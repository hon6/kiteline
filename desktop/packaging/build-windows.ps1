# 在 Windows 上打包 Kiteline：.\desktop\packaging\build-windows.ps1
# 需要 Python 3.12（python.org 版，勾选 Add to PATH）。依赖从清华镜像装，打包结果在 desktop\packaging\dist\Kiteline\
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$desktop = Split-Path -Parent $here
# 打包用的虚拟环境：默认放在 packaging\.venv；KITELINE_BUILD_VENV 可以指到别处（反复同步代码时不用每次重装依赖）
$venv = if ($env:KITELINE_BUILD_VENV) { $env:KITELINE_BUILD_VENV } else { Join-Path $here ".venv" }
if (-not (Test-Path $venv)) { python -m venv $venv }
$py = Join-Path $venv "Scripts\python.exe"
& $py -m pip install -q --upgrade pip -i https://pypi.tuna.tsinghua.edu.cn/simple
# 运行依赖按锁文件装（版本固定、逐个核对 SHA-256）；打包工具单独装
& $py -m pip install -q --require-hashes -r (Join-Path $desktop "requirements.lock") -i https://pypi.tuna.tsinghua.edu.cn/simple
& $py -m pip install -q "pyinstaller>=6.10" -i https://pypi.tuna.tsinghua.edu.cn/simple
Push-Location $here
try {
    & $py -m PyInstaller --noconfirm --clean --distpath (Join-Path $here "dist") --workpath (Join-Path $here "build") kiteline.spec
} finally { Pop-Location }
$out = Join-Path $here "dist\Kiteline"
# 原生客户端（主窗口，托盘「打开 Kiteline」打开它）：还在移植，$env:KITELINE_WITH_CLIENT = "1" 时才打进包
# （先在 Linux 上 bash desktop/client/publish.sh win-x64，同步过来）；不带时托盘照旧开浏览器控制台
if ($env:KITELINE_WITH_CLIENT -eq "1") {
    $client = Join-Path $desktop "client\publish\win-x64"
    if (-not (Test-Path (Join-Path $client "KitelineApp.exe"))) { throw "缺客户端：先运行 bash desktop/client/publish.sh win-x64" }
    Copy-Item -Recurse -Force $client (Join-Path $out "app")
}
Compress-Archive -Path $out -DestinationPath (Join-Path $here "dist\Kiteline-Windows.zip") -Force
Write-Host "已打包：$out\Kiteline.exe"
