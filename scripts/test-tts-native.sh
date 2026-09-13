#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$TEMP/cache" \
  "$ROOT/ios/Runner/SpeechPlayback.swift" \
  "$ROOT/ios/Runner/SpeechLanguage.swift" \
  "$ROOT/ios/Runner/VoiceModel.swift" \
  "$ROOT/ios/Runner/VoiceTextSegments.swift" \
  "$ROOT/ios/Runner/VoiceAudioCache.swift" \
  "$ROOT/scripts/tts_native_tests.swift" -o "$TEMP/tts-tests"
"$TEMP/tts-tests"
