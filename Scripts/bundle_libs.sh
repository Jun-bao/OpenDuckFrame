#!/bin/bash
# Package the self-built libass, embed a deterministic build manifest, sign in
# a clean temporary directory, and fail closed on any incomplete bundle.
set -euo pipefail

APP="${1:?usage: bundle_libs.sh <path-to-OpenDuckFrame.app>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/lib/build_common.sh
source "$ROOT/Scripts/lib/build_common.sh"

# This is the local-development packaging lane and always signs ad hoc. The
# Mac App Store lane never runs this bundler; Xcode owns its sandbox
# entitlements and distribution signature. A future Developer ID/notarization
# lane needs its own explicit, inside-out signing and validation flow.
SP_SIGN_ID="-"
SP_SIGN_OPTS=""

# A SIGKILL can stop a previous publication after the old app was moved to
# its durable backup. Recover that state before inspecting the app: in the
# interrupted state SOURCE_BIN is intentionally absent.
APP_PARENT="$(cd "$(dirname "$APP")" && pwd -P)"
APP="$APP_PARENT/$(basename "$APP")"
sp_recover_atomic_directory "$APP" "$APP_PARENT"

SOURCE_INFO="$APP/Contents/Info.plist"
[ -f "$SOURCE_INFO" ] || { echo "Main Info.plist not found: $SOURCE_INFO" >&2; exit 1; }
APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$SOURCE_INFO")"
case "$APP_EXECUTABLE" in
  ''|*/*) echo "Invalid CFBundleExecutable: $APP_EXECUTABLE" >&2; exit 1 ;;
esac
SOURCE_BIN="$APP/Contents/MacOS/$APP_EXECUTABLE"
LIBASS="$ROOT/ThirdParty/subtitles-min/lib/libass.9.dylib"
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
LOCK="$ROOT/ThirdParty/deps.lock.json"
DAV1D_STAMP="$ROOT/ThirdParty/dav1d-min/.build-stamp.json"
SPEEX_STAMP="$ROOT/ThirdParty/speex-min/.build-stamp.json"
FFMPEG_STAMP="$ROOT/ThirdParty/ffmpeg-min/.build-stamp.json"
SUBTITLE_STAMP="$ROOT/ThirdParty/subtitles-min/.build-stamp.json"
SPARKLE_STAMP="$ROOT/ThirdParty/sparkle-min/.build-stamp.json"

[ -f "$SOURCE_BIN" ] || { echo "Main executable not found: $SOURCE_BIN" >&2; exit 1; }
[ -d "$SPARKLE_FRAMEWORK" ] || {
  echo "Sparkle.framework is missing from the direct-distribution build" >&2
  exit 1
}
[ -f "$LIBASS" ] || {
  echo "Self-built libass is missing; refusing a Homebrew fallback. Run Scripts/build_subtitle_libs.sh first." >&2
  exit 1
}
for stamp in "$DAV1D_STAMP" "$SPEEX_STAMP" "$FFMPEG_STAMP" "$SUBTITLE_STAMP" "$SPARKLE_STAMP"; do
  [ -f "$stamp" ] || { echo "Dependency build stamp is missing: $stamp" >&2; exit 1; }
done

# The self-built libass must have only Apple system dynamic dependencies. Its
# remaining subtitle dependencies are static by design.
if ! LIBASS_DEPS="$(otool -L "$LIBASS" 2>&1)"; then
  printf '%s\n' "$LIBASS_DEPS" >&2
  echo "Self-built libass is not a readable Mach-O; refusing to package it" >&2
  exit 1
fi
if printf '%s\n' "$LIBASS_DEPS" | tail -n +2 | grep -Eq '/opt/homebrew|/usr/local|/opt/X11'; then
  printf '%s\n' "$LIBASS_DEPS" >&2
  echo "Self-built libass has an external dynamic dependency; refusing to package it" >&2
  exit 1
fi

# Copy the unmodified Xcode product to a clean transaction directory first.
# Every Mach-O rewrite below is confined to this copy, so a packaging or
# verification failure leaves the caller's original app byte-for-byte intact.
CLEAN_DIR="$(mktemp -d)"
PUBLISH_DIR=""
cleanup() {
  rm -rf "$CLEAN_DIR"
  [ -z "$PUBLISH_DIR" ] || rm -rf "$PUBLISH_DIR"
}
trap cleanup EXIT
CLEAN_APP="$CLEAN_DIR/$(basename "$APP")"
ditto --norsrc --noextattr --noqtn "$APP" "$CLEAN_APP"
xattr -cr "$CLEAN_APP" 2>/dev/null || true
BIN="$CLEAN_APP/Contents/MacOS/$APP_EXECUTABLE"
FW="$CLEAN_APP/Contents/Frameworks"
MAIN_INFO="$CLEAN_APP/Contents/Info.plist"


# The tracked source plist remains channel-neutral. Add updater configuration
# only to the clean direct-distribution bundle, before the outer signature is
# created. Blank configuration removes every SU key and keeps the updater inert.
SPARKLE_FEED_URL="${ODF_SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_ED_KEY="${ODF_SPARKLE_PUBLIC_ED_KEY:-}"
if { [ -n "$SPARKLE_FEED_URL" ] && [ -z "$SPARKLE_PUBLIC_ED_KEY" ]; } ||
   { [ -z "$SPARKLE_FEED_URL" ] && [ -n "$SPARKLE_PUBLIC_ED_KEY" ]; }; then
  echo "error: ODF_SPARKLE_FEED_URL and ODF_SPARKLE_PUBLIC_ED_KEY must be supplied together" >&2
  exit 2
fi
for update_key in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks SPUpdateUsageEnabled \
                  SUEnableSystemProfiling \
                  SUVerifyUpdateBeforeExtraction SURequireSignedFeed; do
  /usr/bin/plutil -remove "$update_key" "$MAIN_INFO" >/dev/null 2>&1 || true
done
if [ -n "$SPARKLE_FEED_URL" ]; then
  /usr/bin/plutil -insert SUFeedURL -string "$SPARKLE_FEED_URL" "$MAIN_INFO"
  /usr/bin/plutil -insert SUPublicEDKey -string "$SPARKLE_PUBLIC_ED_KEY" "$MAIN_INFO"
  /usr/bin/plutil -insert SUEnableAutomaticChecks -bool YES "$MAIN_INFO"
  /usr/bin/plutil -insert SUEnableSystemProfiling -bool NO "$MAIN_INFO"
  /usr/bin/plutil -insert SUVerifyUpdateBeforeExtraction -bool YES "$MAIN_INFO"
  /usr/bin/plutil -insert SURequireSignedFeed -bool YES "$MAIN_INFO"
fi

# Update checks never carry installation statistics; every build ships the
# neutral privacy manifest.
cp "$ROOT/Apps/Mac/Resources/PrivacyInfo.xcprivacy" \
   "$CLEAN_APP/Contents/Resources/PrivacyInfo.xcprivacy"

# Assemble loose dylibs from empty so stale libraries cannot survive a
# rebuild. Xcode-embedded frameworks (OpenDuckFrameMediaCore) are kept: the
# source app copy is a fresh build product, so they cannot be stale.
mkdir -p "$FW"
find "$FW" -maxdepth 1 -type f -delete
cp "$LIBASS" "$FW/libass.9.dylib"
DISTIL_RUNTIME="$ROOT/.build/distil-runtime"
if [ -d "$DISTIL_RUNTIME" ]; then
  python3 - "$DISTIL_RUNTIME" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
model = root / 'DistilDRBA_720p.mlmodelc'
expected = json.loads((root / 'SHA256.json').read_text())
files = [p for p in model.rglob('*') if p.is_file()]
if not model.is_dir() or any(p.is_symlink() for p in model.rglob('*')):
    raise SystemExit('Distil model missing or contains symlinks')
actual = {str(p.relative_to(model)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
if actual != expected or not actual:
    raise SystemExit('Distil model hash inventory mismatch')
PY
  ditto "$DISTIL_RUNTIME/DistilDRBA_720p.mlmodelc" "$CLEAN_APP/Contents/Resources/DistilDRBA_720p.mlmodelc"
fi
ANIME_RUNTIME="$ROOT/.build/anime4k-runtime"
if [ -d "$ANIME_RUNTIME" ]; then
  [ -f "$ANIME_RUNTIME/SHA256.txt" ] || { echo "Anime4K runtime has no hash inventory" >&2; exit 1; }
  shasum -a 256 -c "$ANIME_RUNTIME/SHA256.txt" >/dev/null
  for library in libplacebo.360.dylib libshaderc_shared.1.dylib liblcms2.2.dylib libMoltenVK.dylib; do
    [ -f "$ANIME_RUNTIME/$library" ] || { echo "Anime4K runtime missing $library" >&2; exit 1; }
    cp "$ANIME_RUNTIME/$library" "$FW/$library"
  done
fi
CUGAN_RUNTIME="$ROOT/.build/realcugan-runtime"
if [ -d "$CUGAN_RUNTIME" ]; then
  [ -f "$CUGAN_RUNTIME/SHA256.txt" ] || { echo "Real-CUGAN runtime has no hash inventory" >&2; exit 1; }
  shasum -a 256 -c "$CUGAN_RUNTIME/SHA256.txt" >/dev/null
  [ -f "$CUGAN_RUNTIME/libodf_realcugan.dylib" ] && [ -f "$CUGAN_RUNTIME/libMoltenVK.dylib" ] || { echo "Real-CUGAN runtime is incomplete" >&2; exit 1; }
  if [ -f "$FW/libMoltenVK.dylib" ]; then
    cmp -s "$FW/libMoltenVK.dylib" "$CUGAN_RUNTIME/libMoltenVK.dylib" || { echo "Anime4K and Real-CUGAN MoltenVK versions differ" >&2; exit 1; }
  else
    cp "$CUGAN_RUNTIME/libMoltenVK.dylib" "$FW/libMoltenVK.dylib"
  fi
  cp "$CUGAN_RUNTIME/libodf_realcugan.dylib" "$FW/libodf_realcugan.dylib"
fi
chmod u+w "$FW/libass.9.dylib"
install_name_tool -id "@rpath/libass.9.dylib" "$FW/libass.9.dylib"
BIN_RPATHS="$(otool -l "$BIN" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" { print $2; in_rpath = 0 }
  ')"
case "$BIN_RPATHS" in
  *'@executable_path/../Frameworks'*) ;;
  *) install_name_tool -add_rpath "@executable_path/../Frameworks" "$BIN" ;;
esac

# Sign every nested Mach-O before creating the manifest. The outer app signing
# happens afterwards and does not mutate these recorded artifact bytes.
# App extensions are excluded here: signing an .appex executable as a bare
# Mach-O strips its entitlements and breaks the nested-bundle seal, so they
# get a proper bundle-level signature below instead.
while IFS= read -r -d '' candidate; do
  [ "$candidate" = "$BIN" ] && continue
  case "$candidate" in
    "$CLEAN_APP/Contents/PlugIns/"*) continue ;;
    *.framework/*) continue ;; # frameworks get bundle-level signatures below
  esac
  if /usr/bin/file -b "$candidate" | grep -q 'Mach-O'; then
    codesign -s "$SP_SIGN_ID" $SP_SIGN_OPTS --force "$candidate"
  fi
done < <(find "$CLEAN_APP/Contents" -type f -print0)

# Sign embedded frameworks as whole bundles (inside-out: before the appex
# that links them and before the outer app).
for framework in "$FW"/*.framework; do
  [ -e "$framework" ] || continue
  if codesign --verify --strict "$framework" >/dev/null 2>&1; then
    continue
  fi
  codesign -s "$SP_SIGN_ID" $SP_SIGN_OPTS --force "$framework"
done

# Sign nested app extensions as whole bundles with their entitlements (the
# sandbox entitlement is mandatory for extension processes). A bundle that
# already carries a valid signature (signed build lane) is left untouched.
for appex in "$CLEAN_APP/Contents/PlugIns"/*.appex; do
  [ -e "$appex" ] || continue
  if codesign --verify --strict "$appex" >/dev/null 2>&1; then
    continue
  fi
  APPEX_EXEC_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
    "$appex/Contents/Info.plist")"
  APPEX_EXEC="$appex/Contents/MacOS/$APPEX_EXEC_NAME"
  # Inside-out: nested dylibs (e.g. Xcode's Debug preview split) first, the
  # bundle-level signature (which covers the main executable) last.
  while IFS= read -r -d '' candidate; do
    [ "$candidate" = "$APPEX_EXEC" ] && continue
    if /usr/bin/file -b "$candidate" | grep -q 'Mach-O'; then
      codesign -s "$SP_SIGN_ID" $SP_SIGN_OPTS --force "$candidate"
    fi
  done < <(find "$appex/Contents" -type f -print0)
  APPEX_ENTITLEMENTS="$ROOT/Apps/Mac/QuickLook/$(basename "$appex" .appex).entitlements"
  if [ -f "$APPEX_ENTITLEMENTS" ]; then
    codesign -s "$SP_SIGN_ID" $SP_SIGN_OPTS --force --entitlements "$APPEX_ENTITLEMENTS" "$appex"
  else
    codesign -s "$SP_SIGN_ID" $SP_SIGN_OPTS --force "$appex"
  fi
done

python3 "$ROOT/Scripts/lib/build_manifest.py" write \
  --app "$CLEAN_APP" \
  --lock "$LOCK" \
  --stamp "dav1d=$DAV1D_STAMP" \
  --stamp "speex=$SPEEX_STAMP" \
  --stamp "ffmpeg=$FFMPEG_STAMP" \
  --stamp "subtitles=$SUBTITLE_STAMP" \
  --stamp "sparkle=$SPARKLE_STAMP"

# Debug/Release host apps are intentionally unsandboxed. Do not pass the main
# app's sandbox entitlements here; AppStore archives apply them in Xcode and do
# not contain this bundler's BuildManifest.json.
python3 "$ROOT/Scripts/verify_public_surface.py" --app "$CLEAN_APP"
codesign -s "$SP_SIGN_ID" $SP_SIGN_OPTS --force "$CLEAN_APP"
"$ROOT/Scripts/verify_app_bundle.sh" "$CLEAN_APP"

# Stage publication beside the target, then use the same serialized,
# crash-recoverable rename transaction as third-party dependency publication.
PUBLISH_DIR="$(mktemp -d "$APP_PARENT/.openduckframe-publish.XXXXXX")"
PUBLISH_APP="$PUBLISH_DIR/$(basename "$APP")"
ditto "$CLEAN_APP" "$PUBLISH_APP"
sp_atomic_replace_directory "$PUBLISH_APP" "$APP" "$APP_PARENT"
rm -rf "$PUBLISH_DIR"
PUBLISH_DIR=""
echo "==> Complete: $APP"
