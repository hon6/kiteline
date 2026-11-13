"""Muse Code（Meta 的终端编程 agent，命令 muse）：单独下发的插件。

11-05 对 Muse Code 1.4.14（Linux，官方安装清单里的包、sha256 核对过）实测。它的模型目录接口不公开，接不了假模型，
用自带的 echo 服务商（--provider echo --echo-delay-ms，原样回话、不调工具，不用账号）测了会话、记录、忙闲、回复、中断、关闭；
工具调用和确认框没能实测（要 Meta 账号或 API Key）：
  数据目录 $XDG_DATA_HOME/muse（默认 ~/.local/share/muse；Mac 也认 ~/Library/Application Support/muse，Windows %LOCALAPPDATA%\\muse）：
    runtime/muse/sessions/<会话 id>.json   开着的会话：session_id、process_generation_hint（"pid=123"）、workspace_label
    sessions/<年>/<月>/<日>/<会话 id>/session.jsonl   追加写的事件日志，一行一条：sequence、recorded_at（微秒）、payload_type、payload
      runtime.session.route_facts     record.cwd
      session.name.changed            new_name（自动起的名字，如 hazel-comet）
      runtime.session（payload.kind = run）的 event.kind：
        started（prompt = 用户的话）、reasoning_committed / assistant_message_committed（text、message_id）、
        model_completed（usage：input_tokens、cached_tokens、output_tokens、reasoning_tokens）、
        terminal（terminal = completed / cancelled / failed）、run_retracted（中断时没出字：把那句话放回输入框）
  界面：忙时状态行有「esc to interrupt」，Esc 中断（中断后它把那句话放回输入框，Ctrl+U 清掉）；/exit 空闲时退出。
  确认框按官方文档的字样（Allow once / Reject）认出来，只用来显示「等你在电脑上确认」；从手机确认要真实账号实测后再开放。
额度：`muse usage` 能看订阅额度，要登录；本机不记。
"""
import glob
import json
import os
import re
import subprocess
import time

BUSY_MARK = "esc to interrupt"
APPROVAL_WORDS = ("Allow once", "Reject")
READ_ONLY = (("Windows 上从手机操作 Muse Code 还没实测，暂未开放，只能查看；请在电脑上回复和确认", "Controlling Muse Code on Windows from your phone isn't tested yet, so it isn't available and this session is view-only. Reply and confirm on your computer.")
             if os.name == "nt" else
             ("Muse Code 不在 tmux 中运行，只能查看；在 tmux 中启动 muse，或在 Kiteline 新建任务时选择 Muse Code（由 Kiteline 在后台运行）后即可从手机回复和确认",
              "Muse Code isn't running in tmux, so this session is view-only. Start muse in tmux, or choose Muse Code when creating a task in Kiteline (it runs in the background), to reply and confirm from your phone."))
# 从手机确认命令还没用真实账号实测：确认框出来时这一会话按只读处理、请用户回电脑确认，实测通过后再开放（换成 pending_options + key）
WAITING_LOCAL = ("Muse Code 正在等你确认命令。从手机确认 Muse 的命令还没实测，暂未开放，请在电脑上确认",
                 "Muse Code is waiting for you to confirm a command. Confirming Muse commands from your phone isn't tested yet, so it isn't available; please confirm on your computer.")
TOOL_KINDS = ("tool_call_committed", "tool_call_started", "tool_call_requested")
RESULT_KINDS = ("tool_result_committed",)


def create(kl):
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

    def data_dirs():
        out = []
        if os.environ.get("MUSE_DATA_DIR"):
            out.append(os.environ["MUSE_DATA_DIR"])
        if os.environ.get("XDG_DATA_HOME"):
            out.append(os.path.join(os.environ["XDG_DATA_HOME"], "muse"))
        out.append(os.path.join(kl.HOME, ".local", "share", "muse"))
        out.append(os.path.join(kl.HOME, "Library", "Application Support", "muse"))
        if os.environ.get("LOCALAPPDATA"):
            out.append(os.path.join(os.environ["LOCALAPPDATA"], "muse"))
        seen = []
        for path in out:
            if path not in seen and os.path.isdir(path):
                seen.append(path)
        return seen

    def run_event(entry):
        """一行日志 → (event.kind, event)；不是主会话的 run 事件返回 (None, {})"""
        if not isinstance(entry, dict) or entry.get("payload_type") != "runtime.session":
            return None, {}
        payload = entry.get("payload") if isinstance(entry.get("payload"), dict) else {}
        event = payload.get("event") if isinstance(payload.get("event"), dict) else {}
        if payload.get("kind") != "run" and not event.get("prompt"):
            return None, {}
        return event.get("kind"), event

    def ts_of(entry):
        value = entry.get("recorded_at")
        return int(value) // 1000 if isinstance(value, (int, float)) else None

    def tool_of(event):
        call = event.get("tool_call") if isinstance(event.get("tool_call"), dict) else event
        name = call.get("name") or call.get("tool_name") or "tool"
        args = call.get("arguments") if "arguments" in call else call.get("input")
        if isinstance(args, str):
            try:
                args = json.loads(args)
            except ValueError:
                args = {"input": args}
        mapped = {"shell": "Bash", "exec_command": "Bash", "read_file": "Read", "apply_patch": "Edit", "write_file": "Write"}.get(name, name)
        args = dict(args) if isinstance(args, dict) else {}
        if mapped == "Bash" and "cmd" in args:
            args["command"] = args.pop("cmd")
        return mapped, args, call.get("call_id") or call.get("tool_call_id") or call.get("id")

    def muse_normalize(offset, entry):
        kind, event = run_event(entry)
        if not kind:
            return []
        ts = ts_of(entry)
        items = []

        def base():
            return {"id": "%s.%d" % (entry.get("sequence", offset), len(items)), "ts": ts}

        if kind == "started" and isinstance(event.get("prompt"), str):
            text, _ = kl.clip(kl.strip_reminders(event["prompt"]).strip(), kl.USER_TEXT_MAX)
            if text:
                items.append(dict(base(), t="user", text=text))
        elif kind in ("assistant_message_committed", "reasoning_committed"):
            text = (event.get("text") or "").strip()
            if text and not (kind == "reasoning_committed" and text == "thinking"):
                items.append(dict(base(), t="text" if kind == "assistant_message_committed" else "thinking",
                                  text=kl.clip(text, kl.ASSISTANT_TEXT_MAX)[0]))
        elif kind in TOOL_KINDS:
            name, args, call_id = tool_of(event)
            items.append(dict(base(), t="tool", toolId=call_id, name=name, brief=kl.tool_brief(name, args), input=kl.shrink(args)))
        elif kind in RESULT_KINDS:
            output = event.get("output") if "output" in event else event.get("result")
            if not isinstance(output, str):
                output = json.dumps(output, ensure_ascii=False) if output is not None else ""
            items.append(dict(base(), t="result", toolId=event.get("call_id") or event.get("tool_call_id"),
                              text=kl.clip(output, kl.TOOL_RESULT_MAX)[0], isError=bool(event.get("is_error"))))
        elif kind == "terminal" and event.get("terminal") == "cancelled":
            items.append(dict(base(), t="event", text="已中断"))
        elif kind == "terminal" and event.get("terminal") == "failed":
            items.append(dict(base(), t="event", text="出错：%s" % (event.get("reason") or "")))
        return items

    def tail_entries(path, size=512 * 1024):
        try:
            total = os.path.getsize(path)
            with open(path, "rb") as handle:
                handle.seek(max(0, total - size))
                raw = handle.read().splitlines()
        except OSError:
            return []
        out = []
        for line in raw:
            if b'"sequence"' not in line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if isinstance(entry, dict):
                out.append(entry)
        return out

    def head_facts(path):
        """日志开头：工作目录、服务商、自动起的名字"""
        facts = {"cwd": None, "provider": None, "name": None}
        try:
            with open(path, "rb") as handle:
                for index, raw in enumerate(handle):
                    if index > 400:
                        break
                    if b"route_facts" not in raw and b"session.name.changed" not in raw and b"runtime.session.metadata" not in raw:
                        continue
                    try:
                        entry = json.loads(raw)
                    except ValueError:
                        continue
                    payload = entry.get("payload") if isinstance(entry.get("payload"), dict) else {}
                    record = payload.get("record") if isinstance(payload.get("record"), dict) else {}
                    if payload.get("kind") == "route_facts":
                        facts["cwd"] = record.get("cwd")
                    elif payload.get("kind") == "metadata":
                        facts["provider"] = record.get("provider_id")
                    elif entry.get("payload_type") == "session.name.changed":
                        facts["name"] = payload.get("new_name")
        except OSError:
            pass
        return facts

    def scan(path):
        note = {"first": None, "message": None, "messageId": None, "busy": False, "model": None, "updated": 0}
        for entry in tail_entries(path):
            kind, event = run_event(entry)
            if entry.get("payload_type") == "session.name.changed":
                note["name"] = (entry.get("payload") or {}).get("new_name")
            if kind == "started" and isinstance(event.get("prompt"), str):
                note["first"] = note["first"] or event["prompt"].strip()
                note["busy"] = True
            elif kind == "assistant_message_committed" and (event.get("text") or "").strip():
                note["message"], note["messageId"] = event["text"].strip(), "%s.0" % entry.get("sequence")
            elif kind == "terminal":
                note["busy"] = False
            elif kind == "model_request_configured" and event.get("model"):
                note["model"] = event.get("model")
        try:
            note["updated"] = int(os.path.getmtime(path) * 1000)
        except OSError:
            pass
        return note

    def usage_scan(path):
        """一份 session.jsonl 的 token：每次 model_completed 一次请求；input_tokens 按 OpenAI 口径含读缓存，减掉"""
        buckets = {}
        facts = head_facts(path)
        sid = os.path.basename(os.path.dirname(path))
        model = facts["provider"] or "muse"
        try:
            handle = open(path, "rb")
        except OSError:
            return []
        with handle:
            for raw in handle:
                if b'"model_completed"' not in raw:
                    continue
                try:
                    entry = json.loads(raw)
                except ValueError:
                    continue
                kind, event = run_event(entry)
                usage = event.get("usage") if kind == "model_completed" and isinstance(event.get("usage"), dict) else None
                ts = ts_of(entry)
                if not usage or not ts:
                    continue
                cached = int(usage.get("cached_tokens") or 0)
                values = (max(0, int(usage.get("input_tokens") or 0) - cached), usage.get("output_tokens"), cached, 0, 1)
                if any(values[:3]):
                    kl.usage_bucket(buckets, ts, event.get("model") or model, values, cwd=facts["cwd"], session=sid)
        return list(buckets.values())

    def session_log(sid):
        for data in data_dirs():
            found = glob.glob(os.path.join(data, "sessions", "*", "*", "*", sid, "session.jsonl"))
            if found:
                return found[0]
        return None

    def live_sessions():
        """runtime 登记的、进程还在的会话 → (会话 id, pid)"""
        out = []
        for data in data_dirs():
            for path in glob.glob(os.path.join(data, "runtime", "*", "sessions", "*.json")):
                try:
                    record = json.loads(kl.read_text(path) or "")
                except ValueError:
                    continue
                sid = record.get("session_id") if isinstance(record, dict) else None
                found = re.search(r"pid=(\d+)", str(record.get("process_generation_hint") or "")) if sid else None
                if found and kl.pid_alive(int(found.group(1))):
                    out.append((sid, int(found.group(1))))
        return out

    def screen(pane):
        out = term_screen(pane)
        if not out:
            return None
        return "\n".join(out.rstrip().splitlines()[-30:])

    def approval_open(text):
        return all(word in (text or "") for word in APPROVAL_WORDS)

    class MuseCode(kl.AgentPlugin):
        name = "Muse Code"

        def __init__(self):
            self.pids = {}

        normalize = staticmethod(muse_normalize)

        def abilities(self):
            return ["view", "reply"]   # 确认命令暂未开放；中断不在这张清单里

        def launch(self, cwd, resume=None):
            """Kiteline 在自己的后台伪终端里起 Muse Code 的配方（中台 hosted_start 带 agent 时调）：不用用户自己开 tmux，
            起来以后读屏、发字、按键都走通用终端层。字样照 muse 1.4.14（11-13） 实测的画面写（比较时不分大小写）"""
            if resume and not (4 <= len(str(resume)) <= 128 and all(c.isalnum() or c in "_.:-" for c in str(resume))):
                return None
            return {"argv": ["muse", "resume", str(resume)] if resume else ["muse"],
                    # 输入提示符（信任框、登录画面里都没有它）
                    "ready": ["\u276f"],
                    # 第一次在这个文件夹里跑会问信不信任它（默认选中「Trust and continue」）：用户在 Kiteline 里选了这个项目开任务，回车
                    "answers": [{"when": "do you trust this workspace?", "keys": ["Enter"]}],
                    # 没登录时停在选登录方式上：要用户本人在终端里登录
                    "needsUser": ["log in with browser", "set an api key"],
                    "settle": 1.0}

        def detect(self):
            import shutil
            command = shutil.which("muse")
            return {"installed": bool(command) or bool(data_dirs()), "forms": {"cli": ""} if command else {}}

        def sessions(self):
            out = []
            now = int(time.time() * 1000)
            for sid, pid in live_sessions():
                path = session_log(sid)
                if not path:
                    continue
                facts = head_facts(path)
                note = scan(path)
                pane = term_pane(pid)
                self.pids[sid] = pid
                busy, waiting = note["busy"], False
                text = screen(pane) if pane else None
                if text is not None:
                    waiting = approval_open(text)
                    busy = BUSY_MARK in text or waiting
                if waiting:
                    activity, reason, waiting_for, pending_tool = "waiting", "等待确认", "等待你确认", "Bash"
                elif busy:
                    activity, reason, waiting_for, pending_tool = "busy", "正在工作", None, None
                else:
                    activity, reason, waiting_for, pending_tool = "idle", note["message"], None, None
                cwd = facts["cwd"] or ""
                title = (note.get("name") or facts["name"] or note["first"] or sid[:8])[:60]
                out.append({
                    "pid": pid, "sessionId": sid, "name": title, "title": title, "cwd": cwd, "cwdShort": kl.display_cwd(cwd),
                    "status": activity, "waitingFor": waiting_for, "needs": None, "detail": None, "activity": activity,
                    "reason": reason, "activityText": None, "message": note["message"], "messageUuid": note["messageId"],
                    "error": None, "effort": None, "subagents": 0, "pendingTool": pending_tool,
                    "pendingId": ("approval-%d" % note["updated"]) if waiting else None, "startedAt": None,
                    "statusUpdatedAt": None, "updatedAt": note["updated"] or now, "version": None, "entrypoint": "muse",
                    "sessionKind": None, "tmuxPane": pane, "usage": None, "transcriptPath": path,
                    "transcriptUpdatedAt": note["updated"] or now, "agent": "muse-code",
                    "model": note["model"] or (facts["provider"] if facts["provider"] not in (None, "meta") else None),
                    "readOnly": not pane or waiting,
                    "readOnlyReason": (WAITING_LOCAL if waiting else READ_ONLY)[0] if (waiting or not pane) else None,
                    "readOnlyReasonEn": (WAITING_LOCAL if waiting else READ_ONLY)[1] if (waiting or not pane) else None,
                })
            return out

        def pending_options(self, snap):
            return None   # 确认暂未开放（见 WAITING_LOCAL）

        def _pane(self, sid):
            pid = self.pids.get(sid)
            pane = term_pane(pid) if pid else None
            if not pane:
                raise RuntimeError("这个 Muse Code 会话不在 tmux 里运行，只能查看；在 tmux 中启动 muse，或在 Kiteline 新建任务时选择 Muse Code（由 Kiteline 在后台运行）后，就可以从手机回复和确认")
            return pid, pane

        def send(self, sid, text, images):
            pid, _ = self._pane(sid)
            if images:
                text = (text + "\n" + "\n".join("@" + p for p in images)).strip()
            # 忙时回车是插话（steer），Muse 会接着这一轮做
            kl.tmux_send(pid, text, [], True)
            return "已发送"

        def key(self, sid, key):
            _, pane = self._pane(sid)
            key = str(key).lower()
            text = screen(pane) or ""
            if key in ("esc", "escape"):
                if BUSY_MARK not in text:
                    return "当前没有进行中的任务"
                term_keys(pane, "Escape")
                time.sleep(0.6)
                # 还没出字就中断时，Muse 把那句话放回输入框：清掉，免得下一条接在后面
                term_keys(pane, "C-u")
                return "已中断"
            raise RuntimeError("从手机确认 Muse Code 的命令还没实测，暂未开放，请在电脑上确认")

        def close(self, sid):
            pid, pane = self._pane(sid)
            text = screen(pane) or ""
            if approval_open(text):
                raise RuntimeError("Muse Code 正在等你确认。请先在卡片中作出选择，再关闭会话")
            if BUSY_MARK in text:
                raise RuntimeError("Muse Code 正在工作，空闲时才能退出。请先中断，再关闭会话")
            kl.tmux_send(pid, "/exit", [], True)
            return "已关闭会话"

        def usage(self, since_ms):
            out = []
            folders = [os.path.join(data, "sessions") for data in data_dirs()]
            for path in kl.recent_files(folders, "session.jsonl", since_ms):
                if os.sep + "subagent" + os.sep in path:
                    continue
                out.extend(r for r in kl.cached_usage(path, usage_scan) if r["ts"] + 3600000 > since_ms)
            return out

    return MuseCode()
