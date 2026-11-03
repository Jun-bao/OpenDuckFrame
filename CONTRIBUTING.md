# Contributing

Thank you for helping improve OpenDuckFrame.

## Before opening a change

- Keep changes focused on the shipping player or its public build pipeline.
- Do not commit generated Xcode projects, build products, dependency sources,
  downloaded media, benchmarks, or local logs.
- Preserve the existing `SP` internal symbol prefix unless a change genuinely
  requires an ABI-level rename.
- Keep public documentation, diagnostics, and new source comments in English.
- Follow the source ownership described in
  [REPOSITORY_LAYOUT.md](REPOSITORY_LAYOUT.md). Product and platform directories
  are not independent packages; do not assume the current media or subtitle
  APIs already support iOS.
- Add user-facing strings to `Apps/Mac/Resources/Localizable.xcstrings`.
  English is the source language; merged shipping changes must keep all
  supported locales complete and preserve every format placeholder.

Use the localization workflow before opening a pull request:

```bash
python3 Scripts/l10n.py status
python3 Scripts/l10n.py check --full
```

When translations are missing, `Scripts/l10n.py export <directory>` creates a
JSON file per incomplete locale with English and Simplified Chinese reference
text. Translate those files, reduce each entry to `{key: translated_string}`,
then run `Scripts/l10n.py merge <directory>` and the full check again.

## Build verification

### Product naming

Use `OpenDuckFrame` for every name: the app bundle, executable, Dock, Finder,
menus, windows, About panel, localized `app.displayName`, bundle identifiers
(`app.openduckframe.*`), targets, modules, environment variables (`ODF_*`),
command-line flags (`--odf-*`), download artifacts and documentation.
`Scripts/check_public_repo.sh` rejects any other product name.

### Checks

Use an Apple Silicon Mac with Xcode and the macOS 26.4 SDK or later, then run
these commands from the repository root:

```bash
./Scripts/check_public_repo.sh
./Apps/Mac/Scripts/build.sh Release
./Scripts/verify_app_bundle.sh \
  .build/Build/Products/Release/OpenDuckFrame.app
```

`Scripts/build.sh` remains a compatibility entry point. Edit
`Apps/Mac/project.yml` for Mac build configuration changes, not the generated
`Apps/Mac/OpenDuckFrame.xcodeproj`. The shared `.build` directory and root-level
`OpenDuckFrame.app` deployment location are unchanged.

Describe the media formats and macOS versions exercised in the pull request.
The public repository intentionally does not ship large media fixtures or the
maintainers' extended benchmark and reliability suites.
