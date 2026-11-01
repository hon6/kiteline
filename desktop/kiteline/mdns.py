"""局域网宣告（Bonjour / mDNS）：iPhone 上的 Kiteline 在配对页自动找到这台电脑（_tars._tcp，TXT 里 role=mac、fp=根证书指纹）。
role 沿用 mac：iOS App 只认这个值；另带 os=windows/linux 说明是什么电脑。"""

import socket

from zeroconf import IPVersion, ServiceInfo, Zeroconf

from . import config, log


class Advert:
    def __init__(self, zc, info):
        self._zc, self._info = zc, info

    def close(self):
        try:
            self._zc.unregister_service(self._info)
            self._zc.close()
        except Exception:  # noqa: BLE001
            pass


def advertise(host, port, fingerprint, ips):
    name = (host or "Kiteline").replace(".", "-")[:60]
    props = {"role": "mac", "os": config.PLATFORM}
    if fingerprint:
        props["fp"] = fingerprint
    addresses = [socket.inet_aton(ip) for ip in ips if ":" not in ip] or [socket.inet_aton("127.0.0.1")]
    info = ServiceInfo("_tars._tcp.local.", "%s._tars._tcp.local." % name, addresses=addresses, port=port,
                       properties=props, server="%s.local." % name.lower())
    zc = Zeroconf(ip_version=IPVersion.V4Only)
    zc.register_service(info, allow_name_change=True)
    log.write("局域网宣告 _tars._tcp：%s（%s:%d）" % (name, ",".join(ips), port))
    return Advert(zc, info)
