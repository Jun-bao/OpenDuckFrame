#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PRODUCTS="${ODF_TEST_FRAMEWORKS_DIR:-$ROOT/.build/Build/Products/Debug}"
APP="${ODF_TEST_RESOURCE_APP:-$ROOT/.build/Build/Products/Debug/OpenDuckFrame.app}"
DYLIB="${ODF_TEST_DEBUG_DYLIB:-$APP/Contents/MacOS/OpenDuckFrame.debug.dylib}"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang++ -std=c++17 -fobjc-arc -Wno-nullability-completeness -I "$ROOT/Modules/VideoEnhancement" -I "$ROOT/Apps/Mac/Capture" "$ROOT/Modules/VideoEnhancement/Tests/SPFileDistilProviderTests.mm" -F "$PRODUCTS" -framework OpenDuckFrameMediaCore -framework Foundation -framework CoreVideo -framework CoreMedia -Wl,-rpath,"$PRODUCTS" -o "$TEST_DIR/test"
"$TEST_DIR/test" "$DYLIB" "$APP" video
"$TEST_DIR/test" "$DYLIB" "$APP" full
