#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
for test in SPFPSMeterTests SPPresentationOrderTests SPPresentationGeometryTests SPPresentationCostTests; do
  xcrun clang++ -O2 -std=c++17 -I "$ROOT/Modules/VideoEnhancement" "$ROOT/Modules/VideoEnhancement/Tests/$test.cpp" -o "$TEST_DIR/$test"
  "$TEST_DIR/$test"
done
