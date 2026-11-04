"""Grok Build（xAI 的终端编程 agent，命令 grok）：单独下发的插件。

11-04 对 1.0.70 实测（隔离 HOME + 假模型 tools/agent-probe/fakellm.py，~/.grok/config.toml 的 [model.x] 配自定义地址，不用账号）：
  ~/.grok/sessions/<URL 编码的工作目录>/<会话 id（UUIDv7）>/（GROK_HOME 改目录）：
    summary.json    info.cwd、generated_title / session_summary、current_model_id、created_at、session_kind
    updates.jsonl   ACP 的 session/update，一行一个、实时写；回复的流式分片 Grok 自己合好了才写（一条消息一行）：
                    user_message_chunk / agent_message_chunk / agent_thought_chunk、tool_call（toolCallId、title、rawInput）、
                    tool_call_update（status completed / failed、content）、plan、turn_completed（stop_reason、这一轮的 usage）
    events.jsonl    turn_started / turn_ended、phase_changed（waiting_for_model / tool_execution / permission_prompt……）、
                    permission_requested / permission_resolved（allow / deny）
  进程一直开着自己会话的 events.jsonl：按进程打开的文件对上会话（Linux /proc，Mac lsof）。
  确认框：1 以后全部自动允许 / 2 总是允许这条 / 3 允许 / 4 拒绝 / 5 永不允许，按数字就提交；提问框按选项数字（z 自己填），回车提交。
  忙时发的消息 Grok 自己排队；中断是 Ctrl+C（Esc 不中断），在「等模型」时中断不写 turn_ended、还把那句话放回输入框，
  所以在 tmux 里以界面为准（忙时状态行有 [stop]），中断后 Ctrl+U 清掉输入框。
用量：turn_completed 的 usage 按模型（modelUsage），inputTokens 含读缓存（11-04 用 FAKE_CACHED_TOKENS 实测），换成不含缓存的口径。
"""
import glob
import json
import os
import shutil
import subprocess
import time
from urllib.parse import unquote

TOOLS = {"run_terminal_command": "Bash", "read_file": "Read", "search_replace": "Edit", "write": "Write", "grep": "Grep",
         "list_dir": "LS", "todo_write": "TodoWrite", "ask_user_question": "AskUserQuestion", "spawn_subagent": "Agent",
         "exit_plan_mode": "ExitPlanMode", "monitor": "Bash"}
TAIL_BYTES = 512 * 1024
BUSY_MARKS = ("[stop]", "Ctrl+c:cancel")
READ_ONLY = (("Windows 上没有 tmux，Grok Build 的会话只能查看", "Windows has no tmux, so Grok Build sessions are view-only.")
             if os.name == "nt" else
             ("Grok Build 不在 tmux 中运行，只能查看；在 tmux 中启动 grok 后即可从手机回复和确认",
              "Grok Build isn't running in tmux, so this session is view-only. Start grok in tmux to reply and confirm from your phone."))
# 确认框：数字就提交。3 允许 / 2 总是允许这条命令 / 4 拒绝
OPTIONS = ({"key": "4", "label": "拒绝", "labelEn": "Deny", "style": "destructive"},
           {"key": "3", "label": "允许", "labelEn": "Allow", "style": "primary"},
           {"key": "2", "label": "总是允许这条命令", "labelEn": "Always allow this command", "style": "normal"})


def create(kl):
    GROK_HOME = os.environ.get("GROK_HOME") or os.path.join(kl.HOME, ".grok")
    SESSIONS = os.path.join(GROK_HOME, "sessions")

    def read_json(path):
        try:
            return json.loads(kl.read_text(path) or "")
        except (ValueError, TypeError):
            return None

    def tail_lines(path, size=TAIL_BYTES):
        try:
            total = os.path.getsize(path)
            with open(path, "rb") as handle:
                handle.seek(max(0, total - size))
                return handle.read().splitlines()
        except OSError:
            return []

    def text_of(content):
        if isinstance(content, dict):
            content = [content]
        out = []
        for part in content if isinstance(content, list) else []:
            if not isinstance(part, dict):
                continue
            inner = part.get("content") if part.get("type") == "content" else part
            if isinstance(inner, dict) and isinstance(inner.get("text"), str):
                out.append(inner["text"])
        return "\n".join(out)

    def tool_of(name, args):
        mapped = TOOLS.get(name, name or "tool")
        args = dict(args) if isinstance(args, dict) else {}
        if mapped == "Read" and "target_file" in args:
            args["file_path"] = args.pop("target_file")
        if mapped == "LS" and "target_directory" in args:
            args["path"] = args.pop("target_directory")
        if mapped == "TodoWrite" and isinstance(args.get("todos"), list):
            args["todos"] = [{"content": t.get("content") or t.get("title") or "", "activeForm": t.get("content") or "",
                              "status": "completed" if t.get("status") in ("completed", "done", "cancelled") else t.get("status") or "pending"}
                             for t in args["todos"] if isinstance(t, dict)]
        return mapped, args

    def call_name(update):
        meta = (update.get("_meta") or {}).get("x.ai/tool") if isinstance(update.get("_meta"), dict) else None
        return (meta or {}).get("name") or update.get("title")

    def grok_normalize(offset, entry):
        """updates.jsonl 一行 → 对话项"""
        params = entry.get("params") if isinstance(entry, dict) and isinstance(entry.get("params"), dict) else {}
        update = params.get("update") if isinstance(params.get("update"), dict) else {}
        kind = update.get("sessionUpdate")
        meta = params.get("_meta") if isinstance(params.get("_meta"), dict) else {}
        ts = meta.get("agentTimestampMs") or ((entry.get("timestamp") or 0) * 1000) or None
        items = []

        def base():
            return {"id": "%d.%d" % (offset, len(items)), "ts": int(ts) if ts else None}

        if kind == "user_message_chunk":
            text, _ = kl.clip(kl.strip_reminders(text_of(update.get("content"))).strip(), kl.USER_TEXT_MAX)
            if text:
                items.append(dict(base(), t="user", text=text))
        elif kind in ("agent_message_chunk", "agent_thought_chunk"):
            text = text_of(update.get("content")).strip()
            if text:
                items.append(dict(base(), t="text" if kind == "agent_message_chunk" else "thinking",
                                  text=kl.clip(text, kl.ASSISTANT_TEXT_MAX)[0]))
        elif kind == "tool_call":
            name, args = tool_of(call_name(update), update.get("rawInput"))
            items.append(dict(base(), t="tool", toolId=update.get("toolCallId"), name=name,
                              brief=kl.tool_brief(name, args), input=kl.shrink(args)))
        elif kind == "tool_call_update" and update.get("status") in ("completed", "failed"):
            text = text_of(update.get("content"))
            items.append(dict(base(), t="result", toolId=update.get("toolCallId"), text=kl.clip(text, kl.TOOL_RESULT_MAX)[0],
                              isError=update.get("status") == "failed"))
        elif kind == "plan" and isinstance(update.get("entries"), list):
            todos = [{"content": e.get("content") or "", "activeForm": e.get("content") or "",
                      "status": "completed" if e.get("status") == "completed" else e.get("status") or "pending"}
                     for e in update["entries"] if isinstance(e, dict)]
            tid = "plan-%d" % offset
            items.append(dict(base(), t="tool", toolId=tid, name="TodoWrite", brief="TodoWrite", input={"todos": todos}))
            items.append(dict(base(), t="result", toolId=tid, text="", isError=False))
        elif kind == "turn_completed" and update.get("stop_reason") == "cancelled":
            items.append(dict(base(), t="event", text="已中断"))
        return items

    def scan(folder):
        """会话目录 → 第一句、最后一句回复、还没结果的工具调用（updates）、忙 / 等确认（events）"""
        note = {"first": None, "message": None, "messageId": None, "pending": None, "busy": False, "approval": False,
                "updated": 0}
        updates = os.path.join(folder, "updates.jsonl")
        calls = {}
        for index, raw in enumerate(tail_lines(updates)):
            try:
                entry = json.loads(raw)
            except ValueError:
                continue
            update = ((entry.get("params") or {}).get("update") or {}) if isinstance(entry, dict) else {}
            kind = update.get("sessionUpdate")
            if kind == "user_message_chunk":
                text = text_of(update.get("content")).strip()
                note["first"] = note["first"] or text
            elif kind == "agent_message_chunk":
                text = text_of(update.get("content")).strip()
                if text:
                    note["message"], note["messageId"] = text, ((entry.get("params") or {}).get("_meta") or {}).get("eventId")
            elif kind == "tool_call":
                calls[update.get("toolCallId")] = update
            elif kind == "tool_call_update" and update.get("status") in ("completed", "failed"):
                calls.pop(update.get("toolCallId"), None)
            elif kind == "turn_completed":
                calls.clear()
        if calls:
            note["pending"] = list(calls.values())[-1]
        for raw in tail_lines(os.path.join(folder, "events.jsonl"), 128 * 1024):
            try:
                event = json.loads(raw)
            except ValueError:
                continue
            kind = event.get("type")
            if kind == "turn_started":
                note["busy"], note["approval"] = True, False
            elif kind == "turn_ended":
                note["busy"], note["approval"] = False, False
            elif kind == "permission_requested" and event.get("tool_name") != "ask_user_question":
                note["approval"] = True
            elif kind == "permission_resolved":
                note["approval"] = False
        try:
            note["updated"] = int(max(os.path.getmtime(updates), os.path.getmtime(os.path.join(folder, "events.jsonl"))) * 1000)
        except OSError:
            pass
        return note

    def usage_scan(path):
        """一份 updates.jsonl 的 token：每轮 turn_completed 的 usage.modelUsage（按模型），输入减掉读缓存。Grok 不记花费"""
        buckets = {}
        folder = os.path.dirname(path)
        summary = read_json(os.path.join(folder, "summary.json")) or {}
        cwd = (summary.get("info") or {}).get("cwd")
        sid = os.path.basename(folder)
        try:
            handle = open(path, "rb")
        except OSError:
            return []
        with handle:
            for raw in handle:
                if b'"turn_completed"' not in raw:
                    continue
                try:
                    entry = json.loads(raw)
                except ValueError:
                    continue
                update = (entry.get("params") or {}).get("update") or {}
                usage = update.get("usage") if isinstance(update.get("usage"), dict) else None
                if not usage:
                    continue
                ts = int((entry.get("timestamp") or 0) * 1000)
                per_model = usage.get("modelUsage") if isinstance(usage.get("modelUsage"), dict) and usage["modelUsage"] else {"unknown": usage}
                for model, u in per_model.items():
                    cached = int(u.get("cachedReadTokens") or 0)
                    values = (max(0, int(u.get("inputTokens") or 0) - cached), u.get("outputTokens"), cached,
                              u.get("cacheCreationTokens"), u.get("modelCalls") or 1)
                    kl.usage_bucket(buckets, ts, model, values, cwd=cwd, session=sid)
        return list(buckets.values())

    _opened = {}   # pid → 它开着的会话目录

    def grok_processes():
        """grok 进程 → 它开着的会话目录（进程一直开着自己会话的 events.jsonl）"""
        try:
            out = subprocess.run(["ps", "-axww", "-o", "pid=,command="], capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            return {}
        found = {}
        for line in out.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) != 2 or not parts[0].isdigit():
                continue
            exe = os.path.basename(parts[1].split()[0])
            if exe not in ("grok", "xai-grok-pager", "grok.exe"):
                continue
            pid = int(parts[0])
            folder = session_of(pid)
            if folder:
                found[pid] = folder
        return found

    def session_of(pid):
        paths = []
        try:
            for fd in os.listdir("/proc/%d/fd" % pid):
                try:
                    paths.append(os.readlink("/proc/%d/fd/%s" % (pid, fd)))
                except OSError:
                    pass
        except OSError:
            try:   # Mac：没有 /proc
                out = subprocess.run(["lsof", "-p", str(pid), "-Fn"], capture_output=True, text=True, timeout=5).stdout
                paths = [l[1:] for l in out.splitlines() if l.startswith("n")]
            except (OSError, subprocess.SubprocessError):
                paths = []
        for path in paths:
            if path.endswith(os.sep + "events.jsonl") and path.startswith(SESSIONS):
                return os.path.dirname(path)
        return None

    def screen(pane):
        try:
            out = subprocess.run(["tmux", "capture-pane", "-p", "-J", "-t", pane], capture_output=True, text=True, timeout=3).stdout
        except (OSError, subprocess.SubprocessError):
            return None
        return "\n".join(out.rstrip().splitlines()[-25:])

    class Grok(kl.AgentPlugin):
        name = "Grok Build"

        def __init__(self):
            self.pids = {}
            self.pending = {}   # 会话 id → 等回答的提问（tool_call）

        normalize = staticmethod(grok_normalize)

        def detect(self):
            command = shutil.which("grok")
            return {"installed": os.path.isdir(SESSIONS) or bool(command), "forms": {"cli": ""} if command else {}}

        def sessions(self):
            out = []
            now = int(time.time() * 1000)
            for pid, folder in grok_processes().items():
                sid = os.path.basename(folder)
                summary = read_json(os.path.join(folder, "summary.json")) or {}
                note = scan(folder)
                cwd = (summary.get("info") or {}).get("cwd") or unquote(os.path.basename(os.path.dirname(folder)))
                pane = kl.find_tmux_pane(pid)
                self.pids[sid] = pid
                busy, approval = note["busy"], note["approval"]
                text = screen(pane) if pane else None
                if text is not None and busy and not approval and not any(mark in text for mark in BUSY_MARKS):
                    busy = False   # 「等模型」时被 Ctrl+C 中断不写 turn_ended：以界面为准
                pending = note["pending"]
                question = pending if pending and call_name(pending) == "ask_user_question" else None
                self.pending[sid] = question
                pending_tool = pending_id = waiting = None
                if approval and pending:
                    pending_tool, args = tool_of(call_name(pending), pending.get("rawInput"))
                    pending_id = pending.get("toolCallId")
                    activity, reason, waiting = "waiting", "等待确认：%s" % kl.tool_brief(pending_tool, args), "等待你确认 %s" % pending_tool
                elif question and busy:
                    pending_tool, pending_id = "AskUserQuestion", question.get("toolCallId")
                    activity, reason, waiting = "waiting", "等待回答提问", "等待你回答"
                elif busy:
                    activity, reason = "busy", "正在工作"
                else:
                    activity, reason = "idle", note["message"]
                title = (summary.get("generated_title") or summary.get("session_summary") or note["first"] or sid[:8])[:60]
                updates = os.path.join(folder, "updates.jsonl")
                out.append({
                    "pid": pid, "sessionId": sid, "name": title, "title": title, "cwd": cwd, "cwdShort": kl.display_cwd(cwd),
                    "status": activity, "waitingFor": waiting, "needs": None, "detail": None, "activity": activity, "reason": reason,
                    "activityText": None, "message": note["message"], "messageUuid": note["messageId"], "error": None, "effort": None,
                    "subagents": 0, "pendingTool": pending_tool, "pendingId": pending_id,
                    "startedAt": kl.parse_ts((summary.get("created_at") or "")[:23] + "Z") if summary.get("created_at") else None,
                    "statusUpdatedAt": None, "updatedAt": note["updated"] or now, "version": None,
                    "entrypoint": "grok-" + (summary.get("session_kind") or "cli"), "sessionKind": None, "tmuxPane": pane,
                    "usage": None, "transcriptPath": updates if os.path.isfile(updates) else None,
                    "transcriptUpdatedAt": note["updated"] or now, "agent": "grok", "model": summary.get("current_model_id"),
                    "readOnly": not pane, "readOnlyReason": None if pane else READ_ONLY[0],
                    "readOnlyReasonEn": None if pane else READ_ONLY[1],
                })
            return out

        def pending_options(self, snap):
            if snap.get("readOnly") or snap.get("pendingTool") in ("AskUserQuestion", "ExitPlanMode"):
                return None
            return OPTIONS

        def _pid(self, sid):
            pid = self.pids.get(sid)
            pane = kl.find_tmux_pane(pid) if pid else None
            if not pane:
                raise RuntimeError("这个 Grok Build 会话不在 tmux 里运行，只能查看；在 tmux 中启动 grok 后，就可以从手机回复和确认")
            return pid, pane

        def send(self, sid, text, images):
            pid, _ = self._pid(sid)
            if images:
                text = (text + "\n" + "\n".join("@" + p for p in images)).strip()
            kl.tmux_send(pid, text, [], True)   # 忙时 Grok 自己排队
            return "已发送"

        def key(self, sid, key):
            pid, pane = self._pid(sid)
            key = str(key).lower()
            if key in ("esc", "escape"):
                text = screen(pane) or ""
                if not any(mark in text for mark in BUSY_MARKS):
                    return "当前没有进行中的任务"
                subprocess.run(["tmux", "send-keys", "-t", pane, "C-c"], check=True, timeout=10)
                time.sleep(0.5)
                # 「等模型」时中断，Grok 把那句话放回输入框：清掉，免得下一条接在后面
                subprocess.run(["tmux", "send-keys", "-t", pane, "C-u"], check=True, timeout=10)
                return "已中断"
            if key not in ("2", "3", "4"):
                raise RuntimeError("不支持的选项：%s" % key)
            kl.tmux_send(pid, "", [key], False)
            return "已选择"

        def answer(self, sid, answers):
            pid, pane = self._pid(sid)
            question = self.pending.get(sid)
            if not question:
                raise RuntimeError("这个 Grok Build 会话现在没有待回答的提问")
            questions = (question.get("rawInput") or {}).get("questions") or []
            for index, item in enumerate(questions):
                labels = [o.get("label") for o in item.get("options") or [] if isinstance(o, dict)]
                picked = kl._answer_for(answers, item.get("question"), index)
                choice = next((p for p in picked if p in labels), None)
                if choice is not None and labels.index(choice) < 9:
                    # 按选项序号（1–9）直接选
                    subprocess.run(["tmux", "send-keys", "-t", pane, str(labels.index(choice) + 1)], check=True, timeout=10)
                else:
                    custom = next((p for p in picked if p), None)
                    if not custom:
                        raise RuntimeError("没有选择答案")
                    subprocess.run(["tmux", "send-keys", "-t", pane, "z"], check=True, timeout=10)   # z 跳到自己填的那行
                    time.sleep(0.3)
                    kl.tmux_send(pid, custom, [], False)
                time.sleep(0.4)
                if question_open(pane):   # 回车：选中并到下一题，最后一题提交
                    kl.tmux_send(pid, "", [], True)
                    time.sleep(0.4)
            return "已回答"

        def close(self, sid):
            pid, pane = self._pid(sid)
            if self.pending.get(sid) or "Yes, proceed" in (screen(pane) or ""):
                raise RuntimeError("Grok Build 正在等你确认或回答。请先在卡片中作出选择，再关闭会话")
            kl.tmux_send(pid, "/quit", [], True)
            return "已关闭会话"

        def usage(self, since_ms):
            out = []
            for path in kl.recent_files([SESSIONS], "updates.jsonl", since_ms):
                out.extend(r for r in kl.cached_usage(path, usage_scan) if r["ts"] + 3600000 > since_ms)
            return out

    def question_open(pane):
        """提问框还开着（底下有 Enter:submit）"""
        return "Enter:submit" in (screen(pane) or "")

    return Grok()
