import contextlib
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import uuid
import zlib


specification = importlib.util.spec_from_file_location('macos_disk', Path(__file__).resolve().parents[1] / 'macos_disk.py')
disk = importlib.util.module_from_spec(specification)
specification.loader.exec_module(disk)

specification = importlib.util.spec_from_file_location('vm_host_services', Path(__file__).resolve().parents[1] / 'host.py')
host = importlib.util.module_from_spec(specification)
specification.loader.exec_module(host)


def fixture_image(size=4 * 1024 ** 2, recovery_sectors=512):
    sectors = size // 512
    recovery_last = sectors - 41
    recovery_first = recovery_last - recovery_sectors + 1
    bounds = [(40, 103), (104, recovery_first - 1), (recovery_first, recovery_last)]
    entries = bytearray(128 * 128)
    guids = [uuid.UUID(int=index + 1) for index in range(3)]
    for index, (kind, (first, last), identifier) in enumerate(zip(disk.PARTITION_TYPES, bounds, guids)):
        offset = index * 128
        entries[offset:offset + 16] = uuid.UUID(kind).bytes_le
        entries[offset + 16:offset + 32] = identifier.bytes_le
        struct.pack_into('<QQQ', entries, offset + 32, first, last, index + 8)
        label = ['iBootSystemContainer', 'Container', 'RecoveryOSContainer'][index].encode('utf-16le')
        entries[offset + 56:offset + 56 + len(label)] = label
    image = bytearray(size)
    image[450] = 0xee
    struct.pack_into('<II', image, 454, 1, sectors - 1)
    image[510:512] = b'\x55\xaa'
    for own, alternate, table in ((1, sectors - 1, 2), (sectors - 1, 1, sectors - 33)):
        header = bytearray(512)
        struct.pack_into('<8sIIIIQQQQ16sQIII', header, 0, b'EFI PART', 0x10000, 92, 0, 0,
            own, alternate, 34, sectors - 34, uuid.UUID(int=10).bytes_le, table, 128, 128, zlib.crc32(entries))
        struct.pack_into('<I', header, 16, zlib.crc32(header[:92]))
        image[own * 512:(own + 1) * 512] = header
        image[table * 512:table * 512 + len(entries)] = entries
    image[40 * 512:104 * 512] = b'I' * (64 * 512)
    image[104 * 512:recovery_first * 512] = b'M' * ((recovery_first - 104) * 512)
    image[recovery_first * 512:(recovery_last + 1) * 512] = bytes(index % 251 for index in range(recovery_sectors * 512))
    return bytes(image)


class DiskGrowthTests(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.root = Path(self.stack.enter_context(tempfile.TemporaryDirectory())).resolve()
        self.identifier = 'macos-upgrade-fixture'
        self.state = self.root / self.identifier / 'state'
        self.state.mkdir(parents=True, mode=0o700)
        (self.state / 'baseline.json').write_text(json.dumps({'vmId': 'fixture', 'macosUpgradeID': self.identifier,
            'sourceVM': str(self.root / 'original.vbvm')}))
        self.vm = self.state / 'baseline.vbvm'
        self.vm.mkdir(mode=0o700)
        (self.vm / '.vbdata').mkdir(mode=0o700)
        self.image = self.vm / 'Disk.img'
        self.original = fixture_image()
        self.image.write_bytes(self.original)
        self.image.chmod(0o600)
        self.config = self.vm / '.vbdata/Config.plist'
        self.configuration = {'systemType': 'mac', 'hardware': {'cpuCount': 8, '_storageDevices': [
            {'isBootVolume': True, 'isSavedStateClone': False, 'isReadOnly': False,
             'backing': {'managedImage': {'_0': {'filename': 'Disk', 'format': 0, 'size': len(self.original), 'id': '__BOOT__'}}}},
            {'isBootVolume': False, 'backing': {'managedImage': {'_0': {
                'filename': 'BuildData', 'format': 0, 'size': 96 * 1024 ** 3, 'id': '__BIG_WALLET_BUILD__'}}}}]},
            'sharedFolders': [], 'preservedPreference': 'unchanged'}
        self.config.write_bytes(plistlib.dumps(self.configuration, fmt=plistlib.FMT_BINARY))
        self.receipt = self.state / 'system-disk-growth.json'
        self.tools = self.state / 'tools'
        self.tools.mkdir()
        self.host = Mock(spec_set=host.host_services(), TOOLS=self.tools, RunnerError=RuntimeError, HOST_RESERVE_BYTES=4096,
            read_json=lambda path: json.loads(path.read_text()),
            atomic_json=lambda path, value: path.write_text(json.dumps(value)),
            private_directory=self.private_directory, ensure_disk_idle=Mock(), validate_vm=self.validate_vm)
        self.clone = self.host.clone_cow = Mock(side_effect=shutil.copy2)
        self.unencrypted = self.stack.enter_context(patch.object(disk, '_unencrypted'))
        self.capacity = self.stack.enter_context(patch.object(disk.shutil, 'disk_usage', return_value=SimpleNamespace(free=1024 ** 3)))
        self.new_bytes = len(self.original) + 2 * 1024 ** 2

    def private_directory(self, path):
        path.mkdir(mode=0o700)
        return path

    def validate_vm(self, path):
        self.assertTrue((path / 'Disk.img').is_file())
        return plistlib.loads((path / '.vbdata/Config.plist').read_bytes())

    def grow(self):
        return disk.grow(self.host, self.vm, self.new_bytes, self.receipt)

    def test_growth_preserves_recovery_main_isc_and_all_identifiers(self):
        before = disk.inspect(self.image)
        result = self.grow()
        after = disk.inspect(self.image)
        self.assertTrue(result['resized'])
        self.assertEqual(result['gapBytes'], self.new_bytes - len(self.original))
        self.assertEqual(result['trailingPaddingSectors'], 7)
        self.assertEqual(after['partitions'][:2], before['partitions'][:2])
        old_recovery = before['partitions'][2]
        new_recovery = after['partitions'][2]
        old_start, new_start = old_recovery['firstLBA'] * 512, new_recovery['firstLBA'] * 512
        contents = self.image.read_bytes()
        self.assertEqual(contents[40 * 512:old_start], self.original[40 * 512:old_start])
        self.assertEqual(contents[new_start:new_start + new_recovery['bytes']],
                         self.original[old_start:old_start + old_recovery['bytes']])
        self.assertEqual(Path(result['backupDisk']).read_bytes(), self.original)
        self.assertEqual(struct.unpack_from('<I', contents, 458)[0], self.new_bytes // 512 - 1)
        expected = self.configuration
        expected['hardware']['_storageDevices'][0]['backing']['managedImage']['_0']['size'] = self.new_bytes
        self.assertEqual(plistlib.loads(self.config.read_bytes()), expected)
        self.assertEqual(self.host.read_json(self.receipt)['phase'], 'complete')

    def test_growth_smaller_than_recovery_handles_overlapping_copy(self):
        self.new_bytes = len(self.original) + 64 * 1024
        before = disk.inspect(self.image)
        result = self.grow()
        after = disk.inspect(self.image)
        recovery = after['partitions'][2]
        original = before['partitions'][2]
        start = recovery['firstLBA'] * 512
        old_start = original['firstLBA'] * 512
        self.assertEqual(self.image.read_bytes()[start:start + recovery['bytes']],
                         self.original[old_start:old_start + original['bytes']])
        self.assertEqual(result['recoverySHA256'], hashlib.sha256(self.original[old_start:old_start + original['bytes']]).hexdigest())

    def test_repeat_is_idempotent_without_recloning_or_rewriting_disk(self):
        first = self.grow()
        before = disk._file(self.image)
        second = self.grow()
        self.assertEqual(first, second)
        self.assertEqual(before, disk._file(self.image))
        self.assertEqual(self.clone.call_count, 1)

    def test_same_size_records_verified_noop(self):
        self.new_bytes = len(self.original)
        result = self.grow()
        self.assertFalse(result['resized'])
        self.assertEqual(result['gapBytes'], 0)
        self.assertIsNone(result['backupDisk'])
        self.assertEqual(self.image.read_bytes(), self.original)
        self.clone.assert_not_called()
        self.assertEqual(result, self.grow())

    def test_shrink_is_refused_without_changing_disk(self):
        self.new_bytes = len(self.original) - 4096
        with self.assertRaisesRegex(disk.DiskGrowthError, 'never shrinks'):
            self.grow()
        self.assertEqual(self.image.read_bytes(), self.original)
        self.assertFalse(self.receipt.exists())

    def test_encryption_rejection_preserves_original(self):
        self.unencrypted.side_effect = disk.DiskGrowthError('Encrypted APFS volume')
        with self.assertRaisesRegex(disk.DiskGrowthError, 'Encrypted'):
            self.grow()
        self.assertFalse(self.receipt.exists())
        self.clone.assert_not_called()
        self.assertEqual(self.image.read_bytes(), self.original)

    def test_running_vm_lock_prevents_any_growth(self):
        lock_path = self.vm / '.big-wallet-vm-run.lock'
        with open(lock_path, 'wb') as held:
            lock_path.chmod(0o600)
            fcntl.flock(held.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(disk.DiskGrowthError, 'still running'):
                self.grow()
        self.clone.assert_not_called()
        self.assertFalse(self.receipt.exists())

    def test_lsof_busy_vm_is_rejected_before_cloning(self):
        self.host.ensure_disk_idle.side_effect = RuntimeError('The VM disk is in use')
        with self.assertRaisesRegex(RuntimeError, 'in use'):
            self.grow()
        self.clone.assert_not_called()
        self.assertEqual(self.image.read_bytes(), self.original)

    def test_actual_free_space_must_cover_recovery_and_host_reserve(self):
        self.capacity.return_value = SimpleNamespace(free=4096)
        with self.assertRaisesRegex(disk.DiskGrowthError, 'actual free host space'):
            self.grow()
        self.assertFalse(self.receipt.exists())
        self.clone.assert_not_called()

    def test_unsupported_clone_fails_without_allocating_a_full_copy(self):
        self.clone.side_effect = self.host.RunnerError('requires a copy-on-write clone')
        with self.assertRaisesRegex(self.host.RunnerError, 'requires a copy-on-write clone'):
            self.grow()
        self.clone.assert_called_once()
        receipt = self.host.read_json(self.receipt)
        self.assertEqual(receipt['phase'], 'cloning')
        self.assertFalse((Path(receipt['workDirectory']) / 'Disk.expanded.img').exists())
        self.assertEqual(self.image.read_bytes(), self.original)

    def test_scratch_directory_sync_failure_leaves_cloning_receipt(self):
        sync = disk._fsync_directory
        def interrupt(path):
            if (path / 'Disk.expanded.img').exists():
                raise OSError('scratch sync failed')
            sync(path)
        with patch.object(disk, '_fsync_directory', side_effect=interrupt):
            with self.assertRaisesRegex(OSError, 'scratch sync failed'):
                self.grow()
        self.assertEqual(self.host.read_json(self.receipt)['phase'], 'cloning')
        self.assertEqual(self.image.read_bytes(), self.original)
        self.assertTrue(self.grow()['resized'])

    def test_gpt_crc_corruption_blocks_before_copy(self):
        contents = bytearray(self.original)
        contents[512 + 56] ^= 1
        self.image.write_bytes(contents)
        with self.assertRaisesRegex(disk.DiskGrowthError, 'header checksum'):
            self.grow()
        self.clone.assert_not_called()

    def test_backup_table_mismatch_blocks_before_copy(self):
        contents = bytearray(self.original)
        contents[-33 * 512 + 100] ^= 1
        self.image.write_bytes(contents)
        with self.assertRaisesRegex(disk.DiskGrowthError, 'tables do not agree'):
            self.grow()
        self.clone.assert_not_called()

    def test_wrong_protective_mbr_extent_blocks_before_copy(self):
        contents = bytearray(self.original)
        struct.pack_into('<I', contents, 458, len(contents) // 512 - 2)
        self.image.write_bytes(contents)
        with self.assertRaisesRegex(disk.DiskGrowthError, 'protective MBR'):
            self.grow()

    def test_resume_after_original_disk_is_backed_up(self):
        rename = os.rename
        interrupted = False
        def fail_after_backup(source, target):
            nonlocal interrupted
            rename(source, target)
            if Path(target).name == 'Disk.original.img' and not interrupted:
                interrupted = True
                raise OSError('injected interruption after backup')
        with patch.object(disk.os, 'rename', side_effect=fail_after_backup):
            with self.assertRaisesRegex(OSError, 'injected'):
                self.grow()
        self.assertFalse(self.image.exists())
        self.assertEqual(self.host.read_json(self.receipt)['phase'], 'publishing')
        result = self.grow()
        self.assertEqual(self.image.stat().st_size, self.new_bytes)
        self.assertEqual(Path(result['backupDisk']).read_bytes(), self.original)
        self.assertEqual(self.clone.call_count, 1)

    def test_resume_after_new_disk_is_published_before_config(self):
        rename = os.rename
        def fail_after_new_disk(source, target):
            rename(source, target)
            if Path(source).name == 'Disk.expanded.img':
                raise OSError('injected interruption after image publication')
        with patch.object(disk.os, 'rename', side_effect=fail_after_new_disk):
            with self.assertRaisesRegex(OSError, 'injected'):
                self.grow()
        self.assertEqual(self.image.stat().st_size, self.new_bytes)
        self.assertEqual(plistlib.loads(self.config.read_bytes()), self.configuration)
        result = self.grow()
        self.assertTrue(result['resized'])
        self.assertEqual(plistlib.loads(self.config.read_bytes())['hardware']['_storageDevices'][0]['backing']['managedImage']['_0']['size'], self.new_bytes)
        self.assertEqual(self.clone.call_count, 1)

    def test_resume_after_config_publication_completes_receipt(self):
        replace = os.replace
        def fail_after_config(source, target):
            replace(source, target)
            if Path(source).name == 'Config.expanded.plist':
                raise OSError('injected interruption after config publication')
        with patch.object(disk.os, 'replace', side_effect=fail_after_config):
            with self.assertRaisesRegex(OSError, 'injected'):
                self.grow()
        result = self.grow()
        self.assertTrue(result['resized'])
        self.assertEqual(self.host.read_json(self.receipt)['phase'], 'complete')

    def test_interrupted_expansion_reclones_only_owned_scratch(self):
        expand = disk._expand
        def interrupted(path, original, new_bytes):
            with open(path, 'r+b') as file:
                file.truncate(new_bytes)
            raise OSError('interrupted scratch expansion')
        with patch.object(disk, '_expand', side_effect=interrupted):
            with self.assertRaisesRegex(OSError, 'interrupted'):
                self.grow()
        self.assertEqual(self.image.read_bytes(), self.original)
        self.assertEqual(self.host.read_json(self.receipt)['phase'], 'cloning')
        result = self.grow()
        self.assertTrue(result['resized'])
        self.assertEqual(self.clone.call_count, 2)

    def test_resume_rejects_changed_target(self):
        self.grow()
        self.new_bytes += 4096
        with self.assertRaisesRegex(disk.DiskGrowthError, 'another VM, target'):
            self.grow()

    def test_idempotent_verification_rejects_replaced_recovery_data(self):
        self.grow()
        result = disk.inspect(self.image)
        with open(self.image, 'r+b') as file:
            file.seek(result['partitions'][2]['firstLBA'] * 512)
            file.write(b'changed')
        with self.assertRaisesRegex(disk.DiskGrowthError, 'identity changed'):
            self.grow()

    def test_unrelated_configuration_edit_prevents_publication(self):
        original_publish = disk._publish
        def edit_before_publish(*args):
            value = plistlib.loads(self.config.read_bytes())
            value['preservedPreference'] = 'user edit'
            self.config.write_bytes(plistlib.dumps(value))
            return original_publish(*args)
        with patch.object(disk, '_publish', side_effect=edit_before_publish):
            with self.assertRaisesRegex(disk.DiskGrowthError, 'configuration changed'):
                self.grow()
        self.assertEqual(self.image.read_bytes(), self.original)
        self.assertEqual(plistlib.loads(self.config.read_bytes())['preservedPreference'], 'user edit')

    def test_readonly_inspection_has_no_filesystem_side_effects(self):
        before = set(self.vm.iterdir())
        identity = disk._file(self.image)
        result = disk.inspect_disk(self.host, self.image)
        self.assertEqual(result['trailingPaddingSectors'], 7)
        self.assertFalse(any(key.startswith('_') for key in result))
        self.assertEqual(set(self.vm.iterdir()), before)
        self.assertEqual(disk._file(self.image), identity)

    def test_default_or_original_baseline_cannot_be_resized(self):
        unrelated = self.root / 'default-state'
        unrelated.mkdir(mode=0o700)
        candidate = unrelated / 'baseline.vbvm'
        candidate.mkdir(mode=0o700)
        (candidate / '.vbdata').mkdir(mode=0o700)
        with self.assertRaisesRegex(disk.DiskGrowthError, 'restricted to an isolated'):
            disk.grow(self.host, candidate, self.new_bytes, unrelated / 'growth.json')
        self.clone.assert_not_called()

    def test_mismatched_upgrade_record_cannot_authorize_growth(self):
        (self.state / 'baseline.json').write_text(json.dumps({'vmId': 'fixture', 'macosUpgradeID': 'macos-upgrade-other'}))
        with self.assertRaisesRegex(disk.DiskGrowthError, 'does not authorize'):
            self.grow()
        self.clone.assert_not_called()


if __name__ == '__main__':
    unittest.main()
