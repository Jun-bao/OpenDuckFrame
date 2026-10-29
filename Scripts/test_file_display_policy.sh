#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
sed '/^final class PlayerWindowController:/,$d' "$ROOT/Apps/Mac/UI/PlayerWindowController.swift" > "$TEST_DIR/Policy.swift"
xcrun swiftc -parse-as-library "$TEST_DIR/Policy.swift" "$ROOT/Modules/VideoEnhancement/Tests/SPFileDisplayPolicyTests.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test"
