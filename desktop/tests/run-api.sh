#!/usr/bin/env bash
# 用 Mac 版的接口测试（tests/test_api.py）测电脑端：隔离的数据目录 + 合成会话 + dry-run（不往 VS Code 里送东西）
#   bash desktop/tests/run-api.sh [python]     默认用 desktop/.venv 或 PATH 里的 python3
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP="$(dirname "$HERE")"
ROOT="$(dirname "$DESKTOP")"
PY="${1:-${KITELINE_PYTHON:-python3}}"
TMP="$(mktemp -d /tmp/kiteline-it.XXXXXX)"
PORT=$((20000 + RANDOM % 20000))
TOKEN="it-$RANDOM$RANDOM"

cleanup() {
  [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null && wait "$APP_PID" 2>/dev/null
  [ -f "$TMP/fake/pids" ] && xargs kill 2>/dev/null < "$TMP/fake/pids"
  rm -rf "$TMP"
}
trap cleanup EXIT

"$PY" "$ROOT/tests/fixture.py" "$TMP/fake" >/dev/null
mkdir -p "$TMP/config"
cat > "$TMP/config/config.json" <<JSON
{"sources":[{"id":"local","name":"本机","kind":"local","remoteWatcherPath":"$TMP/bin/ccpulse-watch.py"}],
 "mobile":{"enabled":true,"port":$PORT,"bindAddress":"127.0.0.1","token":"$TOKEN","installAgentSkill":false,"remoteEnabled":false}}
JSON
cd "$DESKTOP"
CCPULSE_CONFIG_DIR="$TMP/config" CCPULSE_DRY_RUN=1 CCPULSE_FAKE_TRANSCRIPT="帮我看一下首页的按钮" \
  CCPULSE_SESSIONS_DIR="$TMP/fake/sessions" CCPULSE_DATA_DIR="$TMP/fake/data" CLAUDE_CONFIG_DIR="$TMP/fake/claude" CODEX_HOME="$TMP/codex" \
  CCPULSE_PLUGIN_INDEX="http://127.0.0.1:9/plugins/index.json" \
  "$PY" -m kiteline --headless --no-tray > "$TMP/app.out" 2>&1 &
APP_PID=$!
for _ in $(seq 1 60); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
  sleep 0.25
done
sleep 2
"$PY" "$ROOT/tests/test_api.py" "$PORT" "$((PORT + 1))" "$TOKEN" "$TMP/config" "$TMP/fake/data"
STATUS=$?
[ $STATUS -ne 0 ] && tail -30 "$TMP/app.out"
exit $STATUS
