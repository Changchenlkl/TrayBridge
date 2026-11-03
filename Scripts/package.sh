#!/bin/bash
set -euo pipefail

source "$(dirname "$0")/paths.sh"

if [[ ! -d "$APP_ROOT" ]]; then
  echo "请先运行 make build。" >&2
  exit 1
fi
codesign --verify --strict "$APP_ROOT"
mkdir -p "$TASK_ROOT/outputs" "$(dirname "$SOURCE_STAGE")"
rm -rf "$SOURCE_STAGE"
mkdir -p "$SOURCE_STAGE"
for TASK_ENTRY in Sources Tests Scripts Resources README.md Makefile .gitignore; do
  if [[ -e "$TASK_ROOT/$TASK_ENTRY" ]]; then
    ditto "$TASK_ROOT/$TASK_ENTRY" "$SOURCE_STAGE/$TASK_ENTRY"
  fi
done

rm -f "$APP_ZIP" "$SOURCE_ZIP"
ditto -c -k --sequesterRsrc --keepParent \
  "$APP_ROOT" "$APP_ZIP"
ditto -c -k --sequesterRsrc --keepParent \
  "$SOURCE_STAGE" "$SOURCE_ZIP"
cp "$TASK_ROOT/README.md" "$VERSION_ROOT/使用说明.md"
echo "打包完成：$APP_ZIP"
echo "源码：$SOURCE_ZIP"
