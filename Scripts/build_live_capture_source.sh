#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
APP="$ROOT/.build/LiveHarness/OpenDuckFrameControlledSource.app"
mkdir -p "$APP/Contents/MacOS" "$ROOT/.build/ModuleCache"
xcrun swiftc -parse-as-library -module-cache-path "$ROOT/.build/ModuleCache" "$ROOT/Modules/VideoEnhancement/Tests/LiveCaptureSource.swift" -o "$APP/Contents/MacOS/LiveCaptureSource"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.openduckframe.controlledsource</string><key>CFBundleExecutable</key><string>LiveCaptureSource</string><key>CFBundleName</key><string>OpenDuckFrame Controlled Source</string><key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
printf 'Built %s\n' "$APP"
