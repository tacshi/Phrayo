#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$TEMP/cache" \
  "$ROOT/ios/Runner/RecordingDrain.swift" \
  "$ROOT/scripts/recording_drain_tests.swift" -o "$TEMP/recording-tests"
"$TEMP/recording-tests"
