# Four-stage Air training candidate

This private experiment removes the fifth refinement stage from original
RIFE4.25. It retains the Head, blocks0–3, Fast geometry, accumulated mask,
full-resolution synthesis and all13 original block3 output channels. Block3
still predicts a **delta**: add it to the frozen block2 state before supervising
the cumulative flow/mask. The unused feature channels are not separately trimmed.

Only block3's30 tensors (375,828 scalars) can train. Head and blocks0–2 remain
frozen. The candidate has128 tensors and the explicit graph identity
`odf-ifnet425-fourstage-acc-v1`; it is neither the earlier dense fine-tune nor
the earlier factored/narrow final-stage model.

The retained candidate is **untrained**: its weights are the original first
four stages, SHA256
`729ea555016da98e207bc4570e0be81dddbbd37302f7330c89696da798fba22d`.
Its measured native-cost benefit below comes from deleting a stage, not from
the A optimizer updates. A performed200 real training steps but failed its
20% loss-reduction gate; B was not started. Native numerical alignment and
small development diagnostics passed, while independent perceptual quality
and stable application24→48 delivery remain unaccepted.

## Data and preparation

`data.py` derives36 midpoint training triplets and12 development triplets from
the existing hash-bound, five-clip,50Hz development inventory. Consecutive
indices0/1/2 form40ms endpoints and a20ms real GT midpoint; no gap is bridged.
The three training clips and two development clips remain separate. This is
**25→50 training material**, an approximation to the24→48 application target.
It cannot establish exact24Hz or independent quality acceptance. Source PNGs
remain read-only. Only the named five-clip training/development images were
used in this line; the independent-evaluation data gap is described below.

Here **teacher** means the original five-stage product configuration (Fast,
accumulated masks). **GT** is the real intermediate source PNG at the requested
timestamp. Teacher agreement and GT quality are different measurements; the
teacher is neither GT nor a guaranteed upper bound on GT PSNR.

The model implementation reuses the existing read-only `vfi-lite` reference's
padding, resizing, flow units and synthesis. Initial four-stage outputs at
stage3 must match the original five-stage prefix. The cached teacher-prefix
training path must match the full four-stage forward before optimization.

The original4.25 source SHA256 is
`ef29a643a76a9202600458a23dddce16919337ef01743d0fbe817684ec990f74`.

```sh
"$PYTHON" -B Experiments/Air24Training/data.py \
  --frozen "$FROZEN_DEVELOPMENT_MANIFEST" --output "$NEW_DATA_MANIFEST"
"$PYTHON" -u -B Experiments/Air24Training/train_a.py "$A_CONFIG"
```

Keep machine paths, media, weights, generated native packages and run directories
outside Git. The configuration names the original model, lab reference, derived
manifest, new output directory, shared non-blocking GPU lock and cancellation
marker. A marker stops before new optimizer work; it does not terminate another
process. The image cache is bounded to16CPU uint8 originals, without disk copies.

## A feasibility contract and recorded result

A is one fixed seed, FP32/MPS, CPU4, batch8 random512×512 crops, at most200steps
or900seconds. It trains with GT Charbonnier +0.25teacher Charbonnier +0.05L1
flow +0.05L1 sigmoid-mask. Flow is converted to full-resolution pixel units and
divided by unpadded image width. Only flips and endpoint reversal are used.
AdamW has zero weight decay, peak LR1e-4,100step warmup, cosine floor1e-6,
and gradient norm clip1. The fixed eight-crop loss probe is separate from the
random batches and is identical before and after training.

The first A run completed200 real optimizer updates in117.20seconds. All30
block3 tensors changed; source weights and frozen prefix were unchanged, and
all128 names/shapes remained identical. Fixed-probe loss decreased from
0.0665462762 to0.0599642545 (**9.8909%**). The preregistered20% reduction gate
failed. Initial/last weights and all200 step records are retained. No B run,
budget extension or native-finite follow-up of A-last was performed. Subsequent
B0 and native alignment of the **untrained** candidate are separate diagnostics;
they do not reclassify A as passed. A loss is not a GT-PSNR, visual-quality or
playback acceptance.

## Separate native cost screen

`prepare_native.py` invokes the existing pinned product preparer in a **new**
directory, then adds only a strict four-stage RMW2 loader contract and a small
cost CLI. The existing IFNetGraph already uses the header's scale list. Original
RMW1, convolution/warp math, padding and crop paths are not changed. Upstream
licenses are retained. The production runtime and application are untouched.

```sh
"$PYTHON" -B Experiments/Air24Training/prepare_native.py \
  --source "$PINNED_PRISTINE_RIFE_SOURCE" --output "$NEW_NATIVE_COPY"
DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcrun swift build \
  --package-path "$NEW_NATIVE_COPY" -c release --jobs 4
```

The portable cost package contains `air24-cost`, its resource bundles, original
and **untrained** four-stage weights, a hash manifest and standard-library Python
controller. The caller first verifies the Air session/idle state and excludes
other experiments. `run_cost.py --preflight-only` only verifies files;
`run_cost.py --run` runs once and refuses an existing result directory. It uses
the shared diagnostic GPU lock and a180second process timeout.

At1814×1142, FP16 Fast, it primes the previous Head, warms20alternating calls per
arm, then measures200ABAB pairs of complete synchronous `stream.push(_:into:)`.
Each push includes one new Head, native BGRA/tensor IO, all4/5stages, final
full-resolution warp/blend/BGRA, completion wait and status check. Output buffers
and graphs are preallocated/warm. It excludes NV12 conversion, source generation,
App queues, capture, presentation and FPS. Verbose/profile/dump modes are off.

`analyze_cost.py` requires median reduction≥10%, strictly positive95% bootstrap
interval of mean paired savings, and no P95 worsening. The bootstrap uses10,000
AB-pair resamples with a fixed seed; these are short-window conditional intervals,
not independent sessions or stable product evidence. Cost and quality are reported
separately. This cost screen does not make the failed A loss gate pass.

### Recorded Air structural cost result

One completed Air run used the original five-stage model and the **untrained**
four-stage model under the fixed1814×1142 FP16 Fast protocol above. Each arm
has200measured calls after20warm-ups, ordered as200ABAB pairs.

| Complete synchronous native call | Original five-stage | Untrained four-stage |
| --- | ---: | ---: |
| P50 | 18.1323335ms | 13.6138125ms |
| P95 | 20.13746105ms | 15.530467ms |

The median wall time decreased **24.9197%**. Mean paired saving was4.64557832ms,
with a95% paired-bootstrap interval of **[4.40647,4.88448]ms**. All three
prespecified cost gates passed. The raw and analysis evidence are referenced as
`air-fourstage-cost-results-01/result/raw.json` and `analysis.json` in the local
evidence root; raw SHA256 is
`d5892644df3d98f7535f7c35887ffa166abe0796c5c8ad440f6cd36aaf5d0c35`.
Raw results, media and weights are not checked into this directory.

This establishes a structural native-cost benefit in that short conditional
window. AB pairs are not independent sessions; the deterministic BGRA fixture
does not include NV12 conversion, App queues, capture or presentation. It does
not establish FPS, sustained24→48 delivery, or visual quality. No trained
checkpoint was timed in this run. The A feasibility loss gate still failed at
9.8909% reduction, and no B training or holdout evaluation has been started.

## B0: loss reference and development diagnostics

A separate diagnostic stage, without an optimizer, reused exactly the same
eight fixed crops and reproduced A's initial/last losses with zero difference.
The teacher self-prediction reference loss was0.0586929321. Thus the initial
reference gap was0.0078533441 and A recovered83.8117% of that gap. This teacher
value is a reference, **not a mathematical lower bound**; the ratio is not
clamped and would be undefined for a nonpositive denominator. The old A20%
failure is unchanged; this new diagnostic does not rewrite its criterion.

On the two existing development clips, FP32 GT PSNR was:

| Clip-equally-weighted mean | Original five-stage | Untrained four-stage | A-last four-stage |
| --- | ---: | ---: | ---: |
| Twelve40ms midpoint queries | 28.198021dB | 31.225006dB | 30.899935dB |
| Four80ms midpoint queries | 27.269890dB | 30.381119dB | 29.838499dB |

The untrained candidate exceeds the teacher on both development clips and
both endpoint spacings. A-last moved closer to the teacher-loss reference but
lost0.3251dB/0.5426dB relative to the untrained candidate. On this material the
teacher is not a quality upper bound. These are small development diagnostics,
not independent quality acceptance or a reason to open sealed data implicitly.
Evidence is referenced as `B0-r1/report.json` in the local training run root.
No full-resolution B training or checkpoint selection was performed.

The recorded decision is to keep the untrained four-stage candidate and not
start B or continue distilling toward this teacher. The signed development
criterion was candidate40ms ≥ teacher40ms −0.1dB, with candidate80ms no lower
than teacher80ms. A's learning signal and failed original gate are both kept;
neither is relabelled as the source of the structural speed improvement.

## Independent quality data remains insufficient

The historical six-clip inventory is not a verified formal holdout contract.
Its split remained a draft, recording-source independence was unresolved, and
four clip names already appeared in earlier development reports. Its60Hz,
four-frame windows also cannot supply the planned exact40/80ms midpoint
evaluation. This line inspected that inventory's metadata/file existence only,
without decoding, inferring or scoring those six clips.

Thus the results below remain development and numerical evidence. No independent
quality pass, human image-quality acceptance or stable24→48 application result
follows from them. The model candidate is frozen; this data gap pauses the
independent-quality claim, not unrelated software or integration work.

## Native FP16 numerical alignment

`prepare_probe.py` prepares a new quality-only source copy, reusing the earlier
state-dump patch and expecting only final `stage3_flow.npy`/`stage3_mask.npy`.
The uninstrumented measured cost package is never rebuilt or overwritten.
`align_native.py` uses the same16development endpoint pairs, reads the actual
FP16 RMW2 payload back into the FP32 reference, and checks its re-export SHA
against the original FP16 file. It does not substitute the unquantized `.pt`.

All16instrumented native outputs matched their uninstrumented output hashes
exactly. Native flow/mask and reference outputs were finite. Minimum RGB PSNR
was58.47009dB (mean58.73192dB), above the40dB threshold. The maximum per-query
P99 absolute flow error was0.038514full-resolution pixels, below0.5pixels;
overall maximum absolute error was0.24978pixels. Flow comparison excludes
right/bottom padding and converts Fast-grid pixels to full-resolution units.

All numerical gates passed. Private probe compilation used CPU4; B0 and native
GPU diagnostics ran sequentially under the existing project lock. The cost
binary hash remained unchanged. Compiler/probe/source hashes and individual
query results are retained in `native-alignment-r1/report.json` and
`compiler-probe-receipt.json` in the local training run root. These establish
implementation alignment, not perceptual quality, holdout or application FPS.
