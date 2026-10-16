import importlib.util
import itertools
from pathlib import Path
import plistlib
import tempfile
import types
import unittest
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location('setup_access_host', Path(__file__).resolve().parents[1] / 'host.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class SetupAccessTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.state = Path(temporary.name).resolve()
        self.vm = self.state / 'candidate.vbvm'
        self.vm.mkdir()
        self.run_id, self.exchange = host.new_exchange(self.state, 'setup')
        self.operation = {'runId': self.run_id, 'exchange': self.exchange, 'previousStops': [], 'monitorCalled': False}
        host.register_operation(self.state, self.vm, self.exchange, self.run_id, 'preparing')
        self.tools = {'test_manifest.mjs': 'a' * 64}
        self.record = {'vmId': 'fixture-vm', 'consoleUser': 'wallet-test'}
        self.request_id = '12345678-1234-1234-1234-123456789abc'
        self.config = {'consoleUser': 'wallet-test', 'autologin': {'passwordFile': 'account-password'},
                       'provisioningRequestID': self.request_id}
        (self.exchange / 'provision').mkdir(mode=0o700)
        (self.exchange / 'source').mkdir()
        (self.exchange / 'source/fixture').write_text('immutable source')
        (self.exchange / 'snapshot-manifest.json').write_text('{}')
        password = self.exchange / 'provision/account-password'
        password.write_text('fixture guest password\n')
        password.chmod(0o600)
        self.directory = host.private_directory(self.state / 'access')
        self.keys = self.directory / 'known-hosts'
        self.keys.write_text('fixture public key')
        self.access = {'macAddress': '02:00:00:00:00:01', 'hostKeyAlias': 'big-wallet-vm-fixture-vm',
                       'knownHosts': self.keys}
        self.args = host.parser().parse_args(['setup'])
        self.args.guest_user = 'wallet-test'
        self.source = {'sha256': 'b' * 64, 'commit': 'c' * 40}
        real = host.guest_access_module()
        self.module = types.SimpleNamespace(GuestAccessError=real.GuestAccessError,
            read_private_password=real.read_private_password,
            prepare_guest_access=Mock(return_value=self.access),
            find_guest_address=Mock(return_value='192.168.64.2'),
            SSHBannerProbe=Mock(side_effect=lambda _: Mock(poll=Mock(return_value={'status': 'passed'}))),
            GuestInstaller=Mock(side_effect=lambda *a, **kw: Mock(poll=Mock(return_value={'status': 'passed'}))))
        self.transfers = []
        self.exchange_module = types.SimpleNamespace(GuestExchange=Mock(side_effect=self.create_transfer))
        exchange_module = patch.object(host, 'guest_exchange_module', return_value=self.exchange_module)
        exchange_module.start()
        self.addCleanup(exchange_module.stop)
        self.calls = []

    def create_transfer(self, address, user, password, known_hosts, host_key_alias, directory, exchange):
        job = host.read_json(exchange / 'job.json')
        self.assertEqual(address, '192.168.64.2')
        self.assertEqual(user, 'wallet-test')
        self.assertEqual(known_hosts, self.keys)
        self.assertEqual(host_key_alias, self.access['hostKeyAlias'])

        def finish():
            host.atomic_json(exchange / 'artifacts/result.json', {
                'version': 1, 'runId': job['runId'], 'kind': job['kind'], 'status': 'passed',
                'finishedAt': 'fixture completion'})
            return {'status': 'passed'}

        transfer = Mock(poll=Mock(side_effect=finish))
        self.transfers.append(transfer)
        return transfer

    def drive(self, args, state, vm, exchange, run_id, *rest, setup_hook=None, **options):
        self.calls.append((exchange, setup_hook, options))
        if setup_hook is not None:
            self.assertFalse((exchange / 'job.json').exists())
            for _ in range(10):
                result = setup_hook.poll()
                if result is not None:
                    return result
                if setup_hook.exchange_complete:
                    break
            self.assertTrue(setup_hook.exchange_complete)
        job = host.read_json(exchange / 'job.json')
        self.assertEqual(job['kind'], 'doctor')
        self.assertEqual(job['runId'], run_id)
        return host.read_json(exchange / 'artifacts/result.json')

    def run_doctor(self, monitor=None):
        with patch.object(host, 'guest_access_module', return_value=self.module), \
                patch.object(host, 'monitor_vm', side_effect=monitor or self.drive), \
                patch.object(host, 'configure_guest_hardware'), patch.object(host, 'ensure_disk_idle'):
            return host.run_setup_doctor(self.args, self.state, self.vm, {}, self.operation, self.record,
                self.config, self.state / 'tools', self.tools, self.source, None, host.runner_source_digest())

    def test_existing_keys_install_before_publishing_readiness_job(self):
        result, exchange = self.run_doctor()
        self.assertEqual(result['status'], 'passed')
        self.assertEqual(exchange, self.exchange)
        self.assertEqual(len(self.calls), 1)
        self.module.GuestInstaller.assert_called_once()
        directory = self.state / 'guest-access/fixture-vm' / self.request_id
        self.module.prepare_guest_access.assert_called_once_with(self.vm,
            directory, 'fixture-vm', 'wallet-test', first_boot_ssh_requested=False)
        self.assertEqual(host.read_json(exchange / 'job.json')['source'], self.source)
        self.exchange_module.GuestExchange.assert_called_once_with('192.168.64.2', 'wallet-test',
            directory / 'password', self.keys, self.access['hostKeyAlias'], directory, self.exchange)
        self.transfers[0].poll.assert_called_once()
        self.assertTrue(self.operation['monitorCalled'])

    def test_first_key_generation_sends_no_password_and_pins_before_install(self):
        self.module.prepare_guest_access.side_effect = [{**self.access, 'knownHosts': None}, self.access]
        events = []
        def monitor(*args, **options):
            if not events:
                self.module.GuestInstaller.assert_not_called()
                self.assertIsNone(options['setup_hook'].job)
                events.append('key generation')
            else:
                self.assertEqual(self.module.prepare_guest_access.call_count, 2)
                events.append('pinned installation')
            return self.drive(*args, **options)
        result, exchange = self.run_doctor(monitor)
        self.assertEqual(result['status'], 'passed')
        self.assertEqual(events, ['key generation', 'pinned installation'])
        for call in self.module.prepare_guest_access.call_args_list:
            self.assertEqual(call.args[3], 'wallet-test')
            self.assertFalse(call.kwargs['first_boot_ssh_requested'])
        self.assertNotEqual(exchange, self.exchange)
        self.assertEqual((exchange / 'source/fixture').read_text(), 'immutable source')
        self.assertEqual((exchange / 'provision/account-password').read_bytes(),
                         (self.exchange / 'provision/account-password').read_bytes())
        self.assertEqual(self.operation['previousStops'], [(self.exchange, self.run_id)])
        self.assertEqual(host.read_json(self.state / 'active.json')['exchange'], str(exchange))

    def test_stop_after_key_boot_prevents_identity_read_and_install(self):
        self.module.prepare_guest_access.return_value = {**self.access, 'knownHosts': None}
        def stop(*args, **options):
            result = self.drive(*args, **options)
            host.atomic_json(self.exchange / 'stop.json', {'runId': self.run_id})
            return result
        with self.assertRaises(KeyboardInterrupt):
            self.run_doctor(stop)
        self.assertEqual(self.module.prepare_guest_access.call_count, 1)
        self.module.GuestInstaller.assert_not_called()

    def test_install_failure_never_publishes_a_doctor_job(self):
        self.module.GuestInstaller.side_effect = lambda *a, **kw: Mock(poll=Mock(
            return_value={'status': 'failed', 'reason': 'guest_install_failed'}))
        result, exchange = self.run_doctor()
        self.assertEqual(result['status'], 'failed')
        self.assertFalse((exchange / 'job.json').exists())
        self.exchange_module.GuestExchange.assert_not_called()

    def test_automatic_login_restart_is_bounded_and_precedes_readiness(self):
        self.module.GuestInstaller.side_effect = [
            Mock(poll=Mock(return_value={'status': 'restart-required'})),
            Mock(poll=Mock(return_value={'status': 'passed'}))]
        result, exchange = self.run_doctor()
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(result['status'], 'passed')
        self.assertFalse((self.exchange / 'job.json').exists())
        self.assertEqual(host.read_json(exchange / 'job.json')['kind'], 'doctor')

    def test_repeated_login_restart_request_fails_without_another_boot(self):
        self.module.GuestInstaller.side_effect = lambda *a, **kw: Mock(poll=Mock(return_value={'status': 'restart-required'}))
        result, exchange = self.run_doctor()
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['reason'], 'guest_automatic_login_did_not_become_available')
        self.assertFalse((exchange / 'job.json').exists())

    def test_missing_guest_password_fails_before_mount_or_authentication(self):
        self.config.pop('autologin')
        with self.assertRaisesRegex(host.RunnerError, 'existing guest account password'):
            self.run_doctor()
        self.module.prepare_guest_access.assert_not_called()
        self.module.GuestInstaller.assert_not_called()

    def test_saved_password_is_private_account_bound_and_reused(self):
        directory, password = host.guest_setup_password(self.module, self.state, self.record,
            self.config, self.exchange, None)
        self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual(password.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.record['guestAccessID'], self.request_id)
        self.config.pop('autologin')
        self.assertEqual(host.guest_setup_password(self.module, self.state, self.record,
            self.config, self.exchange, None), (directory, password))
        self.config['consoleUser'] = 'another-user'
        with self.assertRaisesRegex(host.RunnerError, 'existing guest account password'):
            host.guest_setup_password(self.module, self.state, self.record, self.config, self.exchange, None)

    def test_failed_candidate_password_or_account_update_preserves_baseline_access(self):
        directory, password = host.guest_setup_password(self.module, self.state, self.record,
            self.config, self.exchange, None)
        baseline = dict(self.record)
        host.atomic_json(self.state / 'baseline.json', baseline)
        preserved = {path.name: path.read_bytes() for path in (password, directory / 'identity.json')}
        baseline_vm = self.state / 'baseline.vbvm'
        baseline_vm.mkdir()
        self.module.GuestInstaller.side_effect = lambda *a, **kw: Mock(poll=Mock(
            return_value={'status': 'failed', 'reason': 'guest_install_failed', 'returnCode': 1}))
        for index, user in enumerate(('wallet-test', 'another-user')):
            with self.subTest(user=user):
                request_id = f'aaaaaaaa-bbbb-cccc-dddd-{index + 1:012d}'
                self.record = dict(baseline)
                self.config.update({'consoleUser': user, 'provisioningRequestID': request_id})
                self.password_path().write_text(f'fixture replacement password {index}\n')
                def check_persisted(*args, **kwargs):
                    self.assertEqual(host.read_json(self.state / 'candidate.json')['guestAccessID'], request_id)
                    return self.access
                self.module.prepare_guest_access.side_effect = check_persisted
                result, _ = self.run_doctor()
                self.assertEqual(result['status'], 'failed')
                self.assertEqual(host.read_json(self.state / 'baseline.json'), baseline)
                for name, contents in preserved.items():
                    self.assertEqual((directory / name).read_bytes(), contents)
                self.assertNotEqual(self.record['guestAccessID'], baseline['guestAccessID'])
                _, exchange = host.new_exchange(self.state, 'run')
                host.atomic_json(exchange / 'job.json', {'runId': exchange.name, 'vmId': baseline['vmId'], 'kind': 'run'})
                self.module.prepare_guest_access.side_effect = None
                with patch.object(host, 'guest_access_module', return_value=self.module):
                    hook = host.prepared_guest_hook(self.state, baseline_vm, baseline, exchange)
                self.assertEqual(hook.password, password)
                self.assertEqual(hook.user, baseline['consoleUser'])
                self.assertEqual(self.module.read_private_password(hook.password), b'fixture guest password')

    def test_pending_credential_scope_is_reused_without_rewriting_or_accepting_different_inputs(self):
        directory, password = host.guest_setup_password(self.module, self.state, self.record,
            self.config, self.exchange, None)
        originals = {path: (path.read_bytes(), path.stat().st_ino) for path in (password, directory / 'identity.json')}
        self.assertEqual(host.guest_setup_password(self.module, self.state, self.record,
            self.config, self.exchange, None), (directory, password))
        for changed in ('password', 'account'):
            with self.subTest(changed=changed):
                self.password_path().write_text('fixture changed password\n' if changed == 'password' else 'fixture guest password\n')
                configuration = {**self.config, 'consoleUser': 'another-user' if changed == 'account' else 'wallet-test'}
                record = dict(self.record)
                with self.assertRaises(host.RunnerError):
                    host.guest_setup_password(self.module, self.state, record, configuration, self.exchange, None)
                self.assertEqual(record, self.record)
                for path, original in originals.items():
                    self.assertEqual((path.read_bytes(), path.stat().st_ino), original)

    def test_explicit_credentials_require_a_valid_request_identity(self):
        for identifier in (None, '', '../outside', 'not-a-request'):
            with self.subTest(identifier=identifier):
                configuration = {**self.config, 'provisioningRequestID': identifier}
                with self.assertRaises(host.RunnerError):
                    host.guest_setup_password(self.module, self.state, self.record, configuration, self.exchange, None)
                self.assertNotIn('guestAccessID', self.record)

    def test_healthy_setup_refreshes_pinned_access_and_exchanges_without_reinstalling(self):
        self.record.update({'runnerTools': self.tools, 'runnerSourceDigest': host.runner_source_digest(),
                            'baseVerifiedAt': 'verified'})
        directory, password = host.guest_setup_password(self.module, self.state, self.record,
            self.config, self.exchange, None)
        self.config.pop('autologin')
        self.config.pop('provisioningRequestID')
        result, _ = self.run_doctor()
        self.assertEqual(result['status'], 'passed')
        self.module.prepare_guest_access.assert_called_once_with(self.vm, directory,
            'fixture-vm', 'wallet-test', first_boot_ssh_requested=False)
        self.module.GuestInstaller.assert_not_called()
        self.exchange_module.GuestExchange.assert_called_once_with('192.168.64.2', 'wallet-test',
            password, self.keys, self.access['hostKeyAlias'], directory, self.exchange)
        self.assertFalse(self.calls[0][1].install)

    def test_no_install_waits_for_banner_and_complete_export_before_readiness(self):
        transfer = Mock(poll=Mock(side_effect=[None, {'status': 'passed'}]))
        self.exchange_module.GuestExchange.side_effect = None
        self.exchange_module.GuestExchange.return_value = transfer
        hook = host.GuestSetupHook(self.module, self.access, 'wallet-test', self.password_path(),
                                  self.directory, self.exchange, {'kind': 'doctor'}, install=False)
        self.assertIsNone(hook.poll())
        self.module.SSHBannerProbe.assert_called_once_with('192.168.64.2')
        self.module.GuestInstaller.assert_not_called()
        self.assertFalse(hook.exchange_complete)
        self.assertIsNone(hook.poll())
        self.assertFalse(hook.exchange_complete)
        self.assertIsNone(hook.poll())
        self.assertTrue(hook.exchange_complete)
        hook.cancel()
        transfer.cancel.assert_called_once()

    def password_path(self):
        return self.exchange / 'provision/account-password'

    def test_stop_before_exchange_prevents_job_publication_after_installer_finishes(self):
        for install in (False, True):
            with self.subTest(install=install):
                hook = host.GuestSetupHook(self.module, self.access, 'wallet-test', self.password_path(),
                                          self.directory, self.exchange, {'kind': 'doctor'}, install=install)
                if install:
                    self.assertIsNone(hook.poll())
                hook.request_stop()
                self.assertIsNone(hook.poll())
                self.assertFalse((self.exchange / 'job.json').exists())
                self.exchange_module.GuestExchange.assert_not_called()
                with patch.object(host.time, 'sleep'):
                    hook.cancel()

    def test_exchange_failure_is_terminal_and_cannot_mark_export_complete(self):
        failure = {'status': 'failed', 'reason': 'guest_artifact_export_failed'}
        transfer = Mock(poll=Mock(return_value=failure))
        self.exchange_module.GuestExchange.side_effect = None
        self.exchange_module.GuestExchange.return_value = transfer
        hook = host.GuestSetupHook(self.module, self.access, 'wallet-test', self.password_path(),
                                  self.directory, self.exchange, {'kind': 'doctor'}, install=False)
        self.assertIsNone(hook.poll())
        self.assertEqual(hook.poll(), failure)
        self.assertFalse(hook.exchange_complete)
        self.assertIsNone(hook.poll())
        transfer.poll.assert_called_once()
        hook.request_stop()
        transfer.request_stop.assert_called_once()
        hook.cancel()
        transfer.cancel.assert_called_once()

    def test_prepared_run_uses_retained_account_and_pins_without_signing_input(self):
        directory, password = host.guest_setup_password(self.module, self.state, self.record,
            self.config, self.exchange, None)
        job = {'runId': self.run_id, 'vmId': 'fixture-vm', 'kind': 'run'}
        host.atomic_json(self.exchange / 'job.json', job)
        with patch.object(host, 'guest_access_module', return_value=self.module):
            hook = host.prepared_guest_hook(self.state, self.vm, self.record, self.exchange)
        self.assertFalse(hook.install)
        self.assertEqual(hook.job, job)
        self.assertEqual(hook.password, password)
        self.module.prepare_guest_access.assert_called_once_with(self.vm, directory, 'fixture-vm', 'wallet-test')
        self.module.GuestInstaller.assert_not_called()
        self.exchange_module.GuestExchange.assert_not_called()

    def test_prepared_run_rejects_missing_pinned_host_keys_before_authentication(self):
        host.guest_setup_password(self.module, self.state, self.record, self.config, self.exchange, None)
        self.module.prepare_guest_access.return_value = {**self.access, 'knownHosts': None}
        with patch.object(host, 'guest_access_module', return_value=self.module):
            with self.assertRaisesRegex(host.RunnerError, 'SSH identity is missing'):
                host.prepared_guest_hook(self.state, self.vm, self.record, self.exchange)
        self.module.SSHBannerProbe.assert_not_called()
        self.module.GuestInstaller.assert_not_called()
        self.exchange_module.GuestExchange.assert_not_called()

    def test_ssh_startup_waits_for_banner_without_sending_password(self):
        self.module.SSHBannerProbe.side_effect = [Mock(poll=Mock(return_value={'status': 'failed'})),
                                                Mock(poll=Mock(return_value={'status': 'passed'}))]
        hook = host.GuestSetupHook(self.module, self.access, 'wallet-test', self.keys,
                                  self.directory, self.exchange, {'kind': 'doctor'})
        with patch.object(host.time, 'monotonic', side_effect=[0, 0, 3, 4]):
            self.assertIsNone(hook.poll())
            self.module.GuestInstaller.assert_not_called()
            self.assertIsNone(hook.poll())
        self.module.GuestInstaller.assert_called_once()
        with patch.object(host.time, 'sleep') as grace:
            hook.cancel()
            grace.assert_called_once_with(20)
            hook.cancel()
            grace.assert_called_once_with(20)

    def test_lost_ssh_transport_retains_remote_rollback_grace(self):
        for code in (255, -15):
            with self.subTest(code=code):
                self.module.GuestInstaller.side_effect = lambda *a, **kw: Mock(poll=Mock(
                    return_value={'status': 'failed', 'reason': 'guest_install_failed', 'returnCode': code}))
                hook = host.GuestSetupHook(self.module, self.access, 'wallet-test', self.keys,
                                          self.directory, self.exchange, {'kind': 'doctor'})
                self.assertIsNone(hook.poll())
                self.assertEqual(hook.poll()['status'], 'failed')
                self.assertFalse((self.exchange / 'job.json').exists())
                with patch.object(host.time, 'sleep') as grace:
                    hook.cancel()
                    grace.assert_called_once_with(20)

    def test_local_cancel_failure_still_allows_remote_rollback(self):
        hook = host.GuestSetupHook(self.module, self.access, 'wallet-test', self.keys,
                                  self.directory, self.exchange, {'kind': 'doctor'})
        self.assertIsNone(hook.poll())
        hook.child.cancel.side_effect = OSError('fixture local cleanup failure')
        with patch.object(host.time, 'sleep') as grace:
            with self.assertRaises(OSError):
                hook.cancel()
            grace.assert_called_once_with(20)

    def test_monitor_hook_completion_stops_vm_and_cleans_up(self):
        process = Mock()
        process.poll.return_value = None
        hook = Mock(poll=Mock(return_value={'status': 'failed', 'reason': 'fixture install failure'}))
        def stopped(*_):
            process.poll.return_value = 0
        with patch.object(host.subprocess, 'Popen', return_value=process), \
                patch.object(host, 'stop_owned_process', side_effect=stopped), \
                patch.object(host.time, 'monotonic', side_effect=itertools.count()), patch.object(host.time, 'sleep'):
            result = host.monitor_vm(self.args, self.state, self.vm, self.exchange, self.run_id,
                self.state / 'tools', {'minimumHostFreeBytes': 1}, 30, setup_hook=hook)
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['reason'], 'guest_exchange_failed')
        self.assertEqual(result['guestFailure']['reason'], 'fixture install failure')
        hook.cancel.assert_called_once()
        self.assertFalse((self.state / 'active.json').exists())

    def test_candidate_network_identity_is_stable_and_distinct_from_source(self):
        (self.vm / '.vbdata').mkdir()
        path = self.vm / '.vbdata/Config.plist'
        original = {'systemType': 'mac', 'hardware': {'networkDevices': [{'macAddress': '02:00:00:00:00:01'}]}}
        path.write_bytes(plistlib.dumps(original))
        source = self.state / 'original-config.plist'
        source.write_bytes(path.read_bytes())
        machine = self.vm / 'MachineIdentifier'
        machine.write_bytes(b'unchanged guest machine identity')
        with patch.object(host, 'validate_vm', side_effect=lambda _: plistlib.loads(path.read_bytes())):
            host.configure_guest_hardware(self.vm, 'fixture-vm')
            first = plistlib.loads(path.read_bytes())['hardware']['networkDevices'][0]['macAddress']
            host.configure_guest_hardware(self.vm, 'fixture-vm')
            self.assertEqual(plistlib.loads(path.read_bytes())['hardware']['networkDevices'][0]['macAddress'], first)
            host.configure_guest_hardware(self.vm, 'another-vm')
            self.assertNotEqual(plistlib.loads(path.read_bytes())['hardware']['networkDevices'][0]['macAddress'], first)
        self.assertNotEqual(first, original['hardware']['networkDevices'][0]['macAddress'])
        self.assertEqual(int(first.split(':')[0], 16) & 3, 2)
        self.assertEqual(plistlib.loads(source.read_bytes()), original)
        self.assertEqual(machine.read_bytes(), b'unchanged guest machine identity')
