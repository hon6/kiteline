"""定时任务（对应 Mac 版 Schedules.swift）：到点在项目的 VS Code 窗口里新开一个会话，把要求发给 Claude。
重复方式：once 一次 / daily 每天 / weekdays 工作日；错过 1 小时以内的补跑，更久的记为错过。"""

import json
import os
import threading
import uuid
from datetime import datetime, timedelta

from . import config, log

MODES = {"once": "一次", "daily": "每天", "weekdays": "工作日"}
GRACE = timedelta(hours=1)


class Schedules:
    def __init__(self, app):
        self.app = app
        self._lock = threading.RLock()
        self._file = config.path("schedules.json")
        data = config.read_json(self._file, [])
        self.tasks = data if isinstance(data, list) else []
        self._in_flight = set()

    def _save(self):
        with self._lock:
            text = json.dumps(self.tasks, ensure_ascii=False, indent=2, sort_keys=True)
        config.write_private(self._file, text)

    @staticmethod
    def _at(day, hm):
        return datetime(day.year, day.month, day.day, hm[0], hm[1])

    def _once(self, task):
        try:
            y, m, d = [int(x) for x in (task.get("date") or "").split("-")]
            hm = config.parse_hm(task["time"])
            return datetime(y, m, d, hm[0], hm[1]) if hm else None
        except (ValueError, TypeError):
            return None

    def next_run(self, task, now=None):
        now = now or datetime.now()
        hm = config.parse_hm(task["time"])
        if not hm or not task.get("enabled", True):
            return None
        if task["repeat"] == "once":
            when = self._once(task)
            return when if when and not task.get("lastRun") else None
        day = now
        for _ in range(8):
            when = self._at(day, hm)
            if when > now and (task["repeat"] == "daily" or when.weekday() < 5):
                return when
            day += timedelta(days=1)
        return None

    def _due(self, task, now):
        """应该跑而还没跑的那一次（最近一次到点时间）"""
        hm = config.parse_hm(task["time"])
        if not hm:
            return None
        last = datetime.fromtimestamp(task["lastRun"] / 1000) if task.get("lastRun") else datetime.fromtimestamp(task["createdAt"] / 1000)
        if task["repeat"] == "once":
            when = self._once(task)
            return when if when and when <= now and not task.get("lastRun") else None
        when = self._at(now, hm)
        if when > now:
            when -= timedelta(days=1)
        while task["repeat"] == "weekdays" and when.weekday() >= 5:
            when -= timedelta(days=1)
        return when if when > last else None

    def label(self, task):
        if task["repeat"] == "daily":
            return "每天 %s" % task["time"]
        if task["repeat"] == "weekdays":
            return "工作日 %s" % task["time"]
        parts = (task.get("date") or "").split("-")
        day = "%d月%d日" % (int(parts[1]), int(parts[2])) if len(parts) == 3 else task.get("date", "")
        return "%s %s 一次" % (day, task["time"])

    def payload(self, task):
        source = self.app.store.source(task["sourceId"])
        item = {"id": task["id"], "sourceId": task["sourceId"], "sourceName": source.name if source else task["sourceId"],
                "cwd": task["cwd"], "name": os.path.basename(task["cwd"].rstrip("/\\")), "prompt": task["prompt"],
                "repeat": task["repeat"], "time": task["time"], "enabled": task.get("enabled", True),
                "createdAt": task["createdAt"], "label": self.label(task)}
        for key in ("date", "lastRun", "lastOk", "lastResult"):
            if task.get(key) is not None:
                item[key] = task[key]
        nxt = self.next_run(task)
        if nxt:
            item["nextRun"] = int(nxt.timestamp() * 1000)
        return item

    def payloads(self):
        with self._lock:
            return [self.payload(t) for t in self.tasks]

    def add(self, source_id, cwd, prompt, repeat, time_text, date):
        if repeat not in MODES:
            return False, "重复方式无效"
        if not config.parse_hm(time_text):
            return False, "时间格式应为 HH:mm"
        text = (prompt or "").strip()
        if not text:
            return False, "请先填写任务内容"
        if not cwd or "\n" in cwd:
            return False, "项目路径无效"
        if not self.app.store.source(source_id):
            return False, "机器不存在"
        task = {"id": uuid.uuid4().hex[:8], "sourceId": source_id, "cwd": cwd, "prompt": text[:4000], "repeat": repeat,
                "time": time_text, "enabled": True, "createdAt": datetime.now().timestamp() * 1000}
        if repeat == "once":
            task["date"] = date
            when = self._once(task)
            if not date or not when:
                return False, "一次性任务需选择日期"
            if when <= datetime.now():
                return False, "该时间已过"
        with self._lock:
            self.tasks.append(task)
        self._save()
        return True, self.payload(task)

    def update(self, task_id, enabled):
        with self._lock:
            task = next((t for t in self.tasks if t["id"] == task_id), None)
            if not task:
                return None
            task["enabled"] = bool(enabled)
            if enabled and task["repeat"] != "once":
                task["lastRun"] = max(task.get("lastRun") or 0, datetime.now().timestamp() * 1000)
        self._save()
        return self.payload(task)

    def remove(self, task_id):
        with self._lock:
            task = next((t for t in self.tasks if t["id"] == task_id), None)
            if not task:
                return None
            self.tasks.remove(task)
        self._save()
        return self.label(task)

    def tick(self, now):
        with self._lock:
            tasks = [dict(t) for t in self.tasks if t.get("enabled", True)]
        for task in tasks:
            due = self._due(task, now)
            if not due:
                continue
            if now - due > GRACE:
                self._finish(task["id"], due, False, "已错过：到达设定时间时电脑未开机或处于睡眠状态")
            else:
                self.run(task["id"], due)

    def run(self, task_id, due=None):
        with self._lock:
            task = next((dict(t) for t in self.tasks if t["id"] == task_id), None)
        if not task:
            return False, "任务不存在"
        if task_id in self._in_flight:
            return False, "该任务正在启动，请稍候"
        ran = due or datetime.now()
        source = self.app.store.source(task["sourceId"])
        if not source or not source.live:
            self._finish(task_id, ran, False, "目标机器当时离线")
            return False, "目标机器当前离线"
        capped = self.app.spend_capped()
        if capped:
            self._finish(task_id, ran, False, "跳过：%s" % capped)
            return False, capped
        self._in_flight.add(task_id)
        try:
            from .app import launch_session
            try:
                check = source.request({"cmd": "is_dir", "path": task["cwd"]}, timeout=15)
                exists = bool(check.get("isDir"))
            except Exception:  # noqa: BLE001
                exists = False
            if not exists:
                self._finish(task_id, ran, False, "项目目录已不存在")
                return False, "项目目录已不存在"
            self.app.audit.note("定时任务", "%s：%s" % (self.label(task), task["prompt"][:60]))
            result = launch_session(task["cwd"], task["prompt"], True, None, source.kind, source.name)
            self._finish(task_id, ran, result["ok"], result["message"])
            name = os.path.basename(task["cwd"].rstrip("/\\"))
            title = ("定时任务已开始 · %s" if result["ok"] else "定时任务启动失败 · %s") % name
            self.app.server.notify("schedule", title, task["prompt"][:200], None, route="")
            return result["ok"], result["message"]
        finally:
            self._in_flight.discard(task_id)

    def _finish(self, task_id, at, ok, message):
        with self._lock:
            for task in self.tasks:
                if task["id"] == task_id:
                    task["lastRun"] = at.timestamp() * 1000
                    task["lastOk"] = ok
                    task["lastResult"] = message
                    if task["repeat"] == "once":
                        task["enabled"] = False
        self._save()
        log.write("定时任务 %s：%s" % (task_id, message))
