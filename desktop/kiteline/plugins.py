"""Agent 插件（规范见 docs/agent-plugins.md；同 Mac 版 Sources/PluginStore.swift）：官方插件索引、下载校验安装、
自动更新、出错退回、出错报告。

- 插件装在 watcher 的数据目录里（默认 ~/.ccpulse/plugins/<id>/：plugin.json、plugin.py、assets/），watcher 启动时加载；
  装好、退回、开关变了都重启各来源的 watcher。Remote-SSH 来源连接时把整个插件目录一起传过去（远端不一定能上外网）。
- 索引（官网 /plugins/index.json）由我们用 Ed25519 签名（index.json.sig），公钥内置在这里；签名不对整份不用。
  索引里每个版本带 sha256，下载的插件包对不上就不装。
- 偏好（关掉的、等 Kiteline 更新完再装的、不再询问的出错、出过错的版本、手动移除过的）存在配置目录的 plugins.json。
"""

import base64
import hashlib
import io
import json
import os
import shutil
import sys
import tarfile
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

from . import config, log

PUBLIC_KEY = os.environ.get("CCPULSE_PLUGIN_PUBKEY") or "s4KGWh096KRYLEJjH8NBNISLLqQy4QJwhAT81/sbzu8="
INDEX_URL = os.environ.get("CCPULSE_PLUGIN_INDEX") or config.BUILTIN_RELAY + "/plugins/index.json"
CHECK_EVERY = 6 * 3600
FIRST_CHECK = 20
REPORT_TO = "hon6@foxmail.com"
APP_KEY = "desktop"   # 索引里 minApp 的键：Windows / Linux 电脑端共用一个版本号


def plugins_dir():
    """和 watcher 的 PLUGINS_DIR 同一个算法（本机 watcher 继承这个进程的环境变量）"""
    data = os.environ.get("CCPULSE_DATA_DIR") or os.path.join(os.path.expanduser("~"), ".ccpulse")
    return os.environ.get("CCPULSE_PLUGINS_DIR") or os.path.join(data, "plugins")


def version_tuple(text):
    parts = []
    for piece in str(text or "0").replace("-", ".").replace("+", ".").split(".")[:4]:
        digits = "".join(ch for ch in piece if ch.isdigit())
        parts.append(int(digits) if digits else 0)
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def verify(data, signature_text, public_key=None):
    """Ed25519 签名对不对（索引）"""
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    try:
        key = Ed25519PublicKey.from_public_bytes(base64.b64decode(public_key or PUBLIC_KEY))
        key.verify(base64.b64decode((signature_text or "").strip()), data)
        return True
    except (InvalidSignature, ValueError, TypeError):
        return False


def fetch(url, timeout=20):
    request = urllib.request.Request(url, headers={"User-Agent": config.USER_AGENT, "Cache-Control": "no-cache"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def read_manifest(folder):
    try:
        with open(os.path.join(folder, "plugin.json"), encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def detected_by_spec(spec):
    """索引里给没装插件的 agent 写的简单检测：有这些目录 / 命令之一就算装了"""
    if not isinstance(spec, dict):
        return False
    if spec.get("always") is True:   # 技能包：不看装没装哪家 agent，有新版就装
        return True
    if any(os.path.exists(os.path.expanduser(p)) for p in spec.get("paths") or [] if isinstance(p, str)):
        return True
    return any(shutil.which(c) for c in spec.get("commands") or [] if isinstance(c, str))


def bundle(root=None):
    """整个插件目录打成 tar.gz（远端部署用）→ (字节, 指纹)；没有插件时字节是空的"""
    root = root or plugins_dir()
    buffer = io.BytesIO()
    digest = hashlib.sha256()
    names = []
    try:
        names = sorted(n for n in os.listdir(root) if not n.startswith(".") and os.path.isfile(os.path.join(root, n, "plugin.json")))
    except OSError:
        pass
    if not names:
        return b"", "none"
    with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
        for name in names:
            for base, dirs, files in os.walk(os.path.join(root, name)):
                dirs[:] = sorted(d for d in dirs if d != "__pycache__")
                for file_name in sorted(files):
                    full = os.path.join(base, file_name)
                    arc = os.path.relpath(full, root).replace(os.sep, "/")
                    with open(full, "rb") as handle:
                        digest.update(arc.encode() + b"\0" + handle.read())
                    tar.add(full, arcname=arc, recursive=False)
    return buffer.getvalue(), digest.hexdigest()[:16]


# 远端：本机同步过去的插件单独放一个目录（远端自己也装了 Kiteline 时，它管的 ~/.ccpulse/plugins 不受影响），
# 经 SSH 拉起的远端 watcher 用这个环境变量去读
REMOTE_DIR_ENV = 'CCPULSE_PLUGINS_DIR="$HOME/.ccpulse/synced-plugins"'

# 远端解包：从标准输入读 base64 的 tar.gz，换掉 ~/.ccpulse/synced-plugins（空的就清空），写指纹。经 python -c 跑
REMOTE_UNPACK = r'''
import base64, io, os, shutil, sys, tarfile
root = os.path.join(os.path.expanduser("~"), ".ccpulse", "synced-plugins")
data = base64.b64decode(sys.stdin.read())
fresh = root + ".new"
shutil.rmtree(fresh, ignore_errors=True)
os.makedirs(fresh)
if data:
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
        for member in tar.getmembers():
            target = os.path.realpath(os.path.join(fresh, member.name))
            if not target.startswith(os.path.realpath(fresh) + os.sep) or not (member.isfile() or member.isdir()):
                raise SystemExit("bad member %s" % member.name)
        tar.extractall(fresh)
shutil.rmtree(root, ignore_errors=True)
os.rename(fresh, root)
open(os.path.join(root, ".sync"), "w").write(sys.argv[1])
print("PLUGINS_OK")
'''


def remote_unpack_command(python, fingerprint):
    code = base64.b64encode(REMOTE_UNPACK.encode()).decode()
    return "%s -c \"import base64;exec(base64.b64decode('%s'))\" %s" % (python, code, fingerprint)


def remote_check_command():
    return "cat ~/.ccpulse/synced-plugins/.sync 2>/dev/null || echo none"


def agent_cards(rows):
    """插件行（索引条目、watcher 报的）→ [{id, name, speaker?, mark?, minApp?}]，同一个 id 后面的盖过前面的。
    minApp 只有 watcher 报的（装着的那个版本）才有：手机版本低于 minApp.ios 时提示去 App Store 更新"""
    cards = {}
    for row in rows:
        if row.get("id") and row.get("name"):
            card = {"id": row["id"], "name": row["name"]}
            for field in ("speaker", "mark"):
                if row.get(field):
                    card[field] = row[field]
            if isinstance(row.get("minApp"), dict) and "versions" not in row:
                card["minApp"] = row["minApp"]
            cards[row["id"]] = card
    return list(cards.values())


class PluginStore:
    def __init__(self, app):
        self.app = app
        self.lock = threading.RLock()
        self.prefs_path = config.path("plugins.json")
        self.index_path = config.path("plugins-index.json")
        prefs = config.read_json(self.prefs_path, {})
        # on：默认不接（optIn）、用户自己打开了的；held：用户手动移除过（恢复内置版本）的，不再自动装回来，直到再手动装一次；
        # flags：做过的一次性迁移；options：用户打开了的插件单项开关「插件 id.开关 id」（默认都关）
        self.prefs = {key: list(prefs.get(key) or []) for key in ("off", "on", "pending", "muted", "bad", "held", "flags", "options")}
        cached = config.read_json(self.index_path, {})
        self.index = cached if isinstance(cached, dict) and cached.get("plugins") else {"plugins": []}
        self.local = {"plugins": [], "hostCaps": None}
        self.cards = {}           # 各台机器的 watcher 报来的插件（名称、称呼、标志），给手机的 agents 用
        self.checked_at = 0
        self.error = ""
        self.phase = "idle"       # idle / checking
        self.busy = {}            # id → installing / removing
        self.errors = []          # 最近的出错（设置页「报告问题」、客户端弹窗）
        self._stop = False
        self._migrate()
        self._apply_env()

    def _migrate(self):
        """以前「通用」里有「为 OpenCode 安装 Kiteline 插件」开关，现在统一在插件页：关着的转成插件页里关掉 OpenCode（只转一次）"""
        if "opencode-switch" in self.prefs["flags"]:
            return
        self.prefs["flags"].append("opencode-switch")
        cfg = getattr(self.app, "cfg", None)
        if cfg is not None and not cfg.mobile.get("installOpenCodePlugin", True) and "opencode" not in self.prefs["off"]:
            self.prefs["off"].append("opencode")
        self._save_prefs()

    # MARK: 偏好

    def _save_prefs(self):
        config.write_private(self.prefs_path, json.dumps(self.prefs, ensure_ascii=False, indent=2))
        self._apply_env()

    def _apply_env(self):
        """关掉的、自己打开了的（默认不接的）插件随 watcher 的环境变量带过去（本机和远端都是）"""
        from . import watcher
        watcher.PLUGINS_OFF = ",".join(sorted(self.off_ids()))
        watcher.PLUGINS_ON = ",".join(sorted(self.prefs["on"]))
        watcher.PLUGIN_OPTIONS_ON = ",".join(sorted(self.prefs["options"]))

    def off_ids(self):
        return set(self.prefs["off"])

    def watcher_env(self):
        env = {}
        if self.prefs["off"]:
            env["CCPULSE_PLUGINS_OFF"] = ",".join(sorted(self.off_ids()))
        if self.prefs["on"]:
            env["CCPULSE_PLUGINS_ON"] = ",".join(sorted(self.prefs["on"]))
        if self.prefs["options"]:
            env["CCPULSE_PLUGIN_OPTIONS_ON"] = ",".join(sorted(self.prefs["options"]))
        return env

    def opt_in(self, plugin_id):
        """不是那家 agent 开放的接入方式：默认不接，打开前给用户看的说明（watcher 报的为准，没装的看索引）"""
        with self.lock:
            row = next((r for r in self.local.get("plugins") or [] if r.get("id") == plugin_id), None) or {}
            entry = next((e for e in self.index.get("plugins") or [] if isinstance(e, dict) and e.get("id") == plugin_id), None) or {}
        return (row.get("optIn") or entry.get("optIn") or None), (row.get("optInEn") or entry.get("optInEn") or None)

    def _reconnect(self):
        """插件变了：各来源换个 watcher 进程载入（会话照旧显示、不报离线），过几秒再问一遍状态，设置页上的版本、能力、装在哪跟着更新"""
        self.app.reconnect_sources(seamless=True)
        timer = threading.Timer(8, self.refresh_local)
        timer.daemon = True
        timer.start()

    # MARK: 后台检查

    def start(self):
        threading.Thread(target=self._loop, name="plugins", daemon=True).start()

    def _loop(self):
        time.sleep(FIRST_CHECK)
        while not self._stop:
            try:
                self.check(auto=True)
            except Exception as exc:  # noqa: BLE001
                log.write("检查插件更新出错：%r" % exc)
            time.sleep(CHECK_EVERY)

    def fetch_index(self):
        try:
            data = fetch(INDEX_URL)
        except urllib.error.HTTPError as exc:
            if exc.code != 404:
                raise
            # 官网还没发布插件索引：当作暂无可更新的插件，不算出错
            with self.lock:
                self.index = {"plugins": []}
            return self.index
        signature = fetch(INDEX_URL + ".sig").decode("ascii", "replace")
        if not verify(data, signature):
            raise RuntimeError("插件索引的签名不对，已忽略")
        index = json.loads(data.decode("utf-8"))
        if not isinstance(index, dict) or not isinstance(index.get("plugins"), list):
            raise RuntimeError("插件索引格式不对")
        with self.lock:
            self.index = index
        config.write_private(self.index_path, json.dumps(index, ensure_ascii=False))
        return index

    def refresh_local(self):
        """问每台在线机器（本机和 Remote-SSH 远端）的 watcher：插件的版本、状态、能力，那台机器上装没装各家 agent；
        还没装的插件按索引里的检测规则问。版本、能力、中台能力以本机为准，「装在哪」合起来"""
        sources = [s for s in list(self.app.store.sources.values()) if s.live]
        with self.lock:
            specs = {e.get("id"): e.get("detect") for e in self.index.get("plugins") or [] if isinstance(e, dict) and e.get("detect")}
        rows, caps, where, cards = None, None, {}, {}
        for source in sorted(sources, key=lambda s: s.id != "local"):
            try:
                reply = source.request({"cmd": "plugins"}, timeout=15)
            except Exception as exc:  # noqa: BLE001
                log.write("取 %s 的插件状态失败：%s" % (source.name, exc))
                continue
            if source.id == "local" or rows is None:
                rows, caps = reply.get("plugins") or [], reply.get("hostCaps")
            for row in reply.get("plugins") or []:
                cards.setdefault(row.get("id"), row)
            for row in reply.get("plugins") or []:
                if isinstance(row.get("detect"), dict) and row["detect"].get("installed"):
                    where.setdefault(row.get("id"), []).append(source.id)
            if specs:
                try:
                    found = source.request({"cmd": "detect", "specs": specs}, timeout=10).get("found") or {}
                except Exception:  # noqa: BLE001 —— 旧版 watcher 不认这个请求
                    found = {}
                for plugin_id, ok in found.items():
                    if ok and source.id not in where.setdefault(plugin_id, []):
                        where[plugin_id].append(source.id)
        if rows is not None:
            names = {s.id: s.name for s in sources}
            with self.lock:
                self.cards = cards
                self.local = {"plugins": rows, "hostCaps": caps,
                              "where": {pid: [names.get(sid, sid) if sid != "local" else "local" for sid in ids] for pid, ids in where.items()}}
        return self.local

    def agent_cards(self):
        """手机 /api/state 的 agents：各插件的 agent 名称、称呼、标志（watcher 报的盖过索引里的）"""
        with self.lock:
            rows = [e for e in self.index.get("plugins") or [] if isinstance(e, dict)] + list(self.cards.values())
        return agent_cards(rows)

    def check(self, auto=False):
        """查一次：拉索引、问本机状态；auto 时把能自动装的（已启用插件的新版本、等更新完再装的）装上"""
        with self.lock:
            if self.phase == "checking":
                return self.state()
            self.phase = "checking"
        try:
            try:
                self.fetch_index()
                self.error = ""
            except Exception as exc:  # noqa: BLE001
                self.error = str(exc) if "签名" in str(exc) or "格式" in str(exc) else "连不上插件服务器"
                log.write("取插件索引失败：%s" % exc)
            self.checked_at = time.time()
            self.refresh_local()
            # 我们吊销了本机装着的版本：退回上一版本（没有就回到内置的），并记成坏版本
            withdrawn = self._withdrawn()
            for plugin_id, version in withdrawn:
                log.write("插件 %s %s 已被吊销，退回" % (plugin_id, version))
                self.rollback(plugin_id, bad_version=version, restart=False)
            if withdrawn:
                self._reconnect()
            if auto:
                installed = False
                for row in self.rows():
                    if row["action"] in ("update", "install") and row["enabled"] and row["autoInstall"]:
                        installed = self.install(row["id"], restart=False, quiet=True).get("ok") or installed
                if installed:
                    self._reconnect()
        finally:
            with self.lock:
                self.phase = "idle"
        return self.state()

    # MARK: 给设置页的一行行

    def _latest(self, entry, host_caps):
        """索引里这个插件能用的最新版本：(最新版本, 本机能装的最新版本)。吊销的、出过错的不算"""
        versions = [v for v in entry.get("versions") or [] if isinstance(v, dict) and not v.get("revoked")
                    and "%s@%s" % (entry.get("id"), v.get("version")) not in self.prefs["bad"]]
        versions.sort(key=lambda v: version_tuple(v.get("version")), reverse=True)
        newest = versions[0] if versions else None
        usable = next((v for v in versions if self._fits(v, host_caps)), None)
        return newest, usable

    def _fits(self, version, host_caps):
        needs = version.get("needs") or []
        if host_caps is not None and any(cap not in host_caps for cap in needs):
            return False
        minimum = (version.get("minApp") or {}).get(APP_KEY)
        return not minimum or version_tuple(self.app.version) >= version_tuple(minimum)

    def rows(self):
        with self.lock:
            local = {row.get("id"): row for row in self.local.get("plugins") or []}
            index = {entry.get("id"): entry for entry in self.index.get("plugins") or [] if isinstance(entry, dict)}
            host_caps = self.local.get("hostCaps")
        external = {name: read_manifest(os.path.join(plugins_dir(), name)) for name in self._installed_ids()}
        out = []
        for plugin_id in list(dict.fromkeys(list(local) + list(index))):
            row = local.get(plugin_id) or {}
            entry = index.get(plugin_id) or {}
            newest, usable = self._latest(entry, host_caps)
            current = row.get("version") or ((external.get(plugin_id) or {}).get("version"))
            detect = row.get("detect") if isinstance(row.get("detect"), dict) else None
            # 装在哪：local = 本机，其余是 Remote-SSH 远端的名字（watcher 太旧问不到时，本机按检测规则自己看）
            detected_on = list((self.local.get("where") or {}).get(plugin_id) or [])
            if not detected_on and ((detect or {}).get("installed") or (not detect and detected_by_spec(entry.get("detect")))):
                detected_on = ["local"]
            detected = bool(detected_on)
            action, target = None, None
            if newest and (current is None or version_tuple(newest.get("version")) > version_tuple(current)):
                if usable and (current is None or version_tuple(usable.get("version")) > version_tuple(current)):
                    action, target = ("update" if current else "install"), usable
                else:
                    action, target = "needsApp", newest
            status = row.get("status") or ("ok" if current else "absent")
            opt_in = row.get("optIn") or entry.get("optIn") or None
            out.append({
                "id": plugin_id,
                "name": row.get("name") or entry.get("name") or plugin_id,
                "summary": entry.get("summary") or "",
                "summaryEn": entry.get("summaryEn") or "",
                "version": current,
                "source": row.get("source") or ("external" if plugin_id in external else None),
                "status": status,
                "error": row.get("error") or "",
                "missing": row.get("missing") or [],
                "abilities": row.get("abilities") or [],
                # 各平台、各形态能做到什么（兼容表）：装着的以 watcher 报的为准，没装的看索引
                "support": row.get("support") or entry.get("support") or {},
                "detect": detect,
                "detected": detected,
                "detectedOn": detected_on,
                "enabled": plugin_id not in self.off_ids() and (not opt_in or plugin_id in self.prefs["on"]),
                "optIn": opt_in,
                "optInEn": row.get("optInEn") or entry.get("optInEn") or None,
                # 单项开关（默认关、要读那家凭证的那几项）：[{id, name, nameEn, note, noteEn, on}]，开没开以这边的偏好为准
                "options": [dict(option, on="%s.%s" % (plugin_id, option.get("id")) in self.prefs["options"])
                            for option in (row.get("options") or entry.get("options") or []) if isinstance(option, dict) and option.get("id")],
                # 额度、余额能不能显示、为什么没有（每个插件一句，规范 4.5）
                "limitsNote": row.get("limitsNote") or entry.get("limitsNote") or None,
                "limitsNoteEn": row.get("limitsNoteEn") or entry.get("limitsNoteEn") or None,
                # 功能缺口：[{kind: unsupported 确定做不到 / untested 还没实测, text, textEn}]
                "gaps": row.get("gaps") or entry.get("gaps") or [],
                "action": action,
                "target": target and {k: target.get(k) for k in ("version", "notes", "notesEn", "minApp", "size")},
                "pending": plugin_id in self.prefs["pending"],
                "busy": self.busy.get(plugin_id),
                # 自动装：已经在用的插件出新版本，或新 agent 的插件且本机检测到了这家 agent
                "autoInstall": (bool(current) or detected or plugin_id in self.prefs["pending"]) and plugin_id not in self.prefs["held"],
                "held": plugin_id in self.prefs["held"],
                "canRemove": plugin_id in external,
                # agent：一家 agent 的插件；skills：技能包（只有数据，watcher 照着给各家 agent 装技能，插件页不列）
                "kind": entry.get("kind") or "agent",
            })
        out.sort(key=lambda r: (not r["detected"], r["name"].lower()))
        return out

    def _withdrawn(self):
        """本机装着、但在索引里被吊销的版本 → [(id, 版本)]"""
        with self.lock:
            index = {e.get("id"): e for e in self.index.get("plugins") or [] if isinstance(e, dict)}
        out = []
        for plugin_id in self._installed_ids():
            version = str((read_manifest(os.path.join(plugins_dir(), plugin_id)) or {}).get("version") or "")
            entry = index.get(plugin_id) or {}
            if any(v.get("revoked") and str(v.get("version")) == version for v in entry.get("versions") or [] if isinstance(v, dict)):
                out.append((plugin_id, version))
        return out

    def _installed_ids(self):
        try:
            return [n for n in os.listdir(plugins_dir()) if not n.startswith(".") and os.path.isdir(os.path.join(plugins_dir(), n))]
        except OSError:
            return []

    def state(self):
        with self.lock:
            errors = list(self.errors)
        return {"plugins": [r for r in self.rows() if r["kind"] != "skills"], "checkedAt": int(self.checked_at * 1000), "checking": self.phase == "checking",
                "error": self.error, "errors": errors, "reportTo": REPORT_TO}

    # MARK: 装、退、开关

    def install(self, plugin_id, restart=True, quiet=False):
        """装索引里本机能用的最新版本：下载 → 核对 sha256 → 解到临时目录、核对清单 → 换上（旧的留一份在 .previous 退回用）。
        quiet 是自动更新；手动装的同时取消「手动移除过」"""
        with self.lock:
            entry = next((e for e in self.index.get("plugins") or [] if isinstance(e, dict) and e.get("id") == plugin_id), None)
            host_caps = self.local.get("hostCaps")
            if self.busy.get(plugin_id):
                return {"ok": False, "error": "正在处理"}
            self.busy[plugin_id] = "installing"
        try:
            if entry is None:
                raise RuntimeError("插件索引里没有 %s" % plugin_id)
            _, usable = self._latest(entry, host_caps)
            if usable is None:
                raise RuntimeError("需要先更新 Kiteline")
            installed = read_manifest(os.path.join(plugins_dir(), plugin_id)) or {}
            if str(installed.get("version")) == str(usable.get("version")):
                return {"ok": True, "version": usable.get("version"), "unchanged": True}   # 已经是这个版本
            url = urllib.parse.urljoin(INDEX_URL, usable.get("url") or "")
            data = fetch(url, timeout=60)
            if hashlib.sha256(data).hexdigest() != (usable.get("sha256") or "").lower():
                raise RuntimeError("下载的插件包校验不通过")
            self._unpack(plugin_id, usable.get("version"), data)
            with self.lock:
                changed = False
                for key in ("pending",) if quiet else ("pending", "held"):
                    if plugin_id in self.prefs[key]:
                        self.prefs[key].remove(plugin_id)
                        changed = True
                if changed:
                    self._save_prefs()
            log.write("已安装插件 %s %s" % (plugin_id, usable.get("version")))
            if restart:
                self._reconnect()
            return {"ok": True, "version": usable.get("version")}
        except Exception as exc:  # noqa: BLE001
            if not quiet:
                log.write("安装插件 %s 失败：%s" % (plugin_id, exc))
            return {"ok": False, "error": str(exc)}
        finally:
            with self.lock:
                self.busy.pop(plugin_id, None)

    def _unpack(self, plugin_id, version, data):
        root = plugins_dir()
        os.makedirs(root, exist_ok=True)
        staging = tempfile.mkdtemp(prefix=".new-%s-" % plugin_id, dir=root)
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                for name in archive.namelist():
                    target = os.path.realpath(os.path.join(staging, name))
                    if not target.startswith(os.path.realpath(staging) + os.sep):
                        raise RuntimeError("插件包里有不安全的路径：%s" % name)
                archive.extractall(staging)
            manifest = read_manifest(staging)
            # agent 插件要有 plugin.py；技能包（kind: skills）只有数据 skills.json
            body = "skills.json" if (manifest or {}).get("kind") == "skills" else "plugin.py"
            if not manifest or manifest.get("id") != plugin_id or str(manifest.get("version")) != str(version) \
                    or not os.path.isfile(os.path.join(staging, body)):
                raise RuntimeError("插件包内容和索引对不上")
            current = os.path.join(root, plugin_id)
            previous = os.path.join(root, ".previous", plugin_id)
            if os.path.isdir(current):
                shutil.rmtree(previous, ignore_errors=True)
                os.makedirs(os.path.dirname(previous), exist_ok=True)
                os.replace(current, previous)
            os.replace(staging, current)
        finally:
            shutil.rmtree(staging, ignore_errors=True)

    def rollback(self, plugin_id, bad_version=None, restart=True):
        """退回上一版本；没有上一版本就删掉（用内置的）。bad_version 记下来，以后不再自动装它"""
        root = plugins_dir()
        current = os.path.join(root, plugin_id)
        previous = os.path.join(root, ".previous", plugin_id)
        with self.lock:
            if bad_version and "%s@%s" % (plugin_id, bad_version) not in self.prefs["bad"]:
                self.prefs["bad"].append("%s@%s" % (plugin_id, bad_version))
                self._save_prefs()
        shutil.rmtree(current, ignore_errors=True)
        kept = str((read_manifest(previous) or {}).get("version") or "")
        if os.path.isdir(previous) and "%s@%s" % (plugin_id, kept) not in self.prefs["bad"]:
            os.replace(previous, current)
            log.write("插件 %s 已退回上一版本 %s" % (plugin_id, kept))
        else:
            shutil.rmtree(previous, ignore_errors=True)   # 上一版本也是坏的（或没有）：回到内置的
            log.write("插件 %s 已删除，改用内置版本" % plugin_id)
        if restart:
            self._reconnect()
        return {"ok": True}

    def remove(self, plugin_id):
        """删掉下载的版本，回到内置的（设置页「恢复内置版本」）；记下来，自动更新不再把它装回来"""
        with self.lock:
            if plugin_id not in self.prefs["held"]:
                self.prefs["held"].append(plugin_id)
                self._save_prefs()
        shutil.rmtree(os.path.join(plugins_dir(), plugin_id), ignore_errors=True)
        shutil.rmtree(os.path.join(plugins_dir(), ".previous", plugin_id), ignore_errors=True)
        self._reconnect()
        return {"ok": True}

    def set_enabled(self, plugin_id, enabled):
        opt_in = self.opt_in(plugin_id)[0]
        with self.lock:
            off, on = self.off_ids(), set(self.prefs["on"])
            off.discard(plugin_id)
            on.discard(plugin_id)
            # 关掉的都记；打开的只记默认不接的（其余的不在 off 里就是开着）
            if not enabled:
                off.add(plugin_id)
            elif opt_in:
                on.add(plugin_id)
            self.prefs["off"], self.prefs["on"] = sorted(off), sorted(on)
            self._save_prefs()
        cfg = getattr(self.app, "cfg", None)
        if plugin_id == "opencode" and enabled and cfg is not None and not cfg.mobile.get("installOpenCodePlugin", True):
            # 插件页打开 OpenCode = 也要往 OpenCode 里装桥接插件（旧的「通用」开关跟着打开）
            from . import watcher
            cfg.update(lambda data: data.setdefault("mobile", {}).update(installOpenCodePlugin=True))
            watcher.OPENCODE_PLUGIN = True
        log.write("插件 %s 已%s" % (plugin_id, "启用" if enabled else "关闭"))
        self._reconnect()
        return {"ok": True}

    def set_option(self, plugin_id, option_id, enabled):
        """插件的单项开关（设置 → 插件里那家下面的小开关）：打开前客户端已给用户看过说明"""
        key = "%s.%s" % (plugin_id, option_id)
        with self.lock:
            options = set(self.prefs["options"])
            (options.add if enabled else options.discard)(key)
            self.prefs["options"] = sorted(options)
            self._save_prefs()
        log.write("插件 %s 的「%s」已%s" % (plugin_id, option_id, "打开" if enabled else "关闭"))
        self._reconnect()
        return {"ok": True}

    def update_then_install(self, plugin_id):
        """插件要的能力本机 Kiteline 还没有：记下来，开始更新 Kiteline；更新完重启后自动装上"""
        with self.lock:
            if plugin_id not in self.prefs["pending"]:
                self.prefs["pending"].append(plugin_id)
                self._save_prefs()
        updater = getattr(self.app, "updater", None)
        if updater is None:
            return {"ok": False, "error": "这个版本不能自动更新，请到官网下载新版"}
        state = updater.check()
        if state.get("phase") in ("available", "error", "none"):
            state = updater.begin()
        return {"ok": True, "update": state}

    # MARK: 出错

    def on_event(self, source, event):
        kind = event.get("event")
        if kind == "plugin_retired":
            # watcher 已经换回内置的；本机的文件退回上一版本，这个版本以后不再自动装
            if source.id == "local" and os.path.isdir(os.path.join(plugins_dir(), event.get("id") or "")):
                threading.Thread(target=self.rollback, args=(event.get("id"), event.get("version")), daemon=True).start()
            return
        if kind != "plugin_error":
            return
        key = "%s@%s:%s" % (event.get("id"), event.get("version"), (event.get("error") or "")[:80])
        with self.lock:
            if key in self.prefs["muted"] or any(e["key"] == key for e in self.errors):
                return
            item = {"key": key, "id": event.get("id"), "name": event.get("name") or event.get("id"), "version": event.get("version"),
                    "source": event.get("source"), "where": event.get("where"), "error": event.get("error") or "",
                    "trace": event.get("trace") or "", "host": source.name, "at": int(time.time() * 1000)}
            self.errors = (self.errors + [item])[-20:]
        log.write("插件 %s 出错：%s" % (item["id"], item["error"]))
        server = getattr(self.app, "server", None)
        if server is not None:
            server.publish("plugin_error", {k: item[k] for k in ("key", "id", "name", "version", "error", "host", "at")})

    def mute(self, key):
        with self.lock:
            if key not in self.prefs["muted"]:
                self.prefs["muted"] = (self.prefs["muted"] + [key])[-200:]
                self._save_prefs()
            self.errors = [e for e in self.errors if e["key"] != key]
        return {"ok": True}

    def dismiss(self, key):
        with self.lock:
            self.errors = [e for e in self.errors if e["key"] != key]
        return {"ok": True}

    def report(self, key=None, plugin_id=None):
        """出错报告：mailto 链接（用户自己的邮件程序发，内容先给用户看）。不含对话内容"""
        with self.lock:
            item = next((e for e in self.errors if e["key"] == key or (plugin_id and e["id"] == plugin_id)), None)
        row = next((r for r in self.rows() if r["id"] == (item or {}).get("id", plugin_id)), {})
        lines = [
            "插件：%s %s（%s）" % (row.get("name") or plugin_id, (item or {}).get("version") or row.get("version") or "", (item or {}).get("source") or row.get("source") or ""),
            "Agent：%s" % json.dumps(row.get("detect") or {}, ensure_ascii=False),
            "Kiteline：%s %s（%s）" % ("电脑端", self.app.version, config.PLATFORM),
            "Python：%s" % sys.version.split()[0],
            "出错位置：%s" % ((item or {}).get("where") or row.get("status") or ""),
            "出错信息：%s" % ((item or {}).get("error") or row.get("error") or ""),
            "",
            ((item or {}).get("trace") or "")[-1500:],
        ]
        subject = "Kiteline 插件出错：%s %s" % (row.get("name") or plugin_id or "", (item or {}).get("version") or row.get("version") or "")
        body = "\n".join(lines).strip() + "\n"
        url = "mailto:%s?subject=%s&body=%s" % (REPORT_TO, urllib.parse.quote(subject), urllib.parse.quote(body))
        return {"ok": True, "to": REPORT_TO, "subject": subject, "body": body, "url": url}
