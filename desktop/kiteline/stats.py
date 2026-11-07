"""使用统计（对应 Mac 版 UsageStats.swift）：每 15 分钟把精简的使用情况报给 Kiteline 的服务器（relay/stats，
tars.betac.cn/stats/report），运营后台按它看有哪些客户、各自几台设备、几个会话、用哪些 agent 和模型。

只有数字和类别：配对设备的类型 / 系统 / App 版本、会话的 agent / 模型 / token / 上下文 / 时长、按天的用量合计，
加上「我」的名字。不带对话、代码、文件、项目路径、会话标题；设备和会话的 id 都换成和本机编号一起算的摘要。
设置里「发送使用统计」可以关（mobile.usageStats）。测试实例（KITELINE_CONFIG_DIR、dry-run）不报，除非用 KITELINE_STATS_URL 指了地址。
"""

import gzip
import hashlib
import json
import locale
import os
import platform
import re
import secrets
import threading
import time
import urllib.request

from . import aggregate, config, delivery, log

INTERVAL = 15 * 60
USAGE_EVERY = 6 * 3600     # 按天用量要扫会话记录：6 小时带一次
HEARTBEAT = 6 * 3600       # 什么都没变也每 6 小时报一次，后台才知道这台电脑还开着


def endpoint():
    custom = os.environ.get("KITELINE_STATS_URL") or os.environ.get("CCPULSE_STATS_URL")
    if custom:
        return custom
    if os.environ.get("KITELINE_CONFIG_DIR") or os.environ.get("CCPULSE_CONFIG_DIR") or delivery.DRY_RUN:
        return None
    return "https://tars.betac.cn/stats/report"


def parse_client(raw):
    """「ios/1.1 (iPhone13,2; iOS 18.7.8)」→ (ios, 1.1, iPhone13,2, iOS 18.7.8)"""
    m = re.match(r"^([^/]+)/([^(]*)\(([^;]+);\s*([^)]+)\)", raw or "")
    return (m.group(1), m.group(2).strip(), m.group(3).strip(), m.group(4).strip()) if m else None


def ios_from_darwin(agent):
    """CFNetwork 的 User-Agent 里只有 Darwin 版本：24.6 → iOS 18.6；iOS 26 是 Darwin 25，27 起两边版本号一致"""
    m = re.search(r"Darwin/(\d+)\.(\d+)", agent or "")
    if not m:
        return None
    major = int(m.group(1))
    major = major - 6 if major <= 24 else (26 if major == 25 else major)
    return "iOS %d.%s" % (major, m.group(2))


def os_name():
    if config.IS_WINDOWS:
        build = platform.version().split(".")[-1]
        name = "Windows 11" if build.isdigit() and int(build) >= 22000 else "Windows %s" % platform.release()
        return "%s (%s)" % (name, build) if build.isdigit() else name
    try:
        with open("/etc/os-release", encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("PRETTY_NAME="):
                    return line.split("=", 1)[1].strip().strip('"')[:40]
    except OSError:
        pass
    return "%s %s" % (platform.system(), platform.release())


def arch_name():
    machine = platform.machine().lower()
    return {"amd64": "x86_64", "aarch64": "arm64"}.get(machine, machine)


def ui_locale():
    if config.IS_WINDOWS:
        try:
            import ctypes
            buffer = ctypes.create_unicode_buffer(85)
            if ctypes.windll.kernel32.GetUserDefaultLocaleName(buffer, 85):
                return buffer.value
        except Exception:  # noqa: BLE001
            pass
    value = os.environ.get("LANG") or (locale.getlocale()[0] or "")
    return value.split(".")[0].replace("_", "-")


def millis(value):
    """watcher 报的时间有秒也有毫秒：统一成毫秒"""
    try:
        value = float(value or 0)
    except (TypeError, ValueError):
        return None
    if value <= 0:
        return None
    return int(value * 1000 if value < 1e12 else value)


def detect_agents(app):
    """本机装了哪些 Agent（同设备详情 /api/machine：Claude Code 在 machine_info 里、别家在插件列表里）；本机来源没连上时 None"""
    from . import faces
    try:
        detail = faces.machine(app, "local")
    except Exception as exc:  # noqa: BLE001
        log.write("检测本机 Agent 出错：%s" % exc)
        return None
    agents = (detail or {}).get("agents")
    return agents if agents else None


class UsageStats:
    def __init__(self, app):
        self.app = app
        self._wake = threading.Event()
        self._force = False
        self._last_sent = 0.0
        self._last_usage = 0.0
        self._last_fingerprint = None
        self._identity = None
        # 本机检测到的 Agent（id）：None = 还没检测过（报 null）；一小时问一次本机 watcher
        self.installed_agents = None
        self._last_agent_check = 0.0

    def start(self):
        if not endpoint():
            return
        threading.Thread(target=self._loop, daemon=True, name="usage-stats").start()

    def kick(self):
        """设置里关了再开：马上报一次"""
        self._force = True
        self._wake.set()

    def _loop(self):
        # 启动后先等两分钟：来源连上、会话列表齐了再报
        self._wake.wait(float(os.environ.get("KITELINE_STATS_DELAY") or 120))
        while True:
            self._wake.clear()
            force, self._force = self._force, False
            try:
                self.tick(force)
            except Exception as exc:  # noqa: BLE001
                log.write("使用统计出错：%s" % exc)
            self._wake.wait(INTERVAL)

    # MARK: 本机编号

    @property
    def identity(self):
        """第一次用时随机生成，存在配置目录（只有本机用户能读）；删了就当新客户"""
        if self._identity:
            return self._identity
        path = config.path("stats-id.json")
        data = config.read_json(path, {})
        if not (isinstance(data, dict) and len(data.get("install") or "") == 32 and len(data.get("key") or "") == 32):
            data = {"install": secrets.token_hex(16), "key": secrets.token_hex(16)}
            config.write_private(path, json.dumps(data))
        self._identity = data
        return data

    def digest(self, value):
        """设备、会话的 id 不原样发：和本机编号一起算个摘要，后台只拿来区分是不是同一个"""
        return hashlib.sha256((self.identity["install"] + "/" + value).encode()).hexdigest()[:16]

    # MARK: 上报

    def tick(self, force=False):
        url = endpoint()
        if not url or not self.app.cfg.mobile.get("usageStats", True):
            return
        now = time.time()
        usage = self._usage() if force or now - self._last_usage > USAGE_EVERY else None
        if force or now - self._last_agent_check > 3600:
            found = detect_agents(self.app)
            if found is not None:
                self.installed_agents = [a["id"] for a in found if a.get("installed")]
                self._last_agent_check = now
        body = self.snapshot()
        fingerprint = json.dumps(body, sort_keys=True)
        if usage is None and not force and fingerprint == self._last_fingerprint and now - self._last_sent < HEARTBEAT:
            return
        if usage:
            body["days"], body["models"] = usage
        if self._post(url, body):
            self._last_sent, self._last_fingerprint = now, fingerprint
            if usage:
                self._last_usage = now

    def snapshot(self):
        app = self.app
        m = app.cfg.mobile
        devices = app.devices.all
        with app.push._lock:   # noqa: SLF001 订阅表会在别的线程里改
            pushed = {s.get("deviceId") for s in app.push.subscriptions if s.get("deviceId")}
        with app.store.lock:
            sources = list(app.store.sources.values())
            records = list(app.store.records)
        identity = self.identity
        return {
            "v": 1, "install": identity["install"], "key": identity["key"],
            "name": m.get("myName") or app.user_name(),
            "platform": config.PLATFORM, "os": os_name(), "arch": arch_name(), "app": app.version,
            "lang": ui_locale(), "tz": int(-time.altzone / 60) if time.localtime().tm_isdst else int(-time.timezone / 60),
            "features": {
                "remote": bool(m.get("remoteEnabled")) and any(d.get("p2pId") for d in devices),
                "push": bool(pushed),
                "bark": bool(m.get("barkURL")),
                "ssh": any(s.kind == "ssh" for s in sources),
                "digest": bool(m.get("digestTime")),
                "budget": bool(m.get("dailyBudget") or m.get("dailyCap")),
                "watch": any((d.get("watch") or {}).get("installed") for d in devices),
            },
            "hosts": [{"kind": "ssh" if s.kind == "ssh" else "local", "live": bool(s.live)} for s in sources],
            "agents": self.installed_agents,
            "devices": [self._device(d, d.get("id") in pushed) for d in devices],
            "sessions": [self._session(r) for r in records],
        }

    def _device(self, d, pushed):
        out = {"id": self.digest("device/" + d.get("id", "")), "via": "qr" if d.get("via") == "扫码" else "code",
               "remote": bool(d.get("p2pId")), "push": pushed,
               "createdAt": int(d.get("createdAt") or 0), "lastSeen": int(d.get("lastSeen") or 0)}
        if d.get("pro") is not None:
            out["pro"] = bool(d["pro"])
        if d.get("remoteAt"):
            out["remoteAt"] = int(d["remoteAt"])
        client = parse_client(d.get("client"))
        agent = d.get("agent") or ""
        if d.get("build"):
            out["build"] = d["build"]
        if d.get("client") == "miniprogram":
            # 微信小程序（来源由电脑端的小程序入口定，不能冒充）；mpUser 是中继给的用户编号，后台据此对上小程序用户和订阅
            out["kind"] = "miniprogram"
            if d.get("mpUser"):
                out["mpUser"] = d["mpUser"]
        elif client:
            out["kind"] = "ipad" if client[2].startswith("iPad") else ("mac-app" if client[0] == "mac" else "iphone")
            out.update({"model": client[2], "os": client[3], "app": client[1]})
        elif agent.startswith("TARS/") or "CFNetwork" in agent:
            # 旧版 App 不报机型：从 User-Agent 猜个大概
            out["kind"] = "ipad" if "iPad" in (d.get("name") or "") else "iphone"
            guess = ios_from_darwin(agent)
            if guess:
                out["os"] = guess
        elif "Android" in agent:
            out["kind"] = "android"
        elif "iPhone" in agent or "iPad" in agent:
            out.update({"kind": "browser", "os": "iPadOS" if "iPad" in agent else "iOS"})
        else:
            out["kind"] = "browser-mac" if "Macintosh" in agent else "browser-windows" if "Windows" in agent \
                else "browser-linux" if "Linux" in agent else "browser"
        if out["kind"] == "ipad" and str(out.get("os", "")).startswith("iOS "):
            out["os"] = "iPadOS " + out["os"][4:]
        watch = d.get("watch") or {}
        if watch.get("paired"):
            out["watch"] = "paired" if not watch.get("installed") else ("complication" if watch.get("complication") else "installed")
            if watch.get("lastUsed"):
                out["watchUsed"] = int(watch["lastUsed"])
        return out

    def _session(self, record):
        s = record.snap
        u = s.get("usage") or {}
        effort = s.get("effort") or {}
        out = {
            "id": self.digest("session/" + record.key), "agent": s.get("agent") or "claude-code", "entry": s.get("entrypoint") or "",
            "host": "ssh" if record.kind == "ssh" else "local", "model": u.get("model") or "", "version": s.get("version") or "",
            "subagents": int(s.get("subagents") or 0), "effort": effort.get("effort") or "", "mode": effort.get("mode") or "",
            "activity": s.get("activity") or "",
        }
        for key in ("context", "window", "input", "output", "cacheRead", "cacheWrite", "requests"):
            out[key] = int(aggregate.number(u.get(key)))
        out["cost"] = aggregate.number(u.get("cost"))
        started, updated = millis(s.get("startedAt")), millis(s.get("updatedAt") or s.get("transcriptUpdatedAt"))
        if started:
            out["startedAt"] = started
        if updated:
            out["updatedAt"] = updated
        return out

    def _usage(self):
        """近 30 天按天、按模型的用量（和「用量」页同一份算法，含已经结束的会话）。有来源没连上时这次不带，免得把那几天报少了"""
        report = aggregate.usage(self.app.store, 30)
        if report.get("errors"):
            return None
        keys = ("input", "output", "cacheRead", "cacheWrite", "requests")

        def pick(item, name):
            out = {name: item.get(name) or ""}
            out.update({k: int(aggregate.number(item.get(k))) for k in keys})
            out["cost"] = aggregate.number(item.get("cost"))
            return out
        return [pick(d, "day") for d in report.get("days") or []], [pick(m, "model") for m in (report.get("models") or [])[:30]]

    def feedback(self, fields):
        """用户主动提交的反馈（新手引导里「你使用的 Agent 不在列表中？」）：和使用统计同一个本机编号，发到 /stats/feedback。
        是用户自己点的「提交」，不看「发送使用统计」开关；测试实例没指地址时不发"""
        url = endpoint()
        if not url:
            return False
        identity = self.identity
        body = {"v": 1, "install": identity["install"], "key": identity["key"],
                "name": self.app.cfg.mobile.get("myName") or self.app.user_name(), "platform": config.PLATFORM,
                "os": os_name(), "app": self.app.version, "lang": ui_locale()}
        body.update(fields)
        return self._post(url.rsplit("/", 1)[0] + "/feedback", body)

    def _post(self, url, body):
        data = gzip.compress(json.dumps(body, ensure_ascii=False).encode())
        request = urllib.request.Request(url, data=data, method="POST", headers={
            "Content-Type": "application/json", "Content-Encoding": "gzip",
            "User-Agent": "Kiteline/%s (%s)" % (self.app.version, config.PLATFORM)})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.status == 200
        except Exception as exc:  # noqa: BLE001
            log.write("使用统计没报上去：%s" % exc)
            return False
