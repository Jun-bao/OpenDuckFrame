#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang++ -std=c++17 -I "$ROOT/Modules/VideoEnhancement" "$ROOT/Modules/VideoEnhancement/Tests/SPPresentationBudgetTests.cpp" -o "$TEST_DIR/test"
"$TEST_DIR/test"
