"""电脑端（Windows / Linux 共用的主机）里会话浏览器和重启会话的逻辑：python desktop/tests/test_browser_host.py
覆盖：设置带给 watcher 的环境变量、连远端的反向转发、远端会话的小窗信息合并、画面事件按会话 id 找 key、
/api/browser 分流（远端会话找本机 watcher、指令列表找远端、接管两边都发）、重启会话（空闲马上、忙的排队、关了接着打开）"""
import json
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
os.environ["KITELINE_CONFIG_DIR"] = tempfile.mkdtemp(prefix="kiteline-unit-")

from kiteline import restart, server, store, watcher  # noqa: E402
from kiteline.httpd import Request  # noqa: E402

FAILED = 0


def check(name, ok, detail=""):
    global FAILED
    print("  [%s] %s %s" % ("PASS" if ok else "FAIL", name, detail if not ok else ""))
    if not ok:
        FAILED += 1


print("== 设置带给 watcher")
watcher.BROWSER.update(on="client", max=3, idle=5, record=False)
env = watcher.watcher_env()
check("上限、回收时间、录制开关经环境变量带过去", env.get("CCPULSE_BROWSER_MAX") == "3" and env.get("CCPULSE_BROWSER_IDLE") == "5"
      and env.get("CCPULSE_BROWSER_REC") == "0", env)

print("== 连远端：浏览器开在这台电脑上时加反向转发")
ssh = ["ssh", "-o", "BatchMode=yes", "me@server"]
cmd, extra = watcher.browser_tunnel(ssh, {"sshHost": "me@server"})
port = int(extra.get("CCPULSE_BROWSER_TUNNEL") or 0)
check("ssh 带 -R 端口:127.0.0.1:9339，放在主机名前面", cmd[-1] == "me@server" and cmd[-3:-1] == ["-R", "%d:127.0.0.1:9339" % port], cmd)
check("远端带远端模式和通道端口（20000～49999，固定值）", extra.get("CCPULSE_BROWSER_REMOTE") == "1" and 20000 <= port < 50000
      and watcher.browser_tunnel(ssh, {"sshHost": "me@server"})[1] == extra, extra)
watcher.BROWSER["on"] = "server"
cmd2, extra2 = watcher.browser_tunnel(ssh, {"sshHost": "me@server"})
check("设成开在 agent 所在的电脑：不加转发", cmd2 == ssh and extra2 == {})
watcher.BROWSER.update(on="client", max=4, idle=10, record=True)


class FakeSource:
    def __init__(self, sid, kind):
        self.id, self.kind, self.live, self.calls = sid, kind, True, []

    def request(self, payload, timeout=10):
        self.calls.append(payload)
        if payload.get("op") == "actions":
            return {"actions": [{"t": 1, "text": "open https://example.com"}]}
        return {"tabs": [], "actions": [], "event": "response", "id": 1}


class FakeStore:
    def __init__(self, records, sources):
        self.records, self.sources, self.browser_states = records, sources, {}

    def record(self, key):
        return next((r for r in self.records if r.key == key), None)

    def source(self, sid):
        return self.sources.get(sid)

    def resolve_any(self, key):
        source_id, session_id = key.split("#", 1)
        return session_id, self.sources[source_id]


local, remote = FakeSource("local", "local"), FakeSource("ssh:vm", "ssh")
rec_remote = store.Record("ssh:vm", "虚拟机", "ssh", {"sessionId": "s-remote", "browser": {"remote": True, "last": "click @e3", "actions": 2}})
rec_local = store.Record("local", "本机", "local", {"sessionId": "s-local", "browser": {"url": "https://a.com", "title": "A", "since": 1}})
fake = FakeStore([rec_remote, rec_local], {"local": local, "ssh:vm": remote})

print("== 小窗信息")
check("本机会话用自己快照里的", store.Store.browser_payload(fake, rec_local).get("title") == "A")
check("远端会话：本机没开着它的浏览器就不出小窗", store.Store.browser_payload(fake, rec_remote) is None)
fake.browser_states = {"s-remote": {"url": "https://b.com", "title": "B", "since": 5}}
merged = store.Store.browser_payload(fake, rec_remote) or {}
check("远端会话：地址标题取本机的，指令取远端的", merged.get("url") == "https://b.com" and merged.get("last") == "click @e3", merged)
fake.browser_states = {"s-remote": {"closed": True, "recs": 1, "since": 5, "url": "", "title": ""}}
check("浏览器关了：带 closed / recs（小窗变成「回放」卡片）", (store.Store.browser_payload(fake, rec_remote) or {}).get("closed"))
check("画面事件按会话 id 找到远端会话的 key", store.Store.key_for_session(fake, "local", "s-remote") == "ssh:vm#s-remote")

print("== /api/browser 分流")


class FakeApp:
    def __init__(self):
        self.store = fake


class FakeServer:
    app = FakeApp()


def call(key, body):
    request = Request("POST", "/api/browser?key=" + key.replace("#", "%23"), {"Content-Type": "application/json"},
                      json.dumps(body).encode("utf-8"), "127.0.0.1")
    return server.r_browser(FakeServer(), request)


local.calls.clear(); remote.calls.clear()
reply = json.loads(call("ssh:vm#s-remote", {"op": "watch", "viewer": "v", "level": "thumb"}).body)
check("远端会话看画面：找本机 watcher，指令列表找远端", local.calls and local.calls[0]["op"] == "watch"
      and remote.calls and remote.calls[0]["op"] == "actions" and reply.get("actions"), (local.calls, remote.calls, reply))
local.calls.clear(); remote.calls.clear()
call("ssh:vm#s-remote", {"op": "control", "on": False, "text": "好了"})
check("接管 / 交还：两边都发（远端把留言交给在等的 agent）", local.calls and remote.calls and remote.calls[0]["op"] == "control")
local.calls.clear(); remote.calls.clear()
call("ssh:vm#s-remote", {"op": "input", "type": "click", "x": 0.5, "y": 0.5})
check("接管时的点击只发本机（浏览器在本机）", local.calls and not remote.calls)
watcher.BROWSER["on"] = "server"
local.calls.clear(); remote.calls.clear()
call("ssh:vm#s-remote", {"op": "watch", "viewer": "v"})
check("设成开在 agent 所在的电脑：全发给会话所在那台", remote.calls and not local.calls)
watcher.BROWSER["on"] = "client"

print("== 重启会话")
performed = []


class RestartApp:
    def __init__(self, records):
        self.store = FakeStore(records, {"local": local})


busy = store.Record("local", "本机", "local", {"sessionId": "busy", "activity": "busy"})
idle = store.Record("local", "本机", "local", {"sessionId": "idle", "activity": "idle"})
app = RestartApp([busy, idle])
r = restart.SessionRestart(app)
r._perform = lambda record: performed.append(record.key)
result = r.restart(["local#busy", "local#idle", "local#gone"])
time.sleep(0.3)
check("空闲的马上重启", result["restarted"] == ["local#idle"] and "local#idle" in performed, result)
check("正在工作的排队（不打断）", result["queued"] == ["local#busy"] and r.is_pending("local#busy"))
check("不存在的报原因", result["failed"] and result["failed"][0]["key"] == "local#gone")
busy.snap["activity"] = "idle"
deadline = time.time() + 8
while "local#busy" not in performed and time.time() < deadline:
    time.sleep(0.2)
check("这一轮做完（变空闲）后自动重启", "local#busy" in performed and not r.is_pending("local#busy"), performed)

print("== 重启：关掉、等结束、接着打开（原来在 VS Code 里的还在 VS Code）")
closed, resumed = [], []
recs = [store.Record("local", "本机", "local", {"sessionId": "x1", "activity": "idle", "name": "x"})]
app2 = RestartApp(recs)


class Outcome(dict):
    ok = True


def fake_close(record, source, siblings):
    closed.append(record.key)
    app2.store.records = []   # 会话结束了
    return Outcome(message="")


def fake_resume(request):
    resumed.append((request.query.get("key"), json.loads(request.body)))
    from kiteline.httpd import Response
    return Response.json({"ok": True})


restart.delivery.close, app2.resume = fake_close, fake_resume
app2.server = type("S", (), {"notify": lambda *a, **k: None})()
restart.SessionRestart(app2)._perform(recs[0])
check("先关闭、再用同一个会话 id 接着打开、不发消息", closed == ["local#x1"] and resumed and resumed[0][0] == "local#x1"
      and resumed[0][1] == {"text": "", "submit": False, "editor": True}, (closed, resumed))

print("\n%s" % ("全部通过" if not FAILED else "%d 项失败" % FAILED))
sys.exit(1 if FAILED else 0)
