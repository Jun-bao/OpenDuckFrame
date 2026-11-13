# Mac interface

Own native windows, menus, player interaction and enhancement configuration here.
[AppDelegate.swift](AppDelegate.swift) handles app lifecycle and open actions.
[PlayerViewController.swift](PlayerViewController.swift) connects playback, chrome and file enhancement.
[PlayerWindowController.swift](PlayerWindowController.swift), [MainMenu.swift](MainMenu.swift) and [SPChrome.swift](SPChrome.swift) own their native presentation.

## Enhancement workbench

[Enhancement/EnhancementWorkbench.swift](Enhancement/EnhancementWorkbench.swift) owns profiles, migration, configuration actions, source/output controls and the workbench window.
[Enhancement/LiveFPSOverlay.swift](Enhancement/LiveFPSOverlay.swift) formats live FPS observations.
The engine selector offers ODF-VFI (default), Apple low latency and Apple FRC. Preserve each engine when loading and saving profiles. ODF-VFI has fast/balanced/hq tiers; persisted `rife-v4.25` identifiers remain for compatibility. Apple low latency uses X2/X4 for live capture and X2 for files, without fixed FPS or X3. FRC has standard/quality tiers for live capture and standard for files. Keep rate controls and quality choices consistent with the selected source and engine.
The workbench offers Apple low-latency and Apple video super resolution; preserve the disabled-by-default scale switch and migrate legacy scaler profiles without altering frame-generation settings.
The workbench always shows enhanced output; legacy original/compare view settings migrate to enhanced.
Keep continuous stream caching enabled by default and window output fixed to follow with mouse passthrough.
The normal countdown defaults to 3 seconds; keep saved countdown and custom settings working.
Hardware/configuration auto-detection is deferred. Keep its suggestions and scoring out of ordinary controls.
Preserve configuration add/rename/delete, preset metadata and saved-profile migration.
The three-step first-use coach marks are implemented in [WorkbenchOnboarding.swift](Enhancement/WorkbenchOnboarding.swift); keep them skippable, source-specific and replayable from Help.
Preserve the no-source delayed window-selection path, countdown cancellation, restart after Stop and pending Apply Changes actions.
File output retains its fullscreen control; display and window output follow their source without a fullscreen preview option.
The workbench is a compact controls-only window. Keep its preview endpoint disconnected; file video stays in the player and live enhancement uses its actual output view.

## UI validation

Run `./Scripts/test_workbench_store.sh` for profile, countdown or workbench action changes.
Run `./Scripts/test_workbench_guide.sh` for coach-mark preferences, navigation and source-specific guidance.
Use the existing localization catalog and EnhancementText flow according to the current surface.
Verify actual English/Chinese, light/dark, source types, long names and keyboard actions when affected.
Check default 560×700, minimum 540×620, native fullscreen and ordinary window resizing for layout changes.
Keep the controls usable when parameters scroll.
Preferred fill constraints must yield to window resizing; AppKit's window size priority is 500.
Native rendering and real controls are the UI acceptance evidence. Parse or store tests cover a narrower layer.
Coordinate live pipeline changes with [Capture](../Capture/AGENTS.md) and shared file playback with [Modules](../../../Modules/AGENTS.md).
