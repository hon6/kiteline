"""Linux：经 VS Code 里的 Kiteline 配套扩展投递（Wayland、X11 都走这条）。

扩展在 VS Code 里面切到会话、报告窗口在不在前台和当前标签、聚焦输入框、粘贴；回车 / 确认框选项用 uinput 虚拟键盘按
（X11 上没开 uinput 权限时用 xdotool）。VS Code 不在前台（比如正在 Kiteline 客户端里发消息）时先把它切过来、投完还回去
（同 Mac / Windows 版）：GNOME 上经 Kiteline 的 GNOME 扩展切（shellext，Wayland、X11 都行），没有它时 X11 / XWayland 里的 VS Code 用 x11focus。
和 Mac 版一样宁可不发也不发错：切不过来、屏幕锁着、当前标签对不上，一律不按键。
没装扩展、或者会话所在的窗口还没加载扩展时，X11 上退回 delivery_x11 的老办法。
"""

import os
import shutil
import subprocess
import time

from . import alerts, atspi_linux, bridge, delivery, delivery_x11, keyhold, log, shellext, uinput, vscode_a11y, vscreen, x11focus
from .delivery import Outcome

PANEL = "claudeVSCodePanel"   # Claude Code 会话标签的网页视图类型（扩展报的 activeKind 里带这一段）
FRONT_MESSAGE = "VS Code 不在前台（电脑可能已锁屏，或被其他窗口遮挡）。为避免误输入到其他应用，此消息未发送"
# VS Code 以原生 Wayland 方式运行（新版在 Wayland 桌面上默认如此）：桌面不让别的程序把它切到前台
WAYLAND_FRONT_MESSAGE = ("VS Code 不在前台。Wayland 桌面不允许其他程序替你切换窗口，为避免误输入到其他应用，此消息未发送。"
                         "请先切到 VS Code 再发送")
NO_WINDOW = ("未找到该会话所在的 VS Code 窗口（VS Code 未运行、没有打开该项目，或装上 Kiteline 配套扩展后还没重新打开 VS Code）")
XDOTOOL_KEYS = {"enter": "Return", "esc": "Escape", "shift+tab": "shift+Tab"}


def wayland_front_message(press=False):
    """VS Code 不在前台、又没法替你切：GNOME 上提示装 Kiteline 的 GNOME 扩展（装好、重新登录一次后就能替你切）"""
    message = WAYLAND_FRONT_MESSAGE
    if press:
        message = message.replace("此消息未发送", "未按下按键").replace("再发送", "再操作")
    if shellext.applicable() and not shellext.loaded():
        message += "。在就绪检查中安装 Kiteline 的 GNOME 扩展（注销并重新登录一次后生效）后，Kiteline 可以替你切换"
    return message


def wayland():
    return os.environ.get("XDG_SESSION_TYPE") == "wayland" or (bool(os.environ.get("WAYLAND_DISPLAY")) and not os.environ.get("DISPLAY"))


def keys_available():
    """能不能按回车：uinput 开了权限；或者 X11 会话里有 xdotool（Wayland 上 xdotool 按不到原生窗口）"""
    return uinput.available() or (not wayland() and bool(os.environ.get("DISPLAY")) and shutil.which("xdotool") is not None)


def why_unavailable():
    """向 VS Code 发消息还差什么（空字符串 = 能发）"""
    if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        return "这台电脑没有图形界面，无法操作 VS Code；终端里的会话放在 tmux 中运行即可从手机发送"
    legacy = not wayland() and not delivery_x11.why_unavailable()
    if not bridge.installed():
        if legacy:
            return ""
        if not bridge.editors():
            return "没有找到 VS Code（code 命令）"
        return "需要在 VS Code 中安装 Kiteline 配套扩展，并授予 Kiteline 键盘模拟权限（就绪检查里可以一键安装）"
    if not keys_available() and not legacy:
        return "需要授予 Kiteline 键盘模拟权限（只用来在 VS Code 里按回车、选确认框选项；就绪检查里可以一键安装）"
    return ""


def locked():
    """这台电脑的图形会话是不是锁屏了（锁屏时按键会落进锁屏密码框）"""
    try:
        out = subprocess.run(["loginctl", "list-sessions", "--no-legend"], capture_output=True, timeout=5).stdout.decode()
    except (OSError, subprocess.SubprocessError):
        return False
    uid = str(os.getuid())
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 2 or parts[1] != uid:
            continue
        try:
            props = subprocess.run(["loginctl", "show-session", parts[0], "-p", "Type", "-p", "LockedHint"],
                                   capture_output=True, timeout=5).stdout.decode()
        except (OSError, subprocess.SubprocessError):
            continue
        if "LockedHint=yes" in props and ("Type=wayland" in props or "Type=x11" in props):
            return True
    return False


def _tap(name):
    if uinput.available():
        uinput.tap(name)
        return
    subprocess.run(["xdotool", "key", "--clearmodifiers", XDOTOOL_KEYS.get(name, name)],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)


def problem(state, record, siblings, focused=None):
    """当前窗口能不能往这个会话里输入（None = 可以）。规则同 delivery.front_problem。
    focused：截着键盘时 VS Code 拿不到键盘焦点、扩展报的 focused 不作数，由调用方看窗口管理器的前台窗口给出"""
    if not (state.get("focused") if focused is None else focused) or locked():
        return FRONT_MESSAGE
    snap = record.snap
    title = (snap.get("title") or "").strip()
    display = title or snap.get("name", "")
    tab = state.get("activeTab") or ""
    if PANEL not in (state.get("activeKind") or ""):
        log.write("VS Code 当前标签「%s」不是 Claude Code 会话，不投递" % tab)
        return ("未能切换到会话「%s」（VS Code 当前为「%s」）。为避免发错会话，此消息未发送。"
                "请先在 VS Code 中打开该会话的标签页后再发送" % (display, tab))
    if tab == "Claude Code" and siblings == 0:
        return None
    if not title:
        return delivery.UNTITLED_MESSAGE % display
    if not delivery.tab_matches(tab, delivery.tab_names(snap)):
        log.write("VS Code 当前标签「%s」不是会话「%s」，不投递" % (tab, display))
        return ("未能切换到会话「%s」（VS Code 当前为「%s」）。为避免发错会话，此消息未发送。"
                "请先在 VS Code 中打开该会话的标签页后再发送" % (display, tab))
    return None


class _Front:
    """投递前切到前台的记录：投完照着还回去（没切过就什么也不做）"""

    def __init__(self, previous=None, raised=None, restore=None, current=None):
        self.raised = raised
        self._previous = previous
        self._restore = restore
        self._current = current

    def restore(self, delay=0.4):
        if self._restore:
            self._restore(self._previous, self.raised, delay)

    def is_front(self):
        """窗口管理器眼里切过去的 VS Code 窗口还在前台（截着键盘时 VS Code 自己报的 focused 不作数）"""
        return bool(self.raised and self._current and self._current() == self.raised)


def _bring_front(window, hold):
    """VS Code 不在前台（比如正在 Kiteline 客户端里发消息）：先把它切过来，同 Mac / Windows 版。
    GNOME 上经 Kiteline 的 GNOME 扩展切（Wayland 也行；VS Code 在虚拟屏幕上时切过去也看不见）；没有扩展时 X11 用 x11focus。
    锁屏、找不到窗口时什么也不做"""
    if window.state.get("focused") or locked():
        return _Front()
    if shellext.loaded():
        previous, raised = shellext.raise_editor(window.state.get("folders"))
        restore, current = shellext.restore, shellext.focused
    else:
        previous, raised = x11focus.active(), x11focus.raise_editor(window.state.get("folders"))
        restore, current = x11focus.restore, x11focus.active
    if not raised:
        return _Front()
    log.write("把 VS Code 窗口切到前台再投递")
    front = _Front(previous, raised, restore, current)
    for _ in range(12):
        time.sleep(0.15)
        if front.is_front() if hold.holding else window.call("state").get("focused"):
            break
    else:
        if not hold.holding and restore is shellext.restore and shellext.ensure_focus(window, window.state.get("folders")):
            log.write("VS Code 没认这次切换，已重新切了一次")
    return front


def _take_keyboard(window, hold):
    """粘贴、按键前放开截着的键盘（先等用户停手），等 VS Code 真拿到键盘焦点（最多 1.5 秒）；返回扩展报的最新状态"""
    hold.settle()
    hold.pause()
    state = window.call("state")
    for _ in range(10):
        if state.get("focused"):
            break
        time.sleep(0.15)
        state = window.call("state")
    return state


def _switch(window, record, front, hold):
    """切到这个会话的标签。还没发过消息的会话扩展打不开（会另开空白标签）：不切，只核对当前标签"""
    state = window.state
    if not (front.is_front() if hold.holding else state.get("focused")) or locked():
        return state
    if (record.snap.get("title") or "").strip() and record.snap.get("sessionId"):
        log.write("经配套扩展切到会话「%s」" % record.snap.get("name"))
        state = window.call("open", session=record.snap["sessionId"])
    return state


def send_vscode(prompt, record, submit, siblings, check_waiting=True):
    if not bridge.installed():
        # 没装扩展：X11 上 xdotool + xclip 齐了就用老办法，不然说清还差什么
        reason = why_unavailable()
        return Outcome(False, False, reason) if reason else delivery_x11.send_vscode(prompt, record, submit, siblings, check_waiting)
    window = bridge.window_for(record)
    if not window:
        if not wayland() and not delivery_x11.why_unavailable():
            return delivery_x11.send_vscode(prompt, record, submit, siblings, check_waiting)
        return Outcome(False, False, NO_WINDOW)
    if not keys_available() and submit:
        return Outcome(False, False, why_unavailable() or "需要授予 Kiteline 键盘模拟权限（就绪检查里可以一键安装）")
    front = _Front()
    filled_only = False
    busy = vscreen.busy()
    busy.__enter__()
    # 要替用户切前台：这一会儿用户手上还在打的字先截下来，还回去以后补上（见 keyhold）
    hold = keyhold.start() if not window.state.get("focused") and not locked() else keyhold.Hold()
    try:
        front = _bring_front(window, hold)
        if not front.raised and not window.state.get("focused") and wayland() and not locked():
            return Outcome(False, False, wayland_front_message())
        found = problem(_switch(window, record, front, hold), record, siblings, front.is_front() if hold.holding else None)
        if found:
            return Outcome(False, False, found)
        found = problem(_take_keyboard(window, hold), record, siblings)
        if found:
            return Outcome(False, False, found)
        # 开启了「读取 VS Code 弹框」的：要打开 claude.ai 的 Artifact 链接弹的「打开外部网站」框先替用户取消（见 alerts.artifact_dialog），
        # 不然回车会按到框里默认的「打开」
        alerts.cancel_artifact_dialogs()
        # 会话在终端、别的窗口还开着（或窗口刚重新加载、之前的 Claude 进程还没退）：标签里是「仍在别处打开」，输入框整块收起，
        # 粘贴不进去。开启了「读取 VS Code 弹框」的，替用户按「Open here anyway」，等输入框出来再粘贴（同 Mac / Windows 版）
        if vscode_a11y.enabled() and atspi_linux.open_here_if_held():
            found = problem(window.call("state"), record, siblings)
            if found:
                return Outcome(False, False, found)
        window.call("focus")
        alerts.note_paste(prompt)   # 万一粘进了终端，弹的「粘贴到终端?」框认得出、替用户取消（见 alerts.stray_paste_dialog）
        # 粘贴后、回车后读输入框核对（同 Mac / Windows 版）：开了「读取 VS Code 弹框」才读得到，读不到的照以前的做法
        before = atspi_linux.input_text() if vscode_a11y.enabled() else None
        window.call("paste", text=prompt)
        pasted = None
        if before is not None:
            def landed():
                now = atspi_linux.input_text()
                return now is None or now != before
            if not delivery.poll(1.2, landed):
                log.write("粘贴后输入框没变，再粘一次")
                window.call("focus")
                window.call("paste", text=prompt)
                if not delivery.poll(1.2, landed):
                    log.write("重新粘贴后输入框仍没变，不发")
                    return Outcome(False, False, delivery.PASTE_MISSED)
            pasted = atspi_linux.input_text()
        if not submit:
            filled_only = True
            return Outcome(True, False, "已填入输入框")
        time.sleep(0.15)
        found = problem(window.call("state"), record, siblings)
        if found:
            return Outcome(False, False, "文字已粘贴，但提交时出现问题：" + found)
        midway = check_waiting and delivery.waiting_midway(record)
        if midway:
            return Outcome(True, False, midway)
        if alerts.cancel_artifact_dialogs():
            window.call("focus")
        _tap("enter")
        # 斜杠命令：输入框可能弹出命令菜单，第一下回车只是选中，再按一下才执行（同 Mac 版）
        slash = prompt.startswith("/") and "\n" not in prompt
        if slash:
            time.sleep(0.5)
            _tap("enter")
        time.sleep(0.05)
        hold.resume()   # 还前台之前打的字也截下来：不然落进刚清空的输入框，和下一条拼在一起
        # 回车后核对：输入框里不再是这段话才算提交上；没提交上的补按一次，前台、等确认照样先核对
        if pasted is not None:
            def cleared():
                return delivery.submitted_from(atspi_linux.input_text(), pasted, prompt)
            if not delivery.poll(2.0 if slash else 1.5, cleared):
                log.write("回车后输入框里仍是这段话，补按一次")
                found = problem(_take_keyboard(window, hold), record, siblings)
                if found:
                    return Outcome(False, False, "文字已粘贴，但提交时出现问题：" + found)
                midway = check_waiting and delivery.waiting_midway(record)
                if midway:
                    return Outcome(True, False, midway)
                if not cleared():
                    window.call("focus")
                    _tap("enter")
                    time.sleep(0.05)
                    hold.resume()
                    if not delivery.poll(1.5, cleared):
                        log.write("补按回车后输入框里仍是这段话，按未提交报")
                        return Outcome(True, False, delivery.SUBMIT_MISSED)
        return Outcome(True, True, "已提交")
    except (OSError, ValueError) as exc:
        log.write("经配套扩展投递失败：%s" % exc)
        return Outcome(False, False, "与 VS Code 配套扩展通信失败：%s" % exc)
    finally:
        # 前台还给用户原来在用的窗口（回车要先落进 VS Code：斜杠命令按两下，多等一会儿）；只填不提交的不还（用户要到 VS Code 里再看一眼，
        # VS Code 在虚拟屏幕上时由 vscreen 放回来给人看）
        if not filled_only:
            front.restore(0.9 if prompt.startswith("/") and "\n" not in prompt else 0.4)
        hold.end(replay=not filled_only and not front.is_front())
        busy.__exit__(None, None, None)


def press_vscode(key, times, record, siblings):
    name = {"return": "enter", "escape": "esc"}.get(key, key)
    if name not in uinput.KEYS:
        return Outcome(False, False, "不支持的按键：%s" % key)
    if not bridge.installed():
        reason = why_unavailable()
        return Outcome(False, False, reason) if reason else delivery_x11.press_vscode(key, times, record, siblings)
    window = bridge.window_for(record)
    if not window:
        if not wayland() and not delivery_x11.why_unavailable():
            return delivery_x11.press_vscode(key, times, record, siblings)
        return Outcome(False, False, NO_WINDOW)
    if not keys_available():
        return Outcome(False, False, why_unavailable() or "需要授予 Kiteline 键盘模拟权限（就绪检查里可以一键安装）")
    front = _Front()
    busy = vscreen.busy()
    busy.__enter__()
    hold = keyhold.start() if not window.state.get("focused") and not locked() else keyhold.Hold()
    try:
        front = _bring_front(window, hold)
        if not front.raised and not window.state.get("focused") and wayland() and not locked():
            return Outcome(False, False, wayland_front_message(press=True))
        found = problem(_switch(window, record, front, hold), record, siblings, front.is_front() if hold.holding else None)
        if found:
            return Outcome(False, False, found.replace("此消息未发送", "未按下按键"))
        found = problem(_take_keyboard(window, hold), record, siblings)
        if found:
            return Outcome(False, False, found.replace("此消息未发送", "未按下按键"))
        alerts.cancel_artifact_dialogs()   # 同 send_vscode：Artifact 链接的框挂着时按键会按到框里
        time.sleep(0.3)
        for _ in range(times):
            _tap(name)
            time.sleep(0.25)
        hold.resume()
        return Outcome(True, False, "已按下 %s" % key)
    except (OSError, ValueError) as exc:
        log.write("经配套扩展按键失败：%s" % exc)
        return Outcome(False, False, "与 VS Code 配套扩展通信失败：%s" % exc)
    finally:
        front.restore()
        hold.end(replay=not front.is_front())
        busy.__exit__(None, None, None)


# 动作单里的程序在 Linux 上的窗口类名（GNOME 扩展报的 wmClass / app、X11 的 WM_CLASS）
UI_CLASSES = {"cursor": ("cursor",)}


def run_ui(actions, plugin_step):
    """插件回的动作单（同 Mac 版 Delivery.runUIActions、Windows 版 delivery_win.run_ui），按顺序做：
    focus 把 app 里打开了这个项目的窗口切到前台并核对 / plugin 回头请插件做一步（如往对话输入框里填字）/ key 核对前台再按键；
    做完把前台还回去。切窗口经 Kiteline 的 GNOME 扩展（Wayland、X11 都行），没有它时 X11 用 x11focus；按键用 uinput（X11 退回 xdotool）。
    哪一步不成就停下、不按键，返回给用户看的原因；都做完返回 None"""
    if not keys_available() and any(a.get("do") == "key" for a in actions):
        return delivery.ui_problem(actions, "需要授予 Kiteline 键盘模拟权限（就绪检查里可以一键安装）", False)
    if locked():
        return delivery.ui_problem(actions, "电脑已锁屏，为避免误输入而停止", False)
    if shellext.loaded():
        listing = lambda: [(w["id"], ((w.get("wmClass") or "").lower(), (w.get("app") or "").lower()), w.get("title")) for w in shellext.windows()]
        current, activate, restore = shellext.focused, shellext.activate, shellext.restore
    elif not wayland() and os.environ.get("DISPLAY"):
        listing = None   # X11：按类名、标题直接问 x11focus.find
        current, activate, restore = x11focus.active, x11focus.activate, x11focus.restore
    else:
        message = "Wayland 桌面不允许其他程序替你切换窗口"
        if shellext.applicable() and not shellext.loaded():
            message += "（在就绪检查中安装 Kiteline 的 GNOME 扩展并注销重新登录一次后，Kiteline 可以替你切换）"
        return delivery.ui_problem(actions, message, False)
    target = previous = None
    filled, pressed, shown = False, False, "编辑器"
    hold = keyhold.Hold()
    busy = vscreen.busy()
    busy.__enter__()
    try:
        for action in actions:
            kind = action.get("do")
            if kind == "focus":
                app = action.get("app") or ""
                shown, classes = delivery.UI_APPS.get(app), UI_CLASSES.get(app)
                if not shown or not classes:
                    return delivery.ui_problem(actions, delivery.UI_UNSUPPORTED, filled)
                folder = (action.get("folder") or "").rstrip("/")
                names = [os.path.basename(folder)] if folder else []

                def ours(klass, title):
                    return any(c in classes for c in klass) and (not names or shellext.title_matches(title, names))

                if shellext.loaded():
                    found = [wid for wid, klass, title in listing() if ours(klass, title)]
                else:
                    found = x11focus.find(ours)
                if not found:
                    return delivery.ui_problem(actions, "未找到 %s 中打开「%s」的窗口" % (shown, os.path.basename(folder) or folder), filled)
                target, previous = found[-1], current()
                if previous != target:
                    hold = keyhold.start()   # 切前台这一会儿用户手上打的字先截下来，还回去以后补上（见 keyhold）
                    if not activate(target):
                        return delivery.ui_problem(actions, "%s 未能切到前台" % shown, filled)
                for _ in range(12):
                    if current() == target:
                        break
                    time.sleep(0.15)
                else:
                    return delivery.ui_problem(actions, "%s 未能切到前台（可能被其他窗口遮挡），为避免误输入到其他应用而停止" % shown, filled)
                hold.settle()
                hold.pause()   # 窗口要真拿到键盘焦点，插件才能往里填字
            elif kind == "plugin":
                try:
                    plugin_step(action.get("step") or "")
                except Exception as exc:  # noqa: BLE001
                    return delivery.ui_problem(actions, str(exc), filled)
                filled = True
                time.sleep(0.2)
            elif kind == "key" and (action.get("name") or "").lower() in uinput.KEYS:
                if target is not None and current() != target:
                    return delivery.ui_problem(actions, "%s 已不在前台，为避免误输入到其他应用而停止" % shown, filled)
                time.sleep(0.15)
                _tap(action["name"].lower())
                pressed = True
                time.sleep(0.05)
                hold.resume()
                log.write("动作单：在 %s 按下 %s" % (shown, action["name"]))
            else:
                return delivery.ui_problem(actions, delivery.UI_UNSUPPORTED, filled)
        return None
    finally:
        if previous and target is not None and previous != target:
            restore(previous, target, 0.4)
        hold.end(replay=pressed and current() != target)
        busy.__exit__(None, None, None)


def launch(cwd, prompt, submit, session_id, started=None, wait=24, outcome=None):
    """新建任务 / 恢复会话（app.launch_session 在后台调）：等项目的 VS Code 窗口加载好配套扩展，经扩展新开（或恢复）会话、
    预填内容；submit 时等会话标签在前台再按回车，并核实会话开始运行（提交上了记 outcome["submitted"]）。返回 False = 没找到装了扩展的窗口（调用方改走链接）。
    wait：最多等窗口多少秒（远端窗口第一次连要装服务端，调用方给得长些）"""
    window = None
    for _ in range(max(1, int(wait / 2))):
        window = bridge.window_for_cwd(cwd, only_match=True)
        if window:
            break
        time.sleep(2)
    if not window:
        return False
    folder = os.path.basename(cwd.rstrip("/"))
    try:
        window.call("open", session=session_id or None, prompt=prompt or None)
        if not (submit and prompt):
            return True
        if not keys_available():
            log.write("新任务未能自动提交：没有键盘模拟权限，内容已填入输入框（%s）" % folder)
            return True
        refocused = False
        for attempt in range(2):
            ready = False
            for _ in range(10):
                time.sleep(1.5)
                state = window.call("state")
                if not state.get("focused") and shellext.loaded() and not locked():
                    # 新标签在不在前台的窗口里：GNOME 上经扩展把它切过来（Wayland 也行），回车才落得进去；
                    # GNOME 说已经是它、VS Code 却没认（刚跑过 code 命令时会这样）：补切一次
                    if shellext.raise_editor(state.get("folders")) == (None, None) and not refocused:
                        refocused = True
                        if shellext.ensure_focus(window, state.get("folders")):
                            log.write("VS Code 没认这次切换，已重新切了一次")
                    time.sleep(0.4)
                    state = window.call("state")
                tab = state.get("activeTab") or ""
                if state.get("focused") and PANEL in (state.get("activeKind") or "") and (tab == "Claude Code" or session_id) and not locked():
                    ready = True
                    break
            if not ready:
                break
            window.call("focus")
            time.sleep(0.3)
            _tap("enter")
            if started is None:
                log.write("新任务已按回车提交（%s）" % folder)
                if outcome is not None:
                    outcome["submitted"] = True
                return True
            for _ in range(8):
                time.sleep(1)
                if started():
                    log.write("新任务已提交，会话已开始运行（%s）" % folder)
                    if outcome is not None:
                        outcome["submitted"] = True
                    return True
            log.write("新任务按了回车但会话未开始运行，再试一次（%s）" % folder)
        log.write("新任务未能自动提交：「%s」的 VS Code 会话标签不在前台或回车未生效，内容已填入输入框，需在 VS Code 中按回车" % folder)
    except (OSError, ValueError) as exc:
        log.write("新任务经配套扩展提交失败：%s" % exc)
    return True
