#!/usr/bin/env bash
# 结束正在运行的 Kiteline（连同改名前的 TARS / CC Pulse），再在后台打开指定的 App（不抢前台）。
#   bash tools/mac-app-restart.sh /Applications/Kiteline.app
# install.sh、tools/rotate-ca.sh 用。两个坑（11-20 实测）：
#  1. macOS 的 pgrep / pkill 默认跳过调用者自己的祖先进程（要 -a 才算进去，Linux 没这规矩）：在 Kiteline 的会话终端里跑时
#     shell 是 Kiteline 的子孙，pkill 找不到 Kiteline，旧版一直跑着、新版装了没生效。这里用 ps 找。
#  2. Kiteline 一退出，它的会话终端跟着关，watcher 给整个进程组发 SIGHUP / SIGKILL，nohup 也躲不过：
#     「结束 → 等退出 → 打开」交给另起一个会话（perl setsid）的进程做，调用的脚本被一起带走也不影响。
set -euo pipefail
APP="${1:?用法：mac-app-restart.sh <要打开的 .app>}"
LOG="${TMPDIR:-/tmp}/kiteline-restart.log"

PIDS=$(ps -axo pid=,command= | awk '{ pid = $1; sub(/^ *[0-9]+ /, "") }
  /\/(Kiteline|TARS)\.app\/Contents\/MacOS\/(TARS|Kiteline)( |$)|\/CC Pulse\.app\/Contents\/MacOS\/CCPulse( |$)/ { print pid }' | tr '\n' ' ')

# 自己是不是在 Kiteline 里面跑（会话终端）：是的话 Kiteline 一退出这里就会被带走
inside=0
p=$$
while [ -n "$p" ] && [ "$p" -gt 1 ]; do
  case " $PIDS " in *" $p "*) inside=1; break ;; esac
  p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
done

: > "$LOG"
/usr/bin/perl -MPOSIX -e 'fork and exit; POSIX::setsid(); exec @ARGV' /bin/bash -c '
  pids="$1"; app="$2"
  for p in $pids; do kill "$p" 2>/dev/null || true; done
  for i in $(seq 1 60); do
    alive=0; for p in $pids; do kill -0 "$p" 2>/dev/null && alive=1; done
    [ "$alive" = 0 ] && break; sleep 0.25
  done
  for p in $pids; do kill -0 "$p" 2>/dev/null && { echo "进程 $p 15 秒没退出，强制结束"; kill -9 "$p" 2>/dev/null || true; }; done
  sleep 0.5
  open -g "$app" && echo "RESTARTED $app"' _ "$PIDS" "$APP" >> "$LOG" 2>&1 < /dev/null

if [ "$inside" = 1 ]; then
  echo "    这个终端是 Kiteline 的会话终端：Kiteline 马上退出并重新打开，终端会随之关闭（日志 ${LOG}）"
fi
for i in $(seq 1 80); do
  grep -q '^RESTARTED' "$LOG" 2>/dev/null && break
  sleep 0.25
done
if grep -q '^RESTARTED' "$LOG"; then
  echo "    已重新打开：$APP${PIDS:+（结束了旧进程 ${PIDS}）}"
else
  echo "    ! 20 秒内没等到重新打开，看 $LOG" >&2
  exit 1
fi
