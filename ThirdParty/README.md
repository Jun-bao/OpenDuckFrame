# Third-party dependencies

## Reproducible dependency builds

[`deps.lock.json`](deps.lock.json) is the single source of dependency versions,
source URLs, SHA-256 values, the FFmpeg patch hashes, target architecture, and
minimum macOS version. The build scripts download to a temporary file, verify
the hash, and only then atomically publish the archive in the ignored
`ThirdParty/downloads/` cache.

Each installed prefix contains `.build-stamp.json`. Its recipe hash covers the
relevant lock entries, build scripts, patch/dependency stamps, install prefix,
and compiler/build-tool versions. `Apps/Mac/Scripts/build.sh` runs the required
ensure recipes; a matching artifact and stamp make them no-ops:

- `Scripts/build_dav1d.sh` → `dav1d-min/` (static AV1 fallback)
- `Scripts/build_speex.sh` → `speex-min/` (static reference Speex decoder)
- `Scripts/build_ffmpeg_min.sh` → `ffmpeg-min/` (minimal static FFmpeg;
  ensures and fingerprints dav1d and Speex)
- `Scripts/build_subtitle_libs.sh` → `subtitles-min/` (self-built libass dylib)
- `Scripts/build_sparkle.sh` → `sparkle-min/` (optional direct-update framework
  and release-side appcast/signing tools)

These are source builds, not copies of Homebrew libraries. They require Xcode
with the macOS SDK plus `xcodegen`, `meson`, `ninja`, `cmake`, and `pkg-config`;
the recipes use the SDK toolchain and the system `make`. A full `ffmpeg`
command-line installation is useful for generating validation media, but is
not an input to the app dependency build.

The recipes clear caller include/link/SDK flags, isolate pkg-config, disable
fallback downloads/autodetection, and reject external include/library roots or
X11/Vulkan linkage after configuration. Generated sources, caches, build trees,
and installed prefixes are intentionally not committed.

Before publishing a staged prefix, dav1d and Speex link a version probe against
their actual static archives and verify their pkg-config versions. FFmpeg's
capability probe requires its embedded version to equal the lock. GitHub tag
archives lack FFmpeg's release `VERSION` file, so its recipe writes the locked
version before configuration instead of embedding the enclosing Git identity.
This removes commit-dependent version drift, not every source of byte variation:
FFmpeg still embeds absolute configure/toolchain paths, so different checkout
locations or Xcode installations can produce different archive bytes.

The current recipes and installed prefixes target macOS only. The source
directory layout does not add iOS or simulator builds; future mobile builds
must keep their SDK-specific artifacts separate from these macOS prefixes.
Matching CPU architectures do not make libraries interchangeable between
platforms. Sparkle remains specific to direct distribution on macOS.

## FFmpeg

FFmpeg is configured with `--disable-everything` and explicit playback
demuxer/decoder/parser allowlists. It has no network, encoder, muxer, filter, or
device support and statically links the locked dav1d and Speex. The configuration remains
LGPL-only; no GPL component is enabled. The project is MIT-licensed and ships
the complete build recipe and [downstream patch lifecycle](../Scripts/patches/README.md);
the exact upstream source archive and checksum are recorded in the lock.

The build-time `Scripts/lib/ffmpeg_capabilities.c` gate checks actual decoder,
demuxer, parser, and bitstream-filter registration before publishing the prefix.
It covers MXF, DV, raw AV1, VVC, CAVS, DNxHD/DNxHR, JPEG 2000, FFV1,
Speex, and WMA Lossless alongside baseline formats. Speex must resolve uniquely
to the reference-library wrapper; FLV1 must resolve to the native `flv` decoder.
The probe also rejects an unexpected FFmpeg license and tests missing-component
failure. It is not linked into the player's media-open path.

Speex 1.2.1 is a static decoder dependency, without command-line tools,
SpeexDSP, or libogg. The downstream flush patch recreates its decoder and stereo
state for deterministic seek/replay. The raw AV1 patches preserve default
behavior and expose a one-shot tail-drain acknowledgement only after the player
checks an unchanged local source; they do not add a raw-file index.

## libass

libpng, FreeType, FriBidi, libunibreak, Graphite2, and HarfBuzz are built from
the lock and statically linked into the self-built `libass.9.dylib`. Packaging
fails if that dylib or its build stamp is missing; there is no Homebrew runtime
fallback. `Scripts/bundle_libs.sh` embeds the dylib and a deterministic
`BuildManifest.json`, signs the package, then calls
`Scripts/verify_app_bundle.sh` to validate Mach-O dependency closure, arm64,
minos, codesign, the metallib, bundled notice bytes, and manifest hashes.

## Sparkle

Sparkle is built from its checksum-pinned source tag for non-App-Store
distribution. The local framework is embedded but not linked at launch; it is
loaded only when a build contains both a feed URL and an EdDSA public key.
Release-side tools (`generate_appcast`, `generate_keys`, and `sign_update`) are
built from the same source but are not copied into the app. The App Store
configuration neither builds nor embeds Sparkle.

## License texts

[`Licenses/`](Licenses/) contains the upstream license files for the exact
dependency versions recorded in `deps.lock.json`: FFmpeg, dav1d, Speex, libass,
libpng, FreeType, FriBidi, libunibreak, Graphite2, HarfBuzz, and Sparkle. The repository
root [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md) maps each dependency
to its selected license; `deps.lock.json` records the corresponding source URL.

The component directories and `Licenses/THIRD_PARTY_NOTICES.txt` ship as a folder
resource in `OpenDuckFrameMediaCore.framework/Resources/Licenses`, shared by the
host app and Quick Look extension. `build_manifest.py` requires every notice;
bundle verification compares the complete relative-file set and bytes against
the source directory, including for Store archives without a build manifest.
When a dependency is updated, copy its notices verbatim from the newly locked
archive and update the index. Keep the Independent JPEG Group and FreeType Team
acknowledgments in both notice indexes.

These files document redistribution obligations; the build itself consumes the
checksum-pinned upstream archives and does not compile files from `Licenses/`.
Binary distributors remain responsible for preserving the applicable notices
and providing corresponding source or relinking materials where required.
