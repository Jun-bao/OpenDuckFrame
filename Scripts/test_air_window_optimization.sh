#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang++ -std=c++17 -Wall -Wextra -pedantic -I "$ROOT/Apps/Mac/Capture" \
  "$ROOT/Modules/VideoEnhancement/Tests/SPAirWindowOptimizationTests.cpp" -o "$TEST_DIR/air-window-optimization-tests"
"$TEST_DIR/air-window-optimization-tests"
