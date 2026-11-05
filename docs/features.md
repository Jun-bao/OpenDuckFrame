# Features and availability

OpenDuckFrame combines live enhancement and local playback. The app reports
runtime availability; an interface entry does not mean every Mac or input
supports that backend.

## Input and output

Window and display inputs use ScreenCaptureKit. Local files use the player's
decoding path. Output can follow a source window or use a selected display,
including fullscreen output. Scaling and interpolation have separate controls.
Profiles preserve common settings, and the FPS overlay reports observed output.

## Frame generation

| Backend | Availability and scope |
|---|---|
| Apple FRC / Motion+ | macOS 26+ and supported hardware; runtime capability checks apply |
| Apple low-latency interpolation | macOS 26+ and supported input configurations |
| RIFE 4.25 / 4.26 | Metal on Apple silicon; resolution and quality affect throughput |
| DistilDRBA | Experimental; optional model, fixed 1280×720 input and X2 midpoint |

The workbench offers target-FPS and multiplier modes. X2 / X3 / X4 are requests;
engine, frame budget, source cadence and display refresh rate determine actual
presentation. RIFE stream caching is experimental.

For live RIFE target-FPS mode, original pictures fill nearby output slots and
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

| Backend | Availability and scope |
|---|---|
| Lanczos | Spatial scaling without a learned model |
| MetalFX | System spatial scaling, subject to the Mac's Metal capability |
| Apple low-latency super resolution | macOS 26+; the workbench gates 720p input and supported 1.5× scaling |
| Apple video super resolution | Experimental; supported scale factors and source conditions are checked at runtime |
| Anime4K | Experimental animation-oriented 2× enhancement; optional runtime currently requires macOS 27 |
| Real-CUGAN | Experimental animation enhancement; optional model / runtime and input-size limits apply |

Animation runtime selection currently limits input dimensions to 1920×1080.
Apple video super resolution has a restricted live-input path; read the UI's
availability state rather than assuming arbitrary source sizes work.

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
