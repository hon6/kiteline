"""oh-my-pi（can1357/oh-my-pi，pi 的分支，npm 包 @oh-my-pi/pi-coding-agent，命令 omp，跑在 Bun 上）：单独下发的插件。
GitHub issue #1 用户问「支持 oh my pi 的 agent 吗」。照 pi 插件改，区别都是 11-23 对 19.1.0 实测出来的（隔离 HOME + 假模型
tools/agent-probe/fakellm.py，~/.omp/agent/models.json 配 openai-completions 自定义地址，不用账号）：
  数据在 ~/.omp/agent（--profile 名字 → ~/.omp/profiles/<名字>/agent）；会话 sessions/--<工作目录的真实路径，/ 换成 ->--/<时间>_<id>.jsonl。
  第一行是 {"type":"title", title, pad}（自动起的标题，原地改写、用空格补齐长度，行偏移不变），第二行才是 {"type":"session"}；
  之后的条目和 pi 一样（message：user / assistant / toolResult……），另有 custom（工具开始执行、提醒等内部记录）、model_usage 等。
  model_change 记的是 "model": "提供方/模型"。用户的话前面带 <system-reminder>（日期、目录），显示时去掉。
  进程：bun …/omp（Windows 上是 bun.exe …/@oh-my-pi/pi-coding-agent/dist/cli.js）；另有后台工作进程 bun.exe …/cli.js __omp_worker_daemon，要排除。注意 pi 插件按 pi-coding-agent 认进程，要排除 oh-my-pi。
  界面：忙时「Working…」（单字符省略号）；Esc 中断；空闲时输入框上方是「π >」（新会话还有「to change thinking effort」提示，接着旧会话没有）；提问工具 ask（参数同 AskUserQuestion），
  界面是选项列表 + Other + Submit，单题回车即提交，第 k 项 = ↓ 按 k-1 次再回车；退出 /quit。
  第一次运行有六步设置向导（登录、选模型……，⎋ 跳过），后台运行时遇到它交给用户处理。
用量：每条 assistant 带 usage（同 pi）。
"""
import glob
import json
import os
import shutil
import subprocess
import time

TOOLS = {"bash": "Bash", "read": "Read", "edit": "Edit", "write": "Write", "grep": "Grep", "find": "Glob", "ls": "LS",
         "ask": "AskUserQuestion"}
TAIL_BYTES = 512 * 1024
BUSY_MARKS = ("Working…", "Working...")
ASK_MARK = "Other: type your own"
READ_ONLY = (("找不到 oh-my-pi 所在的终端窗口，只能查看；请在电脑上回复",
              "Couldn't find the terminal window oh-my-pi is running in, so this session is view-only. Reply on your computer.")
             if os.name == "nt" else
             ("oh-my-pi 不在 tmux 中运行，只能查看；在 tmux 中启动 omp，或在 Kiteline 新建任务时选择 oh-my-pi（由 Kiteline 在后台运行）后即可从手机回复、回答和中断",
              "oh-my-pi isn't running in tmux, so this session is view-only. Start omp in tmux, or choose oh-my-pi when creating a task in Kiteline (it runs in the background), to reply, answer and interrupt from your phone."))


def is_busy(text):
    return any(mark in (text or "") for mark in BUSY_MARKS)


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
    # Windows 控制台上的回复、回答、中断：11-23 Win11 实测通过（认会话、发消息、忙时插话、中断、回答提问、关闭；后台工作进程不认）
    WINDOWS_TESTED = True

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

    OMP_HOME = os.path.join(kl.HOME, ".omp")
    AGENT_DIR = os.path.join(OMP_HOME, "agent")
    # 还没发第一句的新会话没有记录文件：给它一份空文件，手机上照常打开、发第一句
    EMPTY = os.path.join(kl.DATA_DIR, "omp-new-session.jsonl")

    def agent_dirs():
        """默认的 + 各 --profile 的数据目录"""
        return [AGENT_DIR] + sorted(glob.glob(os.path.join(OMP_HOME, "profiles", "*", "agent")))

    def read_json(path):
        try:
            return json.loads(kl.read_text(path) or "")
        except (ValueError, TypeError):
            return None

    def custom_dir(cwd=None):
        """omp 的会话目录改走写在 config.yml 里：暂不跟（插件说明里写了）"""
        return None

    def cwd_dirs(cwd):
        """按工作目录分的会话目录（omp 用真实路径，Mac 上 /tmp 记成 /private/tmp）"""
        out = []
        for real in dict.fromkeys((os.path.realpath(cwd), cwd)):
            safe = real.lstrip("/\\")
            for ch in "/\\:":
                safe = safe.replace(ch, "-")
            out.extend(os.path.join(base, "sessions", "--%s--" % safe) for base in agent_dirs())
        return out

    def session_roots():
        return [os.path.join(base, "sessions") for base in agent_dirs()]

    def head_lines(path, count=3):
        out = []
        try:
            with open(path, "rb") as handle:
                for _ in range(count):
                    raw = handle.readline()
                    if not raw:
                        break
                    try:
                        entry = json.loads(raw)
                    except ValueError:
                        continue
                    if isinstance(entry, dict):
                        out.append(entry)
        except OSError:
            pass
        return out

    def header(path):
        """{"type":"session"} 那行：omp 在它前面有一行标题"""
        return next((e for e in head_lines(path) if e.get("type") == "session"), {})

    def title_of(path):
        return next((str(e.get("title") or "").strip() for e in head_lines(path, 1) if e.get("type") == "title"), "") or None

    def candidates(cwd):
        """这个工作目录的会话文件 → [(修改时间, 路径)]"""
        out = []
        # 拿不到工作目录（Windows 没有 /proc、lsof）：所有目录都算，靠启动时间挑
        folders = cwd_dirs(cwd) if cwd else [f for root in session_roots() for f in glob.glob(os.path.join(root, "*"))]
        extra = custom_dir(cwd)
        if extra:
            folders.append(extra)
        for folder in folders:
            for path in glob.glob(os.path.join(folder, "*.jsonl")):
                if folder == extra and cwd and header(path).get("cwd") not in (cwd, os.path.realpath(cwd)):
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
                "updated": 0, "ask": None}
        if path == EMPTY:
            return note
        note["name"] = title_of(path)
        for raw in tail_lines(path):
            try:
                entry = json.loads(raw)
            except ValueError:
                continue
            kind = entry.get("type") if isinstance(entry, dict) else None
            if kind == "session_info":
                note["name"] = entry.get("name") or None
            elif kind == "model_change":
                model = entry.get("modelId") or entry.get("model")
                note["model"] = (model.split("/", 1)[-1] if isinstance(model, str) else None) or note["model"]
            elif kind != "message":
                continue
            message = entry.get("message") if isinstance(entry.get("message"), dict) else {}
            role = message.get("role")
            if role == "user":
                note["first"] = note["first"] or kl.strip_reminders(text_of(message.get("content"))).strip() or None
                note["busy"], note["error"] = True, None
            elif role == "toolResult":
                note["busy"] = True
                if note["ask"] and note["ask"]["id"] == message.get("toolCallId"):
                    note["ask"] = None
            elif role == "assistant":
                note["model"] = message.get("model") or note["model"]
                text = text_of(message.get("content")).strip()
                if text:
                    note["message"], note["messageId"] = text, entry.get("id")
                stop = message.get("stopReason")
                note["busy"] = stop == "toolUse"
                for part in message.get("content") or [] if isinstance(message.get("content"), list) else []:
                    if isinstance(part, dict) and part.get("type") == "toolCall" and part.get("name") == "ask":
                        args = part.get("arguments") if isinstance(part.get("arguments"), dict) else {}
                        note["ask"] = {"id": part.get("id"), "questions": [q for q in args.get("questions") or [] if isinstance(q, dict)]}
                note["error"] = message.get("errorMessage") if stop == "error" else None
        if not note["first"]:
            # 只读了文件末尾：第一句从头找
            try:
                with open(path, "rb") as handle:
                    for raw in handle:
                        if b'"role":"user"' not in raw or b'"attribution":"user"' not in raw:
                            continue
                        message = (json.loads(raw).get("message") or {})
                        note["first"] = kl.strip_reminders(text_of(message.get("content"))).strip() or None
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
                if b'"usage"' not in raw or (b'"assistant"' not in raw and b'"model_usage"' not in raw):
                    continue
                try:
                    entry = json.loads(raw)
                except ValueError:
                    continue
                message = entry.get("message") if isinstance(entry, dict) else None
                if isinstance(entry, dict) and entry.get("type") == "model_usage":
                    # 输入预测、起标题这些辅助调用：omp 单独记一行 model_usage，也是真实用量
                    message = {"usage": entry.get("usage"), "model": entry.get("model"), "timestamp": None}
                usage = message.get("usage") if isinstance(message, dict) and isinstance(message.get("usage"), dict) else None
                if not usage:
                    continue
                ts = message.get("timestamp") or kl.parse_ts(entry.get("timestamp")) or 0
                total = (usage.get("cost") or {}).get("total") if isinstance(usage.get("cost"), dict) else None
                values = (usage.get("input"), usage.get("output"), usage.get("cacheRead"), usage.get("cacheWrite"), 1)
                if not any(values[:4]):
                    continue   # 还没出字就被中断的那次：pi 记一条全 0 的，不算一次请求
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

    def is_omp(cmd):
        parts = cmd.split()
        if "__omp_" in cmd:
            return False   # omp 自己的后台工作进程（bun.exe …/cli.js __omp_worker_daemon），不是会话
        # 编译成单文件的 omp，或 bun …/omp（npm / bun 全局装的是 Bun 脚本，进程名是 bun）
        for exe in parts[:2]:
            if os.path.basename(exe).lower() in ("omp", "omp.exe", "omp.cmd"):
                return parts[0] == exe or os.path.basename(parts[0]).lower() in ("bun", "bun.exe", "node", "node.exe")
        return "oh-my-pi" in cmd and "pi-coding-agent" in cmd and "cli.js" in cmd

    def pi_processes():
        """本机的 omp 进程 → (工作目录, 启动时间)"""
        found = {}
        for pid, cmd, start in ps_rows():
            if not is_omp(cmd):
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

    class OhMyPi(kl.AgentPlugin):
        name = "oh-my-pi"

        def __init__(self):
            self.pids = {}
            self.asks = {}

        normalize = staticmethod(pi_normalize)

        def launch(self, cwd, resume=None):
            """Kiteline 在自己的后台伪终端里起 omp 的配方（中台 hosted_start 带 agent 时调）。字样照 omp 19.1（11-23）实测的画面写；
            第一次运行的设置向导（登录、选模型）交给用户在终端里做完"""
            if resume and not (4 <= len(str(resume)) <= 128 and all(c.isalnum() or c in "_.:-" for c in str(resume))):
                return None
            return {"argv": ["omp"] + (["--resume", str(resume)] if resume else []),
                    "ready": ["to change thinking effort", " π > "], "needsUser": ["exit setup"], "settle": 1.0}

        def detect(self):
            command = shutil.which("omp")
            return {"installed": os.path.isdir(AGENT_DIR) or bool(command), "forms": {"cli": ""} if command else {}}

        def live(self):
            """开着的 omp → {会话 id: (pid, 记录文件)}。按工作目录找这个进程启动后写过的最新会话文件；
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
                    out["omp-new-%d" % pid] = (pid, EMPTY, cwd)
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
                ask = note["ask"]
                text = screen(pane) if pane else None
                if text is not None:
                    busy = is_busy(text)   # 有界面就以界面为准（中断、出错时记录可能还没写）
                    if ask and ASK_MARK not in text:
                        ask = None   # 记录里的提问已经在界面上答掉了（结果还没写盘）
                self.asks[sid] = ask
                waiting, pending_tool, pending_id = None, None, None
                if ask:
                    activity, reason, waiting = "waiting", "等待回答提问", "等待你回答"
                    pending_tool, pending_id = "AskUserQuestion", ask["id"]
                elif busy:
                    activity, reason = "busy", "正在工作"
                else:
                    activity, reason = "idle", note["message"]
                new = path == EMPTY
                title = (note["name"] or note["first"] or ("新会话" if new else sid[:8]))[:60]
                updated = note["updated"] or now
                out.append({
                    "pid": pid, "sessionId": sid, "name": title, "title": title, "cwd": cwd, "cwdShort": kl.display_cwd(cwd),
                    "status": activity, "waitingFor": waiting, "needs": None, "detail": None, "activity": activity, "reason": reason,
                    "activityText": None, "message": note["message"], "messageUuid": note["messageId"],
                    "error": note["error"] if not busy else None, "effort": None, "subagents": 0, "pendingTool": pending_tool,
                    "pendingId": pending_id,
                    "startedAt": kl.parse_ts(head.get("timestamp")) if head.get("timestamp") else None,
                    "statusUpdatedAt": None, "updatedAt": updated, "version": None, "entrypoint": "omp-cli", "sessionKind": None,
                    "tmuxPane": pane, "usage": None, "transcriptPath": path, "transcriptUpdatedAt": updated, "agent": "oh-my-pi",
                    "model": note["model"], "readOnly": not pane, "readOnlyReason": None if pane else READ_ONLY[0],
                    "readOnlyReasonEn": None if pane else READ_ONLY[1],
                })
            return out

        def abilities(self):
            return ["view", "reply", "answer", "interrupt"]   # key() 只用来中断：omp 没有确认框

        def pending_options(self, snap):
            return None

        def _pid(self, sid):
            pid = self.pids.get(sid)
            pane = term_pane(pid) if pid else None
            if not pane:
                raise RuntimeError("这个 oh-my-pi 会话不在 tmux 里运行，只能查看；在 tmux 中启动 omp，或在 Kiteline 新建任务时选择 oh-my-pi（由 Kiteline 在后台运行）后，就可以从手机回复、回答和中断")
            return pid, pane

        def send(self, sid, text, images):
            pid, _ = self._pid(sid)
            if images:
                # 交互界面里附图只能贴剪贴板：把图片路径随消息发过去，omp 的 read 工具能读图（手机上照常显示成图片）
                text = (text + "\n" + "\n".join(kl.ATTACH_PREFIX + p for p in images)).strip()
            kl.tmux_send(pid, text, [], True)   # 忙时回车 = steering，omp 自己排着
            return "已发送"

        def answer(self, sid, answers):
            """提问面板：第 k 个选项 = ↓ 按 k-1 次再回车（单题回车即提交）。自己填写、多选、一次多个问题的没实测，请用户在电脑上答"""
            pid, pane = self._pid(sid)
            ask = self.asks.get(sid)
            if not ask or ASK_MARK not in (screen(pane) or ""):
                raise RuntimeError("这个 oh-my-pi 会话现在没有待回答的提问")
            questions = ask["questions"]
            if len(questions) != 1 or questions[0].get("multiSelect") or questions[0].get("multi"):
                raise RuntimeError("这个提问有多个问题或可以多选，请在电脑上的 oh-my-pi 中回答")
            question = questions[0]
            labels = [o.get("label") if isinstance(o, dict) else o for o in question.get("options") or []]
            picked = kl._answer_for(answers, question.get("question"), 0)
            choice = next((p for p in picked if p in labels), None)
            if choice is None:
                raise RuntimeError("oh-my-pi 的提问暂不支持从手机填写自定义答案，请从选项中选择，或在电脑上回答")
            for _ in range(labels.index(choice)):
                term_keys(pane, "Down")
                time.sleep(0.15)
            term_keys(pane, "Enter")
            self.asks.pop(sid, None)
            return "已回答"

        def key(self, sid, key):
            pid, pane = self._pid(sid)
            if str(key).lower() not in ("esc", "escape"):
                raise RuntimeError("oh-my-pi 没有确认框，不支持这个按键：%s" % key)
            if not is_busy(screen(pane)):
                return "当前没有进行中的任务"
            term_keys(pane, "Escape")
            time.sleep(0.5)
            # 中断时排着的话被放回输入框：清掉，免得下一条接在后面
            term_keys(pane, "C-u")
            return "已中断"

        def close(self, sid):
            pid, pane = self._pid(sid)
            if is_busy(screen(pane)):
                raise RuntimeError("oh-my-pi 正在工作。请先中断，再关闭会话")
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

    return OhMyPi()
