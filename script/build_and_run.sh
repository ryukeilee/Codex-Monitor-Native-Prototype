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

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
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
INSTALL_APP_PATH_RAW="${INSTALL_APP_PATH:-/Applications/$APP_NAME.app}"
INSTALL_APP_PATH=""
INSTALL_WORK_DIR=""
INSTALL_STAGING_PATH=""
INSTALL_BACKUP_PATH=""
INSTALL_REPLACEMENT_ACTIVE=0
INSTALL_HAD_PREVIOUS_APP=0
INSTALL_OLD_APP_MOVED=0
INSTALL_COMMITTED=0
PREVIOUS_INSTALL_WAS_RUNNING=0
INSTANCE_OWNER_PATH="${HOME}/Library/Application Support/CodexMonitorNative/InstanceArbitration/v1/owner.json"
APP_GROUP_ID="group.com.ryukeilee.CodexMonitorNativePrototype"

usage() {
  echo "用法：$0 [run|--verify|--debug|--logs|--telemetry]"
  echo "  --verify  构建、关闭旧实例、覆盖安装，并验收运行版本、路径和 Widget 绑定"
  echo "  INSTALL_APP_PATH=...        覆盖默认安装路径（默认：${INSTALL_APP_PATH_RAW}）"
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
REDIRECT_VERIFICATION_TOKEN=""
REDIRECT_OWNER_PID=""
REDIRECT_OWNER_INSTANCE_ID=""
VERIFY_LOG_ERROR_PATH=""

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
  local running_pids query_status

  if running_pids="$(pgrep -x "$APP_NAME" 2>&1)"; then
    :
  else
    query_status=$?
    [[ "$query_status" -eq 1 ]] && return 0
    fail_step "查询旧实例" "pgrep 无法查询 ${APP_NAME} 进程：${running_pids}。" \
      "确认当前用户可读取进程列表后重试"
  fi

  pkill -TERM -x "$APP_NAME" >/dev/null 2>&1 || true
  for _ in {1..25}; do
    if running_pids="$(pgrep -x "$APP_NAME" 2>&1)"; then
      sleep 0.2
      continue
    else
      query_status=$?
    fi
    [[ "$query_status" -eq 1 ]] && return 0
    fail_step "查询旧实例" "SIGTERM 后 pgrep 无法查询 ${APP_NAME} 进程：${running_pids}。" \
      "确认当前用户可读取进程列表后重试"
  done

  pkill -KILL -x "$APP_NAME" >/dev/null 2>&1 || true
  for _ in {1..10}; do
    if running_pids="$(pgrep -x "$APP_NAME" 2>&1)"; then
      sleep 0.2
      continue
    else
      query_status=$?
    fi
    [[ "$query_status" -eq 1 ]] && return 0
    fail_step "查询旧实例" "SIGKILL 后 pgrep 无法查询 ${APP_NAME} 进程：${running_pids}。" \
      "确认当前用户可读取进程列表后重试"
  done

  fail_step "关闭旧实例" "进程 $APP_NAME 仍在运行，无法安全覆盖安装。" \
    "pkill -TERM -x ${APP_NAME}；确认进程退出后重试 ./script/build_and_run.sh --verify"
}

read_plist_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$2"
}

canonicalize_directory_path() {
  local requested_path="$1"
  local cursor="$requested_path"
  local component physical_path missing_suffix=""

  while [[ ! -e "$cursor" && ! -L "$cursor" ]]; do
    component="${cursor##*/}"
    [[ -n "$component" && "$component" != "." && "$component" != ".." ]] || return 1
    missing_suffix="/$component$missing_suffix"
    cursor="${cursor%/*}"
    [[ -n "$cursor" ]] || cursor="/"
  done

  [[ -d "$cursor" ]] || return 1
  physical_path="$(cd -P -- "$cursor" 2>/dev/null && pwd -P)" || return 1
  physical_path="${physical_path%/}${missing_suffix}"
  [[ -n "$physical_path" ]] || physical_path="/"
  printf '%s\n' "$physical_path"
}

validate_existing_install_target() {
  local target="$1"
  local info_plist="$target/Contents/Info.plist"
  local existing_identifier

  if [[ -L "$target" ]]; then
    fail_step "校验安装路径" "安装目标不能是符号链接或 Finder 别名：${target}。" \
      "移除该别名，并将 INSTALL_APP_PATH 指向真实的 ${APP_NAME}.app 路径"
  fi
  [[ -e "$target" ]] || return 0
  [[ -d "$target" ]] || fail_step "校验安装路径" \
    "安装目标已存在，但不是 .app 目录：${target}。" \
    "将 INSTALL_APP_PATH 指向不存在的 ${APP_NAME}.app，或现有的本项目安装包"
  [[ -f "$info_plist" ]] || fail_step "校验安装路径" \
    "安装目标不是可识别的 App bundle（缺少 Info.plist）：${target}。" \
    "不要把普通目录作为 INSTALL_APP_PATH"
  existing_identifier="$(read_plist_value CFBundleIdentifier "$info_plist" 2>/dev/null)" || fail_step \
    "校验安装路径" "无法读取现有安装的 Bundle ID：${target}。" \
    "确认目标是本项目的 ${APP_NAME}.app"
  [[ "$existing_identifier" == "$BUNDLE_ID" ]] || fail_step "校验安装路径" \
    "拒绝覆盖其他 App：${target} 的 Bundle ID 为 ${existing_identifier}。" \
    "将 INSTALL_APP_PATH 指向 Bundle ID 为 ${BUNDLE_ID} 的安装包"
}

validate_install_path() {
  local requested="$INSTALL_APP_PATH_RAW"
  local requested_parent canonical_parent canonical_target canonical_home

  [[ "$requested" == /* ]] || fail_step "校验安装路径" \
    "INSTALL_APP_PATH 必须是绝对路径：${requested}。" \
    "使用 /Applications/${APP_NAME}.app 或 \"${HOME}/Applications/${APP_NAME}.app\""
  case "$requested" in
    *//*|*/./*|*/../*|*/.|*/..)
      fail_step "校验安装路径" "INSTALL_APP_PATH 含有未规范化的路径分量：${requested}。" \
        "改用不含 //、/./ 或 /../ 的绝对路径"
      ;;
  esac
  [[ "${requested##*/}" == "${APP_NAME}.app" ]] || fail_step "校验安装路径" \
    "INSTALL_APP_PATH 的最终名称必须精确为 ${APP_NAME}.app：${requested}。" \
    "将目标改为某个安全目录下的 ${APP_NAME}.app"

  requested_parent="${requested%/*}"
  [[ -n "$requested_parent" ]] || requested_parent="/"
  canonical_parent="$(canonicalize_directory_path "$requested_parent")" || fail_step \
    "校验安装路径" "安装父路径包含无效别名、非目录分量或无法解析：${requested_parent}。" \
    "将 INSTALL_APP_PATH 指向真实、可解析的目录"
  canonical_target="${canonical_parent%/}/${APP_NAME}.app"
  canonical_home="$(cd -P -- "$HOME" 2>/dev/null && pwd -P)" || fail_step \
    "校验安装路径" "无法解析用户主目录。" "确认 HOME 指向可访问的真实目录"

  case "$canonical_parent" in
    /|"$canonical_home"|"$ROOT_DIR")
      fail_step "校验安装路径" "拒绝直接在受保护目录中安装：${canonical_parent}。" \
        "使用 /Applications/${APP_NAME}.app 或 \"${HOME}/Applications/${APP_NAME}.app\""
      ;;
  esac
  case "$canonical_target" in
    /|"$canonical_home"|"$ROOT_DIR")
      fail_step "校验安装路径" "拒绝把受保护目录作为安装目标：${canonical_target}。" \
        "使用 /Applications/${APP_NAME}.app 或 \"${HOME}/Applications/${APP_NAME}.app\""
      ;;
  esac
  if [[ "$ACCEPTANCE_MODE" -eq 1 && "$canonical_target" == "$APP_BUNDLE" ]]; then
    fail_step "校验安装路径" "安装路径不能与 dist 挑战副本相同：${canonical_target}。" \
      "为 --verify 使用独立的 ${APP_NAME}.app 安装路径"
  fi
  INSTALL_APP_PATH="$canonical_target"
  validate_existing_install_target "$INSTALL_APP_PATH"
}

verify_expected_entitlements() {
  local bundle="$1"
  local expected_entitlements="$2"
  local label="$3"
  local dump_path expected_group actual_group expected_sandbox actual_sandbox

  dump_path="$(mktemp "$INSTALL_WORK_DIR/entitlements.XXXXXX")" || fail_step \
    "校验 ${label} entitlements" "无法创建受控的 entitlement 临时文件。" \
    "确认安装目标父目录可写后重试"
  if ! /usr/bin/codesign -d --entitlements :- "$bundle" >"$dump_path" 2>/dev/null; then
    fail_step "校验 ${label} entitlements" "无法读取 ${bundle} 的已签名 entitlements。" \
      "/usr/bin/codesign -dvvv --entitlements :- \"$bundle\""
  fi

  expected_group="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$expected_entitlements" 2>/dev/null)" || fail_step \
    "校验 ${label} entitlements" "期望 entitlement 文件缺少 App Group。" \
    "/usr/bin/plutil -p \"$expected_entitlements\""
  actual_group="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$dump_path" 2>/dev/null)" || fail_step \
    "校验 ${label} entitlements" "已签名产物缺少 App Group entitlement。" \
    "/usr/bin/codesign -dvvv --entitlements :- \"$bundle\""
  [[ "$expected_group" == "$APP_GROUP_ID" && "$actual_group" == "$expected_group" ]] || fail_step \
    "校验 ${label} entitlements" \
    "App Group 不匹配：实际 ${actual_group}，预期 ${APP_GROUP_ID}。" \
    "确认签名使用 \"$expected_entitlements\""
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:1' "$dump_path" >/dev/null 2>&1; then
    fail_step "校验 ${label} entitlements" "已签名产物包含未预期的额外 App Group。" \
      "/usr/bin/codesign -dvvv --entitlements :- \"$bundle\""
  fi

  if expected_sandbox="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$expected_entitlements" 2>/dev/null)"; then
    actual_sandbox="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$dump_path" 2>/dev/null)" || fail_step \
      "校验 ${label} entitlements" "已签名产物缺少 App Sandbox entitlement。" \
      "/usr/bin/codesign -dvvv --entitlements :- \"$bundle\""
    [[ "$actual_sandbox" == "$expected_sandbox" ]] || fail_step \
      "校验 ${label} entitlements" "App Sandbox entitlement 与期望不一致。" \
      "确认签名使用 \"$expected_entitlements\""
  fi
  rm -f "$dump_path"
}

verify_bundle_signature_and_entitlements() {
  local bundle="$1"
  local expected_entitlements="$2"
  local label="$3"
  shift 3
  local -a verification_arguments=(--verify --strict --verbose=2)
  if [[ "${1:-}" == "--deep" ]]; then
    verification_arguments+=(--deep)
  fi
  if ! /usr/bin/codesign "${verification_arguments[@]}" "$bundle"; then
    fail_step "校验 ${label} 签名" "${bundle} 的代码签名无效。" \
      "/usr/bin/codesign --verify --strict --verbose=4 \"$bundle\""
  fi
  verify_expected_entitlements "$bundle" "$expected_entitlements" "$label"
}

verify_install_candidate() {
  local candidate="$1"
  local info="$candidate/Contents/Info.plist"
  local widget="$candidate/Contents/PlugIns/$WIDGET_NAME.appex"
  local widget_info="$widget/Contents/Info.plist"
  local identifier version build widget_identifier widget_version widget_build widget_parent

  [[ -d "$candidate" && -f "$info" && -x "$candidate/Contents/MacOS/$APP_NAME" ]] || fail_step \
    "校验安装候选" "staging 不是完整的 ${APP_NAME}.app。" \
    "重新执行 ./script/build_and_run.sh --verify"
  identifier="$(read_plist_value CFBundleIdentifier "$info" 2>/dev/null)" || fail_step \
    "校验安装候选" "无法读取 staging Bundle ID。" "/usr/bin/plutil -p \"$info\""
  version="$(read_plist_value CFBundleShortVersionString "$info" 2>/dev/null)" || fail_step \
    "校验安装候选" "无法读取 staging 版本。" "/usr/bin/plutil -p \"$info\""
  build="$(read_plist_value CFBundleVersion "$info" 2>/dev/null)" || fail_step \
    "校验安装候选" "无法读取 staging build。" "/usr/bin/plutil -p \"$info\""
  [[ "$identifier" == "$BUNDLE_ID" && "$version" == "$APP_MARKETING_VERSION" && "$build" == "$APP_BUILD_VERSION" ]] || fail_step \
    "校验安装候选" "staging 的 Bundle ID 或版本与本次构建不一致。" \
    "/usr/bin/plutil -p \"$info\""

  if [[ -d "$WIDGET_PROJECT" ]]; then
    [[ -d "$widget" && -f "$widget_info" ]] || fail_step "校验安装候选" \
      "staging 缺少本项目要求的 Widget extension。" \
      "检查 Widget 构建与嵌入步骤后重试"
    widget_identifier="$(read_plist_value CFBundleIdentifier "$widget_info" 2>/dev/null)" || fail_step \
      "校验安装候选" "无法读取 Widget Bundle ID。" "/usr/bin/plutil -p \"$widget_info\""
    widget_version="$(read_plist_value CFBundleShortVersionString "$widget_info" 2>/dev/null)" || fail_step \
      "校验安装候选" "无法读取 Widget 版本。" "/usr/bin/plutil -p \"$widget_info\""
    widget_build="$(read_plist_value CFBundleVersion "$widget_info" 2>/dev/null)" || fail_step \
      "校验安装候选" "无法读取 Widget build。" "/usr/bin/plutil -p \"$widget_info\""
    widget_parent="$(read_plist_value NSExtension.NSExtensionAttributes.WKAppBundleIdentifier "$widget_info" 2>/dev/null)" || fail_step \
      "校验安装候选" "无法读取 Widget 宿主绑定。" "/usr/bin/plutil -p \"$widget_info\""
    [[ "$widget_identifier" == "$WIDGET_BUNDLE_ID" \
      && "$widget_version" == "$version" \
      && "$widget_build" == "$build" \
      && "$widget_parent" == "$BUNDLE_ID" ]] || fail_step \
      "校验安装候选" "Widget Bundle ID、版本或宿主绑定与主应用不一致。" \
      "/usr/bin/plutil -p \"$widget_info\""
    verify_bundle_signature_and_entitlements "$widget" "$WIDGET_ENTITLEMENTS" "Widget"
  fi
  verify_bundle_signature_and_entitlements "$candidate" "$APP_ENTITLEMENTS" "主应用与嵌套代码" --deep
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
  local output query_status
  if output="$(pgrep -x "$APP_NAME" 2>&1)"; then
    printf '%s\n' "$output"
    return 0
  else
    query_status=$?
  fi
  [[ "$query_status" -eq 1 ]] && return 0
  echo "pgrep 无法查询 ${APP_NAME} 进程：${output}" >&2
  return "$query_status"
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

verify_preferred_owner_takeover() {
  local installed_binary="$INSTALL_APP_PATH/Contents/MacOS/$APP_NAME"
  local development_binary="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
  local old_owner_pid="" old_owner_id="" new_owner_pid="" running_pids="" running_command=""

  stop_running_app
  open_app "$APP_BUNDLE"

  for _ in {1..30}; do
    if read_instance_owner_record; then
      if ! running_command="$(ps -p "$INSTANCE_OWNER_PID" -o command= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"; then
        sleep 0.2
        continue
      fi
      if [[ "$running_command" == "$development_binary" || "$running_command" == "$development_binary "* ]]; then
        old_owner_pid="$INSTANCE_OWNER_PID"
        old_owner_id="$INSTANCE_OWNER_ID"
        break
      fi
    fi
    sleep 0.2
  done
  [[ -n "$old_owner_pid" ]] || fail_step "校验首选 owner 接管" \
    "未能先建立 dist 开发 owner，无法复现旧副本已持锁场景。" \
    "执行 pkill -TERM -x $APP_NAME 后重试 ./script/build_and_run.sh --verify"

  open_app "$INSTALL_APP_PATH"
  for _ in {1..40}; do
    if read_instance_owner_record; then
      running_pids="$(running_app_pids)"
      if ! running_command="$(ps -p "$INSTANCE_OWNER_PID" -o command= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"; then
        sleep 0.2
        continue
      fi
      if [[ "$INSTANCE_OWNER_ID" != "$old_owner_id" \
        && "$running_pids" == "$INSTANCE_OWNER_PID" \
        && ("$running_command" == "$installed_binary" || "$running_command" == "$installed_binary "*) ]]; then
        new_owner_pid="$INSTANCE_OWNER_PID"
        break
      fi
    fi
    sleep 0.2
  done

  [[ -n "$new_owner_pid" ]] || fail_step "校验首选 owner 接管" \
    "首选安装未从已运行的 dist owner 取得唯一所有权。" \
    "检查 ownership handoff ticket/ACK 与 AppDelegate 让位日志后重试"
  if kill -0 "$old_owner_pid" >/dev/null 2>&1; then
    fail_step "校验首选 owner 接管" \
      "首选 owner 已出现，但旧 dist owner PID $old_owner_pid 仍在运行。" \
      "检查 committed relinquishment 是否在释放 owner.lock 前停止并终止旧实例"
  fi

  echo "  首选 owner 接管：dist PID $old_owner_pid 已让位，安装版 PID $new_owner_pid 取得所有权"
}

verify_stale_copy_redirect() {
  local installed_binary="$INSTALL_APP_PATH/Contents/MacOS/$APP_NAME"
  local redirected_pid="" running_pids="" running_command=""
  local previous_instance_id="" redirect_started_at redirect_events=""
  local log_query_succeeded=0 log_error_summary=""

  if read_instance_owner_record; then
    previous_instance_id="$INSTANCE_OWNER_ID"
  fi

  stop_running_app
  REDIRECT_VERIFICATION_TOKEN="$(/usr/bin/uuidgen)"
  redirect_started_at="$(date '+%Y-%m-%d %H:%M:%S')"
  open_app_without_development_override "$APP_BUNDLE" "$REDIRECT_VERIFICATION_TOKEN"

  for _ in {1..40}; do
    if read_instance_owner_record; then
      running_pids="$(running_app_pids)"
      if [[ "$running_pids" == "$INSTANCE_OWNER_PID" ]] \
        && kill -0 "$INSTANCE_OWNER_PID" >/dev/null 2>&1; then
        running_command="$(ps -p "$INSTANCE_OWNER_PID" -o command= | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        if [[ "$running_command" == "$installed_binary" || "$running_command" == "$installed_binary "* ]]; then
          redirected_pid="$INSTANCE_OWNER_PID"
          REDIRECT_OWNER_PID="$INSTANCE_OWNER_PID"
          REDIRECT_OWNER_INSTANCE_ID="$INSTANCE_OWNER_ID"
          break
        fi
      fi
    fi
    sleep 0.2
  done

  [[ -n "$redirected_pid" ]] || fail_step "校验旧副本让位" \
    "先启动 dist 旧副本后，未确认首选安装路径成为唯一 owner。" \
    "检查 AppInstallationAuthority 重定向日志后重试 ./script/build_and_run.sh --verify"
  [[ "$(running_app_pids)" == "$redirected_pid" ]] || fail_step "校验旧副本让位" \
    "旧副本重定向后仍存在多个运行实例。" \
    "执行 pkill -TERM -x $APP_NAME 后重试 ./script/build_and_run.sh --verify"
  [[ -z "$previous_instance_id" || "$INSTANCE_OWNER_ID" != "$previous_instance_id" ]] || fail_step "校验旧副本让位" \
    "旧副本挑战后 owner instanceID 未更新，无法证明安装版重新取得所有权。" \
    "检查 InstanceArbitration/v1/owner.json 后重试 ./script/build_and_run.sh --verify"

  VERIFY_LOG_ERROR_PATH="$(mktemp "${TMPDIR:-/tmp}/codex-monitor-redirect-log.XXXXXX")" || fail_step \
    "校验旧副本让位" "无法创建统一日志诊断文件。" "确认 TMPDIR 可写后重试"
  for _ in {1..20}; do
    if redirect_events="$(/usr/bin/log show \
      --info \
      --start "$redirect_started_at" \
      --style compact \
      --predicate "process == \"$APP_NAME\" AND eventMessage CONTAINS[c] \"Verified redirect to the recorded preferred app installation token=$REDIRECT_VERIFICATION_TOKEN\"" \
      2>"$VERIFY_LOG_ERROR_PATH")"; then
      log_query_succeeded=1
      [[ -n "$redirect_events" ]] && break
    fi
    sleep 0.25
  done
  if [[ "$log_query_succeeded" -ne 1 ]]; then
    log_error_summary="$(tail -n 4 "$VERIFY_LOG_ERROR_PATH" 2>/dev/null || true)"
  fi
  [[ -n "$redirect_events" ]] || fail_step "校验旧副本让位" \
    "最终 owner 路径正确，但未捕获 token=${REDIRECT_VERIFICATION_TOKEN} 的因果日志。${log_error_summary:+ log show: $log_error_summary}" \
    "执行 ./script/build_and_run.sh --logs 检查 AppInstallationAuthority 重定向后重试"

  echo "  旧副本让位：dist 启动请求已重定向到安装 owner PID $redirected_pid"
}

record_previous_install_state() {
  local installed_binary="$INSTALL_APP_PATH/Contents/MacOS/$APP_NAME"
  local pid command running_pids

  PREVIOUS_INSTALL_WAS_RUNNING=0
  running_pids="$(running_app_pids)" || fail_step "查询原安装进程" \
    "无法判断原安装是否正在运行。" "确认当前用户可读取进程列表后重试"
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if ! command="$(ps -p "$pid" -o command= 2>/dev/null)"; then
      if kill -0 "$pid" >/dev/null 2>&1; then
        fail_step "查询原安装进程" \
          "PID ${pid} 仍存活，但 ps 无法确认其命令身份。" \
          "确认当前用户可读取该进程信息后重试"
      fi
      continue
    fi
    command="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<< "$command")"
    if [[ -z "$command" ]]; then
      if kill -0 "$pid" >/dev/null 2>&1; then
        fail_step "查询原安装进程" \
          "PID ${pid} 仍存活，但 ps 返回空命令身份。" \
          "确认当前用户可读取该进程信息后重试"
      fi
      continue
    fi
    if [[ "$command" == "$installed_binary" || "$command" == "$installed_binary "* ]]; then
      PREVIOUS_INSTALL_WAS_RUNNING=1
      return
    fi
  done <<< "$running_pids"
}

stop_acceptance_processes_before_rollback() {
  local running_pids pid command
  local -a process_pids=()

  running_pids="$(running_app_pids)" || {
    echo "回滚前进程门禁失败：pgrep 无法枚举 ${APP_NAME} 进程。" >&2
    return 1
  }
  [[ -n "$running_pids" ]] || return 0

  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || {
      echo "回滚前进程门禁失败：pgrep 返回无效 PID：${pid}。" >&2
      return 1
    }
    if ! command="$(ps -p "$pid" -o command= 2>/dev/null)"; then
      if kill -0 "$pid" >/dev/null 2>&1; then
        echo "回滚前进程门禁失败：PID ${pid} 仍存活，但 ps 无法确认其命令身份。" >&2
        return 1
      fi
      continue
    fi
    command="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<< "$command")"
    if [[ -z "$command" ]]; then
      if kill -0 "$pid" >/dev/null 2>&1; then
        echo "回滚前进程门禁失败：PID ${pid} 仍存活，但 ps 返回空命令身份。" >&2
        return 1
      fi
      continue
    fi
    process_pids+=("$pid")
  done <<< "$running_pids"

  if [[ "${#process_pids[@]}" -gt 0 ]]; then
    for pid in "${process_pids[@]}"; do
      kill -TERM "$pid" >/dev/null 2>&1 || true
    done
  fi
  for _ in {1..10}; do
    running_pids="$(running_app_pids)" || {
      echo "回滚前进程门禁失败：SIGTERM 后 pgrep 无法枚举 ${APP_NAME} 进程。" >&2
      return 1
    }
    [[ -z "$running_pids" ]] && return 0
    sleep 0.2
  done

  process_pids=()
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || {
      echo "回滚前进程门禁失败：SIGTERM 后 pgrep 返回无效 PID：${pid}。" >&2
      return 1
    }
    if ! command="$(ps -p "$pid" -o command= 2>/dev/null)"; then
      if kill -0 "$pid" >/dev/null 2>&1; then
        echo "回滚前进程门禁失败：PID ${pid} 仍存活，但 SIGKILL 前无法确认其命令身份。" >&2
        return 1
      fi
      continue
    fi
    command="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<< "$command")"
    if [[ -z "$command" ]]; then
      if kill -0 "$pid" >/dev/null 2>&1; then
        echo "回滚前进程门禁失败：PID ${pid} 仍存活，但 SIGKILL 前 ps 返回空命令身份。" >&2
        return 1
      fi
      continue
    fi
    process_pids+=("$pid")
  done <<< "$running_pids"
  if [[ "${#process_pids[@]}" -gt 0 ]]; then
    for pid in "${process_pids[@]}"; do
      kill -KILL "$pid" >/dev/null 2>&1 || true
    done
  fi
  for _ in {1..10}; do
    running_pids="$(running_app_pids)" || {
      echo "回滚前进程门禁失败：SIGKILL 后 pgrep 无法枚举 ${APP_NAME} 进程。" >&2
      return 1
    }
    [[ -z "$running_pids" ]] && return 0
    sleep 0.2
  done

  echo "回滚前进程门禁失败：TERM/KILL 后仍有 ${APP_NAME} PID：${running_pids//$'\n'/, }。" >&2
  return 1
}

rollback_install() {
  local restored_previous=0
  local restored_widget="$INSTALL_APP_PATH/Contents/PlugIns/$WIDGET_NAME.appex"

  [[ "$INSTALL_REPLACEMENT_ACTIVE" -eq 1 && "$INSTALL_COMMITTED" -eq 0 ]] || return 0
  if [[ -d "$restored_widget" ]]; then
    /usr/bin/pluginkit -r "$restored_widget" >/dev/null 2>&1 || true
  fi
  if [[ "$INSTALL_HAD_PREVIOUS_APP" -eq 1 ]]; then
    if [[ ! -d "$INSTALL_BACKUP_PATH" ]]; then
      if [[ "$INSTALL_OLD_APP_MOVED" -eq 0 && -d "$INSTALL_APP_PATH" ]]; then
        INSTALL_REPLACEMENT_ACTIVE=0
        return 0
      fi
      echo "回滚失败：找不到原安装 backup；保留受控目录 ${INSTALL_WORK_DIR} 供人工检查。" >&2
      echo "预期 backup 路径：${INSTALL_BACKUP_PATH}" >&2
      return 1
    fi
    if [[ -e "$INSTALL_APP_PATH" || -L "$INSTALL_APP_PATH" ]]; then
      if ! rm -rf "$INSTALL_APP_PATH"; then
        echo "回滚失败：无法移除失败的新安装 ${INSTALL_APP_PATH}。" >&2
        echo "原安装 backup 已保留：${INSTALL_BACKUP_PATH}" >&2
        echo "人工恢复步骤 1：移除或移走 ${INSTALL_APP_PATH}" >&2
        echo "人工恢复步骤 2：mv \"${INSTALL_BACKUP_PATH}\" \"${INSTALL_APP_PATH}\"" >&2
        return 1
      fi
    fi
    if mv "$INSTALL_BACKUP_PATH" "$INSTALL_APP_PATH"; then
      restored_previous=1
      INSTALL_OLD_APP_MOVED=0
      echo "安装回滚：已恢复原安装 ${INSTALL_APP_PATH}。" >&2
    else
      echo "回滚失败：无法从 backup 恢复原安装。" >&2
      echo "原安装 backup 已保留：${INSTALL_BACKUP_PATH}" >&2
      echo "人工恢复命令：mv \"${INSTALL_BACKUP_PATH}\" \"${INSTALL_APP_PATH}\"" >&2
      return 1
    fi
  else
    if [[ -e "$INSTALL_APP_PATH" || -L "$INSTALL_APP_PATH" ]]; then
      if ! rm -rf "$INSTALL_APP_PATH"; then
        echo "回滚失败：无法移除失败的新安装 ${INSTALL_APP_PATH}；受控目录保留在 ${INSTALL_WORK_DIR}。" >&2
        return 1
      fi
    fi
  fi
  INSTALL_REPLACEMENT_ACTIVE=0

  if [[ "$restored_previous" -eq 1 && -d "$restored_widget" ]]; then
    /usr/bin/pluginkit -a "$restored_widget" >/dev/null 2>&1 \
      || echo "回滚警告：原安装已恢复，但 Widget 未能自动重新注册。" >&2
  fi
  if [[ "$restored_previous" -eq 1 && "$PREVIOUS_INSTALL_WAS_RUNNING" -eq 1 ]]; then
    if /usr/bin/open -n "$INSTALL_APP_PATH"; then
      echo "安装回滚：已请求重新启动原安装。" >&2
    else
      echo "回滚警告：原安装已恢复，但无法自动重新启动。" >&2
    fi
  fi
  return 0
}

commit_install() {
  INSTALL_COMMITTED=1
  INSTALL_REPLACEMENT_ACTIVE=0
  if [[ -n "$INSTALL_WORK_DIR" && -d "$INSTALL_WORK_DIR" ]]; then
    if ! rm -rf "$INSTALL_WORK_DIR"; then
      echo "清理警告：安装已验收，但无法删除受控 backup 目录 ${INSTALL_WORK_DIR}。" >&2
      return
    fi
  fi
  INSTALL_WORK_DIR=""
  INSTALL_STAGING_PATH=""
  INSTALL_BACKUP_PATH=""
}

cleanup_after_exit() {
  local task_exit=$?
  local rollback_completed=1
  local processes_stopped=1
  trap - EXIT
  if [[ "$ACCEPTANCE_MODE" -eq 1 \
    && "$task_exit" -ne 0 \
    && "$INSTALL_REPLACEMENT_ACTIVE" -eq 1 ]]; then
    if ! stop_acceptance_processes_before_rollback; then
      processes_stopped=0
    fi
  fi
  if [[ "$task_exit" -ne 0 ]]; then
    if [[ "$processes_stopped" -eq 0 ]]; then
      rollback_completed=0
      echo "禁止回滚：无法证明所有 ${APP_NAME} 验收进程已退出。" >&2
      echo "当前安装保留：${INSTALL_APP_PATH:-未建立}" >&2
      echo "原安装 backup：${INSTALL_BACKUP_PATH:-未建立}" >&2
      echo "受控工作目录：${INSTALL_WORK_DIR:-未建立}" >&2
    elif ! rollback_install; then
      rollback_completed=0
    fi
  fi
  if [[ -n "$INSTALL_WORK_DIR" && -d "$INSTALL_WORK_DIR" ]]; then
    if [[ "$task_exit" -ne 0 && "$rollback_completed" -eq 0 ]]; then
      echo "回滚未完成：保留受控安装目录 ${INSTALL_WORK_DIR}，不得删除其中的 backup。" >&2
    else
      rm -rf "$INSTALL_WORK_DIR" || true
    fi
  fi
  if [[ -n "$VERIFY_LOG_ERROR_PATH" && -e "$VERIFY_LOG_ERROR_PATH" ]]; then
    rm -f "$VERIFY_LOG_ERROR_PATH" || true
  fi
  exit "$task_exit"
}

if [[ "$ACCEPTANCE_MODE" -eq 1 ]]; then
  validate_install_path
fi
trap cleanup_after_exit EXIT

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

open_app() {
  local app_path="${1:-$APP_BUNDLE}"
  local -a open_arguments=(-n "$app_path")
  if [[ "$app_path" == "$APP_BUNDLE" ]]; then
    open_arguments+=(--args --codex-monitor-allow-development-instance)
  fi
  if ! /usr/bin/open "${open_arguments[@]}"; then
    fail_step "启动应用" "open 无法启动 ${app_path}。" \
      "确认应用包存在且签名有效后重试 ./script/build_and_run.sh --verify"
  fi
}

open_app_without_development_override() {
  local app_path="$1"
  local verification_token="${2:-}"
  local -a open_arguments=(-n "$app_path")
  if [[ -n "$verification_token" ]]; then
    open_arguments+=(--args --codex-monitor-redirect-verification-token "$verification_token")
  fi
  if ! /usr/bin/open "${open_arguments[@]}"; then
    fail_step "启动旧副本挑战" "open 无法启动 ${app_path}。" \
      "确认应用包存在且签名有效后重试 ./script/build_and_run.sh --verify"
  fi
}

install_app() {
  local install_parent physical_parent

  install_parent="${INSTALL_APP_PATH%/*}"
  if ! mkdir -p "$install_parent"; then
    fail_step "准备安装目录" "无法创建安装目录：${install_parent}。" \
      "设置 INSTALL_APP_PATH=\"${HOME}/Applications/${APP_NAME}.app\" 后重试 ./script/build_and_run.sh --verify"
  fi
  physical_parent="$(cd -P -- "$install_parent" 2>/dev/null && pwd -P)" || fail_step \
    "准备安装目录" "无法解析安装父目录：${install_parent}。" \
    "确认父目录不是损坏的符号链接或 Finder 别名"
  [[ "$physical_parent" == "$install_parent" ]] || fail_step "准备安装目录" \
    "安装父目录在构建期间被替换为别名或符号链接：${install_parent} -> ${physical_parent}。" \
    "改用稳定的真实目录后重试"

  INSTALL_WORK_DIR="$(mktemp -d "$install_parent/.${APP_NAME}.install.XXXXXX")" || fail_step \
    "准备覆盖安装" "无法在安装父目录创建唯一 staging。" \
    "确认 ${install_parent} 可写，或改用用户 Applications 目录"
  INSTALL_STAGING_PATH="$INSTALL_WORK_DIR/$APP_NAME.app"
  INSTALL_BACKUP_PATH="$INSTALL_WORK_DIR/previous-$APP_NAME.app"
  if ! ditto --norsrc --noextattr "$APP_BUNDLE" "$INSTALL_STAGING_PATH"; then
    fail_step "准备覆盖安装" "无法复制已签名构建到受控 staging。" \
      "确认 ${install_parent} 可写后重试"
  fi
  verify_install_candidate "$INSTALL_STAGING_PATH"

  record_previous_install_state
  stop_running_app
  validate_existing_install_target "$INSTALL_APP_PATH"
  if [[ -e "$INSTALL_APP_PATH" ]]; then
    INSTALL_HAD_PREVIOUS_APP=1
  fi
  INSTALL_REPLACEMENT_ACTIVE=1
  if [[ "$INSTALL_HAD_PREVIOUS_APP" -eq 1 ]]; then
    if ! mv "$INSTALL_APP_PATH" "$INSTALL_BACKUP_PATH"; then
      fail_step "覆盖安装" "无法把原安装移动到受控 backup：${INSTALL_BACKUP_PATH}。" \
        "确认安装父目录可写，或改用用户 Applications 目录"
    fi
    INSTALL_OLD_APP_MOVED=1
  fi
  if ! mv "$INSTALL_STAGING_PATH" "$INSTALL_APP_PATH"; then
    fail_step "覆盖安装" "无法将新应用移入：${INSTALL_APP_PATH}。" \
      "确认目标目录可写，或设置 INSTALL_APP_PATH=\"${HOME}/Applications/${APP_NAME}.app\" 后重试 ./script/build_and_run.sh --verify"
  fi
  echo "  安装替换：新包已就位，原安装保留在受控 backup，等待验收提交"
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

  if [[ -d "$WIDGET_PROJECT" ]]; then
    [[ -d "$installed_widget" ]] || fail_step "校验安装签名" \
      "安装包缺少本项目要求的 Widget extension。" \
      "重新执行 ./script/build_and_run.sh --verify"
    verify_bundle_signature_and_entitlements "$installed_widget" "$WIDGET_ENTITLEMENTS" "已安装 Widget"
  fi
  verify_bundle_signature_and_entitlements "$INSTALL_APP_PATH" "$APP_ENTITLEMENTS" "已安装主应用与嵌套代码" --deep

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
  verify_preferred_owner_takeover
  verify_stale_copy_redirect

  local final_owner_pid final_owner_instance_id final_running_pids
  read_instance_owner_record || fail_step "校验最终 owner" \
    "跨副本挑战结束后无法读取有效 owner 记录。" \
    "检查 InstanceArbitration/v1/owner.json 后重试"
  final_owner_pid="$INSTANCE_OWNER_PID"
  final_owner_instance_id="$INSTANCE_OWNER_ID"
  final_running_pids="$(running_app_pids)"
  [[ -n "$REDIRECT_VERIFICATION_TOKEN" \
    && -n "$REDIRECT_OWNER_PID" \
    && -n "$REDIRECT_OWNER_INSTANCE_ID" \
    && "$final_running_pids" == "$REDIRECT_OWNER_PID" \
    && "$final_owner_pid" == "$REDIRECT_OWNER_PID" \
    && "$final_owner_instance_id" == "$REDIRECT_OWNER_INSTANCE_ID" ]] || fail_step \
    "校验最终 owner" "token 对应的重定向 owner 已崩溃、被替换，或与最终 owner record 不一致。" \
    "检查单实例与旧副本重定向日志后重试"
  kill -0 "$REDIRECT_OWNER_PID" >/dev/null 2>&1 || fail_step "校验最终 owner" \
    "token 对应的 redirect owner PID ${REDIRECT_OWNER_PID} 已不再存活。" \
    "检查重定向完成后的崩溃或退出日志"
  running_command="$(ps -p "$final_owner_pid" -o command= 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" || fail_step \
    "校验最终 owner" "无法读取最终 owner PID ${final_owner_pid} 的命令路径。" \
    "确认最终安装版仍在运行后重试"
  [[ "$running_command" == "$installed_binary" || "$running_command" == "$installed_binary "* ]] || fail_step \
    "校验最终 owner" "最终 owner 路径为 ${running_command}，预期为 ${installed_binary}。" \
    "确认首选安装路径后重试"
  commit_install

  echo "安装验收通过："
  echo "  安装路径：$INSTALL_APP_PATH"
  echo "  最终 owner：PID ${final_owner_pid}，instanceID ${final_owner_instance_id}"
  echo "  token 对应 owner：PID ${REDIRECT_OWNER_PID}，instanceID ${REDIRECT_OWNER_INSTANCE_ID}"
  echo "  运行路径：$running_command"
  echo "  运行版本：$installed_version ($installed_build)"
  echo "  代码签名：主应用、Widget 与预期 App Group entitlements 验证通过"
  echo "  旧副本 challenger：$APP_BINARY"
  echo "  重定向 token：$REDIRECT_VERIFICATION_TOKEN"
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
    lldb -- "$APP_BINARY" --codex-monitor-allow-development-instance
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
