import os
from pathlib import Path
import stat
import struct
import uuid
import zlib


# Bounded metadata inspection, not a filesystem checker. On-disk structures:
# https://developer.apple.com/support/downloads/Apple-File-System-Reference.pdf
class PreflightError(Exception):
    pass


class _InvalidCheckpoint(PreflightError):
    pass


def _require(condition, message='The candidate disk has unsupported or malformed APFS metadata'):
    if not condition:
        raise PreflightError(message)


def _u32(data, offset):
    return struct.unpack_from('<I', data, offset)[0]


def _u64(data, offset):
    return struct.unpack_from('<Q', data, offset)[0]


def _object(data, object_type, *, oid=None, xid=None, subtype=0):
    if _u32(data, 24) & 0xffff == object_type & 0xffff:
        _require(_u32(data, 24) == object_type)
    first = second = 0
    for (word,) in struct.iter_unpack('<I', data[8:]):
        first += word
        second += first
    modulus = 0xffffffff
    check1 = modulus - (first + second) % modulus
    check2 = modulus - (first + check1) % modulus
    if (_u64(data, 0) != check1 | check2 << 32 or
            _u32(data, 24) & 0xffff != object_type & 0xffff or _u32(data, 28) != subtype or
            oid is not None and _u64(data, 8) != oid or
            _u64(data, 16) == 0 or xid is not None and _u64(data, 16) > xid):
        raise _InvalidCheckpoint('The candidate disk has invalid APFS object metadata')
    _require(_u32(data, 24) == object_type)


class _Image:
    def __init__(self, descriptor, size):
        self.descriptor = descriptor
        self.size = size
        self.remaining = 128 * 1024 * 1024

    def read(self, offset, size):
        _require(0 <= offset <= self.size and 0 < size <= self.size - offset)
        _require(size <= self.remaining, 'The candidate disk exceeds the APFS metadata inspection limit')
        self.remaining -= size
        data = os.pread(self.descriptor, size, offset)
        _require(len(data) == size)
        return data

    def partitions(self):
        sectors = [size for size in (512, 4096)
                   if self.size % size == 0 and self.size > size * 3 and self.read(size, 8) == b'EFI PART']
        _require(len(sectors) == 1, 'The candidate disk must be a supported raw GPT image')
        sector = sectors[0]
        last = self.size // sector - 1
        mbr = self.read(0, 512)
        _require(mbr[510:512] == b'\x55\xaa' and mbr[450] == 0xee and not any(mbr[462:510]))

        def table(lba, backup):
            header = self.read(lba * sector, sector)
            _require(header[:8] == b'EFI PART' and _u32(header, 8) == 0x10000 and _u32(header, 12) == 92)
            _require(not any(header[20:24]) and not any(header[92:]))
            checksum = bytearray(header[:92])
            checksum[16:20] = bytes(4)
            _require(zlib.crc32(checksum) == _u32(header, 16))
            _require(_u64(header, 24) == lba and _u64(header, 32) == backup)
            first, final = struct.unpack_from('<QQ', header, 40)
            entry_lba, count, length, crc = struct.unpack_from('<QIII', header, 72)
            _require(1 < first <= final < last and 0 < count <= 128 and length == 128)
            blocks = (count * length + sector - 1) // sector
            _require((lba == 1 and 1 < entry_lba and entry_lba + blocks <= first) or
                     (lba == last and final < entry_lba and entry_lba + blocks <= last))
            entries = self.read(entry_lba * sector, count * length)
            _require(zlib.crc32(entries) == crc)
            return header[40:72], entries, first, final

        identity, entries, first, final = table(1, last)
        backup_identity, backup_entries, _, _ = table(last, 1)
        _require(identity == backup_identity and entries == backup_entries)
        partitions = []
        for offset in range(0, len(entries), 128):
            entry = entries[offset:offset + 128]
            if not any(entry[:16]):
                _require(not any(entry))
                continue
            start, end = struct.unpack_from('<QQ', entry, 32)
            _require(first <= start <= end <= final and any(entry[16:32]))
            _require(str(uuid.UUID(bytes_le=entry[:16])) in (
                '7c3457ef-0000-11aa-aa11-00306543ecac',
                '69646961-6700-11aa-aa11-00306543ecac',
                '52637672-7900-11aa-aa11-00306543ecac'))
            partitions.append((start, end))
        _require(partitions)
        partitions.sort()
        _require(all(left[1] < right[0] for left, right in zip(partitions, partitions[1:])))
        return [(start * sector, (end - start + 1) * sector) for start, end in partitions]


class _Container:
    def __init__(self, image, offset, size):
        self.image, self.offset, self.size = image, offset, size
        header = image.read(offset, 4096)
        _require(header[32:36] == b'NXSB', 'Every candidate disk partition must contain supported APFS metadata')
        self.block_size = _u32(header, 36)
        _require(self.block_size in (4096, 8192, 16384, 32768, 65536))
        self.block_count = _u64(header, 40)
        _require(0 < self.block_count <= size // self.block_size)
        self.cache = {}
        self.zero = self.block(0)

    def block(self, address):
        _require(0 <= address < self.block_count)
        if address not in self.cache:
            self.cache[address] = self.image.read(self.offset + address * self.block_size, self.block_size)
        else:
            _require(self.block_size <= self.image.remaining, 'The candidate disk exceeds the APFS metadata inspection limit')
            self.image.remaining -= self.block_size
        return self.cache[address]

    def check(self):
        zero = self.zero
        _object(zero, 0x80000001, oid=1)
        count, base = _u32(zero, 104), _u64(zero, 112)
        _require(0 < count <= 32768 and 0 < base <= self.block_count - count)
        checkpoints = []
        for address in range(base, base + count):
            data = self.block(address)
            if not any(data):
                continue
            kind = _u32(data, 24)
            _require(kind in (0x80000001, 0x4000000c))
            if kind == 0x80000001:
                try:
                    _object(data, kind, oid=1)
                except _InvalidCheckpoint:
                    continue
                checkpoints.append((address, data))
        _require(checkpoints)
        newest = max(_u64(checkpoint, 16) for _, checkpoint in checkpoints)
        volumes = valid = 0
        for address, checkpoint in checkpoints:
            _require(checkpoint[32:48] == zero[32:48] and checkpoint[72:88] == zero[72:88])
            _require(_u32(checkpoint, 104) == count and _u64(checkpoint, 112) == base)
            _require(_u64(checkpoint, 56) == 0 and _u64(checkpoint, 64) == 2)
            maximum = _u32(checkpoint, 180)
            _require(0 < maximum <= 100)
            identifiers = struct.unpack_from('<100Q', checkpoint, 184)
            _require(not any(identifiers[maximum:]))
            wanted = {oid: index for index, oid in enumerate(identifiers) if oid}
            _require(len(wanted) == sum(bool(oid) for oid in identifiers))
            xid = _u64(checkpoint, 16)
            # Older checkpoints can reference reclaimed objects. Skip only unreadable
            # objects or branches; their readable encrypted siblings must still fail.
            older = xid < newest
            try:
                self.check_ephemeral(checkpoint, address, base, count, xid)
            except _InvalidCheckpoint:
                if not older:
                    raise
                continue
            valid += 1
            if not wanted:
                continue
            volumes += self.check_volumes(checkpoint, xid, wanted, older=older)
        _require(valid > 0)
        return volumes

    def check_ephemeral(self, checkpoint, address, base, count, xid):
        index, length = struct.unpack_from('<II', checkpoint, 136)
        _require(index < count and 2 <= length <= count and base + (index + length - 1) % count == address)
        for step in range(length - 1):
            physical = base + (index + step) % count
            mapping = self.block(physical)
            _object(mapping, 0x4000000c, oid=physical, xid=xid)
            if _u64(mapping, 16) != xid:
                raise _InvalidCheckpoint('The candidate disk has an incomplete APFS checkpoint')
            _require(_u32(mapping, 32) == int(step == length - 2))
            entries = _u32(mapping, 36)
            _require(entries <= (self.block_size - 40) // 40)
            for offset in range(40, 40 + entries * 40, 40):
                kind, subtype, size, _, _, oid, physical = struct.unpack_from('<IIIIQQQ', mapping, offset)
                _require(kind & 0xffff0000 == 0x80000000 and size % self.block_size == 0 and
                         0 < size <= 16 * 1024 * 1024 and physical < self.block_count and
                         size <= (self.block_count - physical) * self.block_size)
                data = self.image.read(self.offset + physical * self.block_size, size)
                _object(data, kind, oid=oid, xid=xid, subtype=subtype)

    def check_volumes(self, checkpoint, xid, wanted, *, older):
        mappings = self.mappings(_u64(checkpoint, 160), xid, wanted, older=older)
        volumes = 0
        for oid, index in wanted.items():
            if older and oid not in mappings:
                continue
            _require(oid in mappings)
            version, flags, size, address = mappings[oid]
            if older and flags & 1:
                _require(flags & ~3 == 0)
                continue
            _require(flags & ~2 == 0 and size == self.block_size)
            volume = self.block(address)
            try:
                _object(volume, 0xd, oid=oid, xid=xid)
            except _InvalidCheckpoint:
                if older:
                    continue
                raise
            _require(volume[32:36] == b'APSB' and _u32(volume, 36) == index and _u64(volume, 16) == version)
            _require(_u64(volume, 48) == 0 and _u64(volume, 56) & ~0x2b == 0)
            _require(_u64(volume, 264) & 0xb == 1,
                     'The candidate disk contains encrypted APFS volumes; disable FileVault before offline guest access')
            _require(not any(volume[160:176]) and _u64(volume, 976) == 0)
            volume_omap = self.block(_u64(volume, 128))
            try:
                _object(volume_omap, 0x4000000b, oid=_u64(volume, 128), xid=xid)
            except _InvalidCheckpoint:
                if older:
                    continue
                raise
            _require(_u32(volume_omap, 32) & ~0x10 == 0 and not any(volume_omap[72:88]))
            volumes += 1
        return volumes

    def mappings(self, address, xid, wanted, *, older):
        omap = self.block(address)
        try:
            _object(omap, 0x4000000b, oid=address, xid=xid)
        except _InvalidCheckpoint:
            if older:
                return {}
            raise
        _require(_u32(omap, 32) == 1 and _u32(omap, 40) == 0x40000002 and not any(omap[72:88]))
        result, visited = {}, set()

        def walk(address, expected_level=None, lower=None, upper=None):
            _require(address not in visited)
            visited.add(address)
            data = self.block(address)
            root = expected_level is None
            try:
                _object(data, 0x40000002 if root else 0x40000003, oid=address, xid=xid, subtype=11)
            except _InvalidCheckpoint:
                if older:
                    return
                raise
            flags, level, count, table_offset, table_length = struct.unpack_from('<HHIHH', data, 32)
            _require(level <= 8 and (root or level == expected_level))
            _require(flags == 4 | int(root) | (2 if level == 0 else 0))
            end = self.block_size - (40 if root else 0)
            if root:
                tree_flags, node_size, key_size, value_size = struct.unpack_from('<4I', data, end)
                _require(tree_flags & ~0x53 == 0 and tree_flags & 0x10 and
                         (node_size, key_size, value_size) == (self.block_size, 16, 16))
            table = 56 + table_offset
            keys = table + table_length
            _require(count > 0 and count * 4 <= table_length and 56 <= table <= keys <= end)
            entries, spans = [], []
            for index in range(count):
                key_offset, value_offset = struct.unpack_from('<HH', data, table + index * 4)
                key_start, value_start = keys + key_offset, end - value_offset
                value_size = 8 if level else 16
                _require(keys <= key_start <= end - 16 and keys <= value_start <= end - value_size)
                spans.extend(((key_start, key_start + 16), (value_start, value_start + value_size)))
                key = struct.unpack_from('<QQ', data, key_start)
                _require((not entries or entries[-1][0] < key) and (lower is None or lower <= key) and
                         (upper is None or key < upper))
                entries.append((key, value_start))
            spans.sort()
            _require(all(left[1] <= right[0] for left, right in zip(spans, spans[1:])))
            for index, (key, value_start) in enumerate(entries):
                if level:
                    walk(_u64(data, value_start), level - 1, key,
                         entries[index + 1][0] if index + 1 < len(entries) else upper)
                elif key[0] in wanted and key[1] <= xid:
                    flags, size, physical = struct.unpack_from('<IIQ', data, value_start)
                    if key[0] not in result or result[key[0]][0] < key[1]:
                        result[key[0]] = (key[1], flags, size, physical)

        walk(_u64(omap, 48))
        return result


def check_unencrypted_image(path):
    path = Path(path).absolute()
    _require(path.resolve() == path, 'The candidate disk must be a regular image without symlinks')
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(descriptor, 'rb') as file:
            before = os.fstat(file.fileno())
            _require(stat.S_ISREG(before.st_mode))
            image = _Image(file.fileno(), before.st_size)
            _require(sum(_Container(image, offset, size).check() for offset, size in image.partitions()) > 0)
            after = os.fstat(file.fileno())
            current = path.lstat()
            identity = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
            _require(identity(before) == identity(after) == identity(current),
                     'The candidate disk changed during APFS inspection')
    except (OSError, ValueError, struct.error):
        raise PreflightError('The candidate disk could not be safely inspected before attachment') from None
