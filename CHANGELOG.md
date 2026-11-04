# Changelog

All notable public releases will be documented here.

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
