import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import select
import shutil
import signal
import subprocess
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location('recovery_host', Path(__file__).resolve().parents[1] / 'host.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)
recovery = host.recovery_module()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_text(json.dumps(value) + '\n')
    path.chmod(0o600)


class RecoveryFixture:
    def setUp(self):
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.root = Path(self.stack.enter_context(tempfile.TemporaryDirectory())).resolve()
        self.state = self.root / 'state'
        self.state.mkdir(mode=0o700)
        self.run_id = 'run-fixture'
        self.vm_id = 'fixture-vm'
        self.original = self.state / 'results' / self.run_id
        self.original.mkdir(parents=True, mode=0o700)
        self.vm = self.state / 'runs' / (self.run_id + '.vbvm')
        (self.vm / '.vbdata').mkdir(parents=True, mode=0o700)
        for name in ('Disk.img', 'AuxiliaryStorage', 'HardwareModel', 'MachineIdentifier'):
            (self.vm / name).write_bytes(b'preserved VM fixture')
        configuration = {'systemType': 'mac', 'hardware': {'networkDevices': [{'macAddress': '02:00:00:00:00:01'}],
            '_storageDevices': [{'isBootVolume': True, 'backing': {'managedImage': {'_0': {'filename': 'Disk', 'format': 0}}}}]}}
        (self.vm / '.vbdata/Config.plist').write_bytes(plistlib.dumps(configuration))
        self.snapshot = b'{"files": []}\n'
        self.source_hash = hashlib.sha256(self.snapshot).hexdigest()
        (self.original / 'snapshot-manifest.json').write_bytes(self.snapshot)
        (self.original / 'snapshot-manifest.json').chmod(0o600)
        self.job = {'version': 1, 'runId': self.run_id, 'vmId': self.vm_id, 'kind': 'run',
                    'source': {'sha256': self.source_hash}}
        write_json(self.original / 'job.json', self.job)
        self.job_hash = hashlib.sha256((self.original / 'job.json').read_bytes()).hexdigest()
        self.host_report = {**self.job, 'status': 'blocked', 'finishedAt': 'host-finished',
                            'hostTermination': {'reason': 'host_disk_reserve_reached'},
                            'coverage': {'status': 'partial', 'fullSuiteVerified': False}}
        write_json(self.original / 'artifacts/result.json', self.host_report)
        write_json(self.original / 'artifacts/planned-result.json', {'original': 'plan'})
        write_json(self.original / 'guest-receipt.json', {'original': 'receipt'})
        write_json(self.original / 'stop.json', {'runId': self.run_id, 'requestCount': 1})
        (self.original / 'vm-stop').write_bytes(b'')
        (self.original / 'vm-stop').chmod(0o600)
        write_json(self.original / 'retained-vm.json', {'version': 1, 'runId': self.run_id,
                                                      'vm': str(self.vm), 'reason': 'artifacts_not_collected'})
        self.access_id = '00000000-0000-0000-0000-000000000001'
        write_json(self.state / 'baseline.json', {'vmId': self.vm_id, 'consoleUser': 'guest', 'guestAccessID': self.access_id})
        self.access_directory = self.state / 'guest-access' / self.vm_id / self.access_id
        self.access_directory.mkdir(parents=True, mode=0o700)
        write_json(self.access_directory / 'identity.json', {'vmId': self.vm_id, 'consoleUser': 'guest'})
        (self.access_directory / 'password').write_bytes(b'fixture private password\n')
        (self.access_directory / 'password').chmod(0o600)
        self.key = self.host_key(b'fixture')
        for name in ('known-hosts-first', 'known-hosts-second'):
            (self.access_directory / name).write_bytes(self.key)
            (self.access_directory / name).chmod(0o600)
        self.access_receipt = {'version': 1, 'runId': self.run_id, 'vmId': self.vm_id,
            'vm': str(self.vm), 'consoleUser': 'guest', 'guestAccessID': self.access_id,
            'knownHosts': 'known-hosts-first'}
        write_json(self.original / 'guest-access.json', self.access_receipt)
        self.idle = self.stack.enter_context(patch.object(host, 'ensure_disk_idle'))
        self.host_capacity = self.stack.enter_context(patch.object(host, 'check_capacity', return_value={
            'availableBytes': 100 * 1024 ** 3, 'freeBytes': 100 * 1024 ** 3, 'capacitySource': 'fixture'}))
        self.output = self.stack.enter_context(contextlib.redirect_stdout(io.StringIO()))

    def host_key(self, suffix):
        algorithm = b'ssh-ed25519'
        blob = len(algorithm).to_bytes(4, 'big') + algorithm + suffix
        return b'big-wallet-vm-' + self.vm_id.encode() + b' ssh-ed25519 ' + base64.b64encode(blob) + b'\n'

    def plan(self):
        return recovery.prepare_plan(host, self.state, self.run_id)

    def original_bytes(self):
        return {str(path.relative_to(self.original)): path.read_bytes() for path in self.original.rglob('*') if path.is_file()}

    def report(self, status='running'):
        value = {**self.job, 'status': status, 'stages': [{'id': 'safari.macos.release', 'status': 'failed'}]}
        if status != 'running':
            value['finishedAt'] = 'guest-finished'
        return (json.dumps(value) + '\n').encode()

    def archive(self, entries, *, report=None):
        report = self.report() if report is None else report
        all_entries = [('artifacts', b'', tarfile.DIRTYPE), ('artifacts/result.json', report, tarfile.REGTYPE), *entries]
        archive = self.root / ('export-' + str(len(list(self.root.glob('export-*')))) + '.tar')
        with tarfile.open(archive, 'w') as file:
            for name, value, kind in all_entries:
                member = tarfile.TarInfo(name)
                member.type = kind
                if kind == tarfile.REGTYPE:
                    member.size = len(value)
                    file.addfile(member, io.BytesIO(value))
                else:
                    if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                        member.linkname = value.decode()
                    file.addfile(member)
        archive.chmod(0o600)
        parsed = json.loads(report)
        total = sum(len(value) for _, value, kind in all_entries if kind == tarfile.REGTYPE)
        manifest = {'version': 1, 'runId': self.run_id, 'vmId': self.vm_id, 'jobSHA256': self.job_hash,
                    'sourceSHA256': self.source_hash, 'reportSHA256': hashlib.sha256(report).hexdigest(),
                    'reportStatus': parsed['status'], 'reportFinishedAt': parsed.get('finishedAt'),
                    'bytes': total, 'entries': len(all_entries), 'inventorySHA256': 'd' * 64,
                    'archiveMaximumBytes': total + len(all_entries) * 8192 + 10240}
        return archive, manifest

    def extract(self, archive, manifest):
        destination = Path(tempfile.mkdtemp(dir=self.root))
        value = recovery.extract_archive(archive, destination, manifest, 0)
        return destination, value


class RecoveryTests(RecoveryFixture, unittest.TestCase):
    @contextlib.contextmanager
    def recovery_cli(self):
        def admit(api, args, state):
            recovery.prepare_plan(api, state, args.run_id)
            return 0
        action = Mock(side_effect=admit)
        with patch.object(host.sys, 'platform', 'darwin'), \
                patch.object(host.os, 'uname', return_value=SimpleNamespace(machine='arm64')), \
                patch.object(host, 'recovery_module', return_value=SimpleNamespace(
                    recover=action, cleanup_scratch=recovery.cleanup_scratch)), \
                patch.object(host, 'run_tests', side_effect=AssertionError('Recovery must not run tests')), \
                contextlib.redirect_stderr(io.StringIO()):
            yield action

    def interrupted_recovery(self):
        recovery_id, attempt = host.new_exchange(self.state, 'recovery')
        write_json(attempt / 'artifacts/result.json', {'version': 1, 'runId': recovery_id,
            'kind': 'artifact-recovery', 'sourceRunId': self.run_id, 'status': 'running'})
        write_json(self.state / 'active.json', {'version': 1, 'runId': recovery_id,
            'vm': str(self.vm), 'exchange': str(attempt), 'ownerPID': 12345, 'phase': 'extraction'})
        return attempt

    def scratch(self, attempt):
        work = attempt / '.recovery-fixture'
        work.mkdir(mode=0o700)
        for name in ('worker.stderr', 'artifacts.tar'):
            (work / name).write_bytes(b'partial recovery fixture')
            (work / name).chmod(0o600)
        write_json(work / 'extracted/artifacts/result.json', {'partial': True})
        return work

    def test_cli_dispatches_recovery_without_reconciling_or_running_tests(self):
        action = Mock(return_value=0)
        with patch.object(host.sys, 'platform', 'darwin'), \
                patch.object(host.os, 'uname', return_value=SimpleNamespace(machine='arm64')), \
                patch.object(host, 'recovery_module', return_value=SimpleNamespace(recover=action)), \
                patch.object(host, 'reconcile_interrupted_operation', side_effect=AssertionError('Original run must not be reconciled')), \
                patch.object(host, 'run_tests', side_effect=AssertionError('Recovery must not run tests')):
            self.assertEqual(host.main(['--state-dir', str(self.state), 'recover-artifacts', self.run_id, '--timeout', '120']), 0)
        self.assertEqual(action.call_args.args[1].run_id, self.run_id)
        self.assertEqual(action.call_args.args[1].timeout, 120)

    def test_plan_uses_recorded_pins_and_preserves_original_records(self):
        before = self.original_bytes()
        with patch.object(recovery.access, 'prepare_guest_access', side_effect=AssertionError('No disk mount')), \
                patch.object(recovery.access, 'read_private_password', side_effect=AssertionError('Plan must not authenticate')):
            plan = self.plan()
        self.assertEqual(plan['access']['pins'], self.key)
        self.assertEqual(plan['macAddress'], '02:00:00:00:00:01')
        self.assertEqual(plan['originalStatus'], 'blocked')
        self.assertIn('guest-access.json', plan['protected'])
        self.assertEqual(self.original_bytes(), before)
        self.idle.assert_called_once_with(self.vm)

    def test_plan_rejects_other_active_operation_without_reconciliation(self):
        write_json(self.state / 'active.json', {'ownerPID': 123, 'runId': 'other-run'})
        before = self.original_bytes()
        with self.assertRaisesRegex(recovery.RecoveryError, 'ownership record'):
            self.plan()
        self.assertEqual(self.original_bytes(), before)
        self.idle.assert_not_called()

    def test_plan_rejects_paths_outside_the_exact_retained_clone(self):
        for run_id in ('../run-fixture', 'run-../fixture', '/run-fixture', 'setup-fixture'):
            with self.subTest(run_id=run_id), self.assertRaises(recovery.RecoveryError):
                recovery.prepare_plan(host, self.state, run_id)
        write_json(self.original / 'retained-vm.json', {'version': 1, 'runId': self.run_id,
            'vm': str(self.state / 'baseline.vbvm'), 'reason': 'artifacts_not_collected'})
        with self.assertRaisesRegex(recovery.RecoveryError, 'owned clone'):
            self.plan()

    def test_plan_rejects_symlinked_original_metadata(self):
        path = self.original / 'job.json'
        path.rename(self.root / 'other-job.json')
        path.symlink_to(self.root / 'other-job.json')
        with self.assertRaisesRegex(recovery.access.GuestAccessError, 'symlink'):
            self.plan()

    def test_plan_rejects_changed_source(self):
        (self.original / 'snapshot-manifest.json').write_bytes(b'changed')
        with self.assertRaisesRegex(recovery.RecoveryError, 'source manifest'):
            self.plan()

    def test_plan_ignores_pins_that_were_not_selected_for_the_original_run(self):
        (self.access_directory / 'known-hosts-second').write_bytes(self.host_key(b'different'))
        (self.access_directory / 'known-hosts-unrelated').symlink_to(self.root / 'absent')
        self.assertEqual(self.plan()['access']['pins'], self.key)

    def test_reprovisioning_keeps_the_original_run_credential_scope(self):
        before = self.original_bytes()
        candidate = host.read_json(self.state / 'baseline.json')
        setup = self.state / 'setup' / 'setup-fixture'
        (setup / 'provision').mkdir(parents=True, mode=0o700)
        staged = setup / 'provision' / 'password'
        staged.write_bytes((self.access_directory / 'password').read_bytes())
        staged.chmod(0o600)
        configuration = {'consoleUser': 'guest', 'provisioningRequestID': '00000000-0000-0000-0000-000000000002',
                         'autologin': {'passwordFile': 'password'}}
        directory, _ = host.guest_setup_password(recovery.access, self.state, candidate, configuration, setup, None)
        write_json(self.state / 'candidate.json', candidate)
        self.assertNotEqual(directory, self.access_directory)
        for records in ('candidate', 'promoted', 'removed'):
            with self.subTest(records=records):
                if records == 'promoted':
                    write_json(self.state / 'baseline.json', candidate)
                    (self.state / 'candidate.json').unlink()
                elif records == 'removed':
                    (self.state / 'baseline.json').unlink()
                selected = self.plan()['access']
                self.assertEqual(selected['password'], self.access_directory / 'password')
                self.assertEqual(selected['pins'], self.key)
                self.assertEqual(self.original_bytes(), before)

    def test_prepared_hook_records_the_exact_run_access_scope(self):
        (self.original / 'guest-access.json').unlink()
        module = SimpleNamespace(GuestAccessError=recovery.access.GuestAccessError,
            read_private_password=recovery.access.read_private_password,
            prepare_guest_access=Mock(return_value={'knownHosts': self.access_directory / 'known-hosts-first'}))
        with patch.object(host, 'guest_access_module', return_value=module):
            host.prepared_guest_hook(self.state, self.vm, host.read_json(self.state / 'baseline.json'), self.original)
        self.assertEqual(host.read_json(self.original / 'guest-access.json'), self.access_receipt)
        module.prepare_guest_access.assert_called_once_with(self.vm, self.access_directory, self.vm_id, 'guest')

    def test_plan_requires_a_receipt_matching_the_original_run(self):
        path = self.original / 'guest-access.json'
        path.unlink()
        with self.assertRaises(OSError):
            self.plan()
        for key, value in [('version', 2), ('runId', 'run-other'), ('vmId', 'other-vm'),
                           ('vm', str(self.state / 'baseline.vbvm'))]:
            with self.subTest(key=key):
                write_json(path, {**self.access_receipt, key: value})
                with self.assertRaisesRegex(recovery.RecoveryError, 'receipt does not match'):
                    self.plan()

    def test_plan_rejects_mismatched_credential_identity(self):
        write_json(self.access_directory / 'identity.json', {'vmId': self.vm_id, 'consoleUser': 'other'})
        with self.assertRaisesRegex(recovery.RecoveryError, 'another VM or account'):
            self.plan()

    def test_plan_rejects_missing_malformed_and_external_pin_paths(self):
        receipt = self.original / 'guest-access.json'
        for name in (None, '', '../known-hosts-first', 'known-hosts-first/extra', str(self.access_directory / 'known-hosts-first')):
            with self.subTest(name=name):
                write_json(receipt, {**self.access_receipt, 'knownHosts': name})
                with self.assertRaisesRegex(recovery.RecoveryError, 'identity is invalid'):
                    self.plan()
        write_json(receipt, self.access_receipt)
        selected = self.access_directory / 'known-hosts-first'
        selected.unlink()
        with self.assertRaises(OSError):
            self.plan()
        selected.symlink_to(self.access_directory / 'known-hosts-second')
        with self.assertRaisesRegex(recovery.access.GuestAccessError, 'symlink'):
            self.plan()
        selected.unlink()
        for contents in (b'', b'another-vm ssh-ed25519 invalid\n', b'big-wallet-vm-fixture ssh-ed25519 invalid\n'):
            with self.subTest(contents=contents):
                selected.write_bytes(contents)
                selected.chmod(0o600)
                with self.assertRaises((recovery.RecoveryError, recovery.access.GuestAccessError)):
                    self.plan()

    def test_original_metadata_changes_are_detected_without_restoring_or_rewriting(self):
        for name in ('artifacts/result.json', 'guest-access.json'):
            with self.subTest(name=name):
                plan = self.plan()
                path = self.original / name
                before = path.read_bytes()
                path.write_bytes(b'changed externally')
                with self.assertRaisesRegex(recovery.RecoveryError, 'Original run metadata changed'):
                    recovery.assert_original_unchanged(plan)
                self.assertEqual(path.read_bytes(), b'changed externally')
                path.write_bytes(before)

    def test_capacity_requires_real_free_archive_and_extraction_bytes_plus_reserve(self):
        with patch.object(recovery.shutil, 'disk_usage', return_value=SimpleNamespace(free=199)):
            with self.assertRaises(recovery.RecoveryError):
                recovery.check_capacity(self.root, 100, 100)
        with patch.object(recovery.shutil, 'disk_usage', return_value=SimpleNamespace(free=200)):
            recovery.check_capacity(self.root, 100, 100)

    def test_nonfinal_guest_report_is_collected_as_raw_partial_diagnostics(self):
        before = self.original_bytes()
        archive, manifest = self.archive([('artifacts/safari.log', b'existing diagnostic', tarfile.REGTYPE)])
        recovery.validate_manifest(manifest, self.plan())
        destination, result = self.extract(archive, manifest)
        self.assertEqual((destination / 'artifacts/result.json').read_bytes(), self.report())
        self.assertEqual((result['guestReportStatus'], result['guestReportComplete']), ('running', False))
        self.assertEqual(self.original_bytes(), before)

    def test_complete_guest_report_never_replaces_the_original_host_interruption(self):
        before = self.original_bytes()
        archive, manifest = self.archive([], report=self.report('passed'))
        destination, result = self.extract(archive, manifest)
        self.assertEqual((result['guestReportStatus'], result['guestReportComplete']), ('passed', True))
        self.assertEqual(self.original_bytes(), before)
        self.assertNotIn('hostTermination', json.loads((destination / 'artifacts/result.json').read_bytes()))

    def test_unsafe_links_paths_duplicates_and_special_files_are_rejected(self):
        for entry in [('../outside', b'x', tarfile.REGTYPE), ('artifacts/link', b'../outside', tarfile.SYMTYPE),
                      ('artifacts/link', b'artifacts/result.json', tarfile.LNKTYPE), ('artifacts/pipe', b'', tarfile.FIFOTYPE),
                      ('artifacts/result.json', b'duplicate', tarfile.REGTYPE), ('source/private', b'other', tarfile.REGTYPE)]:
            with self.subTest(entry=entry):
                archive, manifest = self.archive([entry])
                with self.assertRaises(recovery.RecoveryError):
                    self.extract(archive, manifest)

    def test_truncation_inventory_mismatch_and_report_replacement_are_rejected(self):
        archive, manifest = self.archive([])
        archive.write_bytes(archive.read_bytes()[:-1])
        with self.assertRaisesRegex(recovery.RecoveryError, 'truncated'):
            self.extract(archive, manifest)
        archive, manifest = self.archive([])
        manifest['bytes'] += 1
        with self.assertRaisesRegex(recovery.RecoveryError, 'complete admitted inventory'):
            self.extract(archive, manifest)
        archive, manifest = self.archive([])
        manifest['reportSHA256'] = 'b' * 64
        with self.assertRaisesRegex(recovery.RecoveryError, 'differs from its admitted identity'):
            self.extract(archive, manifest)

    def test_recovery_does_not_relax_normal_terminal_export_validation(self):
        archive, manifest = self.archive([])
        destination = Path(tempfile.mkdtemp(dir=self.root))
        with self.assertRaisesRegex(recovery.exchange.GuestExchangeError, 'not complete'):
            recovery.exchange.extract_export(archive, destination, self.run_id, self.vm_id)

    def test_transport_only_uses_readiness_inspection_and_export(self):
        plan = self.plan()
        _, attempt = host.new_exchange(self.state, 'recovery')
        vm = Mock()
        vm.poll.return_value = None
        session = recovery.RecoverySession(host, plan, attempt, vm, float('inf'), lambda: False, 0)
        self.addCleanup(session.close)
        self.assertNotIn('HOME', session.environment)
        archive, manifest = self.archive([])
        scripts = []
        def remote(script, arguments, **options):
            scripts.append(script)
            if script == recovery.exchange._READY:
                return {'version': 1, 'runId': self.run_id, 'vmId': self.vm_id, 'ready': True}
            if script == recovery.REMOTE_MANIFEST:
                return manifest
            self.assertEqual(script, recovery.REMOTE_EXPORT)
            self.assertEqual(options['pending_bytes'](0), manifest['archiveMaximumBytes'] + manifest['bytes'])
            options['output_path'].write_bytes(archive.read_bytes())
            options['output_path'].chmod(0o600)
        def extract(command, **options):
            self.assertEqual(command[3], '--extract')
            return recovery.extract_archive(Path(command[4]), Path(command[5]), manifest, 0)
        with patch.object(session, 'connect'), patch.object(session, 'remote', side_effect=remote), \
                patch.object(session, 'command_output', side_effect=extract):
            session.collect(Mock())
        self.assertEqual(scripts, [recovery.exchange._READY, recovery.REMOTE_MANIFEST, recovery.REMOTE_EXPORT])
        self.host_capacity.assert_called_once_with(attempt, manifest['archiveMaximumBytes'] + manifest['bytes'])
        self.assertEqual((attempt / 'recovered/artifacts/result.json').read_bytes(), self.report())
        self.assertEqual(json.loads((self.original / 'artifacts/result.json').read_bytes()), self.host_report)

    def test_transfer_failure_redacts_existing_password_and_stops_only_its_child(self):
        plan = self.plan()
        _, attempt = host.new_exchange(self.state, 'recovery')
        vm = Mock()
        vm.poll.return_value = None
        session = recovery.RecoverySession(host, plan, attempt, vm, float('inf'), lambda: False, 0)
        self.addCleanup(session.close)
        session.password = b'fixture private password'
        child = Mock()
        child.poll.return_value = 1
        def launch(command, **options):
            self.assertIs(options['stderr'], session.errors)
            options['stderr'].write(b'failure with fixture private password')
            options['stderr'].flush()
            return child
        with patch.object(recovery.subprocess, 'Popen', side_effect=launch):
            with self.assertRaisesRegex(recovery.RecoveryError, r'failure with \[REDACTED\]'):
                session.command_output(['fixture-only'], timeout=1)
        child.wait.assert_called()
        vm.terminate.assert_not_called()
        self.assertEqual(json.loads((self.original / 'artifacts/result.json').read_bytes()), self.host_report)

    def test_cancelled_transfer_never_starts_a_remote_command(self):
        plan = self.plan()
        _, attempt = host.new_exchange(self.state, 'recovery')
        vm = Mock()
        session = recovery.RecoverySession(host, plan, attempt, vm, float('inf'), lambda: True, 0)
        self.addCleanup(session.close)
        with patch.object(recovery.subprocess, 'Popen', side_effect=AssertionError('No transfer after cancellation')):
            with self.assertRaises(InterruptedError):
                session.command_output(['fixture-only'], timeout=1)

    def run_recovery(self, *, failure=None, shutdown_error=None, close_error=None):
        args = host.parser().parse_args(['recover-artifacts', self.run_id])
        vm = Mock()
        vm.poll.return_value = None
        events = []
        outer = self
        class Session:
            password = b''
            def __init__(self, api, plan, attempt, process, deadline, cancelled, reserve):
                outer.assertEqual(process, vm)
                self.attempt = attempt
                if close_error:
                    outer.scratch(attempt)
            def collect(self, phase):
                phase('inspection')
                events.append('collect-existing-artifacts')
                if failure:
                    raise failure
                write_json(self.attempt / 'recovered/artifacts/result.json', json.loads(outer.report()))
                return {'guestReportStatus': 'running', 'guestReportComplete': False}
            def close(self):
                events.append('close-transport')
                if close_error:
                    raise close_error
        def stop(process, path):
            self.assertEqual(process, vm)
            self.assertNotEqual(path, self.original / 'vm-stop')
            events.append('stop-recovery-vm')
            if shutdown_error:
                raise shutdown_error
            vm.poll.return_value = 0
        with patch.object(host, 'build_tools', return_value=self.root / 'tools'), \
                patch.object(recovery, 'check_capacity'), patch.object(recovery, 'RecoverySession', Session), \
                patch.object(recovery.subprocess, 'Popen', return_value=vm) as launch, \
                patch.object(host, 'stop_owned_process', side_effect=stop):
            code = recovery.recover(host, args, self.state)
        command = launch.call_args.args[0]
        self.assertEqual(command[:3], [str(self.root / 'tools/VMHost'), '--vm', str(self.vm)])
        self.assertNotIn('--provision-user', command)
        self.assertNotIn('--setup-window', command)
        result_file = next((self.state / 'results').glob('recovery-*/artifacts/result.json'))
        return code, json.loads(result_file.read_bytes()), events

    def test_orchestration_retains_vm_and_original_failure_after_successful_collection(self):
        before = self.original_bytes()
        code, result, events = self.run_recovery()
        self.assertEqual(code, 0)
        self.assertEqual((result['status'], result['originalRunStatus'], result['testsExecuted']), ('passed', 'blocked', False))
        self.assertEqual(result['coverage'], {'status': 'partial', 'fullSuiteVerified': False})
        self.assertTrue(result['vmRetained'])
        self.assertTrue(self.vm.exists())
        self.assertFalse((self.state / 'active.json').exists())
        self.assertEqual(self.original_bytes(), before)
        self.assertEqual(events, ['collect-existing-artifacts', 'close-transport', 'stop-recovery-vm'])

    def test_cancelled_collection_preserves_original_report_stop_files_and_vm(self):
        before = self.original_bytes()
        code, result, events = self.run_recovery(failure=InterruptedError('cancelled fixture'))
        self.assertEqual((code, result['status']), (1, 'cancelled'))
        self.assertFalse(result['coverage']['fullSuiteVerified'])
        self.assertEqual(self.original_bytes(), before)
        self.assertTrue(self.vm.exists())
        self.assertEqual(events[-2:], ['close-transport', 'stop-recovery-vm'])

    def test_host_capacity_error_finishes_failed_without_changing_original_run(self):
        before = self.original_bytes()
        code, result, events = self.run_recovery(failure=host.RunnerError('fixture host reserve reached during collection'))
        self.assertEqual((code, result['status']), (1, 'failed'))
        self.assertEqual(result['error'], 'fixture host reserve reached during collection')
        self.assertTrue(result['finishedAt'])
        self.assertFalse(result['coverage']['fullSuiteVerified'])
        self.assertEqual(self.original_bytes(), before)
        self.assertEqual(events[-2:], ['close-transport', 'stop-recovery-vm'])

    def test_guest_access_error_finishes_failed_without_changing_original_run(self):
        before = self.original_bytes()
        code, result, events = self.run_recovery(failure=recovery.access.GuestAccessError('fixture pinned host key changed'))
        self.assertEqual((code, result['status']), (1, 'failed'))
        self.assertEqual(result['error'], 'fixture pinned host key changed')
        self.assertTrue(result['finishedAt'])
        self.assertEqual(self.original_bytes(), before)
        self.assertEqual(events[-2:], ['close-transport', 'stop-recovery-vm'])

    def test_status_stop_and_recovery_retry_reconcile_without_touching_original(self):
        before = self.original_bytes()
        recovery_id, attempt = host.new_exchange(self.state, 'recovery')
        write_json(attempt / 'artifacts/result.json', {'version': 1, 'runId': recovery_id,
            'kind': 'artifact-recovery', 'sourceRunId': self.run_id, 'status': 'running',
            'coverage': {'status': 'partial', 'fullSuiteVerified': False}})
        host.register_operation(self.state, self.vm, attempt, recovery_id, 'export')
        active = host.read_json(self.state / 'active.json')
        active.update(ownerPID=12345, kind='artifact-recovery', sourceRunId=self.run_id)
        write_json(self.state / 'active.json', active)
        with self.recovery_cli() as recover:
            self.assertEqual(host.main(['--state-dir', str(self.state), 'status']), 0)
            self.assertEqual(host.main(['--state-dir', str(self.state), 'stop']), 0)
            recover.assert_not_called()
            self.assertEqual(self.original_bytes(), before)
            self.assertEqual(host.main(['--state-dir', str(self.state), 'recover-artifacts', self.run_id]), 0)
            recover.assert_called_once()
        result = host.read_json(attempt / 'artifacts/result.json')
        self.assertEqual(result['hostTermination']['reason'], 'host_runner_interrupted')
        self.assertEqual(result['status'], 'blocked')
        self.assertFalse(result['coverage']['fullSuiteVerified'])
        self.assertFalse((attempt / 'artifacts/planned-result.json').exists())
        self.assertTrue((attempt / 'artifacts/guest-result-interrupted.json').exists())
        self.assertEqual(self.original_bytes(), before)
        self.assertTrue(self.vm.exists())
        self.assertFalse((self.state / 'active.json').exists())

    def test_recovery_retry_reconciles_a_crash_before_kind_or_report_was_written(self):
        before = self.original_bytes()
        recovery_id, attempt = host.new_exchange(self.state, 'recovery')
        host.register_operation(self.state, self.vm, attempt, recovery_id, 'export')
        active = host.read_json(self.state / 'active.json')
        active['ownerPID'] = 12345
        write_json(self.state / 'active.json', active)
        with self.recovery_cli() as recover:
            self.assertEqual(host.main(['--state-dir', str(self.state), 'recover-artifacts', self.run_id]), 0)
            recover.assert_called_once()
        result = host.read_json(attempt / 'artifacts/result.json')
        self.assertEqual(result['hostTermination']['reason'], 'host_runner_interrupted')
        self.assertFalse(result['coverage']['fullSuiteVerified'])
        self.assertEqual(self.original_bytes(), before)
        self.assertTrue(self.vm.exists())
        self.assertFalse((self.state / 'active.json').exists())

    def test_recovery_cli_preserves_unrelated_original_and_clone_owned_operations(self):
        before = self.original_bytes()
        cases = [
            {'runId': self.run_id, 'exchange': str(self.original)},
            {'runId': 'setup-other', 'exchange': str(self.state / 'setup' / 'setup-other')},
            {'runId': 'recovery-other', 'exchange': str(self.original)},
            {'runId': 'recovery-other', 'exchange': str(self.state / 'results' / 'recovery-other'), 'cloneOwned': True},
        ]
        for ownership in cases:
            with self.subTest(ownership=ownership):
                active = {'version': 1, 'ownerPID': 12345, 'vm': str(self.vm), **ownership}
                write_json(self.state / 'active.json', active)
                with self.recovery_cli() as recover, patch.object(host, 'reconcile_interrupted_operation',
                        side_effect=AssertionError('Only stale recovery ownership may be reconciled')):
                    self.assertEqual(host.main(['--state-dir', str(self.state), 'recover-artifacts', self.run_id]), 2)
                    recover.assert_called_once()
                self.assertEqual(host.read_json(self.state / 'active.json'), active)
                self.assertEqual(self.original_bytes(), before)
        self.idle.assert_not_called()

    def test_recovery_retry_does_not_reconcile_an_operation_holding_the_lock(self):
        before = self.original_bytes()
        recovery_id, attempt = host.new_exchange(self.state, 'recovery')
        host.register_operation(self.state, self.vm, attempt, recovery_id, 'export')
        active = (self.state / 'active.json').read_bytes()
        with host.execution_lock(self.state), self.recovery_cli() as recover, \
                patch.object(host, 'reconcile_interrupted_operation', side_effect=AssertionError('The collector is live')):
            self.assertEqual(host.main(['--state-dir', str(self.state), 'recover-artifacts', self.run_id]), 2)
            recover.assert_not_called()
        self.assertEqual((self.state / 'active.json').read_bytes(), active)
        self.assertFalse((attempt / 'stop.json').exists())
        self.assertEqual(self.original_bytes(), before)
        self.idle.assert_not_called()

    def test_retry_removes_stale_scratch_before_capacity_admission(self):
        before = self.original_bytes()
        vm_files = {path: path.read_bytes() for path in self.vm.rglob('*') if path.is_file()}
        attempt = self.interrupted_recovery()
        report = host.read_json(attempt / 'artifacts/result.json')
        work = self.scratch(attempt)
        empty = attempt / '.recovery-preinit'
        empty.mkdir(mode=0o700)
        preserved = ['recovered/artifacts/result.json', 'collection-manifest.json', 'unrelated/notes.json']
        for name in preserved:
            write_json(attempt / name, {'preserved': name})
        contents = {name: (attempt / name).read_bytes() for name in preserved}
        def capacity(*args):
            self.assertFalse(work.exists())
            self.assertFalse(empty.exists())
            self.idle.assert_called_with(self.vm)
            raise host.RunnerError('fixture capacity admission')
        with self.recovery_cli() as collect, \
                patch.object(host, 'build_tools', side_effect=AssertionError('No build after admission refusal')):
            collect.side_effect = recovery.recover
            self.host_capacity.side_effect = capacity
            self.assertEqual(host.main(['--state-dir', str(self.state), 'recover-artifacts', self.run_id]), 2)
            collect.assert_called_once()
        self.host_capacity.assert_called_once()
        self.assertFalse((self.state / 'active.json').exists())
        self.assertEqual(host.read_json(attempt / 'artifacts/guest-result-interrupted.json'), report)
        self.assertTrue((attempt / 'artifacts/result.json').exists())
        self.assertEqual({name: (attempt / name).read_bytes() for name in preserved}, contents)
        self.assertEqual(self.original_bytes(), before)
        self.assertEqual({path: path.read_bytes() for path in self.vm.rglob('*') if path.is_file()}, vm_files)

    def test_interrupted_payload_deletion_retains_the_lease_for_retry(self):
        before = self.original_bytes()
        attempt = self.interrupted_recovery()
        work = self.scratch(attempt)
        write_json(work / 'extracted/artifacts/remaining.json', {'partial': True})
        published = attempt / 'recovered/artifacts/result.json'
        write_json(published, {'published': True})
        published_bytes = published.read_bytes()
        active = (self.state / 'active.json').read_bytes()
        report = (attempt / 'artifacts/result.json').read_bytes()
        unlink = os.unlink
        def interrupt_after_unlink(path, *args, **kwargs):
            unlink(path, *args, **kwargs)
            if Path(path).name == 'result.json':
                raise OSError('fixture interrupted payload deletion')
        with self.recovery_cli() as collect, \
                patch.object(recovery.os, 'unlink', side_effect=interrupt_after_unlink), \
                patch.object(recovery.shutil, 'rmtree', wraps=shutil.rmtree) as remove:
            self.assertEqual(host.main(['--state-dir', str(self.state), 'recover-artifacts', self.run_id]), 2)
            collect.assert_not_called()
        removed_roots = [Path(call.args[0]) for call in remove.call_args_list]
        self.assertIn(work / 'extracted', removed_roots)
        self.assertNotIn(work, removed_roots)
        self.assertFalse((work / 'extracted/artifacts/result.json').exists())
        self.assertTrue((work / 'extracted').exists())
        self.assertTrue((work / 'worker.stderr').is_file())
        self.assertEqual((self.state / 'active.json').read_bytes(), active)
        self.assertEqual((attempt / 'artifacts/result.json').read_bytes(), report)
        self.assertEqual(published.read_bytes(), published_bytes)
        self.assertEqual(self.original_bytes(), before)
        with self.recovery_cli() as collect:
            self.assertEqual(host.main(['--state-dir', str(self.state), 'recover-artifacts', self.run_id]), 0)
            collect.assert_called_once()
        self.assertFalse(work.exists())
        self.assertFalse((self.state / 'active.json').exists())
        self.assertEqual(host.read_json(attempt / 'artifacts/guest-result-interrupted.json'), json.loads(report))
        self.assertEqual(published.read_bytes(), published_bytes)
        self.assertEqual(self.original_bytes(), before)
        self.assertTrue(self.vm.exists())

    def test_unsafe_scratch_preserves_ownership_and_metadata(self):
        before = self.original_bytes()
        for invalid in ('missing-lock', 'public-lock', 'hardlinked-lock', 'symlink-lock', 'directory-lock',
                        'symlink-scratch', 'public-scratch', 'unexpected-file'):
            with self.subTest(invalid=invalid):
                attempt = self.interrupted_recovery()
                work = self.scratch(attempt)
                lock = work / 'worker.stderr'
                if invalid == 'missing-lock':
                    lock.unlink()
                elif invalid == 'public-lock':
                    lock.chmod(0o644)
                elif invalid == 'hardlinked-lock':
                    os.link(lock, attempt / 'saved-lock')
                elif invalid == 'symlink-lock':
                    lock.unlink()
                    lock.symlink_to(work / 'artifacts.tar')
                elif invalid == 'directory-lock':
                    lock.unlink()
                    lock.mkdir(mode=0o700)
                elif invalid == 'symlink-scratch':
                    work.rename(attempt / 'unrelated')
                    work.symlink_to(attempt / 'unrelated')
                elif invalid == 'public-scratch':
                    work.chmod(0o755)
                else:
                    (work / 'unowned').write_bytes(b'preserve this file')
                active = (self.state / 'active.json').read_bytes()
                report = (attempt / 'artifacts/result.json').read_bytes()
                with self.recovery_cli() as collect:
                    self.assertEqual(host.main(['--state-dir', str(self.state), 'recover-artifacts', self.run_id]), 2)
                    collect.assert_not_called()
                self.assertEqual((self.state / 'active.json').read_bytes(), active)
                self.assertEqual((attempt / 'artifacts/result.json').read_bytes(), report)
                self.assertFalse((attempt / 'stop.json').exists())
                self.assertFalse((attempt / 'vm-stop').exists())
                self.assertTrue(work.exists())
                self.assertEqual(self.original_bytes(), before)
                self.assertTrue(self.vm.exists())

    def test_worker_stderr_keeps_scratch_locked_after_owner_descriptor_closes(self):
        plan = self.plan()
        attempt = self.interrupted_recovery()
        session = recovery.RecoverySession(host, plan, attempt, Mock(), float('inf'), lambda: False, 0)
        self.addCleanup(session.close)
        worker = subprocess.Popen([recovery.sys.executable, '-B', '-c',
            "import os; os.closerange(3, 65536); os.write(1, b'ready\\n'); os.read(0, 1)"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=session.errors)
        def close_worker():
            if worker.poll() is None:
                worker.kill()
            worker.communicate(timeout=5)
        self.addCleanup(close_worker)
        self.assertTrue(select.select([worker.stdout], [], [], 5)[0], 'Fixture worker did not become ready')
        self.assertEqual(worker.stdout.readline(), b'ready\n')
        session.errors.close()
        active = (self.state / 'active.json').read_bytes()
        report = (attempt / 'artifacts/result.json').read_bytes()
        with self.assertRaisesRegex(recovery.RecoveryError, 'still in use'):
            recovery.cleanup_scratch(attempt)
        with self.recovery_cli() as collect:
            self.assertEqual(host.main(['--state-dir', str(self.state), 'recover-artifacts', self.run_id]), 2)
            collect.assert_not_called()
        self.assertEqual((self.state / 'active.json').read_bytes(), active)
        self.assertEqual((attempt / 'artifacts/result.json').read_bytes(), report)
        self.assertTrue(session.work.exists())
        worker.communicate(input=b'x', timeout=5)
        self.assertEqual(worker.returncode, 0)
        with self.recovery_cli() as collect:
            self.assertEqual(host.main(['--state-dir', str(self.state), 'recover-artifacts', self.run_id]), 0)
            collect.assert_called_once()
        self.assertFalse(session.work.exists())
        self.assertFalse((self.state / 'active.json').exists())

    def test_killed_owner_after_output_creation_leaves_reclaimable_scratch(self):
        before = self.original_bytes()
        plan = self.plan()
        attempt = self.interrupted_recovery()
        published = attempt / 'recovered/artifacts/result.json'
        write_json(published, {'published': True})
        published_bytes = published.read_bytes()
        active = (self.state / 'active.json').read_bytes()
        report = (attempt / 'artifacts/result.json').read_bytes()
        script = r'''
import base64
import importlib.util
import os
from pathlib import Path
import sys
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location('recovery_fixture', sys.argv[1])
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)
plan = {'access': {'pins': base64.b64decode(sys.argv[3]), 'password': Path(sys.argv[4])}}
session = recovery.RecoverySession(None, plan, Path(sys.argv[2]), SimpleNamespace(poll=lambda: None),
                                   float('inf'), lambda: False, 0)
original_open = os.open
def suspend_after_output_creation(path, flags, *args, **kwargs):
    descriptor = original_open(path, flags, *args, **kwargs)
    if Path(path).parent == session.work and flags & os.O_CREAT:
        os.write(1, b'ready\n')
        os.read(0, 1)
    return descriptor
os.open = suspend_after_output_creation
session.command_output([sys.executable, '-B', '-c', 'print("{}")'], timeout=5)
'''
        worker = subprocess.Popen([recovery.sys.executable, '-B', '-c', script, str(Path(recovery.__file__).resolve()),
            str(attempt), base64.b64encode(plan['access']['pins']).decode(), str(plan['access']['password'])],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        def close_worker():
            if worker.poll() is None:
                worker.kill()
            worker.communicate(timeout=5)
        self.addCleanup(close_worker)
        self.assertTrue(select.select([worker.stdout], [], [], 5)[0], 'Fixture owner did not create its output')
        self.assertEqual(worker.stdout.readline(), b'ready\n')
        work, = attempt.glob('.recovery-*')
        with self.assertRaisesRegex(recovery.RecoveryError, 'still in use'):
            recovery.cleanup_scratch(attempt)
        with self.recovery_cli() as collect:
            self.assertEqual(host.main(['--state-dir', str(self.state), 'recover-artifacts', self.run_id]), 2)
            collect.assert_not_called()
        self.assertEqual((self.state / 'active.json').read_bytes(), active)
        self.assertEqual((attempt / 'artifacts/result.json').read_bytes(), report)
        self.assertEqual(published.read_bytes(), published_bytes)
        self.assertEqual(self.original_bytes(), before)
        self.assertTrue(work.exists())
        worker.kill()
        worker.communicate(timeout=5)
        self.assertEqual(worker.returncode, -signal.SIGKILL)
        with self.recovery_cli() as collect:
            self.assertEqual(host.main(['--state-dir', str(self.state), 'recover-artifacts', self.run_id]), 0)
            collect.assert_called_once()
        self.assertFalse(work.exists())
        self.assertFalse((self.state / 'active.json').exists())
        self.assertEqual(host.read_json(attempt / 'artifacts/guest-result-interrupted.json'), json.loads(report))
        self.assertEqual(published.read_bytes(), published_bytes)
        self.assertEqual(self.original_bytes(), before)
        self.assertTrue(self.vm.exists())

    def test_session_close_releases_its_lock_and_removes_scratch(self):
        before = self.original_bytes()
        _, attempt = host.new_exchange(self.state, 'recovery')
        vm = Mock()
        vm.poll.return_value = None
        session = recovery.RecoverySession(host, self.plan(), attempt, vm, float('inf'), lambda: False, 0)
        self.addCleanup(session.close)
        value = session.command_output([recovery.sys.executable, '-B', '-c', 'print("{\\"fixture\\": true}")'], timeout=5)
        self.assertEqual(value, {'fixture': True})
        value = session.command_output([recovery.sys.executable, '-B', '-c', 'print("{}")'], timeout=5)
        self.assertEqual(value, {})
        with self.assertRaisesRegex(recovery.RecoveryError, 'still in use'):
            recovery.cleanup_scratch(attempt)
        session.close()
        self.assertTrue(session.errors.closed)
        self.assertFalse(session.work.exists())
        self.assertEqual(self.original_bytes(), before)

    def test_failed_scratch_cleanup_keeps_ownership_after_vm_shutdown(self):
        before = self.original_bytes()
        code, result, events = self.run_recovery(close_error=OSError('fixture cleanup failed'))
        self.assertEqual((code, result['status']), (1, 'failed'))
        self.assertEqual(result['cleanupError'], 'fixture cleanup failed')
        active = host.read_json(self.state / 'active.json')
        attempt = Path(active['exchange'])
        self.assertEqual(active['kind'], 'artifact-recovery')
        self.assertTrue((attempt / '.recovery-fixture/artifacts.tar').exists())
        self.assertTrue((attempt / 'recovered/artifacts/result.json').exists())
        self.assertEqual(events[-2:], ['close-transport', 'stop-recovery-vm'])
        self.assertEqual(self.original_bytes(), before)
        self.assertTrue(self.vm.exists())

    def test_failed_shutdown_keeps_recovery_ownership_without_claiming_collection_success(self):
        before = self.original_bytes()
        code, result, _ = self.run_recovery(shutdown_error=OSError('fixture shutdown failed'))
        self.assertEqual((code, result['status']), (1, 'failed'))
        active = json.loads((self.state / 'active.json').read_bytes())
        self.assertEqual((active['kind'], active['sourceRunId']), ('artifact-recovery', self.run_id))
        self.assertNotIn('cloneOwned', active)
        self.assertEqual(self.original_bytes(), before)
        self.assertTrue(self.vm.exists())


class RemoteRecoveryTests(RecoveryFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.node = shutil.which('node')
        if self.node is None:
            self.skipTest('Pure recovery script fixtures require Node.js')
        self.guest_root = self.root / 'guest'
        self.guest = self.guest_root / 'Exchange'
        (self.guest / 'artifacts').mkdir(parents=True, mode=0o700)
        self.guest.chmod(0o700)
        for name in ('job.json', 'snapshot-manifest.json'):
            (self.guest / name).write_bytes((self.original / name).read_bytes())
            (self.guest / name).chmod(0o600)
        (self.guest / 'artifacts/result.json').write_bytes(self.report())
        (self.guest / 'artifacts/result.json').chmod(0o600)
        (self.guest / 'artifacts/safari.log').write_bytes(b'original safari failure log')
        (self.guest / 'artifacts/safari.log').chmod(0o600)
        self.receipt = {'version': 1, 'runId': self.run_id, 'vmId': self.vm_id, 'state': 'running',
                        'agentPID': 1001, 'agentStart': [1, 1], 'runnerPID': 1002, 'runnerStart': [1, 2]}
        write_json(self.guest / '.agent-runs' / (self.run_id + '.json'), self.receipt)
        self.processes = {}
        self.uid_results = {}
        self.start_results = {}

    def script(self, source, *extra):
        source = source.replace("const root = '/Volumes/BigWalletBuild';", 'const root = ' + json.dumps(str(self.guest_root)) + ';')
        source = source.replace('const protectedOwner = 0;', 'const protectedOwner = process.getuid();')
        shim = '''
const childFixture = require('node:child_process');
const originalSpawn = childFixture.spawnSync;
const processesFixture = PROCESS_FIXTURE;
const uidResultsFixture = UID_RESULTS_FIXTURE;
const startResultsFixture = START_RESULTS_FIXTURE;
const userFixture = require('node:os');
const originalUser = userFixture.userInfo;
userFixture.userInfo = () => ({...originalUser(), username: 'guest'});
childFixture.spawnSync = (file, args, options) => {
    if (file === '/bin/ps') {
        if (JSON.stringify(args) !== JSON.stringify(['-p', args[1], '-o', 'uid=']) ||
            options.timeout !== 5000 || options.maxBuffer !== 4096) throw Error('Unexpected PID owner query');
        return uidResultsFixture[args[1]] ?? {status: 0, stdout: String(process.getuid()) + '\\n', stderr: ''};
    }
    if (file === '/usr/local/libexec/big-wallet-vm/VMGuestAgent') {
        if (args[0] !== '--process-identity') throw Error('Recovery attempted to launch a runner');
        return startResultsFixture[args[1]] ?? {status: 0, stdout: JSON.stringify(processesFixture[args[1]] ?? null), stderr: ''};
    }
    if (file === '/usr/bin/tar') return originalSpawn(file, args, options);
    throw Error('Unexpected recovery subprocess: ' + file);
};
'''.replace('PROCESS_FIXTURE', json.dumps(self.processes)).replace('UID_RESULTS_FIXTURE', json.dumps(self.uid_results)).replace(
            'START_RESULTS_FIXTURE', json.dumps(self.start_results))
        return subprocess.run([self.node, '-e', shim + source, self.run_id, self.vm_id,
                               self.job_hash, self.source_hash, 'guest', *extra], capture_output=True, timeout=15)

    def test_remote_manifest_accepts_stopped_pid_reuse_and_preserves_running_report(self):
        before = {str(path): path.read_bytes() for path in self.guest.rglob('*') if path.is_file()}
        self.processes = {'1001': [999, 1], '1002': [999, 2]}
        result = self.script(recovery.REMOTE_MANIFEST)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        manifest = json.loads(result.stdout)
        recovery.validate_manifest(manifest, self.plan())
        self.assertEqual(manifest['reportStatus'], 'running')
        self.assertIsNone(manifest['reportFinishedAt'])
        self.assertEqual({str(path): path.read_bytes() for path in self.guest.rglob('*') if path.is_file()}, before)

    def test_remote_manifest_rejects_live_agent_or_runner_without_signaling(self):
        for processes in ({'1001': [1, 1]}, {'1002': [1, 2]}):
            with self.subTest(processes=processes):
                self.processes = processes
                result = self.script(recovery.REMOTE_MANIFEST)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b'still alive', result.stderr)

    def test_other_uid_pid_reuse_skips_privileged_start_time_inspection(self):
        self.uid_results = {'1001': {'status': 0, 'stdout': '0\n', 'stderr': ''},
                            '1002': {'status': 0, 'stdout': '0\n', 'stderr': ''}}
        self.start_results = {pid: {'status': 2, 'stdout': '', 'stderr': 'inspection must not happen'} for pid in ('1001', '1002')}
        result = self.script(recovery.REMOTE_MANIFEST)
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_absent_pid_requires_unambiguous_ps_absence_and_skips_start_time_inspection(self):
        self.uid_results = {'1001': {'status': 1, 'stdout': '', 'stderr': ''},
                            '1002': {'status': 1, 'stdout': '', 'stderr': ''}}
        self.start_results = {pid: {'status': 2, 'stdout': '', 'stderr': 'inspection must not happen'} for pid in ('1001', '1002')}
        result = self.script(recovery.REMOTE_MANIFEST)
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_uid_query_errors_and_ambiguous_responses_fail_closed_with_safe_identity_diagnostics(self):
        cases = [
            {'status': 2, 'stdout': '', 'stderr': 'private fixture detail'},
            {'status': None, 'signal': 'SIGKILL', 'stdout': '', 'stderr': ''},
            {'status': 1, 'stdout': '501\n', 'stderr': ''},
            {'status': 0, 'stdout': '501\n502\n', 'stderr': ''},
            {'status': 0, 'stdout': '', 'stderr': ''},
            {'status': 0, 'stdout': '-1\n', 'stderr': ''},
            {'status': 0, 'stdout': '501\n', 'stderr': 'private fixture detail'},
        ]
        for value in cases:
            with self.subTest(value=value):
                self.uid_results = {'1001': value}
                result = self.script(recovery.REMOTE_MANIFEST)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b'Cannot inspect retained guest process identity: PID 1001; UID', result.stderr)
                self.assertIn(b'; status ', result.stderr)
                self.assertIn(b'; signal ', result.stderr)
                self.assertNotIn(b'private fixture detail', result.stderr)

    def test_owned_process_inspection_errors_fail_closed_with_safe_status_and_signal(self):
        cases = [
            {'status': 2, 'stdout': '', 'stderr': 'private fixture detail'},
            {'status': None, 'signal': 'SIGKILL', 'stdout': '', 'stderr': ''},
            {'status': 0, 'stdout': 'not JSON', 'stderr': ''},
            {'status': 0, 'stdout': '[1,-1]', 'stderr': ''},
            {'status': 0, 'stdout': 'null', 'stderr': 'private fixture detail'},
        ]
        for value in cases:
            with self.subTest(value=value):
                self.start_results = {'1001': value}
                result = self.script(recovery.REMOTE_MANIFEST)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b'Cannot inspect retained guest process identity: PID 1001; start-time', result.stderr)
                self.assertIn(b'; status ', result.stderr)
                self.assertIn(b'; signal ', result.stderr)
                self.assertNotIn(b'private fixture detail', result.stderr)

    def test_completed_receipt_still_requires_its_process_to_have_exited(self):
        self.receipt.update(state='completed', exitCode=1)
        self.receipt.pop('runnerPID')
        self.receipt.pop('runnerStart')
        write_json(self.guest / '.agent-runs' / (self.run_id + '.json'), self.receipt)
        self.processes = {'1001': [1, 1]}
        result = self.script(recovery.REMOTE_MANIFEST)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'still alive', result.stderr)

    def test_remote_export_is_observational_and_rejects_changed_inventory(self):
        manifest = json.loads(self.script(recovery.REMOTE_MANIFEST).stdout)
        before = {str(path): path.read_bytes() for path in self.guest.rglob('*') if path.is_file()}
        result = self.script(recovery.REMOTE_EXPORT, manifest['inventorySHA256'], manifest['reportSHA256'])
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        archive = self.root / 'remote.tar'
        archive.write_bytes(result.stdout)
        archive.chmod(0o600)
        destination, extracted = self.extract(archive, manifest)
        self.assertEqual((destination / 'artifacts/safari.log').read_bytes(), b'original safari failure log')
        self.assertFalse(extracted['guestReportComplete'])
        self.assertEqual({str(path): path.read_bytes() for path in self.guest.rglob('*') if path.is_file()}, before)
        (self.guest / 'artifacts/safari.log').write_bytes(b'changed diagnostic')
        rejected = self.script(recovery.REMOTE_EXPORT, manifest['inventorySHA256'], manifest['reportSHA256'])
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn(b'changed after recovery admission', rejected.stderr)
        self.assertEqual(rejected.stdout, b'')

    def test_remote_manifest_rejects_mismatched_guest_job_and_symlinked_artifacts(self):
        (self.guest / 'job.json').write_text('{}')
        result = self.script(recovery.REMOTE_MANIFEST)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'Guest job or source identity differs', result.stderr)
        (self.guest / 'job.json').write_bytes((self.original / 'job.json').read_bytes())
        (self.guest / 'artifacts/escape').symlink_to(self.original / 'job.json')
        result = self.script(recovery.REMOTE_MANIFEST)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'unsafe path', result.stderr)


if __name__ == '__main__':
    unittest.main()
