"""登录时自动启动：Windows 写注册表 HKCU\\...\\Run，Linux 写 ~/.config/autostart/kiteline.desktop"""

import os
import sys

from . import config

RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"


def _command():
    if getattr(sys, "frozen", False):
        return [sys.executable, "--background"]
    return [sys.executable, "-m", "kiteline", "--background"]


def _legacy_windows_paths():
    """旧版写在「启动」文件夹里的 .cmd / .lnk（登录时会闪一下黑框）：开关时一并清掉"""
    folder = os.path.join(os.environ.get("APPDATA", ""), "Microsoft", "Windows", "Start Menu", "Programs", "Startup")
    return [os.path.join(folder, "Kiteline.cmd"), os.path.join(folder, "Kiteline.lnk")]


def _linux_path():
    return os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "autostart", "kiteline.desktop")


def _windows_command():
    if getattr(sys, "frozen", False):
        return '"%s" --background' % sys.executable
    # 源码运行：Run 项设不了工作目录，写一个小启动脚本把 desktop 目录加进 sys.path，用 pythonw 起（没有黑框）
    launcher = config.path("autostart.pyw")
    desktop = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    config.write_private(launcher, "import sys\nsys.path.insert(0, %r)\nfrom kiteline.__main__ import main\nsys.exit(main([\"--background\"]))\n" % desktop)
    pythonw = os.path.join(os.path.dirname(sys.executable), "pythonw.exe")
    return '"%s" "%s"' % (pythonw if os.path.exists(pythonw) else sys.executable, launcher)


def enabled():
    if config.IS_WINDOWS:
        import winreg
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
                winreg.QueryValueEx(key, "Kiteline")
                return True
        except OSError:
            return any(os.path.exists(p) for p in _legacy_windows_paths())
    service = os.path.expanduser("~/.config/systemd/user/kiteline.service")
    return os.path.exists(_linux_path()) or os.path.exists(service)


def set_enabled(on):
    if config.IS_WINDOWS:
        import winreg
        for legacy in _legacy_windows_paths():
            if os.path.exists(legacy):
                os.remove(legacy)
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
            if on:
                winreg.SetValueEx(key, "Kiteline", 0, winreg.REG_SZ, _windows_command())
            else:
                try:
                    winreg.DeleteValue(key, "Kiteline")
                except OSError:
                    pass
        return
    path = _linux_path()
    if on:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        # 源码运行（python -m kiteline）要在 desktop 目录里起：Path= 设工作目录
        workdir = "" if getattr(sys, "frozen", False) else "Path=%s\n" % os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("[Desktop Entry]\nType=Application\nName=Kiteline\nComment=在手机上跟进和回复 Claude Code\n"
                         "Exec=%s\n%sX-GNOME-Autostart-enabled=true\nTerminal=false\n" % (" ".join('"%s"' % p if " " in p else p for p in _command()), workdir))
    elif os.path.exists(path):
        os.remove(path)


def installed():
    """正式安装的版本（Windows 打包版、Linux install.sh 装的）才默认开机自启；直接从源码跑的开发版不动"""
    if config.IS_WINDOWS:
        return bool(getattr(sys, "frozen", False))
    from .updater import Updater
    return bool(Updater.install_home())


def ensure_default(cfg):
    """装好后第一次运行：默认打开开机自启（只做一次，之后用户在设置里关了就不再动）；
    已开启的 Windows 版顺带把启动命令更新成现在的位置（解压到别处、更新后换了文件夹时旧路径会失效）"""
    if os.environ.get("KITELINE_CONFIG_DIR") or not installed():
        return
    try:
        if not cfg.mobile.get("autostartDefaulted"):
            if not enabled():
                set_enabled(True)
            cfg.update(lambda d: d["mobile"].update({"autostartDefaulted": True}))
        elif config.IS_WINDOWS and enabled() and _registered_command() not in (None, _windows_command()):
            set_enabled(True)
    except Exception as exc:  # noqa: BLE001
        from . import log
        log.write("开机自启设置失败：%s" % exc)


def _registered_command():
    import winreg
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:
            return winreg.QueryValueEx(key, "Kiteline")[0]
    except OSError:
        return None
