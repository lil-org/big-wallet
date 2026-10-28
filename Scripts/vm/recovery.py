import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid


_spec = importlib.util.spec_from_file_location('recovery_exchange', Path(__file__).with_name('guest_exchange.py'))
exchange = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(exchange)
access = exchange.access
MAX_BYTES = exchange.MAX_EXPORT_BYTES
MAX_ENTRIES = exchange.MAX_EXPORT_FILES
MAX_JSON = exchange.MAX_REPORT_BYTES
STATUSES = ('running', *exchange.TERMINAL_STATUSES)


class RecoveryError(RuntimeError):
    pass


def digest(contents):
    return hashlib.sha256(contents).hexdigest()


def read_bytes(path, maximum=MAX_JSON):
    return access._read(path, private=True, maximum=maximum)[0]


def read_json(path, maximum=MAX_JSON):
    value = json.loads(read_bytes(path, maximum))
    if not isinstance(value, dict):
        raise RecoveryError('Recovery metadata must be an object')
    return value


def owned_directory(path, *, private=True):
    path = Path(path)
    metadata = path.lstat()
    if (path.resolve() != path or not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() or
            metadata.st_mode & (0o077 if private else 0o022)):
        raise RecoveryError('Recovery requires a canonical runner-owned directory')
    return metadata.st_dev, metadata.st_ino, metadata.st_uid


def cleanup_scratch(attempt):
    attempt = Path(attempt)
    owned_directory(attempt)
    for work in sorted(attempt.glob('.recovery-*')):
        identity = owned_directory(work)
        names = {path.name for path in work.iterdir()}
        if not names:
            work.rmdir()
            continue
        if 'worker.stderr' not in names or names - {'worker.stderr', 'worker.stdout', 'known_hosts', 'askpass', 'artifacts.tar', 'extracted'}:
            raise RecoveryError('Recovery scratch ownership is incomplete; preserving it for inspection')
        lock_path = work / 'worker.stderr'
        descriptor = os.open(lock_path, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, 'r+b') as lock:
            metadata = os.fstat(lock.fileno())
            if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() or
                    metadata.st_mode & 0o077 or metadata.st_nlink != 1):
                raise RecoveryError('Recovery scratch lock must be a private owned regular file')
            try:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RecoveryError('Recovery scratch is still in use; retry after its worker exits') from None
            current = lock_path.lstat()
            if (owned_directory(work) != identity or
                    (current.st_dev, current.st_ino) != (metadata.st_dev, metadata.st_ino)):
                raise RecoveryError('Recovery scratch changed during cleanup; preserving it for inspection')
            for path in list(work.iterdir()):
                if path.name == 'worker.stderr':
                    continue
                if path.is_dir() and not path.is_symlink():
                    shutil.rmtree(path)
                else:
                    path.unlink()
            lock_path.unlink()
            work.rmdir()


def check_capacity(directory, reserve, needed=0):
    if needed < 0 or shutil.disk_usage(directory).free < reserve + needed:
        raise RecoveryError(f'Artifact recovery requires {((reserve + needed) / 1024 ** 3):.1f} GiB of free space including its reserve')


def retained_access(state, original, job, vm):
    record = read_json(original / 'guest-access.json', 65536)
    vm_id = job['vmId']
    if (record.get('version') != 1 or record.get('runId') != job['runId'] or
            record.get('vmId') != vm_id or record.get('vm') != str(vm)):
        raise RecoveryError('The retained guest access receipt does not match the original run')
    user, access_id, pin_name = record.get('consoleUser'), record.get('guestAccessID'), record.get('knownHosts')
    if (not isinstance(user, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', user) or
            not isinstance(access_id, str) or str(uuid.UUID(access_id)) != access_id or
            not isinstance(pin_name, str) or not re.fullmatch(r'known-hosts-[A-Za-z0-9_-]+', pin_name)):
        raise RecoveryError('The retained guest access identity is invalid')
    directory = state / 'guest-access' / vm_id / access_id
    owned_directory(directory)
    if read_json(directory / 'identity.json') != {'vmId': vm_id, 'consoleUser': user}:
        raise RecoveryError('The retained credential scope belongs to another VM or account')
    password = directory / 'password'
    access._regular(password, private=True)
    alias = 'big-wallet-vm-' + vm_id
    lines = read_bytes(directory / pin_name, 65536).decode('ascii').splitlines()
    if not lines or any(not line.startswith(alias + ' ') for line in lines):
        raise RecoveryError('Retained SSH host keys must belong to this VM')
    pins = '\n'.join(sorted({alias + ' ' + access._public_key(line[len(alias) + 1:]) for line in lines})) + '\n'
    return {'user': user, 'password': password, 'alias': alias, 'pins': pins.encode('ascii')}


def prepare_plan(host, state, run_id):
    if not isinstance(run_id, str) or not re.fullmatch(r'run-[A-Za-z0-9][A-Za-z0-9._-]{0,122}', run_id) or '..' in run_id:
        raise RecoveryError('Recovery requires a retained run identifier')
    if (state / 'active.json').exists() or (state / 'active.json').is_symlink():
        raise RecoveryError('Another VM operation has an ownership record; inspect status before recovery')
    original = state / 'results' / run_id
    owned_directory(original)
    receipt = read_json(original / 'retained-vm.json', 65536)
    vm = state / 'runs' / (run_id + '.vbvm')
    if receipt != {'version': 1, 'runId': run_id, 'vm': str(vm), 'reason': 'artifacts_not_collected'}:
        raise RecoveryError('The retained VM receipt does not match the requested run and owned clone')
    vm_identity = owned_directory(vm, private=False)
    host.validate_vm(vm)
    host.ensure_disk_idle(vm)
    job_bytes = read_bytes(original / 'job.json', 65536)
    job = json.loads(job_bytes)
    if (not isinstance(job, dict) or job.get('version') != 1 or job.get('kind') != 'run' or job.get('runId') != run_id or
            not isinstance(job.get('vmId'), str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', job['vmId']) or
            not isinstance(job.get('source'), dict) or not re.fullmatch(r'[a-f0-9]{64}', str(job['source'].get('sha256', '')))):
        raise RecoveryError('The retained job identity is invalid')
    snapshot = read_bytes(original / 'snapshot-manifest.json')
    if digest(snapshot) != job['source']['sha256']:
        raise RecoveryError('The retained source manifest does not match the job')
    report = read_json(original / 'artifacts/result.json')
    if (report.get('runId') != run_id or report.get('vmId') != job['vmId'] or report.get('status') not in STATUSES or
            not isinstance(report.get('source'), dict) or
            report.get('source', {}).get('sha256') != job['source']['sha256']):
        raise RecoveryError('The retained host report does not match the original job')
    protected = {}
    names = ['job.json', 'guest-access.json', 'snapshot-manifest.json', 'retained-vm.json', 'artifacts/result.json',
             'artifacts/planned-result.json', 'artifacts/guest-result-interrupted.json',
             'artifacts/guest-result-after-stop.json', 'guest-receipt.json', 'stop.json', 'vm-stop', 'vm-status.json']
    for name in names:
        path = original / name
        if path.exists() or path.is_symlink():
            protected[name] = digest(read_bytes(path))
    return {'runId': run_id, 'vmId': job['vmId'], 'vm': vm, 'vmIdentity': vm_identity, 'original': original,
            'jobSHA256': digest(job_bytes), 'sourceSHA256': job['source']['sha256'], 'protected': protected,
            'originalStatus': report['status'], 'access': retained_access(state, original, job, vm),
            'macAddress': access.candidate_mac(vm)}


def assert_original_unchanged(plan):
    if owned_directory(plan['vm'], private=False) != plan['vmIdentity']:
        raise RecoveryError('The retained VM directory changed during recovery')
    for name, expected in plan['protected'].items():
        if digest(read_bytes(plan['original'] / name)) != expected:
            raise RecoveryError(f'Original run metadata changed during recovery: {name}')


REMOTE_INSPECTION = r'''
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const crypto = require('node:crypto');
const root = '/Volumes/BigWalletBuild';
const protectedOwner = 0;
const exchange = path.join(root, 'Exchange');
const [runId, vmId, jobSHA256, sourceSHA256, consoleUser] = process.argv.slice(1);
const uid = process.getuid();
const fail = message => { throw new Error(message); };
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
if (!uid || !/^run-[A-Za-z0-9][A-Za-z0-9._-]{0,122}$/.test(runId || '') || runId.includes('..') ||
    !/^[A-Za-z0-9_-]{1,128}$/.test(vmId || '') || !/^[a-f0-9]{64}$/.test(jobSHA256 || '') ||
    !/^[a-f0-9]{64}$/.test(sourceSHA256 || '') || require('node:os').userInfo().username !== consoleUser)
    fail('Invalid artifact recovery identity');
for (const [directory, owner, mask] of [[root, protectedOwner, 0o022], [exchange, uid, 0o077]]) {
    const info = fs.lstatSync(directory);
    if (!info.isDirectory() || info.isSymbolicLink() || fs.realpathSync(directory) !== directory ||
        info.uid !== owner || info.mode & mask) fail('Invalid recovery directory ownership');
}
const bytes = (filename, maximum = 16 * 1024 * 1024) => {
    const descriptor = fs.openSync(filename, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    try {
        const before = fs.fstatSync(descriptor);
        if (!before.isFile() || before.uid !== uid || before.mode & 0o077 || before.size > maximum)
            fail('Invalid recovery metadata file');
        const value = fs.readFileSync(descriptor);
        const after = fs.fstatSync(descriptor);
        if (value.length !== before.size || after.size !== before.size || after.mtimeMs !== before.mtimeMs || after.ctimeMs !== before.ctimeMs)
            fail('Recovery metadata changed during reading');
        return value;
    } finally { fs.closeSync(descriptor); }
};
const validPID = value => Number.isSafeInteger(value) && value > 1 && value <= 2147483647;
const validStart = value => Array.isArray(value) && value.length === 2 && value.every(Number.isSafeInteger) &&
    value[0] > 0 && value[1] >= 0 && value[1] < 1000000;
const inspectionFailed = (pid, operation, result) => {
    const status = Number.isInteger(result.status) ? String(result.status) : 'unavailable';
    const signal = result.signal === null || result.signal === undefined ? 'none' :
        /^SIG[A-Z0-9]{1,16}$/.test(result.signal) ? result.signal : 'invalid';
    const error = result.error ? /^[A-Z0-9_]{1,32}$/.test(result.error.code || '') ? result.error.code : 'unavailable' : 'none';
    fail(`Cannot inspect retained guest process identity: PID ${pid}; ${operation}; status ${status}; signal ${signal}; error ${error}`);
};
const processUID = pid => {
    const result = cp.spawnSync('/bin/ps', ['-p', String(pid), '-o', 'uid='],
        {encoding: 'utf8', timeout: 5000, maxBuffer: 4096, killSignal: 'SIGKILL'});
    if (result.error || result.signal || ![0, 1].includes(result.status) ||
        typeof result.stdout !== 'string' || typeof result.stderr !== 'string' || result.stderr.trim())
        inspectionFailed(pid, 'UID query', result);
    if (result.status === 1 && result.stdout.trim() === '') return null;
    const match = /^[ \t]*([0-9]+)[ \t]*(?:\r?\n)?$/.exec(result.stdout);
    const owner = match ? Number(match[1]) : NaN;
    if (result.status !== 0 || !Number.isSafeInteger(owner) || owner < 0 || owner > 4294967294 || String(owner) !== match?.[1])
        inspectionFailed(pid, 'UID response', result);
    return owner;
};
const ensureStopped = () => {
    const directory = path.join(exchange, '.agent-runs');
    const info = fs.lstatSync(directory);
    if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== uid || info.mode & 0o077)
        fail('Invalid recovery receipt directory');
    const names = fs.readdirSync(directory).filter(name => name.endsWith('.json'));
    if (names.length > 1024 || !names.includes(runId + '.json')) fail('Missing or excessive recovery receipts');
    for (const name of names) {
        if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.json$/.test(name) || name.includes('..')) fail('Invalid recovery receipt name');
        const receipt = JSON.parse(bytes(path.join(directory, name), 65536));
        if (receipt.version !== 1 || receipt.runId + '.json' !== name || receipt.vmId !== vmId ||
            !validPID(receipt.agentPID) || !validStart(receipt.agentStart) ||
            !['claimed', 'running', 'completed', 'failed'].includes(receipt.state)) fail('Invalid recovery process receipt');
        const processes = [[receipt.agentPID, receipt.agentStart]];
        if (receipt.state === 'running' || receipt.runnerPID !== undefined || receipt.runnerStart !== undefined)
            processes.push([receipt.runnerPID, receipt.runnerStart]);
        for (const [pid, start] of processes) {
            if (!validPID(pid) || !validStart(start)) fail('Invalid recovery process identity');
            const owner = processUID(pid);
            if (owner === null || owner !== uid) continue;
            const result = cp.spawnSync('/usr/local/libexec/big-wallet-vm/VMGuestAgent', ['--process-identity', String(pid)],
                {encoding: 'utf8', timeout: 5000, maxBuffer: 4096, killSignal: 'SIGKILL'});
            if (result.status !== 0 || result.error || result.signal || typeof result.stdout !== 'string' ||
                typeof result.stderr !== 'string' || result.stderr.trim()) inspectionFailed(pid, 'start-time query', result);
            let current;
            try { current = JSON.parse(result.stdout); }
            catch { inspectionFailed(pid, 'start-time response', result); }
            if (current !== null && !validStart(current)) inspectionFailed(pid, 'start-time response', result);
            if (current !== null && current[0] === start[0] && current[1] === start[1])
                fail('A retained guest runner is still alive; recovery will not stop or restart it');
        }
    }
};
const inspect = () => {
    const jobBytes = bytes(path.join(exchange, 'job.json'), 65536);
    const job = JSON.parse(jobBytes);
    if (hash(jobBytes) !== jobSHA256 || job.runId !== runId || job.vmId !== vmId || job.kind !== 'run' ||
        job.source?.sha256 !== sourceSHA256 || hash(bytes(path.join(exchange, 'snapshot-manifest.json'))) !== sourceSHA256)
        fail('Guest job or source identity differs from the retained host job');
    ensureStopped();
    const artifactDirectory = path.join(exchange, 'artifacts');
    const artifactInfo = fs.lstatSync(artifactDirectory);
    if (!artifactInfo.isDirectory() || artifactInfo.isSymbolicLink() || artifactInfo.uid !== uid ||
        artifactInfo.mode & 0o022 || fs.realpathSync(artifactDirectory) !== artifactDirectory)
        fail('Invalid recovery artifact directory');
    const reportBytes = bytes(path.join(exchange, 'artifacts/result.json'));
    const report = JSON.parse(reportBytes);
    if (report.runId !== runId || report.vmId !== vmId || report.source?.sha256 !== sourceSHA256 ||
        !['running', 'passed', 'failed', 'blocked', 'cancelled'].includes(report.status) ||
        (report.status === 'running' ? !!report.finishedAt : typeof report.finishedAt !== 'string' || !report.finishedAt))
        fail('The retained guest report has an invalid identity or completion state');
    const names = ['artifacts'];
    if (fs.existsSync(path.join(exchange, 'guest-runner.log'))) names.push('guest-runner.log');
    const pending = [...names].reverse();
    const inventory = crypto.createHash('sha256');
    let total = 0, entries = 0;
    while (pending.length) {
        const name = pending.pop();
        const filename = path.join(exchange, name);
        const info = fs.lstatSync(filename, {bigint: true});
        if ((!info.isDirectory() && !info.isFile()) || info.uid !== BigInt(uid) || info.mode & 0o022n ||
            fs.realpathSync(filename) !== filename || Buffer.byteLength(name) > 4096)
            fail('Guest artifacts contain an unsafe path, owner, or file type');
        entries += 1;
        if (info.isDirectory()) {
            for (const child of fs.readdirSync(filename).sort().reverse()) pending.push(name + '/' + child);
        } else total += Number(info.size);
        if (entries > 500000 || !Number.isSafeInteger(total) || total > 64 * 1024 ** 3)
            fail('Guest artifacts exceed the recovery budget');
        inventory.update(JSON.stringify([name, info.isDirectory(), String(info.dev), String(info.ino),
            String(info.mode), String(info.size), String(info.mtimeNs), String(info.ctimeNs)]) + '\n');
    }
    const reportSHA256 = hash(reportBytes);
    if (hash(bytes(path.join(exchange, 'artifacts/result.json'))) !== reportSHA256) fail('Guest report changed during recovery inspection');
    return {version: 1, runId, vmId, jobSHA256, sourceSHA256, reportSHA256,
        reportStatus: report.status, reportFinishedAt: report.finishedAt ?? null,
        bytes: total, entries, inventorySHA256: inventory.digest('hex'), archiveMaximumBytes: total + entries * 8192 + 10240};
};
'''

REMOTE_MANIFEST = REMOTE_INSPECTION + '\nprocess.stdout.write(JSON.stringify(inspect()) + "\\n");\n'
REMOTE_EXPORT = REMOTE_INSPECTION + r'''
const before = inspect();
if (before.inventorySHA256 !== process.argv[6] || before.reportSHA256 !== process.argv[7])
    fail('Guest artifacts changed after recovery admission');
const names = ['artifacts'];
if (fs.existsSync(path.join(exchange, 'guest-runner.log'))) names.push('guest-runner.log');
const result = cp.spawnSync('/usr/bin/tar', ['-cf', '-', '-C', exchange, ...names],
    {stdio: ['ignore', 'inherit', 'inherit'], env: {...process.env, COPYFILE_DISABLE: '1'}, timeout: 1800000, killSignal: 'SIGKILL'});
if (result.status !== 0 || result.error || result.signal) fail('Recovery artifact export failed');
if (JSON.stringify(inspect()) !== JSON.stringify(before)) fail('Guest artifacts changed during recovery export');
'''


def validate_manifest(value, plan):
    keys = {'version', 'runId', 'vmId', 'jobSHA256', 'sourceSHA256', 'reportSHA256', 'reportStatus',
            'reportFinishedAt', 'bytes', 'entries', 'inventorySHA256', 'archiveMaximumBytes'}
    if (not isinstance(value, dict) or set(value) != keys or type(value['version']) is not int or value['version'] != 1 or
            any(value[key] != plan[key] for key in ('runId', 'vmId', 'jobSHA256', 'sourceSHA256')) or
            any(not isinstance(value[key], str) or not re.fullmatch(r'[a-f0-9]{64}', value[key])
                for key in ('reportSHA256', 'inventorySHA256')) or value['reportStatus'] not in STATUSES or
            type(value['bytes']) is not int or not 0 < value['bytes'] <= MAX_BYTES or
            type(value['entries']) is not int or not 0 < value['entries'] <= MAX_ENTRIES or
            type(value['archiveMaximumBytes']) is not int or value['archiveMaximumBytes'] != value['bytes'] + value['entries'] * 8192 + 10240 or
            (value['reportFinishedAt'] is not None if value['reportStatus'] == 'running' else
             not isinstance(value['reportFinishedAt'], str) or not 0 < len(value['reportFinishedAt']) <= 128)):
        raise RecoveryError('The recovery manifest does not match the retained job and bounded artifact inventory')
    return value


def extract_archive(archive_path, destination, manifest, reserve):
    destination = Path(destination)
    owned_directory(destination)
    if any(destination.iterdir()):
        raise RecoveryError('Recovery extraction requires an empty private directory')
    archive_path = Path(archive_path)
    access._regular(archive_path, private=True)
    size = archive_path.stat().st_size
    if size < 1024 or size % 512 or size > manifest['archiveMaximumBytes']:
        raise RecoveryError('The recovery archive is truncated or exceeds its budget')
    archive_hash = hashlib.sha256()
    with archive_path.open('rb') as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b''):
            archive_hash.update(chunk)
        file.seek(-1024, os.SEEK_END)
        if file.read() != bytes(1024):
            raise RecoveryError('The recovery archive is missing its completion trailer')
    members, names, total = [], {}, 0
    with tarfile.open(archive_path, 'r:') as archive:
        for member in archive:
            name = member.name.removesuffix('/')
            parts = PurePosixPath(name).parts
            if (not name or name.startswith('/') or any(part in ('', '.', '..') for part in name.split('/')) or
                    parts[0] not in ('artifacts', 'guest-runner.log') or
                    parts[0] == 'guest-runner.log' and (len(parts) != 1 or not member.isfile()) or
                    name in names or member.sparse is not None or not (member.isfile() or member.isdir()) or
                    member.isfile() and member.name.endswith('/') or name == 'artifacts' and not member.isdir() or
                    name in ('artifacts/planned-result.json', 'artifacts/provisioning.log')):
                raise RecoveryError('The recovery archive contains an unsafe path or file type')
            total += member.size
            if member.size < 0 or total > manifest['bytes'] or len(members) >= manifest['entries']:
                raise RecoveryError('The recovery archive exceeds its admitted inventory')
            names[name] = member
            members.append(member)
        if total != manifest['bytes'] or len(members) != manifest['entries']:
            raise RecoveryError('The recovery archive does not contain its complete admitted inventory')
        for name in names:
            for parent in PurePosixPath(name).parents:
                if str(parent) in names and not names[str(parent)].isdir():
                    raise RecoveryError('A recovery artifact parent is not a directory')
        if 'artifacts/result.json' not in names or not names['artifacts/result.json'].isfile():
            raise RecoveryError('The recovery archive is missing its original guest report')
        check_capacity(destination, reserve, total)
        for member in members:
            target = destination / member.name
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            if member.isdir():
                target.mkdir(exist_ok=True, mode=0o700)
            else:
                with archive.extractfile(member) as source, open(target, 'xb') as output:
                    copied = 0
                    while chunk := source.read(1024 * 1024):
                        check_capacity(destination, reserve)
                        output.write(chunk)
                        copied += len(chunk)
                target.chmod(0o600)
                if copied != member.size:
                    raise RecoveryError('A recovered artifact was truncated')
    report_bytes = read_bytes(destination / 'artifacts/result.json')
    report = exchange._report(json.loads(report_bytes), manifest['runId'], manifest['vmId'])
    if (digest(report_bytes) != manifest['reportSHA256'] or report['status'] != manifest['reportStatus'] or
            report.get('finishedAt') != manifest['reportFinishedAt'] or
            report.get('source', {}).get('sha256') != manifest['sourceSHA256']):
        raise RecoveryError('The recovered guest report differs from its admitted identity')
    return {'archiveSHA256': archive_hash.hexdigest(), 'bytes': total, 'entries': len(members),
            'guestReportStatus': report['status'], 'guestReportComplete': bool(report.get('finishedAt'))}


class RecoverySession:
    def __init__(self, host, plan, attempt, vm_process, deadline, cancelled, reserve):
        self.host, self.plan, self.attempt = host, plan, attempt
        self.vm_process, self.deadline, self.cancelled, self.reserve = vm_process, deadline, cancelled, reserve
        self.work = Path(tempfile.mkdtemp(prefix='.recovery-', dir=attempt))
        self.errors = os.fdopen(os.open(self.work / 'worker.stderr', os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600), 'w+b')
        fcntl.flock(self.errors.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.password = b''
        self.child = None
        self.known_hosts = self.work / 'known_hosts'
        self.known_hosts.write_bytes(plan['access']['pins'])
        self.known_hosts.chmod(0o600)
        self.askpass = self.work / 'askpass'
        self.askpass.write_text('#!/bin/sh\nexec ' + shlex.join([sys.executable, str(Path(access.__file__).resolve()),
                                                              '--askpass', str(plan['access']['password'])]) + '\n')
        self.askpass.chmod(0o700)
        self.environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'C',
                            'SSH_ASKPASS': str(self.askpass), 'SSH_ASKPASS_REQUIRE': 'force'}

    def guard(self, needed=0):
        if self.cancelled():
            raise InterruptedError('Artifact recovery was cancelled')
        if time.monotonic() >= self.deadline:
            raise RecoveryError('Artifact recovery exceeded its time limit')
        if self.vm_process.poll() is not None:
            raise RecoveryError('The retained VM stopped before artifact collection completed')
        check_capacity(self.attempt, self.reserve, needed)

    def connect(self):
        deadline = min(self.deadline, time.monotonic() + 180)
        while time.monotonic() < deadline:
            self.guard()
            address = access.find_guest_address(self.plan['macAddress'])
            if address:
                probe = access.SSHBannerProbe(address)
                try:
                    while (outcome := probe.poll()) is None:
                        self.guard()
                        time.sleep(0.2)
                    if outcome['status'] == 'passed':
                        self.command = access.ssh_command(address, self.plan['access']['user'], self.known_hosts,
                                                          self.plan['access']['alias'])
                        self.password = access.read_private_password(self.plan['access']['password'])
                        return
                finally:
                    probe.cancel()
            time.sleep(1)
        raise RecoveryError('The retained VM did not expose its existing SSH service within 180 seconds')

    def command_output(self, command, *, timeout, output_path=None, maximum=MAX_JSON, pending_bytes=None, environment=None):
        path = output_path or self.work / 'worker.stdout'
        flags = os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | (os.O_EXCL if output_path else os.O_TRUNC)
        with os.fdopen(os.open(path, flags, 0o600), 'w+b') as output:
            errors = self.errors
            errors.seek(0)
            errors.truncate()
            self.guard(pending_bytes(0) if pending_bytes else 0)
            self.child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=output, stderr=errors,
                                          env=environment, start_new_session=True)
            deadline = min(self.deadline, time.monotonic() + timeout)
            try:
                while True:
                    size = os.fstat(output.fileno()).st_size
                    if size > maximum or os.fstat(errors.fileno()).st_size > MAX_JSON:
                        raise RecoveryError('Artifact recovery output exceeded its bounded size')
                    self.guard(pending_bytes(size) if pending_bytes else 0)
                    code = self.child.poll()
                    if code is not None:
                        break
                    if time.monotonic() >= deadline:
                        raise RecoveryError('Artifact recovery transfer or extraction timed out')
                    time.sleep(0.2)
                self.child.wait()
                if code:
                    errors.seek(max(0, os.fstat(errors.fileno()).st_size - 4096))
                    detail = errors.read().replace(self.password, b'[REDACTED]') if self.password else errors.read()
                    raise RecoveryError('Artifact recovery command failed: ' + detail.decode('utf-8', errors='replace').strip())
                if output_path:
                    output.flush()
                    os.fsync(output.fileno())
                    return None
                output.seek(0)
                return json.loads(output.read(MAX_JSON + 1))
            finally:
                if self.child.poll() is None:
                    access._stop(self.child)
                self.child.wait()
                self.child = None

    def remote(self, script, arguments, **options):
        return self.command_output(self.command + [shlex.join(['/usr/local/bin/node', '-e', script, *arguments])],
                                   environment=self.environment, **options)

    def collect(self, phase):
        self.connect()
        plan = self.plan
        phase('readiness')
        ready = self.remote(exchange._READY, [plan['runId'], plan['vmId'], '', '', plan['access']['user']], timeout=130)
        if ready != {'version': 1, 'runId': plan['runId'], 'vmId': plan['vmId'], 'ready': True}:
            raise RecoveryError('Invalid recovery readiness acknowledgement')
        arguments = [plan[key] for key in ('runId', 'vmId', 'jobSHA256', 'sourceSHA256')] + [plan['access']['user']]
        phase('inspection')
        manifest = validate_manifest(self.remote(REMOTE_MANIFEST, arguments, timeout=120), plan)
        self.host.atomic_json(self.attempt / 'collection-manifest.json', manifest)
        required = self.reserve + manifest['archiveMaximumBytes'] + manifest['bytes']
        capacity = self.host.check_capacity(self.attempt, required)
        check_capacity(self.attempt, self.reserve, manifest['archiveMaximumBytes'] + manifest['bytes'])
        self.host.atomic_json(self.attempt / 'collection-capacity.json', {**capacity, 'requiredBytes': required,
            'reserveBytes': self.reserve, 'archiveMaximumBytes': manifest['archiveMaximumBytes'], 'extractedBytes': manifest['bytes']})
        archive = self.work / 'artifacts.tar'
        phase('export')
        self.remote(REMOTE_EXPORT, [*arguments, manifest['inventorySHA256'], manifest['reportSHA256']], timeout=1800,
                    output_path=archive, maximum=manifest['archiveMaximumBytes'],
                    pending_bytes=lambda size: max(0, manifest['archiveMaximumBytes'] - size) + manifest['bytes'])
        phase('extraction')
        destination = self.work / 'extracted'
        destination.mkdir(mode=0o700)
        extraction = self.command_output([sys.executable, '-B', str(Path(__file__).resolve()), '--extract', str(archive),
            str(destination), str(self.attempt / 'collection-manifest.json'), *arguments[:4], str(self.reserve)], timeout=900)
        if (not isinstance(extraction, dict) or set(extraction) != {'archiveSHA256', 'bytes', 'entries', 'guestReportStatus', 'guestReportComplete'} or
                not re.fullmatch(r'[a-f0-9]{64}', str(extraction['archiveSHA256'])) or
                any(extraction[key] != manifest[key] for key in ('bytes', 'entries')) or
                extraction['guestReportStatus'] != manifest['reportStatus'] or
                extraction['guestReportComplete'] is not bool(manifest['reportFinishedAt'])):
            raise RecoveryError('Invalid recovery extraction acknowledgement')
        self.guard()
        assert_original_unchanged(plan)
        destination.rename(self.attempt / 'recovered')
        return extraction

    def close(self):
        if self.child is not None:
            access._stop(self.child)
            self.child.wait()
        self.errors.close()
        cleanup_scratch(self.attempt)
        self.password = b''


def recover(host, args, state):
    state = Path(state)
    plan = prepare_plan(host, state, args.run_id)
    environment = host.read_json(host.TOOLS / 'environment.json')
    reserve = environment['minimumHostFreeBytes']
    host.check_capacity(state, reserve)
    check_capacity(state, reserve)
    binaries = host.build_tools(state, args.xcode)
    assert_original_unchanged(plan)
    recovery_id, attempt = host.new_exchange(state, 'recovery')
    result_path = attempt / 'artifacts/result.json'
    result = {'version': 1, 'runId': recovery_id, 'kind': 'artifact-recovery', 'sourceRunId': plan['runId'],
              'vmId': plan['vmId'], 'retainedVM': str(plan['vm']), 'originalRunStatus': plan['originalStatus'],
              'originalFilesSHA256': plan['protected'], 'status': 'running',
              'startedAt': host.datetime.datetime.now(host.datetime.timezone.utc).isoformat(),
              'coverage': {'status': 'partial', 'fullSuiteVerified': False}, 'testsExecuted': False}
    cancelled = False
    process, session = None, None
    stopped = False
    def interrupt(signum, frame):
        nonlocal cancelled
        cancelled = True
    def is_cancelled():
        return cancelled or host.operation_stop_requested(attempt, recovery_id)
    def phase(value):
        result['phase'] = value
        host.atomic_json(result_path, result)
        host.register_operation(state, plan['vm'], attempt, recovery_id, value)
        active = host.read_json(state / 'active.json')
        active.update(kind='artifact-recovery', sourceRunId=plan['runId'])
        host.atomic_json(state / 'active.json', active)
    handlers = {number: signal.signal(number, interrupt) for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        phase('starting')
        print(f'Artifact recovery: {recovery_id}\nOriginal run: {plan["runId"]}\nResults: {attempt}', flush=True)
        with open(attempt / 'vm.log', 'ab', buffering=0) as log:
            if is_cancelled():
                raise InterruptedError('Artifact recovery was cancelled before VM launch')
            host.ensure_disk_idle(plan['vm'])
            check_capacity(state, reserve)
            process = subprocess.Popen([str(Path(binaries) / 'VMHost'), '--vm', str(plan['vm']),
                '--status', str(attempt / 'vm-status.json'), '--stop-file', str(attempt / 'vm-stop'),
                '--owner-pid', str(os.getpid())], stdout=log, stderr=log, start_new_session=True)
            session = RecoverySession(host, plan, attempt, process, time.monotonic() + (args.timeout or 3600),
                                      is_cancelled, reserve)
            result.update(session.collect(phase), recoveredDirectory='recovered', status='passed')
    except (InterruptedError, KeyboardInterrupt) as error:
        result.update(status='cancelled', error=str(error))
    except (OSError, ValueError, RuntimeError, host.RunnerError, access.GuestAccessError) as error:
        detail = str(error).encode('utf-8')
        if session is not None and session.password:
            detail = detail.replace(session.password, b'[REDACTED]')
        result.update(status='failed', error=detail.decode('utf-8', errors='replace'))
    finally:
        try:
            try:
                if session is not None:
                    session.close()
            finally:
                if process is not None:
                    host.stop_owned_process(process, attempt / 'vm-stop')
                host.ensure_disk_idle(plan['vm'])
                stopped = True
                assert_original_unchanged(plan)
        except (OSError, ValueError, RuntimeError, host.RunnerError, access.GuestAccessError) as error:
            result.update(status='failed', cleanupError=str(error))
        finally:
            for number, handler in handlers.items():
                signal.signal(number, handler)
            if result['status'] == 'running':
                result.update(status='failed', error='Artifact recovery did not complete')
            result.update(finishedAt=host.datetime.datetime.now(host.datetime.timezone.utc).isoformat(),
                          phase='collected' if result['status'] == 'passed' else 'incomplete', vmRetained=True)
            host.atomic_json(result_path, result)
            if stopped and not any(attempt.glob('.recovery-*')):
                host.clear_owned_operation(state, recovery_id)
    print(f'{result["status"].upper()}: {result_path}\nOriginal run remains {plan["originalStatus"]}; retained VM preserved.', flush=True)
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    try:
        if len(sys.argv) != 10 or sys.argv[1] != '--extract':
            raise RecoveryError('Use Scripts/test_vm.sh recover-artifacts RUN_ID')
        plan = dict(zip(('runId', 'vmId', 'jobSHA256', 'sourceSHA256'), sys.argv[5:9]))
        manifest = validate_manifest(read_json(Path(sys.argv[4])), plan)
        print(json.dumps(extract_archive(Path(sys.argv[2]), Path(sys.argv[3]), manifest, int(sys.argv[9]))))
    except (OSError, ValueError, RuntimeError, tarfile.TarError) as error:
        print(f'Artifact recovery extraction failed: {error}', file=sys.stderr)
        sys.exit(2)
