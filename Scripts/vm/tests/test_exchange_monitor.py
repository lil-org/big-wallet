from contextlib import ExitStack
import importlib.util
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('exchange_monitor_host', Path(__file__).resolve().parents[1] / 'host.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class ExchangeMonitorTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.run_id, self.exchange = host.new_exchange(self.root, 'run')
        self.result_path = self.exchange / 'artifacts/result.json'
        self.events = []
        self.clock = 0
        self.vm = SimpleNamespace(returncode=None)
        self.vm.poll = lambda: self.vm.returncode
        self.hook = SimpleNamespace(exchange_complete=False, polls=0, stopped=False)
        self.hook.poll = self.poll
        self.hook.request_stop = self.request_stop
        self.hook.notify_guest_finished = lambda: self.events.append('guest-finished')
        self.hook.cancel = lambda: self.events.append('cancel-transfer')
        self.on_poll = lambda _: None
        host.atomic_json(self.exchange / 'snapshot-manifest.json', {'version': 1, 'files': []})
        self.source = {'sha256': host.hash_regular_file(self.exchange / 'snapshot-manifest.json'), 'commit': 'a' * 40}
        self.job = {'runId': self.run_id, 'vmId': 'fixture-vm', 'kind': 'run', 'profile': 'extended', 'source': self.source}
        host.atomic_json(self.exchange / 'job.json', self.job)
        host.atomic_json(self.exchange / 'artifacts/planned-result.json', {
            **self.job, 'origin': 'host-plan', 'status': 'planned',
            'jobSHA256': host.hash_regular_file(self.exchange / 'job.json'),
            'stages': [{'id': 'repository.fixture', 'status': 'pending'}, {'id': 'test.fixture', 'status': 'pending'}]})

    def poll(self):
        self.hook.polls += 1
        self.events.append('poll-transfer')
        return self.on_poll(self.hook.polls)

    def request_stop(self):
        self.hook.stopped = True
        self.events.append('request-stop')

    def sleep(self, seconds):
        self.clock += seconds
        self.assertLess(self.clock, 150, 'The fixture monitor must finish within its simulated deadline')

    def stop_vm(self, process, stop_file):
        self.assertIs(process, self.vm)
        self.assertEqual(stop_file, self.exchange / 'vm-stop')
        self.events.append('stop-vm')
        self.vm.returncode = 0

    def report(self, status='passed', *, terminal=True):
        value = {**self.job, 'version': 1, 'status': status, 'stages': [
            {'id': 'repository.fixture', 'status': 'passed'},
            {'id': 'test.fixture', 'status': status if status != 'running' else 'pending'}],
            'summary': {'status': status, 'issues': []},
            'coverage': {'status': 'complete' if status == 'passed' else 'partial', 'fullSuiteVerified': status == 'passed'}}
        if terminal:
            value['finishedAt'] = 'fixture completion'
        host.atomic_json(self.result_path, value)
        return value

    def terminal_event(self, kind='jobFinished', *, run_id=None):
        event = {'type': kind, 'runId': self.run_id if run_id is None else run_id, 'exitCode': 0}
        host.atomic_json(self.exchange / 'vm-status.json', {'lastGuestEvent': event})
        return event

    def run_monitor(self, timeout=100):
        with ExitStack() as stack:
            launch = stack.enter_context(patch.object(host.subprocess, 'Popen', return_value=self.vm))
            stack.enter_context(patch.object(host.time, 'monotonic', side_effect=lambda: self.clock))
            stack.enter_context(patch.object(host.time, 'sleep', side_effect=self.sleep))
            stack.enter_context(patch.object(host, 'check_capacity', side_effect=lambda *_: self.events.append('capacity')))
            stack.enter_context(patch.object(host, 'stop_owned_process', side_effect=self.stop_vm))
            result = host.monitor_vm(SimpleNamespace(command='run'), self.root, self.root / 'owned.vbvm',
                self.exchange, self.run_id, self.root / 'tools', {'minimumHostFreeBytes': 1}, timeout, setup_hook=self.hook, keep_operation=True)
        active = host.read_json(self.root / 'active.json')
        self.assertEqual(active['acceptedResultSHA256'], host.hash_regular_file(self.result_path))
        if self.hook.exchange_complete:
            self.assertIs(active['artifactsExported'], True)
        else:
            self.assertNotIn('artifactsExported', active)
        host.clear_owned_operation(self.root, self.run_id)
        self.assertFalse((self.root / 'active.json').exists())
        if launch.called:
            command = launch.call_args.args[0]
            self.assertNotIn('--setup-window', command)
            self.assertNotIn('--provision-password-file', command)
        return result

    def test_job_finished_and_terminal_json_wait_for_artifact_export(self):
        self.terminal_event()

        def progress(count):
            if count == 1:
                self.report()
            if count == 3:
                (self.exchange / 'artifacts/test.fixture.log').write_text('complete exported log')
                self.hook.exchange_complete = True

        self.on_poll = progress
        result = self.run_monitor()
        self.assertEqual(result['status'], 'passed')
        self.assertNotIn('hostTermination', result)
        self.assertEqual(self.hook.polls, 3)
        self.assertEqual(self.events.count('capacity'), 2)
        self.assertIn('guest-finished', self.events)
        self.assertNotIn('request-stop', self.events)
        self.assertEqual(self.events[-2:], ['cancel-transfer', 'stop-vm'])
        self.assertEqual((self.exchange / 'artifacts/test.fixture.log').read_text(), 'complete exported log')

    def test_exported_guest_failure_is_preserved_without_transport_failure(self):
        def finish(_):
            self.report('failed')
            self.hook.exchange_complete = True

        self.on_poll = finish
        result = self.run_monitor()
        self.assertEqual(result['status'], 'failed')
        self.assertNotIn('hostTermination', result)
        self.assertNotIn('guestFailure', result)
        self.assertNotIn('request-stop', self.events)

    def test_export_failure_never_accepts_an_unexported_terminal_report(self):
        self.report()
        failure = {'status': 'failed', 'reason': 'artifact_archive_truncated', 'phase': 'extract'}
        self.on_poll = lambda _: failure
        result = self.run_monitor()
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['reason'], 'guest_exchange_failed')
        self.assertEqual(result['guestFailure'], failure)
        self.assertEqual(result['coverage']['status'], 'partial')
        self.assertFalse(result['coverage']['fullSuiteVerified'])
        self.assertEqual(host.read_json(self.exchange / 'artifacts/guest-result-after-stop.json')['status'], 'passed')
        self.assertIn('request-stop', self.events)
        self.assertEqual(self.events[-2:], ['cancel-transfer', 'stop-vm'])

    def test_transfer_failure_preserves_planned_inventory_without_guest_report(self):
        self.on_poll = lambda _: {'status': 'failed', 'reason': 'upload_failed'}
        result = self.run_monitor()
        self.assertEqual(result['plannedResult'], 'planned-result.json')
        self.assertEqual(result['source'], self.source)
        self.assertEqual([stage['id'] for stage in result['stages']], ['repository.fixture', 'test.fixture'])
        self.assertTrue(all(stage['status'] == 'blocked' for stage in result['stages']))
        self.assertEqual(result['reason'], 'guest_exchange_failed')

    def test_agent_error_remains_terminal_while_exchange_is_pending(self):
        event = self.terminal_event('agentError')
        result = self.run_monitor()
        self.assertEqual(result['reason'], 'guest_launch_failed')
        self.assertEqual(result['guestFailure'], event)
        self.assertNotIn('guest-finished', self.events)
        self.assertNotIn('capacity', self.events)
        self.assertIn('request-stop', self.events)

    def test_unrelated_completion_cannot_signal_current_transfer(self):
        self.terminal_event(run_id='another-run')

        def finish(count):
            if count == 2:
                self.report()
                self.hook.exchange_complete = True

        self.on_poll = finish
        result = self.run_monitor()
        self.assertEqual(result['status'], 'passed')
        self.assertNotIn('guest-finished', self.events)

    def test_vm_exit_cannot_accept_terminal_report_before_export(self):
        self.report()
        self.vm.returncode = 0
        result = self.run_monitor()
        self.assertEqual(result['reason'], 'vm_exited')
        self.assertNotEqual(result['status'], 'passed')
        self.assertEqual(self.hook.polls, 0)
        self.assertEqual(self.events, ['cancel-transfer'])

    def test_stop_drains_export_before_cancel_and_cannot_become_late_success(self):
        def finish(count):
            if count == 1:
                host.atomic_json(self.exchange / 'stop.json', {'runId': self.run_id})
            elif self.hook.stopped:
                self.report()
                (self.exchange / 'artifacts/cancel.log').write_text('guest cancellation diagnostics')
                self.hook.exchange_complete = True

        self.on_poll = finish
        result = self.run_monitor()
        self.assertEqual(result['status'], 'cancelled')
        self.assertEqual(result['reason'], 'cancelled')
        request = self.events.index('request-stop')
        self.assertEqual(self.events[request:], ['request-stop', 'poll-transfer', 'cancel-transfer', 'stop-vm'])
        self.assertEqual(host.read_json(self.exchange / 'artifacts/guest-result-after-stop.json')['status'], 'passed')
        self.assertTrue((self.exchange / 'artifacts/cancel.log').exists())

    def test_timeout_during_export_cannot_become_late_success(self):
        def finish(count):
            if count == 1:
                self.report()
                self.clock = 100
            elif self.hook.stopped:
                self.hook.exchange_complete = True

        self.on_poll = finish
        result = self.run_monitor()
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['reason'], 'timed_out')
        self.assertFalse(result['coverage']['fullSuiteVerified'])
        self.assertEqual(host.read_json(self.exchange / 'artifacts/guest-result-after-stop.json')['status'], 'passed')

    def test_cancel_grace_is_bounded_when_guest_never_returns_a_report(self):
        result = self.run_monitor(timeout=0)
        self.assertEqual(result['reason'], 'timed_out')
        self.assertEqual(self.clock, 20)
        self.assertEqual(self.hook.polls, 20)
        self.assertEqual(self.events[0], 'request-stop')
        self.assertEqual(self.events[-2:], ['cancel-transfer', 'stop-vm'])


if __name__ == '__main__':
    unittest.main()
