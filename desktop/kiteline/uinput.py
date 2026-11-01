"""Linux 虚拟键盘（/dev/uinput）：Wayland 桌面上给 VS Code 里的 Claude Code 按回车、选确认框选项。

Wayland 不许普通程序模拟按键，内核的 uinput 设备不受这个限制。要能写 /dev/uinput：一键安装加一条 udev 规则
（TAG+="uaccess"：只给当前坐在屏幕前登录的用户，切到别的用户或注销就收回），见 setup_tools.UINPUT_SCRIPT。
只按 KEYS 里写死的几个键，按哪个由投递代码决定，手机请求里的内容决定不了。
设备在第一次用时建好、一直留着：新建的键盘要等桌面认出来（约半秒），每次现建会把按键丢掉。
"""

import os
import struct
import threading

try:
    import fcntl
except ImportError:   # Windows 没有 fcntl：也没有 /dev/uinput，available() 恒为 False，用不到它；只是别让整个程序导入就崩
    fcntl = None
import time

DEVICE = "/dev/uinput"
NAME = b"Kiteline virtual keyboard"

# linux/uinput.h、linux/input-event-codes.h
UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_DEV_SETUP = 0x405C5503   # _IOW('U', 3, struct uinput_setup)，结构体 92 字节
UI_DEV_CREATE = 0x5501
EV_SYN, EV_KEY, SYN_REPORT = 0, 1, 0
BUS_VIRTUAL = 0x06

# 能按的键：名字 → 依次按下的键码
KEYS = {
    "enter": (28,),
    "esc": (1,),
    "1": (2,),
    "2": (3,),
    "3": (4,),
    "4": (5,),
    "shift+tab": (42, 15),
    "ctrl+w": (29, 17),   # 关闭会话：VS Code 的「关闭编辑器」（只由 delivery.close 按，手机按不到）
}
SETTLE = 0.8   # 新设备建好后等这么久再按

_lock = threading.Lock()
_fd = None
_ready_at = 0.0


def available():
    return os.path.exists(DEVICE) and os.access(DEVICE, os.W_OK)


def _device():
    global _fd, _ready_at
    if _fd is not None:
        return _fd
    fd = os.open(DEVICE, os.O_WRONLY | os.O_NONBLOCK)
    try:
        fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
        for codes in KEYS.values():
            for code in codes:
                fcntl.ioctl(fd, UI_SET_KEYBIT, code)
        fcntl.ioctl(fd, UI_DEV_SETUP, struct.pack("HHHH80sI", BUS_VIRTUAL, 0x1D6B, 0x4B4C, 1, NAME, 0))
        fcntl.ioctl(fd, UI_DEV_CREATE)
    except OSError:
        os.close(fd)
        raise
    _fd = fd
    _ready_at = time.monotonic() + SETTLE
    return fd


def _emit(fd, kind, code, value):
    now = time.time()
    os.write(fd, struct.pack("llHHi", int(now), int((now % 1) * 1_000_000), kind, code, value))


def tap(name):
    """按一下（组合键依次按下、倒序松开）。name 必须在 KEYS 里"""
    codes = KEYS[name]
    with _lock:
        fd = _device()
        wait = _ready_at - time.monotonic()
        if wait > 0:
            time.sleep(wait)
        for code in codes:
            _emit(fd, EV_KEY, code, 1)
        _emit(fd, EV_SYN, SYN_REPORT, 0)
        for code in reversed(codes):
            _emit(fd, EV_KEY, code, 0)
        _emit(fd, EV_SYN, SYN_REPORT, 0)
