"""在临时目录里造几个合成的 Claude Code 会话（只写 ROOT，不碰真实的 ~/.claude）。

四个会话：等你回答提问、等你批准命令、正在运行（带图片/TODO/diff/智能体发图）、等你批准计划。
每个会话由一个 sleep 进程充当「Claude 进程」，pid 记在 <ROOT>/pids，测试结束只收这些（不误杀别的 sleep）。

用法：python3 tests/fixture.py <ROOT> [一张 png]
环境变量 FIXTURE_DEMO=1：给 iOS 演示模式录数据用（tests/record_demo.sh）——不造「用量到上限」那个出错的会话，
再补几个过去一周里已经结束的会话，让用量图、历史会话看起来像真的在用。集成测试不带它，数据和以前一样。
"""
import base64
import json
import os
import subprocess
import sys
import time
import uuid

ROOT = sys.argv[1]
DEMO = os.environ.get("FIXTURE_DEMO") == "1"
PNG = sys.argv[2] if len(sys.argv) > 2 else None
SESS = os.path.join(ROOT, "sessions")
PROJ = os.path.join(ROOT, "projects")
DATA = os.path.join(ROOT, "data")
os.makedirs(SESS, exist_ok=True)
os.makedirs(os.path.join(DATA, "outbox", "files"), exist_ok=True)
# 没给图片就用一张 2x2 的小 PNG
TINY = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGP4z8DAwMDAxMDAwMDAAAANBAEB6M9V3gAAAABJRU5ErkJggg=="
img = base64.b64encode(open(PNG, "rb").read()).decode() if PNG else TINY
now = time.time()

# 一个真的 git 仓库：几次提交 + 未提交的改动 + 一个新文件（改动报告用）
REPO = os.path.join(ROOT, "src", "shop-app")
os.makedirs(os.path.join(REPO, "src", "styles"), exist_ok=True)


def git(*args):
    subprocess.run(["git", "-C", REPO] + list(args), check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   env=dict(os.environ, GIT_AUTHOR_NAME="演示用户", GIT_AUTHOR_EMAIL="demo@example.com",
                            GIT_COMMITTER_NAME="演示用户", GIT_COMMITTER_EMAIL="demo@example.com"))


git("init", "-q", "-b", "main")
with open(os.path.join(REPO, "src", "styles", "home.css"), "w") as handle:
    handle.write(".home {\n  --card-gap: 4px;\n  --card-radius: 8px;\n}\n")
with open(os.path.join(REPO, "README.md"), "w") as handle:
    handle.write("# shop-app\n")
git("add", "-A"); git("commit", "-q", "-m", "首页初版")
with open(os.path.join(REPO, "src", "app.js"), "w") as handle:
    handle.write("export const version = 1;\n")
git("add", "-A"); git("commit", "-q", "-m", "加上版本号")
with open(os.path.join(REPO, "src", "styles", "home.css"), "w") as handle:
    handle.write(".home {\n  --card-gap: 16px;\n  --card-radius: 12px;\n  --card-shadow: 0 1px 3px rgba(0,0,0,.1);\n}\n")
with open(os.path.join(REPO, "src", "card.js"), "w") as handle:
    handle.write("export function card(title) {\n  return `<div class=\"card\">${title}</div>`;\n}\n")


def iso(offset):
    t = now - offset
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".%03dZ" % int((t % 1) * 1000)


def escape(cwd):
    return "".join(ch if (ch.isascii() and ch.isalnum()) else "-" for ch in cwd)


def session(name, title, cwd, status, rows, waiting_for=None):
    sid = str(uuid.uuid4())
    if os.name == "nt":   # Windows（电脑端测试）没有 sleep 命令：用 Python 自己挂两小时
        proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(7200)"], stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, creationflags=0x08000000)
    else:
        proc = subprocess.Popen(["sleep", "7200"], start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(os.path.join(ROOT, "pids"), "a") as handle:
        handle.write("%d\n" % proc.pid)
    folder = os.path.join(PROJ, escape(cwd))
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, sid + ".jsonl"), "w") as handle:
        handle.write(json.dumps({"type": "ai-title", "aiTitle": title, "sessionId": sid}, ensure_ascii=False) + "\n")
        for row in rows:
            handle.write(json.dumps(dict(row, cwd=cwd), ensure_ascii=False) + "\n")   # 真实对话记录每行都带 cwd
    record = {"pid": proc.pid, "sessionId": sid, "cwd": cwd, "name": name, "status": status,
              "entrypoint": "claude-vscode", "kind": "interactive", "startedAt": int((now - 3600) * 1000),
              "updatedAt": int(now * 1000), "statusUpdatedAt": int(now * 1000)}
    if waiting_for:
        record["waitingFor"] = waiting_for
    with open(os.path.join(SESS, "%d.json" % proc.pid), "w") as handle:
        json.dump(record, handle, ensure_ascii=False)
    return sid


def user(text, ago, images=False):
    content = [{"type": "text", "text": text}]
    if images:
        content.insert(0, {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": img}})
    return {"type": "user", "timestamp": iso(ago), "message": {"role": "user", "content": content}}


_context = [60000]


def assistant(blocks, ago):
    # 带上用量：上下文逐条增长，便于核对「上下文 xx%」
    _context[0] += 23000
    usage = {"input_tokens": 12, "output_tokens": 900, "cache_read_input_tokens": _context[0], "cache_creation_input_tokens": 1500}
    return {"type": "assistant", "timestamp": iso(ago), "message": {"role": "assistant", "model": "claude-opus-5-5",
            "id": "msg_%d" % _context[0], "usage": usage, "content": blocks}}


def result(tool_id, text, ago, error=False, image=False):
    content = [{"type": "text", "text": text}]
    if image:
        content.append({"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": img}})
    return {"type": "user", "timestamp": iso(ago), "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": tool_id, "content": content, "is_error": error}]}}


session("ask-demo", "选择登录方案", REPO, "waiting", [
    user("登录这块你看怎么做比较好？", 300),
    assistant([{"type": "thinking", "thinking": "有几个可选方案，让用户来定。"}], 290),
    assistant([{"type": "text", "text": "登录有几种做法，先确认一下你的偏好："}], 288),
    assistant([{"type": "tool_use", "id": "toolu_ask1", "name": "AskUserQuestion", "input": {"questions": [
        {"header": "登录方式", "question": "用哪种登录方式？", "multiSelect": False, "options": [
            {"label": "手机验证码", "description": "最常见，需要短信服务"},
            {"label": "微信一键登录", "description": "需要开放平台资质"},
            {"label": "账号密码", "description": "最简单"}]},
        {"header": "附加功能", "question": "还需要哪些功能？", "multiSelect": True, "options": [
            {"label": "记住登录"}, {"label": "找回密码"}, {"label": "登录日志"}]}]}}], 285),
], waiting_for="dialog open")

session("perm-demo", "清理构建目录", REPO, "waiting", [
    user("构建老是失败，帮我清一下重新构建", 200),
    assistant([{"type": "thinking", "thinking": "先删掉 build 目录再重新构建。这个命令有删除操作，需要用户同意。"}], 195),
    assistant([{"type": "tool_use", "id": "toolu_bash1", "name": "Bash", "input": {
        "command": "rm -rf build && npm run build", "description": "清理并重新构建"}}], 190),
], waiting_for="permission")

# 会话之间的消息（SendMessage）：「首页卡片间距」发给「订单导出功能」，两边记录里同一个 msg_id
PEER_MSG = "5e2d0c1a-7b3f-4a51-9c2e-1f0d6a8b4c77"
PEER_BODY = "首页卡片间距已改为 16px，变量名 --card-gap，圆角 --card-radius: 12px。订单导出页复用卡片组件时直接用这两个变量。"

busy_rows = [
    user("首页的卡片间距不对，你看下截图", 600, images=True),
    assistant([{"type": "thinking", "thinking": "截图里卡片之间的间距是 4px，应该是 16px。先列个计划。"}], 590),
    assistant([{"type": "tool_use", "id": "toolu_todo1", "name": "TodoWrite", "input": {"todos": [
        {"content": "定位首页卡片样式", "status": "completed", "activeForm": "定位首页卡片样式"},
        {"content": "修改卡片间距为 16px", "status": "completed", "activeForm": "修改卡片间距"},
        {"content": "截图验证效果", "status": "in_progress", "activeForm": "正在截图验证效果"},
        {"content": "跑一遍单元测试", "status": "pending", "activeForm": "跑单元测试"}]}}], 585),
    result("toolu_todo1", "Todos have been modified successfully", 584),
    assistant([{"type": "tool_use", "id": "toolu_grep1", "name": "Grep", "input": {"pattern": "card-gap", "path": "src/styles"}}], 580),
    result("toolu_grep1", "src/styles/home.css:42:  --card-gap: 4px;", 579),
    assistant([{"type": "tool_use", "id": "toolu_edit1", "name": "Edit", "input": {
        "file_path": "/Users/demo/projects/shop-app/src/styles/home.css",
        "old_string": "  --card-gap: 4px;", "new_string": "  --card-gap: 16px;\n  --card-radius: 12px;"}}], 570),
    result("toolu_edit1", "The file has been updated.", 569),
    assistant([{"type": "tool_use", "id": "toolu_read1", "name": "Read", "input": {"file_path": "/tmp/home-after.png"}}], 560),
    result("toolu_read1", "", 559, image=True),
    assistant([{"type": "text", "text": "间距已经改好了，对比如下：\n\n| 项目 | 改之前 | 改之后 |\n|---|---|---|\n| 卡片间距 | 4px | **16px** |\n| 圆角 | 8px | 12px |\n\n改动在 `src/styles/home.css`：\n\n```css\n.home {\n  --card-gap: 16px;\n  --card-radius: 12px;\n}\n```\n\n接下来跑一遍测试确认没有破坏别的页面。"}], 550),
    assistant([{"type": "tool_use", "id": "toolu_test1", "name": "Bash", "input": {"command": "npx vitest run", "description": "跑一遍单元测试"}}], 300),
    result("toolu_test1", " ✓ src/card.test.js (3 tests)\n ✗ src/home.test.js > 卡片间距\n   expected 16px, received 4px\n\n Test Files  1 failed | 1 passed (2)\n      Tests  1 failed | 11 passed (12)", 290, error=True),
    assistant([{"type": "tool_use", "id": "toolu_peer1", "name": "SendMessage", "input": {
        "to": "plan-demo", "summary": "告知卡片间距的最终取值", "message": PEER_BODY}}], 240),
    result("toolu_peer1", json.dumps({"success": True, "message": "已送达", "msg_id": PEER_MSG}), 239),
    assistant([{"type": "tool_use", "id": "toolu_test2", "name": "Bash", "input": {"command": "npx vitest run", "description": "修完再跑一遍"}}], 200),
    result("toolu_test2", " ✓ src/card.test.js (3 tests)\n ✓ src/home.test.js (9 tests)\n\n Test Files  2 passed (2)\n      Tests  12 passed (12)", 190),
    assistant([{"type": "tool_use", "id": "toolu_bash2", "name": "Bash", "input": {"command": "npm test -- --watch=false", "description": "运行单元测试"}}], 30),
]
busy_sid = session("busy-demo", "首页卡片间距", REPO, "busy", busy_rows)
# 智能体主动发的图（outbox）
shot = os.path.join(DATA, "outbox", "files", "demo-shot.png")
with open(shot, "wb") as handle:
    handle.write(base64.b64decode(img))
with open(os.path.join(DATA, "outbox", busy_sid + ".jsonl"), "w") as handle:
    handle.write(json.dumps({"ts": int((now - 545) * 1000), "caption": "改完后的首页效果（iPhone 15 尺寸）",
                             "files": [{"path": shot, "mime": "image/png", "name": "home.png"}]}, ensure_ascii=False) + "\n")

session("plan-demo", "订单导出功能", "/Users/demo/projects/admin", "waiting", [
    user("加一个订单导出 Excel 的功能，先出个方案", 900),
    assistant([{"type": "tool_use", "id": "toolu_plan1", "name": "ExitPlanMode", "input": {"plan":
        "## 订单导出方案\n\n1. 后端新增 `GET /api/orders/export`，按筛选条件流式生成 xlsx\n2. 前端订单列表加「导出」按钮，复用当前筛选\n3. 超过 5 万行时改为异步任务，完成后站内通知\n\n预计改动 6 个文件。"}}], 880),
    # 等你批准计划的时候收到另一个会话发来的消息：插进来的（attachment），origin 带着 msg_id
    {"type": "attachment", "timestamp": iso(238), "attachment": {"type": "queued_command", "origin": {
        "kind": "peer", "from": "uds:/tmp/kiteline-fixture.sock", "name": "busy-demo", "msg_id": PEER_MSG, "body": PEER_BODY},
        "prompt": "<cross-session-message from=\"uds:/tmp/kiteline-fixture.sock\" from-name=\"busy-demo\">\n" + PEER_BODY + "\n</cross-session-message>"}},
], waiting_for="dialog open")

# 用量到上限停下的会话（Claude Code 写一条 isApiErrorMessage 的假回复）：30 小时前，不算进今天的动态
if not DEMO:
  session("limit-demo", "周报生成", "/Users/demo/projects/weekly", "idle", [
      user("把这周的周报整理一下", 30 * 3600),
      {"type": "assistant", "uuid": "err-limit-1", "isApiErrorMessage": True, "timestamp": iso(30 * 3600 - 20), "message": {
          "role": "assistant", "model": "<synthetic>", "id": "synthetic-1",
          "content": [{"type": "text", "text": "You've hit your session limit · resets 9:10am (America/New_York)"}]}},
  ])

# 已经结束的会话：只有对话记录、没有注册表项（三天前），用来测历史浏览 / 搜索 / 恢复
ENDED_SID = "eeeeeeee-1111-2222-3333-444444444444"
ended_path = os.path.join(PROJ, escape(REPO), ENDED_SID + ".jsonl")
os.makedirs(os.path.dirname(ended_path), exist_ok=True)
with open(ended_path, "w") as handle:
    reply = assistant([{"type": "text", "text": "登录页按钮已经改成 44px 高，点击区域也加大了。改动在 `src/pages/login.vue`。"}], 3 * 86400 - 60)
    u = reply["message"]["usage"]
    for row in [
        user("登录页的按钮太小了，改大一点", 3 * 86400),
        reply,
        {"type": "ai-title", "aiTitle": "登录页按钮改版", "sessionId": ENDED_SID},
        # Claude Code 结束会话时写的累计花费：给用量报表提供费率（这一条请求花了 $1）
        {"type": "cost-state", "sessionId": ENDED_SID, "totalCostUSD": 1.0, "modelUsage": {"claude-opus-5-5": {
            "inputTokens": u["input_tokens"], "outputTokens": u["output_tokens"], "cacheReadInputTokens": u["cache_read_input_tokens"],
            "cacheCreationInputTokens": u["cache_creation_input_tokens"], "costUSD": 1.0}}},
    ]:
        handle.write(json.dumps(dict(row, cwd=REPO), ensure_ascii=False) + "\n")
os.utime(ended_path, (now - 3 * 86400, now - 3 * 86400))


def past(sid, title, cwd, days, prompt, answer, cost, output):
    """演示用：几天前已经结束的会话（只有对话记录 + 结束时写的花费）"""
    path = os.path.join(PROJ, escape(cwd), sid + ".jsonl")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    ago = days * 86400 + 3600 * (2 + days % 5)
    tokens = {"inputTokens": 40, "outputTokens": output, "cacheReadInputTokens": output * 40, "cacheCreationInputTokens": output * 2}
    usage = {"input_tokens": 40, "output_tokens": output, "cache_read_input_tokens": output * 40, "cache_creation_input_tokens": output * 2}
    rows = [
        user(prompt, ago),
        {"type": "assistant", "timestamp": iso(ago - 600), "message": {"role": "assistant", "model": "claude-opus-5-5",
         "id": "msg_" + sid[:8], "usage": usage, "content": [{"type": "text", "text": answer}]}},
        {"type": "ai-title", "aiTitle": title, "sessionId": sid},
        {"type": "cost-state", "sessionId": sid, "totalCostUSD": cost, "modelUsage": {"claude-opus-5-5": dict(tokens, costUSD=cost)}},
    ]
    with open(path, "w") as handle:
        for row in rows:
            handle.write(json.dumps(dict(row, cwd=cwd), ensure_ascii=False) + "\n")
    os.utime(path, (now - ago + 600, now - ago + 600))


if DEMO:
    ADMIN = "/Users/demo/projects/admin"
    for sid, title, cwd, days, prompt, answer, cost, output in [
        ("d1000000-0000-4000-8000-000000000001", "购物车结算页重构", REPO, 1, "结算页的代码太乱了，拆成几个组件，逻辑别变",
         "结算页拆成了 4 个组件（地址、商品清单、优惠、支付栏），原有 23 个测试全部通过。", 3.2, 21000),
        ("d1000000-0000-4000-8000-000000000002", "图片懒加载闪烁", REPO, 2, "首页往下滑的时候图片会闪一下，查一下",
         "原因是占位图和真图尺寸不一致导致重排。给图片容器加了固定宽高比，滑动时不再闪。", 1.6, 9000),
        ("d1000000-0000-4000-8000-000000000003", "订单列表分页接口", ADMIN, 4, "订单列表改成后端分页，每页 50 条",
         "后端加了游标分页（`cursor` + `limit`），前端改成滚动加载，10 万条订单首屏从 3.2 秒降到 0.4 秒。", 2.4, 15000),
        ("d1000000-0000-4000-8000-000000000004", "补齐首页单元测试", REPO, 5, "首页组件的测试覆盖率太低了，补一下",
         "补了 18 个测试，首页组件覆盖率从 41% 提到 87%。", 1.1, 7000),
        ("d1000000-0000-4000-8000-000000000005", "暗色模式适配", REPO, 6, "整站适配一下暗色模式",
         "颜色都换成了 CSS 变量，加了跟随系统的暗色主题；对比度都检查过，符合 WCAG AA。", 2.8, 18000),
    ]:
        past(sid, title, cwd, days, prompt, answer, cost, output)

# 订阅额度：Claude Code 的额度插件写下的读数（测试脚本把 CLAUDE_CONFIG_DIR 指到 <夹具>/claude，别读真实的 ~/.claude）
os.makedirs(os.path.join(ROOT, "claude", "kiteline"), exist_ok=True)
with open(os.path.join(ROOT, "claude", "kiteline", "limits.json"), "w") as handle:
    json.dump({"at": int(now * 1000) - 60000, "sessionId": "fixture", "limits": [
        {"kind": "five_hour", "percentUsed": 42, "resetsAt": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(now + 7200))},
        {"kind": "seven_day", "percentUsed": 68, "resetsAt": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(now + 4 * 86400))}]}, handle)

print("fixture ready in", ROOT)
