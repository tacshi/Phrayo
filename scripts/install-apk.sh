#!/usr/bin/env bash
# Build once and install on selected Android devices.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_TYPE="debug"
SKIP_BUILD=0
LAUNCH=0
ALL_DEVICES=0
APK_PATH=""
REQUESTED_SERIALS=()
SELECTED_SERIALS=()

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "$1 not found in PATH. $2"; }

find_aapt() {
  local sdk candidate local_sdk=""
  if command -v aapt >/dev/null 2>&1; then
    command -v aapt
    return 0
  fi
  if [[ -f "$ROOT_DIR/android/local.properties" ]]; then
    local_sdk="$(sed -n 's/^sdk\.dir=//p' "$ROOT_DIR/android/local.properties" | head -n 1 | tr -d '\r')"
  fi
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$local_sdk" \
    "${HOME:-}/Library/Android/sdk" "${HOME:-}/Android/Sdk"; do
    [[ -n "$sdk" ]] || continue
    for candidate in "$sdk"/build-tools/*/aapt; do
      if [[ -x "$candidate" && -f "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  done
  return 1
}

usage() {
  cat <<'EOF'
Usage: scripts/install-apk.sh [options]

Build and install Phrayo on connected Android devices.
  --release         Build/install release (requires Android qualification)
  --debug           Build/install debug (default)
  --skip-build      Install the existing APK for the selected build type
  --apk PATH        Install a specific APK (implies --skip-build)
  --device SERIAL   Select a device; repeat to select several
  --all             Select all authorized devices
  --launch          Launch after installation (requires Android SDK aapt)
  -h, --help        Show help

One device is selected automatically. With multiple devices, choose
interactively or pass --device/--all in noninteractive runs.
Building requires Android support; existing APKs can be installed without it.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) BUILD_TYPE="release" ;;
    --debug) BUILD_TYPE="debug" ;;
    --skip-build) SKIP_BUILD=1 ;;
    --apk)
      [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die "--apk requires a path."
      APK_PATH="$2"; SKIP_BUILD=1; shift
      ;;
    --device)
      [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die "--device requires a serial."
      REQUESTED_SERIALS+=("$2"); shift
      ;;
    --all) ALL_DEVICES=1 ;;
    --launch) LAUNCH=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1. Use --help." ;;
  esac
  shift
done

((ALL_DEVICES == 0 || ${#REQUESTED_SERIALS[@]} == 0)) ||
  die "Use either --all or --device, not both."
if [[ "$SKIP_BUILD" -eq 0 && ! -d "$ROOT_DIR/android/app" ]]; then
  die "Phrayo has no Android project. Add Android support before building, or use --apk PATH to install an existing APK."
fi

if [[ -z "$APK_PATH" ]]; then
  APK_PATH="$ROOT_DIR/build/app/outputs/flutter-apk/app-$BUILD_TYPE.apk"
elif [[ "$APK_PATH" != /* ]]; then
  APK_PATH="$PWD/$APK_PATH"
fi
if [[ "$SKIP_BUILD" -eq 1 ]]; then
  [[ -f "$APK_PATH" ]] || die "APK not found: $APK_PATH. Pass --apk PATH or build it first."
fi
require_command adb "Add Android SDK platform-tools to PATH."
if [[ "$LAUNCH" -eq 1 ]]; then
  AAPT="$(find_aapt)" || die "aapt not found. Install Android SDK Build-Tools and set ANDROID_HOME or sdk.dir in android/local.properties."
fi

DEVICE_OUTPUT="$(adb devices -l)" || die "Unable to list Android devices. Check adb devices."
DEVICE_SERIALS=()
DEVICE_LABELS=()
while IFS=$'\t' read -r serial label; do
  [[ -n "$serial" ]] || continue
  DEVICE_SERIALS+=("$serial")
  DEVICE_LABELS+=("$label")
done < <(printf '%s\n' "$DEVICE_OUTPUT" | awk 'NR > 1 && $2 == "device" {
  label = $1
  for (i = 3; i <= NF; i++) {
    if ($i ~ /^model:/) {
      sub(/^model:/, "", $i)
      label = $i " (" $1 ")"
      break
    }
  }
  print $1 "\t" label
}')
[[ ${#DEVICE_SERIALS[@]} -gt 0 ]] ||
  die "No authorized Android device found. Enable USB debugging and check adb devices."

select_serial() {
  local candidate="$1" serial found=0
  for serial in "${DEVICE_SERIALS[@]}"; do
    [[ "$serial" != "$candidate" ]] || found=1
  done
  [[ "$found" -eq 1 ]] || die "Device is not connected or authorized: $candidate"
  for serial in ${SELECTED_SERIALS[@]+"${SELECTED_SERIALS[@]}"}; do
    [[ "$serial" != "$candidate" ]] || return 0
  done
  SELECTED_SERIALS+=("$candidate")
}

if [[ ${#REQUESTED_SERIALS[@]} -gt 0 ]]; then
  for serial in "${REQUESTED_SERIALS[@]}"; do select_serial "$serial"; done
elif [[ "$ALL_DEVICES" -eq 1 ]]; then
  for serial in "${DEVICE_SERIALS[@]}"; do select_serial "$serial"; done
elif [[ ${#DEVICE_SERIALS[@]} -eq 1 ]]; then
  select_serial "${DEVICE_SERIALS[0]}"
else
  [[ -t 0 ]] || die "Several devices are connected; pass --device SERIAL or --all."
  printf 'Connected Android devices:\n'
  for i in "${!DEVICE_SERIALS[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "${DEVICE_LABELS[$i]}"
  done
  printf 'Select devices (for example 1,3; a for all): '
  IFS= read -r selection || die "No device selected."
  if [[ "$selection" == a || "$selection" == A ]]; then
    for serial in "${DEVICE_SERIALS[@]}"; do select_serial "$serial"; done
  else
    selection="${selection//,/ }"
    # Split only on whitespace; never expand a user's selection as a glob.
    set -f
    for choice in $selection; do
      [[ "$choice" =~ ^[0-9]{1,6}$ ]] || die "Invalid selection: $choice"
      index=$((10#$choice - 1))
      [[ "$index" -ge 0 && "$index" -lt ${#DEVICE_SERIALS[@]} ]] || die "Selection out of range: $choice"
      select_serial "${DEVICE_SERIALS[$index]}"
    done
    set +f
  fi
fi
[[ ${#SELECTED_SERIALS[@]} -gt 0 ]] || die "No device selected."

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  "$ROOT_DIR/scripts/build-apk.sh" "--$BUILD_TYPE"
fi
[[ -f "$APK_PATH" ]] || die "APK not found: $APK_PATH"

if [[ "$LAUNCH" -eq 1 ]]; then
  BADGING="$("$AAPT" dump badging "$APK_PATH")" || die "Unable to inspect APK. Check the APK path and Android SDK aapt."
  PACKAGE_NAME="$(printf '%s\n' "$BADGING" | awk -F "'" '/^package: name=/ {print $2}')"
  MAIN_ACTIVITY="$(printf '%s\n' "$BADGING" | awk -F "'" '/^launchable-activity: name=/ {print $2}')"
  [[ "$PACKAGE_NAME" =~ ^[a-zA-Z0-9_.]+$ && "$MAIN_ACTIVITY" =~ ^[a-zA-Z0-9_.$]+$ ]] ||
    die "APK has no valid launchable activity. Omit --launch to install it."
fi

FAILED=0
for serial in "${SELECTED_SERIALS[@]}"; do
  printf '==> Installing on %s\n' "$serial"
  if ! adb -s "$serial" install --no-streaming -r "$APK_PATH"; then
    printf 'Error: Installation failed on %s. Check adb devices and retry with --device.\n' "$serial" >&2
    FAILED=1
    continue
  fi
  if [[ "$LAUNCH" -eq 1 ]]; then
    # adb joins shell arguments remotely; preserve nested-class '$' literally.
    # The validated identifiers above cannot contain single quotes.
    if LAUNCH_OUTPUT="$(adb -s "$serial" shell am start -W -n "'$PACKAGE_NAME/$MAIN_ACTIVITY'" 2>&1)" &&
      ! printf '%s\n' "$LAUNCH_OUTPUT" | grep -Eq '^Error(:| type )|^Exception|^Status: (timeout|error)'; then
      printf '==> Launched on %s\n' "$serial"
    else
      printf 'Error: Launch failed on %s: %s\n' "$serial" "$LAUNCH_OUTPUT" >&2
      FAILED=1
    fi
  fi
  printf '==> Installed %s on %s\n' "$APK_PATH" "$serial"
done
exit "$FAILED"
