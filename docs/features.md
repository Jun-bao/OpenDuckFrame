# Features and availability

OpenDuckFrame combines live enhancement and local playback. The app reports
runtime availability; an interface entry does not mean every Mac or input
supports that backend.

## Input and output

Window and display inputs use ScreenCaptureKit. Local files use the player's
decoding path. Window output follows the source window; display and video-file
output can use a selected display, including fullscreen output. Scaling and
interpolation have separate controls. Profiles preserve common settings, and
the FPS overlay reports observed output.

## Frame generation

The workbench's frame-generation engine is **ODF-VFI**, run with Metal on
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

The source tree also contains other interpolation backends. They are not
selectable in the current workbench:

| Backend | Status in the current app |
|---|---|
| Apple FRC / Motion+ | Not a workbench engine. The player's own motion-smoothing menu (off / double rate) uses it on macOS 26+ with supported hardware; runtime capability checks apply |
| Apple low-latency interpolation | Code retained; not selectable in the workbench |
| RIFE 4.26 | Weights and loader retained; not selectable in the workbench |
| DistilDRBA | Experimental code retained; optional model, fixed 1280×720 input and X2 midpoint |

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

The normal workbench exposes ArtCNN C4F32 and the lighter C4F16 model.
Both use the original upstream weights and produce native 2× luma; chroma is
scaled separately. They support SDR input up to 1920×1080 and output up to
3840×2160. HDR, cropped input and odd dimensions are rejected. Compare at the
same output size; neither model guarantees recovery of real missing detail.

Window inputs can optionally resize the selected source window before capture;
that requires Accessibility permission and a resizable window. The source video
must fill the captured window. Display inputs can reduce capture dimensions
before processing. Local files use decoded source pixels directly.

The repository retains Lanczos/MetalFX and experimental Apple, Anime4K and
Real-CUGAN implementations. These are not selectable in the current normal
workbench; their existence in source does not establish packaged availability.

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
