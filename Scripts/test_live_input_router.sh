#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -swift-version 6 -strict-concurrency=minimal -parse-as-library "$ROOT/Apps/Mac/Capture/LiveInputRouter.swift" "$ROOT/Modules/VideoEnhancement/Tests/LiveInputRouterTests.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test"
