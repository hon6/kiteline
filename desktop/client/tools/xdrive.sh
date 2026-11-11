#!/bin/bash
# 起 Xvfb :77 + 客户端真窗口（连 ~/klc 测试后台）
D=${XDRIVE_DIR:-/tmp/kl-xdrive}; mkdir -p $D; [ -x $D/venv/bin/python ] || { python3 -m venv $D/venv && $D/venv/bin/pip -q install python-xlib pillow; }
for f in $D/x.pid $D/c.pid; do [ -f $f ] && kill $(cat $f) 2>/dev/null; done; sleep 2
Xvfb :77 -screen 0 1440x900x24 >/dev/null 2>&1 &
echo $! > $D/x.pid
sleep 1
mkdir -p $D/cfg $D/xdg
DISPLAY=:77 KITELINE_CONFIG_DIR=$D/cfg XDG_CONFIG_HOME=$D/xdg LANG=zh_CN.UTF-8 PATH=$HOME/.dotnet:$PATH \
  setsid nohup dotnet ~/klc/client/bin/Debug/net10.0/KitelineApp.dll --server http://127.0.0.1:28765 --token devtoken > $D/client.log 2>&1 &
echo $! > $D/c.pid
sleep 8
DISPLAY=:77 $D/venv/bin/python $(dirname "$0")/xdrive.py shot $D/s0.png
