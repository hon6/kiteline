"""Linux：一键安装从手机发消息要用的组件。就绪检查里的「一键安装」（POST /api/readiness/fix）、托盘菜单、install-linux.sh 都走这里。

在电脑上弹出系统的授权窗口（pkexec）安装；没有授权代理时开一个终端跑 sudo；都不行就把命令交给用户自己跑。
手机只能触发这个窗口，不知道电脑的密码装不上。装哪些包、跑什么命令都写死在这里，请求里的内容一律不拼进命令。

要支持新的组件：往 COMPONENTS 加一项，再挂到 ACTIONS 里某个动作下。组件三种装法：
  packages：系统软件包（要管理员权限，经包管理器装）
  script：要管理员权限的固定命令（比如写 udev 规则）
  install：不用管理员权限、Kiteline 自己装（比如 VS Code 配套扩展）
"""

import os
import shlex
import shutil
import subprocess
import sys
import threading

from . import bridge, config, delivery, log, shellext, uinput, vscode_a11y

# 授予键盘模拟权限：只给当前坐在屏幕前登录的用户写 /dev/uinput（TAG+="uaccess"，切到别的用户或注销就收回），开机自动加载 uinput 模块
UINPUT_RULE = 'KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"'
UINPUT_SCRIPT = ("echo %s > /etc/udev/rules.d/70-kiteline-uinput.rules && echo uinput > /etc/modules-load.d/kiteline-uinput.conf"
                 " && modprobe uinput && udevadm control --reload-rules && udevadm trigger --name-match=uinput" % shlex.quote(UINPUT_RULE))

# 组件：装好以后能找到哪些命令（有一个就算有）或者怎么检查、怎么装
COMPONENTS = {
    # X11 上没装配套扩展时的老办法（delivery_x11）：xdotool 操作窗口、xclip 粘贴。一键安装不再装它们
    "xdotool": {"bins": ("xdotool",), "packages": {"apt-get": "xdotool", "dnf": "xdotool", "pacman": "xdotool", "zypper": "xdotool"}},
    "clipboard": {"bins": ("xclip", "xsel"), "packages": {"apt-get": "xclip", "dnf": "xclip", "pacman": "xclip", "zypper": "xclip"}},
    "tmux": {"bins": ("tmux",), "packages": {"apt-get": "tmux", "dnf": "tmux", "pacman": "tmux", "zypper": "tmux"}},
    # VS Code 里的 Kiteline 配套扩展：切会话、核对前台、粘贴（Wayland 上只能靠它，见 bridge.py）
    # 两项都只在装了 VS Code 系编辑器时才需要（只在终端里用 Claude Code 的不用装）
    "vscode-bridge": {"check": lambda: bridge.installed() or not bridge.editors(), "install": bridge.install, "label": "VS Code 配套扩展"},
    # 键盘模拟权限：在 VS Code 里按回车、选确认框选项（见 uinput.py）
    "uinput": {"check": lambda: uinput.available() or not bridge.editors(), "script": UINPUT_SCRIPT, "label": "键盘模拟权限"},
    # Kiteline 的 GNOME 扩展：替你把 VS Code 切到前台（Wayland 下只能靠它）、虚拟屏幕（见 shellext.py）；
    # 只在 GNOME 45+ 上需要，装好后注销并重新登录一次生效
    "gnome-shell": {"check": lambda: not shellext.applicable() or shellext.installed(), "install": shellext.install,
                    "label": "Kiteline 的 GNOME 扩展"},
    # 读取 VS Code 弹框、自动按「Open here anyway」：VS Code 带辅助功能启动 + 两项设置（见 vscode_a11y.py）。
    # 会改 VS Code 的设置和启动项，由用户在就绪检查里自己点开启，不放进「安装所需组件」
    "vscode-a11y": {"check": lambda: vscode_a11y.enabled() or not bridge.editors(), "install": vscode_a11y.enable,
                    "label": "读取 VS Code 弹框"},
}

# 就绪检查里能「一键装」的动作（白名单）：动作 id → 要装的组件
ACTIONS = {
    "install-vscode-tools": ("vscode-bridge", "uinput", "gnome-shell"),   # 往 VS Code 发消息：配套扩展 + 按回车 + 切前台（X11、Wayland 都用这一套）
    "install-gnome-shell": ("gnome-shell",),             # 替你切换到 VS Code、虚拟屏幕
    "install-tmux": ("tmux",),                          # 往终端里的会话发消息
    "enable-vscode-a11y": ("vscode-a11y",),             # 读取 VS Code 弹框、自动接管「仍在别处打开」的会话
}
# 托盘菜单「安装所需组件」：上面几项一起装
ACTIONS["install-all"] = ACTIONS["install-vscode-tools"] + ACTIONS["install-tmux"]

# 在 tmux 里运行 claude 的现成命令：在项目目录里运行；已有同名会话就直接接回去
TMUX_COMMAND = delivery.TMUX_COMMAND

# 包管理器 → 安装命令；apt 的软件源列表过期时先 update 再装一次
_MANAGERS = (
    ("apt-get", "apt-get install -y {pkgs} || (apt-get update -q && apt-get install -y {pkgs})"),
    ("dnf", "dnf install -y {pkgs}"),
    ("pacman", "pacman -S --noconfirm --needed {pkgs}"),
    ("zypper", "zypper --non-interactive install {pkgs}"),
)
# 没有授权代理时开终端：终端名 → 让它执行一条 sh 命令的参数
_TERMINALS = (
    ("gnome-terminal", ["--", "sh", "-c"]),
    ("konsole", ["-e", "sh", "-c"]),
    ("xfce4-terminal", ["-x", "sh", "-c"]),
    ("x-terminal-emulator", ["-e", "sh", "-c"]),
    ("xterm", ["-e", "sh", "-c"]),
)

_busy = threading.Lock()


def missing(action_id=None):
    """某个动作（不给 = 全部）里还缺哪些组件。只有 Linux 才缺"""
    if not config.IS_LINUX:
        return []
    names = ACTIONS.get(action_id, ()) if action_id else tuple(COMPONENTS)
    return [name for name in names if not _present(name)]


def _present(name):
    item = COMPONENTS[name]
    if item.get("check"):
        try:
            return bool(item["check"]())
        except Exception:  # noqa: BLE001
            return False
    return any(shutil.which(b) for b in item["bins"])


def label(name):
    return COMPONENTS[name].get("label") or name


def _manager():
    for tool, template in _MANAGERS:
        if shutil.which(tool):
            return tool, template
    return None, None


def _script(components):
    """要管理员权限的那部分：包管理器装软件包 + 固定命令（不用管理员权限的组件不在这里）"""
    tool, template = _manager()
    parts = []
    pkgs = sorted({COMPONENTS[name]["packages"][tool] for name in components
                   if tool and tool in COMPONENTS[name].get("packages", {})})
    if pkgs:
        parts.append(template.format(pkgs=" ".join(pkgs)))
    parts += [COMPONENTS[name]["script"] for name in components if COMPONENTS[name].get("script")]
    if len(parts) == 1:
        return parts[0]
    return " && ".join("(%s)" % part for part in parts)


def _user_level(components):
    return [name for name in components if COMPONENTS[name].get("install")]


def manual_command(action_id):
    """让用户自己在终端里跑的命令"""
    script = _script(missing(action_id) or ACTIONS.get(action_id, ()))
    if not script:
        return ""
    return "sudo sh -c " + shlex.quote(script)


def action(action_id, label="一键安装"):
    """就绪检查项上挂的按钮：这个动作有缺的组件、能认出包管理器时才有"""
    needed = missing(action_id) if action_id in ACTIONS else []
    if not needed or not (_script(needed) or _user_level(needed)):
        return None
    return {"id": action_id, "label": label, "command": manual_command(action_id)}


def start(action_id):
    """执行就绪检查里的动作。返回 (ok, message)；ok=True 表示已在电脑上弹出授权窗口 / 打开终端，或者本来就不缺"""
    if action_id not in ACTIONS:
        return False, "不支持的操作"
    components = missing(action_id)
    if not components:
        return True, "所需组件都已安装"
    user = _user_level(components)
    root = [name for name in components if name not in user]
    script = _script(root)
    if root and not script:
        return False, "没认出这台电脑的软件包管理器：请手动安装 %s" % "、".join(label(name) for name in root)
    command = manual_command(action_id) if root else ""
    if delivery.DRY_RUN:   # 测试实例：只说要做什么，不真装、不弹窗
        steps = ["安装%s" % label(name) for name in user] + (["执行：%s" % command] if command else [])
        return True, "（测试）将在电脑上%s" % "；".join(steps)
    # 不用管理员权限的先装（VS Code 配套扩展，几秒钟）
    done = []
    for name in user:
        ok, message = COMPONENTS[name]["install"]()
        if not ok:
            return False, message
        done.append(message)
    if not root:
        return True, "；".join(done) + ("。已打开的 VS Code 窗口需要关闭后重新打开" if "vscode-bridge" in user else "")
    if done:
        log.write("；".join(done))
    if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        return False, "电脑没有图形界面，请在电脑的终端里运行：%s" % command
    if not _busy.acquire(blocking=False):
        return True, "正在安装：请在电脑上完成授权"
    try:
        if shutil.which("pkexec"):
            threading.Thread(target=_pkexec, args=(script, command), daemon=True).start()
            return True, "已在电脑上弹出授权窗口：请在电脑上输入密码，安装大约需要半分钟"
        opened = _terminal(script)
    except Exception:  # noqa: BLE001
        _busy.release()
        raise
    _busy.release()
    if opened:
        return True, "已在电脑上打开终端：请在终端里输入密码完成安装"
    return False, "请在电脑的终端里运行：%s" % command


def _pkexec(script, command):
    try:
        result = subprocess.run(["pkexec", "sh", "-c", script], capture_output=True, timeout=900)
        if result.returncode == 0:
            log.write("已安装从手机发消息所需的组件")
        elif result.returncode == 126:
            log.write("安装组件：在电脑上取消了授权")
        elif result.returncode == 127:
            # 没有授权代理（比如 Kiteline 不是在桌面里启动的）：改开终端，在终端里输密码
            log.write("安装组件：电脑上没有授权代理，改为打开终端")
            if not _terminal(script):
                log.write("安装组件：也打不开终端，请在电脑终端运行：%s" % command)
        else:
            log.write("安装组件失败（%d）：%s" % (result.returncode, result.stderr.decode("utf-8", "replace")[-300:]))
    except (OSError, subprocess.SubprocessError) as error:
        log.write("安装组件失败：%s" % error)
    finally:
        _busy.release()


def _terminal(script):
    tail = "; echo; echo 完成后可以关闭这个窗口; read _"
    for name, args in _TERMINALS:
        if shutil.which(name):
            try:
                subprocess.Popen([name] + args + ["sudo sh -c %s%s" % (shlex.quote(script), tail)],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 start_new_session=True)
                return True
            except OSError:
                continue
    return False


def interactive():
    """安装脚本（install-linux.sh）里调：列出缺的组件，问一句「现在安装吗」，当场装（sudo 在终端里要密码）"""
    needed = missing("install-all")
    if not needed:
        return 0
    print("要从手机向 VS Code 和终端里的会话发送消息，还需要：%s" % "、".join(label(name) for name in needed))
    if "uinput" in needed:
        print("（键盘模拟权限只用来在 VS Code 里按回车、选确认框选项，只授予当前登录在这台电脑屏幕前的用户）")
    root = [name for name in needed if name not in _user_level(needed)]
    command = "sudo sh -c " + shlex.quote(_script(root)) if root and _script(root) else ""
    if not sys.stdin.isatty():
        print("可在手机「设置 → 就绪检查」里一键安装%s" % ("，或运行：%s" % command if command else ""))
        return 0
    answer = input("现在安装吗？[Y/n] ").strip().lower()
    if answer in ("n", "no"):
        print("跳过。以后可在手机「设置 → 就绪检查」里一键安装%s" % ("，或运行：%s" % command if command else ""))
        return 0
    for name in _user_level(needed):
        print(COMPONENTS[name]["install"]()[1])
    if command:
        if subprocess.run(["sudo", "sh", "-c", _script(root)]).returncode != 0:
            print("安装没成功：稍后运行 %s" % command)
            return 1
    print("已装好。已打开的 VS Code 窗口需要关闭后重新打开")
    return 0
