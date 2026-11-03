#!/bin/bash
# Direct headless executable, no Launch Services or application launch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
if [[ $# -ne 7 ]]; then
  echo "usage: bash $0 DEBUG_DYLIB APP rife|frc fast|balanced|normal lines|natural|static unpaced|paced OUTPUT_PREFIX" >&2
  exit 2
fi
DYLIB="$1"; APP="$2"; shift 2
[[ "$DYLIB" == *.debug.dylib ]] || { echo "Only a Debug dylib is supported; this is not a Release benchmark." >&2; exit 2; }
DYLIB="$(cd "$(dirname "$DYLIB")" && pwd -P)/$(basename "$DYLIB")"
APP="$(cd "$APP" && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/Probe.app/Contents/MacOS" "$TEST_DIR/Probe.app/Contents/Resources"
cp "$APP/Contents/Resources/default.metallib" "$TEST_DIR/Probe.app/Contents/Resources/default.metallib"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.chuanflow.throughput</string><key>CFBundleExecutable</key><string>probe</string></dict></plist>' > "$TEST_DIR/Probe.app/Contents/Info.plist"
PREFIX="$5"
set +e
xcrun clang++ -O2 -std=c++20 -fobjc-arc -Wno-deprecated-declarations -I "$ROOT/Modules/VideoEnhancement" -I "$ROOT/Apps/Mac/Capture" "$ROOT/Modules/VideoEnhancement/Tests/SPThroughputProbe.mm" -framework Foundation -framework CoreFoundation -framework CoreVideo -framework CoreMedia -framework Metal -Wl,-rpath,"$APP/Contents/Frameworks" -Wl,-rpath,"$(dirname "$APP")" -o "$TEST_DIR/Probe.app/Contents/MacOS/probe"
compile_exit=$?
if [[ $compile_exit -ne 0 ]]; then
  printf '%s\n' "$compile_exit" > "$PREFIX.exit"
  exit "$compile_exit"
fi
"$TEST_DIR/Probe.app/Contents/MacOS/probe" "$DYLIB" "$APP" "$@" > "$PREFIX.json"
probe_exit=$?
set -e
printf '%s\n' "$probe_exit" > "$PREFIX.exit"
exit "$probe_exit"
