#!/bin/bash
# Exercises interleaving and stop-on-failure using fake CPU-only executables.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/App.app"
printf 'fake' > "$tmp/FrameBudget.metallib"
cat > "$tmp/probe-ok" <<'STUB'
#!/bin/bash
[[ "$CHUANFLOW_PROBE_WARMUP_SEC" == 10 && "$CHUANFLOW_PROBE_MEASURE_SEC" == 30 && "$CHUANFLOW_PROBE_WIDTH" == 1280 && "$CHUANFLOW_PROBE_HEIGHT" == 720 ]] || exit 9
[[ -z "${CHUANFLOW_RIFE_STREAM+x}" ]] || exit 10
if [[ "$CHUANFLOW_PROBE_RIFE_REQUEST" == 1 ]]; then flag=true; else flag=false; fi
printf '{"fake":true,"rifeCacheRequest":"%s","rifeCache":{"requested":%s,"effective":%s,"hits":2,"resets":1}}\n' "$CHUANFLOW_PROBE_RIFE_REQUEST" "$flag" "$flag"
STUB
cat > "$tmp/probe-fail" <<'STUB'
#!/bin/bash
if [[ "$3" == lowlatency ]]; then printf '{"failure":"preserved"}\n'; exit 7; fi
printf '{"fake":true}\n'
STUB
chmod +x "$tmp/probe-ok" "$tmp/probe-fail"
CHUANFLOW_PROBE_RIFE_REQUEST=1 CHUANFLOW_RIFE_STREAM=1 bash "$root/Scripts/probe_p2_capacity.sh" "$tmp/probe-ok" "$tmp/App.app" "$tmp/FrameBudget.metallib" 1280x720 "$tmp/ok"
[[ "$(find "$tmp/ok" -name '*.exit' | wc -l | tr -d ' ')" == 12 ]]
python3 - "$tmp/ok" <<'PYTEST'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);m=json.loads((p/'run-manifest.json').read_text()); assert m['rifeCacheRequest']=='off' and (m['warmupCap'],m['measureCap'])==(2400,7200)
assert all(json.loads(x.read_text())['rifeCacheRequest']=='0' for x in p.glob('[123]-*.json'))
assert len(m['runs'])==12 and all(x['actualRifeCache']['effective'] is False and x['actualRifeCache']['hits']==2 for x in m['runs'] if x['engine']=='rife')
PYTEST
bash "$root/Scripts/probe_p2_capacity.sh" "$tmp/probe-ok" "$tmp/App.app" "$tmp/FrameBudget.metallib" 1280x720 "$tmp/on" on
python3 - "$tmp/on" <<'PYTEST'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); m=json.loads((p/'run-manifest.json').read_text()); assert m['rifeCacheRequest']=='on'
assert len(m['runs'])==12 and all(x['actualRifeCache']['effective'] is True and x['actualRifeCache']['resets']==1 for x in m['runs'] if x['engine']=='rife')
assert all(json.loads(x.read_text())['rifeCacheRequest']=='1' for x in p.glob('[123]-*.json'))
PYTEST
if bash "$root/Scripts/probe_p2_capacity.sh" "$tmp/probe-ok" "$tmp/App.app" "$tmp/FrameBudget.metallib" 1280x720 "$tmp/invalid" maybe >/dev/null 2>&1; then exit 1; fi
[[ ! -e "$tmp/invalid" ]]
printf '%s\n' 1-frc-normal 1-lowlatency-normal 1-rife-fast 1-rife-balanced 2-lowlatency-normal 2-rife-fast 2-rife-balanced 2-frc-normal 3-rife-fast 3-rife-balanced 3-frc-normal 3-lowlatency-normal > "$tmp/expected-order"
cmp -s "$tmp/expected-order" "$tmp/ok/order.txt"
for i in 1 2 3; do [[ -f "$tmp/ok/$i-frc-normal.exit" && -f "$tmp/ok/$i-lowlatency-normal.exit" && -f "$tmp/ok/$i-rife-fast.exit" && -f "$tmp/ok/$i-rife-balanced.exit" ]]; done
if bash "$root/Scripts/probe_p2_capacity.sh" "$tmp/probe-fail" "$tmp/App.app" "$tmp/FrameBudget.metallib" 1280x720 "$tmp/failure" 2>"$tmp/error"; then exit 1; else status=$?; fi
[[ "$status" == 7 && "$(cat "$tmp/failure/1-lowlatency-normal.exit")" == 7 ]]
grep -q '"failure":"preserved"' "$tmp/failure/1-lowlatency-normal.json"
python3 - "$tmp/failure/run-manifest.json" <<'PYTEST'
import json,sys
m=json.load(open(sys.argv[1])); assert len(m['runs'])==2 and m['runs'][1]['exit']==7
PYTEST
[[ "$(find "$tmp/failure" -name '*.exit' | wc -l | tr -d ' ')" == 2 ]]
if bash "$root/Scripts/probe_p2_capacity.sh" "$tmp/probe-ok" "$tmp/App.app" "$tmp/FrameBudget.metallib" 1280x720 "$tmp/ok" >/dev/null 2>&1; then exit 1; fi
printf '%s\n' 'P2 wrapper interleaving and stop-on-first-failure pass; fake CPU executables only'
