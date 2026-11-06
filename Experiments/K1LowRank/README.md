# K=1 low-rank native experiment

Implements the first cost-screening stages of the 4.25 beta-folded proposal.
It is an isolated research harness. It does not change the application loader,
quality preset, target timeline, frame budget, or bundled model.

The two explicit RMW2 identities are:

- `odf-ifnet425-b3r32-b4r16-betafold-v1`: the untrained half-rank candidate.
- `odf-ifnet425-b3r64-b4r32-betafold-diag-v1`: full-rank numerical diagnostics.

Only block3/4's eight residual branches change. Each branch is a bias-free
3×3 down projection, a 1×1 up projection with folded bias, the original skip,
and LeakyReLU(0.2). There is no intermediate activation or second beta scale.
The graph binds replacement-mask semantics explicitly; the ordinary product's
accumulated-mask baseline is recorded separately.

`lowrank.py` uses the existing ODF-VFI lab's strict v1 RMW reader and reference
network. It performs SVD in CPU float64 and emits FP16 RMW2, a safe tensor
checkpoint and a sidecar manifest. The manifest binds the source SHA, exported
SHA, graph, ranks, fold/mask policy and per-layer spectra. Unchanged original
weights are required as input; weights are never stored in this source tree.

`prepare_native.py` creates an editable native variant from an existing pinned
lab source snapshot, recording every source hash. It patches only the new
destination, preserves existing wide-graph support, and adds a complete fixed
schema and construction branch for the two low-rank IDs. Unknown graphs,
shapes, missing weights, unexpected mask policies and malformed payloads fail
loading. The prepared package has no network package dependencies.

The copied runtime and reference retain their upstream Apache-2.0/MIT terms;
use the lab's `THIRD-PARTY.md`, `SOURCE-ORIGIN.json` and original license files
for attribution. No runtime sources or model bytes are vendored here.

## Run

Use the existing Python environment with NumPy and PyTorch, and Xcode with
the Metal compiler. Set these variables to the real local directories:

```sh
# ODF-VFI lab, original lab-native snapshot, current product build worktree,
# its actually resolved native checkout, and a new experiment output directory.
LAB_ROOT=/path/to/vfi-lite
LAB_NATIVE=/path/to/rife-metal-p02
PRODUCT_ROOT=/path/to/current-product-worktree
PRODUCT_NATIVE=/path/to/resolved/rife-metal
RESULT_ROOT=/path/to/new-k1-results
NATIVE_ROOT=.build/k1-native
BUILD_ROOT=.build/k1-native-build
MODEL_425="$LAB_NATIVE/Sources/RifeMetal/Resources/rife-v4.25.rmw"
GPU_LOCK=/path/to/existing-project-gpu-measurement.lock

python3 -B Experiments/K1LowRank/test_lowrank.py \
  --lab-root "$LAB_ROOT" --source "$MODEL_425" -v
python3 -B Experiments/K1LowRank/lowrank.py \
  --lab-root "$LAB_ROOT" --source "$MODEL_425" --output "$RESULT_ROOT/models"
python3 -B Experiments/K1LowRank/audit_ledger.py \
  --lab-root "$LAB_ROOT" --source "$MODEL_425" \
  --candidate-checkpoint "$RESULT_ROOT/models/odf-ifnet425-b3r32-b4r16-betafold-v1.pt" \
  --output "$RESULT_ROOT/actual-module-ledger.json"
python3 -B Experiments/K1LowRank/prepare_native.py \
  --source "$LAB_NATIVE" --output "$NATIVE_ROOT"
swift build --package-path "$NATIVE_ROOT" --scratch-path "$BUILD_ROOT" \
  --disable-index-store --jobs 4 -c release --product k1-bench
python3 -u -B Experiments/K1LowRank/run_bench.py \
  --lab-root "$LAB_ROOT" --lab-native "$LAB_NATIVE" \
  --product-worktree "$PRODUCT_ROOT" --product-native "$PRODUCT_NATIVE" \
  --native-bin "$BUILD_ROOT/release/k1-bench" --output "$RESULT_ROOT" \
  --gpu-lock "$GPU_LOCK" --rounds 40
```

If the active command-line tools do not contain `metal`, select the installed
Xcode for this build through `DEVELOPER_DIR`; no global toolchain change is
needed. The native destination and the measurement preregistration refuse an
existing run, so a failed result is not silently replaced by a new attempt.

## Measurements and adoption boundary

The native reader is tested against five malformed real-weight containers.
The microbench uses actual C64×40×64 and C32×80×128 grids, for one and eight
layers. The complete test uses 1920×1080 Fast, padded to 2048×1280, at three
K=1 phases. Models alternate execution order; each timed call contains the
new frame's Head, a complete query and synchronized one-frame delivery. The
previous frame's Head is cached outside that interval. Loading, compilation
and initial encoding have separate cold timings.

The primary time is `DispatchTime.uptimeNanoseconds` around a synchronous
completed call. The optional Metal value is explicitly the **last command
buffer** interval; MPS can split work and this value is not full GPU time.
Simulation and activation dumps are disabled. Current allocated Metal bytes
are allocation samples, not a measured peak.

`phase2-prereg.json` is written before running benchmarks. The speed screen
requires a positive lower bound on paired-bootstrap mean savings at every
tested phase. It is a local cost screen, not a product deadline or displayed
FPS guarantee. Native FP16/CPU FP32 layer diagnostics are reported separately
from approximation error and the analytic scene's real rendered targets.

The single analytic scene is a mechanism probe, not an independent real-video
acceptance set. No allowed quality loss is invented. Even a positive speed
screen does not authorize adoption: independent video quality, training when
justified, K=2..4, state reuse and actual product presentation remain separate.
If complete K=1 savings are not demonstrated, keep the recorded failure and
investigate execution overhead before spending on large training runs.

## Execution diagnostics and randomized comparisons

The continuation adds three tools, all confined to the generated experimental
package. The app and its dependency checkout remain separate.

- `K1ProfileBuffer` observes underlying buffers across `commitAndContinue` and
  records host encoding checkpoints. It does not add commits or waits. Only
  `profile` mode enables it. Observed buffer intervals are residency envelopes;
  their union is not active shader time, and the collector does not establish
  exhaustive coverage of work outside the supplied wrapper.
- The `defer_commits` prototype defers intermediate MPS submissions until the
  ordinary final commit. It changes a scheduling contract and is a diagnostic
  intervention, with no claim of general MPS compatibility. **The measured
  prototype was slower and is not selected for product use.**
- `native_leaky` replaces the expanded max/min/multiply/add activation with
  `leakyReLU(alphaTensor:)`, using the same FP16 slope tensor. `activation` mode
  compares all 65,536 input bit patterns in one isolated shape. The measured
  finite inputs matched; 1,024 nonfinite patterns differed. Whole-network
  outputs are checked separately. **No net speed benefit was established, so
  this variant is also not selected.**

Prepare a fresh native directory with the current `prepare_native.py` and build
it as above. Both experimental interventions default to off. For each new
comparison, keep a new output directory and reuse the original inputs:

```sh
CONTROL_ROOT=/path/to/new-controlled-results
python3 -u -B Experiments/K1LowRank/run_controlled.py \
  --native-bin "$BUILD_ROOT/release/k1-bench" --native-source "$NATIVE_ROOT" \
  --prior-results "$RESULT_ROOT" --output "$CONTROL_ROOT/submission" \
  --gpu-lock "$GPU_LOCK" --intervention submission
python3 -B Experiments/K1LowRank/analyze_controlled.py \
  --result "$CONTROL_ROOT/submission/controlled.json" \
  --output "$CONTROL_ROOT/submission/analysis.json"
```

For the separate activation experiment, pass `--intervention native-leaky` to
both scripts and use another output directory. Its preregistered primary is
D0-expanded minus D0-native at 30 Hz. The submission experiment's primary
remains default D0 minus default Ds; a secondary arm cannot replace it.

Each default experiment uses 12 time blocks × three alpha values × two cadences
× four arms × 20 streamed frames = 5,760 measured calls. Cells and arm order are
randomized before acquisition. Inputs alternate A/B with one new Head per push.
Each arm has its own nominal 30 Hz arrival timeline; overruns retain their lag
and do not move the following arrivals. The arrival budget is not a product
presentation deadline. `arms.jsonl` preserves completed arms if a run fails.

Analysis resamples whole blocks jointly, preserving arm/alpha covariance;
frames and buffers are not independent statistical units. A length-three
circular moving-block analysis is a sensitivity check, not a coverage
guarantee. Relative saving is a ratio of means. Last-frame hashes compare the
same weights under the two execution policies, not the student against D0.

The two short windows did not establish repeatable low-rank speed benefit.
They are reported separately because graph residency and execution history
differ; their intervals are not pooled. These results do not justify model
training, state reuse or application integration under the original gates.
