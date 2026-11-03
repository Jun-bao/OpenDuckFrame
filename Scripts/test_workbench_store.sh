#!/bin/bash
# Isolated, no live preferences or EnhancementProfile.json writes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
python3 - "$ROOT" "$TEST_DIR/source.swift" <<'PY'
import pathlib, sys
root=pathlib.Path(sys.argv[1])
source=(root/'Apps/Mac/UI/Enhancement/EnhancementWorkbench.swift').read_text()
prefix=source[:source.index('final class EnhancementWorkbenchController:')]
test=(root/'Modules/VideoEnhancement/Tests/SPWorkbenchStoreTests.swift').read_text()
pathlib.Path(sys.argv[2]).write_text(prefix+'\n'+test)
PY
xcrun swiftc -parse-as-library "$TEST_DIR/source.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test"
