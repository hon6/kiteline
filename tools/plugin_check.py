#!/usr/bin/env python3
"""在本机检查一个 Agent 插件（写插件时用）：按 watcher 的规则加载 plugin.json + plugin.py，核对清单，
调 detect() 和 sessions()，打印标准化后的快照。只读：不启动 watcher、不调 start()（不往 agent 里装组件），读的是这台电脑上那家 agent 的真实数据。

  python3 tools/plugin_check.py plugins/qwen-code
  python3 tools/plugin_check.py plugins/qwen-code --json     快照原样输出成 JSON
"""

import importlib.util
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ABILITIES = {"view", "reply", "approve", "answer", "interrupt"}
PLATFORMS = {"mac", "windows", "linux"}


def load_watcher():
    spec = importlib.util.spec_from_file_location("kl_watcher", os.path.join(ROOT, "watcher", "kiteline-watch.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check_manifest(folder, w):
    problems = []
    manifest = json.load(open(os.path.join(folder, "plugin.json"), encoding="utf-8"))
    if manifest.get("id") != os.path.basename(folder):
        problems.append("清单里的 id 要和目录名一致 / id must match the folder name")
    for field in ("name", "version", "support"):
        if not manifest.get(field):
            problems.append("清单缺 %s / missing %s" % (field, field))
    missing = sorted(set(manifest.get("needs") or []) - set(w.HOST_CAPS))
    if missing:
        problems.append("电脑端没有这些能力 / unknown host capabilities: %s" % ", ".join(missing))
    for platform, forms in (manifest.get("support") or {}).items():
        if platform not in PLATFORMS:
            problems.append("support 里的平台只能是 mac / windows / linux：%s" % platform)
        for form, c in (forms or {}).items():
            bad = set(c.get("abilities") or []) - ABILITIES
            if bad:
                problems.append("support.%s.%s 有不认识的能力 / unknown abilities: %s" % (platform, form, ", ".join(sorted(bad))))
    return manifest, problems


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    folder = os.path.abspath(sys.argv[1].rstrip("/"))
    as_json = "--json" in sys.argv
    w = load_watcher()
    manifest, problems = check_manifest(folder, w)
    print("== 清单 / manifest：%s %s" % (manifest.get("name"), manifest.get("version")))
    for p in problems:
        print("  ✗ " + p)
    if not problems:
        print("  ✓ 没问题 / OK")

    plugins, broken = w.load_external_plugins(os.path.dirname(folder))
    plugin = next((p for p in plugins if p.id == os.path.basename(folder)), None)
    error = next((b["error"] for b in broken if b["id"] == os.path.basename(folder)), None)
    if not plugin:
        sys.exit("✗ 加载失败 / failed to load: %s" % (error or "create() 没返回插件"))
    print("== 加载 / loaded：能力 abilities = %s；caps = %s" % (", ".join(plugin.abilities()), list(plugin.caps) or "—"))

    print("== detect()")
    print("  %s" % json.dumps(plugin.detect(), ensure_ascii=False))

    # 不调 start() / disable()：它们可能往 agent 里装、拆组件，检查工具只读
    snaps = [plugin.standardize(s) for s in (plugin.sessions() or [])]
    print("== sessions()：%d 个会话 / sessions" % len(snaps))
    for snap in snaps:
        if as_json:
            print(json.dumps(snap, ensure_ascii=False, indent=1))
            continue
        flags = [k for k in ("readOnly", "pendingOptions") if snap.get(k)]
        print("  · %-36s %-8s %s  %s" % ((snap.get("title") or "")[:36], snap.get("activity") or "?",
                                         snap.get("cwd") or "", " ".join(flags)))
        for key in ("sessionId", "agent"):
            if not snap.get(key):
                print("    ✗ 快照缺 %s / snapshot is missing %s" % (key, key))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
