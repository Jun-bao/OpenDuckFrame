#!/bin/bash
# Independent no-window test of the player FPS label's unavailable/valid states.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
python3 - "$ROOT" "$TEST_DIR/test.swift" <<'PY'
import pathlib, sys
source=(pathlib.Path(sys.argv[1])/'Apps/Mac/UI/PlayerUIModel.swift').read_text()
prefix=source[:source.index('enum PlayerCommand:')]
test='''
func L(_ key: String, _ args: CVarArg...) -> String { key }
@main struct Test {
  static func main() {
    let unavailable = MotionPresentation(hasMedia:true, requested:true, available:true,
        active:true, outputFPS:-1, sourceFPS:24, status:"")
    precondition(unavailable.fpsReadout == nil)
    let measured = MotionPresentation(hasMedia:true, requested:true, available:true,
        active:true, outputFPS:47.8, sourceFPS:24, status:"")
    precondition(measured.fpsReadout == "48")
    print("player physical FPS readout contract passed")
  }
}
'''
pathlib.Path(sys.argv[2]).write_text(prefix+'\n'+test)
PY
xcrun swiftc -parse-as-library "$TEST_DIR/test.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test"
