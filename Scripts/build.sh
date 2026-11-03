#!/bin/bash
set -euo pipefail

source "$(dirname "$0")/paths.sh"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "$TASK_ROOT/work"
if [[ -e "$APP_EXECUTABLE" ]]; then
  RUNNING_CHECK_STDOUT="$TASK_ROOT/work/running-check-$APP_VERSION.stdout"
  RUNNING_CHECK_STDERR="$TASK_ROOT/work/running-check-$APP_VERSION.stderr"
  if [[ ! -x /usr/sbin/lsof ]]; then
    echo "无法确认覆盖安全：lsof 不可用，已保留现有应用：$APP_ROOT" >&2
    exit 1
  fi
  if /usr/sbin/lsof -t "$APP_EXECUTABLE" >"$RUNNING_CHECK_STDOUT" 2>"$RUNNING_CHECK_STDERR"; then
    RUNNING_CHECK_STATUS=0
  else
    RUNNING_CHECK_STATUS=$?
  fi
  if [[ -s "$RUNNING_CHECK_STDOUT" ]]; then
    echo "检测到当前版本可执行文件正被进程使用，请先退出后再构建：$APP_ROOT" >&2
    echo "进程记录：$RUNNING_CHECK_STDOUT" >&2
    exit 1
  fi
  if [[ -s "$RUNNING_CHECK_STDERR" ]]; then
    echo "无法确认覆盖安全：lsof 返回错误或警告，已保留现有应用。" >&2
    echo "检查记录：$RUNNING_CHECK_STDERR" >&2
    exit 1
  fi
  if [[ "$RUNNING_CHECK_STATUS" -ne 1 ]]; then
    echo "无法确认覆盖安全：lsof 返回了非预期结果（$RUNNING_CHECK_STATUS），已保留现有应用。" >&2
    exit 1
  fi
fi
mkdir -p "$BUILD_ROOT" "$MODULE_CACHE_ROOT" "$VERSION_ROOT"
shopt -s nullglob
SWIFT_SOURCES=("$TASK_ROOT"/Sources/TrayBridge/*.swift)
if [[ ${#SWIFT_SOURCES[@]} -eq 0 ]]; then
  echo "没有找到 Sources/TrayBridge/*.swift" >&2
  exit 1
fi

for TASK_ARCH in arm64 x86_64; do
  echo "正在编译 ${TASK_ARCH}（macOS 15+）…"
  xcrun swiftc \
    -sdk "$SDK_PATH" \
    -target "$TASK_ARCH-apple-macosx15.0" \
    -module-cache-path "$MODULE_CACHE_ROOT" \
    -module-name TrayBridge \
    -swift-version 5 -O -whole-module-optimization \
    "${SWIFT_SOURCES[@]}" \
    -o "$BUILD_ROOT/TrayBridge-$TASK_ARCH"
done

# Assemble only after both architecture builds have succeeded.
STAGING_APP="$BUILD_ROOT/TrayBridge.app"
rm -rf "$STAGING_APP"
mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources"
xcrun lipo -create \
  "$BUILD_ROOT/TrayBridge-arm64" \
  "$BUILD_ROOT/TrayBridge-x86_64" \
  -output "$STAGING_APP/Contents/MacOS/TrayBridge"
cp "$TASK_ROOT/Resources/Info.plist" "$STAGING_APP/Contents/Info.plist"
cp "$TASK_ROOT/Resources/TrayBridge.icns" "$STAGING_APP/Contents/Resources/TrayBridge.icns"
cp "$TASK_ROOT/README.md" "$STAGING_APP/Contents/Resources/使用说明.md"
printf 'APPL????' > "$STAGING_APP/Contents/PkgInfo"
chmod 755 "$STAGING_APP/Contents/MacOS/TrayBridge"
plutil -lint "$STAGING_APP/Contents/Info.plist"

# Local, ad-hoc signature; this is not Developer ID signing or notarization.
codesign --force --sign - "$STAGING_APP"
codesign --verify --strict "$STAGING_APP"
rm -rf "$APP_ROOT"
ditto "$STAGING_APP" "$APP_ROOT"
echo "构建完成：$APP_ROOT"
xcrun lipo -archs "$APP_ROOT/Contents/MacOS/TrayBridge"
