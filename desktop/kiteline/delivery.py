"""把手机上的输入送进 Claude Code 会话（对应 Mac 版 Delivery.swift）。

Claude Code 没有可写的 stdin，投递只能走前端，按会话的宿主分几条路：
  1. VS Code 扩展里的会话：找到会话所在的 VS Code 窗口、用扩展的 URI 切到这个会话，
     核对前台标签确实是它，再粘贴 + 回车（Windows：Win32 + SendInput；
     Linux：VS Code 里的 Kiteline 配套扩展切会话、核对、粘贴，uinput 虚拟键盘按回车，见 delivery_bridge；没装扩展的 X11 用 xdotool）
  2. 终端里的 CLI 会话、在 tmux 里：交给 watcher 用 tmux 精确投递
  3. Windows 本机终端里的 CLI 会话：直接写进它的控制台输入缓冲区（不用抢前台）
宁可不发，也不能发错会话：对不上就报原因。
Codex、OpenCode 的会话不走这几条：watcher 连着它们自己的本机服务，发消息、确认、回答提问都走协议（见 via_agent）。
"""

import os
import threading
import time
import urllib.parse

from . import config, log

DRY_RUN = os.environ.get("KITELINE_DRY_RUN") == "1" or os.environ.get("CCPULSE_DRY_RUN") == "1"
ATTACH_PREFIX = "[附图] "
FILE_PREFIX = "[附件] "   # 手机发来的文件（PDF、Excel……）：原样留在消息里，Claude 自己去读，手机认出来画成文件卡片
KEYS = ("enter", "return", "esc", "escape", "1", "2", "3", "4", "shift+tab")

last_delivered = None   # 自测断言用：(key, text, submit)
# 按会话 key 取最新的记录（app 启动时设成 store.record）：投递途中回头看 Claude 是不是刚弹出了确认框
LOOKUP = None
# 粘贴、按键要占着前台和剪贴板：HTTP 服务一条连接一个线程，几条同时来（连点常用语、几个分屏块前后脚发）会互相抢——
# 上一条投完把前台还回去时下一条正要按回车，就成了「VS Code 不在前台」，文字还留在输入框里。排队一条一条来（同 Mac 版 Delivery.serialized）
_FRONT = threading.Lock()


# 没能替用户免掉扩展链接的确认框（见 remotessh.trust_claude_links）时回给手机的话（同 Mac 版 Delivery.linkConfirmation）
LINK_CONFIRMATION = "电脑上的 VS Code 弹出了确认框，询问是否允许 Claude Code 扩展打开链接。请在电脑上勾选「不再询问」并点击「打开」后重新发送，此消息未发送"
LINK_CONFIRMATION_PRESS = "电脑上的 VS Code 弹出了确认框，询问是否允许 Claude Code 扩展打开链接。请在电脑上勾选「不再询问」并点击「打开」后重试，未按下按键"


class Outcome(dict):
    def __init__(self, ok, submitted=False, message="", keep_front=False):
        super().__init__(ok=ok, submitted=submitted, message=message)
        # VS Code 弹着确认框：不把前台还回去（切走的话框会被盖住，用户在电脑前也像是它自己消失了）
        self.keep_front = keep_front

    @property
    def ok(self):
        return self["ok"]


def attachments_of(body):
    """手机随消息带的图（images）和文件（files：别的 App 里「用其他应用打开」发来的 PDF、Excel……）：[{name, data(base64), file}]，图在前。
    文字发送、按住说话、新任务、恢复会话都可能带（同 Mac 版 MobileServer.attachments）"""
    out = []
    for field in ("images", "files"):
        for item in (body or {}).get(field) or []:
            if item.get("data"):
                out.append({"name": item.get("name") or ("file" if field == "files" else "image.jpg"), "data": item["data"],
                            "file": field == "files"})
    return out


def split_staged(paths, attachments=None):
    """stage 回来的路径按原来是图还是文件分开；不给 attachments 就都当图"""
    kinds = [bool(a.get("file")) for a in attachments] if attachments else [False] * len(paths)
    return [p for p, f in zip(paths, kinds) if not f], [p for p, f in zip(paths, kinds) if f]


def compose(text, paths, attachments=None):
    """消息正文 + 附图行 / 附件行（附图行手机上还原成图片，附件行画成文件卡片；Claude 看到的是普通路径）"""
    body = (text or "").strip()
    images, files = split_staged(paths, attachments)
    if not images and not files:
        return body
    lines = "\n".join([ATTACH_PREFIX + p for p in images] + [FILE_PREFIX + p for p in files])
    lead = "请查看我发来的文件：" if not images else ("请查看我发来的图片和文件：" if files else "请查看我发来的图片：")
    return "%s\n\n%s" % (body or lead, lines)


def via_agent(snap):
    """Claude Code 以外的 agent（Codex、OpenCode）的会话：消息、确认都交给 watcher 走协议，不碰前台"""
    return (snap.get("agent") or "claude-code") != "claude-code"


def _agent_request(payload, record, source, submitted):
    try:
        response = source.request(dict(payload, sessionId=record.snap.get("sessionId")), timeout=30)
    except Exception as exc:  # noqa: BLE001
        return Outcome(False, False, str(exc))
    actions = response.get("ui")
    if isinstance(actions, list) and actions and all(isinstance(a, dict) for a in actions):
        # 插件回了动作单（watcher 的 HOST_CAPS「ui.keys」）：在这台电脑上按顺序做（同 Mac 版 Delivery.runUIActions）。
        # 远端来源的会话界面也在这台电脑上
        def plugin_step(step):
            source.request({"cmd": "agent_ui", "sessionId": record.snap.get("sessionId"), "step": step}, timeout=15)
        with _FRONT:
            problem = _backend().run_ui(actions, plugin_step)
        if problem:
            return Outcome(False, False, problem)
    return Outcome(True, submitted, response.get("message") or "已送达")


# 动作单里认得的程序（插件写的 app 名 → 给用户看的名字）；各平台怎么认窗口见 delivery_win / delivery_bridge 的 run_ui
UI_APPS = {"cursor": "Cursor"}
UI_UNSUPPORTED = "当前版本的 Kiteline 不支持这一步，请更新 Kiteline"


def ui_problem(actions, why, filled):
    """动作单停在半路：插件填进去了没有（填了 = 文字留在输入框里），告诉用户"""
    shown = next((UI_APPS[a.get("app")] for a in actions if a.get("app") in UI_APPS), "编辑器")
    if filled:
        return "消息已填入 %s 的输入框，但未能自动发送：%s，请在电脑上按回车发送" % (shown, why)
    return "此消息未发送：%s" % why


def stage(attachments, source):
    """图片先落到会话所在的机器上（watcher 的 put_file），拿到路径再写进消息。返回路径列表，失败抛错"""
    paths = []
    for item in attachments:
        response = source.request({"cmd": "put_file", "name": item["name"], "data": item["data"]}, timeout=120)
        if not response.get("path"):
            raise RuntimeError("watcher 未返回路径")
        paths.append(response["path"])
    return paths


# 在 tmux 里运行 claude 的现成命令：在项目目录里运行；已有同名会话就直接接回去（就绪检查、发送失败的提示都用它）
TMUX_COMMAND = "tmux new -A -s claude claude"

# VS Code 远程连接（Remote-SSH / WSL / 容器）的服务端目录：会话的 claude 进程在这里面跑时，编辑器窗口在另一台电脑上
REMOTE_EDITOR_DIRS = (".vscode-server", ".vscode-server-insiders", ".vscodium-server", ".cursor-server", ".windsurf-server")
REMOTE_EDITOR_MESSAGE = ("该会话运行在 VS Code 远程连接（Remote-SSH）中，编辑器窗口在另一台电脑上，无法从这台电脑发送。"
                         "请在打开该 VS Code 窗口的电脑上使用 Kiteline（Mac 版可在设置 → 来源中通过 SSH 添加这台电脑）")


def remote_editor(pid):
    """会话的 claude 进程是不是 VS Code 远程连接服务端里的（只认得出 Linux）"""
    if not pid or not config.IS_LINUX:
        return False
    try:
        path = os.readlink("/proc/%d/exe" % int(pid))
    except (OSError, ValueError):
        return False
    return any("/%s/" % folder in path for folder in REMOTE_EDITOR_DIRS)


def _backend():
    if config.IS_WINDOWS:
        from . import delivery_win
        return delivery_win
    from . import delivery_bridge
    return delivery_bridge


def editor_link(session_id, scheme="vscode", prompt=None, shell_decodes=False):
    """扩展自带的 URI：切到这个会话的标签；带 prompt 时把内容预填进输入框（扩展只预填、不提交）。
    预填只对新开的面板有效（新任务、恢复已关闭的会话）：会话标签已经打开时扩展只把它调到前面，内容不会填进去。
    shell_decodes：Windows 用 ShellExecute 打开协议链接时会先解码一次，内容要再编一层，不然 + 变空格、& 之后被截掉"""
    query = urllib.parse.urlencode({"session": session_id}).replace("+", "%2B") if session_id else ""
    if prompt is not None:
        value = urllib.parse.quote(prompt, safe="")
        if shell_decodes:
            value = urllib.parse.quote(value, safe="")
        query += ("&" if query else "") + "prompt=" + value
    return "%s://anthropic.claude-code/open%s" % (scheme, "?" + query if query else "")


def waiting_problem(record):
    """Claude 正在等你确认（允许 / 拒绝、提问的选项、计划审批）：这时输入框被确认框换掉，粘贴进不去，
    回车会替你选中确认框里默认的「允许」（10-25 在 Linux 测试机上实测：消息没发出去，一条命令被执行了）。
    按键式投递（VS Code、终端、tmux）一律不发；Codex、OpenCode 这类走协议的不受影响（同 Mac 版 Delivery.waitingProblem）。None = 可以发"""
    if via_agent(record.snap):
        return None
    current = (LOOKUP(record.key) if LOOKUP else None) or record
    snap = current.snap
    if snap.get("activity") != "waiting":
        return None
    what = snap.get("waitingFor") or snap.get("needs") or ("等待确认：%s" % snap["pendingTool"] if snap.get("pendingTool") else "允许或拒绝")
    return ("Claude 正在等你确认（%s）。此时发送消息，回车会替你选中确认框中的默认选项，因此消息未发送。"
            "请先在确认卡片中作出选择，再重新发送" % what)


def waiting_midway(record, where="VS Code 输入框"):
    """投递途中（粘贴之后、回车之前）Claude 弹出了确认框：回车就会替你选中默认选项，不按了（文字留在输入框里）。None = 可以按"""
    problem = waiting_problem(record)
    if not problem:
        return None
    log.write("投递途中 Claude 弹出了确认框，不按回车：%s" % problem[:60])
    return "发送途中 Claude 弹出了确认框，为避免回车替你选中默认选项，消息已填入%s但未提交。请先在确认卡片中作出选择，再到 VS Code 中按回车" % where


def send(text, attachments, record, source, submit, siblings, allow_waiting=False):
    """发文本（可带图）。siblings：同一来源、同一目录下的其他会话数（认「Claude Code」通用标签用）。
    allow_waiting：回答提问时先按 Esc 关掉了提问框，watcher 还没来得及更新状态，不拦"""
    global last_delivered
    if not allow_waiting:
        problem = waiting_problem(record)
        if problem:
            return Outcome(False, False, problem)
    try:
        paths = stage(attachments, source) if attachments else []
    except Exception as exc:  # noqa: BLE001
        return Outcome(False, False, "图片或文件传输到会话所在机器失败：%s" % exc)
    prompt = compose(text, paths, attachments)
    if not prompt:
        return Outcome(False, False, "内容为空")
    snap = record.snap
    if DRY_RUN:
        last_delivered = (record.key, prompt, submit)
        log.write("[dry-run] 投递到 %s（submit=%s）：%s" % (snap.get("name"), "true" if submit else "false", prompt[:120]))
        return Outcome(True, submit, "dry-run")
    if via_agent(snap):
        # 图片按图片给（Codex、OpenCode 都收本地图片路径），不拼进文字；文件只能写成路径交给它自己读
        images, files = split_staged(paths, attachments)
        # ui：这台电脑会替插件按键（插件回动作单时执行，见 _agent_request；Cursor 编辑器空闲时发消息靠它）
        return _agent_request({"cmd": "agent_send", "text": compose(text, files, [{"file": True}] * len(files)), "images": images,
                               "ui": ["keys"]}, record, source, True)
    entry = snap.get("entrypoint")
    if entry is None or entry == "claude-vscode":
        if record.kind == "local" and remote_editor(snap.get("pid")):
            return Outcome(False, False, REMOTE_EDITOR_MESSAGE)
        problem = untitled_problem(record, siblings)
        if problem:
            return Outcome(False, False, problem)
        with _FRONT:
            return _backend().send_vscode(prompt, record, submit, siblings, check_waiting=not allow_waiting)
    if snap.get("tmuxPane") and snap.get("pid"):
        try:
            source.request({"cmd": "tmux_send", "pid": snap["pid"], "text": prompt, "submit": submit}, timeout=20)
            return Outcome(True, submit, "已通过 tmux 送达")
        except Exception as exc:  # noqa: BLE001
            return Outcome(False, False, str(exc))
    if record.kind == "local" and config.IS_WINDOWS and snap.get("pid"):
        from . import delivery_win
        with _FRONT:
            return delivery_win.send_console(prompt, snap["pid"], submit)
    return Outcome(False, False, "终端中的 CLI 会话需在 tmux 中运行才能远程发送：在项目目录里用 %s 启动 Claude Code" % TMUX_COMMAND)


def press(key, times, record, source, siblings):
    """确认框选项 / 中断：enter / esc / 1 / 2 / 3 / shift+tab；times = 连按几次"""
    global last_delivered
    times = max(1, min(int(times or 1), 6))
    key = (key or "").lower()
    if key not in KEYS:
        return Outcome(False, False, "不支持的按键：%s" % key)
    snap = record.snap
    if DRY_RUN:
        last_delivered = (record.key, "<key:%s>" % key, False)
        log.write("[dry-run] 在 %s 按键 %s" % (snap.get("name"), key))
        return Outcome(True, False, "dry-run")
    if via_agent(snap):
        # 1 允许 / 2 本会话都允许 / Esc 拒绝（不在等确认时 Esc = 中断）：watcher 换成 Codex、OpenCode 的说法
        return _agent_request({"cmd": "agent_key", "key": key}, record, source, False)
    entry = snap.get("entrypoint")
    if entry is None or entry == "claude-vscode":
        if record.kind == "local" and remote_editor(snap.get("pid")):
            return Outcome(False, False, REMOTE_EDITOR_MESSAGE.replace("无法从这台电脑发送", "无法从这台电脑操作"))
        problem = untitled_problem(record, siblings)
        if problem:
            return Outcome(False, False, problem.replace("此消息未发送", "未按下按键"))
        with _FRONT:
            return _backend().press_vscode(key, times, record, siblings)
    if snap.get("tmuxPane") and snap.get("pid"):
        try:
            source.request({"cmd": "tmux_send", "pid": snap["pid"], "keys": [key] * times}, timeout=20)
            return Outcome(True, False, "已按下 %s" % key)
        except Exception as exc:  # noqa: BLE001
            return Outcome(False, False, str(exc))
    if record.kind == "local" and config.IS_WINDOWS and snap.get("pid"):
        from . import delivery_win
        with _FRONT:
            return delivery_win.press_console(key, times, snap["pid"])
    return Outcome(False, False, "终端中的 CLI 会话需在 tmux 中运行才能远程操作：在项目目录里用 %s 启动 Claude Code" % TMUX_COMMAND)


UNTITLED_CLOSE = ("「%s」还没有标题（尚未发送消息，或标题正在生成），VS Code 中同一项目的标签页都名为「Claude Code」，暂时无法确定要关闭哪一个。"
                  "为避免关错，会话未关闭。刚发过消息的请稍后再试；未使用的空白标签页可在 VS Code 中直接关闭")


def close(record, source, siblings):
    """关闭会话：VS Code 里关掉它的标签页（Ctrl+W = 关闭编辑器，Claude Code 随之结束这个会话）；终端里的 CLI 发 /exit。
    关掉的会话进「历史会话」，之后可以恢复。正在开着的会话越积越多、VS Code 里标签越开越多时用（同 Mac 版 Delivery.close）"""
    global last_delivered
    snap = record.snap
    if DRY_RUN:
        last_delivered = (record.key, "<close>", False)
        log.write("[dry-run] 关闭会话 %s" % snap.get("name"))
        return Outcome(True, False, "dry-run")
    if via_agent(snap):
        # Codex、OpenCode 这些：交给 watcher 里的插件（各家怎么关见 watcher/kiteline-watch.py 各插件的 close）
        return _agent_request({"cmd": "agent_close"}, record, source, False)
    entry = snap.get("entrypoint")
    if entry is None or entry == "claude-vscode":
        if record.kind == "local" and remote_editor(snap.get("pid")):
            return Outcome(False, False, REMOTE_EDITOR_MESSAGE.replace("无法从这台电脑发送", "无法从这台电脑操作"))
        if not (snap.get("title") or "").strip() and siblings:
            return Outcome(False, False, UNTITLED_CLOSE % (snap.get("name") or ""))
        with _FRONT:
            outcome = _backend().press_vscode("ctrl+w", 1, record, siblings)
    else:
        # 终端里的 CLI（tmux、Windows 控制台）：发 /exit。Claude 等确认时不发（回车会替你选中默认选项）
        if waiting_problem(record):
            return Outcome(False, False, CLOSE_WHILE_WAITING)
        outcome = send("/exit", [], record, source, True, siblings)
    if outcome.ok:
        return Outcome(True, False, "已关闭会话")
    message = outcome["message"].replace("此消息未发送", "会话未关闭").replace("未按下按键", "会话未关闭")
    return Outcome(False, False, message, keep_front=outcome.keep_front)


CLOSE_WHILE_WAITING = ("Claude 正在等你确认。终端中的会话需输入 /exit 并按回车才能关闭，此时回车会替你选中确认框中的默认选项，因此会话未关闭。"
                       "请先在确认卡片中作出选择，再关闭会话")


def answer(text, record, source, siblings, answers=None):
    """回答提问：先 Esc 关掉提问框，再把答案作为消息提交。
    Codex、OpenCode 的提问是协议里的请求：把选项原样答回去；对不上待答的提问再退回发一条消息"""
    if via_agent(record.snap) and not DRY_RUN:
        outcome = _agent_request({"cmd": "agent_answer", "answers": answers or []}, record, source, True)
        if outcome.ok:
            return outcome
        return send(text, [], record, source, True, siblings)
    outcome = press("esc", 1, record, source, siblings)
    if not outcome.ok:
        return outcome
    if not DRY_RUN:
        time.sleep(1.2)
    return send(text, [], record, source, True, siblings, allow_waiting=True)


def tab_names(snap):
    """核对 VS Code 前台标签时认的名字（同 Mac 版 SessionSnapshot.tabCandidates）：标题；Claude 没起成标题时
    watcher 拿第一句当标题，另在 tabNames 给标签可能显示的名字（当场发的是第一句，重开 VS Code 恢复的是那时的最近一句）。空 = 还没发过消息"""
    names = [snap.get("title")] + list(snap.get("tabNames") or [])
    return [n.strip() for n in names if isinstance(n, str) and n.strip()]


def tab_matches(tab, title):
    """标签名和会话标题对得上（VS Code 可能截断长标题，两边都按前缀比；空白都并成一个空格，同扩展）。
    title 也可以是一组名字（tab_names），对上一个就算"""
    if isinstance(title, (list, tuple)):
        return any(tab_matches(tab, name) for name in title)
    a = " ".join(tab.replace("…", "").split())
    b = " ".join((title or "").replace("…", "").split())
    if len(a) < 2 or len(b) < 2:
        return False
    if a == b:
        return True
    n = min(len(a), len(b), 16)
    return n >= 4 and a[:n] == b[:n]


def split_title(full):
    """VS Code 窗口标题拆成（当前标签名, 项目名）：
    「● 首页卡片间距 - ccpulse [SSH: 10.168.1.10] - Visual Studio Code」→（首页卡片间距, ccpulse）"""
    sep = " — " if " — " in full else " - "
    parts = [p.strip() for p in full.split(sep)]
    tab = parts[0].replace("● ", "").strip() if parts else full
    project = parts[1].split(" [")[0].strip() if len(parts) > 2 else ""
    return tab, project


def title_place(title):
    """窗口标题里项目那段：「文件 - ccpulse [SSH: 10.168.1.10] - Visual Studio Code」→「ccpulse [SSH: 10.168.1.10]」"""
    sep = " — " if " — " in title else " - "
    parts = [p.strip() for p in title.split(sep) if p.strip()]
    if parts and parts[-1] in ("Visual Studio Code", "Visual Studio Code - Insiders", "VSCodium", "Cursor"):
        parts = parts[:-1]
    return parts[-1] if parts else ""


UNTITLED_MESSAGE = ("「%s」在 VS Code 中尚未发送过消息，标签页名称为「Claude Code」，无法识别目标会话。为避免发错会话，此消息未发送。"
                    "请先在 VS Code 中发送第一条消息；如不再使用，关闭该空白标签页即可")


def focus_elsewhere(record, place):
    """键盘焦点在别处、放不进这个会话的输入框时回给手机的话（同 Mac 版 Delivery.focusElsewhere；按键的把「此消息未发送」换掉）"""
    display = (record.snap.get("title") or "").strip() or record.snap.get("name", "")
    return ("VS Code 的键盘焦点在%s，未能移到「%s」的输入框。为避免误输入，此消息未发送。请在电脑上点一下该会话的输入框后重试"
            % (place, display))


FOCUS_LEFT_MESSAGE = "文字已粘贴，但提交前 VS Code 的键盘焦点移到了%s，为避免误操作，未按回车。请在电脑上检查该会话的输入框"

# 粘贴后、回车后读输入框核对（同 Mac 版 Delivery.sendToVSCode）：10-31 投递时前台被别的程序抢走，粘贴落在那个程序里，
# 回车按在空输入框上，却报了「已提交」。粘贴落空的再粘一次还不行 → PASTE_MISSED（输入框是空的，手机上可以放心重发）；
# 回车没提交上的补按一次还不行 → SUBMIT_MISSED（字留在输入框里，按「已填入、未提交」报）
PASTE_MISSED = "未能将消息粘贴进 VS Code 的输入框，消息未发送"
SUBMIT_MISSED = "消息已在 VS Code 输入框中，但按回车后未能提交。请在电脑上检查该会话的输入框"


def normalized(text):
    """空白统一成一个空格（输入框里的字和发过去的可能差在换行上）"""
    return " ".join(text.split())


def submitted_from(now, pasted, prompt):
    """回车后输入框里不再是粘贴后的那段话：提交上了。开头一截还在的不算（回车被输入法拿去上屏、或变成了换行）；读不出（None）的不拦"""
    if now is None:
        return True
    head = normalized(prompt)[:24]
    return now != pasted and (len(head) < 4 or head not in now)


def poll(seconds, check, step=0.15):
    """每 step 秒看一次 check，成立返回 True，到时间返回 False"""
    until = time.time() + seconds
    while True:
        if check():
            return True
        if time.time() >= until:
            return False
        time.sleep(step)


def untitled_problem(record, siblings):
    """还没发过消息的会话、同目录下又有别的会话：标签都叫「Claude Code」，认不出是哪个。
    在动 VS Code 之前就拒绝——不然内容会先预填进扩展新开的空白标签，留在输入框里"""
    if (record.snap.get("title") or "").strip() or not siblings:
        return None
    return UNTITLED_MESSAGE % (record.snap.get("name") or "")


def front_problem(front_title, record, siblings):
    """前台 VS Code 窗口当前标签是不是这个会话；不是的话返回原因（None = 没问题）"""
    if front_title is None:
        return "VS Code 不在前台（电脑可能已锁屏，或被其他应用遮挡）。为避免误输入到其他应用，此消息未发送"
    snap = record.snap
    title = (snap.get("title") or "").strip()
    display = title or snap.get("name", "")
    tab, project = split_title(front_title)
    folder = os.path.basename((snap.get("cwd") or "").rstrip("/\\"))
    if tab == "Claude Code" and project == folder and siblings == 0:
        return None
    if not title:
        return UNTITLED_MESSAGE % display
    if not tab_matches(tab, tab_names(snap)):
        log.write("前台标签「%s」不是会话「%s」，不投递" % (tab, display))
        return ("未能切换到会话「%s」（VS Code 当前为「%s」）。为避免发错会话，此消息未发送。"
                "请先在 VS Code 中打开该会话的标签页后再发送" % (display, tab))
    return None


def window_matches(title, folder, remote):
    """按窗口标题找会话所在窗口：标题形如「文件 - 根目录名 - Visual Studio Code」，远端带「[SSH: 主机]」"""
    sep = " — " if " — " in title else " - "
    segments = [s.strip() for s in title.split(sep)]
    if remote:
        return any(s.startswith("%s [SSH: " % folder) for s in segments)
    return "[SSH:" not in title and folder in segments
