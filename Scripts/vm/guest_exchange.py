import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time


_spec = importlib.util.spec_from_file_location('big_wallet_exchange_access', Path(__file__).with_name('guest_access.py'))
access = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(access)

GUEST_EXCHANGE = '/Volumes/BigWalletBuild/Exchange'
MAX_INPUT_BYTES = 2 * 1024 ** 3
MAX_INPUT_FILES = 150000
MAX_EXPORT_BYTES = 64 * 1024 ** 3
MAX_EXPORT_FILES = 500000
MAX_REPORT_BYTES = 16 * 1024 ** 2
FREE_RESERVE_BYTES = 1024 ** 3
TERMINAL_STATUSES = ('passed', 'failed', 'blocked', 'cancelled')
REPORT_RETRY_DELAYS = (5, 10)
REPORT_OUTAGE_SECONDS = 60
MAX_RECORDED_REPORT_OUTAGES = 16


class GuestExchangeError(RuntimeError):
    pass


def _json(path, maximum=MAX_REPORT_BYTES):
    data, _ = access._read(path, maximum=maximum)
    try:
        value = json.loads(data)
    except (UnicodeError, ValueError):
        raise GuestExchangeError('The exchange JSON is invalid') from None
    if not isinstance(value, dict):
        raise GuestExchangeError('The exchange JSON must be an object')
    return value


def _report(value, run_id, vm_id, *, final=False):
    if (not isinstance(value, dict) or value.get('runId') != run_id or value.get('vmId') != vm_id or
            value.get('status') not in ('running', *TERMINAL_STATUSES)):
        raise GuestExchangeError('The guest report does not match the current job')
    if final and (not value.get('finishedAt') or value['status'] not in TERMINAL_STATUSES):
        raise GuestExchangeError('The exported guest report is not complete')
    return value


def _process_start(value):
    return (isinstance(value, list) and len(value) == 2 and
            all(type(part) is int for part in value) and 0 < value[0] <= 9007199254740991 and 0 <= value[1] < 1000000)


def _receipt(value, run_id, vm_id):
    if value is None:
        return None
    def pid(value):
        return type(value) is int and 1 < value <= 2147483647
    if (not isinstance(value, dict) or type(value.get('version')) is not int or value['version'] != 1 or
            value.get('runId') != run_id or value.get('vmId') != vm_id or not pid(value.get('agentPID')) or
            not _process_start(value.get('agentStart'))):
        raise GuestExchangeError('The guest receipt does not match the current job')
    state = value.get('state')
    fields = {'version', 'runId', 'vmId', 'agentPID', 'agentStart', 'state'}
    if state == 'running' and pid(value.get('runnerPID')) and _process_start(value.get('runnerStart')):
        fields.update(('runnerPID', 'runnerStart'))
    elif state == 'completed' and type(value.get('exitCode')) is int and 0 <= value['exitCode'] <= 255:
        fields.add('exitCode')
    elif (state == 'failed' and value.get('reason') == 'guest_launch_failed' and
          isinstance(value.get('error'), str) and len(value['error']) <= 4096):
        fields.update(('reason', 'error'))
    elif state != 'claimed':
        raise GuestExchangeError('The guest receipt state is invalid')
    if set(value) != fields:
        raise GuestExchangeError('The guest receipt fields are invalid')
    return value


def _atomic_json(path, value):
    path = Path(path)
    if path.parent.resolve() != path.parent or path.is_symlink():
        raise GuestExchangeError('The host report path must not traverse symlinks')
    descriptor, name = tempfile.mkstemp(prefix='.guest-report-', dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, 'w') as file:
            json.dump(value, file)
            file.write('\n')
            file.flush()
            os.fsync(file.fileno())
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def _capacity(directory, needed):
    if needed < 0 or shutil.disk_usage(directory).free - FREE_RESERVE_BYTES < needed:
        raise GuestExchangeError('Insufficient host capacity for the guest exchange')


def safari_credential_job_digest(job, exchange):
    payload = job.get('payload')
    if (job.get('kind') != 'run' or not isinstance(payload, dict) or payload.get('signing', 'local') != 'local' or
            not isinstance(payload.get('stages'), list) or not isinstance(payload.get('onlyTesting'), list) or
            payload['stages'] and 'safari' not in payload['stages']):
        return None
    plan = _json(exchange / 'artifacts/planned-result.json')
    job_data, _ = access._read(exchange / 'job.json', maximum=65536)
    snapshot_data, _ = access._read(exchange / 'snapshot-manifest.json', maximum=MAX_REPORT_BYTES)
    digest = hashlib.sha256(job_data).hexdigest()
    if (json.loads(job_data) != job or plan.get('version') != 1 or plan.get('origin') != 'host-plan' or
            plan.get('status') != 'planned' or plan.get('runId') != job.get('runId') or plan.get('vmId') != job.get('vmId') or
            plan.get('profile') != job.get('profile') or plan.get('source') != job.get('source') or
            plan.get('jobSHA256') != digest or not isinstance(job.get('source'), dict) or
            job['source'].get('sha256') != hashlib.sha256(snapshot_data).hexdigest() or
            not isinstance(plan.get('stages'), list)):
        raise GuestExchangeError('Safari guest credential selection does not match the captured job plan')
    selected = False
    preparation = payload.get('prepareSafari', False)
    if type(preparation) is not bool:
        raise GuestExchangeError('Invalid Safari guest credential preparation mode')
    if preparation:
        if (job.get('profile') != 'all' or payload['stages'] != ['safari'] or
                payload['onlyTesting'] != ['Safari UI Tests macOS'] or
                payload.get('configuration') != 'Debug' or payload.get('signing') != 'local' or
                payload.get('interactiveSafari') or 'preparedSafari' in payload or payload.get('approvalArgs')):
            raise GuestExchangeError('Safari guest credential preparation is not an explicit local Debug setup')
        expected = ['provider.install', 'protocol.check', 'build-safari.macos.debug', 'prepare-safari.macos.debug']
        if [stage.get('id') if isinstance(stage, dict) else None for stage in plan['stages']] != expected:
            raise GuestExchangeError('Safari guest credential preparation does not match the captured preparation stages')
    for stage in plan['stages']:
        if isinstance(stage, dict) and stage.get('preparationResult'):
            if (not preparation or stage.get('id') != 'prepare-safari.macos.debug' or
                    stage.get('preparationResult') is not True or stage.get('group') != 'safari' or
                    stage.get('status') != 'pending' or 'nativeAudit' in stage):
                raise GuestExchangeError('Safari guest credential selection is not an explicit preparation stage')
            selected = True
            continue
        audit = stage.get('nativeAudit') if isinstance(stage, dict) else None
        if not isinstance(audit, dict) or audit.get('kind') != 'safari' or audit.get('platform') != 'macos':
            continue
        if (preparation or stage.get('group') != 'safari' or stage.get('status') != 'pending' or audit.get('signing') != 'local' or
                audit.get('configuration') not in ('Debug', 'Release') or
                stage.get('id') not in (f'safari.macos.{audit["configuration"].lower()}',
                                        'safari.soak-macos.release' if audit['configuration'] == 'Release' else '')):
            raise GuestExchangeError('Safari guest credential selection is not a local macOS runtime stage')
        selected = True
    if preparation and not selected:
        raise GuestExchangeError('Safari guest credential preparation is missing its explicit preparation marker')
    return digest if selected else None


def build_input_archive(exchange, destination):
    exchange = access._private_directory(exchange)
    paths = []
    total = 0
    for name in ('source', 'snapshot-manifest.json', 'inputs', 'job.json'):
        root = exchange / name
        if not root.exists() and not root.is_symlink():
            if name == 'inputs':
                continue
            raise GuestExchangeError('The exchange is missing a required job input')
        if name in ('source', 'inputs') and (root.is_symlink() or not root.is_dir()):
            raise GuestExchangeError('Exchange input directories must be real directories')
        pending = [root]
        while pending:
            path = pending.pop()
            metadata = path.lstat()
            if metadata.st_uid != os.getuid():
                raise GuestExchangeError('Exchange inputs must be owned by the current user')
            relative = path.relative_to(exchange).as_posix()
            if stat.S_ISDIR(metadata.st_mode):
                pending.extend(sorted(path.iterdir(), reverse=True))
            elif stat.S_ISREG(metadata.st_mode):
                total += metadata.st_size
            elif stat.S_ISLNK(metadata.st_mode) and name == 'source':
                target = os.readlink(path)
                if os.path.isabs(target) or not path.resolve().is_relative_to(root):
                    raise GuestExchangeError('A source symlink leaves the snapshot')
            else:
                raise GuestExchangeError('Unsupported exchange input file type')
            paths.append((path, relative, metadata))
            if len(paths) > MAX_INPUT_FILES or total > MAX_INPUT_BYTES:
                raise GuestExchangeError('The exchange input exceeds its file or size limit')
    _capacity(Path(destination).parent, total + len(paths) * 2048 + 10240)
    with tarfile.open(destination, 'w', format=tarfile.PAX_FORMAT) as archive:
        for path, relative, metadata in paths:
            if path.parent.resolve() != path.parent:
                raise GuestExchangeError('An exchange input parent changed into a symlink')
            current = path.lstat()
            if (current.st_ino, current.st_size, current.st_mtime_ns, current.st_mode) != (
                    metadata.st_ino, metadata.st_size, metadata.st_mtime_ns, metadata.st_mode):
                raise GuestExchangeError('An exchange input changed during packaging')
            entry = tarfile.TarInfo(relative)
            entry.mode = 0o700 if stat.S_ISDIR(metadata.st_mode) else 0o755 if metadata.st_mode & 0o111 else 0o600
            if stat.S_ISDIR(metadata.st_mode):
                entry.type = tarfile.DIRTYPE
                archive.addfile(entry)
            elif stat.S_ISLNK(metadata.st_mode):
                entry.type = tarfile.SYMTYPE
                entry.linkname = os.readlink(path)
                archive.addfile(entry)
            else:
                descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
                with os.fdopen(descriptor, 'rb') as file:
                    before = os.fstat(file.fileno())
                    if (before.st_ino, before.st_size, before.st_mtime_ns) != (
                            metadata.st_ino, metadata.st_size, metadata.st_mtime_ns):
                        raise GuestExchangeError('An exchange input changed before packaging')
                    entry.size = before.st_size
                    archive.addfile(entry, file)
                    after = os.fstat(file.fileno())
                    if (after.st_size, after.st_mtime_ns) != (before.st_size, before.st_mtime_ns):
                        raise GuestExchangeError('An exchange input changed during packaging')


def extract_export(archive_path, destination, run_id, vm_id):
    destination = access._private_directory(destination)
    if any(destination.iterdir()):
        raise GuestExchangeError('Guest artifacts require an empty private extraction directory')
    with open(archive_path, 'rb') as file:
        size = file.seek(0, os.SEEK_END)
        if size < 1024 or size % 512:
            raise GuestExchangeError('The guest artifact archive is truncated')
        file.seek(-1024, os.SEEK_END)
        if file.read() != bytes(1024):
            raise GuestExchangeError('The guest artifact archive is missing its completion trailer')
    members = []
    names = {}
    total = 0
    try:
        with tarfile.open(archive_path, 'r:') as archive:
            for member in archive:
                name = member.name.removesuffix('/')
                parts = PurePosixPath(name).parts
                if (not name or name.startswith('/') or any(part in ('', '.', '..') for part in name.split('/')) or
                        parts[0] not in ('artifacts', 'guest-runner.log') or
                        parts[0] == 'guest-runner.log' and (len(parts) != 1 or not member.isfile()) or
                        name in names or member.sparse is not None or not (member.isfile() or member.isdir()) or
                        member.isfile() and member.name.endswith('/')):
                    raise GuestExchangeError('The guest artifact archive contains an unsafe path or file type')
                if name == 'artifacts' and not member.isdir():
                    raise GuestExchangeError('The guest artifacts root must be a directory')
                if name in ('artifacts/planned-result.json', 'artifacts/provisioning.log'):
                    raise GuestExchangeError('Guest artifacts may not replace host planning or provisioning records')
                total += member.size
                if member.size < 0 or total > MAX_EXPORT_BYTES or len(members) >= MAX_EXPORT_FILES:
                    raise GuestExchangeError('The guest artifacts exceed the file or size limit')
                names[name] = member
                members.append(member)
            for name in names:
                for parent in PurePosixPath(name).parents:
                    if str(parent) in names and not names[str(parent)].isdir():
                        raise GuestExchangeError('A guest artifact parent is not a directory')
            if 'artifacts/result.json' not in names or not names['artifacts/result.json'].isfile():
                raise GuestExchangeError('The guest artifact archive is missing its result')
            _capacity(destination, total)
            for member in members:
                target = destination / member.name
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                if member.isdir():
                    target.mkdir(exist_ok=True, mode=0o700)
                else:
                    with archive.extractfile(member) as source, open(target, 'xb') as output:
                        shutil.copyfileobj(source, output, 1024 * 1024)
                    target.chmod(0o600)
                    if target.stat().st_size != member.size:
                        raise GuestExchangeError('A guest artifact was truncated')
    except (tarfile.TarError, EOFError):
        raise GuestExchangeError('The guest artifact archive is invalid or truncated') from None
    value = _report(_json(destination / 'artifacts/result.json'), run_id, vm_id, final=True)
    _atomic_json(destination / 'validated-result.json', value)


_READY = r'''
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const root = '/Volumes/BigWalletBuild';
const exchange = root + '/Exchange';
const identityDirectory = '/Library/Application Support/BigWalletTestVM';
const protectedOwner = 0;
const uid = process.getuid();
const runId = process.argv[1];
const vmId = process.argv[2];
const consoleUser = process.argv[5];
const fail = message => { throw new Error(message); };
if (!uid || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(runId || '') ||
    !/^[A-Za-z0-9_-]{1,128}$/.test(vmId || '') || !/^[A-Za-z0-9_-]{1,64}$/.test(consoleUser || '') ||
    require('node:os').userInfo().username !== consoleUser) fail('Invalid guest readiness identity');
const directoryReady = (directory, owner, mask, exactMode) => {
    const metadata = fs.lstatSync(directory, {throwIfNoEntry: false});
    if (!metadata) return false;
    if (!metadata.isDirectory() || metadata.isSymbolicLink() || fs.realpathSync(directory) !== directory ||
        metadata.uid !== owner || metadata.mode & mask ||
        exactMode !== undefined && ((metadata.mode & 0o7777) !== exactMode || metadata.gid !== process.getgid()))
        fail('Guest readiness directory ownership or permissions are invalid');
    return true;
};
const protectedJSON = filename => {
    let descriptor;
    try { descriptor = fs.openSync(filename, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK); }
    catch (error) { if (error.code === 'ENOENT') return null; throw error; }
    try {
        const metadata = fs.fstatSync(descriptor);
        if (!metadata.isFile() || metadata.uid !== protectedOwner || metadata.mode & 0o022 ||
            metadata.size < 1 || metadata.size > 4096) fail('Guest readiness identity is not protected');
        const bytes = Buffer.alloc(4097);
        let length = 0;
        while (length < bytes.length) {
            const count = fs.readSync(descriptor, bytes, length, bytes.length - length, length);
            if (!count) break;
            length += count;
        }
        const after = fs.fstatSync(descriptor);
        if (length !== metadata.size || after.size !== metadata.size || after.mtimeMs !== metadata.mtimeMs ||
            after.ctimeMs !== metadata.ctimeMs) fail('Guest readiness identity changed during reading');
        const value = JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(bytes.subarray(0, length)));
        if (!value || typeof value !== 'object' || Array.isArray(value)) fail('Guest readiness identity must be an object');
        return value;
    } finally { fs.closeSync(descriptor); }
};
if (!directoryReady(identityDirectory, protectedOwner, 0o022)) fail('The provisioned guest identity is missing');
const identity = protectedJSON(path.join(identityDirectory, 'identity.json'));
if (identity?.version !== 1 || identity.vmId !== vmId || identity.consoleUser !== consoleUser)
    fail('The provisioned guest identity does not match this VM and account');
const ready = () => {
    if (!directoryReady(root, protectedOwner, 0o022)) return false;
    const mount = cp.spawnSync('/sbin/mount', [], {encoding: 'utf8', timeout: 5000, maxBuffer: 1024 * 1024, killSignal: 'SIGKILL'});
    if (mount.status !== 0 || mount.error || mount.signal) fail('Guest build mount inspection failed');
    const matches = mount.stdout.split('\n').map(line => /^(\S+) on (.+) \(([^)]+)\)$/.exec(line))
        .filter(value => value?.[2] === root);
    if (!matches.length) return false;
    if (matches.length !== 1 || !/^\/dev\/disk[0-9]+s[0-9]+$/.test(matches[0][1]) ||
        matches[0][3].split(', ')[0] !== 'apfs' || !matches[0][3].split(', ').includes('local'))
        fail('The guest build volume is not a direct local APFS mount');
    const buildIdentity = protectedJSON(path.join(root, '.big-wallet-vm.json'));
    if (!buildIdentity) return false;
    if (buildIdentity.version !== 1 || buildIdentity.vmId !== vmId ||
        typeof buildIdentity.volumeUUID !== 'string' || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(buildIdentity.volumeUUID))
        fail('The guest build volume identity does not match this VM');
    return directoryReady(exchange, uid, 0o077, 0o700);
};
const deadline = performance.now() + 120000;
while (!ready()) {
    if (performance.now() >= deadline) fail('The managed guest build volume and private exchange did not become ready within 120 seconds');
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, Math.min(500, Math.max(0, deadline - performance.now())));
}
process.stdout.write(JSON.stringify({version: 1, runId, vmId, ready: true}) + '\n');
'''

_REMOTE_PREAMBLE = r'''
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const tarEnvironment = {...process.env, COPYFILE_DISABLE: '1'};
const root = '/Volumes/BigWalletBuild';
const exchange = root + '/Exchange';
const fail = message => { throw new Error(message); };
const uid = process.getuid();
if (!uid) fail('Guest exchange requires the selected user');
for (const [directory, owner, mask] of [[root, 0, 0o022], [exchange, uid, 0o077]]) {
    const metadata = fs.lstatSync(directory);
    if (!metadata.isDirectory() || fs.realpathSync(directory) !== directory || metadata.uid !== owner || metadata.mode & mask)
        fail('Guest exchange directory ownership or permissions are invalid');
}
const readJSON = filename => {
    const descriptor = fs.openSync(filename, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    try {
        const metadata = fs.fstatSync(descriptor);
        if (!metadata.isFile() || metadata.size > 16 * 1024 * 1024) fail('Invalid guest exchange JSON');
        return JSON.parse(fs.readFileSync(descriptor, 'utf8'));
    } finally { fs.closeSync(descriptor); }
};
const runId = process.argv[1];
if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(runId)) fail('Invalid exchange job identity');
const vmId = process.argv[2];
const validPID = value => Number.isSafeInteger(value) && value > 1 && value <= 2147483647;
const validStart = value => Array.isArray(value) && value.length === 2 &&
    value.every(Number.isSafeInteger) && value[0] > 0 && value[1] >= 0 && value[1] < 1000000;
const processStart = pid => {
    if (!validPID(pid)) fail('Invalid guest supervisor identity');
    const result = cp.spawnSync('/usr/local/libexec/big-wallet-vm/VMGuestAgent', ['--process-identity', String(pid)],
        {encoding: 'utf8', timeout: 5000, killSignal: 'SIGKILL'});
    if (result.status !== 0) fail('Cannot inspect guest process identity');
    const value = JSON.parse(result.stdout);
    if (value !== null && !validStart(value)) fail('Invalid guest process start identity');
    return value;
};
const alive = (pid, start) => {
    if (!validStart(start)) fail('Invalid recorded process identity');
    const current = processStart(pid);
    return current !== null && current[0] === start[0] && current[1] === start[1];
};
const receiptDirectory = path.join(exchange, '.agent-runs');
const receiptNames = () => {
    try {
        const metadata = fs.lstatSync(receiptDirectory);
        if (!metadata.isDirectory() || metadata.uid !== uid || metadata.mode & 0o077)
            fail('Invalid guest receipt directory');
        return fs.readdirSync(receiptDirectory).filter(name => name.endsWith('.json'));
    } catch (error) { if (error.code === 'ENOENT') return []; throw error; }
};
const readReceipt = id => {
    if (!receiptNames().includes(id + '.json')) return null;
    const value = readJSON(path.join(receiptDirectory, id + '.json'));
    if (value.version !== 1 || value.runId !== id || value.vmId !== vmId || !validPID(value.agentPID) || !validStart(value.agentStart))
        fail('Invalid guest receipt identity');
    return value;
};
const stopMarker = path.join(exchange, '.stop-' + runId);
const publishStop = () => {
    const temporary = path.join(exchange, '.stop-' + runId + '.' + process.pid + '.json');
    const descriptor = fs.openSync(temporary, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
    try { fs.writeFileSync(descriptor, JSON.stringify({runId})); }
    finally { fs.closeSync(descriptor); }
    fs.renameSync(temporary, path.join(exchange, 'stop.json'));
};
const safariCredentialPath = path.join(exchange, runId, 'safari', 'guest-credential.json');
const removeSafariCredential = () => {
    for (const directory of [path.join(exchange, runId), path.dirname(safariCredentialPath)]) {
        let metadata;
        try { metadata = fs.lstatSync(directory); }
        catch (error) { if (error.code === 'ENOENT') return; throw error; }
        if (!metadata.isDirectory() || metadata.isSymbolicLink() || metadata.uid !== uid || metadata.mode & 0o077 ||
            fs.realpathSync(directory) !== directory) fail('Invalid Safari credential directory');
    }
    const directory = path.dirname(safariCredentialPath);
    let invalid = false;
    for (const name of fs.readdirSync(directory)) {
        if (name !== 'guest-credential.json' && !/^\.guest-credential\.[1-9][0-9]{0,9}\.tmp$/.test(name)) continue;
        const filename = path.join(directory, name);
        let metadata;
        try { metadata = fs.lstatSync(filename); }
        catch (error) { if (error.code === 'ENOENT') continue; throw error; }
        if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.uid !== uid || (metadata.mode & 0o7777) !== 0o600) { invalid = true; continue; }
        try { fs.unlinkSync(filename); }
        catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
    if (invalid) fail('Invalid Safari credential file');
};
'''

_UPLOAD = _REMOTE_PREAMBLE + r'''
if (readReceipt(runId)) fail('This job was already claimed; refusing to replace it');
for (const name of receiptNames()) {
    const value = readReceipt(name.slice(0, -5));
    if (['claimed', 'running'].includes(value.state) &&
        (alive(value.agentPID, value.agentStart) || value.runnerPID !== undefined && alive(value.runnerPID, value.runnerStart)))
        fail('A guest job is still running; refusing to replace its exchange');
}
fs.rmSync(path.join(exchange, 'job.json'), {force: true});
const incoming = fs.mkdtempSync(path.join(exchange, '.upload-'));
try {
    const unpack = cp.spawnSync('/usr/bin/tar', ['-xf', '-', '-C', incoming, '--no-same-owner'],
        {stdio: ['inherit', 'inherit', 'inherit'], env: tarEnvironment, timeout: 900000, killSignal: 'SIGKILL'});
    if (unpack.status !== 0) fail('Guest exchange input transfer failed');
    const job = readJSON(path.join(incoming, 'job.json'));
    if (job.runId !== runId || job.vmId !== process.argv[2]) fail('Guest exchange job identity changed');
    for (const name of ['source', 'snapshot-manifest.json', 'inputs', 'stop.json', 'artifacts', 'guest-runner.log'])
        fs.rmSync(path.join(exchange, name), {recursive: true, force: true});
    for (const name of ['source', 'snapshot-manifest.json', 'inputs']) {
        const input = path.join(incoming, name);
        if (fs.existsSync(input)) fs.renameSync(input, path.join(exchange, name));
    }
    if (fs.existsSync(stopMarker)) { publishStop(); process.exitCode = 86; }
    else {
        fs.renameSync(path.join(incoming, 'job.json'), path.join(exchange, 'job.json'));
        if (fs.existsSync(stopMarker)) publishStop();
    }
} finally { fs.rmSync(incoming, {recursive: true, force: true}); }
'''

_SAFARI_CREDENTIAL = _REMOTE_PREAMBLE + r'''
const expectedDigest = process.argv[5];
const consoleUser = process.argv[6];
if (!/^[a-f0-9]{64}$/.test(expectedDigest || '') || !/^[A-Za-z0-9_-]{1,64}$/.test(consoleUser || '') ||
    require('node:os').userInfo().username !== consoleUser || runId.includes('..')) fail('Invalid Safari credential identity');
const descriptor = fs.openSync(path.join(exchange, 'job.json'), fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
let jobBytes;
try {
    const metadata = fs.fstatSync(descriptor);
    if (!metadata.isFile() || metadata.size > 65536) fail('Invalid Safari credential job');
    jobBytes = fs.readFileSync(descriptor);
} finally { fs.closeSync(descriptor); }
if (require('node:crypto').createHash('sha256').update(jobBytes).digest('hex') !== expectedDigest) fail('Safari credential job changed after selection');
const job = JSON.parse(jobBytes);
if (job.runId !== runId || job.vmId !== vmId || job.kind !== 'run' || !job.payload ||
    (job.payload.signing || 'local') !== 'local' || !Array.isArray(job.payload.stages) ||
    (job.payload.stages.length && !job.payload.stages.includes('safari')) || readReceipt(runId)) fail('Safari credential requires an unclaimed local test run');
if (fs.existsSync(stopMarker)) { publishStop(); process.exit(86); }
const verified = cp.spawnSync('/usr/local/libexec/big-wallet-vm/guest_runner', ['--verify-session'],
    {stdio: 'ignore', env: {...process.env, BW_TEST_VM_RUN_ID: runId, BW_TEST_VM_EXCHANGE: exchange}, timeout: 30000, killSignal: 'SIGKILL'});
if (verified.status !== 0) fail('Safari credential requires a verified guest session');
const bytes = Buffer.alloc(4097);
let length = 0;
while (length < bytes.length) {
    const count = fs.readSync(0, bytes, length, bytes.length - length, null);
    if (!count) break;
    length += count;
}
if (!length || length > 4096 || bytes.subarray(0, length).some(byte => byte === 0 || byte === 10 || byte === 13)) fail('Invalid Safari guest credential');
let password;
try { password = new TextDecoder('utf-8', {fatal: true}).decode(bytes.subarray(0, length)); }
catch { fail('Invalid Safari guest credential encoding'); }
const value = Buffer.from(JSON.stringify({version: 1, runID: runId, consoleUser, password}));
if (value.length > 4096) fail('Safari guest credential exceeds its private-file budget');
for (const directory of [path.join(exchange, runId), path.dirname(safariCredentialPath)]) {
    try { fs.mkdirSync(directory, {mode: 0o700}); } catch (error) { if (error.code !== 'EEXIST') throw error; }
    const metadata = fs.lstatSync(directory);
    if (!metadata.isDirectory() || metadata.isSymbolicLink() || metadata.uid !== uid || metadata.mode & 0o077 ||
        fs.realpathSync(directory) !== directory) fail('Invalid Safari credential directory');
}
const temporary = path.join(path.dirname(safariCredentialPath), '.guest-credential.' + process.pid + '.tmp');
let file;
try {
    file = fs.openSync(temporary, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
    fs.writeFileSync(file, value);
    fs.fsyncSync(file);
    fs.closeSync(file); file = undefined;
    fs.linkSync(temporary, safariCredentialPath);
} finally {
    if (file !== undefined) fs.closeSync(file);
    try { fs.unlinkSync(temporary); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    bytes.fill(0); value.fill(0); password = undefined;
}
if (fs.existsSync(stopMarker)) { removeSafariCredential(); publishStop(); process.exit(86); }
'''

_LAUNCH = _REMOTE_PREAMBLE + r'''
const job = readJSON(path.join(exchange, 'job.json'));
if (job.runId !== runId || job.vmId !== vmId) fail('Guest launch job identity changed');
const existing = readReceipt(runId);
if (existing) {
    process.stdout.write(JSON.stringify({version: 1, runId, vmId, agentPID: existing.agentPID, agentStart: existing.agentStart}) + '\n');
} else {
    const service = `gui/${uid}/org.lil.big-wallet.vm-guest`;
    const deadline = Date.now() + 120000;
    while (true) {
        if (fs.existsSync(stopMarker)) { publishStop(); process.exit(86); }
        const loaded = cp.spawnSync('/bin/launchctl', ['print', service],
            {stdio: 'ignore', timeout: 1000, killSignal: 'SIGKILL'});
        if (loaded.status === 0) break;
        if (Date.now() >= deadline) fail('The guest Aqua service did not become available');
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 2000);
    }
    if (fs.existsSync(stopMarker)) { publishStop(); process.exit(86); }
    const launched = cp.spawnSync('/bin/launchctl', ['kickstart', '-p', service],
        {encoding: 'utf8', timeout: 10000, killSignal: 'SIGKILL'});
    const agentPID = Number(launched.stdout?.trim());
    if (launched.status !== 0 || !validPID(agentPID)) fail('The guest Aqua supervisor could not be launched');
    const agentStart = readReceipt(runId)?.agentStart ?? processStart(agentPID);
    process.stdout.write(JSON.stringify({version: 1, runId, vmId, agentPID, agentStart}) + '\n');
}
'''

_POLL = _REMOTE_PREAMBLE + r'''
const filename = path.join(exchange, 'artifacts/result.json');
const report = fs.existsSync(filename) ? readJSON(filename) : null;
if (report && (report.runId !== runId || report.vmId !== vmId)) fail('Guest report belongs to another run');
const receipt = readReceipt(runId);
const expectedPID = process.argv[3] ? Number(process.argv[3]) : null;
if (expectedPID !== null && !validPID(expectedPID)) fail('Invalid expected supervisor PID');
if (receipt && expectedPID !== null && receipt.agentPID !== expectedPID) fail('Guest supervisor identity changed');
const expectedStart = process.argv[4] ? JSON.parse(process.argv[4]) : null;
if (expectedStart !== null && !validStart(expectedStart)) fail('Invalid expected supervisor start');
if (receipt && expectedStart !== null && JSON.stringify(receipt.agentStart) !== JSON.stringify(expectedStart))
    fail('Guest supervisor start identity changed');
const agentPID = receipt?.agentPID ?? expectedPID;
const agentStart = receipt?.agentStart ?? expectedStart;
process.stdout.write(JSON.stringify({version: 1, runId, vmId, receipt, report,
    supervisorAlive: report?.finishedAt || agentPID === null || agentStart === null ? null : alive(agentPID, agentStart)}) + '\n');
'''

_EXPORT = _REMOTE_PREAMBLE + r'''
const value = readJSON(path.join(exchange, 'artifacts/result.json'));
if (value.runId !== runId || !value.finishedAt || !['passed', 'failed', 'blocked', 'cancelled'].includes(value.status))
    fail('Guest report is not complete');
removeSafariCredential();
const names = ['artifacts'];
if (fs.existsSync(path.join(exchange, 'guest-runner.log'))) names.push('guest-runner.log');
const result = cp.spawnSync('/usr/bin/tar', ['-cf', '-', '-C', exchange, ...names],
    {stdio: ['ignore', 'inherit', 'inherit'], env: tarEnvironment, timeout: 1800000, killSignal: 'SIGKILL'});
if (result.status !== 0) fail('Guest artifact export failed');
'''

_STOP = _REMOTE_PREAMBLE + r'''
const descriptor = fs.openSync(stopMarker, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_NOFOLLOW, 0o600);
fs.closeSync(descriptor);
publishStop();
removeSafariCredential();
'''


class GuestExchange:
    def __init__(self, address, user, password_file, known_hosts, host_key_alias, private_workdir, exchange):
        self.child = self.stop_child = None
        self.result = None
        self.files = []
        self.askpass = None
        self.scratch = None
        self.export_directory = None
        self.password = b''
        self.stop_requested = False
        self.stop_sent = False
        self.next_poll = 0
        self.guest_finished_at = None
        self.launched_at = None
        self.observed_launch = False
        self.agent_pid = None
        self.agent_start = None
        self.final_seen = False
        self.report_outage = None
        self.report_retry_info = None
        self.report_journal_failed = False
        try:
            self.work = access._private_directory(private_workdir)
            self.exchange = access._private_directory(exchange)
            self.job = _json(self.exchange / 'job.json', 65536)
            self.safari_credential_digest = safari_credential_job_digest(self.job, self.exchange)
            self.console_user = user
            self.run_id = self.job.get('runId')
            self.vm_id = self.job.get('vmId')
            if (not isinstance(self.run_id, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', self.run_id) or
                    not isinstance(self.vm_id, str) or 'big-wallet-vm-' + self.vm_id != host_key_alias):
                raise GuestExchangeError('The exchange job identity is invalid')
            self.command = access.ssh_command(address, user, known_hosts, host_key_alias)
            self.address = access._address(address)
            self.password = access.read_private_password(password_file)
            self.scratch = Path(tempfile.mkdtemp(prefix='guest-exchange-', dir=self.work))
            self.input_archive = self.scratch / 'input.tar'
            self.output_archive = self.scratch / 'artifacts.tar'
            self.export_directory = Path(tempfile.mkdtemp(prefix='.guest-export-', dir=self.exchange))
            descriptor, name = tempfile.mkstemp(prefix='askpass-', dir=self.scratch)
            self.askpass = Path(name)
            with os.fdopen(descriptor, 'w') as file:
                file.write('#!/bin/sh\nexec ' + shlex.join([sys.executable, str(Path(access.__file__).resolve()),
                                                           '--askpass', str(Path(password_file).absolute())]) + '\n')
            self.askpass.chmod(0o700)
            self.environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(self.work), 'LANG': 'C',
                                'SSH_ASKPASS': str(self.askpass), 'SSH_ASKPASS_REQUIRE': 'force'}
            artifacts = self.exchange / 'artifacts'
            artifacts.mkdir(mode=0o700, exist_ok=True)
            access._private_directory(artifacts)
            self._start_local('pack', '--pack', self.exchange, self.input_archive, timeout=300)
        except BaseException as error:
            self.cancel()
            if isinstance(error, access.GuestAccessError):
                raise GuestExchangeError(str(error)) from None
            raise

    def _temporary_output(self):
        file = tempfile.TemporaryFile(dir=self.scratch)
        self.files.append(file)
        return file

    def _start_local(self, phase, *arguments, timeout):
        self.phase = phase
        self.output = self._temporary_output()
        self.errors = self._temporary_output()
        self.child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), *map(str, arguments)],
            stdin=subprocess.DEVNULL, stdout=self.output, stderr=self.errors, start_new_session=True)
        self.deadline = time.monotonic() + timeout

    def _start_remote(self, phase, script, *, timeout, input_path=None, input_file=None, output_path=None, extra_arguments=()):
        if input_path is not None and input_file is not None:
            raise GuestExchangeError('Guest transfer input is ambiguous')
        self.phase = phase
        self.output = open(output_path, 'wb') if output_path else self._temporary_output()
        if output_path:
            self.files.append(self.output)
        self.errors = self._temporary_output()
        command = self.command + [shlex.join(['/usr/local/bin/node', '-e', script, self.run_id, self.vm_id, str(self.agent_pid or ''), json.dumps(self.agent_start) if self.agent_start else '', *extra_arguments])]
        source = input_file if input_file is not None else open(input_path, 'rb') if input_path else subprocess.DEVNULL
        self.phase_started_at = time.monotonic()
        try:
            self.child = subprocess.Popen(command, stdin=source, stdout=self.output, stderr=self.errors,
                                          env=self.environment, start_new_session=True)
        finally:
            if input_path:
                source.close()
        self.deadline = self.phase_started_at + timeout
        if phase == 'report' and self.report_outage is not None:
            self.deadline = min(self.deadline, self.report_outage['deadline'])
            self.report_outage['event']['retryAttempts'] += 1
            self.report_retry_info['retryAttempts'] += 1
            self._write_report_retry_info()

    def _write_report_retry_info(self):
        if not self.report_journal_failed:
            try:
                _atomic_json(self.exchange / 'guest-transport.json', self.report_retry_info)
            except (OSError, RuntimeError):
                self.report_journal_failed = True
                raise

    def _complete_report_outage(self, status, reason=None):
        if self.report_outage is None:
            return
        event = self.report_outage['event']
        event.update(status=status, finishedAt=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                     elapsedSeconds=round(max(0, time.monotonic() - self.report_outage['started']), 3))
        if reason is not None:
            event['reason'] = reason
        if status == 'recovered':
            self.report_retry_info['recoveredOutages'] += 1
        self.report_outage = None
        self._write_report_retry_info()

    def _retry_report_failure(self, code, now):
        if (self.phase != 'report' or code != 255 or not self.observed_launch or self.stop_requested or
                self.output.seek(0, os.SEEK_END) != 0):
            return False
        expected = ('Connection timed out during banner exchange\r\n'
                    f'Connection to {self.address} port 22 timed out\r\n').encode('ascii')
        self.errors.seek(0)
        diagnostic = self.errors.read(len(expected) + 1)
        if diagnostic not in (expected, expected.replace(b'\r\n', b'\n')):
            return False
        if self.report_outage is None:
            if self.report_retry_info is None:
                self.report_retry_info = {'version': 1, 'runId': self.run_id, 'vmId': self.vm_id,
                    'outages': 0, 'retryAttempts': 0, 'recoveredOutages': 0, 'recentOutages': []}
            event = {'firstFailureAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                     'status': 'retrying', 'diagnostic': 'Connection timed out during banner exchange',
                     'failures': 0, 'retryAttempts': 0}
            self.report_retry_info['outages'] += 1
            self.report_retry_info['recentOutages'] = [*self.report_retry_info['recentOutages'], event][-MAX_RECORDED_REPORT_OUTAGES:]
            self.report_outage = {'started': self.phase_started_at,
                                 'deadline': self.phase_started_at + REPORT_OUTAGE_SECONDS, 'event': event}
        event = self.report_outage['event']
        event['failures'] += 1
        attempts = event['retryAttempts']
        if attempts >= len(REPORT_RETRY_DELAYS):
            self._complete_report_outage('failed', 'retry_limit')
            return False
        if now + REPORT_RETRY_DELAYS[attempts] >= self.report_outage['deadline']:
            self._complete_report_outage('failed', 'outage_deadline')
            return False
        event['lastRetryDelaySeconds'] = REPORT_RETRY_DELAYS[attempts]
        self.next_poll = now + REPORT_RETRY_DELAYS[attempts]
        self._write_report_retry_info()
        self._close_phase_files()
        return True

    def _start_safari_credential(self):
        credential = self._temporary_output()
        try:
            credential.write(self.password)
            credential.flush()
            credential.seek(0)
            self._start_remote('safari-credential', _SAFARI_CREDENTIAL, input_file=credential, timeout=45,
                               extra_arguments=(self.safari_credential_digest, self.console_user))
        finally:
            credential.close()
            self.files.remove(credential)

    def _start_stop(self):
        self.stop_errors = self._temporary_output()
        self.stop_child = subprocess.Popen(self.command + [shlex.join(['/usr/local/bin/node', '-e', _STOP, self.run_id])],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=self.stop_errors,
            env=self.environment, start_new_session=True)
        self.stop_deadline = time.monotonic() + 15

    def request_stop(self):
        self.stop_requested = True
        if self.phase in ('pack', 'ready'):
            return
        if self.password and self.stop_child is None and not self.stop_sent:
            self._start_stop()

    def _observation_failure(self, now):
        if self.final_seen:
            return None
        if self.guest_finished_at is not None and now - self.guest_finished_at >= 30:
            return 'guest_exited_without_result'
        if self.launched_at is not None and not self.observed_launch and now - self.launched_at >= 30:
            return 'guest_launch_failed'
        return None

    def _observe_launch(self, now, diagnostic=None):
        if diagnostic:
            _atomic_json(self.exchange / 'guest-launch.json', {'runId': self.run_id, 'error': diagnostic})
        self.launched_at = now
        self.next_poll = now

    def _observe_report(self, value, now):
        if (not isinstance(value, dict) or type(value.get('version')) is not int or value['version'] != 1 or
                value.get('runId') != self.run_id or value.get('vmId') != self.vm_id or
                set(value) != {'version', 'runId', 'vmId', 'receipt', 'report', 'supervisorAlive'} or
                value['supervisorAlive'] is not None and type(value['supervisorAlive']) is not bool):
            raise GuestExchangeError('Invalid guest observation envelope')
        receipt = _receipt(value['receipt'], self.run_id, self.vm_id)
        if receipt:
            if self.agent_pid is not None and receipt['agentPID'] != self.agent_pid:
                raise GuestExchangeError('Guest supervisor identity changed')
            if self.agent_start is not None and receipt['agentStart'] != self.agent_start:
                raise GuestExchangeError('Guest supervisor start identity changed')
            self.agent_pid = receipt['agentPID']
            self.agent_start = receipt['agentStart']
            _atomic_json(self.exchange / 'guest-receipt.json', receipt)
        report = value['report']
        if receipt is not None or report is not None:
            self.observed_launch = True
        if report is not None:
            _report(report, self.run_id, self.vm_id)
            if report.get('finishedAt'):
                _report(report, self.run_id, self.vm_id, final=True)
                self.final_seen = True
                self._start_remote('export', _EXPORT, output_path=self.output_archive, timeout=1800)
                return None
            _atomic_json(self.exchange / 'artifacts/result.json', report)
        if receipt and receipt['state'] == 'failed':
            return self._finish({'status': 'failed', 'reason': 'guest_launch_failed',
                'error': receipt['error'].encode().replace(self.password, b'[REDACTED]').decode()})
        if value['supervisorAlive'] is False or receipt and receipt['state'] == 'completed':
            if self.guest_finished_at is None:
                self.guest_finished_at = now
        return None

    def _error_text(self, file):
        file.seek(0, os.SEEK_END)
        file.seek(max(0, file.tell() - 4096))
        return file.read().replace(self.password, b'[REDACTED]').decode('utf8', errors='replace').strip()

    def _close_phase_files(self):
        for file in (self.output, self.errors):
            file.close()
            self.files.remove(file)

    def _finish(self, result):
        self.result = result
        if self.child is not None:
            access._stop(self.child)
            self.child.wait()
            self.child = None
        for file in list(self.files):
            if self.stop_child is None or file is not self.stop_errors:
                file.close()
                self.files.remove(file)
        shutil.rmtree(self.export_directory, ignore_errors=True)
        self.input_archive.unlink(missing_ok=True)
        self.output_archive.unlink(missing_ok=True)
        self._complete_report_outage('cancelled' if self.stop_requested else 'failed', result.get('reason'))
        return None if self.stop_child is not None else self.result

    def _publish_export(self):
        report = _report(_json(self.export_directory / 'validated-result.json'), self.run_id, self.vm_id, final=True)
        incoming = self.export_directory / 'artifacts'
        artifacts = access._private_directory(self.exchange / 'artifacts')
        if report.get('kind') == 'run' and report['status'] in ('failed', 'cancelled') and report.get('stages') == []:
            plan = _json(artifacts / 'planned-result.json')
            job_data, _ = access._read(self.exchange / 'job.json', maximum=65536)
            snapshot_data, _ = access._read(self.exchange / 'snapshot-manifest.json', maximum=MAX_REPORT_BYTES)
            source = self.job.get('source')
            if (not isinstance(source, dict) or self.job.get('kind') != 'run' or json.loads(job_data) != self.job or
                    plan.get('origin') != 'host-plan' or plan.get('status') != 'planned' or
                    plan.get('runId') != self.run_id or plan.get('vmId') != self.vm_id or plan.get('source') != source or
                    not isinstance(report.get('source'), dict) or any(report['source'].get(key) != value for key, value in source.items()) or
                    plan.get('jobSHA256') != hashlib.sha256(job_data).hexdigest() or
                    source.get('sha256') != hashlib.sha256(snapshot_data).hexdigest() or
                    not isinstance(plan.get('stages'), list) or not plan['stages'] or
                    any(not isinstance(stage, dict) or not isinstance(stage.get('id'), str) or stage.get('status') != 'pending'
                        for stage in plan['stages'])):
                raise GuestExchangeError('The planned inventory does not match the failed guest job and source snapshot')
            stage_status = 'cancelled' if report['status'] == 'cancelled' else 'blocked'
            report['stages'] = [{**stage, 'status': stage_status, 'reason': report.get('error', 'Guest bootstrap did not complete'),
                                 'finishedAt': report['finishedAt']} for stage in plan['stages']]
            report['plannedResult'] = 'planned-result.json'
            report.setdefault('summary', {}).update({'status': report['status'],
                'counts': {status: len(report['stages']) if status == stage_status else 0
                           for status in ('passed', 'failed', 'blocked', 'cancelled')}})
            report.setdefault('coverage', {}).update({'status': 'partial', 'fullSuiteVerified': False,
                'incompleteStages': [{'id': stage['id'], 'status': stage_status} for stage in report['stages']]})
        outputs = [(path, artifacts / path.name) for path in incoming.iterdir() if path.name != 'result.json']
        log = self.export_directory / 'guest-runner.log'
        if log.exists():
            outputs.append((log, self.exchange / 'guest-runner.log'))
        for _, destination in outputs:
            if destination.exists() or destination.is_symlink():
                raise GuestExchangeError('A guest artifact would replace an existing host artifact')
        for source, destination in outputs:
            source.replace(destination)
        _atomic_json(artifacts / 'result.json', report)

    def poll(self):
        try:
            now = time.monotonic()
            if self.stop_requested and self.phase in ('pack', 'ready'):
                return self._finish({'status': 'failed', 'reason': 'guest_exchange_cancelled', 'phase': self.phase})
            if self.stop_child is not None:
                code = self.stop_child.poll()
                if code is None and now > self.stop_deadline:
                    access._stop(self.stop_child)
                    code = self.stop_child.returncode
                if code is not None:
                    self.stop_child.wait()
                    self.stop_child = None
                    self.stop_sent = code == 0
                    if code != 0 and self.result is None:
                        return self._finish({'status': 'failed', 'reason': 'guest_stop_transfer_failed',
                                             'error': self._error_text(self.stop_errors)})
                    self.stop_errors.close()
                    self.files.remove(self.stop_errors)
            if self.result is not None:
                return None if self.stop_child is not None else self.result
            if self.report_outage is not None:
                if self.stop_requested:
                    if self.stop_child is not None:
                        return None
                    if self.child is not None:
                        access._stop(self.child)
                        self.child.wait()
                        self.child = None
                        self._close_phase_files()
                    self._complete_report_outage('cancelled', 'guest_stop_requested')
                    self.next_poll = now
                else:
                    if reason := self._observation_failure(now):
                        return self._finish({'status': 'failed', 'reason': reason})
                    if now >= self.report_outage['deadline']:
                        return self._finish({'status': 'failed', 'reason': 'guest_exchange_timeout', 'phase': 'report'})
            if self.child is None:
                if reason := self._observation_failure(now):
                    return self._finish({'status': 'failed', 'reason': reason})
                if now >= self.next_poll:
                    self._start_remote('report', _POLL, timeout=30)
                return None
            if self.phase == 'export':
                if self.output.tell() > MAX_EXPORT_BYTES + MAX_EXPORT_FILES * 2048:
                    raise GuestExchangeError('The guest artifact download exceeds its size limit')
                _capacity(self.work, 0)
            if self.phase in ('ready', 'launch', 'report') and self.output.tell() > MAX_REPORT_BYTES:
                raise GuestExchangeError('The guest report exceeds its size limit')
            if self.errors.tell() > MAX_REPORT_BYTES:
                raise GuestExchangeError('The guest exchange diagnostic output exceeds its size limit')
            code = self.child.poll()
            if code is None:
                if reason := self._observation_failure(now):
                    return self._finish({'status': 'failed', 'reason': reason})
                if now > self.deadline and self.phase == 'launch':
                    access._stop(self.child)
                    self.child.wait()
                    self.child = None
                    self._close_phase_files()
                    self._observe_launch(now, 'Guest launch acknowledgement timed out')
                    return None
                if now > self.deadline:
                    return self._finish({'status': 'failed', 'reason': 'guest_exchange_timeout', 'phase': self.phase})
                return None
            self.child.wait()
            self.child = None
            if code != 0 and self.phase == 'launch' and not self.stop_requested:
                diagnostic = self._error_text(self.errors)
                self._close_phase_files()
                self._observe_launch(now, diagnostic or 'Guest launch outcome is unknown')
                return None
            if code != 0:
                if self.phase == 'report' and not self.stop_requested:
                    if reason := self._observation_failure(now):
                        return self._finish({'status': 'failed', 'reason': reason})
                    if self._retry_report_failure(code, now):
                        return None
                return self._finish({'status': 'failed', 'reason': 'guest_exchange_cancelled' if self.stop_requested else 'guest_exchange_failed',
                                     'phase': self.phase, 'error': self._error_text(self.errors)})
            phase = self.phase
            data = None
            if phase in ('ready', 'launch', 'report'):
                self.output.seek(0)
                data = self.output.read(MAX_REPORT_BYTES + 1)
            self._close_phase_files()
            if phase == 'pack':
                if self.stop_requested:
                    return self._finish({'status': 'failed', 'reason': 'guest_exchange_cancelled'})
                self._start_remote('ready', _READY, timeout=130, extra_arguments=(self.console_user,))
            elif phase == 'ready':
                value = json.loads(data)
                if (value != {'version': 1, 'runId': self.run_id, 'vmId': self.vm_id, 'ready': True} or
                        type(value.get('version')) is not int or value['ready'] is not True):
                    raise GuestExchangeError('Invalid guest readiness acknowledgement')
                if self.stop_requested:
                    return self._finish({'status': 'failed', 'reason': 'guest_exchange_cancelled'})
                self._start_remote('upload', _UPLOAD, input_path=self.input_archive, timeout=900)
            elif phase == 'upload':
                self.input_archive.unlink(missing_ok=True)
                if self.stop_requested:
                    return self._finish({'status': 'failed', 'reason': 'guest_exchange_cancelled'})
                if self.safari_credential_digest:
                    self._start_safari_credential()
                else:
                    self._start_remote('launch', _LAUNCH, timeout=150)
            elif phase == 'safari-credential':
                if self.stop_requested:
                    return self._finish({'status': 'failed', 'reason': 'guest_exchange_cancelled'})
                self._start_remote('launch', _LAUNCH, timeout=150)
            elif phase == 'launch':
                value = json.loads(data)
                if (not isinstance(value, dict) or type(value.get('version')) is not int or value['version'] != 1 or
                        value.get('runId') != self.run_id or value.get('vmId') != self.vm_id or
                        type(value.get('agentPID')) is not int or not 1 < value['agentPID'] <= 2147483647 or
                        'agentStart' not in value or value['agentStart'] is not None and not _process_start(value['agentStart'])):
                    raise GuestExchangeError('Invalid guest launch acknowledgement')
                self.agent_pid = value['agentPID']
                self.agent_start = value['agentStart']
                self._observe_launch(now)
            elif phase == 'report':
                if len(data) > MAX_REPORT_BYTES:
                    raise GuestExchangeError('The guest report exceeds its size limit')
                result = self._observe_report(json.loads(data), now)
                if result is not None:
                    return result
                self._complete_report_outage('recovered')
                self.next_poll = now + 5
            elif phase == 'export':
                self._start_local('extract', '--extract', self.output_archive, self.export_directory,
                                  self.run_id, self.vm_id, timeout=900)
            elif phase == 'extract':
                self._publish_export()
                return self._finish({'status': 'passed', 'phase': 'exchange-complete'})
            return None
        except (OSError, ValueError, RuntimeError, access.GuestAccessError) as error:
            return self._finish({'status': 'failed', 'reason': 'guest_exchange_failed',
                                 'error': str(error).encode('utf8').replace(self.password, b'[REDACTED]').decode('utf8')})

    def cancel(self):
        if self.result is None:
            self.result = {'status': 'failed', 'reason': 'guest_exchange_cancelled'}
        for name in ('child', 'stop_child'):
            child = getattr(self, name, None)
            if child is not None:
                access._stop(child)
                child.wait()
                setattr(self, name, None)
        for file in self.files:
            file.close()
        self.files.clear()
        if self.export_directory is not None:
            shutil.rmtree(self.export_directory, ignore_errors=True)
        if self.scratch is not None:
            shutil.rmtree(self.scratch, ignore_errors=True)
        self.password = b''
        self._complete_report_outage('cancelled', 'guest_exchange_cancelled')


if __name__ == '__main__':
    try:
        if len(sys.argv) == 4 and sys.argv[1] == '--pack':
            build_input_archive(sys.argv[2], sys.argv[3])
        elif len(sys.argv) == 6 and sys.argv[1] == '--extract':
            extract_export(*sys.argv[2:])
        else:
            raise GuestExchangeError('Unsupported guest exchange worker command')
    except (OSError, ValueError, RuntimeError, access.GuestAccessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
