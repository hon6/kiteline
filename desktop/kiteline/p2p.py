"""远程访问（点对点）：手机不在同一个 Wi-Fi 时也能连这台电脑（对应 Mac 版 P2P.swift）。

内核是 p2p/（iroh）编成的动态库：Linux libtarsp2p.so、Windows tarsp2p.dll，C 接口见 p2p/include/tarsp2p.h。
电脑只接受绑定过的手机（设备记录里的 p2pId），每条连接转给本机的 HTTPS 服务。
"""

import ctypes
import hashlib
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request

from . import config, log

LIB_NAME = "tarsp2p.dll" if config.IS_WINDOWS else "libtarsp2p.so"
PAIR_GATEWAY = os.environ.get("CCPULSE_PAIR_GATEWAY") or "https://tars.betac.cn/pair"


def _find_lib():
    override = os.environ.get("KITELINE_P2P_LIB")
    candidates = [override] if override else []
    base = getattr(sys, "_MEIPASS", None)
    if base:
        candidates.append(os.path.join(base, LIB_NAME))
    here = os.path.dirname(os.path.abspath(__file__))
    candidates += [os.path.join(here, "lib", LIB_NAME), os.path.join(os.path.dirname(sys.executable), LIB_NAME)]
    for item in candidates:
        if item and os.path.exists(item):
            return item
    return None


class P2P:
    def __init__(self, devices):
        self.devices = devices
        self.status = {"state": "stopped"}
        self.on_change = None
        self._lib = None
        self._poller = None
        self._stop = threading.Event()
        self._last_mirrored = None
        path = _find_lib()
        if not path:
            log.write("没有远程访问库（%s），远程访问不可用" % LIB_NAME)
            return
        try:
            lib = ctypes.CDLL(path)
            lib.tars_p2p_start.restype = ctypes.c_void_p
            lib.tars_p2p_start.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
            lib.tars_p2p_status.restype = ctypes.c_void_p
            lib.tars_p2p_serve.restype = ctypes.c_void_p
            lib.tars_p2p_serve.argtypes = [ctypes.c_char_p]
            lib.tars_p2p_logs.restype = ctypes.c_void_p
            lib.tars_p2p_allow.argtypes = [ctypes.c_char_p]
            lib.tars_p2p_pairing.argtypes = [ctypes.c_int]
            lib.tars_p2p_free.argtypes = [ctypes.c_void_p]
            self._lib = lib
        except OSError as exc:
            log.write("远程访问库加载失败：%s" % exc)

    @property
    def available(self):
        return self._lib is not None

    def _take(self, pointer):
        if not pointer:
            return None
        try:
            return ctypes.string_at(pointer).decode("utf-8", "replace")
        finally:
            self._lib.tars_p2p_free(pointer)

    def start(self, relay, https_port):
        if not self._lib:
            self._update({"state": "error", "error": "这个版本没有远程访问组件"})
            return
        self.stop()
        key_path = config.path("p2p.key").encode("utf-8")
        error = self._take(self._lib.tars_p2p_start(key_path, (relay or "").strip().encode("utf-8")))
        if error:
            self._update({"state": "error", "error": error})
            return
        self.refresh_allowlist()
        error = self._take(self._lib.tars_p2p_serve(("127.0.0.1:%d" % https_port).encode("utf-8")))
        if error:
            self._update({"state": "error", "error": error})
            return
        self._stop.clear()
        self._poller = threading.Thread(target=self._poll, daemon=True)
        self._poller.start()
        log.write("远程访问启动（中继：%s）" % (relay or "iroh 公共中继"))

    def stop(self):
        self._stop.set()
        if self._lib:
            self._lib.tars_p2p_stop()
        self._update({"state": "stopped"})

    def refresh_allowlist(self):
        if self._lib:
            self._lib.tars_p2p_allow(",".join(self.devices.p2p_ids).encode("utf-8"))

    def open_pairing(self, code=None, fingerprint=None, on_conflict=None, current_code=None):
        """显示配对码时：10 分钟内放没绑定的手机经中继连进来配对，并把配对码的哈希和本机公钥报给 Kiteline 服务器。
        服务器回 409（这个码正被别的电脑占着）就调 on_conflict 换码"""
        if not self._lib:
            return
        self._lib.tars_p2p_pairing(600)
        if not code:
            return

        def announce():
            for _ in range(20):
                if self.status.get("id"):
                    break
                time.sleep(0.5)
            node, relay = self.status.get("id"), self.status.get("relay")
            if not node or not relay or (current_code and current_code() != code):
                return
            key = hashlib.sha256(("kiteline-pair/%s" % code).encode("utf-8")).hexdigest()
            body = json.dumps({"key": key, "id": node, "relay": relay, "fp": fingerprint or ""}).encode("utf-8")
            request = urllib.request.Request(PAIR_GATEWAY + "/announce", data=body, method="POST",
                                             headers={"Content-Type": "application/json"})
            try:
                urllib.request.urlopen(request, timeout=15).read()
            except urllib.error.HTTPError as exc:
                if exc.code == 409 and on_conflict:
                    on_conflict()
                else:
                    log.write("配对码未报上 Kiteline 服务器（%d）：手机只能在同一 Wi-Fi 中输入配对码" % exc.code)
            except OSError:
                log.write("配对码未报上 Kiteline 服务器（无法连接）：手机只能在同一 Wi-Fi 中输入配对码")
        threading.Thread(target=announce, daemon=True).start()

    @property
    def join_info(self):
        node = self.status.get("id")
        if not node:
            return None
        return {"id": node, "relay": self.status.get("relay") or "", "addrs": self.status.get("addrs") or []}

    def logs(self):
        return self._take(self._lib.tars_p2p_logs()) if self._lib else ""

    def _poll(self):
        interval = 2
        while not self._stop.wait(interval):
            self._mirror_logs()
            text = self._take(self._lib.tars_p2p_status())
            try:
                status = json.loads(text) if text else None
            except ValueError:
                status = None
            if not status:
                continue
            if status.get("state") == "online" and self.status.get("state") != "online":
                log.write("远程访问已连上中继：%s" % status.get("relay"))
                interval = 30
            self._update(status)

    def _mirror_logs(self):
        lines = (self.logs() or "").splitlines()
        start = 0
        if self._last_mirrored in lines:
            start = len(lines) - lines[::-1].index(self._last_mirrored)
        for line in lines[start:]:
            if any(word in line for word in ("手机连进来", "拒绝", "没建成", "连不上本机服务")):
                log.write("远程访问：%s" % line)
        if lines:
            self._last_mirrored = lines[-1]

    def _update(self, status):
        if status == self.status:
            return
        self.status = status
        if self.on_change:
            try:
                self.on_change(status)
            except Exception:  # noqa: BLE001
                pass
