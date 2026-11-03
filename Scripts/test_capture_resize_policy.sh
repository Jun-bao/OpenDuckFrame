#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$ROOT/.build/ModuleCache"
xcrun swiftc -parse-as-library -module-cache-path "$ROOT/.build/ModuleCache" \
 "$ROOT/Apps/Mac/Capture/CaptureRatePolicy.swift" \
 "$ROOT/Apps/Mac/Capture/CaptureResizePolicy.swift" \
 "$ROOT/Modules/VideoEnhancement/Tests/CaptureResizePolicyTests.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test"
python3 -I - "$ROOT/Apps/Mac/Capture/CaptureResizePolicy.swift" <<'PYTEST'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
assert 'guard request.generation == generation, inFlight == request else' in source, 'generation check must remain explicit in addition to token identity'
print('PASS explicit generation guard; behavioral stale callback also checked')
PYTEST
