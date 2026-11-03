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

## Start with a simple setup

1. Select the source and output display.
2. Start with one enhancement: frame generation at X2, or Lanczos / MetalFX
   scaling. Higher resolutions and multipliers require more processing time.
3. Press **Start enhancement**. Compare **Original**, **Enhanced**, and
   **Comparison** views; use the FPS overlay to observe actual output.
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
  engine or disable one enhancement to identify the stage that changes the picture.
- **Unavailable engine:** check the [feature requirements](features.md). Some
  backends need newer macOS, a specific input size, or an optional runtime.
- **Resize / fullscreen problems:** reselect the source and report the source
  application, size and fullscreen mode if the problem persists.

## Report a problem

Use the [bug form](https://github.com/Jun-bao/OpenDuckFrame/issues/new?template=bug_report.yml).
Include app and macOS versions, Mac model, source type and resolution, engine,
requested rate, actual output and reproduction steps. Inspect logs and screenshots
before sharing: window titles and media paths can be personal.
