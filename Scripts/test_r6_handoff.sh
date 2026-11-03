#!/bin/bash
# Tests only the local socket transport between two command-line processes.
# This does not launch OpenDuckFrame or prove its App Sandbox / GUI behavior.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
OUT="$ROOT/.build/r6-development"
mkdir -p "$OUT/module-cache"
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$OUT/module-cache" \
  "$ROOT/Apps/Mac/UI/SingleInstanceIPC.swift" \
  "$ROOT/Modules/VideoEnhancement/Tests/SingleInstanceHandoffTests.swift" -o "$OUT/r6-handoff-tests"
"$OUT/r6-handoff-tests"
