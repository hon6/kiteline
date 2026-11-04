"""电脑端界面：本机浏览器里打开的控制台（/desktop，主令牌才能进）+ 系统托盘图标。

控制台：手机访问（二维码、6 位配对码，10 分钟有效、用一次）、连接状态、已配对设备。网页版已下线（同 Mac 版），控制台里不再有入口。
"""

import hmac
import io
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
import webbrowser

from . import config, i18n, kite, log, setup_tools, tls, vscreen
from .httpd import Response

QR_CACHE = {}


def qr_svg(text):
    try:
        import qrcode
        import qrcode.image.svg
    except ImportError:
        return ""
    if text in QR_CACHE:
        return QR_CACHE[text]
    image = qrcode.make(text, image_factory=qrcode.image.svg.SvgPathImage, box_size=8, border=2)
    buffer = io.BytesIO()
    image.save(buffer)
    QR_CACHE.clear()
    QR_CACHE[text] = buffer.getvalue().decode("utf-8")
    return QR_CACHE[text]


def page(english):
    """控制台页面：中文原样；英文把 HTML 里的中文换成英文，脚本里 t("…") 用到的字连同译文一起放进 T"""
    html = PAGE
    keys = sorted(set(re.findall(r'(?<![\w.])t\("((?:[^"\\]|\\.)*)"\)', html)))
    table = {k: i18n.translate(k) for k in keys} if english else {}
    if english:
        head, script = html.split("<script>", 1)
        head = re.sub(r">([^<>]*[\u4e00-\u9fff][^<>]*)<",
                      lambda m: ">%s<" % m.group(1).replace(m.group(1).strip(), i18n.translate(m.group(1).strip())), head)
        head = head.replace('<html lang="zh-CN">', '<html lang="en">').replace('aria-label="语言"', 'aria-label="Language"')
        html = head + "<script>" + script
    return html.replace("__T__", json.dumps(table, ensure_ascii=False))


def localize_status(payload):
    """控制台状态里电脑生成的字（服务状态、来源状态、就绪检查、配对方式……）换成英文；名字、会话标题、路径不动"""
    out = dict(payload)
    out["https"] = i18n.translate(payload.get("https") or "")
    out["remote"] = dict(payload.get("remote") or {}, error=i18n.translate((payload.get("remote") or {}).get("error") or "") or None)
    out["sources"] = [dict(s, status=i18n.translate(s.get("status") or ""), name="This Computer" if s.get("name") == "本机" else s.get("name"))
                      for s in payload.get("sources") or []]
    out["devices"] = [dict(d, via=i18n.translate(d.get("via") or "")) for d in payload.get("devices") or []]
    out["readiness"] = i18n.localize(payload.get("readiness") or [], ("title",))
    return out


class Console:
    def __init__(self, app):
        self.app = app
        # 电脑端自己的界面语言（存在配置里；跟随系统 / 简体中文 / English）
        i18n.set_ui_choice(app.cfg.mobile.get("uiLanguage", "system"))
        self.on_language = None
        self._link = None
        self._code_shown = False
        self._tickets = {}
        self._sessions = {}
        self._lock = threading.Lock()

    def url(self):
        """一次性入场票据（60 秒、用一次）。进门后换成控制台自己的会话令牌：
        经 URL 片段（#s=…，不发给服务器）交给页面，存在 sessionStorage（按协议 + 主机 + 端口隔离），之后用请求头带。
        主令牌既不进地址栏、浏览器历史，也不放 Cookie（Cookie 不分端口，本机别的服务也会收到）"""
        ticket = secrets.token_hex(16)
        stamp = time.time()
        with self._lock:
            self._tickets = {k: v for k, v in self._tickets.items() if v > stamp}
            self._tickets[ticket] = stamp + 60
        return "http://127.0.0.1:%s/desktop?k=%s" % (self.app.cfg.mobile["port"], ticket)

    def _use_ticket(self, ticket):
        with self._lock:
            for key, expiry in list(self._tickets.items()):
                if hmac.compare_digest(key, ticket):
                    del self._tickets[key]
                    return expiry > time.time()
        return False

    def _new_session(self):
        token = "c" + secrets.token_hex(24)
        stamp = time.time()
        with self._lock:
            self._sessions = {k: v for k, v in self._sessions.items() if v > stamp}
            self._sessions[token] = stamp + 12 * 3600
        return token

    def session_ok(self, token):
        """控制台会话令牌：12 小时有效，Kiteline 重启后作废（重新从托盘打开即可）"""
        if not token or not token.startswith("c"):
            return False
        with self._lock:
            return any(hmac.compare_digest(key, token) and expiry > time.time() for key, expiry in self._sessions.items())

    def open(self):
        """打开 Kiteline：装了原生客户端就开客户端窗口（已经开着的会被叫到前面），没有才用浏览器开控制台"""
        client = client_path()
        if client and open_client(client):
            return
        self.open_browser()

    def open_browser(self):
        webbrowser.open(self.url())

    def handle(self, request, is_master):
        """返回 Response；不归控制台管的返回 None"""
        if request.path == "/desktop" and request.method == "GET":
            ticket = request.query.get("k", "")
            if ticket and self._use_ticket(ticket):
                return Response(303, {"Location": "/desktop#s=%s" % self._new_session(), "Cache-Control": "no-store"})
            # 页面本身不含任何数据（数据都要带会话令牌去 /api/desktop/* 取）；没有令牌时页面上提示从托盘重新打开
            return Response(200, {"Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store",
                                  "Referrer-Policy": "no-referrer"}, page(i18n.ui_english()))
        if request.path == "/api/desktop/jump" and request.method == "POST" and is_master:
            # 电脑端客户端会话菜单「在 VS Code 中打开」：切到会话所在窗口，没开着就新开（远端项目经 Remote-SSH）
            ok, message = self.app.open_in_editor(str((request.json or {}).get("key") or ""))
            return Response.json({"ok": True, "message": message}) if ok else Response.error(message, 409)
        if request.path == "/api/desktop/open" and request.method == "POST" and is_master:
            threading.Timer(0.1, self.open).start()   # 又双击了一次 Kiteline：已经在跑的这份打开控制台
            return Response.json({"ok": True})
        if request.path == "/api/desktop/status" and is_master:
            payload = self.status()
            return Response.json(localize_status(payload) if i18n.ui_english() else payload)
        if request.path == "/api/desktop/pairing" and request.method == "POST" and is_master:
            return Response.json(self.pairing(bool((request.json or {}).get("renew"))))
        if request.path == "/api/desktop/revoke" and request.method == "POST" and is_master:
            device = self.app.server.revoke_device((request.json or {}).get("id", ""))
            return Response.json({"ok": bool(device)})
        if request.path.startswith("/api/desktop/sources") and is_master:
            return self.sources(request.path[len("/api/desktop/sources"):], request.method, request.json or {})
        if request.path == "/api/desktop/reset-token" and request.method == "POST" and is_master:
            return Response.json({"ok": True, "token": self.app.server.reset_token()})
        if request.path == "/api/desktop/vscreen" and is_master:
            # 「VS Code 在虚拟屏幕中运行」（客户端侧栏底栏的显示器按钮、设置 → 通用）：GET 状态，POST {on} 开关
            if request.method != "POST":
                return Response.json(vscreen.state())
            on = (request.json or {}).get("on")
            result = vscreen.toggle() if on is None else (vscreen.turn_on() if on else vscreen.turn_off())
            if self.on_language:
                self.on_language()   # 托盘菜单里的「移到 / 移回」跟着换
            return Response.json(result)
        if request.path == "/api/desktop/settings" and request.method == "POST" and is_master:
            return Response.json(self.settings(request.json or {}))
        if request.path == "/api/desktop/config" and is_master:
            return Response.json(self.config(request.json if request.method == "POST" else None))
        if request.path.startswith("/api/desktop/update") and is_master:
            return self.update(request)
        if request.path.startswith("/api/desktop/plugins") and is_master:
            return self.plugins(request)
        return None

    def plugins(self, request):
        """设置 → 插件（plugins.py）：GET /api/desktop/plugins 列表和状态；POST …/check 现在查；…/install {id} 安装或更新；
        …/enable {id, enabled} 开关；…/option {id, option, enabled} 插件的单项开关；…/remove {id} 恢复内置版本；…/update-install {id} 先更新 Kiteline 再装；
        …/report {key 或 id} 出错报告（mailto 链接和正文）；…/mute {key} 这个错不再询问；…/dismiss {key} 先不报告"""
        store = self.app.plugins
        action = request.path[len("/api/desktop/plugins"):]
        body = request.json or {}
        plugin_id = str(body.get("id") or "")
        if request.method == "GET" and action == "":
            payload = store.state()
        elif request.method == "POST" and action == "/check":
            payload = store.check(auto=False)
        elif request.method == "POST" and action == "/install" and plugin_id:
            payload = store.install(plugin_id)
        elif request.method == "POST" and action == "/enable" and plugin_id:
            payload = store.set_enabled(plugin_id, bool(body.get("enabled")))
        elif request.method == "POST" and action == "/option" and plugin_id and body.get("option"):
            payload = store.set_option(plugin_id, str(body["option"]), bool(body.get("enabled")))
        elif request.method == "POST" and action == "/remove" and plugin_id:
            payload = store.remove(plugin_id)
        elif request.method == "POST" and action == "/update-install" and plugin_id:
            payload = store.update_then_install(plugin_id)
        elif request.method == "POST" and action == "/report":
            payload = store.report(key=body.get("key"), plugin_id=plugin_id or None)
        elif request.method == "POST" and action == "/mute" and body.get("key"):
            payload = store.mute(str(body["key"]))
        elif request.method == "POST" and action == "/dismiss" and body.get("key"):
            payload = store.dismiss(str(body["key"]))
        else:
            return Response.error("接口不存在", 404)
        return Response.json(payload)

    # 客户端设置窗口能改的配置项：键 → 校验（不在表里的一律不认）
    CONFIG_KEYS = {
        "notifyOnNeedsAttention": bool, "notifyOnConclusion": bool,   # 存在配置顶层（同 Mac 版）
        "remindWaiting": bool, "autoCloseIdle": bool, "hostedTipOff": bool, "submitOnSend": bool,
        "digestTime": "time", "morningTime": "time", "quietStart": "time", "quietEnd": "time",
        "voiceLocale": ("zh-CN", "zh-HK", "zh-TW", "en-US"),
        "relayURL": "url", "installOpenCodePlugin": bool, "usageStats": bool, "installAgentSkill": bool,
        "installTestSkill": bool, "installTodoSkill": bool, "installStageSkill": bool,
    }
    TOP_LEVEL = ("notifyOnNeedsAttention", "notifyOnConclusion")

    def config(self, body):
        """GET /api/desktop/config 读；POST {键: 值} 按 CONFIG_KEYS 改（时间是 HH:MM 或空字符串 = 关；中继地址空 = Kiteline 自己的）"""
        app = self.app
        if body:
            changes, top = {}, {}
            for key, rule in self.CONFIG_KEYS.items():
                if key not in body:
                    continue
                value = body[key]
                if rule is bool:
                    if not isinstance(value, bool):
                        continue
                elif rule == "time":
                    value = str(value or "").strip()
                    if value and not config.parse_hm(value):
                        continue
                elif rule == "url":
                    value = str(value or "").strip().rstrip("/")
                    if value and not value.startswith("https://"):
                        continue
                elif value not in rule:
                    continue
                (top if key in self.TOP_LEVEL else changes)[key] = value
            if changes or top:
                def apply(data):
                    data["mobile"].update(changes)
                    data.update(top)
                app.cfg.update(apply)
                if changes.get("usageStats"):
                    app.stats.kick()
                if {"installAgentSkill", "installTestSkill", "installTodoSkill", "installStageSkill"} & set(changes):
                    # 技能开关：在线的 watcher（本机、远端）马上照着装上 / 删掉
                    from . import agent_skill
                    agent_skill.ENABLED = bool(changes.get("installAgentSkill", agent_skill.ENABLED))
                    agent_skill.TEST_ENABLED = bool(changes.get("installTestSkill", agent_skill.TEST_ENABLED))
                    agent_skill.TODO_ENABLED = bool(changes.get("installTodoSkill", agent_skill.TODO_ENABLED))
                    agent_skill.STAGE_ENABLED = bool(changes.get("installStageSkill", agent_skill.STAGE_ENABLED))
                    agent_skill.sync_live(app.store.sources.values())
                if "relayURL" in changes and app.cfg.mobile["remoteEnabled"]:
                    app.p2p.stop()
                    app.p2p.start(app.cfg.relay(), app.cfg.https_port())
                app.server.publish_state()
        m = app.cfg.mobile
        payload = {key: (app.cfg.get(key, True) if key in self.TOP_LEVEL else m.get(key)) for key in self.CONFIG_KEYS}
        payload.update({"ok": True, "builtinRelay": config.BUILTIN_RELAY})
        return payload

    def update(self, request):
        """检查更新（客户端右上角的绿色箭头、控制台、托盘都用这几个）：
        GET /api/desktop/update 状态；POST …/check 现在查；…/start 下载并安装；…/cancel 取消下载；
        …/restart {client: {pid, exe, args}} 重启换上新版本；…/skip {key, on} 勾 / 取消「此版本不再提示」；
        …/prompted {key} 弹过了（24 小时内不再自动弹；…/later 同它，旧控制台页用）。key 是 state 里的 key（电脑端）或 phones.key（手机端）"""
        updater = self.app.updater
        action = request.path[len("/api/desktop/update"):]
        if request.method == "GET" and action == "":
            payload = updater.state()
        elif request.method == "POST" and action == "/check":
            payload = updater.check()
        elif request.method == "POST" and action == "/start":
            payload = updater.begin()
        elif request.method == "POST" and action == "/cancel":
            payload = updater.cancel()
        elif request.method == "POST" and action == "/restart":
            payload = updater.restart((request.json or {}).get("client"))
        elif request.method == "POST" and action == "/client":
            body = request.json or {}
            updater.client = {"pid": int(body.get("pid") or 0), "exe": str(body.get("exe") or ""), "args": [str(a) for a in body.get("args") or []]}
            payload = updater.state()
        elif request.method == "POST" and action == "/skip":
            body = request.json or {}
            payload = updater.set_skipped(str(body.get("key") or ""), bool(body.get("on")))
        elif request.method == "POST" and action in ("/prompted", "/later"):
            payload = updater.mark_shown(str((request.json or {}).get("key") or updater.state()["key"]))
        else:
            return Response.error("接口不存在", 404)
        return Response.json(i18n.localize(payload) if i18n.ui_english() else payload)

    def pairing(self, renew):
        app = self.app
        if renew or not self._link or not app.pairing.link_valid(self._link):
            self._link = app.new_link_token()
        if renew or not app.pairing.code or time.time() >= app.pairing.expiry:
            app.new_code()
        link = app.pairing_link(self._link)
        # addresses + query：客户端换地址时自己拼链接、画二维码（同 Mac 版的地址下拉框）
        return {"ok": True, "code": app.pairing.code, "expiry": app.pairing.expiry * 1000, "link": link, "qr": qr_svg(link),
                "addresses": app.pairing_addresses(), "query": app.pairing_query(self._link)}

    def status(self):
        app = self.app
        m = app.cfg.mobile
        with app.store.lock:
            sources = [{"name": s.name, "online": s.live, "status": s.short_label()} for s in app.store.sources.values()]
            sessions = [{"title": r.snap.get("title") or r.snap.get("name"), "activity": r.activity,
                         "cwd": r.snap.get("cwdShort") or r.snap.get("cwd")} for r in app.store.records]
        from .app import autostart_enabled, delivery_status
        ready, why = delivery_status()
        return {"ok": True, "host": app.host, "version": app.version, "platform": config.PLATFORM,
                "https": app.server.secure_status, "remote": app.p2p.status, "remoteEnabled": m["remoteEnabled"],
                "clients": app.server.client_count(), "sources": sources, "sessions": sessions,
                "devices": [app.server.device_payload(d, None) for d in app.devices.all],
                "delivery": {"ready": ready, "reason": why}, "autostart": autostart_enabled(),
                "fingerprint": tls.ca_fingerprint(), "dataDir": config.config_dir(),
                "readiness": app.readiness(), "uiLanguage": i18n.ui_choice(), "virtualScreen": vscreen.state()}

    def sources(self, action, method, body):
        """来源管理（客户端「来源」页）：GET 列表和建议；POST /add {host, name, port}、/update {id, name, enabled}、/remove {id}、/reconnect {id}"""
        app = self.app
        if method == "GET" and action in ("", "/"):
            payload = app.source_list()
            if i18n.ui_english():
                payload = i18n.localize(payload)
                for item in payload["sources"]:
                    item["name"] = "This Computer" if item.get("name") == "本机" else item.get("name")
            return Response.json(dict(payload, ok=True))
        if method != "POST":
            return Response.error("不支持的操作", 405)
        if action == "/add":
            problem = app.add_ssh_source(str(body.get("host") or ""), str(body.get("name") or ""), body.get("port") or None)
            if problem:
                return Response.error(i18n.tr("无法连接：%s。需确保可在终端中免密 ssh 登录（BatchMode）。" % problem), 400)
            return Response.json({"ok": True})
        if action == "/update":
            ok = app.update_source(str(body.get("id") or ""), name=body.get("name"), enabled=body.get("enabled"))
            return Response.json({"ok": ok})
        if action == "/remove":
            return Response.json({"ok": app.remove_source(str(body.get("id") or ""))})
        if action == "/reconnect":
            app.reconnect_sources(body.get("id") or None)
            return Response.json({"ok": True})
        return Response.error("不支持的操作", 404)

    def settings(self, body):
        from . import autostart
        if "uiLanguage" in body:
            choice = str(body["uiLanguage"])
            i18n.set_ui_choice(choice)
            self.app.cfg.update(lambda d: d["mobile"].update({"uiLanguage": i18n.ui_choice()}))
            if self.on_language:
                self.on_language()   # 托盘菜单跟着换
        if "autostart" in body:
            autostart.set_enabled(bool(body["autostart"]))
        if "remoteEnabled" in body:
            on = bool(body["remoteEnabled"])
            self.app.cfg.update(lambda d: d["mobile"].update({"remoteEnabled": on}))
            if on:
                self.app.p2p.start(self.app.cfg.relay(), self.app.cfg.https_port())
            else:
                self.app.p2p.stop()
        return {"ok": True}


def client_path():
    """原生客户端（desktop/client 发布出来的 KitelineApp）：Windows 打包版在 Kiteline.exe 旁边的 app 文件夹，
    Linux 安装版在安装目录的 app 里；开发时可用 KITELINE_CLIENT 指定"""
    override = os.environ.get("KITELINE_CLIENT")
    if override:
        return override if os.path.isfile(override) else None
    name = "KitelineApp.exe" if config.IS_WINDOWS else "KitelineApp"
    base = os.path.dirname(sys.executable) if getattr(sys, "frozen", False) else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(base, "app", name)
    return path if os.path.isfile(path) else None


def open_client(path):
    try:
        if config.IS_WINDOWS:
            subprocess.Popen([path], cwd=os.path.dirname(path), close_fds=True, creationflags=0x00000008 | 0x00000200)   # DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
        else:
            subprocess.Popen([path], cwd=os.path.dirname(path), close_fds=True, start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except OSError as exc:
        log.write("打开客户端失败（%s），改用浏览器" % exc)
        return False


PAGE = """<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Kiteline</title>
<style>
:root{--bg:#f5f5f4;--card:#fff;--text:#1c1c1e;--sub:#6b6b70;--line:#e4e4e2;--accent:#d97757}
@media (prefers-color-scheme:dark){:root{--bg:#0b0b0c;--card:#161618;--text:#f2f2f2;--sub:#9a9aa0;--line:#2a2a2d}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.55 -apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif}
.wrap{max-width:980px;margin:0 auto;padding:28px 20px 48px}
header{display:flex;align-items:center;gap:12px;margin-bottom:22px}
header h1{font-size:20px;font-weight:600;margin:0}header .host{color:var(--sub);margin-right:auto}
.grid{display:grid;grid-template-columns:minmax(0,1.1fr) minmax(0,1fr);gap:16px}
@media (max-width:760px){.grid{grid-template-columns:1fr}}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:18px 20px}
.card h2{font-size:15px;font-weight:600;margin:0 0 4px}.card p.sub{color:var(--sub);margin:0 0 14px}
.pair{display:flex;gap:22px;align-items:center;flex-wrap:wrap}
.qr{width:200px;height:200px;background:#fff;border-radius:10px;padding:6px;border:1px solid var(--line)}
.qr svg{width:100%;height:100%}
.code{font:600 34px/1.1 ui-monospace,"Cascadia Mono",Menlo,monospace;letter-spacing:.18em}
.muted{color:var(--sub);font-size:12.5px}
button{font:inherit;border:1px solid var(--line);background:var(--card);color:var(--text);border-radius:8px;padding:6px 12px;cursor:pointer}
button.primary{background:var(--accent);border-color:var(--accent);color:#fff}
.row{display:flex;justify-content:space-between;align-items:center;gap:12px;padding:9px 0;border-top:1px solid var(--line)}
.row:first-of-type{border-top:none}.row .k{color:var(--sub);flex-shrink:0;white-space:nowrap}.row .v{text-align:right;word-break:break-all}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px;background:#9a9aa0}
.ok{background:#3a9d5d}.warn{background:#c9a227}.bad{background:#c94c4c}
.list{margin:0;padding:0;list-style:none}.list li{padding:8px 0;border-top:1px solid var(--line);display:flex;justify-content:space-between;gap:10px}
.list li:first-child{border-top:none}.empty{color:var(--sub);padding:6px 0}
.full{grid-column:1/-1}
.upd{width:30px;height:30px;border-radius:50%;border:none;background:#34c759;color:#fff;padding:0;display:grid;place-items:center;box-shadow:0 1px 4px rgba(52,199,89,.45)}
.upd[hidden]{display:none}.upd svg{width:16px;height:16px}
dialog{border:1px solid var(--line);border-radius:14px;background:var(--card);color:var(--text);padding:20px 22px;width:min(440px,92vw)}
dialog::backdrop{background:rgba(0,0,0,.35)}dialog h2{font-size:16px;margin:0 0 6px}
.notes{white-space:pre-wrap;max-height:220px;overflow:auto;font-size:13px;margin:10px 0;padding:10px 12px;border-radius:8px;background:var(--bg)}
.notes:empty{display:none}
.bar{height:6px;border-radius:3px;background:var(--line);overflow:hidden;margin:14px 0 6px}.bar i{display:block;height:100%;width:0;background:#34c759;transition:width .2s}
.bar.indet i{width:35%;animation:indet 1.1s ease-in-out infinite}@keyframes indet{0%{margin-left:-35%}100%{margin-left:100%}}
.acts{display:flex;justify-content:flex-end;gap:8px;margin-top:16px}
</style></head><body><div class="wrap">
<header>""" + kite.SVG_GLYPH + """
<h1>Kiteline</h1><span class="host" id="host"></span>
<button id="upd" class="upd" onclick="openUpdate()" hidden><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M8 13V3M3.5 7.5 8 3l4.5 4.5"/></svg></button>
<select id="lang" onchange="setLang(this.value)" aria-label="语言"><option value="system">跟随系统</option><option value="zh">简体中文</option><option value="en">English</option></select></header>
<div class="grid">
<section class="card"><h2>手机访问</h2><p class="sub">在 iPhone 上打开 Kiteline，扫描二维码或输入配对码。10 分钟内有效，仅可使用一次。</p>
<div class="pair"><div class="qr" id="qr"></div><div><div class="muted">配对码</div><div class="code" id="code">······</div>
<div class="muted" id="expiry"></div><div style="margin-top:12px"><button onclick="pairing(true)">刷新</button></div></div></div></section>
<section class="card"><h2>状态</h2><p class="sub">这台电脑上 Kiteline 的运行情况</p><div id="status"></div></section>
<section class="card"><h2>已配对的设备</h2><p class="sub">手机丢失或不再使用时，可在此停用</p><ul class="list" id="devices"></ul></section>
<section class="card"><h2>正在运行的会话</h2><p class="sub">本机及各远端主机上的 Claude Code</p><ul class="list" id="sessions"></ul></section>
<section class="card full"><h2>就绪检查</h2><p class="sub">以下各项完成后即可使用全部功能</p><div id="ready"></div></section>
</div></div>
<dialog id="ud"><h2 id="udt"></h2><div class="muted" id="uds"></div><div class="notes" id="udn"></div>
<div class="bar" id="udbar" hidden><i id="udb"></i></div><div class="acts" id="uda"></div></dialog>
<script>
const T=__T__;function t(s){return T[s]||s}
const $=id=>document.getElementById(id);
const SK="kl-console";
(()=>{const m=location.hash.match(/^#s=(c[0-9a-f]+)$/);if(m){try{sessionStorage.setItem(SK,m[1])}catch(_){}window.__s=m[1];history.replaceState(null,"","/desktop")}})();
function sess(){try{return sessionStorage.getItem(SK)||window.__s||""}catch(_){return window.__s||""}}
function expired(){document.querySelector(".grid").innerHTML='<section class="card full"><h2>'+t("入口已失效")+'</h2><p class="sub">'+t("请点任务栏托盘里的 Kiteline 图标，或再次打开 Kiteline，重新进入控制台。")+'</p></section>';throw new Error("expired")}
async function api(p,b){const h={"X-CCP-Token":sess()};if(b)h["Content-Type"]="application/json";const r=await fetch(p,b?{method:"POST",headers:h,body:JSON.stringify(b)}:{headers:h,cache:"no-store"});if(r.status===401||r.status===403)expired();return r.json()}
function esc(s){return String(s??"").replace(/[&<>"]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]))}
let expiry=0;
async function pairing(renew){const r=await api("/api/desktop/pairing",{renew});$("qr").innerHTML=r.qr||"";$("code").textContent=r.code||"······";expiry=r.expiry}
setInterval(()=>{const left=Math.max(0,Math.round((expiry-Date.now())/1000));$("expiry").textContent=left?t("%@ 后失效").replace("%@",`${Math.floor(left/60)}:${String(left%60).padStart(2,"0")}`):t("已失效");if(!left&&expiry)pairing(true)},1000);
const act={busy:t("运行中"),waiting:t("待确认"),idle:t("空闲"),unknown:t("未知")};
async function status(){const s=await api("/api/desktop/status");$("host").textContent=`${s.host} · ${s.platform==="windows"?"Windows":"Linux"} · ${s.version}`;
$("lang").value=s.uiLanguage||"system";
const remote=s.remote.state==="online"?t("已连接中继"):(s.remoteEnabled?(s.remote.error||t("连接中…")):t("未开启"));
const auto=`${s.autostart?t("已开启"):t("未开启")} <button onclick="setAuto(${!s.autostart})">${s.autostart?t("关闭"):t("开启")}</button>`;
$("status").innerHTML=[[t("HTTPS 服务"),esc(s.https)],[t("远程访问"),esc(remote)],[t("已连接的手机"),esc(s.clients)],[t("监听的机器"),esc(s.sources.map(x=>`${x.name}${t("：")}${x.status}`).join(t("；"))||t("无"))],[t("开机自动启动"),auto],[t("数据目录"),esc(s.dataDir)]].map(([k,v])=>`<div class="row"><span class="k">${k}</span><span class="v">${v}</span></div>`).join("");
$("devices").innerHTML=s.devices.length?s.devices.map(d=>`<li><span><span class="dot ${d.online?"ok":""}"></span>${esc(d.name)} <span class="muted">${esc(d.via)}</span></span><button onclick="revoke('${d.id}')">${t("停用")}</button></li>`).join(""):'<li class="empty">'+t("暂无已配对的设备")+'</li>';
$("sessions").innerHTML=s.sessions.length?s.sessions.map(x=>`<li><span>${esc(x.title)}<div class="muted">${esc(x.cwd)}</div></span><span class="muted">${act[x.activity]||""}</span></li>`).join(""):'<li class="empty">'+t("没有运行中的会话")+'</li>';
$("ready").innerHTML=s.readiness.map(i=>`<div class="row"><span><span class="dot ${i.level}"></span>${esc(i.title)}</span><span class="v muted">${esc(i.detail)}${i.level!=="ok"&&i.fix?"<br>"+esc(i.fix):""}</span></div>`).join("")}
async function revoke(id){if(confirm(t("停用后该设备需要重新配对。确定停用吗？"))){await api("/api/desktop/revoke",{id});status()}}
async function setAuto(on){await api("/api/desktop/settings",{autostart:on});status()}
async function setLang(v){await api("/api/desktop/settings",{uiLanguage:v});location.reload()}
// 检查更新：有新版本时右上角出绿色向上箭头；点开确认 → 下载（进度条）→ 静默安装 → 提示重启
let up={},restarting=false;
function mb(n){return n>=1048576?(n/1048576).toFixed(1)+" MB":Math.max(1,Math.round(n/1024))+" KB"}
function btn(label,fn,primary){const b=document.createElement("button");b.textContent=label;if(primary)b.className="primary";b.onclick=fn;return b}
async function updState(){try{up=await api("/api/desktop/update")}catch(e){if(restarting)return;throw e}
$("upd").hidden=!["available","downloading","installing","ready"].includes(up.phase);
$("upd").title=up.phase==="ready"?t("重启以完成更新"):t("有新版本 %@").replace("%@",up.version);
if($("ud").open)drawUpdate()}
function drawUpdate(){const a=$("uda");a.innerHTML="";const bar=$("udbar"),fill=$("udb");bar.hidden=true;bar.classList.remove("indet");$("udn").textContent="";
const close=()=>$("ud").close();
if(restarting){$("udt").textContent=t("正在重启 Kiteline…");$("uds").textContent=t("新版本启动后页面会自动刷新");bar.hidden=false;bar.classList.add("indet");return}
if(!up.supported&&up.phase==="available"){$("udt").textContent=t("Kiteline %@ 可用").replace("%@",up.version);$("uds").textContent=t(up.reason);$("udn").textContent=up.notes||"";
a.append(btn(t("关闭"),close),btn(t("打开下载页"),()=>{window.open(up.page,"_blank");close()},true));return}
switch(up.phase){
case "available":$("udt").textContent=t("Kiteline %@ 可用").replace("%@",up.version);$("uds").textContent=t("当前版本 %@").replace("%@",up.current)+(up.size?" · "+mb(up.size):"");$("udn").textContent=up.notes||"";
a.append(btn(t("以后再说"),()=>{api("/api/desktop/update/later",{});close()}),btn(t("下载并安装"),async()=>{await api("/api/desktop/update/start",{});updState()},true));break;
case "downloading":$("udt").textContent=t("正在下载 Kiteline %@").replace("%@",up.version);bar.hidden=false;fill.style.width=(up.size?Math.min(100,up.received/up.size*100):0)+"%";
$("uds").textContent=up.size?`${mb(up.received)} / ${mb(up.size)}`:mb(up.received);a.append(btn(t("取消"),async()=>{await api("/api/desktop/update/cancel",{});updState()}));break;
case "installing":$("udt").textContent=t("正在安装…");$("uds").textContent=t("安装在后台进行，不影响使用");bar.hidden=false;bar.classList.add("indet");a.append(btn(t("隐藏"),close));break;
case "ready":$("udt").textContent=t("新版本已安装");$("uds").textContent=t("重启 Kiteline 后生效，正在进行的会话不受影响。");
a.append(btn(t("稍后"),close),btn(t("立即重启"),restartNow,true));break;
case "error":$("udt").textContent=t("更新失败");$("uds").textContent=t(up.error||"");a.append(btn(t("关闭"),close),btn(t("重试"),async()=>{await api("/api/desktop/update/start",{});updState()},true));break;
default:$("udt").textContent=t("已是最新版本");$("uds").textContent=t("当前版本 %@").replace("%@",up.current);a.append(btn(t("好"),close,true))}}
function openUpdate(){drawUpdate();$("ud").showModal()}
async function restartNow(){const r=await api("/api/desktop/update/restart",{});if(!r.ok){up.phase="error";up.error=r.error;drawUpdate();return}
restarting=true;drawUpdate();const old=up.current;
// 新版本起来后控制台会话令牌作废：等它起来，提示从托盘重新打开
const timer=setInterval(async()=>{try{const r=await fetch("/api/desktop/update",{headers:{"X-CCP-Token":sess()},cache:"no-store"});if(r.status===401){clearInterval(timer);expired()}}catch(_){}},1500)}
setInterval(()=>{if($("ud").open&&!restarting)updState()},700);
if(!sess())expired();
pairing(false);status();updState();setInterval(()=>{if(!restarting){status();updState()}},4000);
</script></body></html>"""


def run_tray(app, console, stop_event):
    """系统托盘（pystray）：打开控制台、退出。装不了托盘库或没有图形界面时直接返回 False"""
    try:
        import pystray
        import PIL  # noqa: F401  托盘图标用 PIL 画（kite.tray_image）
    except Exception as exc:  # noqa: BLE001
        log.write("托盘图标不可用（%s），只在后台运行" % exc)
        return False
    # 纸鸢剪影（形状和 App 图标同一份，见 kite.py）
    image = kite.tray_image(64)

    def on_open(icon, item):
        console.open()

    def on_console(icon, item):
        console.open_browser()

    def on_quit(icon, item):
        icon.stop()
        stop_event.set()

    def on_update(icon, item):
        phase = app.updater.phase
        if phase == "ready":
            app.updater.restart()
        elif phase in ("available", "error"):
            result = app.updater.begin()
            try:
                icon.notify(i18n.tr("正在后台下载新版本，装好后会提示重启") if result.get("ok") else i18n.tr(result.get("error") or "更新失败"), "Kiteline")
            except Exception:  # noqa: BLE001
                pass

    def update_title(item):
        u = app.updater
        if u.phase == "ready":
            return i18n.tr("重启以完成更新")
        if u.phase == "downloading":
            size = (u.release or {}).get("size") or 0
            return i18n.tr("正在下载更新 %@").replace("%@", "%d%%" % int(u.received * 100 / size) if size else "…")
        if u.phase == "installing":
            return i18n.tr("正在安装更新…")
        return i18n.tr("下载并安装 Kiteline %@").replace("%@", (u.release or {}).get("version", ""))

    def on_vscreen(icon, item):
        result = vscreen.toggle()
        icon.update_menu()
        if result.get("ok"):
            message = (i18n.tr("已将 %@ 个 VS Code 窗口移回主屏幕").replace("%@", str(result.get("restored", 0))) if "restored" in result
                       else i18n.tr("已将 %@ 个 VS Code 窗口移到虚拟屏幕").replace("%@", str(result.get("moved", 0))) if result.get("moved")
                       else i18n.tr("已创建虚拟屏幕。VS Code 尚未运行，由 Kiteline 打开的 VS Code 窗口将放到虚拟屏幕上") if not result.get("editorRunning")
                       else i18n.tr("VS Code 窗口已在虚拟屏幕上"))
        else:
            message = i18n.tr(result.get("error") or "无法移到虚拟屏幕")
        try:
            icon.notify(message, "Kiteline")
        except Exception:  # noqa: BLE001
            pass

    def on_install(icon, item):
        # 缺组件时：弹系统授权窗口装上（和手机就绪检查里的「一键安装」同一套）
        ok, message = setup_tools.start("install-all")
        log.write("托盘：%s" % message)
        try:
            icon.notify(message, "Kiteline")
        except Exception:  # noqa: BLE001  有的桌面不支持托盘通知
            pass
    # 菜单文字每次弹出时按电脑端的界面语言取（控制台里换了语言会调 update_menu 重画）
    icon = pystray.Icon("Kiteline", image, "Kiteline", menu=pystray.Menu(
        pystray.MenuItem(lambda item: i18n.tr("打开 Kiteline"), on_open, default=True),
        pystray.MenuItem(lambda item: i18n.tr("打开控制台（浏览器）"), on_console, visible=lambda item: bool(client_path())),
        pystray.MenuItem(update_title, on_update, enabled=lambda item: app.updater.phase in ("available", "error", "ready"),
                         visible=lambda item: app.updater.supported and app.updater.phase in ("available", "downloading", "installing", "ready")
                         or (app.updater.phase == "error" and bool(app.updater.release))),
        pystray.MenuItem(lambda item: i18n.tr("安装从手机发消息所需的组件…"), on_install, visible=lambda item: bool(setup_tools.missing("install-all"))),
        # 同 Mac 版菜单栏的「VS Code 移到虚拟屏幕 / 移回主屏幕」
        pystray.MenuItem(lambda item: i18n.tr("VS Code 移回主屏幕") if vscreen.state()["on"] else i18n.tr("VS Code 移到虚拟屏幕"), on_vscreen,
                         visible=lambda item: vscreen.supported()[0]),
        pystray.MenuItem(lambda item: i18n.tr("退出"), on_quit)))
    console.on_language = lambda: icon.update_menu()
    notified = set()

    def update_changed():
        icon.update_menu()
        u = app.updater
        key = "%s/%s" % (u.phase, (u.release or {}).get("version"))
        version = (u.release or {}).get("version") or ""
        if u.phase in ("available", "ready") and key not in notified and not (u.phase == "available" and u.is_skipped(u.key(version))):
            notified.add(key)
            try:
                icon.notify(i18n.tr("Kiteline %@ 可用").replace("%@", u.release["version"]) if u.phase == "available"
                            else i18n.tr("新版本已安装，重启 Kiteline 后生效"), "Kiteline")
            except Exception:  # noqa: BLE001
                pass
    app.on_update_change = update_changed
    icon.run()
    return True
