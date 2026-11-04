import datetime
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import select
import stat
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace


IDENTITY_DIRECTORY = Path('/Library/Application Support/BigWalletTestVM')
UPGRADE_DIRECTORY = IDENTITY_DIRECTORY / 'macOS-upgrades'
RESULT_PREFIX = 'BIG_WALLET_MACOS_UPDATE='
INPUT_MARKER = b'BIG_WALLET_MACOS_UPDATE_INPUT_V1'
MAX_JSON = 65536
MAX_DIAGNOSTICS = 32768
MAX_UPDATE_OUTPUT = 65536
MIN_SYSTEM_FREE_BYTES = 20 * 1024 ** 3
ENVIRONMENT = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'C', 'LC_ALL': 'C',
               'DEVELOPER_DIR': '/Applications/Xcode.app/Contents/Developer'}


class UpdateError(RuntimeError):
    pass


class LiveOSProbeError(UpdateError):
    pass


def error_envelope(error):
    reason = str(error) if isinstance(error, UpdateError) else ''
    if not re.fullmatch(r'[a-z][a-z0-9_]{0,127}', reason):
        reason = 'guest_update_request_rejected'
    result = {'status': 'failed', 'reason': reason}
    if isinstance(error, LiveOSProbeError) and reason in ('guest_update_probe_unavailable', 'guest_update_probe_failed'):
        result['scope'] = 'live-os-probe'
    return result


def timestamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def attempt_identity(value):
    if (not isinstance(value, dict) or any(not isinstance(value.get(key), str) for key in ('vmId', 'consoleUser', 'upgradeID')) or
            not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', str(value.get('vmId', ''))) or
            not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', str(value.get('consoleUser', ''))) or
            not re.fullmatch(r'macos-upgrade-[A-Za-z0-9_-]{1,100}', str(value.get('upgradeID', '')))):
        raise UpdateError('invalid_upgrade_request')
    target = value.get('target')
    if (not isinstance(target, dict) or set(target) != {'version', 'buildVersion'} or
            any(not isinstance(item, str) for item in target.values()) or
            not re.fullmatch(r'[1-9][0-9]*\.[0-9]+(?:\.[0-9]+)?', str(target.get('version', ''))) or
            not re.fullmatch(r'[0-9]{2}[A-Z][0-9]{1,6}', str(target.get('buildVersion', '')))):
        raise UpdateError('invalid_stable_macos_target')
    return {key: value[key] for key in ('vmId', 'consoleUser', 'upgradeID', 'target')}


def validate_request(value):
    identity = attempt_identity(value)
    nonce = value.get('upgradeNonce')
    if set(value) != {*identity, 'upgradeNonce'} or not isinstance(nonce, str) or not re.fullmatch(r'[a-f0-9]{64}', nonce):
        raise UpdateError('invalid_upgrade_request')
    return value


def protected(path, *, directory=False, private=False):
    path = Path(path)
    if not path.is_absolute() or path.resolve() != path:
        raise UpdateError('unprotected_guest_upgrade_path')
    metadata = path.lstat()
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if (not expected(metadata.st_mode) or metadata.st_uid != 0 or
            metadata.st_mode & (0o077 if private else 0o022)):
        raise UpdateError('unprotected_guest_upgrade_path')
    return metadata


def read_json(path, *, missing=False):
    try:
        protected(path)
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        if missing:
            return None
        raise UpdateError('guest_upgrade_identity_missing') from None
    with os.fdopen(descriptor, 'rb') as file:
        metadata = os.fstat(file.fileno())
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o022 or
                not 0 < metadata.st_size <= MAX_JSON):
            raise UpdateError('unprotected_guest_upgrade_record')
        contents = file.read(MAX_JSON + 1)
    try:
        value = json.loads(contents)
    except (UnicodeError, ValueError):
        raise UpdateError('invalid_guest_upgrade_record') from None
    if not isinstance(value, dict):
        raise UpdateError('invalid_guest_upgrade_record')
    return value


def write_bytes(path, data):
    protected(path.parent, directory=True, private=True)
    if path.exists() or path.is_symlink():
        protected(path, private=True)
    descriptor, name = tempfile.mkstemp(prefix='.update-', dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, 'wb') as file:
            file.write(data)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def write_json(path, value):
    write_bytes(path, (json.dumps(value, sort_keys=True) + '\n').encode())


def run(command, *, timeout=20, limit=1024 * 1024, accepted=(0,)):
    try:
        with tempfile.TemporaryFile() as output:
            result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=output,
                                    stderr=subprocess.DEVNULL, timeout=timeout, env=ENVIRONMENT)
            output.seek(0)
            contents = output.read(limit + 1)
    except (OSError, subprocess.TimeoutExpired):
        raise UpdateError('guest_update_probe_unavailable') from None
    if result.returncode not in accepted or len(contents) > limit:
        raise UpdateError('guest_update_probe_failed')
    return contents


def text(command, **options):
    try:
        return run(command, **options).decode('utf-8').strip()
    except UnicodeError:
        raise UpdateError('invalid_guest_update_probe') from None


def live_os_probe(command):
    try:
        return text(command)
    except UpdateError as error:
        if str(error) in ('guest_update_probe_unavailable', 'guest_update_probe_failed'):
            raise LiveOSProbeError(str(error)) from None
        raise


def attest(request):
    if os.geteuid() != 0 or not text(['/usr/sbin/sysctl', '-n', 'hw.model']).startswith('VirtualMac'):
        raise UpdateError('guest_virtual_machine_root_required')
    if text(['/usr/bin/uname', '-m']) != 'arm64':
        raise UpdateError('guest_apple_silicon_required')
    protected(IDENTITY_DIRECTORY, directory=True)
    identity_path = IDENTITY_DIRECTORY / 'identity.json'
    identity = read_json(identity_path)
    if (identity.get('version') != 1 or identity.get('vmId') != request['vmId'] or
            identity.get('consoleUser') != request['consoleUser']):
        raise UpdateError('guest_upgrade_identity_mismatch')
    enrollment = IDENTITY_DIRECTORY / ('enrollment-' + request['upgradeID'] + '-' + request['upgradeNonce'])
    try:
        bound = os.path.samestat(protected(enrollment), protected(identity_path))
    except FileNotFoundError:
        bound = False
    if not bound:
        raise UpdateError('guest_upgrade_candidate_binding_mismatch')
    try:
        account = pwd.getpwnam(request['consoleUser'])
    except KeyError:
        raise UpdateError('guest_upgrade_account_missing') from None
    if account.pw_uid < 500:
        raise UpdateError('guest_upgrade_account_invalid')
    actual = {'version': live_os_probe(['/usr/bin/sw_vers', '-productVersion']),
              'buildVersion': live_os_probe(['/usr/bin/sw_vers', '-buildVersion'])}
    boot = live_os_probe(['/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid'])
    if (not re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', actual['version']) or
            not re.fullmatch(r'[0-9]{2}[A-Z][0-9]{1,6}[a-z]?', actual['buildVersion']) or
            not re.fullmatch(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}', boot)):
        raise UpdateError('invalid_guest_os_identity')
    return {'actual': actual, 'bootIdentity': boot.upper()}


def owner(user):
    generated = text(['/usr/bin/dscl', '.', '-read', '/Users/' + user, 'GeneratedUID'])
    match = re.fullmatch(r'GeneratedUID:\s*([0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})', generated)
    if not match:
        raise UpdateError('guest_volume_owner_identity_unavailable')
    try:
        inventory = plistlib.loads(run(['/usr/sbin/diskutil', 'apfs', 'listUsers', '/', '-plist']))
    except (ValueError, plistlib.InvalidFileException):
        raise UpdateError('guest_volume_owner_inventory_invalid') from None
    users = inventory.get('Users') if isinstance(inventory, dict) else None
    if not isinstance(users, list) or any(not isinstance(item, dict) for item in users):
        raise UpdateError('guest_volume_owner_inventory_invalid')
    matching = [item for item in users if str(item.get('APFSCryptoUserUUID', '')).upper() == match[1].upper()]
    return {'user': user, 'generatedUID': match[1].upper(),
            'volumeOwner': len(matching) == 1 and matching[0].get('VolumeOwner') is True}


def exact_offer(output, target):
    offers = []
    parts = re.split(r'^\s*[*-]\s+Label:\s*', output, flags=re.MULTILINE)
    suffix = target['version'] + '-' + target['buildVersion']
    for part in parts[1:]:
        label, separator, details = part.partition('\n')
        label = label.strip()
        version = re.search(r'(?:^|[, ])Version:\s*([^,\r\n]+)', details)
        title = re.search(r'(?:^|\s)Title:\s*([^,\r\n]+)', details)
        size = re.search(r'(?:^|[, ])Size:\s*([0-9]+)K\b', details)
        if (separator and label.startswith('macOS ') and label.endswith((' ' + suffix, '-' + suffix)) and title and
                title[1].strip().startswith('macOS ') and version and version[1].strip() == target['version'] and
                not re.search(r'\b(beta|seed|release candidate|rc)\b', label + ' ' + title[1], re.IGNORECASE) and
                len(label) <= 256 and not any(ord(char) < 32 for char in label)):
            offers.append({'label': label, **target, **({'downloadBytes': int(size[1]) * 1024} if size else {})})
    if len(offers) != 1:
        raise UpdateError('exact_macos_update_not_offered' if not offers else 'ambiguous_macos_update_offer')
    return offers[0]


def offer_matches(offer, target):
    if not isinstance(offer, dict) or any(offer.get(key) != value for key, value in target.items()):
        return False
    label = offer.get('label')
    suffix = target['version'] + '-' + target['buildVersion']
    return (isinstance(label, str) and label.startswith('macOS ') and len(label) <= 256 and
            label.endswith((' ' + suffix, '-' + suffix)) and not any(ord(char) < 32 for char in label) and
            not re.search(r'\b(beta|seed|release candidate|rc)\b', label, re.IGNORECASE))


def receipt_path(request):
    return UPGRADE_DIRECTORY / request['upgradeID'] / 'receipt.json'


def matching_receipt(request):
    path = receipt_path(request)
    if not UPGRADE_DIRECTORY.exists() and not UPGRADE_DIRECTORY.is_symlink():
        return None
    protected(UPGRADE_DIRECTORY, directory=True, private=True)
    if not path.parent.exists() and not path.parent.is_symlink():
        return None
    protected(path.parent, directory=True, private=True)
    value = read_json(path, missing=True)
    if value is None:
        return None
    nonce = value.get('upgradeNonce')
    if (value.get('version') != 1 or not isinstance(nonce, str) or not re.fullmatch(r'[a-f0-9]{64}', nonce) or
            any(value.get(key) != request[key] for key in request) or
            value.get('phase') not in ('starting', 'installing', 'restart-pending', 'complete', 'failed') or
            not re.fullmatch(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}', str(value.get('preBootIdentity', ''))) or
            not isinstance(value.get('before'), dict) or type(value.get('safeToStop')) is not bool or
            not offer_matches(value.get('offer'), request['target'])):
        raise UpdateError('guest_update_receipt_mismatch')
    return value


def process_start(pid):
    if type(pid) is not int or not 1 < pid <= 2147483647:
        return None
    try:
        value = text(['/bin/ps', '-p', str(pid), '-o', 'lstart='], timeout=5, limit=128)
    except UpdateError:
        return None
    return value or None


def worker_alive(receipt, evidence):
    return (receipt.get('preBootIdentity') == evidence['bootIdentity'] and
            bool(receipt.get('workerStart')) and
            process_start(receipt.get('workerPID')) == receipt['workerStart'])


def receipt_result(request, evidence, receipt, *, persist=False):
    alive = worker_alive(receipt, evidence)
    cold_target = evidence['actual'] == request['target'] and receipt['preBootIdentity'] != evidence['bootIdentity']
    if cold_target:
        if persist and receipt['phase'] != 'complete':
            receipt = {**receipt, 'phase': 'complete', 'updatedAt': timestamp(),
                       'actual': evidence['actual'], 'bootIdentity': evidence['bootIdentity'], 'safeToStop': True}
            write_json(receipt_path(request), receipt)
        return {**evidence, 'status': 'complete', 'safeToStop': True, 'receipt': receipt}
    if receipt['phase'] == 'complete' and evidence['actual'] != request['target']:
        return {**evidence, 'status': 'failed', 'safeToStop': not alive, 'receipt': receipt,
                'reason': 'completed_upgrade_os_mismatch'}
    if receipt['phase'] == 'failed':
        return {**evidence, 'status': 'failed', 'safeToStop': receipt.get('safeToStop') is True,
                'receipt': receipt, 'reason': receipt.get('reason', 'guest_update_failed')}
    return {**evidence, 'status': 'installing', 'safeToStop': False, 'receipt': receipt,
            **({'reason': 'awaiting_target_boot'} if not alive else {})}


def prerequisite(request, evidence):
    ownership = owner(request['consoleUser'])
    if not ownership['volumeOwner']:
        return {**evidence, 'status': 'blocked', 'safeToStop': True, 'owner': ownership,
                'reason': 'guest_account_is_not_volume_owner'}
    output = text(['/usr/sbin/softwareupdate', '--list'], timeout=240)
    try:
        offer = exact_offer(output, request['target'])
    except UpdateError as error:
        return {**evidence, 'status': 'blocked', 'safeToStop': True, 'owner': ownership, 'reason': str(error)}
    storage = os.statvfs('/')
    available = storage.f_bavail * storage.f_frsize
    minimum = max(MIN_SYSTEM_FREE_BYTES, offer.get('downloadBytes', 0) * 2 + 5 * 1024 ** 3)
    if available < minimum:
        return {**evidence, 'status': 'blocked', 'safeToStop': True, 'owner': ownership, 'offer': offer,
                'freeSystemBytes': available, 'minimumSystemFreeBytes': minimum,
                'reason': 'insufficient_guest_system_storage'}
    return {**evidence, 'status': 'ready', 'safeToStop': True, 'owner': ownership, 'offer': offer,
            'freeSystemBytes': available, 'minimumSystemFreeBytes': minimum}


def redact_strings(value, password):
    if isinstance(value, str):
        return value.replace(password, '[REDACTED]') if password else value
    if isinstance(value, list):
        return [redact_strings(item, password) for item in value]
    if isinstance(value, dict):
        return {key: redact_strings(item, password) for key, item in value.items()}
    return value


def stalled_restart(receipt):
    if not receipt or receipt.get('phase') != 'restart-pending':
        return False
    try:
        updated = datetime.datetime.fromisoformat(receipt['updatedAt'])
        return updated.tzinfo is not None and (datetime.datetime.now(datetime.timezone.utc) - updated).total_seconds() >= 120
    except (KeyError, TypeError, ValueError):
        return False


def protected_bytes(path, maximum, *, tail=False):
    protected(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as file:
        metadata = os.fstat(file.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o022:
            raise UpdateError('unprotected_guest_diagnostic_file')
        if not tail and metadata.st_size > maximum:
            raise UpdateError('guest_diagnostic_file_too_large')
        offset = max(0, metadata.st_size - maximum) if tail else 0
        file.seek(offset)
        value = file.read(maximum)
    if tail:
        if offset:
            value = value.partition(b'\n')[2]
        if not value.endswith(b'\n'):
            value = value.rpartition(b'\n')[0]
    return value


def attempt_log_lines(lines, receipt):
    try:
        created = datetime.datetime.fromisoformat(receipt['createdAt'])
        if created.tzinfo is None:
            return []
    except (KeyError, TypeError, ValueError):
        return []
    installer = receipt.get('installerPID')
    selected, nearby = [], []
    for line in lines:
        if type(installer) is int and f'softwareupdate[{installer}]' in line:
            selected.append(line)
            continue
        match = re.match(r'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:[+-]\d{2}(?::?\d{2})?|Z))\s', line)
        if not match:
            continue
        try:
            moment = match[1].replace(' ', 'T', 1)
            if re.search(r'[+-]\d{2}$', moment):
                moment += ':00'
            elif re.search(r'[+-]\d{4}$', moment):
                moment = moment[:-2] + ':' + moment[-2:]
            occurred = datetime.datetime.fromisoformat(moment.replace('Z', '+00:00'))
        except ValueError:
            continue
        if -5 <= (occurred - created).total_seconds() <= 120:
            nearby.append(line)
    return selected[-16:] + nearby[:max(0, 32 - min(len(selected), 16))]


def compact_disk_layout(value, depth=0):
    if not isinstance(value, dict) or depth > 3:
        return None
    output = {}
    for key in ('DeviceIdentifier', 'Content', 'VolumeName'):
        text_value = value.get(key)
        if isinstance(text_value, str) and len(text_value) <= 128:
            output[key] = text_value
    if type(value.get('Size')) is int and value['Size'] >= 0:
        output['Size'] = value['Size']
    for key in ('Partitions', 'APFSVolumes'):
        if isinstance(value.get(key), list):
            output[key] = [item for original in value[key][:32]
                           if (item := compact_disk_layout(original, depth + 1))]
    return output


def cache_sizes(user):
    home = Path(pwd.getpwnam(user).pw_dir)
    if not home.is_absolute() or home.resolve() != home or not home.is_relative_to('/Users'):
        raise UpdateError('guest_home_cache_scope_unavailable')
    requested = [home / '.npm', home / 'Library/Caches', Path('/private/var/folders'), Path('/private/var/vm'),
                 Path('/Library/Developer/CoreSimulator'), Path('/Applications')]
    paths = [str(path) for path in requested if path.is_dir() and not path.is_symlink() and path.resolve() == path]
    if not paths:
        return []
    measured = text(['/usr/bin/du', '-sk', '-x', *paths], timeout=8, limit=16384, accepted=(0, 1))
    result = []
    for line in measured.splitlines():
        match = re.fullmatch(r'([0-9]+)\s+(.+)', line)
        if match and match[2] in paths:
            result.append({'path': match[2], 'bytes': int(match[1]) * 1024})
    return result


def unified_update_log():
    predicate = ('(process CONTAINS[c] "softwareupdate" OR process CONTAINS[c] "updatebrain") AND '
                 '(eventMessage CONTAINS[c] "download" OR eventMessage CONTAINS[c] "error" OR '
                 'eventMessage CONTAINS[c] "fail" OR eventMessage CONTAINS[c] "progress")')
    deadline = time.monotonic() + 9
    child = subprocess.Popen(['/usr/bin/log', 'show', '--last', '5m', '--style', 'compact', '--info',
                              '--predicate', predicate], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, env=ENVIRONMENT, start_new_session=True)
    captured = bytearray()
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise UpdateError('guest_unified_log_timed_out')
            if not select.select([child.stdout], [], [], min(0.2, remaining))[0]:
                continue
            chunk = os.read(child.stdout.fileno(), 65536)
            if not chunk:
                break
            captured.extend(chunk)
            if len(captured) > 1024 * 1024:
                raise UpdateError('guest_unified_log_output_limit')
        if child.wait(timeout=max(0.01, deadline - time.monotonic())) != 0:
            raise UpdateError('guest_unified_log_unavailable')
    except subprocess.TimeoutExpired:
        raise UpdateError('guest_unified_log_timed_out') from None
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=1)
        child.stdout.close()
    lines = [line for line in captured.decode('utf-8', errors='replace').splitlines()
             if len(line.encode('utf-8')) <= 1024][-24:]
    while lines and len(json.dumps(lines).encode('utf-8')) > 8192:
        lines.pop(0)
    return lines


def diagnostics(password, receipt):
    result = {'collectedAt': timestamp(), 'processes': [], 'installHistory': [],
              'installAttemptLog': [], 'installLog': [], 'cliOutput': [], 'storage': [],
              'diskLayout': [], 'cacheSizes': [], 'unifiedLog': [], 'unavailable': []}
    try:
        result['unifiedLog'] = unified_update_log()
    except (UpdateError, OSError, subprocess.TimeoutExpired):
        result['unavailable'].append('unified_update_log')
    for mount in ('/', '/Volumes/BigWalletBuild'):
        try:
            storage = os.statvfs(mount)
            result['storage'].append({'path': mount, 'totalBytes': storage.f_blocks * storage.f_frsize,
                'freeBytes': storage.f_bfree * storage.f_frsize, 'availableBytes': storage.f_bavail * storage.f_frsize})
        except OSError:
            result['unavailable'].append('system_storage' if mount == '/' else 'build_storage')
    try:
        layout = plistlib.loads(run(['/usr/sbin/diskutil', 'list', '-plist'], timeout=5, limit=1024 * 1024))
        disks = layout.get('AllDisksAndPartitions') if isinstance(layout, dict) else None
        if not isinstance(disks, list):
            raise ValueError()
        result['diskLayout'] = [item for disk in disks[:16] if (item := compact_disk_layout(disk))]
    except (UpdateError, OSError, ValueError, plistlib.InvalidFileException):
        result['unavailable'].append('disk_layout')
    result['storageDetails'] = []
    try:
        root_info = plistlib.loads(run(['/usr/sbin/diskutil', 'info', '-plist', '/'], timeout=2, limit=65536))
        apfs = plistlib.loads(run(['/usr/sbin/diskutil', 'apfs', 'list', '-plist'], timeout=2, limit=1024 * 1024))
        keys = ('DeviceIdentifier', 'ParentWholeDisk', 'APFSContainerReference', 'APFSContainerUUID', 'APFSPhysicalStores',
                'DiskUUID', 'PartitionUUID', 'PartitionMapPartitionGUID', 'TotalSize', 'Size', 'DeviceBlockSize',
                'PartitionMapPartitionOffset', 'APFSContainerSize', 'APFSContainerFree', 'Encrypted', 'FileVault')
        result['storageDetails'].append({'kind': 'root', **{key: root_info[key] for key in keys if key in root_info}})
        for container in apfs.get('Containers', [])[:16]:
            wanted = ('ContainerReference', 'APFSContainerUUID', 'CapacityCeiling', 'CapacityFree', 'Fusion', 'PhysicalStores')
            entry = {key: container[key] for key in wanted if key in container}
            entry['Volumes'] = [{key: volume[key] for key in ('DeviceIdentifier', 'APFSVolumeUUID', 'Name',
                'FileVault', 'Encryption', 'Encrypted', 'Roles', 'CapacityInUse') if key in volume}
                for volume in container.get('Volumes', [])[:16]]
            result['storageDetails'].append({'kind': 'container', **entry})
            if container.get('ContainerReference') == root_info.get('APFSContainerReference'):
                for physical in container.get('PhysicalStores', [])[:1]:
                    device = physical.get('DeviceIdentifier', '')
                    if re.fullmatch(r'disk[0-9]+s2', device):
                        for selected in (device, device[:-1] + '3'):
                            info = plistlib.loads(run(['/usr/sbin/diskutil', 'info', '-plist', selected], timeout=2, limit=65536))
                            result['storageDetails'].append({'kind': 'partition', **{key: info[key] for key in keys if key in info}})
    except (UpdateError, OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException):
        result['unavailable'].append('apfs_storage_details')
    try:
        result['cacheSizes'] = cache_sizes(receipt['consoleUser'])
    except (UpdateError, OSError, KeyError):
        result['unavailable'].append('scoped_cache_sizes')
    try:
        processes = text(['/bin/ps', '-axo', 'pid=,ppid=,comm='], timeout=5, limit=1024 * 1024)
        for line in processes.splitlines():
            fields = line.strip().split(None, 2)
            if len(fields) != 3 or not fields[0].isdigit() or not fields[1].isdigit():
                continue
            name = Path(fields[2]).name
            if re.fullmatch(r'(?:softwareupdate[a-z0-9_-]*|osinstall[a-z0-9_-]*|updatebrain[a-z0-9_-]*)', name, re.IGNORECASE):
                result['processes'].append({'pid': int(fields[0]), 'ppid': int(fields[1]), 'comm': name})
        result['processes'] = result['processes'][-32:]
    except (UpdateError, OSError):
        result['unavailable'].append('update_processes')
    try:
        history = plistlib.loads(protected_bytes(Path('/Library/Receipts/InstallHistory.plist'), 2 * 1024 * 1024))
        if not isinstance(history, list):
            raise ValueError()
        for entry in history:
            if not isinstance(entry, dict):
                continue
            name, version, date = entry.get('displayName'), entry.get('displayVersion'), entry.get('date')
            if (not isinstance(name, str) or len(name) > 512 or not re.search(r'\bmacOS\b', name, re.IGNORECASE) or
                    not isinstance(version, str) or len(version) > 64 or not isinstance(date, datetime.datetime)):
                continue
            result['installHistory'].append({'displayName': name, 'version': version, 'date': date.isoformat()})
        result['installHistory'] = result['installHistory'][-5:]
    except (UpdateError, OSError, ValueError, plistlib.InvalidFileException):
        result['unavailable'].append('macos_install_history')
    try:
        tail = protected_bytes(Path('/private/var/log/install.log'), 1024 * 1024, tail=True).decode('utf-8', errors='replace')
        lines = [line for line in tail.splitlines() if len(line.encode('utf-8')) <= 1024 and
                 re.search(r'software.?updat|osinstall|\bmacOS\b|updatebrain|mobile.?software', line, re.IGNORECASE)]
        result['installAttemptLog'] = attempt_log_lines(lines, receipt)
        result['installLog'] = lines[-24:]
    except (UpdateError, OSError):
        result['unavailable'].append('installer_log')
    try:
        request = validate_request({key: receipt[key] for key in ('vmId', 'consoleUser', 'upgradeID', 'upgradeNonce', 'target')})
        captured = protected_bytes(receipt_path(request).parent / 'softwareupdate.log', MAX_UPDATE_OUTPUT)
        result['cliOutput'] = [line for line in captured.decode('utf-8', errors='replace').splitlines()
                               if len(line.encode('utf-8')) <= 1024][-16:]
    except (UpdateError, OSError, KeyError):
        result['unavailable'].append('softwareupdate_output')
    result = redact_strings(result, password)
    while result['unifiedLog'] and len(json.dumps(result['unifiedLog']).encode('utf-8')) > 8192:
        result['unifiedLog'].pop(0)
    for key in ('installLog', 'installHistory', 'processes', 'installAttemptLog', 'diskLayout', 'cacheSizes', 'cliOutput', 'storageDetails', 'unifiedLog'):
        while result[key] and len(json.dumps(result).encode('utf-8')) > MAX_DIAGNOSTICS:
            result[key].pop(0)
    return result


def receipt_digest(request):
    return hashlib.sha256(protected_bytes(receipt_path(request), MAX_JSON)).hexdigest()


def original_process_alive(pid, started=None):
    if type(pid) is not int or not 1 < pid <= 2147483647:
        raise UpdateError('invalid_abandonment_process_identity')
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except (PermissionError, OSError):
        raise UpdateError('abandonment_process_state_unavailable') from None
    if not started:
        return True
    actual = process_start(pid)
    if actual is None:
        raise UpdateError('abandonment_process_start_unavailable')
    return actual == started


@contextlib.contextmanager
def operation_lock(request, *, allow_busy=False):
    protected(UPGRADE_DIRECTORY, directory=True, private=True)
    path = UPGRADE_DIRECTORY / 'operation.lock'
    protected(path, private=True)
    descriptor = os.open(path, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            if allow_busy:
                yield None
                return
            raise UpdateError('guest_update_operation_still_active') from None
        yield descriptor
    finally:
        os.close(descriptor)


def log_moment(line):
    match = re.match(r'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})([+-]\d{2}(?::?\d{2})?|Z)\s', line)
    if not match:
        return None
    offset = match[2]
    if offset == 'Z':
        offset = '+00:00'
    elif len(offset) == 3:
        offset += ':00'
    elif len(offset) == 5:
        offset = offset[:3] + ':' + offset[3:]
    try:
        return datetime.datetime.fromisoformat(match[1].replace(' ', 'T') + offset)
    except ValueError:
        return None


def storage_rejection_evidence(receipt):
    try:
        started = datetime.datetime.fromisoformat(receipt['createdAt'])
        finished = datetime.datetime.fromisoformat(receipt['updatedAt'])
    except (KeyError, TypeError, ValueError):
        raise UpdateError('abandonment_receipt_time_unavailable') from None
    if started.tzinfo is None or finished.tzinfo is None or finished < started:
        raise UpdateError('abandonment_receipt_time_invalid')
    contents = protected_bytes(Path('/private/var/log/install.log'), 1024 * 1024, tail=True).decode('utf-8', errors='replace')
    rejection = None
    idle = None
    for line in contents.splitlines():
        occurred = log_moment(line)
        if occurred is None:
            continue
        if (f'softwareupdate[{receipt["installerPID"]}]' in line and
                -5 <= (occurred - started).total_seconds() and (occurred - finished).total_seconds() <= 5):
            match = re.search(r'disk space (?:isn.t|is not) sufficient\s*\(required\s*=\s*(\d+),\s*free\s*=\s*(\d+)\)', line, re.IGNORECASE)
            if match and 0 <= int(match[2]) < int(match[1]):
                rejection = {'requiredBytes': int(match[1]), 'freeBytesAtRejection': int(match[2]),
                             'rejectedAt': occurred.isoformat(), 'installerPID': receipt['installerPID']}
        if (rejection and occurred > finished and
                re.search(r'\bsoftwareupdated\[[0-9]+\]:.*No update downloaded and prepared\.', line)):
            idle = occurred.isoformat()
    if rejection is None or idle is None:
        raise UpdateError('positive_storage_abandonment_evidence_missing')
    return {**rejection, 'notPreparedAt': idle}


def abandonment_conditions(request, receipt, evidence):
    if (receipt is None or receipt.get('phase') not in ('restart-pending', 'failed') or
            evidence['bootIdentity'] != receipt.get('preBootIdentity') or
            evidence['actual'] != receipt.get('before') or evidence['actual'] == request['target']):
        raise UpdateError('guest_update_cannot_be_abandoned_in_this_state')
    if (original_process_alive(receipt.get('workerPID'), receipt.get('workerStart')) or
            original_process_alive(receipt.get('installerPID'), receipt.get('installerStart'))):
        raise UpdateError('guest_update_process_still_active')
    processes = text(['/bin/ps', '-axo', 'pid=,comm='], timeout=5, limit=1024 * 1024)
    for line in processes.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and re.fullmatch(r'(?:softwareupdate|osinstall[a-z0-9_-]*|[a-z0-9_-]*updatebrain[a-z0-9_-]*|InstallAssistant)',
                                           Path(fields[1]).name, re.IGNORECASE):
            raise UpdateError('another_guest_os_installer_is_active')
    rejection = storage_rejection_evidence(receipt)
    storage = os.statvfs('/')
    available = storage.f_bavail * storage.f_frsize
    if available >= rejection['requiredBytes']:
        raise UpdateError('guest_storage_no_longer_proves_installation_rejection')
    return {**rejection, 'currentAvailableBytes': available, 'workerPID': receipt['workerPID'],
            'originalExitCode': receipt.get('exitCode'), 'noInstallerProcesses': True}


def matching_abandonment(request, receipt, evidence):
    value = read_json(receipt_path(request).parent / 'abandonment.json', missing=True)
    if value is None:
        return None
    if (receipt is None or value.get('version') != 1 or any(value.get(key) != request[key] for key in request) or
            value.get('receiptSHA256') != receipt_digest(request) or value.get('before') != evidence['actual'] or
            value.get('preBootIdentity') != evidence['bootIdentity'] or
            value.get('reason') != 'insufficient_guest_system_storage' or not isinstance(value.get('evidence'), dict)):
        raise UpdateError('guest_abandonment_identity_mismatch')
    return value


def abandoned_result(evidence, receipt, intent):
    return {**evidence, 'status': 'blocked', 'safeToStop': False, 'reason': 'upgrade_abandoned_for_storage',
            'receipt': receipt, 'abandonment': intent}


def abandon(request):
    evidence = attest(request)
    with operation_lock(request):
        receipt = matching_receipt(request)
        proof = abandonment_conditions(request, receipt, evidence)
        intent = matching_abandonment(request, receipt, evidence)
        if intent is None:
            intent = {'version': 1, **request, 'reason': 'insufficient_guest_system_storage',
                      'receiptSHA256': receipt_digest(request), 'before': evidence['actual'],
                      'preBootIdentity': evidence['bootIdentity'], 'createdAt': timestamp(), 'evidence': proof}
            write_json(receipt_path(request).parent / 'abandonment.json', intent)
    return abandoned_result(evidence, receipt, intent)


def halt_abandoned(request, source):
    evidence = attest(request)
    with operation_lock(request) as descriptor:
        receipt = matching_receipt(request)
        intent = matching_abandonment(request, receipt, evidence)
        if intent is None:
            raise UpdateError('guest_abandonment_intent_required')
        abandonment_conditions(request, receipt, evidence)
        directory = receipt_path(request).parent
        existing = read_json(directory / 'halt-request.json', missing=True)
        if existing is not None:
            if (existing.get('upgradeID') != request['upgradeID'] or existing.get('vmId') != request['vmId'] or
                    existing.get('preBootIdentity') != evidence['bootIdentity']):
                raise UpdateError('guest_abandonment_halt_identity_mismatch')
            if existing.get('phase') not in ('scheduled', 'launch-failed', 'issued'):
                raise UpdateError('guest_abandonment_halt_identity_mismatch')
            if existing['phase'] == 'issued':
                return {**abandoned_result(evidence, receipt, intent), 'shutdownRequested': True, 'halt': existing}
        write_bytes(directory / 'halt-worker.py', source)
        halt = {'version': 1, 'upgradeID': request['upgradeID'], 'vmId': request['vmId'],
                'preBootIdentity': evidence['bootIdentity'], 'requestedAt': timestamp(),
                'phase': 'scheduled', 'method': 'guest_graceful_shutdown'}
        write_json(directory / 'halt-request.json', halt)
        try:
            subprocess.Popen([sys.executable, str(directory / 'halt-worker.py'), '--halt-worker', json.dumps(request), str(descriptor)],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             env=ENVIRONMENT, start_new_session=True, pass_fds=(descriptor,))
        except OSError:
            halt.update(phase='launch-failed')
            write_json(directory / 'halt-request.json', halt)
            raise UpdateError('guest_abandonment_shutdown_launch_failed') from None
    return {**abandoned_result(evidence, receipt, intent), 'shutdownRequested': True, 'halt': halt}


def halt_worker(request, descriptor):
    request = validate_request(request)
    path = UPGRADE_DIRECTORY / 'operation.lock'
    protected(path, private=True)
    held, expected = os.fstat(descriptor), path.stat()
    if (held.st_dev, held.st_ino) != (expected.st_dev, expected.st_ino):
        raise UpdateError('guest_abandonment_halt_lock_mismatch')
    time.sleep(2)
    evidence = attest(request)
    receipt = matching_receipt(request)
    if matching_abandonment(request, receipt, evidence) is None:
        raise UpdateError('guest_abandonment_intent_required')
    abandonment_conditions(request, receipt, evidence)
    halt_path = receipt_path(request).parent / 'halt-request.json'
    halt = read_json(halt_path)
    if (halt.get('phase') != 'scheduled' or halt.get('upgradeID') != request['upgradeID'] or
            halt.get('vmId') != request['vmId'] or halt.get('preBootIdentity') != evidence['bootIdentity']):
        raise UpdateError('guest_abandonment_halt_identity_mismatch')
    run(['/sbin/shutdown', '-h', 'now'], timeout=10, limit=4096)
    write_json(halt_path, {**halt, 'phase': 'issued'})


def reconcile_worker_launch(request, receipt, *, persist=True):
    if receipt is None:
        raise UpdateError('update_receipt_missing')
    if receipt['phase'] == 'starting':
        receipt = {**receipt, 'phase': 'failed', 'reason': 'guest_update_worker_launch_failed',
                   'safeToStop': True, 'updatedAt': timestamp()}
        if persist:
            write_json(receipt_path(request), receipt)
    return receipt


def inspect(request, action, diagnostic_password=None):
    evidence = attest(request)
    receipt = matching_receipt(request)
    if receipt:
        if receipt['phase'] == 'starting':
            with operation_lock(request, allow_busy=True) as lock:
                if lock is not None:
                    receipt = reconcile_worker_launch(request, matching_receipt(request), persist=diagnostic_password is None)
        intent = matching_abandonment(request, receipt, evidence)
        if intent is not None:
            return abandoned_result(evidence, receipt, intent)
        result = receipt_result(request, evidence, receipt, persist=diagnostic_password is None)
        if action == 'observe' and diagnostic_password and result['status'] == 'installing':
            result['diagnostics'] = diagnostics(diagnostic_password, receipt)
        return result
    if action == 'observe':
        return {**evidence, 'status': 'blocked', 'safeToStop': False, 'receipt': None,
                'reason': 'update_receipt_missing'}
    if evidence['actual'] == request['target']:
        return {**evidence, 'status': 'complete', 'safeToStop': True, 'receipt': None}
    return prerequisite(request, evidence)


def private_directory(path):
    try:
        path.mkdir(mode=0o700)
    except FileExistsError:
        pass
    protected(path, directory=True, private=True)


class RedactedOutput:
    def __init__(self, password):
        self.password = password
        self.pending = b''
        self.contents = b''
        self.truncated = False

    def consume(self, chunk, *, final=False):
        value = self.pending + chunk
        boundary = len(value) if final else max(0, len(value) - len(self.password) + 1)
        position = value.find(self.password) if self.password else -1
        while position >= 0 and position < boundary:
            boundary = max(boundary, position + len(self.password))
            position = value.find(self.password, position + len(self.password))
        safe = value[:boundary].replace(self.password, b'[REDACTED]') if self.password else value[:boundary]
        self.pending = value[boundary:]
        output = self.contents + safe
        self.truncated = self.truncated or len(output) > MAX_UPDATE_OUTPUT
        self.contents = output[-MAX_UPDATE_OUTPUT:]
        if final:
            self.password = b''
            self.pending = b''


class UpdateOutput:
    def __init__(self, stream, password, path):
        self.stream = stream
        self.capture = RedactedOutput(password)
        self.path = path
        self.unavailable = False
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()

    def _save(self):
        if self.unavailable:
            return
        try:
            write_bytes(self.path, self.capture.contents)
        except (UpdateError, OSError):
            self.unavailable = True

    def _read(self):
        try:
            while True:
                chunk = self.stream.read1(8192)
                if not chunk:
                    break
                self.capture.consume(chunk)
                self._save()
        except (OSError, ValueError):
            self.unavailable = True
        finally:
            self.capture.consume(b'', final=True)
            self._save()
            self.stream.close()

    def finish(self):
        self.thread.join(timeout=5)
        return {'outputLog': 'softwareupdate.log', 'outputComplete': not self.thread.is_alive(),
                'outputTruncated': self.capture.truncated, 'outputUnavailable': self.unavailable}


def update_outcome(code, contents, evidence):
    if code < 0:
        return {'phase': 'installing', 'exitCode': code, 'safeToStop': False, 'reason': 'softwareupdate_signalled'}
    pending = {'phase': 'restart-pending' if code == 0 else 'installing', 'exitCode': code, 'safeToStop': False}
    if not evidence.get('outputComplete') or evidence.get('outputTruncated') or evidence.get('outputUnavailable'):
        return pending
    lines = [line.strip() for line in contents.decode('utf-8', errors='replace').splitlines() if line.strip()]
    patterns = (
        ('softwareupdate_insufficient_disk_space', r'not enough (?:free )?(?:disk )?space|insufficient (?:free )?(?:disk )?space|disk space (?:isn.t|is not) sufficient'),
        ('softwareupdate_no_matching_update', r'no updates (?:are )?available|no updates to install|no such update'),
        ('softwareupdate_authentication_failed', r'failed to authenticate|authentication failed|failed to authorize|unable to authenticate'),
    )
    if lines:
        for reason, pattern in patterns:
            if re.search(pattern, lines[-1], re.IGNORECASE):
                return {'phase': 'failed', 'exitCode': code, 'safeToStop': True, 'reason': reason,
                        'failureEvidence': 'complete_cli_terminal_output'}
    return pending


def start(request, password, source):
    evidence = attest(request)
    private_directory(UPGRADE_DIRECTORY)
    lock_path = UPGRADE_DIRECTORY / 'operation.lock'
    descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    child = None
    try:
        protected(lock_path, private=True)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            receipt = matching_receipt(request)
            return (receipt_result(request, evidence, receipt) if receipt else
                    {**evidence, 'status': 'installing', 'safeToStop': False,
                     'reason': 'upgrade_admission_in_progress'})
        receipt = matching_receipt(request)
        if receipt:
            receipt = reconcile_worker_launch(request, receipt)
            intent = matching_abandonment(request, receipt, evidence)
            if intent is not None:
                return abandoned_result(evidence, receipt, intent)
            return receipt_result(request, evidence, receipt)
        if evidence['actual'] == request['target']:
            return {**evidence, 'status': 'complete', 'safeToStop': True, 'receipt': None}
        active = read_json(UPGRADE_DIRECTORY / 'active.json', missing=True)
        if active is not None:
            prior = attempt_identity(active)
            if prior['upgradeID'] == request['upgradeID']:
                return {**evidence, 'status': 'blocked', 'safeToStop': False, 'reason': 'update_receipt_missing'}
            previous = matching_receipt(prior)
            previous_finished = (prior['vmId'] == request['vmId'] and prior['consoleUser'] == request['consoleUser'] and
                                 previous is not None and previous['phase'] == 'complete' and
                                 previous.get('actual') == prior['target'] and previous.get('safeToStop') is True and
                                 not worker_alive(previous, evidence))
            if not previous_finished:
                return {**evidence, 'status': 'blocked', 'safeToStop': False,
                        'reason': 'another_guest_upgrade_is_recorded'}
        ready = prerequisite(request, evidence)
        if ready['status'] != 'ready':
            return ready
        directory = receipt_path(request).parent
        private_directory(directory)
        write_bytes(directory / 'worker.py', source)
        write_json(directory / 'request.json', request)
        receipt = {'version': 1, **request, 'phase': 'starting', 'before': evidence['actual'],
                   'preBootIdentity': evidence['bootIdentity'], 'createdAt': timestamp(), 'updatedAt': timestamp(),
                   'owner': ready['owner'], 'offer': ready['offer'], 'safeToStop': False}
        write_json(receipt_path(request), receipt)
        write_json(UPGRADE_DIRECTORY / 'active.json', attempt_identity(request))
        try:
            child = subprocess.Popen([sys.executable, str(directory / 'worker.py'), '--worker', str(directory), str(descriptor)],
                                     stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                     env=ENVIRONMENT, start_new_session=True, pass_fds=(descriptor,))
            child.stdin.write(password + b'\n')
            child.stdin.close()
        except (OSError, BrokenPipeError):
            if child is None:
                receipt.update(phase='failed', reason='guest_update_worker_launch_failed', safeToStop=True, updatedAt=timestamp())
                write_json(receipt_path(request), receipt)
                return receipt_result(request, evidence, receipt)
            return {**evidence, 'status': 'installing', 'safeToStop': False, 'receipt': receipt,
                    'reason': 'guest_update_worker_start_uncertain'}
        return {**evidence, 'status': 'installing', 'safeToStop': False, 'receipt': receipt}
    finally:
        os.close(descriptor)


def worker(directory, lock_descriptor):
    protected(directory, directory=True, private=True)
    if directory.parent != UPGRADE_DIRECTORY:
        raise UpdateError('invalid_guest_update_worker_directory')
    request = validate_request(read_json(directory / 'request.json'))
    if directory != receipt_path(request).parent:
        raise UpdateError('invalid_guest_update_worker_directory')
    evidence = attest(request)
    receipt = matching_receipt(request)
    if receipt is None or receipt['phase'] != 'starting' or receipt['preBootIdentity'] != evidence['bootIdentity']:
        raise UpdateError('invalid_guest_update_worker_receipt')
    lock = os.fstat(lock_descriptor)
    expected_lock = (UPGRADE_DIRECTORY / 'operation.lock').stat()
    if (not stat.S_ISREG(lock.st_mode) or lock.st_uid != 0 or lock.st_mode & 0o077 or
            (lock.st_dev, lock.st_ino) != (expected_lock.st_dev, expected_lock.st_ino)):
        raise UpdateError('invalid_guest_update_worker_lock')
    password = sys.stdin.buffer.readline(4098).removesuffix(b'\n')
    if not password or len(password) > 4096 or any(value in password for value in (b'\n', b'\r', b'\0')):
        receipt.update(phase='failed', reason='guest_update_worker_credentials_missing', safeToStop=True, updatedAt=timestamp())
        write_json(receipt_path(request), receipt)
        return
    receipt.update(workerPID=os.getpid(), workerStart=process_start(os.getpid()), updatedAt=timestamp())
    if not receipt['workerStart']:
        raise UpdateError('guest_update_worker_identity_unavailable')
    command = ['/usr/sbin/softwareupdate', '--install', receipt['offer']['label'], '--restart',
               '--user', request['consoleUser'], '--stdinpass']
    receipt.update(phase='installing')
    write_json(receipt_path(request), receipt)
    process = None
    output = None
    try:
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, env=ENVIRONMENT)
        output = UpdateOutput(process.stdout, password, directory / 'softwareupdate.log')
        receipt.update(installerPID=process.pid, installerStart=process_start(process.pid), updatedAt=timestamp())
        write_json(receipt_path(request), receipt)
        try:
            process.stdin.write(password + b'\n')
            process.stdin.close()
        except BrokenPipeError:
            pass
        password = b''
        code = process.wait()
        receipt.update(output.finish())
        receipt.update(update_outcome(code, output.capture.contents, receipt))
        receipt['updatedAt'] = timestamp()
        write_json(receipt_path(request), receipt)
    except OSError:
        receipt.update(phase='failed' if process is None else 'installing',
                       reason='softwareupdate_launch_failed' if process is None else 'softwareupdate_worker_uncertain',
                       safeToStop=process is None, updatedAt=timestamp())
        if output is not None:
            receipt.update(output.finish())
        write_json(receipt_path(request), receipt)
    finally:
        password = b''


def main():
    if len(sys.argv) == 4 and sys.argv[1] == '--halt-worker':
        halt_worker(json.loads(sys.argv[2]), int(sys.argv[3]))
        return
    if len(sys.argv) == 4 and sys.argv[1] == '--worker':
        worker(Path(sys.argv[2]), int(sys.argv[3]))
        return
    diagnostic = len(sys.argv) == 3 and sys.argv[1:] == ['observe', '--diagnostics']
    if (len(sys.argv) != 2 and not diagnostic) or sys.argv[1] not in ('probe', 'start', 'observe', 'abandon', 'halt-abandoned', 'resize'):
        raise UpdateError('invalid_guest_update_action')
    marker = sys.stdin.buffer.readline(4098).rstrip(b'\n')
    if marker != INPUT_MARKER:
        marker = sys.stdin.buffer.readline(4098).rstrip(b'\n')
    if marker != INPUT_MARKER:
        raise UpdateError('invalid_guest_update_input_marker')
    line = sys.stdin.buffer.readline(MAX_JSON + 1)
    if len(line) > MAX_JSON:
        raise UpdateError('invalid_guest_update_request_size')
    try:
        request = validate_request(json.loads(line))
    except (ValueError, UnicodeError):
        raise UpdateError('invalid_guest_update_request') from None
    if sys.argv[1] == 'resize':
        growth_line = sys.stdin.buffer.readline(MAX_JSON + 1)
        if len(growth_line) > MAX_JSON:
            raise UpdateError('invalid_guest_storage_request_size')
        growth = json.loads(growth_line)
        namespace = {'__name__': 'big_wallet_macos_storage_guest'}
        exec(compile(globals()['STORAGE_SOURCE_BYTES'], 'macos_storage_guest.py', 'exec'), namespace)
        result = namespace['grow_container'](request, growth, SimpleNamespace(**globals()))
    elif sys.argv[1] == 'abandon':
        result = abandon(request)
    elif sys.argv[1] == 'halt-abandoned':
        result = halt_abandoned(request, globals()['SOURCE_BYTES'])
    elif sys.argv[1] == 'start' or diagnostic:
        password = sys.stdin.buffer.readline(4098).removesuffix(b'\n')
        if not password or len(password) > 4096 or any(value in password for value in (b'\n', b'\r', b'\0')):
            raise UpdateError('invalid_guest_update_password')
        if diagnostic:
            result = inspect(request, 'observe', password.decode('utf-8', errors='replace'))
        else:
            result = start(request, password, globals()['SOURCE_BYTES'])
        password = b''
    else:
        result = inspect(request, sys.argv[1])
    print(RESULT_PREFIX + json.dumps(result, sort_keys=True), flush=True)


if __name__ == '__main__':
    try:
        main()
    except (UpdateError, OSError, ValueError) as error:
        print(RESULT_PREFIX + json.dumps(error_envelope(error)), flush=True)
        sys.exit(1)
