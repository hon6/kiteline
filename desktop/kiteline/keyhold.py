"""Linux：投递期间截住用户的按键（同 Mac 版 KeyHold、Windows 版 delivery_win.KeyHold）。

投递把 VS Code 切到前台的这一两秒，用户手上可能还在打字（在 Kiteline 客户端里接着写下一句，或者在别的程序里打字）：
这些键落进 VS Code 会混进刚粘贴的消息；输入法正在拼字时，回车还会被输入法拿去上屏拼音，消息根本没发出去，
下一条又接着粘在后面（10-25 在 Mac 上遇到）。这段时间把键盘接管下来，前台还回去以后按原顺序补发：
- GNOME Wayland：经 Kiteline 的 GNOME 扩展让桌面接管（同打开概览时），截下的键由扩展补发（shellext.hold_keys）
- X11 会话：XGrabKeyboard 抓住键盘，XTEST 补发（libX11 / libXtst，系统自带）
接管期间 VS Code 拿不到键盘焦点（Wayland 下配套扩展报 focused=false），截着键盘时粘贴也不生效（10-25 实测）：
前台核对改看窗口管理器的前台窗口；粘贴、回车前先等用户停手（settle），再 pause() 放开，按完 resume() 再接管。
放开的这一下约 0.3 秒，这期间打的字照旧会落进 VS Code，所以要挑用户停手的时候。
别的 Wayland 桌面（KDE 等）本来就切不了 VS Code 的前台，要用户自己在 VS Code 里发，不用截。
"""

import ctypes
import ctypes.util
import os
import queue
import threading
import time

from . import log, shellext, x11focus

LIMIT = 10   # 最多截几秒（万一投递卡住，到时自己放开）
QUIET = 0.4   # 放开键盘前等用户停手多久
PATIENCE = 4.0   # 用户一直在打字时最多等多久

KeyPress, KeyRelease = 2, 3
GrabModeAsync, GrabSuccess = 1, 0


class Hold:
    """start() 拿到的接管；kind 为 None 时什么也不做"""

    def __init__(self, kind=None, grab=None):
        self.kind = kind
        self.paused = False
        self._grab = grab

    @property
    def holding(self):
        """正截着键盘（这时 VS Code 拿不到键盘焦点）"""
        return self.kind is not None and not self.paused

    def settle(self):
        """放开键盘之前等用户停手 QUIET 秒（最多等 PATIENCE 秒）：放开的那一下打的字会漏进 VS Code"""
        if not self.holding:
            return
        deadline = time.time() + PATIENCE
        while time.time() < deadline:
            idle = shellext.keys_idle() if self.kind == "shell" else self._grab.command("idle")
            if idle >= QUIET:
                return
            time.sleep(max(0.05, QUIET - idle))
        log.write("用户一直在打字，等了 %.0f 秒，照常投递" % PATIENCE)

    def pause(self):
        """粘贴、回车前放开：VS Code 要真拿到键盘焦点"""
        if not self.holding:
            return
        self.paused = True
        if self.kind == "shell":
            shellext.pause_keys()
        else:
            self._grab.command("pause")

    def resume(self):
        if self.kind is None or not self.paused:
            return
        self.paused = not (shellext.resume_keys() if self.kind == "shell" else self._grab.command("resume"))

    def end(self, replay):
        """放开键盘；replay = 把截下的键补发给现在的前台窗口（调用方先把前台还回去、核对过不是 VS Code）"""
        if self.kind is None:
            return
        kind, self.kind = self.kind, None
        presses = shellext.release_keys(replay) if kind == "shell" else self._grab.command("end", replay)
        if presses:
            log.write("投递期间截下 %d 次按键，%s" % (presses, "已补发给原来的窗口" if replay else "前台仍是 VS Code，不补发"))


def start(limit=LIMIT):
    """开始截键；这台电脑上做不到就返回什么也不做的 Hold"""
    wayland = os.environ.get("XDG_SESSION_TYPE") == "wayland" or (bool(os.environ.get("WAYLAND_DISPLAY")) and not os.environ.get("DISPLAY"))
    if wayland:
        if shellext.can_hold() and shellext.hold_keys(limit + 2):   # 扩展那边的时限多给两秒：正常由这边放开
            return Hold("shell")
        return Hold()
    if os.environ.get("DISPLAY"):
        grab = _XGrab(limit)
        if grab.start_grab():
            return Hold("x11", grab)
    return Hold()


class _XKeyEvent(ctypes.Structure):
    _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int), ("display", ctypes.c_void_p),
                ("window", ctypes.c_ulong), ("root", ctypes.c_ulong), ("subwindow", ctypes.c_ulong), ("time", ctypes.c_ulong),
                ("x", ctypes.c_int), ("y", ctypes.c_int), ("x_root", ctypes.c_int), ("y_root", ctypes.c_int),
                ("state", ctypes.c_uint), ("keycode", ctypes.c_uint), ("same_screen", ctypes.c_int)]


class _XEvent(ctypes.Union):
    _fields_ = [("type", ctypes.c_int), ("key", _XKeyEvent), ("pad", ctypes.c_long * 24)]


class _XGrab(threading.Thread):
    """X11 的键盘抓取放在自己的线程里（Xlib 一个连接只在一个线程里用）：投递线程经队列发 pause / resume / end。
    抓取跟着连接走，线程自己守着时限——投递卡住了也到时放开，不会把用户的键盘一直锁着"""

    def __init__(self, limit):
        super().__init__(name="kiteline-keyhold", daemon=True)
        self.limit = limit
        self.keys = []
        self.last = time.time()
        self._commands = queue.Queue()
        self._results = queue.Queue()

    def start_grab(self):
        self.start()
        try:
            return self._results.get(timeout=2)
        except queue.Empty:
            return False

    def command(self, name, *args):
        if not self.is_alive():
            return 0 if name == "end" else False
        self._commands.put((name, args))
        try:
            return self._results.get(timeout=3)
        except queue.Empty:
            return 0 if name == "end" else False

    def run(self):
        try:
            lib = _xlib()
            display = lib.XOpenDisplay(None)
        except OSError:
            display = None
        if not display:
            self._results.put(False)
            return
        root = lib.XDefaultRootWindow(display)

        def grab():
            ok = lib.XGrabKeyboard(display, root, 0, GrabModeAsync, GrabModeAsync, 0) == GrabSuccess
            lib.XFlush(display)
            return ok

        def drain():
            event = _XEvent()
            while lib.XPending(display):
                lib.XNextEvent(display, ctypes.byref(event))
                if event.type in (KeyPress, KeyRelease):
                    self.keys.append((event.key.keycode, event.type == KeyPress))
                    self.last = time.time()

        grabbed = grab()
        self._results.put(grabbed)
        if not grabbed:   # 别的程序正抓着键盘（菜单开着之类）：不截
            lib.XCloseDisplay(display)
            return
        deadline = time.time() + self.limit
        replay = False
        while True:
            try:
                name, args = self._commands.get(timeout=0.02)
            except queue.Empty:
                name, args = None, ()
            drain()
            if name == "idle":
                self._results.put(time.time() - self.last)
            elif name == "pause":
                lib.XUngrabKeyboard(display, 0)
                lib.XFlush(display)
                grabbed = False
                self._results.put(True)
            elif name == "resume":
                grabbed = grab()
                self._results.put(grabbed)
            elif name == "end":
                replay = bool(args and args[0])
                break
            if time.time() > deadline:
                log.write("投递期间截键超时，自动放开")
                break
        if grabbed:
            lib.XUngrabKeyboard(display, 0)
            lib.XFlush(display)
        drain()
        presses = sum(1 for _, pressed in self.keys if pressed)
        if replay and self.keys:
            _replay(lib, display, self.keys)
        lib.XCloseDisplay(display)
        if name == "end":
            self._results.put(presses)


def _replay(lib, display, keys):
    """XTEST 按原顺序补发；截着时按下、放开以后才松开的键补一个松开，别一直按着"""
    try:
        xtst = ctypes.CDLL(ctypes.util.find_library("Xtst") or "libXtst.so.6")
    except OSError:
        log.write("没有 libXtst，截下的按键无法补发")
        return
    xtst.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
    down = set()
    for code, pressed in keys:
        if pressed:
            down.add(code)
        else:
            down.discard(code)
    for code, pressed in list(keys) + [(code, False) for code in down]:
        xtst.XTestFakeKeyEvent(display, code, 1 if pressed else 0, 0)
    lib.XFlush(display)


def _xlib():
    lib = x11focus._x11()
    if not hasattr(lib, "_keyhold"):
        lib.XGrabKeyboard.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]
        lib.XUngrabKeyboard.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        lib.XPending.argtypes = [ctypes.c_void_p]
        lib.XNextEvent.argtypes = [ctypes.c_void_p, ctypes.POINTER(_XEvent)]
        lib._keyhold = True
    return lib
