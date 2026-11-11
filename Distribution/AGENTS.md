# Release configuration and notes

[sparkle.json](sparkle.json) holds the public feed URL and public EdDSA key.
[release-notes](release-notes/) contains version-specific public update notes.
The complete workflow and version/build policy is [RELEASING.md](../RELEASING.md).

## Select the correct lane

Community downloads are ad-hoc signed and use independent EdDSA update signatures.
Developer ID distribution has its own signed archive, notarization and DMG flow.
App Store uses its dedicated archive/export configuration and excludes Sparkle.
Keep each lane's actual signing and approval status explicit.

## Inputs and checks

For ordinary local builds, version/build values come from [Apps/Mac/project.yml](../Apps/Mac/project.yml).
A new handed-out binary requires a globally increasing build number under the release policy.
Retrying the exact immutable artifact preserves its identity.
`Scripts/community_release.py` packages and verifies a supplied app; read its arguments and the release guide before invoking it.
Its `--publish` path creates public assets and updates the gh-pages feed, requiring explicit current authorization.
Pair feed/key overrides and keep the private EdDSA key in the existing Keychain storage.
Preserve published release history and record binary source versus packaging source.
Retain checksums, version/build, validation results and distribution channel for the actual artifact.
Verify normal installation at `/Applications/OpenDuckFrame.app`, exact running identity and extra registrations at handoff.
Release metadata and a successful bundle check do not establish update installation or business/visual acceptance.
