import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location('macos_transport', Path(__file__).resolve().parents[1] / 'macos_transport.py')
transport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)
TARGET = {'version': '27.2', 'buildVersion': '26B123'}
BEFORE = {'version': '27.0.1', 'buildVersion': '26A434'}
BOOT = '12345678-1234-1234-1234-123456789012'
UPGRADE = 'macos-upgrade-fixture'


class MacOSTransportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.root.chmod(0o700)
        self.password = self.root / 'password'
        self.password.write_bytes(b'private-password\n')
        self.password.chmod(0o600)
        key_type = b'ssh-ed25519'
        key = base64.b64encode(len(key_type).to_bytes(4, 'big') + key_type + (32).to_bytes(4, 'big') + bytes(range(32))).decode()
        self.known = self.root / 'known-hosts'
        self.known.write_text('big-wallet-vm-fixture-vm ssh-ed25519 ' + key + '\n')
        self.known.chmod(0o600)
        self.context = {'address': '192.168.64.3', 'user': 'wallet-test', 'vmId': 'fixture-vm',
                        'upgradeNonce': 'a' * 64, 'knownHosts': self.known, 'passwordFile': self.password, 'workDirectory': self.root}
        self.request = transport._request(self.context, TARGET, UPGRADE)
        self.response = {'status': 'ready', 'actual': BEFORE, 'bootIdentity': BOOT, 'safeToStop': True}

    def launch(self, command, **kwargs):
        child = Mock(returncode=0)
        child.poll.return_value = 0
        def communicate(input, timeout):
            self.payload = input
            self.timeout = timeout
            kwargs['stdout'].write(transport.PREFIX + json.dumps(self.response).encode() + b'\n')
        child.communicate.side_effect = communicate
        return child

    def test_probe_uses_pinned_ssh_and_guest_guard_without_host_authentication(self):
        with patch.object(transport.subprocess, 'Popen', side_effect=self.launch) as launch:
            result = transport.probe(None, self.context, TARGET, UPGRADE)
        command = launch.call_args.args[0]
        self.assertEqual(command[0], '/usr/bin/ssh')
        self.assertIn('StrictHostKeyChecking=yes', command)
        self.assertIn('UseKeychain=no', command)
        self.assertIn('VirtualMac', command[-1])
        self.assertIn('/usr/bin/sudo', command[-1])
        self.assertNotIn('private-password', repr(command))
        self.assertNotIn('private-password', repr(launch.call_args.kwargs['env']))
        self.assertEqual(self.timeout, 300)
        self.assertEqual(result['actual'], BEFORE)
        self.assertEqual(list(self.root.glob('macos-askpass-*')), [])

    def test_start_secret_is_only_in_stdin_payload(self):
        self.response.update(status='installing', safeToStop=False)
        with patch.object(transport.subprocess, 'Popen', side_effect=self.launch) as launch:
            transport.start(None, self.context, TARGET, UPGRADE)
        self.assertEqual(self.payload.count(b'private-password'), 2)
        self.assertIn(transport.MARKER, self.payload)
        self.assertNotIn('private-password', repr(launch.call_args))

    def test_observe_has_short_bounded_timeout(self):
        self.response.update(status='blocked', reason='update_receipt_missing', safeToStop=False)
        with patch.object(transport.subprocess, 'Popen', side_effect=self.launch):
            transport.observe(None, self.context, TARGET, UPGRADE)
        self.assertEqual(self.timeout, 45)

    def test_password_matching_a_public_version_does_not_reject_valid_evidence(self):
        self.password.write_bytes(b'27.0.1\n')
        with patch.object(transport.subprocess, 'Popen', side_effect=self.launch):
            result = transport.probe(None, self.context, TARGET, UPGRADE)
        self.assertEqual(result['actual'], BEFORE)

    def test_disconnect_is_identifiably_unavailable_and_never_prints_output(self):
        def disconnected(command, **kwargs):
            child = Mock(returncode=255)
            child.poll.return_value = 255
            child.communicate.side_effect = lambda **ignored: kwargs['stdout'].write(b'Connection reset by peer\n')
            return child
        with patch.object(transport.subprocess, 'Popen', side_effect=disconnected):
            with self.assertRaises(transport.TransportUnavailable) as error:
                transport.start(None, self.context, TARGET, UPGRADE)
        self.assertNotIn('private-password', str(error.exception))
        self.assertEqual(list(self.root.glob('macos-askpass-*')), [])

    def test_nonzero_guest_rejection_is_not_retriable_transport_unavailable(self):
        child = Mock(returncode=1)
        child.poll.return_value = 1
        with patch.object(transport.subprocess, 'Popen', return_value=child):
            with self.assertRaises(transport.TransportError) as error:
                transport.start(None, self.context, TARGET, UPGRADE)
        self.assertNotIsInstance(error.exception, transport.TransportUnavailable)

    def test_timeout_is_unavailable_and_stops_only_owned_ssh_process(self):
        child = Mock(returncode=None, pid=987654)
        child.poll.side_effect = [None, -15]
        child.communicate.side_effect = subprocess.TimeoutExpired('ssh', 300)
        with patch.object(transport.subprocess, 'Popen', return_value=child), patch.object(transport.os, 'killpg') as kill:
            with self.assertRaises(transport.TransportUnavailable):
                transport.start(None, self.context, TARGET, UPGRADE)
        kill.assert_called_once_with(987654, transport.signal.SIGTERM)

    def test_response_rejects_wrong_receipt_target_and_false_completion(self):
        receipt = {'version': 1, **self.request, 'phase': 'installing'}
        for value in ({**self.response, 'status': 'complete'},
                      {**self.response, 'receipt': {**receipt, 'upgradeID': 'macos-upgrade-other'}},
                      {**self.response, 'receipt': {**receipt, 'target': BEFORE}},
                      {**self.response, 'bootIdentity': 'unknown'},
                      {**self.response, 'reason': 'raw password output'}):
            with self.subTest(value=value), self.assertRaises(transport.TransportError):
                transport._response(transport.PREFIX + json.dumps(value).encode(), self.request)

    def test_unsafe_password_permissions_and_unpinned_host_never_launch_ssh(self):
        self.password.chmod(0o644)
        with patch.object(transport.subprocess, 'Popen') as launch:
            with self.assertRaises(transport.TransportError):
                transport.probe(None, self.context, TARGET, UPGRADE)
            launch.assert_not_called()

    def test_diagnose_is_explicit_and_redacts_nested_guest_diagnostics(self):
        self.response.update(status='installing', safeToStop=False,
                             diagnostics={'installLog': ['macOS private-password'],
                                          'nested': {'reason': 'contains private-password text'}})
        with patch.object(transport.subprocess, 'Popen', side_effect=self.launch) as launch:
            result = transport.diagnose(None, self.context, TARGET, UPGRADE)
        self.assertTrue(launch.call_args.args[0][-1].endswith('observe --diagnostics'))
        self.assertEqual(self.payload.count(b'private-password'), 2)
        self.assertEqual(self.timeout, 45)
        self.assertNotIn('private-password', json.dumps(result))
        self.assertIn('[REDACTED]', json.dumps(result))

    def test_plain_observe_does_not_request_diagnostics_or_send_update_password(self):
        with patch.object(transport.subprocess, 'Popen', side_effect=self.launch) as launch:
            transport.observe(None, self.context, TARGET, UPGRADE)
        self.assertTrue(launch.call_args.args[0][-1].endswith(' observe'))
        self.assertEqual(self.payload.count(b'private-password'), 1)

    def test_diagnostic_bound_is_enforced_before_and_after_redaction(self):
        with self.assertRaises(transport.TransportError):
            transport._response(transport.PREFIX + json.dumps({**self.response, 'diagnostics': {
                'installLog': ['x' * 32768]}}).encode(), self.request)
        result = transport._redact_diagnostics({'diagnostics': {'installLog': ['x' * 32000]}}, 'x')
        self.assertLessEqual(len(json.dumps(result['diagnostics']).encode()), 32768)
        self.assertEqual(result['diagnostics'], {'unavailable': ['diagnostic_redaction_exceeded_limit']})

    def test_abandoned_halt_requires_host_supervisor_exit_confirmation(self):
        with patch.object(transport, '_invoke') as invoke:
            with self.assertRaisesRegex(transport.TransportError, 'verify supervisor exit'):
                transport.halt_abandoned(None, self.context, TARGET, UPGRADE)
            invoke.assert_not_called()
            confirmed = {**self.context, 'supervisorExited': True}
            transport.halt_abandoned(None, confirmed, TARGET, UPGRADE)
            invoke.assert_called_once_with(None, confirmed, TARGET, UPGRADE, 'halt-abandoned')

    def test_abandonment_response_is_bound_to_request_and_original_receipt_hash(self):
        value = {**self.response, 'status': 'blocked', 'safeToStop': False,
                 'reason': 'upgrade_abandoned_for_storage',
                 'abandonment': {'version': 1, **self.request, 'receiptSHA256': 'a' * 64}}
        self.assertEqual(transport._response(transport.PREFIX + json.dumps(value).encode(), self.request), value)
        value['abandonment']['upgradeID'] = 'macos-upgrade-other'
        with self.assertRaisesRegex(transport.TransportError, 'abandonment'):
            transport._response(transport.PREFIX + json.dumps(value).encode(), self.request)

    def growth(self):
        return {'oldBytes': 64 * 1024 ** 3, 'newBytes': 96 * 1024 ** 3, 'sectorBytes': 512,
            'mainPartitionBytes': 58 * 1024 ** 3, 'expectedContainerBytes': 90 * 1024 ** 3,
            'gapBytes': 32 * 1024 ** 3, 'mainFirstLBA': 1024, 'mainLastLBA': 2047,
            'recoveryFirstLBA': 4096, 'recoveryLastLBA': 8191, 'recoveryBytes': 2 * 1024 ** 2,
            'trailingPaddingSectors': 0, 'diskGUID': '11111111-1111-1111-1111-111111111111',
            'mainPartitionGUID': '22222222-2222-2222-2222-222222222222',
            'recoveryPartitionGUID': '33333333-3333-3333-3333-333333333333'}

    def grown_response(self, growth):
        return {**self.response, 'storage': {'status': 'grown', 'alreadyGrown': False,
            'upgradeID': UPGRADE, 'vmId': self.context['vmId'], 'growth': growth,
            'expectedContainerBytes': growth['expectedContainerBytes'], 'before': {},
            'after': {'main': {'bytes': growth['expectedContainerBytes'], 'uuid': growth['mainPartitionGUID']},
                'mainContainer': {'capacityBytes': growth['expectedContainerBytes']},
                'recovery': {'uuid': growth['recoveryPartitionGUID'], 'bytes': growth['recoveryBytes'],
                             'offset': growth['recoveryFirstLBA'] * growth['sectorBytes']}}}}

    def test_resize_composes_trusted_helper_and_only_public_proof_over_pinned_transport(self):
        growth = self.growth()
        self.response = self.grown_response(growth)
        with patch.object(transport.subprocess, 'Popen', side_effect=self.launch) as launch:
            result = transport.resize(None, self.context, TARGET, UPGRADE,
                                      {**growth, 'receipt': '/private/host/receipt.json', 'backupDisk': '/private/host/Disk.img'})
        command = launch.call_args.args[0]
        self.assertIn('STORAGE_SOURCE_BYTES', command[-1])
        self.assertTrue(command[-1].endswith(' resize'))
        self.assertNotIn(b'/private/host', self.payload)
        self.assertEqual(json.loads(self.payload.splitlines()[-1]), growth)
        self.assertEqual(self.payload.count(b'private-password'), 1)
        self.assertEqual(self.timeout, 900)
        self.assertEqual(result['storage']['status'], 'grown')

    def test_preflight_rejection_requires_bound_no_intent_proof(self):
        growth = self.growth()
        self.response.update(status='blocked', reason='guest_storage_main_bounds_mismatch',
                             storage={'status': 'preflight-rejected', 'request': self.request, 'growth': growth})
        with patch.object(transport.subprocess, 'Popen', side_effect=self.launch):
            self.assertTrue(transport.resize(None, self.context, TARGET, UPGRADE, growth)['safeToStop'])
            self.response['storage']['request'] = {**self.request, 'upgradeNonce': 'b' * 64}
            with self.assertRaises(transport.TransportError):
                transport.resize(None, self.context, TARGET, UPGRADE, growth)

    def test_blocked_admission_after_growth_requires_the_expected_reason_and_geometry(self):
        growth = self.growth()
        value = {**self.grown_response(growth), 'status': 'blocked', 'reason': 'guest_storage_insufficient_free_space_after_growth'}
        self.assertEqual(transport._resize_result(value, growth, self.request), value)
        with self.assertRaises(transport.TransportError):
            transport._resize_result({**value, 'reason': 'guest_storage_resize_failed'}, growth, self.request)
        value['storage']['after']['mainContainer']['capacityBytes'] -= 512
        with self.assertRaises(transport.TransportError):
            transport._resize_result(value, growth, self.request)

    def test_resize_refuses_untyped_sizes_and_arbitrary_partition_arguments(self):
        for change in ({'newBytes': '96G'}, {'newBytes': True}, {'mainPartitionGUID': 'disk0s2; shutdown'},
                       {'recoveryFirstLBA': -1}):
            with self.subTest(change=change), patch.object(transport.subprocess, 'Popen') as launch:
                with self.assertRaises(transport.TransportError):
                    transport.resize(None, self.context, TARGET, UPGRADE, {**self.growth(), **change})
                launch.assert_not_called()

    def test_resize_response_requires_proven_growth_or_protected_in_progress_state(self):
        growth = self.growth()
        value = self.grown_response(growth)
        value['storage']['after']['recovery']['offset'] += 512
        with self.assertRaises(transport.TransportError):
            transport._resize_result(value, growth, self.request)
        growing = {**self.response, 'status': 'installing', 'safeToStop': False, 'storage': {'status': 'growing'}}
        self.assertEqual(transport._resize_result(growing, growth, self.request), growing)
        with self.assertRaises(transport.TransportError):
            transport._resize_result({**growing, 'safeToStop': True}, growth, self.request)
        value = self.grown_response(growth)
        value['storage']['upgradeID'] = 'macos-upgrade-other'
        with self.assertRaises(transport.TransportError):
            transport._resize_result(value, growth, self.request)

    def test_only_scoped_known_live_os_probe_failures_are_retryable(self):
        for reason in ('guest_update_probe_unavailable', 'guest_update_probe_failed'):
            envelope = transport.PREFIX + json.dumps({'status': 'failed', 'reason': reason, 'scope': 'live-os-probe'}).encode()
            with self.subTest(reason=reason), self.assertRaises(transport.TransportUnavailable):
                transport._failed_transport(1, envelope)
        for error in ({'status': 'failed', 'reason': 'guest_upgrade_identity_mismatch'},
                      {'status': 'failed', 'reason': 'guest_update_probe_failed'},
                      {'status': 'failed', 'reason': 'invalid_guest_os_identity', 'scope': 'live-os-probe'},
                      {'status': 'failed', 'reason': 'guest_account_is_not_volume_owner'}):
            with self.subTest(error=error), self.assertRaises(transport.TransportError) as raised:
                transport._failed_transport(1, transport.PREFIX + json.dumps(error).encode())
            self.assertNotIsInstance(raised.exception, transport.TransportUnavailable)

    def test_authentication_trust_and_malformed_error_replies_remain_hard_failures(self):
        for code, output in ((255, b'Permission denied (password). private-password'),
                             (255, b'Host key verification failed.'),
                             (1, b'sudo: 1 incorrect password attempt'),
                             (1, transport.PREFIX + b'{broken'),
                             (1, transport.PREFIX + json.dumps({'status': 'failed', 'reason': '/private/password'}).encode())):
            with self.subTest(code=code, output=output), self.assertRaises(transport.TransportError) as raised:
                transport._failed_transport(code, output)
            self.assertNotIsInstance(raised.exception, transport.TransportUnavailable)
            self.assertNotIn('private-password', str(raised.exception))

    def test_nonzero_live_os_probe_envelope_is_read_through_real_transport_path(self):
        self.response = {'status': 'failed', 'reason': 'guest_update_probe_unavailable', 'scope': 'live-os-probe'}
        def failed_probe(command, **kwargs):
            child = self.launch(command, **kwargs)
            child.returncode = 1
            child.poll.return_value = 1
            return child
        with patch.object(transport.subprocess, 'Popen', side_effect=failed_probe):
            with self.assertRaises(transport.TransportUnavailable) as raised:
                transport.observe(None, self.context, TARGET, UPGRADE)
        self.assertIn('guest_update_probe_unavailable', str(raised.exception))


if __name__ == '__main__':
    unittest.main()
