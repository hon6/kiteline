"""Linux：投递前把 VS Code 窗口切到前台，投完把前台还给原来的窗口（同 Mac 版 FrontReturn、Windows 版 delivery_win.capture_front）。

在电脑上的 Kiteline 客户端里发消息时，前台是客户端自己；不切过去，VS Code 不在前台、一律不按键，消息就发不出去。
X11 会话和 GNOME / KDE 的 Wayland 会话都行：VS Code（Electron 默认）和 Kiteline 客户端都跑在 XWayland 里，
用 EWMH 的 _NET_ACTIVE_WINDOW 请求切换（来源标成 pager，窗口管理器照办）。VS Code 以原生 Wayland 方式运行时找不到它的窗口，
什么也不做（照旧要求 VS Code 在前台）。只用 libX11（系统自带），不另装东西。
"""

import ctypes
import ctypes.util
import os
import threading
import time

_lib = None
_lock = threading.Lock()

ClientMessage = 33
SubstructureNotifyMask = 1 << 19
SubstructureRedirectMask = 1 << 20


class _ClientMessage(ctypes.Structure):
    _fields_ = [("type", ctypes.c_int), ("serial", ctypes.c_ulong), ("send_event", ctypes.c_int),
                ("display", ctypes.c_void_p), ("window", ctypes.c_ulong), ("message_type", ctypes.c_ulong),
                ("format", ctypes.c_int), ("data", ctypes.c_long * 5)]


class _Event(ctypes.Union):
    _fields_ = [("message", _ClientMessage), ("pad", ctypes.c_long * 24)]


def _x11():
    global _lib
    if _lib is None:
        name = ctypes.util.find_library("X11") or "libX11.so.6"
        lib = ctypes.CDLL(name)
        lib.XOpenDisplay.restype = ctypes.c_void_p
        lib.XOpenDisplay.argtypes = [ctypes.c_char_p]
        lib.XCloseDisplay.argtypes = [ctypes.c_void_p]
        lib.XDefaultRootWindow.restype = ctypes.c_ulong
        lib.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        lib.XInternAtom.restype = ctypes.c_ulong
        lib.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        lib.XGetWindowProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_long, ctypes.c_long, ctypes.c_int,
                                           ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int),
                                           ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_void_p)]
        lib.XFree.argtypes = [ctypes.c_void_p]
        lib.XSendEvent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_long, ctypes.POINTER(_Event)]
        lib.XFlush.argtypes = [ctypes.c_void_p]
        _lib = lib
    return _lib


class _Display:
    def __enter__(self):
        if not os.environ.get("DISPLAY"):
            raise OSError("没有 X11 显示")
        self.lib = _x11()
        self.d = self.lib.XOpenDisplay(None)
        if not self.d:
            raise OSError("连不上 X11 显示")
        self.root = self.lib.XDefaultRootWindow(self.d)
        return self

    def __exit__(self, *_):
        self.lib.XCloseDisplay(self.d)

    def atom(self, name):
        return self.lib.XInternAtom(self.d, name.encode(), 0)

    def prop(self, window, name, kind=0):
        """窗口属性的原始字节和格式（8 / 32）；没有返回 (b"", 0)"""
        actual, fmt, count, after, data = ctypes.c_ulong(), ctypes.c_int(), ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_void_p()
        status = self.lib.XGetWindowProperty(self.d, window, self.atom(name), 0, 4096, 0, kind, ctypes.byref(actual), ctypes.byref(fmt),
                                             ctypes.byref(count), ctypes.byref(after), ctypes.byref(data))
        if status != 0 or not data.value:
            return b"", 0
        try:
            if fmt.value == 32:   # 32 位的属性在客户端里按 long 排
                return bytes((ctypes.c_ulong * count.value).from_address(data.value)), 32
            return ctypes.string_at(data.value, count.value * (fmt.value // 8)), fmt.value
        finally:
            self.lib.XFree(data)

    def windows(self, name):
        raw, fmt = self.prop(self.root, name)
        if fmt != 32 or not raw:
            return []
        return list((ctypes.c_ulong * (len(raw) // ctypes.sizeof(ctypes.c_ulong))).from_buffer_copy(raw))

    def title(self, window):
        raw, _ = self.prop(window, "_NET_WM_NAME")
        if not raw:
            raw, _ = self.prop(window, "WM_NAME")
        return raw.decode("utf-8", "replace")

    def klass(self, window):
        raw, _ = self.prop(window, "WM_CLASS")
        return [part.decode("utf-8", "replace").lower() for part in raw.split(b"\0") if part]

    def activate(self, window):
        event = _Event()
        event.message.type = ClientMessage
        event.message.send_event = 1
        event.message.window = window
        event.message.message_type = self.atom("_NET_ACTIVE_WINDOW")
        event.message.format = 32
        event.message.data[0] = 2   # 来源：pager（窗口管理器照办，不当成抢前台）
        event.message.data[1] = 0   # CurrentTime
        self.lib.XSendEvent(self.d, self.root, 0, SubstructureRedirectMask | SubstructureNotifyMask, ctypes.byref(event))
        self.lib.XFlush(self.d)


# 窗口类名（WM_CLASS）：新版 VS Code 是 com.microsoft.vscode，老版本 code；还有 Insiders、VSCodium、Cursor、Windsurf
EDITOR_CLASSES = {"code", "code-oss", "code - insiders", "com.microsoft.vscode", "com.microsoft.vscode.insiders", "vscodium",
                  "com.vscodium.codium", "cursor", "windsurf"}


def active():
    """现在的前台窗口（X11 窗口编号）；拿不到返回 None"""
    try:
        with _lock, _Display() as x:
            found = x.windows("_NET_ACTIVE_WINDOW")
            return found[0] if found and found[0] else None
    except (OSError, AttributeError):
        return None


def raise_editor(folders):
    """把打开着 folders（扩展报的文件夹）的 VS Code 窗口切到前台，返回窗口编号；找不到返回 None。
    按窗口标题里的文件夹名认（VS Code 默认标题「文件 — 文件夹 — Visual Studio Code」）；切错了也不要紧，
    调用方切完再看扩展报的 focused，对不上不按键"""
    names = [os.path.basename(f.rstrip("/\\")) for f in folders or [] if f]
    if not names:
        return None
    try:
        with _lock, _Display() as x:
            best = None
            for window in x.windows("_NET_CLIENT_LIST"):
                if not EDITOR_CLASSES.intersection(x.klass(window)):
                    continue
                parts = [p.strip() for p in x.title(window).replace(" - ", " — ").split(" — ")]
                # 远端窗口标题里文件夹名后面跟着「[SSH: 主机]」
                if any(part == name or part.startswith(name + " [") for part in parts for name in names):
                    best = window
            if best is None:
                return None
            x.activate(best)
            return best
    except (OSError, AttributeError):
        return None


def find(match):
    """顶层窗口里 match(类名列表, 标题) 为真的（按 _NET_CLIENT_LIST 的顺序）；拿不到返回空列表。插件的动作单按程序认窗口用"""
    try:
        with _lock, _Display() as x:
            return [w for w in x.windows("_NET_CLIENT_LIST") if match(x.klass(w), x.title(w))]
    except (OSError, AttributeError):
        return []


def activate(window):
    """把这个窗口切到前台（不核对：调用方切完看 active()）"""
    try:
        with _lock, _Display() as x:
            x.activate(window)
            return True
    except (OSError, AttributeError):
        return False


def restore(previous, raised, delay=0.4):
    """投完把前台还给 previous：等 delay 秒（回车要先落进 VS Code），前台还是我们切过去的那个窗口才还（用户自己点过别处就不动）"""
    if not previous or not raised or previous == raised:
        return
    time.sleep(delay)
    try:
        with _lock, _Display() as x:
            now = x.windows("_NET_ACTIVE_WINDOW")
            if now and now[0] == raised:
                x.activate(previous)
    except (OSError, AttributeError):
        pass
