#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ccpulse-watch — Claude Code 会话观察器 + 会话内容通道

驻留在跑 Claude Code 的机器上（本机或 Remote-SSH 远端），读取 ~/.claude 下的
会话注册表与 transcript，以 JSON Lines 打到 stdout；同时从 stdin 接收 JSON Lines
请求（拉历史、取图片、落地手机发来的图片、tmux 投递），响应同样走 stdout。
菜单栏 App 以子进程（本机）或 SSH 长连接（远端）读写这条双向通道。

零依赖，仅用 Python 标准库。兼容 Python 3.8+。

事件（stdout）:
  hello     启动横幅，带协议版本与能力列表
  heartbeat 每 10 秒一条，维持通道活性
  snapshots 全量在线会话快照（仅在有变化时推送）
  entries   某会话 transcript / 智能体发图的增量条目（规整后的对话项）
  reset     某会话 transcript 被重写（变短），客户端应重新拉历史
  sys       本机性能，每 5 秒一条：cpu（0～1）、cores、memTotal / memUsed（字节）、netIn / netOut（字节每秒）
  term      会话里的终端有输出：{term, sessionId, seq（这段在整条输出里的字节位置）, data（base64）}
  term_exit 终端结束了：{term, sessionId, code}
  peers     会话之间的消息（Claude Code 的 SendMessage）有新的或状态变了：links [{id, from, to, fromName, toName,
            fromTitle, toTitle, summary, text, sentAt, readAt, ok}]，from / to 是 sessionId（对不上时为空，只有名字）
  response  对 stdin 请求的应答（带同一个 id）
  error     观察器自身出错

请求（stdin，每行一个 JSON，带 id）:
  history   {sessionId, before?, limit?}     向前翻页拉历史对话项
  peers     {since}                          某个时间（毫秒）以来会话之间的消息往来（翻对话记录补齐，给协作图用）
  media     {sessionId, ref}                 取一张图片（base64）
  put_file  {name, data}                     把手机发来的图片落到本机，返回路径
  tmux_send {pid, text?, keys?, submit?}     终端里的 CLI 会话：经 tmux 投递（托管会话写进它的伪终端）
  hosted_start {cwd, prompt?, submit?, sessionId?, takeOver?, netEnv?}  不开 VS Code，后台起一个 claude（sessionId = 恢复这段对话；
                                             takeOver = 它正在 VS Code 里开着，等那边关掉再接着），网络设置和 VS Code 里的 Claude Code 一致
                                             （netEnv：Kiteline 读的 VS Code 设置里给 Claude Code 配的网络变量），
                                             等它起来、第一句发出去再回 {sessionId, hosted, pid, submitted, network}
  hosted_stop {sessionId, ifIdle?}           结束托管会话（转到 VS Code 接着做之前）
  hosted_probe {netEnv?}                     出口检测：照后台运行时的网络设置查出口 IP → {source, settings, egress {ip, country, region, city, org, site}}
  machine_info                               设备详情：主机名、系统、CPU 型号、内存、IP、开机时长、磁盘
  term      {op, sessionId, cwd?, term?, …}  会话里的终端：open {cols, rows} / list / read（最近的输出，接上画面）/
                                             input {data, base64?} / resize {cols, rows} / close
  ping

子命令（给智能体用）:
  ccpulse-watch.py send-image <图片>... [--caption 说明] [--session 会话id]
      把图片发到用户手机上该会话的对话里。
  ccpulse-watch.py prompt-link <提示词> [--project 项目名|路径|owner/repo] [--no-project]
      生成提示词链接（https://tars.betac.cn/new#p=…）：贴进 PR 评论、文档、聊天里，别人用 Kiteline 打开就是填好提示词的「新任务」，
      先看过、选好项目再开始，不会自动执行。不写 --project 时用当前目录名。提示词写成 - 时从标准输入读。
  ccpulse-watch.py send-page <html文件> [--title 标题] [--caption 说明] [--session 会话id]
      把一个网页（图表、对比表、架构图、报告）发到对话里：手机上轻点在 App 里打开（能交互），电脑上用浏览器打开。
      同目录引用的图片、CSS、JS 会一起打包进去；外部 CDN 的脚本照常加载。
  ccpulse-watch.py shot <网址|html文件> [--desktop] [--width W --height H] [--caption 说明]
  ccpulse-watch.py shot --text <文件|-> [--title 标题] [--caption 说明]
      截网页 / 把文本输出渲染成图，然后像 send-image 一样发到手机。
  ccpulse-watch.py report <results.json|它所在的文件夹|步骤清单.json> [--title 标题] [--url 被测网址] [--caption 补充说明] [--no-send]
      把 Playwright 的 JSON 报告（--reporter=json）排成图文测试报告：总览 + 每个用例的步骤截图 + 文字摘要，
      发到手机该会话的对话里；电脑上留一份完整的 HTML（~/.ccpulse/reports）。
      不是 @playwright/test 跑的，写一个步骤清单：
        {"title": "登录流程", "url": "http://localhost:5173", "tests": [{"title": "登录后进入控制台", "status": "passed",
         "duration": 3200, "steps": [{"title": "打开登录页", "screenshot": "shots/1.png", "note": "可选的说明"}]}]}
      status 写 passed / failed / skipped，失败的加 "error": "原因"；截图路径相对清单文件。
  ccpulse-watch.py e2e-setup [名字] [--update]
      项目里没有 Playwright 时用：在 ~/.ccpulse/e2e 装一份公用的（自动选可用的 npm 源和浏览器，优先用电脑上的 Chrome / Edge），
      为这个项目建一个测试文件夹（名字默认取当前目录名），打印测试放哪、怎么跑。不动用户的项目。
  ccpulse-watch.py todo "要做的事" [--detail 背景和做到哪一步] [--session 会话id]
      记一条 agent 自己以后要做的事（打印编号 t-xxxxxx）；todo start|progress|done <编号> [说明] 更新状态和进度，
      todo list 列出这台电脑上还没做完的（新会话接手用）。用户看得到是哪个会话在处理、到哪一步了。
  ccpulse-watch.py todo --user "要用户做的事" [--detail 说明]
      只有用户能做的事（注册、申请 AppID / Key、付款……）：提醒用户，他可以现在处理或加入自己的待办，处理好后回到会话告诉你。
  ccpulse-watch.py keyinfo "标题" --field "名称=值"... [--secret "密码=值"]... [--note 说明] [--session 会话id]
      把以后还要用的关键信息（账号密码、密钥、地址）发到用户手机，可一键收藏、复制；--secret 的值手机上默认遮住。
  ccpulse-watch.py stage --steps "步骤1,步骤2,…"|default [--parts "部分1,部分2"] [--remember] [--session 会话id]
  ccpulse-watch.py stage <第几步或步骤名> [--part 部分] [--note 在做什么]  |  stage done [--part 部分|--all]  |  stage show
      任务做到哪一步（会话列表里「正在工作」前显示「2/4 开发中」「iPhone · 3/4 测试中」，对话页上有任务进展）：
      --steps 按这次任务实际怎么做规划步骤（跨轮保留；以报的为准，忘了报时只往认得出的下一步跟），--parts 分几个端 / 模块各走一遍，
      --remember 记成这个项目的默认流程（--steps default 用它）。没规划的按工具调用推断成默认四步（只进不退）：
      调研了解 / 开发中 / 测试中 / 汇报中（发布中）；问问题、查资料就答完的不显示。
  以上发图、待办、关键信息、阶段都自动认出所在的会话（Claude Code、Codex、OpenCode……），认不出时用 --session 指定。
  ccpulse-watch.py attach [序号 | 会话 id 开头 | 目录或标题里的字]
      给用户用：在这台电脑的终端里（比如 VS Code 连过来的终端）接上 Kiteline 在后台运行的 Claude Code，实时看、直接操作，
      和手机、电脑上 Kiteline 会话终端里的「claude」同时可见。不带参数时接当前目录的那个，有几个就列出来选。
      Ctrl+] 断开，Claude 继续在后台运行。

输出保证：每次打印一行完整的 UTF-8 JSON 并以换行结束。
"""

import base64
import calendar
import glob as globlib
import hashlib
import hmac
import http.client
import importlib.util
import io
import json
import math
import mimetypes
import os
import queue
import signal
import re
import shutil
import socket
import sqlite3
import struct
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import types
import uuid
import zlib
from urllib.parse import quote as url_quote
from urllib.request import pathname2url

PROTOCOL = 2
WATCHER_VERSION = "2.36.0"
FEATURES = ["rpc", "entries", "history", "media", "put_file", "tmux", "outbox", "git", "tests", "usage", "digest", "projects", "history_any", "search", "usage_report", "files", "worktree", "project_overview", "agents", "sys", "peers", "plugins", "skills", "machine_info", "todos", "get_file", "fs", "repo", "limits", "term", "stage", "groups", "goal", "dirs", "brag"]
TICK_SECONDS = 1.0
HEARTBEAT_SECONDS = 10.0
MESSAGE_MAX_CHARS = 600
TRANSCRIPT_TAIL_BYTES = 160 * 1024
TRANSCRIPT_MAX_LINES = 400
VOLATILE_STATUSES = ("busy", "working", "running")

# 对话项的体积控制：正文完整给，工具输入/输出截断（手机上看个大概，细节回电脑看）
ASSISTANT_TEXT_MAX = 30000
USER_TEXT_MAX = 20000
TOOL_RESULT_MAX = 4000
TOOL_INPUT_STRING_MAX = 6000
TAIL_READ_MAX = 8 * 1024 * 1024
HISTORY_DEFAULT_LIMIT = 80
PUT_FILE_MAX = 25 * 1024 * 1024
SEND_IMAGE_MAX = 15 * 1024 * 1024
IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg")
# 常见办公文档、图片、音视频的类型：Windows 上的 Python 不读 mime.types、注册表里也常没有，guess_type 对 .xlsx / .docx 回 None，
# 取回的文件（/api/download）就成了 application/octet-stream。统一登记一遍，三端一致
for _ext, _mime in ((".xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
                    (".xlsm", "application/vnd.ms-excel.sheet.macroEnabled.12"), (".xls", "application/vnd.ms-excel"),
                    (".docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"), (".doc", "application/msword"),
                    (".pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation"),
                    (".ppt", "application/vnd.ms-powerpoint"), (".numbers", "application/vnd.apple.numbers"),
                    (".pages", "application/vnd.apple.pages"), (".key", "application/vnd.apple.keynote"),
                    (".pdf", "application/pdf"), (".rtf", "application/rtf"), (".epub", "application/epub+zip"),
                    (".csv", "text/csv"), (".md", "text/markdown"), (".txt", "text/plain"), (".json", "application/json"),
                    (".zip", "application/zip"), (".png", "image/png"), (".jpg", "image/jpeg"), (".jpeg", "image/jpeg"),
                    (".gif", "image/gif"), (".webp", "image/webp"), (".heic", "image/heic"), (".svg", "image/svg+xml"),
                    (".mp4", "video/mp4"), (".mov", "video/quicktime"), (".mp3", "audio/mpeg"), (".m4a", "audio/mp4"),
                    (".wav", "audio/wav")):
    mimetypes.add_type(_mime, _ext)

HOME = os.path.expanduser("~")
SESSIONS_DIR = os.environ.get("CCPULSE_SESSIONS_DIR") or os.path.join(HOME, ".claude", "sessions")
# projects 目录默认与 sessions 同级；单独指定时以指定值为准
_DEFAULT_PROJECTS = (
    os.path.join(os.path.dirname(SESSIONS_DIR.rstrip("/")), "projects")
    if os.environ.get("CCPULSE_SESSIONS_DIR")
    else os.path.join(HOME, ".claude", "projects")
)
PROJECTS_DIR = os.environ.get("CCPULSE_PROJECTS_DIR") or _DEFAULT_PROJECTS
# 本工具自己的数据目录：手机发来的图片（inbox）、智能体发出的图片（outbox）
DATA_DIR = os.environ.get("CCPULSE_DATA_DIR") or os.path.join(HOME, ".ccpulse")
INBOX_DIR = os.path.join(DATA_DIR, "inbox")
OUTBOX_DIR = os.path.join(DATA_DIR, "outbox")

# 把这些值视为「正在干活」，其余非空值都视为在等人
BUSY_WORDS = ("busy", "working", "running", "thinking", "active", "tool")


DEBUG = bool(os.environ.get("CCPULSE_DEBUG"))

# Windows（Kiteline 电脑端）：进程判活、父进程、启动时间都走 Win32。
# 注意 Windows 上 os.kill(pid, 0) 不是「探一下」，而是 TerminateProcess——绝不能用。
IS_WINDOWS = os.name == "nt"
if IS_WINDOWS:
    import ctypes
    from ctypes import wintypes

    _k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _k32.OpenProcess.restype = wintypes.HANDLE
    _k32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    _k32.CloseHandle.argtypes = [wintypes.HANDLE]
    _k32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    _k32.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
    _k32.CreateToolhelp32Snapshot.restype = wintypes.HANDLE

    class _PROCESSENTRY32W(ctypes.Structure):
        _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD), ("th32ProcessID", wintypes.DWORD),
                    ("th32DefaultHeapID", ctypes.c_size_t), ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
                    ("th32ParentProcessID", wintypes.DWORD), ("pcPriClassBase", ctypes.c_long), ("dwFlags", wintypes.DWORD),
                    ("szExeFile", ctypes.c_wchar * 260)]

    def _win_open(pid):
        return _k32.OpenProcess(0x1000, False, pid)   # PROCESS_QUERY_LIMITED_INFORMATION

    def _win_pid_alive(pid):
        handle = _win_open(pid)
        if not handle:
            return ctypes.get_last_error() == 5   # 拒绝访问 = 进程在，只是权限不够
        try:
            code = wintypes.DWORD()
            return bool(_k32.GetExitCodeProcess(handle, ctypes.byref(code))) and code.value == 259   # STILL_ACTIVE
        finally:
            _k32.CloseHandle(handle)

    def _win_parent_pid(pid):
        snapshot = _k32.CreateToolhelp32Snapshot(0x2, 0)   # TH32CS_SNAPPROCESS
        if not snapshot or snapshot == wintypes.HANDLE(-1).value:
            return None
        try:
            entry = _PROCESSENTRY32W()
            entry.dwSize = ctypes.sizeof(_PROCESSENTRY32W)
            ok = _k32.Process32FirstW(snapshot, ctypes.byref(entry))
            while ok:
                if entry.th32ProcessID == pid:
                    return entry.th32ParentProcessID or None
                ok = _k32.Process32NextW(snapshot, ctypes.byref(entry))
            return None
        finally:
            _k32.CloseHandle(snapshot)

    # 打包成窗口程序的 Kiteline 起 git 这类命令行程序时，别每次闪一个黑框；
    # 子进程的 stdin 也别继承：主线程正阻塞读着 Kiteline 接过来的管道，Git for Windows 一碰这个句柄就卡死
    _popen_init = subprocess.Popen.__init__

    def _popen_no_window(self, *args, **kwargs):
        kwargs.setdefault("creationflags", 0x08000000)   # CREATE_NO_WINDOW
        if len(args) < 4 and kwargs.get("stdin") is None:
            kwargs["stdin"] = subprocess.DEVNULL
        _popen_init(self, *args, **kwargs)

    subprocess.Popen.__init__ = _popen_no_window

    def _win_start_token(pid):
        handle = _win_open(pid)
        if not handle:
            return None
        try:
            times = [wintypes.FILETIME() for _ in range(4)]
            if not _k32.GetProcessTimes(handle, *[ctypes.byref(t) for t in times]):
                return None
            ft = (times[0].dwHighDateTime << 32) | times[0].dwLowDateTime
            return str(int(ft / 10_000_000 - 11_644_473_600))
        finally:
            _k32.CloseHandle(handle)


def log(message):
    """日志只走 stderr，stdout 必须保持纯净的事件流。"""
    sys.stderr.write("[ccpulse-watch] %s\n" % message)
    sys.stderr.flush()


_EMIT_LOCK = threading.Lock()


def emit(obj):
    line = json.dumps(obj, ensure_ascii=False) + "\n"
    # 改文件、Git 的请求在后台线程里回：一行要整行写完，别和主循环的事件搅在一起
    with _EMIT_LOCK:
        sys.stdout.write(line)
        sys.stdout.flush()


def read_text(path, limit=None):
    try:
        with open(path, "rb") as handle:
            data = handle.read() if limit is None else handle.read(limit)
    except OSError:
        return None
    return data.decode("utf-8", "replace")


def rel_path(path, start):
    """给手机看的相对路径一律用 /（Windows 上 relpath 出来是反斜杠）"""
    rel = os.path.relpath(path, start)
    return rel.replace(os.sep, "/") if os.sep != "/" else rel


def is_abs_path(path):
    """绝对路径：/… ；Windows 上还有 C:\\… / C:/…"""
    return isinstance(path, str) and (path.startswith("/") or (IS_WINDOWS and os.path.isabs(path)))


def pid_alive(pid):
    if not isinstance(pid, int) or pid <= 0:
        return False
    if IS_WINDOWS:
        return _win_pid_alive(pid)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def parent_pid(pid):
    """取父进程 pid；Linux 读 /proc，macOS 退回 ps，Windows 走进程快照。取不到返回 None。"""
    if IS_WINDOWS:
        return _win_parent_pid(pid)
    try:
        with open("/proc/%d/stat" % pid, "rb") as handle:
            raw = handle.read().decode("utf-8", "replace")
        close = raw.rfind(")")
        fields = raw[close + 2:].split()
        return int(fields[1])
    except (OSError, ValueError, IndexError):
        pass
    try:
        out = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5)
        text = out.stdout.decode().strip()
        return int(text) if text else None
    except Exception:
        return None


def ancestors(pid, depth=40):
    chain = []
    current = pid
    for _ in range(depth):
        if not current or current <= 1:
            break
        chain.append(current)
        current = parent_pid(current)
    return chain


def process_start_token(pid):
    """进程启动令牌，用于识别 pid 复用。取不到就返回 None。"""
    if IS_WINDOWS:
        return _win_start_token(pid)
    try:
        with open("/proc/%d/stat" % pid, "rb") as handle:
            raw = handle.read().decode("utf-8", "replace")
        close = raw.rfind(")")
        if close == -1:
            return None
        fields = raw[close + 2:].split()
        return fields[19] if len(fields) > 19 else None
    except OSError:
        pass
    try:
        env = dict(os.environ)
        # 关键：让 ps 直接以 UTC 输出，格式与注册表里的 procStart 完全一致。
        # 否则 ps 给本地墙上时间（本机 CST=UTC+8），一比对就把活会话误判成 pid 复用。
        env["TZ"] = "UTC"
        env["LC_ALL"] = "C"
        out = subprocess.run(
            ["ps", "-o", "lstart=", "-p", str(pid)],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5, env=env,
        )
        text = out.stdout.decode("utf-8", "replace").strip()
        return text or None
    except Exception:
        return None


def norm_token(value):
    """空字符串等同于「没有记录」。
    早期版本只判 None，导致 procStart 为 "" 时拿空串去比对，
    把活着的会话误判成 pid 复用（真实会话确实会写空值，生产上踩过）。"""
    if value is None:
        return None
    text = str(value).strip()
    return text or None


# macOS 上 registry 的 procStart 和 ps -o lstart= 的时区表示不一致
# （实测同一时刻分别写成 ...T15:13:11Z 与本地 23:13:11），字符串比对会把活会话误判成
# pid 复用。所以统一解析成时间戳再比，并允许秒级/时区带来的偏差。
# 注意两类输入语义不同：
#   ps -o lstart= → 本地墙上时间，需要加回时区偏移
#   注册表 procStart / ISO 串 → 本身就是 UTC 文本，不能再动
_PS_TIME_FORMAT = "%a %b %d %H:%M:%S %Y"
_TIME_FORMATS = (
    _PS_TIME_FORMAT,
    "%Y-%m-%dT%H:%M:%S",
    "%Y-%m-%d %H:%M:%S",
)
# ps 给的是本地墙上时间，注册表里是 UTC 文本，同一瞬间能差整整一个时区。
# 这里自算偏移（同一瞬间取 UTC 与本地之差），夏令时也覆盖；再留几分钟余量。
PROC_START_TOLERANCE = 300.0


def utc_offset_seconds():
    now = time.time()
    try:
        local_ahead = time.mktime(time.localtime(now)) - calendar.timegm(time.localtime(now))
    except (OSError, OverflowError, ValueError):
        return 0.0
    return float(local_ahead)


_UTC_OFFSET = utc_offset_seconds()


def token_seconds(value):
    """把 procStart / ps 输出统一成 epoch 秒；识别不出来返回 None。"""
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    if text.isdigit():
        number = int(text)
        if number > 10_000_000_000_000_000:   # Windows 的 FILETIME（100 纳秒，从 1601 年起）
            return number / 10_000_000 - 11_644_473_600
        if number > 10_000_000_000:   # 13 位是毫秒
            number //= 1000
        return float(number)
    compact = " ".join(text.split())
    has_zone = False
    for suffix in (" UTC", " GMT", "Z"):
        if compact.endswith(suffix):
            compact = compact[: -len(suffix)].strip()
            has_zone = True
            break
    for fmt in _TIME_FORMATS:
        try:
            parsed = calendar.timegm(time.strptime(compact, fmt))
        except ValueError:
            continue
        # TZ=UTC 后 ps 输出已是 UTC，正常情况下不需要再修；这里只在传入的
        # 确实是本地墙上时间且与时区明显不符时才兜底（偏移为负=东时区，需减回）
        if fmt == _PS_TIME_FORMAT and not has_zone and _UTC_OFFSET < 0:
            parsed += _UTC_OFFSET
        return float(parsed)
    return None


def same_process_start(recorded, actual):
    left, right = token_seconds(recorded), token_seconds(actual)
    if left is None or right is None:
        return None  # 无法判定，交给调用方决定
    return abs(left - right) <= PROC_START_TOLERANCE


def is_live(payload):
    """会话记录可能是上一个进程留下的残骸，必须验活。"""
    pid = payload.get("pid")
    if not isinstance(pid, int):
        return False
    if not pid_alive(pid):
        return False
    recorded = norm_token(payload.get("procStartFt") or payload.get("procStart"))
    if recorded is None:
        return True
    actual = process_start_token(pid)
    if actual is None:
        return True
    verdict = same_process_start(recorded, actual)
    if verdict is None:
        # 解析不了时倾向判活：漏报比误报「pid 复用」安全得多
        return True
    return verdict


def display_cwd(cwd):
    if not isinstance(cwd, str) or not cwd:
        return "?"
    if cwd == HOME:
        return "~"
    if cwd.startswith(HOME + "/") or (IS_WINDOWS and cwd.lower().startswith(HOME.lower() + "\\")):
        return "~/" + cwd[len(HOME) + 1:].replace("\\", "/")
    return cwd


def project_dir_name(cwd):
    """Claude Code 把 cwd 转义成项目目录名：非 ASCII 字母数字一律变 '-'。

    注意不能用 str.isalnum() —— 中文在 Python 里也算 alnum，但 Claude Code
    只保留 [A-Za-z0-9]，其余全部替换（实测：/home/user/文档/... →
    -home-user----Projects-...）。
    """
    out = []
    for ch in cwd:
        if ("a" <= ch <= "z") or ("A" <= ch <= "Z") or ("0" <= ch <= "9"):
            out.append(ch)
        else:
            out.append("-")
    return "".join(out)


def transcript_path(session_id, cwd):
    if not session_id or not cwd:
        return None
    return os.path.join(PROJECTS_DIR, project_dir_name(cwd), "%s.jsonl" % session_id)


def mean_word(text):
    """把 waitingFor / detail 这类内部短语翻成人话。"""
    if not text:
        return None
    low = str(text).strip().lower()
    mapping = {
        "dialog open": "对话框已弹出，等待选择",
        "sandbox request": "沙箱命令请求网络权限",
        "input needed": "需要输入",
        "waiting": "等待确认",
        "permission": "请求权限确认",
        "approval": "等待批准",
    }
    for key, value in mapping.items():
        if key in low:
            return value
    return str(text).strip()


def summarize_needs(needs):
    if not needs:
        return None
    text = str(needs).strip()
    if ":" in text:
        head, tail = text.split(":", 1)
        if head.strip().lower() in ("choose", "choose one of", "pick"):
            return tail.strip()
    return text


def message_from_blocks(blocks):
    texts = []
    for block in blocks:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "text":
            value = block.get("text")
            if isinstance(value, str) and value.strip():
                texts.append(value.strip())
    if not texts:
        return None
    return "\n".join(texts)


def clean_message(text):
    if not text:
        return None
    text = text.strip()
    # 去掉内部注入的标签块，只留给人看的结论
    while True:
        start = text.find("<")
        if start == -1:
            break
        end = text.find(">", start)
        if end == -1:
            break
        tag = text[start + 1:end].strip().split()[0] if text[start + 1:end].strip() else ""
        if tag and all(ch.isalnum() or ch in "-_" for ch in tag):
            text = (text[:start] + text[end + 1:]).strip()
        else:
            break
    text = text.strip()
    if not text:
        return None
    if len(text) > MESSAGE_MAX_CHARS:
        text = text[:MESSAGE_MAX_CHARS].rstrip() + "…"
    return text


def tool_brief(name, tool_input):
    """工具调用的一句话摘要：「Bash: npm test」这种，给列表和状态行用。"""
    if not isinstance(tool_input, dict):
        return name or "tool"
    for key in ("command", "description", "file_path", "path", "pattern", "url", "query", "prompt"):
        value = tool_input.get(key)
        if isinstance(value, str) and value.strip():
            line = value.strip().split("\n", 1)[0]
            if key in ("file_path", "path"):
                line = os.path.basename(line.rstrip("/")) or line
            if len(line) > 80:
                line = line[:80] + "…"
            return "%s: %s" % (name, line)
    return name or "tool"


# ---------------------------------------------------------------------------
# 接口错误：Claude Code 停下来时写一条 isApiErrorMessage 的假回复（用量到上限、上下文太长、接口过载……）
# ---------------------------------------------------------------------------

_RESET_RE = re.compile(r"resets\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*(?:\(([^)]+)\))?", re.IGNORECASE)


def _reset_at(raw, ref_ms=None):
    """「resets 9:10am (America/New_York)」→ 下一次恢复的时间（毫秒）；看不懂就 None"""
    match = _RESET_RE.search(raw or "")
    if not match:
        return None
    hour, minute = int(match.group(1)), int(match.group(2) or 0)
    ampm = (match.group(3) or "").lower()
    if ampm == "pm" and hour < 12:
        hour += 12
    elif ampm == "am" and hour == 12:
        hour = 0
    if hour > 23 or minute > 59:
        return None
    try:
        import datetime
        tz = None
        if match.group(4):
            from zoneinfo import ZoneInfo
            tz = ZoneInfo(match.group(4).strip())
        ref = datetime.datetime.fromtimestamp((ref_ms or time.time() * 1000) / 1000.0, tz)
        when = ref.replace(hour=hour, minute=minute, second=0, microsecond=0)
        if when <= ref:
            when += datetime.timedelta(days=1)
        return int(when.timestamp() * 1000)
    except Exception:
        return None


def api_error_info(raw, ref_ms=None):
    """接口错误的原文 → {kind, text（说人话，带怎么办）, resetAt, raw}"""
    raw = (raw or "").strip()
    low = raw.lower()
    reset = None
    if "limit" in low and any(k in low for k in ("hit your", "usage limit", "session limit", "weekly limit", "rate limit")):
        kind, text = "limit", "Claude 用量已达上限"
        reset = _reset_at(raw, ref_ms)
        if not reset:
            text += "：" + raw[:120]
    elif "prompt is too long" in low or ("too long" in low and "context" in low):
        kind, text = "too_long", "上下文过长（自动压缩失败）：请发送 /compact 进行压缩，或新建会话继续"
    elif "overloaded" in low or "529" in low:
        kind, text = "api", "Anthropic 接口过载，Claude 已停止：请稍后发送「继续」重试"
    elif "credit balance" in low:
        kind, text = "billing", "账户余额不足，Claude 已停止"
    elif "/login" in low or "oauth" in low or "api key" in low or "authentication" in low:
        kind, text = "auth", "登录已失效：请在电脑上重新登录 Claude Code（运行 /login）"
    else:
        kind, text = "api", "Claude 出错已停止：%s（发送「继续」可重试）" % raw[:160]
    return {"kind": kind, "text": text, "resetAt": reset, "raw": raw[:300]}


_EFFORT = {}   # 对话记录路径 -> {"effort": ..., "ultracode": ..., "mode": ...}：只读尾部，看到过的要记住
_EFFORT_RE = re.compile(r"<command-name>/effort</command-name>[\s\S]*?<command-args>([^<]*)</command-args>")
# 权限模式（default / acceptEdits / plan / auto / bypassPermissions）：Claude Code 在你每句话上都记着当时的模式
_MODE_RE = re.compile(r'"permissionMode":"(\w+)"')


_TURN_FROM = {}   # 对话记录路径 -> 最近一轮是谁发起的（user / peer）：一轮很长时开头会滚出尾部，看到过的要记住
# Kiteline 送进会话的群消息：每条一行「【群「群名」· 谁】」，谁是「用户」的才是你在群里说的
_GROUP_SENDER_RE = re.compile(r"【群「[^」\n]*」· ([^】\n]+)】")


def turn_from_prompt(text):
    """你说的一句话（或 Kiteline 送进来的群消息）→ 这一轮是谁发起的：群里只有别的会话发言 = peer，其余都是 user"""
    if text.startswith(("【Kiteline 会话群「", "【群「")):
        senders = _GROUP_SENDER_RE.findall(text)
        if senders and "用户" not in senders:
            return "peer"
    return "user"


def note_effort(path, text):
    """记录里的 /effort 命令（在 VS Code 里打的，或手机发的）→ 这个会话现在的思考等级 / ultracode"""
    for args in _EFFORT_RE.findall(text or ""):
        args = args.strip().lower()
        state = _EFFORT.setdefault(path, {})
        if args.startswith("ultracode"):
            state["ultracode"] = not args.endswith("off")
        elif args:
            state["effort"] = args.split()[0]


def last_permission_mode(path, size, limit=8 * 1024 * 1024):
    """从文件末尾往前找最近一次 permissionMode（每次读 1MB，最多 limit）"""
    try:
        with open(path, "rb") as handle:
            pos = size
            carry = b""
            while pos > 0 and size - pos < limit:
                step = min(1024 * 1024, pos)
                pos -= step
                handle.seek(pos)
                block = handle.read(step) + carry
                found = re.findall(rb'"permissionMode":"(\w+)"', block)
                if found:
                    return found[-1].decode()
                carry = block[:64]
    except OSError:
        pass
    return None


def scan_transcript(path):
    """从 transcript 尾部读出「最后一句人话」「待处理的工具调用」和会话标题。

    返回 dict: message, messageUuid, pendingTool, pendingId, pendingBrief, title, customTitle, lastPrompt, mtime, turnFrom
    turnFrom：最近一轮是你发起的（user）还是别的会话来信引起的（peer：SendMessage、群里别的会话发言），peer 的答完不提醒你
    """
    result = {"message": None, "messageUuid": None, "pendingTool": None, "pendingId": None,
              "pendingBrief": None, "title": None, "customTitle": None, "lastPrompt": None, "mtime": None, "error": None,
              "turnFrom": None}
    if not path:
        return result
    try:
        size = os.path.getsize(path)
        result["mtime"] = os.path.getmtime(path)
    except OSError:
        return result

    try:
        with open(path, "rb") as handle:
            start = max(0, size - TRANSCRIPT_TAIL_BYTES)
            handle.seek(start)
            blob = handle.read()
    except OSError:
        return result

    text = blob.decode("utf-8", "replace")
    lines = text.split("\n")
    if start > 0:
        lines = lines[1:]  # 丢掉可能被截断的首行
    lines = lines[-TRANSCRIPT_MAX_LINES:]

    pending = {}      # tool_use_id -> (tool 名, 摘要)
    resolved = set()  # 已有结果的 tool_use_id
    last_message = None
    last_uuid = None
    last_error = None   # 最后一句是接口错误（Claude 停下了）时才有
    title = None
    custom_title = None
    last_prompt = None
    turn_from = None    # 这段尾部里最后开始的一轮是谁发起的；没看到开头就用记着的

    for line in lines:
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if not isinstance(entry, dict):
            continue

        etype = entry.get("type")
        if etype == "attachment" and not entry.get("isSidechain"):
            # 忙时排队进来的话并进当前这一轮：别的会话的来信不改发起方，你插的话要等你看（改成 user）
            attachment = entry.get("attachment") if isinstance(entry.get("attachment"), dict) else {}
            origin = attachment.get("origin") if isinstance(attachment.get("origin"), dict) else {}
            if attachment.get("type") == "queued_command" and user_origin(origin):
                turn_from = "user"
            continue
        if etype == "ai-title" and isinstance(entry.get("aiTitle"), str):
            title = entry["aiTitle"].strip() or title
            continue
        if etype == "custom-title" and isinstance(entry.get("customTitle"), str):
            custom_title = entry["customTitle"].strip() or custom_title
            continue
        if etype == "last-prompt" and isinstance(entry.get("lastPrompt"), str):
            last_prompt = entry["lastPrompt"].strip() or last_prompt
            continue
        if entry.get("isSidechain"):
            continue
        message = entry.get("message")
        if not isinstance(message, dict):
            continue
        content = message.get("content")

        if etype == "assistant" and isinstance(entry.get("effort"), str) and entry["effort"]:
            # 每条回复都记着这一轮实际用的思考等级：在 VS Code 里直接选的、设置里的默认值都只在这里看得到
            _EFFORT.setdefault(path, {})["effort"] = entry["effort"]
        if etype == "assistant" and isinstance(content, list):
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_use":
                    tool_id = block.get("id")
                    if isinstance(tool_id, str):
                        name = block.get("name") or "tool"
                        pending[tool_id] = (name, tool_brief(name, block.get("input")))
            text_value = message_from_blocks(content)
            if text_value:
                last_message = text_value
                last_uuid = entry.get("uuid")
                last_error = api_error_info(text_value, parse_ts(entry.get("timestamp"))) if entry.get("isApiErrorMessage") else None
        elif etype == "user" and isinstance(content, str):
            if "<command-name>/effort" in content:
                note_effort(path, content)
            if entry.get("isMeta"):
                if peer_origin(entry):
                    turn_from = "peer"   # 空闲时收到别的会话的来信，由它开始一轮
            elif content.strip() and not entry.get("isCompactSummary"):
                last_error = None   # 你又说话了，之前的错误就过去了
                turn_from = turn_from_prompt(content.strip())
        elif etype == "user" and isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text" and "<command-name>/effort" in (block.get("text") or ""):
                    note_effort(path, block.get("text"))
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    tool_id = block.get("tool_use_id")
                    if isinstance(tool_id, str):
                        resolved.add(tool_id)
                elif isinstance(block, dict) and block.get("type") == "text" and (not entry.get("isMeta") or bridge_said(entry)):
                    last_error = None   # 你又说话了（比如「继续」），之前的错误就过去了
                    turn_from = turn_from_prompt((block.get("text") or "").strip())

    for tool_id in list(pending.keys()):
        if tool_id in resolved:
            del pending[tool_id]

    for tool_id, (tool_name, brief) in reversed(list(pending.items())):
        result["pendingTool"] = tool_name
        result["pendingId"] = tool_id
        result["pendingBrief"] = brief
        break

    result["message"] = last_error["text"] if last_error else clean_message(last_message)
    result["messageUuid"] = last_uuid
    result["title"] = title
    result["customTitle"] = custom_title
    result["lastPrompt"] = last_prompt
    result["error"] = last_error
    if turn_from:
        _TURN_FROM[path] = turn_from
    result["turnFrom"] = _TURN_FROM.get(path)
    modes = _MODE_RE.findall(text)
    if modes:
        _EFFORT.setdefault(path, {})["mode"] = modes[-1]
    elif "mode" not in _EFFORT.get(path, {}):
        # 尾部全是工具调用（你上一句话之后 Claude 跑了很久）：往前多找一段，找到一次就记住
        found = last_permission_mode(path, size)
        if found:
            _EFFORT.setdefault(path, {})["mode"] = found
    result["effort"] = dict(_EFFORT.get(path) or {}) or None
    return result


# ---------------------------------------------------------------------------
# 用量：和 VS Code 面板同样的算法
#   上下文占用 = 最近一次请求的 输入 + 缓存读 + 缓存写 + 输出
#   累计 token = 每条回复的 usage 按消息 id 去重后求和
#   花费 = Claude Code 自己写进 transcript 的 cost-state（会话结束/恢复时才写，所以是「截至上次统计」）
# 上下文窗口 transcript 里没有：Claude 5 系列（Haiku 除外）按 100 万，其他按 20 万；实际用量更大时以实际为准。
# ---------------------------------------------------------------------------

def context_window(model, observed):
    window = 200000
    name = (model or "").lower()
    if "[1m]" in name or (re.search(r"claude-(opus|sonnet|fable)-[5-9]", name) is not None):
        window = 1000000
    if observed > window:
        window = 1000000 if observed <= 1000000 else observed
    return window


class UsageMeter:
    def __init__(self):
        self.messages = {}
        self.context = 0
        self.model = None
        self.cost = None
        self.cost_at = None

    def feed(self, entry):
        etype = entry.get("type")
        if etype == "cost-state":
            if isinstance(entry.get("totalCostUSD"), (int, float)):
                self.cost = float(entry["totalCostUSD"])
                self.cost_at = parse_ts(entry.get("timestamp"))
            return
        if etype != "assistant" or entry.get("isSidechain"):
            return
        message = entry.get("message")
        usage = message.get("usage") if isinstance(message, dict) else None
        if not isinstance(usage, dict):
            return
        def n(key):
            value = usage.get(key)
            return int(value) if isinstance(value, (int, float)) else 0
        counts = (n("input_tokens"), n("output_tokens"), n("cache_read_input_tokens"), n("cache_creation_input_tokens"))
        self.messages[message.get("id") or entry.get("uuid")] = counts
        self.context = counts[0] + counts[2] + counts[3] + counts[1]
        if message.get("model") and message.get("model") != "<synthetic>":
            self.model = message.get("model")

    def scan(self, path):
        """首次见到会话：全文扫一遍（只解析带 usage / cost-state 的行，大图行跳过解析）"""
        try:
            with open(path, "rb") as handle:
                for raw in handle:
                    if b'"usage"' in raw or b'cost-state' in raw[:200]:
                        entry = parse_line(raw)
                        if entry is not None:
                            self.feed(entry)
        except OSError:
            pass

    def summary(self):
        if not self.messages and self.cost is None:
            return None
        totals = [0, 0, 0, 0]
        for counts in self.messages.values():
            for index in range(4):
                totals[index] += counts[index]
        return {
            "context": self.context,
            "window": context_window(self.model, self.context),
            "input": totals[0], "output": totals[1], "cacheRead": totals[2], "cacheWrite": totals[3],
            "requests": len(self.messages),
            "model": self.model,
            "cost": round(self.cost, 4) if self.cost is not None else None,
            "costAt": self.cost_at,
        }


_USAGE = {}


# ---------------------------------------------------------------------------
# 目标（/goal；Claude Code 2.1.139 起、Codex 0.128 起）：agent 围着一个目标跨多轮一直做，每轮结束检查一次，确认达成才停。
# Claude Code 把设定、每次检查、清除记成对话记录里的 goal_status 附件：
#   设定 {met:false, sentinel:true, condition}；清除（/goal clear、出了救不回来的错）{met:true, sentinel:true}
#   没达成 {met:false, reason}；达成 {met:true, reason, iterations, durationMs, tokens}；做不到 {met:false, failed:true, …}
# 停下来（接口出错、检查超时、用量到上限……）另记一条系统提示「Goal paused · 原因 · send a message to continue」。
# 快照的 goal（各家同一套，guide/plugin-development.md 4.6）：
#   {text 目标, state, checks 检查了几次, reason 最近一次检查的说法（还差什么 / 为什么做不到）, note 停下的原因,
#    since 设定时间, at 最近变化（毫秒）, turns 用了几轮, durationMs 用时, tokens 用掉的 token, budget token 预算（Codex）}
#   state：active 进行中 / paused 停下了（发消息继续）/ blocked 受阻 / limited 额度或预算用完 /
#          met 已达成 / failed 无法达成 / cleared 已清除 / error 出错中止
# ---------------------------------------------------------------------------

GOAL_RUNNING = ("active", "paused", "blocked", "limited")
GOAL_KEEP_MS = 6 * 3600 * 1000      # 结束了的目标再挂 6 小时：手机上还看得到结果（达成用了几轮、为什么做不到）
# 目标还在、会话却闲下来这么久：停下了，发一条消息才会接着做。每轮结束检查目标时会话会短暂「空闲」（检查本身是一次模型调用，
# 可能要十几秒），所以明确的信号（Claude Code 的暂停提示、你中断了这一轮）才马上算停下，别的要闲满这么久
GOAL_IDLE_PAUSE_MS = 120000
CLAUDE_GOAL_SINCE = (2, 1, 139)

# Claude Code 停下目标时提示里的原因 → 中文（英文设备在出口换回英文）
GOAL_CAUSES = {
    "the API rejected the last request": "接口拒绝了上一个请求",
    "the last turn could not finish": "上一轮没能完成",
    "a hook ended the turn": "钩子结束了这一轮",
    "the goal check timed out": "目标检查超时",
    "goal checks kept finding it unmet this turn": "这一轮反复检查仍未达成",
    "the request was rate limited": "请求被限流",
    "usage limit reached": "用量已达上限",
    "the API was unavailable or the connection dropped": "接口不可用或连接中断",
    "the API returned an unexpected response": "接口返回异常",
    "the response hit the output token limit": "回复超出输出长度上限",
    "cloud credentials did not load": "云端凭证没有加载",
    "sign-in was being refreshed": "登录状态正在刷新",
    "an image could not be sent": "图片无法发送",
    "Claude's tool call could not be read": "工具调用无法解析",
    "the goal check could not complete": "目标检查没能完成",
    "authentication failed": "登录验证失败",
    "disk full": "磁盘已满",
    "organization verification required": "需要组织验证",
    "credit balance too low": "余额不足",
    "context limit reached": "上下文已满",
    "model unavailable": "模型不可用",
}
_GOAL_PAUSED_RE = re.compile(r"^Goal paused(?: after (\d+) automatic retries)? · (.+?) · ")
_GOAL_RETRY_RE = re.compile(r"^Goal still active · (.+?) · retrying in (\d+) min")
_GOAL_ERROR_RE = re.compile(r"^Goal cleared after an unrecoverable error \((.+?)\)")


def goal_cause(text):
    text = (text or "").strip()
    return GOAL_CAUSES.get(text, text)


def goal_notice(text):
    """Claude Code 关于目标的系统提示 → (state, 中文说明)：paused 停下了 / error 出错清除了；不是这类提示返回 None"""
    if not isinstance(text, str) or not text.startswith("Goal "):
        return None
    hit = _GOAL_PAUSED_RE.match(text)
    if hit:
        cause = goal_cause(hit.group(2))
        if "continues automatically" in text:
            return "paused", "%s，额度恢复后自动继续" % cause
        return "paused", ("自动重试 %s 次未成功：%s" % (hit.group(1), cause)) if hit.group(1) else cause
    hit = _GOAL_RETRY_RE.match(text)
    if hit:
        return "paused", "%s，%s 分钟后自动重试" % (goal_cause(hit.group(1)), hit.group(2))
    hit = _GOAL_ERROR_RE.match(text)
    if hit:
        return "error", goal_cause(hit.group(1))
    return None


def goal_line(raw):
    """只解析和目标有关的行（goal_status 附件、Goal … 系统提示、用户的话：你中断 / 又发了话）"""
    return b'"goal_status"' in raw or b'"content":"Goal ' in raw or b'"type":"user"' in raw


class ClaudeGoal:
    """一个 Claude Code 会话的目标：按对话记录里的 goal_status 附件、停下时的系统提示认（见上面的说明）。
    自己跟着读文件新增的行（poll），快照用的总是最新的：等增量那边喂会慢一拍，第一次检查就落在同一秒时（假模型、很快的轮次）
    会拿着上一个目标去判断「这一轮停下要不要提醒」"""

    def __init__(self):
        self.goal = None
        self.path = None
        self.offset = 0

    def scan(self, path):
        """首次见到会话：全文找一遍（目标可能是很久以前设的，尾部看不到）"""
        self.poll(path)

    def poll(self, path):
        """读上次之后新写完的行（文件被重写变短了就从头认）"""
        if not path:
            return
        try:
            size = os.path.getsize(path)
            if path != self.path or size < self.offset:
                self.path, self.offset, self.goal = path, 0, None
            if size == self.offset:
                return
            with open(path, "rb") as handle:
                handle.seek(self.offset)
                blob = handle.read(size - self.offset)
        except OSError:
            return
        end = blob.rfind(b"\n")
        if end < 0:
            return   # 一行还没写完
        self.offset += end + 1
        for raw in blob[:end].split(b"\n"):
            if goal_line(raw) and (self.goal is not None or b'"type":"user"' not in raw or b'"goal_status"' in raw):
                entry = parse_line(raw)
                if entry is not None:
                    self.feed(entry)

    def feed(self, entry):
        if entry.get("isSidechain"):
            return
        etype = entry.get("type")
        goal = self.goal
        ts = parse_ts(entry.get("timestamp")) or _now_ms()
        if etype == "user":
            if goal is None or entry.get("isMeta") or entry.get("isCompactSummary") or goal["state"] not in GOAL_RUNNING:
                return
            content = (entry.get("message") or {}).get("content") if isinstance(entry.get("message"), dict) else None
            texts = [content] if isinstance(content, str) else [b.get("text") for b in content or []
                                                               if isinstance(b, dict) and b.get("type") == "text" and isinstance(b.get("text"), str)]
            texts = [t.strip() for t in texts if t and t.strip()]
            if any(t in INTERRUPT_MARKERS for t in texts):
                goal.update(note="这一轮被中断", at=ts)   # 你按了中断：目标还在，发消息才接着做
            elif texts:
                goal.pop("note", None)   # 你又发了话：之前停下的原因过去了
            return
        if etype == "system":
            hit = goal_notice(entry.get("content"))
            if hit and goal is not None:
                state, text = hit
                if state == "error" and goal["state"] in GOAL_RUNNING + ("cleared",):
                    goal.update(state="error", reason=text, at=ts)   # 清除那条附件先到，提示紧跟着说为什么
                elif state == "paused" and goal["state"] in GOAL_RUNNING:
                    goal.update(note=text, at=ts)
            return
        attachment = entry.get("attachment") if etype == "attachment" else None
        if not isinstance(attachment, dict) or attachment.get("type") != "goal_status":
            return
        text = attachment.get("condition") if isinstance(attachment.get("condition"), str) else ""
        if attachment.get("sentinel"):
            if not attachment.get("met"):
                self.goal = {"text": text, "state": "active", "since": ts, "at": ts, "checks": 0}
            elif goal is not None and goal["state"] in GOAL_RUNNING:
                goal.update(state="cleared", at=ts)
                goal.pop("note", None)
            return
        if goal is None or goal.get("text") != text or goal["state"] not in GOAL_RUNNING:
            # 没看到设定那条（记录被截过、会话是恢复的）：从这里接上
            goal = self.goal = {"text": text, "state": "active", "since": ts, "at": ts, "checks": 0}
        reason = attachment.get("reason")
        goal.update(checks=goal["checks"] + 1, at=ts, reason=reason.strip() if isinstance(reason, str) and reason.strip() else None,
                    state="met" if attachment.get("met") else "failed" if attachment.get("failed") else "active")
        goal.pop("note", None)
        for key, field in (("iterations", "turns"), ("durationMs", "durationMs"), ("tokens", "tokens")):
            if isinstance(attachment.get(key), (int, float)):
                goal[field] = int(attachment[key])

    def view(self):
        return dict(self.goal) if self.goal else None


_GOALS = {}


def goal_supported(version, since=CLAUDE_GOAL_SINCE):
    """Claude Code 的版本号（2.1.314）够不够用 /goal"""
    try:
        return tuple(int(part) for part in str(version).split(".")[:3]) >= since
    except ValueError:
        return False


class GoalBook:
    """给快照挂上 goal：Claude Code 的从对话记录认（ClaudeGoal），别家的插件自己给。
    目标还在、会话闲了一阵 → paused；正在做 → active。结束了的再挂 GOAL_KEEP_MS"""

    def __init__(self):
        self.idle_since = {}

    def annotate(self, snapshots):
        now = _now_ms()
        live = set()
        for snap in snapshots:
            sid = snap.get("sessionId")
            if not sid:
                continue
            live.add(sid)
            claude = (snap.get("agent") or "claude-code") == "claude-code"
            if claude:
                meter = _GOALS.get(sid)
                if meter is not None:
                    meter.poll(snap.get("transcriptPath"))
                goal = meter.view() if meter else None
            else:
                goal = snap.get("goal") if isinstance(snap.get("goal"), dict) else None
            if snap.get("activity") == "idle":
                idle = now - self.idle_since.setdefault(sid, now)
            else:
                self.idle_since.pop(sid, None)
                idle = 0
            if goal and claude and goal["state"] == "active":
                # note：停下的原因（Claude Code 的提示）；reason 留着最近一次检查的说法（还差什么）
                if snap.get("activity") in ("busy", "waiting"):
                    goal.pop("note", None)
                elif idle >= GOAL_IDLE_PAUSE_MS or goal.get("note"):
                    goal["state"] = "paused"
            if goal and (goal.get("state") == "cleared" or goal.get("state") not in GOAL_RUNNING and now - (goal.get("at") or 0) > GOAL_KEEP_MS):
                goal = None   # 你自己清除的不用再看；结束了的挂一阵就收
            if goal:
                snap["goal"] = goal
            else:
                snap.pop("goal", None)
        for sid in [s for s in self.idle_since if s not in live]:
            del self.idle_since[sid]


GOALS = GoalBook()

# 标题只在 transcript 尾部偶尔出现，记住最近一次看到的，避免列表里标题忽有忽无
_TITLES = {}
_TITLE_SCANNED = set()
# 在 VS Code 里改过的名（custom-title）：标签页上显示它，之后再生成的 AI 标题不算（同扩展）
_CUSTOM_TITLES = {}
# Claude 没起成标题时扩展拿用户的话当标签名（见 tab_names）：第一句只取一次，最近一句随尾部更新
_FIRST_PROMPTS = {}
_LAST_PROMPTS = {}


def title_line(raw):
    """ai-title / custom-title 行 → (标题, 是不是改的名)；不是标题行返回 None"""
    if b'"ai-title"' not in raw[:200] and b'"custom-title"' not in raw[:200]:
        return None
    entry = parse_line(raw)
    for key, custom in (("customTitle", True), ("aiTitle", False)):
        if entry and isinstance(entry.get(key), str) and entry[key].strip():
            return entry[key].strip(), custom
    return None


def find_title(path):
    """尾部没读到标题时（比如最近几条带了大图），全文找最后一个标题（改过名的以改的为准）。每个会话只做一次。"""
    found = {}
    try:
        with open(path, "rb") as handle:
            for raw in handle:
                hit = title_line(raw)
                if hit:
                    found[hit[1]] = hit[0]
    except OSError:
        pass
    return found.get(True) or found.get(False)


def tab_names(session_id, transcript, scan):
    """没有标题（Claude 没起成，比如起标题的请求失败了）时 VS Code 标签页上显示的名字：扩展拿用户说的话当名字——
    当场发的标签是第一句，重开 VS Code 恢复的标签是那时的最近一句（扩展自己认标签也是这两个都算）。空 = 还没发过消息"""
    if scan["lastPrompt"]:
        _LAST_PROMPTS[session_id] = scan["lastPrompt"]
    if session_id not in _FIRST_PROMPTS and transcript:
        first = first_prompt(transcript)
        if first:
            _FIRST_PROMPTS[session_id] = first
    names = []
    for name in (_FIRST_PROMPTS.get(session_id), _LAST_PROMPTS.get(session_id)):
        name = " ".join((name or "").split())[:160]
        if name and name not in names:
            names.append(name)
    return names


# tmux pane 查找有成本，按 pid 缓存（pid 存活期间 pane 不会变）
_TMUX_PANES = {}


def snapshot_session(payload):
    session_id = payload.get("sessionId")
    cwd = payload.get("cwd") or ""
    status = payload.get("status")
    status = status if isinstance(status, str) else None
    waiting_for = mean_word(payload.get("waitingFor"))
    needs = summarize_needs(payload.get("needs"))
    detail = payload.get("detail") if isinstance(payload.get("detail"), str) else None
    entrypoint = payload.get("entrypoint") if isinstance(payload.get("entrypoint"), str) else None

    transcript = transcript_path(session_id, cwd)
    scan = scan_transcript(transcript)
    if scan["customTitle"]:
        _CUSTOM_TITLES[session_id] = scan["customTitle"]
    if scan["title"]:
        _TITLES[session_id] = scan["title"]
    elif session_id not in _TITLES and session_id not in _TITLE_SCANNED and transcript:
        _TITLE_SCANNED.add(session_id)
        found = find_title(transcript)
        if found:
            _TITLES[session_id] = found
    title = _CUSTOM_TITLES.get(session_id) or _TITLES.get(session_id)
    # 没有标题：拿 VS Code 标签上的名字（第一句）当标题，列表里认得出、投递时也对得上标签；tabNames 是标签可能显示的几个名字
    names = [] if title else tab_names(session_id, transcript, scan)
    pending_tool = scan["pendingTool"]
    pending_id = scan["pendingId"]
    message = scan["message"]
    # 在等确认、记录里却没有这次调用：从 mod 那里补（见 bridge_ask）
    ask = bridge_ask(session_id, payload.get("startedAt")) if (waiting_for or needs) and not pending_tool else None
    if ask:
        held = ask_item(session_id, ask, transcript)
        pending_tool, pending_id = held["name"], held["toolId"]
        questions = (held.get("input") or {}).get("questions") if held["name"] == "AskUserQuestion" else None
        first = questions[0] if isinstance(questions, list) and questions and isinstance(questions[0], dict) else {}
        if isinstance(first.get("question"), str) and first["question"].strip():
            waiting_for = first["question"].strip()
    else:
        _ASK_ITEMS.pop(session_id, None)

    if waiting_for:
        activity, reason = "waiting", waiting_for
    elif needs:
        activity, reason = "waiting", needs
    elif status and any(word in status.lower() for word in BUSY_WORDS):
        activity, reason = "busy", detail or scan["pendingBrief"]
    elif status:
        if pending_tool:
            activity, reason = "waiting", "等待确认：%s" % pending_tool
        else:
            activity, reason = "idle", message
    else:
        activity, reason = "idle", message

    pid = payload.get("pid")
    tmux_pane = None
    if entrypoint != "claude-vscode" and isinstance(pid, int):
        if pid not in _TMUX_PANES:
            _TMUX_PANES[pid] = find_tmux_pane(pid)
        tmux_pane = _TMUX_PANES[pid]

    updated = scan["mtime"]
    return {
        "pid": pid,
        "sessionId": session_id,
        "name": payload.get("name") or (session_id[:8] if session_id else "unknown"),
        "title": title or (_title_from(names[0]) if names else None),
        "tabNames": names or None,
        "cwd": cwd,
        "cwdShort": display_cwd(cwd),
        "status": status,
        "waitingFor": waiting_for,
        "needs": needs,
        "detail": detail,
        "activity": activity,
        "reason": reason,
        "activityText": scan["pendingBrief"],
        "message": message,
        "messageUuid": scan["messageUuid"],
        "turnFrom": scan.get("turnFrom"),
        "error": scan.get("error") if activity == "idle" else None,
        "effort": scan.get("effort"),
        "subagents": subagent_count(transcript),
        "pendingTool": pending_tool,
        "pendingId": pending_id,
        "startedAt": payload.get("startedAt"),
        "statusUpdatedAt": payload.get("statusUpdatedAt"),
        "updatedAt": payload.get("updatedAt"),
        "version": payload.get("version"),
        "entrypoint": entrypoint,
        "sessionKind": payload.get("kind") if isinstance(payload.get("kind"), str) else None,
        "tmuxPane": tmux_pane,
        "usage": _USAGE[session_id].summary() if session_id in _USAGE else None,
        "transcriptPath": transcript,
        "transcriptUpdatedAt": int(updated * 1000) if updated else None,
        # 这个 claude 进程加载了后台送达 mod：发消息、中断、确认、回答提问不用切到 VS Code（见 bridge_send）
        "bridge": bool(bridge_alive(session_id, payload.get("startedAt"))),
        # 排队等 Claude 读的话（见 bridge_queue）；None = mod 是老版本、改不了
        "queue": bridge_queue(session_id, payload.get("startedAt")),
    }


def signature(snap):
    """决定是否需要推送：状态或结论有变才推。"""
    return "|".join(str(x) for x in (
        snap.get("sessionId"), snap.get("status"), snap.get("waitingFor"),
        snap.get("needs"), snap.get("detail"), snap.get("activity"),
        snap.get("messageUuid"), snap.get("pendingId"), snap.get("title"), snap.get("turnFrom"),
        snap.get("activityText"), (snap.get("usage") or {}).get("context"), (snap.get("usage") or {}).get("cost"),
        snap.get("terminals"), (snap.get("stage") or {}).get("step"), (snap.get("stage") or {}).get("label"),
        (snap.get("stage") or {}).get("total"), (snap.get("stage") or {}).get("note"),
        (snap.get("goal") or {}).get("text"), (snap.get("goal") or {}).get("state"), (snap.get("goal") or {}).get("checks"),
        (snap.get("goal") or {}).get("note"), (snap.get("goal") or {}).get("tokens"),
        snap.get("bridge"), json.dumps(snap.get("queue"), ensure_ascii=False),
    ))


# ---------------------------------------------------------------------------
# transcript → 对话项
#
# 对话项（item）是给手机端渲染的最小单元，字段都很短：
#   id   "<行偏移>.<序号>"，同一行在实时增量与历史翻页里得到的 id 完全相同，客户端据此去重
#   t    user | text | thinking | tool | result | event | agent_image
#   ts   毫秒时间戳
# 图片不内联，只给引用 {"ref": "<行偏移>.<序号>", "mime": ...}，需要时用 media 请求取。
# ---------------------------------------------------------------------------

def parse_ts(value):
    if not isinstance(value, str) or not value:
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1]
    frac = 0.0
    if "." in text:
        text, rest = text.split(".", 1)
        digits = "".join(ch for ch in rest if ch.isdigit())
        frac = float("0." + digits) if digits else 0.0
    try:
        return int((calendar.timegm(time.strptime(text, "%Y-%m-%dT%H:%M:%S")) + frac) * 1000)
    except ValueError:
        return None


def clip(text, limit):
    if not isinstance(text, str):
        return "", False
    if len(text) <= limit:
        return text, False
    return text[:limit], True


def strip_reminders(text):
    """去掉 <system-reminder> 这类系统注入块（VS Code 面板里也不展示它们）。"""
    if not isinstance(text, str):
        return ""
    for tag in ("system-reminder", "ide_selection", "ide_opened_file"):
        open_tag, close_tag = "<%s>" % tag, "</%s>" % tag
        while True:
            start = text.find(open_tag)
            if start == -1:
                break
            end = text.find(close_tag, start)
            if end == -1:
                text = text[:start]
                break
            text = text[:start] + text[end + len(close_tag):]
    # 粘贴进输入框的整段（手机发来的消息就是这样送进 VS Code 的），Claude Code 会前后套一对
    # <pasted_content id="…"> 标签：只去掉标签，里面的字照常显示
    text = PASTED_TAG.sub("", text)
    return text.strip()


PASTED_TAG = re.compile(r'</?pasted_content\s+id="[0-9a-f]+"\s*>\n?')


def between(text, tag):
    start = text.find("<%s>" % tag)
    if start == -1:
        return None
    start += len(tag) + 2
    end = text.find("</%s>" % tag, start)
    return text[start:end if end != -1 else None].strip()


def shrink(value, depth=0):
    """工具输入可能很大（Write 的整份文件内容），逐字段截断后再给手机。"""
    if depth > 6:
        return "…"
    if isinstance(value, str):
        cut, truncated = clip(value, TOOL_INPUT_STRING_MAX)
        return cut + ("\n…（已截断，共 %d 字）" % len(value) if truncated else "")
    if isinstance(value, list):
        out = [shrink(item, depth + 1) for item in value[:60]]
        if len(value) > 60:
            out.append("…（共 %d 项）" % len(value))
        return out
    if isinstance(value, dict):
        return {str(k): shrink(v, depth + 1) for k, v in list(value.items())[:60]}
    return value


def iter_images(entry):
    """按固定顺序遍历一行里的所有图片块（规整与按引用取图共用，保证序号一致）。"""
    message = entry.get("message") if isinstance(entry, dict) else None
    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, list):
        return
    for block in content:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "image":
            yield block
        elif block.get("type") == "tool_result" and isinstance(block.get("content"), list):
            for inner in block["content"]:
                if isinstance(inner, dict) and inner.get("type") == "image":
                    yield inner


def image_meta(block):
    source = block.get("source") if isinstance(block.get("source"), dict) else {}
    data = source.get("data") if isinstance(source.get("data"), str) else ""
    return {"mime": source.get("media_type") or "image/png", "bytes": len(data) * 3 // 4}


ATTACH_PREFIX = "[附图] "
# 用户按 Esc 中断时 Claude Code 写进 transcript 的占位文本：显示成系统提示而不是用户消息
INTERRUPT_MARKERS = ("[Request interrupted by user]", "[Request interrupted by user for tool use]")


def split_attachments(text):
    """手机发图时消息末尾带「[附图] <inbox 里的路径>」行：拆出来变成图片引用，正文里不再显示路径。"""
    if ATTACH_PREFIX not in text:
        return text, []
    keep, refs = [], []
    inbox = os.path.realpath(INBOX_DIR)
    for line in text.split("\n"):
        stripped = line.strip()
        if stripped.startswith(ATTACH_PREFIX):
            path = stripped[len(ATTACH_PREFIX):].strip()
            if os.path.realpath(path).startswith(inbox + os.sep):
                refs.append({"ref": "f:" + path, "mime": mimetypes.guess_type(path)[0] or "image/jpeg"})
                continue
        keep.append(line)
    return "\n".join(keep).strip(), refs


def user_string_item(text, base):
    """content 是字符串的 user 行：可能是真人输入，也可能是斜杠命令、后台任务通知等。
    开头的零宽空格是手机经后台送达 mod 发来、以「/」开头的话垫的（见 BRIDGE_MOD_FILES），去掉"""
    raw = text.strip().lstrip("\u200b")
    if raw.startswith("<command-name>") or "<command-name>" in raw[:200]:
        name = between(raw, "command-name") or ""
        args = between(raw, "command-args") or ""
        item = dict(base, t="user", text=(name + " " + args).strip())
        return item if item["text"] else None
    if "<local-command-stdout>" in raw:
        item = goal_event(raw, base)
        if item:
            return item
        body = between(raw, "local-command-stdout") or ""
        body, _ = clip(body, TOOL_RESULT_MAX)
        return dict(base, t="event", text=body) if body else None
    if raw.startswith("<task-notification>"):
        summary = between(raw, "summary") or "后台任务有新状态"
        status = between(raw, "status") or ""
        return dict(base, t="event", text=summary, status=status)
    if raw.startswith("Another Claude session sent a message") or raw.startswith("<agent-message"):
        body, _ = clip(raw, TOOL_RESULT_MAX)
        return dict(base, t="event", text="子任务回报", detail=body)
    if raw in INTERRUPT_MARKERS:
        return dict(base, t="event", text="已中断")
    cleaned, attached = split_attachments(strip_reminders(raw))
    if not cleaned and not attached:
        return None
    cleaned, truncated = clip(cleaned, USER_TEXT_MAX)
    item = dict(base, t="user", text=cleaned)
    if attached:
        item["images"] = attached
    if truncated:
        item["truncated"] = True
    return item


COMPACT_TRAILERS = ("If you need specific details from before compaction", "Please continue the conversation",
                    "Continue the conversation from where")


def goal_event(text, base):
    """Claude Code 关于目标的系统消息（/goal 的回显、停下的提示）→ 对话里一行提示；不是这类返回 None。
    goal 字段给新客户端认（set / cleared / paused / error）"""
    raw = text.strip()
    if raw.startswith("<local-command-stdout>"):
        raw = (between(raw, "local-command-stdout") or "").strip()
    for prefix, label, kind in (("Goal set: ", "已设定目标", "set"), ("Goal cleared: ", "已清除目标", "cleared")):
        if raw.startswith(prefix):
            return dict(base, t="event", text=label, detail=raw[len(prefix):].strip() or None, goal=kind)
    hit = goal_notice(raw)
    if hit:
        state, note = hit
        if state == "error":
            return dict(base, t="event", level="error", text="目标因出错中止：%s" % note, goal="error")
        return dict(base, t="event", text="目标已暂停：%s" % note, goal="paused")
    return None


def goal_status_item(attachment, base):
    """每轮结束检查目标的结果 → 对话里一行提示，轻点看检查的说法（还差什么）；设定、清除那两条由 /goal 的回显显示"""
    if attachment.get("sentinel"):
        return None
    reason = attachment.get("reason")
    item = dict(base, t="event")
    if isinstance(reason, str) and reason.strip():
        item["detail"] = reason.strip()
    if attachment.get("met"):
        item.update(text="目标已达成", goal="met")
    elif attachment.get("failed"):
        item.update(text="目标无法达成", level="error", goal="failed")
    else:
        item.update(text="目标尚未达成，继续工作", goal="check")
    stats = {field: int(attachment[key]) for key, field in (("iterations", "turns"), ("durationMs", "durationMs"), ("tokens", "tokens"))
             if isinstance(attachment.get(key), (int, float))}
    if stats:
        item["goalStats"] = stats
    return item


def compact_summary_text(content):
    """前情摘要只留正文：去掉开头的固定说明、工具清单和结尾给 Claude 的续写指令"""
    if isinstance(content, list):
        content = "\n\n".join(block.get("text") for block in content
                              if isinstance(block, dict) and isinstance(block.get("text"), str))
    text = strip_reminders(content)
    start = text.find("Summary:")
    if start != -1:
        text = text[start + len("Summary:"):]
    for marker in COMPACT_TRAILERS:
        end = text.rfind(marker)
        if end != -1:
            text = text[:end]
            break
    text, _ = clip(text.strip(), USER_TEXT_MAX)
    return text


def peer_out_info(tool_input):
    """发出的消息：对方是谁（会话 id 对得上就带上）、摘要、正文开头"""
    sid, name = PEERS.resolve(tool_input.get("to"))
    text, _ = clip((tool_input.get("message") or "").strip() if isinstance(tool_input.get("message"), str) else "", PEER_TEXT_MAX)
    info = {"dir": "out", "to": tool_input.get("to"), "name": name, "session": sid,
            "summary": tool_input.get("summary") if isinstance(tool_input.get("summary"), str) else None, "text": text}
    return {k: v for k, v in info.items() if v}


def peer_in_item(base, origin, raw):
    """收到的消息：一条居中的事件（旧版 App 照常显示成一行字），新版按 peer 画成「来自某会话」的卡片"""
    body = peer_body(origin, raw)
    name = origin.get("name") if isinstance(origin.get("name"), str) else None
    sid = PEERS.pid_session(origin.get("verifiedPeerPid"))
    if sid is None and name:
        sid = PEERS.by_name.get(name)
    full, truncated = clip(body, USER_TEXT_MAX)
    preview, _ = clip(body, PEER_TEXT_MAX)
    peer = {"dir": "in", "name": name, "session": sid, "msgId": origin.get("msg_id"), "body": full, "text": preview}
    item = dict(base, t="event", text="来自 %s 的消息" % (name or "其他会话"), peer={k: v for k, v in peer.items() if v})
    if truncated:
        item["truncated"] = True
    return item


def result_item(block, base, image_refs):
    content = block.get("content")
    texts = []
    if isinstance(content, str):
        texts.append(content)
    elif isinstance(content, list):
        for inner in content:
            if isinstance(inner, dict) and inner.get("type") == "text" and isinstance(inner.get("text"), str):
                texts.append(inner["text"])
    text = strip_reminders("\n".join(texts))
    full_len = len(text)
    text, truncated = clip(text, TOOL_RESULT_MAX)
    item = dict(base, t="result", toolId=block.get("tool_use_id"), text=text,
                isError=bool(block.get("is_error")))
    if text.startswith("{") and '"msg_id"' in text:
        # SendMessage 的结果：带 msg_id（和收信那边配对），success = false 是没送到
        try:
            sent = json.loads(text)
            if isinstance(sent, dict) and isinstance(sent.get("msg_id"), str):
                item["msgId"] = sent["msg_id"]
                if sent.get("success") is False:
                    item["isError"] = True
        except ValueError:
            pass
    if truncated:
        item["truncated"] = True
        item["fullLength"] = full_len
    if image_refs:
        item["images"] = image_refs
    return item


# --- 会话之间的消息（Claude Code 的 SendMessage）---
# 发的一方：assistant 的 tool_use（name = SendMessage，input {to, message, summary}），结果文本是 JSON，带 msg_id。
# 收的一方：空闲时是一行 isMeta 的 user，忙时是 attachment（queued_command）；两种都带 origin =
#   {kind: "peer", from: "uds:…/<pid>.sock", verifiedPeerPid, msg_id, name, body}。
# 两边靠 msg_id 配对。「名字 / 进程号 → 会话」看 ~/.claude/sessions/<pid>.json；会话重启后名字会变，所以见到就记下。

PEER_TOOL = "SendMessage"
PEER_TEXT_MAX = 240          # 往来记录里正文只留个开头（卡片、协作图上看个大概，全文在对话里）
PEER_KEEP_MS = 3 * 86400000  # 内存里留几天的往来


def peer_origin(entry):
    """收到的跨会话消息：返回 origin（kind = peer），不是就返回 None"""
    origin = entry.get("origin")
    if not isinstance(origin, dict) and entry.get("type") == "attachment":
        attachment = entry.get("attachment") if isinstance(entry.get("attachment"), dict) else {}
        origin = attachment.get("origin")
    return origin if isinstance(origin, dict) and origin.get("kind") == "peer" else None


def user_origin(origin):
    """排队进来的话是不是用户说的：自己打的（没有来源 / human），或手机经后台送达 mod 发来的（kiteline 插件，见 bridge_send）"""
    kind = (origin or {}).get("kind")
    return kind in (None, "human") or (kind == "plugin" and origin.get("name") == BRIDGE_MOD_NAME)


def bridge_said(entry):
    """Claude 忙时手机发的话，后台送达 mod 在两次工具调用之间插进了这一轮：记录里是 isMeta 的 user 行、origin 是 kiteline 插件，
    文字块开头垫了零宽空格，照你说的话显示（VS Code 不显示 isMeta 行）。
    只认垫了零宽空格的：Claude Code 替插件执行斜杠命令时写的 <local-command-caveat> 说明、展开的技能正文也是 isMeta + kiteline 来源"""
    origin = entry.get("origin")
    if not (isinstance(origin, dict) and origin.get("kind") == "plugin" and origin.get("name") == BRIDGE_MOD_NAME):
        return False
    content = (entry.get("message") or {}).get("content")
    return isinstance(content, list) and any(
        isinstance(block, dict) and block.get("type") == "text" and str(block.get("text") or "").startswith("​") for block in content)


def peer_body(origin, raw):
    """收到的消息正文：优先 origin.body，老版本没有就从 <cross-session-message> 标签里抠"""
    body = origin.get("body")
    if isinstance(body, str) and body.strip():
        return body.strip()
    if isinstance(raw, list):
        raw = "\n".join(block.get("text") for block in raw if isinstance(block, dict) and isinstance(block.get("text"), str))
    if not isinstance(raw, str):
        return ""
    match = re.search(r"<cross-session-message[^>]*>(.*?)</cross-session-message>", raw, re.S)
    return (match.group(1) if match else strip_reminders(raw)).strip()


class PeerBook:
    """会话名、进程号 → 会话（见过就记着，会话退出、登记文件没了也还能对上），以及会话之间的消息往来"""

    def __init__(self):
        self.by_pid = {}        # pid -> sessionId
        self.by_name = {}       # 名字 -> sessionId（最近一次见到的）
        self.names = {}         # sessionId -> 名字
        self.links = {}         # 往来 id（msg_id；结果还没回来时是「t:工具调用 id」）-> 往来
        self.tools = {}         # (发信会话, 工具调用 id) -> 往来 id
        self.titles = {}        # 已经结束的会话的标题（补齐时从对话记录里读的；在线的用快照里的）
        self.changed = set()

    def learn(self, payload):
        """~/.claude/sessions/<pid>.json 的一份登记"""
        sid, pid, name = payload.get("sessionId"), payload.get("pid"), payload.get("name")
        if not sid:
            return
        if isinstance(pid, int):
            self.by_pid[pid] = sid
        if isinstance(name, str) and name:
            self.by_name[name] = sid
            self.names[sid] = name

    def resolve(self, target):
        """SendMessage 的 to（名字、「名字 [ref]」或 uds:…/<pid>.sock）→ (sessionId, 名字)"""
        if not isinstance(target, str) or not target.strip():
            return None, None
        target = target.strip()
        match = re.search(r"/(\d+)\.sock$", target)
        if match:
            sid = self.by_pid.get(int(match.group(1)))
            return sid, self.names.get(sid)
        name = re.sub(r"\s*\[[0-9a-fA-F]+\]$", "", target)
        return self.by_name.get(name), name

    def pid_session(self, pid):
        return self.by_pid.get(pid) if isinstance(pid, int) else None

    def _touch(self, link_id):
        self.changed.add(link_id)
        return self.links.setdefault(link_id, {"id": link_id})

    def observe(self, sid, items):
        """一个会话新解析出的对话项里认往来：发出（工具调用）、发出的结果（拿到 msg_id）、收到"""
        for item in items:
            peer = item.get("peer")
            kind = item.get("t")
            if kind == "tool" and isinstance(peer, dict):
                key = (sid, item.get("toolId"))
                link_id = self.tools.get(key) or "t:%s" % item.get("toolId")
                self.tools[key] = link_id
                link = self._touch(link_id)
                link.update({"from": sid, "sentAt": item.get("ts")})
                if peer.get("session"):
                    link["to"] = peer["session"]
                for field, value in (("toName", peer.get("name")), ("summary", peer.get("summary")), ("text", peer.get("text"))):
                    if value:
                        link[field] = value
            elif kind == "result" and item.get("msgId"):
                key = (sid, item.get("toolId"))
                old = self.tools.get(key)
                if old is None:
                    continue
                msg_id = item["msgId"]
                link = self.links.pop(old, {}) if old != msg_id else self.links.get(old, {})
                self.changed.discard(old)
                merged = self._touch(msg_id)
                for field, value in link.items():
                    if field != "id" and value is not None and not merged.get(field):
                        merged[field] = value
                merged["ok"] = not item.get("isError")
                self.tools[key] = msg_id
                if old != msg_id:
                    merged["was"] = old    # 客户端先收到的是旧 id：据此换成新的
            elif isinstance(peer, dict) and peer.get("dir") == "in" and peer.get("msgId"):
                link = self._touch(peer["msgId"])
                link["to"] = sid
                link["readAt"] = item.get("ts")
                if peer.get("session") and not link.get("from"):
                    link["from"] = peer["session"]
                if peer.get("name") and not link.get("fromName"):
                    link["fromName"] = peer["name"]
                if not link.get("text") and peer.get("text"):
                    link["text"] = peer["text"]

    def finish(self, link):
        """发出去之前补上名字、标题（会话标题是现成缓存的，不额外读文件）"""
        out = dict(link)
        for side in ("from", "to"):
            sid = out.get(side)
            if sid:
                out.setdefault(side + "Name", self.names.get(sid))
                title = _TITLES.get(sid) or self.titles.get(sid)
                if title:
                    out[side + "Title"] = title
        return {k: v for k, v in out.items() if v is not None}

    def drain(self):
        """拿走这一轮变了的往来（并顺手丢掉太旧的）"""
        if not self.changed:
            return []
        cutoff = _now_ms() - PEER_KEEP_MS
        for link_id in [k for k, v in self.links.items() if (v.get("sentAt") or v.get("readAt") or 0) < cutoff]:
            self.links.pop(link_id, None)
        out = [self.finish(self.links[k]) for k in self.changed if k in self.links]
        self.changed = set()
        return out

    def since(self, since_ms):
        return [self.finish(v) for v in self.links.values() if (v.get("sentAt") or v.get("readAt") or 0) >= since_ms]


PEERS = PeerBook()
_PEER_SCAN = {}    # 对话记录路径 -> 已经扫到的字节数（补齐往来时只读新增的部分）


def peer_scan(since_ms):
    """翻对话记录补齐某时间以来的往来（Kiteline 刚连上、协作图要看今天的）：只看这段时间里改过的记录，只解析带往来的行"""
    since_s = since_ms / 1000.0
    for path in globlib.glob(os.path.join(PROJECTS_DIR, "*", "*.jsonl")):
        try:
            stat = os.stat(path)
        except OSError:
            continue
        if stat.st_mtime < since_s:
            continue
        start = _PEER_SCAN.get(path, 0)
        if start > stat.st_size:
            start = 0    # 记录被重写了
        if start == stat.st_size:
            continue
        sid = os.path.basename(path)[:-len(".jsonl")]
        try:
            with open(path, "rb") as handle:
                handle.seek(start)
                data = handle.read()
        except OSError:
            continue
        end = data.rfind(b"\n") + 1     # 最后一行可能还没写完：留到下次
        _PEER_SCAN[path] = start + end
        items = []
        for raw in data[:end].split(b"\n"):
            if b"SendMessage" not in raw and b'"peer"' not in raw and b"msg_id" not in raw:
                continue
            entry = parse_line(raw)
            if entry is not None:
                items.extend(normalize_line(0, entry))
        if items:
            PEERS.observe(sid, items)
            if sid not in _TITLES and sid not in PEERS.titles:
                meta = session_meta(path) or {}
                PEERS.titles[sid] = meta.get("title") or (meta.get("firstPrompt") or "")[:40] or None
    PEERS.changed = set()    # 补齐的不算「刚发生」，别让实时事件再推一遍、触发动画
    return PEERS.since(since_ms)


def normalize_subagent_line(offset, entry):
    """子 agent 自己的记录文件（subagents/agent-*.jsonl）：每一行都标着 isSidechain（主对话里要跳过它们），这里照常认"""
    if isinstance(entry, dict) and entry.get("isSidechain"):
        entry = dict(entry, isSidechain=False)
    return normalize_line(offset, entry)


def normalize_line(offset, entry):
    """一行 transcript → 若干对话项。认不出的行返回空列表（不会报错）。"""
    if not isinstance(entry, dict) or entry.get("isSidechain"):
        return []
    etype = entry.get("type")
    ts = parse_ts(entry.get("timestamp"))
    items = []

    def base():
        return {"id": "%d.%d" % (offset, len(items)), "ts": ts}

    if etype == "system":
        subtype = entry.get("subtype")
        if subtype == "compact_boundary":
            # 「上下文已压缩」由紧跟其后的摘要行（isCompactSummary）显示，带上摘要正文，免得出两行
            return items
        elif subtype == "api_error":
            # 只在重试用尽时露出，网络抖动的中间重试不打扰
            if entry.get("retryAttempt") and entry.get("retryAttempt") >= (entry.get("maxRetries") or 0):
                error = entry.get("error") if isinstance(entry.get("error"), dict) else {}
                items.append(dict(base(), t="event", level="error",
                                  text="接口出错：%s" % (error.get("formatted") or error.get("message") or "未知")))
        elif isinstance(entry.get("content"), str) and entry["content"].strip():
            if entry["content"].startswith("kiteline: "):
                # 我们自己的 mod 的提示（「kiteline: reloaded (6 hooks: …)」）：给开发看的，不进对话
                return items
            item = goal_event(entry["content"], base())
            if item is None:
                # 斜杠命令的回显（/model、/goal 不带参数……）：去掉外面那层标签
                raw = entry["content"]
                if "<local-command-stdout>" in raw or "<local-command-stderr>" in raw:
                    raw = between(raw, "local-command-stdout") or between(raw, "local-command-stderr") or ""
                text, _ = clip(strip_reminders(raw), TOOL_RESULT_MAX)
                item = dict(base(), t="event", text=text) if text else None
            if item:
                items.append(item)
        return items

    if etype == "attachment":
        # Claude 忙的时候用户插进来的话（VS Code 里排队、中途被吸收）记在这里
        attachment = entry.get("attachment") if isinstance(entry.get("attachment"), dict) else {}
        if attachment.get("type") == "goal_status":
            item = goal_status_item(attachment, base())
            return [item] if item else []
        if attachment.get("type") != "queued_command":
            return []
        origin = peer_origin(entry)
        if origin is not None:
            items.append(peer_in_item(base(), origin, attachment.get("prompt")))
            return items
        origin = attachment.get("origin") if isinstance(attachment.get("origin"), dict) else {}
        if not user_origin(origin):
            return []
        prompt = attachment.get("prompt")
        if isinstance(prompt, str):
            text = prompt
        elif isinstance(prompt, list):
            text = "\n\n".join(block.get("text") for block in prompt
                               if isinstance(block, dict) and isinstance(block.get("text"), str))
        else:
            text = ""
        text, attached = split_attachments(strip_reminders(text))
        if text or attached:
            text, _ = clip(text, USER_TEXT_MAX)
            item = dict(base(), ts=parse_ts(attachment.get("timestamp")) or ts, t="user", text=text, queued=True)
            if attached:
                item["images"] = attached
            items.append(item)
        return items

    message = entry.get("message")
    if not isinstance(message, dict):
        return []
    content = message.get("content")

    if etype == "user":
        if entry.get("isCompactSummary"):
            # 压缩上下文时 Claude Code 以用户身份写回的前情摘要，不是用户发的：显示成一行提示，轻点看摘要
            item = dict(base(), t="event", text="上下文已压缩")
            summary = compact_summary_text(content)
            if summary:
                item["detail"] = summary
            return [item]
        if entry.get("isMeta") and not bridge_said(entry):
            origin = peer_origin(entry)
            if origin is not None:
                items.append(peer_in_item(base(), origin, content))
            return items
        if isinstance(content, str):
            item = user_string_item(content, base())
            return [item] if item else []
        if not isinstance(content, list):
            return []
        image_index = 0
        texts = []
        user_images = []
        results = []
        for block in content:
            if not isinstance(block, dict):
                continue
            btype = block.get("type")
            if btype == "text":
                cleaned = strip_reminders(block.get("text")).lstrip("​")
                if cleaned:
                    texts.append(cleaned)
            elif btype == "image":
                user_images.append(dict(image_meta(block), ref="%d.%d" % (offset, image_index)))
                image_index += 1
            elif btype == "tool_result":
                refs = []
                inner_content = block.get("content")
                if isinstance(inner_content, list):
                    for inner in inner_content:
                        if isinstance(inner, dict) and inner.get("type") == "image":
                            refs.append(dict(image_meta(inner), ref="%d.%d" % (offset, image_index)))
                            image_index += 1
                results.append((block, refs))
        if texts and all(text.strip() in INTERRUPT_MARKERS for text in texts) and not user_images:
            items.append(dict(base(), t="event", text="已中断"))
            texts = []
        if texts or user_images:
            text, attached = split_attachments("\n\n".join(texts))
            user_images.extend(attached)
            text, truncated = clip(text, USER_TEXT_MAX)
            item = dict(base(), t="user", text=text)
            if user_images:
                item["images"] = user_images
            if truncated:
                item["truncated"] = True
            items.append(item)
        for block, refs in results:
            items.append(result_item(block, base(), refs))
        return items

    if etype == "assistant" and isinstance(content, list) and entry.get("isApiErrorMessage"):
        # Claude 因为接口错误停下：显示成一条红色提示，不当成 Claude 的回复
        info = api_error_info(message_from_blocks(content) or "", ts)
        items.append(dict(base(), t="event", level="error", text=info["text"], errorKind=info["kind"], resetAt=info["resetAt"]))
        return items

    if etype == "assistant" and isinstance(content, list):
        model = message.get("model")
        for block in content:
            if not isinstance(block, dict):
                continue
            btype = block.get("type")
            if btype == "text":
                text = block.get("text")
                if isinstance(text, str) and text.strip():
                    text, truncated = clip(text, ASSISTANT_TEXT_MAX)
                    item = dict(base(), t="text", text=text)
                    if truncated:
                        item["truncated"] = True
                    items.append(item)
            elif btype in ("thinking", "redacted_thinking"):
                thought = block.get("thinking") if btype == "thinking" else ""
                thought, _ = clip(thought if isinstance(thought, str) else "", ASSISTANT_TEXT_MAX)
                items.append(dict(base(), t="thinking", text=thought))
            elif btype == "tool_use":
                name = block.get("name") or "tool"
                item = dict(base(), t="tool", toolId=block.get("id"), name=name,
                            brief=tool_brief(name, block.get("input")),
                            input=shrink(block.get("input")), **stage_hint(name, block.get("input")))
                if name == PEER_TOOL and isinstance(block.get("input"), dict):
                    item["peer"] = peer_out_info(block["input"])
                items.append(item)
        if items and model:
            items[0]["model"] = model
        return items

    return []


def parse_line(raw):
    raw = raw.strip()
    if not raw or not raw.startswith(b"{"):
        return None
    try:
        entry = json.loads(raw.decode("utf-8", "replace"))
    except ValueError:
        return None
    return entry if isinstance(entry, dict) else None


def read_line_at(path, offset):
    """读出从 offset 开始的一整行（图片所在行可能有几 MB，分块读）。"""
    try:
        with open(path, "rb") as handle:
            handle.seek(offset)
            chunks = []
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                cut = chunk.find(b"\n")
                if cut != -1:
                    chunks.append(chunk[:cut])
                    break
                chunks.append(chunk)
            return b"".join(chunks)
    except OSError:
        return None


def read_history(path, before, limit, normalize=None):
    """从 before（行起始偏移，不含）向前读，返回 (items, has_more, end)。

    按行倒着读，凑够 limit 行「有内容的行」就停。end 是本页覆盖到的文件位置，
    只在拉最新一页时有意义。未以换行结尾的最后一行视为还在写，不读。
    """
    try:
        size = os.path.getsize(path)
    except OSError:
        return [], False, 0
    end = size if before is None else max(0, min(int(before), size))
    if before is None and end > 0:
        # 丢掉还没写完的最后一行
        with open(path, "rb") as handle:
            back = max(0, end - 1)
            handle.seek(back)
            if handle.read(1) != b"\n":
                pos = end
                while pos > 0:
                    step = min(65536, pos)
                    handle.seek(pos - step)
                    block = handle.read(step)
                    cut = block.rfind(b"\n")
                    if cut != -1:
                        end = pos - step + cut + 1
                        break
                    pos -= step
                else:
                    end = 0
    lines_out = []   # 每行的对话项，倒序收集
    content_lines = 0
    remainder = b""
    pos = end
    earliest = end   # 已处理到的最早行起点；> 0 说明前面还有内容
    chunk_size = 256 * 1024
    with open(path, "rb") as handle:
        while pos > 0 and content_lines < limit:
            step = min(chunk_size, pos)
            pos -= step
            handle.seek(pos)
            # remainder 是上一块（更靠后）开头那段不完整的行尾，拼回来成整行
            data = handle.read(step) + remainder
            parts = data.split(b"\n")
            # parts[0] 可能是被截断的行头，留给下一轮（除非已经读到文件开头）
            remainder = parts[0] if pos > 0 else b""
            line_parts = parts[1:] if pos > 0 else parts
            cursor = pos + len(parts[0]) + 1 if pos > 0 else pos
            offsets = []
            for part in line_parts:
                offsets.append(cursor)
                cursor += len(part) + 1
            for index in range(len(line_parts) - 1, -1, -1):
                raw = line_parts[index]
                if not raw:
                    continue
                earliest = offsets[index]
                entry = parse_line(raw)
                if entry is None:
                    continue
                items = (normalize or normalize_line)(offsets[index], entry)
                if items:
                    lines_out.append(items)
                    content_lines += 1
                    if content_lines >= limit:
                        break
    # 粗略即可：前面哪怕只剩无内容的行，客户端多翻一页拿到空列表也就停了
    has_more = earliest > 0
    items = []
    for chunk in reversed(lines_out):
        items.extend(chunk)
    return items, has_more, end


class Tailer:
    """跟踪一个文件的增长，只吐完整的新行。首次见到时从文件末尾开始（不回放历史）。"""

    def __init__(self, path):
        self.path = path
        try:
            self.offset = os.path.getsize(path)
        except OSError:
            self.offset = 0
        self.missing = not os.path.exists(path)

    def poll(self):
        """返回 (lines[(offset, bytes)], was_reset)。"""
        try:
            size = os.path.getsize(self.path)
        except OSError:
            self.missing = True
            return [], False
        if self.missing:
            # 文件刚出现：新会话的 transcript 从头读
            self.missing = False
            self.offset = 0
        if size < self.offset:
            self.offset = size
            return [], True
        if size == self.offset:
            return [], False
        read_to = min(size, self.offset + TAIL_READ_MAX)
        try:
            with open(self.path, "rb") as handle:
                handle.seek(self.offset)
                data = handle.read(read_to - self.offset)
        except OSError:
            return [], False
        cut = data.rfind(b"\n")
        if cut == -1:
            if read_to - self.offset >= TAIL_READ_MAX:
                # 单行超过上限（极少见）：跳过它，避免卡死
                self.offset = read_to
            return [], False
        lines = []
        cursor = self.offset
        for raw in data[:cut].split(b"\n"):
            lines.append((cursor, raw))
            cursor += len(raw) + 1
        self.offset += cut + 1
        return lines, False


# ---------------------------------------------------------------------------
# 智能体发图（outbox）
# 每个会话一个 JSON Lines 文件：~/.ccpulse/outbox/<sessionId>.jsonl
# 一行 = 一次发送：{"ts", "caption", "files": [{"path", "mime", "name"}]}
# ---------------------------------------------------------------------------

def outbox_path(session_id):
    return os.path.join(OUTBOX_DIR, "%s.jsonl" % session_id)


def outbox_item(offset, entry):
    kind = entry.get("kind")
    if kind == "todo":
        # agent 记的待办（todo 子命令）：forUser = 只有用户能做的事（电脑端提醒用户：现在处理，或加入他的待办）；
        # 否则是 agent 自己以后要做的（电脑端记进「agent 的待办」，用户只看是哪个会话在处理、到哪一步了）
        return {"id": "o%d" % offset, "ts": entry.get("ts"), "t": "agent_todo", "text": entry.get("text") or "",
                "detail": entry.get("detail") or "", "forUser": bool(entry.get("forUser")), "ref": entry.get("ref") or ""}
    if kind == "todo_update":
        # agent 更新自己的待办（todo start / progress / done）：电脑端按编号改状态、进度、在处理的会话；
        # 不认识这种条目的客户端当一行提示显示 text
        status = entry.get("status") or "doing"
        label = {"done": "已完成", "doing": "进行中"}.get(status, status)
        progress = entry.get("progress") or ""
        return {"id": "o%d" % offset, "ts": entry.get("ts"), "t": "agent_todo_update", "ref": entry.get("ref") or "",
                "status": status, "progress": progress, "title": entry.get("title") or "",
                "text": "待办「%s」%s%s" % (entry.get("title") or entry.get("ref") or "", label, "：" + progress if progress else "")}
    if kind == "key":
        # 关键信息（keyinfo 子命令）：text 是拼好的纯文字，收藏、搜索、不认识这种条目的老客户端都用它
        fields = [f for f in entry.get("fields") or [] if isinstance(f, dict)]
        lines = [entry.get("title") or ""] + [("%s：%s" % (f.get("name"), f.get("value")) if f.get("name") else str(f.get("value") or ""))
                                             for f in fields]
        if entry.get("note"):
            lines.append(entry["note"])
        return {"id": "o%d" % offset, "ts": entry.get("ts"), "t": "agent_key", "title": entry.get("title") or "",
                "fields": fields, "note": entry.get("note") or "", "text": "\n".join(lines)}
    if kind == "group":
        # 发到会话群的消息（group say）：电脑端投递给群里其他会话；对话里画成一封发往群的信，不认识的客户端显示 text
        item = {"id": "o%d" % offset, "ts": entry.get("ts"), "t": "group_say", "group": entry.get("group") or "",
                "text": entry.get("text") or ""}
        if isinstance(entry.get("to"), list):
            item["to"] = [str(x) for x in entry["to"]][:20]
        if entry.get("name"):
            item["name"] = str(entry["name"])[:40]
        return item
    files = entry.get("files") if isinstance(entry.get("files"), list) else []
    if kind == "page":
        # agent 发来的网页（send-page）：各端画成一张「页面」卡片，手机上在 App 里打开、电脑上用浏览器打开；
        # 网页本身照图片的路子取（media，ref 同 agent_image）。不认识的老客户端当一行提示显示 text
        title = entry.get("title") or "页面"
        caption = entry.get("caption") or ""
        pages = [{"ref": "o%d.%d" % (offset, index), "mime": info.get("mime") or "text/html", "name": info.get("name")}
                 for index, info in enumerate(files) if isinstance(info, dict)]
        return {"id": "o%d" % offset, "ts": entry.get("ts"), "t": "agent_page", "title": title, "caption": caption,
                "images": pages, "text": "发来网页「%s」%s" % (title, "：" + caption if caption else "")}
    images = []
    for index, info in enumerate(files):
        if isinstance(info, dict):
            images.append({"ref": "o%d.%d" % (offset, index), "mime": info.get("mime") or "image/png",
                           "name": info.get("name")})
    return {"id": "o%d" % offset, "ts": entry.get("ts"), "t": "agent_image",
            "text": entry.get("caption") or "", "images": images}


def read_outbox(session_id, ts_from=None, ts_to=None):
    path = outbox_path(session_id)
    items = []
    try:
        with open(path, "rb") as handle:
            offset = 0
            for raw in handle:
                line_offset = offset
                offset += len(raw)
                entry = parse_line(raw)
                if entry is None:
                    continue
                ts = entry.get("ts") or 0
                if ts_from is not None and ts < ts_from:
                    continue
                if ts_to is not None and ts >= ts_to:
                    continue
                items.append(outbox_item(line_offset, entry))
    except OSError:
        pass
    return items


def resolve_calling_session(pid_only=False):
    """send-image 在智能体的 Bash 里执行：沿父进程链往上找，第一个在注册表里的 pid 就是它的会话。
    pid_only：认不出时不按当前目录猜（别家 agent 的会话交给 find_calling_session 的会话表）"""
    chain = set(ancestors(os.getpid()))
    registry = []
    try:
        names = os.listdir(SESSIONS_DIR)
    except OSError:
        names = []
    for name in names:
        if not name.endswith(".json"):
            continue
        raw = read_text(os.path.join(SESSIONS_DIR, name))
        try:
            payload = json.loads(raw) if raw else None
        except ValueError:
            payload = None
        if isinstance(payload, dict) and payload.get("sessionId"):
            registry.append(payload)
    for payload in registry:
        if payload.get("pid") in chain:
            return payload
    if pid_only:
        return None
    # 退路：按当前目录匹配最近活跃的会话
    cwd = os.getcwd()
    candidates = [p for p in registry if isinstance(p.get("cwd"), str)
                  and (cwd == p["cwd"] or cwd.startswith(p["cwd"].rstrip("/") + "/"))
                  and is_live(p)]
    candidates.sort(key=lambda p: (len(p["cwd"]), p.get("updatedAt") or 0), reverse=True)
    return candidates[0] if candidates else None


def command_send_image(argv):
    caption = ""
    session_id = None
    files = []
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg in ("--caption", "-m") and index + 1 < len(argv):
            caption = argv[index + 1]
            index += 2
            continue
        if arg == "--session" and index + 1 < len(argv):
            session_id = argv[index + 1]
            if not _SID_RE.match(session_id):
                print("会话 id 不对：%s" % session_id, file=sys.stderr)
                return 2
            index += 2
            continue
        if arg in ("-h", "--help"):
            print("用法: ccpulse-watch.py send-image <图片>... [--caption 说明] [--session 会话id]")
            return 0
        files.append(arg)
        index += 1
    if not files:
        print("没有指定图片。用法: ccpulse-watch.py send-image <图片>... [--caption 说明]", file=sys.stderr)
        return 2

    session_id, name = target_session(session_id)
    if not session_id:
        return 3

    stored_dir = os.path.join(OUTBOX_DIR, "files")
    os.makedirs(stored_dir, exist_ok=True)
    stored = []
    for path in files:
        path = os.path.abspath(os.path.expanduser(path))
        ext = os.path.splitext(path)[1].lower()
        if ext not in IMAGE_EXTS:
            print("不是支持的图片格式（png/jpg/gif/webp）：%s" % path, file=sys.stderr)
            return 4
        try:
            size = os.path.getsize(path)
        except OSError:
            print("文件不存在：%s" % path, file=sys.stderr)
            return 4
        if size > SEND_IMAGE_MAX:
            print("图片太大（%.1f MB，上限 15 MB）：%s" % (size / 1048576.0, path), file=sys.stderr)
            return 4
        target = os.path.join(stored_dir, uuid.uuid4().hex + ext)
        filename = os.path.basename(path)
        # SVG 手机和电脑客户端都显示不了：能转就转成 PNG 发，转不了照旧发 SVG
        png = svg_to_png(path, os.path.splitext(target)[0] + ".png") if ext == ".svg" else None
        if png:
            target, filename = png, os.path.splitext(filename)[0] + ".png"
        else:
            # 复制一份：原文件之后可能被覆盖（比如每次截图都写同一个名字）
            shutil.copyfile(path, target)
        mime = "image/png" if png else "image/svg+xml" if ext == ".svg" else (mimetypes.guess_type(path)[0] or "image/png")
        stored.append({"path": target, "mime": mime, "name": filename})

    os.makedirs(OUTBOX_DIR, exist_ok=True)
    entry = {"ts": int(time.time() * 1000), "caption": caption, "files": stored}
    with open(outbox_path(session_id), "a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry, ensure_ascii=False) + "\n")
    print("已发送 %d 张图片到用户手机（会话 %s）" % (len(stored), name or session_id[:8]))
    todo_nudge(session_id)
    stage_nudge(session_id)
    return 0


_PAGE_REF = re.compile(r"""(<(?:img|script|source)\b[^>]*?\bsrc\s*=\s*|<link\b[^>]*?\bhref\s*=\s*)(["'])([^"']+)\2""", re.I)


def _inline_page(html, base):
    """send-page：网页里引用的同目录文件（图片、CSS、JS）换成 data: 地址打包进去，手机上单独一个文件也能显示全。
    http(s)、//、data:、# 开头的不动（CDN 脚本照常从网上加载）；读不到的也不动"""
    def swap(match):
        prefix, quote, ref = match.group(1), match.group(2), match.group(3)
        if re.match(r"^(?:[a-z][a-z0-9+.-]*:|//|#)", ref, re.I):
            return match.group(0)
        path = os.path.normpath(os.path.join(base, ref.split("?")[0].split("#")[0]))
        try:
            if os.path.getsize(path) > SEND_IMAGE_MAX:
                return match.group(0)
            with open(path, "rb") as handle:
                data = handle.read()
        except OSError:
            return match.group(0)
        mime = mimetypes.guess_type(path)[0] or "application/octet-stream"
        return "%s%s%s%s" % (prefix, quote, "data:%s;base64,%s" % (mime, base64.b64encode(data).decode("ascii")), quote)
    return _PAGE_REF.sub(swap, html)


def command_send_page(argv):
    title, caption, session_id, source = "", "", None, None
    index = 0
    while index < len(argv):
        arg = argv[index]
        value = argv[index + 1] if index + 1 < len(argv) else None
        if arg == "--title" and value is not None:
            title = value; index += 2; continue
        if arg in ("--caption", "-m") and value is not None:
            caption = value; index += 2; continue
        if arg == "--session" and value is not None:
            session_id = value
            if not _SID_RE.match(session_id):
                print("会话 id 不对：%s" % session_id, file=sys.stderr)
                return 2
            index += 2; continue
        if arg in ("-h", "--help"):
            print("用法: ccpulse-watch.py send-page <html文件> [--title 标题] [--caption 说明] [--session 会话id]")
            return 0
        source = arg
        index += 1
    if not source:
        print("没有指定网页。用法: ccpulse-watch.py send-page <html文件> [--title 标题] [--caption 说明]", file=sys.stderr)
        return 2
    path = os.path.abspath(os.path.expanduser(source))
    if os.path.splitext(path)[1].lower() not in (".html", ".htm"):
        print("不是网页文件（.html / .htm）：%s" % path, file=sys.stderr)
        return 4
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError:
        print("文件不存在：%s" % path, file=sys.stderr)
        return 4
    html = _inline_page(raw.decode("utf-8", "replace"), os.path.dirname(path))
    data = html.encode("utf-8")
    if len(data) > SEND_IMAGE_MAX:
        print("网页太大（连同引用的文件 %.1f MB，上限 15 MB）：%s" % (len(data) / 1048576.0, path), file=sys.stderr)
        return 4
    if not title:
        found = re.search(r"<title[^>]*>(.*?)</title>", html, re.I | re.S)
        title = re.sub(r"\s+", " ", found.group(1)).strip() if found else ""
        title = title or os.path.splitext(os.path.basename(path))[0]

    session_id, name = target_session(session_id)
    if not session_id:
        return 3
    stored_dir = os.path.join(OUTBOX_DIR, "files")
    os.makedirs(stored_dir, exist_ok=True)
    target = os.path.join(stored_dir, uuid.uuid4().hex + ".html")
    with open(target, "wb") as handle:
        handle.write(data)
    append_outbox(session_id, {"kind": "page", "title": title[:200], "caption": caption,
                               "files": [{"path": target, "mime": "text/html", "name": os.path.basename(path)}]})
    print("已发送网页「%s」到用户手机（会话 %s）" % (title[:60], name or session_id[:8]))
    todo_nudge(session_id)
    stage_nudge(session_id)
    return 0


PROMPT_LINK_BASE = "https://tars.betac.cn/new"


def prompt_link(prompt, project=None):
    """提示词链接（各端 PromptLink 解析同一个格式）：提示词放在 # 后面，浏览器不会把它发到服务器"""
    from urllib.parse import quote
    link = PROMPT_LINK_BASE + "#p=" + quote(prompt, safe="")
    if project:
        link += "&project=" + quote(project, safe="")
    return link


def command_prompt_link(argv):
    prompt, project, use_cwd = None, None, True
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "--project" and index + 1 < len(argv):
            project = argv[index + 1]; index += 2; continue
        if arg == "--no-project":
            use_cwd = False; index += 1; continue
        if arg in ("-h", "--help"):
            print("用法: ccpulse-watch.py prompt-link <提示词|-> [--project 项目名|路径|owner/repo] [--no-project]")
            return 0
        prompt = arg
        index += 1
    if prompt == "-":
        prompt = sys.stdin.read()
    prompt = (prompt or "").strip()
    if not prompt:
        print("没有提示词。用法: ccpulse-watch.py prompt-link <提示词> [--project 项目名]", file=sys.stderr)
        return 2
    if project is None and use_cwd:
        project = os.path.basename(os.getcwd().rstrip("/\\")) or None
    print(prompt_link(prompt, project))
    return 0


# ---------------------------------------------------------------------------
# 截图（shot）：让智能体在没有图形界面的远端也能给用户发截图
#   网页 → 本机任意一个无头浏览器（Chrome / Chromium / Edge / Playwright 自带的 / Firefox）
#   文本 → 渲染成深色终端风格的图；有浏览器就截 HTML，没有就直接生成 SVG
# ---------------------------------------------------------------------------

def find_browser():
    """返回 (可执行文件, 类型)；类型是 chrome / chrome-shell / firefox。找不到返回 (None, None)。
    Windows 上 Chrome / Edge 不在 PATH 里，要按安装位置找（以前漏了：Windows 上截网页失败、测试报告只能退回 SVG 文字总览，
    客户端显示不了，对话里那张图一直是灰块）"""
    import glob
    override = os.environ.get("CCPULSE_BROWSER")
    if override and os.path.exists(override):
        kind = "firefox" if "firefox" in override.lower() else ("chrome-shell" if "headless-shell" in override else "chrome")
        return override, kind
    for name in ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "microsoft-edge", "brave-browser"):
        path = shutil.which(name)
        if path:
            return path, "chrome"
    local = os.environ.get("LOCALAPPDATA") or ""
    programs = [os.environ.get(k) or "" for k in ("PROGRAMFILES", "PROGRAMFILES(X86)")]
    for path in (["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                  "/Applications/Chromium.app/Contents/MacOS/Chromium",
                  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
                  "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
                  "/opt/google/chrome/chrome", "/opt/microsoft/msedge/msedge"]
                 + [os.path.join(p, "Google", "Chrome", "Application", "chrome.exe") for p in programs + [local] if p]
                 + [os.path.join(p, "Microsoft", "Edge", "Application", "msedge.exe") for p in programs if p]):
        if os.path.exists(path):
            return path, "chrome"
    # Playwright 下载的浏览器（新版 Chromium 换成了 Chrome for Testing，Mac 上的程序名跟着变了）
    caches = [os.environ.get("PLAYWRIGHT_BROWSERS_PATH") or "", os.path.join(HOME, ".cache", "ms-playwright"),
              os.path.join(HOME, "Library", "Caches", "ms-playwright"), os.path.join(local, "ms-playwright") if local else ""]
    patterns = (("chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell", "chrome-shell"),
                ("chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell.exe", "chrome-shell"),
                ("chromium_headless_shell-*/chrome-win*/headless_shell.exe", "chrome-shell"),
                ("chromium-*/chrome-linux*/chrome", "chrome"),
                ("chromium-*/chrome-win*/chrome.exe", "chrome"),
                ("chromium-*/chrome-mac*/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing", "chrome"),
                ("chromium-*/chrome-mac*/Chromium.app/Contents/MacOS/Chromium", "chrome"))
    for root in filter(None, caches):
        for pattern, kind in patterns:
            found = sorted(glob.glob(os.path.join(root, pattern)))
            if found:
                return found[-1], kind
    for path in (shutil.which("firefox"), "/Applications/Firefox.app/Contents/MacOS/firefox"):
        if path and os.path.exists(path):
            return path, "firefox"
    return None, None


def file_url(path):
    """本地文件的 file:// 地址（Windows 盘符、中文路径都要编码对）"""
    import pathlib
    return pathlib.Path(os.path.abspath(path)).as_uri()


def _chrome_command(path, kind, profile, width, height, scale, wait_ms, no_sandbox):
    cmd = [path, "--headless=new" if kind == "chrome" else "--headless", "--disable-gpu", "--hide-scrollbars",
           "--no-first-run", "--no-default-browser-check", "--mute-audio", "--user-data-dir=" + profile,
           "--window-size=%d,%d" % (width, height), "--force-device-scale-factor=%s" % scale,
           "--virtual-time-budget=%d" % wait_ms]
    if no_sandbox or (hasattr(os, "geteuid") and os.geteuid() == 0):
        cmd.insert(1, "--no-sandbox")
    return cmd


def _sandbox_attempts(kind):
    # Ubuntu 23.10+ 默认禁用了非特权用户命名空间，Chromium 沙箱起不来：Linux 上失败时带 --no-sandbox 再试一次
    return [False, True] if (kind != "firefox" and sys.platform.startswith("linux")) else [False]


def browser_screenshot(url, out, width, height, scale=2, wait_ms=2500):
    path, kind = find_browser()
    if not path:
        raise RuntimeError("这台机器上没找到可用的浏览器（Chrome / Chromium / Edge / Firefox），截不了网页")
    out = os.path.abspath(out)
    for no_sandbox in _sandbox_attempts(kind):
        profile = tempfile.mkdtemp(prefix="ccpulse-shot-")
        try:
            if kind == "firefox":
                cmd = [path, "--headless", "--no-remote", "--profile", profile, "--screenshot", out,
                       "--window-size=%d,%d" % (width, height), url]
            else:
                cmd = _chrome_command(path, kind, profile, width, height, scale, wait_ms, no_sandbox) + ["--screenshot=" + out, url]
            subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=90)
        except subprocess.TimeoutExpired:
            pass
        finally:
            shutil.rmtree(profile, ignore_errors=True)
        if os.path.exists(out) and os.path.getsize(out) > 100:
            return out
    raise RuntimeError("浏览器没有产出截图（%s）" % os.path.basename(path))


def _svg_size(path):
    """SVG 根标签上写的宽高（px）；只有 viewBox 的按它算，都没有（或写的百分比）给 800×600"""
    try:
        with open(path, "rb") as handle:
            head = handle.read(8192).decode("utf-8", "replace")
    except OSError:
        return 800, 600
    match = re.search(r"<svg\b[^>]*>", head)
    tag = match.group(0) if match else ""

    def number(name):
        found = re.search(r"""(?<![-\w])%s\s*=\s*["']\s*([0-9.]+)\s*(?:px)?\s*["']""" % name, tag)
        try:
            return float(found.group(1)) if found else None
        except ValueError:
            return None

    width, height = number("width"), number("height")
    box = re.search(r"""(?<![-\w])viewBox\s*=\s*["']\s*[-0-9.]+[\s,]+[-0-9.]+[\s,]+([0-9.]+)[\s,]+([0-9.]+)""", tag)
    if box and not (width and height):
        box_w, box_h = float(box.group(1)), float(box.group(2))
        if width and box_w:
            height = width * box_h / box_w
        elif height and box_h:
            width = height * box_w / box_h
        else:
            width, height = box_w, box_h
    if not width or not height:
        return 800, 600
    return max(16, min(int(round(width)), 4000)), max(16, min(int(round(height)), 4000))


def svg_to_png(path, out):
    """SVG 换成 PNG 再发：iPhone 解不了 SVG，Mac 自带的解码画不对文字，Windows / Linux 客户端解不出（对话里一直是灰块）。
    用无头浏览器按 SVG 自己的尺寸截 2 倍图；没有浏览器、或截不出来返回 None"""
    if not find_browser()[0]:
        return None
    width, height = _svg_size(path)
    try:
        return browser_screenshot(file_url(path), out, width, height, scale=2 if max(width, height) <= 2000 else 1, wait_ms=500)
    except Exception:
        return None


def browser_dump_dom(url, width, height, wait_ms=3000):
    """页面加载完（脚本跑过）后的 DOM 文本；只有 Chrome 系有这个功能，拿不到返回 None"""
    path, kind = find_browser()
    if not path or kind == "firefox":
        return None
    for no_sandbox in _sandbox_attempts(kind):
        profile = tempfile.mkdtemp(prefix="ccpulse-shot-")
        try:
            cmd = _chrome_command(path, kind, profile, width, height, 1, wait_ms, no_sandbox) + ["--dump-dom", url]
            text = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=90).stdout
        except subprocess.TimeoutExpired:
            text = b""
        finally:
            shutil.rmtree(profile, ignore_errors=True)
        if text.strip():
            return text.decode("utf-8", "replace")
    return None


def _xml(text):
    return (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;"))


def _display_width(line):
    return sum(2 if ord(ch) > 0x2E7F else 1 for ch in line)


def text_lines(raw, limit=200):
    lines = raw.replace("\r\n", "\n").replace("\t", "    ").split("\n")
    # 去掉 ANSI 颜色控制符
    import re
    lines = [re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", line) for line in lines]
    while lines and not lines[-1].strip():
        lines.pop()
    if len(lines) > limit:
        lines = lines[:limit // 2] + ["…（中间省略 %d 行）…" % (len(lines) - limit)] + lines[-(limit // 2):]
    return [line[:220] for line in lines]


def text_svg(lines, title):
    """不依赖任何东西的「终端截图」：深色背景、等宽字体。"""
    char_w, line_h, pad = 8.2, 19, 18
    cols = max([_display_width(l) for l in lines] + [_display_width(title or "") + 4, 30])
    width = int(min(1400, cols * char_w + pad * 2))
    top = 40 if title else pad
    height = int(top + len(lines) * line_h + pad)
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">' % (width, height, width, height),
             '<rect width="100%" height="100%" rx="10" fill="#1e1f22"/>']
    if title:
        parts.append('<circle cx="20" cy="18" r="5" fill="#ff5f57"/><circle cx="36" cy="18" r="5" fill="#febc2e"/><circle cx="52" cy="18" r="5" fill="#28c840"/>')
        parts.append('<text x="68" y="22" fill="#9da0a6" font-family="-apple-system,PingFang SC,sans-serif" font-size="12">%s</text>' % _xml(title))
    parts.append('<text font-family="SF Mono,Menlo,Consolas,DejaVu Sans Mono,Noto Sans Mono CJK SC,monospace" font-size="13" fill="#e6e6e6" xml:space="preserve">')
    for index, line in enumerate(lines):
        color = "#ff7b72" if any(k in line.lower() for k in ("error", "fail", "失败", "错误")) else (
            "#7ee787" if any(k in line.lower() for k in ("pass", "success", " ok", "通过", "成功")) else None)
        fill = ' fill="%s"' % color if color else ""
        parts.append('<tspan x="%d" y="%d"%s>%s</tspan>' % (pad, top + (index + 1) * line_h - 5, fill, _xml(line) or " "))
    parts.append("</text></svg>")
    return "\n".join(parts)


def _line_class(line):
    low = line.lower()
    if any(k in low for k in ("error", "fail", "失败", "错误")):
        return "e"
    if any(k in low for k in ("pass", "success", " ok", "通过", "成功")):
        return "o"
    return ""


def text_html(lines, title):
    body = "\n".join('<span class="%s">%s</span>' % (_line_class(line), _xml(line)) for line in lines)
    return """<!doctype html><meta charset="utf-8"><style>
body{margin:0;background:#1e1f22;font:13px/1.5 'SF Mono',Menlo,Consolas,'DejaVu Sans Mono','Noto Sans Mono CJK SC',monospace;color:#e6e6e6}
.bar{height:34px;display:flex;align-items:center;gap:7px;padding:0 14px;font:12px -apple-system,'PingFang SC',sans-serif;color:#9da0a6}
.bar i{width:10px;height:10px;border-radius:50%%}pre{margin:0;padding:6px 16px 16px;white-space:pre-wrap;word-break:break-all}
.e{color:#ff7b72}.o{color:#7ee787}
</style><div class="bar"><i style="background:#ff5f57"></i><i style="background:#febc2e"></i><i style="background:#28c840"></i>&nbsp;%s</div><pre>%s</pre>""" % (_xml(title or ""), body)


def command_shot(argv):
    caption, session, title = "", None, None
    width, height, text_source, target, desktop = None, None, None, None, False
    index = 0
    while index < len(argv):
        arg = argv[index]
        value = argv[index + 1] if index + 1 < len(argv) else None
        if arg in ("--caption", "-m") and value is not None:
            caption = value; index += 2; continue
        if arg == "--session" and value is not None:
            session = value; index += 2; continue
        if arg == "--title" and value is not None:
            title = value; index += 2; continue
        if arg == "--width" and value is not None:
            width = int(value); index += 2; continue
        if arg == "--height" and value is not None:
            height = int(value); index += 2; continue
        if arg == "--text" and value is not None:
            text_source = value; index += 2; continue
        if arg == "--desktop":
            desktop = True; index += 1; continue
        if arg in ("-h", "--help"):
            print(__doc__.split("子命令（给智能体用）:")[1].strip())
            return 0
        target = arg
        index += 1

    out_dir = tempfile.mkdtemp(prefix="ccpulse-shot-")
    try:
        if text_source is not None:
            raw = sys.stdin.read() if text_source == "-" else open(text_source, encoding="utf-8", errors="replace").read()
            lines = text_lines(raw)
            if not lines:
                print("没有可渲染的文本", file=sys.stderr)
                return 2
            title = title if title is not None else ("" if text_source == "-" else os.path.basename(text_source))
            out = os.path.join(out_dir, "output.png")
            try:
                html = os.path.join(out_dir, "text.html")
                with open(html, "w", encoding="utf-8") as handle:
                    handle.write(text_html(lines, title))
                cols = max(_display_width(l) for l in lines)
                w = int(min(1100, max(480, cols * 7.9 + 40)))
                h = int(min(4000, 50 + len(lines) * 19.5 + 24))
                browser_screenshot(file_url(html), out, w, h, scale=2, wait_ms=500)
            except Exception:
                out = os.path.join(out_dir, "output.svg")
                with open(out, "w", encoding="utf-8") as handle:
                    handle.write(text_svg(lines, title))
        else:
            if not target:
                print("用法：ccpulse-watch.py shot <网址|html文件> [--desktop] [--caption 说明]  或  shot --text <文件|->", file=sys.stderr)
                return 2
            url = target
            if "://" not in url:
                url = file_url(os.path.expanduser(url)) if os.path.exists(os.path.expanduser(url)) else "http://" + url
            w = width or (1440 if desktop else 390)
            h = height or (900 if desktop else 844)
            out = os.path.join(out_dir, "page.png")
            try:
                browser_screenshot(url, out, w, h, scale=1 if desktop else 2)
            except Exception as exc:
                print("截图失败：%s" % exc, file=sys.stderr)
                return 5
        args = [out] + (["--caption", caption] if caption else []) + (["--session", session] if session else [])
        return command_send_image(args)
    finally:
        shutil.rmtree(out_dir, ignore_errors=True)


# ---------------------------------------------------------------------------
# 网页测试报告（report）：读 Playwright 的 JSON 报告（或自己写的步骤清单），排成「总览 + 每个用例的步骤图文」
#   几张图，连同文字摘要发到手机；电脑上留一份完整的 HTML。
# 公用 Playwright 工作区（e2e-setup）：项目里没有 Playwright 时用，装在 ~/.ccpulse/e2e，不往用户的项目里加东西。
# ---------------------------------------------------------------------------

REPORTS_DIR = os.path.join(DATA_DIR, "reports")
REPORTS_KEEP = 20             # 电脑上留最近几份报告
REPORT_WIDTH = 390            # 按手机屏宽排（CSS 像素）、3 倍出图：手机上铺满屏宽看，字和平常一样大
REPORT_SCALE = 3
REPORT_MAX_IMAGES = 9         # 一次最多发几张：总览 + 8 张用例
REPORT_MAX_HEIGHT = 4800      # 一张用例图排到大约多高，后面的步骤就拆到下一张（乘 3 倍后不超过浏览器的截图上限）
REPORT_SHOT_WIDTH = 350       # 截图显示的宽（同 CSS：版心 390 减左右各 20）
REPORT_SHOT_MAX = 840         # 截图最多显示多高，更长的（整页截图）只显示顶部（同 CSS 的 max-height）
_REPORT_FAILED = ("failed", "timedOut", "interrupted")

_REPORT_TEXT = {
    "zh": {
        "kind": "网页测试报告", "all_passed": "全部通过", "not_passed": "%d 个用例未通过", "empty": "没有执行任何用例",
        "st_passed": "通过", "st_failed": "未通过", "st_flaky": "重试后通过", "st_skipped": "跳过", "st_timedOut": "超时",
        "st_interrupted": "中断", "cont": "（续）", "final_page": "结束时的页面", "failed_page": "出错时的页面",
        "more": "另有 %d 个用例", "sec": "%s 秒", "min": "%d 分 %d 秒", "tests_n": "共 %d 个用例", "passed_n": "%d 个通过",
        "failed_n": "%d 个未通过", "skipped_n": "%d 个跳过", "took": "用时 %s", "dot": " · ", "colon": "：",
        "expected": "期望 %s，实际 %s", "not_found": "页面上找不到 %s", "waiting": "超时，一直没等到 %s",
        "rest": "其余用例的截图在电脑上的完整报告里。", "mobile": "手机", "desktop": "桌面", "paren": "（%s）",
        "fail_word": "失败", "pass_word": "通过", "quotes": ("“", "”"),
    },
    "en": {
        "kind": "Web Test Report", "all_passed": "All passed", "not_passed": ("%d test failed", "%d tests failed"),
        "empty": "No tests were run", "st_passed": "Passed", "st_failed": "Failed", "st_flaky": "Passed on retry",
        "st_skipped": "Skipped", "st_timedOut": "Timed out", "st_interrupted": "Interrupted", "cont": " (continued)",
        "final_page": "Final page", "failed_page": "Page at failure", "more": ("%d more test", "%d more tests"),
        "sec": "%ss", "min": "%dm %ds", "tests_n": ("%d test", "%d tests"), "passed_n": "%d passed", "failed_n": "%d failed",
        "skipped_n": "%d skipped", "took": "%s", "dot": " · ", "colon": ": ", "expected": "Expected %s, got %s",
        "not_found": "Not found on the page: %s", "waiting": "Timed out waiting for %s",
        "rest": "Screenshots for the remaining tests are in the full report on the computer.",
        "mobile": "Mobile", "desktop": "Desktop", "paren": " (%s)", "fail_word": "FAIL", "pass_word": "PASS",
        "quotes": ('"', '"'),
    },
}

_REPORT_CSS = """
*{box-sizing:border-box;margin:0;padding:0}
html{background:#ebebe8}
body{padding:24px 0;color:#1d1d1f;font:16px/1.5 -apple-system,BlinkMacSystemFont,"PingFang SC","Hiragino Sans GB","Noto Sans CJK SC","Noto Sans SC","Microsoft YaHei","Segoe UI",Roboto,sans-serif;-webkit-font-smoothing:antialiased}
.card{width:390px;margin:0 auto 20px;padding:24px 20px 28px;background:#fff;border-radius:16px;box-shadow:0 0 0 1px rgba(0,0,0,.05),0 2px 8px rgba(0,0,0,.04)}
html.single{background:#fff}
.single body{padding:0}
.single .card{display:none;margin:0;border-radius:0;box-shadow:none}
.single .card.on{display:block}
.kind{font-size:13px;color:#8e8e93}
h1{margin-top:4px;font-size:24px;line-height:1.3;font-weight:650;letter-spacing:-.01em}
h1.sm{font-size:21px}
.verdict{display:inline-flex;align-items:center;gap:7px;margin-top:14px;padding:5px 13px 5px 11px;border-radius:999px;font-size:15px;font-weight:600}
.verdict i,.row i{flex:none;width:8px;height:8px;border-radius:50%;background:currentColor}
.s-passed{color:#1d7a3d}.s-failed,.s-timedOut,.s-interrupted{color:#b42318}.s-flaky{color:#946200}.s-skipped,.s-none{color:#8e8e93}
.verdict.s-passed{background:#edf7f0}.verdict.s-failed,.verdict.s-timedOut,.verdict.s-interrupted{background:#fdeeeb}
.verdict.s-flaky{background:#fbf4e3}.verdict.s-skipped{background:#f2f2f5}
.sum{margin-top:10px;font-size:14px;color:#6e6e73}
.list{margin-top:18px;border-top:1px solid #ededf0}
.row{display:flex;gap:11px;padding:13px 0;border-bottom:1px solid #f1f1f3}
.row i{margin-top:9px}
.row .name{flex:1;min-width:0;color:#1d1d1f}
.row .tag{color:#8e8e93}
.row .why{display:block;margin-top:2px;font-size:14px;line-height:1.45;color:#b42318}
.row.more{display:block;font-size:14px;color:#8e8e93}
.reason{margin-top:14px;padding:11px 13px;border-radius:10px;background:#fdf0ed;color:#8f1f16;font-size:14.5px;line-height:1.5}
.step{margin-top:22px}
.step.text{margin-top:14px}
.cap{display:flex;align-items:baseline;gap:9px;margin-bottom:9px;font-size:15.5px;font-weight:600;line-height:1.4}
.text .cap{margin-bottom:0}
.cap .n{flex:none;display:inline-flex;align-items:center;justify-content:center;width:22px;height:22px;border-radius:11px;background:#f0f0f3;color:#48484a;font-size:12px;font-weight:650;transform:translateY(-1px)}
.cap .n.s-failed,.cap .n.s-timedOut,.cap .n.s-interrupted{background:#fbe3de;color:#b42318}
.cap .n.sub{width:6px;height:6px;margin:0 8px;background:#c7c7cc}
.cap .t{flex:1;min-width:0}
.d1 .cap,.d2 .cap{padding-left:14px}
.step img{display:block;width:100%;max-height:840px;object-fit:cover;object-position:top;border:1px solid #e3e3e8;border-radius:12px}
.note{margin-top:7px;font-size:14px;color:#6e6e73}
"""

# 带 #card-N 打开时只显示这一张（逐张截图用）；页面加载完把每张的实际高度写到 body 上（--dump-dom 读回来）
_REPORT_JS = """
(function () {
  var m = /^#card-(\\d+)$/.exec(location.hash);
  if (m) {
    document.documentElement.className = 'single';
    var card = document.getElementById('card-' + m[1]);
    if (card) card.className += ' on';
  }
  window.addEventListener('load', function () {
    var cards = document.querySelectorAll('.card'), h = [];
    for (var i = 0; i < cards.length; i++) h.push(Math.ceil(cards[i].getBoundingClientRect().height));
    document.body.setAttribute('data-heights', h.join(','));
  });
})();
"""


def system_lang():
    """这台电脑的界面语言（zh / en）：报告内容看不出语言时用，也给测试页面定 locale"""
    for key in ("LC_ALL", "LC_MESSAGES", "LANG"):
        value = os.environ.get(key) or ""
        if value and value != "C" and not value.startswith(("C.", "POSIX")):
            return "zh" if value.lower().startswith("zh") else "en"
    if sys.platform == "darwin":
        try:
            out = subprocess.run(["defaults", "read", "-g", "AppleLanguages"], stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, timeout=3).stdout.decode("utf-8", "replace")
            match = re.search(r"[A-Za-z]{2}", out)
            if match:
                return "zh" if match.group(0).lower() == "zh" else "en"
        except (OSError, subprocess.SubprocessError):
            pass
    if os.name == "nt":
        try:
            import ctypes
            return "zh" if (ctypes.windll.kernel32.GetUserDefaultUILanguage() & 0x3FF) == 0x04 else "en"
        except Exception:
            pass
    return "en"


def image_size(path):
    """读文件头拿图片宽高（png / jpeg / gif / webp），读不出返回 None"""
    try:
        with open(path, "rb") as handle:
            head = handle.read(256 * 1024)
    except OSError:
        return None
    try:
        if head[:8] == b"\x89PNG\r\n\x1a\n":
            return struct.unpack(">II", head[16:24])
        if head[:6] in (b"GIF87a", b"GIF89a"):
            return struct.unpack("<HH", head[6:10])
        if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
            chunk = head[12:16]
            if chunk == b"VP8X":
                return 1 + int.from_bytes(head[24:27], "little"), 1 + int.from_bytes(head[27:30], "little")
            if chunk == b"VP8 ":
                width, height = struct.unpack("<HH", head[26:30])
                return width & 0x3FFF, height & 0x3FFF
            if chunk == b"VP8L":
                bits = int.from_bytes(head[21:25], "little")
                return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
            return None
        if head[:2] == b"\xff\xd8":
            index = 2
            while index + 9 < len(head):
                if head[index] != 0xFF:
                    index += 1
                    continue
                marker = head[index + 1]
                if marker in (0xD8, 0x01, 0xFF) or 0xD0 <= marker <= 0xD7:
                    index += 1 if marker == 0xFF else 2
                    continue
                if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                    height, width = struct.unpack(">HH", head[index + 5:index + 9])
                    return width, height
                index += 2 + struct.unpack(">H", head[index + 2:index + 4])[0]
    except struct.error:
        return None
    return None


class _ReportImages:
    """报告用到的截图都拷进报告文件夹（Playwright 下次运行会清掉 test-results）"""
    EXT = {"image/png": ".png", "image/jpeg": ".jpg", "image/jpg": ".jpg", "image/webp": ".webp", "image/gif": ".gif"}

    def __init__(self, folder):
        self.folder = folder
        self.count = 0

    def add(self, path=None, body=None, mime=None, base=None):
        mime = (mime or (mimetypes.guess_type(path)[0] if path else None) or "image/png").lower()
        ext = self.EXT.get(mime)
        if not ext:
            return None
        os.makedirs(self.folder, exist_ok=True)
        target = os.path.join(self.folder, "%02d%s" % (self.count + 1, ext))
        try:
            if path:
                source = os.path.expanduser(path)
                if not os.path.isabs(source) and base:
                    source = os.path.join(base, source)
                if os.path.getsize(source) > SEND_IMAGE_MAX:
                    return None
                shutil.copyfile(source, target)
            elif body:
                with open(target, "wb") as handle:
                    handle.write(base64.b64decode(body))
            else:
                return None
        except (OSError, ValueError, TypeError):
            return None
        self.count += 1
        return {"path": target, "size": image_size(target)}


def _report_status(value):
    text = str(value or "").strip().lower()
    for status, words in (("passed", ("passed", "pass", "ok", "success", "expected", "通过", "成功")),
                          ("failed", ("failed", "fail", "error", "unexpected", "失败", "未通过")),
                          ("skipped", ("skipped", "skip", "pending", "跳过")), ("flaky", ("flaky",)),
                          ("timedOut", ("timedout", "timeout", "超时")), ("interrupted", ("interrupted",))):
        if text in words:
            return status
    return None


def _report_error(errors):
    """报错去掉颜色码，只留前 16 行"""
    texts = []
    for err in errors:
        if isinstance(err, dict):
            err = err.get("message") or err.get("value") or ""
        text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", str(err or "")).strip()
        if text and text not in texts:
            texts.append(text)
    rows = "\n\n".join(texts).split("\n")
    if len(rows) > 16:
        rows = rows[:16]
        while rows and not rows[-1].strip():
            rows.pop()
        rows.append("…")
    return "\n".join(row[:300] for row in rows).strip()


def _report_reason(error, T):
    """一句话的失败原因：断言没过说「期望 X，实际 Y」，找不到元素、等超时说是哪个元素，其余取报错第一行"""
    lines = [line.strip() for line in (error or "").split("\n") if line.strip()]
    if not lines:
        return ""
    values = {}
    for line in lines[1:8]:
        match = re.match(r"^(Expected|Received|Locator)[^:]*:\s*(.+)$", line)
        if match and match.group(1) not in values:
            # Playwright 给的字符串值带英文引号，中文报告里换成中文引号
            values[match.group(1)] = re.sub(r'^"(.*)"$', lambda m: T["quotes"][0] + m.group(1) + T["quotes"][1], match.group(2).strip())
    waiting = next((m.group(1) for m in (re.search(r"waiting for (.+)$", line) for line in lines[1:8]) if m), None)
    if "element(s) not found" in values.get("Received", "") and values.get("Locator"):
        text = T["not_found"] % values["Locator"]
    elif "Expected" in values and "Received" in values:
        text = T["expected"] % (values["Expected"], values["Received"])
    elif waiting and "timeout" in lines[0].lower():
        text = T["waiting"] % waiting
    else:
        text = re.sub(r"^Error:\s*", "", lines[0])
    text = re.sub(r"\s+", " ", text)
    return text if len(text) <= 140 else text[:139] + "…"


def _report_step(title="", label=None, depth=0, duration=None, status=None, image=None, note=""):
    return {"title": title, "label": label, "depth": depth, "duration": duration, "status": status, "image": image, "note": note}


def _report_pw_test(spec, test, trail, base, images):
    results = [r for r in test.get("results") or [] if isinstance(r, dict)]
    result = results[-1] if results else {}
    state, outcome = test.get("status"), result.get("status")
    if state == "skipped" or outcome == "skipped":
        status = "skipped"
    elif state == "flaky":
        status = "flaky"
    elif state == "unexpected":
        status = outcome if outcome in ("timedOut", "interrupted") else "failed"
    else:
        status = "passed"
    steps = []

    def flatten(items, depth):
        for item in items or []:
            if isinstance(item, dict):
                steps.append(_report_step(str(item.get("title") or ""), depth=depth, duration=item.get("duration"),
                                          status="failed" if item.get("error") else "passed"))
                flatten(item.get("steps"), depth + 1)

    flatten(result.get("steps"), 0)
    # 截图按名字配到同名的步骤上（技能里的 step() 就是这么附的）；不同名的单独成一步
    auto, extra = [], []
    for att in result.get("attachments") or []:
        if not isinstance(att, dict) or not str(att.get("contentType") or "").startswith("image/"):
            continue
        image = images.add(path=att.get("path"), body=att.get("body"), mime=att.get("contentType"), base=base)
        if not image:
            continue
        name = str(att.get("name") or "").strip()
        same = next((s for s in steps if s["image"] is None and s["title"].strip() == name), None)
        if same:
            same["image"] = image
        elif re.match(r"^screenshot(-\d+)?$", name):
            auto.append(image)
        else:
            extra.append(_report_step(name, image=image))
    steps.extend(extra)
    # Playwright 自动截的图（screenshot: 'on' / 'only-on-failure'）：失败时配给出错的那一步；步骤里已经有图就不再重复
    for image in auto:
        if status in _REPORT_FAILED:
            target = next((s for s in reversed(steps) if s["status"] == "failed" and s["image"] is None), None)
            if target:
                target["image"] = image
            elif not any(s["image"] for s in steps if s["status"] == "failed"):
                steps.append(_report_step(label="failed_page", status="failed", image=image))
        elif not any(s["image"] for s in steps):
            steps.append(_report_step(label="final_page", image=image))
    errors = result.get("errors") or ([result["error"]] if result.get("error") else [])
    where = spec.get("file") or ""
    if where and spec.get("line"):
        where = "%s:%s" % (where, spec["line"])
    return {"title": " › ".join([t for t in trail if t] + [str(spec.get("title") or "")]), "project": str(test.get("projectName") or ""),
            "file": where, "status": status, "duration": result.get("duration"), "error": _report_error(errors), "steps": steps}


def _report_from_playwright(data, base, images):
    tests = []

    def walk(suite, trail):
        for spec in suite.get("specs") or []:
            if isinstance(spec, dict):
                for test in spec.get("tests") or []:
                    if isinstance(test, dict):
                        tests.append(_report_pw_test(spec, test, trail, base, images))
        for child in suite.get("suites") or []:
            if isinstance(child, dict):
                walk(child, trail + [str(child.get("title") or "")])

    # 最外层一级是测试文件，标题不进用例名
    for top in data.get("suites") or []:
        if isinstance(top, dict):
            walk(top, [])
    config = data.get("config") if isinstance(data.get("config"), dict) else {}
    stats = data.get("stats") if isinstance(data.get("stats"), dict) else {}
    duration = stats.get("duration")
    return {"tests": tests, "duration": duration if isinstance(duration, (int, float)) else None,
            "startedAt": parse_ts(stats.get("startTime")),
            "engine": "Playwright %s" % config["version"] if config.get("version") else "Playwright"}


def _report_from_manifest(data, base, images):
    """自己写的清单：{"title", "url", "tests": [{"title", "status", "duration", "error", "steps": [{"title", "screenshot", "status", "note"}]}]}；
    只有一个用例时也可以把 steps 直接写在最外层。截图路径相对清单文件"""
    raw = data.get("tests")
    if not isinstance(raw, list):
        raw = [{"title": data.get("name") or data.get("title"), "steps": data.get("steps"), "status": data.get("status"),
                "error": data.get("error"), "duration": data.get("duration")}]
    tests = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        steps = []
        for step in item.get("steps") or []:
            if isinstance(step, str):
                step = {"title": step}
            if not isinstance(step, dict):
                continue
            shot = step.get("screenshot") or step.get("image")
            image = images.add(path=shot, base=base) if isinstance(shot, str) and shot else None
            steps.append(_report_step(str(step.get("title") or step.get("name") or ""), duration=step.get("duration"),
                                      status=_report_status(step.get("status")) or ("failed" if step.get("error") else None),
                                      image=image, note=str(step.get("note") or step.get("error") or "")))
        error = _report_error([item.get("error")]) if item.get("error") else ""
        status = _report_status(item.get("status")) or ("failed" if error or any(s["status"] == "failed" for s in steps) else "passed")
        duration = item.get("duration") if isinstance(item.get("duration"), (int, float)) else None
        tests.append({"title": str(item.get("title") or item.get("name") or ""), "project": str(item.get("project") or ""),
                      "file": "", "status": status, "duration": duration, "error": error, "steps": steps})
    durations = [t["duration"] for t in tests if t["duration"] is not None]
    total = data.get("duration") if isinstance(data.get("duration"), (int, float)) else (sum(durations) if durations else None)
    return {"tests": tests, "duration": total, "startedAt": None, "engine": str(data.get("engine") or "")}


def _report_plural(T, key, n):
    value = T[key]
    if isinstance(value, tuple):
        value = value[0] if n == 1 else value[1]
    return value % n


def _report_duration(ms, T):
    if not isinstance(ms, (int, float)) or ms < 0:
        return ""
    seconds = ms / 1000.0
    if seconds < 60:
        return T["sec"] % (("%.1f" % max(seconds, 0.1)) if seconds < 10 else "%d" % round(seconds))
    return T["min"] % (int(seconds // 60), int(seconds % 60))


def _report_counts(tests):
    passed = sum(1 for t in tests if t["status"] in ("passed", "flaky"))
    failed = sum(1 for t in tests if t["status"] in _REPORT_FAILED)
    skipped = sum(1 for t in tests if t["status"] == "skipped")
    return len(tests), passed, failed, skipped


def _report_lang(rep, forced):
    if forced in _REPORT_TEXT:
        return forced
    sample = " ".join([rep["title"]] + [t["title"] for t in rep["tests"]] + [s["title"] for t in rep["tests"] for s in t["steps"]])
    return "zh" if re.search(u"[㐀-鿿]", sample) else system_lang()


def _report_project(name, T):
    return T.get(name, name) if name in ("mobile", "desktop") else name


def _report_name(test, rep, T):
    """文字里提到的用例名：跑了几种设备（project）时带上是哪一种"""
    several = _report_several(rep)
    return (test["title"] or "—") + (T["paren"] % _report_project(test["project"], T) if several and test["project"] else "")


def _report_lines(text, per_line):
    """估算文字排成几行（中文按两个字符宽）"""
    return sum(max(1, -(-_display_width(row) // per_line)) for row in (text or " ").split("\n"))


def _report_verdict(rep, T):
    n, passed, failed, skipped = _report_counts(rep["tests"])
    return _report_plural(T, "not_passed", failed) if failed else (T["all_passed"] if passed else T["empty"])


def _report_counts_text(rep, T):
    """一行计数：共 4 个用例 · 2 个通过 · 2 个未通过 · 用时 7.2 秒"""
    n, passed, failed, skipped = _report_counts(rep["tests"])
    parts = [_report_plural(T, "tests_n", n), _report_plural(T, "passed_n", passed)]
    if failed:
        parts.append(_report_plural(T, "failed_n", failed))
    if skipped:
        parts.append(_report_plural(T, "skipped_n", skipped))
    duration = _report_duration(rep.get("duration"), T)
    if duration:
        parts.append(T["took"] % duration)
    return T["dot"].join(parts)


def _report_several(rep):
    """跑了几种设备（Playwright 的 project）"""
    return len(set(t["project"] for t in rep["tests"])) > 1


def _report_cover(rep, T, ordered):
    """总览：结论、一行计数、用例列表（没通过的排前面，附一句原因）"""
    n, passed, failed, skipped = _report_counts(rep["tests"])
    status = "failed" if failed else ("passed" if passed else "skipped")
    started = rep.get("startedAt") or time.time() * 1000
    title = rep["title"] or T["kind"]
    html = ['<div class="kind">%s · %s</div>' % (_xml(T["kind"]), time.strftime("%m-%d %H:%M", time.localtime(started / 1000.0))),
            "<h1>%s</h1>" % _xml(title),
            '<div class="verdict s-%s"><i></i>%s</div>' % (status, _xml(_report_verdict(rep, T))),
            '<div class="sum">%s</div>' % _xml(_report_counts_text(rep, T))]
    height = 52 + 20 + 31 * _report_lines(title, 28) + 50 + 31 + 18
    several = _report_several(rep)
    rows = []
    for test in ordered[:12]:
        tags = [_report_project(test["project"], T)] if several and test["project"] else []
        if test["status"] not in ("passed", "failed"):
            tags.append(T["st_" + test["status"]])
        reason = _report_reason(test["error"], T) if test["status"] in _REPORT_FAILED else ""
        rows.append('<div class="row s-%s"><i></i><div class="name">%s<span class="tag">%s</span>%s</div></div>' % (
            test["status"], _xml(test["title"] or "—"), _xml(T["paren"] % T["dot"].join(tags)) if tags else "",
            '<span class="why">%s</span>' % _xml(reason) if reason else ""))
        height += 50 + 24 * (_report_lines(test["title"], 40) - 1) + (21 * _report_lines(reason, 42) if reason else 0)
    if len(ordered) > 12:
        rows.append('<div class="row more">%s</div>' % _xml(_report_plural(T, "more", len(ordered) - 12)))
        height += 48
    html.append('<div class="list">%s</div>' % "".join(rows))
    return {"html": "".join(html), "height": int(height)}


def _report_step_html(step, number, T):
    title = step["title"] or T.get(step.get("label") or "", "")
    badge = '<span class="n s-%s">%d</span>' % (step["status"] or "none", number) if number else '<span class="n sub"></span>'
    cap = '<div class="cap">%s<span class="t">%s</span></div>' % (badge, _xml(title))
    note = '<div class="note">%s</div>' % _xml(step["note"]) if step.get("note") else ""
    depth = min(step["depth"], 2)
    if step["image"]:
        return '<figure class="step d%d">%s<img src="img/%s">%s</figure>' % (depth, cap, _xml(os.path.basename(step["image"]["path"])), note)
    return '<div class="step text d%d">%s%s</div>' % (depth, cap, note)


def _report_step_height(step):
    height = 22 * _report_lines(step["title"], 38) + (28 if step.get("note") else 0)
    if not step["image"]:
        return 14 + height
    width, tall = step["image"].get("size") or (390, 844)
    return 22 + 9 + height + min(REPORT_SHOT_WIDTH * tall / float(max(width, 1)), REPORT_SHOT_MAX) + 2


def _report_test_cards(test, number, total, T, several):
    """一个用例一张：标题、结论、一句原因，下面一步一张截图往下排；太长就拆成几张"""
    steps = test["steps"]
    numbers, count = [], 0
    for step in steps:
        if step["depth"] == 0:
            count += 1
        numbers.append(count if step["depth"] == 0 else 0)
    head = ["%d / %d" % (number, total)] + ([_report_project(test["project"], T)] if several and test["project"] else [])
    top = 52 + 20 + 28 * _report_lines(test["title"], 32)
    reason = _report_reason(test["error"], T) if test["status"] in _REPORT_FAILED else ""
    first = 50 + ((36 + 22 * _report_lines(reason, 40)) if reason else 0)
    chunks, current, used = [], [], 0
    for index, step in enumerate(steps):
        size = _report_step_height(step)
        if current and top + used + size + (first if not chunks else 0) > REPORT_MAX_HEIGHT:
            chunks.append((current, used))
            current, used = [], 0
        current.append(index)
        used += size
    chunks.append((current, used))
    cards = []
    for part, (chunk, used) in enumerate(chunks):
        html = ['<div class="kind">%s</div>' % _xml(T["dot"].join(head)),
                '<h1 class="sm">%s%s</h1>' % (_xml(test["title"] or "—"), _xml(T["cont"]) if part else "")]
        height = top + used
        if part == 0:
            duration = _report_duration(test["duration"], T)
            html.append('<div class="verdict s-%s"><i></i>%s</div>' % (
                test["status"], _xml(T["st_" + test["status"]] + (T["dot"] + duration if duration else ""))))
            if reason:
                html.append('<div class="reason">%s</div>' % _xml(reason))
            height += first
        html.extend(_report_step_html(steps[i], numbers[i], T) for i in chunk)
        cards.append({"html": "".join(html), "height": int(height)})
    return cards


def _report_page(cards, title, lang):
    sections = "".join('<section class="card" id="card-%d">%s</section>' % (index, card["html"]) for index, card in enumerate(cards))
    return ('<!doctype html><html lang="%s"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
            '<title>%s</title><style>%s</style></head><body>%s<script>%s</script></body></html>'
            % ("zh-CN" if lang == "zh" else "en", _xml(title), _REPORT_CSS, sections, _REPORT_JS))


def _report_render(html_path, cards, out_dir):
    """逐张截成图：先整页量出每张卡片的实际高度（--dump-dom 跑完页面脚本），量不到就用估算的"""
    heights = [card["height"] for card in cards]
    dom = browser_dump_dom(file_url(html_path), REPORT_WIDTH + 40, 1200)
    match = re.search(r'data-heights="([0-9,]+)"', dom or "")
    if match:
        measured = [int(x) for x in match.group(1).split(",") if x.isdigit()]
        if len(measured) == len(heights) and all(measured):
            heights = measured
    outs = [None] * len(cards)

    def shoot(index):
        out = os.path.join(out_dir, "%02d.png" % (index + 1))
        try:
            # 3 倍图最高 16384 像素（浏览器上限），再长的截掉底部
            outs[index] = browser_screenshot(file_url(html_path) + "#card-%d" % index, out, REPORT_WIDTH,
                                             min(max(heights[index], 200), 16000 // REPORT_SCALE), scale=REPORT_SCALE, wait_ms=2000)
        except Exception:
            pass

    # 三个三个并行截（每张都起一个无头浏览器）
    for start in range(0, len(cards), 3):
        threads = [threading.Thread(target=shoot, args=(i,)) for i in range(start, min(start + 3, len(cards)))]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
    # 没截出来的（机器忙、浏览器偶尔起不来）一张一张再截一次：封面没出来，整份报告就只能退回文字总览
    for index in [i for i, out in enumerate(outs) if not out]:
        shoot(index)
    return outs


def _report_fallback(rep, T, ordered, out_dir):
    """没有浏览器（或截图失败）：文字总览出成 SVG，再附上原始的步骤截图"""
    lines = [_report_verdict(rep, T), _report_counts_text(rep, T), ""]
    for test in ordered:
        failed = test["status"] in _REPORT_FAILED
        word = T["fail_word"] if failed else (T["st_skipped"] if test["status"] == "skipped" else T["pass_word"])
        lines.append("%s  %s" % (word, _report_name(test, rep, T)))
        if failed and test["error"]:
            lines.append("      " + _report_reason(test["error"], T))
    cover = os.path.join(out_dir, "summary.svg")
    with open(cover, "w", encoding="utf-8") as handle:
        handle.write(text_svg(text_lines("\n".join(lines)), rep["title"] or T["kind"]))
    shots = [s["image"]["path"] for t in ordered for s in t["steps"] if s["image"]]
    # 客户端都显示不了 SVG：文字总览转成 PNG；转不了又有步骤截图时就不带它（结论、计数在发图的文字里都有）
    png = svg_to_png(cover, os.path.join(out_dir, "summary.png"))
    if png:
        return [png] + shots[:REPORT_MAX_IMAGES - 1]
    return shots[:REPORT_MAX_IMAGES] or [cover]


def _report_caption(rep, T, ordered, missing, extra):
    """跟图一起发的文字（手机上按 Markdown 显示）：结论、计数、没通过的用例各一句原因"""
    lines = ["**%s%s%s**" % (rep["title"] or T["kind"], T["colon"], _report_verdict(rep, T)), _report_counts_text(rep, T)]
    failures = [t for t in ordered if t["status"] in _REPORT_FAILED]
    for test in failures[:3]:
        reason = _report_reason(test["error"], T)
        lines.append("- %s%s" % (_report_name(test, rep, T), T["colon"] + reason if reason else ""))
    if len(failures) > 3:
        lines.append("- " + _report_plural(T, "more", len(failures) - 3))
    if missing:
        lines += ["", T["rest"]]
    if extra:
        lines += ["", extra]
    return "\n".join(lines)


def _report_prune():
    try:
        names = sorted(name for name in os.listdir(REPORTS_DIR) if os.path.isdir(os.path.join(REPORTS_DIR, name)))
    except OSError:
        return
    for name in names[:-REPORTS_KEEP]:
        shutil.rmtree(os.path.join(REPORTS_DIR, name), ignore_errors=True)


def command_report(argv):
    title, url, lang, session, caption, source, send = None, None, None, None, "", None, True
    index = 0
    while index < len(argv):
        arg = argv[index]
        value = argv[index + 1] if index + 1 < len(argv) else None
        if arg == "--title" and value is not None:
            title = value; index += 2; continue
        if arg == "--url" and value is not None:
            url = value; index += 2; continue
        if arg in ("--caption", "-m") and value is not None:
            caption = value; index += 2; continue
        if arg == "--session" and value is not None:
            session = value; index += 2; continue
        if arg == "--lang" and value is not None:
            lang = value; index += 2; continue
        if arg == "--no-send":
            send = False; index += 1; continue
        if arg in ("-h", "--help"):
            print(__doc__.split("子命令（给智能体用）:")[1].strip())
            return 0
        source = arg
        index += 1
    source = os.path.abspath(os.path.expanduser(source or "."))
    if os.path.isdir(source):
        source = os.path.join(source, "results.json")
    try:
        with open(source, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError) as exc:
        print("读不了测试结果 %s：%s" % (source, exc), file=sys.stderr)
        return 2
    if not isinstance(data, dict):
        data = {}
    folder = os.path.join(REPORTS_DIR, time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:4])
    images = _ReportImages(os.path.join(folder, "img"))
    base = os.path.dirname(source)
    if isinstance(data.get("suites"), list):
        rep = _report_from_playwright(data, base, images)
    elif isinstance(data.get("tests"), list) or isinstance(data.get("steps"), list):
        rep = _report_from_manifest(data, base, images)
    else:
        print("认不出 %s 的格式：要 Playwright 的 JSON 报告（--reporter=json），或步骤清单（见 --help）" % source, file=sys.stderr)
        return 2
    if not rep["tests"]:
        shutil.rmtree(folder, ignore_errors=True)
        print("测试结果里没有用例（测试文件没匹配上，或者还没跑完？）：%s" % source, file=sys.stderr)
        return 2
    rep["title"] = title or str(data.get("title") or "") or (rep["tests"][0]["title"] if len(rep["tests"]) == 1 else "")
    rep["url"] = url or str(data.get("url") or "")
    lang = _report_lang(rep, lang)
    T = _REPORT_TEXT[lang]
    # 未通过的排前面，其余保持原来的顺序
    ordered = [t for t in rep["tests"] if t["status"] in _REPORT_FAILED] + [t for t in rep["tests"] if t["status"] not in _REPORT_FAILED]
    several = _report_several(rep)
    cards, owners = [_report_cover(rep, T, ordered)], [None]
    for number, test in enumerate(ordered, 1):
        if test["steps"] or test["error"]:
            for card in _report_test_cards(test, number, len(ordered), T, several):
                cards.append(card)
                owners.append(id(test))
    os.makedirs(folder, exist_ok=True)
    html_path = os.path.join(folder, "report.html")
    with open(html_path, "w", encoding="utf-8") as handle:
        handle.write(_report_page(cards, rep["title"] or T["kind"], lang))
    # 发到手机的：总览 + 前几张用例图；截不出来就退回文字总览 + 原始截图
    rendered = _report_render(html_path, cards[:REPORT_MAX_IMAGES], folder) if find_browser()[0] else []
    phone = [path for path in rendered if path] if rendered and rendered[0] else []
    sent = set(owners[index] for index, path in enumerate(rendered) if path) if phone else set()
    if not phone:
        phone = _report_fallback(rep, T, ordered, folder)
        sent = set(id(t) for t in ordered)
    missing = any(id(t) not in sent and any(s["image"] for s in t["steps"]) for t in ordered)
    text = _report_caption(rep, T, ordered, missing, caption)
    _report_prune()
    if not send:
        print("报告已生成（没有发送）：%s" % html_path)
        for path in phone:
            print("  " + path)
        print("\n文字摘要：\n" + text)
        return 0
    args = phone + ["--caption", text] + (["--session", session] if session else [])
    code = command_send_image(args)
    print("电脑上的完整报告：%s" % html_path)
    return code


# 公用 Playwright 工作区 ------------------------------------------------------

E2E_DIR = os.path.join(DATA_DIR, "e2e")
E2E_MARK = "kiteline-e2e v1"
NPM_MIRROR = "https://registry.npmmirror.com"
PLAYWRIGHT_MIRROR = "https://registry.npmmirror.com/-/binary/playwright"

# 每个项目一个文件夹，测试文件放里面；浏览器用 e2e-setup 选好的（写在上一级的 kiteline.json）
_E2E_CONFIG = """// Kiteline 网页测试：这个文件夹里的 *.spec.ts / *.spec.js 都会跑（%(mark)s，由 ccpulse-watch.py e2e-setup 生成，可以改）
const fs = require('fs');
const path = require('path');
const { defineConfig, devices } = require('@playwright/test');

let setup = {};
try { setup = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'kiteline.json'), 'utf8')); } catch (e) {}

module.exports = defineConfig({
  testDir: '.',
  outputDir: './test-results',
  timeout: 30000,
  expect: { timeout: 5000 },
  workers: 1,
  reporter: [['list'], ['json', { outputFile: 'results.json' }]],
  use: {
    channel: process.env.KITELINE_BROWSER_CHANNEL || setup.channel || undefined,
    locale: setup.locale || 'en-US',
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
  },
  projects: [
    { name: 'mobile', use: { viewport: { width: 390, height: 844 }, deviceScaleFactor: 3, isMobile: true, hasTouch: true, userAgent: devices['iPhone 13'].userAgent } },
    { name: 'desktop', use: { viewport: { width: 1440, height: 900 } } },
  ],
});
"""

# 起一次浏览器再关掉：确认真的能用（Linux 上缺系统库会在这里报出来）
_E2E_PROBE = "require('@playwright/test').chromium.launch({ channel: process.argv[1] || undefined })" \
             ".then(b => b.close()).then(() => console.log('LAUNCH_OK'), e => { console.log(String(e && e.message || e)); process.exit(1); });"


def _e2e_run(cmd, cwd, timeout, env=None):
    """跑一条命令，返回 (成功, 输出)"""
    try:
        proc = subprocess.run(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        return proc.returncode == 0, proc.stdout.decode("utf-8", "replace")
    except subprocess.TimeoutExpired as exc:
        return False, (exc.output or b"").decode("utf-8", "replace") + "\n（%d 秒内没有完成）" % timeout
    except OSError as exc:
        return False, str(exc)


def _reachable(url, timeout=6):
    import urllib.request
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            response.read(1)
        return True
    except Exception:
        return False


def _e2e_registry(npm):
    """npm 源：用户配的源连得上就用它，连不上（国内常见）换国内镜像。返回 (源, 是否换了镜像)"""
    ok, out = _e2e_run([npm, "config", "get", "registry"], None, 30)
    registry = (out.strip().splitlines() or [""])[-1].strip() if ok else ""
    if not registry.startswith("http"):
        registry = "https://registry.npmjs.org/"
    if registry.rstrip("/") == NPM_MIRROR or _reachable(registry.rstrip("/") + "/@playwright%2ftest/latest"):
        return registry, registry.rstrip("/") == NPM_MIRROR
    return NPM_MIRROR, True


def _e2e_system_browser():
    """电脑上装好的 Chrome / Edge（Playwright 的 channel），有就不用另外下载浏览器"""
    local = os.environ.get("LOCALAPPDATA") or ""
    programs = [os.environ.get(k) or "" for k in ("PROGRAMFILES", "PROGRAMFILES(X86)")]
    candidates = (
        ("chrome", "Google Chrome", ["/Applications/Google Chrome.app", "/opt/google/chrome/chrome"]
         + [os.path.join(p, "Google", "Chrome", "Application", "chrome.exe") for p in programs + [local] if p]),
        ("msedge", "Microsoft Edge", ["/Applications/Microsoft Edge.app", "/opt/microsoft/msedge/msedge"]
         + [os.path.join(p, "Microsoft", "Edge", "Application", "msedge.exe") for p in programs if p]),
    )
    for channel, label, paths in candidates:
        if any(os.path.exists(path) for path in paths):
            return channel, label
    return None, None


def command_e2e_setup(argv):
    name, update = None, False
    for arg in argv:
        if arg in ("-h", "--help"):
            print(__doc__.split("子命令（给智能体用）:")[1].strip())
            return 0
        if arg == "--update":
            update = True
        elif not name:
            name = arg
    name = re.sub(r"[^\w.-]+", "-", name or os.path.basename(os.getcwd()) or "default").strip("-.") or "default"
    if name in ("node_modules", "test-results"):
        name += "-tests"
    node, npm = shutil.which("node"), shutil.which("npm")
    if not node or not npm:
        print("这台电脑上没有 Node.js（要 18 以上，带 npm），装不了 Playwright。可以请用户装好 Node.js 后再试；"
              "或者改用 Python 版 Playwright 自己截图，再用 report 的步骤清单格式发报告。", file=sys.stderr)
        return 2
    ok, out = _e2e_run([node, "--version"], None, 20)
    major = re.match(r"v?(\d+)", out.strip()) if ok else None
    if not major or int(major.group(1)) < 18:
        print("Node.js 版本太旧（%s），Playwright 要 18 以上。" % out.strip(), file=sys.stderr)
        return 2
    os.makedirs(E2E_DIR, exist_ok=True)
    package = os.path.join(E2E_DIR, "package.json")
    if not os.path.exists(package):
        with open(package, "w", encoding="utf-8") as handle:
            json.dump({"name": "kiteline-e2e", "private": True, "description": "Kiteline 网页测试工作区（%s）" % E2E_MARK},
                      handle, ensure_ascii=False, indent=2)
    cli = os.path.join(E2E_DIR, "node_modules", "@playwright", "test", "cli.js")
    mirror = False
    if update or not os.path.exists(cli):
        registry, mirror = _e2e_registry(npm)
        print("正在安装 Playwright（npm 源 %s）…" % registry, flush=True)
        install = [npm, "install", "--no-audit", "--no-fund", "--loglevel=error", "@playwright/test@latest"]
        ok, out = _e2e_run(install + ["--registry", registry], E2E_DIR, 600)
        if not ok and registry.rstrip("/") != NPM_MIRROR:
            print("没装上，换国内镜像重试…", flush=True)
            mirror = True
            ok, out = _e2e_run(install + ["--registry", NPM_MIRROR], E2E_DIR, 600)
        if not ok or not os.path.exists(cli):
            print("安装 Playwright 失败：\n%s" % "\n".join(out.strip().splitlines()[-15:]), file=sys.stderr)
            return 3
    try:
        with open(os.path.join(E2E_DIR, "node_modules", "@playwright", "test", "package.json"), encoding="utf-8") as handle:
            version = json.load(handle).get("version") or "?"
    except (OSError, ValueError):
        version = "?"
    channel, label = _e2e_system_browser()
    if not (channel and _e2e_run([node, "-e", _E2E_PROBE, channel], E2E_DIR, 120)[0]):
        channel = None
        # 只装无头版 Chromium（约 100 MB），装过的直接跳过；连不上默认下载地址时换国内镜像
        print("正在准备浏览器（Playwright 自带的 Chromium，第一次要下载约 100 MB）…", flush=True)
        env = dict(os.environ)
        if mirror and not env.get("PLAYWRIGHT_DOWNLOAD_HOST"):
            env["PLAYWRIGHT_DOWNLOAD_HOST"] = PLAYWRIGHT_MIRROR
        browser = [node, cli, "install", "--only-shell", "chromium"]
        ok, out = _e2e_run(browser, E2E_DIR, 900, env)
        if not ok and not env.get("PLAYWRIGHT_DOWNLOAD_HOST"):
            print("没下载下来，换国内镜像重试…", flush=True)
            env["PLAYWRIGHT_DOWNLOAD_HOST"] = PLAYWRIGHT_MIRROR
            ok, out = _e2e_run(browser, E2E_DIR, 900, env)
        if not ok:
            print("下载浏览器失败：\n%s" % "\n".join(out.strip().splitlines()[-15:]), file=sys.stderr)
            return 4
        label = "Playwright 自带的 Chromium"
        ok, out = _e2e_run([node, "-e", _E2E_PROBE, ""], E2E_DIR, 120)
        if not ok:
            hint = "（Linux 上缺系统库：请用户运行 sudo npx playwright install-deps chromium）" if "dependencies" in out.lower() else ""
            print("浏览器起不来%s：\n%s" % (hint, "\n".join(out.strip().splitlines()[-12:])), file=sys.stderr)
            return 5
    with open(os.path.join(E2E_DIR, "kiteline.json"), "w", encoding="utf-8") as handle:
        json.dump({"channel": channel, "browser": label, "playwright": version,
                   "locale": "zh-CN" if system_lang() == "zh" else "en-US"}, handle, ensure_ascii=False, indent=2)
    folder = os.path.join(E2E_DIR, name)
    os.makedirs(folder, exist_ok=True)
    config_path = os.path.join(folder, "playwright.config.js")
    if not os.path.exists(config_path):
        with open(config_path, "w", encoding="utf-8") as handle:
            handle.write(_E2E_CONFIG % {"mark": E2E_MARK})
    shown = folder.replace("\\", "/")
    print("Playwright 网页测试已就绪（Playwright %s，浏览器：%s）" % (version, label))
    print("测试文件夹：%s" % shown)
    print("  - 测试写成这个文件夹里的 *.spec.ts（不用改用户的项目；里面的 playwright.config.js 已配好）")
    print("  - 运行：cd \"%s\" && npx playwright test --project=mobile" % shown)
    print("    手机尺寸 390×844；桌面网站用 --project=desktop（1440×900），两种都要就去掉 --project")
    print("  - 结果写在同一文件夹的 results.json，跑完用 report \"%s\" 生成图文报告发到手机" % shown)
    return 0


# ---------------------------------------------------------------------------
# 给编程 agent 装技能（截图、网页测试报告、待办与关键信息）
#   技能是一份 JSON 数据（SKILLS_BUILTIN）：每个技能的正文模板，以及各家 agent 从哪个目录读技能（targets）。
#   插件目录里有电脑端下发、校验过签名的新版（plugins/skills/skills.json，版本更高）就用它：改技能正文、加一家 agent
#   只要发一份 JSON，不用发版（技能包是 kind: "skills" 的插件包，bash relay/plugins.sh skills <版本> 从这里导出，见 guide/plugin-development.md）。watcher 只管照着装：写进各家的技能目录、带版本标记，关掉的按标记删（只删我们装的）。
#   哪些技能开着由电脑端经环境变量 CCPULSE_SKILLS 带来（逗号分隔的 id，可以为空）；没带这个变量就不动（测试、老电脑端）。
# ---------------------------------------------------------------------------

SKILLS_FILE = "skills.json"
SKILLS_RESYNC_SECONDS = 300   # 隔一会儿再对一遍：新装了一家 agent、技能被人删了，都能补上

_SKILL_SCREENSHOTS = """---
name: tars-screenshots
description: 每次给用户回复进展或结论时都要用。用户常在手机上的 Kiteline 里看这个会话，希望每条消息尽量附上相关截图（界面效果、网页、测试和命令结果、图表）。用 shot / send-image 截图并发到他手机上；要用图表、表格讲清楚的结论，写成网页用 send-page 发。回复别的会话发来的消息时不用：只回给发信的会话。
---

<!-- tars-skill v6 -->

# 每次回复都附上截图

用户经常不在电脑前，用手机上的 Kiteline 看你的回复。**每次给出进展或结论之前，先想想有什么能截图说明的，截了发给用户**，再写文字回复。

## 截什么

- 改了界面、网页 → 截改完的页面（开发服务器地址）
- 跑了测试、构建、部署、命令 → 把关键输出截成图
- 查了网页、文档、报错页面 → 截相关页面
- 生成了图片、图表 → 直接发
- 纯讨论、没有可视内容 → 不用硬截

## 怎么截、怎么发（会自动发到当前会话）

```bash
{{cmd}} shot http://localhost:5173 --caption "改完的首页"             # 网页，默认手机尺寸
{{cmd}} shot http://localhost:5173 --desktop --caption "桌面版"        # 桌面尺寸
{{cmd}} shot --text test.log --caption "测试结果：全部通过"             # 文本输出渲染成图
npm test 2>&1 | tail -40 | {{cmd}} shot --text - --title "npm test" --caption "测试结果"
{{cmd}} send-image a.png b.png --caption "说明"                          # 已有的图片
```

{{screen}}

## 用网页回复（可视化）

结论要靠图表、对比表、流程图、架构图才讲得清时（数据分析、性能对比、方案比较、调用关系），写一个网页发过去，比一大段文字好懂。用户在手机上轻点就能在 Kiteline 里打开，可以缩放、点开交互；在电脑上用浏览器打开。

```bash
{{cmd}} send-page report.html --title "接口耗时对比" --caption "一句话结论"
```

- 写成一个 .html 文件：样式写在页面里，深色、浅色都看得清，先按手机竖屏宽度排版（`<meta name="viewport" content="width=device-width, initial-scale=1">`）。
- 图表可以用 CDN 上的库（如 cdn.jsdelivr.net 的 Chart.js、ECharts、Mermaid）；同目录引用的图片、CSS、JS 会自动打包进去。
- --caption 写一句结论，推送和对话里会直接显示；文字回复里照常写要点，网页是补充。
- 简单的结果用截图（shot）就够，别为了发网页而发网页。

## 注意

- 截图失败（比如机器上没有浏览器）就算了，照常回复，不要为截图反复折腾。
- 不要截含密码、密钥、个人隐私的画面。
- 发完不用在回复里贴图片路径。你自己读过的图片，手机上本来就能看到。

## 别的会话发来的消息

别的会话发来的消息（`<cross-session-message>`，或 Kiteline 会话群里别的会话的发言）是会话之间的往来，不用再告诉用户：
- 能不回就不回：对方只是通知、说收到、道谢的，不回；要回只回给发信的会话：SendMessage 发回来信的 from；群里用 group say。
- 平时少主动给别的会话发消息（每条都会让对方带着整段上下文跑一轮，费 token）：只在遇到问题要它帮忙、要它配合或交接结果时才发，不播报进度。
- 不给用户截图、发图，也不另写给用户的汇报；回完用一句话说明回了什么就结束。
- 用户事先交代过由你汇总汇报的，照他的安排。
"""

_SKILL_PLAYWRIGHT = """---
name: tars-playwright-report
description: 网页功能做完或修完、准备汇报之前，或用户要求测试、验证、验收、回归、跑端到端（E2E）测试时使用：用 Playwright 在真实浏览器里把用户操作走一遍、每一步截图，生成图文测试报告发到用户手机上的 Kiteline，再根据结果汇报或继续修。
---

<!-- tars-playwright v2 -->

# 用 Playwright 实测网页，图文报告发到手机

用户常在手机上的 Kiteline 里看你的进展。网页上的功能做完或修好以后，不要只说「应该好了」：在真实浏览器里把用户会做的操作走一遍，每一步截图，生成图文测试报告发给用户，再写结论。

## 什么时候用

- 做完新功能、修完 bug、改了交互，汇报之前先自己验证
- 用户说「测一下」「验证」「验收」「回归」「跑 E2E」
- 只改了样式、不涉及操作：用 tars-screenshots 技能的 shot 截一张就够
- 不是网页（命令行工具、纯后端）：不用这个技能

## 1. 准备

1. 确认被测页面打得开。开发服务器没在跑，就按项目的方式在后台启动，测完关掉你启动的进程。
2. 项目里已经有 Playwright（有 playwright.config.*，或依赖里有 @playwright/test）：用项目自己的，测试照它的目录和写法放。
3. 没有：不要往用户的项目里装依赖、加文件，运行

   ```bash
   {{cmd}} e2e-setup <项目名>
   ```

   它在 ~/.ccpulse/e2e 准备一份公用的 Playwright（自动选可用的 npm 源和浏览器，优先用电脑上已装的 Chrome / Edge），给这个项目建一个测试文件夹，并打印测试放哪、怎么跑。第一次可能要下载约 100 MB，命令超时设到 10 分钟。

## 2. 写测试

- 照用户的真实操作写：打开页面 → 点击、输入 → 断言看到的结果。选择器优先 getByRole、getByLabel、getByText。
- 每一步用下面的 step 包起来，步骤名用用户的语言写清楚这一步做了什么：报告按步骤名配截图。
- 测主流程，加上这次改动相关的关键分支（错误提示、空状态）。一个用例 3～6 步，用例数量够说明问题就行：报告是给用户在手机上看的，越简单越好。
- 不用真实的账号和密码（用测试账号，或者问用户）；不要对线上环境做提交订单、删除、付款这类会改数据的操作。

```ts
import { test, expect, type Page } from '@playwright/test';

// 做完一步截一张图，图名就是步骤名（出错时也截，报告里能看到出错时的页面）
async function step(page: Page, title: string, body: () => Promise<void>) {
  await test.step(title, async () => {
    try {
      await body();
    } finally {
      const shot = await page.screenshot().catch(() => null);
      if (shot) await test.info().attach(title, { body: shot, contentType: 'image/png' });
    }
  });
}

test('登录后进入控制台', async ({ page }) => {
  await step(page, '打开登录页', async () => {
    await page.goto('http://localhost:5173/login');
    await expect(page.getByRole('heading', { name: '登录' })).toBeVisible();
  });
  await step(page, '输入账号密码并提交', async () => {
    await page.getByLabel('邮箱').fill('demo@example.com');
    await page.getByLabel('密码').fill('demo1234');
    await page.getByRole('button', { name: '登录' }).click();
  });
  await step(page, '看到控制台首页', async () => {
    await expect(page).toHaveURL(/dashboard/);
  });
});
```

## 3. 运行

- 公用工作区：在 e2e-setup 打印的文件夹里运行 `npx playwright test --project=mobile`（手机尺寸 390×844）。桌面网站用 `--project=desktop`（1440×900），两种都要就去掉 `--project`。结果写在同一文件夹的 results.json。
- 项目自己的 Playwright：

  ```bash
  PLAYWRIGHT_JSON_OUTPUT_NAME="$HOME/.ccpulse/e2e/<项目名>-results.json" npx playwright test <测试文件> --reporter=list,json
  ```

- 没通过时，先分清是测试写错了还是功能真有问题：功能问题就修代码再跑，不要为了通过去改断言、删步骤。报错、截图和 trace 在 test-results 文件夹里。

## 4. 发报告

```bash
{{cmd}} report <results.json 或它所在的文件夹> --title "登录流程"
```

- 自动排成适合手机看的图：一张总览（结论、通过几个、没通过的原因），每个用例一张按步骤排的截图，连同几行文字摘要发到当前会话；还会打印电脑上完整报告的位置。
- 改了再测时只发最后一次的报告，调试过程中的不用发。
- 不是用 @playwright/test 跑的（比如 Python 版 Playwright），把每步截图存成图片，写一个步骤清单交给 report：

  ```json
  {"title": "登录流程", "tests": [
    {"title": "登录后进入控制台", "status": "passed", "duration": 3200, "steps": [
      {"title": "打开登录页", "screenshot": "shots/1.png"},
      {"title": "看到控制台首页", "screenshot": "shots/2.png"}]}]}
  ```

  status 写 passed / failed / skipped，没通过的加 "error": "原因"；截图路径相对清单文件。

## 5. 回复用户

- 用一两句话说结论：测了哪些流程、结果如何、发现并修好了什么；还没通过的，说明原因和下一步。
- 报告已经发到手机，回复里不用贴图片路径，也不用把报告内容再抄一遍。

## 出问题时

- e2e-setup 失败（没有 Node.js、下载失败）：说明原因，改用 tars-screenshots 技能的 shot 截图汇报，不要反复折腾。
- Linux 上浏览器起不来、提示缺系统库：请用户运行 `sudo npx playwright install-deps chromium`，不要自己用 sudo；截图里中文显示成方框是缺中文字体（如 fonts-noto-cjk），同样请用户安装。
- report 失败：把报错告诉用户，照常用文字汇报。
"""

_SKILL_TODOS = """---
name: tars-todos
description: 待办分两种：你自己以后要接着做的事（这次做不完、要等条件满足、做到一半）用 todo 记下并随做随更新进度，用户能看到是哪个会话在处理、到哪一步了，做完或不用做了马上 todo done 关掉（不关的话用户那边越堆越多）；只有用户能做的事（注册账号、申请 AppID / Key、付款、在后台操作、提供密码）用 todo --user 提醒他，他可以现在处理或加入自己的待办。给出账号密码、密钥、服务器地址这类以后还要用的关键信息时，用 keyinfo 单独发给用户方便收藏。不要只在回复里写「以后记得……」。
---

<!-- tars-todos v4 -->

# 待办和关键信息：交给用户的 Kiteline

用户在手机上的 Kiteline 里有「待办」和「收藏」。待办分两块：**你（agent）自己的待办**和**用户的待办**，别混在一起。

## 你自己的待办（todo）

你以后要接着做的事：这次做不完的、要等条件满足的（例：「Windows / Linux 端还没改，等测试虚拟机能开了再改」）、做到一半的。
用户不用管，他只看是哪个会话在处理、做到哪一步了，所以**做的时候要随时更新**。

```bash
{{cmd}} todo "Windows/Linux 客户端：读图缩略图、看大图左右滑" --detail "代码已写好未测，补丁在 docs/pending.patch；等测试虚拟机能开后应用并实测"
# → 打印编号，如 t-3fa2c1，记住它
{{cmd}} todo start t-3fa2c1 "开始做：先应用补丁"
{{cmd}} todo progress t-3fa2c1 "补丁已应用，Win11 上实测通过，Linux 还在测"
{{cmd}} todo done t-3fa2c1 "两端都实测通过，已装到测试机"
{{cmd}} todo list            # 还没做完的：这个会话的在前，也列别的会话、别的电脑上记的
```

- 标题一句话，`--detail` 写清楚背景、涉及的文件和命令、做到哪一步、怎么算做完——接手的可能是另一个会话，看不到这次的对话。
- **做完一定要关**：做完马上 `todo done <编号> "结果"`；不用做了（需求取消、重复了、被别的会话做掉了）也用 done，说明里写原因。跟用户说「做完了」之前先 `todo list` 对一遍，这个会话名下其实已经做完的都关掉。发图、发报告时还有没关的，命令输出会提醒你。
- 开始做一件事之前先 `todo list`：别的会话（包括别的电脑上的）可能已经记过同一件事——别重复记，用 `todo start <它的编号>` 接手；顺手做掉了别的会话记的事，也把它关掉。
- 不要记：马上就要做的、已经做完的、可有可无的建议；同一件事不要重复记（记的时候有相近的会提示你）。

## 只有用户能做的事（todo --user）

需要用户亲自动手的（注册账号、申请 AppID / Key、付款、在网站后台操作、提供账号密码……）：

```bash
{{cmd}} todo --user "在微信开放平台申请小程序 AppID" --detail "网址、步骤；拿到后把 AppID 发给我"
```

- 用户会收到提醒，可以选「现在处理」或「加入待办」稍后处理；处理好后他会回到这个会话告诉你。
- 在那之前别卡住：能先做的先做，用占位值的地方写清楚。

## 关键信息（keyinfo）

给出以后还要用的信息时（测试账号和密码、生成的密钥、服务器地址和端口、后台入口……），除了回复里提一句，再用 keyinfo 单独发一份，用户可以一键收藏、一键复制：

```bash
{{cmd}} keyinfo "测试环境管理员账号" --field "地址=https://staging.example.com/admin" --field "账号=admin@example.com" --secret "密码=Xy7#k2pQ" --note "只在测试环境用"
```

- 密码、令牌、私钥这类用 `--secret`（手机上默认遮住，点一下才显示）；其他用 `--field`；补充说明用 `--note`。
- 只发用户需要知道的、你生成的或用户给你的信息；不要从用户电脑里翻找别的密码发出来。
"""

_SKILL_STAGES = """---
name: tars-stages
description: 做任务时报告进度阶段。用户在手机和电脑上的 Kiteline 里同时看好几个会话，每个会话名下显示做到哪一步（如「2/4 开发中」「iPhone · 3/4 测试中」）。接到要动手的任务先按这件事实际怎么做规划步骤：`{{cmd}} stage --steps "复现,定位,修复,验证,汇报"`（分几个端、几个模块的再加 --parts "Mac,iPhone,Windows/Linux"）；进入每一步时 `{{cmd}} stage <第几步> [--part 哪部分] --note "在做什么"`；做完 `{{cmd}} stage done`。
---

<!-- tars-stages v3 -->

# 报告任务阶段

用户常同时开着好几个会话，在 Kiteline 的会话列表里看哪几个在工作、各到哪一步：「正在工作」前面显示「2/4 开发中」这样的标识，对话页上有任务进展。
没规划的任务只按你调用的工具粗略推断成默认四步（读代码 → 调研，改文件 → 开发，跑测试 → 测试，发图、提交、安装、部署 → 汇报 / 发布），只进不退。
**你规划过步骤的任务不做推断，只认你报的**：规划完不报，列表会一直停在第 1 步；报一次停一次，所以每进入一步都要报。

## 1. 开始任务：按这件事实际怎么做规划步骤

步骤照这次任务真实的做法来，不是固定的四步。步骤名用户一眼看得懂（2～5 个字），一般 3～6 步：

```bash
{{cmd}} stage --steps "复现,定位,修复,验证,汇报"            # 修 bug
{{cmd}} stage --steps "调研了解,方案设计,开发中,测试中,发布中"   # 新功能
{{cmd}} stage --steps "调研了解,汇报"                        # 只是查清楚一个问题
{{cmd}} stage --steps default                                # 默认流程：这个项目记过流程就用它，否则是调研了解 / 开发中 / 测试中 / 汇报中
```

- 一两句话就能答完的问题不用规划、不用报。
- 规划完列表显示第 1 步；接着做第 2 步时 `stage 2`，依次往下，**每一步都要报**。
- 规划在这个会话里一直有效，用户中途回「继续」也接着算；换了一件事就重新 `--steps`。

## 2. 分几个端、几个模块做的：分部分

每部分各走一遍上面的步骤，列表显示成「●●○ iPhone · 2/4 开发中」（圆点是各部分的完成情况）：

```bash
{{cmd}} stage --steps "开发,测试,安装" --parts "Mac,iPhone,Windows/Linux"
{{cmd}} stage 1 --part Mac --note "侧栏加标识"
{{cmd}} stage 测试 --part Mac
{{cmd}} stage done --part Mac                 # 这部分做完了
{{cmd}} stage 开发 --part iPhone              # 接着做下一部分
```

- 各部分都要的公共工作（比如先改共用的后台）可以单列一部分，如 --parts "公共,Mac,iPhone"。
- 同时推进几部分时，报的是你此刻在做的那部分；某部分卡住等条件（比如等测试机）就先做别的部分，回头再接着报。

## 3. 进入每一步时报一下，做完收尾

```bash
{{cmd}} stage 2 --note "改登录页和接口"      # 写序号或步骤名都行
{{cmd}} stage 修复 --note "边界条件"          # 验证时发现问题回去改：报回那一步
{{cmd}} stage show                            # 看现在的规划、做到哪
{{cmd}} stage done                            # 整个任务做完（分了部分的用 done --part 一部分一部分关，或 done --all）
```

- 只报阶段变化，不用每个命令都报；`--note` 几个字说清在做什么（列表里放不下长句）。
- 改代码、编译、跑测试反复穿插是一步里的事，不用来回报；真的回到前面某一步（比如验证发现方案要改）才报回去。
- 发图、记待办时如果命令输出提醒「列表上还停在第几步」，说明你很久没报了，按实际补报。
- 默认四步时写「发布」显示成「发布中」，写「汇报」显示「汇报中」。

## 4. 用户和你约定了固定流程

用户说「我们的流程是……」或者这个项目一向这么做：加 `--remember` 记成这个项目的默认流程，以后开始任务时 `stage --steps default` 就用它。

```bash
{{cmd}} stage --steps "需求确认,开发,自测,评审,上线" --remember
{{cmd}} stage --steps default --remember      # 这个项目恢复默认四步
```
"""

# 各平台截桌面怎么截（截图技能里那一句）
_SKILL_SCREEN = {
    "mac": "macOS 上截桌面或某个窗口：`screencapture -x /tmp/s.png`（需要屏幕录制权限），再用 send-image 发。",
    "windows": "Windows 上截整个屏幕：在 PowerShell 里用 `Add-Type -AssemblyName System.Windows.Forms,System.Drawing` 后把 "
               "`[System.Windows.Forms.Screen]::PrimaryScreen.Bounds` 画进 Bitmap 存成 PNG，再用 send-image 发。",
    "linux": "Linux 桌面上截屏：有 `gnome-screenshot -f /tmp/s.png`、`grim /tmp/s.png`（Wayland）或 `import -window root /tmp/s.png`（X11）就用，再用 send-image 发。",
}

SKILLS_BUILTIN = {
    "version": "1.0.4",   # 整份数据的版本（同插件版本号）：下发的技能包版本更高才换
    # 各家 agent 读技能的目录（当前用户的）；when：这个目录在，说明这台电脑装了这家；unless：这个在就不用另装（别家已经读到）
    "targets": [
        {"agent": "claude-code", "dir": "~/.claude/skills", "when": "~/.claude"},          # OpenCode 也读这里
        {"agent": "codex", "dir": "$CODEX_HOME/skills", "when": "$CODEX_HOME"},
        {"agent": "deepseek-harness", "dir": "$DSH_HOME/skills", "when": "$DSH_HOME"},
        {"agent": "qwen-code", "dir": "~/.qwen/skills", "when": "~/.qwen"},
        {"agent": "opencode", "dir": "~/.agents/skills", "when": "~/.config/opencode", "unless": "~/.claude"},
    ],
    "skills": [
        {"id": "screenshots", "name": "tars-screenshots", "marker": "tars-skill v", "content": _SKILL_SCREENSHOTS},
        {"id": "playwright", "name": "tars-playwright-report", "marker": "tars-playwright v", "content": _SKILL_PLAYWRIGHT},
        {"id": "todos", "name": "tars-todos", "marker": "tars-todos v", "content": _SKILL_TODOS},
        {"id": "stages", "name": "tars-stages", "marker": "tars-stages v", "content": _SKILL_STAGES},
    ],
    # 早期版本的技能目录：带我们标记的删掉
    "legacy": [{"name": "ccpulse-send-image", "marker": "send-image"}],
}


def skills_enabled():
    """电脑端带来的开着的技能 id；没带 CCPULSE_SKILLS 返回 None（不动技能）"""
    raw = os.environ.get("CCPULSE_SKILLS")
    return None if raw is None else set(filter(None, (part.strip() for part in raw.split(","))))


def _version_key(text):
    return [int(part) if part.isdigit() else 0 for part in re.split(r"[.\-]", str(text or "0"))]


def skills_data():
    """内置的技能数据；电脑端下发过更新的（plugins/skills/skills.json，校验过签名才放进来的）版本更高就用它"""
    try:
        path = os.path.join(PLUGINS_DIR, "skills", SKILLS_FILE)
        data = json.loads(read_text(path) or "null")
        if isinstance(data, dict) and isinstance(data.get("skills"), list) and isinstance(data.get("targets"), list) \
                and _version_key(data.get("version")) > _version_key(SKILLS_BUILTIN["version"]):
            return data
    except ValueError:
        pass
    return SKILLS_BUILTIN


def _skill_path(text):
    """技能数据里的路径：$CODEX_HOME、$DSH_HOME 有默认值，~ 是当前用户"""
    if not text:
        return None
    homes = {"CODEX_HOME": os.environ.get("CODEX_HOME") or os.path.join(HOME, ".codex"), "DSH_HOME": DSH_HOME}
    text = re.sub(r"\$(\w+)|\$\{(\w+)\}", lambda m: homes.get(m.group(1) or m.group(2)) or os.environ.get(m.group(1) or m.group(2)) or m.group(0), text)
    return os.path.expanduser(text)


def self_command():
    """agent 在 Bash 里调本脚本的写法（技能正文里用）；电脑端可以经 CCPULSE_SELF_COMMAND 指定（Windows 打包版要用 Kiteline.exe 跑）"""
    given = os.environ.get("CCPULSE_SELF_COMMAND")
    if given:
        return given
    path = os.path.abspath(__file__)
    python = os.environ.get("CCPULSE_PYTHON") or "python3"
    # Windows 上不写 ~ 和 $HOME：PowerShell、cmd 不展开，那里的 agent（Codex、Cursor）照抄就找不到脚本
    if path.startswith(HOME + os.sep) and os.name != "nt":
        rest = path[len(HOME):].replace("\\", "/")
        return "%s ~%s" % (python, rest) if " " not in rest else '%s "$HOME%s"' % (python, rest)
    path = path.replace("\\", "/")   # Git Bash 里反斜杠是转义符
    return '%s "%s"' % (python, path) if " " in path else "%s %s" % (python, path)


def render_skill(skill):
    platform = "mac" if sys.platform == "darwin" else ("windows" if os.name == "nt" else "linux")
    return str(skill.get("content") or "").replace("{{cmd}}", self_command()).replace("{{screen}}", _SKILL_SCREEN[platform])


def skill_targets(data):
    """这台电脑上要装技能的目录：[(agent, 目录)]，同一个目录只出现一次"""
    out = []
    for target in data.get("targets") or []:
        if not isinstance(target, dict):
            continue
        when, unless, folder = _skill_path(target.get("when")), _skill_path(target.get("unless")), _skill_path(target.get("dir"))
        if folder and when and os.path.exists(when) and not (unless and os.path.exists(unless)) and folder not in [f for _, f in out]:
            out.append((str(target.get("agent") or ""), folder))
    return out


def sync_skills(enabled=None, data=None):
    """把开着的技能装到这台电脑上各家 agent 的技能目录（内容一样就不动），关掉的按标记删掉。返回 {installed, removed, targets}"""
    enabled = skills_enabled() if enabled is None else set(enabled)
    result = {"installed": [], "removed": [], "targets": []}
    if enabled is None:
        return result
    data = data or skills_data()
    skills = [s for s in data.get("skills") or [] if isinstance(s, dict) and s.get("name") and s.get("marker")]
    for agent, root in skill_targets(data):
        result["targets"].append({"agent": agent, "dir": root})
        for skill in skills:
            folder = os.path.join(root, skill["name"])
            path = os.path.join(folder, "SKILL.md")
            current = read_text(path)
            try:
                if skill.get("id") in enabled:
                    text = render_skill(skill)
                    if current != text:
                        os.makedirs(folder, exist_ok=True)
                        with open(path + ".tmp", "w", encoding="utf-8", newline="\n") as handle:
                            handle.write(text)
                        os.replace(path + ".tmp", path)
                        result["installed"].append(path)
                elif current and skill["marker"] in current:
                    shutil.rmtree(folder, ignore_errors=True)
                    result["removed"].append(path)
            except OSError as exc:
                log("装技能 %s 到 %s 失败：%s" % (skill["name"], root, exc))
        for old in data.get("legacy") or []:
            folder = os.path.join(root, str(old.get("name") or ""))
            current = read_text(os.path.join(folder, "SKILL.md"))
            if old.get("name") and current and str(old.get("marker") or "") in current:
                shutil.rmtree(folder, ignore_errors=True)
                result["removed"].append(folder)
    for path in result["installed"]:
        log("已安装技能：%s" % path)
    for path in result["removed"]:
        log("已移除技能：%s" % path)
    return result


# ---------------------------------------------------------------------------
# 订阅额度（5 小时 / 每周）：Claude Code 靠一个小 mod（2.1.3xx 起的插件接口，放进技能目录自动加载）在每次回复后
# 把引擎拿到的额度（接口响应头里的，不碰凭证）写到 <Claude 配置目录>/kiteline/limits.json；Codex 自己记在 rollout 里。
# 电脑端问 limits 汇总各台电脑，手机首页的「今日用量」卡片画成环形
# ---------------------------------------------------------------------------

LIMITS_MOD_NAME = "kiteline-usage"
LIMITS_MOD_MARKER = "kiteline-usage v1"
LIMITS_MOD_FILES = {
    ".claude-plugin/plugin.json": json.dumps({
        "name": LIMITS_MOD_NAME, "version": "1.0.0",
        "description": "Kiteline: records your plan usage limits (5-hour / weekly) locally so the Kiteline app can show them.",
    }, ensure_ascii=False, indent=2) + "\n",
    "hooks/hooks.json": '{ "modules": ["./register.ts"] }\n',
    "hooks/register.ts": """// %s：Kiteline 装的，别改（会被覆盖）。
import type { Register } from 'claude-code'

// 每次回复后引擎推来的额度（接口响应头里的，不碰凭证），写到 <Claude 配置目录>/kiteline/limits.json 给 Kiteline 读
export const register: Register = on => {
  on('session.measure', async ($, e, next) => {
    if (e.rateLimits.length > 0) {
      const dir = (await $.env.get('CLAUDE_CONFIG_DIR'))
        ?? `${(await $.env.get('HOME')) ?? (await $.env.get('USERPROFILE'))}/.claude`
      const row = { at: await $.clock.now(), sessionId: await $.session.id(), limits: e.rateLimits }
      await $.fs.write(`${dir}/kiteline/limits.json`, JSON.stringify(row))
    }
    return next(e)
  }).catch(($, e, next) => next(e))
}
""" % LIMITS_MOD_MARKER,
}
# 任务阶段提醒：agent 进了下一步却没报，watcher 在 <Claude 配置目录>/kiteline/stage/<会话>.json 留一句（StageTracker.nudge），
# 这个 mod 在主对话下一次工具调用之后附在结果后面给模型看（用户看不到）；同一条只附一次，放久了的不附
STAGE_MOD_NAME = "kiteline-stages"
STAGE_MOD_MARKER = "kiteline-stages v1"
STAGE_MOD_FILES = {
    ".claude-plugin/plugin.json": json.dumps({
        "name": STAGE_MOD_NAME, "version": "1.0.0",
        "description": "Kiteline: reminds the agent to report its task step when Kiteline sees it has moved on without reporting.",
    }, ensure_ascii=False, indent=2) + "\n",
    "hooks/hooks.json": '{ "modules": ["./register.ts"] }\n',
    "hooks/register.ts": """// %s：Kiteline 装的，别改（会被覆盖）。
import type { Register } from 'claude-code'

// Kiteline 看到 agent 进了下一步却没报（任务阶段技能）时，在 <Claude 配置目录>/kiteline/stage/<会话>.json 留一句提醒；
// 主对话的下一次工具调用之后把它附在结果后面给模型看（用户看不到），同一条只附一次，放久了的不附
let delivered = ''
export const register: Register = on => {
  on('tool.call', async ($, e, next) => {
    const result = await next(e)
    if (e.agentId !== undefined || result.deny !== undefined || result.isError) return result
    try {
      const dir = (await $.env.get('CLAUDE_CONFIG_DIR'))
        ?? `${(await $.env.get('HOME')) ?? (await $.env.get('USERPROFILE'))}/.claude`
      const raw = await $.fs.read(`${dir}/kiteline/stage/${await $.session.id()}.json`).catch(() => '')
      const note = raw ? JSON.parse(raw) : null
      if (!note || typeof note.id !== 'string' || typeof note.text !== 'string' || note.id === delivered) return result
      if (Math.abs((await $.clock.now()) - Number(note.at)) > 10 * 60 * 1000) return result
      delivered = note.id
      return { ...result, context: [...(result.context ?? []), note.text] }
    } catch {
      return result
    }
  }).catch(($, e, next) => next(e))
}
""" % STAGE_MOD_MARKER,
}
# 额度读数多久不更新就不报了（一周窗口都过完了，留着只会误导）
LIMITS_STALE_MS = 8 * 86400000
# Codex 的窗口按分钟数认：300 = 5 小时，10080 = 一周
_CODEX_WINDOWS = {300: "five_hour", 10080: "seven_day"}


def claude_config_dir():
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude")


def sync_limits_mod(root=None):
    """装上 / 更新额度 mod（内容一样就不动）。没装 Claude Code 的电脑不装；别人放的同名文件夹（没我们的标记）不碰。
    不传 root 时只在电脑端带了技能配置（CCPULSE_SKILLS，正式运行）时装：测试、旧版电脑端起的 watcher 不往真实的 ~/.claude 里写"""
    if root is None and skills_enabled() is None:
        return False
    return _sync_mod(root or claude_config_dir(), LIMITS_MOD_NAME, LIMITS_MOD_MARKER, LIMITS_MOD_FILES, "额度插件")


def sync_stage_mod(root=None, enabled=None):
    """任务阶段技能开着就装提醒 mod（见 STAGE_MOD_FILES），关了按标记删掉；规矩同 sync_limits_mod"""
    if enabled is None:
        skills = skills_enabled()
        if root is None and skills is None:
            return False
        enabled = skills is not None and "stages" in skills
    root = root or claude_config_dir()
    if enabled:
        return _sync_mod(root, STAGE_MOD_NAME, STAGE_MOD_MARKER, STAGE_MOD_FILES, "任务阶段插件")
    folder = os.path.join(root, "skills", STAGE_MOD_NAME)
    if STAGE_MOD_MARKER.split(" v")[0] in (read_text(os.path.join(folder, "hooks", "register.ts")) or ""):
        shutil.rmtree(folder, ignore_errors=True)
        log("已移除任务阶段插件：%s" % folder)
    return False


def _sync_mod(root, name, marker, files, label):
    if not os.path.isdir(root):
        return False
    folder = os.path.join(root, "skills", name)
    current = read_text(os.path.join(folder, "hooks", "register.ts"))
    if os.path.isdir(folder) and current is not None and marker.split(" v")[0] not in current:
        return False
    changed = False
    for rel, text in files.items():
        path = os.path.join(folder, *rel.split("/"))
        if read_text(path) == text:
            continue
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path + ".tmp", "w", encoding="utf-8", newline="\n") as handle:
                handle.write(text)
            os.replace(path + ".tmp", path)
            changed = True
        except OSError as exc:
            log("装%s失败：%s" % (label, exc))
            return False
    if changed:
        log("已安装%s：%s" % (label, folder))
    return True


# ---------------------------------------------------------------------------
# 后台送达（不打扰用户用电脑）：手机上发消息、中断、确认、回答提问，原来要切到 VS Code 粘贴、按键，占着前台和键盘。
# Claude Code 的 mod 接口能在会话进程里以用户身份提交消息（$.prompt.submit asUser）、中断（$.turn.abort）、
# 应答确认请求（PermissionRequest 钩子：电脑上照常弹框，手机先答 CLI 自己撤掉框）。watcher 装这个 mod（名字就叫 kiteline，
# VS Code 里这类消息上方标「Prompt from the kiteline plugin」），把指令写进 <Claude 配置目录>/kiteline/inbox/<会话>.json，
# mod 照做后写 <会话>.ack-<id>.json。Claude 正忙时发的话（$.prompt.submit 要等这一轮做完）由 mod 在下一批工具跑完后
# 插进这一轮（$.session.append，回执 later），跟在 VS Code 里趁它忙时打字一样；见 bridge_said。
# mod 只在会话启动时加载：装之前开着的会话快照里 bridge 为假，电脑端照旧走前台
# ---------------------------------------------------------------------------

BRIDGE_MOD_NAME = "kiteline"
BRIDGE_MOD_MARKER = "kiteline v1"
BRIDGE_MOD_FILES = {
    ".claude-plugin/plugin.json": json.dumps({
        "name": BRIDGE_MOD_NAME, "version": "1.0.0",
        "description": "Kiteline: delivers what you send from your phone (messages, interrupts, approvals, answers) "
                       "straight into this session, without taking over your screen or keyboard.",
    }, ensure_ascii=False, indent=2) + "\n",
    "hooks/hooks.json": '{ "modules": ["./register.ts"] }\n',
    "hooks/register.ts": """// %s：Kiteline 装的，别改（会被覆盖）。
import type { Register } from 'claude-code'

// 手机上发的消息、中断、确认、回答提问直接交给会话，不切窗口、不模拟按键：用户在电脑上做别的事不受打扰。
// Kiteline 把指令写进 <Claude 配置目录>/kiteline/inbox/<会话>.json（{items: [{id, op, …, expires}]}），这里每 0.4 秒看一眼，
// 照做后写 <会话>.ack-<id>.json；<会话>.alive 记下这个进程什么时候装上的，Kiteline 据此知道这个会话能走这条路
type Item = { id: string; op: string; text?: string; decision?: string; answers?: Record<string, string>; tool?: string; expires?: number;
  action?: string; qid?: string; dir?: number }
type Queued = { id: string; text: string }
type Waiter = { agent: string; tool: string; key: string; wake: (item: Item | null) => void; input: unknown; id: string; at: number }

let dir = ''
let sid = ''
let turn: string | undefined
let ticking = false
let windows = false
const done = new Set<string>()
const waiters: Waiter[] = []
// Claude 正忙时发来、还没交给它的话（排队）：每条带 Kiteline 那边的编号，手机、电脑上能调顺序、改、删、强插；
// 有变化就写进 <会话>.queue.json，Kiteline 据此在输入框上方列出来
const later: Queued[] = []
const publishQueue = ($: any) => {
  if (!dir || !sid) return
  void Promise.resolve($.fs.write(`${dir}/${sid}.queue.json`, JSON.stringify({ items: later }))).catch(() => undefined)
}
const submit = ($: any, text: string) =>
  void $.prompt.submit({ text: text.startsWith('/') ? `\\u200b${text}` : text, asUser: true })

// 正在等的确认（命令、提问、计划）写进 <会话>.asks.json：新版 Claude Code 答完之前不把这次工具调用写进对话记录，
// Kiteline 靠这份在手机、电脑上画出问题和选项
const publish = ($: any) => {
  if (!dir || !sid) return
  const items = waiters.map(w => ({ tool: w.tool, input: w.input, toolUseId: w.id, agent: w.agent, at: w.at }))
  void Promise.resolve($.fs.write(`${dir}/${sid}.asks.json`, JSON.stringify({ items }))).catch(() => undefined)
}

// 同一次工具调用在 tool.call 和确认请求里的参数对得上：键排好序再比
const canon = (value: unknown): string => JSON.stringify(value, (_, x) =>
  x && typeof x === 'object' && !Array.isArray(x) ? Object.fromEntries(Object.entries(x).sort(([a], [b]) => a < b ? -1 : 1)) : x)

export const register: Register = on => {
  on('turn.start', ($, e, next) => {
    if (e.agentId === undefined) turn = e.turnId
    return next(e)
  })
  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if (e.turnId === turn) {
      turn = undefined
      // 这一轮后面没再调用工具（在写最后的回复，或被中断了）：没赶上的话作为下一句提交
      if (later.length) {
        for (const q of later.splice(0)) submit($, q.text)
        publishQueue($)
      }
    }
    return result
  })

  // Claude 正忙时发来的话：跟在 VS Code 里趁它忙时打字一样，这一批工具跑完、下一次请求模型之前交给它，不用等这一轮做完。
  // 插进去的是一行你说的话（记录里 isMeta、origin 是 kiteline 插件，watcher 照你发的显示；VS Code 里不显示这一行）
  on('classic.PostToolBatch', async ($, e, next) => {
    const result = await next(e)
    if (e.agent_id !== undefined) return result
    if (!later.length) return result
    for (const q of later.splice(0)) {
      // 开头垫零宽空格：watcher 据此认出是你的话（替插件执行命令时 Claude Code 写的说明行也是 isMeta、kiteline 来源，不能显示）
      const added = await $.session.append({ message: { type: 'user', content: [{ type: 'text', text: `\\u200b${q.text}` }] } }).catch(() => undefined)
      if (!added || added.deny !== undefined) later.push(q)
    }
    publishQueue($)
    return result
  })

  // 确认框电脑上已经答了（工具跑完或被拒）：别再等手机
  on('tool.call', async ($, e, next) => {
    try {
      return await next(e)
    } finally {
      const { tool, tool_use_id: _id, agentId, requestMeta: _meta, ...args } = e as typeof e & { requestMeta?: unknown }
      const key = canon(args)
      for (const w of waiters.filter(w => w.agent === (agentId ?? '') && w.tool === tool && w.key === key)) w.wake(null)
    }
  })

  // Claude 要确认（命令、改文件、提问、计划）时，VS Code 照常弹框，同时等手机的回答；哪边先答算哪边。
  // 钩子自己的时间上限 10 秒，子进程在跑时不计：挂一个休眠的子进程等着，答了就收掉
  on('classic.PermissionRequest', async ($, e, next) => {
    if (!dir) return next(e)
    let wake: (item: Item | null) => void = () => {}
    const answered = new Promise<Item | null>(resolve => { wake = resolve })
    const waiter: Waiter = { agent: e.agent_id ?? '', tool: e.tool_name, key: canon(e.tool_input), wake: item => wake(item),
      input: e.tool_input, id: (e as typeof e & { tool_use_id?: string }).tool_use_id ?? '', at: await $.clock.now() }
    waiters.push(waiter)
    publish($)
    const sleeper = $.process.spawn({ argv: windows ? ['powershell', '-NoProfile', '-Command', 'Start-Sleep 86400'] : ['sleep', '86400'] })
    const child = sleeper[Symbol.asyncIterator]()
    let item: Item | null = null
    try {
      item = await Promise.race([answered, child.next().then(() => null, () => null)])
    } finally {
      waiters.splice(waiters.indexOf(waiter), 1)
      publish($)
      void child.return?.(undefined)
    }
    if (!item) return next(e)
    if (item.op === 'answer') {
      const input = e.tool_input as Record<string, unknown>
      return { decision: { behavior: 'allow', updatedInput: { ...input, answers: item.answers ?? {} } } }
    }
    if (item.decision === 'allow') return { decision: { behavior: 'allow' } }
    if (item.decision === 'allow_session') {
      // 手机上的按钮是「本会话不再询问」：Claude 建议的规则只记在这次会话里，不写进项目设置
      const rules = (e.permission_suggestions ?? []).map(rule => ({ ...rule, destination: 'session' as const }))
      return { decision: { behavior: 'allow', updatedPermissions: rules } }
    }
    return { decision: { behavior: 'deny', message: 'The user declined this from Kiteline on their phone.', interrupt: true } }
  }).catch(($, e, next) => next(e))

  on('session.start', async ($, e, next) => {
    const started = await next(e)
    const root = (await $.env.get('CLAUDE_CONFIG_DIR'))
      ?? `${(await $.env.get('HOME')) ?? (await $.env.get('USERPROFILE'))}/.claude`
    windows = (await $.env.get('OS')) === 'Windows_NT'
    dir = `${root}/kiteline/inbox`
    sid = await $.session.id()
    // v2：会写 <会话>.queue.json、认 queue 指令（排队的话能调顺序、改、删、强插）
    await $.fs.write(`${dir}/${sid}.alive`, JSON.stringify({ at: await $.clock.now(), v: 2 }))
    publishQueue($)
    if (ticking) return started
    ticking = true
    let busy = false
    $.clock.every(400, async () => {
      if (busy || !sid) return
      busy = true
      try {
        const path = `${dir}/${sid}.json`
        if (!(await $.fs.exists(path))) return
        const now = await $.clock.now()
        const items: Item[] = JSON.parse(await $.fs.read(path)).items ?? []
        for (const item of items) {
          if (!item || typeof item.id !== 'string' || done.has(item.id)) continue
          if (typeof item.expires === 'number' && item.expires < now) continue
          done.add(item.id)
          let result = 'ok'
          if (item.op === 'send' && typeof item.text === 'string') {
            // 斜杠命令（手机上的压缩上下文、切换模型、思考强度……）照在输入框里打的那样执行；别的作为你说的话提交，Claude 正忙就留到它下一步
            const slash = /^\\/([\\w:.-]+)(?:\\s+([\\s\\S]*))?$/.exec(item.text.trim())
            if (slash && (await $.command.list()).some(c => c.name === slash[1])) {
              void $.command.run({ command: slash[1], args: slash[2] ?? '' })
            } else if (turn) {
              later.push({ id: item.id, text: item.text })
              publishQueue($)
              result = 'later'
            } else {
              // 以「/」开头却不是命令（比如开头是个路径）：引擎不让插件这样提交，前面垫一个零宽空格，模型看到的内容不变
              submit($, item.text)
            }
          } else if (item.op === 'queue') {
            // 排队的话：move（dir -1 上移 / 1 下移）、edit（text）、delete；now = 强插：挪到最前，中断这一轮，
            // turn.complete 里按顺序全部提交（正在跑的工具不跑完插不进去）；这时已经空闲就直接提交
            const at = later.findIndex(q => q.id === item.qid)
            if (at < 0) {
              result = 'none'
            } else if (item.action === 'move') {
              const to = at + ((item.dir ?? 1) < 0 ? -1 : 1)
              if (to >= 0 && to < later.length) [later[at], later[to]] = [later[to], later[at]]
            } else if (item.action === 'edit' && typeof item.text === 'string' && item.text.trim()) {
              later[at] = { id: later[at].id, text: item.text }
            } else if (item.action === 'delete') {
              later.splice(at, 1)
            } else if (item.action === 'now') {
              later.unshift(...later.splice(at, 1))
              if (turn) await $.turn.abort({ turnId: turn })
              else for (const q of later.splice(0)) submit($, q.text)
            } else {
              result = 'unknown'
            }
            publishQueue($)
          } else if (item.op === 'abort') {
            if (turn) await $.turn.abort({ turnId: turn })
            else result = 'idle'
          } else if (item.op === 'perm' || item.op === 'answer') {
            // 交给手机上那张卡片对应的确认框：回答只给提问框；带了工具名的按名字对，对不上说明手机看到的已经过时了
            const tool = item.op === 'answer' ? 'AskUserQuestion' : item.tool
            // 「允许」不拿去答提问框（没带答案，答了等于白答、还把这个等待用掉了）；拒绝可以（同在电脑上按 Esc）
            const fits = waiters.filter(w => (!tool || w.tool === tool)
              && !(item.op === 'perm' && item.decision !== 'deny' && w.tool === 'AskUserQuestion'))
            const waiter = fits.find(w => w.agent === '') ?? fits[0]
            if (waiter) waiter.wake(item)
            else result = 'none'
          } else {
            result = 'unknown'
          }
          await $.fs.write(`${dir}/${sid}.ack-${item.id}.json`, JSON.stringify({ result, at: await $.clock.now() }))
        }
      } catch {
        // 文件写到一半、格式不对：下一轮再看
      } finally {
        busy = false
      }
    })
    return started
  })
}
""" % BRIDGE_MOD_MARKER,
}
BRIDGE_OPS = ("send", "abort", "perm", "answer", "queue")
BRIDGE_QUEUE_ACTIONS = ("move", "edit", "delete", "now")
BRIDGE_WAIT = 2.5     # 等 mod 回执的秒数（它 0.4 秒看一次收件箱）；过了就撤下，电脑端改走前台
BRIDGE_GRACE = 0.8    # 撤下后再等一会儿：正好在撤之前被 mod 拿走的也认回执，免得电脑端再从前台发一遍
BRIDGE_TIDY_SECONDS = 3600
_BRIDGE_LOCK = threading.Lock()
_BRIDGE_ALIVE = {}    # 会话 → (alive 文件 mtime, mod 写入的时刻)
_BRIDGE_TIDIED = [0.0]


def sync_bridge_mod(root=None):
    """装上 / 更新后台送达 mod。不带参数随时可以重复调（托管会话起 claude 之前也调），内容一样不动文件，出错只记日志、不抛。
    规矩同 sync_limits_mod：不传 root 时只在电脑端带了技能配置（CCPULSE_SKILLS，正式运行）时装。返回 True = 装好了"""
    try:
        if root is None and skills_enabled() is None:
            return False
        ok = _sync_mod(root or claude_config_dir(), BRIDGE_MOD_NAME, BRIDGE_MOD_MARKER, BRIDGE_MOD_FILES, "后台送达插件")
        if time.time() - _BRIDGE_TIDIED[0] > BRIDGE_TIDY_SECONDS:
            _BRIDGE_TIDIED[0] = time.time()
            bridge_tidy(os.path.join(root, "kiteline", "inbox") if root else None)
        return ok
    except Exception as exc:  # noqa
        log("装后台送达插件出错：%r" % exc)
        return False


def bridge_dir():
    return os.path.join(claude_config_dir(), "kiteline", "inbox")


def bridge_tidy(folder=None, now=None):
    """收件箱里的陈年文件：回执、没人取的指令过一小时删，alive 过 30 天删（会话早结束了）"""
    folder = folder or bridge_dir()
    now = now or time.time()
    try:
        names = os.listdir(folder)
    except OSError:
        return
    for name in names:
        path = os.path.join(folder, name)
        keep = 30 * 86400 if name.endswith((".alive", ".asks.json")) else 3600
        try:
            if now - os.path.getmtime(path) > keep:
                os.remove(path)
        except OSError:
            pass


def bridge_alive(session_id, started_at):
    """这个会话现在的 claude 进程加载了 mod 没有：mod 在会话开始时写 <会话>.alive（毫秒时刻），不早于进程启动就算。
    恢复会话（新进程、同一会话 id）时旧进程留下的 alive 早于新进程启动，不算"""
    if not session_id:
        return False
    path = os.path.join(bridge_dir(), "%s.alive" % session_id)
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        return False
    cached = _BRIDGE_ALIVE.get(session_id)
    if cached is None or cached[0] != mtime:
        try:
            with open(path, encoding="utf-8") as handle:
                data = json.load(handle)
            at, version = int(data.get("at") or 0), int(data.get("v") or 1)
        except (OSError, ValueError, TypeError, AttributeError):
            at, version = 0, 1
        cached = _BRIDGE_ALIVE[session_id] = (mtime, at, version)
    started = started_at if isinstance(started_at, (int, float)) and not isinstance(started_at, bool) else 0
    return cached[2] if cached[1] > 0 and cached[1] >= started else False


def bridge_queue(session_id, started_at):
    """Claude 正忙时手机发来、还排在 mod 里没交给它的话：[{id, text}]（mod 写的 <会话>.queue.json）。
    mod 是老版本（v1，不写队列、不认 queue 指令；mod 只在会话启动时加载）回 None，客户端只能看本地记下的、不能改"""
    if not session_id or (bridge_alive(session_id, started_at) or 0) < 2:
        return None
    path = os.path.join(bridge_dir(), "%s.queue.json" % session_id)
    try:
        if isinstance(started_at, (int, float)) and os.path.getmtime(path) * 1000 < started_at:
            return []
        with open(path, encoding="utf-8") as handle:
            items = json.load(handle).get("items")
    except (OSError, ValueError, AttributeError):
        return []
    return [{"id": x["id"], "text": x["text"]} for x in items or []
            if isinstance(x, dict) and isinstance(x.get("id"), str) and isinstance(x.get("text"), str)]


_ASK_ITEMS = {}    # 会话 → 从 mod 那里补出来的待确认工具调用（对话项，见 bridge_ask）


def bridge_ask(session_id, started_at):
    """mod 写的「正在等的确认」（<会话>.asks.json）里主 agent 最近的一个：新版 Claude Code（2.1.319 实测）弹出提问框、确认框后，
    答完之前不把这次工具调用写进对话记录，单看记录认不出在等什么，手机、电脑上只剩一张没有选项的「需要输入」。
    这个进程写的才算（早于进程启动的是上一个进程留下的）。没有回 None"""
    if not session_id or not bridge_alive(session_id, started_at):
        return None
    path = os.path.join(bridge_dir(), "%s.asks.json" % session_id)
    try:
        if isinstance(started_at, (int, float)) and os.path.getmtime(path) * 1000 < started_at:
            return None
        with open(path, encoding="utf-8") as handle:
            items = json.load(handle).get("items")
    except (OSError, ValueError, AttributeError):
        return None
    mine = [x for x in items or [] if isinstance(x, dict) and not x.get("agent") and isinstance(x.get("tool"), str) and x["tool"]]
    return mine[-1] if mine else None


def ask_item(session_id, ask, transcript):
    """待确认的调用 → 对话项（同记录里的 tool 项），客户端照常画提问 / 计划 / 权限卡片。同一次调用只造一次（id 不变，客户端不重复）；
    id 用记录当前末尾的位置 + 900，排在已有内容后面、不和以后写进来的行撞"""
    tool_input = ask.get("input") if isinstance(ask.get("input"), dict) else {}
    tool_id = ask.get("toolUseId") or "ask-" + hashlib.sha1(
        json.dumps([ask["tool"], tool_input], sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()[:16]
    held = _ASK_ITEMS.get(session_id)
    if held and held["toolId"] == tool_id:
        return held
    try:
        size = os.path.getsize(transcript) if transcript else 0
    except OSError:
        size = 0
    at = ask.get("at")
    name = ask["tool"]
    item = dict({"id": "%d.900" % size, "ts": int(at) if isinstance(at, (int, float)) else int(time.time() * 1000),
                 "t": "tool", "toolId": tool_id, "name": name, "brief": tool_brief(name, tool_input),
                 "input": shrink(tool_input)}, **stage_hint(name, tool_input))
    _ASK_ITEMS[session_id] = item
    return item


def _bridge_items(path):
    try:
        with open(path, encoding="utf-8") as handle:
            items = json.load(handle).get("items")
    except (OSError, ValueError, AttributeError):
        return []
    return [item for item in items if isinstance(item, dict)] if isinstance(items, list) else []


def _bridge_store(path, items):
    """整份换掉（mod 读的时候不会读到半截）；空了就删，mod 那边看一眼文件不在就过去了"""
    if not items:
        try:
            os.remove(path)
        except OSError:
            pass
        return
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump({"items": items}, handle, ensure_ascii=False)
    os.replace(tmp, path)


def bridge_send(session_id, op, wait=BRIDGE_WAIT, **fields):
    """把一条指令交给会话里的 mod，等它回执。op：send（text）/ abort / perm（decision：allow、allow_session、deny）/
    answer（answers：{问题: 答案}）。回 {"bridged": True, "result": ok | idle（中断时本来就空闲）| none（没有待确认的框）}；
    mod 没接（没加载、会话卡住）回 {"bridged": False}，电脑端照旧走前台"""
    folder = bridge_dir()
    path = os.path.join(folder, "%s.json" % session_id)
    item_id = uuid.uuid4().hex[:12]
    now = int(time.time() * 1000)
    item = dict(fields, id=item_id, op=op, expires=now + int(wait * 1000))
    os.makedirs(folder, exist_ok=True)
    with _BRIDGE_LOCK:
        _bridge_store(path, [x for x in _bridge_items(path) if (x.get("expires") or 0) > now] + [item])
    ack = os.path.join(folder, "%s.ack-%s.json" % (session_id, item_id))
    deadline = time.time() + wait
    result = None
    withdrawn = False
    while True:
        if os.path.exists(ack):
            try:
                with open(ack, encoding="utf-8") as handle:
                    result = json.load(handle).get("result") or "ok"
            except (OSError, ValueError, AttributeError):
                result = "ok"
            break
        if time.time() >= deadline + BRIDGE_GRACE:
            break
        if time.time() >= deadline and not withdrawn:
            # 过期了：撤下（mod 也不接过期的），再等一小会儿看是不是正好被拿走了
            withdrawn = True
            with _BRIDGE_LOCK:
                _bridge_store(path, [x for x in _bridge_items(path) if x.get("id") != item_id])
        time.sleep(0.05)
    with _BRIDGE_LOCK:
        _bridge_store(path, [x for x in _bridge_items(path) if x.get("id") != item_id])
    try:
        os.remove(ack)
    except OSError:
        pass
    if result is None:
        return {"bridged": False}
    # 排队了：编号（= 这条指令的 id，mod 的队列用它）回给电脑端，客户端拿它对上输入框上方的排队列表
    return {"bridged": True, "result": result, "qid": item_id} if result == "later" else {"bridged": True, "result": result}


def _iso_ms(value):
    """ISO 8601（带 Z 或 ±HH:MM）或秒 / 毫秒数 → 毫秒"""
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return int(value * 1000) if value < 1e11 else int(value)
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    offset = 0
    match = re.search(r"([+-])(\d\d):?(\d\d)$", text)
    if match and "T" in text:
        offset = (int(match.group(2)) * 60 + int(match.group(3))) * 60000 * (1 if match.group(1) == "+" else -1)
        text = text[:match.start()]
    base = parse_ts(text)
    return None if base is None else base - offset


def _limit_window(kind, percent, resets_at, now):
    """一个窗口：过了重置时间的算 0（还没有新读数，但额度已经回来了）"""
    try:
        percent = max(0.0, float(percent))
    except (TypeError, ValueError):
        return None
    if resets_at is not None and resets_at <= now:
        return {"kind": kind, "percent": 0.0, "resetsAt": None, "reset": True}
    return {"kind": kind, "percent": round(percent, 1), "resetsAt": resets_at}


def claude_limits(root=None, now=None):
    """mod 最近一次写下的额度：{"agent", "at", "windows"}；没有、太旧返回 None"""
    now = now or _now_ms()
    try:
        data = json.loads(read_text(os.path.join(root or claude_config_dir(), "kiteline", "limits.json")) or "null")
    except ValueError:
        return None
    if not isinstance(data, dict) or not isinstance(data.get("limits"), list):
        return None
    at = _iso_ms(data.get("at")) or 0
    if now - at > LIMITS_STALE_MS:
        return None
    windows = [w for w in (_limit_window(str(row.get("kind") or ""), row.get("percentUsed"), _iso_ms(row.get("resetsAt")), now)
                           for row in data["limits"] if isinstance(row, dict) and row.get("kind")) if w]
    return {"agent": "claude-code", "at": at, "windows": windows} if windows else None


def _codex_latest_rollouts(codex_home, count=6):
    """最近改过的几个 rollout：按 年/月/日 目录从新往旧找，不把整棵树扫一遍"""
    base = os.path.join(codex_home, "sessions")
    found = []

    def newest(path):
        try:
            return sorted(os.listdir(path), reverse=True)
        except OSError:
            return []
    for year in newest(base):
        for month in newest(os.path.join(base, year)):
            for day in newest(os.path.join(base, year, month)):
                folder = os.path.join(base, year, month, day)
                for name in newest(folder):
                    if name.startswith("rollout-") and name.endswith(".jsonl"):
                        path = os.path.join(folder, name)
                        try:
                            found.append((os.path.getmtime(path), path))
                        except OSError:
                            pass
                if len(found) >= count:
                    return [p for _, p in sorted(found, reverse=True)]
    return [p for _, p in sorted(found, reverse=True)]


def codex_limits(codex_home=None, now=None):
    """Codex 最近一次记下的额度（rollout 里 token_count 事件带的 rate_limits）"""
    now = now or _now_ms()
    best = None
    for path in _codex_latest_rollouts(codex_home or os.environ.get("CODEX_HOME") or os.path.join(HOME, ".codex")):
        try:
            with open(path, "rb") as handle:
                handle.seek(0, os.SEEK_END)
                handle.seek(max(0, handle.tell() - 512 * 1024))
                lines = handle.read().decode("utf-8", "replace").splitlines()
        except OSError:
            continue
        for line in reversed(lines):
            if '"rate_limits"' not in line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            limits = (row.get("payload") or {}).get("rate_limits") if isinstance(row.get("payload"), dict) else None
            if not isinstance(limits, dict):
                continue
            at = _iso_ms(row.get("timestamp")) or int(os.path.getmtime(path) * 1000)
            if best is None or at > best[0]:
                best = (at, limits)
            break
        if best:
            break   # 文件按修改时间从新到旧，第一个有读数的就是最新的
    if not best or now - best[0] > LIMITS_STALE_MS:
        return None
    at, limits = best
    windows = []
    for slot in ("primary", "secondary"):
        info = limits.get(slot)
        if not isinstance(info, dict) or info.get("used_percent") is None:
            continue
        minutes = int(info.get("window_minutes") or 0)
        resets = _iso_ms(info.get("resets_at")) if info.get("resets_at") is not None else (
            at + int(info["resets_in_seconds"]) * 1000 if info.get("resets_in_seconds") is not None else None)
        window = _limit_window(_CODEX_WINDOWS.get(minutes) or ("window_%d" % minutes), info.get("used_percent"), resets, now)
        if window:
            window["minutes"] = minutes
            windows.append(window)
    return {"agent": "codex", "at": at, "windows": windows, "plan": limits.get("plan_type")} if windows else None


# --- 别家 agent 的 token 用量（AgentPlugin.usage，用量报表用）：按文件签名缓存，一条条请求按（小时, 模型）并好 ---

_PLUGIN_USAGE_CACHE = {}   # 文件 → (签名, 记录)
_USAGE_KEYS = ("input", "output", "cacheRead", "cacheWrite", "requests")


def usage_bucket(buckets, ts, model, values, cost=None, **extra):
    """并进（小时, 模型）这一格：values 依次是输入、输出、读缓存、写缓存、请求数；cost 为 None 表示没有花费数据"""
    key = (ts // 3600000, model)
    bucket = buckets.get(key)
    if bucket is None:
        bucket = buckets[key] = dict({k: 0 for k in _USAGE_KEYS}, ts=key[0] * 3600000, model=model, cost=None, **extra)
    for name, value in zip(_USAGE_KEYS, values):
        bucket[name] += max(0, int(value or 0))
    if cost is not None:
        bucket["cost"] = (bucket["cost"] or 0.0) + float(cost)


def cached_usage(path, scan):
    """文件没变就用上次扫的结果"""
    try:
        stat = os.stat(path)
    except OSError:
        return []
    signature = (stat.st_size, stat.st_mtime)
    hit = _PLUGIN_USAGE_CACHE.get(path)
    if hit and hit[0] == signature:
        return hit[1]
    records = scan(path)
    _PLUGIN_USAGE_CACHE[path] = (signature, records)
    return records


def recent_files(folders, suffix, since_ms):
    """这些目录（含子目录）里 since_ms 之后改过的文件"""
    out = []
    for folder in folders:
        for base, _, names in os.walk(folder):
            for name in names:
                if name.endswith(suffix):
                    path = os.path.join(base, name)
                    try:
                        if os.path.getmtime(path) * 1000 >= since_ms:
                            out.append(path)
                    except OSError:
                        pass
    return out


def codex_usage_scan(path):
    """一份 Codex 记录：token_count 事件带这一份到此为止的累计值（total_token_usage），逐次相减就是每次请求的用量——
    同样的事件 Codex 会重复记（只更新额度时），差为 0 的跳过；第一条、累计值变小的（续接别的会话）用它自己那次（last_token_usage）。
    Codex 的输入含缓存（cached_input_tokens），拆开记"""
    buckets, model, cwd, session, last = {}, None, None, None, None
    try:
        handle = open(path, "rb")
    except OSError:
        return []
    with handle:
        for raw in handle:
            if b'"token_count"' not in raw and b'"turn_context"' not in raw and b'"session_meta"' not in raw:
                continue
            entry = parse_line(raw)
            payload = (entry or {}).get("payload")
            if not isinstance(payload, dict):
                continue
            if entry.get("type") == "session_meta":
                cwd, session = payload.get("cwd") or cwd, payload.get("id") or session
                continue
            if entry.get("type") == "turn_context":
                model, cwd = payload.get("model") or model, payload.get("cwd") or cwd
                continue
            info = payload.get("info") if payload.get("type") == "token_count" else None
            total = info.get("total_token_usage") if isinstance(info, dict) else None
            if not isinstance(total, dict):
                continue
            keys = ("input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens")
            if last is not None and all(int(total.get(k) or 0) >= int(last.get(k) or 0) for k in keys):
                step = {k: int(total.get(k) or 0) - int(last.get(k) or 0) for k in keys}
            else:
                step = info.get("last_token_usage") if isinstance(info.get("last_token_usage"), dict) else total
            last = total
            ts = parse_ts(entry.get("timestamp"))
            if ts is None or not any(int(step.get(k) or 0) for k in keys):
                continue
            cached = int(step.get("cached_input_tokens") or 0)
            usage_bucket(buckets, ts, model or "unknown",
                          (int(step.get("input_tokens") or 0) - cached, step.get("output_tokens"), cached,
                           step.get("cache_write_input_tokens"), 1), cwd=cwd, session=session)
    return list(buckets.values())


def codex_token_usage(since_ms, codex_home=None):
    home = codex_home or os.environ.get("CODEX_HOME") or os.path.join(HOME, ".codex")
    out = []
    for path in recent_files([os.path.join(home, "sessions"), os.path.join(home, "archived_sessions")], ".jsonl", since_ms):
        if os.path.basename(path).startswith("rollout-"):
            out.extend(r for r in cached_usage(path, codex_usage_scan) if r["ts"] + 3600000 > since_ms)
    return out


def claude_limits_pending(sessions, root=None):
    """还没有读数，而开着的 Claude Code 会话全是额度插件装上之前启动的（插件只在会话启动时加载）：
    卡片上提示「新开一个会话回复后显示」。有插件装上之后开的会话还是没读数，多半没用订阅登录，就不提示了"""
    try:
        installed = os.path.getmtime(os.path.join(root or claude_config_dir(), "skills", LIMITS_MOD_NAME, "hooks", "register.ts")) * 1000
    except OSError:
        return False
    live = [s for s in sessions or [] if (s.get("agent") or "claude-code") == "claude-code"]
    return bool(live) and all((s.get("startedAt") or 0) < installed for s in live)


def read_limits(sessions=None, plugins=None):
    """这台电脑上各家 agent 的额度（电脑端 limits 请求）；sessions：正在跑的会话（看要不要提示新开会话）；
    plugins：AgentPlugins，问各插件的 limits()（DeepSeek Harness 的余额、外部插件的）"""
    now = _now_ms()
    agents = []
    for reader in (claude_limits, codex_limits):
        try:
            item = reader(now=now)
        except Exception as exc:
            log("读额度出错：%r" % exc)
            item = None
        if item:
            agents.append(item)
        elif reader is claude_limits and claude_limits_pending(sessions):
            agents.append({"agent": "claude-code", "at": 0, "windows": [], "pending": True})
    if plugins is not None:
        agents.extend(plugins.limits())
    return {"agents": agents, "now": now}


# ---------------------------------------------------------------------------
# 正在跑的会话表：守护进程每次快照有变就写一份（各家 agent 都在里面），agent 在 Bash 里调 send-image / todo 这些子命令时，
# 靠它认出自己是哪个会话（Claude Code 有会话注册表，别家没有）
# ---------------------------------------------------------------------------

LIVE_SESSIONS_FILE = os.path.join(DATA_DIR, "live-sessions.json")
_BUSY = ("busy", "working", "running")


def write_live_sessions(snapshots, last=[None]):
    """有变化才写（内容和上次一样就不动文件）"""
    rows = [{"sessionId": s.get("sessionId"), "agent": s.get("agent") or "claude-code", "pid": s.get("pid"),
             "cwd": s.get("cwd"), "name": s.get("title") or s.get("name"),
             "busy": (s.get("activity") in _BUSY) or (s.get("status") in _BUSY), "updatedAt": s.get("updatedAt")}
            for s in snapshots if s.get("sessionId")]
    if rows == last[0]:
        return
    last[0] = rows
    text = json.dumps({"at": int(time.time() * 1000), "pid": os.getpid(), "sessions": rows}, ensure_ascii=False)
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
        with open(LIVE_SESSIONS_FILE + ".tmp", "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(LIVE_SESSIONS_FILE + ".tmp", LIVE_SESSIONS_FILE)
    except OSError:
        pass


def find_calling_session():
    """子命令在 agent 的 Bash 里执行时，认出是哪个会话 → {sessionId, name, agent}；认不出返回 None。
    先看 Claude Code 的会话注册表（父进程链里有它的进程）；再看守护进程写的会话表：父进程链里有某个会话的进程就是它，
    否则在当前目录里找正在干活的会话（agent 跑命令时会话一定在忙），找不到再退回最近活跃的"""
    payload = resolve_calling_session(pid_only=True)
    if payload:
        return {"sessionId": payload["sessionId"], "name": payload.get("name"), "agent": "claude-code"}
    try:
        table = json.loads(read_text(LIVE_SESSIONS_FILE) or "{}")
    except ValueError:
        table = {}
    rows = [r for r in table.get("sessions") or [] if isinstance(r, dict) and r.get("sessionId")]
    chain = set(ancestors(os.getpid()))
    for row in rows:
        if isinstance(row.get("pid"), int) and row["pid"] in chain:
            return row
    cwd = os.path.realpath(os.getcwd())

    def inside(row):
        root = row.get("cwd")
        if not isinstance(root, str) or not root:
            return False
        root = os.path.realpath(root)
        return cwd == root or cwd.startswith(root.rstrip(os.sep) + os.sep)

    here = [r for r in rows if inside(r)]
    here.sort(key=lambda r: (bool(r.get("busy")), len(r.get("cwd") or ""), r.get("updatedAt") or 0), reverse=True)
    if here:
        return here[0]
    payload = resolve_calling_session()
    if payload:
        return {"sessionId": payload["sessionId"], "name": payload.get("name"), "agent": "claude-code"}
    return None


def target_session(session_id):
    """子命令要发到哪个会话：给了 --session 就用它，否则认调用它的会话。→ (会话 id, 显示名)；认不出打印原因返回 (None, None)"""
    if session_id:
        if not _SID_RE.match(session_id):
            print("会话 id 不对：%s" % session_id, file=sys.stderr)
            return None, None
        return session_id, None
    found = find_calling_session()
    if not found:
        print("找不到当前所在的会话（Kiteline 在这台电脑上运行着吗？），可以用 --session <会话id> 指定。", file=sys.stderr)
        return None, None
    return found["sessionId"], found.get("name")


def append_outbox(session_id, entry):
    os.makedirs(OUTBOX_DIR, exist_ok=True)
    entry = dict(entry, ts=int(time.time() * 1000))
    with open(outbox_path(session_id), "a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry, ensure_ascii=False) + "\n")


_TODO_STATUS = {"pending": "待处理", "doing": "进行中", "done": "已完成"}
_TODO_REF_RE = re.compile(r"^t-[0-9a-f]{6}$")
# 电脑端推来的「agent 的待办」：各台电脑、各会话记的合在一起，用户在手机上勾掉、删掉的也算数（见 Watcher.handle 的 todos 请求）
HOST_TODOS_FILE = os.path.join(DATA_DIR, "agent-todos.json")


def save_host_todos(items):
    """电脑端推来的 agent 待办存一份：todo 子命令在 agent 的 Bash 里跑，从这里看到别的会话、别的电脑上记的（列出、接手、关掉）。
    一行 = {ref, text, status, progress, detail?, key（在处理 / 记下它的会话）, title, machine, at}"""
    rows = [item for item in items or [] if isinstance(item, dict) and _TODO_REF_RE.match(str(item.get("ref") or ""))]
    text = json.dumps({"at": _now_ms(), "items": rows}, ensure_ascii=False)
    os.makedirs(DATA_DIR, exist_ok=True)
    with open(HOST_TODOS_FILE + ".tmp", "w", encoding="utf-8") as handle:
        handle.write(text)
    os.replace(HOST_TODOS_FILE + ".tmp", HOST_TODOS_FILE)
    return len(rows)


def _host_todos():
    """电脑端推来的那份 → ({编号: 行}, 推来的时间)；没推过（老版本电脑端）→ ({}, 0)"""
    try:
        with open(HOST_TODOS_FILE, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return {}, 0
    rows = {}
    for item in data.get("items") or []:
        if not isinstance(item, dict) or not item.get("ref"):
            continue
        key = str(item.get("key") or "")
        rows[item["ref"]] = {"text": item.get("text") or "", "detail": item.get("detail") or "", "status": item.get("status") or "pending",
                             "progress": item.get("progress") or "", "session": key.split("#", 1)[-1], "title": item.get("title") or "",
                             "machine": item.get("machine") or "", "ts": item.get("at") or 0}
    return rows, data.get("at") or 0


def _todo_ledger():
    """agent 记的「自己的待办」→ {编号: {text, detail, status, progress, session, ts, title?, machine?}}。
    以电脑端推来的那份为准；这台电脑上刚记的、刚更新还没传过去的，按各会话的发图通道补上"""
    entries = []
    try:
        names = sorted(n for n in os.listdir(OUTBOX_DIR) if n.endswith(".jsonl"))
    except OSError:
        names = []
    for name in names:
        try:
            with open(os.path.join(OUTBOX_DIR, name), "rb") as handle:
                for raw in handle:
                    entry = parse_line(raw)
                    if isinstance(entry, dict) and entry.get("ref") and entry.get("kind") in ("todo", "todo_update") and not entry.get("forUser"):
                        entries.append((entry.get("ts") or 0, name[:-len(".jsonl")], entry))
        except OSError:
            continue
    local = {}
    # 按时间先后合：记在一个会话、在另一个会话里更新的，最后更新它的会话才是在处理的
    for ts, sid, entry in sorted(entries, key=lambda e: e[0]):
        if entry["kind"] == "todo":
            local.setdefault(entry["ref"], {"status": "pending", "progress": "", "session": sid, "ts": ts}).update(
                text=entry.get("text") or "", detail=entry.get("detail") or "")
        else:
            row = local.setdefault(entry["ref"], {"text": entry.get("title") or "", "detail": "", "progress": ""})
            row.update(status=entry.get("status") or "doing", session=sid, progress=entry.get("progress") or row.get("progress") or "", ts=ts)
    ledger, pushed_at = _host_todos()
    for ref, row in local.items():
        known = ledger.get(ref)
        if known is None:
            # 电脑端那份里没有：刚记的还没传过去，补上；比那份早得多的是用户删掉了
            if not pushed_at or (row.get("ts") or 0) > pushed_at - 120000:
                ledger[ref] = row
        elif (row.get("ts") or 0) > (known.get("ts") or 0):
            ledger[ref] = dict(known, status=row.get("status") or known["status"], progress=row.get("progress") or known["progress"],
                               session=row.get("session") or known["session"], ts=row["ts"])
    return ledger


def _calling_session_quiet():
    """调子命令的是哪个会话（认不出就 None，不打印）"""
    try:
        found = find_calling_session()
    except Exception:  # noqa
        return None
    return (found or {}).get("sessionId")


def _bigrams(text):
    text = re.sub(r"\s+", "", str(text or "").lower())
    return {text[i:i + 2] for i in range(len(text) - 1)}


def _similar_todos(text, ledger, skip=None, limit=3):
    """没做完的待办里标题相近的（按两字片段重合算，中英文都行）→ [(编号, 行)]"""
    mine = _bigrams(text)
    scored = []
    for ref, row in ledger.items():
        if ref == skip or row.get("status") == "done":
            continue
        other = _bigrams(row.get("text"))
        if mine and other:
            score = len(mine & other) / float(len(mine | other))
            if score >= 0.3:
                scored.append((score, ref, row))
    scored.sort(key=lambda s: s[0], reverse=True)
    return [(ref, row) for _, ref, row in scored[:limit]]


def _todo_line(ref, row, me=None):
    holder = "本会话" if me and row.get("session") == me else \
        "会话「%s」" % row["title"] if row.get("title") else "会话 %s" % (row.get("session") or "?")[:8]
    if row.get("machine") and holder != "本会话":
        holder += " · " + row["machine"]
    return "%s  [%s]  %s%s  （%s）" % (ref, _TODO_STATUS.get(row.get("status"), row.get("status")), row.get("text"),
                                     "：" + row["progress"] if row.get("progress") else "", holder)


STAGE_NUDGE_MS = 10 * 60 * 1000   # 规划过的任务多久没报就在发图、记待办时提醒一句
STAGE_PLAN_NUDGE_MS = 3 * 60 * 1000   # 没规划却已经动手这么久：经 kiteline-stages mod 提醒它规划
STAGE_NUDGE_GAP_MS = 3 * 60 * 1000    # 两次提醒之间至少隔这么久
STAGE_ACTS = {"research": "查资料", "dev": "改代码", "test": "测试", "report": "汇报、发布"}


def stage_nudge(session_id):
    """发图、发报告、记待办之后顺带提一句：这个会话规划了任务，却很久没报做到哪一步了（认不出的步骤不推断，不报列表就停着）"""
    if not session_id:
        return
    try:
        state = _read_json(os.path.join(STAGE_DIR, "%s.json" % session_id), {})
        now = int(time.time() * 1000)
        if not stage_plan_active(state, now):
            return
        marks = state.get("marks") or []
        last = max([state.get("plan") or 0] + [m.get("ts") or 0 for m in marks if isinstance(m, dict)])
        if now - last < STAGE_NUDGE_MS:
            return
        steps = state.get("steps") or STAGE_DEFAULT
        step = (marks[-1].get("step") if marks and isinstance(marks[-1], dict) else None) or 1
        print("\n任务进展：列表上这个会话还停在第 %d/%d 步「%s」（%d 分钟前报的）。已经进入别的步骤就报一下：%s stage <第几步> --note \"在做什么\"；"
              "做完了用 stage done。" % (step, len(steps), steps[min(step, len(steps)) - 1], (now - last) // 60000, self_command()))
    except Exception:  # noqa  提醒而已
        pass


def todo_nudge(session_id):
    """发图、发报告（shot / report 也走发图）、记待办、更新待办之后顺带提一句：这个会话还有没关的待办。
    agent 常常事情做完了却忘了 todo done，用户那边「agent 的待办」越堆越多（10-27）"""
    if not session_id:
        return
    try:
        rows = [(ref, row) for ref, row in _todo_ledger().items() if row.get("status") != "done" and row.get("session") == session_id]
    except Exception:  # noqa  提醒而已，出错不影响发图
        return
    if not rows:
        return
    rows.sort(key=lambda item: item[1].get("ts") or 0)
    print("\n这个会话名下还有 %d 条没关的待办：" % len(rows))
    for ref, row in rows[:6]:
        print("  %s  [%s]  %s" % (ref, _TODO_STATUS.get(row.get("status"), row.get("status")), (row.get("text") or "")[:60]))
    if len(rows) > 6:
        print("  …共 %d 条，todo list 看全部" % len(rows))
    print("已经做完的现在就关掉：%s todo done <编号> \"结果\"；不用做了也用 done 写明原因；还在做的不用管。" % self_command())


def command_todo(argv):
    """待办（待办与关键信息技能用）：
    todo "标题" [--detail 说明]            记一条 agent 自己以后要做的事，打印编号（t-xxxxxx）
    todo start|progress|done <编号> [说明]  更新待办：开始做 / 进度 / 做完或不用做了（别的会话记的也能接手、关掉）
    todo list [--all]                       agent 记的待办：这个会话的在前，也有别的会话、别的电脑上记的（默认不列做完的）
    todo --user "标题" [--detail 说明]      只有用户能做的事：提醒用户，用户可以现在处理或加入他的待办"""
    if argv and argv[0] in ("start", "progress", "done"):
        return _todo_update(argv[0], argv[1:])
    if argv and argv[0] == "list":
        ledger = _todo_ledger()
        me = _calling_session_quiet()
        rows = sorted(((ref, row) for ref, row in ledger.items() if "--all" in argv or row.get("status") != "done"),
                      key=lambda item: (item[1].get("session") != me, item[1].get("ts") or 0))
        if not rows:
            print("没有未完成的待办" if "--all" not in argv else "还没有 agent 记的待办")
            return 0
        for ref, row in rows:
            print(_todo_line(ref, row, me))
            if row.get("detail") and row.get("status") != "done":
                print("    " + row["detail"].replace("\n", "\n    "))
        print("\n做完的用 todo done <编号> \"结果\" 关掉（别的会话记的、你做掉了也一样关）；不用做了也用 done 写明原因。")
        return 0
    text, detail, session, for_user = None, "", None, False
    index = 0
    while index < len(argv):
        arg = argv[index]
        value = argv[index + 1] if index + 1 < len(argv) else None
        if arg in ("--detail", "-d") and value is not None:
            detail = value; index += 2; continue
        if arg == "--session" and value is not None:
            session = value; index += 2; continue
        if arg == "--user":
            for_user = True; index += 1; continue
        if arg in ("-h", "--help"):
            print(command_todo.__doc__)
            return 0
        text = arg if text is None else text + " " + arg
        index += 1
    text = (text or "").strip()
    if not text:
        print("没有待办内容。用法：ccpulse-watch.py todo \"要做的事\" [--detail 说明] [--user]", file=sys.stderr)
        return 2
    session_id, name = target_session(session)
    if not session_id:
        return 3
    # 编号只给 agent 自己的待办（它用编号更新进度）；提醒用户的那条由用户处理，不用编号
    ref = "" if for_user else "t-" + uuid.uuid4().hex[:6]
    append_outbox(session_id, {"kind": "todo", "ref": ref, "text": text[:500], "detail": detail.strip()[:4000], "forUser": for_user})
    if for_user:
        print("已提醒用户：%s（会话 %s）。用户可以现在处理，或加入他的待办稍后处理；处理好后他会回到这个会话告诉你。" % (text[:60], name or session_id[:8]))
        return 0
    print("已记下你自己的待办，编号 %s：%s（会话 %s）。开始做、有进展时用 todo start / progress %s 更新，做完或不用做了一定要 todo done %s 关掉。"
          % (ref, text[:60], name or session_id[:8], ref, ref))
    similar = _similar_todos(text, _todo_ledger(), skip=ref)
    if similar:
        # 同一件事别的会话（或者这个会话早先）记过了：别留两条
        print("\n已有相近的待办，是同一件事的话把刚记的 %s done 掉（写「重复」），接着用原来那条（todo start <编号> 接手）：" % ref)
        for other, row in similar:
            print("  " + _todo_line(other, row, session_id))
    return 0


def _todo_update(action, argv):
    session, rest = None, []
    index = 0
    while index < len(argv):
        if argv[index] == "--session" and index + 1 < len(argv):
            session = argv[index + 1]
            index += 2
            continue
        rest.append(argv[index])
        index += 1
    if not rest or not _TODO_REF_RE.match(rest[0]):
        print("用法：ccpulse-watch.py todo %s <编号 t-xxxxxx> [说明]（编号见记待办时的输出，或 todo list）" % action, file=sys.stderr)
        return 2
    ref, note = rest[0], " ".join(rest[1:]).strip()
    if action == "progress" and not note:
        print("进度说明不能为空", file=sys.stderr)
        return 2
    row = _todo_ledger().get(ref)
    if row is None:
        # 编号写错了、或是用户已经删掉了：不往对话里写一条对不上号的进度
        print("找不到待办 %s：编号不对，或者用户已经删掉了。用 todo list --all 查看编号" % ref, file=sys.stderr)
        return 4
    title = row.get("text") or ""
    session_id, name = target_session(session)
    if not session_id:
        return 3
    status = "done" if action == "done" else "doing"
    # 写进当前会话的发图通道：电脑端按编号改那一条（别的会话、别的电脑上记的也行），在处理的会话记成这一个
    append_outbox(session_id, {"kind": "todo_update", "ref": ref, "status": status, "progress": note[:1000], "title": title[:500]})
    print("已更新待办 %s「%s」：%s%s（会话 %s）" % (ref, title[:40] or "?", _TODO_STATUS[status], "，" + note[:60] if note else "", name or session_id[:8]))
    todo_nudge(session_id)
    stage_nudge(session_id)
    return 0


def command_keyinfo(argv):
    """agent 把以后要用的关键信息（账号密码、密钥、地址）发给用户，可收藏"""
    title, note, session, fields = None, "", None, []
    index = 0
    while index < len(argv):
        arg = argv[index]
        value = argv[index + 1] if index + 1 < len(argv) else None
        if arg in ("--field", "--secret") and value is not None:
            name, sep, content = value.partition("=")
            if not sep:
                name, content = "", value
            fields.append({"name": name.strip()[:60], "value": content.strip()[:2000], "secret": arg == "--secret"})
            index += 2
            continue
        if arg == "--note" and value is not None:
            note = value; index += 2; continue
        if arg == "--session" and value is not None:
            session = value; index += 2; continue
        if arg in ("-h", "--help"):
            print(__doc__.split("子命令（给智能体用）:")[1].strip())
            return 0
        title = arg if title is None else title + " " + arg
        index += 1
    title = (title or "").strip()
    if not title or not (fields or note.strip()):
        print("用法：ccpulse-watch.py keyinfo \"标题\" --field \"名称=值\" [--secret \"密码=值\"] [--note 说明]", file=sys.stderr)
        return 2
    session_id, name = target_session(session)
    if not session_id:
        return 3
    append_outbox(session_id, {"kind": "key", "title": title[:200], "fields": fields[:20], "note": note.strip()[:2000]})
    print("已把关键信息「%s」发到用户手机（会话 %s），他可以一键收藏" % (title[:60], name or session_id[:8]))
    return 0


# ---------------------------------------------------------------------------
# 会话群：用户在 Kiteline 里把几个会话（可以在不同电脑、不同项目）拉进一个群，它们经 Kiteline 互相发消息。
#   agent 用 group say 发言：写进这个会话的发图通道（kind=group），电脑端收到后投递给群里其他会话；
#   群成员、最近的群消息由电脑端推来（{"cmd":"groups"}），存在 ~/.ccpulse/groups.json 给 group info / say 核对用。
# ---------------------------------------------------------------------------

HOST_GROUPS_FILE = os.path.join(DATA_DIR, "groups.json")
GROUP_TEXT_MAX = 8000


def save_host_groups(items):
    """电脑端推来的会话群存一份（整份换掉）。一个群 = {id, name, autoName, topic?, paused?, members:[{key, sessionId, title, machine, project, live}], recent:[…]}"""
    rows = [item for item in items or [] if isinstance(item, dict) and item.get("id")]
    os.makedirs(DATA_DIR, exist_ok=True)
    with open(HOST_GROUPS_FILE + ".tmp", "w", encoding="utf-8") as handle:
        handle.write(json.dumps({"at": _now_ms(), "items": rows}, ensure_ascii=False))
    os.replace(HOST_GROUPS_FILE + ".tmp", HOST_GROUPS_FILE)
    return len(rows)


def _host_groups():
    """电脑端推来的那份 → (群列表, 推来的时间)；没推过（老版本电脑端）→ ([], 0)"""
    try:
        with open(HOST_GROUPS_FILE, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return [], 0
    return [g for g in data.get("items") or [] if isinstance(g, dict)], data.get("at") or 0


def _my_groups(session_id):
    """这个会话在的群（还在群里的）"""
    return [g for g in _host_groups()[0]
            if any(isinstance(m, dict) and m.get("sessionId") == session_id for m in g.get("members") or [])]


def _group_member_label(member):
    where = " · ".join(x for x in (member.get("machine"), member.get("project")) if x)
    return "%s（%s）" % (member.get("title") or "会话", where) if where else (member.get("title") or "会话")


def _pick_group(groups, wanted):
    """--group 写的是群编号或群名（含一部分也行）"""
    if not wanted:
        return groups[0] if len(groups) == 1 else None
    wanted = wanted.strip()
    for group in groups:
        if group.get("id") == wanted or group.get("name") == wanted:
            return group
    hits = [g for g in groups if wanted in (g.get("name") or "")]
    return hits[0] if len(hits) == 1 else None


def _match_members(group, names, me):
    """--to 写的名字 → 成员 key：会话标题、项目、电脑名、会话 id 开头都认；认不出的原样返回给调用方报错"""
    members = [m for m in group.get("members") or [] if isinstance(m, dict) and m.get("sessionId") != me]
    keys, unknown = [], []
    for name in names:
        low = name.strip().lower()
        hits = [m for m in members if low and (low in (m.get("title") or "").lower() or low == (m.get("project") or "").lower()
                                               or low == (m.get("machine") or "").lower() or (m.get("sessionId") or "").startswith(low))]
        if len(hits) == 1:
            keys.append(hits[0].get("key"))
        else:
            unknown.append(name)
    return keys, unknown


def _print_group(group, me, recent=8):
    print("会话群「%s」（%s）%s" % (group.get("name") or "未命名", group.get("id"), "　转发已暂停（等用户点继续）" if group.get("paused") else ""))
    if group.get("topic"):
        print("用户说明：%s" % group["topic"])
    print("成员：")
    for member in group.get("members") or []:
        if not isinstance(member, dict):
            continue
        tag = "你" if member.get("sessionId") == me else ("运行中" if member.get("live") else "已关闭（用户在群里发消息时会恢复）")
        print("  · %s　%s" % (_group_member_label(member), tag))
    rows = [r for r in group.get("recent") or [] if isinstance(r, dict)][-recent:]
    if rows:
        print("最近的群消息：")
        for row in rows:
            when = time.strftime("%m-%d %H:%M", time.localtime((row.get("ts") or 0) / 1000.0))
            text = re.sub(r"\s+", " ", str(row.get("text") or ""))
            print("  [%s] %s：%s" % (when, row.get("fromTitle") or "?", text[:300] + ("…" if len(text) > 300 else "")))


def command_group(argv):
    """会话群（用户在 Kiteline 里把几个会话拉进一个群，它们可以在不同电脑、不同项目里）：
    group say "内容" [--to 成员] [--group 群] [--name 群名]   发群消息：默认发给群里其他所有会话，--to 只发给某一个（可写多次）；
                                                          内容写 - 从标准输入读（长内容、带引号的内容）
    group info [--group 群]                                  群成员和最近的群消息
    group list                                               这个会话在哪些群里"""
    action = argv[0] if argv else "info"
    rest = argv[1:] if argv else []
    if action in ("-h", "--help", "help"):
        print(command_group.__doc__)
        return 0
    text, wanted, name, session, to = None, None, None, None, []
    index = 0
    while index < len(rest):
        arg = rest[index]
        value = rest[index + 1] if index + 1 < len(rest) else None
        if arg == "--group" and value is not None:
            wanted = value; index += 2; continue
        if arg == "--name" and value is not None:
            name = value; index += 2; continue
        if arg == "--to" and value is not None:
            to.append(value); index += 2; continue
        if arg == "--session" and value is not None:
            session = value; index += 2; continue
        text = arg if text is None else text + " " + arg
        index += 1
    session_id, label = target_session(session)
    if not session_id:
        return 3
    groups = _my_groups(session_id)
    _, pushed_at = _host_groups()

    if action == "list":
        if not groups:
            print("这个会话不在任何会话群里（用户在 Kiteline 里拉群后才有）")
            return 0
        for group in groups:
            others = [m for m in group.get("members") or [] if isinstance(m, dict) and m.get("sessionId") != session_id]
            print("「%s」（%s）：和 %s" % (group.get("name") or "未命名", group.get("id"), "、".join(_group_member_label(m) for m in others) or "（只剩你）"))
        return 0

    if action == "info":
        if not groups:
            print("这个会话不在任何会话群里（用户在 Kiteline 里拉群后才有）")
            return 0
        picked = _pick_group(groups, wanted)
        for group in [picked] if picked else groups:
            _print_group(group, session_id)
            print()
        print("发群消息：%s group say \"内容\"（只发给某一个加 --to 名字）" % self_command())
        return 0

    if action != "say":
        print("不认识的操作：%s。用法：\n%s" % (action, command_group.__doc__), file=sys.stderr)
        return 2
    if text == "-":
        text = sys.stdin.read()
    text = (text or "").strip()
    if not text:
        print("没有消息内容。用法：%s group say \"内容\" [--to 成员]" % self_command(), file=sys.stderr)
        return 2
    if len(text) > GROUP_TEXT_MAX:
        print("内容太长（%d 字，上限 %d）：写成文件放在对方能读到的地方，群里只发路径和要点" % (len(text), GROUP_TEXT_MAX), file=sys.stderr)
        return 2
    group = None
    if pushed_at:
        # 电脑端推过群名单：先在这里核对，发错了当场告诉 agent
        if not groups:
            print("这个会话不在任何会话群里，消息没有发出（用户在 Kiteline 里拉群后才能发）", file=sys.stderr)
            return 4
        group = _pick_group(groups, wanted)
        if group is None:
            print("这个会话在不止一个群里（或 --group 对不上），请用 --group 指定：", file=sys.stderr)
            for g in groups:
                print("  --group %s　「%s」" % (g.get("id"), g.get("name") or "未命名"), file=sys.stderr)
            return 4
        if to:
            keys, unknown = _match_members(group, to, session_id)
            if unknown:
                print("群里找不到这些成员（或不止一个对得上）：%s。成员：" % "、".join(unknown), file=sys.stderr)
                for m in group.get("members") or []:
                    if isinstance(m, dict) and m.get("sessionId") != session_id:
                        print("  · %s" % _group_member_label(m), file=sys.stderr)
                return 4
            to = keys
    entry = {"kind": "group", "text": text, "group": (group or {}).get("id") or wanted or ""}
    if to:
        entry["to"] = to
    if name and name.strip():
        entry["name"] = name.strip()[:40]
    append_outbox(session_id, entry)
    if group is None:
        print("已发到会话群（会话 %s）" % (label or session_id[:8]))
        return 0
    others = [m for m in group.get("members") or [] if isinstance(m, dict) and m.get("sessionId") != session_id
              and (not to or m.get("key") in to)]
    closed = [m for m in others if not m.get("live")]
    print("已发到群「%s」：%s 会收到%s" % (entry.get("name") or group.get("name") or "未命名", "、".join(m.get("title") or "会话" for m in others) or "（没有其他成员）",
                                       "（%s 已关闭，用户在群里发消息恢复它时会一并看到）" % "、".join(m.get("title") or "会话" for m in closed) if closed else ""))
    if group.get("paused"):
        print("注意：这个群的转发已暂停（往来太多条，等用户在 Kiteline 里点继续），消息先记在群里，暂时不会投递。")
    return 0


# ---------------------------------------------------------------------------
# 任务阶段：会话列表里「正在工作」前的「2/4 开发中」、对话页上的任务进展
#   agent 用 stage 子命令自己报（任务阶段技能），记在 ~/.ccpulse/stage/<会话>.json；没报的按这一轮的工具调用推断：
#   读代码、搜索 → 调研了解；改文件、编译 → 开发中；跑测试、截图核对 → 测试中；发图发报告 → 汇报中，提交推送、安装部署 → 发布中。
#   流程可以按用户和 agent 的约定改（stage --steps "调研了解,方案设计,开发中,测试中,发布中"）：这个会话照它显示，
#   也记成这个项目以后的流程（~/.ccpulse/stage-flows.json），推断时按步骤名认出每一步属于哪一类。
#   一轮 = 用户发一句话（或空闲的会话被别的会话、定时任务叫醒）到 agent 停下；只在忙、等确认时给快照带 stage。
#   推断只在这一轮动手改过东西（改文件、编译）以后才显示：问问题、查资料就答完的不挂阶段（10-31）
# ---------------------------------------------------------------------------

STAGE_DIR = os.path.join(DATA_DIR, "stage")
STAGE_FLOWS_FILE = os.path.join(DATA_DIR, "stage-flows.json")
STAGE_KINDS = ("research", "dev", "test", "report")
STAGE_DEFAULT = ["调研了解", "开发中", "测试中", "汇报中"]
STAGE_MAX_STEPS = 9
# 自定的步骤名属于哪一类（先认汇报、测试：「提交测试」「修复验证」算后面那步）；认不出的那步只有 agent 自己报才走得到
STAGE_WORDS = (
    ("report", re.compile(r"汇报|发布|部署|上线|交付|提交|总结|安装|上架|报告|report|releas|deploy|ship|publish|deliver", re.I)),
    ("test", re.compile(r"测试|实测|验证|验收|自测|回归|核对|test|verif|qa\b|check", re.I)),
    ("dev", re.compile(r"开发|实现|编码|编写|修改|修复|重构|改|做|dev|implement|cod|build|fix|refactor", re.I)),
    ("research", re.compile(r"调研|了解|分析|研究|排查|定位|复现|摸清|摸底|梳理|诊断|阅读|规划|设计|方案|需求|research|investigat|plan|design|explor|analy|read", re.I)),
)
_STAGE_READ_TOOLS = {"read", "grep", "glob", "ls", "websearch", "webfetch", "toolsearch", "notebookread", "enterplanmode"}
_STAGE_EDIT_TOOLS = {"edit", "write", "multiedit", "notebookedit", "apply_patch", "patch", "str_replace_editor"}
_STAGE_SELF = re.compile(r"ccpulse-watch\.py\s+(send-image|send-page|report|keyinfo|shot|e2e-setup)\b")
_STAGE_REPORTED = re.compile(r"ccpulse-watch\.py[\"']?\s+stage\b")
# 每一段命令开头的「外壳」：ssh 主机、sudo、timeout、环境变量……去掉后看真正跑的是什么
_STAGE_WRAP = re.compile(r"^\s*(?:ssh\s+(?:-[bcDEeFIiJLlmOopQRSWw]\s*\S+\s+|-\w+\s+)*\S+\s+)?"
                         r"(?:sudo\s+|time\s+|nohup\s+|exec\s+|timeout\s+\S+\s+|env\s+|[A-Z_][A-Z0-9_]*=\S*\s+)*")
# 用解释器跑脚本：bash x.sh、/usr/bin/python3 x.py、./x.sh
_STAGE_RUN = r"(?:(?:\S*/)?(?:bash|sh|zsh|python[\d.]*|pwsh|powershell(?:\.exe)?|node)\s+(?:-\S+\s+)*)?"
# 以下都只认一段命令的开头：grep 里搜「git push」、cat release.sh、release.py --help 这类只读的不算
_STAGE_RELEASE = re.compile(
    r"^(?:git\s+(?:-C\s+\S+\s+)?(?:push|commit|tag)\b|"
    + _STAGE_RUN + r"\S*?(?:install|release|publish|deploy|upload)[\w.-]*\.(?:sh|py|ps1)\b(?!\s+(?:-h|--help|help|history|plan)\b)|"
    + _STAGE_RUN + r"\S*build\.sh\s+device\b|"
    r"(?:npm|pnpm|yarn|cargo|gem|poetry)\s+publish\b|twine\s+upload\b|docker\s+push\b|kubectl\s+(?:apply|rollout)\b|"
    r"helm\s+(?:install|upgrade)\b|(?:xcrun\s+)?devicectl\s+device\s+install\b|gh\s+(?:release\s+create|pr\s+create)\b|"
    r"(?:firebase|fly|wrangler)\s+deploy\b|fastlane\b|xcrun\s+(?:notarytool|altool)\b)")
_STAGE_TEST = re.compile(
    r"^(?:(?:npx\s+)?(?:playwright|lighthouse)\b|curl\b.*(?:localhost|127\.0\.0\.1)|(?:xcrun\s+)?(?:simctl|xctrace)\b|"
    + _STAGE_RUN + r"\S*(?:snapshot|cap|shot|e2e|smoke|check|verify)[\w.-]*\.(?:sh|py|js|mjs|ts)\b|\S*\s.*--render\b)")
_STAGE_BUILD = re.compile(
    r"^(?:" + _STAGE_RUN + r"\S*build\.sh\b|(?:make|cmake|(?:xcrun\s+)?swiftc|(?:npx\s+)?tsc|xcodebuild|ninja)(?=\s|$)|swift\s+build\b|"
    r"cargo\s+(?:build|check|clippy)\b|go\s+(?:build|vet)\b|(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?(?:build|lint|typecheck)\b|"
    r"\S*gradlew?\b.*\b(?:assemble|build)\w*|\S*dotnet\s+build\b|mvn\s+(?:compile|package)\b|"
    r"sed\s+-i|perl\s+-p?i|git\s+(?:apply|am|merge|rebase|cherry-pick|restore)\b|patch\s+-p)")
# heredoc 里的脚本在写文件（agent 常用 python - <<EOF 改代码）、cat > 文件 <<EOF
_STAGE_WRITES = re.compile(r"\.write\(|write_text\(|os\.replace\(|json\.dump\(|^\s*cat\s+>\s*\S+|\btee\s+\S+\s*<<", re.M)


def stage_word_kind(label):
    """步骤名 → research / dev / test / report；认不出 None"""
    for kind, pattern in STAGE_WORDS:
        if pattern.search(label or ""):
            return kind
    return None


def stage_command_kind(command):
    """一条 Bash 命令属于哪一步 → (类, 细分)：细分只给第 4 步分「汇报」「发布」；看不出来 (None, None)。
    命令拆成段（; && || | 换行），几段里取最靠后的那一步（编译完接着跑测试算测试）"""
    command = command or ""
    head = command_head(command)
    found = _STAGE_SELF.search(head)
    if found:
        return ("test", None) if found.group(1) in ("shot", "e2e-setup") else ("report", "report")
    segments = [_STAGE_WRAP.sub("", seg, count=1) for seg in re.split(r"[;\n|&()]+", head.replace("'", " ").replace('"', " "))]
    segments = [seg for seg in segments if seg.strip()]
    if any(_STAGE_RELEASE.search(seg) for seg in segments):
        return "report", "release"
    if is_test_command(command) or any(_STAGE_TEST.search(seg) for seg in segments):   # 它自己去掉 heredoc，别交已经去掉的（再去一遍会吞掉后面的命令）
        return "test", None
    if any(_STAGE_BUILD.search(seg) for seg in segments) or ("<<" in command and _STAGE_WRITES.search(command)):
        return "dev", None
    return None, None


# 派给子 agent 的活看描述里最先出现的动词：「实测查重」测试、「帮助文档改为……」开发、「查一下测试为什么挂」调研
_STAGE_TASK_WORDS = (
    ("test", re.compile(r"实测|测试|测一下|自测|验证|验收|回归|核对|截图|试跑|跑通|e2e|test|verif|\bqa\b|playwright", re.I)),
    ("report", re.compile(r"发布|发版|部署|上线|上架|推送|release|deploy|publish|\bship", re.I)),
    ("dev", re.compile(r"改|实现|开发|修复|编写|写|重构|补上|加上|新增|更新|迁移|implement|fix|refactor|write|add\b|update|migrat|build", re.I)),
    ("research", re.compile(r"查|调研|研究|分析|排查|定位|梳理|搜索|找|看看|了解|摸清|review|research|investigat|explor|search|find|look|analy|audit|read", re.I)),
)


def stage_task_kind(description):
    """子 agent 的描述 → 类；认不出 None"""
    best = None
    for kind, pattern in _STAGE_TASK_WORDS:
        found = pattern.search(description or "")
        if found and (best is None or found.start() < best[0]):
            best = (found.start(), kind)
    return best[1] if best else None


# agent 写给用户的说明（「后端改完，接下来实测」）→ 它说要进入哪一类：一个按字词打分的小模型（线性，约 6000 个字词权重，压缩后 68 KB，
# 纯 Python），用 2500 句真实说明人工标注训练（tools/stage-model/）。整体准确率约 68%、有把握（≥0.8）时约 81%，会把阶段判得偏后，
# 不够直接定列表上的阶段：只用来判断「它说要进下一步了却没报」，经 kiteline-stages mod 提醒它自己报（StageTracker._nudge_text）
STAGE_SAID_PROB = 0.8
_STAGE_TEXT_KINDS = ("research", "dev", "test", "report", None)
_stage_text_model = []
_STAGE_CJK = re.compile(r"[\u4e00-\u9fff]+")
_STAGE_LATIN = re.compile(r"[a-z][a-z_\-]+")


def stage_text_features(text):
    """字词特征：中文 1～3 字片段、英文单词和相邻两词；第一小句、最后一小句的另记一份（「接下来做什么」常在最后）"""
    text = re.sub(r"\d+", "0", re.sub(r"`[^`]*`", " ", (text or "").lower()))[:300]
    clauses = [c for c in re.split(r"[。！？!?\n；;：:]|\.\s", text) if c.strip()]
    out = []

    def grams(part, tag):
        for run in _STAGE_CJK.findall(part):
            for n in (1, 2, 3):
                out.extend(tag + run[i:i + n] for i in range(len(run) - n + 1))
        words = _STAGE_LATIN.findall(part)
        out.extend(tag + w for w in words)
        out.extend(tag + a + " " + b for a, b in zip(words, words[1:]))
    grams(text, "")
    if clauses:
        grams(clauses[-1], "E|")
        grams(clauses[0], "B|")
    return out


def stage_text_kind(text):
    """一句说明 → (类, 把握)：类 None 是看不出来；模型坏了 (None, 0)"""
    if not _stage_text_model:
        try:
            data = json.loads(zlib.decompress(base64.b64decode("".join(_STAGE_TEXT_MODEL))).decode("utf-8"))
            _stage_text_model.append((data["w"], data["b"]))
        except Exception as exc:  # noqa  模型只是用来提醒
            log("任务阶段模型读不出来：%r" % exc)
            _stage_text_model.append(({}, [0] * 5))
    weights, bias = _stage_text_model[0]
    scores = list(bias)
    for feature in set(stage_text_features(text)):
        row = weights.get(feature)
        if row:
            scores = [a + b for a, b in zip(scores, row)]
    top = max(scores)
    exps = [math.exp((x - top) / 100.0) for x in scores]
    best = max(range(len(exps)), key=lambda i: exps[i])
    return _STAGE_TEXT_KINDS[best], exps[best] / sum(exps)


def stage_hint(name, tool_input):
    """太长的命令给手机时会截断，后半截（常是跑测试、提交）就认不出了：截断前先按完整命令认好，记在条目的 _sk 里，
    StageTracker.feed 取走它（不发给手机）。不长的不带"""
    if (name or "").lower() != "bash" or not isinstance(tool_input, dict):
        return {}
    command = tool_input.get("command")
    if not isinstance(command, str) or len(command) <= TOOL_INPUT_STRING_MAX:
        return {}
    return {"_sk": list(stage_command_kind(command))}


def stage_tool_kind(name, tool_input, cwd=None):
    """一次工具调用属于哪一步 → (类, 细分)。只认有把握的：TodoWrite、提问、发消息这类看不出阶段的 (None, None)。
    cwd 是会话的项目目录：在它里面改文件一律算开发"""
    tool_input = tool_input if isinstance(tool_input, dict) else {}
    low = (name or "").lower()
    if low == "bash":
        return stage_command_kind(tool_input.get("command") if isinstance(tool_input.get("command"), str) else "")
    if low in _STAGE_EDIT_TOOLS:
        path = str(tool_input.get("file_path") or tool_input.get("path") or "")
        inside = bool(cwd) and path.startswith(cwd.rstrip("/\\") + os.sep)
        # 项目外往临时目录、草稿区写的是查东西时的草稿，不算动手开发
        if not inside and re.search(r"(?:^|[/\\])(?:tmp|Temp|scratchpad)(?:[/\\]|$)|^/private/var/", path):
            return None, None
        return "dev", None
    if low in _STAGE_READ_TOOLS:
        return "research", None
    if low in ("agent", "task"):
        kind = str(tool_input.get("subagent_type") or "").lower()
        if kind in ("explore", "plan", "claude-code-guide"):
            return "research", None
        # 通用子 agent 按派给它的活认（11-01：改完代码派子 agent 在后台做浏览器实测，列表还停在「开发中」）
        kind = stage_task_kind(str(tool_input.get("description") or ""))
        return kind, ("release" if kind == "report" else None)
    if low == "skill":
        skill = str(tool_input.get("skill") or tool_input.get("name") or "").lower()
        if "release" in skill or "deploy" in skill:
            return "report", "release"
        if "screenshot" in skill:
            return "report", "report"
        if any(word in skill for word in ("playwright", "test", "review", "verify", "run")):
            return "test", None
        return None, None
    if low in ("artifact", "pushnotification"):
        return "report", "report"
    if low.startswith("mcp__") and any(word in low for word in ("playwright", "browser", "chrome", "puppeteer")):
        return "test", None
    return None, None


def stage_steps_arg(text):
    """--steps / --parts 的值 → 名字列表（逗号、顿号、竖线、箭头分隔；斜杠不拆，「Windows/Linux」是一部分）；
    default / 默认 → []（默认四步）；不合格 None"""
    text = (text or "").strip()
    if text.lower() in ("default", "默认", "reset"):
        return []
    steps = [s.strip()[:16] for s in re.split(r"\s*(?:,|，|、|\||->|→)\s*", text) if s.strip()]
    return steps if 2 <= len(steps) <= STAGE_MAX_STEPS else None


def _read_json(path, fallback):
    try:
        data = json.loads(read_text(path) or "null")
    except ValueError:
        data = None
    return data if isinstance(data, type(fallback)) else fallback


def _write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".tmp", "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False)
    os.replace(path + ".tmp", path)


STAGE_PLAN_TTL_MS = 12 * 3600 * 1000   # 规划过的任务这么久没再报就不算了（忘了 stage done 的）


def stage_plan_active(state, now):
    """agent 规划过（--steps / --parts）、还没做完的任务：跨轮保留，用户中途说「继续」不从头算"""
    plan = state.get("plan")
    if not isinstance(plan, (int, float)) or now - max(plan, state.get("ts") or 0) > STAGE_PLAN_TTL_MS:
        return False
    parts = stage_parts(state)
    return not parts or not all(p["done"] for p in parts)


def stage_parts(state):
    """任务分的几部分（几个端）：[{name, step, done}]；没分返回 []"""
    out = []
    for p in state.get("parts") or []:
        if isinstance(p, dict) and isinstance(p.get("name"), str) and p["name"]:
            out.append({"name": p["name"][:16], "step": p.get("step") if isinstance(p.get("step"), int) else 0, "done": bool(p.get("done"))})
    return out if len(out) >= 2 else []


def stage_current_part(state, parts):
    """正在做哪部分：最近报的那部分；还没报过就是第一个没做完的"""
    names = [p["name"] for p in parts]
    if state.get("part") in names:
        return state["part"]
    return next((p["name"] for p in parts if not p["done"]), names[0])


class StageTracker:
    """每个会话这一轮做到第几步：agent 报的优先，没报的按工具调用推断（见上）。
    推断只进不退：测出问题回去改代码仍算「测试中」（10-31 反馈：在测试和开发之间来回跳，进度就没意义了）。
    agent 报过以后忘了报下一步（11-01 反馈：都开始改代码了，还停在「定位」）：动作正好是紧挨着的下一步才往前跟一步"""

    def __init__(self):
        self.turns = {}       # 会话 -> 这一轮的推断：{turn 开始, kind, flavor, back, backN, marks [(类, 时间, 细分)]}
        self.activity = {}    # 会话 -> 上一次看到的忙闲
        self.idle_since = {}  # 会话 -> 从什么时候起空闲（判断「空闲 → 忙」是不是已经由用户那句话开了新的一轮）
        self.cwds = {}        # 会话 -> 项目目录（在里面改文件算开发）
        self.trail = {}       # 会话 -> 动作的类按时间排（连着同一类的只记头一个）：[(类, 时间, 细分)]，类 None 是 agent 报了一步
        self.nudged = {}      # 会话 -> (上一次留的提醒, 时间)
        self.said = {}        # 会话 -> (agent 最近一次说要进入的类, 时间)：说明文字小模型认的，只拿来提醒
        self.nudge_dir = None # 提醒写到哪（测试用）；None 时任务阶段技能开着才写，写到 <Claude 配置目录>/kiteline/stage
        self.files = {}       # 路径 -> (mtime, 内容)：agent 报的阶段、项目流程，文件没变不重读

    def _load(self, path, fallback):
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            self.files.pop(path, None)
            return fallback
        cached = self.files.get(path)
        if cached and cached[0] == mtime:
            return cached[1]
        data = _read_json(path, fallback)
        self.files[path] = (mtime, data)
        return data

    def new_turn(self, sid, ts):
        self.turns[sid] = {"turn": ts, "kind": "research", "flavor": None, "marks": [("research", ts, None)], "worked": False}

    def feed(self, sid, items):
        for item in items:
            ts = item.get("ts") or int(time.time() * 1000)
            if item.get("t") == "user" and not item.get("queued"):
                self.new_turn(sid, ts)
            elif item.get("t") == "tool":
                hint = item.pop("_sk", None)
                command = (item.get("input") or {}).get("command") if (item.get("name") or "").lower() == "bash" and isinstance(item.get("input"), dict) else None
                if isinstance(command, str) and _STAGE_REPORTED.search(command):
                    self._trail(sid, None, ts, None)   # 报了一步：报之前就在改代码、报完接着改的，那次改动也要记得到
                    continue
                kind, flavor = hint if isinstance(hint, list) and len(hint) == 2 else \
                    stage_tool_kind(item.get("name"), item.get("input"), self.cwds.get(sid))
                if kind:
                    self.step(sid, kind, flavor, ts)
            elif item.get("t") == "text" and item.get("text"):
                kind, sure = stage_text_kind(item["text"])
                if kind in ("dev", "test", "report") and sure >= STAGE_SAID_PROB:
                    self.said[sid] = (kind, ts)

    def _trail(self, sid, kind, ts, flavor):
        trail = self.trail.setdefault(sid, [])
        if not trail or trail[-1][0] != kind or trail[-1][2] != flavor:
            trail.append((kind, ts, flavor))
            del trail[:-60]

    def step(self, sid, kind, flavor, ts):
        self._trail(sid, kind, ts, flavor)
        turn = self.turns.get(sid)
        if turn is None:
            self.new_turn(sid, ts)
            turn = self.turns[sid]
        if kind == "dev" and not turn["worked"]:
            turn["worked"] = ts   # 这一轮从什么时候起动手改东西：推断的阶段这才显示（见 view），久了没规划提醒它（_nudge_text）
        rank, current = STAGE_KINDS.index(kind), STAGE_KINDS.index(turn["kind"])
        if rank == current:
            if kind == "report" and flavor and flavor != turn["flavor"]:
                turn["flavor"] = flavor
                turn["marks"].append((kind, ts, flavor))
            return
        if rank < current:
            return   # 只进不退：后面的阶段里再读代码、改代码是这一步的一部分（测出问题回去改仍算测试）
        turn.update(kind=kind, flavor=flavor if kind == "report" else None)
        turn["marks"] = (turn["marks"] + [(kind, ts, turn["flavor"])])[-24:]

    def bootstrap(self, sid, path, normalize=None):
        """watcher 刚起来、会话已经在跑：从对话记录末尾最近一句用户的话起补算这一轮"""
        try:
            items, _, _ = read_history(path, None, 400, normalize)
        except Exception:  # noqa  补算而已
            return
        start = 0
        for index in range(len(items) - 1, -1, -1):
            if items[index].get("t") == "user" and not items[index].get("queued"):
                start = index
                break
        self.feed(sid, items[start:])

    def declared(self, sid):
        """agent 用 stage 报的：{steps, parts: [{name, step, done}], part, plan, doneAt, marks: [{step, ts, label, note, part}]}"""
        return self._load(os.path.join(STAGE_DIR, "%s.json" % sid), {})

    def view(self, sid, cwd):
        """快照里的 stage：{step, total, label, steps, kinds, since, turnAt, note, auto, marks: [[第几步, 时间]], part, parts}；
        不知道返回 None。part / parts 只在 agent 把任务分了几部分（几个端）时有：step 这些说的是正在做的那部分"""
        turn = self.turns.get(sid)
        state = self.declared(sid)
        now = int(time.time() * 1000)
        active = stage_plan_active(state, now)
        steps = state.get("steps") if active else None
        steps = [str(s)[:16] for s in steps] if isinstance(steps, list) and 2 <= len(steps) <= STAGE_MAX_STEPS else None
        # agent 自己定的步骤（「主机与 watcher」「Mac 和 iPhone 界面」这类）按名字猜不准是哪一类：以它报的为准，不整段推断，
        # 只在报过以后往认得出的下一步跟（见 _next_step）。10-31 一个会话规划了 7 步却没报，推断把「改代码」套到「设计方案」上，
        # 在 2/7 和 6/7 之间来回跳
        guess = steps is None or steps == STAGE_DEFAULT
        kinds = list(STAGE_KINDS) if guess else [stage_word_kind(s) for s in steps]
        steps = steps or list(STAGE_DEFAULT)
        parts = stage_parts(state) if active else []
        part = stage_current_part(state, parts) if parts else None
        turn_at = turn["turn"] if turn else None
        # 规划过的任务跨轮保留（用户中途说「继续」不从第 1 步重算）；没规划的只算这一轮报的
        since_floor = state.get("plan") if active else max(turn_at - 2000 if turn_at else 0, state.get("doneAt") or 0)
        declared = [m for m in state.get("marks") or [] if isinstance(m, dict) and isinstance(m.get("step"), int)
                    and 1 <= m["step"] <= len(steps) and (m.get("ts") or 0) >= (since_floor or 0)]
        if parts:
            # 分了几部分：只看正在做的这部分最近一次接手以来报的，推断也只算接手以后的（之前那段是在做别的部分）
            run, last = [], state.get("plan") or 0
            for mark in declared:
                run = run + [mark] if mark.get("part") == part else []
                last = mark.get("ts") or last
            auto_floor = run[0].get("ts") or 0 if run else last
            declared = run
        else:
            declared = [m for m in declared if not m.get("part")]
            auto_floor = 0
        if active and not declared:
            # 规划了还没报到哪一步：从第 1 步开始（分了部分的，接着这部分上次报到的那步）
            stored = next((p["step"] for p in parts if p["name"] == part), 0) if parts else 0
            declared = [{"step": max(1, min(stored, len(steps))), "ts": auto_floor or state.get("plan") or now, "implicit": True}]
        if not declared and not parts and not (turn and turn.get("worked")):
            # 没报过、这一轮也还没动手改东西（问个问题、查点资料、跑条命令就答完的）：不显示阶段，免得一句话的回答也挂着「1/4 调研了解」
            return None
        events = []
        if turn and guess:
            for kind, ts, flavor in turn["marks"]:
                index = self._index_of(kind, kinds)
                if index is not None and ts >= auto_floor:
                    events.append((ts, 0, index, flavor, None, None))
        for mark in declared:
            events.append((mark.get("ts") or 0, 1, mark["step"] - 1, None, mark.get("label"), mark.get("note")))
        if declared:
            # agent 报过以后的动作（跨轮的也算：规划过的任务用户说「继续」接着做）：忘了报下一步时拿来往前跟
            for kind, ts, flavor in self.trail.get(sid) or []:
                if kind and ts >= auto_floor:
                    events.append((ts, 2, kind, flavor, None, None))
        if not events:
            return None
        events.sort(key=lambda e: (e[0], e[1]))
        current, label, note, flavor, by_agent, inferred, marks = None, None, None, None, False, False, []
        for ts, source, index, mark_flavor, mark_label, mark_note in events:
            if source == 1:
                by_agent, inferred = True, False
                label, note, flavor = mark_label, mark_note, None
            elif source == 2:
                if not by_agent:
                    continue
                kind, index = index, self._next_step(index, current, kinds)
                if index is None:
                    if kind == "report" and kinds[current] == "report" and mark_flavor:
                        flavor = mark_flavor   # 报了「汇报中」以后提交推送：「发布中」
                    continue
                label, note, flavor, inferred = None, None, mark_flavor, True   # 报的说明是上一步的，跟上以后不再挂着
            else:
                if by_agent:
                    continue   # 报过以后只按上面一步一步跟，不按这一轮整段推断
                if index != current:
                    label, note = None, None
                flavor = mark_flavor
            if index != current:
                marks.append([index + 1, ts])
                current = index
        name = label or steps[current]
        if not label and kinds[current] == "report" and steps[current] in ("汇报中", "发布中"):
            name = "发布中" if flavor == "release" else "汇报中"
        out = {"step": current + 1, "total": len(steps), "label": name, "steps": steps, "kinds": kinds,
               "since": marks[-1][1] if marks else turn_at, "turnAt": (state.get("plan") if active else None) or turn_at,
               "note": note or None, "auto": not by_agent or inferred, "marks": marks[-12:]}
        if parts:
            out["part"] = part
            out["parts"] = [{"name": p["name"], "step": current + 1 if p["name"] == part else p["step"], "done": p["done"]} for p in parts]
        reported = max([m.get("ts") or 0 for m in declared if not m.get("implicit")] + [state.get("plan") or 0 if active else 0])
        nudge = self._nudge_text(sid, turn, out, kinds, by_agent, inferred, active, reported, part, now)
        if nudge:
            out["_nudge"] = nudge
        return out

    def _nudge_text(self, sid, turn, out, kinds, by_agent, inferred, active, reported, part, now):
        """agent 该报却没报时给它的一句提醒 → (同一件事的标识, 文字)；不用提醒 None。三种：
        推断替它跟到了下一步（请它确认、补上说明）；规划过的任务很久没报、手上的活已经换了一类；没规划却已经动手好几分钟"""
        n, total, cmd = out["step"], out["total"], self_command()
        part_arg = " --part %s" % part if part else ""
        if by_agent and inferred:
            return ("inf:%s:%d" % (part or "", n), "看你已经在%s了，列表自动跟到了第 %d/%d 步「%s」。是这一步就报一下、带上在做什么：%s stage %d%s --note \"…\"；"
                    "不是就报实际在第几步。" % (STAGE_ACTS.get(kinds[n - 1], "做下一步"), n, total, out["label"], cmd, n, part_arg))
        said = self.said.get(sid)
        if by_agent and said and said[1] > reported and said[0] != kinds[n - 1] \
                and (kinds[n - 1] is None or STAGE_KINDS.index(said[0]) > STAGE_KINDS.index(kinds[n - 1])):
            return ("said:%s:%d:%s" % (part or "", n, said[0]), "你说接下来要%s，列表上还是第 %d/%d 步「%s」。进入下一步了就报：%s stage <第几步>%s --note \"…\"。"
                    % (STAGE_ACTS[said[0]], n, total, out["label"], cmd, part_arg))
        if by_agent and active and reported and now - reported > STAGE_NUDGE_MS:
            moved = [k for k, ts, _ in self.trail.get(sid) or [] if k and k != "research" and k != kinds[n - 1] and ts > reported]
            if moved:
                return ("stale:%s:%d:%d" % (part or "", n, reported), "列表上你还停在第 %d/%d 步「%s」（%d 分钟前报的），最近在%s。进入下一步了就报：%s stage <第几步>%s --note \"…\"；"
                        "全部做完 stage done。" % (n, total, out["label"], (now - reported) // 60000, STAGE_ACTS[moved[-1]], cmd, part_arg))
            return None
        if not by_agent and turn and turn.get("worked"):
            started = turn["worked"]   # 先跑了测试再改代码的，marks 里没有「开发」（只进不退），从动手那刻算
            if now - started > STAGE_PLAN_NUDGE_MS:
                return ("plan:%d" % turn["turn"], "这次任务已经动手 %d 分钟了，还没规划步骤（用户在手机上看每个会话做到哪一步）。按任务阶段技能规划：%s stage --steps \"步骤1,步骤2,…\"，"
                        "之后每进入一步报一次；马上就做完的可以不管。" % ((now - started) // 60000, cmd))
        return None

    def nudge(self, sid, nudge, now):
        """把提醒留给 kiteline-stages mod（STAGE_MOD_FILES）：同一件事只留一次，两次之间至少隔 STAGE_NUDGE_GAP_MS"""
        folder = self.nudge_dir
        if folder is None:
            skills = skills_enabled()
            if not skills or "stages" not in skills:
                return
            folder = os.path.join(claude_config_dir(), "kiteline", "stage")
        key, text = nudge
        last = self.nudged.get(sid)
        if last is None:
            # watcher 刚起来：文件里还是同一件事就不再留（重启前留过）
            old = _read_json(os.path.join(folder, "%s.json" % sid), {})
            last = (str(old.get("id") or "").split("@")[0], old.get("at") or 0)
        if last[0] == key or now - last[1] < STAGE_NUDGE_GAP_MS:
            return
        self.nudged[sid] = (key, now)
        try:
            _write_json(os.path.join(folder, "%s.json" % sid), {"id": "%s@%d" % (key, now), "text": "（Kiteline 任务进展）" + text, "at": now})
        except OSError as exc:
            log("写任务阶段提醒失败：%s" % exc)

    @staticmethod
    def _next_step(kind, current, kinds):
        """agent 报到第 current 步（从 0 数）以后看到一个动作（改代码 dev、跑测试 test、发图提交 report）→ 跟到第几步；不跟 None。
        只跟紧挨着的下一步，而且那一步正好是这一类；中间认作调研的步骤可以跨过（动手改了就是查完了）：
        跑测试不会越过还没做的「iPhone 端」跳到「验证」，「开发后端」里改代码不会挪到「开发前端」，读代码哪一步都会有、不跟"""
        if kind == "research" or kinds[current] == kind:
            return None
        nxt = current + 1
        while nxt < len(kinds) and kinds[nxt] == "research":
            nxt += 1
        return nxt if nxt < len(kinds) and kinds[nxt] == kind else None

    @staticmethod
    def _index_of(kind, kinds):
        """推断的类 → 流程里第几步（从 0 数）：有这一类的取第一步；没有就落在它前面最近的那类上"""
        if kind in kinds:
            return kinds.index(kind)
        rank = STAGE_KINDS.index(kind)
        best = None
        for index, other in enumerate(kinds):
            if other is not None and STAGE_KINDS.index(other) <= rank:
                best = index
        return best

    def annotate(self, snapshots):
        now = int(time.time() * 1000)
        live = set()
        for snap in snapshots:
            sid = snap.get("sessionId")
            if not sid:
                continue
            live.add(sid)
            self.cwds[sid] = snap.get("cwd") or ""
            activity = snap.get("activity")
            before = self.activity.get(sid)
            self.activity[sid] = activity
            if activity == "idle":
                self.idle_since.setdefault(sid, now)
            elif before == "idle":
                # 空闲 → 忙：新的一轮（别的会话发来的消息、定时任务叫醒的也算）。用户那句话已经先到、开过新一轮的不重来
                since = self.idle_since.pop(sid, now)
                turn = self.turns.get(sid)
                if turn is None or turn["turn"] < since - 2000:
                    self.new_turn(sid, now)
            else:
                self.idle_since.pop(sid, None)
            if activity in ("busy", "waiting"):
                try:
                    stage = self.view(sid, snap.get("cwd") or "")
                except Exception as exc:  # noqa  阶段只是锦上添花，算错了也不能拖垮快照
                    log("stage %s: %r" % (sid[:8], exc))
                    stage = None
                if stage:
                    nudge = stage.pop("_nudge", None)
                    if nudge and snap.get("agent") in (None, "", "claude-code"):   # 只有 Claude Code 装得上提醒 mod
                        self.nudge(sid, nudge, now)
                    snap["stage"] = stage
        for table in (self.turns, self.activity, self.idle_since, self.cwds, self.trail, self.nudged, self.said):
            for sid in [s for s in table if s not in live]:
                del table[sid]


STAGES = StageTracker()


def _session_cwd(session_id):
    table = _read_json(LIVE_SESSIONS_FILE, {})
    for row in table.get("sessions") or []:
        if isinstance(row, dict) and row.get("sessionId") == session_id:
            return row.get("cwd") or ""
    return ""


def _stage_flow_text(steps):
    return " → ".join("%d %s" % (i + 1, step) for i, step in enumerate(steps))


def _stage_match_part(text, parts):
    """--part 的值 → 部分名（不分大小写；写了前几个字也认）；认不出 None"""
    low = (text or "").strip().lower()
    for p in parts:
        if p["name"].lower() == low:
            return p["name"]
    hits = [p["name"] for p in parts if low and (p["name"].lower().startswith(low) or low in p["name"].lower())]
    return hits[0] if len(hits) == 1 else None


def command_stage(argv):
    """任务阶段（任务阶段技能用）。步骤按这次任务实际怎么做来定，不必是固定的四步：
    stage --steps "复现,定位,修复,验证,汇报"   开始一个任务：规划这次的步骤（跨轮保留，用户说「继续」也不从头算）
    stage --steps default                     这次按默认四步：调研了解 / 开发中 / 测试中 / 汇报中（发布中）
    stage --parts "Mac,iPhone,Windows/Linux"  任务分几部分（几个端）：每部分各走一遍步骤
    stage <第几步或步骤名> [--part 部分] [--note 在做什么]   报做到哪一步（分了部分的，--part 说是哪部分；省略就是正在做的那部分）
    stage done [--part 部分 | --all]           这部分做完了；没分部分、或 --all：整个任务做完
    stage show                                看现在的规划、做到哪
    --remember：把这次的 --steps 记成这个项目的默认流程（用户和你约定的习惯），以后 --steps default 就用它
    规划过的步骤以报的为准：每进入一步都要报；忘了报时只在看得出是下一步（改代码、跑测试、发图、提交）时跟一步，
    认不出的步骤（「iPhone 端」这类）不报列表就停在上一步"""
    step_arg, note, steps_arg, parts_arg, part_arg, session, remember, everything = None, "", None, None, None, None, False, False
    index = 0
    while index < len(argv):
        arg = argv[index]
        value = argv[index + 1] if index + 1 < len(argv) else None
        if arg in ("--note", "-n") and value is not None:
            note = value; index += 2; continue
        if arg == "--steps" and value is not None:
            steps_arg = value; index += 2; continue
        if arg == "--parts" and value is not None:
            parts_arg = value; index += 2; continue
        if arg == "--part" and value is not None:
            part_arg = value; index += 2; continue
        if arg == "--session" and value is not None:
            session = value; index += 2; continue
        if arg == "--remember":
            remember = True; index += 1; continue
        if arg == "--all":
            everything = True; index += 1; continue
        if arg in ("-h", "--help"):
            print(command_stage.__doc__)
            return 0
        step_arg = arg if step_arg is None else step_arg + " " + arg
        index += 1
    if step_arg is None and steps_arg is None and parts_arg is None:
        print("用法：ccpulse-watch.py stage --steps \"步骤1,步骤2,…\" | --parts \"部分1,部分2\" | <第几步> [--part 部分] [--note 在做什么] | done | show",
              file=sys.stderr)
        return 2
    session_id, name = target_session(session)
    if not session_id:
        return 3
    path = os.path.join(STAGE_DIR, "%s.json" % session_id)
    state = _read_json(path, {})
    cwd = _session_cwd(session_id) or os.getcwd()
    flows = _read_json(STAGE_FLOWS_FILE, {})
    now = int(time.time() * 1000)
    who = name or session_id[:8]
    if steps_arg is not None:
        steps = stage_steps_arg(steps_arg)
        if steps is None:
            print("--steps 要 2～%d 个步骤名，用逗号分开，如 \"复现,定位,修复,验证,汇报\"；默认四步写 --steps default" % STAGE_MAX_STEPS, file=sys.stderr)
            return 2
        if not steps and not remember:
            # default：这个项目记过流程（--remember）就用它，没有就是默认四步
            remembered = flows.get(cwd) if isinstance(flows.get(cwd), dict) else {}
            steps = stage_steps_arg(",".join(remembered.get("steps") or [])) or []
        # 新任务：换掉上一个任务的规划（几部分也清掉，要分的话同一条命令里带 --parts）
        state.update(steps=steps or None, plan=now, marks=[], doneAt=None)
        state.pop("parts", None)
        state.pop("part", None)
        if remember:
            if steps:
                flows[cwd] = {"steps": steps, "ts": now}
            else:
                flows.pop(cwd, None)
            _write_json(STAGE_FLOWS_FILE, flows)
    steps = (state.get("steps") if stage_plan_active(state, now) else None) or STAGE_DEFAULT
    if parts_arg is not None:
        names = [] if parts_arg.strip().lower() in ("none", "无", "") else stage_steps_arg(parts_arg)
        if names is None:
            print("--parts 要 2～%d 个部分，用逗号分开，如 \"Mac,iPhone,Windows/Linux\"；不分了写 --parts none" % STAGE_MAX_STEPS, file=sys.stderr)
            return 2
        if names:
            state["parts"] = [{"name": n, "step": 0, "done": False} for n in names]
            state.pop("part", None)
            if not state.get("plan") or steps_arg is None:
                state.update(plan=now, marks=[], doneAt=None)
        else:
            state.pop("parts", None)
            state.pop("part", None)
    parts = stage_parts(state)
    active = stage_plan_active(state, now)
    if step_arg == "show":
        print("这次任务的步骤：%s%s" % (_stage_flow_text(steps), "" if active else "（还没规划，按工具调用自动推断）"))
        if parts:
            current = stage_current_part(state, parts)
            for p in parts:
                print("  %s %s：%s" % ("▶" if p["name"] == current else " ", p["name"],
                                      "已完成" if p["done"] else ("第 %d 步 %s" % (p["step"], steps[p["step"] - 1]) if 1 <= p["step"] <= len(steps) else "还没开始")))
        elif state.get("marks"):
            print("上次报的：第 %s 步" % state["marks"][-1].get("step"))
        return 0
    part = None
    if step_arg is not None and parts:
        if part_arg is not None:
            part = _stage_match_part(part_arg, parts)
            if part is None:
                print("没有「%s」这部分。现在分的是：%s（不对就用 --parts 重新分）" % (part_arg, "、".join(p["name"] for p in parts)), file=sys.stderr)
                return 2
        else:
            part = stage_current_part(state, parts)
    elif part_arg is not None and step_arg is not None and step_arg != "done":
        print("这个任务还没分部分：先 stage --parts \"Mac,iPhone,…\"", file=sys.stderr)
        return 2
    if step_arg == "done":
        if parts and not everything:
            for p in state["parts"]:
                if p.get("name") == part:
                    p.update(step=len(steps), done=True)
            left = [p["name"] for p in stage_parts(state) if not p["done"]]
            if left:
                state["part"] = left[0]
                state["ts"] = now
                _write_json(path, state)
                print("「%s」这部分做完了（会话 %s）。还剩：%s；开始做下一部分时报 stage <第几步> --part %s" % (part, who, "、".join(left), left[0]))
                return 0
        state.update(plan=None, doneAt=now, ts=now)
        _write_json(path, state)
        print("任务做完了（会话 %s）：列表里不再显示这个任务的阶段。下一个任务开始时再 stage --steps 规划。" % who)
        return 0
    if step_arg is not None:
        text = step_arg.strip()
        label = None
        if text.isdigit():
            number = int(text)
        elif text in steps:
            number = steps.index(text) + 1
        else:
            kind = stage_word_kind(text)
            kinds = [stage_word_kind(s) for s in steps]
            number = kinds.index(kind) + 1 if kind in kinds else 0
            if number and steps == STAGE_DEFAULT and kind == "report":
                label = "发布中" if re.search(r"发布|部署|上线|安装|上架|releas|deploy|ship|publish", text, re.I) else "汇报中"
        if not 1 <= number <= len(steps):
            print("认不出「%s」是第几步。这次的步骤：%s（写序号或步骤名；步骤不对就用 --steps 重新规划）"
                  % (text, _stage_flow_text(steps)), file=sys.stderr)
            return 2
        mark = {"step": number, "ts": now}
        if label:
            mark["label"] = label
        if note.strip():
            mark["note"] = note.strip()[:120]
        if part:
            mark["part"] = part
            state["part"] = part
            for p in state["parts"]:
                if p.get("name") == part:
                    p.update(step=number, done=False)
        state["marks"] = ((state.get("marks") or []) + [mark])[-40:]
    state["ts"] = now
    _write_json(path, state)
    if step_arg is None:
        lines = ["已规划这次任务（会话 %s）：%s" % (who, _stage_flow_text(steps))]
        if parts:
            lines.append("分 %d 部分：%s。每部分各走一遍这些步骤，报的时候带 --part，做完一部分 stage done --part <部分>" % (len(parts), "、".join(p["name"] for p in parts)))
        lines.append("列表上现在显示第 1 步「%s」。之后每进入一步都要报（stage 2 --note \"在做什么\"）：只有改代码、跑测试、发图这类"
                     "看得出是下一步的才会自动跟上，别的步骤不报会一直停在上一步；全部做完 stage done。" % steps[0])
        if remember and steps_arg is not None:
            lines.append("已记成这个项目以后的默认流程" if state.get("steps") else "这个项目已恢复默认流程")
        print("\n".join(lines))
        return 0
    shown = mark.get("label") or steps[number - 1]
    print("已报告任务阶段：%s%d/%d %s%s（会话 %s）。用户在会话列表和对话页上能看到；进入下一步时再报一次。"
          % (part + " · " if part else "", number, len(steps), shown, "，" + note.strip()[:40] if note.strip() else "", who))
    return 0


# ---------------------------------------------------------------------------
# 改动报告（git，只读）与测试报告（从 transcript 里认出测试命令和结果）
# ---------------------------------------------------------------------------

def run_git(cwd, args, limit=400000, timeout=20):
    # core.quotePath=false：中文文件名原样输出，不转义成 "\346\226..."
    out = subprocess.run(["git", "-c", "core.quotePath=false", "-C", cwd] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
                         env=dict(os.environ, GIT_PAGER="cat", LC_ALL="C.UTF-8", GIT_OPTIONAL_LOCKS="0"))
    if out.returncode != 0:
        raise RuntimeError(out.stderr.decode("utf-8", "replace").strip().split("\n")[-1] or "git 失败")
    text = out.stdout[:limit].decode("utf-8", "replace")
    return text + ("\n…（输出太长，已截断）" if len(out.stdout) > limit else "")


SLOW_FS_MESSAGE = "读取超时：这个目录可能在网络盘上，或者 macOS 在等你允许 Kiteline 访问（系统设置 → 隐私与安全性 → 文件与文件夹）"


def call_with_timeout(seconds, fn, *args):
    """可能卡住的 git / 文件操作放到后台线程跑：卡住时先回话，不冻住主循环（心跳停了 Mac 会当它死了重启）"""
    box = {}

    def run():
        try:
            box["value"] = fn(*args)
        except BaseException as exc:  # noqa
            box["error"] = exc

    worker = threading.Thread(target=run, daemon=True)
    worker.start()
    worker.join(seconds)
    if worker.is_alive():
        raise RuntimeError(SLOW_FS_MESSAGE)
    if "error" in box:
        if isinstance(box["error"], subprocess.TimeoutExpired):
            raise RuntimeError(SLOW_FS_MESSAGE)
        raise box["error"]
    return box["value"]


def _numstat_path(path):
    """numstat 里的重命名写成「旧 => 新」或「src/{旧 => 新}/a.js」，取新路径，和 status 里的条目对上"""
    if " => " not in path:
        return path
    match = re.match(r"(.*)\{(.*) => (.*)\}(.*)", path)
    if match:
        return re.sub(r"/+", "/", match.group(1) + match.group(3) + match.group(4))
    return path.split(" => ", 1)[1]


def git_status(cwd):
    if not shutil.which("git"):
        return {"repo": None, "reason": "这台机器上没有 git"}
    try:
        root = run_git(cwd, ["rev-parse", "--show-toplevel"]).strip()
    except Exception:
        return {"repo": None, "reason": "不是 git 仓库"}
    porcelain = run_git(root, ["status", "--porcelain=v1", "-b", "--untracked-files=normal"])
    branch, upstream, ahead, behind = None, None, 0, 0
    files = {}
    untracked = []
    for line in porcelain.splitlines():
        if line.startswith("## "):
            head = line[3:]
            match = re.match(r"([^.\s]+)(?:\.\.\.(\S+))?(?: \[(.*)\])?", head)
            if match:
                branch, upstream = match.group(1), match.group(2)
                for part in (match.group(3) or "").split(","):
                    part = part.strip()
                    if part.startswith("ahead "):
                        ahead = int(part[6:])
                    elif part.startswith("behind "):
                        behind = int(part[7:])
            continue
        code, path = line[:2], line[3:]
        if " -> " in path:
            path = path.split(" -> ", 1)[1]
        path = path.strip('"')
        if code == "??":
            untracked.append(path)
        else:
            # 两位状态码（暂存区 + 工作区，如 MM、AM、RM）取有意义的那一位，界面只认单个字母
            files[path] = {"path": path, "status": (code[0] if code[0] not in " ?" else code[1:].strip()) or "M", "add": 0, "del": 0}
    try:
        numstat = run_git(root, ["diff", "--numstat", "HEAD"])
    except Exception:
        numstat = run_git(root, ["diff", "--numstat"])   # 还没有任何提交的仓库
    for line in numstat.splitlines():
        parts = line.split("\t")
        if len(parts) == 3:
            path = _numstat_path(parts[2])
            entry = files.setdefault(path, {"path": path, "status": "M", "add": 0, "del": 0})
            entry["add"] = int(parts[0]) if parts[0].isdigit() else 0
            entry["del"] = int(parts[1]) if parts[1].isdigit() else 0
            entry["binary"] = parts[0] == "-"
    commits = []
    try:
        log = run_git(root, ["log", "-10", "--pretty=format:%h%x09%ct%x09%an%x09%s"])
        for line in log.splitlines():
            parts = line.split("\t", 3)
            if len(parts) == 4:
                commits.append({"hash": parts[0], "ts": int(parts[1]) * 1000, "author": parts[2], "subject": parts[3]})
    except Exception:
        pass
    changed = sorted(files.values(), key=lambda f: f["path"])
    return {
        "repo": root, "branch": branch, "upstream": upstream, "ahead": ahead, "behind": behind,
        "files": changed[:300], "untracked": untracked[:100], "untrackedCount": len(untracked),
        "totalAdd": sum(f["add"] for f in changed), "totalDel": sum(f["del"] for f in changed),
        "commits": commits,
    }


def git_diff(cwd, path=None, commit=None):
    root = run_git(cwd, ["rev-parse", "--show-toplevel"]).strip()
    if commit:
        if not re.match(r"^[0-9a-fA-F]{4,40}$", commit):
            raise RuntimeError("提交号不合法")
        return run_git(root, ["show", "--stat", "--patch", "--format=%H%n%an  %ad%n%n%s%n%n%b", "--date=format:%Y-%m-%d %H:%M", commit])
    if not path or is_abs_path(path) or ".." in path.replace("\\", "/").split("/"):
        raise RuntimeError("路径不合法")
    full = os.path.realpath(os.path.join(root, path))
    if not full.startswith(os.path.realpath(root) + os.sep):
        raise RuntimeError("路径不合法")
    tracked = subprocess.run(["git", "-C", root, "ls-files", "--error-unmatch", "--", path], timeout=10,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if tracked:
        try:
            return run_git(root, ["diff", "HEAD", "--", path])
        except Exception:
            return run_git(root, ["diff", "--", path])
    # 新文件：整个文件当成新增
    try:
        with open(full, "rb") as handle:
            data = handle.read(200000)
    except OSError as exc:
        raise RuntimeError("读不了文件：%s" % exc)
    if b"\x00" in data[:8000]:
        return "（二进制文件）"
    lines = data.decode("utf-8", "replace").split("\n")
    return "新文件 %s\n@@ -0,0 +1,%d @@\n" % (path, len(lines)) + "\n".join("+" + line for line in lines)


TEST_COMMAND = re.compile(
    r"(pytest|\bjest\b|vitest|\bmocha\b|\bgo test\b|cargo test|(npm|pnpm|yarn|bun)( run)? test|swift test|"
    r"xcodebuild[^|;&]*\btest\b|\bmvn\b[^|;&]*\btest\b|gradlew?[^|;&]*\btest\b|phpunit|rspec|unittest|"
    r"playwright test|make test|\btox\b|run-integration|selftest|test_\w+\.py|tests?/[\w./-]+\.(py|sh|js|ts|mjs))")


def command_head(command):
    """去掉 heredoc 正文，只留真正执行的命令行（否则「用 python 改 tests/xx.py」也会被当成测试）"""
    keep, marker = [], None
    for line in command.splitlines():
        if marker is not None:
            if line.strip() == marker:
                marker = None
            continue
        keep.append(line)
        found = re.search(r"<<-?\s*['\"]?(\w+)['\"]?", line)
        if found:
            marker = found.group(1)
    return "\n".join(keep)


TEST_SEGMENT = re.compile(
    r"^\s*(?:sudo\s+)?(?:timeout\s+\S+\s+)?(?:env\s+)?(?:[A-Z_][A-Z0-9_]*=\S*\s+)*(?:"
    r"pytest|py\.test|python3?\s+-m\s+(?:pytest|unittest)|npx\s+(?:jest|vitest|mocha|playwright\s+test)|"
    r"jest|vitest|mocha|go\s+test|cargo\s+(?:test|nextest)|(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?test|swift\s+test|"
    r"xcodebuild\b.*\btest\b|mvn\b.*\btest\b|\.?/?gradlew?\b.*\btest\b|phpunit|vendor/bin/phpunit|rspec|"
    r"make\s+(?:test|check)|tox|nox|ctest|"
    r"(?:bash|sh|zsh)\s+\S*(?:test|selftest|run-integration)\S*|python3?\s+\S*test\S*\.py|\./\S*test\S*)"
    r"(?:\s|$|')")


def is_test_command(command):
    """命令拆成段（; && || | 换行，以及 ssh '…' 里的命令），段首是测试执行程序才算"""
    head = command_head(command).replace("'", " ").replace('"', " ")
    return any(TEST_SEGMENT.search(segment) for segment in re.split(r"[;\n|&]+", head))


def summarize_test_output(text, is_error):
    """尽量从输出里认出通过 / 失败数（pytest、jest/vitest、go、cargo、mocha、本项目的 [PASS]/[FAIL]…）"""
    passed = failed = None
    low = text.lower()
    # jest / vitest 有「测试文件」和「测试用例」两行计数：优先取 Tests 那一行，免得加重
    for line in reversed(low.splitlines()):
        line = line.strip()
        if re.match(r"^tests?:?\s", line) and ("passed" in line or "failed" in line):
            found_pass = re.search(r"(\d+) passed", line)
            found_fail = re.search(r"(\d+) failed", line)
            passed = int(found_pass.group(1)) if found_pass else 0
            failed = int(found_fail.group(1)) if found_fail else 0
            break
    patterns = [] if passed is not None else [
        (r"(\d+) passed", r"(\d+) failed"),                     # pytest / vitest / playwright
        (r"tests:.*?(\d+) passed", r"tests:.*?(\d+) failed"),   # jest
        (r"(\d+) passing", r"(\d+) failing"),                   # mocha
        (r"test result: \w+\. (\d+) passed", r"(\d+) failed;"),  # cargo
        (r"(\d+) 项通过", r"(\d+) 项失败"),                       # 本项目
    ]
    for p_pass, p_fail in patterns:
        found_pass = re.findall(p_pass, low)
        found_fail = re.findall(p_fail, low)
        if found_pass or found_fail:
            passed = sum(int(x) for x in found_pass) if found_pass else 0
            failed = sum(int(x) for x in found_fail) if found_fail else 0
            break
    if passed is None:
        p_lines = len(re.findall(r"\[pass\]|^ok\s|✓|✔", low, re.M))
        f_lines = len(re.findall(r"\[fail\]|^fail\b|^--- fail|✗|✘", low, re.M))
        if p_lines or f_lines:
            passed, failed = p_lines, f_lines
    if failed:
        ok = False
    elif is_error or re.search(r"\b(error|failed|failure|traceback)\b", low) and not passed:
        ok = False
    elif passed:
        ok = True
    else:
        ok = None if not is_error else False
    summary = ""
    for line in reversed(text.strip().splitlines()):
        if re.search(r"pass|fail|ok|error|tests?:|项", line, re.I):
            summary = line.strip()[:160]
            break
    return {"passed": passed, "failed": failed, "ok": ok, "summary": summary}


def find_test_runs(path, limit=40):
    """扫 transcript：Bash 调用里像测试的命令 + 它的结果。只解析相关行，大文件也快。"""
    pending = {}
    runs = []
    try:
        handle = open(path, "rb")
    except OSError:
        return []
    with handle:
        for raw in handle:
            if b'"tool_use"' in raw and b"Bash" in raw:
                entry = parse_line(raw)
                if not entry or entry.get("isSidechain"):
                    continue
                for block in (entry.get("message") or {}).get("content") or []:
                    if isinstance(block, dict) and block.get("type") == "tool_use" and block.get("name") == "Bash":
                        command = str((block.get("input") or {}).get("command") or "")
                        if is_test_command(command):
                            pending[block.get("id")] = {"toolId": block.get("id"), "ts": parse_ts(entry.get("timestamp")),
                                                        "command": command.strip()[:600],
                                                        "description": (block.get("input") or {}).get("description")}
            elif pending and b'"tool_result"' in raw and any(tid.encode() in raw for tid in pending if tid):
                entry = parse_line(raw)
                if not entry:
                    continue
                for block in (entry.get("message") or {}).get("content") or []:
                    if not (isinstance(block, dict) and block.get("type") == "tool_result"):
                        continue
                    run = pending.pop(block.get("tool_use_id"), None)
                    if not run:
                        continue
                    content = block.get("content")
                    if isinstance(content, list):
                        content = "\n".join(c.get("text", "") for c in content if isinstance(c, dict))
                    text = str(content or "")
                    run.update(summarize_test_output(text, bool(block.get("is_error"))))
                    run["output"] = text[-6000:]
                    run["finishedAt"] = parse_ts(entry.get("timestamp"))
                    runs.append(run)
    for run in pending.values():   # 还在跑
        run.update({"ok": None, "running": True, "summary": "运行中…"})
        runs.append(run)
    runs.sort(key=lambda r: r.get("ts") or 0, reverse=True)
    return runs[:limit]


# ---------------------------------------------------------------------------
# 今日动态：某个时间点之后，每个会话做了什么（包括已经关掉的会话）
# ---------------------------------------------------------------------------

_TS_BYTES = re.compile(rb'"timestamp":\s*"([0-9T:.\-]+)Z?"')
EDIT_TOOLS = ("Edit", "MultiEdit", "Write", "NotebookEdit")


def digest_file(path, since_ms, until_ms=None):
    """一个 transcript 在 [since, until) 里的摘要。先用正则读时间戳跳过旧行，只解析今天的行。"""
    prompts = replies = requests = output_tokens = 0
    tools = {}
    files = {}
    conclusions = []
    seen_messages = set()
    first_at = last_at = None
    cwd = None
    try:
        handle = open(path, "rb")
    except OSError:
        return None
    with handle:
        for raw in handle:
            # 真实记录里 timestamp 在 message 后面：带截图的大行要到行尾去找；取最后一个，免得命中正文里的同名字段
            tail = raw[-8000:]
            found = list(_TS_BYTES.finditer(tail))
            match = found[-1] if found else None
            if not match:
                continue
            ts = parse_ts(match.group(1).decode() + "Z")
            if ts is None or ts < since_ms or (until_ms and ts >= until_ms):
                continue
            entry = parse_line(raw)
            if not entry or entry.get("isSidechain"):
                continue
            cwd = entry.get("cwd") or cwd
            for item in normalize_line(0, entry):
                if item["t"] == "user":
                    prompts += 1
                elif item["t"] == "text":
                    replies += 1
                    conclusions.append({"ts": ts, "text": item["text"][:600]})
                    conclusions = conclusions[-3:]
                elif item["t"] == "tool":
                    name = item.get("name") or "tool"
                    tools[name] = tools.get(name, 0) + 1
                    if name in EDIT_TOOLS:
                        target = (item.get("input") or {}).get("file_path") or (item.get("input") or {}).get("notebook_path")
                        if isinstance(target, str):
                            files[target] = files.get(target, 0) + 1
                else:
                    continue
                first_at = first_at or ts
                last_at = ts
            message = entry.get("message") if isinstance(entry.get("message"), dict) else {}
            usage = message.get("usage") if entry.get("type") == "assistant" else None
            if isinstance(usage, dict) and message.get("id") not in seen_messages:
                seen_messages.add(message.get("id"))
                requests += 1
                output_tokens += int(usage.get("output_tokens") or 0)
    if not (prompts or replies or tools):
        return None
    return {
        "prompts": prompts, "replies": replies, "requests": requests, "outputTokens": output_tokens,
        "tools": sorted(({"name": k, "count": v} for k, v in tools.items()), key=lambda t: -t["count"])[:8],
        "files": sorted(({"path": k, "edits": v} for k, v in files.items()), key=lambda f: -f["edits"])[:40],
        "fileCount": len(files), "conclusions": conclusions, "firstAt": first_at, "lastAt": last_at, "cwd": cwd,
    }


def digest_all(since_ms, live, until_ms=None, limit=300):
    """扫 projects 目录下 since 之后改过的 transcript，逐个出摘要。live = {在线会话 id: 工作目录}"""
    found = []
    try:
        projects = os.listdir(PROJECTS_DIR)
    except OSError:
        projects = []
    for project in projects:   # 只看项目目录这一层；子代理的 transcript 在更深的目录里
        folder = os.path.join(PROJECTS_DIR, project)
        try:
            names = os.listdir(folder)
        except OSError:
            continue
        for name in names:
            path = os.path.join(folder, name)
            try:
                if name.endswith(".jsonl") and os.path.getmtime(path) * 1000 >= since_ms:
                    found.append(path)
            except OSError:
                pass
    found.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    sessions = []
    for path in found[:limit]:
        summary = digest_file(path, since_ms, until_ms)
        if not summary:
            continue
        session_id = os.path.basename(path)[:-6]
        summary["cwd"] = summary["cwd"] or live.get(session_id)
        base = (summary["cwd"] or "").rstrip("/")
        for item in summary["files"]:
            if base and item["path"].startswith(base + "/"):
                item["path"] = item["path"][len(base) + 1:]
        runs = [r for r in find_test_runs(path, limit=200)
                if (r.get("ts") or 0) >= since_ms and not (until_ms and (r.get("ts") or 0) >= until_ms)]
        shots = [{"ref": image["ref"], "caption": item["text"], "ts": item["ts"]}
                 for item in read_outbox(session_id, since_ms, until_ms) if item.get("t") == "agent_image"
                 for image in item.get("images") or []]
        summary.update({
            "sessionId": session_id,
            "title": _TITLES.get(session_id) or find_title(path),
            "live": session_id in live,
            "tests": {"runs": len(runs), "passed": sum(1 for r in runs if r.get("ok") is True),
                      "failed": sum(1 for r in runs if r.get("ok") is False),
                      "last": [{k: r.get(k) for k in ("command", "description", "ok", "passed", "failed", "ts")} for r in runs[:3]]},
            "images": len(shots), "shots": shots[-6:],
        })
        sessions.append(summary)
    return sessions


# ---------------------------------------------------------------------------
# 最近的项目：手机上「新任务」选项目用
# ---------------------------------------------------------------------------

_CWD_BYTES = re.compile(rb'"cwd":\s*"((?:[^"\\]|\\.)*)"')


def transcript_cwd(path):
    """transcript 前几十行里找工作目录（每行都带 cwd，取第一个）"""
    try:
        with open(path, "rb") as handle:
            for index, raw in enumerate(handle):
                match = _CWD_BYTES.search(raw[:20000])
                if match:
                    try:
                        return json.loads(b'"' + match.group(1) + b'"')
                    except ValueError:
                        return None
                if index > 60:
                    return None
    except OSError:
        return None
    return None


def list_projects(limit=60, since=None):
    """~/.claude/projects 下每个项目目录取最新的一份对话：工作目录、最后活动时间、标题；
    顺带数这个项目一共几个会话、since（毫秒，默认本机今天 0 点）之后动过几个"""
    if since is None:
        since = time.mktime(time.localtime()[:3] + (0, 0, 0, 0, 0, -1))
    else:
        since = since / 1000.0
    found = []
    try:
        projects = os.listdir(PROJECTS_DIR)
    except OSError:
        return []
    for project in projects:
        folder = os.path.join(PROJECTS_DIR, project)
        newest, newest_mtime, count, recent = None, 0, 0, 0
        try:
            for name in os.listdir(folder):
                if name.endswith(".jsonl"):
                    path = os.path.join(folder, name)
                    mtime = os.path.getmtime(path)
                    count += 1
                    if mtime >= since:
                        recent += 1
                    if mtime > newest_mtime:
                        newest, newest_mtime = path, mtime
        except OSError:
            continue
        if newest:
            found.append((newest_mtime, newest, count, recent))
    found.sort(reverse=True)
    out, seen = [], set()
    for mtime, path, count, recent in found:
        cwd = transcript_cwd(path)
        if not cwd or cwd in seen:
            continue
        seen.add(cwd)
        out.append({"cwd": cwd, "lastActive": int(mtime * 1000), "exists": os.path.isdir(cwd),
                    "title": find_title(path), "sessionId": os.path.basename(path)[:-6],
                    "sessions": count, "today": recent})
        if len(out) >= limit:
            break
    return out


# ---------------------------------------------------------------------------
# 历史会话：列表、搜索、按 id 找对话记录（会话关了也能看）
# ---------------------------------------------------------------------------

_SID_RE = re.compile(r"^[0-9a-fA-F-]{8,64}$")
_META_CACHE = {}   # path -> (size, mtime, meta)


def find_transcript(session_id):
    """按会话 id 在所有项目目录里找对话记录（只认 id 形状的文件名，防路径穿越）"""
    if not isinstance(session_id, str) or not _SID_RE.match(session_id):
        return None
    try:
        projects = os.listdir(PROJECTS_DIR)
    except OSError:
        return None
    for project in projects:
        path = os.path.join(PROJECTS_DIR, project, session_id + ".jsonl")
        if os.path.isfile(path):
            return path
    return None


def tail_title(path, size):
    """标题（ai-title / 改过的名 custom-title）一般在后面：先读最后 512KB，没有再全文找（只对小文件）"""
    try:
        with open(path, "rb") as handle:
            handle.seek(max(0, size - 512 * 1024))
            found = {}
            for raw in handle:
                hit = title_line(raw)
                if hit:
                    found[hit[1]] = hit[0]
            if found:
                return found.get(True) or found.get(False)
    except OSError:
        return None
    return find_title(path) if size < 8 * 1024 * 1024 else None


def first_prompt(path):
    """第一句用户发的话（跳过命令、元信息、工具结果）"""
    try:
        with open(path, "rb") as handle:
            for index, raw in enumerate(handle):
                if index > 200:
                    break
                if b'"type":"user"' not in raw and b'"type": "user"' not in raw:
                    continue
                entry = parse_line(raw)
                if not entry or entry.get("isMeta") or entry.get("isSidechain"):
                    continue
                for item in normalize_line(0, entry):
                    if item["t"] == "user" and item.get("text", "").strip():
                        return item["text"].strip()[:160]
    except OSError:
        return None
    return None


def session_meta(path):
    """一份对话记录的概要（按大小 + 修改时间缓存）"""
    try:
        stat = os.stat(path)
    except OSError:
        return None
    hit = _META_CACHE.get(path)
    if hit and hit[0] == stat.st_size and hit[1] == stat.st_mtime:
        return hit[2]
    meta = {
        "sessionId": os.path.basename(path)[:-6],
        "cwd": transcript_cwd(path),
        "title": tail_title(path, stat.st_size),
        "firstPrompt": first_prompt(path),
        "lastActive": int(stat.st_mtime * 1000),
        "size": stat.st_size,
    }
    _META_CACHE[path] = (stat.st_size, stat.st_mtime, meta)
    return meta


def project_name(cwd):
    """项目名 = 工作目录的最后一级（历史会话按项目筛、按项目名搜都用它）"""
    return os.path.basename((cwd or "").rstrip("/\\")) or (cwd or "")


def list_sessions(limit=80, cwd=None, project=None):
    """所有项目的会话，按最后活动时间倒序；project 给定时只要项目名（目录最后一级）是它的"""
    found = []
    try:
        folders = os.listdir(PROJECTS_DIR)
    except OSError:
        return []
    # Claude Code 存记录的目录名 = 工作目录里字母数字以外的字符都换成「-」：按项目筛时先按目录名排除（太长被截短的目录照常细看）
    suffix = "-" + re.sub(r"[^A-Za-z0-9]", "-", project) if project else None
    for entry in folders:
        if suffix and not entry.endswith(suffix) and len(entry) < 180:
            continue
        folder = os.path.join(PROJECTS_DIR, entry)
        try:
            names = os.listdir(folder)
        except OSError:
            continue
        for name in names:
            if name.endswith(".jsonl") and _SID_RE.match(name[:-6]):
                path = os.path.join(folder, name)
                try:
                    found.append((os.path.getmtime(path), path))
                except OSError:
                    pass
    found.sort(reverse=True)
    out = []
    for _, path in found:
        meta = session_meta(path)
        if not meta or not (meta["firstPrompt"] or meta["title"]):
            continue   # 空会话（打开就关了）不列
        if cwd and meta["cwd"] != cwd:
            continue
        if project and project_name(meta["cwd"]) != project:
            continue
        out.append(meta)
        if len(out) >= limit:
            break
    return out


def search_sessions(query, limit=60, per_session=3, budget=12.0, paths=None):
    """全文搜索所有对话记录里你说的话和 Claude 的回复，返回带片段的命中（按时间倒序）。
    搜全部时，项目名（目录最后一级）或标题里有搜索词的会话也算搜到（match 里写着是哪样，可能没有片段）。
    paths 给定时只搜这几份（对话内搜索）"""
    query = (query or "").strip()
    if len(query) < 1:
        return [], False
    # 不分大小写（只管英文字母，同 bytes.lower）：整份转小写后用子串查找，比忽略大小写的正则快一个数量级
    pattern = query.encode("utf-8").lower()
    folds = pattern != pattern.upper()
    needle = query.lower()
    started = time.time()
    found = []
    try:
        projects = [] if paths else os.listdir(PROJECTS_DIR)
    except OSError:
        return [], False
    for path in paths or []:
        found.append((0, path))
    for project in projects:
        folder = os.path.join(PROJECTS_DIR, project)
        try:
            for name in os.listdir(folder):
                if name.endswith(".jsonl") and _SID_RE.match(name[:-6]):
                    path = os.path.join(folder, name)
                    found.append((os.path.getmtime(path), path))
        except OSError:
            continue
    found.sort(reverse=True)
    max_candidates = 4000 if paths else 400
    results, total, truncated = [], 0, False
    # 先挑项目名对得上的（不读全文、不占时间预算）：记录目录名是工作目录里字母数字以外都换成「-」，按它粗筛再看工作目录
    by_project = {}
    if not paths and re.search(r"[A-Za-z0-9]", query):
        encoded = re.sub(r"[^A-Za-z0-9]", "-", query).lower()
        for _, path in found:
            if encoded not in os.path.basename(os.path.dirname(path)).lower():
                continue
            meta = session_meta(path)
            if not meta or not (meta["firstPrompt"] or meta["title"]) or needle not in project_name(meta["cwd"]).lower():
                continue
            title = needle in (meta["title"] or "").lower()
            by_project[path] = dict(meta, hits=[], match=["project", "title"] if title else ["project"])
            if len(by_project) >= 300:
                truncated = True
                break
    for _, path in found:
        if path in by_project:
            continue
        if time.time() - started > budget:
            truncated = True
            break
        try:
            with open(path, "rb") as handle:
                data = handle.read()
        except OSError:
            continue
        lowered = data.lower() if folds else data
        if pattern not in lowered:
            continue
        # 项目名（上面没挑出来的，如中文目录名）、标题里有搜索词：每行都带着工作目录，这种会话行行都命中，少翻几行找正文片段，也不占片段总数
        meta, matched = None, []
        if not paths:
            meta = session_meta(path) or {}
            if needle in project_name(meta.get("cwd")).lower():
                matched.append("project")
            if needle in (meta.get("title") or "").lower():
                matched.append("title")
        cap = 60 if matched else max_candidates
        hits, candidates, pos = [], 0, 0
        # 一行只看一次：看完跳到下一行再找（一行里出现很多次时别每次都往回找行首，长行会很慢）
        while True:
            found = lowered.find(pattern, pos)
            if found < 0:
                break
            start = data.rfind(b"\n", 0, found) + 1
            end = data.find(b"\n", found + len(pattern))
            end = len(data) if end < 0 else end
            pos = end + 1
            candidates += 1
            if candidates > cap or len(hits) >= per_session:
                break
            if end - start > 1024 * 1024:
                continue   # 带大图的行，正文命中的概率很小，跳过省时间
            entry = parse_line(data[start:end])
            if not entry or entry.get("isSidechain") or entry.get("isMeta"):
                continue
            for item in normalize_line(start, entry):
                text = item.get("text") or ""
                if item["t"] not in ("user", "text") or needle not in text.lower():
                    continue
                at = text.lower().index(needle)
                left = max(0, at - 36)
                snippet = ("…" if left else "") + text[left:at + len(query) + 60].replace("\n", " ")
                hits.append({"id": item["id"], "ts": item.get("ts"), "t": item["t"], "snippet": snippet})
                break
        if matched and not hits and not (meta.get("firstPrompt") or meta.get("title")):
            continue   # 空会话（打开就关了）不列，同 list_sessions
        if hits or matched:
            results.append(dict(meta if meta is not None else session_meta(path) or {}, hits=hits, match=matched))
            if not matched:
                total += len(hits)
            if total >= limit or len(results) >= 300:
                truncated = True
                break
    if by_project:
        results = sorted(results + list(by_project.values()), key=lambda r: -(r.get("lastActive") or 0))
    return results, truncated


# ---------------------------------------------------------------------------
# 用量报表（类似 ccusage）：按天 / 模型 / 项目汇总 token 和花费
#   token：每条 assistant 消息的 usage（按 message.id 去重，含子代理记录）
#   花费：Claude Code 自己写的 cost-state.modelUsage 给出每个模型累计的 token 和 costUSD，
#         由此得到「这个会话里这个模型每加权 token 多少钱」，再乘到每次请求上；
#         还没写 cost-state 的会话（正在跑）借用同机同模型的平均费率，标为估算
# ---------------------------------------------------------------------------

_USAGE_SCAN_CACHE = {}   # path -> (signature, scan)


def usage_weight(inp, out, cache_read, cache_write):
    """按 Anthropic 计价结构折算成「输入 token 当量」：输出 5 倍、写缓存 1.25 倍、读缓存 0.1 倍"""
    return inp + 5.0 * out + 0.1 * cache_read + 1.25 * cache_write


def scan_usage(path):
    """一个会话（含子代理）：{(小时, 模型): [输入, 输出, 读缓存, 写缓存, 请求数]}、各模型费率、工作目录"""
    sub_dir = os.path.join(path[:-6], "subagents")
    files = [path]
    try:
        files += [os.path.join(sub_dir, n) for n in sorted(os.listdir(sub_dir)) if n.endswith(".jsonl")]
    except OSError:
        pass
    try:
        signature = tuple((os.path.getsize(f), os.path.getmtime(f)) for f in files)
    except OSError:
        return None
    hit = _USAGE_SCAN_CACHE.get(path)
    if hit and hit[0] == signature:
        return hit[1]
    buckets, rates, seen, cwd = {}, {}, set(), None
    for index, name in enumerate(files):
        try:
            handle = open(name, "rb")
        except OSError:
            continue
        with handle:
            for raw in handle:
                if index == 0 and b'"cost-state"' in raw[:60]:
                    entry = parse_line(raw)
                    for model, info in ((entry or {}).get("modelUsage") or {}).items():
                        if not isinstance(info, dict):
                            continue
                        weight = usage_weight(info.get("inputTokens") or 0, info.get("outputTokens") or 0,
                                              info.get("cacheReadInputTokens") or 0, info.get("cacheCreationInputTokens") or 0)
                        cost = info.get("costUSD")
                        if weight > 0 and isinstance(cost, (int, float)):
                            rates[model] = (float(cost), weight)   # 累计值，后面的覆盖前面的
                    continue
                if b'"usage"' not in raw:
                    continue
                entry = parse_line(raw)
                if not entry or entry.get("type") != "assistant":
                    continue
                message = entry.get("message") if isinstance(entry.get("message"), dict) else {}
                usage = message.get("usage")
                model = message.get("model") or "unknown"
                if not isinstance(usage, dict) or model == "<synthetic>":
                    continue
                key = (message.get("id"), entry.get("requestId"))
                if key != (None, None):
                    if key in seen:
                        continue
                    seen.add(key)
                ts = parse_ts(entry.get("timestamp"))
                if ts is None:
                    continue
                cwd = cwd or entry.get("cwd")
                bucket = buckets.setdefault((ts // 3600000, model), [0, 0, 0, 0, 0])
                bucket[0] += int(usage.get("input_tokens") or 0)
                bucket[1] += int(usage.get("output_tokens") or 0)
                bucket[2] += int(usage.get("cache_read_input_tokens") or 0)
                bucket[3] += int(usage.get("cache_creation_input_tokens") or 0)
                bucket[4] += 1
    scan = {"buckets": buckets, "rates": rates, "cwd": cwd or transcript_cwd(path)}
    _USAGE_SCAN_CACHE[path] = (signature, scan)
    return scan


def usage_report(since_ms, until_ms=None, tz_minutes=0, plugins=None):
    """Claude Code 的记录（下面扫 PROJECTS_DIR）+ 各插件报的（AgentPlugin.usage），按天 / 模型 / 项目 / agent 汇总"""
    # 费率至少参考最近 30 天的会话：只看「今天」时，今天还在跑的会话也能借到费率
    scan_since = min(since_ms, int(time.time() * 1000) - 30 * 86400000)
    files = []
    try:
        projects = os.listdir(PROJECTS_DIR)
    except OSError:
        projects = []
    for project in projects:
        folder = os.path.join(PROJECTS_DIR, project)
        try:
            names = os.listdir(folder)
        except OSError:
            continue
        for name in names:
            if name.endswith(".jsonl") and _SID_RE.match(name[:-6]):
                path = os.path.join(folder, name)
                try:
                    newest = os.path.getmtime(path)
                    sub = os.path.join(path[:-6], "subagents")
                    if os.path.isdir(sub):
                        newest = max([newest] + [os.path.getmtime(os.path.join(sub, n)) for n in os.listdir(sub)])
                except OSError:
                    continue
                if newest * 1000 >= scan_since:
                    files.append(path)
    scans = [(path, scan_usage(path)) for path in files]
    scans = [(p, sc) for p, sc in scans if sc]
    # 同机同模型的平均费率：给还没写 cost-state 的会话估算用
    pooled = {}
    for _, scan in scans:
        for model, (cost, weight) in scan["rates"].items():
            acc = pooled.setdefault(model, [0.0, 0.0])
            acc[0] += cost
            acc[1] += weight
    days, models, projects_out, agents = {}, {}, {}, {}
    day_split = {}   # 天 -> {"agents": {agent: token}, "models": {模型: token}}：分享战绩的「阵容」用

    def split(day, agent, model, vals):
        entry = day_split.setdefault(day, {"agents": {}, "models": {}})
        tokens = vals[0] + vals[1] + vals[2] + vals[3]
        entry["agents"][agent] = entry["agents"].get(agent, 0) + tokens
        entry["models"][model] = entry["models"].get(model, 0) + tokens
    totals = {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "requests": 0, "cost": 0.0, "estimated": 0.0}
    unpriced = set()

    def add(target, vals, cost, estimated):
        target["input"] += vals[0]
        target["output"] += vals[1]
        target["cacheRead"] += vals[2]
        target["cacheWrite"] += vals[3]
        target["requests"] += vals[4]
        target["cost"] += cost
        target["estimated"] += cost if estimated else 0.0

    def blank(**extra):
        return dict({"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "requests": 0, "cost": 0.0, "estimated": 0.0}, **extra)

    for path, scan in scans:
        for (hour, model), vals in scan["buckets"].items():
            ts = hour * 3600000
            if ts < since_ms or (until_ms and ts >= until_ms):
                continue
            weight = usage_weight(vals[0], vals[1], vals[2], vals[3])
            if model in scan["rates"]:
                cost, estimated = weight * scan["rates"][model][0] / scan["rates"][model][1], False
            elif model in pooled and pooled[model][1] > 0:
                cost, estimated = weight * pooled[model][0] / pooled[model][1], True
            else:
                cost, estimated = 0.0, False
                unpriced.add(model)
            day = time.strftime("%Y-%m-%d", time.gmtime(ts / 1000.0 + tz_minutes * 60))
            add(days.setdefault(day, blank(day=day)), vals, cost, estimated)
            add(models.setdefault(model, blank(model=model)), vals, cost, estimated)
            cwd = scan["cwd"] or ""
            add(projects_out.setdefault(cwd, blank(cwd=cwd)), vals, cost, estimated)
            add(agents.setdefault("claude", blank(agent="claude", name="Claude Code")), vals, cost, estimated)
            split(day, "claude", model, vals)
            add(totals, vals, cost, estimated)
    sessions = sum(1 for _, scan in scans if any(hour * 3600000 >= since_ms for hour, _ in scan["buckets"]))
    # 别家 agent：插件报的一条条记录（花费是 agent 自己记的；没记的模型只算 token）
    for plugin, records in (plugins.usage(since_ms) if plugins else []):
        seen = set()
        for record in records:
            ts = int(record["ts"])
            if ts < since_ms or (until_ms and ts >= until_ms):
                continue
            vals = [max(0, int(record.get(key) or 0)) for key in ("input", "output", "cacheRead", "cacheWrite", "requests")]
            if not any(vals):
                continue
            model = str(record.get("model") or "unknown")
            cost = record.get("cost")
            priced = isinstance(cost, (int, float)) and cost >= 0
            cost = float(cost) if priced else 0.0
            if not priced:
                unpriced.add(model)
            day = time.strftime("%Y-%m-%d", time.gmtime(ts / 1000.0 + tz_minutes * 60))
            add(days.setdefault(day, blank(day=day)), vals, cost, False)
            add(models.setdefault(model, blank(model=model)), vals, cost, False)
            cwd = record.get("cwd") or ""
            add(projects_out.setdefault(cwd, blank(cwd=cwd)), vals, cost, False)
            # 这家一条花费都没记（Codex、DSH、Qwen Code）：界面上写「仅 token」，别显示成 $0
            row = agents.setdefault(plugin.id, blank(agent=plugin.id, name=plugin.name, unpriced=True))
            split(day, plugin.id, model, vals)
            add(row, vals, cost, False)
            row["unpriced"] = row["unpriced"] and not priced
            add(totals, vals, cost, False)
            if record.get("session"):
                seen.add(record["session"])
        sessions += len(seen)
    rank = lambda item: (item["cost"], item["output"])
    return {
        "days": sorted(days.values(), key=lambda d: d["day"]),
        "models": sorted(models.values(), key=rank, reverse=True),
        "projects": sorted(projects_out.values(), key=rank, reverse=True)[:30],
        "agents": sorted(agents.values(), key=rank, reverse=True),
        "totals": totals,
        "unpriced": sorted(unpriced),
        "sessions": sessions,
        "daySplit": day_split,
    }


# ---------------------------------------------------------------------------
# 战绩（分享卡片用）：每天改了多少行、在线多久、同时开了几个会话。只有数字，不带任何对话内容、文件名、项目名
# ---------------------------------------------------------------------------

BRAG_IDLE_MS = 5 * 60000      # 同一个会话两次动静隔得比这短，算一直在干活
_BRAG_SCAN_CACHE = {}         # path -> (signature, scan)


def _patch_counts(patch):
    """apply_patch 补丁 → [(路径, 加的行, 删的行)]，只数 + / - 行，上下文行不算"""
    out = []
    for line in (patch or "").split("\n"):
        match = re.match(r"^\*\*\* (Add|Update|Delete) File: (.+)$", line)
        if match:
            out.append([match.group(2).strip(), 0, 0])
        elif out and not line.startswith("*** ") and not line.startswith("@@"):
            if line.startswith("+"):
                out[-1][1] += 1
            elif line.startswith("-"):
                out[-1][2] += 1
    return [tuple(item) for item in out]


def _codex_patch_text(name, args):
    """Codex 的一次工具调用里如果是补丁，取出补丁正文"""
    if name == "apply_patch":
        if isinstance(args, dict):
            return args.get("input") or args.get("patch") or ""
        return args if isinstance(args, str) else ""
    if name in CODEX_SHELL_TOOLS and isinstance(args, dict):
        command = _shell_text(args.get("cmd") or args.get("command"))
        if command.startswith("apply_patch"):
            body = command[len("apply_patch"):].strip()
            if len(body) >= 2 and body[0] == body[-1] and body[0] in "'\"":
                body = body[1:-1]
            if "*** Begin Patch" in body:
                return body.replace("\\n", "\n") if "\n" not in body else body
    return ""


def _brag_claude_file(path, scan):
    """一份 Claude Code 记录：每条带时间的记录算一次动静；用户发的话、工具调用、编辑结果（按真实补丁数行）"""
    try:
        handle = open(path, "rb")
    except OSError:
        return
    with handle:
        for raw in handle:
            tail = raw[-8000:]
            found = list(_TS_BYTES.finditer(tail))
            if not found:
                continue
            ts = parse_ts(found[-1].group(1).decode() + "Z")
            if ts is None:
                continue
            scan["events"].append(ts)
            head = raw[:1500]   # 用户那一行的 "type":"user" 在 message 前面；助手那一行的 type 在行尾，不能靠它认
            if b'"type":"user"' not in head and b'"type": "user"' not in head:
                # 工具调用只数个数，不解析整行（大部分时间花在这里）；正文里的同样字样是转义过的（\"），数不到
                uses = raw.count(b'"type":"tool_use"') + raw.count(b'"type": "tool_use"')
                if uses:
                    scan["tools"].extend([ts] * uses)
                continue
            if b'"toolUseResult"' in raw and b'"structuredPatch"' not in raw:
                continue   # 读文件、跑命令的结果：不是编辑，也不是用户说的话
            entry = parse_line(raw)
            if not isinstance(entry, dict) or entry.get("type") != "user":
                continue
            scan["cwd"] = scan["cwd"] or entry.get("cwd")
            result = entry.get("toolUseResult")
            if isinstance(result, dict):
                target = result.get("filePath") or result.get("notebook_path") or ""
                added = removed = 0
                text = result.get("content")
                if result.get("type") == "create" and isinstance(text, str) and text:
                    added = text.count("\n") + (0 if text.endswith("\n") else 1)
                for hunk in result.get("structuredPatch") or []:
                    for line in (hunk.get("lines") if isinstance(hunk, dict) else None) or []:
                        if isinstance(line, str) and line.startswith("+"):
                            added += 1
                        elif isinstance(line, str) and line.startswith("-"):
                            removed += 1
                if added or removed:
                    scan["edits"].append((ts, added, removed, target))
                continue
            if entry.get("isSidechain") or entry.get("isMeta") or result is not None:
                continue
            if any(item.get("t") == "user" for item in normalize_line(0, entry)):
                scan["prompts"].append(ts)


def _brag_codex_file(path, scan):
    """一份 Codex rollout：用户发的话、工具调用、补丁（apply_patch，或 shell 里调的 apply_patch）"""
    try:
        handle = open(path, "rb")
    except OSError:
        return
    with handle:
        for raw in handle:
            entry = parse_line(raw)
            if not isinstance(entry, dict):
                continue
            ts = parse_ts(entry.get("timestamp"))
            payload = entry.get("payload") if isinstance(entry.get("payload"), dict) else {}
            if ts is None:
                continue
            scan["events"].append(ts)
            kind = payload.get("type")
            if entry.get("type") in ("session_meta", "turn_context"):
                scan["cwd"] = payload.get("cwd") or scan["cwd"]
            elif entry.get("type") == "event_msg" and kind == "user_message":
                scan["prompts"].append(ts)
            elif entry.get("type") == "response_item" and kind in ("function_call", "custom_tool_call", "local_shell_call"):
                scan["tools"].append(ts)
                name = payload.get("name") or ("shell" if kind == "local_shell_call" else "")
                args = payload.get("arguments") if kind == "function_call" else payload.get("input")
                if kind == "local_shell_call":
                    args = payload.get("action") or {}
                if isinstance(args, str) and kind == "function_call":
                    try:
                        args = json.loads(args)
                    except ValueError:
                        pass
                for target, added, removed in _patch_counts(_codex_patch_text(name, args)):
                    if added or removed:
                        scan["edits"].append((ts, added, removed, target))


def brag_scan(path, agent):
    """一个会话的动静（含 Claude 子代理）：文件没变就用上次的"""
    files = [path]
    if agent == "claude":
        sub_dir = os.path.join(path[:-6], "subagents")
        try:
            files += [os.path.join(sub_dir, n) for n in sorted(os.listdir(sub_dir)) if n.endswith(".jsonl")]
        except OSError:
            pass
    try:
        signature = tuple((os.path.getsize(f), os.path.getmtime(f)) for f in files)
    except OSError:
        return None
    hit = _BRAG_SCAN_CACHE.get(path)
    if hit and hit[0] == signature:
        return hit[1]
    scan = {"agent": agent, "events": [], "prompts": [], "tools": [], "edits": [], "cwd": None}
    for name in files:
        (_brag_claude_file if agent == "claude" else _brag_codex_file)(name, scan)
    scan["events"].sort()
    _BRAG_SCAN_CACHE[path] = (signature, scan)
    return scan


def _brag_spans(events, since_ms, until_ms):
    """一串动静时间（已排序）→ 在干活的时间段 [[开始分钟, 结束分钟)]：相邻两次隔不到 5 分钟连成一段，孤零零的一次算 1 分钟"""
    spans = []
    for ts in events:
        if ts < since_ms or (until_ms and ts >= until_ms):
            continue
        if spans and ts - spans[-1][2] <= BRAG_IDLE_MS:
            spans[-1][1] = max(spans[-1][1], ts // 60000 + 1)
            spans[-1][2] = ts
        else:
            spans.append([ts // 60000, ts // 60000 + 1, ts])
    return [[s, e] for s, e, _ in spans]


def brag_merge(lanes):
    """好几个会话（可能在好几台电脑上）的时间段 → (并起来的总分钟数, 各会话加起来的分钟数, 最多同时几个)"""
    points, union, total = [], [], 0
    for lane in lanes:
        for start, end in lane:
            total += end - start
            points.append((start, 1))
            points.append((end, -1))
    points.sort(key=lambda p: (p[0], p[1]))   # 同一分钟先结束再开始，首尾相接不算同时
    peak = current = 0
    for _, step in points:
        current += step
        peak = max(peak, current)
    for start, end in sorted(span for lane in lanes for span in lane):
        if union and start <= union[-1][1]:
            union[-1][1] = max(union[-1][1], end)
        else:
            union.append([start, end])
    return sum(e - s for s, e in union), total, peak


def brag_curve(lanes, day, tz_minutes):
    """一天 96 格（每格 15 分钟），每格有几个会话在干活：分享卡片上的 24 小时活跃曲线。多台电脑的直接逐格相加"""
    try:
        start = (calendar.timegm(time.strptime(day, "%Y-%m-%d")) // 60) - tz_minutes
    except ValueError:
        return [0] * 96
    curve = [0] * 96
    for lane in lanes:
        hit = set()
        for s, e in lane:
            for slot in range(max(0, (s - start) // 15), min(96, (e - 1 - start) // 15 + 1)):
                hit.add(slot)
        for slot in hit:
            curve[slot] += 1
    return curve


def _brag_files(since_ms):
    """since 之后动过的会话记录：[(路径, agent)]"""
    out = []
    try:
        projects = os.listdir(PROJECTS_DIR)
    except OSError:
        projects = []
    for project in projects:
        folder = os.path.join(PROJECTS_DIR, project)
        try:
            names = os.listdir(folder)
        except OSError:
            continue
        for name in names:
            if name.endswith(".jsonl") and _SID_RE.match(name[:-6]):
                path = os.path.join(folder, name)
                try:
                    newest = os.path.getmtime(path)
                    sub = os.path.join(path[:-6], "subagents")
                    if os.path.isdir(sub):
                        newest = max([newest] + [os.path.getmtime(os.path.join(sub, n)) for n in os.listdir(sub)])
                except OSError:
                    continue
                if newest * 1000 >= since_ms:
                    out.append((path, "claude"))
    home = os.environ.get("CODEX_HOME") or os.path.join(HOME, ".codex")
    for path in recent_files([os.path.join(home, "sessions"), os.path.join(home, "archived_sessions")], ".jsonl", since_ms):
        if os.path.basename(path).startswith("rollout-"):
            out.append((path, "codex"))
    return out


def _brag_blank(day):
    return {"day": day, "linesAdded": 0, "linesRemoved": 0, "files": 0, "edits": 0, "prompts": 0, "toolCalls": 0,
            "sessions": 0, "activeMinutes": 0, "agentMinutes": 0, "peak": 0, "firstAt": None, "lastAt": None,
            "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "requests": 0, "cost": 0.0, "agents": [], "lanes": []}


def brag_report(since_ms, until_ms=None, tz_minutes=0, plugins=None):
    """按天的战绩：token 与花费（同 usage_report，含各插件）+ 改了多少行、在线多久、同时开几个会话（Claude Code、Codex 的记录）。
    lanes 是每个会话那天在干活的时间段（分钟），电脑端合并多台电脑时用它重算在线时长和「最多同时」"""
    def day_of(ts):
        return time.strftime("%Y-%m-%d", time.gmtime(ts / 1000.0 + tz_minutes * 60))

    def day_start(ts):
        local = ts + tz_minutes * 60000
        return local - local % 86400000 - tz_minutes * 60000

    def inside(ts):
        return ts >= since_ms and not (until_ms and ts >= until_ms)

    days = {}

    def row_for(ts):
        key = day_of(ts)
        return days.setdefault(key, _brag_blank(key))

    for path, agent in _brag_files(since_ms):
        scan = brag_scan(path, agent)
        if not scan or not scan["events"]:
            continue
        files_by_day = {}
        for ts, added, removed, target in scan["edits"]:
            if inside(ts):
                row = row_for(ts)
                row["linesAdded"] += added
                row["linesRemoved"] += removed
                row["edits"] += 1
                files_by_day.setdefault(row["day"], set()).add(target)
        for key, targets in files_by_day.items():
            days[key]["files"] += len(targets)
        for field, stamps in (("prompts", scan["prompts"]), ("toolCalls", scan["tools"])):
            for ts in stamps:
                if inside(ts):
                    row_for(ts)[field] += 1
        # 按天切开：跨午夜的会话两天各算各的
        by_day = {}
        for ts in scan["events"]:
            if inside(ts):
                by_day.setdefault(day_start(ts), []).append(ts)
        for start, stamps in by_day.items():
            row = row_for(start)
            row["lanes"].append(_brag_spans(stamps, start, start + 86400000))
            row["sessions"] += 1
            row["firstAt"] = min(row["firstAt"] or stamps[0], stamps[0])
            row["lastAt"] = max(row["lastAt"] or stamps[-1], stamps[-1])
            if agent not in row["agents"]:
                row["agents"].append(agent)
    usage = usage_report(since_ms, until_ms, tz_minutes, plugins)
    for item in usage.get("days") or []:
        row = days.setdefault(item["day"], _brag_blank(item["day"]))
        for field in ("input", "output", "cacheRead", "cacheWrite", "requests", "cost"):
            row[field] += item.get(field) or 0
    for key, entry in (usage.get("daySplit") or {}).items():
        row = days.setdefault(key, _brag_blank(key))
        row["agentTokens"], row["models"] = entry["agents"], entry["models"]
        for agent in entry["agents"]:
            if agent not in row["agents"]:
                row["agents"].append(agent)
    for row in days.values():
        row["activeMinutes"], row["agentMinutes"], row["peak"] = brag_merge(row["lanes"])
        row["curve"] = brag_curve(row["lanes"], row["day"], tz_minutes)
    return {"days": sorted(days.values(), key=lambda d: d["day"]),
            "agents": [a.get("agent") for a in usage.get("agents") or []], "idleMinutes": BRAG_IDLE_MS // 60000}


def _brag_session_split(path, agent):
    """一个会话按模型分的 token（阵容卡片用）"""
    models = {}
    if agent == "claude":
        for (_, model), vals in ((scan_usage(path) or {}).get("buckets") or {}).items():
            models[model] = models.get(model, 0) + vals[0] + vals[1] + vals[2] + vals[3]
    else:
        for record in cached_usage(path, codex_usage_scan):
            model = str(record.get("model") or "unknown")
            models[model] = models.get(model, 0) + sum(int(record.get(k) or 0) for k in ("input", "output", "cacheRead", "cacheWrite"))
    return models


def brag_session(path):
    """一个会话从头到尾的战绩（任务做完时分享用）：同样只有数字"""
    agent = "codex" if os.path.basename(path).startswith("rollout-") else "claude"
    scan = brag_scan(path, agent)
    if not scan:
        raise RuntimeError("读不到这个会话的记录")
    events = scan["events"]
    spans = _brag_spans(events, 0, None)
    tokens = {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "requests": 0, "cost": 0.0}
    if agent == "claude":
        usage = scan_usage(path) or {"buckets": {}, "rates": {}}
        for (_, model), vals in usage["buckets"].items():
            for index, field in enumerate(("input", "output", "cacheRead", "cacheWrite", "requests")):
                tokens[field] += vals[index]
            if model in usage["rates"] and usage["rates"][model][1] > 0:
                tokens["cost"] += usage_weight(*vals[:4]) * usage["rates"][model][0] / usage["rates"][model][1]
    else:
        for record in cached_usage(path, codex_usage_scan):
            for field in ("input", "output", "cacheRead", "cacheWrite", "requests"):
                tokens[field] += int(record.get(field) or 0)
    models = _brag_session_split(path, agent)
    return dict(tokens, agent=agent, agents=[agent], models=models, agentTokens={agent: sum(models.values())},
                linesAdded=sum(e[1] for e in scan["edits"]),
                linesRemoved=sum(e[2] for e in scan["edits"]), files=len({e[3] for e in scan["edits"]}),
                edits=len(scan["edits"]), prompts=len(scan["prompts"]), toolCalls=len(scan["tools"]),
                activeMinutes=sum(e - s for s, e in spans), agentMinutes=sum(e - s for s, e in spans), sessions=1, peak=1,
                firstAt=events[0] if events else None, lastAt=events[-1] if events else None)


# ---------------------------------------------------------------------------
# 独立 worktree：新任务可以在一个新分支的 worktree 里做，不碰主目录正在改的东西（只新增，不删不改）
# ---------------------------------------------------------------------------

_QUICK_GIT = {}   # cwd -> (过期时间, 概况)
QUICK_GIT_TIMEOUT = 3


def quick_git(cwd):
    """项目总览用的 git 概况：分支、未提交改动个数、领先 / 落后、最近一次提交。不算行数，求快；20 秒内复用。
    超时的（大仓库、网络盘，或 macOS 在等用户授权访问「文稿」/ 网络卷——这时 git 会一直卡着）记 10 分钟，别每次都等"""
    hit = _QUICK_GIT.get(cwd)
    if hit and time.time() < hit[0]:
        return hit[1]
    info, ttl = None, 20
    if shutil.which("git") and isinstance(cwd, str) and os.path.isdir(cwd):
        try:
            porcelain = run_git(cwd, ["status", "--porcelain=v1", "-b", "--untracked-files=normal"], timeout=QUICK_GIT_TIMEOUT)
            branch, upstream, ahead, behind, changed, untracked = None, None, 0, 0, 0, 0
            for line in porcelain.splitlines():
                if line.startswith("## "):
                    head = line[3:]
                    if head.startswith("No commits yet on "):
                        branch = head[len("No commits yet on "):].split("...")[0].strip()
                        continue
                    match = re.match(r"([^.\s]+)(?:\.\.\.(\S+))?(?: \[(.*)\])?", head)
                    if match:
                        branch, upstream = match.group(1), match.group(2)
                        for part in (match.group(3) or "").split(","):
                            part = part.strip()
                            if part.startswith("ahead "):
                                ahead = int(part[6:])
                            elif part.startswith("behind "):
                                behind = int(part[7:])
                elif line.startswith("??"):
                    untracked += 1
                elif line.strip() and not line.startswith("…"):
                    changed += 1
            last = None
            try:
                parts = run_git(cwd, ["log", "-1", "--pretty=format:%h%x09%ct%x09%s"], timeout=QUICK_GIT_TIMEOUT).split("\t", 2)
                if len(parts) == 3 and parts[1].isdigit():
                    last = {"hash": parts[0], "ts": int(parts[1]) * 1000, "subject": parts[2][:200]}
            except Exception:
                pass   # 还没有提交
            info = {"branch": branch, "upstream": upstream, "ahead": ahead, "behind": behind,
                    "changed": changed, "untracked": untracked, "last": last}
        except subprocess.TimeoutExpired:
            info, ttl = {"timeout": True}, 600
        except Exception:
            info = None   # 不是 git 仓库
    _QUICK_GIT[cwd] = (time.time() + ttl, info)
    return info


def project_overview(limit=40, since=None, extra=None):
    """项目总览：每个项目的会话数、今天动过几个、git 概况。extra 是正在跑的会话的目录（保证它们在列表里）"""
    from concurrent.futures import ThreadPoolExecutor
    projects = list_projects(limit, since)
    known = {p["cwd"] for p in projects}
    for cwd in (extra or [])[:20]:
        if is_abs_path(cwd) and cwd not in known:
            known.add(cwd)
            projects.append({"cwd": cwd, "lastActive": 0, "exists": os.path.isdir(cwd), "sessions": 0, "today": 0})
    targets = [p for p in projects if p.get("exists")]
    with ThreadPoolExecutor(max_workers=8) as pool:
        for project, info in zip(targets, pool.map(lambda p: quick_git(p["cwd"]), targets)):
            project["git"] = info
    return projects


def repo_info(cwd):
    """cwd 是不是 git 仓库、仓库根、当前分支、已有的 Kiteline worktree"""
    if not shutil.which("git") or not isinstance(cwd, str) or not os.path.isdir(cwd):
        return {"repo": False}
    try:
        root = run_git(cwd, ["rev-parse", "--show-toplevel"]).strip()
    except Exception:
        return {"repo": False}
    try:
        branch = run_git(root, ["rev-parse", "--abbrev-ref", "HEAD"]).strip()
    except Exception:
        branch = None
    trees = []
    try:
        current = {}
        for line in run_git(root, ["worktree", "list", "--porcelain"]).splitlines() + [""]:
            if not line:
                if current.get("branch", "").startswith("refs/heads/tars/"):
                    trees.append({"path": current["worktree"], "branch": current["branch"][len("refs/heads/"):]})
                current = {}
            elif " " in line:
                key, value = line.split(" ", 1)
                current[key] = value
    except Exception:
        pass
    return {"repo": True, "root": root, "branch": branch, "worktrees": trees}


def worktree_add(cwd, stamp=None):
    """在仓库旁边的 <仓库名>-worktrees/ 下新建一个 worktree，分支 tars/<时间>，返回会话该用的目录"""
    info = repo_info(cwd)
    if not info["repo"]:
        raise RuntimeError("这个目录不是 git 仓库，没法开独立分支")
    root = info["root"]
    stamp = stamp or time.strftime("%Y%m%d-%H%M%S")
    branch = "tars/%s" % stamp
    base = os.path.join(os.path.dirname(root), os.path.basename(root) + "-worktrees")
    path = os.path.join(base, stamp)
    if os.path.exists(path):
        raise RuntimeError("目录已存在：%s" % path)
    os.makedirs(base, exist_ok=True)
    run_git(root, ["worktree", "add", "-b", branch, path, "HEAD"])
    # 会话目录在仓库的子目录里时，worktree 里也进到同一个子目录
    rel = os.path.relpath(os.path.realpath(cwd), os.path.realpath(root))
    target = path if rel == "." else os.path.join(path, rel)
    if not os.path.isdir(target):
        target = path   # 子目录里没有被 git 跟踪的文件时，worktree 里不会有它
    return {"path": target, "worktree": path, "branch": branch, "base": info.get("branch")}


# ---------------------------------------------------------------------------
# 项目文件浏览（只读）：只能看会话工作目录以内的东西，符号链接解析后也不能跑出去
# ---------------------------------------------------------------------------

FILE_READ_MAX = 512 * 1024
IMAGE_READ_MAX = 6 * 1024 * 1024
SKIP_DIRS = {".git", "node_modules", "dist", "build", ".next", ".nuxt", "__pycache__", ".venv", "venv", "Pods",
             "DerivedData", ".build", "target", ".gradle", ".idea", ".cache", "coverage", ".turbo", "vendor"}
# 看名字像密钥、密码的文件：手机上默认不给内容，要点「显示」才给（防误看、防截图外传，不是安全边界）
SECRET_RE = re.compile(r"(^\.env(\..*)?$|\.(pem|key|p8|p12|pfx|jks|keystore|kdbx|ovpn)$|^id_(rsa|ed25519|ecdsa|dsa)|"
                       r"^\.(netrc|npmrc|pypirc|pgpass|git-credentials|server)$|htpasswd|credentials|secret|"
                       r"(^|[._-])(tokens?|passwords?|passwd)(\.(txt|json|ya?ml|toml|conf|cfg|ini))?$)", re.IGNORECASE)
_GIT_MARKS = {}   # 仓库根 -> (时间, {相对仓库根的路径: 状态})


def safe_path(root, rel):
    """root 下的相对路径 → 绝对路径；跑出 root（.. 或符号链接）就拒绝"""
    if not is_abs_path(root) or not os.path.isdir(root):
        raise RuntimeError("项目目录不存在")
    rel = (rel or "").strip().lstrip("/")
    real_root = os.path.realpath(root)
    target = os.path.realpath(os.path.join(real_root, rel))
    if target != real_root and not target.startswith(real_root + os.sep):
        raise RuntimeError("只能查看项目目录里的文件")
    return real_root, target


def git_marks(path):
    """path 所在仓库的改动标记，缓存 5 秒（翻目录时不用每次跑 git）"""
    if not shutil.which("git"):
        return None, {}
    try:
        root = run_git(path, ["rev-parse", "--show-toplevel"]).strip()
    except Exception:
        return None, {}
    hit = _GIT_MARKS.get(root)
    if hit and time.time() - hit[0] < 5:
        return root, hit[1]
    marks = {}
    try:
        for line in run_git(root, ["status", "--porcelain=v1", "--untracked-files=normal"]).splitlines():
            code, name = line[:2], line[3:]
            if " -> " in name:
                name = name.split(" -> ", 1)[1]
            marks[name.strip('"').rstrip("/")] = "?" if code == "??" else (code.strip()[:1] or "M")
    except Exception:
        pass
    _GIT_MARKS[root] = (time.time(), marks)
    return root, marks


def list_dir(root, rel):
    real_root, target = safe_path(root, rel)
    if not os.path.isdir(target):
        raise RuntimeError("不是目录")
    repo, marks = git_marks(target)
    entries = []
    try:
        names = os.listdir(target)
    except OSError as error:
        raise RuntimeError("读不了这个目录：%s" % error.strerror)
    for name in names:
        if name == ".git":
            continue
        full = os.path.join(target, name)
        try:
            stat = os.stat(full)
        except OSError:
            continue
        is_dir = os.path.isdir(full)
        item = {"name": name, "type": "dir" if is_dir else "file", "size": 0 if is_dir else stat.st_size,
                "mtime": int(stat.st_mtime * 1000)}
        if os.path.islink(full):
            item["link"] = True
        if repo:
            in_repo = rel_path(os.path.realpath(full), repo)
            if is_dir:
                prefix = in_repo + "/"
                if any(k == in_repo or k.startswith(prefix) for k in marks):
                    item["git"] = "•"
            elif in_repo in marks:
                item["git"] = marks[in_repo]
        entries.append(item)
        if len(entries) >= 2000:
            break
    entries.sort(key=lambda e: (e["type"] != "dir", e["name"].lower()))
    rel = rel_path(target, real_root)
    return {"path": "" if rel == "." else rel, "entries": entries, "truncated": len(entries) >= 2000}


def list_dirs(path, hidden=False, mkdir=None):
    """新任务「打开其他文件夹」：列一个目录下的子文件夹（不限项目目录；空 = 用户主目录）。
    mkdir：先在这个目录里新建一个文件夹，再列新文件夹（给新项目用）"""
    home = os.path.expanduser("~")
    target = os.path.expanduser(path.strip()) if isinstance(path, str) and path.strip() else home
    if not is_abs_path(target):
        raise RuntimeError("路径无效")
    target = os.path.abspath(target)
    if not os.path.isdir(target):
        raise RuntimeError("目录不存在：%s" % target)
    if mkdir:
        name = _check_name(mkdir)
        made = os.path.join(target, name)
        if os.path.lexists(made):
            raise RuntimeError("已存在同名的文件或文件夹")
        try:
            os.makedirs(made)
        except PermissionError:
            raise RuntimeError("没有权限在这里新建文件夹")
        except OSError as error:
            raise RuntimeError("无法新建文件夹：%s" % (error.strerror or error))
        target = made
    try:
        names = os.listdir(target)
    except PermissionError:
        raise RuntimeError("没有权限读取该目录")
    except OSError as error:
        raise RuntimeError("无法读取该目录：%s" % (error.strerror or error))
    entries = []
    # Mac 上主目录下的「文稿」「桌面」「下载」、/Volumes 下的盘：往里看一眼有没有 .git 就会弹文件夹授权框，不探（点进去再说）
    probe = not (sys.platform == "darwin" and target in (os.path.realpath(home), home, "/Volumes"))
    for name in names:
        if not hidden and (name.startswith(".") or (IS_WINDOWS and (name.startswith("$") or name == "System Volume Information"))):
            continue
        full = os.path.join(target, name)
        if not os.path.isdir(full):
            continue
        item = {"name": name, "path": full}
        if probe and os.path.exists(os.path.join(full, ".git")):
            item["git"] = True
        entries.append(item)
        if len(entries) >= 2000:
            break
    entries.sort(key=lambda e: e["name"].lower())
    parent = os.path.dirname(target)
    out = {"path": target, "parent": parent if parent != target else None, "home": home, "sep": os.sep,
           "entries": entries, "truncated": len(entries) >= 2000, "git": os.path.exists(os.path.join(target, ".git"))}
    if IS_WINDOWS:
        out["roots"] = [drive for drive in ("%s:\\" % letter for letter in "CDEFGHIJKLMNOPQRSTUVWXYZ") if os.path.isdir(drive)]
    return out


def read_file(root, rel, reveal=False, edit=False):
    real_root, target = safe_path(root, rel)
    if not os.path.isfile(target):
        raise RuntimeError("不是文件")
    name = os.path.basename(target)
    size = os.path.getsize(target)
    out = {"path": rel_path(target, real_root), "name": name, "size": size, "mtime": int(os.path.getmtime(target) * 1000)}
    if SECRET_RE.search(name) and not reveal:
        out["secret"] = True
        return out
    mime = mimetypes.guess_type(name)[0] or ""
    if mime.startswith("image/"):
        if size > IMAGE_READ_MAX:
            out["tooLarge"] = True
            return out
        with open(target, "rb") as handle:
            out.update({"image": True, "mime": mime, "data": base64.b64encode(handle.read()).decode("ascii")})
        return out
    # 编辑器（edit）一次读到 4MB；只看的仍是 512KB
    limit = FILE_EDIT_MAX if edit else FILE_READ_MAX
    with open(target, "rb") as handle:
        data = handle.read(limit + 1)
    if b"\0" in data[:8192]:
        out["binary"] = True
        return out
    out["truncated"] = len(data) > limit
    out.update(text_meta(data[:limit], cut=len(data) > limit))
    out["text"] = data[:limit].decode("utf-8", "replace").lstrip("\ufeff")
    out["lines"] = out["text"].count("\n") + 1
    return out


# 手机取回电脑上的文件（Claude 回复里提到的路径、手机发来的附件）：预览、转发到别的 App。
# 不限于项目目录（Claude 常把生成的表格放桌面）：绝对路径、~ 开头，或相对会话目录；看名字像密钥的同样要点「仍然打开」才给
DOWNLOAD_MAX = 50 * 1024 * 1024


def get_file(path, cwd=None, reveal=False):
    raw = str(path or "").strip()
    if not raw or len(raw) > 4096 or "\0" in raw:
        raise RuntimeError("文件路径无效")
    full = os.path.expanduser(raw)
    if not is_abs_path(full):
        if not is_abs_path(cwd):
            raise RuntimeError("无法确定相对路径所在的目录：%s" % raw)
        full = os.path.join(cwd, full)
    full = os.path.realpath(full)
    if os.path.isdir(full):
        raise RuntimeError("这是一个文件夹，不是文件：%s" % raw)
    if not os.path.isfile(full):
        raise RuntimeError("文件不存在：%s" % raw)
    name = os.path.basename(full)
    size = os.path.getsize(full)
    out = {"path": full, "name": name, "size": size, "mtime": int(os.path.getmtime(full) * 1000),
           "mime": mimetypes.guess_type(name)[0] or "application/octet-stream"}
    if SECRET_RE.search(name) and not reveal:
        out["secret"] = True
        return out
    if size > DOWNLOAD_MAX:
        raise RuntimeError("文件超过 50 MB，请在电脑上查看：%s" % name)
    try:
        with open(full, "rb") as handle:
            out["data"] = base64.b64encode(handle.read()).decode("ascii")
    except OSError as error:
        raise RuntimeError("无法读取文件：%s" % (error.strerror or error))
    return out


def find_files(root, query, limit=200):
    """按文件名找（不分大小写，空格分开的几个词都要出现），跳过 node_modules 这类目录"""
    real_root, _ = safe_path(root, "")
    words = [w for w in (query or "").lower().split() if w]
    if not words:
        return {"results": []}
    results, started, scanned = [], time.time(), 0
    for folder, dirs, names in os.walk(real_root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS and not d.startswith(".")]
        rel_folder = rel_path(folder, real_root)
        for name in names:
            scanned += 1
            rel = name if rel_folder == "." else rel_folder + "/" + name
            low = rel.lower()
            if all(w in low for w in words):
                results.append(rel)
                if len(results) >= limit:
                    return {"results": results, "truncated": True}
        if time.time() - started > 5 or scanned > 200000:
            return {"results": results, "truncated": True}
    results.sort(key=lambda r: (not os.path.basename(r).lower().startswith(words[0]), len(r)))
    return {"results": results}


# ---------------------------------------------------------------------------
# 代码 IDE：改项目文件（保存 / 新建 / 改名 / 移动 / 复制 / 删除到废纸篓 / 上传）。
# 和上面的浏览一样只能动会话工作目录以内的东西；删除一律进系统废纸篓（还能找回），移不进去就报错，不偷偷永久删除
# ---------------------------------------------------------------------------

FILE_EDIT_MAX = 4 * 1024 * 1024     # 编辑器一次读写的上限（只读浏览仍是 FILE_READ_MAX）
UPLOAD_MAX = 30 * 1024 * 1024
UTF8_BOM = b"\xef\xbb\xbf"


def text_meta(data, cut=False):
    """编辑器保存时要原样保留的东西：换行（CRLF / LF）、BOM、能不能按 UTF-8 无损读写"""
    meta = {"sha": hashlib.sha1(data).hexdigest(), "eol": "crlf" if b"\r\n" in data[:200000] else "lf"}
    if data.startswith(UTF8_BOM):
        meta["bom"] = True
    try:
        data.decode("utf-8")
    except UnicodeDecodeError as exc:
        # 读到上限时最后一个字可能被截成半个，那不算编码问题
        if not cut or exc.start < len(data) - 4:
            meta["lossy"] = True
    return meta


def _check_name(name):
    name = (name or "").strip()
    if not name or name in (".", "..") or "/" in name or "\\" in name or "\0" in name:
        raise RuntimeError("名称不合法")
    if IS_WINDOWS and (re.search(r'[<>:"|?*]', name) or name.rstrip(" .") != name):
        raise RuntimeError("名称不合法")
    return name


def _editable_target(root, rel, allow_root=False):
    real_root, target = safe_path(root, rel)
    if target == real_root and not allow_root:
        raise RuntimeError("不能操作项目根目录")
    inside = rel_path(target, real_root).split("/")
    if ".git" in inside:
        raise RuntimeError("不能直接修改 .git 目录")
    return real_root, target


def _unique_path(path, suffix_word="copy"):
    """重名时依次试「名字 copy.ext」「名字 copy 2.ext」（和 VS Code 的「复制」一样）"""
    if not os.path.lexists(path):
        return path
    folder, name = os.path.split(path)
    stem, ext = os.path.splitext(name)
    if name.startswith(".") and stem == name:
        ext = ""
    for n in range(1, 1000):
        label = "%s %s%s" % (stem, suffix_word, "" if n == 1 else " %d" % n)
        candidate = os.path.join(folder, label + ext)
        if not os.path.lexists(candidate):
            return candidate
    raise RuntimeError("同名文件过多")


def _trash_windows(path):
    import ctypes
    from ctypes import wintypes

    class SHFILEOPSTRUCTW(ctypes.Structure):
        _fields_ = [("hwnd", wintypes.HWND), ("wFunc", wintypes.UINT), ("pFrom", wintypes.LPCWSTR),
                    ("pTo", wintypes.LPCWSTR), ("fFlags", ctypes.c_uint16), ("fAnyOperationsAborted", wintypes.BOOL),
                    ("hNameMappings", ctypes.c_void_p), ("lpszProgressTitle", wintypes.LPCWSTR)]

    # FO_DELETE + FOF_ALLOWUNDO（进回收站）| FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI
    op = SHFILEOPSTRUCTW(None, 3, os.path.abspath(path) + "\0", None, 0x40 | 0x10 | 0x04 | 0x400, False, None, None)
    code = ctypes.windll.shell32.SHFileOperationW(ctypes.byref(op))
    if code != 0 or op.fAnyOperationsAborted:
        raise RuntimeError("无法移到回收站（错误 %d）" % code)


def _trash_freedesktop(path):
    """Linux：freedesktop 回收站（~/.local/share/Trash）；跨分区时用该分区根下的 .Trash-<uid>"""
    from urllib.parse import quote as _quote
    candidates = [os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.join(HOME, ".local", "share"), "Trash")]
    try:
        mount = os.path.realpath(path)
        while not os.path.ismount(mount):
            mount = os.path.dirname(mount)
        candidates.append(os.path.join(mount, ".Trash-%d" % os.getuid()))
    except Exception:
        pass
    last = None
    for trash in candidates:
        files, info = os.path.join(trash, "files"), os.path.join(trash, "info")
        try:
            os.makedirs(files, exist_ok=True)
            os.makedirs(info, exist_ok=True)
            name = os.path.basename(path.rstrip("/"))
            target = _unique_path(os.path.join(files, name), "kl")
            stem = os.path.basename(target)
            with open(os.path.join(info, stem + ".trashinfo"), "w", encoding="utf-8") as handle:
                handle.write("[Trash Info]\nPath=%s\nDeletionDate=%s\n" % (_quote(os.path.abspath(path)), time.strftime("%Y-%m-%dT%H:%M:%S")))
            try:
                os.rename(path, target)
            except OSError as exc:
                os.remove(os.path.join(info, stem + ".trashinfo"))
                raise exc
            return
        except OSError as exc:
            last = exc
    raise RuntimeError("无法移到回收站：%s" % (getattr(last, "strerror", None) or last))


def move_to_trash(path):
    if IS_WINDOWS:
        return _trash_windows(path)
    if sys.platform == "darwin":
        trash = os.path.join(HOME, ".Trash")
        name = os.path.basename(path.rstrip("/"))
        target = os.path.join(trash, name)
        if os.path.lexists(target):
            stem, ext = os.path.splitext(name)
            target = os.path.join(trash, "%s %s%s" % (stem, time.strftime("%H.%M.%S"), ext))
            target = _unique_path(target, "kl")
        try:
            os.rename(path, target)
        except OSError as exc:
            if exc.errno == 18:   # EXDEV：外接磁盘上的东西挪不进主废纸篓，退回复制后删除
                if os.path.isdir(path) and not os.path.islink(path):
                    shutil.copytree(path, target, symlinks=True)
                    shutil.rmtree(path)
                else:
                    shutil.copy2(path, target, follow_symlinks=False)
                    os.remove(path)
            else:
                raise RuntimeError("无法移到废纸篓：%s" % exc.strerror)
        return
    return _trash_freedesktop(path)


def _write_text(target, text, base=None, force=False):
    """保存：先核对磁盘上的内容还是不是打开时那份（别人 / Claude 改过就回 conflict），换行和 BOM 照原文件"""
    data = text.encode("utf-8")
    if os.path.exists(target):
        if not os.path.isfile(target):
            raise RuntimeError("不是文件")
        with open(target, "rb") as handle:
            current = handle.read(FILE_EDIT_MAX + 1)
        if len(current) > FILE_EDIT_MAX:
            raise RuntimeError("文件超过 4MB，无法在这里编辑")
        if base and not force and hashlib.sha1(current).hexdigest() != base:
            meta = text_meta(current)
            return {"conflict": True, "sha": meta["sha"], "mtime": int(os.path.getmtime(target) * 1000)}
        if b"\r\n" in current[:200000] and b"\r\n" not in data:
            data = data.replace(b"\n", b"\r\n")
        if current.startswith(UTF8_BOM) and not data.startswith(UTF8_BOM):
            data = UTF8_BOM + data
    if len(data) > FILE_EDIT_MAX:
        raise RuntimeError("文件超过 4MB，无法在这里编辑")
    # 原地写（和 VS Code 一样）：保留权限、属主、扩展属性和硬链接
    with open(target, "wb") as handle:
        handle.write(data)
    return {"sha": hashlib.sha1(data).hexdigest(), "mtime": int(os.path.getmtime(target) * 1000), "size": len(data)}


def fs_op(root, request):
    op = request.get("op")
    rel = request.get("path") or ""
    _GIT_MARKS.clear()   # 改过文件后，列目录时的改动标记要重算
    if op == "write":
        real_root, target = _editable_target(root, rel)
        if not os.path.isdir(os.path.dirname(target)):
            raise RuntimeError("所在目录不存在")
        text = request.get("text")
        if not isinstance(text, str):
            raise RuntimeError("缺少内容")
        out = _write_text(target, text, request.get("base"), bool(request.get("force")))
        out["path"] = rel_path(target, real_root)
        return out
    if op == "create":
        real_root, target = _editable_target(root, rel)
        for part in rel.replace("\\", "/").split("/"):
            if part:
                _check_name(part)
        if os.path.lexists(target):
            raise RuntimeError("已存在同名的文件或文件夹")
        if request.get("kind") == "dir":
            os.makedirs(target)
        else:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "xb") as handle:
                handle.write((request.get("text") or "").encode("utf-8"))
        return {"path": rel_path(target, real_root)}
    if op == "rename":
        real_root, target = _editable_target(root, rel)
        if not os.path.lexists(target):
            raise RuntimeError("文件不存在")
        name = _check_name(request.get("name"))
        dest = os.path.join(os.path.dirname(target), name)
        if os.path.lexists(dest) and os.path.normcase(dest) != os.path.normcase(target) and \
                not (os.path.exists(dest) and os.path.samefile(dest, target)):
            raise RuntimeError("已存在同名的文件或文件夹")
        if os.path.lexists(dest) and dest != target:
            # 只改大小写（不区分大小写的磁盘上「同一个文件」）：先挪到临时名再改回来
            temp = dest + ".kl-rename-%s" % uuid.uuid4().hex[:6]
            os.rename(target, temp)
            os.rename(temp, dest)
        else:
            os.rename(target, dest)
        return {"path": rel_path(dest, real_root)}
    if op in ("move", "copy"):
        real_root, folder = safe_path(root, request.get("dest") or "")
        if not os.path.isdir(folder):
            raise RuntimeError("目标不是文件夹")
        if ".git" in rel_path(folder, real_root).split("/"):
            raise RuntimeError("不能直接修改 .git 目录")
        done = []
        for item in request.get("paths") or ([rel] if rel else []):
            _, source = _editable_target(root, item)
            if not os.path.lexists(source):
                raise RuntimeError("文件不存在：%s" % item)
            dest = os.path.join(folder, os.path.basename(source))
            if op == "move":
                if os.path.dirname(source) == folder:
                    continue
                if os.path.isdir(source) and (folder + os.sep).startswith(source + os.sep):
                    raise RuntimeError("不能把文件夹移到它自己里面")
                if os.path.lexists(dest):
                    raise RuntimeError("目标位置已有同名的文件或文件夹：%s" % os.path.basename(source))
                shutil.move(source, dest)
            else:
                dest = _unique_path(dest)
                if os.path.isdir(source) and not os.path.islink(source):
                    if (folder + os.sep).startswith(source + os.sep):
                        raise RuntimeError("不能把文件夹复制到它自己里面")
                    shutil.copytree(source, dest, symlinks=True)
                else:
                    shutil.copy2(source, dest, follow_symlinks=False)
            done.append(rel_path(dest, real_root))
        return {"paths": done}
    if op == "delete":
        real_root = safe_path(root, "")[0]
        trashed = []
        for item in request.get("paths") or ([rel] if rel else []):
            _, target = _editable_target(root, item)
            if not os.path.lexists(target):
                continue
            move_to_trash(target)
            trashed.append(rel_path(target, real_root))
        return {"trashed": trashed}
    if op == "upload":
        real_root, folder = safe_path(root, request.get("dest") or "")
        if not os.path.isdir(folder):
            raise RuntimeError("目标不是文件夹")
        data = base64.b64decode(request.get("data") or "")
        if len(data) > UPLOAD_MAX:
            raise RuntimeError("文件太大（上限 30MB）")
        target = os.path.join(folder, _check_name(request.get("name")))
        if os.path.lexists(target) and not request.get("overwrite"):
            target = _unique_path(target)
        with open(target, "wb") as handle:
            handle.write(data)
        return {"path": rel_path(target, real_root), "size": len(data)}
    raise RuntimeError("未知操作：%s" % op)


# ---------------------------------------------------------------------------
# 代码 IDE：完整的 Git（概览、提交图、提交详情、暂存 / 区块暂存、提交、推送拉取、分支、合并变基、贮藏、标签、工作树）。
# 会话和分支的对应：这台机器上正在跑的会话各在哪个工作树、哪个分支（只读 .git 里的文件，不起 git 进程）
# ---------------------------------------------------------------------------

GIT_SLOW_OPS = {"push", "pull", "fetch", "remote_branch_delete"}
_REPO_LOCKS = {}
_REPO_LOCKS_GUARD = threading.Lock()
_HEAD_CACHE = {}   # cwd -> (时间, 结果)


def _repo_lock(root):
    with _REPO_LOCKS_GUARD:
        return _REPO_LOCKS.setdefault(os.path.realpath(root), threading.Lock())


def git_head_info(cwd):
    """cwd 所在的工作树和分支：顺着往上找 .git（目录，或工作树里写着 gitdir: 的文件），读 HEAD。3 秒内复用"""
    if not isinstance(cwd, str) or not cwd:
        return None
    hit = _HEAD_CACHE.get(cwd)
    if hit and time.time() - hit[0] < 3:
        return hit[1]
    info = None
    folder = cwd
    for _ in range(40):
        dot = os.path.join(folder, ".git")
        try:
            if os.path.isdir(dot):
                gitdir, linked = dot, False
            elif os.path.isfile(dot):
                with open(dot, encoding="utf-8", errors="replace") as handle:
                    line = handle.read(4096).strip()
                if not line.startswith("gitdir:"):
                    break
                gitdir = line[7:].strip()
                if not os.path.isabs(gitdir):
                    gitdir = os.path.normpath(os.path.join(folder, gitdir))
                linked = True
            else:
                parent = os.path.dirname(folder)
                if parent == folder:
                    break
                folder = parent
                continue
            common = gitdir
            if os.path.isfile(os.path.join(gitdir, "commondir")):
                with open(os.path.join(gitdir, "commondir"), encoding="utf-8", errors="replace") as handle:
                    common = os.path.normpath(os.path.join(gitdir, handle.read().strip()))
            with open(os.path.join(gitdir, "HEAD"), encoding="utf-8", errors="replace") as handle:
                head = handle.read(512).strip()
            branch = head[16:] if head.startswith("ref: refs/heads/") else None
            info = {"worktree": folder, "common": os.path.realpath(common), "branch": branch,
                    "detached": None if branch else head[:12], "linked": linked}
        except OSError:
            info = None
        break
    _HEAD_CACHE[cwd] = (time.time(), info)
    return info


def annotate_branches(snapshots):
    """会话快照里带上分支：列表、对话页标题下面能看出每个会话在哪个分支上干活"""
    for snap in snapshots:
        info = git_head_info(snap.get("cwd"))
        if info:
            snap["branch"] = info["branch"] or ("(%s)" % info["detached"] if info["detached"] else None)
            if info["linked"]:
                snap["worktree"] = info["worktree"]


def git_env(root):
    env = dict(os.environ, GIT_PAGER="cat", LC_ALL="C.UTF-8", GIT_TERMINAL_PROMPT="0", GCM_INTERACTIVE="never",
               GIT_EDITOR=":", GIT_SEQUENCE_EDITOR=":", GIT_MERGE_AUTOEDIT="no")
    # 推送 / 拉取不能停下来问密码（手机上没处输）：ssh 用 BatchMode，要口令就直接失败。用户自己配了 ssh 命令的不动
    if "GIT_SSH_COMMAND" not in os.environ and "GIT_SSH" not in os.environ:
        try:
            configured = subprocess.run(["git", "-C", root, "config", "--get", "core.sshCommand"], stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, timeout=5, **_no_window()).stdout.strip()
        except Exception:
            configured = b""
        if not configured:
            env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=15"
    return env


def _no_window():
    return {"creationflags": 0x08000000} if IS_WINDOWS else {}


GIT_ERRORS = [
    (r"Please tell me who you are|empty ident name|unable to auto-detect email",
     "未设置提交者身份：请先在这台电脑上运行 git config --global user.name 和 user.email"),
    (r"could not read (Username|Password)|terminal prompts disabled|Authentication failed|Permission denied \(publickey|"
     r"Host key verification failed|could not read from remote repository",
     "需要身份验证，但无法在这里输入密码：请在这台电脑上配置 SSH 密钥（ssh-agent）或 Git 凭据助手"),
    (r"\[rejected\].*\((fetch first|non-fast-forward)\)|Updates were rejected",
     "远端有新的提交，推送被拒绝：请先拉取"),
    (r"would be overwritten by (merge|checkout)|Please commit your changes or stash them",
     "本地有未提交的改动会被覆盖：请先提交或贮藏"),
    (r"is already (checked out|used by worktree) at '([^']+)'", "该分支已在另一个工作树中检出：{1}"),
    (r"Need to specify how to reconcile divergent branches", "本地与远端已分叉：请选择「拉取（合并）」或「拉取（变基）」"),
    (r"nothing to commit|no changes added to commit", "没有可提交的改动"),
    (r"There is no tracking information for the current branch", "当前分支未关联远端分支"),
    (r"does not have any commits yet|unknown revision or path not in the working tree.*HEAD", "仓库还没有任何提交"),
    (r"not fully merged", "该分支还有未合并的提交：确认不要了可以选择强制删除"),
    (r"Could not resolve host|unable to access|Connection timed out|Network is unreachable|Operation timed out",
     "无法连接远端仓库：请检查这台电脑的网络"),
    (r"A branch named '([^']+)' already exists|already exists", "已存在同名的分支或标签"),
    (r"is not a valid branch name|not a valid ref name|is not a valid tag name", "名称不合法"),
]


def git_error(stderr, stdout=""):
    text = (stderr or "").strip() or (stdout or "").strip()
    for pattern, message in GIT_ERRORS:
        match = re.search(pattern, text, re.IGNORECASE | re.DOTALL)
        if match:
            if "{1}" in message:
                message = message.replace("{1}", match.group(2) if match.lastindex and match.lastindex >= 2 else "")
            return message
    lines = [l for l in text.splitlines() if l.strip() and not l.startswith("hint:")]
    return (lines[-1] if lines else "git 失败")[:400]


class GitFailed(RuntimeError):
    def __init__(self, message, output=""):
        RuntimeError.__init__(self, message)
        self.output = output


def git_run(root, args, timeout=60, stdin=None, limit=2000000, check=True):
    """会改仓库的 git：带上不交互的环境、完整的错误输出（冲突时要把文件列出来）"""
    out = subprocess.run(["git", "-c", "core.quotePath=false", "-c", "color.ui=false", "-C", root] + args,
                         input=stdin.encode("utf-8") if isinstance(stdin, str) else stdin,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, env=git_env(root), **_no_window())
    stdout = out.stdout[:limit].decode("utf-8", "replace")
    stderr = out.stderr[:20000].decode("utf-8", "replace")
    if check and out.returncode != 0:
        raise GitFailed(git_error(stderr, stdout), (stdout + "\n" + stderr).strip()[-4000:])
    return stdout, stderr, out.returncode


def git_read(root, args, timeout=20, limit=4000000):
    return git_run(root, args, timeout=timeout, limit=limit)[0]


def _repo_root(cwd):
    if not shutil.which("git"):
        raise RuntimeError("这台机器上没有 git")
    if not is_abs_path(cwd) or not os.path.isdir(cwd):
        raise RuntimeError("会话已结束或没有工作目录")
    try:
        return run_git(cwd, ["rev-parse", "--show-toplevel"]).strip()
    except Exception:
        raise RuntimeError("不是 git 仓库")


def _git_dir(root):
    path = run_git(root, ["rev-parse", "--git-dir"]).strip()
    return path if os.path.isabs(path) else os.path.normpath(os.path.join(root, path))


def _common_dir(root):
    """几个工作树共用的那个 .git（分支、标签都在这里）"""
    path = run_git(root, ["rev-parse", "--git-common-dir"]).strip()
    return os.path.realpath(path if os.path.isabs(path) else os.path.join(root, path))


def _redact_url(url):
    """远端地址里的账号密码（https://user:token@host）不往外给"""
    return re.sub(r"(://)[^/@\s]+@", r"\1", url or "")


def _split_z(text):
    return [part for part in text.split("\0")]


def _parse_status_v2(text):
    """git status --porcelain=v2 -z：暂存区 / 工作区 / 未跟踪 / 冲突分开列"""
    head = {"branch": None, "oid": None, "upstream": None, "ahead": 0, "behind": 0}
    staged, unstaged, untracked, conflicts = [], [], [], []
    parts = _split_z(text)
    i = 0
    while i < len(parts):
        line = parts[i]
        i += 1
        if not line:
            continue
        if line.startswith("# "):
            key, _, value = line[2:].partition(" ")
            if key == "branch.head":
                head["branch"] = None if value == "(detached)" else value
            elif key == "branch.oid":
                head["oid"] = None if value == "(initial)" else value
            elif key == "branch.upstream":
                head["upstream"] = value
            elif key == "branch.ab":
                ab = value.split()
                if len(ab) == 2:
                    head["ahead"], head["behind"] = int(ab[0].lstrip("+")), int(ab[1].lstrip("-"))
            continue
        kind = line[0]
        if kind == "?":
            untracked.append({"path": line[2:], "status": "?"})
        elif kind == "1":
            fields = line.split(" ", 8)
            xy, path = fields[1], fields[8]
            if xy[0] != ".":
                staged.append({"path": path, "status": xy[0]})
            if xy[1] != ".":
                unstaged.append({"path": path, "status": xy[1]})
        elif kind == "2":
            fields = line.split(" ", 9)
            xy, path = fields[1], fields[9]
            orig = parts[i] if i < len(parts) else ""
            i += 1
            if xy[0] != ".":
                staged.append({"path": path, "status": xy[0], "oldPath": orig})
            if xy[1] != ".":
                unstaged.append({"path": path, "status": xy[1], "oldPath": orig})
        elif kind == "u":
            fields = line.split(" ", 10)
            conflicts.append({"path": fields[10], "status": "U", "how": fields[1]})
    return head, staged, unstaged, untracked, conflicts


def _numstat_map(text):
    """--numstat -z：普通的一段「增\t删\t路径」，改名的是「增\t删\t」后面跟旧路径、新路径两段"""
    stats = {}
    parts = _split_z(text)
    i = 0
    while i < len(parts):
        line = parts[i]
        i += 1
        if not line:
            continue
        fields = line.split("\t", 2)
        if len(fields) < 3:
            continue
        path = fields[2]
        if path == "" and i + 1 < len(parts):
            path = parts[i + 1]
            i += 2
        stats[path] = (int(fields[0]) if fields[0].isdigit() else 0, int(fields[1]) if fields[1].isdigit() else 0, fields[0] == "-")
    return stats


def _apply_stats(items, stats):
    for item in items:
        hit = stats.get(item["path"])
        if hit:
            item["add"], item["del"] = hit[0], hit[1]
            if hit[2]:
                item["binary"] = True


def _repo_state(git_dir):
    """进行到一半的操作：合并 / 变基 / 拣选 / 还原（界面上要给「继续」「放弃」）"""
    if os.path.isdir(os.path.join(git_dir, "rebase-merge")) or os.path.isdir(os.path.join(git_dir, "rebase-apply")):
        return "rebase"
    for name, state in (("MERGE_HEAD", "merge"), ("CHERRY_PICK_HEAD", "cherry-pick"), ("REVERT_HEAD", "revert")):
        if os.path.exists(os.path.join(git_dir, name)):
            return state
    return None


def repo_status(root):
    text = git_read(root, ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"])
    head, staged, unstaged, untracked, conflicts = _parse_status_v2(text)
    if head["oid"]:
        _apply_stats(staged, _numstat_map(git_read(root, ["diff", "--cached", "--numstat", "-z", "-M"])))
    _apply_stats(unstaged, _numstat_map(git_read(root, ["diff", "--numstat", "-z"])))
    git_dir = _git_dir(root)
    out = dict(head)
    out.update({"staged": staged[:2000], "unstaged": unstaged[:2000], "untracked": untracked[:2000],
                "untrackedCount": len(untracked), "conflicts": conflicts, "state": _repo_state(git_dir)})
    if out["state"] == "merge":
        try:
            with open(os.path.join(git_dir, "MERGE_MSG"), encoding="utf-8", errors="replace") as handle:
                out["mergeMessage"] = handle.read(4000).split("\n#")[0].strip()
        except OSError:
            pass
    return out


def _ref_rows(root):
    fmt = "%(refname)%00%(objectname)%00%(*objectname)%00%(upstream:short)%00%(upstream:track)%00%(committerdate:unix)%00%(subject)%00%(HEAD)%00%(worktreepath)"
    rows = []
    for line in git_read(root, ["for-each-ref", "--format=" + fmt, "refs/heads", "refs/remotes", "refs/tags"]).splitlines():
        f = line.split("\0")
        if len(f) < 9:
            continue
        rows.append({"ref": f[0], "hash": f[2] or f[1], "upstream": f[3] or None, "track": f[4], "ts": int(f[5]) * 1000 if f[5].isdigit() else None,
                     "subject": f[6][:200], "current": f[7] == "*", "worktree": f[8] or None})
    return rows


def _worktrees(root):
    trees, current = [], {}
    for line in run_git(root, ["worktree", "list", "--porcelain"]).splitlines() + [""]:
        if not line:
            if current.get("worktree"):
                branch = current.get("branch", "")
                trees.append({"path": current["worktree"], "head": (current.get("HEAD") or "")[:12],
                              "branch": branch[len("refs/heads/"):] if branch.startswith("refs/heads/") else None,
                              "detached": "detached" in current, "locked": "locked" in current, "prunable": "prunable" in current,
                              "bare": "bare" in current})
            current = {}
        else:
            key, _, value = line.partition(" ")
            current[key] = value if value else True
    if trees:
        trees[0]["main"] = True
    return trees


def repo_overview(cwd, sessions=None):
    """仓库总览：状态、本地 / 远端分支、标签、贮藏、工作树，以及这台机器上每个会话在哪个工作树、哪个分支"""
    root = _repo_root(cwd)
    status = repo_status(root)
    remotes = []
    for line in git_read(root, ["remote", "-v"]).splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[2] == "(fetch)":
            if not any(r["name"] == parts[0] for r in remotes):
                remotes.append({"name": parts[0], "url": _redact_url(parts[1])})
    remote_names = [r["name"] for r in remotes]
    local, remote_branches, tags = [], [], []
    for row in _ref_rows(root):
        ref = row["ref"]
        if ref.startswith("refs/heads/"):
            ahead = behind = 0
            gone = "gone" in row["track"]
            for m in re.finditer(r"(ahead|behind) (\d+)", row["track"]):
                if m.group(1) == "ahead":
                    ahead = int(m.group(2))
                else:
                    behind = int(m.group(2))
            local.append({"name": ref[11:], "hash": row["hash"][:12], "upstream": row["upstream"], "ahead": ahead, "behind": behind,
                          "gone": gone, "ts": row["ts"], "subject": row["subject"], "current": row["current"], "worktree": row["worktree"]})
        elif ref.startswith("refs/remotes/"):
            name = ref[13:]
            if name.endswith("/HEAD"):
                continue
            remote = next((r for r in remote_names if name.startswith(r + "/")), name.split("/")[0])
            remote_branches.append({"name": name, "remote": remote, "branch": name[len(remote) + 1:], "hash": row["hash"][:12],
                                    "ts": row["ts"], "subject": row["subject"]})
        elif ref.startswith("refs/tags/"):
            tags.append({"name": ref[10:], "hash": row["hash"][:12], "ts": row["ts"], "subject": row["subject"]})
    local.sort(key=lambda b: (not b["current"], -(b["ts"] or 0)))
    remote_branches.sort(key=lambda b: (b["remote"], -(b["ts"] or 0)))
    tags.sort(key=lambda t: -(t["ts"] or 0))
    stashes = []
    try:
        for line in git_read(root, ["stash", "list", "--format=%gd%x00%H%x00%ct%x00%gs"]).splitlines():
            f = line.split("\0")
            if len(f) == 4:
                stashes.append({"ref": f[0], "hash": f[1][:12], "ts": int(f[2]) * 1000 if f[2].isdigit() else None, "title": f[3]})
    except Exception:
        pass
    trees = _worktrees(root)
    common = _common_dir(root)
    mapped = []
    for item in sessions or []:
        info = git_head_info(item.get("cwd"))
        if info and info["common"] == common:
            mapped.append({"sessionId": item.get("sessionId"), "worktree": info["worktree"], "branch": info["branch"],
                           "detached": info["detached"]})
    identity = {}
    for key in ("user.name", "user.email"):
        try:
            identity[key.split(".")[1]] = run_git(root, ["config", "--get", key]).strip()
        except Exception:
            identity[key.split(".")[1]] = ""
    status.update({"repo": root, "name": os.path.basename(root), "remotes": remotes, "branches": local[:500],
                   "remoteBranches": remote_branches[:800], "tags": tags[:500], "stashes": stashes[:200], "worktrees": trees,
                   "sessions": mapped, "identity": identity})
    return status


def _parse_refs(decoration, remote_names):
    refs = []
    for part in [p.strip() for p in (decoration or "").split(",") if p.strip()]:
        if part.startswith("HEAD -> "):
            refs.append({"name": part[8:], "type": "branch", "current": True})
        elif part == "HEAD":
            refs.append({"name": "HEAD", "type": "head", "current": True})
        elif part.startswith("tag: "):
            refs.append({"name": part[5:], "type": "tag"})
        elif part.endswith("/HEAD"):
            continue
        elif any(part.startswith(r + "/") for r in remote_names):
            refs.append({"name": part, "type": "remote"})
        else:
            refs.append({"name": part, "type": "branch"})
    return refs


def layout_graph(commits):
    """提交图：给每个提交排列，算出这一行要画的线段（列号 0 起，y 取 0 上沿 / 1 圆点 / 2 下沿，最后一位是颜色）。
    线在服务端算好，iPhone / Mac / Windows / Linux 照着画就行，各端不用各写一遍"""
    lanes = []         # 每列在等哪个提交：[hash, 颜色] 或 None
    next_color = 0
    width = 0
    for commit in commits:
        h = commit["hash"]
        cols = [i for i, lane in enumerate(lanes) if lane and lane[0] == h]
        if cols:
            col = cols[0]
            color = lanes[col][1]
        else:
            col = next((i for i, lane in enumerate(lanes) if lane is None), len(lanes))
            if col == len(lanes):
                lanes.append(None)
            color = next_color
            next_color += 1
        segs = []
        for i, lane in enumerate(lanes):
            if lane is None:
                continue
            if i == col and cols:
                segs.append([col, 0, col, 1, color])
            elif lane[0] == h:
                segs.append([i, 0, col, 1, lane[1]])        # 别的分支在这里汇合
            else:
                segs.append([i, 0, i, 2, lane[1]])          # 穿过这一行
        for i in cols[1:]:
            lanes[i] = None
        parents = commit["parents"]
        if parents:
            lanes[col] = [parents[0], color]
            segs.append([col, 1, col, 2, color])
            for p in parents[1:]:
                existing = next((i for i, lane in enumerate(lanes) if lane and lane[0] == p), None)
                if existing is not None:
                    segs.append([col, 1, existing, 2, lanes[existing][1]])
                    continue
                slot = next((i for i, lane in enumerate(lanes) if lane is None), len(lanes))
                if slot == len(lanes):
                    lanes.append(None)
                lanes[slot] = [p, next_color]
                segs.append([col, 1, slot, 2, next_color])
                next_color += 1
        else:
            lanes[col] = None
        while lanes and lanes[-1] is None:
            lanes.pop()
        width = max(width, col + 1, len(lanes))
        commit["graph"] = {"col": col, "color": color % 8, "segs": [s[:4] + [s[4] % 8] for s in segs]}
    return width


def repo_log(cwd, request):
    root = _repo_root(cwd)
    skip = max(0, int(request.get("skip") or 0))
    limit = max(1, min(500, int(request.get("limit") or 200)))
    args = ["log", "--topo-order", "-z", "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s", "-n", str(skip + limit)]
    query = (request.get("q") or "").strip()
    if query:
        args += ["-i", "--grep=" + query] if not re.match(r"^[0-9a-f]{6,40}$", query) else []
    ref = request.get("ref") or ""
    if ref and ref != "all":
        if ref.startswith("-"):
            raise RuntimeError("名称不合法")
        args.append(ref)
    else:
        args += ["--branches", "--remotes", "--tags", "HEAD"]
    path = request.get("path")
    if path:
        safe_path(root, path)
        args += ["--follow", "--", path] if ref and ref != "all" else ["--", path]
    try:
        text = git_read(root, args, timeout=30)
    except GitFailed as exc:
        if "does not have any commits" in exc.output or "unknown revision" in exc.output:
            return {"commits": [], "width": 0, "more": False}
        raise
    remote_names = [l.strip() for l in run_git(root, ["remote"]).splitlines() if l.strip()]
    commits = []
    for record in text.split("\0"):
        record = record.strip("\n")
        if not record:
            continue
        f = record.split("\x1f")
        if len(f) < 7:
            continue
        if query and re.match(r"^[0-9a-f]{6,40}$", query) and not f[0].startswith(query):
            continue
        commits.append({"hash": f[0], "short": f[0][:8], "parents": [p for p in f[1].split() if p], "author": f[2], "email": f[3],
                        "ts": int(f[4]) * 1000 if f[4].isdigit() else None, "refs": _parse_refs(f[5], remote_names), "subject": f[6][:300]})
    # 筛了路径 / 搜索时提交之间不连续，画图意义不大：只在看整棵树时画
    width = layout_graph(commits) if not path and not query else 0
    return {"commits": commits[skip:], "width": width, "more": len(commits) >= skip + limit}


def _check_rev(rev):
    if not isinstance(rev, str) or not rev or rev.startswith("-") or not re.match(r"^[\w./@{}~^:+-]+$", rev):
        raise RuntimeError("提交号不合法")
    return rev


def repo_commit_info(cwd, rev):
    root = _repo_root(cwd)
    rev = _check_rev(rev)
    text = git_read(root, ["show", "-s", "-z", "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ce%x1f%ct%x1f%D%x1f%B", rev])
    f = text.rstrip("\0").split("\x1f")
    if len(f) < 10:
        raise RuntimeError("找不到这个提交")
    parents = f[1].split()
    base = parents[0] if parents else None
    diff_args = ["diff-tree", "-r", "-M", "-z", "--no-commit-id"]
    names = git_read(root, diff_args + ["--name-status"] + ([base, f[0]] if base else ["--root", f[0]]))
    stats = _numstat_map(git_read(root, diff_args + ["--numstat"] + ([base, f[0]] if base else ["--root", f[0]])))
    files = []
    parts = _split_z(names)
    i = 0
    while i < len(parts):
        code = parts[i]
        i += 1
        if not code:
            continue
        if code[0] in "RC":
            old, new = parts[i], parts[i + 1]
            i += 2
            files.append({"path": new, "oldPath": old, "status": code[0]})
        else:
            files.append({"path": parts[i], "status": code[0]})
            i += 1
    _apply_stats(files, stats)
    remote_names = [l.strip() for l in run_git(root, ["remote"]).splitlines() if l.strip()]
    branches = [l.strip().lstrip("* ").strip() for l in git_read(root, ["branch", "-a", "--contains", f[0], "--format=%(refname:short)"]).splitlines() if l.strip()][:30]
    return {"hash": f[0], "parents": parents, "author": f[2], "email": f[3], "ts": int(f[4]) * 1000 if f[4].isdigit() else None,
            "committer": f[5], "committerEmail": f[6], "committedAt": int(f[7]) * 1000 if f[7].isdigit() else None,
            "refs": _parse_refs(f[8], remote_names), "fullMessage": f[9].strip(), "files": files[:3000], "branches": branches}


def _show_blob(root, spec, limit=FILE_EDIT_MAX):
    try:
        out = subprocess.run(["git", "-C", root, "show", spec], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=20,
                             env=git_env(root), **_no_window())
    except subprocess.TimeoutExpired:
        return None, False
    if out.returncode != 0:
        return "", False     # 这一边没有这个文件（新增 / 删除）
    data = out.stdout
    if b"\0" in data[:8000]:
        return None, True
    if len(data) > limit:
        return None, False
    return data.decode("utf-8", "replace").lstrip("﻿"), False


def repo_diff(cwd, request):
    """一个文件的改动：统一格式的 diff（区块暂存用）+ 两边的完整内容（并排对比、语法高亮用）"""
    root = _repo_root(cwd)
    path = request.get("path") or ""
    safe_path(root, path)
    mode = request.get("mode") or "unstaged"
    old_path = request.get("oldPath") or path
    context = ["-U%d" % max(0, min(50, int(request.get("context") or 3)))]
    if mode == "commit":
        rev = _check_rev(request.get("commit"))
        parents = git_read(root, ["rev-list", "--parents", "-n", "1", rev]).split()[1:]
        base = parents[0] if parents else None
        diff = git_read(root, ["diff", "-M"] + context + ([base, rev] if base else ["--root", rev]) + ["--", old_path, path]) if base else \
            git_read(root, ["show", "--format=", "-M"] + context + [rev, "--", path])
        original, binary_a = _show_blob(root, "%s:%s" % (base, old_path)) if base else ("", False)
        modified, binary_b = _show_blob(root, "%s:%s" % (rev, path))
    elif mode == "staged":
        diff = git_read(root, ["diff", "--cached", "-M"] + context + ["--", old_path, path])
        original, binary_a = _show_blob(root, "HEAD:%s" % old_path)
        modified, binary_b = _show_blob(root, ":%s" % path)
    elif mode == "untracked":
        diff = git_diff(root, path)
        original, binary_a = "", False
        modified, binary_b = _read_worktree(root, path)
    else:
        diff = git_read(root, ["diff"] + context + ["--", path])
        original, binary_a = _show_blob(root, ":%s" % path)
        modified, binary_b = _read_worktree(root, path)
    out = {"diff": diff, "path": path, "mode": mode, "hunks": _hunk_headers(diff)}
    if binary_a or binary_b:
        out["binary"] = True
    elif original is not None and modified is not None:
        out["original"], out["modified"] = original, modified
    return out


def _read_worktree(root, path):
    _, target = safe_path(root, path)
    if not os.path.isfile(target):
        return "", False
    if os.path.getsize(target) > FILE_EDIT_MAX:
        return None, False
    with open(target, "rb") as handle:
        data = handle.read()
    if b"\0" in data[:8000]:
        return None, True
    return data.decode("utf-8", "replace").lstrip("﻿"), False


def _split_hunks(diff):
    """统一格式 diff → (文件头, [区块文字])"""
    lines = diff.split("\n")
    header, hunks, current = [], [], None
    for line in lines:
        if line.startswith("@@"):
            if current is not None:
                hunks.append(current)
            current = [line]
        elif current is None:
            header.append(line)
        else:
            current.append(line)
    if current is not None:
        hunks.append(current)
    # 末尾的空行是 split 出来的，不属于区块
    for hunk in hunks:
        while hunk and hunk[-1] == "":
            hunk.pop()
    return header, hunks


def _hunk_headers(diff):
    return [hunk[0] for hunk in _split_hunks(diff)[1]]


def _apply_hunk(root, path, index, header_line, action):
    """暂存 / 取消暂存 / 丢弃一个区块：取当前的 diff，核对区块头没变（文件刚被改过就拒绝，免得套错地方），再 git apply"""
    staged = action == "unstage"
    diff = git_read(root, ["diff"] + (["--cached"] if staged else []) + ["-U3", "--", path])
    header, hunks = _split_hunks(diff)
    if not isinstance(index, int) or index < 0 or index >= len(hunks) or hunks[index][0] != header_line:
        raise RuntimeError("文件刚刚有变化，请刷新后重试")
    patch = "\n".join(header + hunks[index]) + "\n"
    args = ["apply", "--whitespace=nowarn", "--recount"]
    if action == "stage":
        args.append("--cached")
    elif action == "unstage":
        args += ["--cached", "-R"]
    else:
        args.append("-R")
    git_run(root, args + ["-"], stdin=patch)


def _paths(request):
    paths = request.get("paths")
    if isinstance(paths, str):
        paths = [paths]
    paths = [p for p in (paths or []) if isinstance(p, str) and p]
    if not paths:
        raise RuntimeError("缺少文件")
    return paths


def _check_branch_name(name):
    name = (name or "").strip()
    if not name or name.startswith("-") or " " in name:
        raise RuntimeError("名称不合法")
    return name


def repo_op(cwd, request):
    """会改仓库的操作；同一个仓库一次只做一个（index.lock 不会撞）"""
    root = _repo_root(cwd)
    op = request.get("op")
    with _repo_lock(_common_dir(root)):
        out = _repo_op(root, op, request) or {}
    _GIT_MARKS.clear()
    _QUICK_GIT.clear()
    return out


def _repo_op(root, op, request):
    slow = 180
    if op == "stage":
        paths = _paths(request)
        for p in paths:
            safe_path(root, p)
        git_run(root, ["add", "-A", "--"] + paths)
    elif op == "stage_all":
        git_run(root, ["add", "-A"])
    elif op == "unstage":
        paths = _paths(request)
        if subprocess.run(["git", "-C", root, "rev-parse", "-q", "--verify", "HEAD"], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL, **_no_window()).returncode == 0:
            git_run(root, ["reset", "-q", "HEAD", "--"] + paths)
        else:
            git_run(root, ["rm", "--cached", "-r", "-q", "--"] + paths)
    elif op == "unstage_all":
        git_run(root, ["reset", "-q"])
    elif op == "discard":
        # 丢弃工作区里的改动：跟踪的文件恢复成暂存区里的样子；未跟踪的新文件移到废纸篓（还能找回）
        tracked, fresh = [], []
        for p in _paths(request):
            safe_path(root, p)
            known = subprocess.run(["git", "-C", root, "ls-files", "--error-unmatch", "--", p], stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, **_no_window()).returncode == 0
            (tracked if known else fresh).append(p)
        if tracked:
            git_run(root, ["checkout", "-q", "--"] + tracked)
        for p in fresh:
            _, target = _editable_target(root, p)
            if os.path.lexists(target):
                move_to_trash(target)
        return {"trashed": fresh}
    elif op in ("stage_hunk", "unstage_hunk", "discard_hunk"):
        path = request.get("path") or ""
        safe_path(root, path)
        _apply_hunk(root, path, request.get("hunk"), request.get("header"), op.split("_")[0])
    elif op == "resolve":
        path = request.get("path") or ""
        safe_path(root, path)
        side = request.get("side")
        if side in ("ours", "theirs"):
            git_run(root, ["checkout", "--" + side, "--", path])
        git_run(root, ["add", "--", path])
    elif op == "commit":
        message = (request.get("message") or "").strip()
        amend = bool(request.get("amend"))
        if not message and not amend:
            raise RuntimeError("请填写提交信息")
        if request.get("all"):
            git_run(root, ["add", "-A"])
        args = ["commit", "-q"]
        if amend:
            args.append("--amend")
            if not message:
                args.append("--no-edit")
        if message:
            args += ["-F", "-"]
        if request.get("signoff"):
            args.append("--signoff")
        git_run(root, args, stdin=message or None, timeout=slow)
        return {"hash": run_git(root, ["rev-parse", "HEAD"]).strip()}
    elif op == "push":
        branch = run_git(root, ["rev-parse", "--abbrev-ref", "HEAD"]).strip()
        remote = request.get("remote")
        args = ["push", "--porcelain"]
        if request.get("force"):
            args.append("--force-with-lease")
        if request.get("tags"):
            args.append("--follow-tags")
        upstream = subprocess.run(["git", "-C", root, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, **_no_window())
        if upstream.returncode != 0 or remote:
            remotes = [l.strip() for l in run_git(root, ["remote"]).splitlines() if l.strip()]
            if not remotes:
                raise RuntimeError("还没有配置远端仓库")
            remote = remote if remote in remotes else ("origin" if "origin" in remotes else remotes[0])
            if branch == "HEAD":
                raise RuntimeError("当前不在任何分支上（游离 HEAD），无法推送")
            args += ["-u", remote, branch]
        stdout, stderr, _ = git_run(root, args, timeout=slow)
        return {"output": (stdout + stderr).strip()[-2000:]}
    elif op == "pull":
        args = ["pull", "--no-edit"]
        rebase = request.get("rebase")
        if rebase is True:
            args.append("--rebase")
        elif rebase is False:
            args.append("--no-rebase")
        else:
            try:
                configured = run_git(root, ["config", "--get", "pull.rebase"]).strip()
            except Exception:
                configured = ""
            if not configured:
                args.append("--no-rebase")
        stdout, stderr, code = git_run(root, args, timeout=slow, check=False)
        if code != 0:
            state = _repo_state(_git_dir(root))
            if state:
                return {"conflict": True, "state": state, "output": (stdout + stderr).strip()[-3000:]}
            raise GitFailed(git_error(stderr, stdout), (stdout + stderr)[-4000:])
        return {"output": (stdout + stderr).strip()[-2000:]}
    elif op == "fetch":
        args = ["fetch", "--all", "--prune"]
        if request.get("tags", True):
            args.append("--tags")
        stdout, stderr, _ = git_run(root, args, timeout=slow)
        return {"output": (stdout + stderr).strip()[-2000:]}
    elif op == "checkout":
        target = request.get("ref") or ""
        if request.get("remote"):
            # 远端分支：本地没有同名分支就建一个跟踪它的；有就直接切过去
            name = target.split("/", 1)[1] if "/" in target else target
            exists = subprocess.run(["git", "-C", root, "show-ref", "--verify", "-q", "refs/heads/" + name], **_no_window()).returncode == 0
            git_run(root, ["checkout", "-q", name] if exists else ["checkout", "-q", "-b", name, "--track", _check_rev(target)])
        elif request.get("detach"):
            git_run(root, ["checkout", "-q", "--detach", _check_rev(target)])
        else:
            git_run(root, ["checkout", "-q", _check_branch_name(target)])
    elif op == "branch_create":
        name = _check_branch_name(request.get("name"))
        base = _check_rev(request.get("from") or "HEAD")
        if request.get("checkout", True):
            git_run(root, ["checkout", "-q", "-b", name, base])
        else:
            git_run(root, ["branch", name, base])
    elif op == "branch_delete":
        name = _check_branch_name(request.get("name"))
        git_run(root, ["branch", "-D" if request.get("force") else "-d", name])
    elif op == "branch_rename":
        git_run(root, ["branch", "-m", _check_branch_name(request.get("name")), _check_branch_name(request.get("to"))])
    elif op == "remote_branch_delete":
        remote, branch = _check_branch_name(request.get("remote")), _check_branch_name(request.get("branch"))
        git_run(root, ["push", remote, "--delete", branch], timeout=slow)
    elif op == "set_upstream":
        git_run(root, ["branch", "--set-upstream-to=" + _check_rev(request.get("upstream")), _check_branch_name(request.get("name"))])
    elif op in ("merge", "rebase", "cherry_pick", "revert"):
        rev = _check_rev(request.get("ref"))
        args = {"merge": ["merge", "--no-edit"] + (["--no-ff"] if request.get("noff") else []) + (["--squash"] if request.get("squash") else []),
                "rebase": ["rebase"], "cherry_pick": ["cherry-pick"], "revert": ["revert", "--no-edit"]}[op] + [rev]
        stdout, stderr, code = git_run(root, args, timeout=slow, check=False)
        if code != 0:
            state = _repo_state(_git_dir(root))
            if state:
                return {"conflict": True, "state": state, "output": (stdout + stderr).strip()[-3000:]}
            raise GitFailed(git_error(stderr, stdout), (stdout + stderr)[-4000:])
        return {"output": (stdout + stderr).strip()[-2000:]}
    elif op in ("abort", "continue", "skip"):
        state = _repo_state(_git_dir(root))
        if not state:
            raise RuntimeError("当前没有进行中的合并或变基")
        if op == "skip" and state not in ("rebase", "cherry-pick", "revert"):
            raise RuntimeError("当前操作不能跳过")
        if op == "continue" and state == "merge":
            git_run(root, ["commit", "--no-edit", "-q"], timeout=slow)
        else:
            stdout, stderr, code = git_run(root, [state, "--" + op], timeout=slow, check=False)
            if code != 0:
                next_state = _repo_state(_git_dir(root))
                if next_state and op != "abort":
                    return {"conflict": True, "state": next_state, "output": (stdout + stderr).strip()[-3000:]}
                raise GitFailed(git_error(stderr, stdout), (stdout + stderr)[-4000:])
    elif op == "reset":
        mode = request.get("mode") or "mixed"
        if mode not in ("soft", "mixed", "hard"):
            raise RuntimeError("未知的重置方式")
        git_run(root, ["reset", "-q", "--" + mode, _check_rev(request.get("ref"))])
    elif op == "stash_save":
        args = ["stash", "push"]
        if request.get("untracked"):
            args.append("--include-untracked")
        if request.get("staged"):
            args.append("--staged")
        message = (request.get("message") or "").strip()
        if message:
            args += ["-m", message]
        stdout, stderr, _ = git_run(root, args)
        if "No local changes to save" in stdout + stderr:
            raise RuntimeError("没有可以贮藏的改动")
    elif op in ("stash_apply", "stash_pop", "stash_drop"):
        ref = request.get("ref") or "stash@{0}"
        if not re.match(r"^stash@\{\d+\}$", ref):
            raise RuntimeError("贮藏不存在")
        stdout, stderr, code = git_run(root, ["stash", op[6:], ref], check=False)
        if code != 0:
            if "CONFLICT" in stdout + stderr:
                return {"conflict": True, "state": None, "output": (stdout + stderr).strip()[-3000:]}
            raise GitFailed(git_error(stderr, stdout), (stdout + stderr)[-4000:])
    elif op == "tag_create":
        name = _check_branch_name(request.get("name"))
        message = (request.get("message") or "").strip()
        rev = _check_rev(request.get("ref") or "HEAD")
        git_run(root, ["tag", "-a", name, "-F", "-", rev] if message else ["tag", name, rev], stdin=message or None)
    elif op == "tag_delete":
        git_run(root, ["tag", "-d", _check_branch_name(request.get("name"))])
    elif op == "worktree_add":
        name = _check_branch_name(request.get("branch"))
        base = os.path.join(os.path.dirname(root), os.path.basename(root) + "-worktrees")
        path = os.path.join(base, re.sub(r"[^\w.-]+", "-", name).strip("-") or "worktree")
        if os.path.exists(path):
            raise RuntimeError("目录已存在：%s" % path)
        os.makedirs(base, exist_ok=True)
        exists = subprocess.run(["git", "-C", root, "show-ref", "--verify", "-q", "refs/heads/" + name], **_no_window()).returncode == 0
        git_run(root, ["worktree", "add", path, name] if exists else ["worktree", "add", "-b", name, path, _check_rev(request.get("from") or "HEAD")])
        return {"path": path, "branch": name}
    elif op == "worktree_remove":
        path = request.get("path") or ""
        trees = _worktrees(root)
        if not any(os.path.realpath(t["path"]) == os.path.realpath(path) and not t.get("main") for t in trees):
            raise RuntimeError("只能移除附加的工作树")
        git_run(root, ["worktree", "remove"] + (["--force"] if request.get("force") else []) + [path])
    else:
        raise RuntimeError("未知操作：%s" % op)
    return {}


def repo_request(cwd, request, sessions):
    """手机 / 电脑端 IDE 的 Git 请求（读和写都走这里，op 分开）"""
    op = request.get("op") or "overview"
    if op == "init":
        if not is_abs_path(cwd) or not os.path.isdir(cwd):
            raise RuntimeError("会话已结束或没有工作目录")
        git_run(cwd, ["init", "-q"])
        op = "overview"
    if op == "overview":
        try:
            _repo_root(cwd)
        except RuntimeError as exc:
            if str(exc) != "不是 git 仓库":
                raise
            return {"repo": None, "reason": str(exc)}
        return repo_overview(cwd, sessions)
    if op == "status":
        return repo_status(_repo_root(cwd))
    if op == "log":
        return repo_log(cwd, request)
    if op == "commit_info":
        return repo_commit_info(cwd, request.get("commit"))
    if op == "diff":
        return repo_diff(cwd, request)
    return repo_op(cwd, request)


# ---------------------------------------------------------------------------
# tmux：终端里跑的 CLI 会话，远端也能精确投递
# ---------------------------------------------------------------------------

def find_tmux_pane(pid):
    if not shutil.which("tmux"):
        return None
    try:
        out = subprocess.run(["tmux", "list-panes", "-a", "-F", "#{pane_id} #{pane_pid}"],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5)
    except Exception:
        return None
    if out.returncode != 0:
        return None
    panes = {}
    for line in out.stdout.decode("utf-8", "replace").splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].isdigit():
            panes[int(parts[1])] = parts[0]
    for ancestor in ancestors(pid):
        if ancestor in panes:
            return panes[ancestor]
    return None


# ---------------------------------------------------------------------------
# 子 agent 和后台任务（手机上的 Agent map，同 VS Code 里那张图）
#   子 agent：<会话记录同名目录>/subagents/agent-<id>.jsonl，旁边 .meta.json 记着类型、描述、模型、派出它的那次调用、做完没有
#   后台任务：主对话里 Bash 的结果写着「后台运行，ID xxx，输出写到 …/tasks/xxx.output」；跑完会插一条 <task-notification>

_BG_RE = re.compile(r"(?:running in background with ID: |moved to the background \(ID: )(\w+)\)?\. Output is being written to: (\S+?\.output)")
_NOTE_RE = re.compile(r"<task-notification>([\s\S]*?)</task-notification>")


def _tag(block, name):
    found = re.search(r"<%s>([\s\S]*?)</%s>" % (name, name), block)
    return found.group(1).strip() if found else None


def subagent_dir(path):
    base = path[:-6] if path.endswith(".jsonl") else path
    return os.path.join(base, "subagents")


def subagent_count(path):
    """这个会话派过几个子 agent（做完的也算）：数 subagents/ 下的记录文件，不读内容"""
    if not path:
        return 0
    try:
        return sum(1 for name in os.listdir(subagent_dir(path)) if name.endswith(".jsonl"))
    except OSError:
        return 0


def _contents(entry):
    message = entry.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    return [c for c in content if isinstance(c, dict)] if isinstance(content, list) else []


def _result_text(block):
    inner = block.get("content")
    if isinstance(inner, str):
        return inner
    if isinstance(inner, list):
        return "\n".join(x.get("text") or "" for x in inner if isinstance(x, dict) and x.get("type") == "text")
    return ""


def background_tasks(path):
    """主对话里放到后台跑的命令（新的在前）：描述、命令、开始 / 结束时间、状态、输出文件"""
    starts, tasks, notes = {}, {}, {}
    last_ts = None
    try:
        handle = open(path, "rb")
    except OSError:
        return []
    with handle:
        for raw in handle:
            if (b'"Bash"' not in raw and b"background" not in raw and b"task-notification" not in raw
                    and b"KillShell" not in raw and b"TaskStop" not in raw):
                stamp = re.search(rb'"timestamp":"([^"]+)"', raw[:400]) if b'"timestamp"' in raw[:400] else None
                if stamp:
                    last_ts = parse_ts(stamp.group(1).decode()) or last_ts
                continue
            entry = parse_line(raw)
            if not entry:
                continue
            # 有的行（系统插进来的通知）不带时间：用前一行的
            ts = parse_ts(entry.get("timestamp")) or last_ts
            last_ts = ts or last_ts
            for block in _contents(entry):
                kind = block.get("type")
                if kind == "tool_use":
                    tool_input = block.get("input") or {}
                    if block.get("name") == "Bash":
                        starts[block.get("id")] = {"command": str(tool_input.get("command") or ""),
                                                   "description": str(tool_input.get("description") or ""), "ts": ts}
                    elif block.get("name") in ("KillShell", "KillBash", "TaskStop"):
                        tid = tool_input.get("shell_id") or tool_input.get("task_id") or tool_input.get("bash_id")
                        if tid:
                            notes.setdefault(str(tid), {"status": "killed", "ts": ts, "summary": "被 Claude 停掉了"})
                elif kind == "tool_result":
                    found = _BG_RE.search(_result_text(block))
                    if found:
                        start = starts.get(block.get("tool_use_id")) or {}
                        tasks[found.group(1)] = {"id": found.group(1), "output": found.group(2),
                                                 "command": start.get("command", ""), "description": start.get("description", ""),
                                                 "startedAt": start.get("ts") or ts}
                text = block.get("text") if kind == "text" else (_result_text(block) if kind == "tool_result" else None)
                for note in _NOTE_RE.findall(text or ""):
                    tid = _tag(note, "task-id")
                    if tid:
                        notes[tid] = {"status": _tag(note, "status") or "completed", "ts": ts, "summary": _tag(note, "summary")}
    out = []
    for tid, task in tasks.items():
        note = notes.get(tid)
        task = dict(task)
        task["kind"] = "shell"
        task["status"] = note["status"] if note else "running"
        task["endedAt"] = note.get("ts") if note else None
        task["summary"] = note.get("summary") if note else None
        if not task["description"]:
            task["description"] = (task["command"].strip().split("\n", 1)[0] or "后台命令")[:120]
        task["command"] = task["command"][:4000]
        out.append(task)
    out.sort(key=lambda t: t.get("startedAt") or 0, reverse=True)
    return out[:40]


def summarize_subagent(path):
    """一个子 agent 的记录：派给它的任务、用过的工具、最后交回的话、用时和 token"""
    info = {"prompt": "", "tools": [], "report": "", "firstAt": None, "lastAt": None, "tokens": 0,
            "model": None, "agentCalls": []}
    try:
        handle = open(path, "rb")
    except OSError:
        return info
    with handle:
        for raw in handle:
            entry = parse_line(raw)
            if not entry:
                continue
            ts = parse_ts(entry.get("timestamp"))
            if ts:
                info["firstAt"] = info["firstAt"] or ts
                info["lastAt"] = ts
            message = entry.get("message") if isinstance(entry.get("message"), dict) else {}
            if entry.get("type") == "user" and not info["prompt"]:
                info["prompt"] = "\n".join(c.get("text") or "" for c in _contents(entry) if c.get("type") == "text")[:4000]
            if entry.get("type") != "assistant":
                continue
            info["model"] = message.get("model") or info["model"]
            usage = message.get("usage") or {}
            total = sum(int(usage.get(k) or 0) for k in ("input_tokens", "cache_read_input_tokens",
                                                          "cache_creation_input_tokens", "output_tokens"))
            if total:
                info["tokens"] = total
            texts = []
            for block in _contents(entry):
                if block.get("type") == "tool_use":
                    name = block.get("name") or "tool"
                    if len(info["tools"]) < 200:
                        info["tools"].append({"name": name, "brief": tool_brief(name, block.get("input"))})
                    if name in ("Agent", "Task"):
                        info["agentCalls"].append(block.get("id"))
                elif block.get("type") == "text" and (block.get("text") or "").strip():
                    texts.append(block.get("text").strip())
            if texts:
                info["report"] = "\n\n".join(texts)[:6000]
    return info


def subagent_list(path):
    """这个会话派出过的子 agent（新的在前）；parent = 派它出来的那个（main = 主 agent）"""
    folder = subagent_dir(path)
    try:
        names = [n for n in os.listdir(folder) if n.endswith(".jsonl")]
    except OSError:
        return []
    agents = []
    for name in names:
        agent_id = name[6:-6] if name.startswith("agent-") else name[:-6]
        jsonl = os.path.join(folder, name)
        meta = {}
        try:
            with open(os.path.join(folder, name[:-6] + ".meta.json"), encoding="utf-8") as handle:
                meta = json.load(handle) or {}
        except (OSError, ValueError):
            pass
        info = summarize_subagent(jsonl)
        finished = meta.get("finished")
        if finished is None:
            try:
                finished = time.time() - os.path.getmtime(jsonl) > 120
            except OSError:
                finished = True
        agents.append({
            "id": agent_id, "description": meta.get("description") or info["prompt"].split("\n", 1)[0][:80] or "子 agent",
            "agentType": meta.get("agentType"), "model": info["model"] or meta.get("model"), "requestShape": meta.get("requestShape"),
            "toolUseId": meta.get("toolUseId"), "depth": meta.get("spawnDepth") or 1, "finished": bool(finished),
            "startedAt": info["firstAt"], "endedAt": info["lastAt"] if finished else None, "tokens": info["tokens"],
            "prompt": info["prompt"], "tools": info["tools"], "report": info["report"], "agentCalls": info["agentCalls"],
        })
    # 谁派的：子 agent 里调用过 Agent 的那次 = 它的孩子；其余都是主 agent 派的
    owner = {}
    for agent in agents:
        for call in agent.pop("agentCalls"):
            owner[call] = agent["id"]
    for agent in agents:
        agent["parent"] = owner.get(agent.get("toolUseId")) or "main"
    agents.sort(key=lambda a: a.get("startedAt") or 0, reverse=True)
    return agents[:40]


def task_output_tail(path, limit=24 * 1024):
    """后台任务输出文件的末尾"""
    if not path.endswith(".output") or "/tasks/" not in path:
        raise RuntimeError("不是后台任务的输出文件")
    try:
        size = os.path.getsize(path)
        mtime = os.path.getmtime(path)
        with open(path, "rb") as handle:
            handle.seek(max(0, size - limit))
            data = handle.read()
    except OSError:
        return {"text": "", "size": 0, "missing": True}
    return {"text": data.decode("utf-8", "replace"), "size": size, "truncated": size > limit, "mtime": int(mtime * 1000)}


# ---------------------------------------------------------------------------
# 执行过程（trace）：对话页右上角的「执行过程」面板
# 一个会话 = 主 agent + 它派出的子 agent（subagents/ 下每个文件一个）；每个 agent 分成若干轮
# （一条用户 / 上级 agent 的话开始），每轮是一串步骤：模型调用（带思考、输出、token）、
# 工具调用（配上结果、是否出错）、出错提示、中途插话、其他事件。
# 每个文件一个 TraceFile，记着读到哪：第一次全读，之后只读新增的行。面板开着时客户端每几秒拉一次。
# ---------------------------------------------------------------------------

TRACE_TEXT_MAX = 600          # 步骤里带的文字（思考、输出、工具结果）只留开头，全文在对话里
TRACE_STEPS_MAX = 400         # 一轮最多回多少步（多了只回最后这些）
TRACE_TURNS_MAX = 300         # 一个 agent 最多回多少轮
TRACE_FILES_MAX = 80          # 内存里最多记多少个文件的解析结果
TRACE_SEGS_MAX = 48           # 一轮的时间条最多分几段着色
TRACE_STALE_S = 300           # 记录这么久没动、轮次又没收尾：当它停了（被关掉、断了），不再显示「进行中」
TRACE_DONE_STOPS = ("end_turn", "stop_sequence", "max_tokens", "refusal")
TRACE_SPAWN_TOOLS = ("Agent", "Task")
TRACE_SKIP_PREFIXES = (b'{"type":"api-request-blob"', b'{"type":"api-request-shape"', b'{"type":"file-history-snapshot"',
                       b'{"type":"atis-latch"', b'{"type":"last-prompt"', b'{"type":"tools-used"', b'{"type":"ai-title"',
                       b'{"type":"queue-operation"')
_TRACE_LOCK = threading.Lock()
_TRACE_FILES = {}             # 路径 -> TraceFile


def _trace_clip(text, limit=TRACE_TEXT_MAX):
    text = (text or "").strip()
    return text if len(text) <= limit else text[:limit].rstrip() + "…"


def _trace_title(text, limit=80):
    for line in (text or "").splitlines():
        line = line.strip()
        if line:
            return line[:limit]
    return ""


class TraceFile:
    """一个对话记录文件（主对话或一个子 agent）的轮次和步骤，增量解析"""

    def __init__(self, path, normalize):
        self.path = path
        self.normalize = normalize
        self.used = time.time()
        self.reset()

    def reset(self):
        self.offset = 0
        self.mtime = 0
        self.turns = []
        self.call = None          # 正在拼的那次模型调用（一个步骤）
        self.call_key = None      # 它的 message.id（没有 id 的 agent：连着的助手内容算一次）
        self.req_ts = None        # 最近一条 api-request 的时间 = 下一次模型调用的开始
        self.last_ts = None
        self.tools = {}           # toolId -> 工具步骤（等结果）
        self.activity = {}        # 分钟（毫秒）-> [模型调用, 工具调用, 出错]
        self.counts = {"llm": 0, "tools": 0, "errors": 0}

    # --- 读文件 ---

    def refresh(self):
        try:
            stat = os.stat(self.path)
        except OSError:
            return
        self.mtime = stat.st_mtime
        if stat.st_size < self.offset:
            self.reset()      # 记录被重写了（压缩、改名）：从头来
            self.mtime = stat.st_mtime
        if stat.st_size == self.offset:
            return
        try:
            handle = open(self.path, "rb")
        except OSError:
            return
        with handle:
            handle.seek(self.offset)
            while True:
                raw = handle.readline()
                if not raw or not raw.endswith(b"\n"):
                    break         # 最后一行还没写完：下次再读
                offset = self.offset
                self.offset += len(raw)
                if raw.startswith(TRACE_SKIP_PREFIXES):
                    continue
                if raw.startswith(b'{"type":"api-request"'):
                    stamp = re.search(rb'"timestamp":"([^"]+)"', raw[:600])
                    self.req_ts = parse_ts(stamp.group(1).decode()) if stamp else self.req_ts
                    continue
                entry = parse_line(raw)
                if entry is not None:
                    try:
                        self.feed(offset, entry)
                    except Exception:     # 一行认不出不能拖垮整个面板
                        pass

    # --- 拼轮次和步骤 ---

    def _minute(self, ts, slot):
        if not ts:
            return
        bucket = self.activity.setdefault(int(ts // 60000) * 60000, [0, 0, 0])
        bucket[slot] += 1

    def _turn(self, ts, title=None, kind="user"):
        turn = {"i": len(self.turns) + 1, "title": title or "", "kind": kind, "start": ts, "end": ts,
                "steps": [], "llm": 0, "tools": 0, "errors": 0, "done": False, "firstError": None}
        if self.turns:
            self.turns[-1]["done"] = True
        self.turns.append(turn)
        self.call = None
        self.call_key = None
        return turn

    def _step(self, turn, step):
        step["n"] = len(turn["steps"])
        turn["steps"].append(step)
        stamp = step.get("end") or step.get("start")
        if stamp and (not turn["end"] or stamp > turn["end"]):
            turn["end"] = stamp
        if not turn["start"]:
            turn["start"] = step.get("start")
        return step

    def _error(self, turn, step, ts):
        turn["errors"] += 1
        self.counts["errors"] += 1
        if turn["firstError"] is None:
            turn["firstError"] = step["n"]
        self._minute(ts, 2)

    def feed(self, offset, entry):
        etype = entry.get("type")
        message = entry.get("message") if isinstance(entry.get("message"), dict) else {}
        items = self.normalize(offset, entry)
        msg_id = message.get("id") if etype == "assistant" else None
        for item in items:
            self.item(item, msg_id, message if etype == "assistant" else None)
        if etype == "assistant" and self.turns and items and message.get("stop_reason") in TRACE_DONE_STOPS:
            if not self.tools:
                self.turns[-1]["done"] = True

    def item(self, item, msg_id, message):
        kind = item.get("t")
        prev = self.last_ts
        ts = item.get("ts") or prev
        if ts:
            self.last_ts = ts
        if kind == "user":
            text = item.get("text") or ""
            if item.get("queued") and self.turns and not self.turns[-1]["done"]:
                # 忙的时候插进来的话：算这一轮里的一步
                self._step(self.turns[-1], {"k": "user", "start": ts, "end": ts, "text": _trace_clip(text)})
                return
            self._turn(ts, _trace_title(text), kind="image" if (not text.strip() and item.get("images")) else "user")
            return
        if kind == "event" and item.get("peer"):
            peer = item["peer"]
            self._turn(ts, _trace_title(peer.get("text") or peer.get("body") or item.get("text")) or item.get("text"), kind="peer")
            return
        if kind in ("text", "thinking", "tool"):
            if not self.turns:
                self._turn(ts, "", kind="resume")
            turn = self.turns[-1]
            if turn["done"]:
                # 收尾以后助手又说话（后台任务通知、续做目标……）：接着记在这一轮里，重新算进行中
                turn["done"] = False
            key = msg_id or self.call_key or ("seq", offset_key(item))
            if self.call is None or key != self.call_key:
                usage = (message or {}).get("usage") or {}
                self.call = self._step(turn, {
                    "k": "llm", "start": self.req_ts or prev or ts, "end": ts, "model": (message or {}).get("model") or item.get("model"),
                    "text": "", "think": "", "thought": False, "tools": 0,
                    "in": sum(int(usage.get(k) or 0) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")),
                    "out": int(usage.get("output_tokens") or 0)})
                self.call_key = key
                self.req_ts = None
                turn["llm"] += 1
                self.counts["llm"] += 1
                self._minute(self.call["start"], 0)
            call = self.call
            if ts and (not call["end"] or ts > call["end"]):
                call["end"] = ts
            if message and (message.get("usage") or {}).get("output_tokens"):
                call["out"] = int(message["usage"]["output_tokens"])
            if kind == "text":
                call["text"] = _trace_clip((call["text"] + "\n\n" + (item.get("text") or "")).strip())
            elif kind == "thinking":
                call["thought"] = True
                if item.get("text"):
                    call["think"] = _trace_clip((call["think"] + "\n\n" + item["text"]).strip())
            else:
                call["tools"] += 1
                name = item.get("name") or "tool"
                step = self._step(turn, {"k": "tool", "id": item.get("toolId"), "name": name,
                                         "brief": _trace_clip(item.get("brief") or name, 200), "start": ts, "end": None,
                                         "error": False, "result": ""})
                if name == "Bash" and isinstance(item.get("input"), dict) and item["input"].get("command"):
                    step["detail"] = _trace_clip(str(item["input"]["command"]), 1200)
                if item.get("toolId"):
                    self.tools[item["toolId"]] = (turn, step)
                turn["tools"] += 1
                self.counts["tools"] += 1
                self._minute(ts, 1)
            if turn["end"] is None or (ts and ts > turn["end"]):
                turn["end"] = ts
            return
        if kind == "result":
            pending = self.tools.pop(item.get("toolId"), None)
            self.call = None
            self.call_key = None
            if pending is None:
                return
            owner, step = pending
            step["end"] = ts or step["start"]
            step["result"] = _trace_clip(item.get("text") or "", 400)
            if ts and (not owner["end"] or ts > owner["end"]):
                owner["end"] = ts
            if item.get("isError"):
                step["error"] = True
                self._error(owner, step, ts)
            return
        if kind == "event":
            if not self.turns:
                return
            turn = self.turns[-1]
            text = item.get("text") or ""
            if item.get("level") == "error":
                step = self._step(turn, {"k": "error", "start": ts, "end": ts, "text": _trace_clip(text)})
                self._error(turn, step, ts)
            elif text == "已中断":
                self._step(turn, {"k": "event", "start": ts, "end": ts, "text": text})
                turn["done"] = True
                for _, pending in self.tools.values():
                    pending["end"] = pending["end"] or ts
                self.tools = {}
            elif text:
                self._step(turn, {"k": "event", "start": ts, "end": ts, "text": _trace_clip(text, 200)})
            self.call = None
            self.call_key = None

    # --- 给客户端的样子 ---

    def running(self, now):
        if not self.turns or self.turns[-1]["done"]:
            return False
        return now - self.mtime < TRACE_STALE_S

    def turn_brief(self, turn, live, now_ms=None):
        start, end = turn["start"], turn["end"]
        out = {k: turn[k] for k in ("i", "title", "kind", "llm", "tools", "errors", "firstError")}
        out.update({"start": start, "end": end, "steps": len(turn["steps"]), "running": live})
        out.update(trace_turn_shape(turn, now_ms if live else None))
        return out

    def steps_of(self, turn, spawned):
        steps = turn["steps"]
        omitted = max(0, len(steps) - TRACE_STEPS_MAX)
        out = []
        for step in steps[omitted:]:
            step = {k: v for k, v in step.items() if v not in (None, "", False) or k in ("end", "n")}
            if step.get("k") == "tool" and step.get("id") in spawned:
                step["agent"] = spawned[step["id"]]
            out.append(step)
        return out, omitted


def trace_turn_shape(turn, now_ms=None):
    """一轮的形状（时间条分段着色、回放用，不用拉步骤）：
    segs [[距本轮开始毫秒, 时长毫秒, 种类 0 模型 1 工具 2 出错], ...]（同种相邻的并起来，最多 TRACE_SEGS_MAX 段）；
    errAt 出错的时刻（最多 20 个）；llmMs / toolMs / failMs / waitMs 用时拆分（等待 = 本轮用时减去前三项）"""
    start = turn["start"]
    if not start:
        return {"segs": [], "errAt": [], "llmMs": 0, "toolMs": 0, "failMs": 0, "waitMs": 0}
    stop = now_ms or turn["end"] or start
    raw = []
    llm_ms = tool_ms = fail_ms = 0
    err_at = []
    for step in turn["steps"]:
        kind = step.get("k")
        s0 = step.get("start")
        if not s0:
            continue
        if kind == "error":
            err_at.append(s0)
            continue
        if kind not in ("llm", "tool"):
            continue
        s1 = step.get("end") or (now_ms if now_ms else s0)
        dur = max(0, s1 - s0)
        if kind == "llm":
            llm_ms += dur
            raw.append([s0 - start, dur, 0])
        elif step.get("error"):
            fail_ms += dur
            err_at.append(s1)
            raw.append([s0 - start, dur, 2])
        else:
            tool_ms += dur
            raw.append([s0 - start, dur, 1])
    total = max(1, stop - start)
    # 太多段时把挨得近的同种段并起来：间隔阈值从 1 秒起，翻倍直到段数够少
    gap = 1000
    segs = raw
    while True:
        merged = []
        for seg in segs:
            if merged and merged[-1][2] == seg[2] and seg[0] - (merged[-1][0] + merged[-1][1]) <= gap:
                merged[-1][1] = max(merged[-1][1], seg[0] + seg[1] - merged[-1][0])
            else:
                merged.append(list(seg))
        if len(merged) <= TRACE_SEGS_MAX or gap > total:
            break
        segs, gap = merged, gap * 2
    return {"segs": [[int(a), int(b), c] for a, b, c in merged[:TRACE_SEGS_MAX]], "errAt": err_at[:20],
            "llmMs": int(llm_ms), "toolMs": int(tool_ms), "failMs": int(fail_ms),
            "waitMs": int(max(0, total - llm_ms - tool_ms - fail_ms))}


def offset_key(item):
    """没有 message.id 时的分组键：同一行拆出来的几项（id 是「行偏移.序号」）算一次调用"""
    return str(item.get("id") or "").split(".", 1)[0]


def _trace_file(path, normalize):
    tracer = _TRACE_FILES.get(path)
    if tracer is None or tracer.normalize is not normalize:
        tracer = TraceFile(path, normalize)
        _TRACE_FILES[path] = tracer
        if len(_TRACE_FILES) > TRACE_FILES_MAX:
            for old in sorted(_TRACE_FILES, key=lambda p: _TRACE_FILES[p].used)[:len(_TRACE_FILES) - TRACE_FILES_MAX]:
                _TRACE_FILES.pop(old, None)
    tracer.used = time.time()
    tracer.refresh()
    return tracer


def session_trace(path, normalize, title=None, busy=None, expand=None, subagents=True, rev=None):
    """一个会话的执行过程：统计、按分钟的活动、agent → 轮次（摘要），expand 里点名的轮次带上步骤。
    expand: ["main:12", "<agentId>:1", ...]；busy: 主 agent 现在是不是在忙（电脑端知道得更准，没有就按记录猜）"""
    with _TRACE_LOCK:
        now = time.time()
        files = [("main", _trace_file(path, normalize), {})]
        if subagents:
            folder = subagent_dir(path)
            try:
                names = sorted(n for n in os.listdir(folder) if n.endswith(".jsonl"))
            except OSError:
                names = []
            for name in names:
                agent_id = name[6:-6] if name.startswith("agent-") else name[:-6]
                meta = {}
                try:
                    with open(os.path.join(folder, name[:-6] + ".meta.json"), encoding="utf-8") as handle:
                        meta = json.load(handle) or {}
                except (OSError, ValueError):
                    pass
                files.append((agent_id, _trace_file(os.path.join(folder, name), normalize_subagent_line), meta))

        # 版本号：各文件读到哪 + 忙不忙 + 要哪几轮的步骤；客户端带着上次的来、没变就只回一句（面板开着时每几秒拉一次，大会话一次一两百 KB）
        version = hashlib.sha1(json.dumps([[a, t.offset] for a, t, _ in files] + [busy, sorted(str(x) for x in (expand or []))]).encode()).hexdigest()[:16]
        has_live = bool(busy) or any(t.running(now) for _, t, _ in files)    # 有在跑的：用时每秒在变，照常回全量
        if rev and rev == version and not has_live:
            return {"same": True, "rev": version}
        # 谁派的：工具调用 id -> (派它的 agent, 第几轮)
        spawn_at = {}
        for agent_id, tracer, _ in files:
            for turn in tracer.turns:
                for step in turn["steps"]:
                    if step.get("k") == "tool" and step.get("name") in TRACE_SPAWN_TOOLS and step.get("id"):
                        spawn_at[step["id"]] = (agent_id, turn["i"])
        spawned = {}     # 工具调用 id -> 子 agent id
        agents = []
        activity = {}
        first_error = None
        totals = {"llm": 0, "tools": 0, "errors": 0, "turns": 0}
        durations = []
        wanted = set(str(x) for x in (expand or []))
        steps = {}
        start_all, end_all = None, None
        for agent_id, tracer, meta in files:
            live_file = tracer.running(now)
            if agent_id == "main" and busy is not None:
                live_file = bool(busy) and bool(tracer.turns)
            elif agent_id != "main" and meta.get("finished") is not None:
                live_file = live_file and not meta.get("finished")
            turns = tracer.turns[-TRACE_TURNS_MAX:]
            briefs = []
            for turn in turns:
                live = live_file and turn is tracer.turns[-1]
                briefs.append(tracer.turn_brief(turn, live, int(now * 1000)))
                if turn["start"] and turn["end"] and not live:
                    durations.append(turn["end"] - turn["start"])
                if turn["firstError"] is not None:
                    stamp = turn["steps"][turn["firstError"]].get("start")
                    if stamp and (first_error is None or stamp < first_error["ts"]):
                        first_error = {"agent": agent_id, "turn": turn["i"], "step": turn["firstError"], "ts": stamp}
            for minute, counts in tracer.activity.items():
                bucket = activity.setdefault(minute, [0, 0, 0])
                for i in range(3):
                    bucket[i] += counts[i]
            for key in ("llm", "tools", "errors"):
                totals[key] += tracer.counts[key]
            totals["turns"] += len(tracer.turns)
            first = next((t["start"] for t in tracer.turns if t["start"]), None)
            last = max((t["end"] or t["start"] or 0 for t in tracer.turns), default=0) or None
            if first:
                start_all = min(start_all or first, first)
            if last:
                end_all = max(end_all or last, last)
            info = {"id": agent_id, "running": live_file, "start": first, "end": last,
                    "llm": tracer.counts["llm"], "tools": tracer.counts["tools"], "errors": tracer.counts["errors"],
                    "turns": briefs, "turnsOmitted": max(0, len(tracer.turns) - TRACE_TURNS_MAX)}
            if agent_id == "main":
                info.update({"title": title or "", "parent": None})
            else:
                origin = spawn_at.get(meta.get("toolUseId"))
                if meta.get("toolUseId"):
                    spawned[meta["toolUseId"]] = agent_id
                first_turn = tracer.turns[0]["title"] if tracer.turns else ""
                info.update({"title": meta.get("description") or first_turn or "", "agentType": meta.get("agentType"),
                             "parent": origin[0] if origin else "main", "fromTurn": origin[1] if origin else None})
            agents.append(info)
        for agent_id, tracer, _ in files:
            for turn in tracer.turns:
                if "%s:%d" % (agent_id, turn["i"]) in wanted:
                    items, omitted = tracer.steps_of(turn, spawned)
                    steps["%s:%d" % (agent_id, turn["i"])] = {"items": items, "omitted": omitted}
        # 子 agent 排在主 agent 后面，按开始时间
        agents[1:] = sorted(agents[1:], key=lambda a: a.get("start") or 0)
        durations.sort()
        busy_minutes = sum(1 for counts in activity.values() if any(counts))
        return {
            "start": start_all, "end": end_all, "now": int(now * 1000),
            "stats": {"agents": len(agents), "subagents": len(agents) - 1, "turns": totals["turns"],
                      "medianTurn": durations[len(durations) // 2] if durations else None,
                      "llm": totals["llm"], "tools": totals["tools"], "errors": totals["errors"],
                      "busyMs": busy_minutes * 60000},
            "activity": [[minute] + counts for minute, counts in sorted(activity.items())],
            "firstError": first_error, "agents": agents, "steps": steps, "rev": version,
        }


TMUX_KEYS = {"enter": "Enter", "esc": "Escape", "escape": "Escape", "up": "Up", "down": "Down",
             "tab": "Tab", "shift+tab": "BTab", "1": "1", "2": "2", "3": "3", "4": "4", "y": "y", "n": "n"}

# 终端里的 Claude Code 停在选择框上（11-11）：一轮答完后它会自己弹推广 / 引导框（「Teach auto mode about your environment?
# 1. Yes / 2. Not now / 3. Don't show again」，光标默认在 Yes），这时往里粘字 + 回车，字被框吞掉、回车替用户选了 Yes，
# 第二页的回车又把「扫描命令行历史」勾上了。认法（screen_text 的写法，去空白、小写）：最后一次画出的框底提示
# 在最后一次画出的输入框状态行之后 = 框还开着（框关掉时输入框和状态行会整个重画，托管会话的真实输出验证过）
_DIALOG_FOOTERS = ("esctocancel", "entertoconfirm")
_PROMPT_MARKS = ("shift+tabtocycle", "forshortcuts", "/effort", "esctointerrupt", "automodeon", "bypasspermissionson",
                 "accepteditson", "planmodeon")
# 能替用户关掉的：只认这几种推广 / 引导框（Esc =「Not now」，什么都不改）。权限确认、提问框绝不替用户关
_NAG_MARKS = ("teachautomode", "alsoscanshellhistory", "don'tshowagain")
_NOT_NAG = ("doyouwant", "allow", "permission")
DIALOG_REFUSED = ("电脑上的 Claude Code 正停在一个选择框上，消息没有送进去（免得回车替你选了选项）。"
                  "请在会话终端里或电脑上处理这个框后再发")


def claude_dialog(text):
    """终端画面（screen_text 处理过的）停在选择框上：推广 / 引导框回 "nag"（可以 Esc 关掉），别的框回 "dialog"，没有框回 None"""
    footer = max(text.rfind(mark) for mark in _DIALOG_FOOTERS)
    if footer < 0 or len(text) - footer > 6000:   # 框开着时画面是静止的，框底提示就在最近的输出里；早画过的不算
        return None
    prompt = max(text.rfind(mark) for mark in _PROMPT_MARKS)
    if prompt > footer:
        return None
    # 框的内容：从框顶那条「▔▔▔」边线（没有就往前 2000 字）到框底提示，别把框上面的对话算进来
    box = text[max(prompt + 1, footer - 2000, text.rfind("▔", 0, footer) + 1):footer + 40]
    if any(mark in box for mark in _NAG_MARKS) and not any(mark in box for mark in _NOT_NAG):
        return "nag"
    return "dialog"


def _screen_gate(pane, text):
    """tmux / Windows 控制台：要粘字之前看一眼当前屏幕。推广框按 Esc 关掉；别的框不送（抛错，客户端照实告诉用户）"""
    if not text or not pane:
        return
    for _ in range(4):
        kind = claude_dialog(screen_text(term_screen(pane).encode("utf-8", "replace")))
        if kind == "nag":
            log("%s 上弹着 Claude Code 的推广框，按 Esc 关掉再送" % pane)
            term_keys(pane, "Escape")
            time.sleep(1.0)
            continue
        if kind == "dialog":
            raise RuntimeError(DIALOG_REFUSED)
        return
    raise RuntimeError(DIALOG_REFUSED)


def tmux_send(pid, text, keys, submit):
    hosted = HOSTED.by_pid(pid)
    if hosted:   # 托管会话：写进守护进程拿着的伪终端（见 HostedSessions）
        return HOSTED.send(hosted, text, keys, submit)
    pane = _TMUX_PANES.get(pid) or find_tmux_pane(pid)
    if not pane and IS_WINDOWS and pid_alive(pid):
        _screen_gate("console:%d" % pid, text)
        return console_send(pid, text, keys, submit)   # Windows 没有 tmux：写进它所在的控制台
    if not pane:
        raise RuntimeError("这个 CLI 会话不在 tmux 里，无法远程投递（在 tmux 中启动 claude 即可）")
    _screen_gate(pane, text)
    if text:
        # 走 tmux 缓冲区 + 括号粘贴：多行内容不会被逐行提交
        buffer_name = "ccpulse-%d" % os.getpid()
        subprocess.run(["tmux", "load-buffer", "-b", buffer_name, "-"], input=text.encode("utf-8"),
                       check=True, timeout=10)
        subprocess.run(["tmux", "paste-buffer", "-p", "-d", "-b", buffer_name, "-t", pane],
                       check=True, timeout=10)
    for key in keys or []:
        name = TMUX_KEYS.get(str(key).lower())
        if not name:
            raise RuntimeError("不支持的按键：%s" % key)
        subprocess.run(["tmux", "send-keys", "-t", pane, name], check=True, timeout=10)
    if submit:
        time.sleep(0.15)
        subprocess.run(["tmux", "send-keys", "-t", pane, "Enter"], check=True, timeout=10)
    return pane


# ---------------------------------------------------------------------------
# 通用终端层（插件用，规范 4.4 的 term.*）：tmux 窗格、托管会话、Windows 控制台用同一套调用
#   term_pane(pid)            → 窗格标识：tmux 的 "%3"、"hosted:<id>"、Windows 的 "console:<pid>"；不可操作时 None
#   term_screen(pane, lines)  → 屏幕上最后几十行的文字（判断是不是在等确认、忙不忙）
#   term_keys(pane, *names)   → 按键，名字用 tmux 的写法：Enter、Escape、Up、Down、Tab、BTab、BSpace、C-c、C-u、C-q、单个字符
#   tmux_send(pid, …)         → 发文字 + 按键 + 回车（Windows 上没有 tmux 时走控制台）
# Windows 上没有 tmux：在一个没有控制台的子进程里 AttachConsole 到 CLI 所在的控制台，WriteConsoleInputW 写按键、
# ReadConsoleOutputCharacterW 读屏幕（同电脑端给 Claude Code 用的写法，delivery_win.console_input_main）。
# 每个会话一个常驻子进程（ConsoleBridge），目标进程退了它也退，免得拖住终端窗口不关（11-05）。
# ---------------------------------------------------------------------------

_PROCESS_CACHE = [0.0, []]


def process_list():
    """本机进程（插件用，HOST_CAPS proc.list）：[{"pid", "cmd" 完整命令行, "start" 启动时间（秒）或 None}]。
    Unix 用 ps；Windows 没有 ps，用进程快照 + NtQueryInformationProcess 读命令行（11-05）。2 秒内重复调用用缓存"""
    if time.time() - _PROCESS_CACHE[0] < 2.0:
        return _PROCESS_CACHE[1]
    out = []
    if IS_WINDOWS:
        ntdll = ctypes.WinDLL("ntdll")

        class USTR(ctypes.Structure):
            _fields_ = [("Length", wintypes.USHORT), ("MaximumLength", wintypes.USHORT), ("Buffer", ctypes.c_void_p)]

        for pid, name in _win_process_names().items():
            if not pid:
                continue
            cmd = name
            handle = _win_open(pid)
            if handle:
                try:
                    size = wintypes.ULONG(0)
                    buffer = ctypes.create_string_buffer(8192)
                    status = ntdll.NtQueryInformationProcess(handle, 60, buffer, len(buffer), ctypes.byref(size)) & 0xFFFFFFFF
                    if status == 0xC0000004 and size.value:   # STATUS_INFO_LENGTH_MISMATCH
                        buffer = ctypes.create_string_buffer(size.value)
                        status = ntdll.NtQueryInformationProcess(handle, 60, buffer, len(buffer), ctypes.byref(size)) & 0xFFFFFFFF
                    if status == 0:
                        text = USTR.from_buffer(buffer)
                        if text.Buffer and text.Length:
                            cmd = ctypes.wstring_at(text.Buffer, text.Length // 2)
                finally:
                    _k32.CloseHandle(handle)
            start = _win_start_token(pid)
            out.append({"pid": pid, "cmd": cmd, "start": int(start) if start else None})
    else:
        try:
            text = subprocess.run(["ps", "-axww", "-o", "pid=,lstart=,command="], capture_output=True, text=True, timeout=15,
                                  env=dict(os.environ, LC_ALL="C", LANG="C")).stdout
        except (OSError, subprocess.SubprocessError):
            return []   # 这次没列出来：不缓存，下次重试
        for line in text.splitlines():
            parts = line.split()
            if len(parts) < 7 or not parts[0].isdigit():
                continue
            try:
                start = int(time.mktime(time.strptime(" ".join(parts[1:6]), "%a %b %d %H:%M:%S %Y")))
            except ValueError:
                start = None
            out.append({"pid": int(parts[0]), "cmd": " ".join(parts[6:]), "start": start})
    _PROCESS_CACHE[0], _PROCESS_CACHE[1] = time.time(), out
    return out


_CONSOLE_VK = {"Enter": (0x0D, "\r"), "Escape": (0x1B, "\x1b"), "Up": (0x26, ""), "Down": (0x28, ""), "Left": (0x25, ""),
               "Right": (0x27, ""), "Tab": (0x09, "\t"), "BTab": (0x09, "\t"), "BSpace": (0x08, "\b"), "Home": (0x24, ""),
               "End": (0x23, ""), "Space": (0x20, " ")}


def _console_records(tokens):
    """[{"text": …} | {"key": "C-c" / "Enter"…}] → INPUT_RECORD 参数 (按下?, vk, 扫描码, 字符, 控制键状态)"""
    out = []
    user32 = ctypes.WinDLL("user32")
    for token in tokens:
        if "text" in token:
            data = str(token["text"]).encode("utf-16-le")
            for unit in (int.from_bytes(data[i:i + 2], "little") for i in range(0, len(data), 2)):
                ch = chr(unit)
                vk = {"\r": 0x0D, "\n": 0x0D, "\x1b": 0x1B, "\t": 0x09}.get(ch, 0)
                out.append((vk, user32.MapVirtualKeyW(vk, 0) if vk else 0, "\r" if ch == "\n" else ch, 0))
            continue
        name = str(token.get("key") or "")
        if name.startswith("C-") and len(name) == 3:
            letter = name[2].upper()
            out.append((ord(letter), user32.MapVirtualKeyW(ord(letter), 0), chr(ord(letter) - 64), 0x0008))   # LEFT_CTRL_PRESSED
        elif name in _CONSOLE_VK:
            vk, ch = _CONSOLE_VK[name]
            state = 0x0010 if name == "BTab" else (0x0100 if not ch else 0)   # SHIFT_PRESSED / ENHANCED_KEY（方向键）
            out.append((vk, user32.MapVirtualKeyW(vk, 0), ch, state))
        elif len(name) == 1:
            out.append((0, 0, name, 0))
        else:
            raise ValueError("不支持的按键：%s" % name)
    return out


def console_io_main(pid):
    """子进程入口（ccpulse-watch.py console-io <pid>）：常驻，stdin 一行一个请求 {"op": "keys", "tokens"} / {"op": "read"}，
    stdout 一行一个回答 {"ok", "text"?, "error"?}。目标进程退了就退出"""
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

    class CHAR(ctypes.Union):
        _fields_ = [("UnicodeChar", wintypes.WCHAR), ("AsciiChar", ctypes.c_char)]

    class KEY(ctypes.Structure):
        _fields_ = [("bKeyDown", wintypes.BOOL), ("wRepeatCount", wintypes.WORD), ("wVirtualKeyCode", wintypes.WORD),
                    ("wVirtualScanCode", wintypes.WORD), ("uChar", CHAR), ("dwControlKeyState", wintypes.DWORD)]

    class EVENT(ctypes.Union):
        _fields_ = [("KeyEvent", KEY), ("_pad", ctypes.c_byte * 16)]

    class RECORD(ctypes.Structure):
        _fields_ = [("EventType", wintypes.WORD), ("Event", EVENT)]

    class COORD(ctypes.Structure):
        _fields_ = [("X", wintypes.SHORT), ("Y", wintypes.SHORT)]

    class RECT(ctypes.Structure):
        _fields_ = [("Left", wintypes.SHORT), ("Top", wintypes.SHORT), ("Right", wintypes.SHORT), ("Bottom", wintypes.SHORT)]

    class INFO(ctypes.Structure):
        _fields_ = [("dwSize", COORD), ("dwCursorPosition", COORD), ("wAttributes", wintypes.WORD),
                    ("srWindow", RECT), ("dwMaximumWindowSize", COORD)]

    out = sys.stdout

    def reply(obj):
        out.write(json.dumps(obj, ensure_ascii=False) + "\n")
        out.flush()

    kernel32.FreeConsole()
    if not kernel32.AttachConsole(wintypes.DWORD(pid)):
        reply({"ok": False, "error": "无法连接到会话所在的终端（AttachConsole 失败，错误 %d）" % ctypes.get_last_error()})
        return 2
    kernel32.SetConsoleCtrlHandler(None, True)   # 用户在那个终端里按 Ctrl+C 时别把自己也结束了
    kernel32.CreateFileW.restype = wintypes.HANDLE
    kernel32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID, wintypes.DWORD,
                                     wintypes.DWORD, wintypes.HANDLE]
    conin = kernel32.CreateFileW("CONIN$", 0xC0000000, 3, None, 3, 0, None)
    conout = kernel32.CreateFileW("CONOUT$", 0xC0000000, 3, None, 3, 0, None)
    reply({"ok": True, "ready": True})

    def alive():
        handle = kernel32.OpenProcess(0x1000, False, pid)   # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            return False
        code = wintypes.DWORD()
        kernel32.GetExitCodeProcess(handle, ctypes.byref(code))
        kernel32.CloseHandle(handle)
        return code.value == 259   # STILL_ACTIVE

    def watchdog():
        while alive():
            time.sleep(1)
        os._exit(0)

    threading.Thread(target=watchdog, daemon=True).start()
    for line in sys.stdin:
        try:
            request = json.loads(line)
        except ValueError:
            continue
        try:
            if request.get("op") == "keys":
                records = []
                for vk, scan, ch, state in _console_records(request.get("tokens") or []):
                    for down in (True, False):
                        rec = RECORD()
                        rec.EventType = 1
                        rec.Event.KeyEvent = KEY(down, 1, vk, scan, CHAR(UnicodeChar=ch or "\0"), state)
                        records.append(rec)
                if records:
                    array = (RECORD * len(records))(*records)
                    written = wintypes.DWORD()
                    if not kernel32.WriteConsoleInputW(wintypes.HANDLE(conin), array, len(records), ctypes.byref(written)):
                        raise OSError("写入终端输入失败（错误 %d）" % ctypes.get_last_error())
                reply({"ok": True})
            elif request.get("op") == "read":
                info = INFO()
                if not kernel32.GetConsoleScreenBufferInfo(wintypes.HANDLE(conout), ctypes.byref(info)):
                    raise OSError("读不到终端内容（错误 %d）" % ctypes.get_last_error())
                width = info.dwSize.X
                bottom = info.srWindow.Bottom
                top = max(0, bottom - int(request.get("lines") or (bottom - info.srWindow.Top)))
                rows = []
                buffer = ctypes.create_unicode_buffer(width + 1)
                for row in range(top, bottom + 1):
                    count = wintypes.DWORD()
                    kernel32.ReadConsoleOutputCharacterW(wintypes.HANDLE(conout), buffer, width, COORD(0, row), ctypes.byref(count))
                    rows.append(buffer.value[:count.value].rstrip())
                reply({"ok": True, "text": "\n".join(rows)})
            else:
                reply({"ok": False, "error": "unknown op"})
        except Exception as exc:   # 一条请求出错不退出
            reply({"ok": False, "error": str(exc)})
    return 0


class ConsoleBridge:
    """watcher 这边：每个 Windows 控制台会话一个常驻子进程（console_io_main），按行问答；子进程挂了下次再起"""

    def __init__(self):
        self.procs = {}
        self.lock = threading.Lock()

    def _command(self, pid):
        exe = os.path.basename(sys.executable).lower()
        base = [sys.executable] if exe.startswith("python") else [sys.executable, "--run-script"]
        return base + [os.path.abspath(__file__), "console-io", str(pid)]

    def _proc(self, pid):
        proc = self.procs.get(pid)
        if proc and proc.poll() is None:
            return proc
        env = dict(os.environ, PYTHONIOENCODING="utf-8", PYTHONUTF8="1")
        proc = subprocess.Popen(self._command(pid), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                env=env, creationflags=0x00000008, text=True, encoding="utf-8", bufsize=1)   # DETACHED_PROCESS
        first = json.loads(proc.stdout.readline() or "{}")
        if not first.get("ok"):
            proc.kill()
            raise RuntimeError(first.get("error") or "无法连接到会话所在的终端")
        self.procs[pid] = proc
        return proc

    def ask(self, pid, request):
        with self.lock:
            proc = self._proc(pid)
            try:
                proc.stdin.write(json.dumps(request, ensure_ascii=False) + "\n")
                proc.stdin.flush()
                answer = json.loads(proc.stdout.readline() or "{}")
            except (OSError, ValueError):
                self.procs.pop(pid, None)
                raise RuntimeError("和会话所在终端的连接断了，请重试")
        if not answer.get("ok"):
            raise RuntimeError(answer.get("error") or "终端操作失败")
        return answer


CONSOLE = ConsoleBridge()
_SCREEN_CACHE = {}


def term_pane(pid):
    """可操作的终端：tmux 窗格 / 托管会话 / Windows 控制台；都不是返回 None"""
    if not pid:
        return None
    hosted = HOSTED.by_pid(pid)
    if hosted:
        return "hosted:%s" % hosted.get("id")
    pane = find_tmux_pane(pid)
    if pane:
        return pane
    if IS_WINDOWS and pid_alive(pid):
        return "console:%d" % pid
    return None


def term_screen(pane, lines=None):
    """屏幕上的文字（最后 lines 行；不给就是当前一屏）。读不到返回空字符串。Windows 上 1 秒内重复读用缓存（每次要问子进程）"""
    if not pane:
        return ""
    if pane.startswith("console:"):
        key = (pane, lines)
        hit = _SCREEN_CACHE.get(key)
        if hit and time.time() - hit[0] < 1.0:
            return hit[1]
        try:
            text = CONSOLE.ask(int(pane.split(":", 1)[1]), {"op": "read", "lines": lines or 0}).get("text") or ""
        except RuntimeError:
            text = ""
        _SCREEN_CACHE[key] = (time.time(), text)
        return text
    if pane.startswith("hosted:"):
        return ""
    try:
        cmd = ["tmux", "capture-pane", "-p", "-J", "-t", pane] + (["-S", "-%d" % lines] if lines else [])
        return subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def term_keys(pane, *names):
    """按键（tmux 的写法）"""
    if not pane:
        raise RuntimeError("这个会话不在可操作的终端里")
    if pane.startswith("console:"):
        _SCREEN_CACHE.clear()
        CONSOLE.ask(int(pane.split(":", 1)[1]), {"op": "keys", "tokens": [{"key": name} for name in names]})
        return
    if pane.startswith("hosted:"):
        raise RuntimeError("托管会话不支持这个按键")
    for name in names:
        subprocess.run(["tmux", "send-keys", "-t", pane, name], check=True, timeout=10)


def console_send(pid, text, keys, submit):
    """Windows：发文字、按键、回车。文字和回车分开写（同电脑端 send_console：一口气写进去有的 TUI 当成粘贴，回车只换行）"""
    pane = "console:%d" % pid
    if text:
        CONSOLE.ask(pid, {"op": "keys", "tokens": [{"text": text.replace("\r\n", "\n").replace("\n", " ")}]})
    for key in keys or []:
        name = TMUX_KEYS.get(str(key).lower())
        if not name:
            raise RuntimeError("不支持的按键：%s" % key)
        term_keys(pane, name)
    if submit:
        time.sleep(0.4)
        term_keys(pane, "Enter")
    _SCREEN_CACHE.clear()
    return pane


# ---------------------------------------------------------------------------
# stdin 请求
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 其他编程 agent：Codex、OpenCode、DeepSeek Harness、Proma
#
# Claude Code 的会话靠读文件（注册表 + transcript）。Codex、OpenCode 各有本机服务可以连
# （DeepSeek Harness、Proma 的说明在各自那一节）：
#   Codex     终端、桌面版、IDE 扩展共用一个本机守护进程（app-server），控制 socket 上是 WebSocket + JSON-RPC。
#             状态靠广播（不用附着就收得到），对话内容读它自己落盘的 rollout 文件；只在审批、发消息时才附着
#             （thread/resume），会话空闲后退订——附着着的会话不会卸载，用户关了终端它还会一直挂在列表里。
#   OpenCode  默认的终端界面不开端口：Kiteline 的插件（~/.config/opencode/plugin/kiteline.js）在它的进程里
#             开一个 127.0.0.1 随机端口 + 令牌，把 HTTP 请求原样转给内部服务，登记在 ~/.ccpulse/opencode/ 下。
# 两边的会话都整理成和 Claude Code 一样的快照、对话项（工具名也尽量对上 Bash / Edit / TodoWrite……），
# 手机上的确认卡片、改动对比、任务清单不用分别处理。快照里多一个 agent 字段（codex / opencode）。
# 每家最后包成一个插件，主循环只认插件接口（见后面「Agent 插件」一节）。
# ---------------------------------------------------------------------------

CODEX_HOME = os.environ.get("CODEX_HOME") or os.path.join(HOME, ".codex")
CODEX_SOCKET = os.path.join(CODEX_HOME, "app-server-control", "app-server-control.sock")
OPENCODE_BRIDGES = os.path.join(DATA_DIR, "opencode")
# Kiteline 设置里关了「为 OpenCode 安装 Kiteline 插件」时为 0：不装，装过的也删掉
OPENCODE_PLUGIN_ENABLED = os.environ.get("CCPULSE_OPENCODE_PLUGIN") != "0"


def _now_ms():
    return int(time.time() * 1000)


def _ws_mask(data, mask):
    if not data:
        return data
    size = len(data)
    pad = (mask * (size // 4 + 1))[:size]
    return (int.from_bytes(data, "big") ^ int.from_bytes(pad, "big")).to_bytes(size, "big")


class SocketPipe:
    """Mac / Linux：直接连 Codex 守护进程的 Unix socket；给 (主机, 端口) 时连 TCP（DeepSeek Harness 的网页服务）"""

    def __init__(self, path, timeout=5):
        if isinstance(path, tuple):
            self.sock = socket.create_connection(path, timeout=timeout)
            return
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(path)

    def ready(self):
        self.sock.settimeout(None)

    def write(self, data):
        self.sock.sendall(data)

    def read(self, size):
        return self.sock.recv(size)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class ProxyPipe:
    """Windows：Python 连不了 Windows 的 Unix socket，起一个 `codex app-server proxy`，经它的标准输入输出转过去"""

    def __init__(self, executable):
        self.proc = subprocess.Popen([executable, "app-server", "proxy"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, bufsize=0)

    def ready(self):
        pass

    def write(self, data):
        self.proc.stdin.write(data)
        self.proc.stdin.flush()

    def read(self, size):
        return self.proc.stdout.read(size)

    def close(self):
        try:
            self.proc.kill()
            self.proc.wait(timeout=5)
        except Exception:
            pass


class WebSocket:
    """WebSocket 客户端：只做 Codex 守护进程、DeepSeek Harness 用到的部分（文本帧、分片、ping），底下是 SocketPipe 或 ProxyPipe"""

    def __init__(self, pipe, path="/", host="localhost", headers=None):
        self.pipe = pipe
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        extra = "".join("%s: %s\r\n" % item for item in (headers or {}).items())
        pipe.write(("GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                    "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n%s\r\n" % (path, host, key, extra)).encode("utf-8"))
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = pipe.read(1)     # 一次一个字节：握手后面紧跟着的帧不能被读走
            if not chunk:
                pipe.close()
                raise EOFError("握手时连接断开")
            head += chunk
            if len(head) > 16384:
                pipe.close()
                raise RuntimeError("握手响应过长")
        if b" 101 " not in head.split(b"\r\n", 1)[0]:
            pipe.close()
            raise RuntimeError("握手失败：%r" % head[:120])
        pipe.ready()
        self.lock = threading.Lock()

    def send(self, text, opcode=1):
        data = text.encode("utf-8") if isinstance(text, str) else text
        size = len(data)
        if size < 126:
            head = bytes([0x80 | opcode, 0x80 | size])
        elif size < 65536:
            head = bytes([0x80 | opcode, 0x80 | 126]) + struct.pack(">H", size)
        else:
            head = bytes([0x80 | opcode, 0x80 | 127]) + struct.pack(">Q", size)
        mask = os.urandom(4)
        with self.lock:
            self.pipe.write(head + mask + _ws_mask(data, mask))

    def _exact(self, size):
        buf = b""
        while len(buf) < size:
            chunk = self.pipe.read(size - len(buf))
            if not chunk:
                raise EOFError("连接断开")
            buf += chunk
        return buf

    def recv(self):
        parts = []
        while True:
            first, second = self._exact(2)
            opcode, size = first & 0x0F, second & 0x7F
            if size == 126:
                size = struct.unpack(">H", self._exact(2))[0]
            elif size == 127:
                size = struct.unpack(">Q", self._exact(8))[0]
            mask = self._exact(4) if second & 0x80 else None
            data = self._exact(size)
            if mask:
                data = _ws_mask(data, mask)
            if opcode == 9:
                self.send(data, opcode=10)
                continue
            if opcode == 8:
                raise EOFError("对方关闭了连接")
            if opcode in (0, 1, 2):
                parts.append(data)
                if first & 0x80:
                    return b"".join(parts).decode("utf-8", "replace")

    def close(self):
        self.pipe.close()


def codex_daemon_executable():
    """守护进程自己管的那份 codex（它启动时把自己装进 CODEX_HOME/packages）：Windows 上起 proxy 用，不用管用户装在哪。
    current 是个目录联接；带管理员权限的进程穿不过普通权限建的联接（WinError 448），就直接在 releases 里挑最新的"""
    name = "codex.exe" if IS_WINDOWS else "codex"
    base = os.path.join(CODEX_HOME, "packages", "app-server-daemon")
    current = os.path.join(base, "current", "bin", name)
    try:
        if os.path.isfile(current):
            return current
    except OSError:
        pass
    found = []
    for path in globlib.glob(os.path.join(base, "releases", "*", "bin", name)):
        try:
            found.append((os.path.getmtime(path), path))
        except OSError:
            continue
    return max(found)[1] if found else None


def open_codex_daemon():
    """连上 Codex 守护进程；不在运行就抛错"""
    if not os.path.lexists(CODEX_SOCKET):
        raise FileNotFoundError(CODEX_SOCKET)
    if hasattr(socket, "AF_UNIX") and not IS_WINDOWS:
        # Codex 把 CODEX_HOME 下的 socket 做成指向短路径的链接（Unix socket 路径有长度上限，macOS 是 104 字节）：连真实路径
        return WebSocket(SocketPipe(os.path.realpath(CODEX_SOCKET)))
    executable = codex_daemon_executable()
    if not executable:
        raise FileNotFoundError("找不到 Codex 守护进程的程序")
    return WebSocket(ProxyPipe(executable))


# --- 工具调用 → 手机认得的样子 ---

def _patch_files(patch):
    """apply_patch 补丁 → [(动作, 路径, 删掉的行, 加上的行)]"""
    files = []
    current = None
    for line in (patch or "").split("\n"):
        match = re.match(r"^\*\*\* (Add|Update|Delete) File: (.+)$", line)
        if match:
            current = [match.group(1), match.group(2).strip(), [], []]
            files.append(current)
        elif line.startswith("*** "):
            continue
        elif current is not None and not line.startswith("@@"):
            if line.startswith("-"):
                current[2].append(line[1:])
            elif line.startswith("+"):
                current[3].append(line[1:])
            elif line.startswith(" "):
                current[2].append(line[1:])
                current[3].append(line[1:])
    return files


def patch_tool(patch):
    """补丁 → Edit / Write（单个文件，手机上能画改动对比）或 apply_patch（多个文件）"""
    files = _patch_files(patch)
    if len(files) == 1:
        action, path, old, new = files[0]
        if action == "Add":
            return "Write", {"file_path": path, "content": "\n".join(new)}
        if action == "Update":
            return "Edit", {"file_path": path, "old_string": "\n".join(old), "new_string": "\n".join(new)}
    return "apply_patch", {"files": [path for _, path, _, _ in files], "patch": patch,
                           "description": "修改 %d 个文件" % len(files) if files else ""}


def _shell_text(command):
    if isinstance(command, list):
        # ["/bin/zsh", "-lc", "真正的命令"]、Windows 上 ["powershell.exe", "-Command", "…"] / ["cmd.exe", "/c", "…"] 只留最后一段
        if len(command) >= 3 and str(command[-2]).lower() in ("-lc", "-c", "-command", "/c"):
            return command[-1]
        return " ".join(str(part) for part in command)
    return command if isinstance(command, str) else ""


CODEX_SHELL_TOOLS = ("exec_command", "shell", "shell_command", "local_shell", "container.exec", "unified_exec")


def codex_tool(name, args):
    """Codex 的工具调用 → (工具名, 输入)：尽量对上 Claude Code 的工具名"""
    if not isinstance(args, dict):
        args = {"input": args} if args not in (None, "") else {}
    if name in CODEX_SHELL_TOOLS:
        command = _shell_text(args.get("cmd") or args.get("command"))
        if command.startswith("apply_patch ") or command.startswith("apply_patch\n"):
            body = command[len("apply_patch"):].strip()
            if len(body) >= 2 and body[0] == body[-1] and body[0] in "'\"":
                body = body[1:-1]
            if "*** Begin Patch" in body:
                return patch_tool(body.replace("\\n", "\n") if "\n" not in body else body)
        out = {"command": command}
        if isinstance(args.get("justification"), str):
            out["description"] = args["justification"]
        if isinstance(args.get("workdir"), str):
            out["cwd"] = args["workdir"]
        return "Bash", out
    if name == "apply_patch":
        return patch_tool(args.get("input") or args.get("patch") or "")
    if name == "update_plan":
        steps = args.get("plan") if isinstance(args.get("plan"), list) else []
        todos = [{"content": step.get("step") or "", "status": step.get("status") or "pending",
                  "activeForm": step.get("step") or ""} for step in steps if isinstance(step, dict)]
        return "TodoWrite", {"todos": todos}
    if name == "view_image":
        return "Read", {"file_path": args.get("path") or ""}
    if name == "request_user_input":
        questions = []
        for item in args.get("questions") or []:
            if isinstance(item, dict):
                questions.append({"question": item.get("question") or "", "header": item.get("header") or "",
                                  "options": [{"label": o.get("label") or "", "description": o.get("description") or ""}
                                              for o in (item.get("options") or []) if isinstance(o, dict)],
                                  "multiSelect": False})
        return "AskUserQuestion", {"questions": questions}
    if name in ("web_search", "web_search_preview"):
        return "WebSearch", {"query": args.get("query") or ""}
    return name or "tool", args


# Codex 往对话里塞的上下文（环境、说明、技能），不是用户说的话
CODEX_CONTEXT_TAGS = ("environment_context", "user_instructions", "permissions instructions", "skills_instructions",
                      "apps_instructions", "collaboration_mode", "user_shell_command", "subagent_notification",
                      "INSTRUCTIONS", "personality_spec")


def _codex_output(output):
    """工具输出：去掉「Chunk ID / Wall time / Process exited with code N / Output:」这段头，认出退出码"""
    if isinstance(output, dict):
        text = output.get("content") if isinstance(output.get("content"), str) else json.dumps(output, ensure_ascii=False)
        failed = output.get("success") is False
    elif isinstance(output, list):
        text = "\n".join(part.get("text") for part in output if isinstance(part, dict) and isinstance(part.get("text"), str))
        failed = False
    else:
        text = output if isinstance(output, str) else ""
        failed = False
    match = re.search(r"Process exited with code (-?\d+)", text[:400])
    if match:
        failed = failed or match.group(1) != "0"
        cut = text.find("\nOutput:\n")
        if cut != -1:
            text = text[cut + len("\nOutput:\n"):]
    return text.rstrip("\n"), failed


def codex_goal_event(text):
    """Codex 关于目标的内部上下文 → 对话里一行提示的字段：source="user_goal" 是你设定 / 暂停 / 继续，source="goal" 是它自己接着做的一轮"""
    source = re.match(r'^<codex_internal_context source="([\w-]+)"', text)
    source = source.group(1) if source else ""
    if source == "goal":
        return {"text": "继续推进目标", "goal": "check"}
    if source != "user_goal":
        return None
    objective = re.search(r'User set the goal: "(.*?)"\s*\n(?:User set goal status|</codex_internal_context>)', text, re.S)
    if objective:
        return {"text": "已设定目标", "detail": objective.group(1), "goal": "set"}
    status = re.search(r'User set goal status: "(\w+)"', text)
    if status:
        return {"paused": {"text": "已暂停目标", "goal": "paused"}, "active": {"text": "已继续目标", "goal": "set"}}.get(status.group(1))
    if "clear" in text.lower():
        return {"text": "已清除目标", "goal": "cleared"}
    return None


def normalize_codex_line(offset, entry):
    """Codex rollout 的一行 → 若干对话项（id 规则同 Claude：「行偏移.序号」）。认不出的行返回空"""
    if not isinstance(entry, dict):
        return []
    etype = entry.get("type")
    payload = entry.get("payload") if isinstance(entry.get("payload"), dict) else {}
    ptype = payload.get("type")
    ts = parse_ts(entry.get("timestamp"))
    items = []

    def base():
        return {"id": "%d.%d" % (offset, len(items)), "ts": ts}

    if etype == "compacted" or (etype == "event_msg" and ptype == "context_compacted"):
        return [dict(base(), t="event", text="上下文已压缩")]
    if etype == "event_msg":
        if ptype == "error" and isinstance(payload.get("message"), str):
            return [dict(base(), t="event", level="error", text="出错：%s" % payload["message"])]
        if ptype == "turn_aborted":
            return [dict(base(), t="event", text="已中断")]
        return []
    if etype != "response_item":
        return []

    if ptype == "message":
        role = payload.get("role")
        blocks = payload.get("content") if isinstance(payload.get("content"), list) else []
        if role == "user":
            texts, images = [], []
            for index, block in enumerate(blocks):
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "input_text" and isinstance(block.get("text"), str):
                    text = block["text"].strip()
                    tag = re.match(r"^<([A-Za-z_ ]+)>", text)
                    if tag and tag.group(1) in CODEX_CONTEXT_TAGS:
                        continue
                    if text.startswith("<codex_internal_context"):
                        # Codex 自己塞给模型的上下文：目标的设定、每一轮「接着做」显示成一行提示，别的不显示
                        event = codex_goal_event(text)
                        if event:
                            items.append(dict(base(), t="event", **event))
                        continue
                    if text.startswith("<turn_aborted>"):
                        continue   # 给模型看的中断说明；同一次中断还有 turn_aborted 事件，那条记成「已中断」
                    if text.startswith("# AGENTS.md instructions"):
                        continue
                    texts.append(text)
                elif block.get("type") == "input_image":
                    url = block.get("image_url") if isinstance(block.get("image_url"), str) else ""
                    mime = url[5:url.find(";")] if url.startswith("data:") and ";" in url else "image/png"
                    images.append({"ref": "%d.%d" % (offset, index), "mime": mime})
            text, attached = split_attachments("\n\n".join(texts))
            if text or images or attached:
                text, truncated = clip(text, USER_TEXT_MAX)
                item = dict(base(), t="user", text=text)
                if images or attached:
                    item["images"] = images + attached
                if truncated:
                    item["truncated"] = True
                items.append(item)
        elif role == "assistant":
            for block in blocks:
                if isinstance(block, dict) and block.get("type") == "output_text" and (block.get("text") or "").strip():
                    text, truncated = clip(block["text"], ASSISTANT_TEXT_MAX)
                    item = dict(base(), t="text", text=text)
                    if truncated:
                        item["truncated"] = True
                    items.append(item)
        return items

    if ptype == "reasoning":
        summary = [part.get("text") for part in (payload.get("summary") or [])
                   if isinstance(part, dict) and isinstance(part.get("text"), str)]
        if not summary:
            summary = [part.get("text") for part in (payload.get("content") or [])
                       if isinstance(part, dict) and isinstance(part.get("text"), str)]
        thought, _ = clip("\n\n".join(summary).strip(), ASSISTANT_TEXT_MAX)
        return [dict(base(), t="thinking", text=thought)]

    if ptype in ("function_call", "custom_tool_call", "local_shell_call"):
        if ptype == "local_shell_call":
            action = payload.get("action") if isinstance(payload.get("action"), dict) else {}
            name, args = "local_shell", {"command": action.get("command")}
        elif ptype == "custom_tool_call":
            name, args = payload.get("name"), {"input": payload.get("input")}
        else:
            name = payload.get("name")
            try:
                args = json.loads(payload.get("arguments") or "{}")
            except ValueError:
                args = {"input": payload.get("arguments")}
        tool, tool_input = codex_tool(name, args)
        return [dict(base(), t="tool", toolId=payload.get("call_id") or payload.get("id"), name=tool,
                     brief=tool_brief(tool, tool_input), input=shrink(tool_input), **stage_hint(tool, tool_input))]

    if ptype in ("function_call_output", "custom_tool_call_output"):
        text, failed = _codex_output(payload.get("output"))
        full = len(text)
        text, truncated = clip(text, TOOL_RESULT_MAX)
        item = dict(base(), t="result", toolId=payload.get("call_id"), text=text, isError=failed)
        if truncated:
            item["truncated"] = True
            item["fullLength"] = full
        return [item]

    if ptype == "web_search_call":
        action = payload.get("action") if isinstance(payload.get("action"), dict) else {}
        query = action.get("query") or ""
        return [dict(base(), t="tool", toolId=payload.get("id"), name="WebSearch",
                     brief=tool_brief("WebSearch", {"query": query}), input={"query": query})]
    return []


def codex_media(path, ref):
    """rollout 里用户发的图（data URL）→ {"mime", "data"}"""
    offset_text, _, index_text = ref.partition(".")
    entry = parse_line(read_line_at(path, int(offset_text)) or b"") or {}
    blocks = ((entry.get("payload") or {}).get("content")) or []
    block = blocks[int(index_text)] if int(index_text) < len(blocks) else {}
    url = block.get("image_url") if isinstance(block, dict) else None
    if not isinstance(url, str) or not url.startswith("data:") or "," not in url:
        raise RuntimeError("图片不存在：%s" % ref)
    head, data = url.split(",", 1)
    return {"mime": head[5:].split(";")[0] or "image/png", "data": data}


_CODEX_SCANS = {}


def scan_codex_rollout(path):
    """读 rollout 尾部：最后一句回复、还在跑（没有输出）的工具、标题兜底（第一句用户的话）"""
    result = {"message": None, "messageId": None, "pendingTool": None, "pendingBrief": None, "pendingId": None,
              "mtime": None, "firstUser": None}
    if not path:
        return result
    try:
        stat = os.stat(path)
    except OSError:
        return result
    key = (stat.st_size, stat.st_mtime)
    cached = _CODEX_SCANS.get(path)
    if cached and cached[0] == key:
        return cached[1]
    result["mtime"] = stat.st_mtime
    start = max(0, stat.st_size - TRANSCRIPT_TAIL_BYTES)
    try:
        with open(path, "rb") as handle:
            handle.seek(start)
            data = handle.read()
    except OSError:
        return result
    lines = data.split(b"\n")
    if start > 0:
        lines = lines[1:]
    calls = {}
    cursor = start + ((len(data.split(b"\n", 1)[0]) + 1) if start > 0 else 0)
    for raw in lines:
        offset = cursor
        cursor += len(raw) + 1
        entry = parse_line(raw)
        if entry is None:
            continue
        for item in normalize_codex_line(offset, entry):
            if item["t"] == "text":
                result["message"], result["messageId"] = item["text"][:MESSAGE_MAX_CHARS], item["id"]
            elif item["t"] == "tool":
                calls[item.get("toolId")] = item
            elif item["t"] == "result":
                calls.pop(item.get("toolId"), None)
            elif item["t"] == "user" and result["firstUser"] is None:
                result["firstUser"] = item.get("text")
    if calls:
        last = list(calls.values())[-1]
        result["pendingTool"], result["pendingBrief"], result["pendingId"] = last["name"], last.get("brief"), last.get("toolId")
    _CODEX_SCANS[path] = (key, result)
    if len(_CODEX_SCANS) > 200:
        _CODEX_SCANS.pop(next(iter(_CODEX_SCANS)))
    return result


def _title_from(text):
    line = (text or "").strip().split("\n", 1)[0].strip()
    return (line[:40] + "…") if len(line) > 40 else line


# 逐字流式的增量通知用不上（对话内容读 rollout，整条出来再推），不要
CODEX_QUIET = ["item/agentMessage/delta", "item/plan/delta", "item/reasoning/summaryTextDelta", "item/reasoning/summaryPartAdded",
               "item/reasoning/textDelta", "item/commandExecution/outputDelta", "item/fileChange/outputDelta",
               "command/exec/outputDelta", "process/outputDelta", "turn/diff/updated", "fuzzyFileSearch/sessionUpdated"]

# 审批按键 → Codex 的决定：1 允许、2 本会话都允许、3 / Esc 拒绝并停下（同 Claude Code 按 Esc：等你说怎么改）
CODEX_DECISIONS = {"1": "accept", "enter": "accept", "y": "accept", "2": "acceptForSession", "p": "acceptForSession",
                   "3": "cancel", "esc": "cancel", "n": "decline"}
# 老协议（v1）的说法
CODEX_LEGACY_DECISIONS = {"accept": "approved", "acceptForSession": "approved_for_session", "decline": "denied", "cancel": "abort"}


class CodexLink:
    """连 Codex 的本机守护进程：会话列表、状态、审批、发消息"""

    IDLE_UNSUBSCRIBE = 90   # 附着过的会话空闲这么久（秒）就退订，让它能正常卸载

    def __init__(self):
        self.lock = threading.RLock()
        self.ws = None
        self.threads = {}      # 会话 id → thread（thread/read、thread/started 给的元数据，status 随广播更新）
        self.pending = {}      # 会话 id → [守护进程发来、还没人答的审批 / 提问请求]
        self.turns = {}        # 会话 id → 正在进行的 turn id（附着后才收得到）
        self.usage = {}        # 会话 id → 用量
        self.errors = {}       # 会话 id → 上一轮出错的原因
        self.subscribed = {}   # 会话 id → 最近一次需要附着的时间
        self.waiters = {}
        self.next_id = 0
        self.tasks = queue.Queue()   # 读线程不能自己发请求再等回复（会等到自己身上），交给工作线程
        self.started = False
        self.connected = False

    def start(self):
        if self.started:
            return
        self.started = True
        threading.Thread(target=self.run, name="codex", daemon=True).start()

    # --- 连接 ---

    def run(self):
        delay = 2
        while True:
            if not os.path.lexists(CODEX_SOCKET):
                time.sleep(3)
                continue
            try:
                ws = open_codex_daemon()
                with self.lock:
                    self.ws = ws
                reader = threading.Thread(target=self.read, args=(ws,), name="codex-read", daemon=True)
                reader.start()
                self.setup()
                self.connected = True
                log("已连上 Codex 守护进程（%d 个会话）" % len(self.threads))
                delay = 2
                self.work(reader)
            except Exception as exc:
                log("Codex 连接中断：%r" % exc)
            self.disconnect()
            time.sleep(delay)
            delay = min(delay * 2, 30)

    def setup(self):
        self.call("initialize", {"clientInfo": {"name": "kiteline", "title": "Kiteline", "version": WATCHER_VERSION},
                                 "capabilities": {"optOutNotificationMethods": CODEX_QUIET}}, timeout=10)
        self.notify("initialized")
        cursor = None
        while True:
            page = self.call("thread/loaded/list", {"cursor": cursor} if cursor else {}, timeout=10)
            for thread_id in page.get("data") or []:
                try:
                    self.load(thread_id)
                except Exception as exc:
                    log("读取 Codex 会话 %s 失败：%r" % (thread_id, exc))
            cursor = page.get("nextCursor")
            if not cursor:
                break

    def disconnect(self):
        with self.lock:
            if self.ws is not None:
                self.ws.close()
            self.ws = None
            self.connected = False
            self.threads.clear()
            self.pending.clear()
            self.turns.clear()
            self.subscribed.clear()
            for box in self.waiters.values():
                box.put(None)
            self.waiters.clear()

    def work(self, reader):
        """工作线程：执行读线程交过来的事，顺带把闲下来的会话退订"""
        while reader.is_alive():
            try:
                task = self.tasks.get(timeout=1)
            except queue.Empty:
                task = None
            if task is not None:
                try:
                    task()
                except Exception as exc:
                    log("Codex 后台任务失败：%r" % exc)
            self.release_idle()

    def read(self, ws):
        try:
            while True:
                message = json.loads(ws.recv())
                if not isinstance(message, dict):
                    continue
                if "method" not in message:
                    box = self.waiters.pop(message.get("id"), None)
                    if box is not None:
                        box.put(message)
                elif "id" in message:
                    self.on_request(message)
                else:
                    self.on_notify(message)
        except Exception as exc:
            if not isinstance(exc, EOFError):
                log("Codex 读取出错：%r" % exc)

    def call(self, method, params=None, timeout=15):
        with self.lock:
            ws = self.ws
            if ws is None:
                raise RuntimeError("没有连上 Codex（Codex 没在运行？）")
            self.next_id += 1
            request_id = self.next_id
            box = queue.Queue()
            self.waiters[request_id] = box
        ws.send(json.dumps({"id": request_id, "method": method, "params": params or {}}))
        try:
            reply = box.get(timeout=timeout)
        except queue.Empty:
            raise RuntimeError("Codex 没有响应（%s）" % method)
        finally:
            self.waiters.pop(request_id, None)
        if reply is None:
            raise RuntimeError("和 Codex 的连接断开了")
        if reply.get("error"):
            error = reply["error"]
            raise RuntimeError("Codex：%s" % (error.get("message") if isinstance(error, dict) else error))
        return reply.get("result") or {}

    def notify(self, method, params=None):
        ws = self.ws
        if ws is not None:
            ws.send(json.dumps({"method": method, "params": params} if params else {"method": method}))

    def reply(self, request, result):
        ws = self.ws
        if ws is None:
            raise RuntimeError("和 Codex 的连接断开了")
        ws.send(json.dumps({"id": request["id"], "result": result}))
        thread_id = self._thread_of(request)
        with self.lock:
            self.pending[thread_id] = [r for r in self.pending.get(thread_id, []) if r["id"] != request["id"]]

    # --- 守护进程推来的 ---

    @staticmethod
    def _thread_of(message):
        params = message.get("params") or {}
        return params.get("threadId") or params.get("conversationId")

    def load(self, thread_id):
        thread = (self.call("thread/read", {"threadId": thread_id}) or {}).get("thread")
        if isinstance(thread, dict) and thread.get("id"):
            with self.lock:
                old = self.threads.get(thread_id) or {}
                if old.get("status") and not thread.get("status"):
                    thread["status"] = old["status"]
                self.threads[thread_id] = thread

    def on_request(self, message):
        """审批、提问：留着等手机上的人答（终端那边也会弹框，谁先答算谁的）"""
        thread_id = self._thread_of(message)
        if not thread_id:
            return
        with self.lock:
            requests = self.pending.setdefault(thread_id, [])
            if all(r["id"] != message["id"] for r in requests):
                message["at"] = _now_ms()
                requests.append(message)

    def on_notify(self, message):
        method = message.get("method")
        params = message.get("params") or {}
        thread_id = params.get("threadId")
        with self.lock:
            if method == "thread/started":
                thread = params.get("thread") or {}
                if thread.get("id"):
                    self.threads[thread["id"]] = thread
                return
            if not thread_id:
                return
            thread = self.threads.get(thread_id)
            if method == "thread/status/changed":
                status = params.get("status") or {}
                if thread is None:
                    self.tasks.put(lambda tid=thread_id: self.load(tid))
                else:
                    thread["status"] = status
                    thread["statusAt"] = _now_ms()
                flags = status.get("activeFlags") or []
                if ("waitingOnApproval" in flags or "waitingOnUserInput" in flags) and thread_id not in self.subscribed:
                    # 等确认了：附着上去，守护进程会把待答的请求补发过来
                    self.subscribed[thread_id] = time.time()
                    self.tasks.put(lambda tid=thread_id: self.subscribe(tid))
                if status.get("type") != "active":
                    self.turns.pop(thread_id, None)
                if status.get("type") == "active":
                    self.errors.pop(thread_id, None)
            elif method in ("thread/closed", "thread/archived", "thread/deleted"):
                for table in (self.threads, self.pending, self.turns, self.subscribed, self.usage, self.errors):
                    table.pop(thread_id, None)
            elif method == "thread/name/updated" and thread is not None:
                thread["name"] = params.get("threadName")
            elif method == "thread/tokenUsage/updated":
                self.usage[thread_id] = params.get("tokenUsage")
            elif method == "turn/started":
                self.turns[thread_id] = (params.get("turn") or {}).get("id")
            elif method == "turn/completed":
                turn = params.get("turn") or {}
                self.turns.pop(thread_id, None)
                error = turn.get("error") if isinstance(turn.get("error"), dict) else None
                if turn.get("status") == "failed" and error and error.get("message"):
                    self.errors[thread_id] = error["message"]
            elif method == "serverRequest/resolved":
                request_id = params.get("requestId")
                self.pending[thread_id] = [r for r in self.pending.get(thread_id, []) if r["id"] != request_id]

    # --- 附着 / 退订 ---

    def subscribe(self, thread_id):
        try:
            result = self.call("thread/resume", {"threadId": thread_id}, timeout=20)
        except Exception:
            with self.lock:
                self.subscribed.pop(thread_id, None)
            raise
        with self.lock:
            self.subscribed[thread_id] = time.time()
            thread = result.get("thread")
            if isinstance(thread, dict) and thread.get("id") and thread_id in self.threads:
                status = self.threads[thread_id].get("status")
                self.threads[thread_id].update(thread)
                if status and not thread.get("status"):
                    self.threads[thread_id]["status"] = status

    def ensure_subscribed(self, thread_id):
        with self.lock:
            if thread_id in self.subscribed:
                self.subscribed[thread_id] = time.time()
                return
        self.subscribe(thread_id)

    def release_idle(self):
        now = time.time()
        with self.lock:
            idle = [tid for tid, at in self.subscribed.items()
                    if now - at > self.IDLE_UNSUBSCRIBE and not self.pending.get(tid)
                    and ((self.threads.get(tid) or {}).get("status") or {}).get("type") != "active"]
            for tid in idle:
                self.subscribed.pop(tid, None)
        for tid in idle:
            try:
                self.call("thread/unsubscribe", {"threadId": tid}, timeout=10)
            except Exception as exc:
                log("Codex 退订失败：%r" % exc)

    def active_turn(self, thread_id):
        with self.lock:
            turn_id = self.turns.get(thread_id)
        if turn_id:
            return turn_id
        page = self.call("thread/turns/list", {"threadId": thread_id, "limit": 1, "sortDirection": "desc"})
        for turn in page.get("data") or []:
            if turn.get("status") == "inProgress":
                return turn.get("id")
        return None

    # --- 手机上的操作 ---

    def send(self, thread_id, text, images):
        self.ensure_subscribed(thread_id)
        content = [{"type": "text", "text": text}] if text else []
        content += [{"type": "localImage", "path": path} for path in images]
        if not content:
            raise RuntimeError("内容为空")
        with self.lock:
            busy = (((self.threads.get(thread_id) or {}).get("status")) or {}).get("type") == "active"
        if busy:
            turn_id = self.active_turn(thread_id)
            if turn_id:
                # 正在干活：插进这一轮（Codex 终端里在工作时打字也是这样）
                self.call("turn/steer", {"threadId": thread_id, "expectedTurnId": turn_id, "input": content})
                return "已加入正在进行的这一轮"
        self.call("turn/start", {"threadId": thread_id, "input": content})
        return "已发送"

    def key(self, thread_id, key):
        with self.lock:
            requests = list(self.pending.get(thread_id) or [])
            if thread_id in self.subscribed:
                self.subscribed[thread_id] = time.time()
        request = requests[0] if requests else None
        if request is None:
            if key == "esc":
                turn_id = self.active_turn(thread_id)
                if not turn_id:
                    raise RuntimeError("这个 Codex 会话现在没有在工作")
                self.ensure_subscribed(thread_id)
                self.call("turn/interrupt", {"threadId": thread_id, "turnId": turn_id})
                return "已中断"
            raise RuntimeError("这个 Codex 会话现在没有待确认的操作")
        self.reply(request, codex_reply(request, key))
        return "已选择"

    def goal(self, thread_id, action, objective):
        """/goal：设定、清除、暂停、继续目标（同 Codex 终端里的 /goal）。设定以后 Codex 自己一轮接一轮做，直到它确认达成"""
        if action == "show":
            goal = (self.call("thread/goal/get", {"threadId": thread_id}) or {}).get("goal")
            return "当前目标：%s" % goal["objective"] if isinstance(goal, dict) and goal.get("objective") else "这个会话没有设定目标"
        if action == "clear":
            self.call("thread/goal/clear", {"threadId": thread_id, "origin": "user"})
            return "已清除目标"
        params = {"threadId": thread_id, "origin": "user"}
        if action == "set":
            params.update(objective=objective, status="active")
        else:
            params["status"] = "paused" if action == "pause" else "active"
        self.call("thread/goal/set", params)
        return {"set": "已设定目标", "pause": "已暂停目标", "resume": "已继续目标"}[action]

    def close(self, thread_id):
        # 归档（同 Codex 里的 /archive）：从后台服务卸载、从会话列表拿掉，在 Codex 里能找回。
        # 终端里的 Codex 界面本身关不了：它不认外部的退出请求，发信号要么没反应、要么不收尾就退（终端会停在原始模式）
        self.call("thread/archive", {"threadId": thread_id}, timeout=20)
        with self.lock:
            self.threads.pop(thread_id, None)
            self.pending.pop(thread_id, None)
            self.subscribed.pop(thread_id, None)
        return "已关闭会话（已在 Codex 中归档；终端里的 Codex 界面仍开着，可直接关掉）"

    def answer(self, thread_id, answers):
        with self.lock:
            request = next((r for r in self.pending.get(thread_id) or [] if r.get("method") == "item/tool/requestUserInput"), None)
        if request is None:
            raise RuntimeError("这个 Codex 会话现在没有待回答的提问")
        self.reply(request, codex_answers(request, answers))
        return "已回答"

    # --- 快照 ---

    def snapshots(self):
        with self.lock:
            threads = [dict(t) for t in self.threads.values()]
            pending = {tid: list(reqs) for tid, reqs in self.pending.items()}
            usage = dict(self.usage)
            errors = dict(self.errors)
        children = {}
        for thread in threads:
            parent = thread.get("parentThreadId")
            if parent:
                children[parent] = children.get(parent, 0) + 1
        out = []
        for thread in threads:
            snap = self._snapshot(thread, pending.get(thread["id"]) or [], usage.get(thread["id"]),
                                  errors.get(thread["id"]), children.get(thread["id"], 0))
            if snap:
                out.append(snap)
        return out

    @staticmethod
    def _snapshot(thread, requests, usage, error, subagents):
        if thread.get("parentThreadId") or thread.get("ephemeral"):
            return None
        source = thread.get("source")
        if isinstance(source, dict) and source.get("subAgent"):
            return None
        status = thread.get("status") if isinstance(thread.get("status"), dict) else {}
        state = status.get("type") or "idle"
        if state == "notLoaded":
            return None
        thread_id = thread["id"]
        cwd = thread.get("cwd") or ""
        path = thread.get("path")
        scan = scan_codex_rollout(path)
        flags = status.get("activeFlags") or []
        waiting_for, pending_tool, pending_id = None, None, None
        if requests:
            request = requests[0]
            waiting_for, pending_tool = codex_request_text(request)
            pending_id = str(request.get("id"))
        elif "waitingOnApproval" in flags or "waitingOnUserInput" in flags:
            waiting_for = "等待你回答" if "waitingOnUserInput" in flags else "等待批准"
        if waiting_for:
            activity, reason = "waiting", waiting_for
            pending_tool = pending_tool or scan["pendingTool"]
        elif state == "active":
            activity, reason = "busy", scan["pendingBrief"] or "正在工作"
        else:
            activity, reason = "idle", scan["message"]
        title = thread.get("name") or _title_from(thread.get("preview") or scan["firstUser"]) or None
        created = thread.get("createdAt")
        updated = thread.get("updatedAt")
        return {
            "pid": None,
            "sessionId": thread_id,
            "name": title or thread_id[:8],
            "title": title,
            "cwd": cwd,
            "cwdShort": display_cwd(cwd),
            "status": state,
            "waitingFor": waiting_for,
            "needs": None,
            "detail": None,
            "activity": activity,
            "reason": reason,
            "activityText": scan["pendingBrief"] if activity == "busy" else None,
            "message": scan["message"],
            "messageUuid": scan["messageId"],
            "error": {"kind": "api", "text": "Codex 出错已停止：%s" % error[:160]} if error and activity == "idle" else None,
            "effort": {"effort": thread["reasoningEffort"]} if thread.get("reasoningEffort") else None,
            "subagents": subagents,
            "pendingTool": pending_tool if activity == "waiting" else None,
            "pendingId": pending_id or (scan["pendingId"] if activity == "waiting" else None),
            "startedAt": int(created * 1000) if isinstance(created, (int, float)) else None,
            "statusUpdatedAt": thread.get("statusAt"),
            "updatedAt": int(updated * 1000) if isinstance(updated, (int, float)) else None,
            "version": thread.get("cliVersion"),
            "entrypoint": "codex",
            "sessionKind": source if isinstance(source, str) else None,
            "tmuxPane": None,
            "usage": codex_usage(usage, thread.get("model")),
            "transcriptPath": path,
            "transcriptUpdatedAt": int(scan["mtime"] * 1000) if scan["mtime"] else None,
            "agent": "codex",
        }


def codex_request_text(request):
    """待答的请求 → (卡在哪的一句话, 工具名)"""
    method = request.get("method") or ""
    params = request.get("params") or {}
    reason = params.get("reason") if isinstance(params.get("reason"), str) else ""
    if "commandExecution" in method or method == "execCommandApproval":
        command = _shell_text(params.get("command"))
        return (reason or "等待批准命令：%s" % command[:80]), "Bash"
    if "fileChange" in method or method == "applyPatchApproval":
        return (reason or "等待批准修改文件"), "Edit"
    if "permissions" in method:
        return (reason or "请求额外权限（网络或文件）"), "Permissions"
    if "requestUserInput" in method:
        questions = params.get("questions") or []
        first = questions[0].get("question") if questions and isinstance(questions[0], dict) else ""
        return (first or "等待你回答"), "AskUserQuestion"
    if "elicitation" in method:
        return (params.get("message") or "MCP 工具请求确认"), "MCP"
    return "等待确认", None


def codex_usage(usage, model):
    if not isinstance(usage, dict):
        return None
    last = usage.get("last") if isinstance(usage.get("last"), dict) else {}
    total = usage.get("total") if isinstance(usage.get("total"), dict) else {}
    context = int(last.get("inputTokens") or 0) + int(last.get("outputTokens") or 0)
    window = usage.get("modelContextWindow") or 0
    return {
        "context": context,
        "window": int(window) if window else max(context, 1),
        "input": int(total.get("inputTokens") or 0) - int(total.get("cachedInputTokens") or 0),
        "output": int(total.get("outputTokens") or 0),
        "cacheRead": int(total.get("cachedInputTokens") or 0),
        "cacheWrite": int(total.get("cacheWriteInputTokens") or 0),
        "requests": 0,
        "model": model,
        "cost": None,
        "costAt": None,
    }


def _answer_for(answers, question, index):
    """手机答的 [{question, picked, other}] 里找这一题的答案（先按题目对，对不上按顺序）"""
    answers = answers if isinstance(answers, list) else []
    chosen = next((a for a in answers if isinstance(a, dict) and a.get("question") == question), None)
    if chosen is None and index < len(answers) and isinstance(answers[index], dict):
        chosen = answers[index]
    if not chosen:
        return []
    picked = [str(p) for p in (chosen.get("picked") or []) if p]
    other = (chosen.get("other") or "").strip() if isinstance(chosen.get("other"), str) else ""
    if other:
        picked.append(other)
    return picked


def _pick_decision(decision, available):
    """请求带了 availableDecisions 的，只能在里面挑：要「本会话都允许」而没有这个选项时，退到「这类命令以后不再问」，再退到「允许」；
    要拒绝而没有 cancel 时用 decline"""
    if not isinstance(available, list) or not available:
        return decision
    plain = [d for d in available if isinstance(d, str)]
    if decision in plain:
        return decision
    if decision == "acceptForSession":
        amend = next((d for d in available if isinstance(d, dict) and "acceptWithExecpolicyAmendment" in d), None)
        return amend if amend is not None else ("accept" if "accept" in plain else decision)
    if decision == "cancel" and "decline" in plain:
        return "decline"
    if decision == "decline" and "cancel" in plain:
        return "cancel"
    return decision


def codex_reply(request, key):
    """手机按键（1 / 2 / Esc）→ 给 Codex 审批 / 提问请求的回复（共享后台服务和桌面版、VS Code 扩展的 IPC 共用）"""
    decision = CODEX_DECISIONS.get(key)
    if decision is None:
        raise RuntimeError("Codex 会话不支持这个操作")
    method = request.get("method")
    params = request.get("params") or {}
    if method in ("item/commandExecution/requestApproval", "item/fileChange/requestApproval"):
        return {"decision": _pick_decision(decision, params.get("availableDecisions"))}
    if method in ("execCommandApproval", "applyPatchApproval"):
        return {"decision": CODEX_LEGACY_DECISIONS[decision]}
    if method == "item/permissions/requestApproval":
        granted = params.get("permissions") if decision.startswith("accept") else {}
        return {"permissions": granted or {}, "scope": "session" if decision == "acceptForSession" else "turn"}
    if method == "mcpServer/elicitation/request":
        accepted = decision.startswith("accept")
        return {"action": "accept" if accepted else "decline", "content": {} if accepted else None}
    if method == "item/tool/requestUserInput":
        if key != "esc":
            raise RuntimeError("请在提问卡片上选择答案")
        return {"answers": {}}
    raise RuntimeError("不认识的确认请求：%s" % method)


def codex_answers(request, answers):
    """手机答的提问 → requestUserInput 的回复：按题目对上 id"""
    result = {}
    for index, question in enumerate((request.get("params") or {}).get("questions") or []):
        result[question.get("id") or str(index)] = {"answers": _answer_for(answers, question.get("question"), index)}
    return {"answers": result}


# --- Codex 桌面版、VS Code 扩展：IPC 总线 ---
#
# 这两个不用共享后台服务：各自起私有的 codex 进程，再经一条本机 IPC 总线互相「跟随」对方的会话
# （Mac / Linux：~/.codex/ipc/ipc.sock，Windows：命名管道 \\.\pipe\codex-ipc；每帧「4 字节小端长度 + JSON」）。
# 最先启动的那个进程当路由，其余连上来发 initialize 拿客户端 id；请求由路由问遍各客户端「谁能处理」再转过去。
# Kiteline 只当客户端（从不当路由）：对最近的会话问 thread-owner-discovery，找到「所有者」（会话开着的那个窗口）就跟随，
# 所有者推来会话状态的快照和补丁（immer 格式），里面的 threadRuntimeStatus、requests 和共享后台服务的同一个格式；
# 审批、发消息、中断用 thread-follower-* 请求交给所有者执行。对话内容照旧读 rollout（状态里有 rolloutPath）。
# 每个方法都带版本号，对不上会被对方丢掉：运行时从本机装着的 Codex 扩展里读版本表，读不到用下面的。

CODEX_IPC_VERSIONS = {
    "thread-stream-state-changed": 11, "thread-stream-following-changed": 1, "thread-owner-discovery": 1,
    "thread-follower-start-turn": 2, "thread-follower-steer-turn": 1, "thread-follower-interrupt-turn": 4,
    "thread-follower-command-approval-decision": 1, "thread-follower-file-approval-decision": 1,
    "thread-follower-permissions-request-approval-response": 1, "thread-follower-submit-user-input": 1,
    "thread-follower-submit-mcp-server-elicitation-response": 1,
}
# 所有者推来的状态里只用这几项（补丁改别处的不用应用）
CODEX_IPC_FIELDS = ("threadRuntimeStatus", "requests", "latestTokenUsageInfo", "title", "latestModel", "latestReasoningEffort",
                    "cwd", "rolloutPath", "createdAt", "updatedAt", "source", "originator", "id")
CODEX_IPC_FOLLOWER = {
    "item/commandExecution/requestApproval": ("thread-follower-command-approval-decision", "decision"),
    "item/fileChange/requestApproval": ("thread-follower-file-approval-decision", "decision"),
    "item/permissions/requestApproval": ("thread-follower-permissions-request-approval-response", "response"),
    "item/tool/requestUserInput": ("thread-follower-submit-user-input", "response"),
    "mcpServer/elicitation/request": ("thread-follower-submit-mcp-server-elicitation-response", "response"),
}
_IPC_VERSION_CACHE = {}


def codex_ipc_versions():
    """从本机装着的 Codex VS Code 扩展里读方法版本表（Codex 升级会改，对不上的消息对方直接丢）"""
    roots = [os.path.join(HOME, folder, "extensions") for folder in (".vscode", ".vscode-insiders", ".cursor", ".windsurf", ".vscode-server")]
    found = []
    for root in roots:
        for path in globlib.glob(os.path.join(root, "openai.chatgpt-*", "out", "extension.js")):
            try:
                found.append((os.path.getmtime(path), path))
            except OSError:
                continue
    versions = dict(CODEX_IPC_VERSIONS)
    if not found:
        return versions
    path = max(found)[1]
    stamp = os.path.getmtime(path)
    cached = _IPC_VERSION_CACHE.get(path)
    if cached and cached[0] == stamp:
        return cached[1]
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            text = handle.read()
        anchor = text.find('"thread-stream-state-changed":')
        start = text.rfind("{", 0, anchor)
        end = text.find("}", anchor)
        table = json.loads(text[start:end + 1]) if anchor != -1 and start != -1 and end != -1 else {}
        versions.update({k: int(v) for k, v in table.items() if isinstance(v, int)})
    except (OSError, ValueError):
        pass
    _IPC_VERSION_CACHE[path] = (stamp, versions)
    return versions


def apply_patches(state, patches, fields=None):
    """immer 补丁（op add / replace / remove，path 是键和下标的数组）应用到 state；fields 给了的话只应用这些顶层字段"""
    for patch in patches or []:
        path = patch.get("path") if isinstance(patch, dict) else None
        if not isinstance(path, list):
            continue
        op = patch.get("op")
        if not path:
            if op in ("add", "replace") and isinstance(patch.get("value"), dict):
                state.clear()
                state.update(patch["value"])
            continue
        if fields is not None and path[0] not in fields:
            continue
        parent = state
        try:
            for key in path[:-1]:
                parent = parent[int(key)] if isinstance(parent, list) else parent[key]
        except (KeyError, IndexError, TypeError, ValueError):
            continue
        last = path[-1]
        if isinstance(parent, list):
            if last == "length" and op == "replace" and isinstance(patch.get("value"), int):
                del parent[patch["value"]:]
                continue
            try:
                index = int(last)
            except (TypeError, ValueError):
                continue
            if op == "add":
                parent.insert(index, patch.get("value"))
            elif op == "replace":
                if index < len(parent):
                    parent[index] = patch.get("value")
                else:
                    parent.append(patch.get("value"))
            elif op == "remove" and index < len(parent):
                del parent[index]
        elif isinstance(parent, dict):
            if op in ("add", "replace"):
                parent[last] = patch.get("value")
            elif op == "remove":
                parent.pop(last, None)


class IpcPipe:
    """IPC 总线的连接：Windows 命名管道（重叠 I/O，读写可以同时进行）或 Unix socket"""

    def __init__(self):
        if IS_WINDOWS:
            import _winapi
            self.winapi = _winapi
            self.handle = _winapi.CreateFile(r"\\.\pipe\codex-ipc", _winapi.GENERIC_READ | _winapi.GENERIC_WRITE, 0, _winapi.NULL,
                                             _winapi.OPEN_EXISTING, _winapi.FILE_FLAG_OVERLAPPED, _winapi.NULL)
            self.sock = None
        else:
            path = codex_ipc_socket()
            if not path:
                raise FileNotFoundError("Codex IPC 不在")
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.settimeout(5)
            self.sock.connect(path)
            self.sock.settimeout(None)
        self.lock = threading.Lock()

    def write(self, data):
        with self.lock:
            if self.sock is not None:
                self.sock.sendall(data)
                return
            ov, _ = self.winapi.WriteFile(self.handle, data, overlapped=True)
            ov.GetOverlappedResult(True)

    def read(self, size):
        if self.sock is not None:
            return self.sock.recv(size)
        ov, _ = self.winapi.ReadFile(self.handle, size, overlapped=True)
        ov.GetOverlappedResult(True)
        return bytes(ov.getbuffer())

    def close(self):
        try:
            if self.sock is not None:
                self.sock.close()
            else:
                self.winapi.CloseHandle(self.handle)
        except Exception:
            pass


def codex_ipc_socket():
    """Mac / Linux 上 IPC 路由监听的 socket：先 CODEX_HOME/ipc/ipc.sock，路径太长时 Codex 会改用临时目录里的"""
    primary = os.path.join(CODEX_HOME, "ipc", "ipc.sock")
    if os.path.lexists(primary):
        return os.path.realpath(primary)
    uid = os.getuid() if hasattr(os, "getuid") else None
    fallback = os.path.join(tempfile.gettempdir(), "codex-ipc", "ipc-%d.sock" % uid if uid is not None else "ipc.sock")
    return fallback if os.path.lexists(fallback) else None


def codex_state_db():
    found = []
    for path in globlib.glob(os.path.join(CODEX_HOME, "state_*.sqlite")):
        match = re.search(r"state_(\d+)\.sqlite$", path)
        if match:
            found.append((int(match.group(1)), path))
    return max(found)[1] if found else None


# Codex 的目标（/goal，0.128 起）存在 CODEX_HOME 的 goals_N.sqlite（早几版在 state_N.sqlite）的 thread_goals 表里：
# 终端、桌面版、VS Code 扩展的会话都记在这，清除了就删掉那一行。状态 → 快照 goal 的 state（见 GoalBook 上面的说明）
CODEX_GOAL_STATES = {"active": "active", "paused": "paused", "blocked": "blocked", "usage_limited": "limited", "usageLimited": "limited",
                     "budget_limited": "limited", "budgetLimited": "limited", "complete": "met"}
CODEX_GOAL_NOTES = {"usage_limited": "用量已达上限", "usageLimited": "用量已达上限",
                    "budget_limited": "token 预算已用完", "budgetLimited": "token 预算已用完"}
_CODEX_GOALS = {"sig": None, "goals": {}}


def codex_goal_db():
    for prefix in ("goals_", "state_"):
        found = []
        for path in globlib.glob(os.path.join(CODEX_HOME, prefix + "*.sqlite")):
            match = re.search(r"_(\d+)\.sqlite$", path)
            if match:
                found.append((int(match.group(1)), path))
        if found:
            return max(found)[1]
    return None


def codex_goals():
    """各会话的目标 {会话 id: 快照的 goal}；没装带目标的 Codex 返回 None。按库文件（连同 -wal）的修改时间缓存，每秒问也不费事"""
    path = codex_goal_db()
    if not path:
        return None
    try:
        sig = (path, os.path.getmtime(path), os.path.getmtime(path + "-wal") if os.path.exists(path + "-wal") else 0)
    except OSError:
        return None
    if sig == _CODEX_GOALS["sig"]:
        return _CODEX_GOALS["goals"]
    goals = {}
    try:
        db = sqlite3.connect("file:%s?mode=ro" % pathname2url(path), uri=True, timeout=2)
        try:
            rows = db.execute("select thread_id, objective, status, token_budget, tokens_used, time_used_seconds, created_at_ms, updated_at_ms "
                              "from thread_goals").fetchall()
        finally:
            db.close()
    except sqlite3.Error as exc:
        if "no such table" in str(exc):
            _CODEX_GOALS.update(sig=sig, goals=None)   # 这版 Codex 没有目标：库没变就不再问
            return None
        log("读 Codex 目标失败：%r" % exc)
        return _CODEX_GOALS["goals"]
    for thread_id, objective, status, budget, used, seconds, created, updated in rows:
        goal = {"text": objective or "", "state": CODEX_GOAL_STATES.get(status, "active"), "since": created, "at": updated,
                "tokens": int(used or 0), "durationMs": int(seconds or 0) * 1000}
        if budget:
            goal["budget"] = int(budget)
        if status in CODEX_GOAL_NOTES:
            goal["note"] = CODEX_GOAL_NOTES[status]
        goals[thread_id] = goal
    _CODEX_GOALS.update(sig=sig, goals=goals)
    return goals


GOAL_CLEAR_WORDS = ("clear", "stop", "off", "reset", "none", "cancel")


def goal_command(text):
    """「/goal …」→ (动作, 目标)：set 设定 / clear 清除 / pause 暂停 / resume 继续 / show 看现在的；不是 /goal 命令返回 None。
    和 Claude Code、Codex 终端里的写法一样（Claude Code 的会话原样投进输入框，它自己认）"""
    raw = (text or "").strip()
    if not re.match(r"^/goal(\s|$)", raw):
        return None
    arg = raw[5:].strip()
    word = arg.lower()
    if not arg:
        return "show", ""
    if word in GOAL_CLEAR_WORDS:
        return "clear", ""
    if word in ("pause", "resume"):
        return word, ""
    return "set", arg


class CodexIpcLink:
    """跟随 Codex 桌面版、VS Code 扩展里开着的会话（说明见上）"""

    PROBE_EVERY = 5          # 秒：多久找一次新会话的所有者
    RECHECK_EVERY = 30       # 秒：跟随着的会话多久确认一次所有者还在

    def __init__(self):
        self.lock = threading.RLock()
        self.pipe = None
        self.client_id = "initializing-client"
        self.versions = dict(CODEX_IPC_VERSIONS)
        self.waiters = {}
        self.states = {}         # 会话 id → {"owner", "revision", "state"}
        self.checked = {}        # 会话 id → 上次问所有者的时间
        self.hints = {}          # 会话 id → 广播里提到它的客户端（所有者的候选）
        self.started = False
        self.connected = False
        self.daemon_ids = set()  # 共享后台服务那边已经列出的会话：这边不重复列
        self.recent = {}         # 会话 id → 状态库里的最后更新时间（秒）

    def start(self):
        if self.started:
            return
        self.started = True
        threading.Thread(target=self.run, name="codex-ipc", daemon=True).start()

    # --- 连接 ---

    def available(self):
        # Windows 的命名管道不去 stat（会被路由当成一次连接），直接连，连不上算不在
        return IS_WINDOWS or codex_ipc_socket() is not None

    def run(self):
        while True:
            if not self.available():
                time.sleep(5)
                continue
            try:
                pipe = IpcPipe()
                with self.lock:
                    self.pipe = pipe
                    self.client_id = "initializing-client"
                self.versions = codex_ipc_versions()
                reader = threading.Thread(target=self.read, args=(pipe,), name="codex-ipc-read", daemon=True)
                reader.start()
                result = self.request("initialize", {"clientType": "kiteline"}, timeout=10)
                self.client_id = (result.get("result") or {}).get("clientId") or self.client_id
                self.connected = True
                log("已接入 Codex 桌面版 / VS Code 扩展的 IPC 总线")
                while reader.is_alive():
                    self.probe()
                    time.sleep(1)
            except Exception as exc:
                if not isinstance(exc, (FileNotFoundError, ConnectionRefusedError)):
                    log("Codex IPC 连接中断：%r" % exc)
            self.disconnect()
            time.sleep(5)

    def disconnect(self):
        with self.lock:
            if self.pipe is not None:
                self.pipe.close()
            self.pipe = None
            self.connected = False
            self.states.clear()
            self.checked.clear()
            for box in self.waiters.values():
                box.put(None)
            self.waiters.clear()

    def send(self, message):
        pipe = self.pipe
        if pipe is None:
            raise RuntimeError("没有连上 Codex")
        data = json.dumps(message).encode("utf-8")
        pipe.write(struct.pack("<I", len(data)) + data)

    def _exact(self, pipe, size):
        buf = b""
        while len(buf) < size:
            chunk = pipe.read(size - len(buf))
            if not chunk:
                raise EOFError("IPC 断开")
            buf += chunk
        return buf

    def read(self, pipe):
        try:
            while True:
                size = struct.unpack("<I", self._exact(pipe, 4))[0]
                if size == 0 or size > 256 * 1024 * 1024:
                    raise RuntimeError("IPC 帧长度不对：%d" % size)
                message = json.loads(self._exact(pipe, size).decode("utf-8", "replace"))
                if isinstance(message, dict):
                    self.dispatch(message)
        except Exception as exc:
            if not isinstance(exc, (EOFError, OSError)):
                log("Codex IPC 读取出错：%r" % exc)

    def request(self, method, params, target=None, timeout=10):
        request_id = str(uuid.uuid4())
        box = queue.Queue()
        with self.lock:
            self.waiters[request_id] = box
        message = {"type": "request", "requestId": request_id, "sourceClientId": self.client_id,
                   "version": self.versions.get(method, 0), "method": method, "params": params, "timeoutMs": int(timeout * 1000)}
        if target:
            message["targetClientId"] = target
        self.send(message)
        try:
            reply = box.get(timeout=timeout + 1)
        except queue.Empty:
            reply = {"resultType": "error", "error": "timeout"}
        finally:
            with self.lock:
                self.waiters.pop(request_id, None)
        if reply is None:
            raise RuntimeError("和 Codex 的连接断开了")
        return reply

    def dispatch(self, message):
        kind = message.get("type")
        if kind == "response":
            with self.lock:
                box = self.waiters.pop(message.get("requestId"), None)
            if box is not None:
                box.put(message)
        elif kind == "client-discovery-request":
            # 路由在问「这个请求你能处理吗」：Kiteline 什么都不处理，马上说不能，别让别人等超时
            self.send({"type": "client-discovery-response", "requestId": message.get("requestId"), "response": {"canHandle": False}})
        elif kind == "request":
            self.send({"type": "response", "requestId": message.get("requestId"), "resultType": "error", "error": "no-handler-for-request"})
        elif kind == "broadcast":
            self.on_broadcast(message)

    def on_broadcast(self, message):
        method = message.get("method")
        params = message.get("params") or {}
        source = message.get("sourceClientId")
        conversation = params.get("conversationId")
        with self.lock:
            if method == "thread-stream-state-changed" and conversation:
                change = params.get("change") or {}
                entry = self.states.get(conversation)
                if change.get("type") == "snapshot":
                    state = change.get("conversationState") or {}
                    self.states[conversation] = {"owner": source, "revision": change.get("revision"),
                                                 "state": {k: state.get(k) for k in CODEX_IPC_FIELDS if k in state}}
                elif change.get("type") == "patches" and entry is not None and entry["owner"] == source:
                    if entry["revision"] != change.get("baseRevision"):
                        entry["stale"] = True      # 漏了补丁：下一轮重新要快照
                    else:
                        apply_patches(entry["state"], change.get("patches"), CODEX_IPC_FIELDS)
                        entry["revision"] = change.get("revision")
            elif method == "thread-stream-following-changed" and conversation and params.get("following"):
                # 有窗口在说它开着这个会话：记下来，下一轮问所有者
                self.hints[conversation] = source
            elif method == "client-status-changed" and params.get("status") == "disconnected":
                gone = params.get("clientId")
                for cid in [c for c, e in self.states.items() if e["owner"] == gone]:
                    self.states.pop(cid, None)

    # --- 找会话、跟随 ---

    def candidates(self):
        """最近活跃的会话（Codex 状态库）+ 广播里提到的"""
        ids = list(self.hints.keys())
        path = codex_state_db()
        if path:
            try:
                db = sqlite3.connect("file:%s?mode=ro" % pathname2url(path), uri=True, timeout=2)
                try:
                    since = int(time.time()) - 3 * 86400
                    rows = db.execute("select id, updated_at from threads where archived = 0 and updated_at > ? "
                                      "order by updated_at desc limit 30", (since,)).fetchall()
                finally:
                    db.close()
                for cid, updated in rows:
                    ids.append(cid)
                    self.recent[cid] = updated
            except Exception as exc:
                log("读 Codex 状态库失败：%r" % exc)
        seen, out = set(), []
        for cid in ids:
            if cid and cid not in seen:
                seen.add(cid)
                out.append(cid)
        return out

    def probe(self):
        now = time.time()
        with self.lock:
            followed = {cid: dict(e) for cid, e in self.states.items()}
        for cid in self.candidates():
            if cid in self.daemon_ids:
                continue
            entry = followed.get(cid)
            # 跟随着的半分钟确认一次；广播里提到的、10 分钟内动过的 5 秒问一次；更早的一分钟问一次
            if entry:
                every = self.RECHECK_EVERY
            elif cid in self.hints or now - self.recent.get(cid, 0) < 600:
                every = self.PROBE_EVERY
            else:
                every = 60
            if not entry or not entry.get("stale"):
                if now - self.checked.get(cid, 0) < every:
                    continue
            self.checked[cid] = now
            reply = self.request("thread-owner-discovery", {"hostId": "local", "conversationId": cid}, timeout=4)
            owner = reply.get("handledByClientId") if reply.get("resultType") == "success" else None
            if not owner:
                with self.lock:
                    self.states.pop(cid, None)
                continue
            if entry and entry["owner"] == owner and not entry.get("stale"):
                continue
            # 开始跟随：所有者把我们记成跟随者并发一份快照，之后有变化就推补丁
            with self.lock:
                if cid in self.states:
                    self.states[cid]["stale"] = False
            self.send({"type": "broadcast", "method": "thread-stream-following-changed", "sourceClientId": self.client_id,
                       "targetClientIds": [owner], "params": {"conversationId": cid, "hostId": "local", "following": True},
                       "version": self.versions.get("thread-stream-following-changed", 1)})

    # --- 快照 ---

    def snapshots(self, daemon_ids):
        self.daemon_ids = set(daemon_ids)
        with self.lock:
            entries = [(cid, dict(e["state"])) for cid, e in self.states.items() if cid not in self.daemon_ids]
        out = []
        for cid, state in entries:
            originator = str(state.get("originator") or "")
            thread = {"id": cid, "cwd": state.get("cwd") or "", "path": state.get("rolloutPath"), "name": state.get("title"),
                      "status": state.get("threadRuntimeStatus") or {"type": "idle"}, "model": state.get("latestModel"),
                      "reasoningEffort": state.get("latestReasoningEffort"), "source": state.get("source")}
            for key in ("createdAt", "updatedAt"):
                value = state.get(key)
                if isinstance(value, (int, float)):
                    thread[key] = value / 1000 if value > 10 ** 11 else value   # 状态里是毫秒，快照函数按秒算
            requests = [r for r in (state.get("requests") or []) if isinstance(r, dict) and r.get("method")]
            snap = CodexLink._snapshot(thread, requests, state.get("latestTokenUsageInfo"), None, 0)
            if snap:
                snap["entrypoint"] = "codex-vscode" if "vscode" in originator.lower() else "codex-desktop"
                out.append(snap)
        return out

    def owns(self, cid):
        with self.lock:
            return cid in self.states

    def _owner(self, cid):
        with self.lock:
            entry = self.states.get(cid)
            if entry is None:
                raise RuntimeError("这个 Codex 会话已经关了")
            return entry["owner"], dict(entry["state"])

    def _follower(self, cid, method, params, timeout=20):
        owner, _ = self._owner(cid)
        reply = self.request(method, dict(params, conversationId=cid), target=owner, timeout=timeout)
        if reply.get("resultType") != "success":
            raise RuntimeError("Codex：%s" % (reply.get("error") or "操作失败"))
        return reply.get("result") or {}

    # --- 手机上的操作 ---

    def send_message(self, cid, text, images):
        content = [{"type": "text", "text": text, "text_elements": []}] if text else []
        content += [{"type": "localImage", "path": path} for path in images]
        if not content:
            raise RuntimeError("内容为空")
        _, state = self._owner(cid)
        busy = (state.get("threadRuntimeStatus") or {}).get("type") == "active"
        if busy:
            self._follower(cid, "thread-follower-steer-turn", {
                "input": content, "clientUserMessageId": str(uuid.uuid4()),
                "restoreMessage": {"text": text, "cwd": state.get("cwd"), "context": {"workspaceRoots": [state.get("cwd")]}}})
            return "已加入正在进行的这一轮"
        self._follower(cid, "thread-follower-start-turn",
                       {"turnStart": {"request": {"threadId": cid, "input": content}, "context": {"inheritThreadSettings": True}}})
        return "已发送"

    def key(self, cid, key):
        _, state = self._owner(cid)
        requests = [r for r in (state.get("requests") or []) if isinstance(r, dict) and r.get("method")]
        if not requests:
            if key == "esc":
                if (state.get("threadRuntimeStatus") or {}).get("type") != "active":
                    raise RuntimeError("这个 Codex 会话现在没有在工作")
                # 第 3 版（不带 expectedTurnId）所有者也认
                owner, _ = self._owner(cid)
                reply = self.request("thread-follower-interrupt-turn", {"conversationId": cid, "mode": "user-stop"}, target=owner, timeout=20)
                if reply.get("resultType") == "error" and "version" in str(reply.get("error")):
                    saved = self.versions.get("thread-follower-interrupt-turn")
                    self.versions["thread-follower-interrupt-turn"] = 3
                    try:
                        reply = self.request("thread-follower-interrupt-turn", {"conversationId": cid, "mode": "user-stop"}, target=owner, timeout=20)
                    finally:
                        self.versions["thread-follower-interrupt-turn"] = saved
                if reply.get("resultType") != "success":
                    raise RuntimeError("Codex：%s" % (reply.get("error") or "中断失败"))
                return "已中断"
            raise RuntimeError("这个 Codex 会话现在没有待确认的操作")
        request = requests[0]
        method, field = CODEX_IPC_FOLLOWER.get(request.get("method"), (None, None))
        if method is None:
            raise RuntimeError("不认识的确认请求：%s" % request.get("method"))
        result = codex_reply(request, key)
        payload = result.get("decision") if field == "decision" else result
        self._follower(cid, method, {"requestId": request.get("id"), field: payload})
        return "已选择"

    def answer(self, cid, answers):
        _, state = self._owner(cid)
        request = next((r for r in (state.get("requests") or []) if isinstance(r, dict) and r.get("method") == "item/tool/requestUserInput"), None)
        if request is None:
            raise RuntimeError("这个 Codex 会话现在没有待回答的提问")
        self._follower(cid, "thread-follower-submit-user-input", {"requestId": request.get("id"), "response": codex_answers(request, answers)})
        return "已回答"


# --- OpenCode ---

# OpenCode 的工具名 → (Claude 的工具名, 字段改名)
OPENCODE_TOOLS = {
    "bash": ("Bash", {}),
    "read": ("Read", {"filePath": "file_path"}),
    "edit": ("Edit", {"filePath": "file_path", "oldString": "old_string", "newString": "new_string"}),
    "write": ("Write", {"filePath": "file_path"}),
    "glob": ("Glob", {}),
    "grep": ("Grep", {}),
    "list": ("Glob", {"path": "path"}),
    "webfetch": ("WebFetch", {}),
    "websearch": ("WebSearch", {}),
    "todowrite": ("TodoWrite", {}),
    "task": ("Task", {"subagent_type": "subagent_type"}),
    "skill": ("Skill", {}),
}
OPENCODE_PERMISSIONS = {"bash": "Bash", "edit": "Edit", "write": "Write", "read": "Read", "webfetch": "WebFetch",
                        "websearch": "WebSearch", "task": "Task", "external_directory": "Read"}


def opencode_tool(name, args):
    args = args if isinstance(args, dict) else {}
    if name == "question":
        questions = []
        for item in args.get("questions") or []:
            if isinstance(item, dict):
                questions.append({"question": item.get("question") or "", "header": item.get("header") or "",
                                  "options": [{"label": o.get("label") or "", "description": o.get("description") or ""}
                                              for o in (item.get("options") or []) if isinstance(o, dict)],
                                  "multiSelect": bool(item.get("multiple"))})
        return "AskUserQuestion", {"questions": questions}
    if name in ("patch", "apply_patch"):
        return patch_tool(args.get("patchText") or args.get("patch") or "")
    mapped = OPENCODE_TOOLS.get(name)
    if not mapped:
        return name or "tool", args
    tool, renames = mapped
    out = {}
    for key, value in args.items():
        out[renames.get(key, key)] = value
    if tool == "TodoWrite":
        out["todos"] = [{"content": t.get("content") or "", "status": t.get("status") or "pending",
                         "activeForm": t.get("content") or ""} for t in (args.get("todos") or []) if isinstance(t, dict)]
    return tool, out


def opencode_items(messages):
    """OpenCode 的消息（info + parts）→ 对话项。id =「消息创建毫秒.序号」：和 Claude 的「行偏移.序号」一样能排序、翻页"""
    items = []
    for message in messages or []:
        info = message.get("info") if isinstance(message.get("info"), dict) else {}
        parts = message.get("parts") if isinstance(message.get("parts"), list) else []
        created = int(((info.get("time") or {}).get("created")) or 0)
        role = info.get("role")

        def item_id(index):
            return "%d.%d" % (created, index)

        if role == "user":
            texts, images = [], []
            for part in parts:
                if not isinstance(part, dict):
                    continue
                if part.get("type") == "text" and not part.get("synthetic") and not part.get("ignored"):
                    texts.append(part.get("text") or "")
                elif part.get("type") == "file" and str(part.get("mime") or "").startswith("image/"):
                    url = part.get("url") or ""
                    if url.startswith("file://"):
                        images.append({"ref": "f:" + url[7:], "mime": part.get("mime")})
            text, attached = split_attachments(strip_reminders("\n\n".join(texts)))
            if text or images or attached:
                text, truncated = clip(text, USER_TEXT_MAX)
                item = {"id": item_id(0), "ts": created, "t": "user", "text": text}
                if images or attached:
                    item["images"] = images + attached
                if truncated:
                    item["truncated"] = True
                items.append(item)
            continue
        if role != "assistant":
            continue
        for index, part in enumerate(parts):
            if not isinstance(part, dict):
                continue
            ptype = part.get("type")
            ts = ((part.get("time") or {}).get("start")) or created
            if ptype == "text" and (part.get("text") or "").strip() and not part.get("synthetic"):
                text, truncated = clip(part["text"], ASSISTANT_TEXT_MAX)
                item = {"id": item_id(index * 2), "ts": ts, "t": "text", "text": text}
                if truncated:
                    item["truncated"] = True
                items.append(item)
            elif ptype == "reasoning" and (part.get("text") or "").strip():
                thought, _ = clip(part["text"], ASSISTANT_TEXT_MAX)
                items.append({"id": item_id(index * 2), "ts": ts, "t": "thinking", "text": thought})
            elif ptype == "tool":
                state = part.get("state") if isinstance(part.get("state"), dict) else {}
                started = ((state.get("time") or {}).get("start")) or created
                tool, tool_input = opencode_tool(part.get("tool"), state.get("input"))
                items.append(dict({"id": item_id(index * 2), "ts": started, "t": "tool", "toolId": part.get("callID") or part.get("id"),
                                   "name": tool, "brief": tool_brief(tool, tool_input), "input": shrink(tool_input)},
                                  **stage_hint(tool, tool_input)))
                if state.get("status") in ("completed", "error"):
                    output = state.get("output") if state.get("status") == "completed" else state.get("error")
                    text = output if isinstance(output, str) else json.dumps(output, ensure_ascii=False)
                    full = len(text)
                    text, truncated = clip(text, TOOL_RESULT_MAX)
                    result = {"id": item_id(index * 2 + 1), "ts": ((state.get("time") or {}).get("end")) or started,
                              "t": "result", "toolId": part.get("callID") or part.get("id"), "text": text,
                              "isError": state.get("status") == "error"}
                    if truncated:
                        result["truncated"] = True
                        result["fullLength"] = full
                    items.append(result)
            elif ptype == "compaction":
                items.append({"id": item_id(index * 2), "ts": ts, "t": "event", "text": "上下文已压缩"})
        error = info.get("error") if isinstance(info.get("error"), dict) else None
        if error:
            name = error.get("name") or ""
            data = error.get("data") if isinstance(error.get("data"), dict) else {}
            if name == "MessageAbortedError":
                items.append({"id": item_id(9999), "ts": created, "t": "event", "text": "已中断"})
            else:
                items.append({"id": item_id(9999), "ts": created, "t": "event", "level": "error",
                              "text": "出错：%s" % (data.get("message") or name or "未知错误")})
    return items


OPENCODE_DECISIONS = {"1": "once", "enter": "once", "y": "once", "2": "always", "3": "reject", "esc": "reject", "n": "reject"}


class OpenCodeBridge:
    """一个 OpenCode 进程（终端界面、serve、网页版）里 Kiteline 插件开的桥"""

    def __init__(self, info, path):
        self.file = path
        self.pid = int(info["pid"])
        self.port = int(info["port"])
        self.token = str(info["token"])
        self.directory = info.get("directory") or ""
        self.started = int(info.get("started") or 0)
        self.lock = threading.RLock()
        self.sessions = {}       # 会话 id → Session
        self.status = {}         # 会话 id → {"type": idle / busy / retry}
        self.permissions = {}    # 请求 id → PermissionRequest
        self.questions = {}      # 请求 id → QuestionRequest
        self.touched = {}        # 会话 id → 最近有动静的时间：这个进程里用过的会话才算「开着」
        self.dirty = set()       # 消息有变、要重新取的会话
        self.latest = {}         # 会话 id → 最近几条消息里认出的：最后一句回复、正在跑的工具、用量
        self.sent = {}           # 会话 id → {对话项 id: 内容签名}：只推有变化的
        self.alive = True
        self.connected = False
        threading.Thread(target=self.listen, name="opencode-%d" % self.pid, daemon=True).start()

    def http(self, method, path, body=None, timeout=10):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=timeout)
        try:
            headers = {"Authorization": "Bearer " + self.token, "Accept": "application/json"}
            data = None
            if body is not None:
                data = json.dumps(body).encode("utf-8")
                headers["Content-Type"] = "application/json"
            conn.request(method, path, body=data, headers=headers)
            response = conn.getresponse()
            raw = response.read()
            if response.status >= 400:
                raise RuntimeError("OpenCode 返回 %d：%s" % (response.status, raw[:200].decode("utf-8", "replace")))
            return json.loads(raw) if raw.strip() else None
        finally:
            conn.close()

    def refresh(self):
        sessions = self.http("GET", "/session") or []
        status = self.http("GET", "/session/status") or {}
        permissions = self.http("GET", "/permission") or []
        questions = self.http("GET", "/question") or []
        now = _now_ms()
        with self.lock:
            self.sessions = {s["id"]: s for s in sessions if isinstance(s, dict) and s.get("id")}
            self.status = status if isinstance(status, dict) else {}
            self.permissions = {p["id"]: p for p in permissions if isinstance(p, dict) and p.get("id")}
            self.questions = {q["id"]: q for q in questions if isinstance(q, dict) and q.get("id")}
            for sid, session in self.sessions.items():
                updated = int(((session.get("time") or {}).get("updated")) or 0)
                if updated >= self.started - 1000 or (self.status.get(sid) or {}).get("type") in ("busy", "retry"):
                    self.touched[sid] = max(self.touched.get(sid, 0), updated or now)
            for request in list(self.permissions.values()) + list(self.questions.values()):
                self.touched[request.get("sessionID")] = now
            self.dirty.update(self.touched.keys())

    def listen(self):
        refused = 0
        while self.alive:
            try:
                self.refresh()
                conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=60)
                conn.request("GET", "/event", headers={"Authorization": "Bearer " + self.token, "Accept": "text/event-stream"})
                response = conn.getresponse()
                if response.status != 200:
                    raise RuntimeError("事件流返回 %d" % response.status)
                self.connected = True
                refused = 0
                buffer = []
                while self.alive:
                    line = response.readline()
                    if not line:
                        break
                    line = line.decode("utf-8", "replace").rstrip("\r\n")
                    if line.startswith("data:"):
                        buffer.append(line[5:].strip())
                        try:
                            event = json.loads("\n".join(buffer))
                        except ValueError:
                            continue
                        buffer = []
                        self.on_event(event)
                    elif not line:
                        buffer = []
                conn.close()
            except ConnectionRefusedError:
                # 端口没人听了：OpenCode 已经退出（被强退时登记文件还在、pid 也可能还没回收）
                refused += 1
                if refused >= 3:
                    self.alive = False
                    try:
                        os.remove(self.file)
                    except OSError:
                        pass
                    log("OpenCode（pid %d）已退出" % self.pid)
            except Exception as exc:
                if self.alive:
                    log("OpenCode（pid %d）连接中断：%r" % (self.pid, exc))
            self.connected = False
            if self.alive:
                time.sleep(2)

    def on_event(self, event):
        if not isinstance(event, dict):
            return
        kind = event.get("type") or ""
        props = event.get("properties") if isinstance(event.get("properties"), dict) else {}
        info = props.get("info") if isinstance(props.get("info"), dict) else {}
        sid = props.get("sessionID") or (info.get("id") if kind.startswith("session.") else info.get("sessionID"))
        part = props.get("part") if isinstance(props.get("part"), dict) else {}
        sid = sid or part.get("sessionID")
        now = _now_ms()
        with self.lock:
            if kind in ("session.created", "session.updated") and info.get("id"):
                self.sessions[info["id"]] = info
                self.touched[info["id"]] = now
            elif kind == "session.deleted" and info.get("id"):
                for table in (self.sessions, self.status, self.touched, self.latest, self.sent):
                    table.pop(info["id"], None)
            elif kind == "session.status" and sid:
                self.status[sid] = props.get("status") or {"type": "idle"}
                self.touched[sid] = now
            elif kind == "session.idle" and sid:
                self.status[sid] = {"type": "idle"}
            elif kind in ("permission.asked", "permission.updated") and props.get("id"):
                self.permissions[props["id"]] = props
                self.touched[sid] = now
            elif kind == "permission.replied":
                self.permissions.pop(props.get("requestID") or props.get("permissionID"), None)
            elif kind == "question.asked" and props.get("id"):
                self.questions[props["id"]] = props
                self.touched[sid] = now
            elif kind in ("question.replied", "question.rejected"):
                self.questions.pop(props.get("requestID"), None)
            elif kind.startswith("message.") and sid:
                self.dirty.add(sid)
                self.touched[sid] = now

    def live_sessions(self):
        with self.lock:
            return [dict(self.sessions[sid]) for sid in self.touched if sid in self.sessions
                    and not self.sessions[sid].get("parentID")]

    # --- 对话项 ---

    def messages(self, sid, limit):
        return self.http("GET", "/session/%s/message?limit=%d" % (urllib_quote(sid), limit), timeout=15) or []

    def pump(self):
        """有变化的会话取最近几条消息：推增量，顺带记下最后一句回复、正在跑的工具、用量"""
        with self.lock:
            # 子任务（子 agent）的会话不单独列出，也就不用推
            dirty = {sid for sid in self.dirty if not (self.sessions.get(sid) or {}).get("parentID")}
            self.dirty = set()
        out = []
        for sid in dirty:
            try:
                messages = self.messages(sid, 6)
            except Exception as exc:
                log("OpenCode 取消息失败：%r" % exc)
                with self.lock:
                    self.dirty.add(sid)
                continue
            items = opencode_items(messages)
            self.note(sid, messages, items)
            sent = self.sent.setdefault(sid, {})
            changed = []
            for item in items:
                mark = json.dumps(item, sort_keys=True, ensure_ascii=False)
                if sent.get(item["id"]) != mark:
                    sent[item["id"]] = mark
                    changed.append(item)
            if len(sent) > 600:
                for key in list(sent.keys())[:300]:
                    sent.pop(key, None)
            if changed:
                out.append((sid, changed))
        return out

    def note(self, sid, messages, items):
        latest = {"message": None, "messageId": None, "pendingTool": None, "pendingBrief": None, "pendingId": None,
                  "usage": None, "error": None}
        calls = {}
        for item in items:
            if item["t"] == "text":
                latest["message"], latest["messageId"] = item["text"][:MESSAGE_MAX_CHARS], item["id"]
            elif item["t"] == "tool":
                calls[item.get("toolId")] = item
            elif item["t"] == "result":
                calls.pop(item.get("toolId"), None)
            elif item["t"] == "event" and item.get("level") == "error":
                latest["error"] = item["text"]
            elif item["t"] == "user":
                latest["error"] = None
        if calls:
            last = list(calls.values())[-1]
            latest["pendingTool"], latest["pendingBrief"], latest["pendingId"] = last["name"], last.get("brief"), last.get("toolId")
        for message in reversed(messages):
            info = message.get("info") or {}
            tokens = info.get("tokens") if isinstance(info.get("tokens"), dict) else None
            if info.get("role") == "assistant" and tokens:
                cache = tokens.get("cache") if isinstance(tokens.get("cache"), dict) else {}
                context = int(tokens.get("input") or 0) + int(tokens.get("output") or 0) + int(cache.get("read") or 0) + int(cache.get("write") or 0)
                # 不知道模型的上下文窗口：给 0，界面就不显示占比（给已用量会显示成 100%）
                latest["usage"] = {"context": context, "window": 0, "input": int(tokens.get("input") or 0),
                                   "output": int(tokens.get("output") or 0), "cacheRead": int(cache.get("read") or 0),
                                   "cacheWrite": int(cache.get("write") or 0), "requests": 0,
                                   "model": info.get("modelID"), "cost": info.get("cost"), "costAt": None}
                break
        with self.lock:
            self.latest[sid] = latest

    def history(self, sid, before, limit):
        messages = self.messages(sid, 400)
        if before is not None:
            messages = [m for m in messages if int((((m.get("info") or {}).get("time") or {}).get("created")) or 0) < int(before)]
        count = max(1, limit // 4)
        has_more = len(messages) > count
        return opencode_items(messages[-count:]), has_more

    # --- 快照 ---

    def snapshots(self):
        with self.lock:
            sessions = [dict(s) for sid, s in self.sessions.items() if sid in self.touched]
            status = dict(self.status)
            permissions = list(self.permissions.values())
            questions = list(self.questions.values())
            latest = {sid: dict(v) for sid, v in self.latest.items()}
        children = {}
        for session in sessions:
            if session.get("parentID"):
                children[session["parentID"]] = children.get(session["parentID"], 0) + 1
        out = []
        for session in sessions:
            if session.get("parentID"):
                continue
            sid = session["id"]
            note = latest.get(sid) or {}
            state = (status.get(sid) or {}).get("type") or "idle"
            perms = [p for p in permissions if p.get("sessionID") == sid]
            asks = [q for q in questions if q.get("sessionID") == sid]
            waiting_for, pending_tool, pending_id = None, None, None
            if perms:
                perm = perms[0]
                pending_tool = OPENCODE_PERMISSIONS.get(perm.get("permission")) or perm.get("permission")
                patterns = ", ".join(perm.get("patterns") or [])
                waiting_for = "请求权限确认：%s" % (patterns[:80] or perm.get("permission") or "")
                pending_id = perm.get("id")
            elif asks:
                first = (asks[0].get("questions") or [{}])[0]
                waiting_for, pending_tool, pending_id = first.get("question") or "等待你回答", "AskUserQuestion", asks[0].get("id")
            if waiting_for:
                activity, reason = "waiting", waiting_for
            elif state in ("busy", "retry"):
                activity = "busy"
                reason = note.get("pendingBrief") or ((status.get(sid) or {}).get("message") if state == "retry" else None) or "正在工作"
            else:
                activity, reason = "idle", note.get("message")
            times = session.get("time") or {}
            cwd = session.get("directory") or self.directory
            title = session.get("title") or None
            if title and re.match(r"^New session - \d{4}-", title):
                title = None   # 还没生成标题的默认名
            error = note.get("error")
            out.append({
                "pid": self.pid,
                "sessionId": sid,
                "name": title or session.get("slug") or sid[-8:],
                "title": title,
                "cwd": cwd,
                "cwdShort": display_cwd(cwd),
                "status": state,
                "waitingFor": waiting_for,
                "needs": None,
                "detail": None,
                "activity": activity,
                "reason": reason,
                "activityText": note.get("pendingBrief") if activity == "busy" else None,
                "message": note.get("message"),
                "messageUuid": note.get("messageId"),
                "error": {"kind": "api", "text": "OpenCode %s" % error[:160]} if error and activity == "idle" else None,
                "effort": None,
                "subagents": children.get(sid, 0),
                "pendingTool": pending_tool if activity == "waiting" else None,
                "pendingId": pending_id,
                "startedAt": times.get("created"),
                "statusUpdatedAt": None,
                "updatedAt": times.get("updated"),
                "version": session.get("version"),
                "entrypoint": "opencode",
                "sessionKind": None,
                "tmuxPane": None,
                "usage": note.get("usage"),
                "transcriptPath": None,
                "transcriptUpdatedAt": times.get("updated"),
                "agent": "opencode",
            })
        return out

    # --- 手机上的操作 ---

    def send(self, sid, text, images):
        parts = [{"type": "text", "text": text}] if text else []
        for path in images:
            parts.append({"type": "file", "mime": mimetypes.guess_type(path)[0] or "image/jpeg",
                          "filename": os.path.basename(path), "url": "file://" + path})
        if not parts:
            raise RuntimeError("内容为空")
        self.http("POST", "/session/%s/prompt_async" % urllib_quote(sid), {"parts": parts})
        with self.lock:
            self.touched[sid] = _now_ms()
        return "已发送"

    def key(self, sid, key):
        with self.lock:
            perm = next((p for p in self.permissions.values() if p.get("sessionID") == sid), None)
            asks = next((q for q in self.questions.values() if q.get("sessionID") == sid), None)
            busy = (self.status.get(sid) or {}).get("type") in ("busy", "retry")
        if perm is not None:
            reply = OPENCODE_DECISIONS.get(key)
            if reply is None:
                raise RuntimeError("OpenCode 会话不支持这个操作")
            self.http("POST", "/permission/%s/reply" % urllib_quote(perm["id"]), {"reply": reply})
            with self.lock:
                self.permissions.pop(perm["id"], None)
            return "已选择"
        if asks is not None and key == "esc":
            self.http("POST", "/question/%s/reject" % urllib_quote(asks["id"]), {})
            return "已跳过"
        if key == "esc" and busy:
            self.http("POST", "/session/%s/abort" % urllib_quote(sid), {})
            return "已中断"
        raise RuntimeError("这个 OpenCode 会话现在没有待确认的操作")

    def close(self, sid):
        # OpenCode 没有「关掉会话、留着记录」的接口（DELETE 会永久删记录），/tui 的命令、提交输入框接口也不执行 /exit
        # （还会把界面的输入框弄乱，10-25 实测 1.19.4）：结束这个 OpenCode 进程。它收到 SIGTERM 照常收尾——退出备用屏幕、
        # 关鼠标，和在界面里输入 /exit 一样（同上实测）；记录留在 OpenCode 里，之后能接着用。
        # 同一个窗口里还开着别的会话就不关，免得连带关掉
        with self.lock:
            others = [s for s in self.touched if s != sid and s in self.sessions and not self.sessions[s].get("parentID")]
        if others:
            raise RuntimeError("这个 OpenCode 窗口中还开着其他 %d 个会话，关闭会退出整个窗口：请在 OpenCode 中关闭" % len(others))
        os.kill(self.pid, signal.SIGTERM)
        for _ in range(40):
            if not pid_alive(self.pid):
                self.alive = False
                return "已关闭会话"
            time.sleep(0.25)
        raise RuntimeError("OpenCode 没有退出，请在 OpenCode 中关闭（输入 /exit）")

    def answer(self, sid, answers):
        with self.lock:
            request = next((q for q in self.questions.values() if q.get("sessionID") == sid), None)
        if request is None:
            raise RuntimeError("这个 OpenCode 会话现在没有待回答的提问")
        replies = [_answer_for(answers, q.get("question"), index) for index, q in enumerate(request.get("questions") or [])]
        self.http("POST", "/question/%s/reply" % urllib_quote(request["id"]), {"answers": replies})
        with self.lock:
            self.questions.pop(request["id"], None)
        return "已回答"


def urllib_quote(text):
    return url_quote(str(text), safe="")


class OpenCodeLink:
    """找出本机所有装了 Kiteline 插件的 OpenCode 进程，各开一座桥"""

    def __init__(self):
        self.bridges = {}       # 登记文件 → OpenCodeBridge
        self.last_scan = 0.0

    def scan(self):
        now = time.time()
        if now - self.last_scan < 2:
            return
        self.last_scan = now
        try:
            names = [n for n in os.listdir(OPENCODE_BRIDGES) if n.endswith(".json")]
        except OSError:
            names = []
        seen = set()
        for name in names:
            path = os.path.join(OPENCODE_BRIDGES, name)
            if path in self.bridges:
                seen.add(path)
                continue
            try:
                info = json.loads(read_text(path) or "")
                pid = int(info["pid"])
            except (ValueError, KeyError, TypeError):
                continue
            if not pid_alive(pid):
                try:
                    os.remove(path)   # OpenCode 被强退时留下的
                except OSError:
                    pass
                continue
            try:
                self.bridges[path] = OpenCodeBridge(info, path)
                seen.add(path)
            except (KeyError, ValueError, TypeError) as exc:
                log("OpenCode 登记文件不对（%s）：%r" % (name, exc))
        for path in list(self.bridges.keys()):
            bridge = self.bridges[path]
            if path not in seen or not bridge.alive or not pid_alive(bridge.pid):
                bridge.alive = False
                del self.bridges[path]

    def snapshots(self):
        self.scan()
        out = []
        for bridge in list(self.bridges.values()):
            out.extend(bridge.snapshots())
        return out

    def owner(self, sid):
        for bridge in list(self.bridges.values()):
            with bridge.lock:
                if sid in bridge.sessions:
                    return bridge
        raise RuntimeError("这个 OpenCode 会话已经关了")

    def pump(self):
        out = []
        for bridge in list(self.bridges.values()):
            if bridge.connected:
                out.extend(bridge.pump())
        return out


# --- OpenCode 插件：Kiteline 自动装，删掉文件即停用 ---

OPENCODE_PLUGIN_VERSION = "1"
OPENCODE_PLUGIN = r"""// kiteline-bridge v%(version)s
// Kiteline 桥接插件（Kiteline 自动安装；在 Kiteline 设置里关掉「为 OpenCode 安装 Kiteline 插件」即删除并不再装回）。
// 让手机上的 Kiteline 看到、操作这台电脑上的 OpenCode 会话：只监听本机 127.0.0.1 的随机端口，
// 每次启动生成新的访问令牌，登记在 ~/.ccpulse/opencode/ 下（只有你能读），OpenCode 退出时删除。
import { mkdirSync, writeFileSync, rmSync } from "node:fs"
import { join } from "node:path"
import { homedir } from "node:os"
import { randomBytes, createHash } from "node:crypto"

export const KitelineBridge = async ({ client, directory }) => {
  // 出任何问题都只是不开桥，绝不能影响 OpenCode 本身
  try {
    const config = client?._client?.getConfig?.()
    if (typeof Bun === "undefined" || !config) return {}
    const forward = config.fetch || fetch
    const base = String(config.baseUrl || "http://localhost:4096").replace(/\/+$/, "")
    const defaults = new Headers(config.headers || {})
    const token = randomBytes(24).toString("hex")
    const server = Bun.serve({
      hostname: "127.0.0.1",
      port: 0,
      idleTimeout: 0,
      async fetch(request) {
        if (request.headers.get("authorization") !== "Bearer " + token) return new Response("forbidden", { status: 403 })
        const url = new URL(request.url)
        const headers = new Headers(request.headers)
        headers.delete("authorization")
        headers.delete("host")
        defaults.forEach((value, key) => { if (!headers.has(key)) headers.set(key, value) })
        const body = request.method === "GET" || request.method === "HEAD" ? undefined : await request.arrayBuffer()
        return forward(new Request(base + url.pathname + url.search, { method: request.method, headers, body }))
      },
    })
    const folder = join(process.env.CCPULSE_DATA_DIR || join(homedir(), ".ccpulse"), "opencode")
    mkdirSync(folder, { recursive: true, mode: 0o700 })
    const file = join(folder, process.pid + "-" + createHash("sha1").update(String(directory)).digest("hex").slice(0, 10) + ".json")
    writeFileSync(file, JSON.stringify({ pid: process.pid, port: server.port, token, directory, started: Date.now(), version: %(version)s }), { mode: 0o600 })
    // 正常退出时删掉登记；被强退留下的，Kiteline 发现进程不在了会自己清掉
    process.once("exit", () => { try { rmSync(file) } catch {} })
  } catch {}
  return {}
}
""" % {"version": OPENCODE_PLUGIN_VERSION}


def opencode_config_dir():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config")
    return os.path.join(base, "opencode")


def remove_opencode_plugin():
    """设置里关掉了：删掉之前装的（只删带 Kiteline 标记的，别人的同名文件不碰）"""
    target = os.path.join(opencode_config_dir(), "plugin", "kiteline.js")
    if (read_text(target) or "").startswith("// kiteline-bridge"):
        os.remove(target)
        log("已删除 OpenCode 插件：%s" % target)


def opencode_installed():
    """这台电脑真的装了 / 用过 OpenCode：找得到程序（Kiteline 拉起的 watcher 不一定有 shell 的 PATH，常见位置挨个看），
    或者有用户自己的配置目录，或者数据目录里有用过才有的数据库。光有个空的数据目录不算（卸载、别的程序留下的）"""
    if shutil.which("opencode"):
        return True
    for folder in (os.path.join(HOME, ".opencode", "bin"), os.path.join(HOME, ".bun", "bin"), os.path.join(HOME, ".local", "bin"),
                   "/opt/homebrew/bin", "/usr/local/bin", os.path.join(HOME, ".npm-global", "bin")):
        if os.path.isfile(os.path.join(folder, "opencode.exe" if IS_WINDOWS else "opencode")):
            return True
    config = opencode_config_dir()
    if os.path.isdir(config) and any(name != "plugin" for name in os.listdir(config)):
        return True
    data = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.join(HOME, ".local", "share"), "opencode")
    return os.path.isfile(os.path.join(data, "opencode.db")) or os.path.isdir(os.path.join(data, "storage"))


def install_opencode_plugin():
    """这台电脑装了 OpenCode 才装插件；内容一样就不动。返回装好的路径（没装 OpenCode 返回 None）"""
    if not opencode_installed():
        return None
    config = opencode_config_dir()
    target = os.path.join(config, "plugin", "kiteline.js")
    if read_text(target) == OPENCODE_PLUGIN:
        return target
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target + ".tmp", "w", encoding="utf-8") as handle:
        handle.write(OPENCODE_PLUGIN)
    os.replace(target + ".tmp", target)
    log("已安装 OpenCode 插件：%s（重启 OpenCode 后生效）" % target)
    return target


# --- DeepSeek Harness（dsh） ---
#
# 桌面版（Electron）在本机 127.0.0.1 的随机端口起一个网页服务（和 `dsh --profile web` 是同一套），桌面窗口也是连它。
# 网页服务认签名 cookie：签名密钥是 DSH 自己存在 $DSH_HOME/.credentials.yaml 里的 client-connection/browser-session，
# 同一个用户的 Kiteline 读得到，照它的格式签一张只认「127.0.0.1:端口」的 cookie，身份就和桌面窗口一样（owner）。
# 接口：一元调用是 POST /api/<方法>，{type: client-request, rpcId, method, payload: {args}}；
#      流都在一条 WebSocket（/api/remote.mux）上多路复用：{type: open / item / end / cancel, streamId, …}。
# 用到的流：$events（会话增删、忙闲、审批和提问请求）、session/control（标题、用量这些投影）、
#          session/follow（每个开着的会话一条，对话事件）。审批、提问会同时发给所有能作答的客户端，
#          谁先答算谁的，其余的收到撤销——手机和桌面窗口可以一起等着答，互不影响。

DSH_HOME = os.environ.get("DSH_HOME") or os.path.join(HOME, ".dsh")
# 桌面版的后台进程（…/@deepseek-ai/dsh-desktop-host/lib/index.js）、桌面版带的命令行（…/cli.js）、npm 装的 dsh
# （直接跑是 …/dsh/lib/bin.js，经 PATH 里的命令跑是「node …/bin/dsh」）；只是候选，最后靠探测认
DSH_PROCESS = re.compile(r"@deepseek-ai[\\/](?:dsh-desktop-host|dsh)[\\/]lib[\\/]|(?:^|\s)(?:\S*[\\/])?dsh(?:\.js)?(?=\s|$)")
DSH_FOLLOW_WINDOW = {"maxMessages": 40, "turnWindow": {"minMessages": 8, "minTurns": 1}}
# DeepSeek 账号余额（account/getBalance 要经 DSH 问 DeepSeek 平台）：读到了 10 分钟内不再问，没读到 3 分钟后再试
DSH_BALANCE_TTL, DSH_BALANCE_RETRY = 600, 180
# DSH 的工具名 → (Claude 的工具名, 字段改名)
DSH_TOOLS = {
    "bash": ("Bash", {"timeoutMs": "timeout"}),
    "pwsh": ("Bash", {"timeoutMs": "timeout"}),
    "read": ("Read", {}),
    "read_image": ("Read", {}),
    "write": ("Write", {}),
    "edit": ("Edit", {}),
    "glob": ("Glob", {}),
    "grep": ("Grep", {}),
    "web_fetch": ("WebFetch", {}),
    "web_search": ("WebSearch", {}),
    "todo_write": ("TodoWrite", {}),
    "subagent": ("Task", {}),
    "subagent_fork": ("Task", {}),
    "skill": ("Skill", {}),
}
# 审批：手机上的按键 → DSH 的决定（DSH 只有「允许这一次」，没有「本会话都允许」）
DSH_DECISIONS = {"1": "allowed-once", "2": "allowed-once", "enter": "allowed-once", "y": "allowed-once",
                 "3": "rejected", "n": "rejected", "esc": "rejected"}


def _b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _b64url_decode(text):
    try:
        return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))
    except (ValueError, TypeError):
        return None


def dsh_secret(home=None):
    """DSH 的浏览器会话签名密钥（.credentials.yaml 里 client-connection/browser-session 这一条，32 字节）。
    只取这一条，文件里别的凭据（账号登录等）不碰。没装 DSH、格式不认得都返回 None"""
    text = read_text(os.path.join(home or DSH_HOME, ".credentials.yaml"))
    indent = None
    for line in (text or "").splitlines():
        if indent is None:
            match = re.match(r"^(\s*)[\"']?client-connection/browser-session[\"']?\s*:\s*$", line)
            if match:
                indent = len(match.group(1))
            continue
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            break   # 这一条到头了
        match = re.match(r"^\s*secret\s*:\s*[\"']?([A-Za-z0-9_-]+)[\"']?\s*$", line)
        if match:
            secret = _b64url_decode(match.group(1))
            return secret if secret and len(secret) == 32 else None
    return None


def dsh_cookie(secret, authority, now=None):
    """照 DSH 的格式签一张浏览器 cookie（v1）：只认这个 authority（127.0.0.1:端口），12 小时有效（DSH 最短允许 1 天）。
    签发时间往前放 5 分钟：DSH 拒收签发时间在它「未来」的 cookie，两边的钟差一点就会被拒"""
    now = now or _now_ms()
    body = _b64url(json.dumps({"version": 1, "authority": authority, "issuedAt": now - 300000, "expiresAt": now + 43200000},
                              separators=(",", ":")).encode("utf-8"))
    signature = _b64url(hmac.new(secret, body.encode("ascii"), hashlib.sha256).digest())
    return "dsh-auth-%s=v1.%s.%s" % (_b64url(hashlib.sha256(authority.encode("utf-8")).digest()), body, signature)


def _linux_listeners(pids):
    """这些进程在 127.0.0.1 / ::1 上监听的 TCP 端口：/proc/net/tcp* 里 LISTEN 的套接字，按 inode 对回进程"""
    owners = {}
    for pid in pids:
        try:
            for fd in os.listdir("/proc/%d/fd" % pid):
                link = os.readlink("/proc/%d/fd/%s" % (pid, fd))
                if link.startswith("socket:["):
                    owners[link[8:-1]] = pid
        except OSError:
            continue
    out = []
    for table in ("/proc/net/tcp", "/proc/net/tcp6"):
        for line in (read_text(table) or "").splitlines()[1:]:
            fields = line.split()
            if len(fields) < 10 or fields[3] != "0A" or fields[9] not in owners:
                continue
            address, _, port = fields[1].partition(":")
            if address in ("0100007F", "00000000000000000000000001000000", "0000000000000000FFFF00000100007F"):
                out.append((owners[fields[9]], int(port, 16)))
    return out


if IS_WINDOWS:
    def _win_process_names():
        snapshot = _k32.CreateToolhelp32Snapshot(0x2, 0)   # TH32CS_SNAPPROCESS
        if not snapshot or snapshot == wintypes.HANDLE(-1).value:
            return {}
        names = {}
        try:
            entry = _PROCESSENTRY32W()
            entry.dwSize = ctypes.sizeof(_PROCESSENTRY32W)
            ok = _k32.Process32FirstW(snapshot, ctypes.byref(entry))
            while ok:
                names[entry.th32ProcessID] = entry.szExeFile.lower()
                ok = _k32.Process32NextW(snapshot, ctypes.byref(entry))
        finally:
            _k32.CloseHandle(snapshot)
        return names

    def _win_listeners(pids):
        """GetExtendedTcpTable（TCP_TABLE_OWNER_PID_LISTENER）：127.0.0.1 上监听的端口和进程"""
        iphlp = ctypes.WinDLL("iphlpapi")
        size = wintypes.DWORD(0)
        iphlp.GetExtendedTcpTable(None, ctypes.byref(size), False, 2, 3, 0)
        size.value += 4096   # 两次调用之间可能多出连接
        buffer = ctypes.create_string_buffer(size.value)
        if iphlp.GetExtendedTcpTable(buffer, ctypes.byref(size), False, 2, 3, 0) != 0:
            return []
        out = []
        for index in range(struct.unpack_from("<I", buffer.raw, 0)[0]):
            _, address, port, _, _, pid = struct.unpack_from("<6I", buffer.raw, 4 + index * 24)
            if pid in pids and address == 0x0100007F:
                out.append((pid, socket.ntohs(port & 0xFFFF)))
        return out


def dsh_listeners():
    """本机 DSH 进程在 127.0.0.1 上监听的 (pid, 端口)。Windows 拿不到命令行，桌面版和 node 的都算候选，再靠探测认"""
    if IS_WINDOWS:
        names = _win_process_names()
        return _win_listeners({pid for pid, name in names.items() if name in ("deepseek harness.exe", "node.exe")})
    if os.path.isdir("/proc/self/fd"):
        pids = set()
        for name in os.listdir("/proc"):
            if name.isdigit():
                try:
                    with open("/proc/%s/cmdline" % name, "rb") as handle:
                        cmdline = handle.read().replace(b"\0", b" ").decode("utf-8", "replace")
                except OSError:
                    continue
                if DSH_PROCESS.search(cmdline):
                    pids.add(int(name))
        return _linux_listeners(pids) if pids else []
    out = subprocess.run(["ps", "-axww", "-o", "pid=,command="], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5)
    pids = [line.split(None, 1)[0] for line in out.stdout.decode("utf-8", "replace").splitlines()
            if DSH_PROCESS.search(line)]
    if not pids:
        return []
    out = subprocess.run(["lsof", "-nP", "-a", "-p", ",".join(pids), "-iTCP", "-sTCP:LISTEN", "-Fpn"],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10)
    found, pid = [], None
    for line in out.stdout.decode("utf-8", "replace").splitlines():
        if line.startswith("p"):
            pid = int(line[1:])
        elif line.startswith("n") and pid:
            address, _, port = line[1:].rpartition(":")
            if address in ("127.0.0.1", "[::1]", "localhost") and port.isdigit():
                found.append((pid, int(port)))
    return found


def dsh_probe(port):
    """是不是 DSH 的网页服务：不带 cookie 访问首页，DSH 回 401 和一句固定的提示"""
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    try:
        conn.request("GET", "/", headers={"Accept": "text/plain"})
        response = conn.getresponse()
        return response.status == 401 and b"dsh web authentication" in response.read(400)
    except (OSError, http.client.HTTPException):
        return False
    finally:
        conn.close()


def _dsh_json(text):
    try:
        return json.loads(text) if isinstance(text, str) and text.strip() else {}
    except ValueError:
        return {"raw": text}


def dsh_tool(name, args):
    args = args if isinstance(args, dict) else {}
    if name == "ask_user_question":
        questions = []
        for item in args.get("questions") or []:
            if isinstance(item, dict):
                questions.append({"question": item.get("question") or "", "header": item.get("header") or "",
                                  "options": [{"label": o.get("label") or "", "description": o.get("description") or ""}
                                              for o in (item.get("options") or []) if isinstance(o, dict)],
                                  "multiSelect": bool(item.get("multi_select"))})
        return "AskUserQuestion", {"questions": questions}
    mapped = DSH_TOOLS.get(name)
    if not mapped:
        return name or "tool", args
    tool, renames = mapped
    out = {renames.get(key, key): value for key, value in args.items()}
    if tool == "TodoWrite":
        out["todos"] = [{"content": t.get("content") or "", "status": t.get("status") or "pending",
                         "activeForm": t.get("content") or ""} for t in (args.get("todos") or []) if isinstance(t, dict)]
    elif tool == "WebSearch" and isinstance(args.get("queries"), list):
        out["query"] = " / ".join(str(q) for q in args["queries"])
    return tool, out


# DSH 读图工具结果里图片前面那段说明（整段都是这个格式才去掉）
DSH_IMAGE_NOTE = re.compile(r"\s*<path>[^<]*</path>\s*<type>image</type>(?:\s*<content>[^<]*</content>)?\s*$")


def _dsh_text(content):
    if isinstance(content, str):
        return content
    return "\n".join(part.get("text") or "" for part in (content or []) if isinstance(part, dict) and part.get("type") == "text")


def dsh_items(events):
    """DSH 的会话事件 → 对话项。id =「事件序号.块序号」：和 Claude 的「行偏移.序号」一样能排序、往前翻页"""
    items = []
    for event in events or []:
        if not isinstance(event, dict) or not isinstance(event.get("seq"), int):
            continue
        kind, seq, ts = event.get("type"), event["seq"], event.get("time")
        data = event.get("data") if isinstance(event.get("data"), dict) else {}

        def item_id(index):
            return "%d.%d" % (seq, index)

        if kind == "user/message":
            # 只要用户自己说的话：运行环境、时间这些是 DSH 塞给模型的；回答提问的回复在工具结果里已经有了
            if (data.get("source") or {}).get("kind") != "user":
                continue
            texts, images = [], []
            for index, part in enumerate(data.get("content") or []):
                if not isinstance(part, dict):
                    continue
                if part.get("type") == "text":
                    texts.append(part.get("text") or "")
                elif part.get("type") == "image":
                    images.append({"ref": "d%d.%d" % (seq, index), "mime": (part.get("attachment") or {}).get("mediaType") or "image/png"})
            text, attached = split_attachments(strip_reminders("\n\n".join(texts)))
            if text or images or attached:
                text, truncated = clip(text, USER_TEXT_MAX)
                item = {"id": item_id(0), "ts": ts, "t": "user", "text": text}
                if images or attached:
                    item["images"] = images + attached
                if truncated:
                    item["truncated"] = True
                items.append(item)
        elif kind == "assistant/message":
            message = data.get("message") if isinstance(data.get("message"), dict) else {}
            for index, block in enumerate(message.get("content") or []):
                if not isinstance(block, dict):
                    continue
                btype = block.get("type")
                if btype == "text" and (block.get("text") or "").strip():
                    text, truncated = clip(block["text"], ASSISTANT_TEXT_MAX)
                    item = {"id": item_id(index), "ts": ts, "t": "text", "text": text}
                    if truncated:
                        item["truncated"] = True
                    items.append(item)
                elif btype in ("reasoning", "thinking") and (block.get("text") or block.get("thinking") or "").strip():
                    thought, _ = clip(block.get("text") or block.get("thinking"), ASSISTANT_TEXT_MAX)
                    items.append({"id": item_id(index), "ts": ts, "t": "thinking", "text": thought})
                elif btype == "tool-call":
                    tool, tool_input = dsh_tool(block.get("name"), _dsh_json(block.get("arguments")))
                    items.append(dict({"id": item_id(index), "ts": ts, "t": "tool", "toolId": block.get("id"),
                                       "name": tool, "brief": tool_brief(tool, tool_input), "input": shrink(tool_input)},
                                      **stage_hint(tool, tool_input)))
        elif kind == "tool/result":
            message = data.get("message") if isinstance(data.get("message"), dict) else {}
            text = _dsh_text(message.get("content"))
            if not text and data.get("error"):
                text = str((data.get("error") or {}).get("message") or data.get("error"))
            # read_image 的结果是「<path>…</path><type>image</type><content>…</content>」一段说明 + 图片附件：
            # 只给图（同 Claude 的 Read 读图），说明文字像代码，不显示。图的 ref 带 r，取图时到结果里找
            images = [{"ref": "d%d.r%d" % (seq, index), "mime": (part.get("attachment") or {}).get("mediaType") or "image/png"}
                      for index, part in enumerate(message.get("content") or [])
                      if isinstance(part, dict) and part.get("type") == "image"]
            if images and DSH_IMAGE_NOTE.match(text):
                text = ""
            full = len(text)
            text, truncated = clip(text, TOOL_RESULT_MAX)
            item = {"id": item_id(0), "ts": ts, "t": "result", "toolId": message.get("toolCallId"), "text": text,
                    "isError": bool(message.get("isError") or data.get("error"))}
            if images:
                item["images"] = images
            if truncated:
                item["truncated"] = True
                item["fullLength"] = full
            items.append(item)
        elif kind == "turn/end":
            reason = data.get("reason") if isinstance(data.get("reason"), dict) else {}
            if reason.get("kind") in ("cancelled", "canceled", "interrupted", "aborted"):
                items.append({"id": item_id(0), "ts": ts, "t": "event", "text": "已中断"})
            elif reason.get("kind") in ("error", "failed"):
                error = reason.get("error") if isinstance(reason.get("error"), dict) else {}
                detail = reason.get("message") or error.get("message")
                items.append({"id": item_id(0), "ts": ts, "t": "event", "level": "error", "text": "出错：%s" % (detail or "未知错误")})
        elif kind and kind.startswith("compaction/") and kind.endswith(("/end", "/completed", "/applied")):
            items.append({"id": item_id(0), "ts": ts, "t": "event", "text": "上下文已压缩"})
    return items


class DshAuthError(RuntimeError):
    pass


class DshHost:
    """一个 DSH 网页服务（桌面版的后台进程，或命令行起的 `dsh --profile web`）"""

    def __init__(self, pid, port, secret):
        self.pid, self.port, self.secret = pid, port, secret
        self.authority = "127.0.0.1:%d" % port
        self.lock = threading.RLock()
        self.rows = {}           # 会话 id → session/list 的一行（cwd、running、agentAvailable、blank……）
        self.projections = {}    # 会话 id → {投影名: 值}（title、tokenUsage、contextPressure……）
        self.running = {}        # 会话 id → 正在跑
        self.touched = {}        # 会话 id → 最近有动静的时间（Kiteline 连上之后）
        self.requests = {}       # 事件 id → 等人答的审批 / 提问（$events 的 waterfall）
        self.follows = {}        # 会话 id → session/follow 的流 id
        self.streams = {}        # 流 id → 处理函数
        self.latest = {}         # 会话 id → 最后一句回复、出错
        self.calls = {}          # 会话 id → {工具调用 id: 对话项}：还没出结果的
        self.cursors = {}        # 会话 id → 已知最新的事件序号（翻历史要带）
        self.sent = {}           # 会话 id → {对话项 id: 内容签名}：只推有变化的
        self.outbox = []         # 待推给 Kiteline 的 (会话 id, 对话项)
        self.archived = set()    # 归档了的会话（workspace/follow 推的整份；关闭会话也是归档）：不算开着
        self.workspace_ready = False   # workspace/follow 的基线到了（没到之前不知道哪些归档了）
        self.workspace_wait = 0.0
        self.client_id = None    # 这一代 $events 的客户端 id，答审批要带
        self.ws = None
        self.alive = True
        self.rejected = False    # cookie 不被认（这个 DSH 用的不是 $DSH_HOME 那份数据）
        self.connected = False
        self.balance_read = (0.0, None)   # (上次问余额的时间, 读数)
        self.balance_error = None
        threading.Thread(target=self.run, name="dsh-%d" % port, daemon=True).start()

    # --- 连接 ---

    def call(self, method, args=None, timeout=15):
        body = json.dumps({"type": "client-request", "rpcId": str(uuid.uuid4()), "method": method,
                           "payload": {"args": args if args is not None else {}}}).encode("utf-8")
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=timeout)
        try:
            conn.request("POST", "/api/" + method, body=body,
                         headers={"Content-Type": "application/json", "Cookie": dsh_cookie(self.secret, self.authority)})
            response = conn.getresponse()
            raw = response.read()
        finally:
            conn.close()
        if response.status == 401:
            raise DshAuthError("DeepSeek Harness 不认 Kiteline 的登录凭据")
        if response.status >= 400:
            raise RuntimeError("DeepSeek Harness 返回 %d：%s" % (response.status, raw[:200].decode("utf-8", "replace")))
        if (response.getheader("content-type") or "").startswith("multipart/"):
            raise RuntimeError("DeepSeek Harness 返回了二进制内容")
        result = (json.loads(raw) or {}).get("result") or {}
        if not result.get("ok"):
            error = result.get("error") or {}
            raise RuntimeError("DeepSeek Harness：%s" % (error.get("message") or error.get("code") or "调用失败"))
        return result.get("value")

    def balance(self):
        """DeepSeek 账号的余额：{"at", "balances": [{currency, amount, kind}]}——DSH 设置页上那份（account/getBalance），
        DSH 自己拿登录态去问 DeepSeek 平台，我们不经手凭证。用 API Key、没登录 DeepSeek 账号的返回 None"""
        asked, reading = self.balance_read
        if time.time() - asked < (DSH_BALANCE_TTL if reading else DSH_BALANCE_RETRY):
            return reading
        local = time.localtime()
        # client：发起请求的界面（DSH 据此给平台带版本、语言、时区头）；我们报自己的版本
        client = {"version": "kiteline-" + WATCHER_VERSION, "locale": "zh-CN", "timezoneOffsetSeconds": int(local.tm_gmtoff or 0)}
        failed = False
        try:
            value = self.call("account/getBalance", {"client": client}, timeout=10)
        except Exception as exc:
            # 老版本 DSH 没有这个方法、平台一时连不上：同一个错只记一次
            if str(exc) != self.balance_error:
                self.balance_error = str(exc)
                log("DeepSeek Harness 读余额出错：%s" % exc)
            value, failed = None, True
        failed = failed or (isinstance(value, dict) and value.get("status") == "failed")
        fresh = None
        if isinstance(value, dict) and value.get("status") == "ready":
            balances = []
            for kind, rows in (("main", value.get("value")), ("bonus", value.get("bonusWallets"))):
                for row in rows if isinstance(rows, list) else []:
                    if isinstance(row, dict) and row.get("currency") and row.get("balance") is not None:
                        # 赠送余额是 0 的不列（大多数人没有）
                        try:
                            empty = kind == "bonus" and float(row["balance"]) == 0
                        except (TypeError, ValueError):
                            empty = False
                        if empty:
                            continue
                        balances.append({"currency": str(row["currency"]), "amount": str(row["balance"]), "kind": kind})
            if balances:
                fresh = {"at": _now_ms(), "balances": balances}
        # 这次没读到（平台一时出错）：上次的读数一天内照样给，卡片上写着是多久前的；退出了 DeepSeek 账号（回 null）的就不给了
        if fresh is None and failed and reading and _now_ms() - reading["at"] < 86400000:
            fresh = reading
        self.balance_read = (time.time(), fresh)
        return fresh

    def open(self, endpoint, args, handler):
        stream = str(uuid.uuid4())
        with self.lock:
            self.streams[stream] = handler   # 先登记再发：回来的第一帧可能比 send 返回还快
        self.ws.send(json.dumps({"type": "open", "streamId": stream, "endpoint": endpoint, "payload": {"args": args}}))
        return stream

    def close_stream(self, stream):
        with self.lock:
            self.streams.pop(stream, None)
        try:
            self.ws.send(json.dumps({"type": "cancel", "streamId": stream}))
        except Exception:
            pass

    def run(self):
        refused = 0
        while self.alive:
            try:
                self.serve()
            except DshAuthError as exc:
                self.rejected = True
                self.alive = False
                log("DeepSeek Harness（端口 %d）：%s，跳过" % (self.port, exc))
            except ConnectionRefusedError:
                refused += 1
                if refused >= 3:
                    self.alive = False
            except Exception as exc:
                if self.alive:
                    log("DeepSeek Harness（端口 %d）连接中断：%r" % (self.port, exc))
            self.connected = False
            ws, self.ws = self.ws, None
            if ws is not None:
                ws.close()
            with self.lock:
                self.streams.clear()
                self.follows.clear()
                self.requests.clear()
                self.client_id = None
            if self.alive:
                time.sleep(2)

    def serve(self):
        listed = self.call("session/list", {"_request": {}}) or {}
        with self.lock:
            self.rows = {row["sessionId"]: row for row in listed.get("items") or [] if isinstance(row, dict) and row.get("sessionId")}
            for sid, row in self.rows.items():
                self.running[sid] = bool(row.get("running"))
                # 列表里带着缓存的投影（标题、用量……）：control 流的基线到之前先用着
                cached = (row.get("projections") or {}).get("values") if isinstance(row.get("projections"), dict) else None
                if isinstance(cached, dict):
                    self.projections.setdefault(sid, {}).update(cached)
        self.ws = WebSocket(SocketPipe(("127.0.0.1", self.port)), path="/api/remote.mux", host=self.authority,
                            headers={"Cookie": dsh_cookie(self.secret, self.authority)})
        self.open("$events", {}, self.on_event)
        self.open("session/control", {}, self.on_control)
        self.workspace_ready, self.workspace_wait = False, time.time() + 3
        self.open("workspace/follow", {}, self.on_workspace)
        self.connected = True
        self.sync_follows()
        while self.alive:
            frame = json.loads(self.ws.recv())
            kind, stream = frame.get("type"), frame.get("streamId")
            with self.lock:
                handler = self.streams.get(stream)
                if kind in ("end", "error"):
                    self.streams.pop(stream, None)
            if handler is None:
                continue
            if kind == "item":
                handler(frame.get("value"))
            elif kind in ("end", "error"):
                if kind == "error":
                    log("DeepSeek Harness 流出错：%s" % json.dumps(frame.get("error"), ensure_ascii=False)[:300])
                handler(None)

    def stop(self):
        self.alive = False
        ws = self.ws
        if ws is not None:
            ws.close()

    # --- 流 ---

    def on_event(self, value):
        if value is None:
            raise EOFError("$events 流结束")
        kind = value.get("type")
        now = _now_ms()
        with self.lock:
            if kind == "ready":
                self.client_id = value.get("clientId")
            elif kind == "emit":
                event, args = value.get("event"), value.get("args") or []
                head = args[0] if args else None
                if event == "api-session/added" and isinstance(head, dict) and head.get("sessionId"):
                    self.rows[head["sessionId"]] = head
                    self.running[head["sessionId"]] = bool(head.get("running"))
                elif event == "api-session/removed" and isinstance(head, str):
                    for table in (self.rows, self.projections, self.running, self.touched, self.latest, self.calls, self.sent):
                        table.pop(head, None)
                elif event == "api-session/status" and isinstance(head, str):
                    self.running[head] = bool(args[1]) if len(args) > 1 else False
                    self.touched[head] = now
                elif event == "api-session/activity" and isinstance(head, str):
                    self.touched[head] = now
                elif event == "api-session/error" and isinstance(head, str):
                    detail = args[1] if len(args) > 1 else None
                    self.latest.setdefault(head, {})["error"] = (detail.get("message") if isinstance(detail, dict) else str(detail or "")) or "出错"
            elif kind == "waterfall" and value.get("eventId"):
                self.requests[value["eventId"]] = value
                if value.get("agentId"):
                    self.touched[value["agentId"]] = now
            elif kind == "cancel":
                self.requests.pop(value.get("eventId"), None)

    def on_control(self, value):
        if value is None:
            raise EOFError("session/control 流结束")
        with self.lock:
            if value.get("type") == "baseline":
                # {会话 id: {asOfSeq, values: {投影名: 值}}}
                projections = (value.get("value") or {}).get("projections") or {}
                for sid, entry in projections.items():
                    if isinstance(entry, dict) and isinstance(entry.get("values"), dict):
                        self.projections.setdefault(sid, {}).update(entry["values"])
            elif value.get("type") == "projection" and value.get("sessionId"):
                self.projections.setdefault(value["sessionId"], {})[value.get("key")] = value.get("value")

    def on_workspace(self, value):
        # 基线、整份替换里带着全部归档的会话，之后归档有变化单独来一帧 archived（都是整份）。
        # 老版本没有这个流、流断了都不影响别的：只是不知道哪些归档了
        self.workspace_ready = True
        if not isinstance(value, dict):
            return
        kind = value.get("type")
        body = value.get("value") if kind in ("baseline", "replace") else value if kind == "archived" else None
        ids = body.get("archivedSessionIds") if isinstance(body, dict) else None
        if isinstance(ids, list):
            with self.lock:
                self.archived = {str(i) for i in ids}

    def follow(self, sid):
        stream = None

        def handle(value):
            if value is None:
                with self.lock:
                    if self.follows.get(sid) == stream:
                        del self.follows[sid]
                return
            if value.get("type") == "snapshot":
                records = value.get("records") or []
                if isinstance(value.get("cursor"), int):
                    with self.lock:
                        self.cursors[sid] = max(self.cursors.get(sid, 0), value["cursor"])
                self.absorb(sid, [r.get("event") for r in records if isinstance(r, dict) and r.get("type") == "event"], True)
            elif value.get("type") == "event":
                self.absorb(sid, [value.get("event")], False)

        request = {"address": {"kind": "session", "sessionId": sid}}
        request.update(DSH_FOLLOW_WINDOW)
        stream = self.open("session/follow", {"request": request}, handle)
        with self.lock:
            self.follows[sid] = stream

    def absorb(self, sid, events, snapshot):
        items = dsh_items(events)
        with self.lock:
            seqs = [e["seq"] for e in events if isinstance(e, dict) and isinstance(e.get("seq"), int)]
            if seqs:
                self.cursors[sid] = max([self.cursors.get(sid, 0)] + seqs)
            calls = {} if snapshot else self.calls.setdefault(sid, {})
            latest = self.latest.setdefault(sid, {})
            for item in items:
                if item["t"] == "text":
                    latest["message"], latest["messageId"] = item["text"][:MESSAGE_MAX_CHARS], item["id"]
                elif item["t"] == "tool":
                    calls[item.get("toolId")] = item
                elif item["t"] == "result":
                    calls.pop(item.get("toolId"), None)
                elif item["t"] == "event" and item.get("level") == "error":
                    latest["error"] = item["text"]
                elif item["t"] == "user":
                    latest["error"] = None
            for event in events:
                if isinstance(event, dict) and event.get("type") == "turn/end":
                    calls.clear()   # 一轮结束：没出结果的工具（被中断的）不再算「正在跑」
            self.calls[sid] = calls
            sent = self.sent.setdefault(sid, {})
            changed = []
            for item in items:
                mark = json.dumps(item, sort_keys=True, ensure_ascii=False)
                if sent.get(item["id"]) != mark:
                    sent[item["id"]] = mark
                    changed.append(item)
            if len(sent) > 600:
                for key in list(sent.keys())[:300]:
                    sent.pop(key, None)
            if changed:
                self.outbox.append((sid, changed))

    def live(self):
        """算「开着」的会话：DSH 里已经载入、说过话的，正在跑的，有待答请求的，Kiteline 连上后有动静的"""
        with self.lock:
            pending = {r.get("agentId") for r in self.requests.values()}
            out = []
            for sid, row in self.rows.items():
                # 空白（还没说过话）以投影为准：新建的会话说过话以后，DSH 只更新投影，不再推新的列表行
                meta = (self.projections.get(sid) or {}).get("sessionListMetadata")
                blank = meta.get("blank") if isinstance(meta, dict) and "blank" in meta else row.get("blank")
                if sid in self.archived or blank and not self.running.get(sid):
                    continue
                if row.get("agentAvailable") or self.running.get(sid) or sid in pending or sid in self.touched:
                    out.append(sid)
            return out

    def sync_follows(self):
        if not self.connected:
            return
        live = set(self.live())
        with self.lock:
            missing = [sid for sid in live if sid not in self.follows]
            stale = [(sid, stream) for sid, stream in self.follows.items() if sid not in live]
        for sid in missing:
            self.follow(sid)
        for sid, stream in stale:
            with self.lock:
                self.follows.pop(sid, None)
            self.close_stream(stream)

    def pump(self):
        with self.lock:
            out, self.outbox = self.outbox, []
        return out

    # --- 快照 ---

    def request_for(self, sid):
        with self.lock:
            return next((r for r in self.requests.values() if r.get("agentId") == sid), None)

    def snapshots(self):
        # 刚连上、工作区基线还没到：先不列（不然归档了的会话会在列表里闪一下），最多等 3 秒
        if not self.workspace_ready and time.time() < self.workspace_wait:
            return []
        self.sync_follows()
        live = self.live()
        out = []
        for sid in live:
            with self.lock:
                row = dict(self.rows.get(sid) or {})
                proj = dict(self.projections.get(sid) or {})
                running = self.running.get(sid)
                note = dict(self.latest.get(sid) or {})
                calls = list((self.calls.get(sid) or {}).values())
            request = self.request_for(sid)
            waiting_for, pending_tool, pending_id = None, None, None
            if request is not None:
                body = request.get("request") if isinstance(request.get("request"), dict) else {}
                pending_id = request.get("eventId")
                if request.get("event") == "user-questions/request":
                    first = (body.get("questions") or [{}])[0]
                    waiting_for, pending_tool = first.get("question") or "等待你回答", "AskUserQuestion"
                else:
                    pending_tool = dsh_tool(body.get("toolName") or "", {})[0]
                    # displayReason 是 {en, zh}：出口会按设备语言换，这里给中文原文
                    shown = body.get("displayReason")
                    if isinstance(shown, dict):
                        shown = shown.get("zh") or shown.get("en")
                    waiting_for = str(shown or "请求权限确认：%s" % (body.get("reason") or body.get("toolName") or ""))[:160]
            last_call = calls[-1] if calls else None
            if waiting_for:
                activity, reason = "waiting", waiting_for
            elif running:
                activity, reason = "busy", (last_call or {}).get("brief") or "正在工作"
            else:
                activity, reason = "idle", note.get("message")
            title = proj.get("title") if isinstance(proj.get("title"), str) else row.get("title")
            cwd = row.get("cwd") or ""
            usage = None
            tokens = proj.get("tokenUsage") if isinstance(proj.get("tokenUsage"), dict) else None
            pressure = proj.get("contextPressure") if isinstance(proj.get("contextPressure"), dict) else {}
            if tokens:
                model = (((proj.get("modelSelection") or {}).get("lastUsed") or {}).get("model")) if isinstance(proj.get("modelSelection"), dict) else None
                context = int(pressure.get("pressureTokens") or 0)
                usage = {"context": context, "window": int(pressure.get("contextWindow") or 0),
                         "input": int(tokens.get("uncachedInputTokens") or 0), "output": int(tokens.get("outputTokens") or 0),
                         "cacheRead": int(tokens.get("cacheReadTokens") or 0), "cacheWrite": int(tokens.get("cacheWriteTokens") or 0),
                         "requests": 0, "model": model, "cost": None, "costAt": None}
            error = note.get("error")
            updated = row.get("updatedAt")
            out.append({
                "pid": self.pid,
                "sessionId": sid,
                "name": title or sid[-8:],
                "title": title,
                "cwd": cwd,
                "cwdShort": display_cwd(cwd),
                "status": "busy" if running else "idle",
                "waitingFor": waiting_for,
                "needs": None,
                "detail": None,
                "activity": activity,
                "reason": reason,
                "activityText": (last_call or {}).get("brief") if activity == "busy" else None,
                "message": note.get("message"),
                "messageUuid": note.get("messageId"),
                "error": {"kind": "api", "text": "DeepSeek Harness %s" % error[:160]} if error and activity == "idle" else None,
                "effort": None,
                "subagents": 0,
                "pendingTool": pending_tool if activity == "waiting" else None,
                "pendingId": pending_id,
                "startedAt": row.get("createdAt"),
                "statusUpdatedAt": None,
                "updatedAt": updated,
                "version": None,
                "entrypoint": "dsh",
                "sessionKind": None,
                "tmuxPane": None,
                "usage": usage,
                "transcriptPath": None,
                "transcriptUpdatedAt": updated,
                "agent": "deepseek-harness",
            })
        return out

    # --- 手机上的操作 ---

    def answer_event(self, request, value):
        if not self.client_id:
            raise RuntimeError("和 DeepSeek Harness 的连接还没就绪")
        self.call("$events/result", {"clientId": self.client_id, "eventId": request["eventId"],
                                     "outcome": {"kind": "result", "value": value}})
        with self.lock:
            self.requests.pop(request["eventId"], None)

    def send(self, sid, text, images):
        content = [{"type": "text", "text": text}] if text else []
        for path in images:
            with open(path, "rb") as handle:
                data = handle.read()
            if len(data) > SEND_IMAGE_MAX:
                raise RuntimeError("图片太大")
            content.append({"type": "image", "data": base64.b64encode(data).decode("ascii"),
                            "mediaType": mimetypes.guess_type(path)[0] or "image/jpeg", "name": os.path.basename(path)})
        if not content:
            raise RuntimeError("内容为空")
        with self.lock:
            running = self.running.get(sid)
        # 忙的时候插进这一轮（下一步就看到），闲着就开新的一轮
        self.call("session/prompt", {"request": {"requestId": str(uuid.uuid4()), "sessionId": sid,
                                                 "mode": "steer" if running else "queue", "content": content}})
        with self.lock:
            self.touched[sid] = _now_ms()
        return "已发送"

    def key(self, sid, key):
        request = self.request_for(sid)
        with self.lock:
            running = self.running.get(sid)
        if request is not None and request.get("event") == "approval/request":
            decision = DSH_DECISIONS.get(key)
            if decision is None:
                raise RuntimeError("DeepSeek Harness 会话不支持这个操作")
            self.answer_event(request, decision)
            return "已选择"
        if key == "esc" and (running or request is not None):
            # 没有待确认的审批：中断这一轮（等着回答的提问也一起撤掉）
            self.call("session/cancel", {"request": {"sessionId": sid}})
            return "已中断"
        raise RuntimeError("这个 DeepSeek Harness 会话现在没有待确认的操作")

    def close(self, sid):
        # 归档：从 DeepSeek Harness 窗口的分组里收起来（数据不删，在它的归档里能恢复）；正在工作的先停下（同 Claude Code 关标签）
        result = self.call("workspace/archiveSession", {"request": {"sessionId": sid, "stopActivity": True}}) or {}
        with self.lock:
            self.archived.update(str(i) for i in result.get("archivedSessionIds") or [sid])
        return "已关闭会话（已在 DeepSeek Harness 中归档）"

    def answer(self, sid, answers):
        request = self.request_for(sid)
        if request is None or request.get("event") != "user-questions/request":
            raise RuntimeError("这个 DeepSeek Harness 会话现在没有待回答的提问")
        replies = []
        for index, question in enumerate((request.get("request") or {}).get("questions") or []):
            labels = {o.get("label") for o in question.get("options") or [] if isinstance(o, dict)}
            picked = _answer_for(answers, question.get("question"), index)
            reply = {"id": question.get("id"), "selected": [p for p in picked if p in labels]}
            custom = [p for p in picked if p not in labels]
            if custom:
                reply["custom"] = "\n".join(custom)
            replies.append(reply)
        self.answer_event(request, {"answers": replies})
        return "已回答"

    def cursor(self, sid):
        """翻历史要带一个不超过日志末尾的序号：跟着的会话用收到的最新序号，没跟的用列表里投影的序号"""
        with self.lock:
            if sid in self.cursors:
                return self.cursors[sid]
            row = self.rows.get(sid) or {}
        seq = (row.get("projections") or {}).get("asOfSeq") if isinstance(row.get("projections"), dict) else None
        if isinstance(seq, int):
            return seq
        raise RuntimeError("还不知道这个会话的进度，稍后再试")

    def page(self, sid, before, count):
        request = {"address": {"kind": "session", "sessionId": sid}, "throughSeq": self.cursor(sid), "maxMessages": count}
        if before is not None:
            request["beforeSeq"] = int(before)
        page = self.call("session/page", {"request": request}, timeout=30) or {}
        return [r.get("event") for r in page.get("records") or [] if isinstance(r, dict) and r.get("type") == "event"], bool(page.get("hasMore"))

    def history(self, sid, before, limit):
        events, has_more = self.page(sid, before, max(10, min(limit, 200)))
        return dsh_items(events), has_more

    def media(self, sid, ref):
        # d<事件序号>.<序号>：用户发的图；d<事件序号>.r<序号>：工具结果里的图（read_image）
        seq_text, _, index_text = ref[1:].partition(".")
        events, _ = self.page(sid, int(seq_text) + 1, 1)
        for event in events:
            if isinstance(event, dict) and event.get("seq") == int(seq_text):
                data = event.get("data") or {}
                if index_text.startswith("r"):
                    part = ((data.get("message") or {}).get("content") or [])[int(index_text[1:])]
                else:
                    part = (data.get("content") or [])[int(index_text)]
                attachment = part.get("attachment") if isinstance(part.get("attachment"), dict) else {}
                attachment_id = attachment.get("attachmentId") or attachment.get("id")   # DSH 落盘的事件里叫 attachmentId；两种写法都认
                found = self.call("session/attachment", {"request": {"sessionId": sid, "attachmentId": attachment_id}}) or {}
                return {"mime": (found.get("attachment") or {}).get("mediaType") or attachment.get("mediaType") or "image/png",
                        "data": found.get("data") or ""}
        raise RuntimeError("图片不存在：%s" % ref)


class DshLink:
    """找出本机的 DeepSeek Harness 网页服务（桌面版、命令行），各连一个"""

    def __init__(self):
        self.hosts = {}       # (pid, 端口) → DshHost
        self.checked = {}     # (pid, 端口) → 是不是能连的 DSH（探测过的不再探）
        self.last_scan = 0.0

    def scan(self):
        now = time.time()
        if now - self.last_scan < 5:
            return
        self.last_scan = now
        secret = dsh_secret()
        found = []
        if secret is not None:
            try:
                found = dsh_listeners()
            except Exception as exc:
                log("找 DeepSeek Harness 进程出错：%r" % exc)
                return
        for key in found:
            if key in self.hosts:
                continue
            if key not in self.checked:
                self.checked[key] = dsh_probe(key[1])
            if self.checked[key]:
                self.hosts[key] = DshHost(key[0], key[1], secret)
        for key in list(self.hosts.keys()):
            host = self.hosts[key]
            if key not in found or not host.alive:
                if host.rejected:
                    self.checked[key] = False
                host.stop()
                del self.hosts[key]
        for key in list(self.checked.keys()):
            if key not in found:
                del self.checked[key]

    def snapshots(self):
        self.scan()
        out = []
        for host in list(self.hosts.values()):
            if host.connected:
                out.extend(host.snapshots())
        return out

    def owner(self, sid):
        for host in list(self.hosts.values()):
            with host.lock:
                if sid in host.rows:
                    return host
        raise RuntimeError("这个 DeepSeek Harness 会话已经关了")

    def pump(self):
        out = []
        for host in list(self.hosts.values()):
            out.extend(host.pump())
        return out


# --- Proma ---
#
# Proma（github.com/proma-ai/Proma，Electron 桌面 Agent）把会话存在 ~/.proma：索引 agent-sessions.json，
# 每个会话一份 agent-sessions/<id>.jsonl，格式就是 Claude Agent SDK 的消息（type user / assistant / result，
# 工具名已经是 Read / Edit / Bash），所以对话项直接用 Claude 的规整函数。
# 它只在一轮结束时把这一轮写盘（开头先写用户那句），没有对外的接口，审批也只在它自己进程里——
# Kiteline 只能看：列表、在跑还是做完了、每轮的对话、完成提醒；回复、确认得回 Proma 里操作（快照带 readOnly）。

PROMA_HOME = os.environ.get("CCPULSE_PROMA_DIR") or os.path.join(HOME, ".proma")
PROMA_RECENT_MS = 6 * 3600 * 1000     # Proma 开着时，最近 6 小时动过的会话算「开着」
PROMA_TAIL_BYTES = 256 * 1024


PROMA_MARKS = re.compile(r"\s*<!--PROMA_[A-Z_]+-->")   # 定时任务发的话后面带的标记（<!--PROMA_SCHEDULED_RUN-->）


class PromaClock:
    """Proma 一轮结束才写盘：助手消息记的是这一轮开始的时间（比用户那句还早几毫秒），工具结果、结尾记的是写盘时间，
    原样用手机上会排乱（手机先按时间排）。按文件位置从头扫，每行的时间取「它自己的」和「前一行的」较大的那个；
    增量扫、按行偏移记，实时推送和往前翻历史查的是同一张表"""

    def __init__(self):
        self.files = {}   # 路径 → {"pos": 扫到哪, "last": 上一行的时间, "map": {行偏移: 时间}, "id": 文件身份}

    def at(self, path, offset):
        try:
            stat = os.stat(path)
        except OSError:
            return None
        ident = (stat.st_dev, stat.st_ino)
        state = self.files.get(path)
        if state is None or state["id"] != ident or stat.st_size < state["pos"]:
            # 新文件，或者被重写（Proma 回退 / 删消息）
            if len(self.files) > 64:
                self.files.pop(next(iter(self.files)))
            state = self.files[path] = {"pos": 0, "last": 0, "map": {}, "id": ident}
        if offset not in state["map"] and state["pos"] < stat.st_size:
            with open(path, "rb") as handle:
                handle.seek(state["pos"])
                data = handle.read(stat.st_size - state["pos"])
            pos = state["pos"]
            for line in data.split(b"\n")[:-1]:   # 最后一段没有换行 = 还没写完，下次再扫
                entry = parse_line(line)
                if entry is not None:
                    created = entry.get("_createdAt") if "_createdAt" in entry else entry.get("createdAt")
                    if isinstance(created, (int, float)):
                        state["last"] = max(int(created), state["last"])
                    state["map"][pos] = state["last"] or None
                pos += len(line) + 1
            state["pos"] = pos
        return state["map"].get(offset)


PROMA_CLOCK = PromaClock()


def normalize_proma_line(offset, entry):
    """Proma 的一行 → 对话项：时间是 _createdAt（毫秒），补成 Claude 的 timestamp；一轮出错记一条红色提示"""
    if not isinstance(entry, dict):
        return []
    message = entry.get("message") if isinstance(entry.get("message"), dict) else None
    if entry.get("type") == "user" and message and isinstance(message.get("content"), list):
        content = [dict(b, text=PROMA_MARKS.sub("", b["text"])) if isinstance(b, dict) and isinstance(b.get("text"), str) else b
                   for b in message["content"]]
        entry = dict(entry, message=dict(message, content=content))
    created = entry.get("_createdAt")
    if not entry.get("timestamp") and isinstance(created, (int, float)):
        entry = dict(entry, timestamp=time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(created / 1000.0)) + ".%03dZ" % (int(created) % 1000))
    if "role" in entry and "type" not in entry:
        # 很早的版本存的是 {role, content}
        role = {"user": "user", "assistant": "assistant"}.get(entry.get("role"))
        if not role or not isinstance(entry.get("content"), str):
            return []
        entry = {"type": role, "timestamp": entry.get("timestamp"), "message": {"content": [{"type": "text", "text": entry["content"]}]}}
    if entry.get("type") == "result":
        subtype = entry.get("subtype")
        if subtype and subtype != "success" and subtype != "error_during_execution_stopped":
            errors = [e for e in entry.get("errors") or [] if isinstance(e, str) and e.strip()]
            return [{"id": "%d.0" % offset, "ts": parse_ts(entry.get("timestamp")), "t": "event", "level": "error",
                     "text": "出错：%s" % (errors[0][:300] if errors else subtype)}]
        return []
    return normalize_line(offset, entry)


def _proma_json(path, cache):
    """读 Proma 的索引文件，按修改时间缓存"""
    try:
        mtime = os.stat(path).st_mtime
    except OSError:
        return None
    if cache.get(path, (None,))[0] != mtime:
        try:
            with open(path, "rb") as handle:
                cache[path] = (mtime, json.loads(handle.read().decode("utf-8")))
        except (OSError, ValueError):
            return cache.get(path, (None, None))[1]
    return cache[path][1]


def proma_running():
    """Proma 桌面版开着没有（主进程）：没开着时它的会话一个都不算开着，也就不会「正在工作」"""
    if IS_WINDOWS:
        return "proma.exe" in set(_win_process_names().values())
    if os.path.isdir("/proc/self/fd"):
        for name in os.listdir("/proc"):
            if name.isdigit() and (read_text("/proc/%s/comm" % name) or "").strip().lower() == "proma":
                return True
        return False
    out = subprocess.run(["ps", "-axww", "-o", "command="], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5)
    return any(line.startswith("/") and "/Proma.app/Contents/MacOS/Proma" in line
               for line in out.stdout.decode("utf-8", "replace").splitlines())


def proma_note(path, size):
    """读一个会话文件的尾巴：最后一句回复、用量、出错，还有这一轮做完没有（只写了用户那句、没有结果 = 还在跑）"""
    try:
        with open(path, "rb") as handle:
            handle.seek(max(0, size - PROMA_TAIL_BYTES))
            raw = handle.read()
    except OSError:
        return {}
    lines = raw.split(b"\n")
    if size > PROMA_TAIL_BYTES:
        lines = lines[1:]   # 第一行多半是被截断的
    note = {"pending": False, "message": None, "messageId": None, "usage": None, "error": None}
    settled = False
    offset = size - len(raw) + (len(raw) - len(b"\n".join(lines)))
    entries = []
    for line in lines:
        entry = parse_line(line)
        if isinstance(entry, dict):
            entries.append((offset, entry))
        offset += len(line) + 1
    for offset, entry in reversed(entries):
        etype = entry.get("type")
        message = entry.get("message") if isinstance(entry.get("message"), dict) else {}
        content = message.get("content") if isinstance(message.get("content"), list) else []
        if not settled:
            if etype in ("assistant", "result"):
                settled = True
            elif etype == "user" and any(isinstance(b, dict) and b.get("type") == "text" for b in content):
                note["pending"] = True
                settled = True
        if etype == "result" and note["error"] is None and note["message"] is None:
            items = normalize_proma_line(offset, entry)
            if items:
                note["error"] = items[0]["text"]
        if etype == "assistant" and note["message"] is None:
            texts = [item for item in normalize_proma_line(offset, entry) if item["t"] == "text"]
            if texts:
                note["message"], note["messageId"] = texts[-1]["text"][:MESSAGE_MAX_CHARS], texts[-1]["id"]
        if note["usage"] is None and etype in ("assistant", "result"):
            usage = (message.get("usage") if etype == "assistant" else entry.get("usage")) or {}
            if isinstance(usage, dict) and usage.get("input_tokens") is not None:
                read = int(usage.get("cache_read_input_tokens") or 0)
                write = int(usage.get("cache_creation_input_tokens") or 0)
                context = int(usage.get("input_tokens") or 0) + read + write + int(usage.get("output_tokens") or 0)
                # Proma 不记模型的上下文窗口：给 0，界面不显示占比
                note["usage"] = {"context": context, "window": 0, "input": int(usage.get("input_tokens") or 0),
                                 "output": int(usage.get("output_tokens") or 0), "cacheRead": read, "cacheWrite": write,
                                 "requests": 0, "model": entry.get("_channelModelId") or message.get("model"),
                                 "cost": entry.get("total_cost_usd"), "costAt": None}
        if settled and note["message"] is not None and note["usage"] is not None:
            break
    return note


class PromaLink:
    """Proma 的会话：读它落盘的文件（只读）"""

    def __init__(self):
        self.cache = {}         # 索引文件 → (修改时间, 内容)
        self.notes = {}         # 会话文件 → (大小, 修改时间, 尾巴里认出的东西)
        self.checked = 0.0
        self.running = False

    def app_running(self):
        now = time.time()
        if now - self.checked >= 5:
            self.checked = now
            try:
                self.running = proma_running()
            except Exception as exc:
                log("查 Proma 进程出错：%r" % exc)
                self.running = False
        return self.running

    def cwd(self, meta, workspaces):
        """和 Proma 一样算 agent 的工作目录：激活的 worktree > 项目目录（project 模式）> 会话自己的工作台目录"""
        worktree = (meta.get("activeWorktree") or {}).get("path") if isinstance(meta.get("activeWorktree"), dict) else None
        if worktree and os.path.isdir(worktree):
            return worktree
        workspace = workspaces.get(meta.get("workspaceId")) or {}
        slug = workspace.get("slug")
        if not slug:
            return ""
        base = os.path.join(PROMA_HOME, "agent-workspaces", slug)
        if meta.get("agentCwdMode") == "project":
            return workspace.get("projectRootPath") or os.path.join(base, "workspace-files")
        return os.path.join(base, meta["id"])

    def snapshots(self):
        index = os.path.join(PROMA_HOME, "agent-sessions.json")
        if not os.path.isfile(index) or not self.app_running():
            return []
        metas = [m for m in ((_proma_json(index, self.cache) or {}).get("sessions") or []) if isinstance(m, dict) and m.get("id")]
        workspaces = {w.get("id"): w for w in ((_proma_json(os.path.join(PROMA_HOME, "agent-workspaces.json"), self.cache) or {})
                                               .get("workspaces") or []) if isinstance(w, dict)}
        children = {}
        for meta in metas:
            if meta.get("parentSessionId"):
                children[meta["parentSessionId"]] = children.get(meta["parentSessionId"], 0) + 1
        now = _now_ms()
        out = []
        for meta in metas:
            # 子会话（父 agent 派出去的）不单列，算子 agent 数；归档的、还没发过消息的草稿不算
            if meta.get("archived") or meta.get("isDraft") or meta.get("parentSessionId"):
                continue
            path = os.path.join(PROMA_HOME, "agent-sessions", meta["id"] + ".jsonl")
            try:
                stat = os.stat(path)
            except OSError:
                continue
            updated = max(int(meta.get("updatedAt") or 0), int(stat.st_mtime * 1000))
            if now - updated > PROMA_RECENT_MS:
                continue
            cached = self.notes.get(path)
            if cached and cached[:2] == (stat.st_size, stat.st_mtime):
                note = cached[2]
            else:
                note = proma_note(path, stat.st_size)
                self.notes[path] = (stat.st_size, stat.st_mtime, note)
            busy = note.get("pending") and not meta.get("stoppedByUser")
            cwd = self.cwd(meta, workspaces)
            title = meta.get("title") or None
            error = note.get("error")
            out.append({
                "pid": None,
                "sessionId": meta["id"],
                "name": title or meta["id"][-8:],
                "title": title,
                "cwd": cwd,
                "cwdShort": display_cwd(cwd),
                "status": "busy" if busy else "idle",
                "waitingFor": None,
                "needs": None,
                "detail": None,
                "activity": "busy" if busy else "idle",
                "reason": "正在工作" if busy else note.get("message"),
                "activityText": None,
                "message": note.get("message"),
                "messageUuid": note.get("messageId"),
                "error": {"kind": "api", "text": "Proma %s" % error[:160]} if error and not busy else None,
                "effort": None,
                "subagents": children.get(meta["id"], 0),
                "pendingTool": None,
                "pendingId": None,
                "startedAt": meta.get("createdAt"),
                "statusUpdatedAt": None,
                "updatedAt": updated,
                "version": None,
                "entrypoint": "proma",
                "sessionKind": None,
                "tmuxPane": None,
                "usage": note.get("usage"),
                "transcriptPath": path,
                "transcriptUpdatedAt": updated,
                "agent": "proma",
                # Proma 没有对外的接口：只能看，回复和确认在 Proma 里做
                "readOnly": True,
            })
        live = {os.path.join(PROMA_HOME, "agent-sessions", s["sessionId"] + ".jsonl") for s in out}
        for path in list(self.notes.keys()):
            if path not in live:
                del self.notes[path]
        return out


# ---------------------------------------------------------------------------
# Agent 插件（规范见 guide/plugin-development.md）
#
# Claude Code 以外的每家 agent 是一个插件：找会话、翻成统一的快照和对话项、把手机上的操作翻成它的动作。
# 连接、读文件、起进程这些通用能力由中台（本文件前面的函数和类）提供，插件在 needs 里列出用到的，
# 对照能力登记表 HOST_CAPS，缺了就不启用。现在几家都是内置插件，以后单独下发的插件也用同一个接口。
# ---------------------------------------------------------------------------

# 中台能力登记表：能力名 → 从第几版中台起有。只加不改；补一项能力就加一行，HOST_API 跟着加一
HOST_API = 3
HOST_CAPS = {
    "locate": 1,         # agent 装在哪、什么版本
    "fs.read": 1,        # 读文件、列目录
    "fs.tail": 1,        # 跟追加写的记录文件（Tailer）
    "db.read": 1,        # 只读打开 SQLite
    "proc": 1,           # 列进程、验活、父进程链、命令行
    "proc.pipe": 1,      # 起子进程走标准输入输出（ProxyPipe）
    "net.connect": 1,    # Unix socket、命名管道、本机 TCP；按行或长度前缀分帧
    "net.ws": 1,         # 本机 WebSocket
    "net.http": 1,       # 本机 HTTP
    "net.sse": 1,        # 本机事件流
    "secret.read": 1,    # 读 agent 自己存在本机的凭据
    "install.file": 1,   # 往 agent 里装带标记的组件，停用即删
    "term.tmux": 1,      # 往 tmux 窗格发文字和按键
    # 通用终端层：term_pane / term_screen / term_keys，tmux、托管会话、Windows 控制台同一套调用；
    # Windows 上没有 tmux 的命令行 agent 也能回复、确认、中断（11-05）。老中台没有这几个函数，插件退回只认 tmux
    "term.any": 1,
    # 跨平台进程列举 process_list()：Windows 上没有 ps，插件找进程用它（11-05）
    "proc.list": 1,
    # 界面动作单（规范 3.3 的第一步）：插件的 send 可以回 {"message", "ui": [动作…]}，电脑端按顺序做、做完把前台还给用户：
    #   {"do": "focus", "app", "folder"}  把 app 里打开了这个项目的窗口切到前台，核对确实在前台
    #   {"do": "plugin", "step"}          回头请插件做一步（cmd agent_ui → 插件的 ui_step），比如窗口在前台后再往里填字
    #   {"do": "key", "name"}             核对前台还是那个窗口，按键
    # 哪一步不成就停下、不按键，告诉用户停在哪。只在电脑端发消息时带了 ui（它会执行）时才回，插件看 self.host_ui；
    # 老电脑端不带，插件照旧（Cursor 编辑器空闲时从手机发消息靠它，11-01）
    "ui.keys": 2,
    # 插件的单项开关（清单的 options / 类属性 options）：插件里某一项要读那家 agent 存在本机的凭证才做得到（Cursor 查月用量），
    # 插件照常接、这一项默认关，用户在设置 → 插件里看过说明自己打开（电脑端经 CCPULSE_PLUGIN_OPTIONS_ON 带「插件 id.开关 id」）。
    # 插件用 self.option_on(开关 id) 判断；老中台没有这一项时 option_on 不存在，插件按关着处理（11-02）
    "plugin.options": 3,
}

VSCODE_EXTENSION_ROOTS = [os.path.join(HOME, folder, "extensions")
                          for folder in (".vscode", ".vscode-insiders", ".cursor", ".windsurf", ".vscode-server")]


def version_tuple(text):
    return tuple(int(x) if x.isdigit() else 0 for x in re.split(r"[.\-+]", str(text or "0"))[:4])


def extension_version(prefix):
    """本机 VS Code 系编辑器里装的扩展（目录名「发布者.名字-版本[-平台]」）的最新版本；没装返回 None"""
    best = None
    for root in VSCODE_EXTENSION_ROOTS:
        for path in globlib.glob(os.path.join(root, prefix + "-*")):
            version = os.path.basename(path)[len(prefix) + 1:].split("-")[0]
            if best is None or version_tuple(version) > version_tuple(best):
                best = version
    return best


FULL = ("view", "reply", "approve", "answer", "interrupt")


def support_form(abilities=FULL, verified=False, note=None):
    """兼容表里的一格：这个平台的这个形态能做到什么、我们实测过没有；abilities 为空表示没有（note 说原因）"""
    cell = {"abilities": list(abilities), "verified": verified}
    if note:
        cell["note"] = note
    return cell


def detect_by_spec(spec):
    """索引里给还没装的插件写的简单检测：这台机器上有这些目录、命令之一就算装了那家 agent"""
    if not isinstance(spec, dict):
        return False
    if any(os.path.exists(os.path.expanduser(p)) for p in spec.get("paths") or [] if isinstance(p, str)):
        return True
    folders = [os.path.join(HOME, ".local", "bin"), os.path.join(HOME, ".npm-global", "bin"), os.path.join(HOME, ".bun", "bin"),
               "/usr/local/bin", "/opt/homebrew/bin"]
    suffix = ".exe" if IS_WINDOWS else ""
    return any(isinstance(c, str) and (shutil.which(c) or any(os.path.isfile(os.path.join(d, c + suffix)) for d in folders))
               for c in spec.get("commands") or [])


def app_version(path):
    """macOS 上某个 .app 的版本号；没装（或不是 Mac）返回 None"""
    try:
        import plistlib
        with open(os.path.join(path, "Contents", "Info.plist"), "rb") as handle:
            return str(plistlib.load(handle).get("CFBundleShortVersionString") or "") or None
    except (OSError, ValueError):
        return None


# 待确认卡片的按钮（快照的 pendingOptions）：key 是手机发回、交给插件 key() 的按键；
# style：primary 主按钮 / destructive 拒绝（红字）/ normal 次要。文字是中文原文，电脑端出口按设备语言翻
APPROVAL_OPTIONS = ({"key": "esc", "label": "拒绝", "style": "destructive"},
                    {"key": "1", "label": "允许", "style": "primary"},
                    {"key": "2", "label": "允许，且本会话不再询问", "style": "normal"})


class AgentPlugin:
    """插件接口。没实现的方法 = 没有这项能力（默认实现给出说明或交还中台）"""

    id = ""              # 快照里的 agent 字段
    name = ""
    version = "1.0.0"    # 内置插件随 watcher 走；外部插件取清单里的版本，比内置的新才顶替
    source = "builtin"   # builtin / external
    needs = ()           # 用到的中台能力（HOST_CAPS 里的名字）
    # 对话记录落在文件里（快照带 transcriptPath）的：一行 → 对话项。跟文件、翻历史、搜索、取图都由中台按文件做
    normalize = None
    # 只读的 agent：手机上回复、确认时给的说明
    read_only = None
    # 各平台、各形态能做到什么（设置页的兼容表、guide/plugin-development.md）：{平台: {形态: support_form(...)}}。
    # 平台 mac / windows / linux；形态 cli 命令行 / vscode VS Code 扩展 / desktop 桌面版。
    # 能力：view 查看会话和记录（读）、reply 发消息和插话（写）、approve 审批命令 / answer 回答提问 / interrupt 中断（执行）
    support = {}
    # 看、回复、确认、中断以外，手机上还能出哪些按钮（快照的 caps，guide/plugin-development.md 4.4）：
    # mode 权限模式 / model 换模型 / compact 压缩上下文 / subagents 子 agent / tests 测试记录。目前只有 Claude Code 有
    caps = ()
    # 单色标志：24×24 画布的 SVG 路径（奇偶填充）[{"d": …, "opacity": 1}]。手机内置表里没有这家时画它，不用为新 agent 发 App
    mark = None
    # 对话里怎么称呼（「Qwen 想使用 Bash」）；不给就用 name
    speaker = None
    # 各端最低版本（清单的 minApp）：ios 一项转给手机，手机版本低于它就提示去 App Store 更新
    min_app = None
    # 不是那家 agent 开放给第三方的接入方式（比如要读它存在本机的密钥）：默认不接，用户在设置 → 插件里看过这段说明、
    # 自己打开（PLUGINS_ON）才接。None = 检测到就启用。opt_in_en 是英文说明（外部插件用；内置的走 i18n/en.json）
    opt_in = None
    opt_in_en = None
    # 这次发消息的电脑端能执行哪些界面动作（请求里的 ui，如 ["keys"]）；老电脑端是空的。send 可以据此回动作单（见 HOST_CAPS 的 ui.keys）
    host_ui = ()
    # 单项开关（HOST_CAPS 的 plugin.options）：[{"id", "name", "note", "optIn"}，各带 …En 英文]——name 开关名、note 一句话说明、
    # optIn 打开前给用户看的完整说明（读哪份凭证、查什么、只在本机用）。都默认关
    options = ()
    # 额度、余额这家能不能显示、从哪来、为什么没有（设置 → 插件里那家下面的一行「额度：…」，规范 4.5）。每个插件都要写；
    # 英文：内置的走 i18n/en.json，外部插件写清单的 limitsNoteEn
    limits_note = None
    limits_note_en = None
    # 功能上的缺口（设置 → 插件里那家下面逐条显示，规范 4.2 的 gaps）：[{"kind": "unsupported" 确定做不到 / "untested" 还没实测,
    # "text": 中文（做不到的要写原因）, "textEn": 英文}]。没列的就是都做到了、也测过
    gaps = ()

    def option_on(self, key):
        """用户在设置里打开了这一项没有"""
        return "%s.%s" % (self.id, key) in PLUGIN_OPTIONS_ON

    def standardize(self, snap):
        """补上客户端认的标准字段（guide/plugin-development.md 第五节）：caps、待确认卡片的按钮、只读的说明"""
        caps = snap.setdefault("caps", list(self.caps))
        # 关闭会话：插件实现了 close()、这个会话也关得了就给（客户端菜单里出「关闭会话」）
        if not snap.get("readOnly") and "close" not in caps and self.closable(snap):
            caps.append("close")
        if snap.get("activity") == "waiting" and "pendingOptions" not in snap:
            options = self.pending_options(snap)
            if options:
                snap["pendingOptions"] = [dict(option) for option in options]
        if snap.get("readOnly") and self.read_only and not snap.get("readOnlyReason"):
            snap["readOnlyReason"] = self.read_only
        return snap

    def pending_options(self, snap):
        """等确认时卡片上的按钮，客户端按顺序画、把 key 原样发回给 key()。提问、计划、只读的不给（客户端有专门的卡片）"""
        if self.read_only or snap.get("readOnly") or type(self).key is AgentPlugin.key:
            return None
        if snap.get("pendingTool") in ("AskUserQuestion", "ExitPlanMode"):
            return None
        return APPROVAL_OPTIONS

    def normalizer_for(self, path):
        """记录文件按文件规整：默认就是 normalize；时间等要按文件位置修正的插件（Proma）覆盖它"""
        return self.normalize

    def detect(self):
        """本机装没装这家 agent：{installed, forms: {形态: 版本}}；不知道就返回 None。只读、设置页打开时才调"""
        return None

    def abilities(self):
        """设置页上显示的能力：view 能看 / reply 能回复 / approve 能审批 / answer 能回答提问"""
        if self.read_only:
            return ["view"]
        own = type(self)
        return ["view"] + [name for name, method in (("reply", "send"), ("approve", "key"), ("answer", "answer"))
                           if getattr(own, method) is not getattr(AgentPlugin, method)]

    def start(self):
        pass

    def disable(self):
        """用户在设置里关掉了：把装进 agent 里的东西删干净（不会再 start）"""
        pass

    def sessions(self):
        """→ 快照列表"""
        return []

    def pump(self):
        """没有记录文件的：→ [(会话 id, 新对话项)]"""
        return []

    def history(self, sid, before, limit):
        """没有记录文件的：→ (对话项, 还有没有更早的)"""
        raise RuntimeError("这个会话没有历史记录")

    def items(self, sid, limit):
        """没有记录文件的：最近的对话项（会话内搜索用）"""
        return self.history(sid, None, limit)[0]

    def media(self, sid, ref, path):
        """自己认得的图片引用 → {mime, data}；不认得返回 None，交给中台（path 是快照里的记录文件，可能没有）"""
        return None

    def send(self, sid, text, images):
        raise RuntimeError(self.read_only or "%s 不支持远程回复" % self.name)

    def key(self, sid, key):
        raise RuntimeError(self.read_only or "%s 不支持远程操作" % self.name)

    def answer(self, sid, answers):
        raise RuntimeError(self.read_only or "%s 不支持远程回答" % self.name)

    def close(self, sid):
        """关闭会话：同 Claude Code 关掉 VS Code 里的标签页——结束这个会话、关掉它在 agent 里的窗口或界面，之后能恢复的尽量能恢复"""
        raise RuntimeError(self.read_only or "%s 不支持远程关闭会话" % self.name)

    def ui_step(self, sid, step):
        """电脑端执行插件回的动作单（send 回的 ui）到 {"do": "plugin", "step"} 时调：做这一步，→ 给用户看的一句话；做不了抛错"""
        raise RuntimeError("%s 不支持这一步：%s" % (self.name, step))

    def limits(self):
        """这家 agent 在这台电脑上的额度 / 余额（手机「今日用量」卡片，电脑端几分钟问一次，要快、要缓存）：
        {"at": 读数时间（毫秒）, "windows": [{kind, percent, resetsAt}], "balances": [{currency, amount, kind}], "plan"}；没有返回 None。
        窗口 kind：five_hour 5 小时 / day 今日 / seven_day 本周 / month 本月（按账单周期），别的写 window_<分钟数>；
        余额 kind：main 充值的 / bonus 赠送的。优先用这家 agent 自己记下、自己给的读数；要读它存在本机的凭证才查得到的，
        得写进 opt_in 的说明、用户打开才查（Claude 的凭证一律不碰）"""
        return None

    def usage(self, since_ms):
        """这家 agent 在这台电脑上记下的 token 用量（用量报表、手机「今日用量」的 token 和花费）：since_ms 之后的一条条记录
        [{"ts": 毫秒, "model": 模型名, "cwd": 工作目录或 None, "session": 会话 id（可选，数会话用）,
          "input": 不含缓存的输入, "output": 输出, "cacheRead": 读缓存, "cacheWrite": 写缓存, "requests": 请求数,
          "cost": 美元（agent 自己记的；没有给 None，报表按「无费率」只算 token）}]。
        电脑端一分钟内可能问好几次、一次可能要 90 天的：按文件签名缓存，别每次全扫；一条一条的请求也可以先按小时、模型并好再给"""
        return []

    def closable(self, snap):
        """这个会话能不能关（决定 caps 里给不给 close）：默认实现了 close() 就都能"""
        return type(self).close is not AgentPlugin.close


class CodexPlugin(AgentPlugin):
    """终端会话在共享后台服务里（CodexLink），桌面版、VS Code 扩展的在 IPC 总线上（CodexIpcLink）"""

    id, name = "codex", "Codex"
    needs = ("locate", "net.connect", "net.ws", "proc.pipe", "fs.tail", "db.read")
    limits_note = "「今日用量」中显示 5 小时与本周额度（免费版为 30 天额度），取自 Codex 自己的记录，回复一次后更新"
    normalize = staticmethod(normalize_codex_line)
    # 10-23 真机矩阵 + 10-24 真实 Codex + 假模型的端到端（tools/codex-probe/e2e_watcher.py）
    support = {
        "mac": {"cli": support_form(verified=True), "vscode": support_form(verified=True), "desktop": support_form(verified=True)},
        "windows": {"cli": support_form(verified=True), "vscode": support_form(verified=True), "desktop": support_form(verified=True)},
        "linux": {"cli": support_form(verified=True), "vscode": support_form(verified=True),
                  "desktop": support_form((), note="Codex 桌面版没有 Linux 版")},
    }

    def __init__(self):
        self.daemon = CodexLink()
        self.ipc = CodexIpcLink()

    def usage(self, since_ms):
        """token 用量：Codex 自己的记录（rollout 里的 token_count）；它不记花费，报表里按「无费率」只算 token"""
        return codex_token_usage(since_ms)

    def detect(self):
        forms = {}
        if shutil.which("codex"):
            forms["cli"] = ""
        if extension_version("openai.chatgpt"):
            forms["vscode"] = extension_version("openai.chatgpt")
        if app_version("/Applications/ChatGPT.app"):
            forms["desktop"] = app_version("/Applications/ChatGPT.app")
        return {"installed": bool(forms) or os.path.isdir(CODEX_HOME), "forms": forms}

    def start(self):
        self.daemon.start()
        self.ipc.start()

    def sessions(self):
        out = []
        try:
            out.extend(self.daemon.snapshots())
        except Exception as exc:
            log("CodexLink 快照出错：%r" % exc)
        with self.daemon.lock:
            daemon_ids = set(self.daemon.threads.keys())
        try:
            # 桌面版、VS Code 扩展的会话：共享后台服务里已经有的不重复列
            out.extend(self.ipc.snapshots(daemon_ids))
        except Exception as exc:
            log("CodexIpcLink 快照出错：%r" % exc)
        try:
            goals = codex_goals()
        except Exception as exc:
            log("Codex 目标出错：%r" % exc)
            goals = None
        for snap in out:
            sid = snap.get("sessionId")
            if goals and goals.get(sid):
                snap["goal"] = dict(goals[sid])
            if goals is not None and sid in daemon_ids:
                # 终端里的会话在共享后台服务里，能替它设定 / 暂停目标；桌面版、VS Code 扩展的只能看（IPC 总线没有目标的请求）
                caps = snap.setdefault("caps", list(self.caps))
                caps.extend(cap for cap in ("goal", "goal-pause") if cap not in caps)
        return out

    def via_ipc(self, sid):
        with self.daemon.lock:
            if sid in self.daemon.threads:
                return False
        return self.ipc.owns(sid)

    def send(self, sid, text, images):
        command = None if images else goal_command(text)
        if command:
            # /goal 不是发给模型的话：交给后台服务设定目标（Codex 终端里的 /goal 也是这样，不进对话）
            if self.via_ipc(sid):
                raise RuntimeError("Codex 桌面版、VS Code 扩展中的会话请在 Codex 中设定目标")
            return self.daemon.goal(sid, *command)
        if self.via_ipc(sid):
            return self.ipc.send_message(sid, text, images)
        return self.daemon.send(sid, text, images)

    def key(self, sid, key):
        return (self.ipc if self.via_ipc(sid) else self.daemon).key(sid, key)

    def answer(self, sid, answers):
        return (self.ipc if self.via_ipc(sid) else self.daemon).answer(sid, answers)

    def close(self, sid):
        if self.via_ipc(sid):
            raise RuntimeError("Codex 桌面版、VS Code 扩展中的会话请在 Codex 中归档")
        return self.daemon.close(sid)

    def closable(self, snap):
        # 桌面版、VS Code 扩展的会话在它们自己的私有进程里，IPC 总线没有归档的请求，从外面改它的会话文件不安全：不给
        return not self.via_ipc(snap.get("sessionId") or "")

    def media(self, sid, ref, path):
        if ref.startswith(("f:", "o")):   # 手机发来的图、Kiteline 发的图：中台取
            return None
        if not path:
            raise RuntimeError("未知会话：%s" % sid)
        return codex_media(path, ref)


_OPENCODE_USAGE = {"db": None, "span": None, "parts": {}}
_OPENCODE_USAGE_LOCK = threading.Lock()


def opencode_db():
    """OpenCode 1.x 的数据库：各平台都在 $XDG_DATA_HOME/opencode 或 ~/.local/share/opencode（Windows 也是），OPENCODE_DB 可另指"""
    given = os.environ.get("OPENCODE_DB")
    if given:
        return given
    return os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.join(HOME, ".local", "share"), "opencode", "opencode.db")


def opencode_usage(since_ms, db_path=None):
    """OpenCode 每一步请求的用量在 part 表 type 为 step-finish 的那条（data.tokens、data.cost）：助手消息上的 tokens 只是最后一步的，
    不能用。tokens.input 不含缓存、output 不含推理（output + reasoning 才是模型的输出，和 Claude、Codex 的口径一样记进输出）；
    cost 是 OpenCode 按价目算的美元（走订阅的是 0）。只读打开；按 part id 记着，只补新的（和上次接上、重叠一分钟）"""
    path = db_path or opencode_db()
    if not os.path.isfile(path):
        return []
    now = _now_ms()
    with _OPENCODE_USAGE_LOCK:
        cache = _OPENCODE_USAGE
        if cache["db"] != path:
            cache.update(db=path, span=None, parts={})
        span, ranges = cache["span"], []
        if span is None or since_ms < span[0]:
            ranges.append((since_ms, span[0] if span else now + 1))
        if span is not None:
            ranges.append((span[1] - 60000, now + 1))
        try:
            db = sqlite3.connect("file:%s?mode=ro" % path.replace("\\", "/").replace("?", "%3f"), uri=True, timeout=2)
            try:
                for begin, end in ranges:
                    rows = db.execute("select p.id, p.time_created, p.data, m.data, s.directory from part p join message m on m.id = p.message_id "
                                      "left join session s on s.id = p.session_id "
                                      "where p.time_created >= ? and p.time_created < ? and p.data like '%step-finish%'", (begin, end))
                    for pid, created, data, message, directory in rows:
                        part, info = json.loads(data or "{}"), json.loads(message or "{}")
                        tokens = part.get("tokens") if isinstance(part.get("tokens"), dict) else None
                        if part.get("type") != "step-finish" or not tokens:
                            continue
                        cache_tokens = tokens.get("cache") if isinstance(tokens.get("cache"), dict) else {}
                        cost = part.get("cost")
                        cache["parts"][pid] = {"ts": int(created), "model": info.get("modelID") or "unknown",
                                               "cwd": directory or (info.get("path") or {}).get("cwd"), "session": part.get("sessionID"),
                                               "input": int(tokens.get("input") or 0),
                                               "output": int(tokens.get("output") or 0) + int(tokens.get("reasoning") or 0),
                                               "cacheRead": int(cache_tokens.get("read") or 0), "cacheWrite": int(cache_tokens.get("write") or 0),
                                               "requests": 1, "cost": float(cost) if isinstance(cost, (int, float)) else None}
                    span = (min(begin, span[0]), max(end, span[1])) if span else (begin, end)
                cache["span"] = span
            finally:
                db.close()
        except (sqlite3.Error, ValueError) as exc:
            log("读 OpenCode 用量出错：%r" % exc)
        return [r for r in cache["parts"].values() if r["ts"] >= since_ms]


class OpenCodePlugin(AgentPlugin):
    """OpenCode 进程里的 Kiteline 插件开桥（OpenCodeLink），对话没有落盘文件，靠桥推"""

    id, name = "opencode", "OpenCode"
    needs = ("locate", "install.file", "net.http", "net.sse", "proc", "db.read")
    limits_note = "OpenCode 未提供额度查询接口（OpenCode Go 订阅的用量只能在 OpenCode 网页控制台查看），「今日用量」中不显示"
    # 终端界面；Kiteline 自动往 OpenCode 里装一个桥接插件。Mac 10-23 实测；Windows / Linux 10-24 用 OpenCode 1.19.4 + 假模型实测 25/25
    support = {
        "mac": {"cli": support_form(verified=True)},
        "windows": {"cli": support_form(verified=True)},
        "linux": {"cli": support_form(verified=True)},
    }

    def usage(self, since_ms):
        """token 用量和花费：OpenCode 自己的数据库（见 opencode_usage）"""
        return opencode_usage(since_ms)

    def __init__(self):
        self.link = OpenCodeLink()

    def detect(self):
        return {"installed": opencode_installed(), "forms": {"cli": ""} if shutil.which("opencode") else {}}

    def disable(self):
        remove_opencode_plugin()

    def start(self):
        try:
            if OPENCODE_PLUGIN_ENABLED:
                install_opencode_plugin()
            else:
                remove_opencode_plugin()
        except Exception as exc:
            log("安装 / 删除 OpenCode 插件失败：%r" % exc)

    def sessions(self):
        return self.link.snapshots()

    def pump(self):
        return self.link.pump()

    def history(self, sid, before, limit):
        return self.link.owner(sid).history(sid, before, limit)

    def items(self, sid, limit):
        return opencode_items(self.link.owner(sid).messages(sid, limit))

    def send(self, sid, text, images):
        return self.link.owner(sid).send(sid, text, images)

    def key(self, sid, key):
        return self.link.owner(sid).key(sid, key)

    def answer(self, sid, answers):
        return self.link.owner(sid).answer(sid, answers)

    def close(self, sid):
        return self.link.owner(sid).close(sid)

    def closable(self, snap):
        # Windows 上没有能让它照常收尾的信号（强制结束会把终端留在它的界面状态里）
        return not IS_WINDOWS


DSH_USAGE_FILE = os.path.join(DATA_DIR, "dsh-usage.json")
DSH_USAGE_KEEP_MS = 92 * 86400000
_DSH_USAGE_LOCK = threading.Lock()


def dsh_usage(since_ms, home=None, ledger_path=None):
    """DSH 每个会话只在投影缓存里存累计用量（storages/session_projcache/sessions/<id>.json 的 tokenUsage.totals；
    逐次的明细在 zstd 压缩的会话日志里，Python 自带的库解不开）。这里记一本账：每个会话上次看到的累计值，涨了多少记一条，
    时间取它最后一条消息的时间——第一次看到的会话整段算在最后那天，之后按看到的增长分天。DSH 不记花费"""
    home = home or DSH_HOME
    path = ledger_path or DSH_USAGE_FILE
    folder = os.path.join(home, "storages", "session_projcache", "sessions")
    with _DSH_USAGE_LOCK:
        ledger = _read_json(path, {})
        seen, records = ledger.get("seen") or {}, ledger.get("records") or []
        changed = False
        try:
            names = os.listdir(folder)
        except OSError:
            names = []
        for name in names:
            file = os.path.join(folder, name)
            try:
                mtime = os.path.getmtime(file)
            except OSError:
                continue
            sid = name[:-5]
            if not name.endswith(".json") or (seen.get(sid) or {}).get("mtime") == mtime:
                continue
            record = (_read_json(file, {}).get("record") or {})
            rows = record.get("rows") if isinstance(record.get("rows"), dict) else {}
            value = lambda row: (rows.get(row) or {}).get("val") if isinstance(rows.get(row), dict) else None
            totals = (value("tokenUsage") or {}).get("totals") if isinstance(value("tokenUsage"), dict) else None
            if not isinstance(totals, dict):
                continue
            now = [int(totals.get(k) or 0) for k in ("uncachedInputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens")]
            steps = int((value("sessionStats") or {}).get("steps") or 0) if isinstance(value("sessionStats"), dict) else 0
            before = seen.get(sid) or {}
            last = before.get("totals") or [0, 0, 0, 0]
            delta = [max(0, a - b) for a, b in zip(now, last)]
            if any(delta):
                when = (value("timeContext") or {}).get("lastMessageTime") if isinstance(value("timeContext"), dict) else None
                selection = value("modelSelection") if isinstance(value("modelSelection"), dict) else {}
                records.append({"ts": int(when or mtime * 1000), "model": (selection.get("lastUsed") or {}).get("model") or "unknown",
                                "cwd": (record.get("identity") or {}).get("cwd"), "session": sid,
                                "input": delta[0], "output": delta[1], "cacheRead": delta[2], "cacheWrite": delta[3],
                                "requests": max(0, steps - int(before.get("steps") or 0)), "cost": None})
            seen[sid] = {"mtime": mtime, "totals": now, "steps": steps}
            changed = True
        if changed:
            cutoff = _now_ms() - DSH_USAGE_KEEP_MS
            records = [r for r in records if r.get("ts", 0) >= cutoff]
            try:
                _write_json(path, {"seen": seen, "records": records})
            except OSError as exc:
                log("记 DSH 用量出错：%r" % exc)
    return [r for r in records if r.get("ts", 0) + 3600000 > since_ms]


class DshPlugin(AgentPlugin):
    """DeepSeek Harness 的本机网页服务（DshLink），对话靠订阅推"""

    id, name = "deepseek-harness", "DeepSeek Harness"
    needs = ("proc", "secret.read", "net.http", "net.ws")
    limits_note = "DeepSeek 按量付费，没有周期额度：「今日用量」中显示 DeepSeek 账号余额（需在 DeepSeek Harness 中登录 DeepSeek 账号，使用 API Key 的不显示）"
    # 桌面版和命令行（dsh --profile web）是同一套网页服务；审批只有「允许这一次」。实测见 ccpulse-c1 10-24 的记录
    support = {
        "mac": {"desktop": support_form(verified=True), "cli": support_form()},
        "windows": {"desktop": support_form(verified=True), "cli": support_form()},
        "linux": {"desktop": support_form((), note="DeepSeek Harness 桌面版没有 Linux 版"), "cli": support_form(verified=True)},
    }
    # 它没有给第三方的接口，我们是读它的签名密钥自己签 cookie：用户知情、自己打开才接（10-24）
    opt_in = ("DeepSeek Harness 未提供第三方接入接口。开启后，Kiteline 将读取 DeepSeek Harness 保存在本机的连接密钥"
              "（其数据目录下 .credentials.yaml 中的 browser-session 一项，默认位于 ~/.dsh；文件中的其他内容不会读取），"
              "据此生成与 DeepSeek Harness 桌面窗口相同的访问凭证，连接其在本机（127.0.0.1）提供的服务，"
              "以查看会话、发送消息、审批命令和回答提问。密钥仅在本机使用，不会上传，也不会发送到手机。"
              "此接入方式并非 DeepSeek 官方提供，DeepSeek Harness 更新后可能失效。")

    def __init__(self):
        self.link = DshLink()

    def detect(self):
        return {"installed": os.path.isdir(DSH_HOME) or bool(shutil.which("dsh")), "forms": {}}

    def sessions(self):
        return self.link.snapshots()

    def pump(self):
        return self.link.pump()

    def history(self, sid, before, limit):
        return self.link.owner(sid).history(sid, before, limit)

    def media(self, sid, ref, path):
        return self.link.owner(sid).media(sid, ref) if ref.startswith("d") else None

    def send(self, sid, text, images):
        return self.link.owner(sid).send(sid, text, images)

    def key(self, sid, key):
        return self.link.owner(sid).key(sid, key)

    def answer(self, sid, answers):
        return self.link.owner(sid).answer(sid, answers)

    def close(self, sid):
        return self.link.owner(sid).close(sid)

    def usage(self, since_ms):
        """token 用量：DSH 投影缓存里各会话的累计值，按增长记（见 dsh_usage）；DSH 不记花费"""
        return dsh_usage(since_ms)

    def limits(self):
        """DeepSeek 按量付费，没有 5 小时 / 每周额度，给账号余额（连着的 DSH 里第一个登录了 DeepSeek 账号的）"""
        for host in list(self.link.hosts.values()):
            if host.connected:
                reading = host.balance()
                if reading:
                    return dict(reading, windows=[])
        return None

    def pending_options(self, snap):
        options = super().pending_options(snap)
        return options and [option for option in options if option["key"] != "2"]   # 审批只有「允许这一次」


def proma_usage_scan(path):
    """一个 Proma 会话的 token 用量：每轮结尾那条 result（Claude Agent SDK 的格式）带这一轮的 usage、花费 total_cost_usd，
    有 modelUsage 时按模型分（各带 costUSD）；模型名没给就用这一轮助手消息的"""
    buckets, model = {}, None
    try:
        handle = open(path, "rb")
    except OSError:
        return []
    with handle:
        for raw in handle:
            if b'"result"' not in raw and b'"model"' not in raw:
                continue
            entry = parse_line(raw)
            if not entry:
                continue
            if entry.get("type") == "assistant" and isinstance(entry.get("message"), dict):
                model = entry["message"].get("model") or model
                continue
            if entry.get("type") != "result":
                continue
            ts = entry.get("_createdAt") if isinstance(entry.get("_createdAt"), (int, float)) else parse_ts(entry.get("timestamp"))
            if not ts:
                continue
            requests = int(entry.get("num_turns") or 1)
            per_model = entry.get("modelUsage") if isinstance(entry.get("modelUsage"), dict) else {}
            if per_model:
                for name, info in per_model.items():
                    if isinstance(info, dict):
                        usage_bucket(buckets, int(ts), name, (info.get("inputTokens"), info.get("outputTokens"), info.get("cacheReadInputTokens"),
                                                               info.get("cacheCreationInputTokens"), requests if name == model or len(per_model) == 1 else 0),
                                      info.get("costUSD") if isinstance(info.get("costUSD"), (int, float)) else None)
                continue
            usage = entry.get("usage") if isinstance(entry.get("usage"), dict) else {}
            cost = entry.get("total_cost_usd")
            usage_bucket(buckets, int(ts), model or "unknown", (usage.get("input_tokens"), usage.get("output_tokens"), usage.get("cache_read_input_tokens"),
                                                                 usage.get("cache_creation_input_tokens"), requests),
                          cost if isinstance(cost, (int, float)) else None)
    return list(buckets.values())


class PromaPlugin(AgentPlugin):
    """Proma 落盘的会话文件（PromaLink），只读"""

    id, name = "proma", "Proma"
    needs = ("fs.read", "fs.tail", "proc")
    limits_note = "Proma 没有对外接口，额度和余额请在 Proma 所接的模型服务中查看，「今日用量」中不显示"
    normalize = staticmethod(normalize_proma_line)
    # 只有桌面版，没有任何对外接口：各平台都只读。Linux 真机实测；Mac / Windows 只验证过进程判断，桌面版没真跑
    support = {
        "mac": {"desktop": support_form(("view",))},
        "windows": {"desktop": support_form(("view",))},
        "linux": {"desktop": support_form(("view",), verified=True)},
    }
    read_only = "Proma 没有开放远程操作的接口，只能查看；回复和确认请在电脑上的 Proma 里操作"

    def __init__(self):
        self.link = PromaLink()

    def usage(self, since_ms):
        """token 用量和花费：Proma 每轮结尾记的（见 proma_usage_scan）；项目目录按它的会话索引算"""
        index = os.path.join(PROMA_HOME, "agent-sessions.json")
        metas = {m["id"]: m for m in ((_proma_json(index, self.link.cache) or {}).get("sessions") or []) if isinstance(m, dict) and m.get("id")}
        workspaces = {w.get("id"): w for w in ((_proma_json(os.path.join(PROMA_HOME, "agent-workspaces.json"), self.link.cache) or {})
                                               .get("workspaces") or []) if isinstance(w, dict)}
        out = []
        for path in recent_files([os.path.join(PROMA_HOME, "agent-sessions")], ".jsonl", since_ms):
            sid = os.path.basename(path)[:-6]
            meta = metas.get(sid)
            cwd = self.link.cwd(meta, workspaces) if meta else None
            out.extend(dict(r, cwd=cwd, session=sid) for r in cached_usage(path, proma_usage_scan) if r["ts"] + 3600000 > since_ms)
        return out

    def normalizer_for(self, path):
        """这个会话文件的规整函数：时间按 PromaClock 修成不倒退（见那里的说明）"""
        if not path:
            return self.normalize

        def normalize(offset, entry):
            clamped = PROMA_CLOCK.at(path, offset)
            if clamped is not None and isinstance(entry, dict):
                entry = dict(entry, _createdAt=clamped, timestamp=None)
            return normalize_proma_line(offset, entry)
        return normalize

    def detect(self):
        desktop = app_version("/Applications/Proma.app")
        return {"installed": os.path.isdir(PROMA_HOME) or bool(desktop), "forms": {"desktop": desktop} if desktop else {}}

    def sessions(self):
        return self.link.snapshots()


def builtin_plugins():
    return [CodexPlugin(), OpenCodePlugin(), DshPlugin(), PromaPlugin()]


# --- 外部插件：Kiteline 电脑端下载、校验好放在这里，每家一个目录（plugin.json + plugin.py + assets/）---
# plugin.py 里的 create(kl) 返回一个 AgentPlugin，kl 就是本文件（中台能力、内置插件的类都能直接用）。
# 同 id 的外部插件版本比内置的新才顶替它；出错太多次就停用、换回内置的（电脑端收到 plugin_retired 再把文件退回上一版）。

PLUGINS_DIR = os.environ.get("CCPULSE_PLUGINS_DIR") or os.path.join(DATA_DIR, "plugins")
# 用户在设置里关掉的插件（电脑端启动 watcher 时带上，逗号分隔）
PLUGINS_OFF = set(filter(None, (os.environ.get("CCPULSE_PLUGINS_OFF") or "").split(",")))
# 默认不接（opt_in）、用户在设置里自己打开了的插件（同上）
PLUGINS_ON = set(filter(None, (os.environ.get("CCPULSE_PLUGINS_ON") or "").split(",")))
# 用户打开了的插件单项开关：「插件 id.开关 id」（见 HOST_CAPS 的 plugin.options）
PLUGIN_OPTIONS_ON = set(filter(None, (os.environ.get("CCPULSE_PLUGIN_OPTIONS_ON") or "").split(",")))
PLUGIN_FAIL_LIMIT = 5   # 外部插件连续这么多轮出错就停用


def load_external_plugins(root=None):
    """→ (插件列表, 加载不了的 [{id, version, error}])"""
    root = root or PLUGINS_DIR
    plugins, broken = [], []
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return plugins, broken
    for name in names:
        folder = os.path.join(root, name)
        if name.startswith(".") or not os.path.isfile(os.path.join(folder, "plugin.json")):
            continue
        manifest = {}
        try:
            manifest = json.loads(read_text(os.path.join(folder, "plugin.json")) or "")
            if manifest.get("kind") == "skills":
                continue   # 技能包只有数据，装技能时读（skills_data），不是 agent 插件
            if manifest.get("id") != name:
                raise ValueError("清单里的 id（%s）和目录名不一致" % manifest.get("id"))
            spec = importlib.util.spec_from_file_location("kl_plugin_" + re.sub(r"\W", "_", name), os.path.join(folder, "plugin.py"))
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            # 作为脚本跑时本文件就是 __main__；被别的程序按文件载入（测试）时不在 sys.modules 里，给一份全局名字的副本
            plugin = module.create(sys.modules.get(__name__) or types.SimpleNamespace(**globals()))
            if not isinstance(plugin, AgentPlugin):
                raise TypeError("create() 返回的不是插件")
            plugin.id = name
            plugin.name = manifest.get("name") or plugin.name or name
            plugin.version = str(manifest.get("version") or "0")
            plugin.needs = tuple(manifest.get("needs") or plugin.needs)
            plugin.support = manifest.get("support") or plugin.support
            for field in ("caps", "mark", "speaker"):   # 清单里写了就以清单为准（插件代码里也可以写在类上）
                if manifest.get(field):
                    setattr(plugin, field, manifest[field])
            if isinstance(manifest.get("minApp"), dict):
                plugin.min_app = manifest["minApp"]
            if manifest.get("optIn"):
                plugin.opt_in, plugin.opt_in_en = str(manifest["optIn"]), manifest.get("optInEn") or plugin.opt_in_en
            if manifest.get("limitsNote"):
                plugin.limits_note, plugin.limits_note_en = str(manifest["limitsNote"]), manifest.get("limitsNoteEn") or None
            if isinstance(manifest.get("gaps"), list):
                plugin.gaps = tuple(g for g in manifest["gaps"] if isinstance(g, dict) and g.get("text")
                                    and g.get("kind") in ("unsupported", "untested"))
            if isinstance(manifest.get("options"), list):
                plugin.options = tuple(o for o in manifest["options"] if isinstance(o, dict) and o.get("id") and o.get("name"))
            plugin.source = "external"
            plugin.folder = folder
            plugins.append(plugin)
        except Exception as exc:
            broken.append({"id": name, "name": manifest.get("name") or name, "version": str(manifest.get("version") or ""),
                           "source": "external", "status": "error", "error": "%s: %s" % (type(exc).__name__, exc)})
            log("外部插件 %s 加载失败：%r" % (name, exc))
    return plugins, broken


class AgentPlugins:
    """启用的插件：主循环统一调，按 agent 找插件；单个插件出错只影响它自己"""

    def __init__(self, plugins=None, external=None, off=None, on=None):
        """plugins：内置插件（默认全部）；external：外部插件（默认从 PLUGINS_DIR 读，传了 plugins 就不读）；off：关掉的 id；
        on：默认不接（opt_in）的插件里用户打开了的 id"""
        builtin = builtin_plugins() if plugins is None else list(plugins)
        if external is None:
            external, self.broken = load_external_plugins() if plugins is None else ([], [])
        else:
            self.broken = []
        self.wanted_off = PLUGINS_OFF if off is None else set(off)
        self.wanted_on = PLUGINS_ON if on is None else set(on)
        self.fallback = {}      # id → 被外部插件顶替下来的内置插件（外部的停用时换回来）
        self.status = {}        # id → 设置页上显示的状态（ok / off / incompatible / retired）和原因
        self.failures = {}      # id → 连续出错的轮数
        self.reported = set()   # 已经报给电脑端的错（同一个错只报一次）
        chosen = {plugin.id: plugin for plugin in builtin}
        for plugin in external:
            current = chosen.get(plugin.id)
            if current is not None and version_tuple(plugin.version) <= version_tuple(current.version):
                log("外部插件 %s %s 不比内置的 %s 新，不用" % (plugin.id, plugin.version, current.version))
                continue
            if current is not None:
                self.fallback[plugin.id] = current
            chosen[plugin.id] = plugin
        self.all, self.off = [], []
        for plugin in chosen.values():
            missing = [cap for cap in plugin.needs if cap not in HOST_CAPS]
            if missing and plugin.id in self.fallback:
                log("外部插件 %s 用到的中台能力还没有（%s），先用内置的" % (plugin.id, ", ".join(missing)))
                self.status[plugin.id] = {"status": "incompatible", "missing": missing, "wanted": plugin.version}
                plugin = self.fallback.pop(plugin.id)
                missing = []
            if missing:
                log("插件 %s 用到的中台能力还没有（%s），不启用" % (plugin.id, ", ".join(missing)))
                self.status[plugin.id] = {"status": "incompatible", "missing": missing}
                self.off.append(plugin)
            elif not self.wanted(plugin):
                self.status.setdefault(plugin.id, {"status": "off"})
                self.off.append(plugin)
            else:
                self.all.append(plugin)
        self.by_id = {plugin.id: plugin for plugin in self.all}

    def wanted(self, plugin):
        """用户要不要接这家：没在设置里关掉，而且默认不接的（opt_in）是用户自己打开了的"""
        return plugin.id not in self.wanted_off and (not plugin.opt_in or plugin.id in self.wanted_on)

    def get(self, agent):
        return self.by_id.get(agent)

    def start(self):
        for plugin in self.off:
            if self.status.get(plugin.id, {}).get("status") == "off":
                try:
                    plugin.disable()
                except Exception as exc:
                    log("插件 %s 还原出错：%r" % (plugin.id, exc))
        for plugin in list(self.all):
            try:
                plugin.start()
            except Exception as exc:
                self.failed(plugin, "start", exc)

    def sessions(self):
        out = []
        for plugin in list(self.all):
            try:
                out.extend(plugin.standardize(snap) for snap in plugin.sessions())
                self.failures[plugin.id] = 0
            except Exception as exc:
                self.failed(plugin, "sessions", exc)
        return out

    def pump(self):
        out = []
        for plugin in list(self.all):
            try:
                out.extend(plugin.pump())
            except Exception as exc:
                self.failed(plugin, "pump", exc)
        return out

    def limits(self):
        """各插件报的额度 / 余额（read_limits 用）：没有窗口也没有余额的不算；读不到只记日志，不算插件出错"""
        out = []
        for plugin in list(self.all):
            if type(plugin).limits is AgentPlugin.limits:
                continue
            try:
                item = plugin.limits()
            except Exception as exc:
                log("插件 %s 读额度出错：%r" % (plugin.id, exc))
                continue
            if isinstance(item, dict) and (item.get("windows") or item.get("balances")):
                out.append(dict(item, agent=plugin.id, windows=list(item.get("windows") or [])))
        return out

    def usage(self, since_ms):
        """各插件报的 token 用量（usage_report 用）：[(插件, 记录)]；读不到只记日志，不算插件出错"""
        out = []
        for plugin in list(self.all):
            if type(plugin).usage is AgentPlugin.usage:
                continue
            try:
                records = [r for r in plugin.usage(since_ms) or [] if isinstance(r, dict) and isinstance(r.get("ts"), (int, float))]
            except Exception as exc:
                log("插件 %s 读用量出错：%r" % (plugin.id, exc))
                continue
            if records:
                out.append((plugin, records))
        return out

    def failed(self, plugin, where, exc):
        """插件自己出错（不是「会话已关」这类正常的操作失败）：记日志；同一个错报一次给电脑端（弹窗问用户要不要报告）；
        外部插件连续出错太多就停用、换回内置的"""
        text = "%s: %s" % (type(exc).__name__, exc)
        log("插件 %s（%s）%s 出错：%s" % (plugin.id, plugin.version, where, text))
        self.failures[plugin.id] = self.failures.get(plugin.id, 0) + 1
        key = (plugin.id, plugin.version, where, text[:160])
        if key not in self.reported:
            self.reported.add(key)
            emit({"event": "plugin_error", "id": plugin.id, "name": plugin.name, "version": plugin.version,
                  "source": plugin.source, "where": where, "error": text[:500], "trace": traceback.format_exc()[-2000:]})
        if plugin.source == "external" and self.failures[plugin.id] >= PLUGIN_FAIL_LIMIT:
            self.retire(plugin, text)

    def retire(self, plugin, reason):
        """停用出错的外部插件，有内置的就换回内置的"""
        if plugin in self.all:
            self.all.remove(plugin)
        self.off.append(plugin)
        self.status[plugin.id] = {"status": "retired", "error": reason[:500], "wanted": plugin.version}
        self.failures[plugin.id] = 0
        builtin = self.fallback.pop(plugin.id, None)
        swapped = builtin is not None and self.wanted(builtin)   # 内置的是默认不接、用户没打开的：只停用，不换上
        if swapped:
            self.all.append(builtin)
            try:
                builtin.start()
            except Exception as exc:
                log("换回内置插件 %s 时出错：%r" % (plugin.id, exc))
        self.by_id = {p.id: p for p in self.all}
        log("外部插件 %s %s 连续出错，已停用%s" % (plugin.id, plugin.version, "，换回内置版本" if swapped else ""))
        emit({"event": "plugin_retired", "id": plugin.id, "version": plugin.version, "error": reason[:500],
              "fallback": builtin.version if builtin else None})

    def describe(self):
        """设置页用：每个插件的版本、来源、能力、状态，以及本机装没装这家 agent"""
        out, seen = [], set()
        for plugin in self.all + self.off:   # 停用后换回内置的：同一个 id 只列在用的那个
            if plugin.id in seen:
                continue
            seen.add(plugin.id)
            try:
                detect = plugin.detect()
            except Exception as exc:
                detect = {"error": repr(exc)}
            row = {"id": plugin.id, "name": plugin.name, "version": plugin.version, "source": plugin.source,
                   "needs": list(plugin.needs), "abilities": plugin.abilities(), "support": plugin.support,
                   "detect": detect, "status": "ok", "caps": list(plugin.caps)}
            if plugin.mark:
                row["mark"] = plugin.mark
            if plugin.speaker:
                row["speaker"] = plugin.speaker
            if plugin.min_app:
                row["minApp"] = plugin.min_app
            if plugin.opt_in:
                row["optIn"] = plugin.opt_in
                if plugin.opt_in_en:
                    row["optInEn"] = plugin.opt_in_en
            if plugin.options:
                row["options"] = [dict(option, on=plugin.option_on(option["id"])) for option in plugin.options]
            if plugin.limits_note:
                row["limitsNote"] = plugin.limits_note
                if plugin.limits_note_en:
                    row["limitsNoteEn"] = plugin.limits_note_en
            if plugin.gaps:
                row["gaps"] = [dict(g) for g in plugin.gaps]
            row.update(self.status.get(plugin.id) or {})
            out.append(row)
        return out + list(self.broken)

    def handle(self, agent, request):
        """手机上对别家 agent 会话的操作：发消息、按键（审批、中断）、回答提问、关闭会话"""
        plugin = self.by_id.get(agent)
        if plugin is None:
            raise RuntimeError("不支持的 agent：%s" % agent)
        cmd = request.get("cmd")
        sid = str(request.get("sessionId") or "")
        if cmd == "agent_send":
            images = [p for p in (request.get("images") or []) if isinstance(p, str)]
            plugin.host_ui = tuple(str(x) for x in request.get("ui") or () if isinstance(x, str))
            try:
                result = plugin.send(sid, (request.get("text") or "").strip(), images)
            finally:
                plugin.host_ui = ()
            # 插件回了动作单（{"message", "ui": [...]}）：原样交给电脑端执行
            return result if isinstance(result, dict) else {"message": result}
        if cmd == "agent_key":
            key = str(request.get("key") or "").lower()
            return {"message": plugin.key(sid, {"escape": "esc", "return": "enter"}.get(key, key))}
        if cmd == "agent_answer":
            return {"message": plugin.answer(sid, request.get("answers") or [])}
        if cmd == "agent_close":
            return {"message": plugin.close(sid)}
        if cmd == "agent_ui":
            # 电脑端执行动作单到 {"do": "plugin"} 这一步：回头请插件做（见 HOST_CAPS 的 ui.keys）
            return {"message": plugin.ui_step(sid, str(request.get("step") or ""))}
        raise RuntimeError("未知请求：%s" % cmd)


DEFERRED = object()   # handle() 返回它：这个请求在后台线程里回（见 Watcher.defer）
_SVG_LOCK = threading.Lock()   # 旧 SVG 图现转 PNG（Watcher.media_svg）一次只转一张
_IDE_JOBS = {}        # 任务号 -> 进度 / 结果（慢的 Git 操作，见 Watcher.defer）


# ---------------------------------------------------------------------------
# 终端：会话里开的终端，开在会话所在的机器上（Remote-SSH 的会话就是那台服务器），目录是会话的工作目录。
# 伪终端（Unix pty / Windows ConPTY）里跑用户的 shell；输出攒一小段就推 term 事件（data 是 base64，seq 是这段在整条输出里的字节位置），
# 每个终端留最近 TERM_BUFFER 字节，手机重新打开时 term read 一次把画面接上。watcher 退出时终端跟着结束
# ---------------------------------------------------------------------------

TERM_BUFFER = 256 * 1024
TERM_PER_SESSION = 8
TERM_TOTAL = 32
TERM_RATE = 512 * 1024   # 每秒最多推这么多：输出再快就先不读，让程序在伪终端上等着（同真终端被拖慢），免得把手机的连接灌满


class Term:
    def __init__(self, tid, session_id, cwd, cols, rows):
        self.id, self.session_id, self.cwd = tid, session_id, cwd
        self.cols, self.rows = cols, rows
        self.created = time.time()
        self.buffer = bytearray()
        self.end = 0              # 一共输出了多少字节（buffer 是最后那段）
        self.lock = threading.Lock()
        self.exit_code = None
        self.shell = ""
        self.proc = None
        self.fd = None            # Unix：伪终端主端
        self.win = None           # Windows：ConPTY 句柄们

    def info(self):
        return {"term": self.id, "sessionId": self.session_id, "cwd": self.cwd, "shell": os.path.basename(self.shell),
                "cols": self.cols, "rows": self.rows, "createdAt": int(self.created * 1000), "end": self.end}

    # --- 启动 ---

    def start(self):
        if IS_WINDOWS:
            self._start_windows()
        else:
            self._start_unix()
        threading.Thread(target=self._pump, name="term-%s" % self.id, daemon=True).start()

    def _env(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith("CCPULSE_")}
        env.update({"TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "Kiteline"})
        if not IS_WINDOWS and "UTF-8" not in (env.get("LC_ALL") or env.get("LC_CTYPE") or env.get("LANG") or "").upper().replace("UTF8", "UTF-8"):
            env["LANG"] = "en_US.UTF-8" if sys.platform == "darwin" else "C.UTF-8"   # 不然中文文件名、输出是乱码
        return env

    def _start_unix(self):
        import fcntl
        import pty
        import termios
        shell = os.environ.get("SHELL") or ""
        if not shell or not os.path.exists(shell):
            try:
                import pwd
                shell = pwd.getpwuid(os.getuid()).pw_shell
            except (ImportError, KeyError):
                shell = "/bin/sh"
        self.shell = shell
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", self.rows, self.cols, 0, 0))

        def child():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)   # 伪终端当它的控制终端：Ctrl+C、作业控制才管用
            # watcher 常是被「忽略 Ctrl+C」地拉起来的（后台启动、nohup）：忽略会一路传给 shell 和里面的程序，Ctrl+C 停不下来
            for sig in (signal.SIGINT, signal.SIGQUIT, signal.SIGHUP, signal.SIGTSTP, signal.SIGTTIN, signal.SIGTTOU, signal.SIGPIPE):
                signal.signal(sig, signal.SIG_DFL)

        # 登录 shell：读 .profile / .zprofile，PATH、conda 这些和自己开终端时一样（watcher 是 ssh 非交互起的，环境不全）
        self.proc = subprocess.Popen([shell, "-l"], stdin=slave, stdout=slave, stderr=slave, cwd=self.cwd, env=self._env(),
                                     preexec_fn=child, close_fds=True)
        os.close(slave)
        self.fd = master

    def _start_windows(self):
        import ctypes
        from ctypes import wintypes
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)

        class COORD(ctypes.Structure):
            _fields_ = [("X", ctypes.c_short), ("Y", ctypes.c_short)]

        class STARTUPINFOW(ctypes.Structure):
            _fields_ = [("cb", wintypes.DWORD), ("lpReserved", wintypes.LPWSTR), ("lpDesktop", wintypes.LPWSTR), ("lpTitle", wintypes.LPWSTR),
                        ("dwX", wintypes.DWORD), ("dwY", wintypes.DWORD), ("dwXSize", wintypes.DWORD), ("dwYSize", wintypes.DWORD),
                        ("dwXCountChars", wintypes.DWORD), ("dwYCountChars", wintypes.DWORD), ("dwFillAttribute", wintypes.DWORD),
                        ("dwFlags", wintypes.DWORD), ("wShowWindow", wintypes.WORD), ("cbReserved2", wintypes.WORD),
                        ("lpReserved2", ctypes.c_void_p), ("hStdInput", wintypes.HANDLE), ("hStdOutput", wintypes.HANDLE), ("hStdError", wintypes.HANDLE)]

        class STARTUPINFOEXW(ctypes.Structure):
            _fields_ = [("StartupInfo", STARTUPINFOW), ("lpAttributeList", ctypes.c_void_p)]

        class PROCESS_INFORMATION(ctypes.Structure):
            _fields_ = [("hProcess", wintypes.HANDLE), ("hThread", wintypes.HANDLE), ("dwProcessId", wintypes.DWORD), ("dwThreadId", wintypes.DWORD)]

        k32.CreatePseudoConsole.argtypes = [COORD, wintypes.HANDLE, wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(ctypes.c_void_p)]
        k32.CreatePseudoConsole.restype = ctypes.c_long
        k32.ResizePseudoConsole.argtypes = [ctypes.c_void_p, COORD]
        k32.ClosePseudoConsole.argtypes = [ctypes.c_void_p]
        k32.UpdateProcThreadAttribute.argtypes = [ctypes.c_void_p, wintypes.DWORD, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t,
                                                  ctypes.c_void_p, ctypes.c_void_p]
        k32.InitializeProcThreadAttributeList.argtypes = [ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, ctypes.POINTER(ctypes.c_size_t)]
        k32.CreateProcessW.argtypes = [wintypes.LPCWSTR, wintypes.LPWSTR, ctypes.c_void_p, ctypes.c_void_p, wintypes.BOOL, wintypes.DWORD,
                                       ctypes.c_void_p, wintypes.LPCWSTR, ctypes.c_void_p, ctypes.c_void_p]
        k32.ReadFile.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
        k32.PeekNamedPipe.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD, ctypes.c_void_p, ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
        k32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        k32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        k32.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
        k32.CloseHandle.argtypes = [wintypes.HANDLE]
        k32.WriteFile.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]

        def pipe():
            read, write = wintypes.HANDLE(), wintypes.HANDLE()
            if not k32.CreatePipe(ctypes.byref(read), ctypes.byref(write), None, 0):
                raise OSError("CreatePipe 失败：%d" % ctypes.get_last_error())
            return read, write

        in_read, in_write = pipe()
        out_read, out_write = pipe()
        hpc = ctypes.c_void_p()
        hr = k32.CreatePseudoConsole(COORD(self.cols, self.rows), in_read, out_write, 0, ctypes.byref(hpc))
        if hr != 0:
            raise OSError("这台电脑不支持伪终端（需要 Windows 10 1809 或更新）：%#x" % (hr & 0xFFFFFFFF))
        k32.CloseHandle(in_read)
        k32.CloseHandle(out_write)
        size = ctypes.c_size_t()
        k32.InitializeProcThreadAttributeList(None, 1, 0, ctypes.byref(size))
        attrs = ctypes.create_string_buffer(size.value)
        if not k32.InitializeProcThreadAttributeList(attrs, 1, 0, ctypes.byref(size)):
            raise OSError("InitializeProcThreadAttributeList 失败：%d" % ctypes.get_last_error())
        if not k32.UpdateProcThreadAttribute(attrs, 0, 0x00020016, hpc, ctypes.sizeof(ctypes.c_void_p), None, None):   # PSEUDOCONSOLE
            raise OSError("UpdateProcThreadAttribute 失败：%d" % ctypes.get_last_error())
        info = STARTUPINFOEXW()
        info.StartupInfo.cb = ctypes.sizeof(STARTUPINFOEXW)
        # watcher 自己的标准输入输出是管道：不写这个的话 shell 会继承这几个管道，输出跑到 watcher 的 stdout 里去
        info.StartupInfo.dwFlags = 0x00000100   # STARTF_USESTDHANDLES（句柄留空）
        info.lpAttributeList = ctypes.cast(attrs, ctypes.c_void_p)
        shell = shutil.which("pwsh.exe") or shutil.which("powershell.exe") or os.environ.get("COMSPEC") or "cmd.exe"
        self.shell = shell
        command = ctypes.create_unicode_buffer('"%s"%s' % (shell, " -NoLogo" if "powershell" in shell.lower() or "pwsh" in shell.lower() else ""))
        env = "".join("%s=%s\0" % kv for kv in sorted(self._env().items(), key=lambda kv: kv[0].upper())) + "\0"
        env_block = ctypes.create_unicode_buffer(env)
        process = PROCESS_INFORMATION()
        # 「不理 Ctrl+C」会传给子进程：watcher 多半是这样被拉起来的（电脑端、ssh），shell 跟着不理，终端里 Ctrl+C 停不下程序。
        # 开 shell 前先恢复，开完再不理（watcher 自己本来就不该被 Ctrl+C 打断）
        k32.SetConsoleCtrlHandler(None, False)
        try:
            created = k32.CreateProcessW(None, command, None, None, False, 0x00080000 | 0x00000400, env_block, self.cwd,   # EXTENDED_STARTUPINFO | UNICODE_ENVIRONMENT
                                         ctypes.byref(info), ctypes.byref(process))
        finally:
            k32.SetConsoleCtrlHandler(None, True)
        if not created:
            raise OSError("启动 %s 失败：%d" % (shell, ctypes.get_last_error()))
        k32.CloseHandle(process.hThread)
        self.win = {"k32": k32, "hpc": hpc, "in": in_write, "out": out_read, "process": process.hProcess,
                    "COORD": COORD, "attrs": attrs, "wintypes": wintypes, "ctypes": ctypes}

        def watch_exit():
            # shell 退出后伪终端还开着、输出管道不会自己断：等它退出再关伪终端，读输出那边才读到结尾。
            # ClosePseudoConsole 在输出没读完时会等，所以放在这个线程里，读输出的线程照常读完
            k32.WaitForSingleObject(process.hProcess, 0xFFFFFFFF)
            k32.ClosePseudoConsole(hpc)

        threading.Thread(target=watch_exit, name="term-exit-%s" % self.id, daemon=True).start()

    # --- 读写 ---

    def _read(self):
        """读一段输出（b"" = 结束了）"""
        if self.win:
            w = self.win
            buf = w["ctypes"].create_string_buffer(65536)
            got = w["wintypes"].DWORD()
            if not w["k32"].ReadFile(w["out"], buf, 65536, w["ctypes"].byref(got), None) or not got.value:
                return b""
            return buf.raw[:got.value]
        try:
            return os.read(self.fd, 65536)
        except OSError:   # EIO：shell 退出、从端全关了
            return b""

    def _more(self):
        """紧接着还有没有输出（攒成一段再推）"""
        if self.win:
            w = self.win
            avail = w["wintypes"].DWORD()
            w["k32"].PeekNamedPipe(w["out"], None, 0, None, w["ctypes"].byref(avail), None)
            return avail.value > 0
        import select
        try:
            return bool(select.select([self.fd], [], [], 0.012)[0])
        except (OSError, ValueError):
            return False

    def _pump(self):
        sent, window = 0, time.time()
        while True:
            chunk = self._read()
            if not chunk:
                break
            while len(chunk) < 128 * 1024 and self._more():
                more = self._read()
                if not more:
                    break
                chunk += more
            with self.lock:
                seq = self.end
                self.buffer += chunk
                if len(self.buffer) > TERM_BUFFER:
                    del self.buffer[:len(self.buffer) - TERM_BUFFER]
                self.end += len(chunk)
            try:
                emit({"event": "term", "term": self.id, "sessionId": self.session_id, "seq": seq,
                      "data": base64.b64encode(chunk).decode("ascii")})
            except Exception:
                pass
            sent += len(chunk)
            now = time.time()
            if now - window >= 1.0:
                sent, window = 0, now
            elif sent > TERM_RATE:
                time.sleep(1.0 - (now - window))
                sent, window = 0, time.time()
        self.exit_code = self._wait()
        TERMS.gone(self)

    def _wait(self):
        if self.win:
            w = self.win
            w["k32"].WaitForSingleObject(w["process"], 3000)
            code = w["wintypes"].DWORD()
            w["k32"].GetExitCodeProcess(w["process"], w["ctypes"].byref(code))
            for handle in ("in", "out", "process"):
                w["k32"].CloseHandle(w[handle])
            return code.value
        try:
            os.close(self.fd)
        except OSError:
            pass
        try:
            return self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            return None

    def write(self, data):
        if self.exit_code is not None:
            raise RuntimeError("终端已结束")
        while data:
            if self.win:
                w = self.win
                done = w["wintypes"].DWORD()
                if not w["k32"].WriteFile(w["in"], data, len(data), w["ctypes"].byref(done), None):
                    raise RuntimeError("写入终端失败")
                written = done.value
            else:
                written = os.write(self.fd, data)
            data = data[written:]

    def resize(self, cols, rows):
        self.cols, self.rows = cols, rows
        if self.win:
            self.win["k32"].ResizePseudoConsole(self.win["hpc"], self.win["COORD"](cols, rows))
            return
        import fcntl
        import termios
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        try:
            os.killpg(self.proc.pid, signal.SIGWINCH)
        except OSError:
            pass

    def close(self):
        if self.win:
            # 进程一结束，watch_exit 关伪终端、读输出那边读到结尾，收尾同自己退出
            self.win["k32"].TerminateProcess(self.win["process"], 1)
            return
        for sig in (signal.SIGHUP, signal.SIGKILL):
            try:
                os.killpg(self.proc.pid, sig)
            except OSError:
                return
            try:
                self.proc.wait(timeout=1.5)
                return
            except subprocess.TimeoutExpired:
                continue

    def tail(self):
        with self.lock:
            return self.end - len(self.buffer), bytes(self.buffer)


class Terminals:
    def __init__(self):
        self.terms = {}
        self.lock = threading.Lock()

    def count(self, session_id):
        return sum(1 for t in self.terms.values() if t.session_id == session_id)

    def annotate(self, snapshots):
        """会话快照带上开着几个终端（手机上终端按钮的角标）"""
        for snap in snapshots:
            n = self.count(snap.get("sessionId"))
            if n:
                snap["terminals"] = n

    def gone(self, term):
        with self.lock:
            self.terms.pop(term.id, None)
        log("终端 %s 结束了（%s）" % (term.id, term.exit_code))
        try:
            emit({"event": "term_exit", "term": term.id, "sessionId": term.session_id, "code": term.exit_code})
        except Exception:
            pass

    def get(self, tid):
        term = self.terms.get(tid or "")
        if not term:
            raise RuntimeError("终端已关闭")
        return term

    def handle(self, request, cwd):
        op = request.get("op") or "list"
        session_id = request.get("sessionId") or ""
        if op == "list":
            terms = [t for t in self.terms.values() if not session_id or t.session_id == session_id]
            return {"terms": [t.info() for t in sorted(terms, key=lambda t: t.created)]}
        if op == "open":
            if self.count(session_id) >= TERM_PER_SESSION or len(self.terms) >= TERM_TOTAL:
                raise RuntimeError("这个会话已开了 %d 个终端，请先关掉不用的" % self.count(session_id))
            if not cwd or not os.path.isdir(cwd):
                cwd = HOME
            cols = max(20, min(int(request.get("cols") or 80), 500))
            rows = max(5, min(int(request.get("rows") or 24), 300))
            term = Term("k-" + uuid.uuid4().hex[:10], session_id, cwd, cols, rows)
            term.start()
            with self.lock:
                self.terms[term.id] = term
            log("开了终端 %s（%s）：%s" % (term.id, term.shell, cwd))
            return {"term": term.info()}
        term = self.get(request.get("term"))
        if op == "read":
            start, data = term.tail()
            return {"term": term.info(), "seq": start, "data": base64.b64encode(data).decode("ascii")}
        if op == "input":
            data = request.get("data")
            raw = base64.b64decode(data) if request.get("base64") else (data or "").encode("utf-8")
            term.write(raw)
            return {}
        if op == "resize":
            term.resize(max(20, min(int(request.get("cols") or 80), 500)), max(5, min(int(request.get("rows") or 24), 300)))
            return {}
        if op == "close":
            term.close()
            return {}
        raise RuntimeError("未知的终端操作：%s" % op)


TERMS = Terminals()


# ---------------------------------------------------------------------------
# 托管会话：不开 VS Code，在这台电脑上后台跑交互式 claude（Remote-SSH 的项目新任务、恢复会话默认走这条）。
# watcher 起一个脱离自己的守护进程（本脚本的 hold 子命令），它在伪终端里跑 claude 并一直拿着：watcher 退出、SSH 断开、
# 电脑端休眠都不影响，claude 退出它才退出。守护进程在 HOSTED_DIR 放 <id>.json（登记：守护进程和 claude 的 pid、会话 id、
# 目录、就绪没有）和 <id>.sock（Unix 套接字，一次连接一个 JSON 请求，见 HostedHolder.handle）；退出时留 <id>.end（退出码和最后的画面）。
# 跑的是用户自己装的 claude（没装命令行版就用 VS Code 扩展自带的那份），交互式、用用户自己的登录，等于用户在终端里敲 claude：
# 不用 -p / SDK 这类程序化调用，不碰凭证。发消息、按键：电脑端先走会话里的 mod 收件箱（bridge），不行再走 tmux_send →
# 往这个伪终端里粘贴 + 回车。会话终端里多一个「claude」终端（HostedTerm），接的就是这个伪终端，Claude 原来的界面能看能操作。
# 只做 Unix；Windows 上 hosted_start 报 HOSTED_UNSUPPORTED，电脑端照旧开 VS Code
# ---------------------------------------------------------------------------

HOSTED_DIR = os.path.join(DATA_DIR, "hosted")
HOSTED_BUFFER = 256 * 1024
# claude 起来（出现在会话登记里）最多等这么久：慢机器、刚装好要初始化时十几秒（CCPULSE_HOSTED_READY 给测试缩短）
HOSTED_READY_SECONDS = float(os.environ.get("CCPULSE_HOSTED_READY") or 45)
HOSTED_KEYS = {"enter": b"\r", "esc": b"\x1b", "escape": b"\x1b", "up": b"\x1b[A", "down": b"\x1b[B", "tab": b"\t",
               "shift+tab": b"\x1b[Z", "1": b"1", "2": b"2", "3": b"3", "4": b"4", "y": b"y", "n": b"n"}
HOSTED_ENV_DROP = {"CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_AGENT_SDK_VERSION", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT",
                   "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_EXECPATH",
                   "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_EMIT_STARTUP_TIMING",
                   "CLAUDE_CODE_STARTUP_FAILURE_RESULTS", "CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING", "CLAUDE_CODE_QUESTION_PREVIEW_FORMAT",
                   "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TMUX", "TMUX_PANE", "GIT_ASKPASS"}
if not IS_WINDOWS:
    FEATURES.append("hosted")

_SCREEN_CODES = re.compile(rb"\x1b\[[0-9;?<>=]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[=>()][0-9A-Za-z]?|\x1b[@-_]|[\x00-\x08\x0b-\x1f\x7f]")


def screen_text(data):
    """伪终端输出 → 去掉控制序列和空白的小写字，认启动时停在哪个画面用（Ink 靠挪光标排版，空格多半是光标移动，所以连空白一起去掉）"""
    return re.sub(r"\s+", "", _SCREEN_CODES.sub(b"", data).decode("utf-8", "replace")).lower()


def screen_excerpt(data, limit=400):
    """给用户看的最后一屏文字（报「没启动起来」时带上）：光标右移当空格、挪到别的行当换行，其余控制序列去掉"""
    data = re.sub(rb"\x1b\[\d*C", b" ", data)
    data = re.sub(rb"\x1b\[[\d;]*[ABEFHJKf]", b"\n", data).replace(b"\r", b"\n")
    lines = []
    for line in _SCREEN_CODES.sub(b"", data).decode("utf-8", "replace").split("\n"):
        line = " ".join(line.split())
        if line.strip(" ─━╌-·*✻✶✢✽❯") and (not lines or lines[-1] != line):
            lines.append(line)
    return "\n".join(lines)[-limit:]


def claude_command():
    """后台跑 claude 用哪个可执行文件：登录 shell 里的 claude（同用户自己开终端）、原生安装、npm 全局的位置；
    都没有就用 VS Code 扩展自带的那份（只在 Remote-SSH 里用过 Claude Code 的服务器也能跑）。找不到返回 None"""
    override = os.environ.get("CCPULSE_CLAUDE")   # 测试用：指定一个假的 claude
    if override:
        return override if os.path.isfile(override) else None
    found = shutil.which("claude")
    if not found and not IS_WINDOWS:
        try:
            out = subprocess.run(login_shell_command(["sh", "-c", "command -v claude"]), stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, timeout=15)
            for line in reversed(out.stdout.decode("utf-8", "replace").splitlines()):
                if line.startswith("/") and os.access(line.strip(), os.X_OK):
                    found = line.strip()
                    break
        except Exception:
            pass
    if found:
        return found
    for path in (os.path.join(HOME, ".local", "bin", "claude"), os.path.join(HOME, ".claude", "local", "claude"),
                 os.path.join(HOME, ".npm-global", "bin", "claude"), "/opt/homebrew/bin/claude", "/usr/local/bin/claude"):
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    best = None
    for root in VSCODE_EXTENSION_ROOTS:
        for folder in globlib.glob(os.path.join(root, "anthropic.claude-code-*")):
            path = os.path.join(folder, "resources", "native-binary", "claude")
            version = os.path.basename(folder)[len("anthropic.claude-code") + 1:].split("-")[0]
            if os.path.isfile(path) and os.access(path, os.X_OK) and (best is None or version_tuple(version) > version_tuple(best[0])):
                best = (version, path)
    return best[1] if best else None


def login_shell_command(argv, prelude=""):
    """经登录 shell 跑（读 .profile / .zprofile：PATH、nvm、conda 和自己开终端时一样；watcher 是 ssh 非交互起的，环境不全）。
    fish 这类 -c 写法不一样的换成 bash。prelude：登录脚本跑完、exec 之前先执行的一段（套网络设置用，见 net_prelude）"""
    shell = os.environ.get("SHELL") or ""
    if not shell or not os.path.exists(shell):
        try:
            import pwd
            shell = pwd.getpwuid(os.getuid()).pw_shell
        except (ImportError, KeyError):
            shell = "/bin/sh"
    if os.path.basename(shell) not in ("bash", "zsh", "sh", "dash", "ksh"):
        shell = "/bin/bash" if os.path.exists("/bin/bash") else "/bin/sh"
    return [shell, "-l", "-c", prelude + 'exec "$0" "$@"'] + list(argv)


# 网络相关的环境变量（代理、证书、接口地址、走哪家云）：后台运行的 claude 和 VS Code 里的 Claude Code 用同一套，出口才一样，
# 「出口检测」比的也是这几个。登录凭证（API Key、令牌）不在里面：不读、不传
HOSTED_NET_ENV = ("HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY", "https_proxy", "http_proxy", "all_proxy", "no_proxy",
                  "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_USE_ENV_PROXY", "CLAUDE_CODE_CERT_STORE",
                  "CLAUDE_CODE_PROXY_RESOLVES_HOSTS", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX")
# 查出口 IP 的公共网址：中性的，不碰 Anthropic、claude.ai 的域名；前一个不通换下一个（CCPULSE_IP_SITES 给测试换成本机的）
HOSTED_IP_SITES = tuple((os.environ.get("CCPULSE_IP_SITES") or "").split()) or (
    "https://ipinfo.io/json", "https://api.ip.sb/geoip", "https://ipapi.co/json/")
# 在套好网络设置的环境里跑：curl 访问查 IP 的网址（代理写法它都认），没有 curl 用 urllib；打印第一个查到的结果
_PROBE_SCRIPT = r'''
import json, subprocess, sys, urllib.request
curl = True
for url in sys.argv[1:]:
    data = b""
    if curl:
        try:
            data = subprocess.run(["curl", "-sS", "-m", "8", "-A", "curl/8", "-H", "Accept: application/json", url],
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=12).stdout
        except FileNotFoundError:
            curl = False
        except Exception:
            pass
    if not curl:
        try:
            request = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "curl/8"})
            data = urllib.request.urlopen(request, timeout=8).read()
        except Exception:
            pass
    try:
        found = json.loads(data.decode("utf-8", "replace"))
    except ValueError:
        continue
    if isinstance(found, dict) and (found.get("ip") or found.get("query")):
        found["site"] = url
        sys.stdout.write("\n\x1eKLPROBE" + json.dumps(found))
        break
'''


def process_environ(pid):
    """同一用户的进程启动时的环境变量，读不到返回 None。Linux 读 /proc；macOS 用 sysctl KERN_PROCARGS2（ps -E 用的也是它）"""
    raw = None
    try:
        with open("/proc/%d/environ" % pid, "rb") as handle:
            raw = handle.read().split(b"\0")
    except OSError:
        pass
    if raw is None and sys.platform == "darwin":
        try:
            import ctypes
            import ctypes.util
            libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
            mib = (ctypes.c_int * 3)(1, 49, pid)   # CTL_KERN, KERN_PROCARGS2
            size = ctypes.c_size_t(0)
            if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0 or not size.value:
                return None
            buf = ctypes.create_string_buffer(size.value)
            if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
                return None
            data = buf.raw[:size.value]
            argc = struct.unpack("i", data[:4])[0]
            parts = data[4:].split(b"\0")
            index = 1                                # 可执行文件路径后面是补齐用的空字节，再是参数、环境变量
            while index < len(parts) and not parts[index]:
                index += 1
            raw = parts[index + argc:]
        except (OSError, ValueError, AttributeError, struct.error):
            return None
    if raw is None:
        return None
    env = {}
    for item in raw:
        if not item:
            if env:
                break                                # macOS 环境变量后面还跟着系统自己的几项，空字节隔开
            continue
        key, sep, value = item.partition(b"=")
        if sep:
            env[key.decode("utf-8", "replace")] = value.decode("utf-8", "replace")
    # 一个变量都没有 = 没读到（macOS 对系统自带的程序不给看），不能当成「没设代理」
    return env or None


def _editor_extension_host(pid):
    """是不是编辑器的扩展宿主进程（VS Code / Cursor 本机的 Helper (Plugin)，Remote-SSH 服务端的 --type=extensionHost）"""
    if not pid:
        return False
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as handle:
            command = handle.read().replace(b"\0", b" ").decode("utf-8", "replace")
    except OSError:
        try:
            command = subprocess.run(["ps", "-ww", "-o", "command=", "-p", str(pid)], stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, timeout=5).stdout.decode("utf-8", "replace")
        except (OSError, subprocess.SubprocessError):
            return False
    return "extensionHost" in command or "Helper (Plugin)" in command


def vscode_claude_environ():
    """这台电脑上 VS Code 里正在运行的 Claude Code 的环境（最近启动的那个）：扩展给它的，含 VS Code 设置里的
    claudeCode.environmentVariables。只认父进程是扩展宿主的（测试脚本仿扩展起的 claude 带着假模型地址，不能当成用户的设置）"""
    hosted = {e.get("pid") for e in HOSTED.entries()}
    best = None
    for path in globlib.glob(os.path.join(SESSIONS_DIR, "*.json")):
        entry = read_json_file(path)
        pid = entry.get("pid") if entry else None
        if (not isinstance(pid, int) or pid in hosted or entry.get("entrypoint") != "claude-vscode"
                or (best and (entry.get("startedAt") or 0) <= best[0]) or not pid_alive(pid)
                or not _editor_extension_host(parent_pid(pid))):
            continue
        env = process_environ(pid)
        if env is not None:
            best = (entry.get("startedAt") or 0, env)
    return best[1] if best else None


def interactive_shell_environ():
    """用户自己开终端时的环境：交互式登录 shell（读 .bashrc / .zshrc 里 export 的代理）。同 VS Code 解析 shell 环境的做法，
    带上 VSCODE_RESOLVING_ENVIRONMENT，启动脚本可以跳过只给人看的部分。拿不到返回 None"""
    argv = login_shell_command([sys.executable, "-c",
                                "import json,os,sys;sys.stdout.write('\\n\\x1eKLENV'+json.dumps(dict(os.environ)))"])
    argv.insert(1, "-i")
    env = {k: v for k, v in os.environ.items() if not k.startswith("CCPULSE_")}
    env["VSCODE_RESOLVING_ENVIRONMENT"] = "1"
    try:
        out = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env,
                             timeout=15, start_new_session=True).stdout
        found = json.loads(out[out.rindex(b"\x1eKLENV") + 6:].decode("utf-8", "replace"))
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    if not isinstance(found, dict):
        return None
    found.pop("VSCODE_RESOLVING_ENVIRONMENT", None)
    return found


def net_only(env):
    """只留网络相关的那几个（os.environ 不是 dict，也认）"""
    env = dict(env) if hasattr(env, "items") else {}
    return {k: str(env[k]) for k in HOSTED_NET_ENV if env.get(k) not in (None, "")}


def registered_session(session_id):
    """这个会话正在运行的 claude（会话登记里 pid 还活着的），没有返回 None"""
    for path in globlib.glob(os.path.join(SESSIONS_DIR, "*.json")):
        entry = read_json_file(path)
        if entry and entry.get("sessionId") == session_id and isinstance(entry.get("pid"), int) and pid_alive(entry["pid"]):
            return entry
    return None


def hosted_network(request, pid=None):
    """后台运行的 claude 该用的网络设置 → (来源, {名: 值})。来源：
    vscode：照这台电脑上 VS Code 里正在运行的 Claude Code（pid：把 VS Code 里的这个会话转到后台时，照它自己的）；
    shell：VS Code 里没有在运行的，照用户开终端时的环境，再叠上 Kiteline 传来的 VS Code 设置（claudeCode.environmentVariables，
    request.netEnv；Remote-SSH 时扩展用的是本地电脑上的这项设置）。
    都拿不到抛 HOSTED_NETWORK：不在后台运行，改开 VS Code"""
    if os.environ.get("CCPULSE_HOSTED_NET") == "inherit":    # 测试：照 watcher 自己的环境（假模型地址）
        return "inherit", net_only(os.environ)
    env = process_environ(pid) if pid else None              # 转到后台的那个会话自己的
    if env is None:
        env = vscode_claude_environ()
    if env is not None:
        return "vscode", net_only(env)
    env = interactive_shell_environ()
    if env is None:
        raise RuntimeError("HOSTED_NETWORK：无法确认这台电脑上 Claude Code 使用的网络设置")
    found = net_only(env)
    found.update(net_only(request.get("netEnv")))
    return "shell", found


def net_prelude(network):
    """套网络设置的那段 shell：登录脚本跑完、exec 之前，有的设上、没有的去掉（登录脚本里 export 的也以它为准）。
    值放在 _KLN_<名> 变量里带过去，不进命令行（ps 看得见）、不落文件"""
    parts = []
    for name in HOSTED_NET_ENV:
        parts.append('export %s="$_KLN_%s"; unset _KLN_%s' % (name, name, name) if name in network else "unset " + name)
    return "; ".join(parts) + "; "


def hosted_env(network):
    """托管 claude（和出口检测）的环境：watcher 的环境去掉 Claude Code / VS Code / Kiteline 自己的标记
    （watcher 若是从 Claude Code / VS Code 里起的，留着的话新 claude 当自己是子会话，不写对话记录、不登记），网络设置另外带上"""
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CCPULSE_", "VSCODE_", "_KLN_")) and k not in HOSTED_ENV_DROP}
    env.update({"TERM": "xterm-256color", "COLORTERM": "truecolor"})
    if "UTF-8" not in (env.get("LC_ALL") or env.get("LC_CTYPE") or env.get("LANG") or "").upper().replace("UTF8", "UTF-8"):
        env["LANG"] = "en_US.UTF-8" if sys.platform == "darwin" else "C.UTF-8"
    env.update({"_KLN_" + k: v for k, v in network.items()})
    return env


def mask_url(value):
    """代理地址里的账号密码遮掉（给人看的时候）"""
    return re.sub(r"(://)[^/\s]*@", r"\1***@", str(value))


def hosted_probe(request):
    """出口检测（设置里的「检测出口 IP」）：用后台运行 claude 时的那套环境（同一个登录 shell、同样套上网络设置）访问查 IP 的公共网址，
    回出口 IP、地区，网络设置从哪来、是什么（代理地址里的账号密码遮掉）。不连 Claude"""
    if IS_WINDOWS:
        raise RuntimeError("HOSTED_UNSUPPORTED：这台电脑暂不支持在后台运行 Claude Code")
    source, network = hosted_network(request)
    reply = {"source": source, "settings": {k: mask_url(v) for k, v in network.items()}, "egress": None}
    argv = login_shell_command([sys.executable, "-c", _PROBE_SCRIPT] + list(HOSTED_IP_SITES), net_prelude(network))
    try:
        out = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             env=hosted_env(network), cwd=HOME, timeout=60, start_new_session=True).stdout
        found = json.loads(out[out.rindex(b"\x1eKLPROBE") + 8:].decode("utf-8", "replace"))
    except (OSError, subprocess.SubprocessError, ValueError):
        return reply
    country = found.get("country_code") or found.get("countryCode") or found.get("country")
    reply["egress"] = {"ip": found.get("ip") or found.get("query"),
                       "country": country if isinstance(country, str) and len(country) == 2 else None,
                       "region": found.get("region") or found.get("regionName"), "city": found.get("city"),
                       "org": found.get("org") or found.get("organization") or found.get("isp"),
                       "site": re.sub(r"^https?://([^/]+).*$", r"\1", found.get("site") or "")}
    return reply


def hosted_sock_path(hid):
    """Unix 套接字路径有长度上限（macOS 104 字节）：数据目录太深时放到临时目录里自己的文件夹"""
    path = os.path.join(HOSTED_DIR, hid + ".sock")
    if len(path.encode("utf-8")) < 100:
        return path
    folder = os.path.join(tempfile.gettempdir(), "kl-hosted-%d" % os.getuid())
    os.makedirs(folder, mode=0o700, exist_ok=True)
    return os.path.join(folder, hid + ".sock")


def hosted_call(entry, request, timeout=10):
    """给托管会话的守护进程发一个请求，等它回一行"""
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(timeout)
    try:
        conn.connect(entry["sock"])
        conn.sendall(json.dumps(request).encode("utf-8") + b"\n")
        data = b""
        while not data.endswith(b"\n"):
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
    except OSError as exc:
        raise RuntimeError("后台会话没有响应（%s）" % exc)
    finally:
        conn.close()
    reply = json.loads(data.decode("utf-8") or "{}")
    if reply.get("error"):
        raise RuntimeError(reply["error"])
    return reply


def _hosted_write(path, value):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False)
    os.replace(tmp, path)


class HostedHolder:
    """守护进程里那一半：拿着伪终端跑 claude，开套接字等 watcher 来发字、看输出"""

    def __init__(self, spec):
        self.id, self.session_id, self.cwd = spec["id"], spec["sessionId"], spec["cwd"]
        self.argv = spec["argv"]
        self.prompt, self.submit = spec.get("prompt") or "", bool(spec.get("submit"))
        self.cols, self.rows = int(spec.get("cols") or 120), int(spec.get("rows") or 40)
        self.sessions_dir = spec.get("sessionsDir") or SESSIONS_DIR
        self.base = os.path.join(spec.get("dir") or HOSTED_DIR, self.id)
        self.sock_path = spec.get("sock") or hosted_sock_path(self.id)
        self.buffer, self.end = bytearray(), 0
        self.lock = threading.Lock()
        self.write_lock = threading.Lock()
        self.nag_lock, self.nag_tried = threading.Lock(), -1
        self.subscribers = []
        self.proc, self.fd, self.server = None, None, None
        self.started = time.time()
        self.last_output = time.time()   # 最后一次有输出：Claude 在干活时转圈的字一直在刷，空闲时界面不动
        self.state = {"ready": False, "prompted": False, "claudePid": None, "stuck": None}

    # --- 登记 ---

    def info(self):
        return {"id": self.id, "holder": os.getpid(), "pid": self.state["claudePid"] or (self.proc.pid if self.proc else None),
                "child": self.proc.pid if self.proc else None, "sessionId": self.session_id, "cwd": self.cwd,
                "sock": self.sock_path, "startedAt": int(self.started * 1000), "cols": self.cols, "rows": self.rows,
                "ready": self.state["ready"], "prompted": self.state["prompted"], "stuck": self.state["stuck"], "end": self.end,
                "quietFor": round(time.time() - self.last_output, 2)}

    def register(self):
        _hosted_write(self.base + ".json", self.info())

    # --- 运行 ---

    def run(self):
        import fcntl
        import pty
        import termios
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", self.rows, self.cols, 0, 0))

        def child():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
            for sig in (signal.SIGINT, signal.SIGQUIT, signal.SIGHUP, signal.SIGTSTP, signal.SIGTTIN, signal.SIGTTOU, signal.SIGPIPE, signal.SIGTERM):
                signal.signal(sig, signal.SIG_DFL)

        # 网络设置（hosted_network 定的，watcher 经环境变量交过来，不落文件）：登录脚本跑完后套上，和 VS Code 里的 Claude Code 一致
        network = json.loads(os.environ.pop("CCPULSE_HOSTED_NETENV", "null") or "null")
        self.proc = subprocess.Popen(login_shell_command(self.argv, net_prelude(network) if isinstance(network, dict) else ""),
                                     stdin=slave, stdout=slave, stderr=slave, cwd=self.cwd,
                                     env=hosted_env(network if isinstance(network, dict) else {}), preexec_fn=child, close_fds=True)
        os.close(slave)
        self.fd = master
        signal.signal(signal.SIGTERM, lambda *_: self.stop())
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        try:
            os.unlink(self.sock_path)
        except OSError:
            pass
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        old_mask = os.umask(0o177)
        try:
            self.server.bind(self.sock_path)
        finally:
            os.umask(old_mask)
        self.server.listen(16)
        self.register()
        log("托管会话 %s：claude 已启动（pid %d，%s）" % (self.id, self.proc.pid, self.cwd))
        threading.Thread(target=self._serve, name="hosted-serve", daemon=True).start()
        threading.Thread(target=self._startup, name="hosted-startup", daemon=True).start()
        threading.Thread(target=self._guard, name="hosted-guard", daemon=True).start()
        self._pump()
        try:
            code = self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            code = None
        log("托管会话 %s：claude 退出了（%s）" % (self.id, code))
        with self.lock:
            tail = bytes(self.buffer[-8192:])
        try:
            _hosted_write(self.base + ".end", {"id": self.id, "sessionId": self.session_id, "code": code, "ready": self.state["ready"],
                                             "stuck": self.state["stuck"], "screen": screen_excerpt(tail), "endedAt": int(time.time() * 1000)})
        except OSError:
            pass
        self._broadcast({"exit": code})
        for path in (self.base + ".json", self.sock_path):
            try:
                os.unlink(path)
            except OSError:
                pass
        return 0

    def _pump(self):
        while True:
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:   # EIO：claude 退出、从端全关了
                chunk = b""
            if not chunk:
                break
            with self.lock:
                seq = self.end
                self.buffer += chunk
                if len(self.buffer) > HOSTED_BUFFER:
                    del self.buffer[:len(self.buffer) - HOSTED_BUFFER]
                self.end += len(chunk)
                self.last_output = time.time()
            self._broadcast({"seq": seq, "data": base64.b64encode(chunk).decode("ascii")})
        try:
            os.close(self.fd)
        except OSError:
            pass

    def _broadcast(self, message):
        line = json.dumps(message).encode("utf-8") + b"\n"
        for conn in list(self.subscribers):
            try:
                conn.sendall(line)
            except OSError:   # 看的那边断了或卡住：不等它
                self._unsubscribe(conn)

    def _unsubscribe(self, conn):
        if conn in self.subscribers:
            self.subscribers.remove(conn)
        try:
            conn.close()
        except OSError:
            pass

    # --- 启动时的画面 ---

    def _registered(self):
        """claude 起好了：会话登记（~/.claude/sessions/<pid>.json）里有这个会话 id。返回 claude 的 pid"""
        for path in globlib.glob(os.path.join(self.sessions_dir, "*.json")):
            try:
                with open(path, "r", encoding="utf-8") as handle:
                    payload = json.load(handle)
            except (OSError, ValueError):
                continue
            pid = payload.get("pid") if isinstance(payload, dict) else None
            if not isinstance(pid, int) or payload.get("sessionId") != self.session_id or not pid_alive(pid):
                continue
            # 还得是自己起的这个 claude（或它的子进程）：同一段对话别处若还开着，别认成它
            if pid == self.proc.pid or self.proc.pid in ancestors(pid):
                return pid
        return None

    def _since(self, offset):
        with self.lock:
            start = self.end - len(self.buffer)
            return bytes(self.buffer[max(0, offset - start):])

    def _startup(self):
        """等 claude 起来：途中停在这几个画面上就替用户答（用户在 Kiteline 里选了这个项目、要开始任务，相当于已经同意）——
        信任这个文件夹（默认选中的是「No, exit」，先挪到「Yes」再回车）、首次运行选配色（回车用默认的）、「Press Enter to continue」。
        要登录、要不要用环境变量里的 API Key 这类不替用户答：记下停在哪（stuck），hosted_start 带着画面报给用户"""
        deadline = time.time() + HOSTED_READY_SECONDS
        mark, acted, tries = 0, 0.0, 0
        pid = None
        while time.time() < deadline and self.proc.poll() is None:
            time.sleep(0.25)
            pid = self._registered()
            if pid:
                break
            # 只看上次答完之后新画出来的：前一个画面的字还留在输出里，别对着下一个画面再按一次
            fresh = self._since(mark)
            if not fresh or time.time() - acted < 0.8:
                continue
            screen = screen_text(fresh[-8000:])
            keys = None
            if "trustthisfolder" in screen or "trustthefilesinthisfolder" in screen:
                chosen = screen[screen.rfind("❯") + 1:][:8] if "❯" in screen else ""
                keys = b"\r" if chosen.startswith(("yes", "1.yes")) else b"\x1b[B"
            elif "choosethetextstyle" in screen:
                keys = b"\r"
            elif "pressentertocontinue" in screen[-200:]:
                keys = b"\r"
            if keys is None or tries >= 8:
                continue
            tries += 1
            mark, acted = self.end, time.time()
            log("托管会话 %s：启动画面替用户答 %r" % (self.id, keys))
            self.write(keys)
        if not pid:
            if self.proc.poll() is None:
                self.state["stuck"] = screen_excerpt(self._since(max(0, self.end - 8192)))
                self.register()
            return
        # 输入框刚出来时还在画：等输出停一下再粘贴，免得字落到半截画面里
        quiet_since, last_end, limit = time.time(), self.end, time.time() + 4
        while time.time() < limit:
            time.sleep(0.15)
            if self.end != last_end:
                quiet_since, last_end = time.time(), self.end
            elif time.time() - quiet_since > 0.6:
                break
        self.state.update(ready=True, claudePid=pid)
        self.register()
        if self.prompt:
            try:
                self.send(self.prompt, [], self.submit)
            except Exception as exc:  # noqa
                log("托管会话 %s：发第一句失败：%r" % (self.id, exc))
        self.state["prompted"] = True
        self.register()

    # --- 操作 ---

    def write(self, data):
        with self.write_lock:
            while data:
                data = data[os.write(self.fd, data):]

    def _dialog(self):
        """现在是不是停在选择框上（见 claude_dialog）：看最近一段输出"""
        return claude_dialog(screen_text(self._since(max(0, self.end - 131072))))

    def _clear_nags(self):
        """推广 / 引导框按 Esc 关掉（最多几次：引导有两页），回最后的状态（None / "dialog" / 还关不掉的 "nag"）"""
        with self.nag_lock:
            kind = self._dialog()
            for _ in range(4):
                # 同一个画面按过 Esc 没反应就别再按（空闲时连按两下 Esc 会打开「回到之前的消息」）
                if kind != "nag" or self.end == self.nag_tried:
                    break
                log("托管会话 %s：Claude Code 弹了推广框，按 Esc 关掉" % self.id)
                self.write(b"\x1b")
                time.sleep(1.0)
                self.nag_tried = self.end
                kind = self._dialog()
            return kind

    def _guard(self):
        """一直看着：Claude Code 空闲时弹出推广框（一轮答完常有）就关掉，免得挡住排队的消息、手机上一直「待确认」。
        只在画面停住时看（框是静止的；干活时转圈的字一直在刷）"""
        while self.proc and self.proc.poll() is None:
            time.sleep(2.0)
            if self.state["ready"] and time.time() - self.last_output > 1.5:
                try:
                    self._clear_nags()
                except Exception as exc:  # noqa
                    log("托管会话 %s：关推广框失败：%r" % (self.id, exc))

    def send(self, text, keys, submit):
        if text:
            # 停在框上时粘字 + 回车：字被框吞掉、回车替用户选了选项。推广框先关掉，别的框不送
            if self._clear_nags():
                raise RuntimeError(DIALOG_REFUSED)
        if text:
            # 括号粘贴：多行内容不会逐行提交（同 tmux paste-buffer -p）；去掉 ESC，免得内容里的「粘贴结束」提前收尾、后面变成按键
            body = text.replace("\r\n", "\n").replace("\x1b", "")
            self.write(b"\x1b[200~" + body.encode("utf-8") + b"\x1b[201~")
        for key in keys or []:
            seq = HOSTED_KEYS.get(str(key).lower())
            if not seq:
                raise RuntimeError("不支持的按键：%s" % key)
            self.write(seq)
            time.sleep(0.08)
        if submit:
            time.sleep(0.3 + min(len(text or "") / 40000.0, 1.5) if text else 0.15)
            self.write(b"\r")

    def resize(self, cols, rows):
        import fcntl
        import termios
        self.cols, self.rows = cols, rows
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        try:
            os.killpg(self.proc.pid, signal.SIGWINCH)
        except OSError:
            pass
        self.register()

    def stop(self):
        def finish():
            for sig, wait in ((signal.SIGTERM, 4), (signal.SIGKILL, 2)):
                try:
                    os.killpg(self.proc.pid, sig)
                except OSError:
                    return
                try:
                    self.proc.wait(timeout=wait)
                    return
                except subprocess.TimeoutExpired:
                    continue
        threading.Thread(target=finish, name="hosted-stop", daemon=True).start()

    # --- 套接字 ---

    def _serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            threading.Thread(target=self._client, args=(conn,), name="hosted-client", daemon=True).start()

    def _client(self, conn):
        try:
            conn.settimeout(10)
            raw = b""
            while not raw.endswith(b"\n") and len(raw) < (8 << 20):
                chunk = conn.recv(65536)
                if not chunk:
                    break
                raw += chunk
            request = json.loads(raw.decode("utf-8") or "{}")
            if request.get("op") == "subscribe":
                self._subscribe(conn)
                return
            reply = self.handle(request)
        except Exception as exc:  # noqa
            reply = {"error": str(exc) or repr(exc)}
        try:
            conn.sendall(json.dumps(reply).encode("utf-8") + b"\n")
        except OSError:
            pass
        conn.close()

    def _subscribe(self, conn):
        """持续收输出：先给最近留着的一段，之后有输出就推 {seq, data}，claude 退出推 {exit}。对面关了连接就不推了"""
        with self.lock:
            start, data = self.end - len(self.buffer), bytes(self.buffer)
            conn.settimeout(3)
            conn.sendall(json.dumps({"seq": start, "data": base64.b64encode(data).decode("ascii"), "info": self.info()}).encode("utf-8") + b"\n")
            self.subscribers.append(conn)
        try:
            conn.settimeout(None)
            while conn.recv(1024):
                pass
        except OSError:
            pass
        with self.lock:
            self._unsubscribe(conn)

    def handle(self, request):
        op = request.get("op")
        if op == "status":
            return self.info()
        if op == "send":
            self.send(request.get("text") or "", request.get("keys") or [], bool(request.get("submit")))
            return {}
        if op == "input":
            self.write(base64.b64decode(request.get("data") or ""))
            return {}
        if op == "resize":
            self.resize(max(20, min(int(request.get("cols") or 80), 500)), max(5, min(int(request.get("rows") or 24), 300)))
            return {}
        if op == "tail":
            with self.lock:
                start, data = self.end - len(self.buffer), bytes(self.buffer)
            return {"seq": start, "data": base64.b64encode(data).decode("ascii"), "info": self.info()}
        if op == "stop":
            self.stop()
            return {}
        raise RuntimeError("未知操作：%s" % op)


def command_hold(argv):
    """hold <说明文件>：托管会话的守护进程（hosted_start 起的，别手动跑）。说明文件读完就删（里面有第一句话）"""
    if not argv:
        return 2
    with open(argv[0], "r", encoding="utf-8") as handle:
        spec = json.load(handle)
    os.unlink(argv[0])
    return HostedHolder(spec).run()


class HostedTerm:
    """会话终端里的「claude」：接的是托管会话的伪终端，接口同 Term，输出从守护进程订阅来。
    关掉只是不看了，claude 照常在后台跑；下次列终端时又会出现"""

    def __init__(self, entry):
        self.entry = entry
        self.id = "h-" + entry["id"]
        self.session_id, self.cwd = entry["sessionId"], entry["cwd"]
        self.cols, self.rows = entry.get("cols") or 120, entry.get("rows") or 40
        self.created = (entry.get("startedAt") or time.time() * 1000) / 1000.0
        self.end = entry.get("end") or 0
        self.exit_code = None
        self.shell = "claude"
        self.conn = None

    def info(self):
        return {"term": self.id, "sessionId": self.session_id, "cwd": self.cwd, "shell": self.shell, "hosted": True,
                "cols": self.cols, "rows": self.rows, "createdAt": int(self.created * 1000), "end": self.end}

    def start(self):
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(10)
        conn.connect(self.entry["sock"])
        conn.sendall(b'{"op": "subscribe"}\n')
        self.conn = conn
        threading.Thread(target=self._pump, name="hosted-term-%s" % self.id, daemon=True).start()

    def _pump(self):
        reader = self.conn.makefile("rb")
        first = True
        try:
            self.conn.settimeout(None)
            for raw in reader:
                message = json.loads(raw.decode("utf-8"))
                if "exit" in message:
                    self.exit_code = message["exit"]
                    break
                data = base64.b64decode(message.get("data") or "")
                self.end = message.get("seq", 0) + len(data)
                if first:   # 先来的是留着的那段：客户端打开时 read 自己会要，这里不重复推
                    first = False
                    continue
                emit({"event": "term", "term": self.id, "sessionId": self.session_id, "seq": message.get("seq", 0),
                      "data": message.get("data") or ""})
        except Exception:
            pass
        try:
            self.conn.close()
        except OSError:
            pass
        TERMS.gone(self)

    def tail(self):
        reply = hosted_call(self.entry, {"op": "tail"})
        return reply.get("seq", 0), base64.b64decode(reply.get("data") or "")

    def write(self, data):
        hosted_call(self.entry, {"op": "input", "data": base64.b64encode(data).decode("ascii")})

    def resize(self, cols, rows):
        self.cols, self.rows = cols, rows
        hosted_call(self.entry, {"op": "resize", "cols": cols, "rows": rows})

    def close(self):
        try:
            self.conn.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


class HostedSessions:
    """watcher 这边：认出哪些会话是托管的、起新的、转发操作"""

    def entries(self):
        """守护进程还活着的托管会话（登记文件就几个，每轮读一遍）；守护进程没了的把留下的文件清掉"""
        out = []
        for path in globlib.glob(os.path.join(HOSTED_DIR, "*.json")):
            try:
                with open(path, "r", encoding="utf-8") as handle:
                    entry = json.load(handle)
            except (OSError, ValueError):
                continue
            if pid_alive(entry.get("holder")):
                out.append(entry)
                continue
            for stale in (path, entry.get("sock") or ""):
                try:
                    os.unlink(stale)
                except OSError:
                    pass
        for path in globlib.glob(os.path.join(HOSTED_DIR, "*.end")) + globlib.glob(os.path.join(HOSTED_DIR, "*.log")):
            try:
                if time.time() - os.path.getmtime(path) > 86400 and not os.path.exists(path[:-4] + ".json"):
                    os.unlink(path)
            except OSError:
                pass
        return out

    def by_pid(self, pid):
        return next((e for e in self.entries() if e.get("ready") and e.get("pid") == pid), None)

    def annotate(self, snapshots):
        """快照带上 hosted（托管会话的编号）；没在看它的终端时角标也算上「claude」这一个"""
        entries = {e.get("pid"): e for e in self.entries() if e.get("ready")}
        if not entries:
            return
        for snap in snapshots:
            entry = entries.get(snap.get("pid"))
            if entry and entry.get("sessionId") == snap.get("sessionId"):
                snap["hosted"] = entry["id"]
                if ("h-" + entry["id"]) not in TERMS.terms:
                    snap["terminals"] = (snap.get("terminals") or 0) + 1

    def attach_terms(self, session_id):
        """列终端前把这个会话的「claude」终端接上（watcher 重启过、关掉过的也重新接）"""
        for entry in self.entries():
            if not entry.get("ready") or entry.get("sessionId") != session_id or ("h-" + entry["id"]) in TERMS.terms:
                continue
            term = HostedTerm(entry)
            try:
                term.start()
            except OSError as exc:
                log("接不上托管会话 %s 的终端：%s" % (entry["id"], exc))
                continue
            with TERMS.lock:
                TERMS.terms[term.id] = term

    def start(self, request):
        """新开（sessionId 为空）或恢复一个托管会话，等 claude 起来、第一句发出去再回"""
        if IS_WINDOWS:
            raise RuntimeError("HOSTED_UNSUPPORTED：这台电脑暂不支持在后台运行 Claude Code")
        cwd = request.get("cwd")
        if not is_abs_path(cwd) or not os.path.isdir(cwd):
            raise RuntimeError("目录不存在：%s" % cwd)
        claude = claude_command()
        if not claude:
            raise RuntimeError("HOSTED_NO_CLAUDE：这台电脑上找不到 Claude Code，请先安装 Claude Code（或在 VS Code 中安装 Claude Code 扩展）")
        resume = request.get("sessionId") or None
        running = None
        if resume:
            if not re.match(r"^[0-9a-fA-F-]{8,64}$", str(resume)):
                raise RuntimeError("会话编号无效")
            if any(e.get("sessionId") == resume for e in self.entries()):
                raise RuntimeError("此会话已在后台运行")
            running = registered_session(resume)
            if running and not request.get("takeOver"):
                raise RuntimeError("HOSTED_OPEN：此会话正在 VS Code 中运行")
        # 网络设置先定下来（转到后台时照的是 VS Code 里这个会话自己的，它马上要关了）
        source, network = hosted_network(request, running.get("pid") if running and running.get("entrypoint") == "claude-vscode" else None)
        if running:
            # 把 VS Code 里正开着的会话转到后台：Kiteline 发完这个请求去关 VS Code 里的标签，等那边的 claude 退出再接着这段对话
            deadline = time.time() + 25
            while pid_alive(running["pid"]) and time.time() < deadline:
                time.sleep(0.3)
            if pid_alive(running["pid"]):
                raise RuntimeError("VS Code 中的这个会话没有关闭，未转到后台运行")
        session_id = resume or str(uuid.uuid4())
        hid = uuid.uuid4().hex[:10]
        os.makedirs(HOSTED_DIR, mode=0o700, exist_ok=True)
        os.chmod(HOSTED_DIR, 0o700)
        try:
            sync_bridge_mod()   # 起 claude 前装好 mod：电脑端发消息、批权限优先走它（见上面的说明）
        except Exception as exc:  # noqa
            log("装 bridge mod 出错：%r" % exc)
        # 恢复的会话还没有对话记录（VS Code 里刚开、一句没发的标签转到后台）：--resume 会报找不到，用同一个编号新开
        flag = "--resume" if resume and find_transcript(resume) else "--session-id"
        spec = {"id": hid, "sessionId": session_id, "cwd": cwd, "argv": [claude, flag, session_id],
                "prompt": request.get("prompt") or "", "submit": bool(request.get("submit")), "sessionsDir": SESSIONS_DIR,
                "dir": HOSTED_DIR, "sock": hosted_sock_path(hid), "cols": request.get("cols") or 120, "rows": request.get("rows") or 40}
        spec_path = os.path.join(HOSTED_DIR, hid + ".spec")
        _hosted_write(spec_path, spec)
        holder_env = dict(os.environ, CCPULSE_HOSTED_NETENV=json.dumps(network))
        with open(os.path.join(HOSTED_DIR, hid + ".log"), "ab") as errors:
            # 新会话（setsid）：和 watcher、SSH 断开没关系；标准输入输出不连着 watcher 的通道
            holder = subprocess.Popen([sys.executable, os.path.abspath(__file__), "hold", spec_path], stdin=subprocess.DEVNULL,
                                      stdout=subprocess.DEVNULL, stderr=errors, cwd=cwd, env=holder_env, close_fds=True,
                                      start_new_session=True)
        # 它是 watcher 的子进程：退出后得有人收尸，不然成了僵尸进程，pid_alive 一直当它活着
        threading.Thread(target=holder.wait, name="hosted-reap", daemon=True).start()
        log("托管会话 %s：%s %s（%s）" % (hid, "恢复" if resume else "新开", session_id, cwd))
        base = os.path.join(HOSTED_DIR, hid)
        deadline = time.time() + HOSTED_READY_SECONDS + 10
        entry = None
        while time.time() < deadline:
            time.sleep(0.25)
            entry = read_json_file(base + ".json")
            if entry and entry.get("prompted"):
                # 核对：起来的 claude 实际用的网络设置和定下的一样（读它的进程环境）；对不上就停掉，不在后台运行
                actual = process_environ(entry["pid"]) if isinstance(entry.get("pid"), int) else None
                if actual is not None and net_only(actual) != network:
                    differ = sorted(k for k in set(network) | set(net_only(actual)) if network.get(k) != net_only(actual).get(k))
                    hosted_call(entry, {"op": "stop"})
                    raise RuntimeError("HOSTED_NETWORK：后台运行的 Claude Code 网络设置与 VS Code 中的不一致（%s）" % "、".join(differ))
                return {"sessionId": session_id, "hosted": hid, "pid": entry.get("pid"), "resumed": bool(resume),
                        "submitted": bool(spec["prompt"]) and spec["submit"], "claude": claude, "network": source}
            if entry and entry.get("stuck"):
                break
            ended = read_json_file(base + ".end")
            if ended:
                raise RuntimeError("Claude Code 启动后退出了（退出码 %s）%s" % (ended.get("code"), self._screen_note(ended.get("screen"))))
        if entry:
            try:
                screen = entry.get("stuck") or screen_excerpt(base64.b64decode(hosted_call(entry, {"op": "tail"}).get("data") or "")[-8192:])
                hosted_call(entry, {"op": "stop"})
            except Exception:
                screen = entry.get("stuck")
            raise RuntimeError("Claude Code 没有启动起来，停在了需要操作的画面上，请在这台电脑的终端里运行一次 claude 处理后再试%s"
                               % self._screen_note(screen))
        raise RuntimeError("Claude Code 没有启动起来")

    @staticmethod
    def _screen_note(screen):
        screen = (screen or "").strip()
        return "：\n" + screen[-300:] if screen else ""

    def stop(self, request):
        """结束托管会话（转到 VS Code 接着做之前）：等 claude 退出再回。
        ifIdle：Claude 在干活就不停、回 {busy}。快照里的状态会晚一两秒（刚发的消息 mod 还没取走、Claude 刚开始转圈时还是空闲），
        所以再看界面：先等 1.2 秒（mod 0.4 秒取一次收件箱），最近 2 秒界面有输出就算在干活"""
        session_id = request.get("sessionId")
        entry = next((e for e in self.entries() if e.get("sessionId") == session_id), None)
        if not entry:
            return {"stopped": False}
        if request.get("ifIdle"):
            time.sleep(1.2)
            if hosted_call(entry, {"op": "status"}).get("quietFor", 99) < 2.0:
                return {"stopped": False, "busy": True}
        hosted_call(entry, {"op": "stop"})
        registry = os.path.join(HOSTED_DIR, entry["id"] + ".json")
        deadline = time.time() + 10
        while time.time() < deadline and os.path.exists(registry) and pid_alive(entry.get("holder")):
            time.sleep(0.2)
        return {"stopped": not os.path.exists(registry) or not pid_alive(entry.get("holder"))}

    def send(self, entry, text, keys, submit):
        hosted_call(entry, {"op": "send", "text": text, "keys": keys, "submit": submit}, timeout=20)
        return "hosted:" + entry["id"]


def read_json_file(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            value = json.load(handle)
        return value if isinstance(value, dict) else None
    except (OSError, ValueError):
        return None


HOSTED = HostedSessions()

# attach 断开键 Ctrl+]（同 telnet）：Ctrl+C、Esc 都要留给 Claude（中断、清输入、连按两下退出）
ATTACH_DETACH = b"\x1d"
_PRIVATE_MODES = re.compile(rb"\x1b\[\?([\d;]+)([hl])")


def hosted_label(entry):
    """列表里给人认的名字：会话标题，还没有就第一句话"""
    path = transcript_path(entry.get("sessionId"), entry.get("cwd"))
    try:
        title = tail_title(path, os.path.getsize(path)) or first_prompt(path)
    except (OSError, TypeError):
        title = None
    return " ".join((title or "").split())[:60]


def _near(here, cwd):
    """终端开在项目目录、它的子目录里，或者在它上一级"""
    return here == cwd or here.startswith(cwd.rstrip(os.sep) + os.sep) or cwd.startswith(here.rstrip(os.sep) + os.sep)


def command_attach(argv):
    """attach（见文件开头的用法）：在终端里接上后台运行的 Claude Code，和 Kiteline 会话终端里的「claude」是同一个伪终端"""
    zh = system_lang() == "zh"

    def say(cn, en):
        sys.stdout.write((cn if zh else en) + "\n")
        sys.stdout.flush()

    if IS_WINDOWS:
        say("这台电脑不支持在后台运行 Claude Code。", "Running Claude Code in the background is not supported on this computer.")
        return 1
    entries = sorted(HOSTED.entries(), key=lambda e: e.get("startedAt") or 0)
    if not entries:
        say("这台电脑上没有在后台运行的 Claude Code。", "No Claude Code session is running in the background on this computer.")
        return 1
    labels = {e["id"]: hosted_label(e) for e in entries}
    wanted = " ".join(argv).strip()
    if wanted.isdigit() and 0 < int(wanted) <= len(entries):
        picks = [entries[int(wanted) - 1]]
    elif wanted:
        low = wanted.lower()
        picks = [e for e in entries if e["id"] == wanted or (e.get("sessionId") or "").startswith(wanted)
                 or low in (e.get("cwd") or "").lower() or low in labels[e["id"]].lower()]
    else:
        here = os.path.realpath(os.getcwd())
        picks = [e for e in entries if _near(here, os.path.realpath(e.get("cwd") or "/"))]
    if len(picks) != 1:
        if wanted and not picks:
            say("没有找到「%s」。" % wanted, "Nothing matches \"%s\"." % wanted)
        say("在后台运行的 Claude Code：", "Claude Code sessions running in the background:")
        for entry in picks or entries:
            cwd = entry.get("cwd") or ""
            if cwd == HOME or cwd.startswith(HOME + os.sep):
                cwd = "~" + cwd[len(HOME):]
            since = time.strftime("%H:%M", time.localtime((entry.get("startedAt") or 0) / 1000))
            title = labels[entry["id"]] or ("（还没有标题）" if zh else "(untitled)")
            say("  %d. %s  %s（%s 开始）" % (entries.index(entry) + 1, title, cwd, since),
                "  %d. %s  %s (since %s)" % (entries.index(entry) + 1, title, cwd, since))
        if not sys.stdin.isatty():
            say("用 attach <序号> 接上。", "Run attach <number> to connect.")
            return 1
        try:
            choice = input("接上第几个（直接回车取消）：" if zh else "Number to connect (Enter to cancel): ").strip()
        except (EOFError, KeyboardInterrupt):
            sys.stdout.write("\n")
            return 1
        if not choice.isdigit() or not 0 < int(choice) <= len(entries):
            return 1
        picks = [entries[int(choice) - 1]]
    return hosted_attach(picks[0], labels[picks[0]["id"]], say)


def hosted_attach(entry, label, say):
    """接上托管会话的伪终端：输出原样写到这个终端，按键原样转过去，窗口大小跟着这个终端（断开时还回去）。
    Kiteline 的会话终端开着也没关系，两边一起看、一起能敲；窗口大小以最后调的为准"""
    import select
    import termios
    import tty
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        say("请在终端里运行。", "Run this in a terminal.")
        return 1
    in_fd, out_fd = sys.stdin.fileno(), sys.stdout.fileno()
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    pending = b""
    try:
        conn.settimeout(10)
        conn.connect(entry["sock"])
        conn.sendall(b'{"op": "subscribe"}\n')
        while b"\n" not in pending:
            chunk = conn.recv(65536)
            if not chunk:
                raise OSError("closed")
            pending += chunk
    except OSError as exc:
        conn.close()
        say("接不上这个后台会话（%s）。" % exc, "Could not connect to this session (%s)." % exc)
        return 1
    line, pending = pending.split(b"\n", 1)
    first = json.loads(line.decode("utf-8"))
    info = first.get("info") or {}
    before = (info.get("cols"), info.get("rows"))
    say("已接上后台运行的 Claude Code%s。按 Ctrl+] 断开，Claude 继续在后台运行。" % ("「%s」" % label if label else ""),
        "Connected to Claude Code running in the background%s. Press Ctrl+] to detach; Claude keeps running." % (" (%s)" % label if label else ""))
    modes = {}

    def show(data):
        for params, flag in _PRIVATE_MODES.findall(data):
            for mode in params.split(b";"):
                modes[mode] = flag == b"h"
        view = memoryview(data)
        while view:
            view = view[os.write(out_fd, view):]

    changed = [True]

    def hangup(*_):
        raise SystemExit(0)
    old_winch = signal.signal(signal.SIGWINCH, lambda *_: changed.__setitem__(0, True))
    old_hup = signal.signal(signal.SIGHUP, hangup)
    saved = termios.tcgetattr(in_fd)
    ours, reason = None, None
    try:
        tty.setraw(in_fd)
        os.write(out_fd, b"\x1b[?2004h")   # Claude 一直开着括号粘贴：留着的那段输出里不一定有这句，不开的话贴多行字每行都当回车提交
        show(base64.b64decode(first.get("data") or ""))
        conn.settimeout(None)
        while reason is None:
            if changed[0]:
                changed[0] = False
                size = os.get_terminal_size(out_fd)
                ours = (max(20, min(size.columns, 500)), max(5, min(size.lines, 300)))
                hosted_call(entry, {"op": "resize", "cols": ours[0], "rows": ours[1]})
            ready, _, _ = select.select([conn, in_fd], [], [], 0.5)
            if in_fd in ready:
                data = os.read(in_fd, 65536)
                cut = data.find(ATTACH_DETACH)
                if cut >= 0 or not data:
                    data, reason = data[:max(cut, 0)], "detach"
                if data:
                    hosted_call(entry, {"op": "input", "data": base64.b64encode(data).decode("ascii")})
            if conn in ready:
                chunk = conn.recv(65536)
                if not chunk:
                    reason = "gone"
                pending += chunk
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    message = json.loads(line.decode("utf-8"))
                    if "exit" in message:
                        reason = "exit"
                        break
                    show(base64.b64decode(message.get("data") or ""))
    except (OSError, RuntimeError, ValueError) as exc:
        reason = reason or str(exc)
    finally:
        # 关掉 Claude 开过的终端模式（括号粘贴、焦点上报、鼠标、备用屏幕），光标显示出来、挪到最底下再换行（提示别压在 Claude 的界面上）
        reset = b"\x1b[?2004l\x1b[?25h\x1b[0m" + b"".join(b"\x1b[?%sl" % m for m, on in modes.items() if on and m not in (b"25", b"2004"))
        try:
            os.write(out_fd, reset + b"\x1b[999B\r\n")
            termios.tcsetattr(in_fd, termios.TCSADRAIN, saved)
        except OSError:
            pass
        signal.signal(signal.SIGWINCH, old_winch)
        signal.signal(signal.SIGHUP, old_hup)
        conn.close()
        # 窗口大小还回去（这期间别处又调过的就不动）
        if ours and before[0] and ours != before and reason != "exit":
            try:
                now = hosted_call(entry, {"op": "status"})
                if (now.get("cols"), now.get("rows")) == ours:
                    hosted_call(entry, {"op": "resize", "cols": before[0], "rows": before[1]})
            except (OSError, RuntimeError):
                pass
    if reason == "exit":
        say("Claude Code 已退出，这个后台会话结束了。", "Claude Code exited; this background session has ended.")
    elif reason == "gone":
        say("后台会话已结束。", "The background session has ended.")
    elif reason == "detach":
        say("已断开，Claude 继续在后台运行。再次接上：python3 ~/.ccpulse/ccpulse-watch.py attach",
            "Detached; Claude keeps running. Reconnect with: python3 ~/.ccpulse/ccpulse-watch.py attach")
    else:
        say("连接中断（%s）。" % reason, "Connection lost (%s)." % reason)
    return 0


def respond_later(request, work):
    """慢请求放到后台线程做、做完再回（同 Watcher.defer）：hosted_start 要等 claude 起来，最长近一分钟，不能卡住观察循环"""
    def run():
        response = {"event": "response", "id": request.get("id"), "ok": True}
        try:
            response.update(work())
        except Exception as exc:  # noqa
            response.update({"ok": False, "error": str(exc) or repr(exc)})
        try:
            emit(response)
        except Exception:
            pass

    threading.Thread(target=run, name="slow-%s" % request.get("cmd"), daemon=True).start()
    return DEFERRED


class Watcher:
    def __init__(self, plugins=None):
        self.sessions = {}     # sessionId -> 最近一次快照（含已退出的，便于历史请求）
        self.tailers = {}      # sessionId -> Tailer（transcript；Codex 是 rollout）
        self.outboxes = {}     # sessionId -> Tailer（outbox）
        self.agents = {}       # sessionId -> claude-code / 插件 id
        self.plugins = plugins or AgentPlugins()
        self.live = set()      # 这一轮还在跑的会话
        self.asks_shown = {}   # 会话 → 已经推给客户端的补出来的待确认调用（对话项 id）

    # --- 增量 ---

    def track(self, snapshots):
        live = set()
        for snap in snapshots:
            sid = snap["sessionId"]
            live.add(sid)
            self.sessions[sid] = snap
            agent = snap.get("agent") or "claude-code"
            self.agents[sid] = agent
            path = snap.get("transcriptPath")
            tailer = self.tailers.get(sid)
            if path and (tailer is None or tailer.path != path):
                self.tailers[sid] = Tailer(path)
                if tailer is None and not self.tailers[sid].missing:
                    STAGES.bootstrap(sid, path, self.normalizer(sid))
                if agent == "claude-code":   # 别家的用量、目标在快照里直接给
                    meter = UsageMeter()
                    meter.scan(path)
                    _USAGE[sid] = meter
                    goal = ClaudeGoal()
                    goal.scan(path)
                    _GOALS[sid] = goal
            if sid not in self.outboxes:
                self.outboxes[sid] = Tailer(outbox_path(sid))
        self.live = live
        for sid in list(self.tailers.keys()):
            if sid not in live:
                del self.tailers[sid]
                self.outboxes.pop(sid, None)
                _GOALS.pop(sid, None)

    def normalizer(self, session_id):
        plugin = self.plugins.get(self.agents.get(session_id))
        # 按这个会话的对话文件要规整函数（Proma 要按文件位置修时间）
        path = (self.sessions.get(session_id) or {}).get("transcriptPath")
        return (plugin and plugin.normalizer_for(path)) or normalize_line

    def pump(self):
        for sid, tailer in list(self.tailers.items()):
            claude = self.agents.get(sid, "claude-code") == "claude-code"
            lines, was_reset = tailer.poll()
            if was_reset:
                emit({"event": "reset", "sessionId": sid})
                if claude:
                    meter = UsageMeter()
                    meter.scan(tailer.path)
                    _USAGE[sid] = meter
                    goal = ClaudeGoal()
                    goal.scan(tailer.path)
                    _GOALS[sid] = goal
            items = []
            meter = _USAGE.get(sid) if claude else None
            normalize = self.normalizer(sid)
            for offset, raw in lines:
                entry = parse_line(raw)
                if entry is not None:
                    items.extend(normalize(offset, entry))
                    if meter is not None:
                        meter.feed(entry)
            outbox = self.outboxes.get(sid)
            if outbox is not None:
                out_lines, _ = outbox.poll()
                for offset, raw in out_lines:
                    entry = parse_line(raw)
                    if entry is not None:
                        items.append(outbox_item(offset, entry))
            # 记录里没有的待确认调用（见 bridge_ask）：出现时推一条；答完了让客户端重新拉对话，把补的那条去掉
            held = _ASK_ITEMS.get(sid) if claude else None
            shown = self.asks_shown.get(sid)
            if held and shown != held["id"]:
                items.append(held)
                self.asks_shown[sid] = held["id"]
            if items:
                if claude:
                    PEERS.observe(sid, items)
                STAGES.feed(sid, items)
                emit({"event": "entries", "sessionId": sid, "items": items})
            if shown and not held:
                del self.asks_shown[sid]
                emit({"event": "reset", "sessionId": sid})
        links = PEERS.drain()
        if links:
            emit({"event": "peers", "links": links})
        # 没有落盘文件可跟的插件自己推：OpenCode 是桥的事件说哪个会话有变就去取最近几条，DeepSeek Harness 是订阅推过来的
        for sid, items in self.plugins.pump():
            STAGES.feed(sid, items)
            emit({"event": "entries", "sessionId": sid, "items": items})

    # --- 请求 ---

    def path_for(self, session_id):
        snap = self.sessions.get(session_id)
        if snap and snap.get("transcriptPath"):
            return snap["transcriptPath"]
        path = find_transcript(session_id)   # 已经结束的会话
        if path:
            return path
        raise RuntimeError("未知会话：%s" % session_id)

    def handle(self, request):
        cmd = request.get("cmd")
        if cmd == "ping":
            return {"pong": True}
        if cmd == "skills":
            # 设置里开关变了：电脑端把现在开着的技能告诉我们，马上照着装 / 删（之后定时再对也按这份）
            os.environ["CCPULSE_SKILLS"] = ",".join(str(x) for x in request.get("enabled") or [])
            return sync_skills()
        if cmd == "todos":
            # 电脑端的「agent 的待办」变了（或刚连上）：存一份给 todo 子命令——列出、接手、关掉别的会话 / 别的电脑上记的，发图时提醒没关的
            return {"ok": True, "count": save_host_todos(request.get("items"))}
        if cmd == "groups":
            # 会话群变了（或刚连上）：存一份给 group 子命令核对成员、看最近的群消息
            return {"ok": True, "count": save_host_groups(request.get("items"))}
        agent = self.agents.get(request.get("sessionId"), "claude-code")
        if cmd in ("agent_send", "agent_key", "agent_answer", "agent_close", "agent_ui"):
            return self.plugins.handle(agent, request)
        if cmd == "plugins":
            return {"plugins": self.plugins.describe(), "hostApi": HOST_API, "hostCaps": sorted(HOST_CAPS)}
        if cmd == "detect":
            # 设置 → 插件：还没装的插件，电脑端把索引里的检测规则发给每台机器（本机和 Remote-SSH 远端）问一遍
            specs = request.get("specs") if isinstance(request.get("specs"), dict) else {}
            return {"found": {pid: detect_by_spec(spec) for pid, spec in specs.items()}}
        if cmd == "peers":
            return {"links": peer_scan(int(request.get("since") or (_now_ms() - 86400000)))}
        if cmd == "machine_info":
            return machine_info()
        if cmd == "limits":
            return read_limits(list(self.sessions.values()), self.plugins)
        if cmd == "trace":
            # 执行过程面板：agent → 轮次 → 步骤。对话记录落文件的都能看（Claude 带子 agent；Codex 等插件只有主 agent）
            sid = request.get("sessionId")
            plugin = self.plugins.get(agent) if agent != "claude-code" else None
            if plugin is not None and plugin.normalize is None:
                return {"unsupported": True, "agents": [], "steps": {}}
            path = self.path_for(sid)
            snap = self.sessions.get(sid) or {}
            busy = (snap.get("activity") in ("busy", "waiting")) if snap else None
            expand = request.get("expand")
            if isinstance(expand, str):
                expand = [x for x in expand.split(",") if x]
            return session_trace(path, self.normalizer(sid), title=snap.get("title"), busy=busy,
                                 expand=expand if isinstance(expand, list) else None, subagents=agent == "claude-code",
                                 rev=request.get("rev") or None)
        if agent != "claude-code":
            # 子 agent 图、后台任务、测试记录都是从 Claude 的对话记录里认的，别家没有
            if cmd == "agents":
                return {"agents": [], "tasks": []}
            if cmd == "tests":
                return {"runs": []}
            if cmd == "task_output":
                raise RuntimeError("这个会话没有后台任务")
            plugin = self.plugins.get(agent)
            sid = request.get("sessionId")
            # 对话记录不落文件的插件，历史、搜索、图片由插件自己给；落文件的走下面和 Claude 共用的那套
            if plugin is not None and cmd == "history" and plugin.normalize is None:
                limit = max(1, min(int(request.get("limit") or HISTORY_DEFAULT_LIMIT), 400))
                items, has_more = plugin.history(sid, request.get("before"), limit)
                # agent 经子命令发来的图、待办、关键信息按时间并进这一页（同 Claude 的会话）
                ts_values = [item["ts"] for item in items if item.get("ts")]
                ts_from = min(ts_values) if (ts_values and has_more) else None
                ts_to = (request.get("beforeTs") or (max(ts_values) + 1 if ts_values else 0)) if request.get("before") is not None else None
                return {"items": items + read_outbox(sid, ts_from, ts_to), "hasMore": has_more, "end": 0}
            if plugin is not None and cmd == "search" and sid:
                return {"results": [{"hits": self.search_agent(plugin, sid, request.get("q"))}], "truncated": False}
            if plugin is not None and cmd == "media":
                got = plugin.media(sid, str(request.get("ref") or ""), (self.sessions.get(sid) or {}).get("transcriptPath"))
                if got is not None:
                    return got
        if cmd == "agents":
            path = self.path_for(request.get("sessionId"))
            return {"agents": subagent_list(path), "tasks": background_tasks(path)}
        if cmd == "task_output":
            path = self.path_for(request.get("sessionId"))
            task_id = str(request.get("taskId") or "")
            task = next((t for t in background_tasks(path) if t["id"] == task_id), None)
            if not task:
                raise RuntimeError("找不到这个后台任务")
            reply = task_output_tail(task["output"])
            reply["task"] = task
            return reply
        if cmd == "history":
            session_id = request.get("sessionId")
            path = self.path_for(session_id)
            agent_id = str(request.get("agentId") or "")
            if agent_id:
                # 子 agent 的完整记录（Agent map 里点「打开完整记录」）
                if not re.match(r"^[A-Za-z0-9_-]{3,64}$", agent_id):
                    raise RuntimeError("子 agent 编号不对")
                path = os.path.join(subagent_dir(path), "agent-%s.jsonl" % agent_id)
                if not os.path.exists(path):
                    raise RuntimeError("找不到这个子 agent 的记录")
                limit = max(1, min(int(request.get("limit") or HISTORY_DEFAULT_LIMIT), 400))
                items, has_more, end = read_history(path, request.get("before"), limit, normalize_subagent_line)
                return {"items": items, "hasMore": has_more, "end": end}
            limit = int(request.get("limit") or HISTORY_DEFAULT_LIMIT)
            limit = max(1, min(limit, 400))
            before = request.get("before")
            items, has_more, end = read_history(path, before, limit, self.normalizer(session_id))
            # 智能体发的图按时间并进这一页
            # 区间是 [本页最早, 上一页最早)：客户端翻页时带上 beforeTs（它手里最早一条的时间）
            ts_values = [item["ts"] for item in items if item.get("ts")]
            ts_from = min(ts_values) if (ts_values and has_more) else None
            ts_to = None
            if before is not None:
                ts_to = request.get("beforeTs") or (max(ts_values) + 1 if ts_values else 0)
            outbox = read_outbox(session_id, ts_from, ts_to)
            held = _ASK_ITEMS.get(session_id) if before is None else None
            return {"items": items + outbox + ([held] if held else []), "hasMore": has_more, "end": end}
        if cmd == "media":
            session_id = request.get("sessionId")
            ref = str(request.get("ref") or "")
            if ref.startswith("f:"):
                # 只允许读 inbox 里的文件（手机发来的图），不能变成任意文件读取
                path = os.path.realpath(ref[2:])
                if not path.startswith(os.path.realpath(INBOX_DIR) + os.sep):
                    raise RuntimeError("不允许读取该路径")
                with open(path, "rb") as handle:
                    data = handle.read()
                return {"mime": mimetypes.guess_type(path)[0] or "image/jpeg",
                        "data": base64.b64encode(data).decode("ascii")}
            if ref.startswith("o"):
                offset_text, _, index_text = ref[1:].partition(".")
                raw = read_line_at(outbox_path(session_id), int(offset_text))
                entry = parse_line(raw or b"")
                files = (entry or {}).get("files") or []
                info = files[int(index_text)]
                if info.get("mime") == "image/svg+xml":
                    return self.media_svg(request.get("id"), info["path"])
                with open(info["path"], "rb") as handle:
                    data = handle.read()
                return {"mime": info.get("mime") or "image/png", "data": base64.b64encode(data).decode("ascii")}
            offset_text, _, index_text = ref.partition(".")
            raw = read_line_at(self.path_for(session_id), int(offset_text))
            entry = parse_line(raw or b"")
            if entry is None:
                raise RuntimeError("图片所在行已不存在")
            for index, block in enumerate(iter_images(entry)):
                if index == int(index_text):
                    source = block.get("source") or {}
                    return {"mime": source.get("media_type") or "image/png", "data": source.get("data") or ""}
            raise RuntimeError("图片不存在：%s" % ref)
        if cmd == "put_file":
            data = base64.b64decode(request.get("data") or "")
            if len(data) > PUT_FILE_MAX:
                raise RuntimeError("文件太大")
            name = os.path.basename(str(request.get("name") or "image.jpg"))
            safe = "".join(ch if (ch.isalnum() or ch in "._-") else "_" for ch in name)[-60:] or "image.jpg"
            day = time.strftime("%Y%m%d")
            folder = os.path.join(INBOX_DIR, day)
            os.makedirs(folder, exist_ok=True)
            target = os.path.join(folder, "%s-%s-%s" % (time.strftime("%H%M%S"), uuid.uuid4().hex[:6], safe))
            with open(target, "wb") as handle:
                handle.write(data)
            return {"path": target}
        if cmd in ("git_status", "git_diff"):
            snap = self.sessions.get(request.get("sessionId")) or {}
            cwd = snap.get("cwd")
            if not cwd:
                # 会话已结束：Mac 从对话记录里查到的工作目录（项目总览里看改动也走这里）
                given = request.get("cwd")
                if is_abs_path(given) and os.path.isdir(given):
                    cwd = given
            if not cwd:
                raise RuntimeError("会话已结束或没有工作目录")   # 空目录会让 git 落到 watcher 自己的目录
            if cmd == "git_status":
                return call_with_timeout(15, git_status, cwd)
            return {"diff": call_with_timeout(15, git_diff, cwd, request.get("path"), request.get("commit"))}
        if cmd in ("fs", "repo"):
            return self.defer(request)
        if cmd == "term":
            # 会话里的终端：目录用在跑的会话的工作目录，会话结束了用电脑端查到的
            snap = self.sessions.get(request.get("sessionId")) or {}
            cwd = snap.get("cwd") if request.get("sessionId") in self.live else None
            if request.get("op") == "list" and snap.get("hosted"):
                HOSTED.attach_terms(request.get("sessionId"))   # 托管会话的「claude」终端
            return TERMS.handle(request, cwd or request.get("cwd"))
        if cmd == "repo_info":
            return repo_info(request.get("cwd"))
        if cmd == "worktree_add":
            return worktree_add(request.get("cwd"))
        if cmd == "ls":
            return call_with_timeout(15, list_dir, request.get("root"), request.get("path"))
        if cmd == "dirs":
            return call_with_timeout(15, list_dirs, request.get("path"), bool(request.get("hidden")), request.get("mkdir"))
        if cmd == "read_file":
            return call_with_timeout(15, read_file, request.get("root"), request.get("path"), bool(request.get("reveal")),
                                     bool(request.get("edit")))
        if cmd == "find_files":
            return call_with_timeout(15, find_files, request.get("root"), request.get("q"))
        if cmd == "get_file":
            return call_with_timeout(60, get_file, request.get("path"), request.get("cwd"), bool(request.get("reveal")))
        if cmd == "brag":
            # 分享战绩：按天的数字（sessionId 给了就只算这一个会话）
            if request.get("sessionId"):
                return {"session": call_with_timeout(60, brag_session, self.path_for(request.get("sessionId")))}
            return call_with_timeout(90, brag_report, int(request.get("since") or 0), int(request.get("until") or 0) or None,
                                     int(request.get("tz") or 0), self.plugins)
        if cmd == "usage_report":
            return usage_report(int(request.get("since") or 0), int(request.get("until") or 0) or None,
                                int(request.get("tz") or 0), self.plugins)
        if cmd == "sessions_list":
            return {"sessions": list_sessions(int(request.get("limit") or 80), request.get("cwd"), request.get("project"))}
        if cmd == "session_info":
            path = find_transcript(request.get("sessionId"))
            if not path:
                raise RuntimeError("找不到这个会话的记录")
            return {"session": session_meta(path)}
        if cmd == "search":
            if request.get("sessionId"):
                # 对话内搜索：只搜这一份，命中都要
                path = self.path_for(request.get("sessionId"))
                results, truncated = search_sessions(request.get("q"), 200, per_session=200, paths=[path])
                return {"results": results, "truncated": truncated}
            results, truncated = search_sessions(request.get("q"), int(request.get("limit") or 60))
            return {"results": results, "truncated": truncated}
        if cmd == "projects":
            return {"projects": list_projects(int(request.get("limit") or 60))}
        if cmd == "project_overview":
            since = request.get("since")
            return {"projects": project_overview(int(request.get("limit") or 40), int(since) if since else None,
                                                 request.get("extra") or [])}
        if cmd == "is_dir":
            path = str(request.get("path") or "")
            return {"isDir": is_abs_path(path) and os.path.isdir(path)}
        if cmd == "digest":
            since = int(request.get("since") or 0)
            until = int(request.get("until") or 0) or None
            live = {sid: snap.get("cwd") for sid, snap in self.sessions.items()}
            return {"sessions": digest_all(since, live, until)}
        if cmd == "tests":
            return {"runs": find_test_runs(self.path_for(request.get("sessionId")), int(request.get("limit") or 40))}
        if cmd == "bridge":
            return self.bridge(request)
        if cmd == "hosted_start":
            return respond_later(request, lambda: HOSTED.start(request))
        if cmd == "hosted_stop":
            return respond_later(request, lambda: HOSTED.stop(request))
        if cmd == "hosted_probe":
            return respond_later(request, lambda: hosted_probe(request))
        if cmd == "tmux_send":
            pid = int(request.get("pid") or 0)
            pane = tmux_send(pid, request.get("text") or "", request.get("keys") or [],
                             bool(request.get("submit")))
            return {"pane": pane}
        raise RuntimeError("未知请求：%s" % cmd)

    def bridge(self, request):
        """后台送达（见 bridge_send）：会话的 claude 进程加载了 mod 才送，等回执要一两秒，放后台线程回、别卡住观察循环。
        回 bridged False 时电脑端照旧走前台"""
        sid = str(request.get("sessionId") or "")
        op = request.get("op")
        snap = self.sessions.get(sid) or {}
        if op not in BRIDGE_OPS or sid not in self.live or not bridge_alive(sid, snap.get("startedAt")):
            return {"bridged": False}
        if op == "queue" and (request.get("action") not in BRIDGE_QUEUE_ACTIONS or (bridge_alive(sid, snap.get("startedAt")) or 0) < 2):
            return {"bridged": False}
        fields = {key: request[key] for key in ("text", "decision", "answers", "tool", "action", "qid", "dir") if request.get(key) is not None}
        rid = request.get("id")

        def work():
            response = {"event": "response", "id": rid, "ok": True}
            try:
                response.update(bridge_send(sid, op, **fields))
            except Exception as exc:  # noqa
                log("后台送达失败：%r" % exc)
                response.update({"bridged": False})
            try:
                emit(response)
            except Exception:
                pass

        threading.Thread(target=work, name="bridge", daemon=True).start()
        return DEFERRED

    def search_agent(self, plugin, session_id, query):
        """插件的会话里搜：在规整好的对话项里找（结果格式同 search_sessions 的 hits）"""
        needle = (query or "").strip().lower()
        if not needle:
            return []
        if plugin.normalize is None:
            items = plugin.items(session_id, 400)
        else:
            items = []
            normalize = self.normalizer(session_id)
            with open(self.path_for(session_id), "rb") as handle:
                offset = 0
                for raw in handle:
                    entry = parse_line(raw)
                    if entry is not None:
                        items.extend(normalize(offset, entry))
                    offset += len(raw)
        hits = []
        for item in items:
            text = item.get("text") or ""
            if item["t"] not in ("user", "text") or needle not in text.lower():
                continue
            at = text.lower().index(needle)
            left = max(0, at - 36)
            hits.append({"id": item["id"], "ts": item.get("ts"), "t": item["t"],
                         "snippet": ("…" if left else "") + text[left:at + len(needle) + 60].replace("\n", " ")})
        return hits[-200:]

    def defer(self, request):
        """代码 IDE 的改文件、Git：放到后台线程做、做完再回。推送、拉取、提交钩子能跑几分钟，不能卡住观察循环（心跳停了电脑端会重启 watcher）"""
        rid, cmd = request.get("id"), request.get("cmd")
        snap = self.sessions.get(request.get("sessionId")) or {}
        cwd = snap.get("cwd") if request.get("sessionId") in self.live else None
        given = request.get("cwd") or request.get("root")
        if not cwd and is_abs_path(given) and os.path.isdir(given):
            cwd = given   # 会话已结束：电脑端从对话记录里查到的工作目录
        sessions = [{"sessionId": sid, "cwd": (self.sessions.get(sid) or {}).get("cwd")} for sid in self.live]
        if cmd == "repo" and request.get("op") == "job":
            # 慢操作（推送、拉取……）的结果：手机隔一秒问一次，做完了给结果
            job = _IDE_JOBS.get(request.get("job") or "")
            if not job:
                raise RuntimeError("任务不存在或已过期")
            return dict(job)

        def compute():
            out = {"ok": True}
            try:
                if not cwd:
                    raise RuntimeError("会话已结束或没有工作目录")
                out.update(fs_op(cwd, request) if cmd == "fs" else repo_request(cwd, request, sessions))
            except GitFailed as exc:
                # git 的原话放 detail（冲突的文件、钩子的输出），error 是一句能看懂的话；RPC 层照常算成功，免得 detail 丢掉
                out.update({"failed": True, "error": str(exc), "detail": exc.output})
            except Exception as exc:  # noqa
                out = {"ok": False, "error": str(exc) or repr(exc)}
            return out

        if request.get("job"):
            # 推送、拉取、提交钩子能跑好几分钟，手机那边的请求等不了这么久：先回一个任务号，结果存起来等它来问
            for old in [k for k, v in _IDE_JOBS.items() if time.time() - v.get("at", 0) > 900]:
                _IDE_JOBS.pop(old, None)
            jid = "j-" + uuid.uuid4().hex[:12]
            _IDE_JOBS[jid] = {"done": False, "at": time.time()}

            def run_job():
                result = compute()
                failed = not result.pop("ok", True)
                _IDE_JOBS[jid] = {"done": True, "at": time.time(), "result": result,
                                  "failed": failed or bool(result.get("failed")), "error": result.get("error"), "detail": result.get("detail")}

            threading.Thread(target=run_job, name="ide-job", daemon=True).start()
            return {"job": jid}

        def work():
            response = {"event": "response", "id": rid}
            response.update(compute())
            try:
                emit(response)
            except Exception:
                pass

        threading.Thread(target=work, name="ide-%s" % cmd, daemon=True).start()
        return DEFERRED

    def media_svg(self, rid, path):
        """以前发出去的 SVG 图（Windows 上找不到浏览器时，测试报告的文字总览就是 SVG）：客户端都显示不了，换成 PNG 给，
        转好的放在旁边下次直接用；转不了照旧给 SVG。要起浏览器（几秒），放后台线程回，别卡住观察循环"""
        def work():
            response = {"event": "response", "id": rid, "ok": True}
            try:
                png = os.path.splitext(path)[0] + ".png"
                with _SVG_LOCK:   # 缩略图和原图常同时来要，别两个浏览器往同一个文件里截
                    if not (os.path.exists(png) and os.path.getsize(png) > 100):
                        png = svg_to_png(path, png)
                with open(png or path, "rb") as handle:
                    data = handle.read()
                response.update({"mime": "image/png" if png else "image/svg+xml", "data": base64.b64encode(data).decode("ascii")})
            except Exception as exc:
                response.update({"ok": False, "error": str(exc) or repr(exc)})
            try:
                emit(response)
            except Exception:
                pass

        threading.Thread(target=work, name="media-svg", daemon=True).start()
        return DEFERRED

    def respond(self, raw):
        try:
            request = json.loads(raw)
        except ValueError:
            log("忽略无法解析的请求")
            return
        if not isinstance(request, dict):
            return
        request_id = request.get("id")
        try:
            result = self.handle(request)
            if result is DEFERRED:
                return
            response = {"event": "response", "id": request_id, "ok": True}
            response.update(result)
        except Exception as exc:  # 单个请求失败不能拖垮观察循环
            response = {"event": "response", "id": request_id, "ok": False, "error": str(exc) or repr(exc)}
        emit(response)


# MARK: 本机性能（会话列表「按来源」分组时，机器名旁边显示 CPU、内存、网速）

SYS_SECONDS = 5.0


def _linux_mem():
    info = {}
    with open("/proc/meminfo") as handle:
        for line in handle:
            key, _, rest = line.partition(":")
            if key in ("MemTotal", "MemAvailable", "MemFree", "Buffers", "Cached"):
                info[key] = int(rest.split()[0]) * 1024
    available = info.get("MemAvailable")
    if available is None:   # 3.14 以前的内核没有 MemAvailable
        available = info.get("MemFree", 0) + info.get("Buffers", 0) + info.get("Cached", 0)
    return info["MemTotal"], info["MemTotal"] - available


def _linux_cpu():
    with open("/proc/stat") as handle:
        ticks = [int(x) for x in handle.readline().split()[1:9]]   # user nice system idle iowait irq softirq steal
    total = sum(ticks)
    return total - ticks[3] - ticks[4], total


def _linux_net():
    """物理网卡（/sys/class/net/<名>/device 在）的收发合计：网桥、VPN、docker 的流量本来就会经过物理网卡，再加就重复了"""
    rows = []
    with open("/proc/net/dev") as handle:
        for line in handle.readlines()[2:]:
            name, _, rest = line.partition(":")
            name = name.strip()
            fields = rest.split()
            if name != "lo" and len(fields) >= 9:
                rows.append((name, int(fields[0]), int(fields[8])))
    physical = [r for r in rows if os.path.exists("/sys/class/net/%s/device" % r[0])] or rows
    return sum(r[1] for r in physical), sum(r[2] for r in physical)


if sys.platform == "darwin":
    import ctypes

    # 载入失败（极少见）不能让观察器起不来：这几项读的时候报错，SysSampler 记一次日志就不再读
    try:
        _sys_lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        _sys_lib.mach_host_self.restype = ctypes.c_uint32
        _sys_host = _sys_lib.mach_host_self()
    except (OSError, AttributeError):
        _sys_lib = _sys_host = None

    def _mac_sysctl_u64(name):
        value, size = ctypes.c_uint64(0), ctypes.c_size_t(8)
        if _sys_lib.sysctlbyname(name.encode(), ctypes.byref(value), ctypes.byref(size), None, ctypes.c_size_t(0)) != 0:
            raise OSError("sysctl %s 失败" % name)
        return value.value

    def _mac_host_info(flavor, count):
        buffer = (ctypes.c_uint32 * count)()
        size = ctypes.c_uint32(count)
        fn = _sys_lib.host_statistics64 if flavor == 4 else _sys_lib.host_statistics
        if fn(_sys_host, flavor, buffer, ctypes.byref(size)) != 0:
            raise OSError("host_statistics(%d) 失败" % flavor)
        return bytes(buffer)

    def _mac_ifname(index):
        try:
            return socket.if_indextoname(index)
        except OSError:
            return ""

    def _mac_mem():
        """和活动监视器的「已使用内存」一样：App 内存（匿名页 − 可清除）+ 联动 + 被压缩"""
        vm = struct.unpack_from("<4I9Q2I4Q4IQ", _mac_host_info(4, 38))   # HOST_VM_INFO64，vm_statistics64
        wired, purgeable, compressed, internal = vm[3], vm[13], vm[19], vm[22]
        return _mac_sysctl_u64("hw.memsize"), (internal - purgeable + wired + compressed) * _mac_sysctl_u64("hw.pagesize")

    def _mac_cpu():
        user, system, idle, nice = struct.unpack("<4I", _mac_host_info(3, 4))   # HOST_CPU_LOAD_INFO
        busy = user + system + nice
        return busy, busy + idle

    def _mac_net():
        """sysctl NET_RT_IFLIST2：每块网卡一条 if_msghdr2，里面是 64 位计数的 if_data64。
        以太网类（有线、Wi-Fi、雷雳网卡）收发都算；跳过回环、utun（VPN 的流量已经算在真网卡上）、虚拟机的 vmenet。
        网桥（如「雷雳网桥」bridge0）只算收：macOS 把成员网卡收到的字节记在网桥上（成员的收是 0），
        发出的却在成员网卡上记一份、网桥上再记双份"""
        mib = (ctypes.c_int * 6)(4, 17, 0, 0, 6, 0)   # CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0
        size = ctypes.c_size_t(0)
        if _sys_lib.sysctl(mib, 6, None, ctypes.byref(size), None, ctypes.c_size_t(0)) != 0:
            raise OSError("sysctl NET_RT_IFLIST2 失败")
        size.value += 4096   # 两次调用之间可能多出网卡
        buffer = ctypes.create_string_buffer(size.value)
        if _sys_lib.sysctl(mib, 6, buffer, ctypes.byref(size), None, ctypes.c_size_t(0)) != 0:
            raise OSError("sysctl NET_RT_IFLIST2 失败")
        data, offset, rx, tx = buffer.raw[:size.value], 0, 0, 0
        while offset + 4 <= len(data):
            length, _, kind = struct.unpack_from("<HBB", data, offset)
            if length == 0:
                break
            # RTM_IFINFO2；if_data64 从第 32 字节起，ifi_type 是它的第一个字节，ifi_ibytes / ifi_obytes 在它的第 64、72 字节
            if kind == 0x12 and length >= 112 and offset + 112 <= len(data) and data[offset + 32] in (0x06, 0xD1):
                ibytes, obytes = struct.unpack_from("<QQ", data, offset + 32 + 64)
                if data[offset + 32] == 0xD1:   # IFT_BRIDGE
                    rx += ibytes
                elif (ibytes or obytes) and not _mac_ifname(struct.unpack_from("<H", data, offset + 12)[0]).startswith("vmenet"):   # IFT_ETHER
                    rx, tx = rx + ibytes, tx + obytes
            offset += length
        return rx, tx

elif IS_WINDOWS:
    class _MEMORYSTATUSEX(ctypes.Structure):
        _fields_ = [("dwLength", wintypes.DWORD), ("dwMemoryLoad", wintypes.DWORD)] + \
                   [(name, ctypes.c_uint64) for name in ("ullTotalPhys", "ullAvailPhys", "ullTotalPageFile", "ullAvailPageFile",
                                                        "ullTotalVirtual", "ullAvailVirtual", "ullAvailExtendedVirtual")]

    try:
        _sys_iphlp = ctypes.WinDLL("iphlpapi")
        _sys_iphlp.GetIfTable2.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
        _sys_iphlp.FreeMibTable.argtypes = [ctypes.c_void_p]
    except (OSError, AttributeError):
        _sys_iphlp = None

    def _win_mem():
        status = _MEMORYSTATUSEX()
        status.dwLength = ctypes.sizeof(_MEMORYSTATUSEX)
        if not _k32.GlobalMemoryStatusEx(ctypes.byref(status)):
            raise OSError("GlobalMemoryStatusEx 失败")
        return status.ullTotalPhys, status.ullTotalPhys - status.ullAvailPhys

    def _win_cpu():
        idle, kernel, user = wintypes.FILETIME(), wintypes.FILETIME(), wintypes.FILETIME()
        if not _k32.GetSystemTimes(ctypes.byref(idle), ctypes.byref(kernel), ctypes.byref(user)):
            raise OSError("GetSystemTimes 失败")
        idle, kernel, user = [(t.dwHighDateTime << 32) | t.dwLowDateTime for t in (idle, kernel, user)]
        return kernel + user - idle, kernel + user   # 内核时间里含空闲

    def _win_net():
        """GetIfTable2：只算真网卡（HardwareInterface），跳过过滤驱动挂出来的重复行、回环、虚拟网卡。
        MIB_IF_ROW2 每行 1352 字节，表头 NumEntries 后按 8 对齐"""
        table = ctypes.c_void_p()
        if _sys_iphlp.GetIfTable2(ctypes.byref(table)) != 0:
            raise OSError("GetIfTable2 失败")
        try:
            rx = tx = 0
            for i in range(ctypes.c_ulong.from_address(table.value).value):
                row = table.value + 8 + i * 1352
                flags = ctypes.c_ubyte.from_address(row + 1152).value   # bit0 HardwareInterface，bit1 FilterInterface
                if flags & 0x03 == 0x01 and ctypes.c_ulong.from_address(row + 1128).value != 24:   # Type 24 = 回环
                    rx += ctypes.c_uint64.from_address(row + 1208).value   # InOctets
                    tx += ctypes.c_uint64.from_address(row + 1280).value   # OutOctets
            return rx, tx
        finally:
            _sys_iphlp.FreeMibTable(table)


if sys.platform == "darwin":
    _SYS_PROBES = {"mem": _mac_mem, "cpu": _mac_cpu, "net": _mac_net}
elif IS_WINDOWS:
    _SYS_PROBES = {"mem": _win_mem, "cpu": _win_cpu, "net": _win_net}
elif os.path.exists("/proc/stat"):
    _SYS_PROBES = {"mem": _linux_mem, "cpu": _linux_cpu, "net": _linux_net}
else:
    _SYS_PROBES = {}


class SysSampler:
    """隔几秒采一次本机的 CPU 占用、内存（总量 / 已用）、网速（收发合计）。CPU 和网速是两次采样相减，
    第一次只记基线、隔 1 秒就出第一条，之后每 5 秒一条。某一项读不了就记一次日志、以后不再读"""

    def __init__(self):
        self.prev = None
        self.next_at = 0.0
        self.broken = set()

    def _read(self, key):
        probe = _SYS_PROBES.get(key)
        if probe is None or key in self.broken:
            return None
        try:
            return probe()
        except Exception as exc:
            self.broken.add(key)
            log("sys %s unavailable: %r" % (key, exc))
            return None

    def tick(self, now):
        if now < self.next_at or not _SYS_PROBES:
            return None
        sample = {"t": now, "cpu": self._read("cpu"), "net": self._read("net")}
        prev, self.prev = self.prev, sample
        self.next_at = now + (1.0 if prev is None else SYS_SECONDS)
        if prev is None:
            return None
        event = {"event": "sys", "at": int(now * 1000), "cores": os.cpu_count() or 0}
        mem = self._read("mem")
        if mem:
            event["memTotal"], event["memUsed"] = int(mem[0]), max(int(mem[1]), 0)
        if sample["cpu"] and prev["cpu"]:
            busy, total = sample["cpu"][0] - prev["cpu"][0], sample["cpu"][1] - prev["cpu"][1]
            if total > 0:
                event["cpu"] = round(min(max(busy / total, 0.0), 1.0), 3)
        span = now - prev["t"]
        if sample["net"] and prev["net"] and span > 0:
            # 网卡没了、计数归零时差值为负：这一轮记 0
            event["netIn"] = int(max(sample["net"][0] - prev["net"][0], 0) / span)
            event["netOut"] = int(max(sample["net"][1] - prev["net"][1], 0) / span)
        return event if len(event) > 3 else None


def _run_text(args, timeout=3):
    """跑一个小命令取输出（读不到返回空串）：设备详情用，都是系统自带、一瞬间就完的"""
    try:
        done = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout,
                              **({"creationflags": 0x08000000} if IS_WINDOWS else {}))   # CREATE_NO_WINDOW
        return done.stdout.decode("utf-8", "replace").strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def _os_name():
    """系统名称和版本：macOS 27.0 / Ubuntu 24.04.1 LTS / Windows 11（26100）"""
    import platform
    if sys.platform == "darwin":
        version = platform.mac_ver()[0]
        return "macOS %s" % version if version else "macOS"
    if IS_WINDOWS:
        parts = platform.version().split(".")
        build = int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else 0
        # Windows 11 的 release 仍报 10，按内部版本号分
        name = "Windows 11" if build >= 22000 else "Windows %s" % platform.release()
        return "%s（%d）" % (name, build) if build else name
    for line in (read_text("/etc/os-release") or "").splitlines():
        if line.startswith("PRETTY_NAME="):
            return line.split("=", 1)[1].strip().strip('"')
    return "%s %s" % (platform.system(), platform.release())


def _cpu_model():
    """CPU 型号：Apple M2 Max / AMD Ryzen AI Max+ 395 / Intel Core i7-…"""
    if sys.platform == "darwin":
        return _run_text(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"])
    if IS_WINDOWS:
        try:
            import winreg
            with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"HARDWARE\DESCRIPTION\System\CentralProcessor\0") as key:
                return str(winreg.QueryValueEx(key, "ProcessorNameString")[0]).strip()
        except OSError:
            return ""
    for line in (read_text("/proc/cpuinfo") or "").splitlines():
        name, _, value = line.partition(":")
        if name.strip() in ("model name", "Hardware", "Model") and value.strip():
            return " ".join(value.split())
    return ""


def _uptime_seconds():
    try:
        if sys.platform == "darwin":
            match = re.search(r"sec = (\d+)", _run_text(["/usr/sbin/sysctl", "-n", "kern.boottime"]))
            return int(time.time() - int(match.group(1))) if match else None
        if IS_WINDOWS:
            _k32.GetTickCount64.restype = ctypes.c_uint64
            return int(_k32.GetTickCount64() / 1000)
        return int(float((read_text("/proc/uptime") or "").split()[0]))
    except (ValueError, IndexError, AttributeError, OSError):
        return None


def _ip_addresses():
    """这台机器的 IPv4 地址 [{name: 网卡, ip}]：跳过回环、自动分配的 169.254；
    primary 是去外网时用的那个（UDP connect 只选路、不发包）"""
    found = []
    if sys.platform == "darwin":
        name = ""
        for line in _run_text(["/sbin/ifconfig"]).splitlines():
            if line and not line[0].isspace():
                name = line.split(":", 1)[0]
            match = re.match(r"\s+inet (\d+\.\d+\.\d+\.\d+)", line)
            if match:
                found.append({"name": name, "ip": match.group(1)})
    elif not IS_WINDOWS:
        for line in _run_text(["ip", "-o", "-4", "addr", "show"]).splitlines():
            match = re.match(r"\d+:\s+(\S+)\s+inet (\d+\.\d+\.\d+\.\d+)", line)
            if match:
                found.append({"name": match.group(1), "ip": match.group(2)})
    if not found:   # Windows、没有 ip 命令的 Linux：主机名解析出来的就是各网卡的地址
        try:
            for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
                if not any(item["ip"] == info[4][0] for item in found):
                    found.append({"name": "", "ip": info[4][0]})
        except OSError:
            pass
    found = [item for item in found if not item["ip"].startswith(("127.", "169.254."))]
    # 真网卡排前面：代理软件的 TUN（Clash / Mihomo 的 198.18.x）、VPN、容器和虚拟机网桥排后面
    found.sort(key=lambda item: _virtual_nic(item["name"], item["ip"]))
    primary = None
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            probe.connect(("223.5.5.5", 53))
            primary = probe.getsockname()[0]
        finally:
            probe.close()
    except OSError:
        pass
    # 开着代理 TUN、VPN 时默认路由走虚拟网卡：主 IP 改取第一块真网卡的
    if primary is None or _virtual_nic(next((i["name"] for i in found if i["ip"] == primary), ""), primary):
        primary = next((i["ip"] for i in found if not _virtual_nic(i["name"], i["ip"])), primary)
    return found, primary


_VIRTUAL_NIC = re.compile(r"^(utun|tun|tap|wg|tailscale|zt|docker|br-|veth|virbr|vmnet|vboxnet|awdl|llw|anpi|ppp|meta|clash|mihomo)", re.I)


def _virtual_nic(name, ip):
    return ip.startswith(("198.18.", "198.19.")) or bool(_VIRTUAL_NIC.match(name or ""))


def claude_forms():
    """这台机器上的 Claude Code：终端版（原生安装的版本号取 ~/.local/share/claude/versions）、VS Code 扩展的版本。
    只看文件，不跑 claude --version（起 node 要一两秒）"""
    forms = {}
    suffix = ".exe" if IS_WINDOWS else ""
    candidates = [os.path.join(HOME, ".local", "bin", "claude" + suffix), os.path.join(HOME, ".claude", "local", "claude" + suffix),
                  "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    if shutil.which("claude") or any(os.path.isfile(path) for path in candidates):
        versions = [os.path.basename(path) for path in globlib.glob(os.path.join(HOME, ".local", "share", "claude", "versions", "*"))]
        versions = [v for v in versions if re.match(r"^\d+\.\d+", v)]
        forms["cli"] = max(versions, key=version_tuple) if versions else ""
    extension = extension_version("anthropic.claude-code")
    if extension:
        forms["vscode"] = extension
    return forms


def machine_info():
    """设备详情（打开详情页时才调，不定时报）：主机名、用户、系统、架构、CPU 型号和核数、内存总量、IP、开机多久、家目录所在磁盘"""
    import platform
    info = {"hostname": socket.gethostname(), "os": _os_name(), "arch": platform.machine(), "cores": os.cpu_count() or 0,
            "cpuModel": _cpu_model(), "python": platform.python_version(), "watcher": WATCHER_VERSION, "home": HOME}
    try:
        import getpass
        info["user"] = getpass.getuser()
    except Exception:
        pass
    mem = _SYS_PROBES.get("mem")
    if mem:
        try:
            info["memTotal"] = int(mem()[0])
        except Exception:
            pass
    uptime = _uptime_seconds()
    if uptime:
        info["uptime"] = uptime
    try:
        disk = shutil.disk_usage(HOME)
        info["diskTotal"], info["diskFree"] = int(disk.total), int(disk.free)
    except OSError:
        pass
    try:
        forms = claude_forms()
        if forms or os.path.isdir(os.path.join(HOME, ".claude")):
            info["claude"] = {"installed": True, "forms": forms}
    except Exception as exc:
        log("读 Claude Code 版本失败：%r" % exc)
    addresses, primary = _ip_addresses()
    info["ips"] = addresses
    if primary:
        info["primaryIp"] = primary
    return info


def stdin_reader(inbox):
    """后台线程：把 stdin 的请求行放进队列。stdin 关闭（本机旧版或 /dev/null）就安静退出。"""
    stream = io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace")
    try:
        for line in stream:
            line = line.strip()
            if line and not ('"term"' in line and term_fast(line)):
                inbox.put(line)
    except Exception as exc:
        log("stdin 读取结束：%r" % exc)


def term_fast(line):
    """终端的按键、改大小、读输出不排队：主循环扫会话的那几百毫秒里也立刻处理，打字不卡。开终端要查会话目录，照常排队"""
    try:
        request = json.loads(line)
    except ValueError:
        return False
    if not isinstance(request, dict) or request.get("cmd") != "term" or request.get("op") in (None, "open", "list"):
        return False
    response = {"event": "response", "id": request.get("id"), "ok": True}
    try:
        response.update(TERMS.handle(request, None))
    except Exception as exc:
        response.update({"ok": False, "error": str(exc) or repr(exc)})
    emit(response)
    return True


def unused_session(snap):
    """一句话都还没发过的 Claude Code 会话：VS Code 里新开没用的标签、扩展预先起好备用的 claude、新建会话没提交成功留下的空标签。
    进程和会话登记都有，对话记录还没写出来，列出来只是一行空会话（11-07），等发了第一句、有了对话记录再列。
    后台托管的照列（要从终端里接着操作）；正在干活、等确认的也照列"""
    if snap.get("agent") not in (None, "claude-code") or snap.get("hosted"):
        return False
    if snap.get("activity") != "idle" or snap.get("transcriptUpdatedAt"):
        return False
    path = snap.get("transcriptPath")
    return bool(path) and not os.path.exists(path)


def collect_snapshots(debug_state):
    snapshots = []
    if not os.path.isdir(SESSIONS_DIR):
        return snapshots
    try:
        names = os.listdir(SESSIONS_DIR)
    except OSError:
        names = []
    if DEBUG and debug_state["scans"] < 3:
        debug_state["scans"] += 1
        log("SCAN dir=%s files=%d json=%s" % (
            SESSIONS_DIR, len(names), [n for n in names if n.endswith(".json")][:5]))
    for name in names:
        if not name.endswith(".json") or not name[:-5].isdigit():
            continue
        raw = read_text(os.path.join(SESSIONS_DIR, name))
        if not raw:
            continue
        try:
            payload = json.loads(raw)
        except ValueError:
            continue  # 被写到一半的文件，下一轮再说
        if not isinstance(payload, dict) or not payload.get("sessionId"):
            continue
        PEERS.learn(payload)
        if not is_live(payload):
            if DEBUG:
                log("SKIP %s: pid=%s 不在线" % (name, payload.get("pid")))
            continue
        try:
            snapshots.append(snapshot_session(payload))
        except Exception as exc:  # 单个会话出错不能拖垮整体
            log("snapshot failed for %s: %r" % (name, exc))
    snapshots.sort(key=lambda item: item.get("startedAt") or 0)
    return snapshots


def main():
    log("starting v%s on %s (pid %d)" % (WATCHER_VERSION, sys.platform, os.getpid()))
    emit({
        "event": "hello",
        "protocol": PROTOCOL,
        "watcher": WATCHER_VERSION,
        "features": FEATURES,
        "host": os.uname().nodename if hasattr(os, "uname") else (os.environ.get("COMPUTERNAME") or "Windows"),
        "home": HOME,
        "platform": sys.platform,
        "python": sys.version.split()[0],
        "sessionsDir": SESSIONS_DIR,
        # agent 在 Bash 里调本脚本的写法：电脑端往会话群的消息里写回复方法时用（各台电脑装的位置不同）
        "selfCommand": self_command(),
        "hostApi": HOST_API,                 # 中台版本和能力：电脑端装插件前核对
        "hostCaps": sorted(HOST_CAPS),
    })

    inbox = queue.Queue()
    reader = threading.Thread(target=stdin_reader, args=(inbox,), daemon=True)
    reader.start()

    plugins = AgentPlugins()
    plugins.start()
    watcher = Watcher(plugins)
    try:
        sync_skills()
        sync_limits_mod()
        sync_stage_mod()
        sync_bridge_mod()
    except Exception as exc:
        log("装技能出错：%r" % exc)
    last_skills = time.time()
    sampler = SysSampler()
    last_signatures = {}
    debug_state = {"scans": 0}
    last_emit = 0.0
    last_heartbeat = 0.0
    seen_once = False

    while True:
        try:
            snapshots = collect_snapshots(debug_state) + plugins.sessions()
            snapshots.sort(key=lambda item: item.get("startedAt") or 0)
            # 同一会话在两个窗口里同时开着（两个进程、同一 sessionId）：只报最后打开的那个，
            # 否则客户端按 id 建索引会撞车（Mac 端曾因此一启动就崩）
            snapshots = list({snap["sessionId"]: snap for snap in snapshots}.values())
            annotate_branches(snapshots)
            TERMS.annotate(snapshots)
            HOSTED.annotate(snapshots)
            snapshots = [snap for snap in snapshots if not unused_session(snap)]
            STAGES.annotate(snapshots)
            watcher.track(snapshots)
            GOALS.annotate(snapshots)
            write_live_sessions(snapshots)
            if time.time() - last_skills > SKILLS_RESYNC_SECONDS:
                last_skills = time.time()
                try:
                    sync_skills()
                    sync_limits_mod()
                    sync_stage_mod()
                    sync_bridge_mod()
                except Exception as exc:
                    log("装技能出错：%r" % exc)

            changed = False
            current_ids = set()
            for snap in snapshots:
                key = snap["sessionId"]
                current_ids.add(key)
                if last_signatures.get(key) != signature(snap):
                    changed = True
            if set(last_signatures.keys()) - current_ids:
                changed = True

            now = time.time()
            if changed or not seen_once or (now - last_emit) >= 5.0:
                emit({"event": "snapshots", "at": int(now * 1000), "sessions": snapshots})
                last_signatures = {snap["sessionId"]: signature(snap) for snap in snapshots}
                last_emit = now
                seen_once = True

            # 快照先于增量：客户端收到某会话的条目时，已经知道这个会话
            watcher.pump()

            sys_event = sampler.tick(now)
            if sys_event:
                emit(sys_event)

            if (now - last_heartbeat) >= HEARTBEAT_SECONDS:
                emit({"event": "heartbeat", "at": int(now * 1000), "count": len(snapshots)})
                last_heartbeat = now

        except BrokenPipeError:
            log("stdout closed, exiting")
            return 0
        except KeyboardInterrupt:
            return 0
        except Exception as exc:
            log("loop error: %r" % exc)
            try:
                emit({"event": "error", "message": "%r" % exc})
            except Exception:
                return 1

        # 等下一轮的同时处理请求：请求到了立即响应，不必等满一秒
        deadline = time.time() + TICK_SECONDS
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                break
            try:
                raw = inbox.get(timeout=remaining)
            except queue.Empty:
                break
            except KeyboardInterrupt:
                return 0
            try:
                watcher.respond(raw)
            except BrokenPipeError:
                return 0


# 任务阶段说明文字小模型的权重（见 stage_text_kind；重新训练：tools/stage-model/README.md）
_STAGE_TEXT_MODEL = (
    "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"
    "PfZ///f/AY+ZH3M="
)


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "console-io" and IS_WINDOWS:
        sys.exit(console_io_main(int(sys.argv[2])))
    if len(sys.argv) > 1 and sys.argv[1] == "hold":
        sys.exit(command_hold(sys.argv[2:]))
    if len(sys.argv) > 1 and sys.argv[1] == "attach":
        sys.exit(command_attach(sys.argv[2:]))
    if len(sys.argv) > 1 and sys.argv[1] == "send-image":
        sys.exit(command_send_image(sys.argv[2:]))
    if len(sys.argv) > 1 and sys.argv[1] == "send-page":
        sys.exit(command_send_page(sys.argv[2:]))
    if len(sys.argv) > 1 and sys.argv[1] == "prompt-link":
        sys.exit(command_prompt_link(sys.argv[2:]))
    if len(sys.argv) > 1 and sys.argv[1] == "shot":
        sys.exit(command_shot(sys.argv[2:]))
    if len(sys.argv) > 1 and sys.argv[1] == "report":
        sys.exit(command_report(sys.argv[2:]))
    if len(sys.argv) > 1 and sys.argv[1] == "e2e-setup":
        sys.exit(command_e2e_setup(sys.argv[2:]))
    if len(sys.argv) > 1 and sys.argv[1] == "todo":
        sys.exit(command_todo(sys.argv[2:]))
    if len(sys.argv) > 1 and sys.argv[1] == "keyinfo":
        sys.exit(command_keyinfo(sys.argv[2:]))
    if len(sys.argv) > 1 and sys.argv[1] == "stage":
        sys.exit(command_stage(sys.argv[2:]))
    if len(sys.argv) > 1 and sys.argv[1] == "group":
        sys.exit(command_group(sys.argv[2:]))
    if len(sys.argv) > 1 and sys.argv[1] == "limits":
        # 排查用：装上额度插件，打印这台电脑上读到的额度
        sync_limits_mod(claude_config_dir())
        print(json.dumps(read_limits(), ensure_ascii=False, indent=2))
        sys.exit(0)
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(0)
