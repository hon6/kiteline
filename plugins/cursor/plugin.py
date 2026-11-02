"""Cursor（编辑器和命令行 agent）：单独下发的插件，不随 Kiteline 发版。

接法全走 Cursor 公开的扩展点（11-01 对编辑器 3.27.22、命令行 2026.10.22 实测）：
  hooks    ~/.cursor/hooks.json（编辑器、命令行都读）里加几条带 kiteline 路径的命令，调起 assets/hook.py：
           只记录、一律回 allow（Cursor 只认 deny / ask，allow 等于不表态，用户原来的审批设置照常生效）。
           hook.py 把每一步记成 <数据目录>/cursor/events/<会话 id>.jsonl（中台按文件跟），元数据在 meta/<会话 id>.json。
  扩展     ~/.cursor/extensions 里装 assets/cursor-link（Kiteline for Cursor）：手机上点允许 / 拒绝 / 中断时，
           它在编辑器里按对话 id 调 Cursor 自己的命令（系统通知上那两个按钮用的就是它们），不碰键盘、不抢前台。
           新装的扩展要重启一次 Cursor 才生效。
  tmux     命令行 agent 在 tmux 里跑时，回复、确认（y / tab / shift+tab / esc）、中断、关闭都经中台的 term.tmux。
  排队     Cursor 正在工作时手机发的消息放进 queue/<会话 id>.json，这一轮结束时 stop hook 作为 followup_message 交给 Cursor 接着发。
  空闲发送 编辑器里的对话空闲时，send 回动作单（中台 ui.keys）：电脑端把项目窗口切到前台 → 扩展填字 → 电脑端按回车 → 还原前台
           （Cursor 没有给扩展「往已有对话里提交」的命令）。
  月用量   Cursor 不在本机记用量，只有它的服务器有：用户在设置 → 插件里打开「显示本月用量」（清单 options 的 usage，默认关）后，
           读 Cursor 存在本机的登录令牌，10 分钟问一次 DashboardService 的 GetCurrentPeriodUsage（Cursor 设置页那个数）。
状态：编辑器看它自己的 state.vscdb 里 composerHeaders 的 hasBlockingPendingActions（等你确认），命令行看 tmux 界面上的审批菜单。
"""
import glob
import json
import os
import re
import shlex
import shutil
import sqlite3
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
HOOK_EVENTS = ("sessionStart", "sessionEnd", "beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure",
               "afterAgentThought", "afterAgentResponse", "stop")
EXTENSION_ID = "kiteline.kiteline-cursor-link"
LIVE_HOURS = 12            # 编辑器里的对话：最近这么久有动静才列出来
BUSY_STALE = 30 * 60       # 「忙」超过这么久没有任何动静：当成已经停了（Cursor 被强关时收不到 stop）
KEEP_DAYS = 14             # 事件记录留这么久
BEAT_FRESH = 15            # 扩展的心跳多久以内算它还在
USAGE_BACKEND = "https://api2.cursor.sh"
USAGE_TTL, USAGE_RETRY = 600, 180   # 月用量：读到了 10 分钟内不再问，没读到 3 分钟后再试
EVENTS_KEEP_MS = 92 * 86400000      # 每次请求的用量（用量报表）：最多往前拿这么久
EVENTS_PAGE, EVENTS_PAGES = 100, 50   # 一页多少条、一次最多翻几页
# 命令行 agent 的审批菜单（tmux 界面上）
APPROVAL_MARKS = ("Run this command?", "Waiting for approval", "Skip & tell the agent")
CLI_OPTIONS = ({"key": "esc", "label": "拒绝", "labelEn": "Skip", "style": "destructive"},
               {"key": "y", "label": "运行", "labelEn": "Run", "style": "primary"},
               {"key": "tab", "label": "运行，并把这条命令加入白名单", "labelEn": "Run and add to allowlist", "style": "normal"},
               {"key": "shift+tab", "label": "全部运行（之后不再询问）", "labelEn": "Run everything", "style": "normal"})
IDE_OPTIONS = ({"key": "esc", "label": "拒绝", "labelEn": "Reject", "style": "destructive"},
               {"key": "1", "label": "允许", "labelEn": "Allow", "style": "primary"})
# 手机上只能看 / 某个操作做不了时给用户的说明（中文 + 英文，电脑端按设备语言挑）。都要说清楚原因和怎么才能用
READ_ONLY = {
    # 编辑器里的对话手机够不着：在 Cursor 的 Agents 窗口里（Agents 窗口不加载扩展）、项目没在编辑器窗口里开着，
    # 或者刚装好插件、Cursor 还没重启（扩展没生效）——从外面分不清，一句话都说到
    "agents": ("这个对话没有在 Cursor 的编辑器窗口中打开，暂不能从手机发消息和确认。请在 Cursor 右上角点「IDE」切换到编辑器窗口并打开这个项目"
               "（刚装好 Kiteline 插件时需先重启一次 Cursor），之后 Kiteline 会自动把对话转到编辑器窗口，就能从手机发消息、确认和中断了",
               "This chat isn't open in a Cursor editor window, so you can't send or confirm from your phone yet. Click \u201cIDE\u201d at "
               "the top right of Cursor to switch to an editor window and open this project (restart Cursor once if you just installed "
               "the Kiteline plugin); Kiteline then moves the chat to the editor window and you can send, confirm and stop from your phone."),
    # 电脑端的 Kiteline 太旧，还不会替插件按回车
    "update": ("从手机给 Cursor 编辑器里的对话发消息需要更新电脑上的 Kiteline。Cursor 正在工作时从手机发的消息会在这一轮结束后自动发出",
               "Sending messages to Cursor editor chats from your phone requires updating Kiteline on your computer. Messages sent "
               "while Cursor is working are delivered when the current turn ends."),
    "cli": ("这个 Cursor 命令行会话不在 tmux 中运行，只能查看；在 tmux 中启动 Cursor 命令行（agent）即可从手机回复和确认",
            "This Cursor CLI session isn't running in tmux, so it's view-only. Start the Cursor CLI (agent) in tmux to reply and "
            "confirm from your phone."),
    "remote": ("这个 Cursor 对话在远程工作区（Remote-SSH）中，无法从手机编辑，只能查看",
               "This Cursor chat is in a remote workspace (Remote-SSH). It can't be edited from your phone; view only."),
    # 等确认，但这一轮在 Agents 窗口里跑（编辑器窗口接不过来：这一轮属于开始它的那个窗口）
    "confirm": ("这一步请在电脑上的 Cursor 中确认：对话正在 Cursor 的 Agents 窗口中运行，手机无法替你确认。"
                "在 Cursor 右上角点「IDE」切换到编辑器窗口使用，之后的确认就能在手机上完成",
                "Please confirm this step in Cursor on your computer: the chat is running in Cursor's Agents window, which your phone "
                "can't confirm for you. Click \u201cIDE\u201d at the top right of Cursor to use an editor window, and later "
                "confirmations can be done from your phone."),
}
# 编辑器在等你确认哪条命令：它的 Agent Host 日志（数据库里的对话头不是实时写的，等确认时还是旧值）。
# 「preflight」行带对话 id 和工具调用 id，「prompting」开始等，「approval gate allowed / skipped」放行；拒绝没有带 id 的行，
# 靠之后的 hook（postToolUse）把元数据时间推到它后面。日志是 Cursor 自己的、格式可能变：认不出来就当不知道（不显示等确认）
LOG_LINE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d(?:\.\d+)?) \[\w+\] (.*?)(\{.*\})?\s*$")
# Cursor 的工具 → 手机认得的工具（改动对比、任务清单这些才画得出）；参数改名
TOOLS = {
    "Shell": ("Bash", {}),
    "Read": ("Read", {"path": "file_path"}),
    "Write": ("Write", {"path": "file_path", "contents": "content"}),
    "StrReplace": ("Edit", {"path": "file_path"}),
    "EditNotebook": ("NotebookEdit", {"path": "notebook_path"}),
    "Delete": ("Delete", {"path": "file_path"}),
    "Grep": ("Grep", {}),
    "Glob": ("Glob", {"glob_pattern": "pattern", "target_directory": "path"}),
    "WebSearch": ("WebSearch", {"search_term": "query"}),
    "WebFetch": ("WebFetch", {}),
    "TodoWrite": ("TodoWrite", {}),
    "Task": ("Task", {}),
}


def tool_of(name, args):
    args = dict(args) if isinstance(args, dict) else {}
    if name == "CallMcpTool":
        inner = args.get("arguments") if isinstance(args.get("arguments"), dict) else {}
        return "mcp__%s__%s" % (args.get("server") or "mcp", args.get("toolName") or "tool"), inner
    if isinstance(name, str) and name.startswith("MCP:"):
        return "mcp__" + name[4:], args
    mapped, rename = TOOLS.get(name, (name or "tool", {}))
    for old, new in rename.items():
        if old in args and new not in args:
            args[new] = args.pop(old)
    if mapped == "TodoWrite":
        args["todos"] = [dict(t, status="completed" if t.get("status") == "cancelled" else t.get("status") or "pending")
                         for t in args.get("todos") or [] if isinstance(t, dict)]
    return mapped, args


def within(path, folder):
    """path 是不是 folder 或它下面的目录"""
    path, folder = os.path.normcase(os.path.abspath(path)), os.path.normcase(os.path.abspath(folder))
    return path == folder or path.startswith(folder.rstrip(os.sep) + os.sep)


def short_path(path):
    """Windows：带空格的路径换成 8.3 短路径（hook 命令不用引号，PowerShell、cmd 都认）"""
    if " " not in path:
        return path
    try:
        import ctypes
        buffer = ctypes.create_unicode_buffer(1024)
        if ctypes.windll.kernel32.GetShortPathNameW(path, buffer, 1024):
            return buffer.value
    except Exception:
        pass
    return path


def create(kl):
    CURSOR = os.path.join(kl.HOME, ".cursor")
    HOOKS_JSON = os.path.join(CURSOR, "hooks.json")
    HOOK_DIR = os.path.join(CURSOR, "hooks", "kiteline")
    HOOK_FILE = os.path.join(HOOK_DIR, "hook.py")
    EXT_ROOT = os.path.join(CURSOR, "extensions")
    STATE = os.path.join(kl.DATA_DIR, "cursor")
    BOX = os.path.join(STATE, "ide")
    # 电脑端会不会替插件按键（ui.keys，随这个 watcher 一起发的电脑端都会）：编辑器空闲时从手机发消息靠它
    HOST_UI = "ui.keys" in getattr(kl, "HOST_CAPS", {})
    if sys.platform == "darwin":
        APP_DATA = os.path.join(kl.HOME, "Library", "Application Support", "Cursor")
    elif kl.IS_WINDOWS:
        APP_DATA = os.path.join(os.environ.get("APPDATA") or os.path.join(kl.HOME, "AppData", "Roaming"), "Cursor")
    else:
        APP_DATA = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(kl.HOME, ".config"), "Cursor")
    STATE_DB = os.path.join(APP_DATA, "User", "globalStorage", "state.vscdb")
    LOG_ROOT = os.path.join(APP_DATA, "logs")
    # 命令行的登录令牌（只装了命令行、没有编辑器时用）：Windows %APPDATA%\Cursor、Mac ~/.cursor、其他 $XDG_CONFIG_HOME/cursor
    if kl.IS_WINDOWS:
        CLI_AUTH = os.path.join(APP_DATA, "auth.json")
    elif sys.platform == "darwin":
        CLI_AUTH = os.path.join(CURSOR, "auth.json")
    else:
        CLI_AUTH = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(kl.HOME, ".config"), "cursor", "auth.json")

    def read_state(keys):
        """编辑器 state.vscdb 里的几项（ItemTable，只读打开）→ {键: 值}"""
        out = {}
        if os.path.isfile(STATE_DB):
            try:
                db = sqlite3.connect("file:%s?mode=ro" % STATE_DB.replace("\\", "/").replace("?", "%3f"), uri=True, timeout=1)
                try:
                    marks = ",".join("?" * len(keys))
                    for key, value in db.execute("select key, value from ItemTable where key in (%s)" % marks, tuple(keys)):
                        out[key] = value.decode("utf-8", "replace") if isinstance(value, bytes) else value
                finally:
                    db.close()
            except sqlite3.Error:
                pass
        return out

    def cursor_login():
        """Cursor 的登录令牌和服务器地址：先看编辑器的，没有再看命令行的 → (令牌, 地址)；没登录返回 (None, None)"""
        state = read_state(("cursorAuth/accessToken", "cursorAuth/storedServerBackendUrl"))
        token = state.get("cursorAuth/accessToken")
        if not token:
            try:
                with open(CLI_AUTH, encoding="utf-8") as handle:
                    token = (json.load(handle) or {}).get("accessToken")
            except (OSError, ValueError, AttributeError):
                token = None
        backend = state.get("cursorAuth/storedServerBackendUrl") or ""
        if not backend.startswith("https://"):
            backend = USAGE_BACKEND
        return (str(token) if token else None), backend.rstrip("/")

    def tls_context():
        """系统根证书再加上 certifi 的（有就加）：Windows 的根证书用到才下载，新装的系统里常常没有 Cursor 服务器用的
        Amazon 根证书（Cursor 自己带一套所以它连得上），Python 只认已经有的；Windows / Linux 版 Kiteline 打包时带着 certifi"""
        context = ssl.create_default_context()
        try:
            import certifi
            context.load_verify_locations(certifi.where())
        except (ImportError, OSError, ssl.SSLError):
            pass
        return context

    def dashboard(backend, token, method, body=None):
        """Cursor 服务器的 DashboardService（Connect 协议的 JSON 形式），设置页查用量、套餐用的就是它"""
        request = urllib.request.Request("%s/aiserver.v1.DashboardService/%s" % (backend, method), data=json.dumps(body or {}).encode(),
                                         method="POST",
                                         headers={"Authorization": "Bearer " + token, "Content-Type": "application/json",
                                                  "Connect-Protocol-Version": "1"})
        with urllib.request.urlopen(request, timeout=10, context=tls_context()) as response:
            return json.loads(response.read() or b"{}")

    class HostLog:
        """跟 Cursor Agent Host 的日志（每个窗口一份，见上面 LOG_LINE 的说明）：哪个对话在等你确认"""

        def __init__(self):
            self.offsets = {}     # 日志文件 → 读到哪
            self.tools = {}       # 工具调用 id → 对话 id
            self.prompts = {}     # 对话 id → (工具调用 id, 开始等的时间)
            self.scanned = 0

        def poll(self):
            if time.time() - self.scanned < 1:
                return
            self.scanned = time.time()
            for session in sorted(glob.glob(os.path.join(LOG_ROOT, "*")), reverse=True)[:2]:   # 最近两次启动
                for path in glob.glob(os.path.join(session, "window*", "exthost", "anysphere.cursor-agent-host", "Cursor Agent Host*.log")):
                    if re.search(r"Network|Storage|debug", os.path.basename(path)):
                        continue
                    try:
                        size = os.path.getsize(path)
                        if time.time() - os.path.getmtime(path) > 6 * 3600:
                            continue
                        offset = self.offsets.get(path)
                        offset = max(0, size - 256 * 1024) if offset is None or offset > size else offset
                        with open(path, "rb") as handle:
                            handle.seek(offset)
                            data = handle.read(min(size - offset, 4 * 1024 * 1024))
                    except OSError:
                        continue
                    end = data.rfind(b"\n") + 1
                    self.offsets[path] = offset + end
                    for raw in data[:end].decode("utf-8", "replace").splitlines():
                        self.feed(raw)

        def feed(self, line):
            found = LOG_LINE.match(line)
            if not found:
                return
            message = found.group(2).strip()
            try:
                data = json.loads(found.group(3)) if found.group(3) else {}
            except ValueError:
                data = {}
            tool = data.get("toolCallId") if isinstance(data, dict) else None
            if not tool:
                return
            if data.get("conversationId"):
                self.tools[tool] = data["conversationId"]
                if len(self.tools) > 2000:
                    self.tools = dict(list(self.tools.items())[-1000:])
            if message.startswith("Shell permissions: prompting") and tool in self.tools:
                stamp, _, frac = found.group(1).partition(".")
                try:
                    when = time.mktime(time.strptime(stamp, "%Y-%m-%d %H:%M:%S")) + float("0." + (frac or "0"))
                except ValueError:
                    return
                self.prompts[self.tools[tool]] = (tool, when)
            elif re.search(r"approval gate (allowed|denied|rejected)|skipped local approval", message):
                for cid, (pending, _) in list(self.prompts.items()):
                    if pending == tool:
                        del self.prompts[cid]

        def waiting(self, cid, updated):
            """在等：开始等之后没有再来过 hook（放行、拒绝后 Cursor 都会报 postToolUse，元数据的时间就到它后面了）"""
            prompt = self.prompts.get(cid)
            return bool(prompt) and prompt[1] * 1000 > updated - 300

    def cursor_normalize(offset, entry):
        """events/<会话>.jsonl 的一行 → 对话项（格式同内置插件）"""
        if not isinstance(entry, dict):
            return []
        kind, ts, items = entry.get("e"), entry.get("ts"), []

        def base():
            return {"id": "%d.%d" % (offset, len(items)), "ts": ts}

        if kind == "user":
            text, _ = kl.clip(entry.get("text") or "", kl.USER_TEXT_MAX)
            files = [f for f in entry.get("files") or [] if isinstance(f, str)]
            if files:
                text = (text + "\n" + "\n".join("@" + f for f in files)).strip()
            if text:
                items.append(dict(base(), t="user", text=text))
        elif kind in ("text", "thinking"):
            text, _ = kl.clip(entry.get("text") or "", kl.ASSISTANT_TEXT_MAX)
            if text:
                items.append(dict(base(), t=kind, text=text))
        elif kind == "tool":
            name, args = tool_of(entry.get("name"), entry.get("input"))
            items.append(dict(base(), t="tool", toolId=entry.get("id"), name=name, brief=kl.tool_brief(name, args), input=kl.shrink(args)))
        elif kind == "result":
            text, _ = kl.clip(entry.get("text") or "", kl.TOOL_RESULT_MAX)
            items.append(dict(base(), t="result", toolId=entry.get("id"), text=text, isError=bool(entry.get("error"))))
        elif kind == "stop" and entry.get("status") == "aborted":
            items.append(dict(base(), t="event", text="已中断"))
        elif kind == "stop" and entry.get("status") == "error":
            items.append(dict(base(), t="event", level="error", text="出错"))
        return items

    def write_json(path, data, indent=None):
        tmp = path + ".kl%d.tmp" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=indent)
            handle.write("\n" if indent else "")
        os.replace(tmp, path)

    def read_json(path):
        try:
            with open(path, encoding="utf-8") as handle:
                return json.load(handle)
        except (OSError, ValueError):
            return None

    def copy_if_changed(source, target):
        try:
            with open(source, "rb") as handle:
                data = handle.read()
            try:
                with open(target, "rb") as handle:
                    if handle.read() == data:
                        return False
            except OSError:
                pass
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target + ".tmp", "wb") as handle:
                handle.write(data)
            os.replace(target + ".tmp", target)
            return True
        except OSError as exc:
            kl.log("Cursor 插件：复制 %s 失败：%r" % (source, exc))
            return False

    def hook_command():
        """调起 hook.py 的命令：用跑 watcher 的这个 Python（Windows 打包版是 Kiteline.exe --run-script），用户不用另装 Python"""
        parts = [sys.executable] + (["--run-script"] if getattr(sys, "frozen", False) else []) + [HOOK_FILE, STATE]
        if kl.IS_WINDOWS:   # 编辑器经 PowerShell 跑 hook：不带引号的短路径两边都认
            return " ".join(short_path(p) if os.path.isabs(p) else p for p in parts)
        return " ".join(shlex.quote(p) for p in parts)

    def is_ours(entry):
        command = entry.get("command") if isinstance(entry, dict) else None
        return isinstance(command, str) and re.search(r"hooks[\\/]+kiteline[\\/]+hook\.py", command) is not None

    def install_hooks():
        """hooks.json 里合并我们那几条（别人的原样保留）；文件坏了不动它"""
        if not copy_if_changed(os.path.join(HERE, "assets", "hook.py"), HOOK_FILE) and not os.path.isfile(HOOK_FILE):
            return
        config = read_json(HOOKS_JSON) if os.path.exists(HOOKS_JSON) else {"version": 1, "hooks": {}}
        if not isinstance(config, dict) or not isinstance(config.setdefault("hooks", {}), dict):
            kl.log("Cursor 插件：%s 不是有效的 JSON，没有改它" % HOOKS_JSON)
            return
        hooks, command, changed = config["hooks"], hook_command(), False
        for event in list(hooks.keys()) + [e for e in HOOK_EVENTS if e not in hooks]:
            entries = hooks.get(event) if isinstance(hooks.get(event), list) else []
            want = []
            if event in HOOK_EVENTS:   # stop 的 followup 不限次数：手机排队的消息每轮都要能接着发
                want = [dict({"command": command, "timeout": 10}, **({"loop_limit": None} if event == "stop" else {}))]
            if [e for e in entries if is_ours(e)] == want:
                continue
            rest = [e for e in entries if not is_ours(e)] + want
            if rest:
                hooks[event] = rest
            else:
                hooks.pop(event, None)
            changed = True
        config.setdefault("version", 1)
        if changed:
            write_json(HOOKS_JSON, config, indent=2)
            kl.log("Cursor 插件：已在 %s 加上 Kiteline 的 hook" % HOOKS_JSON)

    def remove_hooks():
        config = read_json(HOOKS_JSON)
        if isinstance(config, dict) and isinstance(config.get("hooks"), dict):
            hooks = config["hooks"]
            if any(is_ours(e) for entries in hooks.values() if isinstance(entries, list) for e in entries):
                for event in list(hooks.keys()):
                    if isinstance(hooks[event], list):
                        hooks[event] = [e for e in hooks[event] if not is_ours(e)]
                        if not hooks[event]:
                            del hooks[event]
                write_json(HOOKS_JSON, config, indent=2)
        shutil.rmtree(HOOK_DIR, ignore_errors=True)

    def extension_version():
        manifest = read_json(os.path.join(HERE, "assets", "cursor-link", "package.json")) or {}
        return str(manifest.get("version") or "0")

    def install_extension():
        """装 Kiteline for Cursor 扩展（只在用过 Cursor 编辑器、有扩展目录时）：文件 + extensions.json 里登记一条"""
        if not os.path.isdir(EXT_ROOT):
            return
        version = extension_version()
        name = "%s-%s" % (EXTENSION_ID, version)
        folder = os.path.join(EXT_ROOT, name)
        source = os.path.join(HERE, "assets", "cursor-link")
        for file in ("package.json", "extension.js"):
            copy_if_changed(os.path.join(source, file), os.path.join(folder, file))
        if read_json(os.path.join(folder, "kiteline.json")) != {"dir": BOX}:
            write_json(os.path.join(folder, "kiteline.json"), {"dir": BOX})
        for old in glob.glob(os.path.join(EXT_ROOT, EXTENSION_ID + "-*")):
            if os.path.basename(old) != name:
                shutil.rmtree(old, ignore_errors=True)
        registry = os.path.join(EXT_ROOT, "extensions.json")
        entries = read_json(registry) if os.path.exists(registry) else []
        if not isinstance(entries, list):
            return
        mine = [e for e in entries if isinstance(e, dict) and (e.get("identifier") or {}).get("id") == EXTENSION_ID]
        if len(mine) == 1 and mine[0].get("version") == version:
            return
        posix = folder.replace("\\", "/")
        uri = "file://" + ("/" + posix if not posix.startswith("/") else posix)
        entries = [e for e in entries if e not in mine] + [{
            "identifier": {"id": EXTENSION_ID}, "version": version,
            "location": {"$mid": 1, "fsPath": folder, "external": uri, "path": posix if posix.startswith("/") else "/" + posix, "scheme": "file"},
            "relativeLocation": name,
            "metadata": {"installedTimestamp": int(time.time() * 1000), "source": "vsix", "pinned": True}}]
        write_json(registry, entries)
        kl.log("Cursor 插件：已装 Kiteline for Cursor 扩展 %s（重启 Cursor 后生效）" % version)

    def remove_extension():
        for old in glob.glob(os.path.join(EXT_ROOT, EXTENSION_ID + "-*")):
            shutil.rmtree(old, ignore_errors=True)
        registry = os.path.join(EXT_ROOT, "extensions.json")
        entries = read_json(registry)
        if isinstance(entries, list):
            kept = [e for e in entries if not (isinstance(e, dict) and (e.get("identifier") or {}).get("id") == EXTENSION_ID)]
            if len(kept) != len(entries):
                write_json(registry, kept)

    def prune():
        """两周没动的事件记录、残留的信箱文件删掉"""
        cutoff = time.time() - KEEP_DAYS * 86400
        for path in glob.glob(os.path.join(STATE, "events", "*.jsonl")) + glob.glob(os.path.join(STATE, "meta", "*.json")):
            try:
                if os.path.getmtime(path) < cutoff:
                    os.remove(path)
            except OSError:
                pass
        for path in glob.glob(os.path.join(BOX, "req-*.json")) + glob.glob(os.path.join(BOX, "ack-*.json")):
            try:
                if os.path.getmtime(path) < time.time() - 60:
                    os.remove(path)
            except OSError:
                pass

    class Cursor(kl.AgentPlugin):
        name = "Cursor"

        def __init__(self):
            self.metas = {}        # 会话 id → (元数据文件的修改时间, 元数据)
            self.snaps = {}        # 会话 id → 最近一次的快照里用到的东西（发消息、按键时用）
            self.headers = (0, {})
            self.titles = {}
            self.installed = 0
            self.log = HostLog()
            self.running = (0, False)   # (查的时间, Cursor 编辑器在不在运行)
            self.fills = {}             # 会话 id → 等电脑端切好窗口再填的字（send 回动作单、ui_step 填）
            self.month = (0.0, None)    # (上次问月用量的时间, 读数)
            self.usage_error = None
            # 每次请求的用量（用量报表）：事件 id → 记录；已经拿到的时间段；上次拿到、上次试的时间
            self.events, self.events_span, self.events_at, self.events_tried = {}, None, 0.0, 0.0
            self.events_lock = threading.Lock()

        normalize = staticmethod(cursor_normalize)

        def detect(self):
            versions = sorted(glob.glob(os.path.join(kl.HOME, ".local", "share", "cursor-agent", "versions", "*")))
            cli = os.path.basename(versions[-1]) if versions else ("" if shutil.which("cursor-agent") else None)
            desktop = kl.app_version("/Applications/Cursor.app") if sys.platform == "darwin" else None
            if desktop is None and (os.path.isfile(STATE_DB) or shutil.which("cursor")):
                desktop = ""
            forms = {k: v for k, v in (("desktop", desktop), ("cli", cli)) if v is not None}
            return {"installed": os.path.isdir(CURSOR) or bool(forms), "forms": forms}

        def start(self):
            self.ensure()

        def limits(self):
            """本月用量（「今日用量」卡片）：用户打开了「显示本月用量」才查（老中台没有单项开关，按关着处理）。
            读 Cursor 存在本机的登录令牌问它的服务器——和 Cursor 设置页显示的同一个数；令牌只在本机用"""
            option_on = getattr(self, "option_on", None)
            if option_on is None or not option_on("usage"):
                return None
            asked, reading = self.month
            if time.time() - asked < (USAGE_TTL if reading else USAGE_RETRY):
                return reading
            fresh, failed = None, False
            token, backend = cursor_login()
            if token:
                try:
                    usage = dashboard(backend, token, "GetCurrentPeriodUsage")
                    plan = (usage.get("planUsage") or {}) if isinstance(usage, dict) else {}
                    if plan.get("totalPercentUsed") is not None:
                        try:
                            name = (dashboard(backend, token, "GetPlanInfo").get("planInfo") or {}).get("planName")
                        except (OSError, ValueError, urllib.error.URLError):
                            name = (reading or {}).get("plan")
                        end = int(usage.get("billingCycleEnd") or 0) or None
                        fresh = {"at": int(time.time() * 1000), "plan": name or None,
                                 "windows": [{"kind": "month", "percent": round(max(0.0, float(plan["totalPercentUsed"])), 1), "resetsAt": end}]}
                    self.usage_error = None
                except urllib.error.HTTPError as exc:
                    # 401 / 403：令牌过期或退出了登录（Cursor 自己会刷新令牌，下次再试）
                    failed = exc.code not in (401, 403)
                    self.note_usage_error("HTTP %d" % exc.code)
                except (OSError, ValueError, urllib.error.URLError) as exc:
                    failed = True
                    self.note_usage_error(repr(exc))
            # 一时连不上：上次的读数一天内照样给（卡片上写着是多久前的）
            if fresh is None and failed and reading and time.time() * 1000 - reading["at"] < 86400000:
                fresh = reading
            self.month = (time.time(), fresh)
            return fresh

        def usage(self, since_ms):
            """token 用量（用量报表）：Cursor 本机不记，同样是打开了「显示本月用量」才问它的服务器（GetFilteredUsageEvents：
            每次请求的时间、模型、token、花费和对话 id，对话 id 对上 hook 记的项目目录）。10 分钟内不重复问，只补新的
            （和上次接上、重叠 10 分钟），要更早的再往前补，最多 92 天"""
            option_on = getattr(self, "option_on", None)
            if option_on is None or not option_on("usage"):
                return []
            now = int(time.time() * 1000)
            since_ms = max(int(since_ms), now - EVENTS_KEEP_MS)
            with self.events_lock:
                span = self.events_span
                ranges = []
                if span is None or since_ms < span[0]:
                    ranges.append((since_ms, span[0] if span else now))
                if span is not None and time.time() - self.events_at >= USAGE_TTL:
                    ranges.append((span[1] - 600000, now))
                if ranges and time.time() - self.events_tried >= USAGE_RETRY:
                    self.events_tried = time.time()
                    token, backend = cursor_login()
                    try:
                        for begin, end in (ranges if token else []):
                            self.fetch_events(backend, token, begin, end)
                            span = (min(begin, span[0]), max(end, span[1])) if span else (begin, end)
                            self.events_span, self.events_at = span, time.time()
                    except urllib.error.HTTPError as exc:
                        self.note_usage_error("HTTP %d" % exc.code)
                    except (OSError, ValueError, urllib.error.URLError) as exc:
                        self.note_usage_error(repr(exc))
                out = []
                for event in self.events.values():
                    if event["ts"] >= since_ms:
                        meta = self.meta(event["session"]) if event["session"] else None
                        out.append(dict(event, cwd=((meta or {}).get("roots") or [None])[0]))
                return out

        def fetch_events(self, backend, token, begin, end):
            for page in range(1, EVENTS_PAGES + 1):
                data = dashboard(backend, token, "GetFilteredUsageEvents",
                                 {"startDate": str(begin), "endDate": str(end), "page": page, "pageSize": EVENTS_PAGE})
                rows = [r for r in (data.get("usageEventsDisplay") or []) if isinstance(r, dict)] if isinstance(data, dict) else []
                for row in rows:
                    tokens = row.get("tokenUsage") if isinstance(row.get("tokenUsage"), dict) else {}
                    cents = tokens.get("totalCents")
                    key = row.get("usageEventId") or "%s-%s" % (row.get("timestamp"), row.get("model"))
                    self.events[key] = {"ts": int(row.get("timestamp") or 0), "model": row.get("model") or "unknown",
                                        "session": row.get("conversationId") or None,
                                        "input": int(tokens.get("inputTokens") or 0), "output": int(tokens.get("outputTokens") or 0),
                                        "cacheRead": int(tokens.get("cacheReadTokens") or 0), "cacheWrite": int(tokens.get("cacheWriteTokens") or 0),
                                        "requests": 1, "cost": cents / 100.0 if isinstance(cents, (int, float)) else None}
                if len(rows) < EVENTS_PAGE or page * EVENTS_PAGE >= int(data.get("totalUsageEventsCount") or 0):
                    break
            cutoff = int(time.time() * 1000) - EVENTS_KEEP_MS
            for key in [k for k, v in self.events.items() if v["ts"] < cutoff]:
                self.events.pop(key, None)

        def note_usage_error(self, text):
            if text != self.usage_error:
                self.usage_error = text
                kl.log("Cursor 查月用量出错：%s" % text)

        def ensure(self):
            """装 hook 和扩展（只在用过 Cursor 的电脑上）；每 10 分钟对一遍，被用户或 Cursor 改掉了就补回来"""
            if time.time() - self.installed < 600 or not os.path.isdir(CURSOR):
                return
            self.installed = time.time()
            for folder in ("meta", "events", "queue", "ide"):
                os.makedirs(os.path.join(STATE, folder), exist_ok=True)
            install_hooks()
            install_extension()
            prune()

        def disable(self):
            remove_hooks()
            remove_extension()

        # --- 读 ---

        def meta(self, cid):
            path = os.path.join(STATE, "meta", cid + ".json")
            try:
                mtime = os.path.getmtime(path)
            except OSError:
                return None
            cached = self.metas.get(cid)
            if cached and cached[0] == mtime:
                return cached[1]
            data = read_json(path)
            if isinstance(data, dict):
                self.metas[cid] = (mtime, data)
                return data
            return cached[1] if cached else None

        def ide_headers(self):
            """编辑器自己记的对话头：标题、最后一句、归档没有（不是实时写的，等不等确认看 HostLog）。2 秒内不重复读"""
            if time.time() - self.headers[0] < 2:
                return self.headers[1]
            out = {}
            if os.path.isfile(STATE_DB):
                try:
                    db = sqlite3.connect("file:%s?mode=ro" % STATE_DB.replace("\\", "/").replace("?", "%3f"), uri=True, timeout=1)
                    try:
                        for cid, archived, value in db.execute("select composerId, isArchived, value from composerHeaders"):
                            try:
                                head = json.loads(value) if value else {}
                            except ValueError:
                                head = {}
                            head["archived"] = bool(archived)
                            out[cid] = head
                    finally:
                        db.close()
                except sqlite3.Error:
                    pass
            self.headers = (time.time(), out)
            return out

        def cli_title(self, cid):
            if cid not in self.titles:
                found = glob.glob(os.path.join(CURSOR, "chats", "*", cid, "meta.json"))
                self.titles[cid] = found[0] if found else None
            data = read_json(self.titles[cid]) if self.titles[cid] else None
            return (data or {}).get("title") if isinstance(data, dict) else None

        def editor_running(self):
            """Cursor 编辑器在不在运行（5 秒内不重复查）"""
            if time.time() - self.running[0] < 5:
                return self.running[1]
            running = False
            try:
                if kl.IS_WINDOWS:
                    out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq Cursor.exe", "/NH"], capture_output=True, text=True,
                                         timeout=5, creationflags=0x08000000).stdout
                    running = "cursor.exe" in out.lower()
                elif sys.platform == "darwin":
                    running = subprocess.run(["pgrep", "-x", "Cursor"], capture_output=True, timeout=5).returncode == 0
                else:
                    for comm in glob.glob("/proc/[0-9]*/comm"):
                        try:
                            with open(comm) as handle:
                                if handle.read().strip().lower() == "cursor":
                                    running = True
                                    break
                        except OSError:
                            pass
            except (OSError, subprocess.SubprocessError):
                running = False
            self.running = (time.time(), running)
            return running

        def agent_pid(self, meta):
            """hook 记下的进程链里那个长期在的（命令行的 cursor-agent / 编辑器的扩展进程）：跳过调起 hook 的 shell；Windows 没有"""
            for pid, name in meta.get("pids") or []:
                if not re.match(r"^-?(ba|z|da|fi|c|k|tc)?sh$|^tmux|^login$|^systemd|^sshd|^screen", str(name), re.I):
                    return int(pid)
            return None

        def beats(self):
            """装了扩展的编辑器窗口（扩展进程 → 心跳）：开着哪些对话、打开了哪些项目。Cursor 的 Agents 窗口不加载扩展，不在这里"""
            out = {}
            for path in glob.glob(os.path.join(BOX, "win-*.json")):
                data = read_json(path)
                if isinstance(data, dict) and time.time() * 1000 - (data.get("ts") or 0) < BEAT_FRESH * 1000:
                    out[int(data.get("pid") or 0)] = data
            return out

        def windows_for(self, cid, cwd, beats):
            """能处理这个对话的编辑器窗口 → (开着这个对话的, 打开了它所在项目的)。后一种发消息时由扩展在那里打开它"""
            opened = [pid for pid, beat in beats.items() if cid in (beat.get("open") or [])]
            near = [pid for pid, beat in beats.items() if pid not in opened and cwd
                    and any(within(cwd, folder) for folder in beat.get("folders") or [])]
            return opened, near

        def unreachable(self, opened, near):
            """编辑器里的对话手机够不着时的说明（没有哪个装了扩展的编辑器窗口开着它或它的项目）"""
            return None if opened or near else READ_ONLY["agents"]

        def pane_text(self, pane):
            try:
                out = subprocess.run(["tmux", "capture-pane", "-p", "-t", pane], capture_output=True, text=True, timeout=3).stdout
            except (OSError, subprocess.SubprocessError):
                return ""
            return "\n".join(out.rstrip().splitlines()[-16:])

        def sessions(self):
            self.ensure()
            out, now = [], time.time()
            headers, beats = None, None
            self.log.poll()
            paths = glob.glob(os.path.join(STATE, "meta", "*.json"))
            for path in paths:
                cid = os.path.basename(path)[:-5]
                try:
                    if now - os.path.getmtime(path) > 24 * 3600:
                        continue
                except OSError:
                    continue
                meta = self.meta(cid)
                if not meta or meta.get("state") == "ended":
                    continue
                form = meta.get("form") or "ide"
                pid = self.agent_pid(meta)
                alive = kl.pid_alive(pid) if pid else None
                updated = int(meta.get("updated") or 0)
                restarted = alive is False and form == "ide" and self.editor_running()
                if restarted:
                    alive = None   # Cursor 重启过（扩展进程换了）：对话都还在，按时间算
                if alive is False:
                    continue
                state = "idle" if restarted else meta.get("state") or "idle"   # 重启前跑着的那一轮已经停了
                if state == "busy" and now * 1000 - updated > BUSY_STALE * 1000:
                    state = "idle"
                head = {}
                if form == "ide":
                    if headers is None:
                        headers, beats = self.ide_headers(), self.beats()
                    head = headers.get(cid) or {}
                    if head.get("archived") or (state != "busy" and now * 1000 - updated > LIVE_HOURS * 3600 * 1000):
                        continue
                elif alive is None and now * 1000 - updated > LIVE_HOURS * 3600 * 1000:
                    continue   # Windows 上的命令行会话（看不了进程）：同编辑器按时间
                pane = meta.get("pane") if form == "cli" and pid and shutil.which("tmux") and kl.find_tmux_pane(pid) else None
                waiting = False
                if form == "ide":
                    waiting = not restarted and self.log.waiting(cid, updated)
                elif pane:
                    waiting = any(mark in self.pane_text(pane) for mark in APPROVAL_MARKS)
                if waiting:
                    state = "busy"
                calls = {c.get("id"): c for c in meta.get("calls") or []}
                current = calls.get(meta.get("current"))
                tool, args = tool_of(current.get("tool"), current.get("input")) if current else (None, {})
                remote = bool(meta.get("remote"))
                cwd = (meta.get("roots") or [""])[0] or ""
                opened, near = self.windows_for(cid, cwd, beats or {}) if form == "ide" else ([], [])
                # 能不能从手机操作，不能就说清楚为什么、怎么才能用：
                #   命令行：在 tmux 里全都能；不在只能看（忙时发的消息照样排队）
                #   编辑器：开着它的编辑器窗口里能确认、中断；空闲时发消息要电脑端按回车（ui.keys）、项目在编辑器窗口里开着；
                #          Agents 窗口里的（扩展不在那里）只能看；忙时发的消息排队；远程工作区只能看
                reason = None
                if remote:
                    reason = READ_ONLY["remote"]
                elif form == "cli":
                    reason = None if pane or state == "busy" else READ_ONLY["cli"]
                elif waiting:
                    reason = None if opened else READ_ONLY["confirm"]
                elif state != "busy":
                    reason = self.unreachable(opened, near) or (None if HOST_UI else READ_ONLY["update"])
                can_reply = reason is None
                if waiting:
                    activity, why = "waiting", "等待确认：%s" % kl.tool_brief(tool, args) if tool else "等待确认"
                elif state == "busy":
                    activity, why = "busy", ("正在运行 %s" % kl.tool_brief(tool, args)) if tool else "正在工作"
                else:
                    activity, why = "idle", meta.get("message")
                title = (head.get("name") if form == "ide" else self.cli_title(cid)) or (meta.get("first") or "")[:60] or cid[:8]
                events = os.path.join(STATE, "events", cid + ".jsonl")
                snap = {
                    "pid": pid or 0, "sessionId": cid, "name": title, "title": title, "cwd": cwd, "cwdShort": kl.display_cwd(cwd) if cwd else "",
                    "status": activity, "waitingFor": ("等待你确认 %s" % kl.tool_brief(tool, args)) if waiting and tool else ("等待你确认" if waiting else None),
                    "needs": None, "detail": None, "activity": activity, "reason": why, "activityText": None,
                    "message": meta.get("message"), "messageUuid": None, "error": None, "effort": None,
                    "subagents": 0, "pendingTool": tool if waiting else None, "pendingId": current.get("id") if waiting and current else None,
                    "startedAt": meta.get("started"), "statusUpdatedAt": updated, "updatedAt": updated,
                    "version": meta.get("version"), "entrypoint": "cursor-" + form, "sessionKind": None, "tmuxPane": pane,
                    "usage": None, "transcriptPath": events if os.path.isfile(events) else None, "transcriptUpdatedAt": updated,
                    "agent": "cursor", "model": meta.get("model"),
                    "readOnly": not can_reply, "readOnlyReason": reason[0] if reason else None, "readOnlyReasonEn": reason[1] if reason else None,
                }
                if waiting:
                    snap["pendingOptions"] = [dict(o) for o in (CLI_OPTIONS if pane else IDE_OPTIONS if can_reply else ())]
                out.append(snap)
                self.snaps[cid] = {"form": form, "pid": pid, "pane": pane, "state": state, "waiting": waiting, "opened": opened,
                                   "near": near, "remote": remote, "cwd": cwd, "updated": updated}
            return out

        # --- 操作 ---

        def info(self, sid):
            info = self.snaps.get(sid)
            if info is None:
                raise RuntimeError("找不到这个 Cursor 对话，它可能已经关闭")
            return info

        def ide_call(self, cmd, sid, windows, **extra):
            """经 Kiteline for Cursor 扩展在这些编辑器窗口里执行（见 assets/cursor-link/extension.js）"""
            os.makedirs(BOX, exist_ok=True)
            rid = uuid.uuid4().hex[:12]
            write_json(os.path.join(BOX, "req-%s.json" % rid), dict(extra, id=rid, cmd=cmd, composerId=sid, pids=list(windows),
                                                                    ts=int(time.time() * 1000)))
            ack, deadline = None, time.time() + 6
            try:
                while time.time() < deadline and ack is None:
                    for path in glob.glob(os.path.join(BOX, "ack-%s-*.json" % rid)):
                        data = read_json(path)   # 读到半截（还没写完）就下一轮再读
                        if isinstance(data, dict):
                            ack = data
                    time.sleep(0.1)
            finally:
                for path in [os.path.join(BOX, "req-%s.json" % rid)] + glob.glob(os.path.join(BOX, "ack-%s-*.json" % rid)):
                    try:
                        os.remove(path)
                    except OSError:
                        pass
            if ack is None:
                raise RuntimeError("Cursor 没有响应（编辑器窗口可能正忙或已关闭），请稍后重试")
            if ack.get("error") == "unknown request":   # 还是旧版扩展（插件更新后 Cursor 没重启）
                raise RuntimeError("Kiteline 的 Cursor 扩展需要更新：请重启一次 Cursor 后重试")
            if "clipboard" in str(ack.get("error") or ""):
                raise RuntimeError("Cursor 没能把文字粘进输入框（剪贴板暂时写不进去），请重试")
            if not ack.get("ok"):
                raise RuntimeError("Cursor 没能执行：%s" % (ack.get("error") or "未知原因"))
            return ack

        def settled(self, sid, info):
            """允许 / 拒绝之后，Cursor 真的不等了没有（这一轮在 Agents 窗口里跑的话，编辑器窗口的命令不起作用）"""
            deadline = time.time() + 3
            while time.time() < deadline:
                time.sleep(0.3)
                self.log.scanned = 0
                self.log.poll()
                meta = self.meta(sid) or {}
                if not self.log.waiting(sid, int(meta.get("updated") or info["updated"])):
                    return True
            return False

        def send(self, sid, text, images):
            info = self.info(sid)
            if images:
                text = (text + "\n" + "\n".join(images)).strip()
            if not text:
                raise RuntimeError("消息是空的")
            if info["remote"]:
                raise RuntimeError(READ_ONLY["remote"][0])
            if info["pane"]:
                if info["waiting"]:
                    raise RuntimeError("Cursor 正在等你确认，请先在确认卡片中作出选择")
                kl.tmux_send(info["pid"], text, [], True)
                return "已发送"
            if info["state"] == "busy":
                path = os.path.join(STATE, "queue", sid + ".json")
                queued = read_json(path)
                queued = queued if isinstance(queued, list) else []
                queued.append({"text": text, "ts": int(time.time() * 1000)})
                os.makedirs(os.path.dirname(path), exist_ok=True)
                write_json(path, queued)
                return "Cursor 正在工作，这条消息会在这一轮结束后自动发出"
            if info["form"] != "ide":
                raise RuntimeError(READ_ONLY["cli"][0])
            # 编辑器空闲：动作单交给电脑端（Cursor 没有「提交」的命令，要真按回车）——
            #   把 Cursor 里开着这个对话（或这个项目）的窗口切到前台 → 回头请插件填字（ui_step）：扩展在这个窗口里打开对话、
            #   聚焦输入框、粘贴（窗口在前台才粘：Wayland 上后台窗口写不了剪贴板，会粘出旧内容）→ 核对前台后按回车。
            # Agents 窗口里的对话就这样转到编辑器窗口里接着用
            blocked = self.unreachable(info["opened"], info["near"])
            if blocked:
                raise RuntimeError(blocked[0])
            if "keys" not in getattr(self, "host_ui", ()):
                raise RuntimeError(READ_ONLY["update"][0])
            window = (info["opened"] or info["near"])[0]
            beat = self.beats().get(window) or {}
            folders = [f for f in beat.get("folders") or [] if within(info["cwd"], f)] or list(beat.get("folders") or [])
            self.fills[sid] = {"text": text, "window": window, "ts": time.time()}
            return {"message": "已发送", "ui": [{"do": "focus", "app": "cursor", "folder": folders[0] if folders else info["cwd"]},
                                                {"do": "plugin", "step": "fill"}, {"do": "key", "name": "enter"}]}

        def ui_step(self, sid, step):
            """动作单里的「填字」：电脑端已经把 Cursor 窗口切到前台，扩展打开这个对话、聚焦输入框、粘贴（不提交）"""
            fill = self.fills.pop(sid, None)
            if step != "fill" or not fill or time.time() - fill["ts"] > 60:
                raise RuntimeError("要发送的内容已过期，请重新发送")
            self.ide_call("send", sid, [fill["window"]], text=fill["text"])
            return "已填入"

        def key(self, sid, key):
            info = self.info(sid)
            if info["pane"]:
                kl.tmux_send(info["pid"], "", [key], False)
                return "已发送 Esc" if key in ("esc", "escape") else "已选择"
            if info["remote"]:
                raise RuntimeError(READ_ONLY["remote"][0])
            if info["form"] != "ide":
                raise RuntimeError(READ_ONLY["cli"][0])
            if not info["opened"]:
                raise RuntimeError(READ_ONLY["confirm" if info["waiting"] else "agents"][0])
            if key in ("esc", "escape"):
                self.ide_call("reject" if info["waiting"] else "cancel", sid, info["opened"])
                if info["waiting"] and not self.settled(sid, info):
                    raise RuntimeError(READ_ONLY["confirm"][0])
                return "已拒绝" if info["waiting"] else "已中断"
            if key in ("1", "y", "enter"):
                self.ide_call("approve", sid, info["opened"])
                if not self.settled(sid, info):
                    raise RuntimeError(READ_ONLY["confirm"][0])
                return "已允许"
            raise RuntimeError("Cursor 编辑器里只能允许或拒绝")

        def closable(self, snap):
            return bool(snap.get("tmuxPane"))

        def close(self, sid):
            # 同 Claude Code 终端里的会话发 /exit：Cursor 命令行的退出命令是 /quit；之后能用 agent --resume 接着用。
            # 等确认时不发：回车会替你选中审批菜单里的选项
            info = self.info(sid)
            if not info["pane"]:
                raise RuntimeError("只能关闭在 tmux 中运行的 Cursor 命令行会话")
            if info["waiting"]:
                raise RuntimeError("Cursor 正在等你确认。终端中的会话需输入 /quit 并按回车才能关闭，此时回车会替你选中审批菜单中的选项，"
                                   "因此会话未关闭。请先在确认卡片中作出选择，再关闭会话")
            kl.tmux_send(info["pid"], "/quit", [], True)
            return "已关闭会话"

    return Cursor()
