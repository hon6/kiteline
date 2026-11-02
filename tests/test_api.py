"""手机服务接口测试：对一个以 dry-run 方式运行、挂着合成会话的 Kiteline 实例做断言。

由 tests/run-integration.sh 启动实例后调用：
  python3 tests/test_api.py <http 端口> <https 端口> <令牌> <配置目录> <数据目录>
"""
import base64
import hashlib
import json
import os
import re
import socket
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HTTP_PORT, HTTPS_PORT, TOKEN, CONFIG_DIR, DATA_DIR = sys.argv[1:6]
BASE = "http://127.0.0.1:%s" % HTTP_PORT
PASS, FAIL = [0], []


def check(name, cond, detail=""):
    if cond:
        PASS[0] += 1
        print("  [PASS] %s" % name)
    else:
        FAIL.append(name)
        print("  [FAIL] %s %s" % (name, detail))


def request(path, method="GET", body=None, token=TOKEN, base=BASE, context=None, raw=False):
    url = base + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    if token:
        req.add_header("X-CCP-Token", token)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=20, context=context) as res:
            payload = res.read()
            return res.status, (payload if raw else json.loads(payload or b"{}")), res.headers
    except urllib.error.HTTPError as err:
        payload = err.read()
        try:
            return err.code, json.loads(payload), err.headers
        except ValueError:
            return err.code, payload, err.headers


def q(value):
    return urllib.parse.quote(value, safe="")


def log_tail():
    with open(os.path.join(CONFIG_DIR, "ccpulse.log"), encoding="utf-8") as handle:
        return handle.read()


print("== 鉴权与配对")
status, _, _ = request("/api/state", token=None)
check("不带令牌返回 401", status == 401)
status, _, _ = request("/api/state", token="wrong")
check("错误令牌返回 401", status == 401)
status, page, page_headers = request("/", token=None, raw=True)
check("网页版已下线：根路径只有说明页（请用 Kiteline App 连接）", status == 200 and "Kiteline App".encode() in page and b"<script" not in page, page[:200])
csp = page_headers.get("Content-Security-Policy", "")
check("说明页禁止脚本、不许被嵌进 iframe", "default-src 'none'" in csp and "frame-ancestors 'none'" in csp and page_headers.get("X-Frame-Options") == "DENY", csp)
check("说明页不往外带 Referer、不许猜类型", page_headers.get("Referrer-Policy") == "no-referrer" and page_headers.get("X-Content-Type-Options") == "nosniff")
gone = {path: request(path + "?t=%s" % TOKEN, token=None, raw=True)[0]
        for path in ["/app.js", "/app.css", "/sw.js", "/manifest.webmanifest", "/apple-touch-icon.png", "/icon-192.png"]}
check("网页版的文件一律 404（带令牌也一样）", set(gone.values()) == {404}, str(gone))
print("== 防拖垮：慢速请求、陌生人的大请求体")
_host, _port = urllib.parse.urlparse(BASE).hostname, urllib.parse.urlparse(BASE).port
with socket.create_connection((_host, _port), timeout=30) as sock:
    sock.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n")   # 请求头一直不发完
    started = time.time()
    try:
        closed = sock.recv(1024) == b""
    except (ConnectionResetError, socket.timeout):
        closed = True
    waited = time.time() - started
check("请求头 15 秒内不发完就断开", closed and 12 < waited < 25, "%.1f 秒" % waited)
with socket.create_connection((_host, _port), timeout=10) as sock:
    sock.sendall(b"POST /api/send HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 5000000\r\n\r\n")
    reply = sock.recv(1024)
check("没令牌的大请求体不收，直接 401", reply.startswith(b"HTTP/1.1 401"), reply[:60])
with socket.create_connection((_host, _port), timeout=10) as sock:
    sock.sendall(("POST /api/send HTTP/1.1\r\nHost: x\r\nX-CCP-Token: %s\r\nContent-Type: application/json\r\nContent-Length: 2000000\r\n\r\n" % TOKEN).encode())
    sock.sendall(b"{" + b" " * 1999998 + b"}")
    reply = sock.recv(1024)
check("带令牌的大请求体照常收", not reply.startswith(b"HTTP/1.1 401") and not reply.startswith(b"HTTP/1.1 413"), reply[:60])
codes = [request("/pair?code=000000", token=None)[0] for _ in range(9)]
check("配对码错 8 次后锁定（429）", codes[0] == 403 and codes[-1] == 429, str(codes))

print("== 会话列表")
state = {}
for _ in range(20):
    status, state, _ = request("/api/state")
    if len(state.get("sessions", [])) >= 4:
        break
    time.sleep(0.5)
by_title = {s["title"]: s for s in state.get("sessions", [])}
check("四个合成会话都在", all(t in by_title for t in ("选择登录方案", "清理构建目录", "首页卡片间距", "订单导出功能")),
      str(list(by_title)))
ask, perm, busy = by_title.get("选择登录方案", {}), by_title.get("清理构建目录", {}), by_title.get("首页卡片间距", {})
check("等待状态与原因", ask.get("activity") == "waiting" and perm.get("blocking") == "请求权限确认")
check("运行中带当前工具摘要", busy.get("activity") == "busy" and busy.get("activityText", "").startswith("Bash"))

print("== 历史与图片")
status, hist, _ = request("/api/history?key=%s&limit=200" % q(busy["key"]))
kinds = [i["t"] for i in hist.get("items", [])]
check("历史里有用户图、工具、结果、正文、智能体发图",
      all(k in kinds for k in ("user", "tool", "result", "text", "agent_image")), str(kinds))
ref = next(i["images"][0]["ref"] for i in hist["items"] if i["t"] == "user" and i.get("images"))
status, img, headers = request("/api/media?key=%s&ref=%s" % (q(busy["key"]), q(ref)), raw=True)
check("取图返回图片并允许缓存", status == 200 and img[:4] == b"\x89PNG" and "immutable" in headers.get("Cache-Control", ""))
status, img2, _ = request("/api/media?key=%s&ref=%s" % (q(busy["key"]), q(ref)), raw=True)
check("第二次取图走缓存，内容一致", status == 200 and img2 == img)

print("== 发送（dry-run）")
photo = base64.b64encode(b"\xff\xd8\xff\xe0fake-jpeg").decode()
status, body, _ = request("/api/send?key=%s" % q(busy["key"]), "POST",
                          {"text": "按钮太小了", "images": [{"name": "截图.jpg", "data": photo}]})
check("发送成功并提交", status == 200 and body["ok"] and body["submitted"], str(body))
log = log_tail()
check("投递内容带附图路径", "按钮太小了\n\n[附图] %s" % os.path.join(DATA_DIR, "inbox") in log)
inbox = os.path.join(DATA_DIR, "inbox")
files = [os.path.join(d, f) for d, _, fs in os.walk(inbox) for f in fs]
check("图片落到了会话所在机器的 inbox", any(open(f, "rb").read() == base64.b64decode(photo) for f in files))
status, body, _ = request("/api/send?key=%s" % q("nope#nope"), "POST", {"text": "x"})
check("不存在的会话返回 404", status == 404)

print("== 发文件、取回文件（别的 App 里「用其他应用打开」发来的 PDF、Excel；消息里的电脑文件路径点开）")
status, now, _ = request("/api/state")
check("状态里报告支持文件", "files" in (now.get("features") or []), str(now.get("features")))
sheet = "PK\x03\x04报价单".encode()
status, body, _ = request("/api/send?key=%s" % q(busy["key"]), "POST",
                          {"text": "核对金额", "images": [{"name": "图.jpg", "data": photo}],
                           "files": [{"name": "报价单.xlsx", "data": base64.b64encode(sheet).decode()}]})
check("带文件发送成功", status == 200 and body["ok"], str(body))
saved = [os.path.join(d, f) for d, _, fs in os.walk(inbox) for f in fs if f.endswith("报价单.xlsx")]
check("文件原样落到 inbox，保留原名", len(saved) == 1 and open(saved[0], "rb").read() == sheet, str(saved))
sent = log_tail().split("[dry-run] 投递到")[-1]
check("消息里图在前、文件写成附件行", "核对金额\n\n[附图] " in sent and "\n[附件] " in sent, sent[:240])
status, body, _ = request("/api/send?key=%s" % q(busy["key"]), "POST", {"text": "", "files": [{"name": "a.pdf", "data": "JVBERg=="}]})
check("只发文件时的引导语", status == 200 and "请查看我发来的文件：" in log_tail().split("[dry-run] 投递到")[-1])
status, data, headers = request("/api/download?key=%s&path=%s" % (q(busy["key"]), q(saved[0] if saved else "")), raw=True)
check("按路径取回附件，内容一致", status == 200 and data == sheet and "spreadsheetml" in headers.get("Content-Type", ""), str(status))
elsewhere = os.path.join(DATA_DIR, "kl-files")   # 项目目录以外（Claude 常把生成的表格放桌面）
os.makedirs(elsewhere, exist_ok=True)
with open(os.path.join(elsewhere, "桌面 报告.pdf"), "wb") as handle:
    handle.write(b"%PDF-1.4 kl")
status, data, headers = request("/api/download?key=%s&path=%s" % (q(busy["key"]), q(os.path.join(elsewhere, "桌面 报告.pdf"))), raw=True)
check("项目目录以外的绝对路径也能取回（中文、空格）", status == 200 and data == b"%PDF-1.4 kl"
      and headers.get("Content-Type", "").startswith("application/pdf"), str(status))
with open(os.path.join(elsewhere, ".env"), "w") as handle:
    handle.write("TOKEN=1")
status, body, _ = request("/api/download?key=%s&path=%s" % (q(busy["key"]), q(os.path.join(elsewhere, ".env"))))
check("像密钥的文件默认不给", status == 403 and body.get("secret") is True, str(body))
status, data, _ = request("/api/download?key=%s&path=%s&reveal=1" % (q(busy["key"]), q(os.path.join(elsewhere, ".env"))), raw=True)
check("确认后才给", status == 200 and data == b"TOKEN=1", str(status))
status, body, _ = request("/api/download?key=%s&path=%s" % (q(busy["key"]), q(os.path.join(elsewhere, "nope.xlsx"))))
check("不存在的文件说清楚", status == 404 and "文件不存在" in body.get("error", ""), str(body))
status, body, _ = request("/api/download?key=%s&path=x.pdf" % q("nope#nope"))
check("会话不存在时 404", status == 404, str(body))

print("== 确认与提问（dry-run）")
status, body, _ = request("/api/key?key=%s" % q(perm["key"]), "POST", {"key": "1"})
check("按键 1（允许）", status == 200 and body["ok"])
status, body, _ = request("/api/key?key=%s" % q(perm["key"]), "POST", {"key": "rm -rf"})
check("不支持的按键被拒绝", status == 409 and not body["ok"])
status, body, _ = request("/api/answer?key=%s" % q(ask["key"]), "POST", {"answers": [
    {"question": "用哪种登录方式？", "picked": ["微信一键登录"], "other": ""},
    {"question": "还需要哪些功能？", "picked": ["记住登录", "找回密码"], "other": "支持指纹"}]})
check("回答提问", status == 200 and body["ok"], str(body))
log = log_tail()
check("回答先 Esc 关掉提问框", "在 ask-demo 按键 esc" in log)
check("答案按格式提交", "→ 微信一键登录" in log and "→ 记住登录、找回密码、支持指纹" in log)

print("== 按住说话（转写由 CCPULSE_FAKE_TRANSCRIPT 代替系统识别）")
wav = b"RIFF" + b"\x00" * 40 + b"\x01\x00" * 8000
status, body, _ = request("/api/voice?key=%s" % q(busy["key"]), "POST",
                          {"data": base64.b64encode(wav).decode(), "mime": "audio/wav", "duration": 2.5, "mode": "text"})
check("只转文字：返回文字、不投递", status == 200 and body.get("text") and "voiceId" not in body, str(body))
status, body, _ = request("/api/voice?key=%s" % q(busy["key"]), "POST",
                          {"data": base64.b64encode(wav).decode(), "mime": "audio/wav", "duration": 2.5, "mode": "send"})
check("松开发送：转写后提交并记下语音", status == 200 and body["submitted"] and body.get("voiceId"), str(body))
voice_text = body.get("text", "")
check("语音文字被投递给会话", "投递到 busy-demo（submit=true）：%s" % voice_text in log_tail())
status, body, _ = request("/api/voices?key=%s" % q(busy["key"]))
check("语音列表里有这条", status == 200 and any(v["text"] == voice_text for v in body["voices"]))
vid = body["voices"][-1]["id"] if body.get("voices") else ""
status, audio, headers = request("/api/voice-audio?id=%s" % q(vid), raw=True)
check("能取回录音回放", status == 200 and audio == wav and headers.get("Content-Type") == "audio/wav")
status, body, _ = request("/api/voice?key=%s" % q(busy["key"]), "POST",
                          {"data": base64.b64encode(wav).decode(), "mime": "text/html\r\nSet-Cookie: evil=1", "duration": 1, "mode": "send"})
status, audio, headers = request("/api/voice-audio?id=%s" % q(body.get("voiceId", "")), raw=True)
check("录音类型不是音频时当二进制回，不能被当成网页、也拼不出额外响应头", status == 200
      and headers.get("Content-Type") == "application/octet-stream" and headers.get("X-Content-Type-Options") == "nosniff"
      and headers.get("Set-Cookie") is None and "sandbox" in (headers.get("Content-Security-Policy") or ""), str(dict(headers)))
status, body, _ = request("/api/voice?key=%s" % q(busy["key"]), "POST", {"data": "", "mime": "audio/wav"})
check("空录音被拒绝", status == 400)

print("== 改动报告 / 测试报告")
status, body, _ = request("/api/git?key=%s" % q(busy["key"]))
paths = [f["path"] for f in body.get("files", [])]
check("改动报告：分支、改动文件、新文件、提交", status == 200 and body.get("branch") == "main" and "src/styles/home.css" in paths
      and "src/card.js" in body.get("untracked", []) and len(body.get("commits", [])) == 2, str(body)[:300])
home = next((f for f in body.get("files", []) if f["path"] == "src/styles/home.css"), {})
check("改动行数", home.get("add") == 3 and home.get("del") == 2, str(home))
status, body, _ = request("/api/git/diff?key=%s&path=%s" % (q(busy["key"]), q("src/styles/home.css")))
check("文件 diff", status == 200 and "+  --card-gap: 16px;" in body.get("diff", ""))
status, body, _ = request("/api/git/diff?key=%s&path=%s" % (q(busy["key"]), q("src/card.js")))
check("新文件 diff 整个算新增", status == 200 and "+export function card" in body.get("diff", ""))
status, body, _ = request("/api/git/diff?key=%s&path=%s" % (q(busy["key"]), q("../../etc/passwd")))
check("越界路径被拒绝", status == 502)
status, body, _ = request("/api/git/diff?key=%s&commit=%s" % (q(busy["key"]), q("HEAD;rm")))
check("不合法的提交号被拒绝", status == 502)
status, body, _ = request("/api/tests?key=%s" % q(busy["key"]))
runs = body.get("runs", [])
check("测试报告：两次 vitest + 一次运行中", len(runs) == 3 and runs[0].get("running") and runs[1]["ok"] is True
      and runs[1]["passed"] == 12 and runs[2]["ok"] is False and runs[2]["failed"] == 1, str([(r.get("ok"), r.get("passed"), r.get("failed")) for r in runs]))

print("== 今日动态")
status, body, _ = request("/api/digest?since=%d" % int((time.time() - 7200) * 1000))
digest = {s.get("title"): s for s in body.get("sessions", [])}
card = digest.get("首页卡片间距", {})
check("汇总了 4 个会话并给出合计", status == 200 and body["totals"]["sessions"] == 4
      and body["totals"]["prompts"] == 4, str(body.get("totals")))
check("在线会话带 key 和状态", card.get("key") == busy["key"] and card.get("activity") == "busy")
check("会话里的改动文件、测试、截图", card.get("fileCount") == 1 and card["tests"]["runs"] == 3
      and card["tests"]["failed"] == 1 and card["tests"]["passed"] == 1 and card.get("images") == 1, str(card)[:300])
check("最后结论是 Claude 最后一段回复", card.get("conclusions") and card["conclusions"][-1]["text"].startswith("间距已经改好了"))
shot_ref = card["shots"][0]["ref"] if card.get("shots") else ""
status, img, headers = request("/api/digest/media?source=%s&sid=%s&ref=%s" % (q(card.get("sourceId", "")), q(card.get("sessionId", "")), q(shot_ref)), raw=True)
check("按来源 + 会话 id 取截图（会话关了也能看）", status == 200 and img[:4] == b"\x89PNG")
status, _, _ = request("/api/digest/media?source=%s&sid=%s&ref=%s" % (q(card.get("sourceId", "")), q(card.get("sessionId", "")), q("f:/etc/passwd")), raw=True)
check("截图接口只认 outbox 引用", status == 400)
status, body, _ = request("/api/digest?since=%d" % int((time.time() + 60) * 1000))
check("区间里没动静时返回空列表", status == 200 and body["sessions"] == [] and body["totals"]["sessions"] == 0)
status, body, _ = request("/api/digest/push", "POST", {})
check("手动推送日报", status == 200 and body["ok"] and "个会话" in body.get("message", ""), str(body))
status, body, _ = request("/api/info")
check("info 带日报时间", body.get("digestTime") == "21:30")

print("== 快捷短语")
status, body, _ = request("/api/state")
check("状态里带默认快捷短语", status == 200 and body.get("quickReplies", [None])[0] == "继续" and len(body["quickReplies"]) == 6)
status, body, _ = request("/api/quick-replies", "POST", {"items": ["  继续 ", "继续", "", "长" * 300, "看看效果"]})
check("保存时去空、去重、限长", status == 200 and body["items"] == ["继续", "长" * 200, "看看效果"], str(body)[:200])
_, state, _ = request("/api/state")
saved = json.load(open(os.path.join(CONFIG_DIR, "config.json"), encoding="utf-8"))
check("立即同步到状态并写进配置文件", state["quickReplies"] == body["items"] and saved["mobile"]["quickReplies"] == body["items"])
status, body, _ = request("/api/quick-replies", "POST", {"items": []})
check("可以清空（输入框上方就不显示）", status == 200 and body["items"] == [])
status, body, _ = request("/api/quick-replies", "POST", {"items": None})
check("恢复默认", status == 200 and len(body["items"]) == 6)
status, _, _ = request("/api/quick-replies", "POST", {"items": ["x"]}, token="wrong")
check("改短语要鉴权", status == 401)

print("== 我的头像和名字")
status, body, _ = request("/api/state")
me = body.get("me") or {}
check("状态里带「我」：默认名字是 Mac 用户名", status == 200 and me.get("name") and "avatar" in me, str(me))
status, prof, _ = request("/api/profile")
groups = prof.get("groups") or []
check("能列出 Mac 自带头像（按分类）", status == 200 and prof.get("avatar") == "mac" and sum(len(g["items"]) for g in groups) >= 20,
      str([(g["name"], len(g["items"])) for g in groups]))
first = groups[0]["items"][0] if groups else "Animals/Owl"
status, body, _ = request("/api/profile", "POST", {"name": "  小洪\n ", "avatar": "system:" + first})
check("改名字（去掉首尾空白和换行）+ 换系统头像", status == 200 and body["me"]["name"] == "小洪" and body["avatar"] == "system:" + first
      and body["me"]["avatar"].startswith("/api/avatar?v="), str(body.get("me")))
saved = json.load(open(os.path.join(CONFIG_DIR, "config.json"), encoding="utf-8"))
check("写进配置文件", saved["mobile"]["myName"] == "小洪" and saved["mobile"]["avatar"] == "system:" + first)
status, img, headers = request(body["me"]["avatar"], raw=True)
check("头像图片是 JPEG", status == 200 and img[:2] == b"\xff\xd8", str(status))
status, _, _ = request("/api/avatar?preset=" + q("../../../../etc/passwd"), raw=True)
check("系统头像只认列表里有的，不拼路径", status == 404)
status, body, _ = request("/api/profile", "POST", {"avatar": "system:../../etc"})
check("不存在的头像拒绝", status == 400)
status, body, _ = request("/api/profile", "POST", {"image": "data:image/png;base64,AAAA"})
check("坏图片拒绝", status == 400 and "无法打开" in body.get("error", ""))
status, body, _ = request("/api/profile", "POST", {"avatar": "text", "name": ""})
check("名字留空 = 跟着 Mac 用户名；名字首字模式没有图片", status == 200 and body["me"]["name"] == me.get("name") and body["me"]["avatar"] == "")
status, _, _ = request("/api/profile", "POST", {"name": "x"}, token="wrong")
check("改资料要鉴权", status == 401)

print("== Agent 头像昵称、Agent 详情、设备详情")
k = busy["key"]
status, body, _ = request("/api/agent-face", "POST", {"key": k, "agent": "claude-code", "scope": "session", "name": " 小克\n", "avatar": "emoji:🦊:paper"})
check("给会话设头像、昵称（去掉首尾空白）", status == 200 and body["sessions"].get(k) == {"name": "小克", "avatar": "emoji:🦊:paper"}, str(body))
status, state, _ = request("/api/state")
check("状态里带上 faces", ((state.get("faces") or {}).get("sessions") or {}).get(k, {}).get("name") == "小克")
status, _, _ = request("/api/agent-face", "POST", {"key": k, "agent": "claude-code", "scope": "session", "avatar": "image:../../x"})
check("头像写法不对拒绝", status == 400)
status, body, _ = request("/api/agent-face", "POST", {"key": k, "agent": "claude-code", "scope": "session", "image": "data:image/png;base64,AAAA"})
check("坏图片拒绝", status == 400 and "无法打开" in body.get("error", ""))
dot = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
status, body, _ = request("/api/agent-face", "POST", {"key": k, "agent": "claude-code", "scope": "session", "name": "小克", "image": dot})
avatar = ((body.get("sessions") or {}).get(k) or {}).get("avatar", "")
check("上传的图存成 image:<id>", status == 200 and avatar.startswith("image:"), str(body))
status, img, _ = request("/api/agent-avatar?id=" + q(avatar[6:]), raw=True)
check("取得到上传的头像（JPEG）", status == 200 and img[:2] == b"\xff\xd8", str(status))
status, _, _ = request("/api/agent-avatar?id=" + q("../config"), raw=True)
check("头像 id 不拼路径", status == 404)
status, body, _ = request("/api/agent-face", "POST", {"key": k, "agent": "claude-code", "scope": "agent", "name": "", "avatar": "mark:kite:ink"})
check("设为这家 agent 所有会话的默认：会话自己的那份不留", status == 200 and k not in body["sessions"]
      and body["agents"].get("claude-code", {}).get("avatar") == "mark:kite:ink", str(body))
images = os.path.join(CONFIG_DIR, "agent-avatars")
for _ in range(20):
    if not [n for n in os.listdir(images) if n.endswith(".jpg")]:
        break
    time.sleep(0.25)
check("没人用的上传图删掉", not [n for n in os.listdir(images) if n.endswith(".jpg")])
status, body, _ = request("/api/agent-info?key=" + q(k))
check("Agent 详情：会话、插件、所在设备", status == 200 and body.get("agent") == "claude-code" and body.get("live") and body.get("cwd") == busy["cwd"]
      and (body.get("agentFace") or {}).get("avatar") == "mark:kite:ink" and (body.get("machine") or {}).get("id") == busy["sourceId"]
      and (body.get("plugin") or {}).get("id") == "claude-code", str(body)[:400])
status, body, _ = request("/api/machine?source=" + q(busy["sourceId"]))
info = body.get("info") or {}
check("设备详情：那台机器的系统信息（watcher 的 machine_info）", status == 200 and body.get("online") and info.get("cores", 0) > 0
      and bool(info.get("os")) and isinstance(info.get("ips"), list) and info.get("hostname"), str(body)[:400])
status, _, _ = request("/api/machine?source=nope")
check("不认识的设备 404", status == 404)
status, body, _ = request("/api/agent-face", "POST", {"agent": "claude-code", "scope": "agent", "name": "", "avatar": ""})
check("名字、头像都空 = 恢复默认", status == 200 and not body["agents"] and not body["sessions"], str(body))
status, _, _ = request("/api/agent-face", "POST", {"key": k, "name": "x"}, token="wrong")
check("改 agent 头像要鉴权", status == 401)

print("== 新任务（dry-run，不会真的开 VS Code）")
status, body, _ = request("/api/projects")
projects = {p["cwd"]: p for p in body.get("projects", [])}
repo = projects.get(busy["cwd"], {})
check("项目列表：最近用过的目录 + 运行中的会话数", status == 200 and repo.get("live") == 3 and repo.get("exists") is True
      and repo.get("sourceId") == busy["sourceId"], str(repo))
admin = projects.get("/Users/demo/projects/admin", {})
check("已经不存在的目录标出来", admin.get("exists") is False, str(admin))
check("有会话的项目排在前面", body["projects"][0]["live"] > 0)
status, body, _ = request("/api/new-session", "POST", {"sourceId": busy["sourceId"], "cwd": busy["cwd"], "text": "给首页加一个搜索框"})
check("在项目里开新会话（dry-run）", status == 200 and body["ok"] and body["submitted"], str(body))
check("投递记录里是新会话和完整要求", "[dry-run] 新会话" in log_tail() and "给首页加一个搜索框" in log_tail())
photo = base64.b64encode(b"\xff\xd8\xffnew-task").decode()
status, body, _ = request("/api/new-session", "POST", {"sourceId": busy["sourceId"], "cwd": busy["cwd"], "text": "",
                                                       "images": [{"name": "设计稿.jpg", "data": photo}]})
check("只带图片也能开，图片先落到那台机器", status == 200 and body["ok"] and "[附图] " in log_tail().split("[dry-run] 新会话")[-1])
status, body, _ = request("/api/new-session", "POST", {"sourceId": busy["sourceId"], "cwd": busy["cwd"], "text": "",
                                                       "files": [{"name": "需求.docx", "data": base64.b64encode(b"PK-docx").decode()}]})
check("只带文件也能开，文件写成附件行", status == 200 and body["ok"] and "[附件] " in log_tail().split("[dry-run] 新会话")[-1], str(body))
status, body, _ = request("/api/new-session", "POST", {"sourceId": busy["sourceId"], "cwd": "/Users/demo/projects/admin", "text": "x"})
check("目录不存在时拒绝", status == 400 and "不存在该目录" in body.get("error", ""), str(body))
status, body, _ = request("/api/new-session", "POST", {"sourceId": busy["sourceId"], "cwd": "relative/dir", "text": "x"})
check("相对路径被拒绝", status == 400)
status, body, _ = request("/api/new-session", "POST", {"sourceId": busy["sourceId"], "cwd": busy["cwd"], "text": "  "})
check("没写要求时拒绝", status == 400)
status, body, _ = request("/api/new-session", "POST", {"sourceId": "nope", "cwd": busy["cwd"], "text": "x"})
check("来源不存在时 404", status == 404)

print("== 历史会话 / 搜索 / 恢复（dry-run）")
ENDED = "%s#eeeeeeee-1111-2222-3333-444444444444" % busy["sourceId"]
status, body, _ = request("/api/sessions")
listed = {m["key"]: m for m in body.get("sessions", [])}
check("历史列表：运行中的和已结束的都在", status == 200 and listed.get(busy["key"], {}).get("live") is True
      and listed.get(ENDED, {}).get("live") is False and listed[ENDED]["title"] == "登录页按钮改版", str(listed.get(ENDED)))
status, body, _ = request("/api/history?key=%s" % q(ENDED))
check("已结束的会话能看完整对话", status == 200 and [i["t"] for i in body["items"]] == ["user", "text"], str(body)[:200])
status, body, _ = request("/api/session-meta?key=%s" % q(ENDED))
check("已结束的会话概要（标题、目录）", status == 200 and body["session"]["title"] == "登录页按钮改版"
      and body["session"]["cwd"] == busy["cwd"] and body["session"]["live"] is False)
status, body, _ = request("/api/search?q=%s" % q("44PX"))
check("跨会话全文搜索", status == 200 and [r["key"] for r in body["results"]] == [ENDED]
      and "<" not in body["results"][0]["hits"][0]["snippet"][:1], str(body)[:300])
status, body, _ = request("/api/search?q=")
check("空搜索词被拒绝", status == 400)
status, body, _ = request("/api/resume?key=%s" % q(ENDED), "POST", {"text": "再加一个忘记密码入口"})
check("给已结束的会话发消息 = 在 VS Code 里恢复并发出", status == 200 and body["ok"] and body["submitted"], str(body))
check("恢复用的是原来的会话 id", "[dry-run] 恢复会话 eeeeeeee-1111-2222-3333-444444444444" in log_tail())

print("== 会话之间的消息（SendMessage）")
plan = by_title.get("订单导出功能", {})
link = {}
for _ in range(20):   # 来源连上后 watcher 翻对话记录补齐，稍等一下
    status, body, _ = request("/api/peers")
    link = next((l for l in body.get("links", []) if l.get("id") == "5e2d0c1a-7b3f-4a51-9c2e-1f0d6a8b4c77"), {})
    if link.get("from") and link.get("to"):
        break
    time.sleep(0.5)
check("往来列表：两头都换成会话 key（和会话列表一致）", status == 200 and link.get("from") == busy["key"] and link.get("to") == plan.get("key")
      and link.get("summary") == "告知卡片间距的最终取值" and link.get("readAt") and link.get("sentAt"), str(link))
status, body, _ = request("/api/peers?since=%d" % int((time.time() + 3600) * 1000))
check("往来列表按时间筛（since）", status == 200 and body.get("links") == [], str(body)[:200])
status, body, _ = request("/api/history?key=%s" % q(busy["key"]))
sent = next((i for i in body.get("items", []) if i.get("t") == "tool" and i.get("name") == "SendMessage"), {})
check("发出的那步带 peer（对方会话 id、摘要）", (sent.get("peer") or {}).get("session") == plan.get("key", "#").split("#", 1)[1]
      and sent["peer"].get("summary") == "告知卡片间距的最终取值", str(sent)[:300])
status, body, _ = request("/api/history?key=%s" % q(plan.get("key", "")))
got = next((i for i in body.get("items", []) if (i.get("peer") or {}).get("dir") == "in"), {})
check("收到的那条是带 peer 的事件（来自哪个会话、全文）", got.get("t") == "event" and got["peer"].get("session") == busy["key"].split("#", 1)[1]
      and "--card-gap" in got["peer"].get("body", ""), str(got)[:300])

print("== 项目总览")
status, body, _ = request("/api/projects?detail=1")
over = {p["cwd"]: p for p in body.get("projects", [])}
shop = over.get(busy["cwd"], {})
g = shop.get("git") or {}
check("项目总览带 git 概况：分支、未提交改动、新文件、最近提交", status == 200 and g.get("branch") == "main" and g.get("changed", 0) >= 1
      and g.get("untracked", 0) >= 1 and (g.get("last") or {}).get("subject") == "加上版本号", str(shop)[:300])
_, state_now, _ = request("/api/state")
waiting_here = sum(1 for s in state_now["sessions"] if s.get("cwd") == busy["cwd"] and s.get("activity") == "waiting")
check("项目总览带会话总数、今天的会话数、在跑和等你确认的个数", shop.get("sessions", 0) >= 2 and shop.get("today", 0) >= 1
      and shop.get("live") == 3 and shop.get("waiting", 0) == waiting_here and shop.get("sessionId"), str(shop)[:300])
check("不存在的目录不跑 git", over.get("/Users/demo/projects/admin", {}).get("exists") is False
      and "git" not in over.get("/Users/demo/projects/admin", {}), str(over.get("/Users/demo/projects/admin")))
status, body, _ = request("/api/sessions?source=%s&cwd=%s" % (q(busy["sourceId"]), q(busy["cwd"])))
here = body.get("sessions", [])
check("按项目列会话：只有这个目录的，含已结束的", status == 200 and here and {m["cwd"] for m in here} == {busy["cwd"]}
      and any(m["key"] == ENDED for m in here), str([m.get("cwd") for m in here])[:200])
status, body, _ = request("/api/sessions?source=%s&cwd=%s" % (q("没有这台"), q(busy["cwd"])))
check("按项目列会话：别的机器不串", status == 200 and body.get("sessions") == [], str(body)[:200])
status, body, _ = request("/api/git?key=%s" % q(ENDED))
check("已结束的会话也能看改动报告（用对话记录里的目录）", status == 200 and body.get("branch") == "main"
      and any(f["path"] == "src/styles/home.css" for f in body.get("files", [])), str(body)[:200])
status, body, _ = request("/api/git/diff?key=%s&path=%s" % (q(ENDED), q("src/styles/home.css")))
check("已结束的会话看单个文件的差异", status == 200 and "--card-gap: 16px" in (body.get("diff") or ""), str(body)[:200])
status, body, _ = request("/api/git?key=%s" % q(busy["sourceId"] + "#ffffffff-0000-0000-0000-000000000000"))
check("不存在的会话看改动报告给 404", status == 404, status)
status, body, _ = request("/api/usage?days=7")
check("用量按项目带机器 id（项目总览对得上花费）", status == 200 and all(p.get("sourceId") for p in body.get("projects", [])), str(body.get("projects"))[:200])
status, body, _ = request("/api/resume?key=%s" % q(busy["key"]), "POST", {"text": "x"})
check("还在运行的会话不走恢复", status == 409)
status, body, _ = request("/api/history?key=%s" % q(busy["sourceId"] + "#../../etc"))
check("不合法的会话 id 被拒绝", status == 404)

print("== 用量报表")
status, body, _ = request("/api/usage?days=7")
t = body.get("totals", {})
check("7 天每天一行（没用的日子补 0）", status == 200 and len(body.get("days", [])) == 7, str(body)[:200])
check("三天前结束的会话按记录花费 $1，今天运行中的按同模型费率估算", abs(sum(d["cost"] - d["estimated"] for d in body["days"]) - 1.0) < 1e-6
      and t.get("estimated", 0) > 0 and body["days"][-1]["cost"] > 0, str(t))
check("按模型、按项目、按机器汇总", body["models"][0]["model"] == "claude-opus-5-5"
      and any(p["name"] == "shop-app" for p in body["projects"]) and len(body["sources"]) == 1)
status, body, _ = request("/api/usage?days=1")
check("只看今天：不含三天前的花费，今天的按借来的费率估算", status == 200 and len(body["days"]) == 1
      and body["totals"]["cost"] > 0 and abs(body["totals"]["cost"] - body["totals"]["estimated"]) < 1e-6, str(body.get("totals")))

print("== 订阅额度")
status, body, _ = request("/api/limits?fresh=1")
devices = body.get("devices") or []
agent = (devices[0].get("agents") or [{}])[0] if devices else {}
windows = {w.get("kind"): w for w in agent.get("windows") or []}
check("按电脑分组：本机 Claude Code 的 5 小时 / 本周额度（额度插件写下的读数）", status == 200 and len(devices) == 1 and devices[0].get("local")
      and agent.get("agent") == "claude-code" and windows.get("five_hour", {}).get("percent") == 42
      and windows.get("seven_day", {}).get("percent") == 68 and windows["five_hour"].get("resetsAt", 0) > time.time() * 1000, str(body)[:300])

print("== 花费提醒")
status, body, _ = request("/api/budget")
check("默认不提醒", status == 200 and body["daily"] == 0)
status, body, _ = request("/api/budget/check", "POST", {})
check("没设预算时检查直接跳过", status == 200 and "未设置" in body["message"])
status, body, _ = request("/api/budget", "POST", {"daily": 1})
check("设每日预算", status == 200 and body["daily"] == 1)
alert = None
for _ in range(20):   # 设完预算立刻检查一次（异步）
    time.sleep(0.5)
    _, audit, _ = request("/api/audit")
    alert = next((e for e in audit.get("entries", []) if e["action"] == "花费提醒"), None)
    if alert:
        break
check("今天花费超过预算时立刻提醒", alert is not None and "超出预算" in alert.get("detail", ""), str(alert))
status, body, _ = request("/api/budget/check", "POST", {})
check("同一天同一档只提醒一次", status == 200 and "已提醒" in body["message"], str(body))
state = json.load(open(os.path.join(CONFIG_DIR, "state.json"), encoding="utf-8"))
check("提醒状态记在配置目录（不碰正式 App 的 UserDefaults）", state.get("budgetAlertSent", "").endswith("|100"))
status, body, _ = request("/api/budget", "POST", {"daily": -5})
check("负数金额被拒绝", status == 400)
request("/api/budget", "POST", {"daily": 0})

print("== 操作记录")
status, body, _ = request("/api/audit?limit=500")
entries = body.get("entries", [])
actions = {e["action"] for e in entries}
check("每类写操作都有记录", {"发送消息", "按键", "回答提问", "语音", "新任务", "恢复会话", "修改快捷短语", "推送日报", "修改花费提醒 / 上限", "配对"} <= actions, str(sorted(actions)))
sent = next((e for e in entries if e["action"] == "发送消息" and e.get("ok")), {})
check("记下目标会话、内容和来自哪台设备", sent.get("target") and sent.get("detail") and sent.get("client") == "这台 Mac", str(sent))
pressed = next((e for e in entries if e["action"] == "按键" and e.get("ok")), {})
check("按键记成人能看懂的名字", pressed.get("detail") in ("允许", "总是允许", "拒绝 / 中断", "确认"), str(pressed))
failed = [e.get("message", "") for e in entries if e["action"] == "新任务" and not e["ok"]]
check("失败的操作带原因", any("不存在该目录" in m for m in failed), str(failed))
check("未配对的请求也记下来", any(e["action"] == "修改快捷短语" and e.get("message") == "未配对的请求被拒绝" for e in entries))
check("配对失败有记录", any(e["action"] == "配对" and not e["ok"] for e in entries))
check("新的在前", entries[0]["ts"] >= entries[-1]["ts"])

print("== 项目文件（只读）")
status, body, _ = request("/api/files?key=%s" % q(busy["key"]))
names = [e["name"] for e in body.get("entries", [])]
check("以会话工作目录为根列文件", status == 200 and "src" in names and body.get("root") == busy["cwd"], str(body)[:200])
status, body, _ = request("/api/files?key=%s&path=src/styles" % q(busy["key"]))
home = next((e for e in body.get("entries", []) if e["name"] == "home.css"), {})
check("带 git 改动标记", home.get("git") == "M", str(body)[:300])
status, body, _ = request("/api/files?key=%s&path=src" % q(busy["key"]))
check("新文件标为 ?，有改动的目录带点", any(e["name"] == "card.js" and e.get("git") == "?" for e in body["entries"])
      and any(e["name"] == "styles" and e.get("git") == "•" for e in body["entries"]), str(body["entries"]))
status, body, _ = request("/api/file?key=%s&path=src/styles/home.css" % q(busy["key"]))
check("读文件", status == 200 and "--card-gap" in body.get("text", ""))
status, body, _ = request("/api/file?key=%s&path=%s" % (q(busy["key"]), q("../../../etc/passwd")))
check("跑出项目目录被拒绝", status == 400 and "项目目录" in body.get("error", ""), str(body))
status, body, _ = request("/api/files/find?key=%s&q=card" % q(busy["key"]))
check("按文件名找", status == 200 and "src/card.js" in body.get("results", []), str(body))
status, body, _ = request("/api/files?key=%s" % q(ENDED))
check("已结束的会话也能看文件", status == 200 and "src" in [e["name"] for e in body.get("entries", [])])

print("== 已配对的设备")
status, body, _ = request("/api/whoami")
check("扫码链接（主令牌）认作 master", status == 200 and body["auth"] == "master")
status, body, _ = request("/api/devices/register", "POST", {"name": "测试 iPhone"})
dev_token = body.get("token", "")
dev_id = (body.get("device") or {}).get("id")
check("登记设备：发一把 d 开头的专用令牌", status == 200 and dev_token.startswith("d") and len(dev_token) > 40, str(body)[:200])
status, body, _ = request("/api/state", token=dev_token)
check("设备令牌能用", status == 200 and body.get("ok"))
status, body, _ = request("/api/whoami", token=dev_token)
check("whoami 认出是哪台设备", body.get("auth") == "device" and body["device"]["name"] == "测试 iPhone" and body["device"]["current"])
status, body, _ = request("/api/devices/register", "POST", {}, token=dev_token)
check("设备令牌不能再登记别的设备", status == 403)
saved = open(os.path.join(CONFIG_DIR, "devices.json"), encoding="utf-8").read()
check("磁盘上只存哈希，不存令牌", dev_token not in saved and dev_id in saved)
status, body, _ = request("/api/devices/rename", "POST", {"id": dev_id, "name": "我的手机"}, token=dev_token)
check("改名字", status == 200 and body["device"]["name"] == "我的手机")
status, body, _ = request("/api/devices")
listed = {d["id"]: d for d in body.get("devices", [])}
check("设备列表：名字、配对方式、最后使用", dev_id in listed and listed[dev_id]["name"] == "我的手机" and listed[dev_id]["via"] == "扫码"
      and listed[dev_id]["lastSeen"] > 0)
print("== 使用统计：订阅状态（X-Kiteline-Pro）、走远程访问的时间（手机 App 从 127.0.0.1 连进来 = 点对点转进来的）")
_req = urllib.request.Request(BASE + "/api/state", headers={"X-CCP-Token": dev_token, "X-Kiteline-Pro": "1",
                                                            "X-Kiteline-Client": "ios/1.5 (iPhone16,1; iOS 26.6.2)"})
urllib.request.urlopen(_req, timeout=20).read()
mine = {}
for _ in range(20):   # 设备记录 5 秒后才写盘
    mine = next((d for d in json.load(open(os.path.join(CONFIG_DIR, "devices.json"), encoding="utf-8")) if d["id"] == dev_id), {})
    if mine.get("remoteAt"):
        break
    time.sleep(0.5)
check("记下订阅状态和走远程的时间", mine.get("pro") is True and mine.get("remoteAt", 0) > 0, str(mine)[:300])
print("== 令牌不放 Cookie（浏览器的 Cookie 不分端口，本机别的服务也会收到）")
_req = urllib.request.Request(BASE + "/api/state")
_req.add_header("Cookie", "ccp=%s" % dev_token)
try:
    with urllib.request.urlopen(_req, timeout=10) as _res:
        _status, _headers = _res.status, _res.headers
except urllib.error.HTTPError as _err:
    _status, _headers = _err.code, _err.headers
check("只带 Cookie 的请求不认", _status == 401)
check("看到旧 Cookie 就让浏览器删掉", "Max-Age=0" in (_headers.get("Set-Cookie") or ""), str(_headers.get("Set-Cookie")))
print("== 二维码里的一次性配对令牌")
status, body, _ = request("/api/devices/link", "POST", {})
link_token = body.get("token", "")
check("主令牌能要一次性配对令牌（p 开头）", status == 200 and link_token.startswith("p") and len(link_token) > 40, str(body)[:200])
status, _, _ = request("/api/devices/link", "POST", {}, token=dev_token)
check("设备令牌不能生成配对令牌", status == 403)
status, _, _ = request("/api/ping", token=link_token)
check("配对令牌能探路（/api/ping）", status == 200)
status, body, _ = request("/api/info", token=link_token)
check("配对令牌能看是哪台 Mac（/api/info）", status == 200)
status, _, _ = request("/api/state", token=link_token)
check("配对令牌不能看会话", status == 401)
status, _, _ = request("/api/files?key=x&path=", token=link_token)
check("配对令牌不能读文件", status == 401)
status, body, _ = request("/api/devices/register", "POST", {"name": "扫码的手机"}, token=link_token)
link_dev_token = body.get("token", "")
link_dev_id = (body.get("device") or {}).get("id")
check("配对令牌换到设备令牌", status == 200 and link_dev_token.startswith("d"), str(body)[:200])
status, _, _ = request("/api/devices/register", "POST", {"name": "又一台"}, token=link_token)
check("配对令牌只能用一次", status == 401)
status, _, _ = request("/api/ping", token=link_token)
check("用过的配对令牌什么都做不了", status == 401)
status, _, _ = request("/api/state", token="p" + "0" * 48)
check("编造的配对令牌不认", status == 401)
if link_dev_id:
    request("/api/devices/revoke", "POST", {"id": link_dev_id})
_, audit, _ = request("/api/audit")
check("操作记录里用设备名标出是谁", any(e["action"] == "修改设备名称" and e["client"].startswith("我的手机") for e in audit["entries"]))
status, body, _ = request("/api/devices/revoke", "POST", {"id": dev_id})
check("停用设备", status == 200 and body["name"] == "我的手机")
status, body, _ = request("/api/state", token=dev_token)
check("停用后它的令牌立即失效", status == 401)
status, body, _ = request("/api/devices/revoke", "POST", {"id": "nope"})
check("停用不存在的设备返回 404", status == 404)

print("== 会话快捷操作")
status, body, _ = request("/api/send?key=%s" % q(busy["key"]), "POST", {"text": "/compact"})
check("压缩上下文：把 /compact 当消息提交", status == 200 and body["submitted"] and "（submit=true）：/compact" in log_tail(), str(body))

print("== 定时任务（dry-run，时间用模拟的）")
import datetime
def ms(dt):
    return int(dt.timestamp() * 1000)
def schedules():
    return {t["id"]: t for t in request("/api/schedules")[1].get("schedules", [])}
def wait_until(pred, timeout=8):
    end = time.time() + timeout
    while time.time() < end:
        found = pred(schedules())
        if found:
            return found
        time.sleep(0.3)
    return None
base = {"sourceId": busy["sourceId"], "cwd": busy["cwd"]}
status, body, _ = request("/api/schedules", "POST", dict(base, prompt="每天早上跑一遍测试，把结果截图发我", repeat="daily", time="09:00"))
daily = body.get("schedule", {})
check("新建每日任务：标签和下次运行时间", status == 200 and daily.get("label") == "每天 09:00" and daily.get("nextRun", 0) > time.time() * 1000, str(body))
tomorrow = datetime.date.today() + datetime.timedelta(days=1)
status, body, _ = request("/api/schedules", "POST", dict(base, prompt="明早总结昨天的改动", repeat="once", time="08:30", date=tomorrow.isoformat()))
once = body.get("schedule", {})
check("新建一次性任务", status == 200 and once.get("label", "").endswith("08:30 一次") and once.get("nextRun") == ms(datetime.datetime.combine(tomorrow, datetime.time(8, 30))))
bad = [request("/api/schedules", "POST", dict(base, prompt="x", repeat="daily", time="25:00"))[0],
       request("/api/schedules", "POST", dict(base, prompt="x", repeat="hourly", time="09:00"))[0],
       request("/api/schedules", "POST", dict(base, prompt="x", repeat="once", time="09:00", date=(datetime.date.today() - datetime.timedelta(days=1)).isoformat()))[0],
       request("/api/schedules", "POST", dict(base, prompt="  ", repeat="daily", time="09:00"))[0]]
check("时间、重复方式、过去的日期、空要求都会被拒绝", bad == [400, 400, 400, 400], str(bad))
status, _, _ = request("/api/schedules", "POST", {"sourceId": "nope", "cwd": busy["cwd"], "prompt": "x", "repeat": "daily", "time": "09:00"})
check("来源不存在返回 404", status == 404)
request("/api/schedules/tick", "POST", {"now": ms(datetime.datetime.combine(tomorrow, datetime.time(8, 30, 10)))})
ran = wait_until(lambda all: all.get(once["id"]) if all.get(once["id"], {}).get("lastOk") else None)
check("到点自动开会话；一次性任务跑完自动停用", ran is not None and ran["enabled"] is False and "nextRun" not in ran
      and "[dry-run] 新会话" in log_tail() and "明早总结昨天的改动" in log_tail(), str(ran))
day2 = datetime.date.today() + datetime.timedelta(days=2)
request("/api/schedules/tick", "POST", {"now": ms(datetime.datetime.combine(day2, datetime.time(12, 0)))})
missed = wait_until(lambda all: all.get(daily["id"]) if all.get(daily["id"], {}).get("lastOk") is False else None)
check("晚了 3 小时（Mac 睡着）记为错过，不补跑", missed is not None and "错过" in missed.get("lastResult", ""), str(missed))
day3 = datetime.date.today() + datetime.timedelta(days=3)
request("/api/schedules/tick", "POST", {"now": ms(datetime.datetime.combine(day3, datetime.time(9, 0, 30)))})
again = wait_until(lambda all: all.get(daily["id"]) if all.get(daily["id"], {}).get("lastOk") is True else None)
check("第二天准点照常运行", again is not None and again["lastRun"] == ms(datetime.datetime.combine(day3, datetime.time(9, 0))))
status, body, _ = request("/api/schedules/run", "POST", {"id": daily["id"]})
check("现在运行一次", status == 200 and body["ok"])
status, body, _ = request("/api/schedules/update", "POST", {"id": daily["id"], "enabled": False})
check("暂停后没有下次运行时间", status == 200 and body["schedule"]["enabled"] is False and "nextRun" not in body["schedule"])
status, body, _ = request("/api/schedules/delete", "POST", {"id": daily["id"]})
check("删除", status == 200 and daily["id"] not in schedules())
_, audit, _ = request("/api/audit")
acts = {e["action"] for e in audit["entries"]}
check("定时任务的新建 / 运行都进操作记录", {"新建定时任务", "定时任务", "删除定时任务"} <= acts, str(acts))
request("/api/schedules/delete", "POST", {"id": once["id"]})

print("== Bark 备用推送（本地假 Bark 服务器）")
import http.server, threading, subprocess
received = []
class FakeBark(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        received.append((self.path, self.headers.get("Content-Type", ""), self.rfile.read(length)))
        reply = b'{"code":200,"message":"success"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)
    def log_message(self, *args):
        pass
fake_bark = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeBark)
threading.Thread(target=fake_bark.serve_forever, daemon=True).start()
bark_url = "http://127.0.0.1:%d/TESTKEY123" % fake_bark.server_address[1]
def wait_received(count, timeout=6):
    end = time.time() + timeout
    while time.time() < end and len(received) < count:
        time.sleep(0.2)
    return len(received) >= count
status, _, _ = request("/api/bark", "POST", {"url": "这不是地址"})
check("地址不对被拒绝", status == 400)
status, body, _ = request("/api/bark", "POST", {"url": bark_url, "mode": "attention"})
check("保存 Bark 地址", status == 200 and body["mode"] == "attention")
status, body, _ = request("/api/bark/test", "POST", {})
path, ctype, raw = received[-1] if wait_received(1) else ("", "", b"{}")
sent = json.loads(raw or b"{}")
check("测试推送：POST /push，带 device_key、标题，需要确认的级别是时效性", status == 200 and path == "/push"
      and sent.get("device_key") == "TESTKEY123" and sent.get("title") == "Kiteline 测试" and sent.get("level") == "timeSensitive", str(sent))
before = len(received)
request("/api/digest/push", "POST", {})
time.sleep(1.5)
check("只推需要确认的：日报不走 Bark", len(received) == before)
request("/api/bark", "POST", {"mode": "all"})
request("/api/digest/push", "POST", {})
got = wait_received(before + 1)
check("全部：日报也走 Bark（普通级别）", got and "日报" in json.loads(received[-1][2]).get("title", "") and json.loads(received[-1][2]).get("level") == "active")
status, _, _ = request("/api/bark", "POST", {"key": "short", "iv": "x"})
check("加密密钥长度不对被拒绝", status == 400)
status, body, _ = request("/api/bark", "POST", {"key": "1234567890abcdef", "iv": "fedcba0987654321"})
check("开启加密", status == 200 and body["encrypted"] is True)
count = len(received)
request("/api/bark/test", "POST", {})
wait_received(count + 1)
path, ctype, raw = received[-1]
form = dict(urllib.parse.parse_qsl(raw.decode()))
plain = subprocess.run(["openssl", "enc", "-d", "-aes-128-cbc", "-K", b"1234567890abcdef".hex(), "-iv", b"fedcba0987654321".hex()],
                       input=base64.b64decode(form.get("ciphertext", "")), stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
check("加密推送：表单 POST 到 /<key>，密文用同一密钥能解开", path == "/TESTKEY123" and "form-urlencoded" in ctype
      and form.get("iv") == "fedcba0987654321" and "Kiteline 测试" in plain.decode("utf-8", "replace") and "Kiteline 测试" not in raw.decode(), plain[:80])
status, body, _ = request("/api/bark")
check("读设置时不回传密钥本身", body.get("encrypted") is True and "key" not in body and "iv" not in body)
request("/api/bark", "POST", {"url": "", "key": "", "iv": ""})
status, body, _ = request("/api/bark")
check("清空地址即关闭", body.get("valid") is False)
fake_bark.shutdown()

print("== 花费硬上限")
status, body, _ = request("/api/budget", "POST", {"cap": 1})
check("设每日上限（不影响提醒设置）", status == 200 and body["cap"] == 1 and body["daily"] == 0)
status, body, _ = request("/api/budget")
check("读上限时告诉你今天已经超了", body.get("cap") == 1 and "超出每日上限" in body.get("capped", ""), str(body))
status, body, _ = request("/api/send?key=%s" % q(busy["key"]), "POST", {"text": "超上限了还发"})
check("超上限：手机发消息先拦住，带 capExceeded", status == 409 and body.get("capExceeded") is True and "超出每日上限" in body.get("error", ""), str(body))
status, body, _ = request("/api/send?key=%s" % q(busy["key"]), "POST", {"text": "超上限了还发", "override": True})
check("确认后（override）照常发出", status == 200 and body["submitted"])
status, body, _ = request("/api/new-session", "POST", {"sourceId": busy["sourceId"], "cwd": busy["cwd"], "text": "新任务"})
check("超上限：新任务也拦", status == 409 and body.get("capExceeded") is True)
status, body, _ = request("/api/resume?key=%s" % q(ENDED), "POST", {"text": "接着做"})
check("超上限：恢复会话也拦", status == 409 and body.get("capExceeded") is True)
status, body, _ = request("/api/key?key=%s" % q(perm["key"]), "POST", {"key": "1"})
check("点允许 / 拒绝不受上限影响", status == 200 and body["ok"])
status, body, _ = request("/api/schedules", "POST", {"sourceId": busy["sourceId"], "cwd": busy["cwd"], "prompt": "定时跑测试", "repeat": "daily", "time": "09:00"})
sid_cap = body["schedule"]["id"]
status, body, _ = request("/api/schedules/run", "POST", {"id": sid_cap})
skipped = {t["id"]: t for t in request("/api/schedules")[1]["schedules"]}.get(sid_cap, {})
check("超上限：定时任务跳过并记下原因", status == 409 and skipped.get("lastOk") is False and "跳过" in skipped.get("lastResult", ""), str(skipped))
request("/api/schedules/delete", "POST", {"id": sid_cap})
_, audit, _ = request("/api/audit")
check("被拦下的操作在操作记录里标出来", any(e["action"] == "发送消息" and e.get("detail") == "超出每日花费上限，已拦截" for e in audit["entries"]))
request("/api/budget", "POST", {"cap": 0})
status, body, _ = request("/api/send?key=%s" % q(busy["key"]), "POST", {"text": "取消上限后"})
check("取消上限后恢复正常", status == 200 and body["submitted"])

print("== 新任务：独立 worktree")
status, body, _ = request("/api/repo-info?sourceId=%s&cwd=%s" % (q(busy["sourceId"]), q(busy["cwd"])))
check("识别出 git 仓库", status == 200 and body.get("repo") is True and body.get("worktrees") == [], str(body))
status, body, _ = request("/api/new-session", "POST", {"sourceId": busy["sourceId"], "cwd": busy["cwd"], "text": "在独立分支里重构首页", "worktree": True})
wt = body.get("cwd", "")
check("在独立分支里开新任务：会话目录换到 worktree", status == 200 and body.get("branch", "").startswith("tars/")
      and "shop-app-worktrees" in wt and os.path.isdir(wt), str(body))
check("交代给 Claude：独立分支、先别合并", "独立的 git worktree" in log_tail() and wt in log_tail())
status, body, _ = request("/api/repo-info?sourceId=%s&cwd=%s" % (q(busy["sourceId"]), q(busy["cwd"])))
check("仓库里能看到这个 Kiteline 分支", len(body.get("worktrees", [])) == 1)
status, body, _ = request("/api/new-session", "POST", {"sourceId": busy["sourceId"], "cwd": CONFIG_DIR, "text": "x", "worktree": True})
check("不是 git 仓库时拒绝并说明", status == 409 and "不是 git 仓库" in body.get("error", ""), str(body))

print("== 对话内搜索 / 更新记录")
status, body, _ = request("/api/search?key=%s&q=%s" % (q(busy["key"]), q("vitest")))
hits = (body.get("results") or [{}])[0].get("hits", [])
check("对话内搜索只在这个会话里找", status == 200 and len(body.get("results", [])) <= 1, str(body)[:200])
status, body, _ = request("/api/search?key=%s&q=%s" % (q(busy["key"]), q("间距")))
hits = (body.get("results") or [{}])[0].get("hits", [])
check("命中你说的话和 Claude 的回复", status == 200 and {h["t"] for h in hits} == {"user", "text"}, str(hits)[:200])
status, body, _ = request("/api/changelog")
check("更新记录随 App 打包，最新一版就是当前版本", status == 200 and body.get("version")
      and re.search(r"^## (\S+?)（", body.get("text", ""), re.M).group(1) == body["version"], body.get("version"))

print("== 断网重发去重")
status, first, _ = request("/api/send?key=%s" % q(busy["key"]), "POST", {"text": "去重测试", "cid": "abc123"})
count_before = log_tail().count("（submit=true）：去重测试")
status2, second, _ = request("/api/send?key=%s" % q(busy["key"]), "POST", {"text": "去重测试", "cid": "abc123"})
check("同一个消息 id 重发只投递一次", status == 200 and status2 == 200 and second.get("duplicate") is True
      and log_tail().count("（submit=true）：去重测试") == count_before == 1, str(second))
status3, third, _ = request("/api/send?key=%s" % q(busy["key"]), "POST", {"text": "去重测试", "cid": "other1"})
check("不同 id 照常投递", status3 == 200 and not third.get("duplicate") and log_tail().count("（submit=true）：去重测试") == 2)

print("== 体检修复")
status, body, _ = request("/api/audit?limit=-1")
status2, _, _ = request("/api/state")
check("操作记录 limit 为负数不会把 App 弄崩", status == 200 and status2 == 200)
status, img, headers = request("/api/media?key=%s&ref=%s" % (q(busy["key"]), q(ref)), raw=True)
check("图片响应带 nosniff 和 CSP sandbox（SVG 新标签页打开也跑不了脚本）", headers.get("X-Content-Type-Options") == "nosniff"
      and "sandbox" in headers.get("Content-Security-Policy", ""), str(dict(headers))[:200])

print("== 等确认提醒 / 早安简报（模拟时间）")
_, info, _ = request("/api/info")
check("默认开着：早安简报 08:30、等确认提醒", info.get("morningTime") == "08:30" and info.get("remindWaiting") is True)
def nudges():
    return [e for e in request("/api/audit?limit=500")[1]["entries"] if e["action"] == "确认提醒"]
t0 = time.time() * 1000
request("/api/reminders/tick", "POST", {"now": t0})
base_count = len(nudges())
request("/api/reminders/tick", "POST", {"now": t0 + 11 * 60000})
time.sleep(0.5)
first = nudges()
waiting_titles = {s["title"] for s in request("/api/state")[1]["sessions"] if s["activity"] == "waiting"}
check("等确认超过 10 分钟：每个在等的会话各催一次", len(first) - base_count == len(waiting_titles) == 3
      and all("分钟" in e["detail"] for e in first[:3]), str([e["detail"] for e in first[:4]]))
request("/api/reminders/tick", "POST", {"now": t0 + 12 * 60000})
time.sleep(0.3)
check("同一档不重复催", len(nudges()) == len(first))
request("/api/reminders/tick", "POST", {"now": t0 + 31 * 60000})
time.sleep(0.3)
second = nudges()
request("/api/reminders/tick", "POST", {"now": t0 + 90 * 60000})
time.sleep(0.3)
check("30 分钟再催一次，之后不再催", len(second) - len(first) == 3 and len(nudges()) == len(second))
status, body, _ = request("/api/morning/push", "POST", {})
check("早安简报：先说有几个会话在等你，再说昨晚的动态", status == 200 and "待确认：3 个会话" in body.get("message", "")
      and "昨晚" in body.get("message", ""), str(body))
check("早安简报：哪些项目有没提交的改动", "项目：1 个有未提交的改动（shop-app）" in body.get("message", ""), str(body))

print("== 免打扰 / 会话静音（本地假 Bark 看有没有推出去）")
pushed = []
class Sink(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        pushed.append(json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}"))
        self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"{}")
    def log_message(self, *args):
        pass
sink = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Sink)
threading.Thread(target=sink.serve_forever, daemon=True).start()
request("/api/bark", "POST", {"url": "http://127.0.0.1:%d/SINKKEY01" % sink.server_address[1], "mode": "all", "key": "", "iv": ""})
def push(kind, title):
    before = len(pushed)
    request("/api/notify/test", "POST", {"kind": kind, "title": title, "key": busy["key"]})
    time.sleep(1.2)
    return len(pushed) > before
now = time.localtime()
around = lambda delta: time.strftime("%H:%M", time.localtime(time.time() + delta * 60))
request("/api/quiet", "POST", {"start": around(-60), "end": around(60)})
_, info, _ = request("/api/info")
check("免打扰时段现在生效", info.get("quietActive") is True, str(info.get("quietStart")))
check("免打扰时：结论不推", not push("conclusion", "夜里的结论"))
check("免打扰时：需要确认的照推", push("attention", "夜里要确认"))
request("/api/quiet", "POST", {"start": around(120), "end": around(180)})
check("不在免打扰时段：结论照推", push("conclusion", "白天的结论"))
status, body, _ = request("/api/mute", "POST", {"key": busy["key"], "muted": True})
_, st, _ = request("/api/state")
check("静音会话：状态里标出来", status == 200 and busy["key"] in st.get("muted", []))
check("静音会话：结论不推", not push("conclusion", "静音会话的结论"))
check("静音会话：需要确认的照推", push("attention", "静音会话要确认"))
request("/api/mute", "POST", {"key": busy["key"], "muted": False})
check("取消静音后结论照推", push("conclusion", "取消静音后"))
status, _, _ = request("/api/quiet", "POST", {"start": "25:00", "end": "08:00"})
check("免打扰时间格式不对被拒绝", status == 400)
print("== 通知收件箱")
status, body, _ = request("/api/inbox?limit=300")
inbox = {e["title"]: e for e in body.get("entries", [])}
check("每条提醒都进收件箱（最新的在前），带类型和会话", status == 200 and body["entries"][0]["title"] == "取消静音后"
      and inbox.get("夜里要确认", {}).get("kind") == "attention" and inbox["夜里要确认"].get("key") == busy["key"], str(body.get("entries", [])[:2])[:300])
check("免打扰时没推的记为 quiet，静音会话的记为 muted，推了的记为 sent",
      inbox.get("夜里的结论", {}).get("delivery") == "quiet" and inbox.get("静音会话的结论", {}).get("delivery") == "muted"
      and inbox.get("白天的结论", {}).get("delivery") == "sent" and inbox.get("夜里要确认", {}).get("delivery") == "sent",
      str({k: v.get("delivery") for k, v in inbox.items()})[:300])
newest = body["entries"][0]["ts"]
status, body, _ = request("/api/inbox?since=%d" % newest)
check("since 之后没有新的 = 没有未读", status == 200 and body["entries"] == [], str(body)[:200])
request("/api/bark", "POST", {"url": ""})
push("conclusion", "没开推送时的结论")
status, body, _ = request("/api/inbox?since=%d" % newest)
check("没有设备开推送时记为 none（只在打开的页面里弹）", [e["delivery"] for e in body.get("entries", [])] == ["none"], str(body)[:200])
status, body, _ = request("/api/inbox?limit=-5")
check("limit 异常值被限住", status == 200 and len(body.get("entries", [])) == 1)
request("/api/quiet", "POST", {"start": "23:00", "end": "08:00"})
request("/api/bark", "POST", {"url": ""})
sink.shutdown()

print("== Claude 出错停下了")
import glob
_, st, _ = request("/api/state")
limit = next((x for x in st["sessions"] if x["title"] == "周报生成"), {})
check("用量到上限停下的会话：列表里带出错说明和本地恢复时间", limit.get("errorKind") == "limit"
      and "用量已达上限" in limit.get("error", "") and "恢复" in limit.get("error", ""), str(limit)[:300])
status, body, _ = request("/api/history?key=%s" % q(limit.get("key", "")))
evs = [i for i in body.get("items", []) if i.get("t") == "event" and i.get("level") == "error"]
check("对话里是一条红色提示（带恢复时间），不是 Claude 的回复", status == 200 and evs and evs[-1].get("resetAt")
      and not any(i.get("t") == "text" and "session limit" in (i.get("text") or "") for i in body.get("items", [])), str(body.get("items"))[:300])
lim_path = next(p for p in glob.glob(os.path.join(os.path.dirname(DATA_DIR), "projects", "*", "*.jsonl")) if "周报生成" in open(p, encoding="utf-8").read())
request("/api/quiet", "POST", {"start": around(120), "end": around(180)})
with open(lim_path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps({"type": "assistant", "uuid": "err-529", "isApiErrorMessage": True, "cwd": "/Users/demo/projects/weekly",
                             "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()), "message": {"role": "assistant",
                             "model": "<synthetic>", "content": [{"type": "text", "text": "API Error: 529 overloaded_error"}]}}, ensure_ascii=False) + "\n")
got = None
for _ in range(20):
    time.sleep(0.5)
    got = next((e for e in request("/api/inbox?limit=20")[1].get("entries", []) if e["title"] == "周报生成"), None)
    if got:
        break
check("又出错时推「出错停下了」（不是「有结论了」），写明怎么办", got and got["kind"] == "error" and "过载" in got["body"]
      and "继续" in got["body"], str(got))
check("Mac 日志里是出错提醒", "周报生成" in log_tail())
request("/api/quiet", "POST", {"start": "23:00", "end": "08:00"})

print("== 别的会话来信引起的那一轮：答完不提醒")


def lim_append(*rows):
    with open(lim_path, "a", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(dict(row, cwd="/Users/demo/projects/weekly", timestamp=time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())),
                                    ensure_ascii=False) + "\n")


def lim_inbox(text, wait):
    end = time.time() + wait
    while time.time() < end:
        time.sleep(0.5)
        got = next((e for e in request("/api/inbox?limit=30")[1].get("entries", []) if text in (e.get("body") or "")), None)
        if got:
            return got
    return None


time.sleep(21)   # 上面刚推过「出错停下」：等过同一会话的结论冷却，免得下面「不提醒」是被冷却挡掉的
lim_append({"type": "user", "isMeta": True, "origin": {"kind": "peer", "from": "uds:/tmp/x.sock", "name": "发版会话", "msg_id": "it-peer-1",
                                                       "body": "快照拍好了"},
            "message": {"role": "user", "content": "<cross-session-message from=\"uds:/tmp/x.sock\">快照拍好了</cross-session-message>"}},
           {"type": "assistant", "uuid": "it-peer-reply", "message": {"role": "assistant", "content": [{"type": "text", "text": "已回复发版会话：周报这边不用改"}]}})
check("来信那一轮答完：不进提醒、不推送", lim_inbox("已回复发版会话", 5) is None)
lim_append({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "周报再加一页图表"}]}},
           {"type": "assistant", "uuid": "it-user-reply", "message": {"role": "assistant", "content": [{"type": "text", "text": "图表页加好了"}]}})
got = lim_inbox("图表页加好了", 10)
check("你发起的下一轮答完：照常提醒", got and got["kind"] == "conclusion", str(got))

print("== 可能卡住了（模拟时间推进）")
_, st, _ = request("/api/state")
busy_now = next(x for x in st["sessions"] if x["key"] == busy["key"])
request("/api/quiet", "POST", {"start": around(120), "end": around(180)})
last = busy_now["updatedAt"]
def stuck_entries():
    return [e for e in request("/api/inbox?limit=50")[1].get("entries", []) if e["kind"] == "stuck"]
base = len(stuck_entries())
request("/api/stuck/tick", "POST", {"now": last + 10 * 60000})
time.sleep(0.3)
check("工作中 10 分钟没动静：不提醒", len(stuck_entries()) == base)
request("/api/stuck/tick", "POST", {"now": last + 25 * 60000})
time.sleep(0.3)
got = stuck_entries()
check("工作中 25 分钟没动静：提醒「可能卡住了」，写明在干什么、能中断", len(got) == base + 1 and got[0]["key"] == busy["key"]
      and "25 分钟" in got[0]["body"] and "npm test" in got[0]["body"] and "中断" in got[0]["body"], str(got[:1]))
request("/api/stuck/tick", "POST", {"now": last + 40 * 60000})
time.sleep(0.3)
check("同一次卡住只提醒一次", len(stuck_entries()) == base + 1)
status, body, _ = request("/api/morning/push", "POST", {})
check("早安简报列出可能卡住的会话（按真实时间，此刻没卡住就不列）", status == 200 and "可能停滞" not in body.get("message", ""), body.get("message"))
status, body, _ = request("/api/key?key=%s" % q(busy["key"]), "POST", {"key": "esc"})
check("中断（Esc）走按键投递", status == 200 and "[dry-run] 在 busy-demo 按键 esc" in log_tail(), str(body))
check("Claude Code 会话能关闭（caps 带 close）", "close" in busy.get("caps", []), busy.get("caps"))
status, body, _ = request("/api/close?key=%s" % q(busy["key"]), "POST", {})
check("关闭会话走投递（VS Code 关标签 / 终端 /exit）", status == 200 and body["ok"] and "[dry-run] 关闭会话 busy-demo" in log_tail(), str(body))
status, body, _ = request("/api/close?key=nope", "POST", {})
check("关闭不存在的会话", status == 404)

print("== 闲置会话自动关闭（模拟时间推进）")
check("设置里默认开着「自动关闭 24 小时未查看的会话」", request("/api/info")[1].get("autoCloseIdle") is True)
_, st, _ = request("/api/state")
idle_ones = [x for x in st["sessions"] if "close" in x.get("caps", []) and x.get("canReply") and x["activity"] != "busy"]
check("有几个能关闭、没在跑的会话可测", len(idle_ones) >= 4, str([x["title"] for x in idle_ones]))
# 补历史用的那个要挑主机只记了「第一次见到」的（前面的测试发过消息、取过语音的都算打开过）
opened = set(request("/api/idleclose/tick", "POST", {"now": time.time() * 1000})[1].get("opened", []))
fresh = [x for x in idle_ones if x["key"] not in opened]
check("有只记了第一次见到、没打开过的会话可测", fresh, str(sorted(opened))[:200])
old_one = (fresh + [{}])[0]
viewed_one, voiced_one, stale = ([x for x in idle_ones if x is not old_one] + [{}, {}, {}])[:3]
request("/api/mark", "POST", {"key": stale.get("key", ""), "marked": True})
request("/api/pin", "POST", {"key": stale.get("key", ""), "pinned": True})
t0 = time.time() * 1000
time.sleep(2.2)
request("/api/viewed", "POST", {"keys": [viewed_one.get("key", "")]})   # 对话页打开（新版各端）
request("/api/voices?key=%s" % q(voiced_one.get("key", "")))            # 对话页打开（旧版手机只取语音）
# 各端启动时带上的本机历史（最后看过）：old_one 30 小时前看过 → 按历史算；viewed_one 刚打开过，报个更早的不往回挪；不认识的不收
long_ago = t0 - 30 * 3600_000
request("/api/viewed", "POST", {"keys": [], "seen": {old_one.get("key", ""): long_ago, viewed_one.get("key", ""): long_ago,
                                                     "ssh:nowhere#x": long_ago, voiced_one.get("key", ""): "坏数据"}})
def auto_closed(after):
    tail = log_tail()[after:]
    return {x["title"] for x in st["sessions"] if "自动关闭会话「%s」" % x["title"] in tail}
mark = len(log_tail())
opened = set(request("/api/idleclose/tick", "POST", {"now": t0 + 23 * 3600_000})[1].get("opened", []))
time.sleep(1.5)
closed = auto_closed(mark)
check("23 小时没打开：不关", not closed & {stale.get("title"), viewed_one.get("title"), voiced_one.get("title")}, str(closed))
check("升级前的历史也算（各端报来的最后看过）：30 小时前看过的 23 小时后就过了 24 小时、关掉", old_one.get("title") in closed, str(closed))
check("报来的历史只收认识的会话", "ssh:nowhere#x" not in opened, str(sorted(opened))[:200])
mark = len(log_tail())
request("/api/idleclose/tick", "POST", {"now": t0 + 24 * 3600_000 + 1000})
time.sleep(1.5)
closed = auto_closed(mark)
check("24 小时没打开的关掉（标记、置顶的也关），走的是关闭会话的投递", stale.get("title") in closed
      and "[dry-run] 关闭会话 %s" % stale.get("name") in log_tail()[mark:], str(closed))
check("24 小时内打开过的不关（POST /api/viewed、旧版手机取语音都算）", viewed_one.get("title") not in closed and voiced_one.get("title") not in closed, str(closed))
check("正在跑的不关", busy.get("title") not in closed, str(closed))
_, st2, _ = request("/api/state")
check("关掉了就取消标记（同手动关闭），置顶留着（恢复后还在顶上）", stale.get("key") not in st2.get("marked", []) and stale.get("key") in st2.get("pinned", []))
request("/api/pin", "POST", {"key": stale.get("key", ""), "pinned": False})
request("/api/quiet", "POST", {"start": "23:00", "end": "08:00"})

print("== 朗读：电脑合成（Mac 自带 / 微软 / Windows 自带语音）")
status, body, _ = request("/api/tts/voices")
voices = body.get("voices", [])
check("列出中文语音，最自然的在前，不列太机械的（Mac 的 Eloquence）", status == 200 and voices and body.get("best") == voices[0]["id"]
      and not any("eloquence" in v["id"] for v in voices) and voices[0]["quality"] >= voices[-1]["quality"], str(voices[:3])[:300])
def tts(text, voice=""):
    req = urllib.request.Request(BASE + "/api/tts", data=json.dumps({"text": text, "voice": voice, "rate": 1}).encode(), method="POST")
    req.add_header("X-CCP-Token", TOKEN)
    req.add_header("Content-Type", "application/json")
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=60) as res:
            return res.status, res.read(), res.headers, time.time() - t0
    except urllib.error.HTTPError as err:
        return err.code, err.read(), err.headers, time.time() - t0
status, audio, headers, first = tts("好的，首页卡片间距已经改好了，测试也全部通过。")
# Mac 自带语音是 m4a（AAC），微软语音（Mac / 电脑端装了 edge-tts 时排第一）是 mp3，Windows 自带语音是 wav
kind = headers.get("Content-Type")
looks = {"audio/mp4": audio[4:8] == b"ftyp", "audio/mpeg": audio[:3] == b"ID3" or audio[:2] in (b"\xff\xf3", b"\xff\xfb", b"\xff\xf2"),
         "audio/wav": audio[:4] == b"RIFF" and audio[8:12] == b"WAVE"}
check("合成出一段音频（Mac 自带 m4a / 微软 mp3 / Windows 自带 wav）", status == 200 and looks.get(kind, False) and len(audio) > 2000,
      "%s %s %d" % (status, kind, len(audio)))
status, again, _, second = tts("好的，首页卡片间距已经改好了，测试也全部通过。")
check("同一段第二次直接用缓存", status == 200 and again == audio and second < max(0.3, first), "%.2fs → %.2fs" % (first, second))
status, _, _, _ = tts("   ")
check("空文字被拒绝", status == 400)
status, _, _, _ = tts("长" * 1600)
check("太长的一段被拒绝（手机端会切段）", status == 400)

print("== 就绪检查")
status, body, _ = request("/api/readiness")
items = {i["id"]: i for i in body.get("items", [])}
check("Mac 这一侧的检查项都在，每项带说明和怎么补", status == 200 and {"accessibility", "https", "speech", "sources", "vscode", "login", "push"} <= set(items)
      and all(i["level"] in ("ok", "warn", "bad") and i["fix"] for i in items.values()), str(list(items))[:200])
check("来源在线、观察器版本一致时显示就绪", items.get("sources", {}).get("level") == "ok", str(items.get("sources")))
check("语音识别（测试里用假转写）显示已授权", items.get("speech", {}).get("level") == "ok")
check("用固定本机签名构建（授权跨版本保留）", items.get("signing", {}).get("level") == "ok", str(items.get("signing")))
# 一键安装（电脑端 Linux / Windows 才有这个接口；Mac 没有，回 404 就跳过）
status, body, _ = request("/api/readiness/fix", "POST", {"action": "install-tmux; rm -rf /"})
if status != 404:
    check("一键安装：不认识的动作一律拒绝", status == 409 and body.get("message") == "不支持的操作", str(body)[:200])
    status, body, _ = request("/api/readiness/fix", "POST", {"action": "install-tmux"})
    check("一键安装：测试实例里不真装（只说要执行什么，或本来就不缺）", status == 200 and
          (body.get("message", "").startswith("（测试）") or body.get("message") == "所需组件都已安装"), str(body)[:200])
    if "terminal" in items:
        check("Linux：终端会话那项给出在 tmux 里运行 claude 的现成命令", "tmux new -A -s claude claude" in items["terminal"]["fix"], items["terminal"]["fix"])

print("== 置顶会话")
status, body, _ = request("/api/pin", "POST", {"key": ask["key"], "pinned": True})
request("/api/pin", "POST", {"key": busy["key"], "pinned": True})
_, st, _ = request("/api/state")
check("置顶：后置顶的排在前面，状态里带出来", status == 200 and st.get("pinned", [])[:2] == [busy["key"], ask["key"]], str(st.get("pinned")))
request("/api/pin", "POST", {"key": busy["key"], "pinned": False})
request("/api/pin", "POST", {"key": ask["key"], "pinned": False})
_, st, _ = request("/api/state")
check("取消置顶", st.get("pinned") == [])
status, _, _ = request("/api/pin", "POST", {})
check("缺少会话时拒绝", status == 400)

print("== 标记会话")
status, body, _ = request("/api/mark", "POST", {"key": ask["key"], "marked": True})
request("/api/mark", "POST", {"key": busy["key"], "marked": True})
_, st, _ = request("/api/state")
check("标记：新标记的排在前面，状态里带出来", status == 200 and body.get("marked") is True and st.get("marked", [])[:2] == [busy["key"], ask["key"]], str(st.get("marked")))
request("/api/mark", "POST", {"key": ask["key"], "marked": False})
_, st, _ = request("/api/state")
check("取消标记", st.get("marked") == [busy["key"]], str(st.get("marked")))
status, _, _ = request("/api/mark", "POST", {})
check("缺少会话时拒绝", status == 400)
saved = json.load(open(os.path.join(CONFIG_DIR, "config.json"), encoding="utf-8"))
check("标记存在配置里（重启还在）", saved.get("mobile", {}).get("markedSessions") == [busy["key"]], str(saved.get("mobile", {}).get("markedSessions")))
request("/api/mark", "POST", {"key": ask["key"], "marked": True})
status, body, _ = request("/api/close?key=%s" % q(busy["key"]), "POST", {})
for _ in range(20):
    _, st, _ = request("/api/state")
    if st.get("marked") == [ask["key"]]:
        break
    time.sleep(0.2)
check("关闭会话后自动取消标记，别的标记不动", status == 200 and st.get("marked") == [ask["key"]], str(body) + str(st.get("marked")))
request("/api/mark", "POST", {"key": ask["key"], "marked": False})

print("== 状态增量推送（patch=1 的连接只收变了的部分）")


def open_events(query=""):
    sock = socket.create_connection(("127.0.0.1", int(HTTP_PORT)), timeout=15)
    sock.sendall(("GET /api/events%s HTTP/1.1\r\nHost: x\r\nX-CCP-Token: %s\r\nAccept: text/event-stream\r\n\r\n" % (query, TOKEN)).encode())
    return {"sock": sock, "buf": b""}


def next_event(conn, want, timeout=12):
    """读到 want 里的某个事件为止，返回 (事件名, 数据)；超时返回 (None, None)"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        while b"\n\n" in conn["buf"]:
            raw, conn["buf"] = conn["buf"].split(b"\n\n", 1)
            event, data = "message", b""
            for line in raw.split(b"\n"):
                if line.startswith(b"event: "):
                    event = line[7:].decode()
                elif line.startswith(b"data: "):
                    data += line[6:]
            if event in want:
                return event, json.loads(data)
        conn["sock"].settimeout(max(0.1, deadline - time.time()))
        try:
            chunk = conn["sock"].recv(65536)
        except socket.timeout:
            break
        if not chunk:
            break
        conn["buf"] += chunk.split(b"\r\n\r\n", 1)[1] if b"HTTP/1.1" in chunk[:12] else chunk
    return None, None


def merge_state(state, patch):
    """和 iPhone 上的 AppModel.mergeState 同一套规则"""
    if state.get("stateSeq") != patch.get("base"):
        return None
    sessions = list(state.get("sessions", []))
    index = {s["key"]: i for i, s in enumerate(sessions)}
    for item in patch.get("upsert", []):
        if item["key"] in index:
            sessions[index[item["key"]]] = item
        else:
            index[item["key"]] = len(sessions)
            sessions.append(item)
    gone = set(patch.get("remove", []))
    sessions = [s for s in sessions if s["key"] not in gone]
    if "order" in patch:
        by_key = {s["key"]: s for s in sessions}
        sessions = [by_key[k] for k in patch["order"] if k in by_key]
    merged = dict(state, sessions=sessions, **patch.get("set", {}))
    for field in patch.get("unset", []):
        merged.pop(field, None)
    merged["stateSeq"] = patch["seq"]
    return merged


def same_as_server(merged):
    _, now_state, _ = request("/api/state")
    now_state.pop("sys", None)
    return {k: v for k, v in merged.items() if k != "stateSeq"} == now_state


patch_conn, full_conn = open_events("?patch=1"), open_events()
_, patch_state = next_event(patch_conn, {"state"})
_, full_state = next_event(full_conn, {"state"})
check("连上先收整份状态，带序号", isinstance((patch_state or {}).get("stateSeq"), int) and isinstance((full_state or {}).get("stateSeq"), int),
      str(patch_state)[:200])
request("/api/quick-replies", "POST", {"items": ["增量测试"]})
event, patch = next_event(patch_conn, {"state", "statepatch"})
check("改了设置：patch=1 的连接收 statepatch，只带变了的字段", event == "statepatch" and set(patch.get("set", {})) == {"quickReplies"}
      and "upsert" not in patch and patch.get("base") == patch_state["stateSeq"], "%s %s" % (event, str(patch)[:300]))
merged = merge_state(patch_state, patch) if event == "statepatch" else None
check("合进上一份后和 /api/state 一模一样", merged is not None and same_as_server(merged))
event, full_next = next_event(full_conn, {"state", "statepatch"})
check("没要增量的连接照旧收整份 state", event == "state" and full_next.get("quickReplies") == ["增量测试"], str(event))
# 会话本身变了（记录里多了一句话）：只带这一个会话
transcript = None
for folder, _, files in os.walk(os.path.join(os.path.dirname(DATA_DIR), "projects")):
    if busy.get("sessionId", "?") + ".jsonl" in files:
        transcript = os.path.join(folder, busy["sessionId"] + ".jsonl")
if transcript:
    with open(transcript, "a", encoding="utf-8") as handle:
        handle.write(json.dumps({"type": "assistant", "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
                                 "message": {"role": "assistant", "model": "claude-opus-5-5", "id": "msg_patch",
                                             "content": [{"type": "text", "text": "增量推送测试的一句话"}]}}, ensure_ascii=False) + "\n")
    state_now = merged
    for _ in range(6):
        event, patch = next_event(patch_conn, {"state", "statepatch"})
        if event != "statepatch":
            break
        state_now = merge_state(state_now, patch)
        if state_now is None or any(s["key"] == busy["key"] and "增量推送测试" in str(s.get("preview")) for s in patch.get("upsert", [])):
            break
    check("会话有新消息：增量里只换这一个会话", event == "statepatch" and [s["key"] for s in patch.get("upsert", [])] == [busy["key"]]
          and "order" not in patch and "增量推送测试" in str(patch["upsert"][0].get("preview")), "%s %s" % (event, str(patch)[:300]))
    check("连着合几次增量仍和 /api/state 一致", state_now is not None and same_as_server(state_now))
else:
    check("找到正在运行的会话的记录文件", False)
request("/api/quick-replies", "POST", {"items": None})
for conn in (patch_conn, full_conn):
    conn["sock"].close()

print("== 网络检测")
t0 = time.time()
status, payload, headers = request("/api/ping?bytes=65536", raw=True)
check("测速接口返回指定大小的数据", status == 200 and len(payload) == 65536 and headers.get("X-Server-Time"))
status, payload, _ = request("/api/ping?bytes=99999999", raw=True)
check("测速数据有上限", len(payload) == 512 * 1024)

print("== 推送")
status, body, _ = request("/api/push/key")
key = base64.urlsafe_b64decode(body["publicKey"] + "=" * (-len(body["publicKey"]) % 4))
check("推送公钥是 65 字节的 P-256 点", status == 200 and len(key) == 65 and key[0] == 4)
sub = {"endpoint": "https://push.example.invalid/abc", "keys": {"p256dh": body["publicKey"], "auth": "AAAAAAAAAAAAAAAAAAAAAA"}}
status, body, _ = request("/api/push/subscribe", "POST", sub)
check("订阅成功", status == 200 and body["subscriptions"] >= 1)
status, body, _ = request("/api/push/unsubscribe", "POST", {"endpoint": sub["endpoint"]})
_, keyinfo, _ = request("/api/push/key")
check("取消订阅", status == 200 and keyinfo["subscriptions"] == 0)
# 已配对设备也不能让 Mac 往本机 / 内网地址发请求（SSRF）
bad_endpoints = ["http://push.example.invalid/x", "https://127.0.0.1:8765/x", "https://0x7f.1/x", "https://[::1]/x",
                 "https://router.local/x", "https://localhost/x", "https://user:pw@push.example.invalid/x",
                 "apns:production:not-hex", "apns:staging:abcdef", "ftp://push.example.invalid/x"]
rejected = [e for e in bad_endpoints
            if request("/api/push/subscribe", "POST", {"endpoint": e, "keys": sub["keys"]})[0] == 400]
check("推送订阅不收 http / IP / 本机 / 局域网地址", rejected == bad_endpoints, set(bad_endpoints) - set(rejected))
status, _, _ = request("/api/push/subscribe", "POST", {"endpoint": sub["endpoint"], "keys": {"p256dh": "AAAA", "auth": "AAAA"}})
check("推送订阅的密钥长度不对就拒收", status == 400)
_, body, _ = request("/api/devices/register", "POST", {"name": "推送测试"})
push_dev = body.get("token", "")
for i in range(6):
    request("/api/push/subscribe", "POST", {"endpoint": "https://push.example.invalid/n%d" % i, "keys": sub["keys"]}, token=push_dev)
_, keyinfo, _ = request("/api/push/key")
check("一台设备最多留 3 个推送订阅", keyinfo["subscriptions"] == 3, keyinfo["subscriptions"])
request("/api/devices/revoke", "POST", {"id": (body.get("device") or {}).get("id")})
_, keyinfo, _ = request("/api/push/key")
check("停用设备时它的推送订阅一起删", keyinfo["subscriptions"] == 0, keyinfo["subscriptions"])

print("== 压缩")
import gzip as _gzip
def fetch_raw(path, encoding=None, token=TOKEN):
    req = urllib.request.Request(BASE + path)
    if token:
        req.add_header("X-CCP-Token", token)
    if encoding:
        req.add_header("Accept-Encoding", encoding)
    with urllib.request.urlopen(req, timeout=20) as res:
        return res.status, res.read(), res.headers
# 网页版下线后拿最大的接口（更新记录，几十 KB）测压缩
_, plain_log, plain_headers = fetch_raw("/api/changelog")
status, packed_log, packed_headers = fetch_raw("/api/changelog", "gzip, deflate, br")
check("不要压缩时原样返回", plain_headers.get("Content-Encoding") is None and len(plain_log) > 10000, len(plain_log))
check("支持 gzip 时压缩返回", status == 200 and packed_headers.get("Content-Encoding") == "gzip"
      and "Accept-Encoding" in (packed_headers.get("Vary") or ""), dict(packed_headers))
try:
    check("gzip 解开和原文一字不差", _gzip.decompress(packed_log) == plain_log)
except Exception as exc:  # noqa
    check("gzip 解开和原文一字不差", False, repr(exc))
check("压缩到 60% 以内", len(packed_log) < len(plain_log) * 0.6, "%d → %d" % (len(plain_log), len(packed_log)))
check("Content-Length 是压缩后的长度", int(packed_headers.get("Content-Length", -1)) == len(packed_log))
_, plain_state, _ = fetch_raw("/api/state")
_, packed_state, state_headers = fetch_raw("/api/state", "gzip")
if len(plain_state) > 1024:
    check("会话列表也压缩", state_headers.get("Content-Encoding") == "gzip"
          and json.loads(_gzip.decompress(packed_state))["ok"] == json.loads(plain_state)["ok"])
_, small, small_headers = fetch_raw("/api/whoami", "gzip")
check("小响应不压缩", small_headers.get("Content-Encoding") is None and json.loads(small).get("ok") is not None, small[:200])

print("== Apple Watch 的外观选项")
status, body, _ = request("/api/watch")
prefs = body.get("prefs", {})
check("手表外观默认跟 iPhone、字号跟手表", status == 200 and prefs.get("theme") == "phone" and prefs.get("font") == "phone"
      and prefs.get("textSize") == "watch", str(prefs)[:200])
status, body, _ = request("/api/watch", "POST", {"theme": "ocean", "font": "serif", "textSize": "xl"})
prefs = body.get("prefs", {})
check("手表外观能改（主题、字体、字号）", status == 200 and (prefs.get("theme"), prefs.get("font"), prefs.get("textSize")) == ("ocean", "serif", "xl"), str(prefs)[:200])
_, st, _ = request("/api/state")
check("状态里带上手表外观（手机转给手表）", st.get("watch", {}).get("theme") == "ocean", str(st.get("watch"))[:200])
status, body, _ = request("/api/watch", "POST", {"theme": "neon", "font": "comic", "textSize": "huge"})
prefs = body.get("prefs", {})
check("不认识的主题、字体、字号不收", (prefs.get("theme"), prefs.get("font"), prefs.get("textSize")) == ("ocean", "serif", "xl"), str(prefs)[:200])
status, body, _ = request("/api/watch", "POST", {"theme": "wine", "font": "xingkai", "textSize": "xs"})
prefs = body.get("prefs", {})
check("手表外观：新加的主题、字体也认", (prefs.get("theme"), prefs.get("font"), prefs.get("textSize")) == ("wine", "xingkai", "xs"), str(prefs)[:200])
request("/api/watch", "POST", {"theme": "phone", "font": "phone", "textSize": "watch"})

print("== 待办（agent 经待办技能记的）与关键信息")
# agent 在会话里跑 watcher 的 todo / keyinfo 子命令：写进发图通道，Mac 收到待办直接加进来；对话历史里是 agent_todo / agent_key
import glob
import subprocess
busy_sid = busy["key"].split("#", 1)[1]
watcher_py = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "watcher", "kiteline-watch.py")

def agent_cmd(*args):
    return subprocess.run([sys.executable, watcher_py] + list(args) + ["--session", busy_sid], env=dict(os.environ, CCPULSE_DATA_DIR=DATA_DIR),
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30).stdout.decode("utf-8", "replace")

out = agent_cmd("todo", "等测试虚拟机能开后改 Windows/Linux 客户端", "--detail", "补丁在 docs/pending.patch，应用后实测")
ref_match = re.search(r"t-[0-9a-f]{6}", out)
ref = ref_match.group(0) if ref_match else "t-none"
out += agent_cmd("todo", "在微信开放平台申请小程序 AppID", "--user", "--detail", "网址、步骤；拿到后把 AppID 发给我")
agent_todos, asks, todos = [], [], {}
for _ in range(30):
    status, todos, _ = request("/api/todos")
    agent_todos = [x for x in todos.get("items", []) if x.get("agent") and x.get("source", {}).get("key") == busy["key"]]
    asks = [x for x in todos.get("suggestions", []) if x.get("key") == busy["key"]]
    if agent_todos and asks:
        break
    time.sleep(0.5)
first = agent_todos[0] if agent_todos else {}
check("agent 自己的待办直接记进「agent 的待办」：带编号、说明、来源（会话标题、机器），不算我的", len(agent_todos) == 1 and first.get("ref") == ref
      and first.get("detail") == "补丁在 docs/pending.patch，应用后实测" and not first.get("forUser")
      and first.get("source", {}).get("title") == "首页卡片间距" and first.get("source", {}).get("machine") == "本机", out + str(todos)[:300])
check("agent 的待办记下会话的项目目录、agent（按项目 / 按 Agent 分组用，会话结束了也分得出来）",
      first.get("source", {}).get("cwd") == busy.get("cwd") and bool(busy.get("cwd")) and first.get("source", {}).get("agent") == busy.get("agent", "claude-code"),
      str(first.get("source"))[:300] + " / " + str(busy.get("cwd")))
check("只有用户能做的（--user）不直接加，先成提示（现在处理 / 加入待办），带说明", len(asks) == 1 and asks[0].get("asks") == ["在微信开放平台申请小程序 AppID"]
      and asks[0].get("detail") == "网址、步骤；拿到后把 AppID 发给我", str(todos.get("suggestions"))[:300])
check("出自的那条记为处理过（不会再加第二次）", ("%s|%s" % (busy["key"], first.get("source", {}).get("itemId"))) in todos.get("handled", []))
# agent 更新自己的待办：开始做、有进展、做完；各端看得到是哪个会话在处理、到哪一步了
steps = [("start", "开始做：先应用补丁", "doing", False), ("progress", "补丁已应用，Win11 上实测通过，Linux 还在测", "doing", False),
         ("done", "两端都实测通过，已装到测试机", "done", True)]
for action, note, want, done in steps:
    out = agent_cmd("todo", action, ref, note)
    item = {}
    for _ in range(30):
        _, todos, _ = request("/api/todos")
        item = next((x for x in todos.get("items", []) if x.get("ref") == ref), {})
        if item.get("progress") == note:
            break
        time.sleep(0.3)
    check("todo %s：状态 %s、进度、处理它的会话" % (action, want), item.get("status") == want and item.get("progress") == note
          and item.get("done") == done and item.get("handler", {}).get("key") == busy["key"]
          and item.get("handler", {}).get("cwd") == busy.get("cwd"), out + str(item)[:300])
out = agent_cmd("todo", "list", "--all")
check("todo list --all 列出编号、状态、进度", ref in out and "两端都实测通过" in out, out)
out = agent_cmd("todo", "start", "t-ffffff")
check("不存在的编号说清楚", "t-ffffff" in out, out)
# agent 的待办推给 watcher：agent 用 todo list / done 看得到、关得掉别的会话或别的电脑上记的
pushed, row = {}, {}
for _ in range(20):
    try:
        pushed = json.load(open(os.path.join(DATA_DIR, "agent-todos.json"), encoding="utf-8"))
    except (OSError, ValueError):
        pushed = {}
    row = next((x for x in pushed.get("items", []) if x.get("ref") == ref), {})
    if row.get("status") == "done":
        break
    time.sleep(0.3)
check("agent 的待办推给 watcher：带编号、状态、在处理的会话", row.get("status") == "done" and row.get("key") == busy["key"]
      and row.get("title") == "首页卡片间距", str(pushed)[:300])
# 用户替 agent 勾掉 / 恢复：状态跟着变（agent 那边 todo list 对得上）
status, body, _ = request("/api/todos/update", "POST", {"id": first.get("id", ""), "done": False})
item = next((x for x in body.get("items", []) if x.get("ref") == ref), {})
check("用户把 agent 的待办恢复成未完成：状态回到待处理", item.get("status") == "pending" and not item.get("done") and item.get("updatedAt"), str(item)[:300])
# 没编号的 agent 待办（10-27 中午之前记的）补上编号，agent 才关得掉
status, body, _ = request("/api/todos/add", "POST", {"texts": ["没编号的 agent 待办"], "agent": True, "forUser": False})
legacy = next((x for x in body.get("items", []) if x.get("text") == "没编号的 agent 待办"), {})
check("没编号的 agent 待办补上编号", re.fullmatch(r"t-[0-9a-f]{6}", legacy.get("ref") or "") is not None and legacy.get("status") == "pending", str(legacy)[:300])
request("/api/todos/delete", "POST", {"ids": [legacy.get("id", "")]})
_, hist, _ = request("/api/history?key=%s&limit=200" % q(busy["key"]))
marks = [i for i in hist.get("items", []) if i["t"] == "agent_todo"]
updates = [i for i in hist.get("items", []) if i["t"] == "agent_todo_update"]
check("对话历史里有这两条待办（agent_todo，提醒用户的那条带 forUser）", len(marks) == 2 and [bool(i.get("forUser")) for i in marks] == [False, True]
      and marks[0].get("ref") == ref, str(marks)[:300])
check("对话历史里有三条进度（agent_todo_update）", [i.get("status") for i in updates] == ["doing", "doing", "done"] and updates[-1].get("ref") == ref, str(updates)[:300])
# 用户点「加入待办」：进「我的待办」，说明跟着带上，提示消失
status, body, _ = request("/api/todos/add", "POST", {"texts": asks[0]["asks"] if asks else ["?"], "key": busy["key"], "itemId": asks[0]["itemId"] if asks else ""})
mine = next((x for x in body.get("items", []) if x.get("text") == "在微信开放平台申请小程序 AppID"), {})
check("加入待办：我的待办（forUser）带说明，提示消失", status == 200 and mine.get("forUser") is True and mine.get("detail") == "网址、步骤；拿到后把 AppID 发给我"
      and not [x for x in body.get("suggestions", []) if x.get("key") == busy["key"]], str(body)[:300])
request("/api/todos/delete", "POST", {"ids": [mine.get("id", ""), first.get("id", "")]})
out = agent_cmd("keyinfo", "测试环境管理员账号", "--field", "账号=admin@example.com", "--secret", "密码=Xy7#k2pQ", "--note", "只在测试环境用")
key_item = None
for _ in range(20):
    _, hist, _ = request("/api/history?key=%s&limit=200" % q(busy["key"]))
    key_item = next((i for i in hist.get("items", []) if i["t"] == "agent_key"), None)
    if key_item:
        break
    time.sleep(0.5)
check("关键信息（agent_key）：标题、各项（密码标 secret）、补充说明、拼好的纯文字", key_item is not None and key_item.get("title") == "测试环境管理员账号"
      and [f.get("secret") for f in key_item.get("fields", [])] == [False, True] and key_item.get("note") == "只在测试环境用"
      and "密码：Xy7#k2pQ" in key_item.get("text", ""), out + str(key_item))
# 不再从 Claude 的回复里猜「需要你来做」（10-27 反馈太宽泛）
transcript = glob.glob(os.path.join(os.path.dirname(DATA_DIR), "projects", "*", busy_sid + ".jsonl"))[0]

def reply_line(text, ago, mid):
    t = time.time() - ago
    return json.dumps({"type": "assistant", "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".000Z",
                       "cwd": busy.get("cwd", ""), "message": {"role": "assistant", "model": "claude-opus-5-5", "id": mid,
                       "content": [{"type": "text", "text": text}]}}, ensure_ascii=False) + "\n"

with open(transcript, "a", encoding="utf-8") as handle:
    handle.write(reply_line("改好了。\n\n**需要你来做**\n\n1. 执行迁移 553、554，重启 worker。", 1, "msg_todo_new"))
time.sleep(2)
_, todos, _ = request("/api/todos")
_, hist, _ = request("/api/history?key=%s&limit=200" % q(busy["key"]))
check("不再从回复里猜待办：没有提示、历史不带 asks", not todos.get("suggestions") and not any(i.get("asks") for i in hist.get("items", [])),
      str(todos.get("suggestions"))[:200])
status, body, _ = request("/api/todos/add", "POST", {"texts": ["执行迁移 553、554，重启 worker。", "  "], "key": busy["key"],
                                                     "itemId": "msg-manual", "title": "手机传的标题", "ts": 1, "detail": "补的说明", "agent": True})
added = [i for i in body.get("items", []) if i.get("source", {}).get("itemId") == "msg-manual"]
check("从对话卡片补加：记下出自哪条消息（标题取 Mac 上的），带说明", status == 200 and len(added) == 1 and added[0].get("detail") == "补的说明"
      and added[0].get("agent") is True and added[0]["source"].get("title") == "首页卡片间距" and not added[0]["done"], str(body)[:300])
status, body, _ = request("/api/todos/add", "POST", {"texts": ["执行迁移 553、554，重启 worker。"], "key": busy["key"], "itemId": "msg-manual"})
check("同一条消息的同一句不重复加", len([i for i in body.get("items", []) if i.get("source", {}).get("itemId") == "msg-manual"]) == 1)
todo_id = added[0]["id"] if added else "none"
status, body, _ = request("/api/todos/update", "POST", {"id": todo_id, "done": True})
item = next((i for i in body.get("items", []) if i["id"] == todo_id), {})
check("打勾：做完了、记下时间", status == 200 and item.get("done") is True and item.get("doneAt", 0) > 0, str(item))
status, body, _ = request("/api/todos/update", "POST", {"id": todo_id, "text": "执行迁移 553、554"})
check("改字", next((i["text"] for i in body.get("items", []) if i["id"] == todo_id), "") == "执行迁移 553、554")
status, _, _ = request("/api/todos/update", "POST", {"id": todo_id, "text": "   "})
check("改成空的不收", status == 400)
status, _, _ = request("/api/todos/update", "POST", {"id": "nope", "done": True})
check("不存在的待办返回 404", status == 404)
status, _, _ = request("/api/todos/add", "POST", {"texts": []})
check("空的不收", status == 400)
status, body, _ = request("/api/todos/add", "POST", {"texts": ["给客户发报价清单"]})
manual = next((i for i in body.get("items", []) if i["text"] == "给客户发报价清单"), {})
check("自己记一条（没有来源、不是 agent 记的）", status == 200 and manual and "source" not in manual and not manual.get("agent"), str(manual))
status, body, _ = request("/api/todos/dismiss", "POST", {"key": busy["key"], "itemId": "123.0"})
check("忽略一条消息：记为处理过", status == 200 and ("%s|123.0" % busy["key"]) in body.get("handled", []))
status, body, _ = request("/api/todos/dismiss", "POST", {"items": [{"key": busy["key"], "itemId": "124.0"}, {"bad": 1}]})
check("忽略几条：格式不对的条目跳过，不报错", status == 200 and ("%s|124.0" % busy["key"]) in body.get("handled", []))
status, body, _ = request("/api/todos/delete", "POST", {"ids": [manual.get("id", "")]})
check("删除", status == 200 and not any(i["text"] == "给客户发报价清单" for i in body.get("items", [])))
status, body, _ = request("/api/todos/clear-done", "POST", {})
check("清空已完成", status == 200 and not any(i["done"] for i in body.get("items", [])), str(body.get("items"))[:200])
time.sleep(0.5)
saved = json.load(open(os.path.join(CONFIG_DIR, "todos.json"), encoding="utf-8"))
check("存到配置目录 todos.json", ("%s|123.0" % busy["key"]) in saved.get("handled", []), str(saved)[:200])
# 附截图：记一条带两张图，取图；修改时留一张、去一张、加一张；删掉这条，文件也删
png = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGP4z8DAwMDAxMDAwMDAAAANBAEB6M9V3gAAAABJRU5ErkJggg=="
jpg = base64.b64encode(b"\xff\xd8\xff\xe0" + b"0" * 64).decode()
status, body, _ = request("/api/todos/add", "POST", {"texts": ["看一下这两张截图里的报错"], "images": [{"data": png}, {"data": jpg}]})
shot = next((i for i in body.get("items", []) if i["text"] == "看一下这两张截图里的报错"), {})
refs = [im["ref"] for im in shot.get("images", [])]
check("记一条带两张截图", status == 200 and len(refs) == 2 and refs[0].endswith(".png") and refs[1].endswith(".jpg"), str(shot)[:300])
status, raw, headers = request("/api/todos/media?ref=%s" % q(refs[0] if refs else "x"), raw=True)
check("取截图（可长期缓存）", status == 200 and raw == base64.b64decode(png) and "immutable" in headers.get("Cache-Control", ""), str(status))
media_dir = os.path.join(CONFIG_DIR, "todo-media")
status, body, _ = request("/api/todos/update", "POST", {"id": shot.get("id", ""), "text": "看截图里的报错", "images": [{"ref": refs[1] if len(refs) > 1 else ""}, {"data": png}, {"ref": "ffffffffffffffff.jpg"}]})
after = next((i for i in body.get("items", []) if i.get("id") == shot.get("id")), {})
new_refs = [im["ref"] for im in after.get("images", [])]
check("修改：留一张、去一张、加一张（别人的 ref 不认）", status == 200 and len(new_refs) == 2 and new_refs[0] == refs[1] and new_refs[1] not in refs
      and after.get("text") == "看截图里的报错", str(after)[:300])
check("去掉的截图连文件一起删", refs and not os.path.exists(os.path.join(media_dir, refs[0])) and all(os.path.exists(os.path.join(media_dir, r)) for r in new_refs))
status, body, _ = request("/api/todos/update", "POST", {"id": shot.get("id", ""), "text": "只改字"})
check("只改字不动截图", [im["ref"] for im in next((i for i in body.get("items", []) if i.get("id") == shot.get("id")), {}).get("images", [])] == new_refs)
status, _, _ = request("/api/todos/add", "POST", {"texts": ["坏图"], "images": [{"data": base64.b64encode(b"not an image at all").decode()}]})
check("不是图片的不收", status == 400)
status, _, _ = request("/api/todos/add", "POST", {"texts": ["太多"], "images": [{"data": png}] * 10})
check("超过 9 张不收", status == 400)
status, _, _ = request("/api/todos/media?ref=%s" % q("../todos.json"), raw=True)
check("取图不能越界", status == 404)
request("/api/todos/delete", "POST", {"ids": [shot.get("id", "")]})
check("删掉待办，截图文件也删", not any(os.path.exists(os.path.join(media_dir, r)) for r in new_refs))
status, _, _ = request("/api/todos", token=None)
check("待办要鉴权", status == 401)

print("== 收藏（收藏的消息）")
fav_body = {"key": busy["key"], "itemId": "fav-item-1", "who": "bot", "speaker": "Claude", "agent": "claude-code", "ts": 1761292800000,
            "title": "手机上传来的标题", "text": "统计后台已上线\n- 地址：https://example.com", "images": [{"data": png}]}
status, body, _ = request("/api/favorites/add", "POST", fav_body)
fav = next((i for i in body.get("items", []) if i.get("itemId") == "fav-item-1"), {})
fav_refs = [im["ref"] for im in fav.get("images", [])]
check("收藏一条（文字 + 图，标题取 Mac 上的会话名、记下机器）", status == 200 and fav.get("text", "").startswith("统计后台") and len(fav_refs) == 1
      and fav.get("title") == busy.get("title", fav.get("title")) and fav.get("machine") and fav.get("who") == "bot", str(fav)[:300])
status, body, _ = request("/api/favorites/add", "POST", fav_body)
check("同一条消息收藏两次只算一条", status == 200 and sum(1 for i in body.get("items", []) if i.get("itemId") == "fav-item-1") == 1)
status, raw, headers = request("/api/favorites/media?ref=%s" % q(fav_refs[0] if fav_refs else "x"), raw=True)
check("取收藏里的图", status == 200 and raw == base64.b64decode(png), str(status))
status, _, _ = request("/api/favorites/add", "POST", {"key": busy["key"], "itemId": "fav-empty"})
check("没有文字和图的不收", status == 400)
status, _, _ = request("/api/favorites/add", "POST", {"key": busy["key"], "itemId": "fav-many", "images": [{"data": png}] * 10})
check("收藏的图超过 9 张不收", status == 400)
status, _, _ = request("/api/favorites/media?ref=%s" % q("../favorites.json"), raw=True)
check("收藏取图不能越界", status == 404)
fav_dir = os.path.join(CONFIG_DIR, "favorite-media")
status, body, _ = request("/api/favorites/delete", "POST", {"key": busy["key"], "itemId": "fav-item-1"})
check("取消收藏（按消息），图文件一起删", status == 200 and not any(i.get("itemId") == "fav-item-1" for i in body.get("items", []))
      and not any(os.path.exists(os.path.join(fav_dir, r)) for r in fav_refs))
status, _, _ = request("/api/favorites", token=None)
check("收藏要鉴权", status == 401)

print("== HTTPS 与证书")
status, profile, headers = request("/ca.mobileconfig", token=None, raw=True)
check("证书描述文件可下载", status == 200 and headers.get("Content-Type") == "application/x-apple-aspen-config"
      and b"com.apple.security.root" in profile)
ca = os.path.join(CONFIG_DIR, "tls", "ca.pem")
for _ in range(20):
    if os.path.exists(ca):
        break
    time.sleep(0.5)
# 严格校验用系统 curl（SecureTransport，就是苹果的 Security 框架，和 iPhone App、Safari 同一套校验）：
# 测试用的 Python 链的是 LibreSSL 2.8，不认根证书里的 IP 名称约束
import subprocess
verified = subprocess.run(["curl", "-s", "--max-time", "10", "--cacert", ca, "-H", "X-CCP-Token: " + TOKEN,
                           "https://127.0.0.1:%s/api/info" % HTTPS_PORT], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    body = json.loads(verified.stdout or b"{}")
except ValueError:
    body = {}
check("HTTPS 用本机根证书严格校验通过", verified.returncode == 0 and body.get("ok"),
      "curl %d %s" % (verified.returncode, verified.stderr.decode("utf-8", "replace")[:200]))
check("info 列出 https 地址", any(u.startswith("https://") for u in body.get("https", [])))
ca_text = subprocess.run(["openssl", "x509", "-in", ca, "-noout", "-text"],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.decode("utf-8", "replace")
check("新生成的根证书带名称约束（只能签私网 / 本机地址和 .local 名字），不能再签下级 CA",
      "Name Constraints: critical" in ca_text and "IP:192.168.0.0/255.255.0.0" in ca_text and "DNS:local" in ca_text
      and "pathlen:0" in ca_text, ca_text[-300:])
evil = subprocess.run(["curl", "-s", "-o", "/dev/null", "--max-time", "10", "--cacert", ca, "--resolve", "evil.example.com:%s:127.0.0.1" % HTTPS_PORT,
                       "https://evil.example.com:%s/api/ping" % HTTPS_PORT], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
check("用别的域名访问时证书不被认", evil.returncode != 0)

print("== 会话群（跨设备、跨项目的会话互相发消息；dry-run 不真的投递）")
plan = by_title.get("订单导出功能", {})
plan_sid = plan.get("key", "#").split("#", 1)[1]
status, now, _ = request("/api/state")
check("状态里报告支持会话群", "groups" in (now.get("features") or []), str(now.get("features")))

def agent_as(sid, *args):
    run = subprocess.run([sys.executable, watcher_py] + list(args) + ["--session", sid], env=dict(os.environ, CCPULSE_DATA_DIR=DATA_DIR),
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
    return run.returncode, run.stdout.decode("utf-8", "replace")

def group_messages(gid, want=None, timeout=10):
    items = []
    for _ in range(int(timeout / 0.3)):
        _, body, _ = request("/api/groups/messages?id=%s" % q(gid))
        items = body.get("items", [])
        if want is None or want(items):
            break
        time.sleep(0.3)
    return items

status, body, _ = request("/api/groups/create", "POST", {"keys": [busy["key"]]})
check("只选一个会话不能建群", status == 400)
status, body, _ = request("/api/groups/create", "POST", {"keys": [busy["key"], plan["key"]], "topic": "导出接口改好后告诉首页那边。别的不用管"})
group = body.get("group", {})
gid = group.get("id", "")
check("建群：成员带标题、电脑、项目，群名先取要协作的事的第一句，等 agent 起正式名字",
      status == 200 and [m["title"] for m in group.get("members", [])] == ["首页卡片间距", "订单导出功能"]
      and group["members"][0].get("machine") == "本机" and group["members"][1].get("project") == "admin"
      and group.get("name") == "导出接口改好后告诉首页那边" and group.get("autoName") is True, str(body)[:400])
items = group_messages(gid, lambda xs: any(x["from"] == "me" and x.get("states", {}).get(busy["key"]) == "sent" for x in xs))
first = next((x for x in items if x["from"] == "me"), {})
check("要协作的事作为第一条群消息发给全部成员：空闲 / 在忙的送达，等确认的先排着（回车会替你点允许）",
      first.get("states", {}).get(busy["key"]) == "sent" and first.get("states", {}).get(plan["key"]) == "pending", str(items)[:400])
sent = log_tail().split("[dry-run] 群消息全文")[-1]
check("第一次投递带群说明（成员、电脑 · 项目、怎么发言、请起群名）和要协作的事",
      "【Kiteline 会话群「导出接口改好后告诉首页那边」】" in sent and "订单导出功能（本机 · admin）" in sent and "· 你：首页卡片间距" in sent
      and "group say" in sent and "--name" in sent and "【群「导出接口改好后告诉首页那边」· 用户】\n导出接口改好后告诉首页那边。别的不用管" in sent, sent[:600])

def pushed(pred, timeout=8):
    """电脑推给 watcher 的群名单（group 子命令核对成员用）到了"""
    for _ in range(int(timeout / 0.2)):
        try:
            with open(os.path.join(DATA_DIR, "groups.json"), encoding="utf-8") as handle:
                if pred(json.load(handle).get("items", [])):
                    return True
        except (OSError, ValueError):
            pass
        time.sleep(0.2)
    return False

check("建群后群名单马上推给 watcher", pushed(lambda gs: any(g.get("id") == gid for g in gs), timeout=3))
code, out = agent_as(plan_sid, "group", "info")
check("group info：群名、成员、谁是自己、最近的群消息", code == 0 and "订单导出功能（本机 · admin）　你" in out and "首页卡片间距" in out
      and "导出接口改好后告诉首页那边" in out, out[:400])
code, out = agent_as(plan_sid, "group", "say", "导出接口改好了，字段见 docs/export.md", "--name", "订单导出联调")
check("agent 发群消息：电脑收到并投递给其他成员", code == 0 and "已发到群" in out and "首页卡片间距 会收到" in out, out)
items = group_messages(gid, lambda xs: any(x["from"] == plan["key"] and x.get("states", {}).get(busy["key"]) == "sent" for x in xs))
said = next((x for x in items if x["from"] == plan["key"]), {})
check("群里记下 agent 的发言、送达状态、出自它对话里的哪一条", said.get("text") == "导出接口改好了，字段见 docs/export.md"
      and said.get("states") == {busy["key"]: "sent"} and str(said.get("itemId", "")).startswith("o"), str(items)[-400:])
sent = log_tail().split("[dry-run] 群消息全文")[-1]
check("投递给成员：带群名、发言的会话和它在哪台电脑哪个项目；看过说明的只带一行回复方法", "【群「订单导出联调」· 订单导出功能（本机 · admin）】" in sent
      and "导出接口改好了" in sent and "【Kiteline 会话群" not in sent and "回复群里：" in sent, sent[:300])
status, body, _ = request("/api/groups")
check("第一个发言的 agent 用 --name 起了正式群名", (body.get("items") or [{}])[0].get("name") == "订单导出联调"
      and (body.get("items") or [{}])[0].get("autoName") is False, str(body)[:300])
code, out = agent_as(plan_sid, "group", "say", "x", "--to", "不存在的会话")
check("--to 写错成员：不发，列出成员", code == 4 and "首页卡片间距" in out, out)
ask_sid = by_title.get("选择登录方案", {}).get("key", "#").split("#", 1)[1]
code, out = agent_as(ask_sid, "group", "say", "我也想说")
check("不在群里的会话发不了群消息", code == 4 and "不在任何会话群里" in out, out)
status, body, _ = request("/api/history?key=%s&limit=200" % q(plan["key"]))
check("对话记录里是一条 group_say（各端画成「发到群」卡片）", any(i.get("t") == "group_say" and i.get("group") == gid for i in body.get("items", [])),
      str([i.get("t") for i in body.get("items", [])][-6:]))

status, body, _ = request("/api/groups/send", "POST", {"id": gid, "text": "首页也改好了吗？", "to": [busy["key"]]})
check("用户在群里发话，可以只发给某一个成员", status == 200 and body.get("message", {}).get("to") == [busy["key"]]
      and list(body["message"].get("states", {}).keys()) == [busy["key"]], str(body)[:300])
check("状态里报告群里能发图、文件", "groupMedia" in (now.get("features") or []), str(now.get("features")))
status, body, _ = request("/api/groups/send", "POST", {"id": gid, "text": "", "to": [busy["key"]],
                                                       "images": [{"name": "截图.jpg", "data": photo}],
                                                       "files": [{"name": "需求.txt", "data": base64.b64encode("字段说明".encode()).decode()}]})
sent_media = body.get("message", {})
check("群里只发图和文件（不写字）也行：消息里记着图、文件的原名和大小",
      status == 200 and sent_media.get("text") == "" and [m.get("name") for m in sent_media.get("images", [])] == ["截图.jpg"]
      and [m.get("name") for m in sent_media.get("files", [])] == ["需求.txt"], str(body)[:300])
image_ref = (sent_media.get("images") or [{}])[0].get("ref", "")
file_ref = (sent_media.get("files") or [{}])[0].get("ref", "")
status, data, headers = request("/api/groups/media?id=%s&ref=%s" % (q(gid), q(image_ref)), raw=True)
check("群里的图从电脑取回", status == 200 and data == base64.b64decode(photo) and headers.get("Content-Type", "").startswith("image/jpeg"), str(status))
status, data, headers = request("/api/groups/media?id=%s&ref=%s" % (q(gid), q(file_ref)), raw=True)
check("群里的文件原样取回", status == 200 and data == "字段说明".encode(), str(status))
status, body, _ = request("/api/groups/media?id=%s&ref=%s" % (q(gid), q("../groups.json")))
check("取群文件只认自己起的文件名（不能借它读别的文件）", status == 404, str(status))
group_messages(gid, lambda xs: any(x.get("id") == sent_media.get("id") and x.get("states", {}).get(busy["key"]) == "sent" for x in xs))
media_text = log_tail().split("[dry-run] 群消息全文 → 首页卡片间距")[-1]
check("投递时带上图和文件（先传到成员所在的电脑，路径写在消息末尾）",
      "附图 1 张，附件 需求.txt" in media_text and "附 2 个图片或文件" in media_text, media_text[:400])
status, body, _ = request("/api/groups/send", "POST", {"id": gid, "text": "", "images": [{"name": "x.jpg", "data": photo}] * 7})
check("一次最多 6 张图", status == 400, str(body)[:200])
status, body, _ = request("/api/groups/rename", "POST", {"id": gid, "name": "导出联调（用户改）"})
check("用户改群名：之后 agent 不再自动起名", status == 200 and body["group"]["name"] == "导出联调（用户改）" and body["group"]["autoName"] is False)
code, out = agent_as(plan_sid, "group", "say", "收到", "--name", "又一个名字")
time.sleep(1.5)
status, body, _ = request("/api/groups")
check("用户改过的群名 agent 改不动", (body.get("items") or [{}])[0].get("name") == "导出联调（用户改）", str(body)[:200])

status, body, _ = request("/api/groups/add", "POST", {"id": gid, "keys": [ENDED]})
check("加进一个已经关了的会话", status == 200 and ENDED in [m["key"] for m in body["group"]["members"]], str(body)[:300])
member = {}
for _ in range(30):
    _, body, _ = request("/api/groups")
    member = next((m for g in body.get("items", []) for m in g.get("members", []) if m["key"] == ENDED), {})
    if member.get("title") == "登录页按钮改版":
        break
    time.sleep(0.3)
check("关了的成员去它那台电脑上查到标题、项目", member.get("title") == "登录页按钮改版" and member.get("project") == os.path.basename(busy["cwd"]), str(member))
code, out = agent_as(plan_sid, "group", "say", "登录页那边也看一下")
items = group_messages(gid, lambda xs: any(x.get("states", {}).get(ENDED) == "ended" for x in xs))
check("agent 发给关了的成员：先记着（恢复时补上），不去恢复", any(x.get("states", {}).get(ENDED) == "ended" for x in items), str(items)[-300:])
status, body, _ = request("/api/groups/send", "POST", {"id": gid, "text": "都接着干吧"})
items = group_messages(gid, lambda xs: any(x.get("text") == "都接着干吧" and x.get("states", {}).get(ENDED) == "sent" for x in xs))
resumed = log_tail().split("[dry-run] 群消息全文 → 登录页按钮改版（恢复）")[-1]
check("用户在群里发话：关了的成员在原项目里恢复，带上群说明、它错过的群消息和这句话",
      "[dry-run] 恢复会话 eeeeeeee-1111-2222-3333-444444444444" in log_tail() and "【Kiteline 会话群「导出联调（用户改）」】" in resumed
      and resumed.find("登录页那边也看一下") < resumed.find("都接着干吧") and "登录页那边也看一下" in resumed, resumed[:500])
check("恢复后错过的、这一句都记成已送达", all(x.get("states", {}).get(ENDED) == "sent" for x in items if x.get("text") in ("登录页那边也看一下", "都接着干吧")),
      str([x for x in items if ENDED in x.get("states", {})])[:300])

status, body, _ = request("/api/groups/pause", "POST", {"id": gid, "paused": True})
pushed(lambda gs: any(g.get("id") == gid and g.get("paused") for g in gs))
code, out = agent_as(plan_sid, "group", "say", "暂停时说的")
items = group_messages(gid, lambda xs: any(x.get("text") == "暂停时说的" for x in xs))
held = next((x for x in items if x.get("text") == "暂停时说的"), {})
check("暂停转发：消息记在群里但不投递", held.get("states", {}).get(busy["key"]) == "paused" and "转发已暂停" in out, str(held) + out)
status, body, _ = request("/api/groups/pause", "POST", {"id": gid, "paused": False})
items = group_messages(gid, lambda xs: any(x.get("text") == "暂停时说的" and x.get("states", {}).get(busy["key"]) == "sent" for x in xs))
check("继续转发：暂停时攒下的接着投", any(x.get("text") == "暂停时说的" and x.get("states", {}).get(busy["key"]) == "sent" for x in items))
def group_notes(group_id):
    return [e for e in request("/api/inbox?limit=300")[1].get("entries", []) if e.get("kind") == "group" and e.get("route") == "group:" + group_id]

notes = group_notes(gid)
check("agent 在群里发言推一条提醒（点开进群聊页，老版本进发言的会话）；同一个群两分钟内只推一条",
      len(notes) == 1 and notes[0].get("title") == "订单导出联调" and notes[0].get("key") == plan["key"]
      and notes[0].get("body", "").startswith("订单导出功能：导出接口改好了"), str(notes)[:400])
status, body, _ = request("/api/groups/create", "POST", {"keys": [busy["key"], plan["key"]], "topic": "第二个群"})
gid2 = body.get("group", {}).get("id", "")
status, body, _ = request("/api/groups")
check("群列表按最近动静排", [g["id"] for g in body.get("items", [])][:2] == [gid2, gid], str([g["id"] for g in body.get("items", [])]))
status, body, _ = request("/api/groups/mark", "POST", {"id": gid, "marked": True})
check("标记群", status == 200 and body.get("group", {}).get("marked") is True, str(body)[:200])
status, body, _ = request("/api/groups")
check("标记的群排最上面", [g["id"] for g in body.get("items", [])][:2] == [gid, gid2] and body["items"][0].get("marked") is True
      and body["items"][1].get("marked") is False, str([(g["id"], g.get("marked")) for g in body.get("items", [])]))
status, body, _ = request("/api/groups/mute", "POST", {"id": gid2, "muted": True})
check("群免打扰", status == 200 and body.get("group", {}).get("muted") is True, str(body)[:200])
pushed(lambda gs: any(g.get("id") == gid2 for g in gs))
code, out = agent_as(plan_sid, "group", "say", "免打扰的群里说一句", "--group", gid2)
group_messages(gid2, lambda xs: any(x.get("text") == "免打扰的群里说一句" for x in xs))
check("免打扰的群：agent 发言照常转发，但不推提醒", code == 0 and group_notes(gid2) == [], out + str(group_notes(gid2))[:300])
request("/api/groups/mark", "POST", {"id": gid, "marked": False})
status, body, _ = request("/api/groups/delete", "POST", {"id": gid2})
check("取消标记后按最近动静排", status == 200 and [g["id"] for g in body.get("items", [])] == [gid]
      and body["items"][0].get("marked") is False, str(body)[:200])

status, body, _ = request("/api/groups/remove", "POST", {"id": gid, "key": ENDED})
check("移出成员", status == 200 and ENDED not in [m["key"] for m in body["group"]["members"]])
status, body, _ = request("/api/groups/delete", "POST", {"id": gid})
check("解散群", status == 200 and gid not in [g["id"] for g in body.get("items", [])])
status, body, _ = request("/api/groups/messages?id=%s" % q(gid))
check("解散后消息一并删除", status == 404)

print("\n接口：%d 项通过，%d 项失败" % (PASS[0], len(FAIL)))
sys.exit(1 if FAIL else 0)
