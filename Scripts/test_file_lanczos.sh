#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang++ -std=c++17 -fobjc-arc -I "$ROOT/Modules/VideoEnhancement" \
  "$ROOT/Modules/VideoEnhancement/SPFileLanczosScaler.mm" "$ROOT/Modules/VideoEnhancement/Tests/SPFileLanczosTests.mm" \
  -framework Foundation -framework CoreVideo -framework CoreGraphics -framework Metal -framework MetalPerformanceShaders -o "$TEST_DIR/test"
"$TEST_DIR/test"
