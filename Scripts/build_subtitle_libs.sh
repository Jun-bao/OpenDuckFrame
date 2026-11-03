#!/bin/bash
# OpenDuckFrame — reproducible libass dylib with a fully static dependency chain.
# Output: ThirdParty/subtitles-min/lib/libass.9.dylib (macOS 14+, arm64).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/build_common.sh
source "$SCRIPT_DIR/lib/build_common.sh"
sp_reset_build_env

DEPENDENCIES=(libpng freetype fribidi libunibreak graphite2 harfbuzz libass)
PREFIX="$SP_THIRDPARTY/subtitles-min"
STAMP="$PREFIX/.build-stamp.json"
REQUIRED_OUTPUTS=(
  "$PREFIX/lib/libass.9.dylib"
  "$PREFIX/include/ass/ass.h"
)
MESON="$(sp_find_tool meson /opt/homebrew/bin/meson)"
NINJA="$(sp_find_tool ninja /opt/homebrew/bin/ninja)"
CMAKE="$(sp_find_tool cmake /opt/homebrew/bin/cmake)"
MAKE="$(sp_find_tool make /usr/bin/make)"
PKG_CONFIG_BIN="$(sp_find_tool pkg-config /opt/homebrew/bin/pkg-config)"
JOBS="$(sysctl -n hw.ncpu)"

RECIPE_ARGS=(
  --input "$SP_ROOT/Scripts/build_subtitle_libs.sh"
  --input "$SP_ROOT/Scripts/lib/build_common.sh"
  --input "$SP_ROOT/Scripts/lib/deps_lock.py"
  --tool "ar=$AR"
  --tool "clang=$CC"
  --tool "cmake=$CMAKE"
  --tool "ld=$LD"
  --tool "make=$MAKE"
  --tool "meson=$MESON"
  --tool "ninja=$NINJA"
  --tool "pkg-config=$PKG_CONFIG_BIN"
  --tool "ranlib=$RANLIB"
  --tool "xcodebuild=/usr/bin/xcodebuild"
  --parameter "prefix=$PREFIX"
  --parameter "sdk_version=$SP_SDK_VERSION"
)
for dependency in "${DEPENDENCIES[@]}"; do
  RECIPE_ARGS+=(--dependency "$dependency")
done
RECIPE_HASH="$(sp_recipe_hash "${RECIPE_ARGS[@]}")"
if sp_all_files_exist "${REQUIRED_OUTPUTS[@]}" && sp_stamp_matches "$STAMP" "$RECIPE_HASH"; then
  echo "==> Subtitle stack already matches the current recipe"
  exit 0
fi

mkdir -p "$SP_DOWNLOADS"
for dependency in "${DEPENDENCIES[@]}"; do
  sp_verified_download \
    "$(sp_lock_get "$dependency" url)" \
    "$(sp_lock_get "$dependency" sha256)" \
    "$SP_DOWNLOADS/$(sp_lock_get "$dependency" archive)"
done

WORK="$(mktemp -d "$SP_THIRDPARTY/.subtitles-build.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
SOURCE_ROOT="$WORK/src"
DESTDIR="$WORK/dest"
STAGED_PREFIX="$DESTDIR$PREFIX"
mkdir -p "$SOURCE_ROOT" "$STAGED_PREFIX/lib/pkgconfig"

for dependency in "${DEPENDENCIES[@]}"; do
  sp_extract_archive \
    "$SP_DOWNLOADS/$(sp_lock_get "$dependency" archive)" \
    "$SOURCE_ROOT"
done

# pkg-config only sees libraries installed in this staged recipe. The sysroot
# maps the final absolute prefix recorded in .pc files into DESTDIR while the
# next dependency is being built.
export PKG_CONFIG="$PKG_CONFIG_BIN"
export PKG_CONFIG_PATH=""
export PKG_CONFIG_LIBDIR="$STAGED_PREFIX/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$DESTDIR"
MINFLAG="-isysroot $SDKROOT -arch arm64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
export CFLAGS="$MINFLAG -O2"
export CXXFLAGS="$MINFLAG -O2"
export CPPFLAGS="-I$STAGED_PREFIX/include -I$STAGED_PREFIX/include/freetype2"
export LDFLAGS="$MINFLAG -L$STAGED_PREFIX/lib"

# libpng's .pc requires zlib. This explicit SDK stub avoids finding Homebrew's
# zlib while keeping the dependency visible to Meson/pkg-config.
printf '%s\n' \
  'Name: zlib' \
  'Description: macOS SDK zlib' \
  'Version: 1.2.12' \
  'Libs: -lz' \
  'Cflags:' \
  > "$STAGED_PREFIX/lib/pkgconfig/zlib.pc"

meson_install() {
  local build_dir="$1"
  "$NINJA" -C "$build_dir" -j "$JOBS"
  "$MESON" install -C "$build_dir" --destdir "$DESTDIR"
}

echo "==> 1/7 libpng $(sp_lock_get libpng version)"
LIBPNG_SOURCE="$SOURCE_ROOT/$(sp_lock_get libpng source_dir)"
(cd "$LIBPNG_SOURCE" && \
  ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-tools && \
  "$MAKE" -j"$JOBS" && \
  "$MAKE" DESTDIR="$DESTDIR" install)

MESON_COMMON=(
  --wrap-mode=nofallback
  --default-library=static
  --buildtype=release
  -Dc_args="$CFLAGS"
  -Dc_link_args="$LDFLAGS"
)

echo "==> 2/7 freetype $(sp_lock_get freetype version)"
FT_BUILD="$WORK/freetype-build"
"$MESON" setup "$FT_BUILD" "$SOURCE_ROOT/$(sp_lock_get freetype source_dir)" \
  --prefix="$PREFIX" "${MESON_COMMON[@]}" \
  -Dpng=enabled -Dharfbuzz=disabled -Dbrotli=disabled \
  -Dzlib=system -Dtests=disabled
meson_install "$FT_BUILD"

echo "==> 3/7 fribidi $(sp_lock_get fribidi version)"
FRIBIDI_BUILD="$WORK/fribidi-build"
"$MESON" setup "$FRIBIDI_BUILD" "$SOURCE_ROOT/$(sp_lock_get fribidi source_dir)" \
  --prefix="$PREFIX" "${MESON_COMMON[@]}" \
  -Ddocs=false -Dtests=false -Dbin=false
meson_install "$FRIBIDI_BUILD"

echo "==> 4/7 libunibreak $(sp_lock_get libunibreak version)"
UNIBREAK_SOURCE="$SOURCE_ROOT/$(sp_lock_get libunibreak source_dir)"
(cd "$UNIBREAK_SOURCE" && \
  ./configure --prefix="$PREFIX" --disable-shared --enable-static && \
  "$MAKE" -j"$JOBS" && \
  "$MAKE" DESTDIR="$DESTDIR" install)

echo "==> 5/7 graphite2 $(sp_lock_get graphite2 version)"
GRAPHITE_BUILD="$WORK/graphite2-build"
"$CMAKE" \
  -S "$SOURCE_ROOT/$(sp_lock_get graphite2 source_dir)" \
  -B "$GRAPHITE_BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_TESTING=OFF \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_OSX_SYSROOT="$SDKROOT" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/opt/X11"
"$CMAKE" --build "$GRAPHITE_BUILD" --target graphite2 -j "$JOBS"
# The upstream top-level install unconditionally visits the optional
# gr2fonttest directory even when only the library target was requested. Install
# the library subtree (which includes headers) and its generated .pc explicitly.
DESTDIR="$DESTDIR" "$CMAKE" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -P "$GRAPHITE_BUILD/src/cmake_install.cmake"
cp "$GRAPHITE_BUILD/graphite2.pc" "$STAGED_PREFIX/lib/pkgconfig/graphite2.pc"

echo "==> 6/7 harfbuzz $(sp_lock_get harfbuzz version)"
HB_BUILD="$WORK/harfbuzz-build"
"$MESON" setup "$HB_BUILD" "$SOURCE_ROOT/$(sp_lock_get harfbuzz source_dir)" \
  --prefix="$PREFIX" "${MESON_COMMON[@]}" \
  -Dfreetype=enabled -Dcoretext=enabled -Dgraphite2=enabled \
  -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dicu=disabled \
  -Dchafa=disabled -Dtests=disabled -Ddocs=disabled -Dbenchmark=disabled \
  -Dutilities=disabled -Dcpp_args="$CXXFLAGS" -Dcpp_link_args="$LDFLAGS"
meson_install "$HB_BUILD"

echo "==> 7/7 libass $(sp_lock_get libass version)"
LIBASS_SOURCE="$SOURCE_ROOT/$(sp_lock_get libass source_dir)"
(cd "$LIBASS_SOURCE" && \
  PKG_CONFIG="$PKG_CONFIG_BIN --static" LIBS="-lc++ -lbz2" \
    ./configure --prefix="$PREFIX" --enable-shared --disable-static \
      --disable-fontconfig && \
  "$MAKE" -j"$JOBS" && \
  "$MAKE" DESTDIR="$DESTDIR" install)

# Libtool archives are unnecessary for the app and retain the random staging
# directory in dependency_libs, defeating byte-for-byte prefix reproducibility.
find "$STAGED_PREFIX" \( -type f -o -type l \) -name '*.la' -delete

# Inspect generated compiler/linker configs, not just the final dylib. Any
# absolute search root outside sources, staged output, or the SDK fails closed.
CONFIG_ARGS=()
for config in \
  "$LIBPNG_SOURCE/Makefile" \
  "$FT_BUILD/build.ninja" \
  "$FRIBIDI_BUILD/build.ninja" \
  "$UNIBREAK_SOURCE/Makefile" \
  "$GRAPHITE_BUILD/CMakeCache.txt" \
  "$HB_BUILD/build.ninja" \
  "$LIBASS_SOURCE/Makefile"; do
  CONFIG_ARGS+=(--config "$config")
done
python3 "$SP_DEPS_HELPER" verify-search-paths \
  "${CONFIG_ARGS[@]}" \
  --allow-root "$SOURCE_ROOT" \
  --allow-root "$WORK" \
  --allow-root "$PREFIX" \
  --allow-root "$STAGED_PREFIX"

DYLIB="$STAGED_PREFIX/lib/libass.9.dylib"
for output in "${REQUIRED_OUTPUTS[@]}"; do
  staged_output="$STAGED_PREFIX/${output#"$PREFIX/"}"
  [ -s "$staged_output" ] || sp_die "subtitle stack installation is missing: ${output#"$PREFIX/"}"
done
/usr/bin/install_name_tool -id "@rpath/libass.9.dylib" "$DYLIB"
[ "$(lipo -archs "$DYLIB")" = "arm64" ] || sp_die "libass architecture is not arm64"
if otool -L "$DYLIB" | grep -Eq '/opt/homebrew|/usr/local|/opt/X11'; then
  otool -L "$DYLIB" >&2
  sp_die "libass still references a package-manager dynamic library"
fi
MINOS="$(vtool -show-build "$DYLIB" | awk '/minos/ {print $2; exit}')"
case "$MINOS" in
  10.*|11.*|12.*|13.*|14.*) ;;
  *) sp_die "libass has an incompatible minimum OS version: ${MINOS:-unknown}" ;;
esac

DYLIB_STRINGS="$(strings -a "$DYLIB")"
DYLIB_SYMBOLS="$(nm "$DYLIB")"
assert_embedded_version() {
  local name="$1"
  local expected="$2"
  case "$DYLIB_STRINGS" in
    *"$expected"*) echo "  ✓ $name $expected" ;;
    *) sp_die "$name version assertion failed: $expected" ;;
  esac
}
assert_embedded_version libpng "libpng version $(sp_lock_get libpng version)"
assert_embedded_version harfbuzz "$(sp_lock_get harfbuzz version)"
assert_embedded_version libass "$(sp_lock_get libass version)"
case "$DYLIB_SYMBOLS" in
  *gr_face*) echo "  ✓ graphite2 is linked statically" ;;
  *) sp_die "graphite2 is not linked statically into libass" ;;
esac

FT_HEADER="$STAGED_PREFIX/include/freetype2/freetype/freetype.h"
FT_VERSION="$(awk '/#define FREETYPE_MAJOR/{a=$3} /#define FREETYPE_MINOR/{b=$3} /#define FREETYPE_PATCH/{c=$3} END{print a"."b"."c}' "$FT_HEADER")"
[ "$FT_VERSION" = "$(sp_lock_get freetype version)" ] || sp_die "freetype header version does not match the lock: $FT_VERSION"
GRAPHITE_HEADER="$STAGED_PREFIX/include/graphite2/Font.h"
GRAPHITE_VERSION="$(awk '/GR2_VERSION_MAJOR/{a=$3} /GR2_VERSION_MINOR/{b=$3} /GR2_VERSION_BUGFIX/{c=$3} END{print a"."b"."c}' "$GRAPHITE_HEADER")"
[ "$GRAPHITE_VERSION" = "$(sp_lock_get graphite2 version)" ] || sp_die "graphite2 header version does not match the lock: $GRAPHITE_VERSION"

sp_write_stamp "$STAGED_PREFIX/.build-stamp.json" "${RECIPE_ARGS[@]}"
sp_atomic_replace_directory "$STAGED_PREFIX" "$PREFIX"
echo "==> Complete: $PREFIX (recipe ${RECIPE_HASH:0:12})"
