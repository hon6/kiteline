#!/usr/bin/env bash
# 发布 Windows / Linux 原生客户端：bash desktop/client/publish.sh [linux-x64] [win-x64]（默认两个都出）
#   → desktop/client/publish/<平台>/（自带 .NET 运行时，用户不用另装）；打安装包时由 build-linux.sh / build-windows.ps1 放进 app 文件夹
# 源码在网络盘上时编译很慢：先 rsync 到本机的编译目录（KITELINE_CLIENT_BUILD，默认 ~/.cache/kiteline-client-build）再编
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTNET="${DOTNET:-$(command -v dotnet || echo "$HOME/.dotnet/dotnet")}"
[ -x "$DOTNET" ] || { echo "没找到 dotnet（.NET 10 SDK）" >&2; exit 1; }
BUILD="${KITELINE_CLIENT_BUILD:-$HOME/.cache/kiteline-client-build}"
mkdir -p "$BUILD"
# 按内容比对、不保留修改时间：源码在网络盘上、两边时钟有偏差时，保留时间会让 dotnet 误判「不用重编」
rsync -rlp --checksum --delete --exclude bin --exclude obj --exclude publish "$HERE/" "$BUILD/src/"
# 客户端版本号跟电脑端（desktop/kiteline/app.py 的 VERSION）走：关于页显示的、更新时比对的都是这一个
VERSION="$(sed -n 's/^VERSION = "\(.*\)"$/\1/p' "$HERE/../kiteline/app.py")"
[ -n "$VERSION" ] || { echo "没从 desktop/kiteline/app.py 读到 VERSION" >&2; exit 1; }
[ $# -gt 0 ] || set -- linux-x64 win-x64
for rid in "$@"; do
  echo "==> $rid"
  rm -rf "$HERE/publish/$rid"
  "$DOTNET" publish "$BUILD/src/Kiteline.Client.csproj" -c Release -r "$rid" --self-contained true -nologo -v q -p:Version="$VERSION" -o "$BUILD/out/$rid"
  mkdir -p "$HERE/publish"
  rsync -a --delete "$BUILD/out/$rid/" "$HERE/publish/$rid/"
  echo "    $(du -sh "$HERE/publish/$rid" | cut -f1)  $HERE/publish/$rid"
done
