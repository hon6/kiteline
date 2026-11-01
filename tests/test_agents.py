"""watcher 接 Codex、OpenCode、DeepSeek Harness、Proma 的测试：不需要真的装这几家。

覆盖：
  - Codex rollout 解析：上下文注入不当成用户的话；shell / apply_patch / update_plan / 提问对上 Bash / Edit / TodoWrite / AskUserQuestion；
    工具输出去掉头部、按退出码判失败；尾部扫描认出还没结果的工具
  - OpenCode 消息解析：工具名、字段名对上 Claude Code；提问；出错、中断
  - 假的 Codex 守护进程（Unix socket 上的 WebSocket + JSON-RPC）：会话列表、状态广播、等确认时自动附着并收到补发的请求、
    按键 → 审批决定、发消息（空闲 turn/start、忙时 turn/steer）、中断、回答提问、空闲后退订、会话关闭后消失
  - 假的 OpenCode 插件桥（HTTP + 事件流）：登记文件发现、令牌、权限请求 → 按键 → 回复、发消息、增量、进程退出后清理
  - OpenCode 插件安装 / 删除：只在装了 OpenCode 的机器上装，关掉时只删自己的
  - 假的 DeepSeek Harness 网页服务（HTTP + WebSocket 多路流，按 DSH 的格式验 cookie）：读签名密钥、探测、
    列表 / 投影 / 对话项、审批 → 按键 → $events/result、提问 → 回答、忙时插话 / 空闲开新一轮、中断、翻历史、
    增量、会话删除、密钥对不上时不重试、进程退出后断开
  - Proma：落盘消息的规整（时间、工具、出错、旧格式），会话列表（最近动过的、子会话、草稿、归档），
    在跑 / 做完的判断、工作目录、只读；Proma 没开时一个都不列
  - Cursor 插件：hook.py 记录（对话记录与 hook 结果按 id 配对、待办合并、排队消息作 followup），装 / 删 hook 和配套扩展，
    列表、等确认（Agent Host 日志）、经扩展允许 / 拒绝 / 中断、忙时排队

用法：python3 tests/test_agents.py
"""
import base64
import hashlib
import http.server
import importlib.util
import json
import os
import queue
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
WATCHER = os.path.join(HERE, "..", "watcher", "kiteline-watch.py")

ROOT = tempfile.mkdtemp(prefix="kl-agents-test-")
os.environ["CODEX_HOME"] = os.path.join(ROOT, "codex")
os.environ["CCPULSE_DATA_DIR"] = os.path.join(ROOT, "data")
os.environ["XDG_CONFIG_HOME"] = os.path.join(ROOT, "xdg-config")
os.environ["XDG_DATA_HOME"] = os.path.join(ROOT, "xdg-data")
os.environ["DSH_HOME"] = os.path.join(ROOT, "dsh")
os.environ["CCPULSE_PROMA_DIR"] = os.path.join(ROOT, "proma")

spec = importlib.util.spec_from_file_location("watcher", WATCHER)
W = importlib.util.module_from_spec(spec)
spec.loader.exec_module(W)

PASS, FAIL = [0], []


def check(name, cond, detail=""):
    if cond:
        PASS[0] += 1
        print("  [PASS] %s" % name)
    else:
        FAIL.append(name)
        print("  [FAIL] %s %s" % (name, detail))


def wait(predicate, timeout=5.0):
    end = time.time() + timeout
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    return None


def rollout_line(kind, payload, ts="2026-10-23T02:00:00.000Z"):
    return {"timestamp": ts, "type": kind, "payload": payload}


# ---------------------------------------------------------------------------
print("== Codex rollout 解析")

items = W.normalize_codex_line(10, rollout_line("response_item", {"type": "message", "role": "user", "content": [
    {"type": "input_text", "text": "<environment_context>\n  <cwd>/x</cwd>\n</environment_context>"}]}))
check("环境上下文不当成用户的话", items == [], str(items))
items = W.normalize_codex_line(20, rollout_line("response_item", {"type": "message", "role": "user", "content": [
    {"type": "input_text", "text": "帮我跑一下测试"}, {"type": "input_image", "image_url": "data:image/png;base64,AAAA"}]}))
check("用户的话 + 图片引用", len(items) == 1 and items[0]["t"] == "user" and items[0]["text"] == "帮我跑一下测试"
      and items[0]["images"][0] == {"ref": "20.1", "mime": "image/png"} and items[0]["id"] == "20.0", str(items))
items = W.normalize_codex_line(30, rollout_line("response_item", {"type": "message", "role": "assistant", "content": [
    {"type": "output_text", "text": "好的，开始。"}]}))
check("回复", items and items[0]["t"] == "text" and items[0]["text"] == "好的，开始。", str(items))
items = W.normalize_codex_line(40, rollout_line("response_item", {"type": "reasoning", "summary": [],
                                                                  "content": [{"type": "reasoning_text", "text": "想一想"}]}))
check("思考（没有摘要时用原文）", items and items[0]["t"] == "thinking" and items[0]["text"] == "想一想", str(items))
items = W.normalize_codex_line(50, rollout_line("response_item", {"type": "function_call", "name": "exec_command", "call_id": "c1",
                                                                  "arguments": json.dumps({"cmd": "npm test", "justification": "跑测试"})}))
check("exec_command → Bash", items and items[0]["name"] == "Bash" and items[0]["input"]["command"] == "npm test"
      and items[0]["input"]["description"] == "跑测试" and items[0]["toolId"] == "c1" and items[0]["brief"] == "Bash: npm test", str(items))
patch = "*** Begin Patch\n*** Update File: /w/notes.md\n@@\n alpha\n-beta\n+gamma\n*** End Patch"
items = W.normalize_codex_line(60, rollout_line("response_item", {"type": "function_call", "name": "exec_command", "call_id": "c2",
                                                                  "arguments": json.dumps({"cmd": "apply_patch '%s'" % patch})}))
check("shell 里调 apply_patch → Edit（改动前后的文本）", items and items[0]["name"] == "Edit"
      and items[0]["input"] == {"file_path": "/w/notes.md", "old_string": "alpha\nbeta", "new_string": "alpha\ngamma"}, str(items))
items = W.normalize_codex_line(70, rollout_line("response_item", {"type": "custom_tool_call", "name": "apply_patch", "call_id": "c3",
                                                                  "input": "*** Begin Patch\n*** Add File: a.txt\n+x\n+y\n*** End Patch"}))
check("apply_patch 新建文件 → Write", items and items[0]["name"] == "Write" and items[0]["input"]["content"] == "x\ny", str(items))
items = W.normalize_codex_line(80, rollout_line("response_item", {"type": "function_call", "name": "update_plan", "call_id": "c4",
                                                                  "arguments": json.dumps({"plan": [{"step": "写代码", "status": "completed"},
                                                                                                    {"step": "跑测试", "status": "in_progress"}]})}))
check("update_plan → TodoWrite", items and items[0]["name"] == "TodoWrite"
      and [t["status"] for t in items[0]["input"]["todos"]] == ["completed", "in_progress"], str(items))
items = W.normalize_codex_line(90, rollout_line("response_item", {"type": "function_call", "name": "request_user_input", "call_id": "c5",
                                                                  "arguments": json.dumps({"questions": [{"id": "q1", "header": "方案", "question": "用哪个？",
                                                                                                          "options": [{"label": "A", "description": "快"}]}]})}))
check("request_user_input → AskUserQuestion", items and items[0]["name"] == "AskUserQuestion"
      and items[0]["input"]["questions"][0]["options"][0]["label"] == "A", str(items))
items = W.normalize_codex_line(100, rollout_line("response_item", {"type": "function_call_output", "call_id": "c1", "output":
    "Chunk ID: 1\nWall time: 0.1 seconds\nProcess exited with code 1\nOriginal token count: 3\nOutput:\nFAIL x\n"}))
check("工具输出去掉头部，退出码非 0 记失败", items and items[0]["t"] == "result" and items[0]["text"] == "FAIL x" and items[0]["isError"], str(items))
check("认不出的行返回空", W.normalize_codex_line(110, rollout_line("token_usage_record", {})) == []
      and W.normalize_codex_line(111, {"type": "turn_context", "payload": {}}) == [])
aborted = W.normalize_codex_line(120, rollout_line("response_item", {"type": "message", "role": "user", "content": [
    {"type": "input_text", "text": "<turn_aborted>\nThe user interrupted the previous turn on purpose.\n</turn_aborted>"}]}))
aborted += W.normalize_codex_line(121, rollout_line("event_msg", {"type": "turn_aborted", "reason": "interrupted"}))
check("一次中断只记一个「已中断」（给模型看的说明 + 事件）", [i["text"] for i in aborted] == ["已中断"], str(aborted))

path = os.path.join(ROOT, "rollout.jsonl")
with open(path, "w") as handle:
    for obj in (rollout_line("response_item", {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "第一句话"}]}),
                rollout_line("response_item", {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "收到"}]}),
                rollout_line("response_item", {"type": "function_call", "name": "exec_command", "call_id": "z1", "arguments": "{\"cmd\": \"ls\"}"})):
        handle.write(json.dumps(obj) + "\n")
scan = W.scan_codex_rollout(path)
check("尾部扫描：最后一句回复、还在跑的工具、标题兜底", scan["message"] == "收到" and scan["pendingTool"] == "Bash"
      and scan["pendingBrief"] == "Bash: ls" and scan["firstUser"] == "第一句话", str(scan))
items, more, _ = W.read_history(path, None, 10, W.normalize_codex_line)
check("历史翻页用 Codex 的规整函数", [i["t"] for i in items] == ["user", "text", "tool"] and not more, str(items))

# ---------------------------------------------------------------------------
print("== OpenCode 消息解析")

messages = [
    {"info": {"id": "m1", "role": "user", "time": {"created": 1000}},
     "parts": [{"type": "text", "text": "跑一下"}, {"type": "text", "text": "系统提示", "synthetic": True},
               {"type": "file", "mime": "image/png", "url": "file:///tmp/a.png"}]},
    {"info": {"id": "m2", "role": "assistant", "time": {"created": 2000}, "tokens": {"input": 10, "output": 5, "cache": {"read": 100, "write": 0}},
              "modelID": "qwen"},
     "parts": [{"type": "step-start"}, {"type": "reasoning", "text": "想想", "time": {"start": 2001}},
               {"type": "tool", "callID": "k1", "tool": "edit", "state": {"status": "completed", "input": {"filePath": "/w/a.py", "oldString": "1", "newString": "2"},
                                                                         "output": "ok", "time": {"start": 2002, "end": 2003}}},
               {"type": "tool", "callID": "k2", "tool": "bash", "state": {"status": "running", "input": {"command": "make"}, "time": {"start": 2004}}},
               {"type": "text", "text": "改好了", "time": {"start": 2005}}]},
    {"info": {"id": "m3", "role": "assistant", "time": {"created": 3000}, "error": {"name": "MessageAbortedError", "data": {}}}, "parts": []},
]
items = W.opencode_items(messages)
kinds = [(i["t"], i.get("name")) for i in items]
check("OpenCode：用户的话（不含系统注入）+ 图片", items[0]["t"] == "user" and items[0]["text"] == "跑一下"
      and items[0]["images"] == [{"ref": "f:/tmp/a.png", "mime": "image/png"}], str(items[0]))
check("OpenCode：edit → Edit（字段名对上），完成的有结果，在跑的没有", ("tool", "Edit") in kinds and ("tool", "Bash") in kinds
      and sum(1 for i in items if i["t"] == "result") == 1
      and next(i for i in items if i.get("name") == "Edit")["input"]["old_string"] == "1", str(kinds))
check("OpenCode：id 是「消息毫秒.序号」，能排序、翻页", all(i["id"].split(".")[0].isdigit() for i in items) and items[0]["id"] == "1000.0")
check("OpenCode：中断记成事件", items[-1]["t"] == "event" and items[-1]["text"] == "已中断", str(items[-1]))
name, args = W.opencode_tool("question", {"questions": [{"question": "选哪个", "header": "h", "options": [{"label": "A", "description": ""}], "multiple": True}]})
check("OpenCode：提问 → AskUserQuestion（多选）", name == "AskUserQuestion" and args["questions"][0]["multiSelect"] is True)


# ---------------------------------------------------------------------------
print("== 假的 Codex 守护进程")

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class FakeCodex:
    """Unix socket 上的 WebSocket 服务端，回 Kiteline 用到的几个方法，记下收到的请求和回复"""

    def __init__(self, path):
        if os.path.exists(path):
            os.remove(path)
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(4)
        self.conn = None
        self.requests = []      # (method, params)
        self.replies = []       # 客户端对 server request 的回复
        self.status = {"type": "idle"}
        self.turn_status = "completed"
        self.lock = threading.Lock()
        threading.Thread(target=self.accept, daemon=True).start()

    def accept(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            threading.Thread(target=self.serve, args=(conn,), daemon=True).start()

    def frame(self, data):
        size = len(data)
        head = bytes([0x81, size]) if size < 126 else (bytes([0x81, 126]) + struct.pack(">H", size) if size < 65536
                                                         else bytes([0x81, 127]) + struct.pack(">Q", size))
        return head + data

    def send(self, obj):
        with self.lock:
            self.conn.sendall(self.frame(json.dumps(obj).encode()))

    def serve(self, conn):
        head = b""
        while b"\r\n\r\n" not in head:
            head += conn.recv(1)
        key = [l.split(b":", 1)[1].strip() for l in head.split(b"\r\n") if l.lower().startswith(b"sec-websocket-key")][0]
        accept = base64.b64encode(hashlib.sha1(key + GUID.encode()).digest())
        conn.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
        self.conn = conn

        def exact(n):
            buf = b""
            while len(buf) < n:
                chunk = conn.recv(n - len(buf))
                if not chunk:
                    raise EOFError
                buf += chunk
            return buf
        try:
            while True:
                first, second = exact(2)
                size = second & 0x7F
                if size == 126:
                    size = struct.unpack(">H", exact(2))[0]
                elif size == 127:
                    size = struct.unpack(">Q", exact(8))[0]
                mask = exact(4)
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(exact(size)))
                if first & 0x0F == 8:
                    return
                self.handle(json.loads(data))
        except (EOFError, OSError):
            return

    def thread(self):
        return {"id": "t1", "cwd": "/w/项目", "path": path, "name": "修首页", "createdAt": 1792700000, "updatedAt": 1792700100,
                "status": self.status, "model": "gpt-6", "cliVersion": "0.162.0", "source": "cli"}

    def handle(self, message):
        method = message.get("method")
        if method is None:
            self.replies.append(message)
            return
        self.requests.append((method, message.get("params") or {}))
        if "id" not in message:
            return
        result = {}
        if method == "initialize":
            result = {"userAgent": "fake"}
        elif method == "thread/loaded/list":
            result = {"data": ["t1"], "nextCursor": None}
        elif method in ("thread/read", "thread/resume"):
            result = {"thread": self.thread()}
        elif method == "thread/turns/list":
            result = {"data": [{"id": "turn-9", "status": self.turn_status}]}
        self.send({"id": message["id"], "result": result})
        if method == "thread/resume" and self.status.get("activeFlags"):
            # 等确认时附着：补发待答的请求
            self.send({"id": 900, "method": "item/commandExecution/requestApproval",
                       "params": {"threadId": "t1", "turnId": "turn-9", "itemId": "c9", "command": ["/bin/zsh", "-lc", "rm -rf build"],
                                  "reason": "要删掉 build 目录"}})

    def set_status(self, status):
        self.status = status
        self.send({"method": "thread/status/changed", "params": {"threadId": "t1", "status": status}})


if not hasattr(socket, "AF_UNIX") or os.name == "nt":
    print("  （跳过：这台机器不支持 Unix socket）")
else:
    # 照 Codex 的样子：真 socket 放在短路径上，CODEX_HOME 里是指向它的链接（macOS 的临时目录太长，直接放会超长）
    real_sock = "/tmp/kl-agents-%d.sock" % os.getpid()
    sock_path = os.path.join(ROOT, "codex", "app-server-control", "app-server-control.sock")
    fake = FakeCodex(real_sock)
    os.makedirs(os.path.dirname(sock_path), exist_ok=True)
    os.symlink(real_sock, sock_path)
    W.CODEX_SOCKET = sock_path
    link = W.CodexLink()
    link.IDLE_UNSUBSCRIBE = 0.5
    link.start()
    snap = wait(lambda: next(iter(link.snapshots()), None))
    check("Codex：连上后列出已加载的会话", snap and snap["sessionId"] == "t1" and snap["agent"] == "codex" and snap["title"] == "修首页"
          and snap["activity"] == "idle" and snap["message"] == "收到", str(snap))
    initialize = next((p for m, p in fake.requests if m == "initialize"), {})
    check("Codex：初始化时退订用不上的逐字增量", "item/agentMessage/delta" in ((initialize.get("capabilities") or {}).get("optOutNotificationMethods") or []))
    check("Codex：只看状态时不附着", not any(m == "thread/resume" for m, _ in fake.requests))
    fake.set_status({"type": "active", "activeFlags": []})
    snap = wait(lambda: next((s for s in link.snapshots() if s["activity"] == "busy"), None))
    check("Codex：状态广播 → 正在工作，状态行是还在跑的工具", snap and snap["activityText"] == "Bash: ls", str(snap))
    fake.set_status({"type": "active", "activeFlags": ["waitingOnApproval"]})
    snap = wait(lambda: next((s for s in link.snapshots() if s["activity"] == "waiting" and s["pendingId"] == "900"), None))
    check("Codex：等确认时自动附着，收到补发的请求", snap and snap["pendingTool"] == "Bash" and snap["waitingFor"] == "要删掉 build 目录"
          and any(m == "thread/resume" for m, _ in fake.requests), str(snap))
    message = link.key("t1", "esc")
    reply = wait(lambda: next((r for r in fake.replies if r.get("id") == 900), None))
    check("Codex：Esc → 拒绝并停下（cancel）", reply and reply["result"] == {"decision": "cancel"} and message == "已选择", str(reply))
    check("Codex：答完就不再算待确认", not link.pending.get("t1"))
    fake.send({"id": 901, "method": "item/commandExecution/requestApproval", "params": {"threadId": "t1", "command": "ls"}})
    wait(lambda: link.pending.get("t1"))
    link.key("t1", "2")
    reply = wait(lambda: next((r for r in fake.replies if r.get("id") == 901), None))
    check("Codex：2 → 本会话都允许", reply and reply["result"] == {"decision": "acceptForSession"}, str(reply))
    fake.send({"id": 902, "method": "item/tool/requestUserInput", "params": {"threadId": "t1", "questions": [
        {"id": "q1", "header": "方案", "question": "用哪个？", "options": [{"label": "A", "description": ""}, {"label": "B", "description": ""}]}]}})
    wait(lambda: link.pending.get("t1"))
    link.answer("t1", [{"question": "用哪个？", "picked": ["B"], "other": "再快点"}])
    reply = wait(lambda: next((r for r in fake.replies if r.get("id") == 902), None))
    check("Codex：回答提问（按题目对上 id，自己写的也带上）", reply and reply["result"] == {"answers": {"q1": {"answers": ["B", "再快点"]}}}, str(reply))
    fake.turn_status = "inProgress"
    fake.set_status({"type": "active", "activeFlags": []})
    wait(lambda: any(s["activity"] == "busy" for s in link.snapshots()))
    link.send("t1", "顺便看下日志", [])
    steer = wait(lambda: next((p for m, p in fake.requests if m == "turn/steer"), None))
    check("Codex：忙时发消息 → 插进这一轮（turn/steer）", steer and steer["expectedTurnId"] == "turn-9"
          and steer["input"] == [{"type": "text", "text": "顺便看下日志"}], str(steer))
    link.key("t1", "esc")
    interrupt = wait(lambda: next((p for m, p in fake.requests if m == "turn/interrupt"), None))
    check("Codex：没有待确认时 Esc → 中断", interrupt and interrupt["turnId"] == "turn-9", str(interrupt))
    fake.turn_status = "completed"
    fake.set_status({"type": "idle"})
    wait(lambda: all(s["activity"] == "idle" for s in link.snapshots()))
    cplugin = W.CodexPlugin.__new__(W.CodexPlugin)   # 走插件分派：会话在后台服务里 → 交给 CodexLink
    cplugin.daemon, cplugin.ipc = link, W.CodexIpcLink()
    W.AgentPlugins([cplugin]).handle("codex", {"cmd": "agent_send", "sessionId": "t1", "text": " 再跑一遍\n", "images": ["/tmp/a.png", 3]})
    start = wait(lambda: next((p for m, p in fake.requests if m == "turn/start"), None))
    check("Codex：空闲时发消息 → turn/start（图片按本地图片给）", start and start["input"] == [
        {"type": "text", "text": "再跑一遍"}, {"type": "localImage", "path": "/tmp/a.png"}], str(start))
    unsubscribed = wait(lambda: any(m == "thread/unsubscribe" for m, _ in fake.requests), timeout=6)
    check("Codex：空闲一阵后退订（会话能正常卸载）", unsubscribed)
    try:
        link.key("t1", "1")
        check("Codex：没有待确认时按 1 给出明确提示", False)
    except RuntimeError as exc:
        check("Codex：没有待确认时按 1 给出明确提示", "没有待确认" in str(exc), str(exc))
    fake.send({"method": "thread/closed", "params": {"threadId": "t1"}})
    check("Codex：会话关闭后从列表消失", wait(lambda: link.snapshots() == []))


# ---------------------------------------------------------------------------
print("== 补丁与审批选项")

state = {"requests": [], "threadRuntimeStatus": {"type": "idle"}, "list": [1, 2, 3]}
W.apply_patches(state, [{"op": "replace", "path": ["threadRuntimeStatus"], "value": {"type": "active", "activeFlags": []}},
                        {"op": "add", "path": ["requests", 0], "value": {"id": 7}},
                        {"op": "remove", "path": ["list", 1]},
                        {"op": "replace", "path": ["turnHistory", "x"], "value": 1}], fields=("threadRuntimeStatus", "requests", "list"))
check("immer 补丁：替换、数组插入、删除；不关心的字段跳过", state == {"requests": [{"id": 7}], "threadRuntimeStatus": {"type": "active", "activeFlags": []},
                                                        "list": [1, 3]}, str(state))
amend = {"acceptWithExecpolicyAmendment": {"execpolicy_amendment": ["ls"]}}
check("审批选项：没有「本会话都允许」时退到「这类命令以后不再问」", W._pick_decision("acceptForSession", ["accept", amend, "cancel"]) == amend)
check("审批选项：都没有时退到「允许」", W._pick_decision("acceptForSession", ["accept", "cancel"]) == "accept")
check("审批选项：没有 cancel 时拒绝用 decline", W._pick_decision("cancel", ["accept", "decline"]) == "decline")
check("审批选项：没给选项时照原样", W._pick_decision("acceptForSession", None) == "acceptForSession")


# ---------------------------------------------------------------------------
print("== 假的 Codex IPC 总线（桌面版 / VS Code 扩展）")


class FakeIpc:
    """扮演 IPC 路由 + 会话 c1 的所有者（owner-1）"""

    def __init__(self, path):
        if os.path.exists(path):
            os.remove(path)
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(2)
        self.conn = None
        self.requests = []       # (method, params, targetClientId)
        self.discovery = []      # Kiteline 对 client-discovery-request 的回答
        self.revision = 1
        self.state = {"id": "c1", "title": "修登录页", "cwd": "/w/vs", "rolloutPath": path_rollout, "createdAt": 1792700000000,
                      "updatedAt": 1792700100000, "threadRuntimeStatus": {"type": "idle"}, "requests": [], "originator": "codex_vscode",
                      "latestModel": "gpt-6", "latestTokenUsageInfo": {"last": {"inputTokens": 900, "outputTokens": 100},
                                                                       "total": {"inputTokens": 5000, "outputTokens": 300}, "modelContextWindow": 10000},
                      "turnHistory": {"big": "x" * 1000}}
        self.lock = threading.Lock()
        threading.Thread(target=self.accept, daemon=True).start()

    def accept(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            self.conn = conn
            threading.Thread(target=self.serve, args=(conn,), daemon=True).start()

    def push(self, obj):
        data = json.dumps(obj).encode()
        with self.lock:
            self.conn.sendall(struct.pack("<I", len(data)) + data)

    def reply(self, msg, ok=True, result=None, handled="owner-1", error=None):
        out = {"type": "response", "requestId": msg["requestId"], "resultType": "success" if ok else "error", "method": msg["method"]}
        if ok:
            out.update(handledByClientId=handled, result=result if result is not None else {"ok": True})
        else:
            out["error"] = error
        self.push(out)

    def snapshot(self):
        self.push({"type": "broadcast", "method": "thread-stream-state-changed", "sourceClientId": "owner-1", "version": 11,
                   "params": {"conversationId": "c1", "hostId": "local", "change": {"type": "snapshot", "revision": self.revision,
                                                                                    "conversationState": self.state}}})

    def patch(self, patches, base=None):
        base = self.revision if base is None else base
        self.revision += 1
        self.push({"type": "broadcast", "method": "thread-stream-state-changed", "sourceClientId": "owner-1", "version": 11,
                   "params": {"conversationId": "c1", "hostId": "local", "change": {"type": "patches", "baseRevision": base,
                                                                                    "revision": self.revision, "patches": patches}}})

    def serve(self, conn):
        def exact(n):
            buf = b""
            while len(buf) < n:
                chunk = conn.recv(n - len(buf))
                if not chunk:
                    raise EOFError
                buf += chunk
            return buf
        try:
            while True:
                msg = json.loads(exact(struct.unpack("<I", exact(4))[0]))
                kind, method = msg.get("type"), msg.get("method")
                if kind == "client-discovery-response":
                    self.discovery.append(msg)
                elif kind == "request" and method == "initialize":
                    self.reply(msg, result={"clientId": "kl"}, handled="kl")
                elif kind == "request" and method == "thread-owner-discovery":
                    if msg["params"]["conversationId"] == "c1":
                        self.reply(msg, result={"supportsUntrustedAppInput": True})
                    else:
                        self.reply(msg, ok=False, error="no-client-found")
                elif kind == "request":
                    self.requests.append((method, msg.get("params"), msg.get("targetClientId"), msg.get("version")))
                    self.reply(msg)
                elif kind == "broadcast" and method == "thread-stream-following-changed":
                    self.requests.append((method, msg.get("params"), msg.get("targetClientIds"), msg.get("version")))
                    if msg["params"]["following"]:
                        self.snapshot()
        except (EOFError, OSError):
            return


if not hasattr(socket, "AF_UNIX") or os.name == "nt":
    print("  （跳过：这台机器不支持 Unix socket）")
else:
    W.CODEX_HOME = os.path.join(ROOT, "codex")
    path_rollout = os.path.join(ROOT, "rollout.jsonl")
    os.makedirs(os.path.join(W.CODEX_HOME, "ipc"), exist_ok=True)
    real_ipc = "/tmp/kl-ipc-%d.sock" % os.getpid()
    fake_ipc = FakeIpc(real_ipc)
    if not os.path.lexists(os.path.join(W.CODEX_HOME, "ipc", "ipc.sock")):
        os.symlink(real_ipc, os.path.join(W.CODEX_HOME, "ipc", "ipc.sock"))
    import sqlite3 as _sqlite3
    db = _sqlite3.connect(os.path.join(W.CODEX_HOME, "state_5.sqlite"))
    db.execute("create table threads (id text, updated_at integer, archived integer)")
    db.executemany("insert into threads values (?, ?, 0)", [("c1", int(time.time())), ("c2", int(time.time()) - 60)])
    db.commit()
    db.close()
    ipc = W.CodexIpcLink()
    ipc.PROBE_EVERY = 0.3
    ipc.start()
    snap = wait(lambda: next(iter(ipc.snapshots(set())), None), timeout=8)
    check("IPC：找到 VS Code 里开着的会话并跟随（没所有者的 c2 不列）", snap and [s["sessionId"] for s in ipc.snapshots(set())] == ["c1"]
          and snap["entrypoint"] == "codex-vscode" and snap["title"] == "修登录页" and snap["agent"] == "codex"
          and snap["usage"]["context"] == 1000 and snap["transcriptPath"] == path_rollout, str(snap)[:300])
    check("IPC：只记用得着的字段（不存整段对话历史）", "turnHistory" not in ipc.states["c1"]["state"])
    follow = next((r for r in fake_ipc.requests if r[0] == "thread-stream-following-changed"), None)
    check("IPC：跟随广播只发给所有者", follow and follow[2] == ["owner-1"] and follow[1]["following"] is True, str(follow))
    fake_ipc.push({"type": "client-discovery-request", "requestId": "d1", "request": {"method": "thread-owner-discovery"}})
    answer = wait(lambda: next((d for d in fake_ipc.discovery if d["requestId"] == "d1"), None), timeout=3)
    check("IPC：路由问「能处理吗」马上回答不能（不拖慢别人）", answer and answer["response"] == {"canHandle": False}, str(answer))
    check("IPC：和共享后台服务去重", ipc.snapshots({"c1"}) == [])
    fake_ipc.patch([{"op": "replace", "path": ["threadRuntimeStatus"], "value": {"type": "active", "activeFlags": ["waitingOnApproval"]}},
                    {"op": "replace", "path": ["requests"], "value": [{"method": "item/commandExecution/requestApproval", "id": 3, "params": {
                        "threadId": "c1", "command": "rm -rf dist", "reason": "清理旧产物",
                        "availableDecisions": ["accept", {"acceptWithExecpolicyAmendment": {"execpolicy_amendment": ["rm"]}}, "cancel"]}}]}])
    snap = wait(lambda: next((s for s in ipc.snapshots(set()) if s["activity"] == "waiting"), None), timeout=4)
    check("IPC：补丁 → 等确认（工具、原因）", snap and snap["pendingTool"] == "Bash" and snap["waitingFor"] == "清理旧产物", str(snap)[:200])
    ipc.key("c1", "2")
    decided = wait(lambda: next((r for r in fake_ipc.requests if r[0] == "thread-follower-command-approval-decision"), None), timeout=3)
    check("IPC：2 → 交给所有者（按可用选项换成「这类命令不再问」，发给所有者）", decided and decided[1]["requestId"] == 3
          and decided[1]["decision"] == {"acceptWithExecpolicyAmendment": {"execpolicy_amendment": ["rm"]}}
          and decided[2] == "owner-1" and decided[1]["conversationId"] == "c1", str(decided))
    fake_ipc.patch([{"op": "replace", "path": ["requests"], "value": []},
                    {"op": "replace", "path": ["threadRuntimeStatus"], "value": {"type": "active", "activeFlags": []}}])
    wait(lambda: any(s["activity"] == "busy" for s in ipc.snapshots(set())), timeout=3)
    ipc.send_message("c1", "顺便看下日志", [])
    steer = wait(lambda: next((r for r in fake_ipc.requests if r[0] == "thread-follower-steer-turn"), None), timeout=3)
    check("IPC：忙时发消息 → steer-turn", steer and steer[1]["input"][0]["text"] == "顺便看下日志", str(steer)[:200])
    ipc_plugin = W.CodexPlugin.__new__(W.CodexPlugin)
    ipc_plugin.daemon, ipc_plugin.ipc = W.CodexLink(), ipc
    ipc_plugins = W.AgentPlugins([ipc_plugin])
    ipc_plugins.handle("codex", {"cmd": "agent_key", "sessionId": "c1", "key": "Escape"})
    stop = wait(lambda: next((r for r in fake_ipc.requests if r[0] == "thread-follower-interrupt-turn"), None), timeout=3)
    check("IPC：没有待确认时 Esc → 中断（user-stop）", stop and stop[1]["mode"] == "user-stop", str(stop))
    fake_ipc.patch([{"op": "replace", "path": ["threadRuntimeStatus"], "value": {"type": "idle"}}], base=999)
    resync = wait(lambda: sum(1 for r in fake_ipc.requests if r[0] == "thread-stream-following-changed") >= 2, timeout=6)
    check("IPC：补丁漏了（修订号对不上）→ 重新要快照", resync and ipc.states["c1"]["revision"] == fake_ipc.revision)
    fake_ipc.state["threadRuntimeStatus"] = {"type": "idle"}
    fake_ipc.snapshot()
    wait(lambda: all(s["activity"] == "idle" for s in ipc.snapshots(set())), timeout=3)
    ipc_plugins.handle("codex", {"cmd": "agent_send", "sessionId": "c1", "text": "再跑一遍", "images": ["/tmp/x.png"]})
    start = wait(lambda: next((r for r in fake_ipc.requests if r[0] == "thread-follower-start-turn"), None), timeout=3)
    check("IPC：空闲时发消息 → start-turn（turnStart.request 带会话 id 和图片）", start and start[1]["turnStart"]["request"]["threadId"] == "c1"
          and start[1]["turnStart"]["request"]["input"][1] == {"type": "localImage", "path": "/tmp/x.png"} and start[3] == 2, str(start)[:300])
    fake_ipc.patch([{"op": "replace", "path": ["requests"], "value": [{"method": "item/tool/requestUserInput", "id": 9, "params": {
        "threadId": "c1", "questions": [{"id": "q1", "question": "用哪个？", "header": "h", "options": [{"label": "A", "description": ""}]}]}}]}])
    wait(lambda: any(s["activity"] == "waiting" for s in ipc.snapshots(set())), timeout=3)
    ipc.answer("c1", [{"question": "用哪个？", "picked": ["A"]}])
    submitted = wait(lambda: next((r for r in fake_ipc.requests if r[0] == "thread-follower-submit-user-input"), None), timeout=3)
    check("IPC：回答提问 → submit-user-input", submitted and submitted[1]["response"] == {"answers": {"q1": {"answers": ["A"]}}}, str(submitted))
    fake_ipc.push({"type": "broadcast", "method": "client-status-changed", "sourceClientId": "owner-1", "version": 1,
                   "params": {"clientId": "owner-1", "clientType": "vscode", "status": "disconnected"}})
    check("IPC：所有者断开后会话消失", wait(lambda: ipc.snapshots(set()) == [], timeout=3))
    ipc_plugin.daemon.threads["c1"] = {"id": "c1"}
    check("插件分派：同一会话后台服务里也有时，以后台服务为准", ipc_plugin.via_ipc("c1") is False)
    os.remove(real_ipc)


# ---------------------------------------------------------------------------
print("== 假的 OpenCode 插件桥")

TOKEN = "secret-token"


class FakeOpenCode(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), FakeHandler)
        self.events = queue.Queue()
        self.stopped = False      # 模拟进程退出：事件流也断开
        self.calls = []
        self.status = {}
        self.permissions = []
        self.questions = []
        now = int(time.time() * 1000)
        self.sessions = [{"id": "ses_1", "title": "加导出", "directory": "/w/oc", "time": {"created": now - 5000, "updated": now}},
                         {"id": "ses_old", "title": "很久以前", "directory": "/w/oc", "time": {"created": 1000, "updated": 2000}},
                         {"id": "ses_child", "parentID": "ses_1", "title": "子任务", "directory": "/w/oc", "time": {"created": now, "updated": now}}]
        self.messages = messages


class FakeHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, obj, status=200):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            self.reply({"error": "forbidden"}, 403)
            return False
        return True

    def do_GET(self):
        if not self.authorized():
            return
        server = self.server
        route = self.path.split("?")[0]
        if route == "/event":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            while not server.stopped:
                try:
                    event = server.events.get(timeout=1)
                except queue.Empty:
                    event = {"type": "server.heartbeat", "properties": {}}
                try:
                    self.wfile.write(("data: %s\n\n" % json.dumps(event)).encode())
                    self.wfile.flush()
                except OSError:
                    return
        elif route == "/session":
            self.reply(server.sessions)
        elif route == "/session/status":
            self.reply(server.status)
        elif route == "/permission":
            self.reply(server.permissions)
        elif route == "/question":
            self.reply(server.questions)
        elif route.startswith("/session/") and route.endswith("/message"):
            server.calls.append(("GET", self.path))
            self.reply(server.messages)
        else:
            self.reply({"error": "not found"}, 404)

    def do_POST(self):
        if not self.authorized():
            return
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"null")
        self.server.calls.append(("POST", self.path, body))
        self.reply(True)


oc = FakeOpenCode()
threading.Thread(target=oc.serve_forever, daemon=True).start()
bridges = os.path.join(ROOT, "data", "opencode")
os.makedirs(bridges, exist_ok=True)
W.OPENCODE_BRIDGES = bridges
registration = os.path.join(bridges, "%d-abc.json" % os.getpid())
with open(os.path.join(bridges, "999999-dead.json"), "w") as handle:
    json.dump({"pid": 999999, "port": 1, "token": "x", "directory": "/w"}, handle)
with open(registration, "w") as handle:
    json.dump({"pid": os.getpid(), "port": oc.server_address[1], "token": TOKEN, "directory": "/w/oc",
               "started": int(time.time() * 1000) - 60000}, handle)
oclink = W.OpenCodeLink()
snap = wait(lambda: next(iter(oclink.snapshots()), None))
check("OpenCode：发现登记的桥，列出这个进程里用过的会话（旧会话、子任务不算）", snap and [s["sessionId"] for s in oclink.snapshots()] == ["ses_1"]
      and snap["agent"] == "opencode" and snap["title"] == "加导出" and snap["subagents"] == 1, str(oclink.snapshots()))
check("OpenCode：进程已经不在的登记文件被清掉", not os.path.exists(os.path.join(bridges, "999999-dead.json")))
bridge = oclink.owner("ses_1")
wait(lambda: bridge.connected)
pumped = wait(lambda: oclink.pump())
check("OpenCode：连上后推一遍最近的对话项（子任务的不推）", pumped and [sid for sid, _ in pumped] == ["ses_1"]
      and any(i["t"] == "text" for i in pumped[0][1]), str(pumped)[:200])
check("OpenCode：快照带最后一句回复、用量", wait(lambda: (next(iter(oclink.snapshots()), {}) or {}).get("message") == "改好了")
      and next(iter(oclink.snapshots()))["usage"]["context"] == 115)
oc.events.put({"type": "session.status", "properties": {"sessionID": "ses_1", "status": {"type": "busy"}}})
snap = wait(lambda: next((s for s in oclink.snapshots() if s["activity"] == "busy"), None))
check("OpenCode：事件流 → 正在工作", snap and snap["activityText"] == "Bash: make", str(snap))
oc.events.put({"type": "permission.asked", "properties": {"id": "per_1", "sessionID": "ses_1", "permission": "bash",
                                                          "patterns": ["rm -rf dist"], "metadata": {}, "always": []}})
snap = wait(lambda: next((s for s in oclink.snapshots() if s["activity"] == "waiting"), None))
check("OpenCode：权限请求 → 等确认", snap and snap["pendingTool"] == "Bash" and "rm -rf dist" in snap["waitingFor"], str(snap))
bridge.key("ses_1", "1")
check("OpenCode：1 → 允许一次", ("POST", "/permission/per_1/reply", {"reply": "once"}) in oc.calls, str(oc.calls[-1:]))
check("OpenCode：答完不再算待确认", wait(lambda: all(s["activity"] != "waiting" for s in oclink.snapshots())))
oplugin = W.OpenCodePlugin.__new__(W.OpenCodePlugin)   # 走插件分派：按会话找到所在的桥
oplugin.link = oclink
W.AgentPlugins([oplugin]).handle("opencode", {"cmd": "agent_send", "sessionId": "ses_1", "text": "加个测试", "images": ["/tmp/b.png"]})
sent = next((c for c in oc.calls if c[1] == "/session/ses_1/prompt_async"), None)
check("OpenCode：发消息 → prompt_async（图片按文件给）", sent and sent[2]["parts"][0] == {"type": "text", "text": "加个测试"}
      and sent[2]["parts"][1]["url"] == "file:///tmp/b.png", str(sent))
bridge.key("ses_1", "esc")
check("OpenCode：忙时 Esc → 中断", any(c[1] == "/session/ses_1/abort" for c in oc.calls))
oc.events.put({"type": "question.asked", "properties": {"id": "que_1", "sessionID": "ses_1",
                                                        "questions": [{"question": "选哪个", "header": "h", "options": [{"label": "A"}]}]}})
wait(lambda: bridge.questions)
bridge.answer("ses_1", [{"question": "选哪个", "picked": ["A"]}])
check("OpenCode：回答提问", ("POST", "/question/que_1/reply", {"answers": [["A"]]}) in oc.calls, str(oc.calls[-1:]))
before = len([c for c in oc.calls if c[0] == "GET"])
oc.events.put({"type": "message.part.updated", "properties": {"part": {"sessionID": "ses_1", "type": "text"}}})
check("OpenCode：消息有变 → 重新取最近几条", wait(lambda: oclink.pump() is not None and len([c for c in oc.calls if c[0] == "GET"]) > before))
items, more = bridge.history("ses_1", 3000, 80)
check("OpenCode：历史翻页按「消息毫秒」往前取", items and all(int(i["id"].split(".")[0]) < 3000 for i in items) and not more, str(items)[:200])
oc.stopped = True
oc.shutdown()
oc.server_close()
check("OpenCode：进程退出（端口没人听）后会话消失、登记文件删掉",
      wait(lambda: oclink.snapshots() == [] and not os.path.exists(registration), timeout=15), str(oclink.snapshots())[:200])


# ---------------------------------------------------------------------------
print("== OpenCode 插件安装 / 删除")

target = os.path.join(ROOT, "xdg-config", "opencode", "plugin", "kiteline.js")
real_home, W.HOME = W.HOME, ROOT   # 别去看这台机器上真装没装
os.makedirs(os.path.join(ROOT, "xdg-data", "opencode", "log"))
os.makedirs(os.path.join(ROOT, "xdg-config", "opencode", "plugin"))
check("只有空的数据目录、空的插件目录（卸载或别的程序留下的）不算装了 OpenCode", W.install_opencode_plugin() is None
      or shutil.which("opencode") is not None)
open(os.path.join(ROOT, "xdg-data", "opencode", "opencode.db"), "w").close()
check("用过 OpenCode（有数据库）才装插件", W.install_opencode_plugin() == target and open(target).read() == W.OPENCODE_PLUGIN)
W.HOME = real_home
check("插件只监听本机、带令牌、出错不影响 OpenCode", '"127.0.0.1"' in W.OPENCODE_PLUGIN and "Bearer" in W.OPENCODE_PLUGIN
      and "} catch {}" in W.OPENCODE_PLUGIN)
W.remove_opencode_plugin()
check("关掉时删掉自己装的", not os.path.exists(target))
with open(target, "w") as handle:
    handle.write("// 用户自己的插件\n")
W.remove_opencode_plugin()
check("别人的同名文件不碰", os.path.exists(target))


# ---------------------------------------------------------------------------
print("== DeepSeek Harness：签名密钥与 cookie")

import hmac   # noqa: E402

DSH_SECRET = os.urandom(32)
os.makedirs(os.environ["DSH_HOME"])
with open(os.path.join(os.environ["DSH_HOME"], ".credentials.yaml"), "w") as handle:
    handle.write("version: 1\nrecords:\n  deepseek-account/session:\n    kind: grant\n    payload:\n      secret: not-this-one\n"
                 "  \"client-connection/browser-session\":\n    kind: grant\n    payload:\n      version: 1\n"
                 "      secret: '%s'\n  other/thing:\n    kind: token\n" % W._b64url(DSH_SECRET))
check("只取 client-connection/browser-session 这一条（别的凭据不碰，带引号也认）", W.dsh_secret() == DSH_SECRET)
check("没装 DSH：没有密钥", W.dsh_secret(os.path.join(ROOT, "nope")) is None)

# read_image 的结果：说明文字 + 图片附件（照 DSH 落盘的格式）→ 只给图，像 Claude 的 Read 读图
read_events = [
    {"seq": 5, "type": "assistant/message", "data": {"message": {"content": [
        {"type": "tool-call", "id": "c1", "name": "read_image", "arguments": json.dumps({"file_path": "/tmp/shot.png"})}]}}},
    {"seq": 6, "type": "tool/result", "data": {"message": {"toolCallId": "c1", "content": [
        {"type": "text", "text": "<path>/private/tmp/shot.png</path>\n<type>image</type>\n<content>\nimage/png image, 1600x900 px, 1495164 bytes\n</content>"},
        {"type": "image", "attachment": {"attachmentId": "sha256:ab", "mediaType": "image/png", "bytes": 1495164, "name": "shot.png"}}]}}},
    {"seq": 7, "type": "tool/result", "data": {"message": {"toolCallId": "c2", "content": [
        {"type": "text", "text": "截图已保存"}, {"type": "image", "attachment": {"attachmentId": "sha256:cd", "mediaType": "image/jpeg"}}]}}},
]
items = W.dsh_items(read_events)
check("DSH read_image → Read，结果只有图（ref 带 r，取图时到结果里找）",
      items[0]["name"] == "Read" and items[1]["text"] == "" and items[1]["images"] == [{"ref": "d6.r1", "mime": "image/png"}], str(items))
check("DSH 工具结果里别的文字照留，图也带上", items[2]["text"] == "截图已保存" and items[2]["images"][0]["ref"] == "d7.r1", str(items[2]))


def dsh_verify(cookie_header, authority, secret=None):
    """照 DSH 的 BrowserAuth.authenticate 验一遍"""
    name = "dsh-auth-" + W._b64url(hashlib.sha256(authority.encode()).digest())
    for part in (cookie_header or "").split(";"):
        key, _, value = part.strip().partition("=")
        if key != name:
            continue
        version, body, sig = value.split(".")
        expected = hmac.new(secret or DSH_SECRET, body.encode(), hashlib.sha256).digest()
        payload = json.loads(W._b64url_decode(body))
        now = time.time() * 1000
        return (version == "v1" and hmac.compare_digest(W._b64url_decode(sig), expected) and payload["authority"] == authority
                and payload["issuedAt"] <= now < payload["expiresAt"] and payload["expiresAt"] - payload["issuedAt"] <= 86400000)
    return False


cookie = W.dsh_cookie(DSH_SECRET, "127.0.0.1:3080")
check("cookie 按 DSH 的格式签：名字带 authority 摘要、HMAC、时效不超过 1 天", dsh_verify(cookie, "127.0.0.1:3080"))
check("换个端口不认", not dsh_verify(cookie, "127.0.0.1:3081"))
check("签发时间往前放（两边的钟差一点也不会被当成「未来」的 cookie）",
      json.loads(W._b64url_decode(cookie.split("=", 1)[1].split(".")[1]))["issuedAt"] < time.time() * 1000 - 60000)


# ---------------------------------------------------------------------------
print("== 假的 DeepSeek Harness 网页服务")

SID = "session-aaaa"


def dsh_event(seq, kind, data):
    return {"type": kind, "seq": seq, "time": 1792800000000 + seq, "data": data}


DSH_LOG = [
    dsh_event(0, "permission/preset", {"value": "workspace-write"}),
    dsh_event(3, "turn/start", {"turn": 1}),
    dsh_event(8, "user/message", {"content": [{"type": "text", "text": "跑一下测试"}], "source": {"kind": "user", "rpcId": "r1"}, "role": "user", "id": "u1"}),
    dsh_event(9, "user/message", {"content": [{"type": "text", "text": "Current runtime context."}], "source": {"kind": "runtime-context"}, "role": "user", "id": "u2"}),
    dsh_event(11, "request/header", {"header": {"tools": []}}),
    dsh_event(16, "assistant/message", {"turn": 1, "step": 1, "message": {"role": "assistant", "content": [
        {"type": "reasoning", "text": "先看看"},
        {"type": "tool-call", "id": "call_1", "name": "bash", "arguments": json.dumps({"command": "npm test", "description": "跑测试", "timeoutMs": 5000})},
        {"type": "tool-call", "id": "call_2", "name": "edit", "arguments": json.dumps({"file_path": "/w/a.js", "old_string": "a", "new_string": "b"})}]}}),
    dsh_event(22, "tool/result", {"turn": 1, "step": 1, "message": {"role": "tool", "toolCallId": "call_1", "content": [{"type": "text", "text": "3 passed"}], "isError": False}}),
    dsh_event(23, "tool/result", {"turn": 1, "step": 1, "message": {"role": "tool", "toolCallId": "call_2", "content": [{"type": "text", "text": "no match"}], "isError": True}}),
    dsh_event(26, "assistant/message", {"turn": 1, "step": 2, "message": {"role": "assistant", "content": [{"type": "text", "text": "测试都过了"}]}}),
    dsh_event(28, "turn/end", {"turn": 1, "reason": {"kind": "completed"}}),
]


class FakeDsh(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, secret=DSH_SECRET):
        super().__init__(("127.0.0.1", 0), FakeDshHandler)
        self.secret = secret
        self.calls = []          # (方法, 参数)
        self.opened = []         # (流端点, 参数)
        self.sockets = []
        self.client_id = "client-1"
        self.running = False
        threading.Thread(target=self.serve_forever, daemon=True).start()

    @property
    def authority(self):
        return "127.0.0.1:%d" % self.server_address[1]

    def push(self, endpoint, value):
        """往打开了这个端点的流推一条"""
        for conn, streams, lock in list(self.sockets):
            for stream, name in list(streams.items()):
                if name == endpoint:
                    data = json.dumps({"type": "item", "streamId": stream, "value": value}).encode()
                    size = len(data)
                    head = bytes([0x81, size]) if size < 126 else (bytes([0x81, 126]) + struct.pack(">H", size) if size < 65536
                                                                     else bytes([0x81, 127]) + struct.pack(">Q", size))
                    try:
                        with lock:
                            conn.sendall(head + data)
                    except OSError:
                        pass


class FakeDshHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authed(self):
        return self.headers.get("Host") == self.server.authority and dsh_verify(self.headers.get("Cookie"), self.server.authority, self.server.secret)

    def do_GET(self):
        if self.path == "/api/remote.mux" and self.authed():
            return self.mux()
        self.reply(401, b"dsh web authentication required; reopen the URL printed by dsh web.\n", "text/plain; charset=utf-8")

    def do_POST(self):
        size = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(size) or b"{}")
        if not self.authed():
            return self.reply(401, b"dsh web authentication required\n", "text/plain")
        method = self.path[len("/api/"):]
        args = (body.get("payload") or {}).get("args")
        self.server.calls.append((method, args))
        value, ok = None, True
        if method == "session/list":
            value = {"items": [
                {"sessionId": SID, "updatedAt": 1792800000028, "agentAvailable": True, "running": self.server.running, "blank": False,
                 "cwd": "/w/项目", "projections": {"kind": "sequenced", "asOfSeq": 28, "values": {"title": "缓存的标题"}}},
                {"sessionId": "session-cold", "agentAvailable": False, "running": False, "blank": False, "cwd": "/w/旧"},
                {"sessionId": "session-blank", "agentAvailable": True, "running": False, "blank": True, "cwd": "/w"}]}
        elif method == "session/page":
            request = args["request"]
            through, before = request["throughSeq"], request.get("beforeSeq", 10 ** 9)
            records = [{"type": "event", "event": e} for e in DSH_LOG if e["seq"] <= through and e["seq"] < before]
            value = {"records": records[-request.get("maxMessages", 50):], "hasMore": False}
        elif method in ("session/prompt", "session/cancel", "$events/result"):
            value = {"accepted": True} if method != "$events/result" else None
        else:
            ok = False
        self.reply(200, {"type": "server-response", "rpcId": body.get("rpcId"),
                         "result": {"ok": True, "value": value} if ok else {"ok": False, "error": {"code": "gateway/not-found", "message": method, "details": {}}}})

    def mux(self):
        key = self.headers.get("Sec-WebSocket-Key").encode()
        accept = base64.b64encode(hashlib.sha1(key + GUID.encode()).digest()).decode()
        self.wfile.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                          "Sec-WebSocket-Accept: %s\r\n\r\n" % accept).encode())
        self.wfile.flush()
        conn, streams, lock = self.connection, {}, threading.Lock()
        entry = (conn, streams, lock)
        self.server.sockets.append(entry)
        self.close_connection = True

        def exact(n):
            buf = b""
            while len(buf) < n:
                chunk = conn.recv(n - len(buf))
                if not chunk:
                    raise EOFError
                buf += chunk
            return buf
        try:
            while True:
                first, second = exact(2)
                size = second & 0x7F
                if size == 126:
                    size = struct.unpack(">H", exact(2))[0]
                elif size == 127:
                    size = struct.unpack(">Q", exact(8))[0]
                mask = exact(4)
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(exact(size)))
                if first & 0x0F == 8:
                    return
                frame = json.loads(data)
                if frame["type"] == "open":
                    streams[frame["streamId"]] = frame["endpoint"]
                    self.server.opened.append((frame["endpoint"], frame["payload"]["args"]))
                    if frame["endpoint"] == "$events":
                        self.server.push("$events", {"type": "ready", "clientId": self.server.client_id, "host": {"home": "/Users/x"}})
                    elif frame["endpoint"] == "session/control":
                        self.server.push("session/control", {"type": "baseline", "value": {"projections": {SID: {"asOfSeq": 28, "values": {
                            "title": "修测试", "tokenUsage": {"uncachedInputTokens": 1200, "outputTokens": 300, "cacheReadTokens": 5000, "cacheWriteTokens": 0},
                            "contextPressure": {"pressureTokens": 6500, "contextWindow": 1000000},
                            "modelSelection": {"lastUsed": {"provider": "deepseek-official", "model": "deepseek-flash"}}}}}}})
                    elif frame["endpoint"] == "session/follow":
                        self.server.push("session/follow", {"type": "snapshot", "header": {"id": SID}, "cursor": 28,
                                                            "records": [{"type": "event", "event": e} for e in DSH_LOG]})
                elif frame["type"] == "cancel":
                    streams.pop(frame["streamId"], None)
        except (EOFError, OSError, ValueError):
            return
        finally:
            if entry in self.server.sockets:
                self.server.sockets.remove(entry)


dsh = FakeDsh()
port = dsh.server_address[1]
check("探测：DSH 的网页服务（不带 cookie 回 401 和固定提示）认得出", W.dsh_probe(port))
check("探测：端口没人听 → 不是 DSH", not W.dsh_probe(1))
check("进程候选：桌面版后台、npm 装的 dsh（包路径或 PATH 里的 dsh 命令）都算，别的不算",
      all(W.DSH_PROCESS.search(c) for c in (
          "/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness --expose-internals /x/app.asar/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/index.js",
          "node /usr/local/bin/dsh --profile web", "node C:\\npm\\node_modules\\@deepseek-ai\\dsh\\lib\\bin.js --profile web"))
      and not any(W.DSH_PROCESS.search(c) for c in ("/usr/sbin/sshd -D", "vim dsh-notes.md", "bash ./dsh-start.sh")))
if os.path.isdir("/proc/self/fd"):
    check("Linux：从 /proc 认出进程在 127.0.0.1 上监听的端口", (os.getpid(), port) in W._linux_listeners({os.getpid()}))
real_listeners = W.dsh_listeners
W.dsh_listeners = lambda: [(os.getpid(), port)]
dlink = W.DshLink()
snap = wait(lambda: (dlink.snapshots() or [None])[0], timeout=10)
check("连上：只列载入过、说过话的会话（冷的、空白的不列）", snap and [s["sessionId"] for s in dlink.snapshots()] == [SID], str(dlink.snapshots())[:300])
check("快照：标题（control 流）、目录、agent、用量、上下文窗口", snap and snap["title"] == "修测试" and snap["cwd"] == "/w/项目"
      and snap["agent"] == "deepseek-harness" and snap["usage"]["context"] == 6500 and snap["usage"]["window"] == 1000000
      and snap["usage"]["cacheRead"] == 5000 and snap["usage"]["model"] == "deepseek-flash", str(snap)[:400])
check("快照：最后一句回复", snap and snap["message"] == "测试都过了" and snap["activity"] == "idle", str(snap)[:300])
check("跟着这个会话：session/follow 带地址和窗口", any(e == "session/follow" and a["request"]["address"] == {"kind": "session", "sessionId": SID}
                                                   and a["request"]["maxMessages"] for e, a in dsh.opened), str(dsh.opened)[:300])
pumped = wait(lambda: dlink.pump())
items = pumped[0][1] if pumped else []
kinds = [(i["t"], i.get("name")) for i in items]
check("对话项：只要用户自己的话（运行环境那些不算）", [i["text"] for i in items if i["t"] == "user"] == ["跑一下测试"], str(items)[:300])
check("对话项：bash → Bash、edit → Edit，思考、结果、出错", kinds == [("user", None), ("thinking", None), ("tool", "Bash"), ("tool", "Edit"),
                                                          ("result", None), ("result", None), ("text", None)], str(kinds))
bash_item = next(i for i in items if i.get("name") == "Bash")
check("对话项：id 是「事件序号.块序号」、工具字段对上 Claude（timeoutMs → timeout）", bash_item["id"] == "16.1" and bash_item["input"]["timeout"] == 5000
      and bash_item["brief"] == "Bash: npm test", str(bash_item))
check("对话项：工具出错标成失败", [i["isError"] for i in items if i["t"] == "result"] == [False, True])
check("没变化不重复推", dlink.pump() == [])

host = dlink.owner(SID)
dsh.push("$events", {"type": "waterfall", "event": "approval/request", "eventId": "ev-1", "agentId": SID,
                     "request": {"toolName": "bash", "callId": "call_3", "reason": "escalate sandbox",
                                 "displayReason": {"en": "Allow this operation", "zh": "允许本次操作使用 danger-full-access 权限：要装依赖"}}})
snap = wait(lambda: next((s for s in dlink.snapshots() if s["activity"] == "waiting"), None))
check("审批请求 → 等确认，说明用中文那句", snap and snap["pendingTool"] == "Bash" and snap["waitingFor"] == "允许本次操作使用 danger-full-access 权限：要装依赖"
      and snap["pendingId"] == "ev-1", str(snap)[:300])
dplugin = W.DshPlugin.__new__(W.DshPlugin)   # 用上面这个 dlink，不另起一个
dplugin.link = dlink
plugins = W.AgentPlugins([dplugin], on={"deepseek-harness"})   # 只要 DSH 这一路：走插件注册表的分发；DSH 默认不接，当作用户打开了
plugins.handle("deepseek-harness", {"cmd": "agent_key", "sessionId": SID, "key": "1"})
check("按 1 → $events/result 回 allowed-once，带这一代的 clientId",
      ("$events/result", {"clientId": "client-1", "eventId": "ev-1", "outcome": {"kind": "result", "value": "allowed-once"}}) in dsh.calls, str(dsh.calls[-1:]))
check("答完不再算待确认", wait(lambda: all(s["activity"] != "waiting" for s in dlink.snapshots())))
dsh.push("$events", {"type": "waterfall", "event": "approval/request", "eventId": "ev-2", "agentId": SID, "request": {"toolName": "write", "reason": "x"}})
wait(lambda: host.request_for(SID))
plugins.handle("deepseek-harness", {"cmd": "agent_key", "sessionId": SID, "key": "escape"})
check("Esc → rejected（DSH 没有「本会话都允许」，2 也按允许一次）",
      dsh.calls[-1][1]["outcome"]["value"] == "rejected" and W.DSH_DECISIONS["2"] == "allowed-once", str(dsh.calls[-1:]))
dsh.push("$events", {"type": "waterfall", "event": "approval/request", "eventId": "ev-3", "agentId": SID, "request": {"toolName": "bash"}})
wait(lambda: host.request_for(SID))
dsh.push("$events", {"type": "cancel", "eventId": "ev-3"})
check("桌面窗口先答了（收到撤销）→ 不再算待确认", wait(lambda: host.request_for(SID) is None))

dsh.push("$events", {"type": "waterfall", "event": "user-questions/request", "eventId": "ev-4", "agentId": SID, "request": {"questions": [
    {"id": "q1", "question": "部署到哪", "header": "环境", "options": [{"label": "预发"}, {"label": "正式"}]},
    {"id": "q2", "question": "要通知谁", "options": [{"label": "群里"}]}]}})
snap = wait(lambda: next((s for s in dlink.snapshots() if s["activity"] == "waiting"), None))
check("提问 → 等你回答", snap and snap["pendingTool"] == "AskUserQuestion" and snap["waitingFor"] == "部署到哪", str(snap)[:200])
plugins.handle("deepseek-harness", {"cmd": "agent_answer", "sessionId": SID,
                                  "answers": [{"question": "部署到哪", "picked": ["预发"]}, {"question": "要通知谁", "picked": [], "other": "张三"}]})
check("回答：选项进 selected，自己写的进 custom，每题带 id",
      dsh.calls[-1] == ("$events/result", {"clientId": "client-1", "eventId": "ev-4", "outcome": {"kind": "result", "value": {"answers": [
          {"id": "q1", "selected": ["预发"]}, {"id": "q2", "selected": [], "custom": "张三"}]}}}), str(dsh.calls[-1:]))

plugins.handle("deepseek-harness", {"cmd": "agent_send", "sessionId": SID, "text": "再加个测试"})
prompt = dsh.calls[-1]
check("空闲时发消息 → session/prompt（queue，开新一轮）", prompt[0] == "session/prompt" and prompt[1]["request"]["mode"] == "queue"
      and prompt[1]["request"]["content"] == [{"type": "text", "text": "再加个测试"}] and prompt[1]["request"]["requestId"], str(prompt)[:300])
dsh.push("$events", {"type": "emit", "event": "api-session/status", "args": [SID, True]})
snap = wait(lambda: next((s for s in dlink.snapshots() if s["activity"] == "busy"), None))
check("忙闲广播 → 正在工作", snap is not None)
image = os.path.join(ROOT, "shot.png")
with open(image, "wb") as handle:
    handle.write(b"\x89PNG\r\n\x1a\nfake")
plugins.handle("deepseek-harness", {"cmd": "agent_send", "sessionId": SID, "text": "看这张图", "images": [image]})
request = dsh.calls[-1][1]["request"]
check("忙时发消息 → steer（插进这一轮）；图片按 base64 给", request["mode"] == "steer" and request["content"][1]["type"] == "image"
      and base64.b64decode(request["content"][1]["data"]) == b"\x89PNG\r\n\x1a\nfake" and request["content"][1]["mediaType"] == "image/png", str(request)[:300])
plugins.handle("deepseek-harness", {"cmd": "agent_key", "sessionId": SID, "key": "esc"})
check("忙时 Esc（没有待确认）→ session/cancel", dsh.calls[-1] == ("session/cancel", {"request": {"sessionId": SID}}), str(dsh.calls[-1:]))
dsh.push("session/follow", {"type": "event", "event": dsh_event(40, "user/message", {"content": [{"type": "text", "text": "再加个测试"}], "source": {"kind": "user"}})})
dsh.push("session/follow", {"type": "event", "event": dsh_event(45, "turn/end", {"turn": 2, "reason": {"kind": "cancelled"}})})
got = []
wait(lambda: got.extend(i for _, batch in dlink.pump() for i in batch) or len(got) >= 2)
check("增量：新事件推过来；中断记成「已中断」", [(i["t"], i["text"]) for i in got] == [("user", "再加个测试"), ("event", "已中断")], str(got))
items, more = dlink.owner(SID).history(SID, 16, 80)
check("翻历史：session/page 带 throughSeq（已知最新序号）和 beforeSeq", dsh.calls[-1][0] == "session/page"
      and dsh.calls[-1][1]["request"]["throughSeq"] == 45 and dsh.calls[-1][1]["request"]["beforeSeq"] == 16
      and [i["id"] for i in items] == ["8.0"] and more is False, str(dsh.calls[-1:]) + str(items)[:200])
try:
    plugins.handle("deepseek-harness", {"cmd": "agent_key", "sessionId": SID, "key": "1"})
    check("没有待确认时按 1 → 报错", False)
except RuntimeError:
    check("没有待确认时按 1 → 报错", True)
dsh.push("$events", {"type": "emit", "event": "api-session/removed", "args": [SID]})
dsh.push("$events", {"type": "emit", "event": "api-session/added", "args": [
    {"sessionId": "session-new", "agentAvailable": True, "running": False, "blank": True, "cwd": "/w/新"}]})
check("新建的空白会话不列", wait(lambda: host.rows.get("session-new")) and "session-new" not in [s["sessionId"] for s in dlink.snapshots()])
dsh.push("session/control", {"type": "projection", "sessionId": "session-new", "key": "sessionListMetadata", "value": {"blank": False, "lastPromptAt": 1}, "seq": 4})
check("说过话以后（DSH 只更新投影里的 blank，不再推列表行）→ 列出来",
      wait(lambda: "session-new" in [s["sessionId"] for s in dlink.snapshots()]), str(host.projections.get("session-new")))
dsh.push("$events", {"type": "emit", "event": "api-session/removed", "args": ["session-new"]})
check("会话删了 → 不再列", wait(lambda: dlink.snapshots() == []))

bad = FakeDsh(secret=os.urandom(32))   # 用的是另一份 DSH_HOME
bad_key = (os.getpid(), bad.server_address[1])
W.dsh_listeners = lambda: [bad_key]


def given_up():
    dlink.last_scan = 0
    dlink.snapshots()
    return dlink.checked.get(bad_key) is False and bad_key not in dlink.hosts


check("密钥对不上（别的 DSH_HOME）→ 放弃、不反复重连", wait(given_up, timeout=10), str(dlink.checked))
calls_before = len(bad.calls)
given_up()
check("放弃之后不再去连", len(bad.calls) == calls_before)
W.dsh_listeners = lambda: []
dlink.last_scan = 0
dlink.snapshots()
check("进程退出（端口不在了）→ 断开", not dlink.hosts)
W.dsh_listeners = real_listeners
for server in (dsh, bad):
    server.shutdown()
    server.server_close()


# ---------------------------------------------------------------------------
print("== Proma")

PROMA = os.environ["CCPULSE_PROMA_DIR"]
os.makedirs(os.path.join(PROMA, "agent-sessions"))
now_ms = int(time.time() * 1000)


def proma_line(obj):
    return json.dumps(obj, ensure_ascii=False) + "\n"


user_line = {"type": "user", "uuid": "u1", "message": {"content": [{"type": "text", "text": "整理一下周报"}]}, "parent_tool_use_id": None, "_createdAt": now_ms - 60000}
assistant_tool = {"type": "assistant", "message": {"content": [{"type": "thinking", "thinking": "看看文件"},
                                                               {"type": "tool_use", "id": "tu1", "name": "Read", "input": {"file_path": "/w/周报.md"}}],
                                                   "usage": {"input_tokens": 900, "output_tokens": 40, "cache_read_input_tokens": 3000}, "model": "glm-5"},
                  "_createdAt": now_ms - 50000, "_channelModelId": "glm-5"}
tool_result = {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "tu1", "content": "第 1 周……"}]}, "_createdAt": now_ms - 40000}
assistant_text = {"type": "assistant", "message": {"content": [{"type": "text", "text": "周报整理好了"}], "usage": {"input_tokens": 1000, "output_tokens": 80}}, "_createdAt": now_ms - 30000}
result_ok = {"type": "result", "subtype": "success", "_createdAt": now_ms - 30000, "_durationMs": 30000}
items = []
for offset, entry in enumerate([user_line, assistant_tool, tool_result, assistant_text, result_ok]):
    items.extend(W.normalize_proma_line(offset * 100, entry))
check("Proma 规整：用户、思考、Read、结果、回复（result 不出项）", [(i["t"], i.get("name")) for i in items] ==
      [("user", None), ("thinking", None), ("tool", "Read"), ("result", None), ("text", None)], str(items)[:300])
check("Proma 规整：时间取 _createdAt（毫秒）", items[0]["ts"] == now_ms - 60000, str(items[0]))
err = W.normalize_proma_line(7, {"type": "result", "subtype": "error_during_execution", "errors": ["渠道余额不足"], "_createdAt": now_ms})
check("Proma 规整：一轮出错 → 红色提示", err and err[0]["level"] == "error" and "渠道余额不足" in err[0]["text"], str(err))
legacy = W.normalize_proma_line(9, {"role": "assistant", "content": "旧版的回复", "createdAt": now_ms})
check("Proma 规整：很早的 {role, content} 格式也认", legacy and legacy[0]["t"] == "text" and legacy[0]["text"] == "旧版的回复", str(legacy))


def proma_write(sid, entries):
    with open(os.path.join(PROMA, "agent-sessions", sid + ".jsonl"), "w") as handle:
        handle.write("".join(proma_line(e) for e in entries))


proma_write("done", [user_line, assistant_tool, tool_result, assistant_text, result_ok])
proma_write("running", [user_line])
proma_write("old", [user_line, assistant_text, result_ok])
os.utime(os.path.join(PROMA, "agent-sessions", "old.jsonl"), (time.time() - 86400, time.time() - 86400))
proma_write("failed", [user_line, {"type": "result", "subtype": "error_max_turns", "_createdAt": now_ms}])
for sid in ("child", "draft", "archived"):
    proma_write(sid, [user_line])
with open(os.path.join(PROMA, "agent-sessions.json"), "w") as handle:
    json.dump({"version": 1, "sessions": [
        {"id": "done", "title": "周报", "workspaceId": "w1", "agentCwdMode": "project", "createdAt": now_ms - 70000, "updatedAt": now_ms - 30000},
        {"id": "running", "title": "跑数据", "workspaceId": "w2", "createdAt": now_ms - 60000, "updatedAt": now_ms - 60000},
        {"id": "old", "title": "上周的", "workspaceId": "w1", "createdAt": now_ms - 90000000, "updatedAt": now_ms - 86400000},
        {"id": "failed", "title": "失败的", "workspaceId": "w1", "createdAt": now_ms, "updatedAt": now_ms},
        {"id": "child", "title": "子会话", "parentSessionId": "done", "createdAt": now_ms, "updatedAt": now_ms},
        {"id": "draft", "title": "草稿", "isDraft": True, "createdAt": now_ms, "updatedAt": now_ms},
        {"id": "archived", "title": "归档", "archived": True, "createdAt": now_ms, "updatedAt": now_ms}]}, handle)
with open(os.path.join(PROMA, "agent-workspaces.json"), "w") as handle:
    json.dump({"version": 1, "workspaces": [{"id": "w1", "name": "工作", "slug": "work", "projectRootPath": "/Users/x/项目"},
                                            {"id": "w2", "name": "默认", "slug": "default"}]}, handle)
real_running = W.proma_running
W.proma_running = lambda: False
plink = W.PromaLink()
check("Proma 没开着：一个都不列", plink.snapshots() == [])
W.proma_running = lambda: True
plink.checked = 0
psnaps = {s["sessionId"]: s for s in plink.snapshots()}
check("Proma 开着：列最近动过的（太久没动的、子会话、草稿、归档不列）", sorted(psnaps) == ["done", "failed", "running"], str(sorted(psnaps)))
done = psnaps.get("done") or {}
check("做完的：空闲、最后一句回复、用量（含缓存）、模型、子会话数", done.get("activity") == "idle" and done.get("message") == "周报整理好了"
      and done.get("usage", {}).get("input") == 1000 and done.get("subagents") == 1 and done.get("agent") == "proma", str(done)[:400])
check("只写了用户那句、还没结果 → 正在工作", (psnaps.get("running") or {}).get("activity") == "busy")
check("一轮出错 → 带错误", "error_max_turns" in (((psnaps.get("failed") or {}).get("error") or {}).get("text") or ""), str(psnaps.get("failed"))[:300])
check("工作目录：project 模式用项目目录，默认用会话自己的工作台目录", done.get("cwd") == "/Users/x/项目"
      and (psnaps.get("running") or {}).get("cwd") == os.path.join(PROMA, "agent-workspaces", "default", "running"))
check("只读（Proma 没有对外接口），带对话文件给 watcher 跟", done.get("readOnly") is True and done.get("transcriptPath", "").endswith("done.jsonl"))
with open(os.path.join(PROMA, "agent-sessions", "running.jsonl"), "a") as handle:
    handle.write(proma_line(assistant_text) + proma_line(result_ok))
check("这一轮写盘了 → 空闲", next(s for s in plink.snapshots() if s["sessionId"] == "running")["activity"] == "idle")
pplugin = W.PromaPlugin.__new__(W.PromaPlugin)
pplugin.link = plink
plugins = W.AgentPlugins([dplugin, pplugin], on={"deepseek-harness"})
try:
    plugins.handle("proma", {"cmd": "agent_send", "sessionId": "done", "text": "hi"})
    check("Proma 不能远程回复：说清楚", False)
except RuntimeError as exc:
    check("Proma 不能远程回复：说清楚", "Proma" in str(exc) and "只能查看" in str(exc), str(exc))
watcher = W.Watcher(plugins=plugins)
watcher.track([done])
check("watcher 用 Proma 的规整函数跟对话文件", watcher.normalizer("done") is not W.normalize_line
      and [i["t"] for i in watcher.normalizer("done")(0, user_line)] == ["user"])
hist = watcher.handle({"cmd": "history", "sessionId": "done", "limit": 80})
check("翻历史走对话文件", [i["t"] for i in hist["items"]] == ["user", "thinking", "tool", "result", "text"], str(hist)[:300])
found = watcher.handle({"cmd": "search", "sessionId": "done", "q": "周报"})
check("会话内搜索", len(found["results"][0]["hits"]) == 2, str(found)[:300])

# 照真实 Proma 0.19.58 写出的样子（kl-ubuntu 实测）：定时任务的话带标记；助手消息记的是这一轮开始的时间（比用户那句还早），
# 工具结果、结尾记的是写盘时间（比后面那句回复还晚）
t0 = now_ms - 5000
proma_write("real", [
    {"type": "user", "uuid": "r1", "message": {"content": [{"type": "text", "text": "run: echo ok\n<!--PROMA_SCHEDULED_RUN-->"}]}, "parent_tool_use_id": None, "_createdAt": t0 + 4},
    {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "b1", "name": "Bash", "input": {"command": "echo ok"}}]}, "_createdAt": t0, "session_id": "s"},
    {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "b1", "content": "ok"}]}, "_createdAt": t0 + 1838, "session_id": "s"},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "好了"}]}, "_createdAt": t0, "session_id": "s"},
    {"type": "result", "subtype": "success", "_createdAt": t0 + 1840, "usage": {"input_tokens": 200, "output_tokens": 40}, "total_cost_usd": 0}])
real = {"sessionId": "real", "transcriptPath": os.path.join(PROMA, "agent-sessions", "real.jsonl"), "agent": "proma"}
watcher.track([done, real])
live = []
with open(real["transcriptPath"], "rb") as handle:
    offset = 0
    for raw in handle:
        entry = W.parse_line(raw)
        live.extend(watcher.normalizer("real")(offset, entry))
        offset += len(raw)
check("定时任务的话去掉 Proma 的内部标记", live[0]["t"] == "user" and live[0]["text"] == "run: echo ok", repr(live[0].get("text")))
check("时间修成不倒退：按时间排和按文件顺序一致（手机先按时间排）",
      [i["t"] for i in sorted(live, key=lambda i: (i["ts"], int(i["id"].split(".")[0]), int(i["id"].split(".")[1])))] == ["user", "tool", "result", "text"],
      str([(i["t"], i["ts"]) for i in live]))
page = watcher.handle({"cmd": "history", "sessionId": "real", "limit": 80})["items"]
check("翻历史（倒着读）拿到的时间和实时推的一样", [(i["id"], i["ts"]) for i in page] == [(i["id"], i["ts"]) for i in live], str(page)[:300])
W.proma_running = real_running

print("\n== 插件注册表")
builtin = W.AgentPlugins(on={"deepseek-harness"})   # 只建不 start：不连 socket、不装 OpenCode 插件；DSH 当作用户打开了
check("内置插件：Codex、OpenCode、DSH、Proma，都启用", [p.id for p in builtin.all] == ["codex", "opencode", "deepseek-harness", "proma"],
      str([p.id for p in builtin.all]))
check("用户没打开时 DSH 不接（默认不接），其余照常", [p.id for p in W.AgentPlugins().all] == ["codex", "opencode", "proma"])
check("内置插件用到的中台能力都在登记表里", all(cap in W.HOST_CAPS for p in builtin.all for cap in p.needs))
check("落文件的插件带规整函数，watcher 原样拿来用", builtin.get("codex").normalize is W.normalize_codex_line
      and builtin.get("proma").normalize is W.normalize_proma_line and builtin.get("opencode").normalize is None)


class FakePlugin(W.AgentPlugin):
    id, name = "fake", "Fake"

    def sessions(self):
        return [{"sessionId": "f1", "agent": "fake"}]


class BrokenPlugin(W.AgentPlugin):
    id, name = "broken", "Broken"

    def sessions(self):
        raise RuntimeError("坏了")

    def pump(self):
        raise RuntimeError("坏了")


class NeedsMore(W.AgentPlugin):
    id, name, needs = "future", "Future", ("fs.read", "net.quic")


reg = W.AgentPlugins([BrokenPlugin(), FakePlugin(), NeedsMore()])
check("用到登记表里没有的能力：不启用", reg.get("future") is None and [p.id for p in reg.all] == ["broken", "fake"])
check("一个插件出错不影响别家（快照、取对话）", reg.sessions() == [{"sessionId": "f1", "agent": "fake", "caps": []}] and reg.pump() == [])
try:
    reg.handle("nobody", {"cmd": "agent_send", "sessionId": "x", "text": "hi"})
    check("没有对应插件：说不支持", False)
except RuntimeError as exc:
    check("没有对应插件：说不支持", "不支持的 agent" in str(exc), str(exc))
try:
    reg.handle("fake", {"cmd": "agent_send", "sessionId": "f1", "text": "hi"})
    check("插件没实现发消息：说明不支持", False)
except RuntimeError as exc:
    check("插件没实现发消息：说明不支持", "Fake" in str(exc) and "不支持" in str(exc), str(exc))
fw = W.Watcher(plugins=reg)
fw.track(reg.sessions())
check("插件会话记下所属 agent", fw.agents.get("f1") == "fake")
check("插件会话：Claude 专属的请求（子 agent、测试）回空", fw.handle({"cmd": "agents", "sessionId": "f1"}) == {"agents": [], "tasks": []}
      and fw.handle({"cmd": "tests", "sessionId": "f1"}) == {"runs": []})
try:
    fw.handle({"cmd": "history", "sessionId": "f1"})
    check("没有记录文件、也没实现历史：说清楚", False)
except RuntimeError as exc:
    check("没有记录文件、也没实现历史：说清楚", "没有历史记录" in str(exc), str(exc))
check("能力：能看能回复能审批 / 只读的只能看", builtin.get("codex").abilities() == ["view", "reply", "approve", "answer"]
      and builtin.get("proma").abilities() == ["view"])

print("\n== 标准字段（caps、待确认的按钮、只读说明：手机只认这些，不认 agent 名字）")


class AskingPlugin(W.AgentPlugin):
    id, name = "asking", "Asking"

    def __init__(self, tool="Bash"):
        self.tool = tool

    def sessions(self):
        return [{"sessionId": "a1", "agent": self.id, "activity": "waiting", "pendingTool": self.tool},
                {"sessionId": "a2", "agent": self.id, "activity": "busy"}]

    def key(self, sid, key):
        return key


snaps = W.AgentPlugins([AskingPlugin()]).sessions()
check("插件会话都带 caps（没有额外功能就是空的）", all(s.get("caps") == [] for s in snaps), str(snaps))
check("等确认：默认给拒绝 / 允许 / 本会话都允许，按键和以前手机发的一样",
      [(o["key"], o["style"]) for o in snaps[0].get("pendingOptions") or []] == [("esc", "destructive"), ("1", "primary"), ("2", "normal")], str(snaps[0]))
check("不在等确认：不带按钮", "pendingOptions" not in snaps[1])
snaps[0]["pendingOptions"][0]["label"] = "改过"
check("每个会话拿到的是一份副本：改了不影响下一次", W.AgentPlugins([AskingPlugin()]).sessions()[0]["pendingOptions"][0]["label"] == "拒绝")
check("提问、计划：不给按钮（客户端有专门的卡片）", all("pendingOptions" not in W.AgentPlugins([AskingPlugin(tool)]).sessions()[0]
                                                    for tool in ("AskUserQuestion", "ExitPlanMode")))
check("没实现按键的插件：不给按钮", "pendingOptions" not in FakePlugin().standardize({"activity": "waiting", "pendingTool": "Bash"}))
check("DeepSeek Harness：只有拒绝 / 允许这一次", [o["key"] for o in builtin.get("deepseek-harness").pending_options(
    {"activity": "waiting", "pendingTool": "Bash"})] == ["esc", "1"])
proma_snap = builtin.get("proma").standardize({"sessionId": "p", "readOnly": True, "activity": "waiting", "pendingTool": "Bash"})
check("只读的：带只读说明、不带按钮", proma_snap.get("readOnlyReason") == builtin.get("proma").read_only
      and "pendingOptions" not in proma_snap, str(proma_snap))
own = AskingPlugin().standardize({"activity": "waiting", "pendingTool": "Bash", "caps": ["compact"],
                                  "pendingOptions": [{"key": "y", "label": "是"}], "readOnly": True, "readOnlyReason": "自己说"})
check("插件自己给的 caps、按钮、只读说明不被覆盖", own["caps"] == ["compact"] and own["pendingOptions"] == [{"key": "y", "label": "是"}]
      and own["readOnlyReason"] == "自己说")
row = next(r for r in W.AgentPlugins([AskingPlugin()]).describe() if r["id"] == "asking")
check("设置页的插件信息带 caps；没标志、没称呼的不带这两项", row.get("caps") == [] and "mark" not in row and "speaker" not in row, str(row))

print("\n== 外部插件")
PDIR = os.path.join(ROOT, "plugins")


def make_plugin(pid, version, code, needs=("fs.read",), name=None, **manifest):
    folder = os.path.join(PDIR, pid)
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "plugin.json"), "w") as handle:
        json.dump(dict({"id": pid, "name": name or pid, "version": version, "needs": list(needs)}, **manifest), handle)
    with open(os.path.join(folder, "plugin.py"), "w") as handle:
        handle.write(code)


make_plugin("newagent", "1.2.0", '''
def create(kl):
    class P(kl.AgentPlugin):
        def sessions(self):
            return [{"sessionId": "n1", "agent": self.id, "activity": "idle"}]
        def send(self, sid, text, images):
            return "已发给新 agent：" + text
    return P()
''', name="新 Agent", mark=[{"d": "M0 0h24v24H0z", "opacity": 1}], speaker="新", caps=["compact"], minApp={"ios": "1.3"})
make_plugin("proma", "9.0.0", '''
def create(kl):
    class P(kl.PromaPlugin):
        def sessions(self):
            return [{"sessionId": "p-ext", "agent": "proma"}]
    return P()
''')
make_plugin("codex", "0.0.1", "def create(kl):\n    return kl.CodexPlugin()\n")
make_plugin("broken", "1.0.0", "def create(kl) oops\n")
make_plugin("opencode", "5.0.0", "def create(kl):\n    return kl.OpenCodePlugin()\n", needs=("net.quic",))
make_plugin("deepseek-harness", "3.0.0", '''
def create(kl):
    class P(kl.AgentPlugin):
        name = "坏掉的 DSH"
        def sessions(self):
            raise ValueError("协议变了")
    return P()
''')
external, broken_plugins = W.load_external_plugins(PDIR)
check("外部插件：读得出清单和代码，坏的单独列出", sorted(p.id for p in external) == ["codex", "deepseek-harness", "newagent", "opencode", "proma"]
      and [b["id"] for b in broken_plugins] == ["broken"] and "SyntaxError" in broken_plugins[0]["error"], str(broken_plugins))
emitted = []
real_emit = W.emit
W.emit = emitted.append


def idle_builtin(cls):
    """内置插件的替身：不连任何东西，快照、对话都是空的"""
    plugin = cls.__new__(cls)
    plugin.sessions = lambda: []
    plugin.pump = lambda: []
    return plugin


reg = W.AgentPlugins([idle_builtin(c) for c in (W.CodexPlugin, W.OpenCodePlugin, W.DshPlugin, W.PromaPlugin)],
                     external=external, off=(), on={"deepseek-harness"})
check("新 agent 的插件直接启用（不用发版）", reg.get("newagent") is not None and reg.get("newagent").source == "external"
      and reg.get("newagent").name == "新 Agent")
check("同 id 更新的外部版本顶替内置的", reg.get("proma").version == "9.0.0" and reg.get("proma").source == "external")
check("不比内置新的外部版本不用", reg.get("codex").source == "builtin")
check("外部版本要的中台能力没有：先用内置的，标「需要更新」", reg.get("opencode").source == "builtin"
      and reg.status["opencode"]["status"] == "incompatible" and reg.status["opencode"]["missing"] == ["net.quic"]
      and reg.status["opencode"]["wanted"] == "5.0.0")
check("经插件分派到新 agent", reg.handle("newagent", {"cmd": "agent_send", "sessionId": "n1", "text": "hi"})["message"] == "已发给新 agent：hi")
newagent_row = next(r for r in reg.describe() if r["id"] == "newagent")
check("清单里的标志、称呼、caps：设置页信息带上（电脑端转给手机画标志），快照里的 caps 照清单",
      newagent_row.get("mark") == [{"d": "M0 0h24v24H0z", "opacity": 1}] and newagent_row.get("speaker") == "新"
      and newagent_row.get("caps") == ["compact"] and newagent_row.get("minApp") == {"ios": "1.3"}
      and next(s for s in reg.sessions() if s["sessionId"] == "n1")["caps"] == ["compact"], str(newagent_row)[:300])
for _ in range(W.PLUGIN_FAIL_LIMIT):
    sessions = reg.sessions()
check("外部插件出错：只报一次给电脑端（弹窗问要不要报告）", len([e for e in emitted if e["event"] == "plugin_error"]) == 1
      and emitted[0]["id"] == "deepseek-harness" and "协议变了" in emitted[0]["error"] and emitted[0]["version"] == "3.0.0", str(emitted[:1])[:300])
retired = next((e for e in emitted if e["event"] == "plugin_retired"), None)
check("连续出错 %d 轮：停用，换回内置版本，通知电脑端退回文件" % W.PLUGIN_FAIL_LIMIT, retired and retired["fallback"] == "1.0.0"
      and reg.get("deepseek-harness").source == "builtin" and reg.status["deepseek-harness"]["status"] == "retired", str(retired))
check("别的插件照常出快照", any(s["sessionId"] == "n1" for s in sessions) and any(s["sessionId"] == "p-ext" for s in sessions))
rows = {r["id"]: r for r in reg.describe()}
check("设置页的列表：每家一行，带版本、来源、状态、能力", sorted(rows) == ["codex", "deepseek-harness", "newagent", "opencode", "proma"]
      and rows["newagent"]["version"] == "1.2.0" and rows["newagent"]["abilities"] == ["view", "reply"]
      and rows["deepseek-harness"]["status"] == "retired" and rows["proma"]["status"] == "ok", str(rows)[:400])
off_called = []
quiet = W.OpenCodePlugin.__new__(W.OpenCodePlugin)
quiet.disable = lambda: off_called.append("opencode")
reg2 = W.AgentPlugins([quiet], external=[], off={"opencode"})
reg2.start()
check("设置里关掉的：不启用，并把装进 agent 的东西删掉", reg2.get("opencode") is None and off_called == ["opencode"]
      and reg2.describe()[0]["status"] == "off")
dsh_row = W.AgentPlugins([idle_builtin(W.DshPlugin)], external=[], off=()).describe()[0]
check("DeepSeek Harness 默认不接（不是它开放的接入方式），设置页带上开启前要看的说明",
      dsh_row["status"] == "off" and "browser-session" in dsh_row.get("optIn", ""), str(dsh_row)[:300])
check("用户在设置里打开了才接", W.AgentPlugins([idle_builtin(W.DshPlugin)], external=[], off=(), on={"deepseek-harness"}).get("deepseek-harness") is not None)
check("打开过又关掉：以关掉为准", W.AgentPlugins([idle_builtin(W.DshPlugin)], external=[], off={"deepseek-harness"},
                                         on={"deepseek-harness"}).get("deepseek-harness") is None)
shy_dir = os.path.join(ROOT, "plugins-optin", "shy")
os.makedirs(shy_dir)
with open(os.path.join(shy_dir, "plugin.json"), "w") as handle:
    json.dump({"id": "shy", "name": "Shy", "version": "1.0.0", "needs": ["fs.read"], "optIn": "要读它的密钥", "optInEn": "Reads its key"}, handle)
with open(os.path.join(shy_dir, "plugin.py"), "w") as handle:
    handle.write("def create(kl):\n    return kl.AgentPlugin()\n")
shy_row = W.AgentPlugins([], external=W.load_external_plugins(os.path.dirname(shy_dir))[0], off=()).describe()[0]
check("外部插件清单写了 optIn：同样默认不接，中英文说明带给设置页",
      shy_row["status"] == "off" and shy_row.get("optIn") == "要读它的密钥" and shy_row.get("optInEn") == "Reads its key", str(shy_row)[:300])


class FlakyDsh(W.AgentPlugin):
    id, name, version, source = "deepseek-harness", "坏掉的 DSH", "3.0.0", "external"

    def sessions(self):
        raise ValueError("协议变了")


reg4 = W.AgentPlugins([idle_builtin(W.DshPlugin)], external=[FlakyDsh()], off=())
for _ in range(W.PLUGIN_FAIL_LIMIT):
    reg4.sessions()
check("外部版本连续出错停用时：内置的是默认不接、用户没打开的，不擅自换上",
      reg4.get("deepseek-harness") is None and reg4.status["deepseek-harness"]["status"] == "retired", str(reg4.status))
fw2 = W.Watcher(plugins=reg)
listed = fw2.handle({"cmd": "plugins"})
check("watcher 的 plugins 请求：插件列表 + 中台能力", "newagent" in [r["id"] for r in listed["plugins"]] and "fs.read" in listed["hostCaps"]
      and listed["hostApi"] == W.HOST_API)
W.emit = real_emit

print("\n== Qwen Code 插件（plugins/qwen-code：单独下发，不随 Kiteline 发版）")
QHOME = os.path.join(ROOT, "qwen")
QCWD = "/tmp/qwen-proj"
QCHATS = os.path.join(QHOME, "projects", "".join(c if c.isalnum() else "-" for c in QCWD), "chats")
os.makedirs(os.path.join(QHOME, "sessions"))
os.makedirs(QCHATS)
with open(os.path.join(QHOME, "sessions", "%d.json" % os.getpid()), "w") as handle:
    json.dump({"pid": os.getpid(), "sessionId": "q-1", "cwd": QCWD, "startedAt": 1}, handle)
with open(os.path.join(QCHATS, "q-1.jsonl"), "w") as handle:
    for entry in ({"type": "user", "timestamp": "2026-10-24T08:00:00Z", "message": {"role": "user", "parts": [{"text": "跑一下测试"}]}},
                  {"type": "assistant", "uuid": "a1", "timestamp": "2026-10-24T08:00:01Z", "message": {"role": "model", "parts": [
                      {"text": "想一想", "thought": True}, {"text": "好的，先跑测试。"},
                      {"functionCall": {"id": "c1", "name": "run_shell_command", "args": {"command": "npm test"}}}]}}):
        handle.write(json.dumps(entry, ensure_ascii=False) + "\n")
os.environ["QWEN_HOME"] = QHOME
qwen = next(p for p in W.load_external_plugins(os.path.join(os.path.dirname(WATCHER), "..", "plugins"))[0] if p.id == "qwen-code")
qsnap = W.AgentPlugins([], external=[qwen], off=()).sessions()
check("Qwen：开着的会话、等确认（最后一个工具调用还没结果）、工具名换成手机认得的", len(qsnap) == 1 and qsnap[0]["sessionId"] == "q-1"
      and qsnap[0]["activity"] == "waiting" and qsnap[0]["pendingTool"] == "Bash" and qsnap[0]["agent"] == "qwen-code", str(qsnap)[:300])
check("Qwen：不在 tmux 里只读、说明原因；在 tmux 里给确认按钮（两者只会有一个）",
      (qsnap[0]["readOnly"] and "tmux" in (qsnap[0].get("readOnlyReason") or "") and "pendingOptions" not in qsnap[0])
      or (not qsnap[0]["readOnly"] and qsnap[0].get("readOnlyReason") is None and len(qsnap[0].get("pendingOptions") or []) == 3), str(qsnap)[:400])
qitems = [i for line, entry in enumerate(open(os.path.join(QCHATS, "q-1.jsonl"))) for i in qwen.normalize(line, json.loads(entry))]
check("Qwen：对话记录规整成统一格式（user / thinking / text / tool）", [(i["t"], i.get("name")) for i in qitems]
      == [("user", None), ("thinking", None), ("text", None), ("tool", "Bash")] and qitems[-1]["input"].get("command") == "npm test", str(qitems)[:300])
del os.environ["QWEN_HOME"]

print("\n== Cursor 插件（plugins/cursor：hooks 记录 + 配套扩展 + tmux；单独下发）")
CHOME = os.path.join(ROOT, "cursor-home")
CSTATE = os.path.join(os.environ["CCPULSE_DATA_DIR"], "cursor")
CHOOK = os.path.join(os.path.dirname(WATCHER), "..", "plugins", "cursor", "assets", "hook.py")
CTRANS = os.path.join(CHOME, ".cursor", "projects", "p-proj", "agent-transcripts", "cur-1", "cur-1.jsonl")
os.makedirs(os.path.join(CHOME, ".cursor", "extensions"))
with open(os.path.join(CHOME, ".cursor", "hooks.json"), "w") as handle:   # 用户自己的 hook：插件只加自己的，不动这些
    json.dump({"version": 1, "hooks": {"afterFileEdit": [{"command": "./format.sh"}], "stop": [{"command": "./audit.sh"}]}}, handle)
with open(os.path.join(CHOME, ".cursor", "extensions", "extensions.json"), "w") as handle:
    json.dump([{"identifier": {"id": "someone.else"}, "version": "1.0.0"}], handle)


def chook(event, cid="cur-1", **fields):
    """像 Cursor 那样调起 hook.py：JSON 从标准输入进，回的 JSON 从标准输出出"""
    data = dict(fields, hook_event_name=event, conversation_id=cid, workspace_roots=["/p/proj"], cursor_version="3.27.22")
    out = subprocess.run([sys.executable, CHOOK, CSTATE], input=json.dumps(data).encode(), capture_output=True, timeout=20,
                         env=dict(os.environ, HOME=CHOME))
    return json.loads(out.stdout.decode() or "null")


def ctranscript(*entries):
    os.makedirs(os.path.dirname(CTRANS), exist_ok=True)
    with open(CTRANS, "a") as handle:
        for entry in entries:
            handle.write(json.dumps(entry, ensure_ascii=False) + "\n")


def assistant(*parts):
    return {"role": "assistant", "message": {"content": list(parts)}}


chook("sessionStart", composer_mode="agent")
check("hook：beforeSubmitPrompt 回 continue（不拦）", chook("beforeSubmitPrompt", prompt="改一下 notes.md") == {"continue": True})
chook("afterAgentThought", text="先看看")
chook("afterAgentThought", text="先看看")   # Cursor 同一段思考报两次
check("hook：要表态的一律回 allow（Cursor 只认 deny / ask，allow 不改变用户的审批设置）",
      chook("preToolUse", tool_name="Shell", tool_use_id="t1", tool_input={"command": "ls", "cwd": ""}) == {"permission": "allow"})
ctranscript({"role": "user", "message": {"content": [{"type": "text", "text": "<timestamp>Sunday</timestamp>\n<user_query>\n改一下 notes.md\n</user_query>"}]}},
            assistant({"type": "text", "text": "我先列一下文件"}, {"type": "tool_use", "name": "Shell", "input": {"command": "ls", "description": "列文件"}}))
chook("postToolUse", tool_name="Shell", tool_use_id="t1", tool_output=json.dumps({"output": "a.txt\n", "exitCode": 0}),
      transcript_path=CTRANS)
chook("preToolUse", tool_name="Write", tool_use_id="t2", tool_input={"file_path": "/p/proj/notes.md", "content": "beta\n"})
ctranscript(assistant({"type": "tool_use", "name": "StrReplace", "input": {"path": "/p/proj/notes.md", "old_string": "alpha", "new_string": "beta"}},
                      {"type": "tool_use", "name": "CallDynamicTool", "input": {"namespace": "cursor", "toolName": "TodoWrite", "arguments": {
                          "merge": False, "todos": [{"id": "1", "content": "改文件", "status": "in_progress"}]}}}))
chook("postToolUse", tool_name="Write", tool_use_id="t2", tool_output=json.dumps({"file_path": "/p/proj/notes.md", "success": True}))
ctranscript(assistant({"type": "tool_use", "name": "CallDynamicTool", "input": {"namespace": "cursor", "toolName": "TodoWrite",
                                                                               "arguments": {"merge": True, "todos": [{"id": "1", "status": "completed"}]}}}),
            assistant({"type": "text", "text": "改好了"}), {"type": "turn_ended", "status": "success"})
os.makedirs(os.path.join(CSTATE, "queue"), exist_ok=True)
with open(os.path.join(CSTATE, "queue", "cur-1.json"), "w") as handle:
    json.dump([{"text": "再跑一下测试", "ts": 1}], handle)
chook("afterAgentResponse", text="我先列一下文件改好了")
stopped = chook("stop", status="completed", loop_count=0)
check("hook：这一轮结束时把手机排队的消息作为 followup_message 交给 Cursor，并清掉队列",
      stopped == {"followup_message": "再跑一下测试"} and not os.path.exists(os.path.join(CSTATE, "queue", "cur-1.json")), stopped)

W.HOME = CHOME   # 插件按中台的 HOME 找 ~/.cursor（create 时取）
cursor = next(p for p in W.load_external_plugins(os.path.join(os.path.dirname(WATCHER), "..", "plugins"))[0] if p.id == "cursor")
W.HOME = os.path.expanduser("~")
cevents = os.path.join(CSTATE, "events", "cur-1.jsonl")
citems = [i for offset, entry in ((o, json.loads(l)) for o, l in enumerate(open(cevents))) for i in cursor.normalize(offset, entry)]
check("Cursor：记录规整成统一格式——对话记录里的文字、工具和 hook 报的结果按 id 配上，思考不重复",
      [(i["t"], i.get("name")) for i in citems] == [("user", None), ("thinking", None), ("text", None), ("tool", "Bash"), ("result", None),
                                                   ("tool", "Edit"), ("tool", "TodoWrite"), ("result", None), ("tool", "TodoWrite"), ("text", None)],
      [(i["t"], i.get("name")) for i in citems])
check("Cursor：工具结果跟着 id 走（Bash 的输出、改文件的结果）",
      citems[3]["toolId"] == citems[4]["toolId"] == "t1" and citems[4]["text"] == "a.txt\n" and citems[5]["toolId"] == citems[7]["toolId"] == "t2",
      citems[3:8])
check("Cursor：改文件用对话记录里的 StrReplace（手机画得出改动对比），待办合成完整清单",
      citems[5]["input"].get("file_path") == "/p/proj/notes.md" and citems[5]["input"].get("old_string") == "alpha"
      and citems[8]["input"]["todos"] == [{"content": "改文件", "status": "completed"}], (citems[5], citems[8]))
check("Cursor：用户的话不带 Cursor 加的 <timestamp> / <user_query>，只出现一次",
      [i["text"] for i in citems if i["t"] == "user"] == ["改一下 notes.md"], [i for i in citems if i["t"] == "user"])

cursor.start()
chooks = json.load(open(os.path.join(CHOME, ".cursor", "hooks.json")))["hooks"]
ours = [e for entries in chooks.values() for e in entries if "kiteline" in e.get("command", "")]
check("Cursor：hooks.json 里加上自己的几条，用户原来的原样保留",
      {"command": "./format.sh"} in chooks["afterFileEdit"] and {"command": "./audit.sh"} in chooks["stop"]
      and len(ours) == 9 and all(CSTATE in e["command"] for e in ours), chooks)
check("Cursor：stop 的 followup 不限次数（loop_limit 为空），hook 文件装好了",
      [e for e in chooks["stop"] if "kiteline" in e["command"]][0].get("loop_limit", "x") is None
      and os.path.isfile(os.path.join(CHOME, ".cursor", "hooks", "kiteline", "hook.py")), chooks["stop"])
CEXT_VERSION = json.load(open(os.path.join(os.path.dirname(CHOOK), "cursor-link", "package.json")))["version"]
cext = os.path.join(CHOME, ".cursor", "extensions", "kiteline.kiteline-cursor-link-" + CEXT_VERSION)
cregistry = json.load(open(os.path.join(CHOME, ".cursor", "extensions", "extensions.json")))
check("Cursor：配套扩展装进扩展目录、登记进 extensions.json（别人的保留），信箱目录写好",
      os.path.isfile(os.path.join(cext, "extension.js")) and json.load(open(os.path.join(cext, "kiteline.json")))["dir"] == os.path.join(CSTATE, "ide")
      and [e["identifier"]["id"] for e in cregistry] == ["someone.else", "kiteline.kiteline-cursor-link"], cregistry)
before = open(os.path.join(CHOME, ".cursor", "hooks.json")).read()
cursor.installed = 0
cursor.ensure()
check("Cursor：再装一遍不重复加", open(os.path.join(CHOME, ".cursor", "hooks.json")).read() == before)

csnaps = {s["sessionId"]: s for s in W.AgentPlugins([], external=[cursor], off=()).sessions()}
cs = csnaps.get("cur-1") or {}
check("Cursor：列出编辑器里的对话（空闲、标题取第一句、最后一句回复、记录文件）",
      cs.get("activity") == "idle" and cs.get("title") == "改一下 notes.md" and cs.get("message") == "改好了"
      and cs.get("transcriptPath") == cevents and cs.get("entrypoint") == "cursor-ide" and cs.get("agent") == "cursor", cs)
check("Cursor：编辑器扩展还没生效（装好后没重启过 Cursor）→ 只读，提示重启 Cursor",
      cs.get("readOnly") and "重启" in (cs.get("readOnlyReason") or "") and cs.get("readOnlyReasonEn"), cs)
try:
    cursor.send("cur-1", "hi", [])
    refused = ""
except RuntimeError as exc:
    refused = str(exc)
check("Cursor：这时从手机发消息 → 同样说明要重启 Cursor", "重启" in refused, refused)

os.makedirs(os.path.join(CSTATE, "ide"), exist_ok=True)


def cbeat(opened, folders=("/p/proj",)):
    """扮演编辑器窗口里扩展的心跳：开着哪些对话、打开了哪些项目"""
    with open(os.path.join(CSTATE, "ide", "win-4242.json"), "w") as handle:
        json.dump({"pid": 4242, "ts": int(time.time() * 1000), "open": list(opened), "folders": list(folders)}, handle)


def csnap(sid="cur-1"):
    cursor.log.scanned = 0
    return {s["sessionId"]: s for s in W.AgentPlugins([], external=[cursor], off=()).sessions()}.get(sid) or {}


APP = os.path.join(CHOME, "Library", "Application Support", "Cursor") if sys.platform == "darwin" else os.path.join(ROOT, "xdg-config", "Cursor")
CLOG = os.path.join(APP, "logs", "20261101T000000", "window1", "exthost", "anysphere.cursor-agent-host", "Cursor Agent Host.log")
os.makedirs(os.path.dirname(CLOG))


def clog(message, **data):
    now = time.time()
    with open(CLOG, "a") as handle:
        handle.write("%s.%03d [info] %s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now)), int(now % 1 * 1000), message,
                                                  json.dumps(dict(data, module_version="x"))))


seen_reqs, ext_stop = [], []


def fake_extension():
    """扮演 Cursor 里的 Kiteline 扩展：收请求、回执；「允许」后像 Cursor 那样在 Agent Host 日志里记一行放行"""
    box = os.path.join(CSTATE, "ide")
    while not ext_stop:
        for name in os.listdir(box):
            if name.startswith("req-") and name.endswith(".json") and name not in [r["_name"] for r in seen_reqs]:
                try:
                    req = dict(json.load(open(os.path.join(box, name))), _name=name)
                except (OSError, ValueError):
                    continue
                seen_reqs.append(req)
                if req["cmd"] == "approve":
                    clog("Shell stream: approval gate allowed command", toolCallId="call-9")
                with open(os.path.join(box, "ack.tmp"), "w") as handle:   # 同真扩展：先写临时文件再改名
                    json.dump({"ok": True, "pid": 4242}, handle)
                os.replace(os.path.join(box, "ack.tmp"), os.path.join(box, "ack-%s-4242.json" % req["id"]))
        time.sleep(0.05)


threading.Thread(target=fake_extension, daemon=True).start()
cbeat([])   # 编辑器窗口打开了这个项目，但还没开这个对话（比如它在 Agents 窗口里）
cs = csnap()
check("Cursor：项目在编辑器窗口里开着 → 空闲时也能从手机发消息（电脑端会按回车）", not cs.get("readOnly"), cs)
hub_cursor = W.AgentPlugins([], external=[cursor], off=())
hub_cursor.sessions()
before_reqs = len(seen_reqs)
sent = hub_cursor.handle("cursor", {"cmd": "agent_send", "sessionId": "cur-1", "text": "再跑一遍测试", "ui": ["keys"]})
check("Cursor：空闲时发消息 → 回动作单（切到 Cursor 里这个项目的窗口 → 请插件填字 → 按回车），这时还不碰 Cursor",
      sent.get("ui") == [{"do": "focus", "app": "cursor", "folder": "/p/proj"}, {"do": "plugin", "step": "fill"},
                         {"do": "key", "name": "enter"}] and len(seen_reqs) == before_reqs, (sent, seen_reqs[before_reqs:]))
filled = hub_cursor.handle("cursor", {"cmd": "agent_ui", "sessionId": "cur-1", "step": "fill"})
check("Cursor：电脑端切好窗口后回头请插件填字 → 扩展在那个窗口里打开对话、填进去",
      filled == {"message": "已填入"} and seen_reqs[-1]["cmd"] == "send" and seen_reqs[-1]["text"] == "再跑一遍测试"
      and seen_reqs[-1]["pids"] == [4242], (filled, seen_reqs[-1:]))
try:
    hub_cursor.handle("cursor", {"cmd": "agent_ui", "sessionId": "cur-1", "step": "fill"})
    refused = ""
except RuntimeError as exc:
    refused = str(exc)
check("Cursor：同一份内容不会填第二次", "过期" in refused, refused)
real_emit = W.emit
W.emit = lambda event: None
cwatch = W.Watcher(plugins=hub_cursor)
cwatch.track(hub_cursor.sessions())
plan = cwatch.handle({"cmd": "agent_send", "sessionId": "cur-1", "text": "经 watcher 发", "ui": ["keys"]})
step = cwatch.handle({"cmd": "agent_ui", "sessionId": "cur-1", "step": "fill"})
W.emit = real_emit
check("Cursor：经 watcher 的请求分派同样走得通（agent_send 回动作单、agent_ui 填字）",
      [a["do"] for a in plan.get("ui") or []] == ["focus", "plugin", "key"] and step == {"message": "已填入"}
      and seen_reqs[-1]["text"] == "经 watcher 发", (plan, step))
try:
    hub_cursor.handle("cursor", {"cmd": "agent_send", "sessionId": "cur-1", "text": "旧电脑端"})
    refused = ""
except RuntimeError as exc:
    refused = str(exc)
check("Cursor：电脑端不会按键（旧版本）→ 提示更新 Kiteline，不往 Cursor 里填字", "更新" in refused and seen_reqs[-1]["text"] != "旧电脑端", refused)
cbeat([], folders=("/somewhere/else",))
cs = csnap()
check("Cursor：项目没在任何编辑器窗口里开着（如只用 Agents 窗口）→ 只读，提示点「IDE」切到编辑器窗口",
      cs.get("readOnly") and "IDE" in (cs.get("readOnlyReason") or "") and "IDE" in (cs.get("readOnlyReasonEn") or ""), cs)

# 新一轮：等确认（编辑器的 Agent Host 日志里「prompting」）
chook("beforeSubmitPrompt", prompt="清理一下")
chook("preToolUse", tool_name="Shell", tool_use_id="t3", tool_input={"command": "rm -rf build"})
time.sleep(0.05)
clog("Smart Mode shell preflight state", toolCallId="call-9", conversationId="cur-1", toolName="SHELL")
clog("Shell stream: approval gate reached", toolCallId="call-9", skipApproval=False)
clog("Shell permissions: prompting for empty allowlist", toolCallId="call-9", approvalMode="allowlist")
cs = csnap()
check("Cursor：编辑器在等确认（看它的 Agent Host 日志），工具是 Bash", cs.get("activity") == "waiting" and cs.get("pendingTool") == "Bash"
      and "rm -rf build" in (cs.get("reason") or "") and "rm -rf build" in (cs.get("waitingFor") or ""), cs)
check("Cursor：这一轮不在装了扩展的编辑器窗口里（Agents 窗口）→ 不给按钮，说明去电脑上确认、以后切到编辑器窗口",
      cs.get("readOnly") and "Agents" in (cs.get("readOnlyReason") or "") and not cs.get("pendingOptions"), cs)
cbeat(["cur-1"])
cs = csnap()
check("Cursor：编辑器窗口里开着 → 允许 / 拒绝两个按钮（带英文）",
      not cs.get("readOnly") and [o["key"] for o in cs.get("pendingOptions") or []] == ["esc", "1"]
      and all(o.get("labelEn") for o in cs["pendingOptions"]), cs)
check("Cursor：按 1 → 让开着这个对话的窗口执行「允许」，并核对 Cursor 真的放行了", cursor.key("cur-1", "1") == "已允许"
      and seen_reqs[-1]["cmd"] == "approve" and seen_reqs[-1]["composerId"] == "cur-1" and seen_reqs[-1]["pids"] == [4242], seen_reqs[-1:])
check("Cursor：等确认时按 Esc → 拒绝", cursor.key("cur-1", "esc") == "已拒绝" and seen_reqs[-1]["cmd"] == "reject", seen_reqs[-1:])
check("Cursor：忙时发消息 → 排队，这一轮结束后自动发出", "结束后自动发出" in cursor.send("cur-1", "顺便看下日志", [])
      and json.load(open(os.path.join(CSTATE, "queue", "cur-1.json")))[0]["text"] == "顺便看下日志")
chook("postToolUse", tool_name="Shell", tool_use_id="t3", tool_output=json.dumps({"output": ""}))
cbeat(["cur-1"])
cs = csnap()
check("Cursor：放行 / 拒绝之后 hook 又来了 → 不再算等确认（还在忙）", cs.get("activity") == "busy", cs)
check("Cursor：忙着（不在等确认）时按 Esc → 中断", cursor.key("cur-1", "esc") == "已中断" and seen_reqs[-1]["cmd"] == "cancel", seen_reqs[-1:])
check("Cursor：stop 时把排队的消息交出去", chook("stop", status="aborted") == {"followup_message": "顺便看下日志"})
citems = [i for offset, line in enumerate(open(cevents)) for i in cursor.normalize(offset, json.loads(line))]
check("Cursor：被中断的一轮记一行「已中断」", citems[-1]["t"] == "event" and citems[-1]["text"] == "已中断", citems[-2:])
ext_stop.append(True)

# 远程工作区（Remote-SSH）里的对话：hook 带 CURSOR_CODE_REMOTE=true
os.environ["CURSOR_CODE_REMOTE"] = "true"
chook("sessionStart", cid="cur-remote")
chook("beforeSubmitPrompt", cid="cur-remote", prompt="远程项目里改个文件")
chook("stop", cid="cur-remote", status="completed")
del os.environ["CURSOR_CODE_REMOTE"]
cs = csnap("cur-remote")
check("Cursor：Remote-SSH 里的对话 → 只读，说明无法从手机编辑", cs.get("readOnly") and "无法从手机编辑" in (cs.get("readOnlyReason") or "")
      and cs.get("readOnlyReasonEn"), cs)
chook("sessionEnd", reason="user_close")
check("Cursor：会话关了就不再列出", "cur-1" not in {s["sessionId"] for s in W.AgentPlugins([], external=[cursor], off=()).sessions()})

cursor.disable()
chooks = json.load(open(os.path.join(CHOME, ".cursor", "hooks.json")))["hooks"]
check("Cursor：关掉插件 → 只删自己的 hook，用户的留着", chooks == {"afterFileEdit": [{"command": "./format.sh"}], "stop": [{"command": "./audit.sh"}]}
      and not os.path.exists(os.path.join(CHOME, ".cursor", "hooks", "kiteline")), chooks)
check("Cursor：关掉插件 → 扩展删掉、登记去掉（别人的留着）", not os.path.exists(cext)
      and [e["identifier"]["id"] for e in json.load(open(os.path.join(CHOME, ".cursor", "extensions", "extensions.json")))] == ["someone.else"])
check("Cursor 插件只在 tmux 里的命令行会话给 close", not cursor.closable({"tmuxPane": None}) and cursor.closable({"tmuxPane": "%1"}))

print("\n== 关闭会话（插件实现了 close 才给 caps close，见 docs/agent-plugins.md 4.4）")


class CloserDemo(W.AgentPlugin):
    id, name = "closer-demo", "Closer"

    def sessions(self):
        return [{"sessionId": "c-1", "agent": "closer-demo", "activity": "idle"},
                {"sessionId": "c-2", "agent": "closer-demo", "activity": "idle", "readOnly": True}]

    def close(self, sid):
        return "已关闭 %s" % sid


class PlainDemo(W.AgentPlugin):
    id, name = "plain-demo", "Plain"

    def sessions(self):
        return [{"sessionId": "p-1", "agent": "plain-demo", "activity": "idle"}]


hub = W.AgentPlugins([CloserDemo(), PlainDemo()], external=[], off=())
csnaps = {s["sessionId"]: s for s in hub.sessions()}
check("实现了 close 的插件：会话 caps 带 close", "close" in (csnaps.get("c-1") or {}).get("caps", []), csnaps.get("c-1"))
check("只读的会话不给 close", "close" not in (csnaps.get("c-2") or {}).get("caps", ["close"]), csnaps.get("c-2"))
check("没实现 close 的插件：不给", "close" not in (csnaps.get("p-1") or {}).get("caps", ["close"]), csnaps.get("p-1"))
check("agent_close 交给插件的 close", hub.handle("closer-demo", {"cmd": "agent_close", "sessionId": "c-1"}) == {"message": "已关闭 c-1"})
try:
    hub.handle("plain-demo", {"cmd": "agent_close", "sessionId": "p-1"})
    refused = ""
except RuntimeError as exc:
    refused = str(exc)
check("没实现 close 的插件：关闭时报不支持", "不支持远程关闭" in refused, refused)
check("Qwen 插件实现了 close（tmux 里发 /quit）", type(qwen).close is not W.AgentPlugin.close)

shutil.rmtree(ROOT, ignore_errors=True)
if os.path.exists("/tmp/kl-agents-%d.sock" % os.getpid()):
    os.remove("/tmp/kl-agents-%d.sock" % os.getpid())
print("\nagents：%d 项通过，%d 项失败" % (PASS[0], len(FAIL)))
sys.exit(1 if FAIL else 0)
