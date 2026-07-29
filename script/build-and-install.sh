#!/usr/bin/env bash
# build-and-install.sh — Codex Monitor Native Prototype 专用构建签名安装脚本
#
# 构建 → 嵌入 Widget → 签名 → 安装 → 启动
#
# 用法:
#   ./script/build-and-install.sh
#   INSTALL_APP_PATH=/tmp/MyApp.app ./script/build-and-install.sh

set -euo pipefail

# ── 项目常量 ─────────────────────────────────────────────────
APP_NAME="CodexMonitorNative"
BUNDLE_ID="com.ryukeilee.CodexMonitorNativePrototype"
APP_GROUP="group.com.ryukeilee.CodexMonitorNativePrototype"
MIN_SYSTEM_VERSION="14.0"
MARKETING_VERSION="${APP_MARKETING_VERSION:-0.1.0}"
BUILD_VERSION="${APP_BUILD_VERSION:-1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DIST_DIR="$ROOT_DIR/dist"
INSTALL_APP="${INSTALL_APP_PATH:-/Applications/${APP_NAME}.app}"

APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_PLUGINS="$APP_CONTENTS/PlugIns"
APP_BINARY="$APP_MACOS/$APP_NAME"

ENTITLEMENTS_APP="$ROOT_DIR/Assets/CodexMonitorNative.entitlements"
ENTITLEMENTS_WIDGET="$ROOT_DIR/Assets/CodexMonitorWidgetExtension.entitlements"
WIDGET_PROJECT="$ROOT_DIR/CodexMonitorWidgetExtension.xcodeproj"
WIDGET_NAME="CodexMonitorWidgetExtension"
WIDGET_BUILD_DIR="$ROOT_DIR/.build/xcode-widget"

# ── 自动选择签名身份 ────────────────────────────────────────
resolve_signing_identity() {
  # 优先使用环境变量
  [ -n "${CODESIGN_IDENTITY:-}" ] && echo "$CODESIGN_IDENTITY" && return 0
  # 尝试 Apple Development 证书
  local id
  id="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(.*Apple Development.*\)".*/\1/p' | head -1)" || true
  [ -n "$id" ] && echo "$id" && return 0
  # 备用：取第一个开发证书的 SHA-1
  id="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Apple Development/{print $2; exit}')" || true
  [ -n "$id" ] && echo "$id" && return 0
  # 兜底：ad-hoc
  echo "-"
}
SIGN_IDENTITY="$(resolve_signing_identity)"

# ── 工具函数 ─────────────────────────────────────────────────
info()  { printf '\033[36m[build]\033[0m %s\n' "$*"; }
ok()    { printf '\033[32m[build]\033[0m %s\n' "$*"; }
fail()  { printf '\033[31m[build] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ── 1. 构建主应用 (SwiftPM) ──────────────────────────────────
info "=== Build $APP_NAME (SwiftPM) ==="
BD="$ROOT_DIR/.build"
export CLANG_MODULE_CACHE_PATH="$BD/ModuleCache"
swift build -c debug --scratch-path "$BD/scratch" --cache-path "$BD/cache"
BP="$(swift build -c debug --scratch-path "$BD/scratch" --show-bin-path)"
[ -x "$BP/$APP_NAME" ] || fail "二进制文件未找到: $BP/$APP_NAME"

# ── 2. 组装 .app bundle ──────────────────────────────────────
info "=== Assemble $APP_NAME.app ==="
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_PLUGINS"

# 拷贝可执行文件
cp "$BP/$APP_NAME" "$APP_BINARY"
chmod +x "$APP_BINARY"

# 生成 Info.plist
cat > "$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$MARKETING_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

# 生成 AppIcon (SVG → icns)
ICON_SVG="$ROOT_DIR/Assets/AppIcon.svg"
if [ -f "$ICON_SVG" ]; then
  ICONSET="$DIST_DIR/AppIcon.iconset"
  mkdir -p "$ICONSET"
  # 依赖: librsvg (rsvg-convert) + iconutil
  if command -v rsvg-convert &>/dev/null; then
    for dim in 16 32 64 128 256 512 1024; do
      rsvg-convert -w "$dim" -h "$dim" "$ICON_SVG" > "$ICONSET/icon_${dim}x${dim}.png" 2>/dev/null || true
    done
    # Retina: 16x16@2x = 32, 32x32@2x = 64, 128x128@2x = 256, 256x256@2x = 512, 512x512@2x = 1024
    rsvg-convert -w 32  -h 32  "$ICON_SVG" > "$ICONSET/icon_16x16@2x.png" 2>/dev/null || true
    rsvg-convert -w 64  -h 64  "$ICON_SVG" > "$ICONSET/icon_32x32@2x.png" 2>/dev/null || true
    rsvg-convert -w 256 -h 256 "$ICON_SVG" > "$ICONSET/icon_128x128@2x.png" 2>/dev/null || true
    rsvg-convert -w 512 -h 512 "$ICON_SVG" > "$ICONSET/icon_256x256@2x.png" 2>/dev/null || true
    rsvg-convert -w 1024 -h 1024 "$ICON_SVG" > "$ICONSET/icon_512x512@2x.png" 2>/dev/null || true
    iconutil -c icns "$ICONSET" -o "$APP_RESOURCES/AppIcon.icns" 2>/dev/null || true
    rm -rf "$ICONSET"
  else
    info "librsvg (rsvg-convert) 未安装，跳过图标生成"
  fi
fi

# ── 3. 构建 & 嵌入 Widget ────────────────────────────────────
if [ -d "$WIDGET_PROJECT" ]; then
  info "=== Build Widget ==="
  WPD="$WIDGET_BUILD_DIR/Debug"
  mkdir -p "$WPD"
  xcodebuild -project "$WIDGET_PROJECT" -scheme "$WIDGET_NAME" \
    -configuration Debug -destination "platform=macOS" \
    -derivedDataPath "$WIDGET_BUILD_DIR/DerivedData" \
    CONFIGURATION_BUILD_DIR="$WPD" \
    MARKETING_VERSION="$MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_VERSION" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    build
  [ -d "$WPD/${WIDGET_NAME}.appex" ] || fail "Widget 产物未找到"
  ditto --norsrc --noextattr "$WPD/${WIDGET_NAME}.appex" "$APP_PLUGINS/$WIDGET_NAME.appex"
  xattr -cr "$APP_PLUGINS/$WIDGET_NAME.appex"
  ok "Widget: $APP_PLUGINS/$WIDGET_NAME.appex"
fi

# ── 4. 签名 ──────────────────────────────────────────────────
info "=== Sign (identity: $SIGN_IDENTITY) ==="

# 移除测试 bundle（如有）
[ -d "$APP_PLUGINS/${APP_NAME}Tests.xctest" ] && rm -rf "$APP_PLUGINS/${APP_NAME}Tests.xctest"

# 签名 Widget
for widget in "$APP_PLUGINS"/*.appex; do
  [ -d "$widget" ] || continue
  wname="$(basename "$widget")"
  if [ -f "$ENTITLEMENTS_WIDGET" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
      --entitlements "$ENTITLEMENTS_WIDGET" "$widget"
  else
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
      --generate-entitlement-der "$widget"
  fi
  info "  signed: $wname"
done

# 签名主应用
xattr -cr "$APP_BUNDLE"
if [ -f "$ENTITLEMENTS_APP" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
    --entitlements "$ENTITLEMENTS_APP" "$APP_BUNDLE"
else
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
    --generate-entitlement-der "$APP_BUNDLE"
fi

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | tail -3
ok "Signing verified"

# ── 5. 安装 ──────────────────────────────────────────────────
info "=== Install to $INSTALL_APP ==="

# 停止旧实例
OLD_PIDS="$(pgrep -x "$APP_NAME" 2>/dev/null || true)"
if [ -n "$OLD_PIDS" ]; then
  kill $OLD_PIDS 2>/dev/null || true
  for _ in $(seq 1 20); do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.25
  done
  REMAINING="$(pgrep -x "$APP_NAME" 2>/dev/null || true)"
  [ -z "$REMAINING" ] || kill -KILL $REMAINING 2>/dev/null || true
  info "Stopped old process(es): $OLD_PIDS"
fi

# 备份旧安装
if [ -d "$INSTALL_APP" ]; then
  BACKUP="${INSTALL_APP}.bak.$(date +%s)"
  mv "$INSTALL_APP" "$BACKUP"
  info "Backed up old install: $BACKUP"
fi

# 安装
mkdir -p "$(dirname "$INSTALL_APP")"
ditto "$APP_BUNDLE" "$INSTALL_APP"

# 注册 Widget
pluginkit -a "$INSTALL_APP/Contents/PlugIns/"*.appex 2>/dev/null || true
lsregister -f -R -trusted "$INSTALL_APP" 2>/dev/null || true
ok "Install: $INSTALL_APP"

# ── 6. 启动 ──────────────────────────────────────────────────
info "=== Launch ==="
open -n "$INSTALL_APP"
for _ in $(seq 1 20); do
  pgrep -x "$APP_NAME" >/dev/null 2>&1 && break
  sleep 0.25
done
pgrep -x "$APP_NAME" >/dev/null 2>&1 || fail "应用未能启动"
ok "Running: $APP_NAME"
