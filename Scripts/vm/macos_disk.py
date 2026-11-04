import copy
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import struct
import uuid
import zlib


SECTOR_BYTES = 512
ENTRY_BYTES = 128
ENTRY_COUNT = 128
TABLE_BYTES = ENTRY_BYTES * ENTRY_COUNT
MAX_BYTES = 8 * 1024 ** 4
COPY_BYTES = 4 * 1024 ** 2
PARTITION_TYPES = ('69646961-6700-11aa-aa11-00306543ecac',
                   '7c3457ef-0000-11aa-aa11-00306543ecac',
                   '52637672-7900-11aa-aa11-00306543ecac')


class DiskGrowthError(RuntimeError):
    pass


def _require(value, message):
    if not value:
        raise DiskGrowthError(message)


def _directory(path, *, private=False):
    path = Path(path)
    metadata = path.lstat()
    _require(path.resolve() == path and stat.S_ISDIR(metadata.st_mode) and metadata.st_uid == os.getuid() and
             metadata.st_mode & (0o077 if private else 0o022) == 0, 'Disk growth requires an owned canonical directory')
    return [metadata.st_dev, metadata.st_ino]


def _file(path):
    path = Path(path)
    metadata = path.lstat()
    _require(path.resolve() == path and stat.S_ISREG(metadata.st_mode) and metadata.st_uid == os.getuid() and
             metadata.st_nlink == 1 and metadata.st_mode & 0o022 == 0,
             'Disk growth requires an owned regular file without links')
    return {'fileID': [metadata.st_dev, metadata.st_ino], 'bytes': metadata.st_size,
            'modifiedNS': metadata.st_mtime_ns}


def _read(path, limit=1024 * 1024):
    _file(path)
    with open(path, 'rb') as file:
        data = file.read(limit + 1)
    _require(len(data) <= limit, 'Disk growth metadata exceeds its size limit')
    return data


def _digest(data):
    return hashlib.sha256(data).hexdigest()


def _pread(descriptor, offset, length):
    data = os.pread(descriptor, length, offset)
    _require(len(data) == length, 'The disk image ended inside its declared metadata')
    return data


def _pwrite(descriptor, offset, data):
    view = memoryview(data)
    while view:
        count = os.pwrite(descriptor, view, offset)
        _require(count > 0, 'The expanded disk could not be written completely')
        offset += count
        view = view[count:]


def _fsync_directory(path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _header(data, own, alternate, total_sectors):
    _require(len(data) == SECTOR_BYTES and data[:8] == b'EFI PART', 'The disk requires a valid GPT header')
    revision, length, crc, reserved = struct.unpack_from('<IIII', data, 8)
    _require(revision == 0x10000 and length == 92 and reserved == 0 and not any(data[92:]),
             'The GPT header format is unsupported')
    checksum = bytearray(data[:92])
    checksum[16:20] = bytes(4)
    _require(zlib.crc32(checksum) == crc, 'The GPT header checksum is invalid')
    current, backup, first, last = struct.unpack_from('<QQQQ', data, 24)
    entries_lba, count, entry_size, entries_crc = struct.unpack_from('<QIII', data, 72)
    _require((current, backup, first, last, count, entry_size) ==
             (own, alternate, 34, total_sectors - 34, ENTRY_COUNT, ENTRY_BYTES) and
             entries_lba == (2 if own == 1 else total_sectors - 33) and any(data[56:72]),
             'The GPT geometry is unsupported for isolated boot-disk growth')
    return {'entriesLBA': entries_lba, 'entriesCRC': entries_crc, 'diskGUID': str(uuid.UUID(bytes_le=data[56:72])),
            'firstUsableLBA': first, 'lastUsableLBA': last}


def inspect(path):
    path = Path(path)
    before = _file(path)
    size = before['bytes']
    _require(512 * 128 <= size <= MAX_BYTES and size % 4096 == 0, 'The raw boot disk has an unsupported size')
    sectors = size // SECTOR_BYTES
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        mbr = _pread(descriptor, 0, SECTOR_BYTES)
        _require(mbr[510:512] == b'\x55\xaa' and mbr[446] == 0 and mbr[450] == 0xee and
                 struct.unpack_from('<II', mbr, 454) == (1, min(sectors - 1, 0xffffffff)) and not any(mbr[462:510]),
                 'The protective MBR is invalid or contains other partitions')
        primary = _pread(descriptor, SECTOR_BYTES, SECTOR_BYTES)
        backup = _pread(descriptor, (sectors - 1) * SECTOR_BYTES, SECTOR_BYTES)
        header = _header(primary, 1, sectors - 1, sectors)
        secondary = _header(backup, sectors - 1, 1, sectors)
        entries = _pread(descriptor, header['entriesLBA'] * SECTOR_BYTES, TABLE_BYTES)
        other = _pread(descriptor, secondary['entriesLBA'] * SECTOR_BYTES, TABLE_BYTES)
        _require(entries == other and zlib.crc32(entries) == header['entriesCRC'] == secondary['entriesCRC'] and
                 primary[40:72] == backup[40:72], 'The primary and backup GPT tables do not agree')
        partitions = []
        for index in range(ENTRY_COUNT):
            entry = entries[index * ENTRY_BYTES:(index + 1) * ENTRY_BYTES]
            if not any(entry[:16]):
                _require(not any(entry), 'An unused GPT entry contains unexpected metadata')
                continue
            start, end, attributes = struct.unpack_from('<QQQ', entry, 32)
            kind = str(uuid.UUID(bytes_le=entry[:16]))
            _require(len(partitions) < 3 and kind == PARTITION_TYPES[len(partitions)] and
                     header['firstUsableLBA'] <= start <= end <= header['lastUsableLBA'] and
                     start % 8 == 0 and (end + 1) % 8 == 0 and any(entry[16:32]),
                     'Disk growth requires the known ISC, main APFS, and Recovery GPT layout')
            partitions.append({'index': index, 'typeGUID': kind, 'guid': str(uuid.UUID(bytes_le=entry[16:32])),
                               'firstLBA': start, 'lastLBA': end, 'bytes': (end - start + 1) * SECTOR_BYTES,
                               'attributes': attributes})
        _require(len(partitions) == 3 and partitions[0]['lastLBA'] < partitions[1]['firstLBA'] and
                 partitions[1]['lastLBA'] < partitions[2]['firstLBA'] and
                 0 <= header['lastUsableLBA'] - partitions[2]['lastLBA'] <= 7,
                 'The disk has unsupported partition overlap or Recovery padding')
        _require(_file(path) == before, 'The disk changed during GPT inspection')
        metadata = mbr + primary + entries + backup
        return {'bytes': size, 'sectorBytes': SECTOR_BYTES, 'diskGUID': header['diskGUID'],
                'firstUsableLBA': header['firstUsableLBA'], 'lastUsableLBA': header['lastUsableLBA'],
                'trailingPaddingSectors': header['lastUsableLBA'] - partitions[2]['lastLBA'],
                'partitions': partitions, 'gptSHA256': _digest(metadata),
                '_mbr': mbr, '_primary': primary, '_backup': backup, '_entries': entries}
    finally:
        os.close(descriptor)


def _public_layout(layout):
    return {key: value for key, value in layout.items() if not key.startswith('_')}


def inspect_disk(host, path, *, growth_target=None):
    try:
        layout = inspect(path)
        if growth_target is not None:
            _capacity(host, path.parent.parent, layout, growth_target)
        return _public_layout(layout)
    except DiskGrowthError as error:
        raise host.RunnerError(str(error)) from None


def _unencrypted(path):
    specification = importlib.util.spec_from_file_location('vm_growth_apfs_preflight', Path(__file__).with_name('apfs_preflight.py'))
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    try:
        module.check_unencrypted_image(path)
    except module.PreflightError as error:
        raise DiskGrowthError(str(error)) from None


def _range_hash(path, offset, length):
    before = _file(path)
    _require(0 <= offset <= before['bytes'] and 0 < length <= before['bytes'] - offset,
             'The Recovery hash range is outside the image')
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    digest = hashlib.sha256()
    try:
        for position in range(0, length, COPY_BYTES):
            digest.update(_pread(descriptor, offset + position, min(COPY_BYTES, length - position)))
    finally:
        os.close(descriptor)
    _require(_file(path) == before, 'The disk changed while Recovery was verified')
    return digest.hexdigest()


def _updated_header(original, *, own, alternate, last_usable, entries_lba, entries_crc):
    data = bytearray(original)
    struct.pack_into('<QQ', data, 24, own, alternate)
    struct.pack_into('<Q', data, 48, last_usable)
    struct.pack_into('<Q', data, 72, entries_lba)
    struct.pack_into('<I', data, 88, entries_crc)
    struct.pack_into('<I', data, 16, 0)
    struct.pack_into('<I', data, 16, zlib.crc32(data[:92]))
    return data


def _expand(path, original, new_bytes):
    _require(new_bytes > original['bytes'] and new_bytes <= MAX_BYTES and new_bytes % 4096 == 0,
             'Only aligned boot-disk growth is supported')
    delta = (new_bytes - original['bytes']) // SECTOR_BYTES
    recovery = original['partitions'][2]
    old_start = recovery['firstLBA'] * SECTOR_BYTES
    new_start = old_start + delta * SECTOR_BYTES
    entries = bytearray(original['_entries'])
    offset = recovery['index'] * ENTRY_BYTES
    struct.pack_into('<QQ', entries, offset + 32, recovery['firstLBA'] + delta, recovery['lastLBA'] + delta)
    sectors = new_bytes // SECTOR_BYTES
    crc = zlib.crc32(entries)
    primary = _updated_header(original['_primary'], own=1, alternate=sectors - 1,
        last_usable=original['lastUsableLBA'] + delta, entries_lba=2, entries_crc=crc)
    backup = _updated_header(original['_backup'], own=sectors - 1, alternate=1,
        last_usable=original['lastUsableLBA'] + delta, entries_lba=sectors - 33, entries_crc=crc)
    mbr = bytearray(original['_mbr'])
    struct.pack_into('<I', mbr, 458, min(sectors - 1, 0xffffffff))
    descriptor = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
    try:
        os.ftruncate(descriptor, new_bytes)
        remaining = recovery['bytes']
        while remaining:
            length = min(COPY_BYTES, remaining)
            position = remaining - length
            _pwrite(descriptor, new_start + position, _pread(descriptor, old_start + position, length))
            remaining -= length
        _pwrite(descriptor, (sectors - 33) * SECTOR_BYTES, entries)
        _pwrite(descriptor, (sectors - 1) * SECTOR_BYTES, backup)
        _pwrite(descriptor, 2 * SECTOR_BYTES, entries)
        _pwrite(descriptor, SECTOR_BYTES, primary)
        _pwrite(descriptor, 0, mbr)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    result = inspect(path)
    _require(result['diskGUID'] == original['diskGUID'] and
             result['partitions'][:2] == original['partitions'][:2] and
             result['partitions'][2] == {**recovery, 'firstLBA': recovery['firstLBA'] + delta,
                                          'lastLBA': recovery['lastLBA'] + delta} and
             result['trailingPaddingSectors'] == original['trailingPaddingSectors'],
             'The expanded GPT did not preserve the original partition identities')
    return result


def _configuration(path, disk_bytes):
    contents = _read(path)
    try:
        value = plistlib.loads(contents)
        device = value['hardware']['_storageDevices'][0]
        image = device['backing']['managedImage']['_0']
        _require(value.get('systemType') == 'mac' and device.get('isBootVolume') is True and
                 device.get('isSavedStateClone', False) is False and image.get('filename') == 'Disk' and
                 image.get('format') == 0 and image.get('size') == disk_bytes,
                 'The boot image configuration does not match the stopped raw disk')
    except (ValueError, KeyError, TypeError, plistlib.InvalidFileException):
        raise DiskGrowthError('The boot image configuration is invalid') from None
    return contents, value


def _new_file(path, contents, mode):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    with os.fdopen(descriptor, 'wb') as file:
        file.write(contents)
        file.flush()
        os.fsync(file.fileno())
        os.fchmod(file.fileno(), mode)
    _fsync_directory(path.parent)


def _capacity(host, directory, layout, new_bytes):
    environment = host.read_json(host.TOOLS / 'environment.json')
    reserve = environment['minimumHostFreeBytes']
    needed = layout['partitions'][2]['bytes'] if new_bytes > layout['bytes'] else 0
    _require(type(reserve) is int and reserve >= 0 and shutil.disk_usage(directory).free >= reserve + needed,
             'Boot-disk growth requires actual free host space for its Recovery copy plus the configured reserve')


def _validate_receipt(receipt, vm, new_bytes, parent, upgrade_id):
    _require(isinstance(receipt, dict) and receipt.get('version') == 1 and receipt.get('vm') == str(vm) and
             receipt.get('upgradeID') == upgrade_id and
             receipt.get('newBytes') == new_bytes and receipt.get('vmFileID') == _directory(vm) and
             receipt.get('phase') in ('cloning', 'prepared', 'publishing', 'complete'),
             'The disk-growth receipt belongs to another VM, target, or unsupported phase')
    work = Path(receipt.get('workDirectory', ''))
    _require(work.parent == parent and re.fullmatch(r'system-disk-growth-[a-f0-9]{32}', work.name) and
             _directory(work, private=True) == receipt.get('workFileID'),
             'The disk-growth work directory changed')
    allowed = {'Disk.expanded.img', 'Disk.original.img', 'Config.original.plist', 'Config.expanded.plist'}
    _require({path.name for path in work.iterdir()} <= allowed, 'Unexpected files appeared in disk-growth state')
    for path in work.iterdir():
        _file(path)
    _require(_digest(_read(work / 'Config.original.plist')) == receipt.get('originalConfigSHA256'),
             'The saved original disk configuration changed')
    return work


def _source(receipt, disk, work):
    source = work / 'Disk.original.img' if (work / 'Disk.original.img').exists() else disk
    _require(_file(source) == receipt.get('originalDisk'), 'The original boot disk changed during growth')
    layout = inspect(source)
    _require(_public_layout(layout) == receipt.get('originalLayout'), 'The original GPT changed during growth')
    return source, layout


def _verify_expanded(receipt, path):
    _require(_file(path) == receipt.get('expandedDisk'), 'The expanded boot disk identity changed')
    layout = inspect(path)
    _require(_public_layout(layout) == receipt.get('expandedLayout'), 'The expanded GPT changed before publication')
    recovery = layout['partitions'][2]
    _require(_range_hash(path, recovery['firstLBA'] * SECTOR_BYTES, recovery['bytes']) == receipt['recoverySHA256'],
             'The relocated Recovery content does not match the original')
    return layout


def _publish(host, vm, receipt_path, receipt, work):
    disk, config = vm / 'Disk.img', vm / '.vbdata/Config.plist'
    source, original = _source(receipt, disk, work)
    old_recovery = original['partitions'][2]
    _require(_range_hash(source, old_recovery['firstLBA'] * SECTOR_BYTES, old_recovery['bytes']) == receipt['recoverySHA256'],
             'The original Recovery content changed')
    expanded = work / 'Disk.expanded.img'
    published = disk.exists() and _file(disk) == receipt['expandedDisk']
    _verify_expanded(receipt, disk if published else expanded)
    current_config = _digest(_read(config))
    _require(current_config in (receipt['originalConfigSHA256'], receipt['expandedConfigSHA256']),
             'The VM configuration changed during disk publication')
    host.ensure_disk_idle(vm)
    receipt['phase'] = 'publishing'
    host.atomic_json(receipt_path, receipt)
    _fsync_directory(receipt_path.parent)
    backup = work / 'Disk.original.img'
    if not published:
        if disk.exists():
            _require(_file(disk) == receipt['originalDisk'] and not backup.exists(),
                     'The original disk backup is ambiguous; both images were preserved')
            os.rename(disk, backup)
            _fsync_directory(vm)
            _fsync_directory(work)
        _require(_file(backup) == receipt['originalDisk'], 'The original disk backup changed')
        os.rename(expanded, disk)
        _fsync_directory(vm)
        _fsync_directory(work)
    if current_config != receipt['expandedConfigSHA256']:
        replacement = work / 'Config.expanded.plist'
        _require(_digest(_read(replacement)) == receipt['expandedConfigSHA256'], 'The expanded disk configuration changed')
        os.replace(replacement, config)
        _fsync_directory(config.parent)
        _fsync_directory(work)
    _verify_expanded(receipt, disk)
    _require(_digest(_read(config)) == receipt['expandedConfigSHA256'], 'The new disk configuration was not published')
    host.validate_vm(vm)
    receipt['phase'] = 'complete'
    host.atomic_json(receipt_path, receipt)
    _fsync_directory(receipt_path.parent)


def _result(receipt, receipt_path):
    original, expanded = receipt['originalLayout'], receipt['expandedLayout']
    main, recovery = original['partitions'][1], expanded['partitions'][2]
    return {'resized': receipt['newBytes'] != receipt['oldBytes'], 'oldBytes': receipt['oldBytes'],
            'newBytes': receipt['newBytes'], 'mainPartitionGUID': main['guid'],
            'recoveryPartitionGUID': recovery['guid'], 'diskGUID': original['diskGUID'],
            'sectorBytes': SECTOR_BYTES, 'mainFirstLBA': main['firstLBA'], 'mainLastLBA': main['lastLBA'],
            'recoveryFirstLBA': recovery['firstLBA'], 'recoveryLastLBA': recovery['lastLBA'],
            'recoveryBytes': recovery['bytes'],
            'mainPartitionBytes': main['bytes'],
            'expectedContainerBytes': (recovery['firstLBA'] - main['firstLBA']) * SECTOR_BYTES,
            'gapBytes': (recovery['firstLBA'] - main['lastLBA'] - 1) * SECTOR_BYTES,
            'trailingPaddingSectors': expanded['trailingPaddingSectors'],
            'recoverySHA256': receipt['recoverySHA256'], 'receipt': str(receipt_path),
            'backupDisk': str(Path(receipt['workDirectory']) / 'Disk.original.img') if receipt['newBytes'] != receipt['oldBytes'] else None}


def grow(host, vm, new_bytes, receipt_path):
    vm, receipt_path = Path(vm), Path(receipt_path)
    _require(type(new_bytes) is int and 0 < new_bytes <= MAX_BYTES and new_bytes % 4096 == 0,
             'The requested boot-disk size must be a positive, aligned size at most 8 TiB')
    identity = _directory(vm)
    _directory(vm / '.vbdata')
    _directory(receipt_path.parent, private=True)
    _require(receipt_path.is_absolute() and receipt_path.parent.stat().st_dev == vm.stat().st_dev and
             receipt_path.parent == vm.parent, 'The disk-growth receipt must be in the isolated VM state on the same filesystem')
    upgrade_id = vm.parent.parent.name
    _require(vm.name == 'baseline.vbvm' and vm.parent.name == 'state' and
             re.fullmatch(r'macos-upgrade-[A-Za-z0-9_-]{1,100}', upgrade_id),
             'Boot-disk growth is restricted to an isolated macOS upgrade candidate')
    try:
        baseline = json.loads(_read(vm.parent / 'baseline.json'))
    except (ValueError, TypeError):
        raise DiskGrowthError('The isolated baseline record is invalid') from None
    _require(isinstance(baseline, dict) and baseline.get('macosUpgradeID') == upgrade_id and
             isinstance(baseline.get('vmId'), str) and baseline['vmId'] and
             baseline.get('sourceVM') != str(vm), 'The isolated baseline record does not authorize this growth')
    lock_path = vm / '.big-wallet-vm-run.lock'
    descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        lock = os.fstat(descriptor)
        _require(stat.S_ISREG(lock.st_mode) and lock.st_uid == os.getuid() and lock.st_nlink == 1 and lock.st_mode & 0o077 == 0,
                 'The upgrade VM ownership lock is invalid')
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise DiskGrowthError('The upgrade VM is still running or owned by another operation') from None
        host.ensure_disk_idle(vm)
        disk, config = vm / 'Disk.img', vm / '.vbdata/Config.plist'
        if receipt_path.exists() or receipt_path.is_symlink():
            _file(receipt_path)
            receipt = host.read_json(receipt_path)
            work = _validate_receipt(receipt, vm, new_bytes, receipt_path.parent, upgrade_id)
        else:
            host.validate_vm(vm)
            original_disk = _file(disk)
            original = inspect(disk)
            _require(new_bytes >= original['bytes'], 'Boot-disk growth never shrinks an existing image')
            _require(original['partitions'][0]['lastLBA'] + 1 == original['partitions'][1]['firstLBA'] and
                     original['partitions'][1]['lastLBA'] + 1 == original['partitions'][2]['firstLBA'],
                     'A new growth transaction requires the original contiguous Apple partition layout')
            _unencrypted(disk)
            config_bytes, configuration = _configuration(config, original['bytes'])
            recovery = original['partitions'][2]
            recovery_hash = _range_hash(disk, recovery['firstLBA'] * SECTOR_BYTES, recovery['bytes'])
            _capacity(host, vm.parent, original, new_bytes)
            work = host.private_directory(receipt_path.parent / ('system-disk-growth-' + uuid.uuid4().hex))
            _new_file(work / 'Config.original.plist', config_bytes, stat.S_IMODE(config.stat().st_mode))
            replacement = copy.deepcopy(configuration)
            replacement['hardware']['_storageDevices'][0]['backing']['managedImage']['_0']['size'] = new_bytes
            new_config = plistlib.dumps(replacement, fmt=plistlib.FMT_BINARY if config_bytes.startswith(b'bplist00') else plistlib.FMT_XML)
            if new_bytes == original['bytes']:
                new_config = config_bytes
            _new_file(work / 'Config.expanded.plist', new_config, stat.S_IMODE(config.stat().st_mode))
            receipt = {'version': 1, 'upgradeID': upgrade_id, 'vm': str(vm), 'vmFileID': identity, 'phase': 'cloning',
                'oldBytes': original['bytes'], 'newBytes': new_bytes, 'workDirectory': str(work),
                'workFileID': _directory(work, private=True), 'originalDisk': original_disk,
                'originalLayout': _public_layout(original), 'originalConfigSHA256': _digest(config_bytes),
                'expandedConfigSHA256': _digest(new_config), 'recoverySHA256': recovery_hash}
            host.atomic_json(receipt_path, receipt)
            _fsync_directory(receipt_path.parent)
        if receipt['newBytes'] == receipt['oldBytes']:
            source, original = _source(receipt, disk, work)
            _require(source == disk and _digest(_read(config)) == receipt['originalConfigSHA256'],
                     'The unchanged boot disk or configuration was replaced')
            receipt.update({'phase': 'complete', 'expandedDisk': receipt['originalDisk'],
                            'expandedLayout': receipt['originalLayout']})
            _verify_expanded(receipt, disk)
            host.atomic_json(receipt_path, receipt)
            return _result(receipt, receipt_path)
        if receipt['phase'] == 'cloning':
            source, original = _source(receipt, disk, work)
            _require(source == disk, 'A partial clone cannot replace an already-backed-up disk')
            _require(_digest(_read(config)) == receipt['originalConfigSHA256'], 'The original VM configuration changed')
            _unencrypted(source)
            _capacity(host, vm.parent, original, new_bytes)
            expanded = work / 'Disk.expanded.img'
            if expanded.exists():
                _file(expanded)
                expanded.unlink()
            host.clone_cow(source, expanded)
            _require(_file(source) == receipt['originalDisk'], 'The source disk changed during cloning')
            _require(_public_layout(inspect(expanded)) == receipt['originalLayout'], 'The cloned GPT differs from its source')
            target_layout = _expand(expanded, original, new_bytes)
            _unencrypted(expanded)
            receipt.update({'phase': 'prepared', 'expandedDisk': _file(expanded),
                            'expandedLayout': _public_layout(target_layout)})
            _verify_expanded(receipt, expanded)
            _fsync_directory(work)
            host.atomic_json(receipt_path, receipt)
            _fsync_directory(receipt_path.parent)
        if receipt['phase'] != 'complete':
            _publish(host, vm, receipt_path, receipt, work)
        else:
            _source(receipt, disk, work)
            _verify_expanded(receipt, disk)
            _require(_digest(_read(config)) == receipt['expandedConfigSHA256'], 'The published VM configuration changed')
        return _result(receipt, receipt_path)
    finally:
        os.close(descriptor)
