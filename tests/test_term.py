"""会话里的终端（watcher/kiteline-watch.py 的 term 请求）：真开一个伪终端跑 shell，不碰真实的会话。

覆盖：开在会话目录、执行命令、中文、Ctrl+C、改大小、重新打开时接上画面、角标计数、按键走快速通道、关闭和自己退出

用法：python3 tests/test_term.py
"""
import base64
import importlib.util
import json
import os
import re
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("watcher", os.path.join(HERE, "..", "watcher", "kiteline-watch.py"))
W = importlib.util.module_from_spec(spec)
spec.loader.exec_module(W)

EVENTS = []
W.emit = EVENTS.append   # 终端的输出、结束、快速通道的应答都经 emit 出去
PASS, FAIL = [0], []


def check(name, cond, detail=""):
    if cond:
        PASS[0] += 1
        print("  [PASS] %s" % name)
    else:
        FAIL.append(name)
        print("  [FAIL] %s %s" % (name, detail))


def output(tid):
    """按 seq 拼出这个终端收到的全部输出"""
    chunks = sorted((e["seq"], base64.b64decode(e["data"])) for e in list(EVENTS) if e.get("event") == "term" and e["term"] == tid)
    data, end = b"", 0
    for seq, chunk in chunks:
        if seq >= end:
            data += chunk
            end = seq + len(chunk)
    return data.decode("utf-8", "replace")


def wait_for(predicate, timeout=10.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return False


def send(tid, text):
    W.TERMS.handle({"op": "input", "term": tid, "data": text}, None)


# Windows 上是 PowerShell（ConPTY），回车是 \r；其余是用户的 shell（pty）
WIN = W.IS_WINDOWS
NL = "\r" if WIN else "\n"
CMD = {
    "calc": 'echo "kl-$(40+2)"' if WIN else "echo kl-$((40+2))",
    "pwd": "(Get-Location).Path" if WIN else "pwd",
    "sleep": "Start-Sleep 30" if WIN else "sleep 30",
    "size": 'echo "$($Host.UI.RawUI.WindowSize.Height) $($Host.UI.RawUI.WindowSize.Width)"' if WIN else "stty size",
}


cwd = tempfile.mkdtemp(prefix="kl-term-工作区-")
print("== 开终端")
opened = W.TERMS.handle({"op": "open", "sessionId": "s-1", "cols": 100, "rows": 30}, cwd)["term"]
tid = opened["term"]
check("开在会话的工作目录，带 shell 名", opened["cwd"] == cwd and opened["shell"], str(opened))
send(tid, CMD["calc"] + NL)
check("执行命令、输出推回来", wait_for(lambda: "kl-42" in output(tid)), output(tid)[-300:])
send(tid, CMD["pwd"] + NL)
check("当前目录就是会话目录（中文路径）", wait_for(lambda: output(tid).count(cwd) >= 1), output(tid)[-300:])
send(tid, "echo 你好终端" + NL)
check("中文输入输出不乱码", wait_for(lambda: output(tid).count("你好终端") >= 2), output(tid)[-200:])

print("== 按键与大小")
if not WIN:
    # watcher 常是「忽略 Ctrl+C」地被拉起来的（后台启动、nohup）：自己也这样，看开出来的 shell 里 Ctrl+C 还管不管用
    import signal  # noqa: E402
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    W.TERMS.handle({"op": "close", "term": tid}, None)
    tid = W.TERMS.handle({"op": "open", "sessionId": "s-1", "cols": 100, "rows": 30}, cwd)["term"]["term"]
    time.sleep(0.5)
    if os.path.exists("/proc/self/status"):
        shell_pid = W.TERMS.get(tid).proc.pid
        ignored = int(re.search(r"SigIgn:\s*([0-9a-f]+)", open("/proc/%d/status" % shell_pid).read()).group(1), 16)
        check("watcher 忽略 Ctrl+C 时，开出来的 shell 不跟着忽略", not ignored & (1 << (signal.SIGINT - 1)), hex(ignored))
send(tid, CMD["sleep"] + NL)
time.sleep(0.4)
send(tid, "\x03")
started = time.time()
if WIN:
    time.sleep(1.0)   # Windows 控制台按 Ctrl+C 会清掉还没读的输入：等新的提示符出来再打（人也是这样）
send(tid, "echo after-ctrl-c" + NL)
check("Ctrl+C 能打断前台程序", wait_for(lambda: output(tid).count("after-ctrl-c") >= 2, 5) and time.time() - started < 5, output(tid)[-200:])
W.TERMS.handle({"op": "resize", "term": tid, "cols": 120, "rows": 40}, None)
send(tid, CMD["size"] + NL)
check("改大小后程序看到新的行列数", wait_for(lambda: "40 120" in output(tid)), output(tid)[-200:])

print("== 重新打开时接上画面")
read = W.TERMS.handle({"op": "read", "term": tid}, None)
tail = base64.b64decode(read["data"]).decode("utf-8", "replace")
check("read 给出最近的输出和起始位置", "40 120" in tail and read["seq"] + len(base64.b64decode(read["data"])) == read["term"]["end"], str(read["seq"]))
check("list 列出这个会话的终端", [t["term"] for t in W.TERMS.handle({"op": "list", "sessionId": "s-1"}, None)["terms"]] == [tid])
snaps = [{"sessionId": "s-1"}, {"sessionId": "s-2"}]
W.TERMS.annotate(snaps)
check("会话快照带终端个数（角标），没开的不带", snaps[0].get("terminals") == 1 and "terminals" not in snaps[1], str(snaps))

print("== 快速通道")
before = len(EVENTS)
handled = W.term_fast(json.dumps({"id": "r-1", "cmd": "term", "op": "input", "term": tid, "data": "echo fast-path" + NL}))
reply = [e for e in EVENTS[before:] if e.get("event") == "response" and e.get("id") == "r-1"]
check("按键不进主循环队列、直接应答", handled and reply and reply[0]["ok"], str(reply))
check("开终端照常排队（要查会话目录）", not W.term_fast(json.dumps({"id": "r-2", "cmd": "term", "op": "open", "sessionId": "s-1"})))
check("快速通道送进去的命令执行了", wait_for(lambda: output(tid).count("fast-path") >= 2), output(tid)[-200:])

print("== 关闭")
second = W.TERMS.handle({"op": "open", "sessionId": "s-1"}, cwd)["term"]["term"]
W.TERMS.handle({"op": "close", "term": tid}, None)
check("关闭：推 term_exit，列表里没了", wait_for(lambda: any(e.get("event") == "term_exit" and e["term"] == tid for e in EVENTS))
      and tid not in [t["term"] for t in W.TERMS.handle({"op": "list"}, None)["terms"]])
send(second, "exit" + NL)
check("shell 自己退出（输入 exit）：同样推 term_exit", wait_for(lambda: any(e.get("event") == "term_exit" and e["term"] == second for e in EVENTS)))
try:
    send(second, "echo late" + NL)
    late = "没报错"
except RuntimeError as exc:
    late = str(exc)
check("结束后再输入：说终端已关闭", late == "终端已关闭", late)
check("目录不存在时开在家目录", W.TERMS.handle({"op": "open", "sessionId": "s-3"}, "/no/such/dir")["term"]["cwd"] == W.HOME)
for t in W.TERMS.handle({"op": "list"}, None)["terms"]:
    W.TERMS.handle({"op": "close", "term": t["term"]}, None)

print("\n终端：%d 项通过，%d 项失败" % (PASS[0], len(FAIL)))
sys.exit(1 if FAIL else 0)
