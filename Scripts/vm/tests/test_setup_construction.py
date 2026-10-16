import contextlib
import importlib.util
import io
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('setup_construction_host', Path(__file__).resolve().parents[1] / 'host.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class SetupConstructionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.state = Path(self.temporary.name).resolve()
        self.original = self.state / 'original.vbvm'
        self.candidate = self.state / 'candidate.vbvm'
        self.record_path = self.state / 'candidate.json'
        self.environment = {'minimumHostFreeBytes': 1, 'buildData': {'bytes': 1024}}
        self.clone_failure = None
        self.storage_failure = None
        self.clones = []
        self.selected_users = []
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        for name, result in [('validate_vm', {}), ('check_capacity', None), ('build_tools', self.state / 'tools'),
                             ('guest_tool_hashes', {}), ('configure_guest_hardware', None),
                             ('snapshot_source', {'sha256': 'a' * 64, 'commit': 'b' * 40}),
                             ('environment_attested', False), ('verify_setup_sources', None)]:
            self.stack.enter_context(patch.object(host, name, return_value=result))
        self.idle = self.stack.enter_context(patch.object(host, 'ensure_disk_idle'))
        self.clone = self.stack.enter_context(patch.object(host, 'clone_vm', side_effect=self.copy_candidate))
        self.stack.enter_context(patch.object(host, 'configure_build_storage', side_effect=self.build_storage))
        self.stack.enter_context(patch.object(host, 'stage_provisioning', side_effect=self.stage))
        self.stack.enter_context(patch.object(host, 'monitor_vm', side_effect=AssertionError('No VM may start')))
        self.stack.enter_context(patch.object(host, 'guest_access_module', side_effect=AssertionError('No disk access or SSH in construction fixtures')))
        self.stack.enter_context(patch('sys.stdout', new=io.StringIO()))

    def args(self, *options):
        return host.parser().parse_args(['--vm', str(self.original), 'setup', '--stage-only', *options])

    def copy_candidate(self, source, destination):
        self.assertFalse(destination.exists())
        record = host.read_json(self.record_path)
        self.assertIs(record['constructionPending'], True)
        self.clones.append((source, record['vmId']))
        (destination / '.vbdata').mkdir(parents=True)
        (destination / 'Disk.img').write_bytes(b'copied fixture disk')
        (destination / '.vbdata/Metadata.plist').write_bytes(plistlib.dumps({'uuid': 'original-identity'}))
        if self.clone_failure:
            raise self.clone_failure

    def build_storage(self, candidate, byte_count):
        if self.storage_failure:
            raise self.storage_failure
        return True

    def stage(self, args, state, exchange, environment, record, binaries):
        user = host.selected_console_user(args, record)
        self.selected_users.append(user)
        return {'vmId': record['vmId'], 'consoleUser': user}

    def test_partial_copy_failure_and_interrupt_are_rebuilt_with_the_same_identity_and_user(self):
        for failure in (host.RunnerError('copy failed'), KeyboardInterrupt()):
            with self.subTest(failure=type(failure).__name__):
                self.clone_failure = failure
                if isinstance(failure, KeyboardInterrupt):
                    self.assertEqual(host.setup(self.args('--guest-user', 'selected-user'), self.state, self.environment), 2)
                else:
                    with self.assertRaises(type(failure)):
                        host.setup(self.args('--guest-user', 'selected-user'), self.state, self.environment)
                pending = host.read_json(self.record_path)
                self.assertIs(pending['constructionPending'], True)
                self.assertTrue((self.candidate / 'Disk.img').exists())
                self.clone_failure = None
                self.assertEqual(host.setup(self.args(), self.state, self.environment), 2)
                completed = host.read_json(self.record_path)
                self.assertEqual(completed['vmId'], pending['vmId'])
                self.assertNotIn('constructionPending', completed)
                self.assertNotIn('constructionConsoleUser', completed)
                self.assertEqual(self.selected_users[-1], 'selected-user')
                with host.open_regular(self.candidate / '.vbdata/Metadata.plist') as file:
                    self.assertEqual(plistlib.load(file)['uuid'], pending['vmId'])
                self.idle.assert_any_call(self.candidate)
                host.shutil.rmtree(self.candidate)
                self.record_path.unlink()

    def test_storage_or_metadata_failure_keeps_recoverable_construction_ownership(self):
        for phase in ('storage', 'metadata'):
            with self.subTest(phase=phase):
                self.storage_failure = OSError('storage failed') if phase == 'storage' else None
                with contextlib.ExitStack() as stack:
                    if phase == 'metadata':
                        stack.enter_context(patch.object(host.plistlib, 'dump', side_effect=OSError('metadata failed')))
                    with self.assertRaises(OSError):
                        host.setup(self.args(), self.state, self.environment)
                pending = host.read_json(self.record_path)
                self.assertTrue(pending['constructionPending'])
                self.storage_failure = None
                self.assertEqual(host.setup(self.args(), self.state, self.environment), 2)
                self.assertEqual(host.read_json(self.record_path)['vmId'], pending['vmId'])
                host.shutil.rmtree(self.candidate)
                self.record_path.unlink()

    def test_next_invocation_recovers_durable_ownership_after_abrupt_process_loss(self):
        host.atomic_json(self.record_path, {'version': 1, 'vmId': 'retained-vm', 'sourceVM': str(self.original),
            'environment': self.environment, 'constructionPending': True, 'constructionConsoleUser': 'retained-user',
            'consoleUser': 'baseline-user'})
        self.candidate.mkdir()
        (self.candidate / 'Disk.img').write_bytes(b'incomplete copy')
        self.assertEqual(host.setup(self.args(), self.state, self.environment), 2)
        self.assertEqual(self.clones, [(self.original, 'retained-vm')])
        self.assertEqual(self.selected_users, ['retained-user'])
        self.assertEqual(host.read_json(self.record_path)['consoleUser'], 'baseline-user')

    def test_unrecorded_candidate_is_never_adopted_or_removed(self):
        self.candidate.mkdir()
        sentinel = self.candidate / 'unowned-file'
        sentinel.write_bytes(b'preserve')
        with self.assertRaisesRegex(host.RunnerError, 'Unrecorded candidate'):
            host.setup(self.args(), self.state, self.environment)
        self.assertEqual(sentinel.read_bytes(), b'preserve')
        self.assertFalse(self.record_path.exists())
        self.clone.assert_not_called()
        self.idle.assert_not_called()

    def test_unrecorded_or_mismatched_baseline_is_preserved_before_construction_or_retry(self):
        baseline = self.state / 'baseline.vbvm'
        baseline.mkdir()
        (baseline / 'Disk.img').write_bytes(b'unowned baseline')
        self.original.mkdir()
        (self.original / 'Disk.img').write_bytes(b'original')
        baseline_record_path = self.state / 'baseline.json'
        for baseline_record in (None, {}, {'sourceVM': str(self.state / 'another.vbvm')}):
            for retry in (False, True):
                with self.subTest(baseline_record=baseline_record, retry=retry):
                    if baseline_record is not None:
                        host.atomic_json(baseline_record_path, baseline_record)
                    if retry:
                        pending = {'version': 1, 'vmId': 'retained-vm', 'sourceVM': str(self.original),
                                   'constructionPending': True, 'constructionConsoleUser': 'retained-user'}
                        host.atomic_json(self.record_path, pending)
                        self.candidate.mkdir()
                        (self.candidate / 'Disk.img').write_bytes(b'incomplete copy')
                    message = 'Unrecorded baseline' if baseline_record is None else 'Baseline belongs to another source VM'
                    with self.assertRaisesRegex(host.RunnerError, message):
                        host.setup(self.args(), self.state, self.environment)
                    self.assertEqual((baseline / 'Disk.img').read_bytes(), b'unowned baseline')
                    self.assertEqual((self.original / 'Disk.img').read_bytes(), b'original')
                    self.clone.assert_not_called()
                    self.idle.assert_not_called()
                    if retry:
                        self.assertEqual(host.read_json(self.record_path), pending)
                        self.assertEqual((self.candidate / 'Disk.img').read_bytes(), b'incomplete copy')
                        host.shutil.rmtree(self.candidate)
                        self.record_path.unlink()
                    else:
                        self.assertFalse(self.record_path.exists())
                        self.assertFalse(self.candidate.exists())
                    if baseline_record is not None:
                        self.assertEqual(host.read_json(baseline_record_path), baseline_record)
                        baseline_record_path.unlink()

    def test_matching_baseline_is_reused_after_partial_copy_failure(self):
        baseline = self.state / 'baseline.vbvm'
        baseline.mkdir()
        (baseline / 'Disk.img').write_bytes(b'prepared baseline')
        host.atomic_json(self.state / 'baseline.json', {'version': 1, 'vmId': 'baseline-vm',
            'sourceVM': str(self.original), 'consoleUser': 'baseline-user'})
        self.clone_failure = host.RunnerError('copy failed')
        with self.assertRaisesRegex(host.RunnerError, 'copy failed'):
            host.setup(self.args(), self.state, self.environment)
        self.clone_failure = None
        self.assertEqual(host.setup(self.args(), self.state, self.environment), 2)
        self.assertEqual(self.clones, [(baseline, 'baseline-vm'), (baseline, 'baseline-vm')])
        self.assertEqual(self.selected_users, ['baseline-user'])
        self.assertEqual((baseline / 'Disk.img').read_bytes(), b'prepared baseline')
        self.assertNotIn('constructionPending', host.read_json(self.record_path))

    def test_busy_or_replaced_partial_candidate_is_preserved_with_its_marker(self):
        self.clone_failure = KeyboardInterrupt()
        self.assertEqual(host.setup(self.args(), self.state, self.environment), 2)
        pending = host.read_json(self.record_path)
        self.idle.side_effect = host.RunnerError('disk busy')
        with self.assertRaisesRegex(host.RunnerError, 'disk busy'):
            host.setup(self.args(), self.state, self.environment)
        self.assertEqual(host.read_json(self.record_path), pending)
        self.assertTrue((self.candidate / 'Disk.img').exists())
        host.shutil.rmtree(self.candidate)
        outside = self.state / 'outside.vbvm'
        outside.mkdir()
        self.candidate.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(host.RunnerError, 'changed type'):
            host.setup(self.args(), self.state, self.environment)
        self.assertTrue(outside.exists())
        self.assertEqual(host.read_json(self.record_path), pending)


if __name__ == '__main__':
    unittest.main()
