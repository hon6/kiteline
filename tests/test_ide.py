"""代码 IDE 后端（watcher/kiteline-watch.py 的 fs / repo 请求）的测试：全在临时目录里建仓库、远端和废纸篓，不碰真实数据。

覆盖：
  - 文件：保存（冲突检测、保留 CRLF 和 BOM）、新建、改名（含只改大小写）、移动、复制（重名加 copy）、删除进废纸篓、上传、越界拒绝
  - 读文件：编辑模式的 sha / 换行 / BOM / 非 UTF-8 标记
  - Git：概览（暂存 / 工作区 / 未跟踪 / 冲突分开、分支、远端、标签、贮藏、工作树、会话在哪个分支）、暂存与区块暂存、丢弃、
    提交与修改提交、提交图连线、提交详情、并排对比的两边内容、推送 / 获取 / 拉取 / 被拒、分支增删改与检出远端分支、
    合并冲突与放弃、变基、拣选、还原、重置、贮藏、标签、工作树
  - 后台线程回复：defer 立即返回、结果随后按 id 发出，Git 报错带 detail

用法：python3 tests/test_ide.py
"""
import base64
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
WATCHER = os.path.join(HERE, "..", "watcher", "kiteline-watch.py")
spec = importlib.util.spec_from_file_location("watcher", WATCHER)
W = importlib.util.module_from_spec(spec)
spec.loader.exec_module(W)

PASS, FAIL = [0], []


def check(name, cond, detail=""):
    if cond:
        PASS[0] += 1
    else:
        FAIL.append(name)
        print("✗ %s %s" % (name, detail))


def raises(fn, *args, contains=""):
    try:
        fn(*args)
    except Exception as exc:  # noqa
        return contains in str(exc)
    return False


def git(cwd, *args):
    return subprocess.run(["git", "-C", cwd] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
                          env=dict(os.environ, GIT_AUTHOR_DATE="", GIT_COMMITTER_DATE="")).stdout.decode().strip()


def write(path, text, mode="w"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # newline=""：Windows 上也原样写 \n（不自动换成 \r\n），和 Mac / Linux 结果一致
    with open(path, mode, **({} if "b" in mode else {"newline": "", "encoding": "utf-8"})) as handle:
        handle.write(text)


def read(path, mode="r"):
    with open(path, mode, **({} if "b" in mode else {"newline": "", "encoding": "utf-8"})) as handle:
        return handle.read()


# Windows 删除进的是系统回收站（SHFileOperation），测试里看不到；那边只核对文件确实没了
SYSTEM_TRASH = os.name == "nt"


TMP = tempfile.mkdtemp(prefix="kl-ide-")
os.environ["XDG_DATA_HOME"] = os.path.join(TMP, "xdg")
os.environ["GIT_CONFIG_GLOBAL"] = os.path.join(TMP, "gitconfig")
os.environ["GIT_CONFIG_NOSYSTEM"] = "1"
write(os.environ["GIT_CONFIG_GLOBAL"], "[init]\n\tdefaultBranch = main\n[core]\n\tautocrlf = false\n")
W.HOME = TMP
os.makedirs(os.path.join(TMP, ".Trash"))


def trashed_names():
    names = os.listdir(os.path.join(TMP, ".Trash"))
    xdg = os.path.join(TMP, "xdg", "Trash", "files")
    if os.path.isdir(xdg):
        names += os.listdir(xdg)
    return names


def test_files():
    root = os.path.join(TMP, "proj")
    os.makedirs(root)
    fs = lambda **req: W.fs_op(root, req)  # noqa: E731

    out = fs(op="create", path="src/app.js", kind="file")
    check("新建文件（自动建上级目录）", out["path"] == "src/app.js" and os.path.isfile(os.path.join(root, "src/app.js")))
    check("新建重名报错", raises(fs, contains="已存在") if False else raises(lambda: fs(op="create", path="src/app.js"), contains="已存在"))
    fs(op="create", path="docs", kind="dir")
    check("新建文件夹", os.path.isdir(os.path.join(root, "docs")))

    meta = W.read_file(root, "src/app.js", edit=True)
    saved = fs(op="write", path="src/app.js", text="let a = 1\n", base=meta["sha"])
    check("保存", read(os.path.join(root, "src/app.js")) == "let a = 1\n" and saved["sha"])
    write(os.path.join(root, "src/app.js"), "changed elsewhere\n")
    conflict = fs(op="write", path="src/app.js", text="mine\n", base=saved["sha"])
    check("别处改过：回 conflict 不写", conflict.get("conflict") and read(os.path.join(root, "src/app.js")) == "changed elsewhere\n")
    fs(op="write", path="src/app.js", text="mine\n", base=saved["sha"], force=True)
    check("强制覆盖", read(os.path.join(root, "src/app.js")) == "mine\n")

    write(os.path.join(root, "win.txt"), b"a\r\nb\r\n", "wb")
    meta = W.read_file(root, "win.txt", edit=True)
    check("读出 CRLF", meta["eol"] == "crlf" and meta["text"] == "a\r\nb\r\n")
    fs(op="write", path="win.txt", text="a\nb\nc\n", base=meta["sha"])
    check("保存时保留 CRLF", read(os.path.join(root, "win.txt"), "rb") == b"a\r\nb\r\nc\r\n")
    write(os.path.join(root, "bom.txt"), b"\xef\xbb\xbfhi\n", "wb")
    meta = W.read_file(root, "bom.txt", edit=True)
    check("BOM 不进编辑器", meta.get("bom") and meta["text"] == "hi\n")
    fs(op="write", path="bom.txt", text="hey\n", base=meta["sha"])
    check("保存时保留 BOM", read(os.path.join(root, "bom.txt"), "rb") == b"\xef\xbb\xbfhey\n")
    write(os.path.join(root, "gbk.txt"), "中文".encode("gbk"), "wb")
    check("非 UTF-8 标记 lossy", W.read_file(root, "gbk.txt", edit=True).get("lossy"))

    fs(op="rename", path="win.txt", name="dos.txt")
    check("改名", os.path.exists(os.path.join(root, "dos.txt")) and not os.path.exists(os.path.join(root, "win.txt")))
    fs(op="rename", path="dos.txt", name="DOS.txt")
    check("只改大小写", "DOS.txt" in os.listdir(root))
    check("改名重名报错", raises(lambda: fs(op="rename", path="bom.txt", name="DOS.txt"), contains="已存在"))
    check("名称带斜杠拒绝", raises(lambda: fs(op="rename", path="bom.txt", name="a/b"), contains="名称不合法"))

    fs(op="move", paths=["bom.txt", "DOS.txt"], dest="docs")
    check("移动", os.path.exists(os.path.join(root, "docs/bom.txt")) and os.path.exists(os.path.join(root, "docs/DOS.txt")))
    check("文件夹移进自己拒绝", raises(lambda: fs(op="move", paths=["docs"], dest="docs"), contains=""))
    out = fs(op="copy", paths=["src/app.js"], dest="src")
    out2 = fs(op="copy", paths=["src/app.js"], dest="src")
    check("复制重名加 copy", out["paths"] == ["src/app copy.js"] and out2["paths"] == ["src/app copy 2.js"])
    out = fs(op="copy", paths=["docs"], dest="")
    check("复制文件夹", out["paths"] == ["docs copy"] and os.path.exists(os.path.join(root, "docs copy/bom.txt")))

    before = set(trashed_names())
    out = fs(op="delete", paths=["docs copy", "src/app copy 2.js"])
    added = set(trashed_names()) - before
    check("删除进废纸篓", out["trashed"] == ["docs copy", "src/app copy 2.js"] and (SYSTEM_TRASH or len(added) == 2)
          and not os.path.exists(os.path.join(root, "docs copy")), str(added))
    fs(op="create", path="t/x.txt")
    fs(op="delete", paths=["t/x.txt"])
    fs(op="create", path="t/x.txt")
    fs(op="delete", paths=["t/x.txt"])
    check("同名文件再删也进废纸篓（不覆盖上一个）", SYSTEM_TRASH or len(set(trashed_names()) - before) == 4)

    out = fs(op="upload", dest="docs", name="pic.png", data=base64.b64encode(b"PNG").decode())
    out2 = fs(op="upload", dest="docs", name="pic.png", data=base64.b64encode(b"PNG2").decode())
    check("上传、重名不覆盖", out["path"] == "docs/pic.png" and out2["path"] == "docs/pic copy.png")

    check("越界拒绝", raises(lambda: fs(op="write", path="../evil.txt", text="x"), contains="只能"))
    check("根目录拒绝删除", raises(lambda: fs(op="delete", paths=[""]), contains=""))
    os.makedirs(os.path.join(root, ".git"))
    check(".git 拒绝", raises(lambda: fs(op="create", path=".git/hooks/x"), contains=".git"))
    os.symlink(TMP, os.path.join(root, "outside"))
    check("符号链接跑出去拒绝", raises(lambda: fs(op="write", path="outside/evil.txt", text="x"), contains="只能"))


def repo(cwd, **req):
    return W.repo_request(cwd, req, req.pop("sessions", []))


def test_git():
    origin = os.path.join(TMP, "origin.git")
    subprocess.run(["git", "init", "-q", "--bare", origin], check=True)
    root = os.path.join(TMP, "repo")
    os.makedirs(root)
    check("不是仓库：概览给 reason", repo(root, op="overview").get("repo") is None)
    repo(root, op="init")
    git(root, "config", "user.name", "Tester")
    git(root, "config", "user.email", "t@example.com")
    git(root, "remote", "add", "origin", "https://user:secret@example.com/x.git")
    git(root, "remote", "set-url", "origin", origin)
    write(os.path.join(root, "a.txt"), "".join("line %d\n" % i for i in range(1, 41)))
    write(os.path.join(root, "b.txt"), "b\n")
    out = repo(root, op="overview")
    check("空仓库概览", out["repo"] and out["branch"] == "main" and out["oid"] is None and len(out["untracked"]) == 2, str(out.get("branch")))
    repo(root, op="stage_all")
    repo(root, op="commit", message="初始提交")
    out = repo(root, op="push")
    check("首次推送自动关联远端", repo(root, op="overview")["upstream"] == "origin/main", out.get("output"))

    # 两处改动：只暂存第一个区块
    lines = read(os.path.join(root, "a.txt")).split("\n")
    lines[1] = "line 2 changed"
    lines[35] = "line 36 changed"
    write(os.path.join(root, "a.txt"), "\n".join(lines))
    diff = repo(root, op="diff", path="a.txt")
    check("工作区 diff 两个区块 + 两边内容", len(diff["hunks"]) == 2 and "line 2 changed" in diff["modified"] and "line 2\n" in diff["original"])
    repo(root, op="stage_hunk", path="a.txt", hunk=0, header=diff["hunks"][0])
    status = repo(root, op="status")
    staged = repo(root, op="diff", path="a.txt", mode="staged")
    check("区块暂存", [f["path"] for f in status["staged"]] == ["a.txt"] and [f["path"] for f in status["unstaged"]] == ["a.txt"]
          and len(staged["hunks"]) == 1 and "line 2 changed" in staged["diff"])
    check("区块头对不上拒绝", raises(lambda: repo(root, op="stage_hunk", path="a.txt", hunk=0, header="@@ -1 +1 @@"), contains="刷新"))
    repo(root, op="unstage_hunk", path="a.txt", hunk=0, header=staged["hunks"][0])
    check("区块取消暂存", not repo(root, op="status")["staged"])
    diff = repo(root, op="diff", path="a.txt")
    repo(root, op="discard_hunk", path="a.txt", hunk=1, header=diff["hunks"][1])
    check("区块丢弃", "line 36 changed" not in read(os.path.join(root, "a.txt")) and "line 2 changed" in read(os.path.join(root, "a.txt")))

    write(os.path.join(root, "new.txt"), "new\n")
    status = repo(root, op="status")
    check("状态分开列", [f["path"] for f in status["unstaged"]] == ["a.txt"] and [f["path"] for f in status["untracked"]] == ["new.txt"]
          and status["unstaged"][0].get("add") == 1)
    repo(root, op="discard", paths=["new.txt"])
    check("丢弃未跟踪的文件进废纸篓", not os.path.exists(os.path.join(root, "new.txt")) and (SYSTEM_TRASH or "new.txt" in trashed_names()))
    repo(root, op="stage", paths=["a.txt"])
    check("没写提交信息拒绝", raises(lambda: repo(root, op="commit", message=" "), contains="提交信息"))
    first = repo(root, op="commit", message="改第二行")["hash"]
    repo(root, op="commit", message="改第二行（修订）", amend=True)
    check("修改上一次提交", git(root, "log", "-1", "--format=%s") == "改第二行（修订）" and git(root, "rev-list", "--count", "HEAD") == "2")
    check("没有改动时提交报错", raises(lambda: repo(root, op="commit", message="x", all=True), contains=""))

    # 分支 + 合并：提交图要有汇合的线
    repo(root, op="branch_create", name="feature/login")
    write(os.path.join(root, "login.txt"), "login\n")
    repo(root, op="commit", message="登录页", all=True)
    repo(root, op="checkout", ref="main")
    write(os.path.join(root, "b.txt"), "b2\n")
    repo(root, op="commit", message="改 b", all=True)
    out = repo(root, op="merge", ref="feature/login", noff=True)
    check("合并", not out.get("conflict") and os.path.exists(os.path.join(root, "login.txt")))
    log = repo(root, op="log")
    merge = log["commits"][0]
    check("提交图：合并提交两个父亲、有分叉线", len(merge["parents"]) == 2 and log["width"] >= 2
          and any(seg[0] != seg[2] for seg in merge["graph"]["segs"]), json.dumps(merge["graph"]))
    check("提交图：引用标签", any(r["name"] == "main" and r.get("current") for r in merge["refs"])
          and any(r["type"] == "branch" and r["name"] == "feature/login" for c in log["commits"] for r in c["refs"]))
    rows_with_two_lanes = [c for c in log["commits"] if len({s[0] for s in c["graph"]["segs"]} | {s[2] for s in c["graph"]["segs"]}) >= 2]
    check("提交图：并行的两条线", len(rows_with_two_lanes) >= 2)
    check("翻页", len(repo(root, op="log", limit=2)["commits"]) == 2 and repo(root, op="log", limit=2)["more"])
    check("按文件看历史", [c["subject"] for c in repo(root, op="log", path="b.txt")["commits"]] == ["改 b", "初始提交"])
    check("搜索提交", [c["subject"] for c in repo(root, op="log", q="登录")["commits"]] == ["登录页"])
    info = repo(root, op="commit_info", commit=merge["hash"])
    check("提交详情（对第一个父亲）", [f["path"] for f in info["files"]] == ["login.txt"] and info["files"][0]["add"] == 1
          and "main" in info["branches"])
    root_commit = log["commits"][-1]["hash"]
    info = repo(root, op="commit_info", commit=root_commit)
    check("第一个提交的详情", sorted(f["path"] for f in info["files"]) == ["a.txt", "b.txt"])
    diff = repo(root, op="diff", path="b.txt", mode="commit", commit=git(root, "log", "-1", "--format=%H", "--", "b.txt"))
    check("提交里一个文件的两边", diff["original"] == "b\n" and diff["modified"] == "b2\n")
    check("非法提交号拒绝", raises(lambda: repo(root, op="commit_info", commit="--output=/tmp/x"), contains="不合法"))

    # 冲突与放弃
    repo(root, op="branch_create", name="conflict")
    write(os.path.join(root, "b.txt"), "theirs\n")
    repo(root, op="commit", message="theirs", all=True)
    repo(root, op="checkout", ref="main")
    write(os.path.join(root, "b.txt"), "ours\n")
    repo(root, op="commit", message="ours", all=True)
    out = repo(root, op="merge", ref="conflict")
    status = repo(root, op="status")
    check("合并冲突", out.get("conflict") and status["state"] == "merge" and [c["path"] for c in status["conflicts"]] == ["b.txt"]
          and status.get("mergeMessage"), str(out))
    repo(root, op="abort")
    check("放弃合并", repo(root, op="status")["state"] is None and read(os.path.join(root, "b.txt")) == "ours\n")
    repo(root, op="merge", ref="conflict")
    repo(root, op="resolve", path="b.txt", side="theirs")
    repo(root, op="continue")
    check("用对方版本解决后继续", read(os.path.join(root, "b.txt")) == "theirs\n" and repo(root, op="status")["state"] is None
          and len(git(root, "log", "-1", "--format=%P").split()) == 2)

    # 变基、拣选、还原、重置
    repo(root, op="branch_create", name="topic")
    write(os.path.join(root, "t.txt"), "t\n")
    repo(root, op="commit", message="topic 1", all=True)
    repo(root, op="checkout", ref="main")
    write(os.path.join(root, "m.txt"), "m\n")
    repo(root, op="commit", message="main 1", all=True)
    repo(root, op="checkout", ref="topic")
    repo(root, op="rebase", ref="main")
    check("变基", git(root, "log", "-2", "--format=%s") == "topic 1\nmain 1")
    topic_head = git(root, "rev-parse", "HEAD")
    repo(root, op="checkout", ref="main")
    repo(root, op="cherry_pick", ref=topic_head)
    check("拣选", os.path.exists(os.path.join(root, "t.txt")) and git(root, "log", "-1", "--format=%s") == "topic 1")
    repo(root, op="revert", ref="HEAD")
    check("还原", not os.path.exists(os.path.join(root, "t.txt")))
    repo(root, op="reset", ref="HEAD~1", mode="hard")
    check("重置（hard）", os.path.exists(os.path.join(root, "t.txt")))
    repo(root, op="reset", ref="HEAD~1", mode="soft")
    check("重置（soft）留在暂存区", [f["path"] for f in repo(root, op="status")["staged"]] == ["t.txt"])
    repo(root, op="commit", message="topic 1 again")

    # 贮藏
    write(os.path.join(root, "m.txt"), "m2\n")
    write(os.path.join(root, "u.txt"), "u\n")
    repo(root, op="stash_save", message="半成品", untracked=True)
    over = repo(root, op="overview")
    check("贮藏（含未跟踪）", not over["unstaged"] and not over["untracked"] and over["stashes"][0]["title"].endswith("半成品"))
    check("没东西可贮藏", raises(lambda: repo(root, op="stash_save"), contains="没有可以贮藏"))
    repo(root, op="stash_apply", ref="stash@{0}")
    check("应用贮藏", read(os.path.join(root, "m.txt")) == "m2\n" and len(repo(root, op="overview")["stashes"]) == 1)
    repo(root, op="stash_drop", ref="stash@{0}")
    check("删除贮藏", not repo(root, op="overview")["stashes"])
    check("非法贮藏拒绝", raises(lambda: repo(root, op="stash_pop", ref="; rm -rf /"), contains="贮藏不存在"))
    repo(root, op="commit", message="m2", all=True)

    # 标签、分支增删改
    repo(root, op="tag_create", name="v1.0", message="第一版")
    repo(root, op="tag_create", name="light")
    over = repo(root, op="overview")
    check("标签", {t["name"] for t in over["tags"]} == {"v1.0", "light"})
    repo(root, op="tag_delete", name="light")
    repo(root, op="branch_rename", name="topic", to="topic2")
    check("分支改名", any(b["name"] == "topic2" for b in repo(root, op="overview")["branches"]))
    repo(root, op="branch_create", name="unmerged", checkout=False)
    repo(root, op="checkout", ref="unmerged")
    write(os.path.join(root, "x.txt"), "x\n")
    repo(root, op="commit", message="x", all=True)
    repo(root, op="checkout", ref="main")
    try:
        repo(root, op="branch_delete", name="unmerged")
        check("未合并的分支不让删", False)
    except W.GitFailed as exc:
        check("未合并的分支不让删（说人话）", "未合并" in str(exc), str(exc))
    repo(root, op="branch_delete", name="unmerged", force=True)
    check("强制删除分支", not any(b["name"] == "unmerged" for b in repo(root, op="overview")["branches"]))
    check("分支名以 - 开头拒绝", raises(lambda: repo(root, op="branch_create", name="-x"), contains="不合法"))

    # 推送 / 远端分支 / 获取 / 拉取 / 被拒
    repo(root, op="push", tags=True)
    repo(root, op="checkout", ref="feature/login")
    repo(root, op="push")
    repo(root, op="checkout", ref="main")
    other = os.path.join(TMP, "other")
    subprocess.run(["git", "clone", "-q", origin, other], check=True)
    git(other, "config", "user.name", "Other")
    git(other, "config", "user.email", "o@example.com")
    over = repo(other, op="overview")
    check("远端分支、远端地址", any(b["name"] == "origin/feature/login" and b["branch"] == "feature/login" for b in over["remoteBranches"])
          and over["remotes"][0]["name"] == "origin")
    repo(other, op="checkout", ref="origin/feature/login", remote=True)
    over = repo(other, op="overview")
    check("检出远端分支：建本地跟踪分支", over["branch"] == "feature/login" and over["upstream"] == "origin/feature/login")
    repo(other, op="checkout", ref="main")
    write(os.path.join(other, "from-other.txt"), "o\n")
    repo(other, op="commit", message="来自另一处", all=True)
    repo(other, op="push")
    write(os.path.join(root, "local.txt"), "l\n")
    repo(root, op="commit", message="本地新提交", all=True)
    try:
        repo(root, op="push")
        check("推送被拒", False)
    except W.GitFailed as exc:
        check("推送被拒（说人话、带原话）", "请先拉取" in str(exc) and "rejected" in exc.output, str(exc))
    repo(root, op="fetch")
    over = repo(root, op="overview")
    check("获取后看到分叉", over["ahead"] == 1 and over["behind"] == 1)
    repo(root, op="pull", rebase=True)
    check("拉取（变基）", os.path.exists(os.path.join(root, "from-other.txt")) and repo(root, op="overview")["behind"] == 0)
    repo(root, op="push")
    repo(other, op="pull")
    check("拉取（合并，默认）", os.path.exists(os.path.join(other, "local.txt")))
    repo(root, op="remote_branch_delete", remote="origin", branch="feature/login")
    repo(other, op="fetch")
    check("删除远端分支 + 获取时清理", not any(b["name"] == "origin/feature/login" for b in repo(other, op="overview")["remoteBranches"]))
    git(root, "remote", "add", "bad", "https://user:secret@127.0.0.1:9/x.git")
    check("远端地址去掉账号密码", all("secret" not in r["url"] for r in repo(root, op="overview")["remotes"]))

    # 工作树 + 会话在哪个分支
    out = repo(root, op="worktree_add", branch="tars/demo")
    tree = out["path"]
    os.makedirs(os.path.join(tree, "sub"))
    W._HEAD_CACHE.clear()
    sessions = [{"sessionId": "s-main", "cwd": root}, {"sessionId": "s-tree", "cwd": os.path.join(tree, "sub")},
                {"sessionId": "s-else", "cwd": other}]
    over = repo(root, op="overview", sessions=sessions)
    mapped = {s["sessionId"]: s for s in over["sessions"]}
    check("会话归到工作树和分支", set(mapped) == {"s-main", "s-tree"} and mapped["s-main"]["branch"] == "main"
          and mapped["s-tree"]["branch"] == "tars/demo" and os.path.realpath(mapped["s-tree"]["worktree"]) == os.path.realpath(tree),
          json.dumps(over["sessions"]))
    check("工作树列表", len(over["worktrees"]) == 2 and over["worktrees"][0].get("main")
          and any(t["branch"] == "tars/demo" for t in over["worktrees"]))
    check("分支在别的工作树里检出", any(b["name"] == "tars/demo" and b["worktree"] for b in over["branches"]))
    try:
        repo(root, op="checkout", ref="tars/demo")
        check("检出别处已检出的分支", False)
    except W.GitFailed as exc:
        check("检出别处已检出的分支（说明在哪）", "另一个工作树" in str(exc), str(exc))
    snaps = [{"cwd": os.path.join(tree, "sub")}, {"cwd": root}, {"cwd": TMP}]
    W.annotate_branches(snaps)
    check("快照带分支", snaps[0].get("branch") == "tars/demo" and snaps[0].get("worktree") and snaps[1].get("branch") == "main"
          and "worktree" not in snaps[1] and "branch" not in snaps[2])
    check("主工作树不能移除", raises(lambda: repo(root, op="worktree_remove", path=root), contains="附加"))
    repo(root, op="worktree_remove", path=tree)
    check("移除工作树", not os.path.exists(tree))
    repo(root, op="checkout", ref=git(root, "rev-parse", "HEAD~1"), detach=True)
    W._HEAD_CACHE.clear()
    snaps = [{"cwd": root}]
    W.annotate_branches(snaps)
    check("游离 HEAD", snaps[0]["branch"].startswith("(") and repo(root, op="overview")["branch"] is None)
    try:
        repo(root, op="push")
        check("游离 HEAD 推送", False)
    except Exception as exc:  # noqa
        check("游离 HEAD 推送（说明原因）", "游离" in str(exc) or "HEAD" in str(exc), str(exc))
    repo(root, op="checkout", ref="main")


def test_defer():
    """watcher 收到 fs / repo 请求：立即返回 DEFERRED，结果在后台线程按 id 发出"""
    root = os.path.join(TMP, "repo")
    sent = []
    done = threading.Event()
    original = W.emit

    def capture(obj):
        sent.append(obj)
        done.set()

    W.emit = capture
    try:
        watcher = W.Watcher()
        result = watcher.handle({"cmd": "repo", "op": "overview", "cwd": root, "id": "r1"})
        check("defer 立即返回", result is W.DEFERRED)
        done.wait(20)
        check("后台回复按 id", sent and sent[0]["id"] == "r1" and sent[0]["ok"] and sent[0]["branch"] == "main")
        done.clear()
        watcher.handle({"cmd": "repo", "op": "branch_delete", "name": "no-such-branch", "cwd": root, "id": "r2"})
        done.wait(20)
        check("Git 报错：ok 仍为真、failed + detail", sent[-1]["id"] == "r2" and sent[-1]["ok"] and sent[-1].get("failed")
              and sent[-1].get("detail"), json.dumps(sent[-1], ensure_ascii=False))
        done.clear()
        watcher.handle({"cmd": "fs", "op": "rename", "path": "nope", "name": "x", "root": root, "id": "r3"})
        done.wait(20)
        check("文件操作报错：ok 为假", sent[-1]["id"] == "r3" and not sent[-1]["ok"] and "不存在" in sent[-1]["error"])
        job = watcher.handle({"cmd": "repo", "op": "tag_create", "name": "job-tag", "job": True, "cwd": root, "id": "r5"})
        check("慢操作先回任务号", job.get("job", "").startswith("j-"))
        for _ in range(100):
            state = watcher.handle({"cmd": "repo", "op": "job", "job": job["job"], "id": "r6"})
            if state.get("done"):
                break
            time.sleep(0.1)
        check("任务做完给结果", state.get("done") and not state.get("failed") and "job-tag" in git(root, "tag"), json.dumps(state, ensure_ascii=False))
        job = watcher.handle({"cmd": "repo", "op": "branch_delete", "name": "nope", "job": True, "cwd": root, "id": "r7"})
        for _ in range(100):
            state = watcher.handle({"cmd": "repo", "op": "job", "job": job["job"], "id": "r8"})
            if state.get("done"):
                break
            time.sleep(0.1)
        check("任务失败带原因和 detail", state.get("failed") and state.get("error") and state.get("detail"))
        check("问不存在的任务", raises(lambda: watcher.handle({"cmd": "repo", "op": "job", "job": "j-x", "id": "r9"}), contains="任务不存在"))
        done.clear()
        watcher.handle({"cmd": "repo", "op": "overview", "id": "r4"})
        done.wait(20)
        check("没有工作目录", sent[-1]["id"] == "r4" and not sent[-1]["ok"])
    finally:
        W.emit = original


if __name__ == "__main__":
    try:
        test_files()
        test_git()
        test_defer()
    finally:
        shutil.rmtree(TMP, ignore_errors=True)
    print("通过 %d 项，失败 %d 项" % (PASS[0], len(FAIL)))
    sys.exit(1 if FAIL else 0)
