#!/bin/bash
# Headless CLI: no application, target window or capture stream is started.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PRODUCTS="${KHUA_TEST_FRAMEWORKS_DIR:-$ROOT/.build/Build/Products/Debug}"
APP="${KHUA_TEST_RESOURCE_APP:-$ROOT/.build/Build/Products/Debug/Khua.app}"
DYLIB="${KHUA_TEST_DEBUG_DYLIB:-$APP/Contents/MacOS/Khua.debug.dylib}"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
# Give the headless executable a private bundle only for the app's actual Metal
# shader lookup. It is executed directly, never opened via Launch Services.
mkdir -p "$TEST_DIR/Probe.app/Contents/MacOS" "$TEST_DIR/Probe.app/Contents/Resources"
cp "$APP/Contents/Resources/default.metallib" "$TEST_DIR/Probe.app/Contents/Resources/default.metallib"
if [[ "${1:-}" == "switch" ]]; then
  cp "$APP/Contents/Resources/rife-v4.26.rmw" "$TEST_DIR/Probe.app/Contents/Resources/rife-v4.26.rmw"
fi
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.khua.headless</string><key>CFBundleExecutable</key><string>test</string></dict></plist>' > "$TEST_DIR/Probe.app/Contents/Info.plist"
xcrun clang++ -std=c++17 -fobjc-arc "$ROOT/Modules/VideoEnhancement/Tests/SPLiveOutputRepairTests.mm" -framework Foundation -framework CoreFoundation -framework AppKit -Wl,-rpath,"$PRODUCTS" -o "$TEST_DIR/Probe.app/Contents/MacOS/test"
"$TEST_DIR/Probe.app/Contents/MacOS/test" "$DYLIB" "$APP" "$@"
