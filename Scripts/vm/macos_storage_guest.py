import errno
import fcntl
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile


MIN_FREE_BYTES = 20 * 1024 ** 3
DISKUTIL = '/usr/sbin/diskutil'
GUID_PATTERN = r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}'
DEVICE_PATTERN = r'disk[0-9]+(?:s[0-9]+)*'


def require(helpers, condition, reason):
    if not condition:
        raise helpers.UpdateError(reason)


def integer(helpers, value, *, positive=False):
    require(helpers, type(value) is int and value >= (1 if positive else 0), 'guest_storage_invalid_size')
    return value


def guid(helpers, value):
    require(helpers, isinstance(value, str) and re.fullmatch(GUID_PATTERN, value) is not None,
            'guest_storage_invalid_partition_identity')
    return value.upper()


def device(helpers, value):
    require(helpers, isinstance(value, str) and re.fullmatch(DEVICE_PATTERN, value) is not None,
            'guest_storage_invalid_device_identity')
    return value


def validate_growth(helpers, growth):
    require(helpers, isinstance(growth, dict), 'guest_storage_growth_receipt_invalid')
    numbers = ('oldBytes', 'newBytes', 'sectorBytes', 'mainPartitionBytes', 'expectedContainerBytes', 'gapBytes',
               'mainFirstLBA', 'mainLastLBA', 'recoveryFirstLBA', 'recoveryLastLBA', 'recoveryBytes', 'trailingPaddingSectors')
    values = {key: integer(helpers, growth.get(key)) for key in numbers}
    values.update({key: guid(helpers, growth.get(key)) for key in ('diskGUID', 'mainPartitionGUID', 'recoveryPartitionGUID')})
    old, new, sector = values['oldBytes'], values['newBytes'], values['sectorBytes']
    require(helpers, sector == 512 and 0 < old <= new and old % 4096 == new % 4096 == 0 and
            values['mainPartitionGUID'] != values['recoveryPartitionGUID'], 'guest_storage_growth_receipt_invalid')
    main_first, main_last = values['mainFirstLBA'], values['mainLastLBA']
    recovery_first, recovery_last = values['recoveryFirstLBA'], values['recoveryLastLBA']
    require(helpers, 34 <= main_first <= main_last < recovery_first <= recovery_last and
            main_first % 8 == recovery_first % 8 == 0 and
            (main_last - main_first + 1) * sector == values['mainPartitionBytes'] and
            (recovery_last - recovery_first + 1) * sector == values['recoveryBytes'] and
            (recovery_first - main_first) * sector == values['expectedContainerBytes'] and
            values['expectedContainerBytes'] - values['mainPartitionBytes'] == values['gapBytes'] == new - old and
            new // sector - 34 - recovery_last == values['trailingPaddingSectors'], 'guest_storage_growth_receipt_invalid')
    return values


def plist(helpers, arguments):
    try:
        value = plistlib.loads(helpers.run([DISKUTIL, *arguments], timeout=20, limit=2 * 1024 * 1024))
    except (ValueError, plistlib.InvalidFileException):
        raise helpers.UpdateError('guest_storage_inventory_invalid') from None
    require(helpers, isinstance(value, dict), 'guest_storage_inventory_invalid')
    return value


def collection(helpers, value):
    require(helpers, isinstance(value, list) and value and all(isinstance(item, dict) for item in value),
            'guest_storage_inventory_invalid')
    return value


def one(helpers, values, reason):
    require(helpers, len(values) == 1, reason)
    return values[0]


def partition(helpers, entry, whole):
    identifier = device(helpers, entry.get('DeviceIdentifier'))
    info = plist(helpers, ['info', '-plist', identifier])
    require(helpers, info.get('DeviceIdentifier') == identifier and info.get('ParentWholeDisk') == whole and
            info.get('WholeDisk') is False and info.get('PartitionMapPartition') is True and
            info.get('Content') == entry.get('Content'), 'guest_storage_partition_mapping_changed')
    identity = guid(helpers, info.get('DiskUUID'))
    size = integer(helpers, info.get('TotalSize'), positive=True)
    offset = integer(helpers, info.get('PartitionMapPartitionOffset'), positive=True)
    require(helpers, entry.get('Size') == size and
            (entry.get('DiskUUID') is None or guid(helpers, entry['DiskUUID']) == identity),
            'guest_storage_partition_inventory_mismatch')
    return {'device': identifier, 'uuid': identity, 'bytes': size, 'offset': offset, 'content': info['Content']}


def container(helpers, value):
    reference = device(helpers, value.get('ContainerReference'))
    stores = collection(helpers, value.get('PhysicalStores'))
    require(helpers, len(stores) == 1 and value.get('Fusion', False) is False, 'guest_storage_single_physical_store_required')
    store = stores[0]
    identifier = device(helpers, store.get('DeviceIdentifier'))
    identity = guid(helpers, store.get('DiskUUID'))
    size = integer(helpers, store.get('Size'), positive=True)
    capacity = integer(helpers, value.get('CapacityCeiling'), positive=True)
    free = integer(helpers, value.get('CapacityFree'))
    require(helpers, size == capacity and free <= capacity, 'guest_storage_container_capacity_mismatch')
    volumes = collection(helpers, value.get('Volumes'))
    require(helpers, all(volume.get('Encryption') is False and volume.get('FileVault') is False and
                        volume.get('Locked', False) is False and volume.get('CryptoMigrationOn', False) is False for volume in volumes),
            'guest_storage_unencrypted_unlocked_container_required')
    volume_ids = [guid(helpers, volume.get('APFSVolumeUUID')) for volume in volumes]
    require(helpers, len(set(volume_ids)) == len(volume_ids), 'guest_storage_volume_identity_ambiguous')
    return {'device': reference, 'uuid': guid(helpers, value.get('APFSContainerUUID')), 'store': identifier,
            'storeUUID': identity, 'capacityBytes': capacity, 'freeBytes': free, 'volumeUUIDs': sorted(volume_ids)}


def container_for_store(helpers, values, identity):
    matches = []
    for value in values:
        stores = collection(helpers, value.get('PhysicalStores'))
        if any(str(store.get('DiskUUID', '')).upper() == identity for store in stores):
            matches.append(value)
    return one(helpers, matches, 'guest_storage_partition_container_ambiguous')


def inspect(helpers, growth):
    root = plist(helpers, ['info', '-plist', '/'])
    require(helpers, root.get('MountPoint') == '/' and root.get('FilesystemType') == 'apfs',
            'guest_storage_root_apfs_required')
    reference = device(helpers, root.get('APFSContainerReference'))
    require(helpers, root.get('ParentWholeDisk') == reference, 'guest_storage_root_container_mismatch')
    inventory = plist(helpers, ['apfs', 'list', '-plist'])
    containers = collection(helpers, inventory.get('Containers'))
    main_value = one(helpers, [item for item in containers if item.get('ContainerReference') == reference],
                     'guest_storage_root_container_ambiguous')
    main_container = container(helpers, main_value)
    require(helpers, main_container['storeUUID'] == growth['mainPartitionGUID'], 'guest_storage_root_partition_mismatch')
    require(helpers, container_for_store(helpers, containers, growth['mainPartitionGUID']) == main_value,
            'guest_storage_root_partition_ambiguous')
    root_uuid = guid(helpers, root.get('DiskUUID'))
    root_stores = collection(helpers, root.get('APFSPhysicalStores'))
    require(helpers, len(root_stores) == 1 and root_stores[0].get('APFSPhysicalStore') == main_container['store'] and
            root.get('FileVault') is False and root.get('APFSContainerSize') == main_container['capacityBytes'],
            'guest_storage_root_volume_mismatch')
    main_info = plist(helpers, ['info', '-plist', main_container['store']])
    whole = device(helpers, main_info.get('ParentWholeDisk'))
    require(helpers, re.fullmatch(r'disk[0-9]+', whole) is not None, 'guest_storage_physical_disk_required')
    layout = plist(helpers, ['list', '-plist'])
    disks = collection(helpers, layout.get('AllDisksAndPartitions'))
    disk = one(helpers, [item for item in disks if item.get('DeviceIdentifier') == whole],
               'guest_storage_physical_disk_ambiguous')
    require(helpers, disk.get('Content') == 'GUID_partition_scheme' and disk.get('Size') == growth['newBytes'],
            'guest_storage_grown_disk_size_mismatch')
    entries = collection(helpers, disk.get('Partitions'))
    require(helpers, len(entries) == 3 and sorted(item.get('Content', '') for item in entries) ==
            sorted(['Apple_APFS_ISC', 'Apple_APFS', 'Apple_APFS_Recovery']), 'guest_storage_partition_layout_unsupported')
    mapped = [partition(helpers, item, whole) for item in entries]
    main = one(helpers, [item for item in mapped if item['content'] == 'Apple_APFS'], 'guest_storage_main_partition_ambiguous')
    recovery = one(helpers, [item for item in mapped if item['content'] == 'Apple_APFS_Recovery'],
                   'guest_storage_recovery_partition_ambiguous')
    isc = one(helpers, [item for item in mapped if item['content'] == 'Apple_APFS_ISC'], 'guest_storage_isc_partition_ambiguous')
    require(helpers, main['device'] == main_container['store'] and main['uuid'] == growth['mainPartitionGUID'] and
            main['offset'] == growth['mainFirstLBA'] * growth['sectorBytes'] and
            main['bytes'] == main_container['capacityBytes'] and
            main['bytes'] in (growth['mainPartitionBytes'], growth['expectedContainerBytes']),
            'guest_storage_main_partition_bounds_mismatch')
    require(helpers, recovery['uuid'] == growth['recoveryPartitionGUID'] and
            recovery['offset'] == growth['recoveryFirstLBA'] * growth['sectorBytes'] and
            recovery['bytes'] == growth['recoveryBytes'] and
            isc['offset'] + isc['bytes'] <= main['offset'] and
            main['offset'] + main['bytes'] <= recovery['offset'], 'guest_storage_recovery_partition_bounds_mismatch')
    recovery_value = container_for_store(helpers, containers, growth['recoveryPartitionGUID'])
    recovery_container = container(helpers, recovery_value)
    require(helpers, recovery_container['device'] != reference and recovery_container['store'] == recovery['device'] and
            recovery_container['capacityBytes'] == recovery['bytes'], 'guest_storage_recovery_container_mismatch')
    isc_container = container(helpers, container_for_store(helpers, containers, isc['uuid']))
    require(helpers, isc_container['store'] == isc['device'] and isc_container['capacityBytes'] == isc['bytes'],
            'guest_storage_isc_container_mismatch')
    available = os.statvfs('/')
    available_bytes = integer(helpers, available.f_bavail * available.f_frsize)
    return {'root': {'device': device(helpers, root.get('DeviceIdentifier')), 'volumeUUID': root_uuid, 'container': reference},
            'disk': {'device': whole, 'bytes': disk['Size']}, 'main': main, 'recovery': recovery, 'isc': isc,
            'mainContainer': main_container, 'recoveryContainer': recovery_container, 'iscContainer': isc_container,
            'availableBytes': available_bytes}


def verify_after(helpers, before, after, growth):
    require(helpers, after['main']['bytes'] == growth['expectedContainerBytes'] and
            after['mainContainer']['capacityBytes'] == growth['expectedContainerBytes'], 'guest_storage_container_did_not_grow')
    require(helpers, before['root']['volumeUUID'] == after['root']['volumeUUID'] and before['disk']['bytes'] == after['disk']['bytes'],
            'guest_storage_root_identity_changed')
    for name in ('recovery', 'isc'):
        for key in ('uuid', 'bytes', 'offset', 'content'):
            require(helpers, before[name][key] == after[name][key], 'guest_storage_unrelated_partition_changed')
    for key in ('uuid', 'storeUUID', 'volumeUUIDs'):
        require(helpers, before['mainContainer'][key] == after['mainContainer'][key], 'guest_storage_container_identity_changed')
    for key in ('uuid', 'storeUUID', 'capacityBytes', 'volumeUUIDs'):
        require(helpers, before['recoveryContainer'][key] == after['recoveryContainer'][key], 'guest_storage_recovery_container_changed')
        require(helpers, before['iscContainer'][key] == after['iscContainer'][key], 'guest_storage_isc_container_changed')


def free_bytes(inventory):
    return min(inventory['availableBytes'], inventory['mainContainer']['freeBytes'])


def resize(helpers, reference, lock):
    try:
        with tempfile.TemporaryFile() as output:
            result = subprocess.run([DISKUTIL, 'apfs', 'resizeContainer', reference, '0'], stdin=subprocess.DEVNULL,
                stdout=output, stderr=subprocess.STDOUT, timeout=300, env=helpers.ENVIRONMENT, pass_fds=(lock,))
            output.seek(0)
            captured = output.read(1024 * 1024 + 1)
    except (OSError, subprocess.TimeoutExpired):
        raise helpers.UpdateError('guest_storage_resize_failed') from None
    require(helpers, result.returncode == 0 and len(captured) <= 1024 * 1024, 'guest_storage_resize_failed')


def grow_locked(request, growth, helpers, observation, receipt_path, lock):
    existing = helpers.read_json(receipt_path, missing=True)
    if existing is not None:
        require(helpers, existing.get('version') == 1 and existing.get('request') == request and
                existing.get('growth') == growth and existing.get('phase') in ('growing', 'grown') and
                isinstance(existing.get('before'), dict), 'guest_storage_receipt_mismatch')
    current = inspect(helpers, growth)
    already_grown = current['main']['bytes'] == growth['expectedContainerBytes']
    before = existing['before'] if existing is not None else current
    if not already_grown:
        require(helpers, existing is None, 'guest_storage_previous_growth_not_verified')
        require(helpers, free_bytes(current) + growth['gapBytes'] >= MIN_FREE_BYTES,
                'guest_storage_insufficient_growth_increment')
        helpers.write_json(receipt_path, {'version': 1, 'request': request, 'growth': growth, 'phase': 'growing',
            'before': before, 'startedAt': helpers.timestamp()})
        resize(helpers, current['mainContainer']['device'], lock)
    after = inspect(helpers, growth)
    final = helpers.attest(request)
    require(helpers, final == observation, 'guest_storage_boot_identity_changed')
    for name in ('root', 'disk', 'recovery', 'isc'):
        require(helpers, current[name] == after[name], 'guest_storage_live_mapping_changed')
    for key in ('device', 'uuid', 'store', 'storeUUID', 'volumeUUIDs'):
        require(helpers, current['mainContainer'][key] == after['mainContainer'][key], 'guest_storage_live_mapping_changed')
    verify_after(helpers, before, after, growth)
    helpers.write_json(receipt_path, {'version': 1, 'request': request, 'growth': growth, 'phase': 'grown',
        'before': before, 'after': after, 'verifiedAt': helpers.timestamp()})
    storage = {'status': 'grown', 'upgradeID': request['upgradeID'], 'vmId': request['vmId'], 'growth': growth,
               'alreadyGrown': already_grown, 'expectedContainerBytes': growth['expectedContainerBytes'],
               'before': before, 'after': after}
    result = {**final, 'safeToStop': True, 'storage': storage}
    if free_bytes(after) < MIN_FREE_BYTES:
        return {**result, 'status': 'blocked', 'reason': 'guest_storage_insufficient_free_space_after_growth'}
    return {**result, 'status': 'ready'}


def grow_container(request, growth, helpers):
    request = helpers.validate_request(request)
    observation = helpers.attest(request)
    directory = Path(helpers.UPGRADE_DIRECTORY)
    operation = directory / request['upgradeID']
    owner = helpers.protected(directory.parent, directory=True)
    descriptor = os.open(directory.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        require(helpers, os.path.samestat(owner, os.fstat(descriptor)), 'guest_storage_lock_invalid')
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {'status': 'installing', **observation, 'safeToStop': False, 'storage': {'status': 'growing'}}
        receipt_path = operation / 'storage.json'
        try:
            directory.mkdir(mode=0o700, exist_ok=True)
            helpers.protected(directory, directory=True, private=True)
            operation.mkdir(mode=0o700, exist_ok=True)
            helpers.protected(operation, directory=True, private=True)
            try:
                return grow_locked(request, validate_growth(helpers, growth), helpers, observation, receipt_path, descriptor)
            except helpers.UpdateError as error:
                if helpers.read_json(receipt_path, missing=True) is not None:
                    raise
                reason = str(error)
        except OSError as error:
            if error.errno != errno.ENOSPC or helpers.read_json(receipt_path, missing=True) is not None:
                raise
            reason = 'guest_storage_receipt_out_of_space'
        return {**observation, 'status': 'blocked', 'safeToStop': True, 'reason': reason,
                'storage': {'status': 'preflight-rejected', 'request': request, 'growth': growth}}
    finally:
        os.close(descriptor)
