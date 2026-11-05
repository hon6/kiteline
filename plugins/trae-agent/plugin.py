"""trae-agent（字节跳动开源的命令行编程 agent，命令 trae-cli；不是 Trae IDE）：单独下发的插件。

11-05 对 github.com/bytedance/trae-agent main（0.1.0，Linux，uv 按 uv.lock 装，另补上游漏写的 docker、pexpect）+ 假模型实测：
  trae-cli interactive 默认全屏界面（Textual）：输入框「Enter your task...」，回车提交；忙时提交会被忽略；Ctrl+C / Ctrl+Q 都是退出整个程序，
  没有只停当前任务的办法。工具直接执行，没有确认框，也没有提问工具。--console-type simple 时先问「Task:」再问「Working Directory:」。
  轨迹：一个 JSON 文件，默认是进程当前目录下 trajectories/trajectory_<启动时间>.json（-t 可改），每一步整个重写：
    task、start_time、end_time（空 = 还在做）、provider、model、
    agent_steps[]：step_number、timestamp、llm_response（content、tool_calls[call_id、name、arguments]）、tool_results[call_id、success、result、error]、error
    llm_interactions[]：timestamp、model、response.usage（input_tokens、output_tokens、cache_read_input_tokens……）
  同一个进程的所有任务写同一个文件，开始新任务时把上一个任务的步骤清掉（start_recording 重置）。
用量：Anthropic 的 input_tokens 不含读缓存；OpenAI、Google 等的含（按 trae-agent 各家客户端的写法），换成不含缓存的口径。
"""
import glob
import json
import os
import re
import subprocess
import time

READ_ONLY = (("Windows 上从手机操作 trae-agent 还没实测，暂未开放，只能查看；请在电脑上回复和确认", "Controlling trae-agent on Windows from your phone isn't tested yet, so it isn't available and this session is view-only. Reply and confirm on your computer.")
             if os.name == "nt" else
             ("trae-agent 不在 tmux 中运行，只能查看；在 tmux 中启动 trae-cli interactive 后即可从手机发任务",
              "trae-agent isn't running in tmux, so this session is view-only. Start trae-cli interactive in tmux to send tasks from your phone."))
BUSY_TEXT = "trae-agent 正在执行任务，做完才能发下一个（它在忙时不接收新任务，也不能插话）"


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

    def processes():
        """trae-cli interactive 进程 → (pid, 工作目录, -t 指定的轨迹文件, 启动时间)。用中台的跨平台进程列举（Windows 也行），老中台退回 ps"""
        rows = []
        if hasattr(kl, "process_list"):
            rows = [(p["pid"], p["cmd"], p.get("start")) for p in kl.process_list()]
        else:
            try:
                out = subprocess.run(["ps", "-axww", "-o", "pid=,lstart=,command="], capture_output=True, text=True, timeout=5,
                                     env=dict(os.environ, LC_ALL="C", LANG="C")).stdout
            except (OSError, subprocess.SubprocessError):
                out = ""
            for line in out.splitlines():
                parts = line.split()
                if len(parts) < 7 or not parts[0].isdigit():
                    continue
                try:
                    started = time.mktime(time.strptime(" ".join(parts[1:6]), "%a %b %d %H:%M:%S %Y"))
                except ValueError:
                    started = None
                rows.append((int(parts[0]), " ".join(parts[6:]), started))
        found = []
        for pid, command, started in rows:
            if "trae-cli" not in command or " interactive" not in command:
                continue
            if not re.search(r"(^|[/\\])trae-cli(\.exe)?[\"']?(\s|$)", command.split(" interactive")[0] + " "):
                continue
            explicit = re.search(r"(?:-t|--trajectory-file)[ =](\S+)", command)
            found.append((pid, process_cwd(pid), explicit.group(1) if explicit else None, started))
        return found

    def process_cwd(pid):
        try:
            return os.readlink("/proc/%d/cwd" % pid)
        except OSError:
            try:   # Mac：没有 /proc
                out = subprocess.run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"], capture_output=True, text=True, timeout=5).stdout
                return next((l[1:] for l in out.splitlines() if l.startswith("n")), None)
            except (OSError, subprocess.SubprocessError):
                return None

    def trajectory_of(cwd, explicit, started):
        if explicit:
            path = explicit if os.path.isabs(explicit) else os.path.join(cwd or "", explicit)
            return path if os.path.isfile(path) else None
        if not cwd:
            return None
        files = glob.glob(os.path.join(cwd, "trajectories", "trajectory_*.json"))
        # 进程启动时就建好了文件（文件名是启动时间）：取启动以后建的里面最早的那个
        if started:
            files = [f for f in files if os.path.getmtime(f) >= started - 5]
        files.sort(key=os.path.basename)
        return files[0] if files else None

    def local_ts(value):
        """trae-agent 写的是本地时间、不带时区（datetime.now().isoformat()）"""
        if not value:
            return None
        try:
            return int(time.mktime(time.strptime(str(value)[:19], "%Y-%m-%dT%H:%M:%S")) * 1000)
        except ValueError:
            return None

    def running(data):
        """还在做：开始时间比结束时间晚（开始新任务时 trae-agent 不清上一个任务的 end_time）"""
        start, end = str(data.get("start_time") or ""), str(data.get("end_time") or "")
        return bool(start) and (not end or end < start)

    _cache = {}
    STATE = os.path.join(kl.DATA_DIR, "plugins", "trae-agent", "folders.json")

    def known_folders(add=None):
        """见过的轨迹目录（进程退出后也要算得到用量）"""
        try:
            with open(STATE, encoding="utf-8") as handle:
                folders = [f for f in json.load(handle) if isinstance(f, str)]
        except (OSError, ValueError):
            folders = []
        if add and add not in folders:
            folders = (folders + [add])[-50:]
            try:
                os.makedirs(os.path.dirname(STATE), exist_ok=True)
                with open(STATE, "w", encoding="utf-8") as handle:
                    json.dump(folders, handle)
            except OSError:
                pass
        return folders

    def load(path):
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            return None
        hit = _cache.get(path)
        if hit and hit[0] == mtime:
            return hit[1]
        try:
            with open(path, encoding="utf-8") as handle:
                data = json.load(handle)
        except (OSError, ValueError):
            return hit[1] if hit else None   # 正在整个重写时读到半截：用上次的
        _cache[path] = (mtime, data)
        return data

    def tool_of(name, args):
        mapped = {"bash": "Bash", "str_replace_based_edit_tool": "Edit", "json_edit_tool": "Edit",
                  "sequentialthinking": "Think", "task_done": "TaskDone"}.get(name, name or "tool")
        args = dict(args) if isinstance(args, dict) else {}
        if mapped == "Edit" and "path" in args:
            args["file_path"] = args.pop("path")
        return mapped, args

    def items_of(data):
        """一份轨迹 → 对话项（id 带任务开始时间，换任务后不撞）"""
        if not isinstance(data, dict):
            return []
        task = str(data.get("start_time") or "")
        base_ts = local_ts(task)
        out = []
        if data.get("task"):
            text, _ = kl.clip(str(data["task"]).strip(), kl.USER_TEXT_MAX)
            out.append({"id": "%s.task" % task, "ts": base_ts, "t": "user", "text": text})
        for step in data.get("agent_steps") or []:
            if not isinstance(step, dict):
                continue
            n = step.get("step_number")
            ts = local_ts(step.get("timestamp")) or base_ts
            response = step.get("llm_response") if isinstance(step.get("llm_response"), dict) else {}
            k = 0
            text = (response.get("content") or "").strip()
            if text:
                out.append({"id": "%s.%s.%d" % (task, n, k), "ts": ts, "t": "text", "text": kl.clip(text, kl.ASSISTANT_TEXT_MAX)[0]})
                k += 1
            for call in step.get("tool_calls") or response.get("tool_calls") or []:
                if not isinstance(call, dict):
                    continue
                name, args = tool_of(call.get("name"), call.get("arguments"))
                out.append({"id": "%s.%s.%d" % (task, n, k), "ts": ts, "t": "tool", "toolId": call.get("call_id"), "name": name,
                            "brief": kl.tool_brief(name, args), "input": kl.shrink(args)})
                k += 1
            for result in step.get("tool_results") or []:
                if not isinstance(result, dict):
                    continue
                body = result.get("result") if result.get("success") else (result.get("error") or result.get("result"))
                out.append({"id": "%s.%s.%d" % (task, n, k), "ts": ts, "t": "result", "toolId": result.get("call_id"),
                            "text": kl.clip(str(body or ""), kl.TOOL_RESULT_MAX)[0], "isError": not result.get("success")})
                k += 1
            if step.get("error"):
                out.append({"id": "%s.%s.%d" % (task, n, k), "ts": ts, "t": "event", "text": "出错：%s" % step["error"]})
        if not running(data) and data.get("end_time") and data.get("final_result") and not data.get("success"):
            out.append({"id": "%s.end" % task, "ts": None, "t": "event", "text": str(data["final_result"])[:500]})
        return out

    def usage_scan(path):
        buckets = {}
        data = load(path) or {}
        cwd = os.path.dirname(os.path.dirname(os.path.abspath(path)))
        provider = str(data.get("provider") or "")
        sid = os.path.splitext(os.path.basename(path))[0]
        for item in data.get("llm_interactions") or []:
            usage = ((item.get("response") or {}).get("usage")) if isinstance(item, dict) else None
            ts = local_ts(item.get("timestamp")) if isinstance(item, dict) else None
            if not isinstance(usage, dict) or not ts:
                continue
            cached = int(usage.get("cache_read_input_tokens") or 0)
            raw = int(usage.get("input_tokens") or 0)
            fresh = raw if provider == "anthropic" else max(0, raw - cached)
            values = (fresh, usage.get("output_tokens"), cached, usage.get("cache_creation_input_tokens"), 1)
            kl.usage_bucket(buckets, ts, item.get("model") or data.get("model") or "unknown", values, cwd=cwd, session=sid)
        return list(buckets.values())

    def screen(pane):
        return term_screen(pane) or ""

    class TraeAgent(kl.AgentPlugin):
        name = "trae-agent"

        def __init__(self):
            self.live = {}    # 会话 id → (pid, 轨迹路径)
            self.sent = {}    # 会话 id → 已推过的项 id

        def detect(self):
            import shutil
            command = shutil.which("trae-cli")
            return {"installed": bool(command), "forms": {"cli": ""} if command else {}}

        def abilities(self):
            return ["view", "reply"]

        def sessions(self):
            out = []
            now = int(time.time() * 1000)
            live = {}
            for pid, cwd, explicit, started in processes():
                # 第一个任务之前还没有轨迹文件：照样列出来，好从手机发第一个任务。会话 id 用进程号（一个进程一个窗口）
                path = trajectory_of(cwd, explicit, started)
                sid = "trae-%d" % pid
                live[sid] = (pid, path)
                if path:
                    known_folders(os.path.dirname(os.path.abspath(path)))
                data = (load(path) if path else None) or {}
                busy = running(data)
                items = items_of(data)
                last = next((i for i in reversed(items) if i["t"] == "text"), None)
                pane = term_pane(pid)
                title = (str(data.get("task") or "").strip() or "trae-agent")[:60]
                updated = int(os.path.getmtime(path) * 1000) if path else (int(started * 1000) if started else now)
                out.append({
                    "pid": pid, "sessionId": sid, "name": title, "title": title, "cwd": cwd or "", "cwdShort": kl.display_cwd(cwd),
                    "status": "busy" if busy else "idle", "waitingFor": None, "needs": None, "detail": None,
                    "activity": "busy" if busy else "idle", "reason": "正在执行任务" if busy else (last["text"] if last else None),
                    "activityText": None, "message": last["text"] if last else None, "messageUuid": last["id"] if last else None,
                    "error": None, "effort": None, "subagents": 0, "pendingTool": None, "pendingId": None,
                    "startedAt": int(started * 1000) if started else None, "statusUpdatedAt": None, "updatedAt": updated,
                    "version": None, "entrypoint": "trae-cli", "sessionKind": None, "tmuxPane": pane, "usage": None,
                    "transcriptPath": None, "transcriptUpdatedAt": updated, "agent": "trae-agent", "model": data.get("model"),
                    "readOnly": not pane, "readOnlyReason": None if pane else READ_ONLY[0],
                    "readOnlyReasonEn": None if pane else READ_ONLY[1],
                })
            self.live = live
            return out

        def pump(self):
            """轨迹是整个重写的 JSON：每次读全量，只推没推过的项（换任务后 id 不同，照样推）"""
            out = []
            for sid, (_, path) in list(self.live.items()):
                if not path:
                    continue
                items = items_of(load(path))
                seen = self.sent.setdefault(sid, set())
                fresh = [i for i in items if i["id"] not in seen]
                if fresh:
                    seen.update(i["id"] for i in fresh)
                    out.append((sid, fresh))
            return out

        def history(self, sid, before, limit):
            path = (self.live.get(sid) or (None, None))[1]
            items = items_of(load(path)) if path else []
            if before is not None:
                index = next((n for n, item in enumerate(items) if item["id"] == str(before)), len(items))
                items = items[:index]
            return items[-limit:], len(items) > limit

        def _pane(self, sid):
            pid = (self.live.get(sid) or (None, None))[0]
            pane = term_pane(pid) if pid else None
            if not pane:
                raise RuntimeError("这个 trae-agent 会话不在 tmux 里运行，只能查看；在 tmux 中启动 trae-cli interactive 后，就可以从手机发任务")
            return pid, pane

        def send(self, sid, text, images):
            pid, pane = self._pane(sid)
            path = self.live[sid][1]
            data = (load(path) if path else None) or {}
            if running(data):
                raise RuntimeError(BUSY_TEXT)
            if images:
                raise RuntimeError("trae-agent 不支持图片，请只发文字")
            text = " ".join(text.split())   # 输入框是单行的
            kl.tmux_send(pid, text, [], True)
            time.sleep(0.5)
            if "Working Directory:" in screen(pane):   # simple 控制台还要问工作目录：用它启动时的目录
                kl.tmux_send(pid, self_cwd(pid), [], True)
            return "已发送"

        def key(self, sid, key):
            if str(key).lower() in ("esc", "escape"):
                raise RuntimeError("trae-agent 没有中断当前任务的办法（Ctrl+C 会退出整个程序），请等它做完，或在电脑上关掉重开")
            raise RuntimeError("trae-agent 不弹确认，工具直接执行")

        def close(self, sid):
            pid, pane = self._pane(sid)
            term_keys(pane, "C-q")
            return "已关闭会话"

        def usage(self, since_ms):
            out = []
            for folder in known_folders():
                if not os.path.isdir(folder):
                    continue
                for path in kl.recent_files([folder], ".json", since_ms):
                    if not os.path.basename(path).startswith("trajectory_"):
                        continue
                    out.extend(r for r in kl.cached_usage(path, usage_scan) if r["ts"] + 3600000 > since_ms)
            return out

    def self_cwd(pid):
        return process_cwd(pid) or os.getcwd()

    return TraeAgent()
