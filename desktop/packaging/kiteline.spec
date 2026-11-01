# PyInstaller 配置：打出 Windows 版 Kiteline（目录形式，dist/Kiteline/Kiteline.exe）
# 在 Windows 上运行：desktop\packaging\build-windows.ps1
import os

from PyInstaller.utils.hooks import collect_dynamic_libs, collect_data_files

HERE = os.path.abspath(SPECPATH)
DESKTOP = os.path.dirname(HERE)
ROOT = os.path.dirname(DESKTOP)

datas = [
    (os.path.join(ROOT, "watcher", "kiteline-watch.py"), "."),
    (os.path.join(DESKTOP, "CHANGELOG.md"), "."),
    (os.path.join(DESKTOP, "CHANGELOG.en.md"), "."),   # 英文手机看的更新记录
    # 发给英文手机的字的翻译表（kiteline/i18n.py 在自己旁边找它）
    (os.path.join(DESKTOP, "kiteline", "i18n_en.json"), "kiteline"),
    # 世界模式的网页（客户端打开 http://127.0.0.1:端口/world/，见 docs/world.md）
    (os.path.join(ROOT, "Resources", "world"), "world"),
]
datas += collect_data_files("tzdata")
datas += collect_data_files("certifi")   # edge-tts 连微软时校验证书用的根证书包
# 远程访问库（p2p/ 编出来的；开源版没有，打出来的包只能在同一个网络里连）
P2P_DLL = os.path.join(DESKTOP, "kiteline", "lib", "tarsp2p.dll")
if os.environ.get("KITELINE_REQUIRE_P2P") == "1" and not os.path.exists(P2P_DLL):
    raise SystemExit("缺 kiteline/lib/tarsp2p.dll（发官网的包必须带远程访问）")
binaries =[(P2P_DLL, ".")] if os.path.exists(P2P_DLL) else []
binaries += collect_dynamic_libs("sherpa_onnx")

# watcher 是在打包后的程序里用 runpy 跑的，PyInstaller 看不到它 import 了什么：直接从源码里读出来，watcher 改了也不会漏
def _watcher_modules():
    import ast
    with open(os.path.join(ROOT, "watcher", "kiteline-watch.py"), encoding="utf-8") as handle:
        tree = ast.parse(handle.read())
    found = {"ctypes.wintypes"}
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            found.update(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module and node.level == 0:
            found.add(node.module)
    return sorted(found)


watcher_modules = _watcher_modules()

a = Analysis(
    [os.path.join(HERE, "entry.py")],
    pathex=[DESKTOP],
    binaries=binaries,
    datas=datas,
    # edge_tts（朗读的微软语音）在函数里才 import：写明，免得打包时漏掉
    hiddenimports=watcher_modules + ["kiteline.delivery_win", "kiteline.mdns", "pystray._win32", "PIL.Image", "PIL.ImageDraw",
                                     "edge_tts"],
    excludes=["tkinter", "matplotlib", "IPython"],
)
pyz = PYZ(a.pure)
# 打包版的 Python 不读 PYTHONUTF8 环境变量：直接开 UTF-8 模式（中文 Windows 默认 GBK，和 watcher 之间的管道会乱码）
exe = EXE(pyz, a.scripts, [("X utf8_mode=1", None, "OPTION")], exclude_binaries=True, name="Kiteline", console=False,
          icon=os.path.join(HERE, "kiteline.ico"))
coll = COLLECT(exe, a.binaries, a.datas, name="Kiteline")
