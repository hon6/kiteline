"""Bark 备用推送（对应 Mac 版 Bark.swift）：iOS 上免费的推送 App，网页推送收不到时兜底。

  - 地址：Bark App 里复制的「https://api.day.app/<key>」，也支持自建 bark-server，或只填 key
  - 需要确认的用「时效性」级别（专注模式下也会响），其他用普通级别
  - 可选加密：填了 Bark App 里设置的 AES 密钥 / IV，内容用 AES-CBC 加密后再发，Bark 服务器只看到密文
"""

import base64
import json
import re
import urllib.error
import urllib.parse
import urllib.request

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

from . import config, log

KEY_RE = re.compile(r"^[A-Za-z0-9]{6,64}$")


def parse(text):
    """返回 (服务器, key) 或 None"""
    text = (text or "").strip()
    if not text:
        return None
    if "/" not in text:
        return ("https://api.day.app", text) if KEY_RE.match(text) else None
    parts = urllib.parse.urlsplit(text)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        return None
    segments = [s for s in parts.path.split("/") if s]
    if not segments or not KEY_RE.match(segments[0]):
        return None
    port = ":%d" % parts.port if parts.port else ""
    return "%s://%s%s" % (parts.scheme, parts.hostname, port), segments[0]


def wants(kind, mobile):
    if not parse(mobile.get("barkURL")):
        return False
    mode = mobile.get("barkMode")
    if mode == "all":
        return True
    if mode == "attention":
        return kind in ("attention", "budget")
    return False


def aes_cbc(data, key, iv):
    key_bytes, iv_bytes = key.encode("utf-8"), iv.encode("utf-8")
    if len(key_bytes) not in (16, 24, 32) or len(iv_bytes) != 16:
        return None
    padder = padding.PKCS7(128).padder()
    padded = padder.update(data) + padder.finalize()
    encryptor = Cipher(algorithms.AES(key_bytes), modes.CBC(iv_bytes)).encryptor()
    return encryptor.update(padded) + encryptor.finalize()


def send(title, body, kind, mobile):
    """同步发一条；返回 (成功, 说明)"""
    target = parse(mobile.get("barkURL"))
    if not target:
        return False, "Bark 地址无效"
    server, device_key = target
    payload = {"title": title, "body": body[:500], "group": "Kiteline",
               "level": "timeSensitive" if kind == "attention" else "active", "isArchive": 1}
    if kind == "attention":
        payload["sound"] = "multiwayinvitation"
    key = (mobile.get("barkKey") or "").strip()
    if key:
        iv = (mobile.get("barkIV") or "").strip()
        cipher = aes_cbc(json.dumps(payload, ensure_ascii=False).encode("utf-8"), key, iv)
        if cipher is None:
            return False, "加密失败：密钥须为 16 / 24 / 32 个字符，IV 须为 16 个字符"
        data = urllib.parse.urlencode({"ciphertext": base64.b64encode(cipher).decode("ascii"), "iv": iv}).encode("utf-8")
        request = urllib.request.Request("%s/%s" % (server, device_key), data=data, method="POST",
                                         headers={"Content-Type": "application/x-www-form-urlencoded", "User-Agent": config.USER_AGENT})
    else:
        payload["device_key"] = device_key
        request = urllib.request.Request("%s/push" % server, data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                                         method="POST", headers={"Content-Type": "application/json; charset=utf-8", "User-Agent": config.USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            reply = json.loads(response.read() or b"{}")
            ok = response.status == 200 and int(reply.get("code", 200)) == 200
            message = "已发到 Bark" if ok else reply.get("message") or "Bark 返回 %d" % response.status
    except urllib.error.HTTPError as exc:
        ok, message = False, "Bark 返回 %d" % exc.code
    except (OSError, ValueError) as exc:
        ok, message = False, str(exc)
    if not ok:
        log.write("Bark 推送失败：%s" % message)
    return ok, message
