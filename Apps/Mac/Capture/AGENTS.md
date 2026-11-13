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
For capture and inference sizing or performance admission, follow the root [hardware optimization scope](../../../AGENTS.md#hardware-optimization-scope). Derive limits from the selected source and engine capabilities; do not turn a test machine's model identifier or screen dimensions into product eligibility rules. Keep model identifiers in diagnostic evidence, and preserve real API compatibility checks.
The automatic Fast X2 window fallback uses Metal/Apple GPU/unified-memory capabilities and a bounded BGRA capture budget, never model identifiers. Preparation first measures three warmed full-size inference jobs; preserve native dimensions when the median fits 75% of a display interval. Only a budget miss or preparation failure selects the shared 1080p-area fallback and its existing keeper/presenter. Unsupported fallback formats or refresh rates retain ordinary engine preparation. Preparation timings are not sustained FPS acceptance. File preparation remains separate.
UI selectors and persisted profile behavior belong to [UI](../UI/AGENTS.md).
File cadence and shared provider contracts belong to [VideoEnhancement](../../../Modules/VideoEnhancement/AGENTS.md).

## Focused verification

Choose the scripts relevant to the changed policy and read their prerequisites first.
`./Scripts/test_capture_callback_policy.sh` checks callback policy.
`./Scripts/test_capture_resize_policy.sh` checks resize state and stale callback guards.
`./Scripts/test_content_frame_gate.sh` checks content gating.
`./Scripts/test_output_geometry.sh` and `./Scripts/test_shared_geometry.sh` cover geometry policies.
`./Scripts/test_air_window_optimization.sh` checks GPU capability and native frame-budget admission.
`./Scripts/test_air_beta_sizing.sh` checks byte-bounded capture and adaptive processing sizing.
`bash Scripts/test_window_optimization_preparation.sh` requires the built Debug app and runs real GPU preparation/generation for native and forced-budget fallback, ordinary preparation and oversized rejection. It does not capture or present a window.
These checks do not establish Screen Recording permission, real source capture or physical output correctness.
For a live task, record selected source, dimensions, generation/configuration and actual presented output.
Capture, requested target and presented FPS are separate measurements.
Keep diagnostic hooks task-scoped and gated; remove temporary instrumentation before delivery.
