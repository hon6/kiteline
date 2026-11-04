"""电脑端自己的单元测试（不起服务）：python desktop/tests/test_desktop.py"""
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
# 配置、日志都写到临时目录：别碰这台电脑上正在用的 Kiteline（~/.config/kiteline、%APPDATA%\Kiteline）
os.environ["KITELINE_CONFIG_DIR"] = tempfile.mkdtemp(prefix="kiteline-unit-")

from kiteline import agent_skill, devices, server, voice  # noqa: E402

FAILED = 0


def check(name, ok, detail=""):
    global FAILED
    print("  [%s] %s %s" % ("PASS" if ok else "FAIL", name, detail if not ok else ""))
    if not ok:
        FAILED += 1


print("== 网页版已下线：根路径只有说明页")
check("说明页提示用 iPhone 上的 Kiteline App 连接、不带脚本", "Kiteline App" in server.NOTICE_PAGE and "<script" not in server.NOTICE_PAGE)
check("说明页的内容安全策略禁止脚本和嵌入", "default-src 'none'" in server.NOTICE_CSP and "frame-ancestors 'none'" in server.NOTICE_CSP)

print("== 控制台入口：一次性票据，主令牌不进地址栏")
from kiteline import ui  # noqa: E402
from kiteline.httpd import Request  # noqa: E402


class _Cfg:
    mobile = {"port": 8765, "token": "master-token"}


class _App:
    cfg = _Cfg()


console = ui.Console(_App())
url = console.url()
check("地址里不带主令牌", "master-token" not in url and "?k=" in url, url)
ticket_path = url.split("127.0.0.1:8765", 1)[1]
first = console.handle(Request("GET", ticket_path, {}, b"", "127.0.0.1"), False)
location = first.headers.get("Location", "")
session = location.split("#s=", 1)[-1]
check("票据换成控制台会话令牌，放在 # 片段里（不发给服务器）", first.status == 303 and location.startswith("/desktop#s=c")
      and "master-token" not in location and "Set-Cookie" not in first.headers, str(first.headers))
check("会话令牌能用、不是主令牌", console.session_ok(session) and session != "master-token")
again = console.handle(Request("GET", ticket_path, {}, b"", "127.0.0.1"), False)
check("同一张票据不能用第二次（不再发新会话）", again.status == 200 and "Location" not in again.headers)
check("随便编的会话令牌不认", not console.session_ok("c" + "0" * 48) and not console.session_ok("master-token"))
check("没有会话令牌拿不到数据", console.handle(Request("GET", "/api/desktop/status", {}, b"", "127.0.0.1"), False) is None)

print("== 配对码锁定按来源")
pairing = devices.Pairing()
pairing.new_code()
for _ in range(8):
    pairing.check_code("000000", "10.0.0.9")
check("同一来源错 8 次被锁", pairing.check_code(pairing.code, "10.0.0.9") == (False, "locked"))
check("别的来源不受影响", pairing.check_code(pairing.code, "10.0.0.8")[0] is True)

print("== 技能（交给 watcher 装，这里只带开关）")
os.environ["KITELINE_SKILL_TEST"] = "1"
agent_skill.ENABLED, agent_skill.TEST_ENABLED, agent_skill.TODO_ENABLED, agent_skill.STAGE_ENABLED = True, False, True, True
env = agent_skill.local_env("/x/ccpulse-watch.py")
check("开着的技能经 CCPULSE_SKILLS 带给 watcher", env.get("CCPULSE_SKILLS") == "screenshots,todos,stages", str(env))
check("远端：python 不是 python3 时告诉它", agent_skill.remote_env("python3.11").get("CCPULSE_PYTHON") == "python3.11")
agent_skill.ENABLED = agent_skill.TODO_ENABLED = agent_skill.STAGE_ENABLED = False
check("全关：远端也带空值（让它删掉）", agent_skill.remote_env("python3") == {"CCPULSE_SKILLS": "''"})
os.environ.pop("KITELINE_SKILL_TEST")
os.environ["KITELINE_CONFIG_DIR"] = os.environ.get("KITELINE_CONFIG_DIR") or "/tmp/kl-isolated"
check("隔离的测试实例不带技能开关（不动真的技能目录）", agent_skill.local_env("/x/ccpulse-watch.py") == {})
agent_skill.ENABLED = agent_skill.TEST_ENABLED = agent_skill.TODO_ENABLED = True
# 技能命令里的路径：没空格不加引号（带引号的程序路径 PowerShell 不执行），有空格才加
check("技能命令：路径没空格不加引号（PowerShell、cmd、Git Bash 都能跑）",
      agent_skill._quote("C:\\Users\\kite\\.ccpulse\\ccpulse-watch.py") == "C:/Users/kite/.ccpulse/ccpulse-watch.py")
check("技能命令：路径有空格还是加引号", agent_skill._quote("/home/a b/ccpulse-watch.py") == '"/home/a b/ccpulse-watch.py"')

print("== 用量：各台电脑按 agent 合起来（旧版 watcher 没有这一项，当它只统计 Claude Code）")
import threading as _ag_threading  # noqa: E402
from kiteline import aggregate as _ag  # noqa: E402


class _AgSource:
    def __init__(self, sid, name, reply):
        self.id, self.name, self.live, self.reply, self.kind = sid, name, True, reply, "local"

    def request(self, request, timeout=None):
        return self.reply


_ag_row = lambda **kw: dict({"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "requests": 0, "cost": 0.0, "estimated": 0.0}, **kw)
_ag_new = {"days": [], "models": [], "projects": [], "unpriced": ["deepseek-flash"],
           "totals": _ag_row(input=130, output=13, requests=3, cost=1.0),
           "agents": [_ag_row(agent="claude", name="Claude Code", input=100, output=10, requests=2, cost=1.0),
                      _ag_row(agent="deepseek-harness", name="DeepSeek Harness", input=30, output=3, requests=1, unpriced=True)]}
_ag_old = {"days": [], "models": [], "projects": [], "unpriced": [], "totals": _ag_row(input=50, output=5, requests=1, cost=0.5)}
_ag_store = type("Store", (), {"lock": _ag_threading.Lock(), "sources": {"a": _AgSource("a", "Mac", _ag_new), "b": _AgSource("b", "旧电脑", _ag_old)}})()
_ag_report = _ag.usage(_ag_store, 1, fresh=True)
_ag_by = {a["agent"]: a for a in _ag_report.get("agents") or []}
check("用量按 agent：两台合起来、旧版 watcher 算进 Claude Code", _ag_by.get("claude", {}).get("input") == 150
      and _ag_by.get("claude", {}).get("requests") == 3 and not _ag_by["claude"].get("unpriced"), str(_ag_report.get("agents")))
check("用量按 agent：没记花费的 agent 带「仅 token」标记", _ag_by.get("deepseek-harness", {}).get("unpriced") is True, str(_ag_by))

print("== 语音分段")
import numpy as np  # noqa: E402
rate = 16000
samples = np.ones(rate * 40, dtype=np.float32) * 0.3
samples[rate * 11: rate * 11 + rate // 2] = 0   # 11 秒处一段静音
chunks = voice.split(samples, rate)
check("长录音在停顿处切开、每段不超过 15 秒", all(len(c) <= 15 * rate for c in chunks) and abs(len(chunks[0]) - 11.25 * rate) < rate,
      [round(len(c) / rate, 1) for c in chunks])
check("切完一个采样都不少", sum(len(c) for c in chunks) == len(samples))

print("== 证书里的本机地址：只跳过手机连不到的网卡")
from kiteline import netinfo  # noqa: E402
for name in ["docker0", "br-618adfa78270", "veth77d6df0@if2", "virbr0"]:
    check("跳过 %s" % name, netinfo.skip_interface(name))
for name in ["br-vm", "br-lan", "br0", "wlp195s0", "eth0", "enp3s0"]:
    check("保留 %s" % name, not netinfo.skip_interface(name))

print("== 图片缓存：启动时清掉 14 天没用过的")
import time  # noqa: E402
from kiteline.records import MediaCache  # noqa: E402
cache = MediaCache()
cache.directory = tempfile.mkdtemp()
cache.store("会话|新图", b"new", "image/png")
cache.store("会话|旧图", b"old", "image/png")
cache.store("会话|旧图但刚看过", b"seen", "image/png")
old = time.time() - 20 * 86400
for key in ["会话|旧图", "会话|旧图但刚看过"]:
    os.utime(cache._name(key), (old, old))
check("看过的图会刷新时间", cache.load("会话|旧图但刚看过") == (b"seen", "image/png"))
open(os.path.join(cache.directory, "孤立.mime"), "w").write("image/png")
cache.prune()
check("14 天没用过的删掉（连同类型文件）", cache.load("会话|旧图") is None and not os.path.exists(cache._name("会话|旧图") + ".mime"))
check("新的、刚看过的留着", cache.load("会话|新图") == (b"new", "image/png") and cache.load("会话|旧图但刚看过") is not None)
check("没有图的类型文件也删掉", not os.path.exists(os.path.join(cache.directory, "孤立.mime")))

print("== 扩展 URI 预填内容：特殊字符原样到达输入框")
import urllib.parse  # noqa: E402
from kiteline import delivery as _delivery  # noqa: E402
text = "a+b=c 50%\n第二行 & 结尾 #号 ?问号 /斜杠"
single = _delivery.editor_link("s-1", "vscode", text)
check("单层编码：扩展解析出原文", urllib.parse.parse_qs(single.split("?", 1)[1])["prompt"] == [text])
double = _delivery.editor_link("s-1", "vscode", text, shell_decodes=True)
once = urllib.parse.unquote(double)   # Windows 打开协议链接时先解码一次
check("两层编码：Windows 解码一次后扩展仍解析出原文", urllib.parse.parse_qs(once.split("?", 1)[1])["prompt"] == [text])
check("不带内容时只切会话", _delivery.editor_link("s-1") == "vscode://anthropic.claude-code/open?session=s-1")
check("新会话只带内容", _delivery.editor_link(None, "vscode", "hi") == "vscode://anthropic.claude-code/open?prompt=hi")


class _Rec:
    def __init__(self, title):
        self.snap = {"title": title, "name": "kl06-proj-ea"}


check("没发过消息、同目录还有别的会话：动 VS Code 前就拒绝", "尚未发送过消息" in (_delivery.untitled_problem(_Rec(""), 1) or ""))
check("没发过消息、只有它一个：放行（前台是「Claude Code」标签即可）", _delivery.untitled_problem(_Rec(""), 0) is None)
check("有标题的会话：放行", _delivery.untitled_problem(_Rec("首页卡片间距"), 3) is None)

# Claude 没起成标题：watcher 拿第一句当标题，tabNames 给标签可能显示的第一句 / 最近一句
_prompted = _Rec("订单列表里，清空筛选条件后又重新筛选，现在接口报错了，怎么办，帮我看看…")
_prompted.snap.update({"cwd": "/p/shop-app", "tabNames": ["订单列表里，清空筛选条件后又重新筛选，现在接口报错了，怎么办", "继续"]})
check("没标题的会话：当场发的标签（第一句截断）认得出",
      _delivery.front_problem("订单列表里，清空筛选条件后又重新筛选，现在… - shop-app - Visual Studio Code", _prompted, 1) is None)
check("没标题的会话：重开 VS Code 恢复的标签（最近一句）认得出",
      _delivery.front_problem("继续 - shop-app - Visual Studio Code", _prompted, 1) is None)
check("没标题的会话：别的会话的标签照样拒发",
      "未能切换到会话" in (_delivery.front_problem("优惠券配置 - shop-app - Visual Studio Code", _prompted, 1) or ""))
check("标签名里的换行按空格比", _delivery.tab_matches("第一行 第二行的内容比较长…", "第一行\n\n第二行的内容比较长一些"))

if sys.platform.startswith("linux"):
    print("== VS Code 远程连接里的会话：直接说明原因，不去找本机窗口")
    import shutil  # noqa: E402
    import subprocess  # noqa: E402
    from kiteline import delivery  # noqa: E402
    server_bin = os.path.join(tempfile.mkdtemp(), ".vscode-server", "extensions", "claude", "claude")
    os.makedirs(os.path.dirname(server_bin))
    shutil.copy(shutil.which("sleep"), server_bin)
    remote = subprocess.Popen([server_bin, "30"])
    local = subprocess.Popen([shutil.which("sleep"), "30"])
    try:
        check("认出 ~/.vscode-server 里跑的会话", delivery.remote_editor(remote.pid))
        check("本机的会话不算", not delivery.remote_editor(local.pid))
        check("进程已不在也不算", not delivery.remote_editor(99999999))
    finally:
        remote.kill(); local.kill()

print("== 一键安装从手机发消息所需的组件（只认白名单动作，测试里不真装）")
import shlex  # noqa: E402
from kiteline import setup_tools  # noqa: E402
_which, _linux, _dry = setup_tools.shutil.which, setup_tools.config.IS_LINUX, setup_tools.delivery.DRY_RUN
_bridge_item, _uinput_item = dict(setup_tools.COMPONENTS["vscode-bridge"]), dict(setup_tools.COMPONENTS["uinput"])
_installs = []
try:
    setup_tools.config.IS_LINUX = True
    setup_tools.COMPONENTS["vscode-bridge"].update(check=lambda: False, install=lambda: (_installs.append(1), (True, "已在 VS Code 中安装 Kiteline 配套扩展"))[1])
    setup_tools.COMPONENTS["uinput"]["check"] = lambda: False
    setup_tools.shutil.which = lambda name: "/usr/bin/apt-get" if name == "apt-get" else None
    check("缺什么列得出来", setup_tools.missing() == ["xdotool", "clipboard", "tmux", "vscode-bridge", "uinput"], setup_tools.missing())
    act = setup_tools.action("install-vscode-tools")
    check("VS Code 那项：装配套扩展、授予键盘模拟权限（udev uaccess），不装 xdotool / tmux", act and act["id"] == "install-vscode-tools"
          and "70-kiteline-uinput.rules" in act["command"] and "uaccess" in act["command"]
          and "xdotool" not in act["command"] and "tmux" not in act["command"], act)
    check("给用户看的命令能被 shell 原样解析", shlex.split(act["command"])[:3] == ["sudo", "sh", "-c"]
          and shlex.split(act["command"])[3] == setup_tools.UINPUT_SCRIPT)
    check("终端那项的按钮只装 tmux", "tmux" in setup_tools.manual_command("install-tmux")
          and "uinput" not in setup_tools.manual_command("install-tmux"))
    check("不认识的动作一律拒绝", setup_tools.start("install-tmux; rm -rf /") == (False, "不支持的操作")
          and setup_tools.start("") == (False, "不支持的操作"))
    setup_tools.delivery.DRY_RUN = True
    ok, message = setup_tools.start("install-tmux")
    check("测试实例里只说要执行什么，不真装", ok and message.startswith("（测试）") and "tmux" in message, message)
    ok, message = setup_tools.start("install-vscode-tools")
    check("测试实例里扩展也不真装", ok and "VS Code 配套扩展" in message and "uaccess" in message and not _installs, message)
    setup_tools.delivery.DRY_RUN = False
    setup_tools.COMPONENTS["uinput"]["check"] = lambda: True
    act = setup_tools.action("install-vscode-tools")
    check("只缺扩展：有按钮、不用管理员命令", act and act["command"] == "", act)
    ok, message = setup_tools.start("install-vscode-tools")
    check("只缺扩展：直接装上，提示重新打开 VS Code", ok and _installs and "重新打开" in message, message)
    setup_tools.COMPONENTS["vscode-bridge"]["check"] = lambda: True
    setup_tools.shutil.which = lambda name: "/usr/bin/" + name
    check("都装好了：没有按钮", setup_tools.action("install-vscode-tools") is None and setup_tools.start("install-all") == (True, "所需组件都已安装"))
    setup_tools.shutil.which = lambda name: "/usr/bin/xsel" if name == "xsel" else ("/usr/bin/dnf" if name == "dnf" else None)
    check("有 xsel 不缺剪贴板；认得出 dnf", "clipboard" not in setup_tools.missing()
          and setup_tools.manual_command("install-tmux") == "sudo sh -c 'dnf install -y tmux'", setup_tools.manual_command("install-tmux"))
    setup_tools.shutil.which = lambda name: None
    setup_tools.COMPONENTS["uinput"]["check"] = lambda: False
    check("认不出包管理器：tmux 没有按钮（只给文字说明）", setup_tools.action("install-tmux") is None)
    check("认不出包管理器：键盘模拟权限照样能装（不靠包管理器）", setup_tools.action("install-vscode-tools") is not None)
    setup_tools.config.IS_LINUX = False
    check("Windows 上不缺这些", setup_tools.missing() == [] and setup_tools.action("install-tmux") is None)
finally:
    setup_tools.shutil.which, setup_tools.config.IS_LINUX, setup_tools.delivery.DRY_RUN = _which, _linux, _dry
    setup_tools.COMPONENTS["vscode-bridge"], setup_tools.COMPONENTS["uinput"] = _bridge_item, _uinput_item

if sys.platform.startswith("linux"):
    print("== Linux：经 VS Code 配套扩展投递（假扩展；核对不过时一个键都不按）")
    import json as _json  # noqa: E402
    import socket as _socket  # noqa: E402
    import threading as _threading  # noqa: E402
    from kiteline import bridge, delivery_bridge, uinput  # noqa: E402

    class _FakeVSCode:
        """假的配套扩展：记下收到的命令，按设定回状态"""
        def __init__(self, path, folders, focused=True, tab="Claude Code", opened_tab=None):
            self.calls, self.focused, self.tab, self.opened_tab, self.folders = [], focused, tab, opened_tab, folders
            self.server = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM)
            self.server.bind(path)
            self.server.listen(8)
            _threading.Thread(target=self.serve, daemon=True).start()

        def state(self):
            return {"ok": True, "version": 1, "focused": self.focused, "folders": self.folders, "activeTab": self.tab,
                    "activeKind": "mainThreadWebview-claudeVSCodePanel"}

        def serve(self):
            while True:
                try:
                    conn, _ = self.server.accept()
                except OSError:
                    return
                data = b""
                while not data.endswith(b"\n"):
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    data += chunk
                request = _json.loads(data)
                self.calls.append(request["cmd"] if request["cmd"] != "paste" else ("paste", request["text"]))
                if request["cmd"] == "open" and self.opened_tab:
                    self.tab = self.opened_tab
                conn.sendall((_json.dumps(self.state()) + "\n").encode())
                conn.close()

    def _acts(fake):
        """收到的动作（去掉查询状态）"""
        return [c for c in fake.calls if c != "state"]

    class _BRec:
        kind = "local"

        def __init__(self, title, cwd="/home/u/proj/app"):
            self.key = "k"
            self.snap = {"title": title, "name": "app", "cwd": cwd, "sessionId": "6d563254-a5b1-4935-815d-5e19326e8c2c"}

    runtime = tempfile.mkdtemp()
    _env = os.environ.get("XDG_RUNTIME_DIR")
    _saved = (bridge.installed, uinput.available, delivery_bridge._tap, delivery_bridge.locked)
    taps = []
    os.environ["XDG_RUNTIME_DIR"] = runtime
    os.makedirs(os.path.join(runtime, "kiteline"), mode=0o700)
    bridge.installed = lambda: True
    uinput.available = lambda: True
    delivery_bridge._tap = taps.append
    delivery_bridge.locked = lambda: False
    try:
        outer = _FakeVSCode(os.path.join(runtime, "kiteline", "vscode-1.sock"), ["/home/u"])
        inner = _FakeVSCode(os.path.join(runtime, "kiteline", "vscode-2.sock"), ["/home/u/proj"], opened_tab="首页卡片间距")
        stale = os.path.join(runtime, "kiteline", "vscode-3.sock")
        _dead = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM); _dead.bind(stale); _dead.close()
        check("会话目录在两个窗口里：取打开的文件夹最深的那个", bridge.window_for(_BRec("首页卡片间距")).path == inner.server.getsockname())
        check("窗口关掉后留下的套接字顺手删掉", not os.path.exists(stale))
        os.chmod(os.path.join(runtime, "kiteline"), 0o755)
        check("通道目录别人也能进：不认（可能是别人放的假通道）", bridge.windows() == [])
        os.chmod(os.path.join(runtime, "kiteline"), 0o700)
        out = delivery_bridge.send_vscode("把按钮改大一点", _BRec("首页卡片间距"), True, 1)
        check("切到会话 → 聚焦 → 粘贴 → 再核对 → 回车", out.ok and out["submitted"] and _acts(inner) == ["open", "focus", ("paste", "把按钮改大一点")]
              and inner.calls[-1] == "state" and taps == ["enter"], (out, inner.calls, taps))
        inner.calls.clear(); taps.clear()
        out = delivery_bridge.send_vscode("/compact", _BRec("首页卡片间距"), True, 1)
        check("斜杠命令按两次回车", out.ok and taps == ["enter", "enter"], taps)
        inner.calls.clear(); taps.clear(); inner.focused = False
        out = delivery_bridge.send_vscode("hi", _BRec("首页卡片间距"), True, 1)
        check("VS Code 不在前台：不切、不粘贴、不按键", not out.ok and "不在前台" in out["message"] and _acts(inner) == [] and taps == [], (out, inner.calls))
        inner.focused, inner.opened_tab, inner.tab = True, "别的会话", "别的会话"
        inner.calls.clear()
        out = delivery_bridge.send_vscode("hi", _BRec("首页卡片间距"), True, 1)
        check("切过去还是别的会话：不粘贴、不按键", not out.ok and "未能切换" in out["message"] and _acts(inner) == ["open"] and taps == [], (out, inner.calls))
        inner.opened_tab, inner.tab = None, "Claude Code"
        inner.calls.clear()
        out = delivery_bridge.send_vscode("hi", _BRec(""), True, 0)
        check("没发过消息、只有它一个：不开会话（会另开空白标签），直接核对当前标签", out.ok and _acts(inner) == ["focus", ("paste", "hi")], inner.calls)
        inner.calls.clear(); taps.clear()
        out = delivery_bridge.send_vscode("hi", _BRec(""), True, 1)
        check("没发过消息、同目录还有别的会话：拒绝", not out.ok and taps == [] and not any(isinstance(c, tuple) for c in inner.calls))
        inner.calls.clear(); taps.clear(); inner.opened_tab = "首页卡片间距"
        out = delivery_bridge.press_vscode("1", 1, _BRec("首页卡片间距"), 1)
        check("确认框按 1：切到会话后直接按，不聚焦输入框、不粘贴", out.ok and _acts(inner) == ["open"] and taps == ["1"], (inner.calls, taps))
        check("按键只认写死的几个", not delivery_bridge.press_vscode("ctrl+alt+t", 1, _BRec("首页卡片间距"), 1).ok)
    finally:
        bridge.installed, uinput.available, delivery_bridge._tap, delivery_bridge.locked = _saved
        if _env is None:
            os.environ.pop("XDG_RUNTIME_DIR", None)
        else:
            os.environ["XDG_RUNTIME_DIR"] = _env

    print("== 配套扩展打包成 .vsix")
    import zipfile as _zipfile  # noqa: E402
    vsix = bridge.build_vsix(os.path.join(tempfile.mkdtemp(), "b.vsix"))
    names = _zipfile.ZipFile(vsix).namelist()
    check("vsix 里有清单、package.json、extension.js", {"extension.vsixmanifest", "extension/package.json", "extension/extension.js"} <= set(names), names)

if sys.platform.startswith("linux"):
    print("== 配套扩展的通道：只跟本用户的 VS Code 说话")
    import json as _json  # noqa: E402
    import socket as _socket  # noqa: E402
    import threading as _threading  # noqa: E402
    from kiteline import bridge  # noqa: E402
    _path = os.path.join(tempfile.mkdtemp(), "vscode-test.sock")
    _srv = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM)
    _srv.bind(_path)
    _srv.listen(4)

    def _serve():
        for _ in range(2):
            conn, _ = _srv.accept()
            conn.recv(65536)
            conn.sendall((_json.dumps({"ok": True, "focused": True}) + "\n").encode())
            conn.close()
    _threading.Thread(target=_serve, daemon=True).start()
    check("同一个用户开的通道：正常收发", bridge.call(_path, {"cmd": "state"}, timeout=3).get("ok") is True)
    _getuid = bridge.os.getuid
    bridge.os.getuid = lambda: _getuid() + 1   # 当成「另一头是别的用户」
    try:
        bridge.call(_path, {"cmd": "state"}, timeout=3)
        check("别的用户放的假通道：拒绝（不发消息内容）", False)
    except PermissionError:
        check("别的用户放的假通道：拒绝（不发消息内容）", True)
    finally:
        bridge.os.getuid = _getuid
        _srv.close()

print("== 远端项目开 VS Code 窗口（remotessh）")
from kiteline import remotessh  # noqa: E402
# 期望值由 Remote-SSH 0.128 的 HostInfo.toAuthorityString 原样算出（和 Mac 版 WindowLocator.sshAuthority 同一组）
for (_host, _port), _want in {
    ("vm", None): "vm",
    ("10.168.1.10", None): "10.168.1.10",
    ("MyServer", None): "7b22686f73744e616d65223a224d79536572766572227d",
    ("kite@10.168.1.166", None): "7b22686f73744e616d65223a2231302e3136382e312e313636222c2275736572223a226b697465227d",
    ("build-01", 2222): "7b22686f73744e616d65223a226275696c642d3031222c22706f7274223a323232327d",
    ("a+b", None): "7b22686f73744e616d65223a22612b62227d",
}.items():
    check("主机写法 %s%s" % (_host, ":%s" % _port if _port else ""), remotessh.ssh_authority(_host, _port) == _want,
          remotessh.ssh_authority(_host, _port))
check("远端目录地址：路径按 URI 编码", remotessh.folder_uri("vm", None, "/home/k/my proj") == "vscode-remote://ssh-remote+vm/home/k/my%20proj")
check("远端是 Windows：路径写成 /c:/…", remotessh.folder_uri("win", None, "C:\\Users\\k\\proj") == "vscode-remote://ssh-remote+win/C:/Users/k/proj")

_settings = os.path.join(tempfile.mkdtemp(prefix="kl-vscode-"), "settings.json")
_orig_path, _orig_win = remotessh._settings_path, remotessh.config.IS_WINDOWS
remotessh._settings_path = lambda: _settings
remotessh.config.IS_WINDOWS = True
try:
    remotessh.ensure_platform("kite@10.168.1.166", "linux")
    check("没有设置文件：新建并写上这台主机", remotessh._parse_jsonc(open(_settings, encoding="utf-8").read())
          == {"remote.SSH.remotePlatform": {"10.168.1.166": "linux"}})
    with open(_settings, "w", encoding="utf-8") as _f:
        _f.write('{\n  // 用户自己的注释\n  "editor.fontSize": 14, /* 块注释 */\n  "remote.SSH.remotePlatform": {\n    "old": "windows"\n  },\n}\n')
    remotessh.ensure_platform("build-01", "darwin")
    _text = open(_settings, encoding="utf-8").read()
    check("已有设置项：只往里加一台主机", remotessh._parse_jsonc(_text)
          == {"editor.fontSize": 14, "remote.SSH.remotePlatform": {"build-01": "macOS", "old": "windows"}}, _text)
    check("已有设置：注释原样保留", "// 用户自己的注释" in _text and "/* 块注释 */" in _text)
    remotessh.ensure_platform("build-01", "linux")
    check("这台主机已经有了：不改（用户自己选的为准）", open(_settings, encoding="utf-8").read() == _text)
    with open(_settings, "w", encoding="utf-8") as _f:
        _f.write('{\n  "a": "{ 字符串里的括号 }"\n}')
    remotessh.ensure_platform("vm", "linux")
    check("没有这一项：加在最前面，字符串里的括号不干扰",
          remotessh._parse_jsonc(open(_settings, encoding="utf-8").read()) == {"remote.SSH.remotePlatform": {"vm": "linux"}, "a": "{ 字符串里的括号 }"})
    with open(_settings, "w", encoding="utf-8") as _f:
        _f.write('{ "a": ')
    remotessh.ensure_platform("vm2", "linux")
    check("设置文件看不懂：不碰", open(_settings, encoding="utf-8").read() == '{ "a": ')
    remotessh.config.IS_WINDOWS = False
    os.remove(_settings)
    remotessh.ensure_platform("vm", "linux")
    check("Mac / Linux 不写（Remote-SSH 自动识别远端系统）", not os.path.exists(_settings))
finally:
    remotessh._settings_path, remotessh.config.IS_WINDOWS = _orig_path, _orig_win

print("== Claude Code 扩展的链接免确认（extensions.confirmedUriHandlerExtensionIds）")
_key = remotessh.TRUST_KEY


def _ids(text):
    return (remotessh._parse_jsonc(text) or {}).get(_key) if text is not None else None


check("空文件：新建", _ids(remotessh.adding_claude_trust("")) == ["anthropic.claude-code"])
check("空对象", remotessh.adding_claude_trust("{}") == '{\n    "%s": ["anthropic.claude-code"]\n}' % _key)
_text = remotessh.adding_claude_trust('{\n  // 注释 { [\n  "a": "x // 不是注释 \\" [", /* 块注释 } */\n  "c": {"%s": []},\n}\n' % _key)
check("JSONC：插进根对象、注释原样保留", _ids(_text) == ["anthropic.claude-code"] and "// 注释 { [" in (_text or "")
      and "/* 块注释 } */" in (_text or "") and remotessh._parse_jsonc(_text)["c"] == {_key: []}, _text)
check("已有列表：插进去", _ids(remotessh.adding_claude_trust('{"%s": ["foo.bar"], "z": 1}' % _key)) == ["anthropic.claude-code", "foo.bar"])
check("已有空列表", _ids(remotessh.adding_claude_trust('{ "%s": [ ] }' % _key)) == ["anthropic.claude-code"])
check("列表里第一项是字符串 \"]\"：不当成空列表", _ids(remotessh.adding_claude_trust('{"%s": ["]"]}' % _key)) == ["anthropic.claude-code", "]"])
_same = '{ "%s": ["Anthropic.Claude-Code"] } // 已有' % _key
check("已经信任（大小写不同）：原文不动", remotessh.adding_claude_trust(_same) == _same)
check("这项不是列表：不碰", remotessh.adding_claude_trust('{"%s": "x"}' % _key) is None)
check("坏文件：不碰", remotessh.adding_claude_trust('{ "a": 1 "b": 2 }') is None)

_user = os.path.join(tempfile.mkdtemp(prefix="kl-vscode-"), "User")
os.makedirs(os.path.join(_user, "globalStorage"))
_settings = os.path.join(_user, "settings.json")
_orig = remotessh._settings_path, remotessh._vscode_user_dir
remotessh._settings_path, remotessh._vscode_user_dir = (lambda: _settings), (lambda: _user)
try:
    check("只查不写：没有设置文件时算未信任、也不建文件", not remotessh.claude_links_trusted() and not os.path.exists(_settings))
    check("没有设置文件：工作区信任按默认算开着", remotessh.workspace_trust_enabled())
    check("没有设置文件：新建并信任", remotessh.trust_claude_links() == (True, True)
          and _ids(open(_settings, encoding="utf-8").read()) == ["anthropic.claude-code"])
    check("只查不写：写过之后算已信任", remotessh.claude_links_trusted())
    check("第二次：已信任、不再写", remotessh.trust_claude_links() == (True, False))
    with open(_settings, "w", encoding="utf-8") as _f:
        _f.write('{ "a": ')
    check("设置文件看不懂：不碰、报未信任", remotessh.trust_claude_links() == (False, False)
          and open(_settings, encoding="utf-8").read() == '{ "a": ')
    import sqlite3
    _db = sqlite3.connect(os.path.join(_user, "globalStorage", "state.vscdb"))
    _db.execute("CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
    _db.execute("INSERT INTO ItemTable VALUES ('extensionUrlHandler.confirmedExtensions', '[\"anthropic.claude-code\"]')")
    _db.commit()
    _db.close()
    check("用户在框里勾过「不再询问」：算已信任、不碰设置", remotessh.trust_claude_links() == (True, False)
          and open(_settings, encoding="utf-8").read() == '{ "a": ')
    check("只查不写：勾过「不再询问」也算已信任", remotessh.claude_links_trusted())
    with open(_settings, "w", encoding="utf-8") as _f:
        _f.write('{\n  // 关掉了工作区信任\n  "security.workspace.trust.enabled": false,\n}')
    check("设置里关掉了工作区信任", not remotessh.workspace_trust_enabled())
    _missing = os.path.join(os.path.dirname(_user), "NoVSCode", "User")
    remotessh._settings_path, remotessh._vscode_user_dir = (lambda: os.path.join(_missing, "settings.json")), (lambda: _missing)
    check("没装 VS Code：不建目录", remotessh.trust_claude_links() == (False, False) and not os.path.exists(_missing))
finally:
    remotessh._settings_path, remotessh._vscode_user_dir = _orig

print("== 断线提醒（alerts.py）")
import threading  # noqa: E402
from kiteline import alerts  # noqa: E402


class _Src:
    def __init__(self, sid, name):
        self.id, self.name, self.state, self.state_detail = sid, name, "live", ""

    @property
    def live(self):
        return self.state == "live"


class _AlertApp:
    def __init__(self):
        self.store = type("S", (), {"lock": threading.Lock(), "sources": {}})()
        self.calls, self.restarted = [], []
        self.server = type("V", (), {"notify_alert": lambda _s, *a, **_k: self.calls.append(a), "publish_state": lambda _s: None})()

    def reconnect_sources(self, sid):
        self.restarted.append(sid)


_aapp = _AlertApp()
_vm, _off = _Src("ssh:vm", "虚拟机"), _Src("ssh:off", "关着的")
_off.state = "failed"
_aapp.store.sources = {_vm.id: _vm, _off.id: _off}
_alerts = alerts.Alerts(_aapp)
_alerts.tick(1000)
_vm.state, _vm.state_detail = "failed", "Host is down"
_alerts.tick(1010)
check("断开不到一分钟不提醒", _alerts.payload() == [])
_alerts.tick(1071)
_p = _alerts.payload()
check("断开一分钟：列表里有提示、带尝试重连、带原因", len(_p) == 1 and _p[0]["id"] == "lssh:vm" and _p[0]["actions"] == ["reconnect"]
      and "Host is down" in _p[0]["text"], str(_p))
check("推了「连接已断开」；从没连上过的机器不提醒", [(c[1], c[2]) for c in _aapp.calls] == [("虚拟机", "连接已断开")], str(_aapp.calls))
check("尝试重连：立即重连这台机器", _alerts.reconnect("lssh:vm")[0] and _aapp.restarted == ["ssh:vm"])
_vm.state = "stopped"
_alerts.tick(1072)
check("重连那一下是 stopped，提示照留", len(_alerts.payload()) == 1)
_vm.state = "live"
_alerts.tick(1080)
check("连回来：提示撤掉、推「已重新连上」", _alerts.payload() == [] and _aapp.calls[-1][2] == "已重新连上", str(_aapp.calls[-1]))
_vm.state = "stopped"
_alerts.tick(1200)
_alerts.tick(1300)
check("用户停掉的不算断线", _alerts.payload() == [])
check("对话框已关时点重连：如实说", _alerts.reconnect("d123-abc") == (False, "电脑上的这个对话框已经关闭"))
check("提示已消失时点重连：如实说", _alerts.reconnect("xyz") == (False, "电脑上的这个提示已经消失"))
check("按钮名去掉助记符和省略号", alerts.plain("重新加载窗口(&R)") == "重新加载窗口" and alerts.plain("More Actions...") == "more actions"
      and alerts.plain("Reload &Window") == "reload window")
check("对话框文字拼成一句（中文句子之间不空格）", alerts.sentence(["Workspace does not exist", "Please select another workspace to open."])
      == "Workspace does not exist. Please select another workspace to open" and alerts.sentence(["工作区不存在", "请选择另一个工作区以打开。"]) == "工作区不存在。请选择另一个工作区以打开")

print("== Linux 读 VS Code 弹框（alerts.py + atspi_linux / vscode_a11y，界面读取和配套扩展用假的）")
from kiteline import atspi_linux, bridge, config, vscode_a11y  # noqa: E402

_saved = (config.IS_LINUX, config.IS_WINDOWS, vscode_a11y.enabled, atspi_linux.dialogs, atspi_linux.press, bridge.windows, alerts.linux_idle_seconds)
_open = [{"pid": 7, "frame": "proj [SSH: dev] - Visual Studio Code", "texts": ["Workspace does not exist", "Please select another workspace to open."],
          "buttons": ["Open Workspace...", "Cancel"], "panel": False}]
_pressed, _reloaded = [], []


class _FakeWindow:
    def __init__(self, folders, remote):
        self.state = {"folders": folders, "remote": remote}

    def call(self, cmd, **_args):
        _reloaded.append((self.state["folders"][0], cmd))
        return {"ok": True}


def _fake_press(frame, texts, button):
    _pressed.append((frame, button))
    _open.clear()
    return True


try:
    config.IS_LINUX, config.IS_WINDOWS = True, False
    vscode_a11y.enabled = lambda: True
    atspi_linux.dialogs = lambda: [dict(d) for d in _open]
    atspi_linux.press = _fake_press
    bridge.windows = lambda: [_FakeWindow(["/home/me/proj"], "ssh-remote"), _FakeWindow(["/home/me/proj"], None)]
    alerts.linux_idle_seconds = lambda: 999
    _la = alerts.Alerts(_AlertApp())
    _la.tick(2000)
    check("对话框刚出来（不到 4 秒）不提醒", _la.payload() == [])
    _la.tick(2005)
    _p = _la.payload()
    check("挂满 4 秒：列出提示，远端窗口「工作区不存在」可以尝试重连", len(_p) == 1 and _p[0]["kind"] == "dialog" and _p[0]["title"] == "proj [SSH: dev]"
          and _p[0]["actions"] == ["reconnect"] and _p[0]["text"] == "Workspace does not exist. Please select another workspace to open", str(_p))
    check("人不在电脑前：推送一次", [c[0] for c in _la.app.calls] == ["editor"], str(_la.app.calls))
    _ok, _msg = _la.reconnect(_p[0]["id"])
    check("尝试重连：按 Cancel，再经配套扩展重新加载远端那个窗口（同名的本地窗口不动）",
          _ok and _pressed == [("proj [SSH: dev] - Visual Studio Code", "Cancel")] and _reloaded == [("/home/me/proj", "reload")], "%s %s %s" % (_msg, _pressed, _reloaded))
    _la.tick(2010)
    check("框关了：提示撤掉", _la.payload() == [])
    _frame = "proj [SSH: dev] - Visual Studio Code"
    _preview = {"pid": 7, "frame": _frame, "texts": ["是否要 Code 打开外部网站?", "https://claude.ai/artifact/6vw4wi3X?via=auto_preview"],
                "buttons": ["打开", "复制", "配置受信任的域", "取消"], "panel": False}
    _open[:], _pressed[:], _pushed = [dict(_preview)], [], len(_la.app.calls)
    _la.tick(2011)
    check("Artifact 自动预览的「打开外部网站」框：一出来就按「取消」，不提示、不推送",
          _pressed == [(_frame, "取消")] and _la.payload() == [] and len(_la.app.calls) == _pushed, "%s %s" % (_pressed, _la.payload()))
    _open[:], _pressed[:] = [dict(_preview, texts=["Do you want Code to open the external website?", "https://claude.ai/code/artifact/0b7c9e2a"],
                                  buttons=["Open", "Copy", "Configure Trusted Domains", "Cancel"])], []
    _la.tick(2012)
    check("会话里手动点的 Artifact 链接（不带 via=auto_preview）：也取消", _pressed == [(_frame, "Cancel")] and _la.payload() == [], "%s %s" % (_pressed, _la.payload()))
    _open[:], _pressed[:] = [dict(_preview, texts=["是否要 Code 打开外部网站?", "https://claude.ai/oauth/authorize?code=true&client_id=x"])], []
    _la.tick(2013)
    _la.tick(2018)
    check("登录等别的 claude.ai 链接：不替用户取消，照常提示", _pressed == [] and len(_la.payload()) == 1, "%s %s" % (_pressed, _la.payload()))
    _open[:], _pressed[:] = [dict(_preview)], []
    check("投递前：Artifact 链接的框先取消、等它关上", alerts.cancel_artifact_dialogs() and _pressed == [(_frame, "取消")], str(_pressed))
    check("投递前：没有这种框什么也不做", not alerts.cancel_artifact_dialogs())
    check("认 Artifact 链接：被截成「?...尾巴」的也认（截的只是问号后面），别的网站、别的 claude.ai 页面不认",
          alerts.artifact_link("https://claude.ai/artifact/6vw4wi3XTp4SdD91y91vHg?...to_preview")
          and alerts.artifact_link(" https://claude.ai/code/artifact/0b7c9e2a-5f1d-4c3b-9a8e-7d6f5e4c3b2a?...view ")
          and not alerts.artifact_link("https://example.com/artifact/abc")
          and not alerts.artifact_link("https://claude.ai.evil.com/artifact/abc")
          and not alerts.artifact_link("https://claude.ai/settings/usage")
          and not alerts.artifact_link("是否要 Code 打开外部网站?"))
    check("没开启「读取 VS Code 弹框」：不读", (setattr(vscode_a11y, "enabled", lambda: False), alerts.open_dialogs())[1] is None)
finally:
    (config.IS_LINUX, config.IS_WINDOWS, vscode_a11y.enabled, atspi_linux.dialogs, atspi_linux.press, bridge.windows, alerts.linux_idle_seconds) = _saved

_run = alerts.subprocess.run
try:
    alerts.subprocess.run = lambda *a, **k: type("R", (), {"stdout": b"(uint64 124159,)\n"})()
    check("Linux 空闲时间：读 Mutter 回的毫秒数（别把 uint64 里的 64 当成数）", alerts.linux_idle_seconds() == 124.159)
finally:
    alerts.subprocess.run = _run

_desk = ("[Desktop Entry]\nName=Visual Studio Code\nExec=/usr/share/code/code %F\nType=Application\n\n"
         "[Desktop Action new-empty-window]\nExec=env FOO=1 /usr/share/code/code --new-window %F\n")
_once = vscode_a11y._with_env(_desk)
check("启动项：每条 Exec 前加 ACCESSIBILITY_ENABLED=1（原有的 env 合并）、加一行标记",
      "Exec=env ACCESSIBILITY_ENABLED=1 /usr/share/code/code %F" in _once and "Exec=env ACCESSIBILITY_ENABLED=1 FOO=1 /usr/share/code/code --new-window %F" in _once
      and _once.count(vscode_a11y.MARK) == 1, _once)
check("启动项：再开启一次不重复加", vscode_a11y._with_env(_once) == _once)
check("设置：空文件写成只有这一项", vscode_a11y._adding("", "window.dialogStyle", "custom") == '{\n    "window.dialogStyle": "custom"\n}\n')
_jsonc = '// 我的设置\n{\n    "editor.fontSize": 14, // 字号\n}\n'
_added = vscode_a11y._adding(_jsonc, "window.dialogStyle", "custom")
check("设置：加在最外层、注释和别的设置原样保留", _added.startswith("// 我的设置\n{\n    \"window.dialogStyle\": \"custom\",") and "// 字号" in _added
      and remotessh._parse_jsonc(_added) == {"window.dialogStyle": "custom", "editor.fontSize": 14}, _added)
check("设置：空对象里加", remotessh._parse_jsonc(vscode_a11y._adding("{}", "a", "b")) == {"a": "b"})

print("== 闲置会话自动关闭（idleclose）")
import threading as _threading  # noqa: E402
from kiteline import delivery as _delivery, idleclose  # noqa: E402
from kiteline.store import Record as _IcRecord  # noqa: E402


class _IcStore:
    def __init__(self):
        self.lock = _threading.RLock()
        self.records = []

    def record(self, key):
        return next((r for r in self.records if r.key == key), None)

    def source(self, _id):
        return None


class _IcApp:
    def __init__(self):
        self.store = _IcStore()
        self.cfg = type("C", (), {"mobile": {"autoCloseIdle": True}})()
        self.server = type("S", (), {"siblings": staticmethod(lambda r: 0)})()
        self.audit = type("A", (), {"note": staticmethod(lambda *a: None)})()
        self.unmarked = []
        self.set_marked = lambda key, on: self.unmarked.append(key)


def _ic_rec(sid, activity="idle", **extra):
    return _IcRecord("local", "本机", "local", dict({"sessionId": sid, "name": sid, "activity": activity, "entrypoint": "claude-vscode"}, **extra))


_ic_closed, _ic_outcome = [], [True]
_ic_saved = (_delivery.close, idleclose.user_idle)
_delivery.close = lambda record, source, siblings: (_ic_closed.append(record.key), _delivery.Outcome(_ic_outcome[0], False, "x"))[1]
_ic_away = [10_000.0]
idleclose.user_idle = lambda: _ic_away[0]


def _ic_tick(ic, now, force=False):
    del _ic_closed[:]
    ic._last_tick = 0   # 每 5 分钟才真看一次：测试里直接看
    ic.tick(now, force=force)
    for _ in range(100):
        if not ic._closing:
            break
        import time as _t
        _t.sleep(0.02)
    return sorted(k.split("#")[1] for k in _ic_closed)


_ica = _IcApp()
_ic = idleclose.IdleClose(_ica)
_t0 = 1_800_000_000.0
_ica.store.records = [_ic_rec("a"), _ic_rec("b"), _ic_rec("busy", "busy"), _ic_rec("ro", readOnly=True), _ic_rec("codex", agent="codex", caps=[])]
_ic.store_updated(_t0)
check("新出现的会话从第一次见到起算", _ic.idle("local#a", _t0 + 60) == 60)
_ic.touch(["local#b"], _t0 + 3600)
check("23 小时：都不关", _ic_tick(_ic, _t0 + 23 * 3600) == [])
check("24 小时没打开的关；打开过的、正在跑的、只读的、不能关的（caps 没 close）不关", _ic_tick(_ic, _t0 + 24 * 3600 + 10) == ["a"])
check("关掉了取消标记", "local#a" in _ica.unmarked)
_ic_away[0] = 30
check("人在用电脑（10 分钟内动过键鼠）：要切 VS Code 的先不关", _ic_tick(_ic, _t0 + 25 * 3600 + 20) == [])
_ic_away[0] = 10_000.0
_ica.store.records = [r for r in _ica.store.records if r.key != "local#a"]
_ic.store_updated(_t0 + 25 * 3600 + 30)
_ic.lost([_ic_rec("a")], _t0 + 25 * 3600 + 30)
_ica.store.records.append(_ic_rec("a"))
_ic.store_updated(_t0 + 25 * 3600 + 30 + idleclose.REGONE + 1)
check("关掉 10 分钟以上又出现的（在 VS Code 里自己恢复）重新起算，不马上又关", _ic.idle("local#a", _t0 + 25 * 3600 + 30 + idleclose.REGONE + 1) == 0)
_ic_outcome[0] = False
check("关不掉的记下", _ic_tick(_ic, _t0 + 25 * 3600 + 40) == ["b"])
check("关不掉的 2 小时内不再试", _ic_tick(_ic, _t0 + 25 * 3600 + 50) == [])
_ic_outcome[0] = True
_ica.cfg.mobile["autoCloseIdle"] = False
check("设置里关掉就不关", _ic_tick(_ic, _t0 + 30 * 3600, force=True) == [])
_ica.cfg.mobile["autoCloseIdle"] = True
_ic2 = idleclose.IdleClose(_ica)
check("打开记录存盘、重启后还在（不会重启一次就从头算）", _ic2.idle("local#b", _t0 + 3600 + 5) == 5)
# 1.0.20 存的是一张表；各端启动时报来本机历史（最后看过），补上升级前的
import json as _json  # noqa: E402  （上面的只在 Linux 分支里导入）
with open(_ic.path, "w", encoding="utf-8") as _f:
    _json.dump({"local#a": _t0 * 1000, "local#b": (_t0 + 30) * 1000, "local#c": (_t0 + 5 * 3600) * 1000}, _f)
_ic3 = idleclose.IdleClose(_ica)
check("旧版存的一张表：装上那一刻一起记下的算第一次见到，之后的算打开过", _ic3.opened_keys() == ["local#c"], str(_ic3.opened_keys()))
_ic3.merge({"local#a": (_t0 - 30 * 3600) * 1000, "local#c": (_t0 - 30 * 3600) * 1000, "local#zz": _t0 * 1000, "local#b": "x"}, _t0 + 6 * 3600)
check("报来的历史：只记了第一次见到的按历史算（升级前 30 小时前看过的不用再等 24 小时）", _ic3.idle("local#a", _t0) == 30 * 3600)
check("报来的历史不把打开过的往回挪", _ic3.idle("local#c", _t0 + 6 * 3600) == 3600)
check("不认识的会话、坏数据不收", "local#zz" not in _ic3.opened_keys() and _ic3.idle("local#b", _t0 + 30) == 0)
check("新格式存盘、重启后还在", idleclose.IdleClose(_ica).idle("local#a", _t0) == 30 * 3600)
_delivery.close, idleclose.user_idle = _ic_saved

print("== 新版本提醒：自动弹窗（到期才弹、不再提示）、落后各版本说明、手机端版本、手机看电脑的更新")
import http.server as _uh_http  # noqa: E402
import json as _uh_json  # noqa: E402
import threading as _uh_threading  # noqa: E402
import time as _uh_time  # noqa: E402
from kiteline import config as _uh_config, updater as _uh  # noqa: E402

_uh_files = {}


class _UhHandler(_uh_http.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        body = _uh_files.get(self.path.split("?")[0])
        self.send_response(200 if body is not None else 404)
        self.end_headers()
        if body is not None:
            self.wfile.write(_uh_json.dumps(body, ensure_ascii=False).encode("utf-8"))

    def log_message(self, *args):
        pass


_uh_server = _uh_http.ThreadingHTTPServer(("127.0.0.1", 0), _UhHandler)
_uh_threading.Thread(target=_uh_server.serve_forever, daemon=True).start()
_uh_base = "http://127.0.0.1:%d" % _uh_server.server_port
_uh_plat = "windows" if _uh_config.IS_WINDOWS else "linux"


def _uh_publish(version):
    _uh_files["/download/latest.json"] = {"platforms": {_uh_plat: {
        "version": version, "url": _uh_base + "/download/k.zip", "size": 10, "sha256": "", "notes": "新功能\n· 最新一版", "notesEn": "New\n· Latest",
        "versions": [version, "1.0.21", "1.0.20", "1.0.19", "1.0.18"]}}}


_uh_publish("1.0.21")
_uh_files["/download/notes-desktop.json"] = {"releases": [
    {"version": "1.0.21", "date": "2026-11-02", "notes": "· 二十一", "notesEn": "· twenty-one"},
    {"version": "1.0.20", "date": "2026-11-01", "notes": "· 二十", "notesEn": "· twenty"},
    {"version": "1.0.19", "date": "2026-10-31", "notes": "· 十九（这台已经装了）", "notesEn": ""}]}
_uh_files["/lookup"] = {"resultCount": 1, "results": [{"version": "1.7", "releaseNotes": "· 手机新版", "minimumOsVersion": "18.0"}]}
os.environ["KITELINE_UPDATE_URL"] = _uh_base + "/download/latest.json"
os.environ["KITELINE_STORE_LOOKUP"] = _uh_base + "/lookup"
_uh_now = _uh_time.time() * 1000


class _UhDevices:
    all = [{"name": "旧 iPhone", "client": "ios/1.5 (iPhone13,2; iOS 18.7.8)", "lastSeen": _uh_now},
           {"name": "新 iPad", "client": "ios/1.7 (iPad8,1; iOS 26.5)", "lastSeen": _uh_now},
           {"name": "开发版", "client": "ios/1.8 (iPhone17,1; iOS 26.0)", "lastSeen": _uh_now},
           {"name": "系统太旧", "client": "ios/1.5 (iPhone9,1; iOS 17.6)", "lastSeen": _uh_now},
           {"name": "一个月没用", "client": "ios/1.5 (iPhone13,2; iOS 18.7.8)", "lastSeen": _uh_now - 40 * 86_400_000},
           {"name": "Mac 上的", "client": "mac/1.5 (Mac15,1; macOS 26.0)", "lastSeen": _uh_now},
           {"name": "旧版 App", "lastSeen": _uh_now}]


class _UhApp:
    version = "1.0.19"
    cfg = _uh_config.Config()
    devices = _UhDevices()
    on_update_change = None

    def request_exit(self):
        pass


_uh_app = _UhApp()
_uh_u = _uh.Updater(_uh_app)


def _uh_settle():
    for _ in range(50):
        if _uh_u.history and _uh_u.phones is not None:
            return
        _uh_time.sleep(0.1)


_uh_u.check()
_uh_settle()
_st = _uh_u.state()
check("发现新版本、该弹窗", _st["phase"] == "available" and _st["version"] == "1.0.21" and _st["prompt"] and not _st["skipped"], str(_st))
check("落后 2 个版本（latest.json 的 versions 里比这台新的）", _st["behind"] == 2, str(_st["behind"]))
check("各版本说明：只列比这台新的、新的在前", [r["version"] for r in _st["releases"]] == ["1.0.21", "1.0.20"], str(_st["releases"]))
_ph = _st.get("phones") or {}
check("手机端：只列最近用过、系统装得上、比 App Store 旧的 iPhone / iPad",
      [d["name"] for d in _ph.get("devices", [])] == ["旧 iPhone"] and _ph.get("version") == "1.7" and _ph.get("prompt"), str(_ph))
_uh_u.mark_shown(_st["key"])
check("弹过以后 24 小时内不再自动弹", not _uh_u.state()["prompt"])
_uh_app.cfg.update(lambda d: d["mobile"]["updateSnoozed"].update({_st["key"]: _uh_time.time() - 1}))
check("过了 24 小时再弹", _uh_u.state()["prompt"])
_uh_u.set_skipped(_st["key"], True)
check("勾了「此版本不再提示」就不弹、记得勾过", not _uh_u.state()["prompt"] and _uh_u.state()["skipped"])
check("「不再提示」存进配置、重启后还在", _st["key"] in (_uh_config.Config().mobile.get("updateSkipped") or []))
_uh_u.set_skipped(_st["key"], False)
check("取消勾选又会弹", _uh_u.state()["prompt"])
_uh_u.set_skipped(_st["key"], True)
_uh_publish("1.0.22")
_uh_u.check()
_st2 = _uh_u.state()
check("又出了新版本：照样弹（不再提示只管那一个版本）", _st2["version"] == "1.0.22" and _st2["prompt"] and not _st2["skipped"], str(_st2))
_hp = _uh_u.host_payload()
check("手机看电脑的更新：两种语言的说明都给、不带客户端自己用的字段",
      _hp["notes"] == "新功能\n· 最新一版" and _hp["notesEn"] == "New\n· Latest" and "phones" not in _hp and "prompt" not in _hp and _hp["current"] == "1.0.19", str(_hp))
_rs = _uh_u.remote("start")
check("开发版：手机上点更新说明原因、不装", _rs["ok"] is False and "官网" in _rs["error"] and _uh_u.phase == "available", str(_rs))
check("手机上点了不认识的操作", _uh_u.remote("rm -rf")["ok"] is False)
_uh_app.devices.all = [d for d in _UhDevices.all if d["name"] != "旧 iPhone"]
_uh_u._evaluate_phones()
check("手机升级了：手机端提醒收起", "phones" not in _uh_u.state())
_uh_server.shutdown()
del os.environ["KITELINE_UPDATE_URL"], os.environ["KITELINE_STORE_LOOKUP"]

print("== 别的会话来信引起的那一轮答完不提醒（store）")
from kiteline.store import Store as _Store  # noqa: E402

_sn_calls = []
_sn = _Store({}, lambda: None, lambda record, kind, text: _sn_calls.append((kind, text)))
_sn_src = type("Src", (), {"id": "local", "name": "本机", "kind": "local", "config": {}})()


def _sn_apply(activity, uuid, message, **extra):
    _sn.apply_snapshots(_sn_src, [dict({"sessionId": "s1", "name": "s1", "activity": activity, "message": message, "messageUuid": uuid}, **extra)])


_sn_apply("idle", "m0", "旧结论")
_sn_apply("busy", "m0", "旧结论", turnFrom="user")
_sn_apply("idle", "m1", "首页改好了", turnFrom="user")
check("你发起的一轮答完：照常提醒", _sn_calls == [("conclusion", "首页改好了")], str(_sn_calls))
del _sn_calls[:]
_sn_apply("busy", "m1", "首页改好了", turnFrom="peer")
_sn_apply("idle", "m2", "已回复 ccpulse-67：可以拍快照了", turnFrom="peer")
check("别的会话来信那一轮答完：不提醒", _sn_calls == [], str(_sn_calls))
_sn._last_conclusion.clear()   # 过了冷却（同一会话 20 秒内只提醒一次）
_sn_apply("idle", "m3", "Claude 用量已达上限", turnFrom="peer", error={"kind": "limit", "text": "Claude 用量已达上限"})
check("来信那一轮出错停下：照样提醒", [k for k, _ in _sn_calls] == ["conclusion"], str(_sn_calls))
del _sn_calls[:]
_sn._last_conclusion.clear()   # 过了冷却
_sn_apply("idle", "m4", "又改好一处")
check("老 watcher 不带 turnFrom：照常提醒", _sn_calls == [("conclusion", "又改好一处")], str(_sn_calls))

print("== 目标（/goal）：每一轮停下不提醒，达成、做不到、停下时提醒一次（store）")
from kiteline.store import caps_payload as _caps, goal_push_body as _goal_body  # noqa: E402

_goal = {"text": "测试全部通过", "state": "active", "checks": 1, "since": 1793610000000}
del _sn_calls[:]
_sn._last_conclusion.clear()
_sn_apply("busy", "m4", "又改好一处", goal=_goal)
_sn_apply("idle", "m5", "这一轮做完了", goal=_goal)
check("目标还在做：这一轮停下不提醒（Codex 一轮接一轮续做）", _sn_calls == [], str(_sn_calls))
_sn_apply("idle", "m5", "这一轮做完了", goal=dict(_goal, state="met", checks=3, turns=3, durationMs=720000, reason="全部通过"))
check("目标达成：提醒一次（kind goal，带着目标）", [(k, t.get("state")) for k, t in _sn_calls] == [("goal", "met")], str(_sn_calls))
_sn_apply("idle", "m5", "这一轮做完了", goal=dict(_goal, state="met", checks=3, turns=3, durationMs=720000, reason="全部通过"))
check("状态没变：不再提醒", len(_sn_calls) == 1, str(_sn_calls))
del _sn_calls[:]
_sn_apply("busy", "m5", "x", goal=dict(_goal, text="迁移数据"))
_sn_apply("idle", "m6", "停在第 2 步", goal=dict(_goal, text="迁移数据", state="paused", note="目标检查超时"))
check("目标停下：提醒（结论那条不再另推）", [k for k, _ in _sn_calls] == ["goal"], str(_sn_calls))
met = dict(_goal, state="met", checks=3, turns=3, durationMs=720000)
check("推送正文：目标 + 用了几轮、多久；英文那份按表换", _goal_body(met, False) == "目标：测试全部通过\n用了 3 轮 · 12 分钟"
      and _goal_body(met, True).startswith("Goal: 测试全部通过") and "3 turns" in _goal_body(met, True), _goal_body(met, True))
check("停下的正文写原因；没有原因提示发消息继续", _goal_body(dict(_goal, state="paused", note="目标检查超时"), False).endswith("目标检查超时")
      and _goal_body(dict(_goal, state="paused"), False).endswith("发送消息即可继续"))
check("Claude Code 2.1.139 起才给「目标」，别家看插件给的", "goal" in _caps({"version": "2.1.314"}) and "goal" not in _caps({"version": "2.1.120"})
      and "goal" not in _caps({"agent": "opencode"}) and _caps({"agent": "codex", "caps": ["goal", "goal-pause"]}) == ["goal", "goal-pause"])

print("== 插件变了换 watcher 进程：会话照旧显示、请求排队等新进程（LocalSource.restart）")
import time as _time  # noqa: E402
from kiteline import watcher as _wmod  # noqa: E402

_fake_dir = tempfile.mkdtemp(prefix="kl-fakewatch-")
_fake_ok = os.path.join(_fake_dir, "ok.py")
_fake_bad = os.path.join(_fake_dir, "bad.py")
with open(_fake_ok, "w", encoding="utf-8") as _h:
    _h.write("""import json, os, sys, threading, time
lock = threading.Lock()
def emit(obj):
    with lock:
        sys.stdout.write(json.dumps(obj) + "\\n"); sys.stdout.flush()
time.sleep(float(os.environ.get("FAKE_BOOT", "0.3")))
emit({"event": "hello", "watcher": "fake", "host": "fake", "home": "/tmp"})
def answer(req):
    if req.get("cmd") == "slow":
        time.sleep(1.0)
    emit({"event": "response", "id": req["id"], "ok": True, "pid": os.getpid()})
for line in sys.stdin:
    if line.strip():
        threading.Thread(target=answer, args=(json.loads(line),), daemon=True).start()
""")
with open(_fake_bad, "w", encoding="utf-8") as _h:
    _h.write("import sys, time\ntime.sleep(0.3)\nsys.stderr.write('坏了\\n')\nsys.exit(3)\n")

_states = []
_src = _wmod.LocalSource({"id": "local"}, lambda *_a: None, lambda src: _states.append(src.state))
_src._script = lambda: _fake_now[0]
_fake_now = [_fake_ok]
_wmod.RESTART_GRACE = 8


def _wait(cond, limit=10):
    end = _time.time() + limit
    while not cond() and _time.time() < end:
        _time.sleep(0.05)
    return cond()


_src.start()
check("起来了", _wait(lambda: _src.live), str(_states))
_pid1 = _src.request({"cmd": "ping"})["pid"]
_slow, _during = {}, {}
_t1 = threading.Thread(target=lambda: _slow.update(_src.request({"cmd": "slow"})))
_t1.start()
_time.sleep(0.2)
del _states[:]
_src.restart({"id": "local"})
_time.sleep(0.1)


def _ping_during():
    try:
        _during.update(_src.request({"cmd": "ping"}))
    except Exception as exc:  # noqa: BLE001
        _during["error"] = str(exc)


_t2 = threading.Thread(target=_ping_during)
_t2.start()
_t1.join(10)
_t2.join(15)
check("换之前手上的请求先答完（旧进程答的）", _slow.get("pid") == _pid1, str(_slow))
check("换进程期间的请求等新进程就绪再发", _during.get("pid") not in (None, _pid1), str(_during))
check("全程不报连接中 / 断线（会话照旧显示）", set(_states) <= {"live"}, str(_states))
check("换完照常可用", _src.request({"cmd": "ping"})["pid"] == _during.get("pid"))

# 新进程起不来：照常算断线、排队的请求不白等到期限
del _states[:]
_fake_now[0] = _fake_bad
_src.restart()
_t0 = _time.time()
try:
    _src.request({"cmd": "ping"}, timeout=20)
    _err = ""
except Exception as exc:  # noqa: BLE001
    _err = str(exc)
check("新进程起不来：请求报错、不白等（%.1f 秒）" % (_time.time() - _t0), _err and _time.time() - _t0 < 5, _err)
check("新进程起不来：照常报断线（会话清掉、退避重连）", _wait(lambda: "failed" in _states, 5), str(_states))
_src.stop()

# 等着重连的（起不来、过几秒再试）：restart 不多起进程，下次重连自然按新开关
_fake_now[0] = _fake_bad
_src2 = _wmod.LocalSource({"id": "local"}, lambda *_a: None, lambda src: None)
_src2._script = lambda: _fake_now[0]
_src2.start()
_wait(lambda: _src2.state == "failed", 5)
_fake_now[0] = _fake_ok
_src2.restart()
check("等着重连的 restart：到点重连上、只有一个进程", _wait(lambda: _src2.live, 15) and _src2.request({"cmd": "ping"}).get("ok")
      and not _src2._relaunch and _src2._proc.poll() is None)
_src2.stop()

# 还在连（进程起了、没报 hello）：照样换成新开关的进程
_src3 = _wmod.LocalSource({"id": "local"}, lambda *_a: None, lambda src: None)
_src3._script = lambda: _fake_ok
os.environ["FAKE_BOOT"] = "1.5"
_src3.start()
_wait(lambda: _src3._proc is not None, 5)
_first = _src3._proc
_src3.restart()
os.environ.pop("FAKE_BOOT")
check("还在连的 restart：换掉没就绪的进程、新进程连上", _wait(lambda: _src3.live, 15) and _src3._proc is not _first and _first.poll() is not None)
_src3.stop()

print("== 实时活动：开始、更新、划掉、结束（假网关）")
import http.server as _lv_http  # noqa: E402
import json as _lv_json  # noqa: E402
import threading as _lv_threading  # noqa: E402
import time as _lv_time  # noqa: E402

from kiteline import live as _live  # noqa: E402

_lv_posts = []
_lv_dead = set()


class _LvHandler(_lv_http.BaseHTTPRequestHandler):
    def do_POST(self):
        body = _lv_json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        _lv_posts.append(body)
        code = 410 if body.get("token") in _lv_dead else 200
        self.send_response(code)
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def log_message(self, *_):
        pass


_lv_server = _lv_http.ThreadingHTTPServer(("127.0.0.1", 0), _LvHandler)
_lv_threading.Thread(target=_lv_server.serve_forever, daemon=True).start()
_live.LIVE_GATEWAY = "http://127.0.0.1:%d/push/live" % _lv_server.server_address[1]
_T_START, _T_ACT, _T_EN = "a1" * 32, "b2" * 32, "c3" * 32


def _lv_take(count, timeout=5):
    deadline = _lv_time.time() + timeout
    while len(_lv_posts) < count and _lv_time.time() < deadline:
        _lv_time.sleep(0.05)
    _lv_time.sleep(0.15)
    taken = list(_lv_posts)
    del _lv_posts[:]
    return taken


lv = _live.LiveActivities("测试电脑")
lv.register("d1", {"enabled": True, "env": "development", "lang": "zh", "startToken": _T_START})
_busy = {"key": "local#s1", "title": "修复订单导出", "activity": "busy", "updatedAt": 2,
         "stage": {"step": 2, "total": 4, "label": "开发中"}}
lv.update([_busy])
_posts = _lv_take(1)
_start = _posts[0] if _posts else {}
_item = (_start.get("state") or {}).get("items", [{}])[0]
check("开始干活：用推送启动令牌开一个", len(_posts) == 1 and _start.get("event") == "start" and _start.get("token") == _T_START
      and _start.get("env") == "development" and _start.get("attributes") == {"host": "测试电脑"} and _start.get("urgency") == "high", _posts)
check("内容：标题、进行中、阶段", _item.get("t") == "修复订单导出" and _item.get("s") == "busy" and _item.get("l") == "进行中"
      and _item.get("d") == "2/4 开发中" and _start["state"].get("head") == "1 个进行中" and _start.get("alert", {}).get("title") == "修复订单导出", _item)
lv.update([dict(_busy, updatedAt=3)])
check("内容没变不重复发、同一轮不再开", _lv_take(0, 0.5) == [])

lv.register("d1", {"enabled": True, "env": "development", "lang": "zh", "startToken": _T_START, "activities": [{"id": "act1", "token": _T_ACT}]})
_posts = _lv_take(1)
check("App 报了实时活动的令牌：马上补一份更新", len(_posts) == 1 and _posts[0].get("event") == "update" and _posts[0].get("token") == _T_ACT, _posts)
# 等批命令：电脑给的说明是笼统的「请求权限确认」，锁屏上要写出是哪条命令
_wait = dict(_busy, activity="waiting", blocking="请求权限确认", pendingTool="Bash", activityText="Bash: npm install", updatedAt=4)
lv.update([_wait])
_posts = _lv_take(1)
_upd = _posts[0] if _posts else {}
_item = (_upd.get("state") or {}).get("items", [{}])[0]
check("变成等你确认：高优先级更新", _upd.get("urgency") == "high" and _upd["state"].get("waiting") == 1 and _item.get("l") == "待确认"
      and _item.get("d") == "Bash: npm install" and _upd["state"].get("head") == "1 个待确认", _posts)

lv.register("d1", {"enabled": True, "env": "development", "lang": "zh", "startToken": _T_START, "activities": [], "ended": "act1"})
lv._last_flush = 0
lv.update([dict(_busy, updatedAt=5)])
check("用户在锁屏上划掉：这一轮不再开", _lv_take(0, 0.5) == [] and lv._devices["d1"]["dismissedRound"] == lv._round)

lv.update([dict(_busy, activity="idle", updatedAt=6)])
lv._idle_since = _lv_time.time() - 100
lv._end_if_idle()
check("全部停下满 90 秒：这一轮结束", not lv._active and _lv_take(0, 0.5) == [])
lv.update([dict(_busy, title="第二个任务", updatedAt=7)])
_posts = _lv_take(1)
check("下一轮干活：又开一个", len(_posts) == 1 and _posts[0].get("event") == "start" and lv._round == 2, _posts)

lv.register("d1", {"enabled": True, "env": "development", "lang": "zh", "startToken": _T_START, "activities": [{"id": "act2", "token": _T_ACT}]})
_lv_take(1)
lv.update([dict(_busy, title="第二个任务", activity="idle", updatedAt=8)])
_lv_take(1)
lv._idle_since = _lv_time.time() - 100
lv._end_if_idle()
_posts = _lv_take(1)
_end = _posts[0] if _posts else {}
_items = (_end.get("state") or {}).get("items", [])
check("结束：全部完成、刚做完的标已完成、锁屏留一会儿", _end.get("event") == "end" and _end["state"].get("head") == "全部完成"
      and _items and _items[0].get("s") == "done" and _items[0].get("l") == "已完成" and _end.get("dismiss", 0) > _lv_time.time(), _posts)
check("结束后不再记着这个实时活动", lv._devices["d1"]["activities"] == {})

print("== 实时活动：英文、关掉、令牌失效")
lv2 = _live.LiveActivities("PC")
lv2.register("d2", {"enabled": True, "env": "production", "lang": "en", "startToken": _T_EN})
_lv_dead.add(_T_EN)
lv2.update([{"key": "k", "title": "Fix export", "activity": "waiting", "updatedAt": 1}])
_posts = _lv_take(1)
_st = (_posts[0] if _posts else {}).get("state") or {}
check("英文手机：英文的状态文字", _st.get("head") == "1 waiting" and _st.get("items", [{}])[0].get("l") == "Needs approval", _st)
_lv_time.sleep(0.3)
check("网关说令牌失效（410）：删掉推送启动令牌", lv2._devices["d2"].get("startToken") is None)
lv2.register("d2", {"enabled": False, "lang": "en"})
check("App 里关掉实时活动：令牌全清", lv2._devices["d2"].get("startToken") is None and lv2._devices["d2"]["activities"] == {})
lv2.forget("d2")
check("停用设备：登记一起删", "d2" not in lv2._devices)
check("登记存在配置目录、只有自己能读", os.path.exists(_live._path()) and (os.name == "nt" or (os.stat(_live._path()).st_mode & 0o077) == 0))
_lv_server.shutdown()

print("== 游客链接（局域网）：网址、页面、内容过滤、304、停止")
from kiteline import guest as _guest  # noqa: E402

_gl_items = [
    {"t": "user", "text": "修一下订单导出", "ts": 1},
    {"t": "thinking", "text": "（思考过程不该出去）"},
    {"t": "tool", "name": "Bash", "brief": "npm test", "ts": 2},
    {"t": "tool", "name": "TodoWrite", "brief": "清单"},
    {"t": "agent_key", "text": "密码：hunter2", "title": "测试账号"},
    {"t": "agent_image", "images": [{"ref": "a"}, {"ref": "b"}]},
    {"t": "text", "text": "已修好，测试全部通过。", "ts": 3},
]
_gl_calls = []


class _GlSource:
    def request(self, payload, timeout=30):
        _gl_calls.append(payload)
        return {"items": _gl_items, "hasMore": True}


class _GlStore:
    def resolve_any(self, key):
        return ("sess-1", _GlSource()) if key == "local#sess-1" else None


class _GlApp:
    store = _GlStore()
    activity = "busy"

    def state_payload(self):
        return {"sessions": [{"key": "local#sess-1", "title": "修复订单导出", "activity": self.activity, "cwd": "/work/shop-app", "agent": "claude-code", "updatedAt": 5}]}


_gl_app = _GlApp()
gl = _guest.GuestLinks(_gl_app)
_share = gl.create("local#sess-1", 24)
_url = _guest.url_of(_share, 8765)
check("局域网网址：http://<局域网 IP>:<端口>/g/<22 位编号>", _url.startswith("http://") and _url.endswith(":8765/g/" + _share["id"]) and len(_share["id"]) == 22, _url)
_st, _hd, _body = gl.serve("/g/" + _share["id"])
check("页面：不要令牌、只连这台电脑、不让嵌入、不进搜索", _st == 200 and b"/g/api/" in _body and "connect-src 'self'" in _hd["Content-Security-Policy"]
      and "frame-ancestors 'none'" in _hd["Content-Security-Policy"] and _hd.get("X-Robots-Tag") and b"tars.betac.cn" not in _body, (_st, _hd))
_st, _hd, _body = gl.serve("/g/api/" + _share["id"])
_snap = _lv_json.loads(_body or b"{}")
_kinds = [r.get("r") for r in _snap.get("items", [])]
check("内容：对话、步骤、图片张数；不含思考过程、关键信息、任务清单", _st == 200 and _kinds == ["u", "s", "i", "a"] and _snap["items"][1]["x"] == "Bash · npm test"
      and _snap["items"][2]["n"] == 2 and "hunter2" not in _body.decode() and "思考" not in _body.decode(), _snap)
check("内容带状态、项目名、agent、还有更早的", _snap.get("status") == "busy" and _snap.get("project") == "shop-app" and _snap.get("agent") == "Claude Code" and _snap.get("more") is True, _snap)
_calls = len(_gl_calls)
_st2, _hd2, _ = gl.serve("/g/api/" + _share["id"], _hd.get("ETag"))
check("没变化：回 304、不再去取记录", _st2 == 304 and len(_gl_calls) == _calls, _st2)
_gl_app.activity = "idle"
_st3, _hd3, _body3 = gl.serve("/g/api/" + _share["id"], _hd.get("ETag"))
check("会话有进展：ETag 变了、内容是新的", _st3 == 200 and _hd3["ETag"] != _hd["ETag"] and _lv_json.loads(_body3)["status"] == "idle")
check("列出这个会话正在分享的网址", [x["id"] for x in gl.list("local#sess-1")] == [_share["id"]] and gl.list("local#other") == [])
check("编错的编号拿不到内容", gl.serve("/g/api/AAAAAAAAAAAAAAAAAAAAAA")[0] == 404 and gl.serve("/g/x/y/z")[0] == 404)
gl.stop(_share["id"])
check("停止分享：网址马上失效", gl.serve("/g/api/" + _share["id"])[0] == 404 and gl.list() == [])
check("有效期只能 1 / 24 / 168 小时", gl.create("local#sess-1", 5) is None)
_old = gl.create("local#sess-1", 1)
gl._shares[-1]["expires"] = _lv_time.time() - 1
check("到期：网址失效", gl.serve("/g/api/" + _old["id"])[0] == 404)

print("== 游客链接（局域网）：单独的游客端口只给 /g/，没分享就关")
import socket as _gl_socket  # noqa: E402
import urllib.error as _gl_uerr  # noqa: E402
import urllib.request as _gl_ureq  # noqa: E402

with _gl_socket.socket() as _probe:
    _probe.bind(("127.0.0.1", 0))
    _free = _probe.getsockname()[1]


class _GlCfg:
    mobile = {"port": _free - 2, "bindAddress": "127.0.0.1"}


_gl_app2 = _GlApp()
_gl_app2.cfg = _GlCfg()
gl2 = _guest.GuestLinks(_gl_app2)
gl2._shares = []
gl2.sync_listener()
check("没有分享：不开游客端口", gl2._listener is None)
_s2 = gl2.create("local#sess-1", 1)


def _gl_get(path):
    try:
        with _gl_ureq.urlopen("http://127.0.0.1:%d%s" % (_free, path), timeout=5) as r:
            return r.status, r.read()
    except _gl_uerr.HTTPError as e:
        return e.code, b""
    except OSError:
        return 0, b""


_code, _data = _gl_get("/g/api/" + _s2["id"])
check("有分享：游客端口（手机端口 + 2）能取到内容", _code == 200 and b"\"title\"" in _data and _guest.payload_of(_s2, _guest.guest_port(_gl_app2))["url"].endswith(":%d/g/%s" % (_free, _s2["id"])), _code)
check("游客端口不给别的接口", _gl_get("/api/state")[0] == 404 and _gl_get("/")[0] == 404)
gl2.stop(_s2["id"])
check("停止最后一个分享：游客端口关掉", gl2._listener is None and _gl_get("/g/api/" + _s2["id"])[0] == 0)

print("== 后台送达：装了 kiteline mod 的会话不切前台（delivery.via_bridge）")


class _BrSource:
    def __init__(self, reply):
        self.reply, self.calls = reply, []

    def request(self, payload, timeout=30):
        self.calls.append(payload)
        return dict(self.reply) if payload.get("cmd") == "bridge" else {}


class _BrBackend:
    def __init__(self):
        self.calls = []

    def send_vscode(self, prompt, record, submit, siblings, check_waiting=True):
        self.calls.append(("send", prompt))
        return _delivery.Outcome(True, submit, "前台")

    def press_vscode(self, key, times, record, siblings):
        self.calls.append(("press", key))
        return _delivery.Outcome(True, False, "前台")


def _br_rec(activity="idle", bridge=True, sid="br-1", tool=None):
    return _IcRecord("local", "本机", "local", {"sessionId": sid, "name": sid, "title": "送达测试", "activity": activity,
                                              "entrypoint": "claude-vscode", "bridge": bridge, "pendingTool": tool})


_br_saved = (_delivery.DRY_RUN, _delivery.LOOKUP, _delivery._backend)
_br_front = _BrBackend()
_delivery.DRY_RUN, _delivery.LOOKUP, _delivery._backend = False, None, (lambda: _br_front)
try:
    src = _BrSource({"bridged": True, "result": "ok"})
    out = _delivery.send("你好", [], _br_rec(), src, True, 0)
    check("发消息：交给 mod（op send），不碰前台", out.ok and out["submitted"] and src.calls[-1] == {"op": "send", "text": "你好", "cmd": "bridge", "sessionId": "br-1"}
          and not _br_front.calls, (out, src.calls))
    out = _delivery.send("等确认时也能发", [], _br_rec("waiting"), src, True, 0)
    check("等确认时发：不按回车，排在确认之后（不再拒绝）", out.ok and src.calls[-1]["text"] == "等确认时也能发", out)
    out = _delivery.send("只填不提交", [], _br_rec(), src, False, 0)
    check("只填不提交：照旧走前台", out.ok and _br_front.calls == [("send", "只填不提交")], _br_front.calls)
    keys = {}
    for key, act in (("1", "waiting"), ("enter", "waiting"), ("2", "waiting"), ("esc", "waiting"), ("esc", "idle")):
        _delivery.press(key, 1, _br_rec(act), src, 0)
        keys[(key, act)] = {k: v for k, v in src.calls[-1].items() if k in ("op", "decision")}
    check("按键换成 mod 指令：1 / 回车 允许、2 本会话不再询问、等确认时 Esc 拒绝、空闲时 Esc 中断", keys == {
        ("1", "waiting"): {"op": "perm", "decision": "allow"}, ("enter", "waiting"): {"op": "perm", "decision": "allow"},
        ("2", "waiting"): {"op": "perm", "decision": "allow_session"}, ("esc", "waiting"): {"op": "perm", "decision": "deny"},
        ("esc", "idle"): {"op": "abort"}}, keys)
    _delivery.press("1", 1, _br_rec("waiting", tool="Bash"), src, 0)
    check("带上手机卡片对应的工具名，mod 按它找确认框", src.calls[-1].get("tool") == "Bash" and src.calls[-1]["decision"] == "allow", src.calls[-1])
    _br_front.calls.clear()
    out = _delivery.press("shift+tab", 1, _br_rec(), src, 0)
    check("mod 做不了的键（切权限模式）照旧按", _br_front.calls == [("press", "shift+tab")], _br_front.calls)
    out = _delivery.answer("A", _br_rec("waiting"), src, 0, [{"question": "用哪个？", "picked": ["A"], "other": "再加个日志"}, {"question": "空的", "picked": []}])
    check("回答提问：选项原样答给提问框（多选 / 自己写的用逗号连起来），不先按 Esc", out.ok and src.calls[-1]["op"] == "answer"
          and src.calls[-1]["answers"] == {"用哪个？": "A, 再加个日志"} and ("press", "esc") not in _br_front.calls, (out, src.calls[-1]))
    none = _BrSource({"bridged": True, "result": "none"})
    _br_front.calls.clear()
    out = _delivery.press("1", 1, _br_rec("waiting"), none, 0)
    check("mod 那边没有在等的确认框、会话还在等：是 mod 管不到的框，照旧按键", _br_front.calls == [("press", "1")], _br_front.calls)
    _delivery.LOOKUP = lambda key: _br_rec("idle")
    _br_front.calls.clear()
    out = _delivery.press("1", 1, _br_rec("waiting"), none, 0)
    check("确认框已在电脑上答过：不再按键（按下去会落进输入框）", not out.ok and "电脑上处理" in out["message"] and not _br_front.calls, out)
    _br_front.calls.clear()
    out = _delivery.press("2", 1, _br_rec("idle"), src, 0)
    check("卡片过期（会话已不在等确认）按了 2：不问 mod、也不按键", not out.ok and not _br_front.calls, out)
    _delivery.LOOKUP = None
    off = _BrSource({"bridged": False})
    _br_front.calls.clear()
    out = _delivery.send("没接上", [], _br_rec(), off, True, 0)
    check("mod 没接上：改走前台", out.ok and _br_front.calls == [("send", "没接上")], _br_front.calls)
    _br_front.calls.clear()
    out = _delivery.send("没接上又在等确认", [], _br_rec("waiting"), off, True, 0)
    check("没接上、Claude 又在等确认：照旧拦下（前台回车会替你点允许）", not out.ok and "等你确认" in out["message"] and not _br_front.calls, out)
    _br_front.calls.clear()
    asked = len(src.calls)
    out = _delivery.send("老会话", [], _br_rec(bridge=False), src, True, 0)
    check("没加载 mod 的会话：直接走前台，不问 watcher", _br_front.calls == [("send", "老会话")] and len(src.calls) == asked, src.calls[asked:])
finally:
    _delivery.DRY_RUN, _delivery.LOOKUP, _delivery._backend = _br_saved

print("== 后台托管会话（远端项目不开 VS Code）")
from kiteline import app as _app  # noqa: E402
from kiteline.store import Record as _Record  # noqa: E402


class _HostSource:
    """假的远端来源：hosted_start 按 reply 回（异常就抛），别的命令记下来回空"""
    kind, name, config, id, state = "ssh", "服务器", {"sshHost": "srv"}, "srv", "live"

    def __init__(self, reply, delay=0.0, features=("hosted",)):
        self.reply, self.delay, self.calls, self.features = reply, delay, [], set(features)

    def request(self, payload, timeout=30):
        self.calls.append(payload)
        if payload.get("cmd") == "hosted_start":
            time.sleep(self.delay)
            if isinstance(self.reply, Exception):
                raise self.reply
            return dict(self.reply)
        if payload.get("cmd") == "hosted_stop":
            return {"stopped": True}
        if payload.get("cmd") == "hosted_probe":
            return {"source": "vscode", "settings": {"HTTPS_PROXY": "http://***@127.0.0.1:7890"},
                    "egress": {"ip": "1.2.3.4", "country": "US", "site": "ipinfo.io"}}
        return {}


_hs_saved = (_delivery.DRY_RUN, _delivery.LOOKUP, _delivery._backend, _app.launch_session, _app.HOSTED_SETTING[0])
_hs_editor = []
_hs_real = _app.launch_session


def _hs_launch(*args, **kwargs):
    if kwargs.get("in_editor"):
        _hs_editor.append(args[:5])
        return {"ok": True, "submitted": False, "openedWindow": True, "message": "已在 VS Code 中新建会话", "error": "", "cwd": args[0]}
    return _hs_real(*args, **kwargs)


_br_front.calls.clear()
_delivery.DRY_RUN, _delivery.LOOKUP, _delivery._backend = False, None, (lambda: _br_front)
_app.launch_session = _hs_launch
_app.HOSTED_SETTING[0] = lambda source_id: source_id == "srv"
try:
    hosted_rec = _Record("srv", "服务器", "ssh", {"sessionId": "h-1", "name": "h-1", "activity": "idle", "entrypoint": "cli",
                                                "pid": 4321, "hosted": "abc123", "cwd": "/srv/p"})
    src = _HostSource({})
    out = _delivery.send("你好", [], hosted_rec, src, True, 0)
    check("发消息：交给 watcher 写进伪终端（tmux_send），不碰前台", out.ok and out["submitted"] and src.calls[-1] == {
        "cmd": "tmux_send", "pid": 4321, "text": "你好", "submit": True} and not _br_front.calls, (out, src.calls))
    out = _delivery.press("1", 1, hosted_rec, src, 0)
    check("按键同样经 watcher", out.ok and src.calls[-1] == {"cmd": "tmux_send", "pid": 4321, "keys": ["1"]}, src.calls[-1])
    src = _HostSource({"sessionId": "new-1", "hosted": "x1", "submitted": True})
    started = time.time()
    result = _app.launch_session("/srv/p", "做个功能", True, None, "ssh", "服务器", source=src)
    check("远端新任务：先在后台起，不开 VS Code", result["ok"] and result["submitted"] and "后台" in result["message"] and not _hs_editor
          and {k: v for k, v in src.calls[0].items() if k != "netEnv"} == {"cmd": "hosted_start", "cwd": "/srv/p", "prompt": "做个功能", "submit": True}
          and isinstance(src.calls[0].get("netEnv"), dict), (result, src.calls))
    check("起得快就直接回结果", time.time() - started < 3, time.time() - started)
    src = _HostSource({"sessionId": "old-1", "hosted": "x2", "submitted": False})
    result = _app.launch_session("/srv/p", "", False, "old-1", "ssh", "服务器", source=src)
    check("恢复：带上会话编号", result["ok"] and src.calls[0].get("sessionId") == "old-1" and result["message"] == "已在后台恢复对话", result)
    src = _HostSource(RuntimeError("HOSTED_UNSUPPORTED：这台电脑暂不支持在后台运行 Claude Code"))
    result = _app.launch_session("/srv/p", "做个功能", True, None, "ssh", "服务器", source=src)
    check("那台电脑不支持：悄悄改开 VS Code", _hs_editor and result["message"] == "已在 VS Code 中新建会话", (result, _hs_editor))
    _hs_editor.clear()
    src = _HostSource(RuntimeError("Claude Code 没有启动起来，停在了需要操作的画面上\nLogin method XYZ"))
    result = _app.launch_session("/srv/p", "做个功能", True, None, "ssh", "服务器", source=src)
    check("后台起不来：改开 VS Code，并说明原因", _hs_editor and "后台启动未成功：Claude Code 没有启动起来" in result["message"]
          and "XYZ" not in result["message"], result)   # 只带第一句，不带后面的画面
    _hs_editor.clear()
    notes = []
    src = _HostSource(RuntimeError("Claude Code 没有启动起来"), delay=9.5)
    result = _app.launch_session("/srv/p", "做个功能", True, None, "ssh", "服务器", source=src, notify=notes.append)
    check("起得慢：8 秒先回「将自动提交」", result["ok"] and result["submitted"] and "正在后台启动" in result["message"] and not _hs_editor, result)
    time.sleep(2.5)
    check("之后起不来再改开 VS Code", len(_hs_editor) == 1, _hs_editor)
    _hs_editor.clear()
    src = _HostSource({"sessionId": "x"})
    result = _app.launch_session("/local/p", "做个功能", True, None, "local", "本机", source=src)
    check("本机项目照旧开 VS Code（不走后台）", not src.calls, src.calls)
    _app.HOSTED_SETTING[0] = lambda source_id: False
    result = _app.launch_session("/srv/p", "做个功能", True, None, "ssh", "服务器", source=src)
    check("这台没开后台运行（默认）：远端也照旧开 VS Code", not src.calls, src.calls)
    _app.HOSTED_SETTING[0] = lambda source_id: source_id == "srv"
    result = _app.launch_session("/srv/p", "做个功能", True, None, "ssh", "服务器", source=src, in_editor=True)
    check("in_editor（「在 VS Code 中恢复」按钮）：不走后台", not src.calls and _hs_editor, src.calls)
    _hs_editor.clear()
    src = _HostSource({})
    ok, message = _app.hand_over(_Record("srv", "服务器", "ssh", dict(hosted_rec.snap, activity="busy")), src)
    check("转到 VS Code：Claude 在忙时不打断", not ok and "这一轮完成后" in message and not src.calls, (ok, message))
    ok, message = _app.hand_over(hosted_rec, src)
    check("转到 VS Code：空闲时先结束后台的，再在 VS Code 里恢复同一段对话", ok and src.calls == [{"cmd": "hosted_stop", "sessionId": "h-1", "ifIdle": True}]
          and _hs_editor and _hs_editor[0][3] == "h-1", (src.calls, _hs_editor))
    _hs_editor.clear()
    src = _HostSource(RuntimeError("HOSTED_NETWORK：无法确认这台电脑上 Claude Code 使用的网络设置"))
    result = _app.launch_session("/srv/p", "做个功能", True, None, "ssh", "服务器", source=src)
    check("网络检查没过：改开 VS Code，并告诉用户原因（出口不能悄悄换）", _hs_editor
          and "无法确认这台电脑上 Claude Code 使用的网络设置，已改在 VS Code 中打开" in result["message"], result)
    _hs_editor.clear()

    # 出口检测、按设备开关、把 VS Code 里的会话转到后台
    from kiteline import store as _store_mod  # noqa: E402
    probe = _app.hosted_probe([_HostSource({}), _HostSource({}, features=()), type("Off", (_HostSource,), {"state": "connecting"})({})])
    check("出口检测：能后台运行的那台回出口和网络设置", probe[0]["egress"]["ip"] == "1.2.3.4" and probe[0]["source"] == "vscode"
          and "error" not in probe[0], probe[0])
    check("出口检测：不支持的、离线的也列上并说明", "暂不支持" in probe[1]["error"] and "离线" in probe[2]["error"], probe[1:])
    vs_rec = _Record("srv", "服务器", "ssh", {"sessionId": "v-1", "name": "v-1", "activity": "idle", "entrypoint": "claude-vscode",
                                            "pid": 999, "cwd": "/srv/p"})
    check("能转到后台的会话：远端、VS Code 里的 Claude Code、那台支持", _store_mod.hostable(vs_rec, _HostSource({}))
          and not _store_mod.hostable(vs_rec, _HostSource({}, features=())) and not _store_mod.hostable(hosted_rec, _HostSource({}))
          and not _store_mod.hostable(_Record("local", "本机", "local", dict(vs_rec.snap)), _HostSource({})), "hostable")
    closed = []
    _saved_close = _app.delivery.close
    _app.delivery.close = lambda record, source, siblings: (closed.append(record.key), _delivery.Outcome(True, False, "已关闭会话"))[1]
    try:
        src = _HostSource({})
        ok, message = _app.move_to_background(_Record("srv", "服务器", "ssh", dict(vs_rec.snap, activity="busy")), src, 1)
        check("转到后台：Claude 在忙时不转", not ok and "这一轮完成后" in message and not src.calls and not closed, (ok, message))
        src = _HostSource({"sessionId": "v-1", "hosted": "y1"})
        ok, message = _app.move_to_background(vs_rec, src, 1)
        call = src.calls[0] if src.calls else {}
        check("转到后台：先请 watcher 接手（takeOver），再关掉 VS Code 里的标签", ok and message == "已转到后台运行" and closed == [vs_rec.key]
              and call.get("cmd") == "hosted_start" and call.get("takeOver") is True and call.get("sessionId") == "v-1" and call.get("prompt") == "",
              (ok, message, src.calls, closed))
        src = _HostSource(RuntimeError("VS Code 中的这个会话没有关闭，未转到后台运行"))
        ok, message = _app.move_to_background(vs_rec, src, 1)
        check("转到后台：没成功如实说", not ok and "没有关闭" in message, message)
    finally:
        _app.delivery.close = _saved_close
finally:
    _delivery.DRY_RUN, _delivery.LOOKUP, _delivery._backend, _app.launch_session, _app.HOSTED_SETTING[0] = _hs_saved

print("\n电脑端单元测试：%s" % ("全部通过" if not FAILED else "%d 项失败" % FAILED))
sys.exit(1 if FAILED else 0)
