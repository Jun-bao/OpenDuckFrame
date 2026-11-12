#!/bin/bash
# Pure CPU math checks; does not create a Metal device or launch the app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Apps/Mac/Capture/SPResidentCalibrationPolicy.swift" \
  "$ROOT/Modules/VideoEnhancement/Tests/SPResidentCalibrationPolicyTests.swift" -o "$WORK/test"
"$WORK/test"
