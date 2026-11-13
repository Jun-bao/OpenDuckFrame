#!/bin/bash
# Exercise the permission decision without changing macOS privacy settings.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -parse-as-library \
    "$ROOT/Apps/Mac/UI/Enhancement/ScreenCapturePermission.swift" \
    "$ROOT/Modules/VideoEnhancement/Tests/SPScreenCapturePermissionTests.swift" \
    -o "$TEST_DIR/test"
"$TEST_DIR/test"
