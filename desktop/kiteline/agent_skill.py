"""给各家编程 agent 装技能：截图（screenshots）、网页测试报告（playwright）、待办与关键信息（todos）（同 Mac 版 Sources/AgentSkill.swift）。

技能正文和装到哪由 watcher 管（watcher/kiteline-watch.py 的 SKILLS_BUILTIN，是一份 JSON 数据，可经插件索引下发新版）：
每台电脑上的 watcher 自己装到这台电脑上各家 agent 的技能目录（Claude Code、Codex、DeepSeek Harness、Qwen Code；
OpenCode 读 Claude 的那份），带版本标记，关掉的按标记删。
这里只把设置里哪几个开着经环境变量 CCPULSE_SKILLS 带给 watcher（本机、Remote-SSH 远端都是）；开关一变，让在线的 watcher 当场照着装 / 删。
Windows 上技能正文里调 watcher 子命令的写法要用 Kiteline 自己跑（CCPULSE_SELF_COMMAND）：Claude Code 在 Git Bash 里执行，多半没有 python3。
"""

import os
import sys
import threading

from . import config, log

# app 按配置设置（来源对象拿不到完整配置）：mobile.installAgentSkill / installTestSkill / installTodoSkill
ENABLED = True
TEST_ENABLED = True
TODO_ENABLED = True
STAGE_ENABLED = True


def _isolated():
    """测试实例（另指了数据目录、或 dry-run）不动用户的技能目录；测技能本身时用 KITELINE_SKILL_TEST=1 放开"""
    if os.environ.get("KITELINE_SKILL_TEST") == "1":
        return False
    return bool(os.environ.get("KITELINE_CONFIG_DIR")) or os.environ.get("KITELINE_DRY_RUN") == "1" or os.environ.get("CCPULSE_DRY_RUN") == "1"


def skill_ids():
    """开着的技能（id 同 watcher 的技能数据）"""
    return [name for name, on in (("screenshots", ENABLED), ("playwright", TEST_ENABLED), ("todos", TODO_ENABLED),
                                                 ("stages", STAGE_ENABLED)) if on]


def _quote(path):
    """命令里的路径：没有空格就不加引号。Windows 上 Codex、Cursor 在 PowerShell 里跑技能命令，带引号的程序路径在 PowerShell 里
    只是个字符串（要前面加 & 才执行，Git Bash 又不认 &），不带引号 PowerShell、cmd、Git Bash 都认；有空格先换成 8.3 短路径"""
    if " " in path and config.IS_WINDOWS:
        try:
            import ctypes
            buffer = ctypes.create_unicode_buffer(1024)
            if ctypes.windll.kernel32.GetShortPathNameW(path, buffer, len(buffer)):
                path = buffer.value
        except (AttributeError, OSError):
            pass
    path = path.replace("\\", "/")
    return '"%s"' % path if " " in path else path


def local_command(watcher_path):
    """本机跑 watcher 子命令的写法：Linux 用系统的 python3；Windows 上 Claude Code 在 Git Bash 里执行，
    多半没有 python3，打包版用 Kiteline 自己跑（Kiteline.exe --run-script），源码版用当前的 Python"""
    script = _quote(watcher_path)
    if config.IS_WINDOWS:
        if getattr(sys, "frozen", False):
            return "%s --run-script %s" % (_quote(sys.executable), script)
        # 源码版常用 pythonw.exe 跑（没有控制台）：给 Claude 用同目录的 python.exe，命令的输出才看得到
        exe = sys.executable
        console = os.path.join(os.path.dirname(exe), "python.exe")
        if os.path.basename(exe).lower() == "pythonw.exe" and os.path.exists(console):
            exe = console
        return "%s %s" % (_quote(exe), script)
    return "python3 %s" % script


def local_env(watcher_path):
    """本机 watcher 的环境变量：开着的技能；Windows 另给技能正文里的命令写法。隔离的测试实例不带（watcher 就不装也不删）"""
    if _isolated():
        return {}
    env = {"CCPULSE_SKILLS": ",".join(skill_ids())}
    if config.IS_WINDOWS:
        env["CCPULSE_SELF_COMMAND"] = local_command(watcher_path)
    return env


def remote_env(python):
    """Remote-SSH 远端 watcher 的环境变量（拼在远端命令前面，值里没有空格）：开着的技能；远端不是 python3 时告诉它"""
    if _isolated():
        return {}
    env = {"CCPULSE_SKILLS": ",".join(skill_ids()) or "''"}
    if python and python != "python3" and " " not in python:
        env["CCPULSE_PYTHON"] = python
    return env


def sync_live(sources):
    """设置里开关变了：在线的 watcher 马上照新开关装 / 删（不在线的下次连上时按环境变量来）。请求要等回复，放后台线程发"""
    if _isolated():
        return
    ids = skill_ids()

    def run():
        for source in list(sources):
            if not getattr(source, "live", False):
                continue
            try:
                source.request({"cmd": "skills", "enabled": ids}, timeout=20)
            except Exception as exc:   # 一台出错不影响别的
                log.write("[%s] 同步技能失败：%s" % (getattr(source, "name", "?"), exc))

    threading.Thread(target=run, name="skills-sync", daemon=True).start()
