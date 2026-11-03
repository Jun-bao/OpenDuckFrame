#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$ROOT/.build/ModuleCache"
xcrun swiftc -module-cache-path "$ROOT/.build/ModuleCache" "$ROOT/Apps/Mac/Capture/CaptureRatePolicy.swift" "$ROOT/Modules/VideoEnhancement/Tests/CaptureRatePolicyTests.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test"
