#!/bin/bash
# 装依赖（国内镜像，默认华为云，可用 NPM_REGISTRY 换；版本按 package-lock.json 锁定）并打包编辑器内核。
# 依赖装在本机缓存目录（仓库可能在网络盘上，node_modules 放那里又慢又容易出错），打包结果写回仓库
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORK="${KL_EDITOR_WORK:-$HOME/.cache/kl-editor}"
NODE_BIN="${NODE_BIN:-$(command -v node || echo "$HOME/kl-node/bin/node")}"
export PATH="$(dirname "$NODE_BIN"):$PATH"
REGISTRY="${NPM_REGISTRY:-https://repo.huaweicloud.com/repository/npm/}"
mkdir -p "$WORK"
rsync -rl --delete --exclude node_modules "$HERE/" "$WORK/"
cd "$WORK"
if [ -f package-lock.json ]; then
  npm ci --registry="$REGISTRY" --no-audit --no-fund
else
  npm install --registry="$REGISTRY" --no-audit --no-fund
  cp package-lock.json "$HERE/package-lock.json"
fi
KL_ROOT="$ROOT" node build.mjs
