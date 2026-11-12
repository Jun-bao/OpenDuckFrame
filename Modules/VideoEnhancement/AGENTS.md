# Frame generation, scheduling and file scaling

[SPFrameGeneration.h](SPFrameGeneration.h) defines the shared core/generator contract.
[SPRateSchedule.hpp](SPRateSchedule.hpp) and [SPRateBudget.hpp](SPRateBudget.hpp) own rational schedules and rate admission.
SPPresentationOrder, SPPresentationBudget and SPPresentationGeometry cover output policy.
The SPFile* providers/scalers integrate decoded files with frame generation and scaling.
Live adapters remain in [Apps/Mac/Capture](../../Apps/Mac/Capture/AGENTS.md).

## Contracts to preserve

Keep rational source PTS, original frame pairs, source generations and configuration epochs intact.
Cancellation, seek and mode changes must reject stale work and retain valid source fallback behavior.
Track actual generated and presented frames separately from scheduled holds and skipped work.
A fixed FPS request or multiplier defines a target; achieved presentation also depends on display and processing limits.
The workbench exposes ODF-VFI (default), Apple low latency and Apple FRC; the internal `rife-v4.25` identifier remains for compatibility. Private comparison backends do not automatically become public choices.
Preserve model identity, quality tier, dimensions, padding, color metadata and cache semantics in comparisons.

## Verification entry points

Policy sources have focused tests in [Tests](Tests/) with wrappers under Scripts.
Use `./Scripts/test_rate_budget.sh` for budget and FPS HUD behavior.
Use `./Scripts/test_presentation_order.sh` or `./Scripts/test_presentation_budget.sh` for their respective policies.
Read file-provider/scaler test scripts before running them; some need built frameworks, models, macOS features or GPU work.
Select the existing test that exercises the changed normal entry point.
[Shaders/FrameBudget.metal](Shaders/FrameBudget.metal) produces lazily loaded FrameBudget.metallib in the media framework.
Keep it separate from the normal playback shader library and preserve the Motion+ disabled path.
Component output, inference throughput and physical presented FPS have different acceptance scopes.
Record failures and actual denominators; Air-specific or simulated results stay limited to their recorded conditions.
