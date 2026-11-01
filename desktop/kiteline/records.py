"""存在数据目录里的几样记录（对应 Mac 版 Todos / Inbox / Audit / VoiceStore / MediaCache）"""

import base64
import hashlib
import json
import os
import re
import threading
import time
import uuid

from . import config, log


def now_ms():
    return round(time.time() * 1000)


def short_id():
    return uuid.uuid4().hex[:8]


# MARK: - 待办

class Todos:
    ITEM_LIMIT, SUGGESTION_LIMIT, HANDLED_LIMIT, IMAGE_LIMIT = 500, 30, 2000, 9
    SUGGESTION_TTL = 7 * 86_400_000
    GUESSED_BEFORE = 1_793_030_400_000   # 2026-10-27 00:00（北京时间）

    def __init__(self, store, publish):
        self.sessions = store
        self.publish = publish
        self._lock = threading.RLock()
        self._file = config.path("todos.json")
        self.media_dir = config.path("todo-media")
        data = config.read_json(self._file, {})
        # suggestions：agent 提醒用户的事（只有用户能做的，问一句「现在处理 / 加入待办」）。
        # 10-27 之前从回复里猜出来的提示不再用了，清掉
        old = data.get("suggestions") or []
        kept = [s for s in old if s.get("at", 0) >= self.GUESSED_BEFORE]
        self._store = {"items": data.get("items", []), "suggestions": kept, "handled": data.get("handled", [])}
        # 10-27 中午之前记的 agent 待办没有编号，agent 没法关（todo done 要编号）：补上
        if self._number_agent_tasks() or len(kept) != len(old):
            self._write()
        # agent 的待办推给在线的 watcher（app 设置；同 Mac 版 Todos.pushToAgents）；上次推出去的内容，没变不重发
        self.push_agents = None
        self._pushed_agents = None

    @staticmethod
    def mark(key, item_id):
        return "%s|%s" % (key, item_id)

    @staticmethod
    def _agent_task(item):
        return bool(item.get("agent")) and not item.get("forUser")

    def _number_agent_tasks(self):
        """agent 的待办都要有编号（agent 凭它更新、关掉）：没有的补一个（取 id 前 6 位，撞了就随机）。返回 True = 补过"""
        with self._lock:
            used = {i.get("ref") for i in self._store["items"] if i.get("ref")}
            changed = False
            for item in self._store["items"]:
                if not self._agent_task(item) or item.get("ref"):
                    continue
                ref = "t-" + str(item.get("id") or "")[:6]
                while ref in used or not re.match(r"^t-[0-9a-f]{6}$", ref):
                    ref = "t-" + uuid.uuid4().hex[:6]
                used.add(ref)
                item["ref"] = ref
                item.setdefault("status", "done" if item.get("done") else "pending")
                changed = True
            return changed

    def agent_snapshot(self):
        """推给 watcher 的 agent 待办（todos 请求，同 Mac 版 Todos.agentSnapshot）：agent 用 todo list / done 看得到、接手、
        关掉别的会话或别的电脑上记的。没做完的全带上，做完的只带最近一周的；holder = 在处理的会话，没人接手就是记下它的会话"""
        cutoff = now_ms() - 7 * 86_400_000
        rows = []
        with self._lock:
            for item in self._store["items"]:
                if not self._agent_task(item) or not item.get("ref") or (item.get("done") and (item.get("doneAt") or 0) < cutoff):
                    continue
                row = {"ref": item["ref"], "text": item.get("text") or "", "at": item.get("updatedAt") or item.get("createdAt") or 0,
                       "status": "done" if item.get("done") else (item.get("status") or "pending")}
                if item.get("progress"):
                    row["progress"] = str(item["progress"])[:300]
                if not item.get("done") and item.get("detail"):
                    row["detail"] = str(item["detail"])[:1500]
                holder = item.get("handler") or item.get("source")
                if holder:
                    row["key"] = holder.get("key") or ""
                    row["title"] = holder.get("title") or ""
                    if holder.get("machine"):
                        row["machine"] = holder["machine"]
                rows.append(row)
        return rows

    def push_to_agents(self, only=None):
        """agent 的待办有变化就推给在线的 watcher（内容没变不重发）；only = 刚连上的那一个，不管上次推过什么都发一份"""
        if not self.push_agents:
            return
        items = self.agent_snapshot()
        if only is None:
            text = json.dumps(items, ensure_ascii=False, sort_keys=True)
            if text == self._pushed_agents:
                return
            self._pushed_agents = text
        self.push_agents(items, only)

    def payload(self):
        with self._lock:
            cutoff = now_ms() - self.SUGGESTION_TTL
            return {"ok": True, "items": [dict(i) for i in self._store["items"]],
                    "suggestions": [dict(s) for s in self._store["suggestions"] if s.get("at", 0) >= cutoff],
                    "handled": list(self._store["handled"])}

    def _known(self, ident):
        """这条消息处理过没有（加过、删过、忽略过、正在提示）"""
        with self._lock:
            return ident in self._store["handled"] or any(self.mark(s["key"], s["itemId"]) == ident for s in self._store["suggestions"]) \
                or any(i.get("source") and self.mark(i["source"]["key"], i["source"]["itemId"]) == ident for i in self._store["items"])

    def add_agent_task(self, key, item_id, text, detail, ref, ts):
        """agent 自己以后要做的事（对话里不带 forUser 的 agent_todo）：直接记进「agent 的待办」（同 Mac 版 Todos.addAgentTask）。
        返回 True = 新记的；这条加过、删过就不再加"""
        if self._known(self.mark(key, item_id)):
            return False
        source = self._source({"key": key, "itemId": item_id, "ts": ts})
        if not source:
            return False
        self._add([str(text)[:2000]], source, [], detail=str(detail or "")[:4000], agent=True, ref=ref or None)
        return True

    def suggest_for_user(self, key, item_id, title, machine, ts, text, detail):
        """只有用户能做的事（带 forUser 的 agent_todo）：先记成提示，各端问一句「现在处理 / 加入待办」（同 Mac 版 Todos.suggestForUser）。
        返回 True = 新的（要推送）"""
        if self._known(self.mark(key, item_id)):
            return False
        fresh = {"key": key, "itemId": item_id, "title": str(title or "会话")[:200], "asks": [str(text)[:2000]], "at": now_ms()}
        if machine:
            fresh["machine"] = machine
        if ts:
            fresh["ts"] = ts
        if detail:
            fresh["detail"] = str(detail)[:4000]
        with self._lock:
            cutoff = now_ms() - self.SUGGESTION_TTL
            suggestions = [s for s in self._store["suggestions"] if s.get("at", 0) >= cutoff] + [fresh]
            self._store["suggestions"] = suggestions[-self.SUGGESTION_LIMIT:]
        self._changed(fresh=fresh)
        return True

    def update_agent_task(self, ref, status, progress, key):
        """agent 更新自己的待办（todo start / progress / done）：按编号改状态、进度，记下是哪个会话在处理。返回那条的标题（找不到 None）"""
        handler = self._source({"key": key, "itemId": "-"}) or {"key": key, "title": "会话"}
        handler = {k: v for k, v in handler.items() if k in ("key", "title", "machine", "cwd", "agent")}
        with self._lock:
            item = next((i for i in reversed(self._store["items"]) if i.get("ref") == ref), None)
            if not item:
                return None
            item["status"] = status
            if progress:
                item["progress"] = str(progress)[:1000]
            item["handler"] = handler
            item["updatedAt"] = now_ms()
            done = status == "done"
            if bool(item.get("done")) != done:
                item["done"] = done
                if done:
                    item["doneAt"] = now_ms()
                else:
                    item.pop("doneAt", None)
            title = item["text"]
        self._changed()
        return title

    def handle(self, method, path, body, query):
        """返回 (状态码, 字典) 或 (状态码, (字节, mime))"""
        body = body or {}
        if method == "GET" and path == "/api/todos":
            return 200, self.payload()
        if method == "POST" and path == "/api/todos/add":
            texts = [str(t).strip() for t in body.get("texts") or [] if str(t).strip()]
            if not texts or len(texts) > 50:
                return 400, {"ok": False, "error": "没有可添加的内容"}
            images = self._save_images(body.get("images"), [])
            if images is None:
                return 400, {"ok": False, "error": "截图过多或无法打开（最多 %d 张）" % self.IMAGE_LIMIT}
            # 从提示加进来的（agent 提醒用户的那条）：说明跟着带上，算「我的待办」
            with self._lock:
                pending = next((dict(s) for s in self._store["suggestions"]
                                if s["key"] == body.get("key") and s["itemId"] == body.get("itemId")), None)
            detail = str(body.get("detail") or (pending or {}).get("detail") or "").strip()
            for_user = body.get("forUser") if body.get("forUser") is not None else pending is not None
            agent = body.get("agent") if body.get("agent") is not None else pending is not None
            self._add([t[:2000] for t in texts], self._source(body), images, detail=detail[:4000],
                      for_user=bool(for_user), agent=bool(agent))
            return 200, self.payload()
        if method == "POST" and path == "/api/todos/update":
            item_id = body.get("id")
            if not item_id:
                return 400, {"ok": False, "error": "缺少 id"}
            text = body.get("text")
            if text is not None:
                text = str(text).strip()
                if not text:
                    return 400, {"ok": False, "error": "内容不能为空"}
            images = None
            if "images" in body:
                current = (self._item(item_id) or {}).get("images") or []
                images = self._save_images(body.get("images"), current)
                if images is None:
                    return 400, {"ok": False, "error": "截图过多或无法打开（最多 %d 张）" % self.IMAGE_LIMIT}
            if not self._update(item_id, body.get("done"), text[:2000] if text else None, images):
                return 404, {"ok": False, "error": "该待办已不存在"}
            return 200, self.payload()
        if method == "GET" and path == "/api/todos/media":
            ref = query.get("ref", "")
            if not re.match(r"^[a-f0-9]{16}\.(jpg|png)$", ref):
                return 404, {"ok": False, "error": "图片不存在"}
            try:
                with open(os.path.join(self.media_dir, ref), "rb") as handle:
                    return 200, (handle.read(), "image/png" if ref.endswith(".png") else "image/jpeg")
            except OSError:
                return 404, {"ok": False, "error": "图片不存在"}
        if method == "POST" and path == "/api/todos/delete":
            ids = set(body.get("ids") or ([body["id"]] if body.get("id") else []))
            if not ids:
                return 400, {"ok": False, "error": "缺少 id"}
            with self._lock:
                self._drop_images([i for i in self._store["items"] if i["id"] in ids])
                self._store["items"] = [i for i in self._store["items"] if i["id"] not in ids]
            self._changed()
            return 200, self.payload()
        if method == "POST" and path == "/api/todos/dismiss":
            # 「全部忽略」：items 是手机上当时列着的那几条（只忽略看得见的，刚冒出来的新提示不跟着丢）
            if isinstance(body.get("items"), list):
                marks = {self.mark(e["key"], e["itemId"]) for e in body["items"]
                         if isinstance(e, dict) and isinstance(e.get("key"), str) and isinstance(e.get("itemId"), str)}
                with self._lock:
                    self._store["suggestions"] = [s for s in self._store["suggestions"]
                                                  if self.mark(s["key"], s["itemId"]) not in marks]
                    for mark in marks:
                        self._remember(mark)
                self._changed()
                return 200, self.payload()
            key, item_id = body.get("key"), body.get("itemId")
            if not key or not item_id:
                return 400, {"ok": False, "error": "缺少 key、itemId"}
            with self._lock:
                self._store["suggestions"] = [s for s in self._store["suggestions"]
                                              if not (s["key"] == key and s["itemId"] == item_id)]
                self._remember(self.mark(key, item_id))
            self._changed()
            return 200, self.payload()
        if method == "POST" and path == "/api/todos/clear-done":
            with self._lock:
                self._drop_images([i for i in self._store["items"] if i.get("done")])
                self._store["items"] = [i for i in self._store["items"] if not i.get("done")]
            self._changed()
            return 200, self.payload()
        return 404, {"ok": False, "error": "未知的待办接口"}

    def _source(self, body):
        key, item_id = body.get("key"), body.get("itemId")
        if not key or not item_id:
            return None
        title = body.get("title") or ""
        machine = None
        record = self.sessions.record(key)
        if record:
            title = record.snap.get("title") or record.snap.get("name") or title
            machine = record.source_name
        elif "#" in key:
            source = self.sessions.source(key.split("#", 1)[0])
            machine = source.name if source else None
        with self._lock:
            pending = next((s for s in self._store["suggestions"] if s["key"] == key and s["itemId"] == item_id), None)
        if not title:
            title = (pending or {}).get("title") or "会话"
        out = {"key": key, "itemId": item_id, "title": title[:200]}
        machine = machine or (pending or {}).get("machine")
        if machine:
            out["machine"] = machine
        ts = body.get("ts") or (pending or {}).get("ts")
        if ts:
            out["ts"] = ts
        # 会话的项目目录、哪个 agent：agent 的待办按项目、按 Agent 分组用，会话结束了也分得出来
        if record and record.snap.get("cwd"):
            out["cwd"] = record.snap["cwd"]
            out["agent"] = record.snap.get("agent") or "claude-code"
        return out

    def fill_session_meta(self):
        """早先记的 agent 待办（没有项目目录、agent）：会话还在的从会话补上（同 Mac 版 Todos.fillSessionMeta）。
        会话列表每次更新时调；都补齐了就什么也不做"""
        with self._lock:
            lacking = [i for i in self._store["items"] if self._agent_task(i) and not (i.get("handler") or i.get("source") or {"cwd": 1}).get("cwd")]
            if not lacking:
                return
            filled = False
            for item in lacking:
                for field in ("source", "handler"):
                    holder = item.get(field)
                    record = holder and not holder.get("cwd") and self.sessions.record(holder.get("key"))
                    if record and record.snap.get("cwd"):
                        holder["cwd"] = record.snap["cwd"]
                        holder.setdefault("agent", record.snap.get("agent") or "claude-code")
                        filled = True
        if filled:
            self._changed()

    def _add(self, texts, source, images, detail="", for_user=False, agent=False, ref=None):
        with self._lock:
            stamp = now_ms()
            for index, text in enumerate(texts):
                if source and any(i["text"] == text and (i.get("source") or {}).get("key") == source["key"]
                                  and (i.get("source") or {}).get("itemId") == source["itemId"] for i in self._store["items"]):
                    continue
                item = {"id": short_id(), "text": text, "done": False, "createdAt": stamp + index}
                if source:
                    item["source"] = source
                if index == 0 and images:
                    item["images"] = images
                # 说明、要你自己做的、agent 记的（同 Mac 版 Todos.Item）：说明跟着第一条
                if index == 0 and detail:
                    item["detail"] = detail
                if index == 0 and for_user:
                    item["forUser"] = True
                if agent:
                    item["agent"] = True
                # agent 自己的待办：编号（它用编号更新进度），状态从「待处理」开始（同 Mac 版）
                if index == 0 and ref:
                    item["ref"] = ref
                    item["status"] = "pending"
                self._store["items"].append(item)
            overflow = len(self._store["items"]) - self.ITEM_LIMIT
            if overflow > 0:
                done = sorted([i for i in self._store["items"] if i.get("done")], key=lambda i: i.get("doneAt") or 0)[:overflow]
                ids = {i["id"] for i in done}
                self._drop_images(done)
                self._store["items"] = [i for i in self._store["items"] if i["id"] not in ids]
                extra = len(self._store["items"]) - self.ITEM_LIMIT
                if extra > 0:
                    self._drop_images(self._store["items"][:extra])
                    self._store["items"] = self._store["items"][extra:]
            if source:
                self._store["suggestions"] = [s for s in self._store["suggestions"]
                                              if not (s["key"] == source["key"] and s["itemId"] == source["itemId"])]
                self._remember(self.mark(source["key"], source["itemId"]))
        self._number_agent_tasks()
        self._changed()

    def _update(self, item_id, done, text, images):
        with self._lock:
            item = next((i for i in self._store["items"] if i["id"] == item_id), None)
            if not item:
                return False
            if done is not None and bool(item.get("done")) != bool(done):
                item["done"] = bool(done)
                if done:
                    item["doneAt"] = now_ms()
                else:
                    item.pop("doneAt", None)
                if self._agent_task(item):
                    # 用户替 agent 勾掉 / 恢复：状态跟着变，agent 那边 todo list 也就对得上
                    item["status"] = "done" if done else "pending"
                    item["updatedAt"] = now_ms()
            if text:
                item["text"] = text
            if images is not None:
                kept = {i["ref"] for i in images}
                for old in item.get("images") or []:
                    if old["ref"] not in kept:
                        try:
                            os.remove(os.path.join(self.media_dir, old["ref"]))
                        except OSError:
                            pass
                if images:
                    item["images"] = images
                else:
                    item.pop("images", None)
        self._changed()
        return True

    def _item(self, item_id):
        with self._lock:
            return next((dict(i) for i in self._store["items"] if i["id"] == item_id), None)

    def _save_images(self, raw, current):
        entries = raw or []
        if len(entries) > self.IMAGE_LIMIT:
            return None
        result = []
        for entry in entries:
            if entry.get("ref"):
                old = next((c for c in current if c["ref"] == entry["ref"]), None)
                if old:
                    result.append(old)
                continue
            try:
                data = base64.b64decode(entry.get("data") or "", validate=False)
            except (ValueError, TypeError):
                return None
            if not (8 < len(data) < 15_000_000):
                return None
            png = data.startswith(b"\x89PNG")
            if not png and not data.startswith(b"\xff\xd8"):
                return None
            ref = uuid.uuid4().hex[:16] + (".png" if png else ".jpg")
            os.makedirs(self.media_dir, exist_ok=True)
            config.write_private(os.path.join(self.media_dir, ref), data)
            result.append({"ref": ref, "mime": "image/png" if png else "image/jpeg"})
        return result

    def _drop_images(self, items):
        for item in items:
            for image in item.get("images") or []:
                try:
                    os.remove(os.path.join(self.media_dir, image["ref"]))
                except OSError:
                    pass

    def _remember(self, mark):
        handled = self._store["handled"]
        if mark not in handled:
            handled.append(mark)
            del handled[:-self.HANDLED_LIMIT]

    def _write(self):
        with self._lock:
            text = json.dumps(self._store, ensure_ascii=False)
        config.write_private(self._file, text)

    def _changed(self, fresh=None):
        self._write()
        payload = self.payload()
        if fresh:
            payload["fresh"] = fresh
        self.publish("todos", payload)
        self.push_to_agents()


# MARK: - 收藏

class Favorites:
    """我的收藏（同 Mac 版 Favorites.swift）：对话里收藏的消息，存文字和图片的一份快照（会话结束、记录清掉也还在）。
    存数据目录 favorites.json，图存 favorite-media/；有变化就推 favorites 事件（整份）"""
    ITEM_LIMIT, IMAGE_LIMIT, TEXT_LIMIT = 2000, 9, 100_000

    def __init__(self, store, publish):
        self.sessions = store
        self.publish = publish
        self._lock = threading.RLock()
        self._file = config.path("favorites.json")
        self.media_dir = config.path("favorite-media")
        self._items = config.read_json(self._file, {}).get("items", [])

    def payload(self):
        with self._lock:
            return {"ok": True, "items": [dict(i) for i in sorted(self._items, key=lambda i: i.get("at", 0), reverse=True)]}

    def handle(self, method, path, body, query):
        """返回 (状态码, 字典) 或 (状态码, (字节, mime))"""
        body = body or {}
        if method == "GET" and path == "/api/favorites":
            return 200, self.payload()
        if method == "POST" and path == "/api/favorites/add":
            key, item_id = body.get("key"), body.get("itemId")
            if not key or not item_id:
                return 400, {"ok": False, "error": "缺少 key、itemId"}
            text = str(body.get("text") or "").strip()
            raw = body.get("images") or []
            if not text and not raw:
                return 400, {"ok": False, "error": "这条消息没有可收藏的内容"}
            with self._lock:
                if any(i["key"] == key and i["itemId"] == item_id for i in self._items):
                    return 200, self.payload()
            images = self._save_images(raw)
            if images is None:
                return 400, {"ok": False, "error": "图片过多或无法打开（最多 %d 张）" % self.IMAGE_LIMIT}
            item = {"id": short_id(), "key": key, "itemId": item_id, "who": "me" if body.get("who") == "me" else "bot", "at": now_ms()}
            title = body.get("title") or ""
            record = self.sessions.record(key)
            if record:
                title = record.snap.get("title") or record.snap.get("name") or title
                item["machine"] = record.source_name
            elif "#" in key:
                source = self.sessions.source(key.split("#", 1)[0])
                if source:
                    item["machine"] = source.name
            item["title"] = (title or "会话")[:200]
            for field, limit in (("speaker", 60), ("agent", 60)):
                if body.get(field):
                    item[field] = str(body[field])[:limit]
            if isinstance(body.get("ts"), (int, float)):
                item["ts"] = body["ts"]
            if text:
                item["text"] = text[:self.TEXT_LIMIT]
            if images:
                item["images"] = images
            with self._lock:
                if not any(i["key"] == key and i["itemId"] == item_id for i in self._items):
                    self._items.append(item)
                    if len(self._items) > self.ITEM_LIMIT:
                        self._items.sort(key=lambda i: i.get("at", 0))
                        self._drop_images(self._items[:-self.ITEM_LIMIT])
                        del self._items[:-self.ITEM_LIMIT]
            self._changed()
            return 200, self.payload()
        if method == "POST" and path == "/api/favorites/delete":
            ids = set(body.get("ids") or ([body["id"]] if body.get("id") else []))
            key, item_id = body.get("key"), body.get("itemId")
            if not ids and not (key and item_id):
                return 400, {"ok": False, "error": "缺少 id"}
            gone = lambda i: i["id"] in ids or (i["key"] == key and i["itemId"] == item_id)
            with self._lock:
                self._drop_images([i for i in self._items if gone(i)])
                self._items = [i for i in self._items if not gone(i)]
            self._changed()
            return 200, self.payload()
        if method == "GET" and path == "/api/favorites/media":
            ref = query.get("ref", "")
            if not re.match(r"^[a-f0-9]{16}\.(jpg|png)$", ref):
                return 404, {"ok": False, "error": "图片不存在"}
            try:
                with open(os.path.join(self.media_dir, ref), "rb") as handle:
                    return 200, (handle.read(), "image/png" if ref.endswith(".png") else "image/jpeg")
            except OSError:
                return 404, {"ok": False, "error": "图片不存在"}
        return 404, {"ok": False, "error": "未知的收藏接口"}

    def _save_images(self, raw):
        """消息里的图（base64，各端从 /api/media 取来原图再传过来）存成文件。None = 太多或打不开"""
        if not isinstance(raw, list) or len(raw) > self.IMAGE_LIMIT:
            return None
        result = []
        for entry in raw:
            try:
                data = base64.b64decode((entry or {}).get("data") or "", validate=True)
            except (ValueError, TypeError):
                return None
            if len(data) <= 8 or len(data) >= 15_000_000:
                return None
            png = data.startswith(b"\x89PNG")
            if not png and not data.startswith(b"\xff\xd8"):
                return None
            ref = uuid.uuid4().hex[:16] + (".png" if png else ".jpg")
            os.makedirs(self.media_dir, exist_ok=True)
            config.write_private(os.path.join(self.media_dir, ref), data)
            result.append({"ref": ref, "mime": "image/png" if png else "image/jpeg"})
        return result

    def _drop_images(self, items):
        for item in items:
            for image in item.get("images") or []:
                try:
                    os.remove(os.path.join(self.media_dir, image["ref"]))
                except OSError:
                    pass

    def _changed(self):
        with self._lock:
            text = json.dumps({"items": self._items}, ensure_ascii=False)
        config.write_private(self._file, text)
        self.publish("favorites", self.payload())


# MARK: - 通知收件箱

class Inbox:
    LIMIT = 300

    def __init__(self):
        self._lock = threading.Lock()
        self._file = config.path("inbox.json")
        data = config.read_json(self._file, [])
        self._entries = data if isinstance(data, list) else []

    def add(self, kind, title, body, key, route, delivery, english=None):
        entry = {"id": short_id(), "ts": now_ms(), "kind": kind, "title": title[:200], "body": body[:600], "delivery": delivery}
        if english:   # 英文版（日报这类在源头按语言拼好的）：出口给英文设备换上（i18n.localize）
            entry["titleEn"], entry["bodyEn"] = english[0][:200], english[1][:600]
        if key:
            entry["key"] = key
        if route:
            entry["route"] = route
        with self._lock:
            self._entries.append(entry)
            del self._entries[:-self.LIMIT]
            text = json.dumps(self._entries, ensure_ascii=False)
        config.write_private(self._file, text)
        return entry

    def recent(self, limit, since=0):
        with self._lock:
            return [dict(e) for e in reversed(self._entries) if e["ts"] > since][:limit]


# MARK: - 操作记录

AUDIT_ACTIONS = {
    "/api/send": "发送消息", "/api/key": "按键", "/api/answer": "回答提问", "/api/voice": "语音", "/api/close": "关闭会话",
    "/api/new-session": "新任务", "/api/resume": "恢复会话", "/api/quick-replies": "修改快捷短语",
    "/api/digest/push": "推送日报", "/api/push/subscribe": "开启推送", "/api/readiness/fix": "一键安装组件", "/api/push/unsubscribe": "关闭推送",
    "/api/push/test": "测试推送", "/api/budget": "修改花费提醒 / 上限", "/pair": "配对",
    "/api/devices/register": "登记设备", "/api/devices/revoke": "停用设备", "/api/devices/rename": "修改设备名称",
    "/api/schedules": "新建定时任务", "/api/schedules/update": "启用 / 停用定时任务", "/api/schedules/delete": "删除定时任务",
    "/api/schedules/run": "立即运行定时任务", "/api/morning/push": "推送早安简报",
    "/api/quiet": "修改免打扰时段", "/api/mute": "静音 / 取消静音会话", "/api/pin": "置顶 / 取消置顶会话", "/api/mark": "标记 / 取消标记会话",
    "/api/bark": "修改 Bark 推送", "/api/bark/test": "测试 Bark 推送", "/api/profile": "修改头像 / 名字", "/api/agent-face": "修改 Agent 头像 / 昵称",
    "/api/p2p/join": "开通远程访问", "/api/watch": "修改手表设置", "/api/term": "打开 / 关闭终端",
}
KEY_NAMES = {"1": "允许", "2": "总是允许", "3": "选项 3", "esc": "拒绝 / 中断", "enter": "确认"}


class Audit:
    def __init__(self):
        self._lock = threading.Lock()
        self._file = config.path("audit.jsonl")

    def record(self, request, status, reply, client, target):
        if not (request.method == "POST" or request.path == "/pair"):
            return
        action = AUDIT_ACTIONS.get(request.path)
        if not action:
            return
        # 终端只记开、关：按键不记（会记下 sudo 密码这类东西），读输出、改大小太多（同 Mac）
        if request.path == "/api/term" and (request.json or {}).get("op") not in ("open", "close"):
            return
        ok = 200 <= status < 300 and reply.get("ok") is not False
        entry = {"ts": now_ms(), "action": action, "ok": ok, "client": client}
        message = reply.get("error") or reply.get("message")
        if message and message != "dry-run":
            entry["message"] = str(message)[:120]
        if status == 401:
            entry["message"] = "未配对的请求被拒绝"
        if target:
            entry["target"] = target
        detail = self._detail(request, reply)
        if detail:
            entry["detail"] = detail
        self.append(entry)

    def note(self, action, detail):
        self.append({"ts": now_ms(), "action": action, "ok": True, "client": "Kiteline", "detail": detail})

    def _detail(self, request, reply):
        body = None if request.path == "/api/voice" else (request.json or {})
        if request.path in ("/api/send", "/api/answer", "/api/new-session", "/api/resume"):
            if reply.get("capExceeded"):
                return "超出每日花费上限，已拦截"
            text = str(body.get("text") or "").replace("\n", " ")
            images = len(body.get("images") or [])
            if len(text) > 80:
                text = text[:80] + "…"
            if images:
                text += "（%d 张图）" % images if not text else "（附 %d 张图）" % images
            # 手机发来的文件（PDF、Excel……）：记下文件名
            files = [str(f.get("name") or "") for f in body.get("files") or [] if isinstance(f, dict)]
            if files:
                names = "、".join(files[:2]) + (" 等 %d 个" % len(files) if len(files) > 2 else "")
                text += "（文件 %s）" % names if not text else "（附文件 %s）" % names
            if reply.get("branch"):
                text += "（独立分支 %s）" % reply["branch"]
            return text or None
        if request.path == "/api/key":
            key = body.get("key", "")
            return KEY_NAMES.get(key, key)
        if request.path == "/api/term":
            return "打开终端" if body.get("op") == "open" else "关闭终端"
        if request.path == "/api/voice" and reply.get("text"):
            return "“%s”" % reply["text"][:60]
        if request.path == "/api/quick-replies" and isinstance(reply.get("items"), list):
            return "%d 条" % len(reply["items"])
        return None

    def append(self, entry):
        line = json.dumps(entry, ensure_ascii=False) + "\n"
        with self._lock:
            os.makedirs(os.path.dirname(self._file), exist_ok=True)
            with open(self._file, "a", encoding="utf-8") as handle:
                handle.write(line)
            try:
                if os.path.getsize(self._file) > 1_500_000:
                    with open(self._file, encoding="utf-8") as handle:
                        lines = handle.read().splitlines()
                    if len(lines) > 4000:
                        config.write_private(self._file, "\n".join(lines[-3000:]) + "\n")
            except OSError:
                pass

    def recent(self, limit=200):
        with self._lock:
            try:
                with open(self._file, encoding="utf-8") as handle:
                    lines = handle.read().splitlines()
            except OSError:
                return []
        out = []
        for line in reversed(lines[-max(1, limit):]):
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
        return out


# MARK: - 语音

class VoiceStore:
    def __init__(self):
        self._lock = threading.Lock()
        self.directory = config.path("voice")
        self._index = os.path.join(self.directory, "index.json")
        data = config.read_json(self._index, [])
        self._entries = data if isinstance(data, list) else []
        self._prune()

    def save_audio(self, data, mime):
        os.makedirs(self.directory, exist_ok=True)
        ext = "wav" if "wav" in mime else ("m4a" if any(k in mime for k in ("mp4", "m4a", "aac")) else
                                          ("webm" if "webm" in mime else "audio"))
        path = os.path.join(self.directory, "%s.%s" % (uuid.uuid4().hex, ext))
        with open(path, "wb") as handle:
            handle.write(data)
        return path

    def record(self, key, text, duration, path, mime):
        entry = {"id": uuid.uuid4().hex, "key": key, "text": text, "duration": duration, "ts": time.time(),
                 "file": os.path.basename(path), "mime": mime}
        with self._lock:
            self._entries.append(entry)
        self._save()
        return entry

    def list(self, key):
        with self._lock:
            return [dict(e) for e in self._entries if e["key"] == key]

    def entry(self, entry_id):
        with self._lock:
            return next((dict(e) for e in self._entries if e["id"] == entry_id), None)

    def file_path(self, entry):
        return os.path.join(self.directory, entry["file"])

    def _save(self):
        with self._lock:
            text = json.dumps(self._entries, ensure_ascii=False)
        os.makedirs(self.directory, exist_ok=True)
        config.write_private(self._index, text)

    def _prune(self):
        cutoff = time.time() - 30 * 86400
        expired = [e for e in self._entries if e["ts"] < cutoff]
        if not expired:
            return
        for entry in expired:
            try:
                os.remove(self.file_path(entry))
            except OSError:
                pass
        self._entries = [e for e in self._entries if e["ts"] >= cutoff]
        self._save()


# MARK: - 图片缓存

class MediaCache:
    def __init__(self):
        self.directory = config.path("media-cache")

    def _name(self, key):
        return os.path.join(self.directory, hashlib.sha256(key.encode("utf-8")).hexdigest())

    def load(self, key):
        base = self._name(key)
        try:
            with open(base, "rb") as handle:
                data = handle.read()
            with open(base + ".mime", encoding="utf-8") as handle:
                mime = handle.read()
        except OSError:
            return None
        try:
            os.utime(base)   # 记下最近用过：prune 按修改时间清（Linux 常用 noatime / relatime，访问时间不可靠）
        except OSError:
            pass
        return data, mime

    def store(self, key, data, mime):
        os.makedirs(self.directory, exist_ok=True)
        base = self._name(key)
        config.write_private(base, data)
        config.write_private(base + ".mime", mime)

    def prune(self, days=14):
        """启动时清掉 14 天没用过的缓存（同 Mac 版）：不清的话手机看过的图会一直堆在磁盘上"""
        cutoff = time.time() - days * 86400
        try:
            names = os.listdir(self.directory)
        except OSError:
            return
        removed = 0
        for name in names:
            if name.endswith(".mime"):
                if name[:-5] not in names:   # 图已经没了，留下的类型文件也删
                    try:
                        os.remove(os.path.join(self.directory, name))
                    except OSError:
                        pass
                continue
            base = os.path.join(self.directory, name)
            try:
                if os.path.getmtime(base) >= cutoff:
                    continue
                os.remove(base)
                removed += 1
            except OSError:
                continue
            try:
                os.remove(base + ".mime")
            except OSError:
                pass
        if removed:
            log.write("清理图片缓存：%d 张 %d 天未用" % (removed, days))
