#!/bin/bash
# Build the optional Real-CUGAN in-process adapter in this checkout only.
# It does not install or modify Homebrew, Vulkan, or the installed Khua app.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
for cmd in git cmake brew python3 install_name_tool codesign shasum; do command -v "$cmd" >/dev/null || { echo "missing $cmd" >&2; exit 1; }; done
commit=395302c5c70f1bff604c974e92e0a87e45c9f9ee
ncnn_commit=066614351391d309c96ae1e00c6fb1bd873b4949
deps="$repo_root/.build/deps-realcugan"
if [ ! -d "$deps/.git" ]; then
  git clone https://github.com/nihui/realcugan-ncnn-vulkan.git "$deps"
  git -C "$deps" checkout --detach "$commit"
fi
[ "$(git -C "$deps" rev-parse HEAD)" = "$commit" ] || { echo "Real-CUGAN dependency is not the locked commit" >&2; exit 1; }
git -C "$deps" submodule update --init --recursive src/ncnn
ncnn="$deps/src/ncnn"
[ "$(git -C "$ncnn" rev-parse HEAD)" = "$ncnn_commit" ] || { echo "ncnn dependency is not the locked commit" >&2; exit 1; }
patch="$repo_root/ThirdParty/realcugan/ncnn-portability.patch"
if git -C "$ncnn" apply --reverse --check "$patch" >/dev/null 2>&1; then :; else git -C "$ncnn" apply --check "$patch" && git -C "$ncnn" apply "$patch"; fi
molten="$(brew --prefix molten-vk)/lib/libMoltenVK.dylib"
[ "$(shasum -a 256 "$molten" | awk '{print $1}')" = e21bceade8d0638bb2bc041f3166fbd54da19fa0958d8bbaff584afd7958d542 ] || { echo "MoltenVK binary differs from the validated version" >&2; exit 1; }
headers="$(brew --prefix vulkan-headers)/include"
src="$repo_root/.build/realcugan-generated-source"; build="$repo_root/.build/realcugan-runtime-build"; runtime="$repo_root/.build/realcugan-runtime"
mkdir -p "$src" "$runtime"
if [ ! -e "$src/ncnn" ]; then ln -s "$ncnn" "$src/ncnn"; fi
[ "$(cd "$src/ncnn" && pwd -P)" = "$(cd "$ncnn" && pwd -P)" ] || { echo "generated source points to a different ncnn tree" >&2; exit 1; }
cp "$deps"/src/*.comp "$deps/src/generate_shader_comp_header.cmake" "$src/"
git -C "$deps" show HEAD:src/CMakeLists.txt > "$src/CMakeLists.upstream.txt"
python3 - "$src/CMakeLists.upstream.txt" "$src/CMakeLists.txt" <<'PY'
import sys
s=open(sys.argv[1]).read()
a=s.index('if(USE_SYSTEM_WEBP)'); b=s.index('realcugan_add_shader(realcugan_preproc.comp)',a); c=s.index('add_executable(realcugan-ncnn-vulkan',b)
s=s[:a]+s[b:c]+'''\nadd_library(khua_realcugan SHARED ${KHUA_REPO_ROOT}/ThirdParty/realcugan/realcugan.cpp ${KHUA_REPO_ROOT}/ThirdParty/realcugan/KhuaRealCUGAN.cpp)\ntarget_include_directories(khua_realcugan PRIVATE ${KHUA_REPO_ROOT}/ThirdParty/realcugan)\ntarget_link_libraries(khua_realcugan ncnn ${Vulkan_LIBRARY})\nadd_dependencies(khua_realcugan generate-spirv)\nset_target_properties(khua_realcugan PROPERTIES MACOSX_RPATH ON INSTALL_NAME_DIR "@rpath")\n'''
open(sys.argv[2],'w').write(s)
PY
cmake -S "$src" -B "$build" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DNCNN_VULKAN=ON -DVulkan_INCLUDE_DIR="$headers" -DVulkan_LIBRARY="$molten" -DKHUA_REPO_ROOT="$repo_root"
cmake --build "$build" --parallel 6 --target khua_realcugan
for existing in "$runtime/libkhua_realcugan.dylib" "$runtime/libMoltenVK.dylib"; do
  [ ! -e "$existing" ] || chmod u+w "$existing"
done
cp "$build/libkhua_realcugan.dylib" "$runtime/"; cp -L "$molten" "$runtime/"
chmod u+w "$runtime/libkhua_realcugan.dylib"
molten_id="$(otool -D "$molten" | tail -1)"
install_name_tool -id @rpath/libkhua_realcugan.dylib -change "$molten_id" @loader_path/libMoltenVK.dylib "$runtime/libkhua_realcugan.dylib"
codesign --force --sign - "$runtime/libkhua_realcugan.dylib"
shasum -a 256 "$runtime"/*.dylib > "$runtime/SHA256.txt"
echo "Real-CUGAN runtime ready: $runtime (macOS 14 minimum)"
