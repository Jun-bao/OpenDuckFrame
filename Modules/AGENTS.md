# Shared media and caption source

These are source groups compiled into current Mac targets.
Read [REPOSITORY_LAYOUT.md](../REPOSITORY_LAYOUT.md) and [Apps/Mac/project.yml](../Apps/Mac/project.yml) for target membership.
Current AppKit, rendering, file access and host dependencies must be considered before cross-platform reuse.

## Read by responsibility

- `MediaCore/Core/` owns demuxing, queues, seeking and container recovery.
- [MediaCore/Bridge/SPPlayerCore.h](MediaCore/Bridge/SPPlayerCore.h) and its `.mm` implementation connect playback state to Swift and the platform renderer.
- `MediaCore/Bridge/` contains decoder interfaces, subtitle integration, thumbnails and media metadata.
- `MediaCore/Shaders/Video.metal` is the playback shader source.
- [VideoEnhancement/AGENTS.md](VideoEnhancement/AGENTS.md) covers generation, scheduling and file scalers.
- [Captions/CaptionEngine.swift](Captions/CaptionEngine.swift), CaptionTranscriber and CaptionScheduler manage on-demand caption work.
- Mac caption presentation and downloads are under `Apps/Mac/CaptionsHost/` and `Apps/Mac/CaptionsUI/`.

## Interface and validation rules

Preserve SP interfaces, callback threading, cancellation and seek/generation boundaries for current callers.
Keep decoder errors, damaged-input recovery and user acknowledgement tied to actual input evidence.
Keep subtitle sidecar output completion and media identity intact when altering caption lifecycles.
Rendering/audio implementations are covered by [Platform/macOS](../Platform/macOS/AGENTS.md).
For playback integration, inspect `Scripts/test_file_core_headless.sh` and select suitable existing tests.
That script needs ffmpeg plus a built Debug media framework, or `ODF_TEST_FRAMEWORKS_DIR` pointing to matching products.
Headless and generated-fixture results have their stated format and backend scope.
Validate actual playback, seeking, subtitles, audio and HDR separately when the change affects them.
Keep large or private media fixtures and generated results outside tracked source.
