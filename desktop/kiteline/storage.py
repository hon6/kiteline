"""存储清理（11-24 用户要的，同 Mac 版 Sources/Storage.swift）：会话衍生出来的缓存本来就能从 agent 的会话记录里重新拉，不必长期留着。

口径是「超过 N 天（默认 14）没有使用」，按最后一次使用算，不是按创建时间算。
清的只有我们自己存的衍生数据：图片缓存（media-cache，手机看过的图）、会话浏览器的用户数据、手机发来的图片、旧的测试报告；
不碰 agent 自己的会话记录、待办、收藏、配置。浏览器数据、收件图片、报告由 watcher 的 storage 子命令管
（watcher/kiteline-watch.py：scan / clean），这里再加上自己的图片缓存，提供「立即清理」和每天一次的自动清理。
"""
import json
import os
import subprocess
import sys
import threading
import time

from . import config, log
from .watcher import bundled_watcher

NAMES = {"media": "图片缓存", "browser": "会话浏览器数据", "inbox": "手机发来的图片", "reports": "测试报告"}
_STATE = "storage-auto.json"


def _watcher_script():
    """本机 watcher 脚本：先用装到 ~/.ccpulse 的那份（和 watcher 本身同一份），没有就用打包带的"""
    installed = os.path.join(os.path.expanduser("~"), ".ccpulse", "ccpulse-watch.py")
    if os.path.exists(installed):
        return installed
    return bundled_watcher()


def _watcher(args):
    script = _watcher_script()
    if not script:
        return None
    python = sys.executable if not getattr(sys, "frozen", False) else ("python" if os.name == "nt" else "python3")
    try:
        done = subprocess.run([python, script, "storage"] + args, capture_output=True, text=True, timeout=300,
                              creationflags=0x08000000 if os.name == "nt" else 0)
    except (OSError, subprocess.SubprocessError):
        return None
    try:
        return json.loads(done.stdout)
    except ValueError:
        return None


def _media_usage(media, days):
    """图片缓存：(总字节, 超过 days 天没用的字节, 个数)，按修改时间（load 时会 utime 记下最近用过）"""
    cutoff = time.time() - days * 86400
    total = stale = count = 0
    try:
        names = os.listdir(media.directory)
    except OSError:
        return 0, 0, 0
    for name in names:
        path = os.path.join(media.directory, name)
        try:
            info = os.stat(path)
        except OSError:
            continue
        total += info.st_size
        if not name.endswith(".mime"):
            count += 1
        if info.st_mtime < cutoff:
            stale += info.st_size
    return total, stale, count


def scan(media, days):
    rows = []
    total, stale, count = _media_usage(media, days)
    rows.append({"id": "media", "name": NAMES["media"], "bytes": total, "cleanable": stale, "items": count})
    result = _watcher(["scan", "--days", str(days), "--json"]) or {}
    for item in result.get("categories") or []:
        cid = item.get("category") or ""
        rows.append({"id": cid, "name": NAMES.get(cid, cid), "bytes": int(item.get("bytes") or 0),
                     "cleanable": int(item.get("cleanable") or 0), "items": int(item.get("items") or 0)})
    rows.sort(key=lambda row: -row["bytes"])
    return {"days": days, "total": sum(r["bytes"] for r in rows), "cleanable": sum(r["cleanable"] for r in rows), "categories": rows}


def clean(media, days, only=None):
    """清掉超过 days 天没用的；only 为空就全清。返回腾出的字节数"""
    only = set(only or [])
    freed = 0
    if not only or "media" in only:
        freed += _media_usage(media, days)[1]
        media.prune(days)
    rest = only - {"media"}
    if only and not rest:
        return freed
    args = ["clean", "--days", str(days), "--json"] + (["--only", ",".join(sorted(rest))] if rest else [])
    result = _watcher(args) or {}
    freed += int(result.get("freed") or 0)
    log.write("存储清理：超过 %d 天没用的，共腾出 %d MB" % (days, freed // 1048576))
    return freed


def auto_clean_if_due(media, enabled, days):
    """每天最多自动清一次（用户可在设置里关掉、改天数）；浏览器数据等由 watcher 自己每天清，这里补上自己的图片缓存"""
    if not enabled:
        return
    path = os.path.join(config.config_dir(), _STATE)
    try:
        with open(path, encoding="utf-8") as handle:
            last = float(json.load(handle).get("last") or 0)
    except (OSError, ValueError):
        last = 0.0
    if time.time() - last < 20 * 3600:
        return
    try:
        with open(path, "w", encoding="utf-8") as handle:
            json.dump({"last": time.time()}, handle)
    except OSError:
        pass
    threading.Thread(target=lambda: clean(media, days, ["media"]), daemon=True).start()
