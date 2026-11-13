import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


specification = importlib.util.spec_from_file_location('macos_vm', Path(__file__).resolve().parents[1] / 'macos_vm.py')
vm = importlib.util.module_from_spec(specification)
specification.loader.exec_module(vm)

specification = importlib.util.spec_from_file_location('vm_host_services', Path(__file__).resolve().parents[1] / 'host.py')
host = importlib.util.module_from_spec(specification)
specification.loader.exec_module(host)


class RunnerError(RuntimeError):
    pass


class TransportUnavailable(RuntimeError):
    pass


class MacOSVMLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.state = Path(self.stack.enter_context(tempfile.TemporaryDirectory())).resolve()
        self.target = {'version': '27.2', 'buildVersion': '26B123'}
        self.before = {'version': '27.0.1', 'buildVersion': '26A434'}
        self.record = {'vmId': 'fixture', 'consoleUser': 'wallet-test', 'guestAccessID': 'credential'}
        self.identifier = 'macos-upgrade-20261103T000000Z-12345678'
        self.args = SimpleNamespace(xcode=Path('/Applications/Xcode.app'), interactive=False, timeout=None)
        self.clock = 0.0
        self.progress = []
        self.launches = 0
        self.alive = False
        self.native = None
        self.host = Mock(spec_set=host.host_services(), RunnerError=RunnerError, private_directory=self.directory,
            atomic_json=lambda path, value: path.write_text(json.dumps(value)),
            read_json=lambda path: json.loads(path.read_text()), build_tools=Mock(return_value=self.state / 'tools'),
            ensure_disk_idle=Mock(), validate_vm=Mock())
        self.transport = SimpleNamespace(TransportUnavailable=TransportUnavailable,
            probe=Mock(return_value=self.observation('ready')),
            start=Mock(return_value=self.observation('installing', safe=False)), observe=Mock(), resize=Mock())
        self.access = SimpleNamespace(find_guest_address=Mock(return_value='192.168.64.3'))
        self.stack.enter_context(patch.object(vm, 'transport_module', return_value=self.transport))
        self.stack.enter_context(patch.object(vm, '_vm_identity', return_value=[1, 2]))
        self.stack.enter_context(patch.object(vm, '_access_context', side_effect=self.access_context))
        self.stack.enter_context(patch.object(vm, '_native_alive', side_effect=lambda *args: self.alive))
        self.stack.enter_context(patch.object(vm, '_native_status', side_effect=self.native_status))
        self.stack.enter_context(patch.object(vm, '_launch', side_effect=self.launch))
        self.shutdown = self.stack.enter_context(patch.object(vm, '_shutdown', side_effect=self.stop))
        self.stack.enter_context(patch.object(vm.time, 'sleep', side_effect=self.sleep))
        self.stack.enter_context(patch.object(vm.time, 'monotonic', side_effect=lambda: self.clock))
        self.stack.enter_context(patch.object(vm.signal, 'signal', return_value=0))

    def directory(self, path):
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.chmod(0o700)
        return path

    def native_status(self, host, journal):
        if self.native is not None:
            return {'running': self.native['state'] == 'running', 'installationProtected': journal.get('protected', False),
                    **self.native}

    def observation(self, status, *, safe=True, actual=None, boot=None, reason=None):
        result = {'status': status, 'actual': actual or (self.target if status == 'complete' else self.before),
                  'bootIdentity': boot or ('after' if status == 'complete' else 'before'), 'safeToStop': safe}
        if reason:
            result['reason'] = reason
        return result

    def access_context(self, host, state, template, record, directory, journal):
        journal['access'] = {'macAddress': '02:00:00:00:00:01'}
        return self.access, {}

    def launch(self, host, args, state, directory, journal, binaries):
        self.launches += 1
        journal['boots'] = self.launches
        journal['native'] = {'process': {'pid': 123, 'start': [1, 2], 'executable': '/tools/VMHost'}}
        self.alive = True
        self.native = {'state': 'running'}
        return Mock()

    def stop(self, host, directory, journal, child):
        journal['protected'] = False
        if not self.alive:
            return
        self.alive = False
        self.native = {'state': 'stopped', 'stopReason': 'stop-file'}

    def sleep(self, seconds):
        self.clock += seconds
        if self.clock > 1000:
            raise AssertionError('The lifecycle did not terminate')

    def install(self, stopped=lambda: False):
        return vm.install(self.host, self.args, self.state, self.record, self.identifier, self.target,
                          self.progress.append, stopped)

    def completed(self):
        return self.observation('complete')

    def journal(self):
        return self.host.read_json(self.state / 'macos-install/install.json')

    def seed_attempt(self):
        directory = self.directory(self.state / 'macos-install')
        self.host.atomic_json(directory / 'install.json', {'version': 1, 'upgradeID': self.identifier,
            'vmId': self.record['vmId'], 'vm': str(self.state / 'baseline.vbvm'), 'target': self.target,
            'vmFileID': [1, 2], 'startAttempted': True, 'preBootIdentity': 'before', 'protected': True})
        self.host.atomic_json(directory / 'control.json', {'version': 1, 'upgradeID': self.identifier,
            'vmPath': str(self.state / 'baseline.vbvm'), 'protectInstallation': True})

    def test_matching_target_is_observed_twice_without_installation(self):
        self.transport.probe.return_value = self.completed()
        result = self.install()
        self.assertEqual(result['status'], 'complete')
        self.assertEqual(result['actual'], self.target)
        self.assertEqual(self.transport.probe.call_count, 2)
        self.transport.start.assert_not_called()
        self.assertEqual(self.launches, 1)

    def test_ssh_disconnect_after_start_is_not_reinstalled_or_powered_off(self):
        self.transport.start.side_effect = TransportUnavailable('disconnected')
        self.transport.observe.side_effect = [TransportUnavailable('rebooting'),
            self.observation('installing', safe=False), self.completed(), self.completed()]
        result = self.install()
        self.assertEqual(result['status'], 'complete')
        self.assertEqual(self.transport.start.call_count, 1)
        self.assertEqual(self.launches, 1)
        self.assertEqual(self.shutdown.call_count, 1)
        self.assertTrue(any(item.get('protected') is True for item in self.progress))

    def test_lost_start_response_never_accepts_completion_on_admission_boot(self):
        self.transport.start.side_effect = TransportUnavailable('lost response')
        same_boot = self.observation('complete', boot='before')
        self.transport.observe.side_effect = [same_boot, same_boot, self.completed(), self.completed()]
        result = self.install()
        self.assertEqual(result['bootIdentity'], 'after')
        self.assertEqual(self.transport.observe.call_count, 4)
        self.assertEqual(self.transport.start.call_count, 1)

    def test_actual_vm_stop_is_required_before_relaunch(self):
        def installing(*args):
            self.alive = False
            self.native = {'state': 'stopped'}
            return self.observation('installing', safe=False)
        self.transport.observe.side_effect = [installing, self.completed(), self.completed()]
        values = iter([installing, self.completed(), self.completed()])
        self.transport.observe.side_effect = lambda *args: (lambda value: value(*args) if callable(value) else value)(next(values))
        result = self.install()
        self.assertEqual(result['status'], 'complete')
        self.assertEqual(self.launches, 2)
        self.assertEqual(self.transport.start.call_count, 1)

    def test_cancellation_after_start_waits_for_verified_stable_boot(self):
        self.transport.observe.side_effect = [self.observation('installing', safe=False), self.completed(), self.completed()]
        result = self.install(lambda: self.transport.start.called)
        self.assertEqual(result['status'], 'cancelled')
        self.assertEqual(result['actual'], self.target)
        self.assertEqual(self.transport.observe.call_count, 3)
        self.assertTrue(any(item.get('cancellationDeferred') is True for item in self.progress))
        self.assertEqual(self.shutdown.call_count, 1)

    def test_install_deadline_reports_attention_without_stopping_installer(self):
        self.args.timeout = 1
        self.transport.observe.side_effect = [self.observation('installing', safe=False), self.completed(), self.completed()]
        result = self.install()
        self.assertEqual(result['status'], 'complete')
        self.assertTrue(any('attentionRequired' in item for item in self.progress))
        self.assertEqual(self.shutdown.call_count, 1)

    def test_preinstall_unreachable_timeout_is_safe_to_stop(self):
        self.args.timeout = 3
        self.transport.probe.side_effect = TransportUnavailable('not ready')
        result = self.install()
        self.assertEqual(result['status'], 'blocked')
        self.transport.start.assert_not_called()
        self.assertEqual(self.shutdown.call_count, 1)

    def test_slow_probe_crossing_deadline_never_admits_installation(self):
        self.args.timeout = 5
        def slow_probe(*_):
            self.clock = 5
            return self.observation('ready')
        self.transport.probe.side_effect = slow_probe
        result = self.install()
        self.assertEqual(result['status'], 'blocked')
        self.assertIn('deadline', result['reason'])
        self.transport.start.assert_not_called()
        self.assertFalse(self.journal().get('startAttempted'))

    def test_deadline_after_writing_install_intent_prevents_start(self):
        self.args.timeout = 5
        def progress(value):
            if value['phase'] == 'starting-installation':
                self.clock = 5
        result = vm.install(self.host, self.args, self.state, self.record, self.identifier, self.target,
                            progress, lambda: False)
        self.assertEqual(result['status'], 'blocked')
        self.assertFalse(self.journal()['startAttempted'])
        self.transport.start.assert_not_called()

    def test_missing_receipt_preserves_protected_vm_for_inspection(self):
        self.transport.start.side_effect = TransportUnavailable('lost response')
        self.transport.observe.return_value = self.observation('blocked', safe=False, reason='update_receipt_missing')
        result = self.install()
        self.assertEqual(result['status'], 'blocked')
        self.assertTrue(result['vmPreservedRunning'])
        self.assertTrue(self.journal()['protected'])
        self.assertTrue(self.journal()['startAttempted'])
        self.shutdown.assert_not_called()

    def test_known_install_launch_failure_stops_safely_and_never_retries(self):
        failure = {**self.observation('failed', reason='guest_update_worker_launch_failed'), 'receipt': {'phase': 'failed'}}
        self.transport.start.return_value = failure
        result = self.install()
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(self.transport.start.call_count, 1)
        self.assertEqual(self.shutdown.call_count, 1)
        self.assertFalse(self.journal()['protected'])
        self.transport.observe.return_value = failure
        with patch.object(vm, '_validate_native'):
            self.assertEqual(self.install()['status'], 'failed')
        self.assertEqual(self.transport.start.call_count, 1)

    def test_authenticated_prerequisite_rejection_at_start_can_retry_on_resume(self):
        self.transport.start.return_value = self.observation('blocked', reason='insufficient_guest_system_storage')
        self.assertEqual(self.install()['status'], 'blocked')
        self.assertFalse(self.journal()['startAttempted'])
        self.transport.start.return_value = self.observation('installing', safe=False)
        self.transport.observe.side_effect = [self.completed(), self.completed()]
        with patch.object(vm, '_validate_native'):
            self.assertEqual(self.install()['status'], 'complete')
        self.assertEqual(self.transport.start.call_count, 2)

    def test_explicit_resume_after_startup_failure_tries_one_new_boot(self):
        def fail_startup(*_):
            self.alive = False
            self.native = {'state': 'failed', 'running': False, 'guestStarted': False}
        self.access.find_guest_address.side_effect = fail_startup
        self.assertEqual(self.install()['status'], 'blocked')
        self.assertEqual(self.launches, 1)
        self.native['stopReason'] = 'signal'
        with patch.object(vm, '_validate_native'):
            self.assertEqual(self.install()['status'], 'blocked')
            self.assertEqual(self.launches, 2)
            self.access.find_guest_address.side_effect = None
            self.transport.observe.side_effect = [self.completed(), self.completed()]
            self.assertEqual(self.install()['status'], 'complete')
            self.assertEqual(self.launches, 3)

    def test_explicit_resume_keeps_post_admission_or_running_guest_failure(self):
        self.seed_attempt()
        directory = self.state / 'macos-install'
        with patch.object(vm, '_validate_native'):
            for admitted, started in ((True, False), (False, True), (False, None)):
                with self.subTest(admitted=admitted, started=started):
                    journal = self.journal()
                    journal.update(boots=1, startAttempted=admitted, native={'process': {'pid': 123}})
                    self.host.atomic_json(directory / 'install.json', journal)
                    self.native = {'state': 'failed', 'running': False, 'guestStarted': started}
                    self.assertEqual(self.install()['status'], 'blocked')
                    self.assertEqual(self.launches, 0)

    def safely_blocked_attempt(self):
        self.transport.probe.return_value = self.observation('blocked', reason='guest_volume_owner_required')
        result = self.install()
        self.assertEqual(result['status'], 'blocked')
        self.assertEqual(self.native, {'state': 'stopped', 'stopReason': 'stop-file'})
        self.transport.probe.return_value = self.observation('ready')
        self.transport.observe.side_effect = [self.completed(), self.completed()]

    def test_resume_after_safe_prerequisite_shutdown_rechecks_instead_of_cancelling(self):
        self.safely_blocked_attempt()
        self.args.interactive = True
        with patch.object(vm, '_validate_native'):
            result = self.install()
        self.assertEqual(result['status'], 'complete')
        self.assertEqual(self.launches, 2)
        self.assertEqual(self.transport.probe.call_count, 2)
        self.assertEqual(self.transport.start.call_count, 1)
        self.assertFalse(self.journal().get('cancellationDeferred', False))

    def test_resume_after_completed_installation_checkpoint_does_not_repeat_install_or_cancel(self):
        self.transport.observe.side_effect = [self.completed(), self.completed()]
        self.assertEqual(self.install()['status'], 'complete')
        self.transport.observe.side_effect = [self.completed(), self.completed()]
        with patch.object(vm, '_validate_native'):
            result = self.install()
        self.assertEqual(result['status'], 'complete')
        self.assertEqual(self.launches, 2)
        self.assertEqual(self.transport.start.call_count, 1)
        self.assertFalse(self.journal().get('cancellationDeferred', False))

    def test_current_stop_request_still_cancels_after_a_historical_safe_shutdown(self):
        self.safely_blocked_attempt()
        with patch.object(vm, '_validate_native'):
            result = self.install(lambda: True)
        self.assertEqual(result['status'], 'cancelled')
        self.assertEqual(self.launches, 1)
        self.assertEqual(self.transport.probe.call_count, 1)
        self.transport.start.assert_not_called()

    def test_cancellation_from_a_new_native_session_is_not_treated_as_historical(self):
        self.safely_blocked_attempt()
        def current_stop(*args):
            self.native = {'state': 'running', 'stopReason': 'stop-file', 'shutdownDeferred': True}
            return self.observation('installing', safe=False)
        observations = iter([current_stop, self.completed(), self.completed()])
        self.transport.observe.side_effect = lambda *args: (lambda value: value(*args) if callable(value) else value)(next(observations))
        with patch.object(vm, '_validate_native'):
            result = self.install()
        self.assertEqual(result['status'], 'cancelled')
        self.assertEqual(result['actual'], self.target)
        self.assertEqual(self.launches, 2)

    def test_resume_observes_existing_attempt_instead_of_reissuing_update(self):
        self.seed_attempt()
        self.transport.observe.side_effect = [self.completed(), self.completed()]
        result = self.install()
        self.assertEqual(result['status'], 'complete')
        self.transport.probe.assert_not_called()
        self.transport.start.assert_not_called()

    def test_resume_cannot_verify_attempt_without_saved_admission_boot(self):
        self.seed_attempt()
        journal = self.journal()
        journal.pop('preBootIdentity')
        self.host.atomic_json(self.state / 'macos-install/install.json', journal)
        with self.assertRaisesRegex(RunnerError, 'admission boot identity'):
            self.install()
        self.assertEqual(self.launches, 0)
        self.shutdown.assert_not_called()

    def test_resume_refuses_changed_target_before_starting_vm(self):
        self.seed_attempt()
        self.target = {'version': '27.3', 'buildVersion': '26C100'}
        with self.assertRaisesRegex(RunnerError, 'different VM or target'):
            self.install()
        self.assertEqual(self.launches, 0)

    def test_wrong_version_cannot_be_accepted_as_complete(self):
        self.transport.observe.return_value = self.observation('complete', actual=self.before)
        result = self.install()
        self.assertEqual(result['status'], 'blocked')
        self.assertTrue(result['vmPreservedRunning'])
        self.shutdown.assert_not_called()

    def test_interactive_recovery_keeps_failed_receipt_vm_open_until_new_boot(self):
        self.seed_attempt()
        self.args.interactive = True
        self.transport.observe.return_value = self.observation('failed', reason='authentication_required')
        self.transport.probe.side_effect = [self.completed(), self.completed()]
        result = self.install()
        self.assertEqual(result['status'], 'complete')
        self.assertTrue(any(item['phase'] == 'waiting-for-consent' and item['protected'] for item in self.progress))
        self.transport.start.assert_not_called()
        self.assertEqual(self.shutdown.call_count, 1)

    def test_interactive_prerequisite_protects_manual_update_until_cold_target_boot(self):
        self.args.interactive = True
        self.transport.probe.side_effect = [self.observation('blocked', reason='volume_owner_required'),
            self.observation('ready'), self.observation('complete', boot='before'), self.completed(), self.completed()]
        result = self.install()
        self.assertEqual(result['status'], 'complete')
        self.assertEqual(self.transport.probe.call_count, 5)
        self.transport.start.assert_not_called()
        self.assertTrue(any(item['phase'] == 'waiting-for-consent' and item['protected'] for item in self.progress))
        self.assertTrue(any(item['phase'] == 'waiting-for-restart' for item in self.progress))
        control = self.host.read_json(self.state / 'macos-install/control.json')
        self.assertTrue(control['showWindow'])
        self.assertEqual(self.shutdown.call_count, 1)

    def test_cancellation_during_manual_handoff_cannot_stop_in_flight_update(self):
        self.args.interactive = True
        self.transport.probe.side_effect = [self.observation('blocked', reason='volume_owner_required'),
            self.observation('ready'), self.completed(), self.completed()]
        result = self.install(lambda: any(item['phase'] == 'waiting-for-consent' for item in self.progress))
        self.assertEqual(result['status'], 'cancelled')
        self.assertEqual(result['actual'], self.target)
        self.transport.start.assert_not_called()
        self.assertEqual(self.shutdown.call_count, 1)

    def test_window_close_during_update_does_not_skip_required_reboot(self):
        def close_and_stop(*args):
            self.alive = False
            self.native = {'state': 'stopped', 'stopReason': 'upgrade-window-closed'}
            return self.observation('installing', safe=False)
        values = iter([close_and_stop, self.completed(), self.completed()])
        self.transport.observe.side_effect = lambda *args: (lambda value: value(*args) if callable(value) else value)(next(values))
        result = self.install()
        self.assertEqual(result['status'], 'cancelled')
        self.assertEqual(result['actual'], self.target)
        self.assertEqual(self.launches, 2)

    def test_interactive_resume_requests_window_without_restarting_existing_host(self):
        self.seed_attempt()
        self.args.interactive = True
        self.alive = True
        self.native = {'state': 'running'}
        self.transport.observe.side_effect = [self.completed(), self.completed()]
        result = self.install()
        self.assertEqual(result['status'], 'complete')
        self.assertEqual(self.launches, 0)
        control = self.host.read_json(self.state / 'macos-install/control.json')
        self.assertTrue(control['showWindow'])

    def test_interactive_candidate_shows_window_before_guest_network_is_ready(self):
        self.args.interactive = True
        def find_address(_):
            control = self.host.read_json(self.state / 'macos-install/control.json')
            self.assertTrue(control['showWindow'])
            self.assertTrue(control['protectInstallation'])
            self.transport.probe.assert_not_called()
            return None
        self.access.find_guest_address.side_effect = lambda mac: find_address(mac) if self.access.find_guest_address.call_count == 1 else '192.168.64.3'
        self.transport.observe.side_effect = [self.completed(), self.completed()]
        self.assertEqual(self.install()['status'], 'complete')

    def test_stop_during_dhcp_hands_interactive_guest_back_without_resize(self):
        self.args.interactive = True
        self.request_storage()
        self.access.find_guest_address.return_value = None
        result = self.install(lambda: self.access.find_guest_address.called)
        self.assertTrue(result['vmPreservedRunning'])
        self.assertTrue(self.journal()['awaitingGuestShutdown'])
        self.assertTrue(self.journal()['protected'])
        self.shutdown.assert_not_called()
        self.transport.resize.assert_not_called()
        self.assertEqual(self.journal()['awaitingGuestShutdown'], 'cancelled')
        self.alive = False
        self.native = {'state': 'stopped', 'running': False}
        with patch.object(vm, '_validate_native'):
            self.assertEqual(self.install()['status'], 'cancelled')
        self.assertEqual(self.launches, 1)
        self.transport.resize.assert_not_called()
        self.transport.start.assert_not_called()

    def test_stopping_unprotected_orphan_is_cold_booted_before_installing(self):
        self.safely_blocked_attempt()
        self.alive = True
        self.native = {'state': 'stopping', 'stopReason': 'owner-exited'}
        def admit(*_):
            self.assertEqual(self.launches, 2)
            self.assertEqual(self.native['state'], 'running')
            return self.observation('installing', safe=False)
        self.transport.start.side_effect = admit
        with patch.object(vm, '_validate_native'):
            self.assertEqual(self.install()['status'], 'complete')

    def test_vm_must_confirm_protection_before_resize(self):
        self.request_storage()
        self.args.timeout = 10
        def lookup(_):
            self.native['installationProtected'] = False
            return '192.168.64.3'
        self.access.find_guest_address.side_effect = lookup
        self.assertEqual(self.install()['status'], 'blocked')
        self.transport.resize.assert_not_called()

    def test_deferred_escalation_during_shutdown_still_blocks_install(self):
        self.args.timeout = 10
        def probe(*_):
            self.native.update(state='stopping', running=True, stopReason='owner-exited', shutdownDeferred=True)
            return self.observation('ready')
        self.transport.probe.side_effect = probe
        self.assertEqual(self.install()['status'], 'blocked')
        self.transport.start.assert_not_called()

    def test_owner_exit_deferred_before_shutdown_allows_protected_admission(self):
        def probe(*_):
            self.native.update(stopReason='owner-exited', shutdownDeferred=True)
            return self.observation('ready')
        self.args.interactive = True
        self.transport.probe.side_effect = probe
        self.transport.observe.side_effect = [self.completed(), self.completed()]
        self.assertEqual(self.install()['status'], 'complete')
        self.transport.start.assert_called_once()

    def test_stop_during_ssh_hands_interactive_guest_back_without_installation(self):
        self.args.interactive = True
        def disconnected(*_):
            self.native.update(stopReason='upgrade-window-closed')
            raise TransportUnavailable('not reachable')
        self.transport.probe.side_effect = disconnected
        result = self.install()
        self.assertTrue(result['vmPreservedRunning'])
        self.assertTrue(self.journal()['awaitingGuestShutdown'])
        self.assertTrue(self.journal()['protected'])
        self.shutdown.assert_not_called()
        self.transport.start.assert_not_called()

    def test_clean_guest_shutdown_during_interactive_probe_cancels_without_relaunch(self):
        self.args.interactive = True
        def shutdown(*_):
            self.alive = False
            self.native = {'state': 'stopped', 'running': False}
            return self.observation('ready')
        self.transport.probe.side_effect = shutdown
        result = self.install()
        self.assertEqual(result['status'], 'cancelled')
        self.assertEqual(self.launches, 1)
        self.host.ensure_disk_idle.assert_called()
        self.transport.start.assert_not_called()

    def test_stop_after_guest_shutdown_during_dhcp_cancels_without_relaunch(self):
        self.args.interactive = True
        def shutdown(_):
            self.alive = False
            self.native = {'state': 'stopped', 'running': False}
        self.access.find_guest_address.side_effect = shutdown
        result = self.install(lambda: self.access.find_guest_address.called)
        self.assertEqual(result['status'], 'cancelled')
        self.assertEqual(self.launches, 1)
        self.host.ensure_disk_idle.assert_called()
        self.transport.probe.assert_not_called()

    def test_new_interactive_request_reaches_running_supervisor_before_ssh(self):
        self.args.interactive_requested = lambda: self.access.find_guest_address.called
        self.access.find_guest_address.side_effect = [None, '192.168.64.3', '192.168.64.3']
        def probe(*_):
            self.assertTrue(self.host.read_json(self.state / 'macos-install/control.json')['showWindow'])
            return self.completed()
        self.transport.probe.side_effect = probe
        self.assertEqual(self.install()['status'], 'complete')
        self.assertEqual(self.launches, 1)

    def test_rejected_resume_paths_never_reach_shutdown_or_protection_mutation(self):
        self.seed_attempt()
        control = self.state / 'macos-install/control.json'
        old_control = control.read_bytes()
        with patch.object(vm, '_validate_native', side_effect=RunnerError('invalid stop path')):
            with self.assertRaisesRegex(RunnerError, 'invalid stop path'):
                self.install()
        self.assertEqual(control.read_bytes(), old_control)
        self.shutdown.assert_not_called()

    def test_guest_window_close_during_install_is_applied_after_safe_boot(self):
        def close_window(*args):
            self.native = {'state': 'running', 'shutdownDeferred': True, 'stopReason': 'upgrade-window-closed'}
            return self.observation('installing', safe=False)
        values = iter([close_window, self.completed(), self.completed()])
        self.transport.observe.side_effect = lambda *args: (lambda value: value(*args) if callable(value) else value)(next(values))
        result = self.install()
        self.assertEqual(result['status'], 'cancelled')
        self.assertEqual(result['actual'], self.target)

    def test_app_quit_during_install_waits_for_safe_boot(self):
        def quit_requested(*_):
            self.native = {'state': 'running', 'shutdownDeferred': True, 'stopReason': 'upgrade-quit-requested'}
            return self.observation('installing', safe=False)
        self.transport.start.side_effect = quit_requested
        self.transport.observe.side_effect = [self.completed(), self.completed()]
        self.assertEqual(self.install()['status'], 'cancelled')
        self.assertEqual(self.transport.observe.call_count, 2)

    def test_another_version_build_uses_the_same_flow(self):
        self.target = {'version': '28.0', 'buildVersion': '27A100'}
        self.transport.observe.side_effect = [self.completed(), self.completed()]
        result = self.install()
        self.assertEqual(result['actual'], self.target)
        self.assertEqual(self.transport.start.call_args.args[2], self.target)

    def storage_observation(self, boot, *, status='ready', safe=True, storage_status='grown'):
        value = self.observation(status, safe=safe, boot=boot)
        if storage_status == 'preflight-rejected':
            value['reason'] = 'guest_storage_main_bounds_mismatch'
        value['storage'] = {'status': storage_status, 'mainCapacityBytes': 96 * 1024 ** 3 - 5 * 1024 ** 3}
        return value

    def request_storage(self):
        self.args.system_disk_growth = {'oldBytes': 64 * 1024 ** 3, 'newBytes': 96 * 1024 ** 3,
                                        'mainPartitionGUID': 'main', 'recoveryPartitionGUID': 'recovery'}

    def test_storage_growth_is_cold_boot_verified_before_os_admission(self):
        self.request_storage()
        self.transport.resize.side_effect = [self.storage_observation('storage-before'), self.storage_observation('storage-after')]
        self.transport.observe.side_effect = [self.completed(), self.completed()]
        def probe(*args):
            self.assertEqual(self.transport.resize.call_count, 2)
            self.assertTrue(self.journal()['storageVerified'])
            return self.observation('ready')
        self.transport.probe.side_effect = probe
        result = self.install()
        self.assertEqual(result['status'], 'complete')
        self.assertTrue(result['storageVerified'])
        self.assertEqual(result['storage']['status'], 'grown')
        self.assertEqual(self.launches, 2)
        self.assertEqual(self.shutdown.call_count, 2)
        self.assertEqual(self.transport.resize.call_args.args[4], self.args.system_disk_growth)

    def test_resize_disconnect_stays_protected_and_only_rechecks_same_receipt(self):
        self.request_storage()
        self.transport.resize.side_effect = [TransportUnavailable('resize still active'),
            self.storage_observation('storage-before', status='installing', safe=False, storage_status='growing'),
            self.storage_observation('storage-before'), self.storage_observation('storage-after')]
        self.transport.observe.side_effect = [self.completed(), self.completed()]
        result = self.install()
        self.assertEqual(result['status'], 'complete')
        self.assertEqual(self.transport.resize.call_count, 4)
        self.assertEqual(self.launches, 2)
        self.assertTrue(any(item['phase'] == 'growing-system-volume' and item['protected'] for item in self.progress))

    def test_cancel_during_resize_waits_for_verified_cold_boot(self):
        self.request_storage()
        self.transport.resize.side_effect = [self.storage_observation('storage-before'), self.storage_observation('storage-after')]
        result = self.install(lambda: self.transport.resize.called)
        self.assertEqual(result['status'], 'cancelled')
        self.assertTrue(result['storageVerified'])
        self.assertEqual(self.launches, 2)
        self.transport.start.assert_not_called()
        self.transport.probe.assert_not_called()

    def test_slow_address_lookup_crossing_deadline_cannot_admit_resize(self):
        self.args.timeout = 5
        self.request_storage()
        def lookup(_):
            self.clock = 5
            return '192.168.64.3'
        self.access.find_guest_address.side_effect = lookup
        result = self.install()
        self.assertEqual(result['status'], 'blocked')
        self.assertIn('deadline', result['reason'])
        self.assertFalse(self.journal().get('storageGrowAttempted'))
        self.transport.resize.assert_not_called()

    def assert_interactive_cancel_before_rpc(self, phase):
        self.args.interactive = True
        result = self.install(lambda: any(item['phase'] == phase for item in self.progress))
        self.assertTrue(result['vmPreservedRunning'])
        self.assertTrue(self.journal()['protected'])
        self.assertTrue(self.journal()['awaitingGuestShutdown'])
        self.assertFalse(self.journal().get('startAttempted'))
        self.assertFalse(self.journal().get('storageGrowAttempted'))
        self.shutdown.assert_not_called()
        self.transport.start.assert_not_called()
        self.transport.resize.assert_not_called()

    def test_interactive_cancel_before_resize_preserves_running_guest(self):
        self.request_storage()
        self.assert_interactive_cancel_before_rpc('growing-system-volume')

    def test_interactive_cancel_before_install_preserves_running_guest(self):
        self.assert_interactive_cancel_before_rpc('starting-installation')

    def test_interactive_resize_requires_guest_shutdown_for_cold_verification(self):
        self.request_storage()
        self.args.interactive = True
        self.transport.resize.side_effect = [self.storage_observation('before'), self.storage_observation('after')]
        result = self.install()
        self.assertTrue(result['vmPreservedRunning'])
        self.assertTrue(self.journal()['protected'])
        self.shutdown.assert_not_called()
        self.transport.start.assert_not_called()
        with patch.object(vm, '_validate_native'):
            self.assertTrue(self.install()['vmPreservedRunning'])
            self.assertEqual(self.transport.resize.call_count, 1)
            self.alive = False
            self.native = {'state': 'stopped', 'running': False}
            result = self.install(lambda: self.transport.resize.call_count == 2)
            self.assertTrue(result['vmPreservedRunning'])
            self.assertTrue(self.journal()['storageVerified'])
            self.assertTrue(self.journal()['protected'])
            self.shutdown.assert_not_called()
            self.transport.start.assert_not_called()

    def test_low_free_space_after_growth_requires_cold_verification_and_blocks_install(self):
        self.request_storage()
        self.transport.resize.side_effect = [
            {**self.storage_observation(boot, status='blocked'), 'reason': 'guest_storage_insufficient_free_space_after_growth'}
            for boot in ('before', 'after')]
        result = self.install()
        self.assertEqual(result['status'], 'blocked')
        self.assertEqual(result['reason'], 'guest_storage_insufficient_free_space_after_growth')
        self.assertFalse(self.journal()['protected'])
        self.assertEqual(self.launches, 2)
        self.transport.start.assert_not_called()
        self.assertFalse(self.journal()['storageGrowAttempted'])
        self.transport.resize.side_effect = [self.storage_observation('subsequent-boot')]
        self.transport.observe.side_effect = [self.completed(), self.completed()]
        with patch.object(vm, '_validate_native'):
            self.assertEqual(self.install()['status'], 'complete')
        self.assertEqual(self.transport.resize.call_count, 3)
        self.assertTrue(self.journal()['storageVerified'])

    def test_uncertain_resize_state_preserves_running_guest(self):
        self.request_storage()
        self.transport.resize.return_value = self.storage_observation('storage-before', status='blocked', safe=False, storage_status='unknown')
        result = self.install()
        self.assertEqual(result['status'], 'blocked')
        self.assertTrue(result['vmPreservedRunning'])
        self.shutdown.assert_not_called()
        self.transport.probe.assert_not_called()

    def test_known_resize_failure_blocks_os_update_and_stops_safely(self):
        self.request_storage()
        self.transport.resize.return_value = self.storage_observation('storage-before', status='blocked', storage_status='preflight-rejected')
        result = self.install()
        self.assertEqual(result['status'], 'blocked')
        self.assertFalse(self.journal()['storageGrowAttempted'])
        self.assertEqual(self.shutdown.call_count, 1)
        self.transport.start.assert_not_called()

    def test_interactive_resize_rejection_waits_for_guest_shutdown_then_allows_headless_retry(self):
        self.request_storage()
        self.args.interactive = True
        self.transport.resize.return_value = self.storage_observation('storage-before', status='blocked',
                                                                     storage_status='preflight-rejected')
        result = self.install()
        self.assertIn('Shut down from the guest window', result['reason'])
        self.assertTrue(result['vmPreservedRunning'])
        self.assertTrue(self.journal()['protected'])
        self.assertFalse(self.journal()['storageGrowAttempted'])
        self.shutdown.assert_not_called()
        self.args.interactive = False
        with patch.object(vm, '_validate_native'):
            self.assertTrue(self.install()['vmPreservedRunning'])
            self.assertEqual(self.transport.resize.call_count, 1)
            self.alive = False
            self.native = {'state': 'stopped', 'running': False}
            self.transport.resize.side_effect = [self.storage_observation('before'), self.storage_observation('after')]
            self.transport.observe.side_effect = [self.completed(), self.completed()]
            self.assertEqual(self.install()['status'], 'complete')
        self.assertFalse(self.journal().get('interactiveProtection'))
        self.assertFalse(self.journal().get('awaitingGuestShutdown'))

    def test_fresh_interactive_stop_before_launch_cancels_safely(self):
        self.args.interactive = True
        self.assertEqual(self.install(lambda: True)['status'], 'cancelled')
        self.assertEqual(self.launches, 0)

    def test_missing_resize_evidence_is_not_accepted(self):
        self.request_storage()
        self.transport.resize.return_value = self.observation('ready')
        result = self.install()
        self.assertEqual(result['status'], 'blocked')
        self.assertTrue(result['vmPreservedRunning'])
        self.shutdown.assert_not_called()

    def test_resume_binds_the_original_system_disk_growth_receipt(self):
        self.request_storage()
        self.transport.resize.return_value = self.storage_observation('storage-before', status='blocked', safe=False, storage_status='unknown')
        self.install()
        self.args.system_disk_growth = {**self.args.system_disk_growth, 'newBytes': 128 * 1024 ** 3}
        with self.assertRaisesRegex(RunnerError, 'different VM or target'):
            self.install()


class MacOSVMOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.state = Path(self.directory.name).resolve()
        self.work = self.state / 'macos-install'
        self.boot = self.work / 'boot-1'
        self.boot.mkdir(parents=True, mode=0o700)
        self.executable = self.state / 'tools/fixture/VMHost'
        self.executable.parent.mkdir(parents=True)
        self.executable.write_bytes(b'fixture executable')
        self.host = Mock(spec_set=host.host_services(), RunnerError=RunnerError,
            read_json=lambda path: json.loads(path.read_text()),
            hash_regular_file=lambda path: hashlib.sha256(Path(path).read_bytes()).hexdigest())
        self.process = {'pid': 101, 'start': [1000, 20], 'executable': str(self.executable)}
        self.journal = {'vm': str(self.state / 'baseline.vbvm'), 'boots': 1,
            'native': {'process': self.process, 'statusPath': str(self.boot / 'vm-status.json'),
                       'stopPath': str(self.boot / 'vm-stop'),
                       'executableSHA256': self.host.hash_regular_file(self.executable)}}

    def launch_fixture(self):
        self.host.setup_viewer_binary = Mock(return_value=self.executable)
        self.host.ensure_disk_idle = Mock()
        def write(path, value):
            path.write_text(json.dumps(value))
        self.host.atomic_json = write
        journals = []
        grants = []
        class Gate(io.BytesIO):
            def write(gate, value):
                grants.append(value)
                journals.append(self.host.read_json(self.work / 'install.json'))
                return super().write(value)
        def popen(*args, **options):
            self.assertIs(options['stdin'], vm.subprocess.PIPE)
            journals.append(self.host.read_json(self.work / 'install.json'))
            return SimpleNamespace(pid=self.process['pid'], stdin=Gate())
        return popen, grants, journals

    def test_launch_reserves_unique_boot_slot_and_commits_process_before_vm_admission(self):
        popen, grants, journals = self.launch_fixture()
        self.journal['interactiveProtection'] = True
        with patch.object(vm.subprocess, 'Popen', side_effect=popen) as launch, \
                patch.object(vm, 'process_identity', return_value=self.process):
            vm._launch(self.host, SimpleNamespace(), self.state, self.work, self.journal, self.state / 'tools')
        self.assertIn('--upgrade-window', launch.call_args.args[0])
        self.assertEqual(journals[0]['boots'], 2)
        self.assertIsNone(journals[0]['native'])
        self.assertEqual(grants, [b'G'])
        self.assertEqual(journals[1]['native']['process'], self.process)

    def test_interrupted_launch_before_identity_never_admits_vm_and_can_resume(self):
        popen, grants, _ = self.launch_fixture()
        with patch.object(vm.subprocess, 'Popen', side_effect=popen), \
                patch.object(vm, 'process_identity', side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                vm._launch(self.host, None, self.state, self.work, self.journal, self.state / 'tools')
        self.assertEqual(grants, [])
        retained = self.host.read_json(self.work / 'install.json')
        self.assertIsNone(retained['native'])
        self.assertTrue((self.work / 'boot-2/vm.log').exists())
        with patch.object(vm.subprocess, 'Popen', side_effect=popen), \
                patch.object(vm, 'process_identity', return_value=self.process):
            vm._launch(self.host, None, self.state, self.work, retained, self.state / 'tools')
        self.assertEqual(grants, [b'G'])
        self.assertEqual(retained['boots'], 3)

    def test_resume_rejects_symlinked_stop_file_before_releasing_watchdog_protection(self):
        target = self.state / 'unrelated'
        target.write_bytes(b'preserve')
        (self.boot / 'vm-stop').symlink_to(target)
        with patch.object(vm, '_set_protection') as control, self.assertRaisesRegex(RunnerError, 'owned regular file'):
            vm._shutdown(self.host, self.work, self.journal, None)
        control.assert_not_called()
        self.assertEqual(target.read_bytes(), b'preserve')

    def test_resume_requires_the_same_executable_bytes(self):
        vm._validate_native(self.host, self.state, self.work, self.journal)
        self.executable.write_bytes(b'replaced executable')
        with self.assertRaisesRegex(RunnerError, 'executable changed'):
            vm._validate_native(self.host, self.state, self.work, self.journal)

    def test_retained_stop_path_cannot_escape_the_boot_directory(self):
        self.journal['native']['stopPath'] = str(self.state / 'unrelated-file')
        with self.assertRaisesRegex(RunnerError, 'paths or identity'):
            vm._validate_native(self.host, self.state, self.work, self.journal)

    def test_reused_pid_is_never_adopted(self):
        with patch.object(vm, 'process_identity', return_value={**self.process, 'start': [1001, 0]}):
            with self.assertRaisesRegex(RunnerError, 'process identity changed'):
                vm._native_alive(self.host, self.journal, None)

    def test_terminal_status_and_idle_disk_release_reused_pid(self):
        self.host.ensure_disk_idle = Mock()
        native = self.journal['native']
        session = native['sessionId'] = '00000000-0000-0000-0000-000000000001'
        for state in ('stopped', 'failed'):
            with self.subTest(state=state), patch.object(vm, 'process_identity', return_value={
                    'pid': self.process['pid'], 'start': [1001, 0]}):
                Path(native['statusPath']).write_text(json.dumps({'state': state, 'running': False,
                    'guestStarted': False, 'sessionId': session, 'vmPath': self.journal['vm'], 'hostPID': 101}))
                self.assertFalse(vm._native_alive(self.host, self.journal, None))
                self.host.ensure_disk_idle.assert_called_with(Path(self.journal['vm']))
                with patch.object(self.host, 'ensure_disk_idle', side_effect=RunnerError('disk busy')), \
                        self.assertRaisesRegex(RunnerError, 'disk busy'):
                    vm._native_alive(self.host, self.journal, None)
                if state == 'failed':
                    self.journal['startAttempted'] = True
                    with self.assertRaisesRegex(RunnerError, 'process identity changed'):
                        vm._native_alive(self.host, self.journal, None)
        self.assertFalse(Path(native['stopPath']).exists())

    def test_live_matching_process_can_be_adopted_without_a_popen_handle(self):
        with patch.object(vm, 'process_identity', return_value=self.process):
            self.assertTrue(vm._native_alive(self.host, self.journal, None))

    def executable_alias(self, directory, *, hardlink=True):
        directory.mkdir(parents=True, mode=0o700)
        alias = directory / 'VMHost'
        if hardlink:
            os.link(self.executable, alias)
        else:
            alias.write_bytes(self.executable.read_bytes())
        return alias

    def test_kernel_reported_hardlink_alias_inside_same_tool_state_is_accepted(self):
        alias = self.executable_alias(self.state / 'tools/sets/current')
        with patch.object(vm, 'process_identity', return_value={**self.process, 'executable': str(alias)}):
            self.assertTrue(vm._native_alive(self.host, self.journal, None))
        self.assertEqual(self.journal['native']['process'], self.process)

    def test_same_bytes_different_executable_inode_is_rejected(self):
        alias = self.executable_alias(self.state / 'tools/replaced', hardlink=False)
        with patch.object(vm, 'process_identity', return_value={**self.process, 'executable': str(alias)}):
            with self.assertRaisesRegex(RunnerError, 'vnode changed'):
                vm._native_alive(self.host, self.journal, None)

    def test_hardlink_outside_transaction_tools_is_rejected(self):
        alias = self.executable_alias(self.state / 'outside-tools')
        with patch.object(vm, 'process_identity', return_value={**self.process, 'executable': str(alias)}):
            with self.assertRaisesRegex(RunnerError, 'escaped'):
                vm._native_alive(self.host, self.journal, None)

    def test_symlink_alias_is_rejected_even_when_it_resolves_to_expected_binary(self):
        parent = self.state / 'tools/symlinked'
        parent.mkdir()
        alias = parent / 'VMHost'
        alias.symlink_to(self.executable)
        with patch.object(vm, 'process_identity', return_value={**self.process, 'executable': str(alias)}):
            with self.assertRaisesRegex(RunnerError, 'escaped'):
                vm._native_alive(self.host, self.journal, None)

    def test_aliased_executable_modified_in_place_fails_recorded_hash(self):
        alias = self.executable_alias(self.state / 'tools/sets/changed')
        alias.write_bytes(b'changed executable contents')
        with patch.object(vm, 'process_identity', return_value={**self.process, 'executable': str(alias)}):
            with self.assertRaisesRegex(RunnerError, 'executable changed'):
                vm._native_alive(self.host, self.journal, None)

    def test_aliased_executable_in_group_writable_directory_is_rejected(self):
        alias = self.executable_alias(self.state / 'tools/writable')
        alias.parent.chmod(0o770)
        with patch.object(vm, 'process_identity', return_value={**self.process, 'executable': str(alias)}):
            with self.assertRaisesRegex(RunnerError, 'directory changed ownership'):
                vm._native_alive(self.host, self.journal, None)

    def test_retained_status_cannot_switch_native_sessions(self):
        self.journal['native']['sessionId'] = '00000000-0000-0000-0000-000000000001'
        (self.boot / 'vm-status.json').write_text(json.dumps({'vmPath': self.journal['vm'], 'hostPID': 101,
            'sessionId': '00000000-0000-0000-0000-000000000002'}))
        with self.assertRaisesRegex(RunnerError, 'recorded process'):
            vm._native_status(self.host, self.journal)

    def test_resumed_access_uses_saved_pin_without_mounting_running_vm(self):
        scope = self.state / 'guest-access/fixture/access'
        scope.mkdir(parents=True)
        pin = scope / 'known-hosts-fixture'
        pin.write_text('public SSH pin')
        password = scope / 'password'
        password.write_text('fixture')
        record = {'vmId': 'fixture', 'consoleUser': 'wallet-test'}
        access = SimpleNamespace(candidate_mac=Mock(return_value='02:00:00:00:00:01'), prepare_guest_access=Mock())
        self.host.guest_access_module = lambda: access
        self.host.guest_setup_password = Mock(return_value=(scope, password))
        journal = {'upgradeNonce': 'a' * 64, 'access': {'macAddress': '02:00:00:00:00:01', 'knownHosts': str(pin),
            'knownHostsSHA256': self.host.hash_regular_file(pin), 'passwordFile': str(password), 'workDirectory': str(scope)}}
        _, context = vm._access_context(self.host, self.state, Path(self.journal['vm']), record, self.work, journal)
        self.assertEqual(context['knownHosts'], str(pin))
        access.prepare_guest_access.assert_not_called()
        pin.write_text('changed pin')
        with self.assertRaisesRegex(RunnerError, 'SSH pin changed'):
            vm._access_context(self.host, self.state, Path(self.journal['vm']), record, self.work, journal)
        access.prepare_guest_access.assert_not_called()


if __name__ == '__main__':
    unittest.main()
