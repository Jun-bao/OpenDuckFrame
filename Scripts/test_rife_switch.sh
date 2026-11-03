#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
APP="$ROOT/.build/Build/Products/Debug/OpenDuckFrame.app"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang++ -fobjc-arc "$ROOT/Modules/VideoEnhancement/Tests/SPRifeSwitchTests.mm" -framework Foundation -Wl,-rpath,"$APP/Contents/Frameworks" -o "$TEST_DIR/test"
env -u CHUANFLOW_RIFE_STREAM "$TEST_DIR/test" "$APP/Contents/MacOS/Khua.debug.dylib" 0
CHUANFLOW_RIFE_STREAM=1 "$TEST_DIR/test" "$APP/Contents/MacOS/Khua.debug.dylib" 1
