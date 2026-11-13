#!/bin/bash
# Real RIFE GPU test, headless. Requires the current Debug app; no capture or UI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
APP="$ROOT/.build/Build/Products/Debug/OpenDuckFrame.app"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang++ -std=c++17 -fobjc-arc -Wno-nullability-completeness \
  -I "$ROOT/Apps/Mac/Capture" -I "$ROOT/Modules/VideoEnhancement" \
  "$ROOT/Modules/VideoEnhancement/Tests/SPWindowOptimizationPreparationTests.mm" \
  -framework Foundation -framework CoreVideo -framework CoreMedia \
  -Wl,-rpath,"$APP/Contents/Frameworks" -o "$TEST_DIR/test"
"$TEST_DIR/test" "$APP/Contents/MacOS/OpenDuckFrame.debug.dylib" "$APP"
