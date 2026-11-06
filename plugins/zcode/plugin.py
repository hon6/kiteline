"""ZCode（智谱的 agent 编程桌面应用 + 命令行 zcode，开源 github.com/zai-org/ZCode）：单独下发的插件，只读。

11-05 对 ZCode 3.17.2（Linux AppImage，自带的命令行 zcode 0.17.1）实测（隔离 HOME + 假模型，个人模型配置
~/.zcode/v2/provider_config.json 按官方文档 03-config 的格式写，不用登录）：
  ~/.zcode/cli/db/db.sqlite（桌面版和命令行共用；ZCODE_HOME / ZCODE_DATA_BASE_DIR 改目录），表结构同 OpenCode：
    session   id（sess_…）、directory、title、time_created / time_updated（毫秒）、time_archived、time_deleted、parent_id、last_outcome
    message   id、session_id、data（JSON：role、time.created / completed、modelId、metadata.visibility = model-only 的是给模型看的系统消息）
    part      message_id、session_id、data（JSON：text / reasoning / tool（callID、tool、state.status/input/output/error）/ step-finish（tokens））
    model_usage  每次请求一行：provider_id、model_id、started_at、input_tokens（含读缓存）、output_tokens、cache_read_input_tokens、cache_creation_input_tokens
  工具名同 Claude Code（Bash、Edit、Read、AskUserQuestion……）。
操作（1.1.0 起，11-05 实测）：ZCode 自带的命令行有后台服务 `zcode app-server --stdio`（一行一个 JSON，社区桥 zcode-acp 也接它）。
  插件自己起一个（优先 PATH 上的 zcode；没有就用桌面版自带的 resources/glm/zcode.cjs，以 ELECTRON_RUN_AS_NODE=1 跑 ZCode 程序本身），
  session/resume + session/subscribe 后 session/send 发消息、session/stop 中断；这一轮在我们的进程里跑，它的
  interaction/requestPermission（回选项自带的 response，即 {"decision": …}）和 interaction/requestUserInput（回
  {"action": "accept", "content": {"answer_0": …}}）都发给我们，手机上确认、回答。必须应答 session/requestRuntimePreferences。
  局限：电脑上 ZCode 窗口里自己发起的那一轮在桌面版进程里，它的确认只弹在电脑上；手机发起的这一轮，电脑上的窗口可能要重新打开对话才看得到。
  这些在对话里插一条灰色小提示告诉用户（11-05 起：提示清楚就行）。
额度：GLM Coding Plan（5 小时 + 每周）只能在智谱网页上看，本机不记。
"""
import json
import os
import re
import sqlite3
import subprocess
import threading
import time
from urllib.request import pathname2url

RECENT_MS = 12 * 3600 * 1000      # 开着 ZCode 时，列出最近 12 小时动过的会话
MAX_SESSIONS = 8
PROCESS = re.compile(r"(?i)(ZCode\.app/|ZCode\.exe|/zcode(\.cjs)?(\s|$)|zcode-(linux|darwin|windows)|/squashfs-root/zcode|\.mount_ZCode)")
READ_ONLY = ("这台电脑上找不到 ZCode 的命令行程序（zcode 或桌面版自带的那份），会话只能查看；请在电脑上的 ZCode 中回复和确认",
             "Couldn't find ZCode's command-line program on this computer (zcode or the copy bundled with the desktop app), so sessions are view-only. Reply and confirm in ZCode on your computer.")
HINT_SENT = ("从手机发的这一轮在 Kiteline 后台运行：这一轮要确认的命令、要回答的提问会出现在手机上。电脑上的 ZCode 窗口不会实时显示这一轮，退出 ZCode 再打开就能看到；在电脑上发起的那一轮，请在电脑上确认。",
             "This turn from your phone runs in the background through Kiteline: commands to confirm and questions to answer in this turn show up on your phone. The ZCode window on your computer doesn't show this turn as it happens; quit and reopen ZCode to see it. For turns started on your computer, confirm on your computer.")
ACCOUNT = ("这个对话用的是 ZCode 账号登录的模型：它要由 ZCode 桌面版提供登录状态，Kiteline 不读 ZCode 的登录凭证，所以只能查看，请在电脑上的 ZCode 中回复。"
           "在 ZCode 设置里用 API Key 添加的模型可以从手机操作",
           "This conversation uses a model from your ZCode account sign-in, which needs the ZCode desktop app's sign-in; Kiteline doesn't read "
           "ZCode's sign-in credentials, so it's view-only. Reply in ZCode on your computer. Models added with an API key in ZCode's settings can be controlled from your phone.")
FAILED = ("从手机发起的这一轮没能完成（ZCode：%s）", "The turn started from your phone didn't finish (ZCode: %s)")
IDLE_STOP = 15 * 60   # 后台服务没有在跑的这一轮、空闲这么久就关掉


def create(kl):
    def ps_text():
        """「进程号 命令行」一行一个：中台的跨平台进程列举（HOST_CAPS proc.list，Windows 也行）；老中台退回 ps"""
        if hasattr(kl, "process_list"):
            return "\n".join("%d %s" % (p["pid"], p["cmd"]) for p in kl.process_list())
        try:
            return subprocess.run(["ps", "-axww", "-o", "pid=,command="], capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            return ""

    if os.environ.get("ZCODE_HOME"):
        HOME = os.environ["ZCODE_HOME"]
    elif os.environ.get("ZCODE_DATA_BASE_DIR"):
        HOME = os.environ["ZCODE_DATA_BASE_DIR"]
    else:
        HOME = os.path.join(kl.HOME, ".zcode")
    DB = os.path.join(HOME, "cli", "db", "db.sqlite")

    def query(sql, args=()):
        if not os.path.isfile(DB):
            return []
        db = sqlite3.connect("file:%s?mode=ro" % pathname2url(DB), uri=True, timeout=2)
        try:
            db.row_factory = sqlite3.Row
            return [dict(r) for r in db.execute(sql, args)]
        finally:
            db.close()

    def load(text):
        try:
            value = json.loads(text or "{}")
            return value if isinstance(value, dict) else {}
        except ValueError:
            return {}

    def account_model(recent):
        """最近一条带模型的消息用的是不是 ZCode 账号登录的模型（providerId 以 account: 开头）"""
        for message in reversed(recent):
            info = message["info"]
            model = info.get("model") if isinstance(info.get("model"), dict) else {}
            provider = info.get("providerId") or model.get("providerID") or model.get("providerId")
            if provider:
                return str(provider).startswith("account:")
        return False

    def messages(sid, limit=None, before=None):
        """会话的消息（升序），拼成 OpenCode 接口的格式 {info, parts}，去掉只给模型看的系统消息"""
        sql = "select id, data, time_created from message where session_id = ?"
        args = [sid]
        if before is not None:
            sql += " and time_created < ?"
            args.append(int(before))
        sql += " order by time_created desc, sequence desc"
        if limit:
            sql += " limit %d" % int(limit)
        rows = list(reversed(query(sql, tuple(args))))
        if not rows:
            return []
        ids = [r["id"] for r in rows]
        parts = {}
        for row in query("select message_id, id, data from part where message_id in (%s) order by time_created, sequence"
                         % ",".join("?" * len(ids)), tuple(ids)):
            parts.setdefault(row["message_id"], []).append(dict(load(row["data"]), id=row["id"]))
        out = []
        for row in rows:
            info = dict(load(row["data"]), id=row["id"], sessionID=sid)
            meta = info.get("metadata") if isinstance(info.get("metadata"), dict) else {}
            if info.get("role") == "user" and (meta.get("visibility") == "model-only" or meta.get("runtimeMessage")):
                continue
            info.setdefault("time", {}).setdefault("created", row["time_created"])
            out.append({"info": info, "parts": parts.get(row["id"], [])})
        return out

    def running():
        try:
            out = ps_text()
        except (OSError, subprocess.SubprocessError):
            return False
        return any(PROCESS.search(line) for line in out.splitlines())


    def server_command():
        """起后台服务的命令：ZCODE_BIN → PATH 上的 zcode → 桌面版自带的 zcode.cjs（用 ZCode 程序本身当 Node 跑）"""
        import shutil
        env = {}
        found = os.environ.get("ZCODE_BIN") or shutil.which("zcode")
        if found:
            if found.endswith(".cjs"):
                node = shutil.which("node")
                return ([node, found] if node else None), env
            return [found], env
        def mac_app(app):
            return (os.path.join(app, "Contents", "MacOS", "ZCode"), os.path.join(app, "Contents", "Resources", "glm", "zcode.cjs"))
        candidates = [mac_app("/Applications/ZCode.app"), mac_app(os.path.expanduser("~/Applications/ZCode.app"))]
        if os.environ.get("LOCALAPPDATA"):
            base = os.path.join(os.environ["LOCALAPPDATA"], "Programs", "ZCode")
            candidates.append((os.path.join(base, "ZCode.exe"), os.path.join(base, "resources", "glm", "zcode.cjs")))
        # 正在运行的桌面版（Linux AppImage 解开在 /tmp/.mount_ZCode…）：程序旁边的 resources/glm/zcode.cjs；
        # Mac 上程序在 ZCode.app/Contents/MacOS/，脚本在 Contents/Resources/glm/
        for line in ps_text().splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2 and PROCESS.search(parts[1]):
                command = parts[1].strip()
                exe = command[1:command.find('"', 1)] if command.startswith('"') else command.split()[0]
                if "/Contents/MacOS/" in exe:
                    candidates.append(mac_app(exe.split("/Contents/MacOS/")[0]))
                else:
                    candidates.append((exe, os.path.join(os.path.dirname(exe), "resources", "glm", "zcode.cjs")))
        for exe, script in candidates:
            if os.path.isfile(exe) and os.path.isfile(script):
                env = {"ELECTRON_RUN_AS_NODE": "1"}
                # 桌面版自带的命令行找不到内置服务商配置（它在 resources/config/provider/，桌面版启动它时用环境变量指过去），
                # 照桌面版的做法指给它，否则报「无法定位 CLI ZCode Built-in Provider Config」
                builtin = os.path.join(os.path.dirname(os.path.dirname(script)), "config", "provider", "zcode-builtin.json")
                if not os.environ.get("ZCODE_BUILTIN_PROVIDER_CONFIG_FILE") and os.path.isfile(builtin):
                    env["ZCODE_BUILTIN_PROVIDER_CONFIG_FILE"] = builtin
                return [exe, script], env
        return None, env

    class Server:
        """自己起的 zcode app-server（一行一个 JSON 问答）。会话 resume + subscribe 一次；
        这一轮的确认、提问记在 pending 里等手机回答"""

        def __init__(self):
            self.proc = None
            self.lock = threading.Lock()
            self.next_id = 0
            self.waiters = {}      # 请求 id → [Event, 回答]
            self.joined = set()    # 已 resume + subscribe 的会话
            self.pending = {}      # 会话 id → {"id", "kind": permission / question, "params"}
            self.own = set()       # 我们发起、还没结束的那一轮所在的会话
            self.failed = {}       # 会话 id → 从手机发起的那一轮失败的原因（插件推成灰色小提示）
            self.used = time.time()

        def available(self):
            return server_command()[0] is not None

        def start(self):
            if self.proc and self.proc.poll() is None:
                return
            cmd, extra = server_command()
            if not cmd:
                raise RuntimeError(READ_ONLY[0])
            env = dict(os.environ, **extra)
            if os.environ.get("ZCODE_HOME", "").rstrip("/\\").endswith(".zcode"):
                env["HOME"] = os.path.dirname(os.environ["ZCODE_HOME"].rstrip("/\\"))   # 测试用的隔离目录
            kwargs = {"creationflags": 0x08000000} if os.name == "nt" else {}
            self.proc = subprocess.Popen(cmd + ["app-server", "--stdio"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                         stderr=subprocess.DEVNULL, text=True, encoding="utf-8", bufsize=1, env=env, **kwargs)
            self.joined.clear()
            self.pending.clear()
            self.own.clear()
            threading.Thread(target=self._read, args=(self.proc,), daemon=True).start()

        def _write(self, obj):
            self.proc.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n")
            self.proc.stdin.flush()

        def request(self, method, params, timeout=30):
            with self.lock:
                self.start()
                self.next_id += 1
                rid = self.next_id
                waiter = [threading.Event(), None]
                self.waiters[rid] = waiter
                self._write({"id": rid, "method": method, "params": params})
            self.used = time.time()
            if not waiter[0].wait(timeout):
                self.waiters.pop(rid, None)
                raise RuntimeError("ZCode 后台服务没有回应（%s）" % method)
            reply = waiter[1] or {}
            if reply.get("error"):
                raise ServerError(reply["error"])
            return reply.get("result")

        def answer(self, rid, result=None, error=None):
            with self.lock:
                if self.proc and self.proc.poll() is None:
                    self._write({"id": rid, "error": error} if error else {"id": rid, "result": result})
            self.used = time.time()

        def _read(self, proc):
            for line in proc.stdout:
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                method = msg.get("method")
                params = msg.get("params") if isinstance(msg.get("params"), dict) else {}
                if method is None and msg.get("id") in self.waiters:
                    waiter = self.waiters.pop(msg["id"])
                    waiter[1] = msg
                    waiter[0].set()
                elif method == "session/requestRuntimePreferences" and "id" in msg:
                    self.answer(msg["id"], {"nativeSearchEnhancementsEnabled": False, "memoryEnabled": False,
                                            "askUserQuestionAutoResolutionEnabled": False})
                elif method == "interaction/requestPermission" and "id" in msg:
                    self.pending[params.get("sessionId")] = {"id": msg["id"], "kind": "permission", "params": params}
                elif method == "interaction/requestUserInput" and "id" in msg:
                    self.pending[params.get("sessionId")] = {"id": msg["id"], "kind": "question", "params": params}
                elif "id" in msg and method:   # 别的反向请求（官方插件的登录头、浏览器……）：我们给不了
                    self.answer(msg["id"], error={"code": -32601, "message": "unavailable in Kiteline"})
                elif method == "session/event":
                    kind = params.get("type")
                    sid = params.get("sessionId")
                    if kind == "permission.resolved":
                        if (self.pending.get(sid) or {}).get("params", {}).get("requestId") == (params.get("payload") or {}).get("requestId"):
                            self.pending.pop(sid, None)
                    elif kind in ("turn.completed", "turn.failed", "turn.terminal"):
                        payload = params.get("payload") if isinstance(params.get("payload"), dict) else {}
                        if kind == "turn.failed" and sid in self.own:
                            error = payload.get("error")
                            error = error.get("message") if isinstance(error, dict) else error
                            self.failed[sid] = str(error or payload.get("message") or payload.get("reason") or "unknown")[:200]
                        self.own.discard(sid)
                        self.pending.pop(sid, None)
            for waiter in list(self.waiters.values()):
                waiter[0].set()

        def join(self, sid, cwd):
            if sid in self.joined and self.proc and self.proc.poll() is None:
                return
            workspace = {"workspacePath": cwd, "workspaceKey": cwd}
            self.request("session/resume", {"sessionId": sid, "workspace": workspace})
            self.request("session/subscribe", {"sessionId": sid, "deliveryKind": "desktop-continuous", "includeSnapshot": False,
                                               "afterSeq": 0})
            self.joined.add(sid)

        def idle_stop(self):
            if self.proc and self.proc.poll() is None and not self.own and not self.pending and time.time() - self.used > IDLE_STOP:
                self.proc.terminate()
                self.proc = None

    class ServerError(RuntimeError):
        def __init__(self, error):
            super().__init__(str((error or {}).get("message") or error))
            self.code = (error or {}).get("code")

    SERVER = Server()

    class ZCode(kl.AgentPlugin):
        name = "ZCode"

        def __init__(self):
            self.last = {}    # 会话 id → 推到的最新消息时间
            self.hints = {}   # 会话 id → 待推的灰色小提示
            self.hinted = set()   # 已提示过的会话
            self.cwds = {}    # 会话 id → 工作目录

        def detect(self):
            import shutil
            forms = {}
            if shutil.which("zcode"):
                forms["cli"] = ""
            if os.path.isdir(HOME):
                forms["desktop"] = ""
            return {"installed": bool(forms), "forms": forms}

        def sessions(self):
            SERVER.idle_stop()
            if not running() and not SERVER.own:
                self.last.clear()
                return []
            can_act = SERVER.available()
            now = int(time.time() * 1000)
            rows = query("select * from session where parent_id is null and time_archived is null and time_deleted is null "
                         "and time_updated > ? order by time_updated desc limit ?", (now - RECENT_MS, MAX_SESSIONS))
            out = []
            for session in rows:
                sid = session["id"]
                recent = messages(sid, 30)
                items = kl.opencode_items(recent)
                last_user = next((m for m in reversed(recent) if m["info"].get("role") == "user"), None)
                last_reply = next((m for m in reversed(recent) if m["info"].get("role") == "assistant"), None)
                text = next((i for i in reversed(items) if i["t"] == "text"), None)
                running_tool = None
                for message in recent[-3:]:
                    for part in message["parts"]:
                        state = part.get("state") if isinstance(part.get("state"), dict) else {}
                        if part.get("type") == "tool" and state.get("status") in ("pending", "running"):
                            running_tool = part.get("tool")
                replying = last_reply is not None and not (last_reply["info"].get("time") or {}).get("completed")
                asked = last_user is not None and (last_reply is None or
                                                   last_user["info"]["time"]["created"] > last_reply["info"]["time"]["created"])
                busy = (replying or asked or running_tool) and now - int(session.get("time_updated") or 0) < 10 * 60 * 1000
                pending = SERVER.pending.get(sid)
                self.cwds[sid] = session.get("directory") or ""
                pending_tool = pending_id = waiting = None
                if pending:
                    params = pending["params"]
                    pending_id = params.get("toolCallId")
                    if pending["kind"] == "question":
                        pending_tool = "AskUserQuestion"
                        activity, reason, waiting = "waiting", "等待回答提问", "等待你回答"
                    else:
                        pending_tool = params.get("toolName") or "Bash"
                        brief = kl.tool_brief(pending_tool, params.get("input") if isinstance(params.get("input"), dict) else {})
                        activity, reason, waiting = "waiting", "等待确认：%s" % brief, "等待你确认 %s" % pending_tool
                elif busy and running_tool and sid not in SERVER.own:
                    # 电脑上发起的那一轮：它要确认的话只弹在电脑上，这里看不出是在跑还是在等
                    activity, reason = "busy", "正在执行 %s（电脑上发起的这一轮，如需确认请在电脑上操作）" % running_tool
                elif busy:
                    activity, reason = "busy", ("正在执行 %s" % running_tool) if running_tool else "正在工作"
                else:
                    activity, reason = "idle", text["text"] if text else None
                model = (last_reply or {}).get("info", {}).get("modelId")
                account = account_model(recent)
                title = (session.get("title") or sid)[:60]
                cwd = session.get("directory") or ""
                if recent:
                    self.last.setdefault(sid, recent[-1]["info"]["time"]["created"])
                out.append({
                    "pid": None, "sessionId": sid, "name": title, "title": title, "cwd": cwd, "cwdShort": kl.display_cwd(cwd),
                    "status": activity, "waitingFor": waiting, "needs": None, "detail": None, "activity": activity, "reason": reason,
                    "activityText": None, "message": text["text"] if text else None, "messageUuid": text["id"] if text else None,
                    "error": None, "effort": None, "subagents": 0, "pendingTool": pending_tool, "pendingId": pending_id,
                    "startedAt": session.get("time_created"), "statusUpdatedAt": None, "updatedAt": session.get("time_updated"),
                    "version": session.get("version"), "entrypoint": "zcode", "sessionKind": None, "tmuxPane": None,
                    "usage": None, "transcriptPath": None, "transcriptUpdatedAt": session.get("time_updated"),
                    "agent": "zcode", "model": model,
                    "readOnly": not can_act or account, "readOnlyReason": None if can_act and not account else (READ_ONLY if not can_act else ACCOUNT)[0],
                    "readOnlyReasonEn": None if can_act and not account else (READ_ONLY if not can_act else ACCOUNT)[1],
                })
            return out

        def pump(self):
            out = []
            for sid, last in list(self.last.items()):
                try:
                    recent = messages(sid, 12)
                except sqlite3.Error:
                    continue
                if not recent:
                    continue
                # 正在写的那条（分片还在更新）也要推：从最后一条已推的消息起重出，客户端按 id 覆盖
                fresh = [m for m in recent if m["info"]["time"]["created"] >= last]
                items = kl.opencode_items(fresh)
                self.last[sid] = recent[-1]["info"]["time"]["created"]
                if items:
                    out.append((sid, items))
            for sid, error in list(SERVER.failed.items()):
                stamp = int(time.time() * 1000)
                self.hints.setdefault(sid, []).append({"id": "kl-fail-%d" % stamp, "ts": stamp, "t": "event", "text": FAILED[0] % error})
                SERVER.failed.pop(sid, None)
            for sid, hints in list(self.hints.items()):
                if hints:
                    out.append((sid, hints))
                self.hints.pop(sid, None)
            return out

        def pending_options(self, snap):
            pending = SERVER.pending.get(snap.get("sessionId"))
            if not pending or pending["kind"] != "permission":
                return None
            styles = {"allow_once": "primary", "deny_once": "destructive", "reject_once": "destructive", "deny": "destructive"}
            out = []
            for option in pending["params"].get("options") or []:
                kind = str(option.get("kind") or "")
                label = option.get("name") or option.get("optionId")
                key = str(option.get("optionId") or "")
                zh = {"allow_once": "允许一次", "allow_project": "在这个项目中总是允许", "allow_always": "总是允许",
                      "allow_session": "本会话总是允许", "deny": "拒绝", "deny_once": "拒绝", "reject_once": "拒绝",
                      "reject_always": "总是拒绝"}.get(key) or {"allow_once": "允许一次", "allow_always": "总是允许",
                                                           "deny_once": "拒绝", "reject_once": "拒绝"}.get(kind, label)
                style = styles.get(key) or styles.get(kind) or ("destructive" if "deny" in key or "reject" in kind else "normal")
                out.append({"key": key, "label": zh, "labelEn": label, "style": style})
            # 拒绝放最前（同其他插件的按钮顺序）
            out.sort(key=lambda o: 0 if o["style"] == "destructive" else (1 if o["style"] == "primary" else 2))
            return out or None

        def send(self, sid, text, images):
            if images:
                text = (text + "\n" + "\n".join("@" + p for p in images)).strip()
            if account_model(messages(sid, 30)):
                raise RuntimeError(ACCOUNT[0])
            SERVER.join(sid, self.cwds.get(sid) or "")
            busy = sid in SERVER.own
            SERVER.own.add(sid)    # 先记下：模型起不来时 turn.failed 可能比 send 的回应先到
            try:
                SERVER.request("session/send", {"sessionId": sid, "content": text})
            except Exception as exc:
                if not busy:
                    SERVER.own.discard(sid)
                if isinstance(exc, ServerError) and exc.code in (1308, -32010):   # -32010：这个会话已有一轮在跑
                    if busy:
                        raise RuntimeError("从手机发起的上一轮还没结束（可能在等你确认）：先确认或中断它，再发新消息")
                    raise RuntimeError("ZCode 正在处理电脑上发起的这一轮，等它结束后再发")
                raise
            if sid not in self.hinted:    # 每个会话只提示一次
                self.hinted.add(sid)
                stamp = int(time.time() * 1000)
                self.hints.setdefault(sid, []).append({"id": "kl-hint-%d" % stamp, "ts": stamp, "t": "event", "text": HINT_SENT[0]})
            return "已发送"

        def key(self, sid, key):
            if str(key).lower() in ("esc", "escape"):
                if sid not in SERVER.own:
                    raise RuntimeError("这一轮是在电脑上发起的，请在电脑上的 ZCode 中停止")
                SERVER.request("session/stop", {"sessionId": sid}, timeout=10)
                return "已中断"
            pending = SERVER.pending.get(sid)
            if not pending or pending["kind"] != "permission":
                raise RuntimeError("ZCode 现在没有等你确认的操作（电脑上发起的那一轮请在电脑上确认）")
            option = next((o for o in pending["params"].get("options") or [] if o.get("optionId") == key), None)
            if not option:
                raise RuntimeError("不支持的选项：%s" % key)
            response = option.get("response") or {"decision": "deny" if "deny" in key or "reject" in key else "allow"}
            SERVER.answer(pending["id"], response)
            SERVER.pending.pop(sid, None)
            return "已选择"

        def answer(self, sid, answers):
            pending = SERVER.pending.get(sid)
            if not pending or pending["kind"] != "question":
                raise RuntimeError("ZCode 现在没有待回答的提问（电脑上发起的那一轮请在电脑上回答）")
            content = {}
            for index, item in enumerate(pending["params"].get("questions") or []):
                picked = [p for p in kl._answer_for(answers, item.get("question"), index) if p]
                if not picked:
                    raise RuntimeError("没有选择答案")
                content["answer_%d" % index] = ", ".join(picked)
            SERVER.answer(pending["id"], {"action": "accept", "content": content})
            SERVER.pending.pop(sid, None)
            return "已回答"

        def history(self, sid, before, limit):
            count = max(1, limit // 3)
            try:
                bound = int(str(before).split(".")[0]) if before is not None else None
            except ValueError:
                bound = None
            rows = messages(sid, count + 1, bound)
            has_more = len(rows) > count
            return kl.opencode_items(rows[-count:]), has_more

        def usage(self, since_ms):
            out, buckets = [], {}
            try:
                rows = query("select u.*, s.directory as cwd from model_usage u left join session s on s.id = u.session_id "
                             "where u.started_at >= ?", (int(since_ms) - 3600000,))
            except sqlite3.Error:
                rows = []
            for row in rows:
                cached = int(row.get("cache_read_input_tokens") or 0)
                values = (max(0, int(row.get("input_tokens") or 0) - cached), row.get("output_tokens"), cached,
                          row.get("cache_creation_input_tokens"), 1)
                kl.usage_bucket(buckets, int(row["started_at"]), row.get("model_id") or "unknown", values,
                                cwd=row.get("cwd"), session=row.get("session_id"))
            out.extend(buckets.values())
            return out

    return ZCode()
