#!/usr/bin/env bash
# Kiteline 集成测试（在 Mac 上运行）
#   1. watcher：分页、增量、发图、路径安全；Codex / OpenCode 接入（假守护进程、假插件服务）（纯 Python，合成数据）
#   2. 手机服务接口：用 dry-run 方式起一个隔离的 App 实例，挂合成会话，逐个接口断言
#   3. 推送加密：装了 python 的 cryptography 库时，用它按 RFC 8291/8292 独立解密核对
#
# 全程只写临时目录，不碰真实的 ~/.claude，也不会往 VS Code 里送任何东西（CCPULSE_DRY_RUN=1）。
# 前置：已构建 dist/Kiteline.app（./build.sh）
#
# 用法：bash tests/run-integration.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Kiteline.app"
PY=/Library/Developer/CommandLineTools/usr/bin/python3
[ -x "$PY" ] || PY=python3
TMP="$(mktemp -d /tmp/ccpulse-it.XXXXXX)"
PORT=$((20000 + RANDOM % 20000))
HTTPS_PORT=$((PORT + 1))
TOKEN="it-$RANDOM$RANDOM"
FAILED=0

cleanup() {
  pkill -f "CCPULSE_IT_MARK=$TMP" 2>/dev/null
  if [ -n "${APP_PID:-}" ]; then kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; fi
  [ -f "$TMP/fake/pids" ] && xargs kill 2>/dev/null < "$TMP/fake/pids"
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "==== 1/3 watcher ===="
"$PY" "$ROOT/tests/test_watcher.py" || FAILED=1
"$PY" "$ROOT/tests/test_agents.py" || FAILED=1

echo ""
echo "==== 2/3 手机服务接口 ===="
[ -x "$APP/Contents/MacOS/TARS" ] || { echo "先运行 ./build.sh"; exit 1; }
"$PY" "$ROOT/tests/fixture.py" "$TMP/fake" >/dev/null
mkdir -p "$TMP/config"
cat > "$TMP/config/config.json" <<JSON
{"sources":[{"id":"local","name":"本机","kind":"local","remoteWatcherPath":"$TMP/bin/ccpulse-watch.py"}],
 "mobile":{"enabled":true,"port":$PORT,"bindAddress":"127.0.0.1","token":"$TOKEN","installAgentSkill":false,"installTestSkill":false,"installTodoSkill":false,"installOpenCodePlugin":false},
 "connectOnLaunch":true}
JSON
CCPULSE_CONFIG_DIR="$TMP/config" CCPULSE_DRY_RUN=1 CCPULSE_FAKE_TRANSCRIPT="帮我看一下首页的按钮" \
  CCPULSE_SESSIONS_DIR="$TMP/fake/sessions" CCPULSE_DATA_DIR="$TMP/fake/data" CLAUDE_CONFIG_DIR="$TMP/fake/claude" CODEX_HOME="$TMP/codex" DSH_HOME="$TMP/dsh" CCPULSE_PROMA_DIR="$TMP/proma" \
  XDG_CONFIG_HOME="$TMP/xdg-config" XDG_DATA_HOME="$TMP/xdg-data" \
  "$APP/Contents/MacOS/TARS" --selftest-exit 120 >/dev/null 2>&1 &
APP_PID=$!
for _ in $(seq 1 40); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
  sleep 0.25
done
"$PY" "$ROOT/tests/test_api.py" "$PORT" "$HTTPS_PORT" "$TOKEN" "$TMP/config" "$TMP/fake/data" || FAILED=1

echo ""
echo "==== 3/3 推送加密 ===="
if "$PY" -c "import cryptography" 2>/dev/null; then
  CCPULSE_CONFIG_DIR="$TMP/config" "$PY" "$ROOT/tests/test_webpush.py" "$APP/Contents/MacOS/TARS" || FAILED=1
else
  echo "  （跳过：没装 python 的 cryptography 库。pip3 install cryptography 后可运行）"
fi

echo ""
if [ "$FAILED" = 0 ]; then echo "全部通过 ✓"; else echo "有失败项 ✗"; fi
exit $FAILED
