"""watcher（watcher/kiteline-watch.py）的端到端测试：只用合成数据，不碰真实的 ~/.claude。

覆盖：
  - 历史翻页：任意页大小翻到底，结果与顺序全量解析逐项一致、无重复
  - 实时增量：只吐写完的行；半行续写完成后再吐
  - 图片：transcript 里的图、工具结果里的图、智能体发的图、手机发来的图都能按引用取回
  - send-image：从「Claude 进程」的子进程里调用时自动认出所属会话
  - put_file / 路径安全：只能读 inbox 里的文件
  - transcript 被重写变短时发 reset
  - 会话之间的消息：发出、拿到 msg_id、收信方读到，实时事件 peers 和补齐请求都能把两头配上

用法：python3 tests/test_watcher.py
"""
import base64
import glob
import importlib.util
import json
import re
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
WATCHER = os.path.join(HERE, "..", "watcher", "kiteline-watch.py")
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")

spec = importlib.util.spec_from_file_location("watcher", WATCHER)
W = importlib.util.module_from_spec(spec)
spec.loader.exec_module(W)

PASS, FAIL = [0], []


def check(name, cond, detail=""):
    if cond:
        PASS[0] += 1
        print("  [PASS] %s" % name)
    else:
        FAIL.append(name)
        print("  [FAIL] %s %s" % (name, detail))


print("== 文件类型（手机取回文件的 Content-Type，Windows 上的 Python 原本不认 Office 文档）")
check("xlsx / docx / pptx / csv / md 都认得", [W.mimetypes.guess_type("a" + e)[0] for e in (".xlsx", ".docx", ".pptx", ".csv", ".md")] == [
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation", "text/csv", "text/markdown"])
check("大写扩展名、中文文件名也认得", W.mimetypes.guess_type("/x/报价单.XLSX")[0] == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")

root = tempfile.mkdtemp(prefix="ccpulse-watch-test-")
SESS = os.path.join(root, "claude", "sessions")
PROJ = os.path.join(root, "claude", "projects")
DATA = os.path.join(root, "ccpulse")
os.makedirs(SESS)
CWD = os.path.join(root, "工作区")
os.makedirs(CWD)
SID = "aaaaaaaa-1111-2222-3333-444444444444"
# Codex、OpenCode、DeepSeek Harness、Proma 也指到临时目录：别连上这台机器真实的 Codex 守护进程、DSH，别给真实的 OpenCode 装插件
env = dict(os.environ, CCPULSE_SESSIONS_DIR=SESS, CCPULSE_DATA_DIR=DATA, CODEX_HOME=os.path.join(root, "codex"), CLAUDE_CONFIG_DIR=os.path.join(root, "claude"),
           XDG_CONFIG_HOME=os.path.join(root, "xdg-config"), XDG_DATA_HOME=os.path.join(root, "xdg-data"),
           DSH_HOME=os.path.join(root, "dsh"), CCPULSE_PROMA_DIR=os.path.join(root, "proma"))
W.INBOX_DIR = os.path.join(DATA, "inbox")

png_path = os.path.join(root, "shot.png")
with open(png_path, "wb") as handle:
    handle.write(PNG)

# 「Claude 进程」：一个 bash，8 秒后在自己的子进程里调用 send-image
fake = subprocess.Popen(
    ["bash", "-c", "sleep 8; cd '%s'; '%s' '%s' send-image '%s' --caption '首页效果'; sleep 120"
     % (CWD, sys.executable, WATCHER, png_path)],
    env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

transcript_dir = os.path.join(PROJ, W.project_dir_name(CWD))
os.makedirs(transcript_dir)
transcript = os.path.join(transcript_dir, SID + ".jsonl")


def ts(i):
    return "2026-10-19T10:%02d:%02d.000Z" % (i // 60 % 60, i % 60)


# 一份 300 多行的历史：各种类型都有，夹着无关行和大图
rows = []
for i in range(120):
    rows.append({"type": "user", "timestamp": ts(i * 3), "cwd": CWD, "message": {"role": "user", "content": "第 %d 个问题" % i}})
    rows.append({"type": "attachment", "timestamp": ts(i * 3), "attachment": {"type": "environment"}})
    rows.append({"type": "assistant", "timestamp": ts(i * 3 + 1), "message": {"role": "assistant", "content": [
        {"type": "thinking", "thinking": "想一想 %d" % i},
        {"type": "tool_use", "id": "t%d" % i, "name": "Bash", "input": {"command": "echo %d" % i}}]}})
    content = [{"type": "text", "text": "输出 %d" % i}]
    if i % 30 == 0:
        content.append({"type": "image", "source": {"type": "base64", "media_type": "image/png",
                                                     "data": base64.b64encode(PNG * 2000).decode()}})
    rows.append({"type": "user", "timestamp": ts(i * 3 + 2), "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "t%d" % i, "content": content}]}})
rows.append({"type": "user", "timestamp": ts(400), "message": {"role": "user", "content": "[Request interrupted by user]"}})
with open(transcript, "w") as handle:
    for row in rows:
        handle.write(json.dumps(row, ensure_ascii=False) + "\n")

with open(os.path.join(SESS, "%d.json" % fake.pid), "w") as handle:
    json.dump({"pid": fake.pid, "sessionId": SID, "cwd": CWD, "status": "busy", "name": "合成会话",
               "entrypoint": "cli", "kind": "interactive", "startedAt": 1}, handle, ensure_ascii=False)

proc = subprocess.Popen([sys.executable, WATCHER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL, env=env)
events = queue.Queue()
threading.Thread(target=lambda: [events.put(json.loads(l)) for l in proc.stdout], daemon=True).start()


def wait_for(predicate, timeout=8.0):
    end = time.time() + timeout
    while time.time() < end:
        try:
            event = events.get(timeout=0.3)
        except queue.Empty:
            continue
        if predicate(event):
            return event
    return None


counter = [0]


def call(payload, timeout=15):
    counter[0] += 1
    payload["id"] = "q%d" % counter[0]
    proc.stdin.write((json.dumps(payload, ensure_ascii=False) + "\n").encode())
    proc.stdin.flush()
    return wait_for(lambda e: e.get("event") == "response" and e.get("id") == payload["id"], timeout)


try:
    print("== 握手与快照")
    hello = wait_for(lambda e: e["event"] == "hello")
    check("hello 带能力列表", hello and "history" in hello.get("features", []))
    snap = wait_for(lambda e: e["event"] == "snapshots" and e["sessions"])
    check("快照里有合成会话", snap and snap["sessions"][0]["sessionId"] == SID)

    print("== 历史翻页")
    expected = []
    offset = 0
    with open(transcript, "rb") as handle:
        for raw in handle:
            entry = W.parse_line(raw)
            if entry is not None:
                expected.extend(W.normalize_line(offset, entry))
            offset += len(raw)
    for limit in (1, 7, 50):
        got, before, pages = [], None, 0
        while pages < 1000:
            req = {"cmd": "history", "sessionId": SID, "limit": limit}
            if before is not None:
                req["before"] = before
            resp = call(req)
            items = [i for i in resp["items"] if not i["id"].startswith("o")]
            got = items + got
            pages += 1
            if not resp["hasMore"] or not items:
                break
            before = int(items[0]["id"].split(".")[0])
        ids = [i["id"] for i in got]
        check("每页 %d 行：%d 页翻完，与全量一致" % (limit, pages),
              got == expected and len(ids) == len(set(ids)), "得到 %d / 期望 %d" % (len(got), len(expected)))
    check("中断占位显示成系统提示", expected[-1]["t"] == "event" and expected[-1]["text"] == "已中断")

    print("== 图片")
    with_image = next(i for i in expected if i.get("images"))
    resp = call({"cmd": "media", "sessionId": SID, "ref": with_image["images"][0]["ref"]})
    check("取工具结果里的大图", resp["ok"] and base64.b64decode(resp["data"]) == PNG * 2000)

    print("== 实时增量")
    while not events.empty():
        events.get()
    with open(transcript, "a") as handle:
        handle.write(json.dumps({"type": "user", "timestamp": ts(500), "message": {"role": "user", "content": "新消息"}},
                                ensure_ascii=False) + "\n")
        handle.write('{"type": "assistant", "timestamp": "%s", "message": {"role": "assistant", "content": [{"type": "te' % ts(501))
    ev = wait_for(lambda e: e["event"] == "entries")
    check("写完的行立即吐出", ev and [i["text"] for i in ev["items"]] == ["新消息"])
    with open(transcript, "a") as handle:
        handle.write('xt", "text": "回复完成"}]}}\n')
    ev = wait_for(lambda e: e["event"] == "entries")
    check("半行续写完成后吐出", ev and ev["items"][0]["text"] == "回复完成")

    print("== 智能体发图（send-image）")
    ev = wait_for(lambda e: e["event"] == "entries" and e["items"][0]["t"] == "agent_image", timeout=15)
    check("从子进程调用时自动认出会话", ev is not None)
    if ev:
        item = ev["items"][0]
        check("带说明文字", item["text"] == "首页效果")
        resp = call({"cmd": "media", "sessionId": SID, "ref": item["images"][0]["ref"]})
        check("取回智能体发的图", resp["ok"] and base64.b64decode(resp["data"]) == PNG)
        resp = call({"cmd": "history", "sessionId": SID, "limit": 5})
        check("最新一页历史里合并了发图", any(i["t"] == "agent_image" for i in resp["items"]))

    print("== 手机发来的图（put_file）与路径安全")
    resp = call({"cmd": "put_file", "name": "../../手机 图.jpg", "data": base64.b64encode(b"\xff\xd8\xffjpeg").decode()})
    path = resp.get("path", "")
    check("落到 inbox 且文件名被清洗", resp["ok"] and path.startswith(os.path.join(DATA, "inbox")) and ".." not in path, path)
    resp = call({"cmd": "media", "sessionId": SID, "ref": "f:" + path})
    check("能按 f: 引用取回", resp["ok"] and base64.b64decode(resp["data"]) == b"\xff\xd8\xffjpeg")
    resp = call({"cmd": "media", "sessionId": SID, "ref": "f:/etc/passwd"})
    check("inbox 以外的路径被拒绝", resp and not resp["ok"])
    text = "看看这个\n\n[附图] %s" % path
    item = W.normalize_line(0, {"type": "user", "message": {"role": "user", "content": text}})[0]
    check("附图行还原成图片、正文不显示路径", item["text"] == "看看这个" and item["images"][0]["ref"] == "f:" + path)

    print("== 截图（shot）")
    log_path = os.path.join(root, "test.log")
    with open(log_path, "w") as handle:
        handle.write("\x1b[32mPASS\x1b[0m login (12 tests)\nFAIL home\n  expected 16px, received 4px\n")
    # 指一个不出图的「浏览器」，验证退回 SVG 也能发出去
    fake_browser = os.path.join(root, "no-browser")
    with open(fake_browser, "w") as handle:
        handle.write("#!/bin/sh\nexit 1\n")
    os.chmod(fake_browser, 0o755)
    shot_env = dict(env, CCPULSE_BROWSER=fake_browser)
    out = subprocess.run([sys.executable, WATCHER, "shot", "--text", log_path, "--session", SID, "--caption", "测试结果"],
                         env=shot_env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60).stdout.decode()
    ev = wait_for(lambda e: e["event"] == "entries" and e["items"][0]["t"] == "agent_image" and e["items"][0]["text"] == "测试结果", timeout=10)
    check("shot --text 没浏览器时退回 SVG 并发出", ev is not None and ev["items"][0]["images"][0]["mime"] == "image/svg+xml", out.strip())
    if ev:
        stored = max(glob.glob(os.path.join(DATA, "outbox", "files", "*.svg")), key=os.path.getmtime)
        with open(stored, encoding="utf-8") as handle:
            svg = handle.read()
        check("SVG 里是去掉颜色码的文本，失败行标红", "<svg" in svg and "PASS login" in svg and "\x1b" not in svg and "#ff7b72" in svg)
        # 客户端都显示不了 SVG：watcher 这边有浏览器时，取图时换成 PNG 给（以前发的 SVG 也一样）
        resp = call({"cmd": "media", "sessionId": SID, "ref": ev["items"][0]["images"][0]["ref"]}, timeout=120)
        data = base64.b64decode(resp["data"]) if resp and resp["ok"] else b""
        if W.find_browser()[0]:
            check("取 SVG 图时换成 PNG", resp["mime"] == "image/png" and data[:8] == b"\x89PNG\r\n\x1a\n" and os.path.exists(stored[:-4] + ".png"),
                  str(resp)[:200])
            # send-image 直接发 SVG：先转成 PNG 再存
            chart = os.path.join(root, "图表.svg")
            with open(chart, "w", encoding="utf-8") as handle:
                handle.write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100"><rect width="200" height="100" fill="#2a6"/></svg>')
            out = subprocess.run([sys.executable, WATCHER, "send-image", chart, "--session", SID, "--caption", "SVG 图表"],
                                 env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120).stdout.decode()
            ev = wait_for(lambda e: e["event"] == "entries" and e["items"][0]["t"] == "agent_image" and e["items"][0]["text"] == "SVG 图表", timeout=10)
            image = ev["items"][0]["images"][0] if ev else {}
            check("send-image 发 SVG 时先转成 PNG", image.get("mime") == "image/png" and image.get("name") == "图表.png", out.strip())
        else:
            check("没浏览器时取 SVG 图照旧给 SVG", resp["mime"] == "image/svg+xml" and b"<svg" in data, str(resp)[:200])

    print("== 今日动态（digest）")
    with open(transcript, "a") as handle:
        handle.write(json.dumps({"type": "assistant", "timestamp": ts(502), "message": {
            "id": "msg_edit", "role": "assistant", "usage": {"input_tokens": 10, "output_tokens": 345},
            "content": [{"type": "tool_use", "id": "e1", "name": "Edit",
                         "input": {"file_path": os.path.join(CWD, "src", "app.js"), "old_string": "a", "new_string": "b"}}]}},
            ensure_ascii=False) + "\n")
    since = W.parse_ts(ts(0))
    resp = call({"cmd": "digest", "since": since})
    item = (resp or {}).get("sessions", [{}])[0] if resp and resp.get("sessions") else {}
    check("按会话汇总：对话轮数、回复、工具次数", item.get("prompts") == 121 and item.get("replies") == 1
          and any(t["name"] == "Bash" and t["count"] == 120 for t in item.get("tools", [])), str(item.get("prompts")))
    check("改动文件取自 Edit，路径相对工作目录", item.get("files") == [{"path": "src/app.js", "edits": 1}], str(item.get("files")))
    check("在线会话标 live、带最后结论与时间范围", item.get("live") is True and item.get("conclusions")[-1]["text"] == "回复完成"
          and item.get("firstAt") == since and item.get("lastAt") == W.parse_ts(ts(502)))
    # send-image 一张 + shot 一张（有浏览器时还多发了一张 SVG 图表）
    check("统计 Claude 发来的截图并给出引用", item.get("images") == (3 if W.find_browser()[0] else 2)
          and all(s["ref"].startswith("o") for s in item.get("shots", [])), str(item.get("images")))
    check("输出 token 按消息去重累计", item.get("outputTokens") == 345 and item.get("requests") == 1, str(item.get("outputTokens")))
    resp = call({"cmd": "digest", "since": W.parse_ts(ts(150))})
    check("since 之前的行不算", resp["sessions"][0]["prompts"] == 71, str(resp["sessions"][0]["prompts"]))
    resp = call({"cmd": "digest", "since": since, "until": W.parse_ts(ts(30))})
    check("until 截止（昨天这种区间）", resp["sessions"][0]["prompts"] == 10 and resp["sessions"][0]["images"] == 0)
    resp = call({"cmd": "digest", "since": W.parse_ts(ts(503))})
    check("区间里没动静的会话不出现", resp["ok"] and resp["sessions"] == [])
    # 真实记录的字段顺序：timestamp 在 message 后面；带截图的大行（几百 KB）也要算上
    big = {"type": "user", "message": {"role": "user", "content": [
        {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": base64.b64encode(PNG * 30000).decode()}},
        {"type": "text", "text": "看这张截图"}]}, "timestamp": ts(504), "cwd": CWD}
    with open(transcript, "a") as handle:
        handle.write(json.dumps(big, ensure_ascii=False) + "\n")
    resp = call({"cmd": "digest", "since": W.parse_ts(ts(504))})
    check("时间戳在行尾的大行（带截图的消息）也计入今日动态", resp["ok"] and resp["sessions"] and resp["sessions"][0]["prompts"] == 1, str(resp)[:200])

    print("== 接口错误（Claude 停下了）")
    ref = W.parse_ts("2026-10-07T13:01:11.397Z")   # 纽约 09:01（夏令时）
    info = W.api_error_info("You've hit your session limit · resets 9:10am (America/New_York)", ref)
    check("用量上限：认出来，恢复时间换算成绝对时间（纽约 9:10 = UTC 13:10）", info["kind"] == "limit"
          and info["resetAt"] == W.parse_ts("2026-10-07T13:10:00Z"), str(info))
    info2 = W.api_error_info("You've hit your session limit · resets 9:10am (America/New_York)", W.parse_ts("2026-10-07T13:30:00Z"))
    check("恢复时刻已经过了就算到第二天", info2["resetAt"] == W.parse_ts("2026-10-08T13:10:00Z"), str(info2))
    kinds = [W.api_error_info(t)["kind"] for t in ["Prompt is too long · automatic compaction failed",
             'API Error: 529 {"type":"overloaded_error"}', "Invalid API key · Please run /login", "Credit balance is too low", "怪事"]]
    check("上下文太长 / 过载 / 登录失效 / 余额不足 / 其他各归各类", kinds == ["too_long", "api", "auth", "billing", "api"], str(kinds))
    err_path = os.path.join(root, "err.jsonl")
    with open(err_path, "w") as handle:
        handle.write(json.dumps({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "整理周报"}]}}) + "\n")
        handle.write(json.dumps({"type": "assistant", "uuid": "e1", "isApiErrorMessage": True, "timestamp": "2026-10-07T13:01:11Z",
                                 "message": {"role": "assistant", "model": "<synthetic>", "content": [{"type": "text", "text": "Prompt is too long"}]}}) + "\n")
    scan = W.scan_transcript(err_path)
    check("快照：最后一句是接口错误时带 error，消息换成说人话的", scan["error"] and scan["error"]["kind"] == "too_long"
          and scan["message"].startswith("上下文过长"), str(scan)[:300])
    with open(err_path, "a") as handle:
        handle.write(json.dumps({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "继续"}]}}) + "\n")
    check("你又说了话（比如「继续」）之后错误就过去了", W.scan_transcript(err_path)["error"] is None)
    eff_path = os.path.join(root, "effort.jsonl")
    with open(eff_path, "w") as handle:
        for args in ("max", "ultracode on", "high"):
            handle.write(json.dumps({"type": "user", "message": {"role": "user", "content":
                "<command-name>/effort</command-name>\n<command-message>effort</command-message>\n<command-args>%s</command-args>" % args}}) + "\n")
    check("认出这个会话的思考等级和 ultracode（在 VS Code 里打的 /effort 或手机发的）",
          W.scan_transcript(eff_path)["effort"] == {"effort": "high", "ultracode": True}, str(W.scan_transcript(eff_path)["effort"]))
    with open(eff_path, "w") as handle:   # 记录尾部滚过去了（看不到那几条命令）也记得
        handle.write(json.dumps({"type": "user", "message": {"role": "user", "content": "接着做"}}) + "\n")
    check("命令滚出了记录尾部，思考等级照样记得", W.scan_transcript(eff_path)["effort"] == {"effort": "high", "ultracode": True})
    # Claude 没起成标题（起标题的请求失败）：VS Code 标签拿用户的话当名字，列表和投递核对标签都要认这个
    nt_path = os.path.join(root, "notitle.jsonl")
    first_words = "订单列表里，清空筛选条件后又重新筛选，现在接口报错了，怎么办\n\n[附图] /tmp/a.jpg"
    with open(nt_path, "w") as handle:
        handle.write(json.dumps({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": first_words}]}}, ensure_ascii=False) + "\n")
        handle.write(json.dumps({"type": "last-prompt", "lastPrompt": "继续", "sessionId": "nt"}, ensure_ascii=False) + "\n")
    real_path = W.transcript_path
    W.transcript_path = lambda sid, cwd: nt_path
    try:
        snap = W.snapshot_session({"sessionId": "nt", "cwd": CWD, "status": "idle", "name": "proj-ab"})
        check("没有标题：拿第一句当标题（同 VS Code 标签）", snap["title"].startswith("订单列表里，清空筛选条件后又重新筛选") and "\n" not in snap["title"], str(snap["title"]))
        check("没有标题：tabNames 带第一句（换行并成空格）和最近一句", len(snap["tabNames"]) == 2 and snap["tabNames"][1] == "继续"
              and snap["tabNames"][0].startswith("订单列表里，清空筛选条件后又重新筛选，现在接口报错了，怎么办") and "\n" not in snap["tabNames"][0], str(snap["tabNames"]))
        with open(nt_path, "a") as handle:
            handle.write(json.dumps({"type": "ai-title", "aiTitle": "筛选报错", "sessionId": "nt"}, ensure_ascii=False) + "\n")
        snap = W.snapshot_session({"sessionId": "nt", "cwd": CWD, "status": "idle", "name": "proj-ab"})
        check("后来起好了标题：用标题，不再带 tabNames", snap["title"] == "筛选报错" and snap["tabNames"] is None, str(snap))
        with open(nt_path, "a") as handle:
            handle.write(json.dumps({"type": "custom-title", "customTitle": "订单筛选", "sessionId": "nt"}, ensure_ascii=False) + "\n")
            handle.write(json.dumps({"type": "ai-title", "aiTitle": "筛选报错", "sessionId": "nt"}, ensure_ascii=False) + "\n")
        snap = W.snapshot_session({"sessionId": "nt", "cwd": CWD, "status": "idle", "name": "proj-ab"})
        check("在 VS Code 里改过名：用改的名（之后的 AI 标题不算）", snap["title"] == "订单筛选", str(snap["title"]))
        check("历史列表的标题也认改的名", W.tail_title(nt_path, os.path.getsize(nt_path)) == "订单筛选" and W.find_title(nt_path) == "订单筛选")
    finally:
        W.transcript_path = real_path
    items = W.normalize_line(0, {"type": "assistant", "isApiErrorMessage": True, "timestamp": "2026-10-07T13:01:11Z",
                                 "message": {"role": "assistant", "content": [{"type": "text", "text": "API Error: 529 overloaded"}]}})
    check("对话里显示成红色提示，不当成 Claude 的回复", len(items) == 1 and items[0]["t"] == "event" and items[0]["level"] == "error"
          and "过载" in items[0]["text"], str(items))

    print("== 新任务：项目列表")
    resp = call({"cmd": "projects"})
    mine = next((p for p in (resp or {}).get("projects", []) if p["cwd"] == CWD), None)
    check("最近项目里有这个工作目录，带标题和最后活动时间", mine is not None and mine["exists"] and mine["lastActive"] > 0
          and mine["sessionId"] == SID, str(resp)[:200])
    resp = call({"cmd": "is_dir", "path": CWD})
    ok_dir = resp and resp["isDir"] is True
    resp = call({"cmd": "is_dir", "path": os.path.join(CWD, "没有这个目录")})
    no_dir = resp and resp["isDir"] is False
    resp = call({"cmd": "is_dir", "path": "relative/path"})
    check("目录检查：存在 / 不存在 / 相对路径", ok_dir and no_dir and resp["isDir"] is False)

    # 新任务「打开其他文件夹」：列子文件夹（不限项目目录）、标出 Git 仓库、新建文件夹
    browse = os.path.join(root, "browse")
    os.makedirs(os.path.join(browse, "repo", ".git"))
    os.makedirs(os.path.join(browse, ".hidden"))
    open(os.path.join(browse, "file.txt"), "w").close()
    resp = call({"cmd": "dirs", "path": browse})
    check("列子文件夹：只有文件夹、不含隐藏的、Git 仓库标出、给上一级", resp and [(e["name"], e.get("git", False)) for e in resp["entries"]] == [("repo", True)]
          and resp["parent"] == os.path.dirname(browse) and resp["path"] == browse, str(resp)[:300])
    resp = call({"cmd": "dirs", "path": browse, "hidden": True})
    check("显示隐藏文件夹", resp and [e["name"] for e in resp["entries"]] == [".hidden", "repo"], str(resp)[:200])
    resp = call({"cmd": "dirs", "path": ""})
    check("不给路径 = 主目录", resp and resp["ok"] and resp["path"] == os.path.expanduser("~") == resp["home"], str(resp)[:200])
    resp = call({"cmd": "dirs", "path": browse, "mkdir": "新项目"})
    check("新建文件夹后列新文件夹", resp and resp["ok"] and resp["path"] == os.path.join(browse, "新项目") and os.path.isdir(resp["path"]), str(resp)[:200])
    bad = [call({"cmd": "dirs", "path": browse, "mkdir": "新项目"}), call({"cmd": "dirs", "path": browse, "mkdir": "../逃出去"}),
           call({"cmd": "dirs", "path": "relative/path"}), call({"cmd": "dirs", "path": os.path.join(browse, "没有")})]
    check("重名 / 非法名 / 相对路径 / 不存在都报错", all(r and not r["ok"] for r in bad) and not os.path.exists(os.path.join(root, "逃出去")),
          str([r and r.get("error") for r in bad]))

    print("== 历史会话与搜索")
    OLD = "bbbbbbbb-1111-2222-3333-444444444444"
    with open(os.path.join(transcript_dir, OLD + ".jsonl"), "w") as handle:
        for row in [{"type": "user", "timestamp": ts(5), "cwd": CWD, "message": {"role": "user", "content": "上周那个导出功能"}},
                    {"type": "assistant", "timestamp": ts(6), "cwd": CWD, "message": {"role": "assistant", "content": [
                        {"type": "text", "text": "导出功能已经上线，Excel 文件按日期命名。"}]}},
                    {"type": "ai-title", "aiTitle": "订单导出", "sessionId": OLD}]:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    resp = call({"cmd": "sessions_list"})
    listed = {m["sessionId"]: m for m in (resp or {}).get("sessions", [])}
    check("会话列表含已结束的会话：标题、第一句话、目录", OLD in listed and listed[OLD]["title"] == "订单导出"
          and listed[OLD]["firstPrompt"] == "上周那个导出功能" and listed[OLD]["cwd"] == CWD, str(listed.get(OLD)))
    resp = call({"cmd": "history", "sessionId": OLD, "limit": 10})
    check("已结束的会话也能拉历史", resp and resp["ok"] and [i["t"] for i in resp["items"]] == ["user", "text"], str(resp)[:200])
    resp = call({"cmd": "session_info", "sessionId": OLD})
    check("会话概要", resp and resp["ok"] and resp["session"]["cwd"] == CWD)
    resp = call({"cmd": "history", "sessionId": "../../etc/passwd"})
    check("会话 id 不合法时拒绝（防路径穿越）", resp and not resp["ok"])
    resp = call({"cmd": "search", "q": "excel"})
    hits = [(r["sessionId"], h["t"]) for r in (resp or {}).get("results", []) for h in r["hits"]]
    check("全文搜索不分大小写，命中 Claude 的回复", hits == [(OLD, "text")], str(hits))
    resp = call({"cmd": "search", "q": "第 7 个问题"})
    first = resp["results"][0]["hits"][0] if resp and resp.get("results") else {}
    check("命中你说的话，带片段和定位 id", first.get("t") == "user" and "第 7 个问题" in first.get("snippet", "") and "." in first.get("id", ""))
    resp = call({"cmd": "search", "q": "输出 3"})
    check("只搜对话正文，不搜工具输出", resp and resp["ok"] and resp["results"] == [])
    resp = call({"cmd": "search", "q": "个问题", "sessionId": SID})
    hits = resp["results"][0]["hits"] if resp and resp.get("results") else []
    check("对话内搜索：只搜这一个会话，命中全给（不止 3 条）", len(hits) == 120 and all(h["t"] == "user" for h in hits), str(len(hits)))
    resp = call({"cmd": "search", "q": "订单导出"})
    found = {r["sessionId"]: r for r in (resp or {}).get("results", [])}
    check("按标题搜：只在标题里的词也能搜到，标出 match=title", OLD in found and "title" in found[OLD].get("match", []), str(found.get(OLD))[:200])
    resp = call({"cmd": "search", "q": "工作区"})
    found = {r["sessionId"]: r for r in (resp or {}).get("results", [])}
    check("按项目名搜（中文目录名）：这个项目的会话都搜到，标出 match=project",
          {SID, OLD} <= set(found) and all("project" in r.get("match", []) for r in found.values()), str(sorted(found))[:200])
    # 英文目录名的项目：先按记录目录名挑出来，不读全文
    OTHER_CWD = os.path.join(root, "kiteline-demo")
    OTHER = "eeeeeeee-1111-2222-3333-444444444444"
    other_dir = os.path.join(PROJ, W.project_dir_name(OTHER_CWD))
    os.makedirs(other_dir, exist_ok=True)
    with open(os.path.join(other_dir, OTHER + ".jsonl"), "w") as handle:
        handle.write(json.dumps({"type": "user", "timestamp": ts(7), "cwd": OTHER_CWD, "message": {"role": "user", "content": "看一下首页"}},
                                ensure_ascii=False) + "\n")
    resp = call({"cmd": "search", "q": "KITELINE"})
    found = {r["sessionId"]: r for r in (resp or {}).get("results", [])}
    check("按项目名搜（英文目录名、不分大小写）", list(found) == [OTHER] and found[OTHER]["match"] == ["project"]
          and found[OTHER]["hits"] == [], str(resp)[:200])
    resp = call({"cmd": "sessions_list", "project": "kiteline-demo"})
    other_ids = [m["sessionId"] for m in (resp or {}).get("sessions", [])]
    resp = call({"cmd": "sessions_list", "project": "工作区"})
    mine_ids = [m["sessionId"] for m in (resp or {}).get("sessions", [])]
    check("会话列表按项目名取：只要这个项目的", other_ids == [OTHER] and OLD in mine_ids and OTHER not in mine_ids, str((other_ids, mine_ids)))
    shutil.rmtree(other_dir)

    print("== 用量报表")
    def usage_line(i, mid, model, inp, out, cr, cw):
        return {"type": "assistant", "timestamp": ts(i), "cwd": CWD, "requestId": "r" + mid, "message": {
            "id": mid, "role": "assistant", "model": model, "content": [{"type": "text", "text": "x"}],
            "usage": {"input_tokens": inp, "output_tokens": out, "cache_read_input_tokens": cr, "cache_creation_input_tokens": cw}}}
    U1, U2 = "cccccccc-1111-2222-3333-444444444444", "dddddddd-1111-2222-3333-444444444444"
    m1 = usage_line(10, "m1", "claude-opus-5-5", 100, 200, 1000, 400)
    rows = [m1, m1, usage_line(11, "m2", "claude-opus-5-5", 0, 100, 2000, 0),
            usage_line(12, "s1", "<synthetic>", 0, 999, 0, 0),
            {"type": "cost-state", "sessionId": U1, "totalCostUSD": 2.0, "modelUsage": {"claude-opus-5-5": {
                "inputTokens": 100, "outputTokens": 300, "cacheReadInputTokens": 3000, "cacheCreationInputTokens": 400, "costUSD": 2.0}}}]
    with open(os.path.join(transcript_dir, U1 + ".jsonl"), "w") as handle:
        handle.write("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
    os.makedirs(os.path.join(transcript_dir, U1, "subagents"))
    with open(os.path.join(transcript_dir, U1, "subagents", "agent-1.jsonl"), "w") as handle:
        handle.write(json.dumps(usage_line(13, "a1", "claude-haiku-5-5", 0, 60, 0, 0)) + "\n")
    with open(os.path.join(transcript_dir, U2 + ".jsonl"), "w") as handle:
        handle.write(json.dumps(usage_line(14, "u2", "claude-opus-5-5", 0, 120, 0, 0)) + "\n")
    resp = call({"cmd": "usage_report", "since": W.parse_ts(ts(0)), "tz": 0})
    t = (resp or {}).get("totals", {})
    opus = next((m for m in (resp or {}).get("models", []) if m["model"] == "claude-opus-5-5"), {})
    check("按 message.id 去重、跳过 <synthetic>、算上子代理", opus.get("requests") == 3 and opus.get("output") == 420
          and any(m["model"] == "claude-haiku-5-5" and m["requests"] == 1 for m in resp["models"]), str(resp)[:300])
    check("有 cost-state 的会话按它的费率分摊（合计正好 $2）", abs(opus.get("cost", 0) - 2.5) < 1e-6
          and abs(t.get("estimated", 0) - 0.5) < 1e-6, "%s %s" % (opus.get("cost"), t.get("estimated")))
    check("没费率数据的模型列为只统计 token", "claude-haiku-5-5" in resp["unpriced"])
    check("按天汇总（按传入的时区切日）", [d["day"] for d in resp["days"]] == ["2026-10-19"] and abs(resp["days"][0]["cost"] - 2.5) < 1e-6)
    resp = call({"cmd": "usage_report", "since": W.parse_ts(ts(0)), "tz": 14 * 60})
    check("时区不同切日不同", [d["day"] for d in resp["days"]] == ["2026-10-20"])

    print("== 子 agent 的完整记录")
    rows = [{"type": "user", "isSidechain": True, "agentId": "a2b3c4", "timestamp": ts(20), "message": {"role": "user", "content": "调研一下扩展"}},
            {"type": "assistant", "isSidechain": True, "agentId": "a2b3c4", "timestamp": ts(21),
             "message": {"id": "sa1", "role": "assistant", "content": [{"type": "text", "text": "调研结果如下"}]}}]
    with open(os.path.join(transcript_dir, U1, "subagents", "agent-a2b3c4.jsonl"), "w") as handle:
        handle.write("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
    resp = call({"cmd": "history", "sessionId": U1, "agentId": "a2b3c4", "limit": 50})
    shown = json.dumps(resp, ensure_ascii=False)
    check("子 agent 记录里每行都标着 isSidechain，照常显示", len((resp or {}).get("items", [])) == 2 and "调研一下扩展" in shown and "调研结果如下" in shown, shown[:300])

    print("== 项目文件（只读）")
    os.makedirs(os.path.join(CWD, "src", "深层"))
    with open(os.path.join(CWD, "src", "app.js"), "w") as handle:
        handle.write("const a = 1;\n// 注释\n")
    with open(os.path.join(CWD, "src", "深层", "说明.md"), "w") as handle:
        handle.write("# 标题\n")
    with open(os.path.join(CWD, ".env"), "w") as handle:
        handle.write("TOKEN=secret\n")
    with open(os.path.join(CWD, "logo.png"), "wb") as handle:
        handle.write(PNG)
    with open(os.path.join(CWD, "blob.bin"), "wb") as handle:
        handle.write(b"\x00\x01\x02binary")
    os.symlink("/etc", os.path.join(CWD, "外链"))
    resp = call({"cmd": "ls", "root": CWD, "path": ""})
    names = [e["name"] for e in (resp or {}).get("entries", [])]
    check("列目录：目录在前，按名字排", resp and resp["ok"] and names.index("src") < names.index("logo.png"), str(names))
    resp = call({"cmd": "read_file", "root": CWD, "path": "src/app.js"})
    check("读文本文件：内容、行数", resp and resp["ok"] and resp["text"].startswith("const a") and resp["lines"] == 3)
    resp = call({"cmd": "read_file", "root": CWD, "path": ".env"})
    check("疑似密钥的文件默认不给内容", resp and resp["ok"] and resp.get("secret") and "text" not in resp)
    resp = call({"cmd": "read_file", "root": CWD, "path": ".env", "reveal": True})
    check("确认后才给", resp and resp.get("text") == "TOKEN=secret\n")
    hidden = []
    for name in ["AuthKey_ABC.p8", ".server", ".netrc", ".npmrc", "db-password.txt", "api_token.json"]:
        with open(os.path.join(CWD, name), "w") as handle:
            handle.write("x\n")
        resp = call({"cmd": "read_file", "root": CWD, "path": name})
        if resp and resp.get("secret") and "text" not in resp:
            hidden.append(name)
    check("推送密钥、服务器密码、.netrc / .npmrc 等也默认不给内容", len(hidden) == 6, str(hidden))
    resp = call({"cmd": "read_file", "root": CWD, "path": "src/app.js"})
    check("普通文件照常给", resp and "text" in resp and not resp.get("secret"))
    resp = call({"cmd": "read_file", "root": CWD, "path": "logo.png"})
    check("图片给 base64", resp and resp.get("image") and base64.b64decode(resp["data"]) == PNG)
    resp = call({"cmd": "read_file", "root": CWD, "path": "blob.bin"})
    check("二进制文件不给内容", resp and resp.get("binary") and "text" not in resp)
    blocked = []
    for bad in ["../../etc/passwd", "外链/passwd", "src/../../x"]:
        resp = call({"cmd": "read_file", "root": CWD, "path": bad})
        blocked.append(bool(resp) and not resp["ok"])
    resp = call({"cmd": "ls", "root": CWD, "path": "外链"})
    blocked.append(bool(resp) and not resp["ok"])
    check("跑出项目目录（.. 或符号链接）一律拒绝", all(blocked), str(blocked))
    resp = call({"cmd": "find_files", "root": CWD, "q": "说明"})
    check("按文件名找（含子目录）", resp and resp["results"] == [os.path.join("src", "深层", "说明.md")], str(resp))

    print("== 独立 worktree")
    repo = os.path.join(root, "仓库")
    os.makedirs(os.path.join(repo, "src"))
    with open(os.path.join(repo, "src", "a.txt"), "w") as handle:
        handle.write("a\n")
    gitenv = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
    for args in (["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "init"]):
        subprocess.run(["git", "-C", repo] + args, env=gitenv, check=True)
    resp = call({"cmd": "repo_info", "cwd": CWD})
    not_repo = resp and resp["ok"] and resp["repo"] is False
    resp = call({"cmd": "worktree_add", "cwd": os.path.join(repo, "src")})
    made = resp and resp["ok"] and resp["branch"].startswith("tars/") and os.path.isfile(os.path.join(resp["path"], "a.txt"))
    info = call({"cmd": "repo_info", "cwd": repo})
    check("建 worktree：新分支、同一子目录、仓库里能列出来；非仓库目录如实报告", not_repo and made
          and [t["branch"] for t in info["worktrees"]] == [resp["branch"]] and os.path.isfile(os.path.join(repo, "src", "a.txt")), str(resp))

    print("== 项目总览")
    with open(os.path.join(repo, "src", "a.txt"), "a") as handle:
        handle.write("改了一行\n")
    with open(os.path.join(repo, "新文件.md"), "w") as handle:
        handle.write("x\n")
    gone = os.path.join(root, "早就删了")
    resp = call({"cmd": "project_overview", "extra": [repo, gone, "相对路径"]})
    listed = {p["cwd"]: p for p in (resp or {}).get("projects", [])}
    mine, extra_repo = listed.get(CWD) or {}, listed.get(repo) or {}
    g = extra_repo.get("git") or {}
    check("项目总览：会话数、今天动过几个；不是 git 仓库的 git 为空", mine.get("sessions", 0) >= 1 and mine.get("today", 0) >= 1
          and mine.get("git") is None, str(mine)[:200])
    check("项目总览：git 分支、改动数、新文件数、最近提交", g.get("branch") and g.get("changed") == 1 and g.get("untracked") == 1
          and (g.get("last") or {}).get("subject") == "init" and g.get("ahead") == 0, str(extra_repo)[:300])
    check("额外目录：不存在的标出来、不跑 git，相对路径忽略", listed.get(gone, {}).get("exists") is False
          and "git" not in listed.get(gone, {}) and "相对路径" not in listed, str(listed.get(gone)))
    # git 卡住（macOS 等授权 / 网络盘）：3 秒放弃，记为超时，10 分钟内不再等
    real_run_git = W.run_git
    def stuck(cwd, args, limit=400000, timeout=20):
        raise subprocess.TimeoutExpired(["git"] + args, timeout)
    W.run_git = stuck
    try:
        W._QUICK_GIT.pop(repo, None)
        first = W.quick_git(repo)
        W.run_git = real_run_git
        again = W.quick_git(repo)
    finally:
        W.run_git = real_run_git
    check("git 读超时记为 timeout，10 分钟内直接用这个结果", first == {"timeout": True} and again == {"timeout": True}
          and W._QUICK_GIT[repo][0] - time.time() > 500, str(first))
    W._QUICK_GIT.pop(repo, None)
    # 改动报告：重命名后又改（RM）、暂存后又改（MM）都只显示一个字母，重命名的行数对到新路径上
    gitenv2 = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
    subprocess.run(["git", "-C", repo, "add", "-A"], env=gitenv2, check=True)
    subprocess.run(["git", "-C", repo, "commit", "-q", "-m", "second"], env=gitenv2, check=True)
    subprocess.run(["git", "-C", repo, "mv", os.path.join("src", "a.txt"), os.path.join("src", "renamed.txt")], env=gitenv2, check=True)
    with open(os.path.join(repo, "src", "renamed.txt"), "a") as handle:
        handle.write("重命名后又改了\n")
    with open(os.path.join(repo, "新文件.md"), "a") as handle:
        handle.write("y\n")
    subprocess.run(["git", "-C", repo, "add", "新文件.md"], env=gitenv2, check=True)
    with open(os.path.join(repo, "新文件.md"), "a") as handle:
        handle.write("z\n")
    st = W.git_status(repo)
    by = {f["path"]: f for f in st["files"]}
    check("改动报告：两位状态码归成一个字母，重命名不多出「旧 => 新」条目", by.get("src/renamed.txt", {}).get("status") == "R"
          and by.get("新文件.md", {}).get("status") == "M" and not any("=>" in p for p in by)
          and by["src/renamed.txt"]["add"] >= 1, str(st["files"]))
    resp = call({"cmd": "project_overview", "since": int((time.time() + 3600) * 1000)})
    later = next((p for p in (resp or {}).get("projects", []) if p["cwd"] == CWD), {})
    check("「今天」的起点由 Mac 传入（按用户所在时区）", later.get("today") == 0 and later.get("sessions", 0) >= 1, str(later)[:200])

    print("== 会话之间的消息（SendMessage）")

    def now_ts(offset=0):
        # 往来只留最近几天：这一段用当前时间（上面的合成历史是固定的旧日期）
        return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() + offset))
    # 第二个会话（收信的）：自己的进程、登记、对话记录
    peer_proc = subprocess.Popen(["sleep", "120"])
    SID2 = "bbbbbbbb-1111-2222-3333-444444444444"
    with open(os.path.join(SESS, "%d.json" % peer_proc.pid), "w") as handle:
        json.dump({"pid": peer_proc.pid, "sessionId": SID2, "cwd": CWD, "status": "idle", "name": "收信会话",
                   "entrypoint": "cli", "kind": "interactive", "startedAt": 2}, handle, ensure_ascii=False)
    transcript2 = os.path.join(transcript_dir, SID2 + ".jsonl")
    with open(transcript2, "w") as handle:
        handle.write(json.dumps({"type": "user", "timestamp": now_ts(-6), "message": {"role": "user", "content": "你好"}}, ensure_ascii=False) + "\n")
    check("第二个会话进了快照", wait_for(lambda e: e["event"] == "snapshots" and any(x["sessionId"] == SID2 for x in e["sessions"])) is not None)
    while not events.empty():
        events.get()
    msg_id = "11111111-2222-3333-4444-555555555555"
    with open(transcript, "a") as handle:
        handle.write(json.dumps({"type": "assistant", "timestamp": now_ts(-5), "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": "toolu_peer1", "name": "SendMessage",
             "input": {"to": "收信会话", "summary": "请你跑一下测试", "message": "测试跑完告诉我结果"}}]}}, ensure_ascii=False) + "\n")
    ev = wait_for(lambda e: e["event"] == "peers")
    link = (ev or {}).get("links", [{}])[0]
    check("发出时就有往来：发信、收信会话都认出来", link.get("from") == SID and link.get("to") == SID2 and link.get("summary") == "请你跑一下测试", str(link))
    with open(transcript, "a") as handle:
        handle.write(json.dumps({"type": "user", "timestamp": now_ts(-4), "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "toolu_peer1",
             "content": [{"type": "text", "text": json.dumps({"success": True, "message": "已送达", "msg_id": msg_id})}]}]}}) + "\n")
    ev = wait_for(lambda e: e["event"] == "peers")
    link = (ev or {}).get("links", [{}])[0]
    check("拿到 msg_id 后换成正式 id，带着旧 id 让客户端替换", link.get("id") == msg_id and link.get("was") == "t:toolu_peer1" and link.get("ok") is True, str(link))
    with open(transcript2, "a") as handle:
        handle.write(json.dumps({"type": "user", "isMeta": True, "timestamp": now_ts(-3),
                                 "origin": {"kind": "peer", "from": "uds:/tmp/%d.sock" % fake.pid, "verifiedPeerPid": fake.pid,
                                            "msg_id": msg_id, "name": "合成会话", "body": "测试跑完告诉我结果"},
                                 "message": {"role": "user", "content": "<cross-session-message from=\"uds:/tmp/x.sock\">测试跑完告诉我结果</cross-session-message>"}},
                                ensure_ascii=False) + "\n")
    got = {}
    end = time.time() + 8
    while time.time() < end and not ("peers" in got and "entries" in got):
        e = wait_for(lambda e: e["event"] in ("peers", "entries") and (e["event"] == "peers" or e.get("sessionId") == SID2), 1)
        if e:
            got[e["event"]] = e
    link = (got.get("peers") or {}).get("links", [{}])[0]
    check("收信方读到：同一条往来记上收信时间", link.get("id") == msg_id and link.get("to") == SID2 and link.get("readAt") and link.get("from") == SID, str(link))
    item = ((got.get("entries") or {}).get("items") or [{}])[0]
    check("收到的消息是一条带 peer 的事件（旧版 App 显示一行字）", item.get("t") == "event" and (item.get("peer") or {}).get("dir") == "in"
          and item["peer"].get("session") == SID and item["peer"].get("body") == "测试跑完告诉我结果", str(item))
    resp = call({"cmd": "peers", "since": 0})
    links = [l for l in (resp or {}).get("links", []) if l.get("id") == msg_id]
    check("补齐请求：翻对话记录也能把两头配上", resp and resp["ok"] and links and links[0].get("from") == SID and links[0].get("to") == SID2, str(resp)[:300])
    # 忙时插进来的（attachment），以及老格式（没有 body，从标签里抠正文）
    items = W.normalize_line(0, {"type": "attachment", "timestamp": now_ts(-2), "attachment": {
        "type": "queued_command", "prompt": "<cross-session-message from=\"uds:/x.sock\" from-name=\"甲\">\n正文在这\n</cross-session-message>",
        "origin": {"kind": "peer", "from": "uds:/x.sock", "name": "甲", "msg_id": "m2"}}})
    check("忙时收到的消息也认出来，正文从标签里取", items and items[0].get("peer", {}).get("body") == "正文在这" and items[0]["peer"].get("msgId") == "m2", str(items))
    check("普通的排队消息照旧是用户说的话", W.normalize_line(0, {"type": "attachment", "timestamp": now_ts(-1), "attachment": {
        "type": "queued_command", "prompt": "顺便看看日志"}})[0].get("t") == "user")
    snap = wait_for(lambda e: e["event"] == "snapshots" and any(x["sessionId"] == SID2 and x.get("turnFrom") == "peer" for x in e["sessions"]))
    check("快照标出这一轮是别的会话来信引起的（答完不提醒用户）", snap is not None)
    peer_proc.kill()

    # 这一轮是谁发起的：别的会话来信（peer）答完不提醒用户
    def turn_from(rows, path=None):
        path = path or tempfile.mkstemp(dir=root, suffix=".jsonl")[1]
        with open(path, "w") as handle:
            for row in rows:
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")
        return W.scan_transcript(path)["turnFrom"]

    def said(text, meta=False):
        return {"type": "user", "isMeta": meta, "message": {"role": "user", "content": text}}

    def reply(text="好的"):
        return {"type": "assistant", "uuid": "u-" + text, "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}

    def tool(i):
        return [{"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "t%d" % i, "name": "Bash", "input": {"command": "ls"}}]}},
                {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t%d" % i, "content": "ok"}]}}]

    peer_in = dict(said("<cross-session-message from=\"uds:/x.sock\">拍好了</cross-session-message>", meta=True),
                   origin={"kind": "peer", "from": "uds:/x.sock", "name": "甲", "msg_id": "m3"})

    def queued(prompt, origin=None):
        attachment = {"type": "queued_command", "prompt": prompt}
        if origin:
            attachment["origin"] = origin
        return {"type": "attachment", "attachment": attachment}
    check("你发起的一轮：user", turn_from([said("改一下首页"), reply()]) == "user")
    check("空闲时收到别的会话来信、由它开始的一轮：peer", turn_from([said("改一下首页"), reply(), peer_in, reply("已回复甲")]) == "peer")
    check("来信那一轮里你又插了一句：改回 user（你在等回复）",
          turn_from([peer_in] + tool(1) + [queued("顺便看看日志")] + [reply("日志正常")]) == "user")
    check("你那一轮里排队进来的来信不改发起方", turn_from([said("跑测试")] + tool(2) + [queued("<cross-session-message>x</cross-session-message>", peer_in["origin"]), reply("测试通过")]) == "user")
    check("技能展开、系统提示这类 isMeta 不算新一轮", turn_from([peer_in, said("Base directory for this skill: /x", meta=True), reply()]) == "peer")
    check("群里只有别的会话发言：peer", turn_from([said("【群「发版」· ccpulse-67（Mac · ccpulse）】\n快照拍好了\n（回复群里：kl group say \"内容\"；不需要回复就不用回）"), reply()]) == "peer")
    check("首次进群的说明 + 别的会话发言：peer", turn_from([said("【Kiteline 会话群「发版」】用户把这个会话和下面几个会话拉进了一个群……\n· 你：ccpulse-c2\n\n【群「发版」· ccpulse-67】\n拍好了"), reply()]) == "peer")
    check("群里有你说的话：user", turn_from([said("【群「发版」· ccpulse-67】\n拍好了\n【群「发版」· 用户】\n今晚发"), reply()]) == "user")
    long_path = os.path.join(root, "turn-long.jsonl")
    rows = [said("改一下首页"), reply(), peer_in]
    turn_from(rows, long_path)
    for i in range(300):
        rows += tool(100 + i)
    check("来信那一轮很长、开头滚出尾部：照样记得是 peer", turn_from(rows + [reply("都改好了")], long_path) == "peer")
    check("老记录没有发起方的线索：None（照旧提醒）", turn_from(tool(9) + [reply()]) is None)

    print("== 压缩上下文")
    check("压缩边界行不单独出条目", W.normalize_line(0, {"type": "system", "subtype": "compact_boundary", "timestamp": now_ts(-3)}) == [])
    summary = ("This session is being continued from a previous conversation that ran out of context. "
               "The summary below covers the earlier portion of the conversation.\n\n"
               "<tools-used-before-summary>Bash, Read</tools-used-before-summary>\nSummary:\n1. Primary Request and Intent:\n   改首页卡片间距\n\n"
               "If you need specific details from before compaction, read the full transcript at: /x.jsonl\n\n"
               "Continue the conversation from where it left off without asking the user any further questions.")
    items = W.normalize_line(0, {"type": "user", "isCompactSummary": True, "isVisibleInTranscriptOnly": True, "timestamp": now_ts(-2),
                                 "message": {"role": "user", "content": summary}})
    check("前情摘要不当成用户说的话：显示「上下文已压缩」，详情只留摘要正文",
          len(items) == 1 and items[0]["t"] == "event" and items[0]["text"] == "上下文已压缩"
          and items[0].get("detail") == "1. Primary Request and Intent:\n   改首页卡片间距", str(items))

    print("== 同一会话开在两个窗口")
    twin = subprocess.Popen(["sleep", "60"])
    twin_file = os.path.join(SESS, "%d.json" % twin.pid)
    with open(twin_file, "w") as handle:
        json.dump({"pid": twin.pid, "sessionId": SID, "cwd": CWD, "status": "busy", "name": "合成会话（另一个窗口）",
                   "entrypoint": "cli", "kind": "interactive", "startedAt": 2}, handle, ensure_ascii=False)
    snap = wait_for(lambda e: e["event"] == "snapshots" and any(s.get("pid") == twin.pid for s in e["sessions"]), timeout=10)
    same = [s for s in (snap or {}).get("sessions", []) if s.get("sessionId") == SID]
    check("两个进程挂着同一会话时只报一条（后打开的那个）", snap and len(same) == 1 and same[0].get("pid") == twin.pid,
          str([(s.get("sessionId"), s.get("pid")) for s in (snap or {}).get("sessions", [])]))
    os.remove(twin_file)
    twin.kill()

    print("== 其他")
    resp = call({"cmd": "tmux_send", "pid": fake.pid, "text": "hi", "submit": True})
    check("非 tmux 会话投递给出明确报错", resp and not resp["ok"] and "tmux" in resp["error"])
    resp = call({"cmd": "nope"})
    check("未知请求返回失败而不是崩溃", resp and not resp["ok"])
    with open(transcript, "w") as handle:
        handle.write("")
    check("transcript 被重写时发 reset", wait_for(lambda e: e["event"] == "reset") is not None)
    pasted = W.strip_reminders('<pasted_content id="ae88">\n手机发来的话\n</pasted_content id="ae88">')
    check("粘贴进来的消息去掉 Claude Code 套的 pasted_content 标签", pasted == "手机发来的话", repr(pasted))
    check("正文里只是提到 <pasted_content> 的不动", W.strip_reminders("提到 <pasted_content> 标签") == "提到 <pasted_content> 标签")

    print("== 网页测试报告（report）")
    pw_dir = os.path.join(root, "e2e-shop")
    os.makedirs(os.path.join(pw_dir, "test-results"))
    auto_png = os.path.join(pw_dir, "test-results", "test-failed-1.png")
    with open(auto_png, "wb") as handle:
        handle.write(PNG)
    shot = base64.b64encode(PNG).decode()
    expect_error = ("Error: \x1b[2mexpect(\x1b[22mlocator).toHaveText(expected) failed\n\nLocator:  getByRole('alert')\n"
                    "Expected: \"账号或密码不正确\"\nReceived: \"密码错误，请重试\"\nTimeout:  2000ms")
    results = {"config": {"version": "1.64.1"}, "stats": {"startTime": "2026-10-27T00:44:55.284Z", "duration": 7236.9},
               "suites": [{"title": "login.spec.ts", "file": "login.spec.ts", "specs": [], "suites": [{"title": "登录", "specs": [
                   {"title": "进入控制台", "file": "login.spec.ts", "line": 12, "tests": [{"projectName": "mobile", "status": "expected", "results": [
                       {"status": "passed", "duration": 1000, "steps": [{"title": "打开登录页", "duration": 300}, {"title": "提交", "duration": 500}],
                        "attachments": [{"name": "打开登录页", "contentType": "image/png", "body": shot},
                                        {"name": "提交", "contentType": "image/png", "body": shot}]}]}]},
                   {"title": "密码错误时提示", "file": "login.spec.ts", "line": 30, "tests": [{"projectName": "mobile", "status": "unexpected", "results": [
                       {"status": "failed", "duration": 2300, "errors": [{"message": expect_error}],
                        "steps": [{"title": "打开登录页", "duration": 100}, {"title": "看到错误提示", "duration": 2000, "error": {"message": "x"}}],
                        "attachments": [{"name": "打开登录页", "contentType": "image/png", "body": shot},
                                        {"name": "screenshot", "contentType": "image/png", "path": auto_png},
                                        {"name": "trace", "contentType": "application/zip", "path": "/nope/trace.zip"}]}]}]}]}]}]}
    with open(os.path.join(pw_dir, "results.json"), "w", encoding="utf-8") as handle:
        json.dump(results, handle, ensure_ascii=False)
    images = W._ReportImages(os.path.join(root, "report-img"))
    rep = W._report_from_playwright(results, pw_dir, images)
    T = W._REPORT_TEXT["zh"]
    passed, failed = rep["tests"]
    check("用例名带上 describe、去掉文件名一级", passed["title"] == "登录 › 进入控制台" and failed["status"] == "failed", passed["title"])
    check("截图按名字配到同名步骤", [bool(s["image"]) for s in passed["steps"]] == [True, True])
    check("自动截的失败图配给出错的那一步，trace 不当图片", [bool(s["image"]) for s in failed["steps"]] == [True, True]
          and len(failed["steps"]) == 2 and images.count == 4)
    check("报错去掉颜色码", "\x1b" not in failed["error"] and failed["error"].startswith("Error: expect(locator)"))
    check("断言失败说成「期望 / 实际」", W._report_reason(failed["error"], T) == "期望 “账号或密码不正确”，实际 “密码错误，请重试”",
          W._report_reason(failed["error"], T))
    check("找不到元素说成哪个元素", W._report_reason("Error: expect(locator).toBeVisible() failed\n\nLocator: getByText('今日订单')\n"
                                         "Expected: visible\nReceived: <element(s) not found>", T) == "页面上找不到 getByText('今日订单')")
    check("等元素超时说在等哪个", W._report_reason("Error: locator.click: Timeout 30000ms exceeded.\nCall log:\n"
                                       "  - waiting for getByRole('button', { name: '登录' })", T)
          == "超时，一直没等到 getByRole('button', { name: '登录' })")
    # 浏览器不出图：文字总览（SVG）转不成 PNG 就不带（客户端都显示不了，结论和计数在文字里），只发原始截图
    out = subprocess.run([sys.executable, WATCHER, "report", pw_dir, "--session", SID, "--title", "登录流程"],
                         env=shot_env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120).stdout.decode()
    ev = wait_for(lambda e: e["event"] == "entries" and e["items"][0]["t"] == "agent_image"
                  and (e["items"][0]["text"] or "").startswith("**登录流程"), timeout=10)
    check("report 发到会话：浏览器不出图时只发步骤截图、不带 SVG", ev is not None and len(ev["items"][0]["images"]) == 4
          and all(i["mime"] == "image/png" for i in ev["items"][0]["images"]) and "（会话 %s）" % SID[:8] in out, out.strip())
    if ev:
        caption = ev["items"][0]["text"]
        check("文字摘要：结论、计数、没通过的原因", caption.startswith("**登录流程：1 个用例未通过**\n共 2 个用例 · 1 个通过 · 1 个未通过 · 用时 7.2 秒")
              and "- 登录 › 密码错误时提示：期望 “账号或密码不正确”" in caption, caption)
    check("电脑上留一份 HTML 报告", "电脑上的完整报告" in out and glob.glob(os.path.join(DATA, "reports", "*", "report.html")), out)
    manifest = os.path.join(root, "steps.json")
    with open(manifest, "w", encoding="utf-8") as handle:
        json.dump({"title": "Checkout", "steps": [{"title": "Open cart", "screenshot": png_path}, "Pay"]}, handle)
    out = subprocess.run([sys.executable, WATCHER, "report", manifest, "--no-send", "--lang", "en"],
                         env=shot_env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60).stdout.decode()
    check("步骤清单格式（只有一个用例时 steps 写在最外层），英文", "**Checkout: All passed**\n1 test · 1 passed" in out, out)
    if W.find_browser()[0]:
        out = subprocess.run([sys.executable, WATCHER, "report", pw_dir, "--no-send"], env=env,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120).stdout.decode()
        pngs = [line.strip() for line in out.splitlines() if line.strip().endswith(".png")]
        sizes = [W.image_size(p) for p in pngs]
        check("有浏览器时出成手机宽的图（总览 + 两个用例）", len(pngs) == 3 and all(s and s[0] == 1170 for s in sizes), out)

    print("== 待办、关键信息（todo / keyinfo）")
    out = subprocess.run([sys.executable, WATCHER, "todo", "等虚拟机能开再改 Windows", "--detail", "补丁在 x.patch", "--session", SID],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30).stdout.decode()
    ev = wait_for(lambda e: e["event"] == "entries" and e["items"][0]["t"] == "agent_todo", timeout=10)
    check("todo 进对话：agent_todo 带标题、说明", ev is not None and ev["items"][0]["text"] == "等虚拟机能开再改 Windows"
          and ev["items"][0]["detail"] == "补丁在 x.patch" and ev["items"][0]["forUser"] is False, out)
    ref = ev["items"][0].get("ref", "") if ev else ""
    check("agent 自己的待办带编号（t-xxxxxx），输出里告诉它怎么更新", re.fullmatch(r"t-[0-9a-f]{6}", ref or "") is not None and ref in out
          and "todo start" in out, out)
    out = subprocess.run([sys.executable, WATCHER, "todo", "progress", ref, "Win11 测过了", "--session", SID],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30).stdout.decode()
    ev = wait_for(lambda e: e["event"] == "entries" and e["items"][0]["t"] == "agent_todo_update", timeout=10)
    check("todo progress 进对话：agent_todo_update 带编号、状态、进度、标题", ev is not None and ev["items"][0]["ref"] == ref
          and ev["items"][0]["status"] == "doing" and ev["items"][0]["progress"] == "Win11 测过了"
          and ev["items"][0]["title"] == "等虚拟机能开再改 Windows", out)
    out = subprocess.run([sys.executable, WATCHER, "todo", "list", "--session", SID],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30).stdout.decode()
    check("todo list 列出未完成的、带进度", ref in out and "Win11 测过了" in out, out)
    out = subprocess.run([sys.executable, WATCHER, "todo", "--user", "去申请 AppID", "--session", SID],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30).stdout.decode()
    ev = wait_for(lambda e: e["event"] == "entries" and e["items"][0]["t"] == "agent_todo" and e["items"][0]["forUser"] is True, timeout=10)
    check("todo --user：提醒用户（forUser），不给编号", ev is not None and not ev["items"][0].get("ref") and "已提醒用户" in out, out)
    out = subprocess.run([sys.executable, WATCHER, "keyinfo", "测试账号", "--field", "账号=a@b.c", "--secret", "密码=p@ss", "--session", SID],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30).stdout.decode()
    ev = wait_for(lambda e: e["event"] == "entries" and e["items"][0]["t"] == "agent_key", timeout=10)
    check("keyinfo 进对话：agent_key 各项、密码标 secret、拼好的纯文字", ev is not None
          and [f["secret"] for f in ev["items"][0]["fields"]] == [False, True] and ev["items"][0]["text"] == "测试账号\n账号：a@b.c\n密码：p@ss", out)
    out = subprocess.run([sys.executable, WATCHER, "keyinfo", "只有标题", "--session", SID], env=env,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
    check("keyinfo 没有内容不收", out.returncode == 2)
    live = json.load(open(os.path.join(DATA, "live-sessions.json"), encoding="utf-8"))
    check("守护进程写会话表（子命令认会话用）", any(r["sessionId"] == SID and r["cwd"] == CWD for r in live.get("sessions", [])), str(live)[:300])
    # 不带 --session、也不在 Claude 进程底下：在会话的工作目录里调用，按会话表认出来
    out = subprocess.run([sys.executable, WATCHER, "todo", "按目录认会话"], env=env, cwd=os.path.join(CWD),
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30).stdout.decode()
    ev = wait_for(lambda e: e["event"] == "entries" and e["items"][0]["t"] == "agent_todo" and e["sessionId"] == SID
                  and e["items"][0]["text"] == "按目录认会话", timeout=10)
    check("不带 --session：按会话表在当前目录认出会话", ev is not None, out)
    # 电脑端推来的 agent 待办（各会话、各台电脑合在一起）：别的会话 / 别的电脑上记的也列得出、关得掉；用户删掉的不再列
    other = "ssh:other#11111111-2222-3333-4444-555555555555"
    now = int(time.time() * 1000)
    reply = call({"cmd": "todos", "items": [
        {"ref": ref, "text": "等虚拟机能开再改 Windows", "status": "doing", "progress": "Win11 测过了", "key": "local#" + SID, "title": "本会话", "at": now},
        {"ref": "t-abc123", "text": "读取 VS Code 对话框并自动点 Open here anyway", "status": "pending", "key": other, "title": "断线提醒",
         "machine": "Ubuntu", "at": now},
        {"ref": "坏编号", "text": "x"}]})
    check("todos 请求：存下电脑端推来的那份（坏编号不收）", (reply or {}).get("count") == 2, str(reply))
    out = subprocess.run([sys.executable, WATCHER, "todo", "list", "--session", SID],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30).stdout.decode()
    check("todo list 也列别的会话、别的电脑上记的（带会话名、机器）", "t-abc123" in out and "「断线提醒」 · Ubuntu" in out, out)
    out = subprocess.run([sys.executable, WATCHER, "todo", "读取 VS Code 的对话框、自动点 Open here anyway", "--session", SID],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30).stdout.decode()
    dup = re.search(r"编号 (t-[0-9a-f]{6})", out)
    check("记待办时提示相近的（可能是同一件事）", "已有相近的待办" in out and "t-abc123" in out, out)
    out = subprocess.run([sys.executable, WATCHER, "todo", "done", "t-abc123", "这个会话顺手做掉了", "--session", SID],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30).stdout.decode()
    # 刚记的那条和这条更新可能在同一批里
    ev = wait_for(lambda e: e["event"] == "entries" and any(i["t"] == "agent_todo_update" and i.get("ref") == "t-abc123" for i in e["items"]), timeout=10)
    update = next((i for i in ev["items"] if i.get("ref") == "t-abc123"), {}) if ev else {}
    check("别的电脑上记的也能关：todo_update 进当前会话", update.get("status") == "done", out)
    check("更新完提醒这个会话名下还没关的", "这个会话名下还有" in out and ref in out and "todo done" in out, out)
    if dup:
        subprocess.run([sys.executable, WATCHER, "todo", "done", dup.group(1), "重复", "--session", SID], env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
    png_path2 = os.path.join(root, "nudge.png")
    shutil.copyfile(png_path, png_path2)
    out = subprocess.run([sys.executable, WATCHER, "send-image", png_path2, "--session", SID],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30).stdout.decode()
    check("发图时提醒这个会话还有没关的待办", "已发送 1 张" in out and "这个会话名下还有" in out and ref in out
          and "t-abc123" not in out.split("这个会话名下还有")[1], out)
    call({"cmd": "todos", "items": [{"ref": ref, "text": "等虚拟机能开再改 Windows", "status": "done", "key": "local#" + SID, "at": now + 600000}]})
    out = subprocess.run([sys.executable, WATCHER, "send-image", png_path2, "--session", SID],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30).stdout.decode()
    check("用户在手机上勾掉的、都关了：不再提醒", "这个会话名下还有" not in out or ref not in out.split("这个会话名下还有")[1], out)

    print("== 任务阶段（stage：列表里的「2/4 开发中」）")
    check("工具：读代码 → 调研，改项目里的文件 → 开发，往临时目录写草稿不算", W.stage_tool_kind("Read", {"file_path": "/x/a.py"})[0] == "research"
          and W.stage_tool_kind("Edit", {"file_path": CWD + "/a.py"}, CWD)[0] == "dev" and W.stage_tool_kind("Write", {"file_path": "/tmp/x.py"}, CWD)[0] is None
          and W.stage_tool_kind("Write", {"file_path": "/home/u/proj/x.py"}, CWD)[0] == "dev"
          and W.stage_tool_kind("TodoWrite", {})[0] is None and W.stage_tool_kind("Agent", {"subagent_type": "Explore"})[0] == "research")
    # 11-01 截图：改完代码派子 agent 在后台做浏览器实测，列表还停在「开发中」
    tasks = [W.stage_tool_kind("Agent", {"subagent_type": "general-purpose", "description": d}) for d in (
        "实测查重改为只提示", "帮助文档改为只提示口径", "查一下测试为什么失败", "Run e2e tests", "发版并上传", "整理会议纪要")]
    check("通用子 agent 按描述里最先出现的动词认：实测 → 测试、改文档 → 开发、查测试为何挂 → 调研、发版 → 发布、认不出不算", tasks == [
        ("test", None), ("dev", None), ("research", None), ("test", None), ("report", "release"), (None, None)], str(tasks))
    kinds = [W.stage_command_kind(c) for c in (
        "cd x && pytest -q", "ssh mac 'cd /a && bash build.sh'", "python3 ~/.ccpulse/ccpulse-watch.py send-image a.png --caption x",
        "git add -A && git commit -m x && git push", "ls -la && grep -rn foo .", "python3 ~/x/ccpulse-watch.py shot http://localhost:5173",
        "sed -i 's/a/b/' x.swift", "bash install.sh", "make-icon --help")]
    check("命令：测试、编译、发图汇报、提交安装各归各类，看不出来的不算", kinds == [
        ("test", None), ("dev", None), ("report", "report"), ("report", "release"), (None, None), ("test", None),
        ("dev", None), ("report", "release"), (None, None)], str(kinds))
    kinds = [W.stage_command_kind(c) for c in (
        "python3 tools/release/release.py --help", "grep -rn 'git push' docs", "cat install.sh", "ssh mac 'cd /a && bash install.sh'",
        "python3 - <<'EOF'\nopen('a.py', 'w').write('x')\nEOF", "bash ios/build.sh device")]
    check("只读的（--help、grep、cat 脚本）不算发布；ssh 里装、heredoc 脚本写文件、装手机各归各类", kinds == [
        (None, None), (None, None), (None, None), ("report", "release"), ("dev", None), ("report", "release")], str(kinds))
    long_cmd = "python3 - <<'EOF'\n" + "x = 1\n" * 3000 + "EOF\ntimeout 600 python3 tests/test_watcher.py"
    line = {"type": "assistant", "timestamp": "2026-10-31T10:00:00.000Z", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": long_cmd}}]}}
    long_item = W.normalize_line(0, line)[0]
    check("超长命令给手机时截断，截断前先按完整命令认好（后半截在跑测试）", "已截断" in long_item["input"]["command"]
          and long_item.get("_sk") == ["test", None], str(long_item.get("_sk")))
    W.STAGE_DIR, W.STAGE_FLOWS_FILE = os.path.join(root, "stage-unit"), os.path.join(root, "stage-flows-unit.json")
    tracker = W.StageTracker()
    stage_base = int(time.time() * 1000) + 10000   # 条目时间晚于「开始空闲」：用户的话总是在空闲之后到

    def stage_at(i):
        return stage_base + i * 1000

    def stage_tool(i, name, **inp):
        return {"t": "tool", "ts": stage_at(i), "name": name, "input": inp}

    def stage_view(activity="busy", sid="st-1"):
        snaps = [{"sessionId": sid, "activity": activity, "cwd": CWD}]
        tracker.annotate(snaps)
        return snaps[0].get("stage")

    tracker.feed("st-1", [{"t": "user", "ts": stage_at(0), "text": "做个功能"}, stage_tool(1, "Read", file_path="/a"),
                          stage_tool(1, "Bash", command="ip -4 -br addr")])
    check("只是问问题、查资料、跑条命令（还没动手改东西）：不显示阶段", stage_view() is None)
    seq = [(2, "Edit", {"file_path": CWD + "/a.py"}, 2), (3, "Read", {"file_path": "/b"}, 2), (4, "Bash", {"command": "pytest"}, 3),
           (5, "Edit", {"file_path": CWD + "/a.py"}, 3), (6, "Edit", {"file_path": CWD + "/a.py"}, 3), (7, "Bash", {"command": "pytest"}, 3),
           (8, "Bash", {"command": "python3 ~/.ccpulse/ccpulse-watch.py send-image a.png"}, 4)]
    got = []
    for i, name, inp, _ in seq:
        tracker.feed("st-1", [stage_tool(i, name, **inp)])
        got.append(stage_view()["step"])
    check("改文件 → 开发，跑测试 → 测试，之后再改代码也不退回（只进不退），发图 → 汇报", got == [s for *_, s in seq], str(got))
    check("动手以后显示：前面的调研也算进这一轮的时间线（1/4 调研了解从用户发话起）", stage_view()["marks"][0] == [1, stage_at(0)])
    check("第 4 步发图是「汇报中」", stage_view()["label"] == "汇报中")
    tracker.feed("st-1", [stage_tool(9, "Bash", command="git push")])
    v = stage_view()
    check("提交推送 → 「发布中」；这一轮走过的步骤和时间都在", v["label"] == "发布中" and v["marks"] == [
        [1, stage_at(0)], [2, stage_at(2)], [3, stage_at(4)], [4, stage_at(8)]]
        and v["since"] == stage_at(8) and v["turnAt"] == stage_at(0), str(v))
    check("空闲时不带阶段", stage_view("idle") is None)
    tracker.feed("st-1", [{"t": "user", "ts": stage_at(20), "text": "下一个"}])
    W._write_json(os.path.join(W.STAGE_DIR, "st-1.json"), {"marks": [{"step": 3, "ts": stage_at(1), "note": "上一轮的"},
                                                                     {"step": 3, "ts": stage_at(21), "note": "跑集成测试"}]})
    v = stage_view()
    check("agent 报的优先（上一轮报的不算）：3/4 测试中、带说明", v and (v["step"], v["note"], v["auto"]) == (3, "跑集成测试", False), str(v))
    tracker.feed("st-1", [stage_tool(22, "Edit", file_path=CWD + "/a.py"), stage_tool(23, "Edit", file_path=CWD + "/a.py")])
    check("agent 报过以后推断不往回拽", stage_view()["step"] == 3)
    tracker.feed("st-1", [stage_tool(24, "Bash", command="bash release.sh")])
    v = stage_view()
    check("agent 忘了报下一步：推断往前跟上", (v["step"], v["label"], v["note"]) == (4, "发布中", None), str(v))
    os.remove(os.path.join(W.STAGE_DIR, "st-1.json"))
    W._write_json(W.STAGE_FLOWS_FILE, {CWD: {"steps": ["调研了解", "方案设计", "开发中", "测试中", "评审", "上架"]}})
    tracker.feed("st-1", [{"t": "user", "ts": stage_at(30), "text": "按我们的流程"}, stage_tool(31, "Edit", file_path=CWD + "/a.py")])
    v = stage_view()
    check("没规划时项目记的流程不参与推断：按默认四步（2/4 开发中）", v and (v["step"], v["total"], v["label"]) == (2, 4, "开发中"), str(v))
    tracker.feed("st-1", [stage_tool(32, "Bash", command="npm test"), stage_tool(33, "Bash", command="git push")])
    v = stage_view()
    check("推断：测试 → 提交推送 4/4 发布中", (v["step"], v["label"]) == (4, "发布中"), str(v))
    stage_view("idle")
    tracker.idle_since["st-1"] = stage_at(60)
    check("空闲 → 忙、没有用户那句话（别的会话发来的消息叫醒）：新一轮从头算（还没动手前不显示）", stage_view() is None
          and tracker.turns["st-1"]["kind"] == "research")
    stage_view("idle")
    now_ms = int(time.time() * 1000)
    tracker.feed("st-1", [{"t": "user", "ts": now_ms + 500, "text": "x"}, {"t": "tool", "ts": now_ms + 600, "name": "Edit", "input": {"file_path": CWD + "/a"}}])
    check("用户那句话先到、已经开过新一轮：变忙时不再从头算", stage_view()["step"] == 2)
    W._write_json(os.path.join(W.STAGE_DIR, "st-1.json"), {"steps": ["复现", "定位", "修复", "验证", "汇报"], "plan": stage_at(70), "ts": stage_at(71),
                                                           "marks": [{"step": 3, "ts": stage_at(71), "note": "改边界条件"}]})
    tracker.feed("st-1", [{"t": "user", "ts": stage_at(72), "text": "继续"}, stage_tool(73, "Read", file_path="/a")])
    v = stage_view()
    check("规划过的任务跨轮保留：用户说「继续」不从第 1 步重算（按这次任务自己的步骤）", v and (v["step"], v["total"], v["label"], v["turnAt"]) == (3, 5, "修复", stage_at(70)), str(v))
    parts_state = {"steps": ["开发", "测试", "安装"], "plan": stage_at(80), "ts": stage_at(86), "part": "iPhone",
                   "parts": [{"name": "Mac", "step": 3, "done": True}, {"name": "iPhone", "step": 2, "done": False}, {"name": "Windows/Linux", "step": 0, "done": False}],
                   "marks": [{"step": 1, "ts": stage_at(81), "part": "Mac"}, {"step": 3, "ts": stage_at(83), "part": "Mac"},
                             {"step": 1, "ts": stage_at(85), "part": "iPhone"}, {"step": 2, "ts": stage_at(86), "part": "iPhone", "note": "跑单元测试"}]}
    W._write_json(os.path.join(W.STAGE_DIR, "st-1.json"), parts_state)
    v = stage_view()
    check("分了几部分：说的是正在做的那部分（iPhone 2/3 测试），各部分进度都带上", v and (v["part"], v["step"], v["total"], v["label"], v["note"]) == ("iPhone", 2, 3, "测试", "跑单元测试")
          and [(p["name"], p["step"], p["done"]) for p in v["parts"]] == [("Mac", 3, True), ("iPhone", 2, False), ("Windows/Linux", 0, False)]
          and v["marks"] == [[1, stage_at(85)], [2, stage_at(86)]], str(v))
    tracker.feed("st-1", [stage_tool(87, "Bash", command="pytest")])
    check("报过以后同一类的动作不往后挪：测试里再跑测试仍是 2/3", stage_view()["step"] == 2)
    tracker.feed("st-1", [stage_tool(87, "Bash", command="bash install.sh")])
    v = stage_view()
    check("agent 忘了报下一步、动作正好是下一步（安装）：跟上 3/3，标成自动识别、不挂上一步的说明",
          (v["part"], v["step"], v["label"], v["note"], v["auto"]) == ("iPhone", 3, "安装", None, True), str(v))
    for p in parts_state["parts"]:
        p["done"] = True
    W._write_json(os.path.join(W.STAGE_DIR, "st-1.json"), parts_state)
    check("各部分都做完：任务结束，不再显示这个任务", stage_view() is None)
    tracker.feed("st-1", [stage_tool(88, "Edit", file_path=CWD + "/b.py")])
    v = stage_view()
    check("之后再动手：回到按这一轮推断（默认四步、不带部分）", v and "parts" not in v and v["total"] == 4, str(v))
    # 10-31 截图的问题：规划了自定的 7 步却一次没报，推断把改代码套到「设计方案」上，在 2/7 和 6/7 之间来回跳
    W._write_json(os.path.join(W.STAGE_DIR, "st-1.json"), {"steps": ["摸清现有链路", "设计方案", "主机与watcher", "Mac和iPhone界面", "Windows/Linux", "自测", "装机汇报"],
                                                           "plan": stage_at(90), "ts": stage_at(90), "marks": []})
    seen = []
    for i, call in enumerate([("Edit", {"file_path": CWD + "/a.py"}), ("Bash", {"command": "bash /tmp/kx/check.sh"}), ("Bash", {"command": "python3 - <<'EOF'\nopen('a','w').write('x')\nEOF"}),
                              ("Bash", {"command": "pytest"}), ("Edit", {"file_path": CWD + "/b.py"})]):
        tracker.feed("st-1", [stage_tool(91 + i, call[0], **call[1])])
        v = stage_view()
        seen.append((v["step"], v["total"]))
    check("规划了自定步骤却没报：稳定显示第 1 步，不按工具调用乱跳", seen == [(1, 7)] * 5, str(seen))
    W._write_json(os.path.join(W.STAGE_DIR, "st-1.json"), {"steps": ["摸清现有链路", "设计方案", "主机与watcher", "Mac和iPhone界面", "Windows/Linux", "自测", "装机汇报"],
                                                           "plan": stage_at(90), "ts": stage_at(97), "marks": [{"step": 4, "ts": stage_at(97)}]})
    tracker.feed("st-1", [stage_tool(98, "Bash", command="pytest")])
    check("报了第 4 步就是第 4 步（不被推断挪走）", (stage_view()["step"], stage_view()["label"]) == (4, "Mac和iPhone界面"))
    tracker.feed("st-1", [stage_tool(99, "Edit", file_path=CWD + "/c.py")])
    check("下一步认不出是哪一类（Windows/Linux）：跑测试、改代码都不越过它跳到「自测」", stage_view()["step"] == 4)
    # 11-01 截图的问题：报了「2 定位」以后开始改代码却没报，一直停在定位
    steps = ["取崩溃报告", "定位", "修复", "验证", "装机汇报"]
    tracker.feed("st-1", [{"t": "user", "ts": stage_at(100), "text": "崩溃了"}, stage_tool(101, "Edit", file_path=CWD + "/x.swift"),
                          stage_tool(104, "Bash", command="python3 ~/.ccpulse/ccpulse-watch.py stage 2 --note '查侧栏代码'")])
    W._write_json(os.path.join(W.STAGE_DIR, "st-1.json"), {"steps": steps, "plan": stage_at(100), "ts": stage_at(104) + 500,
                                                           "marks": [{"step": 2, "ts": stage_at(104) + 500, "note": "查侧栏代码"}]})
    seen = []
    for i, call in enumerate([("Read", {"file_path": CWD + "/x.swift"}), ("Edit", {"file_path": CWD + "/x.swift"}), ("Read", {"file_path": CWD + "/y.swift"}),
                              ("Bash", {"command": "pytest"}), ("Edit", {"file_path": CWD + "/x.swift"}), ("Bash", {"command": "python3 ~/.ccpulse/ccpulse-watch.py send-image a.png"}),
                              ("Bash", {"command": "pytest"})]):
        tracker.feed("st-1", [stage_tool(105 + i, call[0], **call[1])])
        v = stage_view()
        seen.append((v["step"], v["label"], v["note"]))
    check("报了「定位」以后改代码 → 跟到「修复」（报之前就改过也认），跑测试 → 「验证」，回去改代码不退，发图 → 「装机汇报」",
          seen == [(2, "定位", "查侧栏代码"), (3, "修复", None), (3, "修复", None), (4, "验证", None), (4, "验证", None),
                   (5, "装机汇报", None), (5, "装机汇报", None)], str(seen))
    v = stage_view()
    check("跟上的步骤记在时间线里（用时从跟上那刻算）", v["marks"] == [[2, stage_at(104) + 500], [3, stage_at(106)],
                                                          [4, stage_at(108)], [5, stage_at(110)]] and v["since"] == stage_at(110), str(v["marks"]))
    W._write_json(os.path.join(W.STAGE_DIR, "st-1.json"), {"steps": ["复现", "定位", "修复", "验证", "汇报"], "plan": stage_at(120), "ts": stage_at(120), "marks": []})
    tracker.feed("st-1", [stage_tool(121, "Bash", command="pytest"), stage_tool(122, "Edit", file_path=CWD + "/x.swift")])
    v = stage_view()
    check("规划了还没报：跑测试复现不动，动手改代码跨过「定位」跟到「修复」", (v["step"], v["label"], v["auto"]) == (3, "修复", True), str(v))
    # 11-01 反馈：「有办法弄精准吗」→ agent 该报没报时经 kiteline-stages mod 提醒它自己报
    tracker.nudge_dir = os.path.join(root, "stage-nudge")
    nudge_file = os.path.join(tracker.nudge_dir, "st-1.json")
    stage_view()
    note = W._read_json(nudge_file, {})
    check("推断替 agent 跟到下一步：留提醒请它确认、补上说明（带这台电脑上的 stage 命令）", "列表自动跟到了第 3/5 步「修复」" in note.get("text", "")
          and "stage 3" in note.get("text", "") and note.get("id", "").startswith("inf::3@"), str(note))
    tracker.nudged["st-1"] = ("inf::3", 0)   # 当作很久以前留的：同一件事也不再留
    os.remove(nudge_file)
    stage_view()
    check("同一件事只提醒一次", not os.path.exists(nudge_file))
    W._write_json(os.path.join(W.STAGE_DIR, "st-1.json"), {"steps": ["复现", "定位", "修复", "验证", "汇报"], "plan": stage_at(120), "ts": stage_at(123),
                                                           "marks": [{"step": 3, "ts": stage_at(123), "note": "改边界条件"}]})
    tracker.feed("st-1", [{"t": "text", "ts": stage_at(124), "text": "后端改完，接下来在开发库上实际跑一遍。"}])
    tracker.nudged["st-1"] = ("old", 0)
    v = stage_view()
    note = W._read_json(nudge_file, {})
    check("agent 说要进下一步（说明文字小模型认出「测试」）却没报：列表不动、提醒它报", v["step"] == 3 and "你说接下来要测试" in note.get("text", ""), str(note))
    tracker.nudged["st-1"] = ("old", 0)
    tracker.feed("st-1", [{"t": "text", "ts": stage_at(125), "text": "现在改前端。"}])
    os.remove(nudge_file)
    stage_view()
    check("说的还是这一步的活（改代码）：不提醒", not os.path.exists(nudge_file))
    stage_view("idle")
    os.remove(os.path.join(W.STAGE_DIR, "st-1.json"))
    long_ago = int(time.time() * 1000) - 5 * 60000
    tracker.idle_since["st-1"] = long_ago - 1000
    tracker.feed("st-1", [{"t": "user", "ts": long_ago, "text": "改个东西"}, {"t": "tool", "ts": long_ago + 500, "name": "Bash", "input": {"command": "pytest"}},
                          {"t": "tool", "ts": long_ago + 1000, "name": "Edit", "input": {"file_path": CWD + "/a"}}])
    tracker.nudged["st-1"] = ("old", 0)
    stage_view()
    note = W._read_json(nudge_file, {})
    check("没规划却已经动手 3 分钟以上（先跑测试再改代码的也算）：提醒它规划步骤", "还没规划步骤" in note.get("text", "") and "stage --steps" in note.get("text", ""), str(note))
    os.remove(nudge_file)
    tracker.nudged["st-2"] = ("old", 0)
    tracker.feed("st-2", [{"t": "user", "ts": long_ago, "text": "改个东西"}, {"t": "tool", "ts": long_ago + 1000, "name": "Edit", "input": {"file_path": CWD + "/a"}}])
    snaps = [{"sessionId": "st-2", "activity": "busy", "cwd": CWD, "agent": "codex"}]
    tracker.annotate(snaps)
    check("别家 agent（装不上提醒 mod）不留提醒；快照里也不带提醒", not os.path.exists(os.path.join(tracker.nudge_dir, "st-2.json"))
          and "_nudge" not in (snaps[0].get("stage") or {}), str(snaps[0].get("stage")))
    tracker.nudge_dir = None
    said = [W.stage_text_kind(t)[0] for t in ("后端改完，接下来在宿主机开发库上实际跑一遍这个函数。", "现在改前端。", "先看一下现在的代码是怎么取数据的。", "类型检查通过。提交并发版。")]
    check("说明文字小模型：接下来实际跑一遍 → 测试、改前端 → 开发、先看代码 → 调研、提交发版 → 发布", said == ["test", "dev", "research", "report"], str(said))
    mod_root = os.path.join(root, "claude-mod")
    os.makedirs(mod_root)
    W.sync_stage_mod(mod_root, enabled=True)
    register = open(os.path.join(mod_root, "skills", "kiteline-stages", "hooks", "register.ts"), encoding="utf-8").read()
    check("任务阶段技能开着：装上提醒 mod（工具调用之后附提醒、只给主对话、同一条只附一次）", "on('tool.call'" in register and "kiteline/stage/" in register
          and "e.agentId !== undefined" in register and "delivered" in register)
    W.sync_stage_mod(mod_root, enabled=False)
    check("关掉任务阶段技能：提醒 mod 一起删掉", not os.path.exists(os.path.join(mod_root, "skills", "kiteline-stages")))
    W.STAGE_DIR, W.STAGE_FLOWS_FILE = os.path.join(DATA, "stage"), os.path.join(DATA, "stage-flows.json")

    out = subprocess.run([sys.executable, WATCHER, "stage", "测试", "--note", "跑集成测试", "--session", SID],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30).stdout.decode()
    check("stage 命令：按步骤名报（测试 → 3/4）", "3/4 测试中" in out, out)
    ev = wait_for(lambda e: e["event"] == "snapshots" and any((s.get("stage") or {}).get("note") == "跑集成测试" for s in e["sessions"]), timeout=10)
    stage = next((s["stage"] for s in ev["sessions"] if s["sessionId"] == SID), None) if ev else None
    check("快照带上 agent 报的阶段（忙着的会话）", stage and (stage["step"], stage["total"], stage["label"], stage["auto"]) == (3, 4, "测试中", False), str(stage))
    out = subprocess.run([sys.executable, WATCHER, "stage", "发布", "--session", SID],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30).stdout.decode()
    check("写「发布」显示成 4/4 发布中", "4/4 发布中" in out, out)
    out = subprocess.run([sys.executable, WATCHER, "stage", "--steps", "复现,定位,修复,验证,汇报", "--session", SID],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30).stdout.decode()
    check("--steps 按这次任务规划步骤，不记成项目流程", "已规划这次任务" in out and "3 修复" in out
          and not os.path.exists(os.path.join(DATA, "stage-flows.json")), out)
    out = subprocess.run([sys.executable, WATCHER, "stage", "--steps", "调研了解,方案设计,开发中,测试中,发布中", "--remember", "--session", SID],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30).stdout.decode()
    flows = json.load(open(os.path.join(DATA, "stage-flows.json"), encoding="utf-8"))
    check("--remember 记成这个项目以后的默认流程", "已记成这个项目以后的默认流程" in out and flows.get(CWD, {}).get("steps", [None])[1] == "方案设计", out + str(flows))
    out = subprocess.run([sys.executable, WATCHER, "stage", "--steps", "default", "--session", SID],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30).stdout.decode()
    check("--steps default：用这个项目记过的流程；提醒之后每一步都要报", "2 方案设计" in out and "每进入一步都要报" in out, out)
    out = subprocess.run([sys.executable, WATCHER, "stage", "2", "--session", SID],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30).stdout.decode()
    check("按序号报：2/5 方案设计", "2/5 方案设计" in out, out)
    bad = subprocess.run([sys.executable, WATCHER, "stage", "9", "--session", SID], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
    check("超出流程的步骤不收、告诉它现在的流程", bad.returncode == 2 and "方案设计" in bad.stdout.decode(), bad.stdout.decode())
    out = subprocess.run([sys.executable, WATCHER, "stage", "--steps", "default", "--remember", "--session", SID],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30).stdout.decode()
    check("--steps default --remember：这个项目恢复默认四步", "这个项目已恢复默认流程" in out and CWD not in json.load(open(os.path.join(DATA, "stage-flows.json"), encoding="utf-8")), out)
    out = subprocess.run([sys.executable, WATCHER, "stage", "--steps", "开发,测试,安装", "--parts", "Mac,iPhone,Windows/Linux", "--session", SID],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30).stdout.decode()
    check("--parts 分几部分（斜杠不拆开）", "分 3 部分：Mac、iPhone、Windows/Linux" in out, out)
    out = subprocess.run([sys.executable, WATCHER, "stage", "测试", "--part", "mac", "--note", "侧栏", "--session", SID],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30).stdout.decode()
    check("--part 不分大小写：Mac · 2/3 测试", "Mac · 2/3 测试" in out, out)
    bad = subprocess.run([sys.executable, WATCHER, "stage", "1", "--part", "Android", "--session", SID], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
    check("没有的部分不收、列出现在分的", bad.returncode == 2 and "Windows/Linux" in bad.stdout.decode(), bad.stdout.decode())
    out = subprocess.run([sys.executable, WATCHER, "stage", "done", "--part", "Mac", "--session", SID],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30).stdout.decode()
    check("done --part：这部分做完，告诉它还剩哪些", "还剩：iPhone、Windows/Linux" in out, out)
    ev = wait_for(lambda e: e["event"] == "snapshots" and any((s.get("stage") or {}).get("part") == "iPhone" for s in e["sessions"]), timeout=10)
    stage = next((s["stage"] for s in ev["sessions"] if s["sessionId"] == SID), None) if ev else None
    check("快照：接着做下一部分（iPhone 1/3），Mac 标做完", stage and stage["step"] == 1 and stage["parts"][0] == {"name": "Mac", "step": 3, "done": True}, str(stage))
    stage_file = os.path.join(DATA, "stage", SID + ".json")
    old_state = json.load(open(stage_file, encoding="utf-8"))
    W._write_json(stage_file, dict(old_state, plan=old_state["plan"] - 30 * 60000, ts=int(time.time() * 1000) - 30 * 60000,
                                   marks=[dict(m, ts=m["ts"] - 30 * 60000) for m in old_state["marks"]]))
    shutil.copyfile(png_path, os.path.join(root, "nudge2.png"))
    out = subprocess.run([sys.executable, WATCHER, "send-image", os.path.join(root, "nudge2.png"), "--session", SID],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30).stdout.decode()
    check("规划了任务却很久没报：发图时提醒补报", "列表上这个会话还停在第" in out and "stage <第几步>" in out, out)
    out = subprocess.run([sys.executable, WATCHER, "stage", "done", "--all", "--session", SID],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30).stdout.decode()
    ev = wait_for(lambda e: e["event"] == "snapshots" and any(s["sessionId"] == SID and "parts" not in (s.get("stage") or {}) for s in e["sessions"]), timeout=10)
    check("done --all：整个任务做完，不再带这个任务的部分", "任务做完了" in out and ev is not None, out)

    print("== 技能（装到各家 agent 的技能目录）")
    # 在子进程里用临时的家目录跑：绝不能动这台电脑真的 ~/.claude、~/.codex、~/.dsh
    fake_home = os.path.join(root, "home")
    for name in (".claude/skills/user-own", ".codex", ".dsh"):
        os.makedirs(os.path.join(fake_home, name))
    with open(os.path.join(fake_home, ".claude/skills/user-own/SKILL.md"), "w") as handle:
        handle.write("用户自己的技能\n")
    skill_env = dict(os.environ, HOME=fake_home, CODEX_HOME=os.path.join(fake_home, ".codex"), DSH_HOME=os.path.join(fake_home, ".dsh"),
                     CCPULSE_DATA_DIR=os.path.join(fake_home, ".ccpulse"), CCPULSE_PLUGINS_DIR=os.path.join(fake_home, "plugins"))
    probe = ("import importlib.util, json, sys\nspec = importlib.util.spec_from_file_location('w', sys.argv[1])\n"
             "W = importlib.util.module_from_spec(spec); spec.loader.exec_module(W)\n"
             "print(json.dumps(W.sync_skills(set(filter(None, sys.argv[2].split(','))))))")

    def sync(ids):
        raw = subprocess.run([sys.executable, "-c", probe, WATCHER, ids], env=skill_env, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, timeout=30).stdout.decode()
        return json.loads(raw.strip().splitlines()[-1])

    result = sync("screenshots,todos")
    todo_skill = os.path.join(fake_home, ".codex", "skills", "tars-todos", "SKILL.md")
    text = open(todo_skill, encoding="utf-8").read() if os.path.exists(todo_skill) else ""
    check("装到 Claude、Codex、DeepSeek Harness 的技能目录（开着的两个）", sorted(t["agent"] for t in result["targets"]) == ["claude-code", "codex", "deepseek-harness"]
          and len(result["installed"]) == 6, str(result)[:300])
    check("正文里的命令换成这台电脑上的写法、带版本标记", "<!-- tars-todos v" in text and "{{cmd}}" not in text and " todo \"" in text, text[:200])
    check("内容一样就不再写", sync("screenshots,todos")["installed"] == [])
    stage_skill = os.path.join(fake_home, ".claude", "skills", "tars-stages", "SKILL.md")
    result = sync("screenshots,todos,stages")
    text = open(stage_skill, encoding="utf-8").read() if os.path.exists(stage_skill) else ""
    check("任务阶段技能：描述里就带着这台电脑上的 stage 命令（不用打开技能也会报）", len(result["installed"]) == 3
          and " stage <第几步>" in text.split("---")[1] and "{{cmd}}" not in text and "<!-- tars-stages v" in text, text[:300])
    result = sync("screenshots")
    check("关掉的按标记删掉，用户自己的技能不动", len(result["removed"]) == 6 and not os.path.exists(todo_skill) and not os.path.exists(stage_skill)
          and os.path.exists(os.path.join(fake_home, ".claude/skills/user-own/SKILL.md")), str(result)[:300])

    print("== 订阅额度（limits）")
    lim_root = os.path.join(root, "limits")
    claude_dir = os.path.join(lim_root, "claude")
    os.makedirs(claude_dir)
    check("装上额度插件（plugin.json、hooks.json、register.ts）", W.sync_limits_mod(claude_dir)
          and all(os.path.exists(os.path.join(claude_dir, "skills", "kiteline-usage", *rel.split("/"))) for rel in W.LIMITS_MOD_FILES))
    mod_ts = os.path.join(claude_dir, "skills", "kiteline-usage", "hooks", "register.ts")
    stamp = os.path.getmtime(mod_ts)
    time.sleep(0.05)
    W.sync_limits_mod(claude_dir)
    check("内容一样就不再写", os.path.getmtime(mod_ts) == stamp)
    other = os.path.join(lim_root, "other")
    os.makedirs(os.path.join(other, "skills", "kiteline-usage", "hooks"))
    with open(os.path.join(other, "skills", "kiteline-usage", "hooks", "register.ts"), "w") as fh:
        fh.write("// 用户自己的")
    check("别人放的同名文件夹（没有我们的标记）不碰", not W.sync_limits_mod(other)
          and open(os.path.join(other, "skills", "kiteline-usage", "hooks", "register.ts")).read() == "// 用户自己的")
    check("没装 Claude Code 的电脑不装", not W.sync_limits_mod(os.path.join(lim_root, "none")))
    now = 1793439538685
    os.makedirs(os.path.join(claude_dir, "kiteline"))
    with open(os.path.join(claude_dir, "kiteline", "limits.json"), "w") as fh:
        json.dump({"at": now - 60000, "sessionId": "s1", "limits": [
            {"kind": "five_hour", "percentUsed": 8, "resetsAt": "2026-10-31T14:10:00.000Z"},
            {"kind": "seven_day", "percentUsed": 13.25, "resetsAt": "2026-11-07T03:00:00+00:00"},
            {"kind": "spend_limit", "percentUsed": 50, "resetsAt": "2026-10-01T00:00:00Z"}]}, fh)
    got = W.claude_limits(claude_dir, now=now)
    check("Claude：mod 写的额度读成 5 小时 / 每周，重置时间换成毫秒（Z 和 +00:00 都认）", got and got["agent"] == "claude-code" and got["windows"][:2] == [
        {"kind": "five_hour", "percent": 8.0, "resetsAt": 1793455800000},
        {"kind": "seven_day", "percent": 13.2, "resetsAt": 1794020400000}], str(got))
    check("过了重置时间的窗口算 0、标 reset", got and got["windows"][2] == {"kind": "spend_limit", "percent": 0.0, "resetsAt": None, "reset": True}, str(got))
    check("读数太旧（超过 8 天）不报", W.claude_limits(claude_dir, now=now + 9 * 86400000) is None)
    codex_home = os.path.join(lim_root, "codex")
    day_dir = os.path.join(codex_home, "sessions", "2026", "10", "31")
    os.makedirs(day_dir)
    with open(os.path.join(day_dir, "rollout-2026-10-31T09-00-00-a.jsonl"), "w") as fh:
        fh.write(json.dumps({"timestamp": "2026-10-31T09:00:00.000Z", "type": "event_msg", "payload": {"type": "token_count", "rate_limits": {
            "primary": {"used_percent": 30.0, "window_minutes": 300, "resets_at": 1793455800},
            "secondary": {"used_percent": 70.5, "window_minutes": 10080, "resets_at": 1794020400}, "plan_type": "plus"}}}) + "\n")
        fh.write(json.dumps({"timestamp": "2026-10-31T09:05:00.000Z", "type": "event_msg", "payload": {"type": "token_count", "rate_limits": {
            "primary": {"used_percent": 42.0, "window_minutes": 300, "resets_in_seconds": 3600}, "secondary": None, "plan_type": "plus"}}}) + "\n")
        fh.write(json.dumps({"timestamp": "2026-10-31T09:06:00.000Z", "type": "response_item", "payload": {"type": "message"}}) + "\n")
    got = W.codex_limits(codex_home, now=now)
    at = W._iso_ms("2026-10-31T09:05:00.000Z")
    check("Codex：取 rollout 里最后一次额度，按窗口分钟数认 5 小时；只有相对秒数时按事件时间算重置", got and got["agent"] == "codex" and got["plan"] == "plus"
          and got["windows"] == [{"kind": "five_hour", "percent": 42.0, "resetsAt": at + 3600000, "minutes": 300}], str(got))
    check("没有 Codex 记录返回空", W.codex_limits(os.path.join(lim_root, "nocodex"), now=now) is None)
    installed = os.path.getmtime(mod_ts) * 1000
    old = {"sessionId": "a", "agent": "claude-code", "startedAt": installed - 60000}
    new = {"sessionId": "b", "startedAt": installed + 60000}
    check("开着的会话全是插件装上之前启动的：提示新开会话", W.claude_limits_pending([old], claude_dir))
    check("有插件装上之后开的会话（还没读数多半没用订阅）、没有会话、别家 agent 的会话：都不提示",
          not W.claude_limits_pending([old, new], claude_dir) and not W.claude_limits_pending([], claude_dir)
          and not W.claude_limits_pending([dict(old, agent="codex")], claude_dir))

    print("== 目标（/goal：Claude Code 2.1.139 起、Codex 0.128 起）")
    # 字段照 Claude Code 2.1.314 真实写进记录的样子（tools/agent-probe/fakellm.py 的 [goal:N] 实测过）
    def goal_att(ts, **fields):
        return {"type": "attachment", "timestamp": ts, "attachment": dict(type="goal_status", **fields)}
    goal_lines = [
        goal_att("2026-11-02T09:00:00Z", met=False, sentinel=True, condition="测试全部通过"),
        {"type": "system", "subtype": "local_command", "timestamp": "2026-11-02T09:00:00Z",
         "content": "<local-command-stdout>Goal set: 测试全部通过</local-command-stdout>"},
        goal_att("2026-11-02T09:05:00Z", met=False, condition="测试全部通过", reason="还有 2 个用例失败"),
        {"type": "system", "subtype": "informational", "level": "notice", "timestamp": "2026-11-02T09:06:00Z",
         "content": "Goal paused · the goal check timed out · send a message to continue"},
    ]
    meter = W.ClaudeGoal()
    for line in goal_lines:
        meter.feed(line)
    view = meter.view()
    check("Claude：设定后每次检查记一次、留着检查的说法（还差什么），停下的提示记成原因",
          view["text"] == "测试全部通过" and view["state"] == "active" and view["checks"] == 1
          and view["reason"] == "还有 2 个用例失败" and view["note"] == "目标检查超时", str(view))
    book = W.GoalBook()
    W._GOALS["g1"] = meter
    snaps = [{"sessionId": "g1", "activity": "idle"}]
    book.annotate(snaps)
    check("目标还在、会话闲下来又有停下的提示：paused", snaps[0]["goal"]["state"] == "paused", str(snaps[0].get("goal")))
    meter.feed({"type": "user", "timestamp": "2026-11-02T09:07:00Z", "message": {"role": "user", "content": "继续"}})
    snaps = [{"sessionId": "g1", "activity": "busy"}]
    book.annotate(snaps)
    check("你发了话、又忙起来：回到进行中，停下的原因清掉", snaps[0]["goal"]["state"] == "active" and "note" not in snaps[0]["goal"])
    snaps = [{"sessionId": "g1", "activity": "idle"}]
    book.annotate(snaps)
    check("刚闲下来（每轮检查目标时会短暂空闲；没有停下的提示）：还算进行中，不来回跳", snaps[0]["goal"]["state"] == "active")
    book.idle_since["g1"] -= W.GOAL_IDLE_PAUSE_MS + 1000
    book.annotate(snaps)
    check("闲满 2 分钟（没有明确信号的兜底）：paused", snaps[0]["goal"]["state"] == "paused")
    meter.feed({"type": "user", "timestamp": "2026-11-02T09:08:00Z", "message": {"role": "user", "content": "继续"}})
    meter.feed({"type": "user", "timestamp": "2026-11-02T09:09:00Z", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "t1", "content": "x"}, {"type": "text", "text": "[Request interrupted by user for tool use]"}]}})
    book.idle_since.pop("g1", None)
    snaps = [{"sessionId": "g1", "activity": "idle"}]
    book.annotate(snaps)
    check("你按了中断：马上算停下（原因「这一轮被中断」），不用等 2 分钟", snaps[0]["goal"]["state"] == "paused"
          and snaps[0]["goal"]["note"] == "这一轮被中断", str(snaps[0].get("goal")))
    meter.feed(goal_att(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), met=True, condition="测试全部通过", reason="全部通过",
                        iterations=3, durationMs=600000, tokens=45000))
    snaps = [{"sessionId": "g1", "activity": "idle"}]
    book.annotate(snaps)
    goal = snaps[0]["goal"]
    check("达成：met，带用了几轮、多久、多少 token", goal["state"] == "met" and goal["turns"] == 3 and goal["durationMs"] == 600000
          and goal["tokens"] == 45000 and goal["checks"] == 2, str(goal))
    meter.goal["at"] -= W.GOAL_KEEP_MS + 1000
    snaps = [{"sessionId": "g1", "activity": "idle"}]
    book.annotate(snaps)
    check("结束了的目标挂 6 小时就不再给", "goal" not in snaps[0])
    failed = W.ClaudeGoal()
    for line in (goal_att("2026-11-02T10:00:00Z", met=False, sentinel=True, condition="x"),
                 goal_att("2026-11-02T10:01:00Z", met=False, failed=True, condition="x", reason="没有这个集群", iterations=1)):
        failed.feed(line)
    check("做不到：failed，说法是为什么", failed.view()["state"] == "failed" and failed.view()["reason"] == "没有这个集群")
    errored = W.ClaudeGoal()
    for line in (goal_att("2026-11-02T10:00:00Z", met=False, sentinel=True, condition="x"),
                 goal_att("2026-11-02T10:02:00Z", met=True, sentinel=True, condition="x"),
                 {"type": "system", "timestamp": "2026-11-02T10:02:00Z",
                  "content": "Goal cleared after an unrecoverable error (credit balance too low): \"x\". Run /goal again to continue."}):
        errored.feed(line)
    check("出了救不回来的错被清掉：error，原因换成中文", errored.view()["state"] == "error" and errored.view()["reason"] == "余额不足", str(errored.view()))
    cleared = W.ClaudeGoal()
    for line in (goal_att("2026-11-02T10:00:00Z", met=False, sentinel=True, condition="x"),
                 goal_att("2026-11-02T10:02:00Z", met=True, sentinel=True, condition="x")):
        cleared.feed(line)
    W._GOALS["g2"] = cleared
    snaps = [{"sessionId": "g2", "activity": "idle"}]
    book.annotate(snaps)
    check("你自己 /goal clear 的：快照里不再带目标", cleared.view()["state"] == "cleared" and "goal" not in snaps[0])
    W._GOALS.pop("g1", None)
    W._GOALS.pop("g2", None)
    # 自己跟着读文件：第一次检查和设定落在同一秒也不会拿着上一个目标判断（11-02 真机：假模型 1 秒跑完，推了一条「已完成」）
    goal_file = os.path.join(root, "goal-poll.jsonl")
    with open(goal_file, "w") as fh:
        fh.write(json.dumps(goal_att("2026-11-02T11:00:00Z", met=True, condition="旧目标", reason="ok", iterations=1)) + "\n")
    polled = W.ClaudeGoal()
    polled.scan(goal_file)
    with open(goal_file, "a") as fh:
        fh.write(json.dumps(goal_att("2026-11-02T11:01:00Z", met=False, sentinel=True, condition="新目标")) + "\n")
        fh.write('{"type": "attachment", "attachm')   # 还没写完的一行
    W._GOALS["g3"] = polled
    snaps = [{"sessionId": "g3", "activity": "idle", "transcriptPath": goal_file}]
    book.annotate(snaps)
    check("快照时先读文件新写完的行：新设的目标马上认出，没写完的那行不读", snaps[0]["goal"]["text"] == "新目标"
          and snaps[0]["goal"]["state"] == "active" and polled.offset < os.path.getsize(goal_file), str(snaps[0].get("goal")))
    W._GOALS.pop("g3", None)
    items = [it for offset, line in enumerate(goal_lines) for it in W.normalize_line(offset, line)]
    check("对话里：/goal 的回显 → 「已设定目标」（轻点看目标）、每次检查一行、停下一行，不再露 <local-command-stdout>", [
        (it["text"], it.get("goal"), it.get("detail")) for it in items] == [
        ("已设定目标", "set", "测试全部通过"), ("目标尚未达成，继续工作", "check", "还有 2 个用例失败"), ("目标已暂停：目标检查超时", "paused", None)], str(items))
    model = W.normalize_line(0, {"type": "system", "subtype": "local_command", "content": "<local-command-stdout>Set model to Opus</local-command-stdout>"})
    check("别的斜杠命令回显也去掉外面那层标签", model and model[0]["text"] == "Set model to Opus", str(model))
    met = W.normalize_line(5, goal_att("2026-11-02T09:09:00Z", met=True, condition="x", reason="ok", iterations=3, durationMs=1000, tokens=9))
    check("达成那一行带 goalStats（新客户端显示用了几轮、多久）", met[0]["text"] == "目标已达成" and met[0]["goalStats"] == {"turns": 3, "durationMs": 1000, "tokens": 9})
    check("暂停提示的几种原因都换成中文", W.goal_notice("Goal still active · the API was unavailable or the connection dropped · retrying in 5 min (2/3) · send a message to retry now")
          == ("paused", "接口不可用或连接中断，5 分钟后自动重试")
          and W.goal_notice("Goal paused after 3 automatic retries · the API returned an unexpected response · send a message to continue")
          == ("paused", "自动重试 3 次未成功：接口返回异常"))
    check("Claude Code 版本够不够用 /goal：2.1.139 起", W.goal_supported("2.1.139") and W.goal_supported("2.1.314")
          and not W.goal_supported("2.1.138") and not W.goal_supported(None) and not W.goal_supported("2.0.90"))
    check("/goal 命令：设定 / 清除（clear、stop……）/ 暂停 / 继续 / 只看", W.goal_command("/goal 把测试跑通") == ("set", "把测试跑通")
          and W.goal_command("/goal clear") == ("clear", "") and W.goal_command("/goal Stop") == ("clear", "")
          and W.goal_command("/goal pause") == ("pause", "") and W.goal_command("/goal") == ("show", "")
          and W.goal_command("/goals 不是") is None and W.goal_command("帮我看看 /goal") is None)
    # Codex：目标在 goals_N.sqlite 的 thread_goals 表（0.163 实测的表结构），对话记录里是 <codex_internal_context source="…">
    codex_home = tempfile.mkdtemp(prefix="kl-codex-goal-")
    db = W.sqlite3.connect(os.path.join(codex_home, "goals_1.sqlite"))
    db.execute("create table thread_goals (thread_id text primary key, goal_id text, objective text, status text, token_budget integer, "
               "tokens_used integer, time_used_seconds integer, created_at_ms integer, updated_at_ms integer)")
    db.executemany("insert into thread_goals values (?,?,?,?,?,?,?,?,?)", [
        ("t1", "g", "把测试跑通", "active", None, 9020, 18, 1793611372000, 1793611391000),
        ("t2", "g", "迁移数据", "budget_limited", 50000, 50100, 600, 1793611372000, 1793611391000),
        ("t3", "g", "写文档", "complete", None, 220, 1, 1793611372000, 1793611391000)])
    db.commit()
    db.close()
    saved_home = W.CODEX_HOME
    W.CODEX_HOME = codex_home
    try:
        goals = W.codex_goals()
    finally:
        W.CODEX_HOME = saved_home
    check("Codex：从目标库读出每个会话的目标，状态换成同一套（预算用完 → limited 带原因，complete → met）",
          goals["t1"] == {"text": "把测试跑通", "state": "active", "since": 1793611372000, "at": 1793611391000, "tokens": 9020, "durationMs": 18000}
          and goals["t2"]["state"] == "limited" and goals["t2"]["budget"] == 50000 and goals["t2"]["note"] == "token 预算已用完"
          and goals["t3"]["state"] == "met", str(goals))
    W.CODEX_HOME = os.path.join(codex_home, "none")
    try:
        check("没装带目标的 Codex：None（不给设定目标的按钮）", W.codex_goals() is None)
    finally:
        W.CODEX_HOME = saved_home
    shutil.rmtree(codex_home, ignore_errors=True)

    def codex_user(text):
        return {"timestamp": "2026-11-02T09:22:52Z", "type": "response_item", "payload": {
            "type": "message", "role": "user", "content": [{"type": "input_text", "text": text}]}}
    got = [W.normalize_codex_line(i, codex_user(t)) for i, t in enumerate((
        '<codex_internal_context source="user_goal">\nUser set the goal: "把测试跑通"\nUser set goal status: "active".\n</codex_internal_context>',
        '<codex_internal_context source="goal">\nContinue working toward the active thread goal.\n</codex_internal_context>',
        '<codex_internal_context source="user_goal">\nUser set goal status: "paused".\n</codex_internal_context>',
        '<codex_internal_context source="world">\n别的内部上下文\n</codex_internal_context>'))]
    check("Codex 记录：设定 / 每轮续做 / 暂停显示成一行提示，别的内部上下文不当成你说的话", [[(it["t"], it["text"]) for it in row] for row in got] == [
        [("event", "已设定目标")], [("event", "继续推进目标")], [("event", "已暂停目标")], []] and got[0][0]["detail"] == "把测试跑通", str(got))

    print("== 后台送达（kiteline mod 收件箱）")
    br_root = os.path.join(root, "bridge-mod")
    os.makedirs(br_root)
    check("装上后台送达插件（plugin.json、hooks.json、register.ts），内容一样不再写", W.sync_bridge_mod(br_root)
          and all(os.path.exists(os.path.join(br_root, "skills", "kiteline", *rel.split("/"))) for rel in W.BRIDGE_MOD_FILES)
          and W.sync_bridge_mod(br_root))
    check("register.ts 带标记、插件名就是 kiteline（VS Code 里标「Prompt from the kiteline plugin」）",
          W.BRIDGE_MOD_FILES["hooks/register.ts"].startswith("// kiteline v1：")
          and json.loads(W.BRIDGE_MOD_FILES[".claude-plugin/plugin.json"])["name"] == "kiteline")
    check("不带参数：测试 watcher（没有 CCPULSE_SKILLS）不往真实的 ~/.claude 里装、也不抛", "CCPULSE_SKILLS" in os.environ or W.sync_bridge_mod() is False)
    mod_ts = W.BRIDGE_MOD_FILES["hooks/register.ts"]
    check("mod：斜杠命令走 $.command.run，以「/」开头的普通话垫零宽空格（源码里是转义写法）",
          "$.command.run(" in mod_ts and "`\\u200b${text}` : text" in mod_ts and "await deliver($, { id: item.id, text: item.text, cmd })" in mod_ts and "\u200b" not in mod_ts)
    pb = mod_ts.split("on('classic.PostToolBatch'")[1].split("on('tool.call'")[0]
    check("mod：Claude 忙时发来的斜杠命令也排进队（带 cmd），不插进这一轮，这一轮做完（turn.complete）再执行",
          "later.push({ id: item.id, text: item.text, ...(cmd ? { cmd } : {}) })" in mod_ts
          and "if (q.cmd) {" in pb and "later.push(q)" in pb
          and "await deliver($, q)" in mod_ts.split("on('turn.complete'")[1].split("on('classic.PostToolBatch'")[0]
          and "void $.command.run({ command: slash[0], args: slash[1] })" in mod_ts)
    check("读记录时去掉垫的零宽空格：手机上显示、核对送达都照原话", W.user_string_item("\u200b/Users/x 看看", {"id": "1"})["text"] == "/Users/x 看看")
    check("手机经 mod 发来、排队进来的话算你说的；别的插件的不算",
          W.normalize_line(0, {"type": "attachment", "timestamp": ts(1), "attachment": {
              "type": "queued_command", "prompt": "手机上说的", "origin": {"kind": "plugin", "name": "kiteline", "asUser": True}}})[0].get("t") == "user"
          and W.normalize_line(0, {"type": "attachment", "timestamp": ts(1), "attachment": {
              "type": "queued_command", "prompt": "别的插件", "origin": {"kind": "plugin", "name": "other"}}}) == [])
    check("mod：Claude 忙时发的话留着，下一批工具跑完插进这一轮（session.append），没赶上的这一轮完了再提交",
          "classic.PostToolBatch" in mod_ts and "$.session.append(" in mod_ts and "result = 'later'" in mod_ts
          and "later.splice(0)" in mod_ts.split("on('turn.complete'")[1].split("on('classic.PostToolBatch'")[0])
    check("mod：插进去的话开头垫零宽空格（watcher 靠它认）", "text: `\\u200b${q.text}`" in mod_ts.split("on('classic.PostToolBatch'")[1].split("on('tool.call'")[0])
    check("mod：排队的话写进 <会话>.queue.json，认 queue 指令（move / edit / delete / now），alive 标 v2",
          "queue.json" in mod_ts and "item.op === 'queue'" in mod_ts and all("item.action === '%s'" % a in mod_ts for a in ("move", "edit", "delete", "now"))
          and "v: 2" in mod_ts and set(W.BRIDGE_QUEUE_ACTIONS) == {"move", "edit", "delete", "now"} and "queue" in W.BRIDGE_OPS)
    q_dir = W.bridge_dir()
    os.makedirs(q_dir, exist_ok=True)
    q_started = int(time.time() * 1000) - 5000
    with open(os.path.join(q_dir, "q-v1.alive"), "w") as handle:
        json.dump({"at": q_started + 1000, "v": 1}, handle)
    with open(os.path.join(q_dir, "q-v2.alive"), "w") as handle:
        json.dump({"at": q_started + 1000, "v": 2}, handle)
    with open(os.path.join(q_dir, "q-v2.queue.json"), "w") as handle:
        json.dump({"items": [{"id": "a1", "text": "先这个"}, {"id": "b2", "text": "再这个"}, {"id": "c3", "text": "/effort high", "cmd": True}, {"bad": 1}]}, handle)
    check("排队列表：v2 的 mod 读出队列（坏条目跳过），v1（老 mod）回 None，快照 bridge 仍是真",
          W.bridge_queue("q-v2", q_started) == [{"id": "a1", "text": "先这个"}, {"id": "b2", "text": "再这个"}, {"id": "c3", "text": "/effort high", "cmd": True}]
          and W.bridge_queue("q-v1", q_started) is None and W.bridge_alive("q-v1", q_started) == 1 and W.bridge_alive("q-v2", q_started) == 2)
    for name in ("q-v1.alive", "q-v2.alive", "q-v2.queue.json"):
        os.remove(os.path.join(q_dir, name))
    meta_row = {"type": "user", "isMeta": True, "timestamp": ts(1), "uuid": "m1",
                "message": {"role": "user", "content": [{"type": "text", "text": "\u200b顺便看看 README"}]}}
    got_said = W.normalize_line(0, dict(meta_row, origin={"kind": "plugin", "name": "kiteline"}))
    check("插进这一轮的那行（isMeta、来源 kiteline、垫了零宽空格）照你说的显示、去掉零宽空格；别的 isMeta 行照旧不显示",
          [(it["t"], it["text"]) for it in got_said] == [("user", "顺便看看 README")]
          and W.normalize_line(0, meta_row) == [] and W.normalize_line(0, dict(meta_row, origin={"kind": "plugin", "name": "other"})) == [], str(got_said))
    kl = {"kind": "plugin", "name": "kiteline"}
    caveat = {"type": "user", "isMeta": True, "timestamp": ts(1), "uuid": "c1", "origin": kl, "message": {"role": "user", "content":
              "<local-command-caveat>The command below was run directly in Claude Code, not sent to you as a request.</local-command-caveat>"}}
    skill_body = {"type": "user", "isMeta": True, "timestamp": ts(1), "uuid": "s1", "origin": kl,
                  "message": {"role": "user", "content": [{"type": "text", "text": "Base directory for this skill: /x"}]}}
    check("手机发斜杠命令时 Claude Code 写的说明行、展开的技能正文（也是 isMeta + kiteline）不显示成你说的话（11-05 截图）",
          W.normalize_line(0, caveat) == [] and W.normalize_line(0, skill_body) == [])
    said_path = os.path.join(root, "bridge-said.jsonl")
    with open(said_path, "w") as handle:
        handle.write(json.dumps({"type": "user", "timestamp": ts(1), "uuid": "p1", "origin": {"kind": "peer", "from": "x"}, "isMeta": True,
                                 "message": {"role": "user", "content": "<cross-session-message from=\"x\">来信</cross-session-message>"}}, ensure_ascii=False) + "\n")
        handle.write(json.dumps(dict(meta_row, origin=kl), ensure_ascii=False) + "\n")
    check("别的会话来信开始的一轮，中途插进你的话：这一轮算你的（答完照常推送）", W.scan_transcript(said_path).get("turnFrom") == "user",
          str(W.scan_transcript(said_path).get("turnFrom")))

    saved_cfg = os.environ.get("CLAUDE_CONFIG_DIR")
    os.environ["CLAUDE_CONFIG_DIR"] = os.path.join(root, "claude")   # 本进程里的 bridge_* 也指到临时目录
    try:
        inbox = W.bridge_dir()
        os.makedirs(inbox, exist_ok=True)
        br_proc = subprocess.Popen(["sleep", "60"])
        BR_SID = "bbbbbbbb-5555-6666-7777-888888888888"
        started = int(time.time() * 1000)
        open(os.path.join(transcript_dir, BR_SID + ".jsonl"), "w").close()
        with open(os.path.join(SESS, "%d.json" % br_proc.pid), "w") as handle:
            json.dump({"pid": br_proc.pid, "sessionId": BR_SID, "cwd": CWD, "status": "idle", "name": "送达会话",
                       "entrypoint": "claude-vscode", "kind": "interactive", "startedAt": started}, handle, ensure_ascii=False)
        alive = os.path.join(inbox, BR_SID + ".alive")
        with open(alive, "w") as handle:
            json.dump({"at": started - 5000}, handle)
        check("alive 早于这个进程启动（上一个进程留下的）：不算", not W.bridge_alive(BR_SID, started))
        with open(alive, "w") as handle:
            json.dump({"at": started + 300}, handle)
        os.utime(alive, (time.time() + 1, time.time() + 1))
        check("这个进程启动后 mod 写的 alive：算", W.bridge_alive(BR_SID, started) and not W.bridge_alive("没有这个会话", started))
        snap = wait_for(lambda e: e["event"] == "snapshots" and any(x["sessionId"] == BR_SID and x.get("bridge") for x in e["sessions"]), timeout=12)
        check("快照带 bridge = true（电脑端据此不切前台）", snap is not None)

        # 假的 mod：照收件箱的条目写回执，记下收到了什么
        got, stop = [], threading.Event()

        def fake_mod():
            seen = set()
            path = os.path.join(inbox, BR_SID + ".json")
            while not stop.is_set():
                for item in W._bridge_items(path):
                    if item["id"] in seen or item.get("expires", 0) < time.time() * 1000:
                        continue
                    seen.add(item["id"])
                    got.append(item)
                    with open(os.path.join(inbox, "%s.ack-%s.json" % (BR_SID, item["id"])), "w") as handle:
                        json.dump({"result": "none" if item["op"] == "perm" else "ok"}, handle)
                time.sleep(0.1)

        def ask(payload, timeout=15):
            # 文件前面的 call 名字被别处占了：同样经 stdin 发请求、等回应
            counter[0] += 1
            payload["id"] = "br%d" % counter[0]
            proc.stdin.write((json.dumps(payload, ensure_ascii=False) + "\n").encode())
            proc.stdin.flush()
            return wait_for(lambda e: e.get("event") == "response" and e.get("id") == payload["id"], timeout)

        mod_thread = threading.Thread(target=fake_mod, daemon=True)
        mod_thread.start()
        resp = ask({"cmd": "bridge", "sessionId": BR_SID, "op": "send", "text": "手机上发的第一句"})
        check("经 watcher 送进会话：收件箱里是这句话，回 bridged + ok", resp and resp.get("bridged") is True and resp.get("result") == "ok"
              and got and got[-1]["op"] == "send" and got[-1]["text"] == "手机上发的第一句", str(resp))
        resp = ask({"cmd": "bridge", "sessionId": BR_SID, "op": "perm", "decision": "allow"})
        check("确认框已经没了（电脑上答过）：回 result none，电脑端不再补按键", resp and resp.get("bridged") and resp.get("result") == "none", str(resp))
        check("送完收件箱清空、回执删掉", not os.path.exists(os.path.join(inbox, BR_SID + ".json"))
              and not glob.glob(os.path.join(inbox, BR_SID + ".ack-*")))
        resp = ask({"cmd": "bridge", "sessionId": BR_SID, "op": "keys", "text": "x"})
        check("不认识的指令不送", resp and resp.get("bridged") is False, str(resp))

        # 同一条指令（bid）电脑端问了两遍（第一次的回应没等到）：只送一次，第二次拿到同一个结果
        before = len(got)
        first = ask({"cmd": "bridge", "sessionId": BR_SID, "op": "send", "text": "只该送一次", "bid": "bid-once-1"})
        again = ask({"cmd": "bridge", "sessionId": BR_SID, "op": "send", "text": "只该送一次", "bid": "bid-once-1"})
        check("带编号的指令重复询问：mod 只收到一次，第二次回同一个结果并标 repeat",
              first and first.get("bridged") is True and again and again.get("bridged") is True and again.get("repeat") is True
              and again.get("result") == first.get("result") and len(got) == before + 1, "%s / %s / %d" % (first, again, len(got) - before))
        other = ask({"cmd": "bridge", "sessionId": BR_SID, "op": "send", "text": "另一条", "bid": "bid-once-2"})
        check("换了编号就是新指令，照常送", other and other.get("bridged") is True and len(got) == before + 2 and got[-1]["text"] == "另一条")
        check("握手里声明 bridge_bid（电脑端据此才敢拿同一个编号重问）", "bridge_bid" in W.FEATURES)

        # 发消息不排在慢查询后面：慢查询（历史列表、用量报表……）在后台线程算，送进会话的请求由读线程直接分出去
        shell = object.__new__(W.Watcher)
        shell.sessions, shell.live, shell.agents = {}, set(), {}
        emitted, real_emit, real_list = [], W.emit, W.list_sessions
        W.emit = lambda obj: emitted.append((time.time(), obj))
        W.list_sessions = lambda *a, **k: (time.sleep(1.5), [])[1]
        try:
            t0 = time.time()
            shell.respond(json.dumps({"cmd": "sessions_list", "id": "slow1"}))
            returned = time.time() - t0
            shell.respond(json.dumps({"cmd": "ping", "id": "p1"}))
            pinged = time.time() - t0
            deadline = time.time() + 5
            while time.time() < deadline and not any(o.get("id") == "slow1" for _, o in emitted):
                time.sleep(0.05)
            order = [o.get("id") for _, o in emitted]
            slow_at = next((t - t0 for t, o in emitted if o.get("id") == "slow1"), 0)
            check("慢查询不占住请求线：历史列表要 1.5 秒，respond 立刻返回，后到的 ping 先回，慢查询算完照常回",
                  returned < 0.3 and pinged < 0.4 and order == ["p1", "slow1"] and 1.3 < slow_at < 4
                  and emitted[-1][1].get("ok") is True and emitted[-1][1].get("sessions") == [], "%.2f %.2f %s %.2f" % (returned, pinged, order, slow_at))
            # 统计类一次只算一个（几个一起算内存叠加、互相抢解释器）；文件类另走一档，不排在统计后面
            del emitted[:]
            real_dirs = W.list_dirs
            W.list_dirs = lambda *a, **k: {"dirs": []}
            t1 = time.time()
            shell.respond(json.dumps({"cmd": "sessions_list", "id": "h1"}))
            shell.respond(json.dumps({"cmd": "sessions_list", "id": "h2"}))
            shell.respond(json.dumps({"cmd": "dirs", "id": "d1", "path": "/tmp"}))
            deadline = time.time() + 8
            while time.time() < deadline and len(emitted) < 3:
                time.sleep(0.05)
            at = {o.get("id"): t - t1 for t, o in emitted}
            heavy = sorted(v for k, v in at.items() if k in ("h1", "h2"))
            check("统计类查询一次只算一个（两个各 1.5 秒：第二个约 3 秒才回）；列目录这类不排在它们后面",
                  len(at) == 3 and at.get("d1", 9) < 1.0 and len(heavy) == 2 and 1.3 < heavy[0] < 2.6 and 2.8 < heavy[1] < 4.8, str(at))
            W.list_dirs = real_dirs
            W.trim_memory()   # 不抛就行（Linux 上把内存还给系统，别的系统只做垃圾回收）
            # 别家 agent 的会话从只读变成可操作（进了 tmux / 后台伪终端）、或在后台运行：快照要重新推，各端跟着换界面
            base_snap = {"sessionId": "x", "agent": "pi", "activity": "idle", "readOnly": True}
            check("只读 ↔ 可操作、是否在后台运行都算快照变化",
                  W.signature(base_snap) != W.signature(dict(base_snap, readOnly=False))
                  and W.signature(base_snap) != W.signature(dict(base_snap, hosted="abc")), "")
            # 终端屏幕模拟（托管伪终端的读屏）：喂进输出，问现在屏幕上是什么字
            E = "\x1b"
            vt = W.VTScreen(40, 8)
            vt.feed(("第一行\r\n第二行\r\n" + E + "[31m红字" + E + "[0m 普通").encode("utf-8"))
            check("屏幕：普通输出按行落位，颜色不算字", vt.text() == "第一行\n第二行\n红字 普通", repr(vt.text()))
            vt.feed((E + "[2A\r" + E + "[2K改过的第一行" + E + "[2B\r").encode("utf-8"))
            check("屏幕：光标上移、清掉整行再重写（Ink 这类界面重画的写法）", vt.text().split("\n")[0] == "改过的第一行" and vt.text().split("\n")[1] == "第二行", repr(vt.text()))
            vt.feed((E + "[2J" + E + "[H" + "❯ 1. Yes\r\n  2. No" + E + "[1;3H" + "X").encode("utf-8"))
            check("屏幕：清屏、回到左上角、按行列定位改一个字", vt.text() == "❯ X. Yes\n  2. No", repr(vt.text()))
            vt.feed((E + "[?1049h" + "全屏界面" + E + "[?1049l").encode("utf-8"))
            check("屏幕：进出备用屏后主屏还在", vt.text() == "❯ X. Yes\n  2. No", repr(vt.text()))
            vt.feed((E + "[2J" + E + "[H" + "中文AB" + E + "[1;3H" + E + "[K").encode("utf-8"))
            check("屏幕：汉字占两格（第 3 列是第二个汉字的起点）", vt.text() == "中", repr(vt.text()))
            vt.feed((E + "[2J" + E + "[H" + "\r\n".join("行%d" % i for i in range(12))).encode("utf-8"))
            check("屏幕：写满了往上滚，留下最后几行；能只要最后几行", vt.text().split("\n")[-1] == "行11" and vt.text().split("\n")[0] == "行4" and vt.text(2) == "行10\n行11", repr(vt.text()))
            vt.feed((E + "]0;窗口标题\x07" + E + "[2J" + E + "[H" + "a" + E + "[5C" + "b" + E + "[3D" + E + "[1P").encode("utf-8"))
            check("屏幕：标题这类序列不算字；光标右移留空格、删一个字符后面的左移", vt.text() == "a    b", repr(vt.text()))
            half = "中".encode("utf-8")
            vt.feed((E + "[2J" + E + "[H").encode("utf-8") + half[:1])
            vt.feed(half[1:] + (E + "[").encode("utf-8"))
            vt.feed("2Cz".encode("utf-8"))
            check("屏幕：一个字、一段控制序列被拆在两次输出里也认得", vt.text() == "中  z", repr(vt.text()))
            vt.resize(30, 5)
            check("屏幕：改大小不丢左上角的字", vt.text() == "中  z" and vt.cols == 30 and vt.rows == 5, repr(vt.text()))
            # 后台运行前先看项目文件夹读不读得了：macOS 等用户点「允许访问文稿」时读目录会一直卡着，不能跟着卡
            real_scandir = W.os.scandir
            gate = threading.Event()

            def stuck_scandir(path):
                if str(path).endswith("要授权"):
                    gate.wait(10)
                return real_scandir(tempfile.gettempdir() if str(path).endswith("要授权") else path)

            W.os.scandir = stuck_scandir
            try:
                t2 = time.time()
                first = W.folder_reachable("/tmp/要授权", timeout=0.5)
                took_first = time.time() - t2
                t2 = time.time()
                again = W.folder_reachable("/tmp/要授权", timeout=0.5)
                took_again = time.time() - t2
                check("目录读起来卡住（系统在等用户允许）：到时间就算读不了；它回来之前再问直接答读不了，不再多开线程等",
                      first is False and 0.4 < took_first < 1.5 and again is False and took_again < 0.2, "%.2f %.2f" % (took_first, took_again))
                gate.set()
                time.sleep(0.3)
                check("用户点了允许之后：读得了", W.folder_reachable("/tmp/要授权", timeout=0.5) is True)
                check("读得了的目录、没有的目录", W.folder_reachable(tempfile.gettempdir()) is True and W.folder_reachable("/没有/这个/目录") is False)
            finally:
                gate.set()
                W.os.scandir = real_scandir
            check("统计类和文件类分开登记", W.HEAVY_CMDS <= W.SLOW_CMDS and "usage_report" in W.HEAVY_CMDS and "read_file" in W.SLOW_CMDS - W.HEAVY_CMDS)
            saved_fast = W._FAST["watcher"]
            W._FAST["watcher"] = None
            check("快车道：watcher 还没准备好时照常排队", W.fast_lane(json.dumps({"cmd": "bridge", "id": "f0"})) is False)
            W._FAST["watcher"] = shell
            del emitted[:]
            check("快车道：后台送达、写终端的请求由读线程直接分出去；别的请求、终端按键以外的照常排队",
                  W.fast_lane(json.dumps({"cmd": "bridge", "id": "f1", "sessionId": "没有", "op": "send"})) is True
                  and W.fast_lane(json.dumps({"cmd": "history", "id": "f2", "note": "\"bridge\""})) is False
                  and W.fast_lane(json.dumps({"cmd": "ping", "id": "f3"})) is False and W.fast_lane("{坏的 \"bridge\"") is False)
            deadline = time.time() + 3
            while time.time() < deadline and not emitted:
                time.sleep(0.05)
            check("快车道上的请求照常应答（会话不在：bridged false）", [o.get("id") for _, o in emitted] == ["f1"] and emitted[0][1].get("bridged") is False, str(emitted))
            # 同一个会话连发几条：按到达的先后一条一条做（第一条慢也不让后面的抢先）；别的会话不等它
            order, lane_lock = [], threading.Lock()
            real_handle = shell.handle

            def slow_first(request):
                if request.get("id") == "a1":
                    time.sleep(0.5)
                with lane_lock:
                    order.append(request.get("id"))
                return {"bridged": False}

            shell.handle = slow_first
            try:
                t3 = time.time()
                for rid, sid in (("a1", "甲"), ("a2", "甲"), ("b1", "乙"), ("a3", "甲"), ("a4", "甲")):
                    W.fast_lane(json.dumps({"cmd": "bridge", "id": rid, "sessionId": sid, "op": "send", "text": rid}))
                fed = time.time() - t3
                time.sleep(0.2)
                early = list(order)
                deadline = time.time() + 4
                while time.time() < deadline and len(order) < 5:
                    time.sleep(0.05)
                check("快车道：同一会话连发的几条按先后做完（第一条慢，后面的不抢先）；别的会话的不等它；读线程不被占住",
                      [x for x in order if x.startswith("a")] == ["a1", "a2", "a3", "a4"] and early == ["b1"] and fed < 0.2 and not W._LANES,
                      "%s %s %.2f %s" % (order, early, fed, list(W._LANES)))
                real_thread = W.threading.Thread

                class NoThread:
                    def __init__(self, *a, **k):
                        pass

                    def start(self):
                        raise RuntimeError("can't start new thread")

                W.threading.Thread = NoThread
                try:
                    taken = W.fast_lane(json.dumps({"cmd": "bridge", "id": "n1", "sessionId": "丙", "op": "send"}))
                finally:
                    W.threading.Thread = real_thread
                check("快车道：线程开不出来时这条照常排队（返回 False），不抛异常、不留下占着的线", taken is False and not W._LANES, str(list(W._LANES)))
            finally:
                shell.handle = real_handle
            W._FAST["watcher"] = saved_fast
        finally:
            W.emit, W.list_sessions = real_emit, real_list

        # 记录里没有在等的调用（11-07 实测：会话弹出提问框后，这一轮一直没写进记录）：从 mod 写的 asks.json 补
        asks = os.path.join(inbox, BR_SID + ".asks.json")
        quiz = {"questions": [{"question": "要部署吗", "header": "确认", "multiSelect": False,
                               "options": [{"label": "部署", "description": ""}, {"label": "先不", "description": ""}]}]}
        with open(asks, "w") as handle:
            json.dump({"items": [{"tool": "AskUserQuestion", "input": quiz, "toolUseId": "", "agent": "", "at": started + 2000},
                                 {"tool": "Bash", "input": {"command": "ls"}, "toolUseId": "", "agent": "sub1", "at": started + 3000}]},
                      handle, ensure_ascii=False)
        waiting = {"sessionId": BR_SID, "cwd": CWD, "status": "waiting", "waitingFor": "input needed", "startedAt": started}
        snap_ask = W.snapshot_session(waiting)
        held = W._ASK_ITEMS.get(BR_SID)
        check("记录里没有、mod 写了在等的提问：快照带提问工具和编号、状态写问题本身，补一条提问对话项（子 agent 的不算）",
              snap_ask["pendingTool"] == "AskUserQuestion" and snap_ask["waitingFor"] == "要部署吗" and held and held["t"] == "tool"
              and held["name"] == "AskUserQuestion" and held["input"]["questions"][0]["options"][1]["label"] == "先不"
              and snap_ask["pendingId"] == held["toolId"] and held["id"].endswith(".900"), str(snap_ask.get("pendingTool")))
        W.snapshot_session(waiting)
        check("同一次提问再看一遍：对话项不变（客户端不会出两条）", W._ASK_ITEMS.get(BR_SID) is held)
        with open(asks, "w") as handle:
            json.dump({"items": []}, handle)
        snap_done = W.snapshot_session(dict(waiting, status="busy", waitingFor=None))
        check("答完：补的项去掉", BR_SID not in W._ASK_ITEMS and snap_done["pendingTool"] is None)
        check("mod：在等的确认写进 asks.json；「允许」不拿去答提问框（没带答案，答了等于白答）",
              ".asks.json" in mod_ts and "publish($)" in mod_ts and "w.tool === 'AskUserQuestion'" in mod_ts)
        stop.set()
        mod_thread.join()
        began = time.time()
        resp = ask({"cmd": "bridge", "sessionId": BR_SID, "op": "abort"})
        check("mod 没接（会话卡住）：约 3 秒后回 bridged false，指令已撤下（之后不会再被执行）", resp and resp.get("bridged") is False
              and 2.5 <= time.time() - began < 6 and not os.path.exists(os.path.join(inbox, BR_SID + ".json")), str(resp))
        resp = ask({"cmd": "bridge", "sessionId": SID, "op": "send", "text": "x"})
        check("没加载 mod 的会话：马上回 bridged false", resp and resp.get("bridged") is False, str(resp))
        old = os.path.join(inbox, "old.ack-1.json")
        open(old, "w").close()
        os.utime(old, (time.time() - 7200, time.time() - 7200))
        W.bridge_tidy(inbox)
        check("陈年回执清掉，alive 留着", not os.path.exists(old) and os.path.exists(alive))
        br_proc.kill()
    finally:
        if saved_cfg is None:
            os.environ.pop("CLAUDE_CONFIG_DIR", None)
        else:
            os.environ["CLAUDE_CONFIG_DIR"] = saved_cfg

    print("== 本机性能")
    stats = wait_for(lambda e: e["event"] == "sys", timeout=12)
    check("每隔几秒报一次本机性能（sys）", stats is not None)
    if stats:
        check("内存：总量 > 已用 > 0", 0 < stats.get("memUsed", 0) < stats.get("memTotal", 0), str(stats))
        check("CPU 占用在 0～1 之间", 0 <= stats.get("cpu", -1) <= 1, str(stats))
        check("网速是非负整数", all(isinstance(stats.get(k), int) and stats[k] >= 0 for k in ("netIn", "netOut")), str(stats))
finally:
    proc.terminate()
    fake.kill()
    shutil.rmtree(root, ignore_errors=True)

print("\nwatcher：%d 项通过，%d 项失败" % (PASS[0], len(FAIL)))
sys.exit(1 if FAIL else 0)
