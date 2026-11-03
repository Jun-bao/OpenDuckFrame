#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PRODUCTS="${ODF_TEST_FRAMEWORKS_DIR:-$ROOT/.build/Build/Products/Debug}"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
"$(command -v ffmpeg)" -v error -f lavfi -i 'testsrc2=size=160x96:rate=24' -frames:v 2 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 -an "$TEST_DIR/source.mp4"
xcrun clang++ -std=c++17 -fobjc-arc -Wno-nullability-completeness -Wno-deprecated-declarations -I "$ROOT/Modules/VideoEnhancement" "$ROOT/Modules/VideoEnhancement/Tests/SPFileMetalFXTests.mm" -F "$PRODUCTS" -framework OpenDuckFrameMediaCore -framework Foundation -framework CoreVideo -framework CoreMedia -framework AVFoundation -framework Metal -Wl,-rpath,"$PRODUCTS" -o "$TEST_DIR/test"
"$TEST_DIR/test" "$TEST_DIR/source.mp4"
