#!/bin/bash
# Headless timing controls plus real RIFE, using the same production generator.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PRODUCTS="${ODF_TEST_FRAMEWORKS_DIR:-$ROOT/.build/Build/Products/Debug}"
export ODF_TEST_RESOURCE_APP="${ODF_TEST_RESOURCE_APP:-$PRODUCTS/OpenDuckFrame.app}"
export ODF_TEST_DEBUG_DYLIB="${ODF_TEST_DEBUG_DYLIB:-$ODF_TEST_RESOURCE_APP/Contents/MacOS/OpenDuckFrame.debug.dylib}"
OUT="${1:-$ROOT/.build/performance-simulation/results}"
FRAMES="${ODF_PERF_PROBE_FRAMES:-120}"
mkdir -p "$OUT"
xcrun swiftc "$ROOT/Apps/Mac/Capture/SPPerformanceSimulation.swift" "$ROOT/Modules/VideoEnhancement/Tests/SPPerformanceSimulationTests.swift" -o "$OUT/limiter-tests"
"$OUT/limiter-tests" > "$OUT/limiter.json"
xcrun clang++ -std=c++17 -fobjc-arc -Wno-deprecated-declarations -Wno-nullability-completeness \
  -I "$ROOT/Modules/VideoEnhancement" -I "$ROOT/Modules/MediaCore/Bridge" -I "$ROOT/Modules/MediaCore/Core" -I "$ROOT/Apps/Mac/Capture" \
  "$ROOT/Modules/VideoEnhancement/Tests/SPFilePerformanceProbe.mm" -F "$PRODUCTS" \
  -framework OpenDuckFrameMediaCore -framework Foundation -framework CoreVideo -framework CoreMedia -framework QuartzCore -framework Metal \
  -Wl,-rpath,"$PRODUCTS" -Wl,-rpath,"$ODF_TEST_RESOURCE_APP/Contents/Frameworks" -o "$OUT/file-probe"
for size in '1280 720' '1920 1080'; do
  read -r width height <<< "$size"
  "$ROOT/Scripts/with_performance_simulation.sh" off "$OUT/file-probe" off "$width" "$height" "$FRAMES" > "$OUT/${width}-original.json"
  for profile in off m1pro-16 m1pro-14; do
    "$ROOT/Scripts/with_performance_simulation.sh" "$profile" "$OUT/file-probe" rife "$width" "$height" "$FRAMES" > "$OUT/${width}-${profile}.json"
  done
done
for ms in 20 60 120; do
  ODF_PROBE_JOB_MS="$ms" "$OUT/file-probe" fake 1920 1080 "$FRAMES" > "$OUT/control-${ms}ms.json"
done
python3 - "$OUT" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
records = [json.loads(p.read_text()) for p in sorted(root.glob('*.json'))]
assert records and all(r['ok'] for r in records)
controls = {ms: json.loads((root / f'control-{ms}ms.json').read_text()) for ms in [20, 60, 120]}
for r in records:
    if 'originalEmissionFPS' not in r:
        continue
    assert r['originalEmissionFPS'] >= 23, ('original cadence must survive slow inference', r)
    assert r['emissionFPS'] >= 23, ('held copies cannot mask output below source cadence', r)
    assert r['maxPlayoutLagMs'] < 100, ('slow inference must not accumulate playback lag', r)
assert controls[20]['emissionFPS'] >= 42, 'fast inference must still enhance playback'
for r in records:
    print(json.dumps(r, ensure_ascii=False))
PY
