# Quick start

## Choose what to enhance

Open **File → Quality Workbench** (⇧⌘E) and select the input type:

- **Window:** choose a browser, game, player, or streaming application's window.
- **Display:** choose the display to capture. Avoid including the output window
  inside the captured area, which can create visual feedback.
- **Video file:** open a local file and use its decoded video directly.

A capture card can be used through a preview window in an application such as
OBS; OpenDuckFrame does not expose a separate capture-card input.

For window and display capture, grant Screen Recording access in **System
Settings → Privacy & Security** when macOS prompts. The precise setting name
varies by macOS version. If access is denied, change it there and reopen the app
when macOS requests it. Video-file playback does not need capture permission.
Community updates are ad-hoc signed, so macOS may ask for capture or
Accessibility permission again after an upgrade.

## Start with a simple setup

On a fresh installation, frame generation is enabled with ODF-VFI, fast
quality, and X2 rate. Window output follows the source, and scaling is off.
Continuous caching is always on; there is no separate switch to find or enable.
Existing saved settings are retained, and profiles saved with RIFE 4.25 use
ODF-VFI; a new named configuration copies the current settings.

1. Select the source. Display and video-file inputs can also use a selected
   output display.
2. Choose ODF-VFI, Apple low latency, or Apple FRC in the engine selector.
   Apple options require system/hardware support; low latency offers live X2/X4
   and file X2, while FRC can add processing delay. Start with one enhancement:
   frame generation at X2, or Apple real-time super resolution. Apple video SR
   is also available on supported devices; live video SR requires frame generation
   to be off. Higher resolutions and multipliers require more processing time.
3. For a window, press **Delayed Enhancement**, then focus the window you want
   to enhance before the countdown ends. The focused window is selected and
   enhancement starts automatically. The countdown defaults to 3 seconds and
   can be set from 1 to 20 seconds in **Settings**. Display and video-file inputs
   keep **Start Enhancement**. Compare **Original**, **Enhanced**, and
   **Comparison** views in the output settings; use the FPS overlay to observe actual output.
4. Save a profile once you have settings that work for your content.

Frame generation creates intermediate pictures; it does not change the source
application's simulation rate or recover detail that was never present.
Performance, latency and artifacts vary with motion, resolution and backend.

## If the picture or rate is unexpected

- **Absent capture:** check permission and source selection. Protected content
  may not be capturable.
- **Output below target:** try X2, a lower resolution, or a lighter quality mode.
  A 60 Hz output display cannot present 120 distinct frames per second.
- **Softness or motion artifacts:** compare at the same output size, then switch
  the scaling technology or disable one enhancement to identify the stage that
  changes the picture.
- **Unavailable engine:** check the [feature requirements](features.md). Some
  backends need newer macOS, a specific input size, or an optional runtime.
- **Resize / fullscreen problems:** reselect the source and report the source
  application, size and fullscreen mode if the problem persists.

## Report a problem

Use the [bug form](https://github.com/Jun-bao/OpenDuckFrame/issues/new?template=bug_report.yml).
Include app and macOS versions, Mac model, source type and resolution, engine,
requested rate, actual output and reproduction steps. Inspect logs and screenshots
before sharing: window titles and media paths can be personal.
