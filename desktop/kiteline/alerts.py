"""要人处理的状况（对应 Mac 版 EditorAlerts.swift）：
  - VS Code 弹着系统对话框（Remote-SSH 连不上、断线放弃「无法重新连接」、远端目录不在「工作区不存在」、保存确认……）：
    框挂着时手机发的消息投递不进去，人不在电脑前又看不见。挂 4 秒以上、人 30 秒没碰电脑才推送；手机列表顶上显示到框关掉为止。
    Windows 上读得到（系统 TaskDialog，见 uia_win.py）；Linux 要用户在就绪检查里开启「读取 VS Code 弹框」（见 vscode_a11y.py、atspi_linux.py）。
  - Kiteline 到某台机器的连接断了一分钟以上：那台机器上的会话会从列表里消失，推一条提醒，连回来时再说一声。
    从没连上过的机器（关着的）、用户停掉的不算。
手机上点「尝试重连」：框里有「重试 / 重新加载窗口」就替你按；远端窗口里「工作区不存在」这类关掉框、重新加载窗口
（Windows 敲命令面板，Linux 由配套扩展直接执行）；连接断了就立即重连。
要打开 claude.ai 的 Artifact 链接时弹的「是否要 Code 打开外部网站？」不提醒，直接替用户取消（见 artifact_dialog）；
投递时焦点不在 Claude 输入框、消息粘进了终端弹的「是否确实要将 3 行文本粘贴到终端?」同样取消（见 stray_paste_dialog）。
和 Mac 版同一套接口：state 里的 alerts、POST /api/alerts/reconnect。
"""

import hashlib
import os
import re
import subprocess
import threading
import time
import urllib.parse

from . import config, delivery, i18n, log

LINK_TEXT = "Kiteline 与这台机器的连接已断开，这台机器上的会话暂时看不到，正在自动重连"
RECONNECT_TITLES = {"重新加载窗口", "reload window", "重试", "retry", "立即重新连接", "reconnect now", "重新连接", "reconnect", "重新加载", "reload"}
CANCEL_TITLES = {"取消", "cancel"}
CONNECTION_WORDS = ("不存在", "does not exist", "连接", "connect", "断开", "找不到", "not found")
SETTLE = 4            # 框挂这么久才算（一闪而过的不算）


def plain(title):
    """按钮名去掉助记符和省略号：「重新加载窗口(&R)」「Reload &Window」「More Actions...」"""
    title = re.sub(r"\(&?\w\)$", "", title.replace("…", "").replace("...", "")).replace("&", "")
    return title.strip().lower()


def sentence(texts):
    """「工作区不存在」「请选择另一个工作区以打开。」→「工作区不存在。请选择另一个工作区以打开」（英文句子之间才空一格）"""
    text = ""
    for part in texts:
        line = " ".join(part.split())
        if not line:
            continue
        if line[-1] not in "。.？?！!":
            line += "。" if any(ord(ch) >= 0x3000 for ch in line) else "."
        if text:
            text += "" if text[-1] in "。？！" else " "
        text += line
    text = text.rstrip("。.")
    return text if len(text) <= 300 else text[:298] + "…"


def remote_place(place):
    """远端窗口：项目名后面带「[SSH: 主机]」「[WSL: Ubuntu]」这类"""
    return place.endswith("]") and " [" in place


def linux_idle_seconds():
    """Linux 上人多久没碰键盘鼠标：GNOME（Wayland、X11 都行）问 Mutter；别的桌面读不到，当人不在（照推）"""
    try:
        out = subprocess.run(["gdbus", "call", "--session", "--dest", "org.gnome.Mutter.IdleMonitor",
                              "--object-path", "/org/gnome/Mutter/IdleMonitor/Core", "--method", "org.gnome.Mutter.IdleMonitor.GetIdletime"],
                             capture_output=True, timeout=3).stdout.decode()
        return int(re.search(r"uint64\s+(\d+)", out).group(1)) / 1000.0   # 回的是「(uint64 124159,)」，单位毫秒
    except (OSError, subprocess.SubprocessError, AttributeError, ValueError):
        return float("inf")


def reload_linux_window(place):
    """Linux：经配套扩展让这个 VS Code 窗口「重新加载窗口」（扩展直接执行命令，不用像 Mac / Windows 那样敲命令面板）。
    窗口按标题里的项目名认：扩展报的文件夹名和地点里「[SSH: …]」前面那段对得上、远端与否也对得上，恰好一个才算"""
    from . import bridge
    folder = place.split(" [")[0].strip()
    remote = " [" in place
    matches = [w for w in bridge.windows()
               if any(os.path.basename(f.rstrip("/")) == folder for f in w.state.get("folders") or [])
               and ("remote" not in w.state or bool(w.state["remote"]) == remote)]   # 1.0.3 之前的扩展不报 remote
    if len(matches) != 1:
        return False, "没能找到这个 VS Code 窗口，请在电脑上重新加载窗口"
    try:
        matches[0].call("reload")
    except (OSError, ValueError) as exc:
        log.write("让「%s」重新加载窗口失败：%s" % (place, exc))
        return False, "VS Code 里的 Kiteline 配套扩展版本较旧，请在电脑上重新加载窗口"
    log.write("已让「%s」重新加载窗口" % place)
    return True, "已在电脑上重新加载「%s」窗口；如果仍连不上，会再提醒你" % place


def buttons(entry, titles):
    """对话框上名字是这些之一的按钮"""
    return [b for b in entry.get("buttons") or [] if plain(b.get("name") or "") in titles]


def open_dialogs():
    """开着的对话框：{键: (所在窗口, 地点, 读文字和按钮的函数)}；这个平台读不了返回 None。
    Windows：Win32 扫系统对话框（便宜），新框才用 UI Automation 读；键是对话框窗口句柄。
    Linux：开启了「读取 VS Code 弹框」才读（AT-SPI 一次查完，见 atspi_linux.py）；同一个窗口换了个框算新框，键里带上文字"""
    if config.IS_WINDOWS:
        from . import delivery_win, uia_win
        return {hwnd: (owner, delivery_win.delivery_place(title), lambda hwnd=hwnd: uia_win.read_dialog(hwnd))
                for hwnd, owner, title in delivery_win.editor_dialogs()}
    if config.IS_LINUX:
        from . import atspi_linux, vscode_a11y
        if not vscode_a11y.enabled():
            return None
        found = atspi_linux.dialogs()
        if found is None:
            return None
        result = {}
        for d in found:
            info = {"texts": d.get("texts") or [], "buttons": [{"name": b} for b in d.get("buttons") or []], "panel": bool(d.get("panel"))}
            key = "%s|%s|%s" % (d.get("pid"), d.get("frame"), "|".join(info["texts"]))
            result[key] = (d.get("frame") or "", delivery.title_place(d.get("frame") or ""), lambda info=info: dict(info))
        return result
    return None


def click(key, entry, button):
    """按对话框上的按钮（只管按，关没关调用方自己看）"""
    if config.IS_WINDOWS:
        from . import uia_win
        return uia_win.click_button(key, button.get("id"))
    from . import atspi_linux
    return atspi_linux.press(entry["owner"], entry["texts"], button.get("name"))


def artifact_dialog(entry):
    """要打开 claude.ai 的 Artifact 链接：Claude 扩展发布 Artifact 后自动打开的预览（链接带 via=auto_preview），或会话里点的链接。
    claude.ai 不在 VS Code 受信任的域里时弹「是否要 Code 打开外部网站？」，一律替用户取消（同 Mac 版）：浏览器和 Claude Code 走的网络
    常常不一样，换个 IP 打开 claude.ai 账号容易被风控；框挂着时手机发来的消息也投递不进去，回车还会按到默认的「打开」。
    只认 Artifact：登录（claude.ai/oauth/…）等别的链接照常由用户决定"""
    return bool(buttons(entry, CANCEL_TITLES)) and any(artifact_link(t) for t in entry.get("texts") or [])


def artifact_link(text):
    """框里显示的是不是 claude.ai 的 Artifact 链接（claude.ai/artifact/…、claude.ai/code/artifact/…）。扩展传的是 Uri 对象时
    VS Code 会把超过 60 个字符的链接截成「https://claude.ai/artifact/xxx?...preview」，截的只是问号后面，路径总是完整的"""
    try:
        url = urllib.parse.urlsplit(text.strip())
        host = (url.hostname or "").lower()
    except ValueError:
        return False
    return url.scheme in ("http", "https") and (host == "claude.ai" or host.endswith(".claude.ai")) and "/artifact" in url.path


_pastes_lock = threading.Lock()
_recent_pastes = []   # Kiteline 最近一分钟往 VS Code 里粘过的话：[(时间, 文字)]


def note_paste(text):
    """投递粘贴前记一下：粘进了终端时认得出它弹的框（见 stray_paste_dialog）"""
    now = time.time()
    with _pastes_lock:
        _recent_pastes[:] = [p for p in _recent_pastes if now - p[0] < 60] + [(now, text)]


def stray_paste_dialog(entry):
    """Kiteline 投递时焦点不在 Claude 输入框、粘进了终端：VS Code 弹「是否确实要将 3 行文本粘贴到终端?」（多行才弹），
    预览是前三行、每行前 30 个字（长的带「…」）。预览对得上刚投递的话才算，用户自己往终端里粘的不管（同 Mac 版 Dialog.strayPaste）"""
    if not buttons(entry, CANCEL_TITLES):
        return False
    lines = [line.strip() for t in entry.get("texts") or [] for line in t.splitlines()]
    if not any("粘贴到终端" in line or "into the terminal" in line.lower() for line in lines):
        return False
    header = next((i for i, line in enumerate(lines) if line.lower() in ("预览:", "预览：", "preview:")), None)
    first = next((line for line in lines[header + 1:] if line), None) if header is not None else None
    if not first:
        return False
    head = first[:-1] if first.endswith("…") else first
    if len(head) < 4:
        return False
    now = time.time()
    with _pastes_lock:
        pasted = [text for at, text in _recent_pastes if now - at < 60]
    return any(next((line.strip() for line in text.splitlines() if line.strip()), "").startswith(head) for text in pasted)


def auto_cancel(entry):
    """替用户按掉的框：要打开 Artifact 链接的（artifact）、投递时粘进了终端的（paste）；不是返回 None"""
    if artifact_dialog(entry):
        return "artifact"
    return "paste" if stray_paste_dialog(entry) else None


def cancel_artifact_dialog(key, entry, kind="artifact"):
    """按 Artifact 链接框、投递粘错的框上的「取消」；同一个框日志只记一次（按了没关的，下一拍再按）"""
    clicked = click(key, entry, buttons(entry, CANCEL_TITLES)[0])
    if not entry.get("cancelled"):
        entry["cancelled"] = True
        where = "%s %s" % (entry.get("place") or "VS Code", sentence(entry.get("texts") or []))
        log.write(("投递的消息粘进了终端，已替用户取消：" if kind == "paste" else "已拦截 claude.ai 的 Artifact 链接：") + where)
    return clicked


def cancel_artifact_dialogs():
    """投递前、回车前用：VS Code 弹着该替用户按掉的框（见 auto_cancel）就先取消，等它关上（最多 1 秒），关上了返回 True。
    不然这条消息投不进去，回车还可能按到框里默认的「打开」「粘贴」"""
    pressed = set()
    for key, (owner, place, read) in (open_dialogs() or {}).items():
        entry = read()
        if entry is None:
            continue
        entry.update(owner=owner, place=place)
        kind = auto_cancel(entry)
        if kind and cancel_artifact_dialog(key, entry, kind):
            pressed.add(key)
    if not pressed:
        return False
    until = time.time() + 1
    while time.time() < until:
        time.sleep(0.1)
        if not pressed & set(open_dialogs() or {}):
            return True
    return False


def _test_value(name, default):
    """自测（dry-run）时缩短等待"""
    if delivery.DRY_RUN and os.environ.get(name):
        try:
            return float(os.environ[name])
        except ValueError:
            pass
    return default


class Alerts:
    LINK_GRACE = _test_value("CCPULSE_ALERT_LINK_GRACE", 60)   # 睡眠唤醒、网络切换时会断几秒再自己连上

    IDLE_BEFORE_PUSH = _test_value("CCPULSE_ALERT_IDLE", 30)

    def __init__(self, app):
        self.app = app
        self._lock = threading.Lock()
        self.alerts = []
        self._dialogs = {}           # 对话框的键 → {"first", "owner", "place", "texts", "buttons", "panel"}（读过一次就记着；键见 open_dialogs）
        self._dialog_ids = {}        # 提示的 id → 对话框的键（手机上点「尝试重连」时找回是哪个框）
        self._dialog_notified = set()
        self._ever_live = set()
        self._down_since = {}
        self._notified = set()       # 推过断线的来源：连回来时说一声
        self._manual_retry = {}      # 手机上点了重连的时刻：重连那一下是 stopped，照算断着

    def start(self):
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while True:
            time.sleep(3)
            try:
                self.tick(time.time())
            except Exception as exc:  # noqa: BLE001
                log.write("断线检查出错：%s" % exc)

    def payload(self):
        with self._lock:
            return [dict(a) for a in self.alerts]

    # MARK: VS Code 对话框

    def _scan_dialogs(self, now):
        """这一拍看到的对话框提示（挂满 SETTLE 秒、读得出字的）；要打开 Artifact 链接的框直接取消，不提示"""
        seen = open_dialogs()
        if seen is None:
            self._dialogs.clear()
            return []
        for key in list(self._dialogs):
            if key not in seen:
                self._dialogs.pop(key)
        result = []
        for key, (owner, place, read) in seen.items():
            entry = self._dialogs.setdefault(key, {"first": now, "owner": owner, "place": place})
            # 新框也马上读：Artifact 链接的框要尽快取消。没挂满 SETTLE 秒的读了先不记（框刚弹出时可能还没画全），之后记着不再读
            info = entry if "texts" in entry else read()
            if info is None:
                continue
            kind = auto_cancel(info)
            if kind:
                entry.update(info)
                cancel_artifact_dialog(key, entry, kind)
                continue
            if now - entry["first"] < SETTLE:
                continue
            entry.update(info)
            if entry.get("panel") or not entry.get("texts") or not entry.get("buttons"):
                continue   # 打开 / 保存面板：人就在电脑前操作
            result.append(self._dialog_alert(key, entry))
        return result

    def _dialog_alert(self, key, entry):
        texts = entry.get("texts") or []
        digest = hashlib.md5("|".join(texts).encode("utf-8")).hexdigest()[:8]
        words = " ".join(texts).lower()
        reload_after_cancel = remote_place(entry["place"]) and bool(buttons(entry, CANCEL_TITLES)) \
            and any(w in words for w in CONNECTION_WORDS)
        can = bool(buttons(entry, RECONNECT_TITLES)) or reload_after_cancel
        handle = key if isinstance(key, int) else hashlib.md5(key.encode("utf-8")).hexdigest()[:8]
        alert = {"id": "d%s-%s" % (handle, digest), "kind": "dialog", "title": entry["place"], "text": sentence(texts),
                 "since": entry["first"] * 1000}
        self._dialog_ids[alert["id"]] = key
        if can:
            alert["actions"] = ["reconnect"]
        return alert

    def _dialog_should_push(self):
        if config.IS_LINUX:
            return linux_idle_seconds() >= self.IDLE_BEFORE_PUSH
        from . import delivery_win
        if time.time() < delivery_win.AUTOMATION_UNTIL[0]:
            return False   # Kiteline 投递时 VS Code 弹的确认框：投递那边已经回给手机了
        return delivery_win.idle_seconds() >= self.IDLE_BEFORE_PUSH

    def _notify_dialog(self, alert):
        can = "reconnect" in (alert.get("actions") or [])
        tail = "可在手机上轻点「尝试重连」" if can else "需要在电脑上处理"
        body = "VS Code 弹出提示：%s。%s" % (alert["text"], tail)
        body_en = "VS Code is showing a dialog: %s. %s" % (alert["text"], i18n.translate(tail))
        self.app.server.notify_alert("editor", alert["title"] or "VS Code", "需要处理", body, alert, body_en=body_en)
        log.write("提醒：%s %s" % (alert["title"], alert["text"]))

    # MARK: 汇总

    def tick(self, now):
        store = self.app.store
        with store.lock:
            sources = list(store.sources.values())
        dialogs = self._scan_dialogs(now)
        ids = {a["id"] for a in dialogs}
        self._dialog_ids = {i: k for i, k in self._dialog_ids.items() if i in ids}
        self._dialog_notified &= ids
        for alert in dialogs:
            if alert["id"] not in self._dialog_notified and self._dialog_should_push():
                self._dialog_notified.add(alert["id"])
                self._notify_dialog(alert)
        current, fresh = list(dialogs), []
        for source in sources:
            if source.live:
                self._ever_live.add(source.id)
                self._down_since.pop(source.id, None)
                self._manual_retry.pop(source.id, None)
                continue
            retrying = now - self._manual_retry.get(source.id, 0) < 5
            if source.id not in self._ever_live or (source.state == "stopped" and not retrying):
                self._down_since.pop(source.id, None)
                continue
            since = self._down_since.setdefault(source.id, now)
            if now - since < self.LINK_GRACE:
                continue
            text = LINK_TEXT
            if source.state == "failed" and source.state_detail:
                text += "（%s）" % source.state_detail.strip()
            alert = {"id": "l" + source.id, "kind": "link", "title": source.name, "text": text, "textEn": i18n.translate(text),
                     "since": since * 1000, "actions": ["reconnect"]}
            current.append(alert)
            if source.id not in self._notified:
                self._notified.add(source.id)
                fresh.append(alert)
        ids = {a["id"] for a in current}
        recovered = [sid for sid in self._notified if "l" + sid not in ids]
        for sid in recovered:
            self._notified.discard(sid)
            source = next((s for s in sources if s.id == sid), None)
            if source and source.live:
                self.app.server.notify_alert("link", source.name, "已重新连上", "这台机器上的会话已恢复显示", None)
                log.write("提醒：%s 已重新连上" % source.name)
        for alert in fresh:
            self.app.server.notify_alert("link", alert["title"], "连接已断开", alert["text"], alert)
            log.write("提醒：%s %s" % (alert["title"], alert["text"]))
        with self._lock:
            changed = current != self.alerts
            self.alerts = current
        if changed:
            self.app.server.publish_state()

    def reconnect(self, alert_id):
        """手机上点了「尝试重连」：返回 (成功, 给手机看的话)"""
        if alert_id.startswith("d"):
            return self._reconnect_dialog(alert_id)
        if not alert_id.startswith("l"):
            return False, "电脑上的这个提示已经消失"
        source_id = alert_id[1:]
        source = self.app.store.sources.get(source_id)
        if not source:
            return False, "这台机器已不在 Kiteline 的来源列表中"
        log.write("手机要求立即重连：%s" % source.name)
        self._manual_retry[source_id] = time.time()
        self.app.reconnect_sources(source_id)
        return True, "正在重新连接「%s」" % source.name

    def _reconnect_dialog(self, alert_id):
        """框里有重连按钮就按它；远端窗口里「工作区不存在」这类：按取消，再重新加载窗口"""
        key = self._dialog_ids.get(alert_id)
        entry = self._dialogs.get(key) if key is not None else None

        def still_open():
            return key in (open_dialogs() or {})
        if not entry or "texts" not in entry or self._dialog_alert(key, entry)["id"] != alert_id or not still_open():
            return False, "电脑上的这个对话框已经关闭"

        def press(button):
            if not click(key, entry, button):
                return False
            until = time.time() + 2
            while time.time() < until:
                time.sleep(0.25)
                if not still_open():
                    return True
            return False

        retry = buttons(entry, RECONNECT_TITLES)
        if retry:
            closed = press(retry[0])
            log.write("手机要求重连：按了「%s」对话框上的「%s」（%s）" % (entry["place"], retry[0].get("name"), "框已关" if closed else "框还在"))
            return (True, "已在电脑上重新连接，VS Code 窗口正在重新加载") if closed else (False, "没能按下对话框上的按钮，请在电脑上处理")
        alert = self._dialog_alert(key, entry)
        cancel = buttons(entry, CANCEL_TITLES)
        if "reconnect" not in (alert.get("actions") or []) or not cancel:
            return False, "这个对话框需要在电脑上处理"
        if not press(cancel[0]):
            return False, "没能关闭对话框，请在电脑上处理"
        log.write("手机要求重连：关掉「%s」的对话框，重新加载窗口" % entry["place"])
        if config.IS_WINDOWS:
            from . import delivery_win
            return delivery_win.reload_window(entry["owner"])
        return reload_linux_window(entry["place"])
