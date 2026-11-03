#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/paths.sh"

case "${1:-run}" in
  run)
    open "$APP_ROOT"
    ;;
  diagnose)
    "$APP_EXECUTABLE" --diagnose
    ;;
  *)
    echo "用法：$0 [run|diagnose]" >&2
    exit 2
    ;;
esac
