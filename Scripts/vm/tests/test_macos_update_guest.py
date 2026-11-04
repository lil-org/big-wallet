import importlib.util
import datetime
import contextlib
import fcntl
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location('macos_update_guest', Path(__file__).resolve().parents[1] / 'macos_update_guest.py')
guest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guest)
TARGET = {'version': '27.2', 'buildVersion': '26B123'}
BEFORE = {'version': '27.0.1', 'buildVersion': '26A434'}
BOOT = '12345678-1234-1234-1234-123456789012'
NEXT_BOOT = '12345678-1234-1234-1234-123456789013'
REQUEST = {'vmId': 'fixture-vm', 'consoleUser': 'wallet-test', 'upgradeID': 'macos-upgrade-fixture', 'upgradeNonce': 'a' * 64, 'target': TARGET}
OFFER_TEXT = '''Software Update Tool
Finding available software
Software Update found the following new or updated software:
* Label: macOS Test 27.2-26B123
    Title: macOS Test 27.2, Version: 27.2, Size: 4523123K, Recommended: YES, Action: restart,
* Label: Safari27.2TestAuto-27.2
    Title: Safari, Version: 27.2, Size: 245612K, Recommended: YES,
'''


def receipt(**updates):
    return {'version': 1, **REQUEST, 'phase': 'installing', 'before': BEFORE, 'preBootIdentity': BOOT,
            'workerPID': 1234, 'workerStart': 'Tue Nov  3 12:00:00 2026', 'safeToStop': False,
            'offer': guest.exact_offer(OFFER_TEXT, TARGET), **updates}


class GuestUpdateTests(unittest.TestCase):
    def test_offer_requires_exact_version_build_and_stable_macos(self):
        offer = guest.exact_offer(OFFER_TEXT, TARGET)
        self.assertEqual(offer['label'], 'macOS Test 27.2-26B123')
        self.assertEqual(offer['downloadBytes'], 4523123 * 1024)
        for output in (OFFER_TEXT.replace('26B123', '26B124'), OFFER_TEXT.replace('Version: 27.2', 'Version: 27.1'),
                       OFFER_TEXT.replace('macOS Test', 'macOS Test Beta'), OFFER_TEXT.replace('macOS Test', 'Safari Test'),
                       OFFER_TEXT + OFFER_TEXT):
            with self.subTest(output=output), self.assertRaises(guest.UpdateError):
                guest.exact_offer(output, TARGET)

    def test_request_rejects_beta_targets_and_path_or_shell_inputs(self):
        for target in ({'version': '27.2', 'buildVersion': '26B123a'}, {'version': '27', 'buildVersion': '26B123'},
                       {'version': '27.2;reboot', 'buildVersion': '26B123'}):
            with self.subTest(target=target), self.assertRaises(guest.UpdateError):
                guest.validate_request({**REQUEST, 'target': target})
        for key, value in (('upgradeID', '../macos-upgrade-fixture'), ('consoleUser', 'root; id'), ('vmId', '../vm')):
            with self.subTest(key=key), self.assertRaises(guest.UpdateError):
                guest.validate_request({**REQUEST, key: value})

    def test_volume_ownership_requires_selected_generated_uid_and_true_flag(self):
        guid = 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE'
        for users, expected in ([{'APFSCryptoUserUUID': guid, 'VolumeOwner': True}], True), ([{'APFSCryptoUserUUID': guid, 'VolumeOwner': False}], False), ([{'APFSCryptoUserUUID': guid, 'VolumeOwner': 'true'}], False), ([{'APFSCryptoUserUUID': BOOT, 'VolumeOwner': True}], False):
            with self.subTest(users=users), patch.object(guest, 'text', return_value='GeneratedUID: ' + guid), \
                    patch.object(guest, 'run', return_value=plistlib.dumps({'Users': users})):
                self.assertEqual(guest.owner('wallet-test')['volumeOwner'], expected)

    def test_attestation_refuses_host_before_reading_identity(self):
        with patch.object(guest.os, 'geteuid', return_value=0), patch.object(guest, 'text', return_value='Mac14,9'), \
                patch.object(guest, 'read_json') as read:
            with self.assertRaisesRegex(guest.UpdateError, 'virtual_machine'):
                guest.attest(REQUEST)
            read.assert_not_called()

    def test_attestation_requires_matching_provisioned_vm_and_user(self):
        with patch.object(guest.os, 'geteuid', return_value=0), \
                patch.object(guest, 'text', side_effect=['VirtualMac2,1', 'arm64']), \
                patch.object(guest, 'protected'), patch.object(guest, 'read_json', return_value={
                    'version': 1, 'vmId': 'other-vm', 'consoleUser': REQUEST['consoleUser']}):
            with self.assertRaisesRegex(guest.UpdateError, 'identity_mismatch'):
                guest.attest(REQUEST)

    def test_another_clone_with_same_vm_account_and_ssh_identity_cannot_start_an_action(self):
        baseline = {'version': 1, 'vmId': REQUEST['vmId'], 'consoleUser': REQUEST['consoleUser']}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            identity = root / 'identity.json'
            identity.write_text(json.dumps(baseline))
            marker = root / ('enrollment-' + REQUEST['upgradeID'] + '-' + REQUEST['upgradeNonce'])
            with patch.object(guest, 'IDENTITY_DIRECTORY', root), patch.object(guest.os, 'geteuid', return_value=0), \
                    patch.object(guest, 'protected', side_effect=lambda path, **kwargs: path.lstat()), \
                    patch.object(guest, 'read_json', return_value=baseline), patch.object(guest, 'private_directory') as mutate:
                for mismatch in ('missing', 'copied'):
                    if mismatch == 'copied':
                        marker.write_bytes(identity.read_bytes())
                    with self.subTest(mismatch=mismatch), patch.object(guest, 'text', side_effect=['VirtualMac2,1', 'arm64']):
                        with self.assertRaisesRegex(guest.UpdateError, 'candidate_binding_mismatch'):
                            guest.start(REQUEST, b'fixture', b'worker')
                mutate.assert_not_called()
                marker.unlink()
                os.link(identity, marker)
                with patch.object(guest, 'text', side_effect=['VirtualMac2,1', 'arm64', BEFORE['version'], BEFORE['buildVersion'], BOOT]), \
                        patch.object(guest.pwd, 'getpwnam', return_value=SimpleNamespace(pw_uid=501)):
                    self.assertEqual(guest.attest(REQUEST)['actual'], BEFORE)

    def test_exact_already_installed_target_skips_owner_and_offer_scan(self):
        evidence = {'actual': TARGET, 'bootIdentity': BOOT}
        with patch.object(guest, 'attest', return_value=evidence), patch.object(guest, 'matching_receipt', return_value=None), \
                patch.object(guest, 'prerequisite') as prerequisite:
            self.assertEqual(guest.inspect(REQUEST, 'probe')['status'], 'complete')
            prerequisite.assert_not_called()

    def test_observe_without_receipt_cannot_authorize_stop_or_restart_install(self):
        for actual in (BEFORE, TARGET):
            with self.subTest(actual=actual), patch.object(guest, 'attest', return_value={'actual': actual, 'bootIdentity': BOOT}), \
                    patch.object(guest, 'matching_receipt', return_value=None), patch.object(guest, 'prerequisite') as prerequisite:
                result = guest.inspect(REQUEST, 'observe')
                self.assertEqual(result['reason'], 'update_receipt_missing')
                self.assertFalse(result['safeToStop'])
                prerequisite.assert_not_called()

    def test_target_version_requires_new_boot_before_completion(self):
        for phase in ('installing', 'complete'):
            with self.subTest(phase=phase), patch.object(guest, 'worker_alive', return_value=False):
                result = guest.receipt_result(REQUEST, {'actual': TARGET, 'bootIdentity': BOOT}, receipt(phase=phase))
                self.assertEqual(result['status'], 'installing')
                self.assertFalse(result['safeToStop'])

    def test_new_boot_with_target_completes_and_persists_bound_receipt(self):
        with patch.object(guest, 'worker_alive', return_value=False), patch.object(guest, 'write_json') as write:
            result = guest.receipt_result(REQUEST, {'actual': TARGET, 'bootIdentity': NEXT_BOOT}, receipt(), persist=True)
        self.assertEqual(result['status'], 'complete')
        self.assertTrue(result['safeToStop'])
        self.assertEqual(result['receipt']['target'], TARGET)
        self.assertEqual(write.call_args.args[1]['phase'], 'complete')

    def test_diagnosis_of_cold_target_boot_leaves_receipt_untouched(self):
        current = receipt()
        with patch.object(guest, 'attest', return_value={'actual': TARGET, 'bootIdentity': NEXT_BOOT}), \
                patch.object(guest, 'matching_receipt', return_value=current), \
                patch.object(guest, 'matching_abandonment', return_value=None), \
                patch.object(guest, 'worker_alive', return_value=False), patch.object(guest, 'write_json') as write:
            completed = guest.inspect(REQUEST, 'observe', 'diagnostic-password')
        self.assertEqual(completed['status'], 'complete')
        self.assertEqual(completed['receipt']['phase'], 'installing')
        write.assert_not_called()

    def test_manual_completion_probe_persists_receipt_for_future_upgrades(self):
        current = receipt(phase='failed', reason='softwareupdate_failed', safeToStop=True)
        with patch.object(guest, 'attest', return_value={'actual': TARGET, 'bootIdentity': NEXT_BOOT}), \
                patch.object(guest, 'matching_receipt', return_value=current), \
                patch.object(guest, 'matching_abandonment', return_value=None), \
                patch.object(guest, 'worker_alive', return_value=False), patch.object(guest, 'write_json') as write:
            completed = guest.inspect(REQUEST, 'probe')
        self.assertEqual(completed['status'], 'complete')
        persisted = write.call_args.args[1]
        self.assertEqual(persisted['phase'], 'complete')
        self.assertTrue(persisted['safeToStop'])
        self.assertEqual(persisted['target'], TARGET)
        next_request = {**REQUEST, 'upgradeID': 'macos-upgrade-next',
                        'target': {'version': '27.3', 'buildVersion': '26C100'}}
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve() / 'upgrades'
            with patch.object(guest, 'UPGRADE_DIRECTORY', directory), patch.object(guest, 'protected'), \
                    patch.object(guest, 'attest', return_value={'actual': TARGET, 'bootIdentity': NEXT_BOOT}), \
                    patch.object(guest, 'matching_receipt', side_effect=[None, persisted]), \
                    patch.object(guest, 'read_json', return_value=REQUEST), patch.object(guest, 'worker_alive', return_value=False), \
                    patch.object(guest, 'prerequisite', return_value={'status': 'ready', 'owner': persisted['owner'] if 'owner' in persisted else {},
                        'offer': {'label': 'macOS Test 27.3-26C100', **next_request['target']}}), \
                    patch.object(guest, 'write_json'), patch.object(guest, 'write_bytes'), \
                    patch.object(guest.subprocess, 'Popen', return_value=Mock(stdin=io.BytesIO())) as launch:
                result = guest.start(next_request, b'private-password', b'worker source')
            self.assertEqual(result['status'], 'installing')
            launch.assert_called_once()

    def test_reboot_to_wrong_build_never_authorizes_reinstall_or_stop(self):
        with patch.object(guest, 'worker_alive', return_value=False):
            result = guest.receipt_result(REQUEST, {'actual': BEFORE, 'bootIdentity': NEXT_BOOT}, receipt())
        self.assertEqual(result['status'], 'installing')
        self.assertFalse(result['safeToStop'])

    def test_safe_terminal_failure_is_distinct_from_missing_worker(self):
        with patch.object(guest, 'worker_alive', return_value=False):
            failed = guest.receipt_result(REQUEST, {'actual': BEFORE, 'bootIdentity': BOOT},
                                          receipt(phase='failed', reason='softwareupdate_failed', safeToStop=True))
            uncertain = guest.receipt_result(REQUEST, {'actual': BEFORE, 'bootIdentity': BOOT}, receipt())
        self.assertTrue(failed['safeToStop'])
        self.assertFalse(uncertain['safeToStop'])

    def test_symlinked_protected_path_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / 'regular').write_text('{}')
            (root / 'alias').symlink_to(root / 'regular')
            with self.assertRaisesRegex(guest.UpdateError, 'unprotected'):
                guest.protected(root / 'alias')

    def test_worker_launch_uses_detached_process_and_password_stdin_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve() / 'upgrades'
            candidate = Mock(stdin=io.BytesIO())
            writes = []
            with patch.object(guest, 'UPGRADE_DIRECTORY', directory), patch.object(guest, 'protected'), \
                    patch.object(guest, 'attest', return_value={'actual': BEFORE, 'bootIdentity': BOOT}), \
                    patch.object(guest, 'matching_receipt', return_value=None), patch.object(guest, 'read_json', return_value=None), \
                    patch.object(guest, 'prerequisite', return_value={'status': 'ready', 'owner': {'volumeOwner': True},
                                                                   'offer': guest.exact_offer(OFFER_TEXT, TARGET)}), \
                    patch.object(guest, 'write_json', side_effect=lambda path, value: writes.append((path, dict(value)))), \
                    patch.object(guest, 'write_bytes') as write_source, \
                    patch.object(guest.subprocess, 'Popen', return_value=candidate) as launch:
                result = guest.start(REQUEST, b'private-password', b'worker source')
            self.assertEqual(result['status'], 'installing')
            self.assertTrue(launch.call_args.kwargs['start_new_session'])
            self.assertNotIn('private-password', repr(launch.call_args))
            self.assertNotIn('private-password', repr(writes))
            self.assertNotIn('private-password', repr(write_source.call_args))
            self.assertEqual([path.name for path, _ in writes], ['request.json', 'receipt.json', 'active.json'])
            self.assertEqual(result['receipt']['phase'], 'starting')

    def test_existing_receipt_does_not_launch_another_worker(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve() / 'upgrades'
            with patch.object(guest, 'UPGRADE_DIRECTORY', directory), patch.object(guest, 'protected'), \
                    patch.object(guest, 'attest', return_value={'actual': BEFORE, 'bootIdentity': BOOT}), \
                    patch.object(guest, 'matching_receipt', return_value=receipt()), \
                    patch.object(guest, 'worker_alive', return_value=False), patch.object(guest.subprocess, 'Popen') as launch:
                result = guest.start(REQUEST, b'private-password', b'worker source')
            self.assertEqual(result['status'], 'installing')
            launch.assert_not_called()

    def test_interrupted_worker_launch_is_settled_only_after_the_lock_is_free(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            lock = directory / 'operation.lock'
            current = receipt(phase='starting')
            with patch.object(guest, 'UPGRADE_DIRECTORY', directory), patch.object(guest, 'protected'), \
                    patch.object(guest, 'attest', return_value={'actual': BEFORE, 'bootIdentity': BOOT}), \
                    patch.object(guest, 'matching_receipt', return_value=current), \
                    patch.object(guest, 'matching_abandonment', return_value=None), \
                    patch.object(guest, 'worker_alive', return_value=False), patch.object(guest, 'write_json') as write:
                with lock.open('wb') as held:
                    fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    self.assertEqual(guest.inspect(REQUEST, 'observe')['status'], 'installing')
                diagnostic = guest.inspect(REQUEST, 'observe', 'diagnostic-password')
                self.assertTrue(diagnostic['safeToStop'])
                write.assert_not_called()
                settled = guest.inspect(REQUEST, 'observe')
                self.assertEqual(settled['status'], 'failed')
                self.assertEqual(settled['reason'], 'guest_update_worker_launch_failed')
                write.assert_called_once_with(guest.receipt_path(REQUEST), settled['receipt'])

    def test_completed_previous_upgrade_allows_next_target_without_erasing_history(self):
        old_request = {**REQUEST, 'upgradeID': 'macos-upgrade-previous', 'upgradeNonce': 'b' * 64, 'target': BEFORE}
        old_receipt = {**receipt(phase='complete', safeToStop=True, actual=BEFORE), **old_request,
                       'offer': {'label': 'macOS Test 27.0.1-26A434', **BEFORE}}
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve() / 'upgrades'
            prior = directory / old_request['upgradeID']
            prior.mkdir(parents=True)
            (prior / 'receipt.json').write_text(json.dumps(old_receipt))
            (directory / 'active.json').write_text(json.dumps(guest.attempt_identity(old_request)))
            def read_json(path, *, missing=False):
                return None if missing and not path.exists() else json.loads(path.read_text())
            with patch.object(guest, 'UPGRADE_DIRECTORY', directory), patch.object(guest, 'protected'), \
                    patch.object(guest, 'attest', return_value={'actual': BEFORE, 'bootIdentity': NEXT_BOOT}), \
                    patch.object(guest, 'read_json', side_effect=read_json), patch.object(guest, 'worker_alive', return_value=False), \
                    patch.object(guest, 'prerequisite', return_value={'status': 'ready', 'owner': {'volumeOwner': True},
                                                                   'offer': guest.exact_offer(OFFER_TEXT, TARGET)}), \
                    patch.object(guest, 'write_json') as write, patch.object(guest, 'write_bytes'), \
                    patch.object(guest.subprocess, 'Popen', return_value=Mock(stdin=io.BytesIO())) as launch:
                result = guest.start(REQUEST, b'private-password', b'worker source')
            self.assertEqual(result['status'], 'installing')
            launch.assert_called_once()
            self.assertTrue(all('macos-upgrade-previous' not in str(call.args[0]) for call in write.call_args_list))

    def test_incomplete_other_upgrade_blocks_new_install(self):
        old_request = {**REQUEST, 'upgradeID': 'macos-upgrade-previous'}
        old_receipt = {**receipt(), **old_request}
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve() / 'upgrades'
            with patch.object(guest, 'UPGRADE_DIRECTORY', directory), patch.object(guest, 'protected'), \
                    patch.object(guest, 'attest', return_value={'actual': BEFORE, 'bootIdentity': BOOT}), \
                    patch.object(guest, 'matching_receipt', side_effect=[None, old_receipt]), \
                    patch.object(guest, 'read_json', return_value=old_request), patch.object(guest.subprocess, 'Popen') as launch:
                result = guest.start(REQUEST, b'private-password', b'worker source')
            self.assertEqual(result['reason'], 'another_guest_upgrade_is_recorded')
            self.assertFalse(result['safeToStop'])
            launch.assert_not_called()

    def worker_fixture(self, temporary, *, fail_after_launch=False, fail_after_exit=False):
        root = Path(temporary).resolve() / 'upgrades'
        directory = root / REQUEST['upgradeID']
        directory.mkdir(parents=True)
        lock = root / 'operation.lock'
        lock.write_bytes(b'')
        metadata = lock.stat()
        lock_metadata = SimpleNamespace(st_mode=0o100600, st_uid=0, st_dev=metadata.st_dev, st_ino=metadata.st_ino)
        stream = Mock()
        child = Mock(stdin=stream, pid=2468)
        child.wait.return_value = 0 if fail_after_exit else 1
        child.poll.return_value = 0 if fail_after_exit else None
        records = []
        def write(path, value):
            if fail_after_exit and value.get('phase') == 'restart-pending':
                raise OSError('fixture write failure after successful exit')
            if fail_after_launch and value.get('installerPID') and not records[-1].get('installerPID'):
                records.append(dict(value))
                raise OSError('fixture write failure')
            records.append(dict(value))
        with patch.object(guest, 'UPGRADE_DIRECTORY', root), patch.object(guest, 'protected'), \
                patch.object(guest, 'read_json', return_value=REQUEST), \
                patch.object(guest, 'attest', return_value={'actual': BEFORE, 'bootIdentity': BOOT}), \
                patch.object(guest, 'matching_receipt', return_value=receipt(phase='starting')), \
                patch.object(guest.os, 'fstat', return_value=lock_metadata), \
                patch.object(guest.sys, 'stdin', SimpleNamespace(buffer=io.BytesIO(b'private-password\n'))), \
                patch.object(guest, 'process_start', return_value='fixture-start'), \
                patch.object(guest, 'write_json', side_effect=write), \
                patch.object(guest, 'UpdateOutput', return_value=Mock(capture=SimpleNamespace(contents=b'Preparing to restart'), finish=Mock(return_value={
                    'outputLog': 'softwareupdate.log', 'outputComplete': True, 'outputTruncated': False, 'outputUnavailable': False}))), \
                patch.object(guest.subprocess, 'Popen', return_value=child) as launch:
            guest.worker(directory, 10)
        return launch.call_args, stream, records

    def test_worker_runs_only_exact_guest_update_with_secret_stdin(self):
        with tempfile.TemporaryDirectory() as temporary:
            launch, stream, records = self.worker_fixture(temporary)
        self.assertEqual(launch.args[0], ['/usr/sbin/softwareupdate', '--install', 'macOS Test 27.2-26B123',
                                         '--restart', '--user', 'wallet-test', '--stdinpass'])
        stream.write.assert_called_once_with(b'private-password\n')
        self.assertEqual(launch.kwargs['stdout'], subprocess.PIPE)
        self.assertEqual(launch.kwargs['stderr'], subprocess.STDOUT)
        self.assertNotIn('private-password', repr(records))
        self.assertEqual(records[-1]['exitCode'], 1)
        self.assertFalse(records[-1]['safeToStop'])
        self.assertEqual(records[-1]['phase'], 'installing')

    def test_worker_record_error_after_launch_never_claims_safe_to_stop(self):
        with tempfile.TemporaryDirectory() as temporary:
            _, _, records = self.worker_fixture(temporary, fail_after_launch=True)
        self.assertEqual(records[-1]['phase'], 'installing')
        self.assertFalse(records[-1]['safeToStop'])

    def test_worker_error_after_successful_cli_exit_still_preserves_vm(self):
        with tempfile.TemporaryDirectory() as temporary:
            _, _, records = self.worker_fixture(temporary, fail_after_exit=True)
        self.assertFalse(records[-1]['safeToStop'])
        self.assertEqual(records[-1]['phase'], 'installing')

    def test_signalled_cli_is_an_uncertain_handoff(self):
        outcome = guest.update_outcome(-15, b'failed to authenticate', {'outputComplete': True})
        self.assertFalse(outcome['safeToStop'])
        self.assertEqual(outcome['exitCode'], -15)

    def test_active_installation_diagnostics_require_explicit_secret_opt_in(self):
        old = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=180)).isoformat()
        for phase, updated, action, password, expected in (
                ('restart-pending', old, 'observe', 'secret', True),
                ('installing', old, 'observe', 'secret', True),
                ('restart-pending', guest.timestamp(), 'observe', 'secret', True),
                ('restart-pending', old, 'observe', None, False),
                ('restart-pending', old, 'probe', 'secret', False)):
            with self.subTest(phase=phase, action=action, password=password), \
                    patch.object(guest, 'attest', return_value={'actual': BEFORE, 'bootIdentity': BOOT}), \
                    patch.object(guest, 'matching_receipt', return_value=receipt(phase=phase, updatedAt=updated)), \
                    patch.object(guest, 'matching_abandonment', return_value=None), \
                    patch.object(guest, 'worker_alive', return_value=False), \
                    patch.object(guest, 'diagnostics', return_value={'processes': []}) as diagnose:
                result = guest.inspect(REQUEST, action, password)
            self.assertEqual(diagnose.called, expected)
            self.assertEqual('diagnostics' in result, expected)

    def test_inspect_fixtures_never_stat_or_read_protected_guest_state(self):
        for action, actual, boot, expected in (('observe', BEFORE, BOOT, 'installing'),
                                               ('probe', TARGET, NEXT_BOOT, 'complete')):
            with self.subTest(action=action), \
                    patch.object(guest, 'attest', return_value={'actual': actual, 'bootIdentity': boot}), \
                    patch.object(guest, 'matching_receipt', return_value=receipt()), \
                    patch.object(guest, 'matching_abandonment', return_value=None) as abandonment, \
                    patch.object(guest, 'worker_alive', return_value=False), patch.object(guest, 'write_json'), \
                    patch.object(guest, 'diagnostics', return_value={'processes': []}), \
                    patch.object(guest, 'read_json', side_effect=AssertionError('Unexpected guest state read')) as read, \
                    patch.object(Path, 'lstat', side_effect=PermissionError('Protected guest state')) as metadata:
                result = guest.inspect(REQUEST, action, 'fixture-password')
                self.assertEqual(result['status'], expected)
                abandonment.assert_called_once()
                read.assert_not_called()
                metadata.assert_not_called()

    def test_diagnostics_are_bounded_whitelisted_and_redacted(self):
        history = [{'displayName': f'macOS test {index}', 'displayVersion': '27.2',
                    'date': datetime.datetime(2026, 11, 3)} for index in range(8)]
        history.append({'displayName': 'Unrelated application', 'displayVersion': '1.0',
                        'date': datetime.datetime(2026, 11, 3)})
        log = '\n'.join('macOS private-password ' + 'x' * 800 for _ in range(90)).encode()
        def contents(path, maximum, **kwargs):
            if path == guest.receipt_path(REQUEST).parent / 'softwareupdate.log':
                self.assertEqual(maximum, guest.MAX_UPDATE_OUTPUT)
                return b'installer: private-password\n'
            return plistlib.dumps(history) if path.name == 'InstallHistory.plist' else log
        process_output = '\n'.join(f'{100 + index} 1 /usr/sbin/softwareupdated' for index in range(40))
        process_output += '\n333 1 /usr/bin/unrelated\n444 1 /System/Library/osinstallersetupd\n'
        with patch.object(guest, 'text', return_value=process_output) as run, \
                patch.object(guest, 'unified_update_log', return_value=['softwareupdated private-password download progress']), \
                patch.object(guest, 'protected_bytes', side_effect=contents), \
                patch.object(guest, 'run', return_value=plistlib.dumps({'AllDisksAndPartitions': []})), \
                patch.object(guest, 'cache_sizes', return_value=[]), \
                patch.object(guest.os, 'statvfs', return_value=SimpleNamespace(f_blocks=100, f_bfree=30, f_bavail=20, f_frsize=4096)):
            result = guest.diagnostics('private-password', receipt())
        self.assertLessEqual(len(json.dumps(result).encode()), guest.MAX_DIAGNOSTICS)
        self.assertEqual(len(result['installHistory']), 5)
        self.assertLessEqual(len(result['processes']), 32)
        self.assertLessEqual(len(result['installLog']), 24)
        self.assertEqual(result['cliOutput'], ['installer: [REDACTED]'])
        self.assertNotIn('private-password', json.dumps(result))
        self.assertNotIn('Unrelated', json.dumps(result))
        run.assert_called_once_with(['/bin/ps', '-axo', 'pid=,ppid=,comm='], timeout=5, limit=1024 * 1024)

    def test_diagnostics_skip_unavailable_sources_without_raw_errors(self):
        with patch.object(guest, 'text', side_effect=guest.UpdateError('private-password')), \
                patch.object(guest, 'unified_update_log', side_effect=guest.UpdateError('private-password')), \
                patch.object(guest, 'protected_bytes', side_effect=FileNotFoundError('private-password')), \
                patch.object(guest, 'run', side_effect=guest.UpdateError('private-password')), \
                patch.object(guest, 'cache_sizes', side_effect=guest.UpdateError('private-password')), \
                patch.object(guest.os, 'statvfs', side_effect=OSError('private-password')):
            result = guest.diagnostics('private-password', receipt())
        self.assertTrue({'system_storage', 'build_storage', 'disk_layout', 'scoped_cache_sizes',
                         'update_processes', 'macos_install_history', 'installer_log',
                         'softwareupdate_output'}.issubset(result['unavailable']))
        self.assertNotIn('private-password', json.dumps(result))

    def test_diagnostics_select_original_installer_and_attempt_window_across_timezones(self):
        lines = [
            '2026-11-03 02:39:35-08 guest softwareupdated[291]: request starts',
            '2026-11-03 02:39:43-08 guest softwareupdate[803]: install refused',
            '2026-11-03 02:41:30-08 guest softwareupdated[291]: attempt followup',
            '2026-11-03 02:41:40-08 guest softwareupdated[291]: outside attempt',
            '2026-11-03 02:43:09-08 guest softwareupdated[291]: unrelated background scan',
        ]
        result = guest.attempt_log_lines(lines, receipt(createdAt='2026-11-03T10:39:35+00:00', installerPID=803))
        self.assertEqual(result, [lines[1], lines[0], lines[2]])

    def test_cli_output_redacts_secrets_crossing_every_chunk_boundary(self):
        password = b'private-password'
        raw = b'progress ' + password + b' failed ' + password + b'\n'
        for size in range(1, len(password) + 2):
            capture = guest.RedactedOutput(password)
            snapshots = []
            for offset in range(0, len(raw), size):
                capture.consume(raw[offset:offset + size])
                snapshots.append(capture.contents)
            capture.consume(b'', final=True)
            self.assertEqual(capture.contents, b'progress [REDACTED] failed [REDACTED]\n')
            self.assertTrue(all(password not in value for value in snapshots))
            self.assertEqual(capture.password, b'')
            self.assertEqual(capture.pending, b'')

    def test_cli_output_log_is_bounded_and_only_redacted_bytes_reach_storage(self):
        stream = io.BytesIO(b'private-password\n' + b'line\n' * 20000)
        snapshots = []
        with patch.object(guest, 'write_bytes', side_effect=lambda path, value: snapshots.append(value)):
            output = guest.UpdateOutput(stream, b'private-password', Path('/private/fake/softwareupdate.log'))
            result = output.finish()
        self.assertTrue(result['outputComplete'])
        self.assertTrue(result['outputTruncated'])
        self.assertFalse(result['outputUnavailable'])
        self.assertTrue(all(len(value) <= guest.MAX_UPDATE_OUTPUT for value in snapshots))
        self.assertTrue(all(b'private-password' not in value for value in snapshots))

    def test_cli_output_write_failure_does_not_stop_draining_child_output(self):
        stream = io.BytesIO(b'private-password\n' + b'line\n' * 20000)
        with patch.object(guest, 'write_bytes', side_effect=OSError('fixture unavailable')):
            output = guest.UpdateOutput(stream, b'private-password', Path('/private/fake/softwareupdate.log'))
            result = output.finish()
        self.assertTrue(result['outputComplete'])
        self.assertTrue(result['outputUnavailable'])
        self.assertTrue(stream.closed)

    def test_preflight_blocks_low_system_storage_before_installation(self):
        with patch.object(guest, 'owner', return_value={'volumeOwner': True}), \
                patch.object(guest, 'text', return_value=OFFER_TEXT), \
                patch.object(guest.os, 'statvfs', return_value=SimpleNamespace(f_bavail=13 * 1024 ** 3, f_frsize=1)):
            result = guest.prerequisite(REQUEST, {'actual': BEFORE, 'bootIdentity': BOOT})
        self.assertEqual(result['status'], 'blocked')
        self.assertEqual(result['reason'], 'insufficient_guest_system_storage')
        self.assertGreaterEqual(result['minimumSystemFreeBytes'], 20 * 1024 ** 3)
        self.assertTrue(result['safeToStop'])

    def test_cache_measurement_stays_within_explicit_guest_paths_and_deadline(self):
        with patch.object(guest.pwd, 'getpwnam', return_value=SimpleNamespace(pw_dir='/Users/wallet-test')), \
                patch.object(Path, 'resolve', lambda path: path), patch.object(Path, 'is_dir', return_value=True), \
                patch.object(Path, 'is_symlink', return_value=False), \
                patch.object(guest, 'text', return_value='1024\t/Users/wallet-test/.npm\n9999\t/unrequested\n') as query:
            result = guest.cache_sizes('wallet-test')
        query.assert_called_once_with(['/usr/bin/du', '-sk', '-x', '/Users/wallet-test/.npm',
            '/Users/wallet-test/Library/Caches', '/private/var/folders', '/private/var/vm',
            '/Library/Developer/CoreSimulator', '/Applications'], timeout=8, limit=16384, accepted=(0, 1))
        self.assertEqual(result, [{'path': '/Users/wallet-test/.npm', 'bytes': 1024 ** 2}])

    def test_disk_geometry_excludes_unrequested_plist_fields(self):
        result = guest.compact_disk_layout({'DeviceIdentifier': 'disk0', 'Size': 64 * 1024 ** 3,
            'Unexpected': 'secret', 'Partitions': [{'DeviceIdentifier': 'disk0s2', 'Content': 'Apple_APFS',
            'Size': 60 * 1024 ** 3, 'Unexpected': 'secret'}]})
        self.assertEqual(result['Partitions'][0]['DeviceIdentifier'], 'disk0s2')
        self.assertNotIn('secret', json.dumps(result))

    def test_zero_exit_with_complete_terminal_error_is_not_restart_pending(self):
        evidence = {'outputComplete': True, 'outputTruncated': False, 'outputUnavailable': False}
        for text, reason in ((b'Not enough free disk space: 17 GB required.\n', 'softwareupdate_insufficient_disk_space'),
                             (b'macOS: No such update\nNo updates are available.\n', 'softwareupdate_no_matching_update'),
                             (b'Failed to authenticate.\n', 'softwareupdate_authentication_failed')):
            with self.subTest(text=text):
                result = guest.update_outcome(0, text, evidence)
                self.assertEqual(result['phase'], 'failed')
                self.assertEqual(result['reason'], reason)
                self.assertTrue(result['safeToStop'])
                self.assertEqual(result['failureEvidence'], 'complete_cli_terminal_output')

    def test_warning_followed_by_progress_or_incomplete_capture_cannot_authorize_stop(self):
        complete = {'outputComplete': True, 'outputTruncated': False, 'outputUnavailable': False}
        for text, evidence in ((b'Disk space is not sufficient\nPreparing macOS 27.2\nRestarting\n', complete),
                               (b'Not enough free disk space\n', {**complete, 'outputComplete': False}),
                               (b'Not enough free disk space\n', {**complete, 'outputTruncated': True}),
                               (b'No updates are available\n', {**complete, 'outputUnavailable': True})):
            with self.subTest(text=text, evidence=evidence):
                result = guest.update_outcome(0, text, evidence)
                self.assertEqual(result['phase'], 'restart-pending')
                self.assertFalse(result['safeToStop'])

    def storage_receipt(self):
        return receipt(phase='restart-pending', installerPID=803, exitCode=0,
                       createdAt='2026-11-03T10:39:35+00:00', updatedAt='2026-11-03T10:39:43+00:00')

    def storage_log(self):
        return (b"2026-11-03 02:39:40-08 guest softwareupdate[803]: Disk space isn't sufficient (required =17053799565, free=13519732736). Invoking CacheDelete\n"
                b'2026-11-03 02:43:06-08 guest softwareupdated[291]: SUOSULoginCredentialPolicyManager: No update downloaded and prepared.\n')

    def test_storage_abandonment_requires_positive_exact_attempt_and_later_idle_evidence(self):
        with patch.object(guest, 'protected_bytes', return_value=self.storage_log()):
            proof = guest.storage_rejection_evidence(self.storage_receipt())
        self.assertEqual(proof['requiredBytes'], 17053799565)
        self.assertEqual(proof['installerPID'], 803)
        self.assertEqual(proof['notPreparedAt'], '2026-11-03T02:43:06-08:00')
        for contents in (self.storage_log().replace(b'[803]', b'[804]'), self.storage_log().splitlines(keepends=True)[0],
                         self.storage_log().replace(b'02:43:06', b'02:39:36'),
                         self.storage_log().replace(b'02:39:40', b'01:39:40')):
            with self.subTest(contents=contents), patch.object(guest, 'protected_bytes', return_value=contents):
                with self.assertRaisesRegex(guest.UpdateError, 'positive_storage'):
                    guest.storage_rejection_evidence(self.storage_receipt())

    def test_abandonment_cannot_treat_unknown_pid_start_as_stopped(self):
        with patch.object(guest.os, 'kill', side_effect=ProcessLookupError):
            self.assertFalse(guest.original_process_alive(803, 'old-start'))
        with patch.object(guest.os, 'kill'), patch.object(guest, 'process_start', return_value=None):
            with self.assertRaisesRegex(guest.UpdateError, 'start_unavailable'):
                guest.original_process_alive(803, 'old-start')
            self.assertTrue(guest.original_process_alive(803))
        with patch.object(guest.os, 'kill'), patch.object(guest, 'process_start', return_value='different-start'):
            self.assertFalse(guest.original_process_alive(803, 'old-start'))

    def test_abandonment_conditions_reject_boot_process_and_storage_changes(self):
        evidence = {'actual': BEFORE, 'bootIdentity': BOOT}
        with patch.object(guest, 'original_process_alive', return_value=False), \
                patch.object(guest, 'text', return_value='291 /usr/sbin/softwareupdated'), \
                patch.object(guest, 'storage_rejection_evidence', return_value={'requiredBytes': 17 * 1024 ** 3}), \
                patch.object(guest.os, 'statvfs', return_value=SimpleNamespace(f_bavail=13 * 1024 ** 3, f_frsize=1)):
            proof = guest.abandonment_conditions(REQUEST, self.storage_receipt(), evidence)
            self.assertTrue(proof['noInstallerProcesses'])
            with self.assertRaisesRegex(guest.UpdateError, 'cannot_be_abandoned'):
                guest.abandonment_conditions(REQUEST, self.storage_receipt(), {**evidence, 'bootIdentity': NEXT_BOOT})
            with patch.object(guest, 'original_process_alive', return_value=True):
                with self.assertRaisesRegex(guest.UpdateError, 'process_still_active'):
                    guest.abandonment_conditions(REQUEST, self.storage_receipt(), evidence)
            with patch.object(guest, 'text', return_value='999 /usr/libexec/osinstallersetupd'):
                with self.assertRaisesRegex(guest.UpdateError, 'another_guest_os_installer'):
                    guest.abandonment_conditions(REQUEST, self.storage_receipt(), evidence)
            with patch.object(guest.os, 'statvfs', return_value=SimpleNamespace(f_bavail=21 * 1024 ** 3, f_frsize=1)):
                with self.assertRaisesRegex(guest.UpdateError, 'no_longer_proves'):
                    guest.abandonment_conditions(REQUEST, self.storage_receipt(), evidence)

    def test_abandon_writes_separate_intent_without_rewriting_original_receipt(self):
        original = self.storage_receipt()
        before = dict(original)
        with patch.object(guest, 'attest', return_value={'actual': BEFORE, 'bootIdentity': BOOT}), \
                patch.object(guest, 'operation_lock', return_value=contextlib.nullcontext(10)), \
                patch.object(guest, 'matching_receipt', return_value=original), \
                patch.object(guest, 'abandonment_conditions', return_value={'requiredBytes': 17 * 1024 ** 3}), \
                patch.object(guest, 'matching_abandonment', return_value=None), \
                patch.object(guest, 'receipt_digest', return_value='a' * 64), patch.object(guest, 'write_json') as write:
            result = guest.abandon(REQUEST)
        self.assertEqual(original, before)
        self.assertEqual(write.call_args.args[0].name, 'abandonment.json')
        self.assertEqual(result['receipt']['exitCode'], 0)
        self.assertEqual(result['reason'], 'upgrade_abandoned_for_storage')
        self.assertFalse(result['safeToStop'])

    def test_observer_reports_abandonment_without_claiming_safe_hypervisor_stop(self):
        with patch.object(guest, 'attest', return_value={'actual': BEFORE, 'bootIdentity': BOOT}), \
                patch.object(guest, 'matching_receipt', return_value=self.storage_receipt()), \
                patch.object(guest, 'matching_abandonment', return_value={'receiptSHA256': 'a' * 64}), \
                patch.object(guest, 'receipt_result') as original_result:
            result = guest.inspect(REQUEST, 'observe')
        self.assertEqual(result['reason'], 'upgrade_abandoned_for_storage')
        self.assertFalse(result['safeToStop'])
        original_result.assert_not_called()

    def test_abandoned_halt_schedules_detached_guest_worker_and_keeps_receipt(self):
        with patch.object(guest, 'attest', return_value={'actual': BEFORE, 'bootIdentity': BOOT}), \
                patch.object(guest, 'operation_lock', return_value=contextlib.nullcontext(10)), \
                patch.object(guest, 'matching_receipt', return_value=self.storage_receipt()), \
                patch.object(guest, 'matching_abandonment', return_value={'receiptSHA256': 'a' * 64}), \
                patch.object(guest, 'abandonment_conditions'), patch.object(guest, 'read_json', return_value={
                    'phase': 'scheduled', 'vmId': REQUEST['vmId'], 'upgradeID': REQUEST['upgradeID'], 'preBootIdentity': BOOT}), \
                patch.object(guest, 'write_json') as write, patch.object(guest, 'write_bytes'), \
                patch.object(guest.subprocess, 'Popen') as launch:
            result = guest.halt_abandoned(REQUEST, b'source')
        self.assertTrue(result['shutdownRequested'])
        self.assertFalse(result['safeToStop'])
        self.assertIn('--halt-worker', launch.call_args.args[0])
        self.assertTrue(launch.call_args.kwargs['start_new_session'])
        self.assertEqual(launch.call_args.kwargs['pass_fds'], (10,))
        self.assertTrue(all(call.args[0].name != 'receipt.json' for call in write.call_args_list))

    def test_halt_worker_revalidates_after_delay_and_only_requests_guest_graceful_shutdown(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            lock = directory / 'operation.lock'
            lock.write_bytes(b'')
            with patch.object(guest, 'UPGRADE_DIRECTORY', directory), patch.object(guest, 'protected'), \
                    patch.object(guest.os, 'fstat', return_value=lock.stat()), patch.object(guest.time, 'sleep') as sleep, \
                    patch.object(guest, 'attest', return_value={'actual': BEFORE, 'bootIdentity': BOOT}), \
                    patch.object(guest, 'matching_receipt', return_value=self.storage_receipt()), \
                    patch.object(guest, 'matching_abandonment', return_value={'receiptSHA256': 'a' * 64}), \
                    patch.object(guest, 'read_json', return_value={'phase': 'scheduled', 'upgradeID': REQUEST['upgradeID'],
                        'vmId': REQUEST['vmId'], 'preBootIdentity': BOOT}), patch.object(guest, 'write_json') as save, \
                    patch.object(guest, 'abandonment_conditions') as conditions, patch.object(guest, 'run') as command:
                guest.halt_worker(REQUEST, 10)
        self.assertEqual(save.call_args.args[1]['phase'], 'issued')
        sleep.assert_called_once_with(2)
        conditions.assert_called_once()
        command.assert_called_once_with(['/sbin/shutdown', '-h', 'now'], timeout=10, limit=4096)

    def test_unified_log_uses_read_only_filtered_query_and_bounded_memory_output(self):
        child = Mock(stdout=Mock())
        child.poll.return_value = 0
        child.wait.return_value = 0
        data = ('softwareupdated download progress ' + 'x' * 500 + '\n') * 60
        with patch.object(guest.subprocess, 'Popen', return_value=child) as launch, \
                patch.object(guest.select, 'select', return_value=([child.stdout], [], [])), \
                patch.object(guest.os, 'read', side_effect=[data.encode(), b'']):
            result = guest.unified_update_log()
        self.assertLessEqual(len(result), 24)
        self.assertLessEqual(len(json.dumps(result).encode()), 8192)
        arguments = launch.call_args.args[0]
        self.assertEqual(arguments[:8], ['/usr/bin/log', 'show', '--last', '5m', '--style', 'compact', '--info', '--predicate'])
        self.assertIn('updatebrain', arguments[8])
        self.assertIn('download', arguments[8])
        child.kill.assert_not_called()

    def test_unified_log_overflow_discards_output_and_stops_only_owned_reader(self):
        child = Mock(stdout=Mock())
        child.poll.return_value = None
        with patch.object(guest.subprocess, 'Popen', return_value=child), \
                patch.object(guest.select, 'select', return_value=([child.stdout], [], [])), \
                patch.object(guest.os, 'read', return_value=b'x' * (1024 * 1024 + 1)):
            with self.assertRaisesRegex(guest.UpdateError, 'output_limit'):
                guest.unified_update_log()
        child.kill.assert_called_once()
        child.stdout.close.assert_called_once()

    def test_guest_error_envelope_preserves_only_sanitized_reason_enums(self):
        self.assertEqual(guest.error_envelope(guest.UpdateError('guest_upgrade_identity_mismatch')),
                         {'status': 'failed', 'reason': 'guest_upgrade_identity_mismatch'})
        self.assertEqual(guest.error_envelope(guest.LiveOSProbeError('guest_update_probe_failed')),
                         {'status': 'failed', 'reason': 'guest_update_probe_failed', 'scope': 'live-os-probe'})
        for error in (OSError('/private/private-password'), ValueError('private-password'),
                      guest.UpdateError('unexpected private-password output')):
            with self.subTest(error=type(error)):
                self.assertEqual(guest.error_envelope(error), {'status': 'failed', 'reason': 'guest_update_request_rejected'})

    def test_only_os_version_probe_after_guest_identity_attestation_gets_retry_scope(self):
        identity = {'version': 1, **REQUEST}
        with patch.object(guest.os, 'geteuid', return_value=0), patch.object(guest, 'protected'), \
                patch.object(guest, 'read_json', return_value=identity), \
                patch.object(guest.pwd, 'getpwnam', return_value=SimpleNamespace(pw_uid=501)):
            with patch.object(guest, 'text', side_effect=['VirtualMac2,1', 'arm64', guest.UpdateError('guest_update_probe_failed')]):
                with self.assertRaises(guest.LiveOSProbeError) as raised:
                    guest.attest(REQUEST)
                self.assertEqual(guest.error_envelope(raised.exception)['scope'], 'live-os-probe')
            with patch.object(guest, 'text', side_effect=guest.UpdateError('guest_update_probe_failed')):
                with self.assertRaises(guest.UpdateError) as raised:
                    guest.attest(REQUEST)
                self.assertNotIsInstance(raised.exception, guest.LiveOSProbeError)
                self.assertNotIn('scope', guest.error_envelope(raised.exception))
            with patch.object(guest, 'text', side_effect=['VirtualMac2,1', 'arm64']), \
                    patch.object(guest, 'read_json', return_value={**identity, 'vmId': 'another-vm'}):
                with self.assertRaises(guest.UpdateError) as raised:
                    guest.attest(REQUEST)
                self.assertEqual(guest.error_envelope(raised.exception)['reason'], 'guest_upgrade_identity_mismatch')
                self.assertNotIn('scope', guest.error_envelope(raised.exception))


if __name__ == '__main__':
    unittest.main()
