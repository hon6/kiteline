"""ZCode（智谱的 agent 编程桌面应用 + 命令行 zcode，开源 github.com/zai-org/ZCode）：单独下发的插件，只读。

11-05 对 ZCode 3.17.2（Linux AppImage，自带的命令行 zcode 0.17.1）实测（隔离 HOME + 假模型，个人模型配置
~/.zcode/v2/provider_config.json 按官方文档 03-config 的格式写，不用登录）：
  ~/.zcode/cli/db/db.sqlite（桌面版和命令行共用；ZCODE_HOME / ZCODE_DATA_BASE_DIR 改目录），表结构同 OpenCode：
    session   id（sess_…）、directory、title、time_created / time_updated（毫秒）、time_archived、time_deleted、parent_id、last_outcome
    message   id、session_id、data（JSON：role、time.created / completed、modelId、metadata.visibility = model-only 的是给模型看的系统消息）
    part      message_id、session_id、data（JSON：text / reasoning / tool（callID、tool、state.status/input/output/error）/ step-finish（tokens））
    model_usage  每次请求一行：provider_id、model_id、started_at、input_tokens（含读缓存）、output_tokens、cache_read_input_tokens、cache_creation_input_tokens
  工具名同 Claude Code（Bash、Edit、Read、AskUserQuestion……）。
只读：桌面版没有对外的操作接口（它的服务是给远程 SSH 服务器用的）；完整的终端命令行要从源码编，桌面版自带的只有无界面的 --prompt。
额度：GLM Coding Plan（5 小时 + 每周）只能在智谱网页上看，本机不记。
"""
import json
import os
import re
import sqlite3
import subprocess
import time
from urllib.request import pathname2url

RECENT_MS = 12 * 3600 * 1000      # 开着 ZCode 时，列出最近 12 小时动过的会话
MAX_SESSIONS = 8
PROCESS = re.compile(r"(?i)(ZCode\.app/|ZCode\.exe|/zcode(\.cjs)?(\s|$)|zcode-(linux|darwin|windows)|/squashfs-root/zcode|\.mount_ZCode)")
READ_ONLY = ("ZCode 没有对外的操作接口，会话只能查看；请在电脑上的 ZCode 中回复和确认",
             "ZCode offers no external control interface, so its sessions are view-only. Reply and confirm in ZCode on your computer.")


def create(kl):
    def ps_text():
        """「进程号 命令行」一行一个：中台的跨平台进程列举（HOST_CAPS proc.list，Windows 也行）；老中台退回 ps"""
        if hasattr(kl, "process_list"):
            return "\n".join("%d %s" % (p["pid"], p["cmd"]) for p in kl.process_list())
        try:
            return subprocess.run(["ps", "-axww", "-o", "pid=,command="], capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            return ""

    if os.environ.get("ZCODE_HOME"):
        HOME = os.environ["ZCODE_HOME"]
    elif os.environ.get("ZCODE_DATA_BASE_DIR"):
        HOME = os.environ["ZCODE_DATA_BASE_DIR"]
    else:
        HOME = os.path.join(kl.HOME, ".zcode")
    DB = os.path.join(HOME, "cli", "db", "db.sqlite")

    def query(sql, args=()):
        if not os.path.isfile(DB):
            return []
        db = sqlite3.connect("file:%s?mode=ro" % pathname2url(DB), uri=True, timeout=2)
        try:
            db.row_factory = sqlite3.Row
            return [dict(r) for r in db.execute(sql, args)]
        finally:
            db.close()

    def load(text):
        try:
            value = json.loads(text or "{}")
            return value if isinstance(value, dict) else {}
        except ValueError:
            return {}

    def messages(sid, limit=None, before=None):
        """会话的消息（升序），拼成 OpenCode 接口的格式 {info, parts}，去掉只给模型看的系统消息"""
        sql = "select id, data, time_created from message where session_id = ?"
        args = [sid]
        if before is not None:
            sql += " and time_created < ?"
            args.append(int(before))
        sql += " order by time_created desc, sequence desc"
        if limit:
            sql += " limit %d" % int(limit)
        rows = list(reversed(query(sql, tuple(args))))
        if not rows:
            return []
        ids = [r["id"] for r in rows]
        parts = {}
        for row in query("select message_id, id, data from part where message_id in (%s) order by time_created, sequence"
                         % ",".join("?" * len(ids)), tuple(ids)):
            parts.setdefault(row["message_id"], []).append(dict(load(row["data"]), id=row["id"]))
        out = []
        for row in rows:
            info = dict(load(row["data"]), id=row["id"], sessionID=sid)
            meta = info.get("metadata") if isinstance(info.get("metadata"), dict) else {}
            if info.get("role") == "user" and (meta.get("visibility") == "model-only" or meta.get("runtimeMessage")):
                continue
            info.setdefault("time", {}).setdefault("created", row["time_created"])
            out.append({"info": info, "parts": parts.get(row["id"], [])})
        return out

    def running():
        try:
            out = ps_text()
        except (OSError, subprocess.SubprocessError):
            return False
        return any(PROCESS.search(line) for line in out.splitlines())

    class ZCode(kl.AgentPlugin):
        name = "ZCode"
        read_only = READ_ONLY[0]

        def __init__(self):
            self.last = {}   # 会话 id → 推到的最新消息时间

        def detect(self):
            import shutil
            forms = {}
            if shutil.which("zcode"):
                forms["cli"] = ""
            if os.path.isdir(HOME):
                forms["desktop"] = ""
            return {"installed": bool(forms), "forms": forms}

        def sessions(self):
            if not running():
                self.last.clear()
                return []
            now = int(time.time() * 1000)
            rows = query("select * from session where parent_id is null and time_archived is null and time_deleted is null "
                         "and time_updated > ? order by time_updated desc limit ?", (now - RECENT_MS, MAX_SESSIONS))
            out = []
            for session in rows:
                sid = session["id"]
                recent = messages(sid, 30)
                items = kl.opencode_items(recent)
                last_user = next((m for m in reversed(recent) if m["info"].get("role") == "user"), None)
                last_reply = next((m for m in reversed(recent) if m["info"].get("role") == "assistant"), None)
                text = next((i for i in reversed(items) if i["t"] == "text"), None)
                running_tool = None
                for message in recent[-3:]:
                    for part in message["parts"]:
                        state = part.get("state") if isinstance(part.get("state"), dict) else {}
                        if part.get("type") == "tool" and state.get("status") in ("pending", "running"):
                            running_tool = part.get("tool")
                replying = last_reply is not None and not (last_reply["info"].get("time") or {}).get("completed")
                asked = last_user is not None and (last_reply is None or
                                                   last_user["info"]["time"]["created"] > last_reply["info"]["time"]["created"])
                busy = (replying or asked or running_tool) and now - int(session.get("time_updated") or 0) < 10 * 60 * 1000
                if busy:
                    activity, reason = "busy", ("正在执行 %s" % running_tool) if running_tool else "正在工作"
                else:
                    activity, reason = "idle", text["text"] if text else None
                model = (last_reply or {}).get("info", {}).get("modelId")
                title = (session.get("title") or sid)[:60]
                cwd = session.get("directory") or ""
                if recent:
                    self.last.setdefault(sid, recent[-1]["info"]["time"]["created"])
                out.append({
                    "pid": None, "sessionId": sid, "name": title, "title": title, "cwd": cwd, "cwdShort": kl.display_cwd(cwd),
                    "status": activity, "waitingFor": None, "needs": None, "detail": None, "activity": activity, "reason": reason,
                    "activityText": None, "message": text["text"] if text else None, "messageUuid": text["id"] if text else None,
                    "error": None, "effort": None, "subagents": 0, "pendingTool": None, "pendingId": None,
                    "startedAt": session.get("time_created"), "statusUpdatedAt": None, "updatedAt": session.get("time_updated"),
                    "version": session.get("version"), "entrypoint": "zcode", "sessionKind": None, "tmuxPane": None,
                    "usage": None, "transcriptPath": None, "transcriptUpdatedAt": session.get("time_updated"),
                    "agent": "zcode", "model": model,
                    "readOnly": True, "readOnlyReason": READ_ONLY[0], "readOnlyReasonEn": READ_ONLY[1],
                })
            return out

        def pump(self):
            out = []
            for sid, last in list(self.last.items()):
                try:
                    recent = messages(sid, 12)
                except sqlite3.Error:
                    continue
                if not recent:
                    continue
                # 正在写的那条（分片还在更新）也要推：从最后一条已推的消息起重出，客户端按 id 覆盖
                fresh = [m for m in recent if m["info"]["time"]["created"] >= last]
                items = kl.opencode_items(fresh)
                self.last[sid] = recent[-1]["info"]["time"]["created"]
                if items:
                    out.append((sid, items))
            return out

        def history(self, sid, before, limit):
            count = max(1, limit // 3)
            try:
                bound = int(str(before).split(".")[0]) if before is not None else None
            except ValueError:
                bound = None
            rows = messages(sid, count + 1, bound)
            has_more = len(rows) > count
            return kl.opencode_items(rows[-count:]), has_more

        def usage(self, since_ms):
            out, buckets = [], {}
            try:
                rows = query("select u.*, s.directory as cwd from model_usage u left join session s on s.id = u.session_id "
                             "where u.started_at >= ?", (int(since_ms) - 3600000,))
            except sqlite3.Error:
                rows = []
            for row in rows:
                cached = int(row.get("cache_read_input_tokens") or 0)
                values = (max(0, int(row.get("input_tokens") or 0) - cached), row.get("output_tokens"), cached,
                          row.get("cache_creation_input_tokens"), 1)
                kl.usage_bucket(buckets, int(row["started_at"]), row.get("model_id") or "unknown", values,
                                cwd=row.get("cwd"), session=row.get("session_id"))
            out.extend(buckets.values())
            return out

    return ZCode()
