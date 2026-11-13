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
handler=source.split('@objc private func controlChanged()',1)[1]
size_controls='let selectedEngine ='+handler.split('let selectedEngine =',1)[1].split('let wasLanczos',1)[0]
test=test.replace('// ACTUAL_SOURCE_WINDOW_CONTROL_CHANGE',size_controls)
selected_source=source.split('private var hasSelectedSource: Bool {',1)[1].split('    private func updateSourceChrome',1)[0].rsplit('}',1)[0]
actions=source.split('private func refreshActions() {',1)[1].split('    private func row(',1)[0].rsplit('}',1)[0]
start_handler=source.split('@objc private func start() {',1)[1].split('    @objc private func startDelayedWindow()',1)[0].rsplit('}',1)[0]
delay_handler=source.split('@objc private func startDelayedWindow() {',1)[1].split('    private func hideScreenCountdown()',1)[0].rsplit('}',1)[0]
plan_label=source.split('private func refreshPlanLabel()',1)[1]
form_difference='let formDiffers ='+plan_label.split('let formDiffers =',1)[1].split('hasPendingFormChanges = formDiffers',1)[0]
test=test.replace('// ACTUAL_SELECTED_SOURCE',selected_source)
test=test.replace('// ACTUAL_WORKBENCH_ACTIONS',actions)
test=test.replace('// ACTUAL_START_HANDLER',start_handler)
test=test.replace('// ACTUAL_DELAY_HANDLER',delay_handler)
test=test.replace('// ACTUAL_FORM_DIFFERENCE',form_difference)
pathlib.Path(sys.argv[2]).write_text(prefix+'\n'+test)
PY
xcrun swiftc -parse-as-library "$ROOT/Apps/Mac/UI/Enhancement/LiveFPSOverlay.swift" "$TEST_DIR/source.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test"
