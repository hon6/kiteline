"""闲置会话自动关闭（同 Mac 版 IdleClose.swift，11-01 起）：24 小时没在 Kiteline 里打开过会话详情的会话，
自动关掉它在电脑上的标签（同手动「关闭会话」：VS Code 关标签、终端发 /exit、别家 agent 交给插件），进「历史会话」；
标记、置顶的也一样关。之后在历史里打开它、发一句话就恢复回会话列表（/api/resume）。

只认人在 Kiteline 里打开了对话页：别的会话发来消息、它在后台自己回复都不算。算「打开过」的：
  - 各端对话页打开时报 POST /api/viewed；对话页开着、App 在前台时每 10 分钟再报一次
  - 旧版 iPhone 不报 /api/viewed，但打开对话页时必取一次 GET /api/voices?key=，也算
  - 从对话页发消息、按住说话、恢复会话
  - 各端启动时随 /api/viewed 带上本机记的「最后看过」（seen），补上升级前的历史（11-02 反馈：超时的会话没有关闭）

起算时间：有打开记录按最后一次打开；一次都没有的，从 Kiteline 第一次见到它算（first）；关掉 / 结束了 10 分钟以上
又出现的重新起算。正在跑的不关，等这一轮停下；要切 VS Code / 终端的，等电脑 10 分钟没人动键盘鼠标再关，一次一个。
记录存配置目录 viewed.json：{viewed: 会话 key → 最后打开时间（毫秒）, first: 第一次见到的时间}
"""

import json
import os
import threading
import time

from . import config, delivery, log
from .store import caps_payload, display_title, is_vscode

THRESHOLD = 24 * 3600
USER_AWAY = 600      # 要切 VS Code / 终端的：人离开电脑这么久才关
REGONE = 600         # 离开列表这么久再出现 = 关掉后又恢复了（重新加载窗口这类几秒钟的不算）
RETRY = 7200         # 关不掉的（还没标题认不出标签、等确认的终端会话……）隔 2 小时再试
TICK = 300


def user_idle():
    if config.IS_LINUX:
        from .alerts import linux_idle_seconds
        return linux_idle_seconds()
    if config.IS_WINDOWS:
        from . import delivery_win
        return delivery_win.idle_seconds()
    return float("inf")


class IdleClose:
    def __init__(self, app):
        self.app = app
        self.path = os.path.join(config.config_dir(), "viewed.json")
        self._lock = threading.Lock()
        self._save_lock = threading.Lock()
        self._viewed, self._first = {}, {}   # 打开过的时间 / 第一次见到的时间（一次打开记录都没有时才拿它起算）
        try:
            with open(self.path, encoding="utf-8") as f:
                saved = json.load(f)
            if "viewed" in saved and "first" in saved:
                self._viewed = {str(k): float(v) for k, v in saved["viewed"].items()}
                self._first = {str(k): float(v) for k, v in saved["first"].items()}
            elif saved:
                # 1.0.20 存的是一张表：装上那一刻一起记下的（2 分钟内）是「第一次见到」，之后的才是真打开过
                old = {str(k): float(v) for k, v in saved.items()}
                earliest = min(old.values())
                for key, value in old.items():
                    (self._first if value - earliest < 120000 else self._viewed)[key] = value
        except (OSError, ValueError, AttributeError, TypeError):
            self._viewed, self._first = {}, {}
        self._live = set()
        self._gone_at = {}
        self._failed_at = {}
        self._closing = False
        self._last_tick = 0

    def touch(self, keys, now=None):
        """打开过这些会话的详情"""
        keys = [k for k in keys or [] if isinstance(k, str) and k and len(k) < 300][:50]
        if not keys:
            return
        stamp = (now or time.time()) * 1000
        with self._lock:
            for key in keys:
                self._viewed[key] = stamp
        self._save()

    def merge(self, history, now=None):
        """各端报来的本机历史（key → 最后看过，毫秒）：只补认识的会话，只往后挪"""
        if not isinstance(history, dict):
            return
        ms = (now or time.time()) * 1000
        oldest = ms - 30 * 86400 * 1000
        changed = False
        with self._lock:
            for key, value in list(history.items())[:1000]:
                if not isinstance(value, (int, float)) or isinstance(value, bool):
                    continue
                if key not in self._live and key not in self._viewed and key not in self._first:
                    continue
                value = min(float(value), ms)
                if value > oldest and value > self._viewed.get(key, 0):
                    self._viewed[key] = value
                    changed = True
        if changed:
            self._save()

    def lost(self, records, now=None):
        """来源还连着、会话却不见了（关掉、结束了）：记下时间，再出现时看要不要重新起算"""
        now = now or time.time()
        with self._lock:
            for record in records:
                self._gone_at[record.key] = now

    def store_updated(self, now=None):
        """会话列表变了：新出现的记下起算时间；关掉 / 结束了一阵子又出现的重新起算"""
        now = now or time.time()
        with self.app.store.lock:
            current = {r.key for r in self.app.store.records}
        changed = False
        with self._lock:
            if current == self._live:
                return
            for key in current - self._live:
                gone = self._gone_at.pop(key, None)
                if gone is not None and now - gone >= REGONE:
                    self._viewed[key] = max(self._viewed.get(key, 0), now * 1000)
                    changed = True
                elif key not in self._viewed and key not in self._first:
                    self._first[key] = now * 1000
                    changed = True
            self._live = current
        if changed:
            self._save()

    def opened_keys(self):
        """有打开记录的会话（自测用：其余的只记了第一次见到）"""
        with self._lock:
            return list(self._viewed)

    def idle(self, key, now=None):
        """多久没打开了（秒）；没记录的返回 None"""
        with self._lock:
            last = self._viewed.get(key, self._first.get(key))
        return None if last is None else (now or time.time()) - last / 1000

    def tick(self, now=None, force=False):
        """定时器每 30 秒叫一次，每 5 分钟真看一次（自测传 now、force 时马上看，不等人离开电脑）"""
        now = now or time.time()
        if not force and now - self._last_tick < TICK:
            return
        self._last_tick = now
        self.store_updated(now)
        self._prune(now)
        if not self.app.cfg.mobile.get("autoCloseIdle", True):
            return
        with self._lock:
            if self._closing:
                return
            self._closing = True
        threading.Thread(target=self._close_due, args=(now, force), daemon=True).start()

    def _due(self, record, now):
        snap = record.snap
        can_reply = not snap.get("readOnly") and (is_vscode(snap) or bool(snap.get("tmuxPane") or snap.get("hosted")) or record.kind == "local"
                                                  or delivery.via_agent(snap))
        if "close" not in caps_payload(snap) or not can_reply or record.activity == "busy":
            return False
        idle = self.idle(record.key, now)
        if idle is None or idle < THRESHOLD:
            return False
        with self._lock:
            failed = self._failed_at.get(record.key)
        return failed is None or now - failed >= RETRY

    def _close_due(self, now, force):
        """一个一个关：每关一个前都再核对一遍（这期间可能刚被打开、开始干活了），关完隔 3 秒"""
        try:
            with self.app.store.lock:
                due = [r for r in self.app.store.records if self._due(r, now)]
            due.sort(key=lambda r: -(self.idle(r.key, now) or 0))   # 最久没打开的先关
            for first in due:
                record = self.app.store.record(first.key)
                if not record or not self._due(record, now):
                    continue
                # 要切 VS Code / 终端的：人在用电脑就等下一轮（别家 agent 交给插件关，不碰前台）
                if not delivery.via_agent(record.snap) and not force and user_idle() < USER_AWAY:
                    return
                title = display_title(record.snap)
                hours = int((self.idle(record.key, now) or 0) / 3600)
                log.write("自动关闭会话「%s」：%d 小时未打开" % (title, hours))
                outcome = delivery.close(record, self.app.store.source(record.source_id), self.app.server.siblings(record))
                if outcome.ok:
                    self.app.set_marked(record.key, False)   # 同手动关闭：关掉了就取消标记
                    self.app.audit.note("自动关闭会话", "%s（%d 小时未打开）" % (title, hours))
                    with self._lock:
                        self._failed_at.pop(record.key, None)
                else:
                    log.write("自动关闭会话未成功「%s」：%s" % (title, outcome["message"]))
                    with self._lock:
                        self._failed_at[record.key] = now
                time.sleep(0 if delivery.DRY_RUN else 3)
        except Exception as exc:  # noqa: BLE001
            log.write("自动关闭会话出错：%s" % exc)
        finally:
            with self._lock:
                self._closing = False

    def _prune(self, now):
        """只留还开着的和 30 天内打开过的（进了历史的会话恢复时 key 不变，留着它的时间）"""
        cutoff = (now - 30 * 86400) * 1000
        with self._lock:
            kept = {k: v for k, v in self._viewed.items() if k in self._live or v >= cutoff}
            kept_first = {k: v for k, v in self._first.items() if k in self._live or v >= cutoff}
            pruned = len(kept) != len(self._viewed) or len(kept_first) != len(self._first)
            self._viewed, self._first = kept, kept_first
            self._failed_at = {k: v for k, v in self._failed_at.items() if k in self._live}
            self._gone_at = {k: v for k, v in self._gone_at.items() if now - v < 86400}
        if pruned:
            self._save()

    def _save(self):
        with self._save_lock:
            with self._lock:
                data = {"viewed": dict(self._viewed), "first": dict(self._first)}
            tmp = self.path + ".tmp"
            try:
                with open(tmp, "w", encoding="utf-8") as f:
                    json.dump(data, f)
                os.replace(tmp, self.path)
            except OSError as exc:
                log.write("保存会话打开记录失败：%s" % exc)
