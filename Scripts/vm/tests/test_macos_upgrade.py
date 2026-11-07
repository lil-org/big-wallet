import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location('macos_upgrade_host', Path(__file__).resolve().parents[1] / 'host.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)
upgrade = host.macos_upgrade_module()


class MacOSUpgradeTests(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.root = Path(self.stack.enter_context(tempfile.TemporaryDirectory())).resolve()
        self.repository = self.root / 'repository'
        self.tools = self.repository / 'Scripts/vm'
        self.tools.mkdir(parents=True)
        self.environment = host.read_json(host.TOOLS / 'environment.json')
        host.atomic_json(self.tools / 'environment.json', self.environment)
        self.state = self.root / 'state'
        self.state.mkdir()
        self.source_vm = self.root / 'original.vbvm'
        self.make_vm(self.source_vm)
        self.xcode = self.root / 'Xcode.app'
        self.args = host.parser().parse_args(['--vm', str(self.source_vm), '--xcode', str(self.xcode),
            'upgrade-macos', '--version', '27.2', '--build', '26B123'])
        self.target = {'version': '27.2', 'buildVersion': '26B123'}
        self.source_macos = {'version': '27.0.1', 'buildVersion': '26A434'}
        self.identifier = 'macos-upgrade-20261103T120000Z-0123abcd'
        self.directory = self.state / 'upgrades' / self.identifier
        self.staged = self.directory / 'state'
        self.source = {'sha256': 'c' * 64, 'commit': 'd' * 40}
        self.baseline = self.state / 'baseline.vbvm'
        self.make_vm(self.baseline)
        self.record = {'version': 1, 'vmId': 'fixture-vm', 'sourceVM': str(self.source_vm),
            'consoleUser': 'wallet-test', 'guestAccessID': '11111111-2222-4333-8444-555555555555', 'verifiedAt': 'verified',
            'verificationSigningMode': 'local', 'environment': self.environment, 'macos': self.source_macos,
            'bootstrapSourceDigest': 'fixture-bootstrap', 'bootstrapTools': {}}
        host.atomic_json(self.state / 'baseline.json', self.record)
        access = self.state / 'guest-access/fixture-vm/11111111-2222-4333-8444-555555555555'
        access.mkdir(parents=True)
        host.atomic_json(access / 'identity.json', {'vmId': 'fixture-vm', 'consoleUser': 'wallet-test'})
        (access / 'password').write_text('fixture-only-password')
        for name, value in [('ROOT', self.repository), ('TOOLS', self.tools)]:
            self.stack.enter_context(patch.object(host, name, value))
        for name, value in [('ensure_disk_idle', None), ('check_capacity', {'availableBytes': 10**12}),
                            ('manifest_node', {'version': 'v24.22.0'}), ('inherited_safari_preparation', {}),
                            ('bootstrap_source_digest', 'fixture-bootstrap')]:
            self.stack.enter_context(patch.object(host, name, return_value=value))
        self.stack.enter_context(patch.object(host, 'validate_vm', side_effect=lambda vm: plistlib.loads((vm / '.vbdata/Config.plist').read_bytes())))
        self.stack.enter_context(patch.object(host, 'guest_access_module', return_value=SimpleNamespace(
            read_private_password=lambda path: path.read_bytes())))
        self.stack.enter_context(patch.object(host, 'xcode_upgrade_module', return_value=SimpleNamespace(
            installed_xcode=lambda host, path: self.environment['xcode'])))
        self.clones = self.stack.enter_context(patch.object(host, 'clone_vm', side_effect=self.clone_vm))
        self.stack.enter_context(patch.object(host, 'checked', side_effect=self.checked))
        self.stack.enter_context(patch.object(host, 'snapshot_source', return_value=self.source))
        self.stack.enter_context(patch('sys.stdout', new=io.StringIO()))
        self.result = {'version': 1, 'upgradeID': self.identifier, 'target': self.target, 'status': 'running',
            'phase': 'cloning', 'repository': str(self.repository), 'stateDirectory': str(self.state),
            'stagingDirectory': str(self.staged), 'sourceVM': str(self.source_vm), 'xcodePath': str(self.xcode),
            'environment': copy.deepcopy(self.environment), 'vmId': 'fixture-vm', 'interactive': False,
            'timeout': 100, 'steps': [], 'fullSuiteVerified': False,
            'sourceBaseline': upgrade.identity(host, self.baseline, self.state / 'baseline.json')}
        self.parent_record = (self.state / 'baseline.json').read_bytes()
        self.parent_disk = (self.baseline / 'Disk.img').read_bytes()
        self.calls = []

    def make_vm(self, path):
        (path / '.vbdata').mkdir(parents=True)
        for name in ('Disk.img', 'BuildData.img', 'AuxiliaryStorage', 'HardwareModel', 'MachineIdentifier'):
            (path / name).write_bytes(('fixture-' + name).encode())
        (path / '.vbdata/Config.plist').write_bytes(plistlib.dumps({
            'sharedFolders': [], 'hardware': {'networkDevices': [{'macAddress': '02:00:00:00:00:01'}]}}))

    def clone_vm(self, source, destination, *, clone_only):
        self.assertIs(clone_only, True)
        shutil.copytree(source, destination)

    def checked(self, command, **kwargs):
        self.assertEqual(command[:2], ['/bin/cp', '-c'])
        shutil.copyfile(command[2], command[3])
        return b''

    def save(self):
        self.directory.mkdir(parents=True, exist_ok=True)
        host.atomic_json(self.directory / 'result.json', self.result)

    def stage(self):
        self.save()
        return upgrade.initialize_staging(host, self.state, self.directory, self.result, self.save)

    def assert_parent_unchanged(self):
        self.assertEqual((self.state / 'baseline.json').read_bytes(), self.parent_record)
        self.assertEqual((self.baseline / 'Disk.img').read_bytes(), self.parent_disk)

    def report(self, state=None, *, target=None, status='passed', full=True, vm_id='fixture-vm'):
        state = state or self.staged
        directory = state / 'results' / ('run-' + str(len(self.calls))) / 'artifacts'
        directory.mkdir(parents=True, exist_ok=True)
        target = self.target if target is None else target
        report = {'version': 1, 'runId': 'run-' + str(len(self.calls)), 'vmId': vm_id, 'status': status,
            'finishedAt': 'fixture-finished', 'source': self.source, 'coverage': {'fullSuiteVerified': full},
            'preflight': {'macos': {'expected': self.target, 'actual': target, 'available': target == self.target},
                'versions': {'node': 'v' + self.environment['node']['version'],
                             'npm': self.environment['node']['npmVersion'], 'jq': 'jq-' + self.environment['jq']['version']},
                'pinnedEnvironment': {'xcode': {'available': True, 'actual': self.environment['xcode']},
                    'runtimes': {key: {'available': True, 'expected': {name: runtime[name] for name in ('version', 'buildVersion')}}
                        for key, runtime in zip(('ios', 'visionos'), self.environment['runtimes'])}}}}
        if full:
            native = 'safari.macos.debug'
            stages = [{'id': 'scripts.fixture_check'}, {'id': native, 'nativeAudit': {'kind': 'safari'}}]
            host.atomic_json(directory / 'planned-result.json', {'origin': 'host-plan', 'vmId': vm_id,
                'runId': report['runId'], 'stages': [{**stage, 'status': 'pending'} for stage in stages]})
            report['stages'] = [{**stage, 'status': status, 'log': stage['id'] + '.log'} for stage in stages]
            for stage in report['stages']:
                (directory / stage['log']).touch()
            simulator_log = f'{native}.simulator-1-list.log'
            (directory / simulator_log).touch()
            report['stages'][1].update({'resultBundle': f'{native}.xcresult', 'safariEvidence': f'{native}.safari.json',
                'simulatorPreparation': {'artifact': f'{native}.simulators.json', 'status': 'passed', 'steps': [{'log': simulator_log}]}})
            for suffix in ('summary', 'tests', 'safari', 'simulators'):
                host.atomic_json(directory / f'{native}.{suffix}.json', {})
            bundle = directory / f'{native}.xcresult'
            (bundle / 'Data').mkdir(parents=True, exist_ok=True)
            members = {'Info.plist': b'info', 'database.sqlite3': b'db', 'Data/data.object': b'fixture result object'}
            for name, contents in members.items():
                (bundle / name).write_bytes(contents)
            inventory = b''.join(f'{name}\0{len(members[name])}\0'.encode() for name in sorted(members))
            report['stages'][1]['resultBundleInventorySHA256'] = hashlib.sha256(inventory).hexdigest()
        path = directory / 'result.json'
        host.atomic_json(path, report)
        return path, report

    def setup(self, args, state, environment, *, result_callback, force_verification=False):
        self.assertEqual(state, self.staged)
        self.assertTrue(force_verification)
        self.assert_parent_unchanged()
        self.calls.append(('setup', state))
        record = host.read_json(state / 'baseline.json')
        self.assertEqual(record['macos'], self.target)
        path, report = self.report(state)
        record.update({'verifiedAt': 'freshly-verified', 'validationResult': str(path)})
        host.atomic_json(state / 'baseline.json', record)
        result_callback(path, report)
        return 0

    def run_tests(self, args, state, environment, *, result_callback):
        self.calls.append(('run', state, args.stage))
        if state == self.staged:
            self.assert_parent_unchanged()
        else:
            self.assertEqual(host.read_json(state / 'baseline.json')['macos'], self.target)
        path, report = self.report(state, full=not args.stage)
        result_callback(path, report)
        return 0

    def execution_fixture(self, *, failure=None):
        stack = contextlib.ExitStack()
        installer = Mock(return_value={'status': 'complete', 'actual': self.target})
        stack.enter_context(patch.object(upgrade, 'module', return_value=SimpleNamespace(install=installer)))
        stack.enter_context(patch.object(host, 'setup', side_effect=self.setup))
        stack.enter_context(patch.object(host, 'run_tests', side_effect=failure or self.run_tests))
        stack.enter_context(patch.object(host, 'inherited_safari_preparation', return_value={'prepared': True}))
        stack.enter_context(patch.object(upgrade, 'copy_safari_evidence', side_effect=lambda host, source, destination, record: record))
        return stack, installer

    def test_preview_is_read_only_and_reports_future_targets_without_hardcoded_versions(self):
        self.args.check = True
        self.args.version, self.args.build = '28.3.1', '27D205'
        before = sorted(str(path.relative_to(self.state)) for path in self.state.rglob('*'))
        with patch.object(host, 'private_directory', side_effect=AssertionError('Preview mutated state')), \
                patch.object(host, 'execution_lock', side_effect=AssertionError('Preview acquired a mutation lock')), \
                patch.object(upgrade.subprocess, 'Popen', side_effect=AssertionError('Preview started a process')):
            self.assertEqual(upgrade.upgrade(host, self.args, self.state), 0)
        self.assertEqual(before, sorted(str(path.relative_to(self.state)) for path in self.state.rglob('*')))
        self.assert_parent_unchanged()

    def test_target_requires_an_exact_version_build_and_resume_cannot_change_it(self):
        for version, build in [(None, '26B123'), ('27.2', None), ('latest', '26B123'), ('27.2', 'latest'),
                               ('0.2', '26B123'), ('027.2', '26B123'), ('27.2', '26B123a'), ('27.2', '6B123'),
                               ('27.2', '26B1234567')]:
            with self.subTest(version=version, build=build), self.assertRaises(host.RunnerError):
                upgrade.selected_target(host, SimpleNamespace(version=version, build=build))
        self.assertEqual(upgrade.selected_target(host, SimpleNamespace(version=None, build=None), self.target), self.target)
        with self.assertRaisesRegex(host.RunnerError, 'differs'):
            upgrade.selected_target(host, SimpleNamespace(version='28.0', build='27A123'), self.target)

    def test_missing_original_vm_blocks_preview_and_start_before_cloning(self):
        shutil.rmtree(self.source_vm)
        preview = upgrade.preview(host, self.args, self.state)
        self.assertEqual([item['name'] for item in preview['prerequisites'] if item['status'] == 'blocked'], ['sourceVM'])
        self.assertEqual(upgrade.upgrade(host, self.args, self.state), 2)
        self.clones.assert_not_called()
        self.assertFalse((self.state / 'upgrades').exists())

    def test_fresh_admission_rechecks_the_selected_baseline_and_prerequisites_under_lock(self):
        acquire = host.execution_lock
        for change in ('unverified', 'replaced', 'candidate'):
            with self.subTest(change=change):
                @contextlib.contextmanager
                def acquire_changed(state):
                    with acquire(state):
                        if change == 'candidate':
                            (state / 'candidate.vbvm').mkdir()
                        else:
                            host.atomic_json(state / 'baseline.json', {**self.record, 'verifiedAt':
                                None if change == 'unverified' else 'newly-verified'})
                        yield
                with patch.object(host, 'execution_lock', side_effect=acquire_changed), \
                        patch.object(upgrade.subprocess, 'Popen', side_effect=AssertionError('Launched changed selection')):
                    if change == 'replaced':
                        with self.assertRaisesRegex(host.RunnerError, 'baseline changed during admission'):
                            upgrade.upgrade(host, self.args, self.state)
                    else:
                        self.assertEqual(upgrade.upgrade(host, self.args, self.state), 2)
                self.assertFalse((self.state / 'upgrades').exists())
                if change == 'candidate':
                    (self.state / 'candidate.vbvm').rmdir()
                else:
                    host.atomic_json(self.state / 'baseline.json', self.record)

    def test_supervisor_identity_uses_kernel_start_with_microsecond_pid_reuse_detection(self):
        supervisor = {'pid': 342, 'start': [1750000000, 12345]}
        identity = Mock(side_effect=[supervisor, {**supervisor, 'start': [1750000000, 12346]}, None])
        with patch.object(upgrade, 'module', return_value=SimpleNamespace(process_identity=identity)), \
                patch.object(upgrade.subprocess, 'run', side_effect=AssertionError('Consulted formatted process date')):
            self.assertTrue(upgrade.supervisor_alive({'supervisor': supervisor}))
            self.assertFalse(upgrade.supervisor_alive({'supervisor': supervisor}))
            self.assertFalse(upgrade.supervisor_alive({'supervisor': supervisor}))
        self.assertEqual([call.args for call in identity.call_args_list], [(342, supervisor['start'])] * 3)

    def test_isolated_clone_copies_both_disks_and_account_inputs_without_changing_the_parent(self):
        self.stage()
        self.assert_parent_unchanged()
        self.assertEqual(self.clones.call_args.args[0], self.baseline)
        self.assertTrue(self.clones.call_args.args[1].is_relative_to(self.staged))
        for name in ('Disk.img', 'BuildData.img'):
            self.assertEqual((self.staged / 'baseline.vbvm' / name).read_bytes(), (self.baseline / name).read_bytes())
            self.assertNotEqual((self.staged / 'baseline.vbvm' / name).stat().st_ino, (self.baseline / name).stat().st_ino)
        access = self.staged / 'guest-access/fixture-vm/11111111-2222-4333-8444-555555555555'
        self.assertEqual((access / 'password').read_bytes(), b'fixture-only-password')
        self.assertEqual((access / 'password').stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.result['environment'], self.environment)
        def mac(vm):
            config = host.validate_vm(vm)
            return config['hardware']['networkDevices'][0]['macAddress']
        isolated_mac = mac(self.staged / 'baseline.vbvm')
        self.assertNotEqual(isolated_mac, mac(self.baseline))
        self.assertEqual(isolated_mac, ':'.join(f'{octet:02x}' for octet in
            b'\x02' + hashlib.sha256(('big-wallet-vm:' + self.identifier).encode()).digest()[:5]))

    def test_cached_archive_is_only_published_after_a_verified_copy(self):
        source = self.root / 'Xcode.tar'
        source.write_bytes(b'complete archive')
        dest = self.staged / 'tools/xcode-archive-fixture/Xcode.tar'
        temporary = dest.with_name('.Xcode.tar.copying')
        def truncate(command):
            self.assertEqual(command[-1], temporary)
            temporary.write_bytes(b'partial')
            self.assertFalse(dest.exists())
        with patch.object(host, 'checked', side_effect=truncate), self.assertRaisesRegex(host.RunnerError, 'differs'):
            upgrade.copy_file(host, source, dest)
        self.assertFalse(dest.exists())
        self.assertFalse(temporary.exists())
        temporary.write_bytes(b'left by a killed copy')
        upgrade.copy_file(host, source, dest)
        self.assertEqual(dest.read_bytes(), source.read_bytes())
        self.assertFalse(temporary.exists())
        dest.write_bytes(b'conflicting retained input')
        with self.assertRaisesRegex(host.RunnerError, 'preserve both files'):
            upgrade.copy_file(host, source, dest)
        self.assertEqual(dest.read_bytes(), b'conflicting retained input')
        temporary.symlink_to(source)
        with self.assertRaisesRegex(host.RunnerError, 'symlink'):
            upgrade.copy_file(host, source, dest)
        self.assertEqual(source.read_bytes(), b'complete archive')

    def test_source_change_before_cloning_never_selects_another_vm(self):
        (self.baseline / 'Disk.img').write_bytes(b'changed-source')
        with self.assertRaisesRegex(host.RunnerError, 'source baseline changed'):
            self.stage()
        self.clones.assert_not_called()
        self.assertFalse((self.staged / 'baseline.vbvm').exists())

    def test_source_change_during_clone_cannot_be_accepted(self):
        def changed(source, destination, **kwargs):
            self.clone_vm(source, destination, **kwargs)
            (source / 'Disk.img').write_bytes(b'changed-during-clone')
        with patch.object(host, 'clone_vm', side_effect=changed), \
                self.assertRaisesRegex(host.RunnerError, 'source baseline changed'):
            self.stage()
        self.assertFalse(self.result.get('stagingReady', False))
        self.assertFalse((self.staged / 'baseline.vbvm').exists())

    def test_completed_clone_handoff_resumes_without_recloning(self):
        self.stage()
        original_id = self.result['stagingFileID']
        self.result.update({'stagingReady': False, 'phase': 'cloning'})
        self.save()
        upgrade.initialize_staging(host, self.state, self.directory, self.result, self.save)
        self.assertTrue(self.result['stagingReady'])
        self.assertEqual(self.result['stagingFileID'], original_id)
        self.assertEqual(self.clones.call_count, 1)
        self.assert_parent_unchanged()

    def test_replaced_staging_bundle_or_foreign_lineage_is_rejected_on_resume(self):
        self.stage()
        original = self.staged / 'baseline.vbvm'
        retained = self.staged / 'retained-original.vbvm'
        original.rename(retained)
        self.make_vm(original)
        with self.assertRaisesRegex(host.RunnerError, 'replaced outside'):
            upgrade.initialize_staging(host, self.state, self.directory, self.result, self.save)
        shutil.rmtree(original)
        retained.rename(original)
        record = host.read_json(self.staged / 'baseline.json')
        record['macosUpgradeID'] = 'macos-upgrade-20261103T120000Z-9999abcd'
        host.atomic_json(self.staged / 'baseline.json', record)
        with self.assertRaisesRegex(host.RunnerError, 'no longer belongs'):
            upgrade.initialize_staging(host, self.state, self.directory, self.result, self.save)
        self.assert_parent_unchanged()

    def test_resume_rejects_changed_source_vm_environment_or_xcode(self):
        self.save()
        self.args.resume = self.identifier
        original = self.args.vm
        self.args.vm = self.root / 'another.vbvm'
        with self.assertRaisesRegex(host.RunnerError, 'original source VM'):
            upgrade.preview(host, self.args, self.state)
        self.args.vm = original
        self.result['environment']['node']['version'] = '99.0.0'
        self.save()
        with self.assertRaisesRegex(host.RunnerError, 'toolchain pins'):
            upgrade.preview(host, self.args, self.state)

    def test_staging_never_falls_back_to_the_parent_when_its_baseline_is_missing(self):
        self.stage()
        shutil.rmtree(self.staged / 'baseline.vbvm')
        with patch.object(host, 'validate_vm', side_effect=lambda path: path.stat()):
            with self.assertRaises(OSError):
                upgrade.initialize_staging(host, self.state, self.directory, self.result, self.save)
        self.assertEqual(self.clones.call_count, 1)
        self.assert_parent_unchanged()

    def test_result_gating_requires_exact_os_toolchain_vm_and_full_coverage(self):
        for changes in ({'target': self.source_macos}, {'status': 'failed'}, {'full': False}, {'vm_id': 'other-vm'}):
            with self.subTest(changes=changes):
                path, _ = self.report(**changes)
                with self.assertRaises(host.RunnerError):
                    upgrade.checked_result(host, self.result, {'result': str(path)}, full=True)
        path, report = self.report()
        report['preflight']['pinnedEnvironment']['xcode']['actual'] = {'version': '99.0', 'buildVersion': '99A123'}
        host.atomic_json(path, report)
        with self.assertRaises(host.RunnerError):
            upgrade.checked_result(host, self.result, {'result': str(path)}, full=True)

    def test_setup_verification_uses_only_staging_and_cannot_promote_parent(self):
        self.stage()
        record = host.read_json(self.staged / 'baseline.json')
        record['macos'] = self.target
        host.atomic_json(self.staged / 'baseline.json', record)
        with patch.object(host, 'setup', side_effect=self.setup):
            upgrade.validation_step(host, self.result, self.directory, 'setup', ['setup'], self.save, setup=True)
        self.assert_parent_unchanged()
        with self.assertRaisesRegex(host.RunnerError, 'before full-suite'):
            upgrade.promote(host, self.state, self.directory, self.result, self.save)

    def test_cancelled_roundtrip_propagates_to_the_upgrade(self):
        def cancel(args, state, environment, *, result_callback):
            result_callback(*self.report(state, status='cancelled'))
            return 2
        self.stage()
        with patch.object(host, 'run_tests', side_effect=cancel), self.assertRaisesRegex(InterruptedError, 'was cancelled'):
            upgrade.validation_step(host, self.result, self.directory, 'safari-roundtrips', ['run', 'all', '--stage', 'safari'], self.save)
        self.assertEqual(self.result['steps'][-1]['status'], 'cancelled')
        self.assert_parent_unchanged()

    def test_full_suite_failure_retains_the_original_baseline_and_upgrade_candidate(self):
        def fail(args, state, environment, *, result_callback):
            if args.stage:
                return self.run_tests(args, state, environment, result_callback=result_callback)
            self.calls.append(('failed-full-suite', state))
            result_callback(*self.report(state, status='failed'))
            return 1
        stack, installer = self.execution_fixture(failure=fail)
        with stack, self.assertRaisesRegex(host.RunnerError, 'full-suite did not pass'):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        installer.assert_called_once()
        self.assert_parent_unchanged()
        self.assertTrue((self.staged / 'baseline.vbvm').exists())
        self.assertFalse((self.state / 'candidate.vbvm').exists())
        self.assertFalse(self.result['fullSuiteVerified'])

    def test_replacing_disk_inside_same_bundle_during_full_suite_blocks_promotion(self):
        def replace_disk(args, state, environment, *, result_callback):
            code = self.run_tests(args, state, environment, result_callback=result_callback)
            if not args.stage:
                disk = state / 'baseline.vbvm/Disk.img'
                disk.rename(disk.with_suffix('.original'))
                disk.write_bytes(b'unverified disk')
            return code
        stack, _ = self.execution_fixture(failure=replace_disk)
        with stack, self.assertRaisesRegex(host.RunnerError, 'changed during full-suite'):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        self.assertFalse(self.result['fullSuiteVerified'])
        self.assert_parent_unchanged()

    def test_changing_staging_record_during_handoff_blocks_promotion(self):
        def clone(source, destination, **kwargs):
            self.clone_vm(source, destination, **kwargs)
            if destination == self.directory / 'promotion-handoff.vbvm':
                path = self.staged / 'baseline.json'
                host.atomic_json(path, {**host.read_json(path), 'consoleUser': 'another-user'})
        stack, _ = self.execution_fixture()
        with stack, patch.object(host, 'clone_vm', side_effect=clone), self.assertRaisesRegex(host.RunnerError, 'promotion copy'):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        self.assert_parent_unchanged()

    def test_in_place_disk_change_preserving_size_and_mtime_blocks_promotion(self):
        def overwrite(args, state, environment, *, result_callback):
            code = self.run_tests(args, state, environment, result_callback=result_callback)
            if not args.stage:
                disk = state / 'baseline.vbvm/Disk.img'
                before = disk.stat()
                disk.write_bytes(b'x' * before.st_size)
                os.utime(disk, ns=(before.st_atime_ns, before.st_mtime_ns))
            return code
        stack, _ = self.execution_fixture(failure=overwrite)
        with stack, self.assertRaisesRegex(host.RunnerError, 'changed during full-suite'):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        self.assert_parent_unchanged()

    def test_live_interactive_resume_publishes_request_to_only_the_active_worker(self):
        _, _, _, runtime, _ = self.diagnostic_fixture()
        self.result.update(phase='installation', launchToken='a' * 32)
        self.save()
        self.args.resume = self.identifier
        self.args.interactive = True
        self.assertFalse(upgrade.interactive_requested(host, self.directory, self.result))
        with patch.object(upgrade, 'supervisor_alive', return_value=True), patch.object(upgrade, 'wait_for_worker', return_value=0), \
                patch.object(upgrade, 'module', return_value=runtime), \
                patch.object(host, 'manifest_node', side_effect=AssertionError('Live control checked startup Node')), \
                patch.object(host, 'check_capacity', side_effect=AssertionError('Live control checked host capacity')):
            self.assertEqual(upgrade.upgrade(host, self.args, self.state), 0)
        self.assertTrue(upgrade.interactive_requested(host, self.directory, self.result))
        self.result['launchToken'] = 'b' * 32
        self.assertFalse(upgrade.interactive_requested(host, self.directory, self.result))

    def test_live_control_never_launches_a_worker_when_the_supervisor_exits_after_preview(self):
        _, _, _, runtime, _ = self.diagnostic_fixture()
        self.args.resume = self.identifier
        self.args.interactive = True
        with patch.object(upgrade, 'supervisor_alive', side_effect=[True, False]), \
                patch.object(upgrade, 'module', return_value=runtime), \
                patch.object(upgrade.subprocess, 'Popen', side_effect=AssertionError('Launched without startup checks')), \
                self.assertRaisesRegex(host.RunnerError, 'retry resume'):
            upgrade.upgrade(host, self.args, self.state)
        self.assertFalse((self.directory / 'interactive.json').exists())

    def test_live_attachment_before_ssh_binding_or_during_setup_requires_no_startup_capacity(self):
        self.stage()
        self.result['launchToken'] = 'a' * 32
        host.atomic_json(self.state / 'macos-upgrade-active.json', {'version': 1, 'upgradeID': self.identifier})
        self.args.resume = self.identifier
        self.args.interactive = True
        with patch.object(upgrade, 'supervisor_alive', return_value=True), patch.object(upgrade, 'wait_for_worker', return_value=0), \
                patch.object(host, 'check_capacity', side_effect=AssertionError('Live control checked host capacity')):
            for phase in ('installation', 'setup'):
                with self.subTest(phase=phase):
                    self.result['phase'] = phase
                    if phase == 'setup':
                        self.result['steps'].append({'name': 'setup', 'status': 'running', 'interactive': False})
                    self.save()
                    if phase == 'installation':
                        self.assertEqual(upgrade.upgrade(host, self.args, self.state), 0)
                        self.assertTrue(upgrade.interactive_requested(host, self.directory, self.result))
                        (self.directory / 'interactive.json').unlink()
                    else:
                        with self.assertRaisesRegex(host.RunnerError, 'Use stop, then resume'):
                            upgrade.upgrade(host, self.args, self.state)
                        self.assertFalse((self.directory / 'interactive.json').exists())

    def test_completed_pointer_from_another_worktree_is_ignored_and_cleared_under_lock(self):
        pointer = self.state / 'macos-upgrade-active.json'
        self.result.update(status='passed', phase='complete', repository=str(self.root / 'previous-worktree'))
        self.save()
        host.atomic_json(pointer, {'version': 1, 'upgradeID': self.identifier})
        self.assertIsNone(upgrade.active_result(host, self.state))
        self.assertTrue(pointer.exists())
        with host.execution_lock(self.state):
            upgrade.ensure_no_supervisor(host, self.state)
        self.assertFalse(pointer.exists())
        self.assertTrue((self.directory / 'result.json').exists())

    def test_interrupted_safari_preparation_resumes_with_activation_setup(self):
        self.stage()
        path = self.staged / 'baseline.json'
        host.atomic_json(path, {**host.read_json(path), 'macos': self.target})
        self.result.update(phase='safari-preparation', installationVerified=True)
        self.save()
        stack, _ = self.execution_fixture()
        with stack, self.assertRaisesRegex(host.RunnerError, 'resume this upgrade with --interactive'):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        self.assertFalse(self.calls)
        self.result['interactive'] = True
        stack, _ = self.execution_fixture()
        with stack:
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
            self.assertEqual(len(host.setup.call_args_list), 1)
            self.assertTrue(host.setup.call_args.args[0].safari_activation)

    def test_only_lost_prepared_activation_in_safari_audit_requires_consent(self):
        path, report = self.report()
        self.result['steps'].append({'result': str(path)})
        report['reason'] = 'Missing activation prerequisite'
        failure = "Safari XCTest failure: caught error: The prepared VM's Wallet activation did not survive this run's installation or Safari restart"
        for stage_id, issue, expected in [('safari.macos.debug', failure, True),
                ('safari.macos.debug', 'Safari XCTest failure: missing activation helper', False),
                ('test.macos.debug', failure, False)]:
            with self.subTest(stage=stage_id, issue=issue):
                report['stages'] = [{'id': stage_id, 'audit': {'issues': [issue]}}]
                host.atomic_json(path, report)
                self.assertEqual(upgrade.safari_consent_missing(host, self.result), expected)

    def test_installer_success_without_exact_target_never_reaches_setup(self):
        stack, installer = self.execution_fixture()
        installer.return_value = {'status': 'complete', 'actual': self.source_macos}
        with stack, self.assertRaisesRegex(host.RunnerError, 'installation is not verified'):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        self.assertEqual(self.calls, [])
        self.assert_parent_unchanged()

    def test_completed_transport_receipt_without_committed_target_record_is_reverified(self):
        self.stage()
        self.result['installation'] = {'status': 'complete', 'actual': self.target}
        self.save()
        stack, installer = self.execution_fixture()
        with stack:
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        installer.assert_called_once()
        self.assertEqual(self.result['status'], 'passed')

    def test_verified_installation_is_not_repeated_when_validation_is_resumed(self):
        self.stage()
        record = host.read_json(self.staged / 'baseline.json')
        record['macos'] = self.target
        host.atomic_json(self.staged / 'baseline.json', record)
        self.result.update({'installation': {'status': 'complete', 'actual': self.target},
                            'installationVerified': True, 'phase': 'setup'})
        self.save()
        stack, installer = self.execution_fixture()
        with stack:
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        installer.assert_not_called()
        self.assertEqual(self.calls[0], ('setup', self.staged))
        self.assertEqual(self.result['status'], 'passed')

    def test_stop_before_validation_preserves_both_baselines(self):
        self.stage()
        host.atomic_json(self.directory / 'stop.json', {'upgradeID': self.identifier})
        with patch.object(host, 'setup', side_effect=AssertionError('Stopped upgrade ran setup')), self.assertRaises(InterruptedError):
            upgrade.validation_step(host, self.result, self.directory, 'setup', ['setup'], self.save, setup=True)
        self.assert_parent_unchanged()
        self.assertTrue((self.staged / 'baseline.vbvm').exists())

    def test_stop_after_phase_publication_reaches_setup_and_run_before_either_starts_work(self):
        self.stage()
        host.atomic_json(self.state / 'macos-upgrade-active.json', {'version': 1, 'upgradeID': self.identifier})
        new_exchange = host.new_exchange
        def stop_before_registration(state, kind):
            self.assertEqual(host.read_json(self.directory / 'result.json')['phase'], name)
            self.assertFalse((state / 'active.json').exists())
            upgrade.control(host, SimpleNamespace(command='stop'), self.state)
            return new_exchange(state, kind)
        for name, command, setup in [('setup', ['setup'], True), ('safari-roundtrips', ['run', 'all'], False)]:
            with self.subTest(name=name), patch.object(upgrade, 'supervisor_alive', return_value=True), \
                    patch.object(host, 'new_exchange', side_effect=stop_before_registration), \
                    patch.object(host, 'prepare_setup', side_effect=AssertionError('Started cancelled setup')), \
                    patch.object(host, 'build_tools', side_effect=AssertionError('Started cancelled run')), \
                    self.assertRaisesRegex(InterruptedError, 'was cancelled'):
                upgrade.validation_step(host, self.result, self.directory, name, command, self.save, setup=setup)
            self.assertEqual(self.result['steps'][-1]['status'], 'cancelled')
            self.assertFalse((self.staged / 'active.json').exists())
            (self.directory / 'stop.json').unlink()

    def test_stop_during_handoff_clone_cannot_commit_parent_promotion(self):
        def clone(source, destination, **kwargs):
            self.clone_vm(source, destination, **kwargs)
            if destination == self.directory / 'promotion-handoff.vbvm':
                host.atomic_json(self.directory / 'stop.json', {'upgradeID': self.identifier})
        stack, _ = self.execution_fixture()
        with stack, patch.object(host, 'clone_vm', side_effect=clone), self.assertRaises(InterruptedError):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        self.assert_parent_unchanged()
        self.assertFalse((self.state / 'candidate.vbvm').exists())
        self.assertTrue((self.directory / 'promotion-handoff.vbvm').exists())

    def test_interrupted_staged_setup_promotion_recovers_before_validation_resumes(self):
        self.stage()
        baseline = self.staged / 'baseline.vbvm'
        record = host.read_json(self.staged / 'baseline.json')
        record['macos'] = self.target
        host.atomic_json(self.staged / 'baseline.json', record)
        self.result['stagingRecordSHA256'] = host.hash_regular_file(self.staged / 'baseline.json')
        candidate = self.staged / 'candidate.vbvm'
        shutil.copytree(baseline, candidate)
        path, _ = self.report()
        info = candidate.stat()
        record.update({'verifiedAt': 'verified-target', 'validationResult': str(path),
            'promotionPending': {'backup': 'previous-baseline-' + 'e' * 32 + '.vbvm',
                                 'candidateFileID': [info.st_dev, info.st_ino]}})
        host.atomic_json(self.staged / 'candidate.json', record)
        rename = Path.rename
        def interrupt_candidate(path, destination):
            if path == candidate and destination == baseline:
                raise OSError('fixture staged candidate rename interrupted')
            return rename(path, destination)
        with patch.object(Path, 'rename', new=interrupt_candidate), self.assertRaises(OSError):
            host.finish_baseline_promotion(self.staged, record)
        self.assertFalse(baseline.exists())
        self.result.update({'phase': 'setup', 'installationVerified': True,
                            'installation': {'status': 'complete', 'actual': self.target}})
        self.save()
        stack, installer = self.execution_fixture()
        with stack:
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        installer.assert_not_called()
        self.assertEqual(self.result['status'], 'passed')

    def test_success_orders_fresh_setup_roundtrips_full_suite_promotion_and_default_verification(self):
        stack, installer = self.execution_fixture()
        with stack:
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        self.assertEqual(self.calls, [('setup', self.staged), ('run', self.staged, ['safari']),
                                     ('run', self.staged, []), ('run', self.state, ['test'])])
        self.assertEqual(self.result['status'], 'passed')
        self.assertTrue(self.result['fullSuiteVerified'])
        self.assertEqual(host.read_json(self.state / 'baseline.json')['macos'], self.target)
        backup = Path(self.result['previousBaseline'])
        self.assertEqual((backup / 'Disk.img').read_bytes(), self.parent_disk)
        self.assertEqual(backup.with_suffix('.json').read_bytes(), self.parent_record)
        self.assertEqual(installer.call_args.args[2], self.staged)

    def stop_after_promotion(self):
        def fail_default(args, state, environment, *, result_callback):
            if state == self.state:
                raise host.RunnerError('fixture default verification interrupted')
            return self.run_tests(args, state, environment, result_callback=result_callback)
        stack, _ = self.execution_fixture(failure=fail_default)
        with stack, self.assertRaisesRegex(host.RunnerError, 'default verification interrupted'):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        self.assertEqual(self.result['phase'], 'default-verification')
        self.args.resume = self.identifier

    def test_post_promotion_resume_rejects_replaced_vm_with_identical_record_os_and_pins(self):
        self.stop_after_promotion()
        preserved = self.state / 'preserved-promoted.vbvm'
        self.baseline.rename(preserved)
        shutil.copytree(preserved, self.baseline)
        report = upgrade.preview(host, self.args, self.state)
        self.assertEqual(report['status'], 'blocked')
        baseline = next(item for item in report['prerequisites'] if item['name'] == 'baseline')
        self.assertIn('no longer matches', baseline['detail'])
        with patch.object(host, 'run_tests') as run, self.assertRaisesRegex(host.RunnerError, 'no longer matches'):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        run.assert_not_called()
        self.assertTrue(preserved.is_dir())
        self.assertTrue(self.baseline.is_dir())

    def test_resumed_default_check_records_current_source_and_preserves_accepted_full_run(self):
        self.stop_after_promotion()
        full = next(step for step in self.result['steps'] if step['name'] == 'full-suite')
        original = full['source'].copy()
        self.source = {**self.source, 'sha256': 'e' * 64}
        stack, _ = self.execution_fixture()
        with stack, patch.object(host, 'snapshot_source', return_value=self.source):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        self.assertEqual(self.result['status'], 'passed')
        self.assertEqual(full['source'], original)
        self.assertEqual(self.result['steps'][-1]['source'], self.source)

    def test_post_promotion_resume_rejects_other_upgrade_record_with_same_vm_os_and_pins(self):
        self.stop_after_promotion()
        record = host.read_json(self.state / 'baseline.json')
        record['macosUpgradeID'] = 'macos-upgrade-20261103T130000Z-89abcdef'
        host.atomic_json(self.state / 'baseline.json', record)
        self.assertEqual(upgrade.preview(host, self.args, self.state)['status'], 'blocked')
        with patch.object(host, 'run_tests') as run, self.assertRaisesRegex(host.RunnerError, 'no longer matches'):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        run.assert_not_called()

    def test_default_verification_cannot_accept_baseline_replacement_during_its_run(self):
        def change_default_owner(args, state, environment, *, result_callback):
            code = self.run_tests(args, state, environment, result_callback=result_callback)
            if state == self.state:
                record = host.read_json(state / 'baseline.json')
                record['macosUpgradeID'] = 'macos-upgrade-20261103T130000Z-89abcdef'
                host.atomic_json(state / 'baseline.json', record)
            return code
        stack, _ = self.execution_fixture(failure=change_default_owner)
        with stack, self.assertRaisesRegex(host.RunnerError, 'no longer matches'):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        self.assertNotEqual(self.result['status'], 'passed')
        self.assertEqual(self.result['phase'], 'default-verification')

    def test_source_edits_after_full_suite_block_promotion(self):
        stack, _ = self.execution_fixture()
        with stack, patch.object(host, 'snapshot_source', return_value={**self.source, 'sha256': 'e' * 64}), \
                self.assertRaisesRegex(host.RunnerError, 'sources changed'):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        self.assert_parent_unchanged()
        self.assertFalse((self.state / 'candidate.vbvm').exists())

    def test_source_check_cleans_up_after_success_mismatch_and_snapshot_failure(self):
        self.directory.mkdir(parents=True)
        for outcome in (self.source, {'sha256': '0' * 64}, OSError('fixture snapshot interrupted')):
            def snapshot(repo, exchange):
                (exchange / 'partial-source').write_bytes(b'partial fixture')
                if isinstance(outcome, Exception):
                    raise outcome
                return outcome
            with self.subTest(outcome=outcome), patch.object(host, 'snapshot_source', side_effect=snapshot):
                if outcome == self.source:
                    self.assertEqual(upgrade.require_source(host, self.directory, self.source), self.source)
                else:
                    with self.assertRaises((host.RunnerError, OSError)):
                        upgrade.require_source(host, self.directory, self.source)
                self.assertEqual(list(self.directory.glob('source-check-*')), [])

    def test_interrupted_parent_promotion_resumes_only_the_recorded_candidate(self):
        record_path = self.state / 'baseline.json'
        record_path.write_text(json.dumps(self.record, indent=4) + '\n')
        self.parent_record = record_path.read_bytes()
        self.result['sourceBaseline'] = upgrade.identity(host, self.baseline, record_path)
        stack, _ = self.execution_fixture()
        with stack, patch.object(host, 'finish_baseline_promotion', side_effect=OSError('fixture promotion interrupted')), \
                self.assertRaisesRegex(OSError, 'promotion interrupted'):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        self.assertEqual(self.result['phase'], 'promoting')
        self.assert_parent_unchanged()
        candidate = self.state / 'candidate.vbvm'
        candidate_info = candidate.stat()
        before = list(self.calls)
        stack, installer = self.execution_fixture()
        with stack:
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        installer.assert_not_called()
        self.assertEqual(self.calls, [*before, ('run', self.state, ['test'])])
        self.assertEqual(self.result['status'], 'passed')
        self.assertEqual((self.baseline.stat().st_dev, self.baseline.stat().st_ino),
                         (candidate_info.st_dev, candidate_info.st_ino))
        backup = Path(self.result['previousBaseline'])
        self.assertEqual(backup.with_suffix('.json').read_bytes(), self.parent_record)
        self.assertEqual(host.read_json(record_path)['macosUpgradePromotion']['sourceRecordSHA256'],
                         hashlib.sha256(self.parent_record).hexdigest())

    def interrupt_before_swap(self):
        stack, _ = self.execution_fixture()
        with stack, patch.object(host, 'finish_baseline_promotion', side_effect=OSError('interrupted')), self.assertRaises(OSError):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        return self.directory / ('withdrawn-' + Path(self.result['previousBaseline']).name)

    def test_changed_report_withdraws_verified_candidate_and_resume_runs_full_suite_again(self):
        withdrawn = self.interrupt_before_swap()
        pending = host.read_json(self.state / 'candidate.json')
        full = next(step for step in self.result['steps'] if step['name'] == 'full-suite')
        path = Path(full['result'])
        path.write_bytes(path.read_bytes() + b' ')
        host.atomic_json(self.state / 'macos-upgrade-active.json', {'version': 1, 'upgradeID': self.identifier})
        with self.assertRaisesRegex(host.RunnerError, 'report changed'):
            upgrade.finish_promotion(host, self.state, self.directory, self.result, self.save)
        self.assert_parent_unchanged()
        self.assertFalse((self.state / 'candidate.vbvm').exists())
        self.assertFalse((self.state / 'candidate.json').exists())
        self.assertEqual(upgrade.vm_identity(host, withdrawn)['fileID'], pending['promotionPending']['candidateFileID'])
        self.assertEqual(host.read_json(withdrawn.with_suffix('.json')), pending)
        self.assertEqual(self.result['phase'], 'setup')
        self.assertFalse(self.result['fullSuiteVerified'])
        upgrade.ensure_no_supervisor(host, self.state)
        self.args.resume = self.identifier
        self.assertEqual(upgrade.preview(host, self.args, self.state)['status'], 'ready')
        before = list(self.calls)
        stack, installer = self.execution_fixture()
        with stack:
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        installer.assert_not_called()
        self.assertEqual(self.calls[len(before):], [('setup', self.staged), ('run', self.staged, ['safari']),
                                                   ('run', self.staged, []), ('run', self.state, ['test'])])
        self.assertTrue(withdrawn.is_dir())
        self.assertEqual(self.result['status'], 'passed')

    def test_recovery_finishes_withdrawal_after_archive_rename(self):
        withdrawn = self.interrupt_before_swap()
        rename = Path.rename
        def interrupt(path, destination):
            if path == self.state / 'candidate.json':
                raise OSError('fixture withdrawal interrupted')
            return rename(path, destination)
        with patch.object(host, 'snapshot_source', return_value={'sha256': 'e' * 64}), \
                patch.object(Path, 'rename', new=interrupt), self.assertRaisesRegex(OSError, 'withdrawal interrupted'):
            upgrade.finish_promotion(host, self.state, self.directory, self.result, self.save)
        self.assertTrue(withdrawn.is_dir())
        self.assertTrue((self.state / 'candidate.json').exists())
        self.args.resume = self.identifier
        self.assertEqual(upgrade.preview(host, self.args, self.state)['status'], 'ready')
        with self.assertRaisesRegex(host.RunnerError, 'was withdrawn'):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        self.assertTrue(withdrawn.with_suffix('.json').exists())
        self.assertFalse((self.state / 'candidate.json').exists())
        self.assertEqual(self.result['phase'], 'setup')
        self.assert_parent_unchanged()

    def test_resume_keeps_a_pre_swap_stop_left_by_an_interrupted_supervisor(self):
        withdrawn = self.interrupt_before_swap()
        self.result.update(status='blocked')
        self.save()
        stop = self.directory / 'stop.json'
        host.atomic_json(stop, {'upgradeID': self.identifier})
        self.args.resume = self.identifier
        with patch.object(host, 'check_capacity', side_effect=host.RunnerError('validation capacity unavailable')), \
                patch.object(upgrade.subprocess, 'Popen', return_value=SimpleNamespace(pid=101)), \
                patch.object(upgrade, 'process_start', return_value=[1000000000, 12345]), \
                patch.object(upgrade, 'wait_for_worker', return_value=0):
            self.assertEqual(upgrade.upgrade(host, self.args, self.state), 0)
        self.assertTrue(stop.exists())
        self.result = host.read_json(self.directory / 'result.json')
        with patch.object(upgrade, 'promotion_evidence', side_effect=AssertionError('Retried cancelled validation')), \
                self.assertRaisesRegex(InterruptedError, 'before promotion'):
            upgrade.finish_promotion(host, self.state, self.directory, self.result, self.save)
        self.assertTrue(withdrawn.exists())
        self.assertEqual(self.result['phase'], 'setup')
        self.assert_parent_unchanged()

    def test_changed_pins_allow_resume_to_release_original_without_swap(self):
        self.interrupt_before_swap()
        self.args.resume = self.identifier
        host.atomic_json(self.tools / 'environment.json', {**self.environment, 'modified': True})
        self.assertEqual(upgrade.preview(host, self.args, self.state)['status'], 'ready')
        with self.assertRaisesRegex(host.RunnerError, 'pins changed'):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        self.assertEqual(self.result['phase'], 'setup')
        self.assertFalse((self.state / 'candidate.json').exists())
        self.assert_parent_unchanged()

    def test_recovery_reconciles_committed_swap_before_reporting_stale_pins(self):
        rename = Path.rename
        def interrupt(path, destination):
            if path == self.state / 'candidate.vbvm':
                raise OSError('interrupted after moving original')
            return rename(path, destination)
        stack, _ = self.execution_fixture()
        with stack, patch.object(Path, 'rename', new=interrupt), self.assertRaises(OSError):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        self.assertFalse(self.baseline.exists())
        host.atomic_json(self.directory / 'stop.json', {'upgradeID': self.identifier})
        self.args.resume = self.identifier
        host.atomic_json(self.tools / 'environment.json', {**self.environment, 'modified': True})
        self.assertEqual(upgrade.preview(host, self.args, self.state)['status'], 'ready')
        with self.assertRaisesRegex(host.RunnerError, 'pins changed'):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        self.assertEqual(self.result['phase'], 'promoted')
        self.assertTrue(self.baseline.is_dir())
        self.assertFalse((self.state / 'candidate.json').exists())
        self.assertEqual(Path(self.result['previousBaseline']).with_suffix('.json').read_bytes(), self.parent_record)

    def test_recovery_refuses_adulterated_candidate_record_or_files(self):
        stack, _ = self.execution_fixture()
        with stack, patch.object(host, 'finish_baseline_promotion', side_effect=OSError('interrupted')), self.assertRaises(OSError):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        candidate = self.state / 'candidate.json'
        original = host.read_json(candidate)
        host.atomic_json(candidate, {**original, 'guestAccessID': 'unverified'})
        with patch.object(host, 'snapshot_source', return_value={'sha256': 'e' * 64}), self.assertRaisesRegex(host.RunnerError, 'another operation'):
            upgrade.finish_promotion(host, self.state, self.directory, self.result, self.save)
        self.assertEqual(self.result['phase'], 'promoting')
        self.assertEqual(host.read_json(candidate)['guestAccessID'], 'unverified')
        self.assertTrue((self.state / 'candidate.vbvm').is_dir())
        host.atomic_json(candidate, original)
        (self.state / 'candidate.vbvm/BuildData.img').write_bytes(b'new disk')
        with self.assertRaisesRegex(host.RunnerError, 'candidate identity changed'):
            upgrade.finish_promotion(host, self.state, self.directory, self.result, self.save)
        self.assert_parent_unchanged()

    def test_resume_preview_accepts_owned_promotion_between_the_two_baseline_renames(self):
        rename = Path.rename
        def interrupt_candidate(path, destination):
            if path == self.state / 'candidate.vbvm' and destination == self.baseline:
                raise OSError('fixture candidate rename interrupted')
            return rename(path, destination)
        stack, _ = self.execution_fixture()
        with stack, patch.object(Path, 'rename', new=interrupt_candidate), self.assertRaises(OSError):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        self.assertFalse(self.baseline.exists())
        self.assertTrue(Path(self.result['previousBaseline']).exists())
        self.args.resume = self.identifier
        self.assertEqual(upgrade.preview(host, self.args, self.state)['status'], 'ready')
        self.result.update({'systemDiskBytes': 96 * 1024 ** 3, 'systemDiskReady': True})
        self.save()
        inspector = Mock(return_value={'validated': True})
        with patch.object(upgrade, 'module', return_value=SimpleNamespace(inspect_disk=inspector)):
            self.assertEqual(upgrade.preview(host, self.args, self.state)['status'], 'ready')
        inspector.assert_called_once_with(host, Path(self.result['previousBaseline']) / 'Disk.img', growth_target=None)
        stack, installer = self.execution_fixture()
        with stack:
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        installer.assert_not_called()
        self.assertEqual(self.result['status'], 'passed')
        self.assertEqual(host.read_json(self.state / 'baseline.json')['macos'], self.target)

    def test_interrupted_promotion_after_baseline_record_write_finishes_without_retesting(self):
        stack, _ = self.execution_fixture()
        with stack, patch.object(host, 'clear_applied_provisioning_packages', side_effect=OSError('fixture cleanup interrupted')), \
                self.assertRaisesRegex(OSError, 'cleanup interrupted'):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        self.assertEqual(host.read_json(self.state / 'baseline.json')['macos'], self.target)
        self.assertTrue((self.state / 'candidate.json').exists())
        self.assertEqual(self.result['phase'], 'promoting')
        before = list(self.calls)
        stack, installer = self.execution_fixture()
        with stack:
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        installer.assert_not_called()
        self.assertEqual(self.calls, [*before, ('run', self.state, ['test'])])
        self.assertFalse((self.state / 'candidate.json').exists())
        self.assertEqual(self.result['status'], 'passed')

    def test_stale_supervisor_token_cannot_overwrite_the_current_transaction(self):
        self.result['launchToken'] = 'a' * 32
        self.save()
        host.atomic_json(self.state / 'macos-upgrade-active.json', {'version': 1, 'upgradeID': self.identifier})
        before = (self.directory / 'result.json').read_bytes()
        with patch.object(upgrade, 'module', return_value=host), patch.object(upgrade.signal, 'signal'), \
                patch.object(upgrade, 'execute', side_effect=AssertionError('Stale worker executed')):
            self.assertEqual(upgrade.worker(self.state, self.identifier, 'b' * 32), 2)
        self.assertEqual((self.directory / 'result.json').read_bytes(), before)

    def test_replaced_pending_promotion_candidate_is_preserved_and_never_adopted(self):
        stack, _ = self.execution_fixture()
        with stack, patch.object(host, 'finish_baseline_promotion', side_effect=OSError('fixture interruption')), \
                self.assertRaises(OSError):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        candidate = self.state / 'candidate.vbvm'
        candidate.rename(self.state / 'preserved-candidate.vbvm')
        self.make_vm(candidate)
        with self.assertRaisesRegex(host.RunnerError, 'candidate identity changed'):
            upgrade.finish_promotion(host, self.state, self.directory, self.result, self.save)
        self.assert_parent_unchanged()
        self.assertTrue(candidate.exists())
        self.assertTrue((self.state / 'preserved-candidate.vbvm').exists())

    def test_changed_full_suite_report_cannot_be_reused_for_promotion(self):
        self.stage()
        path, report = self.report()
        step = {'name': 'full-suite', 'result': str(path)}
        upgrade.checked_result(host, self.result, step, full=True)
        self.result.update({'steps': [step], 'fullSuiteVerified': True})
        report['extra'] = 'changed-after-verification'
        host.atomic_json(path, report)
        with self.assertRaisesRegex(host.RunnerError, 'report changed'):
            upgrade.promote(host, self.state, self.directory, self.result, self.save)
        self.assert_parent_unchanged()

    def test_incomplete_full_suite_collection_never_attests_missing_evidence(self):
        for filename in ('scripts.fixture_check.log', 'safari.macos.debug.xcresult/Data/data.object', 'safari.macos.debug.xcresult/Info.plist',
                         'safari.macos.debug.summary.json', 'safari.macos.debug.simulator-1-list.log',
                         'safari.macos.debug.safari.json'):
            with self.subTest(filename=filename):
                path, _ = self.report()
                (path.parent / filename).unlink()
                step = {'result': str(path)}
                with self.assertRaisesRegex(host.RunnerError, 'missing required artifacts'):
                    upgrade.checked_result(host, self.result, step, full=True)
                self.assertNotIn('archiveIdentitySHA256', step)
        for change in (lambda report: report.pop('stages'), lambda report: report['stages'].pop(),
                       lambda report: report['stages'][1].pop('resultBundle')):
            path, report = self.report()
            change(report)
            host.atomic_json(path, report)
            with self.assertRaises(host.RunnerError):
                upgrade.checked_result(host, self.result, {'result': str(path)}, full=True)

    def test_changed_xcresult_contents_withdraw_interrupted_promotion_before_swap(self):
        withdrawn = self.interrupt_before_swap()
        full = next(step for step in self.result['steps'] if step['name'] == 'full-suite')
        path = Path(full['result']).parent / 'safari.macos.debug.xcresult/Data/data.object'
        path.write_bytes(b'x' * path.stat().st_size)
        self.result = host.read_json(self.directory / 'result.json')
        with self.assertRaisesRegex(host.RunnerError, 'archive changed'):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        self.assert_parent_unchanged()
        self.assertTrue(withdrawn.is_dir())
        self.assertFalse(self.result['fullSuiteVerified'])

    def test_missing_stage_log_on_resume_keeps_original_baseline(self):
        withdrawn = self.interrupt_before_swap()
        full = next(step for step in self.result['steps'] if step['name'] == 'full-suite')
        (Path(full['result']).parent / 'scripts.fixture_check.log').unlink()
        with self.assertRaisesRegex(host.RunnerError, 'missing required artifacts.*scripts.fixture_check.log'):
            upgrade.finish_promotion(host, self.state, self.directory, self.result, self.save)
        self.assert_parent_unchanged()
        self.assertTrue(withdrawn.is_dir())

    def diagnostic_fixture(self):
        self.stage()
        self.result['phase'] = 'installation'
        self.save()
        host.atomic_json(self.state / 'macos-upgrade-active.json', {'version': 1, 'upgradeID': self.identifier})
        install = host.private_directory(self.staged / 'macos-install')
        vm = self.staged / 'baseline.vbvm'
        info = vm.stat()
        journal = {'version': 1, 'upgradeID': self.identifier, 'vmId': self.result['vmId'], 'target': self.target,
            'vm': str(vm), 'vmFileID': [info.st_dev, info.st_ino], 'upgradeNonce': 'a' * 64, 'access': {'macAddress': '02:00:00:00:00:01'}}
        host.atomic_json(install / 'install.json', journal)
        context = {'user': 'wallet-test', 'vmId': 'fixture-vm', 'knownHosts': 'existing-known-hosts',
                   'passwordFile': 'existing-password-file', 'workDirectory': 'existing-private-directory'}
        access = SimpleNamespace(find_guest_address=Mock(return_value='192.168.64.10'))
        runtime = SimpleNamespace(_validate_native=Mock(), _native_alive=Mock(return_value=True),
            _access_context=Mock(return_value=(access, context)))
        transport = SimpleNamespace(diagnose=Mock(return_value={'status': 'restart-pending', 'actual': self.source_macos}),
            install=Mock(side_effect=AssertionError('Diagnostics invoked installation')))
        return install, journal, context, runtime, transport

    def test_diagnostics_reject_noninstallation_without_loading_guest_transport(self):
        self.result['phase'] = 'full-suite'
        with patch.object(upgrade, 'module', side_effect=AssertionError('Diagnostics loaded transport')), \
                self.assertRaisesRegex(host.RunnerError, 'installation phase'):
            upgrade.diagnose(host, self.state, self.directory, self.result)

    def test_diagnostics_reject_wrong_journal_identity_before_guest_access(self):
        install, journal, *_ = self.diagnostic_fixture()
        for key, replacement in [('upgradeID', 'macos-upgrade-20261103T120000Z-9999abcd'),
                                 ('target', self.source_macos), ('vmId', 'another-vm'), ('vm', '/unrelated/vm'),
                                 ('vmFileID', [0, 0]), ('access', None)]:
            with self.subTest(key=key):
                host.atomic_json(install / 'install.json', {**journal, key: replacement})
                with patch.object(upgrade, 'module', side_effect=AssertionError('Wrong identity reached transport')), \
                        self.assertRaisesRegex(host.RunnerError, 'identity does not match'):
                    upgrade.diagnose(host, self.state, self.directory, self.result)
        self.assert_parent_unchanged()

    def test_diagnostics_never_boot_a_stopped_native_guest(self):
        _, _, _, runtime, transport = self.diagnostic_fixture()
        runtime._native_alive.return_value = False
        with patch.object(upgrade, 'module', return_value=runtime) as modules, \
                patch.object(host, 'monitor_vm', side_effect=AssertionError('Diagnostics started VM')), \
                patch.object(upgrade.subprocess, 'Popen', side_effect=AssertionError('Diagnostics spawned process')), \
                self.assertRaisesRegex(host.RunnerError, 'never start a VM'):
            upgrade.diagnose(host, self.state, self.directory, self.result)
        modules.assert_called_once_with('macos_vm')
        runtime._access_context.assert_not_called()
        transport.diagnose.assert_not_called()
        self.assertFalse((self.directory / 'diagnostics').exists())

    def test_status_diagnose_uses_existing_pinned_context_and_only_read_only_transport(self):
        install, _, context, runtime, transport = self.diagnostic_fixture()
        expected_context = {**context, 'address': '192.168.64.10'}
        before = {path: path.read_bytes() for path in (install / 'install.json', self.staged / 'baseline.json',
                                                     self.staged / 'baseline.vbvm/Disk.img')}
        def selected(name):
            return {'macos_vm': runtime, 'macos_transport': transport}[name]
        with patch.object(host, 'macos_upgrade_module', return_value=upgrade), \
                patch.object(upgrade, 'module', side_effect=selected) as modules, \
                patch.object(upgrade, 'supervisor_alive', return_value=True), \
                patch.object(host.sys, 'platform', 'darwin'), \
                patch.object(host.os, 'uname', return_value=SimpleNamespace(machine='arm64')), \
                patch.object(host, 'monitor_vm', side_effect=AssertionError('Diagnostics started VM')), \
                patch.object(host, 'setup', side_effect=AssertionError('Diagnostics ran setup')), \
                patch.object(upgrade.subprocess, 'Popen', side_effect=AssertionError('Diagnostics spawned process')):
            self.assertEqual(host.main(['--state-dir', str(self.state), 'status', '--diagnose']), 0)
        self.assertEqual([call.args[0] for call in modules.call_args_list], ['macos_vm', 'macos_transport'])
        transport.diagnose.assert_called_once()
        arguments = transport.diagnose.call_args.args
        self.assertEqual(arguments[1], expected_context)
        self.assertEqual(arguments[2:], (self.target, self.identifier))
        transport.install.assert_not_called()
        for path, contents in before.items():
            self.assertEqual(path.read_bytes(), contents)
        evidence = list((self.directory / 'diagnostics').glob('installer-*.json'))
        self.assertEqual(len(evidence), 1)
        self.assertEqual(host.read_json(evidence[0])['observation'], transport.diagnose.return_value)
        self.assert_parent_unchanged()

    def test_abandonment_waits_for_supervisor_then_uses_guest_shutdown_without_force(self):
        runtime, transport, select = self.abandonment_fixture()
        with patch.object(upgrade, 'module', side_effect=select), \
                patch.object(upgrade, 'supervisor_alive', side_effect=[True, False, False]), \
                patch.object(upgrade.time, 'sleep'), \
                patch.object(host, 'check_capacity', side_effect=AssertionError('Abandonment checked startup capacity')), \
                patch.object(host, 'xcode_upgrade_module', side_effect=AssertionError('Abandonment checked Xcode')), \
                patch.object(host, 'stop_owned_process', side_effect=AssertionError('Forced VM stop')):
            self.assertEqual(upgrade.upgrade(host, self.args, self.state), 0)
        transport.abandon.assert_called_once()
        transport.halt_abandoned.assert_called_once()
        self.assertTrue(transport.halt_abandoned.call_args.args[1]['supervisorExited'])
        retained = host.read_json(self.directory / 'result.json')
        self.assertEqual((retained['status'], retained['phase']), ('cancelled', 'abandoned'))
        self.assertTrue((self.staged / 'baseline.vbvm').is_dir())
        self.assert_parent_unchanged()

    def test_abandonment_cannot_halt_while_supervisor_retains_ownership(self):
        _, transport, select = self.abandonment_fixture()
        with patch.object(upgrade, 'module', side_effect=select), \
                patch.object(upgrade, 'supervisor_alive', return_value=True), \
                patch.object(upgrade.time, 'monotonic', side_effect=[0, 100]), \
                self.assertRaisesRegex(host.RunnerError, 'no shutdown was attempted'):
            upgrade.abandon(host, self.args, self.state)
        transport.halt_abandoned.assert_not_called()
        self.assert_parent_unchanged()

    def abandonment_fixture(self, *, running=True, collected=False):
        _, _, _, runtime, transport = self.diagnostic_fixture()
        self.args.resume = self.identifier
        self.args.abandon = True
        self.native_running = running
        runtime._native_alive.side_effect = lambda *args: self.native_running
        runtime._native_status = Mock(return_value={'state': 'stopped', 'running': False})
        request = {'upgradeID': self.identifier, 'target': self.target, 'upgradeNonce': 'a' * 64, 'vmId': self.result['vmId'], 'consoleUser': 'wallet-test'}
        boot = '12345678-1234-4234-8234-123456789012'
        receipt = {'version': 1, **request, 'phase': 'restart-pending', 'before': self.source_macos,
                   'preBootIdentity': boot, 'workerPID': 101, 'installerPID': 102, 'exitCode': 0}
        intent = {'version': 1, **request, 'reason': 'insufficient_guest_system_storage', 'before': self.source_macos,
            'preBootIdentity': boot, 'receiptSHA256': hashlib.sha256((json.dumps(receipt, sort_keys=True) + '\n').encode()).hexdigest(),
            'evidence': {'requiredBytes': 20 * 1024 ** 3, 'freeBytesAtRejection': 14 * 1024 ** 3,
                'currentAvailableBytes': 14 * 1024 ** 3, 'noInstallerProcesses': True, 'workerPID': 101, 'installerPID': 102}}
        evidence = {'status': 'blocked', 'safeToStop': False, 'reason': 'upgrade_abandoned_for_storage',
                    'actual': self.source_macos, 'bootIdentity': boot, 'receipt': receipt, 'abandonment': intent}
        transport.abandon = Mock(return_value=evidence)
        def halt(*args):
            self.native_running = False
            return {'shutdownRequested': True}
        transport.halt_abandoned = Mock(side_effect=halt)
        if collected:
            host.atomic_json(self.directory / 'abandonment.json', {'version': 1, 'upgradeID': self.identifier,
                'requestedAt': 'fixture-time', 'guestEvidence': evidence})
        return runtime, transport, lambda name: {'macos_vm': runtime, 'macos_transport': transport}[name]

    def test_stopped_guest_after_lost_client_finishes_abandonment_without_any_guest_commands(self):
        runtime, transport, select = self.abandonment_fixture(running=False, collected=True)
        with patch.object(upgrade, 'module', side_effect=select) as modules, \
                patch.object(upgrade, 'supervisor_alive', return_value=False), \
                patch.object(host, 'stop_owned_process', side_effect=AssertionError('Forced VM stop')), \
                patch.object(host, 'monitor_vm', side_effect=AssertionError('VM started')), \
                patch.object(upgrade.subprocess, 'Popen', side_effect=AssertionError('Process spawned')):
            self.assertEqual(upgrade.abandon(host, self.args, self.state), 0)
        self.assertEqual({call.args[0] for call in modules.call_args_list}, {'macos_vm'})
        runtime._access_context.assert_not_called()
        transport.abandon.assert_not_called()
        transport.halt_abandoned.assert_not_called()
        self.assertEqual(host.read_json(self.directory / 'result.json')['phase'], 'abandoned')
        self.assert_parent_unchanged()

    def test_abandonment_retry_after_final_record_write_failure_does_not_repeat_guest_shutdown(self):
        runtime, transport, select = self.abandonment_fixture()
        write = host.atomic_json
        def interrupted(path, value):
            if path == self.directory / 'result.json' and value.get('phase') == 'abandoned':
                raise OSError('fixture client lost after guest halt')
            return write(path, value)
        with patch.object(upgrade, 'module', side_effect=select), patch.object(upgrade, 'supervisor_alive', return_value=False):
            with patch.object(host, 'atomic_json', side_effect=interrupted), self.assertRaisesRegex(OSError, 'client lost'):
                upgrade.abandon(host, self.args, self.state)
            self.assertFalse(self.native_running)
            self.assertEqual(host.read_json(self.directory / 'result.json')['phase'], 'installation')
            self.assertEqual(upgrade.abandon(host, self.args, self.state), 0)
        transport.abandon.assert_called_once()
        transport.halt_abandoned.assert_called_once()
        self.assertEqual(host.read_json(self.directory / 'result.json')['phase'], 'abandoned')

    def test_completed_abandonment_check_and_repeat_are_read_only_and_idempotent(self):
        runtime, transport, select = self.abandonment_fixture(running=False, collected=True)
        with patch.object(upgrade, 'module', side_effect=select), patch.object(upgrade, 'supervisor_alive', return_value=False):
            self.assertEqual(upgrade.abandon(host, self.args, self.state), 0)
            before = (self.directory / 'result.json').read_bytes()
            pointer = self.state / 'macos-upgrade-active.json'
            with patch.object(host, 'ROOT', self.root / 'another-worktree'):
                self.assertIsNone(upgrade.control(host, SimpleNamespace(command='status'), self.state))
                self.assertTrue(pointer.exists())
                with host.execution_lock(self.state):
                    upgrade.ensure_no_supervisor(host, self.state)
                self.assertFalse(pointer.exists())
            self.args.check = True
            with patch.object(host, 'atomic_json', side_effect=AssertionError('Check rewrote state')):
                self.assertEqual(upgrade.upgrade(host, self.args, self.state), 0)
            self.args.check = False
            self.assertEqual(upgrade.upgrade(host, self.args, self.state), 0)
        self.assertEqual((self.directory / 'result.json').read_bytes(), before)
        runtime._access_context.assert_not_called()
        transport.abandon.assert_not_called()
        transport.halt_abandoned.assert_not_called()

    def test_abandoned_upgrade_rejects_normal_resume(self):
        self.result.update(status='cancelled', phase='abandoned')
        self.save()
        self.args.resume = self.identifier
        with patch.object(upgrade.subprocess, 'Popen', side_effect=AssertionError('Spawned abandoned upgrade')), \
                self.assertRaisesRegex(host.RunnerError, 'was abandoned'):
            upgrade.upgrade(host, self.args, self.state)
        self.assertEqual(host.read_json(self.directory / 'result.json')['phase'], 'abandoned')

    def test_another_worktree_cannot_release_a_protected_installation(self):
        self.diagnostic_fixture()
        self.result.update(status='blocked', installation={'vmPreservedRunning': True})
        self.save()
        with patch.object(host, 'ROOT', self.root / 'another-worktree'), host.execution_lock(self.state), \
                self.assertRaisesRegex(host.RunnerError, 'this repository'):
            upgrade.ensure_no_supervisor(host, self.state)
        self.assertTrue((self.state / 'macos-upgrade-active.json').exists())

    def test_preinstall_stop_releases_other_worktrees_only_after_confirmed_shutdown(self):
        install, journal, _, runtime, _ = self.diagnostic_fixture()
        pointer = self.state / 'macos-upgrade-active.json'
        for handoff in (False, True):
            with self.subTest(cancelling=handoff):
                self.result.update(status='blocked', installation={'status': 'blocked', 'vmPreservedRunning': handoff})
                self.save()
                host.atomic_json(pointer, {'version': 1, 'upgradeID': self.identifier})
                journal.update(native={'process': {'pid': 12345}}, boots=1, protected=handoff,
                    phase='needs-attention' if handoff else 'blocked', awaitingGuestShutdown='cancelled' if handoff else False)
                host.atomic_json(install / 'install.json', journal)
                runtime._native_alive.return_value = True
                runtime._native_status = Mock(return_value={'state': 'stopped', 'running': False})
                with patch.object(host, 'ROOT', self.root / 'another-worktree'), patch.object(upgrade, 'module', return_value=runtime), \
                        host.execution_lock(self.state):
                    with self.assertRaisesRegex(host.RunnerError, 'not confirmed shutdown'):
                        upgrade.ensure_no_supervisor(host, self.state)
                    runtime._native_alive.return_value = False
                    runtime._native_status.return_value = {'state': 'stopping', 'running': True}
                    with self.assertRaisesRegex(host.RunnerError, 'not confirmed shutdown'):
                        upgrade.ensure_no_supervisor(host, self.state)
                    runtime._native_status.return_value = {'state': 'stopped', 'running': False}
                    self.assertIsNone(upgrade.active_result(host, self.state))
                    self.assertTrue(pointer.exists())
                    upgrade.ensure_no_supervisor(host, self.state)
                    self.assertFalse(pointer.exists())
                self.assertEqual(host.read_json(self.directory / 'result.json')['status'], 'cancelled' if handoff else 'blocked')

    def test_cancelled_validation_releases_parent_only_after_quiescence_and_retains_resume(self):
        def cancel(args, state, environment, *, result_callback):
            self.calls.append(('cancelled-roundtrips', state))
            result_callback(*self.report(state, status='cancelled'))
            return 2
        stack, _ = self.execution_fixture(failure=cancel)
        with stack, self.assertRaises(InterruptedError):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        self.result['status'] = 'cancelled'
        self.save()
        before = (self.directory / 'result.json').read_bytes()
        pointer = self.state / 'macos-upgrade-active.json'
        host.atomic_json(pointer, {'version': 1, 'upgradeID': self.identifier})
        clone = self.staged / 'runs/retained.vbvm'
        self.make_vm(clone)
        with patch.object(host, 'ROOT', self.root / 'another-worktree'), host.execution_lock(self.state):
            with host.execution_lock(self.staged), self.assertRaisesRegex(host.RunnerError, 'Another VM operation is active'):
                upgrade.ensure_no_supervisor(host, self.state)
            self.assertTrue(pointer.exists())
            for scope in (self.staged, self.state):
                active = scope / 'active.json'
                host.atomic_json(active, {'ownerPID': 100})
                with self.assertRaisesRegex(host.RunnerError, 'still owns a VM'):
                    upgrade.ensure_no_supervisor(host, self.state)
                self.assertTrue(pointer.exists())
                active.unlink()
            def busy(path):
                if path == clone:
                    raise host.RunnerError('retained test clone still running')
            with patch.object(host, 'ensure_disk_idle', side_effect=busy), self.assertRaisesRegex(host.RunnerError, 'still running'):
                upgrade.ensure_no_supervisor(host, self.state)
            self.assertTrue(pointer.exists())
            with patch.object(upgrade, 'supervisor_alive', return_value=True), self.assertRaises(host.RunnerError):
                upgrade.ensure_no_supervisor(host, self.state)
            self.assertTrue(pointer.exists())
            upgrade.ensure_no_supervisor(host, self.state)
            self.assertFalse(pointer.exists())
        self.assertTrue(clone.is_dir())
        self.assert_parent_unchanged()
        self.assertEqual((self.directory / 'result.json').read_bytes(), before)
        self.args.resume = self.identifier
        self.assertEqual(upgrade.preview(host, self.args, self.state)['status'], 'ready')
        stack, installer = self.execution_fixture()
        with stack:
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        installer.assert_not_called()
        self.assertEqual(self.result['status'], 'passed')

    def test_stopped_abandonment_requires_bound_receipt_hash_vm_target_and_terminal_state(self):
        runtime, transport, select = self.abandonment_fixture(running=False, collected=True)
        path = self.directory / 'abandonment.json'
        original = host.read_json(path)
        changes = [lambda item: item['guestEvidence']['abandonment'].update(receiptSHA256='0' * 64),
            lambda item: item['guestEvidence']['abandonment'].update(vmId='another-vm'),
            lambda item: item['guestEvidence']['abandonment'].update(upgradeNonce='b' * 64),
            lambda item: item['guestEvidence']['receipt'].update(target={'version': '28.0', 'buildVersion': '27A100'}),
            lambda item: item.update(upgradeID='macos-upgrade-20261103T120000Z-9999abcd'),
            lambda item: item['guestEvidence'].update(bootIdentity='12345678-1234-4234-8234-123456789013')]
        with patch.object(upgrade, 'module', side_effect=select), patch.object(upgrade, 'supervisor_alive', return_value=False):
            for change in changes:
                value = copy.deepcopy(original)
                change(value)
                host.atomic_json(path, value)
                with self.subTest(change=change), self.assertRaises(host.RunnerError):
                    upgrade.abandon(host, self.args, self.state)
            host.atomic_json(path, original)
            runtime._native_status.return_value = {'state': 'stopping', 'running': False}
            with self.assertRaisesRegex(host.RunnerError, 'terminal stopped state'):
                upgrade.abandon(host, self.args, self.state)
        runtime._access_context.assert_not_called()
        transport.abandon.assert_not_called()
        transport.halt_abandoned.assert_not_called()
        self.assertEqual(host.read_json(self.directory / 'result.json')['phase'], 'installation')

    def test_abandonment_refuses_a_changed_original_baseline_before_guest_actions(self):
        self.stage()
        self.result['phase'] = 'installation'
        self.save()
        host.atomic_json(self.state / 'macos-upgrade-active.json', {'version': 1, 'upgradeID': self.identifier})
        self.args.resume = self.identifier
        (self.baseline / 'Disk.img').write_bytes(b'changed')
        with patch.object(upgrade, 'installation_context', side_effect=AssertionError('Guest action')), \
                self.assertRaisesRegex(host.RunnerError, 'unchanged active baseline'):
            upgrade.abandon(host, self.args, self.state)

    def test_growth_preview_requires_recovery_space_above_actual_reserve(self):
        from test_macos_disk import fixture_image
        (self.baseline / 'Disk.img').write_bytes(fixture_image(recovery_sectors=512))
        self.args.system_disk_gib = 96
        reserve = 10_000_000_000
        for free, expected in ((reserve + 512 * 512 - 1, 'blocked'), (reserve + 512 * 512, 'ready')):
            with patch.object(shutil, 'disk_usage', return_value=SimpleNamespace(free=free)):
                self.assertEqual(upgrade.preview(host, self.args, self.state)['status'], expected)
        self.clones.assert_not_called()

    def test_system_disk_size_is_explicit_and_cannot_change_on_resume(self):
        self.args.system_disk_gib = 96
        with patch.object(upgrade, 'module', return_value=SimpleNamespace(inspect_disk=Mock(return_value={'validated': True}))):
            preview = upgrade.preview(host, self.args, self.state)
        self.assertEqual(preview['systemDiskBytes'], 96 * 1024 ** 3)
        self.assertEqual(preview['status'], 'ready')
        self.result['systemDiskBytes'] = 96 * 1024 ** 3
        self.save()
        self.args.resume = self.identifier
        self.args.system_disk_gib = 128
        with self.assertRaisesRegex(host.RunnerError, 'original system disk size'):
            upgrade.preview(host, self.args, self.state)

    def test_interrupted_raw_disk_publication_recovers_before_vm_validation(self):
        self.stage()
        disk = self.staged / 'baseline.vbvm/Disk.img'
        disk.unlink()
        self.result.update({'phase': 'system-disk-growth', 'systemDiskBytes': 96 * 1024 ** 3})
        self.save()
        proof = {'resized': True, 'newBytes': self.result['systemDiskBytes']}
        def grow(selected_host, vm, size, receipt):
            self.assertEqual(vm, self.staged / 'baseline.vbvm')
            self.assertFalse(disk.exists())
            self.assert_parent_unchanged()
            disk.write_bytes(b'expanded-fixture')
            return proof
        grow_mock = Mock(side_effect=grow)
        stack, installer = self.execution_fixture()
        with stack, patch.object(upgrade, 'module', side_effect=lambda name: SimpleNamespace(grow=grow_mock) if name == 'macos_disk' else SimpleNamespace(install=installer)), \
                patch.object(host, 'validate_vm', side_effect=lambda vm: ((vm / 'Disk.img').stat(), plistlib.loads((vm / '.vbdata/Config.plist').read_bytes()))[1]):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        grow_mock.assert_called_once()
        self.assertEqual(installer.call_args.args[1].system_disk_growth, proof)
        self.assertTrue(self.result['systemDiskReady'])
        self.assertEqual(self.result['status'], 'passed')

    def test_completed_raw_growth_is_not_repeated_after_guest_filesystem_changes(self):
        self.result.update({'systemDiskBytes': 96 * 1024 ** 3, 'systemDiskReady': True,
                            'systemDiskGrowth': {'resized': True}})
        stack, installer = self.execution_fixture()
        with stack, patch.object(upgrade, 'module', side_effect=lambda name: SimpleNamespace(install=installer) if name == 'macos_vm' else self.fail('Repeated raw disk growth')):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        self.assertEqual(self.result['status'], 'passed')

    def test_stop_during_final_source_check_does_not_commit_promotion(self):
        checks = []
        def check(selected_host, directory, source):
            checks.append(source)
            if len(checks) == 2:
                host.atomic_json(directory / 'stop.json', {'version': 1, 'upgradeID': self.identifier})
            return self.source
        stack, _ = self.execution_fixture()
        with stack, patch.object(upgrade, 'require_source', side_effect=check), \
                self.assertRaisesRegex(InterruptedError, 'before promotion'):
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        self.assertEqual(len(checks), 2)
        self.assert_parent_unchanged()
        self.assertFalse((self.state / 'candidate.json').exists())
        self.assertFalse((self.directory / 'promotion-handoff.vbvm').exists())
        self.assertEqual(len(list(self.directory.glob('withdrawn-*.vbvm'))), 1)
        self.assertEqual(self.result['phase'], 'setup')
        self.assertFalse(self.result['fullSuiteVerified'])

    def test_stop_after_candidate_metadata_backup_releases_parent_and_requires_fresh_validation(self):
        self.result['launchToken'] = 'a' * 32
        self.save()
        host.atomic_json(self.state / 'macos-upgrade-active.json', {'version': 1, 'upgradeID': self.identifier})
        preserve = host.preserve_previous_baseline_record
        def stop(state, record, promoted, backup):
            preserve(state, record, promoted, backup)
            self.assertTrue(backup.with_suffix('.json').exists())
            upgrade.control(host, SimpleNamespace(command='stop'), self.state)
        stack, installer = self.execution_fixture()
        def select(name):
            return host if name == 'host' else SimpleNamespace(install=installer)
        with stack, patch.object(upgrade, 'module', side_effect=select), patch.object(upgrade.signal, 'signal'), \
                patch.object(upgrade.os, 'umask'), patch.object(upgrade, 'process_start', return_value=[1000000000, 12345]), \
                patch.object(host, 'preserve_previous_baseline_record', side_effect=stop):
            self.assertEqual(upgrade.worker(self.state, self.identifier, self.result['launchToken']), 2)
        self.result = host.read_json(self.directory / 'result.json')
        self.assertEqual((self.result['status'], self.result['phase']), ('cancelled', 'setup'))
        self.assertFalse(self.result['fullSuiteVerified'])
        self.assert_parent_unchanged()
        for name in ('candidate.json', 'candidate.vbvm'):
            self.assertFalse((self.state / name).exists())
        self.assertFalse(list(self.state.glob('previous-baseline-*')))
        self.assertEqual(len(list(self.directory.glob('withdrawn-*.vbvm'))), 1)
        upgrade.ensure_no_supervisor(host, self.state)
        self.assertEqual(upgrade.preview(host, self.args, self.state)['status'], 'ready')
        before = len(self.calls)
        (self.directory / 'stop.json').unlink()
        stack, installer = self.execution_fixture()
        with stack:
            upgrade.execute(host, self.state, self.directory, self.result, self.save)
        installer.assert_not_called()
        self.assertIn(('run', self.staged, []), self.calls[before:])
        self.assertEqual(self.result['status'], 'passed')


if __name__ == '__main__':
    unittest.main()
