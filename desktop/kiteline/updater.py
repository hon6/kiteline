"""检查更新、下载、静默安装、重启（同 Mac 版 Sources/Updater.swift）。

新版本信息在官网下载页的 latest.json（relay/download.sh 发布时写）：platforms.windows / platforms.linux 里有
version、url、size、sha256，notes / notesEn 是这一版的更新说明。

流程：启动 30 秒后查一次、之后每小时查一次 → 有新版本时客户端右上角出绿色箭头 → 用户确认后下载（带进度、核对 SHA-256）
→ 静默装好（Windows 解压到旁边待换；Linux 解压并把依赖装进现有虚拟环境）→ 提示重启 → 重启时由一个独立的小脚本
等 Kiteline（和客户端）退出、换上新文件、再把它们启动起来。

只有正式安装的版本能自动更新：Windows 是打包版（Kiteline.exe），Linux 是 install.sh 装在 ~/.local/share/kiteline 的；
直接从源码跑的开发版只检查、不安装。
"""

import hashlib
import json
import os
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
        self.dismissed = ""          # 用户点了「以后再说」的版本：托盘不再提醒（客户端的箭头照样在）
        self.client = {}             # 正在运行的客户端（启动时自己报上来）：从托盘、控制台重启时也把它关掉再打开
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
            return {"ok": True, "supported": self.supported, "reason": self.reason, "current": self.app.version,
                    "phase": self.phase, "version": release.get("version", ""), "notes": notes,
                    "size": int(release.get("size") or 0), "received": self.received, "error": self.error,
                    "checkedAt": int(self.checked_at * 1000), "page": self.app.cfg.relay().rstrip("/") + "/download",
                    "restartNeeded": self.phase == "ready"}

    def _set(self, phase, **fields):
        with self._lock:
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

    def _loop(self):
        time.sleep(FIRST_CHECK)
        while True:
            if self.phase in ("idle", "none", "available", "error"):
                self.check()
            time.sleep(CHECK_EVERY)

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
                if not self.release or self.release.get("version") != release.get("version"):
                    log.write("发现新版本 %s（当前 %s）" % (release.get("version"), self.app.version))
                self._set("available", release=release, error="")
            else:
                self._set("none", release=None, error="")
        except Exception as exc:  # noqa: BLE001
            log.write("检查更新失败：%s" % exc)
            # 查不到不算错：之前发现过的新版本照旧显示
            self._set("available" if previous == "available" else "error", error="无法连接更新服务器")
        return self.state()

    # MARK: 下载、安装

    def begin(self):
        """用户确认更新：后台下载 + 静默安装，进度看 state()"""
        with self._lock:
            if not self.supported:
                return {"ok": False, "error": self.reason}
            if self.phase not in ("available", "error") or not self.release:
                return {"ok": self.phase in ("downloading", "installing", "ready"), "error": "" if self.phase in ("downloading", "installing", "ready") else "没有可用的更新"}
            self.phase = "downloading"
            self.received = 0
            self.error = ""
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
        try:
            os.makedirs(self.directory, exist_ok=True)
            self._cleanup()
            name = os.path.basename(release.get("file") or release["url"].rsplit("/", 1)[-1])
            archive = os.path.join(self.directory, name)
            self._download(release["url"], archive, int(release.get("size") or 0), release.get("sha256", ""))
            self._set("installing")
            self.staged = self._stage_windows(archive) if config.IS_WINDOWS else self._stage_linux(archive)
            os.remove(archive)
            log.write("新版本 %s 已装好，重启后生效" % release.get("version"))
            self._set("ready")
        except Cancelled:
            self._cleanup()
            self._set("available", received=0, error="")
        except Exception as exc:  # noqa: BLE001
            log.write("更新失败：%s" % exc)
            self._cleanup()
            self._set("error", error=str(exc) or "更新失败")

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

    def restart(self, client=None):
        """装好后重启：起一个独立的小脚本，等这份 Kiteline（和客户端）退出、换上新文件、再启动；然后这份退出。
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
