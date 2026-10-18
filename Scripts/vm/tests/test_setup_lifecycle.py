import contextlib
import importlib.util
import io
from pathlib import Path
import plistlib
import shutil
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('setup_lifecycle_host', Path(__file__).resolve().parents[1] / 'host.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class SetupFixture:
    def __init__(self, test, stop_phase=None, baseline=False):
        self.test = test
        self.stop_phase = stop_phase
        self.stack = contextlib.ExitStack()
        self.state = Path(self.stack.enter_context(tempfile.TemporaryDirectory())).resolve()
        self.original = self.state / 'original.vbvm'
        self.candidate = self.state / 'candidate.vbvm'
        self.baseline = self.state / 'baseline.vbvm'
        self.make_vm(self.original, b'original')
        self.args = host.parser().parse_args(['--vm', str(self.original), 'setup'])
        self.environment = {'minimumHostFreeBytes': 1, 'buildData': {'bytes': 1024}}
        self.tools = {'guest_bootstrap.mjs': 'fixture-tools'}
        self.launches = []
        self.stop_exchange = None
        self.snapshot_count = 0
        if baseline:
            self.make_vm(self.baseline, b'old-baseline')
            host.atomic_json(self.state / 'baseline.json', {'version': 1, 'vmId': 'fixture-vm',
                'sourceVM': str(self.original), 'consoleUser': 'wallet-test', 'environment': self.environment,
                'bootstrapTools': self.tools, 'bootstrapSourceDigest': 'outdated'})
        for name, value in [('check_capacity', None), ('bootstrap_tool_hashes', self.tools),
                            ('ensure_disk_idle', None), ('environment_attested', True), ('verify_setup_sources', None)]:
            self.stack.enter_context(patch.object(host, name, return_value=value))
        for name, action in [('build_tools', self.build_tools), ('clone_vm', self.clone),
                             ('stage_provisioning', self.stage), ('snapshot_source', self.snapshot),
                             ('stage_planned_result', self.plan), ('run_setup_doctor', self.doctor)]:
            self.stack.enter_context(patch.object(host, name, side_effect=action))
        self.stack.enter_context(patch.object(host, 'guest_access_module', side_effect=AssertionError('No disk access or SSH in lifecycle fixtures')))
        self.stack.enter_context(patch.object(host, 'prepared_guest_hook', return_value=None))
        self.stack.enter_context(patch.object(host.subprocess, 'Popen', side_effect=self.launch))
        self.stack.enter_context(patch('sys.stdout', new=io.StringIO()))

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.stack.close()

    def make_vm(self, path, disk):
        (path / '.vbdata').mkdir(parents=True)
        for name in ('Disk.img', 'AuxiliaryStorage', 'HardwareModel', 'MachineIdentifier'):
            (path / name).write_bytes(disk)
        configuration = {'systemType': 'mac', 'hardware': {'_storageDevices': [{'isBootVolume': True,
            'backing': {'managedImage': {'_0': {'filename': 'Disk', 'format': 0}}}}],
            'networkDevices': [{'macAddress': '02:00:00:00:00:01'}]}, 'sharedFolders': []}
        (path / '.vbdata/Config.plist').write_bytes(plistlib.dumps(configuration))
        (path / '.vbdata/Metadata.plist').write_bytes(plistlib.dumps({'uuid': 'original-vm'}))

    def stop(self, phase):
        if self.stop_phase != phase:
            return
        active = host.read_json(self.state / 'active.json')
        self.stop_exchange = Path(active['exchange'])
        with patch.object(host.sys, 'platform', 'darwin'), \
                patch.object(host.os, 'uname', return_value=SimpleNamespace(machine='arm64')):
            self.test.assertEqual(host.main(['--state-dir', str(self.state), 'status']), 0)
            self.test.assertEqual(host.main(['--state-dir', str(self.state), 'stop']), 0)
        self.test.assertEqual(host.read_json(self.stop_exchange / 'stop.json')['runId'], active['runId'])

    def build_tools(self, *args):
        self.stop('tools')
        return self.state / 'tools'

    def clone(self, source, destination):
        shutil.copytree(source, destination)
        (destination / 'Disk.img').write_bytes(b'verified-candidate')
        self.stop('clone')

    def stage(self, args, state, exchange, environment, record, binaries):
        self.stop('archive')
        return {'consoleUser': 'wallet-test'}

    def snapshot(self, repository, exchange):
        self.snapshot_count += 1
        host.atomic_json(exchange / 'snapshot-manifest.json', {'version': 1, 'files': []})
        self.stop('snapshot' if self.snapshot_count == 1 else 'validation-snapshot')
        return {'sha256': host.hash_regular_file(exchange / 'snapshot-manifest.json'), 'commit': 'fixture'}

    def plan(self, exchange, job):
        plan = {'version': 1, 'runId': job['runId'], 'vmId': job['vmId'], 'source': job['source'],
                'jobSHA256': host.hash_regular_file(exchange / 'job.json'), 'origin': 'host-plan',
                'status': 'planned', 'stages': [{'id': 'test.fixture', 'status': 'pending'}]}
        host.atomic_json(exchange / 'artifacts/planned-result.json', plan)
        self.stop('validation-plan')
        return plan

    def launch(self, command, **kwargs):
        exchange = Path(command[command.index('--status') + 1]).parent
        job = host.read_json(exchange / 'job.json')
        self.launches.append(job['kind'])
        if job['kind'] == 'run':
            self.test.assertEqual(job['payload'], {
                'stages': ['test'], 'configuration': 'Debug', 'signing': 'local',
                'onlyTesting': ['WindowAuthenticationSessionTests', 'PasswordStorageTests', 'SecretHandlingTests']})
        if job['kind'] == 'doctor':
            self.doctor_control = (exchange, job['runId'])
        elif self.stop_phase == 'late-prior-stop':
            self.stop_exchange = exchange
            host.atomic_json(self.doctor_control[0] / 'stop.json', {'runId': self.doctor_control[1]})
        report = {'version': 1, 'runId': job['runId'], 'status': 'passed', 'finishedAt': 'fixture',
                  'identity': {'vmId': job['vmId'], 'consoleUser': 'wallet-test'}, 'source': job['source'],
                  'preflight': {'bootstrap': {'available': True, 'hashes': self.tools},
                    'checks': {**{name: True for name in ('bootstrap', 'node', 'python', 'jq', 'xcode', 'macos', 'ios', 'visionos')},
                               'signing': False, 'proofKey': False}}}
        host.atomic_json(exchange / 'artifacts/result.json', report)
        fixture = self
        class Child:
            returncode = None
            def poll(self):
                return self.returncode
            def wait(self, timeout=None):
                if job['kind'] == 'doctor':
                    fixture.stop('doctor-shutdown')
                    if fixture.stop_phase == 'doctor-signal':
                        fixture.stop_exchange = exchange
                        handler = host.signal.getsignal(host.signal.SIGTERM)
                        handler(host.signal.SIGTERM, None)
                self.returncode = 0
                return 0
        return Child()

    def doctor(self, args, state, candidate, environment, operation, record, configuration,
               binaries, bootstrap_tools, source, password, source_digest):
        run_id, exchange = operation['runId'], operation['exchange']
        host.atomic_json(exchange / 'job.json', {'version': 1, 'runId': run_id, 'vmId': record['vmId'],
            'kind': 'doctor', 'profile': 'all', 'payload': {'stages': [], 'onlyTesting': []}, 'source': source,
            'bootstrapTools': bootstrap_tools})
        operation['monitorCalled'] = True
        return host.monitor_vm(args, state, candidate, exchange, run_id, binaries, environment,
            args.timeout or 120, password, keep_operation=True, previous_stops=operation['previousStops']), exchange

    def run(self):
        return host.setup(self.args, self.state, self.environment)


class SetupPreparationTests(unittest.TestCase):
    def test_runner_source_edit_during_tool_preparation_blocks_before_candidate_creation(self):
        with SetupFixture(self) as fixture:
            sources = fixture.state / 'setup-sources'
            sources.mkdir()
            for source in host.TOOLS.iterdir():
                if source.is_file():
                    shutil.copyfile(source, sources / source.name)
            def build(*args):
                (sources / 'VMGuestAgent.swift').write_text('changed during tool preparation')
                return fixture.state / 'tools'
            with patch.object(host, 'TOOLS', sources), patch.object(host, 'build_tools', side_effect=build):
                with self.assertRaisesRegex(host.RunnerError, 'sources changed during setup'):
                    fixture.run()
            self.assertFalse(fixture.candidate.exists())
            self.assertEqual(fixture.launches, [])
            self.assertFalse((fixture.state / 'active.json').exists())

    def test_installer_edits_during_doctor_or_validation_cannot_stamp_a_new_source_identity(self):
        for phase in ('doctor', 'run'):
            with self.subTest(phase=phase), SetupFixture(self) as fixture:
                sources = fixture.state / 'setup-sources'
                sources.mkdir()
                for source in host.TOOLS.iterdir():
                    if source.is_file():
                        shutil.copyfile(source, sources / source.name)
                installer = sources / 'provision_guest.sh'
                launch = fixture.launch
                def edit_after_report(command, **options):
                    child = launch(command, **options)
                    exchange = Path(command[command.index('--status') + 1]).parent
                    if host.read_json(exchange / 'job.json')['kind'] == phase:
                        installer.write_bytes(installer.read_bytes() + b'\nfixture installer edit\n')
                    return child
                with patch.object(host, 'TOOLS', sources), patch.object(host.subprocess, 'Popen', side_effect=edit_after_report):
                    captured = host.bootstrap_source_digest()
                    with self.assertRaisesRegex(host.RunnerError, 'sources changed during setup'):
                        fixture.run()
                    current = host.bootstrap_source_digest()
                record = host.read_json(fixture.state / 'candidate.json')
                self.assertNotEqual(current, captured)
                self.assertNotEqual(record.get('bootstrapSourceDigest'), current)
                if phase == 'doctor':
                    self.assertNotIn('baseVerifiedAt', record)
                else:
                    self.assertEqual(record['bootstrapSourceDigest'], captured)
                self.assertNotIn('promotionPending', record)
                self.assertFalse((fixture.state / 'baseline.json').exists())
                self.assertFalse((fixture.state / 'active.json').exists())

    def test_unchanged_setup_records_its_verified_identity_and_reuses_the_baseline(self):
        with SetupFixture(self) as fixture:
            captured = host.bootstrap_source_digest()
            self.assertEqual(fixture.run(), 0)
            baseline = host.read_json(fixture.state / 'baseline.json')
            self.assertEqual(baseline['bootstrapSourceDigest'], captured)
            self.assertEqual(baseline['verificationSigningMode'], 'local')
            self.assertEqual(fixture.launches, ['doctor', 'run'])
            fixture.launches.clear()
            self.assertEqual(fixture.run(), 0)
            self.assertEqual(fixture.launches, [])

    def test_failed_local_smoke_tests_do_not_promote_a_baseline(self):
        with SetupFixture(self) as fixture:
            launch = fixture.launch
            def fail_smoke(command, **options):
                child = launch(command, **options)
                exchange = Path(command[command.index('--status') + 1]).parent
                if host.read_json(exchange / 'job.json')['kind'] == 'run':
                    report = host.read_json(exchange / 'artifacts/result.json')
                    report.update(status='failed', stages=[{'id': 'test.macos.debug', 'status': 'failed'}])
                    host.atomic_json(exchange / 'artifacts/result.json', report)
                return child
            with patch.object(host.subprocess, 'Popen', side_effect=fail_smoke):
                self.assertEqual(fixture.run(), 2)
            self.assertEqual(fixture.launches, ['doctor', 'run'])
            self.assertFalse((fixture.state / 'baseline.json').exists())
            candidate = host.read_json(fixture.state / 'candidate.json')
            self.assertIn('baseVerifiedAt', candidate)
            self.assertNotIn('verifiedAt', candidate)
            self.assertNotIn('verificationSigningMode', candidate)
            self.assertNotIn('promotionPending', candidate)

    def test_baseline_without_local_verification_requires_smoke_tests(self):
        with SetupFixture(self) as fixture:
            self.assertEqual(fixture.run(), 0)
            baseline_path = fixture.state / 'baseline.json'
            baseline = host.read_json(baseline_path)
            baseline.pop('verificationSigningMode')
            host.atomic_json(baseline_path, baseline)
            fixture.launches.clear()
            self.assertEqual(fixture.run(), 0)
            self.assertEqual(fixture.launches, ['doctor', 'run'])
            self.assertEqual(host.read_json(baseline_path)['verificationSigningMode'], 'local')

    def test_stop_during_preparation_cancels_before_the_next_vm_launch(self):
        phases = ('tools', 'clone', 'archive', 'snapshot', 'doctor-shutdown', 'doctor-signal', 'validation-snapshot', 'validation-plan')
        for phase in phases:
            with self.subTest(phase=phase), SetupFixture(self, phase) as fixture:
                self.assertEqual(fixture.run(), 2)
                expected = ['doctor'] if phase.startswith(('validation', 'doctor')) else []
                self.assertEqual(fixture.launches, expected)
                report = host.read_json(fixture.stop_exchange / 'artifacts/result.json')
                self.assertEqual(report['status'], 'cancelled')
                if phase.startswith('validation'):
                    self.assertEqual(report['stages'], [{'id': 'test.fixture', 'status': 'cancelled',
                        'reason': 'cancelled', 'finishedAt': report['finishedAt']}])
                self.assertFalse((fixture.state / 'active.json').exists())
                self.assertFalse((fixture.state / 'baseline.json').exists())
                self.assertEqual((fixture.original / 'Disk.img').read_bytes(), b'original')

    def test_late_stop_from_the_previous_phase_is_not_lost_during_handoff(self):
        with SetupFixture(self) as fixture:
            original = host.register_operation
            def register(state, vm, exchange, run_id, phase, previous=None):
                original(state, vm, exchange, run_id, phase, previous=previous)
                if previous:
                    host.atomic_json(previous[1] / 'stop.json', {'runId': previous[0]})
            with patch.object(host, 'register_operation', side_effect=register):
                self.assertEqual(fixture.run(), 2)
            self.assertEqual(fixture.launches, ['doctor'])
            results = list((fixture.state / 'results').glob('setup-validation-*/artifacts/result.json'))
            self.assertEqual(len(results), 1)
            self.assertEqual(host.read_json(results[0])['status'], 'cancelled')
            self.assertFalse((fixture.state / 'active.json').exists())

    def test_successful_doctor_shutdown_does_not_cancel_validation(self):
        with SetupFixture(self) as fixture:
            self.assertEqual(fixture.run(), 0)
            self.assertEqual(fixture.launches, ['doctor', 'run'])
            self.assertTrue((fixture.state / 'baseline.json').exists())
            self.assertFalse((fixture.state / 'active.json').exists())
            self.assertEqual(list(fixture.state.glob('setup/*/stop.json')), [])

    def test_validation_monitor_honors_a_late_stop_from_the_previous_phase(self):
        with SetupFixture(self, 'late-prior-stop') as fixture:
            self.assertEqual(fixture.run(), 2)
            self.assertEqual(fixture.launches, ['doctor', 'run'])
            report = host.read_json(fixture.stop_exchange / 'artifacts/result.json')
            self.assertEqual(report['status'], 'cancelled')
            self.assertEqual(report['guestResultAfterStop'], 'guest-result-after-stop.json')
            self.assertFalse((fixture.state / 'baseline.json').exists())

    def test_signal_during_handoff_keeps_cancellation_with_the_new_operation(self):
        with SetupFixture(self) as fixture:
            original = host.register_operation
            def register(state, vm, exchange, run_id, phase, previous=None):
                original(state, vm, exchange, run_id, phase, previous=previous)
                if previous:
                    raise KeyboardInterrupt
            with patch.object(host, 'register_operation', side_effect=register):
                self.assertEqual(fixture.run(), 2)
            self.assertEqual(fixture.launches, ['doctor'])
            results = list((fixture.state / 'results').glob('setup-validation-*/artifacts/result.json'))
            self.assertEqual(len(results), 1)
            self.assertEqual(host.read_json(results[0])['status'], 'cancelled')
            self.assertFalse((fixture.state / 'active.json').exists())

    def test_stage_only_finishes_without_leaving_an_active_operation(self):
        with SetupFixture(self) as fixture:
            fixture.args.stage_only = True
            self.assertEqual(fixture.run(), 2)
            self.assertEqual(fixture.launches, [])
            self.assertFalse((fixture.state / 'active.json').exists())
            self.assertTrue(fixture.candidate.exists())


class BaselinePromotionTests(unittest.TestCase):
    def test_candidate_inherits_and_promotes_baseline_credentials_without_new_inputs(self):
        access = host.guest_access_module()
        with SetupFixture(self, baseline=True) as fixture:
            baseline = host.read_json(fixture.state / 'baseline.json')
            _, exchange = host.new_exchange(fixture.state, 'setup')
            (exchange / 'provision').mkdir(mode=0o700)
            source = exchange / 'provision/password'
            source.write_text('fixture retained password\n')
            source.chmod(0o600)
            configuration = {'consoleUser': baseline['consoleUser'],
                'provisioningRequestID': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
                'autologin': {'passwordFile': 'password'}}
            directory, password = host.guest_setup_password(access, fixture.state, baseline, configuration, exchange, None)
            host.atomic_json(fixture.state / 'baseline.json', baseline)
            def stage(*args):
                self.assertEqual(args[4]['guestAccessID'], baseline['guestAccessID'])
                return fixture.stage(*args)
            with patch.object(host, 'stage_provisioning', side_effect=stage):
                self.assertEqual(fixture.run(), 0)
            promoted = host.read_json(fixture.state / 'baseline.json')
            self.assertEqual(promoted['guestAccessID'], baseline['guestAccessID'])
            self.assertEqual(host.guest_setup_password(access, fixture.state, promoted,
                {'consoleUser': promoted['consoleUser']}, exchange, None), (directory, password))
            self.assertEqual(access.read_private_password(password), b'fixture retained password')

    def test_interrupted_promotion_retains_the_new_credential_reference_and_old_scope(self):
        access = host.guest_access_module()
        with SetupFixture(self, baseline=True) as fixture:
            baseline = host.read_json(fixture.state / 'baseline.json')
            _, exchange = host.new_exchange(fixture.state, 'setup')
            (exchange / 'provision').mkdir(mode=0o700)
            source = exchange / 'provision/password'
            source.write_text('fixture baseline password\n')
            source.chmod(0o600)
            configuration = {'consoleUser': baseline['consoleUser'],
                'provisioningRequestID': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
                'autologin': {'passwordFile': 'password'}}
            _, old_password = host.guest_setup_password(access, fixture.state, baseline, configuration, exchange, None)
            host.atomic_json(fixture.state / 'baseline.json', baseline)
            record = dict(baseline)
            source.write_text('fixture promoted password\n')
            configuration['provisioningRequestID'] = '12345678-1234-1234-1234-123456789abc'
            directory, password = host.guest_setup_password(access, fixture.state, record, configuration, exchange, None)
            fixture.make_vm(fixture.candidate, b'verified-candidate')
            metadata = fixture.candidate.stat()
            record['promotionPending'] = {'backup': 'previous-baseline-' + 'a' * 32 + '.vbvm',
                                          'candidateFileID': [metadata.st_dev, metadata.st_ino]}
            host.atomic_json(fixture.state / 'candidate.json', record)
            rename = Path.rename
            def interrupt_after_move(path, destination):
                result = rename(path, destination)
                if path == fixture.candidate:
                    raise OSError('fixture promotion interrupted')
                return result
            with patch.object(Path, 'rename', interrupt_after_move):
                with self.assertRaisesRegex(OSError, 'promotion interrupted'):
                    host.finish_baseline_promotion(fixture.state, record)
            self.assertEqual(host.read_json(fixture.state / 'baseline.json'), baseline)
            pending = host.read_json(fixture.state / 'candidate.json')
            self.assertEqual(pending['guestAccessID'], configuration['provisioningRequestID'])
            host.finish_baseline_promotion(fixture.state, pending)
            promoted = host.read_json(fixture.state / 'baseline.json')
            self.assertEqual(promoted['guestAccessID'], configuration['provisioningRequestID'])
            self.assertEqual(host.guest_setup_password(access, fixture.state, promoted,
                {'consoleUser': promoted['consoleUser']}, exchange, None), (directory, password))
            self.assertEqual(access.read_private_password(password), b'fixture promoted password')
            self.assertEqual(access.read_private_password(old_password), b'fixture baseline password')

    def test_interrupted_promotion_resumes_without_retesting_or_losing_either_vm(self):
        phases = ('old-baseline-moved', 'candidate-moved', 'config-write', 'baseline-record', 'cleanup')
        for phase in phases:
            with self.subTest(phase=phase), SetupFixture(self, baseline=True) as fixture:
                rename = Path.rename
                write = host.atomic_json
                dump = host.plistlib.dump
                def rename_then_fail(path, destination):
                    result = rename(path, destination)
                    if phase == 'old-baseline-moved' and path == fixture.baseline or phase == 'candidate-moved' and path == fixture.candidate:
                        raise OSError('fixture: promotion interrupted')
                    return result
                def write_record(path, value):
                    if phase == 'baseline-record' and path == fixture.state / 'baseline.json':
                        raise OSError('fixture: promotion interrupted')
                    return write(path, value)
                def write_config(value, file, **kwargs):
                    if phase == 'config-write' and Path(file.name).parent == fixture.baseline / '.vbdata':
                        file.write(b'partial plist')
                        raise OSError('fixture: promotion interrupted')
                    return dump(value, file, **kwargs)
                with patch.object(Path, 'rename', rename_then_fail), patch.object(host, 'atomic_json', side_effect=write_record), \
                        patch.object(host.plistlib, 'dump', side_effect=write_config), contextlib.ExitStack() as stack:
                    if phase == 'cleanup':
                        stack.enter_context(patch.object(host, 'clear_applied_provisioning_packages', side_effect=OSError('fixture: promotion interrupted')))
                    with self.assertRaisesRegex(OSError, 'promotion interrupted'):
                        fixture.run()
                pending = host.read_json(fixture.state / 'candidate.json')
                backup = fixture.state / pending['promotionPending']['backup']
                with self.assertRaisesRegex(host.RunnerError, 'promotion is incomplete'):
                    host.run_tests(host.parser().parse_args(['run', 'all']), fixture.state, fixture.environment)
                self.assertEqual(fixture.run(), 0)
                self.assertEqual(fixture.launches, ['doctor', 'run'])
                self.assertEqual((backup / 'Disk.img').read_bytes(), b'old-baseline')
                self.assertEqual((fixture.baseline / 'Disk.img').read_bytes(), b'verified-candidate')
                self.assertEqual((fixture.original / 'Disk.img').read_bytes(), b'original')
                self.assertFalse((fixture.state / 'candidate.json').exists())
                self.assertFalse((fixture.state / 'active.json').exists())
                self.assertNotIn('promotionPending', host.read_json(fixture.state / 'baseline.json'))
                self.assertEqual(host.validate_vm(fixture.baseline)['sharedFolders'], [])

    def test_recovery_does_not_adopt_a_replaced_baseline(self):
        with SetupFixture(self) as fixture:
            write = host.atomic_json
            def interrupted_record(path, value):
                if path == fixture.state / 'baseline.json':
                    raise OSError('fixture: interrupted')
                return write(path, value)
            with patch.object(host, 'atomic_json', side_effect=interrupted_record), self.assertRaises(OSError):
                fixture.run()
            retained = fixture.state / 'retained.vbvm'
            fixture.baseline.rename(retained)
            fixture.make_vm(fixture.baseline, b'unowned-replacement')
            with self.assertRaisesRegex(host.RunnerError, 'no longer owns'):
                fixture.run()
            self.assertEqual((retained / 'Disk.img').read_bytes(), b'verified-candidate')
            self.assertEqual((fixture.baseline / 'Disk.img').read_bytes(), b'unowned-replacement')
            self.assertTrue((fixture.state / 'candidate.json').exists())


if __name__ == '__main__':
    unittest.main()
