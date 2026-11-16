"""重启会话（同 Mac 版 Sources/SessionRestart.swift）：关掉再用同一个会话 id 接着聊，对话不丢；agent 重新读设置、技能、MCP
（新装的 Kiteline 浏览器技能、Playwright MCP 连 Kiteline 浏览器，老会话要重启才用得上）。
空闲的马上重启；正在工作 / 等你确认的不打断，等这一轮做完（变空闲）再自动重启。
原来在 VS Code 里的还在 VS Code 里接着，后台运行的还在后台（别因为「本机默认后台运行」挪了地方）"""

import json
import threading
import time

from . import delivery, log
from .httpd import Request


class SessionRestart:
    def __init__(self, app):
        self.app = app
        self.pending = set()
        self.lock = threading.Lock()
        self.watching = False

    def restart(self, keys):
        """→ {restarted, queued, failed}（restarted 是已经发起的；真正接上要几秒到十几秒）"""
        result = {"restarted": [], "queued": [], "failed": []}
        for key in keys:
            record = self.app.store.record(key)
            if not record:
                result["failed"].append({"key": key, "error": "会话不存在或已结束"})
                continue
            if record.snap.get("activity") in ("busy", "waiting"):
                with self.lock:
                    self.pending.add(key)
                result["queued"].append(key)
                continue
            threading.Thread(target=self._perform, args=(record,), name="restart", daemon=True).start()
            result["restarted"].append(key)
        if result["queued"]:
            self._watch()
        return result

    def is_pending(self, key):
        return key in self.pending

    def _watch(self):
        with self.lock:
            if self.watching:
                return
            self.watching = True

        def loop():
            while True:
                time.sleep(3)
                with self.lock:
                    keys = list(self.pending)
                for key in keys:
                    record = self.app.store.record(key)
                    if not record:
                        self.pending.discard(key)
                        continue
                    if record.snap.get("activity") in ("busy", "waiting"):
                        continue
                    self.pending.discard(key)
                    self._perform(record)
                with self.lock:
                    if not self.pending:
                        self.watching = False
                        return

        threading.Thread(target=loop, name="restart-watch", daemon=True).start()

    def _perform(self, record):
        key, snap = record.key, record.snap
        hosted = bool(snap.get("hosted"))
        log.write("重启会话「%s」（%s）" % (snap.get("name") or snap.get("title") or key, "后台运行" if hosted else "VS Code"))
        source = self.app.store.source(record.source_id)
        siblings = getattr(self.app.server, "siblings", None)   # 同名会话：VS Code 里认准是哪个标签（同 r_close）
        outcome = delivery.close(record, source, siblings(record) if siblings else [])
        if not outcome.ok:
            self._fail(record, outcome["message"])
            return
        deadline = time.time() + 30   # 等它真的结束（VS Code 关标签后 Claude 退出要几秒）
        while self.app.store.record(key) and time.time() < deadline:
            time.sleep(0.5)
        if self.app.store.record(key):
            self._fail(record, "会话没有关掉（可能正在等你确认，或电脑上的窗口没响应），请稍后再试")
            return
        time.sleep(1)
        body = json.dumps({"text": "", "submit": False, "editor": not hosted}).encode("utf-8")
        request = Request("POST", "/api/resume?key=" + key.replace("#", "%23"), {"Content-Type": "application/json"}, body, "127.0.0.1")
        try:
            response = self.app.resume(request)
            data = json.loads(response.body or b"{}")
            if response.status >= 400 or data.get("ok") is False:
                self._fail(record, data.get("message") or data.get("error") or "接着打开没成功")
        except Exception as exc:  # noqa: BLE001
            self._fail(record, str(exc))

    def _fail(self, record, message):
        log.write("重启会话失败：%s" % message)
        try:
            self.app.server.notify("error", record.snap.get("title") or "会话", "重启会话未成功：%s" % message, record.key)
        except Exception:  # noqa: BLE001
            pass
