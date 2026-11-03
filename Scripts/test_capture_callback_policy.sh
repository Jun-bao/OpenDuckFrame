#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -module-cache-path "$ROOT/.build/ModuleCache" "$ROOT/Apps/Mac/Capture/CaptureCallbackPolicy.swift" "$ROOT/Modules/VideoEnhancement/Tests/CaptureCallbackPolicyTests.swift" -framework ScreenCaptureKit -o "$TEST_DIR/test"
"$TEST_DIR/test"
