"""CodeBuddy Code / WorkBuddy（腾讯的编程 agent，命令 codebuddy / cbc；WorkBuddy 桌面版用同一个内核）：单独下发的插件。

11-05 对 CodeBuddy Code 2.179.3 实测（隔离 HOME + 假模型：CODEBUDDY_BASE_URL / CODEBUDDY_API_KEY 指过去就行，不用登录）：
  ~/.codebuddy/（WorkBuddy 是 ~/.workbuddy，国际版 ~/.workbuddy-ai；CODEBUDDY_CONFIG_DIR 改目录）
    sessions/<pid>.json                  开着的会话：pid、sessionId、cwd、startedAt、kind（interactive……）、version、url（本机 Remote Control 网页）
    projects/<cwd 去掉开头的 / 再把 / 换成 ->/<sessionId>.jsonl   对话记录，一行一条，实时写，时间是毫秒：
        message（role user：content 里 input_text；role assistant：output_text，status incomplete + 「Interrupted by user」是中断）
        function_call（callId、name、arguments JSON 字符串）/ function_call_result（callId、status、output.text）
        ai-title（aiTitle）、turn-metrics（一轮结束）、file-history-snapshot、session-meta、summary
        助手条目的 providerData.usage：inputTokens（含读缓存）、inputTokensDetails[].cached_tokens、outputTokens；同一次请求的几条共用 messageId
  工具名同 Claude Code；默认工具模式「PTC」时所有工具经 REPL（写代码调），记录里是 REPL 调用。
  确认框同 Claude Code：1 允许 / 2 本会话都允许 / 3 拒绝（Esc）；提问框方向键选、回车，最后「Submit answers」再回车；Esc 中断；/exit 退出。
回复、确认、中断：在 tmux 里跑的会话经 tmux 发字、按键；WorkBuddy 桌面版和不在 tmux 里的只能看。
额度：积分制，只能在网页「用量」页看，本机不记、没有查询接口。

11-13 在用户 Mac 上装 WorkBuddy 5.9.3（微信登录）实测：
  ~/.workbuddy/ 和 CodeBuddy 同一套布局（projects/<目录>/<任务 id>.jsonl 对话记录、sessions/<pid>.json），另有：
    workbuddy.db（SQLite）sessions 表：id、cwd（默认 ~/WorkBuddy/<时间>）、title / custom_title、status（completed……）、
      created_at / updated_at / last_activity_at（毫秒）、deleted_at、transport（local / cloud）、is_background_automation、model；
      session_usage 表：每个任务的积分（credit_json：{请求 id: 积分}）
    sessions/<pid>.json 平时是进程池里预热的工作进程（kind prewarm、sessionId prewarm-…、cwd /），不是任务
  任务跑完工作进程就回池子，没有常驻的会话进程：桌面版的任务按数据库列（WorkBuddy 开着时，最近 24 小时活动过的）。
  桌面版没有对外的操作接口（网页内容不对辅助功能开放），只能看；它自己有手机 App。
"""
import glob
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from urllib.parse import quote
from urllib.request import pathname2url

TAIL_BYTES = 512 * 1024
READ_ONLY = (("Windows 上从手机操作 CodeBuddy Code 还没实测，暂未开放，只能查看；请在电脑上回复和确认", "Controlling CodeBuddy Code on Windows from your phone isn't tested yet, so it isn't available and this session is view-only. Reply and confirm on your computer.")
             if os.name == "nt" else
             ("不在 tmux 中运行（或在 WorkBuddy 桌面版中），只能查看；在 tmux 中启动 codebuddy，或在 Kiteline 新建任务时选择 CodeBuddy Code（由 Kiteline 在后台运行）后即可从手机回复和确认",
              "Not running in tmux (or running in the WorkBuddy desktop app), so this session is view-only. "
              "Start codebuddy in tmux, or choose CodeBuddy Code when creating a task in Kiteline (it runs in the background), to reply and confirm from your phone."))
OPTIONS = ({"key": "3", "label": "拒绝", "labelEn": "Deny", "style": "destructive"},
           {"key": "1", "label": "允许", "labelEn": "Allow", "style": "primary"},
           {"key": "2", "label": "允许，且本会话不再询问", "labelEn": "Allow for this session", "style": "normal"})
APPROVAL_MARK = "Do you want to proceed"
QUESTION_MARK = "Enter to select · ↑/↓ to navigate"
BUSY_MARKS = ("esc to interrupt", "Esc to interrupt", "ESC to interrupt")
DESKTOP_READ_ONLY = (("WorkBuddy 桌面版的任务在 Windows 上还不能从手机发消息（还没实测），只能查看；请在 WorkBuddy 中继续操作",
                      "Sending to WorkBuddy desktop tasks from your phone isn't available on Windows yet (not tested), so they're view-only. Continue in WorkBuddy.")
                     if os.name == "nt" else
                     ("WorkBuddy 桌面版的任务在这台电脑上只能查看：从手机发消息目前只在 Mac 上实测过；请在 WorkBuddy 中继续操作",
                      "WorkBuddy desktop tasks are view-only on this computer: sending from your phone has only been tested on a Mac. Continue in WorkBuddy."))
DESKTOP_OLD_HOST = "这台电脑上的 Kiteline 版本较旧，更新后可从手机给 WorkBuddy 发消息、新建任务"
# 从手机给 WorkBuddy 桌面版的任务发消息：用它自己的深链接 workbuddy://chat/<任务> 打开这个任务（切到前台），
# 电脑端核对 WorkBuddy 在前台后粘贴、回车（动作单 open / paste / key，见 guide/plugin-development.md 3.3）。只在 Mac 上实测过
DESKTOP_SEND = sys.platform == "darwin"
DESKTOP_WINDOW_MS = 24 * 3600 * 1000      # 列出最近这么久里活动过的桌面版任务
DESKTOP_DONE = ("completed", "complete", "done", "failed", "error", "cancelled", "canceled", "stopped", "interrupted")
DESKTOP_BUSY = ("running", "in_progress", "processing", "streaming", "busy", "working")


def create(kl):
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
            term_keys(pane, name)

    def homes():
        """各品牌的数据目录：(目录, 品牌名)"""
        out = []
        if os.environ.get("CODEBUDDY_CONFIG_DIR"):
            out.append((os.environ["CODEBUDDY_CONFIG_DIR"], "CodeBuddy"))
        if os.environ.get("WORKBUDDY_HOME"):      # 测试用：WorkBuddy 的目录放在别处
            out.append((os.environ["WORKBUDDY_HOME"], "WorkBuddy"))
        for name, brand in ((".codebuddy", "CodeBuddy"), (".workbuddy", "WorkBuddy"), (".workbuddy-ai", "WorkBuddy")):
            path = os.path.join(kl.HOME, name)
            if path not in [p for p, _ in out]:
                out.append((path, brand))
        return out

    def db_rows(path, sql, args=()):
        """只读打开 WorkBuddy 的 workbuddy.db（它开着、正在写也能读）；读不了（被锁住超过半秒、坏了）返回 None，
        和「真没有任务」分开（读不了时沿用上一次的列表，别让手机上的任务一闪就没了）。在主循环里调，等锁不能久"""
        try:
            db = sqlite3.connect("file:%s?mode=ro" % pathname2url(path), uri=True, timeout=0.5)
        except sqlite3.Error:
            return None
        try:
            db.row_factory = sqlite3.Row
            return [dict(r) for r in db.execute(sql, args)]
        except sqlite3.Error:
            return None
        finally:
            db.close()

    def read_json(path):
        try:
            return json.loads(kl.read_text(path) or "")
        except (ValueError, TypeError):
            return None

    def transcript(home, cwd, sid):
        path = os.path.join(home, "projects", (cwd or "").lstrip("/").replace("/", "-").replace("\\", "-").replace(":", ""), sid + ".jsonl")
        if os.path.isfile(path):
            return path
        found = glob.glob(os.path.join(home, "projects", "*", sid + ".jsonl"))
        return found[0] if found else None

    REMINDER = re.compile(r"<system-reminder\b[^>]*>.*?</system-reminder>", re.S)
    USER_QUERY = re.compile(r"<user_query>(.*?)</user_query>", re.S)

    def strip(text):
        """去掉系统注入块：WorkBuddy 的带属性（<system-reminder data-role="user-context">），中台的 strip_reminders 只认不带属性的；
        WorkBuddy 把用户的话包在 <user_query> 里，只留里面的"""
        text = kl.strip_reminders(REMINDER.sub("", text or ""))
        found = USER_QUERY.findall(text)
        return "\n\n".join(part.strip() for part in found) if found else text

    def text_of(content, kinds=("input_text", "output_text", "text")):
        if isinstance(content, str):
            return content
        if isinstance(content, dict):
            content = [content]
        return "\n".join(p.get("text") for p in content or [] if isinstance(p, dict) and p.get("type") in kinds and isinstance(p.get("text"), str))

    def args_of(entry):
        raw = entry.get("arguments")
        if isinstance(raw, dict):
            return raw
        try:
            value = json.loads(raw or "{}")
            return value if isinstance(value, dict) else {"arguments": value}
        except ValueError:
            return {"arguments": raw}

    def cb_normalize(offset, entry):
        if not isinstance(entry, dict):
            return []
        kind = entry.get("type")
        ts = entry.get("timestamp") if isinstance(entry.get("timestamp"), (int, float)) else None
        items = []

        def base():
            return {"id": "%d.%d" % (offset, len(items)), "ts": int(ts) if ts else None}

        if kind == "message" and entry.get("role") == "user":
            text, _ = kl.clip(strip(text_of(entry.get("content"))).strip(), kl.USER_TEXT_MAX)
            if text and not (entry.get("providerData") or {}).get("isMeta"):
                items.append(dict(base(), t="user", text=text))
        elif kind == "message" and entry.get("role") == "assistant":
            text = text_of(entry.get("content")).strip()
            if entry.get("status") == "incomplete" and text == "Interrupted by user":
                items.append(dict(base(), t="event", text="已中断"))
            elif text:
                items.append(dict(base(), t="text", text=kl.clip(text, kl.ASSISTANT_TEXT_MAX)[0]))
        elif kind == "reasoning":
            text = text_of(entry.get("summary") or entry.get("content"), ("summary_text", "reasoning_text", "text")).strip()
            if text:
                items.append(dict(base(), t="thinking", text=kl.clip(text, kl.ASSISTANT_TEXT_MAX)[0]))
        elif kind == "function_call":
            name, args = entry.get("name") or "tool", args_of(entry)
            items.append(dict(base(), t="tool", toolId=entry.get("callId"), name=name,
                              brief=kl.tool_brief(name, args), input=kl.shrink(args)))
        elif kind == "function_call_result":
            output = entry.get("output")
            text = text_of(output) if not isinstance(output, str) else output
            items.append(dict(base(), t="result", toolId=entry.get("callId"), text=kl.clip(text, kl.TOOL_RESULT_MAX)[0],
                              isError=entry.get("status") not in (None, "completed")))
        return items

    def scan(path):
        note = {"first": None, "message": None, "messageId": None, "pending": None, "busy": False, "title": None, "model": None,
                "updated": 0}
        try:
            size = os.path.getsize(path)
            with open(path, "rb") as handle:
                handle.seek(max(0, size - TAIL_BYTES))
                lines = handle.read().splitlines()
            note["updated"] = int(os.path.getmtime(path) * 1000)
        except OSError:
            return note
        calls = {}
        for raw in lines:
            try:
                entry = json.loads(raw)
            except ValueError:
                continue
            kind = entry.get("type") if isinstance(entry, dict) else None
            if kind == "message" and entry.get("role") == "user":
                text = strip(text_of(entry.get("content"))).strip()
                if text:
                    note["first"] = note["first"] or text
                    note["busy"] = True
            elif kind == "message" and entry.get("role") == "assistant":
                text = text_of(entry.get("content")).strip()
                if text and text != "Interrupted by user":
                    note["message"], note["messageId"] = text, entry.get("id")
                if entry.get("status") == "incomplete":
                    note["busy"] = False
                    calls.clear()
                model = (entry.get("providerData") or {}).get("requestModelName") or (entry.get("providerData") or {}).get("model")
                note["model"] = model or note["model"]
            elif kind == "function_call":
                calls[entry.get("callId")] = entry
                note["busy"] = True
            elif kind == "function_call_result":
                calls.pop(entry.get("callId"), None)
            elif kind == "turn-metrics":
                note["busy"] = False
                calls.clear()
            elif kind == "ai-title" and entry.get("aiTitle"):
                note["title"] = entry["aiTitle"]
        if calls:
            note["pending"] = list(calls.values())[-1]
        return note

    def usage_scan(path):
        """每次请求一份 usage（同一次请求的几条共用 messageId，只算一次），输入减掉读缓存。不记花费"""
        buckets, seen = {}, set()
        sid = os.path.basename(path)[:-len(".jsonl")]
        cwd = None
        try:
            handle = open(path, "rb")
        except OSError:
            return []
        with handle:
            for raw in handle:
                if b'"usage"' not in raw and b'"cwd"' not in raw:
                    continue
                try:
                    entry = json.loads(raw)
                except ValueError:
                    continue
                cwd = cwd or entry.get("cwd")
                data = entry.get("providerData") if isinstance(entry.get("providerData"), dict) else {}
                usage = data.get("usage") if isinstance(data.get("usage"), dict) else None
                key = data.get("messageId") or entry.get("id")
                if not usage or key in seen or not isinstance(entry.get("timestamp"), (int, float)):
                    continue
                seen.add(key)
                cached = sum(int(d.get("cached_tokens") or 0) for d in usage.get("inputTokensDetails") or [] if isinstance(d, dict))
                values = (max(0, int(usage.get("inputTokens") or 0) - cached), usage.get("outputTokens"), cached, 0,
                          usage.get("requests") or 1)
                model = data.get("requestModelName") or data.get("model") or "unknown"
                kl.usage_bucket(buckets, int(entry["timestamp"]), model, values, cwd=cwd, session=sid)
        return list(buckets.values())

    def screen(pane):
        out = term_screen(pane)
        if not out:
            return None
        return "\n".join(out.rstrip().splitlines()[-25:])

    class CodeBuddy(kl.AgentPlugin):
        name = "CodeBuddy / WorkBuddy"

        def __init__(self):
            self.pids = {}
            self.pending = {}
            self._desktop = (0.0, False)
            self.desktop = set()     # 最近一次列出的 WorkBuddy 桌面版任务
            self.busy = set()        # 其中正在跑的
            self._last_desktop = {}  # 数据目录 → 上一次列出的桌面版任务（数据库一时读不了时沿用）
            self.sent = {}           # 任务 id → (刚发的话, 发之前用户说了几句)：动作单最后一步核对发出去没有

        def desktop_running(self):
            """WorkBuddy 桌面版开着没有（关着时它的任务不算「开着的会话」，进历史）；看进程表，记 10 秒"""
            at, running = self._desktop
            if time.time() - at < 10:
                return running
            running = False
            for proc in kl.process_list():
                cmd = proc.get("cmd") or ""
                # 只认程序本体（命令行开头）：别把参数里带 ~/WorkBuddy 目录的进程（比如 ls ~/WorkBuddy）当成它开着
                if cmd.startswith("/Applications/WorkBuddy.app/Contents/MacOS/") or "/WorkBuddy.app/Contents/MacOS/Electron" in cmd.split(" --", 1)[0] \
                        or re.match(r'^"?[A-Za-z]:\\[^"]*\\WorkBuddy\.exe"?(\s|$)', cmd) or cmd.startswith("/opt/WorkBuddy/"):
                    running = True
                    break
            self._desktop = (time.time(), running)
            return running

        def desktop_tasks(self, home, listed, now):
            """WorkBuddy 桌面版的任务（workbuddy.db）：工作进程跑完就回池子，没有常驻进程，按数据库列"""
            path = os.path.join(home, "workbuddy.db")
            if not os.path.isfile(path) or not self.desktop_running():
                return []
            rows = db_rows(path, "select id, cwd, title, custom_title, status, created_at, updated_at, last_activity_at from sessions "
                                 "where (deleted_at is null or deleted_at <= 0) and coalesce(transport, 'local') = 'local' "
                                 "and coalesce(is_background_automation, 0) = 0 and coalesce(last_activity_at, updated_at) > ? "
                                 "order by coalesce(last_activity_at, updated_at) desc limit 30", (now - DESKTOP_WINDOW_MS,))
            if rows is None:
                return None          # 读不了：调用方沿用上一次的
            out = []
            for row in rows:
                sid, cwd = str(row.get("id") or ""), row.get("cwd") or ""
                if not sid or sid in listed:
                    continue
                chat = transcript(home, cwd, sid)
                note = scan(chat) if chat else scan("")
                status = str(row.get("status") or "").lower()
                updated = max(int(row.get("last_activity_at") or 0), int(row.get("updated_at") or 0), note["updated"] or 0)
                busy = status in DESKTOP_BUSY or (status not in DESKTOP_DONE and note["busy"] and now - updated < 2 * 60 * 1000)
                activity = "busy" if busy else "idle"
                title = (row.get("custom_title") or row.get("title") or note["title"] or note["first"] or sid[:8])[:60]
                out.append({
                    "pid": None, "sessionId": sid, "name": title, "title": title, "cwd": cwd, "cwdShort": kl.display_cwd(cwd) if cwd else "",
                    "status": activity, "waitingFor": None, "needs": None, "detail": None, "activity": activity,
                    "reason": "正在工作" if busy else note["message"], "activityText": None, "message": note["message"],
                    "messageUuid": note["messageId"], "error": None, "effort": None, "subagents": 0, "pendingTool": None, "pendingId": None,
                    "startedAt": row.get("created_at"), "statusUpdatedAt": None, "updatedAt": updated or now,
                    "version": None, "entrypoint": "workbuddy-desktop", "sessionKind": None, "tmuxPane": None, "usage": None,
                    "transcriptPath": chat, "transcriptUpdatedAt": updated or now, "agent": "codebuddy", "model": note["model"],
                    "readOnly": not DESKTOP_SEND, "readOnlyReason": None if DESKTOP_SEND else DESKTOP_READ_ONLY[0],
                    "readOnlyReasonEn": None if DESKTOP_SEND else DESKTOP_READ_ONLY[1],
                    "caps": [],
                })
                if busy:
                    self.busy.add(sid)
            return out

        normalize = staticmethod(cb_normalize)

        def detect(self):
            forms = {}
            if shutil.which("codebuddy") or shutil.which("cbc"):
                forms["cli"] = ""
            if os.path.isdir(os.path.join(kl.HOME, ".workbuddy")) or os.path.isdir(os.path.join(kl.HOME, ".workbuddy-ai")):
                forms["desktop"] = ""
            return {"installed": bool(forms) or os.path.isdir(os.path.join(kl.HOME, ".codebuddy")), "forms": forms}

        def launch(self, cwd, resume=None):
            """Kiteline 在自己的后台伪终端里起 CodeBuddy Code 的配方（中台 hosted_start 带 agent 时调）：
            不用用户自己开 tmux，起来以后读屏、发字、按键都走通用终端层。恢复用它自己的 --resume"""
            if resume and not re.match(r"^[A-Za-z0-9_:-]{4,128}$", str(resume)):
                return None
            argv = ["codebuddy"] + (["--resume", str(resume)] if resume else [])
            return {"argv": argv,
                    # 输入框下面那行提示出来 = 能输入了
                    "ready": ["? for shortcuts", "shift+tab to cycle", "/ for commands"],
                    # 第一次在这个文件夹里跑会问信不信任它（默认选中的是信任）：用户在 Kiteline 里选了这个项目开任务，回车确认
                    "answers": [{"when": "do you trust the files in this folder", "keys": ["Enter"]},
                                {"when": "trust this folder", "keys": ["Enter"]}],
                    # 没登录时停在选登录方式上：要用户本人在终端里登录，不替他选
                    "needsUser": ["select login method", "log in via"],
                    "settle": 1.0}

        def sessions(self):
            out = []
            now = int(time.time() * 1000)
            for home, brand in homes():
                for path in glob.glob(os.path.join(home, "sessions", "*.json")):
                    record = read_json(path)
                    try:
                        pid, sid = int(record["pid"]), str(record["sessionId"])
                    except (KeyError, TypeError, ValueError):
                        continue
                    # WorkBuddy 进程池里预热好、还没接任务的工作进程：不是会话。WorkBuddy 的工作进程接了任务的也不在这里列：
                    # 那是桌面版的任务，按 workbuddy.db 列（desktop_tasks，带它记的状态；进程跑完就回池子）
                    if record.get("kind") == "prewarm" or sid.startswith("prewarm-") or brand == "WorkBuddy":
                        continue
                    if not kl.pid_alive(pid):
                        continue
                    cwd = record.get("cwd") or ""
                    chat = transcript(home, cwd, sid)
                    note = scan(chat) if chat else scan("")
                    pane = term_pane(pid)
                    text = screen(pane) if pane else None
                    self.pids[sid] = pid
                    pending = note["pending"]
                    question = pending if pending and pending.get("name") == "AskUserQuestion" else None
                    self.pending[sid] = question
                    approval = bool(text and APPROVAL_MARK in text)
                    busy = note["busy"] and now - (note["updated"] or now) < 10 * 60 * 1000 if text is None else (
                        note["busy"] or any(mark in text for mark in BUSY_MARKS))
                    pending_tool = pending_id = waiting = None
                    if question and (text is None or QUESTION_MARK in text):
                        pending_tool, pending_id = "AskUserQuestion", question.get("callId")
                        activity, reason, waiting = "waiting", "等待回答提问", "等待你回答"
                    elif pending and approval:
                        pending_tool, args = pending.get("name") or "tool", args_of(pending)
                        pending_id = pending.get("callId")
                        activity, reason = "waiting", "等待确认：%s" % kl.tool_brief(pending_tool, args)
                        waiting = "等待你确认 %s" % pending_tool
                    elif busy:
                        activity, reason = "busy", ("正在执行 %s" % pending.get("name")) if pending else "正在工作"
                    else:
                        activity, reason = "idle", note["message"]
                    title = (note["title"] or note["first"] or sid[:8])[:60]
                    out.append({
                        "pid": pid, "sessionId": sid, "name": title, "title": title, "cwd": cwd, "cwdShort": kl.display_cwd(cwd),
                        "status": activity, "waitingFor": waiting, "needs": None, "detail": None, "activity": activity,
                        "reason": reason, "activityText": None, "message": note["message"], "messageUuid": note["messageId"],
                        "error": None, "effort": None, "subagents": 0, "pendingTool": pending_tool, "pendingId": pending_id,
                        "startedAt": record.get("startedAt"), "statusUpdatedAt": None, "updatedAt": note["updated"] or now,
                        "version": record.get("version"), "entrypoint": "%s-%s" % (brand.lower(), record.get("kind") or "cli"),
                        "sessionKind": None, "tmuxPane": pane, "usage": None, "transcriptPath": chat,
                        "transcriptUpdatedAt": note["updated"] or now, "agent": "codebuddy", "model": note["model"],
                        "readOnly": not pane, "readOnlyReason": None if pane else READ_ONLY[0],
                        "readOnlyReasonEn": None if pane else READ_ONLY[1],
                    })
            listed = {snap["sessionId"] for snap in out}
            desktop, busy = [], set(self.busy)
            self.busy = set()
            for home, brand in homes():
                if brand == "WorkBuddy":
                    found = self.desktop_tasks(home, listed, now)
                    if found is None:      # 数据库一时读不了：这家的沿用上一次的（任务、忙闲）
                        found = [snap for snap in self._last_desktop.get(home, []) if snap["sessionId"] not in listed]
                        self.busy |= {snap["sessionId"] for snap in found} & busy
                    self._last_desktop[home] = found
                    desktop.extend(found)
            self.desktop = {snap["sessionId"] for snap in desktop}
            return out + desktop

        def pending_options(self, snap):
            if snap.get("readOnly") or snap.get("pendingTool") in ("AskUserQuestion", "ExitPlanMode"):
                return None
            return OPTIONS

        def new_task_targets(self):
            """新任务面板里的「WorkBuddy」：WorkBuddy 开着、这台是 Mac（Windows 还没实测）"""
            if DESKTOP_SEND and any(brand == "WorkBuddy" and os.path.isdir(home) for home, brand in homes()) and self.desktop_running():
                return [{"variant": "workbuddy", "name": "WorkBuddy"}]
            return []

        def new_task(self, variant, cwd, text):
            """WorkBuddy 新建任务：它自己的深链接 workbuddy://task?action=start&prompt=…&cwd=… 把任务填进新任务的输入框，
            电脑端核对 WorkBuddy 在前台后按回车（它的深链接只预填、不自动发送）"""
            ui = set(getattr(self, "host_ui", ()) or ())
            if variant != "workbuddy" or not DESKTOP_SEND:
                raise RuntimeError("HOSTED_UNSUPPORTED：" + DESKTOP_READ_ONLY[0])
            if not {"open", "keys"} <= ui:
                raise RuntimeError("HOSTED_UNSUPPORTED：" + DESKTOP_OLD_HOST)
            if not text:
                raise RuntimeError("请先填写任务内容")
            if len(text) > 8000:     # 它的深链接最多收 8000 字，多的会被截掉：别悄悄丢字
                raise RuntimeError("HOSTED_UNSUPPORTED：任务内容超过 8000 字，WorkBuddy 的新建入口放不下，请精简后再发，或在 WorkBuddy 中直接粘贴")
            url = "workbuddy://task?action=start&prompt=" + quote(text, safe="")
            if cwd and os.path.isdir(cwd):
                url += "&cwd=" + quote(cwd, safe="")
            return {"message": "已在 WorkBuddy 中新建任务", "ui": [
                {"do": "open", "app": "workbuddy", "url": url, "wait": 2500, "fills": True},
                {"do": "key", "name": "enter"},
            ]}

        def send_desktop(self, sid, text, images):
            """WorkBuddy 桌面版的任务：回动作单，电脑端打开 workbuddy://chat/<任务>、核对 WorkBuddy 在前台、粘贴、回车"""
            ui = set(getattr(self, "host_ui", ()) or ())
            if not DESKTOP_SEND:
                raise RuntimeError(DESKTOP_READ_ONLY[0])
            if not {"open", "paste", "keys"} <= ui:
                raise RuntimeError(DESKTOP_OLD_HOST)
            if sid in self.busy:
                raise RuntimeError("WorkBuddy 正在处理这个任务，请等它完成后再发")
            if images:
                text = (text + "\n" + "\n".join(images)).strip()
            if not text:
                raise RuntimeError("消息为空")
            self.sent[sid] = (text, self.user_count(sid))
            return {"message": "已发到 WorkBuddy", "ui": [
                {"do": "open", "app": "workbuddy", "url": "workbuddy://chat/" + quote(sid, safe=""), "wait": 1800},
                {"do": "paste", "text": text},
                {"do": "key", "name": "enter"},
                # 回车之后核对 WorkBuddy 真的收到了（对话记录里多了这句）：输入框没拿到焦点时字会粘丢，不能当成发出去了
                {"do": "plugin", "step": "verify:" + sid},
            ]}

        def user_count(self, sid):
            """这个任务的对话记录里用户说了几句（核对发出去没有用）"""
            for home, brand in homes():
                if brand != "WorkBuddy":
                    continue
                path = transcript(home, "", sid)
                if path:
                    try:
                        with open(path, "rb") as handle:
                            return sum(1 for line in handle if b'"role":"user"' in line or b'"role": "user"' in line)
                    except OSError:
                        return 0
            return 0

        def ui_step(self, sid, step):
            """动作单里的 plugin 这一步：verify = 等 WorkBuddy 的对话记录里出现刚发的这句（最多 12 秒）"""
            if not step.startswith("verify:"):
                raise RuntimeError("不认识的步骤：%s" % step)
            sid = step[len("verify:"):] or sid
            text, before = self.sent.pop(sid, ("", None))
            if before is None:
                return "已发送"
            deadline = time.time() + 12
            while time.time() < deadline:
                if self.user_count(sid) > before:
                    return "WorkBuddy 已收到"
                time.sleep(0.5)
            raise RuntimeError("WorkBuddy 没有收到这条消息（可能它的输入框没拿到焦点），请在电脑上的 WorkBuddy 中查看")

        def _pid(self, sid):
            pid = self.pids.get(sid)
            if pid is None and sid in self.desktop:
                raise RuntimeError(DESKTOP_READ_ONLY[0])
            pane = term_pane(pid) if pid else None
            if not pane:
                raise RuntimeError("这个会话不在 tmux 里运行，只能查看；在 tmux 中启动 codebuddy，或在 Kiteline 新建任务时选择 CodeBuddy Code（由 Kiteline 在后台运行）后，就可以从手机回复和确认")
            return pid, pane

        def send(self, sid, text, images):
            if sid in self.desktop and sid not in self.pids:
                return self.send_desktop(sid, text, images)
            pid, _ = self._pid(sid)
            if images:
                text = (text + "\n" + "\n".join("@" + p for p in images)).strip()
            kl.tmux_send(pid, text, [], True)
            return "已发送"

        def key(self, sid, key):
            pid, pane = self._pid(sid)
            key = str(key).lower()
            if key in ("esc", "escape"):
                kl.tmux_send(pid, "", ["esc"], False)
                return "已发送 Esc"
            if key not in ("1", "2", "3"):
                raise RuntimeError("不支持的选项：%s" % key)
            if APPROVAL_MARK not in (screen(pane) or ""):
                raise RuntimeError("现在没有等待确认的命令")
            kl.tmux_send(pid, "", [key], False)
            return "已选择"

        def answer(self, sid, answers):
            pid, pane = self._pid(sid)
            question = self.pending.get(sid)
            if not question or QUESTION_MARK not in (screen(pane) or ""):
                raise RuntimeError("这个会话现在没有待回答的提问")
            for index, item in enumerate(args_of(question).get("questions") or []):
                labels = [o.get("label") for o in item.get("options") or [] if isinstance(o, dict)]
                picked = kl._answer_for(answers, item.get("question"), index)
                choice = next((p for p in picked if p in labels), None)
                if choice is not None:
                    kl.tmux_send(pid, "", ["down"] * labels.index(choice) + ["enter"], False)
                else:
                    custom = next((p for p in picked if p), None)
                    if not custom:
                        raise RuntimeError("没有选择答案")
                    # 选项之后那一行「Type something」：选中后输入文字再回车
                    kl.tmux_send(pid, "", ["down"] * len(labels), False)
                    time.sleep(0.3)
                    kl.tmux_send(pid, custom, ["enter"], False)
                time.sleep(0.4)
            # 最后一页「Submit answers」：回车提交
            if "Submit answers" in (screen(pane) or ""):
                kl.tmux_send(pid, "", ["enter"], False)
            return "已回答"

        def close(self, sid):
            pid, pane = self._pid(sid)
            text = screen(pane) or ""
            if APPROVAL_MARK in text or QUESTION_MARK in text:
                raise RuntimeError("正在等你确认或回答。请先在卡片中作出选择，再关闭会话")
            kl.tmux_send(pid, "/exit", [], True)
            return "已关闭会话"

        def usage(self, since_ms):
            out = []
            for home, _ in homes():
                for path in kl.recent_files([os.path.join(home, "projects")], ".jsonl", since_ms):
                    out.extend(r for r in kl.cached_usage(path, usage_scan) if r["ts"] + 3600000 > since_ms)
            return out

    return CodeBuddy()
