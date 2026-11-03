#!/bin/bash
set -euo pipefail

source "$(dirname "$0")/paths.sh"
TEST_ROOT="$TASK_ROOT/work/tests"

if [[ ! -x "$APP_EXECUTABLE" ]]; then
  echo "请先运行 make build。" >&2
  exit 1
fi

"$APP_EXECUTABLE" --self-test
mkdir -p "$TEST_ROOT" "$MODULE_CACHE_ROOT"
cat > "$TEST_ROOT/main.swift" <<'SWIFT'
import Foundation

do {
    let geometryChecks = try runGeometryTests()
    let discoveryChecks = try runDiscoveryTests()
    print("Geometry tests passed: \(geometryChecks) checks")
    print("Discovery tests passed: \(discoveryChecks) checks")
    print("Independent tests passed: \(geometryChecks + discoveryChecks) checks")
} catch {
    fputs("Independent tests failed: \(error)\n", stderr)
    exit(1)
}
SWIFT

xcrun swiftc \
  "$TASK_ROOT/Sources/TrayBridge/Geometry.swift" \
  "$TASK_ROOT/Sources/TrayBridge/DiscoveryState.swift" \
  "$TASK_ROOT/Tests/GeometryTests.swift" \
  "$TASK_ROOT/Tests/DiscoveryTests.swift" \
  "$TEST_ROOT/main.swift" \
  -module-cache-path "$MODULE_CACHE_ROOT" \
  -o "$TEST_ROOT/logic-tests"
"$TEST_ROOT/logic-tests"
