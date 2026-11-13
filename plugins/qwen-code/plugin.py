"""Qwen Code（通义千问的命令行编程 agent）：第一个单独下发的插件，不随 Kiteline 发版。

Qwen Code 的文件布局和 Claude Code 几乎一样（10-24 对 0.26.0 实测）：
  ~/.qwen/sessions/<pid>.json                         开着的会话：pid、sessionId、cwd、name、startedAt、kind……
  ~/.qwen/projects/<cwd 转义>/chats/<sessionId>.jsonl  对话记录：type user / assistant / tool_result / system，
                                                     message 是 Gemini 的格式（role + parts：text、thought、functionCall、functionResponse）
看：列表、忙闲 / 等确认（最后一个工具调用还没结果）、完整对话。回复和确认：会话在 tmux 里跑时经 tmux 发字、按键（中台的 term.tmux），
不在 tmux 里就只能看（Qwen Code 自己的跨会话消息会被当成「别的会话发来的」、可能要用户先放行，不拿它当回复）。
"""
import glob
import json
import os
import re
import subprocess
import time

# Qwen 的工具 → 手机认得的工具（改动对比、任务清单这些才画得出）
TOOLS = {
    "run_shell_command": ("Bash", {}),
    "read_file": ("Read", {"absolute_path": "file_path"}),
    "read_many_files": ("Read", {}),
    "write_file": ("Write", {}),
    "edit": ("Edit", {}),
    "replace": ("Edit", {}),
    "glob": ("Glob", {}),
    "search_file_content": ("Grep", {}),
    "grep_search": ("Grep", {}),
    "list_directory": ("LS", {}),
    "todo_write": ("TodoWrite", {}),
    "web_fetch": ("WebFetch", {}),
}
TAIL_BYTES = 256 * 1024
# 终端界面忙的时候底下有「(… · esc to cancel)」；中断（Esc）不写进对话记录，只能看界面
BUSY_MARKS = ("esc to cancel", "esc 取消", "Esc 取消")
# 只读时手机输入框里的说明和英文版（1.0.1 起；Kiteline 3.49.1 / 电脑端 1.0.8 以前的客户端不认这两个字段，照旧显示「仅可查看」）
READ_ONLY = (("Windows 上没有 tmux，Qwen Code 的会话只能查看", "Windows has no tmux, so Qwen Code sessions are view-only.")
             if os.name == "nt" else
             ("Qwen Code 不在 tmux 中运行，只能查看；在 tmux 中启动 Qwen Code，或在 Kiteline 新建任务时选择 Qwen Code（由 Kiteline 在后台运行）后即可从手机回复和确认",
              "Qwen Code isn't running in tmux, so this session is view-only. Start Qwen Code in tmux, or choose Qwen Code when creating a task in Kiteline (it runs in the background), to reply and confirm from your phone."))


def pane_busy(pane):
    """tmux 窗格里的 Qwen 终端界面现在忙不忙；看不了返回 None"""
    try:
        out = subprocess.run(["tmux", "capture-pane", "-p", "-t", pane], capture_output=True, text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    tail = "\n".join(out.rstrip().splitlines()[-12:])
    return any(mark in tail for mark in BUSY_MARKS)


def create(kl):
    QWEN_HOME = os.environ.get("QWEN_HOME") or os.path.join(kl.HOME, ".qwen")

    def term_pane(pid):
        """能操作的终端：tmux 窗格，或 Kiteline 自己的后台伪终端（hosted:…，中台 term_pane，2.37 起）；
        Windows 控制台没实测，不算。老中台没有 term_pane 就只认 tmux"""
        finder = getattr(kl, "term_pane", None) or kl.find_tmux_pane
        pane = finder(pid)
        return None if not pane or str(pane).startswith("console:") else pane

    def screen_busy(pane):
        """界面现在忙不忙（底下有「esc to cancel」）；看不了返回 None"""
        if hasattr(kl, "term_screen"):
            text = kl.term_screen(pane)
            if text is None:
                return None
            tail = "\n".join(text.rstrip().splitlines()[-12:])
            return any(mark in tail for mark in BUSY_MARKS)
        return pane_busy(pane)

    def chat_path(cwd, sid):
        """对话记录：cwd 里非字母数字的字符换成 -（同 Claude Code）；对不上就在所有项目里找"""
        path = os.path.join(QWEN_HOME, "projects", re.sub(r"[^A-Za-z0-9]", "-", cwd or ""), "chats", sid + ".jsonl")
        if os.path.isfile(path):
            return path
        found = glob.glob(os.path.join(QWEN_HOME, "projects", "*", "chats", sid + ".jsonl"))
        return found[0] if found else None

    def parts(entry):
        message = entry.get("message") if isinstance(entry.get("message"), dict) else {}
        return [p for p in message.get("parts") or [] if isinstance(p, dict)]

    def tool_of(call):
        name = call.get("name") or "tool"
        mapped, rename = TOOLS.get(name, (name, {}))
        args = dict(call.get("args") or {}) if isinstance(call.get("args"), dict) else {}
        for old, new in rename.items():
            if old in args and new not in args:
                args[new] = args.pop(old)
        return mapped, args

    def qwen_normalize(offset, entry):
        """一行记录 → 对话项（格式同内置插件：user / text / thinking / tool / result）"""
        if not isinstance(entry, dict):
            return []
        kind = entry.get("type")
        ts = kl.parse_ts(entry.get("timestamp"))
        items = []

        def base():
            return {"id": "%d.%d" % (offset, len(items)), "ts": ts}

        if kind == "user" and entry.get("provenance") in (None, "real_user"):
            text = "\n".join(p.get("text") for p in parts(entry) if isinstance(p.get("text"), str))
            text, _ = kl.clip(kl.strip_reminders(text).strip(), kl.USER_TEXT_MAX)
            if text:
                items.append(dict(base(), t="user", text=text))
        elif kind == "assistant":
            for part in parts(entry):
                if isinstance(part.get("text"), str) and part["text"].strip():
                    text, _ = kl.clip(part["text"].strip(), kl.ASSISTANT_TEXT_MAX)
                    items.append(dict(base(), t="thinking" if part.get("thought") else "text", text=text))
                elif isinstance(part.get("functionCall"), dict):
                    name, args = tool_of(part["functionCall"])
                    items.append(dict(base(), t="tool", toolId=part["functionCall"].get("id"), name=name,
                                      brief=kl.tool_brief(name, args), input=kl.shrink(args)))
        elif kind == "tool_result":
            result = entry.get("toolCallResult") if isinstance(entry.get("toolCallResult"), dict) else {}
            failed = bool(result.get("error")) or result.get("status") in ("error", "cancelled")
            for part in parts(entry):
                response = part.get("functionResponse")
                if isinstance(response, dict):
                    output = (response.get("response") or {}).get("output") if isinstance(response.get("response"), dict) else response.get("response")
                    text, _ = kl.clip(output if isinstance(output, str) else json.dumps(output, ensure_ascii=False), kl.TOOL_RESULT_MAX)
                    items.append(dict(base(), t="result", toolId=response.get("id"), text=text, isError=failed))
        return items

    def scan(path):
        """记录尾巴里认出：第一句、最后一句回复、还没结果的工具调用、最后的类型"""
        note = {"first": None, "message": None, "messageId": None, "pending": None, "last": None}
        try:
            size = os.path.getsize(path)
            with open(path, "rb") as handle:
                handle.seek(max(0, size - TAIL_BYTES))
                lines = handle.read().splitlines()
        except OSError:
            return note
        calls = {}
        for raw in lines:
            try:
                entry = json.loads(raw)
            except ValueError:
                continue
            kind = entry.get("type")
            if kind == "user" and entry.get("provenance") in (None, "real_user"):
                text = " ".join(p.get("text") for p in parts(entry) if isinstance(p.get("text"), str)).strip()
                if text:
                    note["first"] = note["first"] or text
                    note["last"] = "user"
            elif kind == "assistant":
                for part in parts(entry):
                    if isinstance(part.get("text"), str) and part["text"].strip() and not part.get("thought"):
                        note["message"], note["messageId"] = part["text"].strip(), entry.get("uuid")
                    elif isinstance(part.get("functionCall"), dict):
                        calls[part["functionCall"].get("id")] = part["functionCall"]
                note["last"] = "assistant"
            elif kind == "tool_result":
                for part in parts(entry):
                    if isinstance(part.get("functionResponse"), dict):
                        calls.pop(part["functionResponse"].get("id"), None)
                result = entry.get("toolCallResult") if isinstance(entry.get("toolCallResult"), dict) else {}
                # 用户拒绝了（cancelled）：这一轮停了，不算忙
                note["last"] = "cancelled" if result.get("status") == "cancelled" else "tool_result"
        if calls:
            note["pending"] = list(calls.values())[-1]
        return note

    def usage_scan(path):
        """一份对话记录的 token 用量：每次请求一条助手记录，带 usageMetadata（Gemini 的格式：promptTokenCount 含缓存，
        cachedContentTokenCount 是读缓存；candidatesTokenCount 含不含思考看接的是哪家，所以输出按 totalTokenCount - promptTokenCount 算，
        落在 candidates ~ candidates + thoughts 之间才信，不然取 candidates）。/branch 分出来的会话把原来的记录原样抄一份（带 forkedFrom），
        跳过；同一条（uuid）只算一次。Qwen Code 不记花费"""
        buckets, seen = {}, set()
        try:
            handle = open(path, "rb")
        except OSError:
            return []
        with handle:
            for raw in handle:
                if b'"usageMetadata"' not in raw:
                    continue
                try:
                    entry = json.loads(raw.decode("utf-8", "replace"))
                except ValueError:
                    continue
                meta = entry.get("usageMetadata") if isinstance(entry, dict) else None
                if entry.get("type") != "assistant" or entry.get("forkedFrom") or not isinstance(meta, dict) or entry.get("uuid") in seen:
                    continue
                seen.add(entry.get("uuid"))
                ts = kl.parse_ts(entry.get("timestamp"))
                if ts is None:
                    continue
                prompt, cached = int(meta.get("promptTokenCount") or 0), int(meta.get("cachedContentTokenCount") or 0)
                candidates, thoughts = int(meta.get("candidatesTokenCount") or 0), int(meta.get("thoughtsTokenCount") or 0)
                total = int(meta.get("totalTokenCount") or 0)
                output = total - prompt if total and candidates <= total - prompt <= candidates + thoughts else candidates
                kl.usage_bucket(buckets, ts, entry.get("model") or "unknown", (max(0, prompt - cached), output, cached, 0, 1),
                                cwd=entry.get("cwd"), session=entry.get("sessionId"))
        return list(buckets.values())

    class QwenCode(kl.AgentPlugin):
        name = "Qwen Code"

        def __init__(self):
            self.pids = {}   # 会话 id → pid（tmux 投递用）
            self.waiting = set()   # 正在等确认的会话（关闭时不能发 /quit + 回车）

        # 类体里同名赋值读不到外层的变量：外层函数叫 qwen_normalize
        normalize = staticmethod(qwen_normalize)

        def normalizer_for(self, path):
            return qwen_normalize

        def detect(self):
            import shutil
            return {"installed": os.path.isdir(QWEN_HOME) or bool(shutil.which("qwen")), "forms": {"cli": ""} if shutil.which("qwen") else {}}

        def launch(self, cwd, resume=None):
            """Kiteline 在自己的后台伪终端里起 Qwen Code 的配方（中台 hosted_start 带 agent 时调）：不用用户自己开 tmux。
            字样照 qwen 0.27.3（11-13，中文界面和英文界面）实测的画面写（比较时不分大小写）"""
            if resume and not (4 <= len(str(resume)) <= 128 and all(c.isalnum() or c in "_.:-" for c in str(resume))):
                return None
            return {"argv": ["qwen"] + (["--resume", str(resume)] if resume else []),
                    # 输入框的提示（中文界面 / 英文界面）、底下的「Shift + Tab 切换」
                    "ready": ["输入您的消息", "type your message", "shift + tab"],
                    # 还没配置模型：停在选认证方式上（Coding Plan / 第三方 / 自定义服务），要用户本人在终端里配
                    "needsUser": ["third-party providers", "custom provider", "选择认证方式"],
                    "settle": 1.0}

        def usage(self, since_ms):
            """token 用量（用量报表）：各项目 chats 下的对话记录（见 usage_scan）；只有带用量接口的中台才会来问"""
            out = []
            for path in kl.recent_files([os.path.join(QWEN_HOME, "projects")], ".jsonl", since_ms):
                if os.path.basename(os.path.dirname(path)) == "chats":
                    out.extend(r for r in kl.cached_usage(path, usage_scan) if r["ts"] + 3600000 > since_ms)
            return out

        def sessions(self):
            out = []
            now = int(time.time() * 1000)
            for path in glob.glob(os.path.join(QWEN_HOME, "sessions", "*.json")):
                try:
                    record = json.loads(kl.read_text(path) or "")
                    pid, sid = int(record["pid"]), str(record["sessionId"])
                except (ValueError, KeyError, TypeError):
                    continue
                if not kl.pid_alive(pid):
                    continue
                cwd = record.get("cwd") or ""
                chat = chat_path(cwd, sid)
                note = scan(chat) if chat else {"first": None, "message": None, "messageId": None, "pending": None, "last": None}
                updated = int(os.path.getmtime(chat) * 1000) if chat else int(record.get("startedAt") or now)
                pending = note["pending"]
                self.pids[sid] = pid
                if note["pending"]:
                    self.waiting.add(sid)
                else:
                    self.waiting.discard(sid)
                tmux = term_pane(pid)
                # 忙不忙：在 tmux / 后台伪终端里看界面（准）；不在就看对话记录（中断看不出来，最多 10 分钟后算空闲）
                busy = screen_busy(tmux) if tmux else None
                if busy is None:
                    busy = note["last"] in ("user", "tool_result") and now - updated < 10 * 60 * 1000
                if pending:
                    tool, args = tool_of(pending)
                    activity, reason, waiting = "waiting", "等待确认：%s" % kl.tool_brief(tool, args), "等待你确认 %s" % tool
                elif busy:
                    activity, reason, waiting = "busy", "正在工作", None
                else:
                    activity, reason, waiting = "idle", note["message"], None
                title = (note["first"] or "")[:60] or record.get("name") or sid[:8]
                out.append({
                    "pid": pid, "sessionId": sid, "name": title, "title": title, "cwd": cwd, "cwdShort": kl.display_cwd(cwd),
                    "status": activity, "waitingFor": waiting, "needs": None, "detail": None, "activity": activity, "reason": reason,
                    "activityText": None, "message": note["message"], "messageUuid": note["messageId"], "error": None, "effort": None,
                    "subagents": 0, "pendingTool": tool_of(pending)[0] if pending else None,
                    "pendingId": pending.get("id") if pending else None, "startedAt": record.get("startedAt"), "statusUpdatedAt": None,
                    "updatedAt": updated, "version": record.get("qwenVersion"), "entrypoint": "qwen-" + str(record.get("kind") or "cli"),
                    "sessionKind": None, "tmuxPane": tmux, "usage": None, "transcriptPath": chat,
                    "transcriptUpdatedAt": updated, "agent": "qwen-code",
                    # 不在 tmux 里：只能看
                    "readOnly": not tmux, "readOnlyReason": None if tmux else READ_ONLY[0],
                    "readOnlyReasonEn": None if tmux else READ_ONLY[1],
                })
            return out

        def _pid(self, sid):
            pid = self.pids.get(sid)
            if not pid or not term_pane(pid):
                raise RuntimeError("这个 Qwen Code 会话不在 tmux 里运行，只能查看；在 tmux 中启动 Qwen Code 后，就可以从手机回复和确认")
            return pid

        def send(self, sid, text, images):
            if images:
                text = (text + "\n" + "\n".join("@" + p for p in images)).strip()
            kl.tmux_send(self._pid(sid), text, [], True)
            return "已发送"

        def key(self, sid, key):
            # Qwen 的确认菜单：1 允许一次、Esc 拒绝；没有待确认时 Esc 中断这一轮
            kl.tmux_send(self._pid(sid), "", [key], False)
            return "已选择" if key not in ("esc", "escape") else "已发送 Esc"

        def close(self, sid):
            # 同 Claude Code 终端里的会话发 /exit：Qwen Code 的退出命令是 /quit（/exit 是别名），退出后会话可用 qwen --resume 接着用。
            # 等确认时不发：回车会替你选中确认菜单里的选项
            pid = self._pid(sid)
            if sid in self.waiting:
                raise RuntimeError("Qwen Code 正在等你确认。终端中的会话需输入 /quit 并按回车才能关闭，此时回车会替你选中确认菜单中的选项，"
                                   "因此会话未关闭。请先在确认卡片中作出选择，再关闭会话")
            kl.tmux_send(pid, "/quit", [], True)
            return "已关闭会话"

    return QwenCode()
