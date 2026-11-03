#!/bin/bash
# Pinned reference Speex decoder library; no product Ogg/CLI/DSP dependency.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/build_common.sh"
sp_reset_build_env
NAME=speex
VERSION="$(sp_lock_get "$NAME" version)"
PREFIX="$SP_THIRDPARTY/speex-min"
STAMP="$PREFIX/.build-stamp.json"
MAKE="$(sp_find_tool make /usr/bin/make)"
REQUIRED_OUTPUTS=("$PREFIX/lib/libspeex.a" "$PREFIX/lib/pkgconfig/speex.pc"
  "$PREFIX/include/speex/speex.h" "$PREFIX/share/licenses/speex/COPYING")
RECIPE_ARGS=(--dependency "$NAME" --input "$SP_ROOT/Scripts/build_speex.sh"
  --input "$SP_ROOT/Scripts/lib/build_common.sh"
  --input "$SP_ROOT/Scripts/lib/deps_lock.py"
  --input "$SP_ROOT/ThirdParty/Licenses/Speex/COPYING"
  --tool "clang=$CC" --tool "ar=$AR" --tool "ranlib=$RANLIB" --tool "make=$MAKE"
  --parameter "prefix=$PREFIX" --parameter "sdk_version=$SP_SDK_VERSION")
RECIPE_HASH="$(sp_recipe_hash "${RECIPE_ARGS[@]}")"
if sp_all_files_exist "${REQUIRED_OUTPUTS[@]}" && sp_stamp_matches "$STAMP" "$RECIPE_HASH"; then
  echo "==> speex $VERSION already matches the current recipe"
  exit 0
fi
ARCHIVE="$SP_DOWNLOADS/$(sp_lock_get "$NAME" archive)"
sp_verified_download "$(sp_lock_get "$NAME" url)" "$(sp_lock_get "$NAME" sha256)" "$ARCHIVE"
WORK="$(mktemp -d "$SP_THIRDPARTY/.speex-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
sp_extract_archive "$ARCHIVE" "$WORK/src"
SOURCE="$WORK/src/$(sp_lock_get "$NAME" source_dir)"
[ -d "$SOURCE" ] || sp_die "Speex locked source directory is missing"
cmp "$SOURCE/COPYING" "$SP_ROOT/ThirdParty/Licenses/Speex/COPYING" || sp_die "Speex license does not match the locked source"
export CFLAGS="-isysroot $SDKROOT -arch arm64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -O2 -fPIC"
export LDFLAGS="-isysroot $SDKROOT -arch arm64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
export PKG_CONFIG=/usr/bin/false
cd "$SOURCE"
if ! ./configure --prefix="$PREFIX" --disable-shared --enable-static \
    --disable-binaries --disable-examples --disable-sse --disable-neon \
    >"$WORK/configure.log" 2>&1; then
  tail -40 "$WORK/configure.log" >&2; exit 1
fi
if ! "$MAKE" -j"$(sysctl -n hw.ncpu)" >"$WORK/make.log" 2>&1 ||
   ! "$MAKE" DESTDIR="$WORK/dest" install >"$WORK/install.log" 2>&1; then
  tail -40 "$WORK/make.log" "$WORK/install.log" >&2; exit 1
fi
STAGED_PREFIX="$WORK/dest$PREFIX"
mkdir -p "$STAGED_PREFIX/share/licenses/speex"
cp "$SOURCE/COPYING" "$STAGED_PREFIX/share/licenses/speex/COPYING"
for output in "${REQUIRED_OUTPUTS[@]}"; do
  [ -s "$STAGED_PREFIX/${output#"$PREFIX/"}" ] || sp_die "Speex installation is missing: $output"
done
[ "$(lipo -archs "$STAGED_PREFIX/lib/libspeex.a")" = arm64 ] || sp_die "Speex has an unexpected architecture"
otool -l "$STAGED_PREFIX/lib/libspeex.a" > "$WORK/load-commands.txt"
awk -v expected="$MACOSX_DEPLOYMENT_TARGET" '$1 == "minos" { found++; if ($2 != expected) exit 1 } END { if (!found) exit 1 }' \
  "$WORK/load-commands.txt" || sp_die "Speex minimum macOS version does not match"
[ ! -e "$STAGED_PREFIX/bin" ] || sp_die "Speex must not install command-line tools"
# Check the embedded version through the staged static library, then verify
# the pkg-config metadata. Both must match the locked source version.
cat > "$WORK/version-probe.c" <<'EOF'
#include <stdio.h>
#include <speex/speex.h>
int main(void) {
  const char *version = NULL;
  if (speex_lib_ctl(SPEEX_LIB_GET_VERSION_STRING, &version) != 0 || !version) return 1;
  puts(version);
  return 0;
}
EOF
"$CC" -isysroot "$SDKROOT" -arch arm64 -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
  -I "$STAGED_PREFIX/include" "$WORK/version-probe.c" "$STAGED_PREFIX/lib/libspeex.a" \
  -o "$WORK/version-probe" || sp_die "Speex version probe failed to compile"
BUILT_VERSION="$("$WORK/version-probe")" || sp_die "Speex version probe failed to run"
[ "$BUILT_VERSION" = "$VERSION" ] || sp_die "Speex embedded version $BUILT_VERSION does not match lock $VERSION"
PC_VERSION="$(awk '$1 == "Version:" { print $2; exit }' "$STAGED_PREFIX/lib/pkgconfig/speex.pc")"
[ "$PC_VERSION" = "$VERSION" ] || sp_die "speex.pc version ${PC_VERSION:-unknown} does not match lock $VERSION"
echo "  ✓ speex $BUILT_VERSION"
sp_write_stamp "$STAGED_PREFIX/.build-stamp.json" "${RECIPE_ARGS[@]}"
sp_atomic_replace_directory "$STAGED_PREFIX" "$PREFIX"
echo "==> Complete: $PREFIX (recipe ${RECIPE_HASH:0:12})"
