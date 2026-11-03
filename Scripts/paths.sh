#!/bin/bash
# Shared release paths. Source this file from scripts; do not run it directly.
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TASK_ROOT/Resources/Info.plist")"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Info.plist 中的发布版本无效：$APP_VERSION" >&2
  exit 1
fi
VERSION_ROOT="$TASK_ROOT/outputs/TrayBridge-$APP_VERSION"
APP_ROOT="$VERSION_ROOT/TrayBridge.app"
APP_EXECUTABLE="$APP_ROOT/Contents/MacOS/TrayBridge"
BUILD_ROOT="$TASK_ROOT/work/build/$APP_VERSION"
MODULE_CACHE_ROOT="$TASK_ROOT/work/build/module-cache"
SOURCE_STAGE="$TASK_ROOT/work/package/TrayBridge-$APP_VERSION-Source"
APP_ZIP="$TASK_ROOT/outputs/TrayBridge-$APP_VERSION-macOS15-Universal.zip"
SOURCE_ZIP="$TASK_ROOT/outputs/TrayBridge-$APP_VERSION-Source.zip"
