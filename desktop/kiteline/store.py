"""会话中枢（对应 Mac 版 SessionStore.swift + AppState.mobileStatePayload）：
合并各来源的会话快照，判定该不该提醒，拼出手机要的会话列表。

提醒规则（和 Mac 版一致）：
  1. 会话处于 waiting →「需要确认」（同一等待原因只提醒一次）
  2. 从 busy 变成 idle 且带结论文本 →「已完成」（同一条消息只提醒一次）
  3. 第一次见到的会话（启动、来源重连）只建基线，不补发历史提醒
"""

import threading
import time
from datetime import datetime

from . import log

RANK = {"waiting": 0, "busy": 1, "idle": 2}


def is_vscode(snap):
    entry = snap.get("entrypoint")
    return entry is None or entry == "claude-vscode"


def display_title(snap):
    title = snap.get("title")
    return title if title else snap.get("name", "")


# 看、回复、确认、中断以外手机上还能出的按钮（docs/agent-plugins.md 4.4）；Claude Code 的会话和老 watcher 不带，按 agent 补。
# close（关闭会话，1.0.12 起）只由电脑端给：手机连老电脑端时的兜底全套里没有它
CLAUDE_CAPS = ["mode", "model", "compact", "subagents", "tests", "close"]


def caps_payload(snap):
    caps = snap.get("caps")
    if isinstance(caps, list):
        return [str(cap) for cap in caps]
    return list(CLAUDE_CAPS) if (snap.get("agent") or "claude-code") == "claude-code" else []


def blocking(snap):
    for key in ("waitingFor", "needs"):
        if snap.get(key):
            return snap[key]
    if snap.get("pendingTool"):
        return "等待确认：%s" % snap["pendingTool"]
    return None


def error_display(error):
    """接口错误带上恢复时间：「Claude 用量已达上限，21:10 恢复」；已经过了就提示可以接着做"""
    text = error.get("text") or ""
    reset = error.get("resetAt")
    if not reset:
        return text
    when = datetime.fromtimestamp(reset / 1000)
    fmt = "%H:%M" if when.date() == datetime.now().date() else "%m月%d日 %H:%M"
    stamp = when.strftime(fmt).lstrip("0")
    if when <= datetime.now():
        return "%s（%s 已恢复，发送「继续」即可接着执行）" % (text, stamp)
    return "%s，%s 恢复" % (text, stamp)


def usage_payload(usage):
    context, window = usage.get("context", 0), usage.get("window", 0)
    percent = int(round(min(1.0, context / window) * 100)) if window else 0
    out = {k: usage.get(k, 0) for k in ("context", "window", "input", "output", "cacheRead", "cacheWrite")}
    out["percent"] = percent
    for key in ("requests", "model", "cost"):
        if usage.get(key) is not None:
            out[key] = usage[key]
    return out


class Record:
    __slots__ = ("source_id", "source_name", "kind", "snap")

    def __init__(self, source_id, source_name, kind, snap):
        self.source_id, self.source_name, self.kind, self.snap = source_id, source_name, kind, snap

    @property
    def key(self):
        return "%s#%s" % (self.source_id, self.snap.get("sessionId"))

    @property
    def activity(self):
        act = self.snap.get("activity")
        return act if act in ("busy", "waiting", "idle") else "unknown"


class Store:
    def __init__(self, cfg, on_change, on_notify):
        self.cfg = cfg
        self._on_change = on_change
        self._on_notify = on_notify
        self.lock = threading.RLock()
        self.records = []
        self.sources = {}          # id → 来源对象
        self._previous = {}
        self._notified_needs = {}
        self._notified_conclusions = {}
        self._last_attention = {}
        self._last_conclusion = {}
        # 来源还连着、会话却不在它报来的列表里了（关掉、结束了）：on_lost(那几条记录)
        self.on_lost = None

    # MARK: 输入

    def add_source(self, source):
        with self.lock:
            self.sources[source.id] = source

    def source_changed(self, source):
        if not source.live:
            with self.lock:
                self.records = [r for r in self.records if r.source_id != source.id]
                self._previous = {k: v for k, v in self._previous.items() if v.source_id != source.id}
        self._on_change()

    def apply_snapshots(self, source, sessions):
        prefixes = source.config.get("pathPrefixes") or []
        incoming = [Record(source.id, source.name, source.kind, snap) for snap in sessions
                    if not prefixes or any((snap.get("cwd") or "").startswith(p) for p in prefixes)]
        transitions = []
        with self.lock:
            # 同一会话在两个窗口里同时开着时会报出两条同 id 的会话：只留最后打开的那条
            newest = {}
            for record in [r for r in self.records if r.source_id != source.id] + incoming:
                kept = newest.get(record.key)
                if kept is None or (record.snap.get("startedAt") or 0) >= (kept.snap.get("startedAt") or 0):
                    newest[record.key] = record
            merged = list(newest.values())
            merged.sort(key=lambda r: (RANK.get(r.activity, 3), -(r.snap.get("startedAt") or 0)))
            current = set()
            for record in merged:
                current.add(record.key)
                transition = self._classify(self._previous.get(record.key), record)
                if transition:
                    transitions.append((record, transition))
            gone = [old for key, old in self._previous.items() if key not in current and old.source_id == source.id]
            self.records = merged
            self._previous = {r.key: r for r in merged}
        if gone and self.on_lost:
            self.on_lost(gone)
        for record, (kind, text) in transitions:
            if self._pass_cooldown(record, kind):
                self._on_notify(record, kind, text)
        self._on_change()

    def _classify(self, old, new):
        key = new.key
        if old is None:
            # 第一次见到：记下现在的状态当基线，不补发
            if new.activity == "waiting":
                self._notified_needs[key] = blocking(new.snap) or "waiting"
            if new.activity == "idle":
                self._notified_conclusions[key] = new.snap.get("messageUuid") or new.snap.get("message")
            return None
        if new.activity == "waiting":
            reason = blocking(new.snap) or "waiting"
            if self._notified_needs.get(key) != reason:
                self._notified_needs[key] = reason
                return ("attention", blocking(new.snap) or "需要确认")
            return None
        self._notified_needs.pop(key, None)
        if new.activity == "idle":
            message = new.snap.get("message")
            if not message:
                return None
            fingerprint = new.snap.get("messageUuid") or message
            if self._notified_conclusions.get(key) != fingerprint:
                self._notified_conclusions[key] = fingerprint
                return ("conclusion", message)
        return None

    def _pass_cooldown(self, record, kind):
        now = time.time()
        if kind == "attention":
            if not self.cfg.get("notifyOnNeedsAttention", True):
                return False
            if now - self._last_attention.get(record.key, 0) < 20:
                return False
            self._last_attention[record.key] = now
            return True
        if kind == "conclusion":
            if not self.cfg.get("notifyOnConclusion", True):
                return False
            if now - self._last_conclusion.get(record.key, 0) < 20:
                return False
            self._last_conclusion[record.key] = now
            return True
        return False

    # MARK: 查询

    def record(self, key):
        with self.lock:
            for record in self.records:
                if record.key == key:
                    return record
        return None

    def source(self, source_id):
        with self.lock:
            return self.sources.get(source_id)

    def state_payload(self, host, version, me):
        m = self.cfg.mobile
        with self.lock:
            records = list(self.records)
            sources = list(self.sources.values())
        sessions = []
        for record in records:
            snap = record.snap
            item = {
                "key": record.key, "sessionId": snap.get("sessionId"), "sourceId": record.source_id,
                "sourceName": record.source_name, "sourceKind": record.kind, "name": snap.get("name", ""),
                "title": display_title(snap), "cwd": snap.get("cwd", ""), "cwdShort": snap.get("cwdShort", ""),
                "activity": record.activity, "entrypoint": snap.get("entrypoint") or "",
                "agent": snap.get("agent") or "claude-code",
                # Codex、OpenCode、DeepSeek Harness 走协议，在哪台机器上都能回复；Proma 这类只读的不行
                "canReply": not snap.get("readOnly") and (
                    is_vscode(snap) or bool(snap.get("tmuxPane")) or record.kind == "local"
                    or (snap.get("agent") or "claude-code") != "claude-code"),
            }
            for src, dst in (("reason", "reason"), ("activityText", "activityText"), ("message", "preview"),
                             ("pendingTool", "pendingTool"), ("startedAt", "startedAt"), ("branch", "branch"), ("worktree", "worktree")):
                if snap.get(src) is not None:
                    item[dst] = snap[src]
            effort = snap.get("effort") or {}
            if effort.get("effort") is not None:
                item["effort"] = effort["effort"]
            if effort.get("ultracode") is not None:
                item["ultracode"] = effort["ultracode"]
            if effort.get("mode") is not None:
                item["permissionMode"] = effort["mode"]
            stage = snap.get("stage")
            if isinstance(stage, dict) and record.activity in ("busy", "waiting") and stage.get("step") and stage.get("total"):
                item["stage"] = stage   # 这一轮任务做到第几步（「2/4 开发中」，watcher 推断或 agent 报的）
            if snap.get("subagents"):
                item["subagents"] = snap["subagents"]
            if snap.get("readOnly"):   # 只能看、不能远程操作（Proma 这类）
                item["readOnly"] = True
            if snap.get("readOnlyReason"):
                item["readOnlyReason"] = snap["readOnlyReason"]
                if snap.get("readOnlyReasonEn"):   # 插件自带的英文：出口按设备语言换（单独下发的插件新加的文字不用等我们发版）
                    item["readOnlyReasonEn"] = snap["readOnlyReasonEn"]
            # 终端（term）开在会话所在的电脑上，哪家 agent 的会话都能开；只有这一版起的电脑端才有，手机见到才显示终端按钮（同 Mac）
            item["caps"] = caps_payload(snap) + ["term"]
            if snap.get("terminals"):
                item["terminals"] = snap["terminals"]
            if snap.get("pendingOptions") and record.activity == "waiting":
                item["pendingOptions"] = [dict({"key": str(o.get("key")), "label": str(o.get("label")), "style": o.get("style") or "normal"},
                                               **({"labelEn": str(o["labelEn"])} if o.get("labelEn") else {}))
                                          for o in snap["pendingOptions"] if isinstance(o, dict) and o.get("key") and o.get("label")]
            if snap.get("error") and record.activity == "idle":
                item["error"] = error_display(snap["error"])
                item["errorKind"] = snap["error"].get("kind")
            if record.activity == "waiting" and blocking(snap):
                item["blocking"] = blocking(snap)
            updated = snap.get("transcriptUpdatedAt") or snap.get("statusUpdatedAt") or snap.get("updatedAt")
            if updated is not None:
                item["updatedAt"] = updated
            if snap.get("usage"):
                item["usage"] = usage_payload(snap["usage"])
            sessions.append(item)
        source_list = [{"id": s.id, "name": s.name, "kind": s.kind, "online": s.live, "status": s.short_label()}
                       for s in sources]
        return {
            "ok": True, "host": host, "version": version, "submitOnSend": m["submitOnSend"],
            "quickReplies": m["quickReplies"], "watch": m["watch"], "me": me, "muted": m["mutedSessions"],
            "pinned": m["pinnedSessions"], "marked": m.get("markedSessions") or [], "quietActive": self.cfg.in_quiet_hours(), "sources": source_list,
            "sessions": sessions,
        }

    def resolve_any(self, key):
        """只读查询用：会话还在跑就用它的记录；结束了的按「来源#会话 id」去那台机器找。返回 (会话 id, 来源) 或 None"""
        record = self.record(key)
        if record:
            source = self.source(record.source_id)
            return (record.snap.get("sessionId"), source) if source else None
        if not key or "#" not in key:
            return None
        source_id, session_id = key.split("#", 1)
        import re
        if not re.match(r"^[A-Za-z0-9-]{8,64}$", session_id):
            return None
        source = self.source(source_id)
        if not source or not source.live:
            return None
        return session_id, source

    def log_summary(self):
        with self.lock:
            waiting = sum(1 for r in self.records if r.activity == "waiting")
            busy = sum(1 for r in self.records if r.activity == "busy")
        if waiting:
            return "%d 个会话待确认" % waiting
        if busy:
            return "%d 个会话运行中" % busy
        return "全部空闲"


def note(message):
    log.write(message)
