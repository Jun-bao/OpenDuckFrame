#!/bin/bash
# Small temporary file with audio, decoded off-screen; no user media or GUI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
FFMPEG="$(command -v ffmpeg)"
"$FFMPEG" -v error -f lavfi -i 'testsrc2=size=320x192:rate=24' -f lavfi -i 'sine=frequency=440:sample_rate=48000' \
  -t 1 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -c:a aac "$TEST_DIR/source.mp4"
xcrun clang++ -std=c++17 -fobjc-arc -Wno-deprecated-declarations -I "$ROOT/Modules/VideoEnhancement" \
  "$ROOT/Modules/VideoEnhancement/SPFileLanczosScaler.mm" "$ROOT/Modules/VideoEnhancement/Tests/SPFileDecodedLanczosTests.mm" \
  -framework Foundation -framework CoreVideo -framework CoreGraphics -framework CoreMedia -framework Metal -framework MetalPerformanceShaders -framework AVFoundation -framework AudioToolbox \
  -o "$TEST_DIR/test"
"$TEST_DIR/test" "$TEST_DIR/source.mp4"
