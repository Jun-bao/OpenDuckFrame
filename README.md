<p align="center"><img src="Design/AppIcon/AppIcon.appiconset/AppIcon-256.png" alt="OpenDuckFrame" width="128" height="128"></p>
<h1 align="center">OpenDuckFrame</h1>
<p align="center"><b>Real-time frame generation and upscaling for your Mac.</b></p>
<p align="center">Choose a window, a display, or a video. Make it smoother. Make it clearer.</p>
<p align="center"><a href="https://openduckframe.cn/en/">Official website</a> · <b>English</b> · <a href="README.zh-CN.md">简体中文</a></p>
<p align="center">Apple silicon · macOS 14+ · <a href="LICENSE">MIT</a></p>

First use and resetting the default preset select **Apple low latency, X2** on supported macOS 26+ devices, with ODF-VFI fast X2 as the fallback on other supported Macs. Saved engine choices are preserved. ODF-VFI remains selectable: it is a four-stage structural reduction of RIFE 4.25 using the upstream weights without retraining. Existing RIFE 4.25 profiles remain compatible and run ODF-VFI; the app validates the actual four-stage weights when loading. Visual results remain content-dependent.

## About

OpenDuckFrame is a native Mac app that enhances the picture you are already watching.
Select a browser window, game or stream, a display, or a local video file, then
control frame generation and upscaling from one workbench. Processing happens on
your Mac, without an account or uploading your picture.

- **Frame generation.** Choose Apple low latency (default where supported), ODF-VFI, or Apple FRC.
  Available frame-rate and quality settings follow the selected engine and source;
  Apple options require runtime hardware/system support. Watch the actual output rate.
  Achieved performance depends on the source, settings and Mac.
- **Upscaling.** Choose Apple real-time or Apple video super resolution on supported macOS 26+ systems. Larger inputs may be reduced before processing. Live Apple video SR currently requires frame generation to be off.
- **A workbench for everyday use.** Save profiles for games, films and animation.
  Window and display output follow the
  source; video-file output can go fullscreen on a selected display.
- **A local video player, too.** Open formats including MKV, MP4, MOV and WebM,
  with subtitles, HDR playback on compatible displays, playback resume, speed
  control, and Finder Quick Look previews.
- **On-device subtitles.** Generate, translate and export text subtitles on
  supported macOS versions. macOS may download its language models first.
- **Private by design.** No account, ads, or playback analytics. See [PRIVACY.md](PRIVACY.md).

The player has 17 interface languages; the enhancement workbench supports Chinese
and English. Experimental backends and constraints are described in [the feature guide](docs/features.md).

<p align="center"><img src="Website/assets/openduckframe-library-v2.webp" alt="The OpenDuckFrame v0.1.0 technology library on macOS" width="900"></p>
<p align="center"><sub>Earlier v0.1.0 interface. The current technology library lists ODF-VFI and two Apple interpolation options.</sub></p>

## Get started

Download the [Mac app](https://github.com/Jun-bao/OpenDuckFrame/releases/latest/download/OpenDuckFrame.dmg)
or [browse releases](https://github.com/Jun-bao/OpenDuckFrame/releases).
The community download is ad-hoc signed and **not Apple notarized**, so macOS may
block its first launch. Only allow it in System Settings → Privacy & Security if
you trust the source. Updates may require granting Screen Recording or
Accessibility access again because this community lane uses ad-hoc signing. Apple silicon and macOS 14+ are required.

The app checks for signed updates and lets you choose when to install them.
You can also use **OpenDuckFrame → Check for Updates**, or disable automatic
checks from the same menu. Updating never uploads your media.

1. Open **File → Quality Workbench** (⇧⌘E).
2. Choose a window, display, or video file input. macOS asks for Screen Recording
   permission when you capture a window or display.
3. Choose frame generation, upscaling, or both. For a window, press **Delayed Enhancement**
   and switch to the window you want before the countdown ends; that window is
   selected and enhanced automatically. The countdown defaults to 3 seconds and can
   be set from 1 to 20 seconds in the workbench **Settings**. For a display or
   video file, press **Start Enhancement**.
4. Watch the enhanced output and use the FPS display to observe the output rate.

See [Quick start](docs/quick-start.md) for permissions and troubleshooting.

## Requirements

| Capability | Requirements |
|---|---|
| App and local playback | Apple silicon Mac, macOS 14 or later |
| Window / display capture | Screen Recording permission; protected content may not be capturable |
| Apple low-latency interpolation | macOS 26+ and runtime support; live X2/X4, file X2 |
| Apple FRC | macOS 15.4+ and runtime support; quality-oriented, added delay and speed vary |
| Apple super resolution | macOS 26+ and a supported Mac; sizes and factors depend on the processor; video SR may download an Apple model |
| ODF-VFI frame generation | Apple silicon; throughput depends on resolution, quality and display rate |
| Subtitle generation and translation | macOS 26+ and an available system language model |
| Experimental animation backends | Additional models / runtimes; see [features](docs/features.md) |

Intel Macs, Windows, iPhone and iPad are not currently supported. A multiplier is
a requested processing mode, not a guarantee of a particular displayed frame rate.

Live Apple low latency fits inference to the device's supported size and restores
generated frames to source dimensions. The workbench shows the inference size;
reduced inference can soften generated detail. File input retains its native size requirements.
Enhanced live output also reserves at least 80 ms of adaptive buffering, subject to
time/memory caps, and keeps eligible frames in order within a bounded lag window.
This trades some input responsiveness for more consistent delivery; it does not guarantee 60 FPS.
Version 0.5.0 adds optional **Automatic video** timing for live Apple
low latency. It estimates common 24/25/30 FPS content and evens out its timeline,
requesting extra buffering (140 ms, subject to limits). General window remains the
default. Audio stays in the source app, so audio/video offset may be noticeable.

Fast X2 window optimization uses GPU capabilities, memory limits and measured
preparation timing instead of a device-model whitelist. It keeps native dimensions
when the preparation budget fits; otherwise it reduces the generated-frame
processing size. Preparation timing is not a sustained-FPS guarantee.

When local-video frame generation cannot keep up, the original picture is kept and
late generated frames are discarded instead of delaying playback. This does not
mean the selected multiplier is reached on a slower Mac.

## Build from source

Use an Apple silicon Mac with Xcode and the macOS 26.4 SDK or later, Python 3,
and these build tools:

```sh
brew install xcodegen meson ninja cmake pkg-config
git clone https://github.com/Jun-bao/OpenDuckFrame.git
cd OpenDuckFrame
./Apps/Mac/Scripts/build.sh Debug
open .build/Build/Products/Debug/OpenDuckFrame.app
```

For an optimized local build:

```sh
./Apps/Mac/Scripts/build.sh Release
```

The build fetches pinned dependencies, generates the Xcode project, bundles runtime
libraries and verifies the application. Debug output stays under `.build/`; Release
also publishes a local `OpenDuckFrame.app` at the repository root. Local builds use
ad-hoc signing. Developer ID signing, notarization and App Store packaging have
their own [release workflow](RELEASING.md).

RifeMetal is prepared from a pinned source archive with the local stream IO
patch before project generation. See [the runtime recipe](ThirdParty/rife-metal/README.md)
for provenance, licenses and the generated package boundary.

Edit [`Apps/Mac/project.yml`](Apps/Mac/project.yml), not the generated Xcode project.
Optional experimental runtimes are not built by default; see [the feature guide](docs/features.md#optional-runtimes).

## Repository

```text
Apps/Mac/          Native UI, live capture, resources, Quick Look and build definition
Modules/           Media playback, video enhancement and subtitle source
Platform/macOS/    Mac rendering and audio implementations
Scripts/           Build, verification, localization and release tools
ThirdParty/        Dependency lock, selected source and license notices
Design/            App icon source and deterministic exports
Website/           Earlier static page and README images; openduckframe.cn is maintained separately
docs/              Getting started, features and project documentation
```

These are source boundaries, not independently released packages. See
[REPOSITORY_LAYOUT.md](REPOSITORY_LAYOUT.md) for compilation and ownership details.
Generated projects, apps, dependency builds, private keys, local logs and test media stay outside Git.

## Community and contributing

Use [Issues](https://github.com/Jun-bao/OpenDuckFrame/issues) for bugs and
feature requests, and [Discussions](https://github.com/Jun-bao/OpenDuckFrame/discussions)
for questions and setup sharing. Include app and macOS versions, Mac model, source
resolution, engine and observed output rate. Review logs and screenshots for private content before sharing.

[CONTRIBUTING.md](CONTRIBUTING.md) covers development and checks;
[SECURITY.md](SECURITY.md) explains private vulnerability reporting.
See [CHANGELOG.md](CHANGELOG.md) for changes.

## License and acknowledgments

OpenDuckFrame's own code is [MIT-licensed](LICENSE). It builds on
[Khua Player](https://github.com/nake13/khuaplayer) and preserves its copyright notice.
FFmpeg, RIFE, model weights and other dependencies retain their own licenses;
see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
See [TRADEMARK.md](TRADEMARK.md) for the project name and icon.
