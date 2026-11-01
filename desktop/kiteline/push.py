"""推送（对应 Mac 版 WebPush.swift）：RFC 8030 投递、RFC 8291 aes128gcm 内容加密、RFC 8292 VAPID 身份。

iPhone 上的 Kiteline App 也走这里：App 生成一对密钥来订阅，地址写成 apns:<环境>:<推送令牌>，
内容照样按 RFC 8291 加密，交给 Kiteline 推送网关（tars.betac.cn/push）转苹果推送服务；网关和苹果都只看到密文。
"""

import base64
import hashlib
import hmac
import json
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from . import config, log

GATEWAY = os.environ.get("CCPULSE_APNS_GATEWAY") or "https://tars.betac.cn/push"


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def b64url_decode(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def _hmac(key, data):
    return hmac.new(key, data, hashlib.sha256).digest()


def _x963(public_key):
    return public_key.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)


def encrypt(payload, p256dh, auth):
    user_key = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), p256dh)
    server_key = ec.generate_private_key(ec.SECP256R1())
    server_public = _x963(server_key.public_key())
    shared = server_key.exchange(ec.ECDH(), user_key)
    prk_key = _hmac(auth, shared)
    ikm = _hmac(prk_key, b"WebPush: info\x00" + p256dh + server_public + b"\x01")
    salt = os.urandom(16)
    prk = _hmac(salt, ikm)
    cek = _hmac(prk, b"Content-Encoding: aes128gcm\x00\x01")[:16]
    nonce = _hmac(prk, b"Content-Encoding: nonce\x00\x01")[:12]
    sealed = AESGCM(cek).encrypt(nonce, payload + b"\x02", None)
    return salt + (4096).to_bytes(4, "big") + bytes([len(server_public)]) + server_public + sealed


class WebPush:
    def __init__(self):
        self._lock = threading.Lock()
        self.contact = "mailto:ccpulse@users.noreply.github.com"
        key_path = config.path("push-vapid.pem")
        try:
            with open(key_path, "rb") as handle:
                self._key = serialization.load_pem_private_key(handle.read(), password=None)
        except (OSError, ValueError):
            self._key = ec.generate_private_key(ec.SECP256R1())
            config.write_private(key_path, self._key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                                                    serialization.NoEncryption()))
        self._file = config.path("push-subscriptions.json")
        data = config.read_json(self._file, [])
        self.subscriptions = data if isinstance(data, list) else []

    @property
    def public_key(self):
        return b64url(_x963(self._key.public_key()))

    @staticmethod
    def is_app(sub):
        return sub.get("endpoint", "").startswith("apns:")

    # 一台设备最多留几个订阅、总共最多几个：别让一台设备塞进成百上千个地址，每条通知都要挨个发一遍
    PER_DEVICE = 3
    MAX_TOTAL = 64

    @staticmethod
    def acceptable(endpoint, p256dh, auth):
        """订阅地址只收两种：iPhone App 的 apns:<环境>:<推送令牌>、浏览器推送服务的 https 地址（对应 Mac 版 WebPush.acceptable）。
        已配对设备也不能让电脑往本机、内网地址发请求（SSRF）：不收 http、IP 地址、本机 / 局域网域名。"""
        if not all(isinstance(v, str) for v in (endpoint, p256dh, auth)) or len(endpoint) > 2048:
            return False
        try:
            if len(b64url_decode(p256dh)) != 65 or len(b64url_decode(auth)) != 16:
                return False
        except ValueError:
            return False
        if endpoint.startswith("apns:"):
            parts = endpoint.split(":", 2)
            return len(parts) == 3 and parts[1] in ("production", "development") and \
                0 < len(parts[2]) <= 200 and all(c in "0123456789abcdefABCDEF" for c in parts[2])
        try:
            url = urllib.parse.urlsplit(endpoint)
            host = (url.hostname or "").lower().rstrip(".")
        except ValueError:
            return False
        if url.scheme != "https" or url.username or url.password or "." not in host:
            return False
        # 最后一段是纯字母才算域名：挡掉 127.0.0.1、0x7f.1 这类写法
        if not host.rsplit(".", 1)[1].isalpha() or not host.rsplit(".", 1)[1].isascii():
            return False
        return not (host == "localhost" or host.endswith((".localhost", ".local", ".internal", ".lan", ".home.arpa")))

    def add(self, sub):
        with self._lock:
            for old in self.subscriptions:
                if all(old.get(k) == sub.get(k) for k in ("endpoint", "p256dh", "auth", "deviceId")):
                    return
            self.subscriptions = [s for s in self.subscriptions if s["endpoint"] != sub["endpoint"]]
            if self.is_app(sub) and sub.get("deviceId"):
                self.subscriptions = [s for s in self.subscriptions if not (self.is_app(s) and s.get("deviceId") == sub["deviceId"])]
            self.subscriptions.append(sub)
            if sub.get("deviceId"):
                mine = [s for s in self.subscriptions if s.get("deviceId") == sub["deviceId"]]
                drop = {id(s) for s in mine[:-self.PER_DEVICE]}
                self.subscriptions = [s for s in self.subscriptions if id(s) not in drop]
            self.subscriptions = self.subscriptions[-self.MAX_TOTAL:]
            self._save()
        log.write("新增推送订阅（共 %d 个）：%s" % (len(self.subscriptions), "Kiteline App" if self.is_app(sub) else
                                             urllib.parse.urlsplit(sub["endpoint"]).hostname))

    def remove(self, endpoint=None, device_id=None):
        with self._lock:
            self.subscriptions = [s for s in self.subscriptions
                                  if not ((endpoint and s["endpoint"] == endpoint) or (device_id and s.get("deviceId") == device_id))]
            self._save()

    def clear(self):
        with self._lock:
            self.subscriptions = []
            self._save()

    def _save(self):
        config.write_private(self._file, json.dumps(self.subscriptions, ensure_ascii=False, indent=2))

    def device_ids(self, skip):
        with self._lock:
            return {s["deviceId"] for s in self.subscriptions if s.get("deviceId") and s["deviceId"] not in skip}

    def send(self, payload, urgency="high", skip=frozenset(), wait=False, only=None):
        """发给所有订阅（skip 里的设备跳过；only：只发这几台，英文设备单独发一份英文的）。wait=True 时同步返回 (送达数, 错误列表)"""
        with self._lock:
            if only is not None:
                targets = [dict(s) for s in self.subscriptions if s.get("deviceId") in only]
            else:
                targets = [dict(s) for s in self.subscriptions if not s.get("deviceId") or s["deviceId"] not in skip]
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        if not targets:
            return (0, []) if wait else None

        def run():
            delivered, errors = 0, []
            with ThreadPoolExecutor(max_workers=min(8, len(targets))) as pool:
                for sub, (status, detail) in zip(targets, pool.map(lambda s: self._deliver(body, s, urgency), targets)):
                    if 200 <= status < 300:
                        delivered += 1
                        continue
                    errors.append("%s %s" % (status, detail))
                    if status == 410 or (status == 404 and not self.is_app(sub)):
                        self.remove(endpoint=sub["endpoint"])
                        log.write("推送订阅已失效，已移除")
                    else:
                        log.write("推送失败 %s：%s" % (status, detail[:200]))
            return delivered, errors
        if wait:
            return run()
        threading.Thread(target=run, daemon=True).start()
        return None

    def _deliver(self, body, sub, urgency):
        try:
            sealed = encrypt(body, b64url_decode(sub["p256dh"]), b64url_decode(sub["auth"]))
        except Exception as exc:  # noqa: BLE001
            return 410, "订阅数据损坏：%s" % exc
        if self.is_app(sub):
            parts = sub["endpoint"].split(":", 2)
            if len(parts) != 3 or parts[1] not in ("production", "development") or not parts[2]:
                return 410, "订阅数据损坏"
            data = json.dumps({"token": parts[2], "env": parts[1], "data": base64.b64encode(sealed).decode("ascii"),
                               "urgency": urgency, "ttl": 86400}).encode("utf-8")
            request = urllib.request.Request(GATEWAY, data=data, method="POST", headers={"Content-Type": "application/json"})
        else:
            request = urllib.request.Request(sub["endpoint"], data=sealed, method="POST", headers={
                "Content-Encoding": "aes128gcm", "Content-Type": "application/octet-stream", "TTL": "86400",
                "Urgency": urgency, "Authorization": self._vapid(sub["endpoint"])})
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                return response.status, ""
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")
            try:
                detail = json.loads(detail).get("error", detail)
            except (ValueError, AttributeError):
                pass
            return exc.code, detail
        except OSError as exc:
            return 0, str(exc)

    def _vapid(self, endpoint):
        parts = urllib.parse.urlsplit(endpoint)
        audience = "%s://%s" % (parts.scheme, parts.netloc)
        header = b64url(b'{"typ":"JWT","alg":"ES256"}')
        claims = b64url(json.dumps({"aud": audience, "exp": int(time.time()) + 12 * 3600, "sub": self.contact},
                                   sort_keys=True, separators=(",", ":")).encode("utf-8"))
        signing_input = "%s.%s" % (header, claims)
        der = self._key.sign(signing_input.encode("ascii"), ec.ECDSA(hashes.SHA256()))
        r, s = decode_dss_signature(der)
        signature = r.to_bytes(32, "big") + s.to_bytes(32, "big")
        return "vapid t=%s.%s, k=%s" % (signing_input, b64url(signature), self.public_key)
