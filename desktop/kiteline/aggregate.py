"""跨来源汇总（对应 Mac 版 PastSessions / Projects / Digest / UsageReport）：
问每个在线来源的 watcher，合并结果；每条带上 key（来源#会话 id）和是否还在运行。
"""

import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta

from . import config


def number(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def _live_sources(store):
    with store.lock:
        return [s for s in store.sources.values() if s.live]


def _offline_errors(store):
    with store.lock:
        return ["%s：%s" % (s.name, s.short_label()) for s in store.sources.values() if not s.live]


def _ask_all(sources, request, timeout):
    """并行问各来源，返回 [(来源, 应答 or None, 错误 or None)]"""
    def one(source):
        try:
            return source, source.request(request, timeout=timeout), None
        except Exception as exc:  # noqa: BLE001
            return source, None, "%s：%s" % (source.name, exc)
    if not sources:
        return []
    with ThreadPoolExecutor(max_workers=max(1, len(sources))) as pool:
        return list(pool.map(one, sources))


def _gather(store, request, field, timeout, only=None):
    items, errors, truncated = [], [], False
    sources = [s for s in _live_sources(store) if only is None or s.id == only]
    for source, response, error in _ask_all(sources, request, timeout):
        if error:
            errors.append(error)
            continue
        truncated = truncated or bool(response.get("truncated"))
        for item in response.get(field) or []:
            key = "%s#%s" % (source.id, item.get("sessionId", ""))
            item.update({"key": key, "sourceId": source.id, "sourceName": source.name, "sourceKind": source.kind})
            record = store.record(key)
            item["live"] = record is not None
            if record:
                item["activity"] = record.activity
            items.append(item)
    return items, errors, truncated


def past_sessions(store, source_id=None, cwd=None, project=None):
    """project（项目名 = 目录最后一级）给定时列各机器上这个项目的会话，多取一些（历史会话按项目筛时补全）"""
    request = {"cmd": "sessions_list", "limit": 120}
    if cwd:
        request.update({"cwd": cwd, "limit": 40})
    if project:
        request.update({"project": project, "limit": 300})
    items, errors, _ = _gather(store, request, "sessions", 40, only=source_id)
    items.sort(key=lambda i: -number(i.get("lastActive")))
    return {"ok": True, "sessions": items, "errors": errors}


def search(store, query):
    items, errors, truncated = _gather(store, {"cmd": "search", "q": query}, "results", 40)

    def newest(item):
        hits = [number(h.get("ts")) for h in item.get("hits") or []]
        return max(hits) if hits else number(item.get("lastActive"))
    items.sort(key=lambda i: -newest(i))
    return {"ok": True, "query": query, "results": items, "errors": errors, "truncated": truncated}


def projects(store, detail=False):
    items, order, errors = {}, [], []

    def upsert(source, cwd):
        key = "%s\n%s" % (source.id, cwd)
        if key not in items:
            items[key] = {"sourceId": source.id, "sourceName": source.name, "kind": source.kind, "cwd": cwd,
                          "name": os.path.basename(cwd.rstrip("/\\")) or cwd, "exists": True, "lastActive": 0,
                          "live": 0, "open": False}
            order.append(key)
        return items[key]

    start = config.start_of_day_ms()
    sources = _live_sources(store)
    with store.lock:
        records = list(store.records)
    requests = {}
    for source in sources:
        if detail:
            live_cwds = sorted({r.snap.get("cwd") for r in records if r.source_id == source.id and r.snap.get("cwd")})
            requests[source.id] = {"cmd": "project_overview", "limit": 40, "since": start, "extra": live_cwds}
        else:
            requests[source.id] = {"cmd": "projects"}

    def one(source):
        try:
            return source, source.request(requests[source.id], timeout=30), None
        except Exception as exc:  # noqa: BLE001
            return source, None, "%s：%s" % (source.name, exc)
    results = []
    if sources:
        with ThreadPoolExecutor(max_workers=len(sources)) as pool:
            results = list(pool.map(one, sources))
    for source, response, error in results:
        if error:
            errors.append(error)
            continue
        for project in response.get("projects") or []:
            cwd = project.get("cwd")
            if not cwd:
                continue
            item = upsert(source, cwd)
            if number(project.get("lastActive")) > number(item["lastActive"]):
                item["lastActive"] = project.get("lastActive")
            item["exists"] = project.get("exists", True)
            if project.get("title"):
                item["title"] = project["title"]
            for field in ("sessionId", "sessions", "today", "git"):
                if project.get(field) is not None:
                    item[field] = project[field]
    by_id = {s.id: s for s in sources}
    for record in records:
        source = by_id.get(record.source_id)
        cwd = record.snap.get("cwd")
        if not source or not cwd:
            continue
        item = upsert(source, cwd)
        item["live"] = item.get("live", 0) + 1
        if record.activity == "waiting":
            item["waiting"] = item.get("waiting", 0) + 1
        if record.activity == "busy":
            item["busy"] = item.get("busy", 0) + 1
        updated = record.snap.get("transcriptUpdatedAt") or record.snap.get("updatedAt") or 0
        if updated > number(item["lastActive"]):
            item["lastActive"] = updated
        item.setdefault("title", record.snap.get("title") or record.snap.get("name"))
    listing = [items[k] for k in order]
    listing.sort(key=lambda x: (-((2 if x.get("live") else 0) + (1 if x.get("open") else 0)), -number(x.get("lastActive"))))
    return {"ok": True, "projects": listing, "errors": errors}


_digest_cache = {}
_digest_lock = threading.Lock()


def digest(store, since, until=None, fresh=False):
    cache_key = "%s-%s" % (since, until or 0)
    with _digest_lock:
        hit = _digest_cache.get(cache_key)
        if not fresh and hit and time.time() - hit[0] < 30:
            return hit[1]
    errors = _offline_errors(store)
    complete = not errors
    request = {"cmd": "digest", "since": since}
    if until:
        request["until"] = until
    sessions = []
    for source, response, error in _ask_all(_live_sources(store), request, 60):
        if error:
            errors.append(error)
            continue
        for item in response.get("sessions") or []:
            item["sourceId"], item["sourceName"] = source.id, source.name
            key = "%s#%s" % (source.id, item.get("sessionId", ""))
            record = store.record(key)
            if record:
                item["key"], item["activity"] = key, record.activity
            sessions.append(item)
    sessions.sort(key=lambda i: -number(i.get("lastAt")))
    payload = {"ok": True, "since": since, "until": until or 0, "generatedAt": int(time.time() * 1000),
               "sessions": sessions, "totals": digest_totals(sessions), "errors": errors}
    if complete and not errors:
        with _digest_lock:
            _digest_cache[cache_key] = (time.time(), payload)
    return payload


def digest_totals(sessions):
    def total(key):
        return int(sum(number(s.get(key)) for s in sessions))

    def tests(key):
        return int(sum(number((s.get("tests") or {}).get(key)) for s in sessions))
    return {"sessions": len(sessions), "projects": len({s.get("cwd") for s in sessions if s.get("cwd")}),
            "prompts": total("prompts"), "replies": total("replies"), "requests": total("requests"),
            "outputTokens": total("outputTokens"), "files": total("fileCount"), "images": total("images"),
            "testRuns": tests("runs"), "testPassed": tests("passed"), "testFailed": tests("failed")}


USAGE_FIELDS = ("input", "output", "cacheRead", "cacheWrite", "requests", "cost", "estimated")
_usage_cache = {}


def _blank(extra=None):
    item = dict(extra or {})
    for field in USAGE_FIELDS:
        item[field] = 0.0
    return item


def _add(base, other):
    out = dict(base)
    for field in USAGE_FIELDS:
        out[field] = number(base.get(field)) + number(other.get(field))
    return out


def usage(store, days, fresh=False):
    days = max(1, min(int(days or 7), 90))
    hit = _usage_cache.get(days)
    if not fresh and hit and time.time() - hit[0] < 60:
        return hit[1]
    since = config.start_of_day_ms() - (days - 1) * 86_400_000
    tz = int(-time.altzone / 60) if time.localtime().tm_isdst else int(-time.timezone / 60)
    by_day, by_model, by_project, by_source, unpriced = {}, {}, {}, [], set()
    totals = _blank()
    errors = _offline_errors(store)
    complete = not errors
    for source, r, error in _ask_all(_live_sources(store), {"cmd": "usage_report", "since": since, "tz": tz}, 90):
        if error:
            errors.append(error)
            continue
        for day in r.get("days") or []:
            key = day.get("day", "")
            by_day[key] = _add(by_day.get(key) or _blank({"day": key}), day)
        for model in r.get("models") or []:
            key = model.get("model") or "unknown"
            by_model[key] = _add(by_model.get(key) or _blank({"model": key}), model)
        for project in r.get("projects") or []:
            cwd = project.get("cwd", "")
            key = "%s\n%s" % (source.id, cwd)
            by_project[key] = _add(by_project.get(key) or _blank({"cwd": cwd, "name": os.path.basename(cwd.rstrip("/\\")),
                                                                  "sourceName": source.name, "sourceId": source.id}), project)
        source_totals = r.get("totals") or {}
        totals = _add(totals, source_totals)
        by_source.append(_add(_blank({"name": source.name}), source_totals))
        unpriced.update(r.get("unpriced") or [])
    start = datetime.fromtimestamp(since / 1000)
    day_list = []
    for offset in range(days):
        key = (start + timedelta(days=offset)).strftime("%Y-%m-%d")
        day_list.append(by_day.get(key) or _blank({"day": key}))

    def rank(item):
        return (-number(item.get("cost")), -number(item.get("output")))
    payload = {"ok": True, "days": day_list, "range": days, "since": since,
               "models": sorted(by_model.values(), key=rank), "projects": sorted(by_project.values(), key=rank)[:20],
               "sources": sorted(by_source, key=rank), "totals": totals, "unpriced": sorted(unpriced), "errors": errors,
               "generatedAt": int(time.time() * 1000)}
    if complete and not errors:
        _usage_cache[days] = (time.time(), payload)
    return payload


def today_cost(store):
    report = usage(store, 1)
    return number((report.get("totals") or {}).get("cost"))


# 订阅额度（5 小时 / 每周）：问每台在线电脑的 watcher（limits），按电脑分组（同 Mac 版 Limits.collect）
_limits_cache = [0.0, None]
_limits_last = {}   # 每台电脑最近一次的读数：来源断开时照样给出


def limits(store, fresh=False):
    if not fresh and _limits_cache[1] is not None and time.time() - _limits_cache[0] < 30:
        return _limits_cache[1]
    live = _live_sources(store)
    with store.lock:
        order = list(store.sources.values())
    # 旧版 watcher 不认这个命令：当这台电脑没有读数
    for source, r, error in _ask_all(live, {"cmd": "limits"}, 20):
        if error:
            continue
        agents = (r or {}).get("agents") or []
        if agents:
            _limits_last[source.id] = {"sourceId": source.id, "name": source.name, "local": source.kind == "local", "agents": agents}
        else:
            _limits_last.pop(source.id, None)
    # 电脑的顺序同设置里来源的顺序；暂时连不上的电脑给它最近一次的读数（卡片上写着是多久前的）
    payload = {"ok": True, "devices": [_limits_last[s.id] for s in order if s.id in _limits_last],
               "generatedAt": int(time.time() * 1000)}
    # 有来源还没连上（刚启动、断线重连中）：这次不缓存，连上后马上能拿到完整的
    if len(live) == len(order):
        _limits_cache[:] = [time.time(), payload]
    return payload
