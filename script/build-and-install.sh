#!/usr/bin/env bash
# Compatibility entry point. The verified installer in build_and_run.sh owns
# path validation, transactional replacement, signing checks, Widget binding,
# single-instance acceptance, and rollback. Keep only one implementation so
# this legacy command cannot silently install an unverified or ad-hoc Widget.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

case "${1:-}" in
  "")
    ;;
  --help|-h)
    echo "用法：$0"
    echo "兼容入口；等同于 ./script/build_and_run.sh --verify"
    exit 0
    ;;
  *)
    echo "不支持的参数：$1" >&2
    echo "请使用 ./script/build_and_run.sh --help" >&2
    exit 2
    ;;
esac

echo "[build] build-and-install.sh 已统一转交给 build_and_run.sh --verify"
exec "$ROOT_DIR/script/build_and_run.sh" --verify
