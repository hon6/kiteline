"""游客链接（局域网，对应 Mac 版 GuestLinks.swift）：把一个会话分享成只读网址 http://<这台电脑的局域网 IP>:<端口>/g/<编号>，
同一网络（Wi-Fi）里的人用浏览器打开就能看，不用装 Kiteline。

页面（Resources/guest/index.html）和内容都由这台电脑直接给，不经过任何服务器（11-03 起：中继不提供内容展示）；
电脑关机、离开这个网络，链接就打不开。每次打开、刷新（页面 8 秒取一次，没变回 304）现取会话最近的记录生成快照：
只放对话文字和步骤（工具名 + 一句说明），不放思考过程、图片、关键信息（agent 发的密码、地址这类）。
编号是 16 字节随机数，到期或「停止分享」后链接失效。

手机访问的明文 HTTP 只开本机（局域网只走 HTTPS，自签证书会让同事的浏览器报「不是私密连接」），
所以有分享时另开一个只给游客页面用的端口（手机端口 + 2，默认 8767），监听局域网、只认 /g/ 下的路径，没有分享就关掉
"""

import base64
import hashlib
import json
import os
import secrets
import sys
import threading
import time

from . import config, log, netinfo
from .httpd import HTTPServer, Response

HOUR_CHOICES = (1, 24, 168)
AGENT_NAMES = {"claude-code": "Claude Code", "codex": "Codex", "opencode": "OpenCode", "cursor": "Cursor",
               "qwen": "Qwen Code", "dsh": "DeepSeek Harness", "proma": "Proma"}
PAGE_CSP = ("default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'self'; "
            "base-uri 'none'; form-action 'none'; frame-ancestors 'none'")


def _path():
    return os.path.join(config.config_dir(), "guest-links.json")


def page_path():
    """看的页面在哪：打包后的 Windows 版在 _MEIPASS/guest，Linux 包在 desktop/guest，开发时用仓库的 Resources/guest"""
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = []
    base = getattr(sys, "_MEIPASS", None)
    if base:
        candidates.append(os.path.join(base, "guest"))
    candidates += [os.path.join(here, "..", "guest"), os.path.join(here, "..", "..", "Resources", "guest")]
    for folder in candidates:
        path = os.path.join(folder, "index.html")
        if os.path.isfile(path):
            return path
    return None


def guest_port(app):
    """游客端口：手机端口 + 2（HTTPS 是 + 1）"""
    return int(app.cfg.mobile["port"]) + 2


def url_of(share, port):
    """局域网网址：这台电脑的局域网 IP（没有就用主机名）+ 手机访问的 HTTP 端口"""
    net = netinfo.current()
    host = (net.lan or net.names or ["127.0.0.1"])[0]
    return "http://%s:%s/g/%s" % (host, port, share["id"])


def payload_of(share, port):
    return {"id": share["id"], "url": url_of(share, port), "expires": share["expires"], "created": share["created"], "key": share["sessionKey"]}


def _clip(text, limit):
    return text[:limit] + "…" if len(text) > limit else text


def snapshot(share, session, items, more):
    """快照：标题、状态、项目名、agent、最近的对话（u 你说的 / a 回复 / s 步骤 / p 网页 / i 图片张数）"""
    rows = []
    for item in items:
        kind = item.get("t")
        text = (item.get("text") or "").strip()
        if kind == "user" and text:
            row = {"r": "u", "x": _clip(text, 8000)}
        elif kind == "text" and text:
            row = {"r": "a", "x": _clip(text, 8000)}
        elif kind == "tool":
            name = item.get("name") or ""
            if not name or name == "TodoWrite":
                continue
            brief = (item.get("brief") or "").replace("\n", " ")
            # 摘要多半已经以工具名开头（「Bash: npm test」），就不再重复写一遍名字
            step = brief if brief.startswith((name + ":", name + " ")) else ("%s · %s" % (name, brief) if brief else name)
            row = {"r": "s", "x": _clip(step, 120)}
        elif kind == "agent_page":
            row = {"r": "p", "x": _clip(item.get("title") or "", 80)}
        elif kind == "agent_image":
            row = {"r": "i", "n": len(item.get("images") or []) or 1}
        else:
            continue
        if item.get("ts") is not None:
            row["ts"] = item["ts"]
        rows.append(row)
    session = session or {}
    activity = session.get("activity")
    out = {"v": 1, "title": session.get("title") or share.get("title") or "", "items": rows, "more": bool(more),
           "status": activity if activity in ("busy", "waiting") else "idle", "updatedAt": time.time() * 1000}
    cwd = session.get("cwd") or ""
    if cwd:
        out["project"] = os.path.basename(cwd.rstrip("/\\")) or cwd
    agent = session.get("agent") or ""
    if agent:
        out["agent"] = AGENT_NAMES.get(agent, agent)
    return out


class GuestLinks:
    def __init__(self, app):
        self.app = app
        self._lock = threading.RLock()
        self._shares = []
        self._cache = {}              # 编号 → (会话的样子, 快照)：没变就直接给
        self._listener = None         # 游客端口（有分享时开着）
        self._listener_port = 0
        try:
            with open(_path(), encoding="utf-8") as f:
                saved = json.load(f)
            if isinstance(saved, list):
                self._shares = [s for s in saved if isinstance(s, dict) and s.get("expires", 0) > time.time()]
        except (OSError, ValueError):
            pass
        self.sync_listener()

    def sync_listener(self):
        """有分享就开着游客端口、没有就关（端口设置改了换新的）"""
        try:
            port, host = guest_port(self.app), self.app.cfg.mobile["bindAddress"]
        except (AttributeError, KeyError, TypeError, ValueError):
            return   # 单元测试里的假 app 没有配置
        with self._lock:
            active = bool(self.list())
            if self._listener and (not active or self._listener_port != port):
                self._listener.stop()
                self._listener, self._listener_port = None, 0
            if not active or self._listener:
                return
            server = HTTPServer(host, port, self._route)
            try:
                server.start()
            except OSError as exc:
                log.write("游客链接端口启动失败（%s）：%s" % (port, exc))
                return
            self._listener, self._listener_port = server, port
        log.write("游客链接端口监听 %s:%s" % (host, port))

    def _route(self, request):
        if request.method != "GET" or not request.path.startswith("/g/"):
            return Response.text("not found", 404)
        status, headers, body = self.serve(request.path, request.headers.get("if-none-match"))
        return Response(status, headers, body)

    # MARK: 接口（GET /api/share、POST /api/share、POST /api/share/stop）

    def list(self, session_key=None):
        with self._lock:
            self._prune()
            return [dict(s) for s in self._shares if not session_key or s["sessionKey"] == session_key]

    def create(self, session_key, hours):
        if hours not in HOUR_CHOICES:
            return None
        session = self._session(session_key)
        now = time.time()
        share = {"id": base64.urlsafe_b64encode(secrets.token_bytes(16)).rstrip(b"=").decode("ascii"), "sessionKey": session_key,
                 "title": (session or {}).get("title") or "", "expires": now + hours * 3600, "created": now}
        with self._lock:
            self._shares.append(share)
            self._save()
        self.sync_listener()
        log.write("开始在局域网分享会话「%s」的只读网址（%d 小时）" % (share["title"], hours))
        return share

    def stop(self, share_id):
        with self._lock:
            share = next((s for s in self._shares if s["id"] == share_id), None)
            if not share:
                return
            self._shares = [s for s in self._shares if s["id"] != share_id]
            self._cache.pop(share_id, None)
            self._save()
        self.sync_listener()
        log.write("已停止分享会话「%s」的只读网址" % share["title"])

    # MARK: 看的人（GET /g/<编号> 页面、GET /g/api/<编号> 内容；不要令牌）

    def serve(self, path, if_none_match=None):
        """返回 (状态码, 头, 内容)"""
        parts = [p for p in path.split("/") if p]   # ["g", 编号] 或 ["g", "api", 编号]
        if len(parts) == 2:
            page = page_path()
            if not page:
                return 404, {"Content-Type": "text/plain; charset=utf-8"}, b"not found"
            with open(page, "rb") as f:
                data = f.read()
            return 200, {"Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-cache", "X-Content-Type-Options": "nosniff",
                         "Content-Security-Policy": PAGE_CSP, "Referrer-Policy": "no-referrer", "X-Robots-Tag": "noindex, nofollow"}, data
        json_head = {"Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"}
        if len(parts) != 3 or parts[1] != "api":
            return 404, {"Content-Type": "text/plain; charset=utf-8"}, b"not found"
        share_id = parts[2]
        with self._lock:
            self._prune()
            share = next((dict(s) for s in self._shares if s["id"] == share_id), None)
        if not share:
            return 404, json_head, json.dumps({"ok": False, "error": "链接已失效"}, ensure_ascii=False).encode("utf-8")
        session = self._session(share["sessionKey"])
        mark = "%s|%s|%s" % (session.get("activity"), session.get("updatedAt"), session.get("title")) if session else "ended"
        etag = '"%s"' % hashlib.sha256(("%s|%s" % (share_id, mark)).encode("utf-8")).hexdigest()[:16]
        head = dict(json_head, ETag=etag)
        head["X-Share-Expires"] = str(int(share["expires"]))
        if if_none_match == etag:
            return 304, head, b""
        with self._lock:
            cached = self._cache.get(share_id)
        if cached and cached[0] == mark:
            return 200, head, cached[1]
        target = self.app.store.resolve_any(share["sessionKey"])
        if not target:
            return 502, json_head, json.dumps({"ok": False, "error": "取不到这个会话的记录（所在电脑可能离线）"}, ensure_ascii=False).encode("utf-8")
        session_id, source = target
        try:
            response = source.request({"cmd": "history", "sessionId": session_id, "limit": 150}, timeout=30)
        except Exception as exc:  # noqa: BLE001
            return 502, json_head, json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False).encode("utf-8")
        body = json.dumps(snapshot(share, session, response.get("items") or [], response.get("hasMore")), ensure_ascii=False).encode("utf-8")
        with self._lock:
            self._cache[share_id] = (mark, body)
        return 200, head, body

    # MARK: 小工具

    def _session(self, key):
        try:
            return next((s for s in self.app.state_payload().get("sessions") or [] if s.get("key") == key), None)
        except Exception:  # noqa: BLE001
            return None

    def _prune(self):
        now = time.time()
        before = len(self._shares)
        self._shares = [s for s in self._shares if s["expires"] > now]
        if len(self._shares) != before:
            alive = {s["id"] for s in self._shares}
            self._cache = {k: v for k, v in self._cache.items() if k in alive}
            self._save()

    def _save(self):
        try:
            os.makedirs(config.config_dir(), exist_ok=True)
            tmp = _path() + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(self._shares, f, ensure_ascii=False)
            try:
                os.chmod(tmp, 0o600)
            except OSError:
                pass
            os.replace(tmp, _path())
        except OSError as exc:
            log.write("游客链接没存上：%s" % exc)
