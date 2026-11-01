"""入口：python -m kiteline [--background] [--headless]

  （无参数）   启动服务、打开控制台（浏览器），有托盘就挂托盘图标
  --background 开机自启用：不打开控制台
  --headless   没有图形界面的机器（服务器）：不打开控制台、不挂托盘，配对码打在终端里
  --pair       打印一次配对码和配对链接后继续运行
内部用：
  --run-script <脚本> …   打包版里跑 watcher（打包版没有独立的 python）
  --console-input <pid>   Windows：把 stdin 的文字写进这个进程所在控制台的输入缓冲区
  --vscreen-guard <pid>   Windows：等 Kiteline 退出，把留在虚拟屏幕上的 VS Code 窗口放回原处
"""

import os
import runpy
import signal
import sys
import threading


def main(argv):
    if len(argv) >= 2 and argv[0] == "--run-script":
        # 打包成窗口程序（无控制台）时 sys.stdin / stdout 是 None：父进程给的管道句柄还在，按文件描述符重新接上
        # 已经接上的也一律改成 UTF-8（打包版不认 PYTHONUTF8，中文 Windows 默认按 GBK 写管道）
        for fd, name, mode in ((0, "stdin", "r"), (1, "stdout", "w"), (2, "stderr", "w")):
            stream = getattr(sys, name)
            if stream is None:
                try:
                    setattr(sys, name, open(fd, mode, encoding="utf-8", closefd=False))
                except OSError:
                    setattr(sys, name, open(os.devnull, mode, encoding="utf-8"))
            elif getattr(stream, "encoding", "").lower().replace("-", "") != "utf8" and hasattr(stream, "reconfigure"):
                stream.reconfigure(encoding="utf-8")
        script = argv[1]
        sys.argv = [script] + argv[2:]
        runpy.run_path(script, run_name="__main__")
        return 0
    if argv and argv[0] == "--install-components":
        # 安装脚本里调：缺的组件（VS Code 配套扩展、键盘模拟权限、tmux）问一句当场装
        from . import setup_tools
        return setup_tools.interactive()
    if len(argv) >= 2 and argv[0] == "--console-input":
        from kiteline import delivery_win
        return delivery_win.console_input_main(int(argv[1]))
    if len(argv) >= 2 and argv[0] == "--vscreen-guard":
        from kiteline import vscreen
        return vscreen.guard_main(int(argv[1]))

    from kiteline import log, ui
    from kiteline.app import App
    headless = "--headless" in argv or (sys.platform.startswith("linux") and not os.environ.get("DISPLAY") and not os.environ.get("WAYLAND_DISPLAY"))
    if already_running(open_console=not headless and "--background" not in argv):
        return 0
    app = App()
    app.console = ui.Console(app)
    stop = threading.Event()
    app.request_exit = stop.set   # 装好更新后重启：这份退出，由更新脚本启动新版本
    app.start()
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, lambda *_: stop.set())
    if headless or "--pair" in argv:
        def show_pairing():
            stop.wait(3)
            info = app.console.pairing(False)
            print("\n手机访问：在 iPhone 上打开 Kiteline，输入配对码 %s（10 分钟有效）\n配对链接：%s\n" % (info["code"], info["link"]), flush=True)
        threading.Thread(target=show_pairing, daemon=True).start()
    if not headless and "--background" not in argv:
        threading.Timer(1.5, app.console.open).start()
    if not headless and "--no-tray" not in argv:
        tray = threading.Thread(target=ui.run_tray, args=(app, app.console, stop), daemon=True)
        tray.start()
    try:
        while not stop.wait(1):
            pass
    finally:
        log.write("Kiteline 退出")
        from kiteline import vscreen
        vscreen.prepare_for_quit()
        app.stop()
        # 新版本装好了、点过「稍后」：退出时换上，下次打开就是新版本（同 Mac 版）
        app.updater.install_on_quit()
    return 0


def already_running(open_console):
    """本用户已经有一份 Kiteline 在跑：让它打开控制台，这份直接退出（不抢端口、不起第二个 watcher）"""
    import json
    import urllib.request
    from kiteline import config
    mobile = config.read_json(config.path("config.json"), {}).get("mobile") or {}
    token, port = mobile.get("token"), mobile.get("port") or config.DEFAULT_MOBILE["port"]
    if not token:
        return False
    path = "/api/desktop/open" if open_console else "/api/desktop/status"
    request = urllib.request.Request("http://127.0.0.1:%s%s" % (port, path), data=b"{}" if open_console else None,
                                     headers={"X-CCP-Token": token, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=3) as response:
            json.load(response)
        print("Kiteline 已经在运行%s" % ("，已打开控制台" if open_console else ""), flush=True)
        return True
    except (OSError, ValueError):
        return False


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
