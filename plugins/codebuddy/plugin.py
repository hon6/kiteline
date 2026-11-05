"""CodeBuddy Code / WorkBuddy（腾讯的编程 agent，命令 codebuddy / cbc；WorkBuddy 桌面版用同一个内核）：单独下发的插件。

11-05 对 CodeBuddy Code 2.179.3 实测（隔离 HOME + 假模型：CODEBUDDY_BASE_URL / CODEBUDDY_API_KEY 指过去就行，不用登录）：
  ~/.codebuddy/（WorkBuddy 是 ~/.workbuddy，国际版 ~/.workbuddy-ai；CODEBUDDY_CONFIG_DIR 改目录）
    sessions/<pid>.json                  开着的会话：pid、sessionId、cwd、startedAt、kind（interactive……）、version、url（本机 Remote Control 网页）
    projects/<cwd 去掉开头的 / 再把 / 换成 ->/<sessionId>.jsonl   对话记录，一行一条，实时写，时间是毫秒：
        message（role user：content 里 input_text；role assistant：output_text，status incomplete + 「Interrupted by user」是中断）
        function_call（callId、name、arguments JSON 字符串）/ function_call_result（callId、status、output.text）
        ai-title（aiTitle）、turn-metrics（一轮结束）、file-history-snapshot、session-meta、summary
        助手条目的 providerData.usage：inputTokens（含读缓存）、inputTokensDetails[].cached_tokens、outputTokens；同一次请求的几条共用 messageId
  工具名同 Claude Code；默认工具模式「PTC」时所有工具经 REPL（写代码调），记录里是 REPL 调用。
  确认框同 Claude Code：1 允许 / 2 本会话都允许 / 3 拒绝（Esc）；提问框方向键选、回车，最后「Submit answers」再回车；Esc 中断；/exit 退出。
回复、确认、中断：在 tmux 里跑的会话经 tmux 发字、按键；WorkBuddy 桌面版和不在 tmux 里的只能看。
额度：积分制，只能在网页「用量」页看，本机不记、没有查询接口。
"""
import glob
import json
import os
import re
import shutil
import subprocess
import time

TAIL_BYTES = 512 * 1024
READ_ONLY = (("Windows 上从手机操作 CodeBuddy Code 还没实测，暂未开放，只能查看；请在电脑上回复和确认", "Controlling CodeBuddy Code on Windows from your phone isn't tested yet, so it isn't available and this session is view-only. Reply and confirm on your computer.")
             if os.name == "nt" else
             ("不在 tmux 中运行（或在 WorkBuddy 桌面版中），只能查看；在 tmux 中启动 codebuddy 后即可从手机回复和确认",
              "Not running in tmux (or running in the WorkBuddy desktop app), so this session is view-only. "
              "Start codebuddy in tmux to reply and confirm from your phone."))
OPTIONS = ({"key": "3", "label": "拒绝", "labelEn": "Deny", "style": "destructive"},
           {"key": "1", "label": "允许", "labelEn": "Allow", "style": "primary"},
           {"key": "2", "label": "允许，且本会话不再询问", "labelEn": "Allow for this session", "style": "normal"})
APPROVAL_MARK = "Do you want to proceed"
QUESTION_MARK = "Enter to select · ↑/↓ to navigate"
BUSY_MARKS = ("esc to interrupt", "Esc to interrupt", "ESC to interrupt")


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

    def homes():
        """各品牌的数据目录：(目录, 品牌名)"""
        out = []
        if os.environ.get("CODEBUDDY_CONFIG_DIR"):
            out.append((os.environ["CODEBUDDY_CONFIG_DIR"], "CodeBuddy"))
        for name, brand in ((".codebuddy", "CodeBuddy"), (".workbuddy", "WorkBuddy"), (".workbuddy-ai", "WorkBuddy")):
            path = os.path.join(kl.HOME, name)
            if path not in [p for p, _ in out]:
                out.append((path, brand))
        return out

    def read_json(path):
        try:
            return json.loads(kl.read_text(path) or "")
        except (ValueError, TypeError):
            return None

    def transcript(home, cwd, sid):
        path = os.path.join(home, "projects", (cwd or "").lstrip("/").replace("/", "-").replace("\\", "-").replace(":", ""), sid + ".jsonl")
        if os.path.isfile(path):
            return path
        found = glob.glob(os.path.join(home, "projects", "*", sid + ".jsonl"))
        return found[0] if found else None

    def text_of(content, kinds=("input_text", "output_text", "text")):
        if isinstance(content, str):
            return content
        if isinstance(content, dict):
            content = [content]
        return "\n".join(p.get("text") for p in content or [] if isinstance(p, dict) and p.get("type") in kinds and isinstance(p.get("text"), str))

    def args_of(entry):
        raw = entry.get("arguments")
        if isinstance(raw, dict):
            return raw
        try:
            value = json.loads(raw or "{}")
            return value if isinstance(value, dict) else {"arguments": value}
        except ValueError:
            return {"arguments": raw}

    def cb_normalize(offset, entry):
        if not isinstance(entry, dict):
            return []
        kind = entry.get("type")
        ts = entry.get("timestamp") if isinstance(entry.get("timestamp"), (int, float)) else None
        items = []

        def base():
            return {"id": "%d.%d" % (offset, len(items)), "ts": int(ts) if ts else None}

        if kind == "message" and entry.get("role") == "user":
            text, _ = kl.clip(kl.strip_reminders(text_of(entry.get("content"))).strip(), kl.USER_TEXT_MAX)
            if text and not (entry.get("providerData") or {}).get("isMeta"):
                items.append(dict(base(), t="user", text=text))
        elif kind == "message" and entry.get("role") == "assistant":
            text = text_of(entry.get("content")).strip()
            if entry.get("status") == "incomplete" and text == "Interrupted by user":
                items.append(dict(base(), t="event", text="已中断"))
            elif text:
                items.append(dict(base(), t="text", text=kl.clip(text, kl.ASSISTANT_TEXT_MAX)[0]))
        elif kind == "reasoning":
            text = text_of(entry.get("summary") or entry.get("content"), ("summary_text", "reasoning_text", "text")).strip()
            if text:
                items.append(dict(base(), t="thinking", text=kl.clip(text, kl.ASSISTANT_TEXT_MAX)[0]))
        elif kind == "function_call":
            name, args = entry.get("name") or "tool", args_of(entry)
            items.append(dict(base(), t="tool", toolId=entry.get("callId"), name=name,
                              brief=kl.tool_brief(name, args), input=kl.shrink(args)))
        elif kind == "function_call_result":
            output = entry.get("output")
            text = text_of(output) if not isinstance(output, str) else output
            items.append(dict(base(), t="result", toolId=entry.get("callId"), text=kl.clip(text, kl.TOOL_RESULT_MAX)[0],
                              isError=entry.get("status") not in (None, "completed")))
        return items

    def scan(path):
        note = {"first": None, "message": None, "messageId": None, "pending": None, "busy": False, "title": None, "model": None,
                "updated": 0}
        try:
            size = os.path.getsize(path)
            with open(path, "rb") as handle:
                handle.seek(max(0, size - TAIL_BYTES))
                lines = handle.read().splitlines()
            note["updated"] = int(os.path.getmtime(path) * 1000)
        except OSError:
            return note
        calls = {}
        for raw in lines:
            try:
                entry = json.loads(raw)
            except ValueError:
                continue
            kind = entry.get("type") if isinstance(entry, dict) else None
            if kind == "message" and entry.get("role") == "user":
                text = kl.strip_reminders(text_of(entry.get("content"))).strip()
                if text:
                    note["first"] = note["first"] or text
                    note["busy"] = True
            elif kind == "message" and entry.get("role") == "assistant":
                text = text_of(entry.get("content")).strip()
                if text and text != "Interrupted by user":
                    note["message"], note["messageId"] = text, entry.get("id")
                if entry.get("status") == "incomplete":
                    note["busy"] = False
                    calls.clear()
                model = (entry.get("providerData") or {}).get("requestModelName") or (entry.get("providerData") or {}).get("model")
                note["model"] = model or note["model"]
            elif kind == "function_call":
                calls[entry.get("callId")] = entry
                note["busy"] = True
            elif kind == "function_call_result":
                calls.pop(entry.get("callId"), None)
            elif kind == "turn-metrics":
                note["busy"] = False
                calls.clear()
            elif kind == "ai-title" and entry.get("aiTitle"):
                note["title"] = entry["aiTitle"]
        if calls:
            note["pending"] = list(calls.values())[-1]
        return note

    def usage_scan(path):
        """每次请求一份 usage（同一次请求的几条共用 messageId，只算一次），输入减掉读缓存。不记花费"""
        buckets, seen = {}, set()
        sid = os.path.basename(path)[:-len(".jsonl")]
        cwd = None
        try:
            handle = open(path, "rb")
        except OSError:
            return []
        with handle:
            for raw in handle:
                if b'"usage"' not in raw and b'"cwd"' not in raw:
                    continue
                try:
                    entry = json.loads(raw)
                except ValueError:
                    continue
                cwd = cwd or entry.get("cwd")
                data = entry.get("providerData") if isinstance(entry.get("providerData"), dict) else {}
                usage = data.get("usage") if isinstance(data.get("usage"), dict) else None
                key = data.get("messageId") or entry.get("id")
                if not usage or key in seen or not isinstance(entry.get("timestamp"), (int, float)):
                    continue
                seen.add(key)
                cached = sum(int(d.get("cached_tokens") or 0) for d in usage.get("inputTokensDetails") or [] if isinstance(d, dict))
                values = (max(0, int(usage.get("inputTokens") or 0) - cached), usage.get("outputTokens"), cached, 0,
                          usage.get("requests") or 1)
                model = data.get("requestModelName") or data.get("model") or "unknown"
                kl.usage_bucket(buckets, int(entry["timestamp"]), model, values, cwd=cwd, session=sid)
        return list(buckets.values())

    def screen(pane):
        out = term_screen(pane)
        if not out:
            return None
        return "\n".join(out.rstrip().splitlines()[-25:])

    class CodeBuddy(kl.AgentPlugin):
        name = "CodeBuddy / WorkBuddy"

        def __init__(self):
            self.pids = {}
            self.pending = {}

        normalize = staticmethod(cb_normalize)

        def detect(self):
            forms = {}
            if shutil.which("codebuddy") or shutil.which("cbc"):
                forms["cli"] = ""
            if os.path.isdir(os.path.join(kl.HOME, ".workbuddy")) or os.path.isdir(os.path.join(kl.HOME, ".workbuddy-ai")):
                forms["desktop"] = ""
            return {"installed": bool(forms) or os.path.isdir(os.path.join(kl.HOME, ".codebuddy")), "forms": forms}

        def sessions(self):
            out = []
            now = int(time.time() * 1000)
            for home, brand in homes():
                for path in glob.glob(os.path.join(home, "sessions", "*.json")):
                    record = read_json(path)
                    try:
                        pid, sid = int(record["pid"]), str(record["sessionId"])
                    except (KeyError, TypeError, ValueError):
                        continue
                    if not kl.pid_alive(pid):
                        continue
                    cwd = record.get("cwd") or ""
                    chat = transcript(home, cwd, sid)
                    note = scan(chat) if chat else scan("")
                    pane = term_pane(pid)
                    text = screen(pane) if pane else None
                    self.pids[sid] = pid
                    pending = note["pending"]
                    question = pending if pending and pending.get("name") == "AskUserQuestion" else None
                    self.pending[sid] = question
                    approval = bool(text and APPROVAL_MARK in text)
                    busy = note["busy"] and now - (note["updated"] or now) < 10 * 60 * 1000 if text is None else (
                        note["busy"] or any(mark in text for mark in BUSY_MARKS))
                    pending_tool = pending_id = waiting = None
                    if question and (text is None or QUESTION_MARK in text):
                        pending_tool, pending_id = "AskUserQuestion", question.get("callId")
                        activity, reason, waiting = "waiting", "等待回答提问", "等待你回答"
                    elif pending and approval:
                        pending_tool, args = pending.get("name") or "tool", args_of(pending)
                        pending_id = pending.get("callId")
                        activity, reason = "waiting", "等待确认：%s" % kl.tool_brief(pending_tool, args)
                        waiting = "等待你确认 %s" % pending_tool
                    elif busy:
                        activity, reason = "busy", ("正在执行 %s" % pending.get("name")) if pending else "正在工作"
                    else:
                        activity, reason = "idle", note["message"]
                    title = (note["title"] or note["first"] or sid[:8])[:60]
                    out.append({
                        "pid": pid, "sessionId": sid, "name": title, "title": title, "cwd": cwd, "cwdShort": kl.display_cwd(cwd),
                        "status": activity, "waitingFor": waiting, "needs": None, "detail": None, "activity": activity,
                        "reason": reason, "activityText": None, "message": note["message"], "messageUuid": note["messageId"],
                        "error": None, "effort": None, "subagents": 0, "pendingTool": pending_tool, "pendingId": pending_id,
                        "startedAt": record.get("startedAt"), "statusUpdatedAt": None, "updatedAt": note["updated"] or now,
                        "version": record.get("version"), "entrypoint": "%s-%s" % (brand.lower(), record.get("kind") or "cli"),
                        "sessionKind": None, "tmuxPane": pane, "usage": None, "transcriptPath": chat,
                        "transcriptUpdatedAt": note["updated"] or now, "agent": "codebuddy", "model": note["model"],
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
            pane = term_pane(pid) if pid else None
            if not pane:
                raise RuntimeError("这个会话不在 tmux 里运行，只能查看；在 tmux 中启动 codebuddy 后，就可以从手机回复和确认")
            return pid, pane

        def send(self, sid, text, images):
            pid, _ = self._pid(sid)
            if images:
                text = (text + "\n" + "\n".join("@" + p for p in images)).strip()
            kl.tmux_send(pid, text, [], True)
            return "已发送"

        def key(self, sid, key):
            pid, pane = self._pid(sid)
            key = str(key).lower()
            if key in ("esc", "escape"):
                kl.tmux_send(pid, "", ["esc"], False)
                return "已发送 Esc"
            if key not in ("1", "2", "3"):
                raise RuntimeError("不支持的选项：%s" % key)
            if APPROVAL_MARK not in (screen(pane) or ""):
                raise RuntimeError("现在没有等待确认的命令")
            kl.tmux_send(pid, "", [key], False)
            return "已选择"

        def answer(self, sid, answers):
            pid, pane = self._pid(sid)
            question = self.pending.get(sid)
            if not question or QUESTION_MARK not in (screen(pane) or ""):
                raise RuntimeError("这个会话现在没有待回答的提问")
            for index, item in enumerate(args_of(question).get("questions") or []):
                labels = [o.get("label") for o in item.get("options") or [] if isinstance(o, dict)]
                picked = kl._answer_for(answers, item.get("question"), index)
                choice = next((p for p in picked if p in labels), None)
                if choice is not None:
                    kl.tmux_send(pid, "", ["down"] * labels.index(choice) + ["enter"], False)
                else:
                    custom = next((p for p in picked if p), None)
                    if not custom:
                        raise RuntimeError("没有选择答案")
                    # 选项之后那一行「Type something」：选中后输入文字再回车
                    kl.tmux_send(pid, "", ["down"] * len(labels), False)
                    time.sleep(0.3)
                    kl.tmux_send(pid, custom, ["enter"], False)
                time.sleep(0.4)
            # 最后一页「Submit answers」：回车提交
            if "Submit answers" in (screen(pane) or ""):
                kl.tmux_send(pid, "", ["enter"], False)
            return "已回答"

        def close(self, sid):
            pid, pane = self._pid(sid)
            text = screen(pane) or ""
            if APPROVAL_MARK in text or QUESTION_MARK in text:
                raise RuntimeError("正在等你确认或回答。请先在卡片中作出选择，再关闭会话")
            kl.tmux_send(pid, "/exit", [], True)
            return "已关闭会话"

        def usage(self, since_ms):
            out = []
            for home, _ in homes():
                for path in kl.recent_files([os.path.join(home, "projects")], ".jsonl", since_ms):
                    out.extend(r for r in kl.cached_usage(path, usage_scan) if r["ts"] + 3600000 > since_ms)
            return out

    return CodeBuddy()
