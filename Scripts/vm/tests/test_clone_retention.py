import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('clone_retention_host', Path(__file__).resolve().parents[1] / 'host.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class CloneRetentionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.run_id, self.exchange = host.new_exchange(self.root, 'run')
        self.clone = self.root / 'runs' / (self.run_id + '.vbvm')
        self.active_path = self.root / 'active.json'
        self.receipt = self.exchange / 'retained-vm.json'
        self.result_path = self.exchange / 'artifacts/result.json'
        output = patch('sys.stdout', new=io.StringIO())
        output.start()
        self.addCleanup(output.stop)

    def make_clone(self):
        self.clone.mkdir(parents=True)
        (self.clone / 'BuildData.img').write_bytes(b'guest-only test log and xcresult fixture')

    def activate(self, *, phase='starting', exported=None, accepted=False):
        host.register_operation(self.root, self.clone, self.exchange, self.run_id, phase, clone_owned=True)
        active = host.read_json(self.active_path)
        if phase is None:
            active.pop('phase')
        if exported is not None:
            active['artifactsExported'] = exported
        if accepted:
            active['acceptedResultSHA256'] = host.hash_regular_file(self.result_path)
        host.atomic_json(self.active_path, active)
        return active

    def report(self, status='failed'):
        result = {'version': 1, 'runId': self.run_id, 'status': status, 'finishedAt': 'fixture', 'stages': []}
        host.atomic_json(self.result_path, result)
        return result

    def assert_retained(self):
        self.assertEqual((self.clone / 'BuildData.img').read_bytes(), b'guest-only test log and xcresult fixture')
        self.assertEqual(host.read_json(self.receipt), {'version': 1, 'runId': self.run_id,
            'vm': str(self.clone), 'reason': 'artifacts_not_collected'})

    def reconcile(self):
        with patch.object(host, 'ensure_disk_idle') as idle:
            host.reconcile_interrupted_operation(self.root)
        idle.assert_called_once_with(self.clone)

    def test_reconciliation_retains_missing_or_unknown_export_evidence_despite_accepted_report(self):
        for phase in ('starting', 'unknown', None):
            for exported in (None, False, 1, 'true'):
                with self.subTest(phase=phase, exported=exported):
                    if not self.clone.exists():
                        self.make_clone()
                    original = self.report()
                    self.activate(phase=phase, exported=exported, accepted=True)
                    self.reconcile()
                    self.assert_retained()
                    self.assertEqual(host.read_json(self.result_path), original)
                    self.assertFalse(self.active_path.exists())
                    with patch.object(host, 'ensure_disk_idle', side_effect=AssertionError('No active VM remains')):
                        host.reconcile_interrupted_operation(self.root)
                    self.assert_retained()

    def test_prelaunch_or_verified_export_clones_are_removed_during_reconciliation(self):
        for phase, exported in (('preparing', None), ('starting', True), (None, True)):
            with self.subTest(phase=phase, exported=exported):
                self.make_clone()
                self.report('failed')
                self.activate(phase=phase, exported=exported, accepted=True)
                self.reconcile()
                self.assertFalse(self.clone.exists())
                self.assertFalse(self.receipt.exists())
                self.assertFalse(self.active_path.exists())

    def test_retention_receipt_failure_keeps_recovery_ownership_until_retry(self):
        self.make_clone()
        self.report()
        self.activate(accepted=True)
        write = host.atomic_json
        def fail_receipt(path, value):
            if Path(path) == self.receipt:
                raise OSError('fixture retention receipt unavailable')
            return write(path, value)
        with patch.object(host, 'atomic_json', side_effect=fail_receipt):
            with self.assertRaisesRegex(OSError, 'retention receipt unavailable'):
                self.reconcile()
        self.assertTrue(self.active_path.exists())
        self.assertTrue(self.clone.exists())
        self.assertFalse(self.receipt.exists())
        self.reconcile()
        self.assert_retained()
        self.assertFalse(self.active_path.exists())

    def test_operation_handoff_clears_export_and_acceptance_evidence(self):
        self.report()
        self.activate(exported=True, accepted=True)
        next_id, next_exchange = host.new_exchange(self.root, 'run')
        host.register_operation(self.root, self.clone, next_exchange, next_id, 'preparing',
            previous=(self.run_id, self.exchange))
        active = host.read_json(self.active_path)
        self.assertEqual(active['runId'], next_id)
        self.assertEqual(active['exchange'], str(next_exchange))
        self.assertNotIn('artifactsExported', active)
        self.assertNotIn('acceptedResultSHA256', active)

    @contextlib.contextmanager
    def run_fixture(self, *, status='failed', exported=False, crash=False):
        args = host.parser().parse_args(['--vm', str(self.root / 'original.vbvm'), 'run', '--stage', 'worker'])
        environment = {'minimumHostFreeBytes': 1}
        host.atomic_json(self.root / 'baseline.json', {'vmId': 'fixture-vm', 'sourceVM': str(args.vm),
            'environment': environment, 'bootstrapSourceDigest': 'fixture-digest', 'bootstrapTools': {}})
        def clone(source, destination):
            self.assertEqual(destination, self.clone)
            self.make_clone()
        def monitor(*arguments, **options):
            host.register_operation(self.root, self.clone, self.exchange, self.run_id, 'starting')
            if crash:
                raise OSError('fixture host lost the VM before artifact export')
            result = self.report(status)
            active = host.read_json(self.active_path)
            active['acceptedResultSHA256'] = host.hash_regular_file(self.result_path)
            if exported:
                (self.exchange / 'artifacts/test.log').write_text('verified exported diagnostics')
                active['artifactsExported'] = True
            host.atomic_json(self.active_path, active)
            return result
        with contextlib.ExitStack() as stack:
            replacements = {'bootstrap_source_digest': {'return_value': 'fixture-digest'},
                'check_capacity': {}, 'build_tools': {'return_value': self.root / 'tools'},
                'bootstrap_tool_hashes': {'return_value': {}}, 'new_exchange': {'return_value': (self.run_id, self.exchange)},
                'snapshot_source': {'return_value': {'sha256': 'a' * 64}}, 'stage_planned_result': {},
                'clone_vm': {'side_effect': clone}, 'prepared_guest_hook': {'return_value': None},
                'monitor_vm': {'side_effect': monitor}, 'ensure_disk_idle': {}}
            for name, options in replacements.items():
                stack.enter_context(patch.object(host, name, **options))
            yield args, environment

    def test_run_cleanup_retains_unexported_failure_and_survives_next_reconciliation(self):
        with self.run_fixture() as (args, environment):
            self.assertEqual(host.run_tests(args, self.root, environment), 1)
        self.assert_retained()
        self.assertFalse(self.active_path.exists())
        host.reconcile_interrupted_operation(self.root)
        self.assert_retained()

    def test_run_cleanup_does_not_retain_exported_failed_or_cancelled_tests(self):
        for status in ('passed', 'failed', 'blocked', 'cancelled'):
            with self.subTest(status=status):
                with self.run_fixture(status=status, exported=True) as (args, environment):
                    self.assertEqual(host.run_tests(args, self.root, environment), 0 if status == 'passed' else 1)
                self.assertFalse(self.clone.exists())
                self.assertFalse(self.active_path.exists())
                self.assertFalse(self.receipt.exists())
                self.assertEqual((self.exchange / 'artifacts/test.log').read_text(), 'verified exported diagnostics')

    def test_cleanup_failure_still_reports_the_archived_result(self):
        observed = []
        failure = OSError('fixture clone cleanup failed')
        with self.run_fixture(status='passed', exported=True) as (args, environment), \
                patch.object(host.shutil, 'rmtree', side_effect=failure):
            with self.assertRaises(OSError) as raised:
                host.run_tests(args, self.root, environment, result_callback=lambda *value: observed.append(value))
        self.assertIs(raised.exception, failure)
        self.assertEqual(observed, [(self.result_path, host.read_json(self.result_path))])
        self.assertEqual(observed[0][1]['status'], 'passed')
        self.assertTrue(self.active_path.exists())
        self.assertTrue(self.clone.exists())

    def test_reporting_failure_cannot_skip_clone_cleanup(self):
        def report(*args):
            raise ValueError('fixture callback failed')
        with self.run_fixture(status='passed', exported=True) as (args, environment):
            with self.assertRaisesRegex(ValueError, 'callback failed'):
                host.run_tests(args, self.root, environment, result_callback=report)
        self.assertFalse(self.clone.exists())
        self.assertFalse(self.active_path.exists())

    def test_reporting_failure_preserves_the_original_monitor_exception(self):
        observed = []
        failure = OSError('fixture monitor failed after result')
        def report(*args):
            observed.append(args)
            raise ValueError('fixture callback failed')
        with self.run_fixture(status='passed', exported=True) as (args, environment):
            monitor = host.monitor_vm.side_effect
            def fail_after_result(*args, **kwargs):
                monitor(*args, **kwargs)
                raise failure
            host.monitor_vm.side_effect = fail_after_result
            with self.assertRaises(OSError) as raised:
                host.run_tests(args, self.root, environment, result_callback=report)
        self.assertIs(raised.exception, failure)
        self.assertEqual(observed, [(self.result_path, host.read_json(self.result_path))])
        self.assertFalse(self.clone.exists())
        self.assertTrue(self.active_path.exists())

    def test_interrupted_run_keeps_guest_disk_through_reconciliation(self):
        with self.run_fixture(crash=True) as (args, environment):
            with self.assertRaisesRegex(OSError, 'lost the VM'):
                host.run_tests(args, self.root, environment)
        self.assert_retained()
        self.assertTrue(self.active_path.exists())
        self.reconcile()
        self.assert_retained()
        self.assertFalse(self.active_path.exists())
        self.assertEqual(host.read_json(self.result_path)['reason'], 'host_runner_interrupted')

    def test_run_cleanup_preserves_clone_if_active_ownership_changes(self):
        with self.run_fixture() as (args, environment):
            monitor = host.monitor_vm.side_effect
            def changed_owner(*arguments, **options):
                result = monitor(*arguments, **options)
                active = host.read_json(self.active_path)
                active['ownerPID'] += 1
                host.atomic_json(self.active_path, active)
                return result
            host.monitor_vm.side_effect = changed_owner
            with self.assertRaisesRegex(host.RunnerError, 'Another operation owns the clone'):
                host.run_tests(args, self.root, environment)
        self.assertEqual((self.clone / 'BuildData.img').read_bytes(), b'guest-only test log and xcresult fixture')
        self.assertTrue(self.active_path.exists())
        self.assertFalse(self.receipt.exists())

    def test_run_retention_receipt_failure_preserves_active_clone_for_reconciliation(self):
        write = host.atomic_json
        def fail_receipt(path, value):
            if Path(path) == self.receipt:
                raise OSError('fixture retention receipt unavailable')
            return write(path, value)
        with self.run_fixture() as (args, environment), patch.object(host, 'atomic_json', side_effect=fail_receipt):
            with self.assertRaisesRegex(OSError, 'retention receipt unavailable'):
                host.run_tests(args, self.root, environment)
        self.assertTrue(self.clone.exists())
        self.assertTrue(self.active_path.exists())
        self.assertFalse(self.receipt.exists())
        self.reconcile()
        self.assert_retained()
        self.assertFalse(self.active_path.exists())


if __name__ == '__main__':
    unittest.main()
