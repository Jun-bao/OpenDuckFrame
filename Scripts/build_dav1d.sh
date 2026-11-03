#!/bin/bash
# OpenDuckFrame — reproducible static dav1d (AV1 software fallback).
# Output: ThirdParty/dav1d-min/{include,lib}; source/output are not committed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/build_common.sh
source "$SCRIPT_DIR/lib/build_common.sh"
sp_reset_build_env

NAME=dav1d
VERSION="$(sp_lock_get "$NAME" version)"
if [ -n "${1:-}" ] && [ "$1" != "$VERSION" ]; then
  sp_die "dav1d is locked to version $VERSION in deps.lock.json (received $1)"
fi

URL="$(sp_lock_get "$NAME" url)"
ARCHIVE_NAME="$(sp_lock_get "$NAME" archive)"
SOURCE_DIR="$(sp_lock_get "$NAME" source_dir)"
SHA256="$(sp_lock_get "$NAME" sha256)"
PREFIX="$SP_THIRDPARTY/dav1d-min"
STAMP="$PREFIX/.build-stamp.json"
REQUIRED_OUTPUTS=(
  "$PREFIX/lib/libdav1d.a"
  "$PREFIX/lib/pkgconfig/dav1d.pc"
  "$PREFIX/include/dav1d/dav1d.h"
)
MESON="$(sp_find_tool meson /opt/homebrew/bin/meson)"
NINJA="$(sp_find_tool ninja /opt/homebrew/bin/ninja)"

RECIPE_ARGS=(
  --dependency "$NAME"
  --input "$SP_ROOT/Scripts/build_dav1d.sh"
  --input "$SP_ROOT/Scripts/lib/build_common.sh"
  --input "$SP_ROOT/Scripts/lib/deps_lock.py"
  --tool "ar=$AR"
  --tool "clang=$CC"
  --tool "ld=$LD"
  --tool "meson=$MESON"
  --tool "ninja=$NINJA"
  --tool "ranlib=$RANLIB"
  --tool "xcodebuild=/usr/bin/xcodebuild"
  --parameter "prefix=$PREFIX"
  --parameter "sdk_version=$SP_SDK_VERSION"
)
RECIPE_HASH="$(sp_recipe_hash "${RECIPE_ARGS[@]}")"
if sp_all_files_exist "${REQUIRED_OUTPUTS[@]}" && sp_stamp_matches "$STAMP" "$RECIPE_HASH"; then
  echo "==> dav1d $VERSION already matches the current recipe"
  exit 0
fi

mkdir -p "$SP_DOWNLOADS"
ARCHIVE="$SP_DOWNLOADS/$ARCHIVE_NAME"
sp_verified_download "$URL" "$SHA256" "$ARCHIVE"

WORK="$(mktemp -d "$SP_THIRDPARTY/.dav1d-build.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
sp_extract_archive "$ARCHIVE" "$WORK/src"
SOURCE="$WORK/src/$SOURCE_DIR"
[ -d "$SOURCE" ] || sp_die "dav1d source directory does not match the lock: $SOURCE_DIR"

DESTDIR="$WORK/dest"
BUILD="$WORK/build"
COMMON_CFLAGS="-isysroot $SDKROOT -arch arm64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -O2"
COMMON_LDFLAGS="-isysroot $SDKROOT -arch arm64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"

echo "==> Configuring dav1d $VERSION (hermetic arm64 / macOS $MACOSX_DEPLOYMENT_TARGET)"
if ! "$MESON" setup "$BUILD" "$SOURCE" \
    --prefix="$PREFIX" \
    --wrap-mode=nofallback \
    --default-library=static \
    --buildtype=release \
    -Denable_tools=false \
    -Denable_tests=false \
    -Denable_examples=false \
    -Dc_args="$COMMON_CFLAGS" \
    -Dc_link_args="$COMMON_LDFLAGS" \
    >"$WORK/meson.log" 2>&1; then
  tail -40 "$WORK/meson.log" >&2
  exit 1
fi
if ! "$NINJA" -C "$BUILD" >"$WORK/ninja.log" 2>&1; then
  tail -40 "$WORK/ninja.log" >&2
  exit 1
fi
if ! "$MESON" install -C "$BUILD" --destdir "$DESTDIR" \
    >"$WORK/install.log" 2>&1; then
  tail -40 "$WORK/install.log" >&2
  exit 1
fi

STAGED_PREFIX="$DESTDIR$PREFIX"
LIBRARY="$STAGED_PREFIX/lib/libdav1d.a"
for output in "${REQUIRED_OUTPUTS[@]}"; do
  staged_output="$STAGED_PREFIX/${output#"$PREFIX/"}"
  [ -s "$staged_output" ] || sp_die "dav1d installation is missing: ${output#"$PREFIX/"}"
done
ARCHS="$(lipo -archs "$LIBRARY")"
[ "$ARCHS" = "arm64" ] || sp_die "dav1d has an unexpected architecture: $ARCHS"
# Read the version embedded in the staged archive and check its pkg-config
# metadata before publishing either one.
cat > "$WORK/version-probe.c" <<'EOF'
#include <stdio.h>
#include <dav1d/dav1d.h>
int main(void) {
  puts(dav1d_version());
  return 0;
}
EOF
"$CC" -isysroot "$SDKROOT" -arch arm64 -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
  -I "$STAGED_PREFIX/include" "$WORK/version-probe.c" "$LIBRARY" \
  -o "$WORK/version-probe" || sp_die "dav1d version probe failed to compile"
BUILT_VERSION="$("$WORK/version-probe")" || sp_die "dav1d version probe failed to run"
[ "$BUILT_VERSION" = "$VERSION" ] || sp_die "dav1d embedded version $BUILT_VERSION does not match lock $VERSION"
PC_VERSION="$(awk '$1 == "Version:" { print $2; exit }' "$STAGED_PREFIX/lib/pkgconfig/dav1d.pc")"
[ "$PC_VERSION" = "$VERSION" ] || sp_die "dav1d.pc version ${PC_VERSION:-unknown} does not match lock $VERSION"
echo "==> Verified dav1d $BUILT_VERSION"
sp_write_stamp "$STAGED_PREFIX/.build-stamp.json" "${RECIPE_ARGS[@]}"
sp_atomic_replace_directory "$STAGED_PREFIX" "$PREFIX"

echo "==> Complete: $PREFIX (recipe ${RECIPE_HASH:0:12})"
