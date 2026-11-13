#!/usr/bin/env bash
# 一键安装 Kiteline：构建 → 装到 /Applications → 添加远端来源（可选）→ 启动
#
# 用法：
#   ./install.sh                    只监听本机的 Claude Code（VS Code 本地窗口 / 终端）
#   ./install.sh <ssh主机> [...]    同时监听这些 Remote-SSH 主机（要能免密 ssh 过去）
#
# 装完以后：菜单栏 Kiteline 图标 → 右键「手机访问…」→ 用 iPhone 相机扫码。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# 构建产物和可执行文件仍叫 TARS（内部名，开发脚本都认这个路径）；装进「应用程序」时用对外的名字 Kiteline
APP="$ROOT/dist/Kiteline.app"
DEST="/Applications/Kiteline.app"
CC="$DEST/Contents/MacOS/TARS"

# 同一时间只让一个会话编译、安装：几个会话同时 install 时，一个的 rm -rf / cp 和另一个的 open 会交错，
# App 在安装包还没拷完时就被启动、找不到打包的 watcher，本机和远端全连不上（11-14）；同时编译还会互相覆盖 dist/Kiteline.app。
# 锁放在 /tmp（各会话的 TMPDIR 不一样）；最多等 10 分钟（前一个卡死留下的锁也就等这么久）
LOCK="/tmp/kiteline-install.lock"
for i in $(seq 1 600); do mkdir "$LOCK" 2>/dev/null && break; [ "$i" = 1 ] && echo "另一个会话正在编译 / 安装 Kiteline，等它装完…"; sleep 1; done
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

echo "==== 1/4 构建 ===="
bash "$ROOT/build.sh"

echo "==== 2/4 安装到 /Applications ===="
# 先拷到旁边的临时位置，拷完再整个换进去（同一个磁盘上改名是一步完成的）：「应用程序」里任何时候都不会有拷到一半的包
STAGE="/Applications/.Kiteline-installing.app"
rm -rf "$STAGE"
cp -R "$APP" "$STAGE"
# 先退出正在运行的旧版本（手机端口等资源要释放）；改名前的 TARS / CC Pulse 一并退出并移除
pkill -f "Kiteline.app/Contents/MacOS/TARS" 2>/dev/null || true
pkill -f "TARS.app/Contents/MacOS/TARS" 2>/dev/null || true
pkill -f "CC Pulse.app/Contents/MacOS/CCPulse" 2>/dev/null || true
sleep 0.5
if [ -d "/Applications/TARS.app" ]; then
  # 同一个 bundle id、同一个签名：数据目录、配对、系统权限都沿用，手机不用重配
  rm -rf "/Applications/TARS.app"
  echo "已移除改名前的 /Applications/TARS.app（数据、配对和权限都沿用）"
fi
if [ -d "/Applications/CC Pulse.app" ]; then
  rm -rf "/Applications/CC Pulse.app"
  echo "已移除改名前的 /Applications/CC Pulse.app（数据会自动迁移到 Kiteline）"
fi
rm -rf "$DEST"
mv "$STAGE" "$DEST"
echo "已安装：$DEST"

echo "==== 3/4 来源 ===="
if [ "$#" -eq 0 ]; then
  echo "只监听本机。以后要加 Remote-SSH 主机：\"$CC\" sources add ssh <主机>"
else
  for host in "$@"; do
    "$CC" sources add ssh "$host" || echo "（$host 添加失败，稍后可以手动再加）"
  done
fi
"$CC" sources list

echo "==== 4/4 启动 ===="
# -g：后台启动，不抢前台（VS Code 被挤到后台时，手机发的消息不会自动提交）
open -g "$DEST"

cat <<'TXT'

完成。菜单栏会出现 Kiteline 图标（左键看会话，右键菜单）。

接下来：
  1. 右键菜单 →「手机访问…」，用 iPhone 上的 Kiteline 扫二维码（或在手机上输 6 位配对码）。
  2. 系统设置 → 隐私与安全性 → 设备控制和数据访问（旧系统叫「辅助功能」）：打开 Kiteline。
     （没有这个权限时，手机发的消息只能填进 VS Code 输入框，不能自动提交，也不能点确认框。）
  3. 人在外面也想用：Kiteline 设置 →「远程访问」打开；手机不在家里 Wi-Fi 时自动走远程访问（点对点，打不通经 tars.betac.cn 中继）。
TXT
