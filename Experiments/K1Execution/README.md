# Product-runtime execution and IO experiments

This directory contains the 2026-11-06–07 diagnostics for the actual RifeMetal
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

### Complete K1 cost (offscreen)

The prespecified experimental primary in `io-fast-cost/analysis.json` is continuous
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

For the main product X2 path, the relevant measured IO improvement is
**29.5068%** for the single-`0.5` provided-output call. **38.7322%** is the
equally weighted three-phase experimental result. Neither percentage is a
live FPS improvement or evidence of 120 FPS delivery.

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

## Frozen live evidence: full playback acceptance failed

R8 and R9 used a **960×572** source. R9 was an isolated opaque-viewer
experiment: its independently counted actual presentations were **3,860 in
38.000593 s = 101.577/s**, with source content at **59.9988/s**. This is a
different input geometry and cannot be used as a same-input comparison with
R10.

R10 used the production viewer opacity behavior, effective without the
`r7Opaque` diagnostic flag. Capture, processing, and presented output were
all verified at **1920×1080**, with **X2 / RIFE 4.25 Fast**. Its reported
35-second window had source content at **60.013/s**, capture at **59.943/s**,
and **2,195 independently counted actual presentations = 62.715/s**.

The separate linked ready-frame cohort accounts for all **4,197** frames:

| Ready-frame disposition | Count |
| --- | ---: |
| Visible presentations | 2,194 |
| `zeroTime` | 1,064 |
| Superseded | 939 |
| Total ready | 4,197 |

The independent actual count and the linked ready-frame cohort are reported
separately; do not substitute 2,195 for the cohort's 2,194 visible frames.
All model-generated outputs were ready before their targets, but readiness did not
establish visible or timely delivery. Under the unchanged original logical
target +2 ms definition, only **249 of 1,126 visible synthetic frames** were
on time; using all **2,099 ready synthetic frames** as the denominator leaves
the same numerator, **249/2,099**. The **four early source frames** under the
original source-target definition remain recorded failures. R10 does not
pass the original on-time or 120 FPS delivery criteria.

The separate 1920×1080 fixed-120 cohort (`generation=2`, `config=6`,
`measurementEpoch=6`) runs for 35.0007 seconds with source content 59.970 Hz
and accepted capture 59.799/s. It has 2,322 positive actual presentations
(66.342/s); the existing held/reuse-filtered physical counter has 2,215
(63.284/s). The 107-source-callback difference remains an accounting gap:
only 62 duplicate fixture IDs were observed, and the per-frame timeline does
not expose the complete held/filter state. Neither rate passes 120 FPS.

Its 6,125 candidate frame IDs include 1,926 source fallbacks replaced by
synthetics with identical PTS and logical target. The resulting 4,199 unique
output targets account for 2,322 visible, 1,386 zero-time, 489 superseded,
and two queue-full outcomes. These fallbacks are not 1,926 extra failed
targets. All 1,674 completed model jobs meet their job deadlines, while 180
pending-expiry events and three queue drops remain recorded separately;
job readiness does not prove every phase reached early preparation. The
unchanged logical +2 ms and not-early synthetic numerator is 481/1,160
visible synthetics. No early actual callbacks occur in this window.

A single-variable follow-up advances selection guard from 1 to 2 ms without
moving logical targets or increasing latency. It increases the scheduled
registration margin but reduces actual delivery to 2,004/35.0001 seconds
(57.257/s). Its 4,156 ready frames account for 2,004 visible, 1,566 zero-time,
580 superseded, and six queue-full outcomes. Source content remains 59.984 Hz,
with accepted capture 59.371/s. This separate-window comparison does not
establish an isolated causal percentage, but it provides no adoption benefit;
production retains the 1 ms guard. Its failed log is retained; no further
guard increase is adopted.

The production presenter uses the display-link path and a strict one-shot
timer with **50 µs leeway**. Slot tokens and generation/configuration/
measurement/clock context guards reject stale consumption or rearming of a
replacement slot. Offscreen first-draw warm-up primes resources; it is not
physical-presentation evidence. The standalone viewer is opaque in
production, while follow/interactive modes retain their existing opacity
rules.

Separate validation entry points are:

- [CPU display-queue tests](../../Modules/VideoEnhancement/Tests/SPLiveDisplayQueueTests.cpp):
  standalone CPU-only assertions for PTS ordering, original frozen targets,
  slot eligibility, token replacement, and context retirement.
- [Renderer/resource-lifetime probe](../../Modules/VideoEnhancement/Tests/SPLivePresenterResourceTests.mm):
  a standalone probe taking the built candidate library as its one argument;
  it invokes `runOffscreenDrawAndLifetimeProbe` and preserves the public
  presentation-selector check. Its offscreen draw/lifetime result does not
  close the live presentation gate.

Keep these validation results and the frozen live logs separate from native
hash parity and offscreen cost. Full real-playback acceptance remains failed.

### Controls after R10

R12b removes interpolation and scaling and captures a 1920×1080 source whose
content advances at 119.769 Hz. Capture completion is only 64.171/s, accepted
ready output 63.857/s, and actual presentation 60.828/s. Of 2,235 ready frames,
2,129 are visible, 94 have zero actual time and 12 are superseded. This exposes
a source-to-capture supply gap without model work. Its passthrough path has
zero playout delay, so it is not a same-delay model-speed comparison with R10.
The precise capture/compositor cause remains unresolved.

R13 drives the actual built presenter directly with immutable 1920×1080
buffers, fixed 120 Hz IDs/PTS, a 40 ms logical delay and admission 20 ms before
each target. On a verified physical 120 Hz display it delivers 4,793/40 s =
119.825/s; three zero-time and four superseded frames close the 4,800-frame
cohort. No capture or model runs. This proves conditional presenter capacity,
not complete product performance. The old target +2 ms/not-early numerator
is still 0/4,800, with one early frame retained.

R14 suppresses the workbench preview only while the opaque output viewer
fully covers it. Preview drawing stops as intended, but actual delivery is
2,017/35 s = 57.629/s. The 4,166 ready frames close to 2,017 visible, 1,421
zero-time, 720 superseded and eight queue-full outcomes. The experiment is
reverted; it provides no adoption benefit or proof of a second-view cause.

A later presenter-plus-capture control (R15) stops at source-geometry setup,
before starting its producer or capture stream. At that point the system has
changed from a 2560×1440/120 Hz display to a 1920×1080/60 Hz display. This is
an environment blocker for a new comparable 120 FPS run, not an explanation
for earlier failures. No performance result is assigned to that setup failure.

R17 repeats the unchanged R13 probe binary and old renderer in the current
60 Hz environment, without capture, inference or the new clock. Its immutable
1920×1080 buffers and 120/s supply remain unchanged: 4,800 admitted IDs resolve
to 2,400 zero-time callbacks and 2,400 superseded IDs, with no positive actual
time. The panel/layer report opaque, visible and exposed. Thus the new clock
is not necessary to reproduce the current zero-time observation; an exclusive
environment cause is still unproven. This is neither a 60/s-supply test nor a
physical 120 Hz acceptance result. Zero actual time alone does not establish
that the screen was black.

## Frozen-target mathematics and opt-in time contract

The CPU audit preserves every R10 frame ID, outcome, context and target. Under
the conditional assumptions of media-order delivery, at least 1/120 s between
distinct physical deliveries, and each old closed target-to-target+2 ms
window, exact dynamic programming can match at most **3,582/4,197** targets.
At least **615** omissions are therefore unavoidable under those assumptions.
The stronger constant-period/constant-phase result is conditional as well;
neither bound explains all observed zero-time or late outcomes. The +2 ms
window is a retained diagnostic, not a newly established user requirement.

For 2,099 paired outputs, the old synthetic target differs by up to ±1.5 ms
from interpolation between its two source targets. The recorded model alpha
is absent; the audit derives `alpha_time` from exact media PTS and does not
invent a model input. With the observed nominal 16.667 ms SDK prediction lead
and 1 ms guard, 587 synthetic frames lack enough renderer-admission lead for
that narrow window. This conditional count overlaps other failures and must
not be added to the 615 bound. Being model-ready before the logical target
alone does not establish readiness before the required submission cutoff.

Reproduce the audit against an externally supplied frozen cohort export:

```sh
"$PYTHON" -B Experiments/K1Execution/analyze_frozen_timeline.py \
  --input "$FROZEN_COHORT_PLAN" --output "$NEW_OUTPUT_ROOT/frozen-timeline"
"$PYTHON" -B -m unittest discover -s Experiments/K1Execution/tests \
  -p test_frozen_timeline.py
```

The tool requires NumPy, records input/tool hashes and exact rational
parameters, and rejects an existing output directory. Its CPU tests use
independent exhaustive scheduling oracles. SDK timestamps remain predictions,
not physical actual times; observed actual outcomes are reported separately.

The candidate flag `--odf-rife-pair-affine-clock` freezes each accepted source
endpoint before its scheduler emits phases. For a valid same-context pair,
it selects `round(T_A + alpha_time * (T_B - T_A))` once and carries that frozen
snapshot through admission, deferred retries, model completion and enqueue.
The preceding B endpoint is reused as the next A. Missing, unordered or stale
endpoints retain the legacy fallback; stale work is retired rather than
rebound. RIFE timesteps, pixels, weights, selection guard and latency cap are
unchanged.

This is a **default-off diagnostic candidate**, restricted to RIFE multiplier
mode and the existing R8 diagnostics gate. Enable it only with
`--odf-r8-quality-diagnostics --odf-pixel-diagnostics` plus absolute isolated
`--odf-isolated-profile` and `--odf-live-log` paths. Fixed-FPS, hold and other
engine paths retain their previous behavior. `pairAffineSourceFrozen`,
`pairAffinePlan`, `pairAffineSourceEnqueue` and job `pairAffineTargets` retain
both selected and legacy candidate targets, endpoint context, frozen delay,
and exact PTS fraction. The new mapping changes the target definition; it
must not be presented as passing the unchanged old target metric.

Validation includes Debug and optimized
[CPU clock contracts](../../Modules/VideoEnhancement/Tests/SPRifePairAffineClockTests.cpp),
and the built-product `source-clock` headless test with the flag off, with its
gate absent, and with the complete opt-in gate. The latter exercises accepted
sources, the scheduler/event handler and completion/enqueue using simulated
model outputs. Seven related repair/geometry/fixed-rate/PTS cases and the
actual offscreen renderer/resource-lifetime probe pass. These checks establish
the implementation contract, not a real-capture FPS gain. Release and separate
Debug candidates build and bundle successfully; the R13-bound Debug binary is
kept unchanged. A comparable physical 120 Hz run of this candidate is still
pending, and full product acceptance remains open.

R16 additionally exercises actual ScreenCaptureKit capture and RIFE in a
960×572 own-window cohort, with isolated capture cap30, X2 and the opt-in clock
on the current 60 Hz display. All 1,514 observed job plans have bound matching
contexts and exact PTS fractions; affine error is zero or half a host tick.
All 1,513 consecutive B-to-A endpoint reuses match, and all 1,514 observed
submit/completion/enqueue targets remain identical. Actual presentation does
not pass: 3,029 ready frames include 1,543 zero-time, 1,479 superseded, four
invisible and three unlocated terminal outcomes, with no positive actual
times. The three early collection gaps are retained; they are not assigned
to stopping. A later source-selection configuration failure is excluded from
own-window and quality conclusions. This validates the observed real-model
time-contract chain, not visible throughput, image quality or 120 FPS.
