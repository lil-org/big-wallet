from contextlib import ExitStack
import importlib.util
from pathlib import Path
import tempfile
import signal
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
        self.capacity = lambda: self.events.append('capacity')
        self.clock = 0
        self.maximum_clock = 150
        self.vm = SimpleNamespace(returncode=None)
        self.vm.poll = lambda: self.vm.returncode
        self.hook = SimpleNamespace(exchange_complete=False, polls=0, stopped=False)
        self.hook.poll = self.poll
        self.hook.request_stop = self.request_stop
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
        self.assertLess(self.clock, self.maximum_clock, 'The fixture monitor must finish within its simulated deadline')

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

    def run_monitor(self, timeout=100, *, previous_stops=()):
        with ExitStack() as stack:
            launch = stack.enter_context(patch.object(host.subprocess, 'Popen', return_value=self.vm))
            stack.enter_context(patch.object(host.time, 'monotonic', side_effect=lambda: self.clock))
            stack.enter_context(patch.object(host.time, 'sleep', side_effect=self.sleep))
            stack.enter_context(patch.object(host, 'check_capacity', side_effect=lambda *_: self.capacity()))
            stack.enter_context(patch.object(host, 'stop_owned_process', side_effect=self.stop_vm))
            result = host.monitor_vm(SimpleNamespace(command='run'), self.root, self.root / 'owned.vbvm',
                self.exchange, self.run_id, self.root / 'tools', {'minimumHostFreeBytes': 1}, timeout,
                setup_hook=self.hook, keep_operation=True, previous_stops=previous_stops)
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
        self.assertNotIn('request-stop', self.events)
        self.assertEqual(self.events[-2:], ['cancel-transfer', 'stop-vm'])
        self.assertEqual((self.exchange / 'artifacts/test.fixture.log').read_text(), 'complete exported log')

    def test_vm_launch_failure_does_not_claim_artifacts_were_exported(self):
        with patch.object(host.subprocess, 'Popen', side_effect=OSError('fixture launch failed')):
            result = host.monitor_vm(SimpleNamespace(command='run'), self.root, self.root / 'owned.vbvm',
                self.exchange, self.run_id, self.root / 'tools', {'minimumHostFreeBytes': 1}, 100,
                setup_hook=self.hook, keep_operation=True)
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['reason'], 'vm_launch_failed')
        active = host.read_json(self.root / 'active.json')
        self.assertEqual(active['phase'], 'starting')
        self.assertNotIn('artifactsExported', active)

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

    def test_guest_launch_and_exit_failures_remain_terminal(self):
        for reason in ('guest_launch_failed', 'guest_exited_without_result'):
            with self.subTest(reason=reason):
                for name in ('stop.json', 'vm-stop', 'artifacts/result.json'):
                    (self.exchange / name).unlink(missing_ok=True)
                self.vm.returncode = None
                failure = {'status': 'failed', 'reason': reason}
                self.on_poll = lambda _: failure
                result = self.run_monitor()
                self.assertEqual(result['reason'], reason)
                self.assertEqual(result['guestFailure'], failure)
                self.assertIn('request-stop', self.events)

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
                host.publish_stop(self.exchange, self.run_id, requested=True)
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

    def test_stop_preserves_a_long_export_and_extraction_after_guest_finalization(self):
        self.maximum_clock = 3500
        self.hook.transport = SimpleNamespace(phase='report', observed_launch=True, final_seen=False)
        def progress(count):
            if count == 1:
                self.report('running', terminal=False)
                host.publish_stop(self.exchange, self.run_id, requested=True)
            elif self.hook.stopped and self.clock >= 100:
                self.hook.transport.final_seen = True
                self.hook.transport.phase = 'export' if self.clock < 1850 else 'extract'
                if self.clock >= 2700:
                    self.report('cancelled')
                    (self.exchange / 'artifacts/cancel.log').write_text('fully exported diagnostics')
                    self.hook.exchange_complete = True
        self.on_poll = progress
        result = self.run_monitor()
        self.assertEqual(result['status'], 'cancelled')
        self.assertEqual(result['reason'], 'cancelled')
        self.assertTrue(self.hook.exchange_complete)
        self.assertEqual(self.clock, 2700)
        self.assertEqual((self.exchange / 'artifacts/cancel.log').read_text(), 'fully exported diagnostics')
        self.assertNotIn('guestFailure', result)
        self.assertEqual(self.events[-2:], ['cancel-transfer', 'stop-vm'])

    def test_first_stop_during_report_outage_allows_final_collection_before_vm_shutdown(self):
        exchange_module = host.guest_exchange_module()
        transport = exchange_module.GuestExchange.__new__(exchange_module.GuestExchange)
        outage = {'status': 'retrying', 'failures': 1, 'retryAttempts': 0}
        transport.__dict__.update({
            'phase': 'report', 'observed_launch': True, 'final_seen': False,
            'stop_requested': False, 'stop_sent': False, 'stop_child': None, 'child': None,
            'result': None, 'next_poll': 5, 'guest_finished_at': None, 'launched_at': 0,
            'report_outage': {'started': 0, 'deadline': 60, 'event': outage},
            'report_retry_info': {'version': 1, 'runId': self.run_id, 'vmId': 'fixture-vm',
                'outages': 1, 'retryAttempts': 0, 'recoveredOutages': 0, 'recentOutages': [outage]},
            'report_journal_failed': False, 'exchange': self.exchange,
        })
        def start_report(phase, script, *, timeout):
            self.assertEqual((phase, script, timeout), ('report', exchange_module._POLL, 30))
            self.events.append('poll-final-report')
            transport.next_poll = self.clock + 5
        transport._start_remote = start_report
        transport._finish = lambda result: result
        self.hook.transport = transport
        def stop_delivered():
            self.request_stop()
            transport.stop_requested = transport.stop_sent = True
        self.hook.request_stop = stop_delivered
        def progress(count):
            if count == 1:
                self.report('running', terminal=False)
                host.publish_stop(self.exchange, self.run_id, requested=True)
            elif self.clock >= 30:
                self.report('cancelled')
                (self.exchange / 'artifacts/cancel.log').write_text('exported after finalization')
                self.hook.exchange_complete = True
            else:
                return transport.poll()
        self.on_poll = progress
        result = self.run_monitor()
        self.assertEqual(result['status'], 'cancelled')
        self.assertEqual(self.clock, 30)
        self.assertTrue(self.hook.exchange_complete)
        self.assertIn('poll-final-report', self.events)
        self.assertEqual((self.exchange / 'artifacts/cancel.log').read_text(), 'exported after finalization')
        self.assertNotIn('guestFailure', result)
        self.assertEqual(host.read_json(self.exchange / 'guest-transport.json')['recentOutages'][0]['status'], 'cancelled')
        self.assertEqual(self.events[-2:], ['cancel-transfer', 'stop-vm'])

    def test_cancel_export_deadline_exhaustion_preserves_incomplete_coverage(self):
        self.maximum_clock = 1900
        self.hook.transport = SimpleNamespace(phase='export', observed_launch=True, final_seen=True)
        result = self.run_monitor(timeout=0)
        self.assertEqual(result['reason'], 'timed_out')
        self.assertEqual(self.clock, host.STOP_EXPORT_SECONDS)
        self.assertEqual(result['guestFailure'], {'status': 'failed',
            'reason': 'guest_artifact_collection_timeout', 'phase': 'export'})
        self.assertFalse(result['coverage']['fullSuiteVerified'])
        self.assertFalse(self.hook.exchange_complete)
        self.assertEqual(self.events[-2:], ['cancel-transfer', 'stop-vm'])

    def test_cancel_stops_promptly_when_an_observed_transport_fails(self):
        self.hook.transport = SimpleNamespace(phase='export', observed_launch=True, final_seen=True)
        failure = {'status': 'failed', 'reason': 'guest_exchange_timeout', 'phase': 'export'}
        self.on_poll = lambda _: failure
        result = self.run_monitor(timeout=0)
        self.assertEqual(result['reason'], 'timed_out')
        self.assertEqual(result['guestFailure'], failure)
        self.assertEqual(self.clock, 0)
        self.assertEqual(self.hook.polls, 1)

    def test_cancel_still_uses_short_grace_before_the_guest_job_is_observed(self):
        self.hook.transport = SimpleNamespace(phase='launch', observed_launch=False, final_seen=False)
        result = self.run_monitor(timeout=0)
        self.assertEqual(result['reason'], 'timed_out')
        self.assertEqual(self.clock, 20)
        self.assertEqual(self.hook.polls, 20)

    def test_cancel_finalization_is_bounded_without_a_terminal_guest_report(self):
        self.maximum_clock = 700
        self.hook.transport = SimpleNamespace(phase='report', observed_launch=True, final_seen=False)
        result = self.run_monitor(timeout=0)
        self.assertEqual(result['reason'], 'timed_out')
        self.assertEqual(self.clock, host.STOP_FINALIZATION_SECONDS)
        self.assertFalse(self.hook.exchange_complete)

    def test_a_second_stop_request_ends_long_collection_promptly(self):
        self.hook.transport = SimpleNamespace(phase='export', observed_launch=True, final_seen=True)
        def progress(count):
            if count == 1 or self.hook.stopped and self.clock >= 30:
                host.publish_stop(self.exchange, self.run_id, requested=True)
        self.on_poll = progress
        result = self.run_monitor()
        self.assertEqual(result['status'], 'cancelled')
        self.assertEqual(self.clock, 30)
        self.assertFalse(self.hook.exchange_complete)
        self.assertEqual(self.events[-2:], ['cancel-transfer', 'stop-vm'])

    def test_a_second_interrupt_ends_long_collection_promptly(self):
        self.hook.transport = SimpleNamespace(phase='export', observed_launch=True, final_seen=True)
        def progress(count):
            if count == 1 or self.hook.stopped and self.clock >= 30:
                signal.getsignal(signal.SIGINT)(signal.SIGINT, None)
        self.on_poll = progress
        result = self.run_monitor()
        self.assertEqual(result['status'], 'cancelled')
        self.assertEqual(self.clock, 30)
        self.assertFalse(self.hook.exchange_complete)
        self.assertEqual(self.events[-2:], ['cancel-transfer', 'stop-vm'])

    def assert_early_requests(self, *requests):
        self.hook.transport = SimpleNamespace(phase='export', observed_launch=True, final_seen=True)
        def progress(count):
            if count == 1:
                for request in requests:
                    if request == 'stop':
                        host.publish_stop(self.exchange, self.run_id, requested=True)
                    else:
                        signal.getsignal(request)(request, None)
        self.on_poll = progress
        result = self.run_monitor()
        self.assertEqual(result['status'], 'cancelled')
        self.assertEqual(self.clock, 1)
        self.assertEqual(self.hook.polls, 1)
        self.assertFalse(self.hook.exchange_complete)
        self.assertEqual(self.events[-2:], ['cancel-transfer', 'stop-vm'])

    def test_two_stop_requests_before_collection_skip_the_collection_wait(self):
        self.assert_early_requests('stop', 'stop')

    def test_stop_then_interrupt_before_collection_skip_the_collection_wait(self):
        self.assert_early_requests('stop', signal.SIGINT)

    def test_interrupt_then_stop_before_collection_skip_the_collection_wait(self):
        self.assert_early_requests(signal.SIGINT, 'stop')

    def test_repeated_interrupts_before_collection_skip_the_collection_wait(self):
        self.assert_early_requests(signal.SIGTERM, signal.SIGHUP)

    def test_first_interrupt_allows_the_guest_to_finish_export(self):
        self.hook.transport = SimpleNamespace(phase='export', observed_launch=True, final_seen=True)
        def progress(count):
            if count == 1:
                signal.getsignal(signal.SIGINT)(signal.SIGINT, None)
            elif self.hook.stopped and self.clock >= 30:
                self.report('cancelled')
                self.hook.exchange_complete = True
        self.on_poll = progress
        result = self.run_monitor()
        self.assertEqual(result['status'], 'cancelled')
        self.assertEqual(self.clock, 30)
        self.assertTrue(self.hook.exchange_complete)
        self.assertEqual(host.operation_stop_record(self.exchange, self.run_id)['requestCount'], 0)
        self.assertNotIn('guestFailure', result)

    def test_previous_setup_scope_is_counted_once_when_scopes_repeat(self):
        previous_id, previous_exchange = host.new_exchange(self.root, 'setup')
        previous = (previous_exchange, previous_id)
        self.hook.transport = SimpleNamespace(phase='export', observed_launch=True, final_seen=True)
        def progress(count):
            if count == 1:
                host.publish_stop(previous_exchange, previous_id, requested=True)
            elif self.hook.stopped and self.clock >= 30:
                self.report('cancelled')
                self.hook.exchange_complete = True
        self.on_poll = progress
        result = self.run_monitor(previous_stops=(previous, previous, (self.exchange, self.run_id)))
        self.assertEqual(result['status'], 'cancelled')
        self.assertEqual(self.clock, 30)
        self.assertTrue(self.hook.exchange_complete)
        self.assertNotIn('guestFailure', result)

    def test_two_requests_across_setup_scopes_skip_the_collection_wait(self):
        previous_id, previous_exchange = host.new_exchange(self.root, 'setup')
        self.hook.transport = SimpleNamespace(phase='export', observed_launch=True, final_seen=True)
        def progress(count):
            if count == 1:
                host.publish_stop(previous_exchange, previous_id, requested=True)
                host.publish_stop(self.exchange, self.run_id, requested=True)
        self.on_poll = progress
        result = self.run_monitor(previous_stops=((previous_exchange, previous_id),))
        self.assertEqual(result['status'], 'cancelled')
        self.assertEqual(self.clock, 1)
        self.assertEqual(self.hook.polls, 1)
        self.assertFalse(self.hook.exchange_complete)

    def test_stop_during_timeout_stop_publication_ends_collection_immediately(self):
        self.hook.transport = SimpleNamespace(phase='export', observed_launch=True, final_seen=True)
        publish = host.publish_stop
        def request_during_publication(exchange, run_id, *, requested=False):
            if not requested:
                publish(exchange, run_id, requested=True)
            return publish(exchange, run_id, requested=requested)
        with patch.object(host, 'publish_stop', side_effect=request_during_publication):
            result = self.run_monitor(timeout=0)
        self.assertEqual(result['reason'], 'timed_out')
        self.assertEqual(self.clock, 0)
        self.assertEqual(self.hook.polls, 0)
        self.assertFalse(self.hook.exchange_complete)
        self.assertEqual(host.operation_stop_record(self.exchange, self.run_id)['requestCount'], 1)
        self.assertEqual(self.events[-2:], ['cancel-transfer', 'stop-vm'])

    def test_first_interrupt_during_timeout_collection_ends_collection_promptly(self):
        self.hook.transport = SimpleNamespace(phase='export', observed_launch=True, final_seen=True)
        def interrupt(_):
            if self.clock >= 30:
                signal.getsignal(signal.SIGINT)(signal.SIGINT, None)
        self.on_poll = interrupt
        result = self.run_monitor(timeout=0)
        self.assertEqual(result['reason'], 'timed_out')
        self.assertEqual(self.clock, 30)
        self.assertFalse(self.hook.exchange_complete)
        self.assertNotIn('guestFailure', result)

    def test_capacity_failure_ends_collection_immediately(self):
        self.hook.transport = SimpleNamespace(phase='export', observed_launch=True, final_seen=True)
        def capacity():
            raise host.RunnerError('fixture disk reserve reached')
        self.capacity = capacity
        result = self.run_monitor(timeout=0)
        self.assertEqual(result['reason'], 'timed_out')
        self.assertIn('fixture disk reserve reached', result['hostTermination']['error'])
        self.assertEqual(self.clock, 0)
        self.assertEqual(self.hook.polls, 1)


if __name__ == '__main__':
    unittest.main()
