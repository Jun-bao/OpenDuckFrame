#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang++ -std=c++17 -fobjc-arc -I "$ROOT/Modules/VideoEnhancement" "$ROOT/Modules/VideoEnhancement/Tests/SPFileColorTransferTests.mm" -framework Foundation -framework CoreVideo -framework VideoToolbox -framework Metal -o "$TEST_DIR/test"
"$TEST_DIR/test"
