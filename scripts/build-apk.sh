#!/usr/bin/env bash
# Build Phrayo's arm64 APK and stage it in dist/.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_TYPE="release"

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) BUILD_TYPE="release" ;;
    --debug) BUILD_TYPE="debug" ;;
    -h|--help)
      cat <<'EOF'
Usage: scripts/build-apk.sh [--release|--debug]

Build an arm64 APK; release is the default. Requires an Android project.
Outputs: dist/Phrayo.apk or dist/Phrayo-debug.apk
Optional environment: BUILD_NAME, BUILD_NUMBER (Flutter version overrides).
EOF
      exit 0
      ;;
    *) die "Unknown option: $1. Use --help." ;;
  esac
  shift
done

[[ -d "$ROOT_DIR/android/app" ]] ||
  die "Phrayo has no Android project. Add Android support before building an APK."
command -v flutter >/dev/null 2>&1 || die "flutter not found in PATH."

BUILD_ARGS=()
[[ -z "${BUILD_NAME:-}" ]] || BUILD_ARGS+=(--build-name "$BUILD_NAME")
[[ -z "${BUILD_NUMBER:-}" ]] || BUILD_ARGS+=(--build-number "$BUILD_NUMBER")

cd "$ROOT_DIR"
printf '==> Building Phrayo Android %s (arm64)\n' "$BUILD_TYPE"
flutter pub get
BUILT_APK="$ROOT_DIR/build/app/outputs/flutter-apk/app-$BUILD_TYPE.apk"
rm -f "$BUILT_APK"
flutter build apk "--$BUILD_TYPE" --no-pub --target lib/main.dart \
  --target-platform android-arm64 ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}

[[ -f "$BUILT_APK" ]] || die "APK not found after build: $BUILT_APK"
OUT_APK="$ROOT_DIR/dist/Phrayo.apk"
[[ "$BUILD_TYPE" != debug ]] || OUT_APK="$ROOT_DIR/dist/Phrayo-debug.apk"
mkdir -p "$ROOT_DIR/dist"
cp -f "$BUILT_APK" "$OUT_APK"
printf '==> Built %s\n' "$OUT_APK"
