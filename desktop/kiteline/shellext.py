"""Linux（GNOME）：和 Kiteline 的 GNOME Shell 扩展（gnome_extension/kiteline@betac.cn）说话。

Wayland 下普通程序不能切换、隐藏别的窗口；GNOME 桌面本身（gnome-shell）可以，所以随 Kiteline 发一个 GNOME 扩展，
后台经会话总线调它（用系统自带的 gdbus 命令，不另装 Python 库）：
  - 投递前把 VS Code 切到前台、投完还回去（同 Mac / Windows 版；以前 Wayland 下只能要求你先切到 VS Code）
  - 「VS Code 在虚拟屏幕中运行」：藏起 VS Code 的窗口（见 vscreen.py）
扩展装在 ~/.local/share/gnome-shell/extensions/（用户级，不用管理员权限）。Wayland 下 GNOME 只在登录时加载扩展：
第一次装好要注销并重新登录一次才生效（X11 会话也一样）。只支持 GNOME 45 及以上（扩展用的是 45 起的写法）。
"""

import ast
import json
import os
import re
import shutil
import subprocess
import time

from . import config, log

UUID = "kiteline@betac.cn"
SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gnome_extension", UUID)
PATH = "/cn/betac/Kiteline"
IFACE = "cn.betac.Kiteline"
# VS Code 系编辑器的窗口类名（Wayland 下是应用 id，X11 下是 WM_CLASS）：新版 VS Code 是 com.microsoft.VSCode / code
EDITOR_CLASSES = {"code", "code-oss", "code - insiders", "com.microsoft.vscode", "com.microsoft.vscodeinsiders", "com.microsoft.vscode.insiders",
                  "vscodium", "com.vscodium.codium", "codium", "cursor", "windsurf"}

# 切窗口、藏窗口第 1 版就有：升级 Kiteline 后、重新登录之前（GNOME 里跑的还是旧版扩展）照常能用；截键（HoldKeys）要第 2 版
MIN_VERSION = 1
HOLD_VERSION = 2

_version = None
_loaded = (0.0, False)
_running = 0


def version():
    """随这一版 Kiteline 发的扩展的接口版本（metadata.json 的 version）"""
    global _version
    if _version is None:
        try:
            with open(os.path.join(SOURCE, "metadata.json"), encoding="utf-8") as handle:
                _version = int(json.load(handle)["version"])
        except (OSError, ValueError, KeyError):
            _version = 0
    return _version


def target():
    base = os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, "gnome-shell", "extensions", UUID)


def gnome():
    """当前是不是 GNOME 桌面（Ubuntu 是「ubuntu:GNOME」）"""
    return config.IS_LINUX and "gnome" in (os.environ.get("XDG_CURRENT_DESKTOP") or "").lower() and shutil.which("gnome-shell") is not None


def shell_major():
    try:
        out = subprocess.run(["gnome-shell", "--version"], capture_output=True, timeout=10).stdout.decode()
        match = re.search(r"(\d+)", out)
        return int(match.group(1)) if match else 0
    except (OSError, subprocess.SubprocessError):
        return 0


def applicable():
    """这台电脑能用这个扩展：GNOME 45 及以上、有 gdbus"""
    return gnome() and shutil.which("gdbus") is not None and shell_major() >= 45


def installed():
    """装上的是这一版（文件对得上；装了不等于已加载，要重新登录一次）"""
    try:
        with open(os.path.join(target(), "metadata.json"), encoding="utf-8") as handle:
            return int(json.load(handle).get("version", 0)) >= version()
    except (OSError, ValueError):
        return False


def loaded(cache=10):
    """扩展正在 GNOME 里运行（会话总线上答得上来）。结果缓存几秒：投递时连着问好几次"""
    global _loaded, _running
    at, ok = _loaded
    if time.time() - at < cache:
        return ok
    _running = 0
    if gnome() and shutil.which("gdbus"):
        try:
            _running = int(call("Version", timeout=2) or 0)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
            _running = 0
    ok = _running >= MIN_VERSION
    _loaded = (time.time(), ok)
    return ok


def can_hold():
    """GNOME 里跑着的扩展能截键（第 2 版起；装了新版、还没重新登录时不能）"""
    return loaded() and _running >= HOLD_VERSION


def status():
    """(状态, 说明)：ready / relogin（装了，要重新登录一次）/ missing（没装）/ unsupported（不是 GNOME 45+）"""
    if loaded():
        return "ready", ""
    if not applicable():
        return "unsupported", "需要 GNOME 45 或更新版本的桌面（如 Ubuntu 24.04）"
    if installed():
        return "relogin", "Kiteline 的 GNOME 扩展已安装，注销并重新登录一次后生效"
    return "missing", "需要安装 Kiteline 的 GNOME 扩展"


def install():
    """装到用户目录并启用（下次登录生效）。返回 (ok, message)"""
    global _loaded
    if not applicable():
        return False, "需要 GNOME 45 或更新版本的桌面（如 Ubuntu 24.04）"
    try:
        dest = target()
        if os.path.isdir(dest):
            shutil.rmtree(dest)
        shutil.copytree(SOURCE, dest)
    except OSError as exc:
        return False, "安装 Kiteline 的 GNOME 扩展失败：%s" % exc
    _enable()
    _loaded = (0.0, False)
    log.write("已安装 Kiteline 的 GNOME 扩展 v%d → %s" % (version(), target()))
    if loaded(cache=0) and _running >= version():
        return True, "已更新 Kiteline 的 GNOME 扩展"
    return True, "已安装 Kiteline 的 GNOME 扩展，注销并重新登录一次后生效"


def _enable():
    """加进 GNOME 的已启用扩展列表（扩展还没被 GNOME 认出来时 gnome-extensions enable 会报不存在，直接改设置）"""
    try:
        subprocess.run(["gnome-extensions", "enable", UUID], capture_output=True, timeout=10)
        for key, add in (("enabled-extensions", True), ("disabled-extensions", False)):
            raw = subprocess.run(["gsettings", "get", "org.gnome.shell", key], capture_output=True, timeout=10).stdout.decode().strip()
            items = ast.literal_eval(raw.replace("@as ", "")) if raw else []
            changed = [i for i in items if i != UUID] + ([UUID] if add else [])
            if changed != items:
                subprocess.run(["gsettings", "set", "org.gnome.shell", key, str(changed)], capture_output=True, timeout=10)
    except (OSError, ValueError, SyntaxError, subprocess.SubprocessError) as exc:
        log.write("启用 Kiteline 的 GNOME 扩展失败：%s" % exc)


def ensure_current():
    """装过旧版的升到随这一版发的（启动时调；新文件下次登录生效）"""
    if os.path.isdir(target()) and not installed() and applicable():
        install()


# MARK: 会话总线

def _parse(text):
    """gdbus 打出来的 GVariant 文本：「(uint32 1,)」「('[...]',)」「(true,)」「()」→ Python 值（只有一个返回值时取它）"""
    text = text.strip()
    if text in ("()", ""):
        return None
    if not text.startswith(("('", '("')):
        # 数字、布尔：去掉类型前缀、换成 Python 写法（字符串返回值里的 true / false 不能动，所以只在这里换）
        text = re.sub(r"\b(uint64|uint32|int64|int32|byte|uint16|int16)\s+", "", text)
        text = re.sub(r"\btrue\b", "True", re.sub(r"\bfalse\b", "False", text))
    value = ast.literal_eval(text)
    return value[0] if isinstance(value, tuple) and len(value) == 1 else value


def call(method, *args, timeout=3):
    """调扩展的一个方法；args 是 GVariant 文本形式的参数（如 "uint64 123"、"[uint64 1, uint64 2]"）"""
    cmd = ["gdbus", "call", "--session", "--dest", "org.gnome.Shell", "--object-path", PATH,
           "--method", "%s.%s" % (IFACE, method), "--timeout", str(int(timeout))] + list(args)
    result = subprocess.run(cmd, capture_output=True, timeout=timeout + 2)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode("utf-8", "replace").strip()[-200:] or "gdbus 退出码 %d" % result.returncode)
    return _parse(result.stdout.decode("utf-8", "replace"))


def _ids(ids):
    return "[%s]" % ", ".join("uint64 %d" % int(i) for i in ids) if ids else "@at []"


def windows():
    """[{id, wmClass, app, title, pid, hidden, focused, minimized}]；扩展没在跑返回 []"""
    try:
        return json.loads(call("Windows") or "[]")
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        return []


def is_editor(window):
    return (window.get("wmClass") or "").lower() in EDITOR_CLASSES or (window.get("app") or "").lower() in EDITOR_CLASSES


def editor_windows():
    return [w for w in windows() if is_editor(w)]


def focused():
    try:
        return int(call("Focused") or 0) or None
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        return None


def activate(window_id):
    try:
        return bool(call("Activate", "uint64 %d" % int(window_id)))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        return False


def hide(ids):
    try:
        return int(call("Hide", _ids(ids)) or 0) if ids else 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        return 0


def show(ids=None):
    """放回来；ids 不给 = 全部"""
    try:
        return int(call("Show", _ids(ids or [])) or 0)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        return 0


def keep(seconds):
    try:
        call("Keep", "uint32 %d" % int(seconds))
        return True
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        return False


def hold_keys(seconds):
    """投递期间让桌面暂时接管键盘（见扩展的 HoldKeys）；接管不了返回 False"""
    try:
        return bool(call("HoldKeys", "uint32 %d" % int(seconds)))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        return False


def keys_idle():
    """截着键盘时用户多久没按键了（秒）"""
    try:
        return int(call("KeysIdle") or 0) / 1000
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        return 3600.0


def pause_keys():
    try:
        call("PauseKeys")
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        pass


def resume_keys():
    try:
        return bool(call("ResumeKeys"))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        return False


def release_keys(replay):
    """放开键盘，replay = 把截下的键补发给现在的前台窗口。返回截下了几次按键"""
    try:
        return int(call("ReleaseKeys", "true" if replay else "false") or 0)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        return 0


def title_matches(title, names):
    """VS Code 窗口标题「文件 — 文件夹 — Visual Studio Code」里有没有这些文件夹名（远端的后面跟着「[SSH: 主机]」）"""
    parts = [p.strip() for p in (title or "").replace(" - ", " — ").split(" — ")]
    return any(part == name or part.startswith(name + " [") for part in parts for name in names)


def find_editor(folders):
    """打开着 folders（VS Code 配套扩展报的文件夹）的 VS Code 窗口；找不到返回 None"""
    names = [os.path.basename(f.rstrip("/\\")) for f in folders or [] if f]
    if not names:
        return None
    matches = [w for w in editor_windows() if title_matches(w.get("title"), names)]
    return matches[-1] if matches else None


# MARK: 投递时切前台（同 Mac 版 FrontReturn、Windows 版 delivery_win.capture_front / return_front）

def raise_editor(folders):
    """把打开着 folders 的 VS Code 窗口切到前台。返回 (原来的前台, 切过去的窗口)；切不了返回 (None, None)"""
    if not loaded():
        return None, None
    window = find_editor(folders)
    if not window:
        return None, None
    previous = focused()
    if previous == window["id"]:
        return None, None
    if not activate(window["id"]):
        return None, None
    return previous, window["id"]


def restore(previous, raised, delay=0.4):
    """投完把前台还给 previous：等 delay 秒（回车要先落进 VS Code），前台还是切过去的那个窗口才还（你自己点过别处就不动）"""
    if not previous or not raised or previous == raised:
        return
    time.sleep(delay)
    if focused() == raised:
        activate(previous)


def capture_front():
    """新任务（app.launch_session）切 VS Code 之前的前台，做完还回去。本来就在看得见的 VS Code 里的不用还：返回 None"""
    if not loaded():
        return None
    front = focused()
    if not front:
        return None
    window = next((w for w in windows() if w["id"] == front), None)
    if window and is_editor(window) and not window.get("hidden"):
        return None
    return front


def return_front(previous, delay=0.4):
    """把前台还给 previous：前台已经不是 VS Code（你自己切走了）、previous 已经关了，都不动"""
    if not previous:
        return
    time.sleep(delay)
    current = focused()
    if not current or current == previous:
        return
    listed = {w["id"]: w for w in windows()}
    if previous in listed and current in listed and is_editor(listed[current]):
        log.write("新任务做完，前台还给原来的窗口")
        activate(previous)


def refocus(window_id):
    """GNOME 已经把焦点给了这个 VS Code 窗口、VS Code 自己却没认（GNOME Wayland 下刚用 code 命令打开过项目时会这样，10-24 实测）：
    先把焦点给另一个看得见的窗口、再切回来，VS Code 就认了"""
    others = [w for w in windows() if w["id"] != window_id and not w.get("hidden") and not w.get("minimized")]
    if not others:
        return False
    activate(others[0]["id"])
    time.sleep(0.3)
    return activate(window_id)


def ensure_focus(window, folders, wait=1.8):
    """VS Code 配套扩展的窗口（bridge.Window）报的焦点和 GNOME 对不上时补一下（见 refocus）。返回最后 VS Code 认不认"""
    if not loaded():
        return False
    target = find_editor(folders)
    if not target or focused() != target["id"]:
        return False
    refocus(target["id"])
    deadline = time.time() + wait
    while time.time() < deadline:
        time.sleep(0.15)
        if window.call("state").get("focused"):
            return True
    return False
