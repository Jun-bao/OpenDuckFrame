#!/bin/bash
# Prepare the optional, lazily loaded experimental Anime4K runtime. This is
# intentionally isolated under the checkout; it does not change system Vulkan.
# Current locked prebuilt components have macOS 27 minimum. A portable
# release needs its own source build targeting the supported minimum OS.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
for cmd in pkg-config brew install_name_tool codesign shasum; do command -v "$cmd" >/dev/null || { echo "missing $cmd" >&2; exit 1; }; done
[ "$(pkg-config --modversion libplacebo)" = "7.360.1" ]
[ "$(pkg-config --modversion shaderc)" = "2026.4.1" ]
[ "$(pkg-config --modversion lcms2)" = "2.19" ]
placebo_lib="$(pkg-config --variable=libdir libplacebo)/libplacebo.360.dylib"
shaderc_lib="$(pkg-config --variable=libdir shaderc)/libshaderc_shared.1.dylib"
lcms_lib="$(pkg-config --variable=libdir lcms2)/liblcms2.2.dylib"
molten_lib="$(brew --prefix molten-vk)/lib/libMoltenVK.dylib"
check() { [ "$(shasum -a 256 "$1" | awk '{print $1}')" = "$2" ] || { echo "dependency hash mismatch: $1" >&2; exit 1; }; }
check "$placebo_lib" a312f9dafbc689c2fcf0c02f4f4fa8dc1bffe460b4edd5b645bafb46375fdf3c
check "$shaderc_lib" 90987a60123cebb6c01221b03979ace770c8b8ace971f37814cd5261b3352354
check "$lcms_lib" b43de9af9f34128b5c5d12a37510383208e96d352147d31f486cf01341fd16cb
check "$molten_lib" e21bceade8d0638bb2bc041f3166fbd54da19fa0958d8bbaff584afd7958d542
runtime_dir="$repo_root/.build/anime4k-runtime"
mkdir -p "$runtime_dir"
for existing in "$runtime_dir"/*.dylib; do
  [ ! -e "$existing" ] || chmod u+w "$existing"
done
cp -L "$placebo_lib" "$shaderc_lib" "$lcms_lib" "$molten_lib" "$runtime_dir/"
chmod u+w "$runtime_dir/libplacebo.360.dylib"
install_name_tool -id @rpath/libplacebo.360.dylib \
  -change /opt/homebrew/opt/shaderc/lib/libshaderc_shared.1.dylib @loader_path/libshaderc_shared.1.dylib \
  -change /opt/homebrew/opt/little-cms2/lib/liblcms2.2.dylib @loader_path/liblcms2.2.dylib \
  -change /opt/homebrew/opt/vulkan-loader/lib/libvulkan.1.dylib @loader_path/libMoltenVK.dylib \
  "$runtime_dir/libplacebo.360.dylib"
codesign --force --sign - "$runtime_dir/libplacebo.360.dylib"
shasum -a 256 "$runtime_dir"/*.dylib > "$runtime_dir/SHA256.txt"
echo "Optional Anime4K runtime ready: $runtime_dir (macOS 27 minimum)"
