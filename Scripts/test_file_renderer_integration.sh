#!/bin/bash
# A CAMetalLayer with no window; never opens or controls a user interface.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PRODUCTS="${ODF_TEST_FRAMEWORKS_DIR:-$ROOT/.build/Build/Products/Debug}"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang++ -std=c++17 -fobjc-arc -I "$ROOT/Modules/MediaCore/Bridge" -I "$ROOT/Modules/VideoEnhancement" \
  "$ROOT/Modules/VideoEnhancement/Tests/SPFileRendererIntegration.mm" \
  -F "$PRODUCTS" -framework OpenDuckFrameMediaCore -framework AppKit -framework CoreVideo -framework Metal -framework QuartzCore \
  -Wl,-rpath,"$PRODUCTS" -o "$TEST_DIR/test"
"$TEST_DIR/test"
