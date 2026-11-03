#!/bin/bash
# Explicitly launched headless capacity screen; never run implicitly.
set -euo pipefail
if [[ $# != 5 && $# != 6 ]]; then
  printf 'usage: %s RELEASE_COMPONENT APP FRAMEBUDGET_METALLIB WIDTHxHEIGHT NEW_OUTPUT_DIR [off|on]\n' "$0" >&2; exit 2
fi
probe="$1"; app="$2"; metallib="$3"; dims="$4"; out="$5"; cache_mode="${6:-off}"
case "$cache_mode" in off) cache_request=0 ;; on) cache_request=1 ;; *) echo 'cache must be off or on' >&2; exit 2 ;; esac
[[ "$probe" = /* && "$app" = /* && "$metallib" = /* && "$out" = /* && "$dims" =~ ^[1-9][0-9]{0,3}x[1-9][0-9]{0,3}$ ]] || exit 2
[[ -x "$probe" && -d "$app" && -f "$metallib" && ! -e "$out" ]] || { echo 'missing input or output already exists' >&2; exit 2; }
width="${dims%x*}"; height="${dims#*x}"
(( width >= 128 && width <= 3840 && height >= 128 && height <= 2160 && width % 2 == 0 && height % 2 == 0 )) || exit 2
mkdir "$out"
printf '{"rifeCacheRequest":"%s","rifeCacheActual":"per-case stdout rifeCache","width":%s,"height":%s,"warmupSeconds":10,"measureSeconds":30,"warmupCap":2400,"measureCap":7200,"pattern":"natural","pace":"unpaced","runs":[]}\n' "$cache_mode" "$width" "$height" > "$out/run-manifest.json"
shasum -a 256 "$probe" "$metallib" > "$out/resources.sha256"
# Three rotations ensure repeated candidates do not always run in the same order.
candidates=(frc:normal lowlatency:normal rife:fast rife:balanced)
for round in 0 1 2; do
  for offset in 0 1 2 3; do
    pair="${candidates[$(((round+offset)%4))]}"; engine="${pair%:*}"; quality="${pair#*:}"
    prefix="$out/$((round+1))-$engine-$quality"
    printf '%s\n' "$((round+1))-$engine-$quality" >> "$out/order.txt"
    cmd=(env -i PATH=/usr/bin:/bin CHUANFLOW_PROBE_WIDTH="$width" CHUANFLOW_PROBE_HEIGHT="$height" CHUANFLOW_PROBE_MULTIPLIER=2 CHUANFLOW_PROBE_WARMUP_SEC=10 CHUANFLOW_PROBE_MEASURE_SEC=30 CHUANFLOW_FRC_MODE=random1 CHUANFLOW_FRC_CONTINUOUS=0 CHUANFLOW_PROBE_RIFE_REQUEST="$cache_request" CHUANFLOW_FRAMEBUDGET_METALLIB="$metallib" "$probe" - "$app" "$engine" "$quality" natural unpaced "$prefix")
    printf '%q ' "${cmd[@]}" > "$prefix.command"; printf '\n' >> "$prefix.command"
    set +e; "${cmd[@]}" > "$prefix.json" 2> "$prefix.stderr"; status=$?; set -e
    printf '%s\n' "$status" > "$prefix.exit"
    python3 - "$out/run-manifest.json" "$prefix.json" "$engine" "$quality" "$status" <<'PYMANIFEST'
import json,pathlib,sys
manifest_path, result_path = map(pathlib.Path, sys.argv[1:3])
manifest=json.loads(manifest_path.read_text())
try:
 result=json.loads(result_path.read_text())
except (OSError, ValueError):
 result={}
cache=result.get('rifeCache') if sys.argv[3]=='rife' else None
manifest['runs'].append({'engine':sys.argv[3], 'quality':sys.argv[4], 'exit':int(sys.argv[5]),
 'validRun':result.get('validRun'), 'actualRifeCache':cache, 'failureStage':result.get('failureStage'),
 'modelIdentifier':result.get('modelIdentifier'), 'modelSHA256':result.get('modelSHA256'),
 'processingSize':result.get('processingSize'), 'warmupWallMs':result.get('warmupWallMs'),
 'measuredWallMs':result.get('measuredWallMs'), 'warmupLimitHit':result.get('warmupLimitHit'),
 'measureLimitHit':result.get('measureLimitHit')})
manifest_path.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
PYMANIFEST
    if [[ "$status" -ne 0 ]]; then echo "stopped at $prefix (exit $status)" >&2; exit "$status"; fi
  done
done
