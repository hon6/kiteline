"""电脑端 Agent 插件的真进程测试：起一份真的 Kiteline 后台（隔离的配置、数据目录，dry-run）和它的 watcher，
从签名的测试索引装插件，再发一个一跑就出错的新版本，看整条链路：watcher 连续出错停用（plugin_retired）→ 后台退回上一版本、
记下坏版本 → watcher 重启后旧版本的会话回来；出错推给客户端（plugin_error）、报告内容对；坏版本以后不再给装。
不碰真实的 ~/.ccpulse、配置目录：python desktop/tests/test_plugins_live.py"""
import base64
import hashlib
import http.server
import io
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import zipfile

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

HERE = os.path.dirname(os.path.abspath(__file__))
DESKTOP = os.path.dirname(HERE)
ROOT = tempfile.mkdtemp(prefix="kiteline-plugins-live-")
SITE = os.path.join(ROOT, "site", "plugins")
os.makedirs(SITE)
KEY = Ed25519PrivateKey.generate()
FAILED = []


def check(name, ok, detail=""):
    print("  [%s] %s %s" % ("PASS" if ok else "FAIL", name, "" if ok else str(detail)[:400]), flush=True)
    if not ok:
        FAILED.append(name)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


GOOD = '''
import time
def create(kl):
    class P(kl.AgentPlugin):
        read_only = "测试插件"
        def sessions(self):
            now = int(time.time() * 1000)
            return [{"pid": None, "sessionId": "live-1", "name": "插件真进程测试", "title": "插件真进程测试", "cwd": "/tmp",
                     "cwdShort": "/tmp", "status": "idle", "waitingFor": None, "needs": None, "detail": None, "activity": "idle",
                     "reason": "VERSION", "activityText": None, "message": "VERSION", "messageUuid": None, "error": None,
                     "effort": None, "subagents": 0, "pendingTool": None, "pendingId": None, "startedAt": now - 60000,
                     "statusUpdatedAt": None, "updatedAt": now, "version": None, "entrypoint": "livetest", "sessionKind": None,
                     "tmuxPane": None, "usage": None, "transcriptPath": None, "transcriptUpdatedAt": None, "agent": "livetest",
                     "readOnly": True}]
    return P()
'''
BAD = '''
def create(kl):
    class P(kl.AgentPlugin):
        def sessions(self):
            raise ValueError("协议变了（测试用的坏版本）")
    return P()
'''


def package(version, code):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("plugin.json", json.dumps({"id": "livetest", "name": "真进程测试", "version": version, "needs": ["fs.read"]}))
        archive.writestr("plugin.py", code.replace("VERSION", version))
    data = buffer.getvalue()
    name = "livetest-%s.zip" % version
    with open(os.path.join(SITE, name), "wb") as handle:
        handle.write(data)
    return {"version": version, "url": name, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data), "needs": ["fs.read"]}


def publish(versions):
    index = {"format": 1, "plugins": [{"id": "livetest", "name": "真进程测试", "detect": {"paths": ["/"]}, "versions": versions}]}
    data = json.dumps(index, ensure_ascii=False).encode()
    with open(os.path.join(SITE, "index.json"), "wb") as handle:
        handle.write(data)
    with open(os.path.join(SITE, "index.json.sig"), "w") as handle:
        handle.write(base64.b64encode(KEY.sign(data)).decode())


class Quiet(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=os.path.join(ROOT, "site"), **kwargs)

    def log_message(self, *args):
        pass


site = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Quiet)
threading.Thread(target=site.serve_forever, daemon=True).start()
PORT = free_port()
TOKEN = "live-%d" % os.getpid()
config_dir = os.path.join(ROOT, "config")
data_dir = os.path.join(ROOT, "data")
os.makedirs(config_dir)
watcher = os.path.join(DESKTOP, "..", "watcher", "kiteline-watch.py")
with open(os.path.join(config_dir, "config.json"), "w") as handle:
    json.dump({"sources": [{"id": "local", "name": "本机", "kind": "local", "remoteWatcherPath": watcher}],
               "mobile": {"enabled": True, "port": PORT, "bindAddress": "127.0.0.1", "token": TOKEN, "installAgentSkill": False,
                          "remoteEnabled": False, "installOpenCodePlugin": False, "httpsEnabled": False}}, handle)
env = dict(os.environ, KITELINE_CONFIG_DIR=config_dir, CCPULSE_DATA_DIR=data_dir, CCPULSE_SESSIONS_DIR=os.path.join(ROOT, "sessions"),
           CCPULSE_DRY_RUN="1", CCPULSE_OPENCODE_PLUGIN="0", CCPULSE_PROMA_DIR=os.path.join(ROOT, "proma"),
           CCPULSE_PLUGIN_INDEX="http://127.0.0.1:%d/plugins/index.json" % site.server_address[1],
           CCPULSE_PLUGIN_PUBKEY=base64.b64encode(KEY.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).decode())
app = subprocess.Popen([sys.executable, "-m", "kiteline", "--headless", "--no-tray"], cwd=DESKTOP, env=env,
                       stdout=open(os.path.join(ROOT, "app.out"), "w"), stderr=subprocess.STDOUT)


def api(path, body=None, timeout=40):
    request = urllib.request.Request("http://127.0.0.1:%d%s" % (PORT, path), data=None if body is None else json.dumps(body).encode(),
                                     headers={"x-ccp-token": TOKEN, "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def until(fn, timeout=40):
    end = time.time() + timeout
    while time.time() < end:
        try:
            got = fn()
            if got:
                return got
        except Exception:  # noqa: BLE001
            pass
        time.sleep(0.5)
    return None


def session():
    return next((s for s in api("/api/state").get("sessions") or [] if s.get("agent") == "livetest"), None)


def row():
    return next((r for r in api("/api/desktop/plugins")["plugins"] if r["id"] == "livetest"), None)


events = []


def listen():
    """像客户端那样听事件流：plugin_error 要推过来"""
    try:
        request = urllib.request.Request("http://127.0.0.1:%d/api/events" % PORT, headers={"x-ccp-token": TOKEN})
        with urllib.request.urlopen(request, timeout=300) as response:
            kind = None
            for raw in response:
                line = raw.decode("utf-8").rstrip("\n")
                if line.startswith("event: "):
                    kind = line[7:]
                elif line.startswith("data: ") and kind == "plugin_error":
                    events.append(json.loads(line[6:]))
    except Exception:  # noqa: BLE001
        pass


try:
    print("== 起后台")
    check("Kiteline 后台和 watcher 起来了", until(lambda: any(s.get("online") for s in api("/api/state").get("sources") or []), 60))
    threading.Thread(target=listen, daemon=True).start()

    print("== 装能用的 1.0.0")
    publish([package("1.0.0", GOOD)])
    api("/api/desktop/plugins/check", {})
    result = api("/api/desktop/plugins/install", {"id": "livetest"})
    check("从签名索引装上 1.0.0", result.get("ok") and result.get("version") == "1.0.0", result)
    first = until(session, 40)
    check("watcher 重启后载入插件，会话出现", first and first.get("reason") == "1.0.0", first)

    print("== 发一个一跑就出错的 2.0.0")
    publish([package("1.0.0", GOOD), package("2.0.0", BAD)])
    state = api("/api/desktop/plugins/check", {})
    check("查到新版本 2.0.0", next(r for r in state["plugins"] if r["id"] == "livetest")["action"] == "update")
    result = api("/api/desktop/plugins/install", {"id": "livetest"})
    check("装上 2.0.0", result.get("ok") and result.get("version") == "2.0.0", result)
    retired = until(lambda: (row() or {}).get("version") == "1.0.0" and "livetest@2.0.0" in json.load(open(os.path.join(config_dir, "plugins.json")))["bad"], 60)
    check("连续出错 → watcher 停用 → 后台退回 1.0.0、记下坏版本", retired, row())
    back = until(lambda: (session() or {}).get("reason") == "1.0.0", 40)
    check("退回后旧版本的会话回来", back, session())
    state = api("/api/desktop/plugins")
    errors = [e for e in state["errors"] if e["id"] == "livetest"]
    check("出错记下来（设置页「报告问题」用）", errors and errors[0]["version"] == "2.0.0" and "协议变了" in errors[0]["error"], state["errors"])
    check("出错推给客户端（弹窗问要不要报告）", until(lambda: [e for e in events if e.get("id") == "livetest"], 10), events)
    report = api("/api/desktop/plugins/report", {"key": errors[0]["key"]}) if errors else {}
    check("报告：发到 hon6@foxmail.com，带版本和出错位置", (report.get("url") or "").startswith("mailto:hon6@foxmail.com")
          and "2.0.0" in report.get("body", "") and "sessions" in report.get("body", ""), report)
    state = api("/api/desktop/plugins/check", {})
    again = next(r for r in state["plugins"] if r["id"] == "livetest")
    check("坏版本以后不再给装（没有可更新的版本）", again["action"] is None and again["version"] == "1.0.0", again)
finally:
    app.terminate()
    try:
        app.wait(10)
    except subprocess.TimeoutExpired:
        app.kill()
    site.shutdown()
    if FAILED:
        print(open(os.path.join(ROOT, "app.out"), encoding="utf-8", errors="replace").read()[-3000:])
    shutil.rmtree(ROOT, ignore_errors=True)

print("\nplugins-live：%s" % ("全部通过" if not FAILED else "%d 项失败" % len(FAILED)))
sys.exit(1 if FAILED else 0)
