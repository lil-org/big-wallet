import ctypes
import importlib.util
import os
from pathlib import Path
import re
import secrets
import signal
import stat
import subprocess
import time


READY_SECONDS = 600
INSTALL_NOTICE_SECONDS = 4 * 3600
POLL_SECONDS = 5
STABLE_SECONDS = 5
MAX_BOOTS = 8


def transport_module():
    specification = importlib.util.spec_from_file_location('vm_macos_transport', Path(__file__).with_name('macos_transport.py'))
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


class _ProcessInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in (
        'flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid', 'rgid', 'svuid', 'svgid', 'reserved')]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in ('nfiles', 'pgid', 'pjobc', 'tdev', 'tpgid')]
    _fields_ += [('nice', ctypes.c_int32), ('seconds', ctypes.c_uint64), ('microseconds', ctypes.c_uint64)]


def process_identity(pid, expected_start=None):
    if type(pid) is not int or pid <= 1:
        return None
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    library.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    library.proc_pidinfo.restype = ctypes.c_int
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    info = _ProcessInfo()
    count = library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
    if count == 0:
        return None
    if count != ctypes.sizeof(info) or info.pid != pid:
        raise RuntimeError('Could not verify the owned VM host process')
    identity = {'pid': pid, 'start': [info.seconds, info.microseconds]}
    if expected_start is not None and identity['start'] != expected_start:
        return identity
    if info.uid != os.getuid():
        raise RuntimeError('Could not verify the owned VM host process')
    executable = ctypes.create_string_buffer(4096)
    if library.proc_pidpath(pid, executable, len(executable)) <= 0:
        raise RuntimeError('Could not verify the owned VM host executable')
    return {**identity, 'executable': os.fsdecode(executable.value)}


def _owned_directory(host, path):
    path = Path(path)
    metadata = path.lstat()
    if (path.resolve() != path or not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() or
            metadata.st_mode & 0o077):
        raise host.RunnerError('macOS upgrade state must be a private, owned directory')
    return [metadata.st_dev, metadata.st_ino]


def _vm_identity(host, vm):
    host.validate_vm(vm)
    metadata = vm.lstat()
    if vm.resolve() != vm or metadata.st_uid != os.getuid():
        raise host.RunnerError('The macOS upgrade VM ownership changed')
    return [metadata.st_dev, metadata.st_ino]


def _access_context(host, state, vm, record, directory, journal):
    access_module = host.guest_access_module()
    scope, password = host.guest_setup_password(access_module, state, record,
        {'consoleUser': record['consoleUser']}, directory, None)
    access = journal.get('access')
    if access is None:
        host.ensure_disk_idle(vm)
        if 'upgradeNonce' not in journal:
            journal['upgradeNonce'] = secrets.token_hex(32)
            _write_journal(host, directory, journal)
        access_module.bind_upgrade_candidate(vm, journal['upgradeID'], journal['upgradeNonce'],
                                             record['vmId'], record['consoleUser'])
        selected = access_module.prepare_guest_access(vm, scope, record['vmId'], record['consoleUser'])
        if not selected.get('knownHosts'):
            raise host.RunnerError('The upgrade candidate has no pinned SSH identity; run ordinary setup first')
        access = {'macAddress': selected['macAddress'], 'knownHosts': str(selected['knownHosts']),
                  'knownHostsSHA256': host.hash_regular_file(selected['knownHosts']),
                  'passwordFile': str(password), 'workDirectory': str(scope)}
        journal['access'] = access
    else:
        if (access.get('passwordFile') != str(password) or access.get('workDirectory') != str(scope) or
                access.get('macAddress') != access_module.candidate_mac(vm)):
            raise host.RunnerError('The retained upgrade access scope no longer matches the candidate')
        pin = Path(access.get('knownHosts', ''))
        if (pin.parent != scope or not re.fullmatch(r'known-hosts-[A-Za-z0-9_-]+', pin.name) or
                host.hash_regular_file(pin) != access.get('knownHostsSHA256')):
            raise host.RunnerError('The retained upgrade SSH pin changed; preserving the candidate')
    if not re.fullmatch(r'[a-f0-9]{64}', str(journal.get('upgradeNonce', ''))):
        raise host.RunnerError('The retained upgrade is missing its offline candidate binding')
    return access_module, {**access, 'user': record['consoleUser'], 'vmId': record['vmId'],
                           'upgradeNonce': journal['upgradeNonce']}


def _write_journal(host, directory, journal):
    host.atomic_json(directory / 'install.json', journal)
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _native_status(host, journal):
    native = journal.get('native')
    if not native:
        return None
    path = Path(native['statusPath'])
    if not path.exists():
        return None
    status_value = host.read_json(path)
    if (not isinstance(status_value, dict) or status_value.get('vmPath') != journal['vm'] or
            status_value.get('hostPID') != native['process']['pid'] or
            native.get('sessionId') is not None and status_value.get('sessionId') != native['sessionId']):
        raise host.RunnerError('The macOS upgrade VM status does not match its recorded process')
    session_id = status_value.get('sessionId')
    if not isinstance(session_id, str) or not re.fullmatch(r'[A-Fa-f0-9-]{36}', session_id):
        raise host.RunnerError('The macOS upgrade VM has an invalid session identity')
    native['sessionId'] = session_id
    return status_value


def _executable_vnode(host, path, tools, expected_hash):
    path, tools = Path(path), Path(tools)
    if (not path.is_absolute() or path.resolve() != path or not path.is_relative_to(tools) or
            path.name != 'VMHost' or not isinstance(expected_hash, str) or
            re.fullmatch(r'[a-f0-9]{64}', expected_hash) is None):
        raise host.RunnerError('The retained upgrade executable changed or escaped its owned tool directory')
    for directory in (path.parent, *path.parent.parents):
        if not directory.is_relative_to(tools):
            break
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise host.RunnerError('The retained upgrade executable directory changed ownership')
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_mode & 0o022:
        raise host.RunnerError('The retained upgrade executable changed ownership or file type')
    digest = host.hash_regular_file(path)
    after = path.lstat()
    identity = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
    if digest != expected_hash or identity(before) != identity(after):
        raise host.RunnerError('The retained upgrade executable changed')
    return before.st_dev, before.st_ino


def _validate_native(host, state, directory, journal):
    boots = journal.get('boots', 0)
    if type(boots) is not int or not 0 <= boots <= MAX_BOOTS:
        raise host.RunnerError('The retained upgrade boot identity is invalid')
    native = journal.get('native')
    if native is None:
        return
    if boots == 0 or not isinstance(native, dict):
        raise host.RunnerError('The retained upgrade boot identity is invalid')
    boot = directory / f'boot-{boots}'
    _owned_directory(host, boot)
    process = native.get('process')
    if (native.get('statusPath') != str(boot / 'vm-status.json') or
            native.get('stopPath') != str(boot / 'vm-stop') or not isinstance(process, dict) or
            type(process.get('pid')) is not int or process['pid'] <= 1 or
            not isinstance(process.get('start'), list) or len(process['start']) != 2 or
            any(type(value) is not int or value < 0 for value in process['start']) or
            not isinstance(process.get('executable'), str)):
        raise host.RunnerError('The retained upgrade process paths or identity are invalid')
    for key in ('statusPath', 'stopPath'):
        path = Path(native[key])
        try:
            info = path.lstat()
        except FileNotFoundError:
            continue
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            raise host.RunnerError('The retained upgrade control path is not an owned regular file')
    _executable_vnode(host, process['executable'], state / 'tools', native.get('executableSHA256'))


def _retryable_startup_failure(status, journal):
    return (status and status.get('state') == 'failed' and status.get('running') is False and
            status.get('guestStarted') is False and not journal.get('startAttempted') and
            not journal.get('storageGrowAttempted') and not journal.get('manualHandoff'))


def _native_alive(host, journal, child):
    native = journal.get('native')
    if native is None:
        return False
    if child is not None and child.poll() is not None:
        return False
    identity = process_identity(native['process']['pid'], native['process']['start'])
    if identity is None:
        return False
    if any(identity.get(key) != native['process'].get(key) for key in ('pid', 'start')):
        status = _native_status(host, journal)
        if (child is None and status and status.get('running') is False and
                (status.get('state') == 'stopped' or _retryable_startup_failure(status, journal))):
            host.ensure_disk_idle(Path(journal['vm']))
            return False
        raise host.RunnerError('The recorded VM process identity changed; no process was stopped')
    tools = Path(journal['vm']).parent / 'tools'
    expected = _executable_vnode(host, native['process']['executable'], tools, native.get('executableSHA256'))
    actual = _executable_vnode(host, identity['executable'], tools, native.get('executableSHA256'))
    if actual != expected:
        raise host.RunnerError('The recorded VM executable vnode changed; no process was stopped')
    return True


def _launch(host, args, state, directory, journal, binaries):
    vm = Path(journal['vm'])
    host.ensure_disk_idle(vm)
    boots = journal.get('boots', 0)
    if boots >= MAX_BOOTS:
        raise host.RunnerError('The macOS update exceeded its automatic reboot limit; preserve and inspect the candidate')
    boot = directory / f'boot-{boots + 1}'
    if boot.exists() or boot.is_symlink():
        raise host.RunnerError('The next upgrade boot directory already contains evidence')
    interactive = bool(journal.get('interactiveProtection'))
    binary = host.setup_viewer_binary(state, binaries)
    executable_hash = host.hash_regular_file(binary)
    vnode = _executable_vnode(host, binary, state / 'tools', executable_hash)
    journal.update({'boots': boots + 1, 'native': None, 'phase': 'launching'})
    _write_journal(host, directory, journal)
    boot.mkdir(mode=0o700)
    command = [str(binary), '--vm', str(vm), '--status', str(boot / 'vm-status.json'),
               '--stop-file', str(boot / 'vm-stop'), '--owner-pid', str(os.getpid()),
               '--upgrade-control', str(directory / 'control.json')]
    if interactive:
        command.append('--upgrade-window')
    with open(boot / 'vm.log', 'xb', buffering=0) as log:
        child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=log, stderr=log, start_new_session=True)
    with child.stdin:
        identity = process_identity(child.pid)
        if identity is None:
            raise host.RunnerError('The upgrade VM host exited before publishing its process identity')
        if _executable_vnode(host, identity['executable'], state / 'tools', executable_hash) != vnode:
            raise host.RunnerError('The upgrade VM launched an unexpected executable')
        journal['native'] = {'process': identity, 'statusPath': str(boot / 'vm-status.json'),
                             'stopPath': str(boot / 'vm-stop'), 'interactive': interactive,
                             'executableSHA256': executable_hash}
        _write_journal(host, directory, journal)
        child.stdin.write(b'G')
    return child


def _set_protection(host, directory, journal, protected):
    host.atomic_json(directory / 'control.json', {'version': 1, 'vmPath': journal['vm'],
        'upgradeID': journal['upgradeID'], 'protectInstallation': protected,
        'showWindow': bool(journal.get('interactiveProtection'))})
    journal['protected'] = protected


def _shutdown(host, directory, journal, child):
    _validate_native(host, directory.parent, directory, journal)
    _native_status(host, journal)
    alive = _native_alive(host, journal, child)
    _set_protection(host, directory, journal, False)
    if not alive:
        return
    stop = Path(journal['native']['stopPath'])
    if not stop.exists():
        stop.touch(mode=0o600, exist_ok=False)
    deadline = time.monotonic() + 45
    while _native_alive(host, journal, child):
        if time.monotonic() >= deadline:
            raise host.RunnerError('The upgraded VM did not stop cleanly; its process was preserved')
        time.sleep(1)
    if child is not None:
        child.wait(timeout=5)
    host.ensure_disk_idle(Path(journal['vm']))


def _observation(value, target):
    if not isinstance(value, dict) or value.get('status') not in ('ready', 'installing', 'complete', 'blocked', 'failed'):
        raise ValueError('The guest returned an invalid macOS upgrade observation')
    actual = value.get('actual')
    if (not isinstance(actual, dict) or set(actual) != {'version', 'buildVersion'} or
            not all(isinstance(item, str) and 0 < len(item) <= 64 for item in actual.values()) or
            not isinstance(value.get('bootIdentity'), str) or not value['bootIdentity'] or
            type(value.get('safeToStop')) is not bool):
        raise ValueError('The guest did not attest its macOS version, boot, and installer state')
    if value['status'] == 'complete' and (actual != target or value['safeToStop'] is not True):
        raise ValueError('The guest claimed completion without a stable matching macOS installation')
    return value


def install(host, args, state, record, upgrade_id, target, save_progress, stop_requested):
    state = Path(state)
    directory = host.private_directory(state / 'macos-install')
    _owned_directory(host, directory)
    vm = state / 'baseline.vbvm'
    expected = {'version': 1, 'upgradeID': upgrade_id, 'vmId': record['vmId'], 'vm': str(vm),
                'target': target, 'vmFileID': _vm_identity(host, vm)}
    growth = getattr(args, 'system_disk_growth', None)
    if growth is not None:
        if not isinstance(growth, dict):
            raise host.RunnerError('The system-disk growth receipt must be an object')
        expected['systemDiskGrowth'] = growth
    journal_path = directory / 'install.json'
    journal = host.read_json(journal_path) if journal_path.exists() or journal_path.is_symlink() else dict(expected)
    if not isinstance(journal, dict) or any(journal.get(key) != value for key, value in expected.items()):
        raise host.RunnerError('The retained macOS installation belongs to a different VM or target')
    for intent, key in (('startAttempted', 'preBootIdentity'), ('manualHandoff', 'manualPreBootIdentity')):
        if journal.get(intent) and (not isinstance(journal.get(key), str) or not journal[key]):
            raise host.RunnerError('The retained macOS installation is missing its admission boot identity')
    child = None
    last_saved = None
    stopped_by_signal = False
    originals = {}

    def interrupted(signum, frame):
        nonlocal stopped_by_signal
        stopped_by_signal = True

    def cancelled():
        return stopped_by_signal or stop_requested()

    def save(phase, **extra):
        nonlocal last_saved
        journal.update({'phase': phase, **extra})
        status_value = _native_status(host, journal)
        progress = {key: journal[key] for key in ('phase', 'upgradeID', 'target', 'boots', 'protected',
                    'actual', 'bootIdentity', 'reason', 'cancellationDeferred', 'attentionRequired',
                    'storage', 'storageVerified', 'storageGrowAttempted') if key in journal}
        if status_value is not None:
            progress['vmStatus'] = status_value
        if journal.get('native'):
            progress['process'] = journal['native']['process']
        _write_journal(host, directory, journal)
        if progress != last_saved:
            save_progress(progress)
            last_saved = progress

    def finish(status, reason=None, observation=None):
        if observation is not None:
            journal.update({'actual': observation['actual'], 'bootIdentity': observation['bootIdentity'],
                            'observation': observation})
        if reason:
            journal['reason'] = reason
        elif status == 'complete':
            journal.pop('reason', None)
        _shutdown(host, directory, journal, child)
        save(status)
        return {'status': status, **{key: journal[key] for key in ('actual', 'bootIdentity', 'reason', 'storage', 'storageVerified') if key in journal},
                'boots': journal.get('boots', 0), 'evidence': str(journal_path)}

    def wants_window():
        return getattr(args, 'interactive', False) or getattr(args, 'interactive_requested', lambda: False)()

    def await_guest_shutdown(reason, outcome='resume'):
        journal['awaitingGuestShutdown'] = outcome
        reason += ('. Shut down from the guest window to finish cancellation.' if outcome == 'cancelled'
                   else '. Shut down from the guest window, then resume the upgrade.')
        save('needs-attention', reason=reason)
        return {'status': 'blocked', 'reason': reason, 'vmPreservedRunning': True,
                **({'storage': journal['storage']} if 'storage' in journal else {}), 'evidence': str(journal_path)}

    def installation_committed():
        return bool(journal.get('startAttempted') or journal.get('manualHandoff') or
                    journal.get('storageGrowAttempted') and not journal.get('storageVerified'))

    def running_protected(status):
        return (status and status.get('state') == 'running' and status.get('running') is True and
                status.get('installationProtected') is True)

    def guest_ready_for_mutation():
        if not journal.get('protected'):
            _set_protection(host, directory, journal, True)
        if running_protected(_native_status(host, journal)):
            return True
        save('waiting-for-running-vm')
        time.sleep(POLL_SECONDS)
        return running_protected(_native_status(host, journal))

    def check_native_stop(status, before_admission):
        nonlocal stopped_by_signal
        if not status or journal.get('boots') in (retained_stopped_boot, retry_startup_boot):
            return
        reason = status.get('stopReason')
        if ((reason in ('upgrade-window-closed', 'upgrade-quit-requested', 'signal', 'stop-file') and
                not (journal.get('storageRebootRequested') and reason == 'stop-file')) or
                (journal.get('interactiveProtection') and before_admission and
                 status.get('state') == 'stopped' and status.get('running') is False)):
            stopped_by_signal = True

    def check_admission(status, intent=None):
        check_native_stop(status, True)
        if cancelled():
            outcome, reason = 'cancelled', 'The macOS upgrade was cancelled before installation'
        elif time.monotonic() >= deadline:
            outcome, reason = 'blocked', 'The guest did not complete macOS upgrade prerequisites before the deadline'
        elif intent and not running_protected(status):
            outcome, reason = 'blocked', 'The guest stopped being ready for installation before admission'
        else:
            return None
        if intent:
            journal[intent] = False
        if journal.get('interactiveProtection') and journal.get('native'):
            if _native_alive(host, journal, child):
                return await_guest_shutdown(reason, 'cancelled' if outcome == 'cancelled' else 'resume')
            if not status or status.get('state') != 'stopped' or status.get('running') is not False:
                raise host.RunnerError('Could not confirm that the interactive guest stopped; preserve its evidence')
            host.ensure_disk_idle(vm)
            journal.pop('interactiveProtection')
        return finish(outcome, reason)

    cleanup_allowed = False
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        originals[signum] = signal.signal(signum, interrupted)
    try:
        _validate_native(host, state, directory, journal)
        retained_status = _native_status(host, journal)
        retained_stopped_boot = journal.get('boots') if retained_status and retained_status.get('state') == 'stopped' else None
        retry_startup_boot = None
        if _retryable_startup_failure(retained_status, journal):
            retry_startup_boot = journal['boots']
        transport = transport_module()
        control_path = directory / 'control.json'
        existing_control = control_path.exists() or control_path.is_symlink()
        if existing_control:
            control = host.read_json(control_path)
            if (not isinstance(control, dict) or control.get('version') != 1 or control.get('vmPath') != str(vm) or
                    control.get('upgradeID') != upgrade_id or type(control.get('protectInstallation')) is not bool):
                raise host.RunnerError('The installation protection record changed')
            journal['protected'] = control['protectInstallation']
            if control.get('showWindow'):
                journal['interactiveProtection'] = True
        if journal.get('awaitingGuestShutdown'):
            alive = _native_alive(host, journal, None)
            if alive or retained_stopped_boot is None or retained_status.get('running') is not False:
                return {'status': 'blocked', 'reason': journal['reason'], 'vmPreservedRunning': alive,
                        **({'storage': journal['storage']} if 'storage' in journal else {}), 'evidence': str(journal_path)}
            host.ensure_disk_idle(vm)
            handoff = journal.pop('awaitingGuestShutdown')
            journal.pop('interactiveProtection', None)
            _set_protection(host, directory, journal, False)
            if handoff == 'cancelled':
                return finish('cancelled', 'Cancellation completed after guest shutdown')
        if (journal.get('native') and not journal.get('protected') and not journal.get('interactiveProtection') and not installation_committed() and
                _native_alive(host, journal, None)):
            _shutdown(host, directory, journal, None)
            retained_status = _native_status(host, journal)
            if not retained_status or retained_status.get('state') != 'stopped' or retained_status.get('running') is not False:
                raise host.RunnerError('Could not confirm shutdown of the previous unprotected VM host')
            retained_stopped_boot = journal['boots']
        access_module, context = _access_context(host, state, vm, record, directory, journal)
        if wants_window():
            journal['interactiveProtection'] = True
        protected = installation_committed() or bool(journal.get('interactiveProtection'))
        if protected or not existing_control:
            _set_protection(host, directory, journal, protected)
        cleanup_allowed = True
        save('connecting')
        binaries = host.build_tools(state, args.xcode)
        start = time.monotonic()
        deadline = start + (getattr(args, 'timeout', None) or INSTALL_NOTICE_SECONDS)
        ready_deadline = start + min(READY_SECONDS, getattr(args, 'timeout', None) or READY_SECONDS)
        stable = None
        while True:
            if not journal.get('interactiveProtection') and wants_window():
                journal['interactiveProtection'] = True
                _set_protection(host, directory, journal, True)
                save('connecting')
            committed = installation_committed()
            alive = _native_alive(host, journal, child)
            native_status = _native_status(host, journal)
            if committed:
                check_native_stop(native_status, False)
            else:
                interruption = check_admission(native_status)
                if interruption:
                    return interruption
            if not alive:
                if native_status and native_status.get('state') not in ('stopped', 'failed'):
                    raise host.RunnerError('The VM host disappeared without a terminal status; preserve its evidence')
                if native_status and native_status.get('state') == 'failed' and journal.get('boots') != retry_startup_boot:
                    return finish('blocked', 'The upgrade VM stopped with an error; inspect its VM log before resuming')
                if committed and not journal.get('protected'):
                    _set_protection(host, directory, journal, True)
                child = _launch(host, args, state, directory, journal, binaries)
                journal.pop('storageRebootRequested', None)
                ready_deadline = time.monotonic() + READY_SECONDS
                save('booting')
            if cancelled() and committed:
                journal['cancellationDeferred'] = True
            if committed and time.monotonic() >= deadline:
                journal['attentionRequired'] = 'Installation exceeded its observation deadline; waiting for a safe guest state'
            address = access_module.find_guest_address(journal['access']['macAddress'])
            if not address:
                if not committed and not journal.get('interactiveProtection') and time.monotonic() >= ready_deadline:
                    return finish('blocked', 'The upgrade guest did not obtain a network address')
                save('installing' if committed else 'connecting')
                time.sleep(POLL_SECONDS)
                continue
            context['address'] = address
            if growth is not None and not journal.get('storageVerified'):
                if not guest_ready_for_mutation():
                    continue
                if not journal.get('storageGrowAttempted'):
                    journal['storageGrowAttempted'] = True
                    save('growing-system-volume')
                    interruption = check_admission(_native_status(host, journal), 'storageGrowAttempted')
                    if interruption:
                        return interruption
                try:
                    observation = _observation(transport.resize(host, context, target, upgrade_id, growth), target)
                except transport.TransportUnavailable:
                    save('growing-system-volume')
                    time.sleep(POLL_SECONDS)
                    continue
                storage = observation.get('storage')
                if not isinstance(storage, dict):
                    raise host.RunnerError('The guest did not return bound system-volume growth evidence')
                journal.update({'storage': storage, 'actual': observation['actual'], 'bootIdentity': observation['bootIdentity']})
                low_space = (observation['status'] == 'blocked' and
                             observation.get('reason') == 'guest_storage_insufficient_free_space_after_growth')
                if (observation['status'] == 'ready' or low_space) and storage.get('status') == 'grown' and observation['safeToStop']:
                    before_boot = journal.get('storageExpandedBoot')
                    if before_boot is None:
                        journal['storageExpandedBoot'] = observation['bootIdentity']
                        before_boot = observation['bootIdentity']
                    if observation['bootIdentity'] == before_boot:
                        journal['storageRebootRequested'] = True
                        if journal.get('interactiveProtection'):
                            return await_guest_shutdown('Filesystem growth requires a cold boot for verification')
                        save('rebooting-system-volume')
                        _shutdown(host, directory, journal, child)
                        save('rebooting-system-volume')
                    else:
                        if low_space:
                            journal['storageGrowAttempted'] = False
                            reason = observation['reason']
                            if journal.get('interactiveProtection'):
                                return await_guest_shutdown(reason)
                            return finish('blocked', reason, observation)
                        journal['storageVerified'] = True
                        _set_protection(host, directory, journal, bool(journal.get('startAttempted') or journal.get('interactiveProtection')))
                        save('system-volume-verified')
                        if cancelled():
                            if journal.get('interactiveProtection'):
                                return await_guest_shutdown('Cancellation requested after the resized filesystem reached a verified cold boot', 'cancelled')
                            return finish('cancelled', 'Cancellation applied after the resized filesystem reached a verified cold boot', observation)
                    continue
                if observation['status'] == 'blocked' and storage.get('status') == 'preflight-rejected' and observation['safeToStop']:
                    journal['storageGrowAttempted'] = False
                    reason = observation['reason']
                    if not journal.get('interactiveProtection'):
                        return finish('blocked', reason, observation)
                    return await_guest_shutdown(reason + '. Resize did not start')
                if observation['status'] != 'installing' or storage.get('status') != 'growing':
                    save('needs-attention', reason=observation.get('reason', 'The system-volume resize state is uncertain'))
                    return {'status': 'blocked', 'reason': journal['reason'], 'vmPreservedRunning': True,
                            'storage': storage, 'evidence': str(journal_path)}
                save('growing-system-volume')
                time.sleep(POLL_SECONDS)
                continue
            try:
                action = transport.observe if journal.get('startAttempted') and not journal.get('manualHandoff') else transport.probe
                observation = _observation(action(host, context, target, upgrade_id), target)
            except transport.TransportUnavailable:
                if not committed and not journal.get('interactiveProtection') and time.monotonic() >= ready_deadline:
                    return finish('blocked', 'The upgrade guest did not become reachable over pinned SSH')
                stable = None
                save('installing' if committed else 'connecting')
                time.sleep(POLL_SECONDS)
                continue
            journal.update({'observation': observation, 'actual': observation['actual'],
                            'bootIdentity': observation['bootIdentity']})
            if not committed:
                interruption = check_admission(_native_status(host, journal))
                if interruption:
                    return interruption
            if observation['status'] == 'complete':
                if observation['bootIdentity'] in (journal.get('preBootIdentity'), journal.get('manualPreBootIdentity')):
                    stable = None
                    save('waiting-for-restart')
                    time.sleep(POLL_SECONDS)
                    continue
                key = (observation['bootIdentity'], tuple(sorted(observation['actual'].items())))
                if stable is None or stable[0] != key:
                    stable = (key, time.monotonic())
                elif time.monotonic() - stable[1] >= STABLE_SECONDS:
                    return finish('cancelled' if cancelled() else 'complete',
                                  'Cancellation applied after the guest reached a stable boot' if cancelled() else None,
                                  observation)
                save('verifying-boot')
            elif observation['status'] in ('blocked', 'failed') and observation['safeToStop']:
                if getattr(args, 'interactive', False) or journal.get('interactiveProtection'):
                    journal['interactiveProtection'] = True
                    journal['manualHandoff'] = True
                    journal.setdefault('manualPreBootIdentity', observation['bootIdentity'])
                    _set_protection(host, directory, journal, True)
                    save('waiting-for-consent', reason=observation.get('reason', 'Guest intervention is required'))
                else:
                    return finish('cancelled' if cancelled() else observation['status'], observation.get('reason'), observation)
            elif observation['status'] == 'ready' and not journal.get('startAttempted') and not journal.get('manualHandoff'):
                if observation['safeToStop'] is not True:
                    raise host.RunnerError('The guest was ready without a safe installation admission state')
                if not guest_ready_for_mutation():
                    continue
                journal['startAttempted'] = True
                journal['before'] = observation['actual']
                journal['preBootIdentity'] = observation['bootIdentity']
                save('starting-installation')
                interruption = check_admission(_native_status(host, journal), 'startAttempted')
                if interruption:
                    return interruption
                try:
                    observation = _observation(transport.start(host, context, target, upgrade_id), target)
                    journal['observation'] = observation
                    if observation['status'] in ('blocked', 'failed') and observation['safeToStop']:
                        if observation.get('receipt') is None:
                            journal['startAttempted'] = False
                            save('admission-rejected')
                        if journal.get('interactiveProtection'):
                            journal['manualHandoff'] = True
                            journal.setdefault('manualPreBootIdentity', observation['bootIdentity'])
                        else:
                            return finish(observation['status'], observation.get('reason'), observation)
                except transport.TransportUnavailable:
                    pass
                save('installing')
            elif observation['status'] == 'blocked' and not observation['safeToStop']:
                if journal.get('interactiveProtection') and observation.get('reason') == 'update_receipt_missing':
                    journal['manualHandoff'] = True
                    journal.setdefault('manualPreBootIdentity', observation['bootIdentity'])
                    save('waiting-for-consent', reason='Waiting for the manually authorized macOS update')
                    time.sleep(POLL_SECONDS)
                    continue
                save('needs-attention', reason=observation.get('reason', 'The installer state could not be established'))
                return {'status': 'blocked', 'reason': journal['reason'], 'vmPreservedRunning': True,
                        'actual': observation['actual'], 'evidence': str(journal_path)}
            else:
                stable = None
                save('installing')
            time.sleep(POLL_SECONDS)
    except (host.RunnerError, OSError, ValueError, RuntimeError) as error:
        if not cleanup_allowed:
            raise
        reason = str(error)
        if journal.get('protected'):
            journal.update({'phase': 'needs-attention', 'reason': reason})
            _write_journal(host, directory, journal)
            save_progress({'phase': 'needs-attention', 'reason': reason, 'protected': True,
                           'upgradeID': upgrade_id, 'target': target})
            return {'status': 'blocked', 'reason': reason, 'vmPreservedRunning': bool(journal.get('native')),
                    'evidence': str(journal_path)}
        try:
            return finish('blocked', reason)
        except (host.RunnerError, OSError, ValueError, RuntimeError) as shutdown_error:
            journal.update({'phase': 'needs-attention', 'reason': reason, 'shutdownError': str(shutdown_error)})
            _write_journal(host, directory, journal)
            save_progress({'phase': 'needs-attention', 'reason': reason, 'shutdownError': str(shutdown_error),
                           'upgradeID': upgrade_id, 'target': target})
            return {'status': 'blocked', 'reason': reason, 'vmPreservedRunning': bool(journal.get('native')),
                    'evidence': str(journal_path)}
    finally:
        for signum, handler in originals.items():
            signal.signal(signum, handler)
