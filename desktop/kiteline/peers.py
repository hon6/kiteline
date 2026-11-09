"""Kiteline 电脑互联（同 Mac 版 Sources/PeerComputers.swift，协议一样，Mac 和 Windows / Linux 可以互加）。

把另一台装了 Kiteline 的电脑加成来源（异地办公）：输对方的地址和对方「手机访问」页上的 6 位验证码，对方点「允许」后两台互相登记。
  · 对方的每个来源在本机变成 kind = "kiteline" 的来源（id「kl:<对方编号前 8 位>:<对方来源 id>」），会话并进同一个列表；
  · watcher 事件经对方的 /api/peer/watch 原样转过来，watcher 请求经 /api/peer/rpc 转过去（PeerSource）；
  · 手机、客户端对这些会话的操作整条 HTTP 请求转给对方执行（forward），会话 key / 来源 id 在出入口换算；
  · 只转各自「自己的」来源，两台互加不会绕圈；
  · 绑在其中一台上的手机经 /api/computers 拿到另一台的地址、证书和替它登记的令牌，哪台在线连哪台；
  · 电脑之间只走用户自己的网络，不经 Kiteline 的中继。
防撞验证码：电脑来互联一律要本机点「允许」；从公网地址来的手机配对也要点；同一个验证码输错 5 次作废（devices.Pairing）。
"""

import base64
import hashlib
import http.client
import ipaddress
import json
import os
import socket
import ssl
import threading
import time
import urllib.parse
import uuid

from . import config, log, tls

PREFIX = "kl:"
OWNED_BY_PEER = {"skills", "todos", "groups"}   # 那台电脑自己管它的 watcher：这些不转过去
LOCAL_PATHS = {"/api/pin", "/api/mark", "/api/mute", "/api/viewed", "/api/quiet", "/api/share", "/api/share/stop", "/api/inbox",
               "/api/state", "/api/events", "/api/computers", "/api/computers/enroll"}
LOCAL_PREFIXES = ("/api/todos", "/api/favorites", "/api/groups", "/api/peer/", "/api/devices", "/api/push", "/api/live", "/api/desktop")
KEY_FIELDS = ("key", "k", "source", "sourceId", "sessionKey")
# 加电脑时连不上：多半是对方的防火墙拦着（Windows 第一次运行时关掉了系统的提示框）
FIREWALL_HINT = "。请确认那台电脑上 Kiteline 正在运行；若那台电脑开着防火墙，在它的「就绪检查」里点「防火墙放行 → 一键放行」"


def is_private(ip):
    """局域网 / 本机 / Tailscale 这类内网地址（不是从公网来的）"""
    host = (ip or "").split("%")[0]
    if host.lower().startswith("::ffff:"):
        host = host[7:]
    try:
        addr = ipaddress.ip_address(host)
    except ValueError:
        return False
    if addr.is_private or addr.is_loopback or addr.is_link_local:
        return True
    return addr.version == 4 and addr in ipaddress.ip_network("100.64.0.0/10")


def self_id():
    file = config.path("computer-id")
    try:
        with open(file, encoding="utf-8") as fh:
            value = fh.read().strip()
            if value:
                return value
    except OSError:
        pass
    value = str(uuid.uuid4())
    config.write_private(file, value)
    return value


def source_id(peer_id, src):
    return "%s%s:%s" % (PREFIX, peer_id[:8], src)


def normalize(raw):
    """「192.168.1.20」「pc.local:8766」→ https://主机:端口（默认 8766）"""
    text = (raw or "").strip()
    if not text:
        return None
    if text.startswith("http://"):
        text = "https://" + text[7:]
    if not text.startswith("https://"):
        text = "https://" + text
    parts = urllib.parse.urlsplit(text.rstrip("/"))
    if not parts.hostname:
        return None
    host = parts.hostname
    if ":" in host:
        host = "[%s]" % host
    return "https://%s:%d" % (host, parts.port or 8766)


def describe(exc):
    if isinstance(exc, socket.timeout):
        return "连接超时"
    if isinstance(exc, ConnectionRefusedError):
        return "对方拒绝连接（Kiteline 没开，或端口不对）"
    if isinstance(exc, socket.gaierror):
        return "找不到这个地址"
    if isinstance(exc, ssl.SSLError):
        return "对方电脑的证书不对（可能不是原来那台电脑）"
    return str(exc) or exc.__class__.__name__


class PeerSource:
    """对方电脑上的一个来源（同 Mac 版 KitelineSource）：接口和 watcher.LocalSource 一样"""

    def __init__(self, source_config, on_event, on_state, peers):
        self.config = source_config
        self.id = source_config["id"]
        self.kind = "kiteline"
        self.peers = peers
        self.name = source_config.get("name") or peers.default_name(source_config)
        self._on_event = on_event
        self._on_state = on_state
        self.state = "stopped"
        self.state_detail = ""
        self.host = None
        self.platform = None
        self.features = set()
        self.watcher_version = None
        self.session_count = 0
        self.home = None
        self._stopped = True
        self._generation = 0
        self._conn = None
        self._attempt = 0

    @property
    def live(self):
        return self.state == "live"

    def short_label(self):
        if self.state == "live":
            return "%s 在线 · %d 会话" % (self.host or "来源", self.session_count)
        if self.state == "connecting":
            return "连接中"
        if self.state == "failed":
            return "连接失败：%s" % self.state_detail
        return "未连接"

    def start(self):
        self._stopped = False
        self._attempt = 0
        self._generation += 1
        threading.Thread(target=self._run, args=(self._generation,), daemon=True).start()

    def stop(self):
        self._stopped = True
        self._generation += 1
        conn, self._conn = self._conn, None
        if conn:
            try:
                conn.close()
            except OSError:
                pass
        self._set_state("stopped")

    def restart(self, source_config=None):
        if source_config is not None:
            self.config = source_config

    def _run(self, generation):
        while not self._stopped and generation == self._generation:
            peer = self.peers.get(self.config.get("peerId"))
            if not peer:
                self._set_state("failed", "这台电脑已移除")
                return
            if self.state != "live":
                self._set_state("connecting")
            why = None
            if self.peers.refresh(peer["id"]):
                peer = self.peers.get(peer["id"]) or peer
                try:
                    self._stream(peer, generation)
                    why = "连接已断开"
                except Exception as exc:  # noqa: BLE001
                    why = describe(exc)
            else:
                why = self.peers.problems.get(peer["id"]) or "连不上「%s」" % peer.get("name")
            if self._stopped or generation != self._generation:
                return
            self._attempt += 1
            self._set_state("failed", why)
            time.sleep(min(30, 2 ** min(self._attempt, 5)))

    def _stream(self, peer, generation):
        conn, path = self.peers.open(peer, "GET", "/api/peer/watch", {"src": self.config.get("peerSource") or ""}, timeout=50)
        self._conn = conn
        response = conn.getresponse()
        if response.status != 200:
            raise RuntimeError("对方电脑已移除这台电脑，请重新添加" if response.status in (401, 403) else "对方电脑返回 %d" % response.status)
        while not self._stopped and generation == self._generation:
            line = response.readline()
            if not line:
                return
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line.decode("utf-8", "replace"))
            except ValueError:
                continue
            if isinstance(event, dict) and "event" in event:
                self._handle(event)

    def _handle(self, event):
        kind = event["event"]
        peer = self.peers.get(self.config.get("peerId")) or {}
        peer_name = peer.get("name") or "Kiteline 电脑"
        if kind == "peer_link":
            if not event.get("live"):
                reason = event.get("reason")
                self._set_state("failed", "对方电脑上未连接" + ("：%s" % reason if reason else ""))
                self._on_event(self, {"event": "snapshots", "sessions": []})
            return
        if kind == "heartbeat":
            return
        if kind == "hello":
            self._attempt = 0
            self.home = event.get("home") or self.home
            self.platform = event.get("platform") or self.platform
            self.watcher_version = event.get("watcher")
            host = event.get("host") or ""
            same = not host or host == peer_name or peer_name.startswith(host.replace(".local", ""))
            self.host = peer_name if same else "%s · %s" % (peer_name, host)   # 主机名多半就是电脑名：一样就只写一遍
            self._set_state("live")
            log.write("已连上 Kiteline 电脑「%s」的来源 %s" % (peer_name, self.config.get("peerSource")))
        if kind == "snapshots":
            self.session_count = len(event.get("sessions") or [])
            if self.state != "live":
                self.host = self.host or peer_name
                self._set_state("live")   # 没等到 hello 也算连上了
        try:
            self._on_event(self, event)
        except Exception as exc:  # noqa: BLE001
            log.write("处理对方电脑事件 %s 出错：%r" % (kind, exc))

    def _set_state(self, state, detail=""):
        if (self.state, self.state_detail) == (state, detail):
            return
        self.state, self.state_detail = state, detail
        try:
            self._on_state(self)
        except Exception as exc:  # noqa: BLE001
            log.write("来源状态回调出错：%r" % exc)

    def request(self, payload, timeout=30):
        from .watcher import RemoteError
        if payload.get("cmd") in OWNED_BY_PEER:
            return {"ok": True, "skipped": True}
        peer = self.peers.get(self.config.get("peerId"))
        if not peer:
            raise RemoteError("这台电脑已移除")
        status, _, body = self.peers.call(peer, "POST", "/api/peer/rpc", {"src": self.config.get("peerSource") or ""},
                                          json.dumps(payload).encode("utf-8"), {"X-Kiteline-Timeout": str(int(timeout))}, timeout + 10)
        try:
            reply = json.loads(body.decode("utf-8"))
        except ValueError:
            reply = {}
        if reply.get("ok") and isinstance(reply.get("response"), dict):
            result = reply["response"]
            if not result.get("ok"):
                raise RemoteError(result.get("error") or "watcher 返回失败")
            return result
        raise RemoteError(reply.get("error") or "对方电脑返回 %d" % status)


class Peers:
    def __init__(self, app):
        self.app = app
        self._lock = threading.RLock()
        self._file = config.path("peers.json")
        data = config.read_json(self._file, [])
        self._peers = data if isinstance(data, list) else []
        self.problems = {}               # 对方电脑 id → 连不上的原因（在线的没有）
        self._subscribers = {}           # id(stream) → (stream, 来源 id, 对方电脑 id)
        self._cache = {}                 # (来源 id, hello / snapshots / link) → 那一行
        self.on_change = None
        self.id = self_id()

    # MARK: 列表

    @property
    def all(self):
        with self._lock:
            return [dict(p) for p in self._peers]

    def get(self, peer_id):
        with self._lock:
            for peer in self._peers:
                if peer["id"] == peer_id:
                    return dict(peer)
        return None

    def _mutate(self, peer_id, fn):
        with self._lock:
            for peer in self._peers:
                if peer["id"] == peer_id:
                    fn(peer)
            self._save()

    def _save(self):
        with self._lock:
            text = json.dumps(self._peers, ensure_ascii=False, indent=2)
        config.write_private(self._file, text)

    def default_name(self, entry):
        peer = self.get(entry.get("peerId")) or {}
        name = peer.get("name") or "Kiteline 电脑"
        for info in peer.get("sources") or []:
            if info.get("id") == entry.get("peerSource") and info.get("kind") != "local":
                return "%s · %s" % (name, info.get("name"))
        return name

    @staticmethod
    def source_configs(peer):
        return [{"id": source_id(peer["id"], info["id"]), "kind": "kiteline", "peerId": peer["id"], "peerSource": info["id"],
                 "enabled": True} for info in peer.get("sources") or []]

    def start(self):
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        self.sync_sources()
        beat = 0
        while True:
            if beat % 2 == 0:
                for peer in self.all:
                    threading.Thread(target=self.refresh, args=(peer["id"],), daemon=True).start()
            self._heartbeat()
            beat += 1
            time.sleep(15)

    def _changed(self):
        if self.on_change:
            try:
                self.on_change()
            except Exception:  # noqa: BLE001
                pass

    def refresh(self, peer_id):
        """问对方有哪些来源（顺带挑出能连的地址）；来源有变就同步本机的来源列表。返回连没连上"""
        peer = self.get(peer_id)
        if not peer:
            return False
        try:
            status, _, body = self.call(peer, "GET", "/api/peer/hello", timeout=8)
        except Exception as exc:  # noqa: BLE001
            self.problems[peer_id] = describe(exc)
            self._changed()
            return False
        if status != 200:
            self.problems[peer_id] = "对方电脑已移除这台电脑，请重新添加" if status in (401, 403) else "对方电脑返回 %d" % status
            self._changed()
            return False
        try:
            info = json.loads(body.decode("utf-8"))
        except ValueError:
            info = {}
        sources = [{"id": s["id"], "name": s.get("name") or s["id"], "kind": s.get("kind") or "ssh", "live": s.get("live")}
                   for s in info.get("sources") or [] if isinstance(s, dict) and s.get("id")]
        changed = []

        def update(p):
            old = [(s["id"], s["name"]) for s in p.get("sources") or []]
            if old != [(s["id"], s["name"]) for s in sources] or p.get("name") != (info.get("name") or p.get("name")):
                changed.append(True)
            p["sources"] = sources
            p["name"] = info.get("name") or p.get("name")
            for address in info.get("addresses") or []:
                if address.startswith("https://") and address not in p["addresses"]:
                    p["addresses"].append(address)
        self._mutate(peer_id, update)
        self.problems.pop(peer_id, None)
        if changed:
            self.sync_sources()
        self._changed()
        return True

    def sync_sources(self):
        desired = [entry for peer in self.all for entry in self.source_configs(peer)]
        self.app.apply_peer_sources(desired)

    # MARK: 自己的身份

    def self_name(self):
        return self.app.host or "电脑"

    def self_addresses(self):
        m = self.app.cfg.mobile
        if not m.get("enabled", True) or not m.get("httpsEnabled", True):
            return []
        return [a["base"] for a in self.app.pairing_addresses() if a["base"].startswith("https://") and "127.0.0.1" not in a["base"]]

    @staticmethod
    def self_ca():
        der = tls.ca_der()
        return base64.b64encode(der).decode("ascii") if der else ""

    # MARK: 连对方电脑

    @staticmethod
    def _context(peer):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False   # 经公网 IP、域名、端口转发连过去时证书上没有那个名字；只认对方的根证书
        ca = peer.get("ca")
        if ca:
            context.verify_mode = ssl.CERT_REQUIRED
            context.load_verify_locations(cadata=base64.b64decode(ca))
        else:
            context.verify_mode = ssl.CERT_NONE
        return context

    def open(self, peer, method, path, query=None, body=None, headers=None, timeout=20, base=None):
        parts = urllib.parse.urlsplit(base or peer["addresses"][0])
        conn = http.client.HTTPSConnection(parts.hostname, parts.port or 8766, timeout=timeout, context=self._context(peer))
        target = path + ("?" + urllib.parse.urlencode(query) if query else "")
        all_headers = {"X-CCP-Token": peer.get("token") or "", "X-Kiteline-Client": "kiteline-desktop/%s" % self.app.version}
        if body is not None:
            all_headers["Content-Type"] = "application/json"
        all_headers.update(headers or {})
        conn.request(method, target, body=body, headers=all_headers)
        return conn, target

    def call(self, peer, method, path, query=None, body=None, headers=None, timeout=20):
        """一问一答：按地址顺序试，连上的排到最前。返回 (状态码, 响应头, 内容)；都连不上抛最后一个错"""
        last = None
        for index, base in enumerate(list(peer.get("addresses") or [])):
            try:
                conn, _ = self.open(peer, method, path, query, body, headers, timeout if index == 0 else min(timeout, 8), base)
                try:
                    response = conn.getresponse()
                    data = response.read()
                    result = (response.status, {k.lower(): v for k, v in response.getheaders()}, data)
                finally:
                    conn.close()
            except Exception as exc:  # noqa: BLE001
                last = exc
                continue
            if index > 0:
                self._mutate(peer["id"], lambda p, b=base: p.update(addresses=[b] + [a for a in p["addresses"] if a != b]))
            return result
        raise last or OSError("没有可用的地址")

    # MARK: 添加（本机是发起的那台）

    def add(self, address, code, fingerprint=None):
        """输地址 + 对方「手机访问」页上的 6 位验证码添加；返回 (对方电脑, None) 或 (None, 原因)。要等对方点允许，最多约 90 秒"""
        base = normalize(address)
        if not base:
            return None, "地址格式不对，请填 IP 或域名，例如 192.168.1.20"
        digits = "".join(ch for ch in str(code or "") if ch.isdigit())
        if len(digits) != 6:
            return None, "请输入对方电脑上显示的 6 位验证码"
        my_ca = self.self_ca()
        if not my_ca:
            return None, "本机证书尚未就绪，请确认「手机访问」已开启"
        devices = self.app.devices
        device, token_for_peer = devices.register("Kiteline", urllib.parse.urlsplit(base).hostname or "", "电脑互联", "Kiteline 电脑")
        devices.set_peer(device["id"], "computer", None, None)
        payload = {"code": digits, "name": self.self_name(),
                   "computer": {"id": self.id, "name": self.self_name(), "addresses": self.self_addresses(), "ca": my_ca,
                                "token": token_for_peer, "port": self.app.cfg.https_port()}}
        probe = {"id": "", "addresses": [base], "token": ""}
        log.write("添加 Kiteline 电脑：向 %s 请求互联，等待对方电脑上确认" % base)

        def fail(why):
            devices.revoke(device["id"])
            log.write("添加 Kiteline 电脑失败（%s）：%s" % (base, why))
            return None, why
        try:
            conn, _ = self.open(probe, "POST", "/pair", body=json.dumps(payload).encode("utf-8"), timeout=90, base=base)
            try:
                response = conn.getresponse()
                status, raw = response.status, response.read()
            finally:
                conn.close()
        except Exception as exc:  # noqa: BLE001
            why = describe(exc)
            if isinstance(exc, (socket.timeout, ConnectionRefusedError)):
                why += FIREWALL_HINT
            return fail(why)
        try:
            reply = json.loads(raw.decode("utf-8"))
        except ValueError:
            reply = {}
        if status != 200 or not reply.get("token"):
            return fail(reply.get("error") or "对方电脑返回 %d" % status)
        info = reply.get("computer") or {}
        peer_id = info.get("id")
        if not peer_id:
            return fail("对方的 Kiteline 版本过旧，不支持电脑互联，请先在那台电脑上更新 Kiteline")
        if peer_id == self.id:
            return fail("不能添加本机")
        ca = info.get("ca") or ""
        try:
            der = base64.b64decode(ca)
        except ValueError:
            der = b""
        if not der:
            return fail("对方电脑没有给出证书")
        if fingerprint and hashlib.sha256(der).hexdigest() != fingerprint.lower():
            return fail("对方电脑的证书指纹与局域网中宣告的不一致，已中止")
        name = (info.get("name") or "Kiteline 电脑")[:60]
        addresses = [base] + [a for a in info.get("addresses") or [] if a.startswith("https://") and a != base]
        peer = {"id": peer_id, "name": name, "addresses": addresses, "token": reply["token"], "ca": ca, "deviceId": device["id"],
                "addedAt": time.time() * 1000, "sources": [], "enrolled": {}}
        # 对方报的根证书要真能验过这条连接（中间有人冒充的话验不过）
        try:
            status, _, _ = self.call(dict(peer, addresses=[base]), "GET", "/api/peer/hello", timeout=10)
        except Exception as exc:  # noqa: BLE001
            return fail("对方电脑的证书与连接不符，已中止（%s）" % describe(exc))
        if status != 200:
            return fail("对方电脑返回 %d" % status)
        devices.rename(device["id"], name)
        devices.set_peer(device["id"], "computer", peer_id, None)
        self._store(peer, keep_device=device["id"])
        log.write("已添加 Kiteline 电脑「%s」（%s）" % (name, base))
        threading.Thread(target=self.refresh, args=(peer_id,), daemon=True).start()
        return peer, None

    def _store(self, peer, keep_device=None):
        with self._lock:
            old = next((p for p in self._peers if p["id"] == peer["id"]), None)
            self._peers = [p for p in self._peers if p["id"] != peer["id"]] + [peer]
            self._save()
        if old and old.get("deviceId") and old.get("deviceId") != keep_device:
            self.app.devices.revoke(old["deviceId"])
        self.sync_sources()
        self._changed()

    def remove(self, peer_id, notify=True):
        """移除对方电脑：告诉对方一声，作废互相给的令牌、替手机登记的设备，删掉它的来源"""
        peer = self.get(peer_id)
        if not peer:
            return False
        if notify:
            try:
                self.call(peer, "POST", "/api/peer/unlink", body=b"{}", timeout=6)
            except Exception:  # noqa: BLE001
                pass
        with self._lock:
            self._peers = [p for p in self._peers if p["id"] != peer_id]
            self._save()
            theirs = [s for s, _, pid in self._subscribers.values() if pid == peer_id]
        for stream in theirs:
            stream.close()
        if peer.get("deviceId"):
            self.app.server.revoke_device(peer["deviceId"])
        for device in self.app.devices.all:
            if device.get("peer") == peer_id and device.get("kind") != "computer":
                self.app.server.revoke_device(device["id"])
        self.problems.pop(peer_id, None)
        self.sync_sources()
        self._changed()
        log.write("已移除 Kiteline 电脑「%s」" % peer.get("name"))
        return True

    def device_revoked(self, device):
        """设备页里停用了：是电脑 → 互联一起解除；是手机 → 替它在别的电脑上的登记也作废"""
        if device.get("kind") == "computer":
            for peer in self.all:
                if peer.get("deviceId") == device["id"]:
                    threading.Thread(target=self.remove, args=(peer["id"],), daemon=True).start()
            return
        for peer in self.all:
            if device["id"] in (peer.get("enrolled") or {}):
                self._mutate(peer["id"], lambda p: (p.get("enrolled") or {}).pop(device["id"], None))
                threading.Thread(target=self._quiet_call, args=(peer, "POST", "/api/peer/enroll/revoke",
                                                                json.dumps({"phone": device["id"]}).encode("utf-8")), daemon=True).start()

    def _quiet_call(self, peer, method, path, body=None):
        try:
            self.call(peer, method, path, body=body, timeout=8)
        except Exception:  # noqa: BLE001
            pass

    # MARK: 被添加（本机是对方连过来的那台）

    def accept_pairing(self, request, info):
        from .httpd import Response
        peer_id = str(info.get("id") or "")
        if not peer_id or peer_id == self.id:
            return Response.error("不能添加本机", 400)
        name = str(info.get("name") or "Kiteline 电脑")[:60]
        devices = self.app.devices
        for device in devices.all:
            if device.get("kind") == "computer" and device.get("peer") == peer_id:
                self.app.server.revoke_device(device["id"])
        device, token = devices.register(request.headers.get("user-agent", "Kiteline"), request.remote, "电脑互联", name)
        devices.set_peer(device["id"], "computer", peer_id, None)
        their_token, ca = info.get("token"), info.get("ca")
        if their_token and ca:
            addresses = [a for a in info.get("addresses") or [] if str(a).startswith("https://")]
            port = info.get("port")
            if port and not request.remote.startswith("127."):
                host = "[%s]" % request.remote if ":" in request.remote else request.remote
                seen = "https://%s:%d" % (host, int(port))
                if seen not in addresses:
                    addresses.append(seen)
            peer = {"id": peer_id, "name": name, "addresses": addresses, "token": their_token, "ca": ca, "deviceId": device["id"],
                    "addedAt": time.time() * 1000, "sources": [], "enrolled": {}}
            threading.Thread(target=lambda: (self._store(peer, keep_device=device["id"]), self.refresh(peer_id)), daemon=True).start()
        log.write("Kiteline 电脑「%s」（%s）已添加这台电脑" % (name, request.remote))
        return Response.json({"ok": True, "token": token, "deviceId": device["id"],
                              "computer": {"id": self.id, "name": self.self_name(), "addresses": self.self_addresses(), "ca": self.self_ca()}})

    def local_sources(self):
        items = []
        for entry in self.app.cfg.sources:
            if entry.get("kind") == "kiteline" or not entry.get("enabled", True):
                continue
            source = self.app.store.source(entry["id"])
            items.append({"id": entry["id"], "name": entry.get("name") or entry.get("sshHost") or "本机",
                          "kind": entry.get("kind") or "local", "live": bool(source and source.live)})
        return items

    def handle(self, request, device):
        """/api/peer/*：只给互联的电脑（kind = computer 的设备）用。返回 Response / StreamReply"""
        from .httpd import Response, StreamReply
        if not device or device.get("kind") != "computer" or not device.get("peer"):
            return Response.error("只有互联的 Kiteline 电脑能用", 403)
        peer_id = device["peer"]
        method, path, body = request.method, request.path, request.json or {}
        if (method, path) == ("GET", "/api/peer/hello"):
            return Response.json({"id": self.id, "name": self.self_name(), "version": self.app.version,
                                  "addresses": self.self_addresses(), "sources": self.local_sources()})
        if (method, path) == ("GET", "/api/peer/watch"):
            src = request.query.get("src", "")
            if not any(s["id"] == src for s in self.local_sources()):
                return Response.error("没有这个来源", 404)
            return StreamReply({"Content-Type": "application/x-ndjson; charset=utf-8", "X-Accel-Buffering": "no"},
                               lambda stream: self._subscribe(stream, src, peer_id))
        if (method, path) == ("POST", "/api/peer/rpc"):
            source = self.app.store.source(request.query.get("src", ""))
            if source is None or source.kind == "kiteline" or not isinstance(request.json, dict):
                return Response.error("没有这个来源", 404)
            try:
                timeout = min(300, max(2, float(request.headers.get("x-kiteline-timeout") or 30)))
            except ValueError:
                timeout = 30
            try:
                return Response.json({"ok": True, "response": source.request(request.json, timeout)})
            except Exception as exc:  # noqa: BLE001
                return Response.json({"ok": False, "error": str(exc)}, 502)
        if (method, path) == ("POST", "/api/peer/enroll"):
            phone = str(body.get("phone") or "")
            if not phone:
                return Response.error("缺少手机", 400)
            ref = "%s:%s" % (peer_id, phone)
            for old in self.app.devices.all:
                if old.get("ref") == ref:
                    self.app.server.revoke_device(old["id"])
            enrolled, token = self.app.devices.register(str(body.get("agent") or ""), request.remote,
                                                        "经电脑「%s」" % device["name"], str(body.get("name") or "手机"))
            self.app.devices.set_peer(enrolled["id"], None, peer_id, ref)
            return Response.json({"ok": True, "token": token, "deviceId": enrolled["id"], "id": self.id, "name": self.self_name(),
                                  "addresses": self.self_addresses(), "ca": self.self_ca()})
        if (method, path) == ("POST", "/api/peer/enroll/revoke"):
            ref = "%s:%s" % (peer_id, body.get("phone") or "")
            for old in self.app.devices.all:
                if old.get("ref") == ref:
                    self.app.server.revoke_device(old["id"])
            return Response.json({"ok": True})
        if (method, path) == ("POST", "/api/peer/unlink"):
            if self.get(peer_id):
                threading.Thread(target=self.remove, args=(peer_id, False), daemon=True).start()
            else:
                self.app.server.revoke_device(device["id"])
            return Response.json({"ok": True})
        return Response.error("接口不存在", 404)

    def _subscribe(self, stream, src, peer_id):
        key = id(stream)
        with self._lock:
            self._subscribers[key] = (stream, src, peer_id)
            replay = [self._cache.get((src, k)) for k in ("link", "hello", "snapshots")]

        def closed():
            with self._lock:
                self._subscribers.pop(key, None)
        stream.on_close = closed
        for line in replay:
            if line:
                stream.send(line)
        log.write("Kiteline 电脑（%s）开始接收来源 %s 的会话" % (stream.remote, src))

    def tap_event(self, source, event):
        """本机来源的 watcher 事件照抄给连着的对方电脑"""
        if source.kind == "kiteline" or event.get("event") == "response":
            return
        kind = event.get("event")
        with self._lock:
            targets = [s for s, src, _ in self._subscribers.values() if src == source.id]
        if not targets and kind not in ("hello", "snapshots"):
            return
        line = json.dumps(event, ensure_ascii=False) + "\n"
        with self._lock:
            if kind in ("hello", "snapshots"):
                self._cache[(source.id, kind)] = line
        for stream in targets:
            stream.send(line)

    def tap_state(self, source):
        if source.kind == "kiteline":
            return
        event = {"event": "peer_link", "live": source.live}
        if source.state == "failed":
            event["reason"] = source.state_detail
        line = json.dumps(event, ensure_ascii=False) + "\n"
        with self._lock:
            self._cache[(source.id, "link")] = line
            if source.state in ("failed", "stopped"):   # 「连接中」时别清：新进程的 hello 可能已经先到了
                self._cache.pop((source.id, "hello"), None)
                self._cache.pop((source.id, "snapshots"), None)
            targets = [s for s, src, _ in self._subscribers.values() if src == source.id]
        for stream in targets:
            stream.send(line)

    def _heartbeat(self):
        with self._lock:
            streams = [s for s, _, _ in self._subscribers.values()]
        for stream in streams:
            stream.send('{"event":"heartbeat"}\n')

    def is_streaming(self, peer_id):
        with self._lock:
            return any(pid == peer_id for _, _, pid in self._subscribers.values())

    def push_suppressed(self):
        """别的电脑替它的手机在本机登记的：那台电脑连着本机时由它转推，本机不推（免得手机收两条）"""
        return {d["id"] for d in self.app.devices.all if d.get("kind") != "computer" and d.get("peer") and self.is_streaming(d["peer"])}

    # MARK: 手机：另一台电脑的地址和令牌

    def computers_payload(self):
        return {"self": self.id, "computers": [
            {"id": p["id"], "name": p.get("name"), "addresses": p.get("addresses") or [], "online": p["id"] not in self.problems,
             "fp": hashlib.sha256(base64.b64decode(p["ca"])).hexdigest() if p.get("ca") else ""} for p in self.all]}

    def enroll(self, phone, computer_id):
        from .httpd import Response
        peer = self.get(computer_id)
        if not peer:
            return Response.error("没有这台电脑", 404)
        body = json.dumps({"phone": phone["id"], "name": phone.get("name"), "agent": phone.get("agent", "")}).encode("utf-8")
        try:
            status, _, raw = self.call(peer, "POST", "/api/peer/enroll", body=body, timeout=10)
        except Exception as exc:  # noqa: BLE001
            return Response.error("连不上电脑「%s」：%s" % (peer.get("name"), describe(exc)), 502)
        try:
            reply = json.loads(raw.decode("utf-8"))
        except ValueError:
            reply = {}
        if status != 200 or not reply.get("token"):
            return Response.error(reply.get("error") or "对方电脑返回 %d" % status, 502)
        if reply.get("deviceId"):
            self._mutate(computer_id, lambda p: p.setdefault("enrolled", {}).update({phone["id"]: reply["deviceId"]}))
        addresses = list(peer.get("addresses") or [])
        for address in reply.get("addresses") or []:
            if address.startswith("https://") and address not in addresses:
                addresses.append(address)
        log.write("已替「%s」在 Kiteline 电脑「%s」上登记" % (phone.get("name"), peer.get("name")))
        return Response.json({"ok": True, "id": peer["id"], "name": reply.get("name") or peer.get("name"), "addresses": addresses,
                              "ca": reply.get("ca") or peer.get("ca") or "", "token": reply["token"]})

    # MARK: 转发

    def forward_target(self, request):
        path = request.path
        if not path.startswith("/api/") or path in LOCAL_PATHS or path.startswith(LOCAL_PREFIXES):
            return None
        values = [request.query.get(f) for f in KEY_FIELDS]
        body = request.json if isinstance(request.json, dict) else {}
        values += [body.get(f) for f in KEY_FIELDS]
        values = [v for v in values if isinstance(v, str) and v.startswith(PREFIX)]
        if not values:
            return None
        sources = [s for s in self.app.cfg.sources if s.get("kind") == "kiteline"]
        for value in values:
            for entry in sources:
                if value == entry["id"] or value.startswith(entry["id"] + "#"):
                    return entry
        return None

    def forward(self, request, entry):
        from .httpd import Response
        peer = self.get(entry.get("peerId"))
        remote = entry.get("peerSource")
        if not peer or not remote:
            return Response.error("这台电脑已移除", 410)
        local = entry["id"]

        def inward(value):
            if value == local:
                return remote
            if isinstance(value, str) and value.startswith(local + "#"):
                return remote + value[len(local):]
            return value
        query = {k: v for k, v in request.query.items() if k != "t"}
        for field in KEY_FIELDS:
            if field in query:
                query[field] = inward(query[field])
        body = request.body
        if isinstance(request.json, dict):
            data = dict(request.json)
            for field in KEY_FIELDS:
                if isinstance(data.get(field), str):
                    data[field] = inward(data[field])
            if isinstance(data.get("keys"), list):
                data["keys"] = [inward(k) for k in data["keys"]]
            body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        headers = {name: request.headers[name] for name in ("content-type", "x-kiteline-lang", "x-kiteline-client") if request.headers.get(name)}
        try:
            status, reply_headers, data = self.call(peer, request.method, request.path, query, None if request.method == "GET" else body,
                                                    headers, 180)
        except Exception as exc:  # noqa: BLE001
            return Response.error("连不上电脑「%s」：%s" % (peer.get("name"), describe(exc)), 502)
        prefix = "%s%s:" % (PREFIX, peer["id"][:8])
        remote_ids = {s["id"] for s in peer.get("sources") or []}
        kind = reply_headers.get("content-type", "")
        if "json" in kind:
            if reply_headers.get("content-encoding") == "gzip":
                import gzip
                data = gzip.decompress(data)
            try:
                data = json.dumps(outward(json.loads(data.decode("utf-8")), prefix, remote_ids), ensure_ascii=False).encode("utf-8")
            except ValueError:
                pass
        headers = {"Content-Type": kind or "application/octet-stream"}
        for name in ("content-disposition", "cache-control", "etag", "last-modified"):
            if reply_headers.get(name):
                headers[name.title().replace("Etag", "ETag")] = reply_headers[name]
        return Response(status, headers, data)

    def deliver(self, path, record, body):
        """本机发起的投递（会话群、定时任务……）落到对方电脑的会话上：交给那台执行。返回 (ok, submitted, message)"""
        entry = next((s for s in self.app.cfg.sources if s.get("id") == record.source_id), None)
        peer = self.get(entry.get("peerId")) if entry else None
        if not peer or not entry.get("peerSource"):
            return False, False, "这台电脑已移除"
        key = "%s#%s" % (entry["peerSource"], record.snap.get("sessionId"))
        try:
            status, _, raw = self.call(peer, "POST", path, {"key": key}, json.dumps(body, ensure_ascii=False).encode("utf-8"), None, 120)
        except Exception as exc:  # noqa: BLE001
            return False, False, "连不上电脑「%s」：%s" % (peer.get("name"), describe(exc))
        try:
            reply = json.loads(raw.decode("utf-8"))
        except ValueError:
            reply = {}
        return bool(reply.get("ok", status == 200)), bool(reply.get("submitted")), reply.get("message") or reply.get("error") or ""

    def note_viewed(self, keys):
        by_peer = {}
        for key in keys or []:
            if not isinstance(key, str) or not key.startswith(PREFIX) or "#" not in key:
                continue
            head, rest = key.split("#", 1)
            entry = next((s for s in self.app.cfg.sources if s.get("id") == head), None)
            if entry and entry.get("peerId"):
                by_peer.setdefault(entry["peerId"], []).append("%s#%s" % (entry["peerSource"], rest))
        for peer_id, items in by_peer.items():
            peer = self.get(peer_id)
            if peer:
                threading.Thread(target=self._quiet_call, args=(peer, "POST", "/api/viewed",
                                                                json.dumps({"keys": items}).encode("utf-8")), daemon=True).start()


def outward(value, prefix, remote_ids):
    """对方回的 JSON 里的会话 key、来源 id 换回本机的写法"""
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            if (key in KEY_FIELDS or key in ("from", "to")) and isinstance(item, str):
                out[key] = prefix + item if item.split("#", 1)[0] in remote_ids else item
            else:
                out[key] = outward(item, prefix, remote_ids)
        return out
    if isinstance(value, list):
        return [outward(v, prefix, remote_ids) for v in value]
    return value
