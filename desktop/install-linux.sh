#!/usr/bin/env bash
# 安装 Kiteline 电脑端（Linux）：bash desktop/install-linux.sh [--service]
#   装到 ~/.local/share/kiteline（自带 Python 虚拟环境），命令 ~/.local/bin/kiteline
#   有图形界面：登录时自动启动（~/.config/autostart），菜单里有「Kiteline」
#   --service：没有图形界面的服务器，装成 systemd 用户服务（开机自启，配对码用 kiteline --pair 看）
#   --update：Kiteline 自动更新时调（kiteline/updater.py）：只换程序文件，依赖已经装好、开机启动和菜单项保持原样
set -euo pipefail
UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
DEST="${KITELINE_HOME:-$HOME/.local/share/kiteline}"
BIN="$HOME/.local/bin"
MIRROR="${PIP_INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}"

command -v python3 >/dev/null || { echo "需要 Python 3.10 或更新版本（sudo apt install python3 python3-venv）" >&2; exit 1; }
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' || { echo "Python 版本过旧，需要 3.10 或更新版本" >&2; exit 1; }

echo "==> 安装到 $DEST"
mkdir -p "$DEST" "$BIN"
rm -rf "$DEST/kiteline"
cp -R "$HERE/kiteline" "$DEST/kiteline"
cp "$ROOT/watcher/kiteline-watch.py" "$DEST/kiteline/kiteline-watch.py"
rm -rf "$DEST/kiteline/web"   # 网页版已下线：清掉旧版本装进来的网页文件
cp "$HERE/CHANGELOG.md" "$DEST/CHANGELOG.md"
cp "$HERE/CHANGELOG.en.md" "$DEST/CHANGELOG.en.md"   # 英文手机看的更新记录
cp "$HERE/packaging/kiteline.png" "$DEST/kiteline.png"
# 世界模式的网页（包里在 desktop/world；后台按 $DEST/world 找，见 server.world_root）。从仓库直接装时没有这个目录，后台用仓库的 Resources/world
if [ -d "$HERE/world" ]; then rm -rf "$DEST/world"; cp -R "$HERE/world" "$DEST/world"; fi
# 原生客户端（主窗口，托盘「打开 Kiteline」打开它）
if [ -d "$HERE/app" ]; then
  rm -rf "$DEST/app"
  cp -R "$HERE/app" "$DEST/app"
  chmod +x "$DEST/app/KitelineApp"
fi
find "$DEST/kiteline" -name '__pycache__' -prune -exec rm -rf {} +
rm -f "$DEST/kiteline/lib/tarsp2p.dll"

if [ "$UPDATE" = 1 ] && [ -x "$DEST/venv/bin/python" ]; then
  echo "==> 依赖已由更新程序装好"
else
  echo "==> Python 虚拟环境与依赖"
  [ -x "$DEST/venv/bin/python" ] || python3 -m venv "$DEST/venv" || { echo "创建虚拟环境失败：sudo apt install python3-venv" >&2; exit 1; }
  "$DEST/venv/bin/pip" install -q --upgrade pip -i "$MIRROR"
  # 按锁文件装：版本固定、逐个核对 SHA-256（requirements.lock 由 requirements.txt 生成）
  "$DEST/venv/bin/pip" install -q --require-hashes -r "$HERE/requirements.lock" -i "$MIRROR"
fi

cat > "$BIN/kiteline" <<EOF
#!/usr/bin/env bash
cd "$DEST" && exec "$DEST/venv/bin/python" -m kiteline "\$@"
EOF
chmod +x "$BIN/kiteline"

if [ "$UPDATE" = 1 ]; then
  echo "==> 已更新"
  exit 0
fi

if [ "${1:-}" = "--service" ]; then
  mkdir -p "$HOME/.config/systemd/user"
  cat > "$HOME/.config/systemd/user/kiteline.service" <<EOF
[Unit]
Description=Kiteline（在手机上跟进和回复 Claude Code）
After=network-online.target

[Service]
ExecStart=$BIN/kiteline --headless
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now kiteline.service
  loginctl enable-linger "$USER" 2>/dev/null || echo "提示：要在未登录时也运行，请执行 sudo loginctl enable-linger $USER"
  echo "==> 已装成 systemd 用户服务。查看配对码：journalctl --user -u kiteline -n 20"
else
  mkdir -p "$HOME/.local/share/applications" "$HOME/.config/autostart"
  for target in "$HOME/.local/share/applications/kiteline.desktop" "$HOME/.config/autostart/kiteline.desktop"; do
    cat > "$target" <<EOF
[Desktop Entry]
Type=Application
Name=Kiteline
Comment=在手机上跟进和回复 Claude Code
Exec=$BIN/kiteline
Icon=$DEST/kiteline.png
StartupWMClass=kiteline
Terminal=false
Categories=Development;
EOF
  done
  sed -i "s#^Exec=.*#Exec=$BIN/kiteline --background#" "$HOME/.config/autostart/kiteline.desktop"
  if [ -x "$DEST/app/KitelineApp" ]; then
    echo "==> 已安装。在应用菜单中打开 Kiteline，或运行 kiteline（登录时会自动在后台启动）"
  else
    echo "==> 已安装。运行 kiteline 打开控制台（登录时会自动在后台启动）"
  fi
  # 从手机发消息要用的组件（VS Code 配套扩展、键盘模拟权限、tmux）：缺的话问一句当场装（清单在 kiteline/setup_tools.py）
  "$BIN/kiteline" --install-components || true
  echo "终端里的 Claude Code 要在 tmux 里运行才能接收手机消息：在项目目录里运行 tmux new -A -s claude claude"
fi
