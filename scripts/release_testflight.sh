#!/usr/bin/env bash
# Build and publish Phrayo to an existing internal TestFlight group.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ID="${ASC_APP_ID:-}"
TESTFLIGHT_GROUP="${ASC_TESTFLIGHT_GROUP:-}"
TIMEOUT="${ASC_TESTFLIGHT_TIMEOUT:-45m}"
PREFERRED_XCODE="${PREFERRED_XCODE:-/Applications/Xcode-26.6.0.app/Contents/Developer}"

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
step() { printf '==> %s\n' "$*"; }

usage() {
  cat <<'EOF'
Usage: scripts/release_testflight.sh <version> <build>

Build a release IPA and publish to an existing internal TestFlight group.
Version must use x.y.z; build must be a positive integer.

Required environment:
  ASC_APP_ID              Phrayo's numeric App Store Connect app ID
  ASC_TESTFLIGHT_GROUP    One existing internal group name or ID
Optional environment:
  ASC_TESTFLIGHT_TIMEOUT  Upload/processing timeout (default 45m)
  DEVELOPER_DIR           Explicit Xcode Developer directory
  PREFERRED_XCODE         Preferred Xcode when DEVELOPER_DIR is unset
                         (default /Applications/Xcode-26.6.0.app/Contents/Developer)

Requires a clean Git worktree, asc authentication, distribution signing for
Runner and PhrayoActivity, and an explicit ITSAppUsesNonExemptEncryption=false
declaration in ios/Runner/Info.plist. Configure that declaration only after
checking the app's encryption use. The script does not set it automatically.
EOF
}

if [[ $# -eq 1 && ( "$1" == --help || "$1" == -h ) ]]; then usage; exit 0; fi
[[ $# -eq 2 ]] || die "Usage: $0 <version> <build>. Use --help for setup."
VERSION="$1"
BUILD_NUMBER="$2"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Version must use x.y.z format."
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || die "Build must be a positive integer."
[[ "$APP_ID" =~ ^[1-9][0-9]*$ ]] || die "Set ASC_APP_ID to Phrayo's numeric App Store Connect app ID."
[[ -n "$TESTFLIGHT_GROUP" && "$TESTFLIGHT_GROUP" != *,* ]] ||
  die "Set ASC_TESTFLIGHT_GROUP to one existing internal group name or ID."
for tool in flutter asc git python3 xcodebuild; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found in PATH."
done

cd "$ROOT_DIR"
WORKTREE_STATUS="$(git status --porcelain --untracked-files=normal)" || die "Unable to check Git worktree."
[[ -z "$WORKTREE_STATUS" ]] || die "Working tree is dirty. Commit or stash changes before publishing."

# Fail before building if the project's explicit declaration is missing.
python3 - "$ROOT_DIR/ios/Runner/Info.plist" <<'CHECK_ENCRYPTION'
import plistlib, sys
from xml.parsers.expat import ExpatError
try:
    with open(sys.argv[1], 'rb') as stream:
        info = plistlib.load(stream)
    if info.get('ITSAppUsesNonExemptEncryption') is not False:
        sys.exit('Error: This release workflow requires ITSAppUsesNonExemptEncryption=false '
                 'in ios/Runner/Info.plist. Check the app\'s encryption use and configure '
                 'its export-compliance declaration before releasing.')
except (OSError, ValueError, TypeError, AttributeError, ExpatError) as error:
    sys.exit(f'Error: Cannot read iOS release metadata: {error}')
CHECK_ENCRYPTION

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  step "Using DEVELOPER_DIR: $DEVELOPER_DIR"
elif [[ -d "$PREFERRED_XCODE" ]]; then
  export DEVELOPER_DIR="$PREFERRED_XCODE"
  step "Using Xcode: $DEVELOPER_DIR"
else
  step "Preferred Xcode is unavailable; using the active Xcode toolchain"
fi

step "Checking App Store Connect authentication"
asc auth doctor
RELEASE_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/phrayo-testflight.XXXXXX")"
trap 'rm -rf "$RELEASE_TEMP_DIR"' EXIT
asc apps view --id "$APP_ID" --output json > "$RELEASE_TEMP_DIR/app.json"
asc testflight groups list --app "$APP_ID" --internal --paginate --output json > "$RELEASE_TEMP_DIR/groups.json"
python3 - "$RELEASE_TEMP_DIR" "$APP_ID" "$TESTFLIGHT_GROUP" > "$RELEASE_TEMP_DIR/group-id" <<'CHECK_DESTINATION'
import json, sys
from pathlib import Path
try:
    root = Path(sys.argv[1])
    app = json.loads((root / 'app.json').read_text())['data']
    if app['id'] != sys.argv[2] or app['attributes']['bundleId'] != 'app.capyvibe.phrayo':
        sys.exit('Error: ASC_APP_ID does not identify app.capyvibe.phrayo. Set it to Phrayo\'s app ID.')
    groups = json.loads((root / 'groups.json').read_text())['data']
    matches = [group for group in groups
               if group['attributes'].get('isInternalGroup') is True
               and sys.argv[3] in (group['id'], group['attributes'].get('name'))]
    if len(matches) != 1:
        sys.exit('Error: ASC_TESTFLIGHT_GROUP must identify exactly one internal group for Phrayo. '
                 'Check asc testflight groups list --app "$ASC_APP_ID" --internal.')
    print(matches[0]['id'])
except (OSError, ValueError, KeyError, TypeError) as error:
    sys.exit(f'Error: Cannot verify the App Store Connect destination: {error}')
CHECK_DESTINATION
GROUP_ID="$(cat "$RELEASE_TEMP_DIR/group-id")"

# Flutter can finish an archive even when IPA export fails. Remove old export
# files so a previous IPA can never be mistaken for this build's output.
shopt -s nullglob
OLD_IPAS=("$ROOT_DIR"/build/ios/ipa/*.ipa)
if [[ ${#OLD_IPAS[@]} -gt 0 ]]; then rm -f "${OLD_IPAS[@]}"; fi
step "Building Phrayo $VERSION ($BUILD_NUMBER)"
flutter build ipa --release --target lib/main.dart \
  --build-name "$VERSION" --build-number "$BUILD_NUMBER"

IPAS=("$ROOT_DIR"/build/ios/ipa/*.ipa)
[[ ${#IPAS[@]} -eq 1 ]] || die "Expected one IPA in build/ios/ipa, found ${#IPAS[@]}. Check the archive export and signing for both targets."
IPA="${IPAS[0]}"

# Python's standard ZIP/plist readers handle binary plists and avoid BSD awk
# regex differences. Inspect the actual packaged app and embedded extension.
python3 - "$IPA" "$VERSION" "$BUILD_NUMBER" <<'CHECK_IPA'
import plistlib, re, sys, zipfile
from xml.parsers.expat import ExpatError

def fail(message):
    sys.exit(f'Error: {message}. Rebuild the IPA before publishing.')

def check_identity(info, bundle_id, label):
    if info.get('CFBundleIdentifier') != bundle_id:
        fail(f'{label} bundle ID does not match {bundle_id}')
    if info.get('CFBundleShortVersionString') != sys.argv[2]:
        fail(f'{label} version does not match {sys.argv[2]}')
    if info.get('CFBundleVersion') != sys.argv[3]:
        fail(f'{label} build does not match {sys.argv[3]}')

try:
    with zipfile.ZipFile(sys.argv[1]) as archive:
        names = archive.namelist()
        app_plists = [name for name in names if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', name)]
        if len(app_plists) != 1:
            fail('IPA must contain exactly one app Info.plist')
        app_path = app_plists[0]
        app = plistlib.loads(archive.read(app_path))
        check_identity(app, 'app.capyvibe.phrayo', 'App')
        if app.get('ITSAppUsesNonExemptEncryption') is not False:
            fail('Packaged app must declare ITSAppUsesNonExemptEncryption=false')
        extension_path = app_path.removesuffix('Info.plist') + 'PlugIns/PhrayoActivity.appex/Info.plist'
        if names.count(extension_path) != 1:
            fail('IPA must contain the PhrayoActivity extension Info.plist exactly once')
        extension = plistlib.loads(archive.read(extension_path))
        check_identity(extension, 'app.capyvibe.phrayo.liveactivity', 'Live Activity')
except (OSError, ValueError, KeyError, TypeError, AttributeError, RuntimeError,
        NotImplementedError, ExpatError, zipfile.BadZipFile) as error:
    fail(f'Unable to validate IPA metadata: {error}')
CHECK_IPA

step "Publishing $VERSION ($BUILD_NUMBER) to $TESTFLIGHT_GROUP"
asc publish testflight --app "$APP_ID" --ipa "$IPA" \
  --version "$VERSION" --build-number "$BUILD_NUMBER" --group "$GROUP_ID" \
  --wait --timeout "$TIMEOUT" --output table
step "Published Phrayo $VERSION ($BUILD_NUMBER) to internal TestFlight"
