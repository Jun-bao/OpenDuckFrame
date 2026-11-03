#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PRODUCTS="${ODF_TEST_FRAMEWORKS_DIR:-$ROOT/.build/Build/Products/Debug}"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang++ -std=c++17 -fobjc-arc -Wno-nullability-completeness -I "$ROOT/Modules/VideoEnhancement" -I "$ROOT/Modules/MediaCore/Bridge" -I "$ROOT/Modules/MediaCore/Core" \
  "$ROOT/Modules/VideoEnhancement/Tests/SPFileProviderEpochTests.mm" -F "$PRODUCTS" -framework OpenDuckFrameMediaCore -framework Foundation -framework CoreVideo -framework Metal \
  -Wl,-rpath,"$PRODUCTS" -o "$TEST_DIR/test"
"$TEST_DIR/test"
