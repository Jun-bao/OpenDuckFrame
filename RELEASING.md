# Releasing OpenDuckFrame

This document describes the macOS release workflows. Run its commands from
the repository root. The Mac project definition and product build entry point
are `Apps/Mac/project.yml` and `Apps/Mac/Scripts/build.sh`; repository-level
archive, signing, packaging, and verification tools remain in `Scripts/`.
`Scripts/build.sh` forwards to the Mac build for compatibility. There is no
iPhone or iPad release workflow yet.

OpenDuckFrame uses a dedicated App Store build configuration and the standard
Xcode archive/export pipeline. A release archive is immutable: do not copy
libraries into it, regenerate resources, change extended attributes, or re-sign
it after `xcodebuild archive` completes.

The local `Debug`/`Release` lane is intentionally unsandboxed and uses
`Scripts/bundle_libs.sh` for ad-hoc packaging only. The `AppStore`
lane never invokes that bundler: Xcode embeds and signs every component and
applies `Apps/Mac/OpenDuckFrame.entitlements` during the archive build.

CI also runs `Scripts/smoke_app_store_unsigned.sh`. It archives the exact
`AppStore` configuration, including the `SP_APP_STORE` compilation condition,
with Xcode's signing phases fully disabled. The script checks the packaged app,
Quick Look extension, media framework, privacy manifests, libass, Mach-O
closure, absence of provisioning/resource signatures, and absence of
`BuildManifest.json`. This gives pull requests App Store-specific compile and
packaging coverage without a Team ID or certificate, but it does not replace
the distribution-signed archive validation described below.

## Version and build policy

The public version identifies a feature release; the build number identifies a
particular distributable build of that release. Select the public version from
the actual changes, not the number of commits or lines changed:

- New user-visible features increment the minor component and reset the patch
  component, for example `0.2.3` to `0.3.0`.
- Fixes, performance improvements, or refactoring without new user-visible
  features increment the patch component, for example `0.2.3` to `0.2.4`.
- Major-version changes, including the first stable `1.0.0`, require an explicit
  maintainer decision.
- Choose one public version per reviewed source-update batch. Repeating an
  export, retrying a failed build, or rebuilding the same batch does not
  repeatedly increment that version. If no shipping code, resources, or
  configuration changed, no new application version is needed.

Assign a positive, globally increasing build number to every new build handed
out for testing or release. Never reset it when the public version changes or
when reverting code. For example, testing can progress from `0.3.0 (12)` to
`0.3.0 (13)`, followed by a maintenance release `0.3.1 (14)`. Routine local
compiles do not require a new number. Retrying notarization or publication of
the exact same immutable artifact retains its existing numbers; distributing
a replacement build requires a new build number.

Roll back code, not published version numbers. If `0.3.0` must be replaced with
earlier code, release the replacement as `0.3.1` with a higher build number.
Only an unpublished draft may have its planned version reassigned by explicit
maintainer instruction. Never overwrite a published release tag or replace its
artifact with different bytes under the same version/build identity.

For local builds, set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
`Apps/Mac/project.yml`. For distribution builds, pass the intended values
explicitly as `--marketing-version` and `--build-number` to the archive/export
scripts.
Keep the main app and Quick Look extension aligned; the existing validators
check their packaged values. Identify an installed app using its welcome/About
version and build, not the Finder modification date of the outer app directory.

Record the OpenDuckFrame source commit, version, build, validation results, artifact
checksums, and distribution channel in the release record. This is a maintainer
workflow, not automatic numbering: the local build script does not allocate
versions or build numbers, and the app does not currently embed its source
commit. Automatic allocation and in-app source identification remain separate
future work.

## Motion+ packaging

Motion+ is enabled at compile time in Debug, Release, and AppStore configurations
through `SP_ENHANCE`. Runtime tier, hardware, and media checks still apply. The
media framework must contain both `default.metallib` and the lazily loaded
`FrameBudget.metallib`; packaging validators require both. Private interpolation
automation and stress controls are not part of the shipping source.

## Direct-distribution updates

### Community downloads without an Apple Developer account

The community lane uses an ad-hoc code signature and an independent EdDSA update
signature. It is not Apple notarized. Never describe this lane as Developer ID
signed, Gatekeeper approved or App Store approved. A user may need to allow the
first launch through macOS Privacy & Security.

`Distribution/sparkle.json` contains the public feed and public key. The private
key remains in the maintainer's login Keychain under the configured account;
it is never exported by the release script. Loss of that key can prevent existing
users from accepting future updates. Keep control of that Keychain and the GitHub
account. Forks should override both update settings with their own values or
explicitly set both to empty strings.

First compile and validate the desired Release app. Then package it using the
checkout that has its matching dependency stamps and Sparkle tools:

```sh
python3 Scripts/community_release.py \
  --app /path/to/OpenDuckFrame.app \
  --verification-root /path/to/matching-build-checkout \
  --version 0.1.0 --build-number 2 \
  --binary-source-commit FULL_40_CHARACTER_COMMIT \
  --notes Distribution/release-notes/0.1.0.html \
  --output .build/releases/0.1.0-2
```

This preserves the supplied app, verifies it, configures a separate copy, aligns
the Quick Look build, re-signs the changed bundles ad hoc, validates a ZIP round
trip, creates a DMG, and generates and verifies a signed appcast. Its release
record distinguishes the compiled binary's source from the packaging commit.
It does not claim a new compilation. Inspect and test these artifacts before
running the command with a fresh output path and `--publish`.

`--publish` publishes immutable assets under `v<version>` in GitHub Releases,
then commits the signed feed to `gh-pages`. Existing releases are never replaced;
the current feed is retrieved, its signature checked and its history preserved.
Build numbers must increase. GitHub Pages must serve the root of `gh-pages`.
For a first-time setup, enable that source in repository Pages settings.

Each subsequent version needs a new application build and notes. Follow the
version/build policy above. The fixed `OpenDuckFrame.dmg` asset name supports the
website's latest-download link; Sparkle uses the versioned ZIP URL from its signed
feed. Existing 0.1.0 local builds without update configuration must first be
replaced manually with an update-enabled download.

### Developer ID lane

`Debug` and `Release` builds include Sparkle and default to
`Distribution/sparkle.json`. The Developer ID archive script uses that same
configuration. Both values can be overridden together:

```sh
ODF_SPARKLE_FEED_URL=https://example.invalid/updates/appcast.xml \
ODF_SPARKLE_PUBLIC_ED_KEY=BASE64_PUBLIC_KEY \
  Apps/Mac/Scripts/build.sh Release
```

The two settings are all-or-none. Configured builds require signed appcasts and
verify update archives before extraction; anonymous system profiling remains
disabled. They check automatically by default, and users can disable automatic
checks from the App menu. Generate and protect the EdDSA key using the locked
Sparkle tools in `ThirdParty/sparkle-min/bin`, and keep the private key outside
the repository.

OpenDuckFrame builds never attach installation identifiers or other statistics
to update checks. `bundle_libs.sh` always ships the neutral privacy manifest.
The website in `Website/` is a static page with no build step.

The ordinary local lane remains ad-hoc signed and is not a publishable updater
artifact. Developer ID releases use the separate workflow below, which signs
inside-out, submits the exact transport archive for notarization, staples the
accepted ticket, and verifies the final archive. The `AppStore` project
generation disables the Sparkle include, and archive validation fails if the
framework or any updater configuration key is present.

## Developer ID direct distribution

Use a `Developer ID Application` certificate for the intended team. Store
Notary Service credentials once under a Keychain profile; never pass an
app-specific password on a command line or commit an App Store Connect private
key. This interactive example prompts securely for the password:

```sh
xcrun notarytool store-credentials odf-notary \
  --apple-id developer@example.com \
  --team-id ABCDE12345
```

Create a fresh signed release directory. The script builds the pinned runtime,
forces a secure timestamp and Hardened Runtime on every nested executable,
preserves the read-only Quick Look sandbox, rewrites the build manifest after
nested signing, retains UUID-matched dSYMs outside the transport ZIP, and
verifies a ZIP round trip before it can succeed:

```sh
Scripts/archive_developer_id.sh \
  --identity "Developer ID Application: Developer Name (ABCDE12345)" \
  --team-id ABCDE12345 \
  --bundle-id com.example.openduckframe \
  --marketing-version 1.0.0 \
  --build-number 1 \
  --output-dir .build/DeveloperID/OpenDuckFrame-1.0.0-1
```

First notarize the signed app and staple its ticket. This uses the prepared
ZIP as an upload container and also produces an optional `OpenDuckFrame.zip` download:

```sh
Scripts/notarize_developer_id.sh \
  --release-dir .build/DeveloperID/OpenDuckFrame-1.0.0-1 \
  --team-id ABCDE12345 \
  --keychain-profile odf-notary
```

The app needs its own stapled ticket to pass the standalone pre-distribution
checks, even when a notarized outer DMG passes Gatekeeper. On macOS versions
that provide the tool, also run `syspolicy_check distribution` on this app.
Do not re-sign or change the app after its ticket has been stapled.

Create the primary user-facing layout. It contains only `OpenDuckFrame.app` and a real
symbolic link to `/Applications`, then becomes a read-only UDZO disk image
signed with the same Developer ID identity. `OpenDuckFrame-notarization.dmg` is an
internal immutable submission artifact and must not be published. Packaging
and mounted-image verification both require a valid ticket on the inner app:

```sh
Scripts/create_developer_id_dmg.sh \
  --release-dir .build/DeveloperID/OpenDuckFrame-1.0.0-1 \
  --identity "Developer ID Application: Developer Name (ABCDE12345)" \
  --team-id ABCDE12345
```

Submit that signed DMG, wait for `Accepted`, retain Apple's log, staple the
ticket to a byte-for-byte copy, and publish the versioned final DMG:

```sh
Scripts/notarize_developer_id_dmg.sh \
  --release-dir .build/DeveloperID/OpenDuckFrame-1.0.0-1 \
  --team-id ABCDE12345 \
  --keychain-profile odf-notary
```

The final stage requires `hdiutil`, `codesign`, `stapler`, and Gatekeeper to
agree and verifies the contained app again after mounting. This second submission
notarizes the final DMG containing the already-stapled app; the final download
therefore carries both app and container tickets. Do not modify,
convert, lay out, or re-sign the submitted DMG after upload. Those operations
change its CodeDirectory and make the ticket impossible to staple.

Publishing the `OpenDuckFrame.zip` produced by the app-notarization stage is optional.
ZIP files cannot carry tickets themselves; that archive contains the stapled
app. A ZIP download is not needed for normal drag-to-Applications installation.

Test the downloaded DMG on a clean Mac or VM before publishing it or adding
the corresponding update archive to a signed Sparkle appcast.

Release apps, DMGs, ZIPs, dSYMs, and notarization records remain under
`.build/` and are intentionally ignored by Git. Publish the final versioned
`OpenDuckFrame-<version>.dmg` through a release host such as GitHub Releases or object
storage; do not commit binary artifacts to the source repository.

Always create Store archives with `Scripts/archive_app_store.sh`. A project
generated by `Apps/Mac/Scripts/build.sh` is marked as a direct-distribution
project; if someone later selects its `AppStore` configuration manually, an
early build guard fails instead of producing an archive that embeds Sparkle.

## Prerequisites

- A non-beta Xcode accepted by App Store Connect, with the macOS 26.4 SDK or
  later for the subtitle translation APIs. Confirm Apple's current submission
  requirements before publishing; a successful local build is not store approval.
- XcodeGen installed at `/opt/homebrew/bin/xcodegen`, on `PATH`, or selected via
  the `XCODEGEN` environment variable.
- Membership in the paid Apple Developer Program and access to the intended
  team in Xcode.
- An Apple Distribution certificate and Mac App Store provisioning profiles,
  or permission for Xcode to manage them.
- A final explicit App ID registered for the main app. The build also uses
  `<bundle-id>.QuickLook`, `<bundle-id>.MediaCore`, and `<bundle-id>.CaptionsUI`.
- A matching macOS app record in App Store Connect.

Release scripts never infer the bundle identifier from the repository defaults.
Pass the final registered identifier explicitly on every archive and export
invocation, even if it currently matches the value in `Apps/Mac/project.yml`.

## 1. Create the archive

Choose a new archive path. The script refuses to overwrite an existing archive.

```sh
Scripts/archive_app_store.sh \
  --team-id ABCDE12345 \
  --bundle-id com.example.openduckframe \
  --marketing-version 1.0.0 \
  --build-number 1 \
  --archive-path .build/AppStore/OpenDuckFrame-1.0.0-1.xcarchive \
  --allow-provisioning-updates
```

`--allow-provisioning-updates` is optional. Omit it when all signing assets are
already installed and no Developer Portal changes should be allowed.

The archive script runs these stages in order:

1. Builds the pinned FFmpeg/dav1d dependencies.
2. Builds the pinned subtitle dependencies.
3. Generates `Apps/Mac/OpenDuckFrame.xcodeproj` with XcodeGen.
4. Runs an `AppStore` archive for `generic/platform=macOS`, injecting the team,
   final bundle ID, marketing version, and build number on the command line.
5. Performs read-only archive validation.

The validator fails unless all of the following are true:

- The main app, Quick Look extension, media framework, and bundled Mach-O code
  are signed by Apple Distribution and the requested Team ID.
- Main and Quick Look signatures contain App Sandbox. The main app has
  user-selected read/write access for explicit Open/Save panel choices; the
  Quick Look extension remains read-only.
- Main, Quick Look, and media framework bundle identifiers match the explicitly
  supplied identifier family.
- Main and Quick Look version/build values match the supplied release values.
- Both executable bundles contain a valid `PrivacyInfo.xcprivacy`.
- Packaged Mach-O files contain none of the automation, benchmark, dump, or
  runtime-tuning hook tokens that `SP_APP_STORE` is required to compile out.
- Main and Quick Look provisioning profiles authorize the expected IDs and do
  not enable `get-task-allow`.
- The packaged architecture, minimum OS, shaders, signatures, and Mach-O
  dependency closure pass `verify_app_bundle.py --skip-manifest`.
- No `BuildManifest.json` is present. The deterministic local-build manifest
  hashes signed bytes and is intentionally excluded from the App Store lane.

Nothing after the archive command writes into the `.xcarchive` or its app.

## 2. Export a package without uploading

The destination is mandatory; there is no implicit export/upload default.
The export path must not already exist.

```sh
Scripts/export_app_store.sh \
  --archive-path .build/AppStore/OpenDuckFrame-1.0.0-1.xcarchive \
  --export-path .build/AppStore/OpenDuckFrame-1.0.0-1-export \
  --destination export \
  --team-id ABCDE12345 \
  --bundle-id com.example.openduckframe \
  --marketing-version 1.0.0 \
  --build-number 1 \
  --allow-provisioning-updates
```

The generated export options always use `method=app-store-connect`, automatic
signing, the explicit team, and `manageAppVersionAndBuildNumber=false`. Xcode
therefore cannot silently replace the supplied build number.

## 3. Upload to App Store Connect

For an interactive machine signed in to Xcode:

```sh
Scripts/export_app_store.sh \
  --archive-path .build/AppStore/OpenDuckFrame-1.0.0-1.xcarchive \
  --export-path .build/AppStore/OpenDuckFrame-1.0.0-1-upload \
  --destination upload \
  --team-id ABCDE12345 \
  --bundle-id com.example.openduckframe \
  --marketing-version 1.0.0 \
  --build-number 1 \
  --allow-provisioning-updates
```

For CI, pass all three App Store Connect API credentials together:

```sh
Scripts/export_app_store.sh \
  --archive-path .build/AppStore/OpenDuckFrame-1.0.0-1.xcarchive \
  --export-path .build/AppStore/OpenDuckFrame-1.0.0-1-upload \
  --destination upload \
  --team-id ABCDE12345 \
  --bundle-id com.example.openduckframe \
  --marketing-version 1.0.0 \
  --build-number 1 \
  --api-key-path /secure/path/AuthKey_KEYID.p8 \
  --api-key-id KEYID \
  --api-issuer-id 00000000-0000-0000-0000-000000000000
```

When all three API credential options are present, the script automatically
passes `-allowProvisioningUpdates` to `xcodebuild`; the explicit flag is not
needed in this form. The three credential options remain all-or-none.

Never store `.p8` keys, account passwords, or signing certificates in the
repository. Use the CI secret store or the macOS Keychain.

## App Store Connect checklist

Before submitting the uploaded build for review, confirm:

- The app name, primary language, category, age rating, content-rights answer,
  description, keywords, screenshots, support URL, and copyright are complete.
- The public privacy-policy URL and App Privacy answers match
  `PrivacyInfo.xcprivacy` and the shipped code.
- Export compliance is answered for all first- and third-party code.
- The App Review contact and notes explain local media selection and the Quick
  Look extension, and provide representative media if needed.
- Any In-App Purchase is implemented, restorable, tested in Sandbox/TestFlight,
  visible to review, and submitted with its required metadata and screenshot.
- The Paid Apps Agreement, banking information, and tax information are active
  before selling the app or an In-App Purchase.

Use TestFlight before selecting the build for production review. Mac App Store
archives do not use the Developer ID/notarization pipeline; that is a separate
distribution channel.

## Apple references

- [Distributing an app for beta testing and releases](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)
- [Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)
- [Uploading builds to App Store Connect](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
- [Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)
- [Adding a privacy manifest](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
