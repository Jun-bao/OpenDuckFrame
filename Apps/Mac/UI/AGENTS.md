# Mac interface

Own native windows, menus, player interaction and enhancement configuration here.
[AppDelegate.swift](AppDelegate.swift) handles app lifecycle and open actions.
[PlayerViewController.swift](PlayerViewController.swift) connects playback, chrome and file enhancement.
[PlayerWindowController.swift](PlayerWindowController.swift), [MainMenu.swift](MainMenu.swift) and [SPChrome.swift](SPChrome.swift) own their native presentation.

## Enhancement workbench

[Enhancement/EnhancementWorkbench.swift](Enhancement/EnhancementWorkbench.swift) owns profiles, migration, configuration actions, source/output controls and the workbench window.
[Enhancement/LiveFPSOverlay.swift](Enhancement/LiveFPSOverlay.swift) formats live FPS observations.
The visible interpolation model is ODF-VFI, with fast/balanced/hq tiers; persisted `rife-v4.25` identifiers remain for compatibility.
Keep continuous stream caching enabled by default and window output fixed to follow with mouse passthrough.
The normal countdown defaults to 3 seconds; keep saved countdown and custom settings working.
Hardware/configuration auto-detection is deferred. Keep its suggestions and scoring out of ordinary controls.
Preserve configuration add/rename/delete, preset metadata and saved-profile migration.
Preserve the no-source delayed window-selection path, countdown cancellation, restart after Stop and pending Apply Changes actions.
Display and file output retain their fullscreen controls; window follow uses its existing source-aligned behavior.

## UI validation

Run `./Scripts/test_workbench_store.sh` for profile, countdown or workbench action changes.
Use the existing localization catalog and EnhancementText flow according to the current surface.
Verify actual English/Chinese, light/dark, source types, long names and keyboard actions when affected.
Check default 1180×700, minimum 840×620, native fullscreen and ordinary window resizing for layout changes.
Keep the preview aspect-fitted and the 300pt control column usable when parameters scroll.
Preferred fill constraints must yield to window resizing; AppKit's window size priority is 500.
Native rendering and real controls are the UI acceptance evidence. Parse or store tests cover a narrower layer.
Coordinate live pipeline changes with [Capture](../Capture/AGENTS.md) and shared file playback with [Modules](../../../Modules/AGENTS.md).
