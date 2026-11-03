#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -O -parse-as-library "$ROOT/Apps/Mac/Capture/ContentFrameGate.swift" "$ROOT/Apps/Mac/UI/Enhancement/LiveFPSOverlay.swift" "$ROOT/Modules/VideoEnhancement/Tests/ContentFrameGateTests.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test"
