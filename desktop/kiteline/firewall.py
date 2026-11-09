"""防火墙：手机、别的 Kiteline 电脑连进来要用的端口有没有被拦住，一键放行（就绪检查「防火墙」一项，POST /api/readiness/fix allow-firewall）。

Windows：第一次运行时系统会问「是否允许 Kiteline 访问网络」，关掉提示框或点了「取消」，系统就给这个程序建「阻止」规则
（公用网络上默认就是这样），阻止规则比放行规则优先，局域网里的手机、别的电脑都连不进来。这里查这个程序的入站规则：
有阻止规则 = 被拦；没有任何放行规则 = 防火墙开着时多半也连不进。一键放行在电脑上弹 UAC 授权窗口，删掉这个程序的阻止规则，
加一条只放 Kiteline 端口（HTTPS、游客链接、小程序入口，再加局域网宣告 mDNS）的放行规则。
Linux：只管 ufw（Ubuntu 自带的）。开着时用 pkexec 放行这几个端口（规则文件只有 root 能读，查不出放没放过，放过就记一笔）。
请求里的内容一律不进命令：端口来自本机配置，程序路径是本进程自己。
"""

import base64
import json
import os
import shutil
import subprocess
import sys
import threading
import time

from . import config, log

RULE_NAME = "Kiteline"
_cache = {"at": 0.0, "value": None}
_lock = threading.Lock()
_busy = threading.Lock()


def program():
    """入站规则认的程序（防火墙按真正监听端口的进程认）：打包版是 kiteline.exe；开发版在 venv 里时，
    Windows 的 venv\\Scripts\\python.exe 只是个转发壳，真正跑的是基础 Python，要认它"""
    path = sys.executable
    if sys.prefix != getattr(sys, "base_prefix", sys.prefix) and getattr(sys, "_base_executable", None):
        path = sys._base_executable
    return os.path.normcase(os.path.abspath(path))


def ports(cfg):
    """Kiteline 在局域网里监听的 TCP 端口：HTTPS（手机、别的电脑）、游客链接、小程序入口"""
    m = cfg.mobile
    https = cfg.https_port()
    result = [https, int(m["port"]) + 2]
    if m.get("mpEnabled", True):
        result.append(int(m.get("mpPort") or 8768))
    return sorted(set(result))


def _powershell(script, timeout=25):
    encoded = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
    done = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded],
                          capture_output=True, timeout=timeout, creationflags=0x08000000)
    return done.stdout.decode("utf-8", "replace")


def _ps_quote(text):
    return "'" + str(text).replace("'", "''") + "'"


def _windows_status(port_list):
    script = r"""
$ErrorActionPreference = 'SilentlyContinue'
$prog = %s
$ports = @(%s)
$block = 0; $allow = 0
Get-NetFirewallApplicationFilter -Program $prog | Get-NetFirewallRule | Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' } | ForEach-Object {
  if ($_.Action -eq 'Block') { $block++ } else { $allow++ }
}
# 不限程序、按端口放行的规则（自己建的或用户手动建的）也算
Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True | Where-Object { $_.DisplayName -like 'Kiteline*' } | ForEach-Object {
  $p = ($_ | Get-NetFirewallPortFilter).LocalPort
  $hit = $true
  foreach ($x in $ports) { $ok = $false; foreach ($r in @($p)) { if ($r -eq 'Any' -or $r -eq "$x" -or ($r -match '^(\d+)-(\d+)$' -and [int]$matches[1] -le $x -and $x -le [int]$matches[2])) { $ok = $true } }; if (-not $ok) { $hit = $false } }
  if ($hit) { $allow++ }
}
$on = @(Get-NetFirewallProfile | Where-Object { $_.Enabled -eq 'True' }).Count
$cat = @(Get-NetConnectionProfile | ForEach-Object { "$($_.NetworkCategory)" }) -join ','
@{ block = $block; allow = $allow; enabled = $on; category = $cat } | ConvertTo-Json -Compress
""" % (_ps_quote(program()), ",".join(str(p) for p in port_list))
    out = _powershell(script).strip().splitlines()
    return json.loads(out[-1]) if out else None


def _ufw_enabled():
    try:
        with open("/etc/ufw/ufw.conf", encoding="utf-8") as fh:
            return any(line.strip().upper() == "ENABLED=YES" for line in fh)
    except OSError:
        return False


def _ufw_done_file():
    return config.path("firewall-allowed.json")


def status(cfg, refresh=False):
    """(level, detail)：ok / warn / bad；不适用（没有防火墙、没开）返回 None。结果缓存 1 分钟（查 Windows 规则要几秒）"""
    port_list = ports(cfg)
    with _lock:
        cached = _cache["value"]
        fresh = time.time() - _cache["at"] < 60 and cached is not None and cached[0] == port_list
    if fresh and not refresh:
        return cached[1]
    value = None
    try:
        if config.IS_WINDOWS:
            info = _windows_status(port_list)
            if info is None:
                value = None
            elif int(info.get("block") or 0) > 0:
                value = ("bad", "Windows 防火墙阻止了 Kiteline 的入站连接：同一网络里的手机、其他电脑连不进来"
                                + ("（当前网络被设为「公用网络」）" if "Public" in str(info.get("category")) else ""))
            elif int(info.get("enabled") or 0) > 0 and int(info.get("allow") or 0) == 0:
                value = ("warn", "Windows 防火墙还没有放行 Kiteline：同一网络里的手机、其他电脑可能连不进来")
            else:
                value = ("ok", "已放行端口 %s，同一网络里的手机、其他电脑可以连接" % "、".join(str(p) for p in port_list))
        elif config.IS_LINUX and shutil.which("ufw") and _ufw_enabled():
            done = config.read_json(_ufw_done_file(), [])
            if all(p in done for p in port_list):
                value = ("ok", "已在 ufw 中放行端口 %s" % "、".join(str(p) for p in port_list))
            else:
                value = ("warn", "这台电脑开着防火墙（ufw）：还没有放行 Kiteline 的端口 %s，同一网络里的手机、其他电脑可能连不进来"
                         % "、".join(str(p) for p in port_list))
    except Exception as exc:  # noqa: BLE001
        log.write("检查防火墙失败：%r" % exc)
        value = None
    with _lock:
        _cache["at"], _cache["value"] = time.time(), (port_list, value)
    return value


def manual_command(cfg):
    port_list = ",".join(str(p) for p in ports(cfg))
    if config.IS_WINDOWS:
        return ('以管理员身份打开 PowerShell 运行：New-NetFirewallRule -DisplayName Kiteline -Direction Inbound -Action Allow '
                '-Program "%s" -Protocol TCP -LocalPort %s -Profile Any' % (program(), port_list))
    return "sudo ufw allow proto tcp to any port %s comment Kiteline" % port_list


def _windows_fix_script(port_list):
    prog = _ps_quote(program())
    return r"""
$prog = %(prog)s
Get-NetFirewallApplicationFilter -Program $prog | Get-NetFirewallRule | Where-Object { $_.Direction -eq 'Inbound' -and $_.Action -eq 'Block' } | Remove-NetFirewallRule
# 只换掉这个程序自己的旧规则（别的安装、用户手动建的同名规则不动）
Get-NetFirewallApplicationFilter -Program $prog | Get-NetFirewallRule | Where-Object { $_.DisplayName -eq '%(name)s' -or $_.DisplayName -eq '%(name)s mDNS' } | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName '%(name)s' -Description 'Kiteline: phones and other Kiteline computers on the same network' -Direction Inbound -Action Allow -Program $prog -Protocol TCP -LocalPort %(ports)s -Profile Any | Out-Null
New-NetFirewallRule -DisplayName '%(name)s mDNS' -Direction Inbound -Action Allow -Program $prog -Protocol UDP -LocalPort 5353 -Profile Any | Out-Null
""" % {"prog": prog, "name": RULE_NAME, "ports": ",".join(str(p) for p in port_list)}


def fix(cfg):
    """一键放行：在电脑上弹系统授权窗口。返回 (ok, message)"""
    port_list = ports(cfg)
    dry = os.environ.get("CCPULSE_DRY_RUN") == "1" or os.environ.get("KITELINE_DRY_RUN") == "1"
    if dry and os.environ.get("KITELINE_TEST_FIREWALL") != "1":   # 测试实例默认不动防火墙；测这一项时设 KITELINE_TEST_FIREWALL=1
        return True, "（测试）将在电脑上放行端口 %s" % "、".join(str(p) for p in port_list)
    if not _busy.acquire(blocking=False):
        return True, "正在放行：请在电脑上完成授权"
    try:
        if config.IS_WINDOWS:
            inner = base64.b64encode(_windows_fix_script(port_list).encode("utf-16-le")).decode("ascii")
            # Start-Process -Verb RunAs：系统弹 UAC 窗口，点「是」才以管理员身份执行；-Wait 等它做完再刷新状态
            outer = ("Start-Process powershell -Verb RunAs -WindowStyle Hidden -Wait -ArgumentList "
                     "'-NoProfile -ExecutionPolicy Bypass -EncodedCommand %s'" % inner)
            threading.Thread(target=_run_windows, args=(outer,), daemon=True).start()
            return True, "已在电脑上弹出授权窗口：请在电脑上点「是」，完成后同一网络里的手机、其他电脑即可连接"
        if config.IS_LINUX and shutil.which("ufw"):
            if not shutil.which("pkexec") or not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
                _busy.release()
                return False, "请在电脑的终端里运行：%s" % manual_command(cfg)
            threading.Thread(target=_run_ufw, args=(port_list,), daemon=True).start()
            return True, "已在电脑上弹出授权窗口：请在电脑上输入密码"
    except Exception:  # noqa: BLE001
        _busy.release()
        raise
    _busy.release()
    return True, "这台电脑没有需要放行的防火墙"


def _run_windows(outer):
    try:
        done = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", outer],
                              capture_output=True, timeout=300, creationflags=0x08000000)
        err = done.stderr.decode("utf-8", "replace").strip()
        log.write("防火墙放行：%s" % ("已完成" if done.returncode == 0 and not err else "未完成（%s）" % (err[-200:] or done.returncode)))
    except (OSError, subprocess.SubprocessError) as exc:
        log.write("防火墙放行失败：%s" % exc)
    finally:
        with _lock:
            _cache["at"] = 0.0
        _busy.release()


def _run_ufw(port_list):
    try:
        script = " && ".join("ufw allow proto tcp to any port %d comment Kiteline" % p for p in port_list)
        done = subprocess.run(["pkexec", "sh", "-c", script], capture_output=True, timeout=300)
        if done.returncode == 0:
            config.write_private(_ufw_done_file(), json.dumps(port_list))
            log.write("防火墙放行：已在 ufw 中放行端口 %s" % port_list)
        else:
            log.write("防火墙放行未完成（%d）" % done.returncode)
    except (OSError, subprocess.SubprocessError) as exc:
        log.write("防火墙放行失败：%s" % exc)
    finally:
        with _lock:
            _cache["at"] = 0.0
        _busy.release()
