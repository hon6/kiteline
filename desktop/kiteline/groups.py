"""会话群（同 Mac 版 Sources/Groups.swift）：用户把几个会话（可以在不同电脑、不同项目里）拉进一个群，它们经 Kiteline 互相发消息协作。

- agent 用 watcher 的 group say 发言（对话里 t=group_say），这里转给群里其他会话：在跑的直接投递（同手机发消息），
  关了的先记着，用户在群里发话时恢复它（同「历史会话 → 恢复」），连同它没看到的群消息一起送进去。
- 第一次给某个成员投递时带群说明；群名先拿要协作的事 / 成员标题凑，第一个用 --name 的 agent 起正式名字（用户改过就不换）。
- agent 之间连着往来太多条（用户没插话）自动暂停转发，等用户点继续。
存数据目录 groups.json；有变化推 groups（各群概要）、group_msg（一条新消息或投递状态变了），也推给各台电脑的 watcher。
"""

import base64
import json
import os
import queue
import re
import shutil
import threading
import time
import uuid

from . import config, delivery, log
from .records import now_ms, short_id
from .store import display_title

GROUP_LIMIT = 200
MESSAGE_LIMIT = 500
TEXT_LIMIT = 8000
STREAK_LIMIT = 30          # 用户不插话时 agent 之间最多连着转发几条
WAIT_LIMIT = 15 * 60       # 等确认的会话最多等多久再投（之后算投递失败）
PUSH_GAP = 120             # agent 在群里发言的推送：同一个群隔这么久才再推一条（往来密的时候不刷屏）
DEFAULT_COMMAND = "python3 ~/.ccpulse/ccpulse-watch.py"
MEDIA_LIMIT = 6                       # 一条群消息最多带几张图 / 几个文件（同手机给会话发）
FILE_SIZE_LIMIT = 25 * 1024 * 1024
_REF = re.compile(r"^[a-f0-9]{16}(\.[a-z0-9]{1,8})?$")
_MIMES = {"jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "heic": "image/heic", "webp": "image/webp",
          "pdf": "application/pdf", "txt": "text/plain; charset=utf-8", "md": "text/plain; charset=utf-8",
          "log": "text/plain; charset=utf-8", "csv": "text/plain; charset=utf-8"}


def _mime(ref):
    return _MIMES.get(ref.rsplit(".", 1)[-1].lower() if "." in ref else "", "application/octet-stream")


def _new_id(prefix):
    return prefix + short_id()[:6]


def _project(cwd):
    return cwd.replace("\\", "/").rstrip("/").rsplit("/", 1)[-1] if cwd else None


class Groups:
    def __init__(self, app):
        self.app = app
        self._lock = threading.RLock()
        self._file = config.path("groups.json")
        self._groups = config.read_json(self._file, {}).get("groups", [])
        self.commands = {}          # 来源 id → agent 调 watcher 的写法（hello 带来）
        self._jobs = queue.Queue()  # (群, 消息, 收件成员, 进队时间)：一条一条投（投递要占前台、按键）
        self._live = set()
        self._pushed = None
        self._last_push = {}        # 群 id → 上次推送的时间
        for group in self._groups:
            for message in group.get("messages", []):
                for key, state in (message.get("states") or {}).items():
                    if state == "pending":
                        self._jobs.put((group["id"], message["id"], key, time.time()))
        threading.Thread(target=self._worker, name="groups-delivery", daemon=True).start()

    # MARK: 接口

    def _media_dir(self, gid):
        return config.path("group-media", gid)

    def handle(self, method, path, body, query):
        """/api/groups…：返回 (状态码, 字典)；群里的图、文件返回 (状态码, (数据, 类型))"""
        body = body or {}
        # 取群里的图也认 key=@group:<群 id>（各端取图的写法同对话里的图 /api/media?key=&ref=）
        key = query.get("key") or ""
        gid = body.get("id") or query.get("id") or (key[len("@group:"):] if key.startswith("@group:") else "")
        if method == "GET" and path == "/api/groups":
            return 200, self.summary_payload()
        if method == "GET" and path == "/api/groups/messages":
            group = self._group(gid)
            if not group:
                return 404, {"ok": False, "error": "会话群不存在"}
            return 200, {"ok": True, "id": gid, "items": [dict(m) for m in group["messages"]]}
        if method == "GET" and path == "/api/groups/media":
            # 群消息里的图（带 thumb 时给方形缩略图，见 server.thumb_reply）、文件
            ref = query.get("ref", "")
            if not self._group(gid) or not _REF.match(ref):
                return 404, {"ok": False, "error": "文件不存在"}
            try:
                with open(os.path.join(self._media_dir(gid), ref), "rb") as handle:
                    return 200, (handle.read(), _mime(ref))
            except OSError:
                return 404, {"ok": False, "error": "文件不存在"}
        if method != "POST":
            return 404, {"ok": False, "error": "未知的会话群接口"}
        if path == "/api/groups/create":
            keys = self._keys(body.get("keys"))
            if len(keys) < 2:
                return 400, {"ok": False, "error": "至少选两个会话"}
            group = self._create(keys, str(body.get("topic") or "").strip())
            return 200, {"ok": True, "group": self._summary(group)}
        if not self._group(gid):
            return 404, {"ok": False, "error": "会话群不存在"}
        if path == "/api/groups/add":
            keys = self._keys(body.get("keys"))
            if not keys:
                return 400, {"ok": False, "error": "没有选会话"}
            self._add(gid, keys)
        elif path == "/api/groups/remove":
            self._remove(gid, str(body.get("key") or ""))
        elif path == "/api/groups/rename":
            name = str(body.get("name") or "").strip()
            if not name:
                return 400, {"ok": False, "error": "群名不能为空"}
            self._rename(gid, name[:40])
        elif path == "/api/groups/pause":
            self._set_paused(gid, body.get("paused", True) is not False)
        elif path in ("/api/groups/mark", "/api/groups/mute"):
            # 标记（列表里排最上面、群名前一颗星）、免打扰（agent 发言不推送；转发自动暂停这种要你决定的照推）：同会话
            field = "marked" if path.endswith("/mark") else "muted"
            with self._lock:
                self._group(gid)[field] = body.get(field, True) is not False
            self._changed()
        elif path == "/api/groups/delete":
            with self._lock:
                self._groups = [g for g in self._groups if g["id"] != gid]
            self._changed()
            shutil.rmtree(self._media_dir(gid), ignore_errors=True)
            return 200, self.summary_payload()
        elif path == "/api/groups/send":
            text = str(body.get("text") or "").strip()
            attachments = delivery.attachments_of(body)
            if not text and not attachments:
                return 400, {"ok": False, "error": "内容为空"}
            if sum(1 for a in attachments if not a["file"]) > MEDIA_LIMIT or sum(1 for a in attachments if a["file"]) > MEDIA_LIMIT:
                return 400, {"ok": False, "error": "一次最多发送 %d 张图片、%d 个文件" % (MEDIA_LIMIT, MEDIA_LIMIT)}
            try:
                saved = self._store_media(gid, attachments)
            except ValueError as exc:
                return 400, {"ok": False, "error": str(exc)}
            except OSError:
                return 500, {"ok": False, "error": "图片或文件保存失败"}
            to = self._keys(body.get("to"))
            message = self._user_says(gid, text[:TEXT_LIMIT], to or None,
                                      [m for m, f in saved if not f], [m for m, f in saved if f])
            return 200, {"ok": True, "message": message}
        else:
            return 404, {"ok": False, "error": "未知的会话群接口"}
        group = self._group(gid)
        return 200, {"ok": True, "group": self._summary(group) if group else None}

    def _store_media(self, gid, attachments):
        """随群消息发来的图、文件存进这个群的目录：名字换成随机的（保留扩展名），原名记在消息里。返回 [(媒体, 是不是文件)]"""
        decoded = []
        for item in attachments:
            try:
                data = base64.b64decode(item["data"])
            except (ValueError, TypeError):
                raise ValueError("图片或文件数据损坏")
            if len(data) > FILE_SIZE_LIMIT:
                raise ValueError("「%s」超过 25 MB，无法发送" % item["name"])
            decoded.append((item, data))
        saved = []
        for item, data in decoded:
            name = os.path.basename(str(item["name"]).replace("\\", "/")) or "file"
            ext = "".join(c for c in os.path.splitext(name)[1].lower() if c.isalnum())[:8]
            ref = uuid.uuid4().hex[:16] + ("." + ext if ext else "")
            config.write_private(os.path.join(self._media_dir(gid), ref), data)
            saved.append(({"ref": ref, "name": name[:120], "size": len(data)}, item["file"]))
        return saved

    def _attachments(self, gid, messages):
        """投递时随群消息带上的图、文件（读回存着的数据，格式同 delivery.attachments_of；读不到的跳过）"""
        out = []
        for message in messages:
            for field, is_file in (("images", False), ("files", True)):
                for media in message.get(field) or []:
                    try:
                        with open(os.path.join(self._media_dir(gid), media["ref"]), "rb") as handle:
                            out.append({"name": media["name"], "data": base64.b64encode(handle.read()).decode(), "file": is_file})
                    except OSError:
                        pass
        return out

    @staticmethod
    def _keys(raw):
        seen, out = set(), []
        for key in raw if isinstance(raw, list) else []:
            if isinstance(key, str) and "#" in key and key not in seen:
                seen.add(key)
                out.append(key)
        return out

    # MARK: 建群、加人、改名

    def _member(self, key):
        record = self.app.store.record(key)
        source = self.app.store.source(key.split("#", 1)[0])
        cwd = record.snap.get("cwd") if record else None
        return {"key": key, "title": (display_title(record.snap) if record else "会话")[:80],
                "machine": record.source_name if record else (source.name if source else None),
                "project": _project(cwd), "cwd": cwd, "agent": (record.snap.get("agent") or "claude-code") if record else None,
                "joinedAt": now_ms(), "briefed": False}

    @staticmethod
    def _provisional(members, topic):
        """临时群名：写了要协作的事就取它的第一句，否则拿成员标题凑"""
        first = ""
        for part in re.split(r"[\n。！？!?；;，,]", topic or ""):
            if part.strip():
                first = part.strip()
                break
        if first:
            return first[:14] + "…" if len(first) > 14 else first
        return "、".join((m["title"][:8] + "…") if len(m["title"]) > 8 else m["title"] for m in members[:3])

    @staticmethod
    def _event(text, code=None, args=None):
        message = {"id": _new_id("m-"), "ts": now_ms(), "from": "system", "fromTitle": "", "text": text}
        if code:
            message["event"] = code
        if args:
            message["args"] = list(args)
        return message

    def _create(self, keys, topic):
        members = [self._member(k) for k in keys]
        at = now_ms()
        group = {"id": _new_id("g-"), "name": self._provisional(members, topic), "autoName": True, "createdAt": at, "updatedAt": at,
                 "members": members, "messages": [self._event("建群：" + "、".join(m["title"] for m in members), "created", [m["title"] for m in members])]}
        if topic:
            group["topic"] = topic[:2000]
        with self._lock:
            self._groups.append(group)
            if len(self._groups) > GROUP_LIMIT:
                self._groups = sorted(self._groups, key=lambda g: g["updatedAt"], reverse=True)[:GROUP_LIMIT]
        log.write("会话群「%s」：%s" % (group["name"], "、".join("%s（%s）" % (m["title"], m.get("machine") or "?") for m in members)))
        self._changed()
        self._fill_ended(group["id"])
        if topic:
            self._user_says(group["id"], topic, None)
        return self._group(group["id"]) or group

    def _add(self, gid, keys):
        with self._lock:
            group = self._group(gid)
            have = {m["key"] for m in group["members"]}
            fresh = [self._member(k) for k in keys if k not in have]
            if not fresh:
                return
            group["members"] += fresh
            self._append(group, self._event("加入群：" + "、".join(m["title"] for m in fresh), "joined", [m["title"] for m in fresh]))
        self._changed()
        self._fill_ended(gid)

    def _remove(self, gid, key):
        with self._lock:
            group = self._group(gid)
            member = next((m for m in group["members"] if m["key"] == key), None)
            if not member:
                return
            group["members"] = [m for m in group["members"] if m["key"] != key]
            self._append(group, self._event("移出群：%s" % member["title"], "left", [member["title"]]))
        self._changed()

    def _rename(self, gid, name):
        with self._lock:
            group = self._group(gid)
            if group["name"] == name:
                return
            group["name"], group["autoName"] = name, False
            self._append(group, self._event("群名改为「%s」" % name, "renamed", [name]))
        self._changed()

    def _set_paused(self, gid, paused):
        with self._lock:
            group = self._group(gid)
            if bool(group.get("paused")) == paused:
                return
            group["paused"] = paused
            if not paused:
                group["streak"] = 0
                # 暂停时记下没转的：现在接着投
                for message in group["messages"]:
                    for key, state in list((message.get("states") or {}).items()):
                        if state == "paused":
                            message["states"][key] = "pending"
                            self._jobs.put((gid, message["id"], key, time.time()))
            self._append(group, self._event("已暂停转发", "paused") if paused else self._event("已继续转发", "resumed"))
        self._changed()

    def _fill_ended(self, gid):
        """拉进来时已经关了的会话：这边没有它的标题、目录，去它那台电脑上查"""
        group = self._group(gid)
        for member in list(group["members"]) if group else []:
            if member.get("cwd") or self.app.store.record(member["key"]):
                continue
            source_id, session_id = member["key"].split("#", 1)
            source = self.app.store.source(source_id)
            if not source or not source.live:
                continue

            def run(member=member, source=source, session_id=session_id):
                try:
                    meta = source.request({"cmd": "session_info", "sessionId": session_id}, timeout=20).get("session") or {}
                except Exception:  # noqa: BLE001
                    return
                with self._lock:
                    group = self._group(gid)
                    target = next((m for m in group["members"] if m["key"] == member["key"]), None) if group else None
                    if not target:
                        return
                    if meta.get("title"):
                        target["title"] = str(meta["title"])[:80]
                    if meta.get("cwd"):
                        target["cwd"], target["project"] = meta["cwd"], _project(meta["cwd"])
                self._changed()
            threading.Thread(target=run, daemon=True).start()

    # MARK: 发言

    def _user_says(self, gid, text, to, images=None, files=None):
        """用户在群里说话：发给全部成员（或指定的几个），可带图、文件；关了的成员先恢复"""
        if (self._group(gid) or {}).get("paused"):
            self._set_paused(gid, False)   # 用户发话了：暂停期间攒下的先放出去
        ended = []
        with self._lock:
            group = self._group(gid)
            group["streak"] = 0
            if group.get("autoName") and text and not any(m["from"] == "me" for m in group["messages"]):
                group["name"] = self._provisional(group["members"], text)
            targets = [m for m in group["members"] if to is None or m["key"] in to]
            message = {"id": _new_id("m-"), "ts": now_ms(), "from": "me", "fromTitle": "用户", "text": text,
                       "states": {m["key"]: "pending" for m in targets}}
            if to:
                message["to"] = to
            if images:
                message["images"] = images
            if files:
                message["files"] = files
            self._append(group, message)
            for member in targets:
                if self.app.store.record(member["key"]):
                    self._jobs.put((gid, message["id"], member["key"], time.time()))
                else:
                    ended.append(member["key"])
        self._changed()
        if ended:
            threading.Thread(target=self._resume, args=(gid, ended, message["id"]), daemon=True).start()
        return dict(message)

    def agent_said(self, key, item):
        """agent 经 group say 发来的（对话里 t=group_say 的那一条）"""
        text = str(item.get("text") or "").strip()
        if not text:
            return
        wanted = item.get("group") or ""
        with self._lock:
            mine = [g for g in self._groups if any(m["key"] == key for m in g["members"])]
            group = next((g for g in mine if g["id"] == wanted or (wanted and g["name"] == wanted)), None) \
                or (max(mine, key=lambda g: g["updatedAt"]) if mine else None)
            if not group:
                log.write("会话群：%s 发了群消息，但它不在任何群里，忽略" % key)
                return
            item_id = item.get("id")
            if item_id and any(m["from"] == key and m.get("itemId") == item_id for m in group["messages"]):
                return   # 重连后 watcher 又吐了一遍
            record = self.app.store.record(key)
            sender = next((m for m in group["members"] if m["key"] == key), None)
            title = display_title(record.snap) if record else (sender or {}).get("title") or "会话"
            if sender:
                sender["title"], sender["briefed"] = title[:80], True
            if group.get("autoName") and str(item.get("name") or "").strip():
                group["name"], group["autoName"] = str(item["name"]).strip()[:40], False
                self._append(group, self._event("%s 给群起名「%s」" % (title, group["name"]), "named", [title, group["name"]]))
            to = self._resolve(item.get("to") or [], group, key)
            targets = [m for m in group["members"] if m["key"] != key and (not to or m["key"] in to)]
            group["streak"] = group.get("streak", 0) + 1
            paused_now = False
            if not group.get("paused") and group["streak"] > STREAK_LIMIT:
                group["paused"] = paused_now = True
                self._append(group, self._event("agent 之间已连续往来 %d 条，已暂停转发；轻点「继续转发」接着投递" % STREAK_LIMIT, "autopaused", [str(STREAK_LIMIT)]))
            message = {"id": _new_id("m-"), "ts": now_ms(), "from": key, "fromTitle": title, "text": text[:TEXT_LIMIT], "states": {}}
            if to:
                message["to"] = to
            if item_id:
                message["itemId"] = item_id
            for member in targets:
                if group.get("paused"):
                    message["states"][member["key"]] = "paused"
                elif self.app.store.record(member["key"]):
                    message["states"][member["key"]] = "pending"
                    self._jobs.put((group["id"], message["id"], member["key"], time.time()))
                else:
                    message["states"][member["key"]] = "ended"
            self._append(group, message)
            name, gid = group["name"], group["id"]
            # 同微信群：有人说话推一条（免打扰的群不推；同一个群两分钟内只推一条）
            push_said = not paused_now and not group.get("paused") and not group.get("muted") \
                and time.time() - self._last_push.get(gid, 0) > PUSH_GAP
            if push_said:
                self._last_push[gid] = time.time()
        log.write("会话群「%s」：%s → %s：%s" % (name, title, "、".join(m["title"] for m in targets), text[:60]))
        if paused_now:
            self.app.server.notify("group", name, "agent 之间往来较多，已暂停转发，请确认是否继续", key, route="group:" + gid)
        elif push_said:
            self.app.server.notify("group", name, "%s：%s" % (title, re.sub(r"\s+", " ", text)), key, route="group:" + gid)
        self._changed()

    @staticmethod
    def _resolve(names, group, sender):
        """--to 写的：成员 key（watcher 核对过的）或名字（老 watcher 没拿到成员表时原样带来）"""
        others = [m for m in group["members"] if m["key"] != sender]
        out = []
        for name in names if isinstance(names, list) else []:
            if any(m["key"] == name for m in others):
                out.append(name)
                continue
            low = str(name).lower()
            hits = [m for m in others if low in m["title"].lower() or (m.get("project") or "").lower() == low or (m.get("machine") or "").lower() == low]
            if len(hits) == 1:
                out.append(hits[0]["key"])
        return out

    # MARK: 投递

    def _worker(self):
        while True:
            gid, mid, key, since = self._jobs.get()
            try:
                self._deliver(gid, mid, key, since)
            except Exception as exc:  # noqa: BLE001
                log.write("会话群投递出错：%r" % exc)

    def _deliver(self, gid, mid, key, since):
        record = self.app.store.record(key)
        with self._lock:
            group = self._group(gid)
            member = next((m for m in group["members"] if m["key"] == key), None) if group else None
            if not member or not any(m["id"] == mid for m in group["messages"]):
                return
        if not record:
            self._set_state(gid, mid, key, "ended")
            return
        if delivery.waiting_problem(record):
            # Claude 在等你确认：回车会替你点允许，先不投；过会儿再试，等太久算失败
            if time.time() - since > WAIT_LIMIT:
                self._set_state(gid, mid, key, "failed", "会话一直在等你确认，未能投递")
            else:
                threading.Timer(5, lambda: self._jobs.put((gid, mid, key, since))).start()
            return
        with self._lock:
            # 这次要送的：没看过的群说明、会话关着时错过的群消息、这一条
            batch = [dict(m) for m in group["messages"] if m["id"] != mid and (m.get("states") or {}).get(key) == "ended"]
            batch += [dict(m) for m in group["messages"] if m["id"] == mid]
            text = self._compose(batch, member, group)
        media = self._attachments(gid, batch)
        if delivery.DRY_RUN:
            log.write("[dry-run] 群消息全文 → %s：%s%s" % (member["title"], text, "（附 %d 个图片或文件）" % len(media) if media else ""))
        source = self.app.store.source(record.source_id)
        outcome = delivery.send(text, media, record, source, True, self.app.server.siblings(record))
        state = ("sent" if outcome.get("submitted") else "filled") if outcome.ok else "failed"
        for message in batch:
            self._set_state(gid, message["id"], key, state, None if outcome.ok else outcome["message"])
        if outcome.ok:
            self._mark_briefed(gid, key)
        else:
            log.write("会话群投递给 %s 失败：%s" % (member["title"], outcome["message"]))

    def _resume(self, gid, keys, mid):
        """恢复关了的成员（一个一个来）：在它项目的 VS Code 窗口里接着这段对话，送进没看到的群消息"""
        from .app import launch_session
        for key in keys:
            with self._lock:
                group = self._group(gid)
                member = next((m for m in group["members"] if m["key"] == key), None) if group else None
                if not member:
                    continue
                backlog = [dict(m) for m in group["messages"] if (m.get("states") or {}).get(key) == "ended" or m["id"] == mid]
                prompt = self._compose(backlog, member, group)
            media = self._attachments(gid, backlog)
            source_id, session_id = key.split("#", 1)
            source = self.app.store.source(source_id)
            if not source or not source.live:
                self._set_state(gid, mid, key, "ended", "会话所在的电脑未连接，暂时无法恢复")
                continue
            if (member.get("agent") or "claude-code") != "claude-code":
                self._set_state(gid, mid, key, "ended", "这类会话无法从 Kiteline 恢复，请在它的 agent 中打开")
                continue
            cwd = member.get("cwd")
            if not cwd:
                try:
                    cwd = (source.request({"cmd": "session_info", "sessionId": session_id}, timeout=20).get("session") or {}).get("cwd")
                except Exception:  # noqa: BLE001
                    cwd = None
            if not cwd:
                self._set_state(gid, mid, key, "ended", "未找到该会话的工作目录")
                continue
            if media:
                # 图、文件先传到它所在的电脑，路径写在送进去的那段末尾（同给会话发图）
                try:
                    prompt = delivery.compose(prompt, delivery.stage(media, source), media)
                except Exception as exc:  # noqa: BLE001
                    for message in backlog:
                        self._set_state(gid, message["id"], key, "failed", "图片或文件传输到会话所在机器失败：%s" % exc)
                    continue
            if delivery.DRY_RUN:
                log.write("[dry-run] 群消息全文 → %s（恢复）：%s%s" % (member["title"], prompt, "（附 %d 个图片或文件）" % len(media) if media else ""))
            log.write("会话群：恢复 %s（%s:%s）" % (member["title"], source.name, cwd))
            for message in backlog:
                self._set_state(gid, message["id"], key, "pending", "正在恢复会话")
            # 一个做完再恢复下一个（同 Mac 版）：launch_session 先回、开窗口按回车在后台做，不等的话两个同时开，
            # 后一个的扩展链接落进前一个项目的窗口，在那儿开出一个空会话（11-01 Win11 实测）
            finished, outcome = threading.Event(), {}

            def done(submitted, outcome=outcome, finished=finished):
                outcome["submitted"] = submitted
                finished.set()
            # 回车后核实这条群消息真进了会话记录（记录里多出现一次）：电脑重启后 VS Code 自己恢复出来的标签，
            # 扩展会说「会话已经开着、内容没填」，回车按在空输入框上（11-01 kl-ubuntu 实测）。搜不了的照旧按了回车就算
            probe = re.split(r'["\\\r\n\t]', next((m["text"] for m in backlog if m["id"] == mid), "").strip())[0][:30]

            def hits(source=source, session_id=session_id, probe=probe):
                if len(probe) < 4:
                    return None
                try:
                    return len(source.request({"cmd": "search", "sessionId": session_id, "q": probe}, timeout=15).get("results") or [])
                except Exception:  # noqa: BLE001
                    return None
            base = None if delivery.DRY_RUN else hits()

            def started(key=key, base=base, hits=hits):
                record = self.app.store.record(key)
                if record and record.activity in ("busy", "waiting"):
                    return True
                now = hits()
                return now is not None and now > base
            # 不推「新任务未能自动提交」（那段话说的是新建会话）：群里这条消息的状态会写明（同 Mac 版）
            result = launch_session(cwd, prompt, True, session_id, source.kind, source.name, started if base is not None else None,
                                    source=source, done=done)
            submitted = result.get("submitted")
            if result.get("ok") and not delivery.DRY_RUN:
                finished.wait(180)
                submitted = outcome.get("submitted", False)
            if result.get("ok") and not submitted and base is not None:
                # 核实过没进去：别写「已填入」（内容可能根本没填上）。如实记未送达，会话这时多半已经开着，用户在群里再发一次就走普通投递
                state, note = "failed", "恢复会话后未能送进去，请在电脑上查看该会话，或在群里重发"
            else:
                state = ("sent" if submitted else "filled") if result.get("ok") else "ended"
                note = None if result.get("ok") else result.get("message")
            for message in backlog:
                self._set_state(gid, message["id"], key, state, note)
            if result.get("ok") and state != "failed":
                self._mark_briefed(gid, key)

    def _compose(self, messages, member, group):
        """送进会话的文字（同 Mac 版 compose）：没看过群说明的先带上说明，再是群消息，最后一行怎么回"""
        command = self.commands.get(member["key"].split("#", 1)[0]) or DEFAULT_COMMAND
        lines = []
        if not member.get("briefed"):
            lines.append("【Kiteline 会话群「%s」】用户把这个会话和下面几个会话拉进了一个群，大家可能在不同电脑、不同项目里，经 Kiteline 互相发消息协作：" % group["name"])
            for other in group["members"]:
                lines.append("· %s%s" % ("你：" if other["key"] == member["key"] else "", self._label(other)))
            lines.append("发群消息（成员会收到，用户在群里也看得到）：%s group say \"内容\"；只发给某一个加 --to 名字；看成员和最近的群消息：%s group info。" % (command, command))
            lines.append("需要对方知道或配合的事（进度、结果、请求、回答对方的问题）再发，不用客套回复；用户在群里说的话也用 group say 回复；群里的往来只在群里回，不用另外向用户汇报。")
            if group.get("autoName"):
                lines.append("这个群还没有正式名字：你第一次发群消息时加上 --name \"群名\"（概括这次协作的事，12 个字以内）。")
            lines.append("")
        for message in messages:
            if message["from"] == "me":
                who = "用户"
            elif message["from"] == "system":
                who = "群提示"
            else:
                sender = next((m for m in group["members"] if m["key"] == message["from"]), None)
                who = self._label(sender) if sender else message.get("fromTitle") or "会话"
            lines.append("【群「%s」· %s】%s" % (group["name"], who, "（只发给你）" if message.get("to") else ""))
            if message["text"]:
                lines.append(message["text"])
            images, files = len(message.get("images") or []), [f["name"] for f in message.get("files") or []]
            if images or files:
                parts = (["附图 %d 张" % images] if images else []) + (["附件 " + "、".join(files)] if files else [])
                lines.append("（%s，路径在本条消息末尾）" % "，".join(parts))
        if member.get("briefed"):
            lines.append("（回复群里：%s group say \"内容\"；不需要回复就不用回）" % command)
        return "\n".join(lines)

    @staticmethod
    def _label(member):
        where = " · ".join(x for x in (member.get("machine"), member.get("project")) if x)
        return "%s（%s）" % (member["title"], where) if where else member["title"]

    def _set_state(self, gid, mid, key, state, note=None):
        with self._lock:
            group = self._group(gid)
            message = next((m for m in group["messages"] if m["id"] == mid), None) if group else None
            if not message:
                return
            states = message.setdefault("states", {})
            notes = message.get("notes") or {}
            if states.get(key) == state and notes.get(key) == note:
                return
            states[key] = state
            if note:
                notes[key] = note
            else:
                notes.pop(key, None)
            if notes:
                message["notes"] = notes
            else:
                message.pop("notes", None)
            payload = dict(message)
        self._save()
        self.app.server.publish("group_msg", {"id": gid, "message": payload})

    def _mark_briefed(self, gid, key):
        with self._lock:
            group = self._group(gid)
            member = next((m for m in group["members"] if m["key"] == key), None) if group else None
            if member and not member.get("briefed"):
                member["briefed"] = True
                self._save()

    # MARK: 外面来的事

    def note_hello(self, source_id, event):
        command = event.get("selfCommand")
        if command:
            self.commands[source_id] = command

    def sessions_changed(self):
        """会话列表变了：成员开了、关了告诉 watcher；排着的投递有了会话就接着投（投递线程自己认），关了的改成恢复时补上；在跑的成员更新标题"""
        with self._lock:
            keys = {m["key"] for g in self._groups for m in g["members"]}
        live = {k for k in keys if self.app.store.record(k)}
        if live == self._live:
            return
        self._live = live
        with self._lock:
            for group in self._groups:
                for member in group["members"]:
                    record = self.app.store.record(member["key"])
                    if record:
                        member["title"] = display_title(record.snap)[:80]
                        if record.snap.get("cwd"):
                            member["cwd"], member["project"] = record.snap["cwd"], _project(record.snap["cwd"])
        self._changed()

    def push_to_agents(self, only=None):
        """群名单变了马上推给 watcher（agent 收到群说明就可能发言）；内容没变不重推。来源刚连上给它一份。
        隔离的测试实例连着的 watcher 用的是真的数据目录，别拿测试数据盖掉（同待办）"""
        if (os.environ.get("KITELINE_CONFIG_DIR") or os.environ.get("KITELINE_DRY_RUN") == "1") and not os.environ.get("CCPULSE_DATA_DIR"):
            return
        items = self._agent_snapshot()
        if only is None:
            data = json.dumps(items, sort_keys=True, ensure_ascii=False)
            if data == self._pushed:
                return
            self._pushed = data
        targets = [only] if only is not None else [s for s in list(self.app.store.sources.values()) if s.live]

        def run():
            for source in targets:
                try:
                    source.request({"cmd": "groups", "items": items}, timeout=20)
                except Exception:  # noqa: BLE001  老版本 watcher 不认这个请求
                    pass
        threading.Thread(target=run, name="groups-push", daemon=True).start()

    def _agent_snapshot(self):
        with self._lock:
            out = []
            for group in self._groups:
                row = {"id": group["id"], "name": group["name"], "autoName": group.get("autoName", False), "paused": bool(group.get("paused"))}
                if group.get("topic"):
                    row["topic"] = group["topic"][:500]
                row["members"] = [{"key": m["key"], "sessionId": m["key"].split("#", 1)[-1], "title": m["title"], "machine": m.get("machine") or "",
                                   "project": m.get("project") or "", "live": bool(self.app.store.record(m["key"]))} for m in group["members"]]
                row["recent"] = [{"fromTitle": "用户" if m["from"] == "me" else m.get("fromTitle") or "", "text": self._agent_text(m)[:500], "ts": m["ts"]}
                                 for m in [x for x in group["messages"] if x["from"] != "system"][-8:]]
                out.append(row)
            return out

    @staticmethod
    def _agent_text(message):
        """agent 用 group info 看到的一条：带了图、文件的注上（只发图时正文是空的）"""
        images, files = len(message.get("images") or []), [f["name"] for f in message.get("files") or []]
        note = "，".join((["附图 %d 张" % images] if images else []) + (["附件 " + "、".join(files)] if files else []))
        return " ".join(x for x in (message["text"], "（%s）" % note if note else "") if x)

    # MARK: 给各端的

    def _group(self, gid):
        return next((g for g in self._groups if g["id"] == gid), None)

    def _summary(self, group):
        with self._lock:
            out = {k: group[k] for k in ("id", "name", "autoName", "createdAt", "updatedAt")}
            out["paused"] = bool(group.get("paused"))
            out["marked"], out["muted"] = bool(group.get("marked")), bool(group.get("muted"))
            out["count"] = sum(1 for m in group["messages"] if m["from"] != "system")
            if group.get("topic"):
                out["topic"] = group["topic"]
            out["members"] = [{k: m[k] for k in ("key", "title", "joinedAt", "machine", "project", "agent") if m.get(k) is not None} for m in group["members"]]
            last = next((m for m in reversed(group["messages"]) if m["from"] != "system"), None) or (group["messages"][-1] if group["messages"] else None)
            if last:
                out["last"] = dict(last)
            return out

    def summary_payload(self):
        with self._lock:
            # 标记的排前面，再按最近动静
            groups = sorted(self._groups, key=lambda g: (bool(g.get("marked")), g["updatedAt"]), reverse=True)
        return {"ok": True, "items": [self._summary(g) for g in groups]}

    def _append(self, group, message):
        """加一条（调用方持锁）：新消息推 group_msg，超过上限删最早的"""
        group["messages"].append(message)
        group["updatedAt"] = message["ts"]
        if len(group["messages"]) > MESSAGE_LIMIT:
            extra = len(group["messages"]) - MESSAGE_LIMIT
            # 删掉的旧消息：它们的图、文件也删掉
            for old in group["messages"][:extra]:
                for media in (old.get("images") or []) + (old.get("files") or []):
                    try:
                        os.remove(os.path.join(self._media_dir(group["id"]), media["ref"]))
                    except OSError:
                        pass
            del group["messages"][:extra]
        self.app.server.publish("group_msg", {"id": group["id"], "message": dict(message)})

    def _changed(self):
        self._save()
        self.app.server.publish("groups", self.summary_payload())
        self.push_to_agents()

    def _save(self):
        # 写盘也在锁里：投递线程、请求线程同时写会抢同一个 .tmp（一个换名后另一个就找不到了）
        with self._lock:
            config.write_private(self._file, json.dumps({"groups": self._groups}, ensure_ascii=False))
