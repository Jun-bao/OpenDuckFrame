#!/bin/bash
# Exercise the actual refresh button with an isolated, denied permission gate.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -parse-as-library \
    "$ROOT/Apps/Mac/UI/Enhancement/ScreenCapturePermission.swift" \
    "$ROOT/Apps/Mac/UI/Enhancement/WindowSelectionList.swift" \
    "$ROOT/Modules/VideoEnhancement/Tests/SPWindowPermissionFallbackTests.swift" \
    -o "$TEST_DIR/test"
"$TEST_DIR/test"
