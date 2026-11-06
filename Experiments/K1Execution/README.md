# Product-runtime execution and IO experiments

This directory contains the 2026-11-06 diagnostics for the actual RifeMetal
product runtime. The adopted change is stream IO: GPU input edge padding and
directly cropped GPU output. The original model, weights, accumulated-mask
update, internal padded geometry, downsample sampler, cache rotation, and
requested timesteps are retained. No training was performed.

The upstream baseline is `cinemore/rife-metal` v0.1.8 at
`ac6408022eb6bc1a53181f5b2716a9f5ded507c2`, using the original RIFE v4.25
weights and `mask_update=accumulate`. This is the product implementation,
not the lab's P02 mask-replacement graph. The original model SHA-256 is
`ef29a643a76a9202600458a23dddce16919337ef01743d0fbe817684ec990f74`.

Production source preparation and ownership are documented in
[ThirdParty/rife-metal](../../ThirdParty/rife-metal/README.md).
`ThirdParty/rife-metal/PaddedFrameConvert.swift` and `.metal` are the canonical
padding helpers. The prepared production package is
`ThirdParty/rife-metal/runtime`; experimental graph options and training tools
are not included in that package.

## Recorded decision and evidence

Evidence directory names below are relative to a separately supplied local
`EVIDENCE_ROOT`. Raw BGRA inputs, local manifests, generated packages, logs,
and model variants remain outside Git.

| Candidate | Result | Decision / evidence |
| --- | --- | --- |
| Fused non-final stage warp | Numerically exact in the retained checks; complete K1 cost screen failed | Not adopted; `fast-parity`, `fast-cost` |
| Final-stage feature-tail trimming | Exact output parity; complete K1 cost screen failed | Not adopted; `tail-fast-parity`, `tail-and-width-cost` |
| C24 / C16 final trunk | Initial untrained variants failed the three-phase cost screen against the trimmed control | Not trained or adopted; `tail-and-width-cost` |
| GPU padding alone (`pad`) | Exact output parity; continuous three-phase cost screen failed | Diagnostic control, not an independently accepted speed claim |
| Direct GPU crop (`crop`) | Exact output parity; cost screen passed | IO control |
| GPU padding + direct GPU crop (`io`) | Exact output parity and complete K1 cost screen passed | Adopted IO implementation; `io-fast-parity`, `io-fast-cost` |

The failed screens are retained. A smaller operation count, a correct shader,
or one favorable phase was not used to override a failed complete-call screen.
`narrow.py` and `narrow_train.py` remain research tools. The trainer requires a
passing native cost report bound to the exact graph and initial-weight hash,
explicit finite step/time budgets, and the shared GPU lock. These gates did
not pass for C16/C24, so training was not started. No trained checkpoint or
experimental fusion/tail/narrow graph enters production.

### Complete K1 cost

The primary comparison in `io-fast-cost/analysis.json` is continuous
`d0 - io`, with equal clip and phase weight. It contains 20 whole temporal
blocks: five development clips, four passes. Each block contains all three
fixed phases (`0.25`, `0.5`, `0.75`), continuous and 30 Hz cadences, and
randomized arm order. The fixed schedule seed is `20261106`. Each arm warms
for 32 calls without pacing, then measures 24 calls. There are 1,440 measured
continuous calls per variant: `20 × 3 × 24`.

The measured scope is the synchronous call with one new encoder Head and the
complete K1 query, including its stream IO. The previous Head is cached.
Inputs alternate the same frozen endpoint pair; these are not natural,
sustained playback sequences or independent acceptance sessions.

| Scope | Original d0 mean | IO mean | Mean reduction |
| --- | ---: | ---: | ---: |
| Primary: continuous, three phases equally weighted | 5.045454762 ms | 3.091239249 ms | 38.7322% |
| Continuous `0.25`, returning API | 5.539885879 ms | 3.387919835 ms | 38.8450% |
| Continuous `0.5`, provided-output API | 4.142145246 ms | 2.919931875 ms | 29.5068% |
| Continuous `0.75`, returning API | 5.454333160 ms | 2.965866037 ms | 45.6237% |
| Diagnostic: 30 Hz, three phases equally weighted | 7.097827225 ms | 4.904987703 ms | 30.8945% |

The primary saved time is `1.9542155125 ms`. Its approximate 95% whole-block
bootstrap interval is `[1.6884431024305555, 2.2363153223784717] ms`; the
length-three moving-block interval is
`[1.6844732248784724, 2.2174756352604166] ms`. Both interval lower bounds are
positive for every primary phase. Adjacent blocks remain dependent; these
are short-window, conditional intervals, not a population or product-deadline
guarantee. The 30 Hz run is diagnostic and does not replace the continuous
primary comparison.

### Exact-output checks

- `io-fast-parity/analysis.json`: 240 output rows and 180 exact pairs against
  d0, comprising 60 pairs each for `crop`, `pad`, and `io` across five cases
  and all K=1…4 target sets. The 180 pairs are not 180 independent images.
- `production-probe/quality.json`: the actual local production package with
  its bundled original weights matches frozen d0 in all 72 outputs: 60 normal
  IOSurface outputs plus the first case's 12 outputs with verified absent
  input IOSurfaces. Its single-`0.5` provided output also has no IOSurface,
  exercising the retained CPU padding/crop fallback conditions. All outputs
  are 1920×1080 BGRA. `provenance.json` records the source/package, binary,
  inputs, config, baseline, and weights hashes; the production sources were
  unchanged before and after build/run, and bundled weights matched d0.
- GPU padding unit check: 1,376,256 fp16 RGB values are bitwise equal to CPU
  edge replication followed by the original `rifeBGRAToRGB` kernel. The five
  cases cover 1×1, odd sizes, already padded sizes, random BGRA8, distinct
  B/G/R values, and right/bottom edge extrema.
- `io-balanced-parity`, `io-hq-parity`, and `io-426-fast-parity` each add
  60 exact d0/IO pairs using the same five cases and K=1…4 queries. These are
  equivalent-execution regression checks for 4.25 Balanced/HQ and the
  separately bundled 4.26 Fast model, not speed or independent quality claims.

All frame hashes process exactly `width × 4` active bytes per row and exclude
row padding. Single `[0.5]` uses `RifeStream.push(_:into:)`; other target sets
use `RifeStream.push(_:timesteps:)`. Every trial first resets the stream and
caches the first frame with `push(first, timesteps: [])`. Repeated hashes for
the same phase in different K sets are retained as separate API/query checks,
not counted as independent statistical samples.

## Reproduce the experimental comparison

Run commands from the repository root. Replace every placeholder with an
authorized local path. `PINNED_RIFE_SOURCE` must be the pristine upstream
source named above, not the already patched production runtime. The input
manifest is external JSON with a `cases` array containing the same five
`id`, `first`, and `second` entries used by the frozen run. Preserve their
input hashes. Use a new results directory; do not overwrite archived failures.

```sh
export PYTHON="<Python executable with NumPy available>"
export DEVELOPER_DIR="<Xcode.app>/Contents/Developer"
export PINNED_RIFE_SOURCE="<pristine pinned upstream source>"
export INPUT_MANIFEST="<local frozen BGRA input manifest>"
export EVIDENCE_ROOT="<local frozen k1-product-runtime-20261106 directory>"
export NEW_OUTPUT_ROOT="<new external results directory>"
export GPU_LOCK="<shared GPU measurement lock file>"
export WORK_DIR=".build/k1-execution-repro"
export ORIGINAL_WEIGHTS="$PINNED_RIFE_SOURCE/Sources/RifeMetal/Resources/rife-v4.25.rmw"

"$PYTHON" Experiments/K1Execution/prepare_product_native.py \
  --source "$PINNED_RIFE_SOURCE" --output "$WORK_DIR"
xcrun swift build --package-path "$WORK_DIR" \
  --scratch-path "$WORK_DIR/.build" -c release --jobs 4
export NATIVE_BIN="$(xcrun swift build --package-path "$WORK_DIR" \
  --scratch-path "$WORK_DIR/.build" -c release --show-bin-path)/k1-runtime"
```

The preparer copies sources into the new work directory; it does not edit the
upstream checkout. It verifies expected source anchors and records
`source-origin.json`. Keep this diagnostic executable separate from the
production package.

Create the local IO variant manifest with the original model in every arm:

```sh
"$PYTHON" - <<'PY'
import json, os
from pathlib import Path
out = Path(os.environ["NEW_OUTPUT_ROOT"])
out.mkdir(parents=True, exist_ok=False)
model = str(Path(os.environ["ORIGINAL_WEIGHTS"]).resolve())
variants = [dict(id=name, model=model, defer_commits=False,
                 fused_warp=False, trim_final_features=False,
                 direct_crop=crop, gpu_input_padding=pad)
            for name, crop, pad in [("d0", False, False), ("crop", True, False),
                                     ("pad", False, True), ("io", True, True)]]
(out / "io-variants.json").write_text(json.dumps({"variants": variants}, indent=2) + "\n")
PY

"$PYTHON" Experiments/K1Execution/run_runtime.py \
  --native-bin "$NATIVE_BIN" --native-source "$WORK_DIR" \
  --model "$ORIGINAL_WEIGHTS" --inputs "$INPUT_MANIFEST" \
  --variants-file "$NEW_OUTPUT_ROOT/io-variants.json" \
  --primary io --baseline d0 --tier fast --mode quality \
  --gpu-lock "$GPU_LOCK" --output "$NEW_OUTPUT_ROOT/io-fast-parity"
```

Require `all_outputs_byte_equal=true`, `n_pairs=180`, and the expected API
metadata before running cost. A successful `run_runtime.py` process exit does
not enforce these acceptance flags; inspect `analysis.json` explicitly.

```sh
"$PYTHON" Experiments/K1Execution/run_runtime.py \
  --native-bin "$NATIVE_BIN" --native-source "$WORK_DIR" \
  --model "$ORIGINAL_WEIGHTS" --inputs "$INPUT_MANIFEST" \
  --variants-file "$NEW_OUTPUT_ROOT/io-variants.json" \
  --primary io --baseline d0 --tier fast --mode cost \
  --passes 4 --warmup-per-arm 32 --frames-per-arm 24 \
  --gpu-lock "$GPU_LOCK" --output "$NEW_OUTPUT_ROOT/io-fast-cost"
```

Require `cost_screen_passed=true` and `all_arm_last_outputs_equal=true` in the
new cost `analysis.json`, and inspect the per-phase whole/moving-block
intervals. The cost output hashes cover the final output of each matching
direction/cache-state arm; they do not replace the separate all-target parity
run. `prereg.json`, `config.json`, `execution.log`, and raw reports preserve
the fixed schedule, source/input/model hashes, and unsuccessful results.
Use `--mode profile` only as a separate diagnostic run, not as cost evidence.

## Reproduce the production-package and padding checks

Prepare the production runtime through its own entry point, then link it
directly through a temporary SPM path dependency. The probe has one production
model and compares with frozen d0 hashes; it does not create a second copy of
the candidate and call that copy a baseline.

```sh
Scripts/prepare_rife_runtime.sh
"$PYTHON" Experiments/K1Execution/tests/run_production_runtime_probe.py \
  --package ThirdParty/rife-metal/runtime \
  --config "$EVIDENCE_ROOT/io-fast-parity/config.json" \
  --baseline "$EVIDENCE_ROOT/io-fast-parity/quality.json" \
  --build-dir .build/production-runtime-probe-repro \
  --output-dir "$NEW_OUTPUT_ROOT/production-probe" --gpu-lock "$GPU_LOCK"

"$PYTHON" Experiments/K1Execution/tests/run_padded_frame_bitwise.py \
  --product-metal "$PINNED_RIFE_SOURCE/Sources/RifeMetalCore/Shaders/BackwardWarp.metal" \
  --padded-metal ThirdParty/rife-metal/PaddedFrameConvert.metal \
  --padded-swift ThirdParty/rife-metal/PaddedFrameConvert.swift \
  --build-dir .build/padded-frame-convert-repro --gpu-lock "$GPU_LOCK"
```

The production probe builds with four jobs, uses the package's bundled
weights, and records actual CV pixel format, dimensions, IOSurface state,
entrypoint, and active-row SHA-256. Require `complete=true`, 72 rows,
`mismatch_count=0`, `runtime_returncode=0`, `package_unchanged=true`, and
`bundled_model_matches_original=true` across its quality/provenance reports.
Both runners support `--compile-only` without GPU work and use a non-blocking
shared GPU lock when executing. The production result directory must be new.
Do not run other GPU workloads during a comparison.

Frozen configs contain local input/model bindings. For another machine,
create an external path-binding copy and retain the exact case IDs, input
hashes, phases, target sets, flags, and schedule; preserve the archived files.
No local absolute paths or raw inputs belong in this repository.

## Live acceptance remains separate

These measurements establish the stated runtime IO cost and hash results in
their recorded scope. At this documentation stage, real capture/presentation
acceptance still has a late-frame issue under investigation. This README does
not declare live presentation deadlines, sustained playback, or the complete
application accepted. Retain live logs and failures separately from these
offscreen runtime results.
