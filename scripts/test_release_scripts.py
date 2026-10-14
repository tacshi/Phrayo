"""Exercise build/release boundaries with fake tools; never install or upload."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import shlex
import subprocess
import tempfile
import unittest
import zipfile

SOURCE = Path(__file__).resolve().parent
SCRIPTS = ('build-apk.sh', 'install-apk.sh', 'release_testflight.sh')
MOCK = r'''#!/usr/bin/env python3
import json, os, shutil, sys
from pathlib import Path

tool = Path(sys.argv[0]).name
args = sys.argv[1:]
root = Path(os.environ['PHRAYO_TEST_ROOT'])
with open(os.environ['PHRAYO_TEST_LOG'], 'a') as stream:
    stream.write(json.dumps(dict(tool=tool, args=args, cwd=os.getcwd(),
                                developer_dir=os.environ.get('DEVELOPER_DIR'))) + '\n')
if tool == 'git':
    print(os.environ.get('PHRAYO_TEST_DIRTY', ''), end='')
elif tool == 'flutter':
    if os.environ.get('PHRAYO_TEST_BUILD_FAIL'):
        sys.exit(1)
    if args[:2] == ['build', 'apk']:
        if not os.environ.get('PHRAYO_TEST_NO_ARTIFACT'):
            mode = 'debug' if '--debug' in args else 'release'
            output = root / f'build/app/outputs/flutter-apk/app-{mode}.apk'
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(b'new APK')
    elif args[:2] == ['build', 'ipa']:
        output = root / 'build/ios/ipa'
        output.mkdir(parents=True, exist_ok=True)
        for number in range(int(os.environ.get('PHRAYO_TEST_IPA_COUNT', '1'))):
            shutil.copy2(root / 'fixture.ipa', output / f'Phrayo {number}.ipa')
elif tool == 'adb':
    if args == ['devices', '-l']:
        if os.environ.get('PHRAYO_TEST_DISCOVERY_FAIL'):
            sys.exit(1)
        print('List of devices attached')
        for serial, state in json.loads(os.environ['PHRAYO_TEST_DEVICES']):
            print(f'{serial}\t{state} product:test model:Phone_{serial} device:test')
    elif len(args) > 2 and args[2] == 'install':
        if args[1] == os.environ.get('PHRAYO_TEST_INSTALL_FAIL'):
            sys.exit(1)
        print('Success')
    elif len(args) > 2 and args[2] == 'shell':
        if args[1] == os.environ.get('PHRAYO_TEST_LAUNCH_FAIL'):
            # Android can print an error but return a successful shell status.
            print('Error: Activity not started')
        else:
            print('Status: ok')
elif tool == 'aapt':
    if os.environ.get('PHRAYO_TEST_AAPT_FAIL'):
        sys.exit(1)
    print("package: name='org.example.custom.debug' versionCode='1'")
    if not os.environ.get('PHRAYO_TEST_NO_ACTIVITY'):
        activity = os.environ.get('PHRAYO_TEST_ACTIVITY', 'org.example.MainActivity')
        print(f"launchable-activity: name='{activity}' label='Phrayo'")
elif tool == 'asc':
    if args[:2] == ['auth', 'doctor']:
        if os.environ.get('PHRAYO_TEST_AUTH_FAIL'):
            sys.exit(1)
    elif args[:2] == ['apps', 'view']:
        print(json.dumps(dict(data=dict(id=args[args.index('--id') + 1], attributes=dict(
            bundleId=os.environ.get('PHRAYO_TEST_ASC_BUNDLE', 'app.capyvibe.phrayo'))))))
    elif args[:3] == ['testflight', 'groups', 'list']:
        print(os.environ['PHRAYO_TEST_GROUPS'])
    elif args[:2] == ['publish', 'testflight']:
        if os.environ.get('PHRAYO_TEST_PUBLISH_FAIL'):
            sys.exit(1)
'''


class ReleaseScriptTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='phrayo release scripts ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        scripts = self.root / 'scripts'
        scripts.mkdir()
        for name in SCRIPTS:
            shutil.copy2(SOURCE / name, scripts / name)
        self.tools = self.root / 'tools'
        self.tools.mkdir()
        for name in ('flutter', 'adb', 'aapt', 'asc', 'git', 'xcodebuild'):
            path = self.tools / name
            path.write_text(MOCK)
            path.chmod(0o755)
        self.log = self.root / 'calls.jsonl'
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(('ASC_', 'BUILD_', 'PHRAYO_TEST_'))
                    and key not in ('DEVELOPER_DIR', 'PREFERRED_XCODE')}
        self.env.update(
            PATH=f'{self.tools}:{os.environ["PATH"]}',
            PHRAYO_TEST_ROOT=str(self.root), PHRAYO_TEST_LOG=str(self.log),
            PHRAYO_TEST_DEVICES=json.dumps([['A', 'device'], ['B', 'device'], ['C', 'unauthorized']]),
            ASC_APP_ID='12345', ASC_TESTFLIGHT_GROUP='Phrayo Testers',
            PREFERRED_XCODE=str(self.root / 'missing Xcode'),
            PHRAYO_TEST_GROUPS=json.dumps(dict(data=[dict(id='GROUP-1', attributes=dict(
                name='Phrayo Testers', isInternalGroup=True))])),
        )
        self.source_plist = self.root / 'ios/Runner/Info.plist'
        self.source_plist.parent.mkdir(parents=True)
        self.source_plist.write_bytes(plistlib.dumps(dict(ITSAppUsesNonExemptEncryption=False)))
        self.make_ipa()

    def make_ipa(self, app_changes=None, extension_changes=None, extension=True):
        app = dict(CFBundleIdentifier='app.capyvibe.phrayo',
                   CFBundleShortVersionString='2.3.4', CFBundleVersion='5',
                   ITSAppUsesNonExemptEncryption=False)
        activity = dict(CFBundleIdentifier='app.capyvibe.phrayo.liveactivity',
                        CFBundleShortVersionString='2.3.4', CFBundleVersion='5')
        app.update(app_changes or {})
        activity.update(extension_changes or {})
        with zipfile.ZipFile(self.root / 'fixture.ipa', 'w') as archive:
            prefix = 'Payload/Phrayo With Spaces.app/'
            archive.writestr(prefix + 'Info.plist', plistlib.dumps(app, fmt=plistlib.FMT_BINARY))
            if extension:
                archive.writestr(prefix + 'PlugIns/PhrayoActivity.appex/Info.plist',
                                 plistlib.dumps(activity, fmt=plistlib.FMT_BINARY))

    def android(self):
        (self.root / 'android/app').mkdir(parents=True)

    def apk(self):
        path = self.root / 'existing APK.apk'
        path.write_bytes(b'existing APK')
        return path

    def run_script(self, name, *args, selection=None):
        command = ['/bin/bash', str(self.root / 'scripts' / name), *args]
        if selection is None:
            return subprocess.run(command, cwd=self.root.parent, env=self.env, text=True,
                                  stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
        # Real terminal input exercises the interactive device picker.
        master, slave = os.openpty()
        try:
            os.write(master, (selection + '\n').encode())
            return subprocess.run(command, cwd=self.root.parent, env=self.env, text=True,
                                  stdin=slave, capture_output=True, timeout=15)
        finally:
            os.close(master)
            os.close(slave)

    def calls(self, tool=None):
        rows = list(map(json.loads, self.log.read_text().splitlines())) if self.log.exists() else []
        return [row for row in rows if tool is None or row['tool'] == tool]

    def clear_calls(self):
        self.log.unlink(missing_ok=True)

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_failed(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def publishes(self):
        return [row for row in self.calls('asc') if row['args'][:2] == ['publish', 'testflight']]

    def installs(self):
        return [row for row in self.calls('adb') if 'install' in row['args']]

    def test_help_and_invalid_arguments_have_no_external_side_effects(self):
        for name in SCRIPTS:
            with self.subTest(name=name):
                self.assert_ok(self.run_script(name, '--help'))
                self.assert_failed(self.run_script(name, '--unknown'))
        self.assertFalse(self.calls())

    def test_android_build_guards_run_before_tools(self):
        for name in ('build-apk.sh', 'install-apk.sh'):
            result = self.run_script(name)
            self.assert_failed(result)
            self.assertIn('no Android project', result.stderr)
        self.assertFalse(self.calls())

    def test_android_project_allows_debug_integration(self):
        (self.root / 'android/app').mkdir(parents=True)
        result = self.run_script('build-apk.sh', '--debug')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / 'dist/Phrayo-debug.apk').is_file())

    def test_default_install_launch_uses_debug_and_explicit_release(self):
        self.android()
        self.env['PHRAYO_TEST_DEVICES'] = json.dumps([['A', 'device']])
        self.assert_ok(self.run_script('install-apk.sh', '--launch'))
        builds = [row for row in self.calls('flutter') if row['args'][:2] == ['build', 'apk']]
        self.assertEqual(len(builds), 1)
        self.assertIn('--debug', builds[0]['args'])
        self.assertTrue(self.installs()[0]['args'][-1].endswith('app-debug.apk'))
        self.assertTrue(any('shell' in row['args'] for row in self.calls('adb')))
        self.clear_calls()
        self.assert_ok(self.run_script('install-apk.sh', '--release', '--launch'))
        self.assertTrue(self.installs()[0]['args'][-1].endswith('app-release.apk'))
        builds = [row for row in self.calls('flutter') if row['args'][:2] == ['build', 'apk']]
        self.assertIn('--release', builds[0]['args'])

    def test_android_project_builds_release_apk(self):
        self.android()
        self.assert_ok(self.run_script('build-apk.sh', '--release'))
        self.assertTrue((self.root / 'dist/Phrayo.apk').is_file())
        builds = [row for row in self.calls('flutter') if row['args'][:2] == ['build', 'apk']]
        self.assertIn('--release', builds[0]['args'])

    def test_build_modes_and_overrides_from_path_with_spaces(self):
        self.android()
        self.env.update(BUILD_NAME='2.3.4', BUILD_NUMBER='5')
        for mode, output in [('release', 'Phrayo.apk'), ('debug', 'Phrayo-debug.apk')]:
            with self.subTest(mode=mode):
                self.clear_calls()
                self.assert_ok(self.run_script('build-apk.sh', '--' + mode))
                self.assertEqual((self.root / 'dist' / output).read_bytes(), b'new APK')
                calls = self.calls('flutter')
                self.assertEqual(len(calls), 2)
                self.assertEqual(calls[0]['args'], ['pub', 'get'])
                self.assertEqual(calls[1]['args'], ['build', 'apk', '--' + mode, '--no-pub',
                    '--target', 'lib/main.dart', '--target-platform', 'android-arm64',
                    '--build-name', '2.3.4', '--build-number', '5'])
                self.assertEqual(Path(calls[1]['cwd']), self.root)

    def test_failed_or_empty_build_does_not_stage_stale_apk(self):
        self.android()
        old = self.root / 'build/app/outputs/flutter-apk/app-release.apk'
        old.parent.mkdir(parents=True)
        old.write_bytes(b'stale')
        self.env['PHRAYO_TEST_NO_ARTIFACT'] = '1'
        self.assert_failed(self.run_script('build-apk.sh'))
        self.assertFalse((self.root / 'dist/Phrayo.apk').exists())
        self.env['PHRAYO_TEST_BUILD_FAIL'] = '1'
        self.assert_failed(self.run_script('install-apk.sh', '--all'))
        self.assertFalse(self.installs())

    def test_build_once_for_deduplicated_devices(self):
        self.android()
        self.assert_ok(self.run_script('install-apk.sh', '--device', 'B', '--device', 'B', '--device', 'A'))
        self.assertEqual(len([row for row in self.calls('flutter') if row['args'][:2] == ['build', 'apk']]), 1)
        self.assertEqual([row['args'][1] for row in self.installs()], ['B', 'A'])
        self.assertTrue(all('--no-streaming' in row['args'] for row in self.installs()))

    def test_explicit_relative_apk_launch_uses_packaged_identity(self):
        apk = self.apk()
        self.env['PHRAYO_TEST_ACTIVITY'] = 'org.example.Main$Activity'
        relative_apk = os.path.relpath(apk, self.root.parent)
        self.assert_ok(self.run_script('install-apk.sh', '--apk', relative_apk, '--all', '--launch'))
        self.assertFalse(self.calls('flutter'))
        self.assertEqual([row['args'][1] for row in self.installs()], ['A', 'B'])
        self.assertTrue(all(row['args'][-1] == str(apk) for row in self.installs()))
        launches = [row for row in self.calls('adb') if 'shell' in row['args']]
        self.assertEqual(len(launches), 2)
        self.assertTrue(all(shlex.split(row['args'][-1]) == ['org.example.custom.debug/org.example.Main$Activity']
                            for row in launches))
        self.assertTrue(all(row['args'][-1].startswith("'") for row in launches))

    def test_launch_finds_aapt_outside_path(self):
        sdk = self.root / 'Android SDK'
        aapt = sdk / 'build-tools/36.0.0/aapt'
        aapt.parent.mkdir(parents=True)
        shutil.move(self.tools / 'aapt', aapt)
        incomplete = sdk / 'build-tools/99.0.0/aapt'
        incomplete.parent.mkdir(parents=True)
        incomplete.write_text('not executable')
        self.android()
        properties = self.root / 'android/local.properties'
        apk = self.apk()
        for source in ('ANDROID_HOME', 'ANDROID_SDK_ROOT', 'local.properties'):
            with self.subTest(source=source):
                self.clear_calls()
                self.env.pop('ANDROID_HOME', None)
                self.env.pop('ANDROID_SDK_ROOT', None)
                if source == 'local.properties':
                    properties.write_text(f'sdk.dir={sdk}\n')
                else:
                    self.env[source] = str(sdk)
                self.assert_ok(self.run_script(
                    'install-apk.sh', '--apk', str(apk), '--device', 'A', '--launch'))
                self.assertEqual(len(self.calls('aapt')), 1)
                self.assertEqual(len(self.installs()), 1)
                self.assertTrue(any('shell' in row['args'] for row in self.calls('adb')))

    def test_skip_build_selects_debug_output(self):
        apk = self.root / 'build/app/outputs/flutter-apk/app-debug.apk'
        apk.parent.mkdir(parents=True)
        apk.write_bytes(b'debug')
        self.assert_ok(self.run_script('install-apk.sh', '--skip-build', '--debug', '--device', 'A'))
        self.assertEqual(self.installs()[0]['args'][-1], str(apk))
        self.assertFalse(self.calls('flutter'))

    def test_sole_authorized_device_is_selected(self):
        self.env['PHRAYO_TEST_DEVICES'] = json.dumps([['A', 'device'], ['B', 'offline']])
        self.assert_ok(self.run_script('install-apk.sh', '--apk', str(self.apk())))
        self.assertEqual([row['args'][1] for row in self.installs()], ['A'])

    def test_device_selection_errors_do_not_install(self):
        apk = self.apk()
        for args in [(), ('--device', 'C'), ('--all', '--device', 'A')]:
            with self.subTest(args=args):
                self.assert_failed(self.run_script('install-apk.sh', '--apk', str(apk), *args))
        self.assertFalse(self.installs())

    def test_interactive_selection_deduplicates_and_rejects_invalid_input(self):
        apk = self.apk()
        self.assert_ok(self.run_script('install-apk.sh', '--apk', str(apk), selection='02,1,2'))
        self.assertEqual([row['args'][1] for row in self.installs()], ['B', 'A'])
        self.clear_calls()
        self.assert_failed(self.run_script('install-apk.sh', '--apk', str(apk), selection='*'))
        self.assertFalse(self.installs())

    def test_discovery_failure_and_no_devices_do_not_install(self):
        apk = self.apk()
        self.env['PHRAYO_TEST_DEVICES'] = json.dumps([['A', 'offline']])
        self.assert_failed(self.run_script('install-apk.sh', '--apk', str(apk), '--all'))
        self.env['PHRAYO_TEST_DISCOVERY_FAIL'] = '1'
        self.assert_failed(self.run_script('install-apk.sh', '--apk', str(apk), '--all'))
        self.assertFalse(self.installs())

    def test_install_and_launch_failures_continue_other_devices(self):
        apk = self.apk()
        for failure in ('PHRAYO_TEST_INSTALL_FAIL', 'PHRAYO_TEST_LAUNCH_FAIL'):
            with self.subTest(failure=failure):
                self.clear_calls()
                self.env[failure] = 'A'
                self.assert_failed(self.run_script('install-apk.sh', '--apk', str(apk), '--all', '--launch'))
                self.assertEqual(len(self.installs()), 2)
                del self.env[failure]

    def test_unlaunchable_apk_fails_before_install(self):
        self.env['PHRAYO_TEST_NO_ACTIVITY'] = '1'
        self.assert_failed(self.run_script('install-apk.sh', '--apk', str(self.apk()), '--all', '--launch'))
        self.assertFalse(self.installs())

    def test_release_validates_arguments_and_environment_overrides(self):
        for args in [('2.3', '5'), ('2.3.4', '0'), ('2.3.4', '-1'), ('2.3.4', '5', 'extra')]:
            self.assert_failed(self.run_script('release_testflight.sh', *args))
        for key, value in (('ASC_APP_ID', 'phrayo'), ('ASC_TESTFLIGHT_GROUP', 'A,B')):
            original = self.env[key]
            self.env[key] = value
            self.assert_failed(self.run_script('release_testflight.sh', '2.3.4', '5'))
            self.env[key] = original
        self.assertFalse(self.calls())

    def test_release_defaults_to_phrayo_and_its_internal_group(self):
        del self.env['ASC_APP_ID'], self.env['ASC_TESTFLIGHT_GROUP']
        self.env['PHRAYO_TEST_GROUPS'] = json.dumps(dict(data=[dict(id='GROUP-1', attributes=dict(
            name='Phrayo Internal Testers', isInternalGroup=True))]))
        self.assert_ok(self.run_script('release_testflight.sh', '2.3.4', '5'))
        upload = self.publishes()[0]['args']
        self.assertEqual(upload[upload.index('--app') + 1], '6812285544')
        self.assertEqual(upload[upload.index('--group') + 1], 'GROUP-1')

    def test_dirty_worktree_blocks_release_before_authentication(self):
        self.env['PHRAYO_TEST_DIRTY'] = '?? new-file\n'
        self.assert_failed(self.run_script('release_testflight.sh', '2.3.4', '5'))
        self.assertFalse(self.calls('asc'))
        self.assertFalse(self.calls('flutter'))

    def test_missing_or_nonboolean_encryption_declaration_blocks_build(self):
        for declaration in ({}, {'ITSAppUsesNonExemptEncryption': 'false'},
                            {'ITSAppUsesNonExemptEncryption': True}):
            self.source_plist.write_bytes(plistlib.dumps(declaration))
            result = self.run_script('release_testflight.sh', '2.3.4', '5')
            self.assert_failed(result)
            self.assertIn('export-compliance', result.stderr)
        self.assertFalse(self.calls('asc'))
        self.assertFalse(self.calls('flutter'))

    def test_authentication_failure_blocks_build(self):
        self.env['PHRAYO_TEST_AUTH_FAIL'] = '1'
        self.assert_failed(self.run_script('release_testflight.sh', '2.3.4', '5'))
        self.assertFalse(self.calls('flutter'))

    def test_wrong_app_or_external_group_blocks_build(self):
        self.env['PHRAYO_TEST_ASC_BUNDLE'] = 'com.115lab.clean'
        self.assert_failed(self.run_script('release_testflight.sh', '2.3.4', '5'))
        del self.env['PHRAYO_TEST_ASC_BUNDLE']
        self.env['PHRAYO_TEST_GROUPS'] = json.dumps(dict(data=[dict(id='GROUP-1', attributes=dict(
            name='Phrayo Testers', isInternalGroup=False))]))
        self.assert_failed(self.run_script('release_testflight.sh', '2.3.4', '5'))
        self.assertFalse(self.calls('flutter'))

    def test_valid_binary_ipa_is_published_to_internal_group(self):
        self.env.update(DEVELOPER_DIR='/explicit Xcode/Contents/Developer', ASC_TESTFLIGHT_TIMEOUT='12m')
        self.assert_ok(self.run_script('release_testflight.sh', '2.3.4', '5'))
        build = self.calls('flutter')[0]
        self.assertEqual(build['args'], ['build', 'ipa', '--release', '--target', 'lib/main.dart',
                                        '--build-name', '2.3.4', '--build-number', '5'])
        self.assertEqual(build['developer_dir'], self.env['DEVELOPER_DIR'])
        upload = self.publishes()[0]['args']
        self.assertEqual(upload[upload.index('--group') + 1], 'GROUP-1')
        self.assertEqual(upload[upload.index('--timeout') + 1], '12m')
        self.assertIn('--wait', upload)
        self.assertNotIn('--notify', upload)
        self.assertNotIn('--submit', upload)

    def test_preferred_xcode_group_id_and_default_timeout(self):
        preferred = self.root / 'preferred Xcode/Contents/Developer'
        preferred.mkdir(parents=True)
        self.env.update(PREFERRED_XCODE=str(preferred), ASC_TESTFLIGHT_GROUP='GROUP-1')
        self.assert_ok(self.run_script('release_testflight.sh', '2.3.4', '5'))
        self.assertEqual(self.calls('flutter')[0]['developer_dir'], str(preferred))
        self.assertIn('45m', self.publishes()[0]['args'])

    def test_failed_or_missing_export_never_uploads_old_ipa(self):
        old = self.root / 'build/ios/ipa/old.ipa'
        old.parent.mkdir(parents=True)
        shutil.copy2(self.root / 'fixture.ipa', old)
        self.env['PHRAYO_TEST_IPA_COUNT'] = '0'
        self.assert_failed(self.run_script('release_testflight.sh', '2.3.4', '5'))
        self.assertFalse(old.exists())
        self.env['PHRAYO_TEST_BUILD_FAIL'] = '1'
        self.assert_failed(self.run_script('release_testflight.sh', '2.3.4', '5'))
        self.assertFalse(self.publishes())

    def test_multiple_ipas_or_malformed_archive_block_upload(self):
        self.env['PHRAYO_TEST_IPA_COUNT'] = '2'
        self.assert_failed(self.run_script('release_testflight.sh', '2.3.4', '5'))
        self.env['PHRAYO_TEST_IPA_COUNT'] = '1'
        (self.root / 'fixture.ipa').write_bytes(b'not a zip file')
        self.assert_failed(self.run_script('release_testflight.sh', '2.3.4', '5'))
        self.assertFalse(self.publishes())

    def test_malformed_plist_reports_recovery_without_traceback(self):
        invalid_xml = b'<?xml version="1.0"?><plist><dict>broken'
        with zipfile.ZipFile(self.root / 'fixture.ipa', 'w') as archive:
            archive.writestr('Payload/Runner.app/Info.plist', invalid_xml)
        result = self.run_script('release_testflight.sh', '2.3.4', '5')
        self.assert_failed(result)
        self.assertIn('Rebuild the IPA', result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        self.assertFalse(self.publishes())
        self.clear_calls()
        self.source_plist.write_bytes(invalid_xml)
        result = self.run_script('release_testflight.sh', '2.3.4', '5')
        self.assert_failed(result)
        self.assertIn('Cannot read iOS release metadata', result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        self.assertFalse(self.calls('flutter'))

    def test_app_and_extension_metadata_mismatches_block_upload(self):
        for target in ('app_changes', 'extension_changes'):
            for key, value in [('CFBundleIdentifier', 'wrong.app'), ('CFBundleShortVersionString', '1.0.0'),
                               ('CFBundleVersion', '1')]:
                with self.subTest(target=target, key=key):
                    self.make_ipa(**{target: {key: value}})
                    self.assert_failed(self.run_script('release_testflight.sh', '2.3.4', '5'))
        self.make_ipa(extension=False)
        self.assert_failed(self.run_script('release_testflight.sh', '2.3.4', '5'))
        self.make_ipa(app_changes={'ITSAppUsesNonExemptEncryption': True})
        self.assert_failed(self.run_script('release_testflight.sh', '2.3.4', '5'))
        self.assertFalse(self.publishes())

    def test_publish_failure_is_reported_as_failure(self):
        self.env['PHRAYO_TEST_PUBLISH_FAIL'] = '1'
        result = self.run_script('release_testflight.sh', '2.3.4', '5')
        self.assert_failed(result)
        self.assertNotIn('Published Phrayo', result.stdout)


if __name__ == '__main__':
    unittest.main()
