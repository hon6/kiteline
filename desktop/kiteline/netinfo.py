"""本机网络地址：局域网 IPv4、Tailscale（100.64.0.0/10）、主机名。证书 SAN 和配对地址都用它"""

import ipaddress
import re
import socket
import subprocess

from . import config


def skip_interface(name):
    """手机连不到的网卡：docker 自己建的网桥（docker0、br-<12 位十六进制>）、veth、libvirt 的 NAT 网桥。
    br-vm、br-lan 这类自己建的桥接网卡常常就是局域网地址（虚拟机桥接），不能跳过，不然证书里没有它、手机连不上"""
    return name.startswith(("docker", "veth", "virbr")) or re.fullmatch(r"br-[0-9a-f]{12}", name) is not None


def _all_ipv4():
    ips = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ips.add(info[4][0])
    except OSError:
        pass
    # 主路由出口（不真的发包）
    for probe in ("192.168.1.1", "10.0.0.1", "8.8.8.8"):
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.connect((probe, 80))
            ips.add(sock.getsockname()[0])
            sock.close()
        except OSError:
            pass
    if config.IS_LINUX:
        try:
            out = subprocess.run(["ip", "-4", "-o", "addr", "show"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                 timeout=3).stdout.decode()
            for line in out.splitlines():
                parts = line.split()
                if "inet" in parts:
                    name = parts[1]
                    if skip_interface(name):
                        continue
                    ips.add(parts[parts.index("inet") + 1].split("/")[0])
        except (OSError, subprocess.SubprocessError):
            pass
    if config.IS_WINDOWS:
        try:
            out = subprocess.run(["ipconfig"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5,
                                 creationflags=0x08000000).stdout.decode("mbcs", "replace")
            for line in out.splitlines():
                if "IPv4" in line and ":" in line:
                    ips.add(line.rsplit(":", 1)[1].strip())
        except (OSError, subprocess.SubprocessError):
            pass
    good = set()
    for ip in ips:
        try:
            addr = ipaddress.ip_address(ip)
        except ValueError:
            continue
        if addr.is_loopback or addr.is_link_local:
            continue
        # docker 默认网桥；198.18.0.0/15 是代理软件（Clash 等）虚拟网卡的地址，手机连不到
        if addr in ipaddress.ip_network("172.17.0.0/16") or addr in ipaddress.ip_network("198.18.0.0/15"):
            continue
        good.add(ip)
    return sorted(good)


class NetworkInfo:
    def __init__(self):
        ips = _all_ipv4()
        cgnat = ipaddress.ip_network("100.64.0.0/10")
        self.tailscale = [ip for ip in ips if ipaddress.ip_address(ip) in cgnat]
        self.lan = [ip for ip in ips if ip not in self.tailscale]
        host = socket.gethostname()
        self.names = [n for n in {host, host.split(".")[0] + ".local"} if n]
        self.all_ips = ips


def current():
    return NetworkInfo()
