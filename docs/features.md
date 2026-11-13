# Features and availability

OpenDuckFrame combines live enhancement and local playback. The app reports
runtime availability; an interface entry does not mean every Mac or input
supports that backend.

## Input and output

Window and display inputs use ScreenCaptureKit. Local files use the player's
decoding path. Window and display output follow their source; video-file output
can use a selected display, including fullscreen output. Scaling and
interpolation have separate controls. Profiles preserve common settings, and
the FPS overlay reports observed output.

## Frame generation

The workbench's default frame-generation engine is **ODF-VFI**, run with Metal on
Apple silicon; resolution and quality affect throughput. ODF-VFI is a
four-stage structural reduction of Practical-RIFE 4.25: the retained stages
keep the upstream weights, no additional training is applied, and model
processing overhead is lower. It does not guarantee lossless quality for every
scene. Profiles saved with RIFE 4.25 open with ODF-VFI; `rife-v4.25` remains
the compatibility resource and profile ID, not a second selectable model.
`fast` is the checked quality tier; `balanced` and `hq` remain experimental.

The workbench offers target-FPS and multiplier modes. X2 / X3 / X4 are requests;
frame budget, source cadence and display refresh rate determine actual
presentation. Continuous caching is always on; there is no separate switch.

The engine selector also offers Apple's system processors. Low latency targets
real-time enhancement; FRC is designed for quality-oriented video processing.
FRC can be used during playback here, but its throughput and added delay depend
on the device, dimensions and content. Neither choice guarantees the target FPS.
These options process playback/capture; they do not export an interpolated file.

| Engine | Workbench support |
|---|---|
| ODF-VFI | Default; target FPS or X2 / X3 / X4; fast / balanced / hq |
| Apple low latency | macOS 26+ and runtime support; live window/display X2 or X4; local file X2 only. Fixed FPS and X3 are disabled |
| Apple FRC | macOS 15.4+ and runtime support; live target FPS or X2 / X3 / X4, standard / quality; local files standard only, fixed FPS up to 3× source rate |

Saved and named profiles retain the selected engine. Changing to low latency
selects X2 when the previous rate is unsupported. Changing to file input restricts
low latency to X2 and FRC to standard. Unsupported hardware or input is reported
when preparing the engine; the previous committed plan is retained on failure.
For live Apple low latency, inference fits the runtime dimension/pixel limits on
macOS 27+. On macOS 26, or if preparation at the larger size fails, it uses a
conservative 720p pixel budget. Generated frames are resized back to the captured
source dimensions; original frames, timestamps and output geometry are preserved.
The workbench reports the actual inference size. This resizing does not enable
super resolution and can soften generated detail. File preparation is unchanged.
For enhanced live output, Apple low latency requests a minimum 80 ms adaptive
buffer, subject to the existing delay and memory caps. The presenter keeps the
oldest eligible frame within two observed refresh periods, then catches up to
the latest frame when all queued frames are stale. This reduces avoidable
supersession at the cost of extra input delay; queue capacity remains bounded.
It does not change the model or promise a fixed achieved FPS. RIFE, FRC and
source-only presentation retain their existing policies.
The player's Motion+ menu remains a separate off/double-rate FRC control.
RIFE 4.26 and DistilDRBA remain hidden experimental backends.

On M3 MacBook Air (Mac15,12 and Mac15,13), live **window** capture with
ODF-VFI, Fast, X2 and scaling disabled automatically selects the optimized
pipeline. This uses fused conversion, texture reuse,
adaptive lower-resolution inference for generated pictures, and source-aware
presentation timing. Original pictures retain their capture resolution.
The supported envelope is SDR 420v BT.709, a 60 Hz display, and capture buffers
up to 2648×1668 pixels (1324×834 points at 2× scale). Unsupported inputs in this
path use original-picture passthrough and report a reason in the status area.
The active GPU keepalive work can affect power use. Performance measurements
from this device and envelope do not establish a target rate on every input.

For live target-FPS mode, original pictures fill nearby output slots and
only the remaining slots need model inference. Interpolation phases follow the
source timestamps rather than a rounded integer multiplier. Jobs that cannot
finish within their output budget are skipped; original-picture fallbacks keep
playback moving, and repeated pictures do not count as new motion in the FPS
overlay. Actual presentation remains limited by the Mac and display.

For local files, waiting for a model is bounded by the available playout
runway and at most one output interval. Missed synthetic frames keep the
original picture, and late results are discarded instead of delaying source
playback. This fallback preserves playback cadence; it does not guarantee
the requested multiplier on a slower device.

## Scaling and super resolution

The workbench offers Apple low-latency and Apple video super resolution on
supported macOS 26+ devices. Scaling is off by default. Apple video SR may need
the system model to be downloaded and live capture currently requires frame
generation to be off. File playback uses the existing independent-frame video SR
path; it is not a claim of temporal video history in file playback.

Automatic output chooses a supported factor within the current 3840×2160 output
budget. Live input defaults to a 720p maximum box; video SR may reduce it further
to fit the supported factor and a 3200×1800 live output box. File input is similarly
reduced when needed. Reducing an input can lose detail; actual quality and speed
must be assessed on the source and device. Unsupported sizes or factors are
reported rather than silently switching to another engine. SDR 8-bit is required.
For file playback, Apple video SR currently requires a complete, uncropped NV12
frame with supported 601 or 709 color metadata.

Window inputs can optionally resize the selected source window before capture;
that requires Accessibility permission and a resizable window. The source video
must fill the captured window. The repository retains ArtCNN, Lanczos/MetalFX,
Anime4K and Real-CUGAN implementations but they are not selectable in the normal
workbench.

## Local playback and subtitles

The player supports common video and audio formats, embedded and external text
subtitles, resume, speed control, multichannel audio on supported devices, and
Finder Quick Look. HDR depends on content and display capability. Recovery of
damaged or unfinished files is best-effort.

On-device subtitle generation and translation require macOS 26+ and supported
system languages. Apple may download language models before first use.

## Optional runtimes

The default build fetches pinned media dependencies and RIFE Metal. RIFE 4.26
weights, Real-CUGAN weights and the Anime4K shader are tracked under
`Apps/Mac/Resources/Models`; additional experimental runtime libraries and the
converted DistilDRBA model are not.

Maintainer recipes are provided in:

- `Scripts/build_anime4k_runtime.sh`
- `Scripts/build_realcugan_runtime.sh`
- `Scripts/build_distildrba_model.py` and `Scripts/build_distildrba_runtime.sh`

Read a recipe before running it. These development recipes have pinned source /
binary expectations; they are not portable installers for every Mac. Packaging
includes optional runtimes only when local inventories pass verification.
Attribution records live in `Apps/Mac/Resources/Notices` and
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

## Current limitations

- Only Apple silicon macOS is supported. The mobile directory contains plans.
- Higher requested rates do not guarantee matching physical presentation.
  Model output, scheduling and displayed frames are different measurements.
- Some engines can soften details or introduce artifacts. Compare engines at equal output sizes.
- Resizing, fullscreen transitions, occlusion and protected content can affect
  capture or output. Component tests do not establish compatibility with every application.
- Local Release builds are ad-hoc signed. A source build or successful CI job
  does not provide Developer ID signing, notarization or App Store approval.

The [development status](workbench-status.md) preserves the original evidence
and acceptance gaps behind these limitations.
