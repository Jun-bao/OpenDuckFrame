#!/bin/bash
# Decode a temporary sample and exercise bundled optional backends without starting an app or window.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PRODUCTS="${KHUA_TEST_FRAMEWORKS_DIR:-$ROOT/.build/Build/Products/Debug}"
RESOURCE_APP="${KHUA_TEST_RESOURCE_APP:-$ROOT/.build/Build/Products/Debug/OpenDuckFrame.app}"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
"$(command -v ffmpeg)" -v error -f lavfi -i 'testsrc2=size=160x96:rate=24' -frames:v 2 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 -an "$TEST_DIR/source.mp4"
xcrun clang++ -std=c++17 -fobjc-arc -Wno-deprecated-declarations -Wno-nullability-completeness -I "$ROOT/Modules/VideoEnhancement" \
  "$ROOT/Modules/VideoEnhancement/Tests/SPFileAnimationTests.mm" -F "$PRODUCTS" -framework KhuaPlayerMediaCore \
  -framework Foundation -framework CoreVideo -framework CoreMedia -framework AVFoundation -framework Metal \
  -Wl,-rpath,"$PRODUCTS" -o "$TEST_DIR/test"
"$TEST_DIR/test" anime4k none "$RESOURCE_APP" "$TEST_DIR/source.mp4"
"$TEST_DIR/test" realcugan none "$RESOURCE_APP" "$TEST_DIR/source.mp4"
"$TEST_DIR/test" realcugan medium "$RESOURCE_APP" "$TEST_DIR/source.mp4"
