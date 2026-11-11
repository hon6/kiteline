"""提醒与简报（对应 Mac 版 Digest.swift 里的 StuckWatch / WaitingReminder / DailyReport）：
  - 等确认太久：10 分钟、30 分钟各再推一次
  - 可能停滞：正在工作，但对话记录 20 分钟没有新动静（每次卡住只提醒一次）
  - 日报、早安简报的文字
"""

import os
from datetime import datetime, timedelta

from . import aggregate, i18n, log
from .store import blocking, display_title, error_display

STUCK_THRESHOLD = 1200
WAIT_MARKS = (600, 1800)


def last_progress(snap):
    last = snap.get("transcriptUpdatedAt") or snap.get("statusUpdatedAt") or snap.get("updatedAt")
    return last if last and last > 0 else None


def quiet_minutes(record, now_ts):
    if record.activity != "busy":
        return None
    last = last_progress(record.snap)
    if not last:
        return None
    quiet = now_ts - last / 1000
    return int(quiet / 60) if quiet >= STUCK_THRESHOLD else None


class StuckWatch:
    def __init__(self, app):
        self.app = app
        self._notified = {}

    def tick(self, now_ts):
        alive = set()
        with self.app.store.lock:
            records = list(self.app.store.records)
        for record in records:
            minutes = quiet_minutes(record, now_ts)
            last = last_progress(record.snap)
            if minutes is None or not last:
                continue
            alive.add(record.key)
            if self._notified.get(record.key) == last:
                continue
            self._notified[record.key] = last
            title = display_title(record.snap)
            doing = "正在 %s" % record.snap["activityText"] if record.snap.get("activityText") else "正在工作"
            self.app.server.notify("stuck", title, "已有 %d 分钟无新进展（%s），可能已停滞。点击进入可中断" % (minutes, doing), record.key)
            self.app.audit.note("可能停滞", "%s %d 分钟无进展" % (title, minutes))
            log.write("可能卡住了：%s %d 分钟没动静（%s）" % (title, minutes, doing))
        self._notified = {k: v for k, v in self._notified.items() if k in alive}


class WaitingReminder:
    def __init__(self, app):
        self.app = app
        self._tracked = {}

    def tick(self, now_ts):
        if not self.app.cfg.mobile.get("remindWaiting", True):
            self._tracked.clear()
            return
        alive = set()
        with self.app.store.lock:
            records = [r for r in self.app.store.records if r.activity == "waiting"]
        for record in records:
            snap = record.snap
            key = "%s|%s|%s" % (record.key, snap.get("pendingTool") or "", blocking(snap) or "")
            alive.add(key)
            since, sent = self._tracked.get(key, (now_ts, 0))
            waited = now_ts - since
            if sent < len(WAIT_MARKS) and waited >= WAIT_MARKS[sent]:
                while sent < len(WAIT_MARKS) and waited >= WAIT_MARKS[sent]:
                    sent += 1
                minutes = int(waited / 60)
                title = display_title(snap)
                self.app.server.notify("attention", title, "已等待确认 %d 分钟：%s" % (minutes, blocking(snap) or "需要确认"), record.key)
                self.app.audit.note("确认提醒", "%s 已等待 %d 分钟" % (title, minutes))
                log.write("催确认：%s 已等 %d 分钟" % (title, minutes))
            self._tracked[key] = (since, sent)
        self._tracked = {k: v for k, v in self._tracked.items() if k in alive}


def headline(payload, english=False):
    p = i18n.Phrase(english)
    t = payload.get("totals") or {}
    sessions = int(aggregate.number(t.get("sessions")))
    if not sessions:
        return p("今日暂无 Claude Code 动态")
    parts = [p("%lld 个会话", sessions), p("%lld 轮对话", int(aggregate.number(t.get("prompts"))))]
    files = int(aggregate.number(t.get("files")))
    if files:
        parts.append(p("修改 %lld 个文件", files))
    runs = int(aggregate.number(t.get("testRuns")))
    if runs:
        failed = int(aggregate.number(t.get("testFailed")))
        parts.append(p("测试 %lld 次（%lld 次失败）", runs, failed) if failed else p("测试 %lld 次", runs))
    images = int(aggregate.number(t.get("images")))
    if images:
        parts.append(p("%lld 张截图", images))
    return " · ".join(parts)


def report_body(payload, english=False):
    p = i18n.Phrase(english)
    lines = [headline(payload, english)]
    sessions = sorted(payload.get("sessions") or [], key=lambda s: -aggregate.number(s.get("prompts")))[:4]
    for item in sessions:
        title = item.get("title") or os.path.basename((item.get("cwd") or "").rstrip("/\\")) or p("会话")
        bits = []
        prompts = int(aggregate.number(item.get("prompts")))
        if prompts:
            bits.append(p("%lld 轮", prompts))
        files = int(aggregate.number(item.get("fileCount")))
        if files:
            bits.append(p("%lld 个文件", files))
        if aggregate.number((item.get("tests") or {}).get("failed")) > 0:
            bits.append(p("测试有失败"))
        lines.append("• %s%s%s" % (title, p.colon, p.comma.join(bits)) if bits else "• %s" % title)
    return "\n".join(lines)


def pending_line(projects, english=False):
    p = i18n.Phrase(english)
    items = projects.get("projects") or []
    dirty = [i for i in items if aggregate.number((i.get("git") or {}).get("changed")) > 0]
    unpushed = [i for i in items if aggregate.number((i.get("git") or {}).get("ahead")) > 0]
    if not dirty and not unpushed:
        return None

    def names(rows):
        return p.list.join(r.get("name", "") for r in rows[:3]) + (p(" 等") if len(rows) > 3 else "")
    parts = []
    if dirty:
        parts.append(p("%lld 个有未提交的改动（%@）", len(dirty), names(dirty)))
    if unpushed:
        parts.append(p("%lld 个未推送（%@）", len(unpushed), names(unpushed)))
    return p("项目：%@", p.semicolon.join(parts))


def send_digest(app, manual):
    payload = aggregate.digest(app.store, aggregate_start_of_day(), fresh=True)
    if not payload.get("sessions") and not manual:
        log.write("日报：今天没有动态，不推送")
        return "今日无动态"
    # 中文设备收中文、英文设备收英文：各拼一份
    now = datetime.now()
    title = "Kiteline 日报 · %d月%d日" % (now.month, now.day)
    english = (i18n.Phrase(True)("Kiteline 日报 · %@", now.strftime("%b ") + str(now.day)), report_body(payload, True))
    app.server.notify("digest", title, report_body(payload), None, route="today", english=english)
    log.write("日报已推送：%s" % headline(payload))
    return "已推送：%s" % headline(payload)


def aggregate_start_of_day():
    from . import config
    return config.start_of_day_ms()


def yesterday_brag_line(payload, now):
    """晨报里的「昨日战绩」一行：(中文, 英文)；昨天没干活回 None（同 Mac 版 Brag.yesterdayLine）"""
    key = (now - timedelta(days=1)).strftime("%Y-%m-%d")
    day = next((d for d in payload.get("days") or [] if d.get("day") == key), None)
    if not day:
        return None
    n = lambda field: float(day.get(field) or 0)
    tokens = n("input") + n("output") + n("cacheRead") + n("cacheWrite")
    if tokens <= 0 and n("sessions") <= 0:
        return None
    zh_num = lambda v: "%.2f 亿" % (v / 1e8) if v >= 1e8 else "%.1f 万" % (v / 1e4) if v >= 1e4 else str(int(v))
    en_num = lambda v: "%.2fB" % (v / 1e9) if v >= 1e9 else "%.1fM" % (v / 1e6) if v >= 1e6 else "%.1fK" % (v / 1e3) if v >= 1e3 else str(int(v))
    zh, en = ["昨日战绩：%s Token" % zh_num(tokens)], ["Yesterday: %s tokens" % en_num(tokens)]
    if n("linesAdded") > 0:
        zh.append("+{:,} 行代码".format(int(n("linesAdded"))))
        en.append("+{:,} lines".format(int(n("linesAdded"))))
    hours = n("activeMinutes") / 60
    if hours >= 0.1:
        zh.append("在线 %.1f 小时" % hours)
        en.append("%.1f h online" % hours)
    if n("peak") >= 2:
        zh.append("最多同时 %d 个 Agent" % n("peak"))
        en.append("up to %d agents at once" % n("peak"))
    return " · ".join(zh), " · ".join(en)


def send_morning(app, manual, now=None):
    now = now or datetime.now()
    since_dt = (now - timedelta(days=1)).replace(hour=18, minute=0, second=0, microsecond=0)
    since = int(since_dt.timestamp() * 1000)
    payload = aggregate.digest(app.store, since, fresh=True)
    sessions = payload.get("sessions") or []
    with app.store.lock:
        records = list(app.store.records)
    waiting = [r for r in records if r.activity == "waiting"]
    # 昨日战绩一行（Token、代码行数、在线时长）：昨天干过活就推，点开今日动态最上面就是分享卡
    try:
        brag_line = yesterday_brag_line(aggregate.brag(app.store, 2), now)
    except Exception as exc:  # noqa: BLE001
        log.write("早安简报：读昨日战绩出错：%s" % exc)
        brag_line = None
    if not sessions and not waiting and not brag_line and not manual:
        log.write("早安简报：昨晚没有动态，也没有等你的会话，不推送")
        return "昨晚无动态"
    stuck = []
    for record in records:
        minutes = quiet_minutes(record, now.timestamp())
        if minutes is not None:
            stuck.append((display_title(record.snap), minutes))
    stopped = [r for r in records if r.activity == "idle" and r.snap.get("error")]
    held = [e for e in app.inbox.recent(300, since) if e.get("delivery") == "quiet"]
    projects = aggregate.projects(app.store, detail=True)

    def compose(english):
        """按语言各拼一份：中文设备收中文、英文设备收英文"""
        p = i18n.Phrase(english)
        lines = []
        if waiting:
            lines.append(p("待确认：%lld 个会话", len(waiting)) + p.comma + p.list.join(display_title(r.snap) for r in waiting[:3]))
        if brag_line:
            lines.append(brag_line[1] if english else brag_line[0])
        lines.append(p("昨晚：%@", headline(payload, english)) if sessions else p("昨晚无 Claude Code 动态"))
        if stuck:
            lines.append(p("可能停滞：%lld 个会话", len(stuck)) + p.comma + p.semicolon.join(
                p("%@（%@无进展）", title, p("%lld 小时", minutes // 60) if minutes >= 120 else p("%lld 分钟", minutes))
                for title, minutes in stuck[:3]))
        if stopped:
            lines.append(p("出错停止：%lld 个会话", len(stopped)) + p.comma + p.semicolon.join(
                p("%@（%@）", display_title(r.snap), i18n.translate(error_display(r.snap["error"])) if english else error_display(r.snap["error"]))
                for r in stopped[:3]))
        if held:
            kinds = {}
            for entry in held:
                kinds[entry["kind"]] = kinds.get(entry["kind"], 0) + 1
            parts = [p(fmt, kinds[k]) for k, fmt in (("conclusion", "%lld 条结论"), ("error", "%lld 条出错提醒"), ("stuck", "%lld 条停滞提醒"),
                                                    ("image", "%lld 张图片"), ("schedule", "%lld 条定时任务")) if k in kinds]
            lines.append(p("免打扰期间有 %lld 条提醒未推送（%@），可在 Kiteline 的通知中查看", len(held), p.list.join(parts)))
        line = pending_line(projects, english)
        if line:
            lines.append(line)
        body = "\n".join(lines + report_body(payload, english).split("\n")[1:])
        title = p("早安 · %lld 个会话待确认", len(waiting)) if waiting else p("早安 · 昨晚的动态")
        return title, body, lines

    title, body, lines = compose(False)
    english = compose(True)
    app.server.notify("digest", title, body, None, route="today", english=english[:2])
    app.audit.note("早安简报", "；".join(lines))
    log.write("早安简报已推送：%s" % "；".join(lines))
    return "已推送：%s" % "；".join(lines)
