"""对话里 agent 的头像和昵称、Agent 详情、设备详情（同 Mac 版 Sources/AgentFaces.swift，接口和 JSON 一样）。

头像昵称存配置目录 agent-faces.json，上传的图在 agent-avatars/；两层：某个会话自己的（按会话 key）、
某家 agent 所有会话默认的（按 agent id），会话自己的优先。avatar 的写法（各端自己画，不传图）：
  mark:<agentId|kite>:<底色> / emoji:<表情>:<底色> / text:<底色> / image:<id>；空 = agent 自己的标志

  POST /api/agent-face   {key?, agent, scope: session|agent, name, avatar | image(base64)}；name、avatar 都空 = 恢复默认
  GET  /api/agent-avatar?id=
  GET  /api/agent-info?key=&agent=   Agent 详情：会话、插件、所在机器
  GET  /api/machine?source=          设备详情：系统、CPU、内存、IP、装了哪些 agent
"""
import base64
import hashlib
import io
import json
import os
import re
import threading
import time

from . import config, log
from .store import display_title

SESSION_LIMIT = 500
_TONE = re.compile(r"^[a-z]{1,12}$")
_IMAGE_ID = re.compile(r"^[A-Za-z0-9]{1,16}$")


def valid_avatar(avatar):
    parts = avatar.split(":")
    kind = parts[0]
    if kind == "mark":
        return len(parts) == 3 and 0 < len(parts[1]) <= 60 and bool(_TONE.match(parts[2]))
    if kind == "emoji":
        return len(parts) == 3 and 0 < len(parts[1]) <= 12 and bool(_TONE.match(parts[2]))
    if kind == "text":
        return len(parts) == 2 and bool(_TONE.match(parts[1]))
    if kind == "image":
        return len(parts) == 2 and bool(_IMAGE_ID.match(parts[1]))
    return False


def clean_name(raw):
    """名字去掉首尾空白和换行，最多 24 个字（同「我」的名字）"""
    return " ".join(str(raw or "").splitlines()).strip()[:24]


class AgentFaces:
    def __init__(self):
        self.lock = threading.Lock()
        self.store = {"sessions": {}, "agents": {}}
        try:
            with open(self.file, encoding="utf-8") as handle:
                saved = json.load(handle)
            if isinstance(saved, dict):
                self.store = {"sessions": dict(saved.get("sessions") or {}), "agents": dict(saved.get("agents") or {})}
        except (OSError, ValueError):
            pass

    @property
    def file(self):
        return config.path("agent-faces.json")

    @property
    def image_dir(self):
        return config.path("agent-avatars")

    def payload(self):
        """放进 /api/state 的 faces：{sessions: {key: {name, avatar}}, agents: {agentId: {name, avatar}}}"""
        with self.lock:
            return {part: {k: {"name": v.get("name", ""), "avatar": v.get("avatar", "")} for k, v in self.store[part].items()}
                    for part in ("sessions", "agents")}

    def entries(self, key, agent):
        with self.lock:
            return self.store["sessions"].get(key), self.store["agents"].get(agent)

    def save(self, body):
        """改头像昵称：返回 (状态码, JSON)"""
        key = str(body.get("key") or "")
        agent = str(body.get("agent") or "") or "claude-code"
        scope = "agent" if body.get("scope") == "agent" else "session"
        if scope == "session" and not key:
            return 400, {"ok": False, "error": "缺少会话 key"}
        if len(agent) > 60:
            return 400, {"ok": False, "error": "agent 不对"}
        name = clean_name(body.get("name"))
        avatar = str(body.get("avatar") or "").strip()
        if body.get("image"):
            image = str(body["image"])
            if "base64," in image:
                image = image.split("base64,", 1)[1]
            try:
                data = base64.b64decode(image, validate=False)
            except (ValueError, TypeError):
                data = b""
            image_id = self._save_image(data)
            if not image_id:
                return 400, {"ok": False, "error": "无法打开此图片，请选择其他图片"}
            avatar = "image:" + image_id
        if avatar and not valid_avatar(avatar):
            return 400, {"ok": False, "error": "头像格式不对"}
        face = {"name": name, "avatar": avatar, "at": int(time.time() * 1000)} if name or avatar else None
        with self.lock:
            target = self.store["agents" if scope == "agent" else "sessions"]
            slot = agent if scope == "agent" else key
            if face:
                target[slot] = face
            else:
                target.pop(slot, None)
            if scope == "agent" and key:
                self.store["sessions"].pop(key, None)   # 「用于所有会话」：这个会话跟着默认走，不再留自己的
            sessions = self.store["sessions"]
            if len(sessions) > SESSION_LIMIT:
                for old in sorted(sessions, key=lambda k: sessions[k].get("at", 0))[:len(sessions) - SESSION_LIMIT]:
                    sessions.pop(old, None)
            snapshot = json.dumps(self.store, ensure_ascii=False)
            used = {v["avatar"][6:] for part in ("sessions", "agents") for v in self.store[part].values()
                    if str(v.get("avatar", "")).startswith("image:")}
        config.write_private(self.file, snapshot)
        self._prune(used)
        reply = self.payload()
        reply["ok"] = True
        return 200, reply

    def image(self, image_id):
        if not image_id or not _IMAGE_ID.match(image_id):
            return None
        try:
            with open(os.path.join(self.image_dir, image_id + ".jpg"), "rb") as handle:
                return handle.read()
        except OSError:
            return None

    def _save_image(self, data):
        """上传的图：居中裁成 256×256 JPEG，按内容起名（同一张图传两次是同一个文件）"""
        if not data or len(data) > 20 * 1024 * 1024:
            return None
        try:
            from PIL import Image
            image = Image.open(io.BytesIO(data)).convert("RGB")
            side = min(image.size)
            left, top = (image.width - side) // 2, (image.height - side) // 2
            image = image.crop((left, top, left + side, top + side)).resize((256, 256), Image.LANCZOS)
            out = io.BytesIO()
            image.save(out, "JPEG", quality=86)
            jpeg = out.getvalue()
        except Exception as exc:  # noqa: BLE001
            log.write("保存 agent 头像失败：%s" % exc)
            return None
        image_id = hashlib.sha256(jpeg).hexdigest()[:12]
        config.write_private(os.path.join(self.image_dir, image_id + ".jpg"), jpeg)
        return image_id

    def _prune(self, used):
        """没人用的上传图删掉"""
        try:
            names = os.listdir(self.image_dir)
        except OSError:
            return
        for name in names:
            if name.endswith(".jpg") and name[:-4] not in used:
                try:
                    os.remove(os.path.join(self.image_dir, name))
                except OSError:
                    pass


# MARK: - 设备详情、Agent 详情

def _ask(source, payload, timeout=10):
    try:
        reply = source.request(payload, timeout=timeout)
    except Exception as exc:  # noqa: BLE001
        return None, str(exc)
    reply.pop("event", None)
    reply.pop("id", None)
    return reply, None


def machine(app, source_id):
    """设备详情：来源的配置和连接状态 + 那台机器的 watcher 报的系统信息（machine_info）+ 现在的 CPU、内存 + 装了哪些 agent。
    机器离线、watcher 太旧（没有 machine_info）时只给知道的那部分"""
    source = app.store.source(source_id)
    if source is None:
        return None
    with app.store.lock:
        records = [r for r in app.store.records if r.source_id == source_id]
    live = getattr(source, "live", False)
    out = {"ok": True, "id": source.id, "name": source.name, "kind": source.kind, "online": live, "status": source.short_label(),
           "enabled": True, "sessions": len(records), "busy": sum(1 for r in records if r.activity in ("busy", "waiting"))}
    if source.kind == "local":
        out["computer"] = app.host
    host = (getattr(source, "config", None) or {}).get("sshHost")
    if host:
        out["sshHost"] = host
    if getattr(source, "watcher_version", None):
        out["watcher"] = source.watcher_version
    stats = app.machine_stats.get(source_id)
    if stats:
        out["stats"] = stats
    if not live:
        return out
    info, error = _ask(source, {"cmd": "machine_info"})
    if info is not None:
        out["info"] = info
    else:
        # 旧版 watcher 回「未知请求」：outdated（各端说「组件版本较旧」），别的是 failed + 原因
        out["infoError"] = "outdated" if "未知请求" in (error or "") else "failed"
        out["detail"] = error or ""
    plugins, _ = _ask(source, {"cmd": "plugins"})
    agents = []
    for row in (plugins or {}).get("plugins") or []:
        if not isinstance(row, dict) or not row.get("id"):
            continue
        detect = row.get("detect") if isinstance(row.get("detect"), dict) else {}
        item = {"id": row["id"], "name": row.get("name") or row["id"], "installed": detect.get("installed") is True}
        for src, dst in (("version", "plugin"), ("source", "source"), ("status", "state")):
            if row.get(src) is not None:
                item[dst] = str(row[src])
        if isinstance(detect.get("forms"), dict) and detect["forms"]:
            item["forms"] = {k: str(v) for k, v in detect["forms"].items()}
        if isinstance(row.get("abilities"), list):
            item["abilities"] = row["abilities"]
        agents.append(item)
    claude = (info or {}).get("claude")
    if isinstance(claude, dict):
        # Claude Code 不是插件（watcher 自带），machine_info 单独报它装了哪些形态：排在最前
        row = {"id": "claude-code", "name": "Claude Code", "installed": True, "source": "builtin",
               "abilities": ["view", "reply", "approve", "answer"]}
        if (info or {}).get("watcher"):
            row["plugin"] = str(info["watcher"])
        if isinstance(claude.get("forms"), dict) and claude["forms"]:
            row["forms"] = {k: str(v) for k, v in claude["forms"].items()}
        agents = [row] + [a for a in agents if a["id"] != "claude-code"]
    if plugins is not None or agents:
        out["agents"] = agents
    return out


def agent_info(app, faces, key, agent_hint):
    """Agent 详情：头像昵称（会话自己的、这家 agent 默认的）+ 会话（前端、版本、进程、目录、模型）+ 插件 + 所在机器"""
    record = app.store.record(key)
    source_id = record.source_id if record else key.split("#", 1)[0]
    agent = (record.snap.get("agent") if record else None) or agent_hint or "claude-code"
    own, default = faces.entries(key, agent)
    out = {"ok": True, "key": key, "agent": agent, "sourceId": source_id, "live": record is not None}
    if own:
        out["face"] = {"name": own.get("name", ""), "avatar": own.get("avatar", "")}
    if default:
        out["agentFace"] = {"name": default.get("name", ""), "avatar": default.get("avatar", "")}
    if record:
        snap = record.snap
        out.update({"title": display_title(snap), "sessionId": snap.get("sessionId"), "cwd": snap.get("cwd", ""), "entrypoint": snap.get("entrypoint") or ""})
        for src in ("sessionKind", "version", "pid", "startedAt"):
            if snap.get(src) not in (None, ""):
                out[src] = snap[src]
        if snap.get("tmuxPane"):
            out["tmux"] = True
        if (snap.get("usage") or {}).get("model"):
            out["model"] = snap["usage"]["model"]
        if snap.get("readOnly"):
            out["readOnly"] = True
    detail = machine(app, source_id)
    if detail:
        out["machine"] = detail
        plugin = next((a for a in detail.get("agents") or [] if a.get("id") == agent), None)
        if plugin:
            out["plugin"] = plugin
    return out
