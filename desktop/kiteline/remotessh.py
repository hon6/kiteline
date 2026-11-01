"""远端项目还没在 VS Code 里开着、要新开 Remote-SSH 窗口时的准备（新任务、恢复会话、「在 VS Code 中打开」都走这里）。
和 Mac 版 RemoteSSH.swift / WindowLocator.sshAuthority 同一套做法：

1. VS Code 没装 Remote-SSH 扩展：用 VS Code 命令行装上（用户级，从扩展市场下载）；
2. Windows 上 Remote-SSH 第一次连一台主机会弹框问远端是什么系统（Mac / Linux 默认用本地服务器模式，自动识别、不弹）：
   照 watcher 报来的系统替用户填上 VS Code 设置 remote.SSH.remotePlatform（就是用户在框里选了之后 Remote-SSH 自己写的那项）；
3. 远端窗口里 Claude Code 扩展跑在远端：远端没装时扩展链接会被悄悄丢掉，经 ssh 用远端 VS Code 服务端的命令行装上；
4. 密钥文件只在 Kiteline 里填了、ssh 配置里没有：VS Code 只读 ssh 配置，用不上，提醒用户写进 ~/.ssh/config。
端口不用管：窗口地址里的主机写法能带上端口（ssh_authority）。
"""

import json
import os
import re
import shutil
import subprocess
import threading
import time
import urllib.parse

from . import config, log

EXTENSION_ID = "ms-vscode-remote.remote-ssh"
NO_WINDOW = {"creationflags": 0x08000000} if config.IS_WINDOWS else {}
PLATFORMS = {"linux": "linux", "darwin": "macOS", "win32": "windows"}


def ssh_authority(host, port=None):
    """远端窗口地址里的主机写法，照 Remote-SSH 自己的规则（HostInfo.toAuthorityString）：带用户名、端口、大写字母
    （VS Code 会把地址里的主机名转成小写）或 / \\ + 的，写成 {"hostName","user","port"} 的 JSON 再转十六进制，其余原样。
    别名在 ssh 配置里有 HostName 的，Remote-SSH 照配置连（端口以配置为准）"""
    user, host_name = None, host
    if "@" in host:
        user, host_name = host.rsplit("@", 1)
        user = user or None
    port = int(port) if port else None
    if not (user or port or host_name.lower() != host_name or re.search(r"[/\\+]", host_name)):
        return host_name
    data = {"hostName": host_name}   # 字段顺序同 JSON.stringify：hostName、user、port
    if user:
        data["user"] = user
    if port:
        data["port"] = port
    return json.dumps(data, separators=(",", ":"), ensure_ascii=False).encode("utf-8").hex()


def folder_uri(host, port, path):
    """远端目录的 VS Code 地址 vscode-remote://ssh-remote+<主机写法><路径>（远端是 Windows 时路径写成 /c:/…）"""
    if re.match(r"^[A-Za-z]:", path):
        path = "/" + path.replace("\\", "/")
    return "vscode-remote://ssh-remote+%s%s" % (ssh_authority(host, port), urllib.parse.quote(path, safe="/:"))


# MARK: 本机 VS Code 的 Remote-SSH 扩展

def extension_installed():
    """装没装看 extensions.json（卸载后扩展目录要等 VS Code 重启才删）"""
    path = os.path.join(os.path.expanduser("~"), ".vscode", "extensions", "extensions.json")
    try:
        with open(path, encoding="utf-8") as handle:
            entries = json.load(handle)
    except (OSError, ValueError):
        return False
    return any(str((e.get("identifier") or {}).get("id", "")).lower() == EXTENSION_ID for e in entries if isinstance(e, dict))


def ensure_extension(code):
    """没装就用 VS Code 命令行装上（要十几秒）。返回 None = 装好了，否则是原因"""
    if extension_installed():
        return None
    log.write("VS Code 未安装 Remote-SSH 扩展，正在安装")
    try:
        result = subprocess.run([code, "--install-extension", EXTENSION_ID], capture_output=True, timeout=180,
                                stdin=subprocess.DEVNULL, **NO_WINDOW)
        output = (result.stdout + result.stderr).decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError) as exc:
        output = str(exc)
    if extension_installed():
        log.write("已安装 Remote-SSH 扩展")
        return None
    log.write("Remote-SSH 扩展安装失败：%s" % output.strip())
    reason = (output.strip().splitlines() or ["未知错误"])[-1]
    return "VS Code 未安装 Remote-SSH 扩展，自动安装失败（%s）；请在 VS Code 的扩展中搜索「Remote - SSH」安装" % reason


# MARK: VS Code 里用过的 Remote-SSH 主机（「来源」页一键添加）

def _vscode_user_dir():
    if config.IS_WINDOWS:
        base = os.environ.get("APPDATA") or os.path.join(os.path.expanduser("~"), "AppData", "Roaming")
        return os.path.join(base, "Code", "User")
    return os.path.join(os.path.expanduser("~"), ".config", "Code", "User")


def host_of_authority(authority):
    """ssh-remote+<主机写法> → (ssh 命令里的写法 user@host, 端口)；反过来同 ssh_authority"""
    if not authority or not authority.startswith("ssh-remote+"):
        return None, None
    raw = urllib.parse.unquote(authority[len("ssh-remote+"):])
    if re.fullmatch(r"(?:[0-9a-f]{2})+", raw):
        try:
            data = json.loads(bytes.fromhex(raw).decode("utf-8"))
            host = data.get("hostName") or ""
            return (("%s@%s" % (data["user"], host)) if data.get("user") else host) or None, data.get("port")
        except (ValueError, AttributeError):
            pass
    return raw or None, None


def recent_hosts():
    """VS Code 正开着的（排前面）和最近打开过的 Remote-SSH 主机：[{host, port, open}]。
    读 VS Code 自己记的窗口状态（globalStorage/storage.json）和最近打开列表（globalStorage/state.vscdb）里的 vscode-remote:// 地址"""
    found = {}

    def note(uri_or_authority, is_open):
        text = uri_or_authority or ""
        if text.startswith("vscode-remote://"):
            text = text[len("vscode-remote://"):].split("/", 1)[0]
        host, port = host_of_authority(urllib.parse.unquote(text))
        if host and host not in found:
            found[host] = {"host": host, "port": port, "open": is_open}
        elif host and is_open:
            found[host]["open"] = True

    storage = os.path.join(_vscode_user_dir(), "globalStorage")
    try:
        with open(os.path.join(storage, "storage.json"), encoding="utf-8") as handle:
            data = json.load(handle)
        state = data.get("windowsState") or {}
        for window in [state.get("lastActiveWindow")] + list(state.get("openedWindows") or []):
            if isinstance(window, dict):
                note(window.get("remoteAuthority") or window.get("folder") or (window.get("workspaceIdentifier") or {}).get("configURIPath"), True)
        # 有未保存备份的窗口（多半是最近开着的），再是打开过的所有文件夹（VS Code 记它们用的配置档）
        backups = data.get("backupWorkspaces") or {}
        for entry in list(backups.get("folders") or []) + list(backups.get("workspaces") or []):
            if isinstance(entry, dict):
                note(entry.get("remoteAuthority") or entry.get("folderUri") or (entry.get("workspace") or {}).get("configPath"), False)
        for uri in ((data.get("profileAssociations") or {}).get("workspaces") or {}):
            note(uri, False)
    except (OSError, ValueError, AttributeError):
        pass
    try:
        import sqlite3
        db = sqlite3.connect("file:%s?mode=ro" % os.path.join(storage, "state.vscdb"), uri=True, timeout=2)
        try:
            row = db.execute("SELECT value FROM ItemTable WHERE key = 'history.recentlyOpenedPathsList'").fetchone()
        finally:
            db.close()
        for entry in (json.loads(row[0]).get("entries") or [])[:40] if row else []:
            note(entry.get("remoteAuthority") or entry.get("folderUri") or (entry.get("workspace") or {}).get("configPath"), False)
    except Exception:  # noqa: BLE001  数据库被 VS Code 锁着、格式变了：没有建议而已
        pass
    hosts = list(found.values())
    hosts.sort(key=lambda h: not h["open"])
    return hosts[:8]


# MARK: Windows 上替用户选好远端系统

def _settings_path():
    if config.IS_WINDOWS:
        base = os.environ.get("APPDATA") or os.path.join(os.path.expanduser("~"), "AppData", "Roaming")
        return os.path.join(base, "Code", "User", "settings.json")
    return os.path.join(os.path.expanduser("~"), ".config", "Code", "User", "settings.json")


def _tokens(text):
    """JSONC 里注释以外的符号和字符串：(种类, 位置, 内容)"""
    index, size = 0, len(text)
    while index < size:
        char = text[index]
        if char == '"':
            end = index + 1
            while end < size and text[end] != '"':
                end += 2 if text[end] == "\\" else 1
            yield "str", index, text[index + 1:end]
            index = end + 1
        elif text.startswith("//", index):
            end = text.find("\n", index)
            index = size if end < 0 else end
        elif text.startswith("/*", index):
            end = text.find("*/", index + 2)
            index = size if end < 0 else end + 2
        else:
            if char in "{}[]:,":
                yield "sym", index, char
            index += 1


def _parse_jsonc(text):
    """去掉注释和结尾多余的逗号再解析；看不懂返回 None"""
    index, size, out = 0, len(text), []
    while index < size:
        char = text[index]
        if char == '"':
            end = index + 1
            while end < size and text[end] != '"':
                end += 2 if text[end] == "\\" else 1
            out.append(text[index:end + 1])
            index = end + 1
        elif text.startswith("//", index):
            end = text.find("\n", index)
            index = size if end < 0 else end
        elif text.startswith("/*", index):
            end = text.find("*/", index + 2)
            index = size if end < 0 else end + 2
        else:
            out.append(char)
            index += 1
    try:
        value = json.loads(re.sub(r",(\s*[}\]])", r"\1", "".join(out)))
    except ValueError:
        return None
    return value if isinstance(value, dict) else None


def ensure_platform(host, remote_platform):
    """只往设置里加这台主机一项，别的设置和注释原样不动；设置文件看不懂就不碰（照旧弹框）"""
    value = PLATFORMS.get(remote_platform or "")
    if not config.IS_WINDOWS or not value:
        return
    host_name = host.rsplit("@", 1)[-1]
    path = _settings_path()
    try:
        with open(path, encoding="utf-8-sig") as handle:
            text = handle.read()
    except FileNotFoundError:
        text = ""
    except OSError:
        return
    entry = "%s: %s" % (json.dumps(host_name, ensure_ascii=False), json.dumps(value))
    if not text.strip():
        text = '{\n    "remote.SSH.remotePlatform": {\n        %s\n    }\n}\n' % entry
    else:
        parsed = _parse_jsonc(text)
        if parsed is None:
            log.write("VS Code 设置文件无法解析，未预设远端系统（首次连接 %s 时 VS Code 会询问）" % host_name)
            return
        current = parsed.get("remote.SSH.remotePlatform")
        if isinstance(current, dict) and host_name in current:
            return
        if current is not None and not isinstance(current, dict):
            return
        tokens = list(_tokens(text))
        root = target = None
        depth, pending, key = 0, None, None
        for number, (kind, pos, token) in enumerate(tokens):
            if kind == "sym" and token in "{[":
                if depth == 0 and token == "{" and root is None:
                    root = number
                elif depth == 1 and token == "{" and key == "remote.SSH.remotePlatform":
                    target = number
                depth += 1
                key = None
            elif kind == "sym" and token in "}]":
                depth -= 1
            elif kind == "sym" and token == ":":
                key = pending if depth == 1 else None
            elif kind == "sym" and token == ",":
                key = pending = None
            elif kind == "str" and depth == 1:
                pending = token
        brace = target if target is not None else root
        if brace is None:
            return
        empty = brace + 1 < len(tokens) and tokens[brace + 1][2] == "}"
        if target is not None:
            insert = "\n        %s%s" % (entry, "" if empty else ",")
        else:
            insert = '\n    "remote.SSH.remotePlatform": { %s }%s' % (entry, "" if empty else ",")
        at = tokens[brace][1] + 1
        text = text[:at] + insert + text[at:]
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
        log.write("已在 VS Code 设置中预设 %s 的系统为 %s（remote.SSH.remotePlatform）" % (host_name, value))
    except OSError as exc:
        log.write("写 VS Code 设置失败：%s" % exc)



# MARK: Claude Code 扩展的链接免确认（同 Mac 版 EditorSettings）
# Kiteline 用扩展链接 vscode://anthropic.claude-code/open 切会话、开新任务，新装的 VS Code 每次都先弹
# 「是否允许“Claude Code”扩展打开此 URI?」：人不在电脑前没人点，消息就卡住；投完把前台还回去，框还会被压到后面。
# VS Code 自带设置 extensions.confirmedUriHandlerExtensionIds（列出的扩展打开链接不再确认，等同在框里勾「不再询问」），
# 只往用户设置里加这一项；设置文件看不懂就不碰，照旧弹框（投递时提示用户去电脑上点）

CLAUDE_EXTENSION = "anthropic.claude-code"
TRUST_KEY = "extensions.confirmedUriHandlerExtensionIds"
_trust_lock = threading.Lock()


def _lists_claude(ids):
    return isinstance(ids, list) and any(isinstance(i, str) and i.lower() == CLAUDE_EXTENSION for i in ids)


def _confirmed_in_storage():
    """用户在确认框里勾过「不再询问」：VS Code 记在 globalStorage/state.vscdb 的 extensionUrlHandler.confirmedExtensions"""
    try:
        import sqlite3
        path = os.path.join(_vscode_user_dir(), "globalStorage", "state.vscdb")
        if not os.path.exists(path):
            return False
        db = sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=2)
        try:
            row = db.execute("SELECT value FROM ItemTable WHERE key = 'extensionUrlHandler.confirmedExtensions'").fetchone()
        finally:
            db.close()
        return _lists_claude(json.loads(row[0])) if row else False
    except Exception:  # noqa: BLE001  数据库被 VS Code 锁着、格式变了：当没勾过
        return False


def adding_claude_trust(text):
    """往设置里加上信任 Claude Code 扩展链接的那一项，别的原样不动；已经有了返回原文，看不懂（或这项不是列表）返回 None"""
    item = json.dumps(CLAUDE_EXTENSION)
    if not text.strip().strip("\ufeff").strip():
        return '{\n    "%s": [%s]\n}\n' % (TRUST_KEY, item)
    parsed = _parse_jsonc(text)
    if parsed is None or (TRUST_KEY in parsed and not isinstance(parsed[TRUST_KEY], list)):
        return None
    if _lists_claude(parsed.get(TRUST_KEY)):
        return text
    tokens = list(_tokens(text))
    root = array = None
    depth, pending, key = 0, None, None
    for number, (kind, pos, token) in enumerate(tokens):
        if kind == "sym" and token in "{[":
            if depth == 0 and token == "{" and root is None:
                root = number
            elif depth == 1 and token == "[" and key == TRUST_KEY:
                array = number
            depth += 1
            key = None
        elif kind == "sym" and token in "}]":
            depth -= 1
        elif kind == "sym" and token == ":":
            key = pending if depth == 1 else None
        elif kind == "sym" and token == ",":
            key = pending = None
        elif kind == "str" and depth == 1:
            pending = token
    opening = array if array is not None else root
    if opening is None:
        return None
    after = tokens[opening + 1] if opening + 1 < len(tokens) else None
    empty = after is not None and after[0] == "sym" and after[2] == ("]" if array is not None else "}")
    if array is not None:
        insert = item if empty else item + ", "
    else:
        insert = '\n    "%s": [%s]%s' % (TRUST_KEY, item, "\n" if empty else ",")
    at = tokens[opening][1] + 1
    return text[:at] + insert + text[at:]


def vscode_installed():
    """装过（打开过）VS Code：用户目录在"""
    return os.path.isdir(_vscode_user_dir())


def claude_links_trusted():
    """只查不写（就绪检查在测试实例里用，不碰用户的 VS Code 设置）"""
    try:
        with open(_settings_path(), encoding="utf-8-sig") as handle:
            text = handle.read()
    except (OSError, ValueError):
        text = ""
    parsed = _parse_jsonc(text) if text.strip() else {}
    return bool(parsed and _lists_claude(parsed.get(TRUST_KEY))) or _confirmed_in_storage()


def workspace_trust_enabled():
    """VS Code 开着工作区信任（默认开）：没信任过的文件夹以受限模式打开（顶上挂横幅），信任之前 Claude Code 扩展不运行"""
    try:
        with open(_settings_path(), encoding="utf-8-sig") as handle:
            parsed = _parse_jsonc(handle.read()) or {}
    except (OSError, ValueError):
        parsed = {}
    return parsed.get("security.workspace.trust.enabled") is not False


def trust_claude_links():
    """让 Claude Code 扩展的链接不再弹确认框。返回 (之后不会弹, 这次刚写进设置)：刚写的 VS Code 要一会儿才读到"""
    with _trust_lock:   # 启动时在后台设、投递时又来查：同时进来会各插一遍
        path = _settings_path()
        try:
            with open(path, encoding="utf-8-sig") as handle:
                text = handle.read()
        except FileNotFoundError:
            if not os.path.isdir(os.path.dirname(path)):
                return False, False   # 没装或没打开过 VS Code
            text = ""
        except (OSError, ValueError):
            return False, False
        parsed = _parse_jsonc(text) if text.strip() else {}
        if parsed is not None and _lists_claude(parsed.get(TRUST_KEY)):
            return True, False
        if _confirmed_in_storage():
            return True, False
        updated = adding_claude_trust(text)
        if updated is None:
            log.write("VS Code 设置文件无法解析，未能预先信任 Claude Code 扩展的链接（%s）：切换会话时 VS Code 会弹确认框" % path)
            return False, False
        try:
            with open(path, "w", encoding="utf-8") as handle:   # 符号链接（dotfiles）照样写进它指向的文件
                handle.write(updated)
        except OSError as exc:
            log.write("写 VS Code 设置失败：%s" % exc)
            return False, False
        log.write("已在 VS Code 设置中信任 Claude Code 扩展的链接（%s），切换会话、新任务不再弹确认框" % TRUST_KEY)
        return True, True


# MARK: 密钥文件

def _ssh():
    return shutil.which("ssh") or "ssh"


def identity_note(source_config):
    """密钥文件只填在 Kiteline 里时的提醒；没填、或 ssh 配置里已经用这个密钥：None"""
    identity, host = source_config.get("sshIdentityFile"), source_config.get("sshHost")
    if not identity or not host:
        return None
    cmd = [_ssh(), "-G"] + (["-p", str(source_config["sshPort"])] if source_config.get("sshPort") else []) + [host]
    try:
        output = subprocess.run(cmd, capture_output=True, timeout=5, stdin=subprocess.DEVNULL, **NO_WINDOW).stdout.decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError):
        return None
    wanted = os.path.normcase(os.path.expanduser(identity))
    configured = [os.path.normcase(os.path.expanduser(line[len("identityfile "):].strip()))
                  for line in output.splitlines() if line.startswith("identityfile ")]
    if wanted in configured:
        return None
    return "该主机的密钥文件（%s）只在 Kiteline 中设置，VS Code 无法使用，可能连接失败；请在 ~/.ssh/config 中为 %s 添加 IdentityFile" % (identity, host)


def prepare(code, source_config, remote_platform):
    """新开远端窗口前的准备（1、2、4）。返回 (问题, 提醒)：问题非空 = 打不开"""
    problem = ensure_extension(code)
    if problem:
        return problem, None
    ensure_platform(source_config.get("sshHost", ""), remote_platform)
    return None, identity_note(source_config)


# MARK: 远端的 Claude Code 扩展

# 装扩展要下载几十 MB，网慢时要好几分钟：放到远端后台装（ssh 断了也不影响），这边每几秒问一次结果
REMOTE_SCRIPT = r'''d="$HOME/.vscode-server"
f="$d/extensions/extensions.json"
log="$d/kiteline-claude-install.log"
if grep -q '"anthropic.claude-code"' "$f" 2>/dev/null; then rm -f "$log.running" "$log.failed"; echo KL_HAS; exit 0; fi
bin=
for b in $(ls -td "$d"/cli/servers/Stable-*/server/bin/code-server "$d"/bin/*/bin/code-server 2>/dev/null); do
  case "$b" in *.staging*) continue ;; esac
  if [ -x "${b%/bin/code-server}/node" ]; then bin=$b; break; fi
done
if [ -z "$bin" ]; then echo KL_NOSERVER; exit 0; fi
if [ "$1" = check ]; then echo KL_MISSING; exit 0; fi
if [ -f "$log.failed" ]; then rm -f "$log.failed"; echo "KL_FAILED $(tail -n 1 "$log" 2>/dev/null)"; exit 0; fi
if [ -z "$(find "$log.running" -mmin -20 2>/dev/null)" ]; then
  : > "$log.running"
  nohup sh -c '"$1" --install-extension anthropic.claude-code > "$2" 2>&1 || : > "$2.failed"; rm -f "$2.running"' sh "$bin" "$log" < /dev/null > /dev/null 2>&1 &
fi
echo KL_INSTALLING
'''


def ensure_remote_claude(ssh_cmd, installing=None):
    """远端没装 Claude Code 扩展就装上：已经开着的窗口不用重载就能认出来（10-23 实测，首次约 40 秒）。
    这台主机第一次用 VS Code 连、服务端还没装时，等新开的窗口把服务端装好再装（解压到一半的 .staging 目录不算）。
    ssh_cmd：连到远端的 ssh 命令（不含远端命令）；installing：要装（或要等服务端）时先调一下。
    返回 (状态, 原因)：ready 本来就有 / installed 刚装上 / failed 装不上 / unknown 看不出来（连不上、远端是 Windows 等）。
    网慢时下载扩展要好几分钟，最多等 15 分钟"""
    def remote(mode, timeout):
        try:
            result = subprocess.run(ssh_cmd + ["sh", "-s", mode], input=REMOTE_SCRIPT.encode("utf-8"), capture_output=True,
                                    timeout=timeout, **NO_WINDOW)
        except (OSError, subprocess.SubprocessError):
            return ""
        lines = [l.strip() for l in result.stdout.decode("utf-8", "replace").splitlines() if l.strip().startswith("KL_")]
        return lines[-1] if lines else ""

    first = remote("check", 20)
    if first not in ("KL_MISSING", "KL_NOSERVER"):
        return ("ready" if first == "KL_HAS" else "unknown"), ""
    if installing:
        installing()
    log.write("远端未安装 Claude Code 扩展，%s安装" % ("等 VS Code 服务端装好后" if first == "KL_NOSERVER" else "现在"))
    deadline, misses = time.time() + 900, 0
    while True:
        result = remote("install", 30)
        if result == "KL_HAS":
            log.write("远端已安装 Claude Code 扩展")
            return "installed", ""
        if result.startswith("KL_FAILED"):
            reason = result[len("KL_FAILED"):].strip() or "安装命令出错"
            log.write("远端安装 Claude Code 扩展失败：%s" % reason)
            return "failed", reason
        misses = misses + 1 if result not in ("KL_NOSERVER", "KL_INSTALLING") else 0
        if misses >= 5:   # 连着几次连不上：看不出来，照旧往下走
            return "unknown", ""
        if time.time() > deadline:
            return "failed", "VS Code 服务端或扩展 15 分钟内未装好"
        time.sleep(4)
