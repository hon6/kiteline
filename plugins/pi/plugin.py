"""pi（badlogic/pi-mono 的终端编程 agent，npm 包 @mariozechner/pi-coding-agent，命令 pi）：单独下发的插件。

11-09 对 0.73.0 实测（隔离 HOME + 假模型 tools/agent-probe/fakellm.py，~/.pi/agent/models.json 配 openai-completions 自定义地址，不用账号）：
  会话 ~/.pi/agent/sessions/--<工作目录，/ 换成 ->--/<时间>_<uuid>.jsonl（PI_CODING_AGENT_DIR 改 ~/.pi/agent；
  会话目录可由 PI_CODING_AGENT_SESSION_DIR 或 settings.json 的 sessionDir 改走，那时文件直接放在那个目录里）。
  第一行 {"type":"session", id, cwd, timestamp}，之后每行一个条目（id / parentId 连成树，/tree 换分支时旧分支也留在文件里）：
    message       message.role = user / assistant（content：text、thinking、toolCall；usage、stopReason stop / toolUse / aborted / error）/
                  toolResult（toolCallId、content、isError）/ bashExecution（用户的 ! 命令）/ custom（扩展插进来的）
    model_change、thinking_level_change、compaction（上下文压缩）、branch_summary、session_info（/name 起的名字）……
  第一句话发出去才建文件；进程不一直开着它，只能按进程的工作目录 + 启动时间对上。进程名就是 pi（它自己设了 process.title）。
  界面：忙时「Working...」；Esc 中断（这条回复记成 stopReason aborted，忙时排着的话被放回输入框）；
  忙时回车发的话是 steering，等这一步工具做完就插进去；/quit 退出。
  没有确认框（官方就是不弹，靠扩展自己做）、没有提问工具；交互界面里附图只能从剪贴板贴，「@路径」只是文字引用。
用量：每条 assistant 带 usage（input 不含读缓存、cacheRead、cacheWrite、cost.total 按 pi 自带的价目表算的美元）。
"""
import glob
import json
import os
import shutil
import subprocess
import time

TOOLS = {"bash": "Bash", "read": "Read", "edit": "Edit", "write": "Write", "grep": "Grep", "find": "Glob", "ls": "LS"}
TAIL_BYTES = 512 * 1024
BUSY_MARK = "Working..."
READ_ONLY = (("Windows 上从手机操作 pi 还没实测，暂未开放，只能查看；请在电脑上回复",
              "Controlling pi on Windows from your phone isn't tested yet, so it isn't available and this session is view-only. Reply on your computer.")
             if os.name == "nt" else
             ("pi 不在 tmux 中运行，只能查看；在 tmux 中启动 pi 后即可从手机回复和中断",
              "pi isn't running in tmux, so this session is view-only. Start pi in tmux to reply and interrupt from your phone."))


def create(kl):
    def ps_rows():
        """[(进程号, 命令行, 启动时间秒或 None)]：中台的跨平台进程列举（HOST_CAPS proc.list）；老中台退回 ps"""
        if hasattr(kl, "process_list"):
            return [(p["pid"], p["cmd"], p.get("start")) for p in kl.process_list()]
        try:
            out = subprocess.run(["ps", "-axww", "-o", "pid=,command="], capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            return []
        rows = []
        for line in out.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2 and parts[0].isdigit():
                rows.append((int(parts[0]), parts[1], None))
        return rows

    _term_pane = getattr(kl, "term_pane", None) or kl.find_tmux_pane
    # Windows 控制台上的回复、中断：在 Win11 真机实测过才开放（11-05：没测过的不放出来）
    WINDOWS_TESTED = False

    def term_pane(pid):
        pane = _term_pane(pid)
        if pane and str(pane).startswith("console:") and not WINDOWS_TESTED:
            return None
        return pane

    def term_screen(pane):
        if hasattr(kl, "term_screen"):
            return kl.term_screen(pane)
        try:
            return subprocess.run(["tmux", "capture-pane", "-p", "-J", "-t", pane], capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            return ""

    def term_keys(pane, *names):
        if hasattr(kl, "term_keys"):
            return kl.term_keys(pane, *names)
        for name in names:
            subprocess.run(["tmux", "send-keys", "-t", pane, name], timeout=5)

    AGENT_DIR = os.path.expanduser(os.environ.get("PI_CODING_AGENT_DIR") or os.path.join(kl.HOME, ".pi", "agent"))
    DEFAULT_SESSIONS = os.path.join(AGENT_DIR, "sessions")
    # 还没发第一句的新会话没有记录文件：给它一份空文件，手机上照常打开、发第一句
    EMPTY = os.path.join(kl.DATA_DIR, "pi-new-session.jsonl")

    def read_json(path):
        try:
            return json.loads(kl.read_text(path) or "")
        except (ValueError, TypeError):
            return None

    def custom_dir(cwd=None):
        """改走的会话目录：环境变量 > 项目 .pi/settings.json > 全局 settings.json（相对路径按工作目录算）"""
        value = os.environ.get("PI_CODING_AGENT_SESSION_DIR")
        if not value and cwd:
            value = (read_json(os.path.join(cwd, ".pi", "settings.json")) or {}).get("sessionDir")
        if not value:
            value = (read_json(os.path.join(AGENT_DIR, "settings.json")) or {}).get("sessionDir")
        if not isinstance(value, str) or not value:
            return None
        value = os.path.expanduser(value)
        return value if os.path.isabs(value) else os.path.join(cwd or kl.HOME, value)

    def cwd_dir(cwd):
        """pi 默认按工作目录分的会话目录（getDefaultSessionDir）"""
        safe = cwd.lstrip("/\\")
        for ch in "/\\:":
            safe = safe.replace(ch, "-")
        return os.path.join(DEFAULT_SESSIONS, "--%s--" % safe)

    def session_roots():
        roots = [DEFAULT_SESSIONS]
        extra = custom_dir()
        if extra and extra not in roots:
            roots.append(extra)
        return roots

    def header(path):
        try:
            with open(path, "rb") as handle:
                entry = json.loads(handle.readline() or b"{}")
        except (OSError, ValueError):
            return {}
        return entry if isinstance(entry, dict) and entry.get("type") == "session" else {}

    def candidates(cwd):
        """这个工作目录的会话文件 → [(修改时间, 路径)]"""
        out = []
        folders = [cwd_dir(cwd)] if cwd else []
        extra = custom_dir(cwd)
        if extra:
            folders.append(extra)
        for folder in folders:
            for path in glob.glob(os.path.join(folder, "*.jsonl")):
                if folder == extra and cwd and header(path).get("cwd") != cwd:
                    continue
                try:
                    out.append((os.path.getmtime(path), path))
                except OSError:
                    pass
        return out

    def sid_of(path):
        return header(path).get("id") or os.path.basename(path)[:-len(".jsonl")].rpartition("_")[2]

    def tail_lines(path, size=TAIL_BYTES):
        try:
            total = os.path.getsize(path)
            with open(path, "rb") as handle:
                handle.seek(max(0, total - size))
                return handle.read().splitlines()
        except OSError:
            return []

    def text_of(content):
        if isinstance(content, str):
            return content
        return "\n".join(part.get("text") or "" for part in content or []
                         if isinstance(part, dict) and part.get("type") == "text" and isinstance(part.get("text"), str))

    def images_of(content, offset):
        """记录里的图片（用户从剪贴板贴的、read 工具读的图）→ 图片引用，取图走 media()"""
        refs = []
        for part in content if isinstance(content, list) else []:
            if isinstance(part, dict) and part.get("type") == "image" and isinstance(part.get("data"), str):
                refs.append({"ref": "%d.%d" % (offset, len(refs)), "mime": part.get("mimeType") or "image/png",
                             "bytes": len(part["data"]) * 3 // 4})
        return refs

    def tool_of(name, args):
        mapped = TOOLS.get(name, name or "tool")
        args = dict(args) if isinstance(args, dict) else {}
        if mapped in ("Read", "Write", "Edit") and "path" in args:
            args["file_path"] = args.pop("path")
        if mapped == "Edit" and isinstance(args.get("edits"), list):
            edits = [e for e in args.pop("edits") if isinstance(e, dict)]
            if len(edits) == 1:
                args["old_string"], args["new_string"] = edits[0].get("oldText") or "", edits[0].get("newText") or ""
            else:
                mapped = "MultiEdit"
                args["edits"] = [{"old_string": e.get("oldText") or "", "new_string": e.get("newText") or ""} for e in edits]
        return mapped, args

    def pi_normalize(offset, entry):
        """会话文件一行 → 对话项"""
        if not isinstance(entry, dict):
            return []
        kind = entry.get("type")
        message = entry.get("message") if isinstance(entry.get("message"), dict) else {}
        ts = message.get("timestamp") if isinstance(message.get("timestamp"), (int, float)) else kl.parse_ts(entry.get("timestamp"))
        items = []

        def base():
            return {"id": "%d.%d" % (offset, len(items)), "ts": int(ts) if ts else None}

        if kind == "compaction":
            items.append(dict(base(), t="event", text="上下文已压缩"))
            return items
        if kind == "branch_summary":
            items.append(dict(base(), t="event", text="已切换到另一个分支", detail=kl.clip(entry.get("summary") or "", 2000)[0] or None))
            return items
        if kind != "message":
            return items
        role = message.get("role")
        content = message.get("content")
        if role == "user":
            text, attached = kl.split_attachments(text_of(content))
            text = kl.clip(kl.strip_reminders(text).strip(), kl.USER_TEXT_MAX)[0]
            images = images_of(content, offset) + attached
            if text or images:
                item = dict(base(), t="user", text=text)
                if images:
                    item["images"] = images
                items.append(item)
        elif role == "assistant":
            for part in content if isinstance(content, list) else []:
                if not isinstance(part, dict):
                    continue
                if part.get("type") == "text" and (part.get("text") or "").strip():
                    items.append(dict(base(), t="text", text=kl.clip(part["text"].strip(), kl.ASSISTANT_TEXT_MAX)[0]))
                elif part.get("type") == "thinking" and (part.get("thinking") or "").strip():
                    items.append(dict(base(), t="thinking", text=kl.clip(part["thinking"].strip(), kl.ASSISTANT_TEXT_MAX)[0]))
                elif part.get("type") == "toolCall":
                    name, args = tool_of(part.get("name"), part.get("arguments"))
                    items.append(dict(base(), t="tool", toolId=part.get("id"), name=name,
                                      brief=kl.tool_brief(name, args), input=kl.shrink(args)))
            if message.get("stopReason") == "aborted":
                items.append(dict(base(), t="event", text="已中断"))
            elif message.get("stopReason") == "error" and message.get("errorMessage"):
                items.append(dict(base(), t="event", text="出错：%s" % kl.clip(message["errorMessage"], 300)[0]))
        elif role == "toolResult":
            item = dict(base(), t="result", toolId=message.get("toolCallId"), text=kl.clip(text_of(content), kl.TOOL_RESULT_MAX)[0],
                        isError=bool(message.get("isError")))
            images = images_of(content, offset)
            if images:
                item["images"] = images
            items.append(item)
        elif role == "bashExecution":
            # 用户在 pi 里用 ! 跑的命令
            tid = "bash-%d" % offset
            args = {"command": message.get("command") or ""}
            items.append(dict(base(), t="tool", toolId=tid, name="Bash", brief=kl.tool_brief("Bash", args), input=args))
            items.append(dict(base(), t="result", toolId=tid, text=kl.clip(message.get("output") or "", kl.TOOL_RESULT_MAX)[0],
                              isError=bool(message.get("exitCode"))))
        elif role == "custom" and message.get("display"):
            text = text_of(content).strip()
            if text:
                items.append(dict(base(), t="event", text=kl.clip(text, 300)[0]))
        return items

    def scan(path):
        """会话文件 → 标题、第一句、最后一句回复、模型、按记录看忙不忙、出错原因"""
        note = {"first": None, "name": None, "message": None, "messageId": None, "model": None, "busy": False, "error": None,
                "updated": 0}
        if path == EMPTY:
            return note
        for raw in tail_lines(path):
            try:
                entry = json.loads(raw)
            except ValueError:
                continue
            kind = entry.get("type") if isinstance(entry, dict) else None
            if kind == "session_info":
                note["name"] = entry.get("name") or None
            elif kind == "model_change":
                note["model"] = entry.get("modelId") or note["model"]
            elif kind != "message":
                continue
            message = entry.get("message") if isinstance(entry.get("message"), dict) else {}
            role = message.get("role")
            if role == "user":
                note["first"] = note["first"] or text_of(message.get("content")).strip() or None
                note["busy"], note["error"] = True, None
            elif role == "toolResult":
                note["busy"] = True
            elif role == "assistant":
                note["model"] = message.get("model") or note["model"]
                text = text_of(message.get("content")).strip()
                if text:
                    note["message"], note["messageId"] = text, entry.get("id")
                stop = message.get("stopReason")
                note["busy"] = stop == "toolUse"
                note["error"] = message.get("errorMessage") if stop == "error" else None
        if not note["first"]:
            # 只读了文件末尾：第一句从头找
            try:
                with open(path, "rb") as handle:
                    for raw in handle:
                        if b'"role":"user"' not in raw:
                            continue
                        message = (json.loads(raw).get("message") or {})
                        note["first"] = text_of(message.get("content")).strip() or None
                        break
            except (OSError, ValueError):
                pass
        try:
            note["updated"] = int(os.path.getmtime(path) * 1000)
        except OSError:
            pass
        return note

    def usage_scan(path):
        """一份会话文件的 token 和花费：每条 assistant 的 usage（input 本来就不含读缓存）"""
        buckets = {}
        head = header(path)
        cwd, sid = head.get("cwd"), head.get("id") or sid_of(path)
        try:
            handle = open(path, "rb")
        except OSError:
            return []
        with handle:
            for raw in handle:
                if b'"usage"' not in raw or b'"assistant"' not in raw:
                    continue
                try:
                    entry = json.loads(raw)
                except ValueError:
                    continue
                message = entry.get("message") if isinstance(entry, dict) else None
                usage = message.get("usage") if isinstance(message, dict) and isinstance(message.get("usage"), dict) else None
                if not usage:
                    continue
                ts = message.get("timestamp") or kl.parse_ts(entry.get("timestamp")) or 0
                total = (usage.get("cost") or {}).get("total") if isinstance(usage.get("cost"), dict) else None
                values = (usage.get("input"), usage.get("output"), usage.get("cacheRead"), usage.get("cacheWrite"), 1)
                # 价目表里没有的模型（自定义服务）pi 记 0：当作没有花费数据
                kl.usage_bucket(buckets, int(ts), message.get("model") or "unknown", values,
                                cost=total if total else None, cwd=cwd, session=sid)
        return list(buckets.values())

    _cwds = {}   # pid → 工作目录（进程活着时不会变）

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

    def is_pi(cmd):
        exe = cmd.split()[0] if cmd.split() else ""
        if os.path.basename(exe) in ("pi", "pi.exe"):
            return True
        # Windows 上 process.title 只改控制台标题：命令行还是 node …\pi-coding-agent\dist\cli.js
        return "pi-coding-agent" in cmd and "cli.js" in cmd

    def pi_processes():
        """本机的 pi 进程 → (工作目录, 启动时间)"""
        found = {}
        for pid, cmd, start in ps_rows():
            if not is_pi(cmd):
                continue
            if pid not in _cwds:
                _cwds[pid] = process_cwd(pid)
            found[pid] = (_cwds[pid], start)
        for pid in list(_cwds):
            if pid not in found:
                _cwds.pop(pid, None)
        return found

    def screen(pane):
        out = term_screen(pane)
        if not out:
            return None
        return "\n".join(out.rstrip().splitlines()[-25:])

    class Pi(kl.AgentPlugin):
        name = "pi"

        def __init__(self):
            self.pids = {}

        normalize = staticmethod(pi_normalize)

        def detect(self):
            command = shutil.which("pi")
            return {"installed": os.path.isdir(AGENT_DIR) or bool(command), "forms": {"cli": ""} if command else {}}

        def live(self):
            """开着的 pi → {会话 id: (pid, 记录文件)}。按工作目录找这个进程启动后写过的最新会话文件；
            还没发第一句的（没有文件、或用 -c / -r 接着旧会话还没说话）先算一个新会话"""
            out, taken = {}, set()
            procs = sorted(pi_processes().items(), key=lambda item: -(item[1][1] or 0))   # 后启动的先挑
            for pid, (cwd, start) in procs:
                files = sorted((c for c in candidates(cwd) if c[1] not in taken and (not start or c[0] >= start - 2)), reverse=True)
                if files:
                    path = files[0][1]
                    taken.add(path)
                    out[sid_of(path)] = (pid, path, cwd)
                else:
                    out["pi-new-%d" % pid] = (pid, EMPTY, cwd)
            return out

        def sessions(self):
            out = []
            now = int(time.time() * 1000)
            live = self.live()
            if any(path == EMPTY for _, path, _ in live.values()) and not os.path.isfile(EMPTY):
                try:
                    os.makedirs(os.path.dirname(EMPTY), exist_ok=True)
                    open(EMPTY, "a").close()
                except OSError:
                    pass
            self.pids = {}
            for sid, (pid, path, cwd) in live.items():
                note = scan(path)
                head = header(path) if path != EMPTY else {}
                cwd = head.get("cwd") or cwd or ""
                pane = term_pane(pid)
                self.pids[sid] = pid
                busy = note["busy"]
                text = screen(pane) if pane else None
                if text is not None:
                    busy = BUSY_MARK in text   # 有界面就以界面为准（中断、出错时记录可能还没写）
                if busy:
                    activity, reason = "busy", "正在工作"
                else:
                    activity, reason = "idle", note["message"]
                new = path == EMPTY
                title = (note["name"] or note["first"] or ("新会话" if new else sid[:8]))[:60]
                updated = note["updated"] or now
                out.append({
                    "pid": pid, "sessionId": sid, "name": title, "title": title, "cwd": cwd, "cwdShort": kl.display_cwd(cwd),
                    "status": activity, "waitingFor": None, "needs": None, "detail": None, "activity": activity, "reason": reason,
                    "activityText": None, "message": note["message"], "messageUuid": note["messageId"],
                    "error": note["error"] if not busy else None, "effort": None, "subagents": 0, "pendingTool": None, "pendingId": None,
                    "startedAt": kl.parse_ts(head.get("timestamp")) if head.get("timestamp") else None,
                    "statusUpdatedAt": None, "updatedAt": updated, "version": None, "entrypoint": "pi-cli", "sessionKind": None,
                    "tmuxPane": pane, "usage": None, "transcriptPath": path, "transcriptUpdatedAt": updated, "agent": "pi",
                    "model": note["model"], "readOnly": not pane, "readOnlyReason": None if pane else READ_ONLY[0],
                    "readOnlyReasonEn": None if pane else READ_ONLY[1],
                })
            return out

        def abilities(self):
            return ["view", "reply", "interrupt"]   # key() 只用来中断：pi 没有确认框

        def pending_options(self, snap):
            return None

        def _pid(self, sid):
            pid = self.pids.get(sid)
            pane = term_pane(pid) if pid else None
            if not pane:
                raise RuntimeError("这个 pi 会话不在 tmux 里运行，只能查看；在 tmux 中启动 pi 后，就可以从手机回复和中断")
            return pid, pane

        def send(self, sid, text, images):
            pid, _ = self._pid(sid)
            if images:
                # 交互界面里附图只能贴剪贴板：把图片路径随消息发过去，pi 的 read 工具能读图（手机上照常显示成图片）
                text = (text + "\n" + "\n".join(kl.ATTACH_PREFIX + p for p in images)).strip()
            kl.tmux_send(pid, text, [], True)   # 忙时回车 = steering，pi 自己排着
            return "已发送"

        def key(self, sid, key):
            pid, pane = self._pid(sid)
            if str(key).lower() not in ("esc", "escape"):
                raise RuntimeError("pi 没有确认框，不支持这个按键：%s" % key)
            if BUSY_MARK not in (screen(pane) or ""):
                return "当前没有进行中的任务"
            term_keys(pane, "Escape")
            time.sleep(0.5)
            # 中断时排着的话被放回输入框：清掉，免得下一条接在后面
            term_keys(pane, "C-u")
            return "已中断"

        def close(self, sid):
            pid, pane = self._pid(sid)
            if BUSY_MARK in (screen(pane) or ""):
                raise RuntimeError("pi 正在工作。请先中断，再关闭会话")
            term_keys(pane, "C-u")
            kl.tmux_send(pid, "/quit", [], True)
            for _ in range(10):
                time.sleep(0.3)
                if not kl.pid_alive(pid):
                    return "已关闭会话"
            if "/quit" in (screen(pane) or ""):   # 命令补全框吃掉了第一下回车
                term_keys(pane, "Enter")
            return "已关闭会话"

        def media(self, sid, ref, path):
            offset_text, _, index_text = ref.partition(".")
            if not path or not offset_text.isdigit() or not index_text.isdigit():
                return None
            entry = kl.parse_line(kl.read_line_at(path, int(offset_text)) or b"")
            content = (((entry or {}).get("message") or {}).get("content")) if isinstance(entry, dict) else None
            blocks = [p for p in content or [] if isinstance(p, dict) and p.get("type") == "image"] if isinstance(content, list) else []
            index = int(index_text)
            if index >= len(blocks):
                raise RuntimeError("图片不存在：%s" % ref)
            return {"mime": blocks[index].get("mimeType") or "image/png", "data": blocks[index].get("data") or ""}

        def usage(self, since_ms):
            out = []
            for path in kl.recent_files(session_roots(), ".jsonl", since_ms):
                out.extend(r for r in kl.cached_usage(path, usage_scan) if r["ts"] + 3600000 > since_ms)
            return out

    return Pi()
