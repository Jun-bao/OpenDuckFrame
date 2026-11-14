# Mac product

This directory owns the shipping macOS targets and their product integration.
The source ownership and compilation map is in [REPOSITORY_LAYOUT.md](../../REPOSITORY_LAYOUT.md).

## Entry points

- [project.yml](project.yml) defines targets, sources, resources, build settings and version/build values.
- [project.sparkle.yml](project.sparkle.yml) adds the direct-distribution updater.
- [Info.plist](Info.plist), entitlements and [QuickLook/Info.plist](QuickLook/Info.plist) define app and extension identity.
- [UI/AGENTS.md](UI/AGENTS.md) covers AppKit interaction. [Capture/AGENTS.md](Capture/AGENTS.md) covers live input and processing.
- `CaptionsHost/` connects caption tasks to the Mac app; `CaptionsUI/` is the lazily loaded download UI framework.
- `QuickLook/Preview/` hosts Finder previews with the shared media framework.

## Build and integration

Use `./Apps/Mac/Scripts/build.sh Debug` for a task that needs compilation.
Edit the project definitions above. XcodeGen recreates the ignored `OpenDuckFrame.xcodeproj`.
Selected scaler adapters under Capture compile into OpenDuckFrameMediaCore; inspect project.yml before moving files.
The shared directories compile into existing targets and retain their current Mac dependencies.
Run `python3 Scripts/l10n.py check --full` for string or localization changes.
English is the catalog source language; preserve placeholders and all supported translations.
Check app identity, privacy manifests and Quick Look whenever changing resources or entitlements.

## Build side effects and delivery

Release builds deploy `OpenDuckFrame.app` at the repository root and explicitly register that app and Quick Look.
Debug products remain under `.build/Build/Products/Debug/`; opening them can still create an additional launch entry.
[Scripts/run.sh](../../Scripts/run.sh) builds and opens that Debug product.
For normal delivery, reconcile copies and registrations with the root rule for `/Applications/OpenDuckFrame.app`.
Verify the exact running binary and version/build before using its UI as evidence.
App Store, ad-hoc community and Developer ID lanes have distinct signing and packaging requirements.
Read [RELEASING.md](../../RELEASING.md) before changing distribution behavior.

## Permission continuity when replacing an app

Compare the existing and replacement apps' designated signing requirements before replacing the installed app. Ad-hoc signatures can change with each build, so a macOS privacy switch may remain enabled for an older identity while the new app has no access. Prefer an appropriate stable signing identity for successive local test builds when one is available; an Apple Development identity is for local testing and is not a Developer ID release or notarization.

After installation, verify the running app's actual Screen Recording access and ability to refresh the window list, rather than treating the Settings toggle as proof. Also check other permissions needed by the requested feature, such as Accessibility or Input Monitoring for interactive input; do not prompt for unrelated capabilities. Preserve user profiles and existing permissions; change or reset only this app's relevant authorization when necessary and authorized. If macOS requires the user to confirm, unlock or reopen the app, surface that requirement without attempting to bypass it. Record the app version/build, signing lane and verification result; do not put certificate identities, credentials or machine-specific paths in this repository.
