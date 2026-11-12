# Changelog

All notable public releases will be documented here.

## 0.4.0 — 2026-11-12

- Redesign the compact workbench with grouped settings, aligned control columns,
  independent scrolling, and fixed source and run-action areas.
- Add ArtCNN C4F32/C4F16 native 2× SDR super resolution for live and file inputs.
- Add a skippable, replayable three-step guide for selecting and enhancing a source.
- Keep signed in-app update delivery. Community builds remain ad-hoc signed and
  not Apple notarized; macOS may request permissions again after an update.

## 0.3.1 — 2026-11-10

- Automatically select the optimized live-window pipeline on M3 MacBook Air
  for RIFE 4.25 / Fast / X2 with stream caching enabled and scaling disabled.
- Fuse conversion and resize work, reuse prepared GPU textures, and align
  presentation with actual source intervals. Generated pictures use adaptive
  lower-resolution inference and reconstruction; originals retain capture size.
- Restrict this path to SDR BT.709, 60 Hz and captures up to 2648×1668 pixels.
  Unsupported inputs in the optimized path use original-picture passthrough
  with an explanation in the existing status area.
- Preserve the existing workbench controls and use a three-second default
  delayed-enhancement countdown.

## 0.3.0 — 2026-11-06

- Add delayed window enhancement: focus a window during the full-screen
  countdown and start automatically when it ends. Settings preserve a 1–20
  second countdown, with a 5 second default.
- Add workbench language and appearance settings alongside the project links.
- Reduce live RIFE target-FPS inference work by retaining source pictures,
  scheduling interpolation from timestamps and admitting only jobs within the
  output budget. Slow jobs fall back to source pictures without inflating the
  motion-frame counter.
- Validate 28→60 and 30→60 controlled model scheduling. These queue measurements
  do not establish physical-display performance or compatibility with every app.

## 0.1.2 — 2026-11-04

- Bound local-file frame-generation waits so a slow model no longer holds up
  original frames indefinitely. Late synthetic frames fall back to the original.
- Keep current-provider errors visible after a frame's deadline, while ignoring
  results from a previous video or plan.
- Validate slow-model playback, seek/replacement, decoded cadence combinations
  and file-player transactions. This does not establish M1 Pro physical-display
  performance or guarantee the requested multiplier.

## 0.1.0 — Unreleased

- Prepare the public source repository with bilingual documentation, getting
  started and feature guides, contribution templates and automated checks.
- First OpenDuckFrame release: real-time frame generation and upscaling for a
  selected window, display or video file, with a frame-rate overlay.
- Detects the real content frame rate, lowers the multiplier automatically when
  the Mac cannot keep up, and passes frames through at the display limit.
- Plays local video files with subtitles, Quick Look previews and an interface
  in 17 languages.
- Ships without an update feed until the official one is available.
