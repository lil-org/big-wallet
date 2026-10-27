#!/usr/bin/env python3

import argparse
import contextlib
import ctypes
import datetime
import fcntl
import functools
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import time
from types import SimpleNamespace
import uuid


ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path(__file__).resolve().parent
DEFAULT_VM = Path.home() / 'Library/Application Support/VirtualBuddy/tests machine.vbvm'
DEFAULT_STATE = Path.home() / 'Library/Application Support/Big Wallet Test VM'
STAGES = ('build', 'test', 'performance', 'tsan', 'fuzz', 'approval', 'upgrade', 'safari', 'repository', 'worker', 'runtime')
EXCLUDED_PARTS = {'.git', '.asc-runtime', 'node_modules', 'DerivedData', 'build', '.build',
                  '.cache', '.vm-testing', '__pycache__', '.venv', 'venv'}
SECRET_SUFFIXES = {'.p12', '.p8', '.pem', '.key', '.mobileprovision', '.provisionprofile'}
MAX_SNAPSHOT_BYTES = 1024 ** 3
MAX_SNAPSHOT_FILES = 100000
STOP_FINALIZATION_SECONDS = 600
STOP_EXPORT_SECONDS = 1800
STOP_EXTRACT_SECONDS = 900


class RunnerError(Exception):
    pass


def checked(command, **kwargs):
    result = subprocess.run([str(value) for value in command], capture_output=True, **kwargs)
    if result.returncode:
        detail = result.stderr.decode(errors='replace') if isinstance(result.stderr, bytes) else result.stderr
        raise RunnerError(f'{Path(str(command[0])).name} failed: {detail.strip()[-2000:]}')
    return result.stdout


def read_json(path):
    with open_regular(path) as file:
        return json.load(file)


def xcode_upgrade_module():
    spec = importlib.util.spec_from_file_location('vm_xcode_upgrade', TOOLS / 'xcode_upgrade.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def normalize_source_vm(value):
    path = Path(value).expanduser().absolute()
    if '..' in path.parts:
        current = Path(path.anchor)
        for component in path.parts[1:]:
            current /= component
            if current.is_symlink():
                raise RunnerError('Source VM paths containing .. must not traverse symlinks')
    return Path(os.path.abspath(path))


def matches_source_vm(record, requested):
    source = record.get('sourceVM')
    return (isinstance(source, str) and Path(source).is_absolute() and
            normalize_source_vm(source) == normalize_source_vm(requested))


@contextlib.contextmanager
def open_regular(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    if not stat.S_ISREG(os.fstat(descriptor).st_mode):
        os.close(descriptor)
        raise RunnerError(f'Expected a regular file: {path}')
    with os.fdopen(descriptor, 'rb') as file:
        yield file


def atomic_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    with open(temporary, 'x', encoding='utf-8') as file:
        json.dump(value, file, sort_keys=True, separators=(',', ':'))
        file.write('\n')
        file.flush()
        os.fsync(file.fileno())
    os.replace(temporary, path)


def atomic_plist(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        with open(temporary, 'xb') as file:
            plistlib.dump(value, file)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, path)
        descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        temporary.unlink(missing_ok=True)


def private_directory(path):
    path = Path(path)
    if path.is_symlink():
        raise RunnerError(f'Refusing a symlink for runner state: {path}')
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.stat().st_uid != os.getuid():
        raise RunnerError(f'Runner state must be owned by the current user: {path}')
    path.chmod(0o700)
    return path


def source_is_allowed(name):
    path = PurePosixPath(name)
    return (not path.is_absolute() and '..' not in path.parts and
            not any(part in EXCLUDED_PARTS or part.startswith('DerivedData') for part in path.parts) and
            not any(part.startswith('.env') for part in path.parts) and
            not any(part.endswith('.xcresult') for part in path.parts) and
            path.suffix.lower() not in SECRET_SUFFIXES and
            path.name != '.vm-testing.local.json' and
            not name.startswith(('.asc/artifacts/', '.asc/runs/', '.asc/tmp/', '.asc/reports/')))


def snapshot_source(repository, exchange):
    repository = Path(repository).resolve()
    destination = Path(exchange) / 'source'
    destination.mkdir()
    names = checked(['git', '-C', repository, 'ls-files', '-z', '--cached', '--others', '--exclude-standard'])
    entries = []
    size = 0
    for raw in sorted(set(names.split(b'\0')) - {b''}):
        name = os.fsdecode(raw)
        if not source_is_allowed(name):
            continue
        source = repository / name
        if not source.exists() and not source.is_symlink():
            continue
        if len(entries) >= MAX_SNAPSHOT_FILES:
            raise RunnerError('Source snapshot exceeds the 1 GiB / 100,000 file limit')
        target = destination / name
        for parent in PurePosixPath(name).parents:
            if parent != PurePosixPath('.') and (repository / str(parent)).is_symlink():
                raise RunnerError(f'Source traverses a symlink: {name}')
        target.parent.mkdir(parents=True, exist_ok=True)
        metadata = source.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            link = os.readlink(source)
            resolved = (source.parent / link).resolve()
            if os.path.isabs(link) or not resolved.is_relative_to(repository):
                raise RunnerError(f'Source symlink leaves the snapshot: {name}')
            if not source_is_allowed(str(resolved.relative_to(repository))):
                raise RunnerError(f'Source symlink targets excluded content: {name}')
            os.symlink(link, target)
            entries.append({'path': name, 'type': 'symlink', 'target': link,
                            'mode': 0o777, 'sha256': hashlib.sha256(link.encode()).hexdigest()})
        elif stat.S_ISREG(metadata.st_mode):
            with open_regular(source) as file:
                before = os.fstat(file.fileno())
                if before.st_size > MAX_SNAPSHOT_BYTES - size:
                    raise RunnerError('Source snapshot exceeds the 1 GiB / 100,000 file limit')
                digest = hashlib.sha256()
                copied = 0
                with open(target, 'xb') as output:
                    while True:
                        chunk = file.read(min(1024 * 1024, before.st_size - copied + 1))
                        if not chunk:
                            break
                        copied += len(chunk)
                        if copied > before.st_size:
                            raise RunnerError(f'Source changed while snapshotting; retry: {name}')
                        output.write(chunk)
                        digest.update(chunk)
                after = os.fstat(file.fileno())
            if copied != before.st_size or (before.st_mtime_ns, before.st_size) != (after.st_mtime_ns, after.st_size):
                raise RunnerError(f'Source changed while snapshotting; retry: {name}')
            size += copied
            mode = 0o755 if metadata.st_mode & 0o111 else 0o644
            target.chmod(mode)
            entries.append({'path': name, 'type': 'file', 'mode': mode,
                            'sha256': digest.hexdigest()})
        else:
            raise RunnerError(f'Unsupported source file: {name}')
    atomic_json(Path(exchange) / 'snapshot-manifest.json', {'version': 1, 'files': entries})
    manifest = (Path(exchange) / 'snapshot-manifest.json').read_bytes()
    return {'sha256': hashlib.sha256(manifest).hexdigest(),
            'commit': checked(['git', '-C', repository, 'rev-parse', 'HEAD']).decode().strip(),
            'fileCount': len(entries), 'bytes': size}


def validate_vm(path):
    path = Path(path)
    if path.is_symlink() or path.suffix != '.vbvm' or not path.is_dir():
        raise RunnerError(f'Expected an existing, nonsymlink .vbvm bundle: {path}')
    if (path / '.vbdata').is_symlink() or not (path / '.vbdata').is_dir():
        raise RunnerError('VM metadata must be a real directory within the bundle')
    for name in ('Disk.img', 'AuxiliaryStorage', 'HardwareModel', 'MachineIdentifier', '.vbdata/Config.plist'):
        with open_regular(path / name):
            pass
    with open_regular(path / '.vbdata/Config.plist') as file:
        configuration = plistlib.load(file)
    if configuration.get('systemType') != 'mac':
        raise RunnerError('Only existing macOS VirtualBuddy VMs are supported')
    devices = configuration.get('hardware', {}).get('_storageDevices', [])
    if len(devices) not in (1, 2) or not devices[0].get('isBootVolume'):
        raise RunnerError('VM must have one managed boot disk and only the optional managed build disk')
    image = devices[0].get('backing', {}).get('managedImage', {}).get('_0', {})
    if image.get('filename') != 'Disk' or image.get('format') != 0:
        raise RunnerError('Expected the managed raw Disk.img boot disk')
    if len(devices) == 2:
        build_image = devices[1].get('backing', {}).get('managedImage', {}).get('_0', {})
        if devices[1].get('isBootVolume') or build_image.get('filename') != 'BuildData' or build_image.get('format') != 0:
            raise RunnerError('Only the managed BuildData.img secondary disk is supported')
        with open_regular(path / 'BuildData.img'):
            pass
    return configuration


def ensure_disk_idle(vm):
    disks = [str(Path(vm) / name) for name in ('Disk.img', 'BuildData.img') if (Path(vm) / name).exists()]
    if not disks:
        return
    try:
        result = subprocess.run(['/usr/sbin/lsof', '-t', '+w', *disks],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RunnerError('Could not establish exclusive access to the VM disk') from error
    if result.stdout.strip():
        raise RunnerError('The VM disk is in use. Shut down that VM before continuing.')
    if result.returncode not in (0, 1) or result.stderr.strip():
        raise RunnerError('Could not establish exclusive access to the VM disk')


def clone_vm(source, destination):
    validate_vm(source)
    ensure_disk_idle(source)
    if destination.exists():
        raise RunnerError(f'Clone destination already exists: {destination}')
    checked(['/bin/cp', '-cR', source, destination])
    validate_vm(destination)


def configure_build_storage(vm, byte_count):
    config_path = vm / '.vbdata/Config.plist'
    configuration = validate_vm(vm)
    disk = vm / 'BuildData.img'
    if disk.is_symlink() or (disk.exists() and len(configuration['hardware']['_storageDevices']) != 2):
        raise RunnerError('Unregistered or symlinked build disk found; preserve it and inspect the candidate before continuing')
    created = not disk.exists()
    if not disk.exists():
        with open(disk, 'xb') as file:
            file.truncate(byte_count)
        configuration['hardware']['_storageDevices'].append({
            'id': str(uuid.uuid4()), 'isBootVolume': False, 'isEnabled': True,
            'isReadOnly': False, 'isSavedStateClone': False, 'isUSBMassStorageDevice': False,
            'backing': {'managedImage': {'_0': {'id': '__BIG_WALLET_BUILD__', 'filename': 'BuildData',
                                              'format': 0, 'size': byte_count}}}})
    elif disk.stat().st_size != byte_count:
        raise RunnerError('Existing build disk size does not match the pinned environment; it will not be reformatted')
    atomic_plist(config_path, configuration)
    return created


def configure_guest_hardware(vm, vm_id=None):
    configuration = validate_vm(vm)
    if vm_id is not None:
        networks = configuration['hardware'].get('networkDevices', [])
        if len(networks) != 1 or not isinstance(vm_id, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', vm_id):
            raise RunnerError('Headless guest setup requires one network device and a valid VM identity')
        octets = b'\x02' + hashlib.sha256(('big-wallet-vm:' + vm_id).encode()).digest()[:5]
        networks[0]['macAddress'] = ':'.join(f'{value:02x}' for value in octets)
    configuration['guestAdditionsEnabled'] = False
    configuration['captureSystemKeys'] = False
    configuration['hardware']['soundDevices'] = []
    configuration['sharedFolders'] = []
    atomic_plist(vm / '.vbdata/Config.plist', configuration)


@functools.lru_cache(maxsize=1)
def macos_capacity_api():
    core = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    foundation = ctypes.CDLL('/System/Library/Frameworks/Foundation.framework/Foundation')
    pointer = ctypes.c_void_p
    for name, arguments, result in (
        ('CFURLCreateFromFileSystemRepresentation', [pointer, ctypes.c_char_p, ctypes.c_long, ctypes.c_ubyte], pointer),
        ('CFURLCopyResourcePropertyForKey', [pointer, pointer, ctypes.POINTER(pointer), ctypes.POINTER(pointer)], ctypes.c_ubyte),
        ('CFGetTypeID', [pointer], ctypes.c_ulong),
        ('CFNumberGetTypeID', [], ctypes.c_ulong),
        ('CFNumberGetValue', [pointer, ctypes.c_long, pointer], ctypes.c_ubyte),
        ('CFRelease', [pointer], None),
    ):
        function = getattr(core, name)
        function.argtypes, function.restype = arguments, result
    key = pointer.in_dll(foundation, 'NSURLVolumeAvailableCapacityForImportantUsageKey')
    return core, foundation, key


def macos_available_capacity(path):
    if sys.platform != 'darwin':
        return None
    try:
        core, _, key = macos_capacity_api()
    except (OSError, AttributeError, ValueError):
        return None
    value, error = ctypes.c_void_p(), ctypes.c_void_p()
    encoded = os.fsencode(Path(path).absolute())
    url = core.CFURLCreateFromFileSystemRepresentation(None, encoded, len(encoded), True)
    if not url:
        return None
    try:
        if (not core.CFURLCopyResourcePropertyForKey(url, key, ctypes.byref(value), ctypes.byref(error)) or
                not value.value or core.CFGetTypeID(value) != core.CFNumberGetTypeID()):
            return None
        capacity = ctypes.c_int64()
        if not core.CFNumberGetValue(value, 4, ctypes.byref(capacity)) or capacity.value < 0:
            return None
        return capacity.value
    finally:
        for resource in (value, error, url):
            if resource:
                core.CFRelease(resource)


def check_capacity(state, minimum):
    usage = shutil.disk_usage(state)
    estimate = macos_available_capacity(state)
    estimated = type(estimate) is int and 0 <= estimate <= usage.total
    available = estimate if estimated else usage.free
    if available < minimum:
        raise RunnerError(f'Insufficient host disk space: {available / 1024**3:.1f} GiB available '
                          f'({usage.free / 1024**3:.1f} GiB currently free); '
                          f'{minimum / 1024**3:.1f} GiB reserve required')
    return {'availableBytes': available, 'freeBytes': usage.free,
            'capacitySource': 'macOSImportantUsage' if estimated else 'filesystemFree'}


@contextlib.contextmanager
def execution_lock(state):
    descriptor = os.open(state / 'runner.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RunnerError('Another VM operation is active; use status or stop')
        yield
    finally:
        os.close(descriptor)


def build_tools(state, xcode=Path('/Applications/Xcode.app')):
    environment = dict(os.environ, DEVELOPER_DIR=str(xcode / 'Contents/Developer'))
    version = checked(['/usr/bin/xcrun', 'swiftc', '--version'], env=environment)
    binaries = {}
    digests = {}
    for name in ('VMHost', 'VMGuestAgent'):
        source = TOOLS / (name + '.swift')
        source_bytes = source.read_bytes()
        entitlements = (TOOLS / 'virtualization.entitlements').read_bytes() if name == 'VMHost' else None
        identity = 'org.lil.big-wallet.vm.' + name
        material = b'vm-tools-v4\0swift6-O\0' + version + b'\0' + name.encode() + b'\0' + source_bytes
        if entitlements is not None:
            material += b'\0' + entitlements
        digest = hashlib.sha256(material).hexdigest()[:20]
        digests[name] = digest
        cache = private_directory(state / 'tools' / (name + '-' + digest))
        executable = cache / name
        if not executable.exists():
            temporary_directory = private_directory(cache / ('.build-' + uuid.uuid4().hex))
            temporary = temporary_directory / name
            try:
                captured_source = temporary_directory / source.name
                captured_source.write_bytes(source_bytes)
                checked(['/usr/bin/xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                         '-O', '-module-name', name, captured_source, '-o', temporary], env=environment)
                arguments = ['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', identity]
                if entitlements is not None:
                    captured_entitlements = temporary_directory / 'virtualization.entitlements'
                    captured_entitlements.write_bytes(entitlements)
                    arguments += ['--entitlements', captured_entitlements]
                checked(arguments + [temporary])
                temporary.replace(executable)
            finally:
                shutil.rmtree(temporary_directory)
        with open_regular(executable):
            pass
        binaries[name] = executable
    collection = hashlib.sha256(json.dumps(digests, sort_keys=True).encode()).hexdigest()[:20]
    output = private_directory(state / 'tools' / 'sets' / collection)
    for name, executable in binaries.items():
        target = output / name
        if not target.exists():
            os.link(executable, target, follow_symlinks=False)
        elif target.is_symlink() or not target.samefile(executable):
            raise RunnerError(f'Compiled tool collection does not match its cache: {name}')
    return output


def hash_regular_file(path):
    digest = hashlib.sha256()
    with open_regular(path) as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def setup_viewer_binary(state, binaries, *, safari=False):
    source = Path(binaries) / 'VMHost'
    identifier = 'org.lil.big-wallet.vm.safari-viewer' if safari else 'org.lil.big-wallet.vm.setup-viewer'
    name = 'Big Wallet Test VM Safari' if safari else 'Big Wallet Test VM Setup'
    info = {'CFBundleIdentifier': identifier, 'CFBundleName': name, 'CFBundleDisplayName': name,
            'CFBundleExecutable': 'VMHost', 'CFBundlePackageType': 'APPL', 'CFBundleInfoDictionaryVersion': '6.0',
            'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1', 'CFBundleSupportedPlatforms': ['MacOSX'],
            'LSMinimumSystemVersion': '27.0', 'NSHighResolutionCapable': True, 'NSPrincipalClass': 'NSApplication'}
    metadata = plistlib.dumps(info, sort_keys=True)
    entitlements = TOOLS / 'virtualization.entitlements'
    digest = hashlib.sha256(b'setup-viewer-v1\0' + hash_regular_file(source).encode() + b'\0' +
                            entitlements.read_bytes() + b'\0' + metadata).hexdigest()[:20]
    cache = private_directory(Path(state) / 'tools' / ('setup-viewer-' + digest))
    bundle = cache / (name + '.app')
    if not bundle.exists():
        staging = private_directory(cache / ('.build-' + uuid.uuid4().hex))
        temporary_bundle = staging / bundle.name
        try:
            executable_directory = temporary_bundle / 'Contents/MacOS'
            executable_directory.mkdir(parents=True)
            (temporary_bundle / 'Contents/Info.plist').write_bytes(metadata)
            executable = executable_directory / 'VMHost'
            shutil.copyfile(source, executable)
            executable.chmod(0o755)
            checked(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', identifier,
                     '--entitlements', entitlements, temporary_bundle])
            temporary_bundle.replace(bundle)
        finally:
            shutil.rmtree(staging)
    if bundle.is_symlink():
        raise RunnerError('Setup viewer bundle may not be a symlink')
    with open_regular(bundle / 'Contents/Info.plist') as file:
        if plistlib.load(file) != info:
            raise RunnerError('Cached setup viewer metadata does not match its identity')
    executable = bundle / 'Contents/MacOS/VMHost'
    with open_regular(executable):
        pass
    checked(['/usr/bin/codesign', '--verify', '--strict', bundle])
    return executable


def xcode_archive_location(state, xcode, environment):
    xcode = Path(xcode)
    if xcode.is_symlink() or not xcode.is_dir() or xcode.name != 'Xcode.app':
        raise RunnerError('Xcode archive source must be a real Xcode.app directory')
    with open_regular(xcode / 'Contents/version.plist') as file:
        installed = plistlib.load(file)
    expected = environment['xcode']
    if (installed.get('CFBundleShortVersionString'), installed.get('ProductBuildVersion')) != (
            expected['version'], expected['buildVersion']):
        raise RunnerError('Installed Xcode does not match the pinned archive version/build')
    identity = {'version': 1, 'xcodeVersion': expected['version'], 'xcodeBuild': expected['buildVersion'],
                'codeResourcesSHA256': hash_regular_file(xcode / 'Contents/_CodeSignature/CodeResources')}
    digest = hashlib.sha256(json.dumps(identity, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    directory = private_directory(Path(state) / 'tools' / ('xcode-archive-' + digest))
    return directory, identity


def publish_completed_xcode_archive(state, xcode, environment, completed):
    completed = Path(completed)
    if completed.is_symlink() or not completed.resolve().is_relative_to((Path(state) / 'tools').resolve()):
        raise RunnerError('Completed Xcode archive must be a regular runner-owned tools file')
    directory, identity = xcode_archive_location(state, xcode, environment)
    sha256 = hash_regular_file(completed)
    size = completed.stat().st_size
    if size == 0:
        raise RunnerError('Completed Xcode archive is empty')
    destination = directory / 'Xcode.tar'
    if completed != destination:
        completed.replace(destination)
    digest_file = directory / 'Xcode.tar.sha256'
    temporary = directory / ('sha256.' + uuid.uuid4().hex + '.tmp')
    try:
        with open(temporary, 'x', encoding='ascii') as file:
            file.write(sha256 + '\n')
            file.flush()
            os.fsync(file.fileno())
        temporary.replace(digest_file)
    finally:
        temporary.unlink(missing_ok=True)
    atomic_json(directory / 'identity.json', {**identity, 'sha256': sha256, 'bytes': size})
    return destination, sha256


def cached_xcode_archive(state, xcode, environment):
    directory, identity = xcode_archive_location(state, xcode, environment)
    destination = directory / 'Xcode.tar'
    digest_file = directory / 'Xcode.tar.sha256'
    receipt = directory / 'identity.json'
    if destination.exists() and digest_file.exists() and receipt.exists():
        with open_regular(digest_file) as file:
            digest = file.read(128).decode('ascii').strip()
        recorded = read_json(receipt)
        if (len(digest) != 64 or any(character not in '0123456789abcdef' for character in digest) or
                any(recorded.get(key) != value for key, value in identity.items()) or
                recorded.get('sha256') != digest or recorded.get('bytes') != destination.stat().st_size or
                hash_regular_file(destination) != digest):
            raise RunnerError('Cached Xcode archive failed its identity or SHA-256 check')
        return destination, digest
    temporary = directory / ('Xcode.' + uuid.uuid4().hex + '.tar')
    try:
        checked(['/usr/bin/codesign', '--verify', '--strict', xcode])
        checked(['/usr/bin/tar', '-cf', temporary, '-C', Path(xcode).parent, 'Xcode.app'],
                env=dict(os.environ, COPYFILE_DISABLE='1'))
        _, after = xcode_archive_location(state, xcode, environment)
        if after != identity:
            raise RunnerError('Xcode changed while its archive was being created; retry setup')
        return publish_completed_xcode_archive(state, xcode, environment, temporary)
    finally:
        temporary.unlink(missing_ok=True)


def bootstrap_tool_hashes(binaries):
    return {name: hashlib.sha256((binaries / name if name == 'VMGuestAgent' else TOOLS / name).read_bytes()).hexdigest()
            for name in ('VMGuestAgent', 'guest_runner', 'guest_bootstrap.mjs')}


def bootstrap_source_digest(directory=None):
    directory = TOOLS if directory is None else Path(directory)
    names = ('VMGuestAgent.swift', 'guest_runner', 'guest_bootstrap.mjs',
             'provision_guest.sh', 'environment.json')
    return hashlib.sha256(b''.join(name.encode() + b'\0' + (directory / name).read_bytes() for name in names)).hexdigest()


def require_current_bootstrap_sources(expected):
    if bootstrap_source_digest() != expected:
        raise RunnerError('Guest bootstrap sources changed during setup; rerun setup before verifying this candidate')


def verify_setup_sources(exchange, expected, environment, configuration=None, bootstrap_tools=None):
    snapshot = exchange / 'source/Scripts/vm'
    require_current_bootstrap_sources(expected)
    if bootstrap_source_digest(snapshot) != expected or read_json(snapshot / 'environment.json') != environment:
        raise RunnerError('The setup source snapshot does not match the captured guest bootstrap and environment')
    if configuration is None:
        return
    provision = exchange / 'provision'
    staged = read_json(provision / 'config.json')
    staged_environment = {key: staged.get(key) for key in environment}
    staged_environment['runtimes'] = [{key: runtime.get(key) for key in ('platform', 'version', 'buildVersion')}
                                    for runtime in staged.get('runtimes', [])]
    if staged != configuration or staged_environment != environment:
        raise RunnerError('The staged setup configuration does not match the requested guest environment')
    for name in ('guest_runner', 'guest_bootstrap.mjs', 'provision_guest.sh'):
        digest = hash_regular_file(snapshot / name)
        if hash_regular_file(provision / name) != digest or name in bootstrap_tools and bootstrap_tools[name] != digest:
            raise RunnerError('The staged guest installer does not match the captured setup source')
    if hash_regular_file(provision / 'VMGuestAgent') != bootstrap_tools['VMGuestAgent']:
        raise RunnerError('The staged guest agent does not match the captured bootstrap tools')


def node_planning_environment():
    return {key: os.environ[key] for key in ('PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL') if key in os.environ}


def manifest_node():
    executable = shutil.which('node')
    if not executable:
        raise RunnerError('Host Node.js 18 or newer is required for pure test-plan generation; no guest commands were started')
    try:
        version = checked([executable, '--version'], env=node_planning_environment(), text=True, timeout=10).strip()
    except subprocess.TimeoutExpired as error:
        raise RunnerError('Host Node.js did not respond while checking test-plan prerequisites') from error
    major = version.removeprefix('v').split('.', 1)[0]
    if not version.startswith('v') or not major.isdigit() or int(major) < 18:
        raise RunnerError('Host Node.js 18 or newer is required for pure test-plan generation')
    return {'executable': executable, 'version': version}


def stage_planned_result(exchange, job):
    manifest_path = exchange / 'source/Scripts/vm/test_manifest.mjs'
    if hash_regular_file(exchange / 'snapshot-manifest.json') != job['source']['sha256']:
        raise RunnerError('The staged source snapshot does not match the planned job')
    snapshot = read_json(exchange / 'snapshot-manifest.json')
    for relative in ('Scripts/vm/test_manifest.mjs', 'Scripts/safari/scenarios.mjs', 'Scripts/safari/synchronization.mjs',
                     'Scripts/vm/environment.json', 'Scripts/vm/runtime_inventory.mjs', 'Scripts/vm/runtime-test-inventory.json',
                     'Scripts/wallet_upgrade/contract.mjs'):
        entries = [entry for entry in snapshot['files'] if entry.get('path') == relative]
        if (len(entries) != 1 or entries[0].get('type') != 'file' or
                hash_regular_file(exchange / 'source' / relative) != entries[0].get('sha256')):
            raise RunnerError(f'The snapshotted test manifest dependency does not match the source identity: {relative}')
    job_path = exchange / 'job.json'
    if read_json(job_path) != job:
        raise RunnerError('The staged job does not match the requested test plan')
    node = manifest_node()
    try:
        stages = json.loads(checked([node['executable'], TOOLS / 'plan_manifest.mjs', manifest_path],
                                   input=json.dumps(job).encode(), env=node_planning_environment(), timeout=30))
    except subprocess.TimeoutExpired as error:
        raise RunnerError('Pure test-plan generation timed out; no VM was started') from error
    result = {'version': 1, 'runId': job['runId'], 'vmId': job['vmId'], 'kind': job['kind'],
              'profile': job['profile'], 'status': 'planned', 'origin': 'host-plan',
              'plannedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'source': job['source'], 'jobSHA256': hash_regular_file(job_path), 'stages': stages,
              'selection': job_selection(job)}
    atomic_json(exchange / 'artifacts/planned-result.json', result)
    return result


def job_selection(job):
    payload = job['payload']
    return {'signing': payload.get('signing', 'local'),
            **{key: payload[key] for key in ('stages', 'onlyTesting', 'configuration', 'approvalArgs', 'runtimePlatforms',
                                            'interactiveSafari', 'prepareSafari', 'preparedSafari') if key in payload}}


def host_doctor(args, state, environment):
    checks = []
    def check(name, action):
        try:
            detail = action()
            checks.append({'name': name, 'status': 'passed', 'detail': detail})
        except (RunnerError, OSError, ValueError) as error:
            checks.append({'name': name, 'status': 'blocked', 'detail': str(error)})
    check('vm', lambda: {'cpuCount': validate_vm(args.vm)['hardware']['cpuCount'],
                        'memoryBytes': validate_vm(args.vm)['hardware']['memorySize']})
    check('disk', lambda: check_capacity(state, environment['minimumHostFreeBytes']))
    check('manifestNode', manifest_node)
    def xcode():
        with open_regular(args.xcode / 'Contents/version.plist') as file:
            version = plistlib.load(file)
        installed = {'version': version.get('CFBundleShortVersionString'), 'buildVersion': version.get('ProductBuildVersion')}
        if (version.get('CFBundleShortVersionString'), version.get('ProductBuildVersion')) != (
                environment['xcode']['version'], environment['xcode']['buildVersion']):
            raise RunnerError(f'Installed Xcode {installed["version"]} ({installed["buildVersion"]}) does not match '
                              f'pinned Xcode {environment["xcode"]["version"]} ({environment["xcode"]["buildVersion"]}); '
                              'run Scripts/test_vm.sh upgrade-xcode --check, then upgrade-xcode')
        return {'installed': installed, 'pinned': environment['xcode']}
    check('xcode', xcode)
    def baseline():
        record = read_json(state / 'baseline.json')
        if record.get('environment') != environment or record.get('bootstrapSourceDigest') != bootstrap_source_digest():
            raise RunnerError('Prepared baseline needs the current guest bootstrap/environment; run setup')
        if not matches_source_vm(record, args.vm):
            raise RunnerError('Prepared baseline belongs to another source VM')
        return {'verifiedAt': record.get('verifiedAt'), 'vmId': record['vmId'],
                'verificationSigningMode': record.get('verificationSigningMode')}
    check('baseline', baseline)
    return {'version': 1, 'status': 'passed' if all(c['status'] == 'passed' for c in checks) else 'blocked',
            'scope': 'host prerequisites; guest readiness is verified during setup and each run',
            'checks': checks, 'sourceVM': str(args.vm), 'stateDirectory': str(state)}


def copy_provision_input(configuration, input_directory, destination):
    for group, keys in [('signing', ('p12Path', 'p12PasswordFile', 'keychainPasswordFile', 'proofKeyFile')),
                        ('autologin', ('passwordFile',))]:
        values = configuration.get(group, {})
        for key in keys:
            if key not in values:
                continue
            original = Path(values[key])
            if not original.is_absolute():
                original = input_directory / original
            contents = original.read_bytes()
            name = f'{group}-{key}'
            output = destination / name
            output.write_bytes(contents)
            output.chmod(0o600)
            values[key] = name
    signing = configuration.get('signing', {})
    profiles = []
    for index, value in enumerate(signing.get('profiles', [])):
        original = Path(value)
        if not original.is_absolute():
            original = input_directory / original
        name = f'profile-{index}{original.suffix}'
        shutil.copyfile(original, destination / name)
        profiles.append(name)
    if 'profiles' in signing:
        configuration['signing']['profiles'] = profiles
    for index, runtime in enumerate(configuration.get('runtimes', [])):
        if runtime.get('dmgPath'):
            original = Path(runtime['dmgPath'])
            if not original.is_absolute():
                original = input_directory / original
            name = f'runtime-{index}.dmg'
            checked(['/bin/cp', '-c', original, destination / name])
            runtime['dmgPath'] = name


def selected_console_user(args, record, supplied=None):
    supplied = supplied if supplied is not None else read_json(args.provision_config) if args.provision_config else {}
    configured = supplied.get('consoleUser')
    if ('consoleUser' in supplied and not isinstance(configured, str)) or args.guest_user == '' or configured == '':
        raise RunnerError('The selected guest console user is invalid')
    if args.guest_user is not None and configured is not None and args.guest_user != configured:
        raise RunnerError('--guest-user and provision-config consoleUser must agree')
    pending = record.get('pendingProvisioning', {})
    user = args.guest_user or configured or pending.get('consoleUser') or record.get('consoleUser') or 'wallet-test'
    if not isinstance(user, str) or re.fullmatch(r'[A-Za-z0-9_-]+', user) is None:
        raise RunnerError('The selected guest console user is invalid')
    return user


def provisioning_inputs_requested(args, record):
    current_user = record.get('pendingProvisioning', {}).get('consoleUser') or record.get('consoleUser')
    return bool(args.provision_config or args.proof_key_bundle or getattr(args, 'provision_new_account', False) or
                args.guest_user is not None and args.guest_user != current_user)


def validate_guest_password_options(new_account, autologin):
    if new_account and isinstance(autologin, dict) and 'passwordFile' in autologin:
        raise RunnerError('New-account provisioning cannot be combined with autologin.passwordFile. '
                          'Omit that field to use the generated account password, or omit '
                          '--provision-new-account/provisionNewAccount to use an existing account.')


def pending_provisioning_package(state, record):
    pending = record['pendingProvisioning']
    try:
        valid_id = str(uuid.UUID(pending['id'])) == pending['id']
        source = Path(pending['path'])
    except (KeyError, TypeError, ValueError):
        raise RunnerError('Pending guest provisioning identity is invalid')
    if (not valid_id or not source.is_absolute() or source.name != 'provision' or source.is_symlink() or
            source.resolve() != source or not source.is_relative_to(state / 'setup') or not source.is_dir() or
            source.stat().st_uid != os.getuid()):
        raise RunnerError('Pending provisioning must remain in its runner-owned setup directory')
    configuration = read_json(source / 'config.json')
    if (configuration.get('provisioningRequestID') != pending['id'] or configuration.get('vmId') != record['vmId'] or
            configuration.get('consoleUser') != pending.get('consoleUser')):
        raise RunnerError('Pending provisioning package does not match its recorded identity')
    if configuration.get('provisionNewAccount') and pending.get('initialAccountPasswordPath') != str(state / 'initial-guest-password'):
        raise RunnerError('Pending initial account provisioning has no matching private password path')
    validate_guest_password_options(configuration.get('provisionNewAccount'), configuration.get('autologin'))
    return source, configuration


def stage_provisioning(args, state, exchange, environment, record, binaries):
    destination = private_directory(exchange / 'provision')
    if record.get('pendingProvisioning') and not provisioning_inputs_requested(args, record):
        source, configuration = pending_provisioning_package(state, record)
        staged_environment = {key: configuration.get(key) for key in environment}
        if 'runtimes' in staged_environment:
            staged_environment['runtimes'] = [{key: runtime.get(key) for key in ('platform', 'version', 'buildVersion')}
                                               for runtime in configuration.get('runtimes', [])]
        expected_tools = bootstrap_tool_hashes(binaries)
        expected_tools['provision_guest.sh'] = hash_regular_file(TOOLS / 'provision_guest.sh')
        if (staged_environment != environment or any(not (source / name).is_file() or
                hash_regular_file(source / name) != digest for name, digest in expected_tools.items())):
            retained = argparse.Namespace(**vars(args))
            retained.provision_config = source / 'config.json'
            return stage_provisioning(retained, state, exchange, environment, record, binaries)
        for item in source.iterdir():
            with open_regular(item):
                pass
            checked(['/bin/cp', '-c', item, destination / item.name])
        return configuration
    configuration = json.loads(json.dumps(environment))
    supplied = read_json(args.provision_config) if args.provision_config else {}
    if not isinstance(supplied.get('provisionNewAccount', False), bool):
        raise RunnerError('provisionNewAccount must be a boolean')
    configuration.update({'vmId': record['vmId'], 'consoleUser': selected_console_user(args, record, supplied),
                          'provisionNewAccount': bool(getattr(args, 'provision_new_account', False) or supplied.get('provisionNewAccount', False)),
                          'initializeBuildData': record.get('buildDataInitializationAllowed', False)})
    validate_guest_password_options(configuration['provisionNewAccount'], supplied.get('autologin'))
    if provisioning_inputs_requested(args, record):
        configuration['provisioningRequestID'] = str(uuid.uuid4())
    archive, archive_digest = cached_xcode_archive(state, args.xcode, environment)
    checked(['/bin/cp', '-c', archive, destination / 'Xcode.tar'])
    configuration['xcodeArchive'] = {'path': 'Xcode.tar', 'sha256': archive_digest}
    if args.provision_config:
        for key in ('signing', 'autologin'):
            if key in supplied:
                configuration[key] = supplied[key]
        for runtime, override in zip(configuration['runtimes'], supplied.get('runtimes', [])):
            if runtime['platform'] != override['platform']:
                raise RunnerError('Provisioning runtime order must match environment.json')
            if 'dmgPath' in override:
                runtime['dmgPath'] = override['dmgPath']
        copy_provision_input(configuration, args.provision_config.parent, destination)
    if args.proof_key_bundle:
        proof_path = args.proof_key_bundle / 'Contents/Resources/AlchemyJWTRequestProofKey'
        with open_regular(proof_path) as file:
            proof = file.read()
        expected = (ROOT / 'Scripts/alchemy_jwt_request_proof_key.sha256').read_text().strip()
        if len(proof) != 43 or hashlib.sha256(proof).hexdigest() != expected:
            raise RunnerError('App bundle proof key does not match the repository fingerprint')
        (destination / 'proof-key').write_bytes(proof)
        (destination / 'proof-key').chmod(0o600)
        configuration.setdefault('signing', {})['proofKeyFile'] = 'proof-key'
    for name in ('provision_guest.sh', 'guest_runner', 'guest_bootstrap.mjs'):
        shutil.copyfile(TOOLS / name, destination / name)
    shutil.copyfile(binaries / 'VMGuestAgent', destination / 'VMGuestAgent')
    shutil.copyfile(ROOT / 'Scripts/alchemy_jwt_request_proof_key.sha256',
                    destination / 'alchemy_jwt_request_proof_key.sha256')
    for name in ('provision_guest.sh', 'guest_runner', 'VMGuestAgent'):
        (destination / name).chmod(0o755)
    atomic_json(destination / 'config.json', configuration)
    return configuration


def setup_provisioning_issue(result, vm_id, console_user, request_id=None):
    identity = result.get('identity', {})
    if identity.get('vmId') != vm_id or identity.get('consoleUser') != console_user:
        return 'guest_account_does_not_match_requested_setup'
    if request_id is not None:
        receipt = result.get('preflight', {}).get('provisioning', {})
        if (receipt.get('vmId') != vm_id or receipt.get('consoleUser') != console_user or
                receipt.get('appliedRequestID') != request_id):
            return 'requested_guest_provisioning_not_applied'
    return None


def clear_applied_provisioning_packages(state, vm_id, request_id):
    if request_id is None:
        return
    for directory in (state / 'setup').glob('setup-*/provision'):
        if directory.is_symlink() or directory.resolve() != directory or directory.stat().st_uid != os.getuid():
            continue
        config_path = directory / 'config.json'
        if not config_path.exists():
            continue
        configuration = read_json(config_path)
        if configuration.get('vmId') == vm_id and configuration.get('provisioningRequestID') == request_id:
            shutil.rmtree(directory)


def stop_owned_process(process, stop_file):
    try:
        stop_file.touch(exist_ok=True)
    except OSError:
        process.terminate()
    try:
        process.wait(timeout=40)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


@contextlib.contextmanager
def clone_cancellation_signals():
    original_handlers = {}
    def interrupt(signum, frame):
        raise KeyboardInterrupt
    try:
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            original_handlers[signum] = signal.signal(signum, interrupt)
        yield
    finally:
        for signum, handler in original_handlers.items():
            signal.signal(signum, handler)


def register_operation(state, vm, exchange, run_id, phase, previous=None, *, clone_owned=False):
    path = state / 'active.json'
    identity = {'runId': run_id, 'vm': str(vm), 'exchange': str(exchange), 'ownerPID': os.getpid()}
    if path.exists():
        active = read_json(path)
        if any(active.get(key) != value for key, value in identity.items()):
            if (previous is None or active.get('runId') != previous[0] or
                    active.get('exchange') != str(previous[1]) or active.get('vm') != str(vm) or
                    active.get('ownerPID') != os.getpid()):
                raise RunnerError('Another operation owns the active VM record')
            active.update(identity)
    else:
        active = {'version': 1, **identity, 'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    active['phase'] = phase
    active.pop('acceptedResultSHA256', None)
    active.pop('artifactsExported', None)
    active.pop('pendingTermination', None)
    if clone_owned:
        active['cloneOwned'] = True
    atomic_json(path, active)


def clear_owned_operation(state, run_id):
    path = state / 'active.json'
    if path.exists():
        active = read_json(path)
        if active.get('runId') == run_id and active.get('ownerPID') == os.getpid():
            path.unlink()


def retain_clone_diagnostics(active):
    if active.get('phase') == 'preparing' or active.get('artifactsExported') is True:
        return False
    receipt = Path(active['exchange']) / 'retained-vm.json'
    atomic_json(receipt, {'version': 1, 'runId': active['runId'], 'vm': active['vm'],
                          'reason': 'artifacts_not_collected'})
    print(f'Diagnostics remain in the stopped VM: {active["vm"]}\nRetention record: {receipt}', flush=True)
    return True


def accepted_operation_result(active):
    expected = active.get('acceptedResultSHA256')
    if not expected:
        return False
    path = Path(active['exchange']) / 'artifacts/result.json'
    try:
        result = read_json(path)
        return (isinstance(result, dict) and result.get('runId') == active['runId'] and result.get('finishedAt') and
                result.get('status') in ('passed', 'failed', 'blocked', 'cancelled') and hash_regular_file(path) == expected)
    except (OSError, ValueError, RunnerError):
        return False


def completed_safari_preparation(state, active):
    if active.get('vm') != str(state / 'candidate.vbvm') or not accepted_operation_result(active):
        return False
    result_path = Path(active['exchange']) / 'artifacts/result.json'
    if read_json(result_path).get('status') != 'passed':
        return False
    for path in (state / 'candidate.json', state / 'baseline.json'):
        if not path.exists():
            continue
        record = read_json(path)
        if (isinstance(record, dict) and (record.get('promotionPending') or record.get('verifiedAt')) and
                record.get('safariPreparationResult') == str(result_path) and
                isinstance(record.get('safariPreparation'), dict) and
                record.get('safariPreparation', {}).get('preparationRunID') == active['runId']):
            return True
    return False


def operation_stop_record(exchange, run_id):
    path = exchange / 'stop.json'
    if not path.exists():
        return None
    value = read_json(path)
    if (not isinstance(value, dict) or set(value) != {'version', 'runId', 'requestCount'} or
            type(value['version']) is not int or value['version'] != 1 or
            not isinstance(value['runId'], str) or type(value['requestCount']) is not int or
            not 0 <= value['requestCount'] <= 2):
        raise RunnerError('Invalid host stop record')
    return value if value['runId'] == run_id else None


def operation_stop_requested(exchange, run_id):
    return operation_stop_record(exchange, run_id) is not None


def publish_stop(exchange, run_id, *, requested=False):
    descriptor = os.open(exchange / 'stop.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or
                info.st_nlink != 1 or info.st_mode & 0o077):
            raise RunnerError('Invalid host stop lock')
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        current = operation_stop_record(exchange, run_id)
        if current is None and (exchange / 'stop.json').exists():
            raise RunnerError('Host stop record belongs to another operation')
        count = current['requestCount'] if current else 0
        atomic_json(exchange / 'stop.json', {'version': 1, 'runId': run_id,
                                           'requestCount': min(2, count + int(requested))})
    finally:
        os.close(descriptor)


def finalize_interrupted_result(exchange, run_id, reason, guest_failure=None, host_error=None):
    result_path = exchange / 'artifacts/result.json'
    guest_report = result_path.exists()
    planned_path = result_path.with_name('planned-result.json')
    invalid_result = result_path.with_name('guest-result-invalid.json')
    if guest_report:
        try:
            result = read_json(result_path)
            if not isinstance(result, dict) or result.get('runId') != run_id:
                raise ValueError('Invalid guest report identity')
        except ValueError:
            result_path.replace(invalid_result)
            guest_report = False
    if not guest_report:
        result = read_json(planned_path) if planned_path.exists() else {}
    if result and result.get('runId') != run_id:
        raise RunnerError('Guest returned a result for a different run')
    if result and guest_report and not result.get('hostTermination'):
        completed = bool(result.get('finishedAt'))
        original = 'guest-result-after-stop.json' if completed else 'guest-result-interrupted.json'
        atomic_json(result_path.with_name(original), result)
        result['guestResultAfterStop' if completed else 'interruptedGuestResult'] = original
    elif result and not guest_report:
        job = read_json(exchange / 'job.json')
        if (result.get('origin') != 'host-plan' or result.get('status') != 'planned' or
                job.get('runId') != run_id or result.get('vmId') != job.get('vmId') or
                result.get('source') != job.get('source') or
                result.get('jobSHA256') != hash_regular_file(exchange / 'job.json') or
                hash_regular_file(exchange / 'snapshot-manifest.json') != result['source']['sha256']):
            raise RunnerError('The planned inventory does not match the interrupted job and source snapshot')
        result['plannedResult'] = planned_path.name
    job_path = exchange / 'job.json'
    if job_path.exists():
        job = read_json(job_path)
        if job.get('runId') != run_id:
            raise RunnerError('The interrupted job belongs to a different run')
        if isinstance(job.get('payload'), dict):
            result['selection'] = job_selection(job)
    finished_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
    status = ('cancelled' if reason == 'cancelled' else
              'failed' if reason in ('timed_out', 'guest_launch_failed', 'guest_exited_without_result', 'guest_exchange_failed',
                                    'vm_clone_failed', 'vm_launch_failed', 'host_preparation_failed',
                                    'host_monitor_failed') else 'blocked')
    result.update({'version': 1, 'runId': run_id, 'status': status, 'reason': reason,
                   'finishedAt': finished_at, 'hostTermination': {'reason': reason, 'finishedAt': finished_at}})
    for stage in result.get('stages', []):
        if stage.get('status') not in ('passed', 'failed', 'blocked', 'cancelled'):
            stage.update({'status': 'cancelled' if reason == 'cancelled' else 'blocked',
                          'reason': reason, 'finishedAt': finished_at})
    counts = {outcome: sum(stage.get('status') == outcome for stage in result.get('stages', []))
              for outcome in ('passed', 'failed', 'blocked', 'cancelled')}
    summary = result.setdefault('summary', {})
    summary.update({'status': status, 'counts': counts})
    summary.setdefault('issues', []).append(f'Host terminated the run: {reason}')
    coverage = result.setdefault('coverage', {})
    coverage.update({'status': 'partial', 'fullSuiteVerified': False})
    incomplete = {stage['id']: stage for stage in coverage.get('incompleteStages', [])}
    for stage in result.get('stages', []):
        if stage.get('status') != 'passed':
            incomplete[stage['id']] = {'id': stage['id'], 'status': stage['status']}
    coverage['incompleteStages'] = list(incomplete.values())
    if guest_failure:
        result['guestFailure'] = guest_failure
    if host_error:
        result['hostTermination']['error'] = host_error
    status_path = exchange / 'vm-status.json'
    invalid_status = status_path.with_name('vm-status-invalid.json')
    if status_path.exists():
        try:
            status = read_json(status_path)
            if not isinstance(status, dict):
                raise ValueError('Invalid VM status record')
            result['vm'] = status
        except ValueError:
            status_path.replace(invalid_status)
    if invalid_result.exists():
        result['invalidGuestResult'] = invalid_result.name
    if invalid_status.exists():
        result['invalidVMStatus'] = invalid_status.name
    atomic_json(result_path, result)
    return result


def finalize_owned_interruption(state, exchange, run_id, reason, guest_failure=None, host_error=None):
    path = state / 'active.json'
    active = read_json(path)
    if (active.get('runId') != run_id or active.get('exchange') != str(exchange) or
            active.get('ownerPID') != os.getpid()):
        raise RunnerError('Another operation owns the interrupted VM record')
    active.pop('acceptedResultSHA256', None)
    active['pendingTermination'] = {'reason': reason, 'guestFailure': guest_failure, 'hostError': host_error}
    atomic_json(path, active)
    return finalize_interrupted_result(exchange, run_id, reason, guest_failure, host_error)


def monitor_vm(args, state, vm, exchange, run_id, binaries, environment, timeout, provision_password=None,
               *, keep_operation=False, previous_stops=(), setup_hook=None):
    result = monitor_owned_vm(args, state, vm, exchange, run_id, binaries, environment, timeout,
                              provision_password, previous_stops=previous_stops, setup_hook=setup_hook)
    path = state / 'active.json'
    active = read_json(path)
    if (active.get('runId') != run_id or active.get('exchange') != str(exchange) or
            active.get('ownerPID') != os.getpid()):
        raise RunnerError('Another operation owns the completed VM record')
    result_path = exchange / 'artifacts/result.json'
    if read_json(result_path) != result:
        raise RunnerError('The completed report changed before the host could accept it')
    active['acceptedResultSHA256'] = hash_regular_file(result_path)
    if active.get('phase') == 'preparing' or setup_hook is not None and setup_hook.exchange_complete is True:
        active['artifactsExported'] = True
    atomic_json(path, active)
    if not keep_operation:
        clear_owned_operation(state, run_id)
    return result


def monitor_owned_vm(args, state, vm, exchange, run_id, binaries, environment, timeout, provision_password=None,
                     *, previous_stops=(), setup_hook=None):
    setup_window = args.command == 'setup' and getattr(args, 'interactive', False)
    safari_window = args.command == 'run' and getattr(args, 'interactive_safari', False)
    host_binary = setup_viewer_binary(state, binaries, safari=safari_window) if setup_window or safari_window else Path(binaries) / 'VMHost'
    status_path = exchange / 'vm-status.json'
    stop_file = exchange / 'vm-stop'
    register_operation(state, vm, exchange, run_id, 'preparing')
    command = [str(host_binary), '--vm', str(vm),
               '--status', str(status_path), '--stop-file', str(stop_file), '--owner-pid', str(os.getpid())]
    if setup_window:
        command.append('--setup-window')
    if safari_window:
        command.append('--safari-window')
    if provision_password:
        command += ['--provision-user', args.guest_user, '--provision-password-file', str(provision_password)]
    result_path = exchange / 'artifacts/result.json'
    deadline = time.monotonic() + timeout
    cancelled = False
    cancellation_signals = 0
    stop_scopes = tuple(dict.fromkeys(((exchange, run_id), *previous_stops)))
    original_handlers = {}
    def cancel(signum, _):
        nonlocal cancelled, cancellation_signals
        cancelled = True
        cancellation_signals += 1
    def cancellation_requested():
        return cancelled or any(operation_stop_requested(*scope) for scope in stop_scopes)
    def result_exported(result):
        return (setup_hook is None or result.get('kind') == 'prepare' or
                setup_hook.exchange_complete is True)
    def interruption_reason():
        if cancellation_requested():
            return 'cancelled'
        if time.monotonic() >= deadline:
            return 'guest_access_required' if args.command == 'setup' else 'timed_out'
        return None
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        original_handlers[signum] = signal.signal(signum, cancel)
    reason = None
    guest_failure = None
    capacity_error = None
    process = None
    shutdown_confirmed = False
    accepted_result = False
    finalizing = False
    def failure_reason(error):
        if cancelled or isinstance(error, KeyboardInterrupt):
            return 'cancelled'
        if reason:
            return reason
        try:
            interrupted = interruption_reason()
        except (RunnerError, OSError, ValueError):
            interrupted = None
        return interrupted or ('host_monitor_failed' if process is not None else 'vm_launch_failed')
    def finish(reason, host_error=None):
        nonlocal finalizing
        finalizing = True
        return finalize_owned_interruption(state, exchange, run_id, reason, guest_failure, host_error)
    try:
        if interruption_reason() == 'cancelled':
            return finish('cancelled')
        with open(exchange / 'vm.log', 'ab', buffering=0) as log:
            register_operation(state, vm, exchange, run_id, 'starting')
            process = subprocess.Popen(command, stdout=log, stderr=log, start_new_session=True)
            try:
                while process.poll() is None:
                    reason = interruption_reason()
                    if reason:
                        break
                    if setup_hook is not None:
                        prepared = setup_hook.poll()
                        if prepared is not None and prepared['status'] != 'passed':
                            reason = prepared.get('reason') if prepared.get('reason') in (
                                'guest_launch_failed', 'guest_exited_without_result') else 'guest_exchange_failed'
                            guest_failure = prepared
                            break
                        if prepared is not None:
                            atomic_json(result_path, {'version': 1, 'runId': run_id, 'kind': 'prepare',
                                'finishedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(), **prepared})
                    if result_path.exists():
                        result = read_json(result_path)
                        if not isinstance(result, dict):
                            raise RunnerError('Guest returned an invalid report')
                        if result.get('runId') != run_id:
                            raise RunnerError('Guest returned a result for a different run')
                        if (result.get('finishedAt') and result.get('status') in ('passed', 'failed', 'blocked', 'cancelled') and
                                result_exported(result)):
                            reason = interruption_reason()
                            if reason:
                                break
                            accepted_result = True
                            break
                    if status_path.exists():
                        status = read_json(status_path)
                        if not isinstance(status, dict):
                            raise RunnerError('VM returned an invalid status record')
                    try:
                        check_capacity(state, environment['minimumHostFreeBytes'])
                    except RunnerError as error:
                        reason = 'host_disk_reserve_reached'
                        capacity_error = str(error)
                        break
                    time.sleep(1)
                if reason is None and not accepted_result:
                    reason = interruption_reason() or 'vm_exited'
            except (RunnerError, OSError, ValueError, KeyboardInterrupt) as error:
                reason = failure_reason(error)
                raise
            finally:
                try:
                    if process.poll() is None and not accepted_result:
                        publish_stop(exchange, run_id)
                        def collection_interrupted():
                            requests = sum(record['requestCount'] for scope in stop_scopes
                                           if (record := operation_stop_record(*scope)) is not None)
                            return requests + cancellation_signals > (1 if reason == 'cancelled' else 0)
                        if setup_hook is not None:
                            setup_hook.request_stop()
                        stop_started = time.monotonic()
                        cancel_deadline = stop_started + 20
                        collection_deadline = stop_started + STOP_FINALIZATION_SECONDS + STOP_EXPORT_SECONDS + STOP_EXTRACT_SECONDS
                        collection_phases = set()
                        while time.monotonic() < cancel_deadline and process.poll() is None:
                            if collection_interrupted():
                                break
                            if setup_hook is not None:
                                prepared = setup_hook.poll()
                                if prepared is not None and prepared['status'] != 'passed':
                                    guest_failure = prepared
                                    break
                                transport = getattr(setup_hook, 'transport', None)
                                if transport is not None:
                                    phase = getattr(transport, 'phase', None)
                                    if (getattr(transport, 'observed_launch', False) or
                                            getattr(transport, 'final_seen', False) or phase in ('export', 'extract')):
                                        cancel_deadline = max(cancel_deadline, stop_started + STOP_FINALIZATION_SECONDS)
                                    if phase in ('export', 'extract') and phase not in collection_phases:
                                        collection_phases.add(phase)
                                        seconds = STOP_EXPORT_SECONDS if phase == 'export' else STOP_EXTRACT_SECONDS
                                        cancel_deadline = min(collection_deadline, max(cancel_deadline, time.monotonic() + seconds))
                            if collection_interrupted():
                                break
                            if result_path.exists():
                                progress = read_json(result_path)
                                if isinstance(progress, dict) and progress.get('finishedAt') and result_exported(progress):
                                    break
                            if setup_hook is not None:
                                try:
                                    check_capacity(state, environment['minimumHostFreeBytes'])
                                except RunnerError as error:
                                    capacity_error = str(error)
                                    break
                            time.sleep(1)
                        if time.monotonic() >= cancel_deadline and collection_phases and not setup_hook.exchange_complete:
                            guest_failure = {'status': 'failed', 'reason': 'guest_artifact_collection_timeout',
                                             'phase': getattr(getattr(setup_hook, 'transport', None), 'phase', None)}
                finally:
                    try:
                        if setup_hook is not None:
                            setup_hook.cancel()
                    finally:
                        if process.poll() is None:
                            stop_owned_process(process, stop_file)
                        shutdown_confirmed = True
        if accepted_result:
            return finish('cancelled') if cancellation_requested() else result
        if result_path.exists():
            completed = read_json(result_path)
            if not isinstance(completed, dict):
                raise RunnerError('Guest returned an invalid report')
            if reason == 'vm_exited':
                reason = interruption_reason() or reason
            if (reason == 'vm_exited' and completed.get('runId') == run_id and completed.get('finishedAt') and
                    completed.get('status') in ('passed', 'failed', 'blocked', 'cancelled') and result_exported(completed)):
                return completed
        return finish(reason, capacity_error)
    except (RunnerError, OSError, ValueError, KeyboardInterrupt) as error:
        if finalizing or process is not None and not shutdown_confirmed and process.poll() is None:
            raise
        return finish(failure_reason(error), str(error) or type(error).__name__)
    finally:
        for signum, handler in original_handlers.items():
            signal.signal(signum, handler)


def new_exchange(state, prefix):
    run_id = prefix + '-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]
    exchange = private_directory(state / ('setup' if prefix == 'setup' else 'results') / run_id)
    (exchange / 'artifacts').mkdir()
    return run_id, exchange


def stage_approval_arguments(arguments, exchange):
    arguments = list(arguments)
    for flag in ('--worker', '--failure-dir', '--scratch-dir'):
        if flag in arguments:
            raise RunnerError(f'{flag} is managed inside the guest; use the run results directory')
    if '--replay' in arguments:
        index = arguments.index('--replay')
        if arguments.count('--replay') != 1 or index + 1 >= len(arguments):
            raise RunnerError('Supply exactly one replay JSON path')
        source = Path(arguments[index + 1]).expanduser()
        with open_regular(source) as file:
            contents = file.read(16 * 1024 * 1024 + 1)
        if len(contents) > 16 * 1024 * 1024:
            raise RunnerError('Replay JSON exceeds 16 MiB')
        json.loads(contents)
        destination = private_directory(exchange / 'inputs') / 'approval-replay.json'
        destination.write_bytes(contents)
        arguments[index + 1] = '/Volumes/BigWalletBuild/Exchange/inputs/approval-replay.json'
    return arguments


def reconcile_interrupted_operation(state):
    path = state / 'active.json'
    if not path.exists():
        return
    active = read_json(path)
    exchange = Path(active['exchange'])
    vm = Path(active['vm'])
    run_id = active.get('runId')
    if not isinstance(run_id, str) or re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', run_id) is None or '..' in run_id:
        raise RunnerError('Interrupted operation has an invalid run identity')
    if not any(exchange.resolve().is_relative_to(state / folder) for folder in ('results', 'setup')) or not vm.resolve().is_relative_to(state):
        raise RunnerError('Interrupted operation does not belong to this state directory')
    clone_identity = None
    if active.get('cloneOwned') is True and vm == state / 'runs' / (run_id + '.vbvm'):
        if vm.is_symlink() or vm.resolve() != vm:
            raise RunnerError('Interrupted clone path is not canonical; preserving it for inspection')
        if vm.exists():
            metadata = vm.lstat()
            if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid():
                raise RunnerError('Interrupted clone is not an owned directory; preserving it for inspection')
            clone_identity = (metadata.st_dev, metadata.st_ino, metadata.st_uid)
    publish_stop(exchange, active['runId'])
    (exchange / 'vm-stop').touch(exist_ok=True)
    ensure_disk_idle(vm)
    result_path = exchange / 'artifacts/result.json'
    try:
        result = read_json(result_path) if result_path.exists() else {}
        if not isinstance(result, dict):
            result = {}
    except ValueError:
        result = {}
    if not completed_safari_preparation(state, active) and (
            active.get('cloneOwned') is not True or not accepted_operation_result(active)):
        pending = active.get('pendingTermination')
        if not pending:
            pending = {'reason': 'host_runner_interrupted'}
            active['pendingTermination'] = pending
            atomic_json(path, active)
        if (not result.get('finishedAt') or result.get('runId') != run_id or
                result.get('hostTermination', {}).get('reason') != pending.get('reason')):
            finalize_interrupted_result(exchange, active['runId'], pending['reason'],
                                        pending.get('guestFailure'), pending.get('hostError'))
        active['acceptedResultSHA256'] = hash_regular_file(result_path)
        atomic_json(path, active)
    if clone_identity is not None:
        metadata = vm.lstat()
        if (vm.resolve() != vm or not stat.S_ISDIR(metadata.st_mode) or
                (metadata.st_dev, metadata.st_ino, metadata.st_uid) != clone_identity):
            raise RunnerError('Interrupted clone changed during recovery; preserving it for inspection')
        if not retain_clone_diagnostics(active):
            shutil.rmtree(vm)
    path.unlink()


def environment_attested(preflight, environment):
    versions = preflight.get('versions', {})
    if (versions.get('node', '').strip() != 'v' + environment['node']['version'] or
            versions.get('npm', '').strip() != environment['node']['npmVersion'] or
            versions.get('jq', '').strip() != 'jq-' + environment['jq']['version']):
        return False
    pinned = preflight.get('pinnedEnvironment', {})
    xcode = pinned.get('xcode', {})
    if xcode.get('available') is not True or xcode.get('actual') != environment['xcode']:
        return False
    for expected in environment['runtimes']:
        key = {'iOS': 'ios', 'visionOS': 'visionos'}.get(expected['platform'])
        reported = pinned.get('runtimes', {}).get(key, {})
        if (not key or reported.get('available') is not True or
                reported.get('expected') != {name: expected[name] for name in ('version', 'buildVersion')}):
            return False
    return True


def preserve_previous_baseline_record(state, record, promoted, backup):
    pending = record['promotionPending']
    baseline = state / 'baseline.vbvm'
    backup_record = backup.with_suffix('.json')
    expected_hash = pending.get('backupRecordSHA256')
    expected_identity = pending.get('backupFileID')
    if expected_hash is None and expected_identity is None:
        if backup.exists() or backup.is_symlink():
            raise RunnerError('Pending promotion has an unrecorded VM backup; preserving all baselines')
        if promoted == state / 'candidate.vbvm' and (baseline.exists() or baseline.is_symlink()):
            validate_vm(baseline)
            ensure_disk_idle(baseline)
            previous = read_json(state / 'baseline.json')
            if not isinstance(previous, dict) or previous.get('promotionPending'):
                raise RunnerError('The previous baseline record is invalid; preserving both baselines')
            if backup_record.exists() or backup_record.is_symlink():
                if read_json(backup_record) != previous:
                    raise RunnerError('The previous baseline metadata backup already contains another record')
            else:
                atomic_json(backup_record, previous)
            metadata = baseline.lstat()
            pending.update({'backupRecordSHA256': hash_regular_file(backup_record),
                            'backupFileID': [metadata.st_dev, metadata.st_ino]})
            atomic_json(state / 'candidate.json', record)
        elif backup_record.exists() or backup_record.is_symlink():
            raise RunnerError('Pending promotion has metadata without a previous baseline')
        else:
            return
    expected_hash = pending.get('backupRecordSHA256')
    expected_identity = pending.get('backupFileID')
    if (not isinstance(expected_hash, str) or re.fullmatch(r'[a-f0-9]{64}', expected_hash) is None or
            not isinstance(expected_identity, list) or len(expected_identity) != 2 or
            any(type(value) is not int for value in expected_identity) or
            hash_regular_file(backup_record) != expected_hash):
        raise RunnerError('The previous baseline metadata backup changed; preserving all VM bundles')
    previous_vm = backup if backup.exists() or backup.is_symlink() else baseline
    validate_vm(previous_vm)
    metadata = previous_vm.lstat()
    if [metadata.st_dev, metadata.st_ino] != expected_identity:
        raise RunnerError('The previous baseline backup no longer matches its metadata; preserving all VM bundles')


def finish_baseline_promotion(state, record):
    pending = record['promotionPending']
    backup_name = pending.get('backup')
    if not isinstance(backup_name, str) or re.fullmatch(r'previous-baseline-[0-9a-f]{32}\.vbvm', backup_name) is None:
        raise RunnerError('Pending baseline promotion has an invalid backup path')
    candidate = state / 'candidate.vbvm'
    baseline = state / 'baseline.vbvm'
    backup = state / backup_name
    promoted = candidate if candidate.exists() or candidate.is_symlink() else baseline
    validate_vm(promoted)
    metadata = promoted.lstat()
    if [metadata.st_dev, metadata.st_ino] != pending.get('candidateFileID'):
        raise RunnerError('Pending promotion no longer owns the candidate; preserving all VM bundles')
    ensure_disk_idle(promoted)
    preserve_previous_baseline_record(state, record, promoted, backup)
    if promoted == candidate:
        if baseline.exists() or baseline.is_symlink():
            if backup.exists() or backup.is_symlink():
                raise RunnerError('Pending promotion backup already exists; preserving both baselines')
            validate_vm(baseline)
            ensure_disk_idle(baseline)
            baseline.rename(backup)
        candidate.rename(baseline)
    configuration = validate_vm(baseline)
    configuration['sharedFolders'] = []
    atomic_plist(baseline / '.vbdata/Config.plist', configuration)
    completed = dict(record)
    completed.pop('promotionPending')
    request_id = completed.pop('pendingProvisioning', {}).get('id')
    atomic_json(state / 'baseline.json', completed)
    clear_applied_provisioning_packages(state, record['vmId'], request_id)
    (state / 'candidate.json').unlink()


def check_setup_stop(operation):
    if any(operation_stop_requested(exchange, run_id) for exchange, run_id in
           [(operation['exchange'], operation['runId']), *operation['previousStops']]):
        raise KeyboardInterrupt


def handoff_setup_operation(state, vm, operation, run_id, exchange):
    check_setup_stop(operation)
    previous = (operation['runId'], operation['exchange'])
    try:
        register_operation(state, vm, exchange, run_id, 'preparing', previous=previous)
    finally:
        active = read_json(state / 'active.json')
        if active.get('runId') == run_id and active.get('ownerPID') == os.getpid():
            operation['previousStops'].append((previous[1], previous[0]))
            operation.update({'runId': run_id, 'exchange': exchange})
    check_setup_stop(operation)


def guest_access_module():
    specification = importlib.util.spec_from_file_location('big_wallet_guest_access', TOOLS / 'guest_access.py')
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def create_initial_guest_password(path):
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        with open(temporary, 'x', encoding='utf-8') as file:
            os.fchmod(file.fileno(), 0o600)
            file.write(secrets.token_urlsafe(32))
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, path)
        descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        temporary.unlink(missing_ok=True)


def guest_setup_password(module, state, record, configuration, exchange, initial_password):
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', record['vmId']):
        raise RunnerError('The guest access identity is invalid')
    parent = private_directory(private_directory(state / 'guest-access') / record['vmId'])
    identity = {'vmId': record['vmId'], 'consoleUser': configuration['consoleUser']}
    supplied = configuration.get('autologin', {}).get('passwordFile')
    if supplied is not None:
        if not isinstance(supplied, str) or Path(supplied).name != supplied:
            raise RunnerError('The staged guest account password must be a regular provisioning input')
        source = exchange / 'provision' / supplied
    else:
        source = initial_password
    access_id = configuration.get('provisioningRequestID') if source is not None else record.get('guestAccessID')
    try:
        valid_access_id = str(uuid.UUID(access_id)) == access_id
    except (ValueError, AttributeError, TypeError):
        valid_access_id = False
    if not valid_access_id:
        raise RunnerError('Headless guest setup needs the existing guest account password in '
                          'autologin.passwordFile, or --provision-new-account on first boot. '
                          'No additional Apple signing credentials are required.')
    directory = parent / access_id
    password_path = directory / 'password'
    identity_path = directory / 'identity.json'
    if source is not None:
        contents = module.read_private_password(source)
        if not directory.exists() and not directory.is_symlink():
            temporary = private_directory(parent / ('.' + access_id + '-' + uuid.uuid4().hex + '.tmp'))
            try:
                with open(temporary / 'password', 'xb') as file:
                    os.fchmod(file.fileno(), 0o600)
                    file.write(contents + b'\n')
                    file.flush()
                    os.fsync(file.fileno())
                atomic_json(temporary / 'identity.json', identity)
                temporary.rename(directory)
            finally:
                if temporary.exists():
                    shutil.rmtree(temporary)
    if not directory.is_dir() or directory.is_symlink():
        raise RunnerError('The guest credential scope is unavailable or invalid')
    private_directory(directory)
    if not identity_path.exists() or read_json(identity_path) != identity:
        raise RunnerError('Headless guest setup needs the existing guest account password in '
                          'autologin.passwordFile, or --provision-new-account on first boot. '
                          'No additional Apple signing credentials are required.')
    if source is not None:
        if module.read_private_password(password_path) != contents:
            raise RunnerError('The retained guest credentials differ from this provisioning request')
        record['guestAccessID'] = access_id
    else:
        module.read_private_password(password_path)
    return directory, password_path


def guest_exchange_module():
    specification = importlib.util.spec_from_file_location('big_wallet_guest_exchange', TOOLS / 'guest_exchange.py')
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


class GuestSetupHook:
    def __init__(self, module, access, user, password, directory, exchange, job=None, *, install=True):
        self.module = module
        self.access = access
        self.user = user
        self.password = password
        self.directory = directory
        self.exchange = exchange
        self.job = job
        self.install = install
        self.child = None
        self.transport = None
        self.exchange_complete = False
        self.stopping = False
        self.address = None
        self.installing = False
        self.remote_uncertain = False
        self.finished = False
        self.retry_at = 0

    def begin_exchange(self):
        atomic_json(self.exchange / 'job.json', self.job)
        module = guest_exchange_module()
        self.transport = module.GuestExchange(self.address, self.user, self.password,
            self.access['knownHosts'], self.access['hostKeyAlias'], self.directory, self.exchange)

    def poll(self):
        if (self.finished and not self.stopping or self.stopping and self.transport is None or
                time.monotonic() < self.retry_at):
            return None
        try:
            if self.transport is not None:
                outcome = self.transport.poll()
                if outcome is not None:
                    self.finished = True
                    self.exchange_complete = outcome['status'] == 'passed'
                    return outcome if outcome['status'] != 'passed' else None
                return None
            if self.child is None:
                self.address = self.module.find_guest_address(self.access['macAddress'])
                if self.address is None:
                    return None
                self.child = self.module.SSHBannerProbe(self.address)
            outcome = self.child.poll()
            if outcome is None:
                return None
            if not self.installing:
                self.child.cancel()
                self.child = None
                if outcome['status'] != 'passed':
                    self.retry_at = time.monotonic() + 2
                    return None
                if self.job is None:
                    self.finished = True
                    return {'status': 'passed', 'phase': 'guest-ssh-key-generation'}
                if not self.install:
                    self.begin_exchange()
                    return None
                self.installing = True
                self.remote_uncertain = True
                self.child = self.module.GuestInstaller(self.address, self.user, self.password,
                    self.access['knownHosts'], self.access['hostKeyAlias'], self.directory,
                    provision_directory=self.exchange / 'provision',
                    log_path=self.exchange / 'artifacts/provisioning.log')
                return None
            code = outcome.get('returnCode')
            self.remote_uncertain = isinstance(code, int) and (code == 255 or code < 0)
            if outcome['status'] == 'restart-required':
                self.finished = True
                return {'status': 'passed', 'phase': 'guest-session-restart'}
            if outcome['status'] != 'passed':
                self.finished = True
                return outcome
            self.child.cancel()
            self.child = None
            self.begin_exchange()
            return None
        except (self.module.GuestAccessError, OSError, ValueError, RuntimeError) as error:
            self.finished = True
            return {'status': 'failed', 'reason': 'guest_exchange_failed', 'error': str(error)}

    def request_stop(self):
        self.stopping = True
        if self.transport is not None:
            self.transport.request_stop()

    def cancel(self):
        try:
            if self.transport is not None:
                self.transport.cancel()
            if self.child is not None:
                self.child.cancel()
        finally:
            if self.remote_uncertain:
                time.sleep(20)
                self.remote_uncertain = False


def prepared_guest_hook(state, vm, record, exchange):
    module = guest_access_module()
    configuration = {'consoleUser': record['consoleUser']}
    try:
        directory, password = guest_setup_password(module, state, record, configuration, exchange, None)
        access = module.prepare_guest_access(vm, directory, record['vmId'], record['consoleUser'])
        if not access['knownHosts']:
            raise RunnerError('The prepared guest SSH identity is missing; rerun setup before testing')
        return GuestSetupHook(module, access, record['consoleUser'], password, directory, exchange,
                              read_json(exchange / 'job.json'), install=False)
    except module.GuestAccessError as error:
        raise RunnerError(str(error)) from None


def next_setup_exchange(state, candidate, operation, record):
    previous = operation['exchange']
    run_id, exchange = new_exchange(state, 'setup')
    handoff_setup_operation(state, candidate, operation, run_id, exchange)
    for name in ('provision', 'source', 'snapshot-manifest.json'):
        checked(['/bin/cp', '-cR', previous / name, exchange / name])
    configure_guest_hardware(candidate, record['vmId'])
    check_setup_stop(operation)
    return run_id, exchange


def run_setup_doctor(args, state, candidate, environment, operation, record, configuration,
                     binaries, bootstrap_tools, source, initial_password, source_digest):
    run_id, exchange = operation['runId'], operation['exchange']
    needs_install = (configuration.get('provisioningRequestID') is not None or
                     record.get('bootstrapTools') != bootstrap_tools or
                     record.get('bootstrapSourceDigest') != source_digest or
                     not record.get('baseVerifiedAt'))
    module = guest_access_module()
    try:
        directory, password = guest_setup_password(module, state, record, configuration, exchange, initial_password)
        atomic_json(state / 'candidate.json', record)
        check_setup_stop(operation)
        access = module.prepare_guest_access(candidate, directory, record['vmId'], configuration['consoleUser'],
                                             first_boot_ssh_requested=initial_password is not None)
        check_setup_stop(operation)
        if not access['knownHosts']:
            print('Preparing the guest SSH identity in a headless boot; no credentials are sent.', flush=True)
            hook = GuestSetupHook(module, access, configuration['consoleUser'], password, directory, exchange)
            operation['monitorCalled'] = True
            result = monitor_vm(args, state, candidate, exchange, run_id, binaries, environment,
                args.timeout or 600, initial_password, keep_operation=True,
                previous_stops=operation['previousStops'], setup_hook=hook)
            if result['status'] != 'passed':
                return result, exchange
            check_setup_stop(operation)
            ensure_disk_idle(candidate)
            access = module.prepare_guest_access(candidate, directory, record['vmId'], configuration['consoleUser'],
                                                 first_boot_ssh_requested=initial_password is not None)
            if not access['knownHosts']:
                raise RunnerError('The guest did not generate a public SSH host key; no credentials were sent')
            run_id, exchange = next_setup_exchange(state, candidate, operation, record)
    except module.GuestAccessError as error:
        raise RunnerError(str(error)) from None
    check_setup_stop(operation)
    for attempt in range(2):
        job = {'version': 1, 'runId': run_id, 'vmId': record['vmId'], 'kind': 'doctor', 'profile': 'all',
               'payload': {'stages': [], 'onlyTesting': [], 'signing': 'local'}, 'source': source, 'bootstrapTools': bootstrap_tools}
        if needs_install:
            print('Applying guest provisioning over pinned SSH with the existing guest account.', flush=True)
        hook = GuestSetupHook(module, access, configuration['consoleUser'], password, directory, exchange, job,
                              install=needs_install)
        operation['monitorCalled'] = True
        result = monitor_vm(args, state, candidate, exchange, run_id, binaries, environment,
            args.timeout or (14400 if needs_install else 600), initial_password, keep_operation=True,
            previous_stops=operation['previousStops'], setup_hook=hook)
        if result.get('phase') != 'guest-session-restart' or result['status'] != 'passed':
            return result, exchange
        check_setup_stop(operation)
        if attempt:
            result.update({'status': 'failed', 'reason': 'guest_automatic_login_did_not_become_available'})
            atomic_json(exchange / 'artifacts/result.json', result)
            return result, exchange
        print('Restarting the test VM to apply the configured guest automatic login.', flush=True)
        run_id, exchange = next_setup_exchange(state, candidate, operation, record)


def setup(args, state, environment, *, result_callback=None):
    if getattr(args, 'safari_activation', False) and not args.interactive:
        raise RunnerError('Safari activation setup requires --interactive for the genuine user activation step')
    validate_vm(args.vm)
    run_id, exchange = new_exchange(state, 'setup')
    operation = {'runId': run_id, 'exchange': exchange, 'previousStops': [], 'monitorCalled': False}
    candidate = state / 'candidate.vbvm'
    register_operation(state, candidate, exchange, run_id, 'preparing')
    completed = False
    finalization_pending = False
    result = None
    try:
        with clone_cancellation_signals():
            result = prepare_setup(args, state, environment, operation)
        completed = True
        return result
    except KeyboardInterrupt:
        finalization_pending = True
        candidate_path = state / 'candidate.json'
        result_path = operation['exchange'] / 'artifacts/result.json'
        record = {}
        if getattr(args, 'safari_activation', False):
            record_path = candidate_path if candidate_path.exists() else state / 'baseline.json'
            if record_path.exists():
                record = read_json(record_path)
        active = read_json(state / 'active.json')
        completed_preparation = (
            getattr(args, 'safari_activation', False) and
            active.get('runId') == operation['runId'] and active.get('exchange') == str(operation['exchange']) and
            active.get('ownerPID') == os.getpid() and completed_safari_preparation(state, active))
        if not completed_preparation:
            finalize_owned_interruption(state, operation['exchange'], operation['runId'], 'cancelled')
        if record and candidate_path.exists():
            attempt = record.get('safariActivationAttempt', {})
            if attempt.get('runId') == operation['runId'] and attempt.get('result') == str(result_path):
                active = read_json(state / 'active.json')
                attempt.update({'artifactsExported': active.get('artifactsExported') is True or active.get('phase') == 'preparing',
                                'resultSHA256': hash_regular_file(result_path)})
                atomic_json(candidate_path, record)
        completed = True
        print(f'Setup cancelled. Results: {operation["exchange"] / "artifacts/result.json"}')
        return 2
    finally:
        try:
            if result_callback is not None:
                result_path = operation['exchange'] / 'artifacts/result.json'
                if not result_path.exists() and result == 0 and (state / 'baseline.json').exists():
                    result_path = Path(read_json(state / 'baseline.json')['validationResult'])
                if result_path.exists():
                    result_callback(result_path, read_json(result_path))
        except Exception:
            if completed:
                raise
        finally:
            active_path = state / 'active.json'
            if active_path.exists():
                active = read_json(active_path)
                if active.get('runId') == operation['runId'] and active.get('ownerPID') == os.getpid():
                    if operation['monitorCalled']:
                        ensure_disk_idle(Path(active['vm']))
                    if completed or not finalization_pending and (accepted_operation_result(active) or not operation['monitorCalled']):
                        clear_owned_operation(state, operation['runId'])


def safari_preparation_reference(value):
    if (not isinstance(value, dict) or set(value) != {'preparationRunID', 'receiptSHA256'} or
            not isinstance(value['preparationRunID'], str) or
            re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', value['preparationRunID']) is None or
            '..' in value['preparationRunID'] or not isinstance(value['receiptSHA256'], str) or
            re.fullmatch(r'[a-f0-9]{64}', value['receiptSHA256']) is None):
        raise RunnerError('Invalid prepared Safari baseline reference; repeat setup --interactive --safari-activation')
    return dict(value)


def prepared_safari_for_job(record, job, plan):
    payload = job['payload']
    selects_macos = any(stage.get('nativeAudit', {}).get('kind') == 'safari' and
                        stage['nativeAudit'].get('platform') == 'macos' for stage in plan['stages'])
    if (record.get('safariPreparation') is None or payload.get('signing', 'local') != 'local' or
            not selects_macos):
        return None
    if payload.get('interactiveSafari'):
        raise RunnerError('A prepared Safari baseline uses headless activation checks; omit --interactive-safari')
    return safari_preparation_reference(record['safariPreparation'])


def verify_safari_preparation_result(exchange, result, run_id):
    filename = 'prepare-safari.macos.debug.safari-preparation.json'
    stages = [stage for stage in result.get('stages', []) if stage.get('id') == 'prepare-safari.macos.debug']
    if (len(stages) != 1 or stages[0].get('status') != 'passed' or stages[0].get('preparationResult') != filename or
            stages[0].get('audit', {}).get('ok') is not True):
        raise RunnerError('Safari preparation has no passing audited preparation stage')
    with open_regular(exchange / 'artifacts' / filename) as file:
        data = file.read(65537)
    if len(data) > 65536 or hashlib.sha256(data).hexdigest() != stages[0].get('preparationSHA256'):
        raise RunnerError('Safari preparation result does not match the guest-audited artifact')
    value = json.loads(data)
    fields = {'version', 'status', 'preparationRunID', 'platform', 'configuration', 'signingMode',
              'installationDirectory', 'receiptSHA256', 'receipt'}
    if (not isinstance(value, dict) or set(value) != fields or type(value['version']) is not int or value['version'] != 1 or
            value['status'] != 'passed' or value['preparationRunID'] != run_id or value['platform'] != 'macos' or
            value['configuration'] != 'Debug' or value['signingMode'] != 'local'):
        raise RunnerError('Safari preparation result has an invalid identity or status')
    reference = safari_preparation_reference({key: value[key] for key in ('preparationRunID', 'receiptSHA256')})
    receipt = value['receipt']
    if (not isinstance(receipt, dict) or set(receipt) != {'version', 'status', 'preparationRunID', 'descriptor',
            'installationDirectory', 'sourceApp', 'signatures', 'enabledObservation', 'cleanup', 'preparedAt'} or
            type(receipt['version']) is not int or receipt['version'] != 1 or receipt['status'] != 'passed' or
            receipt['preparationRunID'] != run_id or
            hashlib.sha256(json.dumps(receipt, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest() != reference['receiptSHA256']):
        raise RunnerError('Safari preparation receipt does not match its verified identity or digest')
    descriptor = {'version': 1, 'runID': run_id, 'root': f'/Volumes/BigWalletBuild/Exchange/{run_id}/safari/macos/Debug',
                  'platform': 'macos', 'configuration': 'Debug', 'signingMode': 'local'}
    if receipt['descriptor'] != descriptor or type(receipt['descriptor'].get('version')) is not int:
        raise RunnerError('Safari preparation receipt does not match the prepared fixture descriptor')
    def valid_path(path):
        return (isinstance(path, str) and len(path) <= 4096 and path.startswith('/') and
                str(PurePosixPath(path)) == path and '..' not in PurePosixPath(path).parts and
                re.search(r'[\x00-\x1f\x7f]', path) is None)
    installation = receipt['installationDirectory']
    source = receipt['sourceApp']
    if (not valid_path(installation) or not installation.endswith('/Applications/BigWalletSafariVM/Prepared') or
            installation != value['installationDirectory'] or not valid_path(source) or
            '/Library/Developer/Xcode/DerivedData/' not in source or not source.endswith('/Big Wallet.app')):
        raise RunnerError('Safari preparation receipt has invalid installation paths')
    signatures = receipt['signatures']
    identifiers = {'app': 'org.lil.wallet', 'extension': 'org.lil.wallet.Safari', 'helper': 'org.lil.wallet.ambient'}
    if not isinstance(signatures, dict) or set(signatures) != set(identifiers):
        raise RunnerError('Safari preparation receipt is missing product signature identities')
    for role, identifier in identifiers.items():
        signature = signatures[role]
        if (not isinstance(signature, dict) or set(signature) != {'identifier', 'cdhash'} or
                signature['identifier'] != identifier or not isinstance(signature['cdhash'], str) or
                re.fullmatch(r'[a-f0-9]{40}', signature['cdhash']) is None):
            raise RunnerError(f'Safari preparation receipt has an invalid {role} signature identity')
    def parsed_time(value):
        if not isinstance(value, str) or re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z', value) is None:
            raise RunnerError('Safari preparation receipt has an invalid observation timestamp')
        return datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
    observation = receipt['enabledObservation']
    if (not isinstance(observation, dict) or set(observation) != {'enabled', 'processID', 'executablePath', 'preparationNonce', 'observedAt'} or
            observation['enabled'] is not True or type(observation['processID']) is not int or
            not 1 < observation['processID'] <= 2147483647 or
            observation['executablePath'] != f'{installation}/Big Wallet.app/Contents/MacOS/Big Wallet' or
            not isinstance(observation['preparationNonce'], str) or
            re.fullmatch(r'[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}', observation['preparationNonce']) is None or
            parsed_time(observation['observedAt']) > parsed_time(receipt['preparedAt'])):
        raise RunnerError('Safari preparation receipt has no valid native enabled-state observation')
    if receipt['cleanup'] != {'status': 'passed'} or stages[0]['audit'].get('preparation') != reference:
        raise RunnerError('Safari preparation receipt has no matching audit and successful process cleanup')
    return reference


def prepare_safari_activation(args, state, environment, operation):
    if not args.interactive or args.stage_only or args.provision_config or args.proof_key_bundle or args.provision_new_account:
        raise RunnerError('Use setup --interactive --safari-activation with an existing verified baseline and no provisioning inputs')
    baseline_path = state / 'baseline.json'
    baseline = state / 'baseline.vbvm'
    candidate_path = state / 'candidate.json'
    candidate = state / 'candidate.vbvm'
    if candidate_path.exists() and read_json(candidate_path).get('promotionPending'):
        pending = read_json(candidate_path)
        if (not matches_source_vm(pending, args.vm) or pending.get('environment') != environment or
                pending.get('consoleUser') != selected_console_user(args, pending) or
                pending.get('bootstrapSourceDigest') != bootstrap_source_digest() or
                pending.get('bootstrapTools') != bootstrap_tool_hashes(build_tools(state, args.xcode))):
            raise RunnerError('Pending Safari preparation promotion does not match the current verified environment')
        if not inherited_safari_preparation(state, pending, pending['consoleUser']):
            raise RunnerError('Pending Safari preparation no longer has its verified archived receipt')
        check_setup_stop(operation)
        finish_baseline_promotion(state, pending)
        print('The verified Safari preparation was promoted to the baseline.')
        return 0
    if not baseline_path.exists():
        raise RunnerError('Safari activation requires a verified baseline; run ordinary setup first')
    existing = read_json(baseline_path)
    source_digest = bootstrap_source_digest()
    if (not matches_source_vm(existing, args.vm) or existing.get('environment') != environment or
            existing.get('bootstrapSourceDigest') != source_digest or existing.get('verificationSigningMode') != 'local' or
            not existing.get('verifiedAt') or existing.get('consoleUser') != selected_console_user(args, existing)):
        raise RunnerError('Safari activation requires the current verified baseline and guest account; run ordinary setup first')
    check_capacity(state, environment['minimumHostFreeBytes'])
    validate_vm(baseline)
    ensure_disk_idle(baseline)
    baseline_info = baseline.lstat()
    baseline_identity = {'recordSHA256': hash_regular_file(baseline_path), 'fileID': [baseline_info.st_dev, baseline_info.st_ino]}
    binaries = build_tools(state, args.xcode)
    bootstrap_tools = bootstrap_tool_hashes(binaries)
    require_current_bootstrap_sources(source_digest)
    if existing.get('bootstrapTools') != bootstrap_tools:
        raise RunnerError('Safari activation requires current verified guest bootstrap tools; run ordinary setup first')
    check_setup_stop(operation)
    if candidate_path.exists():
        record = read_json(candidate_path)
        if (record.get('safariActivationSource') != baseline_identity or not matches_source_vm(record, args.vm) or
                record.get('environment') != environment or record.get('bootstrapSourceDigest') != source_digest):
            raise RunnerError('An unrelated candidate already exists; preserve it and finish its ordinary setup first')
        if record.get('safariActivationConstructionPending') and (candidate.exists() or candidate.is_symlink()):
            if candidate.is_symlink() or not candidate.is_dir():
                raise RunnerError('The unfinished Safari preparation candidate changed type')
            ensure_disk_idle(candidate)
            shutil.rmtree(candidate)
        elif not record.get('safariActivationConstructionPending'):
            validate_vm(candidate)
            ensure_disk_idle(candidate)
            metadata = candidate.lstat()
            attempt = record.get('safariActivationAttempt', {})
            archived = Path(attempt.get('result', ''))
            if ([metadata.st_dev, metadata.st_ino] != record.get('safariActivationFileID') or
                    attempt.get('artifactsExported') is not True or not archived.is_absolute() or
                    archived.resolve() != archived or not archived.is_relative_to(state / 'results') or
                    archived.name != 'result.json' or hash_regular_file(archived) != attempt.get('resultSHA256')):
                raise RunnerError('The failed Safari candidate has uncollected or unverified diagnostics; preserve it before retrying')
            previous_result = read_json(archived)
            if previous_result.get('runId') != attempt.get('runId') or not previous_result.get('finishedAt'):
                raise RunnerError('The failed Safari candidate has no matching archived final report')
            record['safariActivationConstructionPending'] = True
            record.pop('safariActivationAttempt', None)
            record.pop('safariActivationFileID', None)
            atomic_json(candidate_path, record)
            shutil.rmtree(candidate)
    else:
        if candidate.exists() or candidate.is_symlink():
            raise RunnerError('An unrecorded candidate exists; preserve it before preparing Safari')
        record = {**existing, 'safariActivationSource': baseline_identity, 'safariActivationConstructionPending': True}
        record.pop('safariPreparation', None)
        record.pop('safariPreparationResult', None)
        record.pop('verifiedAt', None)
        atomic_json(candidate_path, record)
    if record.get('safariActivationConstructionPending'):
        check_setup_stop(operation)
        clone_vm(baseline, candidate)
        metadata = candidate.lstat()
        record['safariActivationFileID'] = [metadata.st_dev, metadata.st_ino]
        atomic_json(candidate_path, record)
    validate_vm(candidate)
    ensure_disk_idle(candidate)
    args.guest_user = record['consoleUser']
    print('Reusing the verified guest tools for Safari activation; no installer or Xcode archive is staged.', flush=True)
    validation_result = None
    result = None
    for prefix, payload in (
        ('setup-validation', {'stages': ['test'], 'configuration': 'Debug', 'signing': 'local', 'runtimePlatforms': ['macos'],
            'onlyTesting': ['Tests macOS/WindowAuthenticationSessionTests', 'Tests macOS/PasswordStorageTests',
                            'WalletAuthorityTests/PasswordStorageTests', 'Tests macOS/SecretHandlingTests']}),
        ('setup-safari-preparation', {'stages': ['safari'], 'configuration': 'Debug', 'signing': 'local',
            'onlyTesting': ['Safari UI Tests macOS'], 'prepareSafari': True}),
    ):
        run_id, exchange = new_exchange(state, prefix)
        handoff_setup_operation(state, candidate, operation, run_id, exchange)
        source = snapshot_source(ROOT, exchange)
        verify_setup_sources(exchange, source_digest, environment)
        job = {'version': 1, 'runId': run_id, 'vmId': record['vmId'], 'kind': 'run', 'profile': 'all',
               'payload': payload, 'source': source, 'bootstrapTools': bootstrap_tools}
        atomic_json(exchange / 'job.json', job)
        plan = stage_planned_result(exchange, job)
        check_setup_stop(operation)
        hook = prepared_guest_hook(state, candidate, record, exchange)
        record['safariActivationAttempt'] = {'runId': run_id, 'result': str(exchange / 'artifacts/result.json'),
                                            'artifactsExported': False}
        record.pop('safariActivationConstructionPending', None)
        atomic_json(candidate_path, record)
        operation['monitorCalled'] = True
        result = monitor_vm(args, state, candidate, exchange, run_id, binaries, environment, args.timeout or 7200,
                            keep_operation=True, previous_stops=operation['previousStops'], setup_hook=hook)
        active = read_json(state / 'active.json')
        record['safariActivationAttempt'].update({
            'artifactsExported': active.get('runId') == run_id and active.get('artifactsExported') is True,
            'resultSHA256': hash_regular_file(exchange / 'artifacts/result.json')})
        atomic_json(candidate_path, record)
        require_current_bootstrap_sources(source_digest)
        if result.get('status') != 'passed':
            break
        check_setup_stop(operation)
        preflight = result.get('preflight', {})
        actual_stages = result.get('stages', [])
        verified_source = result.get('source')
        source_matches = (isinstance(verified_source, dict) and
                          all(verified_source.get(key) == value for key, value in source.items()) and
                          type(verified_source.get('files')) is int and verified_source['files'] == source['fileCount'])
        if (result.get('runId') != run_id or result.get('vmId') != record['vmId'] or not source_matches or
                setup_provisioning_issue(result, record['vmId'], args.guest_user) or
                preflight.get('bootstrap', {}).get('available') is not True or
                preflight.get('bootstrap', {}).get('hashes') != bootstrap_tools or not environment_attested(preflight, environment) or
                not isinstance(actual_stages, list) or
                any(not isinstance(stage, dict) for stage in actual_stages) or
                [stage.get('id') for stage in actual_stages] != [stage['id'] for stage in plan['stages']] or
                any(stage.get('status') != 'passed' or
                    planned.get('nativeAudit') and (stage.get('nativeAudit') != planned['nativeAudit'] or stage.get('audit', {}).get('ok') is not True)
                    for stage, planned in zip(actual_stages, plan['stages']))):
            result.update({'status': 'blocked', 'reason': 'safari_preparation_guest_validation_did_not_match_requested_setup'})
            atomic_json(exchange / 'artifacts/result.json', result)
            break
        if payload.get('prepareSafari'):
            try:
                record['safariPreparation'] = verify_safari_preparation_result(exchange, result, run_id)
            except (RunnerError, OSError, ValueError, TypeError, KeyError) as error:
                result.update({'status': 'failed', 'reason': 'safari_preparation_receipt_invalid', 'preparationError': str(error)})
                atomic_json(exchange / 'artifacts/result.json', result)
                break
            record['safariPreparationResult'] = str(exchange / 'artifacts/result.json')
        else:
            validation_result = str(exchange / 'artifacts/result.json')
    print(f'Results: {operation["exchange"] / "artifacts/result.json"}', flush=True)
    if result is None or result.get('status') != 'passed' or 'safariPreparation' not in record:
        if result is not None:
            record['safariActivationAttempt']['resultSHA256'] = hash_regular_file(operation['exchange'] / 'artifacts/result.json')
            atomic_json(candidate_path, record)
        print('Safari preparation is incomplete; the existing baseline remains unchanged.')
        return 2
    check_setup_stop(operation)
    ensure_disk_idle(candidate)
    metadata = candidate.lstat()
    record.pop('safariActivationSource', None)
    record.pop('safariActivationAttempt', None)
    record.pop('safariActivationFileID', None)
    record.update({'verifiedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                   'validationResult': validation_result,
                   'promotionPending': {'backup': 'previous-baseline-' + uuid.uuid4().hex + '.vbvm',
                                        'candidateFileID': [metadata.st_dev, metadata.st_ino]}})
    atomic_json(candidate_path, record)
    finish_baseline_promotion(state, record)
    print('Prepared Safari baseline verified. Normal local macOS Safari runs will check and reuse its activation headlessly.')
    return 0


def inherited_safari_preparation(state, record, console_user):
    fields = ('safariPreparation', 'safariPreparationResult')
    if not any(field in record for field in fields):
        return {}
    if console_user != record.get('consoleUser'):
        raise RunnerError('Prepared Safari belongs to another guest account; preserve this baseline and use another state directory')
    reference = safari_preparation_reference(record.get('safariPreparation'))
    result_path = record.get('safariPreparationResult')
    if not isinstance(result_path, str):
        raise RunnerError('Prepared Safari has no archived verification result')
    archived = Path(result_path)
    if (not archived.is_absolute() or archived.resolve() != archived or
            not archived.is_relative_to(state / 'results') or archived.name != 'result.json' or
            archived.parent.name != 'artifacts'):
        raise RunnerError('Prepared Safari verification must remain in the runner-owned results directory')
    result = read_json(archived)
    if (not isinstance(result, dict) or result.get('status') != 'passed' or not result.get('finishedAt') or
            result.get('runId') != reference['preparationRunID'] or result.get('vmId') != record.get('vmId') or
            not isinstance(result.get('identity'), dict) or
            result['identity'].get('vmId') != record.get('vmId') or
            result['identity'].get('consoleUser') != console_user or
            verify_safari_preparation_result(archived.parent.parent, result, reference['preparationRunID']) != reference):
        raise RunnerError('Prepared Safari verification does not match this VM and guest account')
    return {'safariPreparation': reference, 'safariPreparationResult': str(archived)}


def prepare_setup(args, state, environment, operation):
    if getattr(args, 'safari_activation', False):
        return prepare_safari_activation(args, state, environment, operation)
    run_id, exchange = operation['runId'], operation['exchange']
    check_capacity(state, environment['minimumHostFreeBytes'])
    record_path = state / 'candidate.json'
    if record_path.exists():
        pending = read_json(record_path)
        if pending.get('promotionPending'):
            if not matches_source_vm(pending, args.vm):
                raise RunnerError('Pending promotion belongs to another source VM')
            inherited_safari_preparation(state, pending, pending.get('consoleUser'))
            check_setup_stop(operation)
            finish_baseline_promotion(state, pending)
    source_digest = bootstrap_source_digest()
    binaries = build_tools(state, args.xcode)
    bootstrap_tools = bootstrap_tool_hashes(binaries)
    require_current_bootstrap_sources(source_digest)
    check_setup_stop(operation)
    candidate = state / 'candidate.vbvm'
    if ((state / 'baseline.json').exists() and not record_path.exists() and not candidate.exists() and not args.provision_config and
            not args.proof_key_bundle and not args.provision_new_account and not args.interactive):
        existing = read_json(state / 'baseline.json')
        if (matches_source_vm(existing, args.vm) and existing.get('environment') == environment and
                existing.get('bootstrapTools') == bootstrap_tools and existing.get('bootstrapSourceDigest') == source_digest and
                existing.get('consoleUser') == selected_console_user(args, existing) and
                existing.get('verificationSigningMode') == 'local'):
            validate_vm(state / 'baseline.vbvm')
            inherited_safari_preparation(state, existing, selected_console_user(args, existing))
            print('The prepared baseline already passed local verification with the pinned environment and guest bootstrap.')
            print('Run Scripts/test_vm.sh run all; each run checks live guest readiness again.')
            return 0
    record = read_json(record_path) if record_path.exists() else None
    existing_baseline = state / 'baseline.vbvm'
    if record is None or record.get('constructionPending'):
        existing_record = read_json(state / 'baseline.json') if (state / 'baseline.json').exists() else None
        if existing_record is None and (existing_baseline.exists() or existing_baseline.is_symlink()):
            raise RunnerError('Unrecorded baseline exists; preserve it and use another --state-dir')
        if existing_record is not None and not matches_source_vm(existing_record, args.vm):
            raise RunnerError('Baseline belongs to another source VM; use a different --state-dir')
        existing_record = existing_record or {}
        inheritance_user = selected_console_user(args, record or existing_record)
        if record and record.get('constructionPending') and args.guest_user is None and args.provision_config is None:
            inheritance_user = record['constructionConsoleUser']
        inherited_preparation = inherited_safari_preparation(state, existing_record, inheritance_user)
        if inherited_preparation and record is not None and record.get('vmId') != existing_record.get('vmId'):
            raise RunnerError('Prepared Safari candidate belongs to another VM; preserving the candidate')
    if record is not None:
        if not matches_source_vm(record, args.vm):
            raise RunnerError('Candidate belongs to another source VM; use a different --state-dir')
        inherited_safari_preparation(state, record, selected_console_user(args, record))
        if record.get('constructionPending'):
            if candidate.is_symlink() or candidate.exists() and not candidate.is_dir():
                raise RunnerError('The unfinished candidate path changed type; preserving it for inspection')
            if candidate.exists():
                ensure_disk_idle(candidate)
                shutil.rmtree(candidate)
            if args.guest_user is None and args.provision_config is None:
                args.guest_user = record['constructionConsoleUser']
            record.update(inherited_preparation)
        else:
            validate_vm(candidate)
            ensure_disk_idle(candidate)
            created_build_data = configure_build_storage(candidate, environment['buildData']['bytes'])
            record['buildDataInitializationAllowed'] = record.get('buildDataInitializationAllowed', False) or created_build_data
            record['environment'] = environment
            atomic_json(record_path, record)
    else:
        if candidate.exists() or candidate.is_symlink():
            raise RunnerError('Unrecorded candidate exists; preserve it and use another --state-dir')
        record = {'version': 1, 'vmId': existing_record.get('vmId', str(uuid.uuid4())),
                  'sourceVM': str(args.vm), 'environment': environment,
                  'constructionPending': True,
                  'constructionConsoleUser': selected_console_user(args, existing_record)}
        if existing_record.get('consoleUser'):
            record['consoleUser'] = existing_record['consoleUser']
        if existing_record.get('guestAccessID'):
            record['guestAccessID'] = existing_record['guestAccessID']
        record.update(inherited_preparation)
        atomic_json(record_path, record)
    if record.get('constructionPending'):
        check_setup_stop(operation)
        with clone_cancellation_signals():
            clone_vm(existing_baseline if existing_baseline.exists() else args.vm, candidate)
            created_build_data = configure_build_storage(candidate, environment['buildData']['bytes'])
            metadata_path = candidate / '.vbdata/Metadata.plist'
            with open_regular(metadata_path) as file:
                metadata = plistlib.load(file)
            metadata['uuid'] = record['vmId']
            with open(metadata_path, 'wb') as file:
                plistlib.dump(metadata, file)
            record.update({'environment': environment, 'buildDataInitializationAllowed': created_build_data})
            record.pop('constructionPending')
            record.pop('constructionConsoleUser')
            atomic_json(record_path, record)
    check_setup_stop(operation)
    configuration = stage_provisioning(args, state, exchange, environment, record, binaries)
    request_id = configuration.get('provisioningRequestID')
    if request_id and request_id != record.get('pendingProvisioning', {}).get('id'):
        record['pendingProvisioning'] = {'id': request_id, 'path': str(exchange / 'provision'),
                                        'consoleUser': configuration['consoleUser']}
        if configuration.get('provisionNewAccount'):
            record['pendingProvisioning']['initialAccountPasswordPath'] = str(state / 'initial-guest-password')
        record.pop('baseVerifiedAt', None)
        atomic_json(record_path, record)
    check_setup_stop(operation)
    args.guest_user = configuration['consoleUser']
    console_user = configuration['consoleUser']
    ensure_disk_idle(candidate)
    configure_guest_hardware(candidate, record['vmId'])
    source = snapshot_source(ROOT, exchange)
    verify_setup_sources(exchange, source_digest, environment, configuration, bootstrap_tools)
    check_setup_stop(operation)
    password = None
    if configuration.get('provisionNewAccount'):
        password = Path(record['pendingProvisioning']['initialAccountPasswordPath'])
        if password != state / 'initial-guest-password':
            raise RunnerError('The initial account password must remain in the runner-owned state directory')
        if not password.exists():
            create_initial_guest_password(password)
    print(f'Prepared guest installation: {candidate}', flush=True)
    print(f'Provisioning files: {exchange / "provision"}', flush=True)
    if args.stage_only:
        result = {'version': 1, 'runId': run_id, 'status': 'blocked', 'reason': 'guest_provisioning_required'}
        atomic_json(exchange / 'artifacts/result.json', result)
    else:
        result, exchange = run_setup_doctor(args, state, candidate, environment, operation, record,
            configuration, binaries, bootstrap_tools, source, password, source_digest)
    require_current_bootstrap_sources(source_digest)
    if result['status'] == 'passed':
        check_setup_stop(operation)
    reported_tools = result.get('preflight', {}).get('bootstrap', {})
    pinned_environment_matches = environment_attested(result.get('preflight', {}), environment)
    provisioning_issue = setup_provisioning_issue(result, record['vmId'], console_user, request_id)
    if provisioning_issue and (result.get('identity') or result['status'] == 'passed'):
        result.update({'status': 'blocked', 'reason': provisioning_issue})
        atomic_json(exchange / 'artifacts/result.json', result)
        record.pop('baseVerifiedAt', None)
        atomic_json(record_path, record)
    if (not provisioning_issue and reported_tools.get('available') and
            reported_tools.get('hashes') == bootstrap_tools and pinned_environment_matches):
        base_checks = result.get('preflight', {}).get('checks', {})
        required_base = ('bootstrap', 'node', 'python', 'jq', 'xcode', 'macos', 'ios', 'visionos')
        if all(base_checks.get(name) is True for name in required_base):
            record.update({'baseVerifiedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                           'consoleUser': console_user,
                           'bootstrapTools': bootstrap_tools, 'bootstrapSourceDigest': source_digest})
            atomic_json(record_path, record)
    if result['status'] == 'passed' and not pinned_environment_matches:
        result.update({'status': 'blocked', 'reason': 'guest_environment_does_not_match_host_pins'})
        atomic_json(exchange / 'artifacts/result.json', result)
    if result['status'] == 'passed':
        if not reported_tools.get('available') or reported_tools.get('hashes') != bootstrap_tools:
            raise RunnerError('Guest did not attest the current installed bootstrap tools; rerun the guest installer')
        verification_id, verification_exchange = new_exchange(state, 'setup-validation')
        handoff_setup_operation(state, candidate, operation, verification_id, verification_exchange)
        source = snapshot_source(ROOT, verification_exchange)
        verify_setup_sources(verification_exchange, source_digest, environment)
        verification_job = {'version': 1, 'runId': verification_id,
                    'vmId': record['vmId'], 'kind': 'run', 'profile': 'all',
                    'payload': {'stages': ['test'], 'configuration': 'Debug', 'signing': 'local', 'runtimePlatforms': ['macos'],
                                'onlyTesting': ['WindowAuthenticationSessionTests', 'PasswordStorageTests', 'SecretHandlingTests']},
                    'source': source, 'bootstrapTools': bootstrap_tools}
        atomic_json(verification_exchange / 'job.json', verification_job)
        stage_planned_result(verification_exchange, verification_job)
        check_setup_stop(operation)
        hook = prepared_guest_hook(state, candidate, record, verification_exchange)
        result = monitor_vm(args, state, candidate, verification_exchange, verification_id, binaries,
                            environment, args.timeout or 7200, keep_operation=True,
                            previous_stops=operation['previousStops'], setup_hook=hook)
        exchange = verification_exchange
        require_current_bootstrap_sources(source_digest)
        if result['status'] == 'passed':
            check_setup_stop(operation)
        provisioning_issue = setup_provisioning_issue(result, record['vmId'], console_user, request_id)
        if result['status'] == 'passed' and provisioning_issue:
            result.update({'status': 'blocked', 'reason': provisioning_issue})
            atomic_json(exchange / 'artifacts/result.json', result)
            record.pop('baseVerifiedAt', None)
            atomic_json(record_path, record)
        if result['status'] == 'passed' and not environment_attested(result.get('preflight', {}), environment):
            result.update({'status': 'blocked', 'reason': 'guest_environment_changed_during_validation'})
            atomic_json(exchange / 'artifacts/result.json', result)
        if result['status'] == 'passed':
            metadata = candidate.lstat()
            record.update({'verifiedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                           'verificationSigningMode': 'local',
                           'buildDataInitializationAllowed': False,
                           'bootstrapTools': bootstrap_tools,
                           'bootstrapSourceDigest': source_digest,
                           'validationResult': str(exchange / 'artifacts/result.json'),
                           'promotionPending': {'backup': 'previous-baseline-' + uuid.uuid4().hex + '.vbvm',
                                                'candidateFileID': [metadata.st_dev, metadata.st_ino]}})
            atomic_json(record_path, record)
            finish_baseline_promotion(state, record)
    print(f'Results: {exchange / "artifacts/result.json"}')
    if result['status'] != 'passed':
        print('Full setup validation is incomplete; see the report and provisioning log for missing prerequisites or failures.')
        print('Rerunning setup reuses retained inputs. Use --candidate for diagnostic runs after base prerequisites are verified.')
        print('The original VirtualBuddy VM was not modified.')
        return 2
    print('Prepared baseline verified with local signing. Run Scripts/test_vm.sh run all; Apple signing is checked only with --signing apple.')
    return 0


def run_tests(args, state, environment, *, result_callback=None):
    candidate_record = state / 'candidate.json'
    if candidate_record.exists() and read_json(candidate_record).get('promotionPending'):
        raise RunnerError('Baseline promotion is incomplete. Run setup to finish it before testing.')
    record_path = state / ('candidate.json' if args.candidate else 'baseline.json')
    template = state / ('candidate.vbvm' if args.candidate else 'baseline.vbvm')
    if not record_path.exists():
        raise RunnerError('No verified baseline. Run Scripts/test_vm.sh setup first; no host tests were started.')
    record = read_json(record_path)
    if not matches_source_vm(record, args.vm):
        raise RunnerError('Prepared VM belongs to another source VM; use the matching --vm and --state-dir')
    if args.candidate and not record.get('baseVerifiedAt'):
        raise RunnerError('Candidate base setup has not been verified. Run setup first; no host tests were started.')
    if record.get('environment') != environment:
        raise RunnerError('Pinned environment changed. Re-run setup to validate a new baseline.')
    if record.get('bootstrapSourceDigest') != bootstrap_source_digest():
        raise RunnerError('Guest bootstrap/environment changed. Re-run setup before testing.')
    check_capacity(state, environment['minimumHostFreeBytes'])
    run_id, exchange = new_exchange(state, 'run')
    clone = state / 'runs' / (run_id + '.vbvm')
    clone_owned = False
    preparation_reason = 'host_preparation_failed'
    result = None
    register_operation(state, clone, exchange, run_id, 'preparing')
    print(f'VM run: {run_id}\nResults: {exchange}', flush=True)
    try:
        try:
            with clone_cancellation_signals():
                binaries = build_tools(state, args.xcode)
                bootstrap_tools = bootstrap_tool_hashes(binaries)
                if record.get('bootstrapTools') != bootstrap_tools:
                    raise RunnerError('Guest bootstrap tools changed. Re-run setup before testing.')
                source = snapshot_source(ROOT, exchange)
                if bootstrap_source_digest(exchange / 'source/Scripts/vm') != record['bootstrapSourceDigest']:
                    raise RunnerError('The snapshotted guest bootstrap/environment does not match the verified VM. Re-run setup before testing.')
                job = {'version': 1, 'runId': run_id, 'vmId': record['vmId'], 'kind': 'run',
                       'profile': args.profile, 'payload': {'stages': args.stage, 'onlyTesting': args.only_testing,
                                                          'signing': args.signing}, 'source': source,
                       'bootstrapTools': bootstrap_tools}
                if args.configuration:
                    job['payload']['configuration'] = args.configuration
                if getattr(args, 'runtime_platform', None):
                    job['payload']['runtimePlatforms'] = args.runtime_platform
                if getattr(args, 'interactive_safari', False):
                    job['payload']['interactiveSafari'] = True
                if args.approval_arg:
                    job['payload']['approvalArgs'] = stage_approval_arguments(args.approval_arg, exchange)
                atomic_json(exchange / 'job.json', job)
                plan = stage_planned_result(exchange, job)
                preparation = prepared_safari_for_job(record, job, plan)
                if preparation is not None:
                    job['payload']['preparedSafari'] = preparation
                    atomic_json(exchange / 'job.json', job)
                    stage_planned_result(exchange, job)
                if getattr(args, 'interactive_safari', False):
                    print('Assisted Safari run: use the owned Safari Activation VM window for extension activation checkpoints. '
                          'The same disposable guest and installation remain active through browser restart.', flush=True)
                print(f'Source: {source["sha256"]}', flush=True)
                if operation_stop_requested(exchange, run_id):
                    raise KeyboardInterrupt
                preparation_reason = 'vm_clone_failed'
                private_directory(clone.parent)
                if clone.exists() or clone.is_symlink():
                    raise RunnerError(f'Clone destination already exists: {clone}')
                register_operation(state, clone, exchange, run_id, 'preparing', clone_owned=True)
                clone_owned = True
                clone_vm(template, clone)
                hook = prepared_guest_hook(state, clone, record, exchange)
                if operation_stop_requested(exchange, run_id):
                    raise KeyboardInterrupt
        except KeyboardInterrupt as error:
            result = finalize_owned_interruption(state, exchange, run_id, 'cancelled', host_error=type(error).__name__)
        except (RunnerError, OSError) as error:
            result = finalize_owned_interruption(state, exchange, run_id, preparation_reason, host_error=str(error))
        else:
            result = monitor_vm(args, state, clone, exchange, run_id, binaries, environment,
                                args.timeout or (48 * 3600 if args.profile == 'extended' else 24 * 3600),
                                keep_operation=True, setup_hook=hook)
    finally:
        try:
            result_path = exchange / 'artifacts/result.json'
            if result_callback is not None and result_path.exists():
                result_callback(result_path, read_json(result_path))
        except Exception:
            if result is not None:
                raise
        finally:
            if clone_owned and (clone.exists() or clone.is_symlink()):
                if clone.is_symlink() or not clone.is_dir():
                    raise RunnerError('The clone path changed type; preserving it for inspection')
                active = read_json(state / 'active.json')
                if (active.get('runId') != run_id or active.get('vm') != str(clone) or
                        active.get('exchange') != str(exchange) or active.get('ownerPID') != os.getpid()):
                    raise RunnerError('Another operation owns the clone; preserving it for inspection')
                ensure_disk_idle(clone)
                if not retain_clone_diagnostics(active):
                    shutil.rmtree(clone)
            if result is not None:
                clear_owned_operation(state, run_id)
    print(f'{result["status"].upper()}: {exchange / "artifacts/result.json"}')
    return 0 if result['status'] == 'passed' else 1


def parser():
    parser = argparse.ArgumentParser(description='Build and test only inside a headless macOS VM. Host Node.js 18+ generates the pure test-plan inventory.')
    parser.add_argument('--vm', type=Path, default=DEFAULT_VM)
    parser.add_argument('--state-dir', type=Path, default=Path(os.environ.get('BW_TEST_VM_STATE_DIR', DEFAULT_STATE)))
    parser.add_argument('--xcode', type=Path, default=Path('/Applications/Xcode.app'))
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('doctor')
    commands.add_parser('status')
    commands.add_parser('stop')
    upgrade_parser = commands.add_parser('upgrade-xcode', allow_abbrev=False,
                                        help='Adopt installed Xcode, prepare the VM, and verify the full local suite')
    upgrade_parser.add_argument('--check', action='store_true', help='Preview pins and prerequisites without writing files or starting a VM')
    upgrade_parser.add_argument('--timeout', type=int, help='Per-setup/run timeout in seconds')
    setup_parser = commands.add_parser('setup')
    setup_parser.add_argument('--guest-user')
    setup_parser.add_argument('--provision-config', type=Path)
    setup_parser.add_argument('--proof-key-bundle', type=Path)
    setup_parser.add_argument('--provision-new-account', action='store_true')
    setup_parser.add_argument('--safari-activation', action='store_true',
                              help='Prepare genuine Safari extension activation in a current baseline; requires --interactive')
    setup_mode = setup_parser.add_mutually_exclusive_group()
    setup_mode.add_argument('--stage-only', action='store_true')
    setup_mode.add_argument('--interactive', action='store_true', help='Show only the owned setup VM for one-time guest consent')
    setup_parser.add_argument('--timeout', type=int)
    run_parser = commands.add_parser('run', allow_abbrev=False)
    run_parser.add_argument('profile', choices=('all', 'extended'), nargs='?', default='all')
    run_parser.add_argument('--candidate', action='store_true', help='Run diagnostics against a base-verified candidate before setup smoke tests pass')
    run_parser.add_argument('--interactive-safari', action='store_true',
                            help='Show the disposable test VM for genuine user activation of macOS Safari extensions')
    run_parser.add_argument('--signing', choices=('local', 'apple'), default='local',
                            help='Use credential-free local signing by default, or explicitly verify Apple signing prerequisites')
    run_parser.add_argument('--stage', choices=STAGES, action='append', default=[])
    run_parser.add_argument('--only-testing', action='append', default=[])
    run_parser.add_argument('--runtime-platform', choices=('macos', 'ios', 'visionos'), action='append', default=[],
                            help='Limit package XCTest destinations; repeat to select multiple platforms (default: all three)')
    run_parser.add_argument('--configuration', choices=('Debug', 'Release'))
    run_parser.add_argument('--approval-arg', action='append', default=[])
    run_parser.add_argument('--timeout', type=int)
    return parser


def main(argv=None):
    args = parser().parse_args(argv)
    os.umask(0o077)
    try:
        if sys.platform != 'darwin' or os.uname().machine != 'arm64':
            raise RunnerError('The host VM launcher requires an Apple silicon Mac')
        args.vm = normalize_source_vm(args.vm)
        args.xcode = args.xcode.expanduser().resolve()
        if getattr(args, 'timeout', None) is not None and args.timeout <= 0:
            raise RunnerError('Timeout must be positive')
        if args.command == 'upgrade-xcode' and args.check:
            state = args.state_dir.expanduser().absolute().resolve()
            return xcode_upgrade_module().upgrade(SimpleNamespace(**globals()), args, state)
        state = private_directory(args.state_dir.expanduser().absolute()).resolve()
        environment = read_json(TOOLS / 'environment.json')
        if args.command == 'doctor':
            report = host_doctor(args, state, environment)
            print(json.dumps(report, indent=2))
            return 0 if report['status'] == 'passed' else 2
        if args.command in ('status', 'stop'):
            if not (state / 'active.json').exists():
                print('No VM operation is active.')
                return 0
            active = read_json(state / 'active.json')
            exchange = Path(active['exchange'])
            if exchange.is_symlink() or not any(exchange.resolve().is_relative_to(state / folder) for folder in ('results', 'setup')):
                raise RunnerError('Active operation points outside runner-owned results')
            if args.command == 'stop':
                publish_stop(exchange, active['runId'], requested=True)
                print(f'Stop requested for {active["runId"]}. Diagnostics will be retained.')
            else:
                status_path = exchange / 'vm-status.json'
                if status_path.exists():
                    active['vmStatus'] = read_json(status_path)
                print(json.dumps(active, indent=2))
            return 0
        with execution_lock(state):
            reconcile_interrupted_operation(state)
            if args.command == 'setup':
                return setup(args, state, environment)
            if args.command == 'upgrade-xcode':
                return xcode_upgrade_module().upgrade(SimpleNamespace(**globals()), args, state)
            return run_tests(args, state, environment)
    except (RunnerError, OSError, ValueError, KeyError, RuntimeError) as error:
        print(f'VM testing blocked: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
