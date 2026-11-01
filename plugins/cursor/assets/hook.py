"""Kiteline 装进 Cursor 的 hook：Cursor（编辑器和命令行 agent 都是）每走一步就把这一步的 JSON 从标准输入交给我们。

装在 ~/.cursor/hooks/kiteline/hook.py，由 ~/.cursor/hooks.json 里命令带这个路径的几条调起（停用插件时按路径删干净）。
只记录、不拦截：要表态的几种（preToolUse 等）一律回「allow」——Cursor 只认 deny / ask，allow 等于没表态，
用户原来的审批设置照常生效（3.27 / CLI 2026.10.22 的代码里核对过）。出了任何错也照样回合法的 JSON，绝不挡住 agent。

记到 <状态目录>/events/<会话 id>.jsonl（手机上的对话从这里来，一行一件事）：
  user 用户发的 / thinking 思考 / text 回复 / tool 工具调用 / result 工具结果 / stop 这一轮结束 / end 会话关了
会话的元数据（编辑器还是命令行、目录、进程、tmux 窗格、正在跑的工具……）在 meta/<会话 id>.json。

Cursor 自己的对话记录（agent-transcripts/<id>/<id>.jsonl）有真实的工具名和参数（StrReplace 的新旧文本、待办），
但没有工具结果、没有时间；hook 有结果（按 tool_use_id）但改文件只报整份 Write、待办根本不报。
所以每次被调起都把对话记录新增的部分同步进来，工具调用和 hook 报的按命令 / 路径配上 id，结果跟着 id 走。

stop 时如果手机在这一轮里发了消息（queue/<会话 id>.json），作为 followup_message 交给 Cursor，它会当成下一条消息接着发。
"""
import json
import os
import re
import sys
import time

STATE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.expanduser("~"), ".ccpulse", "cursor")
# 要表态的 hook：回 allow（不表态）；beforeSubmitPrompt 回 continue
PERMISSION = ("preToolUse", "beforeShellExecution", "beforeMCPExecution", "beforeReadFile", "subagentStart")
TEXT_MAX = 30000
RESULT_MAX = 4000
INPUT_MAX = 20000
# 对话记录里这些工具没有 hook（Cursor 的内部工具），不等配对
NO_HOOK = ("TodoWrite", "GetDynamicTools", "CreatePlan", "SwitchMode", "AskQuestion", "UpdateTodos")
# 对话记录里出现了工具调用、hook 还没报：先等一会儿（hook 一般紧跟着就来），超过这么久就不等了
MATCH_WAIT = 20
# 对话记录里的工具名 → hook 报的名字（hook 按 Claude Code 的叫法报：改文件都报 Write，找文件报 Grep）
COMPAT = {"StrReplace": ("Write", "Edit"), "EditNotebook": ("Write", "Edit"), "Glob": ("Grep", "Glob")}


def now():
    return int(time.time() * 1000)


def clip(text, limit):
    text = text if isinstance(text, str) else json.dumps(text, ensure_ascii=False)
    return text if len(text) <= limit else text[:limit] + "…"


def shrink(value, depth=0):
    """工具参数：长字符串截断，免得一行记录太大"""
    if isinstance(value, str):
        return clip(value, INPUT_MAX)
    if isinstance(value, dict) and depth < 6:
        return {k: shrink(v, depth + 1) for k, v in value.items()}
    if isinstance(value, list) and depth < 6:
        return [shrink(v, depth + 1) for v in value[:200]]
    return value


class Lock:
    """同一个会话的 hook 可能并发（并行的工具调用）：读改写元数据、追加记录时用目录锁排队；锁超过 5 秒算残留"""

    def __init__(self, path):
        self.path = path

    def __enter__(self):
        deadline = time.time() + 3
        while True:
            try:
                os.mkdir(self.path)
                return self
            except FileExistsError:
                try:
                    if time.time() - os.path.getmtime(self.path) > 5:
                        os.rmdir(self.path)
                        continue
                except OSError:
                    pass
                if time.time() > deadline:
                    return self   # 等不到就不排队了，宁可乱序也不卡住 agent
                time.sleep(0.02)

    def __exit__(self, *_):
        try:
            os.rmdir(self.path)
        except OSError:
            pass


def process_chain():
    """调起 hook 的进程往上几层（pid, 名字）：手机端据此判断会话还在不在、在不在 tmux 里。Windows 不取"""
    chain = []
    if os.name == "nt":
        return chain
    pid = os.getppid()
    if os.path.isdir("/proc"):
        for _ in range(8):
            try:
                with open("/proc/%d/stat" % pid, "rb") as handle:
                    raw = handle.read().decode("utf-8", "replace")
                name = raw[raw.index("(") + 1:raw.rindex(")")]
                parent = int(raw[raw.rindex(")") + 2:].split()[1])
                # 进程名可能被改掉（命令行 agent 的 node 叫 MainThread）：取可执行文件名
                with open("/proc/%d/cmdline" % pid, "rb") as handle:
                    argv0 = handle.read().split(b"\0", 1)[0].decode("utf-8", "replace")
                name = os.path.basename(argv0) or name
            except (OSError, ValueError, IndexError):
                break
            chain.append([pid, name])
            if parent <= 1:
                break
            pid = parent
        return chain
    try:   # macOS：没有 /proc，问一次 ps
        import subprocess
        out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,comm="], capture_output=True, text=True, timeout=2).stdout
    except Exception:
        return chain
    table = {}
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            table[int(parts[0])] = (int(parts[1]), os.path.basename(parts[2].strip()))
    for _ in range(8):
        if pid not in table:
            break
        parent, name = table[pid]
        chain.append([pid, name])
        if parent <= 1:
            break
        pid = parent
    return chain


def guess_transcript(cid, roots):
    """hook 给的 transcript_path 有时还是空的：按 Cursor 的目录规则找（项目目录的 / 换成 -，没有工作区的叫 empty-window）"""
    base = os.path.join(os.path.expanduser("~"), ".cursor", "projects")
    names = [re.sub(r"[^A-Za-z0-9]+", "-", root).strip("-") for root in roots or []] or ["empty-window"]
    for name in names:
        path = os.path.join(base, name, "agent-transcripts", cid, cid + ".jsonl")
        if os.path.isfile(path):
            return path
    return None


def user_text(raw):
    """对话记录里的用户消息带着 <timestamp>、<user_query> 这些包装，取出用户真正写的"""
    found = re.search(r"<user_query>\s*([\s\S]*?)\s*</user_query>", raw)
    text = found.group(1) if found else re.sub(r"<timestamp>[\s\S]*?</timestamp>", "", raw)
    return text.strip()


def call_key(name, args):
    """配对用：命令、路径、搜索词"""
    args = args if isinstance(args, dict) else {}
    for key in ("command", "file_path", "path", "target_directory", "pattern", "glob_pattern", "url", "search_term", "query"):
        value = args.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def result_text(raw):
    """postToolUse 的 tool_output 是 JSON 字符串：命令取输出，其余尽量取正文，取不到就原样（截断）"""
    try:
        data = json.loads(raw) if isinstance(raw, str) else raw
    except ValueError:
        return clip(raw or "", RESULT_MAX)
    if isinstance(data, dict):
        for key in ("output", "content", "result", "text", "stdout"):
            if isinstance(data.get(key), str):
                text = data[key]
                if isinstance(data.get("exitCode"), int) and data["exitCode"] != 0:
                    text += "\n(exit %d)" % data["exitCode"]
                return clip(text, RESULT_MAX)
    return clip(json.dumps(data, ensure_ascii=False), RESULT_MAX)


class Conversation:
    def __init__(self, cid):
        self.cid = cid
        self.meta_path = os.path.join(STATE, "meta", cid + ".json")
        self.events_path = os.path.join(STATE, "events", cid + ".jsonl")
        try:
            with open(self.meta_path, encoding="utf-8") as handle:
                self.meta = json.load(handle)
        except (OSError, ValueError):
            self.meta = {"id": cid, "started": now(), "offset": 0, "skipUser": 0, "calls": [], "todos": [], "state": "idle"}
        self.lines = []

    def emit(self, kind, **fields):
        self.lines.append(dict(fields, ts=fields.get("ts") or now(), e=kind))
        if kind == "text":   # 列表上显示的「最后一句」
            self.meta["message"] = clip(fields.get("text") or "", 2000)

    def save(self):
        if self.lines:
            with open(self.events_path, "a", encoding="utf-8") as handle:
                handle.write("".join(json.dumps(line, ensure_ascii=False) + "\n" for line in self.lines))
        meta = self.meta
        meta["calls"] = [c for c in meta.get("calls") or [] if not (c.get("done") and c.get("matched"))][-60:]
        meta["updated"] = now()
        tmp = self.meta_path + ".%d.tmp" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(meta, handle, ensure_ascii=False)
        os.replace(tmp, self.meta_path)

    # --- 对话记录 ---

    def sync(self, force=False):
        """把 Cursor 对话记录新增的完整行翻进来；对不上 hook 的工具调用先停在那一行等下次（force 时不等）"""
        path = self.meta.get("transcript")
        if not path or not os.path.isfile(path):
            return
        offset = int(self.meta.get("offset") or 0)
        try:
            size = os.path.getsize(path)
            if size < offset:   # 被重写了：从头再来（工具调用按 id 去重，不会重复）
                offset = 0
            with open(path, "rb") as handle:
                handle.seek(offset)
                data = handle.read(size - offset)
        except OSError:
            return
        position = offset
        for raw in data.split(b"\n")[:-1]:   # 最后一段没有换行：还没写完
            step = len(raw) + 1
            try:
                entry = json.loads(raw)
            except ValueError:
                position += step
                continue
            if not self.take(entry, position, force):
                break
            position += step
        self.meta["offset"] = position

    def take(self, entry, position, force):
        """一行对话记录 → 记录；返回 False 表示这一行先不处理（工具还没等到 hook）"""
        if not isinstance(entry, dict):
            return True
        role = entry.get("role")
        content = (entry.get("message") or {}).get("content") if isinstance(entry.get("message"), dict) else None
        if not isinstance(content, list):
            return True
        if role == "user":
            if self.meta.get("skipUser"):
                self.meta["skipUser"] -= 1   # hook 已经记过这一条（beforeSubmitPrompt）
                return True
            text = "\n".join(user_text(p.get("text") or "") for p in content if isinstance(p, dict) and p.get("type") == "text")
            if text.strip():
                self.emit("user", text=clip(text.strip(), TEXT_MAX))
            return True
        if role != "assistant":
            return True
        # 同一行里几段：先确认工具都配得上（或不用等），再一起记，免得一行记一半
        parts = [p for p in content if isinstance(p, dict)]
        plans = []
        for part in parts:
            if part.get("type") == "tool_use":
                name, args = part.get("name") or "tool", part.get("input") if isinstance(part.get("input"), dict) else {}
                if name == "CallDynamicTool":
                    name, args = args.get("toolName") or name, args.get("arguments") if isinstance(args.get("arguments"), dict) else {}
                if name == "GetDynamicTools":
                    continue
                call = None if name in NO_HOOK else self.match(name, args)
                if call is None and name not in NO_HOOK and not force:
                    seen = self.meta.setdefault("waitSince", {}).setdefault(str(position), now())
                    if now() - seen < MATCH_WAIT * 1000:
                        return False
                plans.append(("tool", name, args, call))
            elif part.get("type") == "text" and (part.get("text") or "").strip():
                plans.append(("text", part["text"].strip(), None, None))
        self.meta.get("waitSince", {}).pop(str(position), None)
        for kind, name, args, call in plans:
            if kind == "text":
                self.emit("text", text=clip(name, TEXT_MAX))
            elif name == "TodoWrite":
                self.emit("tool", id="todo-%d-%d" % (position, len(self.lines)), name="TodoWrite", input={"todos": self.todos(args)})
            else:
                self.tool(name, args, call, position)
        return True

    def match(self, name, args):
        """对话记录里的一次工具调用 → hook 报过的那次（preToolUse 记下的）：先按命令 / 路径，对不上就按先后"""
        calls = [c for c in self.meta.get("calls") or [] if not c.get("matched")]
        if not calls:
            return None
        key = call_key(name, args)
        for call in calls:
            if key and call.get("key") == key:
                return call
        family = COMPAT.get(name, (name,))
        for call in calls:
            tool = call.get("tool") or ""
            if tool in family or (name == "CallMcpTool" and tool.startswith("MCP")):
                return call
        return None

    def tool(self, name, args, call, position):
        if call is not None:
            call["matched"] = True
            if call.get("emitted"):
                return   # 结果先到、已经按 hook 报的记过了
            call["emitted"] = True
        tid = call["id"] if call else "t-%d-%d" % (position, len(self.lines))
        self.emit("tool", id=tid, name=name, input=shrink(args))
        if call and call.get("done"):
            self.emit("result", id=tid, text=call.get("result") or "", error=bool(call.get("error")))

    def todos(self, args):
        """Cursor 的待办是增量的（merge）：合成完整清单再记，手机上的任务清单直接画"""
        current = [] if not args.get("merge") else list(self.meta.get("todos") or [])
        index = {str(t.get("id")): t for t in current}
        for todo in args.get("todos") or []:
            if not isinstance(todo, dict):
                continue
            tid = str(todo.get("id"))
            if tid in index:
                index[tid].update({k: v for k, v in todo.items() if v is not None})
            else:
                index[tid] = dict(todo)
                current.append(index[tid])
        self.meta["todos"] = current
        return [{"content": t.get("content") or "", "status": t.get("status") or "pending"} for t in current]

    # --- hook 事件 ---

    def handle(self, event, data):
        meta = self.meta
        roots = data.get("workspace_roots") if isinstance(data.get("workspace_roots"), list) else None
        if roots is not None:
            meta["roots"] = roots
        if data.get("transcript_path"):
            meta["transcript"] = data["transcript_path"]
        elif not meta.get("transcript"):
            meta["transcript"] = guess_transcript(self.cid, meta.get("roots"))
        for key, field in (("version", "cursor_version"), ("model", "model"), ("mode", "composer_mode")):
            if data.get(field) and data.get(field) != "default":
                meta[key] = data[field]
        meta["form"] = "cli" if os.environ.get("CURSOR_INVOKED_AS") else "ide"
        if event in ("sessionStart", "beforeSubmitPrompt"):
            meta["pids"] = process_chain()
            meta["pane"] = os.environ.get("TMUX_PANE") or None
            if os.environ.get("CURSOR_CODE_REMOTE") == "true":
                meta["remote"] = True
        if event == "beforeSubmitPrompt":
            self.sync(force=True)   # 先把记录里以前的补齐，再记这一条
            prompt = data.get("prompt") if isinstance(data.get("prompt"), str) else ""
            files = [a.get("file_path") for a in data.get("attachments") or [] if isinstance(a, dict) and a.get("type") == "file"]
            if prompt.strip() or files:
                self.emit("user", text=clip(prompt.strip(), TEXT_MAX), files=[f for f in files if f][:20] or None)
                meta["skipUser"] = int(meta.get("skipUser") or 0) + 1
                meta.setdefault("first", clip(prompt.strip(), 300))
            meta["state"], meta["current"], meta["turnStarted"] = "busy", None, now()
        elif event == "afterAgentThought":
            text = (data.get("text") or "").strip()
            if text and text != meta.get("lastThought"):   # Cursor 同一段思考会报两次
                self.sync()
                self.emit("thinking", text=clip(text, TEXT_MAX))
            meta["lastThought"] = text
            if meta.get("state") != "ended":
                meta["state"] = "busy"
        elif event == "preToolUse":
            args = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
            name = data.get("tool_name") or "tool"
            tid = data.get("tool_use_id") or "h-%d" % now()
            calls = meta.setdefault("calls", [])
            if not any(c.get("id") == tid for c in calls):
                calls.append({"id": tid, "tool": name, "input": shrink(args), "key": call_key(name, args), "ts": now()})
            meta["state"], meta["current"] = "busy", tid
            self.sync()
        elif event in ("postToolUse", "postToolUseFailure"):
            tid = data.get("tool_use_id")
            call = next((c for c in meta.get("calls") or [] if c.get("id") == tid), None)
            if event == "postToolUse":
                text, error = result_text(data.get("tool_output")), False
            else:
                text = data.get("error_message") or data.get("failure_type") or "失败"
                error = True
            self.sync()
            if call is None:   # 没见过 preToolUse（装 hook 之前就开始了）：按这次报的补一条
                call = {"id": tid or "h-%d" % now(), "tool": data.get("tool_name") or "tool", "input": shrink(data.get("tool_input") or {}),
                        "key": call_key(data.get("tool_name"), data.get("tool_input")), "ts": now()}
                meta.setdefault("calls", []).append(call)
            call.update(done=True, result=clip(text, RESULT_MAX), error=error)
            if call.get("emitted"):
                self.emit("result", id=call["id"], text=call["result"], error=error)
            elif not meta.get("transcript") or not os.path.isfile(meta.get("transcript") or ""):
                # 没有对话记录（用户关了）：按 hook 报的记
                call["emitted"] = True
                self.emit("tool", id=call["id"], name=call["tool"], input=call.get("input") or {})
                self.emit("result", id=call["id"], text=call["result"], error=error)
            if meta.get("current") == call["id"]:
                meta["current"] = None
        elif event == "afterAgentResponse":
            # 编辑器报的是最后一段，命令行报的是整轮几段拼在一起的：有对话记录就以记录为准
            if meta.get("transcript") and os.path.isfile(meta["transcript"]):
                self.sync(force=True)
            elif (data.get("text") or "").strip():
                self.emit("text", text=clip(data["text"].strip(), TEXT_MAX))
        elif event == "stop":
            self.sync(force=True)
            status = data.get("status") or "completed"
            self.emit("stop", status=status)
            meta["state"], meta["status"], meta["current"] = "idle", status, None
            for call in meta.get("calls") or []:
                call["matched"] = True   # 这一轮没配上的不再等
            return self.followup()
        elif event == "sessionEnd":
            self.sync(force=True)
            self.emit("end", reason=data.get("reason") or "")
            meta["state"] = "ended"
        elif event == "sessionStart":
            meta.setdefault("state", "idle")
        return None

    def followup(self):
        """手机在这一轮里发的消息：拿走交给 Cursor 接着发"""
        path = os.path.join(STATE, "queue", self.cid + ".json")
        taking = path + ".%d" % os.getpid()
        try:
            os.replace(path, taking)
        except OSError:
            return None
        try:
            with open(taking, encoding="utf-8") as handle:
                queued = json.load(handle)
        except (OSError, ValueError):
            queued = []
        finally:
            try:
                os.remove(taking)
            except OSError:
                pass
        texts = [q.get("text") for q in queued if isinstance(q, dict) and isinstance(q.get("text"), str) and q["text"].strip()]
        return "\n\n".join(texts) or None


def main():
    raw = sys.stdin.buffer.read()
    out = {}
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError:   # Windows 上经 PowerShell 转发时可能被转成了系统代码页（如 GBK）
        import locale
        text = raw.decode(locale.getpreferredencoding(False) or "mbcs", "replace")
    try:
        data = json.loads(text or "{}")
    except ValueError:
        data = {}
    event = data.get("hook_event_name") or (sys.argv[2] if len(sys.argv) > 2 else "")
    if event in PERMISSION:
        out = {"permission": "allow"}
    elif event == "beforeSubmitPrompt":
        out = {"continue": True}
    try:
        cid = data.get("conversation_id") or data.get("session_id")
        if cid and re.match(r"^[A-Za-z0-9._-]{1,120}$", cid):
            for folder in ("meta", "events", "queue"):
                os.makedirs(os.path.join(STATE, folder), exist_ok=True)
            with Lock(os.path.join(STATE, "meta", cid + ".lock")):
                conversation = Conversation(cid)
                followup = conversation.handle(event, data)
                conversation.save()
            if followup:
                out["followup_message"] = followup
    except Exception as exc:   # 记下来，但不影响 Cursor
        try:
            with open(os.path.join(STATE, "hook-errors.log"), "a", encoding="utf-8") as handle:
                handle.write("%s %s %r\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), event, exc))
        except OSError:
            pass
    sys.stdout.write(json.dumps(out))
    sys.stdout.flush()


if __name__ == "__main__":
    main()
