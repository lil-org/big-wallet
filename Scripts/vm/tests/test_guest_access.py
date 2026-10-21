import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tarfile
import tempfile
import threading
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, call, patch


spec = importlib.util.spec_from_file_location('guest_access', Path(__file__).resolve().parents[1] / 'guest_access.py')
access = importlib.util.module_from_spec(spec)
spec.loader.exec_module(access)
MAC = '02:00:00:00:00:01'
KEY_TYPE = b'ssh-ed25519'
KEY = 'ssh-ed25519 ' + base64.b64encode(len(KEY_TYPE).to_bytes(4, 'big') + KEY_TYPE + (32).to_bytes(4, 'big') + bytes(range(32))).decode()


def lease(mac=MAC, address='192.168.64.3', expiry='0x7d0'):
    return '{\n hw_address=1,' + mac + '\n ip_address=' + address + '\n lease=' + expiry + '\n}\n'


class GuestAccessTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.check_image = access._check_unencrypted_image
        preflight = patch.object(access, '_check_unencrypted_image')
        self.preflight = preflight.start()
        self.addCleanup(preflight.stop)
        self.work = self.root / 'private work'
        self.work.mkdir(mode=0o700)
        self.candidate = self.root / 'candidate.vbvm'
        (self.candidate / '.vbdata').mkdir(parents=True)
        (self.candidate / '.vbdata/Config.plist').write_bytes(plistlib.dumps({
            'systemType': 'mac', 'hardware': {'networkDevices': [{'macAddress': MAC}]}}))
        (self.candidate / 'Disk.img').write_bytes(b'fixture')
        self.mount = self.root / 'Data'
        self.mount.mkdir()
        self.password = self.work / 'guest-password'
        self.password.write_bytes(b'fixture-secret-with-spaces\n')
        self.password.chmod(0o600)
        self.known = self.work / 'known hosts'
        self.known.write_text('big-wallet-vm-fixture ' + KEY + '\n')
        self.known.chmod(0o600)
        self.payload = self.root / 'provision'
        self.payload.mkdir(mode=0o700)
        (self.payload / 'config.json').write_text(json.dumps({'vmId': 'fixture', 'consoleUser': 'guest',
            'runtimes': [{'dmgPath': 'runtime-0.dmg'}, {'dmgPath': 'runtime-1.dmg'}]}))
        (self.payload / 'provision_guest.sh').write_text('#!/bin/sh\nexit 0\n')
        (self.payload / 'autologin-passwordFile').write_bytes(b'fixture-secret-with-spaces')
        (self.payload / 'Xcode.tar').write_bytes(b'xcode archive fixture')
        (self.payload / 'runtime-0.dmg').write_bytes(b'first runtime fixture')
        (self.payload / 'runtime-1.dmg').write_bytes(b'second runtime fixture')

    def test_candidate_mac_requires_exact_fixed_network_and_real_paths(self):
        self.assertEqual(access.candidate_mac(self.candidate), MAC)
        link = self.root / 'alias.vbvm'
        link.symlink_to(self.candidate)
        with self.assertRaisesRegex(access.GuestAccessError, 'owned candidate'):
            access.candidate_mac(link)
        (self.candidate / '.vbdata/Config.plist').write_bytes(plistlib.dumps({'systemType': 'mac', 'hardware': {'networkDevices': []}}))
        with self.assertRaisesRegex(access.GuestAccessError, 'one configured'):
            access.candidate_mac(self.candidate)

    def test_lease_selection_normalizes_mac_and_discards_expired_addresses(self):
        text = lease(address='192.168.64.2', expiry='0x1') + lease(mac='2:0:0:0:0:1')
        self.assertEqual(access.parse_dhcp_leases(text, MAC, now=1000), '192.168.64.3')
        self.assertIsNone(access.parse_dhcp_leases(text, MAC, now=3000))
        self.assertIsNone(access.find_guest_address(MAC, self.root / 'absent'))

    def test_lease_selection_rejects_multiple_addresses_or_reassigned_ip(self):
        for text in (lease() + lease(address='192.168.64.4'), lease() + lease(mac='02:00:00:00:00:02')):
            with self.subTest(text=text), self.assertRaisesRegex(access.GuestAccessError, 'ambiguous'):
                access.parse_dhcp_leases(text, MAC, now=1000)

    def test_matching_malformed_or_non_guest_lease_is_rejected(self):
        for text in (lease(expiry='invalid'), lease(address='127.0.0.1'), lease(address='1.1.1.1')):
            with self.subTest(text=text), self.assertRaises(access.GuestAccessError):
                access.parse_dhcp_leases(text, MAC, now=1000)

    def attachment(self):
        return {'system-entities': [
            {'dev-entry': '/dev/disk9', 'content-hint': 'Apple_APFS'},
            {'dev-entry': '/dev/disk8', 'content-hint': 'GUID_partition_scheme'},
            {'dev-entry': '/dev/disk8s2', 'content-hint': 'Apple_APFS'}]}

    def detach_arguments(self, device='/dev/disk8'):
        disk = self.candidate / 'Disk.img'
        metadata = disk.stat()
        return disk, device, (metadata.st_dev, metadata.st_ino, metadata.st_uid)

    def attached_image(self):
        return {**self.attachment(), 'image-path': str(self.candidate / 'Disk.img')}

    def inventory(self):
        return {'Containers': [
            {'PhysicalStores': [{'DeviceIdentifier': 'disk0s2'}], 'Volumes': [{'DeviceIdentifier': 'disk1s5', 'Roles': ['Data']}]},
            {'PhysicalStores': [{'DeviceIdentifier': 'disk8s2'}], 'Volumes': [{'DeviceIdentifier': 'disk9s5', 'Roles': ['Data']}]}]}

    def test_data_selection_never_uses_an_unrelated_host_container(self):
        self.assertEqual(access.select_data_volume(self.attachment(), self.inventory()), 'disk9s5')
        inventory = self.inventory()
        inventory['Containers'][1]['Volumes'].append({'DeviceIdentifier': 'disk9s6', 'Roles': ['Data']})
        with self.assertRaisesRegex(access.GuestAccessError, 'exactly one'):
            access.select_data_volume(self.attachment(), inventory)

    def test_multiple_attached_isc_recovery_and_main_containers_select_only_data(self):
        attachment = self.attachment()
        attachment['system-entities'] += [{'dev-entry': '/dev/disk8s1'}, {'dev-entry': '/dev/disk8s3'}]
        inventory = self.inventory()
        inventory['Containers'] += [
            {'PhysicalStores': [{'DeviceIdentifier': 'disk8s1'}], 'Volumes': [{'DeviceIdentifier': 'disk10s1', 'Roles': ['iSCPreboot']}]},
            {'PhysicalStores': [{'DeviceIdentifier': 'disk8s3'}], 'Volumes': [{'DeviceIdentifier': 'disk11s1', 'Roles': ['Recovery']}]}]
        self.assertEqual(access.select_data_volume(attachment, inventory), 'disk9s5')

    def test_inconclusive_or_busy_disk_probe_stops_before_preflight_and_attachment(self):
        command = ['/usr/sbin/lsof', '-t', '+w', str(self.candidate / 'Disk.img')]
        outcomes = [
            ('warning-success', subprocess.CompletedProcess(command, 0, b'', b'Incomplete scan'), False),
            ('warning-no-match', subprocess.CompletedProcess(command, 1, b'', b'Incomplete scan'), False),
            ('failed', subprocess.CompletedProcess(command, 2, b'', b''), False),
            ('terminated', subprocess.CompletedProcess(command, -9, b'', b''), False),
            ('busy', subprocess.CompletedProcess(command, 0, b'123\n', b''), True),
            ('busy-no-match', subprocess.CompletedProcess(command, 1, b'123\n', b''), True),
            ('timeout', subprocess.TimeoutExpired(command, 30), False),
            ('launch-error', OSError('Could not launch lsof'), False),
        ]
        for label, outcome, busy in outcomes:
            options = {'side_effect': outcome} if isinstance(outcome, Exception) else {'return_value': outcome}
            message = 'The candidate disk must be idle before guest access' if busy else 'Could not establish exclusive access to the candidate disk'
            with self.subTest(outcome=label), patch.object(access.subprocess, 'run', **options) as probe, \
                    patch.object(access, '_plist') as disk_services, patch.object(access, '_checked') as cleanup:
                with self.assertRaisesRegex(access.GuestAccessError, message):
                    with access.attached_data(self.candidate, owners=True):
                        self.fail('An inconclusive or busy disk must not be attached')
                probe.assert_called_once_with(command, capture_output=True, timeout=30)
                self.preflight.assert_not_called()
                disk_services.assert_not_called()
                cleanup.assert_not_called()

    def test_clean_idle_probe_preserves_attachment_and_detach_flow(self):
        disk = self.candidate / 'Disk.img'
        command = ['/usr/sbin/lsof', '-t', '+w', str(disk)]
        for returncode in (0, 1):
            responses = [{'images': []}, self.attachment(), self.inventory(),
                         {'DeviceIdentifier': 'disk9s5', 'MountPoint': str(self.mount)}]
            with self.subTest(returncode=returncode), patch.object(access, '_plist', side_effect=responses) as disk_services, \
                    patch.object(access.subprocess, 'run', return_value=subprocess.CompletedProcess(command, returncode, b'', b'')) as probe, \
                    patch.object(access, '_detach_owned_image') as cleanup:
                with access.attached_data(self.candidate, owners=False) as mount:
                    self.assertEqual(mount, self.mount)
                probe.assert_called_once_with(command, capture_output=True, timeout=30)
                self.preflight.assert_called_once_with(disk)
                self.assertEqual(disk_services.call_count, 4)
                self.assertIn('-readwrite', disk_services.call_args_list[1].args[0])
                cleanup.assert_called_once_with(*self.detach_arguments())
            self.preflight.reset_mock()

    def test_owned_attachment_always_detaches_after_read_failure(self):
        responses = [{'images': []}, self.attachment(), self.inventory(), {'DeviceIdentifier': 'disk9s5', 'MountPoint': str(self.mount)}]
        with patch.object(access, '_plist', side_effect=responses) as commands, \
                patch.object(access.subprocess, 'run', return_value=SimpleNamespace(returncode=1, stdout=b'', stderr=b'')), \
                patch.object(access, '_detach_owned_image') as cleanup:
            with self.assertRaisesRegex(RuntimeError, 'fixture failure'):
                with access.attached_data(self.candidate, owners=True) as mount:
                    self.assertEqual(mount, self.mount)
                    raise RuntimeError('fixture failure')
        cleanup.assert_called_once_with(*self.detach_arguments())
        command = commands.call_args_list[1].args[0]
        self.assertEqual(command[-1], str(self.candidate / 'Disk.img'))
        self.assertIn('-nobrowse', command)
        self.assertEqual(command[command.index('-imagekey') + 1], 'diskimage-class=CRawDiskImage')
        self.assertEqual(command[command.index('-owners') + 1], 'on')
        self.preflight.assert_called_once_with(self.candidate / 'Disk.img')

    def test_encrypted_or_unsupported_image_never_reaches_host_disk_services(self):
        for failure in ('Encrypted APFS volume', 'Unsupported APFS metadata'):
            with self.subTest(failure=failure):
                self.preflight.side_effect = access.GuestAccessError(failure)
                with patch.object(access.subprocess, 'run', return_value=SimpleNamespace(returncode=1, stdout=b'', stderr=b'')), \
                        patch.object(access, '_plist') as inventory, patch.object(access, '_checked') as command:
                    with self.assertRaisesRegex(access.GuestAccessError, failure):
                        with access.attached_data(self.candidate, owners=True):
                            self.fail('Unsupported image must not be attached')
                inventory.assert_not_called()
                command.assert_not_called()

    def test_real_image_preflight_refuses_unknown_bytes_without_external_commands(self):
        with patch.object(access.subprocess, 'run', side_effect=AssertionError('No external command')):
            with self.assertRaises(access.GuestAccessError):
                self.check_image(self.candidate / 'Disk.img')

    def test_ambiguous_data_inventory_detaches_without_mount_access(self):
        with patch.object(access, '_plist', side_effect=[{'images': []}, self.attachment(), {'Containers': []}]), \
                patch.object(access.subprocess, 'run', return_value=SimpleNamespace(returncode=1, stdout=b'', stderr=b'')), \
                patch.object(access, '_detach_owned_image') as cleanup:
            with self.assertRaises(access.GuestAccessError):
                with access.attached_data(self.candidate, owners=False):
                    self.fail('unexpected mount')
        cleanup.assert_called_once_with(*self.detach_arguments())

    def test_busy_or_already_attached_candidate_is_never_attached_again(self):
        for busy in (True, False):
            with self.subTest(busy=busy), \
                    patch.object(access.subprocess, 'run', return_value=SimpleNamespace(returncode=0 if busy else 1, stdout=b'123' if busy else b'', stderr=b'')), \
                    patch.object(access, '_plist', return_value={'images': [{'image-path': str(self.candidate / 'Disk.img')}]}) as commands:
                with self.assertRaises(access.GuestAccessError):
                    with access.attached_data(self.candidate, owners=True):
                        self.fail('unexpected mount')
                self.assertLessEqual(commands.call_count, 1)

    def test_partial_attach_failure_recovers_only_the_exact_candidate_for_detach(self):
        image = {**self.attachment(), 'image-path': str(self.candidate / 'Disk.img')}
        unrelated = {'image-path': '/unrelated/Disk.img', 'system-entities': [{'dev-entry': '/dev/disk99'}]}
        responses = [{'images': []}, access.GuestAccessError('attach failed'), {'images': [unrelated, image]}]
        with patch.object(access, '_plist', side_effect=responses), \
                patch.object(access.subprocess, 'run', return_value=SimpleNamespace(returncode=1, stdout=b'', stderr=b'')), \
                patch.object(access, '_detach_owned_image') as cleanup:
            with self.assertRaisesRegex(access.GuestAccessError, 'attach failed'):
                with access.attached_data(self.candidate, owners=True):
                    self.fail('unexpected mount')
        cleanup.assert_called_once_with(*self.detach_arguments(None))

    def test_detach_requires_one_gpt_physical_device_and_never_guesses_synthetic_root(self):
        attachment = self.attachment()
        self.assertEqual(access._attachment_root(attachment), '/dev/disk8')
        attachment['system-entities'] = [attachment['system-entities'][0]]
        self.assertIsNone(access._attachment_root(attachment))
        attachment = self.attachment()
        attachment['system-entities'].append({'dev-entry': '/dev/disk99', 'content-hint': 'GUID_partition_scheme'})
        self.assertIsNone(access._attachment_root(attachment))

    def test_cancellation_during_attach_waits_for_completion_then_recovers_and_detaches(self):
        state = {'attached': False, 'attach_completed': False}
        commands = []
        image = {**self.attachment(), 'image-path': str(self.candidate / 'Disk.img')}
        previous = access.signal.getsignal(access.signal.SIGINT)

        def run(command, **kwargs):
            commands.append(command)
            if command[0] == '/usr/sbin/lsof':
                return subprocess.CompletedProcess(command, 1, stdout=b'', stderr=b'')
            self.assertGreater(kwargs['timeout'], 0)
            self.assertLessEqual(kwargs['timeout'], 60)
            operation = command[1]
            if operation == 'info':
                output = {'images': [image] if state['attached'] else []}
            elif operation == 'attach':
                access.signal.getsignal(access.signal.SIGINT)(access.signal.SIGINT, None)
                state.update(attached=True, attach_completed=True)
                output = self.attachment()
            elif operation == 'detach':
                self.assertTrue(state['attach_completed'])
                self.assertEqual(command[-1], '/dev/disk8')
                state['attached'] = False
                return subprocess.CompletedProcess(command, 0, stdout=b'', stderr=b'')
            else:
                self.fail('Unexpected disk command')
            return subprocess.CompletedProcess(command, 0, stdout=plistlib.dumps(output), stderr=b'')

        with patch.object(access.subprocess, 'run', side_effect=run):
            with self.assertRaises(KeyboardInterrupt):
                with access.attached_data(self.candidate, owners=False):
                    self.fail('Cancellation must propagate before mount access')
        self.assertEqual([command[1] for command in commands[1:]], ['info', 'attach', 'info', 'detach', 'info'])
        self.assertFalse(state['attached'])
        self.assertIs(access.signal.getsignal(access.signal.SIGINT), previous)

    def test_cleanup_detach_retries_only_the_verified_image_and_device(self):
        state = {'attached': True, 'attempts': 0, 'now': 100}
        calls = []
        unrelated = {'image-path': '/unrelated/Disk.img', 'system-entities': [
            {'dev-entry': '/dev/disk77', 'content-hint': 'GUID_partition_scheme'}]}
        def inventory(command, *, timeout):
            self.assertEqual(command, ['/usr/bin/hdiutil', 'info', '-plist'])
            self.assertLessEqual(timeout, 10)
            calls.append('info')
            return {'images': [unrelated, self.attached_image()] if state['attached'] else [unrelated]}
        def detach(command, *, timeout):
            self.assertEqual(command, ['/usr/bin/hdiutil', 'detach', '/dev/disk8'])
            self.assertLessEqual(timeout, 10)
            calls.append('detach')
            state['attempts'] += 1
            if state['attempts'] == 1:
                raise access.GuestAccessError('busy')
            state['attached'] = False
            return b''
        def sleep(seconds):
            calls.append(('sleep', seconds))
            state['now'] += seconds
        with patch.object(access, '_plist', side_effect=inventory), patch.object(access, '_checked', side_effect=detach), \
                patch.object(access.time, 'monotonic', side_effect=lambda: state['now']), \
                patch.object(access.time, 'sleep', side_effect=sleep):
            access._detach_owned_image(*self.detach_arguments(None))
        self.assertEqual(calls, ['info', 'detach', 'info', ('sleep', 5), 'info', 'detach', 'info'])
        self.assertFalse(state['attached'])

    def test_cleanup_detach_refuses_changed_ambiguous_or_unknown_mapping_before_retry(self):
        image = self.attached_image()
        changed_device = {**image, 'system-entities': [{'dev-entry': '/dev/disk77', 'content-hint': 'GUID_partition_scheme'}]}
        wrong_path = {**image, 'image-path': '/unrelated/Disk.img'}
        no_guid = {**image, 'system-entities': [{'dev-entry': '/dev/disk8', 'content-hint': 'Apple_APFS'}]}
        ambiguous_root = {**image, 'system-entities': [*image['system-entities'],
            {'dev-entry': '/dev/disk77', 'content-hint': 'GUID_partition_scheme'}]}
        outcomes = [{}, {'images': {}}, {'images': [None]}, {'images': [{'image-path': str(self.candidate / 'Disk.img')}]},
                    {'images': [{**image, 'image-path': ''}]}, {'images': [{**image, 'image-path': 'Disk.img'}]},
                    {'images': [{**image, 'image-path': '/unknown/../Disk.img'}]},
                    {'images': [{**image, 'system-entities': [{'dev-entry': None}]}]},
                    {'images': [changed_device]}, {'images': [wrong_path]}, {'images': [no_guid]},
                    {'images': [image, image]}, {'images': [image, wrong_path]},
                    {'images': [image, {**wrong_path, 'image-path': 'ram://32768'}]}, {'images': [ambiguous_root]},
                    access.GuestAccessError('inventory unavailable')]
        for index, outcome in enumerate(outcomes):
            with self.subTest(case=index), \
                    patch.object(access, '_plist', side_effect=[{'images': [image]}, {'images': [image]}, outcome]) as inventory, \
                    patch.object(access, '_checked', side_effect=access.GuestAccessError('busy')) as detach, \
                    patch.object(access.time, 'sleep'):
                with self.assertRaises(access.GuestAccessError):
                    access._detach_owned_image(*self.detach_arguments())
                detach.assert_called_once_with(['/usr/bin/hdiutil', 'detach', '/dev/disk8'], timeout=10)
                self.assertEqual(inventory.call_count, 3)

    def test_cleanup_detach_allows_an_unrelated_opaque_image_path(self):
        unrelated = {'image-path': 'ram://32768', 'system-entities': [
            {'dev-entry': '/dev/disk77', 'content-hint': 'GUID_partition_scheme'}]}
        with patch.object(access, '_plist', side_effect=[
                {'images': [unrelated, self.attached_image()]}, {'images': [unrelated]}]), \
                patch.object(access, '_checked') as detach:
            access._detach_owned_image(*self.detach_arguments())
        detach.assert_called_once_with(['/usr/bin/hdiutil', 'detach', '/dev/disk8'], timeout=10)

    def test_cleanup_detach_refuses_replaced_or_symlinked_image_before_retry(self):
        disk = self.candidate / 'Disk.img'
        for symlink in (False, True):
            arguments = self.detach_arguments()
            saved = disk.with_name('saved.img')
            def replace(_):
                disk.rename(saved)
                if symlink:
                    disk.symlink_to(saved)
                else:
                    disk.write_bytes(b'replaced')
            with self.subTest(symlink=symlink), patch.object(access, '_plist', return_value={'images': [self.attached_image()]}) as inventory, \
                    patch.object(access, '_checked', side_effect=access.GuestAccessError('busy')) as detach, \
                    patch.object(access.time, 'sleep', side_effect=replace):
                with self.assertRaises(access.GuestAccessError):
                    access._detach_owned_image(*arguments)
                self.assertEqual(detach.call_count, 1)
                self.assertEqual(inventory.call_count, 2)
            disk.unlink()
            saved.rename(disk)

    def test_cleanup_detach_refuses_owner_or_device_identity_changes(self):
        disk, device, identity = self.detach_arguments()
        for changed in ((identity[0] + 1, identity[1], identity[2]), (identity[0], identity[1], identity[2] + 1)):
            with self.subTest(identity=changed), patch.object(access, '_plist') as inventory, patch.object(access, '_checked') as detach:
                with self.assertRaisesRegex(access.GuestAccessError, 'changed'):
                    access._detach_owned_image(disk, device, changed)
                inventory.assert_not_called()
                detach.assert_not_called()
        with patch.object(access, '_plist') as inventory, patch.object(access, '_checked') as detach:
            with self.assertRaisesRegex(access.GuestAccessError, 'invalid'):
                access._detach_owned_image(disk, '/dev/disk8s2', identity)
            inventory.assert_not_called()
            detach.assert_not_called()

    def test_cleanup_detach_accepts_confirmed_absence_after_an_error(self):
        for error in (access.GuestAccessError('busy'), access.GuestAccessError('detach could not complete')):
            with self.subTest(error=error), \
                    patch.object(access, '_plist', side_effect=[{'images': [self.attached_image()]}, {'images': []}]) as inventory, \
                    patch.object(access, '_checked', side_effect=error) as detach, patch.object(access.time, 'sleep') as sleep:
                access._detach_owned_image(*self.detach_arguments())
                self.assertEqual(inventory.call_count, 2)
                self.assertEqual(detach.call_count, 1)
                sleep.assert_not_called()

    def test_cleanup_detach_has_three_attempts_and_verifies_successful_exit(self):
        for outcome in (b'', access.GuestAccessError('busy')):
            with self.subTest(outcome=outcome), patch.object(access, '_plist', return_value={'images': [self.attached_image()]}) as inventory, \
                    patch.object(access, '_checked', side_effect=[outcome] * 3) as detach, patch.object(access.time, 'sleep') as sleep:
                with self.assertRaisesRegex(access.GuestAccessError, 'remained attached'):
                    access._detach_owned_image(*self.detach_arguments())
                self.assertEqual(detach.call_args_list, [call(['/usr/bin/hdiutil', 'detach', '/dev/disk8'], timeout=10)] * 3)
                self.assertEqual(inventory.call_count, 6)
                self.assertEqual(sleep.call_args_list, [call(5), call(10)])

    def test_cleanup_detach_inventory_commands_and_backoff_share_one_deadline(self):
        state = {'now': 100}
        timeouts = []
        def consume(command, *, timeout):
            self.assertGreater(timeout, 0)
            self.assertLessEqual(timeout, min(10, 160 - state['now']))
            timeouts.append(timeout)
            state['now'] += timeout
            if command[1] == 'detach':
                raise access.GuestAccessError('busy')
            return {'images': [self.attached_image()]}
        def sleep(seconds):
            state['now'] += seconds
        with patch.object(access, '_plist', side_effect=consume), patch.object(access, '_checked', side_effect=consume) as detach, \
                patch.object(access.time, 'monotonic', side_effect=lambda: state['now']), \
                patch.object(access.time, 'sleep', side_effect=sleep) as waiting:
            with self.assertRaisesRegex(access.GuestAccessError, 'cleanup deadline'):
                access._detach_owned_image(*self.detach_arguments(None))
        self.assertEqual(state['now'], 160)
        self.assertEqual(timeouts, [10, 10, 10, 10, 10, 5])
        self.assertEqual(detach.call_count, 2)
        waiting.assert_called_once_with(5)

    def test_cleanup_detach_defers_cancellation_through_inventory_detach_and_backoff(self):
        previous = access.signal.getsignal(access.signal.SIGINT)
        for trigger in ('inventory', 'detach', 'backoff'):
            state = {'attached': True, 'attempts': 0, 'interrupted': False}
            def interrupt(where):
                if where == trigger and not state['interrupted']:
                    state['interrupted'] = True
                    access.signal.getsignal(access.signal.SIGINT)(access.signal.SIGINT, None)
            def inventory(*args, **kwargs):
                interrupt('inventory')
                return {'images': [self.attached_image()] if state['attached'] else []}
            def detach(*args, **kwargs):
                interrupt('detach')
                state['attempts'] += 1
                if state['attempts'] == 1:
                    raise access.GuestAccessError('busy')
                state['attached'] = False
            with self.subTest(trigger=trigger), patch.object(access, '_plist', side_effect=inventory), \
                    patch.object(access, '_checked', side_effect=detach), \
                    patch.object(access.time, 'sleep', side_effect=lambda _: interrupt('backoff')):
                with self.assertRaises(KeyboardInterrupt):
                    access._detach_owned_image(*self.detach_arguments(None))
            self.assertFalse(state['attached'])
            self.assertEqual(state['attempts'], 2)
            self.assertIs(access.signal.getsignal(access.signal.SIGINT), previous)

    def test_partial_attach_error_remains_after_cleanup_detach_retry_succeeds(self):
        state = {'attached': False, 'detaches': 0}
        commands = []
        def run(command, **kwargs):
            commands.append(command)
            if command[0] == '/usr/sbin/lsof':
                return subprocess.CompletedProcess(command, 1, b'', b'')
            if command[1] == 'info':
                return subprocess.CompletedProcess(command, 0, plistlib.dumps({'images': [self.attached_image()] if state['attached'] else []}), b'')
            if command[1] == 'attach':
                state['attached'] = True
                return subprocess.CompletedProcess(command, 1, b'', b'attach failed')
            self.assertEqual(command, ['/usr/bin/hdiutil', 'detach', '/dev/disk8'])
            state['detaches'] += 1
            state['attached'] = state['detaches'] == 1
            return subprocess.CompletedProcess(command, 1 if state['attached'] else 0, b'', b'')
        with patch.object(access.subprocess, 'run', side_effect=run), patch.object(access.time, 'sleep'):
            with self.assertRaisesRegex(access.GuestAccessError, 'hdiutil failed during guest disk access'):
                with access.attached_data(self.candidate, owners=False):
                    self.fail('A failed attach must not yield access')
        self.assertEqual(sum(command[1] == 'attach' for command in commands), 1)
        self.assertEqual(state['detaches'], 2)
        self.assertFalse(state['attached'])

    def prepare(self, first_boot=False, console_user='guest'):
        with patch.object(access, 'attached_data', side_effect=lambda *args, **kwargs: contextlib.nullcontext(self.mount)):
            return access.prepare_guest_access(self.candidate, self.work, 'fixture', console_user,
                                               first_boot_ssh_requested=first_boot)

    def test_absent_service_file_requires_first_boot_and_is_never_created(self):
        with self.assertRaisesRegex(access.GuestAccessError, 'first-boot'):
            self.prepare()
        result = self.prepare(first_boot=True)
        self.assertIsNone(result['knownHosts'])
        self.assertFalse(result['remoteLoginChanged'])
        self.assertFalse(result['automaticLoginLockCleared'])
        self.assertEqual(list(self.mount.iterdir()), [])

    def test_only_public_keys_are_read_and_pinned_to_vm_alias(self):
        directory = self.mount / 'private/etc/ssh'
        directory.mkdir(parents=True)
        (directory / 'ssh_host_ed25519_key.pub').write_text(KEY + ' guest-comment\n')
        (directory / 'ssh_host_ed25519_key').write_text('PRIVATE KEY MUST NOT BE READ')
        original_read = access._read

        def read(path, **kwargs):
            contents, metadata = original_read(path, **kwargs)
            if Path(path).suffix == '.pub':
                metadata = SimpleNamespace(st_uid=0, st_mode=metadata.st_mode)
            return contents, metadata

        with patch.object(access, '_read', side_effect=read) as reads, \
                patch.object(access, '_protected_root_directory') as directories:
            result = self.prepare(first_boot=True)
        self.assertEqual(result['knownHosts'].read_text(), 'big-wallet-vm-fixture ' + KEY + '\n')
        self.assertEqual(result['knownHosts'].stat().st_mode & 0o777, 0o600)
        self.assertNotIn('ssh_host_ed25519_key', [Path(call.args[0]).name for call in reads.call_args_list])
        self.assertEqual([call.args[0] for call in directories.call_args_list], [directory, directory.parent, directory.parent.parent, self.mount])

    def test_public_key_symlink_is_rejected_before_pinning(self):
        directory = self.mount / 'private/etc/ssh'
        directory.mkdir(parents=True)
        (directory / 'ssh_host_ed25519_key.pub').symlink_to(self.known)
        with patch.object(access, '_protected_root_directory'):
            with self.assertRaisesRegex(access.GuestAccessError, 'symlink'):
                self.prepare(first_boot=True)

    def test_unprotected_public_key_and_directory_are_not_trusted(self):
        directory = self.mount / 'private/etc/ssh'
        directory.mkdir(parents=True)
        key = directory / 'ssh_host_ed25519_key.pub'
        key.write_text(KEY)
        with patch.object(access, '_protected_root_directory'):
            with self.assertRaisesRegex(access.GuestAccessError, 'public keys must be root-owned'):
                self.prepare(first_boot=True)
        for metadata in (SimpleNamespace(st_uid=501, st_mode=access.stat.S_IFDIR | 0o755),
                         SimpleNamespace(st_uid=0, st_mode=access.stat.S_IFDIR | 0o777),
                         SimpleNamespace(st_uid=0, st_mode=access.stat.S_IFLNK | 0o755)):
            with self.subTest(metadata=metadata), patch.object(Path, 'lstat', return_value=metadata):
                with self.assertRaisesRegex(access.GuestAccessError, 'directories must be root-owned'):
                    access._protected_root_directory(directory)

    def test_existing_service_plist_changes_only_sshd_and_preserves_inode_mode(self):
        disabled = self.mount / 'private/var/db/com.apple.xpc.launchd/disabled.plist'
        disabled.parent.mkdir(parents=True)
        disabled.write_bytes(plistlib.dumps({'other.service': True, 'nested': {'value': 7}}, fmt=plistlib.FMT_BINARY))
        disabled.chmod(0o644)
        before = disabled.stat()
        original_read = access._read

        def read(path, **kwargs):
            contents, metadata = original_read(path, **kwargs)
            if Path(path) == disabled:
                metadata = SimpleNamespace(st_uid=0, st_gid=0, st_mode=metadata.st_mode, st_ino=metadata.st_ino)
            return contents, metadata

        with patch.object(access, '_read', side_effect=read), patch.object(access, '_protected_root_directory'):
            result = self.prepare()
        self.assertTrue(result['remoteLoginChanged'])
        self.assertEqual(plistlib.loads(disabled.read_bytes()), {'other.service': True, 'nested': {'value': 7}, 'com.openssh.sshd': False})
        self.assertTrue(disabled.read_bytes().startswith(b'bplist00'))
        self.assertEqual((disabled.stat().st_ino, disabled.stat().st_uid, disabled.stat().st_mode), (before.st_ino, before.st_uid, before.st_mode))

    @contextlib.contextmanager
    def protected_plists(self, *paths, owner=0):
        original_read = access._read

        def read(path, **kwargs):
            contents, metadata = original_read(path, **kwargs)
            if Path(path) in paths:
                metadata = SimpleNamespace(st_uid=owner, st_gid=0, st_mode=metadata.st_mode, st_ino=metadata.st_ino)
            return contents, metadata

        with patch.object(access, '_read', side_effect=read), patch.object(access, '_protected_root_directory') as directories:
            yield directories

    def login_preferences(self, configuration, fmt=plistlib.FMT_BINARY):
        path = self.mount / 'Library/Preferences/com.apple.loginwindow.plist'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(configuration, fmt=fmt))
        path.chmod(0o640)
        return path

    def test_selected_automatic_login_clears_only_remembered_lock_and_preserves_file_identity(self):
        for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
            for locked in (True, 1):
                with self.subTest(fmt=fmt, locked=locked):
                    configuration = {'autoLoginUser': 'guest', 'autoLoginUserScreenLocked': locked,
                                     'other': {'value': 7}, 'autoLoginUserUID': 501}
                    path = self.login_preferences(configuration, fmt)
                    before = path.stat()
                    with self.protected_plists(path) as directories:
                        result = self.prepare(first_boot=True)
                    configuration['autoLoginUserScreenLocked'] = False if type(locked) is bool else 0
                    self.assertEqual(plistlib.loads(path.read_bytes()), configuration)
                    self.assertEqual(type(plistlib.loads(path.read_bytes())['autoLoginUserScreenLocked']), type(locked))
                    self.assertEqual(path.read_bytes().startswith(b'bplist00'), fmt == plistlib.FMT_BINARY)
                    self.assertEqual((path.stat().st_ino, path.stat().st_uid, path.stat().st_mode),
                                     (before.st_ino, before.st_uid, before.st_mode))
                    self.assertTrue(result['automaticLoginLockCleared'])
                    self.assertFalse(result['remoteLoginChanged'])
                    self.assertEqual([call.args[0] for call in directories.call_args_list],
                                     [path.parent, path.parent.parent, self.mount])

    def test_absent_other_account_or_unlocked_login_preferences_remain_byte_identical(self):
        for configuration in ({}, {'autoLoginUser': 'guest'}, {'autoLoginUserScreenLocked': True},
                              {'autoLoginUser': 'other', 'autoLoginUserScreenLocked': True},
                              {'autoLoginUser': 'guest', 'autoLoginUserScreenLocked': False},
                              {'autoLoginUser': 'guest', 'autoLoginUserScreenLocked': 0}):
            with self.subTest(configuration=configuration):
                path = self.login_preferences(configuration)
                original = path.read_bytes()
                with self.protected_plists(path):
                    result = self.prepare(first_boot=True)
                self.assertFalse(result['automaticLoginLockCleared'])
                self.assertEqual(path.read_bytes(), original)

    def test_invalid_login_preferences_block_all_planned_offline_changes(self):
        disabled = self.mount / 'private/var/db/com.apple.xpc.launchd/disabled.plist'
        disabled.parent.mkdir(parents=True)
        disabled.write_bytes(plistlib.dumps({'com.openssh.sshd': True}))
        original_service = disabled.read_bytes()
        invalid = [b'not a plist', [], {'autoLoginUser': 501}]
        invalid += [{'autoLoginUser': 'guest', 'autoLoginUserScreenLocked': value}
                    for value in (-1, 2, 1.0, 'true', [], {})]
        for configuration in invalid:
            with self.subTest(configuration=configuration):
                path = self.login_preferences({} if isinstance(configuration, bytes) else configuration)
                if isinstance(configuration, bytes):
                    path.write_bytes(configuration)
                original_login = path.read_bytes()
                with self.protected_plists(disabled, path), patch.object(access, '_replace_contents') as replace:
                    with self.assertRaisesRegex(access.GuestAccessError, 'invalid'):
                        self.prepare()
                replace.assert_not_called()
                self.assertEqual(disabled.read_bytes(), original_service)
                self.assertEqual(path.read_bytes(), original_login)

    def test_stale_login_preferences_prevent_writing_an_earlier_service_change(self):
        disabled = self.mount / 'private/var/db/com.apple.xpc.launchd/disabled.plist'
        disabled.parent.mkdir(parents=True)
        disabled.write_bytes(plistlib.dumps({'com.openssh.sshd': True}))
        original_service = disabled.read_bytes()
        path = self.login_preferences({'autoLoginUser': 'guest', 'autoLoginUserScreenLocked': True})
        changed = plistlib.dumps({'autoLoginUser': 'other', 'autoLoginUserScreenLocked': True})

        def attach(_candidate, *, owners):
            if not owners:
                path.write_bytes(changed)
            return contextlib.nullcontext(self.mount)

        with self.protected_plists(disabled, path), patch.object(access, 'attached_data', side_effect=attach), \
                patch.object(access, '_replace_contents') as replace:
            with self.assertRaisesRegex(access.GuestAccessError, 'changed during offline access'):
                access.prepare_guest_access(self.candidate, self.work, 'fixture', 'guest')
        replace.assert_not_called()
        self.assertEqual(disabled.read_bytes(), original_service)
        self.assertEqual(path.read_bytes(), changed)

    def test_unsafe_login_preferences_are_rejected_before_any_write(self):
        for unsafe in ('symlink', 'owner', 'mode', 'parent'):
            with self.subTest(unsafe=unsafe):
                path = self.login_preferences({'autoLoginUser': 'guest', 'autoLoginUserScreenLocked': True})
                if unsafe == 'symlink':
                    path.unlink()
                    path.symlink_to(self.known)
                elif unsafe == 'mode':
                    path.chmod(0o666)
                with self.protected_plists(path, owner=501 if unsafe == 'owner' else 0) as directories, \
                        patch.object(access, '_replace_contents') as replace:
                    if unsafe == 'parent':
                        directories.side_effect = access.GuestAccessError('Guest access directories must be root-owned and protected')
                    with self.assertRaisesRegex(access.GuestAccessError, 'symlink|root-owned and protected'):
                        self.prepare(first_boot=True)
                replace.assert_not_called()
                path.unlink()

    def test_invalid_selected_console_user_is_rejected_before_disk_access(self):
        for user in ('', '../guest', None):
            with self.subTest(user=user), patch.object(access, 'attached_data') as attach:
                with self.assertRaisesRegex(access.GuestAccessError, 'selected guest console user'):
                    access.prepare_guest_access(self.candidate, self.work, 'fixture', user)
                attach.assert_not_called()

    def test_rewrite_refuses_stale_original_without_changing_file(self):
        target = self.mount / 'fixture'
        target.write_bytes(b'actual')
        with self.assertRaisesRegex(access.GuestAccessError, 'changed'):
            access._replace_contents(target, b'outdated', b'replacement', target.stat().st_ino)
        self.assertEqual(target.read_bytes(), b'actual')

    def test_interrupted_partial_plist_write_restores_original_and_detaches(self):
        target = self.mount / 'disabled.plist'
        original = plistlib.dumps({'other.service': True})
        replacement = plistlib.dumps({'other.service': True, 'com.openssh.sshd': False})
        target.write_bytes(original)
        inode = target.stat().st_ino
        real_fdopen = os.fdopen

        class InterruptedFile:
            def __init__(self, file):
                self.file = file
                self.interrupted = False

            def __getattr__(self, name):
                return getattr(self.file, name)

            def __enter__(self):
                return self

            def __exit__(self, *args):
                return self.file.__exit__(*args)

            def write(self, contents):
                if not self.interrupted:
                    self.interrupted = True
                    self.file.write(contents[:17])
                    self.file.flush()
                    raise KeyboardInterrupt()
                return self.file.write(contents)

        def fdopen(descriptor, mode, *args, **kwargs):
            file = real_fdopen(descriptor, mode, *args, **kwargs)
            return InterruptedFile(file) if mode == 'r+b' else file

        responses = [{'images': []}, self.attachment(), self.inventory(), {'DeviceIdentifier': 'disk9s5', 'MountPoint': str(self.mount)}]
        with patch.object(access, '_plist', side_effect=responses), \
                patch.object(access.subprocess, 'run', return_value=SimpleNamespace(returncode=1, stdout=b'', stderr=b'')), \
                patch.object(access, '_detach_owned_image') as cleanup, patch.object(access.os, 'fdopen', side_effect=fdopen):
            with self.assertRaises(KeyboardInterrupt):
                with access.attached_data(self.candidate, owners=False):
                    access._replace_contents(target, original, replacement, inode)
        cleanup.assert_called_once_with(*self.detach_arguments())
        self.assertEqual(target.read_bytes(), original)
        self.assertEqual(plistlib.loads(target.read_bytes()), {'other.service': True})
        self.assertEqual(target.stat().st_ino, inode)

    def test_signal_cancellation_is_delivered_only_after_complete_fsync(self):
        target = self.mount / 'disabled.plist'
        original = plistlib.dumps({'other.service': True})
        replacement = plistlib.dumps({'other.service': True, 'com.openssh.sshd': False})
        target.write_bytes(original)
        previous = access.signal.getsignal(access.signal.SIGINT)
        real_fsync = os.fsync

        def interrupt(descriptor):
            access.signal.getsignal(access.signal.SIGINT)(access.signal.SIGINT, None)
            real_fsync(descriptor)

        with patch.object(access.os, 'fsync', side_effect=interrupt):
            with self.assertRaises(KeyboardInterrupt):
                access._replace_contents(target, original, replacement, target.stat().st_ino)
        self.assertEqual(target.read_bytes(), replacement)
        self.assertEqual(plistlib.loads(target.read_bytes())['com.openssh.sshd'], False)
        self.assertIs(access.signal.getsignal(access.signal.SIGINT), previous)

    def test_password_requires_private_regular_file_and_single_line(self):
        self.assertEqual(access.read_private_password(self.password), b'fixture-secret-with-spaces')
        self.password.chmod(0o644)
        with self.assertRaisesRegex(access.GuestAccessError, 'private'):
            access.read_private_password(self.password)
        self.password.chmod(0o600)
        self.password.write_bytes(b'first\nsecond')
        with self.assertRaisesRegex(access.GuestAccessError, 'one nonempty line'):
            access.read_private_password(self.password)

    def test_ssh_disables_host_credentials_and_requires_the_exact_pin(self):
        command = access.ssh_command('192.168.64.3', 'guest', self.known, 'big-wallet-vm-fixture')
        self.assertEqual(command[:4], ['/usr/bin/ssh', '-F', '/dev/null', '-T'])
        for option in ('StrictHostKeyChecking=yes', 'IdentityAgent=none', 'UseKeychain=no', 'PubkeyAuthentication=no',
                       'ClearAllForwardings=yes', 'ProxyCommand=none', 'ProxyJump=none', 'RequestTTY=no'):
            self.assertIn(option, command)
        self.assertIn('UserKnownHostsFile="' + str(self.known) + '"', command)
        with self.assertRaisesRegex(access.GuestAccessError, 'pinned'):
            access.ssh_command('192.168.64.3', 'guest', self.known, 'big-wallet-vm-other')
        for invalid in ('localhost', '127.0.0.1', '-oProxyCommand=bad'):
            with self.assertRaises(access.GuestAccessError):
                access.ssh_command(invalid, 'guest', self.known, 'big-wallet-vm-fixture')

    def test_remote_installer_checks_guest_identity_before_sudo_and_uses_local_payload(self):
        marker = 'BIG_WALLET_PAYLOAD_' + 'a' * 32
        command = access.installer_command('guest', marker)
        self.assertLess(command.index('VirtualMac'), command.index('sudo -S'))
        self.assertIn('/usr/bin/id -un', command)
        self.assertNotIn('mount_virtiofs', command)
        self.assertNotIn('/Volumes/BigWalletBuild/Exchange', command)
        self.assertIn('/private/tmp/big-wallet-provision.', command)
        self.assertIn('--no-same-owner', command)
        self.assertIn('--prepare-storage', command)
        self.assertIn('trap', command)
        with self.assertRaises(access.GuestAccessError):
            access.installer_command('guest; bad', marker)
        stage = '/Volumes/BigWalletBuild/Provisioning/12345678-1234-1234-1234-123456789abc/provision'
        full = access.installer_command('guest', marker, stage, 'fixture')
        self.assertNotIn('--prepare-storage', full)
        self.assertIn('.big-wallet-provisioning.json', full)
        self.assertIn('cleanup_stage', full)
        self.assertNotIn('exec /bin/sh "$destination', full)
        for command in (command, full):
            subprocess.run(['/bin/sh', '-n'], input=command.encode(), check=True, capture_output=True)
            subprocess.run(['/bin/sh', '-n'], input=access.shlex.split(command)[-1].encode(), check=True, capture_output=True)

    def test_payload_framing_keeps_tar_aligned_with_or_without_sudo_consuming_password(self):
        marker = 'BIG_WALLET_PAYLOAD_' + 'c' * 32
        root_script = access.shlex.split(access.installer_command('guest', marker))[-1]
        framing = 'IFS= read -r payload_marker\n' + root_script.split('IFS= read -r payload_marker\n', 1)[1].split('unset payload_marker\n', 1)[0]
        script = 'set -eu\n' + framing + 'unset payload_marker\n/usr/bin/tar -tf -\n'
        contents = io.BytesIO()
        with tarfile.open(fileobj=contents, mode='w') as archive:
            entry = tarfile.TarInfo('fixture.txt')
            entry.size = 7
            archive.addfile(entry, io.BytesIO(b'fixture'))
        for prefix in (b'', b'fixture-password\n'):
            with self.subTest(password_pending=bool(prefix)):
                result = subprocess.run(['/bin/sh', '-c', script],
                                        input=prefix + marker.encode() + b'\n' + contents.getvalue(),
                                        check=True, capture_output=True, timeout=5)
                self.assertEqual(result.stdout, b'fixture.txt\n')

    def fake_child(self):
        class Input:
            def __init__(self):
                self.read_descriptor, self.write_descriptor = os.pipe()
                self.contents = bytearray()
                self.closed = False
                self.reader = threading.Thread(target=self.receive, daemon=True)
                self.reader.start()

            def receive(self):
                try:
                    while data := os.read(self.read_descriptor, 65536):
                        self.contents.extend(data)
                finally:
                    os.close(self.read_descriptor)

            def fileno(self):
                return self.write_descriptor

            @property
            def sent(self):
                return bytes(self.contents)

            def close(self):
                if not self.closed:
                    self.closed = True
                    os.close(self.write_descriptor)
                    self.reader.join(1)

        class Child:
            pid = 424242
            code = None
            stdin = Input()

            def poll(self):
                return self.code

            def wait(self, timeout=None):
                self.code = -15
                return self.code
        child = Child()
        self.addCleanup(child.stdin.close)
        return child

    def test_installer_only_sends_password_through_stdin_and_private_askpass(self):
        child = self.fake_child()
        log = self.root / 'install.log'
        with patch.object(access.subprocess, 'Popen', return_value=child) as launch:
            installer = access.GuestInstaller('192.168.64.3', 'guest', self.password, self.known, 'big-wallet-vm-fixture', self.work,
                                              log_path=log, provision_directory=self.payload)
        installer.producer.join()
        command = launch.call_args.args[0]
        environment = launch.call_args.kwargs['env']
        self.assertTrue(child.stdin.sent.startswith(b'fixture-secret-with-spaces\nBIG_WALLET_PAYLOAD_'))
        with tarfile.open(fileobj=io.BytesIO(child.stdin.sent.split(b'\n', 2)[2])) as archive:
            self.assertEqual(set(archive.getnames()), {'config.json', 'provision_guest.sh', 'autologin-passwordFile'})
            self.assertTrue(all(entry.uid == 0 and entry.gid == 0 for entry in archive.getmembers()))
        for visible in (repr(command), repr(environment), installer.askpass.read_text()):
            self.assertNotIn('fixture-secret-with-spaces', visible)
        self.assertEqual(environment['SSH_ASKPASS_REQUIRE'], 'force')
        self.assertNotIn('SSH_AUTH_SOCK', environment)
        self.assertEqual(installer.askpass.stat().st_mode & 0o777, 0o700)
        self.assertIsNone(installer.poll())
        installer.output.write(b'failure fixture-secret-with-spaces details\n')
        child.code = 1
        self.assertEqual(installer.poll(), {'status': 'failed', 'reason': 'guest_install_failed', 'returnCode': 1})
        self.assertEqual(log.read_bytes(), b'failure [REDACTED] details\n')
        self.assertFalse(installer.askpass.exists())
        self.assertEqual(installer.password, b'')

    def test_cancel_only_stops_the_owned_child_and_removes_helper(self):
        child = self.fake_child()
        with patch.object(access.subprocess, 'Popen', return_value=child), patch.object(access.os, 'killpg') as stop:
            installer = access.GuestInstaller('192.168.64.3', 'guest', self.password, self.known, 'big-wallet-vm-fixture', self.work,
                                              provision_directory=self.payload)
            installer.cancel()
        stop.assert_called_once_with(child.pid, access.signal.SIGTERM)
        self.assertEqual(installer.poll()['reason'], 'guest_install_cancelled')
        self.assertFalse(installer.askpass.exists())

    def test_stop_accepts_exit_races_during_termination_and_escalation(self):
        for error_type in (ProcessLookupError, PermissionError):
            for escalate in (False, True):
                with self.subTest(error=error_type.__name__, escalate=escalate):
                    child = Mock(pid=424242)
                    child.poll.return_value = None
                    child.wait.side_effect = [subprocess.TimeoutExpired('fixture', 0.1), 0] if escalate else [0]
                    signals = [access.signal.SIGTERM, access.signal.SIGKILL] if escalate else [access.signal.SIGTERM]
                    errors = [None, error_type()] if escalate else [error_type()]
                    with patch.object(access.os, 'killpg', side_effect=errors) as stop:
                        access._stop(child, grace=0.1)
                    self.assertEqual(stop.call_args_list, [call(child.pid, value) for value in signals])
                    child.poll.assert_called_once_with()
                    self.assertEqual(child.wait.call_args_list, [call(timeout=0.1)] * len(signals))

    def test_stop_preserves_signaling_errors_for_a_running_child(self):
        for error_type in (ProcessLookupError, PermissionError):
            for escalate in (False, True):
                with self.subTest(error=error_type.__name__, escalate=escalate):
                    child = Mock(pid=424242)
                    child.poll.return_value = None
                    child.wait.side_effect = subprocess.TimeoutExpired('fixture', 0.1)
                    error = error_type()
                    with patch.object(access.os, 'killpg', side_effect=[None, error] if escalate else [error]):
                        with self.assertRaises(error_type) as raised:
                            access._stop(child, grace=0.1)
                    self.assertIs(raised.exception, error)
                    self.assertEqual(child.wait.call_args_list, [call(timeout=0.1)] * (2 if escalate else 1))

    def test_launch_failure_does_not_publish_raw_error_or_leave_helper(self):
        before = set(self.work.iterdir())
        with patch.object(access.subprocess, 'Popen', side_effect=OSError('fixture-secret-with-spaces')):
            with self.assertRaisesRegex(access.GuestAccessError, '^Could not start the guest SSH installer$'):
                access.GuestInstaller('192.168.64.3', 'guest', self.password, self.known, 'big-wallet-vm-fixture', self.work,
                                      provision_directory=self.payload)
        self.assertEqual(set(self.work.iterdir()), before)

    def test_stdin_failure_stops_started_child_before_removing_private_state(self):
        child = self.fake_child()
        before = set(self.work.iterdir())
        with patch.object(access.subprocess, 'Popen', return_value=child), \
                patch.object(access._PayloadProducer, 'write', side_effect=OSError('fixture-secret-with-spaces')), \
                patch.object(access.os, 'killpg') as stop:
            installer = access.GuestInstaller('192.168.64.3', 'guest', self.password, self.known, 'big-wallet-vm-fixture', self.work,
                                              provision_directory=self.payload)
            installer.producer.join()
            result = installer.poll()
            self.assertEqual(result['reason'], 'guest_payload_transfer_failed')
            self.assertNotIn('fixture-secret-with-spaces', repr(result))
        stop.assert_called_once_with(child.pid, access.signal.SIGTERM)
        self.assertIsNotNone(child.poll())
        self.assertEqual(set(self.work.iterdir()), before)

    def preparation_receipt(self, required=None, **extra):
        return {'stagingDirectory': '/Volumes/BigWalletBuild/Provisioning/12345678-1234-1234-1234-123456789abc/provision',
                'requiredInputs': required or [], **extra}

    def test_prepare_success_starts_full_phase_with_only_requested_large_inputs(self):
        first, second = self.fake_child(), self.fake_child()
        with patch.object(access.subprocess, 'Popen', side_effect=[first, second]) as launch:
            installer = access.GuestInstaller('192.168.64.3', 'guest', self.password, self.known, 'big-wallet-vm-fixture', self.work,
                                              provision_directory=self.payload)
            installer.producer.join()
            receipt = self.preparation_receipt(['Xcode.tar', 'runtime-1.dmg'])
            installer.output.write(b'prepare completed\nBIG_WALLET_PROVISIONING_STAGE=' + json.dumps(receipt).encode() + b'\n')
            first.code = 0
            self.assertIsNone(installer.poll())
            self.assertEqual(installer.phase, 'install')
            self.assertEqual(launch.call_count, 2)
            self.assertTrue(installer.askpass.exists())
            installer.producer.join()
            with tarfile.open(fileobj=io.BytesIO(second.stdin.sent.split(b'\n', 2)[2])) as archive:
                self.assertEqual(set(archive.getnames()), {'config.json', 'provision_guest.sh', 'autologin-passwordFile',
                                                          'Xcode.tar', 'runtime-1.dmg'})
            self.assertIsNone(installer.poll())
            second.code = 0
            self.assertEqual(installer.poll(), {'status': 'passed'})
            self.assertFalse(installer.askpass.exists())
        self.assertIn('--prepare-storage', launch.call_args_list[0].args[0][-1])
        self.assertNotIn('--prepare-storage', launch.call_args_list[1].args[0][-1])

    def test_prepare_restart_request_never_starts_full_phase_or_reboots_guest(self):
        child = self.fake_child()
        with patch.object(access.subprocess, 'Popen', return_value=child) as launch:
            installer = access.GuestInstaller('192.168.64.3', 'guest', self.password, self.known, 'big-wallet-vm-fixture', self.work,
                                              provision_directory=self.payload)
            installer.producer.join()
            receipt = self.preparation_receipt(['Xcode.tar'], requiresRestart=True)
            installer.output.write(b'BIG_WALLET_PROVISIONING_STAGE=' + json.dumps(receipt).encode() + b'\n')
            child.code = 0
            self.assertEqual(installer.poll(), {'status': 'restart-required'})
        self.assertEqual(launch.call_count, 1)
        self.assertNotIn('shutdown', launch.call_args.args[0][-1])
        self.assertNotIn('reboot', launch.call_args.args[0][-1])
        self.assertFalse(installer.askpass.exists())

    def test_prepare_response_rejects_unsafe_paths_inputs_and_restart_types(self):
        receipts = [self.preparation_receipt(['../secret']), self.preparation_receipt(['autologin-passwordFile']),
                    self.preparation_receipt(['Xcode.tar', 'Xcode.tar']), self.preparation_receipt(requiresRestart='true'),
                    {**self.preparation_receipt(), 'stagingDirectory': '/private/tmp/another-user'},
                    {**self.preparation_receipt(), 'unexpected': True}]
        for receipt in receipts:
            with self.subTest(receipt=receipt), self.assertRaisesRegex(access.GuestAccessError, 'response is invalid'):
                access._prepare_response(b'BIG_WALLET_PROVISIONING_STAGE=' + json.dumps(receipt).encode(), {'Xcode.tar'})
        with self.assertRaisesRegex(access.GuestAccessError, 'response is invalid'):
            line = b'BIG_WALLET_PROVISIONING_STAGE=' + json.dumps(self.preparation_receipt()).encode() + b'\n'
            access._prepare_response(line + line, {'Xcode.tar'})

    def test_prepare_exit_zero_without_receipt_is_not_install_success(self):
        child = self.fake_child()
        with patch.object(access.subprocess, 'Popen', return_value=child) as launch:
            installer = access.GuestInstaller('192.168.64.3', 'guest', self.password, self.known, 'big-wallet-vm-fixture', self.work,
                                              provision_directory=self.payload)
            installer.producer.join()
            child.code = 0
            self.assertEqual(installer.poll(), {'status': 'failed', 'reason': 'guest_prepare_response_invalid'})
        self.assertEqual(launch.call_count, 1)

    def test_payload_rejects_symlinks_and_account_mismatch_before_launch(self):
        (self.payload / 'credential-link').symlink_to(self.password)
        with patch.object(access.subprocess, 'Popen') as launch:
            with self.assertRaisesRegex(access.GuestAccessError, 'symlink'):
                access.GuestInstaller('192.168.64.3', 'guest', self.password, self.known, 'big-wallet-vm-fixture', self.work,
                                      provision_directory=self.payload)
        launch.assert_not_called()
        (self.payload / 'credential-link').unlink()
        with self.assertRaisesRegex(access.GuestAccessError, 'does not match'):
            access._payload_files(self.payload, 'different-user', 'big-wallet-vm-fixture')

    def test_cancel_stops_producer_when_large_archive_pipe_is_full(self):
        read_descriptor, write_descriptor = os.pipe()
        self.addCleanup(os.close, read_descriptor)
        pipe = os.fdopen(write_descriptor, 'wb', buffering=0)
        self.addCleanup(pipe.close)
        large = self.payload / 'large-fixture'
        large.write_bytes(b'x' * (2 * 1024 * 1024))
        blocked = threading.Event()
        real_write = os.write

        def write(descriptor, data):
            try:
                return real_write(descriptor, data)
            except BlockingIOError:
                blocked.set()
                raise

        with patch.object(access.os, 'write', side_effect=write):
            producer = access._PayloadProducer(pipe, b'fixture-password', 'BIG_WALLET_PAYLOAD_' + 'b' * 32, {'large-fixture': large})
            self.assertTrue(blocked.wait(1))
            producer.cancel()
            producer.join(1)
        self.assertTrue(producer.done.is_set())
        self.assertTrue(pipe.closed)
        self.assertFalse(producer.thread.is_alive())
        self.assertEqual(producer.password, b'')

    def test_banner_probe_has_no_authentication_command_or_credentials(self):
        child = self.fake_child()
        with patch.object(access.subprocess, 'Popen', return_value=child) as launch, patch.object(access.os, 'killpg'):
            probe = access.SSHBannerProbe('192.168.64.3')
            probe.output.write(b'SSH-2.0-OpenSSH_fixture\r\n')
            self.assertEqual(probe.poll(), {'status': 'passed'})
        self.assertEqual(launch.call_args.args[0], ['/usr/bin/nc', '-d', '-G', '3', '-w', '3', '192.168.64.3', '22'])
        self.assertEqual(launch.call_args.kwargs['stdin'], subprocess.DEVNULL)
        self.assertTrue(probe.output.closed)


if __name__ == '__main__':
    unittest.main()
