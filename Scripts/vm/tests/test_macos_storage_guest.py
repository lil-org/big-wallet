import copy
import errno
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location('macos_storage_guest', Path(__file__).resolve().parents[1] / 'macos_storage_guest.py')
storage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(storage)

GIB = 1024 ** 3
OLD = {'version': '27.0.1', 'buildVersion': '26A434'}
TARGET = {'version': '27.2', 'buildVersion': '26B123'}
REQUEST = {'vmId': 'fixture-vm', 'consoleUser': 'wallet-test', 'upgradeID': 'macos-upgrade-fixture', 'upgradeNonce': 'a' * 64, 'target': TARGET}
GUIDS = {'disk': '11111111-1111-4111-8111-111111111111', 'isc': '618089E5-6254-493C-97DD-43C17452091C',
    'main': '278B421A-30BA-4DA7-8D02-B6F2AC96E51A', 'recovery': '53A21358-3E7D-4D07-9436-49AC1702454A',
    'mainContainer': '6F484C6D-2CC0-4303-A7BC-7BE097B228E2', 'recoveryContainer': '34EF2A46-F65C-4C82-96E4-F5B8065E8AA2',
    'iscContainer': '7147975C-6B69-4EDB-8258-33D2E4DBE723', 'snapshot': 'AAA09E8F-B64B-45EF-9FFE-871CBD1596D7',
    'system': '15FE74A4-FAF5-4807-9702-CC21ECB4B6D4', 'data': '9769B715-6045-44A5-8CEE-B5AE30DC3A29',
    'recoveryVolume': '0A6E6C5F-C5B6-47EF-A520-880D04A3451E', 'iscVolume': '63F1F780-BEC5-4524-AB84-CFA97C6495A4'}
MAIN_OFFSET = 524308480
MAIN_BYTES = 62826479616
RECOVERY_BYTES = 5368668160
GROWTH = {'oldBytes': 64 * GIB, 'newBytes': 96 * GIB, 'sectorBytes': 512, 'diskGUID': GUIDS['disk'],
    'mainPartitionGUID': GUIDS['main'], 'recoveryPartitionGUID': GUIDS['recovery'], 'mainPartitionBytes': MAIN_BYTES,
    'expectedContainerBytes': MAIN_BYTES + 32 * GIB, 'gapBytes': 32 * GIB, 'mainFirstLBA': MAIN_OFFSET // 512,
    'mainLastLBA': (MAIN_OFFSET + MAIN_BYTES) // 512 - 1, 'recoveryFirstLBA': (MAIN_OFFSET + MAIN_BYTES + 32 * GIB) // 512,
    'recoveryLastLBA': (MAIN_OFFSET + MAIN_BYTES + 32 * GIB + RECOVERY_BYTES) // 512 - 1,
    'recoveryBytes': RECOVERY_BYTES, 'trailingPaddingSectors': 7}


class StorageError(RuntimeError):
    pass


class StorageGrowthTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.grown = False
        self.calls = []
        self.changes = lambda root, apfs, layout, infos: None
        self.after_changes = lambda root, apfs, layout, infos: None
        self.free_after = 44 * GIB
        self.observation = {'actual': OLD, 'bootIdentity': '12345678-1234-4234-8234-123456789012'}
        self.helpers = SimpleNamespace(UpdateError=StorageError, UPGRADE_DIRECTORY=self.root / 'upgrades',
            ENVIRONMENT={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'}, validate_request=Mock(side_effect=lambda value: value),
            attest=Mock(side_effect=lambda request: copy.deepcopy(self.observation)), protected=self.protected,
            read_json=self.read_json, write_json=self.write_json, run=self.run_command, timestamp=lambda: 'fixture-time')

    def protected(self, path, **options):
        metadata = Path(path).lstat()
        self.assertEqual(Path(path).resolve(), Path(path))
        self.assertEqual(metadata.st_uid, os.geteuid())
        return metadata

    def read_json(self, path, *, missing=False):
        if missing and not path.exists():
            return None
        return json.loads(path.read_text())

    def write_json(self, path, value):
        path.write_text(json.dumps(value))
        path.chmod(0o600)

    def inventory(self):
        main_bytes = GROWTH['expectedContainerBytes'] if self.grown else MAIN_BYTES
        main_free = self.free_after if self.grown else 14 * GIB
        root = {'MountPoint': '/', 'FilesystemType': 'apfs', 'DeviceIdentifier': 'disk5s1s1',
            'APFSContainerReference': 'disk5', 'ParentWholeDisk': 'disk5', 'DiskUUID': GUIDS['snapshot'],
            'APFSPhysicalStores': [{'APFSPhysicalStore': 'disk0s2'}], 'APFSContainerSize': main_bytes, 'FileVault': False}
        def container(reference, physical, uuid, size, capacity_free, volumes):
            return {'ContainerReference': reference, 'APFSContainerUUID': uuid,
                'PhysicalStores': [{'DeviceIdentifier': physical[0], 'DiskUUID': physical[1], 'Size': size}],
                'CapacityCeiling': size, 'CapacityFree': capacity_free,
                'Volumes': [{'APFSVolumeUUID': volume, 'Encryption': False, 'FileVault': False} for volume in volumes]}
        apfs = {'Containers': [
            container('disk2', ('disk0s1', GUIDS['isc']), GUIDS['iscContainer'], 524288000, 500000000, [GUIDS['iscVolume']]),
            container('disk3', ('disk0s3', GUIDS['recovery']), GUIDS['recoveryContainer'], RECOVERY_BYTES, 3 * GIB, [GUIDS['recoveryVolume']]),
            container('disk5', ('disk0s2', GUIDS['main']), GUIDS['mainContainer'], main_bytes, main_free, [GUIDS['system'], GUIDS['data']]),
            {'ContainerReference': 'disk4', 'PhysicalStores': [{'DeviceIdentifier': 'disk1s2', 'DiskUUID': '22222222-2222-4222-8222-222222222222'}],
             'Volumes': [{'Encryption': True, 'FileVault': False}]},
            {'ContainerReference': 'disk7', 'PhysicalStores': [{'DeviceIdentifier': 'disk6', 'Size': 4194304}],
             'Volumes': [{'Encryption': False, 'FileVault': False}]}]}
        entries = [('disk0s1', GUIDS['isc'], 'Apple_APFS_ISC', 20480, 524288000),
            ('disk0s2', GUIDS['main'], 'Apple_APFS', MAIN_OFFSET, main_bytes),
            ('disk0s3', GUIDS['recovery'], 'Apple_APFS_Recovery', GROWTH['recoveryFirstLBA'] * 512, RECOVERY_BYTES)]
        infos = {device: {'DeviceIdentifier': device, 'DiskUUID': uuid, 'Content': content, 'ParentWholeDisk': 'disk0',
            'WholeDisk': False, 'PartitionMapPartition': True, 'PartitionMapPartitionOffset': offset,
            'TotalSize': size, 'Size': size} for device, uuid, content, offset, size in entries}
        layout = {'AllDisksAndPartitions': [{'DeviceIdentifier': 'disk0', 'Content': 'GUID_partition_scheme',
            'Size': GROWTH['newBytes'], 'Partitions': [{'DeviceIdentifier': device, 'DiskUUID': uuid, 'Content': content,
                                                     'Size': size} for device, uuid, content, offset, size in entries]},
            {'DeviceIdentifier': 'disk1', 'Content': 'GUID_partition_scheme', 'Size': 96 * GIB, 'Partitions': []}]}
        self.changes(root, apfs, layout, infos)
        if self.grown:
            self.after_changes(root, apfs, layout, infos)
        return root, apfs, layout, infos

    def run_command(self, command, **options):
        self.calls.append(command)
        self.assertEqual(command[0], storage.DISKUTIL)
        root, apfs, layout, infos = self.inventory()
        if command[1:] == ['info', '-plist', '/']:
            return plistlib.dumps(root)
        if command[1:] == ['apfs', 'list', '-plist']:
            return plistlib.dumps(apfs)
        if command[1:] == ['list', '-plist']:
            return plistlib.dumps(layout)
        if command[1:3] == ['info', '-plist']:
            self.assertNotIn(command[3], ('disk1', 'disk1s2', 'disk4'))
            return plistlib.dumps(infos[command[3]])
        raise AssertionError('Unexpected disk command ' + repr(command))

    def resize(self, helpers, reference, lock):
        self.calls.append([storage.DISKUTIL, 'apfs', 'resizeContainer', reference, '0'])
        self.assertEqual(reference, 'disk5')
        self.assertGreaterEqual(lock, 0)
        self.grown = True

    def invoke(self, *, growth=None, resize=None):
        def statvfs(path):
            self.assertEqual(path, '/')
            return SimpleNamespace(f_bavail=(self.free_after if self.grown else 14 * GIB) // 4096, f_frsize=4096)
        with patch.object(storage.os, 'statvfs', side_effect=statvfs), \
                patch.object(storage, 'resize', side_effect=resize or self.resize):
            return storage.grow_container(REQUEST, GROWTH if growth is None else growth, self.helpers)

    def test_grows_only_the_root_container_and_preserves_recovery_isc_and_encrypted_build_disk(self):
        result = self.invoke()
        self.assertEqual(result['status'], 'ready')
        self.assertEqual(result['actual'], OLD)
        self.assertTrue(result['safeToStop'])
        self.assertEqual(result['storage']['status'], 'grown')
        self.assertEqual(result['storage']['growth'], GROWTH)
        self.assertEqual(result['storage']['after']['main']['bytes'], GROWTH['expectedContainerBytes'])
        for key in ('root', 'disk', 'recovery', 'isc'):
            self.assertEqual(result['storage']['before'][key], result['storage']['after'][key])
        mutations = [command for command in self.calls if 'resizeContainer' in command]
        self.assertEqual(mutations, [[storage.DISKUTIL, 'apfs', 'resizeContainer', 'disk5', '0']])
        receipt = self.read_json(self.helpers.UPGRADE_DIRECTORY / REQUEST['upgradeID'] / 'storage.json')
        self.assertEqual(receipt['phase'], 'grown')
        self.assertEqual(receipt['request'], REQUEST)

    def test_root_vm_attestation_happens_before_storage_probes_or_state_creation(self):
        self.helpers.attest.side_effect = StorageError('guest_virtual_machine_root_required')
        with self.assertRaisesRegex(StorageError, 'virtual_machine'):
            self.invoke()
        self.assertEqual(self.calls, [])
        self.assertFalse(self.helpers.UPGRADE_DIRECTORY.exists())

    def assert_preflight_rejected(self, result):
        self.assertTrue(result['safeToStop'])
        self.assertEqual(result['status'], 'blocked')
        self.assertEqual(result['storage']['status'], 'preflight-rejected')
        self.assertEqual(result['storage']['request'], REQUEST)
        self.assertFalse((self.helpers.UPGRADE_DIRECTORY / REQUEST['upgradeID'] / 'storage.json').exists())
        return result['reason']

    def test_invalid_growth_geometry_cannot_run_diskutil(self):
        for key, value in [('newBytes', 64 * GIB), ('gapBytes', 31 * GIB), ('mainFirstLBA', 0),
                           ('recoveryBytes', RECOVERY_BYTES - 512), ('trailingPaddingSectors', 8),
                           ('mainPartitionGUID', GUIDS['recovery']), ('sectorBytes', 4096), ('oldBytes', True)]:
            with self.subTest(key=key):
                self.assert_preflight_rejected(self.invoke(growth={**GROWTH, key: value}))
        self.assertEqual(self.calls, [])

    def test_root_snapshot_uuid_is_not_mistaken_for_the_main_partition_or_system_volume_uuid(self):
        self.assertNotIn(GUIDS['snapshot'], (GUIDS['main'], GUIDS['system']))
        self.assertEqual(self.invoke()['storage']['after']['root']['volumeUUID'], GUIDS['snapshot'])

    def test_wrong_root_store_main_guid_recovery_bounds_and_disk_size_are_rejected(self):
        changes = [lambda root, apfs, layout, infos: root['APFSPhysicalStores'][0].update(APFSPhysicalStore='disk1s2'),
            lambda root, apfs, layout, infos: apfs['Containers'][2]['PhysicalStores'][0].update(DiskUUID=GUIDS['recovery']),
            lambda root, apfs, layout, infos: infos['disk0s3'].update(PartitionMapPartitionOffset=63350788096),
            lambda root, apfs, layout, infos: layout['AllDisksAndPartitions'][0].update(Size=64 * GIB),
            lambda root, apfs, layout, infos: infos['disk0s2'].update(ParentWholeDisk='disk1')]
        for change in changes:
            with self.subTest(change=change):
                self.changes = change
                self.assert_preflight_rejected(self.invoke())
        self.assertFalse(any('resizeContainer' in command for command in self.calls))

    def test_encrypted_locked_fusion_or_multiple_root_stores_are_rejected(self):
        changes = [lambda root, apfs, layout, infos: apfs['Containers'][2]['Volumes'][0].update(Encryption=True),
            lambda root, apfs, layout, infos: apfs['Containers'][1]['Volumes'][0].update(FileVault=True),
            lambda root, apfs, layout, infos: apfs['Containers'][0]['Volumes'][0].update(Locked=True),
            lambda root, apfs, layout, infos: apfs['Containers'][2].update(Fusion=True),
            lambda root, apfs, layout, infos: apfs['Containers'][2]['PhysicalStores'].append({'DeviceIdentifier': 'disk1s2'})]
        for change in changes:
            with self.subTest(change=change):
                self.changes = change
                self.assert_preflight_rejected(self.invoke())
        self.assertFalse(any('resizeContainer' in command for command in self.calls))

    def test_already_grown_container_is_verified_without_another_mutation(self):
        self.invoke()
        self.calls.clear()
        result = self.invoke(resize=Mock(side_effect=AssertionError('Duplicate resize')))
        self.assertTrue(result['storage']['alreadyGrown'])
        self.assertEqual(result['storage']['before']['main']['bytes'], MAIN_BYTES)
        self.assertFalse(any('resizeContainer' in command for command in self.calls))

    def test_future_upgrade_with_an_already_large_disk_uses_read_only_storage_verification(self):
        self.grown = True
        receipt = {**GROWTH, 'oldBytes': GROWTH['newBytes'], 'mainPartitionBytes': GROWTH['expectedContainerBytes'],
                   'gapBytes': 0, 'mainLastLBA': GROWTH['recoveryFirstLBA'] - 1}
        result = self.invoke(growth=receipt, resize=Mock(side_effect=AssertionError('Already large disk was resized')))
        self.assertEqual(result['status'], 'ready')
        self.assertTrue(result['storage']['alreadyGrown'])

    def test_cold_boot_reverification_resolves_new_device_numbers_by_stable_guids(self):
        self.invoke()
        self.observation['bootIdentity'] = '12345678-1234-4234-8234-123456789013'
        def renumber(root, apfs, layout, infos):
            root.update(DeviceIdentifier='disk8s1s1', APFSContainerReference='disk8', ParentWholeDisk='disk8')
            root['APFSPhysicalStores'][0]['APFSPhysicalStore'] = 'disk2s2'
            apfs['Containers'][2]['ContainerReference'] = 'disk8'
            apfs['Containers'][1]['ContainerReference'] = 'disk9'
            apfs['Containers'][0]['ContainerReference'] = 'disk10'
            for entry in apfs['Containers'][:3]:
                entry['PhysicalStores'][0]['DeviceIdentifier'] = entry['PhysicalStores'][0]['DeviceIdentifier'].replace('disk0', 'disk2')
            layout['AllDisksAndPartitions'][0]['DeviceIdentifier'] = 'disk2'
            for entry in layout['AllDisksAndPartitions'][0]['Partitions']:
                entry['DeviceIdentifier'] = entry['DeviceIdentifier'].replace('disk0', 'disk2')
            for key in list(infos):
                value = infos.pop(key)
                value.update(DeviceIdentifier=key.replace('disk0', 'disk2'), ParentWholeDisk='disk2')
                infos[value['DeviceIdentifier']] = value
        self.changes = renumber
        result = self.invoke(resize=Mock(side_effect=AssertionError('Cold boot repeated resize')))
        self.assertTrue(result['storage']['alreadyGrown'])
        self.assertEqual(result['storage']['after']['root']['container'], 'disk8')

    def test_partial_growth_does_not_authorize_another_resize(self):
        def partial(root, apfs, layout, infos):
            amount = MAIN_BYTES + 16 * GIB
            root['APFSContainerSize'] = amount
            apfs['Containers'][2]['CapacityCeiling'] = amount
            apfs['Containers'][2]['PhysicalStores'][0]['Size'] = amount
            infos['disk0s2']['TotalSize'] = amount
            layout['AllDisksAndPartitions'][0]['Partitions'][1]['Size'] = amount
        self.changes = partial
        self.assertRegex(self.assert_preflight_rejected(self.invoke()), 'bounds_mismatch')
        self.assertFalse(any('resizeContainer' in command for command in self.calls))

    def test_changed_recovery_after_resize_never_reports_success(self):
        self.after_changes = lambda root, apfs, layout, infos: apfs['Containers'][1].update(APFSContainerUUID=GUIDS['disk'])
        with self.assertRaisesRegex(StorageError, 'recovery_container_changed'):
            self.invoke()

    def test_growth_too_small_for_the_admission_minimum_is_rejected_before_resize_intent(self):
        reduction = 28 * GIB
        with patch.dict(GROWTH, newBytes=GROWTH['newBytes'] - reduction, gapBytes=GROWTH['gapBytes'] - reduction,
                        expectedContainerBytes=GROWTH['expectedContainerBytes'] - reduction,
                        recoveryFirstLBA=GROWTH['recoveryFirstLBA'] - reduction // 512,
                        recoveryLastLBA=GROWTH['recoveryLastLBA'] - reduction // 512):
            self.assertEqual(self.assert_preflight_rejected(self.invoke()), 'guest_storage_insufficient_growth_increment')
        self.assertFalse(any('resizeContainer' in command for command in self.calls))

    def test_low_free_space_blocks_os_admission_after_proven_growth_and_on_cold_resume(self):
        self.free_after = 19 * GIB
        result = self.invoke()
        receipt_path = self.helpers.UPGRADE_DIRECTORY / REQUEST['upgradeID'] / 'storage.json'
        self.assertEqual(self.read_json(receipt_path)['phase'], 'grown')
        self.observation['bootIdentity'] = '12345678-1234-4234-8234-123456789013'
        cold = self.invoke(resize=Mock(side_effect=AssertionError('Cold boot repeated resize')))
        self.assertTrue(cold['storage']['alreadyGrown'])
        for observation in (result, cold):
            self.assertEqual(observation['status'], 'blocked')
            self.assertTrue(observation['safeToStop'])
            self.assertEqual(observation['reason'], 'guest_storage_insufficient_free_space_after_growth')
            self.assertEqual(observation['storage']['status'], 'grown')
            self.assertEqual(observation['storage']['after']['main']['bytes'], GROWTH['expectedContainerBytes'])

    def test_active_kernel_lock_returns_waiting_without_another_disk_command(self):
        descriptor = os.open(self.helpers.UPGRADE_DIRECTORY.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.invoke()
        finally:
            os.close(descriptor)
        self.assertEqual(result['status'], 'installing')
        self.assertFalse(result['safeToStop'])
        self.assertEqual(result['storage']['status'], 'growing')
        self.assertEqual(self.calls, [])

    def test_no_space_before_receipt_is_safe_but_after_intent_requires_reconciliation(self):
        no_space = OSError(errno.ENOSPC, 'No space left on device')
        with patch.object(self.helpers, 'write_json', side_effect=no_space):
            self.assertEqual(self.assert_preflight_rejected(self.invoke()), 'guest_storage_receipt_out_of_space')
        self.assertFalse(any('resizeContainer' in command for command in self.calls))
        with self.assertRaises(OSError):
            self.invoke(resize=Mock(side_effect=no_space))

    def test_interrupted_growth_receipt_can_verify_completed_layout_without_repeating_command(self):
        def response_lost(helpers, reference, lock):
            self.grown = True
            raise StorageError('fixture response lost')
        with self.assertRaisesRegex(StorageError, 'response lost'):
            self.invoke(resize=response_lost)
        self.calls.clear()
        result = self.invoke(resize=Mock(side_effect=AssertionError('Duplicate resize')))
        self.assertEqual(result['storage']['status'], 'grown')
        self.assertTrue(result['storage']['alreadyGrown'])

    def test_uncertain_unchanged_layout_is_not_blindly_retried(self):
        with self.assertRaisesRegex(StorageError, 'fixture failure'):
            self.invoke(resize=Mock(side_effect=StorageError('fixture failure')))
        with self.assertRaisesRegex(StorageError, 'previous_growth_not_verified'):
            self.invoke(resize=Mock(side_effect=AssertionError('Blind retry')))

    def test_growth_receipt_cannot_be_reused_for_another_target(self):
        self.invoke()
        path = self.helpers.UPGRADE_DIRECTORY / REQUEST['upgradeID'] / 'storage.json'
        receipt = self.read_json(path)
        receipt['request']['target'] = {'version': '28.0', 'buildVersion': '27A100'}
        self.write_json(path, receipt)
        self.calls.clear()
        with self.assertRaisesRegex(StorageError, 'receipt_mismatch'):
            self.invoke()
        self.assertEqual(self.calls, [])

    def test_boot_change_during_resize_cannot_attest_completion(self):
        before = copy.deepcopy(self.observation)
        after = {**before, 'bootIdentity': '12345678-1234-4234-8234-123456789013'}
        self.helpers.attest.side_effect = [before, after]
        with self.assertRaisesRegex(StorageError, 'boot_identity_changed'):
            self.invoke()

    def test_duplicate_main_partition_guid_is_ambiguous_even_with_root_container_reference(self):
        def duplicate(root, apfs, layout, infos):
            apfs['Containers'].append(copy.deepcopy(apfs['Containers'][2]))
            apfs['Containers'][-1]['ContainerReference'] = 'disk8'
        self.changes = duplicate
        self.assertRegex(self.assert_preflight_rejected(self.invoke()), 'container_ambiguous')
        self.assertFalse(any('resizeContainer' in command for command in self.calls))

    def test_resize_child_inherits_storage_lock_and_executes_only_the_bounded_diskutil_command(self):
        descriptor = os.open(self.root / 'lock', os.O_RDWR | os.O_CREAT, 0o600)
        try:
            with patch.object(storage.subprocess, 'run', return_value=SimpleNamespace(returncode=0)) as run:
                storage.resize(self.helpers, 'disk5', descriptor)
            self.assertEqual(run.call_args.args[0], [storage.DISKUTIL, 'apfs', 'resizeContainer', 'disk5', '0'])
            self.assertEqual(run.call_args.kwargs['pass_fds'], (descriptor,))
            self.assertEqual(run.call_args.kwargs['timeout'], 300)
            self.assertEqual(run.call_args.kwargs['stdin'], subprocess.DEVNULL)
        finally:
            os.close(descriptor)


if __name__ == '__main__':
    unittest.main()
