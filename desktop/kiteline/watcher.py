"""来源：本机直接起 watcher 子进程（和 Mac 版 SourceLocal.swift 一样），或经 ssh 读远端 watcher。

watcher（watcher/kiteline-watch.py）读 ~/.claude 下的会话注册表和对话记录，以 JSON Lines 打到 stdout：
  hello / snapshots / entries / reset / heartbeat / error / response
请求从 stdin 进（每行一个 JSON，带 id），结果以 {"event":"response","id":...} 回来。
"""

import base64
import itertools
import json
import os
import shutil
import subprocess
import sys
import threading
import time

from . import config, log

WATCHER_NAME = "kiteline-watch.py"


class RemoteError(Exception):
    pass


def bundled_watcher():
    """打包在程序里的 watcher：PyInstaller 解包目录、或源码仓库里的 watcher/kiteline-watch.py"""
    candidates = []
    base = getattr(sys, "_MEIPASS", None)
    if base:
        candidates.append(os.path.join(base, WATCHER_NAME))
    here = os.path.dirname(os.path.abspath(__file__))
    candidates.append(os.path.join(here, WATCHER_NAME))
    candidates.append(os.path.join(here, "..", "..", "watcher", WATCHER_NAME))
    for item in candidates:
        if os.path.exists(item):
            return os.path.abspath(item)
    return None


# 配置里关了「为 OpenCode 安装 Kiteline 插件」：启动 watcher 时让它别装、并删掉装过的（app 按配置设置）
OPENCODE_PLUGIN = True


# Windows：ssh.exe 是控制台程序，打包版（没有控制台）里不加这个，每个 ssh 进程都会弹出一个黑色终端窗口、一直挂着
NO_WINDOW = {"creationflags": 0x08000000} if config.IS_WINDOWS else {}


# 设置 → 插件里关掉的（逗号分隔，plugins.PluginStore 按偏好设置）：watcher 不启用它们，并把装进 agent 里的东西删掉
PLUGINS_OFF = ""
# 默认不接（optIn）、用户在设置里自己打开了的（同上）
PLUGINS_ON = ""
# 用户打开了的插件单项开关「插件 id.开关 id」（同上；如 cursor.usage 查 Cursor 月用量）
PLUGIN_OPTIONS_ON = ""


def watcher_env():
    env = {} if OPENCODE_PLUGIN else {"CCPULSE_OPENCODE_PLUGIN": "0"}
    if PLUGINS_OFF:
        env["CCPULSE_PLUGINS_OFF"] = PLUGINS_OFF
    if PLUGINS_ON:
        env["CCPULSE_PLUGINS_ON"] = PLUGINS_ON
    if PLUGIN_OPTIONS_ON:
        env["CCPULSE_PLUGIN_OPTIONS_ON"] = PLUGIN_OPTIONS_ON
    return env


def python_command():
    """跑 watcher 用的 Python：打包版用自己（kiteline --run-script），源码版用当前解释器"""
    if getattr(sys, "frozen", False):
        return [sys.executable, "--run-script"]
    return [sys.executable]


class LocalSource:
    def __init__(self, source_config, on_event, on_state):
        self.config = source_config
        self.id = source_config["id"]
        self.name = source_config.get("name") or "本机"
        self.kind = "local"
        self._on_event = on_event
        self._on_state = on_state
        self.state = "stopped"          # stopped / connecting / live / failed
        self.state_detail = ""
        self.host = None
        self.platform = None            # watcher 报来的系统（sys.platform：linux / darwin / win32）
        self.watcher_version = None
        self.session_count = 0
        self.home = os.path.expanduser("~")
        self._proc = None
        self._stdin_lock = threading.Lock()
        self._pending = {}
        self._pending_lock = threading.Lock()
        self._counter = itertools.count(1)
        self._stopped = True
        self._last_event = time.time()
        self._restart_attempt = 0
        self._stderr_tail = []

    @property
    def live(self):
        return self.state == "live"

    def short_label(self):
        if self.state == "live":
            return "%s 在线 · %d 会话" % (self.host or "来源", self.session_count)
        if self.state == "connecting":
            return "连接中"
        if self.state == "failed":
            return "连接失败：%s" % self.state_detail
        return "未连接"

    def start(self):
        self._stopped = False
        self._restart_attempt = 0
        threading.Thread(target=self._launch, daemon=True).start()
        threading.Thread(target=self._watchdog, daemon=True).start()

    def stop(self):
        self._stopped = True
        proc, self._proc = self._proc, None
        if proc and proc.poll() is None:
            try:
                proc.terminate()
            except OSError:
                pass
        self._fail_all("watcher 通道已断开")
        self._set_state("stopped")

    # MARK: 进程

    def _script(self):
        bundled = bundled_watcher()
        if not bundled:
            return None
        target = os.path.expanduser(self.config.get("remoteWatcherPath") or "~/.ccpulse/ccpulse-watch.py")
        try:
            with open(bundled, "rb") as handle:
                text = handle.read()
            current = None
            if os.path.exists(target):
                with open(target, "rb") as handle:
                    current = handle.read()
            if current != text:
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with open(target, "wb") as handle:
                    handle.write(text)
                log.write("已释放本机 watcher 脚本 → %s" % target)
            return target
        except OSError as exc:
            log.write("释放 watcher 脚本失败：%s，直接读包内副本" % exc)
            return bundled

    def _launch(self):
        if self._stopped:
            return
        script = self._script()
        if not script:
            self._set_state("failed", "程序内缺少 ccpulse-watch.py")
            return
        self._set_state("connecting")
        env = dict(os.environ)
        env["PYTHONIOENCODING"] = "utf-8"
        env["PYTHONUTF8"] = "1"
        env.setdefault("LANG", "en_US.UTF-8")
        env.update(watcher_env())
        # 技能由 watcher 装到各家 agent 的技能目录：告诉它哪些开着（见 agent_skill）
        from . import agent_skill
        env.update(agent_skill.local_env(script))
        kwargs = {}
        if config.IS_WINDOWS:
            kwargs["creationflags"] = 0x08000000   # CREATE_NO_WINDOW：别弹黑框
        try:
            proc = subprocess.Popen(python_command() + [script], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, env=env, **kwargs)
        except OSError as exc:
            log.write("本机 watcher 启动失败：%s" % exc)
            self._schedule_restart(str(exc))
            return
        self._proc = proc
        self._last_event = time.time()
        self._stderr_tail = []
        log.write("本机 watcher 已启动（pid %d）" % proc.pid)
        threading.Thread(target=self._read_stderr, args=(proc,), daemon=True).start()
        self._read_stdout(proc)
        # stdout 读完 = 进程退出
        proc.wait()
        if self._proc is proc:
            self._proc = None
        self._fail_all("watcher 通道已断开")
        if self._stopped:
            return
        reason = self._stderr_tail[-1] if self._stderr_tail else "watcher 退出码 %s" % proc.returncode
        log.write("本机 watcher 退出：%s" % reason)
        self._schedule_restart(reason)

    def _schedule_restart(self, reason):
        if self._stopped:
            return
        self._restart_attempt += 1
        delay = min(30.0, 2.0 ** min(self._restart_attempt, 5))
        self._set_state("failed", reason)
        log.write("%d 秒后重启本机 watcher（第 %d 次）" % (delay, self._restart_attempt))

        def later():
            time.sleep(delay)
            self._launch()
        threading.Thread(target=later, daemon=True).start()

    def _watchdog(self):
        while not self._stopped:
            time.sleep(15)
            proc = self._proc
            if proc and proc.poll() is None and time.time() - self._last_event > 45:
                log.write("超过 45 秒没有心跳，重启本机 watcher")
                try:
                    proc.terminate()
                except OSError:
                    pass

    def _read_stderr(self, proc):
        for raw in iter(proc.stderr.readline, b""):
            line = raw.decode("utf-8", "replace").rstrip()
            if line:
                self._stderr_tail = (self._stderr_tail + [line])[-12:]
                if os.environ.get("KITELINE_WATCHER_DEBUG"):
                    log.write("[watcher] %s" % line)

    def _read_stdout(self, proc):
        for raw in iter(proc.stdout.readline, b""):
            raw = raw.strip()
            if not raw:
                continue
            try:
                event = json.loads(raw.decode("utf-8", "replace"))
            except ValueError:
                log.write("忽略无法解析的行：%s" % raw[:160])
                continue
            if not isinstance(event, dict) or "event" not in event:
                continue
            self._last_event = time.time()
            self._restart_attempt = 0
            kind = event["event"]
            if kind == "response":
                self._finish(event)
                continue
            if kind == "hello":
                self.home = event.get("home") or self.home
                self.host = event.get("host") or "本机"
                self.platform = event.get("platform") or self.platform
                self.watcher_version = event.get("watcher")
                self._set_state("live")
                log.write("本机 watcher v%s 就绪" % (self.watcher_version or "?"))
            if kind == "snapshots":
                self.session_count = len(event.get("sessions") or [])
            try:
                self._on_event(self, event)
            except Exception as exc:  # noqa: BLE001
                log.write("处理 watcher 事件 %s 出错：%r" % (kind, exc))

    def _set_state(self, state, detail=""):
        self.state, self.state_detail = state, detail
        try:
            self._on_state(self)
        except Exception as exc:  # noqa: BLE001
            log.write("来源状态回调出错：%r" % exc)

    # MARK: 请求

    def request(self, payload, timeout=30):
        """同步请求：返回 watcher 的应答字典；失败抛 RemoteError"""
        proc = self._proc
        if not proc or proc.poll() is not None:
            raise RemoteError("来源未连接")
        request_id = "r%d" % next(self._counter)
        body = dict(payload)
        body["id"] = request_id
        waiter = {"event": threading.Event(), "result": None}
        with self._pending_lock:
            self._pending[request_id] = waiter
        data = (json.dumps(body, ensure_ascii=False) + "\n").encode("utf-8")
        try:
            with self._stdin_lock:
                proc.stdin.write(data)
                proc.stdin.flush()
        except (OSError, ValueError) as exc:
            with self._pending_lock:
                self._pending.pop(request_id, None)
            raise RemoteError("写入 watcher 失败：%s" % exc)
        if not waiter["event"].wait(timeout):
            with self._pending_lock:
                self._pending.pop(request_id, None)
            raise RemoteError("请求超时（%d 秒）" % timeout)
        result = waiter["result"]
        if isinstance(result, Exception):
            raise result
        if not result.get("ok"):
            raise RemoteError(result.get("error") or "watcher 返回失败")
        return result

    def _finish(self, event):
        with self._pending_lock:
            waiter = self._pending.pop(event.get("id"), None)
        if waiter:
            waiter["result"] = event
            waiter["event"].set()

    def _fail_all(self, reason):
        with self._pending_lock:
            pending, self._pending = self._pending, {}
        for waiter in pending.values():
            waiter["result"] = RemoteError(reason)
            waiter["event"].set()


class SSHSource(LocalSource):
    """Remote-SSH 远端：ssh 过去跑远端的 watcher（第一次连时把脚本传过去）。和 Mac 版 RemoteSession 同一套约定"""

    def __init__(self, source_config, on_event, on_state):
        super().__init__(source_config, on_event, on_state)
        self.kind = "ssh"
        self.name = source_config.get("name") or source_config.get("sshHost") or "远端"

    def _sync_plugins(self, python):
        """本机下载的插件原样传到远端（远端不一定能上外网）：指纹不同才传；失败不影响连接，远端照用内置的"""
        from . import plugins
        data, fingerprint = plugins.bundle()
        try:
            current = subprocess.run(self._ssh() + [plugins.remote_check_command()], capture_output=True, timeout=20,
                                     **NO_WINDOW).stdout.decode("utf-8", "replace").strip()
            if current == fingerprint:
                return
            result = subprocess.run(self._ssh() + [plugins.remote_unpack_command(python, fingerprint)],
                                    input=base64.b64encode(data), capture_output=True, timeout=60, **NO_WINDOW)
            if b"PLUGINS_OK" not in result.stdout:
                raise RuntimeError(result.stderr.decode("utf-8", "replace").strip()[-200:] or "没有回应")
            log.write("已把插件同步到远端 %s（%s）" % (self.name, fingerprint))
        except (OSError, subprocess.SubprocessError, RuntimeError) as exc:
            log.write("同步插件到远端 %s 失败：%s" % (self.name, exc))

    def _ssh(self):
        cmd = [shutil.which("ssh") or "ssh", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=15", "-o", "ConnectTimeout=10"]
        if self.config.get("sshPort"):
            cmd += ["-p", str(self.config["sshPort"])]
        if self.config.get("sshIdentityFile"):
            cmd += ["-i", os.path.expanduser(self.config["sshIdentityFile"])]
        return cmd + [self.config.get("sshHost", "")]

    def _launch(self):
        if self._stopped:
            return
        bundled = bundled_watcher()
        if not bundled:
            self._set_state("failed", "程序内缺少 ccpulse-watch.py")
            return
        self._set_state("connecting")
        remote_path = self.config.get("remoteWatcherPath") or "~/.ccpulse/ccpulse-watch.py"
        python = self.config.get("remotePython") or "python3"
        # 先把 watcher 传过去（内容不同才写）
        try:
            with open(bundled, "rb") as handle:
                text = handle.read()
            remote_dir = os.path.dirname(remote_path) or "."
            put = "mkdir -p %s && cat > %s.tmp && mv %s.tmp %s" % (remote_dir, remote_path, remote_path, remote_path)
            subprocess.run(self._ssh() + [put], input=text, timeout=60, check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, **NO_WINDOW)
        except (OSError, subprocess.SubprocessError) as exc:
            log.write("远端 %s 部署 watcher 失败：%s" % (self.name, exc))
            self._schedule_restart(str(exc))
            return
        self._sync_plugins(python)
        try:
            from . import agent_skill, plugins
            # 本机同步过去的插件在远端单独的目录里（plugins.REMOTE_DIR_ENV）；技能由远端 watcher 自己装（告诉它哪些开着）
            env = dict(watcher_env(), **agent_skill.remote_env(python))
            prefix = "".join("%s=%s " % item for item in env.items()) + plugins.REMOTE_DIR_ENV + " "
            proc = subprocess.Popen(self._ssh() + ["%s%s %s" % (prefix, python, remote_path)], stdin=subprocess.PIPE,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, **NO_WINDOW)
        except OSError as exc:
            self._schedule_restart(str(exc))
            return
        self._proc = proc
        self._last_event = time.time()
        threading.Thread(target=self._read_stderr, args=(proc,), daemon=True).start()
        self._read_stdout(proc)
        proc.wait()
        if self._proc is proc:
            self._proc = None
        self._fail_all("watcher 通道已断开")
        if not self._stopped:
            self._schedule_restart(self._stderr_tail[-1] if self._stderr_tail else "ssh 退出码 %s" % proc.returncode)
