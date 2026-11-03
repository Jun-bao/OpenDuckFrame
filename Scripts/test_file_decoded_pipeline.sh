#!/bin/bash
# Actual decoded NV12 frames into the player's FRC generator, without a GUI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PRODUCTS="${ODF_TEST_FRAMEWORKS_DIR:-$ROOT/.build/Build/Products/Debug/OpenDuckFrame.app/Contents/Frameworks}"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
VIDEO_SIZE=320x192
if [[ "${ODF_TEST_REAL_DISTIL:-0}" == 1 ]]; then VIDEO_SIZE=1280x720; fi
if [[ "${ODF_TEST_VIDEO_SR_COMBOS:-0}" == 1 ]]; then VIDEO_SIZE=480x270; fi
"$(command -v ffmpeg)" -v error -f lavfi -i "testsrc2=size=${VIDEO_SIZE}:rate=24" -t 3 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -color_primaries bt709 -color_trc bt709 -colorspace bt709 -an "$TEST_DIR/source.mp4"
xcrun clang++ -std=c++17 -fobjc-arc -Wno-deprecated-declarations -Wno-nullability-completeness \
  -I "$ROOT/Modules/VideoEnhancement" -I "$ROOT/Apps/Mac/Capture" -I "$ROOT/Modules/MediaCore/Bridge" -I "$ROOT/Modules/MediaCore/Core" \
  "$ROOT/Modules/VideoEnhancement/Tests/SPFilePipelineProbe.mm" -F "$PRODUCTS" \
  -framework OpenDuckFrameMediaCore -framework Foundation -framework CoreVideo -framework CoreMedia -framework Metal -framework MetalPerformanceShaders -framework AVFoundation \
  -Wl,-rpath,"$PRODUCTS" -o "$TEST_DIR/test"
if [[ "${ODF_TEST_REAL_DISTIL:-0}" != 1 && "${ODF_TEST_VIDEO_SR_COMBOS:-0}" != 1 ]]; then
  for mode in 1 2 3 4; do "$TEST_DIR/test" "$mode" "$TEST_DIR/source.mp4"; done
  ODF_PROBE_SCALE=1 "$TEST_DIR/test" 3 "$TEST_DIR/source.mp4"
fi
if [[ "${ODF_TEST_FAKE_PROVIDER:-0}" == 1 ]]; then
  for mode in 1 2 3 4; do "$TEST_DIR/test" "$mode" "$TEST_DIR/source.mp4" fake; done
fi

if [[ "${ODF_TEST_REAL_RIFE:-0}" == 1 ]]; then
  for model in rife-v4.25 rife-v4.26; do
    for mode in 1 2 3 4; do "$TEST_DIR/test" "$mode" "$TEST_DIR/source.mp4" "$model"; done
  done
  ODF_PROBE_SCALE=1 "$TEST_DIR/test" 2 "$TEST_DIR/source.mp4" rife-v4.26
fi

if [[ "${ODF_TEST_REAL_LOW_LATENCY:-0}" == 1 ]]; then
  "$TEST_DIR/test" 2 "$TEST_DIR/source.mp4" apple-lowlatency
fi

if [[ "${ODF_TEST_THREE_PROVIDER:-0}" == 1 ]]; then
  "$TEST_DIR/test" 2 "$TEST_DIR/source.mp4" three
fi

if [[ "${ODF_TEST_REAL_DISTIL:-0}" == 1 ]]; then
  "$TEST_DIR/test" 2 "$TEST_DIR/source.mp4" distil
fi

if [[ "${ODF_TEST_METALFX_COMBOS:-0}" == 1 ]]; then
  ODF_PROBE_METALFX=1 "$TEST_DIR/test" 2 "$TEST_DIR/source.mp4" rife-v4.26
  ODF_PROBE_METALFX=1 "$TEST_DIR/test" 2 "$TEST_DIR/source.mp4" apple-lowlatency
fi

if [[ "${ODF_TEST_VIDEO_SR_COMBOS:-0}" == 1 ]]; then
  ODF_PROBE_VIDEO_SR=1 "$TEST_DIR/test" 2 "$TEST_DIR/source.mp4" rife-v4.26
  ODF_PROBE_VIDEO_SR=1 "$TEST_DIR/test" 2 "$TEST_DIR/source.mp4" apple-lowlatency
fi
