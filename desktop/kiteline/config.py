"""配置与数据目录。

和 Mac 版（Sources/Config.swift）同一套字段：config.json 里 {"sources": [...], "mobile": {...}}，
缺的字段一律回落默认值，手机端看到的行为和 Mac 版一致。

数据目录：
  Windows  %APPDATA%\\Kiteline
  Linux    $XDG_CONFIG_HOME/kiteline（默认 ~/.config/kiteline）
  测试      KITELINE_CONFIG_DIR（兼容 Mac 版的 CCPULSE_CONFIG_DIR）
"""

import copy
import json
import os
import secrets
import sys
import threading
from datetime import datetime, timedelta

IS_WINDOWS = sys.platform.startswith("win")
IS_LINUX = sys.platform.startswith("linux")
PLATFORM = "windows" if IS_WINDOWS else ("linux" if IS_LINUX else sys.platform)
# 访问第三方服务器（语音模型镜像、Bark）时报的名字：hf-mirror.com 会拦 Python 默认的「Python-urllib/3.x」（个别文件 403，10-24 实测）
USER_AGENT = "Kiteline (%s)" % PLATFORM

BUILTIN_RELAY = "https://tars.betac.cn"

DEFAULT_QUICK_REPLIES = ["继续", "按此方案执行", "截图查看效果", "运行测试并发送结果", "总结本次改动", "暂停，等我回来再继续"]

DEFAULT_WATCH = {
    "doubleTap": True, "alwaysAllow": False, "guardDanger": True, "scope": "all", "hideMuted": False,
    "showCost": True, "haptics": True, "replies": [], "theme": "phone", "font": "phone", "textSize": "watch",
}

DEFAULT_MOBILE = {
    "autostartDefaulted": False,   # 装好后第一次运行时已默认打开过开机自启（autostart.ensure_default）
    "enabled": True,
    "port": 8765,
    "bindAddress": "0.0.0.0",
    "token": "",
    "publicURL": "",
    "submitOnSend": True,
    "installAgentSkill": True,
    "installTestSkill": True,     # 网页测试报告技能
    "installTodoSkill": True,     # 待办与关键信息技能
    "installStageSkill": True,    # 任务阶段技能（会话列表的「2/4 开发中」）
    "installOpenCodePlugin": True,
    "httpsEnabled": True,
    "httpsPort": 0,
    "pushContact": "mailto:ccpulse@users.noreply.github.com",
    "voiceLocale": "zh-CN",
    "uiLanguage": "system",   # 电脑端自己的界面（托盘、控制台）：system 跟随系统 / zh / en；发给手机的字按各台手机的语言，和它无关
    "digestTime": "21:30",
    "morningTime": "08:30",
    "remindWaiting": True,
    "autoCloseIdle": True,   # 24 小时没在 Kiteline 里打开过详情的会话自动关闭、进历史会话（见 idleclose.py）
    "quietStart": "23:00",
    "quietEnd": "08:00",
    "mutedSessions": [],
    "pinnedSessions": [],
    # 标记的会话（主题色星星，新标记的在前）：各端所有列表最上面，不受分组限制；关闭会话、会话结束时自动取消（同 Mac 版）
    "markedSessions": [],
    "myName": "",
    "avatar": "text",
    "remoteEnabled": True,
    "relayURL": "",
    "barkURL": "",
    "barkMode": "attention",
    "barkKey": "",
    "barkIV": "",
    "dailyBudget": 0.0,
    "dailyCap": 0.0,
    "quickReplies": list(DEFAULT_QUICK_REPLIES),
    "watch": dict(DEFAULT_WATCH),
    "usageStats": True,   # 发送使用统计（stats.py）：设备、会话的数字和类别，不含对话和代码
}


def default_source_local():
    return {"id": "local", "name": "本机", "kind": "local", "remotePython": "python3",
            "remoteWatcherPath": "~/.ccpulse/ccpulse-watch.py", "pathPrefixes": [], "enabled": True}


def config_dir():
    override = os.environ.get("KITELINE_CONFIG_DIR") or os.environ.get("CCPULSE_CONFIG_DIR")
    if override:
        return override
    if IS_WINDOWS:
        base = os.environ.get("APPDATA") or os.path.join(os.path.expanduser("~"), "AppData", "Roaming")
        return os.path.join(base, "Kiteline")
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "kiteline")


def path(*parts):
    return os.path.join(config_dir(), *parts)


def restrict_dir():
    """数据目录只许本用户进（对应 Mac 版 AppConfig.restrictDirectory）：里面有主令牌、设备令牌、私钥、日志。
    Linux 的家目录常是 755，日志、审计这些按默认权限新建的文件靠目录 700 一并挡住"""
    if IS_WINDOWS:
        return
    try:
        os.makedirs(config_dir(), mode=0o700, exist_ok=True)
        os.chmod(config_dir(), 0o700)
    except OSError:
        pass


def make_token():
    """主令牌：48 位十六进制（和 Mac 版一样，设备令牌以 d 开头、配对令牌以 p 开头，用前缀区分）"""
    return secrets.token_hex(24)


def write_private(file_path, data):
    """原子写入；只有本用户能读（Windows 上用户目录本来就隔离）"""
    os.makedirs(os.path.dirname(file_path), exist_ok=True)
    tmp = file_path + ".tmp"
    mode = "wb" if isinstance(data, (bytes, bytearray)) else "w"
    with open(tmp, mode, **({} if mode == "wb" else {"encoding": "utf-8"})) as handle:
        handle.write(data)
    if not IS_WINDOWS:
        os.chmod(tmp, 0o600)
    os.replace(tmp, file_path)


def read_json(file_path, fallback):
    try:
        # utf-8-sig：Windows 记事本、PowerShell 存的 UTF-8 文件开头带 BOM
        with open(file_path, encoding="utf-8-sig") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return copy.deepcopy(fallback)


def parse_hm(text):
    try:
        hour, minute = text.split(":")
        hour, minute = int(hour), int(minute)
        if 0 <= hour < 24 and 0 <= minute < 60:
            return hour, minute
    except (ValueError, AttributeError):
        pass
    return None


class Config:
    """线程安全的配置：读快照用 .mobile / .sources，改用 update(fn)"""

    def __init__(self):
        self._lock = threading.RLock()
        restrict_dir()
        self._file = path("config.json")
        raw = read_json(self._file, {})
        mobile = dict(DEFAULT_MOBILE)
        mobile.update({k: v for k, v in (raw.get("mobile") or {}).items() if k in DEFAULT_MOBILE})
        watch = dict(DEFAULT_WATCH)
        watch.update({k: v for k, v in (mobile.get("watch") or {}).items() if k in DEFAULT_WATCH})
        mobile["watch"] = watch
        sources = raw.get("sources")
        if not isinstance(sources, list) or not sources:
            sources = [default_source_local()]
        self._data = {"sources": sources, "mobile": mobile}
        for key in ("notifyOnNeedsAttention", "notifyOnConclusion"):
            self._data[key] = raw.get(key, True)
        changed = False
        if not mobile.get("token"):
            mobile["token"] = make_token()
            changed = True
        if changed or not os.path.exists(self._file):
            self.save()

    @property
    def mobile(self):
        with self._lock:
            return copy.deepcopy(self._data["mobile"])

    @property
    def sources(self):
        with self._lock:
            return copy.deepcopy(self._data["sources"])

    def get(self, key, default=None):
        with self._lock:
            return copy.deepcopy(self._data.get(key, default))

    def update(self, fn):
        """fn(data) 原地改；改完存盘"""
        with self._lock:
            fn(self._data)
            self.save()

    def save(self):
        with self._lock:
            text = json.dumps(self._data, ensure_ascii=False, indent=2, sort_keys=True)
        write_private(self._file, text)

    # MARK: 派生

    def https_port(self):
        m = self.mobile
        return m["httpsPort"] if m.get("httpsPort") else int(m["port"]) + 1

    def relay(self):
        return self.mobile.get("relayURL") or BUILTIN_RELAY

    def in_quiet_hours(self, now=None):
        m = self.mobile
        start, end = parse_hm(m.get("quietStart", "")), parse_hm(m.get("quietEnd", ""))
        if not start or not end or start == end:
            return False
        now = now or datetime.now()
        minutes = now.hour * 60 + now.minute
        a, b = start[0] * 60 + start[1], end[0] * 60 + end[1]
        return (a <= minutes < b) if a < b else (minutes >= a or minutes < b)

    def should_push(self, kind, key=None):
        """这类提醒现在要不要推到锁屏（和 MobileConfig.shouldPush 一致）"""
        if kind in ("attention", "budget", "test"):
            return True
        m = self.mobile
        if key and key in m.get("mutedSessions", []) and kind in ("conclusion", "image", "error", "stuck", "todo", "keyinfo"):
            return False
        if self.in_quiet_hours() and kind in ("conclusion", "image", "schedule", "error", "stuck", "editor", "link", "todo", "keyinfo", "group"):
            return False
        return True


def clean_quick_replies(items):
    seen, out = set(), []
    for raw in items:
        text = str(raw).strip()[:200]
        if not text or text in seen:
            continue
        seen.add(text)
        out.append(text)
        if len(out) == 24:
            break
    return out


def start_of_day_ms(now=None):
    now = now or datetime.now()
    return int(datetime(now.year, now.month, now.day).timestamp() * 1000)


def days_ago_ms(days):
    now = datetime.now()
    start = datetime(now.year, now.month, now.day) - timedelta(days=days - 1)
    return int(start.timestamp() * 1000)
