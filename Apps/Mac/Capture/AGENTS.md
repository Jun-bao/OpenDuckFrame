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
UI selectors and persisted profile behavior belong to [UI](../UI/AGENTS.md).
File cadence and shared provider contracts belong to [VideoEnhancement](../../../Modules/VideoEnhancement/AGENTS.md).

## Focused verification

Choose the scripts relevant to the changed policy and read their prerequisites first.
`./Scripts/test_capture_callback_policy.sh` checks callback policy.
`./Scripts/test_capture_resize_policy.sh` checks resize state and stale callback guards.
`./Scripts/test_content_frame_gate.sh` checks content gating.
`./Scripts/test_apple_live_size.sh` uses the built Debug app for real Apple inference, large/portrait input geometry and live plan activation; it does not record or present a window.
`./Scripts/test_output_geometry.sh` and `./Scripts/test_shared_geometry.sh` cover geometry policies.
These checks do not establish Screen Recording permission, real source capture or physical output correctness.
For a live task, record selected source, dimensions, generation/configuration and actual presented output.
Capture, requested target and presented FPS are separate measurements.
Keep diagnostic hooks task-scoped and gated; remove temporary instrumentation before delivery.
