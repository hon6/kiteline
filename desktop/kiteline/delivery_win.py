"""Windows 上的投递：Win32（ctypes），不依赖第三方库。

VS Code 会话：枚举 Code.exe 的顶层窗口 → 按标题里的项目名找到会话所在窗口、切到前台 →
打开扩展 URI 切到这个会话 → 核对前台标签 → 剪贴板粘贴（Ctrl+V）→ 回车。
终端里的 CLI 会话：AttachConsole 到它的控制台，WriteConsoleInputW 直接写按键（不用抢前台）。
"""

import ctypes
import os
import subprocess
import sys
import threading
import time
from ctypes import wintypes

from . import delivery, log
from .delivery import Outcome

user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

EDITORS = {"code.exe": "vscode", "code - insiders.exe": "vscode-insiders", "vscodium.exe": "vscodium", "cursor.exe": "cursor"}

# MARK: 窗口

EnumWindowsProc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
user32.EnumWindows.argtypes = [EnumWindowsProc, wintypes.LPARAM]
user32.GetWindowTextLengthW.argtypes = [wintypes.HWND]
user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user32.GetWindowThreadProcessId.restype = wintypes.DWORD
user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.GetForegroundWindow.restype = wintypes.HWND
user32.SetForegroundWindow.argtypes = [wintypes.HWND]
user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
user32.IsIconic.argtypes = [wintypes.HWND]
user32.AttachThreadInput.argtypes = [wintypes.DWORD, wintypes.DWORD, wintypes.BOOL]
user32.BringWindowToTop.argtypes = [wintypes.HWND]
user32.IsWindow.argtypes = [wintypes.HWND]
kernel32.OpenProcess.restype = wintypes.HANDLE
kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
kernel32.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
kernel32.GetCurrentThreadId.restype = wintypes.DWORD

PROCESS_QUERY_LIMITED_INFORMATION = 0x1000


def _title(hwnd):
    length = user32.GetWindowTextLengthW(hwnd)
    buffer = ctypes.create_unicode_buffer(length + 1)
    user32.GetWindowTextW(hwnd, buffer, length + 1)
    return buffer.value


def _image(pid):
    handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
    if not handle:
        return ""
    try:
        size = wintypes.DWORD(1024)
        buffer = ctypes.create_unicode_buffer(1024)
        if kernel32.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size)):
            return os.path.basename(buffer.value).lower()
        return ""
    finally:
        kernel32.CloseHandle(handle)


def _pid(hwnd):
    pid = wintypes.DWORD()
    user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    return pid.value


def editor_windows():
    """[(hwnd, 标题, scheme)]：VS Code 系编辑器的可见顶层窗口"""
    found = []
    images = {}

    def callback(hwnd, _):
        if not user32.IsWindowVisible(hwnd):
            return True
        title = _title(hwnd)
        if not title:
            return True
        pid = _pid(hwnd)
        if pid not in images:
            images[pid] = _image(pid)
        scheme = EDITORS.get(images[pid])
        if scheme:
            found.append((hwnd, title, scheme))
        return True
    user32.EnumWindows(EnumWindowsProc(callback), 0)
    return found


user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetWindow.argtypes = [wintypes.HWND, wintypes.UINT]
user32.GetWindow.restype = wintypes.HWND


kernel32.GetTickCount.restype = wintypes.DWORD


class LASTINPUTINFO(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.UINT), ("dwTime", wintypes.DWORD)]


def editor_dialogs():
    """[(hwnd, 所属窗口, 所属窗口标题)]：VS Code 系编辑器弹着的系统对话框（TaskDialog / MessageBox，窗口类 #32770），见 alerts.py"""
    found = []
    images = {}

    def callback(hwnd, _):
        if not user32.IsWindowVisible(hwnd):
            return True
        name = ctypes.create_unicode_buffer(64)
        user32.GetClassNameW(hwnd, name, 64)
        if name.value != "#32770":
            return True
        pid = _pid(hwnd)
        if pid not in images:
            images[pid] = _image(pid)
        if EDITORS.get(images[pid]):
            owner = user32.GetWindow(hwnd, 4)   # GW_OWNER
            found.append((hwnd, owner, _title(owner) if owner else ""))
        return True
    user32.EnumWindows(EnumWindowsProc(callback), 0)
    return found


# 投递（切前台、发键）到什么时候：这段时间里的键盘鼠标动静是 Kiteline 自己发的，不算用户在用电脑（见 idle_seconds）
AUTOMATION_UNTIL = [0.0]


def idle_seconds():
    """多久没人动键盘鼠标了。最后一下落在 Kiteline 投递期间（投完 2 秒内）的，是手机那头在操作，人不在电脑前"""
    info = LASTINPUTINFO(ctypes.sizeof(LASTINPUTINFO), 0)
    if not user32.GetLastInputInfo(ctypes.byref(info)):
        return 0.0
    idle = max(0.0, ((kernel32.GetTickCount() - info.dwTime) & 0xFFFFFFFF) / 1000.0)
    since = time.time() - AUTOMATION_UNTIL[0]
    return float("inf") if since >= 0 and idle >= since - 2 else idle


def foreground_editor_title():
    hwnd = user32.GetForegroundWindow()
    if not hwnd:
        return None
    return _title(hwnd) if EDITORS.get(_image(_pid(hwnd))) else None


def _force_foreground(hwnd):
    """后台进程不能随便抢前台：先按一下 Alt（系统认为有用户输入），再挂到前台线程上切换。
    已经在前台就不动：VS Code 在前台时单按一下 Alt 会把焦点移到菜单栏，接下来的回车就打开「文件」菜单、
    新建了一个空白文件，会话没提交（10-23 实测）"""
    if user32.GetForegroundWindow() == hwnd and not user32.IsIconic(hwnd):
        return True
    if user32.IsIconic(hwnd):
        user32.ShowWindow(hwnd, 9)   # SW_RESTORE
    _send_keys([(VK_MENU, False), (VK_MENU, True)])
    front = user32.GetForegroundWindow()
    current = kernel32.GetCurrentThreadId()
    target = user32.GetWindowThreadProcessId(front, None) if front else 0
    attached = bool(target and target != current and user32.AttachThreadInput(current, target, True))
    try:
        user32.BringWindowToTop(hwnd)
        user32.SetForegroundWindow(hwnd)
    finally:
        if attached:
            user32.AttachThreadInput(current, target, False)
    time.sleep(0.15)
    return user32.GetForegroundWindow() == hwnd


# MARK: 投完把前台还回去

def capture_front():
    """投递前的前台窗口，投完还回去（同 Mac 版 FrontReturn）。本来就在 VS Code 里的不用还：返回 None。
    虚拟屏幕开着时，屏幕上那个 VS Code 窗口也要还：投递的可能是看不见的另一个窗口，投完人要回到正在用的这个"""
    from . import vscreen
    hwnd = user32.GetForegroundWindow()
    if not hwnd or (EDITORS.get(_image(_pid(hwnd))) and not vscreen.visible_editor(hwnd)):
        return None
    return hwnd


def return_front(hwnd, delay=0.4):
    """把前台还给投递前的窗口。回车要先落进 VS Code 再切，切早了会打进原来的窗口；
    前台已经不是 VS Code（用户自己切走了）、原来的窗口已经关了，都不动"""
    if not hwnd:
        return
    time.sleep(delay)
    front = user32.GetForegroundWindow()
    if not front or front == hwnd or not user32.IsWindow(hwnd) or not EDITORS.get(_image(_pid(front))):
        return
    log.write("投递完成，前台还给原来的窗口：%s" % _title(hwnd))
    # 刚发过按键的进程一般有权切前台，直接切；不行再走 Alt + 挂线程那一套
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.1)
    if user32.GetForegroundWindow() != hwnd:
        _force_foreground(hwnd)


# MARK: 按键

VK_RETURN, VK_ESCAPE, VK_SHIFT, VK_CONTROL, VK_MENU, VK_TAB, VK_V = 0x0D, 0x1B, 0x10, 0x11, 0x12, 0x09, 0x56
KEY_VK = {"enter": VK_RETURN, "return": VK_RETURN, "esc": VK_ESCAPE, "escape": VK_ESCAPE,
          "1": 0x31, "2": 0x32, "3": 0x33, "4": 0x34}


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", wintypes.LONG), ("dy", wintypes.LONG), ("mouseData", wintypes.DWORD), ("dwFlags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("ki", KEYBDINPUT), ("mi", MOUSEINPUT)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", wintypes.DWORD), ("u", _INPUTUNION)]


user32.SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
KEYEVENTF_KEYUP = 0x0002


def _send_keys(events):
    """events: [(虚拟键码, 是否抬起)]。带上 MARKER：投递期间截用户按键时（KeyHold）放行自己发的"""
    inputs = (INPUT * len(events))()
    for index, (vk, up) in enumerate(events):
        inputs[index].type = 1   # INPUT_KEYBOARD
        inputs[index].u.ki = KEYBDINPUT(vk, 0, KEYEVENTF_KEYUP if up else 0, 0, MARKER)
    user32.SendInput(len(events), inputs, ctypes.sizeof(INPUT))


def _tap(vk, shift=False, ctrl=False):
    events = []
    if ctrl:
        events.append((VK_CONTROL, False))
    if shift:
        events.append((VK_SHIFT, False))
    events += [(vk, False), (vk, True)]
    if shift:
        events.append((VK_SHIFT, True))
    if ctrl:
        events.append((VK_CONTROL, True))
    _send_keys(events)


def _tap_named(key):
    if key == "shift+tab":
        _tap(VK_TAB, shift=True)
    elif key == "ctrl+w":   # 关闭会话：VS Code 的「关闭编辑器」（只由 delivery.close 按，手机按不到）
        _tap(0x57, ctrl=True)
    else:
        _tap(KEY_VK[key])


# MARK: 投递期间截住用户的按键（同 Mac 版 KeyHold）

# 投递把 VS Code 切到前台的这一两秒，用户手上可能还在打字（在 Kiteline 客户端里接着写下一句，或者在别的程序里打字）：
# 这些键落进 VS Code 会混进刚粘贴的消息；输入法正在拼字时，回车还会被输入法拿去上屏拼音，消息根本没发出去，
# 下一条又接着粘在后面（10-25 在 Mac 上遇到）。低级键盘钩子把用户的按键截下来（Kiteline 自己发的带 MARKER，照常放行），
# 前台还回去以后按原顺序补发给用户原来的窗口
MARKER = 0x4B4C4B48
WH_KEYBOARD_LL, HC_ACTION, WM_QUIT = 13, 0, 0x0012
LLKHF_EXTENDED, LLKHF_UP = 0x01, 0x80
KEYEVENTF_EXTENDEDKEY = 0x0001


class KBDLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [("vkCode", wintypes.DWORD), ("scanCode", wintypes.DWORD), ("flags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]


LRESULT = ctypes.c_ssize_t
HOOKPROC = ctypes.WINFUNCTYPE(LRESULT, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM)
user32.SetWindowsHookExW.restype = wintypes.HHOOK
user32.SetWindowsHookExW.argtypes = [ctypes.c_int, HOOKPROC, wintypes.HINSTANCE, wintypes.DWORD]
user32.CallNextHookEx.restype = LRESULT
user32.CallNextHookEx.argtypes = [wintypes.HHOOK, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM]
user32.UnhookWindowsHookEx.argtypes = [wintypes.HHOOK]
user32.GetMessageW.argtypes = [ctypes.POINTER(wintypes.MSG), wintypes.HWND, wintypes.UINT, wintypes.UINT]
user32.PeekMessageW.argtypes = [ctypes.POINTER(wintypes.MSG), wintypes.HWND, wintypes.UINT, wintypes.UINT, wintypes.UINT]
user32.PostThreadMessageW.argtypes = [wintypes.DWORD, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
user32.GetAsyncKeyState.restype = ctypes.c_short
user32.GetAsyncKeyState.argtypes = [ctypes.c_int]
kernel32.GetModuleHandleW.restype = wintypes.HMODULE
kernel32.GetModuleHandleW.argtypes = [wintypes.LPCWSTR]


class KeyHold:
    """with KeyHold(front): 投递 + 还前台。front = 投递前用户在用的窗口（None = 本来就在 VS Code 里，不截）。
    钩子在单独的线程里（低级钩子要有消息循环）；万一没退出，limit 秒后自己放开"""

    def __init__(self, front, limit=8):
        self.front = front
        self.limit = limit
        self.held = []
        self._thread = None
        self._thread_id = 0
        self._ready = threading.Event()

    def __enter__(self):
        if self.front:
            self._thread = threading.Thread(target=self._run, name="kiteline-keyhold", daemon=True)
            self._thread.start()
            self._ready.wait(1)
        return self

    def __exit__(self, *exc):
        if self._thread:
            if self._thread_id:
                user32.PostThreadMessageW(self._thread_id, WM_QUIT, 0, 0)
            self._thread.join(2)
            if self.held:
                self._replay()
        return False

    def _run(self):
        self._thread_id = kernel32.GetCurrentThreadId()

        def proc(code, wparam, lparam):
            if code == HC_ACTION:
                info = ctypes.cast(lparam, ctypes.POINTER(KBDLLHOOKSTRUCT)).contents
                if info.dwExtraInfo != MARKER:
                    self.held.append((info.vkCode, info.scanCode, info.flags))
                    return 1
            return user32.CallNextHookEx(None, code, wparam, lparam)

        callback = HOOKPROC(proc)   # 钩子在的时候一直引用着，被回收了系统会调到野指针
        msg = wintypes.MSG()
        user32.PeekMessageW(ctypes.byref(msg), None, 0, 0, 0)   # 先建好本线程的消息队列，__exit__ 发的 WM_QUIT 才收得到
        hook = user32.SetWindowsHookExW(WH_KEYBOARD_LL, callback, kernel32.GetModuleHandleW(None), 0)
        self._ready.set()
        if not hook:
            log.write("投递期间截键失败（SetWindowsHookEx 错误 %d），照常投递" % ctypes.get_last_error())
            return
        timer = threading.Timer(self.limit, lambda: user32.PostThreadMessageW(self._thread_id, WM_QUIT, 0, 0))
        timer.daemon = True
        timer.start()
        while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
            pass
        timer.cancel()
        user32.UnhookWindowsHookEx(hook)

    def _replay(self):
        """前台已经还给原来的窗口（或用户自己切去了别的程序）才补发；前台还是 VS Code 就不补：补进去正是要避免的事"""
        downs = sum(1 for _, _, flags in self.held if not flags & LLKHF_UP)
        for _ in range(10):
            front = user32.GetForegroundWindow()
            if front and (front == self.front or not EDITORS.get(_image(_pid(front)))):
                break
            time.sleep(0.05)
        else:
            log.write("投递期间截下 %d 次按键，前台仍是 VS Code，不补发" % downs)
            return
        time.sleep(0.25)   # 窗口刚回到前台，程序要一会儿才把键盘焦点交回输入框：补早了字会丢
        events = list(self.held)
        # 截着的时候按下、放开钩子以后才松开的键：松开那一下已经直接落到了前台，补发的只有按下，会一直按着——现在实际没按着的补一个松开
        pressed = {}
        for vk, scan, flags in events:
            if flags & LLKHF_UP:
                pressed.pop(vk, None)
            else:
                pressed[vk] = (vk, scan, flags)
        events += [(vk, scan, flags | LLKHF_UP) for vk, scan, flags in pressed.values() if not user32.GetAsyncKeyState(vk) & 0x8000]
        inputs = (INPUT * len(events))()
        for index, (vk, scan, flags) in enumerate(events):
            inputs[index].type = 1   # INPUT_KEYBOARD
            inputs[index].u.ki = KEYBDINPUT(vk, scan, (KEYEVENTF_KEYUP if flags & LLKHF_UP else 0)
                                            | (KEYEVENTF_EXTENDEDKEY if flags & LLKHF_EXTENDED else 0), 0, MARKER)
        user32.SendInput(len(events), inputs, ctypes.sizeof(INPUT))
        log.write("投递期间截下 %d 次按键，已补发给「%s」" % (downs, _title(front)))


# MARK: 剪贴板

CF_UNICODETEXT = 13
GMEM_MOVEABLE = 0x0002
user32.OpenClipboard.argtypes = [wintypes.HWND]
user32.GetClipboardData.restype = wintypes.HANDLE
user32.GetClipboardData.argtypes = [wintypes.UINT]
user32.SetClipboardData.restype = wintypes.HANDLE
user32.SetClipboardData.argtypes = [wintypes.UINT, wintypes.HANDLE]
kernel32.GlobalAlloc.restype = wintypes.HGLOBAL
kernel32.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]
kernel32.GlobalLock.restype = wintypes.LPVOID
kernel32.GlobalLock.argtypes = [wintypes.HGLOBAL]
kernel32.GlobalUnlock.argtypes = [wintypes.HGLOBAL]


def _open_clipboard():
    for _ in range(20):
        if user32.OpenClipboard(None):
            return True
        time.sleep(0.05)
    return False


def get_clipboard():
    if not _open_clipboard():
        return None
    try:
        handle = user32.GetClipboardData(CF_UNICODETEXT)
        if not handle:
            return None
        pointer = kernel32.GlobalLock(handle)
        try:
            return ctypes.wstring_at(pointer)
        finally:
            kernel32.GlobalUnlock(handle)
    finally:
        user32.CloseClipboard()


def set_clipboard(text):
    data = ctypes.create_unicode_buffer(text)
    size = ctypes.sizeof(data)
    if not _open_clipboard():
        return False
    try:
        user32.EmptyClipboard()
        handle = kernel32.GlobalAlloc(GMEM_MOVEABLE, size)
        pointer = kernel32.GlobalLock(handle)
        ctypes.memmove(pointer, data, size)
        kernel32.GlobalUnlock(handle)
        return bool(user32.SetClipboardData(CF_UNICODETEXT, handle))
    finally:
        user32.CloseClipboard()


# MARK: VS Code

def available():
    return True


def _find_window(cwd, remote=False):
    """cwd 所在的 VS Code 窗口 (hwnd, 标题, scheme)：按目录从深到浅匹配窗口标题；只开着一个窗口时就是它"""
    windows = editor_windows()
    folders = [p for p in (cwd or "").rstrip("\\/").replace("\\", "/").split("/") if p and not p.endswith(":")][::-1]
    for folder in folders:
        for hwnd, title, scheme in windows:
            if delivery.window_matches(title, folder, remote):
                return hwnd, title, scheme
    return windows[0] if len(windows) == 1 else None


def raise_window(cwd, remote=False):
    """把 cwd 所在的 VS Code 窗口切到前台（新任务自动提交前、在 VS Code 中打开）。返回窗口（找不到返回 None）"""
    target = _find_window(cwd, remote)
    if target:
        _force_foreground(target[0])
    return target[0] if target else None


def _focus_session(record):
    """把会话所在窗口切到前台，再用扩展 URI 切到这个会话的标签。返回 (成功, 会弹确认框)。
    还没发过消息的会话不开 URI：扩展打不开它，会另开一个空白标签（之后粘贴、回车都落到新标签里，
    而且新标签还没加载好，粘贴常常落空）。这时只切窗口，由 front_problem 核对前台就是它的「Claude Code」标签。
    会弹确认框：没能替用户设成免确认（见 remotessh.trust_claude_links），链接照开，等用户在电脑上点"""
    from . import remotessh
    target = _find_window(record.snap.get("cwd"), record.kind == "ssh")
    if not target:
        log.write("找不到会话「%s」所在的 VS Code 窗口，放弃投递" % record.snap.get("name"))
        return False, False
    hwnd, title, scheme = target
    if not _force_foreground(hwnd):
        log.write("没能把 VS Code 窗口切到前台：%s" % title)
    time.sleep(0.4)
    if not (record.snap.get("title") or "").strip():
        log.write("会话「%s」尚未发过消息：只切到窗口，不开 URI" % record.snap.get("name"))
        return True, False
    trusted, wrote = remotessh.trust_claude_links()
    if wrote:
        time.sleep(1.0)   # 刚写进设置的，VS Code 要一会儿才读到
    # 注意不能带 prompt 预填：会话标签已经打开时扩展只把它调到前面，提示「Your prompt was not applied」，内容不会填进去
    link = delivery.editor_link(record.snap.get("sessionId"), scheme)
    log.write("打开 %s://anthropic.claude-code/open（会话 %s）" % (scheme, record.snap.get("name")))
    os.startfile(link)   # noqa: S606（ShellExecute 打开自定义协议）
    return True, not trusted


WINDOW_NOT_FOUND = "未找到该会话所在的 VS Code 窗口（VS Code 未运行，或打开了多个窗口而无法确定目标）"


def send_vscode(prompt, record, submit, siblings, check_waiting=True):
    """发完把前台还给用户原来在用的窗口；只填不提交的不还（用户要到 VS Code 里再看一眼：
    VS Code 在虚拟屏幕上时，投完它还在前台，虚拟屏幕会把这个窗口挪回来给人看）"""
    from . import vscreen
    with vscreen.busy():
        AUTOMATION_UNTIL[0] = time.time() + 30
        front = capture_front()
        try:
            with KeyHold(front):
                outcome = _send_vscode(prompt, record, submit, siblings, check_waiting)
                if (submit or not outcome.ok) and not outcome.keep_front:
                    return_front(front, 0.9 if prompt.startswith("/") and "\n" not in prompt else 0.4)
        finally:
            AUTOMATION_UNTIL[0] = time.time() + 1.5
    return outcome


def _front_problem(record, siblings):
    """前台能不能往这个会话里输入（None = 可以）。要打开 claude.ai 的 Artifact 链接弹的「打开外部网站」框先替用户取消
    （见 alerts.artifact_dialog）：框挂着时前台是它，消息投不进去，回车还会按到框里默认的「打开」"""
    from . import alerts
    if alerts.cancel_artifact_dialogs():
        time.sleep(0.3)   # 框关了，前台回到 VS Code 窗口
    return delivery.front_problem(foreground_editor_title(), record, siblings)


def _send_vscode(prompt, record, submit, siblings, check_waiting=True):
    focused, confirming = _focus_session(record)
    if not focused:
        return Outcome(False, False, WINDOW_NOT_FOUND)
    if confirming:
        return Outcome(False, False, delivery.LINK_CONFIRMATION, keep_front=True)
    time.sleep(1.0)   # 等扩展把会话标签切到前面（切到已打开的标签后输入框有焦点，可以直接粘贴）
    problem = _front_problem(record, siblings)
    if problem:
        return Outcome(False, False, problem)
    # 会话在终端、别的窗口还开着（或窗口刚重新加载、之前的 Claude 进程还没退）：标签里是「仍在别处打开」，
    # 输入框不能用，粘贴没反应。替用户按「Open here anyway」，等输入框能用再粘贴（同 Mac 版 ClaudeInput.openHereIfHeld）
    from . import alerts, uia_win
    hwnd = user32.GetForegroundWindow()
    if uia_win.open_here_if_held(hwnd):
        problem = _front_problem(record, siblings)
        if problem:
            return Outcome(False, False, problem)
    # 键盘焦点得在这个会话的输入框里：标签切过来了，焦点却可能还在终端、编辑器里（见 uia_win.ensure_focus），那就先把光标放进输入框
    titles = delivery.tab_names(record.snap)
    at, place = uia_win.ensure_focus(hwnd, titles, need_input=True)
    if at == "elsewhere":
        return Outcome(False, False, delivery.focus_elsewhere(record, place))
    if at == "unknown":
        log.write("读不出 VS Code 的焦点（网页辅助功能树未就绪），照常粘贴")
    saved = get_clipboard()
    set_clipboard(prompt)
    alerts.note_paste(prompt)
    # 粘贴后核对：输入框里的字变了才算粘上（前台被别的程序抢走时 Ctrl+V 落在那个程序里）。落空的叫回 VS Code、光标放回输入框再粘一次（同 Mac 版）
    before = uia_win.input_text(hwnd, titles) if at == "input" else None
    _tap(VK_V, ctrl=True)
    pasted = None
    if before is not None:
        def landed():
            now = uia_win.input_text(hwnd, titles)
            return now is None or now != before
        if not delivery.poll(1.2, landed):
            log.write("粘贴后输入框没变（前台是 %s），叫回 VS Code 再粘一次" % _front_name())
            _force_foreground(hwnd)
            time.sleep(0.3)
            problem = _front_problem(record, siblings)
            if problem:
                _restore_clipboard_later(saved)
                return Outcome(False, False, problem)
            again, place = uia_win.ensure_focus(hwnd, titles, need_input=True)
            if again == "elsewhere":
                _restore_clipboard_later(saved)
                return Outcome(False, False, delivery.focus_elsewhere(record, place))
            _tap(VK_V, ctrl=True)
            if not delivery.poll(1.2, landed):
                log.write("重新粘贴后输入框仍没变（前台是 %s），不发" % _front_name())
                _restore_clipboard_later(saved)
                return Outcome(False, False, delivery.PASTE_MISSED)
        pasted = uia_win.input_text(hwnd, titles)
    time.sleep(0.35)
    if not submit:
        _restore_clipboard_later(saved)
        return Outcome(True, False, "已填入输入框")
    problem = _front_problem(record, siblings)
    if problem:
        _restore_clipboard_later(saved)
        return Outcome(False, False, "文字已粘贴，但提交时出现问题：" + problem)
    # 焦点离开了输入框（比如跳到了终端）：回车会按在那里，不按。斜杠命令的焦点落在面板里的命令菜单上不算（同 Mac 版）
    slash = prompt.startswith("/") and "\n" not in prompt
    left = uia_win.focus_left(hwnd, titles, menu_ok=slash) if at == "input" else None
    if left:
        log.write("粘贴后焦点到了%s，不按回车" % left)
        _restore_clipboard_later(saved)
        return Outcome(False, False, delivery.FOCUS_LEFT_MESSAGE % left)
    midway = check_waiting and delivery.waiting_midway(record)
    if midway:
        _restore_clipboard_later(saved)
        return Outcome(True, False, midway)
    _tap(VK_RETURN)
    # 斜杠命令：第一下回车可能只是选中命令菜单里的项，再按一下才执行
    if slash:
        time.sleep(0.5)
        _tap(VK_RETURN)
    # 回车后核对：输入框里不再是这段话才算提交上（读不出输入框的照旧当作已提交）。没提交上的补按一次，前台、焦点、等确认照样先核对
    if pasted is not None:
        def cleared():
            return delivery.submitted_from(uia_win.input_text(hwnd, titles), pasted, prompt)
        if not delivery.poll(2.0 if slash else 1.5, cleared):
            log.write("回车后输入框里仍是这段话（前台是 %s），补按一次" % _front_name())
            if user32.GetForegroundWindow() != hwnd:
                _force_foreground(hwnd)
                time.sleep(0.3)
            problem = _front_problem(record, siblings)
            if problem:
                _restore_clipboard_later(saved)
                return Outcome(False, False, "文字已粘贴，但提交时出现问题：" + problem)
            left = uia_win.focus_left(hwnd, titles, menu_ok=slash)
            if left:
                _restore_clipboard_later(saved)
                return Outcome(False, False, delivery.FOCUS_LEFT_MESSAGE % left)
            midway = check_waiting and delivery.waiting_midway(record)
            if midway:
                _restore_clipboard_later(saved)
                return Outcome(True, False, midway)
            if not cleared():
                _tap(VK_RETURN)
                if not delivery.poll(1.5, cleared):
                    log.write("补按回车后输入框里仍是这段话，按未提交报")
                    _restore_clipboard_later(saved)
                    return Outcome(True, False, delivery.SUBMIT_MISSED)
    _restore_clipboard_later(saved)
    return Outcome(True, True, "已提交")


def _front_name():
    """前台窗口是哪个程序（日志用）"""
    return _image(_pid(user32.GetForegroundWindow())) or "未知"


def _restore_clipboard_later(saved):
    if saved is None:
        return
    import threading

    def later():
        time.sleep(1.0)
        set_clipboard(saved)
    threading.Thread(target=later, daemon=True).start()


def press_vscode(key, times, record, siblings):
    from . import vscreen
    with vscreen.busy():
        AUTOMATION_UNTIL[0] = time.time() + 30
        front = capture_front()
        try:
            with KeyHold(front):
                outcome = _press_vscode(key, times, record, siblings)
                if not outcome.keep_front:
                    return_front(front)
        finally:
            AUTOMATION_UNTIL[0] = time.time() + 1.5
    return outcome


def _press_vscode(key, times, record, siblings):
    focused, confirming = _focus_session(record)
    if not focused:
        return Outcome(False, False, WINDOW_NOT_FOUND)
    if confirming:
        return Outcome(False, False, delivery.LINK_CONFIRMATION_PRESS, keep_front=True)
    time.sleep(0.9)
    problem = _front_problem(record, siblings)
    if problem:
        return Outcome(False, False, problem.replace("此消息未发送", "未按下按键"))
    # 键要按在这个会话的 Claude 面板里：焦点在终端的话「1」「回车」就按进终端了（见 uia_win.ensure_focus）
    from . import uia_win
    at, place = uia_win.ensure_focus(user32.GetForegroundWindow(), delivery.tab_names(record.snap), need_input=False)
    if at == "elsewhere":
        return Outcome(False, False, delivery.focus_elsewhere(record, place).replace("此消息未发送", "未按下按键"))
    for _ in range(times):
        _tap_named(key)
        time.sleep(0.25)
    return Outcome(True, False, "已按下 %s" % key)


# MARK: 插件回的动作单（同 Mac 版 Delivery.runUIActions）

def run_ui(actions, plugin_step):
    """按顺序做：focus 把 app 里打开了这个项目的窗口切到前台并核对 / plugin 回头请插件做一步（如往对话输入框里填字）/
    key 核对前台还是那个窗口再按键；做完把前台还回去。哪一步不成就停下、不按键，返回给用户看的原因；都做完返回 None"""
    from . import vscreen
    hwnd, filled, shown = None, False, "编辑器"
    with vscreen.busy():
        AUTOMATION_UNTIL[0] = time.time() + 30
        front = capture_front()
        try:
            with KeyHold(front):
                for action in actions:
                    kind = action.get("do")
                    if kind == "focus":
                        app = action.get("app") or ""
                        shown = delivery.UI_APPS.get(app)
                        if not shown:
                            return delivery.ui_problem(actions, delivery.UI_UNSUPPORTED, filled)
                        windows = [w for w in editor_windows() if w[2] == app]
                        if not windows:
                            return delivery.ui_problem(actions, "%s 没有在运行" % shown, filled)
                        folder = action.get("folder") or ""
                        names = [p for p in folder.rstrip("\\/").replace("\\", "/").split("/") if p and not p.endswith(":")][::-1]
                        target = next((w for n in names for w in windows if delivery.window_matches(w[1], n, False)), None)
                        if target is None and len(windows) == 1:
                            target = windows[0]
                        if target is None:
                            return delivery.ui_problem(actions, "未找到 %s 中打开「%s」的窗口" % (shown, os.path.basename(folder.rstrip("\\/"))), filled)
                        hwnd = target[0]
                        _force_foreground(hwnd)
                        time.sleep(0.3)
                        if user32.GetForegroundWindow() != hwnd:
                            return delivery.ui_problem(actions, "%s 未能切到前台（电脑可能已锁屏，或被其他窗口遮挡），为避免误输入到其他应用而停止"
                                                       % shown, filled)
                    elif kind == "plugin":
                        try:
                            plugin_step(action.get("step") or "")
                        except Exception as exc:  # noqa: BLE001
                            return delivery.ui_problem(actions, str(exc), filled)
                        filled = True
                        time.sleep(0.2)
                    elif kind == "key" and (action.get("name") or "").lower() in KEY_VK:
                        if hwnd and user32.GetForegroundWindow() != hwnd:
                            return delivery.ui_problem(actions, "%s 已不在前台，为避免误输入到其他应用而停止" % shown, filled)
                        _tap_named(action["name"].lower())
                        log.write("动作单：在 %s 按下 %s" % (shown, action["name"]))
                        time.sleep(0.3)
                    else:
                        return delivery.ui_problem(actions, delivery.UI_UNSUPPORTED, filled)
                return None
        finally:
            return_front(front)
            AUTOMATION_UNTIL[0] = time.time() + 1.5


# MARK: 重新加载窗口（「尝试重连」，见 alerts.py）

RELOAD_COMMAND = "Developer: Reload Window"


def reload_window(hwnd):
    """让这个 VS Code 窗口「重新加载窗口」：切到前台、Ctrl+Shift+P 打开命令面板、贴上命令名、回车。
    每一步先用 UI Automation 核对：焦点是内容为「>」的输入框才贴，贴完内容对得上才回车，免得贴进编辑器或 Claude 的输入框。
    命令面板认英文命令名（中文界面也认）。返回 (成功, 给手机看的话)"""
    from . import uia_win, vscreen
    title = _title(hwnd)
    with vscreen.busy():
        AUTOMATION_UNTIL[0] = time.time() + 30
        front = capture_front()
        try:
            with KeyHold(front):
                ok, message = _reload_window(hwnd, title, uia_win)
            return_front(front, 0.8 if ok else 0.3)
        finally:
            AUTOMATION_UNTIL[0] = time.time() + 1.5
    return ok, message


def _reload_window(hwnd, title, uia_win):
    if not user32.IsWindow(hwnd) or not _force_foreground(hwnd):
        return False, "没能把这个 VS Code 窗口切到前台，请在电脑上处理"
    time.sleep(0.3)
    # 按键只落在前台：每一步都核对前台还是这个窗口（命令面板的内容是从系统焦点读的，别的 VS Code 窗口里开着的面板也读得到）
    def ours():
        return user32.GetForegroundWindow() == hwnd
    if not ours():
        return False, "没能把这个 VS Code 窗口切到前台，请在电脑上处理"
    _tap(0x50, shift=True, ctrl=True)   # Ctrl+Shift+P

    def wait_value(expected, seconds):
        until = time.time() + seconds
        while time.time() < until:
            if uia_win.palette_value() == expected:
                return True
            time.sleep(0.25)
        return False
    if not wait_value(">", 4) or not ours():
        return False, "没能打开 VS Code 命令面板，请在电脑上重新加载窗口"
    saved = get_clipboard()
    set_clipboard(RELOAD_COMMAND)
    _tap(VK_V, ctrl=True)
    _restore_clipboard_later(saved)
    if not wait_value(">" + RELOAD_COMMAND, 2) or not ours():
        if ours():
            _tap(VK_ESCAPE)   # 焦点核对过就在命令面板里：Esc 关掉它
        return False, "没能在 VS Code 命令面板里输入命令，请在电脑上重新加载窗口"
    _tap(VK_RETURN)
    log.write("已让「%s」重新加载窗口" % title)
    return True, "已在电脑上重新加载「%s」窗口；如果仍连不上，会再提醒你" % (delivery_place(title) or "VS Code")


def delivery_place(title):
    """窗口标题里项目那段（同 delivery.title_place）"""
    return delivery.title_place(title)


# MARK: 终端（控制台）

def send_console(prompt, pid, submit):
    """写进 CLI 会话所在控制台的输入缓冲区。
    回车一律按真实按键单独发（实测 Windows Terminal 里的 Claude Code）：和文字一口气写进去时，Claude Code 一次读到多少条
    不固定，有时当成粘贴（回车只换行）、有时被切开（回车直接提交，一条消息拆成几条）。
    多行：每行末尾加「\\」写进去，再单独按回车——Claude Code 里「\\ + 回车」是换行；最后一行写完，要提交时再单独按回车"""
    lines = prompt.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    for index, line in enumerate(lines):
        last = index == len(lines) - 1
        if line or not last:
            outcome = _console_helper(pid, line if last else line + "\\", "已填入输入框", False)
            if not outcome.ok:
                return outcome
        if not last:
            time.sleep(0.3)
            outcome = _console_helper(pid, "\r", "已填入输入框", False)
            if not outcome.ok:
                return outcome
            time.sleep(0.3)
    if not submit:
        return Outcome(True, False, "已填入输入框")
    time.sleep(0.5)
    return _console_helper(pid, "\r", "已提交", True)


def press_console(key, times, pid):
    seq = {"enter": "\r", "return": "\r", "esc": "\x1b", "escape": "\x1b", "1": "1", "2": "2", "3": "3", "4": "4",
           "shift+tab": "\x1b[Z"}[key]
    return _console_helper(pid, seq * times, "已按下 %s" % key, False)


def _console_helper(pid, text, message, submitted):
    """AttachConsole 会换掉本进程的控制台，所以在一个没有控制台的子进程里做（kiteline --console-input <pid>）"""
    if getattr(sys, "frozen", False):
        cmd = [sys.executable, "--console-input", str(pid)]
    else:
        cmd = [sys.executable, "-m", "kiteline", "--console-input", str(pid)]
    env = dict(os.environ)
    env["PYTHONPATH"] = os.path.dirname(os.path.dirname(os.path.abspath(__file__))) + os.pathsep + env.get("PYTHONPATH", "")
    try:
        result = subprocess.run(cmd, input=text.encode("utf-8"), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=15, env=env, creationflags=0x00000008)   # DETACHED_PROCESS：子进程没有控制台
    except (OSError, subprocess.SubprocessError) as exc:
        return Outcome(False, False, "写入终端失败：%s" % exc)
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip() or "退出码 %d" % result.returncode
        return Outcome(False, False, "写入终端失败：%s" % detail)
    return Outcome(True, submitted, message)


class _CHAR(ctypes.Union):
    _fields_ = [("UnicodeChar", wintypes.WCHAR), ("AsciiChar", ctypes.c_char)]


class _KEY_EVENT_RECORD(ctypes.Structure):
    _fields_ = [("bKeyDown", wintypes.BOOL), ("wRepeatCount", wintypes.WORD), ("wVirtualKeyCode", wintypes.WORD),
                ("wVirtualScanCode", wintypes.WORD), ("uChar", _CHAR), ("dwControlKeyState", wintypes.DWORD)]


class _EVENT(ctypes.Union):
    _fields_ = [("KeyEvent", _KEY_EVENT_RECORD), ("_pad", ctypes.c_byte * 16)]


class _INPUT_RECORD(ctypes.Structure):
    _fields_ = [("EventType", wintypes.WORD), ("Event", _EVENT)]


def console_input_main(pid):
    """子进程入口：stdin 是要写的文字"""
    text = sys.stdin.buffer.read().decode("utf-8")
    kernel32.FreeConsole()
    if not kernel32.AttachConsole(wintypes.DWORD(pid)):
        sys.stderr.write("无法连接到会话所在的终端（AttachConsole 失败，错误 %d）" % ctypes.get_last_error())
        return 2
    kernel32.CreateFileW.restype = wintypes.HANDLE
    kernel32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID, wintypes.DWORD,
                                     wintypes.DWORD, wintypes.HANDLE]
    handle = kernel32.CreateFileW("CONIN$", 0xC0000000, 3, None, 3, 0, None)   # GENERIC_READ|WRITE，OPEN_EXISTING
    records = []
    # 按 UTF-16 码元写（emoji 这类超出 BMP 的字拆成代理对两条，一个 WCHAR 放不下）
    data = text.encode("utf-16-le")
    for unit in (int.from_bytes(data[i:i + 2], "little") for i in range(0, len(data), 2)):
        ch = chr(unit)
        vk = {"\r": VK_RETURN, "\x1b": VK_ESCAPE}.get(ch, 0)
        # 回车、Esc 带上真实的扫描码，同键盘按下时：Windows Terminal 里扫描码为 0 的回车，Claude Code 不当作提交
        scan = user32.MapVirtualKeyW(vk, 0) if vk else 0
        for down in (True, False):
            rec = _INPUT_RECORD()
            rec.EventType = 1   # KEY_EVENT
            rec.Event.KeyEvent = _KEY_EVENT_RECORD(down, 1, vk, scan, _CHAR(UnicodeChar=ch), 0)
            records.append(rec)
    array = (_INPUT_RECORD * len(records))(*records)
    written = wintypes.DWORD()
    ok = kernel32.WriteConsoleInputW(wintypes.HANDLE(handle), array, len(records), ctypes.byref(written))
    kernel32.FreeConsole()
    if not ok:
        sys.stderr.write("写入终端输入失败（错误 %d）" % ctypes.get_last_error())
        return 3
    return 0
