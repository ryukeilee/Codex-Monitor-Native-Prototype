#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CodexMonitorNative"
BUNDLE_ID="com.ryukeilee.CodexMonitorNativePrototype"
WIDGET_BUNDLE_ID="${BUNDLE_ID}.widget"
MIN_SYSTEM_VERSION="14.0"
APP_MARKETING_VERSION="${APP_MARKETING_VERSION:-0.1.0}"
APP_BUILD_VERSION="${APP_BUILD_VERSION:-1}"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-debug}"
case "$BUILD_CONFIGURATION" in
  debug)
    XCODE_CONFIGURATION="Debug"
    ;;
  release)
    XCODE_CONFIGURATION="Release"
    ;;
  *)
    XCODE_CONFIGURATION="$BUILD_CONFIGURATION"
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_PLUGINS="$APP_CONTENTS/PlugIns"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
MODULE_CACHE="$ROOT_DIR/.build/ModuleCache"
SCRATCH_PATH="$ROOT_DIR/.build/scratch"
CACHE_PATH="$ROOT_DIR/.build/cache"
CONFIG_PATH="$ROOT_DIR/.build/config"
SECURITY_PATH="$ROOT_DIR/.build/security"
ICON_SOURCE="$ROOT_DIR/Assets/AppIcon.svg"
ICONSET_DIR="$DIST_DIR/AppIcon.iconset"
ICON_FILE="$APP_RESOURCES/AppIcon.icns"
APP_ENTITLEMENTS="$ROOT_DIR/Assets/CodexMonitorNative.entitlements"
WIDGET_NAME="CodexMonitorWidgetExtension"
WIDGET_PROJECT="$ROOT_DIR/CodexMonitorWidgetExtension.xcodeproj"
WIDGET_SCHEME="$WIDGET_NAME"
WIDGET_BUILD_DIR="$ROOT_DIR/.build/xcode-widget"
WIDGET_PRODUCTS_DIR="$WIDGET_BUILD_DIR/$XCODE_CONFIGURATION"
WIDGET_BUNDLE="$WIDGET_PRODUCTS_DIR/$WIDGET_NAME.appex"
WIDGET_ENTITLEMENTS="$ROOT_DIR/Assets/CodexMonitorWidgetExtension.entitlements"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
INSTALL_APP_PATH="${INSTALL_APP_PATH:-/Applications/$APP_NAME.app}"
INSTALL_STAGING_PATH="${INSTALL_APP_PATH}.incoming.$$"
INSTANCE_OWNER_PATH="${HOME}/Library/Application Support/CodexMonitorNative/InstanceArbitration/v1/owner.json"

usage() {
  echo "用法：$0 [run|--verify|--debug|--logs|--telemetry]"
  echo "  --verify  构建、关闭旧实例、覆盖安装，并验收运行版本、路径和 Widget 绑定"
  echo "  INSTALL_APP_PATH=...        覆盖默认安装路径（默认：${INSTALL_APP_PATH}）"
}

case "$MODE" in
  run|debug|--debug|logs|--logs|telemetry|--telemetry|verify|--verify)
    ;;
  --help|-h)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

ACCEPTANCE_MODE=0
case "$MODE" in
  verify|--verify)
    ACCEPTANCE_MODE=1
    ;;
esac

fail_step() {
  local stage="$1"
  local reason="$2"
  local fix="$3"
  echo "流程失败：$stage" >&2
  echo "原因：$reason" >&2
  echo "修复入口：$fix" >&2
  exit 1
}

stop_running_app() {
  if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    return
  fi

  pkill -TERM -x "$APP_NAME" >/dev/null 2>&1 || true
  for _ in {1..25}; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      return
    fi
    sleep 0.2
  done

  pkill -KILL -x "$APP_NAME" >/dev/null 2>&1 || true
  for _ in {1..10}; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      return
    fi
    sleep 0.2
  done

  fail_step "关闭旧实例" "进程 $APP_NAME 仍在运行，无法安全覆盖安装。" \
    "pkill -TERM -x ${APP_NAME}；确认进程退出后重试 ./script/build_and_run.sh --verify"
}

read_plist_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$2"
}

read_instance_owner_record() {
  local protocol_version instance_id pid started_at activation_count

  [[ -f "$INSTANCE_OWNER_PATH" ]] || return 1
  protocol_version="$(/usr/bin/plutil -extract protocolVersion raw -o - "$INSTANCE_OWNER_PATH" 2>/dev/null)" || return 1
  instance_id="$(/usr/bin/plutil -extract instanceID raw -o - "$INSTANCE_OWNER_PATH" 2>/dev/null)" || return 1
  pid="$(/usr/bin/plutil -extract pid raw -o - "$INSTANCE_OWNER_PATH" 2>/dev/null)" || return 1
  started_at="$(/usr/bin/plutil -extract startedAt raw -o - "$INSTANCE_OWNER_PATH" 2>/dev/null)" || return 1
  activation_count="$(/usr/bin/plutil -extract activationCount raw -o - "$INSTANCE_OWNER_PATH" 2>/dev/null)" || return 1

  [[ "$protocol_version" == "1" && -n "$instance_id" && "$pid" =~ ^[0-9]+$ && -n "$started_at" && "$activation_count" =~ ^[0-9]+$ ]] || return 1

  INSTANCE_OWNER_PROTOCOL_VERSION="$protocol_version"
  INSTANCE_OWNER_ID="$instance_id"
  INSTANCE_OWNER_PID="$pid"
  INSTANCE_OWNER_STARTED_AT="$started_at"
  INSTANCE_OWNER_ACTIVATION_COUNT="$activation_count"
}

running_app_pids() {
  pgrep -x "$APP_NAME" || true
}

verify_cross_copy_instance_arbitration() {
  local installed_binary="$INSTALL_APP_PATH/Contents/MacOS/$APP_NAME"
  local owner_pid owner_instance_id owner_activation_count running_pids running_command
  local arbitration_ready=0

  [[ "$APP_BUNDLE" != "$INSTALL_APP_PATH" ]] || fail_step "校验单实例仲裁" \
    "安装路径与 dist 挑战副本相同，无法验证跨副本仲裁。" \
    "设置不同的 INSTALL_APP_PATH 后重试 ./script/build_and_run.sh --verify"

  for _ in {1..25}; do
    if read_instance_owner_record; then
      arbitration_ready=1
      break
    fi
    sleep 0.2
  done
  [[ "$arbitration_ready" -eq 1 ]] || fail_step "校验单实例仲裁" \
    "未读取到有效 owner 记录：${INSTANCE_OWNER_PATH}。" \
    "确认已安装版成功启动并创建 InstanceArbitration/v1/owner.json 后重试"

  owner_pid="$INSTANCE_OWNER_PID"
  owner_instance_id="$INSTANCE_OWNER_ID"
  owner_activation_count="$INSTANCE_OWNER_ACTIVATION_COUNT"
  [[ "$owner_pid" == "$1" ]] || fail_step "校验单实例仲裁" \
    "owner 记录 PID 为 ${owner_pid}，与已安装实例 PID ${1} 不一致。" \
    "确认旧副本均已退出后重试 ./script/build_and_run.sh --verify"

  open_app "$APP_BUNDLE"

  for _ in {1..25}; do
    if read_instance_owner_record; then
      running_pids="$(running_app_pids)"
      if [[ "$running_pids" == "$owner_pid" \
        && "$INSTANCE_OWNER_PID" == "$owner_pid" \
        && "$INSTANCE_OWNER_ID" == "$owner_instance_id" \
        && (( 10#$INSTANCE_OWNER_ACTIVATION_COUNT > 10#$owner_activation_count )) ]]; then
        break
      fi
    fi
    sleep 0.2
  done

  running_pids="$(running_app_pids)"
  [[ "$running_pids" == "$owner_pid" ]] || fail_step "校验单实例仲裁" \
    "启动 dist 挑战副本后运行 PID 为 ${running_pids:-无}，预期唯一已安装实例 PID 为 ${owner_pid}。" \
    "检查挑战副本是否在激活 owner 后退出，再重试 ./script/build_and_run.sh --verify"
  [[ "$INSTANCE_OWNER_PID" == "$owner_pid" && "$INSTANCE_OWNER_ID" == "$owner_instance_id" ]] || fail_step "校验单实例仲裁" \
    "owner 记录在挑战后发生了 PID 或 instanceID 切换。" \
    "检查跨副本仲裁是否保留原 owner，再重试 ./script/build_and_run.sh --verify"
  (( 10#$INSTANCE_OWNER_ACTIVATION_COUNT > 10#$owner_activation_count )) || fail_step "校验单实例仲裁" \
    "owner activationCount 未增长（启动前 ${owner_activation_count}，当前 ${INSTANCE_OWNER_ACTIVATION_COUNT}）。" \
    "检查挑战副本是否向 owner 发送 showPopover 激活请求后重试"

  running_command="$(ps -p "$owner_pid" -o command= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ "$running_command" == "$installed_binary" || "$running_command" == "$installed_binary "* ]] || fail_step "校验单实例仲裁" \
    "仲裁后的 owner 路径为 ${running_command}，预期为 ${installed_binary}。" \
    "确认已安装版仍为 owner 后重试 ./script/build_and_run.sh --verify"

  echo "  单实例仲裁：已安装 owner PID $owner_pid 保持，activationCount ${owner_activation_count} -> ${INSTANCE_OWNER_ACTIVATION_COUNT}"
}

cleanup_install_stage() {
  if [[ -e "$INSTALL_STAGING_PATH" ]]; then
    rm -rf "$INSTALL_STAGING_PATH" || true
  fi
}

trap cleanup_install_stage EXIT

if [[ "$ACCEPTANCE_MODE" -eq 0 ]]; then
  stop_running_app
fi

if ! mkdir -p "$MODULE_CACHE" "$SCRATCH_PATH" "$CACHE_PATH" "$CONFIG_PATH" "$SECURITY_PATH"; then
  fail_step "准备构建缓存" "无法创建 SwiftPM/Xcode 构建缓存目录。" \
    "检查 .build 目录权限后重试 ./script/build_and_run.sh --verify"
fi

BUILD_FLAGS=(
  --scratch-path "$SCRATCH_PATH"
  --cache-path "$CACHE_PATH"
  --config-path "$CONFIG_PATH"
  --security-path "$SECURITY_PATH"
)

export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

if ! swift build -c "$BUILD_CONFIGURATION" "${BUILD_FLAGS[@]}"; then
  fail_step "构建主应用" "SwiftPM $BUILD_CONFIGURATION 构建失败。" \
    "swift build -c $BUILD_CONFIGURATION"
fi
if ! BUILD_BIN_PATH="$(swift build -c "$BUILD_CONFIGURATION" "${BUILD_FLAGS[@]}" --show-bin-path)"; then
  fail_step "定位构建产物" "无法获取 SwiftPM 二进制目录。" \
    "swift build -c $BUILD_CONFIGURATION --show-bin-path"
fi
BUILD_BINARY="$BUILD_BIN_PATH/$APP_NAME"
if [[ ! -x "$BUILD_BINARY" ]]; then
  fail_step "定位构建产物" "未找到可执行文件：${BUILD_BINARY}。" \
    "swift build -c $BUILD_CONFIGURATION"
fi

if ! (rm -rf "$APP_BUNDLE" && mkdir -p "$APP_MACOS" "$APP_RESOURCES" && cp "$BUILD_BINARY" "$APP_BINARY" && chmod +x "$APP_BINARY"); then
  fail_step "组装应用包" "无法写入构建产物目录：${APP_BUNDLE}。" \
    "检查 dist 目录权限后重试 ./script/build_and_run.sh --verify"
fi

if ! (rm -rf "$ICONSET_DIR" && mkdir -p "$ICONSET_DIR" \
  && swift "$ROOT_DIR/script/svg2png.swift" "$ICON_SOURCE" "$ICONSET_DIR/icon_512x512@2x.png" \
  && /usr/bin/sips -z 16 16 "$ICONSET_DIR/icon_512x512@2x.png" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null \
  && /usr/bin/sips -z 32 32 "$ICONSET_DIR/icon_512x512@2x.png" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null \
  && /usr/bin/sips -z 32 32 "$ICONSET_DIR/icon_512x512@2x.png" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null \
  && /usr/bin/sips -z 64 64 "$ICONSET_DIR/icon_512x512@2x.png" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null \
  && /usr/bin/sips -z 128 128 "$ICONSET_DIR/icon_512x512@2x.png" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null \
  && /usr/bin/sips -z 256 256 "$ICONSET_DIR/icon_512x512@2x.png" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null \
  && /usr/bin/sips -z 256 256 "$ICONSET_DIR/icon_512x512@2x.png" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null \
  && /usr/bin/sips -z 512 512 "$ICONSET_DIR/icon_512x512@2x.png" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null \
  && /usr/bin/sips -z 512 512 "$ICONSET_DIR/icon_512x512@2x.png" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null \
  && /usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$ICON_FILE"); then
  fail_step "生成应用图标" "无法生成 AppIcon.icns。" \
    "确认 sips、iconutil 可用后重试 ./script/build_and_run.sh --verify"
fi

if ! cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
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
  <string>$APP_MARKETING_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD_VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
then
  fail_step "写入应用元数据" "无法写入 Info.plist：${INFO_PLIST}。" \
    "检查 dist 目录权限后重试 ./script/build_and_run.sh --verify"
fi

if [[ -d "$WIDGET_PROJECT" ]]; then
  if ! xcodebuild \
    -project "$WIDGET_PROJECT" \
    -scheme "$WIDGET_SCHEME" \
    -configuration "$XCODE_CONFIGURATION" \
    -destination "platform=macOS" \
    -derivedDataPath "$WIDGET_BUILD_DIR/DerivedData" \
    CONFIGURATION_BUILD_DIR="$WIDGET_PRODUCTS_DIR" \
    MARKETING_VERSION="$APP_MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="$APP_BUILD_VERSION" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build; then
    fail_step "构建 Widget" "xcodebuild 无法构建 ${WIDGET_NAME}。" \
      "xcodebuild -project $WIDGET_PROJECT -scheme $WIDGET_SCHEME -configuration $XCODE_CONFIGURATION -destination platform=macOS build"
  fi

  if [[ ! -d "$WIDGET_BUNDLE" ]]; then
    fail_step "定位 Widget 产物" "未找到构建产物：${WIDGET_BUNDLE}。" \
      "检查 xcodebuild 输出目录后重试 ./script/build_and_run.sh --verify"
  fi

  if ! (mkdir -p "$APP_PLUGINS" \
    && rm -rf "$APP_PLUGINS/$WIDGET_NAME.appex" \
    && ditto --norsrc --noextattr "$WIDGET_BUNDLE" "$APP_PLUGINS/$WIDGET_NAME.appex" \
    && /usr/bin/xattr -cr "$APP_PLUGINS/$WIDGET_NAME.appex"); then
    fail_step "嵌入 Widget" "无法将 Widget 嵌入应用包。" \
      "检查 dist 目录权限后重试 ./script/build_and_run.sh --verify"
  fi

  if ! /usr/bin/codesign \
    --force \
    --sign "$CODESIGN_IDENTITY" \
    --timestamp=none \
    --entitlements "$WIDGET_ENTITLEMENTS" \
    "$APP_PLUGINS/$WIDGET_NAME.appex"; then
    fail_step "签名 Widget" "Widget 本地签名失败。" \
      "确认 CODESIGN_IDENTITY 可用（默认使用本地 ad-hoc 签名）后重试 ./script/build_and_run.sh --verify"
  fi
fi

if ! /usr/bin/xattr -cr "$APP_BUNDLE"; then
  fail_step "清理应用属性" "无法清理应用包扩展属性。" \
    "执行 /usr/bin/xattr -cr $APP_BUNDLE 后重试 ./script/build_and_run.sh --verify"
fi

if ! /usr/bin/codesign \
  --force \
  --sign "$CODESIGN_IDENTITY" \
  --timestamp=none \
  --entitlements "$APP_ENTITLEMENTS" \
  "$APP_BUNDLE"; then
  fail_step "签名应用" "主应用本地签名失败。" \
    "确认 CODESIGN_IDENTITY 可用（默认使用本地 ad-hoc 签名）后重试 ./script/build_and_run.sh --verify"
fi

if [[ "$ACCEPTANCE_MODE" -eq 1 ]]; then
  stop_running_app
fi

open_app() {
  local app_path="${1:-$APP_BUNDLE}"
  if ! /usr/bin/open -n "$app_path"; then
    fail_step "启动应用" "open 无法启动 ${app_path}。" \
      "确认应用包存在且签名有效后重试 ./script/build_and_run.sh --verify"
  fi
}

install_app() {
  if [[ "$INSTALL_APP_PATH" == "$APP_BUNDLE" ]]; then
    return
  fi

  if ! mkdir -p "$(dirname "$INSTALL_APP_PATH")"; then
    fail_step "准备安装目录" "无法创建安装目录：$(dirname "$INSTALL_APP_PATH")。" \
      "设置 INSTALL_APP_PATH=\"${HOME}/Applications/${APP_NAME}.app\" 后重试 ./script/build_and_run.sh --verify"
  fi
  if ! rm -rf "$INSTALL_STAGING_PATH"; then
    fail_step "准备覆盖安装" "无法清理临时安装目录：${INSTALL_STAGING_PATH}。" \
      "执行 rm -rf \"${INSTALL_STAGING_PATH}\" 后重试 ./script/build_and_run.sh --verify"
  fi
  if ! ditto --norsrc --noextattr "$APP_BUNDLE" "$INSTALL_STAGING_PATH"; then
    fail_step "覆盖安装" "无法写入安装路径：${INSTALL_APP_PATH}。" \
      "确认目标目录可写，或设置 INSTALL_APP_PATH=\"${HOME}/Applications/${APP_NAME}.app\" 后重试 ./script/build_and_run.sh --verify"
  fi
  if [[ -e "$INSTALL_APP_PATH" ]] && ! rm -rf "$INSTALL_APP_PATH"; then
    fail_step "覆盖安装" "无法移除旧安装：${INSTALL_APP_PATH}。" \
      "执行 sudo rm -rf \"$INSTALL_APP_PATH\" 后重试 ./script/build_and_run.sh --verify"
  fi
  if ! mv "$INSTALL_STAGING_PATH" "$INSTALL_APP_PATH"; then
    fail_step "覆盖安装" "无法将新应用移入：${INSTALL_APP_PATH}。" \
      "确认目标目录可写，或设置 INSTALL_APP_PATH=\"${HOME}/Applications/${APP_NAME}.app\" 后重试 ./script/build_and_run.sh --verify"
  fi
}

verify_installed_app() {
  local installed_binary="$INSTALL_APP_PATH/Contents/MacOS/$APP_NAME"
  local installed_info="$INSTALL_APP_PATH/Contents/Info.plist"
  local installed_widget="$INSTALL_APP_PATH/Contents/PlugIns/$WIDGET_NAME.appex"
  local installed_widget_info="$installed_widget/Contents/Info.plist"
  local installed_identifier installed_version installed_build widget_version widget_build widget_parent

  [[ -d "$INSTALL_APP_PATH" ]] || fail_step "校验安装路径" "安装包不存在：${INSTALL_APP_PATH}。" \
    "重新执行 ./script/build_and_run.sh --verify"
  [[ -x "$installed_binary" ]] || fail_step "校验安装路径" "安装包缺少可执行文件：${installed_binary}。" \
    "重新执行 ./script/build_and_run.sh --verify"
  [[ -f "$installed_info" ]] || fail_step "校验安装版本" "安装包缺少 Info.plist：${installed_info}。" \
    "重新执行 ./script/build_and_run.sh --verify"

  if ! installed_identifier="$(read_plist_value CFBundleIdentifier "$installed_info")" \
    || ! installed_version="$(read_plist_value CFBundleShortVersionString "$installed_info")" \
    || ! installed_build="$(read_plist_value CFBundleVersion "$installed_info")"; then
    fail_step "校验安装版本" "无法读取安装包版本信息。" \
      "执行 /usr/bin/plutil -p $installed_info 检查安装包后重试"
  fi
  [[ "$installed_identifier" == "$BUNDLE_ID" ]] || fail_step "校验安装版本" "Bundle ID 不匹配：${installed_identifier}。" \
    "确认 INSTALL_APP_PATH 指向本项目构建的应用后重试 ./script/build_and_run.sh --verify"
  [[ "$installed_version" == "$APP_MARKETING_VERSION" && "$installed_build" == "$APP_BUILD_VERSION" ]] || fail_step "校验安装版本" \
    "安装版本为 ${installed_version} (${installed_build})，预期为 ${APP_MARKETING_VERSION} (${APP_BUILD_VERSION})。" \
    "使用 APP_MARKETING_VERSION=$APP_MARKETING_VERSION APP_BUILD_VERSION=$APP_BUILD_VERSION 重试 ./script/build_and_run.sh --verify"

  open_app "$INSTALL_APP_PATH"
  local running_pid="" running_pids=""
  for _ in {1..25}; do
    if read_instance_owner_record; then
      running_pids="$(running_app_pids)"
      if [[ "$running_pids" == "$INSTANCE_OWNER_PID" ]]; then
        running_pid="$INSTANCE_OWNER_PID"
        break
      fi
    fi
    sleep 0.2
  done
  [[ -n "$running_pid" ]] || fail_step "校验运行实例" "启动后未找到 $APP_NAME 进程。" \
    "执行 ./script/build_and_run.sh --logs 查看启动日志后重试"

  local running_command
  running_command="$(ps -p "$running_pid" -o command= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ "$running_command" == "$installed_binary" || "$running_command" == "$installed_binary "* ]] || fail_step "校验运行路径" \
    "运行进程路径为 ${running_command}，预期为 ${installed_binary}。" \
    "执行 pkill -TERM -x $APP_NAME 后重试 ./script/build_and_run.sh --verify"

  if [[ -d "$installed_widget" ]]; then
    [[ -f "$installed_widget_info" ]] || fail_step "校验 Widget 版本" "Widget 缺少 Info.plist：${installed_widget_info}。" \
      "重新执行 ./script/build_and_run.sh --verify"
    if ! widget_version="$(read_plist_value CFBundleShortVersionString "$installed_widget_info")" \
      || ! widget_build="$(read_plist_value CFBundleVersion "$installed_widget_info")" \
      || ! widget_parent="$(read_plist_value NSExtension.NSExtensionAttributes.WKAppBundleIdentifier "$installed_widget_info")"; then
      fail_step "校验 Widget 版本" "无法读取安装 Widget 版本或宿主绑定。" \
        "执行 /usr/bin/plutil -p $installed_widget_info 检查 Widget 包后重试"
    fi
    [[ "$widget_version" == "$installed_version" && "$widget_build" == "$installed_build" ]] || fail_step "校验 Widget 版本" \
      "Widget 版本为 $widget_version ($widget_build)，与应用 $installed_version ($installed_build) 不一致。" \
      "重新执行 ./script/build_and_run.sh --verify"
    [[ "$widget_parent" == "$BUNDLE_ID" ]] || fail_step "校验 Widget 宿主绑定" "Widget 宿主 Bundle ID 为 ${widget_parent}。" \
      "确认 Widget Info.plist 的 WKAppBundleIdentifier 后重试"
    if ! /usr/bin/pluginkit -a "$installed_widget" >/dev/null 2>&1; then
      fail_step "注册 Widget" "pluginkit 无法注册安装包中的 Widget。" \
        "执行 /usr/bin/pluginkit -a $installed_widget 后重试 ./script/build_and_run.sh --verify"
    fi
    local registered_paths
    registered_paths="$(/usr/bin/pluginkit -mAvvv -i "$WIDGET_BUNDLE_ID" 2>/dev/null | sed -n 's/^[[:space:]]*Path = //p')"
    if [[ -z "$registered_paths" ]] || ! while IFS= read -r registered_path; do
      [[ "$registered_path" == "$installed_widget" ]] || exit 1
    done <<< "$registered_paths"; then
      fail_step "校验 Widget 绑定" "pluginkit 未指向当前安装路径：${installed_widget}。" \
        "执行 /usr/bin/pluginkit -a ${installed_widget}，再运行 ./script/build_and_run.sh --verify"
    fi
  fi

  verify_cross_copy_instance_arbitration "$running_pid"

  echo "安装验收通过："
  echo "  安装路径：$INSTALL_APP_PATH"
  echo "  运行路径：$running_command"
  echo "  运行版本：$installed_version ($installed_build)"
  if [[ -d "$installed_widget" ]]; then
    echo "  Widget 路径：$installed_widget"
    echo "  Widget 版本：$widget_version ($widget_build)"
  else
    echo "  Widget：未嵌入（项目未提供 Widget 工程）"
  fi
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    install_app
    verify_installed_app
    ;;
esac
