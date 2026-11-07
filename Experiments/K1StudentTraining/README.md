# Product-aligned K1 student distillation

This isolated experiment follows the approved bounded-training continuation.
It keeps the production model and package unchanged. The earlier low-rank
experiments use laboratory replacement-mask semantics; their weights are not
relabelled as product students.

The teacher and student explicitly use the product's **accumulated mask**,
padding, tier geometry, bilinear sampling, full-resolution synthesis and crop.
The source is original RIFE 4.25 from the pinned RifeMetal 0.1.8 dependency.
Its SHA-256 is
`ef29a643a76a9202600458a23dddce16919337ef01743d0fbe817684ec990f74`.
The teacher reuses the existing read-only lab deployment reference; the native
counterpart uses the product execution preparer with GPU padding/direct crop
enabled equally for original and student arms. Numerical reference agreement
is distinct from output equivalence and independent quality acceptance.

## Model and data

`odf-ifnet425-acc-b3r32-b4r16-v1` factors the eight residual branches in each
of block3 and block4. Each branch is a bias-free 3×3 projection, a 1×1 projection
with folded bias, the original skip and LeakyReLU. There is no intermediate
activation or second beta multiplication. Only these **48 tensors / 205,568
scalars** are trainable; Head, block0–2, conv0 and lastconv remain frozen.
`odf-ifnet425-acc-b3r64-b4r32-diag-v1` is a full-rank expression diagnostic,
not another trained candidate.

The existing development material contains only 60 training PNGs from three
clips, in four five-frame windows per clip. Their original manifest proves
50 Hz source cadence. The training set therefore has 48 adjacent 20 ms pairs;
gaps between windows are never bridged. Six fixed pairs and three phases supply
response-weighted SVD initialization (512 patches per branch/query).

Two separate development clips provide 48 adjacent teacher-distillation
queries for checkpoint selection. Their twelve 80 ms-endpoint GT queries are
reported for initial/best/last models and do not select checkpoints. The six
independent holdout clips are not accessed. This small experiment measures
recoverability on development material, not generalization or noninferiority.

`data.py --design OLD_DESIGN.json --output NEW_MANIFEST.json` verifies original
provenance/hashes and freezes the split without copying images. The
`--from-frozen` alternative derives a new manifest with the 48-query selection
set from an already frozen manifest; it does not reopen the original images.

## Bounded training contract

`train.py CONFIG.json` supports `initialize`, `train` and `evaluate` modes.
Every GPU phase holds the existing non-blocking project lock. Training and
native cost measurements run separately; neither display refresh nor a passing
native cost screen is a prerequisite for this bounded recovery experiment.

The approved configuration uses complete 1920×1080 Fast inputs, float32,
effective batch 4, AdamW with betas (0.9, 0.999), no weight decay, and global
gradient-norm clipping at 1. The unchanged reference accepts scalar alpha, so
four microbatches accumulate mean gradients before one optimizer update.
Two samples use alpha 0.5; two use uniform alpha in (0.05, 0.95). Horizontal
flips and endpoint/time reversal are sampled; the teacher runs on the same
augmented pair.

The peak learning rate is 1e-4, with 200 warm-up steps and cosine decay to 1e-6.
Loss is RGB L1 divided by its fixed initial mean, plus 0.25 times the sum of
normalized cumulative flow/logit L1 for stages 3 and 4. Initial normalizers use
all 48 training pairs at midpoint without augmentation. Losses exclude the
right/bottom padding: RGB uses the original image and internal states use the
mapped valid region. Ground truth never enters the optimizer.

Stop at 10,000 optimizer steps or 7,200 training/evaluation seconds, whichever
comes first. Deadline/cancellation checks precede new forwards, microbatches,
optimizer updates and evaluation queries. In-flight GPU draining and final
artifact flushing are recorded separately. There is no automatic extension.
Every 1,000 steps evaluate the 48 fixed adjacent development queries. Selection
uses teacher RGB L1; a 1% improvement resets the no-improvement counter. Stop
after three evaluations without that improvement, two consecutive evaluations
worse than initialization, or nonfinite values. Every evaluation retains a
checkpoint. Best is the actual lowest diagnostic error and may be step 0; last
is retained separately. Frozen tensors and original weights are checked at
the end. Best/last GT reports are separate post-training evaluation calls.

## Native alignment and reproduction

The new native preparer only edits a fresh generated destination:

```sh
python3 -B Experiments/K1StudentTraining/prepare_native.py \
  --source "$PINNED_RAW_PRODUCT_SOURCE" --output "$NEW_NATIVE_SOURCE"
DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" xcrun swift build \
  --package-path "$NEW_NATIVE_SOURCE" -c release --jobs 4
```

The native tool keeps the existing positional `k1-runtime CONFIG.json` interface. RMW2 headers
must identify one of the two accumulated-mask graphs, with the exact 158 tensor
schema/layout and payload. Original D0 uses its canonical version 1 container.
The generated package retains the original licenses and source provenance;
production sources and bundled weights are not modified.

`compare_native.py CONFIG.json` compares actual native outputs with the exact
exported FP16 weights evaluated in float32. Default scope is 12 GT queries;
`evaluation_set: "both"` uses all 60 development queries. Native cases are
grouped by their actual endpoint indices, not just their parent window name.
It records continuous RGB error and BGRA8 nearest-even quantized error:
maximum LSB difference, mean absolute LSB difference, and fraction of pixels
with any RGB channel differing by at least 2 LSB. An optional
`numerical_baseline` records each sample's comparison with twice its D0 error;
these flags concern implementation numerics and never establish visual quality.
Retain flagged observations and any subsequent diagnostic decision explicitly.

The initial per-sample v1 comparisons retained four triggered/undetermined
observations. Before evaluating trained weights, the numerical v2 diagnostic
was registered: every sample's mean LSB error must remain within twice D0;
the pooled 60-sample fraction of pixels with any RGB difference at least 2 LSB
and the pooled absolute RGB 99.99th percentile must each remain within twice
the full-rank factor graph. Maximum LSB is reported without a threshold. The
full-rank graph controls for the extra FP16 intermediate rounding introduced
by factorization. Reusing old native outputs for histogram analysis does not
rerun inference or retrospectively clear the v1 observations. These numerical
limits do not establish quality noninferiority.

`numerical_probe.py` prepares a separate quality-only diagnostic executable.
It can dump accumulated block3/4 flow and mask states with an explicit output
directory. It is excluded from cost measurement. A finite probe of the four
initial v1 observations compares these states and error locations with D0 and
the full-rank graph; its output hashes must match the uninstrumented executable.

Model exports include an explicit graph ID, FP16 `.rmw`, weights-only-loadable
`.pt`, and a sidecar binding source SHA, mask policy, ranks and training status.
Training outputs include the configuration, fixed loss normalizers, per-step
records, per-target evaluations, checkpoints and final provenance. Keep local
paths, original media, weights and generated runs outside Git.

`analyze_training.py --run-root RUN_DIRECTORY --output ANALYSIS_DIRECTORY` audits the
recorded step continuity, sample membership, evaluations, log hashes and recorded
source/frozen-tensor checks without reopening media or running a model. Optional
Matplotlib output plots the recorded loss and fixed-query development curves.

## First bounded run (2026-11-07)

On the tested M5 Max, actual training completed 10,000 optimizer updates
(40,000 augmented samples) in 1,487.38 seconds. Best and last were both step
10,000, with identical exported FP16 weights. All 48 trainable tensors changed;
the 110 frozen tensors and original source weights were unchanged.

On the 48 fixed **20 ms** development queries, mean teacher RGB L1 decreased
from 0.0032919022 to 0.0011340045 (65.55%); mean per-query teacher RGB PSNR
increased from 46.3784 to 54.0069 dB. This is improved teacher agreement.

The separate 12 **80 ms** development GT queries regressed after training:

| Native FP16 model | Mean GT PSNR | Mean delta from D0 | Worst delta from D0 |
|---|---:|---:|---:|
| Original D0 | 27.475692 dB | 0 | 0 |
| Response initialization | 28.004917 dB | +0.529226 dB | +0.131483 dB |
| Trained best/last | 27.432108 dB | -0.043584 dB | -0.348064 dB |

All twelve targets decreased relative to initialization (mean -0.572810 dB).
The FP32 reference also decreased (mean -0.572277 dB), so FP16 export does not
explain this regression. GT is diagnostic development material, not a frozen
noninferiority test. No quality acceptance follows from the teacher curve.

The trained export stayed within the preregistered numerical v2 limits on 60
queries: mean absolute RGB difference 0.031053 LSB; pooled pixels at least 2 LSB
0.071443% versus full-rank 0.076816%; both pooled 99.99th percentiles 3 LSB.
Maximum difference was 33 LSB. Three v1 flags remain recorded. The finite
four-point initial-state probe matched all twelve uninstrumented output hashes;
it does not establish independent image quality.

Complete synchronous native midpoint calls, including one new Head, measured:

| 1920×1080 preset | D0 | Initialization | Trained best | Trained saving vs D0 |
|---|---:|---:|---:|---:|
| Fast | 2.843775 ms | 2.835574 ms | 2.830601 ms | +0.46% |
| Balanced | 7.117202 ms | 7.095876 ms | 7.130600 ms | -0.19% |

Each preset used 20 paired time blocks, three arms, three phases, two cadences,
32 warm-up calls and 24 measured calls per arm (8,640 measured calls/preset).
All arms shared GPU padding/direct crop; diagnostic state dumping was disabled.
For midpoint saving, whole-block 95% intervals were [-0.040205, +0.067214] ms
(Fast) and [-0.068491, +0.040622] ms (Balanced), both crossing zero. Neither
initialization nor trained weights passed the three-phase cost screen in either
preset. These are short-window paired measurements, not application FPS.

Trained weights and logs remain research evidence; no production model was
replaced. Independent holdouts remain sealed, and whole-application 120 FPS
acceptance remains outstanding.

## Checks

CPU tests cover the model/schema/freeze, data split/provenance, native loader,
numerical comparison helpers, budget cancellation, valid-region loss and
effective-batch gradients. They do not stand in for real training, exported
native validation, inference-cost evidence or actual application playback.
The final CPU suite passed all 47 tests with the existing lab reference path
provided through the environment:

```sh
ODF_VFI_LAB_ROOT="$VFI_LAB_ROOT" python3 -B -m unittest discover \
  -s Experiments/K1StudentTraining/tests -v
```
