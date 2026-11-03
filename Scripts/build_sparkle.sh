#!/bin/bash
# Reproducibly build Sparkle for the optional direct-distribution update lane.
# Output: ThirdParty/sparkle-min/{Sparkle.framework,bin/}. Source trees, caches,
# and build products remain ignored. App Store builds neither run this recipe
# nor embed the resulting framework.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Dependency recipes replace DEVELOPER_DIR with `xcode-select -p`. On this
# machine that is Command Line Tools, which has no xcodebuild. Keep a caller
# supplied full Xcode for the Sparkle schemes only; compiler paths used by the
# recipe hash stay on the reset environment.
CALLER_DEVELOPER_DIR="${DEVELOPER_DIR:-}"
# shellcheck source=lib/build_common.sh
source "$SCRIPT_DIR/lib/build_common.sh"
sp_reset_build_env

NAME=sparkle
VERSION="$(sp_lock_get "$NAME" version)"
if [ -n "${1:-}" ] && [ "$1" != "$VERSION" ]; then
  sp_die "sparkle is locked to $VERSION in deps.lock.json (received $1)"
fi

URL="$(sp_lock_get "$NAME" url)"
ARCHIVE_NAME="$(sp_lock_get "$NAME" archive)"
SOURCE_DIR="$(sp_lock_get "$NAME" source_dir)"
SHA256="$(sp_lock_get "$NAME" sha256)"
PREFIX="$SP_THIRDPARTY/sparkle-min"
STAMP="$PREFIX/.build-stamp.json"
REQUIRED_OUTPUTS=(
  "$PREFIX/Sparkle.framework/Versions/B/Sparkle"
  "$PREFIX/Sparkle.framework/Versions/B/Autoupdate"
  "$PREFIX/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater"
  "$PREFIX/Sparkle.framework/Versions/B/Resources/Info.plist"
  "$PREFIX/bin/generate_appcast"
  "$PREFIX/bin/generate_keys"
  "$PREFIX/bin/sign_update"
)

RECIPE_ARGS=(
  --dependency "$NAME"
  --input "$SP_ROOT/Scripts/build_sparkle.sh"
  --input "$SP_ROOT/Scripts/lib/build_common.sh"
  --input "$SP_ROOT/Scripts/lib/deps_lock.py"
  --tool "xcodebuild=/usr/bin/xcodebuild"
  --parameter "prefix=$PREFIX"
  --parameter "sdk_version=$SP_SDK_VERSION"
)
RECIPE_HASH="$(sp_recipe_hash "${RECIPE_ARGS[@]}")"
if sp_all_files_exist "${REQUIRED_OUTPUTS[@]}" && \
   sp_stamp_matches "$STAMP" "$RECIPE_HASH" && \
   /usr/bin/codesign --verify --deep --strict \
     "$PREFIX/Sparkle.framework" >/dev/null 2>&1; then
  echo "==> sparkle $VERSION already matches the current recipe"
  exit 0
fi

mkdir -p "$SP_DOWNLOADS"
ARCHIVE="$SP_DOWNLOADS/$ARCHIVE_NAME"
sp_verified_download "$URL" "$SHA256" "$ARCHIVE"

WORK="$(mktemp -d "$SP_THIRDPARTY/.sparkle-build.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
sp_extract_archive "$ARCHIVE" "$WORK/src"
SOURCE="$WORK/src/$SOURCE_DIR"
[ -d "$SOURCE" ] || sp_die "locked Sparkle source directory is missing: $SOURCE_DIR"

DERIVED="$WORK/dd"
SPM_CACHE="$SP_DOWNLOADS/spm-cache"
build_scheme() {
  local scheme="$1"
  echo "==> Building Sparkle scheme: $scheme"
  # build_common exports compiler variables for Make/Meson recipes. xcodebuild
  # interprets those names as build-setting overrides, so remove them here.
  local xcode_dev="${DEVELOPER_DIR:-}"
  if [ ! -x "${xcode_dev}/usr/bin/xcodebuild" ] && [ -n "$CALLER_DEVELOPER_DIR" ] && [ -x "${CALLER_DEVELOPER_DIR}/usr/bin/xcodebuild" ]; then
    xcode_dev="$CALLER_DEVELOPER_DIR"
  fi
  [ -x "${xcode_dev}/usr/bin/xcodebuild" ] || sp_die "xcodebuild is not in the active developer directory; pass DEVELOPER_DIR for a full Xcode"
  if ! env -u LD -u CC -u CXX -u AR -u RANLIB -u STRIP \
      DEVELOPER_DIR="$xcode_dev" \
      /usr/bin/xcodebuild -jobs 6 -project "$SOURCE/Sparkle.xcodeproj" \
      -scheme "$scheme" -configuration Release \
      -derivedDataPath "$DERIVED" \
      -clonedSourcePackagesDirPath "$SPM_CACHE" \
      ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
      MACOSX_DEPLOYMENT_TARGET=12.0 \
      CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
      build >"$WORK/xcodebuild-$scheme.log" 2>&1; then
    tail -40 "$WORK/xcodebuild-$scheme.log" >&2
    sp_die "Sparkle scheme failed: $scheme"
  fi
}
build_scheme Sparkle
build_scheme generate_appcast
build_scheme generate_keys
build_scheme sign_update

PRODUCTS="$DERIVED/Build/Products/Release"
STAGED="$WORK/staged"
mkdir -p "$STAGED/bin"
cp -R "$PRODUCTS/Sparkle.framework" "$STAGED/Sparkle.framework"
for tool in generate_appcast generate_keys sign_update; do
  cp "$PRODUCTS/$tool" "$STAGED/bin/$tool"
done

FW="$STAGED/Sparkle.framework"
# Direct local builds are intentionally unsandboxed. Remove Sparkle's sandbox
# XPC services to reduce the bundle and signing surface. The App Store lane is
# separate and excludes the entire framework.
rm -rf "$FW/Versions/B/XPCServices" "$FW/XPCServices"

BUILT_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw \
  "$FW/Versions/B/Resources/Info.plist")"
[ "$BUILT_VERSION" = "$VERSION" ] || \
  sp_die "built Sparkle version $BUILT_VERSION does not match lock $VERSION"

MINOS="$(/usr/bin/otool -l "$FW/Versions/B/Sparkle" | \
  awk '/minos/ {print $2; exit}')"
case "$MINOS" in
  1[5-9].*|[2-9][0-9].*) sp_die "Sparkle minos $MINOS exceeds the 14.0 gate" ;;
esac

# Sign nested code from the inside out for local ad-hoc packaging. A future
# Developer ID release lane must replace these signatures explicitly.
/usr/bin/xattr -cr "$STAGED"
/usr/bin/codesign -s - --force "$FW/Versions/B/Autoupdate"
/usr/bin/codesign -s - --force --deep "$FW/Versions/B/Updater.app"
/usr/bin/codesign -s - --force "$FW"

sp_write_stamp "$STAGED/.build-stamp.json" "${RECIPE_ARGS[@]}"
sp_atomic_replace_directory "$STAGED" "$PREFIX"

echo "==> Complete: $PREFIX (sparkle $VERSION, recipe ${RECIPE_HASH:0:12})"
