# Local experiment comparison

This is a private trial surface for comparing existing candidates, not a new
quality or performance certification. Normal builds keep their existing UI
and models. Trial preferences and profile files are separate from the normal
player, and the two trial configurations have separate instance locks.

Open **Compare Options** in the workbench sidebar. The five controls are:

| Control | What changes | Combination |
| --- | --- | --- |
| Data transfer optimization | GPU edge padding and direct output crop, or their CPU reference | Can combine with either model and either blending rule |
| Fine-tuned model | P04 terminal version 1 or 2, using the original dense graph | Replaces the low-rank choice; initially selects the original experiment's replacement-mask rule |
| Low-rank model | Product r32/r16 response-weighted initial weights or trained weights | Replaces the fine-tuned choice; initially selects accumulated masks |
| Frame blending rule | Replace the mask at each stage, or accumulate it | Can be changed independently; a new combination is not covered by an old quality result |
| Optimized build | Start the separately compiled Release or Debug trial app | Restarts the trial application; does not pretend to change compiler flags in place |

Changing controls 1–4 stops enhancement, saves the selection, and chooses
RIFE 4.25 with the streaming entry point. The source, quality tier, output
size and target rate are retained. Click **Start Enhancement** to apply the
new selection. **Turn off options 1–4** restores the original dense model,
CPU I/O and accumulated masks. The current compiler configuration remains
visible. Switching builds shares trial selections and saved trial profiles;
media playback sessions are not transferred between processes.

## Build the local pair

Use `Scripts/build_experiment_trial.py --help`. Prepare the existing pinned
dependencies first. A private schema-1 JSON manifest supplies `models`, each
with `id`, `file_name`, `source_path`, `sha256`, `graph_id`, `mask_update` and
`description`. The four model IDs are `finetune-a`, `finetune-b`,
`lowrank-initial` and `lowrank-trained`. Source paths and raw weights do not
belong in the repository. The packager verifies hashes and embeds only the
model metadata and model files in the local trial apps.

```sh
DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer \
  python3 Scripts/build_experiment_trial.py \
  --assets-manifest /private/path/assets-input.json --skip-dependencies
```

The default output is `.build/ExperimentComparison/{Debug,Release}/OpenDuckFrame.app`.
Keep those two directories together for the build-switch button. The script
does not deploy the root application, register Quick Look, or configure the
normal update feed. Each configuration has its own build log, model hashes,
code-signing verification and same-source identity in the output manifest.

## Verification

`Scripts/test_rife_experiment_selection.sh` checks persistence of all model,
I/O and blending choices and the trial/normal instance namespaces without
running a model. `Scripts/test_workbench_store.sh` covers profile storage.
`Experiments/TrialPresets/runtime_smoke.py` exercises the actual runtime on
small synthetic frames under an explicit GPU lock. It checks all model and
option combinations, output dimensions, API paths, I/O pixel equality and
that changing models/masks really changes output. Those checks do not judge
motion quality, perceptibility, application FPS, or deadline reliability.

## 中文使用说明

在工作台左下打开“方案对比”。①数据搬运优化可以与②微调模型或③低秩模型组合；
②③只能选一个，且各有两个版本。④画面融合规则可以独立调整。⑤优化构建会重启到
另一份真正独立编译的试用应用，Debug 与 Release 文件夹需保持同级。

调整前四项后，增强会停止，回工作台点击“开始增强”应用。来源、尺寸、画质档位和
目标帧率保持；新组合的效果由实际观看判断，不沿用其他组合的旧成绩。
试用配置与正式版分开，不替换正式应用，也不发布或合并。

## Headless Air cadence diagnostic

`runFixedRateModelProbeWithBundle:` also accepts an explicit
`ODF_AIR_CADENCE_DIAGNOSTIC=1` test mode. It runs only X2 with paced 30 Hz
owned NV12 inputs through the production processor. The existing fixed-model
probe is unchanged when this flag is absent.

Set `ODF_AIR_CADENCE_WIDTH` and `ODF_AIR_CADENCE_HEIGHT` (even, 128–4096),
`ODF_AIR_CADENCE_SECONDS` (5–60, default 24),
`ODF_AIR_CADENCE_WARMUP_SECONDS` (1–5, default 3), and
`ODF_AIR_CADENCE_DISPLAY_HZ` (30–240, default 60), then use the existing
`Scripts/test_live_output_repair.sh fixed-model` driver. Its
`ODF_TEST_RESOURCE_APP` must contain the original model without active trial
preference overrides. For performance diagnosis, use a separately linked diagnostic dylib made from
the actual optimized Release object files and point `ODF_TEST_DEBUG_DYLIB` to it.
Xcode can suppress its automatic debug dylib for optimized builds even when
`ENABLE_DEBUG_DYLIB=YES`; do not switch to Debug optimization to obtain one.
The diagnostic loader and all resource/framework paths must be portable.
Never replace the installed app to run this test.

The timeline contains actual host intervals, logical source/synthetic/hold
counts, production stats, and configuration/measurement epoch changes.
`ok`/`executionOK` describe execution, not meeting the 29/58 observations.
Report qualified `observedHostSeconds` alongside `nominalMeasurementSeconds`:
delayed or coalesced windows remain in the timeline but are excluded from the
qualified one-second fractions. This is offscreen logical playout, with no
ScreenCaptureKit, Safari, drawable or physical-display/quality acceptance.
It does not change user preferences or require accessibility/screen recording.

## Self-owned-window capture and presentation diagnostic

`Modules/VideoEnhancement/Tests/SPSelfWindowCaptureProbe.mm` is a standalone
accessory-app driver for a different layer: a generated 30 Hz source window,
ScreenCaptureKit, the production content gate/owned copy/processor, and the
production drawable presenter. It dynamically loads the optimized diagnostic
library above. Package that library inside its own `Contents/Frameworks`, copy
the ordinary app's Resources/Frameworks, and omit `ODFExperimentTrial` so the
test uses the original model without changing trial preferences. Keep the
runtime bundle outside protected Desktop/Documents/Downloads folders and use
a private temporary directory for native results; no folder-access approval
is needed for this test's own resources and results.

The CLI accepts `--output /absolute/new.json --preflight-only`,
`--output /absolute/new.json --inspect --dylib /absolute/bundled-library`, or
`--output /absolute/new.json --dylib /absolute/bundled-library
--source-width-points 1324 --source-height-points 834 --seconds 12
--minimum-idle-seconds 60`. Each of two phases lasts 5–60 seconds. The source
remains uncovered first, then the output covers it. A small display may only
leave a strip of the first output exposed; the report records this geometry
and does not call it a fully separated comparison.

Only current-process content is queried, with an exact window ID and owner
PID check. That API redacts window/filter geometry, so stream and plan sizes
come from the exact own source view's backing bounds. An in-memory screenshot
checks that filter before streaming; it saves no image. The test stops on new
input, session/display changes or failures, closes its own windows, and never
falls back to global enumeration or a permission request. Progress and the
first failure remain in the result. `functionalComplete` is separate from
29/58 counted-drawable observations; these callbacks are neither Safari
acceptance nor physical-display or human quality proof. The token-gated
`surfaceReady` counter is not total GPU throughput.

For a presentation baseline, use `--arm bare|passthrough|rife` with
`--control-only`, in that order. Bare uses its own immediate display-link
renderer without loading the production library or creating a capture stream;
its static own occluder preserves the control layout. Stop before the other
arms if its measured valid-presented mean is below 58/s. Passthrough starts
with interpolation disabled and multiplier 1; RIFE retains the original X2
request. B/C acceptance still uses counted source plus synthetic frames,
excluding redraws/holds, rather than every valid callback.

The explicit per-process `ODF_AIR_PRESENTATION_TIMING_DIAGNOSTIC=1` flag adds
texture/encoding, lock and actual deadline-check samples under
`airPresentationTiming`. It preserves the existing cutoff and presentation
logic, including failure paths. `HostTicks` require `mach_timebase_info`
conversion; they are not nanoseconds. Existing `gpuHost` is CPU completion
handler arrival, while the bare arm separately records GPUStartTime/GPUEndTime.

`ODF_AIR_PRESENTATION_GUARD_DIAGNOSTIC=1` is a compile-time experiment only:
it changes the selection guard to 2 ms while the normal build remains at
1 ms. It does not change the drawable's actual submission deadline or the
counting rules. Processor status flags are retained as status history; as in
the workbench, a budget warning alone does not stop the test. Plan rejection,
stream/initialization errors and the existing timeouts still stop execution.

With that diagnostic compile switch, the additional per-process
`ODF_AIR_PREPARED_TEXTURE_DIAGNOSTIC=1` flag enables one independent serial
texture-mapping cache. At most four leases cover queued mapping, ready work,
GPU use and pending recycling. Selection never waits: absent, mismatched or
unfinished mapping uses the original path. Each lease keeps its pixel buffers
and CVMetalTextureRefs until discard or GPU completion; the mapper queue
releases and flushes them. Normal builds and default runs leave this path off.
`presentationSlots.output.preparedTexture` records hits, fallbacks, capacity,
failures and recycling; the original renderer cache and flush remain intact.

Before timing, `--prepared-lifetime-only --dylib /absolute/bundled-library`
checks a real offscreen draw and red-pixel readback, four admission slots, a
one-buffer pool blocked while the GPU waits, and reuse after GPU completion
and mapper cleanup. It creates no window or capture stream. This checks the
combined lease ownership, not each reference type independently; the fifth
admission is attempted before the mapping fence. The GPU wait has a five-second
timeout, while mapper fences require the runner's external process timeout
for an overall bound. The command driver allows 30 seconds and the runner
terminates that subprocess after 45 seconds.

The initial formal 2 ms candidate gate at X1, 2648×1668, for 60 seconds required
all qualified windows to reach 29 counted source frames/s, submit-deadline
failures must be at most 1%, selection-to-check p99 at most 1 ms, pre-mapping
fallbacks at most 1%, with zero owned-pool drops/exhaustions or texture failures.
That result remains a strict failure: 52/53 qualified windows reached 29/s.
The inspected low window had 29 callbacks in 1.000442 seconds; all 30 selected
frames later had distinct positive presented times, including one callback in
the next window. This closes that cohort's count difference without proving
uniform cadence or real-screen quality. Other timing gaps and the unobserved
export tail remain separate.

For subsequent internal diagnosis, the advisor restored the original ratio
criterion of at least 95% qualified windows at 29/s, with no attributable
presentation loss, rather than silently reclassifying the old all-window
gate. Only that reviewed progression criterion permits the large RIFE floor:
at least 95% of qualified windows at 29/s, attributable presentation loss at
most 1%, and selection-to-check p99 at most 1 ms. This loss criterion protects
admitted original frames; synthetic losses are reported separately as
interpolation delivery. Late originals and originals retired by a budget
configuration change count as losses. Only a proven original-to-original
collision in the same display slot is exempt. Unknown request types remain
conservative failures until typed evidence is available. It includes the period before
budget downgrade. The small 1814×1142, 60-second test follows only if the large
gate passes; its target is at least 95% of windows at 58/s. These tests record
downgrade and recovery behavior as well as model timing. A failed candidate
is retained for review; it does not change
the original trial app, model or preferences, and does not establish Safari,
physical-screen, visual-quality or 60 FPS acceptance.

For one 12-second attribution run, the same compile guard plus
`ODF_AIR_CADENCE_CAUSAL_TRACE=1` adds preallocated POD rings for view admission,
selection and typed retirement, raw callbacks, and each budget evaluation.
Writes use the existing presentation mutex or processor serial queue. There
is no pixel sampling, trace file IO, new queue or periodic array export.
`presentationOrderDiagnostics.airCadenceCausalTrace` exports once after the
controlled caller stops capture; it does not wait for or stop GPU work. Its
cutoff, sequence ranges and overflow counters bound the evidence. Overflow,
selection-to-check p99 above 1 ms or any submission deadline failure makes
this attribution run unusable. Twelve seconds do not replace the 60-second
gate, and newly typed requests do not fill old runs' unknown identities.

Unassigned cleanup slot/replacement values remain null. Callback records can
lack capture/admission/counts fields; associate them with their admission
before building a per-config ledger. Absent callback `redraw` is exported as
false and absent failure `clockEpoch` as zero, so these defaults are not proof
of known values. Preserve unresolved GPU/callback tail as unknown. Budget
caller gates are recorded directly; the policy's internal persistence or
cooldown reason is not inferred from an unchanged decision.
