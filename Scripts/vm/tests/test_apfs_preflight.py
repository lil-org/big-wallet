import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import uuid
import zlib


spec = importlib.util.spec_from_file_location('apfs_preflight', Path(__file__).resolve().parents[1] / 'apfs_preflight.py')
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)

BLOCK_SIZE = 4096
BLOCK_COUNT = 256
SECTOR_SIZE = 512
FIRST_PARTITION_LBA = 40
APFS_GUID = uuid.UUID('7c3457ef-0000-11aa-aa11-00306543ecac').bytes_le


def seal_object(block):
    block = bytearray(block)
    modulus = (1 << 32) - 1
    words = struct.unpack('<' + 'I' * ((len(block) - 8) // 4), block[8:])
    first = sum(words) % modulus
    second = sum((len(words) - index) * word for index, word in enumerate(words)) % modulus
    low = modulus - (first + second) % modulus
    high = modulus - (first + low) % modulus
    struct.pack_into('<II', block, 0, low, high)
    return bytes(block)


def object_block(oid, xid, kind, body, subtype=0):
    return seal_object((struct.pack('<QQQII', 0, oid, xid, kind, subtype) + body).ljust(BLOCK_SIZE, b'\0'))


# Field order follows Apple's APFS Reference: nx_superblock_t, apfs_superblock_t,
# omap_phys_t, and btree_node_phys_t (pages 27, 51, 44, and 123).
def container_superblock(xid, volume_count, omap=8, descriptor_index=0):
    oids = list(range(100, 100 + volume_count)) + [0] * (100 - volume_count)
    data_index = descriptor_index // 2
    body = struct.pack('<4sIQ3Q16s2Q2I2q6I3Q2I100Q',
                       b'NXSB', BLOCK_SIZE, BLOCK_COUNT, 0, 0, 2, bytes(range(16)),
                       1000, xid + 1, 4, 3, 1, 5,
                       (descriptor_index + 2) % 4, data_index + 1, descriptor_index, 2, data_index, 1,
                       512, omap, 0, 0, 100, *oids)
    return object_block(1, xid, 0x80000001, body)


def volume_superblock(oid, xid, index, flags=1, rolling_state=0, omap=64):
    body = struct.pack('<4sI7Q', b'APSB', index, *([0] * 7))
    body += struct.pack('<HHIIIHH', 5, 0, 0, 0, 0, 1, 0)
    body += struct.pack('<3I14Q', 0, 0, 0, omap, *([0] * 13))
    body += bytes(16) + struct.pack('<2Q', 0, flags)
    body += bytes(48 * 9) + bytes(256) + struct.pack('<IHH2Q', 0, 0, 0, 0, rolling_state)
    return object_block(oid, xid, 0x0d, body)


def omap_block(address, xid, tree, flags=1):
    return object_block(address, xid, 0x4000000b, struct.pack('<4I5Q', flags, 0, 0x40000002, 0, tree, 0, 0, 0, 0))


def omap_leaf(address, xid, mappings, root=True):
    count = len(mappings)
    table_size = (4 * count + 7) // 8 * 8
    values_end = BLOCK_SIZE - (40 if root else 0)
    keys_start = 56 + table_size
    body = bytearray(BLOCK_SIZE - 32)
    struct.pack_into('<HHI8H', body, 0, 6 | int(root), 0, count, 0, table_size,
                     16 * count, values_end - keys_start - 32 * count, 0xffff, 0, 0xffff, 0)
    for index, (oid, version, physical, flags) in enumerate(mappings):
        struct.pack_into('<HH', body, 24 + index * 4, index * 16, (index + 1) * 16)
        struct.pack_into('<QQ', body, keys_start - 32 + index * 16, oid, version)
        struct.pack_into('<IIq', body, values_end - 32 - (index + 1) * 16, flags, BLOCK_SIZE, physical)
    if root:
        struct.pack_into('<6I2Q', body, len(body) - 40, 0x10, BLOCK_SIZE, 16, 16, 16, 16, count, 1)
    return object_block(address, xid, 0x40000002 if root else 0x40000003, body, subtype=11)


def omap_index(address, xid, children):
    block = bytearray(omap_leaf(address, xid, [(oid, version, 0, 0) for oid, version, _ in children]))
    struct.pack_into('<HH', block, 32, 5, 1)
    keys_start = 56 + struct.unpack_from('<H', block, 42)[0]
    struct.pack_into('<H', block, 46, BLOCK_SIZE - 40 - keys_start - 24 * len(children))
    for index, (_, _, child) in enumerate(children):
        struct.pack_into('<H', block, 58 + index * 4, (index + 1) * 8)
        struct.pack_into('<Q', block, BLOCK_SIZE - 40 - (index + 1) * 8, child)
    struct.pack_into('<Q', block, BLOCK_SIZE - 8, 1 + len(children))
    return seal_object(block)


class ContainerFixture:
    def __init__(self, flags=(1,)):
        self.blocks = bytearray(BLOCK_SIZE * BLOCK_COUNT)
        self.add_checkpoint(10, flags, descriptor=2, omap=8)
        self.put(0, self.block(2))

    def put(self, number, contents):
        assert len(contents) == BLOCK_SIZE
        self.blocks[number * BLOCK_SIZE:(number + 1) * BLOCK_SIZE] = contents

    def block(self, number):
        return bytes(self.blocks[number * BLOCK_SIZE:(number + 1) * BLOCK_SIZE])

    def edit(self, number, offset, fmt, *values):
        block = bytearray(self.block(number))
        struct.pack_into(fmt, block, offset, *values)
        self.put(number, seal_object(block))

    def corrupt(self, number):
        block = bytearray(self.block(number))
        block[-1] ^= 1
        self.put(number, block)

    def add_checkpoint(self, xid, flags, descriptor, omap):
        ephemeral = 5 + (descriptor - 2) // 2
        mapping = struct.pack('<IIIIQQQ', 0x80000005, 0, BLOCK_SIZE, 0, 0, 512, ephemeral)
        self.put(descriptor - 1, object_block(descriptor - 1, xid, 0x4000000c, struct.pack('<II', 1, 1) + mapping))
        self.put(ephemeral, object_block(512, xid, 0x80000005, struct.pack('<4I', BLOCK_SIZE, 0, 0, 0)))
        self.put(descriptor, container_superblock(xid, len(flags), omap, descriptor - 2))
        self.put(omap, omap_block(omap, xid, omap + 1))
        mappings = [(100 + index, xid, omap + 2 + index, 0) for index in range(len(flags))]
        self.put(omap + 1, omap_leaf(omap + 1, xid, mappings))
        for index, volume_flags in enumerate(flags):
            volume_omap = 32 + 4 * omap + 2 * index
            self.put(omap + 2 + index, volume_superblock(100 + index, xid, index, volume_flags, omap=volume_omap))
            self.put(volume_omap, omap_block(volume_omap, xid, volume_omap + 1, flags=0))
            self.put(volume_omap + 1, omap_leaf(volume_omap + 1, xid, []))


def gpt_image(*containers):
    entries = bytearray(128 * 128)
    next_lba = FIRST_PARTITION_LBA
    partitions = []
    for index, container in enumerate(containers):
        sectors = len(container.blocks) // SECTOR_SIZE
        entry = struct.pack('<16s16sQQQ72s', APFS_GUID, uuid.UUID(int=index + 1).bytes_le,
                            next_lba, next_lba + sectors - 1, 0, b'')
        entries[index * 128:(index + 1) * 128] = entry
        partitions.append((next_lba * SECTOR_SIZE, container.blocks))
        next_lba += sectors
    backup_entries_lba = next_lba
    last_lba = backup_entries_lba + len(entries) // SECTOR_SIZE
    image = bytearray((last_lba + 1) * SECTOR_SIZE)
    struct.pack_into('<B3sB3sII', image, 446, 0, bytes(3), 0xee, b'\xff' * 3, 1, last_lba)
    image[510:512] = b'\x55\xaa'

    def header(current, backup, table):
        result = bytearray(struct.pack('<8s4I4Q16sQ3I', b'EFI PART', 0x10000, 92, 0, 0,
                                      current, backup, 34, backup_entries_lba - 1,
                                      uuid.UUID(int=1234).bytes_le, table, 128, 128, zlib.crc32(entries)))
        struct.pack_into('<I', result, 16, zlib.crc32(result))
        return result.ljust(SECTOR_SIZE, b'\0')

    image[SECTOR_SIZE:2 * SECTOR_SIZE] = header(1, last_lba, 2)
    image[last_lba * SECTOR_SIZE:] = header(last_lba, 1, backup_entries_lba)
    image[2 * SECTOR_SIZE:2 * SECTOR_SIZE + len(entries)] = entries
    image[backup_entries_lba * SECTOR_SIZE:backup_entries_lba * SECTOR_SIZE + len(entries)] = entries
    for offset, contents in partitions:
        image[offset:offset + len(contents)] = contents
    return image


def edit_partition_entries(image, index, offset, fmt, *values):
    for header in (SECTOR_SIZE, len(image) - SECTOR_SIZE):
        table = struct.unpack_from('<Q', image, header + 72)[0] * SECTOR_SIZE
        struct.pack_into(fmt, image, table + 128 * index + offset, *values)
        struct.pack_into('<I', image, header + 88, zlib.crc32(image[table:table + 128 * 128]))
        struct.pack_into('<I', image, header + 16, 0)
        struct.pack_into('<I', image, header + 16, zlib.crc32(image[header:header + 92]))


class APFSPreflightTests(unittest.TestCase):
    def check_image(self, image, rejected=False):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / 'Disk.img'
            path.write_bytes(image)
            before = path.read_bytes()
            with patch('subprocess.run', side_effect=AssertionError('Preflight must not invoke disk utilities')), \
                    patch('subprocess.Popen', side_effect=AssertionError('Preflight must not start processes')):
                if rejected:
                    with self.assertRaisesRegex(preflight.PreflightError, rejected if isinstance(rejected, str) else '.'):
                        preflight.check_unencrypted_image(path)
                else:
                    preflight.check_unencrypted_image(path)
            self.assertEqual(path.read_bytes(), before)

    def test_unencrypted_single_and_multiple_volume_images_are_read_only(self):
        for volumes in ((1,), (1, 1, 1), (0x101, 0x201)):
            with self.subTest(volumes=volumes):
                self.check_image(gpt_image(ContainerFixture(volumes)))

    def test_every_partition_is_inspected(self):
        self.check_image(gpt_image(ContainerFixture(), ContainerFixture()))
        self.check_image(gpt_image(ContainerFixture(), ContainerFixture((0,))), rejected='encrypted APFS')

    def test_unencrypted_isc_main_and_recovery_partition_layout_passes(self):
        main = ContainerFixture((1, 1))
        main.edit(10, 56, '<Q', 0x2b)
        main.edit(11, 56, '<Q', 0x9)
        image = gpt_image(ContainerFixture(), main, ContainerFixture())
        edit_partition_entries(image, 0, 0, '<16s', uuid.UUID('69646961-6700-11aa-aa11-00306543ecac').bytes_le)
        edit_partition_entries(image, 2, 0, '<16s', uuid.UUID('52637672-7900-11aa-aa11-00306543ecac').bytes_le)
        self.check_image(image)

    def test_any_encrypted_volume_rejects_the_container(self):
        for volumes in ((0, 1), (1, 0), (1, 3), (1, 8), (1, 9)):
            with self.subTest(volumes=volumes):
                self.check_image(gpt_image(ContainerFixture(volumes)), rejected='encrypted APFS')

    def test_newer_encrypted_checkpoint_is_not_masked_by_unencrypted_block_zero(self):
        container = ContainerFixture()
        container.add_checkpoint(20, (0,), descriptor=4, omap=12)
        self.check_image(gpt_image(container), rejected='encrypted APFS')

    def test_incomplete_old_checkpoint_is_ignored_only_after_valid_checkpoint_is_checked(self):
        for corrupt_block in (1, 5):
            for newest_flags in (0, 1):
                with self.subTest(corrupt_block=corrupt_block, newest_flags=newest_flags):
                    container = ContainerFixture()
                    container.add_checkpoint(20, (newest_flags,), descriptor=4, omap=12)
                    container.corrupt(corrupt_block)
                    self.check_image(gpt_image(container), rejected='encrypted APFS' if newest_flags == 0 else False)

    def test_newest_unencrypted_checkpoint_cannot_hide_older_valid_encryption(self):
        container = ContainerFixture((0,))
        container.add_checkpoint(20, (1,), descriptor=4, omap=12)
        container.put(0, container.block(4))
        self.check_image(gpt_image(container), rejected='encrypted APFS')

    def test_invalid_old_objects_are_skipped_without_hiding_new_encryption(self):
        for corrupt_block in (8, 9, 10, 64):
            for corruption in ('checksum', 'identity', 'newer_transaction'):
                for newest_flags in (0, 1):
                    with self.subTest(block=corrupt_block, corruption=corruption, newest_flags=newest_flags):
                        container = ContainerFixture()
                        container.add_checkpoint(20, (newest_flags,), descriptor=4, omap=12)
                        if corruption == 'checksum':
                            container.corrupt(corrupt_block)
                        else:
                            container.edit(corrupt_block, 8 if corruption == 'identity' else 16, '<Q', 200)
                        self.check_image(gpt_image(container), rejected='encrypted APFS' if newest_flags == 0 else False)

    def test_invalid_old_volume_cannot_hide_a_valid_encrypted_sibling(self):
        for corruption in ('volume', 'volume_omap', 'missing_mapping', 'deleted_mapping'):
            with self.subTest(corruption=corruption):
                container = ContainerFixture((1, 0))
                container.add_checkpoint(20, (1, 1), descriptor=4, omap=12)
                if corruption in ('volume', 'volume_omap'):
                    container.corrupt(10 if corruption == 'volume' else 64)
                else:
                    mappings = [(101, 10, 11, 0)]
                    if corruption == 'deleted_mapping':
                        mappings.insert(0, (100, 10, 10, 1))
                    container.put(9, omap_leaf(9, 10, mappings))
                self.check_image(gpt_image(container), rejected='encrypted APFS')

    def test_invalid_old_tree_branch_cannot_hide_a_valid_encrypted_sibling_branch(self):
        container = ContainerFixture((1, 0))
        container.put(9, omap_index(9, 10, [(100, 10, 20), (101, 10, 21)]))
        container.put(20, omap_leaf(20, 10, [(100, 10, 10, 0)], root=False))
        container.put(21, omap_leaf(21, 10, [(101, 10, 11, 0)], root=False))
        container.add_checkpoint(20, (1, 1), descriptor=4, omap=12)
        container.corrupt(20)
        self.check_image(gpt_image(container), rejected='encrypted APFS')

    def test_newest_checkpoint_objects_cannot_fall_back_to_an_older_checkpoint(self):
        for corrupt_block in (3, 6, 12, 13, 14, 80):
            with self.subTest(corrupt_block=corrupt_block):
                container = ContainerFixture()
                container.add_checkpoint(20, (1,), descriptor=4, omap=12)
                container.corrupt(corrupt_block)
                self.check_image(gpt_image(container), rejected=True)

    def test_invalid_newest_tree_branch_rejects_despite_valid_sibling_and_old_checkpoint(self):
        container = ContainerFixture((1, 1))
        container.add_checkpoint(20, (1, 1), descriptor=4, omap=12)
        container.put(13, omap_index(13, 20, [(100, 20, 20), (101, 20, 21)]))
        container.put(20, omap_leaf(20, 20, [(100, 20, 14, 0)], root=False))
        container.put(21, omap_leaf(21, 20, [(101, 20, 15, 0)], root=False))
        container.corrupt(20)
        self.check_image(gpt_image(container), rejected=True)

    def test_checkpoint_mappings_must_refer_to_matching_ephemeral_objects(self):
        container = ContainerFixture()
        container.edit(5, 16, '<Q', 9)
        self.check_image(gpt_image(container))
        for offset, fmt, value in ((8, '<Q', 513), (16, '<Q', 11), (24, '<I', 0x40000005)):
            with self.subTest(offset=offset):
                container = ContainerFixture()
                container.edit(5, offset, fmt, value)
                self.check_image(gpt_image(container), rejected=True)

    def test_checkpoint_descriptor_ring_can_wrap(self):
        container = ContainerFixture()
        container.edit(2, 128, '<I', 1)
        container.edit(2, 136, '<I', 3)
        container.edit(1, 8, '<Q', 4)
        checkpoint = container.block(2)
        container.put(4, container.block(1))
        container.put(1, checkpoint)
        container.put(2, bytes(BLOCK_SIZE))
        self.check_image(gpt_image(container))

    def test_latest_mapping_for_volume_must_be_checked(self):
        container = ContainerFixture()
        container.put(10, volume_superblock(100, 9, 0))
        container.put(11, volume_superblock(100, 10, 0, flags=0))
        container.put(9, omap_leaf(9, 10, [(100, 9, 10, 0), (100, 10, 11, 0)]))
        self.check_image(gpt_image(container), rejected='encrypted APFS')

    def test_internal_object_map_nodes_reach_every_volume(self):
        container = ContainerFixture((1, 1))
        container.put(9, omap_index(9, 10, [(100, 10, 20), (101, 10, 21)]))
        container.put(20, omap_leaf(20, 10, [(100, 10, 10, 0)], root=False))
        container.put(21, omap_leaf(21, 10, [(101, 10, 11, 0)], root=False))
        self.check_image(gpt_image(container))
        container.edit(11, 264, '<Q', 0)
        self.check_image(gpt_image(container), rejected='encrypted APFS')

    def test_cyclic_internal_object_map_rejects(self):
        container = ContainerFixture()
        container.put(9, omap_index(9, 10, [(100, 10, 9)]))
        self.check_image(gpt_image(container), rejected=True)

    def test_encryption_roll_and_omap_encryption_flags_reject(self):
        for number, offset, fmt, value in ((10, 976, '<Q', 22), (8, 32, '<I', 3), (8, 32, '<I', 5),
                                           (8, 32, '<I', 9), (10, 160, '<Q', 4), (64, 32, '<I', 2)):
            with self.subTest(number=number, offset=offset, value=value):
                container = ContainerFixture()
                container.edit(number, offset, fmt, value)
                self.check_image(gpt_image(container), rejected=True)

    def test_encrypted_deleted_and_headerless_volume_mappings_reject(self):
        for flags in (1, 4, 8, 16):
            with self.subTest(flags=flags):
                container = ContainerFixture()
                container.put(9, omap_leaf(9, 10, [(100, 10, 10, flags)]))
                self.check_image(gpt_image(container), rejected=True)

    def test_corrupt_gpt_and_apfs_checksums_fail_closed(self):
        original = gpt_image(ContainerFixture())
        offsets = [SECTOR_SIZE + 24, len(original) - SECTOR_SIZE + 24,
                   2 * SECTOR_SIZE + 32, len(original) - 33 * SECTOR_SIZE + 32]
        offsets += [FIRST_PARTITION_LBA * SECTOR_SIZE + number * BLOCK_SIZE + 64 for number in (0, 1, 2, 5, 8, 9, 10)]
        for offset in offsets:
            with self.subTest(offset=offset):
                image = bytearray(original)
                image[offset] ^= 1
                self.check_image(image, rejected=True)

    def test_truncated_image_and_non_gpt_bytes_fail_closed(self):
        original = gpt_image(ContainerFixture())
        for image in (b'', b'not a disk image', original[:-1], original[:FIRST_PARTITION_LBA * SECTOR_SIZE + BLOCK_SIZE]):
            with self.subTest(length=len(image)):
                self.check_image(image, rejected=True)

    def test_checksummed_partition_bounds_overlap_and_unknown_type_reject(self):
        edits = ((0, 32, '<Q', 33), (0, 40, '<Q', 1 << 40),
                 (1, 32, '<Q', FIRST_PARTITION_LBA + 1), (0, 0, '<16s', bytes([1]) * 16))
        for index, offset, fmt, value in edits:
            with self.subTest(index=index, offset=offset, value=value):
                image = gpt_image(ContainerFixture(), ContainerFixture())
                edit_partition_entries(image, index, offset, fmt, value)
                self.check_image(image, rejected=True)

    def test_checksummed_backup_partition_array_must_match_primary(self):
        image = gpt_image(ContainerFixture())
        header = len(image) - SECTOR_SIZE
        table = struct.unpack_from('<Q', image, header + 72)[0] * SECTOR_SIZE
        image[table + 16] ^= 1
        struct.pack_into('<I', image, header + 88, zlib.crc32(image[table:table + 128 * 128]))
        struct.pack_into('<I', image, header + 16, 0)
        struct.pack_into('<I', image, header + 16, zlib.crc32(image[header:header + 92]))
        self.check_image(image, rejected=True)

    def test_out_of_bounds_metadata_and_tree_offsets_fail_closed(self):
        edits = ((0, 40, '<Q', BLOCK_COUNT + 1), (0, 112, '<q', BLOCK_COUNT),
                 (2, 160, '<Q', BLOCK_COUNT), (8, 48, '<Q', BLOCK_COUNT),
                 (9, 56, '<H', 0xffff), (9, 58, '<H', 0xffff))
        for number, offset, fmt, value in edits:
            with self.subTest(number=number, offset=offset):
                container = ContainerFixture()
                container.edit(number, offset, fmt, value)
                self.check_image(gpt_image(container), rejected=True)
        container = ContainerFixture()
        container.put(9, omap_leaf(9, 10, [(100, 10, BLOCK_COUNT, 0)]))
        self.check_image(gpt_image(container), rejected=True)

    def test_unsupported_descriptor_tree_and_volume_features_fail_closed(self):
        edits = ((0, 104, '<I', 0x80000004), (8, 40, '<I', 2),
                 (9, 32, '<H', 3), (9, 24, '<I', 0x50000002),
                 (9, BLOCK_SIZE - 40, '<I', 0x90), (10, 48, '<Q', 1),
                 (10, 56, '<Q', 1 << 63), (10, 56, '<Q', 4), (10, 56, '<Q', 0x10),
                 (10, 56, '<Q', 0x40))
        for number, offset, fmt, value in edits:
            with self.subTest(number=number, offset=offset, value=value):
                container = ContainerFixture()
                container.edit(number, offset, fmt, value)
                self.check_image(gpt_image(container), rejected=True)

    def test_missing_volume_mapping_and_mismatched_volume_identity_reject(self):
        for number, offset, fmt, value in ((9, 64, '<Q', 101), (10, 8, '<Q', 101),
                                           (10, 16, '<Q', 9), (10, 36, '<I', 1)):
            with self.subTest(number=number, offset=offset):
                container = ContainerFixture()
                container.edit(number, offset, fmt, value)
                self.check_image(gpt_image(container), rejected=True)


if __name__ == '__main__':
    unittest.main()
