"""已配对的设备（对应 Mac 版 Devices.swift）：每台手机一把自己的钥匙（只存哈希），可以单独停用。

令牌前缀：主令牌纯十六进制（只留在本机）、设备令牌 d 开头、一次性配对令牌 p 开头（二维码里的，10 分钟、用一次）。
"""

import hashlib
import hmac
import re
import secrets
import threading
import time
import uuid

from . import config, log


def now_ms():
    return time.time() * 1000


def token_hash(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def default_name(agent):
    if "MiniProgram" in agent:   # 小程序入口（mpgate）给的 User-Agent：Kiteline-MiniProgram
        return "微信小程序"
    if "iPhone" in agent:
        return "iPhone"
    if "iPad" in agent:
        return "iPad"
    if "Android" in agent:
        return "安卓手机"
    if "Macintosh" in agent:
        return "Mac 浏览器"
    if "Windows" in agent:
        return "Windows 浏览器"
    return "浏览器"


def app_build(agent):
    """「TARS/202610271712 CFNetwork/3860.600.12 Darwin/25.5.0」→ 202610271712；浏览器的 User-Agent 不算"""
    found = re.match(r"[A-Za-z]+/(\d{1,20}) CFNetwork/", agent or "")
    return found.group(1) if found else None


def is_loopback(ip):
    """本机连进来的（httpd 已把 ::ffff:127.0.0.1 去掉前缀）"""
    host = (ip or "").split("%")[0]
    return host == "::1" or host.startswith("127.") or host.startswith("::ffff:127.")


class DeviceStore:
    PREFIX = "d"

    def __init__(self, on_p2p_change=None):
        self._lock = threading.Lock()
        self._file = config.path("devices.json")
        data = config.read_json(self._file, [])
        self._devices = data if isinstance(data, list) else []
        self._dirty_at = None
        self.on_p2p_change = on_p2p_change

    @property
    def all(self):
        with self._lock:
            return sorted((dict(d) for d in self._devices), key=lambda d: -d.get("lastSeen", 0))

    def register(self, agent, ip, via, name=None):
        token = self.PREFIX + config.make_token()
        stamp = now_ms()
        with self._lock:
            base = (name or "").strip()[:40] or default_name(agent)
            final, index = base, 2
            while any(d["name"] == final for d in self._devices):
                final, index = "%s %d" % (base, index), index + 1
            device = {"id": uuid.uuid4().hex[:8], "name": final, "tokenHash": token_hash(token), "createdAt": stamp,
                      "lastSeen": stamp, "lastIP": ip, "agent": agent[:300], "via": via}
            self._devices.append(device)
        self._save()
        log.write("登记设备「%s」（%s，%s）" % (device["name"], via, ip))
        return dict(device), token

    def authenticate(self, token, ip, client=None, agent=None, pro=None, mp_user=None):
        """client：App 每个请求带的机型、系统、App 版本（X-Kiteline-Client），记下来给「设备」页和使用统计用；
        agent：User-Agent，App 的请求里系统自带构建号（TARS/202610271712 CFNetwork/…），旧版 App 也有；
        pro：订阅了 Kiteline Pro（X-Kiteline-Pro），旧版 App 不带。
        mp_user：微信小程序带的用户编号（X-Kiteline-MP，中继给的 openid 摘要），随使用统计上报，运营后台据此对上小程序用户。
        手机 App 从 127.0.0.1 连进来只可能是点对点转进来的：记下最近一次走远程访问的时间（remoteAt）"""
        if not token.startswith(self.PREFIX):
            return None
        build = app_build(agent)
        digest = token_hash(token)
        changed = False
        with self._lock:
            for device in self._devices:
                if hmac.compare_digest(device["tokenHash"], digest):
                    stamp = now_ms()
                    if stamp - device.get("lastSeen", 0) > 60_000 or device.get("lastIP") != ip:
                        device["lastSeen"], device["lastIP"] = stamp, ip
                        changed = True
                    if client and device.get("client") != client[:120]:
                        device["client"] = client[:120]
                        changed = True
                    if build and device.get("build") != build:
                        device["build"] = build
                        changed = True
                    if pro is not None and device.get("pro") != pro:
                        device["pro"] = pro
                        changed = True
                    # 以前配对的小程序没报名字，叫成了「浏览器 2」：认出是小程序后改成「微信小程序」（只改自动起的名字）
                    if device.get("client") == "miniprogram" and re.fullmatch(r"(Mac |Windows )?浏览器( \d+)?", device.get("name") or ""):
                        name, n = "微信小程序", 2
                        while any(d.get("name") == name for d in self._devices):
                            name, n = "微信小程序 %d" % n, n + 1
                        device["name"] = name
                        changed = True
                    if device.get("client") == "miniprogram" and mp_user and re.fullmatch(r"[0-9a-f]{10}", mp_user) \
                            and device.get("mpUser") != mp_user:
                        device["mpUser"] = mp_user
                        changed = True
                    # 小程序经中继来的隧道来源也记成 127.0.0.1
                    via_remote = (device.get("client") or "").startswith("ios/") or device.get("client") == "miniprogram"
                    if is_loopback(ip) and via_remote and stamp - device.get("remoteAt", 0) > 60_000:
                        device["remoteAt"] = stamp
                        changed = True
                    found = dict(device)
                    break
            else:
                return None
        if changed:
            self._save_later()
        return found

    def peek(self, token):
        if not token.startswith(self.PREFIX):
            return None
        digest = token_hash(token)
        with self._lock:
            for device in self._devices:
                if device["tokenHash"] == digest:
                    return dict(device)
        return None

    def get(self, device_id):
        with self._lock:
            for device in self._devices:
                if device["id"] == device_id:
                    return dict(device)
        return None

    def revoke(self, device_id):
        with self._lock:
            for index, device in enumerate(self._devices):
                if device["id"] == device_id:
                    removed = self._devices.pop(index)
                    break
            else:
                return None
        self._save()
        log.write("停用设备「%s」" % removed["name"])
        if self.on_p2p_change:
            self.on_p2p_change()
        return removed

    def set_peer(self, device_id, kind, peer, ref):
        """电脑互联（peers.py）：标上是电脑（kind = computer、peer = 对方电脑编号），或是哪台电脑替手机登记的（peer、ref）"""
        with self._lock:
            for device in self._devices:
                if device["id"] == device_id:
                    for field, value in (("kind", kind), ("peer", peer), ("ref", ref)):
                        if value is None:
                            device.pop(field, None)
                        else:
                            device[field] = value
        self._save()

    def rename(self, device_id, name):
        clean = (name or "").strip()[:40]
        if not clean:
            return None
        with self._lock:
            for device in self._devices:
                if device["id"] == device_id:
                    device["name"] = clean
                    found = dict(device)
                    break
            else:
                return None
        self._save()
        return found

    def set_p2p_id(self, device_id, p2p_id):
        with self._lock:
            for device in self._devices:
                if device["id"] == device_id:
                    changed = device.get("p2pId") != p2p_id
                    device["p2pId"] = p2p_id
                    break
            else:
                return
        if changed:
            self._save()

    def set_watch(self, device_id, paired, installed, complication=None):
        with self._lock:
            for device in self._devices:
                if device["id"] == device_id:
                    old = device.get("watch") or {}
                    device["watch"] = {"paired": paired, "installed": installed, "complication": complication,
                                       "updatedAt": now_ms(), "lastUsed": old.get("lastUsed") if paired else None}
                    break
        self._save()

    def touch_watch(self, device_id):
        with self._lock:
            for device in self._devices:
                if device["id"] == device_id:
                    watch = device.get("watch") or {"paired": True, "installed": True, "updatedAt": now_ms()}
                    stale = now_ms() - (watch.get("lastUsed") or 0) > 60_000
                    watch.update({"paired": True, "installed": True, "lastUsed": now_ms()})
                    device["watch"] = watch
                    break
            else:
                return
        if stale:
            self._save_later()

    @property
    def p2p_ids(self):
        with self._lock:
            return [d["p2pId"] for d in self._devices if d.get("p2pId")]

    def revoke_all(self):
        with self._lock:
            self._devices = []
        self._save()
        if self.on_p2p_change:
            self.on_p2p_change()

    def _save_later(self):
        with self._lock:
            if self._dirty_at:
                return
            self._dirty_at = time.time()

        def later():
            time.sleep(5)
            with self._lock:
                self._dirty_at = None
            self._save()
        threading.Thread(target=later, daemon=True).start()

    def _save(self):
        import json
        with self._lock:
            text = json.dumps(self._devices, ensure_ascii=False, indent=2, sort_keys=True)
        config.write_private(self._file, text)


class Pairing:
    """6 位配对码（10 分钟、用一次）和一次性配对令牌（二维码里的 p…）"""

    def __init__(self):
        self._lock = threading.Lock()
        self.code = ""
        self.expiry = 0.0
        self._failed = []
        self._links = {}
        self._code_failures = 0   # 当前这个码输错了几次：5 次作废（防撞码）

    def new_code(self):
        code = "%06d" % secrets.randbelow(1_000_000)
        with self._lock:
            self.code, self.expiry = code, time.time() + 600
            self._code_failures = 0
        return code

    def new_link_token(self):
        token = "p" + config.make_token()
        stamp = time.time()
        with self._lock:
            self._links = {k: v for k, v in self._links.items() if v > stamp}
            self._links[token] = stamp + 600
        return token

    def link_valid(self, token):
        with self._lock:
            return self._links.get(token, 0) > time.time()

    def reset(self):
        """重置令牌时：还没用的配对码、扫码链接全部作废"""
        with self._lock:
            self.code, self.expiry, self._links = "", 0.0, {}

    def consume_link(self, token):
        with self._lock:
            if self._links.get(token, 0) <= time.time():
                return False
            self._links.pop(token, None)
            return True

    def check_code(self, code, source="?"):
        """返回 (ok, 原因)：同一来源 10 分钟内错 8 次只锁它自己，所有来源合计 30 次才全锁；
        有人把端口开到公网：公网地址来的错码一小时合计 10 次，公网来的配对先停一小时（locked_public）；
        同一个码输错 5 次就作废（「手机访问」页自动换新码），一个码最多只给猜 5 次"""
        from .peers import is_private
        stamp = time.time()
        with self._lock:
            self._failed = [(t, s) for t, s in self._failed if stamp - t < 3600]
            recent = [(t, s) for t, s in self._failed if stamp - t < 600]
            if not is_private(source) and sum(1 for _, s in self._failed if not is_private(s)) >= 10:
                return False, "locked_public"
            if len(recent) >= 30 or sum(1 for _, s in recent if s == source) >= 8:
                return False, "locked"
            if not self.code or stamp >= self.expiry or not hmac.compare_digest(code, self.code):
                why = "这个码已经用过" if not self.code else ("码已过期" if stamp >= self.expiry else "码不对")
                self._failed.append((stamp, source))
                if self.code and stamp < self.expiry:
                    self._code_failures += 1
                    if self._code_failures >= 5:
                        self.code, self.expiry = "", stamp
                        log.write("配对码连续输错 5 次，已作废，换新码")
                return False, why
            self.code = ""   # 一次性
            return True, ""

    def add_failure(self, source="?"):
        with self._lock:
            self._failed.append((time.time(), source))
