"""「VS Code 在虚拟屏幕中运行」（同 Mac 版 Sources/VirtualScreen.swift）：把 VS Code 的窗口挪到一块看不见的地方。

Kiteline 发消息要把 VS Code 切到前台、粘贴、回车。VS Code 在看不见的地方时，切到前台也不会盖住你正在用的窗口；
投完再把前台还给原来的程序（键盘焦点全系统只有一个，见 delivery_win.capture_front / return_front）。

Windows 没有现成的虚拟显示器（要装驱动：管理员权限、驱动签名），改把窗口挪到所有显示器之外的一块区域：
- 系统不让鼠标离开显示器，鼠标进不去（Mac 版要的鼠标围栏这里不用）；窗口在那里照样能切到前台、接收粘贴和按键
- 窗口在那块区域里铺开、互不重叠（同 Mac 版）；用户接了新显示器、区域被盖到了，挪到新的外侧
- 每个窗口原来的位置按项目记下（数据目录 vscreen.json），移回、退出 Kiteline 时放回原处；开关记着，下次启动自动恢复
- Kiteline 意外退出（崩溃、被结束进程）时窗口不能留在看不见的地方：开着时有个守护小进程，Kiteline 一退出就把窗口放回去
- 用户自己切到看不见的 VS Code 窗口（点任务栏、Alt+Tab、任务视图）：说明要看它，只把这一个窗口挪回原处，其余的留着（同 Mac 版「在 VS Code 中打开」）。
  靠系统的前台切换事件认：前一个前台是任务栏、切换器这类系统界面才算。关掉别的窗口时系统会顺手把焦点给 Z 序里下一个窗口，
  落到看不见的 VS Code 上就成了「焦点在看不见的地方」（打字没反应、再点任务栏反而是最小化）：这种把它最小化，焦点自然落回看得见的窗口；
  挪过去的窗口也压到 Z 序最底下，少出这种事；
  Kiteline 操作完、看不见的 VS Code 还占着前台（只填不提交、弹了确认框要用户点）：同样挪回来，别让键盘输入打进看不见的窗口
Linux（GNOME 45+）：窗口位置归 GNOME 管（不让窗口完全移出屏幕，Wayland 下别的程序根本挪不了窗口），改由 Kiteline 的 GNOME 扩展
（shellext.py）把 VS Code 的窗口藏起来——不画出来、鼠标点不到，键盘输入照常、照样能切到前台投递。你自己切过去要看它、
系统顺手把焦点给它的处理都在扩展里做（同上面 Windows 的规则）；Kiteline 退出或卡住时扩展收不到续约，30 秒后自己全部放回来（不用守护进程）。
第一次用要先装扩展，注销并重新登录一次才生效：开关记着，重新登录后自动打开。其他桌面（KDE 等）暂不支持。
"""

import ctypes
import json
import os
import subprocess
import sys
import threading
import time

from . import config, delivery, log

# 区域大小（同 Mac 版虚拟屏幕的逻辑分辨率）：够铺 4 个窗口（2×2，每个 1280×800）
WIDTH, HEIGHT = 2560, 1600
# 区域放在所有显示器右边再隔开这么远（像素）
GAP = 1600

_lock = threading.RLock()
_on = False
_busy = 0
_busy_until = 0.0
_watcher = None
_guard = None
_count = 0
_area = None


def supported():
    """(能不能用, 不能用的原因)。Linux 上 GNOME 45+ 都算能用（扩展没装、没生效时点开关会先装、提示重新登录）"""
    if config.IS_WINDOWS:
        return True, ""
    from . import shellext
    if shellext.applicable():
        return True, ""
    return False, "此桌面暂不支持将 VS Code 移到虚拟屏幕（需要 GNOME 45 或更新版本，如 Ubuntu 24.04）"


def _isolated():
    """测试实例不动用户的 VS Code 窗口（同 Mac 版）；测虚拟屏幕本身的测试机上用 KITELINE_VSCREEN_TEST=1 放开"""
    if os.environ.get("KITELINE_VSCREEN_TEST") == "1":
        return False
    return delivery.DRY_RUN or bool(os.environ.get("KITELINE_CONFIG_DIR"))


def state():
    ok, reason = supported()
    payload = {"supported": ok, "reason": reason, "on": _on, "windows": _count}
    if ok and config.IS_LINUX and not _on:
        # GNOME 扩展还没装 / 装了还没生效：按钮的说明里提一句（点了会先装，重新登录后自动打开）
        from . import shellext
        status, why = shellext.status()
        if status != "ready":
            payload["note"] = why
    return payload


# MARK: 投递期间

class busy:
    """投递、新任务、在 VS Code 中打开这段时间里 VS Code 跳到前台是 Kiteline 自己切的：不当成用户要看它。
    结束后再留 1.5 秒（前台还给原来的程序要一会儿）"""

    def __enter__(self):
        global _busy
        with _lock:
            _busy += 1
        return self

    def __exit__(self, *_):
        global _busy, _busy_until
        with _lock:
            _busy -= 1
            _busy_until = time.time() + 1.5
            done = _busy == 0
        if done and _on:
            threading.Timer(1.6, _after_busy).start()


def _is_busy():
    return _busy > 0 or time.time() < _busy_until


# MARK: 开关

def _state_path():
    return os.path.join(config.config_dir(), "vscreen.json")


def _load():
    try:
        with open(_state_path(), encoding="utf-8") as handle:
            data = json.load(handle)
            return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _save(data):
    try:
        os.makedirs(config.config_dir(), exist_ok=True)
        tmp = _state_path() + ".tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False)
        os.replace(tmp, _state_path())
    except OSError as exc:
        log.write("虚拟屏幕：保存窗口位置失败：%s" % exc)


def turn_on():
    """打开：挪窗口。返回 {ok, error, moved, skipped, editorRunning, on, windows}"""
    global _on
    ok, reason = supported()
    if not ok:
        return dict(state(), ok=False, error=reason)
    if _isolated():
        return dict(state(), ok=False, error="测试实例不创建虚拟屏幕")
    if config.IS_LINUX:
        from . import shellext
        status, reason = shellext.status()
        if status != "ready":
            # 扩展没装就装上；装了要重新登录一次才生效：开关先记着，重新登录后 Kiteline 启动时自动打开
            if status == "missing":
                _, reason = shellext.install()
            if status in ("missing", "relogin"):
                data = _load()
                data["on"] = True
                _save(data)
            return dict(state(), ok=False, error=reason)
    with _lock:
        data = _load()
        data["on"] = True
        _save(data)
        _on = True
        _start_watching()
        _start_guard()
        windows = _editors()
        moved, skipped = _arrange(retile=True) if windows else (0, 0)
        _yield_focus()
    message = "已将 %d 个 VS Code 窗口移到虚拟屏幕" % moved if moved else ("VS Code 窗口已在虚拟屏幕上" if windows else "VS Code 尚未运行")
    log.write("虚拟屏幕：%s%s" % (message, "（%d 个全屏窗口未移动）" % skipped if skipped else ""))
    return dict(state(), ok=True, moved=moved, skipped=skipped, editorRunning=bool(windows))


def turn_off():
    """关闭：窗口放回原处。返回 {ok, restored, on, windows}"""
    global _on
    with _lock:
        _on = False
        data = _load()
        data["on"] = False
        count = _restore_all(data.get("frames") or {}) if supported()[0] else 0
        data["frames"] = {}
        _save(data)
        _stop_guard()
        _stop_hook()
    log.write("虚拟屏幕已关闭，移回 %d 个窗口" % count)
    return dict(state(), ok=True, restored=count)


def toggle():
    return turn_off() if _on else turn_on()


def restore_on_launch():
    """启动时：上次开着就恢复；上次关着、却还有窗口留在看不见的地方（意外退出又没守住），放回来"""
    if not supported()[0] or _isolated():
        return
    data = _load()
    if data.get("on"):
        threading.Thread(target=lambda: log.write("启动时恢复虚拟屏幕：%s" % turn_on().get("moved", 0)), daemon=True).start()
    elif data.get("frames"):
        with _lock:
            _restore_all(data["frames"])
            data["frames"] = {}
            _save(data)


def prepare_for_quit():
    """退出 Kiteline：窗口先放回原处，开关保持，下次启动再挪过去（同 Mac 版）"""
    global _count
    if not _on or not supported()[0]:
        return
    with _lock:
        _restore_all(_load().get("frames") or {})
        _stop_guard()
        _count = 0


def adopt_new_windows(folder, remote, all_windows):
    """Kiteline 新开的 VS Code 窗口（新任务）出来后挪过去；all_windows = VS Code 是 Kiteline 拉起来的，恢复出来的窗口一起挪。
    最多等 30 秒（远端窗口要先连 SSH 才有项目名）"""
    if not _on:
        return

    def poll():
        deadline = time.time() + 30
        while _on and time.time() < deadline:
            with _lock:
                moved, _ = _arrange(adopt=None if all_windows else (lambda title: delivery.window_matches(title, folder, remote)))
            if moved and not all_windows:
                log.write("虚拟屏幕：已把新开的 VS Code 窗口移过去")
                return
            time.sleep(0.5)
    threading.Thread(target=poll, daemon=True).start()


# MARK: 窗口（Windows）

if config.IS_WINDOWS:
    from ctypes import wintypes

    from . import delivery_win as _win

    _user32 = _win.user32   # 和投递共用一份（参数类型已在那边声明）
    _kernel32 = _win.kernel32

    class WINDOWPLACEMENT(ctypes.Structure):
        _fields_ = [("length", wintypes.UINT), ("flags", wintypes.UINT), ("showCmd", wintypes.UINT),
                    ("ptMinPosition", wintypes.POINT), ("ptMaxPosition", wintypes.POINT), ("rcNormalPosition", wintypes.RECT)]

    _user32.GetWindowPlacement.argtypes = [wintypes.HWND, ctypes.POINTER(WINDOWPLACEMENT)]
    _user32.SetWindowPlacement.argtypes = [wintypes.HWND, ctypes.POINTER(WINDOWPLACEMENT)]
    _user32.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
    _user32.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wintypes.UINT]
    _user32.MonitorFromRect.argtypes = [ctypes.POINTER(wintypes.RECT), wintypes.DWORD]
    _user32.MonitorFromRect.restype = wintypes.HANDLE
    _user32.GetWindow.argtypes = [wintypes.HWND, wintypes.UINT]
    _user32.GetWindow.restype = wintypes.HWND
    _user32.IsZoomed.argtypes = [wintypes.HWND]
    _user32.GetSystemMetrics.argtypes = [ctypes.c_int]
    _user32.SystemParametersInfoW.argtypes = [wintypes.UINT, wintypes.UINT, ctypes.c_void_p, wintypes.UINT]
    _MonitorProc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HANDLE, wintypes.HDC, ctypes.POINTER(wintypes.RECT), wintypes.LPARAM)
    _user32.EnumDisplayMonitors.argtypes = [wintypes.HDC, ctypes.c_void_p, _MonitorProc, wintypes.LPARAM]
    try:
        _user32.SetThreadDpiAwarenessContext.argtypes = [ctypes.c_void_p]
        _user32.SetThreadDpiAwarenessContext.restype = ctypes.c_void_p
    except AttributeError:   # Windows 10 1607 之前没有
        pass

    SWP_NOZORDER, SWP_NOACTIVATE, SWP_NOOWNERZORDER = 0x0004, 0x0010, 0x0200
    SW_SHOWNOACTIVATE, SW_SHOWMAXIMIZED, SW_SHOWMINIMIZED = 4, 3, 2

    class _physical:
        """这段时间按物理像素算坐标（缩放 150% 的显示器上，不感知 DPI 的程序拿到的坐标是缩过的，存下来再放回去会走样）"""

        def __enter__(self):
            self.old = None
            if hasattr(_user32, "SetThreadDpiAwarenessContext"):
                self.old = _user32.SetThreadDpiAwarenessContext(ctypes.c_void_p(-4))   # PER_MONITOR_AWARE_V2
            return self

        def __exit__(self, *_):
            if self.old:
                _user32.SetThreadDpiAwarenessContext(ctypes.c_void_p(self.old))

    def _rect(hwnd):
        r = wintypes.RECT()
        return (r.left, r.top, r.right - r.left, r.bottom - r.top) if _user32.GetWindowRect(hwnd, ctypes.byref(r)) else None

    def _offscreen(rect):
        """窗口整个不在任何显示器上"""
        x, y, w, h = rect
        r = wintypes.RECT(x, y, x + w, y + h)
        return not _user32.MonitorFromRect(ctypes.byref(r), 0)   # MONITOR_DEFAULTTONULL

    def _desktop():
        """所有显示器拼起来的范围 (x, y, w, h)"""
        return (_user32.GetSystemMetrics(76), _user32.GetSystemMetrics(77), _user32.GetSystemMetrics(78), _user32.GetSystemMetrics(79))

    def _work_area():
        """主显示器去掉任务栏的范围 (x, y, w, h)"""
        r = wintypes.RECT()
        _user32.SystemParametersInfoW(0x0030, 0, ctypes.byref(r), 0)   # SPI_GETWORKAREA
        return (r.left, r.top, r.right - r.left, r.bottom - r.top)

    def _area_now():
        x, y, w, _ = _desktop()
        return (x + w + GAP, y, WIDTH, HEIGHT)

    def _editors():
        return _win.editor_windows()

    def _windows():
        """[(hwnd, 标题)]：VS Code 的主窗口（不含它弹的对话框之类有主人的窗口）"""
        return [(hwnd, title) for hwnd, title, _ in _win.editor_windows() if not _user32.GetWindow(hwnd, 4)]   # GW_OWNER

    def _key(title):
        """窗口标题里的项目部分：「● 首页卡片 - ccpulse [SSH: 10.168.1.10] - Visual Studio Code」→「ccpulse [SSH: 10.168.1.10]」"""
        sep = " — " if " — " in title else " - "
        parts = [p.strip() for p in title.split(sep)]
        return parts[-2] if len(parts) >= 2 else title

    def _placement(hwnd):
        p = WINDOWPLACEMENT()
        p.length = ctypes.sizeof(WINDOWPLACEMENT)
        if not _user32.GetWindowPlacement(hwnd, ctypes.byref(p)):
            return None
        n = p.rcNormalPosition
        return {"show": p.showCmd, "normal": [n.left, n.top, n.right, n.bottom], "rect": list(_rect(hwnd) or ())}

    def _fullscreen(hwnd, rect):
        """VS Code 全屏（F11）：窗口正好盖满一台显示器，又不是最大化"""
        if _user32.IsZoomed(hwnd):
            return False
        x, y, w, h = rect
        for mx, my, mw, mh in _monitors():
            if (x, y, w, h) == (mx, my, mw, mh):
                return True
        return False

    def _monitors():
        found = []

        def each(_, __, rect, ___):
            r = rect.contents
            found.append((r.left, r.top, r.right - r.left, r.bottom - r.top))
            return True
        _user32.EnumDisplayMonitors(None, None, _MonitorProc(each), 0)
        return found

    def _move(hwnd, x, y, w, h):
        _user32.SetWindowPos(hwnd, None, int(x), int(y), int(w), int(h), SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER)

    def _arrange(adopt=None, retile=False):
        """把 VS Code 的窗口铺到看不见的区域。adopt：要挪过来的窗口（按标题挑，None = 全部）。返回 (挪了几个, 全屏没挪的几个)"""
        global _count, _area
        data = _load()
        frames = data.setdefault("frames", {})
        placed, moved, skipped = [], 0, 0
        with _physical():
            area = _area_now()
            for hwnd, title in _windows():
                rect = _rect(hwnd)
                if not rect:
                    continue
                if _offscreen(rect):
                    placed.append(hwnd)
                    continue
                if adopt and not adopt(title):
                    continue
                if _fullscreen(hwnd, rect):
                    skipped += 1
                    continue
                key = _key(title)
                # 已经记过的不覆盖：上次没放回去（意外退出）时窗口被系统摆过，记下的才是真正原来的位置
                if key not in frames:
                    frames[key] = _placement(hwnd)
                # 最大化、最小化的先还原成普通窗口（不激活），不然挪不动，投递时还会在原处弹出来
                if _user32.IsZoomed(hwnd) or _user32.IsIconic(hwnd):
                    _user32.ShowWindow(hwnd, SW_SHOWNOACTIVATE)
                placed.append(hwnd)
                moved += 1
            if moved or retile or area != _area:
                _tile(placed, area)
            _area = area
        _save(data)
        _count = len(placed)
        return moved, skipped

    def _tile(windows, area):
        """平铺、互不重叠（同 Mac 版）：1 个占满，2～4 个两列，再多三列"""
        if not windows:
            return
        x0, y0, width, height = area
        columns = 1 if len(windows) == 1 else (2 if len(windows) <= 4 else 3)
        rows = (len(windows) + columns - 1) // columns
        w, h = width // columns, height // rows
        for index, hwnd in enumerate(windows):
            _move(hwnd, x0 + (index % columns) * w, y0 + (index // columns) * h, w, h)
            _sink(hwnd)

    def _yield_focus():
        """前台是刚挪走的 VS Code（打开虚拟屏幕时正用着它）：最小化，焦点落回看得见的窗口，别让键盘输入打进看不见的地方"""
        front = _user32.GetForegroundWindow()
        if front and _hidden_editor(front) and not _user32.GetWindow(front, 4):
            _user32.ShowWindow(front, 6)   # SW_MINIMIZE

    def _sink(hwnd):
        """压到 Z 序最底下（不激活）：系统找下一个窗口给焦点时先轮到看得见的"""
        _user32.SetWindowPos(hwnd, wintypes.HWND(1), 0, 0, 0, 0, 0x0001 | 0x0002 | SWP_NOACTIVATE)   # HWND_BOTTOM，NOSIZE | NOMOVE

    def _restore(hwnd, title, frames):
        """一个窗口放回原处：记下的位置还在某台显示器上就照原样（含最大化），不然放到主显示器中间"""
        saved = frames.get(_key(title))
        rect = _rect(hwnd)
        if saved and saved.get("normal"):
            l, t, r, b = saved["normal"]
            p = WINDOWPLACEMENT()
            p.length = ctypes.sizeof(WINDOWPLACEMENT)
            p.showCmd = SW_SHOWMAXIMIZED if saved.get("show") == SW_SHOWMAXIMIZED else SW_SHOWNOACTIVATE
            p.ptMinPosition = wintypes.POINT(-1, -1)
            p.ptMaxPosition = wintypes.POINT(-1, -1)
            p.rcNormalPosition = wintypes.RECT(l, t, r, b)
            # 系统会把完全不在显示器上的位置挪进来（显示器拔掉了也不会放丢）
            if _user32.SetWindowPlacement(hwnd, ctypes.byref(p)) and not _offscreen(_rect(hwnd) or (0, 0, 1, 1)):
                return True
        x, y, w, h = _work_area()
        width, height = min((rect or (0, 0, 1280, 800))[2], w - 80), min((rect or (0, 0, 1280, 800))[3], h - 80)
        _move(hwnd, x + (w - width) // 2, y + (h - height) // 2, width, height)
        return True

    def _restore_all(frames, only=None):
        """看不见的地方的窗口放回原处（only = 只放这一个 hwnd）。返回放回了几个"""
        global _count
        count = 0
        with _physical():
            for hwnd, title in _windows():
                if only is not None and hwnd != only:
                    continue
                rect = _rect(hwnd)
                if rect and _offscreen(rect) and _restore(hwnd, title, frames):
                    count += 1
        _count = max(0, _count - count)
        return count

    def bring_back(hwnd):
        """用户要看这个窗口：只把它放回原处。hwnd 是 VS Code 弹的对话框（有主人）时，挪回主人窗口、对话框摆到它中间"""
        owner = _user32.GetWindow(hwnd, 4)   # GW_OWNER
        with _lock:
            if not _on:
                return False
            count = _restore_all(_load().get("frames") or {}, only=owner or hwnd)
            if owner:
                with _physical():
                    outer, inner = _rect(owner), _rect(hwnd)
                    if outer and inner and _offscreen(inner):
                        _move(hwnd, outer[0] + (outer[2] - inner[2]) // 2, outer[1] + (outer[3] - inner[3]) // 2, inner[2], inner[3])
                        count += 1
        if count:
            log.write("虚拟屏幕：用户要看的 VS Code 窗口已移回主屏幕")
        return bool(count)

    def visible_editor(hwnd):
        """虚拟屏幕开着，hwnd 是屏幕上看得见的 VS Code 窗口（用户正在用的）"""
        if not _on:
            return False
        with _physical():
            rect = _rect(hwnd)
        return bool(rect) and not _offscreen(rect)

    # MARK: 盯着前台

    def _start_watching():
        global _watcher, _hook_runner
        if not (_watcher and _watcher.is_alive()):
            _watcher = threading.Thread(target=_watch, daemon=True)
            _watcher.start()
        # 关了又马上开：上一个钩子线程收到退出消息已经走了，另起一个
        if not (_hook_runner and _hook_runner.is_alive()):
            _hook_runner = threading.Thread(target=_hook, daemon=True)
            _hook_runner.start()

    def _hidden_editor(hwnd):
        """hwnd 是在看不见的地方的 VS Code 窗口（含它弹的对话框）"""
        with _physical():
            rect = _rect(hwnd)
            return bool(rect) and _offscreen(rect) and bool(_win.EDITORS.get(_win._image(_win._pid(hwnd))))

    def _after_busy():
        """Kiteline 操作完，前台还是看不见的 VS Code（只填不提交、弹了确认框）：挪回来给人看；
        前台已经还回去了：投递时被切到前面的 VS Code 窗口重新压到最底下"""
        front = _user32.GetForegroundWindow()
        if not _on or _is_busy():
            return
        if front and _hidden_editor(front):
            bring_back(front)
            return
        with _lock, _physical():
            for hwnd, _ in _windows():
                rect = _rect(hwnd)
                if rect and _offscreen(rect):
                    _sink(hwnd)

    def _watch():
        """前台切换事件交给钩子线程（_hook）；这里每 5 秒数一次窗口、看显示器变了没有"""
        global _count
        while _on:
            time.sleep(5)
            try:
                with _lock, _physical():
                    if not _on:
                        break
                    windows = [h for h, _ in _windows() if _rect(h) and _offscreen(_rect(h))]
                    _count = len(windows)
                    # 接了新显示器、显示器排列变了：看不见的区域跟着挪到新的外侧
                    if windows and _area_now() != _area:
                        _arrange()
            except Exception as exc:  # noqa: BLE001
                log.write("虚拟屏幕：%s" % exc)

    # 系统界面：任务栏（主屏、副屏）、Alt+Tab 切换器、任务视图、开始菜单 / 搜索、切换时的过渡窗口。
    # 前一个前台是它们、接着切到看不见的 VS Code = 用户从这些地方选了 VS Code，要看它
    SHELL_CLASSES = {"Shell_TrayWnd", "Shell_SecondaryTrayWnd", "MultitaskingViewFrame", "TaskSwitcherWnd", "XamlExplorerHostIslandWindow",
                     "ForegroundStaging", "Windows.UI.Core.CoreWindow", "TopLevelWindowForOverflowXamlIsland", "NotifyIconOverflowWindow"}
    _WinEventProc = ctypes.WINFUNCTYPE(None, wintypes.HANDLE, wintypes.DWORD, wintypes.HWND, wintypes.LONG, wintypes.LONG,
                                       wintypes.DWORD, wintypes.DWORD)
    _user32.SetWinEventHook.restype = wintypes.HANDLE
    _user32.SetWinEventHook.argtypes = [wintypes.DWORD, wintypes.DWORD, wintypes.HMODULE, _WinEventProc, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD]
    _user32.UnhookWinEvent.argtypes = [wintypes.HANDLE]
    _user32.GetMessageW.argtypes = [ctypes.POINTER(wintypes.MSG), wintypes.HWND, wintypes.UINT, wintypes.UINT]
    _user32.PostThreadMessageW.argtypes = [wintypes.DWORD, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
    _user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
    _hook_thread = 0
    _hook_runner = None

    def _class(hwnd):
        buffer = ctypes.create_unicode_buffer(256)
        return buffer.value if hwnd and _user32.GetClassNameW(hwnd, buffer, 256) else ""

    def _hook():
        """前台每切换一次系统回调一次（不用轮询，也不漏掉任务栏那一下）：看不见的 VS Code 窗口刚到前台、前一个是系统界面 → 挪回来"""
        global _hook_thread
        _hook_thread = _kernel32.GetCurrentThreadId()
        previous = [_user32.GetForegroundWindow()]
        debug = os.environ.get("KITELINE_VSCREEN_DEBUG") == "1"

        def on_foreground(_hook_handle, _event, hwnd, _object, _child, _thread, _time):
            before, previous[0] = previous[0], hwnd
            try:
                if debug:
                    log.write("虚拟屏幕：前台 %s ← %s" % (_class(hwnd), _class(before)))
                if hwnd and _on and not _is_busy() and _hidden_editor(hwnd):
                    if _class(before) in SHELL_CLASSES:
                        threading.Thread(target=bring_back, args=(hwnd,), daemon=True).start()
                    elif not _user32.GetWindow(hwnd, 4):
                        # 不是用户选的（系统顺手给的焦点）：最小化，系统接着把焦点给下一个看得见的窗口
                        _user32.ShowWindow(hwnd, 6)   # SW_MINIMIZE
                        if debug:
                            log.write("虚拟屏幕：系统把焦点给了看不见的 VS Code，已最小化让回")
            except Exception as exc:  # noqa: BLE001
                log.write("虚拟屏幕：%s" % exc)

        callback = _WinEventProc(on_foreground)   # 留着引用，别被回收
        handle = _user32.SetWinEventHook(0x0003, 0x0003, None, callback, 0, 0, 0)   # EVENT_SYSTEM_FOREGROUND，进程外回调
        if not handle:
            log.write("虚拟屏幕：前台切换事件挂不上（%d）" % ctypes.get_last_error())
            return
        msg = wintypes.MSG()
        while _user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
            _user32.TranslateMessage(ctypes.byref(msg))
            _user32.DispatchMessageW(ctypes.byref(msg))
        _user32.UnhookWinEvent(handle)

    def _stop_hook():
        global _hook_thread
        if _hook_thread:
            _user32.PostThreadMessageW(_hook_thread, 0x0012, 0, 0)   # WM_QUIT
            _hook_thread = 0

    # MARK: 守护进程（Kiteline 意外退出时把窗口放回去）

    def _start_guard():
        global _guard
        if _guard and _guard.poll() is None:
            return
        if getattr(sys, "frozen", False):
            cmd = [sys.executable, "--vscreen-guard", str(os.getpid())]
        else:
            cmd = [sys.executable, "-m", "kiteline", "--vscreen-guard", str(os.getpid())]
        env = dict(os.environ)
        env["PYTHONPATH"] = os.path.dirname(os.path.dirname(os.path.abspath(__file__))) + os.pathsep + env.get("PYTHONPATH", "")
        for flags in (0x08000000 | 0x01000000, 0x08000000):   # CREATE_NO_WINDOW（+ 脱离作业对象，不随 Kiteline 一起被结束）
            try:
                _guard = subprocess.Popen(cmd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                          creationflags=flags)
                return
            except OSError:
                continue
        log.write("虚拟屏幕：守护进程没能启动")

    def _stop_guard():
        global _guard
        if _guard and _guard.poll() is None:
            _guard.terminate()
        _guard = None

    def guard_main(pid):
        """守护进程入口：等 Kiteline（pid）退出，把还在看不见的地方的 VS Code 窗口放回原处"""
        _kernel32.OpenProcess.restype = wintypes.HANDLE
        handle = _kernel32.OpenProcess(0x00100000, False, pid)   # SYNCHRONIZE
        if not handle:
            return 1
        _kernel32.WaitForSingleObject(handle, 0xFFFFFFFF)
        time.sleep(0.5)
        frames = _load().get("frames") or {}
        count = _restore_all(frames)
        if count:
            log.write("Kiteline 已退出，守护进程把 %d 个 VS Code 窗口放回原处" % count)
        return 0

elif config.IS_LINUX:
    # MARK: 窗口（Linux：经 Kiteline 的 GNOME 扩展藏起来、放回来）

    from . import shellext as _shell

    def _editors():
        return _shell.editor_windows()

    def visible_editor(window_id):
        return False

    def _yield_focus():
        pass   # 扩展自己处理：藏着的窗口在前台、又不是你选的，它会把焦点让给下一个看得见的窗口

    def _arrange(adopt=None, retile=False):
        """藏起 VS Code 的窗口。adopt：要藏的窗口（按标题挑，None = 全部）。返回 (藏了几个, 0)"""
        global _count
        windows = _shell.editor_windows()
        ids = [w["id"] for w in windows if not w.get("hidden") and (adopt is None or adopt(w.get("title") or ""))]
        moved = _shell.hide(ids) if ids else 0
        _count = sum(1 for w in windows if w.get("hidden")) + moved
        return moved, 0

    def _restore_all(frames, only=None):
        global _count
        count = _shell.show([only] if only else None)
        _count = 0 if only is None else max(0, _count - count)
        return count

    def bring_back(window_id):
        """用户要看这个窗口：只把它放回来"""
        if not _on:
            return False
        count = _restore_all({}, only=window_id)
        if count:
            log.write("虚拟屏幕：用户要看的 VS Code 窗口已移回主屏幕")
        return bool(count)

    def _after_busy():
        """Kiteline 操作完，前台还是藏着的 VS Code（只填不提交、弹了确认框）：放回来给人看"""
        if not _on or _is_busy():
            return
        front = _shell.focused()
        if front and any(w["id"] == front and w.get("hidden") for w in _shell.editor_windows()):
            bring_back(front)

    def _start_watching():
        global _watcher
        if not (_watcher and _watcher.is_alive()):
            _watcher = threading.Thread(target=_watch, daemon=True)
            _watcher.start()

    def _watch():
        """开着时每 10 秒续一次约（扩展 30 秒收不到就全部放回来），顺带数一下藏着几个窗口"""
        global _count
        while _on:
            _shell.keep(30)
            _count = sum(1 for w in _shell.editor_windows() if w.get("hidden"))
            for _ in range(20):
                if not _on:
                    return
                time.sleep(0.5)

    def _start_guard():
        pass   # 续约代替守护进程

    def _stop_guard():
        pass

    def _stop_hook():
        pass

    def guard_main(pid):
        return 0

else:
    def _editors():
        return []

    def visible_editor(hwnd):
        return False

    def _yield_focus():
        pass

    def _after_busy():
        pass

    def _arrange(adopt=None, retile=False):
        return 0, 0

    def _restore_all(frames, only=None):
        return 0

    def bring_back(hwnd):
        return False

    def _start_watching():
        pass

    def _stop_hook():
        pass

    def _start_guard():
        pass

    def _stop_guard():
        pass

    def guard_main(pid):
        return 0
