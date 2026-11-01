"""用 cryptography 库按 RFC 8291 / 8292 独立核对 Kiteline 的推送加密与 VAPID 签名。

用法：python3 tests/test_webpush.py <CCPulse 可执行文件>（配置目录由 CCPULSE_CONFIG_DIR 指定）
"""
import base64
import json
import os
import subprocess
import time

from cryptography.hazmat.primitives import hashes, hmac, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def b64u(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def unb64u(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def hmac256(key, data):
    h = hmac.HMAC(key, hashes.SHA256())
    h.update(data)
    return h.finalize()


ua_private = ec.generate_private_key(ec.SECP256R1())
ua_public = ua_private.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
auth = os.urandom(16)
message = "需要你确认 · 测试推送 ✓ " + "x" * 50
endpoint = "https://web.push.apple.com/QGuQyavXutnMH3a8bJ9Z"

import sys
app = sys.argv[1]
out = subprocess.run([app, "webpush-selftest", b64u(ua_public), b64u(auth), message, endpoint],
                     stdout=subprocess.PIPE, check=True).stdout.decode()
result = json.loads(out)
body = unb64u(result["body"])

# --- 解密（RFC 8291）
salt, rs, idlen = body[:16], int.from_bytes(body[16:20], "big"), body[20]
as_public = body[21:21 + idlen]
ciphertext = body[21 + idlen:]
server_key = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), as_public)
ecdh = ua_private.exchange(ec.ECDH(), server_key)
prk_key = hmac256(auth, ecdh)
ikm = hmac256(prk_key, b"WebPush: info\x00" + ua_public + as_public + b"\x01")
prk = hmac256(salt, ikm)
cek = hmac256(prk, b"Content-Encoding: aes128gcm\x00\x01")[:16]
nonce = hmac256(prk, b"Content-Encoding: nonce\x00\x01")[:12]
plain = AESGCM(cek).decrypt(nonce, ciphertext, None)
assert plain.endswith(b"\x02"), "缺少记录分隔符"
decoded = plain[:-1].decode()
print("rs =", rs, "idlen =", idlen)
print("解密结果一致：", decoded == message)

# --- VAPID（RFC 8292）
header = result["authorization"]
assert header.startswith("vapid t="), header
token = header.split("t=")[1].split(",")[0]
k = header.split("k=")[1].strip()
h64, c64, s64 = token.split(".")
claims = json.loads(unb64u(c64))
pub = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), unb64u(k))
sig = unb64u(s64)
pub.verify(encode_dss_signature(int.from_bytes(sig[:32], "big"), int.from_bytes(sig[32:], "big")),
           f"{h64}.{c64}".encode(), ec.ECDSA(hashes.SHA256()))
print("VAPID 签名有效：True")
print("claims:", claims)
assert claims["aud"] == "https://web.push.apple.com"
assert claims["exp"] > time.time() and claims["exp"] - time.time() <= 24 * 3600
assert k == result["publicKey"]
print("ALL OK")
