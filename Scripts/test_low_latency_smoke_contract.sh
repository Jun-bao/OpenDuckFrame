#!/bin/bash
# CPU check of the production smoke's preparation predicate; no GPU or app launch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
python3 - "$ROOT" "$TEST_DIR/test.cpp" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
source = (root / 'Apps/Mac/Capture/SPLiveProcessor.mm').read_text()
smoke = source.split('+ (NSDictionary<NSString *, id> *)runLowLatencyPrescaleSmoke {', 1)[1]
predicate = 'p->_sessionReady' + smoke.split('prepared=p->_sessionReady', 1)[1].split(';', 1)[0]
floor_guard = '_lowLatency && !_nativeBudgetActive' + source.split('if (_lowLatency && !_nativeBudgetActive', 1)[1].split(')\n        wanted =', 1)[0]
test = r'''
#include <cassert>
#include <cstdio>
struct Plan { bool committed; };
struct Processor { bool _sessionReady; Plan _resolved; };
enum ViewMode { SPLiveViewEnhanced, SPLiveViewOriginal, SPLiveViewCompare };
bool useBufferFloor(bool _lowLatency, bool _nativeBudgetActive, ViewMode mode) {
    struct { ViewMode viewMode; } _request{mode};
    return ACTUAL_FLOOR_GUARD;
}
bool ready(int inferenceWidth, int inferenceHeight, bool session = true, bool committed = true) {
    Processor processor{session, {committed}};
    auto *p = &processor;
    return ACTUAL_PREDICATE;
}
int main() {
    assert(ready(1280, 720)); // macOS 26 or preparation fallback
    assert(ready(1920, 1080)); // larger device limit
    assert(!ready(0, 0));
    assert(!ready(1281, 720));
    assert(!ready(1280, 721));
    assert(!ready(2048, 1080));
    assert(!ready(1920, 1200));
    assert(!ready(1280, 720, false));
    assert(!ready(1280, 720, true, false));
    assert(useBufferFloor(true, false, SPLiveViewEnhanced));
    assert(!useBufferFloor(true, false, SPLiveViewCompare));
    assert(!useBufferFloor(true, false, SPLiveViewOriginal));
    assert(!useBufferFloor(true, true, SPLiveViewEnhanced));
    assert(!useBufferFloor(false, false, SPLiveViewEnhanced));
    puts("low-latency smoke preparation contract passed (CPU; output geometry still requires the GPU smoke)");
}
'''
pathlib.Path(sys.argv[2]).write_text(test.replace('ACTUAL_PREDICATE', predicate).replace('ACTUAL_FLOOR_GUARD', floor_guard))
PY
xcrun clang++ -std=c++17 "$TEST_DIR/test.cpp" -o "$TEST_DIR/test"
"$TEST_DIR/test"
