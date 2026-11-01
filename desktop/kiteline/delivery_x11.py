"""Linux 桌面上的投递：X11（含 XWayland 里的 VS Code）用 xdotool + xclip / xsel。

纯 Wayland 会话不允许程序模拟按键、切窗口：这种情况下 VS Code 里的会话只能看、不能远程发消息，
终端里的 CLI 会话放进 tmux 后照样能发（走 watcher 的 tmux_send）。
"""

import os
import shutil
import subprocess
import time

from . import delivery, log
from .delivery import Outcome

EDITOR_CLASSES = (("code", "vscode"), ("code-insiders", "vscode-insiders"), ("vscodium", "vscodium"), ("cursor", "cursor"))


def _run(args, input_text=None, timeout=5):
    return subprocess.run(args, input=input_text.encode("utf-8") if input_text is not None else None,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout)


def has_display():
    return bool(os.environ.get("DISPLAY"))


def available():
    return has_display() and shutil.which("xdotool") is not None


def why_unavailable():
    if not os.environ.get("DISPLAY"):
        if os.environ.get("WAYLAND_DISPLAY"):
            return "当前是 Wayland 会话，无法模拟按键操作 VS Code。可改用 X11 会话登录，或在 tmux 中运行 claude"
        return "这台电脑没有图形界面（DISPLAY 为空），无法操作 VS Code。可在 tmux 中运行 claude"
    if not shutil.which("xdotool"):
        return "缺少 xdotool，无法操作 VS Code（就绪检查里可以一键安装）"
    # 消息是粘贴进去的：没有剪贴板工具时按键能按、文字发不出去，就绪检查要提前说
    if not (shutil.which("xclip") or shutil.which("xsel")):
        return "缺少 xclip（或 xsel），无法把消息粘贴进 VS Code（就绪检查里可以一键安装）"
    return ""


def editor_windows():
    found = []
    for klass, scheme in EDITOR_CLASSES:
        try:
            out = _run(["xdotool", "search", "--onlyvisible", "--class", klass]).stdout.decode()
        except (OSError, subprocess.SubprocessError):
            continue
        for wid in out.split():
            try:
                title = _run(["xdotool", "getwindowname", wid]).stdout.decode("utf-8", "replace").strip()
            except (OSError, subprocess.SubprocessError):
                continue
            if title:
                found.append((wid, title, scheme))
    return found


def foreground_editor_title():
    try:
        wid = _run(["xdotool", "getactivewindow"]).stdout.decode().strip()
        if not wid:
            return None
        klass = _run(["xdotool", "getwindowclassname", wid]).stdout.decode().strip().lower()
        if not any(klass.startswith(k) for k, _ in EDITOR_CLASSES):
            return None
        return _run(["xdotool", "getwindowname", wid]).stdout.decode("utf-8", "replace").strip()
    except (OSError, subprocess.SubprocessError):
        return None


def _is_editor(wid):
    klass = _run(["xdotool", "getwindowclassname", wid]).stdout.decode().strip().lower()
    return any(klass.startswith(k) for k, _ in EDITOR_CLASSES)


def capture_front():
    """投递前的前台窗口，投完还回去（同 Mac 版 FrontReturn）。本来就在 VS Code 里的不用还：返回 None"""
    try:
        wid = _run(["xdotool", "getactivewindow"]).stdout.decode().strip()
        return None if not wid or _is_editor(wid) else wid
    except (OSError, subprocess.SubprocessError):
        return None


def return_front(wid, delay=0.4):
    """把前台还给投递前的窗口。回车要先落进 VS Code 再切；前台已经不是 VS Code（用户自己切走了）就不动"""
    if not wid:
        return
    time.sleep(delay)
    try:
        front = _run(["xdotool", "getactivewindow"]).stdout.decode().strip()
        if not front or front == wid or not _is_editor(front):
            return
        log.write("投递完成，前台还给原来的窗口")
        _run(["xdotool", "windowactivate", wid], timeout=5)
    except (OSError, subprocess.SubprocessError):
        pass


def set_clipboard(text):
    for tool in (["xclip", "-selection", "clipboard"], ["xsel", "--clipboard", "--input"]):
        if shutil.which(tool[0]):
            try:
                subprocess.run(tool, input=text.encode("utf-8"), timeout=5, check=True)
                return True
            except (OSError, subprocess.SubprocessError):
                continue
    return False


def _key(name):
    _run(["xdotool", "key", "--clearmodifiers", name])


def _focus_session(record):
    """切到会话所在窗口、开扩展 URI 切到它的标签。返回 (成功, 会弹确认框)，同 Windows 版"""
    from . import remotessh
    windows = editor_windows()
    if not windows:
        return False, False
    cwd = (record.snap.get("cwd") or "").rstrip("/")
    target = None
    for folder in [p for p in cwd.split("/") if p][::-1]:
        target = next((w for w in windows if delivery.window_matches(w[1], folder, record.kind == "ssh")), None)
        if target:
            break
    if not target and len(windows) == 1:
        target = windows[0]
    if not target:
        log.write("找不到会话「%s」所在的 VS Code 窗口，放弃投递" % record.snap.get("name"))
        return False, False
    wid, _, scheme = target
    _run(["xdotool", "windowactivate", "--sync", wid], timeout=5)
    time.sleep(0.4)
    if not (record.snap.get("title") or "").strip():
        # 还没发过消息的会话扩展打不开，会另开空白标签：只切窗口（同 Windows 版）
        log.write("会话「%s」尚未发过消息：只切到窗口，不开 URI" % record.snap.get("name"))
        return True, False
    trusted, wrote = remotessh.trust_claude_links()
    if wrote:
        time.sleep(1.0)   # 刚写进设置的，VS Code 要一会儿才读到
    link = delivery.editor_link(record.snap.get("sessionId"), scheme)
    opener = shutil.which("code") if scheme == "vscode" else None
    cmd = [opener, "--open-url", link] if opener else [shutil.which("xdg-open") or "xdg-open", link]
    log.write("打开 %s://anthropic.claude-code/open（会话 %s）" % (scheme, record.snap.get("name")))
    subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return True, not trusted


def _front_is_editor():
    try:
        wid = _run(["xdotool", "getactivewindow"]).stdout.decode().strip()
        return bool(wid) and _is_editor(wid)
    except (OSError, subprocess.SubprocessError):
        return True


def send_vscode(prompt, record, submit, siblings, check_waiting=True):
    """发完把前台还给用户原来在用的窗口；只填不提交的不还（用户要到 VS Code 里再看一眼）。
    要替用户切前台时，这一会儿用户手上还在打的字先截下来，还回去以后补上（见 keyhold）"""
    from . import keyhold
    front = capture_front()
    hold = keyhold.start() if front else keyhold.Hold()
    try:
        outcome = _send_vscode(prompt, record, submit, siblings, hold, check_waiting)
        if (submit or not outcome.ok) and not outcome.keep_front:
            return_front(front, 0.9 if prompt.startswith("/") and "\n" not in prompt else 0.4)
    finally:
        hold.end(replay=not _front_is_editor())
    return outcome


def _front_problem(record, siblings):
    """前台能不能往这个会话里输入（None = 可以）。开启了「读取 VS Code 弹框」的，要打开 claude.ai 的 Artifact 链接弹的
    「打开外部网站」框先替用户取消（见 alerts.artifact_dialog）：不然回车会按到框里默认的「打开」"""
    from . import alerts
    if alerts.cancel_artifact_dialogs():
        time.sleep(0.3)
    return delivery.front_problem(foreground_editor_title(), record, siblings)


def _send_vscode(prompt, record, submit, siblings, hold, check_waiting=True):
    reason = why_unavailable()
    if reason:
        return Outcome(False, False, reason)
    focused, confirming = _focus_session(record)
    if not focused:
        return Outcome(False, False, "未找到该会话所在的 VS Code 窗口（VS Code 未运行，或打开了多个窗口而无法确定目标）")
    if confirming:
        return Outcome(False, False, delivery.LINK_CONFIRMATION, keep_front=True)
    time.sleep(1.0)
    problem = _front_problem(record, siblings)
    if problem:
        return Outcome(False, False, problem)
    if not set_clipboard(prompt):
        return Outcome(False, False, "缺少 xclip / xsel，无法粘贴：在手机「设置 → 就绪检查」里一键安装")
    hold.settle()
    hold.pause()   # 自己按的键也会被抓走：粘贴、回车前先放开（等用户停手，别让正在打的字漏进去）
    from . import alerts
    alerts.note_paste(prompt)   # 万一粘进了终端，弹的「粘贴到终端?」框认得出、替用户取消（见 alerts.stray_paste_dialog）
    _key("ctrl+v")
    time.sleep(0.35)
    if not submit:
        return Outcome(True, False, "已填入输入框")
    problem = _front_problem(record, siblings)
    if problem:
        return Outcome(False, False, "文字已粘贴，但提交时出现问题：" + problem)
    midway = check_waiting and delivery.waiting_midway(record)
    if midway:
        return Outcome(True, False, midway)
    _key("Return")
    if prompt.startswith("/") and "\n" not in prompt:
        time.sleep(0.5)
        _key("Return")
    time.sleep(0.05)
    hold.resume()
    return Outcome(True, True, "已提交")


def press_vscode(key, times, record, siblings):
    from . import keyhold
    front = capture_front()
    hold = keyhold.start() if front else keyhold.Hold()
    try:
        outcome = _press_vscode(key, times, record, siblings, hold)
        if not outcome.keep_front:
            return_front(front)
    finally:
        hold.end(replay=not _front_is_editor())
    return outcome


def _press_vscode(key, times, record, siblings, hold):
    reason = why_unavailable()
    if reason:
        return Outcome(False, False, reason)
    focused, confirming = _focus_session(record)
    if not focused:
        return Outcome(False, False, "未找到该会话所在的 VS Code 窗口（VS Code 未运行，或打开了多个窗口而无法确定目标）")
    if confirming:
        return Outcome(False, False, delivery.LINK_CONFIRMATION_PRESS, keep_front=True)
    time.sleep(0.9)
    problem = _front_problem(record, siblings)
    if problem:
        return Outcome(False, False, problem.replace("此消息未发送", "未按下按键"))
    name = {"enter": "Return", "return": "Return", "esc": "Escape", "escape": "Escape", "shift+tab": "shift+Tab"}.get(key, key)
    hold.settle()
    hold.pause()
    for _ in range(times):
        _key(name)
        time.sleep(0.25)
    hold.resume()
    return Outcome(True, False, "已按下 %s" % key)
