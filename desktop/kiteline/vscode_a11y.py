"""Linux：让 Kiteline 读得到 VS Code 的界面（就绪检查「读取 VS Code 弹框」一键开启）。读了做什么见 atspi_linux.py、alerts.py。

开启做三件事（都是当前用户自己的文件，不用管理员权限；10-27 kl-ubuntu 实测出来的条件）：
  1. VS Code 带 ACCESSIBILITY_ENABLED=1 启动：在 ~/.local/share/applications 放一份同名的启动项覆盖系统的那份，命令前加 env
     （程序坞、应用菜单、vscode:// 链接打开的都带上）；Kiteline 自己启动 VS Code 时也带上。删掉这几份文件就恢复原样
  2. 设置里没写 editor.accessibilitySupport 的写成 off：VS Code 发现开了辅助功能会以为接了读屏软件，自动切到「读屏优化」模式，改变编辑器的行为
  3. 设置里没写 window.dialogStyle 的写成 custom：GNOME 原生对话框读不到，VS Code 自己画的读得到
用户在设置里自己写过这两项的，不改。
"""

import glob
import json
import os
import re
import subprocess

from . import config, log, remotessh

ENV = "ACCESSIBILITY_ENABLED"
MARK = "X-Kiteline-Accessibility=true"
SETTINGS = (("editor.accessibilitySupport", "off"), ("window.dialogStyle", "custom"))
# VS Code 系编辑器的启动项（deb / rpm、snap、老版本 VS Code 的文件名）
LAUNCHER_DIRS = ("/usr/share/applications", "/usr/local/share/applications", "/var/lib/snapd/desktop/applications")
LAUNCHER_NAMES = ("com.microsoft.VSCode.desktop", "com.microsoft.VSCode.UrlHandler.desktop", "code.desktop", "code-url-handler.desktop",
                  "code_code.desktop", "code_code-url-handler.desktop",
                  "com.microsoft.VSCodeInsiders.desktop", "com.microsoft.VSCodeInsiders.UrlHandler.desktop",
                  "code-insiders.desktop", "code-insiders-url-handler.desktop", "codium.desktop", "codium-url-handler.desktop")


def _user_apps():
    base = os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, "applications")


def _launchers():
    """系统里 VS Code 的启动项：[(系统那份, 用户覆盖的那份)]"""
    found = []
    for name in LAUNCHER_NAMES:
        for folder in LAUNCHER_DIRS:
            path = os.path.join(folder, name)
            if os.path.isfile(path):
                found.append((path, os.path.join(_user_apps(), name)))
                break
    return found


def _with_env(text):
    """启动项里每条 Exec= 命令前加 env ACCESSIBILITY_ENABLED=1，[Desktop Entry] 下加一行标记（认得出是 Kiteline 写的）"""
    lines = []
    for line in text.splitlines():
        if line.startswith("Exec=") and ENV + "=" not in line:
            command = line[len("Exec="):]
            command = command[len("env "):] if command.startswith("env ") else command
            line = "Exec=env %s=1 %s" % (ENV, command)
        lines.append(line)
        if line.strip() == "[Desktop Entry]" and MARK not in text:
            lines.append(MARK)
    return "\n".join(lines) + "\n"


def _launcher_ok(user_path):
    try:
        with open(user_path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        return False
    return all(ENV + "=1" in line for line in text.splitlines() if line.startswith("Exec="))


def _settings():
    try:
        with open(remotessh._settings_path(), encoding="utf-8-sig") as handle:
            text = handle.read()
    except FileNotFoundError:
        return "", {}
    except (OSError, ValueError):
        return None, None
    return text, (remotessh._parse_jsonc(text) if text.strip() else {})


def _adding(text, key, value):
    """在设置的最外层加一项，别的设置和注释原样不动；看不懂返回 None"""
    item = "%s: %s" % (json.dumps(key), json.dumps(value))
    if not text.strip().strip("﻿").strip():
        return "{\n    %s\n}\n" % item
    tokens = list(remotessh._tokens(text))
    root = next((n for n, (kind, _pos, token) in enumerate(tokens) if kind == "sym" and token == "{"), None)
    if root is None:
        return None
    after = tokens[root + 1] if root + 1 < len(tokens) else None
    empty = after is not None and after[0] == "sym" and after[2] == "}"
    at = tokens[root][1] + 1
    return text[:at] + "\n    " + item + ("\n" if empty else ",") + text[at:]


def dialog_style():
    """设置里的 window.dialogStyle（没写 = None）"""
    _text, parsed = _settings()
    return (parsed or {}).get("window.dialogStyle")


def enabled():
    """开启过：启动项都带上了 ACCESSIBILITY_ENABLED=1，设置里两项都有（用户自己写的值也算）"""
    if not config.IS_LINUX:
        return False
    launchers = _launchers()
    if not launchers or not all(_launcher_ok(user) for _system, user in launchers):
        return False
    _text, parsed = _settings()
    return parsed is not None and all(key in parsed for key, _ in SETTINGS)


def enable():
    """一键开启（就绪检查的「开启」按钮）。返回 (ok, message)"""
    launchers = _launchers()
    if not launchers:
        return False, "没有找到 VS Code 的启动项（只支持 deb / rpm、snap 安装的 VS Code）"
    text, parsed = _settings()
    if parsed is None:
        return False, "VS Code 的设置文件无法解析，请先修正 %s" % remotessh._settings_path()
    for key, value in SETTINGS:
        if key not in parsed:
            text = _adding(text, key, value)
            if text is None:
                return False, "VS Code 的设置文件无法解析，请先修正 %s" % remotessh._settings_path()
    try:
        os.makedirs(os.path.dirname(remotessh._settings_path()), exist_ok=True)
        with open(remotessh._settings_path(), "w", encoding="utf-8") as handle:
            handle.write(text)
        os.makedirs(_user_apps(), exist_ok=True)
        for system, user in launchers:
            # 用户自己改过的启动项照样在它的基础上加；没有就从系统那份复制
            source = user if os.path.isfile(user) else system
            with open(source, encoding="utf-8") as handle:
                original = handle.read()
            with open(user, "w", encoding="utf-8") as handle:
                handle.write(_with_env(original))
    except OSError as exc:
        return False, "写入失败：%s" % exc
    try:
        subprocess.run(["update-desktop-database", _user_apps()], capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        pass   # 没有这个命令：桌面过一会儿自己会重新读
    log.write("已开启读取 VS Code 弹框（%s）" % "、".join(os.path.basename(user) for _system, user in launchers))
    return True, "已开启读取 VS Code 弹框：关闭所有 VS Code 窗口、重新打开后生效"


def launch_env(base=None):
    """Kiteline 自己启动 VS Code 时用的环境变量（开启过才带上辅助功能）"""
    env = dict(os.environ if base is None else base)
    if enabled():
        env[ENV] = "1"
    return env


def _running():
    """有没有开着的 VS Code（主进程：Chromium 的子进程命令行里都带 --type=）"""
    for path in glob.glob("/proc/[0-9]*/cmdline"):
        try:
            exe = os.readlink(os.path.dirname(path) + "/exe")
            if not re.search(r"/(code|code-insiders|codium)$", exe):
                continue
            with open(path, "rb") as handle:
                if b"--type=" not in handle.read():
                    return True
        except OSError:
            continue
    return False


def needs_restart():
    """开启之前就开着的 VS Code 要重启才生效：VS Code 开着，却没有一个窗口向辅助功能登记。
    不看进程的环境变量：经 code 命令转手启动的主进程，/proc 里的环境变量没有 ACCESSIBILITY_ENABLED，实际却登记了（10-27 实测）"""
    if not _running():
        return False
    from . import atspi_linux
    return atspi_linux.editors_exposed() == 0
