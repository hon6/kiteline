"""ACP（Agent Client Protocol，Zed 发起的开放协议）：一个插件接一批 agent（11-24）。

ACP 的 agent 是客户端拉起的子进程，标准输入输出上走 JSON-RPC（一行一条）。Kiteline 在这里当客户端：
新任务面板里选「Gemini CLI（ACP）」这类条目 → 插件起 `gemini --experimental-acp` → initialize → session/new → session/prompt；
agent 推来的 session/update（回复的文字分片、思考、工具调用和结果、计划）换成 Kiteline 的对话项；
它要权限时（session/request_permission）会话变成「等你确认」，手机上点允许 / 拒绝就回它选了哪个；读写文件（fs/*）照做。
手机上发的消息 = 下一轮 session/prompt；中断 = session/cancel。

只接「Kiteline 自己新开的任务」：ACP 没有附着到用户已经开着的会话的办法（那些由各家自己的插件读记录）。
会话跟着 watcher 进程：电脑上的 Kiteline 重启后这些子进程会结束，记录还在（存在数据目录），可以在历史里看。
"""
import json
import os
import shutil
import subprocess
import threading
import time

# 支持 ACP 的命令行 agent（命令、参数照各家文档；找得到命令才出现在新任务面板里）。
# 已有专门插件的（Qwen Code、Kimi、CodeBuddy、Cursor、OpenCode……）不在这里重复列：它们能连用户自己开的会话，比 ACP 更全
CATALOG = (
    {"variant": "gemini", "name": "Gemini CLI", "argv": ["gemini", "--experimental-acp"]},
    {"variant": "goose", "name": "Goose", "argv": ["goose", "acp"]},
    {"variant": "copilot", "name": "GitHub Copilot CLI", "argv": ["copilot", "--acp"]},
    {"variant": "auggie", "name": "Augment（Auggie）", "argv": ["auggie", "--acp"]},
    {"variant": "droid", "name": "Factory Droid", "argv": ["droid", "exec", "--output-format", "acp"]},
)
# 实测用：CCPULSE_ACP_TEST=1 时把 OpenCode 的 ACP 入口也列出来（接假模型测协议，见 guide/plugin-development.md）
TEST_EXTRA = ({"variant": "opencode", "name": "OpenCode（ACP）", "argv": ["opencode", "acp"]},)

OPTIONS = ({"key": "reject", "label": "拒绝", "labelEn": "Deny", "style": "destructive"},
           {"key": "allow", "label": "允许", "labelEn": "Allow", "style": "primary"},
           {"key": "always", "label": "总是允许", "labelEn": "Always allow", "style": "normal"})

TOOL_KINDS = {"read": "Read", "edit": "Edit", "delete": "Delete", "move": "Move", "search": "Grep", "execute": "Bash",
              "think": "Think", "fetch": "WebFetch", "switch_mode": "Mode", "other": "Tool"}


def create(kl):
    DATA = os.path.join(kl.DATA_DIR, "plugins", "acp")

    def catalog():
        rows = list(CATALOG)
        if os.environ.get("CCPULSE_ACP_TEST") == "1":
            rows += list(TEST_EXTRA)
        return rows

    def find_command(name):
        finder = getattr(kl, "agent_command", None)
        try:
            return (finder(name) if finder else None) or shutil.which(name)
        except Exception:  # noqa: BLE001
            return shutil.which(name)

    def now_ms():
        return int(time.time() * 1000)

    class Session:
        """一个 ACP 子进程 + 它里面的一个会话"""

        def __init__(self, entry, cwd):
            self.entry = entry
            self.cwd = cwd
            self.sid = "acp-%s-%d" % (entry["variant"], now_ms())
            self.acp_sid = None
            self.items = []          # 对话项（按顺序）
            self.sent = 0            # pump 已推到第几项
            self.changed = set()     # 推过之后又改了的项（文字分片接上、工具结果到了）
            self.busy = False
            self.pending = None      # 等确认：{"rpc": 请求号, "options": [...], "tool": 名, "args": {...}, "callId": ...}
            self.error = None
            self.title = ""
            self.started = now_ms()
            self.updated = self.started
            self.ended = False
            self.lock = threading.RLock()
            self.next_id = 1
            self.waiters = {}        # 请求号 → (事件, 结果框)
            self.tools = {}          # toolCallId → 对话项
            self.text_item = None    # 正在接分片的文字项
            self.n = 0
            argv = [find_command(entry["argv"][0]) or entry["argv"][0]] + entry["argv"][1:]
            os.makedirs(DATA, exist_ok=True)
            self.stderr = open(os.path.join(DATA, self.sid + ".log"), "ab")
            env = dict(os.environ)
            for k in [k for k in env if k.startswith(("CCPULSE_", "KITELINE_", "CLAUDE_CODE_", "VSCODE_"))]:
                env.pop(k, None)
            self.proc = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
                                         env=env, start_new_session=True)
            threading.Thread(target=self.reader, name="acp-read", daemon=True).start()

        # ---------- JSON-RPC ----------
        def write(self, message):
            data = (json.dumps(message, ensure_ascii=False) + "\n").encode("utf-8")
            with self.lock:
                self.proc.stdin.write(data)
                self.proc.stdin.flush()

        def call(self, method, params, timeout=60):
            with self.lock:
                rid = self.next_id
                self.next_id += 1
                event, box = threading.Event(), {}
                self.waiters[rid] = (event, box)
            self.write({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
            if timeout is None:
                return rid
            if not event.wait(timeout):
                raise RuntimeError("%s 没有回应（%s）" % (self.entry["name"], method))
            if "error" in box:
                raise RuntimeError("%s 出错：%s" % (self.entry["name"], (box["error"] or {}).get("message") or box["error"]))
            return box.get("result")

        def notify(self, method, params):
            self.write({"jsonrpc": "2.0", "method": method, "params": params})

        def reply(self, rid, result=None, error=None):
            message = {"jsonrpc": "2.0", "id": rid}
            if error:
                message["error"] = error
            else:
                message["result"] = result
            self.write(message)

        def reader(self):
            for raw in self.proc.stdout:
                try:
                    message = json.loads(raw.decode("utf-8", "replace"))
                except ValueError:
                    continue
                try:
                    self.dispatch(message)
                except Exception as exc:  # noqa: BLE001
                    kl.log("ACP 处理消息出错：%r" % (exc,))
            with self.lock:
                self.ended = True
                self.busy = False
                self.pending = None
                for event, box in self.waiters.values():
                    box["error"] = {"message": "已退出"}
                    event.set()
                self.waiters.clear()
            self.event("%s 已退出" % self.entry["name"])
            self.save()

        def dispatch(self, message):
            if "id" in message and ("result" in message or "error" in message) and "method" not in message:
                with self.lock:
                    waiter = self.waiters.pop(message["id"], None)
                if waiter:
                    event, box = waiter
                    if "error" in message:
                        box["error"] = message["error"]
                    else:
                        box["result"] = message.get("result")
                    event.set()
                return
            method, params = message.get("method"), message.get("params") or {}
            if method == "session/update":
                self.update(params.get("update") or {})
            elif method == "session/request_permission":
                self.ask_permission(message.get("id"), params)
            elif method == "fs/read_text_file":
                self.read_file(message.get("id"), params)
            elif method == "fs/write_text_file":
                self.write_file(message.get("id"), params)
            elif "id" in message:
                self.reply(message["id"], error={"code": -32601, "message": "Kiteline 不支持 %s" % method})

        # ---------- 对话项 ----------
        def add(self, item):
            with self.lock:
                self.n += 1
                item.setdefault("id", "%s.%d" % (self.sid, self.n))
                item.setdefault("ts", now_ms())
                self.items.append(item)
                self.updated = now_ms()
                return item

        def touch(self, item):
            with self.lock:
                if self.items.index(item) < self.sent:
                    self.changed.add(item["id"])
                self.updated = now_ms()

        def event(self, text):
            self.text_item = None
            self.add({"t": "event", "text": text})

        def update(self, u):
            kind = u.get("sessionUpdate")
            content = u.get("content")
            if kind in ("agent_message_chunk", "agent_thought_chunk"):
                text = content.get("text") if isinstance(content, dict) and content.get("type") == "text" else ""
                if not text:
                    return
                t = "text" if kind == "agent_message_chunk" else "thinking"
                with self.lock:
                    if self.text_item and self.text_item["t"] == t:
                        self.text_item["text"] = kl.clip(self.text_item["text"] + text, kl.ASSISTANT_TEXT_MAX)[0]
                        self.touch(self.text_item)
                    else:
                        self.text_item = self.add({"t": t, "text": text})
                return
            self.text_item = None
            if kind == "tool_call":
                name, args = self.tool_of(u)
                item = self.add({"t": "tool", "toolId": u.get("toolCallId"), "name": name, "brief": kl.tool_brief(name, args) or u.get("title") or name,
                                 "input": kl.shrink(args)})
                self.tools[u.get("toolCallId")] = item
                if u.get("status") in ("completed", "failed"):
                    self.result(u)
            elif kind == "tool_call_update":
                # 参数常常在后来的更新里才补全（先只有标题）：摘要跟着改
                item = self.tools.get(u.get("toolCallId"))
                if item and (isinstance(u.get("rawInput"), dict) or u.get("title") or u.get("locations")):
                    merged = dict(u)
                    merged.setdefault("kind", next((k for k, v in TOOL_KINDS.items() if v == item.get("name")), "other"))
                    name, args = self.tool_of(merged)
                    if args:
                        item.update(name=name, brief=kl.tool_brief(name, args) or item.get("brief"), input=kl.shrink(args))
                        self.touch(item)
                if u.get("status") in ("completed", "failed"):
                    self.result(u)
            elif kind == "plan":
                entries = u.get("entries") or []
                todos = [{"content": str(e.get("content") or ""), "status": {"in_progress": "in_progress", "completed": "completed"}.get(e.get("status"), "pending")}
                         for e in entries if isinstance(e, dict)]
                self.add({"t": "tool", "name": "TodoWrite", "brief": "任务清单", "input": {"todos": todos}})
            elif kind == "user_message_chunk":
                pass   # 我们自己发的话已经记过了

        def tool_of(self, u):
            name = TOOL_KINDS.get(u.get("kind") or "other", "Tool")
            raw = u.get("rawInput") if isinstance(u.get("rawInput"), dict) else {}
            args = dict(raw)
            locations = [l.get("path") for l in u.get("locations") or [] if isinstance(l, dict) and l.get("path")]
            if name in ("Read", "Edit", "Delete") and locations and "file_path" not in args:
                args["file_path"] = locations[0]
            if name == "Bash" and "command" not in args and u.get("title"):
                args["command"] = u.get("title")
            if not args and u.get("title"):
                args["description"] = u.get("title")
            return name, args

        def result(self, u):
            parts = []
            for c in u.get("content") or []:
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "content" and isinstance(c.get("content"), dict) and c["content"].get("type") == "text":
                    parts.append(c["content"].get("text") or "")
                elif c.get("type") == "diff":
                    parts.append("改动 %s" % (c.get("path") or ""))
            if not parts and u.get("rawOutput") is not None:
                raw = u.get("rawOutput")
                parts.append(raw if isinstance(raw, str) else json.dumps(raw, ensure_ascii=False)[:4000])
            self.add({"t": "result", "toolId": u.get("toolCallId"), "text": kl.clip("\n".join(parts), kl.TOOL_RESULT_MAX)[0],
                      "isError": u.get("status") == "failed"})

        # ---------- agent 找我们要的 ----------
        def ask_permission(self, rid, params):
            call = params.get("toolCall") or {}
            name, args = self.tool_of(call)
            with self.lock:
                self.pending = {"rpc": rid, "options": params.get("options") or [], "tool": name, "args": args, "callId": call.get("toolCallId")}
                self.updated = now_ms()

        def decide(self, key):
            with self.lock:
                pending, self.pending = self.pending, None
            if not pending:
                raise RuntimeError("这个会话现在没有待确认的操作")
            want = {"allow": ("allow_once",), "always": ("allow_always", "allow_once"), "reject": ("reject_once", "reject_always")}[key]
            option = None
            for kind in want:
                option = next((o for o in pending["options"] if isinstance(o, dict) and o.get("kind") == kind), None)
                if option:
                    break
            if option is None:
                self.reply(pending["rpc"], {"outcome": {"outcome": "cancelled"}})
                return "已取消"
            self.reply(pending["rpc"], {"outcome": {"outcome": "selected", "optionId": option.get("optionId")}})
            return "已拒绝" if key == "reject" else "已允许"

        def read_file(self, rid, params):
            path = params.get("path") or ""
            try:
                if not os.path.isabs(path):
                    raise ValueError("要绝对路径")
                with open(path, encoding="utf-8", errors="replace") as handle:
                    lines = handle.read().splitlines(True)
                start = max(0, int(params.get("line") or 1) - 1)
                limit = params.get("limit")
                chunk = lines[start:start + int(limit)] if limit else lines[start:]
                self.reply(rid, {"content": "".join(chunk)})
            except Exception as exc:  # noqa: BLE001
                self.reply(rid, error={"code": -32000, "message": str(exc)})

        def write_file(self, rid, params):
            path = params.get("path") or ""
            try:
                if not os.path.isabs(path):
                    raise ValueError("要绝对路径")
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write(params.get("content") or "")
                self.reply(rid, None)
            except Exception as exc:  # noqa: BLE001
                self.reply(rid, error={"code": -32000, "message": str(exc)})

        # ---------- 我们这边的操作 ----------
        def start(self, prompt):
            init = self.call("initialize", {"protocolVersion": 1, "clientCapabilities": {"fs": {"readTextFile": True, "writeTextFile": True}, "terminal": False},
                                            "clientInfo": {"name": "Kiteline", "version": str(getattr(kl, "WATCHER_VERSION", "") or "")}}, timeout=40)
            self.agent_info = (init or {}).get("agentInfo") or {}
            result = self.call("session/new", {"cwd": self.cwd, "mcpServers": []}, timeout=60)
            self.acp_sid = (result or {}).get("sessionId")
            if not self.acp_sid:
                raise RuntimeError("%s 没有建出会话" % self.entry["name"])
            if prompt:
                self.prompt(prompt)

        def prompt(self, text):
            if self.ended:
                raise RuntimeError("%s 已退出，请重新新建任务" % self.entry["name"])
            if self.busy:
                raise RuntimeError("%s 正在执行，这一轮做完才能发下一条（可以先中断）" % self.entry["name"])
            text = text.strip()
            if not self.title:
                self.title = " ".join(text.split())[:60]
            self.text_item = None
            self.add({"t": "user", "text": kl.clip(text, kl.USER_TEXT_MAX)[0]})
            self.busy = True
            self.error = None

            def run():
                try:
                    result = self.call("session/prompt", {"sessionId": self.acp_sid, "prompt": [{"type": "text", "text": text}]}, timeout=24 * 3600)
                    reason = (result or {}).get("stopReason")
                    if reason == "cancelled":
                        self.event("已中断")
                    elif reason in ("max_tokens", "max_turn_requests", "refusal"):
                        self.event({"max_tokens": "回复达到长度上限", "max_turn_requests": "达到单轮请求上限", "refusal": "模型拒绝了这个请求"}[reason])
                except Exception as exc:  # noqa: BLE001
                    self.error = str(exc)
                    self.event(str(exc))
                finally:
                    with self.lock:
                        self.busy = False
                        self.pending = None
                        self.text_item = None
                        self.updated = now_ms()
                    self.save()
            threading.Thread(target=run, name="acp-prompt", daemon=True).start()

        def cancel(self):
            if not self.busy:
                return "当前没有进行中的任务"
            with self.lock:
                pending, self.pending = self.pending, None
            if pending:
                self.reply(pending["rpc"], {"outcome": {"outcome": "cancelled"}})
            self.notify("session/cancel", {"sessionId": self.acp_sid})
            return "已中断"

        def close(self):
            try:
                self.proc.terminate()
                self.proc.wait(timeout=5)
            except Exception:  # noqa: BLE001
                try:
                    self.proc.kill()
                except Exception:  # noqa: BLE001
                    pass
            return "已结束"

        def save(self):
            try:
                with open(os.path.join(DATA, self.sid + ".json"), "w", encoding="utf-8") as handle:
                    json.dump({"entry": self.entry, "cwd": self.cwd, "title": self.title, "items": self.items[-2000:]}, handle, ensure_ascii=False)
            except (OSError, ValueError):
                pass

        def snapshot(self):
            with self.lock:
                pending = self.pending
                last = next((i for i in reversed(self.items) if i["t"] == "text"), None)
                if pending:
                    activity = "waiting"
                    reason = "等待确认：%s" % (kl.tool_brief(pending["tool"], pending["args"]) or pending["tool"])
                elif self.busy:
                    activity, reason = "busy", "正在工作"
                else:
                    activity, reason = "idle", (last["text"][:200] if last else None)
                title = self.title or self.entry["name"]
                return {
                    "pid": self.proc.pid, "sessionId": self.sid, "name": title, "title": title, "cwd": self.cwd, "cwdShort": kl.display_cwd(self.cwd),
                    "status": activity, "waitingFor": ("等待你确认 %s" % pending["tool"]) if pending else None, "needs": None, "detail": None,
                    "activity": activity, "reason": reason, "activityText": None, "message": last["text"][:400] if last else None,
                    "messageUuid": last["id"] if last else None, "error": self.error, "effort": None, "subagents": 0,
                    "pendingTool": pending["tool"] if pending else None, "pendingId": pending["callId"] if pending else None,
                    "startedAt": self.started, "statusUpdatedAt": self.updated, "updatedAt": self.updated, "version": None,
                    "entrypoint": "acp-" + self.entry["variant"], "sessionKind": None, "tmuxPane": None, "usage": None,
                    "transcriptPath": None, "transcriptUpdatedAt": self.updated, "agent": "acp",
                    "agentName": self.entry["name"], "model": None, "readOnly": self.ended,
                    "readOnlyReason": ("%s 已退出：请重新新建任务" % self.entry["name"]) if self.ended else None,
                    "readOnlyReasonEn": ("%s has exited. Start a new task to continue." % self.entry["name"]) if self.ended else None,
                }

    class Acp(kl.AgentPlugin):
        name = "ACP"

        def __init__(self):
            self.live = {}   # 会话 id → Session

        def detect(self):
            found = [e for e in catalog() if find_command(e["argv"][0])]
            return {"installed": bool(found), "forms": {"cli": ""} if found else {}}

        def abilities(self):
            return ["view", "reply", "approve", "interrupt"]

        def new_task_targets(self):
            """新任务面板里的条目：找得到命令的 ACP agent（Windows 还没实测，不列）"""
            if os.name == "nt":
                return []
            return [{"variant": e["variant"], "name": e["name"] + "（ACP）" if "ACP" not in e["name"] else e["name"]}
                    for e in catalog() if find_command(e["argv"][0])]

        def new_task(self, variant, cwd, text):
            entry = next((e for e in catalog() if e["variant"] == variant), None)
            if not entry or not find_command(entry["argv"][0]):
                raise RuntimeError("HOSTED_NO_AGENT：这台电脑上没有找到 %s" % (entry["name"] if entry else variant))
            if not cwd or not os.path.isdir(cwd):
                raise RuntimeError("项目目录不存在：%s" % cwd)
            session = Session(entry, cwd)
            try:
                session.start(text)
            except Exception:
                session.close()
                raise
            self.live[session.sid] = session
            return {"message": "已在后台新建 %s 会话%s" % (entry["name"], "并提交" if text else "")}

        def sessions(self):
            # 结束超过 10 分钟的不再列在「进行中」（记录在数据目录里）
            cutoff = now_ms() - 600000
            for sid in [s for s, x in self.live.items() if x.ended and x.updated < cutoff]:
                self.live.pop(sid, None)
            return [s.snapshot() for s in list(self.live.values())]

        def pump(self):
            out = []
            for sid, s in list(self.live.items()):
                with s.lock:
                    fresh = s.items[s.sent:]
                    redo = [i for i in s.items[:s.sent] if i["id"] in s.changed]
                    s.sent = len(s.items)
                    s.changed.clear()
                    batch = [dict(i) for i in redo + fresh]
                if batch:
                    out.append((sid, batch))
            return out

        def history(self, sid, before, limit):
            s = self.live.get(sid)
            items = [dict(i) for i in s.items] if s else []
            if before is not None:
                index = next((n for n, item in enumerate(items) if item["id"] == str(before)), len(items))
                items = items[:index]
            return items[-limit:], len(items) > limit

        def _session(self, sid):
            s = self.live.get(sid)
            if not s:
                raise RuntimeError("这个会话已经结束")
            return s

        def send(self, sid, text, images):
            s = self._session(sid)
            if images:
                text = (text + "\n" + "\n".join("@" + p for p in images)).strip()
            s.prompt(text)
            return "已发送"

        def pending_options(self, snap):
            return OPTIONS if snap.get("pendingTool") and not snap.get("readOnly") else None

        def key(self, sid, key):
            s = self._session(sid)
            key = str(key).lower()
            if key in ("esc", "escape"):
                # 等确认时的 esc = 拒绝（老客户端的通用审批键），否则是中断
                return s.decide("reject") if s.pending else s.cancel()
            if key in ("allow", "always", "reject"):
                return s.decide(key)
            # 老客户端发的通用审批键（同 APPROVAL_OPTIONS）
            if key in ("1", "2"):
                return s.decide("allow" if key == "1" else "always")
            raise RuntimeError("不支持的选项：%s" % key)

        def close(self, sid):
            s = self._session(sid)
            message = s.close()
            self.live.pop(sid, None)
            return message

    return Acp()
