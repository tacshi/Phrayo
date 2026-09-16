#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
NDK="$SDK/ndk/28.2.13676358"
[[ -f "$NDK/build/cmake/android.toolchain.cmake" ]] || {
  printf 'Install Android NDK 28.2.13676358 in %s/ndk.\n' "$SDK" >&2; exit 1;
}
python3 "$ROOT_DIR/scripts/prepare-android-voice.py"
python3 "$ROOT_DIR/scripts/patch-android-voice-profile.py"
python3 "$ROOT_DIR/scripts/convert-android-voice-profile.py"
VULKAN="${PHRAYO_VULKAN:-OFF}"
BUILD="$ROOT_DIR/build/android-native/arm64-$VULKAN"
EXTRA=()
if [[ "$VULKAN" == ON ]]; then
  cmake -S "$ROOT_DIR/build/android-native/SPIRV-Headers-04fd3caa1e8267e4d95c806cad901181728e1006" \
    -B "$ROOT_DIR/build/android-native/spirv-build" -G Ninja \
    -DCMAKE_INSTALL_PREFIX="$ROOT_DIR/build/android-native/spirv-install"
  cmake --install "$ROOT_DIR/build/android-native/spirv-build"
  EXTRA+=(-DVulkan_GLSLC_EXECUTABLE="$(command -v glslc)")
fi
cmake -S "$ROOT_DIR/native/android-voice" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=31 -DANDROID_STL=c++_shared \
  -DPHRAYO_VULKAN="$VULKAN" -DPHRAYO_PROFILE="${PHRAYO_PROFILE:-OFF}" ${EXTRA[@]+"${EXTRA[@]}"}
cmake --build "$BUILD" --target phrayo_cosyvoice --parallel 4
LIBS="$ROOT_DIR/build/android-native/jniLibs-$VULKAN/arm64-v8a"
mkdir -p "$LIBS"
cp "$BUILD/libphrayo_cosyvoice.so" "$LIBS/"
cp "$NDK/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$LIBS/"
