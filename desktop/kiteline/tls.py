"""本机 HTTPS（和 Mac 版 LocalTLS.swift 同一套做法）。

首次启动生成一张本机根证书（CA），再用它签一张包含本机所有 IP 与主机名的服务器证书。
iPhone 上的 Kiteline App 配对时记下这张根证书（扫码链接里带它的 SHA-256 指纹核对），之后只认它签的证书。
IP 变了只重签服务器证书，根证书不变，手机不用重新配对。

iOS 对用户信任的根证书签发的服务器证书有要求：RSA ≥ 2048、SHA-256、有效期 ≤ 825 天、必须带 SAN 与 serverAuth。
"""

import datetime
import hashlib
import ipaddress
import json
import os
import socket

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

from . import config, log


def _dir():
    return config.path("tls")


def _p(name):
    return os.path.join(_dir(), name)


def _write_key(key, file_path):
    config.write_private(file_path, key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL,
                                                       serialization.NoEncryption()))


def _load_key(file_path):
    with open(file_path, "rb") as handle:
        return serialization.load_pem_private_key(handle.read(), password=None)


def _load_cert(file_path):
    with open(file_path, "rb") as handle:
        return x509.load_pem_x509_certificate(handle.read())


def host_name():
    return socket.gethostname() or ("Windows" if config.IS_WINDOWS else "Linux")


# 新生成的根证书带名称约束（和 Mac 版 LocalTLS 一致）：只能给私网 / Tailscale / 本机地址和 .local 这类名字签证书。
# 网页版要在手机上完全信任这张根证书：万一这台电脑上的私钥泄露，也冒充不了外面的网站。以前生成的没约束的照常用
PERMITTED_NETS = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "127.0.0.0/8"]
PERMITTED_NAMES = ["local", "localhost", "ts.net", "home.arpa"]


def permitted_ip(ip):
    try:
        address = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(address in ipaddress.ip_network(n) for n in PERMITTED_NETS if address.version == 4)


def permitted_name(name):
    n = name.lower()
    return n == "localhost" or any(n == d or n.endswith("." + d) for d in PERMITTED_NAMES)


def _ca_constrained(cert):
    try:
        cert.extensions.get_extension_for_class(x509.NameConstraints)
        return True
    except x509.ExtensionNotFound:
        return False


def covered(hosts):
    """证书覆盖得到的地址（根证书带约束时，约束外的地址没签进去，列出来手机也连不上）"""
    try:
        if not _ca_constrained(_load_cert(_p("ca.pem"))):
            return list(hosts)
    except (OSError, ValueError):
        return list(hosts)
    return [h for h in hosts if permitted_ip(h) or permitted_name(h)]


def ensure_ca():
    if os.path.exists(_p("ca.key")) and os.path.exists(_p("ca.pem")):
        return
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, "Kiteline Local CA (%s)" % host_name().replace("/", "-")),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Kiteline"),
    ])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(days=1)).not_valid_after(now + datetime.timedelta(days=3650))
            .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
            .add_extension(x509.KeyUsage(digital_signature=False, content_commitment=False, key_encipherment=False,
                                         data_encipherment=False, key_agreement=False, key_cert_sign=True, crl_sign=True,
                                         encipher_only=False, decipher_only=False), critical=True)
            .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
            .add_extension(x509.NameConstraints(
                permitted_subtrees=[x509.IPAddress(ipaddress.ip_network(n)) for n in PERMITTED_NETS]
                + [x509.DNSName(n) for n in PERMITTED_NAMES], excluded_subtrees=None), critical=True)
            .sign(key, hashes.SHA256()))
    os.makedirs(_dir(), exist_ok=True)
    _write_key(key, _p("ca.key"))
    config.write_private(_p("ca.pem"), cert.public_bytes(serialization.Encoding.PEM))
    try:
        os.remove(_p("server.sans"))   # 新 CA 必须重签服务器证书
    except OSError:
        pass
    log.write("已生成本机根证书")


def ensure_leaf(ips, names):
    if _ca_constrained(_load_cert(_p("ca.pem"))):
        # 超出约束的地址有一个，整张证书都会被拒：只签约束范围内的
        ips, names = [i for i in ips if permitted_ip(i)], [n for n in names if permitted_name(n)]
    sans = sorted(set(ips)), sorted(set(names))
    signature = json.dumps(sans)
    leaf = _p("server.pem")
    try:
        with open(_p("server.sans"), encoding="utf-8") as handle:
            same = handle.read() == signature
        fresh = os.path.exists(leaf) and (datetime.datetime.now().timestamp() - os.path.getmtime(leaf)) < 700 * 86400
        if same and fresh:
            return
    except OSError:
        pass
    ca_key, ca_cert = _load_key(_p("ca.key")), _load_cert(_p("ca.pem"))
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    alt = [x509.IPAddress(ipaddress.ip_address(ip)) for ip in sans[0]] + [x509.DNSName(n) for n in sans[1]]
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (x509.CertificateBuilder()
            .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Kiteline"),
                                     x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Kiteline")]))
            .issuer_name(ca_cert.subject).public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(days=1)).not_valid_after(now + datetime.timedelta(days=800))
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=False)
            .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False, key_encipherment=True,
                                         data_encipherment=False, key_agreement=False, key_cert_sign=False, crl_sign=False,
                                         encipher_only=False, decipher_only=False), critical=True)
            .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
            .add_extension(x509.SubjectAlternativeName(alt), critical=False)
            .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_key.public_key()), critical=False)
            .sign(ca_key, hashes.SHA256()))
    _write_key(key, _p("server.key"))
    # 证书链：服务器证书 + 根证书（手机从握手里取链上最后一张当根证书记下）
    chain = cert.public_bytes(serialization.Encoding.PEM) + ca_cert.public_bytes(serialization.Encoding.PEM)
    config.write_private(leaf, chain)
    config.write_private(_p("server.sans"), signature)
    log.write("已签发本机 HTTPS 证书：%s" % ", ".join(sans[0] + sans[1]))


def identity(ips, names):
    """返回 (证书链文件, 私钥文件)；失败返回 None"""
    try:
        ensure_ca()
        ensure_leaf(ips, names)
        return _p("server.pem"), _p("server.key")
    except Exception as exc:  # noqa: BLE001
        log.write("本机 HTTPS 证书准备失败：%s" % exc)
        return None


def ca_der():
    try:
        return _load_cert(_p("ca.pem")).public_bytes(serialization.Encoding.DER)
    except (OSError, ValueError):
        return None


def ca_fingerprint():
    der = ca_der()
    return hashlib.sha256(der).hexdigest() if der else None


def ca_name():
    try:
        cert = _load_cert(_p("ca.pem"))
        return cert.subject.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value
    except Exception:  # noqa: BLE001
        return None
