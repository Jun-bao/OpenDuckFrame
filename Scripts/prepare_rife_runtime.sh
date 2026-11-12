#!/bin/bash
# Prepare pinned, library-only RifeMetal sources. No compilation or GPU work.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/build_common.sh"

NAME=rife-metal
VERSION="$(sp_lock_get "$NAME" version)"
CANONICAL="$SP_THIRDPARTY/rife-metal"
PREFIX="$CANONICAL/runtime"
STAMP="$PREFIX/.build-stamp.json"
PATCH="$CANONICAL/stream-io.patch"
EXPERIMENT_PATCH="$CANONICAL/experiment-options.patch"
RUNTIME_PATCH="$CANONICAL/runtime-support.patch"
WEIGHT_PATH="Sources/RifeMetal/Resources/rife-v4.25.rmw"
ORIGINAL_WEIGHT_SHA="$(sp_lock_get "$NAME" weight_sha256)"
WEIGHT_SHA="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' "$CANONICAL/production-model.json")"

RECIPE_ARGS=(--dependency "$NAME" --input "$SP_ROOT/Scripts/prepare_rife_runtime.sh"
  --input "$SP_ROOT/Scripts/lib/build_common.sh" --input "$SP_ROOT/Scripts/lib/deps_lock.py"
  --input "$PATCH" --input "$EXPERIMENT_PATCH" --input "$RUNTIME_PATCH" --input "$CANONICAL/Package.swift"
  --input "$CANONICAL/PaddedFrameConvert.swift" --input "$CANONICAL/PaddedFrameConvert.metal"
  --input "$CANONICAL/RifeExperimentOptions.swift" --input "$CANONICAL/StudentGraphContract.swift"
  --input "$CANONICAL/LICENSE" --input "$CANONICAL/THIRD-PARTY.md"
  --input "$CANONICAL/production-model.json" --input "$SP_ROOT/Scripts/derive_fourstage_model.py"
  --tool python3 --tool "patch=/usr/bin/patch" --tool tar --parameter "mode=source-only-library")
RECIPE_HASH="$(sp_recipe_hash "${RECIPE_ARGS[@]}")"
REQUIRED_OUTPUTS=("$PREFIX/Package.swift" "$PREFIX/source-origin.json"
  "$PREFIX/LICENSE" "$PREFIX/THIRD-PARTY.md" "$PREFIX/$WEIGHT_PATH"
  "$PREFIX/Sources/RifeMetal/RifeStream.swift" "$PREFIX/Sources/RifeMetalCore/IFNetGraph.swift"
  "$PREFIX/Sources/RifeMetalCore/PaddedFrameConvert.swift"
  "$PREFIX/Sources/RifeMetalCore/RifeExperimentOptions.swift"
  "$PREFIX/Sources/RifeMetalCore/StudentGraphContract.swift"
  "$PREFIX/Sources/RifeMetalCore/FourStageGraphContract.swift"
  "$PREFIX/Sources/RifeMetalCore/AirServiceTrace.swift" "$PREFIX/Sources/RifeMetalCore/InferenceContext.swift"
  "$PREFIX/Sources/RifeMetal/RifeConfiguration.swift" "$PREFIX/Sources/RifeMetal/RifeInterpolator.swift"
  "$PREFIX/Sources/RifeMetalCore/WeightStore.swift" "$PREFIX/Sources/RifeMetalCore/WeightHeader.swift"
  "$PREFIX/Sources/RifeMetalCore/IFBlockBuilder.swift"
  "$PREFIX/Sources/RifeMetalCore/Shaders/PaddedFrameConvert.metal"
  "$PREFIX/Plugins/CompileMetalShaders/plugin.swift")

sp_recover_atomic_directory "$PREFIX" "$CANONICAL"
if sp_all_files_exist "${REQUIRED_OUTPUTS[@]}" && sp_stamp_matches "$STAMP" "$RECIPE_HASH" && \
   [ "$(sp_sha256 "$PREFIX/$WEIGHT_PATH")" = "$WEIGHT_SHA" ]; then
  echo "==> rife-metal $VERSION sources already match the current recipe"
  exit 0
fi

# Keep the source archive in the existing source-download cache.
ARCHIVE="$SP_ROOT/.build/rife-runtime-source-download/$(sp_lock_get "$NAME" archive)"
sp_verified_download "$(sp_lock_get "$NAME" url)" "$(sp_lock_get "$NAME" sha256)" "$ARCHIVE"
[ "$(sp_sha256 "$PATCH")" = "$(sp_lock_get "$NAME" patches 0 sha256)" ] || \
  sp_die "rife-metal IO patch does not match the dependency lock"
[ "$(sp_sha256 "$EXPERIMENT_PATCH")" = "$(sp_lock_get "$NAME" patches 1 sha256)" ] || \
  sp_die "rife-metal experiment patch does not match the dependency lock"
[ "$(sp_sha256 "$RUNTIME_PATCH")" = "$(sp_lock_get "$NAME" patches 2 sha256)" ] || \
  sp_die "rife-metal runtime support patch does not match the dependency lock"
WORK="$(mktemp -d "$CANONICAL/.prepare.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
sp_extract_archive "$ARCHIVE" "$WORK/src"
SOURCE="$WORK/src/$(sp_lock_get "$NAME" source_dir)"
[ -d "$SOURCE" ] || sp_die "rife-metal locked source directory is missing"
cmp "$SOURCE/LICENSE" "$CANONICAL/LICENSE" || sp_die "rife-metal license differs from the pinned source"
cmp "$SOURCE/THIRD-PARTY.md" "$CANONICAL/THIRD-PARTY.md" || sp_die "rife-metal model notice differs from the pinned source"

STAGED="$WORK/package"
mkdir -p "$STAGED/Sources" "$STAGED/Plugins"
cp -R "$SOURCE/Sources/RifeMetal" "$SOURCE/Sources/RifeMetalCore" "$STAGED/Sources/"
cp -R "$SOURCE/Plugins/CompileMetalShaders" "$STAGED/Plugins/"
cp "$SOURCE/LICENSE" "$SOURCE/THIRD-PARTY.md" "$STAGED/"
cp "$CANONICAL/Package.swift" "$STAGED/Package.swift"
/usr/bin/patch -t -N -p1 -d "$STAGED" < "$PATCH"
/usr/bin/patch -t -N -p1 -d "$STAGED" < "$EXPERIMENT_PATCH"
cp "$CANONICAL/PaddedFrameConvert.swift" "$STAGED/Sources/RifeMetalCore/"
cp "$CANONICAL/PaddedFrameConvert.metal" "$STAGED/Sources/RifeMetalCore/Shaders/"
cp "$CANONICAL/RifeExperimentOptions.swift" "$CANONICAL/StudentGraphContract.swift" "$STAGED/Sources/RifeMetalCore/"
# Apply after the canonical helpers so their locked runtime extensions survive.
/usr/bin/patch -t -N -p1 -d "$STAGED" < "$RUNTIME_PATCH"
[ "$(sp_sha256 "$STAGED/$WEIGHT_PATH")" = "$ORIGINAL_WEIGHT_SHA" ] || \
  sp_die "rife-metal bundled v4.25 weights do not match the pinned original"
python3 "$SP_ROOT/Scripts/derive_fourstage_model.py" --source "$STAGED/$WEIGHT_PATH" --output "$STAGED/$WEIGHT_PATH"

python3 - "$SP_DEPS_LOCK" "$CANONICAL" "$STAGED" "$RECIPE_HASH" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

lock_path, canonical, staged = map(Path, sys.argv[1:4])
dependency = json.loads(lock_path.read_text())["dependencies"]["rife-metal"]

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def artifact(path):
    return {"path": path, "sha256": sha(staged / path)}

origin = {
    "schema": 1,
    "upstream": {
        "repository": "https://github.com/cinemore/rife-metal",
        "commit": dependency["commit"],
        "version": dependency["version"],
        "archive_sha256": dependency["sha256"],
    },
    "recipe_sha256": sys.argv[4],
    "patches": [{"path": name, "sha256": sha(canonical / name)}
                for name in ("stream-io.patch", "experiment-options.patch", "runtime-support.patch")],
    "helpers": [artifact("Sources/RifeMetalCore/PaddedFrameConvert.swift"),
                artifact("Sources/RifeMetalCore/Shaders/PaddedFrameConvert.metal"),
                artifact("Sources/RifeMetalCore/RifeExperimentOptions.swift"),
                artifact("Sources/RifeMetalCore/StudentGraphContract.swift")],
    "patched_sources": [artifact("Sources/RifeMetalCore/IFNetGraph.swift"),
                        artifact("Sources/RifeMetal/RifeStream.swift"),
                        artifact("Sources/RifeMetal/RifeConfiguration.swift"),
                        artifact("Sources/RifeMetal/RifeInterpolator.swift"),
                        artifact("Sources/RifeMetalCore/InferenceContext.swift"),
                        artifact("Sources/RifeMetalCore/AirServiceTrace.swift"),
                        artifact("Sources/RifeMetalCore/FourStageGraphContract.swift"),
                        artifact("Sources/RifeMetalCore/IFBlockBuilder.swift"),
                        artifact("Sources/RifeMetalCore/WeightStore.swift"),
                        artifact("Sources/RifeMetalCore/WeightHeader.swift")],
    "experiment_options": {"defaults": {"gpu_io": True, "replace_mask": False},
                           "scope": "immutable per-interpolator options; model metadata unchanged",
                           "student_graphs": ["odf-ifnet425-acc-b3r32-b4r16-v1"]},
    "package_manifest": artifact("Package.swift"),
    "weights": artifact("Sources/RifeMetal/Resources/rife-v4.25.rmw"),
    "production_model": json.loads((canonical / "production-model.json").read_text()),
    "model_derivation": {"path": "Scripts/derive_fourstage_model.py", "sha256": sha(canonical.parents[1] / "Scripts/derive_fourstage_model.py")},
    "licenses": [artifact("LICENSE"), artifact("THIRD-PARTY.md")],
}
(staged / "source-origin.json").write_text(json.dumps(origin, indent=2, sort_keys=True) + "\n")
PY

sp_write_stamp "$STAGED/.build-stamp.json" "${RECIPE_ARGS[@]}"
sp_atomic_replace_directory "$STAGED" "$PREFIX" "$CANONICAL"
echo "==> Prepared rife-metal $VERSION library sources: $PREFIX (recipe ${RECIPE_HASH:0:12})"
