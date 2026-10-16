import base64
import contextlib
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import re
import select
import shlex
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import uuid


class GuestAccessError(Exception):
    pass


def _regular(path, *, private=False):
    path = Path(path).absolute()
    if path.parent.resolve() != path.parent or path.is_symlink():
        raise GuestAccessError('Guest access paths must not traverse symlinks')
    metadata = path.stat()
    if not stat.S_ISREG(metadata.st_mode):
        raise GuestAccessError('Guest access requires a regular file')
    if private and (metadata.st_uid != os.getuid() or metadata.st_mode & 0o077):
        raise GuestAccessError('Guest credentials must be private and owned by the current user')
    if private:
        _private_directory(path.parent)
    return path


def _private_directory(path):
    path = Path(path).absolute()
    if path.resolve() != path or not path.is_dir():
        raise GuestAccessError('Guest access requires a real private directory')
    metadata = path.stat()
    if metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
        raise GuestAccessError('Guest access directory must be private and owned by the current user')
    return path


def _read(path, *, private=False, maximum=1024 * 1024):
    path = _regular(path, private=private)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as file:
        metadata = os.fstat(file.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > maximum:
            raise GuestAccessError('Guest access file has an invalid size or type')
        if private and (metadata.st_uid != os.getuid() or metadata.st_mode & 0o077):
            raise GuestAccessError('Guest credentials must remain private')
        return file.read(maximum + 1), metadata


def _checked(command):
    with _defer_cancellation():
        try:
            result = subprocess.run(command, capture_output=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired):
            raise GuestAccessError(f'{Path(command[0]).name} could not complete guest disk access') from None
        if result.returncode:
            raise GuestAccessError(f'{Path(command[0]).name} failed during guest disk access')
        return result.stdout


def _plist(command):
    try:
        return plistlib.loads(_checked(command))
    except (ValueError, plistlib.InvalidFileException):
        raise GuestAccessError('Guest disk inventory was not a valid plist') from None


def _mac(value):
    parts = str(value).lower().split(':')
    if len(parts) != 6 or any(not re.fullmatch('[0-9a-f]{1,2}', part) for part in parts):
        raise GuestAccessError('The candidate VM requires a valid fixed MAC address')
    normalized = ':'.join(part.zfill(2) for part in parts)
    if int(parts[0], 16) & 1 or normalized == '00:00:00:00:00:00':
        raise GuestAccessError('The candidate VM requires a unicast MAC address')
    return normalized


def candidate_mac(candidate):
    candidate = Path(candidate).absolute()
    if candidate.resolve() != candidate or candidate.suffix != '.vbvm' or not candidate.is_dir():
        raise GuestAccessError('Guest access requires the owned candidate VM bundle')
    contents, _ = _read(candidate / '.vbdata/Config.plist')
    try:
        configuration = plistlib.loads(contents)
        networks = configuration['hardware']['networkDevices']
        if configuration.get('systemType') != 'mac' or len(networks) != 1:
            raise ValueError()
        return _mac(networks[0]['macAddress'])
    except (KeyError, TypeError, ValueError, plistlib.InvalidFileException):
        raise GuestAccessError('The candidate must have one configured macOS network device') from None


def select_data_volume(attachment, inventory):
    devices = {Path(entity.get('dev-entry', '')).name for entity in attachment.get('system-entities', [])}
    containers = [container for container in inventory.get('Containers', [])
                  if any(store.get('DeviceIdentifier') in devices for store in container.get('PhysicalStores', []))]
    volumes = [volume for container in containers for volume in container.get('Volumes', [])
               if 'Data' in volume.get('Roles', [])]
    if len(volumes) != 1:
        raise GuestAccessError('The candidate disk must contain exactly one matching APFS Data volume')
    device = volumes[0].get('DeviceIdentifier', '')
    if not re.fullmatch(r'disk\d+s\d+', device):
        raise GuestAccessError('The candidate Data device identifier is invalid')
    return device


def _attachment_root(attachment):
    physical = [entity for entity in attachment.get('system-entities', [])
                if re.fullmatch(r'/dev/disk\d+', entity.get('dev-entry', '')) and
                entity.get('content-hint') == 'GUID_partition_scheme']
    return physical[0]['dev-entry'] if len(physical) == 1 else None


def _check_unencrypted_image(path):
    specification = importlib.util.spec_from_file_location('big_wallet_apfs_preflight',
                                                          Path(__file__).with_name('apfs_preflight.py'))
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    try:
        module.check_unencrypted_image(path)
    except module.PreflightError as error:
        raise GuestAccessError(str(error)) from None


@contextlib.contextmanager
def attached_data(candidate, *, owners):
    candidate_mac(candidate)
    disk = _regular(Path(candidate) / 'Disk.img')
    if disk.stat().st_uid != os.getuid():
        raise GuestAccessError('The candidate disk must be owned by the current user')
    try:
        busy = subprocess.run(['/usr/sbin/lsof', '-t', '+w', str(disk)], capture_output=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        raise GuestAccessError('Could not establish exclusive access to the candidate disk') from None
    if busy.stdout.strip():
        raise GuestAccessError('The candidate disk must be idle before guest access')
    if busy.returncode not in (0, 1) or busy.stderr.strip():
        raise GuestAccessError('Could not establish exclusive access to the candidate disk')
    _check_unencrypted_image(disk)
    for image in _plist(['/usr/bin/hdiutil', 'info', '-plist']).get('images', []):
        if Path(image.get('image-path', '')).absolute() == disk:
            raise GuestAccessError('The candidate disk is already attached')
    detach_device = None
    try:
        attachment = _plist(['/usr/bin/hdiutil', 'attach', '-imagekey', 'diskimage-class=CRawDiskImage',
                             '-readwrite', '-nobrowse', '-owners',
                             'on' if owners else 'off', '-plist', str(disk)])
        detach_device = _attachment_root(attachment)
        if not detach_device:
            raise GuestAccessError('The attached candidate did not report its detach device')
        device = select_data_volume(attachment, _plist(['/usr/sbin/diskutil', 'apfs', 'list', '-plist']))
        info = _plist(['/usr/sbin/diskutil', 'info', '-plist', device])
        mount = Path(info.get('MountPoint', ''))
        if info.get('DeviceIdentifier') != device or not mount.is_absolute() or mount.resolve() != mount or not mount.is_dir():
            raise GuestAccessError('The candidate Data volume did not mount at a real directory')
        yield mount
    finally:
        if detach_device is None:
            images = _plist(['/usr/bin/hdiutil', 'info', '-plist']).get('images', [])
            matches = [image for image in images if Path(image.get('image-path', '')).absolute() == disk]
            if len(matches) == 1:
                detach_device = _attachment_root(matches[0])
        if detach_device:
            _checked(['/usr/bin/hdiutil', 'detach', detach_device])


def _public_key(line):
    pieces = line.strip().split()
    if len(pieces) < 2 or pieces[0] not in ('ssh-ed25519', 'ssh-rsa', 'ecdsa-sha2-nistp256', 'ecdsa-sha2-nistp384', 'ecdsa-sha2-nistp521'):
        raise GuestAccessError('The guest SSH public key format is invalid')
    try:
        blob = base64.b64decode(pieces[1], validate=True)
        length = int.from_bytes(blob[:4], 'big')
        if not 0 < length <= 64 or blob[4:4 + length].decode('ascii') != pieces[0] or len(blob) <= length + 4:
            raise ValueError()
    except (ValueError, UnicodeError):
        raise GuestAccessError('The guest SSH public key encoding is invalid') from None
    return ' '.join(pieces[:2])


def _protected_root_directory(path):
    metadata = path.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o022:
        raise GuestAccessError('Guest access directories must be root-owned and protected')


def _protected_guest_plist(mount, relative, label):
    path = mount / relative
    for parent in (path.parent, *path.parent.parents):
        if not parent.is_relative_to(mount):
            break
        _protected_root_directory(parent)
    original, metadata = _read(path)
    if metadata.st_uid != 0 or metadata.st_mode & 0o022:
        raise GuestAccessError(f'The existing guest {label} must be root-owned and protected')
    try:
        configuration = plistlib.loads(original)
        if not isinstance(configuration, dict):
            raise ValueError()
    except (ValueError, plistlib.InvalidFileException):
        raise GuestAccessError(f'The guest {label} is invalid') from None
    return original, metadata, configuration


def _alias(vm_id):
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', vm_id):
        raise GuestAccessError('The guest SSH identity is invalid')
    return f'big-wallet-vm-{vm_id}'


@contextlib.contextmanager
def _defer_cancellation():
    handlers = {}
    pending = []

    def defer(signum, frame):
        if not pending and handlers.get(signum) != signal.SIG_IGN:
            pending.append((signum, frame))

    try:
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            handlers[signum] = signal.signal(signum, defer)
        yield
    finally:
        for signum, handler in handlers.items():
            signal.signal(signum, handler)
        if pending:
            signum, frame = pending[0]
            handler = handlers[signum]
            if callable(handler):
                handler(signum, frame)
            elif handler == signal.SIG_DFL:
                signal.raise_signal(signum)


def _replace_contents(path, expected, replacement, inode):
    _regular(path)
    descriptor = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'r+b') as file:
        if os.fstat(file.fileno()).st_ino != inode or file.read() != expected:
            raise GuestAccessError('The guest service configuration changed during offline access')
        with _defer_cancellation():
            try:
                file.seek(0)
                file.write(replacement)
                file.truncate()
                file.flush()
                os.fsync(file.fileno())
            except BaseException as error:
                file.seek(0)
                file.write(expected)
                file.truncate()
                file.flush()
                os.fsync(file.fileno())
                if isinstance(error, OSError):
                    raise GuestAccessError('The guest service configuration could not be updated') from None
                raise


def prepare_guest_access(candidate, private_workdir, vm_id, console_user, first_boot_ssh_requested=False):
    if not isinstance(console_user, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', console_user):
        raise GuestAccessError('The selected guest console user is invalid')
    work = _private_directory(private_workdir)
    mac = candidate_mac(candidate)
    alias = _alias(vm_id)
    service_relative = Path('private/var/db/com.apple.xpc.launchd/disabled.plist')
    login_relative = Path('Library/Preferences/com.apple.loginwindow.plist')
    changes = []
    public_keys = []
    with attached_data(candidate, owners=True) as mount:
        path = mount / service_relative
        if path.exists() or path.is_symlink():
            original, metadata, configuration = _protected_guest_plist(mount, service_relative, 'service configuration')
            if configuration.get('com.openssh.sshd') is not False:
                configuration['com.openssh.sshd'] = False
                replacement = plistlib.dumps(configuration, fmt=plistlib.FMT_BINARY if original.startswith(b'bplist00') else plistlib.FMT_XML)
                changes.append((service_relative, original, replacement, metadata))
        elif not first_boot_ssh_requested:
            raise GuestAccessError('Guest SSH requires an existing service configuration or first-boot Remote Login provisioning')
        path = mount / login_relative
        if path.exists() or path.is_symlink():
            original, metadata, configuration = _protected_guest_plist(mount, login_relative, 'automatic login preferences')
            if 'autoLoginUser' in configuration and not isinstance(configuration['autoLoginUser'], str):
                raise GuestAccessError('The guest automatic login account is invalid')
            locked = configuration.get('autoLoginUserScreenLocked')
            if 'autoLoginUserScreenLocked' in configuration and (type(locked) not in (bool, int) or locked not in (0, 1)):
                raise GuestAccessError('The guest remembered automatic login lock flag is invalid')
            if configuration.get('autoLoginUser') == console_user and locked:
                configuration['autoLoginUserScreenLocked'] = False if type(locked) is bool else 0
                replacement = plistlib.dumps(configuration, fmt=plistlib.FMT_BINARY if original.startswith(b'bplist00') else plistlib.FMT_XML)
                changes.append((login_relative, original, replacement, metadata))
        directory = mount / 'private/etc/ssh'
        if directory.exists():
            if directory.resolve() != directory:
                raise GuestAccessError('The guest SSH public key directory must not be a symlink')
            for parent in (directory, *directory.parents):
                if not parent.is_relative_to(mount):
                    break
                _protected_root_directory(parent)
            for key in sorted(directory.glob('ssh_host_*_key.pub')):
                contents, key_metadata = _read(key, maximum=16384)
                if key_metadata.st_uid != 0 or key_metadata.st_mode & 0o022:
                    raise GuestAccessError('Guest SSH public keys must be root-owned and protected')
                try:
                    public_keys.append(_public_key(contents.decode('ascii')))
                except UnicodeError:
                    raise GuestAccessError('The guest SSH public key is not ASCII') from None
    if changes:
        with attached_data(candidate, owners=False) as mount:
            for relative, original, _, metadata in changes:
                current, current_metadata = _read(mount / relative)
                if current != original or current_metadata.st_ino != metadata.st_ino:
                    raise GuestAccessError('The guest configuration changed during offline access')
            for relative, original, replacement, metadata in changes:
                _replace_contents(mount / relative, original, replacement, metadata.st_ino)
        with attached_data(candidate, owners=True) as mount:
            for relative, _, replacement, metadata in changes:
                final, final_metadata = _read(mount / relative)
                if (final != replacement or final_metadata.st_ino != metadata.st_ino or
                        (final_metadata.st_uid, final_metadata.st_gid, stat.S_IMODE(final_metadata.st_mode)) !=
                        (metadata.st_uid, metadata.st_gid, stat.S_IMODE(metadata.st_mode))):
                    raise GuestAccessError('The guest configuration did not preserve its ownership and permissions')
    known_hosts = None
    if public_keys:
        descriptor, name = tempfile.mkstemp(prefix='known-hosts-', dir=work)
        known_hosts = Path(name)
        with os.fdopen(descriptor, 'w') as file:
            file.write(''.join(f'{alias} {key}\n' for key in sorted(set(public_keys))))
    return {'macAddress': mac, 'hostKeyAlias': alias, 'knownHosts': known_hosts,
            'publicKeyCount': len(set(public_keys)), 'remoteLoginChanged': any(change[0] == service_relative for change in changes),
            'automaticLoginLockCleared': any(change[0] == login_relative for change in changes)}


def parse_dhcp_leases(contents, mac, now=None):
    mac = _mac(mac)
    now = time.time() if now is None else now
    active = []
    for block in re.findall(r'\{([^{}]*)\}', contents):
        record = dict(re.findall(r'^\s*([a-z_]+)\s*=\s*([^\r\n]+)', block, re.MULTILINE))
        raw_mac = record.get('hw_address', '').strip().removeprefix('1,')
        try:
            address_mac = _mac(raw_mac)
            expiry = int(record.get('lease', '').strip(), 0)
            address = ipaddress.IPv4Address(record.get('ip_address', '').strip())
        except (GuestAccessError, ValueError):
            if raw_mac.lower() == mac:
                raise GuestAccessError('The candidate DHCP lease is malformed') from None
            continue
        if expiry <= now:
            continue
        if address_mac == mac and (not address.is_private or address.is_loopback or address.is_link_local or address.is_unspecified):
            raise GuestAccessError('The candidate DHCP lease must use a private guest address')
        active.append((address_mac, str(address)))
    addresses = {address for address_mac, address in active if address_mac == mac}
    if len(addresses) > 1 or any(address_mac != mac and address in addresses for address_mac, address in active):
        raise GuestAccessError('The candidate DHCP lease is ambiguous')
    return next(iter(addresses), None)


def find_guest_address(mac, lease_path='/var/db/dhcpd_leases', now=None):
    try:
        contents = Path(lease_path).read_text()
    except FileNotFoundError:
        return None
    return parse_dhcp_leases(contents, mac, now)


def _address(address):
    try:
        value = ipaddress.IPv4Address(address)
        if not value.is_private or value.is_loopback or value.is_link_local or value.is_unspecified:
            raise ValueError()
    except ValueError:
        raise GuestAccessError('Guest SSH requires a private numeric VM address') from None
    return str(value)


def read_private_password(path):
    contents, _ = _read(path, private=True, maximum=4096)
    contents = contents.removesuffix(b'\n').removesuffix(b'\r')
    if not contents or any(byte in contents for byte in (b'\n', b'\r', b'\0')):
        raise GuestAccessError('The guest password file must contain one nonempty line')
    return contents


def ssh_command(address, user, known_hosts, host_key_alias):
    address = _address(address)
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', user) or not re.fullmatch(r'big-wallet-vm-[A-Za-z0-9_-]{1,128}', host_key_alias):
        raise GuestAccessError('The guest SSH account or host identity is invalid')
    contents, _ = _read(known_hosts, private=True, maximum=65536)
    lines = contents.decode('ascii').splitlines()
    if not lines or any(not line.startswith(host_key_alias + ' ') for line in lines):
        raise GuestAccessError('Guest SSH requires public keys pinned to this VM')
    for line in lines:
        _public_key(line.split(' ', 1)[1])
    escaped = str(Path(known_hosts).absolute()).replace('\\', '\\\\').replace('"', '\\"')
    options = [f'UserKnownHostsFile="{escaped}"', f'HostKeyAlias={host_key_alias}',
               'GlobalKnownHostsFile=/dev/null', 'StrictHostKeyChecking=yes', 'UpdateHostKeys=no',
               'IdentityAgent=none', 'IdentitiesOnly=yes', 'PubkeyAuthentication=no',
               'PasswordAuthentication=yes', 'KbdInteractiveAuthentication=no', 'GSSAPIAuthentication=no',
               'HostbasedAuthentication=no', 'UseKeychain=no', 'NumberOfPasswordPrompts=1',
               'ClearAllForwardings=yes', 'ForwardAgent=no', 'ForwardX11=no', 'Tunnel=no',
               'ProxyCommand=none', 'ProxyJump=none', 'PermitLocalCommand=no',
               'ControlMaster=no', 'ControlPath=none', 'RequestTTY=no',
               'ConnectTimeout=10', 'ConnectionAttempts=1', 'ServerAliveInterval=15', 'ServerAliveCountMax=3']
    return ['/usr/bin/ssh', '-F', '/dev/null', '-T', *[item for option in options for item in ('-o', option)], '-l', user, '--', address]


def installer_command(user, marker, staging_directory=None, vm_id=None):
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', user):
        raise GuestAccessError('The guest account is invalid')
    if not re.fullmatch(r'BIG_WALLET_PAYLOAD_[a-f0-9]{32}', marker):
        raise GuestAccessError('The guest payload marker is invalid')
    if staging_directory is not None:
        _staging_directory(staging_directory)
        _alias(vm_id)
        destination_setup = f'''destination={shlex.quote(staging_directory)}
for directory in /Volumes/BigWalletBuild /Volumes/BigWalletBuild/Provisioning "$(/usr/bin/dirname "$destination")" "$destination"; do
    [ -d "$directory" ] && [ ! -L "$directory" ] || exit 74
    [ "$(/usr/bin/stat -f %u "$directory")" -eq 0 ] || exit 74
    mode=$(/usr/bin/stat -f %Lp "$directory")
    case "$mode" in ''|*[!0-7]*) exit 74 ;; esac
    [ "$((0$mode & 022))" -eq 0 ] || exit 74
done
stage_root=$(/usr/bin/dirname "$destination")
stage_marker="$stage_root/.big-wallet-provisioning.json"
[ -f "$stage_marker" ] && [ ! -L "$stage_marker" ] || exit 74
[ "$(/usr/bin/stat -f %u:%Lp "$stage_marker")" = 0:600 ] || exit 74
[ "$(/usr/bin/plutil -extract version raw -o - "$stage_marker")" = 1 ] || exit 74
[ "$(/usr/bin/plutil -extract vmId raw -o - "$stage_marker")" = {shlex.quote(vm_id)} ] || exit 74
cleanup_stage() {{
    if [ -f "$stage_marker" ] && [ ! -L "$stage_marker" ] &&
       [ "$(/usr/bin/stat -f %u:%Lp "$stage_marker")" = 0:600 ] &&
       [ "$(/usr/bin/plutil -extract vmId raw -o - "$stage_marker")" = {shlex.quote(vm_id)} ]; then
        /bin/rm -rf "$stage_root"
    fi
}}
trap cleanup_stage EXIT
'''
        arguments = ''
    else:
        destination_setup = '''temporary=$(/usr/bin/mktemp -d /private/tmp/big-wallet-provision.XXXXXXXX)
trap '/bin/rm -rf "$temporary"' EXIT
destination="$temporary/provision"
/bin/mkdir -m 700 "$destination"
'''
        arguments = ' --prepare-storage'
    root_script = f'''set -eu
case "$(/usr/sbin/sysctl -n hw.model)" in VirtualMac*) ;; *) exit 71 ;; esac
[ "$(/usr/bin/id -u)" -eq 0 ] || exit 72
guest_uid=$(/usr/bin/id -u {shlex.quote(user)})
[ "$guest_uid" -ge 500 ] || exit 73
umask 077
IFS= read -r payload_marker
if [ "$payload_marker" != {shlex.quote(marker)} ]; then IFS= read -r payload_marker; fi
[ "$payload_marker" = {shlex.quote(marker)} ] || exit 76
unset payload_marker
{destination_setup}
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
/usr/bin/tar --no-same-owner -xpf - -C "$destination"
[ -f "$destination/provision_guest.sh" ] && [ ! -L "$destination/provision_guest.sh" ] || exit 75
/bin/sh "$destination/provision_guest.sh" "$destination/config.json"{arguments}
'''
    return (f'case "$(/usr/sbin/sysctl -n hw.model)" in VirtualMac*) ;; *) exit 71 ;; esac; '
            f'[ "$(/usr/bin/id -un)" = {shlex.quote(user)} ] && [ "$(/usr/bin/id -u)" -ge 500 ] || exit 73; '
            f'exec /usr/bin/sudo -S -p "" -- /usr/bin/caffeinate -dimsu /bin/sh -c {shlex.quote(root_script)}')


def _staging_directory(value):
    if not isinstance(value, str) or not re.fullmatch(
            r'/Volumes/BigWalletBuild/Provisioning/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/provision', value):
        raise GuestAccessError('The guest provisioning stage is outside managed local storage')
    return value


def _payload_files(directory, user, host_key_alias):
    directory = _private_directory(directory)
    files = {}
    for path in directory.iterdir():
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', path.name):
            raise GuestAccessError('The provisioning payload contains an unsafe filename')
        _regular(path)
        if path.stat().st_uid != os.getuid():
            raise GuestAccessError('The provisioning payload must be owned by the current user')
        files[path.name] = path
    try:
        configuration = json.loads(_read(files['config.json'])[0])
        if configuration['consoleUser'] != user or _alias(configuration['vmId']) != host_key_alias:
            raise ValueError()
        large_names = {'Xcode.tar'} | {runtime['dmgPath'] for runtime in configuration.get('runtimes', []) if runtime.get('dmgPath')}
        if any(name not in files for name in large_names) or 'provision_guest.sh' not in files:
            raise ValueError()
    except (KeyError, TypeError, ValueError):
        raise GuestAccessError('The provisioning payload does not match this VM, account, or required inputs') from None
    small = {name: path for name, path in files.items() if name not in large_names}
    if len(files) > 1024 or any(path.suffix.lower() == '.dmg' for path in small.values()) or sum(path.stat().st_size for path in small.values()) > 256 * 1024 * 1024:
        raise GuestAccessError('The initial provisioning payload exceeds its small-file limit')
    return small, {name: files[name] for name in large_names}


def _prepare_response(output, allowed_inputs):
    prefix = b'BIG_WALLET_PROVISIONING_STAGE='
    lines = [line[len(prefix):] for line in output.splitlines() if line.startswith(prefix)]
    try:
        if len(lines) != 1 or len(lines[0]) > 65536:
            raise ValueError()
        response = json.loads(lines[0])
        if (not isinstance(response, dict) or set(response) - {'stagingDirectory', 'requiredInputs', 'requiresRestart'} or
                not isinstance(response.get('requiredInputs'), list) or
                not isinstance(response.get('requiresRestart', False), bool)):
            raise ValueError()
        _staging_directory(response.get('stagingDirectory'))
        required = response['requiredInputs']
        if any(not isinstance(name, str) or name not in allowed_inputs for name in required) or len(set(required)) != len(required):
            raise ValueError()
        return response
    except (ValueError, TypeError, GuestAccessError):
        raise GuestAccessError('The guest storage preparation response is invalid') from None


class _PayloadProducer:
    def __init__(self, pipe, password, marker, files):
        self.pipe = pipe
        self.password = password
        self.marker = marker
        self.files = files
        self.cancelled = threading.Event()
        self.done = threading.Event()
        self.error = None
        self.thread = threading.Thread(target=self._run, name='guest-provisioning-upload', daemon=True)
        self.thread.start()

    def write(self, data):
        view = memoryview(data)
        while view:
            if self.cancelled.is_set():
                raise InterruptedError()
            try:
                count = os.write(self.pipe.fileno(), view)
                if count <= 0:
                    raise BrokenPipeError()
                view = view[count:]
            except BlockingIOError:
                select.select([], [self.pipe.fileno()], [], 0.1)
        return len(data)

    def flush(self):
        pass

    def _run(self):
        try:
            os.set_blocking(self.pipe.fileno(), False)
            self.write(self.password + b'\n' + self.marker.encode('ascii') + b'\n')
            self.password = b''
            with tarfile.open(fileobj=self, mode='w|', format=tarfile.PAX_FORMAT, bufsize=1024 * 1024) as archive:
                for name, path in sorted(self.files.items()):
                    if self.cancelled.is_set():
                        raise InterruptedError()
                    _regular(path)
                    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
                    with os.fdopen(descriptor, 'rb') as file:
                        before = os.fstat(file.fileno())
                        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid():
                            raise GuestAccessError('The provisioning input changed before upload')
                        entry = tarfile.TarInfo(name)
                        entry.size = before.st_size
                        entry.uid = entry.gid = 0
                        entry.uname, entry.gname = 'root', 'wheel'
                        entry.mode = 0o700 if before.st_mode & 0o111 else 0o600
                        archive.addfile(entry, file)
                        after = os.fstat(file.fileno())
                        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                            raise GuestAccessError('The provisioning input changed during upload')
        except BaseException:
            self.error = 'guest_payload_transfer_failed'
        finally:
            self.password = b''
            try:
                self.pipe.close()
            except OSError:
                pass
            self.done.set()

    def cancel(self):
        self.cancelled.set()

    def join(self, timeout=3):
        self.thread.join(timeout)
        if self.thread.is_alive():
            raise GuestAccessError('The guest payload producer did not stop within its deadline')


def _stop(child, grace=3):
    if child.poll() is None:
        try:
            try:
                os.killpg(child.pid, signal.SIGTERM)
                child.wait(timeout=grace)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=3)
        except (ProcessLookupError, PermissionError) as error:
            try:
                child.wait(timeout=grace)
            except subprocess.TimeoutExpired:
                raise error from None


class SSHBannerProbe:
    def __init__(self, address):
        self.output = tempfile.TemporaryFile()
        self.result = None
        self.child = subprocess.Popen(['/usr/bin/nc', '-d', '-G', '3', '-w', '3', _address(address), '22'],
                                      stdin=subprocess.DEVNULL, stdout=self.output, stderr=subprocess.DEVNULL,
                                      start_new_session=True)

    def poll(self):
        if self.result is not None:
            return self.result
        self.output.seek(0)
        if any(line.startswith(b'SSH-2.0-') for line in self.output.read(8192).splitlines()):
            _stop(self.child)
            self.result = {'status': 'passed'}
        elif self.child.poll() is not None:
            self.result = {'status': 'failed', 'reason': 'guest_ssh_banner_unavailable'}
        if self.result:
            self.output.close()
        return self.result

    def cancel(self, grace=3):
        _stop(self.child, grace=grace)
        if not self.output.closed:
            self.output.close()
        self.result = self.result or {'status': 'failed', 'reason': 'guest_ssh_probe_cancelled'}


class GuestInstaller:
    def __init__(self, address, user, password_file, known_hosts, host_key_alias, private_workdir,
                 log_path=None, *, provision_directory):
        work = _private_directory(private_workdir)
        self.command = ssh_command(address, user, known_hosts, host_key_alias)
        self.small_files, self.large_files = _payload_files(provision_directory, user, host_key_alias)
        self.user = user
        self.vm_id = host_key_alias.removeprefix('big-wallet-vm-')
        self.password = read_private_password(password_file)
        self.result = None
        self.producer = None
        self.log_path = Path(log_path) if log_path else None
        self.output = tempfile.TemporaryFile(dir=work)
        descriptor, name = tempfile.mkstemp(prefix='guest-askpass-', dir=work)
        self.askpass = Path(name)
        with os.fdopen(descriptor, 'w') as file:
            file.write('#!/bin/sh\nexec ' + shlex.join([sys.executable, str(Path(__file__).resolve()), '--askpass', str(Path(password_file).absolute())]) + '\n')
        self.askpass.chmod(0o700)
        self.environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(work),
                            'LANG': 'C', 'SSH_ASKPASS': str(self.askpass), 'SSH_ASKPASS_REQUIRE': 'force'}
        try:
            self._start_phase('prepare', self.small_files)
        except (OSError, RuntimeError):
            if hasattr(self, 'child'):
                _stop(self.child, grace=30)
                self.child.stdin.close()
            self.output.close()
            self.askpass.unlink(missing_ok=True)
            self.password = b''
            raise GuestAccessError('Could not start the guest SSH installer') from None

    def _start_phase(self, phase, files, staging_directory=None):
        self.phase = phase
        self.output.seek(0, os.SEEK_END)
        self.phase_offset = self.output.tell()
        marker = 'BIG_WALLET_PAYLOAD_' + uuid.uuid4().hex
        command = self.command + [installer_command(self.user, marker, staging_directory, self.vm_id)]
        self.child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=self.output, stderr=subprocess.STDOUT,
                                      env=self.environment, start_new_session=True)
        self.producer = _PayloadProducer(self.child.stdin, self.password, marker, files)

    def _finish(self, result):
        self.result = result
        try:
            if self.producer:
                self.producer.cancel()
                self.producer.join()
            if self.log_path:
                if self.log_path.is_symlink() or self.log_path.parent.resolve() != self.log_path.parent.absolute():
                    raise GuestAccessError('The guest installer log must not traverse symlinks')
                self.output.seek(0, os.SEEK_END)
                offset = max(0, self.output.tell() - 4 * 1024 * 1024)
                self.output.seek(offset)
                if offset:
                    self.output.readline()
                contents = self.output.read().replace(self.password, b'[REDACTED]')
                descriptor = os.open(self.log_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
                with os.fdopen(descriptor, 'wb') as file:
                    file.write(contents)
        finally:
            self.password = b''
            self.output.close()
            self.askpass.unlink(missing_ok=True)
        return self.result

    def poll(self):
        if self.result is not None:
            return self.result
        code = self.child.poll()
        if self.producer.done.is_set() and self.producer.error:
            _stop(self.child, grace=30)
            return self._finish({'status': 'failed', 'reason': self.producer.error, 'returnCode': self.child.poll()})
        if code is None:
            return None
        if code != 0:
            return self._finish({'status': 'failed', 'reason': 'guest_install_failed', 'returnCode': code})
        if not self.producer.done.is_set():
            return None
        if self.phase == 'prepare':
            self.output.seek(self.phase_offset)
            try:
                response = _prepare_response(self.output.read(4 * 1024 * 1024), self.large_files)
            except GuestAccessError:
                return self._finish({'status': 'failed', 'reason': 'guest_prepare_response_invalid'})
            if response.get('requiresRestart', False):
                return self._finish({'status': 'restart-required'})
            files = {**self.small_files, **{name: self.large_files[name] for name in response['requiredInputs']}}
            try:
                self._start_phase('install', files, response['stagingDirectory'])
            except (OSError, RuntimeError):
                _stop(self.child, grace=30)
                if not self.child.stdin.closed:
                    self.child.stdin.close()
                return self._finish({'status': 'failed', 'reason': 'guest_install_launch_failed'})
            return None
        return self._finish({'status': 'passed'})

    def cancel(self, grace=30):
        if self.result is None:
            if self.producer:
                self.producer.cancel()
            _stop(self.child, grace=grace)
            self._finish({'status': 'failed', 'reason': 'guest_install_cancelled'})


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--askpass':
        try:
            sys.stdout.buffer.write(read_private_password(sys.argv[2]) + b'\n')
        except (GuestAccessError, OSError):
            sys.exit(1)
    else:
        sys.exit(2)
