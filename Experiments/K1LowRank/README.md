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
