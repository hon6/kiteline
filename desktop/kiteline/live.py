"""iPhone 实时活动（锁屏 + 灵动岛，对应 Mac 版 LiveActivities.swift）：什么时候开、显示什么、什么时候结束都由电脑定，
经 Kiteline 推送网关（/push/live）发给每台登记过的 iPhone，App 没开也照样更新。App 那边只报令牌、管开关。

一「轮」= 从有会话开始干活（或等你确认）到全部停下：
- 开始干活：给开着实时活动、有「推送启动令牌」的 iPhone 开一个（每轮每台一次）
- 期间：内容变了就更新（平时最多 8 秒一次、低优先级；多了要你确认的立刻发、高优先级）
- 全部停下满 90 秒（跑目标检查时会短暂空闲，别一停就收）：发「全部完成」并结束，锁屏上再留 10 分钟
- 用户在锁屏上划掉了：这一轮不再开，下一轮照常

苹果规定实时活动的推送内容 App 解不了密，所以是明文：只放会话标题、状态和一句细节（在等什么、做到哪一步），不放对话内容
"""

import json
import os
import re
import threading
import time
import urllib.error
import urllib.request

from . import config, i18n, log
from .push import GATEWAY

LIVE_GATEWAY = GATEWAY.rstrip("/") + "/live"
_TOKEN = re.compile(r"^[0-9a-fA-F]{64,200}$")


def _path():
    return os.path.join(config.config_dir(), "live-activities.json")


def _clip(text, limit):
    flat = (text or "").replace("\n", " ")
    return flat[: limit - 1] + "…" if len(flat) > limit else flat


def _mark(state):
    """比较内容变没变：去掉时间"""
    return json.dumps({k: v for k, v in state.items() if k != "at"}, ensure_ascii=False, sort_keys=True)


class LiveActivities:
    def __init__(self, host_name):
        self.host_name = host_name
        self._lock = threading.RLock()
        self._devices = {}            # 设备 id → {enabled, env, lang, startToken, activities{id: token}, startedRound, dismissedRound}
        self._last_sent = {}          # 设备 id → (内容, 待确认个数)
        self._last_activity = {}
        self._finished = {}           # 会话 key → (标题, 出错原因, 时间)
        self._sessions = []
        self._round = 0
        self._active = False
        self._waiting = 0            # 上次看到几个在等你确认：多了要马上发
        self._idle_since = None
        self._last_flush = 0.0
        self._pending = None
        self._end_timer = None
        try:
            with open(_path(), encoding="utf-8") as f:
                saved = json.load(f)
            if isinstance(saved, dict):
                self._devices = {k: v for k, v in saved.items() if isinstance(v, dict)}
        except (OSError, ValueError):
            pass

    # MARK: iPhone 登记（POST /api/live/register）

    def register(self, device_id, body):
        if not device_id:
            return
        with self._lock:
            device = self._devices.get(device_id) or {"activities": {}, "startedRound": 0, "dismissedRound": 0}
            device["enabled"] = bool(body.get("enabled"))
            if body.get("env") in ("production", "development"):
                device["env"] = body["env"]
            device["lang"] = "en" if body.get("lang") == "en" else "zh"
            ended = body.get("ended")
            if ended and ended in device.get("activities", {}) and self._active:
                device["dismissedRound"] = self._round   # 这一轮还没结束就没了：用户划掉的，这一轮别再开
            if device["enabled"]:
                token = body.get("startToken")
                if isinstance(token, str) and _TOKEN.match(token):
                    device["startToken"] = token
                reported = {}
                for item in body.get("activities") or []:
                    if isinstance(item, dict) and isinstance(item.get("token"), str) and _TOKEN.match(item["token"]) and item.get("id"):
                        reported[str(item["id"])] = item["token"]
                if any(k not in device.get("activities", {}) for k in reported):
                    self._last_sent.pop(device_id, None)   # 刚开出来的报了令牌：马上补一份最新的
                device["activities"] = reported
            else:
                device["startToken"] = None
                device["activities"] = {}
            self._devices[device_id] = device
            self._save()
            if self._active:
                self._schedule(urgent=True)

    def forget(self, device_id):
        with self._lock:
            self._devices.pop(device_id, None)
            self._last_sent.pop(device_id, None)
            self._save()

    # MARK: 会话状态变了（MobileServer.publish_state）

    def update(self, sessions):
        with self._lock:
            if not self._devices:
                return
            now = time.time()
            for session in sessions:
                key = session.get("key")
                if not key:
                    continue
                activity = session.get("activity") or ""
                before = self._last_activity.get(key)
                if activity in ("busy", "waiting"):
                    self._finished.pop(key, None)
                elif before in ("busy", "waiting"):
                    self._finished[key] = (self._title(session), session.get("error"), now)
                self._last_activity[key] = activity
            self._finished = {k: v for k, v in self._finished.items() if now - v[2] < 15 * 60}
            self._sessions = list(sessions)
            working = any(s.get("activity") in ("busy", "waiting") for s in sessions)
            waiting = sum(1 for s in sessions if s.get("activity") == "waiting")
            # 新一轮开始、多了要你确认的：马上发（不等 8 秒）
            urgent = waiting > self._waiting
            self._waiting = waiting
            if working:
                if not self._active:
                    self._active = True
                    self._round += 1
                    urgent = True
                self._idle_since = None
                if self._end_timer:
                    self._end_timer.cancel()
                    self._end_timer = None
                self._schedule(urgent=urgent)
            elif self._active and self._idle_since is None:
                self._idle_since = now
                self._end_timer = threading.Timer(90, self._end_if_idle)
                self._end_timer.daemon = True
                self._end_timer.start()
                self._schedule(urgent=False)

    def _end_if_idle(self):
        with self._lock:
            if not self._active or self._idle_since is None or time.time() - self._idle_since < 89:
                return
            self._active = False
            if self._pending:
                self._pending.cancel()
                self._pending = None
            dismiss = int(time.time()) + 10 * 60
            for device_id, device in self._devices.items():
                if not device.get("enabled") or not device.get("activities"):
                    continue
                state = self.content(device.get("lang", "zh"))
                for token in device["activities"].values():
                    self._send(device_id, token, device.get("env", "production"),
                               {"event": "end", "state": state, "dismiss": dismiss, "urgency": "normal"})
                device["activities"] = {}
            self._last_sent = {}
            self._finished = {}
            self._save()

    def _schedule(self, urgent):
        """平时最多 8 秒发一次；急的（多了要你确认的、刚登记的）马上发"""
        wait = 0 if urgent else max(0.0, 8 - (time.time() - self._last_flush))
        if wait == 0:
            if self._pending:
                self._pending.cancel()
                self._pending = None
            self._flush()
            return
        if self._pending:
            return
        self._pending = threading.Timer(wait, self._timer_flush)
        self._pending.daemon = True
        self._pending.start()

    def _timer_flush(self):
        with self._lock:
            self._pending = None
            self._flush()

    def _flush(self):
        if not self._active:
            return
        self._last_flush = time.time()
        stale = int(time.time()) + 20 * 60
        changed = False
        for device_id, device in self._devices.items():
            if not device.get("enabled"):
                continue
            env = device.get("env", "production")
            state = self.content(device.get("lang", "zh"))
            waiting = state["waiting"]
            mark = _mark(state)
            last = self._last_sent.get(device_id)
            if device.get("activities"):
                if last and last[0] == mark:
                    continue
                urgent = waiting > (last[1] if last else 0)
                self._last_sent[device_id] = (mark, waiting)
                for token in device["activities"].values():
                    self._send(device_id, token, env, {"event": "update", "state": state, "stale": stale, "urgency": "high" if urgent else "normal"})
            elif device.get("startToken") and device.get("startedRound") != self._round and device.get("dismissedRound") != self._round \
                    and state["busy"] + waiting > 0:
                device["startedRound"] = self._round
                self._last_sent[device_id] = (mark, waiting)
                top = state["items"][0] if state["items"] else {}
                self._send(device_id, device["startToken"], env, {
                    "event": "start", "state": state, "attributes": {"host": self.host_name},
                    "alert": {"title": top.get("t") or "Kiteline", "body": top.get("l") or ""}, "stale": stale, "urgency": "high"})
                changed = True
        if changed:
            self._save()

    # MARK: 显示什么

    def content(self, lang):
        """给一台 iPhone 的内容（按它的语言）：顶上一句 + 最多 3 个会话（等你确认的在前，其次在干活的，再是刚做完 / 出错的）"""
        english = lang == "en"

        def text(chinese):
            return i18n.translate(chinese) if english else chinese

        def updated(session):
            try:
                return float(session.get("updatedAt") or 0)
            except (TypeError, ValueError):
                return 0.0

        waiting = sorted((s for s in self._sessions if s.get("activity") == "waiting"), key=updated, reverse=True)
        busy = sorted((s for s in self._sessions if s.get("activity") == "busy"), key=updated, reverse=True)
        items = []
        for session in waiting:
            detail = session.get("blocking") or session.get("pendingTool")
            items.append(self._item(session, "waiting", "Needs approval" if english else "待确认", text(detail) if detail else None))
        for session in busy:
            detail = text(session["activityText"]) if session.get("activityText") else None
            stage = session.get("stage") or {}
            if isinstance(stage, dict) and stage.get("total") and stage.get("label"):
                detail = "%s/%s %s" % (stage.get("step"), stage.get("total"), text(stage["label"]))
            items.append(self._item(session, "busy", "Running" if english else "进行中", detail))
        for key, (title, error, _) in sorted(self._finished.items(), key=lambda kv: kv[1][2], reverse=True):
            item = {"k": key, "t": _clip(title, 40), "s": "error" if error else "done",
                    "l": ("Stopped on error" if english else "出错已停止") if error else ("Done" if english else "已完成")}
            if error:
                item["d"] = _clip(text(error), 60)
            items.append(item)
        head = []
        if waiting:
            head.append("%d waiting" % len(waiting) if english else "%d 个待确认" % len(waiting))
        if busy:
            head.append("%d running" % len(busy) if english else "%d 个进行中" % len(busy))
        return {"head": " · ".join(head) if head else ("All done" if english else "全部完成"),
                "waiting": len(waiting), "busy": len(busy), "items": items[:3], "at": time.time()}

    def _item(self, session, status, label, detail):
        out = {"k": session.get("key") or "", "t": _clip(self._title(session), 40), "s": status, "l": label}
        if detail:
            out["d"] = _clip(detail, 60)
        return out

    @staticmethod
    def _title(session):
        title = (session.get("title") or "").strip()
        return title or session.get("name") or ""

    # MARK: 发给网关

    def _send(self, device_id, token, env, body):
        payload = dict(body, token=token, env=env)
        threading.Thread(target=self._post, args=(device_id, token, payload), daemon=True).start()

    def _post(self, device_id, token, payload):
        request = urllib.request.Request(LIVE_GATEWAY, data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                                         headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=20):
                return
        except urllib.error.HTTPError as exc:
            status = exc.code
        except (OSError, ValueError) as exc:
            log.write("实时活动 %s 没发出去：%s" % (payload.get("event"), exc))
            return
        log.write("实时活动 %s 没发出去：网关返回 %s" % (payload.get("event"), status))
        if status != 410:
            return
        # 令牌失效（App 删了、实时活动没了）：删掉，别再发
        with self._lock:
            device = self._devices.get(device_id)
            if not device:
                return
            if device.get("startToken") == token:
                device["startToken"] = None
            device["activities"] = {k: v for k, v in (device.get("activities") or {}).items() if v != token}
            self._save()

    def _save(self):
        try:
            os.makedirs(config.config_dir(), exist_ok=True)
            tmp = _path() + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(self._devices, f, ensure_ascii=False)
            try:
                os.chmod(tmp, 0o600)
            except OSError:
                pass
            os.replace(tmp, _path())
        except OSError as exc:
            log.write("实时活动登记没存上：%s" % exc)
