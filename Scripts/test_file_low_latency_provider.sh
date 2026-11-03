#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PRODUCTS="${ODF_TEST_FRAMEWORKS_DIR:-$ROOT/.build/Build/Products/Debug}"
DYLIB="${ODF_TEST_DEBUG_DYLIB:-$ROOT/.build/Build/Products/Debug/OpenDuckFrame.app/Contents/MacOS/OpenDuckFrame.debug.dylib}"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang++ -std=c++17 -fobjc-arc -Wno-nullability-completeness -I "$ROOT/Modules/VideoEnhancement" "$ROOT/Modules/VideoEnhancement/Tests/SPFileLowLatencyProviderTests.mm" -F "$PRODUCTS" -framework OpenDuckFrameMediaCore -framework Foundation -framework CoreVideo -framework CoreMedia -Wl,-rpath,"$PRODUCTS" -o "$TEST_DIR/test"
"$TEST_DIR/test" "$DYLIB"
