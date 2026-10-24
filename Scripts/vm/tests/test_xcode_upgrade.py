import contextlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('upgrade_host', Path(__file__).resolve().parents[1] / 'host.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)
upgrade = host.xcode_upgrade_module()


class XcodeUpgradeTests(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.directory = Path(self.stack.enter_context(tempfile.TemporaryDirectory())).resolve()
        self.root = self.directory / 'repository'
        self.state = self.directory / 'state'
        self.state.mkdir()
        self.paths = upgrade.pin_paths(self.root)
        for path in self.paths:
            path.parent.mkdir(parents=True, exist_ok=True)
        self.environment = host.read_json(host.TOOLS / 'environment.json')
        self.environment['xcode'] = {'version': '27.0', 'buildVersion': '27A266a'}
        self.environment['safariSynchronization']['framework'].update(
            version='25228', imageUUID='6C9998E3-2351-34D3-BAAB-B523F500A26A')
        self.environment['localPreference'] = {'preserve': True}
        self.paths[0].write_text(json.dumps(self.environment, indent=2) + '\n')
        self.paths[1].write_bytes(upgrade.pins_module().render_safari_header(self.environment))
        for path in self.paths:
            path.chmod(0o644)
        self.xcode = self.directory / 'Selected Xcode' / 'Xcode.app'
        (self.xcode / 'Contents/_CodeSignature').mkdir(parents=True)
        (self.xcode / 'Contents/_CodeSignature/CodeResources').write_bytes(b'signed resources')
        self.target_xcode = {'version': '27.1', 'buildVersion': '27A9275'}
        (self.xcode / 'Contents/version.plist').write_bytes(plistlib.dumps({
            'CFBundleShortVersionString': '27.1', 'ProductBuildVersion': '27A9275'}))
        self.framework = self.xcode / 'Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks/XCUIAutomation.framework'
        self.framework.mkdir(parents=True)
        (self.framework / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.apple.dt.XCUIAutomation',
            'CFBundleVersion': '25229', 'CFBundleExecutable': 'XCUIAutomation'}))
        self.target_framework = {'bundleIdentifier': 'com.apple.dt.XCUIAutomation', 'version': '25229',
                                 'imageUUID': '8BF9E0BC-F620-35F8-9F7E-49542744F323'}
        self.stack.enter_context(patch.object(host, 'ROOT', self.root))
        self.checked = self.stack.enter_context(patch.object(host, 'checked', side_effect=self.command))
        self.output = self.stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
        self.args = host.parser().parse_args(['--xcode', str(self.xcode), '--state-dir', str(self.state), 'upgrade-xcode'])

    def command(self, command, **kwargs):
        if command[0] == '/usr/bin/codesign':
            self.assertEqual(command, ['/usr/bin/codesign', '--verify', '--strict', self.xcode])
            return b''
        self.assertEqual(command[:3], ['/usr/bin/xcrun', 'dwarfdump', '--uuid'])
        self.assertEqual(kwargs['env']['DEVELOPER_DIR'], str(self.xcode / 'Contents/Developer'))
        return 'UUID: 8BF9E0BC-F620-35F8-9F7E-49542744F323 (arm64) XCUIAutomation\n'

    def installed(self):
        return upgrade.inspect_xcode(host, self.xcode)

    def ready(self, pending=False, prepared=True):
        record = {'vmId': 'fixture', 'sourceVM': str(self.args.vm), 'verifiedAt': 'verified',
                  'consoleUser': 'wallet-test', 'environment': self.environment,
                  'safariPreparation': {'preparationRunID': 'prepared', 'receiptSHA256': 'a' * 64},
                  'safariPreparationResult': str(self.state / 'results/prepared/artifacts/result.json')}
        if not prepared:
            record.pop('safariPreparation')
            record.pop('safariPreparationResult')
        template = self.state / ('candidate.vbvm' if pending else 'baseline.vbvm')
        template.mkdir()
        if pending:
            metadata = template.lstat()
            record['promotionPending'] = {'candidateFileID': [metadata.st_dev, metadata.st_ino]}
        host.atomic_json(self.state / ('candidate.json' if pending else 'baseline.json'), record)
        self.stack.enter_context(patch.object(host, 'validate_vm', return_value={'hardware': {'cpuCount': 5}}))
        self.stack.enter_context(patch.object(host, 'check_capacity', return_value={'availableBytes': 123}))
        self.stack.enter_context(patch.object(host, 'manifest_node', return_value={'version': 'v26.5.0'}))
        self.stack.enter_context(patch.object(host, 'inherited_safari_preparation', side_effect=lambda state, record, user: {
            key: record[key] for key in ('safariPreparation', 'safariPreparationResult') if key in record}))

    def report(self):
        return host.read_json(Path(host.read_json(self.state / 'latest-xcode-upgrade.json')['result']))

    def test_inspection_uses_selected_signed_xcode_and_arm64_framework(self):
        value = self.installed()
        self.assertEqual(value['xcode'], self.target_xcode)
        self.assertEqual(value['safariSynchronization']['framework'], self.target_framework)
        self.assertEqual(self.checked.call_count, 2)

    def test_invalid_or_unsigned_xcode_never_changes_pins(self):
        original = [path.read_bytes() for path in self.paths]
        for invalid in ({'CFBundleShortVersionString': '27.1', 'ProductBuildVersion': 'bad'},
                        {'CFBundleShortVersionString': '27.1\n', 'ProductBuildVersion': '27A9275'}):
            (self.xcode / 'Contents/version.plist').write_bytes(plistlib.dumps(invalid))
            with self.assertRaisesRegex(host.RunnerError, 'invalid version/build'):
                self.installed()
        (self.xcode / 'Contents/version.plist').write_bytes(plistlib.dumps({
            'CFBundleShortVersionString': '27.1', 'ProductBuildVersion': '27A9275'}))
        with patch.object(host, 'checked', side_effect=host.RunnerError('invalid signature')):
            with self.assertRaisesRegex(host.RunnerError, 'invalid signature'):
                upgrade.upgrade(host, self.args, self.state)
        self.assertEqual([path.read_bytes() for path in self.paths], original)
        self.assertFalse((self.state / 'xcode-pin-update.json').exists())

    def test_missing_or_ambiguous_arm64_image_is_rejected(self):
        for output in ('UUID: 8BF9E0BC-F620-35F8-9F7E-49542744F323 (x86_64) image\n',
                       'UUID: 8BF9E0BC-F620-35F8-9F7E-49542744F323 (arm64) image\n' * 2):
            with patch.object(host, 'checked', side_effect=[b'', output]):
                with self.assertRaisesRegex(host.RunnerError, 'exactly one arm64'):
                    self.installed()

    def test_pin_adoption_preserves_other_settings_modes_and_noop_bytes(self):
        value = self.installed()
        target = upgrade.adopt_pins(host, self.state, self.root, value)
        self.assertEqual(target['xcode'], self.target_xcode)
        self.assertEqual(target['safariSynchronization']['framework'], self.target_framework)
        for key in set(self.environment) - {'xcode', 'safariSynchronization'}:
            self.assertEqual(target[key], self.environment[key])
        self.assertEqual(self.paths[1].read_bytes(), upgrade.pins_module().render_safari_header(target))
        before = [(path.read_bytes(), path.stat().st_mtime_ns) for path in self.paths]
        upgrade.adopt_pins(host, self.state, self.root, value)
        self.assertEqual([(path.read_bytes(), path.stat().st_mtime_ns) for path in self.paths], before)
        self.assertTrue(all(stat.S_IMODE(path.stat().st_mode) == 0o644 for path in self.paths))
        self.assertFalse((self.state / 'xcode-pin-update.json').exists())

    def interrupt_update(self):
        write = upgrade.write_pin
        def interrupted(host, path, *args):
            if path == self.paths[1]:
                raise OSError('interrupted before header replacement')
            return write(host, path, *args)
        with patch.object(upgrade, 'write_pin', side_effect=interrupted):
            with self.assertRaisesRegex(OSError, 'interrupted'):
                upgrade.adopt_pins(host, self.state, self.root, self.installed())

    def test_interrupted_pair_resumes_without_reverting_environment(self):
        self.interrupt_update()
        self.assertEqual(host.read_json(self.paths[0])['xcode'], self.target_xcode)
        self.assertTrue((self.state / 'xcode-pin-update.json').exists())
        target = upgrade.adopt_pins(host, self.state, self.root, self.installed())
        self.assertEqual(self.paths[1].read_bytes(), upgrade.pins_module().render_safari_header(target))
        self.assertFalse((self.state / 'xcode-pin-update.json').exists())

    def test_interrupted_pair_refuses_intervening_local_edits(self):
        self.interrupt_update()
        self.paths[1].write_text('local edit\n')
        with self.assertRaisesRegex(host.RunnerError, 'local edits'):
            upgrade.adopt_pins(host, self.state, self.root, self.installed())
        self.assertEqual(self.paths[1].read_text(), 'local edit\n')
        self.assertTrue((self.state / 'xcode-pin-update.json').exists())

    def test_manual_generated_pin_edit_is_not_overwritten(self):
        original = self.paths[0].read_bytes()
        self.paths[1].write_text('custom header\n')
        with self.assertRaisesRegex(host.RunnerError, 'preserve local edits'):
            upgrade.adopt_pins(host, self.state, self.root, self.installed())
        self.assertEqual(self.paths[0].read_bytes(), original)

    def test_check_does_not_create_state_mutate_sources_or_launch_vm(self):
        self.ready()
        self.args.check = True
        before = {str(path): (path.read_bytes(), path.stat().st_mtime_ns) for path in self.directory.rglob('*') if path.is_file()}
        with patch.object(host, 'private_directory', side_effect=AssertionError('No directories')), \
                patch.object(host, 'setup', side_effect=AssertionError('No setup')), \
                patch.object(host, 'run_tests', side_effect=AssertionError('No tests')):
            self.assertEqual(upgrade.upgrade(host, self.args, self.state), 0)
        after = {str(path): (path.read_bytes(), path.stat().st_mtime_ns) for path in self.directory.rglob('*') if path.is_file()}
        self.assertEqual(before, after)

    def test_main_check_does_not_create_missing_state(self):
        missing = self.directory / 'missing-state'
        self.stack.enter_context(patch.object(host, 'xcode_upgrade_module', return_value=upgrade))
        self.stack.enter_context(patch.object(host, 'validate_vm', return_value={'hardware': {'cpuCount': 5}}))
        self.stack.enter_context(patch.object(host, 'check_capacity', return_value={}))
        self.stack.enter_context(patch.object(host, 'manifest_node', return_value={}))
        with patch.object(host, 'private_directory', side_effect=AssertionError('No writes')):
            self.assertEqual(host.main(['--xcode', str(self.xcode), '--state-dir', str(missing), 'upgrade-xcode', '--check']), 2)
        self.assertFalse(missing.exists())

    def test_check_entrypoint_suppresses_dynamic_import_bytecode(self):
        wrapper = self.root / 'Scripts/test_vm.sh'
        shutil.copyfile(Path(__file__).resolve().parents[2] / 'test_vm.sh', wrapper)
        for name in ('host.py', 'xcode_upgrade.py', 'environment_pins.py'):
            shutil.copyfile(host.TOOLS / name, self.root / 'Scripts/vm' / name)
        missing = self.directory / 'absent-state'
        completed = subprocess.run(['/bin/sh', str(wrapper), '--xcode', str(self.xcode),
                                    '--state-dir', str(missing), 'upgrade-xcode', '--check'],
                                   capture_output=True, text=True, timeout=30)
        self.assertEqual(completed.returncode, 2)
        self.assertIn('codesign failed', completed.stderr)
        self.assertFalse(missing.exists())
        self.assertEqual(list(self.root.rglob('*.pyc')), [])

    def test_pending_promotion_can_reach_setup_without_baseline_bundle(self):
        self.ready(pending=True)
        report, _ = upgrade.preview(host, self.args, self.state)
        self.assertEqual(report['status'], 'ready')
        self.assertTrue(next(check for check in report['prerequisites'] if check['name'] == 'baseline')['detail']['promotionPending'])

    def test_invalid_safari_receipt_blocks_before_pin_adoption(self):
        self.ready()
        original = self.paths[0].read_bytes()
        with patch.object(host, 'inherited_safari_preparation', side_effect=host.RunnerError('invalid receipt')):
            self.assertEqual(upgrade.upgrade(host, self.args, self.state), 2)
        self.assertEqual(self.paths[0].read_bytes(), original)

    def test_missing_safari_preparation_allows_native_upgrade_before_requesting_activation(self):
        self.ready(prepared=False)
        original = self.paths[0].read_bytes()
        self.args.check = True
        self.assertEqual(upgrade.upgrade(host, self.args, self.state), 0)
        self.assertEqual(self.paths[0].read_bytes(), original)
        self.args.check = False

        def setup(args, state, environment, *, result_callback):
            self.assertEqual(environment['xcode'], self.target_xcode)
            self.assertEqual(host.read_json(self.paths[0])['xcode'], self.target_xcode)
            baseline = host.read_json(state / 'baseline.json')
            baseline['environment'] = environment
            host.atomic_json(state / 'baseline.json', baseline)
            result_callback(state / 'setup-result.json', {'status': 'passed'})
            return 0

        with patch.object(host, 'setup', side_effect=setup) as provision, \
                patch.object(host, 'run_tests', side_effect=AssertionError('Safari activation is still required')):
            self.assertEqual(upgrade.upgrade(host, self.args, self.state), 2)
        provision.assert_called_once()
        result = self.report()
        self.assertTrue(result['baselineSetupVerified'])
        self.assertFalse(result['fullSuiteVerified'])
        self.assertEqual(result['status'], 'blocked')
        self.assertEqual([step['status'] for step in result['steps']], ['passed', 'blocked'])
        self.assertIn('setup --interactive --safari-activation', result['steps'][-1]['reason'])

    def test_driver_runs_required_vm_sequence_and_demands_full_coverage(self):
        self.ready()
        commands = []
        def setup(args, state, environment, *, result_callback):
            commands.append(('setup', args.command))
            self.assertEqual(args.xcode, self.xcode)
            self.assertEqual(environment['runtimes'], self.environment['runtimes'])
            result_callback(self.state / 'setup-result.json', {'status': 'passed'})
            return 0
        def run(args, state, environment, *, result_callback):
            commands.append((args.stage, args.only_testing, args.configuration))
            self.assertEqual(args.signing, 'local')
            result_callback(self.state / f'run-{len(commands)}.json', {
                'status': 'passed', 'source': {'sha256': f'source-{len(commands)}'},
                'coverage': {'fullSuiteVerified': not args.stage and not args.only_testing}})
            return 0
        with patch.object(host, 'setup', side_effect=setup), patch.object(host, 'run_tests', side_effect=run):
            self.assertEqual(upgrade.upgrade(host, self.args, self.state), 0)
        self.assertEqual(commands, [('setup', 'setup'), (['test'], ['Tests iOS/BWSafariSynchronizationTests'], 'Debug'),
            (['safari'], ['SafariLifecycleTests/testInstallAndNativeRoundtrip'], 'Debug'), ([], [], None)])
        result = self.report()
        self.assertEqual(result['status'], 'passed')
        self.assertTrue(result['fullSuiteVerified'])
        self.assertEqual(result['steps'][-1]['source'], {'sha256': 'source-4'})

    def test_setup_failure_and_cancellation_retain_exact_report_and_skip_runs(self):
        self.ready()
        for status in ('failed', 'cancelled', 'blocked'):
            with self.subTest(status=status):
                def setup(args, state, environment, *, result_callback):
                    result_callback(self.state / 'failed-setup.json', {'status': status, 'reason': 'fixture'})
                    return 2
                with patch.object(host, 'setup', side_effect=setup), patch.object(host, 'run_tests', side_effect=AssertionError('No tests')):
                    self.assertEqual(upgrade.upgrade(host, self.args, self.state), 2)
                result = self.report()
                self.assertEqual(result['status'], status)
                self.assertFalse(result['fullSuiteVerified'])
                self.assertEqual(result['steps'][0]['result'], str(self.state / 'failed-setup.json'))

    def test_cancelled_run_is_not_reported_as_test_failure(self):
        self.ready()
        def run(args, state, environment, *, result_callback):
            result_callback(self.state / 'cancelled.json', {'status': 'cancelled'})
            return 1
        with patch.object(host, 'setup', return_value=0), patch.object(host, 'run_tests', side_effect=run):
            self.assertEqual(upgrade.upgrade(host, self.args, self.state), 1)
        self.assertEqual(self.report()['status'], 'cancelled')
        self.assertEqual(len(self.report()['steps']), 2)

    def test_setup_exception_retains_archived_source_and_does_not_complete_upgrade(self):
        self.ready()
        archived = {}
        failure = OSError('fixture promotion cleanup failed')
        def prepare(args, state, environment, operation):
            path = operation['exchange'] / 'artifacts/result.json'
            result = {'runId': operation['runId'], 'status': 'passed', 'source': {'sha256': 'setup-source'},
                      'coverage': {'fullSuiteVerified': False}, 'preflight': {'versions': {'xcode': 'Xcode 27.1'}}}
            host.atomic_json(path, result)
            archived.update(path=path, result=result)
            raise failure
        with patch.object(host, 'prepare_setup', side_effect=prepare), \
                patch.object(host, 'run_tests', side_effect=AssertionError('No tests after setup exception')):
            with self.assertRaises(OSError) as raised:
                upgrade.upgrade(host, self.args, self.state)
        self.assertIs(raised.exception, failure)
        result = self.report()
        self.assertEqual(result['status'], 'blocked')
        self.assertEqual(result['steps'][0]['status'], 'blocked')
        self.assertEqual(result['steps'][0]['result'], str(archived['path']))
        self.assertEqual(result['steps'][0]['source'], archived['result']['source'])
        self.assertEqual(result['steps'][0]['guestStatus'], 'passed')
        self.assertFalse(result['fullSuiteVerified'])
        self.assertFalse((self.state / 'active.json').exists())

    def test_run_cleanup_failure_retains_archived_evidence_without_completing_upgrade(self):
        self.ready()
        failure = OSError('fixture run clone cleanup failed')
        archived = []
        def run(args, state, environment, *, result_callback):
            name = ('safari-hook', 'safari-roundtrips', 'full-suite')[len(archived)]
            path = state / f'{name}-result.json'
            result = {'status': 'passed', 'source': {'sha256': f'{name}-source'},
                      'coverage': {'fullSuiteVerified': not args.stage and not args.only_testing},
                      'preflight': {'versions': {'xcode': 'Xcode 27.1'}}}
            host.atomic_json(path, result)
            archived.append((path, result))
            result_callback(path, result)
            if name == 'full-suite':
                raise failure
            return 0
        with patch.object(host, 'setup', return_value=0), patch.object(host, 'run_tests', side_effect=run):
            with self.assertRaises(OSError) as raised:
                upgrade.upgrade(host, self.args, self.state)
        self.assertIs(raised.exception, failure)
        self.assertEqual(len(archived), 3)
        result = self.report()
        self.assertEqual(result['status'], 'blocked')
        self.assertEqual(result['reason'], str(failure))
        self.assertFalse(result['fullSuiteVerified'])
        self.assertEqual([step['status'] for step in result['steps']], ['passed', 'passed', 'passed', 'blocked'])
        step = result['steps'][-1]
        path, native_result = archived[-1]
        self.assertEqual(step['name'], 'full-suite')
        self.assertEqual(step['result'], str(path))
        self.assertEqual(step['source'], native_result['source'])
        self.assertEqual(step['coverage'], {'fullSuiteVerified': True})
        self.assertEqual(step['guestStatus'], 'passed')
        self.assertEqual(step['versions'], native_result['preflight']['versions'])

    def test_zero_exit_without_full_suite_audit_does_not_complete_upgrade(self):
        self.ready()
        def run(args, state, environment, *, result_callback):
            result_callback(self.state / 'incomplete.json', {'status': 'passed', 'coverage': {'fullSuiteVerified': False}})
            return 0
        with patch.object(host, 'setup', return_value=0), patch.object(host, 'run_tests', side_effect=run):
            with self.assertRaisesRegex(host.RunnerError, 'did not attest'):
                upgrade.upgrade(host, self.args, self.state)
        result = self.report()
        self.assertEqual(result['status'], 'blocked')
        self.assertEqual(result['steps'][-1]['status'], 'blocked')
        self.assertFalse(result['fullSuiteVerified'])


if __name__ == '__main__':
    unittest.main()
