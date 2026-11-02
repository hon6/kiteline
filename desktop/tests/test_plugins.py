"""电脑端的 Agent 插件（kiteline/plugins.py）：签名索引、下载校验安装、自动更新、退回、开关、出错报告、远端同步，
最后用真的 watcher 载入装好的插件。不起 Kiteline 服务、不碰真实的数据目录：python desktop/tests/test_plugins.py"""
import base64
import hashlib
import http.server
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
ROOT = tempfile.mkdtemp(prefix="kiteline-plugins-")
os.environ["KITELINE_CONFIG_DIR"] = os.path.join(ROOT, "config")
os.environ["CCPULSE_DATA_DIR"] = os.path.join(ROOT, "data")
os.makedirs(os.environ["KITELINE_CONFIG_DIR"])
SITE = os.path.join(ROOT, "site", "plugins")
os.makedirs(SITE)

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey  # noqa: E402
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat  # noqa: E402

KEY = Ed25519PrivateKey.generate()
os.environ["CCPULSE_PLUGIN_PUBKEY"] = base64.b64encode(KEY.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)).decode()


class Quiet(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=os.path.join(ROOT, "site"), **kwargs)

    def log_message(self, *args):
        pass


httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Quiet)
threading.Thread(target=httpd.serve_forever, daemon=True).start()
os.environ["CCPULSE_PLUGIN_INDEX"] = "http://127.0.0.1:%d/plugins/index.json" % httpd.server_address[1]

from kiteline import plugins, watcher  # noqa: E402

FAILED = 0


def check(name, ok, detail=""):
    global FAILED
    print("  [%s] %s %s" % ("PASS" if ok else "FAIL", name, detail if not ok else ""))
    if not ok:
        FAILED += 1


PLUGIN_CODE = {
    "newagent": '''
def create(kl):
    class P(kl.AgentPlugin):
        def sessions(self):
            return [{"sessionId": "n1", "agent": "newagent", "activity": "idle", "cwd": "/tmp", "name": "n1"}]
    return P()
''',
    "codex": "def create(kl):\n    return kl.CodexPlugin()\n",
    "future": "def create(kl):\n    return kl.AgentPlugin()\n",
}


def package(pid, version, extra=None):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("plugin.json", json.dumps({"id": pid, "name": pid, "version": version, "needs": ["fs.read"]}))
        archive.writestr("plugin.py", PLUGIN_CODE.get(pid, PLUGIN_CODE["future"]))
        for name, text in (extra or {}).items():
            archive.writestr(name, text)
    data = buffer.getvalue()
    name = "%s-%s.zip" % (pid, version)
    with open(os.path.join(SITE, name), "wb") as handle:
        handle.write(data)
    return {"version": version, "url": name, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data), "needs": ["fs.read"]}


AGENT_HOME = os.path.join(ROOT, "fake-agent-home")
os.makedirs(AGENT_HOME)
INDEX = {"format": 1, "plugins": [
    {"id": "newagent", "name": "新 Agent", "summary": "新接入的 agent", "detect": {"paths": [AGENT_HOME]},
     "versions": [package("newagent", "1.0.0")]},
    {"id": "codex", "name": "Codex", "versions": [package("codex", "1.0.1"), package("codex", "1.0.2")]},
    {"id": "future", "name": "Future", "detect": {"paths": [AGENT_HOME]},
     "versions": [dict(package("future", "2.0.0"), needs=["net.quic"], minApp={"desktop": "9.9.9"})]},
    {"id": "gone", "name": "Gone", "detect": {"paths": [AGENT_HOME]}, "versions": [dict(package("gone", "1.0.0"), revoked=True)]},
    {"id": "elsewhere", "name": "Elsewhere", "detect": {"paths": [os.path.join(ROOT, "nope")]}, "versions": [package("elsewhere", "1.0.0")]},
]}


def publish(index, sign=True):
    data = json.dumps(index, ensure_ascii=False).encode()
    with open(os.path.join(SITE, "index.json"), "wb") as handle:
        handle.write(data)
    signature = KEY.sign(data) if sign else Ed25519PrivateKey.generate().sign(data)
    with open(os.path.join(SITE, "index.json.sig"), "w") as handle:
        handle.write(base64.b64encode(signature).decode())


class FakeSource:
    id, name, live = "local", "本机", True

    def __init__(self):
        self.rows = [{"id": "codex", "name": "Codex", "version": "1.0.0", "source": "builtin", "status": "ok",
                      "abilities": ["view", "reply", "approve", "answer"], "detect": {"installed": True, "forms": {"cli": ""}}},
                     {"id": "proma", "name": "Proma", "version": "1.0.0", "source": "builtin", "status": "ok",
                      "abilities": ["view"], "detect": {"installed": False, "forms": {}}}]

    def request(self, payload, timeout=30):
        if payload.get("cmd") == "detect":
            return {"ok": True, "found": {pid: False for pid in payload["specs"]}}
        assert payload == {"cmd": "plugins"}
        return {"ok": True, "plugins": self.rows, "hostApi": 1, "hostCaps": ["fs.read", "fs.tail", "net.connect"]}


class RemoteSource(FakeSource):
    """Remote-SSH 远端：这台机器上装着「elsewhere」那家 agent"""
    id, name = "klu", "kl-ubuntu"

    def request(self, payload, timeout=30):
        if payload.get("cmd") == "detect":
            return {"ok": True, "found": {pid: pid == "elsewhere" for pid in payload["specs"]}}
        return super().request(payload, timeout)


class FakeServer:
    def __init__(self):
        self.events = []

    def publish(self, event, payload):
        self.events.append((event, payload))


class FakeUpdater:
    def __init__(self):
        self.calls = []

    def check(self):
        self.calls.append("check")
        return {"phase": "available"}

    def begin(self):
        self.calls.append("begin")
        return {"phase": "downloading"}


class FakeStore:
    def __init__(self):
        self.sources = {"local": FakeSource()}


class FakeApp:
    version = "1.0.6"

    def __init__(self):
        self.store = FakeStore()
        self.server = FakeServer()
        self.updater = FakeUpdater()
        self.reconnects = 0

    def reconnect_sources(self, source_id=None):
        self.reconnects += 1


print("== 签名")
data = b'{"plugins": []}'
good = base64.b64encode(KEY.sign(data)).decode()
check("自己签的对得上", plugins.verify(data, good))
check("内容改了一个字节就不认", not plugins.verify(data + b" ", good))
check("签名是乱码不认、不抛异常", not plugins.verify(data, "不是签名"))

print("== 索引")
app = FakeApp()
store = plugins.PluginStore(app)
publish(INDEX, sign=False)
store.check(auto=False)
check("别人签的索引整份不用，说清楚", store.error == "插件索引的签名不对，已忽略" and store.index.get("plugins") == [], store.error)
publish(INDEX)
state = store.check(auto=False)
rows = {r["id"]: r for r in state["plugins"]}
check("签名对的索引：读进来、缓存一份", not state["error"] and os.path.exists(store.index_path), state["error"])
check("内置插件有新版本 → 更新（挑本机能用的最新版）", rows["codex"]["action"] == "update" and rows["codex"]["target"]["version"] == "1.0.2")
check("新 agent 的插件、本机检测到了 → 安装", rows["newagent"]["action"] == "install" and rows["newagent"]["detected"])
check("要的能力本机没有 → 需要更新 Kiteline", rows["future"]["action"] == "needsApp" and rows["future"]["target"]["minApp"] == {"desktop": "9.9.9"})
check("吊销的版本不给装", rows["gone"]["action"] is None)
check("本机没装那家 agent：列出来但排在后面、不自动装", rows["elsewhere"]["action"] == "install" and not rows["elsewhere"]["detected"]
      and not rows["elsewhere"]["autoInstall"] and state["plugins"][-1]["id"] in ("elsewhere", "proma"))
check("索引里没有的内置插件也列出（版本、能力来自 watcher）", rows["proma"]["version"] == "1.0.0" and rows["proma"]["abilities"] == ["view"])

remote_app = FakeApp()
remote_app.store.sources["klu"] = RemoteSource()
remote_store = plugins.PluginStore(remote_app)
remote_store.index = json.loads(json.dumps(INDEX))
remote_store.refresh_local()
remote_rows = {r["id"]: r for r in remote_store.rows()}
check("只装在 Remote-SSH 远端的 agent：算检测到、记下在哪台、会自动装", remote_rows["elsewhere"]["detected"]
      and remote_rows["elsewhere"]["detectedOn"] == ["kl-ubuntu"] and remote_rows["elsewhere"]["autoInstall"], remote_rows["elsewhere"])
check("本机和远端都装着的：两台都记下（本机标成 local）", remote_rows["codex"]["detectedOn"] == ["local", "kl-ubuntu"], remote_rows["codex"]["detectedOn"])

print("== 安装")
result = store.install("newagent")
folder = os.path.join(plugins.plugins_dir(), "newagent")
check("下载、校验、解开到插件目录", result.get("ok") and plugins.read_manifest(folder)["version"] == "1.0.0"
      and os.path.isfile(os.path.join(folder, "plugin.py")), result)
check("装完重启 watcher", app.reconnects == 1)
same = store.install("newagent", restart=False)
check("已经是这个版本：不重复装（不会把同一个版本备份成「上一版本」）", same.get("unchanged") and not os.path.isdir(os.path.join(plugins.plugins_dir(), ".previous", "newagent")), same)
shutil.rmtree(os.path.join(plugins.plugins_dir(), "newagent"))   # 先删掉，下面才会去下载、校验
tampered = json.loads(json.dumps(INDEX))
tampered["plugins"][0]["versions"][0]["sha256"] = "0" * 64
store.index = tampered
check("包的 sha256 对不上：不装", "校验不通过" in store.install("newagent").get("error", ""))
evil = json.loads(json.dumps(INDEX))
evil["plugins"][0]["versions"] = [package("newagent", "1.0.5", extra={"../../escape.txt": "x"})]
store.index = evil
check("包里有跳出目录的路径：不装", "不安全" in store.install("newagent").get("error", "") and not os.path.exists(os.path.join(ROOT, "data", "escape.txt")))
store.index = INDEX
check("要的能力本机没有：不装、说要先更新", "需要先更新" in store.install("future").get("error", ""))

print("== 自动更新")
app.reconnects = 0
store.check(auto=True)
check("已在用的插件出新版本、检测到 agent 的新插件：自动装上，只重启一次 watcher",
      plugins.read_manifest(os.path.join(plugins.plugins_dir(), "codex"))["version"] == "1.0.2" and app.reconnects == 1)
check("没检测到 agent 的、要更新 Kiteline 的、吊销的：不动",
      not any(os.path.isdir(os.path.join(plugins.plugins_dir(), n)) for n in ("elsewhere", "future", "gone")))

print("== 开关")
store.set_enabled("codex", False)
check("关掉：记进偏好、带进 watcher 的环境变量", "codex" in plugins.config.read_json(store.prefs_path, {})["off"]
      and watcher.watcher_env().get("CCPULSE_PLUGINS_OFF") == "codex")
store.set_enabled("codex", True)
check("打开：环境变量里去掉", "CCPULSE_PLUGINS_OFF" not in watcher.watcher_env())
saved_local = list(store.local.get("plugins") or [])
store.local["plugins"] = saved_local + [{"id": "shyagent", "name": "Shy", "version": "1.0.0", "source": "builtin", "status": "off",
                                         "optIn": "要读它的密钥", "optInEn": "Reads its key"}]
shy = next(r for r in store.rows() if r["id"] == "shyagent")
check("默认不接的插件（optIn）：没打开时开关是关的，中英文说明带给客户端",
      not shy["enabled"] and shy["optIn"] == "要读它的密钥" and shy["optInEn"] == "Reads its key", str(shy)[:200])
store.set_enabled("shyagent", True)
check("打开默认不接的：记进 on、带进 watcher 的 CCPULSE_PLUGINS_ON", "shyagent" in plugins.config.read_json(store.prefs_path, {})["on"]
      and watcher.watcher_env().get("CCPULSE_PLUGINS_ON") == "shyagent" and next(r for r in store.rows() if r["id"] == "shyagent")["enabled"])
check("普通插件打开不记 on（不在 off 里就是开着）", "codex" not in store.prefs["on"])
store.set_enabled("shyagent", False)
check("再关掉：从 on 去掉、记进 off", "CCPULSE_PLUGINS_ON" not in watcher.watcher_env()
      and watcher.watcher_env().get("CCPULSE_PLUGINS_OFF") == "shyagent" and not next(r for r in store.rows() if r["id"] == "shyagent")["enabled"])
store.local["plugins"] = saved_local + [{"id": "metered", "name": "Metered", "version": "1.0.0", "source": "external", "status": "ok",
                                         "limitsNote": "按月计费", "limitsNoteEn": "Billed monthly",
                                         "options": [{"id": "usage", "name": "显示本月用量", "optIn": "要读它的登录令牌", "on": True}]}]
metered = next(r for r in store.rows() if r["id"] == "metered")
check("单项开关：默认关（以这边的偏好为准，不信 watcher 报的 on），说明和额度说明带给客户端",
      [(o["id"], o["on"]) for o in metered["options"]] == [("usage", False)] and metered["options"][0]["optIn"] == "要读它的登录令牌"
      and metered["limitsNote"] == "按月计费" and metered["limitsNoteEn"] == "Billed monthly", str(metered)[:300])
store.set_option("metered", "usage", True)
check("打开单项开关：记进偏好、带进 watcher 的 CCPULSE_PLUGIN_OPTIONS_ON，插件本身照常开着",
      plugins.config.read_json(store.prefs_path, {})["options"] == ["metered.usage"]
      and watcher.watcher_env().get("CCPULSE_PLUGIN_OPTIONS_ON") == "metered.usage" and store.watcher_env().get("CCPULSE_PLUGIN_OPTIONS_ON") == "metered.usage"
      and next(r for r in store.rows() if r["id"] == "metered")["options"][0]["on"] and "metered" not in store.prefs["on"])
store.set_option("metered", "usage", False)
check("关掉单项开关：环境变量里去掉", "CCPULSE_PLUGIN_OPTIONS_ON" not in watcher.watcher_env() and store.prefs["options"] == [])
store.local["plugins"] = saved_local
store.prefs["off"] = [i for i in store.prefs["off"] if i != "shyagent"]
store._save_prefs()

print("== 退回")
store.index = dict(INDEX, plugins=INDEX["plugins"][:1] + [{"id": "codex", "name": "Codex", "versions": [package("codex", "1.0.3")]}] + INDEX["plugins"][2:])
store.install("codex")
check("装新版时旧版留一份", plugins.read_manifest(os.path.join(plugins.plugins_dir(), ".previous", "codex"))["version"] == "1.0.2")
store.on_event(FakeSource(), {"event": "plugin_retired", "id": "codex", "version": "1.0.3", "error": "协议变了"})
deadline = time.time() + 5
while time.time() < deadline and plugins.read_manifest(os.path.join(plugins.plugins_dir(), "codex"))["version"] != "1.0.2":
    time.sleep(0.1)
check("watcher 停用了出错的外部插件 → 文件退回上一版本", plugins.read_manifest(os.path.join(plugins.plugins_dir(), "codex"))["version"] == "1.0.2")
store.local["hostCaps"] = ["fs.read"]
check("出过错的版本以后不再自动装", "codex@1.0.3" in store.prefs["bad"] and next(r for r in store.rows() if r["id"] == "codex")["action"] is None)
store.remove("codex")
check("恢复内置版本：删掉下载的", not os.path.isdir(os.path.join(plugins.plugins_dir(), "codex")))
store.prefs["bad"] = []
store.local["hostCaps"] = ["fs.read", "fs.tail", "net.connect"]
store.check(auto=True)
held_row = next(r for r in store.rows() if r["id"] == "codex")
check("手动移除过的：自动更新不再装回来（10-24 实测发现的问题）", not os.path.isdir(os.path.join(plugins.plugins_dir(), "codex"))
      and held_row["held"] and not held_row["autoInstall"] and held_row["action"] == "update", str(held_row)[:200])
store.install("codex")
check("再手动装一次：装上，并恢复自动更新", os.path.isdir(os.path.join(plugins.plugins_dir(), "codex")) and "codex" not in store.prefs["held"])
store.remove("codex")

print("== 出错报告")
event = {"event": "plugin_error", "id": "newagent", "name": "新 Agent", "version": "1.0.0", "source": "external",
         "where": "sessions", "error": "ValueError: 协议变了", "trace": "Traceback ...\nValueError: 协议变了"}
store.on_event(FakeSource(), event)
store.on_event(FakeSource(), event)
check("出错：记下、推给客户端弹窗（同一个错只推一次）", len(store.errors) == 1 and [e for e, _ in app.server.events].count("plugin_error") == 1)
report = store.report(key=store.errors[0]["key"])
check("报告：发到 hon6@foxmail.com 的邮件，正文有插件、版本、系统、出错位置", report["url"].startswith("mailto:hon6@foxmail.com?")
      and "新 Agent 1.0.0" in report["body"] and "sessions" in report["body"] and "协议变了" in report["body"]
      and plugins.config.PLATFORM in report["body"], report["body"][:300])
store.mute(store.errors[0]["key"])
store.on_event(FakeSource(), event)
check("选了不再询问：同一个错以后不弹", not store.errors and [e for e, _ in app.server.events].count("plugin_error") == 1)

print("== 更新 Kiteline 再装")
result = store.update_then_install("future")
check("记下待装、开始更新 Kiteline", result["ok"] and "future" in store.prefs["pending"] and app.updater.calls == ["check", "begin"])
check("待装的插件算自动装（更新完重启后能用了就装）", next(r for r in store.rows() if r["id"] == "future")["autoInstall"])

print("== 旧的「通用」开关并进插件页")


class FakeCfg:
    def __init__(self, on):
        self.data = {"mobile": {"installOpenCodePlugin": on}}

    @property
    def mobile(self):
        return self.data["mobile"]

    def update(self, fn):
        fn(self.data)


legacy_dir = os.path.join(ROOT, "legacy-config")
os.makedirs(legacy_dir)
saved_dir = os.environ["KITELINE_CONFIG_DIR"]
os.environ["KITELINE_CONFIG_DIR"] = legacy_dir   # 新的偏好文件
legacy_app = FakeApp()
legacy_app.cfg = FakeCfg(False)
legacy = plugins.PluginStore(legacy_app)
check("以前在「通用」里关掉了 OpenCode 插件：插件页里 OpenCode 也是关着的（只迁一次）", "opencode" in legacy.prefs["off"]
      and "opencode-switch" in legacy.prefs["flags"] and "opencode" in watcher.watcher_env().get("CCPULSE_PLUGINS_OFF", ""))
legacy.set_enabled("opencode", True)
check("在插件页打开 OpenCode：旧的「为 OpenCode 安装 Kiteline 插件」跟着打开", legacy_app.cfg.mobile["installOpenCodePlugin"] is True
      and watcher.OPENCODE_PLUGIN is True and "CCPULSE_OPENCODE_PLUGIN" not in watcher.watcher_env())
again = plugins.PluginStore(legacy_app)
check("迁移只做一次：之后以插件页为准", "opencode" not in again.prefs["off"])
os.environ["KITELINE_CONFIG_DIR"] = saved_dir

print("== 远端同步")
data_a, fp_a = plugins.bundle()
data_b, fp_b = plugins.bundle()
check("插件目录打包：内容不变指纹不变", fp_a == fp_b and data_a and fp_a != "none")
fake_home = os.path.join(ROOT, "remote-home")
os.makedirs(fake_home)
code = plugins.REMOTE_UNPACK
run = subprocess.run([sys.executable, "-c", code, fp_a], input=base64.b64encode(data_a), capture_output=True,
                     env=dict(os.environ, HOME=fake_home, USERPROFILE=fake_home))
remote_root = os.path.join(fake_home, ".ccpulse", "synced-plugins")   # 远端单独的目录，不碰远端自己的 ~/.ccpulse/plugins
check("远端解包：插件原样到位、写下指纹", b"PLUGINS_OK" in run.stdout and os.path.isfile(os.path.join(remote_root, "newagent", "plugin.py"))
      and open(os.path.join(remote_root, ".sync")).read() == fp_a, run.stderr[-300:])
run = subprocess.run([sys.executable, "-c", code, "none"], input=b"", capture_output=True, env=dict(os.environ, HOME=fake_home, USERPROFILE=fake_home))
check("本机没插件了：远端清空", b"PLUGINS_OK" in run.stdout and os.listdir(remote_root) == [".sync"], run.stderr[-300:])
check("远端执行的命令是一行（经 ssh 传）", "\n" not in plugins.remote_unpack_command("python3", fp_a))
check("远端 watcher 从单独的目录读同步过去的插件", plugins.REMOTE_DIR_ENV == 'CCPULSE_PLUGINS_DIR="$HOME/.ccpulse/synced-plugins"'
      and "synced-plugins" in plugins.remote_check_command())

print("== 真的 watcher 载入装好的插件")
script = os.path.join(HERE, "..", "..", "watcher", "kiteline-watch.py")
env = dict(os.environ, CCPULSE_SESSIONS_DIR=os.path.join(ROOT, "sessions"), CCPULSE_OPENCODE_PLUGIN="0", PYTHONUTF8="1")
proc = subprocess.Popen([sys.executable, script], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True, encoding="utf-8")
proc.stdin.write(json.dumps({"id": "p1", "cmd": "plugins"}) + "\n")
proc.stdin.flush()
reply, sessions = None, []
deadline = time.time() + 20
while time.time() < deadline and (reply is None or not sessions):
    line = proc.stdout.readline()
    if not line:
        break
    item = json.loads(line)
    if item.get("event") == "response" and item.get("id") == "p1":
        reply = item
    if item.get("event") == "snapshots":
        sessions = [s for s in item.get("sessions") or [] if s.get("agent") == "newagent"]
proc.kill()
listed = {r["id"]: r for r in (reply or {}).get("plugins") or []}
check("watcher 列出下载装好的新 agent 插件（外部、1.0.0）", listed.get("newagent", {}).get("source") == "external"
      and listed["newagent"]["version"] == "1.0.0", str(reply)[:300])
check("新 agent 的会话出现在快照里", sessions and sessions[0]["sessionId"] == "n1", str(sessions)[:200])

print("== 吊销")
store.index = json.loads(json.dumps(INDEX))
store.local["hostCaps"] = ["fs.read", "fs.tail", "net.connect"]
store.prefs["held"] = []
store.install("newagent", restart=False)
revoked_index = json.loads(json.dumps(INDEX))
revoked_index["plugins"][0]["versions"][0]["revoked"] = True
publish(revoked_index)
app.reconnects = 0
store.check(auto=True)
check("我们吊销了装着的版本：退回（没有上一版本就删掉）、记成坏版本、重连 watcher",
      not os.path.isdir(os.path.join(plugins.plugins_dir(), "newagent")) and "newagent@1.0.0" in store.prefs["bad"] and app.reconnects >= 1)
publish(INDEX)
store.fetch_index()

print("== 给手机的标准字段（caps、待确认的按钮、只读说明、agent 标志）")
from kiteline import config as kconfig, store as kstore  # noqa: E402


class SnapSource:
    id, name, kind, live, config = "local", "本机", "local", True, {}

    def short_label(self):
        return "已连接"


mobile_store = kstore.Store(kconfig.Config(), lambda: None, lambda *a, **k: None)
mobile_store.add_source(SnapSource())
mobile_store.apply_snapshots(SnapSource(), [
    {"sessionId": "c1", "name": "claude", "activity": "idle"},
    {"sessionId": "x1", "name": "codex", "agent": "codex", "activity": "waiting", "pendingTool": "Bash", "caps": [],
     "pendingOptions": [{"key": "esc", "label": "拒绝", "style": "destructive"}, {"key": "1", "label": "允许", "style": "primary"},
                        {"key": "3", "label": "拒绝并告诉它怎么做", "labelEn": "Deny and Tell It What to Do"},
                        {"label": "缺 key 的不要"}, "坏的"]},
    {"sessionId": "o1", "name": "old", "agent": "opencode", "activity": "idle"},
    {"sessionId": "q1", "name": "qwen", "agent": "qwen-code", "activity": "idle", "readOnly": True, "readOnlyReason": "不在 tmux 中运行，只能查看",
     "readOnlyReasonEn": "Not running in tmux, so view-only.", "caps": ["compact"]},
])
by_id = {item["sessionId"]: item for item in mobile_store.state_payload("host", "1.0", {})["sessions"]}
check("Claude Code 的会话（watcher 不带 caps）：按 Claude Code 补全套", by_id["c1"]["caps"] == kstore.CLAUDE_CAPS, str(by_id["c1"].get("caps")))
check("老 watcher 的别家会话：caps 为空", by_id["o1"]["caps"] == [])
check("插件给的 caps 原样转", by_id["q1"]["caps"] == ["compact"] and by_id["x1"]["caps"] == [])
check("待确认的按钮：原样转，缺字段、写坏的丢掉", by_id["x1"].get("pendingOptions") == [
    {"key": "esc", "label": "拒绝", "style": "destructive"}, {"key": "1", "label": "允许", "style": "primary"},
    {"key": "3", "label": "拒绝并告诉它怎么做", "style": "normal", "labelEn": "Deny and Tell It What to Do"}], str(by_id["x1"].get("pendingOptions")))
from kiteline import i18n as ki18n  # noqa: E402
english = {item["sessionId"]: item for item in ki18n.localize(list(by_id.values()))}
check("英文设备：按钮用我们的词表或插件自带的英文，只读说明用插件自带的英文（En 字段不单独发）",
      [o["label"] for o in english["x1"]["pendingOptions"]] == ["Deny", "Allow", "Deny and Tell It What to Do"]
      and english["q1"]["readOnlyReason"] == "Not running in tmux, so view-only." and "readOnlyReasonEn" not in english["q1"]
      and "labelEn" not in english["x1"]["pendingOptions"][2], str(english["x1"]["pendingOptions"]))
check("只读说明原样转", by_id["q1"].get("readOnlyReason") == "不在 tmux 中运行，只能查看" and by_id["q1"].get("readOnly") is True)
check("不在等确认的不带按钮", "pendingOptions" not in by_id["c1"] and "pendingOptions" not in by_id["q1"])
cards = plugins.agent_cards([{"id": "newagent", "name": "旧名字"}, {"name": "没 id"},
                             {"id": "newagent", "name": "New Agent", "speaker": "New", "mark": [{"d": "M0 0h24v24H0z", "opacity": 1}]},
                             {"id": "codex", "name": "Codex", "speaker": "", "mark": None}])
check("agent 标志表：同 id 后面的（watcher 报的）盖过前面的（索引），空的称呼、标志不带",
      cards == [{"id": "newagent", "name": "New Agent", "speaker": "New", "mark": [{"d": "M0 0h24v24H0z", "opacity": 1}]},
                {"id": "codex", "name": "Codex"}], str(cards))
card_store = plugins.PluginStore(FakeApp())
card_store.index = {"plugins": [{"id": "fromindex", "name": "From Index", "mark": "M1 1h2v2H1z", "versions": []}]}
card_store.cards = {"newagent": {"id": "newagent", "name": "New Agent", "version": "1.0.0", "mark": [{"d": "M0 0h1v1H0z"}],
                                 "minApp": {"ios": "1.3"}}}
check("给手机的 agents：索引里的和各台 watcher 报的合起来",
      [c["id"] for c in card_store.agent_cards()] == ["fromindex", "newagent"] and card_store.agent_cards()[0]["mark"] == "M1 1h2v2H1z")
check("装着的插件要求的最低手机版本转给手机（手机版本低就提示去 App Store 更新）；索引条目里的不算",
      card_store.agent_cards()[1].get("minApp") == {"ios": "1.3"} and "minApp" not in plugins.agent_cards(
          [{"id": "x", "name": "X", "versions": [], "minApp": {"ios": "2.0"}}])[0])

httpd.shutdown()
shutil.rmtree(ROOT, ignore_errors=True)
print("\nplugins：%s" % ("全部通过" if not FAILED else "%d 项失败" % FAILED))
sys.exit(1 if FAILED else 0)
