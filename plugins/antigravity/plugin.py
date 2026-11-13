"""Antigravity（Google 的 agent 编程：命令行 agy、桌面 App、IDE）：单独下发的插件。

11-05 对 Antigravity CLI 1.5.0（Linux）实测（隔离 HOME + 假模型 tools/agent-probe/fakellm.py 的 Gemini 接口：
~/.gemini/antigravity-cli/settings.json 写 {"modelProvider": "gemini"}，环境变量 GEMINI_API_KEY + GOOGLE_GEMINI_BASE_URL，不用 Google 账号）：
  ~/.gemini/<产品目录>/（命令行 antigravity-cli、桌面 App antigravity、IDE antigravity-ide，同一套结构）：
    conversation_summaries.db   每个会话一行：title、workspace_uris（file:// 的 JSON 数组）、status（CASCADE_RUN_STATUS_RUNNING /
                                IDLE……，等确认时也是 RUNNING）、last_modified_time、step_count
    conversations/<id>.db       steps 表：idx、step_type、status（3 完成、4 / 7 出错或被拒、9 等你确认或回答）；
                                gen_metadata 里有模型名（protobuf，按 gemini-… 认）
    brain/<id>/.system_generated/logs/transcript_full.jsonl   一步一行、实时写：step_index、type（USER_INPUT /
                                PLANNER_RESPONSE / GENERIC）、status、created_at、content、tool_calls（name、args）、error、
                                input_tokens（不含读缓存，11-05 用 FAKE_CACHED_TOKENS 实测）、cache_read_tokens、output_tokens
    presence/<id>.lock          打开着的会话（进程一直开着它）
  确认框「Requesting permission for:」选项 1 允许 / 2 本会话总是允许 / 3 总是允许（写进设置）/ 4 拒绝，按数字就提交；
  提问框「Question 1/N」按选项数字就选（最后一项 Write-in 自己填）；忙时状态行有「esc to cancel」，Esc 中断；/exit 退出。
额度：Google 账号的配额只在 Antigravity 里看（要读它的登录凭证才能查），API key 按量付费在 Google AI Studio 看。
"""
import glob
import json
import os
import re
import shutil
import sqlite3
import subprocess
import time
from urllib.parse import unquote, urlparse
from urllib.request import pathname2url

PRODUCTS = (("antigravity-cli", "cli"), ("antigravity", "desktop"), ("antigravity-ide", "ide"))
TOOLS = {"run_command": "Bash", "view_file": "Read", "write_to_file": "Write", "replace_file_content": "Edit",
         "multi_replace_file_content": "Edit", "list_dir": "LS", "grep_search": "Grep", "find_by_name": "Glob",
         "search_web": "WebSearch", "read_url_content": "WebFetch", "ask_question": "AskUserQuestion",
         "invoke_subagent": "Agent", "manage_task": "TodoWrite"}
PATH_KEYS = ("AbsolutePath", "TargetFile", "FilePath", "File", "Path", "DirectoryPath", "SearchPath")
RECENT_MS = 2 * 3600 * 1000
WAITING = 9          # steps.status：等你确认或回答
BUSY_MARK = "esc to cancel"
APPROVAL_MARK = "Requesting permission for:"
QUESTION_MARK = re.compile(r"Question \d+/\d+")
REQUEST = re.compile(r"<USER_REQUEST>\s*(.*?)\s*</USER_REQUEST>", re.S)
MODEL = re.compile(rb"\x9a\x01[\x05-\x40]((?:gemini|claude|gpt)-[\w.\-]{2,60})")   # gen_metadata 里这次请求用的模型（protobuf 字段 19）
READ_ONLY_DESKTOP = ("Antigravity 桌面版没有对外的操作接口，会话只能查看；请在电脑上的 Antigravity 中回复和确认",
                     "The Antigravity desktop app offers no external control interface, so its sessions are view-only. "
                     "Reply and confirm in Antigravity on your computer.")
READ_ONLY_CLI = (("连不上这个 Antigravity CLI 会话所在的终端窗口，只能查看", "Couldn't reach the terminal window this Antigravity CLI session runs in, so it's view-only.")
                 if os.name == "nt" else
                 ("Antigravity CLI 不在 tmux 中运行，只能查看；在 tmux 中启动 agy，或在 Kiteline 新建任务时选择 Antigravity CLI（由 Kiteline 在后台运行）后即可从手机回复和确认",
                  "Antigravity CLI isn't running in tmux, so this session is view-only. Start agy in tmux, or choose Antigravity CLI when creating a task in Kiteline (it runs in the background), to reply and confirm from your phone."))


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
    WINDOWS_TESTED = True

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
            term_keys(pane, name)

    GEMINI = os.environ.get("ANTIGRAVITY_GEMINI_DIR") or os.path.join(kl.HOME, ".gemini")
    _models = {}   # 会话库路径 → (mtime, 模型名)

    def homes():
        return [(os.path.join(GEMINI, name), form) for name, form in PRODUCTS if os.path.isdir(os.path.join(GEMINI, name))]

    def query(path, sql, args=()):
        if not os.path.isfile(path):
            return []
        try:
            db = sqlite3.connect("file:%s?mode=ro" % pathname2url(path), uri=True, timeout=2)
        except sqlite3.Error:
            return []
        try:
            db.row_factory = sqlite3.Row
            return [dict(r) for r in db.execute(sql, args)]
        except sqlite3.Error:
            return []
        finally:
            db.close()

    def transcript(home, cid):
        return os.path.join(home, "brain", cid, ".system_generated", "logs", "transcript_full.jsonl")

    def model_of(home, cid):
        path = os.path.join(home, "conversations", cid + ".db")
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            return None
        hit = _models.get(path)
        if hit and hit[0] == mtime:
            return hit[1]
        name = None
        for row in query(path, "select data from gen_metadata order by idx desc limit 3"):
            found = MODEL.findall(row.get("data") or b"")
            if found:
                name = found[-1].decode()
                break
        _models[path] = (mtime, name)
        return name

    def tool_of(name, args):
        mapped = TOOLS.get(name, name or "tool")
        args = dict(args) if isinstance(args, dict) else {}
        if mapped == "Bash" and "CommandLine" in args:
            args["command"] = args.pop("CommandLine")
            if args.get("Cwd"):
                args["cwd"] = args.pop("Cwd")
        for key in PATH_KEYS:
            if key in args and isinstance(args[key], str):
                args["path" if mapped in ("LS", "Grep", "Glob") else "file_path"] = args.pop(key)
                break
        if mapped == "AskUserQuestion" and isinstance(args.get("questions"), list):
            args["questions"] = [dict(q, options=[o if isinstance(o, dict) else {"label": str(o)} for o in q.get("options") or []])
                                 for q in args["questions"] if isinstance(q, dict)]
        if mapped == "Grep" and "Query" in args:
            args["pattern"] = args.pop("Query")
        return mapped, args

    def ts_of(entry):
        return kl.parse_ts(entry.get("created_at")) if entry.get("created_at") else None

    def agy_normalize(offset, entry):
        """transcript_full.jsonl 一行（一步）→ 对话项。工具结果是紧跟着的那几步：第 n 个调用的结果是规划那步 + 1 + n"""
        if not isinstance(entry, dict):
            return []
        step = entry.get("step_index")
        kind = entry.get("type")
        ts = ts_of(entry)
        items = []

        def base():
            return {"id": "%s.%d" % (step if step is not None else offset, len(items)), "ts": ts}

        if kind == "USER_INPUT":
            raw = entry.get("content") or ""
            found = REQUEST.search(raw)
            text, _ = kl.clip(kl.strip_reminders(found.group(1) if found else raw).strip(), kl.USER_TEXT_MAX)
            if text:
                items.append(dict(base(), t="user", text=text))
        elif kind == "PLANNER_RESPONSE":
            thinking = (entry.get("thinking") or "").strip()
            if thinking:
                items.append(dict(base(), t="thinking", text=kl.clip(thinking, kl.ASSISTANT_TEXT_MAX)[0]))
            text = (entry.get("content") or "").strip()
            if text:
                items.append(dict(base(), t="text", text=kl.clip(text, kl.ASSISTANT_TEXT_MAX)[0]))
            for index, call in enumerate(entry.get("tool_calls") or []):
                if not isinstance(call, dict):
                    continue
                name, args = tool_of(call.get("name"), call.get("args"))
                items.append(dict(base(), t="tool", toolId="s%s" % ((step or 0) + 1 + index), name=name,
                                  brief=kl.tool_brief(name, args), input=kl.shrink(args)))
        elif kind == "GENERIC" and entry.get("status") in ("DONE", "ERROR"):
            failed = entry.get("status") == "ERROR"
            text = entry.get("error") if failed else entry.get("content")
            items.append(dict(base(), t="result", toolId="s%s" % step, text=kl.clip(text or "", kl.TOOL_RESULT_MAX)[0],
                              isError=failed))
        return items

    def tail_entries(path, size=256 * 1024):
        try:
            total = os.path.getsize(path)
            with open(path, "rb") as handle:
                handle.seek(max(0, total - size))
                raw = handle.read().splitlines()
        except OSError:
            return []
        out = []
        for line in raw:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if isinstance(entry, dict):
                out.append(entry)
        return out

    def scan(path):
        """一份 transcript → 第一句、最后一句回复、最后一次规划里的工具调用"""
        note = {"first": None, "message": None, "messageId": None, "calls": [], "callStep": None}
        for entry in tail_entries(path):
            kind = entry.get("type")
            if kind == "USER_INPUT" and note["first"] is None:
                found = REQUEST.search(entry.get("content") or "")
                note["first"] = (found.group(1) if found else entry.get("content") or "").strip()
            elif kind == "PLANNER_RESPONSE":
                if (entry.get("content") or "").strip():
                    note["message"], note["messageId"] = entry["content"].strip(), "%s.0" % entry.get("step_index")
                if entry.get("tool_calls"):
                    note["calls"], note["callStep"] = entry["tool_calls"], entry.get("step_index")
        return note

    def usage_scan(path):
        """一份 transcript 的 token：每次规划（PLANNER_RESPONSE）一次请求；input_tokens 本来就不含读缓存"""
        buckets = {}
        folder = path.split(os.sep + "brain" + os.sep)
        home, cid = folder[0], os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(path))))
        model = model_of(home, cid) or "gemini"
        cwd = cwds(home).get(cid)
        try:
            handle = open(path, "rb")
        except OSError:
            return []
        with handle:
            for raw in handle:
                if b'"PLANNER_RESPONSE"' not in raw:
                    continue
                try:
                    entry = json.loads(raw)
                except ValueError:
                    continue
                ts = ts_of(entry)
                if not ts:
                    continue
                values = (entry.get("input_tokens"), entry.get("output_tokens"), entry.get("cache_read_tokens"), 0, 1)
                kl.usage_bucket(buckets, ts, model, values, cwd=cwd, session=cid)
        return list(buckets.values())

    def summaries(home):
        return {r["conversation_id"]: r for r in query(os.path.join(home, "conversation_summaries.db"),
                                                         "select * from conversation_summaries")}

    def cwds(home):
        out = {}
        for cid, row in summaries(home).items():
            out[cid] = first_dir(row.get("workspace_uris"))
        return out

    def first_dir(uris):
        try:
            values = json.loads(uris or "[]")
        except ValueError:
            values = []
        for uri in values if isinstance(values, list) else []:
            if isinstance(uri, str) and uri.startswith("file://"):
                path = unquote(urlparse(uri).path)
                if os.name == "nt" and re.match(r"^/[A-Za-z]:", path):
                    path = path[1:].replace("/", "\\")
                return path
        return None

    def modified(row, now):
        return kl.parse_ts(str(row.get("last_modified_time") or "")[:23].replace(" ", "T") + "Z") or now

    def open_locks(pid):
        """进程开着的 presence 锁 → 会话 id（Linux 读 /proc，Mac 用 lsof）"""
        paths = []
        try:
            for fd in os.listdir("/proc/%d/fd" % pid):
                try:
                    paths.append(os.readlink("/proc/%d/fd/%s" % (pid, fd)))
                except OSError:
                    pass
        except OSError:
            try:
                out = subprocess.run(["lsof", "-p", str(pid), "-Fn"], capture_output=True, text=True, timeout=5).stdout
                paths = [l[1:] for l in out.splitlines() if l.startswith("n")]
            except (OSError, subprocess.SubprocessError):
                paths = []
        return [os.path.basename(p)[:-5] for p in paths
                if p.endswith(".lock") and os.path.basename(os.path.dirname(p)) == "presence"]

    LOG_PID = re.compile(r"Starting language server process with pid (\d+)")
    LOG_CONV = re.compile(r"(?:Created conversation|found conversation|[Rr]esum\w* conversation) ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})")

    def from_logs(home):
        """每个 agy 进程一份日志（log/cli-<时间>.log）：第一行是进程号，后面最近提到的会话就是它开着的那个。
        Windows 上没有 /proc、lsof，靠这个对上进程和会话（11-05）"""
        found = {}
        for path in glob.glob(os.path.join(home, "log", "cli-*.log")):
            try:
                if time.time() - os.path.getmtime(path) > 7 * 86400:
                    continue
                with open(path, "rb") as handle:
                    head = handle.read(4096).decode("utf-8", "replace")
                    handle.seek(max(0, os.path.getsize(path) - 512 * 1024))
                    tail = handle.read().decode("utf-8", "replace")
            except OSError:
                continue
            pid = LOG_PID.search(head)
            convs = LOG_CONV.findall(tail)
            if pid and convs and kl.pid_alive(int(pid.group(1))):
                found[convs[-1]] = int(pid.group(1))
        return found

    def agy_processes():
        """agy 进程 → 它开着的会话 id"""
        try:
            out = ps_text()
        except (OSError, subprocess.SubprocessError):
            return {}
        found = {}
        for line in out.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) != 2 or not parts[0].isdigit():
                continue
            exe = os.path.basename(parts[1].split()[0])
            if exe not in ("agy", "agy.exe", "antigravity-cli"):
                continue
            for cid in open_locks(int(parts[0])):
                found[cid] = int(parts[0])
        return found

    def screen(pane):
        out = term_screen(pane)
        if not out:
            return None
        return "\n".join(out.rstrip().splitlines()[-30:])

    def option_digit(text, words):
        """确认框里以 words 开头的那一项的数字（选项顺序跟工具有关，按字认）"""
        for line in (text or "").splitlines():
            found = re.match(r"^\s*>?\s*(\d)\.\s+(.*)$", line)
            if found and found.group(2).startswith(words):
                return found.group(1)
        return None

    class Antigravity(kl.AgentPlugin):
        name = "Antigravity"

        def __init__(self):
            self.pids = {}
            self.pending = {}   # 会话 id → 等回答的提问（工具调用参数）

        normalize = staticmethod(agy_normalize)

        def launch(self, cwd, resume=None):
            """Kiteline 在自己的后台伪终端里起 Antigravity CLI 的配方（中台 hosted_start 带 agent 时调）：不用用户自己开 tmux，
            起来以后读屏、发字、按键都走通用终端层。字样照 agy 1.5.0（11-13） 实测的画面写（比较时不分大小写）"""
            if resume and not (4 <= len(str(resume)) <= 128 and all(c.isalnum() or c in "_.:-" for c in str(resume))):
                return None
            return {"argv": ["agy"] + (["--conversation", str(resume)] if resume else []),
                    "ready": ["? for shortcuts"],
                    # 第一次在这个文件夹里跑会问信不信任它（默认选中「Yes, I trust this folder」）：用户在 Kiteline 里选了这个项目开任务，回车
                    "answers": [{"when": "do you trust the contents of this project?", "keys": ["Enter"]}],
                    # 没登录时停在选登录方式上：要用户本人在终端里登录
                    "needsUser": ["select login method", "not signed in"],
                    "settle": 1.0}

        def detect(self):
            forms = {}
            if shutil.which("agy"):
                forms["cli"] = ""
            for home, form in homes():
                if form != "cli":
                    forms["desktop"] = ""
            return {"installed": bool(forms) or bool(homes()), "forms": forms}

        def sessions(self):
            out = []
            now = int(time.time() * 1000)
            live = agy_processes()
            for home, form in homes():
                if form == "cli":
                    for cid, pid in from_logs(home).items():
                        live.setdefault(cid, pid)
                rows = summaries(home)
                cids = [os.path.basename(lock)[:-5] for lock in glob.glob(os.path.join(home, "presence", "*.lock"))]
                if form == "cli":   # Windows 上没有 presence 目录：日志里对上了进程的会话也算
                    cids += [cid for cid in live if cid not in cids and cid in rows]
                for cid in cids:
                    pid = live.get(cid) if form == "cli" else None
                    if form == "cli" and not pid:
                        continue   # 锁文件退出后不删：没有进程开着它、日志里也对不上进程，就是残留的
                    row = rows.get(cid)
                    if row is None or row.get("parent_conversation_id"):
                        continue
                    if not pid and now - modified(row, now) > RECENT_MS and row.get("status") != "CASCADE_RUN_STATUS_RUNNING":
                        continue   # 认不出进程（桌面版、Windows）：只列最近动过的
                    out.append(self._snap(home, form, cid, row, pid, now))
            return out

        def _snap(self, home, form, cid, row, pid, now):
            path = transcript(home, cid)
            note = scan(path)
            pane = term_pane(pid) if pid else None
            self.pids[cid] = pid
            busy = row.get("status") == "CASCADE_RUN_STATUS_RUNNING"
            steps = query(os.path.join(home, "conversations", cid + ".db"),
                          "select idx, status from steps order by idx desc limit 1")
            waiting = bool(steps) and steps[0]["status"] == WAITING
            text = screen(pane) if pane else None
            if text is not None:
                busy = BUSY_MARK in text or APPROVAL_MARK in text or bool(QUESTION_MARK.search(text))
                waiting = APPROVAL_MARK in text or bool(QUESTION_MARK.search(text))
            calls = note["calls"] or []
            call = calls[-1] if calls and isinstance(calls[-1], dict) else None
            question = call if waiting and call and call.get("name") == "ask_question" else None
            self.pending[cid] = (question.get("args") or {}) if question else None
            pending_tool = pending_id = waiting_for = None
            if question:
                pending_tool, pending_id = "AskUserQuestion", "s%s" % ((note["callStep"] or 0) + len(calls))
                activity, reason, waiting_for = "waiting", "等待回答提问", "等待你回答"
            elif waiting and call:
                pending_tool, args = tool_of(call.get("name"), call.get("args"))
                pending_id = "s%s" % ((note["callStep"] or 0) + len(calls))
                activity, reason, waiting_for = "waiting", "等待确认：%s" % kl.tool_brief(pending_tool, args), "等待你确认 %s" % pending_tool
            elif busy:
                activity, reason = "busy", "正在工作"
            else:
                activity, reason = "idle", note["message"]
            cwd = first_dir(row.get("workspace_uris")) or ""
            title = (row.get("title") or note["first"] or cid[:8])[:60]
            updated = modified(row, now)
            if form == "cli":
                read_only = None if pane else READ_ONLY_CLI
            else:
                read_only = READ_ONLY_DESKTOP
            return {
                "pid": pid, "sessionId": cid, "name": title, "title": title, "cwd": cwd, "cwdShort": kl.display_cwd(cwd),
                "status": activity, "waitingFor": waiting_for, "needs": None, "detail": None, "activity": activity, "reason": reason,
                "activityText": None, "message": note["message"], "messageUuid": note["messageId"], "error": None, "effort": None,
                "subagents": 0, "pendingTool": pending_tool, "pendingId": pending_id, "startedAt": None,
                "statusUpdatedAt": None, "updatedAt": updated, "version": None, "entrypoint": "antigravity-" + form,
                "sessionKind": None, "tmuxPane": pane, "usage": None,
                "transcriptPath": path if os.path.isfile(path) else None, "transcriptUpdatedAt": updated,
                "agent": "antigravity", "model": model_of(home, cid),
                "readOnly": bool(read_only), "readOnlyReason": read_only[0] if read_only else None,
                "readOnlyReasonEn": read_only[1] if read_only else None,
            }

        def pending_options(self, snap):
            if snap.get("readOnly") or snap.get("pendingTool") == "AskUserQuestion":
                return None
            return ({"key": "deny", "label": "拒绝", "labelEn": "Deny", "style": "destructive"},
                    {"key": "allow", "label": "允许", "labelEn": "Allow", "style": "primary"},
                    {"key": "always", "label": "本会话总是允许", "labelEn": "Always allow in this conversation", "style": "normal"})

        def _pane(self, sid):
            pid = self.pids.get(sid)
            pane = term_pane(pid) if pid else None
            if not pane:
                raise RuntimeError("这个 Antigravity 会话不在 tmux 里运行，只能查看；在 tmux 中启动 agy，或在 Kiteline 新建任务时选择 Antigravity CLI（由 Kiteline 在后台运行）后，就可以从手机回复和确认")
            return pid, pane

        def send(self, sid, text, images):
            pid, _ = self._pane(sid)
            if images:
                text = (text + "\n" + "\n".join("@" + p for p in images)).strip()
            kl.tmux_send(pid, text, [], True)
            return "已发送"

        def key(self, sid, key):
            pid, pane = self._pane(sid)
            key = str(key).lower()
            text = screen(pane) or ""
            if key in ("esc", "escape"):
                if BUSY_MARK not in text:
                    return "当前没有进行中的任务"
                term_keys(pane, "Escape")
                return "已中断"
            if APPROVAL_MARK not in text:
                raise RuntimeError("Antigravity 现在没有等你确认的操作")
            words = {"deny": ("No",), "allow": ("Yes, run", "Yes", "Allow"), "always": ("Yes, and always allow in this conversation",)}
            if key not in words:
                raise RuntimeError("不支持的选项：%s" % key)
            digit = next((d for d in (option_digit(text, w) for w in words[key]) if d), None)
            if not digit:
                raise RuntimeError("确认框里没有这个选项")
            term_keys(pane, digit)
            return "已选择"

        def answer(self, sid, answers):
            pid, pane = self._pane(sid)
            question = self.pending.get(sid)
            if not question:
                raise RuntimeError("这个 Antigravity 会话现在没有待回答的提问")
            for index, item in enumerate(question.get("questions") or []):
                labels = [o if isinstance(o, str) else (o or {}).get("label") for o in item.get("options") or []]
                picked = kl._answer_for(answers, item.get("question"), index)
                choice = next((p for p in picked if p in labels), None)
                if choice is not None and labels.index(choice) < 9:
                    term_keys(pane, str(labels.index(choice) + 1))
                else:
                    custom = next((p for p in picked if p), None)
                    if not custom:
                        raise RuntimeError("没有选择答案")
                    # 最后一项 Write-in：选中后输入、回车
                    term_keys(pane, str(len(labels) + 1))
                    time.sleep(0.4)
                    kl.tmux_send(pid, custom, [], True)
                time.sleep(0.6)
            return "已回答"

        def close(self, sid):
            pid, pane = self._pane(sid)
            text = screen(pane) or ""
            if APPROVAL_MARK in text or QUESTION_MARK.search(text):
                raise RuntimeError("Antigravity 正在等你确认或回答。请先在卡片中作出选择，再关闭会话")
            kl.tmux_send(pid, "/exit", [], True)
            return "已关闭会话"

        def usage(self, since_ms):
            out = []
            folders = [os.path.join(home, "brain") for home, _ in homes()]
            for path in kl.recent_files(folders, "transcript_full.jsonl", since_ms):
                out.extend(r for r in kl.cached_usage(path, usage_scan) if r["ts"] + 3600000 > since_ms)
            return out

    return Antigravity()
