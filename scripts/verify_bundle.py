"""Validate the processed iOS bundle, not only source plists."""
import plistlib
import sys
from pathlib import Path

bundle = Path(sys.argv[1] if len(sys.argv) > 1 else 'build/ios/iphoneos/Runner.app')
with (bundle / 'Info.plist').open('rb') as stream:
    app = plistlib.load(stream)
assert app['CFBundleIdentifier'] == 'app.capyvibe.phrayo'
assert float(app['MinimumOSVersion']) >= 26
assert app['NSMicrophoneUsageDescription']
assert app['NSSupportsLiveActivities']
assert 'audio' in app['UIBackgroundModes']
assert (bundle / app['CFBundleExecutable']).is_file()
assert (bundle / 'Assets.car').is_file()
with (bundle / 'PrivacyInfo.xcprivacy').open('rb') as stream:
    privacy = plistlib.load(stream)
assert any(item['NSPrivacyAccessedAPIType'] == 'NSPrivacyAccessedAPICategoryUserDefaults'
           and 'CA92.1' in item['NSPrivacyAccessedAPITypeReasons']
           for item in privacy['NSPrivacyAccessedAPITypes'])
for locale, name in [('en', 'Phrayo'), ('zh-Hans', '句芽'), ('zh-Hant', '句芽')]:
    with (bundle / f'{locale}.lproj' / 'InfoPlist.strings').open('rb') as stream:
        strings = plistlib.load(stream)
    assert strings['CFBundleDisplayName'] == name
extension = bundle / 'PlugIns/PhrayoActivity.appex'
with (extension / 'Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
assert info['CFBundleIdentifier'] == 'app.capyvibe.phrayo.liveactivity'
assert info['CFBundleName']
assert info['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.widgetkit-extension'
assert (extension / info['CFBundleExecutable']).is_file()
print(f'Bundle verified: {bundle} — identity, iOS minimum, localized names, audio, privacy and Live Activity')
