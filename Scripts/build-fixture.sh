#!/bin/bash
set -euo pipefail

TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_ROOT="$TASK_ROOT/work/fixtures"
FIXTURE_APP="$FIXTURE_ROOT/TrayBridgeFixture.app"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "$FIXTURE_APP/Contents/MacOS" "$TASK_ROOT/work/build/module-cache"
xcrun swiftc \
  -sdk "$SDK_PATH" \
  -target "$(uname -m)-apple-macosx15.0" \
  -module-cache-path "$TASK_ROOT/work/build/module-cache" \
  -module-name TrayBridgeFixture \
  -swift-version 5 -O \
  "$TASK_ROOT/Tests/MenuBarFixture.swift" \
  -o "$FIXTURE_APP/Contents/MacOS/TrayBridgeFixture"

cat > "$FIXTURE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.local.TrayBridgeFixture</string>
  <key>CFBundleName</key><string>TrayBridgeFixture</string>
  <key>CFBundleDisplayName</key><string>TrayBridge 测试宿主</string>
  <key>CFBundleExecutable</key><string>TrayBridgeFixture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
printf 'APPL????' > "$FIXTURE_APP/Contents/PkgInfo"
plutil -lint "$FIXTURE_APP/Contents/Info.plist"
codesign --force --sign - "$FIXTURE_APP"
codesign --verify --strict "$FIXTURE_APP"
echo "测试宿主已构建（未运行）：$FIXTURE_APP"
