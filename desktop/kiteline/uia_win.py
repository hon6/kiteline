"""Windows 上读写系统界面（UI Automation）：VS Code 弹的系统对话框（文字、按钮）、Claude 标签里的「Open here anyway」、
命令面板的输入框。对应 Mac 版 EditorAlerts.swift / ClaudeInput.swift 里用辅助功能做的那几件事。

不加第三方依赖：用系统自带的 PowerShell 5.1 + .NET 的 UI Automation。PowerShell 冷启动要一两秒，所以起一个常驻的辅助进程
（标准输入一行 JSON 命令、标准输出一行 JSON 结果），闲置 10 分钟自己关掉，下次用到再起。
VS Code（Chromium）的网页内容第一次被查询时才建辅助功能树，约两秒后才完整（10-27 在 Win11 测试机实测）。

按对话框按钮不走 UI Automation：VS Code 的对话框是系统 TaskDialog，按钮在 UI Automation 里没有「按下」接口，
但按钮编号就在 AutomationId 里（CommandButton_101），给对话框发 TDM_CLICK_BUTTON 就是按下它，不用动鼠标、不用切前台。
"""

import ctypes
import json
import os
import queue
import subprocess
import threading
import time
from ctypes import wintypes

from . import config, log

user32 = ctypes.WinDLL("user32", use_last_error=True)
user32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
user32.GetDlgItem.argtypes = [wintypes.HWND, ctypes.c_int]
user32.GetDlgItem.restype = wintypes.HWND

TDM_CLICK_BUTTON = 0x0400 + 102   # WM_USER + 102
BM_CLICK = 0x00F5
IDLE_EXIT = 600

HELD_LABEL = "Open here anyway"
INPUT_LABEL = "Message input"

# 辅助进程：每行一个请求，按 cmd 分派；出错回 {ok: false, error}
SCRIPT = r"""
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = New-Object Text.UTF8Encoding $false
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$A = [System.Windows.Automation.AutomationElement]
$CT = [System.Windows.Automation.ControlType]
$TS = [System.Windows.Automation.TreeScope]
$All = [System.Windows.Automation.Condition]::TrueCondition
function Reply($o) { [Console]::Out.WriteLine((ConvertTo-Json $o -Compress -Depth 5)); [Console]::Out.Flush() }
function Named($type, $name) {
  New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, $type)),
    (New-Object System.Windows.Automation.PropertyCondition($A::NameProperty, $name)))
}
function ValueOf($e) {
  $p = $null
  if ($e.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$p)) { return $p.Current.Value }
  return $null
}
# 键盘焦点在哪：input（这个输入框）/ panel（这个面板里别处）/ 地点代号（终端、编辑器……，见 uia_win.FOCUS_PLACES）/ unknown（读不到）。
# 扩展面板（id 为 active-frame 的 iframe）里的类名是扩展自己起的，不往下认
function FocusAt($frame, $box) {
  try { $f = $A::FocusedElement } catch { $f = $null }
  if ($null -eq $f) { return @{ at = 'unknown'; place = '' } }
  if ($null -ne $box -and [System.Windows.Automation.Automation]::Compare($f, $box)) { return @{ at = 'input'; place = '' } }
  $walker = [System.Windows.Automation.TreeWalker]::RawViewWalker
  $e = $f
  $place = $null
  for ($i = 0; $i -lt 80 -and $null -ne $e; $i++) {
    if ($null -ne $frame -and [System.Windows.Automation.Automation]::Compare($e, $frame)) { return @{ at = 'panel'; place = 'panel' } }
    $c = $e.Current
    if ($c.AutomationId -eq 'active-frame') { return @{ at = 'tab'; place = [string]$c.Name } }
    if ($null -eq $place) {
      $cls = [string]$c.ClassName
      if ($cls -match 'xterm|terminal') { $place = 'terminal' }
      elseif ($cls -match 'monaco-editor') { $place = 'editor' }
      elseif ($c.AutomationId -eq 'workbench.parts.sidebar' -or $c.AutomationId -eq 'workbench.parts.auxiliarybar') { $place = 'sidebar' }
      elseif ($c.AutomationId -eq 'workbench.parts.panel') { $place = 'bottom' }
      elseif ($c.AutomationId -eq 'workbench.parts.editor') { $place = 'editor-area' }
      elseif ($c.AutomationId -match '^workbench\.parts\.(titlebar|statusbar|activitybar)$') { $place = 'bars' }
    }
    $e = $walker.GetParent($e)
  }
  if ($null -eq $place) { $place = 'other' }
  return @{ at = 'elsewhere'; place = $place }
}
while ($true) {
  $line = [Console]::In.ReadLine()
  if ($null -eq $line) { break }
  try {
    $req = ConvertFrom-Json $line
    switch ($req.cmd) {
      'ping' { Reply @{ ok = $true } }
      'dialog' {
        # 对话框里的字和按钮；有输入框、列表的是打开 / 保存面板，不算提示框
        $el = $A::FromHandle([IntPtr][long]$req.hwnd)
        $texts = New-Object System.Collections.ArrayList
        $buttons = New-Object System.Collections.ArrayList
        $panel = $false
        foreach ($e in $el.FindAll($TS::Descendants, $All)) {
          $c = $e.Current
          if ($c.ControlType -eq $CT::Edit -or $c.ControlType -eq $CT::List -or $c.ControlType -eq $CT::Tree -or $c.ControlType -eq $CT::ComboBox) { $panel = $true }
          elseif ($c.ClassName -eq 'CCPushButton' -or $c.ControlType -eq $CT::Button) {
            if ($c.Name) { [void]$buttons.Add(@{ name = $c.Name; id = $c.AutomationId }) }
          }
          elseif ($c.ControlType -eq $CT::Text -and $c.Name) { [void]$texts.Add($c.Name) }
        }
        Reply @{ ok = $true; texts = @($texts); buttons = @($buttons); panel = $panel }
      }
      'held' {
        # VS Code 窗口里 Claude 标签的「Open here anyway」：恰好一个才按（press）；顺带看输入框在不在、能不能用。
        # 变量别叫 $input：那是 PowerShell 的自动变量，脚本里一出现它，标准输入会先被整个读走，命令一条也收不到
        $el = $A::FromHandle([IntPtr][long]$req.hwnd)
        $found = @($el.FindAll($TS::Descendants, (Named $CT::Button $req.label)))
        $box = $el.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($A::NameProperty, $req.input)))
        $pressed = $false
        if ($req.press -and $found.Count -eq 1) {
          $found[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
          $pressed = $true
        }
        $enabled = $false
        if ($null -ne $box) {
          $enabled = $box.Current.IsEnabled
          if ($req.focus -and $enabled -and $found.Count -eq 0) { $box.SetFocus() }
        }
        Reply @{ ok = $true; held = $found.Count; pressed = $pressed; input = ($null -ne $box); enabled = $enabled }
      }
      'palette' {
        # 命令面板输入框里的字。面板开着时焦点报的是列表里高亮的那一项（ListItem），不是输入框：
        # 从焦点往上找，第一个含输入框（Edit / ComboBox）的祖先就是面板，读它的值。焦点本身是输入框（编辑器、聊天框）就直接读
        $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
        $boxes = New-Object System.Windows.Automation.OrCondition(
          (New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, $CT::Edit)),
          (New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, $CT::ComboBox)))
        $e = $A::FocusedElement
        $value = $null
        for ($i = 0; $i -lt 8 -and $null -ne $e; $i++) {
          if ($e.Current.ControlType -eq $CT::Edit -or $e.Current.ControlType -eq $CT::ComboBox) { $value = ValueOf $e; break }
          $box = $e.FindFirst($TS::Descendants, $boxes)
          if ($null -ne $box) { $value = ValueOf $box; break }
          $e = $walker.GetParent($e)
        }
        Reply @{ ok = $true; value = $value }
      }
      'focus' {
        # 粘贴 / 按键前：键盘焦点得在这个会话的 Claude 输入框里（同 Mac 版 ClaudeInput.ensureFocus）。网页里的 id、class 在 UI Automation 里
        # 是 AutomationId、ClassName：扩展面板是 id 为 active-frame 的 iframe（名字就是标签名），输入框名为「Message input」。
        # 不给 frame（-1）：列出面板，顺带报焦点在哪；给了：看焦点在不在这个面板的输入框里，move 时不在就放进去（按键时没有输入框就放进面板）
        $el = $A::FromHandle([IntPtr][long]$req.hwnd)
        $frames = @($el.FindAll($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($A::AutomationIdProperty, 'active-frame'))))
        $byName = New-Object System.Windows.Automation.PropertyCondition($A::NameProperty, $req.input)
        if ($req.frame -lt 0 -or $req.frame -ge $frames.Count) {
          $list = @($frames | ForEach-Object { @{ name = $_.Current.Name; input = ($null -ne $_.FindFirst($TS::Descendants, $byName)) } })
          $at = FocusAt $null $null
          Reply @{ ok = $true; frames = $list; at = $at.at; place = $at.place }
          break
        }
        $frame = $frames[$req.frame]
        $box = $frame.FindFirst($TS::Descendants, $byName)
        $at = FocusAt $frame $box
        $moved = $false
        $target = $box
        if ($null -eq $target -and -not $req.needInput) { $target = $frame }
        if ($req.move -and $at.at -ne 'input' -and -not ($at.at -eq 'panel' -and -not $req.needInput) -and $null -ne $target) {
          try { $target.SetFocus() } catch { }
          Start-Sleep -Milliseconds 300
          $at = FocusAt $frame $box
          $moved = $true
        }
        # 输入框里现在的字（粘贴后、回车后核对用，见 uia_win.input_text）
        $val = $null
        if ($null -ne $box) { try { $val = ValueOf $box } catch { } }
        Reply @{ ok = $true; at = $at.at; place = $at.place; input = ($null -ne $box); moved = $moved; value = $val }
      }
      default { Reply @{ ok = $false; error = 'unknown command' } }
    }
  } catch { Reply @{ ok = $false; error = $_.Exception.Message } }
}
"""


class _Helper:
    def __init__(self):
        self.lock = threading.Lock()
        self.proc = None
        self.lines = None
        self.last_used = 0.0
        threading.Thread(target=self._reaper, daemon=True).start()

    def _script_path(self):
        path = os.path.join(config.config_dir(), "uia-helper.ps1")
        data = b"\xef\xbb\xbf" + SCRIPT.encode("utf-8")   # PowerShell 5.1 读不带 BOM 的 UTF-8 会把中文读乱
        try:
            with open(path, "rb") as handle:
                if handle.read() == data:
                    return path
        except OSError:
            pass
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(data)
        return path

    def _start(self):
        system = os.environ.get("SystemRoot", r"C:\Windows")
        exe = os.path.join(system, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
        # 不能用 DETACHED_PROCESS 起 PowerShell（见 updater.py）；CREATE_NO_WINDOW 不弹黑框
        self.proc = subprocess.Popen([exe, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", self._script_path()],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                     creationflags=0x08000000)
        self.lines = queue.Queue()
        out = self.proc.stdout

        def pump():
            for raw in iter(out.readline, b""):
                self.lines.put(raw)
            self.lines.put(None)
        threading.Thread(target=pump, daemon=True).start()

    def call(self, request, timeout=6.0):
        """发一条命令，等结果（dict）；超时、辅助进程挂了返回 None（下次重起）"""
        with self.lock:
            self.last_used = time.time()
            try:
                fresh = not self.proc or self.proc.poll() is not None
                if fresh:
                    self._start()
                self.proc.stdin.write((json.dumps(request, ensure_ascii=False) + "\n").encode("utf-8"))
                self.proc.stdin.flush()
                raw = self.lines.get(timeout=timeout + (10 if fresh else 0))   # 刚起的要先加载 UI Automation
            except (OSError, queue.Empty) as exc:
                log.write("界面读取辅助进程没有回应（%s）：%s" % (request.get("cmd"), exc or "超时"))
                self._stop()
                return None
            if raw is None:
                self._stop()
                return None
            try:
                reply = json.loads(raw.decode("utf-8", "replace"))
            except ValueError:
                return None
            if not reply.get("ok"):
                log.write("界面读取出错（%s）：%s" % (request.get("cmd"), reply.get("error")))
                return None
            return reply

    def _stop(self):
        proc, self.proc = self.proc, None
        if proc and proc.poll() is None:
            try:
                proc.kill()
            except OSError:
                pass

    def _reaper(self):
        while True:
            time.sleep(60)
            with self.lock:
                if self.proc and time.time() - self.last_used > IDLE_EXIT:
                    self._stop()


_helper = None
_helper_lock = threading.Lock()


def _call(request, timeout=6.0):
    global _helper
    with _helper_lock:
        if _helper is None:
            _helper = _Helper()
    return _helper.call(request, timeout)


def read_dialog(hwnd):
    """系统对话框里的字和按钮：{"texts": [...], "buttons": [{"name", "id"}], "panel": bool}；读不到返回 None"""
    reply = _call({"cmd": "dialog", "hwnd": int(hwnd)}, timeout=8)
    if not reply:
        return None
    buttons = [b for b in (reply.get("buttons") or []) if isinstance(b, dict)]
    return {"texts": [t for t in (reply.get("texts") or []) if isinstance(t, str)], "buttons": buttons, "panel": bool(reply.get("panel"))}


def click_button(hwnd, automation_id):
    """按对话框上的按钮：TaskDialog 的按钮编号在 AutomationId 末尾（CommandButton_101）；普通对话框的按钮是子窗口，编号就是 AutomationId"""
    tail = (automation_id or "").rsplit("_", 1)[-1]
    if not tail.isdigit():
        return False
    number = int(tail)
    if automation_id.startswith("CommandButton_"):
        return bool(user32.PostMessageW(hwnd, TDM_CLICK_BUTTON, number, 0))
    child = user32.GetDlgItem(hwnd, number)
    return bool(child and user32.PostMessageW(child, BM_CLICK, 0, 0))


def held_state(hwnd, press=False, focus=False):
    """VS Code 窗口里 Claude 标签是不是「仍在别处打开」：{"held": 按钮个数, "pressed", "input", "enabled"}；读不到返回 None"""
    return _call({"cmd": "held", "hwnd": int(hwnd), "label": HELD_LABEL, "input": INPUT_LABEL, "press": press, "focus": focus}, timeout=6)


def open_here_if_held(hwnd, ready_wait=2.5):
    """投递粘贴前：标签是「仍在别处打开」就按「Open here anyway」，等输入框能用了把焦点放进去。返回 True = 按过。
    网页辅助功能树刚建时读不全：最多等 ready_wait 秒，看到输入框（没被占）或按钮（被占）为止"""
    deadline = time.time() + ready_wait
    state = None
    while time.time() < deadline:
        state = held_state(hwnd, press=True)
        if state is None:
            return False
        if state.get("pressed") or state.get("input"):
            break
        time.sleep(0.3)
    if not state or not state.get("pressed"):
        return False
    log.write("会话仍在别处打开，已按「Open here anyway」")
    # 扩展接着重新拉起 Claude，输入框随后才能用
    until = time.time() + 8
    while time.time() < until:
        time.sleep(0.4)
        state = held_state(hwnd, focus=True)
        if state and not state.get("held") and state.get("input") and state.get("enabled"):
            break
    return True


# 辅助进程报的焦点地点代号 → (给用户看的, 是不是终端、编辑器这种打字就进去的地方)
FOCUS_PLACES = {
    "terminal": ("终端", True), "editor": ("编辑器", True), "sidebar": ("侧栏", False), "bottom": ("底部面板", False),
    "editor-area": ("编辑区", False), "bars": ("窗口边栏", False), "panel": ("该会话面板中输入框以外的位置", False),
    "other": ("VS Code 的其他位置", False),
}


def _place(reply):
    """辅助进程的回复 → (地点, 是不是打字的地方)"""
    if reply.get("at") == "tab":
        name = reply.get("place") or ""
        return ("另一个标签页「%s」" % name if name else "另一个标签页"), False
    return FOCUS_PLACES.get(reply.get("place") or "other", FOCUS_PLACES["other"])


def _session_frame(frames, titles):
    """这个会话的 Claude 面板是第几个：标签名对上的那个（titles = delivery.tab_names）；对不上（扩展有时起通用名「Claude Code」）时，只有一个带输入框的面板就是它"""
    from . import delivery
    named = [i for i, f in enumerate(frames) if titles and delivery.tab_matches(f.get("name") or "", titles)]
    if named:
        return named[0] if len(named) == 1 else None
    claude = [i for i, f in enumerate(frames) if f.get("input")]
    return claude[0] if len(claude) == 1 else None


def ensure_focus(hwnd, titles, need_input, wait=2.5):
    """粘贴 / 按键前（会话标签已经切到前面、VS Code 在前台）：键盘焦点不在这个会话的 Claude 面板里（粘贴要在输入框里），
    就把光标放进它的输入框再核对（同 Mac 版 ClaudeInput.ensureFocus）。只核对窗口标题不够：标签切过来了，焦点却可能还在终端里，
    Ctrl+V 就粘进了终端，单行的回车直接在终端里执行。网页辅助功能树刚建时读不全，最多等 wait 秒。
    返回 ("input" | "panel" | "elsewhere" | "unknown", 地点)：elsewhere = 焦点在别处、放不进去；unknown = 读不出来，照以前的做法往下走"""
    title = titles[0] if titles else ""
    deadline = time.time() + wait
    tries = 0
    result = ("unknown", "")
    while True:
        listing = _call({"cmd": "focus", "hwnd": int(hwnd), "frame": -1, "input": INPUT_LABEL}, timeout=6)
        if listing is None:
            return "unknown", ""
        frames = [f for f in (listing.get("frames") or []) if isinstance(f, dict)]
        index = _session_frame(frames, titles)
        if index is not None:
            reply = _call({"cmd": "focus", "hwnd": int(hwnd), "frame": index, "input": INPUT_LABEL,
                           "needInput": bool(need_input), "move": tries < 3}, timeout=6)
            if reply is None:
                return "unknown", ""
            at = reply.get("at")
            if reply.get("moved"):
                if tries == 0:
                    log.write("焦点不在「%s」的 Claude 输入框，把光标放进去" % title)
                tries += 1
            if at == "input" or (at == "panel" and not need_input):
                if tries:
                    log.write("已把光标放进「%s」的 Claude 输入框" % title)
                return at, ""
            if at == "unknown":
                return "unknown", ""
            result = ("elsewhere", _place(reply)[0])
            if tries >= 3:
                break
        elif listing.get("at") not in (None, "unknown", "input", "panel"):
            # 认不出是哪个面板（树没建好，或分屏几个都对不上），但看得出焦点在终端、编辑器里：不往那儿粘
            place, typing = _place(listing)
            result = ("elsewhere", place) if typing else ("unknown", "")
        if time.time() >= deadline:
            break
        time.sleep(0.3)
    if result[0] == "elsewhere":
        log.write("焦点在%s，没能放进「%s」的 Claude 输入框" % (result[1], title))
    return result


def focus_left(hwnd, titles, menu_ok=False):
    """粘贴之后、回车之前：焦点还在这个会话的输入框里（None = 在，或读不出；否则是去了哪儿）。
    menu_ok：斜杠命令粘进去会弹出命令菜单，焦点落在菜单项上（还在这个会话的面板里），回车正是要选中它，不算离开"""
    listing = _call({"cmd": "focus", "hwnd": int(hwnd), "frame": -1, "input": INPUT_LABEL}, timeout=6)
    if listing is None:
        return None
    index = _session_frame([f for f in (listing.get("frames") or []) if isinstance(f, dict)], titles)
    if index is None:
        return None
    reply = _call({"cmd": "focus", "hwnd": int(hwnd), "frame": index, "input": INPUT_LABEL, "needInput": True, "move": False}, timeout=6)
    if not reply or reply.get("at") in ("input", "unknown") or (menu_ok and reply.get("at") == "panel"):
        return None
    return _place(reply)[0]


def input_text(hwnd, titles):
    """这个会话输入框里现在的字（空白统一过；空着时读到的是占位文字）；读不出返回 None（同 Mac 版 ClaudeInput.text）"""
    from . import delivery
    listing = _call({"cmd": "focus", "hwnd": int(hwnd), "frame": -1, "input": INPUT_LABEL}, timeout=6)
    if listing is None:
        return None
    index = _session_frame([f for f in (listing.get("frames") or []) if isinstance(f, dict)], titles)
    if index is None:
        return None
    reply = _call({"cmd": "focus", "hwnd": int(hwnd), "frame": index, "input": INPUT_LABEL, "needInput": True, "move": False}, timeout=6)
    value = reply.get("value") if reply else None
    return delivery.normalized(value) if isinstance(value, str) else None


def palette_value():
    """命令面板（焦点所在的那块）输入框里的字；读不到返回 None"""
    reply = _call({"cmd": "palette"}, timeout=4)
    return reply.get("value") if reply else None
