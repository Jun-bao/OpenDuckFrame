#!/bin/bash
# A prohibited-activation process and a layer without a window; no user GUI or audio.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PRODUCTS="${KHUA_TEST_FRAMEWORKS_DIR:-$ROOT/.build/Build/Products/Debug}"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
FFMPEG="$(command -v ffmpeg)"
VIDEO_SIZE="320x192"
if [[ "${KHUA_TEST_APPLE_SR:-0}" == 1 || "${KHUA_TEST_REAL_FILE_LOW_LATENCY:-0}" == 1 || "${KHUA_TEST_REAL_FILE_DISTIL:-0}" == 1 || "${KHUA_TEST_FILE_METALFX:-0}" == 1 ]]; then VIDEO_SIZE="1280x720"; fi
if [[ -n "${KHUA_TEST_ANIMATION_ENGINE:-}" ]]; then VIDEO_SIZE="160x96"; fi
if [[ -n "${KHUA_LOW_TEST_SIZE:-}" ]]; then VIDEO_SIZE="$KHUA_LOW_TEST_SIZE"; fi
if [[ "${KHUA_TEST_FILE_VIDEO_SR:-0}" == 1 ]]; then VIDEO_SIZE="480x270"; fi
GOP=12
if [[ "${KHUA_TEST_SCAN_WAIT:-0}" == 1 ]]; then GOP=250; fi
"$FFMPEG" -v error -f lavfi -i "testsrc2=size=${VIDEO_SIZE}:rate=24" -t 3 -c:v libx264 -preset ultrafast \
  -g "$GOP" -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 -an "$TEST_DIR/source.mp4"
xcrun clang++ -std=c++17 -fobjc-arc -Wno-nullability-completeness -I "$ROOT/Modules/MediaCore/Bridge" -I "$ROOT/Modules/VideoEnhancement" -I "$ROOT/Apps/Mac/Capture" \
  "$ROOT/Modules/VideoEnhancement/Tests/SPFileCoreHeadlessTests.mm" -F "$PRODUCTS" \
  -framework KhuaPlayerMediaCore -framework Foundation -framework AppKit -framework CoreVideo -framework QuartzCore \
  -Wl,-rpath,"$PRODUCTS" -o "$TEST_DIR/test"
if [[ -n "${KHUA_TEST_ANIMATION_ENGINE:-}" ]]; then
  "$TEST_DIR/test" "$TEST_DIR/source.mp4" "$KHUA_TEST_ANIMATION_ENGINE" "${KHUA_TEST_RESOURCE_APP:?resource app required}"
elif [[ "${KHUA_TEST_FILE_VIDEO_SR:-0}" == 1 ]]; then
  "$TEST_DIR/test" "$TEST_DIR/source.mp4" videosr
elif [[ "${KHUA_TEST_FILE_METALFX:-0}" == 1 ]]; then
  "$TEST_DIR/test" "$TEST_DIR/source.mp4" metalfx
elif [[ "${KHUA_TEST_APPLE_SR:-0}" == 1 ]]; then
  "$TEST_DIR/test" "$TEST_DIR/source.mp4" apple
else
  "$TEST_DIR/test" "$TEST_DIR/source.mp4"
fi
