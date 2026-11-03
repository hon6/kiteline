#!/usr/bin/env bash
# 打 Linux 版安装包：bash desktop/packaging/build-linux.sh → desktop/packaging/dist/Kiteline-Linux-<版本>.tar.gz（+ .sha256）
# 包里是运行要用的源码 + 安装脚本，用户解压后运行 ./install.sh（依赖安装时按 requirements.lock 下载，见 desktop/install-linux.sh）。
# 先确认 desktop/kiteline/lib/libtarsp2p.so 是用当前 p2p/ 编的（x86_64，宿主机 ~/kiteline-build/build-p2p-linux.sh）。
# 版本号取 desktop/kiteline/app.py 的 VERSION；发布：bash relay/download.sh <服务器> <域名> <这个包>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP="$(dirname "$HERE")"
ROOT="$(dirname "$DESKTOP")"
VERSION="$(sed -n 's/^VERSION = "\([0-9.]*\)".*/\1/p' "$DESKTOP/kiteline/app.py")"
[ -n "$VERSION" ] || { echo "没从 kiteline/app.py 读到 VERSION" >&2; exit 1; }
# 开源版没有远程访问库：照样打包，只能在同一个网络里连；发官网的包必须带上（KITELINE_REQUIRE_P2P=1 时缺了就停）
if [ ! -f "$DESKTOP/kiteline/lib/libtarsp2p.so" ]; then
  [ "${KITELINE_REQUIRE_P2P:-0}" = 1 ] && { echo "缺 kiteline/lib/libtarsp2p.so" >&2; exit 1; }
  echo "没有 kiteline/lib/libtarsp2p.so：打出来的包不含远程访问" >&2
fi
# 原生客户端（主窗口）：还在移植，KITELINE_WITH_CLIENT=1 时才打进包（先 bash desktop/client/publish.sh linux-x64）；
# 不带时托盘「打开 Kiteline」照旧开浏览器控制台
CLIENT="$DESKTOP/client/publish/linux-x64"
if [ "${KITELINE_WITH_CLIENT:-0}" = 1 ]; then
  [ -x "$CLIENT/KitelineApp" ] || { echo "缺客户端：先运行 bash desktop/client/publish.sh linux-x64" >&2; exit 1; }
else
  CLIENT=""
fi
OUT="$HERE/dist"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PKG="$WORK/Kiteline"
mkdir -p "$PKG/desktop/packaging" "$PKG/watcher" "$OUT"
cp -R "$DESKTOP/kiteline" "$PKG/desktop/"
cp -R "$ROOT/Resources/world" "$PKG/desktop/world"   # 世界模式的网页（后台 /world/ 路由读它）
cp -R "$ROOT/Resources/guest" "$PKG/desktop/guest"   # 游客链接看的页面（后台 /g/<编号> 给，见 kiteline/guest.py）
cp "$DESKTOP/requirements.lock" "$DESKTOP/requirements.txt" "$DESKTOP/install-linux.sh" "$DESKTOP"/CHANGELOG*.md "$PKG/desktop/"
cp "$HERE/kiteline.png" "$PKG/desktop/packaging/"
[ -n "$CLIENT" ] && cp -R "$CLIENT" "$PKG/desktop/app"
cp "$ROOT/watcher/kiteline-watch.py" "$PKG/watcher/"
rm -f "$PKG/desktop/kiteline/lib/tarsp2p.dll"
find "$PKG" -name __pycache__ -prune -exec rm -rf {} +
cat > "$PKG/install.sh" <<'EOF'
#!/usr/bin/env bash
# 安装 Kiteline 电脑端（Linux）：./install.sh            有图形界面的电脑（登录时自动启动，菜单里有「Kiteline」）
#                                ./install.sh --service  没有图形界面的服务器（systemd 用户服务）
# 需要 Python 3.10 或更新版本（Ubuntu / Debian：sudo apt install python3 python3-venv）
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/desktop/install-linux.sh" "$@"
EOF
chmod +x "$PKG/install.sh"
if [ -n "$CLIENT" ]; then OPEN_HINT="在应用菜单中打开 Kiteline（或运行 kiteline）"; else OPEN_HINT="运行 kiteline 打开控制台"; fi
cat > "$PKG/README.txt" <<EOF
Kiteline 电脑端（Linux）$VERSION

安装：在解压出来的目录里运行  ./install.sh
  · 有图形界面的电脑：装到 ~/.local/share/kiteline，命令 ~/.local/bin/kiteline，登录时自动在后台启动
  · 没有图形界面的服务器：./install.sh --service（装成 systemd 用户服务，配对码用 kiteline --pair 查看）
  · 需要 Python 3.10 或更新版本；依赖默认从清华镜像下载，可用 PIP_INDEX_URL 指定其他镜像
  · 架构：x86_64

装好后${OPEN_HINT}，用 iPhone 上的 Kiteline 扫码或输入 6 位配对码。
更新：下载新版本后再运行一次 ./install.sh（配置和配对关系保留）。
支持：https://tars.betac.cn/support
EOF
NAME="Kiteline-Linux-$VERSION.tar.gz"
# 时间戳统一成打包当天、属主清成 0：用户机器的时钟稍慢时 tar 也不会报「时间戳在未来」
tar --mtime="$(date -u +%Y-%m-%d) 00:00:00 UTC" --owner=0 --group=0 --numeric-owner -C "$WORK" -czf "$OUT/$NAME" Kiteline
(cd "$OUT" && sha256sum "$NAME" > "$NAME.sha256")
echo "已打包：$OUT/$NAME（$(du -h "$OUT/$NAME" | cut -f1)）"
