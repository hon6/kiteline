"""Hermes Agent（Nous Research 的开源 agent，命令 hermes）：单独下发的插件。

11-04 对 0.19.0 实测（隔离 HOME + 假模型 tools/agent-probe/fakellm.py）：
  ~/.hermes/state.db（Windows %LOCALAPPDATA%\\hermes；HERMES_HOME 改目录），SQLite（WAL），实时写：
    sessions   id（20261104_104642_39cd4c）、source（cli / telegram……）、cwd、model、title、started_at / ended_at（秒）、
               累计 input_tokens（不含缓存）/ output_tokens / cache_read_tokens / cache_write_tokens、estimated / actual_cost_usd
    messages   自增 id、session_id、role（user / assistant / tool）、content、tool_calls（OpenAI 格式的 JSON）、
               tool_call_id（clarify 的结果没有，按顺序配对）、tool_name、reasoning、timestamp（秒）
    session_model_usage  每个会话每个模型的累计 token、花费、first_seen / last_seen
  终端界面欢迎框里有「Session: <id>」；忙时提示行是「msg=interrupt · /queue · /bg · /steer · Ctrl+C cancel」。
  危险命令的确认框「Dangerous Command」：1 允许一次 / 2 本会话都允许 / 3 加入永久白名单 / 4 拒绝，方向键选、回车确认；
  clarify 提问框「Hermes needs your input」同样方向键 + 回车，最后一项是 Other 自己填。中断是 Ctrl+C（Esc 没用）。
  记录里看不出「等确认」（工具调用先写进去，确认框只在界面上），也不记中断：在 tmux 里看界面，不在的只能按最后一条消息估。
11-23 对 0.23.3 实测（用户反馈开着两个 hermes 却一个会话都不显示）：0.20 起不再发 PyPI，官方安装器装出来的 hermes 是
  shell 包装 `exec <python> -I -c "…runpy.run_module('hermes_cli.main'…)" 参数`，进程命令行里没有 hermes 这个词；还会自己起
  `python -m hermes_cli.main --profile default gateway run` 子进程。会话 id 变成 local-<64 位十六进制>、source 记 local，
  欢迎框只显示前 8 位；忙时提示换成「type to redirect this turn · Tab queues it」「ctrl+c stop」；提问框标题「Hermes Agent needs your input」，
  clarify 参数改成 questions: [{question, choices}]；状态栏「☤ 模型 · ctx …」右边有「/ commands · @ files」。profile 各有自己的
  state.db（~/.hermes/profiles/<名字>/），一起读。确认框、/queue、Ctrl+C、Other 自己填没变。
回复、确认、中断：会话在 tmux 里跑时经 tmux 发字、按键；忙时发的消息用 /queue 排到这一轮之后（直接发会打断这一轮）。
"""
import json
import os
import re
import shutil
import sqlite3
import subprocess
import time
from urllib.request import pathname2url

TOOLS = {"terminal": "Bash", "read_file": "Read", "write_file": "Write", "patch": "Edit", "search_files": "Grep",
         "todo": "TodoWrite", "clarify": "AskUserQuestion", "delegate_task": "Agent"}
TODO_STATUS = {"pending": "pending", "in_progress": "in_progress", "completed": "completed", "cancelled": "completed"}
# 欢迎框里的会话号：0.19 是完整的 20261104_104642_39cd4c；0.23 起库里是 local-<64 位十六进制>，框里只显示前 8 位
SESSION_LINE = re.compile(r"Session:\s+(\d{8}_\d{6}_[0-9a-f]{6}|(?:local-)?[0-9a-f]{8,64})\b")
# 忙时的提示：0.19「msg=interrupt · /queue · … · Ctrl+C cancel」；0.23「type to redirect this turn · Tab queues it」「ctrl+c stop」
BUSY_MARKS = ("ctrl+c cancel", "ctrl+c stop", "redirect this turn", "tab queues it", "processing...", "reasoning...")
# 提问框：0.19「Hermes needs your input」，0.23「Hermes Agent needs your input」
APPROVAL_MARK, QUESTION_MARK = "Dangerous Command", "needs your input"
# 交互会话的来源：0.19 记 cli，0.23 起终端界面记 local、TUI 记 tui（telegram 等网关来的不算）
LOCAL_SOURCES = ("cli", "local", "tui")
# 0.23 起官方安装器的启动器是 shell 包装：exec <python> -I -c "…runpy.run_module('hermes_cli.main' …)" 参数…，命令行里没有 hermes 这个词
RUN_MODULE = re.compile(r"""run_module\(\s*['"]hermes_cli\.main['"][^)]*\)""")
# 不是交互会话的子命令（网关、ACP、仪表盘这些）；0.23 的 CLI 会自己起一个「--profile default gateway run」子进程
NOT_CHAT = ("gateway", "acp", "dashboard", "setup", "doctor", "update", "cron", "kanban", "desktop", "mcp", "web")
READ_ONLY = (("Windows 上从手机操作 Hermes 还没实测，暂未开放，只能查看；请在电脑上回复和确认", "Controlling Hermes on Windows from your phone isn't tested yet, so it isn't available and this session is view-only. Reply and confirm on your computer.")
             if os.name == "nt" else
             ("Hermes 不在 tmux 中运行，只能查看；在 tmux 中启动 hermes，或在 Kiteline 新建任务时选择 Hermes（由 Kiteline 在后台运行）后即可从手机回复和确认",
              "Hermes isn't running in tmux, so this session is view-only. Start hermes in tmux, or choose Hermes when creating a task in Kiteline (it runs in the background), to reply and confirm from your phone."))
# 确认框里的选项：方向键往下几格再回车
OPTIONS = ({"key": "deny", "label": "拒绝", "labelEn": "Deny", "style": "destructive"},
           {"key": "once", "label": "允许", "labelEn": "Allow", "style": "primary"},
           {"key": "session", "label": "允许，且本会话不再询问", "labelEn": "Allow for this session", "style": "normal"})
APPROVAL_DOWNS = {"once": 0, "1": 0, "session": 1, "2": 1, "deny": 3, "4": 3}
USAGE_KEEP_MS = 92 * 86400000
# 自检：hermes 进程在跑、却持续这么久认不出它的会话 → 多半是 Hermes 改了格式，经中台的出错弹窗提示用户报告（每个版本只提示一次）
UNMATCHED_AFTER = 180


def create(kl):
    def ps_text():
        """「进程号 命令行」一行一个：中台的跨平台进程列举（HOST_CAPS proc.list，Windows 也行）；老中台退回 ps"""
        if hasattr(kl, "process_list"):
            return "\n".join("%d %s" % (p["pid"], p["cmd"]) for p in kl.process_list())
        try:
            return subprocess.run(["ps", "-axww", "-o", "pid=,command="], capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            return ""

    # 终端：中台的通用终端层（tmux、Windows 控制台同一套，HOST_CAPS term.any）；老中台没有时只认 tmux
    _term_pane = getattr(kl, "term_pane", None) or kl.find_tmux_pane
    # Windows 控制台上的回复、确认、中断：在 Win11 真机实测过才开放（11-05：没测过的不放出来）
    WINDOWS_TESTED = False

    def term_pane(pid):
        pane = _term_pane(pid)
        if pane and str(pane).startswith("console:") and not WINDOWS_TESTED:
            return None
        return pane

    def term_screen(pane, lines=None):
        if hasattr(kl, "term_screen"):
            return kl.term_screen(pane, lines)
        try:
            return subprocess.run(["tmux", "capture-pane", "-p", "-J", "-t", pane] + (["-S", "-%d" % lines] if lines else []),
                                  capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            return ""

    def term_keys(pane, *names):
        if hasattr(kl, "term_keys"):
            return kl.term_keys(pane, *names)
        for name in names:
            subprocess.run(["tmux", "send-keys", "-t", pane, name], capture_output=True, timeout=5)

    if os.environ.get("HERMES_HOME"):
        HERMES_HOME = os.environ["HERMES_HOME"]
    elif os.name == "nt" and os.environ.get("LOCALAPPDATA"):
        HERMES_HOME = os.path.join(os.environ["LOCALAPPDATA"], "hermes")
    else:
        HERMES_HOME = os.path.join(kl.HOME, ".hermes")
    DB = os.path.join(HERMES_HOME, "state.db")
    LEDGER = os.path.join(kl.DATA_DIR, "plugins", "hermes", "state", "usage.json")

    def all_dbs():
        """默认的 state.db + 各个 profile（hermes -p <名字>，~/.hermes/profiles/<名字>/state.db）各一个库"""
        found = [DB] if os.path.isfile(DB) else []
        root = os.path.join(HERMES_HOME, "profiles")
        try:
            names = sorted(os.listdir(root))
        except OSError:
            names = []
        for name in names:
            path = os.path.join(root, name, "state.db")
            if not name.startswith(".") and os.path.isfile(path):
                found.append(path)
        return found

    def query(sql, args=(), db=None):
        """在一个库（db 给了）或全部库里查；查不了的库跳过"""
        rows = []
        for path in ([db] if db else all_dbs()):
            if not os.path.isfile(path):
                continue
            try:
                conn = sqlite3.connect("file:%s?mode=ro" % pathname2url(path), uri=True, timeout=2)
            except sqlite3.Error:
                continue
            try:
                conn.row_factory = sqlite3.Row
                rows.extend(dict(r, _db=path) for r in conn.execute(sql, args))
            except sqlite3.Error:
                if db:
                    raise
            finally:
                conn.close()
        return rows

    _homes = {}   # 会话 id → 它所在的库

    def db_of(sid):
        if sid not in _homes:
            rows = query("select id from sessions where id = ?", (sid,))
            if not rows:
                return None
            _homes[sid] = rows[0]["_db"]
        return _homes[sid]

    def resolve_sid(shown):
        """欢迎框里显示的会话号 → 库里完整的 id（0.23 只显示 local-<十六进制> 的前 8 位）"""
        rows = query("select id, started_at from sessions where id = ? or id like ? or id like ?",
                     (shown, "local-%s%%" % shown, "%s%%" % shown))
        exact = next((r["id"] for r in rows if r["id"] == shown), None)
        return exact or (max(rows, key=lambda r: float(r.get("started_at") or 0))["id"] if rows else None)

    def tool_of(name, args):
        mapped = TOOLS.get(name, name or "tool")
        args = dict(args) if isinstance(args, dict) else {}
        if mapped in ("Read", "Write", "Edit") and "path" in args and "file_path" not in args:
            args["file_path"] = args.pop("path")
        if mapped == "TodoWrite" and isinstance(args.get("todos"), list):
            args = {"todos": [{"content": t.get("content") or "", "activeForm": t.get("content") or "",
                               "status": TODO_STATUS.get(t.get("status"), "pending")} for t in args["todos"] if isinstance(t, dict)]}
        elif mapped == "AskUserQuestion":
            # 0.19：{question, choices}；0.23 起：{questions: [{question, choices}]}（一次可问几个）
            asked = [q for q in args["questions"] if isinstance(q, dict)] if isinstance(args.get("questions"), list) else [args]
            args = {"questions": [{"question": q.get("question") or "", "header": "", "multiSelect": False,
                                   "options": [{"label": str(c), "description": ""} for c in
                                               (q.get("choices") if isinstance(q.get("choices"), list) else [])]}
                                  for q in asked] or [{"question": "", "header": "", "multiSelect": False, "options": []}]}
        elif mapped == "Agent":
            args = {"description": (args.get("goal") or "")[:80], "prompt": args.get("context") or args.get("goal") or ""}
        return mapped, args

    def calls_of(row):
        try:
            calls = json.loads(row.get("tool_calls") or "null")
        except ValueError:
            return []
        out = []
        for call in calls if isinstance(calls, list) else []:
            function = call.get("function") if isinstance(call, dict) and isinstance(call.get("function"), dict) else {}
            try:
                args = json.loads(function.get("arguments") or "{}")
            except ValueError:
                args = {"arguments": function.get("arguments")}
            out.append((call.get("id") or call.get("call_id"), function.get("name"), args))
        return out

    def is_error(text):
        try:
            data = json.loads(text)
        except (ValueError, TypeError):
            return False
        return isinstance(data, dict) and (data.get("status") == "error" or bool(data.get("error")))

    def to_items(rows):
        """一串消息（按 id 升序）→ 对话项；id 是「消息 id.序号」"""
        items, open_calls = [], []
        for row in rows:
            ts = int(float(row.get("timestamp") or 0) * 1000) or None
            count = [0]

            def add(**fields):
                items.append(dict({"id": "%d.%d" % (row["id"], count[0]), "ts": ts}, **fields))
                count[0] += 1

            role, content = row.get("role"), row.get("content") or ""
            if role == "user":
                text, _ = kl.clip(kl.strip_reminders(content).strip(), kl.USER_TEXT_MAX)
                if text:
                    add(t="user", text=text)
            elif role == "assistant":
                reasoning = (row.get("reasoning") or row.get("reasoning_content") or "").strip()
                if reasoning:
                    add(t="thinking", text=kl.clip(reasoning, kl.ASSISTANT_TEXT_MAX)[0])
                if content.strip():
                    add(t="text", text=kl.clip(content.strip(), kl.ASSISTANT_TEXT_MAX)[0])
                for call_id, name, args in calls_of(row):
                    mapped, args = tool_of(name, args)
                    open_calls.append((call_id, name))
                    add(t="tool", toolId=call_id, name=mapped, brief=kl.tool_brief(mapped, args), input=kl.shrink(args))
            elif role == "tool":
                call_id = row.get("tool_call_id")
                if not call_id:   # clarify 的结果不带 id：配给最近一个同名、还没结果的调用
                    match = next((c for c in reversed(open_calls) if c[1] == row.get("tool_name")), None)
                    call_id = match[0] if match else None
                open_calls = [c for c in open_calls if c[0] != call_id]
                add(t="result", toolId=call_id, text=kl.clip(content, kl.TOOL_RESULT_MAX)[0], isError=is_error(content))
        return items

    def recent(sid, count):
        rows = query("select * from messages where session_id = ? and active = 1 order by id desc limit ?", (sid, count), db_of(sid))
        return list(reversed(rows))

    _cwds = {}
    _cmds = {}    # pid → 命令行（自检时从里面找安装目录、读 Hermes 的版本）

    def process_cwd(pid):
        try:
            return os.readlink("/proc/%d/cwd" % pid)
        except OSError:
            pass
        try:
            out = subprocess.run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"], capture_output=True, text=True, timeout=5).stdout
            return next((l[1:] for l in out.splitlines() if l.startswith("n")), None)
        except (OSError, subprocess.SubprocessError):
            return None

    def chat_args(command):
        """一行命令行是不是 hermes 主程序：是就返回它后面的参数，不是返回 None。认三种：
        …/bin/hermes（pip 装的、Mac 桌面版自带的）、python -m hermes_cli.main、0.23 起官方启动器的 python -I -c "…run_module('hermes_cli.main'…)\""""
        match = RUN_MODULE.search(command)
        if match:
            return command[match.end():].split()
        argv = command.split()
        if "-m" in argv[:4]:
            at = argv.index("-m")
            if at + 1 < len(argv) and argv[at + 1] == "hermes_cli.main":
                return argv[at + 2:]
        # Windows 的启动器是 hermes.exe，命令行里的路径常带引号
        script = next((a for a in argv[:3] if re.split(r"[\\/]", a.strip('"'))[-1].lower()
                       in ("hermes", "hermes-agent", "hermes.exe", "hermes-agent.exe")), None)
        return argv[argv.index(script) + 1:] if script else None

    def hermes_processes():
        """交互的 hermes 进程（Python 跑的 …/bin/hermes；网关、ACP、仪表盘不算）→ 工作目录"""
        try:
            out = ps_text()
        except (OSError, subprocess.SubprocessError):
            return {}
        procs = {}
        for line in out.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) != 2 or not parts[0].isdigit():
                continue
            args = chat_args(parts[1])
            if args is None:
                continue
            # 跳过 --profile / -p 这类带值的选项，看第一个子命令
            first, skip = None, False
            for arg in args:
                if skip:
                    skip = False
                elif arg in ("--profile", "-p", "--model", "-m", "--provider", "--resume", "-r", "--toolsets", "-t"):
                    skip = True
                elif not arg.startswith("-"):
                    first = arg
                    break
            if first in NOT_CHAT:
                continue
            pid = int(parts[0])
            if pid not in _cwds:
                _cwds[pid] = process_cwd(pid)
            procs[pid] = _cwds[pid]
            _cmds[pid] = parts[1]
        for pid in list(_cwds):
            if pid not in procs:
                _cwds.pop(pid, None)
        for pid in list(_cmds):
            if pid not in procs:
                _cmds.pop(pid, None)
        return procs

    def agent_version(command):
        """从进程命令行找到安装目录读 Hermes 的版本（不起子进程）：打包版的 install-stamp.json、官方脚本装的源码目录（git tag）、
        pip 装的 dist-info；都没有返回 None"""
        roots = re.findall(r"""sys\.path\.insert\(0,\s*['"]([^'"]+)['"]""", command)
        argv = command.split()
        script = next((a.strip('"') for a in argv[:3] if re.split(r"[\\/]", a.strip('"'))[-1].lower().startswith("hermes")), None)
        if script:
            here = os.path.dirname(os.path.realpath(script))
            for _ in range(5):   # Mac 桌面版：…/Contents/Resources/install-stamp.json；源码安装的 venv/bin/hermes 往上找
                roots.append(here)
                here = os.path.dirname(here)
        for root in roots:
            try:
                with open(os.path.join(root, "install-stamp.json"), encoding="utf-8-sig") as handle:
                    stamp = json.load(handle)
                if stamp.get("displayVersion") or stamp.get("baseVersion"):
                    return str(stamp.get("displayVersion") or stamp.get("baseVersion"))
            except (OSError, ValueError, AttributeError):
                pass
            git = os.path.join(root, ".git")
            try:
                head = (kl.read_text(os.path.join(git, "HEAD")) or "").strip()
                if head.startswith("ref: "):
                    head = (kl.read_text(os.path.join(git, head[5:])) or "").strip()
                if re.fullmatch(r"[0-9a-f]{40}", head or ""):
                    tags = [(line.split()[1], line.split()[0]) for line in (kl.read_text(os.path.join(git, "packed-refs")) or "").splitlines()
                            if line[:40] == head and " refs/tags/" in line]
                    tag_dir = os.path.join(git, "refs", "tags")
                    if os.path.isdir(tag_dir):
                        tags += [(name, None) for name in os.listdir(tag_dir) if (kl.read_text(os.path.join(tag_dir, name)) or "").strip() == head]
                    return tags[0][0].replace("refs/tags/", "") if tags else "git " + head[:7]
            except (OSError, IndexError):
                pass
        if script:   # pip 装的：…/bin/hermes → …/lib/python3.x/site-packages/hermes_agent-<版本>.dist-info
            lib = os.path.join(os.path.dirname(os.path.dirname(script)), "lib")
            try:
                for py in os.listdir(lib):
                    for name in os.listdir(os.path.join(lib, py, "site-packages")):
                        hit = re.match(r"hermes_agent-([^-]+)\.dist-info$", name)
                        if hit:
                            return hit.group(1)
            except OSError:
                pass
        return None

    def screen(pane, lines=40):
        out = term_screen(pane, lines if lines > 60 else None)
        if not out:
            return None
        return out if lines > 60 else "\n".join(out.rstrip().splitlines()[-lines:])

    def pane_state(pane):
        """tmux 里的界面：approval 等确认 / question 等回答 / busy / idle；看不了 None"""
        text = screen(pane, 30)
        if text is None:
            return None
        if APPROVAL_MARK in text and "Allow once" in text:
            return "approval"
        if QUESTION_MARK in text:
            return "question"
        tail = "\n".join(text.splitlines()[-6:])
        return "busy" if any(mark in tail.lower() for mark in BUSY_MARKS) else "idle"

    def ledger_usage(since_ms):
        """session_model_usage 只有累计值：记一本账，涨了多少记一条（时间取它 last_seen），第一次看到的整段算在 last_seen 那天"""
        try:
            ledger = json.loads(kl.read_text(LEDGER) or "{}")
        except ValueError:
            ledger = {}
        seen, records = ledger.get("seen") or {}, ledger.get("records") or []
        changed = False
        try:
            rows = query("select u.*, s.cwd as cwd from session_model_usage u left join sessions s on s.id = u.session_id")
        except sqlite3.Error:
            rows = []
        for row in rows:
            key = "|".join(str(row.get(k) or "") for k in ("session_id", "model", "billing_provider", "billing_base_url", "billing_mode", "task"))
            now = [int(row.get(k) or 0) for k in ("input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "api_call_count")]
            cost_now = float(row.get("actual_cost_usd") or 0) or float(row.get("estimated_cost_usd") or 0)
            priced = row.get("cost_status") not in (None, "", "unknown", "none") or cost_now > 0
            before = seen.get(key) or {}
            delta = [max(0, a - b) for a, b in zip(now, before.get("totals") or [0, 0, 0, 0, 0])]
            if any(delta[:4]):
                records.append({"ts": int(float(row.get("last_seen") or time.time()) * 1000), "model": row.get("model") or "unknown",
                                "cwd": row.get("cwd"), "session": row.get("session_id"), "input": delta[0], "output": delta[1],
                                "cacheRead": delta[2], "cacheWrite": delta[3], "requests": delta[4],
                                "cost": max(0.0, cost_now - float(before.get("cost") or 0)) if priced else None})
                seen[key] = {"totals": now, "cost": cost_now}
                changed = True
        if changed:
            cutoff = int(time.time() * 1000) - USAGE_KEEP_MS
            records = [r for r in records if r.get("ts", 0) >= cutoff]
            try:
                os.makedirs(os.path.dirname(LEDGER), exist_ok=True)
                with open(LEDGER + ".tmp", "w", encoding="utf-8") as handle:
                    json.dump({"seen": seen, "records": records}, handle, ensure_ascii=False)
                os.replace(LEDGER + ".tmp", LEDGER)
            except OSError:
                pass
        return [r for r in records if r.get("ts", 0) + 3600000 > since_ms]

    class Hermes(kl.AgentPlugin):
        name = "Hermes"

        def __init__(self):
            self.pids = {}        # 会话 id → pid
            self.panes = {}       # 会话 id → 界面状态
            self.last = {}        # 会话 id → 已推过的最后一条消息 id
            self.questions = {}   # 会话 id → 等回答的 clarify 选项
            self.unmatched = []   # 这一轮认不出会话的 hermes 进程
            self.unmatched_since = None
            self.flagged = set()  # 已经提示过的（插件版本, Hermes 版本）

        def launch(self, cwd, resume=None):
            """Kiteline 在自己的后台伪终端里起 Hermes 的配方（中台 hosted_start 带 agent 时调）：不用用户自己开 tmux，
            起来以后读屏、发字、按键都走通用终端层。字样照 hermes（11-13） 实测的画面写（比较时不分大小写）"""
            if resume and not (4 <= len(str(resume)) <= 128 and all(c.isalnum() or c in "_.:-" for c in str(resume))):
                return None
            return {"argv": ["hermes"] + (["--resume", str(resume)] if resume else []),
                    # 输入框上面的状态栏（模型 │ ctx …）出来 = 能输入了
                    "ready": ["\u2502 ctx", "/ commands \u00b7 @ files"],
                    # 还没配置模型：它问要不要现在跑 hermes setup，要用户本人在终端里配
                    "needsUser": ["isn't configured yet", "run setup now?"],
                    "settle": 1.0}

        def detect(self):
            command = shutil.which("hermes")
            return {"installed": os.path.isfile(DB) or bool(command), "forms": {"cli": ""} if command else {}}

        def live(self):
            """开着的会话 → pid：tmux 里的看欢迎框的会话 id；不在 tmux 的取它工作目录下最近的命令行会话"""
            found = {}
            for pid, cwd in hermes_processes().items():
                sid, pane = None, term_pane(pid)
                if pane:
                    hits = SESSION_LINE.findall(screen(pane, 5000) or "")
                    sid = resolve_sid(hits[-1]) if hits else None
                if not sid and cwd:
                    rows = query("select id, started_at from sessions where cwd = ? and source in (%s) and ended_at is null"
                                 % ",".join("?" * len(LOCAL_SOURCES)), (cwd,) + LOCAL_SOURCES)
                    rows.sort(key=lambda r: float(r.get("started_at") or 0), reverse=True)   # 几个库合在一起再排
                    sid = next((r["id"] for r in rows if r["id"] not in found), None)
                if sid:
                    found[sid] = pid
            self.unmatched = [pid for pid in hermes_processes() if pid not in found.values()]
            return found

        def self_check(self):
            """hermes 在跑却一直认不出会话：经中台的 plugin_error 事件提示用户（电脑端弹窗，可一键报告），不算插件出错、不会停用插件。
            刚启动、还没建会话的有 3 分钟宽限"""
            if not self.unmatched:
                self.unmatched_since = None
                return
            now = time.time()
            self.unmatched_since = self.unmatched_since or now
            if now - self.unmatched_since < UNMATCHED_AFTER or not hasattr(kl, "emit"):
                return
            version = next((v for v in (agent_version(_cmds.get(pid) or "") for pid in self.unmatched) if v), None)
            key = (self.version, version)
            if key in self.flagged:
                return
            self.flagged.add(key)
            kl.emit({"event": "plugin_error", "id": self.id, "name": self.name, "version": self.version, "source": getattr(self, "source", "external"),
                     "where": "sessions", "error": ("有 %d 个 Hermes（版本 %s）正在运行，但插件认不出它的会话，可能是 Hermes 更新后记录格式变了，或它用了插件读不到的数据目录（HERMES_HOME）。"
                                                     "请点「报告」告诉我们，会尽快适配。 / %d Hermes process(es) (version %s) are running "
                                                     "but their sessions can't be recognized, possibly because Hermes changed its format "
                                                     "after an update or uses a data folder (HERMES_HOME) the plugin can't read. Please tap Report so we can add support.")
                                                    % (len(self.unmatched), version or "未知", len(self.unmatched), version or "unknown"),
                     "trace": "agentVersion=%s\n%s" % (version, "\n".join(re.sub(r"/(Users|home)/[^/\s'\"]+", r"/\1/~", _cmds.get(pid) or "")[:400]
                                                                         for pid in self.unmatched[:3]))})

        def sessions(self):
            out = []
            now = int(time.time() * 1000)
            live = self.live()
            for sid, pid in live.items():
                rows = query("select * from sessions where id = ?", (sid,), db_of(sid))
                if not rows:
                    continue
                session = rows[0]
                messages = recent(sid, 40)
                items = to_items(messages)
                first = next((i["text"] for i in items if i["t"] == "user"), None)
                if first is None:
                    first_rows = query("select content from messages where session_id = ? and role = 'user' order by id limit 1", (sid,), db_of(sid))
                    first = first_rows[0]["content"] if first_rows else None
                last_text = next((i for i in reversed(items) if i["t"] == "text"), None)
                calls = {}
                for item in items:
                    if item["t"] == "tool":
                        calls[item.get("toolId")] = item
                    elif item["t"] == "result":
                        calls.pop(item.get("toolId"), None)
                open_call = list(calls.values())[-1] if calls else None
                pane = term_pane(pid)
                state = pane_state(pane) if pane else None
                self.pids[sid], self.panes[sid] = pid, state
                updated = int(float(messages[-1]["timestamp"]) * 1000) if messages else int(float(session.get("started_at") or 0) * 1000)
                if state is None:   # 不在 tmux：最后一条是用户的话或还没结果的工具调用，10 分钟内算忙
                    last_role = messages[-1]["role"] if messages else None
                    state = "busy" if (last_role == "user" or open_call) and now - updated < 10 * 60 * 1000 else "idle"
                pending_tool = pending_id = waiting = None
                if state == "approval":
                    pending_tool = open_call["name"] if open_call else "Bash"
                    pending_id = open_call.get("toolId") if open_call else None
                    activity, reason = "waiting", "等待确认：%s" % (open_call.get("brief") if open_call else "危险命令")
                    waiting = "等待你确认 %s" % pending_tool
                elif state == "question":
                    pending_tool, pending_id = "AskUserQuestion", open_call.get("toolId") if open_call else None
                    activity, reason, waiting = "waiting", "等待回答提问", "等待你回答"
                    questions = ((open_call or {}).get("input") or {}).get("questions") or [{}]
                    self.questions[sid] = [o.get("label") for o in questions[0].get("options") or []]
                elif state == "busy":
                    activity, reason = "busy", "正在工作"
                else:
                    activity, reason = "idle", last_text["text"] if last_text else None
                title = (session.get("title") or (first or "").strip() or sid)[:60]
                cwd = session.get("cwd") or ""
                if sid not in self.last:
                    self.last[sid] = messages[-1]["id"] if messages else 0
                out.append({
                    "pid": pid, "sessionId": sid, "name": title, "title": title, "cwd": cwd, "cwdShort": kl.display_cwd(cwd),
                    "status": activity, "waitingFor": waiting, "needs": None, "detail": None, "activity": activity, "reason": reason,
                    "activityText": None, "message": last_text["text"] if last_text else None,
                    "messageUuid": last_text["id"] if last_text else None, "error": None, "effort": None, "subagents": 0,
                    "pendingTool": pending_tool, "pendingId": pending_id,
                    "startedAt": int(float(session.get("started_at") or 0) * 1000) or None, "statusUpdatedAt": None,
                    "updatedAt": updated, "version": None, "entrypoint": "hermes-" + (session.get("source") or "cli"),
                    "sessionKind": None, "tmuxPane": pane, "usage": None, "transcriptPath": None, "transcriptUpdatedAt": updated,
                    "agent": "hermes", "model": session.get("model"),
                    "readOnly": not pane, "readOnlyReason": None if pane else READ_ONLY[0],
                    "readOnlyReasonEn": None if pane else READ_ONLY[1],
                })
            for sid in list(self.last):
                if sid not in live:
                    self.last.pop(sid, None)
            self.self_check()
            return out

        def pump(self):
            out = []
            for sid, last in list(self.last.items()):
                try:
                    rows = recent(sid, 40)
                except sqlite3.Error:
                    continue
                if not rows or rows[-1]["id"] <= last:
                    continue
                items = [i for i in to_items(rows) if int(i["id"].split(".")[0]) > last]
                self.last[sid] = rows[-1]["id"]
                if items:
                    out.append((sid, items))
            return out

        def history(self, sid, before, limit):
            count = max(1, limit // 2)
            try:
                bound = int(float(before)) if before is not None else None
            except (TypeError, ValueError):
                bound = None
            if bound is None:
                rows = query("select * from messages where session_id = ? and active = 1 order by id desc limit ?", (sid, count + 1), db_of(sid))
            else:
                rows = query("select * from messages where session_id = ? and active = 1 and id < ? order by id desc limit ?",
                             (sid, bound, count + 1), db_of(sid))
            has_more = len(rows) > count
            return to_items(list(reversed(rows[:count]))), has_more

        def pending_options(self, snap):
            if snap.get("readOnly") or snap.get("pendingTool") == "AskUserQuestion":
                return None
            return OPTIONS

        def _pane(self, sid):
            pid = self.pids.get(sid)
            pane = term_pane(pid) if pid else None
            if not pane:
                raise RuntimeError("这个 Hermes 会话不在 tmux 里运行，只能查看；在 tmux 中启动 hermes，或在 Kiteline 新建任务时选择 Hermes（由 Kiteline 在后台运行）后，就可以从手机回复和确认")
            return pid, pane

        def send(self, sid, text, images):
            pid, pane = self._pane(sid)
            if images:
                text = (text + "\n" + "\n".join(images)).strip()
            state = pane_state(pane)
            if state in ("approval", "question"):
                raise RuntimeError("Hermes 正在等你确认或回答，请先在卡片中作出选择再发消息")
            # 忙时直接发会打断这一轮：排到这一轮之后
            kl.tmux_send(pid, ("/queue " + text) if state == "busy" else text, [], True)
            return "已加入队列" if state == "busy" else "已发送"

        def key(self, sid, key):
            pid, pane = self._pane(sid)
            key = str(key).lower()
            if key in ("esc", "escape"):
                state = pane_state(pane)
                if state == "approval":   # 等确认时 Esc 当拒绝
                    key = "deny"
                elif state != "busy":
                    return "当前没有进行中的任务"
                else:
                    term_keys(pane, "C-c")
                    return "已中断"
            if key not in APPROVAL_DOWNS:
                raise RuntimeError("不支持的选项：%s" % key)
            if pane_state(pane) != "approval":
                raise RuntimeError("Hermes 现在没有等待确认的命令")
            kl.tmux_send(pid, "", ["down"] * APPROVAL_DOWNS[key] + ["enter"], False)
            return "已选择"

        def answer(self, sid, answers):
            pid, pane = self._pane(sid)
            if pane_state(pane) != "question":
                raise RuntimeError("这个 Hermes 会话现在没有待回答的提问")
            labels = self.questions.get(sid) or []
            picked = kl._answer_for(answers, None, 0)
            choice = next((p for p in picked if p in labels), None)
            if choice is not None:
                kl.tmux_send(pid, "", ["down"] * labels.index(choice) + ["enter"], False)
                return "已回答"
            custom = next((p for p in picked if p), None)
            if not custom:
                raise RuntimeError("没有选择答案")
            # 最后一项「Other」自己填：选中后输入文字再回车
            kl.tmux_send(pid, "", ["down"] * len(labels) + ["enter"], False)
            time.sleep(0.4)
            kl.tmux_send(pid, custom, [], True)
            return "已回答"

        def close(self, sid):
            pid, pane = self._pane(sid)
            if pane_state(pane) in ("approval", "question"):
                raise RuntimeError("Hermes 正在等你确认或回答。请先在卡片中作出选择，再关闭会话")
            kl.tmux_send(pid, "/exit", [], True)
            return "已关闭会话"

        def usage(self, since_ms):
            return ledger_usage(since_ms)

    return Hermes()
