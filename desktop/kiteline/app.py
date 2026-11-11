"""Kiteline 电脑端（Windows / Linux）主体：把各部件接起来。

和 Mac 版一样：本机起 watcher 读 Claude Code 会话 → 合并成会话列表 → 手机经 HTTPS（局域网直连，或远程访问经中继）连进来。
"""

import getpass
import io
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta

from . import agent_skill, aggregate, alerts, config, delivery, faces, log, netinfo, reminders, remotessh, setup_tools, tls, tts, voice, vscode_a11y, vscreen
from .devices import DeviceStore, Pairing
from .httpd import HTTPServer, Response
from .p2p import P2P
from .plugins import PluginStore
from .push import WebPush
from .live import LiveActivities
from .guest import GuestLinks
from .groups import Groups
from .idleclose import IdleClose
from .records import Audit, Favorites, Inbox, MediaCache, TabGroupStore, Todos, VoiceStore
from .schedules import Schedules
from .server import MobileServer
from .stats import UsageStats
from .updater import Updater
from .store import Store, display_title
from . import watcher as watcher_module
from .watcher import LocalSource, SSHSource

VERSION = "1.0.40"


class App:
    def __init__(self):
        self.version = VERSION
        self.cfg = config.Config()
        HOSTED_SETTING[0] = lambda source_id: any(s.get("id") == source_id and s.get("hostedOn") for s in self.cfg.sources)
        self.host = tls.host_name()
        self.devices = DeviceStore()
        self.pairing = Pairing()
        self.push = WebPush()
        self.live = LiveActivities(self.host)   # iPhone 锁屏 / 灵动岛的实时活动（见 live.py）
        self.guest = GuestLinks(self)   # 游客链接：会话的局域网只读分享（见 guest.py）
        self.push.contact = self.cfg.mobile["pushContact"]
        self.inbox = Inbox()
        self.audit = Audit()
        self.voices = VoiceStore()
        self.media = MediaCache()
        threading.Thread(target=self.media.prune, daemon=True).start()
        self.p2p = P2P(self.devices)
        self.devices.on_p2p_change = self.p2p.refresh_allowlist
        self._state_timer = None
        self._state_lock = threading.Lock()
        # 各台机器的 CPU、内存、网速（来源 id → watcher 每 5 秒报的那条 sys）。变得太勤，不放进 state（不然整份会话列表
        # 每 5 秒重推一次）：GET /api/state 时附上一份，之后的变化单独以 sys 事件推。来源断开就清掉（同 Mac 版）
        self.machine_stats = {}
        # 会话之间的消息往来（Claude Code 的 SendMessage）：往来 id → 往来，from / to 换成会话 key（同 Mac 的 PeerLinks.swift）
        self.peer_links = {}
        self._peer_lock = threading.Lock()
        self.store = Store(self.cfg, self._store_changed, self._session_notify)
        self.store.on_lost = self._sessions_lost
        delivery.LOOKUP = self.store.record
        self.server = MobileServer(self)
        self.todos = Todos(self.store, self.server.publish)
        self.todos.push_agents = self._push_agent_todos
        self.favorites = Favorites(self.store, self.server.publish)
        self.tab_groups = TabGroupStore(self.server.publish)
        self.groups = Groups(self)   # 会话群：跨设备、跨项目的会话互相发消息
        self.schedules = Schedules(self)
        self.stuck = reminders.StuckWatch(self)
        self.idle_close = IdleClose(self)   # 24 小时没在 Kiteline 里打开过详情的会话：自动关掉，进历史会话
        self.alerts = alerts.Alerts(self)
        self.faces = faces.AgentFaces()   # 对话里 agent 的头像、昵称
        self.waiting = reminders.WaitingReminder(self)
        self.mdns = None
        self.on_clients_change = None
        self.ask_pairing_handler = None   # 界面层可以换成自己的确认框
        self.http = None
        self.https = None
        self.started_at = time.time()
        # 检查更新（updater.py）：状态变了通知托盘；request_exit 由入口换成真正的退出（更新后重启用）
        self.on_update_change = None
        self.request_exit = lambda: None
        self.updater = Updater(self)
        self.stats = UsageStats(self)
        self.plugins = PluginStore(self)   # Agent 插件：设置 → 插件；关掉的插件带进 watcher 的环境变量
        from .peers import Peers
        self.peers = Peers(self)
        delivery.PEERS[0] = self.peers   # 互联的别的 Kiteline 电脑（peers.py）：它的来源同步成本机的 kind = kiteline 来源
        self.ask_peer_handler = None   # 界面层可以换成自己的确认框

    # MARK: 启动

    def start(self):
        log.write("Kiteline %s 启动（%s，数据目录 %s）" % (VERSION, config.PLATFORM, config.config_dir()))
        watcher_module.OPENCODE_PLUGIN = bool(self.cfg.mobile.get("installOpenCodePlugin", True))
        agent_skill.ENABLED = bool(self.cfg.mobile.get("installAgentSkill", True))
        agent_skill.TEST_ENABLED = bool(self.cfg.mobile.get("installTestSkill", True))
        agent_skill.TODO_ENABLED = bool(self.cfg.mobile.get("installTodoSkill", True))
        agent_skill.STAGE_ENABLED = bool(self.cfg.mobile.get("installStageSkill", True))
        for source_config in self.cfg.sources:
            if not source_config.get("enabled", True):
                continue
            source = self._make_source(source_config)
            self.store.add_source(source)
            source.start()
        m = self.cfg.mobile
        # 明文 HTTP 只开本机（本机控制台 /desktop、命令行要用）：手机上的 Kiteline 只走 HTTPS，
        # 局域网里不再有明文端口（扫码链接里的令牌会被同一 Wi-Fi 下的人看到；同 Mac 版，10-22 确认不用网页版）
        host = "127.0.0.1"
        try:
            self.http = HTTPServer(host, int(m["port"]), self.server.route, preauth=self.server.preauthorized)
            self.http.start()
            log.write("手机服务监听 %s:%s" % (host, m["port"]))
        except OSError as exc:
            log.write("手机服务启动失败：%s" % exc)
        if m["enabled"] and m["httpsEnabled"]:
            threading.Thread(target=self._start_https, daemon=True).start()
        if m["enabled"] and m.get("mpEnabled", True):
            self._start_mpgate()
        threading.Thread(target=self._ticker, daemon=True).start()
        self.peers.start()
        if m["enabled"]:
            # 先查一遍防火墙（Windows 上要几秒）：就绪检查打开时直接用结果，被拦着的话日志里也留一句
            from . import firewall
            def check_firewall():
                wall = firewall.status(self.cfg)
                if wall and wall[0] != "ok":
                    log.write("防火墙：%s" % wall[1])
            threading.Thread(target=check_firewall, daemon=True).start()
        self.alerts.start()   # 到某台机器的连接断了：告诉手机，给「尝试重连」
        self.updater.start()
        self.stats.start()
        self.plugins.start()
        from . import autostart
        autostart.ensure_default(self.cfg)
        if not delivery.DRY_RUN and not os.environ.get("KITELINE_CONFIG_DIR"):
            # VS Code 打开 Claude Code 扩展的链接不再弹确认框（测试实例不碰用户的 VS Code 设置）
            threading.Thread(target=remotessh.trust_claude_links, daemon=True).start()
        if m.get("voiceLocale", "zh-CN") == "zh-CN" and os.path.isdir(self.voices.directory) and not os.environ.get("KITELINE_CONFIG_DIR"):
            voice.prepare()
        # 上次开着「VS Code 在虚拟屏幕中运行」：接着把窗口挪过去（测试实例不动）
        vscreen.restore_on_launch()
        if config.IS_LINUX and not delivery.DRY_RUN and not os.environ.get("KITELINE_CONFIG_DIR"):
            # 装过旧版 VS Code 配套扩展、GNOME 扩展的，升到随这一版发的（用户级，几秒钟；GNOME 扩展下次登录生效）
            from . import bridge, shellext
            threading.Thread(target=bridge.ensure_current, daemon=True).start()
            threading.Thread(target=shellext.ensure_current, daemon=True).start()

    def _start_mpgate(self):
        """微信小程序入口：局域网 WebSocket（加密隧道，见 mpgate.py）"""
        from . import mpgate
        m = self.cfg.mobile
        try:
            self.mpgate = mpgate.Gate(self.server.route, lambda: self.host)
            self.mpgate.start(m["bindAddress"], int(m.get("mpPort") or mpgate.DEFAULT_PORT))
        except OSError as exc:
            log.write("小程序入口启动失败：%s" % exc)
            return
        if m["remoteEnabled"] and mpgate.remote_allowed():
            # 远程：电脑主动连中继，小程序经中继找到这台电脑（内容端到端加密）。远程要 Pro，由中继验小程序的通行证（relay/push/mppay.go）
            self.mpgate.relay = mpgate.RelayLink(self.mpgate, self.cfg.relay())
            self.mpgate.relay.start()

    def _start_https(self):
        net = netinfo.current()
        identity = tls.identity(net.all_ips + ["127.0.0.1"], net.names + ["localhost"])
        if not identity:
            self.server.secure_status = "证书准备失败（见日志）"
            return
        m = self.cfg.mobile
        port = self.cfg.https_port()
        try:
            self.https = HTTPServer(m["bindAddress"], port, self.server.route, tls=identity, preauth=self.server.preauthorized)
            self.https.start()
            self.server.secure_status = self.https.status
            log.write("手机 HTTPS 服务监听 %s:%d" % (m["bindAddress"], port))
        except OSError as exc:
            self.server.secure_status = "启动失败：%s" % exc
            log.write("手机 HTTPS 服务启动失败：%s" % exc)
            return
        if m["remoteEnabled"]:
            self.p2p.start(self.cfg.relay(), port)
        if m["bindAddress"] not in ("127.0.0.1", "::1", "localhost"):
            # 局域网宣告要探测名字冲突，Windows 上常要 10 秒左右：放最后，别拖慢远程访问
            try:
                from . import mdns
                self.mdns = mdns.advertise(self.host, port, tls.ca_fingerprint(), net.lan)
            except Exception as exc:  # noqa: BLE001
                log.write("局域网宣告失败：%s" % exc)

    # MARK: 来源（本机、Remote-SSH 主机；同 Mac 版 AppState 的 addSSHSource / setSource / renameSource / removeSource）

    def source_list(self):
        """「来源」页：配置里的每个来源和它现在的状态，加上 VS Code 里用过、还没加的 Remote-SSH 主机（一键添加）"""
        live = dict(self.store.sources)
        items = []
        for entry in self.cfg.sources:
            source = live.get(entry.get("id"))
            enabled = entry.get("enabled", True)
            default = self.peers.default_name(entry) if entry.get("kind") == "kiteline" else (entry.get("sshHost") or "本机")
            items.append({"id": entry.get("id"), "kind": entry.get("kind", "local"), "host": entry.get("sshHost"),
                          "name": entry.get("name") or default, "enabled": enabled, "peerId": entry.get("peerId"),
                          "online": bool(source and source.live),
                          "status": (source.short_label() if source else "未连接") if enabled else "已停用"})
            if source is not None and "hosted" in source.features and entry.get("kind") == "ssh":
                items[-1]["hosted"] = "on" if entry.get("hostedOn") else "off"   # 能后台运行 Claude Code 才带（按设备开）
        added = {(entry.get("sshHost") or "").lower() for entry in self.cfg.sources}
        suggestions = [h for h in remotessh.recent_hosts() if h["host"].lower() not in added]
        peers = [{"id": p["id"], "name": p.get("name"), "address": (p.get("addresses") or [""])[0].replace("https://", ""),
                  "problem": self.peers.problems.get(p["id"])} for p in self.peers.all]
        return {"sources": items, "suggestions": suggestions, "peers": peers}

    def _make_source(self, entry):
        if entry.get("kind") == "kiteline":
            from .peers import PeerSource
            return PeerSource(entry, self._source_event, self._source_changed, self.peers)
        cls = SSHSource if entry.get("kind") == "ssh" else LocalSource
        return cls(entry, self._source_event, self._source_changed)

    def _start_source(self, entry):
        old = self.store.sources.get(entry["id"])
        if old:
            self._stop_source(entry["id"])
        if not entry.get("enabled", True):
            return
        source = self._make_source(entry)
        self.store.add_source(source)
        source.start()

    def apply_peer_sources(self, desired):
        """互联电脑的来源（kind = kiteline）跟上对方报的：只增删这一类，名字、停用沿用本机改过的；只起停增删的那几个（同 Mac 版 applyPeerSources）"""
        current = {s["id"]: s for s in self.cfg.sources if s.get("kind") == "kiteline"}
        merged = []
        for item in desired:
            old = current.get(item["id"])
            if old:
                item = dict(item, enabled=old.get("enabled", True))
                if old.get("name"):
                    item["name"] = old["name"]
            merged.append(item)
        if [current.get(m["id"]) for m in merged] == merged and len(merged) == len(current):
            return
        self.cfg.update(lambda d: d.update(sources=[s for s in d["sources"] if s.get("kind") != "kiteline"] + merged))
        wanted = {m["id"] for m in merged if m.get("enabled", True)}
        for source_id, source in list(self.store.sources.items()):
            if source.kind == "kiteline" and source_id not in wanted:
                self._stop_source(source_id)
                self._machine_stats(source_id, None)
        for entry in merged:
            if entry.get("enabled", True) and entry["id"] not in self.store.sources:
                self._start_source(entry)
        self._store_changed()

    def ask_peer(self, name, address):
        if delivery.DRY_RUN and os.environ.get("KITELINE_TEST_PEER_ALLOW") in ("0", "1"):
            return os.environ["KITELINE_TEST_PEER_ALLOW"] == "1"   # 自测：不弹框，按环境变量答
        if self.ask_peer_handler:
            return self.ask_peer_handler(name, address)
        return confirm_dialog("Kiteline 电脑互联请求",
                              "「%s」（%s）正在用这台电脑上显示的验证码请求互联。允许后，它可以查看并操作这台电脑上的会话，"
                              "这台电脑也会把它加为来源。\n\n如果不是你本人正在那台电脑上操作，请拒绝。" % (name, address), 60)

    def _stop_source(self, source_id):
        with self.store.lock:
            source = self.store.sources.pop(source_id, None)
        if source:
            source.stop()
            self.store.source_changed(source)

    def add_ssh_source(self, host, name="", port=None):
        """添加 Remote-SSH 主机：先确认能免密 ssh 过去、远端装了 python3（同 Mac 版），再加进配置马上连（首次连接自动部署观察器）。
        返回 None = 成功；否则是原因"""
        host = (host or "").strip()
        if not re.match(r"^[A-Za-z0-9_.@:%\[\]-]+$", host) or host.startswith("-"):
            return "主机写法不对（与 ssh 命令中的写法一致，如 my-server、user@10.0.0.5）"
        cmd = [shutil.which("ssh") or "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=accept-new"]
        if port:
            cmd += ["-p", str(int(port))]
        cmd += [host, "command -v python3 >/dev/null && echo TARS_OK"]
        try:
            done = subprocess.run(cmd, capture_output=True, timeout=25, stdin=subprocess.DEVNULL,
                                  creationflags=0x08000000 if config.IS_WINDOWS else 0)
        except (OSError, subprocess.SubprocessError) as exc:
            return str(exc)
        if b"TARS_OK" not in done.stdout:
            lines = [l for l in done.stderr.decode("utf-8", "replace").splitlines() if l.strip()]
            return lines[-1].strip() if lines else ("远端未安装 python3" if done.returncode == 0 else "ssh 退出码 %d" % done.returncode)
        entry = {"id": "ssh:" + host, "kind": "ssh", "sshHost": host, "enabled": True}
        if (name or "").strip():
            entry["name"] = name.strip()
        if port:
            entry["sshPort"] = int(port)
        self.cfg.update(lambda d: d.update(sources=[s for s in d["sources"] if s.get("id") != entry["id"]] + [entry]))
        self._start_source(entry)
        log.write("已添加来源：%s" % host)
        return None

    def update_source(self, source_id, name=None, enabled=None):
        """改名、启用 / 停用"""
        found = {}

        def change(data):
            for entry in data["sources"]:
                if entry.get("id") == source_id:
                    if name is not None:
                        if name.strip():
                            entry["name"] = name.strip()
                        else:
                            entry.pop("name", None)
                    if enabled is not None:
                        entry["enabled"] = bool(enabled)
                    found.update(entry)
        self.cfg.update(change)
        if not found:
            return False
        if enabled is not None or source_id not in self.store.sources:
            self._start_source(found) if found.get("enabled", True) else self._stop_source(source_id)
        elif name is not None:
            self.store.sources[source_id].name = found.get("name") or found.get("sshHost") or "本机"
            self.store.source_changed(self.store.sources[source_id])
        return True

    def remove_source(self, source_id):
        if source_id == "local":
            return False
        entry = next((s for s in self.cfg.sources if s.get("id") == source_id), None)
        if entry and entry.get("kind") == "kiteline":
            return self.peers.remove(entry.get("peerId"))   # 别的电脑的来源：整台电脑移除
        self._stop_source(source_id)
        self.cfg.update(lambda d: d.update(sources=[s for s in d["sources"] if s.get("id") != source_id]))
        log.write("已移除来源：%s" % source_id)
        return True

    def reconnect_sources(self, source_id=None, seamless=False):
        """重新连接（全部或一个）；Remote-SSH 来源每次连接都会把观察器重新传一遍，「重新部署观察器」也走这里。
        seamless：插件变了，只换 watcher 进程载入，会话照旧显示、不报离线（LocalSource.restart）"""
        for entry in self.cfg.sources:
            if entry.get("enabled", True) and (source_id is None or entry.get("id") == source_id):
                current = self.store.source(entry["id"])
                if seamless and current is not None and current.kind == ("ssh" if entry.get("kind") == "ssh" else "local"):
                    current.restart(entry)
                else:
                    self._start_source(entry)

    def stop(self):
        for source in list(self.store.sources.values()):
            source.stop()
        for server in (self.http, self.https):
            if server:
                server.stop()
        if getattr(self, "mpgate", None):
            self.mpgate.stop()
            if getattr(self.mpgate, "relay", None):
                self.mpgate.relay.stop()
        if self.mdns:
            self.mdns.close()
        self.p2p.stop()

    # MARK: 会话事件

    def _source_changed(self, source):
        self.peers.tap_state(source)   # 本机来源连上 / 断开：告诉连着的别的 Kiteline 电脑
        self.store.source_changed(source)
        if not source.live:
            self._machine_stats(source.id, None)
        else:
            threading.Thread(target=self._peer_backfill, args=(source,), daemon=True).start()
            # 刚连上：把 agent 的待办给它一份（agent 在这台电脑上 todo list / done 用得上）
            self.todos.push_to_agents(only=source)
            # 会话群的名单也给一份（group say / info 核对成员）
            self.groups.push_to_agents(only=source)

    def _push_agent_todos(self, items, only=None):
        """agent 的待办推给 watcher（同 Mac 版 Todos.pushToAgents）：agent 用 todo list / done 看得到、关得掉别的会话或别的电脑上记的。
        隔离的测试实例连着的 watcher 用的是真的数据目录，别拿测试数据盖掉（watcher 也隔离了数据目录的才推）。请求要等回复，放后台线程发"""
        if (os.environ.get("KITELINE_CONFIG_DIR") or os.environ.get("KITELINE_DRY_RUN") == "1") and not os.environ.get("CCPULSE_DATA_DIR"):
            return
        targets = [only] if only is not None else [s for s in list(self.store.sources.values()) if s.live]

        def run():
            for source in targets:
                try:
                    source.request({"cmd": "todos", "items": items}, timeout=20)
                except Exception:  # noqa  老版本 watcher 不认这个请求，不用管
                    pass

        threading.Thread(target=run, name="todos-push", daemon=True).start()

    # MARK: 会话之间的消息

    def _ingest_peers(self, source_id, raw):
        """watcher 报来的一批往来：会话 id 换成会话 key，记下（留两天），返回换好的"""
        out = []
        cutoff = time.time() * 1000 - 2 * 86400000
        with self._peer_lock:
            for item in raw:
                if not isinstance(item, dict) or not item.get("id"):
                    continue
                link = dict(item, source=source_id)
                for side in ("from", "to"):
                    if item.get(side):
                        link[side] = "%s#%s" % (source_id, item[side])
                if item.get("was"):
                    self.peer_links.pop(item["was"], None)
                self.peer_links[item["id"]] = link
                out.append(link)
            self.peer_links = {k: v for k, v in self.peer_links.items() if (v.get("sentAt") or v.get("readAt") or 0) >= cutoff}
        return out

    def peers_since(self, since_ms):
        with self._peer_lock:
            links = [v for v in self.peer_links.values() if (v.get("sentAt") or v.get("readAt") or 0) >= since_ms]
        return sorted(links, key=lambda v: v.get("sentAt") or v.get("readAt") or 0)

    def _peer_backfill(self, source):
        """来源连上了：让 watcher 翻对话记录补齐最近一天的往来（旧版 watcher 不认，失败就算了）"""
        try:
            reply = source.request({"cmd": "peers", "since": int(time.time() * 1000 - 86400000)}, timeout=60)
        except Exception:   # noqa: BLE001
            return
        links = self._ingest_peers(source.id, reply.get("links") or [])
        if links:
            self.server.publish("peers", {"links": links, "backfill": True})

    def _machine_stats(self, source_id, stats):
        """某台机器报来新的性能数据（None = 断开了，清掉）：记下，推给手机"""
        if stats is None and self.machine_stats.pop(source_id, None) is None:
            return
        payload = {"id": source_id}
        if stats is not None:
            self.machine_stats[source_id] = payload["stats"] = stats
        self.server.publish("sys", payload)

    def _source_event(self, source, event):
        self.peers.tap_event(source, event)   # 本机来源的事件照抄给连着的别的 Kiteline 电脑
        kind = event["event"]
        if kind == "hello":
            self.groups.note_hello(source.id, event)
        if kind == "snapshots":
            self.store.apply_snapshots(source, event.get("sessions") or [])
            # 早先记的 agent 待办没有项目目录、agent：会话还在的趁这时补上（按项目 / 按 Agent 分组用）
            self.todos.fill_session_meta()
            # 会话群：成员开了 / 关了，排着的群消息接着投或改成恢复时补上
            self.groups.sessions_changed()
        elif kind == "sys":
            self._machine_stats(source.id, {k: v for k, v in event.items() if k != "event"})
        elif kind == "peers":
            links = self._ingest_peers(source.id, event.get("links") or [])
            if links:
                self.server.publish("peers", {"links": links})
        elif kind in ("term", "term_exit"):
            # 会话里的终端：输出、结束直接转给手机和客户端，键与会话列表里的 key 一致
            session_id = event.get("sessionId")
            if session_id:
                payload = {k: v for k, v in event.items() if k not in ("event", "sessionId")}
                payload["key"] = "%s#%s" % (source.id, session_id)
                self.server.publish(kind, payload)
        elif kind in ("entries", "reset"):
            session_id = event.get("sessionId")
            if not session_id:
                return
            key = "%s#%s" % (source.id, session_id)
            if kind == "reset":
                self.server.publish("reset", {"key": key})
                return
            items = event.get("items") or []
            self.server.publish("entries", {"key": key, "items": items})
            self._agent_items(key, items)
        elif kind in ("plugin_error", "plugin_retired") and source.kind != "kiteline":
            self.plugins.on_event(source, event)
        elif kind == "error":
            log.write("[%s] watcher 报错：%s" % (source.name, event.get("message")))

    def _speaker(self, record):
        """对话里怎么称呼这个会话的 agent（「Claude 发来一张图片」「Codex 发来关键信息」）"""
        agent = (record.snap.get("agent") if record else None) or "claude-code"
        if agent == "claude-code":
            return "Claude"
        card = next((c for c in self.plugins.agent_cards() if c.get("id") == agent), {})
        return card.get("speaker") or card.get("name") or agent

    def _agent_items(self, key, items):
        """agent 经 watcher 子命令主动发来的（同 Mac 版 AppState.agentItems）：图推到手机锁屏；
        待办：只有用户能做的（forUser）先成提示、推「需要你处理：…」，用户现在处理或加入待办；agent 自己的直接记进「agent 的待办」，不推；
        进度（todo start / progress / done）按编号改那条；关键信息（keyinfo）推一条，不带具体的值。10-27 起不再从回复里猜「需要你来做」的事"""
        record = self.store.record(key)
        title = display_title(record.snap) if record else "会话"
        for item in items:
            kind = item.get("t")
            if kind == "agent_image":
                # 回别的会话来信的那一轮里发的图：对话里照常显示，不推送
                if not (record and record.snap.get("turnFrom") == "peer"):
                    self.server.notify("image", title, item.get("text") or "%s 发来一张图片" % self._speaker(record), key)
            elif kind == "agent_page":
                # agent 发来的网页（send-page）：同发图，推一条
                if not (record and record.snap.get("turnFrom") == "peer"):
                    name = item.get("title") or "网页"
                    caption = item.get("caption") or ""
                    self.server.notify("image", title, "%s：%s" % (name, caption) if caption else "%s 发来网页「%s」" % (self._speaker(record), name), key)
            elif kind == "agent_todo" and item.get("id") and item.get("text"):
                ts = aggregate.number(item.get("ts")) or None
                if item.get("forUser"):
                    if self.todos.suggest_for_user(key, item["id"], title, record.source_name if record else None, ts,
                                                   item["text"], item.get("detail") or ""):
                        self.server.notify("todo", title, "需要你处理：%s" % item["text"], key)
                else:
                    self.todos.add_agent_task(key, item["id"], item["text"], item.get("detail") or "", item.get("ref") or "", ts)
            elif kind == "agent_todo_update" and item.get("ref"):
                self.todos.update_agent_task(item["ref"], item.get("status") or "doing", item.get("progress") or "", key)
            elif kind == "agent_key":
                self.server.notify("keyinfo", title, "%s 发来关键信息：%s。可在对话中查看、收藏。" % (self._speaker(record), item.get("title") or ""), key)
            elif kind == "group_say":
                # 发到会话群的（watcher 的 group say）：转给群里其他会话
                self.groups.agent_said(key, item)

    def set_marked(self, key, on):
        """标记 / 取消标记会话（新标记的排在标记里的最前，同 Mac 版 AppState.setMarked）"""
        if on == (key in self.cfg.mobile.get("markedSessions", [])):
            return

        def change(data):
            items = [k for k in data["mobile"].get("markedSessions") or [] if k != key]
            data["mobile"]["markedSessions"] = ([key] + items if on else items)[:50]
        self.cfg.update(change)
        self.server.publish_state()

    @staticmethod
    def hosted_probe(sources):
        return hosted_probe(sources)

    @staticmethod
    def move_to_background(record, source, siblings):
        return move_to_background(record, source, siblings)

    def set_hosted(self, source_id=None, on=None, tip_off=None):
        """开 / 关某台的后台运行、「支持后台运行」的提示不再提示（同 Mac 版 Hosted.update）。只改开关，不重连这台"""
        def change(data):
            if source_id and on is not None:
                for entry in data["sources"]:
                    if entry.get("id") == source_id:
                        entry["hostedOn"] = bool(on)
            if tip_off is not None:
                data["mobile"]["hostedTipOff"] = bool(tip_off)
        self.cfg.update(change)
        if source_id and on is not None:
            log.write("%s：后台运行 Claude Code %s" % (source_id, "已开启（检测过出口、用户确认）" if on else "已关闭"))
        if tip_off:
            log.write("「支持后台运行 Claude Code」的提示：用户选了不再提示")
        self.server.publish_state()

    def _sessions_lost(self, records):
        """会话从列表里消失（关掉、结束了）：一分钟后还没回来、它那台机器也还连着，就取消标记。
        等一会儿是怕 VS Code 重新加载窗口这类短暂消失又回来的，把标记弄丢"""
        self.idle_close.lost(records)
        marked = set(self.cfg.mobile.get("markedSessions", []))
        lost = [r for r in records if r.key in marked]
        if not lost:
            return

        def check():
            for record in lost:
                source = self.store.source(record.source_id)
                if self.store.record(record.key) is None and source is not None and source.live:
                    self.set_marked(record.key, False)
        timer = threading.Timer(60, check)
        timer.daemon = True
        timer.start()

    def _store_changed(self):
        # 状态变化合并 0.2 秒再推（watcher 一次可能连着报好几条）
        with self._state_lock:
            if self._state_timer:
                return
            self._state_timer = threading.Timer(0.2, self._flush_state)
            self._state_timer.daemon = True
            self._state_timer.start()

    def _flush_state(self):
        with self._state_lock:
            self._state_timer = None
        self.idle_close.store_updated()
        self.server.publish_state()

    def _session_notify(self, record, kind, text):
        title = display_title(record.snap)
        if kind == "attention":
            body = text
            tool = record.snap.get("pendingTool")
            if tool and tool not in text:
                body = "%s\n工具：%s" % (text, tool)
            self.server.notify("attention", title, body, record.key)
        elif kind == "goal":
            from .store import GOAL_HEADS, goal_push_body
            self.server.notify_goal(title, GOAL_HEADS.get(text.get("state"), "目标"), goal_push_body(text, False), goal_push_body(text, True), record.key)
        else:
            error = record.snap.get("error")
            if error:
                from .store import error_display
                self.server.notify("error", title, error_display(error), record.key)
            else:
                self.server.notify("conclusion", title, text, record.key)
        log.write("提醒 %s/%s：%s" % (record.source_name, display_title(record.snap), kind))

    def clients_changed(self):
        if self.on_clients_change:
            try:
                self.on_clients_change()
            except Exception:  # noqa: BLE001
                pass

    # MARK: 给接口用

    def me(self):
        name = self.cfg.mobile["myName"] or self.user_name()
        # 自己选的图（客户端设置里「更换头像」，同 Mac 版 Profile.saveCustom）：地址带上修改时间，换了图手机端缓存跟着失效
        custom = self.avatar_path()
        if self.cfg.mobile.get("avatar") == "custom" and os.path.exists(custom):
            return {"name": name, "avatar": "/api/avatar?v=%d" % int(os.path.getmtime(custom))}
        return {"name": name, "avatar": ""}

    @staticmethod
    def avatar_path():
        return config.path("avatar.jpg")

    def save_avatar(self, data):
        """任意格式的图进来，裁成正方形、统一成 512×512 JPEG；成功返回 True"""
        if not data or len(data) > 20 * 1024 * 1024:
            return False
        try:
            from PIL import Image
            image = Image.open(io.BytesIO(data)).convert("RGB")
            side = min(image.size)
            left, top = (image.width - side) // 2, (image.height - side) // 2
            image = image.crop((left, top, left + side, top + side)).resize((512, 512), Image.LANCZOS)
            out = io.BytesIO()
            image.save(out, "JPEG", quality=88)
            config.write_private(self.avatar_path(), out.getvalue())
            return True
        except Exception as exc:  # noqa: BLE001
            log.write("保存头像失败：%s" % exc)
            return False

    @staticmethod
    def user_name():
        try:
            return getpass.getuser()
        except Exception:  # noqa: BLE001
            return "我"

    def state_payload(self):
        payload = self.store.state_payload(self.host, VERSION, self.me(), viewed_at=self.idle_close.viewed_at)
        payload["platform"] = config.PLATFORM
        payload["agents"] = self.plugins.agent_cards()   # 插件给的 agent 名称和标志：手机内置表里没有的 agent 靠它画
        payload["alerts"] = self.alerts.payload()        # 要人处理的状况（见 alerts.py）
        payload["faces"] = self.faces.payload()          # 用户给会话、给某家 agent 设的头像和昵称（见 faces.py）
        # 收手机发来的文件、按路径取回文件；会话群、群里发图和文件；手机上看这台电脑的新版本、让它更新（手机按它决定给不给入口）
        # hostedSetup = 远端项目后台运行：出口检测、开关、把会话转到后台（/api/hosted/*）
        payload["features"] = ["files", "groups", "groupMedia", "hostUpdate", "share", "dirs", "hostedSetup", "translate", "tabGroups", "brag"]
        payload["hosted"] = {"tipOff": bool(self.cfg.mobile.get("hostedTipOff"))}
        return payload

    def profile_payload(self):
        m = self.cfg.mobile
        return {"ok": True, "me": self.me(), "myName": m["myName"], "macName": self.user_name(),
                "avatar": m.get("avatar") or "text", "hasMacPicture": False, "hasCustom": os.path.exists(self.avatar_path()), "groups": []}

    def info(self):
        net = netinfo.current()
        hosts = net.tailscale + net.lan + net.names
        m = self.cfg.mobile
        port = self.cfg.https_port()
        https = ["https://%s:%d" % (h, port) for h in tls.covered(hosts)] if m["httpsEnabled"] else []
        custom = (m.get("publicURL") or "").strip("/ ")
        if custom.startswith("https://"):
            https.insert(0, custom)
        return {"ok": True, "host": self.host, "version": VERSION, "platform": config.PLATFORM, "https": https,
                "http": ["http://127.0.0.1:%s" % m["port"]], "secureStatus": self.server.secure_status,
                "pushSubscriptions": len(self.push.subscriptions), "accessibility": delivery_ready(),
                "accessibilityName": "键盘模拟", "caName": tls.ca_name() or "Kiteline Local CA",
                "speech": "authorized" if voice.state()[0] in ("ready", "missing", "downloading") else "denied",
                "submitOnSend": m["submitOnSend"], "digestTime": m["digestTime"], "morningTime": m["morningTime"],
                "quietStart": m["quietStart"], "quietEnd": m["quietEnd"], "quietActive": self.cfg.in_quiet_hours(),
                "remindWaiting": m["remindWaiting"], "autoCloseIdle": m["autoCloseIdle"], "dailyBudget": m["dailyBudget"],
                "remote": {"enabled": m["remoteEnabled"], "state": self.p2p.status.get("state", "stopped"),
                           "relay": self.p2p.status.get("relay") or ""}}

    def _a11y_item(self):
        """Linux：读取 VS Code 弹框、自动按「Open here anyway」（Mac、Windows 系统自带，Linux 要 VS Code 带辅助功能启动，用户自己开启）"""
        from . import atspi_linux
        item = {"id": "vscode-a11y", "title": "读取 VS Code 弹框", "level": "warn", "fix": ""}
        if not vscode_a11y.enabled():
            item["detail"] = ("未开启：VS Code 弹出提示（远程连接断开、工作区不存在等）时不会提醒你，会话「仍在别处打开」时手机消息无法送达。"
                              "开启后 VS Code 以辅助功能模式启动（编辑器照常使用），对话框改用 VS Code 自带的样式")
            item["fix"] = "轻点「开启」，然后关闭所有 VS Code 窗口、重新打开"
            action = setup_tools.action("enable-vscode-a11y", "开启")
            if action:
                item["action"] = action
        elif atspi_linux.editors_exposed() is None and atspi_linux.unavailable_reason():
            item["detail"] = "已开启，但这台电脑无法读取界面：%s" % atspi_linux.unavailable_reason()
            item["fix"] = "安装 python3-gi 与 AT-SPI 组件（Ubuntu / Debian：sudo apt install python3-gi gir1.2-atspi-2.0）"
        elif vscode_a11y.needs_restart():
            item["detail"] = "已开启：关闭所有 VS Code 窗口、重新打开后生效"
            item["fix"] = "关闭所有 VS Code 窗口后重新打开"
        else:
            item["level"] = "ok"
            item["detail"] = "已开启：VS Code 弹出提示时推送到手机，可在手机上尝试重连；会话「仍在别处打开」时自动接管"
            style = vscode_a11y.dialog_style()
            if style not in (None, "custom"):
                # 用户自己在设置里指定了原生对话框：不替他改，说明读不到
                item["detail"] = "已开启。VS Code 设置中 window.dialogStyle 为 %s，对话框无法读取；会话「仍在别处打开」时照常自动接管" % style
        return item

    def readiness(self):
        items = []
        ready, why = delivery_status()
        from . import shellext
        can_switch = not (config.IS_LINUX and wayland_session()) or shellext.loaded()
        item = {"id": "delivery", "title": "向 VS Code 发送消息", "level": "ok" if ready else "warn",
                "detail": ("可以把手机消息粘贴进 VS Code 里的会话并提交"
                           + ("" if can_switch else "（发送时 VS Code 窗口需在前台、屏幕未锁定：这类桌面不允许程序把窗口切到前台）"))
                          if ready else why,
                "fix": "" if ready else delivery_fix()}
        fix_action = None if ready else setup_tools.action("install-vscode-tools")
        if fix_action:
            item["action"] = fix_action
        items.append(item)
        if remotessh.vscode_installed():
            # 扩展链接免确认（见 remotessh.trust_claude_links）：查的时候顺手设好，测试实例只查不写（同 Mac 版）
            trusted = (remotessh.claude_links_trusted() if delivery.DRY_RUN or os.environ.get("KITELINE_CONFIG_DIR")
                       else remotessh.trust_claude_links()[0])
            items.append({"id": "vscode-links", "title": "VS Code 允许 Claude Code 打开链接", "level": "ok" if trusted else "bad",
                          "detail": "已允许：切换会话、新建任务时 VS Code 不会弹出确认框" if trusted else
                                    "未允许，且 VS Code 的设置文件无法自动修改：切换会话、新建任务时 VS Code 会先弹出确认框，人不在电脑前时消息无法送达",
                          "fix": "" if trusted else
                                 "在电脑上 VS Code 弹出「是否允许 Claude Code 扩展打开此 URI」时，勾选「不再询问」并点击「打开」；或在 VS Code 的用户设置（JSON）中加入 \"extensions.confirmedUriHandlerExtensionIds\": [\"anthropic.claude-code\"]"})
        if config.IS_LINUX and remotessh.vscode_installed():
            items.append(self._a11y_item())
        if config.IS_LINUX and shellext.applicable() and remotessh.vscode_installed():
            # GNOME：Kiteline 的 GNOME 扩展替你把 VS Code 切到前台（Wayland 下只能靠它）、虚拟屏幕
            status, _ = shellext.status()
            item = {"id": "gnome-shell", "title": "自动切换到 VS Code", "level": "ok" if status == "ready" else "warn",
                    "detail": {"ready": "已启用 Kiteline 的 GNOME 扩展：发送时自动把 VS Code 切到前台，发完切回原来的窗口；也可以把 VS Code 移到虚拟屏幕",
                               "relogin": "Kiteline 的 GNOME 扩展已安装，注销并重新登录一次后生效",
                               }.get(status, "需要安装 Kiteline 的 GNOME 扩展：发送时自动把 VS Code 切到前台、发完切回；没有它时需要先在电脑上切到 VS Code"),
                    "fix": "" if status == "ready" else
                           ("在电脑上注销并重新登录一次" if status == "relogin" else "轻点「一键安装」，然后在电脑上注销并重新登录一次（不需要管理员密码）")}
            fix_action = setup_tools.action("install-gnome-shell")
            if fix_action:
                item["action"] = fix_action
            items.append(item)
        if config.IS_LINUX:
            # 终端里的 claude：在 tmux 里运行才能从手机发消息（Windows 直接写控制台，不用这一项）
            has_tmux = not setup_tools.missing("install-tmux")
            item = {"id": "terminal", "title": "向终端里的会话发送消息", "level": "ok" if has_tmux else "warn",
                    "detail": ("已安装 tmux：在 tmux 里运行的 claude 可以接收手机消息" if has_tmux else
                               "终端里的 Claude Code 会话需要在 tmux 里运行，才能从手机发消息；这台电脑还没有安装 tmux"),
                    "fix": "在项目目录里用这条命令启动 Claude Code：%s（已有同名的 tmux 会话会直接接回去）%s" % (
                        setup_tools.TMUX_COMMAND,
                        "" if has_tmux else "；先轻点「一键安装」装上 tmux，或在电脑终端运行 %s" % setup_tools.manual_command("install-tmux"))}
            fix_action = None if has_tmux else setup_tools.action("install-tmux")
            if fix_action:
                item["action"] = fix_action
            items.append(item)
            lock = screen_lock()
            if lock is not None:
                # 锁屏时系统不许往窗口里输入（Kiteline 也会拒绝发送）；同 Mac 版「保持唤醒」，由用户自己决定
                minutes = lock
                items.append({"id": "screenlock", "title": "屏幕自动锁定", "level": "ok" if minutes == 0 else "warn",
                              "detail": "不会自动锁屏，离开电脑时也能从手机向 VS Code 发消息" if minutes == 0 else
                                        "闲置 %d 分钟后自动锁屏：锁屏期间无法把手机消息发进 VS Code（终端里放在 tmux 中运行的会话不受影响）" % minutes,
                              "fix": "如果希望离开电脑时也能从手机发消息：在「设置 → 隐私和安全性 → 屏幕锁定」关闭「自动锁屏」，或把「空白屏幕延时」调长"})
        from . import firewall
        wall = firewall.status(self.cfg)
        if wall:
            # 防火墙拦着：同一网络里的手机、别的 Kiteline 电脑连不进来（Windows 第一次运行时关掉了系统的提示框就会这样）
            item = {"id": "firewall", "title": "防火墙放行", "level": wall[0], "detail": wall[1],
                    "fix": "" if wall[0] == "ok" else "轻点「一键放行」，在电脑上的授权窗口里确认；或者%s" % firewall.manual_command(self.cfg)}
            if wall[0] != "ok":
                item["action"] = {"id": "allow-firewall", "label": "一键放行", "command": firewall.manual_command(self.cfg)}
            items.append(item)
        secure = self.server.secure_status
        items.append({"id": "https", "title": "HTTPS 服务", "level": "ok" if secure.startswith("监听中") else "bad",
                      "detail": secure, "fix": "检查端口 %d 是否被占用，或防火墙是否放行" % self.cfg.https_port()})
        state, progress = voice.state()
        if os.environ.get("CCPULSE_FAKE_TRANSCRIPT"):
            state = "ready"
        items.append({"id": "speech", "title": "语音识别（按住说话）", "level": "ok" if state == "ready" else "warn",
                      "detail": {"ready": "已就绪，由电脑本机 Fun-ASR-Nano 模型离线转写",
                                 "downloading": "正在下载语音识别模型 %d%%" % int(progress * 100),
                                 "missing": "首次使用时自动下载语音识别模型（约 1 GB）"}.get(state, voice.unavailable_reason()),
                      "fix": "" if state == "ready" else "保持联网，模型下载完成后即可使用"})
        with self.store.lock:
            sources = list(self.store.sources.values())
        offline = [s.name for s in sources if not s.live]
        items.append({"id": "sources", "title": "各台机器", "level": "warn" if offline else "ok",
                      "detail": ("离线：" + "、".join(offline)) if offline else "%d 台均在线" % len(sources),
                      "fix": "确认 Python 3 已安装；远端主机确认可免密 ssh 登录"})
        remote = self.p2p.status
        enabled = self.cfg.mobile["remoteEnabled"]
        items.append({"id": "remote", "title": "远程访问（不在同一 Wi-Fi 时连接）",
                      "level": "ok" if remote.get("state") == "online" else "warn",
                      "detail": "已连接 Kiteline 中继" if remote.get("state") == "online" else
                      ("未开启：手机仅能在同一 Wi-Fi 下连接" if not enabled else "尚未连接中继：%s" % (remote.get("error") or remote.get("state"))),
                      "fix": "在 Kiteline 设置中开启远程访问；无法连接时检查网络"})
        items.append({"id": "autostart", "title": "开机自动启动", "level": "ok" if autostart_enabled() else "warn",
                      "detail": "已开启：电脑重启后 Kiteline 将自动启动" if autostart_enabled() else "未开启：电脑重启后需手动打开 Kiteline，手机才能连接",
                      "fix": "在 Kiteline 设置中开启「登录时自动启动」"})
        return items

    def changelog(self, english=False):
        """按看的那台手机的语言给中文版 / 英文版（没有英文版就用中文版）"""
        base = getattr(sys, "_MEIPASS", None)
        here = os.path.dirname(os.path.abspath(__file__))
        names = (["CHANGELOG.en.md"] if english else []) + ["CHANGELOG.md"]
        candidates = [os.path.join(folder, name) for name in names for folder in ([base] if base else []) + [os.path.join(here, "..")]]
        for candidate in candidates:
            try:
                with open(candidate, encoding="utf-8") as handle:
                    return handle.read()
            except OSError:
                continue
        return ""

    def transcribe(self, path):
        fake = os.environ.get("CCPULSE_FAKE_TRANSCRIPT")   # 自动化测试：不走真的识别
        if fake:
            return fake
        return voice.transcribe(path, self.cfg.mobile.get("voiceLocale", "zh-CN"))

    def synthesize(self, text, voice_id, rate):
        """朗读：微软语音（edge-tts）/ Windows 自带语音，见 tts.py；都不行返回 None，手机改用自带语音"""
        return tts.synthesize(text, voice_id, rate)

    # MARK: 配对

    def new_link_token(self):
        token = self.pairing.new_link_token()
        if self.cfg.mobile["remoteEnabled"]:
            self.p2p.open_pairing(None)
        return token

    def new_code(self):
        code = self.pairing.new_code()
        if self.cfg.mobile["remoteEnabled"]:
            self.p2p.open_pairing(code, tls.ca_fingerprint(), on_conflict=self.new_code, current_code=lambda: self.pairing.code)
        return code

    def pairing_link(self, token):
        """二维码里的链接：https://局域网 IP:HTTPS 端口/?t=<一次性令牌>&fp=<根证书指纹>[&id=<点对点公钥>&r=<中继>]"""
        addresses = self.pairing_addresses()
        return "%s/?%s" % (addresses[0]["base"], self.pairing_query(token))

    def pairing_query(self, token):
        query = {"t": token, "fp": tls.ca_fingerprint() or ""}
        info = self.p2p.join_info
        if info and self.cfg.mobile["remoteEnabled"]:
            query.update({"id": info["id"], "r": info["relay"]})
        gate = getattr(self, "mpgate", None)
        if gate and gate.status.startswith("监听"):
            # 微信小程序扫同一个码：mk = 电脑的小程序长期公钥（核对身份用），mp = 小程序入口端口（见 mpgate.py）
            import base64
            query.update({"mk": base64.urlsafe_b64encode(gate.keys.public).decode("ascii").rstrip("="),
                          "mp": int(self.cfg.mobile.get("mpPort") or 8768)})
        return urllib.parse.urlencode(query)

    def pairing_addresses(self):
        """手机能连到这台电脑的地址（客户端「手机访问」页可以换着扫）：自定义 > 局域网 > Tailscale（同 Mac 版 PhoneAccess.addresses）"""
        net = netinfo.current()
        port = self.cfg.https_port()
        result = []
        custom = (self.cfg.mobile.get("publicURL") or "").strip("/ ")
        if custom.startswith("https://"):
            result.append({"label": "自定义", "base": custom})
        for label, hosts in (("局域网", net.lan), ("Tailscale", net.tailscale)):
            for host in tls.covered(hosts):
                result.append({"label": label, "base": "https://%s:%d" % (host, port)})
        return result or [{"label": "本机", "base": "https://127.0.0.1:%d" % port}]

    def ask_pairing(self, name):
        if self.ask_pairing_handler:
            return self.ask_pairing_handler(name)
        return confirm_dialog("Kiteline 配对请求", "「%s」请求经远程访问与这台电脑配对。\n\n确认是你自己的手机吗？" % name, 60)

    # MARK: 花费

    def spend_capped(self):
        cap = float(self.cfg.mobile["dailyCap"] or 0)
        if cap <= 0:
            return None
        cost = aggregate.today_cost(self.store)
        if cost >= cap:
            return "今日已花费 $%.2f，超出每日上限 $%.0f" % (cost, cap)
        return None

    def _state(self):
        return config.read_json(config.path("state.json"), {})

    def _set_state(self, key, value):
        data = self._state()
        data[key] = value
        config.write_private(config.path("state.json"), json.dumps(data, ensure_ascii=False))

    def check_budget(self):
        """今天花到预算的 80% / 100% 时各推一次（同一天同一档只推一次，状态记在数据目录的 state.json）"""
        budget = float(self.cfg.mobile["dailyBudget"] or 0)
        if budget <= 0:
            return "未设置每日预算"
        cost = aggregate.today_cost(self.store)
        day = datetime.now().strftime("%Y-%m-%d")
        level = 100 if cost >= budget else (80 if cost >= budget * 0.8 else 0)
        if not level:
            return "今日 $%.2f，未达提醒额度" % cost
        sent = str(self._state().get("budgetAlertSent", ""))
        if sent.startswith(day + "|") and int(sent.split("|")[1] or 0) >= level:
            return "今日已提醒"
        self._set_state("budgetAlertSent", "%s|%d" % (day, level))
        title = "今日已花费 $%.0f，超出预算 $%.0f" % (cost, budget) if level == 100 else "今日已花费 $%.0f，达到预算的 80%%" % cost
        self.server.notify("budget", "花费提醒", title, None, route="usage")
        self.audit.note("花费提醒", title)
        return title

    # MARK: 日报

    def send_digest(self, manual=False):
        return reminders.send_digest(self, manual)

    def send_morning(self, manual=False):
        return reminders.send_morning(self, manual)

    def _ticker(self):
        """每分钟看一次：日报 / 早安简报的时间、花费提醒、定时任务"""
        fired = set()
        while True:
            time.sleep(30)
            now = datetime.now()
            stamp = now.strftime("%Y-%m-%d %H:%M")
            m = self.cfg.mobile
            for name, at, fn in (("digest", m.get("digestTime"), self.send_digest), ("morning", m.get("morningTime"), self.send_morning)):
                hm = config.parse_hm(at or "")
                if delivery.DRY_RUN:
                    continue
                if hm and (now.hour, now.minute) == hm and (name, stamp) not in fired:
                    fired.add((name, stamp))
                    try:
                        log.write(fn(False))
                    except Exception as exc:  # noqa: BLE001
                        log.write("%s 推送失败：%s" % (name, exc))
            if now.minute % 10 == 0 and float(m.get("dailyBudget") or 0) > 0:
                try:
                    self.check_budget()
                except Exception:  # noqa: BLE001
                    pass
            try:
                self.schedules.tick(now)
                if not delivery.DRY_RUN:
                    self.stuck.tick(time.time())
                    self.idle_close.tick()
                    self.waiting.tick(time.time())
            except Exception as exc:  # noqa: BLE001
                log.write("定时检查出错：%s" % exc)

    # MARK: 新任务 / 恢复会话

    def new_session(self, request):
        body = request.json
        if body is None:
            return Response.error("请求格式无效", 400)
        source = self.store.source(body.get("sourceId", ""))
        if not source or not source.live:
            return Response.error("该机器当前离线", 404)
        cwd = str(body.get("cwd") or "").strip()
        if not cwd or len(cwd) > 1024 or "\n" in cwd or "\0" in cwd:
            return Response.error("项目路径无效", 400)
        text = body.get("text") or ""
        attachments = delivery.attachments_of(body)
        if not text.strip() and not attachments:
            return Response.error("请先填写任务内容", 400)
        try:
            check = source.request({"cmd": "is_dir", "path": cwd}, timeout=15)
            if not check.get("isDir"):
                raise ValueError
        except Exception:  # noqa: BLE001
            return Response.error("%s 上不存在该目录：%s" % (source.name, cwd), 400)
        try:
            paths = delivery.stage(attachments, source) if attachments else []
        except Exception as exc:  # noqa: BLE001
            return Response.error("图片或文件传输失败：%s" % exc, 502)
        prompt = delivery.compose(text, paths, attachments)
        submit = body.get("submit", self.cfg.mobile["submitOnSend"])
        log.write("手机新任务 %s:%s：%s" % (source.name, cwd, text[:60]))
        branch = None
        if body.get("worktree") is True:
            try:
                prepared = source.request({"cmd": "worktree_add", "cwd": cwd}, timeout=30)
            except Exception as exc:  # noqa: BLE001
                return Response.error("独立分支创建失败：%s" % exc, 409)
            if not prepared.get("path") or not prepared.get("branch"):
                return Response.error("独立分支创建失败：worktree 创建失败", 409)
            base = "（基于 %s）" % prepared["base"] if prepared.get("base") else ""
            cwd, branch = prepared["path"], prepared["branch"]
            prompt += ("\n\n（当前为独立的 git worktree，分支 %s%s，目录 %s。请仅在此目录中修改；完成后暂不合并，并说明改动内容及合并方式。）"
                       % (branch, base, cwd))
            log.write("新任务用独立 worktree：%s → %s" % (branch, cwd))
        # 回车之后核实真的提交了：这个目录下有会话开始运行（发起前就在运行的不算）
        busy_before = {r.key for r in self.store.records if r.activity in ("busy", "waiting")}
        keys_before = {r.key for r in self.store.records}
        want = os.path.normcase(os.path.normpath(cwd))

        def started():
            # 回得快的（两三秒就答完）等 watcher 发现这个新会话时已经空闲了，看不到「运行中」：这次新出现的会话已经有了回复（usage）也算
            with self.store.lock:
                return any(r.source_id == source.id and os.path.normcase(os.path.normpath(r.snap.get("cwd") or "")) == want
                           and ((r.key not in busy_before and r.activity in ("busy", "waiting")) or (r.key not in keys_before and r.snap.get("usage")))
                           for r in self.store.records)
        result = launch_session(cwd, prompt, submit, None, source.kind, source.name, started, source=source, notify=self._launch_failed)
        if branch:
            result["branch"] = branch
        return Response.json(result)

    def resume(self, request):
        target = self.store.resolve_any(request.query.get("key", ""))
        if not target:
            return Response.error("会话不存在，或其所在机器离线", 404)
        if self.store.record(request.query.get("key", "")):
            return Response.error("此会话仍在运行，可直接发送消息", 409)
        session_id, source = target
        body = request.json or {}
        try:
            info = source.request({"cmd": "session_info", "sessionId": session_id}, timeout=20)
            cwd = (info.get("session") or {}).get("cwd")
        except Exception:  # noqa: BLE001
            cwd = None
        if not cwd:
            return Response.error("未找到该会话的工作目录", 404)
        attachments = delivery.attachments_of(body)
        try:
            paths = delivery.stage(attachments, source) if attachments else []
        except Exception as exc:  # noqa: BLE001
            return Response.error("图片或文件传输失败：%s" % exc, 502)
        prompt = delivery.compose(body.get("text") or "", paths, attachments)
        submit = bool(prompt) and body.get("submit", self.cfg.mobile["submitOnSend"])
        log.write("手机恢复会话 %s:%s：%s" % (source.name, session_id, (body.get("text") or "")[:60]))
        # editor：客户端「在 VS Code 中恢复」按钮，远端项目也开 VS Code（不走后台托管）
        return Response.json(launch_session(cwd, prompt, submit, session_id, source.kind, source.name, source=source, notify=self._launch_failed,
                                            in_editor=body.get("editor") is True))

    def _launch_failed(self, message):
        """新任务 / 恢复会话先回了「将自动提交」，后来没提交成功：推一条提醒（同 Mac 版 launchReplies 的 finished）"""
        self.server.notify("error", "新任务未能自动提交", message, None, route="")

    def open_in_editor(self, key):
        """电脑端客户端会话菜单「在 VS Code 中打开」（POST /api/desktop/jump）。返回 (成功, 说明)"""
        record = self.store.record(key)
        source = self.store.source(record.source_id) if record else None
        if not record or not source:
            return False, "会话不存在，或其所在机器离线"
        if record.snap.get("hosted"):
            return hand_over(record, source)
        return open_in_editor(record, source)

    # MARK: Bark

    def bark_send(self, title, body, kind):
        url = (self.cfg.mobile["barkURL"] or "").rstrip("/")
        if not url:
            return False, "尚未填写 Bark 地址"
        data = json.dumps({"title": title, "body": body, "group": "Kiteline",
                           "level": "timeSensitive" if kind == "attention" else "active"}).encode("utf-8")
        request = urllib.request.Request(url, data=data, method="POST", headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                return 200 <= response.status < 300, "已发送"
        except OSError as exc:
            return False, "Bark 推送失败：%s" % exc


# MARK: - 平台相关

def delivery_status():
    if DRY:
        return True, ""
    if config.IS_WINDOWS:
        return True, ""
    from . import delivery_bridge
    reason = delivery_bridge.why_unavailable()
    return not reason, reason


DRY = delivery.DRY_RUN


def wayland_session():
    return os.environ.get("XDG_SESSION_TYPE") == "wayland" or (bool(os.environ.get("WAYLAND_DISPLAY")) and not os.environ.get("DISPLAY"))


def screen_lock():
    """GNOME 闲置多少分钟后自动锁屏（0 = 不会自动锁屏）；不是 GNOME、读不到时返回 None（不显示这一项）"""
    if not shutil.which("gsettings") or not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        return None
    try:
        def get(schema, key):
            out = subprocess.run(["gsettings", "get", schema, key], capture_output=True, timeout=5)
            if out.returncode != 0:
                raise OSError
            return out.stdout.decode().strip()
        if get("org.gnome.desktop.screensaver", "lock-enabled") != "true":
            return 0
        delay = int(get("org.gnome.desktop.session", "idle-delay").split()[-1])
        return 0 if delay == 0 else max(1, delay // 60)
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def delivery_ready():
    return delivery_status()[0]


def delivery_fix():
    if config.IS_LINUX:
        command = setup_tools.manual_command("install-vscode-tools")
        return ("轻点「一键安装」：在 VS Code 中装上 Kiteline 配套扩展，并授予 Kiteline 键盘模拟权限（只用来在 VS Code 里按回车、"
                "选确认框选项，只授予当前登录在电脑屏幕前的用户），需要在电脑上输入一次密码；装好后关闭并重新打开 VS Code"
                + ("。也可以在电脑终端运行：%s" % command if command else ""))
    return ""


def autostart_enabled():
    from . import autostart
    return autostart.enabled()


def confirm_dialog(title, message, timeout):
    """电脑上弹一个「允许 / 拒绝」框；timeout 秒没点算拒绝。没有图形界面时一律拒绝"""
    if config.IS_WINDOWS:
        import ctypes
        try:
            # MessageBoxTimeoutW：系统自带、未公开但长期可用；6 = 点了「是」
            box = ctypes.windll.user32.MessageBoxTimeoutW
            result = box(None, message, title, 0x4 | 0x20 | 0x40000 | 0x10000, 0, timeout * 1000)
            return result == 6
        except Exception:  # noqa: BLE001
            return False
    if shutil.which("zenity") and (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        try:
            # --no-markup：手机名是对方自己填的，别让它用 Pango 标记排版伪装成别的提示
            result = subprocess.run(["zenity", "--question", "--no-markup", "--title", title, "--text", message, "--ok-label", "允许",
                                     "--cancel-label", "拒绝", "--timeout", str(timeout)], timeout=timeout + 5)
            return result.returncode == 0
        except (OSError, subprocess.SubprocessError):
            return False
    log.write("没有图形界面，无法确认经远程访问的配对请求（已拒绝）")
    return False


def open_url(url):
    if config.IS_WINDOWS:
        os.startfile(url)   # noqa: S606
    else:
        opener = shutil.which("code") if url.startswith("vscode") else None
        cmd = [opener, "--open-url", url] if opener else [shutil.which("xdg-open") or "xdg-open", url]
        # VS Code 还没开时由这里拉起：开启过「读取 VS Code 弹框」的带上辅助功能（见 vscode_a11y）
        subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=vscode_a11y.launch_env())


def code_command():
    """VS Code 命令行：Windows 上是 code.cmd"""
    found = shutil.which("code") or shutil.which("code.cmd")
    if found:
        return found
    if config.IS_WINDOWS:
        for base in (os.environ.get("LOCALAPPDATA", ""), os.environ.get("ProgramFiles", "")):
            candidate = os.path.join(base, "Programs" if "Local" in base else "", "Microsoft VS Code", "bin", "code.cmd")
            if os.path.exists(candidate):
                return candidate
    return None


def _front_backend():
    """能切换前台窗口的投递后端（投完还焦点用）：Windows、GNOME（Kiteline 的 GNOME 扩展，Wayland 也行）、X11；都没有返回 None"""
    if config.IS_WINDOWS:
        from . import delivery_win
        return delivery_win
    if config.IS_LINUX:
        from . import delivery_x11, shellext
        if shellext.loaded():
            return shellext
        if delivery_x11.available():
            return delivery_x11
    return None


def _project_window_open(cwd, remote):
    """项目已经在某个 VS Code 窗口里开着（开着的话信任早就答过了）；认不出来当没开"""
    try:
        if config.IS_WINDOWS:
            from . import delivery_win
            folders = [p for p in cwd.rstrip("\\/").replace("\\", "/").split("/") if p and not p.endswith(":")][::-1]
            return any(delivery.window_matches(title, folder, remote) for folder in folders for _, title, _ in delivery_win.editor_windows())
        from . import bridge
        return bool(bridge.installed() and bridge.window_for_cwd(cwd, only_match=True))
    except Exception:  # noqa: BLE001
        return False


def open_in_editor(record, source):
    """切到会话所在的 VS Code 窗口；没开着就新开一个（远端项目经 Remote-SSH，VS Code 没开着也行）。同 Mac 版 Actions.jumpToWorkspace"""
    cwd = record.snap.get("cwd") or ""
    remote = record.kind == "ssh"
    if config.IS_WINDOWS and cwd:
        from . import delivery_win
        hwnd = delivery_win.raise_window(cwd, remote)
        if hwnd:
            vscreen.bring_back(hwnd)   # 在虚拟屏幕上：用户要看这个窗口，挪回原处（只挪这一个）
            return True, ""
    code = code_command()
    if not code:
        return False, "未找到 VS Code 命令行（code）"
    target = cwd or (getattr(source, "home", None) or os.path.expanduser("~"))
    if config.IS_LINUX and cwd:
        # 会话目录在某个已开窗口的工作区里面：开窗口自己的根目录，VS Code 会切到那个窗口（直接开子目录会另开一个窗口）
        from . import bridge, shellext
        window = bridge.window_for_cwd(cwd, only_match=True) if bridge.installed() else None
        if window and not remote and shellext.loaded():
            # 窗口开着、有 Kiteline 的 GNOME 扩展：直接切过去（在虚拟屏幕上的放回来），不跑 code 命令
            # （GNOME Wayland 下跑过 code 命令后 VS Code 会不认外部切过来的焦点，见 shellext.refocus）
            threading.Thread(target=_show_editor, args=(window.state.get("folders") or [cwd],), daemon=True).start()
            return True, ""
        roots = [f.rstrip("/") for f in (window.state.get("folders") or [])] if window else []
        roots = [f for f in roots if f and (cwd.rstrip("/") == f or cwd.startswith(f + "/"))]
        if roots:
            target = max(roots, key=len)
    note = None
    # --skip-welcome：VS Code 有史以来第一次启动时先弹「Welcome to VS Code」登录引导，挡住一切，Kiteline 打开的跳过它（同 Mac 版）
    args = [code, "--skip-welcome", target]
    if remote:
        source_config = source.config
        if not source_config.get("sshHost"):
            return False, "此远端来源未配置主机地址"
        problem, note = remotessh.prepare(code, source_config, getattr(source, "platform", None))
        if problem:
            return False, problem
        args = [code, "--skip-welcome", "--folder-uri", remotessh.folder_uri(source_config["sshHost"], source_config.get("sshPort"), target)]
    try:
        subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         **({"creationflags": 0x08000000} if config.IS_WINDOWS else {"env": vscode_a11y.launch_env()}))
    except OSError as exc:
        return False, str(exc)
    log.write("在 VS Code 中打开：%s" % args[-1])
    if config.IS_LINUX and cwd:
        # Wayland 下 VS Code 自己切不到前台（GNOME 只弹「已就绪」通知）：经 Kiteline 的 GNOME 扩展切过去；在虚拟屏幕上的放回来给你看
        threading.Thread(target=_show_editor, args=([cwd] + ([target] if target != cwd else []),), daemon=True).start()
    return True, note or ""


def _show_editor(folders):
    from . import shellext
    if not shellext.loaded():
        return
    for _ in range(10):
        time.sleep(0.8)
        window = shellext.find_editor(folders)
        if window:
            vscreen.bring_back(window["id"])
            shellext.activate(window["id"])
            return


# 某台远端电脑开没开后台运行 Claude Code（来源的 hostedOn，按设备）：App 起来时接上（launch_session 是模块级的）
HOSTED_SETTING = [lambda source_id: False]


def hand_over(record, source):
    """「在 VS Code 中打开」Kiteline 在后台运行的会话（同 Mac 版 Hosted.handOver）：同一段对话不能两个进程一起写，
    Claude 空闲时先结束后台这份、再在 VS Code 里接着这段对话；正在工作、等确认时不打断。返回 (成功, 说明)"""
    if record.activity in ("busy", "waiting"):
        return False, "Claude 正在处理这个会话。为免打断，请在这一轮完成后再点击「在 VS Code 中打开」，届时会转到 VS Code 中继续。"
    log.write("后台会话 %s 转到 VS Code：先结束后台运行的 claude" % record.snap.get("name"))
    try:
        # ifIdle：快照里的状态晚一两秒，watcher 再看一眼界面，Claude 刚开始干活的也不停
        reply = source.request({"cmd": "hosted_stop", "sessionId": record.snap.get("sessionId"), "ifIdle": True}, timeout=20)
    except Exception as exc:  # noqa: BLE001
        return False, str(exc)
    if reply.get("busy"):
        return False, "Claude 正在处理这个会话。为免打断，请在这一轮完成后再点击「在 VS Code 中打开」，届时会转到 VS Code 中继续。"
    if not reply.get("stopped"):
        return False, "后台会话没有按时结束"
    result = launch_session(record.snap.get("cwd") or "", "", False, record.snap.get("sessionId"), record.kind, record.source_name,
                            source=source, in_editor=True)
    return bool(result.get("ok")), result.get("message") or ""


def hosted_probe(sources):
    """出口检测（同 Mac 版 Hosted.probe）：每台远端电脑照后台运行时的那套网络设置访问查 IP 的公共网址（不连 Claude），
    回 [{id, name, source, settings, egress, error}]；离线、不支持的也列上"""
    env = remotessh.claude_environment()
    results = [None] * len(sources)

    def one(index, source):
        item = {"id": source.id, "name": source.name}
        if source.state != "live":
            item["error"] = "该机器当前离线，未检测"
        elif "hosted" not in source.features:
            item["error"] = "这台电脑暂不支持在后台运行 Claude Code"
        else:
            try:
                reply = source.request({"cmd": "hosted_probe", "netEnv": env}, timeout=90)
                item.update({k: reply.get(k) for k in ("source", "settings", "egress")})
            except Exception as exc:  # noqa: BLE001
                item["error"] = str(exc).replace("HOSTED_NETWORK：", "").replace("HOSTED_UNSUPPORTED：", "")
        results[index] = item

    workers = [threading.Thread(target=one, args=(i, s), name="hosted-probe", daemon=True) for i, s in enumerate(sources)]
    for worker in workers:
        worker.start()
    for worker in workers:
        worker.join(100)
    out = [item for item in results if item]
    log.write("出口检测：" + "，".join("%s=%s" % (i["name"], (i.get("egress") or {}).get("ip") or i.get("error") or "未查到") for i in out))
    return out


def move_to_background(record, source, siblings):
    """把 VS Code 里正开着的会话转到后台运行（同 Mac 版 Hosted.moveToBackground）：先请 watcher 接手（照这个会话自己的网络设置、
    等它退出），再关掉 VS Code 里的标签，watcher 等那边的 claude 退出后在后台接着这段对话。返回 (成功, 说明)"""
    if record.activity in ("busy", "waiting"):
        return False, "Claude 正在处理这个会话。为免打断，请在这一轮完成后再转到后台运行"
    snap = record.snap
    log.write("会话「%s」转到后台运行：先关掉 VS Code 中的标签，watcher 接着这段对话" % snap.get("name"))
    box = {}

    def start():
        try:
            box["reply"] = source.request({"cmd": "hosted_start", "cwd": snap.get("cwd") or "", "prompt": "", "submit": False,
                                           "sessionId": snap.get("sessionId"), "takeOver": True,
                                           "netEnv": remotessh.claude_environment()}, timeout=90)
        except Exception as exc:  # noqa: BLE001
            box["error"] = str(exc)
    worker = threading.Thread(target=start, name="hosted-move", daemon=True)
    worker.start()
    time.sleep(1.5)   # 请求先到（watcher 先记下这个会话的网络设置），再关 VS Code 里的标签；没关掉的话 watcher 等 25 秒后报「没有关闭」
    if os.environ.get("CCPULSE_TEST_NO_EDITOR") != "1":   # 测试实例不碰用户屏幕上的 VS Code：由测试脚本自己结束那边的会话
        outcome = delivery.close(record, source, siblings)
        if not outcome.ok:
            log.write("转到后台运行：关闭 VS Code 中的标签未成功：%s" % outcome["message"])
    worker.join(95)
    if "reply" in box:
        return True, "已转到后台运行"
    error = str(box.get("error") or "超时").replace("HOSTED_NETWORK：", "")
    log.write("转到后台运行未成功：%s" % error)
    return False, "未能转到后台运行：%s" % error


def launch_hosted(cwd, prompt, submit, session_id, source):
    """远端项目不开 VS Code：请那台电脑上的 watcher 在后台起 claude（watcher/kiteline-watch.py 的 hosted_start，同 Mac 版 Hosted.start）。
    返回 (结果, None) 或 (None, 起不来的原因)"""
    payload = {"cmd": "hosted_start", "cwd": cwd, "prompt": prompt, "submit": bool(submit and prompt),
               "netEnv": remotessh.claude_environment()}
    if session_id:
        payload["sessionId"] = session_id
    log.write("新会话：在 %s 后台运行 Claude Code（%s）%s" % (getattr(source, "name", ""), cwd, "，恢复 %s" % session_id if session_id else ""))
    try:
        reply = source.request(payload, timeout=70)
    except Exception as exc:  # noqa: BLE001
        log.write("新会话：后台启动失败（%s），改在 VS Code 中打开" % exc)
        return None, str(exc)
    submitted = bool(reply.get("submitted"))
    if not prompt:
        message = "已在后台恢复对话" if session_id else "已在后台新建会话"
    elif submitted:
        message = "已在后台恢复对话并提交" if session_id else "已在后台新建会话并提交"
    else:
        message = "已在后台恢复对话，内容已填入输入框" if session_id else "已在后台新建会话，内容已填入输入框"
    log.write("新会话：后台会话 %s 已就绪（%s）" % (reply.get("hosted"), reply.get("sessionId")))
    return {"ok": True, "submitted": submitted, "openedWindow": False, "message": message, "error": "", "cwd": cwd,
            "sessionId": reply.get("sessionId")}, None


def hosted_note(reason):
    """退回 VS Code 时要不要告诉用户为什么：不支持、没装 claude、旧 watcher 的不说（本来就该开 VS Code）"""
    reason = str(reason or "")
    # 网络检查没过（拿不到 VS Code 那边的网络设置、起来后核对不一致）：要告诉用户，出口不能悄悄换
    if reason.startswith("HOSTED_NETWORK："):
        return "%s，已改在 VS Code 中打开" % reason[len("HOSTED_NETWORK："):].split("\n")[0]
    if reason.startswith("HOSTED_") or "未知请求" in reason or "离线" in reason or "未连接" in reason:
        return None
    return "后台启动未成功：%s，已改在 VS Code 中打开" % reason.split("\n")[0]


def launch_session(cwd, prompt, submit, session_id, source_kind, source_name="本机", started=None, source=None, notify=None, done=None,
                   in_editor=False):
    """在项目的 VS Code 窗口里新开（或恢复）一个 Claude Code 会话，内容预填进输入框；submit 时再按回车。
    先回一个结果（新标签加载要十几秒，手机的请求等不了），提交在后台做；done(提交上了没有) 在后台做完时调（同 Mac 版 NewSession 的 completion）。
    远端（Remote-SSH）项目用 vscode-remote 地址开窗口（VS Code 没开着也行），开之前先把 Remote-SSH 准备好（见 remotessh）。
    远端项目默认先在那台电脑上后台运行 Claude Code、不开 VS Code（launch_hosted），起不来再开 VS Code；in_editor = 一定开 VS Code"""
    if not in_editor and source_kind == "ssh" and source is not None and not delivery.DRY_RUN and HOSTED_SETTING[0](source.id):
        box = {}
        worker = threading.Thread(target=lambda: box.update(zip(("result", "reason"), launch_hosted(cwd, prompt, submit, session_id, source))),
                                  name="hosted-start", daemon=True)
        worker.start()
        worker.join(8)   # 一般两三秒就起来；手机那边的请求只等 12 秒
        if not worker.is_alive():
            if box.get("result"):
                if done:
                    done(box["result"]["submitted"])
                return box["result"]
            if os.environ.get("CCPULSE_TEST_NO_EDITOR") == "1":   # 测试实例：不退回 VS Code（不然会在用户屏幕上开窗口）
                message = "（测试）后台启动失败：%s" % box.get("reason")
                return {"ok": False, "submitted": False, "openedWindow": False, "message": message, "error": message, "cwd": cwd}
            result = launch_session(cwd, prompt, submit, session_id, source_kind, source_name, started, source, notify, done, in_editor=True)
            note = hosted_note(box.get("reason"))
            if note:
                result["message"] = (result.get("message") or "") + "（%s）" % note
            return result

        def finish():
            # 还没起来：先回了「将自动提交」，等结果；起不来就改开 VS Code（结果靠 notify / done 交代）
            worker.join()
            if box.get("result"):
                if done:
                    done(box["result"]["submitted"])
                return
            result = launch_session(cwd, prompt, submit, session_id, source_kind, source_name, started, source, notify, done, in_editor=True)
            if not result.get("ok") and notify and submit and prompt:
                notify(result.get("message") or "")
        threading.Thread(target=finish, name="hosted-wait", daemon=True).start()
        return {"ok": True, "submitted": bool(submit and prompt), "openedWindow": False, "error": "", "cwd": cwd,
                "message": "正在后台启动 Claude Code，启动后将自动提交" if submit and prompt else "正在后台启动 Claude Code"}
    if delivery.DRY_RUN:
        what = "恢复会话 %s" % session_id if session_id else "新会话"
        log.write("[dry-run] %s %s:%s（submit=%s）：%s" % (what, source_name, cwd, "true" if submit else "false", prompt[:120]))
        return {"ok": True, "submitted": submit, "openedWindow": False, "message": "dry-run", "error": "", "cwd": cwd}
    code = code_command()
    if not code:
        return {"ok": False, "submitted": False, "openedWindow": False, "message": "未找到 VS Code 命令行（code）", "error": "未找到 VS Code 命令行（code）", "cwd": cwd}
    remote = source_kind == "ssh"
    source_config = getattr(source, "config", None) or {}
    if remote and not source_config.get("sshHost"):
        return {"ok": False, "submitted": False, "openedWindow": False, "message": "此远端来源未配置主机地址", "error": "此远端来源未配置主机地址", "cwd": cwd}
    # 开窗口、开标签都会把 VS Code 切到前台：做完把前台还给用户原来在用的窗口（同 Mac 版；Wayland 下系统不让切别的窗口）
    front_backend = _front_backend()
    front = front_backend.capture_front() if front_backend else None
    notes = []
    # 扩展链接免确认（见 remotessh.trust_claude_links）。写不进设置的链接照开（人在电脑前点一下就行），
    # 但不自动提交、前台留在 VS Code（切走的话框会被盖住），先回的话里就说明。Linux 装了配套扩展的不走链接，不用管
    link_trusted, link_wrote = remotessh.trust_claude_links()
    if not link_trusted and config.IS_LINUX:
        from . import bridge
        link_trusted = bridge.installed()
    # 新开的窗口没信任过：VS Code 以受限模式打开（顶上挂横幅、不弹框），Claude Code 扩展不运行，先回的话里就说明
    if remotessh.workspace_trust_enabled() and not _project_window_open(cwd, remote):
        notes.append("如果电脑上的 VS Code 以受限模式打开了此项目，请点击顶部横幅中的「管理」并信任此文件夹，Claude Code 扩展只在受信任的文件夹中运行")

    def open_window():
        """打开（已开着的就切到）项目窗口。返回 None = 开了，否则是原因。
        虚拟屏幕开着时，新开的窗口出来后挪过去（VS Code 是这次拉起来的，恢复出来的窗口一起挪；同 Mac 版）。
        项目窗口本来就开着的不动：在虚拟屏幕上的还在那，用户挪回来看的留给用户"""
        if vscreen.state()["on"] and not _project_window_open(cwd, remote):
            vscreen.adopt_new_windows(os.path.basename(cwd.rstrip("\\/")), remote, not vscreen._editors())
        if config.IS_LINUX and not remote:
            # 项目窗口已经开着（配套扩展认得出来）：不再跑 code 命令，直接经扩展新开会话。
            # GNOME Wayland 下 code 命令会让 VS Code 之后不认外部切过来的焦点，新任务就没法自动提交（10-24 实测）
            from . import bridge
            if bridge.installed() and bridge.window_for_cwd(cwd, only_match=True):
                return None
        args = [code, "--skip-welcome", cwd]
        if remote:
            problem, note = remotessh.prepare(code, source_config, getattr(source, "platform", None))
            if problem:
                return problem
            if note:
                notes.append(note)
            args = [code, "--skip-welcome", "--folder-uri", remotessh.folder_uri(source_config["sshHost"], source_config.get("sshPort"), cwd)]
        try:
            subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             **({"creationflags": 0x08000000} if config.IS_WINDOWS else {"env": vscode_a11y.launch_env()}))
        except OSError as exc:
            return str(exc)
        return None

    # 本机还没装 Remote-SSH 扩展：装要十几秒，手机的请求等不了，连开窗口一起放到后台
    deferred = remote and not remotessh.extension_installed()
    if not deferred:
        problem = open_window()
        if problem:
            return {"ok": False, "submitted": False, "openedWindow": False, "message": problem, "error": problem, "cwd": cwd}

    outcome = {"submitted": False}

    def later():
        # 这段时间 VS Code 跳到前台是 Kiteline 切的（等新标签、按回车），虚拟屏幕别当成用户要看它
        try:
            with vscreen.busy():
                later_steps()
        finally:
            if done:
                done(outcome["submitted"])

    def failed(message):
        """先回给手机的是「将自动提交」，后面没做成：推一条提醒，不然手机上一直以为在跑"""
        if notify and submit and prompt:
            try:
                notify(message)
            except Exception:  # noqa: BLE001
                pass

    def later_steps():
        try:
            if deferred:
                problem = open_window()
                if problem:
                    log.write("新任务未能打开远端项目窗口：%s" % problem)
                    failed(problem)
                    return
            submit_later()
        finally:
            if front_backend and link_trusted:
                front_backend.return_front(front, 1.0)

    def submit_later():
        # 远端窗口要等它建出来再发扩展链接（窗口还在连远端时发的链接 VS Code 会先存着，连好再交给扩展，10-23 实测）
        send_at = time.time() + (10 if remote else 4)
        if remote and hasattr(source, "_ssh"):
            # 远端窗口里 Claude Code 扩展跑在远端：没装时扩展链接会被悄悄丢掉，先装上（和上面的等待同时算）
            state, reason = remotessh.ensure_remote_claude(source._ssh())
            if state == "failed":
                log.write("新任务未能新建会话：远端主机未安装 Claude Code 扩展，自动安装失败（%s），请在 VS Code 中为该主机安装" % reason)
                failed("远端主机未安装 Claude Code 扩展，自动安装失败。请在 VS Code 中为该主机安装后重新发送")
                return
            if state == "installed":
                send_at = max(send_at, time.time() + 5)   # 刚装上的扩展，窗口要过几秒才认出来
        time.sleep(max(0, send_at - time.time()))
        # Linux 装了配套扩展：经扩展新开会话、按回车（Wayland 上只能这样；X11 上也比按窗口标题找更稳）
        if config.IS_LINUX:
            from . import bridge, delivery_bridge
            if bridge.installed() and delivery_bridge.launch(cwd, prompt, submit, session_id, started, wait=90 if remote else 24, outcome=outcome):
                return
        if link_wrote:
            time.sleep(1.0)   # 刚写进设置的，VS Code 要一会儿才读到
        # Windows 打开协议链接时会先解码一次：内容多编一层，不然 + 变空格、& 之后被截掉
        open_url(delivery.editor_link(session_id, "vscode", prompt or None, shell_decodes=config.IS_WINDOWS))
        if not link_trusted:
            log.write("新任务：VS Code 会先弹确认框（未能预先信任 Claude Code 扩展的链接），不自动提交，前台留在 VS Code")
            return
        if not (submit and prompt) or delivery.DRY_RUN:
            return
        folder = os.path.basename(cwd.rstrip("\\/"))
        # 新标签加载要几秒到十几秒：最多等 20 秒，把项目窗口切到前台、前台确实是这个项目里的会话标签再回车。
        # 只看窗口标题里有没有项目名不够：前台是项目里某个文件时，回车会把换行打进文件
        # started：核实提交生效（这个目录下有会话开始运行）。回车可能落空（输入框还没就绪、焦点在扩展弹出的提示卡片上），
        # 落空时输入框里内容还在，再按一次也只会提交一次
        try:
            presses = 0
            # 远端窗口第一次连要装服务端，会话标签出来得慢：多等一会
            for _ in range(45 if remote else 14):
                time.sleep(2)
                if config.IS_WINDOWS:
                    from . import delivery_win as backend
                    backend.raise_window(cwd, remote)
                    time.sleep(0.4)
                else:
                    from . import delivery_x11 as backend
                tab, project = delivery.split_title(backend.foreground_editor_title() or "")
                if project != folder or not (tab == "Claude Code" or session_id):
                    continue
                # 远端窗口的会话面板要从远端加载，标签标题出来时输入框常常还没就绪：多等一会再按
                time.sleep(3.0 if remote else 1.0)
                cleared = None
                if config.IS_WINDOWS:
                    # 标签切过来了，键盘焦点却可能不在输入框里（11-01 Win11 实测：新开的窗口焦点停在标签上，两次回车都落空）：
                    # 先把光标放进这个会话的输入框（同发消息；Mac 版 ClaudeInput.submit 直接找输入框）；放不进去的这一轮不按
                    from . import uia_win
                    hwnd = backend.user32.GetForegroundWindow()
                    titles = [tab] if tab else []
                    at, _ = uia_win.ensure_focus(hwnd, titles, need_input=True)
                    if at == "elsewhere":
                        continue
                    before = uia_win.input_text(hwnd, titles) if at == "input" else None
                    if before and delivery.normalized(prompt)[:24] in before:
                        # 回车后输入框里不再是这段话也算提交上：回得快的会话（几百毫秒就答完）看不到「开始运行」
                        def cleared():
                            now = uia_win.input_text(hwnd, titles)
                            return now is not None and delivery.submitted_from(now, before, prompt)
                    backend._tap(backend.VK_RETURN)
                else:
                    backend._key("Return")
                presses += 1
                if started is None:
                    log.write("新任务已按回车提交（%s）" % folder)
                    outcome["submitted"] = True
                    return
                for _ in range(8):
                    time.sleep(1)
                    if started():
                        log.write("新任务已提交，会话已开始运行（%s）" % folder)
                        outcome["submitted"] = True
                        return
                    if cleared and cleared():
                        log.write("新任务已提交，输入框已清空（%s）" % folder)
                        outcome["submitted"] = True
                        return
                if presses >= (4 if remote else 2):
                    break
                log.write("新任务按了回车但会话未开始运行，再试一次（%s）" % folder)
            log.write("新任务未能自动提交：「%s」的 VS Code 会话标签不在前台或回车未生效，内容已填入输入框，需在 VS Code 中按回车" % folder)
            failed("已在 VS Code 中新建会话，内容已填入输入框，但未能自动提交。请在电脑上按回车键提交")
        except Exception as exc:  # noqa: BLE001
            log.write("新任务自动提交失败：%s" % exc)
            failed("已在 VS Code 中新建会话，内容已填入输入框，但未能自动提交。请在电脑上按回车键提交")
    threading.Thread(target=later, daemon=True).start()
    # 整句写出来，别把「新建会话」拼进去：英文按整句查表，拼出来的会被当成按钮名翻成「New Session」（同 Mac 版）
    if not link_trusted:
        message = ("电脑上的 VS Code 将弹出确认框，询问是否允许 Claude Code 扩展打开链接。请在电脑上勾选「不再询问」并点击「打开」，会话即会打开"
                   if not prompt else
                   "电脑上的 VS Code 将弹出确认框，询问是否允许 Claude Code 扩展打开链接。请在电脑上勾选「不再询问」并点击「打开」，会话打开后内容会填入输入框，按回车键即可提交")
        for note in notes:
            message += "。提醒：" + note
        return {"ok": False, "submitted": False, "openedWindow": True, "message": message, "error": message, "cwd": cwd}
    if deferred:
        message = ("正在为 VS Code 安装 Remote-SSH 扩展，安装后将打开项目窗口并恢复对话" if session_id else
                   "正在为 VS Code 安装 Remote-SSH 扩展，安装后将打开项目窗口并新建会话")
    else:
        message = "已在 VS Code 中恢复对话，内容已填入输入框" if session_id else "已在 VS Code 中新建会话，内容已填入输入框"
    message += "，将自动提交" if submit and prompt else ""
    for note in notes:
        message += "。提醒：" + note
    return {"ok": True, "submitted": False, "openedWindow": True, "message": message, "error": "", "cwd": cwd}
