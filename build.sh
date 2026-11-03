#!/usr/bin/env bash
# 构建 TARS.app
#   ./build.sh          仅构建
#   ./build.sh install  构建后安装到 /Applications
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

APP_NAME="Kiteline"
EXEC_NAME="TARS"
BUNDLE_ID="com.mrhong.tars"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CACHE="$ROOT/.build-cache"
# 架构：平时只编 Apple 芯片（本机自用）；官网下载版（release.sh）传 ARCHS="arm64 x86_64" 编通用版，Intel Mac 也能装
ARCHS="${ARCHS:-arm64}"
rust_triple() { if [ "$1" = x86_64 ]; then echo x86_64-apple-darwin; else echo aarch64-apple-darwin; fi; }

# 装了 Xcode 但还没同意许可协议时，xcrun 会拒绝工作；有命令行工具就先用它编译
if ! xcrun swiftc --version >/dev/null 2>&1 && [ -d /Library/Developer/CommandLineTools ]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
  echo "==> Xcode 不可用（未同意许可协议？），改用命令行工具编译"
fi

# Swift 需要有可写的模块缓存目录（沙箱/权限受限环境下默认路径会失败）
export CLANG_MODULE_CACHE_PATH="$CACHE"
export SWIFT_MODULECACHE_PATH="$CACHE"
mkdir -p "$CACHE"

echo "==> 清理旧产物"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 校验 watcher 版本一致性"
PY_VER=$(grep -m1 -o 'WATCHER_VERSION = "[^"]*"' watcher/kiteline-watch.py | sed 's/.*"\(.*\)"/\1/')
SWIFT_VER=$(grep -m1 -o 'watcherScriptVersion = "[^"]*"' Sources/AppVersion.swift | sed 's/.*"\(.*\)"/\1/')
if [ -z "$PY_VER" ] || [ "$PY_VER" != "$SWIFT_VER" ]; then
  echo "    版本不一致：watcher/kiteline-watch.py=$PY_VER Sources/AppVersion.swift=$SWIFT_VER"
  echo "    两者必须相同，否则 App 不会重新部署远端/本机的 watcher。"
  exit 1
fi
echo "    watcher v$PY_VER"

echo "==> 编译点对点连接（远程访问）"
# 开源版没有 p2p/（远程访问组件不开源）：跳过，Sources/P2P.swift 换成替身，编出来的只能在同一个网络里连
HAS_P2P=""
[ -f "$ROOT/p2p/Cargo.toml" ] && HAS_P2P=1
for arch in $ARCHS; do
  case "$arch" in
    arm64|x86_64) ;;
    *) echo "    不支持的架构：${arch}（只有 arm64、x86_64）" >&2; exit 1 ;;
  esac
  [ -n "$HAS_P2P" ] || continue
  case "$arch" in
    arm64) bash "$ROOT/p2p/build.sh" macos ;;
    x86_64) bash "$ROOT/p2p/build.sh" macos-intel ;;
  esac
done
[ -n "$HAS_P2P" ] || echo "    没有 p2p/：跳过（远程访问不可用）"

echo "==> 编译终端（SwiftTerm，vendor/SwiftTerm）"
# 会话里的终端用的终端模拟器（MIT，github.com/migueldeicaza/SwiftTerm v1.20.0），编成单独的模块；
# 四万多行、一次三十多秒：按源码内容缓存，没改过就直接用上次编好的
ST_HASH=$(find "$ROOT/vendor/SwiftTerm/Sources" -name '*.swift' -type f -print0 | sort -z | xargs -0 shasum | shasum | cut -c1-12)
ST="$CACHE/swiftterm-$ST_HASH"
for arch in $ARCHS; do
  if [ ! -f "$ST/$arch/libSwiftTerm.a" ]; then
    STTMP="$ST/$arch.tmp-$$"
    rm -rf "$STTMP"; mkdir -p "$STTMP"
    swiftc -O -parse-as-library -swift-version 5 -module-name SwiftTerm -target "$arch-apple-macosx14.0" \
      -emit-library -static -emit-module -emit-module-path "$STTMP/SwiftTerm.swiftmodule" -o "$STTMP/libSwiftTerm.a" \
      $(find "$ROOT/vendor/SwiftTerm/Sources/SwiftTerm" -name '*.swift' | sort)
    rm -rf "$ST/$arch"; mv "$STTMP" "$ST/$arch"
  fi
done

echo "==> 编译对话页（和 iOS App 同一套代码，KitelineKit）"
# 编成单独的模块 KitelineKit：iOS 那边的类型名（SessionRow、HistoryView……）和 Mac 这边重名，分开编互不干扰；
# Mac 只用它公开的几样（见 KitelineKit/MacEmbed.swift）。手机专用的页面（配对、引导、设置、首页）不编进来
# 每次编译用自己的目录：几个会话同时跑 build.sh 时不会互相删掉对方编到一半的模块
KIT="$CACHE/tarskit-$$"
rm -rf "$KIT"; mkdir -p "$KIT"
trap 'rm -rf "$KIT"' EXIT
KIT_SOURCES=$(find "$ROOT/KitelineKit" -name '*.swift' ! -path '*/Watch/*' ! -path '*/Shared/*' \
  ! -name TARSApp.swift ! -name PairView.swift ! -name Glass.swift ! -name OnboardingView.swift ! -name ReadinessView.swift \
  ! -name SettingsView.swift ! -name SettingsPages.swift ! -name SessionListView.swift ! -name MainView.swift ! -name Snapshot.swift | sort)
# 纸鸢的形状、各 agent 的标志（App 图标、iPhone、手表、Mac 共用一份）在 KitelineKit/Shared 里，也编进来
KIT_SOURCES="$KIT_SOURCES $ROOT/KitelineKit/Shared/PaperKite.swift $ROOT/KitelineKit/Shared/AgentMark.swift $ROOT/KitelineKit/Shared/Lang.swift"
for arch in $ARCHS; do
  mkdir -p "$KIT/$arch"
  swiftc \
    -O \
    -parse-as-library \
    -swift-version 5 \
    -module-name KitelineKit \
    -D KITELINE_MAC \
    -target "$arch-apple-macosx14.0" \
    -I "$ST/$arch" \
    -emit-library -static \
    -emit-module -emit-module-path "$KIT/$arch/KitelineKit.swiftmodule" \
    -o "$KIT/$arch/libKitelineKit.a" \
    $KIT_SOURCES
done

echo "==> 编译 Swift 源码（${ARCHS}）"
SOURCES=$(find "$ROOT/Sources" -name '*.swift' | sort)
BINS=()
for arch in $ARCHS; do
  P2P_FLAGS=()
  [ -n "$HAS_P2P" ] && P2P_FLAGS=(-I "$ROOT/p2p/include" -L "$ROOT/p2p/target/$(rust_triple "$arch")/release")
  swiftc \
    -O \
    -parse-as-library \
    -target "$arch-apple-macosx14.0" \
    ${P2P_FLAGS[@]+"${P2P_FLAGS[@]}"} \
    -I "$ROOT/vendor/sherpa-onnx/include" \
    -I "$KIT/$arch" -L "$KIT/$arch" -lKitelineKit \
    -I "$ST/$arch" -L "$ST/$arch" -lSwiftTerm \
    -framework AppKit \
    -framework UserNotifications \
    -framework Security \
    -framework SystemConfiguration \
    -o "$KIT/$arch/$EXEC_NAME" \
    $SOURCES
  BINS+=("$KIT/$arch/$EXEC_NAME")
done
# 多个架构合成一个通用二进制（只有一个时就是原样拷过去）
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/$EXEC_NAME"

echo "==> 拷贝资源"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# 强调色（品牌橙）：选中、开关、链接、焦点框、弹出面板默认都用它（系统设置里强调色是「多色」时生效）
if xcrun --find actool >/dev/null 2>&1; then
  xcrun actool "$ROOT/Resources/Assets.xcassets" --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --output-partial-info-plist "$CACHE/assets-info.plist" >/dev/null
else
  echo "    没有 actool（只有命令行工具）：跳过强调色"
fi
# 远端 watcher 打进 App 包，首次运行时自动部署到远端
cp "$ROOT/watcher/kiteline-watch.py" "$APP/Contents/Resources/ccpulse-watch.py"
cp "$ROOT/CHANGELOG.md" "$APP/Contents/Resources/CHANGELOG.md"
cp "$ROOT/CHANGELOG.en.md" "$APP/Contents/Resources/CHANGELOG.en.md"   # 英文界面看的更新记录（和中文版同步维护）
cp "$ROOT/Resources/ThirdPartyNotices.json" "$APP/Contents/Resources/"   # 设置 → 关于 →「开源许可」（tools/licenses.py 生成）
# 英文：界面文字（Localizable.strings / .stringsdict，由 tools/i18n.py build 生成）和权限说明（InfoPlist.strings）
cp -R "$ROOT/Resources/en.lproj" "$APP/Contents/Resources/"
# 网页版已下线（10-22）：Resources/web 不再打进 App，服务端根路径只回说明页（见 MobileServer.noticePage）
# 世界模式的网页（three.js，各端共用一份，见 Sources/WorldView.swift、docs/world.md）
cp -R "$ROOT/Resources/world" "$APP/Contents/Resources/"
# 代码 IDE 的编辑器内核（CodeMirror 6 打成一个 HTML，iPhone / Mac 共用；tools/editor/build.sh 生成）
cp -R "$ROOT/Resources/editor" "$APP/Contents/Resources/"
# 游客链接（局域网只读分享）看的页面：电脑自己在 /g/<编号> 给（见 Sources/GuestLinks.swift）
cp -R "$ROOT/Resources/guest" "$APP/Contents/Resources/"
# 本机离线语音识别库（sherpa-onnx，只有 arm64）：运行时 dlopen，加载不到就退回系统语音识别（见 Sources/LocalASR.swift）
if ls "$ROOT/vendor/sherpa-onnx/lib/"*.dylib >/dev/null 2>&1; then
  mkdir -p "$APP/Contents/Frameworks"
  cp "$ROOT/vendor/sherpa-onnx/lib/"*.dylib "$APP/Contents/Frameworks/"
fi

echo "==> 生成图标"
ICONSET="$CACHE/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
# 图标脚本要和纸鸢形状（KitelineKit/Shared/PaperKite.swift）一起编译：有顶层代码的文件得叫 main.swift
MKICON="$KIT/make-icon"; mkdir -p "$MKICON"
cp "$ROOT/tools/make-icon.swift" "$MKICON/main.swift"
xcrun swiftc -O -o "$MKICON/make-icon" "$MKICON/main.swift" "$ROOT/KitelineKit/Shared/PaperKite.swift"
"$MKICON/make-icon" "$CACHE/icons" >/dev/null
for size in 16 32 64 128 256 512 1024; do
  src="$CACHE/icons/icon_${size}.png"
  [ -f "$src" ] || continue
  case "$size" in
    16)   cp "$src" "$ICONSET/icon_16x16.png";      cp "$src" "$ICONSET/icon_16x16@2x.png" ;;
    32)   cp "$src" "$ICONSET/icon_32x32.png";      cp "$src" "$ICONSET/icon_32x32@2x.png" ;;
    64)   cp "$src" "$ICONSET/icon_32x32@2x.png" ;;
    128)  cp "$src" "$ICONSET/icon_128x128.png" ;;
    256)  cp "$src" "$ICONSET/icon_128x128@2x.png"; cp "$src" "$ICONSET/icon_256x256.png" ;;
    512)  cp "$src" "$ICONSET/icon_256x256@2x.png"; cp "$src" "$ICONSET/icon_512x512.png" ;;
    1024) cp "$src" "$ICONSET/icon_512x512@2x.png" ;;
  esac
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> 生成 PkgInfo"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 签名：用这台 Mac 自己的固定签名身份。
# 辅助功能、语音识别这些授权是跟着签名走的；ad-hoc 签名每次构建都不一样，
# 每更新一次 macOS 就把授权当成新 App 作废。固定身份签出来的「指定要求」是
# 「bundle id + 证书指纹」，每次都一样，授权一次以后更新都保留。
# 证书和私钥放在一个专用钥匙串里（随机密码存在旁边、只有本人可读），不碰登录钥匙串、不弹窗。
SIGN_DIR="$HOME/Library/Application Support/TARS/signing"
SIGN_KC="$SIGN_DIR/tars-signing.keychain-db"
SIGN_ID="TARS Local Signing"

ensure_signing_identity() {
  if [ -f "$SIGN_KC" ] && [ -f "$SIGN_DIR/keychain-password" ] \
     && security find-certificate -c "$SIGN_ID" "$SIGN_KC" >/dev/null 2>&1; then
    return 0
  fi
  echo "    第一次构建：生成这台 Mac 专用的签名身份（自签证书，10 年）"
  mkdir -p "$SIGN_DIR" && chmod 700 "$SIGN_DIR"
  rm -f "$SIGN_KC"
  local tmp; tmp="$(mktemp -d)"
  /usr/bin/openssl rand -hex 24 > "$SIGN_DIR/keychain-password" && chmod 600 "$SIGN_DIR/keychain-password"
  local pw; pw="$(cat "$SIGN_DIR/keychain-password")"
  cat > "$tmp/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $SIGN_ID
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -days 3650 -nodes \
    -config "$tmp/openssl.cnf" >/dev/null 2>&1 \
  && /usr/bin/openssl pkcs12 -export -out "$tmp/id.p12" -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -passout "pass:$pw" -name "$SIGN_ID" >/dev/null 2>&1 \
  && security create-keychain -p "$pw" "$SIGN_KC" >/dev/null 2>&1 \
  && security set-keychain-settings "$SIGN_KC" \
  && security unlock-keychain -p "$pw" "$SIGN_KC" \
  && security import "$tmp/id.p12" -k "$SIGN_KC" -P "$pw" -T /usr/bin/codesign >/dev/null 2>&1 \
  && security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pw" "$SIGN_KC" >/dev/null 2>&1
  local ok=$?
  rm -rf "$tmp"
  return $ok
}

echo "==> 签名"
if ensure_signing_identity \
   && security unlock-keychain -p "$(cat "$SIGN_DIR/keychain-password")" "$SIGN_KC" \
   && codesign --force --deep --keychain "$SIGN_KC" --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1; then
  echo "    固定本机签名：$(codesign -dr - "$APP" 2>&1 | grep -o 'H"[0-9a-f]*"' | head -1)（授权跨版本保留）"
else
  echo "    固定签名不可用，退回 ad-hoc（每次更新后要重新给辅助功能 / 语音识别授权）"
  codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP" 2>&1 | sed 's/^/    /'
fi

echo "==> 完成：$APP"
if [ "${1:-}" = "install" ]; then
  DEST="/Applications/$APP_NAME.app"
  echo "==> 安装到 $DEST"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "==> 已安装。启动：open \"$DEST\""
fi
