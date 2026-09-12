"""Exercise installer routing with fake tools; never builds or touches a device."""
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parent
MOCK = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
name=Path(sys.argv[0]).name
args=sys.argv[1:]
with open(os.environ['INSTALL_TEST_LOG'],'a') as f: f.write(json.dumps([name,*args])+'\\n')
if name=='xcrun' and args[:3]==['devicectl','list','devices']:
    Path(args[args.index('--json-output')+1]).write_text(os.environ['INSTALL_TEST_DEVICES'])
if name=='xcrun' and args[:4]==['devicectl','device','info','ddiServices']:
    if args[args.index('--device')+1]==os.environ.get('INSTALL_TEST_FAIL_PREFLIGHT'): sys.exit(1)
if name=='codesign' and os.environ.get('INSTALL_TEST_UNSIGNED'): sys.exit(1)
if name=='xcrun' and args[:4]==['devicectl','device','install','app']:
    if args[args.index('--device')+1]==os.environ.get('INSTALL_TEST_FAIL_DEVICE'): sys.exit(1)
'''

class InstallerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='phrayo installer ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        scripts = self.root / 'scripts'
        scripts.mkdir()
        for name in ('install-ios.sh', 'verify_bundle.py'):
            shutil.copy2(SOURCE / name, scripts / name)
        (self.root / 'ios/Runner.xcworkspace').mkdir(parents=True)
        self.app = self.root / 'build/ios/iphoneos/Runner.app'
        self.app.mkdir(parents=True)
        def plist(path, data):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(plistlib.dumps(data))
        plist(self.app/'Info.plist', dict(CFBundleIdentifier='app.capyvibe.phrayo',
            CFBundleExecutable='Runner', MinimumOSVersion='26.0',
            CFBundleSupportedPlatforms=['iPhoneOS'], NSMicrophoneUsageDescription='Record',
            NSSupportsLiveActivities=True, UIBackgroundModes=['audio']))
        for name in ('Runner', 'Assets.car'):
            (self.app/name).touch()
        plist(self.app/'PrivacyInfo.xcprivacy', dict(NSPrivacyAccessedAPITypes=[dict(
            NSPrivacyAccessedAPIType='NSPrivacyAccessedAPICategoryUserDefaults',
            NSPrivacyAccessedAPITypeReasons=['CA92.1'])]))
        for locale, name in [('en','Phrayo'),('zh-Hans','句芽'),('zh-Hant','句芽')]:
            plist(self.app/f'{locale}.lproj/InfoPlist.strings', dict(CFBundleDisplayName=name))
        extension=self.app/'PlugIns/PhrayoActivity.appex'
        plist(extension/'Info.plist', dict(CFBundleIdentifier='app.capyvibe.phrayo.liveactivity',
            CFBundleName='PhrayoActivity',CFBundleExecutable='PhrayoActivity',
            NSExtension=dict(NSExtensionPointIdentifier='com.apple.widgetkit-extension')))
        (extension/'PhrayoActivity').touch()
        tools = self.root/'tools'
        tools.mkdir()
        for name in ('flutter', 'xcrun', 'xcodebuild', 'codesign'):
            path=tools/name
            path.write_text(MOCK)
            path.chmod(0o755)
        self.log=self.root/'calls.jsonl'
        self.env=dict(os.environ, PATH=f'{tools}:{os.environ["PATH"]}',
            DEVELOPER_DIR='/mock/Xcode', INSTALL_TEST_LOG=str(self.log),
            INSTALL_TEST_DEVICES=json.dumps({'result':{'devices':[
                dict(identifier=f'CORE-{letter}',hardwareProperties=dict(reality='physical',
                    platform='iOS',udid=f'UDID-{letter}',deviceType='iPhone'),
                    deviceProperties=dict(name=f'Phone {letter}',bootState='booted',osVersionNumber='26.0'),
                    connectionProperties=dict(transportType='wired')) for letter in ('A','B')]}}))

    def run_script(self, *args):
        return subprocess.run(['/bin/bash', str(self.root/'scripts/install-ios.sh'), *args],
            cwd='/tmp',env=self.env,stdin=subprocess.DEVNULL,text=True,capture_output=True)

    def calls(self, command):
        return [row for row in map(json.loads,self.log.read_text().splitlines()) if row[0]==command] if self.log.exists() else []

    def test_release_build_once_installs_all_and_launches(self):
        result=self.run_script('--all','--no-clean','--launch')
        self.assertEqual(result.returncode,0,result.stderr)
        builds=[c for c in self.calls('flutter') if c[1:3]==['build','ios']]
        self.assertEqual(len(builds),1)
        self.assertIn('--release',builds[0])
        self.assertIn('lib/main.dart',builds[0])
        installs=[c for c in self.calls('xcrun') if c[1:5]==['devicectl','device','install','app']]
        self.assertEqual(len(installs),2)
        launches=[c for c in self.calls('xcrun') if c[1:5]==['devicectl','device','process','launch']]
        self.assertEqual(len(launches),2)
        self.assertEqual(launches[0][-1],'app.capyvibe.phrayo')

    def test_debug_runs_flutter_with_hardware_udid(self):
        result=self.run_script('--debug','--no-clean','--device','CORE-A')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('UDID-A',self.calls('flutter')[-1])
        self.assertEqual(self.calls('flutter')[-1][1],'run')
        self.assertFalse(any(c[2:4]==['device','install'] for c in self.calls('xcrun')))

    def test_debug_cannot_target_multiple_devices(self):
        result=self.run_script('--debug','--all')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(self.calls('flutter'))

    def test_existing_debug_bundle_rejected(self):
        path=self.app/'Frameworks/App.framework/flutter_assets/kernel_blob.bin'
        path.parent.mkdir(parents=True)
        path.touch()
        result=self.run_script('--app',str(self.app),'--device','UDID-A')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('Flutter Debug bundle',result.stderr)
        self.assertFalse(any('install' in c for c in self.calls('xcrun')))

    def test_unsigned_bundle_rejected(self):
        self.env['INSTALL_TEST_UNSIGNED']='1'
        result=self.run_script('--skip-build','--device','UDID-A')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any('install' in c for c in self.calls('xcrun')))

    def test_skip_build_does_not_run_flutter(self):
        result=self.run_script('--app',str(self.app),'--device','UDID-A','--device','CORE-A')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(self.calls('flutter'))
        self.assertEqual(len([c for c in self.calls('xcrun') if 'install' in c]),1)

    def test_profile_build(self):
        result=self.run_script('--profile','--no-clean','--device','UDID-A')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('--profile',self.calls('flutter')[-1])

    def test_noninteractive_ambiguous_selection_requires_explicit_target(self):
        result=self.run_script('--skip-build')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('Multiple devices',result.stderr)

    def test_install_failure_continues_other_devices_and_returns_failure(self):
        self.env['INSTALL_TEST_FAIL_DEVICE']='UDID-A'
        result=self.run_script('--skip-build','--all')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(len([c for c in self.calls('xcrun') if 'install' in c]),2)

    def test_preflight_failure_still_installs_ready_device_but_returns_failure(self):
        self.env['INSTALL_TEST_FAIL_PREFLIGHT']='UDID-B'
        result=self.run_script('--skip-build','--all')
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(len([c for c in self.calls('xcrun') if 'install' in c]),1)
        self.assertIn('preflight',result.stderr)

    def test_simulator_bundle_rejected(self):
        path=self.app/'Info.plist'
        data=plistlib.loads(path.read_bytes())
        data['CFBundleSupportedPlatforms']=['iPhoneSimulator']
        path.write_bytes(plistlib.dumps(data))
        result=self.run_script('--skip-build','--device','UDID-A')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any('install' in c for c in self.calls('xcrun')))

    def test_conflicting_selection_flags_rejected(self):
        result=self.run_script('--all','--device','UDID-A')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(self.log.exists())

if __name__ == '__main__':
    unittest.main()
