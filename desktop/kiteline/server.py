"""手机端服务（对应 Mac 版 MobileServer.swift）：鉴权、配对、会话列表、实时事件（SSE）、历史、图片、发送……
接口和返回格式与 Mac 版一致，iPhone 上的 Kiteline App 不用改就能连 Windows / Linux。
网页版已下线（同 Mac 版，10-22 起顾客打不开网页）：根路径只回 NOTICE_PAGE 说明页。

令牌可以放在请求头 X-CCP-Token、查询参数 t、或 Cookie ccp 里（EventSource 和 <img> 不能带头）。
"""

import base64
import hashlib
import hmac
import json
import os
import plistlib
import re
import sys
import threading
import time
import uuid

from . import aggregate, bark, config, delivery, faces, guest, i18n, log, netinfo, setup_tools, tls, tts
from . import translate as translator
from .httpd import Response, StreamReply
from .store import hostable as store_hostable

AUDIO_TYPES = ("audio/wav", "audio/x-wav", "audio/wave", "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac",
               "audio/webm", "audio/ogg", "audio/mpeg")
LINK_ONLY = ("/api/ping", "/api/info", "/api/devices/register")
# 手表外观（和 iOS 的 Look.swift 一致）：phone / watch = 跟手机 / 跟手表
VALID_LOOK = {
    "theme": {"phone", "classic", "clay", "ocean", "pine", "violet", "graphite", "rose", "amber", "teal", "indigo", "wine", "olive", "mocha", "navy"},
    "font": {"phone", "system", "rounded", "lanting", "mono", "serif", "kai", "baoli", "hannotate", "hanzipen", "yuppy", "wawati",
             "xingkai", "libian", "weibei"},
    "textSize": {"watch", "xs", "s", "m", "l", "xl", "xxl", "xxxl"},
}
SESSION_ID = re.compile(r"^[A-Za-z0-9-]{8,64}$")


# 浏览器打开根路径时的说明页：网页版已下线，只说明请用 Kiteline App 连接（和 Mac 版 MobileServer.noticeHTML 是同一份，改要两边改）
NOTICE_PAGE = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Kiteline</title>
<style>
body { margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center; background: #f5f5f7; color: #1d1d1f;
       font: 15px/1.7 -apple-system, BlinkMacSystemFont, "PingFang SC", "Segoe UI", "Microsoft YaHei", sans-serif; }
main { max-width: 440px; padding: 40px 24px; text-align: center; }
h1 { margin: 0 0 14px; font-size: 22px; font-weight: 600; letter-spacing: 0.2px; }
p { margin: 0; color: #6e6e73; }
p.en { margin-top: 16px; font-size: 13px; }
@media (prefers-color-scheme: dark) { body { background: #0b0b0c; color: #f5f5f7; } p { color: #98989d; } }
</style>
</head>
<body>
<main>
<h1>Kiteline</h1>
<p>Kiteline 服务正在这台电脑上运行。<br>请使用 iPhone 上的 Kiteline App 连接。</p>
<p class="en">Kiteline is running on this computer.<br>Please connect with the Kiteline app on your iPhone.</p>
</main>
</body>
</html>
"""
NOTICE_CSP = "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
# 世界模式的网页（Resources/world，各端共用一份，见 world.md（内部文档））：只许连自己、图片和音频可以是 blob / data
WORLD_CSP = ("default-src 'self'; img-src 'self' data: blob:; media-src 'self' blob:; style-src 'self' 'unsafe-inline'; "
             "script-src 'self'; connect-src 'self'; font-src 'self'; base-uri 'none'; form-action 'none'")
WORLD_TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
               ".json": "application/json", ".png": "image/png", ".jpg": "image/jpeg", ".svg": "image/svg+xml",
               ".woff2": "font/woff2", ".txt": "text/plain; charset=utf-8"}


def world_root():
    """世界网页在哪：打包后的 Windows 版在 _MEIPASS/world，Linux 包在 desktop/world，开发时用仓库的 Resources/world"""
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [os.environ.get("KITELINE_WORLD_ROOT") or ""]
    base = getattr(sys, "_MEIPASS", None)
    if base:
        candidates.append(os.path.join(base, "world"))
    candidates += [os.path.join(here, "..", "world"), os.path.join(here, "..", "..", "Resources", "world")]
    for folder in candidates:
        if folder and os.path.isfile(os.path.join(folder, "index.html")):
            return os.path.realpath(folder)
    return None


def image_response(data, mime):
    return Response(200, {"Content-Type": mime, "Cache-Control": "private, max-age=31536000, immutable",
                          "X-Content-Type-Options": "nosniff",
                          "Content-Security-Policy": "sandbox; default-src 'none'; style-src 'unsafe-inline'"}, data)


# 对话里的图片缩略图（和 Mac 版 Thumbnail.swift 一致）：手机在对话里只显示 100×100 点的方块，向电脑要 ?thumb=像素
# （3 倍屏 300），这里按短边缩小、居中裁成正方形、存成 JPEG，单张几 KB 到二十几 KB；点开看大图时再取原图
THUMB_SIZES = range(32, 641)
_thumbs = {}
_thumbs_bytes = [0]
_thumbs_lock = threading.Lock()


def square_thumbnail(data, side):
    """按短边缩到 side、居中裁成 side×side 的 JPEG（带透明的先铺白底）；认不出的图返回 None"""
    try:
        import io
        from PIL import Image, ImageOps
        with Image.open(io.BytesIO(data)) as image:
            # 打开只读了文件头：像素太多的（几 MB 的 PNG 能解出上亿像素、吃掉几百 MB 内存）不做缩略图，给原图
            if image.width * image.height > 60_000_000:
                return None
            image.draft("RGB", (side * 2, side * 2))   # JPEG 解码时直接缩小，不先解出整张大图
            image = ImageOps.exif_transpose(image)
            if image.mode in ("RGBA", "LA", "P"):
                image = image.convert("RGBA")
                background = Image.new("RGB", image.size, (255, 255, 255))
                background.paste(image, mask=image.getchannel("A"))
                image = background
            else:
                image = image.convert("RGB")
            thumb = ImageOps.fit(image, (side, side), Image.LANCZOS)
            out = io.BytesIO()
            thumb.save(out, "JPEG", quality=72, optimize=True)
            return out.getvalue()
    except Exception:  # noqa: BLE001
        return None


def thumb_reply(data, mime, request, cache_key):
    """要了缩略图（?thumb=像素）就换成缩略图，算好的按 key 记在内存里（最多 32 MB）；没要、或图认不出就给原图"""
    try:
        side = int(request.query.get("thumb", ""))
    except ValueError:
        side = 0
    if side not in THUMB_SIZES:
        return image_response(data, mime)
    key = "%s|%d" % (cache_key, side)
    with _thumbs_lock:
        hit = _thumbs.get(key)
    if hit is None:
        hit = square_thumbnail(data, side)
        if hit is None:
            return image_response(data, mime)
        with _thumbs_lock:
            _thumbs[key] = hit
            _thumbs_bytes[0] += len(hit)
            while _thumbs_bytes[0] > 32 * 1024 * 1024 and _thumbs:
                _thumbs_bytes[0] -= len(_thumbs.pop(next(iter(_thumbs))))
    return image_response(hit, "image/jpeg")


CLEAR_COOKIE = "ccp=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"


class MobileServer:
    def __init__(self, app):
        self.app = app
        self._streams = {}            # id → (stream, 设备 id)
        self._stream_langs = {}       # id → 这条连接要的语言（en / zh），见 i18n
        self._lock = threading.Lock()
        self._foreground = {}         # 设备 id → 最近一次「我在前台」
        self._recent_sends = {}
        self._last_state = ""
        # 上一份广播出去的完整状态和它的序号（同 Mac 版 MobileServer.lastState / stateSeq）：连接时带 patch=1 的客户端
        # 之后只收变了的部分（statepatch，见 state_patch）；还没收到第一份整份的连接先不收状态广播
        self._state = {}
        self._state_seq = 0
        self._patch_streams = set()
        self._pending_streams = set()
        self._state_lock = threading.RLock()   # 发布状态和新连接发第一份整份要排队：序号前后接得上
        self.servers = []
        self.secure_status = "未启动"
        self.status = "未启动"
        threading.Thread(target=self._heartbeat, daemon=True).start()

    # MARK: 推送给各端

    @property
    def online_devices(self):
        with self._lock:
            return {device for _, device in self._streams.values() if device}

    def client_count(self):
        return len(self.online_devices)

    def publish_state(self):
        payload = self.app.state_payload()
        text = json.dumps(payload, ensure_ascii=False, sort_keys=True)
        with self._state_lock:
            if text == self._last_state:
                return
            self._last_state = text
            previous, base = self._state, self._state_seq
            self._state = payload
            self._state_seq += 1
            # iPhone 锁屏 / 灵动岛上的实时活动跟着会话状态走
            self.app.live.update(payload.get("sessions") or [])
            full = dict(payload, stateSeq=self._state_seq)
            full_text = json.dumps(full, ensure_ascii=False, sort_keys=True)
            patch = state_patch(previous, payload, base, self._state_seq, len(full_text.encode("utf-8"))) if previous else None
            self._broadcast_state(full, full_text, patch)

    def _broadcast_state(self, full, full_text, patch):
        """要增量的连接发 statepatch，其余发整份；英文的连接把界面文字换成英文（每种只换一次、各条共用）"""
        with self._lock:
            targets = [(s, self._stream_langs.get(k, "zh"), patch is not None and k in self._patch_streams)
                       for k, (s, _) in self._streams.items() if k not in self._pending_streams]
        ready = {}
        for stream, lang, wants_patch in targets:
            event = "statepatch" if wants_patch else "state"
            cache = event + "-" + lang
            if cache not in ready:
                if lang == "en":
                    body = json.dumps(i18n.localize(patch if wants_patch else full), ensure_ascii=False, sort_keys=True)
                else:
                    body = json.dumps(patch, ensure_ascii=False, sort_keys=True) if wants_patch else full_text
                ready[cache] = "event: %s\ndata: %s\n\n" % (event, body)
            stream.send(ready[cache])

    def publish(self, event, payload):
        # 对话增量、会话之间的消息全是内容：英文连接也原样发，只换其中电脑生成的事件提示（同 /api/history）
        if event in ("peers", "term"):   # 终端输出原样转（没有界面文字）
            english = None
        elif event == "entries":
            english = (lambda: self._event_text(event, dict(payload, items=localize_events(payload.get("items") or [])))) \
                if any(item.get("t") == "event" for item in payload.get("items") or []) else None
        else:
            english = lambda: self._event_text(event, i18n.localize(payload))   # noqa: E731
        self._broadcast(self._event_text(event, payload), english)

    @staticmethod
    def _event_text(event, payload):
        return "event: %s\ndata: %s\n\n" % (event, json.dumps(payload, ensure_ascii=False))

    def _broadcast(self, text, english=None):
        """english：英文连接要发的版本（用到才算，只算一次）"""
        with self._lock:
            streams = [(s, self._stream_langs.get(key, "zh")) for key, (s, _) in self._streams.items()]
        en_text = None
        for stream, lang in streams:
            if lang == "en" and english:
                if en_text is None:
                    en_text = english()
                stream.send(en_text)
            else:
                stream.send(text)

    def _heartbeat(self):
        while True:
            time.sleep(15)
            self._broadcast(": ping\n\n")   # SSE 注释行：保活

    def in_app_devices(self):
        stamp = time.time()
        online = self.online_devices
        with self._lock:
            return {d for d, at in self._foreground.items() if stamp - at < 75 and d in online}

    def notify(self, kind, title, body, key=None, route=None, urgency="high", english=None):
        """english：源头按语言拼好的英文版 (标题, 正文)（日报、早安简报）；没给就在出口逐句查表"""
        """提醒：正开着 Kiteline 的设备只弹 App 里的横幅；在后台的设备收系统通知"""
        app = self.app
        in_app = self.in_app_devices()
        wants = app.cfg.should_push(kind, key)
        delivery_state = "quiet"
        mobile = app.cfg.mobile
        use_bark = wants and not in_app and bark.wants(kind, mobile)
        if wants:
            pushed = bool(app.push.device_ids(in_app)) or any(not s.get("deviceId") for s in app.push.subscriptions)
            delivery_state = "sent" if pushed or use_bark else ("none" if not in_app else "app")
        elif key and key in app.cfg.mobile["mutedSessions"] and kind in ("conclusion", "image", "error", "stuck", "todo", "keyinfo", "goal"):
            delivery_state = "muted"
        entry = app.inbox.add(kind, title, body, key, route, delivery_state, english) if kind != "test" else None
        payload = {"kind": kind, "title": title, "body": body, "inbox": entry["id"] if entry else "",
                   "pushed": sorted(app.push.device_ids(in_app)) if wants else [], "at": time.time() * 1000}
        if key:
            payload["key"] = key
        if route is not None:
            payload["route"] = route
        if english:
            payload["titleEn"], payload["bodyEn"] = english
        self.publish("notify", payload)
        if not wants:
            log.write("免打扰：「%s」不推送" % title)
            return
        heads = {"attention": "需要确认", "conclusion": "已完成", "image": "发来图片", "todo": "新待办", "keyinfo": "关键信息",
                 "error": "出错已停止", "stuck": "可能停滞"}
        if use_bark:
            # 目标的标题里已经带着「目标已达成」（notify_goal）
            bark_title = "%s · %s" % (title, heads.get(kind, "新消息")) if route is None and kind != "goal" else title
            bark_body = body
            if kind == "goal" and english and i18n.ui_english():
                bark_title, bark_body = english
            threading.Thread(target=bark.send, args=(bark_title, bark_body, kind, mobile), daemon=True).start()
        if not app.push.subscriptions:
            return
        head = heads.get(kind, "新消息")
        if route is None and kind == "goal":
            # 标题里已经带着「目标已达成」，中英两份源头拼好（notify_goal）
            data = {"title": title, "body": body[:240], "key": key or "", "kind": kind}
            english = dict(data, title=english[0], body=english[1][:240]) if english else dict(data)
        elif route is None:
            data = {"title": "%s · %s" % (title, head), "body": body[:240], "key": key or "", "kind": kind}
            english = dict(data, title="%s · %s" % (title, i18n.translate(head)), body=i18n.translate(body)[:240])
        else:
            # key：跟着的会话（群消息 = 发言的那个）：不认识这个 route 的老版本点开时进这个会话
            data = {"title": title, "body": body[:400], "key": key or kind, "route": route, "kind": kind}
            en_title, en_body = english or (i18n.translate(title), i18n.translate(body))
            english = dict(data, title=en_title, body=en_body[:400])
            urgency = "normal"
        en_devices = i18n.english_devices()
        in_app = set(in_app) | app.peers.push_suppressed()   # 别的电脑替手机登记的：那台连着本机时由它推（免得收两条）
        app.push.send(data, urgency=urgency, skip=set(in_app) | en_devices)
        targets = en_devices - set(in_app)
        if targets:
            app.push.send(english, urgency=urgency, only=targets)

    def notify_goal(self, title, head, body, body_en, key):
        """目标（/goal）达成、做不到、停下：标题「会话 · 目标已达成」，正文是目标和结果；中英两份在源头拼好（正文里夹着目标原文）（同 Mac 版 notifyGoal）"""
        shown, shown_en = "%s · %s" % (title, head), "%s · %s" % (title, i18n.translate(head))
        self.notify("goal", shown, body, key, english=(shown_en, body_en))

    def notify_alert(self, kind, title, head, body, alert, body_en=None):
        """要人处理的状况（见 alerts.py）：VS Code 弹着对话框、到某台机器的连接断了 / 又连上了。带 alert 的锁屏通知长按有「尝试重连」。
        body_en：源头拼好的英文（里面夹着 VS Code 对话框的原文，按句式反推会切错）；没给就在出口逐句查表"""
        app = self.app
        in_app = self.in_app_devices()
        wants = app.cfg.should_push(kind, None)
        mobile = app.cfg.mobile
        use_bark = wants and not in_app and bark.wants(kind, mobile)
        delivery_state = "quiet"
        if wants:
            pushed = bool(app.push.device_ids(in_app)) or any(not s.get("deviceId") for s in app.push.subscriptions)
            delivery_state = "sent" if pushed or use_bark else ("none" if not in_app else "app")
        entry = app.inbox.add(kind, title, body, None, None, delivery_state, (title, body_en) if body_en else None)
        payload = {"kind": kind, "title": title, "body": body, "inbox": entry["id"] if entry else "",
                   "pushed": sorted(app.push.device_ids(in_app)) if wants else [], "at": time.time() * 1000}
        if alert:
            payload["alert"] = alert["id"]
        if body_en:
            payload["bodyEn"] = body_en
        self.publish("notify", payload)
        if not wants:
            return
        if use_bark:
            threading.Thread(target=bark.send, args=("%s · %s" % (title, head), body, kind, mobile), daemon=True).start()
        if not app.push.subscriptions:
            return
        data = {"title": "%s · %s" % (title, head), "body": body[:240], "kind": kind}
        if alert and "reconnect" in (alert.get("actions") or []):
            data.update(alert=alert["id"], actions=["reconnect"])
        english = dict(data, title="%s · %s" % (title, i18n.translate(head)), body=(body_en or i18n.translate(body))[:240])
        en_devices = i18n.english_devices()
        in_app = set(in_app) | app.peers.push_suppressed()
        app.push.send(data, skip=set(in_app) | en_devices)
        targets = en_devices - set(in_app)
        if targets:
            app.push.send(english, only=targets)

    # MARK: 路由

    def route(self, request):
        response = self._route(request)
        if not isinstance(response, StreamReply):
            self._audit(request, response)
            if i18n.lang_of(request) == "en" and request.path not in i18n.CONTENT_ONLY \
                    and (response.headers.get("Content-Type") or "").startswith("application/json"):
                try:
                    extra = ("title",) if request.path == "/api/readiness" else ()
                    response.body = json.dumps(i18n.localize(json.loads(response.body), extra), ensure_ascii=False).encode("utf-8")
                except ValueError:
                    pass
            # 以前把令牌放进过 Cookie：浏览器的 Cookie 不分端口，本机别的服务也会收到。不再发、不再认，看到旧的就让浏览器删掉
            if request.cookies.get("ccp") and "Set-Cookie" not in response.headers:
                response.headers["Set-Cookie"] = CLEAR_COOKIE
        return response

    def _audit(self, request, response):
        try:
            reply = json.loads(response.body.decode("utf-8")) if response.body[:1] == b"{" else {}
        except ValueError:
            reply = {}
        target = None
        key = request.query.get("key")
        if key:
            record = self.app.store.record(key)
            target = (record.snap.get("title") or record.snap.get("name")) if record else key.split("#")[-1][:8]
        elif request.path == "/api/new-session" and request.json:
            target = os.path.basename(str(request.json.get("cwd", "")).rstrip("/\\"))
        self.app.audit.record(request, response.status, reply, self._client(request), target)

    def _client(self, request):
        for token in self._tokens(request):
            device = self.app.devices.peek(token)
            if device:
                via = "的 Apple Watch" if request.query.get("via") == "watch" else ""
                return "%s%s · %s" % (device["name"], via, request.remote)
        if request.remote in ("127.0.0.1", "::1"):
            return "这台电脑"
        from .devices import default_name
        return "%s · %s" % (default_name(request.headers.get("user-agent", "")), request.remote)

    @staticmethod
    def _tokens(request):
        return [t for t in (request.headers.get("x-ccp-token"), request.query.get("t")) if t]

    def preauthorized(self, headers, query, cookies):
        """请求体很大时，收之前先核对令牌（主令牌或有效的设备令牌，只查不记），陌生人直接 401"""
        expected = self.app.cfg.mobile["token"]
        for token in (headers.get("x-ccp-token"), query.get("t")):
            if not token:
                continue
            if expected and hmac.compare_digest(token, expected):
                return True
            if self.app.devices.peek(token):
                return True
        return False

    def _authorize(self, request):
        """返回 ("master", None) / ("device", 设备) / ("link", 令牌) / None"""
        expected = self.app.cfg.mobile["token"]
        for token in self._tokens(request):
            if expected and hmac.compare_digest(token, expected):
                return "master", None
            pro = request.headers.get("x-kiteline-pro")
            device = self.app.devices.authenticate(token, request.remote, request.headers.get("x-kiteline-client"),
                                                   request.headers.get("user-agent"), None if pro is None else pro == "1",
                                                   request.headers.get("x-kiteline-mp"))
            if device:
                return "device", device
            if token.startswith("p") and self.app.pairing.link_valid(token):
                return "link", token
        return None

    def _route(self, request):
        method, path = request.method, request.path
        if method == "OPTIONS":
            return Response(204)
        if method == "GET" and path == "/ca.mobileconfig":
            return self._mobileconfig()
        if path == "/pair" and method in ("GET", "POST"):
            return self._pair(request)
        if path == "/desktop" or path.startswith("/api/desktop/"):
            # 主令牌（本机的单实例检查、脚本）或控制台页面自己的会话令牌（票据进门时发的，只管 /api/desktop/*）
            auth = self._authorize(request)
            allowed = bool(auth and auth[0] == "master") or self.app.console.session_ok(request.headers.get("x-ccp-token"))
            handled = self.app.console.handle(request, allowed)
            return handled or Response.error("未配对或令牌已失效", 401)
        if method == "GET" and (path == "/world" or path.startswith("/world/")):
            # 世界模式（Windows 客户端的 WebView2、Linux 的浏览器窗口打开这里）：静态文件不要令牌，数据接口照旧要
            return self._world_file(path)
        if method == "GET" and path.startswith("/g/"):
            # 游客链接（局域网只读分享）：页面和内容都由这台电脑给，只认分享中的编号（见 guest.py）
            status, headers, body = self.app.guest.serve(path, request.headers.get("if-none-match"))
            return Response(status, headers, body)
        if method == "GET" and not path.startswith("/api/"):
            # 网页版已下线：根路径只有说明页，别的路径（app.js、manifest……）一律 404
            return self._notice() if path in ("/", "", "/index.html") else Response.text("not found", 404)

        auth = self._authorize(request)
        if not auth:
            return Response.error("未配对或令牌已失效", 401)
        kind, who = auth
        if kind == "link" and path not in LINK_ONLY:
            return Response.error("配对链接只能用于配对，请重新扫码", 401)
        device_id = who["id"] if kind == "device" else None
        if request.query.get("via") == "watch" and device_id:
            self.app.devices.touch_watch(device_id)
        i18n.note_lang(device_id, i18n.lang_of(request))
        # 电脑互联（peers.py）：别的电脑来取本机的会话；手机问另一台电脑；对别的电脑上的会话的操作整条转过去
        if path.startswith("/api/peer/"):
            return self.app.peers.handle(request, who if kind == "device" else None)
        if (method, path) == ("GET", "/api/computers"):
            return Response.json(self.app.peers.computers_payload())
        if (method, path) == ("POST", "/api/computers/enroll"):
            if kind != "device" or who.get("kind") == "computer":
                return Response.error("只有手机能用", 403)
            return self.app.peers.enroll(who, str((request.json or {}).get("id") or ""))
        target = self.app.peers.forward_target(request)
        if target:
            if path in ("/api/send", "/api/resume"):
                self.app.idle_close.touch([request.query.get("key", "")])
            return self.app.peers.forward(request, target)
        if (method, path) == ("POST", "/api/viewed"):
            self.app.peers.note_viewed((request.json or {}).get("keys") or [])
        handler = ROUTES.get((method, path))
        if handler:
            return handler(self, request, kind, who, device_id)
        if path == "/api/todos" or path.startswith("/api/todos/"):
            status, result = self.app.todos.handle(method, path, request.json, request.query)
            if isinstance(result, tuple):
                return thumb_reply(result[0], result[1], request, "todo|%s" % request.query.get("ref", ""))
            return Response.json(result, status)
        if path == "/api/tabgroups" or path.startswith("/api/tabgroups/"):
            status, result = self.app.tab_groups.handle(method, path, request.json)
            return Response.json(result, status)
        if path == "/api/favorites" or path.startswith("/api/favorites/"):
            status, result = self.app.favorites.handle(method, path, request.json, request.query)
            if isinstance(result, tuple):
                return thumb_reply(result[0], result[1], request, "favorite|%s" % request.query.get("ref", ""))
            return Response.json(result, status)
        if path == "/api/groups" or path.startswith("/api/groups/"):
            # 会话群（见 groups.py）：群里的图给缩略图，文件原样
            status, result = self.app.groups.handle(method, path, request.json, request.query)
            if isinstance(result, tuple):
                if result[1].startswith("image/"):
                    return thumb_reply(result[0], result[1], request, "group|%s|%s" % (request.query.get("id") or request.query.get("key", ""), request.query.get("ref", "")))
                return Response(200, {"Content-Type": result[1], "Cache-Control": "private, max-age=31536000, immutable",
                                      "X-Content-Type-Options": "nosniff", "Content-Security-Policy": "sandbox; default-src 'none'"}, result[0])
            return Response.json(result, status)
        return Response.error("接口不存在", 404)

    # MARK: 说明页、配对

    @staticmethod
    def _world_file(path):
        root = world_root()
        if not root:
            return Response.text("not found", 404)
        rel = path[len("/world"):].lstrip("/") or "index.html"
        if rel == "en.json":
            # 英文界面的文字：电脑端整张英文表（网页按中文原文查）
            target = os.path.join(os.path.dirname(os.path.abspath(__file__)), "i18n_en.json")
        else:
            target = os.path.realpath(os.path.join(root, rel))
            if not target.startswith(root + os.sep):
                return Response.text("not found", 404)
        try:
            with open(target, "rb") as handle:
                data = handle.read()
        except OSError:
            return Response.text("not found", 404)
        kind = WORLD_TYPES.get(os.path.splitext(target)[1].lower(), "application/octet-stream")
        return Response(200, {"Content-Type": kind, "Cache-Control": "no-cache", "X-Content-Type-Options": "nosniff",
                              "Content-Security-Policy": WORLD_CSP, "Referrer-Policy": "no-referrer"}, data)

    @staticmethod
    def _notice():
        return Response(200, {"Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
                              "Content-Security-Policy": NOTICE_CSP, "X-Frame-Options": "DENY", "Referrer-Policy": "no-referrer"},
                        NOTICE_PAGE.encode("utf-8"))

    def _mobileconfig(self):
        der = tls.ca_der()
        if not der:
            return Response.text("证书尚未就绪", 503)
        stable = hashlib.sha256(der).hexdigest()[:12]
        profile = {"PayloadType": "Configuration", "PayloadVersion": 1, "PayloadIdentifier": "local.ccpulse.ca.%s" % stable,
                   "PayloadUUID": str(uuid.uuid4()).upper(), "PayloadDisplayName": "Kiteline 本机证书（%s）" % self.app.host,
                   "PayloadDescription": "使手机信任 %s 上 Kiteline 的 HTTPS 地址，用于接收推送通知。" % self.app.host,
                   "PayloadContent": [{"PayloadType": "com.apple.security.root", "PayloadVersion": 1,
                                       "PayloadIdentifier": "local.ccpulse.ca.cert.%s" % stable,
                                       "PayloadUUID": str(uuid.uuid4()).upper(), "PayloadDisplayName": "Kiteline Local CA",
                                       "PayloadContent": der}]}
        return Response(200, {"Content-Type": "application/x-apple-aspen-config",
                              "Content-Disposition": 'attachment; filename="Kiteline.mobileconfig"'}, plistlib.dumps(profile))

    def _pair(self, request):
        body = request.json or {}
        code = request.query.get("code") or str(body.get("code") or "")
        ok, why = self.app.pairing.check_code(code, request.remote)
        if not ok:
            if why in ("locked", "locked_public"):
                log.write("配对被拒：输错太多次（%s）" % request.remote)
                return Response.error("尝试次数过多，请 1 小时后重试" if why == "locked_public" else "尝试次数过多，请 10 分钟后重试", 429)
            log.write("手机配对失败：%s（%s）" % (why, request.remote))
            return Response.error("配对码错误或已过期，请在电脑上的 Kiteline「手机访问」窗口中查看最新配对码", 403)
        computer = body.get("computer") if isinstance(body.get("computer"), dict) else None
        if computer:
            # 另一台 Kiteline 电脑来互联（peers.py）：一律要在本机点「允许」
            name = str(computer.get("name") or "Kiteline 电脑")[:60]
            log.write("电脑「%s」（%s）请求互联，等待本机确认" % (name, request.remote))
            if not self.app.ask_peer(name, request.remote):
                self.app.pairing.add_failure(request.remote)
                log.write("电脑互联未获允许（点了拒绝，或 60 秒内没有确认）")
                return Response.error("对方电脑上未允许这次互联。请确认输入的是那台电脑上显示的验证码，重新添加后在那台电脑上点「允许」", 403)
            return self.app.peers.accept_pairing(request, computer)
        # 经远程访问（中继）来的在本机看来是 127.0.0.1、从公网地址来的：码对了还要在电脑上点「允许」
        from .peers import is_private
        if request.remote in ("127.0.0.1", "::1") or not is_private(request.remote):
            name = str(body.get("name") or "一台手机")[:60]
            log.write("手机经远程访问请求配对（%s），等待电脑上确认" % name)
            if not self.app.ask_pairing(name):
                self.app.pairing.add_failure(request.remote)
                log.write("经远程访问的配对未获允许（电脑上点了拒绝，或 60 秒内没有确认）")
                return Response.error("电脑上未允许这次配对。请确认输入的是你自己电脑上显示的配对码，重新输入后在电脑上点「允许」", 403)
        log.write("手机配对成功（%s）" % request.remote)
        device, token = self.app.devices.register(request.headers.get("user-agent", ""), request.remote, "配对码",
                                                  body.get("name"))
        return Response.json({"ok": True, "token": token, "deviceId": device["id"]})

    # MARK: 会话

    def resolve(self, request):
        record = self.app.store.record(request.query.get("key", ""))
        if not record:
            return None, None
        return record, self.app.store.source(record.source_id)

    def siblings(self, record):
        with self.app.store.lock:
            return sum(1 for r in self.app.store.records if r is not record and r.source_id == record.source_id
                       and r.snap.get("cwd") == record.snap.get("cwd"))

    def forward_any(self, request, payload, timeout=40, status_on_error=502):
        target = self.app.store.resolve_any(request.query.get("key", ""))
        if not target:
            return Response.error("会话不存在，或其所在机器离线", 404)
        session_id, source = target
        body = dict(payload)
        body["sessionId"] = session_id
        try:
            response = source.request(body, timeout=timeout)
        except Exception as exc:  # noqa: BLE001
            return Response.error(str(exc), status_on_error)
        response.pop("event", None)
        response.pop("id", None)
        return Response.json(response)

    def session_cwd(self, request):
        """(会话 id, 来源, 目录) 或错误响应"""
        target = self.app.store.resolve_any(request.query.get("key", ""))
        if not target:
            return Response.error("会话不存在，或其所在机器离线", 404)
        session_id, source = target
        record = self.app.store.record(request.query.get("key", ""))
        if record and record.snap.get("cwd"):
            return session_id, source, record.snap["cwd"]
        try:
            info = source.request({"cmd": "session_info", "sessionId": session_id}, timeout=20)
            cwd = (info.get("session") or {}).get("cwd")
        except Exception:  # noqa: BLE001
            cwd = None
        if not cwd:
            return Response.error("未找到该会话的工作目录", 404)
        return session_id, source, cwd

    def cap_check(self, request):
        """每日花费硬上限：超了先拦住，手机上确认「仍然发送」后带 override 再来"""
        body = request.json or {}
        if body.get("override") is True:
            return None
        reason = self.app.spend_capped()
        if reason:
            return Response.json({"ok": False, "capExceeded": True, "error": reason}, 409)
        return None

    def attach(self, stream, device_id, lang="zh", patch=False):
        key = id(stream)
        with self._lock:
            self._streams[key] = (stream, device_id)
            self._stream_langs[key] = lang
            self._pending_streams.add(key)
            if patch:
                self._patch_streams.add(key)

        def closed():
            with self._lock:
                self._streams.pop(key, None)
                self._stream_langs.pop(key, None)
                self._patch_streams.discard(key)
                self._pending_streams.discard(key)
                if device_id and device_id not in {d for _, d in self._streams.values()}:
                    self._foreground.pop(device_id, None)
            log.write("手机断开（%s），剩 %d 个" % (stream.remote, self.client_count()))
            self.app.clients_changed()
        stream.on_close = closed
        log.write("手机连上（%s），共 %d 个" % (stream.remote, self.client_count()))
        stream.send("retry: 3000\n\n")
        # 先把最新的状态发布出去（有变化时别的连接照常收到），新连接拿同一份、带上序号：之后的增量都以它为底
        with self._state_lock:
            self.publish_state()
            with self._lock:
                self._pending_streams.discard(key)
            state = dict(self._state, stateSeq=self._state_seq)
            stream.send("event: state\ndata: %s\n\n" % json.dumps(i18n.localize(state) if lang == "en" else state, ensure_ascii=False, sort_keys=True))
        # 再补上各台机器现在的性能（不然要等下一次 sys，最多 5 秒）
        for source_id, stats in list(self.app.machine_stats.items()):
            stream.send("event: sys\ndata: %s\n\n" % json.dumps({"id": source_id, "stats": stats}, ensure_ascii=False))
        self.app.clients_changed()

    def device_payload(self, device, current):
        watch = device.get("watch")
        return {"id": device["id"], "name": device["name"], "via": device.get("via", ""), "createdAt": device.get("createdAt"),
                "lastSeen": device.get("lastSeen"), "lastIP": device.get("lastIP", ""), "online": device["id"] in self.online_devices,
                "current": device["id"] == current, "push": any(s.get("deviceId") == device["id"] for s in self.app.push.subscriptions),
                "watch": {"paired": watch.get("paired"), "installed": watch.get("installed"), "lastUsed": watch.get("lastUsed") or 0,
                          "label": watch.get("label", "")} if watch else None}

    def reset_token(self):
        """重置配对令牌（同 Mac 版 resetMobileToken，手机丢失、链接泄露时用）：换主令牌，已配对的设备全部停用并断开，
        推送订阅、还没用的配对码和扫码链接一起作废。返回新的主令牌（本机客户端换上它接着连）"""
        token = config.make_token()
        self.app.cfg.update(lambda d: d["mobile"].update({"token": token}))
        self.app.devices.revoke_all()
        self.app.pairing.reset()
        self.app.push.clear()
        with self._lock:
            victims = [s for s, _ in self._streams.values()]
        for stream in victims:
            stream.close()
        log.write("已重置手机配对令牌")
        return token

    def revoke_device(self, device_id):
        device = self.app.devices.revoke(device_id)
        if not device:
            return None
        self.app.peers.device_revoked(device)   # 电脑：互联一起解除；手机：它在别的电脑上的登记也作废
        with self._lock:
            victims = [s for s, d in self._streams.values() if d == device_id]
        for stream in victims:
            stream.close()
        self.app.push.remove(device_id=device_id)
        self.app.live.forget(device_id)
        return device

    def set_foreground(self, device_id, visible):
        with self._lock:
            if visible:
                self._foreground[device_id] = time.time()
            else:
                self._foreground.pop(device_id, None)


# MARK: - 各个接口

def _attachments(body):
    return delivery.attachments_of(body)


def r_state(s, request, kind, who, device_id):
    # 各台机器的性能只在这里附上（刚连上时用）：之后的变化走 sys 事件，不进推送的 state
    payload = s.app.state_payload()
    payload["sys"] = dict(s.app.machine_stats)
    return Response.json(payload)


def r_events(s, request, kind, who, device_id):
    return StreamReply({"Content-Type": "text/event-stream; charset=utf-8", "X-Accel-Buffering": "no"},
                       lambda stream: s.attach(stream, device_id, i18n.lang_of(request), request.query.get("patch") == "1"))


def state_patch(old, new, base, seq, full_size):
    """两份状态之间的增量（同 Mac 版 MobileServer.statePatch）：会话按 key 整条换（upsert）、没了的列出来（remove）、
    成员或顺序变了才带新顺序（order）；会话以外变了的字段放 set、没了的放 unset。客户端合进上一份（序号 base）再按整份处理。
    增量不比整份小多少（变了一大半）就不发（返回 None），大家收整份"""
    def key(session):
        return session.get("key") if isinstance(session, dict) else None
    old_list, new_list = old.get("sessions") or [], new.get("sessions") or []
    old_by_key = {key(s): s for s in old_list if key(s)}
    old_keys, new_keys = [key(s) for s in old_list if key(s)], [key(s) for s in new_list if key(s)]
    patch = {"base": base, "seq": seq}
    upsert = [s for s in new_list if key(s) and old_by_key.get(key(s)) != s]
    if upsert:
        patch["upsert"] = upsert
    remaining = set(new_keys)
    remove = [k for k in old_keys if k not in remaining]
    if remove:
        patch["remove"] = remove
    if new_keys != old_keys:
        patch["order"] = new_keys
    missing = object()
    changed = {field: value for field, value in new.items() if field != "sessions" and old.get(field, missing) != value}
    if changed:
        patch["set"] = changed
    unset = [field for field in old if field != "sessions" and field not in new]
    if unset:
        patch["unset"] = unset
    size = len(json.dumps(patch, ensure_ascii=False, sort_keys=True).encode("utf-8"))
    return patch if size * 10 < full_size * 6 else None


def localize_events(items):
    """对话记录是内容、整体不翻；只有电脑生成的事件提示（「接口出错：…」「上下文已压缩」）换成英文"""
    return [dict(item, text=i18n.translate(item["text"])) if item.get("t") == "event" and item.get("text") else item for item in items]


def r_history(s, request, kind, who, device_id):
    target = s.app.store.resolve_any(request.query.get("key", ""))
    if not target:
        return Response.error("会话不存在，或其所在机器离线", 404)
    session_id, source = target
    payload = {"cmd": "history", "sessionId": session_id, "limit": int(request.query.get("limit") or 60)}
    if (request.query.get("before") or "").lstrip("-").isdigit():
        payload["before"] = int(request.query["before"])
    if (request.query.get("beforeTs") or "").isdigit():
        payload["beforeTs"] = int(request.query["beforeTs"])
    agent = request.query.get("agent")
    if agent and re.match(r"^[A-Za-z0-9_-]{3,64}$", agent):
        payload["agentId"] = agent
    try:
        response = source.request(payload, timeout=30)
    except Exception as exc:  # noqa: BLE001
        return Response.error(str(exc), 502)
    items = response.get("items") or []
    if i18n.lang_of(request) == "en":
        items = localize_events(items)
    return Response.json({"ok": True, "items": items, "hasMore": response.get("hasMore", False)})


def r_agents(s, request, *_):
    return s.forward_any(request, {"cmd": "agents"})


def r_trace(s, request, *_):
    """执行过程面板：agent → 轮次 → 步骤（expand 是要带上步骤的轮次，「agent:轮次」逗号分隔）"""
    return s.forward_any(request, {"cmd": "trace", "expand": request.query.get("expand", ""), "rev": request.query.get("rev", "")})


def r_peers(s, request, *_):
    """会话之间的消息往来（默认最近一天）：手机刚连上、协作图用；之后的走实时事件 peers"""
    try:
        since = float(request.query.get("since") or 0)
    except ValueError:
        since = 0
    return Response.json({"links": s.app.peers_since(since or time.time() * 1000 - 86400000)})


def r_task_output(s, request, *_):
    return s.forward_any(request, {"cmd": "task_output", "taskId": request.query.get("task", "")})


def r_media(s, request, *_):
    ref, key = request.query.get("ref"), request.query.get("key")
    if not ref or not key:
        return Response.error("缺少参数", 400)
    cache_key = "%s|%s" % (key, ref)
    hit = s.app.media.load(cache_key)
    # 缓存里的 SVG 不用：客户端都显示不了，新版 watcher 会换成 PNG 给
    if hit and hit[1] != "image/svg+xml":
        return thumb_reply(hit[0], hit[1], request, cache_key)
    target = s.app.store.resolve_any(key)
    if not target:
        return Response.error("会话不存在，或其所在机器离线", 404)
    session_id, source = target
    try:
        response = source.request({"cmd": "media", "sessionId": session_id, "ref": ref}, timeout=60)
        data = base64.b64decode(response.get("data") or "")
    except Exception as exc:  # noqa: BLE001
        return Response.error(str(exc), 502)
    mime = response.get("mime") or "image/png"
    s.app.media.store(cache_key, data, mime)
    return thumb_reply(data, mime, request, cache_key)


def r_digest_media(s, request, *_):
    source = s.app.store.source(request.query.get("source", ""))
    sid, ref = request.query.get("sid", ""), request.query.get("ref", "")
    if not source or not SESSION_ID.match(sid) or not re.match(r"^o[0-9]+\.[0-9]+$", ref):
        return Response.error("参数无效", 400)
    try:
        response = source.request({"cmd": "media", "sessionId": sid, "ref": ref}, timeout=40)
        data = base64.b64decode(response.get("data") or "")
    except Exception as exc:  # noqa: BLE001
        return Response.error(str(exc), 502)
    if not data:
        return Response.error("图片不存在", 404)
    return thumb_reply(data, response.get("mime") or "image/png", request, "digest|%s|%s|%s" % (source.id, sid, ref))


def r_send(s, request, *_):
    s.app.idle_close.touch([request.query.get("key", "")])   # 从对话页发消息 = 打开过（自动关闭闲置会话，见 idleclose.py）
    blocked = s.cap_check(request)
    if blocked:
        return blocked
    record, source = s.resolve(request)
    if not record:
        return Response.error("会话不存在或已结束", 404)
    body = request.json
    if body is None:
        return Response.error("请求格式无效", 400)
    text = body.get("text") or ""
    attachments = _attachments(body)
    submit = body.get("submit", s.app.cfg.mobile["submitOnSend"])
    cid = body.get("cid")
    stamp = time.time()
    s._recent_sends = {k: v for k, v in s._recent_sends.items() if stamp - v[0] < 600}
    if cid:
        cid = "%s|%s" % (record.key, cid)
        if cid in s._recent_sends:
            log.write("手机重发的消息已经送过（%s），不再投递" % cid[-12:])
            payload = dict(s._recent_sends[cid][1])
            payload["duplicate"] = True
            return Response.json(payload)
    log.write("手机发往「%s」：%s（图 %d 张）" % (record.snap.get("name"), text[:60], len(attachments)))
    outcome = delivery.send(text, attachments, record, source, submit, s.siblings(record))
    if outcome.ok and cid:
        s._recent_sends[cid] = (time.time(), dict(outcome))
    return Response.json(dict(outcome), 200 if outcome.ok else 409)


def r_key(s, request, *_):
    record, source = s.resolve(request)
    if not record:
        return Response.error("会话不存在或已结束", 404)
    body = request.json or {}
    key = body.get("key") or request.query.get("k") or ""
    times = body.get("times") or 1
    log.write("手机在「%s」按键 %s%s" % (record.snap.get("name"), key, " ×%d" % times if times > 1 else ""))
    outcome = delivery.press(key, times, record, source, s.siblings(record))
    return Response.json({"ok": outcome.ok, "message": outcome["message"]}, 200 if outcome.ok else 409)


def r_hosted_probe(s, request, *_):
    """出口检测：每台远端电脑照后台运行时的网络设置查出口 IP（见 app.hosted_probe）"""
    wanted = (request.json or {}).get("sourceId")
    with s.app.store.lock:
        sources = [src for src in s.app.store.sources.values() if getattr(src, "kind", "") == "ssh" and wanted in (None, "", src.id)]
    return Response.json({"ok": True, "machines": s.app.hosted_probe(sources)})


def r_hosted_settings(s, request, *_):
    """后台运行的设置：{sourceId, on}（按设备开关）/ {tipOff}"""
    body = request.json or {}
    on, tip_off = body.get("on"), body.get("tipOff")
    s.app.set_hosted(source_id=body.get("sourceId") or None, on=on if isinstance(on, bool) else None,
                     tip_off=tip_off if isinstance(tip_off, bool) else None)
    return Response.json({"ok": True})


def r_hosted_move(s, request, *_):
    """把 VS Code 里正开着的会话转到后台运行：?key="""
    record, source = s.resolve(request)
    if not record or not source:
        return Response.error("会话不存在或已结束", 404)
    if not store_hostable(record, source):
        return Response.json({"ok": False, "message": "此会话无法转到后台运行"}, 409)
    ok, message = s.app.move_to_background(record, source, s.siblings(record))
    return Response.json({"ok": ok, "message": message}, 200 if ok else 409)


def r_queue(s, request, *_):
    """排队的消息：{action: move | edit | delete | now, id, text?, dir?}（见 delivery.queue）"""
    record, source = s.resolve(request)
    if not record:
        return Response.error("会话不存在或已结束", 404)
    body = request.json if isinstance(request.json, dict) else {}
    action, qid = body.get("action"), body.get("id")
    if action not in delivery.QUEUE_ACTIONS or not isinstance(qid, str):
        return Response.error("请求格式无效", 400)
    text = body.get("text") if isinstance(body.get("text"), str) and body["text"].strip() else None
    if action == "edit" and text is None:
        return Response.error("内容为空", 400)
    direction = body.get("dir") if isinstance(body.get("dir"), int) and not isinstance(body.get("dir"), bool) else None
    log.write("手机调整「%s」的排队消息：%s" % (record.snap.get("name"), action))
    outcome = delivery.queue(action, qid, text, direction, record, source)
    return Response.json({"ok": outcome.ok, "message": outcome["message"]}, 200 if outcome.ok else 409)


def r_close(s, request, *_):
    """关闭会话（VS Code 里关掉它的标签页，终端里 /exit）：?key="""
    record, source = s.resolve(request)
    if not record:
        return Response.error("会话不存在或已结束", 404)
    log.write("关闭会话「%s」" % record.snap.get("name"))
    outcome = delivery.close(record, source, s.siblings(record))
    if outcome.ok:
        # 关掉了就取消标记（标记是为了多任务时找得到还开着的会话）
        s.app.set_marked(record.key, False)
    return Response.json({"ok": outcome.ok, "message": outcome["message"]}, 200 if outcome.ok else 409)


def r_answer(s, request, *_):
    record, source = s.resolve(request)
    if not record:
        return Response.error("会话不存在或已结束", 404)
    lines = []
    for item in (request.json or {}).get("answers") or []:
        question = str(item.get("question") or "").strip()
        parts = [p for p in item.get("picked") or [] if p]
        other = str(item.get("other") or "").strip()
        if other:
            parts.append(other)
        if parts:
            lines.append("• %s\n  → %s" % (question, "、".join(parts)) if question else "• %s" % "、".join(parts))
    if not lines:
        return Response.error("未选择任何选项", 400)
    text = "（回答你刚才的提问）\n" + "\n".join(lines)
    outcome = delivery.answer(text, record, source, s.siblings(record), (request.json or {}).get("answers") or [])
    return Response.json(dict(outcome), 200 if outcome.ok else 409)


def r_voice(s, request, *_):
    body = request.json or {}
    mode = body.get("mode") or "send"
    if mode == "send":
        s.app.idle_close.touch([request.query.get("key", "")])
        blocked = s.cap_check(request)
        if blocked:
            return blocked
    try:
        audio = base64.b64decode(body.get("data") or "")
    except (ValueError, TypeError):
        audio = b""
    if len(audio) <= 44:
        return Response.error("未收到录音", 400)
    if len(audio) >= 12 * 1024 * 1024:
        return Response.error("录音过长", 413)
    mime = body.get("mime") or "audio/wav"
    duration = float(body.get("duration") or 0)
    attachments = _attachments(body)
    record, source = s.resolve(request)
    if mode == "send" and not record:
        return Response.error("会话不存在或已结束", 404)
    path = s.app.voices.save_audio(audio, mime)
    try:
        text = s.app.transcribe(path)
    except Exception as exc:  # noqa: BLE001
        _remove(path)
        return Response.error(str(exc), 422)
    if not text:
        _remove(path)
        return Response.error("未能识别，请重新说一遍", 422)
    log.write("语音转写（%.1f 秒）：%s" % (duration, text[:60]))
    if mode != "send" or not record:
        _remove(path)
        return Response.json({"ok": True, "text": text})
    outcome = delivery.send(text, attachments, record, source, s.app.cfg.mobile["submitOnSend"], s.siblings(record))
    payload = {"ok": outcome.ok, "text": text, "submitted": outcome["submitted"], "message": outcome["message"]}
    if outcome.get("later"):
        payload["later"] = True
        if outcome.get("qid"):
            payload["qid"] = outcome["qid"]
    if outcome.ok:
        payload["voiceId"] = s.app.voices.record(record.key, text, duration, path, mime)["id"]
    else:
        _remove(path)
    return Response.json(payload, 200 if outcome.ok else 409)


def _remove(path):
    try:
        os.remove(path)
    except OSError:
        pass


def r_voices(s, request, *_):
    key = request.query.get("key", "")
    s.app.idle_close.touch([key])   # 各端只在打开对话页时取这个：旧版手机不报 /api/viewed，靠它算「打开过」
    return Response.json({"ok": True, "voices": [{"id": e["id"], "text": e["text"], "duration": e["duration"], "ts": e["ts"] * 1000}
                                                 for e in s.app.voices.list(key)]})


def r_voice_audio(s, request, *_):
    entry = s.app.voices.entry(request.query.get("id", ""))
    if not entry:
        return Response.error("语音不存在", 404)
    try:
        with open(s.app.voices.file_path(entry), "rb") as handle:
            data = handle.read()
    except OSError:
        return Response.error("语音不存在", 404)
    base = entry["mime"].split(";")[0].strip().lower()
    return Response(200, {"Content-Type": base if base in AUDIO_TYPES else "application/octet-stream",
                          "X-Content-Type-Options": "nosniff", "Content-Security-Policy": "sandbox; default-src 'none'",
                          "Cache-Control": "private, max-age=31536000, immutable"}, data)


def _git(s, request, payload, timeout=40):
    found = s.session_cwd(request)
    if isinstance(found, Response):
        return found
    session_id, source, cwd = found
    body = dict(payload)
    body.update({"sessionId": session_id, "cwd": cwd})
    try:
        response = source.request(body, timeout=timeout)
    except Exception as exc:  # noqa: BLE001
        return Response.error(str(exc), 502)
    response.pop("event", None)
    response.pop("id", None)
    return Response.json(response)


def r_git(s, request, *_):
    return _git(s, request, {"cmd": "git_status"})


def r_repo_get(s, request, *_):
    """代码 IDE 的 Git（只读）：overview / status / log / commit_info / diff"""
    payload = {"cmd": "repo", "op": request.query.get("op") or "overview"}
    for field in ("ref", "q", "path", "commit", "mode", "oldPath", "job"):
        if request.query.get(field) is not None:
            payload[field] = request.query[field]
    for field in ("skip", "limit", "context"):
        if str(request.query.get(field) or "").isdigit():
            payload[field] = int(request.query[field])
    return _git(s, request, payload, timeout=60)


def r_repo_post(s, request, *_):
    """代码 IDE 的 Git（会改仓库）：暂存、提交、推送拉取、分支、合并……推送能跑几分钟"""
    payload = dict(request.json or {})
    payload["cmd"] = "repo"
    return _git(s, request, payload, timeout=200)


def r_term(s, request, *_):
    """会话里的终端：开、列、读最近的输出、按键、改大小、关（开在会话所在的电脑上，见 watcher 的 term）"""
    payload = dict(request.json or {})
    payload["cmd"] = "term"
    return _git(s, request, payload, timeout=20)


def r_fs(s, request, *_):
    """代码 IDE 改文件：保存、新建、改名、移动、复制、删除（进回收站）、上传"""
    payload = dict(request.json or {})
    payload["cmd"] = "fs"
    return _files(s, request, payload, timeout=120)


def r_git_diff(s, request, *_):
    payload = {"cmd": "git_diff"}
    for field in ("path", "commit"):
        if request.query.get(field):
            payload[field] = request.query[field]
    return _git(s, request, payload)


def _files(s, request, payload, timeout=40):
    found = s.session_cwd(request)
    if isinstance(found, Response):
        return found
    session_id, source, root = found
    body = dict(payload)
    body["root"] = root
    body["sessionId"] = session_id
    try:
        response = source.request(body, timeout=timeout)
    except Exception as exc:  # noqa: BLE001
        return Response.error(str(exc), 400)
    response.pop("event", None)
    response.pop("id", None)
    response["root"] = root
    return Response.json(response)


def r_files(s, request, *_):
    return _files(s, request, {"cmd": "ls", "path": request.query.get("path", "")})


def r_file(s, request, *_):
    return _files(s, request, {"cmd": "read_file", "path": request.query.get("path", ""), "reveal": request.query.get("reveal") == "1",
                               "edit": request.query.get("edit") == "1"})


def r_download(s, request, *_):
    """电脑上的文件原样取回手机（Claude 回复里提到的路径、手机发过去的附件）：手机上预览、转发到别的 App。
    路径可以在项目目录以外；相对路径按会话目录算（已结束的会话由手机带上 cwd）（同 Mac 版 MobileServer.download）"""
    path = request.query.get("path", "")
    if not path or len(path) >= 4096:
        return Response.error("缺少参数", 400)
    key = request.query.get("key", "")
    target = s.app.store.resolve_any(key)
    if not target:
        return Response.error("会话不存在，或其所在机器离线", 404)
    _, source = target
    record = s.app.store.record(key)
    cwd = (record.snap.get("cwd") if record else None) or request.query.get("cwd", "")
    log.write("手机取文件：%s" % path[:120])
    payload = {"cmd": "get_file", "path": path, "cwd": cwd, "reveal": request.query.get("reveal") == "1"}
    try:
        response = source.request(payload, timeout=120)
    except Exception as exc:  # noqa: BLE001
        # 会话在别的机器上、那边没有这个文件时，再到本机找一次：远端的 agent 常把文件拷到用户这台电脑上
        # （经挂载目录、scp），回复里写的却是本机路径，远端自然找不到。相对路径只按会话目录算，不兜底（同 Mac 版）
        local = None
        absolute = path.startswith(("/", "~/", "~\\")) or re.match(r"^[A-Za-z]:[\\/]", path)
        if getattr(source, "kind", "") != "local" and absolute and str(exc).startswith("文件不存在"):
            with s.app.store.lock:
                local = next((x for x in s.app.store.sources.values() if getattr(x, "kind", "") == "local" and x.live), None)
        if not local:
            return Response.error(str(exc), 404)
        log.write("会话所在机器没有这个文件，改在本机找")
        try:
            response = local.request(payload, timeout=120)
        except Exception:  # noqa: BLE001
            return Response.error(str(exc), 404)
    if response.get("secret"):
        return Response.json({"ok": False, "secret": True, "error": "此文件可能包含密钥或密码，默认不传到手机"}, 403)
    try:
        data = base64.b64decode(response.get("data") or "", validate=True)
    except (ValueError, TypeError):
        return Response.error("文件数据损坏", 502)
    return Response(200, {"Content-Type": response.get("mime") or "application/octet-stream", "X-Content-Type-Options": "nosniff",
                          "Cache-Control": "no-store", "Content-Security-Policy": "sandbox; default-src 'none'"}, data)


def r_files_find(s, request, *_):
    return _files(s, request, {"cmd": "find_files", "q": request.query.get("q", "")})


def r_tests(s, request, *_):
    record, source = s.resolve(request)
    if not record or not source:
        return Response.error("会话不存在或已结束", 404)
    try:
        response = source.request({"cmd": "tests", "limit": 50, "sessionId": record.snap.get("sessionId")}, timeout=40)
    except Exception as exc:  # noqa: BLE001
        return Response.error(str(exc), 502)
    response.pop("event", None)
    response.pop("id", None)
    return Response.json(response)


def r_session_meta(s, request, *_):
    target = s.app.store.resolve_any(request.query.get("key", ""))
    if not target:
        return Response.error("会话不存在，或其所在机器离线", 404)
    session_id, source = target
    try:
        response = source.request({"cmd": "session_info", "sessionId": session_id}, timeout=20)
    except Exception as exc:  # noqa: BLE001
        return Response.error(str(exc), 404)
    meta = response.get("session") or {}
    meta.update({"key": request.query["key"], "sourceId": source.id, "sourceName": source.name, "sourceKind": source.kind,
                 "live": s.app.store.record(request.query["key"]) is not None})
    return Response.json({"ok": True, "session": meta})


def r_sessions(s, request, *_):
    return Response.json(aggregate.past_sessions(s.app.store, request.query.get("source"), request.query.get("cwd"),
                                                 request.query.get("project")))


def r_search(s, request, *_):
    q = (request.query.get("q") or "").strip()
    if not q or len(q) > 100:
        return Response.error("搜索词为空或过长", 400)
    if request.query.get("key") is not None:
        target = s.app.store.resolve_any(request.query["key"])
        if not target:
            return Response.error("会话不存在，或其所在机器离线", 404)
        session_id, source = target
        try:
            response = source.request({"cmd": "search", "q": q, "sessionId": session_id}, timeout=30)
        except Exception as exc:  # noqa: BLE001
            return Response.error(str(exc), 502)
        response.pop("event", None)
        response.pop("id", None)
        return Response.json(response)
    return Response.json(aggregate.search(s.app.store, q))


def r_projects(s, request, *_):
    return Response.json(aggregate.projects(s.app.store, request.query.get("detail") == "1"))


def r_dirs(s, request, *_):
    """新任务「打开其他文件夹」：列某台电脑上一个目录里的子文件夹（不限项目目录，空 = 主目录）；POST 带 mkdir = 先在里面新建再列（同 Mac 版 MobileServer.dirs）"""
    body = request.json or {}
    source = s.app.store.source(request.query.get("sourceId") or body.get("sourceId") or "")
    if not source or not source.live:
        return Response.error("该机器当前离线", 404)
    payload = {"cmd": "dirs", "path": request.query.get("path") or body.get("path") or "",
               "hidden": request.query.get("hidden") == "1" or body.get("hidden") is True}
    if request.method == "POST" and isinstance(body.get("mkdir"), str):
        payload["mkdir"] = body["mkdir"]
    try:
        response = source.request(payload, timeout=20)
    except Exception as exc:  # noqa: BLE001
        # 旧版 watcher 不认 dirs
        return Response.error("该电脑上的 Kiteline 组件版本较旧，请更新后重试" if "未知请求" in str(exc) else str(exc), 400)
    response.pop("event", None)
    response.pop("id", None)
    return Response.json(response)


def r_repo_info(s, request, *_):
    source = s.app.store.source(request.query.get("sourceId", ""))
    if not source or not source.live:
        return Response.error("该机器当前离线", 404)
    try:
        response = source.request({"cmd": "repo_info", "cwd": request.query.get("cwd", "")}, timeout=30)
    except Exception as exc:  # noqa: BLE001
        return Response.error(str(exc), 502)
    response.pop("event", None)
    response.pop("id", None)
    return Response.json(response)


def r_digest(s, request, *_):
    since = int(request.query.get("since") or 0) or config.start_of_day_ms()
    until = int(request.query.get("until") or 0) or None
    return Response.json(aggregate.digest(s.app.store, since, until, request.query.get("fresh") == "1"))


def r_digest_push(s, request, *_):
    return Response.json({"ok": True, "message": s.app.send_digest(manual=True)})


def r_morning_push(s, request, *_):
    return Response.json({"ok": True, "message": s.app.send_morning(manual=True)})


def r_usage(s, request, *_):
    return Response.json(aggregate.usage(s.app.store, int(request.query.get("days") or 7), request.query.get("fresh") == "1"))


def r_limits(s, request, *_):
    return Response.json(aggregate.limits(s.app.store, request.query.get("fresh") == "1"))


def r_budget(s, request, *_):
    m = s.app.cfg.mobile
    return Response.json({"ok": True, "daily": m["dailyBudget"], "cap": m["dailyCap"], "capped": s.app.spend_capped() or ""})


def r_budget_set(s, request, *_):
    body = request.json or {}
    m = s.app.cfg.mobile
    try:
        daily = float(body["daily"]) if "daily" in body else float(m["dailyBudget"])
        cap = float(body["cap"]) if "cap" in body else float(m["dailyCap"])
    except (TypeError, ValueError):
        return Response.error("金额无效", 400)
    if not (0 <= daily <= 100_000 and 0 <= cap <= 100_000):
        return Response.error("金额无效", 400)
    s.app.cfg.update(lambda d: d["mobile"].update({"dailyBudget": daily, "dailyCap": cap}))
    if daily > 0 and "daily" in body:
        threading.Thread(target=s.app.check_budget, daemon=True).start()
    return Response.json({"ok": True, "daily": daily, "cap": cap})


def r_budget_check(s, request, *_):
    return Response.json({"ok": True, "message": s.app.check_budget()})


def r_world_intent(s, request, *_):
    """世界网页在浏览器窗口里（Linux）传不回客户端：点屏幕、点卫星、离开世界经这里转一道，客户端从实时事件 world_intent 收"""
    body = request.json or {}
    kind = body.get("type")
    if kind not in ("open", "machine", "exit"):
        return Response.error("不认识的动作", 400)
    payload = {"type": kind}
    for field in ("key", "sourceId"):
        if isinstance(body.get(field), str):
            payload[field] = body[field][:300]
    s.publish("world_intent", payload)
    return Response.json({"ok": True})


def r_ping(s, request, *_):
    try:
        size = min(max(int(request.query.get("bytes") or 0), 0), 512 * 1024)
    except ValueError:
        size = 0
    return Response(200, {"Content-Type": "application/octet-stream", "Cache-Control": "no-store",
                          "X-Server-Time": str(int(time.time() * 1000))}, b"\0" * size)


def r_info(s, request, *_):
    return Response.json(s.app.info())


def r_whoami(s, request, kind, who, device_id):
    payload = {"ok": True, "auth": "device" if device_id else "master"}
    if device_id:
        payload["device"] = s.device_payload(who, device_id)
    return Response.json(payload)


def r_devices(s, request, kind, who, device_id):
    return Response.json({"ok": True, "devices": [s.device_payload(d, device_id) for d in s.app.devices.all]})


def r_devices_link(s, request, kind, who, device_id):
    if kind != "master":
        return Response.error("只有这台电脑本身可以生成配对链接", 403)
    return Response.json({"ok": True, "token": s.app.new_link_token()})


def r_devices_register(s, request, kind, who, device_id):
    if device_id:
        return Response.error("该设备已登记", 403)
    if kind == "link" and not s.app.pairing.consume_link(who):
        return Response.error("配对链接已使用或已过期，请在电脑上重新扫码", 401)
    device, token = s.app.devices.register(request.headers.get("user-agent", ""), request.remote, "扫码",
                                           (request.json or {}).get("name"))
    s.app.clients_changed()
    return Response.json({"ok": True, "token": token, "device": s.device_payload(device, device["id"])})


def r_devices_revoke(s, request, *_):
    device = s.revoke_device((request.json or {}).get("id", ""))
    if not device:
        return Response.error("设备不存在", 404)
    return Response.json({"ok": True, "name": device["name"]})


def r_devices_rename(s, request, kind, who, device_id):
    body = request.json or {}
    device = s.app.devices.rename(body.get("id") or device_id or "", body.get("name", ""))
    if not device:
        return Response.error("名字不能为空", 400)
    return Response.json({"ok": True, "device": s.device_payload(device, device_id)})


def r_audit(s, request, *_):
    limit = max(1, min(500, int(request.query.get("limit") or 200)))
    return Response.json({"ok": True, "entries": s.app.audit.recent(limit)})


def r_inbox(s, request, *_):
    limit = max(1, min(300, int(request.query.get("limit") or 150)))
    since = float(request.query.get("since") or 0)
    return Response.json({"ok": True, "entries": s.app.inbox.recent(limit, since)})


def r_quiet(s, request, *_):
    body = request.json or {}
    start, end = body.get("start") or "", body.get("end") or ""
    if (start or end) and not (config.parse_hm(start) and config.parse_hm(end)):
        return Response.error("时间格式应为 HH:mm", 400)
    s.app.cfg.update(lambda d: d["mobile"].update({"quietStart": start, "quietEnd": end}))
    return Response.json({"ok": True, "start": start, "end": end, "active": s.app.cfg.in_quiet_hours()})


def _toggle_list(s, request, field, value_key, front):
    body = request.json or {}
    key = body.get("key")
    if not key:
        return Response.error("缺少会话", 400)
    on = body.get(value_key, True)

    def change(data):
        items = [k for k in data["mobile"][field] if k != key]
        if on:
            items = [key] + items if front else items + [key]
        data["mobile"][field] = items[:50] if front else items[-200:]
    s.app.cfg.update(change)
    s.publish_state()
    return Response.json({"ok": True, "key": key, value_key: on})


def r_pin(s, request, *_):
    return _toggle_list(s, request, "pinnedSessions", "pinned", True)


def r_mark(s, request, *_):
    """标记 / 取消标记会话：{key, marked}"""
    body = request.json or {}
    key = body.get("key")
    if not key:
        return Response.error("缺少会话", 400)
    on = bool(body.get("marked", True))
    s.app.set_marked(key, on)
    return Response.json({"ok": True, "key": key, "marked": on})


def r_mute(s, request, *_):
    return _toggle_list(s, request, "mutedSessions", "muted", False)


def r_quick_replies(s, request, *_):
    items = (request.json or {}).get("items")
    cleaned = config.clean_quick_replies(items) if isinstance(items, list) else list(config.DEFAULT_QUICK_REPLIES)
    s.app.cfg.update(lambda d: d["mobile"].update({"quickReplies": cleaned}))
    s.publish_state()
    return Response.json({"ok": True, "items": cleaned})


def r_profile(s, request, *_):
    return Response.json(s.app.profile_payload())


def r_profile_set(s, request, *_):
    body = request.json or {}
    # 电脑端没有系统自带头像：只认「名字首字」和「自己的图」，别的一律拒绝（同 Mac 版的「头像不存在」）
    if body.get("avatar") not in (None, "", "text", "custom") and not body.get("image"):
        return Response.error("头像不存在", 400)
    if "name" in body:
        name = str(body.get("name") or "").strip()[:40]
        s.app.cfg.update(lambda d: d["mobile"].update({"myName": name}))
    if body.get("image"):
        # 上传一张图当头像（base64）：存好后切到「自己的图」
        try:
            data = base64.b64decode(str(body["image"]).split(",", 1)[-1], validate=False)
        except (ValueError, TypeError):
            return Response.error("无法打开此图片，请选择其他图片", 400)
        if not s.app.save_avatar(data):
            return Response.error("无法打开此图片，请选择其他图片", 400)
        s.app.cfg.update(lambda d: d["mobile"].update({"avatar": "custom"}))
    elif body.get("avatar") in ("text", "custom"):
        choice = body["avatar"]
        if choice == "custom" and not os.path.exists(s.app.avatar_path()):
            return Response.error("还没有上传过图片", 400)
        s.app.cfg.update(lambda d: d["mobile"].update({"avatar": choice}))
    s.publish_state()
    return Response.json(s.app.profile_payload())


def r_avatar(s, request, *_):
    if request.query.get("preset") or request.query.get("of") not in (None, "", "custom"):
        return Response.error("没有这个头像", 404)   # 电脑端没有系统自带头像（Mac 才有 preset / of=mac）
    path = s.app.avatar_path()
    if s.app.cfg.mobile.get("avatar") != "custom" or not os.path.exists(path):
        return Response.error("未设置头像", 404)
    with open(path, "rb") as handle:
        return Response(200, {"Content-Type": "image/jpeg", "Cache-Control": "private, max-age=86400"}, handle.read())


def r_agent_face(s, request, *_):
    # 对话里 agent 的头像、昵称（Agent 详情里改的），见 faces.py
    status, body = s.app.faces.save(request.json or {})
    if status == 200:
        s.publish_state()
    return Response.json(body, status)


def r_agent_avatar(s, request, *_):
    data = s.app.faces.image(request.query.get("id", ""))
    if data is None:
        return Response.error("头像不存在", 404)
    return Response(200, {"Content-Type": "image/jpeg", "Cache-Control": "private, max-age=31536000, immutable"}, data)


def r_agent_info(s, request, *_):
    return Response.json(faces.agent_info(s.app, s.app.faces, request.query.get("key", ""), request.query.get("agent")))


def r_feedback(s, request, *_):
    """新手引导第一步：用户填的「我使用的 Agent 不在列表中」，连同本机检测到的 Agent 发到统计后台"""
    body = request.json or {}
    agents = str(body.get("agents") or "").strip()[:200]
    if not agents:
        return Response.error("请填写 Agent 名称", 400)
    detected = [str(a) for a in body.get("detected") or [] if isinstance(a, str)][:30]
    ok = s.app.stats.feedback({"kind": "agent", "agents": agents, "note": str(body.get("note") or "").strip()[:1000], "detected": detected})
    log.write("已提交 Agent 反馈：%s" % agents if ok else "Agent 反馈提交失败")
    return Response.json({"ok": ok} if ok else {"ok": False, "error": "提交失败，请检查网络后重试"})


def r_machine(s, request, *_):
    detail = faces.machine(s.app, request.query.get("source", ""))
    if detail is None:
        return Response.error("未知的设备", 404)
    return Response.json(detail)


def r_watch(s, request, *_):
    watches = []
    for device in s.app.devices.all:
        watch = device.get("watch")
        if watch:
            item = {"device": device["name"], "deviceId": device["id"], "paired": watch.get("paired"),
                    "installed": watch.get("installed"), "updatedAt": watch.get("updatedAt"), "label": watch.get("label", "")}
            if watch.get("lastUsed"):
                item["lastUsed"] = watch["lastUsed"]
            watches.append(item)
    return Response.json({"ok": True, "prefs": s.app.cfg.mobile["watch"], "suggested": ["继续", "按此方案执行", "暂停，等我回来", "说明你的计划", "运行测试"],
                          "watches": watches})


def r_watch_set(s, request, *_):
    body = request.json or {}
    allowed = {"doubleTap": bool, "alwaysAllow": bool, "guardDanger": bool, "hideMuted": bool, "showCost": bool, "haptics": bool,
               "scope": str, "theme": str, "font": str, "textSize": str, "replies": list}

    def change(data):
        watch = data["mobile"]["watch"]
        for key, kind in allowed.items():
            if key in body and isinstance(body[key], kind):
                if key == "scope" and body[key] not in ("all", "active"):
                    continue
                if key in VALID_LOOK and body[key] not in VALID_LOOK[key]:
                    continue
                if key == "replies":
                    watch[key] = [str(r).strip()[:40] for r in body[key] if str(r).strip()][:8]
                else:
                    watch[key] = body[key]
    s.app.cfg.update(change)
    s.publish_state()
    return Response.json({"ok": True, "prefs": s.app.cfg.mobile["watch"]})


def r_watch_status(s, request, kind, who, device_id):
    if not device_id:
        return Response.error("仅已配对的手机可上报手表状态", 403)
    body = request.json or {}
    s.app.devices.set_watch(device_id, bool(body.get("paired")), bool(body.get("installed")), body.get("complication"))
    return Response.json({"ok": True})


def r_p2p_join(s, request, kind, who, device_id):
    if not device_id:
        return Response.error("仅已配对的手机可开通远程访问", 403)
    phone = str((request.json or {}).get("id") or "").lower()
    if len(phone) != 64 or not all(c in "0123456789abcdef" for c in phone):
        return Response.error("手机公钥无效", 400)
    s.app.devices.set_p2p_id(device_id, phone)
    s.app.p2p.refresh_allowlist()
    info = s.app.p2p.join_info
    if info:
        info["ok"] = True
        return Response.json(info)
    enabled = s.app.cfg.mobile["remoteEnabled"]
    return Response.json({"ok": False, "error": "电脑的远程访问尚未就绪" if enabled else "电脑未开启远程访问（Kiteline 设置 → 远程访问）"})


def r_clientlog(s, request, *_):
    message = str((request.json or {}).get("msg") or "").replace("\n", " ")[:300]
    if message:
        log.write("手机报告：%s" % message)
    return Response.json({"ok": True})


def r_presence(s, request, kind, who, device_id):
    if device_id:
        s.set_foreground(device_id, bool((request.json or {}).get("visible")))
    return Response.json({"ok": True})


def r_push_key(s, request, *_):
    return Response.json({"ok": True, "publicKey": s.app.push.public_key, "subscriptions": len(s.app.push.subscriptions)})


def r_push_subscribe(s, request, kind, who, device_id):
    body = request.json or {}
    keys = body.get("keys") or {}
    if not body.get("endpoint") or not keys.get("p256dh") or not keys.get("auth"):
        return Response.error("订阅数据不完整", 400)
    if not s.app.push.acceptable(body["endpoint"], keys["p256dh"], keys["auth"]):
        return Response.error("推送订阅地址不合法", 400)
    s.app.push.add({"endpoint": body["endpoint"], "p256dh": keys["p256dh"], "auth": keys["auth"], "createdAt": time.time(),
                    "label": body.get("label"), "deviceId": device_id})
    return Response.json({"ok": True, "subscriptions": len(s.app.push.subscriptions)})


def r_share_list(s, request, *_):
    """游客链接（局域网只读分享，见 guest.py）：这个会话正在分享的网址"""
    port = guest.guest_port(s.app)
    return Response.json({"ok": True, "shares": [guest.payload_of(x, port) for x in s.app.guest.list(request.query.get("key") or None)]})


def r_share_create(s, request, *_):
    body = request.json or {}
    key = body.get("key") or ""
    if not key:
        return Response.error("缺少会话", 400)
    try:
        hours = int(body.get("hours") or 24)
    except (TypeError, ValueError):
        hours = 0
    share = s.app.guest.create(key, hours)
    if not share:
        return Response.error("有效期只能是 1 小时、24 小时或 7 天", 400)
    return Response.json(dict(guest.payload_of(share, guest.guest_port(s.app)), ok=True))


def r_share_stop(s, request, *_):
    s.app.guest.stop((request.json or {}).get("id") or "")
    return Response.json({"ok": True})


def r_live_register(s, request, kind, who, device_id):
    """iPhone 实时活动的令牌和开关（见 live.py）"""
    s.app.live.register(device_id, request.json or {})
    return Response.json({"ok": True})


def r_push_unsubscribe(s, request, *_):
    endpoint = (request.json or {}).get("endpoint")
    if endpoint:
        s.app.push.remove(endpoint=endpoint)
    return Response.json({"ok": True})


def r_push_test(s, request, *_):
    delivered, errors = s.app.push.send({"title": "Kiteline", "body": "推送通道正常 ✓", "kind": "test"}, wait=True)
    return Response.json({"ok": delivered > 0, "delivered": delivered, "errors": errors,
                          "error": "" if delivered else (errors[0] if errors else "没有可用的推送订阅")})


def r_readiness(s, request, *_):
    return Response.json({"ok": True, "items": s.app.readiness()})


def r_readiness_fix(s, request, *_):
    """就绪检查里的「一键安装」：只认 setup_tools.ACTIONS 里写死的动作，请求里的内容不进命令"""
    action = str((request.json or {}).get("action") or "")
    if action == "allow-firewall":
        from . import firewall
        ok, message = firewall.fix(s.app.cfg)
    else:
        ok, message = setup_tools.start(action)
    log.write("就绪检查一键处理（%s）：%s" % (action[:40], message))
    return Response.json({"ok": ok, "message": message, "error": "" if ok else message}, 200 if ok else 409)


def r_changelog(s, request, *_):
    text = s.app.changelog(english=i18n.lang_of(request) == "en")
    return Response.json({"ok": bool(text), "text": text, "version": s.app.version, "error": "" if text else "此版本未包含更新记录"})


def r_host_update(s, request, *_):
    """手机上看这台电脑的 Kiteline 有没有新版本、下载安装到哪了（同 Mac 版；见 updater.host_payload）"""
    return Response.json(s.app.updater.host_payload())


def r_host_update_post(s, request, *_):
    """手机上点的：{action: check / start / cancel / restart}——让电脑下载安装新版本、装好后重启换上"""
    return Response.json(s.app.updater.remote(str((request.json or {}).get("action") or "")))


def r_schedules(s, request, *_):
    return Response.json({"ok": True, "schedules": s.app.schedules.payloads()})


def r_schedules_add(s, request, *_):
    body = request.json or {}
    if not s.app.store.source(body.get("sourceId", "")):
        return Response.error("机器不存在", 404)
    ok, result = s.app.schedules.add(body.get("sourceId", ""), body.get("cwd", ""), body.get("prompt", ""),
                                     body.get("repeat", ""), body.get("time", ""), body.get("date"))
    return Response.json({"ok": True, "schedule": result}) if ok else Response.error(result, 400)


def r_schedules_update(s, request, *_):
    body = request.json or {}
    task = s.app.schedules.update(body.get("id", ""), body.get("enabled", True))
    return Response.json({"ok": True, "schedule": task}) if task else Response.error("定时任务不存在", 404)


def r_schedules_delete(s, request, *_):
    label = s.app.schedules.remove((request.json or {}).get("id", ""))
    return Response.json({"ok": True, "label": label}) if label else Response.error("定时任务不存在", 404)


def r_schedules_run(s, request, *_):
    ok, message = s.app.schedules.run((request.json or {}).get("id", ""))
    return Response.json({"ok": ok, "message": message, "error": "" if ok else message}, 200 if ok else 409)


def r_new_session(s, request, *_):
    blocked = s.cap_check(request)
    return blocked or s.app.new_session(request)


def r_resume(s, request, *_):
    s.app.idle_close.touch([request.query.get("key", "")])
    blocked = s.cap_check(request)
    return blocked or s.app.resume(request)


def r_viewed(s, request, *_):
    """打开了这些会话的详情（对话页打开时、开着且在前台时每 10 分钟）：{keys:[…]}；
    启动时再带上本机记的最后看过 seen:{key: 毫秒}，补升级前的历史。见 idleclose.py"""
    body = request.json or {}
    keys = body.get("keys")
    s.app.idle_close.touch(keys if isinstance(keys, list) else [])
    s.app.idle_close.merge(body.get("seen"))
    return Response.json({"ok": True})


def r_tts_voices(s, request, *_):
    # 和 Mac 版一样：最自然的在前（微软语音 > Windows 自带语音）；Linux 没装 edge-tts 时为空，手机改用自带语音
    found = tts.voices()
    return Response.json({"ok": True, "voices": found, "best": found[0]["id"] if found else "", "edge": tts.edge_available()})


def r_tts(s, request, *_):
    body = request.json or {}
    text = str(body.get("text") or "").strip()
    if not text or len(text) > 1500:
        return Response.error("朗读文本为空或过长", 400)
    result = s.app.synthesize(text, body.get("voice"), float(body.get("rate") or 1))
    if not result:
        return Response.error("电脑语音合成失败", 500)
    data, mime = result
    return Response(200, {"Content-Type": mime, "Cache-Control": "private, max-age=86400"}, data)


def r_translate(s, request, *_):
    # 翻译一条消息（微信小程序用；同 Mac 的 POST /api/translate）：电脑联网翻好回去
    body = request.json or {}
    text = str(body.get("text") or "").strip()
    if not text or len(text) > 8000:
        return Response.error("翻译内容为空或过长", 400)
    try:
        r = translator.run(text, body.get("to") or None, body.get("from") or None, bool(body.get("local")))
    except translator.TranslateError as e:
        return Response.error(str(e), 502)
    return Response.json(dict(r, ok=True))


def r_bark(s, request, *_):
    m = s.app.cfg.mobile
    return Response.json({"ok": True, "url": m["barkURL"], "mode": m["barkMode"], "encrypted": bool(m["barkKey"]),
                          "valid": bark.parse(m["barkURL"]) is not None})


def r_bark_set(s, request, *_):
    body = request.json or {}
    m = s.app.cfg.mobile
    url = str(body.get("url", m["barkURL"]) or "").strip()
    if url and bark.parse(url) is None:
        return Response.error("Bark 地址无效：请在 Bark App 中复制形如 https://api.day.app/xxxx 的地址", 400)
    mode = body.get("mode") or m["barkMode"]
    if mode not in ("off", "attention", "all"):
        return Response.error("推送范围无效", 400)
    key = body.get("key", m["barkKey"]) or ""
    iv = body.get("iv", m["barkIV"]) or ""
    if key and not (len(key.encode()) in (16, 24, 32) and len(iv.encode()) == 16):
        return Response.error("加密密钥须为 16 / 24 / 32 个字符，IV 须为 16 个字符（与 Bark App 中的设置一致）", 400)
    s.app.cfg.update(lambda d: d["mobile"].update({"barkURL": url, "barkMode": mode, "barkKey": key, "barkIV": iv if key else ""}))
    return Response.json({"ok": True, "url": url, "mode": mode, "encrypted": bool(key)})


def r_bark_test(s, request, *_):
    if bark.parse(s.app.cfg.mobile["barkURL"]) is None:
        return Response.error("尚未填写 Bark 地址", 400)
    suffix = "（加密）" if s.app.cfg.mobile["barkKey"] else ""
    ok, message = bark.send("Kiteline 测试", "Bark 备用推送通道正常 ✓" + suffix, "attention", s.app.cfg.mobile)
    return Response.json({"ok": ok, "message": message, "error": "" if ok else message}, 200 if ok else 502)


# 只在自测（dry-run）时开放：模拟时间推进
def r_alerts_reconnect(s, request, *_):
    """列表顶上 / 锁屏通知里的「尝试重连」（见 alerts.py）"""
    alert_id = (request.json or {}).get("id") or ""
    if not alert_id:
        return Response.error("缺少提示", 400)
    ok, message = s.app.alerts.reconnect(alert_id)
    return Response.json({"ok": ok, "message": message, "error": "" if ok else message}, status=200 if ok else 409)


def r_notify_test(s, request, *_):
    if not delivery.DRY_RUN:
        return Response.error("接口不存在", 404)
    body = request.json or {}
    s.notify(body.get("kind") or "conclusion", body.get("title") or "测试", body.get("body") or "", body.get("key") or "")
    return Response.json({"ok": True})


def _sim_now(request):
    return aggregate.number((request.json or {}).get("now")) / 1000


def r_stuck_tick(s, request, *_):
    if not delivery.DRY_RUN:
        return Response.error("接口不存在", 404)
    s.app.stuck.tick(_sim_now(request))
    return Response.json({"ok": True})


def r_idleclose_tick(s, request, *_):
    """自测用：模拟时间推进，验证闲置会话自动关闭（不等人离开电脑；关是在后台线程里，回得比关得快）"""
    if not delivery.DRY_RUN:
        return Response.error("接口不存在", 404)
    s.app.idle_close.tick(_sim_now(request), force=True)
    return Response.json({"ok": True, "opened": s.app.idle_close.opened_keys()})


def r_reminders_tick(s, request, *_):
    if not delivery.DRY_RUN:
        return Response.error("接口不存在", 404)
    s.app.waiting.tick(_sim_now(request))
    return Response.json({"ok": True})


def r_schedules_tick(s, request, *_):
    if not delivery.DRY_RUN:
        return Response.error("接口不存在", 404)
    import datetime as _dt
    s.app.schedules.tick(_dt.datetime.fromtimestamp(_sim_now(request)))
    return Response.json({"ok": True})


ROUTES = {
    ("GET", "/api/state"): r_state, ("GET", "/api/events"): r_events, ("GET", "/api/history"): r_history,
    ("GET", "/api/agents"): r_agents, ("GET", "/api/trace"): r_trace, ("GET", "/api/peers"): r_peers, ("GET", "/api/task-output"): r_task_output, ("GET", "/api/media"): r_media,
    ("GET", "/api/digest/media"): r_digest_media, ("POST", "/api/send"): r_send, ("POST", "/api/key"): r_key, ("POST", "/api/close"): r_close, ("POST", "/api/queue"): r_queue,
    ("POST", "/api/hosted/probe"): r_hosted_probe, ("POST", "/api/hosted/settings"): r_hosted_settings,
    ("POST", "/api/hosted/move"): r_hosted_move,
    ("POST", "/api/answer"): r_answer, ("POST", "/api/voice"): r_voice, ("GET", "/api/voices"): r_voices,
    ("GET", "/api/voice-audio"): r_voice_audio, ("GET", "/api/git"): r_git, ("GET", "/api/git/diff"): r_git_diff,
    ("GET", "/api/repo"): r_repo_get, ("POST", "/api/repo"): r_repo_post, ("POST", "/api/fs"): r_fs, ("POST", "/api/term"): r_term,
    ("GET", "/api/files"): r_files, ("GET", "/api/file"): r_file, ("GET", "/api/files/find"): r_files_find, ("GET", "/api/download"): r_download,
    ("GET", "/api/tests"): r_tests, ("GET", "/api/session-meta"): r_session_meta, ("GET", "/api/sessions"): r_sessions,
    ("GET", "/api/search"): r_search, ("GET", "/api/projects"): r_projects, ("GET", "/api/dirs"): r_dirs, ("POST", "/api/dirs"): r_dirs, ("GET", "/api/repo-info"): r_repo_info,
    ("GET", "/api/digest"): r_digest, ("POST", "/api/digest/push"): r_digest_push, ("POST", "/api/morning/push"): r_morning_push,
    ("GET", "/api/usage"): r_usage, ("GET", "/api/limits"): r_limits, ("GET", "/api/budget"): r_budget, ("POST", "/api/budget"): r_budget_set,
    ("POST", "/api/budget/check"): r_budget_check, ("GET", "/api/ping"): r_ping, ("GET", "/api/info"): r_info,
    ("GET", "/api/whoami"): r_whoami, ("GET", "/api/devices"): r_devices, ("POST", "/api/devices/link"): r_devices_link,
    ("POST", "/api/devices/register"): r_devices_register, ("POST", "/api/devices/revoke"): r_devices_revoke,
    ("POST", "/api/devices/rename"): r_devices_rename, ("GET", "/api/audit"): r_audit, ("GET", "/api/inbox"): r_inbox,
    ("POST", "/api/quiet"): r_quiet, ("POST", "/api/pin"): r_pin, ("POST", "/api/mark"): r_mark, ("POST", "/api/mute"): r_mute,
    ("POST", "/api/quick-replies"): r_quick_replies, ("GET", "/api/profile"): r_profile, ("POST", "/api/profile"): r_profile_set,
    ("GET", "/api/avatar"): r_avatar, ("GET", "/api/watch"): r_watch, ("POST", "/api/watch"): r_watch_set,
    ("POST", "/api/agent-face"): r_agent_face, ("GET", "/api/agent-avatar"): r_agent_avatar,
    ("GET", "/api/agent-info"): r_agent_info, ("GET", "/api/machine"): r_machine, ("POST", "/api/feedback"): r_feedback,
    ("POST", "/api/watch/status"): r_watch_status, ("POST", "/api/p2p/join"): r_p2p_join, ("POST", "/api/clientlog"): r_clientlog,
    ("POST", "/api/presence"): r_presence, ("GET", "/api/push/key"): r_push_key, ("POST", "/api/push/subscribe"): r_push_subscribe, ("POST", "/api/live/register"): r_live_register,
    ("GET", "/api/share"): r_share_list, ("POST", "/api/share"): r_share_create, ("POST", "/api/share/stop"): r_share_stop,
    ("POST", "/api/push/unsubscribe"): r_push_unsubscribe, ("POST", "/api/push/test"): r_push_test,
    ("GET", "/api/readiness"): r_readiness, ("POST", "/api/readiness/fix"): r_readiness_fix, ("GET", "/api/changelog"): r_changelog, ("GET", "/api/schedules"): r_schedules,
    ("GET", "/api/host-update"): r_host_update, ("POST", "/api/host-update"): r_host_update_post,
    ("POST", "/api/schedules"): r_schedules_add, ("POST", "/api/schedules/update"): r_schedules_update,
    ("POST", "/api/schedules/delete"): r_schedules_delete, ("POST", "/api/schedules/run"): r_schedules_run,
    ("POST", "/api/new-session"): r_new_session, ("POST", "/api/resume"): r_resume, ("POST", "/api/viewed"): r_viewed, ("GET", "/api/tts/voices"): r_tts_voices,
    ("POST", "/api/tts"): r_tts, ("POST", "/api/translate"): r_translate, ("GET", "/api/bark"): r_bark, ("POST", "/api/bark"): r_bark_set, ("POST", "/api/bark/test"): r_bark_test,
    ("POST", "/api/alerts/reconnect"): r_alerts_reconnect, ("POST", "/api/world/intent"): r_world_intent,
    ("POST", "/api/notify/test"): r_notify_test, ("POST", "/api/stuck/tick"): r_stuck_tick, ("POST", "/api/idleclose/tick"): r_idleclose_tick,
    ("POST", "/api/reminders/tick"): r_reminders_tick, ("POST", "/api/schedules/tick"): r_schedules_tick,
}
