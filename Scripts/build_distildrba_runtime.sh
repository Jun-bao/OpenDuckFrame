#!/bin/bash
# Build in an isolated directory using a previously prepared conversion venv.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SOURCE="${1:?Pass the pinned DistilDRBA source checkout}"
PYTHON="${2:?Pass the Python interpreter with torch and coremltools}"
OUT="${3:?Pass a new output directory}"
[ ! -e "$OUT" ] || { echo 'Output already exists' >&2; exit 1; }
mkdir -p "$OUT"
"$PYTHON" "$ROOT/Scripts/build_distildrba_model.py" --source "$SOURCE" --output "$OUT/DistilDRBA_720p.mlpackage" | tee "$OUT/conversion.json"
xcrun coremlcompiler compile "$OUT/DistilDRBA_720p.mlpackage" "$OUT"
python3 - "$OUT" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1]); model = root / 'DistilDRBA_720p.mlmodelc'
files = [p for p in model.rglob('*') if p.is_file()]
if not files or any(p.is_symlink() for p in model.rglob('*')): raise SystemExit('compiled model missing or contains symlinks')
(root / 'SHA256.json').write_text(json.dumps({str(p.relative_to(model)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files)}, indent=2) + '\n')
PY
