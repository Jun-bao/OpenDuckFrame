#!/bin/bash
# Real Apple inference with large synthetic capture buffers; no screen recording.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PRODUCTS="${ODF_TEST_FRAMEWORKS_DIR:-$ROOT/.build/Build/Products/Debug}"
DYLIB="${ODF_TEST_DEBUG_DYLIB:-$PRODUCTS/OpenDuckFrame.app/Contents/MacOS/OpenDuckFrame.debug.dylib}"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang++ -std=c++17 -fobjc-arc -I "$ROOT/Apps/Mac/Capture" -I "$ROOT/Modules/VideoEnhancement" \
  "$ROOT/Modules/VideoEnhancement/Tests/SPAppleLiveSizeTests.mm" \
  -framework AppKit -framework Foundation -framework VideoToolbox -framework CoreVideo -framework CoreMedia \
  -Wl,-rpath,"$PRODUCTS" -o "$TEST_DIR/test"
"$TEST_DIR/test" "$DYLIB"
