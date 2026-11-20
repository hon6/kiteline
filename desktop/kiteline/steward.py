"""总管模式（实验性，同 Mac 版 Sources/Steward.swift）：用户在设置里选一台电脑、一个 agent 当「总管」，以后直接对总管说需求，
总管找设备、项目、会话派活、盯进度、验收、汇报。

- 总管就是一个普通会话，工作目录是那台电脑上的 ~/.ccpulse/steward（里面的 CLAUDE.md / AGENTS.md 是说明书，开启时由 watcher 照它的 STEWARD_BRIEF 写）。
- 这里把设备、项目、运行中的会话整理成目录推给总管那台电脑（{"cmd":"steward","directory":…}），总管用 steward state 看。
- watcher 发图通道里的 steward_op（steward assign / new / group / report）照着做：派活、新开会话、拉群、把汇报送进总管的会话。
- 设置存在配置目录的 steward.json。
"""

import json
import os
import threading
import time
import types

from . import aggregate, config, delivery, log
from .store import display_title

def same_dir(a, b):
    """两个目录是不是同一个：去掉末尾的分隔符，macOS 的 /tmp、/var 实际在 /private 下；Windows 不分大小写、斜杠方向"""
    def norm(path):
        p = str(path or "").replace("\\", "/").rstrip("/") or "/"
        for prefix in ("/private/tmp", "/private/var", "/private/etc"):
            if p == prefix or p.startswith(prefix + "/"):
                p = p[len("/private"):]
        return p.lower() if len(p) > 1 and p[1] == ":" else p
    return norm(a) == norm(b)


def steward_available(cfg=None):
    """还在做（11-20）：默认不对外（features 里不带 steward，各端看不到入口）。开发、试用时打开：
    环境变量 KITELINE_STEWARD=1，或配置 mobile.stewardPreview = true"""
    if os.environ.get("KITELINE_STEWARD") == "1":
        return True
    try:
        return bool((cfg.mobile or {}).get("stewardPreview"))
    except Exception:  # noqa: BLE001
        return False


class Steward:
    DEFAULTS = {"enabled": False, "sourceId": "", "agent": "claude-code", "existing": "keep", "speak": True,
                "sessionId": None, "cwd": None, "enabledAt": None}

    def __init__(self, app):
        self.app = app
        self._file = config.path("steward.json")
        self.settings = dict(self.DEFAULTS, **config.read_json(self._file, {}))
        self._lock = threading.RLock()
        self._pushed = None
        self._push_timer = None
        self._handled = []
        self.starting = False
        # 调度记录（手机上「总管」页画派活过程用，同 Mac 版 Steward.Board）：只留最近 12 小时
        self._board_file = config.path("steward-board.json")
        self.board = dict({"tasks": [], "events": []}, **config.read_json(self._board_file, {}))

    def _save(self):
        try:
            with open(self._file + ".tmp", "w", encoding="utf-8") as handle:
                json.dump(self.settings, handle, ensure_ascii=False)
            os.replace(self._file + ".tmp", self._file)
        except OSError as exc:
            log.write("总管模式：设置保存失败：%s" % exc)

    # MARK: 调度记录

    @staticmethod
    def _now():
        return int(time.time() * 1000)

    def _note(self, change):
        with self._lock:
            change(self.board)
            cutoff = self._now() - 12 * 3600 * 1000
            self.board["tasks"] = [t for t in self.board["tasks"] if t["at"] > cutoff][-60:]
            self.board["events"] = [e for e in self.board["events"] if e["at"] > cutoff][-80:]
            try:
                with open(self._board_file + ".tmp", "w", encoding="utf-8") as handle:
                    json.dump(self.board, handle, ensure_ascii=False)
                os.replace(self._board_file + ".tmp", self._board_file)
            except OSError:
                pass
        self._publish()

    def _event(self, kind, text, keys=None):
        row = {"id": os.urandom(4).hex(), "kind": kind, "text": text[:300], "at": self._now()}
        if keys:
            row["keys"] = keys
        return row

    def _task(self, key, op, title, device, device_id, cwd, text):
        return {"id": os.urandom(4).hex(), "key": key, "op": op, "title": title, "device": device, "deviceId": device_id, "cwd": cwd,
                "text": text[:500], "state": "sent", "at": self._now()}

    def _set_task(self, tid, **fields):
        def change(board):
            for task in board["tasks"]:
                if task["id"] == tid:
                    task.update(fields)
        return change

    def _claim_new(self):
        """新开的会话开出来了：同一台电脑、同一个目录、派活之后才开始的那个就是它（已经认给别的任务的不算）"""
        now = self._now()
        with self._lock:
            pending = [t for t in self.board["tasks"] if not t["key"] and t["state"] != "failed" and now - t["at"] < 10 * 60 * 1000]
            taken = {t["key"] for t in self.board["tasks"]}
        if not pending:
            return
        with self.app.store.lock:
            records = list(self.app.store.records)
        found = {}
        for task in pending:
            hits = [r for r in records if r.source_id == task["deviceId"] and same_dir(r.snap.get("cwd"), task["cwd"]) and r.key not in taken
                    and (r.snap.get("startedAt") or 0) >= task["at"] - 5000 and r.key not in found.values()]
            if hits:
                found[task["id"]] = min(hits, key=lambda r: r.snap.get("startedAt") or 0).key
        if not found:
            return

        def change(board):
            for task in board["tasks"]:
                if task["id"] in found:
                    task["key"] = found[task["id"]]
                    record = self.app.store.record(task["key"])
                    if record:
                        task["title"] = display_title(record.snap)
        self._note(change)

    # MARK: 总管会话

    @property
    def key(self):
        """总管会话的 key（在跑的才有）：记着的会话 id 还在就是它；不在了，找总管那台电脑上工作目录是 ~/.ccpulse/steward 的、最新开的那个"""
        s = self.settings
        if not s["enabled"]:
            return None
        with self.app.store.lock:
            records = [r for r in self.app.store.records if r.source_id == s["sourceId"]]
        if s.get("sessionId"):
            hit = next((r for r in records if r.snap.get("sessionId") == s["sessionId"]), None)
            if hit:
                return hit.key
        if not s.get("cwd"):
            return None
        mine = [r for r in records if same_dir(r.snap.get("cwd"), s["cwd"])]
        return max(mine, key=lambda r: r.snap.get("startedAt") or 0).key if mine else None

    def _record(self):
        key = self.key
        return self.app.store.record(key) if key else None

    def is_steward(self, key):
        return self.settings["enabled"] and key == self.key

    # MARK: 接口

    def handle(self, method, path, body):
        """GET /api/steward：设置和总管会话；POST /api/steward：开启（带配置）/ 关闭；POST /api/steward/wake：总管会话不在了，重开一个"""
        body = body or {}
        if method == "GET" and path == "/api/steward":
            return 200, self.status()
        if method == "POST" and path == "/api/steward":
            if body.get("enabled") is not True:
                self.disable()
                return 200, self.status()
            # 测试实例（dry-run 开不出真的总管会话）：testSessionId 指定一个现成的会话当总管
            if (os.environ.get("KITELINE_CONFIG_DIR") or delivery.DRY_RUN) and body.get("testSessionId"):
                self.settings["sessionId"] = str(body["testSessionId"])
            return self.enable(str(body.get("sourceId") or ""), str(body.get("agent") or "claude-code"),
                               "close" if body.get("existing") == "close" else "keep", body.get("speak") is not False)
        if method == "POST" and path == "/api/steward/wake":
            if not self.settings["enabled"]:
                return 409, {"ok": False, "error": "总管模式未开启"}
            if self._record():
                return 200, self.status()
            ok, message = self._launch()
            return (200 if ok else 409), dict(self.status(), ok=ok, message=message)
        return 404, {"ok": False, "error": "接口不存在"}

    def status(self):
        s = self.settings
        source = self.app.store.source(s["sourceId"]) if s["sourceId"] else None
        out = {"ok": True, "enabled": s["enabled"], "sourceId": s["sourceId"], "agent": s["agent"], "existing": s["existing"],
               "speak": s["speak"], "starting": self.starting, "sourceName": source.name if source else ""}
        record = self._record()
        if record:
            out["key"] = record.key
            out["activity"] = record.activity
        with self._lock:
            out["tasks"] = [dict(t) for t in self.board["tasks"]]
            out["events"] = [dict(e) for e in self.board["events"][-30:]]
        return out

    def _publish(self):
        self.app.server.publish("steward", self.status())

    # MARK: 开启、关闭

    def enable(self, source_id, agent, existing, speak):
        source = self.app.store.source(source_id)
        if not source or not source.live:
            return 404, {"ok": False, "error": "该机器当前离线"}
        if self.starting:
            return 409, {"ok": False, "error": "总管正在启动，请稍候"}
        try:
            reply = source.request({"cmd": "steward", "op": "setup"}, timeout=20)   # 说明书在 watcher 里（STEWARD_BRIEF）
        except Exception as exc:  # noqa: BLE001
            reason = "这台电脑上的 Kiteline 版本较旧，请先更新" if "未知请求" in str(exc) else str(exc)
            return 409, {"ok": False, "error": "无法在 %s 上准备总管：%s" % (source.name, reason)}
        cwd = reply.get("cwd")
        if not cwd:
            return 409, {"ok": False, "error": "无法在 %s 上准备总管" % source.name}
        s = self.settings
        moved = bool(s["sourceId"]) and (s["sourceId"] != source_id or s["agent"] != agent)
        s.update({"enabled": True, "sourceId": source_id, "agent": agent or "claude-code", "existing": existing, "speak": speak,
                  "cwd": cwd, "enabledAt": int(time.time() * 1000)})
        if moved:
            s["sessionId"] = None
        self._save()
        log.write("总管模式：开启（%s，%s，现有会话%s）" % (source.name, s["agent"], "全部关闭" if existing == "close" else "保留"))
        if existing == "close":
            threading.Thread(target=self._close_others, name="steward-close", daemon=True).start()
        self._pushed = None
        self._push()
        if self._record():
            self._publish()
            return 200, dict(self.status(), message="总管模式已开启")
        ok, message = self._launch()
        return (200 if ok else 409), dict(self.status(), ok=ok,
                                          message="总管模式已开启，总管正在 %s 上启动" % source.name if ok else message)

    def disable(self):
        if not self.settings["enabled"]:
            return
        self.settings["enabled"] = False
        self._save()
        log.write("总管模式：关闭（总管会话保留）")
        self._pushed = None
        self._push()
        self._publish()

    def _close_others(self):
        """开启时选了「关闭现有会话」：除了总管自己，运行中的会话一个一个关"""
        mine = self.key
        with self.app.store.lock:
            targets = [r for r in self.app.store.records if r.key != mine and r.kind != "kiteline"]
        for record in targets:
            try:
                delivery.close(record, self.app.store.source(record.source_id), self.app.server.siblings(record))
            except Exception as exc:  # noqa: BLE001
                log.write("总管模式：关闭会话「%s」失败：%s" % (record.snap.get("name"), exc))

    def _start(self, source_id, cwd, prompt, agent):
        """借新任务那条路开会话（Claude Code 照新任务的规矩，别家 agent 后台运行）→ (成功?, 说明)"""
        body = {"sourceId": source_id, "cwd": cwd, "text": prompt, "submit": True}
        if agent and agent != "claude-code":
            body["agent"] = agent
        response = self.app.new_session(types.SimpleNamespace(json=body, query={}, headers={}))
        try:
            payload = json.loads(response.body.decode("utf-8") or "{}")
        except ValueError:
            payload = {}
        ok = response.status < 400 and payload.get("ok", True) is not False
        return ok, payload.get("message") or payload.get("error") or ("已开始" if ok else "启动失败")

    def _launch(self):
        s = self.settings
        if not s.get("cwd"):
            return False, "总管所在的电脑不存在"
        self.starting = True
        self._publish()
        try:
            ok, message = self._start(s["sourceId"], s["cwd"],
                                      "总管模式已开启。请先运行 steward state 了解现在有哪些设备、项目和会话，然后用一两句话向用户问好，说明你能帮他做什么。",
                                      s["agent"])
        finally:
            self.starting = False
        log.write("总管模式：启动总管会话%s：%s" % ("成功" if ok else "失败", message))
        self._publish()
        return ok, message

    # MARK: 推目录

    def sessions_changed(self):
        """会话列表变了：认总管会话（开出来了就记下 id），过 3 秒把目录推给总管那台电脑（连着变只推一次）"""
        if not self.settings["enabled"]:
            return
        self._claim_new()
        key = self.key
        if key:
            sid = key.split("#", 1)[-1]
            if self.settings.get("sessionId") != sid:
                self.settings["sessionId"] = sid
                self._save()
                self._publish()
        self._schedule_push()

    def source_connected(self, source):
        if source.id == self.settings["sourceId"] and (self.settings["enabled"] or self._pushed is not None):
            self._pushed = None
            self._schedule_push()

    def _schedule_push(self):
        with self._lock:
            if self._push_timer:
                return
            self._push_timer = threading.Timer(3, self._timer_push)
            self._push_timer.daemon = True
            self._push_timer.start()

    def _timer_push(self):
        with self._lock:
            self._push_timer = None
        self._push()

    def _push(self):
        source = self.app.store.source(self.settings["sourceId"]) if self.settings["sourceId"] else None
        if not source or not source.live:
            return

        def run():
            try:
                directory = self._directory()
                data = json.dumps(directory, sort_keys=True, ensure_ascii=False)
                if data == self._pushed:
                    return
                self._pushed = data
                source.request({"cmd": "steward", "directory": directory}, timeout=20)
            except Exception as exc:  # noqa: BLE001  老版本 watcher 不认
                log.write("总管模式：推目录失败：%s" % exc)
        threading.Thread(target=run, name="steward-push", daemon=True).start()

    def _directory(self):
        store = self.app.store
        key = self.key
        if not self.settings["enabled"] or not key:
            return {"steward": {}}
        devices = [{"id": s.id, "name": s.name, "kind": s.kind, "online": bool(s.live)}
                   for s in list(store.sources.values()) if s.kind != "kiteline"]
        sessions = []
        with store.lock:
            records = list(store.records)
        for r in records:
            if r.key == key:
                continue
            snap = r.snap
            cwd = snap.get("cwd") or ""
            row = {"key": r.key, "sessionId": snap.get("sessionId"), "title": display_title(snap), "device": r.source_name,
                   "deviceId": r.source_id, "project": os.path.basename(cwd.rstrip("/\\")), "cwd": cwd,
                   "agent": snap.get("agent") or "claude-code", "activity": r.activity}
            stage = snap.get("stage") if isinstance(snap.get("stage"), dict) else None
            if stage and stage.get("total"):
                row["stage"] = "%s/%s %s" % (stage.get("step"), stage.get("total"), stage.get("label") or "")
            if snap.get("message"):
                row["last"] = str(snap["message"])[:300]
            if snap.get("updatedAt"):
                row["updatedAt"] = snap["updatedAt"]
            sessions.append(row)
        try:
            listing = aggregate.projects(store).get("projects") or []
        except Exception:  # noqa: BLE001
            listing = []
        projects = [{"name": p.get("name") or "", "path": p.get("cwd") or "", "deviceId": p.get("sourceId") or "",
                     "device": p.get("sourceName") or "", "live": p.get("live") or 0}
                    for p in sorted(listing, key=lambda p: p.get("lastActive") or 0, reverse=True)
                    if p.get("cwd") != self.settings.get("cwd") and p.get("kind") != "kiteline"][:80]
        return {"steward": {"key": key, "sessionId": key.split("#", 1)[-1], "deviceId": self.settings["sourceId"]},
                "devices": devices, "sessions": sessions, "projects": projects}

    # MARK: 总管 / 被派活的会话发来的

    def agent_op(self, key, item):
        threading.Thread(target=self._perform, args=(key, item), name="steward-op", daemon=True).start()

    def _perform(self, key, item):
        marker = "%s|%s" % (key, item.get("id") or time.time())
        with self._lock:
            if marker in self._handled:
                return
            self._handled.append(marker)
            del self._handled[:-300]
        if not self.settings["enabled"]:
            log.write("总管模式：总管模式已关闭，忽略 %s 的 %s" % (key, item.get("op")))
            return
        op = item.get("op") or ""
        text = str(item.get("text") or "").strip()
        if not text:
            return
        if op == "report":
            self._report(key, text, item.get("images") or [])
            return
        if not self.is_steward(key):
            log.write("总管模式：%s 不是总管，忽略它的 %s" % (key, op))
            return
        if op == "assign":
            for target in item.get("to") or []:
                self._assign(text, str(target))
        elif op == "group":
            members = [key] + [str(k) for k in item.get("to") or [] if k != key]
            self.app.groups.steward_group(members, text, key)
            names = [display_title(r.snap) for r in (self.app.store.record(k) for k in members[1:]) if r]
            self._note(lambda b: b["events"].append(self._event("group", "拉群：%s。%s" % (" × ".join(names), text), members[1:])))
        elif op == "new":
            self._new(str(item.get("device") or ""), str(item.get("cwd") or ""), item.get("agent"), text)
        else:
            log.write("总管模式：不认识的操作 %s" % op)

    def _footer(self, source_id):
        command = self.app.groups.commands.get(source_id) or "python3 ~/.ccpulse/ccpulse-watch.py"
        return "做完、卡住或需要用户决定时，运行 %s steward report \"结果或问题\" 向总管汇报（截图加 --image 路径）；总管会转告用户。" % command

    def _assign(self, text, target):
        record = self.app.store.record(target)
        if not record:
            self._tell("【Kiteline】派活失败：会话已关闭（%s）。可以用 steward new 在它的项目里新开一个。" % target)
            return
        prompt = "【Kiteline 总管派来的任务】\n%s\n\n%s" % (text, self._footer(record.source_id))
        if delivery.DRY_RUN:
            log.write("[dry-run] 总管派活 → %s：%s" % (display_title(record.snap), prompt))
        title = display_title(record.snap)
        task = self._task(record.key, "assign", title, record.source_name, record.source_id, record.snap.get("cwd") or "", text)

        def add(board):
            board["tasks"].append(task)
            board["events"].append(self._event("assign", "派给「%s」：%s" % (title, text), [record.key]))
        self._note(add)
        self._deliver(prompt, task["id"], record.key, time.time())

    QUEUE_LIMIT = 15 * 60

    def _deliver(self, prompt, tid, key, since):
        """把任务投进那个会话。它在等你确认（回车会替你点了确认框）：标成排队中，5 秒后再看；等太久算没送到（同 Mac 版 Steward.deliver）"""
        record = self.app.store.record(key)
        if not record:
            self._note(self._set_task(tid, state="failed", note="会话已关闭"))
            return
        title = display_title(record.snap)
        if not delivery.via_bridge(record) and delivery.waiting_problem(record):
            if time.time() - since > self.QUEUE_LIMIT:
                self._fail(tid, key, title, "会话一直在等你确认，未能派出")
                return
            with self._lock:
                queued = any(t["id"] == tid and t["state"] == "queued" for t in self.board["tasks"])
            if not queued:
                self._note(self._set_task(tid, state="queued"))
            timer = threading.Timer(5, self._deliver, args=(prompt, tid, key, since))
            timer.daemon = True
            timer.start()
            return
        with self._lock:
            queued = any(t["id"] == tid and t["state"] == "queued" for t in self.board["tasks"])
        if queued:
            self._note(self._set_task(tid, state="sent"))
        outcome = delivery.send(prompt, [], record, self.app.store.source(record.source_id), True, self.app.server.siblings(record))
        if not outcome.ok:
            self._fail(tid, key, title, outcome["message"])

    def _fail(self, tid, key, title, message):
        self._note(self._set_task(tid, state="failed", note=message))
        self._note(lambda b: b["events"].append(self._event("failed", "没送到「%s」：%s" % (title, message), [key])))
        self._tell("【Kiteline】派给「%s」的任务没有送到：%s" % (title, message))

    def _new(self, source_id, cwd, agent, text):
        source = self.app.store.source(source_id)
        if not source or not source.live:
            self._tell("【Kiteline】新开会话失败：设备 %s 离线或不存在" % source_id)
            return
        log.write("总管模式：在 %s:%s 新开会话（%s）" % (source.name, cwd, agent or "Claude Code"))
        project = os.path.basename(cwd.rstrip("/\\"))
        task = self._task("", "new", project, source.name, source_id, cwd, text)

        def add(board):
            board["tasks"].append(task)
            board["events"].append(self._event("new", "在 %s 新开会话（%s）：%s" % (source.name, project, text)))
        self._note(add)
        ok, message = self._start(source_id, cwd, "【Kiteline 总管派来的任务】\n%s\n\n%s" % (text, self._footer(source_id)), agent)
        if not ok:
            self._note(self._set_task(task["id"], state="failed", note=message))
            self._note(lambda b: b["events"].append(self._event("failed", "新开会话失败（%s）：%s" % (project, message))))
        self._tell(("【Kiteline】已在 %s 的 %s 新开会话：%s" if ok else "【Kiteline】在 %s 的 %s 新开会话失败：%s") % (source.name, cwd, message))

    def _report(self, key, text, images):
        sender = self.app.store.record(key)
        if not sender:
            return
        snap = sender.snap
        cwd = snap.get("cwd") or ""
        head = "【汇报 · 「%s」（%s · %s）】" % (display_title(snap), sender.source_name, os.path.basename(cwd.rstrip("/\\")))
        title = display_title(snap)

        def mark(board):
            mine = [t for t in board["tasks"] if t["key"] == key]
            if mine:
                mine[-1].update({"state": "reported", "reportAt": self._now(), "report": text[:300], "title": title})
                if images:
                    mine[-1]["images"] = min(len(images), 6)
            board["events"].append(self._event("report", "「%s」回报：%s" % (title, text), [key]))
        self._note(mark)
        attachments = []
        source = self.app.store.source(sender.source_id)
        for path in images[:6]:
            try:
                reply = source.request({"cmd": "get_file", "path": path, "cwd": cwd}, timeout=60)
                if reply.get("data"):
                    attachments.append({"name": reply.get("name") or "image.png", "data": reply["data"], "file": False})
            except Exception as exc:  # noqa: BLE001
                log.write("总管模式：取汇报截图失败：%s" % exc)
        self._tell(head + "\n" + text, attachments)

    def _tell(self, text, attachments=None):
        """给总管的会话发一条（派活结果、汇报）：总管忙时后台送达会排到这一轮结束后"""
        record = self._record()
        if not record:
            log.write("总管模式：总管会话不在，没送到：%s" % text[:80])
            return
        if delivery.DRY_RUN:
            log.write("[dry-run] 告诉总管：%s%s" % (text, "（附 %d 张图）" % len(attachments) if attachments else ""))
        try:
            source = self.app.store.source(record.source_id)
            paths = delivery.stage(attachments, source) if attachments else []
            prompt = delivery.compose(text, paths, attachments or [])
            outcome = delivery.send(prompt, [], record, source, True, self.app.server.siblings(record))
            if not outcome.ok:
                log.write("总管模式：告诉总管失败：%s" % outcome["message"])
        except Exception as exc:  # noqa: BLE001
            log.write("总管模式：告诉总管出错：%r" % exc)
