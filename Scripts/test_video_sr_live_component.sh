#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PRODUCTS="${ODF_TEST_FRAMEWORKS_DIR:-$ROOT/.build/Build/Products/Debug}"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang++ -std=c++17 -fobjc-arc -Wno-nullability-completeness -I "$ROOT/Apps/Mac/Capture" -I "$ROOT/Modules/VideoEnhancement" "$ROOT/Modules/VideoEnhancement/Tests/SPVideoSRLiveRegression.mm" -F "$PRODUCTS" -framework OpenDuckFrameMediaCore -framework Foundation -framework CoreVideo -framework CoreMedia -framework VideoToolbox -Wl,-rpath,"$PRODUCTS" -o "$TEST_DIR/test"
"$TEST_DIR/test"
