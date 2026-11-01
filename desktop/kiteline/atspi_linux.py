"""Linux 上读写 VS Code 的界面（AT-SPI 辅助功能接口）：VS Code 自己画的对话框（文字、按钮）、Claude 标签里的「Open here anyway」。
对应 Mac 版 EditorAlerts.swift / ClaudeInput.swift、Windows 版 uia_win.py。

VS Code 要先开辅助功能才读得到（就绪检查里「读取 VS Code 弹框」一键开启，见 vscode_a11y.py；10-27 kl-ubuntu 实测）：
  - 带 ACCESSIBILITY_ENABLED=1 启动，Chromium 才向 AT-SPI 登记。只加 --force-renderer-accessibility（或 argv.json 里的同名项）不登记
  - window.dialogStyle 要是 custom：GNOME 原生对话框是 GTK 画的，Chromium 关掉了 GTK 那层的辅助功能，读不到；VS Code 自己画的对话框在网页里，读得到

不加依赖：Kiteline 跑在自己的虚拟环境里，导入不了系统的 gi。起一个系统 python3（GNOME 桌面自带 python3-gi 和 AT-SPI 的接口描述）的
常驻辅助进程，标准输入一行 JSON 命令、标准输出一行 JSON 结果，闲置 10 分钟自己关掉，下次用到再起。
找对话框用 AT-SPI 的 Collection 查询（按角色在 VS Code 那边一次查完，几毫秒），不用逐个节点遍历（一个窗口几百个节点、近 0.1 秒）。
"""

import json
import os
import queue
import shutil
import subprocess
import threading
import time

from . import config, log

IDLE_EXIT = 600
HELD_LABEL = "Open here anyway"
INPUT_LABEL = "Message input"

# 辅助进程：每行一个请求，按 cmd 分派；出错回 {ok: false, error}
SCRIPT = r'''
import json, sys
import gi
gi.require_version("Atspi", "2.0")
from gi.repository import Atspi

Atspi.set_timeout(1500, 15000)   # VS Code 卡住时别跟着卡死
EDITORS = {"code", "code - insiders", "code-insiders", "codium", "vscodium", "code-oss", "cursor", "windsurf"}
TEXT_ROLES = {Atspi.Role.STATIC, Atspi.Role.LABEL, Atspi.Role.PARAGRAPH, Atspi.Role.HEADING}
PANEL_ROLES = {Atspi.Role.ENTRY, Atspi.Role.PASSWORD_TEXT, Atspi.Role.LIST, Atspi.Role.LIST_BOX, Atspi.Role.TREE, Atspi.Role.TABLE, Atspi.Role.TREE_TABLE}


def frames(name=None, active=False):
    desktop = Atspi.get_desktop(0)
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        if app is None or (app.get_name() or "").lower() not in EDITORS:
            continue
        app.clear_cache()
        pid = app.get_process_id()
        for k in range(app.get_child_count()):
            frame = app.get_child_at_index(k)
            if frame is None or (name is not None and frame.get_name() != name):
                continue
            if active and not frame.get_state_set().contains(Atspi.StateType.ACTIVE):
                continue
            yield pid, frame


def matching(frame, roles):
    """这个窗口里指定角色的元素（Collection 一次查完；没有 Collection 接口时逐个找）"""
    collection = frame.get_collection_iface()
    if collection is not None:
        rule = Atspi.MatchRule.new(Atspi.StateSet.new([]), Atspi.CollectionMatchType.ALL, {}, Atspi.CollectionMatchType.ALL,
                                   list(roles), Atspi.CollectionMatchType.ANY, [], Atspi.CollectionMatchType.ALL, False)
        return list(collection.get_matches(rule, Atspi.CollectionSortOrder.CANONICAL, 0, True))
    found = []

    def walk(node, depth):
        if depth > 60:
            return
        if node.get_role() in roles:
            found.append(node)
        for k in range(node.get_child_count()):
            child = node.get_child_at_index(k)
            if child is not None:
                walk(child, depth + 1)
    walk(frame, 0)
    return found


def read(dialog):
    """对话框里的字（从上到下）和按钮；有输入框、列表的算面板"""
    texts, buttons, panel = [], [], False

    def walk(node, depth):
        nonlocal panel
        if depth > 12:
            return
        role, name = node.get_role(), " ".join((node.get_name() or "").split())
        if role == Atspi.Role.PUSH_BUTTON:
            if name and name != "Close Dialog":
                buttons.append({"name": name, "node": node})
            return
        if role in PANEL_ROLES:
            panel = True
        # 图标那格的文字是零宽字符这类看不见的东西：只收带字的
        if role in TEXT_ROLES and any(ch.isalnum() for ch in name) and name not in texts:
            texts.append(name)
        for k in range(node.get_child_count()):
            child = node.get_child_at_index(k)
            if child is not None:
                walk(child, depth + 1)
    walk(dialog, 0)
    return texts, buttons, panel


def dialogs():
    out = []
    for pid, frame in frames():
        for dialog in matching(frame, (Atspi.Role.DIALOG, Atspi.Role.ALERT)):
            texts, buttons, panel = read(dialog)
            out.append({"pid": pid, "frame": frame.get_name(), "texts": texts, "buttons": [b["name"] for b in buttons], "panel": panel})
    return out


def press(req):
    for _pid, frame in frames(req["frame"]):
        for dialog in matching(frame, (Atspi.Role.DIALOG, Atspi.Role.ALERT)):
            texts, buttons, _ = read(dialog)
            if texts != req["texts"]:
                continue
            for button in buttons:
                if button["name"] == req["button"]:
                    action = button["node"].get_action_iface()
                    return bool(action and action.do_action(0))
    return False


def held(req):
    """当前窗口（或指定窗口）里 Claude 标签是不是「仍在别处打开」：按钮恰好一个才按（分屏两个都被占时认不出是哪个）"""
    count, pressed, has_input, target = 0, False, False, None
    for _pid, frame in frames(req.get("frame"), active=not req.get("frame")):
        for node in matching(frame, (Atspi.Role.PUSH_BUTTON, Atspi.Role.ENTRY)):
            name = node.get_name() or ""
            if node.get_role() == Atspi.Role.PUSH_BUTTON and name == req["label"]:
                count += 1
                target = node
            elif node.get_role() == Atspi.Role.ENTRY and name == req["input"] \
                    and node.get_state_set().contains(Atspi.StateType.ENABLED):
                has_input = True
    if count == 1 and req.get("press"):
        action = target.get_action_iface()
        pressed = bool(action and action.do_action(0))
    return {"held": count, "pressed": pressed, "input": has_input}


def input_text(req):
    """当前窗口里 Claude 输入框现在的字（粘贴后、回车后核对用）：有焦点的那个，没有就看是不是只有一个能用的；分屏认不出是哪个回 None"""
    boxes = []
    for _pid, frame in frames(active=True):
        for node in matching(frame, (Atspi.Role.ENTRY,)):
            if node.get_name() == req["input"] and node.get_state_set().contains(Atspi.StateType.ENABLED):
                boxes.append(node)
    focused = [b for b in boxes if b.get_state_set().contains(Atspi.StateType.FOCUSED)]
    box = focused[0] if len(focused) == 1 else boxes[0] if len(boxes) == 1 and not focused else None
    if box is None or box.get_text_iface() is None:
        return {"text": None}
    return {"text": Atspi.Text.get_text(box, 0, Atspi.Text.get_character_count(box))}


for line in sys.stdin:
    try:
        req = json.loads(line)
        cmd = req.get("cmd")
        if cmd == "ping":
            out = {"editors": sum(1 for _ in frames())}
        elif cmd == "dialogs":
            out = {"dialogs": dialogs()}
        elif cmd == "press":
            out = {"pressed": press(req)}
        elif cmd == "held":
            out = held(req)
        elif cmd == "input":
            out = input_text(req)
        else:
            out = {"ok": False, "error": "unknown command"}
        out.setdefault("ok", True)
    except Exception as exc:  # noqa: BLE001
        out = {"ok": False, "error": "%s: %s" % (type(exc).__name__, exc)}
    sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
    sys.stdout.flush()
'''


def system_python():
    """系统自带的 python3（不是 Kiteline 虚拟环境里的那个：虚拟环境导入不了系统的 gi）"""
    for path in ("/usr/bin/python3", "/usr/local/bin/python3"):
        if os.access(path, os.X_OK):
            return path
    return shutil.which("python3", path="/usr/bin:/bin:/usr/local/bin")


class _Helper:
    def __init__(self):
        self.lock = threading.Lock()
        self.proc = None
        self.lines = None
        self.last_used = 0.0
        self.broken = None   # 系统 python3 没有 gi / AT-SPI：记下原因，别反复起
        threading.Thread(target=self._reaper, daemon=True).start()

    def _start(self):
        python = system_python()
        if not python:
            raise OSError("没有找到系统的 python3")
        self.proc = subprocess.Popen([python, "-I", "-c", SCRIPT], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, env=dict(os.environ, PYTHONIOENCODING="utf-8"))
        self.lines = queue.Queue()
        out = self.proc.stdout

        def pump():
            for raw in iter(out.readline, b""):
                self.lines.put(raw)
            self.lines.put(None)
        threading.Thread(target=pump, daemon=True).start()

    def call(self, request, timeout=6.0):
        """发一条命令，等结果（dict）；超时、辅助进程挂了返回 None（下次重起）"""
        with self.lock:
            if self.broken:
                return None
            self.last_used = time.time()
            try:
                fresh = not self.proc or self.proc.poll() is not None
                if fresh:
                    self._start()
                self.proc.stdin.write((json.dumps(request, ensure_ascii=False) + "\n").encode("utf-8"))
                self.proc.stdin.flush()
                raw = self.lines.get(timeout=timeout + (5 if fresh else 0))
            except (OSError, queue.Empty) as exc:
                log.write("界面读取辅助进程没有回应（%s）：%s" % (request.get("cmd"), exc or "超时"))
                self._stop()
                return None
            if raw is None:
                # 一启动就退出：多半是系统 python3 没有 gi / AT-SPI（极简桌面），别每 3 秒再试一次
                error = self._stop()
                if fresh:
                    self.broken = error or "辅助进程启动失败"
                    log.write("无法读取 VS Code 界面：%s" % self.broken)
                return None
            try:
                reply = json.loads(raw.decode("utf-8", "replace"))
            except ValueError:
                return None
            if not reply.get("ok"):
                log.write("界面读取出错（%s）：%s" % (request.get("cmd"), reply.get("error")))
                return None
            return reply

    def _stop(self):
        """停掉辅助进程；返回它在标准错误里留下的最后一行（启动失败的原因）"""
        proc, self.proc = self.proc, None
        if not proc:
            return ""
        if proc.poll() is None:
            try:
                proc.kill()
            except OSError:
                pass
        try:
            tail = proc.stderr.read().decode("utf-8", "replace").strip().splitlines()
        except (OSError, ValueError):
            tail = []
        return tail[-1] if tail else ""

    def _reaper(self):
        while True:
            time.sleep(60)
            with self.lock:
                if self.proc and time.time() - self.last_used > IDLE_EXIT:
                    self._stop()


_helper = None
_helper_lock = threading.Lock()


def _call(request, timeout=6.0):
    global _helper
    if not config.IS_LINUX:
        return None
    with _helper_lock:
        if _helper is None:
            _helper = _Helper()
    return _helper.call(request, timeout)


def unavailable_reason():
    """读不了界面的原因（系统 python3 缺 gi / AT-SPI）；能读或还没试过返回空字符串"""
    return (_helper.broken or "") if _helper else ""


def editors_exposed():
    """向辅助功能登记了的 VS Code 窗口个数（带 ACCESSIBILITY_ENABLED=1 启动的才登记）；读不了返回 None"""
    reply = _call({"cmd": "ping"})
    return reply.get("editors", 0) if reply else None


def dialogs():
    """VS Code 窗口里的对话框：[{"pid", "frame": 窗口标题, "texts", "buttons": [按钮名], "panel"}]；读不了返回 None"""
    reply = _call({"cmd": "dialogs"})
    if not reply:
        return None
    return [d for d in reply.get("dialogs") or [] if isinstance(d, dict)]


def press(frame, texts, button):
    """按下某个窗口里（文字就是 texts 的）对话框上的按钮"""
    reply = _call({"cmd": "press", "frame": frame, "texts": texts, "button": button})
    return bool(reply and reply.get("pressed"))


def held_state(frame=None, press=False):
    """当前窗口（frame=None）或指定窗口里 Claude 标签是不是「仍在别处打开」：{"held": 按钮个数, "pressed", "input"}；读不到返回 None"""
    return _call({"cmd": "held", "frame": frame, "label": HELD_LABEL, "input": INPUT_LABEL, "press": press})


def input_text():
    """当前窗口里 Claude 输入框现在的字（空白统一过）；读不出返回 None（同 Mac 版 ClaudeInput.text）"""
    from . import delivery
    reply = _call({"cmd": "input", "input": INPUT_LABEL}, timeout=3)
    value = reply.get("text") if reply else None
    return delivery.normalized(value) if isinstance(value, str) else None


def open_here_if_held(ready_wait=2.5):
    """投递粘贴前（会话标签已切到前面、窗口在前台）：标签是「仍在别处打开」就按「Open here anyway」，等输入框能用。返回 True = 按过。
    同 uia_win.open_here_if_held；网页的辅助功能树刚建时读不全，最多等 ready_wait 秒，看到输入框（没被占）或按钮（被占）为止"""
    deadline = time.time() + ready_wait
    state = None
    while time.time() < deadline:
        state = held_state(press=True)
        if state is None:
            return False
        if state.get("pressed") or state.get("input"):
            break
        time.sleep(0.3)
    if not state or not state.get("pressed"):
        return False
    log.write("会话仍在别处打开，已按「Open here anyway」")
    # 扩展接着重新拉起 Claude，输入框随后才能用
    until = time.time() + 8
    while time.time() < until:
        time.sleep(0.4)
        state = held_state()
        if state and not state.get("held") and state.get("input"):
            break
    return True
