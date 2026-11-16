"""会话终端的归属和设备名，以及 agent 的 term run（在会话终端里跑命令，不在桌面另开终端窗口）。同 Mac 的 Sources/TermRelay.swift。

- 终端开在哪台电脑上，标签上就写哪台的名字（本机写电脑名，远端写来源名）。
- term run --on <设备>：会话在 A、命令要在 B 上跑。A 的 watcher 发 term_run → 这里请 B 的 watcher 开终端（会话 id 用 A 上那个）
  → B 的输出、退出码按事件里的 relay 转回 A（term_run_feed）。B 上的终端显示在 A 会话的终端面板里（foreign 记着实际在哪台）。
"""
import platform
import socket
import threading

from . import log


class TermRelay:
    def __init__(self, app):
        self.app = app
        self.lock = threading.Lock()
        self.foreign = {}        # 终端 id → (实际所在来源 id, 显示在哪个会话 key 下)
        self.finished = set()    # 退出码已转回去的交接号

    # --- 设备名 ---

    def device_name(self, source_id):
        source = self.app.store.source(source_id)
        if not source:
            return source_id
        if source.kind == "local":
            return (platform.node() or socket.gethostname() or source.name).split(".")[0]
        return source.name

    def label(self, term, source_id):
        if not isinstance(term, dict):
            return None
        out = dict(term)
        out["device"] = self.device_name(source_id)
        out["sourceId"] = source_id
        return out

    # --- 归属 ---

    def key(self, source_id, session_id):
        own = "%s#%s" % (source_id, session_id)
        if not session_id or self.app.store.record(own):
            return own
        with self.app.store.lock:
            for record in self.app.store.records:
                if record.snap.get("sessionId") == session_id:
                    return record.key
        return own

    def foreign_terms(self, key):
        with self.lock:
            out = {}
            for tid, (source_id, owner) in self.foreign.items():
                if owner == key:
                    out.setdefault(source_id, []).append(tid)
            return out

    def route(self, tid):
        with self.lock:
            value = self.foreign.get(tid or "")
            return value[0] if value else None

    def count(self, key):
        with self.lock:
            return sum(1 for _, owner in self.foreign.values() if owner == key)

    # --- 事件 ---

    def event(self, kind, event, source):
        """watcher 的 term / term_exit / term_open"""
        tid = event.get("term")
        if not tid:
            return
        session_id = event.get("sessionId") or ""
        key = self.key(source.id, session_id)
        with self.lock:
            if kind == "term_exit" and not event.get("keep"):
                self.foreign.pop(tid, None)
            elif not key.startswith(source.id + "#"):
                self.foreign[tid] = (source.id, key)
        payload = {k: v for k, v in event.items() if k not in ("event", "sessionId", "relay")}
        payload["key"] = key
        payload["device"] = self.device_name(source.id)
        if isinstance(event.get("info"), dict):
            payload["info"] = self.label(event["info"], source.id)
        if session_id:
            self.app.server.publish(kind, payload)
        relay = event.get("relay")
        if isinstance(relay, dict):
            self._feed_back(kind, event, relay)

    def _feed_back(self, kind, event, relay):
        rid, origin = relay.get("rid"), self.app.store.source(relay.get("from") or "")
        if not rid or not origin:
            return
        body = {"cmd": "term_run_feed", "rid": rid}
        if kind == "term":
            if not event.get("data"):
                return
            body["data"] = event["data"]
        elif kind == "term_exit":
            with self.lock:
                if rid in self.finished:
                    return
                self.finished.add(rid)
            body["exit"] = event.get("code")
        else:
            return
        self._send(origin, body)

    def _send(self, source, body):
        # 事件是在读 watcher 输出的线程里处理的：请求放到别的线程发，免得等自己的应答
        def go():
            try:
                source.request(body, timeout=20)
            except Exception as exc:  # noqa: BLE001
                log.write("term run 转发失败：%s" % exc)
        threading.Thread(target=go, daemon=True).start()

    # --- term run --on ---

    def run(self, event, origin):
        rid, command = event.get("rid"), event.get("run")
        if not rid or not command:
            return
        threading.Thread(target=self._run, args=(event, origin), daemon=True).start()

    def _run(self, event, origin):
        rid = event["rid"]
        session_id = event.get("sessionId") or ""
        want = (event.get("on") or "").strip()

        def fail(message):
            log.write("term run %s：%s" % (rid, message))
            self._send(origin, {"cmd": "term_run_feed", "rid": rid, "error": message})

        target = self.resolve_device(want)
        if not target:
            return fail("找不到叫「%s」的设备（可用：%s）" % (want, "、".join(self.device_name(s.id) for s in self.app.store.sources.values())))
        if not target.live:
            return fail("「%s」现在没连上" % self.device_name(target.id))
        body = {"cmd": "term", "op": "open", "sessionId": session_id, "run": event["run"], "cwd": event.get("cwd") or "",
                "cols": event.get("cols") or 120, "rows": event.get("rows") or 32, "relay": {"rid": rid, "from": origin.id}}
        if event.get("title"):
            body["title"] = event["title"]
        device = self.device_name(target.id)
        log.write("term run %s：会话 %s 请「%s」跑 %s" % (rid, session_id[:8], device, event["run"][:200]))
        try:
            response = target.request(body, timeout=30)
        except Exception as exc:  # noqa: BLE001
            return fail(str(exc))
        term = response.get("term") or {}
        if not term.get("term"):
            return fail(response.get("error") or "没开起来")
        key = self.key(target.id, session_id)
        if not key.startswith(target.id + "#"):
            with self.lock:
                self.foreign[term["term"]] = (target.id, key)
        self._send(origin, {"cmd": "term_run_feed", "rid": rid, "started": True, "term": term["term"], "device": device,
                            "cwd": term.get("cwd") or ""})

    def cancel(self, event, origin):
        rid = event.get("rid")
        if not rid:
            return

        def go():
            for source in list(self.app.store.sources.values()):
                if not source.live:
                    continue
                try:
                    listed = source.request({"cmd": "term", "op": "list"}, timeout=10)
                except Exception:  # noqa: BLE001
                    continue
                for term in listed.get("terms") or []:
                    if (term.get("relay") or {}).get("rid") == rid and not term.get("ended"):
                        try:
                            source.request({"cmd": "term", "op": "input", "term": term["term"], "data": "\x03"}, timeout=10)
                        except Exception:  # noqa: BLE001
                            pass
        threading.Thread(target=go, daemon=True).start()

    def resolve_device(self, want):
        needle = want.lower()
        sources = list(self.app.store.sources.values())

        def names(source):
            out = [source.name or "", source.id, self.device_name(source.id), getattr(source, "host", "") or ""]
            if source.kind == "local":
                out += ["local", "本机", "localhost", "这台电脑", platform.system().lower()]
            return [n.lower() for n in out if n]

        for source in sources:
            if needle in names(source):
                return source
        partial = [s for s in sources if any(needle in n for n in names(s))]
        return partial[0] if len(partial) == 1 else None
