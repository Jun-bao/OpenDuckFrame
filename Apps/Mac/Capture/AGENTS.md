# Live capture and enhancement adapters

[WindowCapture.swift](WindowCapture.swift) contains WindowCaptureSource and ScreenCaptureKit selection/capture.
[SPLiveProcessor.h](SPLiveProcessor.h) defines live request and resolved-plan contracts.
[SPLiveProcessor.mm](SPLiveProcessor.mm) processes, schedules and presents live enhancement.
[SPRifeEngine.swift](SPRifeEngine.swift) bridges the pinned RIFE runtime.
The Apple and animation scaler adapters here also serve file playback through the media framework.
Read [project.yml](../project.yml) for their actual target membership.

## Preserve pipeline contracts

Keep source generation, configuration epochs, frame ownership, timestamps and cancellation coherent across asynchronous work.
Keep source identity separate from capture running state; Stop can retain a selectable source.
Preserve verified source/content geometry, Retina/display mappings and stale-frame rejection when following windows.
Keep capture callbacks distinct from source-content changes and physical presentation observations.
Apple low-latency live preparation fits inference to runtime size limits and restores generated frames to source dimensions. Keep the strict file preparation path separate. Report actual inference dimensions; reduced inference can soften generated detail and does not enable super resolution.
Apple low-latency enhanced live output requests at least 80 ms adaptive buffering within existing time/memory caps, and reuses the bounded temporal display queue. Keep this scoped to that engine/mode; preserve RIFE, FRC and source-only behavior.
The opt-in automatic-video mode samples six interior regions before inference queue eviction, estimates visible 24/25/30 FPS, and retimes full captures into rational 60 kHz PTS buckets. Sampling never alone discards picture detail: a bucket retains its latest full capture until closure. One owned pending capture is released on stop/context changes; old timers and model outputs retain revision/generation/clock guards. Detection failure uses source pictures. This mode requests 140 ms buffering within a 160 ms time cap and existing byte limits; it must not infer native-video cadence from whole-window callbacks.
UI selectors and persisted profile behavior belong to [UI](../UI/AGENTS.md).
File cadence and shared provider contracts belong to [VideoEnhancement](../../../Modules/VideoEnhancement/AGENTS.md).

## Focused verification

Choose the scripts relevant to the changed policy and read their prerequisites first.
`./Scripts/test_capture_callback_policy.sh` checks callback policy.
`./Scripts/test_capture_resize_policy.sh` checks resize state and stale callback guards.
`./Scripts/test_content_frame_gate.sh` checks content gating.
`./Scripts/test_apple_live_size.sh` uses the built Debug app for real Apple inference, large/portrait input geometry and live plan activation; it does not record or present a window.
`./Scripts/test_live_display_queue.sh` checks queue selection and bounded temporal order on CPU. `./Scripts/probe_apple_live_presentation.sh OUTPUT.json [steady|jitter]` opens a 23-second synthetic test window using the built Debug app's processor/presenter. It records actual drawable presentation, not ScreenCaptureKit or user-media acceptance.
`./Scripts/test_video_cadence.sh` covers estimation, still scenes, rate changes and rational retiming. The visible probe also accepts `source25`, `auto24`, `auto25`, `auto30` (26 seconds); automatic profiles must actually detect their source rate and release pending capture on stop.
`./Scripts/test_output_geometry.sh` and `./Scripts/test_shared_geometry.sh` cover geometry policies.
These checks do not establish Screen Recording permission, real source capture or physical output correctness.
For a live task, record selected source, dimensions, generation/configuration and actual presented output.
Capture, requested target and presented FPS are separate measurements.
Keep diagnostic hooks task-scoped and gated; remove temporary instrumentation before delivery.
