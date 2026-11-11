# macOS rendering and audio

[Rendering/SPMetalRenderer.mm](Rendering/SPMetalRenderer.mm) implements Mac Metal presentation.
[Audio/SPAudioOutput.mm](Audio/SPAudioOutput.mm) implements desktop audio output.
Their public interfaces are under `Modules/MediaCore/Bridge/`.
They compile into OpenDuckFrameMediaCore through [Apps/Mac/project.yml](../../Apps/Mac/project.yml).

## Rendering changes

Preserve buffer ownership, render/presentation timing and cancellation across player generations.
Retain source color metadata, transfer functions, pixel formats and HDR/display behavior.
Keep playback shaders under `Modules/MediaCore/Shaders/Video.metal` as the source of truth.
`Scripts/gen_shader_header.py` is invoked by the build to prepare the shader header.
Keep lazy FrameBudget resources independent of normal playback startup.
Coordinate generator/provider changes with [Modules](../../Modules/AGENTS.md).

## Audio and verification

Preserve device routing, channel layout, clocking, seek/flush behavior and A/V synchronization.
Use `./Scripts/test_file_renderer_integration.sh` for its offscreen renderer scenario after building the matching media framework.
It defaults to Debug products; `ODF_TEST_FRAMEWORKS_DIR` can select matching framework output.
Choose color-transfer/scaler tests for the exact changed path after reading their prerequisites.
A CAMetalLayer or buffer test does not establish the visible display result.
Check actual HDR/SDR output or audible playback and sync when those behaviors change.
Report the display/audio device, input metadata and tested settings for such acceptance.
