#!/bin/bash
# Opens an owned synthetic test window for 23–26 seconds. Does not capture the screen.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 OUTPUT.json [steady|jitter|source25|auto24|auto25|auto30]" >&2
  exit 2
fi
PROFILE="${2:-jitter}"
case "$PROFILE" in steady|jitter|source25|auto24|auto25|auto30) ;; *) echo 'expected steady, jitter, source25, auto24, auto25 or auto30' >&2; exit 2 ;; esac
PRODUCTS="${ODF_TEST_FRAMEWORKS_DIR:-$ROOT/.build/Build/Products/Debug}"
DYLIB="$PRODUCTS/OpenDuckFrame.app/Contents/MacOS/OpenDuckFrame.debug.dylib"
[ -f "$DYLIB" ] || { echo 'Build the Debug app first.' >&2; exit 2; }
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
PROBE="$TEST_DIR/Probe.app/Contents"
mkdir -p "$PROBE/MacOS" "$PROBE/Resources"
# The production presenter loads its Metal library from the main bundle.
cp "$PRODUCTS/OpenDuckFrame.app/Contents/Resources/default.metallib" "$PROBE/Resources/"
xcrun clang++ -std=c++17 -fobjc-arc -I "$ROOT/Apps/Mac/Capture" -I "$ROOT/Modules/VideoEnhancement" \
  "$ROOT/Modules/VideoEnhancement/Tests/SPAppleLivePresentationProbe.mm" \
  -framework AppKit -framework CoreVideo -framework CoreMedia -framework QuartzCore \
  -Wl,-rpath,"$PRODUCTS" -o "$PROBE/MacOS/probe"
"$PROBE/MacOS/probe" "$DYLIB" "$1" "$PROFILE"
