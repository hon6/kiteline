"""Kimi Code（月之暗面的编程 agent，命令行 kimi，2.x 起 Node 版，取代已归档的 kimi-cli）：单独下发的插件。

11-04 对 2.5.0 实测（隔离 HOME + 假模型 tools/agent-probe/fakellm.py）：
  ~/.kimi-code/locks/sessions/<sessionId>.lock          开着的会话：{"pid", "startedAt", "clientIdentity", "hostname"……}
  ~/.kimi-code/session_index.jsonl                      {sessionId, sessionDir, workDir}
  <sessionDir>/state.json                               {id, cwd, title, lastPrompt, createdAt, updatedAt, lastTurnReason……}
  <sessionDir>/agents/main/wire.jsonl                   事件流（每个事件一行、实时写），时间是毫秒 time：
      turn.prompt（用户这一轮说的话，origin.kind=user）/ turn.ended（completed / cancelled）
      context.append_loop_event：content.part（一段写完才写一行：text / think）、tool.call（工具开始）、tool.result
      interaction.request（等确认：kind approval 审批 / question 提问）/ interaction.resolved
      usage.record（每次请求的 token：inputOther、output、inputCacheRead、inputCacheCreation）、llm.request（真实模型名）
  KIMI_CODE_HOME 改整个目录。
审批是先弹卡片、批准后才写 tool.call；提问是先写 tool.call 再弹卡片。所以等审批时从 interaction.request 出工具项，
批准后的 tool.call 按这份记录里出现过的审批 id 跳过（normalizer_for 按文件记着），不重复。
回复、确认、中断：会话在 tmux 里跑时经 tmux 发字、按键（终端界面：审批 1 允许一次 / 2 本会话都允许 / 3 拒绝；
提问按选项序号、再回车提交；忙时 Esc 中断这一轮）。桌面版、VS Code 扩展、不在 tmux 里的命令行只能看。
额度：Kimi Code 会员有 5 小时、7 天、本月额度和加油包余额，只有拿它的登录令牌问 api.kimi.com 才查得到，做成默认关的单项开关。
"""
import glob
import json
import os
import re
import shutil
import ssl
import subprocess
import time
import urllib.request

TAIL_BYTES = 512 * 1024
# Kimi 的工具 → 手机认得的工具（参数名也对上：path → file_path）
TOOLS = {"Read": "Read", "Write": "Write", "Edit": "Edit", "Bash": "Bash", "Glob": "Glob", "Grep": "Grep",
         "TodoList": "TodoWrite", "FetchURL": "WebFetch", "AskUserQuestion": "AskUserQuestion", "ExitPlanMode": "ExitPlanMode",
         "Agent": "Agent"}
TODO_STATUS = {"pending": "pending", "in_progress": "in_progress", "done": "completed"}
READ_ONLY = (("Windows 上从手机操作 Kimi Code 还没实测，暂未开放，只能查看；请在电脑上回复和确认", "Controlling Kimi Code on Windows from your phone isn't tested yet, so it isn't available and this session is view-only. Reply and confirm on your computer.")
             if os.name == "nt" else
             ("Kimi Code 不在 tmux 中运行（或在桌面版、VS Code 中），只能查看；在 tmux 中启动 kimi 后即可从手机回复和确认",
              "Kimi Code isn't running in tmux (or runs in the desktop app or VS Code), so this session is view-only. "
              "Start kimi in tmux to reply and confirm from your phone."))
# 等审批时的按钮：Kimi 终端界面的审批菜单 1 允许一次 / 2 本会话都允许 / 3 拒绝
OPTIONS = ({"key": "3", "label": "拒绝", "labelEn": "Deny", "style": "destructive"},
           {"key": "1", "label": "允许", "labelEn": "Allow", "style": "primary"},
           {"key": "2", "label": "允许，且本会话不再询问", "labelEn": "Allow for this session", "style": "normal"})
LIMIT_TTL = 10 * 60
# 终端界面欢迎框里的会话 id
SESSION_LINE = re.compile(r"Session:\s+(session_[0-9a-f-]{36})")


def create(kl):
    def ps_text():
        """「进程号 命令行」一行一个：中台的跨平台进程列举（HOST_CAPS proc.list，Windows 也行）；老中台退回 ps"""
        if hasattr(kl, "process_list"):
            return "\n".join("%d %s" % (p["pid"], p["cmd"]) for p in kl.process_list())
        try:
            return subprocess.run(["ps", "-axww", "-o", "pid=,command="], capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            return ""

    # 终端：中台的通用终端层（tmux、Windows 控制台同一套，HOST_CAPS term.any）；老中台没有时只认 tmux
    _term_pane = getattr(kl, "term_pane", None) or kl.find_tmux_pane
    # Windows 控制台上的回复、确认、中断：在 Win11 真机实测过才开放（11-05：没测过的不放出来）
    WINDOWS_TESTED = False

    def term_pane(pid):
        pane = _term_pane(pid)
        if pane and str(pane).startswith("console:") and not WINDOWS_TESTED:
            return None
        return pane

    def term_screen(pane, lines=None):
        if hasattr(kl, "term_screen"):
            return kl.term_screen(pane, lines)
        try:
            return subprocess.run(["tmux", "capture-pane", "-p", "-J", "-t", pane] + (["-S", "-%d" % lines] if lines else []),
                                  capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            return ""

    def term_keys(pane, *names):
        if hasattr(kl, "term_keys"):
            return kl.term_keys(pane, *names)
        for name in names:
            term_keys(pane, name)

    KIMI_HOME = os.environ.get("KIMI_CODE_HOME") or os.path.join(kl.HOME, ".kimi-code")

    def read_json(path):
        try:
            return json.loads(kl.read_text(path) or "")
        except (ValueError, TypeError):
            return None

    def session_dir(sid):
        """会话目录：索引里有就用索引的，没有就在 sessions/ 下找"""
        try:
            with open(os.path.join(KIMI_HOME, "session_index.jsonl"), "rb") as handle:
                for raw in handle:
                    if sid.encode() in raw:
                        try:
                            row = json.loads(raw)
                        except ValueError:
                            continue
                        if row.get("sessionId") == sid and os.path.isdir(row.get("sessionDir") or ""):
                            return row["sessionDir"]
        except OSError:
            pass
        found = glob.glob(os.path.join(KIMI_HOME, "sessions", "*", sid))
        return found[0] if found else None

    def tool_of(name, args):
        mapped = TOOLS.get(name, name or "tool")
        args = dict(args) if isinstance(args, dict) else {}
        if "path" in args and "file_path" not in args and mapped in ("Read", "Write", "Edit"):
            args["file_path"] = args.pop("path")
        if mapped == "TodoWrite" and isinstance(args.get("todos"), list):
            args["todos"] = [{"content": t.get("title") or "", "activeForm": t.get("title") or "",
                              "status": TODO_STATUS.get(t.get("status"), "pending")}
                             for t in args["todos"] if isinstance(t, dict)]
        return mapped, args

    def display_args(display):
        """审批卡片里的 display → 工具参数（命令 / 文件）"""
        display = display if isinstance(display, dict) else {}
        if display.get("command"):
            return {"command": display["command"]}
        for key in ("path", "file", "filePath"):
            if display.get(key):
                return {"file_path": display[key]}
        return {k: v for k, v in display.items() if k != "kind" and isinstance(v, (str, int, float))}

    _approvals = {}   # 记录文件 → (大小, 这份记录里出现过的审批工具 id)

    def approval_ids(path):
        """这份记录里弹过审批的工具调用 id（这些在 interaction.request 时已出过工具项，tool.call 时跳过）"""
        try:
            size = os.path.getsize(path)
        except OSError:
            return set()
        hit = _approvals.get(path)
        if hit and hit[0] == size:
            return hit[1]
        ids = set()
        try:
            with open(path, "rb") as handle:
                for raw in handle:
                    if b'"interaction.request"' in raw and b'"approval"' in raw:
                        try:
                            entry = json.loads(raw)
                        except ValueError:
                            continue
                        if entry.get("kind") == "approval" and entry.get("toolCallId"):
                            ids.add(entry["toolCallId"])
        except OSError:
            pass
        _approvals[path] = (size, ids)
        return ids

    def kimi_normalize(offset, entry, path=None):
        """wire.jsonl 一行 → 对话项（user / text / thinking / tool / result）"""
        if not isinstance(entry, dict) or entry.get("agentId", "main") != "main":
            return []
        kind = entry.get("type")
        ts = entry.get("time") if isinstance(entry.get("time"), (int, float)) else None
        items = []

        def base():
            return {"id": "%d.%d" % (offset, len(items)), "ts": int(ts) if ts else None}

        if kind == "turn.prompt" and (entry.get("origin") or {}).get("kind", "user") == "user":
            parts = entry.get("input") if isinstance(entry.get("input"), list) else []
            text = "\n".join(p.get("text") for p in parts if isinstance(p, dict) and isinstance(p.get("text"), str))
            text, _ = kl.clip(kl.strip_reminders(text).strip(), kl.USER_TEXT_MAX)
            if text:
                items.append(dict(base(), t="user", text=text))
        elif kind == "context.append_loop_event":
            event = entry.get("event") if isinstance(entry.get("event"), dict) else {}
            etype = event.get("type")
            if etype == "content.part":
                part = event.get("part") if isinstance(event.get("part"), dict) else {}
                if part.get("type") == "text" and (part.get("text") or "").strip():
                    text, _ = kl.clip(part["text"].strip(), kl.ASSISTANT_TEXT_MAX)
                    items.append(dict(base(), t="text", text=text))
                elif part.get("type") == "think" and (part.get("think") or "").strip() and not part.get("hidden"):
                    text, _ = kl.clip(part["think"].strip(), kl.ASSISTANT_TEXT_MAX)
                    items.append(dict(base(), t="thinking", text=text))
            elif etype == "tool.call":
                if path and event.get("toolCallId") in approval_ids(path):
                    return []
                name, args = tool_of(event.get("name"), event.get("args"))
                items.append(dict(base(), t="tool", toolId=event.get("toolCallId"), name=name,
                                  brief=kl.tool_brief(name, args), input=kl.shrink(args)))
            elif etype == "tool.result":
                result = event.get("result") if isinstance(event.get("result"), dict) else {}
                output = result.get("output")
                if isinstance(output, list):
                    output = "\n".join(p.get("text") for p in output if isinstance(p, dict) and isinstance(p.get("text"), str))
                text, _ = kl.clip(output if isinstance(output, str) else json.dumps(output, ensure_ascii=False), kl.TOOL_RESULT_MAX)
                items.append(dict(base(), t="result", toolId=event.get("toolCallId"), text=text,
                                  isError=bool(result.get("isError"))))
        elif kind == "turn.ended" and entry.get("reason") == "cancelled":
            items.append(dict(base(), t="event", text="已中断"))
        elif kind == "interaction.request" and entry.get("kind") == "approval":
            request = entry.get("request") if isinstance(entry.get("request"), dict) else {}
            name, args = tool_of(request.get("toolName"), display_args(request.get("display")))
            items.append(dict(base(), t="tool", toolId=entry.get("toolCallId"), name=name,
                              brief=kl.tool_brief(name, args), input=kl.shrink(args)))
        return items

    def scan(path):
        """记录尾巴：第一句、最后一句回复、忙不忙、还没答的确认"""
        note = {"first": None, "message": None, "messageId": None, "busy": False, "pending": None, "model": None, "last": 0}
        try:
            size = os.path.getsize(path)
            with open(path, "rb") as handle:
                handle.seek(max(0, size - TAIL_BYTES))
                lines = handle.read().splitlines()
        except OSError:
            return note
        open_requests = {}
        for raw in lines:
            if b'"tools_snapshot"' in raw or b'"tool_select.' in raw:
                continue
            try:
                entry = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(entry, dict) or entry.get("agentId", "main") != "main":
                continue
            kind = entry.get("type")
            if isinstance(entry.get("time"), (int, float)):
                note["last"] = int(entry["time"])
            if kind == "turn.prompt":
                parts = entry.get("input") if isinstance(entry.get("input"), list) else []
                text = " ".join(p.get("text") for p in parts if isinstance(p, dict) and isinstance(p.get("text"), str)).strip()
                if text and (entry.get("origin") or {}).get("kind", "user") == "user":
                    note["first"] = note["first"] or text
                note["busy"] = True
            elif kind == "agent.turn.started":
                note["busy"] = True
            elif kind in ("turn.ended", "agent.turn.ended", "prompt.completed", "prompt.aborted"):
                note["busy"] = False
                open_requests.clear()
            elif kind == "interaction.request":
                open_requests[entry.get("id")] = entry
            elif kind == "interaction.resolved":
                open_requests.pop(entry.get("id"), None)
            elif kind == "llm.request" and entry.get("model"):
                note["model"] = entry["model"]
            elif kind == "context.append_loop_event":
                event = entry.get("event") if isinstance(entry.get("event"), dict) else {}
                part = event.get("part") if isinstance(event.get("part"), dict) else {}
                if event.get("type") == "content.part" and part.get("type") == "text" and (part.get("text") or "").strip():
                    note["message"], note["messageId"] = part["text"].strip(), event.get("uuid")
        if open_requests:
            note["pending"] = list(open_requests.values())[-1]
        return note

    def usage_scan(path):
        """一份记录的 token：usage.record 一次请求一行（inputOther 不含缓存，同 Claude 的口径）；模型名取最近一次 llm.request 的。
        Kimi Code 不记花费"""
        buckets, model, cwd = {}, None, None
        state = read_json(os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(path))), "state.json")) or {}
        cwd, sid = state.get("cwd"), state.get("id")
        try:
            handle = open(path, "rb")
        except OSError:
            return []
        with handle:
            for raw in handle:
                if b'"llm.request"' in raw:
                    try:
                        model = json.loads(raw).get("model") or model
                    except ValueError:
                        pass
                    continue
                if b'"usage.record"' not in raw:
                    continue
                try:
                    entry = json.loads(raw)
                except ValueError:
                    continue
                usage = entry.get("usage") if isinstance(entry.get("usage"), dict) else None
                ts = entry.get("time")
                if entry.get("type") != "usage.record" or not usage or not isinstance(ts, (int, float)):
                    continue
                values = (usage.get("inputOther"), usage.get("output"), usage.get("inputCacheRead"),
                          usage.get("inputCacheCreation"), 1)
                kl.usage_bucket(buckets, int(ts), model or entry.get("model") or "unknown", values, cwd=cwd, session=sid)
        return list(buckets.values())

    _cwds = {}   # pid → 工作目录（进程活着时不会变的，按 pid 记着）

    def kimi_processes():
        """本机的 Kimi Code 进程（Node 把进程名设成 kimi-code）→ 工作目录"""
        try:
            out = ps_text()
        except (OSError, subprocess.SubprocessError):
            return {}
        procs = {}
        for line in out.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2 and parts[1].strip() == "kimi-code" and parts[0].isdigit():
                pid = int(parts[0])
                if pid not in _cwds:
                    _cwds[pid] = process_cwd(pid)
                procs[pid] = _cwds[pid]
        for pid in list(_cwds):
            if pid not in procs:
                _cwds.pop(pid, None)
        return procs

    def process_cwd(pid):
        try:
            return os.readlink("/proc/%d/cwd" % pid)
        except OSError:
            pass
        try:   # Mac：没有 /proc
            out = subprocess.run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"], capture_output=True, text=True, timeout=5).stdout
            return next((l[1:] for l in out.splitlines() if l.startswith("n")), None)
        except (OSError, subprocess.SubprocessError):
            return None

    def newest_in(cwd, exclude):
        """这个工作目录下最近更新的会话（还没被别的进程占的）"""
        best = None
        try:
            with open(os.path.join(KIMI_HOME, "session_index.jsonl"), "rb") as handle:
                rows = [json.loads(raw) for raw in handle if raw.strip()]
        except (OSError, ValueError):
            rows = []
        for row in rows:
            if not isinstance(row, dict) or row.get("workDir") != cwd or row.get("sessionId") in exclude:
                continue
            state = read_json(os.path.join(row.get("sessionDir") or "", "state.json")) or {}
            if state.get("archived"):
                continue
            stamp = state.get("updatedAt") or 0
            if best is None or stamp > best[0]:
                best = (stamp, row["sessionId"])
        return best[1] if best else None

    def https_context():
        context = ssl.create_default_context()
        try:
            import certifi
            context.load_verify_locations(certifi.where())
        except Exception:   # noqa: BLE001 —— 没有 certifi 就只用系统的
            pass
        return context

    def access_token():
        """Kimi Code 登录后存在本机的令牌（credentials/*.json 里的 access_token，没过期的）；用钥匙串存的拿不到"""
        best = None
        for path in glob.glob(os.path.join(KIMI_HOME, "credentials", "*.json")):
            record = read_json(path)
            if not isinstance(record, dict) or not record.get("access_token"):
                continue
            expires = record.get("expires_at") or 0
            expires = expires / 1000.0 if expires > 1e11 else expires
            if expires and expires < time.time():
                continue
            if best is None or expires > best[0]:
                best = (expires, record["access_token"])
        return best[1] if best else None

    def base_url():
        config = kl.read_text(os.path.join(KIMI_HOME, "config.toml")) or ""
        override = os.environ.get("KIMI_CODE_BASE_URL")
        if override:
            return override.rstrip("/")
        # 登录的是国际站（api.kimi.ai）时，托管的服务地址写在配置里
        return "https://api.kimi.ai/coding/v1" if "api.kimi.ai" in config else "https://api.kimi.com/coding/v1"

    class KimiCode(kl.AgentPlugin):
        name = "Kimi Code"

        def __init__(self):
            self.pids = {}
            self.pending = {}     # 会话 id → 还没答的确认（interaction.request）
            self.limit_cache = (0, None)

        normalize = staticmethod(kimi_normalize)

        def normalizer_for(self, path):
            return lambda offset, entry: kimi_normalize(offset, entry, path)

        def detect(self):
            command = shutil.which("kimi")
            return {"installed": os.path.isdir(KIMI_HOME) or bool(command), "forms": {"cli": ""} if command else {}}

        def live(self):
            """开着的会话 → (pid, 锁文件内容)。锁文件只在一轮进行中才有（11-04 实测 2.5.0），空闲的会话靠进程认：
            进程名 kimi-code → 在 tmux 里就从屏幕历史找欢迎框的「Session: session_…」，不然取它工作目录下最近的会话"""
            found, taken = {}, set()
            for lock in glob.glob(os.path.join(KIMI_HOME, "locks", "sessions", "*.lock")):
                record = read_json(lock)
                try:
                    pid = int(record["pid"])
                except (KeyError, TypeError, ValueError):
                    continue
                if kl.pid_alive(pid):
                    found[os.path.basename(lock)[:-len(".lock")]] = (pid, record)
                    taken.add(pid)
            for pid, cwd in kimi_processes().items():
                if pid in taken:
                    continue
                sid = None
                pane = term_pane(pid)
                if pane:
                    hits = SESSION_LINE.findall(term_screen(pane, 5000) or "")
                    sid = hits[-1] if hits else None
                if not sid and cwd:
                    sid = newest_in(cwd, set(found))
                if sid and sid not in found:
                    found[sid] = (pid, {})
            return found

        def sessions(self):
            out = []
            now = int(time.time() * 1000)
            for sid, (pid, record) in self.live().items():
                folder = session_dir(sid)
                if not folder:
                    continue
                state = read_json(os.path.join(folder, "state.json")) or {}
                wire = os.path.join(folder, "agents", "main", "wire.jsonl")
                note = scan(wire) if os.path.isfile(wire) else scan("")
                updated = int(os.path.getmtime(wire) * 1000) if os.path.isfile(wire) else int(state.get("updatedAt") or now)
                cwd = state.get("cwd") or ""
                tmux = term_pane(pid)
                self.pids[sid] = pid
                pending = note["pending"]
                self.pending[sid] = pending
                pending_tool, pending_id = None, None
                if pending:
                    request = pending.get("request") if isinstance(pending.get("request"), dict) else {}
                    if pending.get("kind") == "question":
                        pending_tool, reason, waiting = "AskUserQuestion", "等待回答提问", "等待你回答"
                    else:
                        pending_tool, args = tool_of(request.get("toolName"), display_args(request.get("display")))
                        reason, waiting = "等待确认：%s" % kl.tool_brief(pending_tool, args), "等待你确认 %s" % pending_tool
                    pending_id = pending.get("toolCallId")
                    activity = "waiting"
                elif note["busy"]:
                    activity, reason, waiting = "busy", "正在工作", None
                else:
                    activity, reason, waiting = "idle", note["message"], None
                title = state.get("title") if state.get("title") and state.get("titleKind") != "placeholder" else None
                title = (title or note["first"] or state.get("lastPrompt") or sid[8:16])[:60]
                client = record.get("clientIdentity") or "kimi_code_cli"
                out.append({
                    "pid": pid, "sessionId": sid, "name": title, "title": title, "cwd": cwd, "cwdShort": kl.display_cwd(cwd),
                    "status": activity, "waitingFor": waiting, "needs": None, "detail": None, "activity": activity, "reason": reason,
                    "activityText": None, "message": note["message"], "messageUuid": note["messageId"], "error": None, "effort": None,
                    "subagents": 0, "pendingTool": pending_tool, "pendingId": pending_id,
                    "startedAt": record.get("startedAt") or state.get("createdAt"), "statusUpdatedAt": None,
                    "updatedAt": updated, "version": None, "entrypoint": "kimi-" + ("cli" if "cli" in client else client),
                    "sessionKind": None, "tmuxPane": tmux, "usage": None, "transcriptPath": wire if os.path.isfile(wire) else None,
                    "transcriptUpdatedAt": updated, "agent": "kimi-code", "model": note["model"],
                    "readOnly": not tmux, "readOnlyReason": None if tmux else READ_ONLY[0],
                    "readOnlyReasonEn": None if tmux else READ_ONLY[1],
                })
            return out

        def pending_options(self, snap):
            if snap.get("readOnly") or snap.get("pendingTool") in ("AskUserQuestion", "ExitPlanMode"):
                return None
            return OPTIONS

        def _pid(self, sid):
            pid = self.pids.get(sid)
            if not pid or not term_pane(pid):
                raise RuntimeError("这个 Kimi Code 会话不在 tmux 里运行，只能查看；在 tmux 中启动 kimi 后，就可以从手机回复和确认")
            return pid

        def send(self, sid, text, images):
            if images:
                text = (text + "\n" + "\n".join("@" + p for p in images)).strip()
            kl.tmux_send(self._pid(sid), text, [], True)
            return "已发送"

        def key(self, sid, key):
            # 等审批：1 / 2 / 3；没有待确认时 Esc 中断这一轮
            kl.tmux_send(self._pid(sid), "", [key], False)
            return "已选择" if key not in ("esc", "escape") else "已发送 Esc"

        def answer(self, sid, answers):
            pid = self._pid(sid)
            pending = self.pending.get(sid)
            if not pending or pending.get("kind") != "question":
                raise RuntimeError("这个 Kimi Code 会话现在没有待回答的提问")
            questions = (pending.get("request") or {}).get("questions") or []
            keys = []
            for index, question in enumerate(questions):
                labels = [o.get("label") for o in question.get("options") or [] if isinstance(o, dict)]
                picked = kl._answer_for(answers, question.get("question"), index)
                choice = next((p for p in picked if p in labels), None)
                if choice is None:
                    raise RuntimeError("Kimi Code 的提问暂不支持从手机填写自定义答案，请从选项中选择")
                number = labels.index(choice) + 1
                if number > 4:
                    raise RuntimeError("这个选项需要在电脑上选择")
                keys.append(str(number))
            # 每题按序号，最后在「Ready to submit」那页回车提交
            for key in keys:
                kl.tmux_send(pid, "", [key], False)
                time.sleep(0.3)
            kl.tmux_send(pid, "", [], True)
            return "已回答"

        def close(self, sid):
            pid = self._pid(sid)
            if self.pending.get(sid):
                raise RuntimeError("Kimi Code 正在等你确认。终端中的会话需输入 /exit 并按回车才能关闭，此时回车会替你选中确认菜单中的选项，"
                                   "因此会话未关闭。请先在确认卡片中作出选择，再关闭会话")
            kl.tmux_send(pid, "/exit", [], True)
            return "已关闭会话"

        def usage(self, since_ms):
            out = []
            for path in kl.recent_files([os.path.join(KIMI_HOME, "sessions")], ".jsonl", since_ms):
                if os.path.basename(path) == "wire.jsonl" and os.path.basename(os.path.dirname(path)) == "main":
                    out.extend(r for r in kl.cached_usage(path, usage_scan) if r["ts"] + 3600000 > since_ms)
            return out

        def limits(self):
            on = getattr(self, "option_on", None)
            if not on or not on("usage"):
                return None
            at, cached = self.limit_cache
            if time.time() - at < LIMIT_TTL:
                return cached
            result = None
            token = access_token()
            if token:
                try:
                    request = urllib.request.Request(base_url() + "/usages", headers={
                        "Authorization": "Bearer " + token, "Accept": "application/json"})
                    with urllib.request.urlopen(request, timeout=8, context=https_context()) as response:
                        result = self.parse_limits(json.loads(response.read().decode("utf-8")))
                except Exception:   # noqa: BLE001 —— 查不到就不显示，过一会再试
                    result = None
            self.limit_cache = (time.time(), result)
            return result

        @staticmethod
        def parse_limits(payload):
            """/usages 的返回 → 规范 4.5 的格式（used_ratio 是 0~1 的比例）"""
            if not isinstance(payload, dict):
                return None
            usages = payload.get("usages") if isinstance(payload.get("usages"), dict) else {}
            windows = []
            for key, kind in (("limit_5h", "five_hour"), ("limit_7d", "seven_day"), ("limit_month_total", "month")):
                entry = usages.get(key)
                if not isinstance(entry, dict):
                    continue
                try:
                    ratio = float(entry.get("used_ratio"))
                except (TypeError, ValueError):
                    continue
                window = {"kind": kind, "percent": round(ratio * 100 if ratio <= 1.0 else ratio, 1)}
                reset = kl.parse_ts(entry.get("reset_time")) if isinstance(entry.get("reset_time"), str) else None
                if reset:
                    window["resetsAt"] = reset
                windows.append(window)
            balances = []
            wallet = payload.get("boosterWallet") if isinstance(payload.get("boosterWallet"), dict) else {}
            balance = wallet.get("balance") if isinstance(wallet.get("balance"), dict) else {}
            if balance.get("type") == "BOOSTER":
                try:
                    left = int(balance.get("amountLeft") or 0) / 1e6 / 100.0
                    currency = ((wallet.get("monthlyChargeLimit") or {}).get("currency") or
                                (wallet.get("monthlyUsed") or {}).get("currency") or "USD")
                    balances.append({"currency": currency, "amount": "%.2f" % left, "kind": "main"})
                except (TypeError, ValueError):
                    pass
            if not windows and not balances:
                return None
            return {"at": int(time.time() * 1000), "windows": windows, "balances": balances}

    return KimiCode()
