#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT_DIR/scripts/build-android-voice-native.sh"
"$ROOT_DIR/scripts/prepare-android-voice-assets.sh"
if [[ -z "${JAVA_HOME:-}" && -x /usr/libexec/java_home ]]; then
  export JAVA_HOME="$(/usr/libexec/java_home -v 21)"
fi
(cd "$ROOT_DIR/android" && ./gradlew :voiceProbe:assembleRelease -PvoiceBackend="${PHRAYO_VULKAN:-OFF}")
mkdir -p "$ROOT_DIR/dist"
cp "$ROOT_DIR/build/voiceProbe/outputs/apk/release/voiceProbe-release.apk" "$ROOT_DIR/dist/Phrayo-Voice-Check.apk"
printf 'Built %s/dist/Phrayo-Voice-Check.apk\n' "$ROOT_DIR"
