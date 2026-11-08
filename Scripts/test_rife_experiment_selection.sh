#!/bin/bash
# CPU-only preference and process-isolation checks, without starting the app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/SelectionTests.app"
mkdir -p "$APP/Contents/MacOS"
python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "wb") as target:
    plistlib.dump({"CFBundleExecutable": "SelectionTests", "CFBundleIdentifier": "app.openduckframe.SelectionTests",
                  "CFBundlePackageType": "APPL", "ODFExperimentTrial": True}, target)
PY
xcrun swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Apps/Mac/Capture/SPRifeExperiments.swift" \
  "$ROOT/Apps/Mac/UI/SingleInstancePolicy.swift" \
  "$ROOT/Modules/VideoEnhancement/Tests/SPRifeExperimentSelectionTests.swift" \
  -o "$APP/Contents/MacOS/SelectionTests"
"$APP/Contents/MacOS/SelectionTests"
