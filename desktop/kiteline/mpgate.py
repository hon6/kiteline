"""微信小程序的入口：加密隧道（局域网 WebSocket 端口；远程经中继，见 relay_link）。

小程序连不了电脑的自签 HTTPS，跑不了点对点库，所以单开一条路：
  握手（双方临时 X25519 + 长期密钥三次 DH → HKDF 出两个方向的 ChaCha20-Poly1305 密钥），
  之后小程序发来的每个请求原样交给 MobileServer.route（和 HTTPS 进来的走同一套鉴权、同一套接口），回复加密送回去。
协议和 miniprogram/lib/tunnel.js 一一对应，细节见 docs/features/miniprogram.md「加密隧道」。

设备令牌和小程序的长期公钥绑在一起（mp-bind.json）：经这里来的请求，令牌必须是这把公钥配对时拿到的。
"""

import base64
import hashlib
import json
import os
import socket
import struct
import threading
import time
import urllib.parse

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from . import config, log
from .httpd import Request, Response, StreamReply

PROTO = b"kiteline-mp-1"
DEFAULT_PORT = 8768
MAX_FRAME = 48 * 1024 * 1024
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
CLIENT_UA = "Kiteline-MiniProgram"
# 不需要设备令牌的路径：配对用
OPEN_PATHS = ("/pair", "/api/ping", "/api/info", "/api/devices/register")
# 远程（经中继）用小程序：远程访问一律要 Kiteline Pro，小程序还没有开通 Pro 的办法，先关着（.claude 记忆 relay-is-paid）。
# 测试经中继时设 CCPULSE_MP_REMOTE=1
REMOTE_REFUSED = "小程序目前只支持手机和电脑在同一个 Wi-Fi 下使用（远程访问属于 Kiteline Pro）"


def remote_allowed():
    return (os.environ.get("CCPULSE_MP_REMOTE") or os.environ.get("KITELINE_MP_REMOTE")) == "1"


def _b64(data):
    return base64.b64encode(data).decode("ascii")


def _unb64(text):
    text = (text or "").replace("-", "+").replace("_", "/")
    return base64.b64decode(text + "=" * (-len(text) % 4))


def host_id(pub):
    return base64.urlsafe_b64encode(hashlib.sha256(pub).digest()[:12]).decode("ascii").rstrip("=")


def _raw(pub_key):
    return pub_key.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def _dh(priv, pub_bytes):
    return priv.exchange(X25519PublicKey.from_public_bytes(pub_bytes))


def derive_keys(ce, he, cs, hs, eph_priv, static_priv):
    """电脑这边：返回 (发送密钥, 接收密钥)。和 tunnel.js 的 deriveKeys(false, …) 一样"""
    d1 = _dh(static_priv, ce)      # e_c · S_h
    d2 = _dh(eph_priv, cs)         # S_c · e_h
    d3 = _dh(eph_priv, ce)         # e_c · e_h
    salt = hashlib.sha256(PROTO + ce + he + cs + hs).digest()
    okm = HKDF(algorithm=hashes.SHA256(), length=64, salt=salt, info=PROTO + b" keys").derive(d1 + d2 + d3)
    return okm[32:], okm[:32]


def _nonce(counter):
    return b"\x00\x00\x00\x00" + struct.pack(">Q", counter)


def seal(key, counter, header, body=b""):
    head = json.dumps(header, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return ChaCha20Poly1305(key).encrypt(_nonce(counter), struct.pack(">I", len(head)) + head + bytes(body or b""), None)


def unseal(key, counter, data):
    plain = ChaCha20Poly1305(key).decrypt(_nonce(counter), bytes(data), None)
    (length,) = struct.unpack(">I", plain[:4])
    return json.loads(plain[4:4 + length].decode("utf-8")), plain[4 + length:]


class Keys:
    """电脑的长期密钥（mp.key）和设备令牌 ↔ 小程序公钥的绑定（mp-bind.json）"""

    def __init__(self):
        self._lock = threading.Lock()
        path = config.path("mp.key")
        raw = None
        try:
            with open(path, "rb") as fh:
                raw = fh.read()
        except OSError:
            pass
        if not raw or len(raw) != 32:
            raw = os.urandom(32)
            config.write_private(path, raw)
        self.private = X25519PrivateKey.from_private_bytes(raw)
        self.public = _raw(self.private.public_key())
        self.id = host_id(self.public)
        self._bind_path = config.path("mp-bind.json")
        self._bind = config.read_json(self._bind_path, {})

    @staticmethod
    def _hash(token):
        return hashlib.sha256(token.encode("utf-8")).hexdigest()

    def bound_key(self, token):
        with self._lock:
            return self._bind.get(self._hash(token))

    def bind(self, token, client_pub):
        with self._lock:
            self._bind[self._hash(token)] = client_pub.hex()
            config.write_private(self._bind_path, json.dumps(self._bind).encode("utf-8"))

    def prune(self, alive):
        """设备停用 / 删除后清掉绑定。alive(token_hash) → 还有效"""
        with self._lock:
            dead = [h for h in self._bind if not alive(h)]
            for h in dead:
                del self._bind[h]
            if dead:
                config.write_private(self._bind_path, json.dumps(self._bind).encode("utf-8"))


# ---------- WebSocket（RFC 6455，只做服务端用到的部分） ----------

class WSConn:
    def __init__(self, sock, client=False):
        self.sock = sock
        self.client = client          # 客户端（连中继时）发出的帧要加掩码
        self._wlock = threading.Lock()
        self.closed = False

    def handshake(self):
        """读 HTTP 升级请求。返回 (路径, 请求头) 或 None"""
        self.sock.settimeout(10)
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = self.sock.recv(4096)
            if not chunk or len(data) > 16384:
                return None
            data += chunk
        head = data.split(b"\r\n\r\n", 1)[0].decode("latin-1").split("\r\n")
        parts = head[0].split(" ")
        if len(parts) < 2 or parts[0] != "GET":
            return None
        headers = {}
        for line in head[1:]:
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        key = headers.get("sec-websocket-key")
        if not key or "websocket" not in headers.get("upgrade", "").lower():
            self.sock.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
            return None
        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        self.sock.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           "Sec-WebSocket-Accept: %s\r\n\r\n" % accept).encode())
        self.sock.settimeout(None)
        return parts[1], headers

    def _read(self, n):
        buf = bytearray()
        while len(buf) < n:
            chunk = self.sock.recv(min(65536, n - len(buf)))
            if not chunk:
                raise ConnectionError("closed")
            buf += chunk
        return bytes(buf)

    def recv(self):
        """返回 (是否文本, 数据)；对方关了返回 None。自动回 ping、拼接分片"""
        message, text = bytearray(), None
        while True:
            b1, b2 = self._read(2)
            fin, op = b1 & 0x80, b1 & 0x0F
            length = b2 & 0x7F
            if length == 126:
                (length,) = struct.unpack(">H", self._read(2))
            elif length == 127:
                (length,) = struct.unpack(">Q", self._read(8))
            if length > MAX_FRAME:
                raise ConnectionError("frame too large")
            mask = self._read(4) if b2 & 0x80 else None
            payload = bytearray(self._read(length))
            if mask:
                for i in range(length):
                    payload[i] ^= mask[i & 3]
            if op == 0x8:
                return None
            if op == 0x9:
                self._send_frame(0xA, bytes(payload))
                continue
            if op == 0xA:
                continue
            if op in (0x1, 0x2):
                text = op == 0x1
                message = payload
            elif op == 0x0:
                message += payload
            if fin:
                return text, bytes(message)

    def _send_frame(self, op, data):
        head = bytes([0x80 | op])
        n = len(data)
        bit = 0x80 if self.client else 0
        if n < 126:
            head += bytes([bit | n])
        elif n < 65536:
            head += bytes([bit | 126]) + struct.pack(">H", n)
        else:
            head += bytes([bit | 127]) + struct.pack(">Q", n)
        if self.client:
            mask = os.urandom(4)
            body = bytearray(data)
            for i in range(n):
                body[i] ^= mask[i & 3]
            head += mask
            data = bytes(body)
        with self._wlock:
            if self.closed:
                return
            try:
                self.sock.sendall(head + data)
            except OSError:
                self.close()

    def send_text(self, text):
        self._send_frame(0x1, text.encode("utf-8"))

    def send_binary(self, data):
        self._send_frame(0x2, data)

    def close(self):
        if self.closed:
            return
        self.closed = True
        try:
            self.sock.sendall(b"\x88\x00")
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


# ---------- 一条加密会话（局域网的一条 WebSocket，或中继转来的一个客户端） ----------

class _TunnelStream:
    """给 StreamReply.attach 用的流：接口和 httpd.Stream 一样，写进去的字节作为 data 帧送回小程序"""

    def __init__(self, session, rid, remote):
        self._session, self._id = session, rid
        self.remote = remote
        self.on_close = None
        self.closed = False

    def send(self, data):
        if self.closed:
            return
        if isinstance(data, str):
            data = data.encode("utf-8")
        if not self._session.post({"t": "data", "id": self._id}, data):
            self.close()

    def close(self):
        if self.closed:
            return
        self.closed = True
        self._session.streams.pop(self._id, None)
        self._session.post({"t": "end", "id": self._id})
        callback, self.on_close = self.on_close, None
        if callback:
            try:
                callback()
            except Exception as exc:  # noqa: BLE001
                log.write("小程序实时流关闭回调出错：%s" % exc)

    def wait(self):
        pass


class Session:
    """send_raw(bytes) 发一帧密文；remote 是记日志 / 鉴权用的来源地址（经中继时是 127.0.0.1，和 iPhone 走中继一样）"""

    def __init__(self, gate, send_raw, send_text, remote, via):
        self.gate, self._send_raw, self._send_text = gate, send_raw, send_text
        self.remote, self.via = remote, via
        self.keys = None
        self.client_pub = None
        self._send_counter = 0
        self._recv_counter = 0
        self._lock = threading.Lock()        # 发送：计数器 + 发帧
        self._recv_lock = threading.Lock()
        self.streams = {}
        self.closed = False

    def on_text(self, text):
        if self.keys:
            return
        try:
            hello = json.loads(text)
            ce, cs = _unb64(hello["e"]), _unb64(hello["s"])
            if hello.get("t") != "hello" or len(ce) != 32 or len(cs) != 32:
                raise ValueError
        except (ValueError, KeyError, TypeError):
            self._send_text(json.dumps({"t": "error", "msg": "握手无效"}))
            return False
        if self.via == "relay" and not remote_allowed():
            self._send_text(json.dumps({"t": "error", "msg": REMOTE_REFUSED}, ensure_ascii=False))
            return False
        if hello.get("v") != 1:
            self._send_text(json.dumps({"t": "error", "msg": "小程序版本过旧，请更新"}))
            return False
        keys = self.gate.keys
        eph = X25519PrivateKey.generate()
        he = _raw(eph.public_key())
        self.keys = derive_keys(ce, he, cs, keys.public, eph, keys.private)
        self.client_pub = cs
        self._send_text(json.dumps({"t": "hello", "v": 1, "e": _b64(he), "s": _b64(keys.public),
                                    "name": self.gate.host_name()}, ensure_ascii=False))
        return True

    def on_binary(self, data):
        if not self.keys:
            return False
        try:
            with self._recv_lock:
                counter = self._recv_counter
                self._recv_counter += 1
            header, body = unseal(self.keys[1], counter, data)
        except Exception:  # noqa: BLE001  解不开 = 对方没有握手时声称的那把私钥，或数据被改了
            log.write("小程序连接解密失败，断开（%s）" % self.remote)
            return False
        kind = header.get("t")
        if kind == "ping":
            self.post({"t": "pong"})
        elif kind == "req":
            threading.Thread(target=self._handle, args=(header, body), name="mp-req", daemon=True).start()
        elif kind == "cancel":
            stream = self.streams.pop(header.get("id"), None)
            if stream:
                stream.close()
        return True

    def post(self, header, body=b""):
        if self.closed or not self.keys:
            return False
        with self._lock:
            counter = self._send_counter
            self._send_counter += 1
            frame = seal(self.keys[0], counter, header, body)
            # 加密和发送要在同一把锁里：计数器的顺序必须和帧到达的顺序一致
            return self._send_raw(frame) is not False

    def _handle(self, header, body):
        rid = header.get("id")
        try:
            reply = self._route(header, body)
        except Exception as exc:  # noqa: BLE001
            log.write("小程序请求 %s 出错：%r" % (header.get("p"), exc))
            reply = Response.error("服务器内部错误：%s" % exc, 500)
        if isinstance(reply, StreamReply):
            stream = _TunnelStream(self, rid, self.remote)
            self.streams[rid] = stream
            self.post({"t": "res", "id": rid, "s": 200, "h": reply.headers, "stream": 1})
            reply.attach(stream)
            return
        self.post({"t": "res", "id": rid, "s": reply.status,
                   "h": {k: v for k, v in reply.headers.items() if k.lower() in ("content-type", "cache-control")}}, reply.body)

    def _route(self, header, body):
        path = str(header.get("p") or "/")
        query = header.get("q") or {}
        headers = {str(k).lower(): str(v) for k, v in (header.get("h") or {}).items()}
        # 来源由这里定：不许小程序自己冒充别的客户端
        headers["x-kiteline-client"] = "miniprogram"
        headers["x-kiteline-via"] = self.via
        if "user-agent" not in headers:
            headers["user-agent"] = CLIENT_UA
        tokens = [t for t in (headers.get("x-ccp-token"), query.get("t")) if t]
        for token in tokens:
            if path in OPEN_PATHS and token.startswith("p"):
                continue   # 扫码配对的一次性令牌：只能用来配对（MobileServer 自己会拦别的路径）
            bound = self.gate.keys.bound_key(token)
            if bound != self.client_pub.hex():
                # 主令牌、iPhone 的令牌、别的小程序的令牌都不认：只认这把公钥自己配对得到的
                return Response.error("未配对或令牌已失效", 401)
        if not tokens and path not in OPEN_PATHS:
            return Response.error("未配对或令牌已失效", 401)
        raw_path = path + ("?" + urllib.parse.urlencode(query) if query else "")
        request = Request(str(header.get("m") or "GET"), raw_path, headers, bytes(body), self.remote)
        reply = self.gate.route(request)
        # 配对成功：把拿到的设备令牌绑到这把公钥上
        if path in ("/pair", "/api/devices/register") and isinstance(reply, Response) and reply.status == 200:
            try:
                token = json.loads(reply.body.decode("utf-8")).get("token")
            except (ValueError, AttributeError):
                token = None
            if token:
                self.gate.keys.bind(token, self.client_pub)
                log.write("小程序配对成功（%s，%s）" % (self.via, self.remote))
        return reply

    def close(self):
        if self.closed:
            return
        self.closed = True
        for stream in list(self.streams.values()):
            stream.close()
        self.streams.clear()


class Gate:
    """route：MobileServer.route；host_name()：显示给小程序的电脑名字"""

    def __init__(self, route, host_name):
        self.route = route
        self.host_name = host_name
        self.keys = Keys()
        self._listener = None
        self.status = "未启动"

    # 局域网：小程序直连
    def start(self, host, port):
        family = socket.AF_INET6 if ":" in host else socket.AF_INET
        listener = socket.socket(family, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((host, port))
        listener.listen(32)
        self._listener = listener
        self.status = "监听中 %s:%d" % (host, port)
        threading.Thread(target=self._accept, args=(listener,), name="mp-accept", daemon=True).start()
        log.write("小程序入口监听 %s:%d（编号 %s）" % (host, port, self.keys.id))

    def stop(self):
        listener, self._listener = self._listener, None
        if listener:
            try:
                listener.close()
            except OSError:
                pass

    def _accept(self, listener):
        while self._listener is listener:
            try:
                sock, addr = listener.accept()
            except OSError:
                if self._listener is not listener:
                    return
                time.sleep(1)
                continue
            threading.Thread(target=self._serve, args=(sock, addr), name="mp-conn", daemon=True).start()

    def _serve(self, sock, addr):
        ws = WSConn(sock)
        remote = addr[0][7:] if addr[0].startswith("::ffff:") else addr[0]
        session = None
        try:
            if not ws.handshake():
                return
            session = Session(self, ws.send_binary, ws.send_text, remote, "lan")
            while True:
                message = ws.recv()
                if message is None:
                    break
                is_text, data = message
                ok = session.on_text(data.decode("utf-8", "replace")) if is_text else session.on_binary(data)
                if ok is False:
                    break
        except (OSError, ConnectionError, ValueError):
            pass
        finally:
            if session:
                session.close()
            ws.close()


# ---------- 远程：经中继（relay/push/mp.go） ----------

import hmac as _hmac
import socket as _socket
import ssl as _ssl

MP_OPEN, MP_TEXT, MP_BINARY, MP_CLOSE = 1, 2, 3, 4


class RelayLink:
    """电脑这头连中继：wss://<中继>/mp/h/<编号>。先回应身份挑战，之后中继转来的每个小程序连接是一条 Session（来源当作 127.0.0.1）"""

    def __init__(self, gate, relay_url):
        self.gate = gate
        u = urllib.parse.urlsplit(relay_url if "://" in relay_url else "https://" + relay_url)
        self.secure = u.scheme in ("https", "wss")
        self.host = u.hostname
        self.port = u.port or (443 if self.secure else 80)
        self.status = "未连接"
        self._stop = False
        self._ws = None

    def start(self):
        threading.Thread(target=self._loop, name="mp-relay", daemon=True).start()

    def stop(self):
        self._stop = True
        if self._ws:
            self._ws.close()

    def _loop(self):
        delay = 2
        while not self._stop:
            started = time.time()
            try:
                self._run()
            except Exception as exc:  # noqa: BLE001
                if not self._stop:
                    self.status = "未连接：%s" % exc
            if self._stop:
                return
            if time.time() - started > 60:
                delay = 2
            time.sleep(delay)
            delay = min(delay * 2, 60)

    def _connect(self):
        raw = _socket.create_connection((self.host, self.port), timeout=15)
        if self.secure:
            raw = _ssl.create_default_context().wrap_socket(raw, server_hostname=self.host)
        key = base64.b64encode(os.urandom(16)).decode()
        path = "/mp/h/" + self.gate.keys.id
        raw.sendall(("GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                     "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nUser-Agent: %s\r\n\r\n"
                     % (path, self.host, key, config.USER_AGENT)).encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = raw.recv(4096)
            if not chunk:
                raise ConnectionError("中继断开")
            head += chunk
        status = head.split(b"\r\n", 1)[0]
        if b" 101 " not in status + b" ":
            raise ConnectionError("中继拒绝：%s" % status.decode("latin-1"))
        expect = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest())
        if expect not in head:
            raise ConnectionError("中继握手无效")
        raw.settimeout(None)
        return WSConn(raw, client=True)

    def _run(self):
        ws = self._ws = self._connect()
        sessions = {}
        try:
            # 身份校验：DH(长期私钥, 中继临时公钥) 做 HMAC 密钥，签中继给的随机数
            message = ws.recv()
            challenge = json.loads(message[1].decode()) if message and message[0] else {}
            if challenge.get("t") != "challenge":
                raise ConnectionError("中继握手无效")
            shared = _dh(self.gate.keys.private, _unb64(challenge["e"]))
            mac = _hmac.new(shared, b"kiteline-mp-relay" + _unb64(challenge["n"]), hashlib.sha256).digest()
            ws.send_text(json.dumps({"t": "prove", "s": _b64(self.gate.keys.public), "m": _b64(mac)}))
            message = ws.recv()
            if not message or json.loads(message[1].decode()).get("t") != "ok":
                raise ConnectionError("中继不认这台电脑")
            self.status = "已连接"
            log.write("小程序远程通道已连上中继 %s" % self.host)
            while not self._stop:
                message = ws.recv()
                if message is None:
                    break
                is_text, data = message
                if is_text or len(data) < 5:
                    continue
                kind, cid, body = data[0], struct.unpack(">I", data[1:5])[0], data[5:]
                if kind == MP_OPEN:
                    def send_raw(frame, cid=cid):
                        ws.send_binary(bytes([MP_BINARY]) + struct.pack(">I", cid) + frame)

                    def send_text(text, cid=cid):
                        ws.send_binary(bytes([MP_TEXT]) + struct.pack(">I", cid) + text.encode("utf-8"))
                    sessions[cid] = Session(self.gate, send_raw, send_text, "127.0.0.1", "relay")
                elif kind == MP_CLOSE:
                    session = sessions.pop(cid, None)
                    if session:
                        session.close()
                elif kind in (MP_TEXT, MP_BINARY):
                    session = sessions.get(cid)
                    if not session:
                        continue
                    ok = session.on_text(body.decode("utf-8", "replace")) if kind == MP_TEXT else session.on_binary(body)
                    if ok is False:
                        sessions.pop(cid, None)
                        session.close()
                        ws.send_binary(bytes([MP_CLOSE]) + struct.pack(">I", cid))
        finally:
            for session in sessions.values():
                session.close()
            ws.close()
            self.status = "未连接"
