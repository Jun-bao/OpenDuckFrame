#!/bin/bash
# Loads the actual debug code into a headless test process; no app/window launch.
set -euo pipefail
# Keep the parity reference stateless when the test disables its stream flag.
export CHUANFLOW_RIFE_STREAM=0
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PRODUCTS="${ODF_TEST_FRAMEWORKS_DIR:-$ROOT/.build/Build/Products/Debug}"
APP="${ODF_TEST_RESOURCE_APP:-$ROOT/.build/Build/Products/Debug/OpenDuckFrame.app}"
DYLIB="${ODF_TEST_DEBUG_DYLIB:-$ROOT/.build/Build/Products/Debug/OpenDuckFrame.app/Contents/MacOS/OpenDuckFrame.debug.dylib}"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
"$(command -v ffmpeg)" -v error -f lavfi -i 'testsrc2=size=320x192:rate=24' -frames:v 2 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 -an "$TEST_DIR/source.mp4"
xcrun clang++ -std=c++17 -fobjc-arc -Wno-deprecated-declarations -Wno-nullability-completeness -I "$ROOT/Apps/Mac/Capture" -I "$ROOT/Modules/VideoEnhancement" \
  "$ROOT/Modules/VideoEnhancement/Tests/SPFileRifeProviderTests.mm" -F "$PRODUCTS" -framework OpenDuckFrameMediaCore -framework Foundation -framework CoreVideo -framework CoreMedia -framework AVFoundation \
  -Wl,-rpath,"$PRODUCTS" -o "$TEST_DIR/test"
for model in rife-v4.25 rife-v4.26; do
  for quality in fast balanced hq; do
    "$TEST_DIR/test" "$DYLIB" "$APP" "$model" "$TEST_DIR/source.mp4" "$quality"
  done
done

"$TEST_DIR/test" "$DYLIB" "$APP" rife-v4.99 "$TEST_DIR/source.mp4" fast reject
"$TEST_DIR/test" "$DYLIB" "$APP" rife-v4.25 "$TEST_DIR/source.mp4" unsupported reject
