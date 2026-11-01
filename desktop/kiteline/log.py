"""日志：写进数据目录的 kiteline.log（和 Mac 版的 ccpulse.log 一样，一行一条、带 UTC 时间），同时打到 stderr"""

import os
import sys
import threading
from datetime import datetime, timezone

from . import config

_lock = threading.Lock()
_MAX = 4 * 1024 * 1024


def log_path():
    # 跑 Mac 版的接口测试（tests/test_api.py）时，它读 ccpulse.log
    return config.path("ccpulse.log" if os.environ.get("CCPULSE_CONFIG_DIR") else "kiteline.log")


def write(message):
    line = "[%s] %s\n" % (datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), message)
    with _lock:
        try:
            sys.stderr.write(line)
            sys.stderr.flush()
        except Exception:
            pass
        try:
            target = log_path()
            os.makedirs(os.path.dirname(target), exist_ok=True)
            if os.path.exists(target) and os.path.getsize(target) > _MAX:
                os.replace(target, target + ".1")
            with open(target, "a", encoding="utf-8") as handle:
                handle.write(line)
        except OSError:
            pass


def tail(lines=60):
    try:
        with open(log_path(), encoding="utf-8", errors="replace") as handle:
            return handle.read().splitlines()[-lines:]
    except OSError:
        return []
