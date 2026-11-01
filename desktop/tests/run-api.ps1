# （本文件存成带 BOM 的 UTF-8：Windows PowerShell 5.1 才不会把中文按 GBK 读错）
# Windows 上用 Mac 版的接口测试（tests/test_api.py）测电脑端：隔离数据目录 + 合成会话 + dry-run
#   powershell -ExecutionPolicy Bypass -File desktop\tests\run-api.ps1 [python.exe] [-Exe 打包好的 Kiteline.exe]
param([string]$Python = "python", [string]$Exe = "")
$ErrorActionPreference = "Continue"
$desktop = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$root = Split-Path -Parent $desktop
$tmp = Join-Path $env:TEMP ("kiteline-it-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$port = Get-Random -Minimum 20000 -Maximum 40000
$token = "it-" + (Get-Random)
$env:PYTHONUTF8 = "1"
# 测试里要用 git 和 openssl（Bark 加密核对）：Git for Windows 两样都带
$git = "C:\Program Files\Git"
if (Test-Path "$git\cmd\git.exe") { $env:Path = "$git\cmd;" + $env:Path + ";$git\usr\bin" }
New-Item -ItemType Directory -Force "$tmp\config" | Out-Null
# Windows 自带的 curl（Schannel）默认要查吊销列表，本机根证书没有吊销列表：测试里关掉这一项
"ssl-no-revoke" | Out-File -Encoding ascii "$tmp\_curlrc"; $env:CURL_HOME = $tmp
& $Python "$root\tests\fixture.py" "$tmp\fake" | Out-Null
$watcher = ("$tmp\bin\ccpulse-watch.py").Replace("\", "/")
@"
{"sources":[{"id":"local","name":"本机","kind":"local","remoteWatcherPath":"$watcher"}],
 "mobile":{"enabled":true,"port":$port,"bindAddress":"127.0.0.1","token":"$token","installAgentSkill":false,"remoteEnabled":false}}
"@ | Out-File -Encoding utf8 "$tmp\config\config.json"
$env:CCPULSE_CONFIG_DIR = "$tmp\config"; $env:CCPULSE_DRY_RUN = "1"; $env:CCPULSE_FAKE_TRANSCRIPT = "帮我看一下首页的按钮"
$env:CCPULSE_SESSIONS_DIR = "$tmp\fake\sessions"; $env:CCPULSE_DATA_DIR = "$tmp\fake\data"
# 额度读数在夹具里（<夹具>/claude/kiteline/limits.json），别读这台电脑真实的 ~/.claude、~/.codex
$env:CLAUDE_CONFIG_DIR = "$tmp\fake\claude"; $env:CODEX_HOME = "$tmp\codex"
if ($Exe) { $file, $args_ = $Exe, "--headless --no-tray" } else { $file, $args_ = $Python, "-m kiteline --headless --no-tray" }
$app = Start-Process -PassThru -NoNewWindow -WorkingDirectory $desktop -FilePath $file -ArgumentList $args_ `
    -RedirectStandardOutput "$tmp\app.out" -RedirectStandardError "$tmp\app.err"
for ($i = 0; $i -lt 80; $i++) {
    try { Invoke-WebRequest "http://127.0.0.1:$port/" -UseBasicParsing -TimeoutSec 2 | Out-Null; break } catch { Start-Sleep -Milliseconds 250 }
}
Start-Sleep 2
& $Python "$root\tests\test_api.py" $port ($port + 1) $token "$tmp\config" "$tmp\fake\data"
$status = $LASTEXITCODE
Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
if (Test-Path "$tmp\fake\pids") { Get-Content "$tmp\fake\pids" | ForEach-Object { Stop-Process -Id ([int]$_) -Force -ErrorAction SilentlyContinue } }
if ($status -ne 0) { Get-Content -Encoding UTF8 "$tmp\app.err" -Tail 30 }
exit $status
