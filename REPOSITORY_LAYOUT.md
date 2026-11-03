# Repository layout

OpenDuckFrame separates product-specific source from media and subtitle code and from
platform implementations. These directories describe source ownership, not
independent frameworks or Swift packages. Only the Mac product currently
builds; the layout prepares for a future iPhone and iPad product without
claiming iOS support.

```text
Apps/
  Mac/
    project.yml           Mac XcodeGen project definition
    project.sparkle.yml   Optional direct-distribution updater configuration
    Scripts/build.sh      Mac product build entry point
    Info.plist            Main app metadata
    UI/                   AppKit windows, controls, menus, and product behavior
    Resources/            Mac localization, icons, and privacy manifest
    Support/              Swift bridging header
    QuickLook/            Finder preview extension and its configuration
    CaptionsHost/         Mac subtitle tasks, presentation, and download adapters
    CaptionsUI/           Lazily loaded SwiftUI language-download host
  Mobile/                 Planned iPhone and iPad product; README only
Modules/
  MediaCore/
    Core/                 Container, queue, and playback helpers
    Bridge/               Media interfaces and Objective-C++ implementations
    Shaders/              Playback shaders
  Captions/               Subtitle models, formats, scheduling, and transcription
  VideoEnhancement/       Motion+ planning, frame generation, and lazy Metal kernels
Platform/
  macOS/
    Audio/                Mac audio-output implementation
    Rendering/            Mac Metal-rendering implementation
Scripts/                  Repository tools, dependency recipes, and release tools
ThirdParty/               Dependency lock, licenses, and ignored macOS artifacts
Design/                   Editable app-icon source and static exports
```

## Build and release entry points

Run these commands from the repository root:

```bash
./Apps/Mac/Scripts/build.sh Debug
./Apps/Mac/Scripts/build.sh Release
./Scripts/run.sh
python3 Scripts/l10n.py check --full
```

The root `Scripts/build.sh` is an `exec` compatibility wrapper. It preserves
arguments, environment settings, and the product build's exit status. Existing
commands that use that entry point remain valid.

Edit `Apps/Mac/project.yml` and its adjacent Sparkle include for Mac project
changes. The build generates `Apps/Mac/OpenDuckFrame.xcodeproj`; it is ignored and
must not be edited as the source of truth. Running `xcodegen` without an
explicit project definition from the repository root is no longer sufficient.
Use the build entry point so that dependency and distribution configuration
are prepared together.

Build products remain under the repository-root `.build` directory. Release
builds also deploy `OpenDuckFrame.app` to the repository root; Debug builds do not
replace it. Neither location is tracked by Git. Signing, archive, App Store
smoke checks, notarization, and DMG tools remain in `Scripts/`; their output
locations and distribution channels are described in [RELEASING.md](RELEASING.md).

## Current compilation boundaries

The `OpenDuckFrame` app compiles `Apps/Mac/UI`, `Apps/Mac/CaptionsHost`, and
`Modules/Captions`. `OpenDuckFrameMediaCore` still combines `Modules/MediaCore`
with `Modules/VideoEnhancement` and the implementations under `Platform/macOS`
in one framework. Quick Look
uses that same media framework. `OpenDuckFrameCaptionsUI` remains a separate,
lazily loaded Mac framework; it is distinct from `CaptionsHost`.

Motion+ uses a separately compiled `FrameBudget.metallib` in the media framework.
It is loaded on demand, not by the normal renderer while Motion+ is off.

Moving a source file into `Modules` does not remove its current dependencies.
The playback host still uses AppKit, rendering still depends on Mac displays,
audio still uses desktop device APIs, and subtitle services still depend on
their app host. Mobile work must adapt those interfaces, file access, resource
lookup, and task lifecycles before reusing them in a shipping product.

Third-party recipes currently produce macOS libraries only. iOS device and
simulator artifacts will need separate SDK-specific builds. No iOS target,
bundle identifier, signing setup, or purchase integration is supplied by this
directory layout. See [Apps/Mobile/README.md](Apps/Mobile/README.md) for scope.
