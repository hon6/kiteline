"""和 VS Code 里的 Kiteline 配套扩展（vscode_bridge/）说话：Linux 上切 Claude Code 会话、核对前台和当前标签、聚焦、粘贴。

Wayland 桌面（Ubuntu、Fedora 默认）不许普通程序找窗口、切窗口、读窗口标题，xdotool 那套用不了，改由扩展在 VS Code 里面做；
回车由 uinput.py 的虚拟键盘按。每个 VS Code 窗口开一个 Unix 套接字：$XDG_RUNTIME_DIR/kiteline/vscode-<pid>.sock（目录 700、套接字 600）。
扩展随 Kiteline 一起发，在本机打成 .vsix 用 `code --install-extension` 装（用户级，不用管理员权限，不从网上下载）。
"""

import glob
import json
import os
import shutil
import socket
import stat
import struct
import subprocess
import tempfile
import zipfile

from . import config, log

EXTENSION_ID = "kiteline.kiteline-bridge"
SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vscode_bridge")
# VS Code 系编辑器：命令行 → 用户扩展目录（相对家目录）
EDITORS = (
    ("code", ".vscode/extensions"),
    ("code-insiders", ".vscode-insiders/extensions"),
    ("codium", ".vscode-oss/extensions"),
    ("cursor", ".cursor/extensions"),
    ("windsurf", ".windsurf/extensions"),
)
MAX_REPLY = 1024 * 1024


def socket_dir():
    """和扩展里 socketDir() 一致：$XDG_RUNTIME_DIR/kiteline，没有时临时目录下按用户分开的 kiteline-<uid>"""
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if runtime:
        return os.path.join(runtime, "kiteline")
    return os.path.join(tempfile.gettempdir(), "kiteline-%d" % os.getuid())


def _own_dir(path):
    """目录是不是自己的：是目录、不是符号链接、属主是自己、别人没有任何权限"""
    try:
        info = os.lstat(path)
    except OSError:
        return False
    return stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o077


def version():
    with open(os.path.join(SOURCE, "package.json"), encoding="utf-8") as handle:
        return json.load(handle)["version"]


def _version_key(text):
    return tuple(int(part) if part.isdigit() else 0 for part in text.split("."))


def installed_version():
    """装过的最新版本（几个编辑器里最高的那个）；没装过返回 None。
    以编辑器自己的清单 extensions.json 为准：卸载后目录要等编辑器重启才删，只看目录会以为还装着"""
    found = []
    home = os.path.expanduser("~")
    for _, folder in EDITORS:
        base = os.path.join(home, folder)
        try:
            with open(os.path.join(base, "extensions.json"), encoding="utf-8") as handle:
                entries = json.load(handle)
            found += [str(e.get("version") or "0") for e in entries
                      if str((e.get("identifier") or {}).get("id", "")).lower() == EXTENSION_ID]
            continue
        except (OSError, ValueError, AttributeError):
            pass
        # 老版本编辑器没有清单：看目录，去掉标记为已卸载的（.obsolete）
        try:
            with open(os.path.join(base, ".obsolete"), encoding="utf-8") as handle:
                obsolete = json.load(handle)
        except (OSError, ValueError):
            obsolete = {}
        for path in glob.glob(os.path.join(base, EXTENSION_ID + "-*")):
            if not obsolete.get(os.path.basename(path)):
                found.append(os.path.basename(path)[len(EXTENSION_ID) + 1:])
    return max(found, key=_version_key) if found else None


def installed():
    return installed_version() is not None


def editors():
    """本机装了哪些 VS Code 系编辑器（命令行能找到的）"""
    return [cli for cli, _ in EDITORS if shutil.which(cli)]


def build_vsix(path):
    """把随 Kiteline 发的扩展源码打成 .vsix（就是一个 zip）"""
    with open(os.path.join(SOURCE, "package.json"), encoding="utf-8") as handle:
        pkg = json.load(handle)
    manifest = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">\n'
        '  <Metadata>\n'
        '    <Identity Language="en-US" Id="{name}" Version="{version}" Publisher="{publisher}" />\n'
        '    <DisplayName>{display}</DisplayName>\n'
        '    <Description xml:space="preserve">{description}</Description>\n'
        '    <Categories>Other</Categories>\n'
        '    <Properties>\n'
        '      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="{engine}" />\n'
        '      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="ui" />\n'
        '    </Properties>\n'
        '  </Metadata>\n'
        '  <Installation><InstallationTarget Id="Microsoft.VisualStudio.Code" /></Installation>\n'
        '  <Dependencies />\n'
        '  <Assets><Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true" /></Assets>\n'
        '</PackageManifest>\n'
    ).format(name=pkg["name"], version=pkg["version"], publisher=pkg["publisher"], display=pkg["displayName"],
             description=pkg["description"], engine=pkg["engines"]["vscode"])
    types = ('<?xml version="1.0" encoding="utf-8"?>\n'
             '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\n'
             '  <Default Extension=".json" ContentType="application/json" />\n'
             '  <Default Extension=".js" ContentType="application/javascript" />\n'
             '  <Default Extension=".vsixmanifest" ContentType="text/xml" />\n'
             '</Types>\n')
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("[Content_Types].xml", types)
        archive.writestr("extension.vsixmanifest", manifest)
        for name in ("package.json", "extension.js"):
            archive.write(os.path.join(SOURCE, name), "extension/" + name)
    return path


def install():
    """装进本机所有 VS Code 系编辑器。返回 (ok, message)"""
    clis = editors()
    if not clis:
        return False, "没有找到 VS Code（code 命令）"
    vsix = build_vsix(os.path.join(config.config_dir(), "kiteline-bridge-%s.vsix" % version()))
    done, failed = [], []
    for cli in clis:
        try:
            result = subprocess.run([cli, "--install-extension", vsix, "--force"], stdin=subprocess.DEVNULL,
                                    capture_output=True, timeout=180)
        except (OSError, subprocess.SubprocessError) as exc:
            failed.append("%s：%s" % (cli, exc))
            continue
        if result.returncode == 0:
            done.append(cli)
        else:
            failed.append("%s：%s" % (cli, result.stderr.decode("utf-8", "replace").strip()[-200:]))
    if failed:
        log.write("安装 VS Code 配套扩展失败：%s" % "；".join(failed))
    if not done:
        return False, "安装 VS Code 配套扩展失败：%s" % "；".join(failed)
    log.write("已安装 VS Code 配套扩展 %s（%s）" % (version(), "、".join(done)))
    return True, "已在 VS Code 中安装 Kiteline 配套扩展"


def ensure_current():
    """装过旧版本就升到随 Kiteline 发的这一版（启动时在后台调）"""
    current = installed_version()
    if current and _version_key(current) < _version_key(version()):
        install()


def call(path, request, timeout=8):
    """发一条请求、读一行回复"""
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(timeout)
    try:
        client.connect(path)
        # 只跟本用户的 VS Code 说话：另一头的进程必须是同一个用户。没有 XDG_RUNTIME_DIR 时套接字放在公共的临时目录，
        # 别的用户可能抢先建好目录、放一个假的套接字，骗走消息内容、谎报窗口在前台
        if hasattr(socket, "SO_PEERCRED"):
            _pid, uid, _gid = struct.unpack("3i", client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
            if uid != os.getuid():
                raise PermissionError("套接字不是当前用户的 VS Code 开的")
        client.sendall((json.dumps(request, ensure_ascii=False) + "\n").encode("utf-8"))
        data = b""
        while not data.endswith(b"\n"):
            chunk = client.recv(65536)
            if not chunk:
                break
            data += chunk
            if len(data) > MAX_REPLY:
                raise ValueError("回复过长")
    finally:
        client.close()
    return json.loads(data.decode("utf-8"))


class Window:
    """一个装了配套扩展的 VS Code 窗口"""

    def __init__(self, path, state):
        self.path = path
        self.state = state

    def call(self, cmd, **args):
        request = dict(args, cmd=cmd)
        reply = call(self.path, request, timeout=15)
        if not reply.get("ok"):
            raise ValueError(reply.get("error") or "扩展返回失败")
        self.state = reply
        return reply


def windows():
    """开着的 VS Code 窗口（装了配套扩展的）；连不上的旧套接字（窗口已关）顺手删掉"""
    found = []
    if not _own_dir(socket_dir()):
        return found
    for path in sorted(glob.glob(os.path.join(socket_dir(), "vscode-*.sock"))):
        try:
            state = call(path, {"cmd": "state"}, timeout=3)
        except (ConnectionRefusedError, FileNotFoundError):
            try:
                os.unlink(path)
            except OSError:
                pass
            continue
        except (OSError, ValueError):
            continue
        if state.get("ok"):
            found.append(Window(path, state))
    return found


def window_for(record):
    """会话所在的窗口：打开的文件夹包含会话目录的那个（取最深的）；只开了一个窗口时就是它"""
    return window_for_cwd(record.snap.get("cwd") or "")


def window_for_cwd(cwd, only_match=False):
    """打开的文件夹包含 cwd 的窗口（取最深的）；only_match=False 时只开了一个窗口也算"""
    cwd = cwd.rstrip("/")
    found = windows()
    best, depth = None, -1
    for window in found:
        for folder in window.state.get("folders") or []:
            folder = folder.rstrip("/")
            if folder and (cwd == folder or cwd.startswith(folder + "/")) and len(folder) > depth:
                best, depth = window, len(folder)
    if best or only_match:
        return best
    return found[0] if len(found) == 1 else None
