import argparse
import contextlib
import copy
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import uuid


TERMINAL = ('passed', 'failed', 'blocked', 'cancelled')
ID_PATTERN = r'macos-upgrade-\d{8}T\d{6}Z-[0-9a-f]{8}'


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def module(name):
    spec = importlib.util.spec_from_file_location('big_wallet_' + name, Path(__file__).with_name(name + '.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def canonical(host, path, *, directory=False):
    path = Path(path)
    if not path.is_absolute() or path.resolve() != path or path.is_symlink():
        raise host.RunnerError('macOS upgrade paths must be canonical and must not traverse symlinks')
    info = path.lstat()
    if info.st_uid != os.getuid() or not (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)):
        raise host.RunnerError('macOS upgrade input has an unexpected owner or file type')
    return path


def transaction_path(host, state, identifier):
    if not isinstance(identifier, str) or re.fullmatch(ID_PATTERN, identifier) is None:
        raise host.RunnerError('Select a macOS upgrade identifier printed by upgrade-macos')
    return Path(state) / 'upgrades' / identifier


def process_start(pid, expected_start=None):
    if type(pid) is not int or pid <= 1:
        return None
    process = module('macos_vm').process_identity(pid, expected_start)
    return process['start'] if process else None


@contextlib.contextmanager
def supervisor_lock(host, state):
    deadline = time.monotonic() + 15
    while True:
        lock = host.execution_lock(state)
        try:
            lock.__enter__()
            break
        except host.RunnerError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.1)
    try:
        yield
    finally:
        lock.__exit__(None, None, None)


def supervisor_alive(record):
    supervisor = record.get('supervisor', {})
    return bool(supervisor.get('start') and process_start(supervisor.get('pid'), supervisor['start']) == supervisor['start'])


def vm_identity(host, vm):
    canonical(host, vm, directory=True)
    host.validate_vm(vm)
    names = ('Disk.img', 'BuildData.img', 'AuxiliaryStorage', 'HardwareModel', 'MachineIdentifier', '.vbdata/Config.plist')
    files = {}
    for name in names:
        path = canonical(host, vm / name)
        info = path.stat()
        files[name] = [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns]
    info = vm.stat()
    return {'fileID': [info.st_dev, info.st_ino], 'files': files}


def identity(host, vm, record_path):
    return {**vm_identity(host, vm), 'recordSHA256': host.hash_regular_file(canonical(host, record_path))}


def released(result):
    if result.get('status') == 'passed' and result.get('phase') == 'complete':
        return True
    installation = result.get('installation')
    return (result.get('status') == 'cancelled' and result.get('phase') == 'abandoned' and
            isinstance(installation, dict) and installation.get('abandoned') is True and
            installation.get('vmPreservedRunning') is False)


def cancelled_validation(result):
    installation = result.get('installation')
    return (result.get('status') == 'cancelled' and
            result.get('phase') in ('setup', 'safari-preparation', 'safari-roundtrips', 'full-suite', 'default-verification') and
            result.get('installationVerified') is True and isinstance(installation, dict) and
            installation.get('status') == 'complete' and installation.get('actual') == result['target'] and
            not installation.get('vmPreservedRunning') and not installation.get('protected'))


def terminal_installation(result):
    installation = result.get('installation')
    return (result.get('status') in ('blocked', 'cancelled', 'failed') and result.get('phase') == 'installation' and
            isinstance(installation, dict) and installation.get('status') in ('blocked', 'failed', 'cancelled') and
            not result.get('installationVerified'))


def verify_upgrade_stopped(host, state, directory, result):
    staged = canonical(host, result['stagingDirectory'], directory=True)
    cancelled = False
    if any(os.path.lexists(scope / 'active.json') for scope in (staged, state)):
        raise host.RunnerError('A validation operation still owns a VM; resume the upgrade to reconcile it')
    if result['phase'] == 'default-verification':
        verify_promoted_baseline(host, state, result)
        for clone in (state / 'runs').glob('*.vbvm'):
            host.ensure_disk_idle(canonical(host, clone, directory=True))
    elif result.get('promotion') or any(os.path.lexists(state / name) for name in ('candidate.json', 'candidate.vbvm')):
        raise host.RunnerError('The parent candidate must be reconciled before releasing the cancelled upgrade')
    elif identity(host, state / 'baseline.vbvm', state / 'baseline.json') != result['sourceBaseline']:
        raise host.RunnerError('The active baseline changed before the cancelled upgrade was released')
    host.ensure_disk_idle(state / 'baseline.vbvm')
    vm = canonical(host, staged / 'baseline.vbvm', directory=True)
    if result['phase'] == 'installation':
        runtime, journal, _ = installation_state(host, directory, result)
        cancelled = journal.get('awaitingGuestShutdown') == 'cancelled'
        if cancelled:
            if (journal.get('phase') != 'needs-attention' or journal.get('protected') is not True or
                    journal.get('startAttempted') or journal.get('manualHandoff') or
                    journal.get('storageGrowAttempted') and not journal.get('storageVerified')):
                raise host.RunnerError('The cancellation handoff cannot release a committed installation')
        elif journal.get('protected') is not False or journal.get('phase') not in ('blocked', 'failed', 'cancelled'):
            raise host.RunnerError('The retained installation has not reached a safe stop')
        if journal.get('native'):
            status = runtime._native_status(host, journal)
            if (runtime._native_alive(host, journal, None) or not status or status.get('state') != 'stopped' or
                    status.get('running') is not False):
                raise host.RunnerError('The upgrade VM has not confirmed shutdown')
        elif journal.get('boots', 0) or cancelled:
            raise host.RunnerError('The upgrade has no confirmed VM shutdown evidence')
    else:
        record = host.read_json(canonical(host, staged / 'baseline.json'))
        if (vm_identity(host, vm)['fileID'] != result.get('stagingFileID') or
                record.get('macosUpgradeID') != result['upgradeID'] or record.get('vmId') != result['vmId'] or
                record.get('macos') != result['target'] or record.get('sourceVM') != result['sourceVM']):
            raise host.RunnerError('The staged baseline no longer matches the cancelled validation')
    for vm in (*staged.glob('*.vbvm'), *(staged / 'runs').glob('*.vbvm')):
        host.ensure_disk_idle(canonical(host, vm, directory=True))
    return cancelled


def load_result(host, state, identifier, *, active=False):
    directory = canonical(host, transaction_path(host, state, identifier), directory=True)
    value = host.read_json(canonical(host, directory / 'result.json'))
    if (not isinstance(value, dict) or value.get('version') != 1 or value.get('upgradeID') != identifier or
            (not active and value.get('repository') != str(host.ROOT)) or
            value.get('stateDirectory') != str(state) or
            value.get('stagingDirectory') != str(directory / 'state') or
            value.get('status') not in ('starting', 'running', 'needs-attention', *TERMINAL)):
        raise host.RunnerError('The macOS upgrade record does not match this repository and state directory')
    stable_target(host, value.get('target'))
    return directory, value


def active_result(host, state, *, clear_complete=False):
    path = state / 'macos-upgrade-active.json'
    if not path.exists() and not path.is_symlink():
        return None
    pointer = host.read_json(canonical(host, path))
    if not isinstance(pointer, dict) or set(pointer) != {'version', 'upgradeID'} or pointer['version'] != 1:
        raise host.RunnerError('The active macOS upgrade pointer is invalid')
    directory, result = load_result(host, state, pointer['upgradeID'], active=True)
    if (cancelled_validation(result) or terminal_installation(result)) and not supervisor_alive(result):
        try:
            staged = canonical(host, result['stagingDirectory'], directory=True)
            with host.execution_lock(staged) if clear_complete else contextlib.nullcontext():
                cancelled = verify_upgrade_stopped(host, state, directory, result)
                if clear_complete:
                    if cancelled:
                        reason = 'Interactive cancellation confirmed after guest shutdown'
                        result.update(status='cancelled', reason=reason, finishedAt=now())
                        result['installation'].update(status='cancelled', reason=reason, vmPreservedRunning=False)
                        host.atomic_json(directory / 'result.json', result)
                    path.unlink()
                return None
        except (host.RunnerError, OSError):
            if result.get('repository') != str(host.ROOT):
                raise
    if released(result):
        if clear_complete:
            path.unlink()
        return None
    if result.get('repository') != str(host.ROOT):
        raise host.RunnerError('The macOS upgrade record does not match this repository and state directory')
    return directory, result


def require_idle_upgrade(host, result):
    if supervisor_alive(result):
        raise host.RunnerError('A macOS upgrade supervisor owns this state; use status or stop')
    if result.get('phase') == 'promoting':
        raise host.RunnerError('Resume the interrupted macOS upgrade to complete its verified promotion')
    if cancelled_validation(result):
        raise host.RunnerError('The cancelled validation still owns its resources; resume it to reconcile the operation')
    if terminal_installation(result):
        raise host.RunnerError('Resume the retained installation to confirm its VM has stopped')
    if result.get('installation', {}).get('vmPreservedRunning') or result.get('installation', {}).get('protected'):
        raise host.RunnerError('Resume the protected installation before starting another VM operation')
    staged = Path(result['stagingDirectory'])
    for name in ('baseline.vbvm', 'candidate.vbvm'):
        vm = staged / name
        if vm.exists():
            canonical(host, vm, directory=True)
            host.ensure_disk_idle(vm)


def ensure_no_supervisor(host, state):
    current = active_result(host, state, clear_complete=True)
    if current:
        require_idle_upgrade(host, current[1])


def selected_target(host, args, retained=None):
    version, build = getattr(args, 'version', None), getattr(args, 'build', None)
    if retained is None and (version is None or build is None) or (version is None) != (build is None):
        raise host.RunnerError('A new macOS upgrade requires both --version and --build')
    target = stable_target(host, {'version': version, 'buildVersion': build} if version is not None else retained)
    if retained is not None and target != retained:
        raise host.RunnerError('The requested target differs from the retained upgrade; use its original version/build')
    return target


def stable_target(host, value):
    target = host.macos_identity(value)
    if (not re.fullmatch(r'[1-9][0-9]*\.[0-9]+(?:\.[0-9]+)?', target['version']) or
            not re.fullmatch(r'[0-9]{2}[A-Z][0-9]{1,6}', target['buildVersion'])):
        raise host.RunnerError('Select an exact stable macOS version and build')
    return target


def promotion_record_with_backup(result):
    record = copy.deepcopy(result['promotion']['record'])
    record['promotionPending'].update({'backupFileID': result['sourceBaseline']['fileID'],
                                     'backupRecordSHA256': result['sourceBaseline']['recordSHA256']})
    return record


def verify_promoted_baseline(host, state, result):
    promoted = result.get('promotion', {}).get('record', {})
    record = host.read_json(canonical(host, state / 'baseline.json'))
    vm = state / 'baseline.vbvm'
    if (promoted.get('macosUpgradeID') != result['upgradeID'] or
            vm_identity(host, vm) != result['promotion'].get('vmIdentity') or
            record != host.completed_baseline_record(promotion_record_with_backup(result))):
        raise host.RunnerError('The active baseline no longer matches this promoted macOS upgrade')
    host.ensure_disk_idle(vm)


def check_setup_window(host, result):
    step = result['steps'][-1] if result['steps'] else {}
    if (result['phase'] == 'setup' and step.get('name') == 'setup' and
            step.get('status') == 'running' and step.get('interactive') is False):
        raise host.RunnerError('Setup is already running headlessly. Use stop, then resume this upgrade with --interactive to open a setup window.')


def preview(host, args, state):
    resumed = getattr(args, 'resume', None)
    retained = load_result(host, state, resumed)[1] if resumed else None
    target = selected_target(host, args, retained and retained['target'])
    requested_size = getattr(args, 'system_disk_gib', None)
    if requested_size is not None and (type(requested_size) is not int or not 64 <= requested_size <= 1024):
        raise host.RunnerError('Select a system disk size from 64 through 1024 GiB')
    disk_bytes = requested_size * 1024 ** 3 if requested_size is not None else retained and retained.get('systemDiskBytes')
    if retained and requested_size is not None and disk_bytes != retained.get('systemDiskBytes'):
        raise host.RunnerError('Resume requires the original system disk size; start another isolated upgrade to change it')
    if getattr(args, 'abandon', False) and (not resumed or retained.get('phase') not in ('installation', 'abandoned')):
        raise host.RunnerError('Only a retained installation can be abandoned with --resume ID --abandon')
    if retained and retained['phase'] == 'abandoned' and not getattr(args, 'abandon', False):
        raise host.RunnerError('This upgrade was abandoned; start a new upgrade to install macOS')
    abandoning = getattr(args, 'abandon', False)
    attaching = retained and not abandoning and supervisor_alive(retained)
    if attaching and args.interactive:
        check_setup_window(host, retained)
    if abandoning or attaching and retained.get('phase') == 'installation':
        directory = transaction_path(host, state, resumed)
        if retained['sourceVM'] != str(args.vm):
            raise host.RunnerError('Recovery requires the original source VM')
        installation_owner(host, state, retained)
        if retained['phase'] == 'abandoned':
            detail = stopped_abandonment(host, state, directory, retained)
        else:
            installation_state(host, directory, retained, starting=bool(attaching))
            detail = {'vmPath': str(Path(retained['stagingDirectory']) / 'baseline.vbvm')}
        return {'version': 1, 'status': 'ready', 'target': target, 'systemDiskBytes': disk_bytes,
                'upgradeID': resumed, 'control': 'abandon' if abandoning else 'attach',
                'prerequisites': [{'name': 'retainedInstallation', 'status': 'passed', 'detail': detail}]}
    environment = host.read_json(host.TOOLS / 'environment.json')
    reconciling = False
    prerequisites = []
    def check(name, action):
        try:
            prerequisites.append({'name': name, 'status': 'passed', 'detail': action()})
        except (host.RunnerError, OSError, ValueError, KeyError) as error:
            prerequisites.append({'name': name, 'status': 'blocked', 'detail': str(error)})
    def baseline():
        nonlocal reconciling
        baseline_vm, baseline_record = state / 'baseline.vbvm', state / 'baseline.json'
        if retained and retained.get('phase') == 'promoting':
            intent = retained.get('promotion', {}).get('record', {})
            pending = intent.get('promotionPending', {})
            backup = pending.get('backup', '')
            if (intent.get('macosUpgradeID') != retained['upgradeID'] or intent.get('macos') != target or
                    re.fullmatch(r'previous-baseline-[0-9a-f]{32}\.vbvm', backup) is None):
                raise host.RunnerError('The interrupted macOS promotion has invalid ownership metadata')
            backup_vm = state / backup
            old = [path for path in (baseline_vm, backup_vm) if path.exists() and
                   [path.stat().st_dev, path.stat().st_ino] == retained['sourceBaseline']['fileID']]
            if len(old) != 1:
                raise host.RunnerError('The previous baseline identity cannot be established during promotion recovery')
            baseline_vm = old[0]
            reconciling = baseline_vm == backup_vm or retained['environment'] != environment
            if backup_vm.with_suffix('.json').exists():
                baseline_record = backup_vm.with_suffix('.json')
            handoff = transaction_path(host, state, retained['upgradeID']) / 'promotion-handoff.vbvm'
            withdrawn = handoff.parent / ('withdrawn-' + backup)
            promoted = [path for path in (handoff, withdrawn, state / 'candidate.vbvm', state / 'baseline.vbvm') if path.exists() and
                        [path.stat().st_dev, path.stat().st_ino] == pending.get('candidateFileID')]
            if len(promoted) != 1:
                raise host.RunnerError('The interrupted promotion candidate identity cannot be established')
            if vm_identity(host, promoted[0]) != retained['promotion'].get('vmIdentity'):
                raise host.RunnerError('The interrupted macOS promotion candidate changed')
            host.ensure_disk_idle(promoted[0])
            reconciling = reconciling or promoted[0] == withdrawn or stopped(host, handoff.parent, retained)
        record = host.read_json(canonical(host, baseline_record))
        if (not host.matches_source_vm(record, args.vm) or not record.get('verifiedAt') or
                not record.get('consoleUser') or record.get('verificationSigningMode') != 'local' or
                record.get('environment') != (retained['environment'] if reconciling else environment)):
            raise host.RunnerError('macOS upgrade requires the existing verified local baseline and unchanged toolchain pins')
        if (re.fullmatch(r'[A-Za-z0-9_-]{1,128}', str(record.get('vmId', ''))) is None or
                re.fullmatch(r'[A-Za-z0-9_-]{1,64}', str(record.get('consoleUser', ''))) is None or
                re.fullmatch(r'[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}', str(record.get('guestAccessID', ''))) is None):
            raise host.RunnerError('The baseline guest account identity is invalid')
        host.ensure_disk_idle(baseline_vm)
        value = identity(host, baseline_vm, baseline_record)
        if retained and retained.get('phase') == 'promoting' and value != retained['sourceBaseline']:
            raise host.RunnerError('The previous baseline changed during interrupted promotion')
        if retained and retained.get('phase') not in ('promoting', 'promoted', 'default-verification', 'complete'):
            if value != retained['sourceBaseline']:
                raise host.RunnerError('The original baseline changed after this upgrade began')
        if retained and retained.get('phase') in ('promoted', 'default-verification', 'complete'):
            verify_promoted_baseline(host, state, retained)
        access = state / 'guest-access' / record['vmId'] / record['guestAccessID']
        canonical(host, access, directory=True)
        if host.read_json(canonical(host, access / 'identity.json')) != {
                'vmId': record['vmId'], 'consoleUser': record['consoleUser']}:
            raise host.RunnerError('The existing guest account access identity does not match the baseline')
        host.guest_access_module().read_private_password(access / 'password')
        host.inherited_safari_preparation(state, record, record['consoleUser'])
        return {'macos': record.get('macos'), 'consoleUser': record['consoleUser'], 'vmPath': str(baseline_vm), 'identity': value}
    check('baseline', baseline)
    def unfinished():
        if not resumed and any((state / name).exists() or (state / name).is_symlink()
                               for name in ('candidate.vbvm', 'candidate.json')):
            raise host.RunnerError('Finish or preserve the existing setup candidate before starting a macOS upgrade')
        current = active_result(host, state)
        if attaching and (not current or current[1]['upgradeID'] != resumed or
                          current[1].get('launchToken') != retained.get('launchToken')):
            raise host.RunnerError('The selected upgrade no longer owns the active supervisor')
        if current and current[1]['upgradeID'] != resumed:
            if current[1]['status'] not in TERMINAL:
                raise host.RunnerError('Resume the existing macOS upgrade before starting another one')
            require_idle_upgrade(host, current[1])
        return 'No conflicting upgrade or setup candidate'
    check('transaction', unfinished)
    def xcode():
        actual = host.xcode_upgrade_module().installed_xcode(host, args.xcode)
        if actual != environment['xcode']:
            raise host.RunnerError('Selected Xcode does not match the existing toolchain pins')
        return actual
    if not reconciling and not attaching:
        def source_vm():
            host.validate_vm(args.vm)
            return str(args.vm)
        check('sourceVM', source_vm)
        check('disk', lambda: host.check_capacity(state, host.HOST_RESERVE_BYTES))
        check('manifestNode', host.manifest_node)
        check('xcode', xcode)
    if disk_bytes and not attaching:
        def system_disk():
            baseline_check = next((item for item in prerequisites if item['name'] == 'baseline' and item['status'] == 'passed'), None)
            if baseline_check is None:
                raise host.RunnerError('System disk inspection requires the verified source baseline')
            disk = Path(baseline_check['detail']['vmPath']) / 'Disk.img'
            size = disk.stat().st_size
            if disk_bytes < size:
                raise host.RunnerError('The upgrade never shrinks a system disk')
            allocated = retained and retained.get('systemDiskReady')
            if retained and retained['phase'] == 'system-disk-growth':
                receipt = Path(retained['stagingDirectory']) / 'system-disk-growth.json'
                if os.path.lexists(receipt):
                    allocated = host.read_json(canonical(host, receipt)).get('phase') in ('prepared', 'publishing', 'complete')
            layout = module('macos_disk').inspect_disk(host, disk, growth_target=None if allocated else disk_bytes)
            return {'currentBytes': size, 'requestedBytes': disk_bytes, 'layout': layout}
        check('systemDisk', system_disk)
    if retained and (not reconciling and retained.get('environment') != environment or retained.get('sourceVM') != str(args.vm) or
                     retained.get('xcodePath') != str(args.xcode)):
        raise host.RunnerError('Resume requires the original source VM, Xcode path, and toolchain pins')
    return {'version': 1, 'status': 'ready' if all(p['status'] == 'passed' for p in prerequisites) else 'blocked',
            'target': target, 'systemDiskBytes': disk_bytes or None, 'upgradeID': resumed, 'prerequisites': prerequisites,
            **({'control': 'attach'} if attaching else {}),
            'guestChecks': 'Live OS, volume ownership, and exact Software Update offer are checked in the isolated guest',
            'verification': 'Fresh setup, Safari roundtrips, full local suite, promotion, and default-runner OS verification'}


def copy_file(host, source, destination):
    canonical(host, source)
    canonical(host, host.private_directory(destination.parent), directory=True)
    temporary = destination.with_name('.' + destination.name + '.copying')
    if os.path.lexists(temporary):
        canonical(host, temporary).unlink()
    if destination.exists() or destination.is_symlink():
        canonical(host, destination)
        if host.hash_regular_file(source) != host.hash_regular_file(destination):
            raise host.RunnerError('Existing upgrade input differs from its retained source; preserve both files')
        return
    try:
        host.checked(['/bin/cp', '-c', source, temporary])
        canonical(host, temporary).chmod(0o600)
        if host.hash_regular_file(temporary) != host.hash_regular_file(source):
            raise host.RunnerError('Copied upgrade input differs from its retained source')
        temporary.rename(destination)
    finally:
        if os.path.lexists(temporary):
            canonical(host, temporary).unlink()


def copy_access(host, source_state, destination_state, record):
    scope = Path('guest-access') / record['vmId'] / record['guestAccessID']
    source = canonical(host, source_state / scope, directory=True)
    destination = host.private_directory(destination_state / scope)
    for name in ('password', 'identity.json'):
        copy_file(host, source / name, destination / name)


def copy_safari_evidence(host, source_state, destination_state, record):
    inherited = host.inherited_safari_preparation(source_state, record, record['consoleUser'])
    if not inherited:
        return record
    run_id = inherited['safariPreparation']['preparationRunID']
    source = Path(inherited['safariPreparationResult']).parent
    destination = host.private_directory(destination_state / 'results' / run_id / 'artifacts')
    for name in ('result.json', 'prepare-safari.macos.debug.safari-preparation.json'):
        copy_file(host, source / name, destination / name)
    copied = {**record, 'safariPreparationResult': str(destination / 'result.json')}
    host.inherited_safari_preparation(destination_state, copied, copied['consoleUser'])
    return copied


def copy_xcode_cache(host, state, staged, environment):
    for directory in (state / 'tools').glob('xcode-archive-*'):
        receipt = directory / 'identity.json'
        if not receipt.exists():
            continue
        canonical(host, directory, directory=True)
        value = host.read_json(canonical(host, receipt))
        if (value.get('xcodeVersion'), value.get('xcodeBuild')) != (
                environment['xcode']['version'], environment['xcode']['buildVersion']):
            continue
        for name in ('identity.json', 'Xcode.tar', 'Xcode.tar.sha256'):
            copy_file(host, directory / name, staged / 'tools' / directory.name / name)


def initialize_staging(host, state, directory, result, save):
    staged = host.private_directory(directory / 'state')
    if result.get('stagingReady'):
        pending_path = staged / 'candidate.json'
        if pending_path.exists():
            pending_record = host.read_json(canonical(host, pending_path))
            promotion = pending_record.get('promotionPending')
            if promotion is not None:
                if (result['phase'] not in ('setup', 'safari-preparation') or
                        pending_record.get('macosUpgradeID') != result['upgradeID'] or
                        pending_record.get('vmId') != result['vmId'] or pending_record.get('macos') != result['target'] or
                        pending_record.get('environment') != result['environment'] or
                        promotion.get('backupFileID', result['stagingFileID']) != result['stagingFileID'] or
                        result.get('stagingRecordSHA256') is not None and
                        promotion.get('backupRecordSHA256', result['stagingRecordSHA256']) != result['stagingRecordSHA256']):
                    raise host.RunnerError('The isolated setup promotion belongs to another VM or target')
                checked_result(host, result, {'result': pending_record.get('validationResult')})
                host.inherited_safari_preparation(staged, pending_record, pending_record['consoleUser'])
                host.finish_baseline_promotion(staged, pending_record)
        host.validate_vm(staged / 'baseline.vbvm')
        record = host.read_json(staged / 'baseline.json')
        info = canonical(host, staged / 'baseline.vbvm', directory=True).stat()
        file_id = [info.st_dev, info.st_ino]
        if (record.get('macosUpgradeID') != result['upgradeID'] or record.get('vmId') != result['vmId'] or
                record.get('environment') != result['environment'] or record.get('sourceVM') != result['sourceVM']):
            raise host.RunnerError('The staging baseline no longer belongs to this upgrade')
        if file_id != result.get('stagingFileID'):
            promotion = record.get('macosUpgradePromotion', {})
            if (result['phase'] not in ('setup', 'safari-preparation') or
                    promotion.get('sourceFileID') != result.get('stagingFileID') or
                    promotion.get('candidateFileID') != file_id):
                raise host.RunnerError('The isolated staging VM was replaced outside its verified setup promotion')
            step = {'result': record.get('validationResult')}
            checked_result(host, result, step)
            result['stagingFileID'] = file_id
            result['stagingRecordSHA256'] = host.hash_regular_file(staged / 'baseline.json')
            save()
        return staged
    if identity(host, state / 'baseline.vbvm', state / 'baseline.json') != result['sourceBaseline']:
        raise host.RunnerError('The source baseline changed before the isolated clone was completed')
    partial = staged / 'baseline-building.vbvm'
    destination = staged / 'baseline.vbvm'
    if result.get('cloneReady'):
        copies = [path for path in (partial, destination) if path.exists() and
                  [path.stat().st_dev, path.stat().st_ino] == result.get('stagingFileID')]
        if len(copies) != 1 or (partial.exists() and destination.exists()):
            raise host.RunnerError('The prepared staging clone changed before its handoff')
        host.validate_vm(copies[0])
        if host.read_json(staged / 'baseline.json').get('macosUpgradeID') != result['upgradeID']:
            raise host.RunnerError('The prepared staging record belongs to another upgrade')
        if copies[0] == partial:
            partial.rename(destination)
        result.update({'stagingReady': True, 'phase': 'installation'})
        save()
        return staged
    if destination.exists():
        raise host.RunnerError('An unrecorded staging baseline exists; preserve it before retrying')
    result['phase'] = 'cloning'
    save()
    if partial.exists() or partial.is_symlink():
        canonical(host, partial, directory=True)
        host.ensure_disk_idle(partial)
        shutil.rmtree(partial)
    host.clone_vm(state / 'baseline.vbvm', partial, clone_only=True)
    host.configure_guest_hardware(partial, result['upgradeID'])
    record = copy_safari_evidence(host, state, staged, copy.deepcopy(host.read_json(state / 'baseline.json')))
    record['macosUpgradeID'] = result['upgradeID']
    record.pop('macosUpgradePromotion', None)
    copy_access(host, state, staged, record)
    copy_xcode_cache(host, state, staged, result['environment'])
    if identity(host, state / 'baseline.vbvm', state / 'baseline.json') != result['sourceBaseline']:
        raise host.RunnerError('The source baseline changed while the isolated clone was being copied')
    host.atomic_json(staged / 'baseline.json', record)
    info = partial.stat()
    result.update({'cloneReady': True, 'stagingFileID': [info.st_dev, info.st_ino],
                   'stagingRecordSHA256': host.hash_regular_file(staged / 'baseline.json')})
    save()
    partial.rename(destination)
    result.update({'stagingReady': True, 'phase': 'installation'})
    save()
    return staged


def command_args(host, result, command, *, staging=True):
    args = host.parser().parse_args(command)
    args.vm = Path(result['sourceVM'])
    args.xcode = Path(result['xcodePath'])
    args.state_dir = Path(result['stagingDirectory'] if staging else result['stateDirectory'])
    args.timeout = result.get('timeout')
    return args


def interactive_requested(host, directory, result):
    if result.get('interactive'):
        return True
    path = directory / 'interactive.json'
    if not path.exists():
        return False
    return host.read_json(canonical(host, path)) == {
        'version': 1, 'upgradeID': result['upgradeID'], 'launchToken': result['launchToken']}


def stopped(host, directory, result):
    path = directory / 'stop.json'
    if not path.exists():
        return False
    value = host.read_json(canonical(host, path))
    if value.get('upgradeID') != result['upgradeID']:
        raise host.RunnerError('The upgrade stop request belongs to another transaction')
    return True


def required_suite_artifacts(host, plan, report):
    stages = report.get('stages')
    if (not isinstance(plan, dict) or plan.get('origin') != 'host-plan' or plan.get('runId') != report.get('runId') or
            plan.get('vmId') != report.get('vmId') or not isinstance(plan.get('stages'), list) or
            not isinstance(stages, list) or not stages or len(stages) != len(plan['stages'])):
        raise host.RunnerError('The full-suite report does not match its archived stage plan')
    files = {'planned-result.json'}
    bundles = {}
    stage_ids = set()
    for planned, stage in zip(plan['stages'], stages):
        name = planned.get('id') if isinstance(planned, dict) else None
        if (not isinstance(name, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', name) or
                name in stage_ids or not isinstance(stage, dict) or stage.get('id') != name or stage.get('status') != 'passed'):
            raise host.RunnerError('The full-suite report does not attest each planned stage')
        stage_ids.add(name)
        references = {'log': f'{name}.log'}
        for audit, field, filename in (
                ('approvalAudit', 'approvalEvidence', 'systematic-coverage.json'),
                ('upgradeAudit', 'upgradeEvidence', 'upgrade-report.json'),
                ('parserFuzzAudit', 'parserFuzzEvidence', 'parser-fuzz-report.json'),
                ('mutationAudit', 'mutationEvidence', 'mutation-report.json')):
            if audit in planned:
                references[field] = f'failures/{name}/{filename}'
        if 'nativeAudit' in planned:
            bundle = f'{name}.xcresult'
            if stage.get('resultBundle') != bundle or not isinstance(planned['nativeAudit'], dict):
                raise host.RunnerError(f'The full-suite report lacks its planned result bundle for {name}')
            inventory = stage.get('resultBundleInventorySHA256')
            if not isinstance(inventory, str) or not re.fullmatch(r'[a-f0-9]{64}', inventory):
                raise host.RunnerError(f'The full-suite report lacks its audited XCTest bundle inventory for {name}')
            bundles[bundle] = inventory
            files.update((f'{name}.summary.json', f'{name}.tests.json'))
            if planned['nativeAudit'].get('kind') == 'safari':
                references['safariEvidence'] = f'{name}.safari.json'
        if planned.get('preparationResult'):
            references['preparationResult'] = f'{name}.safari-preparation.json'
        if 'nativeAudit' in planned or planned.get('preparationResult'):
            simulator = stage.get('simulatorPreparation')
            if (not isinstance(simulator, dict) or simulator.get('artifact') != f'{name}.simulators.json' or
                    simulator.get('status') != 'passed' or not isinstance(simulator.get('steps'), list)):
                raise host.RunnerError(f'The full-suite report lacks its simulator preparation for {name}')
            files.add(simulator['artifact'])
            for item in simulator['steps']:
                log = item.get('log') if isinstance(item, dict) else None
                if not isinstance(log, str) or not re.fullmatch(re.escape(name) + r'\.simulator-[1-9][0-9]*-[a-z]+\.log', log):
                    raise host.RunnerError(f'The full-suite report has an invalid simulator log reference for {name}')
                files.add(log)
        if any(stage.get(field) != filename for field, filename in references.items()):
            raise host.RunnerError(f'The full-suite report lacks its planned artifact references for {name}')
        files.update(references.values())
    return files, bundles


def suite_archive_identity(host, artifacts, report):
    plan = host.read_json(canonical(host, artifacts / 'planned-result.json'))
    files, bundles = required_suite_artifacts(host, plan, report)
    digest = hashlib.sha256()

    def fingerprint(path, info):
        # APFS file identity and change time detect replacement or in-place edits without rereading large bundles.
        digest.update(json.dumps([str(path.relative_to(artifacts)), info.st_dev, info.st_ino, info.st_size,
                                  info.st_mtime_ns, info.st_ctime_ns]).encode())

    def members(directory):
        with os.scandir(directory) as entries:
            for entry in sorted(entries, key=lambda item: item.name):
                info = entry.stat(follow_symlinks=False)
                if info.st_uid != os.getuid() or not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
                    raise host.RunnerError(f'Unsafe full-suite artifact: {entry.path}')
                if stat.S_ISDIR(info.st_mode):
                    yield from members(entry.path)
                else:
                    yield Path(entry.path), info

    evidence_directories = {str(Path(name).parent) for name in files if name.startswith('failures/')}
    try:
        for name in sorted(files):
            path = canonical(host, artifacts / name)
            info = path.stat()
            if not info.st_size and path.suffix != '.log':
                raise host.RunnerError(f'Empty full-suite artifact: {name}')
            fingerprint(path, info)
        for name in sorted(bundles.keys() | evidence_directories):
            directory = canonical(host, artifacts / name, directory=True)
            inventory = []
            for path, info in members(directory):
                fingerprint(path, info)
                if name in bundles:
                    inventory.append(f'{path.relative_to(directory)}\0{info.st_size}\0'.encode())
            if name in bundles and hashlib.sha256(b''.join(sorted(inventory))).hexdigest() != bundles[name]:
                raise host.RunnerError(f'The full-suite archive is missing required artifacts or has changed sizes inside {name}')
    except FileNotFoundError as error:
        raise host.RunnerError(f'The full-suite archive is missing required artifacts: {error.filename}') from error
    return digest.hexdigest()


def checked_result(host, result, step, *, full=False):
    if not step.get('result'):
        raise host.RunnerError('The upgrade validation did not collect a result')
    path = canonical(host, Path(step['result']))
    with host.open_regular(path) as file:
        contents = file.read()
    digest = hashlib.sha256(contents).hexdigest()
    if 'resultSHA256' in step and step['resultSHA256'] != digest:
        raise host.RunnerError('The full-suite report changed before promotion')
    report = json.loads(contents)
    if (not isinstance(report, dict) or report.get('status') != 'passed' or not report.get('finishedAt') or
            report.get('hostTermination') or report.get('vmId') != result['vmId'] or
            not host.environment_attested(report.get('preflight', {}), result['environment'], result['target'])):
        raise host.RunnerError('The upgraded guest did not attest a complete passing result with the exact environment')
    if full:
        coverage = report.get('coverage')
        if not isinstance(coverage, dict) or coverage.get('fullSuiteVerified') is not True:
            raise host.RunnerError('The unfiltered upgrade run did not attest full-suite verification')
        run_directory = path.parent.parent
        if (run_directory.parent != Path(result['stagingDirectory']) / 'results' or
                run_directory.name != report.get('runId') or path != run_directory / 'artifacts/result.json'):
            raise host.RunnerError('The full-suite result does not belong to the staged run archive')
        archive = suite_archive_identity(host, path.parent, report)
        if 'resultSHA256' in step and step.get('archiveIdentitySHA256') != archive:
            raise host.RunnerError('The full-suite archive changed since validation')
        step['archiveIdentitySHA256'] = archive
    step.update({'status': 'passed', 'resultSHA256': digest, 'source': report.get('source'),
                 'macos': report['preflight']['macos']['actual']})
    return report


def safari_consent_missing(host, result):
    step = result['steps'][-1] if result.get('steps') else {}
    if not step.get('result'):
        return False
    report = host.read_json(Path(step['result']))
    failure = "The prepared VM's Wallet activation did not survive this run's installation or Safari restart"
    return any(isinstance(issue, str) and issue.startswith('Safari XCTest failure: ') and failure in issue
               for stage in report.get('stages', []) if stage.get('id') == 'safari.macos.debug'
               for issue in stage.get('audit', {}).get('issues', []))


def validation_step(host, result, directory, name, command, save, *, setup=False, staging=True):
    if stopped(host, directory, result):
        raise InterruptedError('macOS upgrade cancellation requested')
    step = {'name': name, 'status': 'running', 'startedAt': now()}
    if setup:
        step['interactive'] = '--interactive' in command
    result['steps'].append(step)
    result['phase'] = name
    save()
    args = command_args(host, result, command, staging=staging)
    args.cancellation_requested = lambda: stopped(host, directory, result)
    state = args.state_dir
    if name == 'full-suite':
        step['baseline'] = identity(host, state / 'baseline.vbvm', state / 'baseline.json')
        save()
    if setup and staging:
        result['stagingRecordSHA256'] = host.hash_regular_file(state / 'baseline.json')
        save()
    def observed(path, report):
        step.update({'result': str(path), 'guestStatus': report.get('status'), 'reason': report.get('reason')})
        save()
    if setup:
        code = host.setup(args, state, result['environment'], result_callback=observed, force_verification=True)
    else:
        code = host.run_tests(args, state, result['environment'], result_callback=observed)
    if code:
        step['status'] = step.get('guestStatus', 'failed')
        save()
        if step['status'] == 'cancelled':
            raise InterruptedError(f'{name} was cancelled')
        raise host.RunnerError(f'{name} did not pass; inspect its collected result and resume the upgrade')
    if name == 'full-suite' and identity(host, state / 'baseline.vbvm', state / 'baseline.json') != step['baseline']:
        raise host.RunnerError('The staged baseline changed during full-suite verification')
    report = checked_result(host, result, step, full=name == 'full-suite')
    if setup and staging:
        record = host.read_json(state / 'baseline.json')
        info = canonical(host, state / 'baseline.vbvm', directory=True).stat()
        if record.get('macosUpgradeID') != result['upgradeID']:
            raise host.RunnerError('Setup lost the macOS upgrade candidate identity')
        result['stagingFileID'] = [info.st_dev, info.st_ino]
        result['stagingRecordSHA256'] = host.hash_regular_file(state / 'baseline.json')
    step['finishedAt'] = now()
    save()
    return report


def require_source(host, directory, expected):
    if not isinstance(expected, dict) or not re.fullmatch(r'[a-f0-9]{64}', str(expected.get('sha256', ''))):
        raise host.RunnerError('Full-suite verification has no valid source snapshot')
    with tempfile.TemporaryDirectory(dir=directory, prefix='source-check-') as exchange:
        observed = host.snapshot_source(host.ROOT, Path(exchange))
    if observed['sha256'] != expected['sha256']:
        raise host.RunnerError('Repository sources changed after the full suite; resume to validate the current source before promotion')
    return observed


def promotion_evidence(host, directory, result, *, check_source=True):
    full = next((step for step in reversed(result['steps']) if step['name'] == 'full-suite' and step.get('status') == 'passed'), None)
    if not full or not result.get('fullSuiteVerified'):
        raise host.RunnerError('The active baseline cannot change before full-suite verification')
    if not full.get('resultSHA256'):
        raise host.RunnerError('The full-suite report has no recorded digest')
    checked_result(host, result, full, full=True)
    if check_source:
        require_source(host, directory, full['source'])
    if host.read_json(host.TOOLS / 'environment.json') != result['environment']:
        raise host.RunnerError('Toolchain pins changed during the macOS upgrade')
    return full


def finish_promotion(host, state, directory, result, save):
    intent = result.get('promotion', {})
    record = intent.get('record', {})
    if record.get('macosUpgradeID') != result['upgradeID']:
        raise host.RunnerError('The macOS promotion has no matching recorded handoff')
    pending = record.get('promotionPending', {})
    if re.fullmatch(r'previous-baseline-[0-9a-f]{32}\.vbvm', str(pending.get('backup', ''))) is None:
        raise host.RunnerError('The interrupted macOS promotion has an invalid backup path')
    candidate = state / 'candidate.vbvm'
    candidate_path = state / 'candidate.json'
    handoff = directory / 'promotion-handoff.vbvm'
    baseline = state / 'baseline.vbvm'
    backup = state / pending['backup']
    withdrawn = directory / ('withdrawn-' + backup.name)
    locations = [path for path in (handoff, candidate, baseline, withdrawn) if path.exists() and
                 [path.stat().st_dev, path.stat().st_ino] == pending['candidateFileID']]
    if len(locations) != 1:
        raise host.RunnerError('The macOS promotion candidate identity changed; preserving all VM bundles')
    location = locations[0]
    displaced = backup.exists()
    stale_reason = None
    if location == withdrawn:
        if displaced:
            raise host.RunnerError('The original baseline moved after promotion was withdrawn')
        stale_reason = 'The previous macOS promotion was withdrawn'
    elif not displaced and not stopped(host, directory, result):
        try:
            promotion_evidence(host, directory, result)
        except (host.RunnerError, OSError, ValueError) as error:
            stale_reason = str(error)
    old = backup if displaced else baseline
    old_record = backup.with_suffix('.json') if displaced else state / 'baseline.json'
    if identity(host, old, old_record) != result['sourceBaseline']:
        raise host.RunnerError('The active baseline changed before the macOS promotion handoff')
    if vm_identity(host, location) != intent.get('vmIdentity') or host.validate_vm(location).get('sharedFolders') != []:
        raise host.RunnerError('The macOS promotion candidate identity changed; preserving all VM bundles')
    host.ensure_disk_idle(location)
    if any(os.path.lexists(path) for path in (handoff, candidate, withdrawn) if path != location):
        raise host.RunnerError('Another candidate occupies the macOS promotion destination')
    pending_record = None
    if os.path.lexists(candidate_path):
        pending_record = host.read_json(canonical(host, candidate_path))
        if location == handoff or pending_record not in (record, promotion_record_with_backup(result)):
            raise host.RunnerError('Pending promotion belongs to another operation')

    def withdraw(location, pending_record):
        archived_record = withdrawn.with_suffix('.json')
        if os.path.lexists(archived_record):
            if (location != withdrawn or pending_record is not None or
                    host.read_json(canonical(host, archived_record)) not in (record, promotion_record_with_backup(result))):
                raise host.RunnerError('The withdrawn macOS promotion record has conflicting ownership')
        backup_record = backup.with_suffix('.json')
        if (os.path.lexists(backup_record) and
                host.hash_regular_file(canonical(host, backup_record)) != result['sourceBaseline']['recordSHA256']):
            raise host.RunnerError('The previous baseline metadata backup changed before withdrawal')
        if location != withdrawn:
            location.rename(withdrawn)
        if pending_record is not None:
            candidate_path.rename(archived_record)
        elif not archived_record.exists():
            host.atomic_json(archived_record, record)
        backup_record.unlink(missing_ok=True)
        result.update({'phase': 'setup', 'fullSuiteVerified': False})
        result.pop('promotion')
        result.pop('previousBaseline')
        save()

    def check_stop(location, pending_record):
        if stopped(host, directory, result):
            withdraw(location, pending_record)
            raise InterruptedError('macOS upgrade cancellation requested before promotion')

    if not displaced:
        check_stop(location, pending_record)
    if stale_reason is not None:
        withdraw(location, pending_record)
        raise host.RunnerError(f'{stale_reason}. Promotion evidence retained at {withdrawn}; resume to rerun verification')
    if location == handoff:
        handoff.rename(candidate)
    if pending_record is None and location != baseline:
        pending_record = copy.deepcopy(record)
        host.atomic_json(candidate_path, pending_record)
    if pending_record is not None:
        host.finish_baseline_promotion(state, pending_record, before_swap=lambda: check_stop(candidate, pending_record))
    verify_promoted_baseline(host, state, result)
    result.update({'phase': 'promoted', 'promotedAt': result.get('promotedAt') or now()})
    save()


def promote(host, state, directory, result, save):
    staged = Path(result['stagingDirectory'])
    full = promotion_evidence(host, directory, result)
    if stopped(host, directory, result):
        raise InterruptedError('macOS upgrade cancellation requested before promotion')
    if identity(host, state / 'baseline.vbvm', state / 'baseline.json') != result['sourceBaseline']:
        raise host.RunnerError('The active baseline changed during the isolated upgrade')
    if any((state / name).exists() or (state / name).is_symlink() for name in ('candidate.json', 'candidate.vbvm')):
        raise host.RunnerError('Another setup candidate exists; preserve it before macOS promotion')
    staged_vm, staged_record = staged / 'baseline.vbvm', staged / 'baseline.json'
    if identity(host, staged_vm, staged_record) != full.get('baseline'):
        raise host.RunnerError('The staged baseline no longer matches the verified upgrade')
    record = host.read_json(staged_record)
    if (record.get('macos') != result['target'] or record.get('environment') != result['environment'] or
            record.get('macosUpgradeID') != result['upgradeID'] or record.get('vmId') != result['vmId'] or
            record.get('bootstrapSourceDigest') != host.bootstrap_source_digest() or
            full['baseline']['fileID'] != result.get('stagingFileID')):
        raise host.RunnerError('The staged baseline no longer matches the verified upgrade')
    host.ensure_disk_idle(staged_vm)
    record = copy_safari_evidence(host, staged, state, record)
    copy_access(host, staged, state, record)
    record['macosUpgradeResult'] = str(directory / 'result.json')
    handoff = directory / 'promotion-handoff.vbvm'
    if handoff.exists() or handoff.is_symlink():
        canonical(host, handoff, directory=True)
        host.ensure_disk_idle(handoff)
        shutil.rmtree(handoff)
    host.clone_vm(staged_vm, handoff, clone_only=True)
    if identity(host, staged_vm, staged_record) != full['baseline']:
        raise host.RunnerError('The verified staging VM or record changed during the promotion copy')
    if stopped(host, directory, result):
        raise InterruptedError('macOS upgrade cancellation requested before promotion')
    info = handoff.stat()
    record['promotionPending'] = {'backup': 'previous-baseline-' + uuid.uuid4().hex + '.vbvm',
                                  'candidateFileID': [info.st_dev, info.st_ino]}
    result.update({'phase': 'promoting', 'promotion': {'record': record, 'vmIdentity': vm_identity(host, handoff)},
                   'previousBaseline': str(state / record['promotionPending']['backup'])})
    save()
    finish_promotion(host, state, directory, result, save)


def execute(host, state, directory, result, save):
    if result['phase'] in ('promoting', 'promoted', 'default-verification', 'complete'):
        if result['phase'] == 'promoting':
            finish_promotion(host, state, directory, result, save)
        promotion_evidence(host, directory, result, check_source=False)
    else:
        staged = host.private_directory(directory / 'state')
        with host.execution_lock(staged):
            if (result.get('stagingReady') and result.get('phase') == 'system-disk-growth' and
                    result.get('systemDiskBytes') and not result.get('systemDiskReady')):
                info = canonical(host, staged / 'baseline.vbvm', directory=True).stat()
                if ([info.st_dev, info.st_ino] != result.get('stagingFileID') or
                        identity(host, state / 'baseline.vbvm', state / 'baseline.json') != result['sourceBaseline']):
                    raise host.RunnerError('The retained disk-growth source or candidate identity changed')
                result['systemDiskGrowth'] = module('macos_disk').grow(host, staged / 'baseline.vbvm',
                    result['systemDiskBytes'], staged / 'system-disk-growth.json')
                result.update({'systemDiskReady': True, 'phase': 'installation'})
                save()
            initialize_staging(host, state, directory, result, save)
            if result.get('systemDiskBytes') and not result.get('systemDiskReady'):
                if stopped(host, directory, result):
                    raise InterruptedError('macOS upgrade cancelled before system disk growth')
                result['phase'] = 'system-disk-growth'
                save()
                result['systemDiskGrowth'] = module('macos_disk').grow(host, staged / 'baseline.vbvm',
                    result['systemDiskBytes'], staged / 'system-disk-growth.json')
                result.update({'systemDiskReady': True, 'phase': 'installation'})
                save()
            if identity(host, state / 'baseline.vbvm', state / 'baseline.json') != result['sourceBaseline']:
                raise host.RunnerError('The active baseline changed; this upgrade cannot be resumed')
            if not result.get('installationVerified'):
                result['phase'] = 'installation'
                save()
                record = host.read_json(staged / 'baseline.json')
                def progress(value):
                    result['installation'] = value
                    save()
                args = command_args(host, result, ['setup'])
                args.interactive = interactive_requested(host, directory, result)
                args.interactive_requested = lambda: interactive_requested(host, directory, result)
                args.system_disk_growth = result.get('systemDiskGrowth')
                installed = module('macos_vm').install(host, args, staged, record, result['upgradeID'], result['target'],
                    progress, lambda: stopped(host, directory, result))
                result['installation'] = installed
                save()
                if installed.get('status') == 'cancelled':
                    raise InterruptedError('macOS upgrade cancelled after a stable guest boot')
                if installed.get('status') != 'complete' or installed.get('actual') != result['target']:
                    raise host.RunnerError(installed.get('reason', 'The requested macOS installation is not verified'))
                record = host.read_json(staged / 'baseline.json')
                record['macos'] = result['target']
                for key in ('baseVerifiedAt', 'verifiedAt', 'validationResult'):
                    record.pop(key, None)
                host.atomic_json(staged / 'baseline.json', record)
                result.update({'phase': 'setup', 'installationVerified': True,
                               'stagingRecordSHA256': host.hash_regular_file(staged / 'baseline.json')})
                save()
            host.reconcile_interrupted_operation(staged)
            def prepare_safari():
                result['phase'] = 'safari-preparation'
                save()
                if not interactive_requested(host, directory, result):
                    raise host.RunnerError('Safari activation is required; resume this upgrade with --interactive for guest consent')
                validation_step(host, result, directory, 'safari-preparation',
                                ['setup', '--interactive', '--safari-activation'], save, setup=True)

            roundtrips = ['run', 'all', '--stage', 'safari', '--configuration', 'Debug',
                          '--only-testing', 'SafariLifecycleTests/testInstallAndNativeRoundtrip']
            if result['phase'] == 'safari-preparation':
                prepare_safari()
            else:
                setup_command = ['setup'] + (['--interactive'] if interactive_requested(host, directory, result) else [])
                validation_step(host, result, directory, 'setup', setup_command, save, setup=True)
                baseline = host.read_json(staged / 'baseline.json')
                if not host.inherited_safari_preparation(staged, baseline, baseline['consoleUser']):
                    prepare_safari()
            try:
                validation_step(host, result, directory, 'safari-roundtrips', roundtrips, save)
            except host.RunnerError:
                if not safari_consent_missing(host, result):
                    raise
                prepare_safari()
                validation_step(host, result, directory, 'safari-roundtrips', roundtrips, save)
            validation_step(host, result, directory, 'full-suite', ['run', 'all'], save)
            result['fullSuiteVerified'] = True
            save()
            promote(host, state, directory, result, save)
    verify_promoted_baseline(host, state, result)
    validation_step(host, result, directory, 'default-verification', ['run', 'all', '--stage', 'test', '--configuration', 'Debug',
        '--only-testing', 'Tests macOS/WindowAuthenticationSessionTests'], save, staging=False)
    verify_promoted_baseline(host, state, result)
    result.update({'status': 'passed', 'phase': 'complete', 'finishedAt': now()})
    save()


def worker(state, identifier, launch_token):
    loaded = module('host')
    host = SimpleNamespace(**vars(loaded))
    state = canonical(host, Path(state), directory=True)
    directory, result = load_result(host, state, identifier)
    os.umask(0o077)
    def save():
        result['updatedAt'] = now()
        host.atomic_json(directory / 'result.json', result)
    def cancel(signum, frame):
        host.atomic_json(directory / 'stop.json', {'version': 1, 'upgradeID': identifier, 'requestedAt': now()})
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, cancel)
    try:
        with supervisor_lock(host, state):
            current = active_result(host, state)
            if (current is None or current[1]['upgradeID'] != identifier or
                    current[1].get('launchToken') != launch_token):
                raise host.RunnerError('Another upgrade owns the active supervisor record')
            result = current[1]
            start = process_start(os.getpid())
            if start is None:
                raise host.RunnerError('Could not establish the macOS upgrade supervisor identity')
            result.update({'status': 'running', 'supervisor': {'pid': os.getpid(), 'start': start}})
            save()
            if result['phase'] not in ('installation', 'cloning'):
                host.reconcile_interrupted_operation(state)
            execute(host, state, directory, result, save)
            (state / 'macos-upgrade-active.json').unlink()
        return 0
    except BaseException as error:
        reason = str(error) or type(error).__name__
        current = load_result(host, state, identifier)[1]
        if current.get('launchToken') == launch_token and current['status'] != 'passed':
            result.update({'status': 'cancelled' if isinstance(error, (InterruptedError, KeyboardInterrupt)) else 'blocked',
                           'reason': reason, 'finishedAt': now()})
            save()
        print(f'macOS upgrade stopped: {reason}', flush=True)
        return 2


def installation_state(host, directory, result, *, allow_abandoned=False, starting=False):
    if result.get('phase') not in (('installation', 'abandoned') if allow_abandoned else ('installation',)):
        raise host.RunnerError('Installer diagnostics require the retained installation phase')
    staged = Path(result['stagingDirectory'])
    vm = canonical(host, staged / 'baseline.vbvm', directory=True)
    info = vm.stat()
    expected = {'upgradeID': result['upgradeID'], 'target': result['target'], 'vmId': result['vmId'],
                'vm': str(vm), 'vmFileID': [info.st_dev, info.st_ino]}
    record = host.read_json(canonical(host, staged / 'baseline.json'))
    if (expected['vmFileID'] != result.get('stagingFileID') or record.get('vmId') != result['vmId'] or
            record.get('macosUpgradeID') != result['upgradeID'] or
            record.get('sourceVM') != result['sourceVM']):
        raise host.RunnerError('The retained installation record no longer belongs to this upgrade')
    install = staged / 'macos-install'
    if starting and not os.path.lexists(install / 'install.json'):
        if os.path.lexists(install):
            canonical(host, install, directory=True)
        return None, None, record
    canonical(host, install, directory=True)
    journal = host.read_json(canonical(host, install / 'install.json'))
    if any(journal.get(key) != value for key, value in expected.items()) or not (starting or journal.get('access')):
        raise host.RunnerError('Installer diagnostic identity does not match the retained candidate')
    runtime = module('macos_vm')
    runtime._validate_native(host, staged, install, journal)
    return runtime, journal, record


def installation_context(host, directory, result):
    runtime, journal, record = installation_state(host, directory, result)
    if not runtime._native_alive(host, journal, None):
        raise host.RunnerError('Installer diagnostics never start a VM; resume the stopped upgrade first')
    staged = Path(result['stagingDirectory'])
    install, vm = staged / 'macos-install', Path(journal['vm'])
    access, context = runtime._access_context(host, staged, vm, record, install, journal)
    address = access.find_guest_address(journal['access']['macAddress'])
    if not address:
        raise host.RunnerError('The running upgrade guest has no known address; retry after its reboot')
    context['address'] = address
    return runtime, journal, context


def diagnose(host, state, directory, result):
    _, _, context = installation_context(host, directory, result)
    observation = module('macos_transport').diagnose(host, context, result['target'], result['upgradeID'])
    destination = host.private_directory(directory / 'diagnostics') / ('installer-' + uuid.uuid4().hex + '.json')
    host.atomic_json(destination, {'version': 1, 'upgradeID': result['upgradeID'], 'collectedAt': now(), 'observation': observation})
    return {'path': str(destination), 'actual': observation.get('actual'), 'status': observation.get('status')}


def installation_owner(host, state, result):
    current = active_result(host, state)
    owns_installation = current[1]['upgradeID'] == result['upgradeID'] if current else released(result)
    if (not owns_installation or
            result['phase'] not in ('installation', 'abandoned') or
            result.get('promotedAt') or identity(host, state / 'baseline.vbvm', state / 'baseline.json') != result['sourceBaseline']):
        raise host.RunnerError('Installer control requires the unchanged active baseline and its own isolated installation')


def abandonment_evidence(host, directory, result, record, journal):
    path = canonical(host, directory / 'abandonment.json')
    collected = host.read_json(path)
    if not isinstance(collected, dict) or not isinstance(collected.get('guestEvidence'), dict):
        raise host.RunnerError('Collected abandonment evidence is invalid')
    evidence = collected['guestEvidence']
    intent, receipt = evidence.get('abandonment'), evidence.get('receipt')
    nonce = journal.get('upgradeNonce')
    if not isinstance(nonce, str) or not re.fullmatch(r'[0-9a-f]{64}', nonce):
        raise host.RunnerError('The abandoned candidate has no valid installation enrollment')
    request = {'upgradeID': result['upgradeID'], 'target': result['target'], 'upgradeNonce': nonce,
               'vmId': result['vmId'], 'consoleUser': record.get('consoleUser')}
    if (collected.get('version') != 1 or collected.get('upgradeID') != result['upgradeID'] or
            not isinstance(intent, dict) or not isinstance(receipt, dict) or
            intent.get('version') != 1 or receipt.get('version') != 1 or
            any(intent.get(key) != value or receipt.get(key) != value for key, value in request.items()) or
            evidence.get('status') != 'blocked' or evidence.get('safeToStop') is not False or
            evidence.get('reason') != 'upgrade_abandoned_for_storage' or
            intent.get('reason') != 'insufficient_guest_system_storage' or
            receipt.get('phase') not in ('restart-pending', 'failed')):
        raise host.RunnerError('Collected abandonment evidence does not match this VM and target')
    actual = host.macos_identity(evidence.get('actual'))
    boot = evidence.get('bootIdentity')
    digest = hashlib.sha256((json.dumps(receipt, sort_keys=True, allow_nan=False) + '\n').encode()).hexdigest()
    if (actual == result['target'] or intent.get('before') != actual or receipt.get('before') != actual or
            not isinstance(boot, str) or re.fullmatch(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}', boot) is None or
            intent.get('preBootIdentity') != boot or receipt.get('preBootIdentity') != boot or
            intent.get('receiptSHA256') != digest or
            result.get('abandonmentResult', str(path)) != str(path)):
        raise host.RunnerError('Collected abandonment receipt or boot identity changed')
    proof = intent.get('evidence', {})
    sizes = ('requiredBytes', 'freeBytesAtRejection', 'currentAvailableBytes')
    if (not isinstance(proof, dict) or any(type(proof.get(key)) is not int or proof[key] < 0 for key in sizes) or
            not 0 <= proof['freeBytesAtRejection'] < proof['requiredBytes'] or
            not 0 <= proof['currentAvailableBytes'] < proof['requiredBytes'] or
            proof.get('noInstallerProcesses') is not True or
            proof.get('workerPID') != receipt.get('workerPID') or proof.get('installerPID') != receipt.get('installerPID')):
        raise host.RunnerError('Collected abandonment evidence does not establish storage rejection')
    return {'path': str(path), 'receiptSHA256': digest, 'actual': actual, 'bootIdentity': boot}


def stopped_abandonment(host, state, directory, result):
    installation_owner(host, state, result)
    if supervisor_alive(result):
        raise host.RunnerError('The macOS upgrade supervisor still owns this installation')
    runtime, journal, record = installation_state(host, directory, result, allow_abandoned=True)
    if runtime._native_alive(host, journal, None):
        raise host.RunnerError('The abandoned candidate is still running; no local completion was recorded')
    status = runtime._native_status(host, journal)
    if not isinstance(status, dict) or status.get('state') != 'stopped' or status.get('running') is not False:
        raise host.RunnerError('The abandoned candidate has no verified terminal stopped state')
    host.ensure_disk_idle(Path(journal['vm']))
    return abandonment_evidence(host, directory, result, record, journal)


def abandon(host, args, state):
    directory, result = load_result(host, state, args.resume)
    installation_owner(host, state, result)
    runtime, journal, record = installation_state(host, directory, result, allow_abandoned=True)
    if runtime._native_alive(host, journal, None):
        if result['phase'] == 'abandoned':
            raise host.RunnerError('The completed abandoned candidate was restarted; no guest command was sent')
        _, _, context = installation_context(host, directory, result)
        evidence = module('macos_transport').abandon(host, context, result['target'], result['upgradeID'])
        host.atomic_json(directory / 'abandonment.json', {'version': 1, 'upgradeID': result['upgradeID'],
                         'requestedAt': now(), 'guestEvidence': evidence})
        abandonment_evidence(host, directory, result, record, journal)
    print('The storage-rejected candidate is being preserved; waiting for its supervisor to release ownership.', flush=True)
    deadline = time.monotonic() + 90
    while supervisor_alive(load_result(host, state, args.resume)[1]):
        if time.monotonic() >= deadline:
            raise host.RunnerError('The supervisor has not released the protected VM; no shutdown was attempted')
        time.sleep(1)
    with host.execution_lock(state):
        directory, result = load_result(host, state, args.resume)
        installation_owner(host, state, result)
        runtime, journal, record = installation_state(host, directory, result, allow_abandoned=True)
        if runtime._native_alive(host, journal, None):
            abandonment_evidence(host, directory, result, record, journal)
            _, _, context = installation_context(host, directory, result)
            context['supervisorExited'] = True
            module('macos_transport').halt_abandoned(host, context, result['target'], result['upgradeID'])
            print('The guest has been asked to shut down normally. Hypervisor force-stop remains disabled.', flush=True)
        deadline = time.monotonic() + 90
        while runtime._native_alive(host, journal, None):
            if time.monotonic() >= deadline:
                raise host.RunnerError('Guest shutdown did not complete; the protected candidate remains preserved')
            time.sleep(1)
        stopped_abandonment(host, state, directory, result)
        if result['phase'] != 'abandoned':
            result.update({'status': 'cancelled', 'phase': 'abandoned', 'finishedAt': now(),
                           'reason': 'Storage-rejected candidate preserved after graceful guest shutdown',
                           'abandonmentResult': str(directory / 'abandonment.json')})
            result.setdefault('installation', {}).update({'vmPreservedRunning': False, 'abandoned': True})
            host.atomic_json(directory / 'result.json', result)
    print(f'Preserved stopped candidate and diagnostics: {directory}', flush=True)
    return 0


def control(host, args, state):
    current = active_result(host, state)
    if current is None:
        return None
    directory, result = current
    alive = supervisor_alive(result)
    if not alive and (state / 'active.json').exists():
        return None
    if args.command == 'stop':
        if not alive:
            print('The macOS upgrade supervisor is stopped. Its candidate and results remain available for resume.')
            return 0
        host.atomic_json(directory / 'stop.json', {'version': 1, 'upgradeID': result['upgradeID'], 'requestedAt': now()})
        for scope in (Path(result['stagingDirectory']), state):
            active = scope / 'active.json'
            if active.exists():
                value = host.read_json(active)
                if value.get('ownerPID') == result.get('supervisor', {}).get('pid'):
                    host.publish_stop(Path(value['exchange']), value['runId'], requested=True)
        print('macOS upgrade stop requested. A committed OS installation will finish booting before cancellation.')
    else:
        display = {key: result.get(key) for key in ('upgradeID', 'status', 'phase', 'target', 'installation',
                    'fullSuiteVerified', 'promotedAt', 'reason', 'updatedAt') if result.get(key) is not None}
        display.update({'supervisorRunning': alive, 'result': str(directory / 'result.json')})
        if getattr(args, 'diagnose', False):
            display['diagnostics'] = diagnose(host, state, directory, result)
        for scope in (Path(result['stagingDirectory']), state):
            if (scope / 'active.json').exists():
                active = host.read_json(scope / 'active.json')
                display['operation'] = {key: active.get(key) for key in ('runId', 'phase', 'vm', 'exchange')}
        print(json.dumps(display, indent=2))
    return 0


def wait_for_worker(host, state, identifier, process=None, *, interactive=False):
    last = None
    try:
        while True:
            directory, result = load_result(host, state, identifier)
            progress = (result.get('status'), result.get('phase'), result.get('installation', {}).get('phase'))
            if progress != last:
                print(f'macOS upgrade: {progress[0]} / {progress[1]}' + (f' / {progress[2]}' if progress[2] else ''), flush=True)
                last = progress
            if result['status'] in TERMINAL:
                if result.get('reason'):
                    print(result['reason'], flush=True)
                return 0 if result['status'] == 'passed' else 2
            if interactive:
                check_setup_window(host, result)
            if (result.get('installation', {}).get('phase') == 'needs-attention' or
                    result.get('installation', {}).get('attentionRequired')):
                print('The installer still owns the isolated VM. Use status; installation will not be force-stopped.', flush=True)
                return 2
            if process is not None and process.poll() is not None or process is None and not supervisor_alive(result):
                raise host.RunnerError('The upgrade supervisor exited without a completed report; resume its upgrade ID')
            time.sleep(2)
    except KeyboardInterrupt:
        print(f'Detached from {identifier}; the upgrade supervisor continues. Use status or stop.', flush=True)
        return 130


def upgrade(host, args, state):
    report = preview(host, args, state)
    print(json.dumps(report, indent=2), flush=True)
    if report['status'] != 'ready':
        return 2
    if args.check:
        return 0
    if getattr(args, 'abandon', False):
        return abandon(host, args, state)
    resumed = getattr(args, 'resume', None)
    if resumed:
        directory, retained = load_result(host, state, resumed)
        if supervisor_alive(retained):
            current = active_result(host, state)
            if (current is None or current[1]['upgradeID'] != resumed or
                    current[1].get('launchToken') != retained.get('launchToken')):
                raise host.RunnerError('The selected upgrade no longer owns the active supervisor')
            if args.interactive:
                host.atomic_json(directory / 'interactive.json', {
                    'version': 1, 'upgradeID': resumed, 'launchToken': retained['launchToken']})
            return wait_for_worker(host, state, resumed, interactive=args.interactive)
        if report.get('control') == 'attach':
            raise host.RunnerError('The installation supervisor exited; retry resume to check startup prerequisites')
    process = None
    with host.execution_lock(state):
        current = active_result(host, state, clear_complete=True)
        if current and current[1]['upgradeID'] != resumed:
            if current[1]['status'] not in TERMINAL:
                raise host.RunnerError('Another macOS upgrade owns this state directory')
            require_idle_upgrade(host, current[1])
        if resumed:
            directory, result = load_result(host, state, resumed)
            if supervisor_alive(result):
                raise host.RunnerError('The macOS upgrade supervisor is already running')
            if result['phase'] == 'abandoned':
                raise host.RunnerError('This upgrade was abandoned; start a new upgrade to install macOS')
            if result['status'] == 'passed':
                raise host.RunnerError('This upgrade is complete; start a new explicit version/build verification')
            stop = directory / 'stop.json'
            if stop.exists() and result['phase'] != 'promoting':
                stop.rename(directory / ('stop-' + uuid.uuid4().hex + '.json'))
            result.update({'status': 'starting', 'interactive': bool(args.interactive), 'timeout': args.timeout})
            result.pop('reason', None)
            result.pop('finishedAt', None)
        else:
            host.reconcile_interrupted_operation(state)
            selected = next(p['detail']['identity'] for p in report['prerequisites'] if p['name'] == 'baseline')
            locked = preview(host, args, state)
            if locked['status'] != 'ready':
                print(json.dumps(locked, indent=2), flush=True)
                return 2
            if next(p['detail']['identity'] for p in locked['prerequisites'] if p['name'] == 'baseline') != selected:
                raise host.RunnerError('The verified baseline changed during admission; retry the upgrade')
            identifier = 'macos-upgrade-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]
            directory = host.private_directory(transaction_path(host, state, identifier))
            baseline = host.read_json(state / 'baseline.json')
            result = {'version': 1, 'upgradeID': identifier, 'target': report['target'], 'status': 'starting', 'phase': 'cloning',
                      'repository': str(host.ROOT), 'stateDirectory': str(state), 'stagingDirectory': str(directory / 'state'),
                      'sourceVM': str(args.vm), 'xcodePath': str(args.xcode), 'environment': baseline['environment'],
                      'systemDiskBytes': report.get('systemDiskBytes'),
                      'sourceBaseline': selected,
                      'vmId': baseline['vmId'], 'interactive': bool(args.interactive), 'timeout': args.timeout,
                      'steps': [], 'fullSuiteVerified': False, 'startedAt': now()}
        result.update({'updatedAt': now(), 'launchToken': uuid.uuid4().hex})
        host.atomic_json(directory / 'result.json', result)
        host.atomic_json(state / 'macos-upgrade-active.json', {'version': 1, 'upgradeID': result['upgradeID']})
        host.atomic_json(state / 'latest-macos-upgrade.json', {'version': 1, 'result': str(directory / 'result.json')})
        with open(directory / 'supervisor.log', 'ab', buffering=0) as log:
            os.chmod(directory / 'supervisor.log', 0o600)
            process = subprocess.Popen([sys.executable, '-B', str(Path(__file__).resolve()), '--worker', str(state),
                                        '--upgrade-id', result['upgradeID'], '--launch-token', result['launchToken']],
                                       stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True, close_fds=True)
        result['supervisor'] = {'pid': process.pid, 'start': process_start(process.pid)}
        host.atomic_json(directory / 'result.json', result)
    print(f'macOS upgrade: {result["upgradeID"]}\nResults: {directory / "result.json"}\nLog: {directory / "supervisor.log"}', flush=True)
    return wait_for_worker(host, state, result['upgradeID'], process)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--worker', required=True, type=Path)
    parser.add_argument('--upgrade-id', required=True)
    parser.add_argument('--launch-token', required=True)
    options = parser.parse_args()
    sys.exit(worker(options.worker, options.upgrade_id, options.launch_token))
