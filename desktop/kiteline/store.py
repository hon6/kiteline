"""会话中枢（对应 Mac 版 SessionStore.swift + AppState.mobileStatePayload）：
合并各来源的会话快照，判定该不该提醒，拼出手机要的会话列表。

提醒规则（和 Mac 版一致）：
  1. 会话处于 waiting →「需要确认」（同一等待原因只提醒一次）
  2. 从 busy 变成 idle 且带结论文本 →「已完成」（同一条消息只提醒一次）
  3. 第一次见到的会话（启动、来源重连）只建基线，不补发历史提醒
  4. 别的会话来信引起的那一轮（turnFrom = peer）答完不提醒，出错停下照样提醒
"""

import threading
import time
from datetime import datetime

from . import log

RANK = {"waiting": 0, "busy": 1, "idle": 2}


def is_vscode(snap):
    entry = snap.get("entrypoint")
    return entry is None or entry == "claude-vscode"


def hostable(record, source):
    """能转到后台运行的会话：远端电脑上、在 VS Code 里跑的 Claude Code，那台电脑的 watcher 支持后台运行（同 Mac 版 Hosted.hostable）"""
    snap = record.snap
    return (record.kind == "ssh" and not snap.get("hosted") and (snap.get("agent") or "claude-code") == "claude-code"
            and is_vscode(snap) and not snap.get("readOnly") and "hosted" in (getattr(source, "features", None) or ()))


def display_title(snap):
    title = snap.get("title")
    return title if title else snap.get("name", "")


# 看、回复、确认、中断以外手机上还能出的按钮（guide/plugin-development.md 4.4）；Claude Code 的会话和老 watcher 不带，按 agent 补。
# close（关闭会话，1.0.12 起）只由电脑端给：手机连老电脑端时的兜底全套里没有它
CLAUDE_CAPS = ["mode", "model", "compact", "subagents", "tests", "close"]


def caps_payload(snap):
    caps = snap.get("caps")
    if isinstance(caps, list):
        out = [str(cap) for cap in caps]
    else:
        out = list(CLAUDE_CAPS) if (snap.get("agent") or "claude-code") == "claude-code" else []
    # goal（设定目标，发 /goal）：Claude Code 2.1.139 起有，按会话报来的版本给；别家由插件给（Codex 终端里的会话）（同 Mac 版 capsPayload）
    if (snap.get("agent") or "claude-code") == "claude-code" and claude_goal_ready(snap.get("version")) and "goal" not in out:
        out.append("goal")
    return out


# 目标（/goal）：agent 围着一个目标跨多轮一直做、每轮结束检查（watcher 的 GoalBook）。还在做的状态；别的是达成 met / 做不到 failed / 出错 error
GOAL_RUNNING = ("active", "paused", "blocked", "limited")
GOAL_HEADS = {"paused": "目标已暂停", "blocked": "目标受阻", "limited": "目标额度已用完", "met": "目标已达成",
              "failed": "目标无法达成", "error": "目标已中止", "active": "目标进行中"}


def claude_goal_ready(version):
    """Claude Code 的版本号（2.1.314）够不够用 /goal"""
    try:
        parts = [int(x) for x in str(version or "").split(".")[:3]]
    except ValueError:
        return False
    return len(parts) == 3 and parts >= [2, 1, 139]


def snap_goal(snap):
    goal = snap.get("goal")
    return goal if isinstance(goal, dict) and goal.get("text") else None


def goal_ended(old, new):
    """目标从「在做」变成另一个状态（达成、做不到、停下、出错）→ 新的目标；你自己清除的快照里就没了，不提醒"""
    if not new or new.get("state") == "active" or not old or old.get("text") != new.get("text"):
        return None
    return new if old.get("state") != new.get("state") else None


def goal_push_body(goal, english):
    """推送正文：目标是什么 + 结果（用了几轮、多久 / 为什么做不到 / 为什么停下）（同 Mac 版 GoalSnapshot.pushBody）"""
    from .i18n import Phrase, translate
    p = Phrase(english)
    text = goal.get("text") or ""
    text = text[:80] + "…" if len(text) > 80 else text
    detail = None
    note = goal.get("note")
    note = (translate(note) if english else note) if note else None
    state = goal.get("state")
    if state == "met":
        parts = []
        rounds = goal.get("turns") or goal.get("checks")
        if rounds:
            parts.append(p("%lld 轮", int(rounds)))
        minutes = int((goal.get("durationMs") or 0) / 60000)
        if minutes:
            parts.append(p("%lld 小时", minutes // 60) if minutes >= 120 else p("%lld 分钟", minutes))
        detail = p("用了 %@", " · ".join(parts)) if parts else None
    elif state == "paused":
        detail = note or p("发送消息即可继续")
    else:
        detail = note or goal.get("reason")
    return "\n".join(x for x in (p("目标：%@", text), detail) if x)


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
        goal = goal_ended(snap_goal(old.snap), snap_goal(new.snap))
        if goal and new.activity != "waiting":
            # 这一条替掉同时到的「已完成」：结论记成提醒过了（同 Mac 版 SessionStore）
            if new.activity == "idle":
                self._notified_conclusions[key] = new.snap.get("messageUuid") or new.snap.get("message")
            self._notified_needs.pop(key, None)
            return ("goal", goal)
        self._notified_needs.pop(key, None)
        if new.activity == "idle":
            message = new.snap.get("message")
            if not message:
                return None
            fingerprint = new.snap.get("messageUuid") or message
            if self._notified_conclusions.get(key) != fingerprint:
                self._notified_conclusions[key] = fingerprint
                # 别的会话来信引起的那一轮（会话之间的往来）答完不提醒；出错停下照样提醒（同 Mac 版 SessionStore）
                if new.snap.get("turnFrom") == "peer" and not new.snap.get("error"):
                    return None
                # 目标还在做：这一轮停下不算完（Codex 一轮接一轮自己续做），等目标达成 / 停下时再提醒
                if (snap_goal(new.snap) or {}).get("state") == "active":
                    return None
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
        if kind == "goal":
            return self.cfg.get("notifyOnConclusion", True)
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

    def state_payload(self, host, version, me, viewed_at=None):
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
                    is_vscode(snap) or bool(snap.get("tmuxPane") or snap.get("hosted")) or snap.get("bridge") is True or record.kind == "local"
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
            if snap_goal(snap):
                item["goal"] = snap["goal"]   # 目标（/goal）：在做的、结束不久的（watcher 给）
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
            if hostable(record, self.sources.get(record.source_id)):
                item["hostable"] = True   # 能转到后台运行（会话页提示「支持后台托管」）
            if snap.get("terminals"):
                item["terminals"] = snap["terminals"]
            # 新消息怎么算（各端，同 Mac）：最后一次在任何一端看过的时间；最近一轮是别的会话来信引起的不算给你的新消息
            seen = viewed_at(record.key) if viewed_at else None
            if seen is not None:
                item["viewedAt"] = seen
            if snap.get("turnFrom") == "peer":
                item["fromPeer"] = True
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
        hosted_on = {e.get("id") for e in self.cfg.sources if e.get("hostedOn")}
        for item, s in zip(source_list, sources):
            if s.kind == "ssh" and "hosted" in s.features:
                item["hosted"] = "on" if s.id in hosted_on else "off"   # 能后台运行 Claude Code 才带（按设备开）
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
