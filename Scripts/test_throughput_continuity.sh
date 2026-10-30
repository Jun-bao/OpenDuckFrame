#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang++ -O2 -std=c++17 -I "$ROOT/Modules/VideoEnhancement" "$ROOT/Modules/VideoEnhancement/Tests/SPContinuityTests.cpp" -o "$TEST_DIR/frc"
"$TEST_DIR/frc"
xcrun swiftc -O "$ROOT/Apps/Mac/Capture/SPRifeContinuity.swift" "$ROOT/Modules/VideoEnhancement/Tests/SPRifeContinuityTests.swift" -o "$TEST_DIR/rife"
"$TEST_DIR/rife"
