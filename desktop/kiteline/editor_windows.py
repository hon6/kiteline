"""项目的会话都在后台运行以后，关掉它用不着的 VS Code 窗口（同 Mac 版 Sources/EditorWindows.swift，判断规则一样）。

11-19 反馈：「已经转到终端后台的项目，可以关掉 vscode 吗？开了好多，系统资源都不够了」。

只在 Kiteline 刚对这个项目做完动作时看一次，不巡检——用户自己开着看代码的窗口不碰：
- 把 VS Code 里的会话转到了后台运行（app.move_to_background）；
- 在后台新建 / 恢复了会话（app.launch_hosted）：只关已经最小化的窗口（Linux 上读不到最小化状态，这一条不关）；
- 关掉了 VS Code 里的会话（delivery.close），而这个项目还有会话在后台运行。

关之前都要过 obstacle 这一关（宁可不关）：窗口里没有别的会话在运行、没有未保存的改动、不是用户正看着的、
不是 Kiteline 三分钟内刚打开的；有会话在 VS Code 里运行却对不上任何窗口时，同一类（本机 / 远端）的窗口一个都不关。

怎么认窗口、怎么关：
- Windows：按窗口标题认项目，给窗口发 WM_CLOSE（不用切到前台，最小化的也能关）。未保存的改动只看得到当前标签的（标题开头的「●」），
  别的标签有未保存改动时 VS Code 自己会弹保存框拦住，改动不会丢。
- Linux：经 VS Code 里的 Kiteline 配套扩展（bridge.py，1.0.4 起）：它报窗口打开的文件夹、有没有未保存的文件，关窗口也由它做。
  没装扩展、窗口里的扩展还是旧版的，认不出来，不碰。

开关 mobile.hostedCloseEditor（默认开）；idle / close_idle 是设置页里「关闭没有会话在运行的窗口」。
"""

import ipaddress
import os
import threading
import time

from . import config, delivery, log, remotessh

# 测试实例（隔离的配置目录、dry-run、CCPULSE_TEST_NO_EDITOR）一个窗口都不碰：它里面没有用户真实的会话，
# 在它看来用户的窗口全是「没有会话在运行」。要测这个功能就设 KITELINE_TEST_EDITOR_WINDOWS=1（只在测试机上用）
_TESTING = (os.environ.get("CCPULSE_TEST_NO_EDITOR") == "1" or delivery.DRY_RUN
            or bool(os.environ.get("KITELINE_CONFIG_DIR") or os.environ.get("CCPULSE_CONFIG_DIR")))
DISABLED = [_TESTING and os.environ.get("KITELINE_TEST_EDITOR_WINDOWS") != "1"]

APP = [None]         # App 起来时接上（settle 没传 app 时用它）
BACKEND = [None]     # 测试时换成假的窗口列表：() → [Window]
# 测客户端设置页、接口用：这个文件里一行一个窗口标题，当作「没有会话在运行的窗口」，「关闭」就是把文件清空（不碰任何真窗口）
TEST_IDLE = os.environ.get("KITELINE_TEST_EDITOR_IDLE")
SETTLE_DELAY = [3.0]   # 等几秒再看：转到后台、关闭会话时要切到 VS Code 按键，等它把前台还回去，快照也跟上
CLOSE_WAIT = [1.5]     # 按了关闭以后等多久再看窗口还在不在

_lock = threading.Lock()
_opened = {}           # Kiteline 刚替用户打开窗口的项目目录 → 时刻（会话过一会儿才出现在里面，这三分钟不当它是空的）
OPENED_FOR = 180

OBSTACLES = {
    "watched": "窗口正在前台使用",
    "edited": "窗口中有未保存的改动",
    "opened": "窗口刚刚打开",
    "foreign": "不是本机或 SSH 远端的窗口",
    "occupied": "窗口中还有会话在运行",
    "unplaced": "这台电脑上有会话在 VS Code 中运行，但无法确定在哪个窗口",
}


class Window:
    """一个 VS Code 窗口。
    folders：配套扩展报的打开的文件夹（Linux）；None = 按标题认（Windows）
    place：("local", None) / ("ssh", 主机) / ("other", None)（WSL、容器这些，看不到里面的会话，不碰）
    minimized：True / False；None = 读不到"""

    def __init__(self, title, place, folders=None, minimized=None, edited=False, watched=False, close=None, alive=None):
        self.title, self.place, self.folders = title, place, folders
        self.minimized, self.edited, self.watched = minimized, edited, watched
        self.close, self.alive = close, alive


# MARK: 窗口

def place_of_title(title):
    """窗口标题里项目那段后面的方括号：[SSH: 主机] → ("ssh", 主机)；别的带冒号的（WSL、容器、隧道）→ other；没有 → local"""
    project = delivery.title_place(title)
    if project.endswith("]") and " [" in project:
        tag = project[project.rindex(" [") + 2:-1]
        if tag.startswith("SSH: "):
            return "ssh", tag[len("SSH: "):].strip()
        if ": " in tag:
            return "other", None
    return "local", None


def _windows_win():
    import ctypes
    from ctypes import wintypes
    from . import delivery_win as win
    user32 = win.user32
    user32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
    user32.IsIconic.argtypes = [wintypes.HWND]
    user32.IsWindow.argtypes = [wintypes.HWND]
    user32.GetForegroundWindow.restype = wintypes.HWND
    front = user32.GetForegroundWindow()
    items = []
    for hwnd, title, _scheme in win.editor_windows():
        items.append(Window(title, place_of_title(title), minimized=bool(user32.IsIconic(hwnd)),
                            edited=title.lstrip().startswith("●"), watched=(hwnd == front),
                            close=lambda h=hwnd: bool(user32.PostMessageW(h, 0x0010, 0, 0)),   # WM_CLOSE
                            alive=lambda h=hwnd: bool(user32.IsWindow(h))))
    return items


def _windows_bridge():
    from . import bridge
    items = []
    for window in bridge.windows():
        state = window.state
        if not state.get("closable"):   # 窗口里的配套扩展还是旧版（不报未保存、不认关闭）：等它重新加载用上新版
            continue
        folders = [f for f in (state.get("folders") or []) if f]
        remote = state.get("remote")
        if not remote:
            place = ("local", None)
        elif remote == "ssh-remote":
            place = ("ssh", remotessh.host_of_authority(state.get("authority") or "")[0])
        else:
            place = ("other", None)
        name = os.path.basename(folders[0].rstrip("/")) if folders else "（未打开文件夹）"
        title = "%s [SSH: %s]" % (name, place[1]) if place[0] == "ssh" and place[1] else name

        def close(target=window):
            try:
                target.call("close")
                return True
            except (OSError, ValueError):
                return False

        def alive(path=window.path):
            try:
                return bool(bridge.call(path, {"cmd": "state"}, timeout=3).get("ok"))
            except (OSError, ValueError):
                return False
        items.append(Window(title, place, folders=folders, minimized=None, edited=bool(state.get("dirty")),
                            watched=bool(state.get("focused")), close=close, alive=alive))
    return items


def windows():
    if DISABLED[0]:
        return []
    if BACKEND[0] is not None:
        return list(BACKEND[0]())
    try:
        return _windows_win() if config.IS_WINDOWS else _windows_bridge()
    except Exception as exc:  # noqa: BLE001
        log.write("读取 VS Code 窗口失败：%s" % exc)
        return []


# MARK: 会话对不对得上窗口

def _norm(path):
    return (path or "").replace("\\", "/").rstrip("/")


def _host_key(host):
    """主机写法比对用：去掉用户名、不分大小写（别名和 IP 这种对不上的，按「不是同一台」处理——只用在宁可少关的地方）"""
    return (host or "").split("@")[-1].strip().lower()


def _surely_other(one, other):
    """两边写的都是 IP 地址、又不一样：肯定不是同一台（别名、域名可能指同一台，不敢这么说）"""
    try:
        return ipaddress.ip_address(_host_key(one)) != ipaddress.ip_address(_host_key(other))
    except ValueError:
        return False


def _same_place(window, session, any_host):
    kind, host = window.place
    if kind == "local":
        return not session["remote"]
    if kind == "ssh":
        if not session["remote"]:
            return False
        if any_host:   # 宁可多对上：只有两边都是 IP 且不同才排除
            return not _surely_other(host, session.get("host"))
        return _host_key(host) == _host_key(session.get("host"))
    return False


def matches(window, session, exact, any_host=False):
    """会话对不对得上这个窗口。exact：会话的目录就是这个窗口的项目；否则会话目录在窗口的文件夹里面也算（宁可多对上）。
    any_host：远端窗口不细比主机（判断「窗口里还有没有会话」时用：主机写法对不上也当它在里面，只有两边都是 IP 且不同才排除）"""
    if not _same_place(window, session, any_host):
        return False
    cwd = _norm(session.get("cwd"))
    if not cwd:
        return False
    if window.folders is not None:
        for folder in map(_norm, window.folders):
            if folder and (cwd == folder or (not exact and cwd.startswith(folder + "/"))):
                return True
        return False
    names = [p for p in cwd.split("/") if p and not p.endswith(":")]
    if not names:
        return False
    return any(delivery.window_matches(window.title, name, session["remote"]) for name in ([names[-1]] if exact else names[::-1]))


def holders(session, every):
    """这个会话在哪些窗口里：从会话目录最深的一级往上找，第一个对得上窗口的那一级里对上的都算（同投递找窗口的办法）。
    这样开着主目录窗口、又开着项目窗口时，项目里的会话只算在项目窗口头上。远端不细比主机（见 matches 的 any_host）"""
    cwd = _norm(session.get("cwd"))
    if not cwd:
        return []
    here = [w for w in every if _same_place(w, session, True)]
    by_folder = [w for w in here if w.folders is not None]
    best, depth = [], -1
    for window in by_folder:
        for folder in map(_norm, window.folders):
            if folder and (cwd == folder or cwd.startswith(folder + "/")) and len(folder) >= depth:
                best = ([] if len(folder) > depth else best) + [window]
                depth = len(folder)
    if best:
        return best
    by_title = [w for w in here if w.folders is None]
    for name in [p for p in cwd.split("/") if p and not p.endswith(":")][::-1]:
        hit = [w for w in by_title if delivery.window_matches(w.title, name, session["remote"])]
        if hit:
            return hit
    return []


# MARK: Kiteline 刚打开的窗口

def note_opened(cwd, remote=False, host=None):
    if not cwd:
        return
    now = time.time()
    with _lock:
        for key in [k for k, (_, at) in _opened.items() if now - at > OPENED_FOR]:
            _opened.pop(key, None)
        _opened[(_norm(cwd), bool(remote), _host_key(host))] = ({"cwd": cwd, "remote": bool(remote), "host": host}, now)


def _just_opened(window):
    now = time.time()
    with _lock:
        recent = [session for session, at in _opened.values() if now - at < OPENED_FOR]
    return any(matches(window, session, exact=False, any_host=True) for session in recent)


# MARK: 能不能关

def sessions_of(app):
    """各会话里判断窗口用得着的那部分：detached = 关掉 VS Code 窗口也不受影响（后台运行的、tmux 里的）；
    inEditor = 在这台电脑的 VS Code 里运行的 Claude Code（它一定在某个窗口里）"""
    from . import store
    hosts = {entry.get("id"): entry.get("sshHost") for entry in app.cfg.sources}
    with app.store.lock:
        records = list(app.store.records)
    out = []
    for record in records:
        if record.kind == "kiteline":
            continue
        snap = record.snap
        detached = bool(snap.get("hosted")) or bool(snap.get("tmuxPane"))
        # 本机会话的 claude 跑在 VS Code 远程连接的服务端里：窗口在连过来的那台电脑上，不在这台
        elsewhere = record.kind == "local" and delivery.remote_editor(snap.get("pid"))
        out.append({"key": record.key, "cwd": snap.get("cwd") or "", "remote": record.kind == "ssh", "host": hosts.get(record.source_id),
                    "detached": detached,
                    "inEditor": not detached and not elsewhere and (snap.get("agent") or "claude-code") == "claude-code" and store.is_vscode(snap)})
    return out


def machines_of(app):
    """连着的远端电脑（看得到上面有没有会话）"""
    out = []
    for entry in app.cfg.sources:
        if entry.get("kind") != "ssh" or entry.get("enabled") is False:
            continue
        source = app.store.source(entry.get("id"))
        if source is not None and getattr(source, "live", False):
            out.append({"key": "", "cwd": "", "remote": True, "host": entry.get("sshHost"), "detached": True, "inEditor": False})
    return out


def obstacle(window, sessions, every, skip=None):
    """不能关的原因（OBSTACLES 的键）；None = 关了不影响任何会话、不丢改动。skip：刚转走 / 刚关掉的那个会话（快照可能还没跟上）"""
    if window.watched:
        return "watched"
    if window.edited:
        return "edited"
    if _just_opened(window):
        return "opened"
    if window.place[0] == "other":
        return "foreign"
    remote = window.place[0] == "ssh"
    running = [s for s in sessions if not s["detached"] and s["key"] != skip and s["remote"] == remote]
    placed = [(s, holders(s, every)) for s in running]
    if any(window in where for _, where in placed):
        return "occupied"
    # 多文件夹工作区、标题还没出来的重连中窗口，会话按标题对不上：它可能就在这个窗口里
    if any(s["inEditor"] and not where for s, where in placed):
        return "unplaced"
    return None


def _close(items, why):
    closed, left, pressed = [], [], []
    for window in items:
        if window.close and window.close():
            pressed.append(window)
        else:
            log.write("关闭 VS Code 窗口「%s」未成功" % window.title)
            left.append(window)
    if pressed:
        time.sleep(CLOSE_WAIT[0])
    for window in pressed:
        if window.alive and window.alive():
            log.write("VS Code 窗口「%s」没有关闭：VS Code 可能在等待确认" % window.title)
            left.append(window)
        else:
            log.write("已关闭 VS Code 窗口「%s」：%s" % (window.title, why))
            closed.append(window)
    return closed, left


# MARK: 自动关

def enabled(app):
    return bool(app.cfg.mobile.get("hostedCloseEditor", True))


def settle(app, trigger, cwd, source_id, key=None, wait=True):
    """Kiteline 刚对 source_id 这台电脑上 cwd 这个项目做完动作：看看它的 VS Code 窗口是不是用不着了。
    trigger：moved（会话转到了后台）/ started（在后台新建、恢复了会话）/ closed（关掉了 VS Code 里的会话）；key：这个会话。
    wait=False 时当场做完并返回关掉的窗口（测试用）"""
    app = app or APP[0]
    if app is None or DISABLED[0] or not enabled(app):
        return []
    entry = next((e for e in app.cfg.sources if e.get("id") == source_id), None)
    if entry is None or entry.get("kind", "local") == "kiteline":
        return []
    project = {"key": "", "cwd": cwd, "remote": entry.get("kind") == "ssh", "host": entry.get("sshHost"), "detached": True, "inEditor": False}
    why = {"moved": "会话已转到后台运行", "started": "会话已在后台运行，窗口处于最小化",
           "closed": "窗口中的会话已关闭，项目的其余会话在后台运行"}[trigger]

    def run():
        sessions = sessions_of(app)
        every = windows()
        wanted = []
        for window in every:
            if not matches(window, project, exact=True):
                continue
            if trigger == "started" and window.minimized is not True:
                continue
            if trigger == "closed" and not any(s["detached"] and s["key"] != key and matches(window, s, exact=True) for s in sessions):
                continue
            reason = obstacle(window, sessions, every, skip=key if trigger != "started" else None)
            if reason is None:
                wanted.append(window)
            elif reason != "occupied":   # 窗口里还有会话是常事，不记；别的原因记一笔，用户问「怎么没关」时查得到
                log.write("VS Code 窗口「%s」未自动关闭：%s" % (window.title, OBSTACLES[reason]))
        return _close(wanted, why)[0]

    if not wait:
        return run()

    def later():
        time.sleep(SETTLE_DELAY[0])
        try:
            run()
        except Exception as exc:  # noqa: BLE001
            log.write("自动关闭 VS Code 窗口出错：%s" % exc)
    threading.Thread(target=later, name="editor-windows", daemon=True).start()
    return []


# MARK: 手动一次关掉

def _idle(app):
    """没有会话在运行的窗口：远端窗口要连着那台电脑（看得到上面的会话），本机窗口要这个项目有会话在后台运行
    （本机上认不出项目的窗口可能是正在重连的远端窗口，不算）"""
    sessions, machines, every = sessions_of(app), machines_of(app), windows()
    out = []
    for window in every:
        if obstacle(window, sessions, every) is not None:
            continue
        if window.place[0] == "ssh":
            if any(_same_place(window, machine, False) for machine in machines):
                out.append(window)
        elif window.place[0] == "local":
            if any(s["detached"] and matches(window, s, exact=True) for s in sessions):
                out.append(window)
    return out


def shown(title):
    """给界面看的名字：标题里项目那一段（「文件 - 项目 [SSH: 主机] - Visual Studio Code」→「项目 [SSH: 主机]」）"""
    return delivery.title_place(title) or title


def idle(app):
    """可以关的窗口（设置页列出来）：各窗口的项目名"""
    if TEST_IDLE:
        with open(TEST_IDLE, encoding="utf-8") as handle:
            return [line.strip() for line in handle if line.strip()]
    return [shown(window.title) for window in _idle(app)]


def close_idle(app):
    """关掉这些窗口；返回（关掉的, 没关掉的），都是项目名"""
    if TEST_IDLE:
        titles = idle(app)
        open(TEST_IDLE, "w", encoding="utf-8").close()
        return titles, []
    closed, left = _close(_idle(app), "窗口中没有会话在运行（用户在设置中关闭）")
    return [shown(w.title) for w in closed], [shown(w.title) for w in left]
