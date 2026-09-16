#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="$ROOT_DIR/build/android-native/probe-assets"
mkdir -p "$ASSETS"
cp "$ROOT_DIR/build/android-native/phrayo-lj025.gguf" "$ASSETS/"
cp "$ROOT_DIR/native/android-voice/dependencies.json" "$ASSETS/"
mkdir -p "$ASSETS/licenses"
cp "$ROOT_DIR/native/android-voice/licenses/"*.txt "$ASSETS/licenses/"
cp "$ROOT_DIR/build/android-native/cosyvoice.cpp-1616b12215407193fafb08111e7fd2939f977789/LICENSE" "$ASSETS/licenses/cosyvoice-MIT.txt"
cp "$ROOT_DIR/build/android-native/ggml-e91ded11bdcd78c42f9c8d3978ff6686eb4c1226/LICENSE" "$ASSETS/licenses/ggml-MIT.txt"
cp "$ROOT_DIR/build/android-native/pcre2-7978954dbd2efc6f2196869290553cf1871b4ce6/COPYING" "$ASSETS/licenses/pcre2.txt"
cp "$ROOT_DIR/build/android-native/simde-71fd833d9666141edcd1d3c109a80e228303d8d7/COPYING" "$ASSETS/licenses/simde-MIT.txt"
cp "$ROOT_DIR/ios/Runner/VoiceAssets/NOTICE.md" "$ASSETS/licenses/voice-provenance.md"
cp "$ROOT_DIR/ios/Runner/VoiceAssets/mecab-BSD.txt" "$ASSETS/licenses/mecab-BSD.txt"
cp "$ROOT_DIR/ios/Runner/VoiceAssets/ipadic-COPYING.txt" "$ASSETS/licenses/ipadic-COPYING.txt"
cp "$ROOT_DIR/build/android-native/cosyvoice.cpp-1616b12215407193fafb08111e7fd2939f977789/MODEL_LICENSE.md" "$ASSETS/licenses/GGUF-model-license.md"
cp "$ROOT_DIR/build/android-native/Vulkan-Headers-ee2ec5fd83dafce291024683b50dc89219333076/LICENSE.md" "$ASSETS/licenses/Vulkan-Headers.txt"
cp "$ROOT_DIR/build/android-native/SPIRV-Headers-04fd3caa1e8267e4d95c806cad901181728e1006/LICENSE" "$ASSETS/licenses/SPIRV-Headers.txt"
mkdir -p "$ASSETS/ipadic"
for name in sys.dic unk.dic char.bin matrix.bin dicrc; do
  cp "$ROOT_DIR/build/android-native/Mecab-Swift-1f096492e37fc05fc2e7304091f54889974c5368/Sources/IPADic/ipadic dictionary/$name" "$ASSETS/ipadic/"
done
