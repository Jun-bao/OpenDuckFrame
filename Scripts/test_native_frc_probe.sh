#!/bin/bash
# Direct VT SDK, synthetic buffers only; no app, window, capture or physical display.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang++ -std=c++17 -fobjc-arc "$ROOT/Modules/VideoEnhancement/Tests/SPNativeFRCProbe.mm" -framework Foundation -framework CoreVideo -framework CoreMedia -framework VideoToolbox -o "$TEST_DIR/probe"
"$TEST_DIR/probe"
