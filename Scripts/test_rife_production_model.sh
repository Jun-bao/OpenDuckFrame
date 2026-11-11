#!/bin/bash
# CPU-only check of the prepared model and the application's actual identity gate.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Apps/Mac/Capture/SPRifeExperiments.swift" \
  "$ROOT/Modules/VideoEnhancement/Tests/SPRifeProductionModelTests.swift" -o "$WORK/test"
"$WORK/test" "$ROOT/ThirdParty/rife-metal/runtime/Sources/RifeMetal/Resources/rife-v4.25.rmw"
