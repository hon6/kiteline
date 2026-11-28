"""检查更新、下载、静默安装、重启（同 Mac 版 Sources/Updater.swift）。

新版本信息在官网下载页的 latest.json（relay/download.sh 发布时写）：platforms.windows / platforms.linux 里有
version、url、size、sha256，notes / notesEn 是这一版的更新说明。

流程：启动 30 秒后查一次、之后每小时查一次 → 有新版本时客户端右上角出绿色箭头 → 用户确认后下载（带进度、核对 SHA-256）
→ 静默装好（Windows 解压到旁边待换；Linux 解压并把依赖装进现有虚拟环境）→ 提示重启 → 重启时由一个独立的小脚本
等 Kiteline（和客户端）退出、换上新文件、再把它们启动起来。

只有正式安装的版本能自动更新：Windows 是打包版（Kiteline.exe），Linux 是 install.sh 装在 ~/.local/share/kiteline 的；
直接从源码跑的开发版只检查、不安装。

发现新版本时客户端主动弹出更新弹窗（state 里 prompt 为真时弹，弹过报 /prompted）：「以后再说」24 小时后再弹，
勾了「此版本不再提示」（/skip）这个版本就不再弹，出了更新的版本再弹（同 Mac 版）。顺带看配对过的手机：App Store 上
有比手机上新的 Kiteline 时，state 的 phones 里列出来，客户端同样弹一次「手机端有新版本」。
手机也能反过来看这台电脑的更新、让它下载安装和重启（/api/host-update → host_payload() / remote()）。

自动更新（设置里默认开，mobile.autoUpdate；同 Mac 版）：发现新版本不弹窗，直接在后台下载装好，等电脑空闲时（没人用电脑、
没有会话在运行或等确认、手机这几分钟没在看）自动重启换上。下载走差量（_build_delta）：latest.json 的 files 指向这个版本的
文件清单（tools/release/delta.py 生成），本机已有的文件直接拷，变了的文件下二进制补丁（bsdiff 格式，本文件里的 bspatch 打）
或整个文件，拼出和安装包解开后一样的目录，再走原来的安装流程；拼不出来就退回下载整个安装包。
"""

import bz2
import gzip
import hashlib
import json
import locale
import os
import re
import shutil
import subprocess
import sys
import tarfile
import threading
import time
import urllib.request
import zipfile

from . import config, i18n, log

CHECK_EVERY = 3600          # 每小时查一次：发版后各端一小时内就会出绿色箭头（latest.json 才几百字节）
FIRST_CHECK = 30
SNOOZE = 24 * 3600          # 弹过（点了「以后再说」）之后多久再自动弹
STORE_EVERY = 6 * 3600      # App Store 上的 iPhone 版六小时问一次
IOS_BUNDLE = "com.mrhong.tars.ios"
IDLE_TICK = 60              # 装好后每分钟看一次电脑空不空闲
IDLE_NEEDED = 600           # 人离开电脑这么久才自动重启
BUSY_PATIENCE = 24 * 3600   # 一直有会话在运行：等这么久后不再等它（正在运行的会话不受 Kiteline 重启影响，只是保守起见先等）
PHONE_RECENT = 300          # 手机这么久内来过请求 = 正在看


def parse_version(text):
    parts = []
    for piece in str(text or "").strip().lstrip("vV").split("."):
        digits = "".join(ch for ch in piece if ch.isdigit())
        parts.append(int(digits) if digits else 0)
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def newer(candidate, current):
    return parse_version(candidate) > parse_version(current)


class Updater:
    def __init__(self, app):
        self.app = app
        self._lock = threading.Lock()
        self._cancel = threading.Event()
        self._worker = None
        self.release = None          # latest.json 里这个平台的那一段
        self.phase = "idle"          # idle / checking / none / available / downloading / installing / ready / restarting / error
        self.received = 0
        self.error = ""
        self.checked_at = 0
        self.staged = None           # 待换上的新版本目录（Windows）/ 解压出的安装包目录（Linux）
        self.history = []            # 落后的这几版各自的更新内容（官网 notes-desktop.json，新的在前）
        self.behind = 0              # 落后几个版本（latest.json 里发过的版本中比这台新的）
        self.store = None            # App Store 上的 iPhone 版 {version, notes, minimumOS}
        self.store_checked = 0
        self.phones = None           # 还是旧版本的手机 {version, notes, devices: [{name, version}]}
        self.client = {}             # 正在运行的客户端（启动时自己报上来）：从托盘、控制台重启时也把它关掉再打开
        self.total = 0               # 这次要下载的总字节数：差量是算出来的那些，整包是安装包大小
        self.silent = False          # 这次是自动更新开始的：装好了不弹窗，等空闲自动重启
        self.waiting_for = ""        # 自动重启还在等什么（「电脑有人在用」……）；空 = 没在等
        self.ready_since = 0
        self.delta_failed = set()    # 差量拼过失败的版本：下次直接下整包
        self.supported, self.reason = self._supported()
        self.directory = config.path("updates")

    # MARK: 能不能自动装

    def _supported(self):
        if config.IS_WINDOWS:
            if not getattr(sys, "frozen", False):
                return False, "开发版不支持自动更新"
            return True, ""
        if config.IS_LINUX:
            home = self.install_home()
            if not home:
                return False, "开发版不支持自动更新"
            return True, ""
        return False, "此系统不支持自动更新"

    @staticmethod
    def install_home():
        """Linux 安装目录（~/.local/share/kiteline，或 KITELINE_HOME）：kiteline 包和 venv 都在里面才算正式安装"""
        package = os.path.dirname(os.path.abspath(__file__))
        home = os.path.dirname(package)
        venv = os.path.join(home, "venv")
        if os.path.basename(package) == "kiteline" and os.path.isfile(os.path.join(venv, "bin", "python")) \
                and os.path.realpath(sys.prefix) == os.path.realpath(venv):
            return home
        return None

    @staticmethod
    def app_dir():
        """Windows 打包版所在的文件夹（Kiteline.exe 和 _internal 在里面）"""
        return os.path.dirname(os.path.abspath(sys.executable))

    @property
    def platform(self):
        return "windows" if config.IS_WINDOWS else "linux"

    def url(self):
        return os.environ.get("KITELINE_UPDATE_URL") or self.app.cfg.relay().rstrip("/") + "/download/latest.json"

    # MARK: 状态

    def state(self):
        with self._lock:
            release = self.release or {}
            english = i18n.ui_english()
            notes = (release.get("notesEn") if english else None) or release.get("notes") or ""
            version = release.get("version", "")
            key = self.key(version) if version else ""
            payload = {"ok": True, "supported": self.supported, "reason": self.reason, "current": self.app.version,
                       "phase": self.phase, "version": version, "notes": notes,
                       "size": self.total if self.phase == "downloading" else self.expected_size(),
                       "received": self.received, "error": self.error,
                       "autoUpdate": self.auto(), "silent": self.silent, "waitingFor": self.waiting_for,
                       "checkedAt": int(self.checked_at * 1000), "page": self.app.cfg.relay().rstrip("/") + "/download",
                       "restartNeeded": self.phase == "ready", "behind": self.behind,
                       # 各版本说明（客户端按界面语言挑 notes / notesEn）；没取到就只有新版本这一版
                       "releases": self.history or ([{"version": version, "date": "", "notes": release.get("notes") or "",
                                                       "notesEn": release.get("notesEn") or ""}] if version else []),
                       # 自动弹窗：key 记「不再提示」「弹过了」，prompt = 现在该弹
                       "key": key, "skipped": bool(key) and self.is_skipped(key),
                       "prompt": self.phase == "available" and bool(key) and self.due(key) and not self.auto()}
            phones = self.phones
        if phones:
            phone_key = "ios:" + phones["version"]
            payload["phones"] = dict(phones, key=phone_key, skipped=self.is_skipped(phone_key), prompt=self.due(phone_key))
        return payload

    # MARK: 什么时候弹（「此版本不再提示」、24 小时后再弹）

    def key(self, version):
        return "%s:%s" % (self.platform, version)

    def _prefs(self):
        m = self.app.cfg.mobile
        return list(m.get("updateSkipped") or []), dict(m.get("updateSnoozed") or {})

    def is_skipped(self, key):
        return key in self._prefs()[0]

    def due(self, key):
        skipped, snoozed = self._prefs()
        return key not in skipped and float(snoozed.get(key) or 0) <= time.time()

    def set_skipped(self, key, on):
        """勾 / 取消「此版本不再提示」：当场记下，直接关窗口也算"""
        def change(data):
            skipped = [k for k in data["mobile"].get("updateSkipped") or [] if k != key] + ([key] if on else [])
            data["mobile"]["updateSkipped"] = skipped[-10:]   # 只留最近的几个：换了版本的旧键不会再用到
        if key:
            self.app.cfg.update(change)
        return {"ok": True}

    def mark_shown(self, key):
        """弹过了（自动弹的、自己点开的都算）：24 小时内不再自动弹"""
        now = time.time()
        def change(data):
            snoozed = {k: v for k, v in (data["mobile"].get("updateSnoozed") or {}).items() if float(v or 0) > now}
            snoozed[key] = now + SNOOZE
            data["mobile"]["updateSnoozed"] = snoozed
        if key:
            self.app.cfg.update(change)
        return {"ok": True}

    def auto(self):
        """自动更新开着（设置里）且这台能自动装"""
        return self.supported and bool(self.app.cfg.mobile.get("autoUpdate", True))

    def expected_size(self):
        """从这台的版本更新过去大概要下载多少：差量算得出来就用差量的，不然是整个安装包"""
        release = self.release or {}
        files = release.get("files") or {}
        return int((files.get("from") or {}).get(self.app.version) or release.get("size") or 0)

    def _set(self, phase, **fields):
        with self._lock:
            if phase is not None:
                self.phase = phase
            for key, value in fields.items():
                setattr(self, key, value)
        if self.app.on_update_change:
            try:
                self.app.on_update_change()
            except Exception:  # noqa: BLE001
                pass

    # MARK: 检查

    def start(self):
        if os.environ.get("KITELINE_CONFIG_DIR") and not os.environ.get("KITELINE_UPDATE_URL"):
            return   # 隔离测试实例不去查官网
        threading.Thread(target=self._loop, daemon=True, name="updater").start()
        threading.Thread(target=self._idle_loop, daemon=True, name="updater-idle").start()

    def _loop(self):
        time.sleep(FIRST_CHECK)
        while True:
            if self.phase in ("idle", "none", "available", "error"):
                self.check()
            time.sleep(CHECK_EVERY)

    def _idle_loop(self):
        """每分钟：自动更新开着、发现了新版本还没下的 → 后台下载（设置里刚打开自动更新也走这里）；装好了 → 看空不空闲，空闲就重启"""
        tick = float(os.environ.get("KITELINE_UPDATE_IDLE_TICK") or IDLE_TICK)
        while True:
            time.sleep(tick)
            try:
                if self.phase == "available" and self.auto():
                    log.write("自动更新：开始在后台下载 %s" % (self.release or {}).get("version"))
                    self.begin(auto=True)
                elif self.phase == "ready":
                    self._try_idle_restart()
            except Exception as exc:  # noqa: BLE001
                log.write("自动更新：%s" % exc)

    def idle_blocker(self):
        """现在不能自动重启的原因；None = 可以"""
        if self.phase != "ready" or not self.staged:
            return "新版本还没有装好"
        if not self.auto():
            return "自动更新已关闭"
        from .idleclose import user_idle
        if user_idle() < float(os.environ.get("KITELINE_UPDATE_IDLE") or IDLE_NEEDED):
            return "电脑有人在用"
        records = list(getattr(self.app.store, "records", []) or [])
        if any(r.activity == "waiting" for r in records):
            return "有会话在等待确认"
        if any(r.activity == "busy" for r in records) and time.time() - (self.ready_since or time.time()) < BUSY_PATIENCE:
            return "有会话正在运行"
        recent = (time.time() - PHONE_RECENT) * 1000
        for device in self.app.devices.all:
            client = device.get("client") or ""
            if (client.startswith("ios/") or client == "miniprogram") and float(device.get("lastSeen") or 0) > recent:
                return "手机正在查看"
        return None

    def _try_idle_restart(self):
        blocker = self.idle_blocker()
        if blocker:
            if blocker != self.waiting_for:
                log.write("自动更新：新版本 %s 已装好，等待空闲（%s）" % ((self.release or {}).get("version"), blocker))
                self._set(None, waiting_for=blocker)
            return
        log.write("自动更新：电脑空闲，重启换上新版本 %s" % (self.release or {}).get("version"))
        self.restart(auto=True)

    def check(self):
        """查一次；正在下载、装好待重启时不打断"""
        with self._lock:
            if self.phase in ("checking", "downloading", "installing", "ready", "restarting"):
                return self.state()
            previous = self.phase
            self.phase = "checking"
        try:
            request = urllib.request.Request(self.url(), headers={"User-Agent": "Kiteline/%s (%s)" % (self.app.version, self.platform),
                                                                  "Cache-Control": "no-cache"})
            with urllib.request.urlopen(request, timeout=20) as response:
                data = json.loads(response.read().decode("utf-8"))
            release = (data.get("platforms") or {}).get(self.platform)
            self.checked_at = time.time()
            if release and release.get("url") and newer(release.get("version"), self.app.version):
                version = release.get("version")
                fresh = not self.release or self.release.get("version") != version
                if fresh:
                    log.write("发现新版本 %s（当前 %s）" % (version, self.app.version))
                behind = len({parse_version(v) for v in release.get("versions") or [] if newer(v, self.app.version) and not newer(v, version)})
                self._set("available", release=release, error="", behind=behind, **({"history": []} if fresh else {}))
                if fresh:
                    threading.Thread(target=self._fetch_history, args=(version,), daemon=True, name="updater-notes").start()
                if self.auto():
                    # 自动更新：不弹窗，直接在后台下载装好
                    log.write("自动更新：开始在后台下载 %s" % version)
                    self.begin(auto=True)
            else:
                self._set("none", release=None, error="", history=[], behind=0)
            threading.Thread(target=self._check_phones, daemon=True, name="updater-phones").start()
        except Exception as exc:  # noqa: BLE001
            log.write("检查更新失败：%s" % exc)
            # 查不到不算错：之前发现过的新版本照旧显示
            self._set("available" if previous == "available" else "error", error="无法连接更新服务器")
        return self.state()

    def _fetch_history(self, version):
        """落后的这几版各自的更新内容：官网 latest.json 旁边的 notes-desktop.json（relay/download.sh 发布时写，最近十几版）；
        旧的官网没有这个文件，就只显示新版本这一版的"""
        url = self.url().rsplit("/", 1)[0] + "/notes-desktop.json"
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "Kiteline/%s (%s)" % (self.app.version, self.platform)})
            with urllib.request.urlopen(request, timeout=20) as response:
                items = json.loads(response.read().decode("utf-8")).get("releases") or []
        except Exception:  # noqa: BLE001
            return
        picked = [{"version": str(i.get("version")), "date": str(i.get("date") or ""), "notes": str(i.get("notes") or ""),
                   "notesEn": str(i.get("notesEn") or "")}
                  for i in items if isinstance(i, dict) and newer(i.get("version"), self.app.version) and not newer(i.get("version"), version)
                  and (i.get("notes") or i.get("notesEn"))]
        picked.sort(key=lambda i: parse_version(i["version"]), reverse=True)
        with self._lock:
            if (self.release or {}).get("version") != version:
                return
        self._set(None, history=picked[:8])

    # MARK: 手机端的新版本

    def _check_phones(self):
        """配对过的 iPhone / iPad 有没有比 App Store 上旧的：App Store 六小时问一次，设备每次检查都重新看（手机升级了就收起）"""
        fake = os.environ.get("KITELINE_STORE_LOOKUP")
        if fake or time.time() - self.store_checked >= STORE_EVERY:
            self.store_checked = time.time()
            region = ((locale.getlocale()[0] or "").split("_") + ["", ""])[1].lower() or "cn"
            for country in ([region] if region == "cn" else [region, "cn"]) if not fake else [""]:
                url = fake or "https://itunes.apple.com/lookup?bundleId=%s&country=%s" % (IOS_BUNDLE, country)
                try:
                    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "Kiteline/%s" % self.app.version}), timeout=20) as response:
                        results = json.loads(response.read().decode("utf-8")).get("results") or []
                except Exception:  # noqa: BLE001
                    self.store_checked = 0 if not fake else self.store_checked
                    break
                if results and results[0].get("version"):
                    first = results[0]
                    self.store = {"version": str(first["version"]), "notes": str(first.get("releaseNotes") or ""),
                                  "minimumOS": str(first.get("minimumOsVersion") or "")}
                    break
        self._evaluate_phones()

    def _evaluate_phones(self):
        store = self.store
        devices = []
        if store:
            recent = time.time() * 1000 - 30 * 86_400_000
            for device in self.app.devices.all:
                client = device.get("client") or ""
                # 最近 30 天用过的手机：「ios/1.6 (iPhone13,2; iOS 18.7.8)」→ App 1.6、系统 18.7.8；系统低于新版本要求的装不上，不算
                if float(device.get("lastSeen") or 0) < recent or not client.startswith("ios/"):
                    continue
                app = client[4:].split(" ", 1)[0]
                system = (re.search(r"iOS ([0-9.]+)", client) or [None, ""])[1]
                if not app[:1].isdigit() or not newer(store["version"], app):
                    continue
                if store["minimumOS"] and system and newer(store["minimumOS"], system):
                    continue
                devices.append({"name": device.get("name") or "", "version": app})
        phones = {"version": store["version"], "notes": store["notes"], "devices": devices} if devices else None
        if phones != self.phones:
            self._set(None, phones=phones)

    # MARK: 手机上看这台电脑的更新（/api/host-update）

    def host_payload(self):
        """同 Mac 版 Updater.payload()：手机一套代码看两种电脑。更新内容两种语言都给，手机按自己的界面语言挑"""
        payload = self.state()
        release = self.release or {}
        payload.update({"notes": release.get("notes") or "", "notesEn": release.get("notesEn") or ""})
        for key in ("phones", "prompt", "skipped", "key", "checkedAt", "restartNeeded"):
            payload.pop(key, None)
        return payload

    def remote(self, action):
        """手机上点的：check 现在查、start 下载并安装、cancel 取消下载、restart 重启换上新版本"""
        if action == "check":
            threading.Thread(target=self.check, daemon=True, name="updater-check").start()
            time.sleep(0.2)
        elif action == "start":
            if not self.supported:
                return dict(self.host_payload(), ok=False, error="%s，请在电脑上到官网下载新版本" % self.reason)
            log.write("手机上点了更新电脑端 Kiteline %s" % (self.release or {}).get("version"))
            result = self.begin()
            if not result.get("ok"):
                return dict(self.host_payload(), ok=False, error=result.get("error") or "更新失败")
        elif action == "cancel":
            self.cancel()
        elif action == "restart":
            log.write("手机上点了重启电脑端 Kiteline 以完成更新")
            result = self.restart()
            if not result.get("ok"):
                return dict(self.host_payload(), ok=False, error=result.get("error") or "重启失败")
        else:
            return {"ok": False, "error": "未知操作"}
        return self.host_payload()

    # MARK: 下载、安装

    def begin(self, auto=False):
        """后台下载 + 静默安装，进度看 state()。auto：自动更新开始的（装好了不弹窗、等空闲自动重启）"""
        with self._lock:
            if not self.supported:
                return {"ok": False, "error": self.reason}
            if self.phase not in ("available", "error") or not self.release:
                return {"ok": self.phase in ("downloading", "installing", "ready"), "error": "" if self.phase in ("downloading", "installing", "ready") else "没有可用的更新"}
            self.phase = "downloading"
            self.received = 0
            self.total = 0
            self.error = ""
            self.silent = auto
            self._cancel.clear()
        self._worker = threading.Thread(target=self._download_and_install, daemon=True, name="updater-install")
        self._worker.start()
        return {"ok": True}

    def cancel(self):
        if self.phase == "downloading":
            self._cancel.set()
        return {"ok": True}

    def _download_and_install(self):
        release = self.release
        files = release.get("files") or {}
        if files.get("url") and files.get("sha256") and release.get("version") not in self.delta_failed:
            try:
                os.makedirs(self.directory, exist_ok=True)
                self._cleanup()
                tree = self._build_delta(files, release.get("version"))
                self._set("installing")
                self.staged = self._finish_windows(tree) if config.IS_WINDOWS else self._finish_linux(tree)
                log.write("新版本 %s 已装好（差量，下载 %d 字节），重启后生效" % (release.get("version"), self.received))
                self._set("ready", ready_since=time.time(), waiting_for="")
                return
            except Cancelled:
                self._cleanup()
                self._set("available", received=0, error="")
                return
            except Exception as exc:  # noqa: BLE001
                log.write("差量更新没成功（%s），改为下载整个安装包" % exc)
                self.delta_failed.add(release.get("version"))
                self._set(None, received=0)
        try:
            os.makedirs(self.directory, exist_ok=True)
            self._cleanup()
            self._set(None, total=int(release.get("size") or 0), received=0)
            name = os.path.basename(release.get("file") or release["url"].rsplit("/", 1)[-1])
            archive = os.path.join(self.directory, name)
            self._download(release["url"], archive, int(release.get("size") or 0), release.get("sha256", ""))
            self._set("installing")
            self.staged = self._stage_windows(archive) if config.IS_WINDOWS else self._stage_linux(archive)
            os.remove(archive)
            log.write("新版本 %s 已装好，重启后生效" % release.get("version"))
            self._set("ready", ready_since=time.time(), waiting_for="")
        except Cancelled:
            self._cleanup()
            self._set("available", received=0, error="")
        except Exception as exc:  # noqa: BLE001
            log.write("更新失败：%s" % exc)
            self._cleanup()
            self._set("error", error=str(exc) or "更新失败")

    # MARK: 差量更新

    def _local_roots(self):
        """本机这份 Kiteline 的文件在哪：Windows 是 Kiteline.exe 所在的文件夹；Linux 是安装目录（虚拟环境、更新目录除外）"""
        if config.IS_WINDOWS:
            return [self.app_dir()], set()
        home = self.install_home()
        return [home], {os.path.join(home, "venv")}

    def _build_delta(self, files, version):
        """拼出新版本（和安装包解开后的目录一样），返回那个目录。清单格式见 tools/release/delta.py：
        本机有同样内容的文件（按 SHA-256 认，不管在哪个路径）直接拷，变了的文件有从本机某个文件出发的补丁就下补丁打上，
        没有就下整个文件（gzip）；每个文件都核对 SHA-256。出错抛异常（调用方退回下载整包）"""
        data = self._get(files["url"], limit=32 << 20)
        if hashlib.sha256(data).hexdigest() != str(files["sha256"]).lower():
            raise RuntimeError("文件清单校验失败")
        manifest = json.loads(data.decode("utf-8"))
        if manifest.get("format") != 1 or not isinstance(manifest.get("files"), list):
            raise RuntimeError("文件清单格式不对")
        entries = manifest["files"]
        for item in entries + (manifest.get("links") or []):
            _check_rel(item.get("p") or "")
        # 本机的文件：只算大小对得上的（新版本的文件、补丁的出发文件），按 SHA-256 建索引
        sizes = {int(e.get("n") or 0) for e in entries} | {int(d.get("n") or 0) for e in entries for d in e.get("d") or []}
        roots, skip = self._local_roots()
        local = {}
        for root in roots:
            for folder, dirs, names in os.walk(root):
                dirs[:] = [d for d in dirs if os.path.join(folder, d) not in skip and d != "__pycache__"]
                for name in names:
                    if self._cancel.is_set():
                        raise Cancelled()
                    path = os.path.join(folder, name)
                    try:
                        if os.path.islink(path) or os.path.getsize(path) not in sizes:
                            continue
                        local.setdefault(_sha256_file(path), path)
                    except OSError:
                        continue
        plan, total = [], 0
        for e in entries:
            h = str(e["h"]).lower()
            if h in local:
                plan.append((e, "local", local[h], 0))
                continue
            patch = next((d for d in e.get("d") or [] if str(d.get("f")).lower() in local), None)
            if patch:
                plan.append((e, "patch", patch, int(patch.get("z") or 0)))
                total += int(patch.get("z") or 0)
            else:
                plan.append((e, "blob", None, int(e.get("z") or 0)))
                total += int(e.get("z") or 0)
        self._set(None, total=total, received=0)
        downloads = sum(1 for p in plan if p[1] != "local")
        log.write("差量更新 %s：%d 个文件，本机已有 %d 个，要下载 %d 个、共 %d 字节" % (version, len(entries), len(entries) - downloads, downloads, total))
        base = files["url"].rsplit("/", 2)[0]   # …/download/delta
        tree = os.path.join(self.directory, "stage", os.path.basename(manifest.get("root") or "Kiteline"))
        os.makedirs(tree, exist_ok=True)
        for rel in manifest.get("dirs") or []:
            os.makedirs(os.path.join(tree, *_check_rel(rel).split("/")), exist_ok=True)
        received = 0
        for e, kind, source, size in plan:
            if self._cancel.is_set():
                raise Cancelled()
            h = str(e["h"]).lower()
            out = os.path.join(tree, *e["p"].split("/"))
            os.makedirs(os.path.dirname(out), exist_ok=True)
            if kind == "local":
                shutil.copyfile(source, out)
            else:
                url = "%s/patches/%s-%s.bsdiff" % (base, str(source["f"]).lower(), h) if kind == "patch" else "%s/blobs/%s.gz" % (base, h)
                body = self._get(url, limit=size + 1 if size else 512 << 20, progress=received)
                if size and len(body) != size:
                    raise RuntimeError("下载不完整：%s" % e["p"])
                received += len(body)
                if kind == "patch":
                    with open(local[str(source["f"]).lower()], "rb") as old:
                        content = bspatch(old.read(), body)
                else:
                    content = gzip.decompress(body)
                if hashlib.sha256(content).hexdigest() != h:
                    raise RuntimeError("文件校验失败：%s" % e["p"])
                with open(out, "wb") as handle:
                    handle.write(content)
            if _sha256_file(out) != h:
                raise RuntimeError("文件校验失败：%s" % e["p"])
            if not config.IS_WINDOWS:
                os.chmod(out, 0o755 if e.get("x") else 0o644)
        for link in manifest.get("links") or []:
            target = str(link.get("t") or "")
            if target.startswith("/") or config.IS_WINDOWS:
                raise RuntimeError("文件清单里有异常链接")
            os.symlink(target, os.path.join(tree, *link["p"].split("/")))
        return tree

    def _get(self, url, limit, progress=None):
        """下载一个小文件读进内存（清单、补丁、文件块）；progress 给了就边下边更新进度"""
        request = urllib.request.Request(url, headers={"User-Agent": "Kiteline/%s (%s; delta)" % (self.app.version, self.platform)})
        chunks, got, last = [], 0, 0
        with urllib.request.urlopen(request, timeout=60) as response:
            while True:
                if self._cancel.is_set():
                    raise Cancelled()
                chunk = response.read(256 * 1024)
                if not chunk:
                    break
                chunks.append(chunk)
                got += len(chunk)
                if got > limit:
                    raise RuntimeError("下载的内容过大：%s" % url.rsplit("/", 1)[-1])
                if progress is not None and time.time() - last > 0.2:
                    last = time.time()
                    with self._lock:
                        self.received = progress + got
        if progress is not None:
            with self._lock:
                self.received = progress + got
        return b"".join(chunks)

    def _download(self, url, target, size, sha256):
        partial = target + ".part"
        digest = hashlib.sha256()
        request = urllib.request.Request(url, headers={"User-Agent": "Kiteline/%s (%s)" % (self.app.version, self.platform)})
        try:
            response = urllib.request.urlopen(request, timeout=30)
        except Exception as exc:  # noqa: BLE001
            raise RuntimeError("下载失败：无法连接更新服务器") from exc
        with response, open(partial, "wb") as handle:
            total = size or int(response.headers.get("Content-Length") or 0)
            if total and not size:
                with self._lock:
                    self.release = dict(self.release, size=total)
            received = 0
            last = 0
            while True:
                if self._cancel.is_set():
                    raise Cancelled()
                chunk = response.read(256 * 1024)
                if not chunk:
                    break
                handle.write(chunk)
                digest.update(chunk)
                received += len(chunk)
                now = time.time()
                if now - last > 0.2:
                    last = now
                    with self._lock:
                        self.received = received
        with self._lock:
            self.received = received
        if size and received != size:
            raise RuntimeError("下载不完整，请重试")
        if sha256 and digest.hexdigest().lower() != sha256.lower():
            raise RuntimeError("安装包校验失败，请重试")
        os.replace(partial, target)

    def _stage_windows(self, archive):
        """解压到更新目录，核对里面有 Kiteline.exe；真正换文件在重启时做（运行中的 exe 和 dll 换不掉）"""
        stage = os.path.join(self.directory, "stage")
        with zipfile.ZipFile(archive) as bundle:
            for member in bundle.namelist():
                if member.startswith("/") or ".." in member.replace("\\", "/").split("/"):
                    raise RuntimeError("安装包内容异常")
            bundle.extractall(stage)
        return self._finish_windows(stage)

    def _finish_windows(self, stage):
        found = _find(stage, "Kiteline.exe")
        if not found:
            raise RuntimeError("安装包里没有 Kiteline.exe")
        parent = os.path.dirname(self.app_dir())
        if not os.access(parent, os.W_OK):
            raise RuntimeError("没有写入 %s 的权限，请手动下载安装" % parent)
        return os.path.dirname(found)

    def _stage_linux(self, archive):
        """解压，把新版本的依赖先装进现有虚拟环境（慢的那步趁现在做）；换文件留到重启时（几秒钟）"""
        stage = os.path.join(self.directory, "stage")
        with tarfile.open(archive, "r:gz") as bundle:
            members = bundle.getmembers()
            for member in members:
                if member.name.startswith("/") or ".." in member.name.split("/") or member.issym() or member.islnk() or member.isdev():
                    raise RuntimeError("安装包内容异常")
            bundle.extractall(stage, members=members)
        return self._finish_linux(stage)

    def _finish_linux(self, stage):
        installer = _find(stage, "install-linux.sh")
        if not installer:
            raise RuntimeError("安装包里没有 install-linux.sh")
        package = os.path.dirname(os.path.dirname(installer))
        home = self.install_home()
        pip = os.path.join(home, "venv", "bin", "pip")
        lock = os.path.join(os.path.dirname(installer), "requirements.lock")
        mirror = os.environ.get("PIP_INDEX_URL") or "https://pypi.tuna.tsinghua.edu.cn/simple"
        result = subprocess.run([pip, "install", "-q", "--require-hashes", "-r", lock, "-i", mirror],
                                capture_output=True, text=True, timeout=900)
        if result.returncode != 0:
            log.write("更新：安装依赖失败：%s" % (result.stderr or result.stdout)[-800:])
            raise RuntimeError("安装依赖失败，请检查网络后重试")
        return package

    def _cleanup(self):
        shutil.rmtree(os.path.join(self.directory, "stage"), ignore_errors=True)
        try:
            for name in os.listdir(self.directory):
                if name.endswith(".part") or name.endswith(".zip") or name.endswith(".tar.gz"):
                    os.remove(os.path.join(self.directory, name))
        except OSError:
            pass
        self.staged = None

    # MARK: 重启

    def restart(self, client=None, auto=False):
        """auto：空闲时自动重启的（只记日志，流程一样：后台带 --background 起，原来开着的客户端照样重新打开）。
        装好后重启：起一个独立的小脚本，等这份 Kiteline（和客户端）退出、换上新文件、再启动；然后这份退出。
        client = {"pid": 客户端进程号, "exe": 客户端程序路径, "args": [...]}：客户端自己随后退出，由脚本重新打开"""
        if self.phase != "ready" or not self.staged:
            return {"ok": False, "error": "没有待安装的更新"}
        client = client if isinstance(client, dict) and client.get("pid") else self.client
        if client.get("pid") and not _alive(int(client["pid"])):
            client = {}
        try:
            if config.IS_WINDOWS:
                self._restart_windows(client)
            else:
                self._restart_linux(client)
        except Exception as exc:  # noqa: BLE001
            log.write("更新：启动重启脚本失败：%s" % exc)
            return {"ok": False, "error": "重启失败：%s" % exc}
        log.write("更新：重启以换上新版本 %s" % (self.release or {}).get("version"))
        # 客户端看到 restarting 自己退出（脚本等它退了再换文件、再打开）
        self._set("restarting")
        threading.Timer(1.5, self.app.request_exit).start()
        return {"ok": True}

    def install_on_quit(self):
        """退出 Kiteline 时（托盘「退出」、注销关机）：新版本装好了但没点「立即重启」的（点了「稍后」），这时换上，
        下次打开就是新版本，不再启动（同 Mac 版 installIfPendingOnQuit）"""
        if self.phase != "ready" or not self.staged:
            return
        client = self.client if self.client.get("pid") and _alive(int(self.client["pid"])) else {}
        log.write("更新：退出时换上新版本 %s" % (self.release or {}).get("version"))
        try:
            if config.IS_WINDOWS:
                self._restart_windows(client, relaunch=False)
            else:
                self._restart_linux(client, relaunch=False)
        except Exception as exc:  # noqa: BLE001
            log.write("更新：退出时换上新版本失败：%s" % exc)

    def _restart_windows(self, client, relaunch=True):
        """relaunch=False：退出时换版本，换完不启动；开着的客户端先请它关掉（运行中的文件换不掉）"""
        app_dir = self.app_dir()
        pids = [os.getpid()] + ([int(client["pid"])] if client.get("pid") else [])
        client_exe = client.get("exe") or ""
        close_client = "try { (Get-Process -Id %d).CloseMainWindow() | Out-Null } catch {}" % int(client["pid"]) if client.get("pid") and not relaunch else ""
        # 客户端在 Kiteline 文件夹里时，换完从新位置启动
        relaunch_client = ""
        if client_exe and relaunch:
            rel = os.path.relpath(client_exe, app_dir) if os.path.normcase(client_exe).startswith(os.path.normcase(app_dir + os.sep)) else None
            target = "Join-Path $app %s" % _ps(rel) if rel else _ps(client_exe)
            relaunch_client = "$c = %s; if (Test-Path $c) { Start-Process -FilePath $c%s }" % (
                target, (" -ArgumentList " + ",".join(_ps(a) for a in client.get("args") or [])) if client.get("args") else "")
        script = "\r\n".join([
            "$ErrorActionPreference = 'SilentlyContinue'",
            "$app = %s" % _ps(app_dir),
            "$new = %s" % _ps(self.staged),
            "$old = $app + '.old'",
            "$log = %s" % _ps(os.path.join(self.directory, "update.log")),
            "function Note($t) { Add-Content -Path $log -Value ((Get-Date -Format s) + ' ' + $t) -Encoding UTF8 }",
            "Note 'waiting for Kiteline to quit'",
            close_client,
            "foreach ($id in @(%s)) { Wait-Process -Id $id -Timeout 60 }" % ",".join(str(p) for p in pids),
            # watcher 子进程也是 Kiteline.exe：都退了才换得动
            "for ($i = 0; $i -lt 30; $i++) {",
            "  $left = @(Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($app + '\\', [StringComparison]::OrdinalIgnoreCase) })",
            "  if ($left.Count -eq 0) { break }",
            "  if ($i -eq 20) { $left | Stop-Process -Force }",
            "  Start-Sleep -Milliseconds 500",
            "}",
            "if (Test-Path $old) { Remove-Item -Recurse -Force $old }",
            "$moved = $false",
            "for ($i = 0; $i -lt 20; $i++) { try { Move-Item -LiteralPath $app -Destination $old -ErrorAction Stop; $moved = $true; break } catch { Start-Sleep -Milliseconds 500 } }",
            "if ($moved) {",
            "  try { Move-Item -LiteralPath $new -Destination $app -ErrorAction Stop; Note 'new version in place' }",
            "  catch { Note ('replacing failed: ' + $_); Move-Item -LiteralPath $old -Destination $app }",
            "} else { Note 'old files busy, not replaced' }",
            "Start-Process -FilePath (Join-Path $app 'Kiteline.exe') -ArgumentList '--background'" if relaunch else "",
            relaunch_client,
            "Start-Sleep -Seconds 3",
            "if (Test-Path $old) { Remove-Item -Recurse -Force $old }",
            "Remove-Item -Recurse -Force (Split-Path -Parent $new)",
        ])
        path = os.path.join(self.directory, "apply-update.ps1")
        with open(path, "w", encoding="utf-8-sig", newline="") as handle:   # PowerShell 5.1 读不带 BOM 的 UTF-8 会把中文读乱
            handle.write(script + "\r\n")
        command = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", path]
        # CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP。别用 DETACHED_PROCESS：没有控制台的 PowerShell 一启动就退出（10-23 实测）
        flags = 0x08000000 | 0x00000200
        try:
            # 在作业对象里（计划任务、某些启动器）时尽量脱离出来；不允许脱离就照常起（实测 Kiteline 退出后脚本照样跑完）
            subprocess.Popen(command, creationflags=flags | 0x01000000, close_fds=True, cwd=self.directory)
        except OSError:
            subprocess.Popen(command, creationflags=flags, close_fds=True, cwd=self.directory)

    def _restart_linux(self, client, relaunch=True):
        """relaunch=False：退出时换版本，换完不启动（Linux 上运行中的客户端不妨碍换文件，下次打开就是新版本）"""
        home = self.install_home()
        installer = os.path.join(self.staged, "desktop", "install-linux.sh")
        pids = [os.getpid()] + ([int(client["pid"])] if client.get("pid") else [])
        unit = _systemd_unit()
        service = unit == "kiteline.service"   # install.sh --service 装成的 systemd 用户服务
        start = "systemctl --user start kiteline.service" if service else \
            "cd %s && setsid nohup %s -m kiteline --background >/dev/null 2>&1 &" % (_sh(home), _sh(os.path.join(home, "venv", "bin", "python")))
        if not relaunch:
            start, pids = "", [os.getpid()]
        relaunch_client = ""
        if client.get("exe") and relaunch:
            relaunch_client = "c=%s; [ -x \"$c\" ] && setsid nohup \"$c\" %s >/dev/null 2>&1 &" % (_sh(client["exe"]), " ".join(_sh(a) for a in client.get("args") or []))
        script = "\n".join([
            "#!/usr/bin/env bash",
            "log=%s" % _sh(os.path.join(self.directory, "update.log")),
            "note() { echo \"$(date -Is) $*\" >> \"$log\"; }",
            "note 'waiting for Kiteline to quit'",
            "for pid in %s; do for i in $(seq 1 120); do kill -0 \"$pid\" 2>/dev/null || break; sleep 0.5; done; done" % " ".join(str(p) for p in pids),
            "if KITELINE_HOME=%s bash %s --update >> \"$log\" 2>&1; then note 'new version in place'; else note 'replacing failed'; fi" % (_sh(home), _sh(installer)),
            start,
            relaunch_client,
            "sleep 2",
            "rm -rf %s" % _sh(os.path.join(self.directory, "stage")),
        ])
        path = os.path.join(self.directory, "apply-update.sh")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(script + "\n")
        os.chmod(path, 0o700)
        if unit and unit.endswith(".service") and shutil.which("systemd-run"):
            # 在 systemd 服务里跑的：服务主进程一退，同组的进程会被一起结束。脚本放进单独的 scope（不随脚本结束被清掉，
            # 它启动的新版本、客户端也留在里面；环境变量照旧继承）
            subprocess.Popen(["systemd-run", "--user", "--scope", "--collect", "--quiet", "--unit", "kiteline-update-%d" % int(time.time()), "bash", path],
                             start_new_session=True, close_fds=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            subprocess.Popen(["bash", path], start_new_session=True, close_fds=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


class Cancelled(Exception):
    pass


def _check_rel(rel):
    """清单里的路径只能在新版本目录里面：不能是绝对路径、不能有 .."""
    rel = str(rel)
    if not rel or rel.startswith(("/", "\\")) or ".." in rel.replace("\\", "/").split("/") or ":" in rel:
        raise RuntimeError("文件清单里有异常路径")
    return rel


def _sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _offtin(buf, pos):
    """bsdiff 的 64 位整数：小端、最高位是符号位"""
    value = int.from_bytes(buf[pos:pos + 8], "little")
    return -(value & 0x7FFFFFFFFFFFFFFF) if value & (1 << 63) else value


def _add_bytes(a, b):
    """逐字节相加（各自 mod 256，不进位）：整段当大整数一次算完，比逐字节循环快几十倍"""
    n = len(a)
    if not n:
        return b""
    low = int.from_bytes(b"\x7f" * n, "little")
    high = int.from_bytes(b"\x80" * n, "little")
    x, y = int.from_bytes(a, "little"), int.from_bytes(b, "little")
    return (((x & low) + (y & low)) ^ ((x ^ y) & high)).to_bytes(n, "little")


def bspatch(old, patch):
    """打 bsdiff（BSDIFF40 格式，tools/release/delta.py 用 bsdiff4 生成，同 macOS 自带的 bspatch）补丁，返回新文件内容"""
    if patch[:8] != b"BSDIFF40" or len(patch) < 32:
        raise RuntimeError("补丁格式不对")
    ctrl_len, diff_len, new_size = _offtin(patch, 8), _offtin(patch, 16), _offtin(patch, 24)
    if ctrl_len < 0 or diff_len < 0 or new_size < 0 or new_size > 1 << 31:
        raise RuntimeError("补丁格式不对")
    ctrl = bz2.decompress(patch[32:32 + ctrl_len])
    diff = bz2.decompress(patch[32 + ctrl_len:32 + ctrl_len + diff_len])
    extra = bz2.decompress(patch[32 + ctrl_len + diff_len:])
    out = bytearray()
    old_pos = diff_pos = extra_pos = 0
    old_size = len(old)
    for i in range(0, len(ctrl) - 23, 24):
        x, y, z = _offtin(ctrl, i), _offtin(ctrl, i + 8), _offtin(ctrl, i + 16)
        if x < 0 or y < 0 or len(out) + x + y > new_size:
            raise RuntimeError("补丁内容异常")
        chunk = diff[diff_pos:diff_pos + x]
        if len(chunk) != x:
            raise RuntimeError("补丁内容异常")
        # 旧文件里超出范围的字节当 0（同 bspatch.c）
        start, end = max(old_pos, 0), min(old_pos + x, old_size)
        base = bytearray(x)
        if end > start:
            base[start - old_pos:end - old_pos] = old[start:end]
        out += _add_bytes(bytes(base), chunk)
        diff_pos += x
        old_pos += x
        piece = extra[extra_pos:extra_pos + y]
        if len(piece) != y:
            raise RuntimeError("补丁内容异常")
        out += piece
        extra_pos += y
        old_pos += z
    if len(out) != new_size:
        raise RuntimeError("补丁内容异常")
    return bytes(out)


def _alive(pid):
    if config.IS_WINDOWS:
        import ctypes
        kernel32 = ctypes.windll.kernel32
        handle = kernel32.OpenProcess(0x1000, False, pid)   # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            return False
        code = ctypes.c_ulong()
        kernel32.GetExitCodeProcess(handle, ctypes.byref(code))
        kernel32.CloseHandle(handle)
        return code.value == 259   # STILL_ACTIVE
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _systemd_unit():
    """这个进程所在的 systemd 单元（kiteline.service、app-gnome-kiteline-123.scope……），不在 systemd 下返回 None"""
    try:
        with open("/proc/self/cgroup", encoding="utf-8") as handle:
            for line in handle:
                for part in reversed(line.strip().split(":", 2)[-1].split("/")):
                    if part.endswith(".service") or part.endswith(".scope"):
                        return part
    except OSError:
        pass
    return None


def _find(root, name):
    for folder, _dirs, files in os.walk(root):
        if name in files:
            return os.path.join(folder, name)
    return None


def _ps(text):
    """PowerShell 单引号字符串"""
    return "'" + str(text).replace("'", "''") + "'"


def _sh(text):
    return "'" + str(text).replace("'", "'\\''") + "'"
