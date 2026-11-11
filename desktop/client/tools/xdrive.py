# 客户端真窗口点测：Xvfb :77 里起客户端（desktop/client/tools/xdrive.sh），这个脚本经 XTEST 发真鼠标 / 键盘、截整屏
# 用法：x.py shot <png> | click x y | rclick x y | type 文字 | key 名 | move x y
import sys, time
from Xlib import X, display, XK
from Xlib.ext import xtest
from PIL import Image
d = display.Display(); root = d.screen().root
cmd = sys.argv[1]
def btn(b, x, y):
    xtest.fake_input(d, X.MotionNotify, x=int(x), y=int(y)); d.sync(); time.sleep(0.08)
    xtest.fake_input(d, X.ButtonPress, b); d.sync(); time.sleep(0.06)
    xtest.fake_input(d, X.ButtonRelease, b); d.sync()
if cmd == "shot":
    g = root.get_geometry(); raw = root.get_image(0, 0, g.width, g.height, X.ZPixmap, 0xffffffff)
    Image.frombytes("RGB", (g.width, g.height), raw.data, "raw", "BGRX").save(sys.argv[2])
elif cmd == "click": btn(1, sys.argv[2], sys.argv[3])
elif cmd == "rclick": btn(3, sys.argv[2], sys.argv[3])
elif cmd == "move": xtest.fake_input(d, X.MotionNotify, x=int(sys.argv[2]), y=int(sys.argv[3])); d.sync()
elif cmd == "key":
    for name in sys.argv[2:]:
        mods = name.split("+"); k = mods.pop()
        codes = [d.keysym_to_keycode(XK.string_to_keysym(m)) for m in mods]
        kc = d.keysym_to_keycode(XK.string_to_keysym(k))
        for c in codes: xtest.fake_input(d, X.KeyPress, c)
        xtest.fake_input(d, X.KeyPress, kc); xtest.fake_input(d, X.KeyRelease, kc)
        for c in reversed(codes): xtest.fake_input(d, X.KeyRelease, c)
        d.sync(); time.sleep(0.1)
elif cmd == "type":  # 只打 ASCII
    for ch in sys.argv[2]:
        ks = XK.string_to_keysym(ch) or ord(ch); kc = d.keysym_to_keycode(ks)
        shift = ch.isupper()
        if shift: xtest.fake_input(d, X.KeyPress, d.keysym_to_keycode(XK.XK_Shift_L))
        xtest.fake_input(d, X.KeyPress, kc); xtest.fake_input(d, X.KeyRelease, kc)
        if shift: xtest.fake_input(d, X.KeyRelease, d.keysym_to_keycode(XK.XK_Shift_L))
        d.sync(); time.sleep(0.03)
if cmd == "wheel":  # wheel x y 按钮(4上 5下 6左 7右) 次数
    xtest.fake_input(d, X.MotionNotify, x=int(sys.argv[2]), y=int(sys.argv[3])); d.sync(); time.sleep(0.1)
    for _ in range(int(sys.argv[5])):
        xtest.fake_input(d, X.ButtonPress, int(sys.argv[4])); xtest.fake_input(d, X.ButtonRelease, int(sys.argv[4])); d.sync(); time.sleep(0.05)
