# Community update validation — 2026-11-03

The community lane uses ad-hoc application signing plus EdDSA-signed update
archives and feeds. It does not use a Developer ID certificate or Apple
notarization.

## Fixed inputs

- Binary source: `ec98787e8c130345ed59f0ed830d57d81451141b`.
- Product: OpenDuckFrame 0.1.0, arm64, minimum macOS 14.
- Source app passed the repository's complete bundle verifier before packaging.
- The release reuses this existing application binary. It is a configured and
  re-signed package, not a new application compilation.
- Sparkle: 2.9.6. Its official command-line updater was built from the locked
  source archive for the test; the app already contains the same Sparkle version.
- Test host: Apple silicon Mac, macOS 27. Local isolated copies, not the active app.

## Observed results

1. Packaged app validation, ZIP extraction round trip, and DMG checksum: passed.
2. Appcast signature verification: passed.
3. Modifying signed feed content without re-signing it: verification rejected it.
4. A real OpenDuckFrame app copy at build 1 found build 2 through a signed local feed.
5. Sparkle downloaded and verified the full application archive, installed it,
   and exited successfully. The installed copy reported build 2 and passed the
   complete bundle verifier again.
6. A second probe of that updated copy returned “No new update available”.
7. The separately running development app retained its process and executable path.

The official updater's `--application` option pointed at an inactive test watcher
so the installation did not terminate or relaunch the user's running development
app. The installed target was the real product bundle, not a substitute app.

The first attempt to build the official updater tool failed because its default
10.13 deployment target is unsupported by the installed Xcode. Retrying with the
12.0 deployment target used by this repository's Sparkle recipe passed. An initial
probe command combined incompatible CLI flags; the corrected probe passed.

## Limits

This validates the update download, signature and replacement path on this Mac.
It does not validate Apple notarization, first installation through Gatekeeper
on a clean Mac, every macOS version, or all playback / enhancement features.
The user must decide whether to allow a non-notarized first launch. The release
script does not change system security settings.
