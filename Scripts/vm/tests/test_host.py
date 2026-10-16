import importlib.util
import contextlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import itertools
from types import SimpleNamespace
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('vm_host', Path(__file__).resolve().parents[1] / 'host.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repository = self.root / 'repository'
        self.repository.mkdir()
        self.exchange = self.root / 'exchange'
        self.exchange.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'user.name', 'Fixture')
        (self.repository / 'tracked.txt').write_text('initial')
        self.git('add', 'tracked.txt')
        self.git('commit', '-qm', 'fixture')

    def git(self, *args):
        subprocess.run(['git', '-C', str(self.repository), *args], check=True, capture_output=True)

    def test_dirty_untracked_deleted_and_ignored_files_are_snapshotted_correctly(self):
        (self.repository / 'tracked.txt').write_text('edited')
        (self.repository / '.gitignore').write_text('ignored.txt\n')
        (self.repository / 'ignored.txt').write_text('not source')
        (self.repository / 'new.txt').write_text('new')
        (self.repository / 'node_modules').mkdir()
        (self.repository / 'node_modules/dependency.js').write_text('dependency')
        (self.repository / '.env.local').write_text('secret')
        (self.repository / 'signing.p12').write_text('secret')
        result = host.snapshot_source(self.repository, self.exchange)
        manifest = host.read_json(self.exchange / 'snapshot-manifest.json')
        names = {entry['path'] for entry in manifest['files']}
        self.assertEqual(names, {'tracked.txt', '.gitignore', 'new.txt'})
        self.assertEqual(result['fileCount'], 3)
        self.assertEqual((self.exchange / 'source/tracked.txt').read_text(), 'edited')
        (self.repository / 'tracked.txt').write_text('later edit')
        self.assertEqual((self.exchange / 'source/tracked.txt').read_text(), 'edited')
        self.assertEqual(result['sha256'], host.hashlib.sha256((self.exchange / 'snapshot-manifest.json').read_bytes()).hexdigest())

    def test_safe_relative_symlink_preserves_target_without_following_it(self):
        (self.repository / 'alias.txt').symlink_to('tracked.txt')
        host.snapshot_source(self.repository, self.exchange)
        self.assertTrue((self.exchange / 'source/alias.txt').is_symlink())
        self.assertEqual(os.readlink(self.exchange / 'source/alias.txt'), 'tracked.txt')

    def test_symlink_outside_repository_is_rejected(self):
        (self.repository / 'escape').symlink_to('../outside')
        with self.assertRaisesRegex(host.RunnerError, 'symlink leaves'):
            host.snapshot_source(self.repository, self.exchange)

    def test_symlink_to_excluded_credential_is_rejected(self):
        (self.repository / '.env').write_text('secret')
        (self.repository / 'alias').symlink_to('.env')
        with self.assertRaisesRegex(host.RunnerError, 'excluded content'):
            host.snapshot_source(self.repository, self.exchange)

    def test_deleted_tracked_file_is_absent(self):
        (self.repository / 'tracked.txt').unlink()
        host.snapshot_source(self.repository, self.exchange)
        self.assertEqual(host.read_json(self.exchange / 'snapshot-manifest.json')['files'], [])

    def test_oversized_sparse_file_is_rejected_before_reading_or_allocating_contents(self):
        large = self.repository / 'large.dat'
        with open(large, 'wb') as file:
            file.truncate(2 * 1024 ** 3)
        original_open = host.open_regular
        @contextlib.contextmanager
        def guarded_open(path):
            with original_open(path) as file:
                class Reader:
                    def fileno(self): return file.fileno()
                    def read(self, *args): raise AssertionError('Oversized file contents were read')
                yield Reader() if path == large.resolve() else file
        with patch.object(host, 'open_regular', side_effect=guarded_open):
            with self.assertRaisesRegex(host.RunnerError, 'snapshot exceeds'):
                host.snapshot_source(self.repository, self.exchange)
        self.assertFalse((self.exchange / 'source/large.dat').exists())
        self.assertFalse((self.exchange / 'snapshot-manifest.json').exists())

    def test_cumulative_byte_limit_and_symlink_inventory_limit_apply_before_the_next_file(self):
        (self.repository / 'a.dat').write_bytes(b'abcd')
        with patch.object(host, 'MAX_SNAPSHOT_BYTES', 10):
            with self.assertRaisesRegex(host.RunnerError, 'snapshot exceeds'):
                host.snapshot_source(self.repository, self.exchange)
        self.assertEqual((self.exchange / 'source/a.dat').read_bytes(), b'abcd')
        self.assertFalse((self.exchange / 'source/tracked.txt').exists())
        host.shutil.rmtree(self.exchange / 'source')
        (self.repository / 'a.dat').unlink()
        (self.repository / 'a.link').symlink_to('tracked.txt')
        with patch.object(host, 'MAX_SNAPSHOT_FILES', 1):
            with self.assertRaisesRegex(host.RunnerError, 'snapshot exceeds'):
                host.snapshot_source(self.repository, self.exchange)
        self.assertTrue((self.exchange / 'source/a.link').is_symlink())
        self.assertFalse((self.exchange / 'source/tracked.txt').exists())

    def test_growth_is_detected_with_a_read_bounded_by_the_observed_file_size(self):
        source = self.repository / 'a-growing.dat'
        source.write_bytes(b'a')
        original_open = host.open_regular
        requests = []
        @contextlib.contextmanager
        def growing_open(path):
            with original_open(path) as file:
                class Reader:
                    def fileno(self): return file.fileno()
                    def read(self, count):
                        requests.append(count)
                        with open(source, 'ab') as output:
                            output.write(b'grew')
                        return file.read(count)
                yield Reader() if path == source.resolve() else file
        with patch.object(host, 'open_regular', side_effect=growing_open):
            with self.assertRaisesRegex(host.RunnerError, 'Source changed'):
                host.snapshot_source(self.repository, self.exchange)
        self.assertEqual(requests, [2])
        self.assertFalse((self.exchange / 'snapshot-manifest.json').exists())

    def test_streaming_preserves_snapshot_bytes_modes_and_hashes_with_bounded_reads(self):
        source = self.repository / 'payload.dat'
        contents = b'x' * (2 * 1024 * 1024 + 17)
        source.write_bytes(contents)
        source.chmod(0o755)
        original_open = host.open_regular
        requests = []
        @contextlib.contextmanager
        def bounded_open(path):
            with original_open(path) as file:
                class Reader:
                    def fileno(self): return file.fileno()
                    def read(self, count):
                        requests.append(count)
                        if not 0 < count <= 1024 * 1024: raise AssertionError('Unbounded snapshot read')
                        return file.read(count)
                yield Reader()
        with patch.object(host, 'open_regular', side_effect=bounded_open):
            result = host.snapshot_source(self.repository, self.exchange)
        entry = next(value for value in host.read_json(self.exchange / 'snapshot-manifest.json')['files'] if value['path'] == 'payload.dat')
        self.assertEqual(entry['sha256'], host.hashlib.sha256(contents).hexdigest())
        self.assertEqual(entry['mode'], 0o755)
        self.assertEqual((self.exchange / 'source/payload.dat').read_bytes(), contents)
        self.assertEqual(result['bytes'], len(contents) + len(b'initial'))
        self.assertGreater(len(requests), 2)


class DiskIdleTests(unittest.TestCase):
    @unittest.skipUnless(host.sys.platform == 'darwin', 'Uses macOS lsof against plain temporary files')
    def test_real_lsof_rejects_one_or_both_open_files_and_accepts_closed_files(self):
        with tempfile.TemporaryDirectory(prefix='big-wallet-idle-fixture-') as temporary:
            root = Path(temporary)
            files = [root / 'Disk.img', root / 'BuildData.img']
            for filename in files:
                filename.write_bytes(b'plain text fixture, not a disk image')
            host.ensure_disk_idle(root)
            for selected in ([files[0]], [files[1]], files):
                with self.subTest(open_files=[filename.name for filename in selected]), contextlib.ExitStack() as stack:
                    for filename in selected:
                        stack.enter_context(filename.open('rb'))
                    with self.assertRaisesRegex(host.RunnerError, 'disk is in use'):
                        host.ensure_disk_idle(root)
            host.ensure_disk_idle(root)

    def test_lsof_pid_output_warnings_errors_and_timeout_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'Disk.img').write_text('plain fixture')
            for status, output, errors in [(1, b'123\n', b''), (0, b'123\n', b''),
                                           (1, b'', b'incomplete inspection'), (2, b'', b'')]:
                with self.subTest(status=status, output=output, errors=errors), \
                        patch.object(host.subprocess, 'run', return_value=SimpleNamespace(
                            returncode=status, stdout=output, stderr=errors)) as inspect:
                    with self.assertRaises(host.RunnerError):
                        host.ensure_disk_idle(root)
                    self.assertEqual(inspect.call_args.args[0][:3], ['/usr/sbin/lsof', '-t', '+w'])
                    self.assertEqual(inspect.call_args.kwargs['timeout'], 30)
            for error in (OSError('inspection unavailable'), subprocess.TimeoutExpired('lsof', 30)):
                with self.subTest(error=type(error).__name__), patch.object(host.subprocess, 'run', side_effect=error):
                    with self.assertRaisesRegex(host.RunnerError, 'Could not establish'):
                        host.ensure_disk_idle(root)


class ConfigurationWriteTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.vm = self.root / 'candidate.vbvm'
        (self.vm / '.vbdata').mkdir(parents=True)
        for name in ('Disk.img', 'AuxiliaryStorage', 'HardwareModel', 'MachineIdentifier'):
            (self.vm / name).write_bytes(b'fixture')
        (self.vm / 'BuildData.img').write_bytes(b'0' * 1024)
        self.configuration = {'systemType': 'mac', 'hardware': {'networkDevices': [{'macAddress': '02:00:00:00:00:01'}],
            '_storageDevices': [{'isBootVolume': True, 'backing': {'managedImage': {'_0': {'filename': 'Disk', 'format': 0}}}},
                                {'isBootVolume': False, 'backing': {'managedImage': {'_0': {'filename': 'BuildData', 'format': 0}}}}]}}
        self.path = self.vm / '.vbdata/Config.plist'
        self.original = plistlib.dumps(self.configuration)
        self.path.write_bytes(self.original)

    def test_candidate_configuration_survives_partial_write_failure_or_interruption(self):
        operations = [lambda: host.configure_build_storage(self.vm, 1024),
                      lambda: host.configure_guest_hardware(self.vm, 'fixture-vm')]
        for operation in operations:
            for failure in (OSError('fixture write failure'), KeyboardInterrupt()):
                with self.subTest(operation=operation, failure=type(failure).__name__):
                    def interrupted_dump(value, file):
                        file.write(b'partial plist')
                        raise failure
                    with patch.object(host.plistlib, 'dump', side_effect=interrupted_dump):
                        with self.assertRaises(type(failure)):
                            operation()
                    self.assertEqual(self.path.read_bytes(), self.original)
                    self.assertEqual(host.validate_vm(self.vm), self.configuration)
                    self.assertEqual(list(self.path.parent.glob('*.tmp')), [])

    def test_failed_atomic_replacement_preserves_the_existing_configuration(self):
        with patch.object(host.os, 'replace', side_effect=OSError('fixture replacement failure')):
            with self.assertRaisesRegex(OSError, 'replacement failure'):
                host.configure_guest_hardware(self.vm, 'fixture-vm')
        self.assertEqual(self.path.read_bytes(), self.original)
        self.assertEqual(list(self.path.parent.glob('*.tmp')), [])

    def test_atomic_plist_syncs_the_file_before_replacement_and_parent_afterward(self):
        events = []
        replace, sync = host.os.replace, host.os.fsync
        def replace_recorded(source, destination):
            events.append('replace')
            return replace(source, destination)
        def sync_recorded(descriptor):
            events.append('directory-sync' if host.stat.S_ISDIR(host.os.fstat(descriptor).st_mode) else 'file-sync')
            return sync(descriptor)
        with patch.object(host.os, 'replace', side_effect=replace_recorded), patch.object(host.os, 'fsync', side_effect=sync_recorded):
            host.configure_guest_hardware(self.vm, 'fixture-vm')
        self.assertEqual(events, ['file-sync', 'replace', 'directory-sync'])
        self.assertEqual(host.validate_vm(self.vm)['sharedFolders'], [])


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_operation_lock_serializes_runs_without_signalling_other_processes(self):
        with host.execution_lock(self.root):
            with self.assertRaisesRegex(host.RunnerError, 'Another VM operation'):
                with host.execution_lock(self.root):
                    pass
        with host.execution_lock(self.root):
            pass

    def test_state_symlink_is_rejected(self):
        link = self.root / 'link'
        link.symlink_to(self.root / 'other')
        with self.assertRaisesRegex(host.RunnerError, 'symlink'):
            host.private_directory(link)

    def test_vm_metadata_symlink_is_rejected_before_any_mutation(self):
        bundle = self.root / 'symlink.vbvm'
        bundle.mkdir()
        (bundle / '.vbdata').symlink_to(self.root)
        with self.assertRaisesRegex(host.RunnerError, 'metadata must be a real directory'):
            host.validate_vm(bundle)

    def test_missing_baseline_never_runs_any_host_command(self):
        args = host.parser().parse_args(['run', 'all'])
        with patch.object(host, 'checked', side_effect=AssertionError('host command started')):
            with self.assertRaisesRegex(host.RunnerError, 'No verified baseline'):
                host.run_tests(args, self.root, {})

    def test_source_mismatch_blocks_baseline_and_candidate_before_preparation(self):
        for candidate in (False, True):
            with self.subTest(candidate=candidate):
                args = host.parser().parse_args(['--vm', str(self.root / 'requested.vbvm'), 'run', 'all'] +
                                               (['--candidate'] if candidate else []))
                record = self.root / ('candidate.json' if candidate else 'baseline.json')
                host.atomic_json(record, {'sourceVM': str(self.root / 'different.vbvm')})
                with patch.object(host, 'check_capacity') as capacity, patch.object(host, 'build_tools') as tools, \
                        patch.object(host, 'new_exchange') as exchange, patch.object(host, 'clone_vm') as clone, \
                        patch.object(host, 'monitor_vm') as monitor:
                    with self.assertRaisesRegex(host.RunnerError, 'another source VM'):
                        host.run_tests(args, self.root, {})
                for operation in (capacity, tools, exchange, clone, monitor):
                    operation.assert_not_called()
                self.assertFalse((self.root / 'active.json').exists())

    def test_matching_normalized_source_reaches_preparation_for_both_templates(self):
        source = self.root.resolve() / 'source.vbvm'
        (source.parent / 'segment').mkdir()
        recorded = str(source.parent / 'segment' / '..' / source.name)
        environment = {'minimumHostFreeBytes': 1}
        for candidate in (False, True):
            with self.subTest(candidate=candidate):
                args = host.parser().parse_args(['--vm', os.path.relpath(source), 'run', 'all'] +
                                               (['--candidate'] if candidate else []))
                host.atomic_json(self.root / ('candidate.json' if candidate else 'baseline.json'),
                                 {'sourceVM': recorded, 'baseVerifiedAt': 'fixture', 'environment': environment,
                                  'runnerSourceDigest': 'fixture'})
                with patch.object(host, 'runner_source_digest', return_value='fixture'), \
                        patch.object(host, 'check_capacity', side_effect=host.RunnerError('fixture preparation reached')) as capacity:
                    with self.assertRaisesRegex(host.RunnerError, 'fixture preparation reached'):
                        host.run_tests(args, self.root, environment)
                capacity.assert_called_once()

    def test_source_comparison_rejects_invalid_records_and_does_not_follow_symlinks(self):
        source = self.root.resolve() / 'source.vbvm'
        source.mkdir()
        alias = source.with_name('alias.vbvm')
        alias.symlink_to(source, target_is_directory=True)
        self.assertFalse(host.matches_source_vm({'sourceVM': str(source)}, alias))
        for value in (None, 1, {}, 'source.vbvm', '~/source.vbvm'):
            with self.subTest(source=value):
                self.assertFalse(host.matches_source_vm({'sourceVM': value}, source))
        self.assertFalse(host.matches_source_vm({}, source))

    def test_source_dotdot_cannot_hide_a_symlink_ancestor(self):
        state = self.root.resolve()
        selected = state / 'selected'
        target = state / 'different' / 'nested'
        selected.mkdir()
        target.mkdir(parents=True)
        (selected / 'link').symlink_to(target, target_is_directory=True)
        ambiguous = selected / 'link' / '..' / 'source.vbvm'
        for record, requested in (({'sourceVM': str(selected / 'source.vbvm')}, ambiguous),
                                  ({'sourceVM': str(ambiguous)}, selected / 'source.vbvm')):
            with self.subTest(record=record, requested=requested), \
                    self.assertRaisesRegex(host.RunnerError, 'must not traverse symlinks'):
                host.matches_source_vm(record, requested)

    def test_low_disk_space_blocks_before_boot(self):
        with self.assertRaisesRegex(host.RunnerError, 'disk space'):
            host.check_capacity(self.root, 2 ** 62)

    def test_json_does_not_follow_guest_symlink(self):
        (self.root / 'other.json').write_text('{}')
        (self.root / 'result.json').symlink_to('other.json')
        with self.assertRaises(OSError):
            host.read_json(self.root / 'result.json')

    def test_atomic_report_replaces_previous_whole_record(self):
        path = self.root / 'report.json'
        host.atomic_json(path, {'status': 'running'})
        host.atomic_json(path, {'status': 'failed', 'reason': 'fixture'})
        self.assertEqual(host.read_json(path), {'status': 'failed', 'reason': 'fixture'})
        self.assertEqual(list(self.root.iterdir()), [path])

    def test_guest_hardware_removes_shares_only_from_owned_candidate_config(self):
        bundle = self.root / 'candidate.vbvm'
        (bundle / '.vbdata').mkdir(parents=True)
        for name in ('Disk.img', 'AuxiliaryStorage', 'HardwareModel', 'MachineIdentifier'):
            (bundle / name).write_bytes(b'fixture')
        configuration = {'systemType': 'mac', 'hardware': {'_storageDevices': [{'isBootVolume': True,
            'backing': {'managedImage': {'_0': {'filename': 'Disk', 'format': 0, 'size': 7}}}}],
            'soundDevices': [{'enableInput': True}]}, 'guestAdditionsEnabled': True}
        with open(bundle / '.vbdata/Config.plist', 'wb') as file:
            plistlib.dump(configuration, file)
        host.configure_guest_hardware(bundle)
        final = host.validate_vm(bundle)
        self.assertFalse(final['guestAdditionsEnabled'])
        self.assertFalse(final['captureSystemKeys'])
        self.assertEqual(final['hardware']['soundDevices'], [])
        self.assertEqual(final['sharedFolders'], [])
        self.assertEqual((bundle / 'MachineIdentifier').read_bytes(), b'fixture')

    def test_cli_rejects_arbitrary_stages_and_accepts_narrow_native_filter(self):
        args = host.parser().parse_args(['run', 'all', '--stage', 'test', '--only-testing', 'Tests macOS/WindowAuthenticationSessionTests'])
        self.assertEqual(args.stage, ['test'])
        self.assertEqual(args.only_testing, ['Tests macOS/WindowAuthenticationSessionTests'])

    def test_replay_is_copied_and_rewritten_for_the_guest(self):
        source = self.root / 'failure.json'
        source.write_text('{"fixture":true}')
        exchange = self.root / 'exchange'
        exchange.mkdir()
        arguments = host.stage_approval_arguments(['--replay', str(source)], exchange)
        source.write_text('{"fixture":false}')
        self.assertEqual(arguments, ['--replay', '/Volumes/BigWalletBuild/Exchange/inputs/approval-replay.json'])
        self.assertEqual(host.read_json(exchange / 'inputs/approval-replay.json'), {'fixture': True})
        with self.assertRaisesRegex(host.RunnerError, 'managed inside the guest'):
            host.stage_approval_arguments(['--worker', '/host/executable'], exchange)

    def test_timeout_and_stop_cannot_turn_into_a_late_success(self):
        for reason in ('timeout', 'stop'):
            with self.subTest(reason=reason):
                exchange = self.root / reason
                (exchange / 'artifacts').mkdir(parents=True)
                clock = itertools.count()
                class Child:
                    def poll(self): return None
                    def wait(self, timeout=None): return 0
                def launch(*args, **kwargs):
                    if reason == 'stop':
                        host.atomic_json(exchange / 'stop.json', {'runId': 'run-fixture'})
                    return Child()
                def finish_during_cleanup(_):
                    host.atomic_json(exchange / 'artifacts/result.json',
                                     {'runId': 'run-fixture', 'status': 'passed', 'finishedAt': 'fixture',
                                      'summary': {'status': 'passed', 'issues': []},
                                      'coverage': {'status': 'complete', 'fullSuiteVerified': True}})
                with patch.object(host.subprocess, 'Popen', side_effect=launch), \
                        patch.object(host.time, 'monotonic', side_effect=lambda: next(clock)), \
                        patch.object(host.time, 'sleep', side_effect=finish_during_cleanup), \
                        patch.object(host, 'check_capacity', return_value=100):
                    result = host.monitor_vm(SimpleNamespace(command='run'), self.root,
                                             self.root / 'unused.vbvm', exchange, 'run-fixture',
                                             self.root, {}, 0 if reason == 'timeout' else 100)
                self.assertEqual(result['status'], 'failed' if reason == 'timeout' else 'cancelled')
                self.assertEqual(result['guestResultAfterStop'], 'guest-result-after-stop.json')
                self.assertEqual(host.read_json(exchange / 'artifacts/guest-result-after-stop.json')['status'], 'passed')
                self.assertEqual(result['summary']['status'], result['status'])
                self.assertEqual(result['coverage']['status'], 'partial')
                self.assertFalse(result['coverage']['fullSuiteVerified'])

    def test_interruption_before_terminal_acceptance_wins_while_running_or_after_exit(self):
        for trigger in ('stop', 'timeout', 'signal'):
            for exited in (False, True):
                with self.subTest(trigger=trigger, exited=exited):
                    exchange = self.root / f'{trigger}-{exited}'
                    (exchange / 'artifacts').mkdir(parents=True)
                    clock = [0]
                    class Child:
                        returncode = None
                        def poll(self): return self.returncode
                        def wait(self, timeout=None): self.returncode = 0; return 0
                    child = Child()
                    def complete(_):
                        if trigger == 'stop':
                            host.atomic_json(exchange / 'stop.json', {'runId': 'run-fixture'})
                        elif trigger == 'timeout':
                            clock[0] = 100
                        else:
                            host.signal.getsignal(host.signal.SIGTERM)(host.signal.SIGTERM, None)
                        host.atomic_json(exchange / 'artifacts/result.json',
                                         {'runId': 'run-fixture', 'status': 'passed', 'finishedAt': 'fixture'})
                        if exited:
                            child.returncode = 0
                    with patch.object(host.subprocess, 'Popen', return_value=child), \
                            patch.object(host.time, 'monotonic', side_effect=lambda: clock[0]), \
                            patch.object(host.time, 'sleep', side_effect=complete), \
                            patch.object(host, 'check_capacity', return_value=100):
                        result = host.monitor_vm(SimpleNamespace(command='run'), self.root,
                                                 self.root / 'unused.vbvm', exchange, 'run-fixture',
                                                 self.root, {'minimumHostFreeBytes': 1}, 100)
                    self.assertEqual(result['reason'], 'timed_out' if trigger == 'timeout' else 'cancelled')
                    self.assertEqual(result['status'], 'failed' if trigger == 'timeout' else 'cancelled')
                    self.assertEqual(host.read_json(exchange / 'artifacts/guest-result-after-stop.json')['status'], 'passed')
                    self.assertFalse((self.root / 'active.json').exists())

    def test_stop_or_timeout_arriving_during_terminal_read_cannot_pass(self):
        for trigger in ('stop', 'timeout'):
            for exited in (False, True):
                with self.subTest(trigger=trigger, exited=exited):
                    exchange = self.root / f'reading-{trigger}-{exited}'
                    (exchange / 'artifacts').mkdir(parents=True)
                    result_path = exchange / 'artifacts/result.json'
                    host.atomic_json(result_path, {'runId': 'run-fixture', 'status': 'passed', 'finishedAt': 'fixture'})
                    clock = [0]
                    class Child:
                        returncode = 0 if exited else None
                        def poll(self): return self.returncode
                        def wait(self, timeout=None): self.returncode = 0; return 0
                    read_json = host.read_json
                    def read(path):
                        result = read_json(path)
                        if path == result_path:
                            if trigger == 'stop':
                                host.atomic_json(exchange / 'stop.json', {'runId': 'run-fixture'})
                            else:
                                clock[0] = 100
                        return result
                    with patch.object(host.subprocess, 'Popen', return_value=Child()), \
                            patch.object(host.time, 'monotonic', side_effect=lambda: clock[0]), \
                            patch.object(host, 'read_json', side_effect=read):
                        result = host.monitor_vm(SimpleNamespace(command='run'), self.root,
                                                 self.root / 'unused.vbvm', exchange, 'run-fixture',
                                                 self.root, {}, 100)
                    self.assertEqual(result['reason'], 'timed_out' if trigger == 'timeout' else 'cancelled')
                    self.assertEqual(read_json(exchange / 'artifacts/guest-result-after-stop.json')['status'], 'passed')

    def test_completed_result_from_exited_vm_can_still_pass_without_interruption(self):
        exchange = self.root / 'completed-exit'
        (exchange / 'artifacts').mkdir(parents=True)
        completed = {'runId': 'run-fixture', 'status': 'passed', 'finishedAt': 'fixture'}
        host.atomic_json(exchange / 'artifacts/result.json', completed)
        class Child:
            def poll(self): return 0
        with patch.object(host.subprocess, 'Popen', return_value=Child()):
            result = host.monitor_vm(SimpleNamespace(command='run'), self.root,
                                     self.root / 'unused.vbvm', exchange, 'run-fixture', self.root, {}, 100)
        self.assertEqual(result, completed)
        self.assertFalse((exchange / 'stop.json').exists())

    def partial_report(self):
        return {'runId': 'run-fixture', 'status': 'running', 'source': {'sha256': 'snapshot-fixture'},
                'preflight': {'checks': {'graphicalSession': True}},
                'stages': [
                    {'id': 'test.ios.debug', 'status': 'passed', 'audit': {'counts': {'passed': 42}},
                     'resultBundle': 'test.ios.debug.xcresult'},
                    {'id': 'worker.tests', 'status': 'failed', 'reason': 'first failure', 'log': 'worker.tests.log'},
                    {'id': 'approval.soak-debug', 'status': 'running', 'log': 'approval.soak-debug.log'},
                    {'id': 'approval.soak-release', 'status': 'pending'}]}

    def test_monitor_preserves_partial_diagnostics_after_timeout_stop_or_vm_exit(self):
        for trigger, reason, status in (('timeout', 'timed_out', 'failed'), ('stop', 'cancelled', 'cancelled'),
                                        ('exit', 'vm_exited', 'blocked')):
            with self.subTest(trigger=trigger):
                exchange = self.root / trigger
                (exchange / 'artifacts').mkdir(parents=True)
                original = self.partial_report()
                host.atomic_json(exchange / 'artifacts/result.json', original)
                if trigger == 'stop':
                    host.atomic_json(exchange / 'stop.json', {'runId': 'run-fixture'})
                clock = itertools.count()
                class Child:
                    def poll(self): return 0 if trigger == 'exit' else None
                    def wait(self, timeout=None): return 0
                with patch.object(host.subprocess, 'Popen', return_value=Child()), \
                        patch.object(host.time, 'monotonic', side_effect=lambda: next(clock)), \
                        patch.object(host.time, 'sleep'), \
                        patch.object(host, 'check_capacity', return_value=100):
                    result = host.monitor_vm(SimpleNamespace(command='run'), self.root, self.root / 'unused.vbvm',
                                             exchange, 'run-fixture', self.root, {}, 0 if trigger == 'timeout' else 100)
                self.assertEqual(result['status'], status)
                self.assertEqual(result['hostTermination']['reason'], reason)
                self.assertEqual(result['source'], original['source'])
                self.assertEqual(result['preflight'], original['preflight'])
                self.assertEqual(result['stages'][:2], original['stages'][:2])
                self.assertEqual(result['stages'][2]['log'], 'approval.soak-debug.log')
                for stage in result['stages'][2:]:
                    self.assertEqual(stage['status'], 'cancelled' if trigger == 'stop' else 'blocked')
                    self.assertEqual(stage['reason'], reason)
                    self.assertTrue(stage['finishedAt'])
                self.assertEqual(result['summary']['counts']['passed'], 1)
                self.assertEqual(result['summary']['counts']['failed'], 1)
                self.assertEqual(result['coverage']['status'], 'partial')
                self.assertFalse(result['coverage']['fullSuiteVerified'])
                self.assertEqual(len(result['coverage']['incompleteStages']), 3)
                self.assertEqual(host.read_json(exchange / 'artifacts' / result['interruptedGuestResult']), original)
                self.assertEqual(host.read_json(exchange / 'artifacts/result.json'), result)

    def test_reconciliation_preserves_partial_report_and_terminalizes_unfinished_stages(self):
        state = self.root.resolve()
        exchange = state / 'results/run-fixture'
        (exchange / 'artifacts').mkdir(parents=True)
        vm = state / 'runs/run-fixture.vbvm'
        vm.mkdir(parents=True)
        original = self.partial_report()
        host.atomic_json(exchange / 'artifacts/result.json', original)
        host.atomic_json(state / 'active.json', {'runId': 'run-fixture', 'exchange': str(exchange), 'vm': str(vm), 'cloneOwned': True})
        with patch.object(host, 'ensure_disk_idle') as idle:
            host.reconcile_interrupted_operation(state)
        idle.assert_called_once_with(vm)
        result = host.read_json(exchange / 'artifacts/result.json')
        self.assertEqual(result['status'], 'blocked')
        self.assertEqual(result['hostTermination']['reason'], 'host_runner_interrupted')
        self.assertEqual(result['source'], original['source'])
        self.assertEqual(result['stages'][:2], original['stages'][:2])
        self.assertEqual([stage['status'] for stage in result['stages'][2:]], ['blocked', 'blocked'])
        self.assertEqual(host.read_json(exchange / 'artifacts' / result['interruptedGuestResult']), original)
        self.assertTrue((exchange / 'vm-stop').exists())
        self.assertFalse((self.root / 'active.json').exists())
        self.assertTrue(vm.exists())
        self.assertEqual(host.read_json(exchange / 'retained-vm.json')['vm'], str(vm))

    def test_reconciliation_preserves_candidates_baselines_and_other_vm_paths(self):
        for index, relative in enumerate(('candidate.vbvm', 'baseline.vbvm', 'runs/another.vbvm', 'archive/other.vbvm')):
            with self.subTest(path=relative):
                state = self.root.resolve() / str(index)
                exchange = state / 'results/run-fixture'
                (exchange / 'artifacts').mkdir(parents=True)
                vm = state / relative
                vm.mkdir(parents=True)
                (vm / 'sentinel').write_text('preserve')
                host.atomic_json(state / 'active.json', {'runId': 'run-fixture', 'exchange': str(exchange), 'vm': str(vm), 'cloneOwned': True})
                with patch.object(host, 'ensure_disk_idle'), \
                        patch.object(host.shutil, 'rmtree', side_effect=AssertionError('An unowned VM was removed')):
                    host.reconcile_interrupted_operation(state)
                self.assertEqual((vm / 'sentinel').read_text(), 'preserve')
                self.assertFalse((state / 'active.json').exists())

    def test_interrupted_clone_cleanup_failure_retains_ownership_and_is_retryable(self):
        for failure in ('busy', 'remove'):
            with self.subTest(failure=failure):
                state = self.root.resolve() / failure
                exchange = state / 'results/run-fixture'
                (exchange / 'artifacts').mkdir(parents=True)
                vm = state / 'runs/run-fixture.vbvm'
                vm.mkdir(parents=True)
                (vm / 'Disk.img').write_bytes(b'fixture, not a VM image')
                host.atomic_json(exchange / 'artifacts/result.json', {**self.partial_report(),
                    'status': 'failed', 'finishedAt': 'fixture export completion'})
                (exchange / 'artifacts/retained.log').write_text('diagnostics')
                host.atomic_json(state / 'active.json', {'runId': 'run-fixture', 'exchange': str(exchange), 'vm': str(vm), 'cloneOwned': True, 'phase': 'starting', 'artifactsExported': True})
                with contextlib.ExitStack() as stack:
                    stack.enter_context(patch.object(host, 'ensure_disk_idle',
                        side_effect=host.RunnerError('fixture busy') if failure == 'busy' else None))
                    remove = stack.enter_context(patch.object(host.shutil, 'rmtree', side_effect=OSError('fixture remove failed')))
                    with self.assertRaisesRegex(host.RunnerError if failure == 'busy' else OSError, 'fixture'):
                        host.reconcile_interrupted_operation(state)
                    if failure == 'busy':
                        remove.assert_not_called()
                self.assertTrue((state / 'active.json').exists())
                self.assertTrue(vm.exists())
                first_report = host.read_json(exchange / 'artifacts/result.json')
                with patch.object(host, 'ensure_disk_idle'):
                    host.reconcile_interrupted_operation(state)
                self.assertFalse(vm.exists())
                self.assertFalse((state / 'active.json').exists())
                self.assertEqual((exchange / 'artifacts/retained.log').read_text(), 'diagnostics')
                if failure == 'remove':
                    self.assertEqual(host.read_json(exchange / 'artifacts/result.json'), first_report)

    def test_preparing_record_cannot_claim_a_preexisting_clone_during_reconciliation(self):
        for claim in (None, False):
            with self.subTest(cloneOwned=claim):
                state = self.root.resolve() / str(claim)
                exchange = state / 'results/run-fixture'
                (exchange / 'artifacts').mkdir(parents=True)
                vm = state / 'runs/run-fixture.vbvm'
                vm.mkdir(parents=True)
                (vm / 'sentinel').write_text('unclaimed')
                host.register_operation(state, vm, exchange, 'run-fixture', 'preparing')
                active = host.read_json(state / 'active.json')
                self.assertNotIn('cloneOwned', active)
                if claim is False:
                    active['cloneOwned'] = False
                    host.atomic_json(state / 'active.json', active)
                with patch.object(host, 'ensure_disk_idle'), \
                        patch.object(host.shutil, 'rmtree', side_effect=AssertionError('Unclaimed clone was removed')):
                    host.reconcile_interrupted_operation(state)
                self.assertEqual((vm / 'sentinel').read_text(), 'unclaimed')
                self.assertFalse((state / 'active.json').exists())

    def test_claimed_clone_is_retained_after_launch_intent_and_claim_survives_phase_updates(self):
        state = self.root.resolve()
        exchange = state / 'results/run-fixture'
        (exchange / 'artifacts').mkdir(parents=True)
        vm = state / 'runs/run-fixture.vbvm'
        vm.parent.mkdir()
        host.register_operation(state, vm, exchange, 'run-fixture', 'preparing')
        host.register_operation(state, vm, exchange, 'run-fixture', 'preparing', clone_owned=True)
        vm.mkdir()
        (vm / 'Disk.img').write_bytes(b'partial fixture copy')
        host.register_operation(state, vm, exchange, 'run-fixture', 'starting')
        self.assertIs(host.read_json(state / 'active.json')['cloneOwned'], True)
        with patch.object(host, 'ensure_disk_idle'):
            host.reconcile_interrupted_operation(state)
        self.assertEqual((vm / 'Disk.img').read_bytes(), b'partial fixture copy')
        self.assertEqual(host.read_json(exchange / 'retained-vm.json')['vm'], str(vm))
        self.assertFalse((state / 'active.json').exists())
        self.assertEqual(host.read_json(exchange / 'artifacts/result.json')['reason'], 'host_runner_interrupted')

    def test_interrupted_clone_symlinks_and_wrong_owner_are_preserved(self):
        for kind in ('symlink', 'parent-symlink', 'wrong-owner', 'file'):
            with self.subTest(kind=kind):
                state = self.root.resolve() / kind
                exchange = state / 'results/run-fixture'
                (exchange / 'artifacts').mkdir(parents=True)
                preserved = state / 'preserved'
                preserved.mkdir()
                (preserved / 'sentinel').write_text('preserve')
                vm = state / 'runs/run-fixture.vbvm'
                if kind == 'parent-symlink':
                    (state / 'runs').symlink_to(preserved, target_is_directory=True)
                    (preserved / vm.name).mkdir()
                else:
                    vm.parent.mkdir()
                    if kind == 'symlink':
                        vm.symlink_to(preserved, target_is_directory=True)
                    elif kind == 'file':
                        vm.write_bytes(b'not a directory')
                    else:
                        vm.mkdir()
                host.atomic_json(state / 'active.json', {'runId': 'run-fixture', 'exchange': str(exchange), 'vm': str(vm), 'cloneOwned': True})
                with contextlib.ExitStack() as stack:
                    if kind == 'wrong-owner':
                        original_lstat = Path.lstat
                        def lstat(path):
                            metadata = original_lstat(path)
                            return SimpleNamespace(st_mode=metadata.st_mode, st_uid=os.getuid() + 1) if path == vm else metadata
                        stack.enter_context(patch.object(Path, 'lstat', lstat))
                    idle = stack.enter_context(patch.object(host, 'ensure_disk_idle'))
                    remove = stack.enter_context(patch.object(host.shutil, 'rmtree'))
                    with self.assertRaisesRegex(host.RunnerError, 'preserving'):
                        host.reconcile_interrupted_operation(state)
                idle.assert_not_called()
                remove.assert_not_called()
                self.assertTrue((state / 'active.json').exists())
                self.assertEqual((preserved / 'sentinel').read_text(), 'preserve')

    def test_interrupted_clone_replaced_after_idle_check_is_not_removed(self):
        state = self.root.resolve()
        exchange = state / 'results/run-fixture'
        (exchange / 'artifacts').mkdir(parents=True)
        vm = state / 'runs/run-fixture.vbvm'
        vm.mkdir(parents=True)
        preserved = state / 'candidate.vbvm'
        preserved.mkdir()
        (preserved / 'sentinel').write_text('preserve')
        host.atomic_json(state / 'active.json', {'runId': 'run-fixture', 'exchange': str(exchange), 'vm': str(vm), 'cloneOwned': True})
        def replace(_):
            vm.rmdir()
            vm.symlink_to(preserved, target_is_directory=True)
        with patch.object(host, 'ensure_disk_idle', side_effect=replace), patch.object(host.shutil, 'rmtree') as remove:
            with self.assertRaisesRegex(host.RunnerError, 'changed during recovery'):
                host.reconcile_interrupted_operation(state)
        remove.assert_not_called()
        self.assertTrue((state / 'active.json').exists())
        self.assertTrue(vm.is_symlink())
        self.assertEqual((preserved / 'sentinel').read_text(), 'preserve')

    def test_report_or_stop_write_errors_still_stop_the_owned_vm(self):
        for failure in ('malformed-report', 'stop-write'):
            with self.subTest(failure=failure):
                exchange = self.root / failure
                (exchange / 'artifacts').mkdir(parents=True)
                if failure == 'malformed-report':
                    (exchange / 'artifacts/result.json').write_text('{malformed-json')
                else:
                    host.atomic_json(exchange / 'artifacts/result.json',
                                     {'runId': 'run-fixture', 'status': 'running'})
                class Child:
                    returncode = None
                    def poll(self): return self.returncode
                    def wait(self, timeout=None):
                        self.returncode = 0
                        return 0
                child = Child()
                write_json = host.atomic_json
                def write(path, value):
                    if failure == 'stop-write' and Path(path).name == 'stop.json':
                        raise OSError('fixture: stop request could not be written')
                    write_json(path, value)
                with patch.object(host.subprocess, 'Popen', return_value=child), \
                        patch.object(host, 'atomic_json', side_effect=write), \
                        patch.object(host, 'stop_owned_process', wraps=host.stop_owned_process) as stop:
                    result = host.monitor_vm(SimpleNamespace(command='run'), self.root, self.root / 'unused.vbvm',
                                             exchange, 'run-fixture', self.root, {}, 100,
                                             setup_hook=SimpleNamespace(exchange_complete=False,
                                                 poll=lambda: {'status': 'failed', 'reason': 'guest_launch_failed'},
                                                 request_stop=lambda: None, cancel=lambda: None) if failure == 'stop-write' else None)
                self.assertEqual(result['status'], 'failed')
                self.assertTrue(result['finishedAt'])
                if failure == 'malformed-report':
                    self.assertEqual((exchange / 'artifacts' / result['invalidGuestResult']).read_text(), '{malformed-json')
                stop.assert_called_once_with(child, exchange / 'vm-stop')
                self.assertEqual(child.returncode, 0)
                self.assertTrue((exchange / 'vm-stop').exists())
                self.assertFalse((self.root / 'active.json').exists())

    def test_failed_shutdown_retains_active_ownership_for_recovery(self):
        exchange = self.root / 'exchange'
        (exchange / 'artifacts').mkdir(parents=True)
        host.atomic_json(exchange / 'artifacts/result.json',
                         {'runId': 'run-fixture', 'status': 'passed', 'finishedAt': 'fixture'})
        class Child:
            def poll(self): return None
        with patch.object(host.subprocess, 'Popen', return_value=Child()), \
                patch.object(host, 'stop_owned_process', side_effect=OSError('fixture: VM still running')):
            with self.assertRaisesRegex(OSError, 'still running'):
                host.monitor_vm(SimpleNamespace(command='run'), self.root, self.root / 'unused.vbvm',
                                exchange, 'run-fixture', self.root, {}, 100)
        active = host.read_json(self.root / 'active.json')
        self.assertEqual(active['runId'], 'run-fixture')
        self.assertEqual(active['exchange'], str(exchange))

    def test_stop_file_write_failure_falls_back_to_owned_process_termination(self):
        events = []
        class Child:
            def terminate(self): events.append('terminate')
            def wait(self, timeout=None): events.append(('wait', timeout)); return 0
        with patch.object(Path, 'touch', side_effect=OSError('fixture: disk full')):
            host.stop_owned_process(Child(), self.root / 'vm-stop')
        self.assertEqual(events, ['terminate', ('wait', 40)])

    def test_setup_cancellation_report_failures_retain_recovery_over_an_accepted_doctor_pass(self):
        for phase in ('intent', 'report'):
            with self.subTest(phase=phase):
                state = self.root.resolve() / phase
                state.mkdir()
                args = host.parser().parse_args(['setup'])
                write = host.atomic_json
                prepared_exchange = None
                class Child:
                    returncode = None
                    def poll(self): return self.returncode
                    def wait(self, timeout=None): self.returncode = 0; return 0
                def prepare(args, state, environment, operation):
                    nonlocal prepared_exchange
                    exchange, run_id = operation['exchange'], operation['runId']
                    prepared_exchange = exchange
                    write(exchange / 'artifacts/result.json', {'runId': run_id,
                        'status': 'passed', 'finishedAt': 'doctor-completed'})
                    operation['monitorCalled'] = True
                    host.monitor_vm(args, state, state / 'candidate.vbvm', exchange, run_id,
                                    state, environment, 100, keep_operation=True)
                    self.assertIn('acceptedResultSHA256', host.read_json(state / 'active.json'))
                    raise KeyboardInterrupt
                def fail_cancellation_report(path, value):
                    if ((phase == 'intent' and Path(path).name == 'active.json' and value.get('pendingTermination')) or
                            (phase == 'report' and Path(path).name == 'result.json' and value.get('hostTermination'))):
                        raise OSError('fixture cancellation report unavailable')
                    return write(path, value)
                with patch.object(host, 'validate_vm'), patch.object(host, 'prepare_setup', side_effect=prepare), \
                        patch.object(host.subprocess, 'Popen', return_value=Child()), \
                        patch.object(host, 'ensure_disk_idle'), \
                        patch.object(host, 'atomic_json', side_effect=fail_cancellation_report):
                    with self.assertRaisesRegex(OSError, 'cancellation report unavailable'):
                        host.setup(args, state, {'minimumHostFreeBytes': 1})
                active = host.read_json(state / 'active.json')
                self.assertEqual(host.read_json(prepared_exchange / 'artifacts/result.json')['status'], 'passed')
                if phase == 'report':
                    self.assertNotIn('acceptedResultSHA256', active)
                with patch.object(host, 'ensure_disk_idle'):
                    host.reconcile_interrupted_operation(state)
                result = host.read_json(prepared_exchange / 'artifacts/result.json')
                self.assertEqual(result['status'], 'cancelled' if phase == 'report' else 'blocked')
                self.assertEqual(host.read_json(prepared_exchange / 'artifacts' / result['guestResultAfterStop'])['status'], 'passed')
                self.assertFalse((state / 'active.json').exists())


class XcodeArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state = self.root / 'state'
        self.state.mkdir()
        self.xcode = self.root / 'Xcode.app'
        (self.xcode / 'Contents/_CodeSignature').mkdir(parents=True)
        self.seal = self.xcode / 'Contents/_CodeSignature/CodeResources'
        self.seal.write_bytes(b'fixture seal')
        with open(self.xcode / 'Contents/version.plist', 'wb') as file:
            plistlib.dump({'CFBundleShortVersionString': '27.0', 'ProductBuildVersion': 'fixture-build'}, file)
        self.environment = {'xcode': {'version': '27.0', 'buildVersion': 'fixture-build'}}
        self.archives_created = 0
        patcher = patch.object(host, 'checked', side_effect=self.checked)
        patcher.start()
        self.addCleanup(patcher.stop)

    def checked(self, command, **kwargs):
        command = [str(value) for value in command]
        if command[0] == '/usr/bin/codesign':
            self.assertEqual(command, ['/usr/bin/codesign', '--verify', '--strict', str(self.xcode)])
        elif command[0] == '/usr/bin/tar':
            self.assertEqual(command[1], '-cf')
            self.assertEqual(command[3:], ['-C', str(self.xcode.parent), 'Xcode.app'])
            self.assertEqual(kwargs['env']['COPYFILE_DISABLE'], '1')
            Path(command[2]).write_bytes(b'fixture tar: Xcode.app/' + self.seal.read_bytes())
            self.archives_created += 1
        elif command[0] == '/bin/cp':
            self.assertEqual(command[1], '-c')
            host.shutil.copyfile(command[2], command[3])
        else:
            self.fail(f'Unexpected host command: {command[0]}')
        return b''

    def test_archive_is_reused_only_with_matching_pins_seal_and_digest(self):
        archive, digest = host.cached_xcode_archive(self.state, self.xcode, self.environment)
        self.assertEqual(host.hash_regular_file(archive), digest)
        self.assertEqual((archive.parent / 'Xcode.tar.sha256').read_text().strip(), digest)
        self.assertEqual(host.cached_xcode_archive(self.state, self.xcode, self.environment), (archive, digest))
        self.assertEqual(self.archives_created, 1)
        self.seal.write_bytes(b'new fixture seal')
        second, second_digest = host.cached_xcode_archive(self.state, self.xcode, self.environment)
        self.assertNotEqual(archive.parent, second.parent)
        self.assertNotEqual(digest, second_digest)
        self.assertEqual(self.archives_created, 2)

    def test_corrupt_cache_does_not_get_staged_or_silently_reaccepted(self):
        archive, _ = host.cached_xcode_archive(self.state, self.xcode, self.environment)
        archive.write_bytes(b'changed')
        with self.assertRaisesRegex(host.RunnerError, 'SHA-256 check'):
            host.cached_xcode_archive(self.state, self.xcode, self.environment)
        self.assertEqual(self.archives_created, 1)

    def test_wrong_xcode_version_is_rejected_before_any_archive_command(self):
        self.environment['xcode']['buildVersion'] = 'other-build'
        with self.assertRaisesRegex(host.RunnerError, 'pinned archive'):
            host.cached_xcode_archive(self.state, self.xcode, self.environment)
        self.assertEqual(self.archives_created, 0)

    def test_completed_internal_archive_can_be_published_without_regeneration(self):
        (self.state / 'tools').mkdir()
        completed = self.state / 'tools/Xcode.tar'
        completed.write_bytes(b'already completed internal archive')
        archive, digest = host.publish_completed_xcode_archive(self.state, self.xcode, self.environment, completed)
        self.assertFalse(completed.exists())
        self.assertEqual(host.cached_xcode_archive(self.state, self.xcode, self.environment), (archive, digest))
        self.assertEqual(self.archives_created, 0)

    def test_provisioning_stages_the_cached_archive_contract(self):
        exchange = self.root / 'exchange'
        exchange.mkdir()
        binaries = self.root / 'binaries'
        binaries.mkdir()
        (binaries / 'VMGuestAgent').write_bytes(b'fixture guest agent')
        args = SimpleNamespace(xcode=self.xcode, guest_user='wallet-test', provision_config=None, proof_key_bundle=None)
        config = host.stage_provisioning(args, self.state, exchange, self.environment, {'vmId': 'fixture'}, binaries)
        staged = exchange / 'provision/Xcode.tar'
        self.assertEqual(config['xcodeArchive'], {'path': 'Xcode.tar', 'sha256': host.hash_regular_file(staged)})
        self.assertEqual(host.read_json(exchange / 'provision/config.json')['xcodeArchive'], config['xcodeArchive'])
        self.assertEqual(self.archives_created, 1)


class AttestationAndTerminalTests(unittest.TestCase):
    def setUp(self):
        self.environment = {
            'node': {'version': '24.22.0', 'npmVersion': '11.16.0'}, 'jq': {'version': '1.8.1'},
            'xcode': {'version': '27.0', 'buildVersion': 'fixture-xcode'},
            'runtimes': [{'platform': 'iOS', 'version': '27.0', 'buildVersion': 'fixture-ios'},
                         {'platform': 'visionOS', 'version': '27.0', 'buildVersion': 'fixture-vision'}],
        }
        self.preflight = {
            'versions': {'node': 'v24.22.0', 'npm': '11.16.0', 'jq': 'jq-1.8.1'},
            'pinnedEnvironment': {'xcode': {'available': True, 'actual': dict(self.environment['xcode'])},
                'runtimes': {key: {'available': True, 'expected': {name: runtime[name] for name in ('version', 'buildVersion')}}
                             for key, runtime in zip(('ios', 'visionos'), self.environment['runtimes'])}},
        }

    def test_old_guest_pins_cannot_attest_new_host_pins(self):
        self.assertTrue(host.environment_attested(self.preflight, self.environment))
        for component in ('node', 'npm', 'jq', 'xcode', 'runtime'):
            with self.subTest(component=component):
                changed = json.loads(json.dumps(self.environment))
                if component == 'node': changed['node']['version'] = '25.0.0'
                elif component == 'npm': changed['node']['npmVersion'] = '12.0.0'
                elif component == 'jq': changed['jq']['version'] = '1.9.0'
                elif component == 'xcode': changed['xcode']['buildVersion'] = 'new-build'
                else: changed['runtimes'][0]['buildVersion'] = 'new-runtime-build'
                self.assertFalse(host.environment_attested(self.preflight, changed))

    def test_missing_or_unavailable_attestation_is_rejected(self):
        self.assertFalse(host.environment_attested({}, self.environment))
        self.preflight['pinnedEnvironment']['runtimes']['ios']['available'] = False
        self.assertFalse(host.environment_attested(self.preflight, self.environment))



class SetupViewerTests(unittest.TestCase):
    def test_viewer_is_opt_in_and_only_accepted_for_setup(self):
        self.assertFalse(host.parser().parse_args(['setup']).interactive)
        self.assertTrue(host.parser().parse_args(['setup', '--interactive']).interactive)
        for arguments in (['run', 'all', '--interactive'], ['setup', '--interactive', '--stage-only']):
            with self.subTest(arguments=arguments), patch('sys.stderr'), self.assertRaises(SystemExit) as error:
                host.parser().parse_args(arguments)
            self.assertEqual(error.exception.code, 2)

    def test_only_explicit_interactive_setup_passes_the_window_flag(self):
        for command, interactive, expected in (('setup', False, False), ('setup', True, True), ('run', True, False)):
            with self.subTest(command=command, interactive=interactive), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                exchange = root / 'exchange'
                (exchange / 'artifacts').mkdir(parents=True)
                class Child:
                    def poll(self): return 0
                args = SimpleNamespace(command=command, interactive=interactive, xcode=root / 'Xcode.app')
                viewer = root / 'Setup.app/Contents/MacOS/VMHost'
                with patch.object(host.subprocess, 'Popen', return_value=Child()) as launch, \
                        patch.object(host, 'setup_viewer_binary', return_value=viewer) as package:
                    host.monitor_vm(args, root, root / 'fixture.vbvm', exchange, 'fixture', root, {}, 1)
                self.assertEqual('--setup-window' in launch.call_args.args[0], expected)
                self.assertNotIn('--xcode', launch.call_args.args[0])
                self.assertEqual(package.called, expected)
                self.assertEqual(launch.call_args.args[0][0], str(viewer if expected else root / 'VMHost'))

    def test_app_wrapper_is_cached_without_mutating_the_cli_binary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'binaries/VMHost'
            source.parent.mkdir()
            source.write_bytes(b'original signed CLI fixture')
            signatures = []
            def codesign(command, **kwargs):
                values = [str(value) for value in command]
                self.assertEqual(values[0], '/usr/bin/codesign')
                bundle = Path(values[-1])
                if '--force' in values:
                    self.assertEqual(values[values.index('--identifier') + 1], 'org.lil.big-wallet.vm.setup-viewer')
                    self.assertIn('--entitlements', values)
                    executable = bundle / 'Contents/MacOS/VMHost'
                    self.assertFalse(executable.samefile(source))
                    with open(executable, 'ab') as file:
                        file.write(b' bundle-signature')
                    signatures.append(bundle)
                else:
                    self.assertEqual(values[1:3], ['--verify', '--strict'])
                return b''
            with patch.object(host, 'checked', side_effect=codesign):
                executable = host.setup_viewer_binary(root, source.parent)
                self.assertEqual(host.setup_viewer_binary(root, source.parent), executable)
            self.assertEqual(source.read_bytes(), b'original signed CLI fixture')
            self.assertEqual(len(signatures), 1)
            bundle = executable.parents[2]
            with open(bundle / 'Contents/Info.plist', 'rb') as file:
                metadata = plistlib.load(file)
            self.assertEqual(metadata['CFBundlePackageType'], 'APPL')
            self.assertEqual(metadata['CFBundleExecutable'], 'VMHost')
            self.assertEqual(metadata['CFBundleIdentifier'], 'org.lil.big-wallet.vm.setup-viewer')
            self.assertEqual(list(root.rglob('.build-*')), [])


class BuildToolCacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.tools = self.root / 'sources'
        self.tools.mkdir()
        for name in ('VMHost.swift', 'VMGuestAgent.swift', 'virtualization.entitlements'):
            (self.tools / name).write_text(name + ' fixture')
        self.state = self.root / 'state'
        self.state.mkdir()
        self.xcode = self.root / 'PinnedXcode.app'
        self.compiled = []
        self.signed = []
        self.fail_signing = False
        self.addCleanup(patch.stopall)
        patch.object(host, 'TOOLS', self.tools).start()
        patch.object(host, 'checked', side_effect=self.checked).start()

    def checked(self, command, **kwargs):
        command = [str(value) for value in command]
        if command == ['/usr/bin/xcrun', 'swiftc', '--version']:
            self.assertEqual(kwargs['env']['DEVELOPER_DIR'], str(self.xcode / 'Contents/Developer'))
            return b'Swift fixture version'
        if command[:2] == ['/usr/bin/xcrun', 'swiftc']:
            self.assertEqual(kwargs['env']['DEVELOPER_DIR'], str(self.xcode / 'Contents/Developer'))
            module = command[command.index('-module-name') + 1]
            output = Path(command[command.index('-o') + 1])
            source = Path(command[command.index('-o') - 1])
            self.assertEqual(source.name, module + '.swift')
            self.assertEqual(source.parent, output.parent)
            self.assertEqual(output.name, module)
            self.assertTrue(output.parent.name.startswith('.build-'))
            output.write_bytes(module.encode() + b'\0' + source.read_bytes())
            self.compiled.append(module)
            return b''
        self.assertEqual(command[0], '/usr/bin/codesign')
        identity = command[command.index('--identifier') + 1]
        self.assertIn(identity, ('org.lil.big-wallet.vm.VMHost', 'org.lil.big-wallet.vm.VMGuestAgent'))
        if self.fail_signing:
            self.fail_signing = False
            raise host.RunnerError('fixture signing failure')
        output = Path(command[-1])
        with open(output, 'ab') as file:
            file.write(b'\0' + identity.encode())
        self.signed.append(identity)
        return b''

    def test_host_and_entitlement_edits_reuse_the_identical_guest_binary(self):
        first = host.build_tools(self.state, self.xcode)
        guest_hash = host.hashlib.sha256((first / 'VMGuestAgent').read_bytes()).hexdigest()
        (self.tools / 'VMHost.swift').write_text('changed host source')
        second = host.build_tools(self.state, self.xcode)
        (self.tools / 'virtualization.entitlements').write_text('changed host entitlements')
        third = host.build_tools(self.state, self.xcode)
        self.assertEqual(self.compiled, ['VMHost', 'VMGuestAgent', 'VMHost', 'VMHost'])
        for collection in (second, third):
            self.assertTrue((collection / 'VMGuestAgent').samefile(first / 'VMGuestAgent'))
            self.assertEqual(host.hashlib.sha256((collection / 'VMGuestAgent').read_bytes()).hexdigest(), guest_hash)
        self.assertEqual(host.build_tools(self.state, self.xcode), third)
        self.assertEqual(len(self.compiled), 4)

    def test_guest_edit_reuses_the_identical_host_binary(self):
        first = host.build_tools(self.state, self.xcode)
        (self.tools / 'VMGuestAgent.swift').write_text('changed guest source')
        second = host.build_tools(self.state, self.xcode)
        self.assertEqual(self.compiled, ['VMHost', 'VMGuestAgent', 'VMGuestAgent'])
        self.assertTrue((first / 'VMHost').samefile(second / 'VMHost'))
        self.assertNotEqual((first / 'VMGuestAgent').read_bytes(), (second / 'VMGuestAgent').read_bytes())

    def test_failed_signing_cannot_publish_or_poison_the_cache(self):
        self.fail_signing = True
        with self.assertRaisesRegex(host.RunnerError, 'signing failure'):
            host.build_tools(self.state, self.xcode)
        self.assertEqual(list(self.state.rglob('.build-*')), [])
        self.assertEqual(list(self.state.rglob('VMHost')), [])
        output = host.build_tools(self.state, self.xcode)
        self.assertEqual(self.compiled, ['VMHost', 'VMHost', 'VMGuestAgent'])
        self.assertTrue((output / 'VMHost').is_file())
        self.assertTrue((output / 'VMGuestAgent').is_file())

    def test_mutating_live_compile_and_signing_inputs_cannot_poison_their_original_cache_keys(self):
        agent = self.tools / 'VMGuestAgent.swift'
        entitlements = self.tools / 'virtualization.entitlements'
        original_agent, original_entitlements = agent.read_bytes(), entitlements.read_bytes()
        signed_entitlements = []
        def mutate_then_execute(command, **options):
            if command[:2] == ['/usr/bin/xcrun', 'swiftc'] and '-module-name' in command:
                module = command[command.index('-module-name') + 1]
                if module == 'VMHost':
                    entitlements.write_bytes(b'changed entitlements during compile')
                else:
                    agent.write_bytes(b'changed guest source during compile')
            if '--entitlements' in command:
                captured = Path(command[command.index('--entitlements') + 1])
                self.assertNotEqual(captured, entitlements)
                signed_entitlements.append(captured.read_bytes())
            return self.checked(command, **options)
        with patch.object(host, 'checked', side_effect=mutate_then_execute):
            first = host.build_tools(self.state, self.xcode)
        self.assertIn(original_agent, (first / 'VMGuestAgent').read_bytes())
        self.assertNotIn(b'changed guest source', (first / 'VMGuestAgent').read_bytes())
        self.assertEqual(signed_entitlements, [original_entitlements])
        agent.write_bytes(original_agent)
        entitlements.write_bytes(original_entitlements)
        self.assertEqual(host.build_tools(self.state, self.xcode), first)
        self.assertEqual(self.compiled, ['VMHost', 'VMGuestAgent'])


if __name__ == '__main__':
    unittest.main()
