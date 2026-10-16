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
const stopMarker = path.join(exchange, '.stop-' + runId);
const publishStop = () => {
    const temporary = path.join(exchange, '.stop-' + runId + '.' + process.pid + '.json');
    const descriptor = fs.openSync(temporary, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
    try { fs.writeFileSync(descriptor, JSON.stringify({runId})); }
    finally { fs.closeSync(descriptor); }
    fs.renameSync(temporary, path.join(exchange, 'stop.json'));
};
'''

_UPLOAD = _REMOTE_PREAMBLE + r'''
fs.rmSync(path.join(exchange, 'job.json'), {force: true});
const incoming = fs.mkdtempSync(path.join(exchange, '.upload-'));
try {
    const unpack = cp.spawnSync('/usr/bin/tar', ['-xf', '-', '-C', incoming, '--no-same-owner'],
        {stdio: ['inherit', 'inherit', 'inherit'], env: tarEnvironment, timeout: 900000, killSignal: 'SIGKILL'});
    if (unpack.status !== 0) fail('Guest exchange input transfer failed');
    const job = readJSON(path.join(incoming, 'job.json'));
    if (job.runId !== runId || job.vmId !== process.argv[2]) fail('Guest exchange job identity changed');
    for (const name of ['source', 'snapshot-manifest.json', 'inputs', 'stop.json', 'artifacts', 'guest-runner.log', '.agent-runs'])
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

_POLL = _REMOTE_PREAMBLE + r'''
const filename = path.join(exchange, 'artifacts/result.json');
if (!fs.existsSync(filename)) process.stdout.write('{}\n');
else {
    const value = readJSON(filename);
    if (value.runId !== runId) fail('Guest report belongs to another run');
    process.stdout.write(JSON.stringify(value) + '\n');
}
'''

_EXPORT = _REMOTE_PREAMBLE + r'''
const value = readJSON(path.join(exchange, 'artifacts/result.json'));
if (value.runId !== runId || !value.finishedAt || !['passed', 'failed', 'blocked', 'cancelled'].includes(value.status))
    fail('Guest report is not complete');
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
        self.final_seen = False
        try:
            self.work = access._private_directory(private_workdir)
            self.exchange = access._private_directory(exchange)
            self.job = _json(self.exchange / 'job.json', 65536)
            self.run_id = self.job.get('runId')
            self.vm_id = self.job.get('vmId')
            if (not isinstance(self.run_id, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', self.run_id) or
                    not isinstance(self.vm_id, str) or 'big-wallet-vm-' + self.vm_id != host_key_alias):
                raise GuestExchangeError('The exchange job identity is invalid')
            self.command = access.ssh_command(address, user, known_hosts, host_key_alias)
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

    def _start_remote(self, phase, script, *, timeout, input_path=None, output_path=None):
        self.phase = phase
        self.output = open(output_path, 'wb') if output_path else self._temporary_output()
        if output_path:
            self.files.append(self.output)
        self.errors = self._temporary_output()
        command = self.command + [shlex.join(['/usr/local/bin/node', '-e', script, self.run_id, self.vm_id])]
        source = open(input_path, 'rb') if input_path else subprocess.DEVNULL
        try:
            self.child = subprocess.Popen(command, stdin=source, stdout=self.output, stderr=self.errors,
                                          env=self.environment, start_new_session=True)
        finally:
            if input_path:
                source.close()
        self.deadline = time.monotonic() + timeout

    def _start_stop(self):
        self.stop_errors = self._temporary_output()
        self.stop_child = subprocess.Popen(self.command + [shlex.join(['/usr/local/bin/node', '-e', _STOP, self.run_id])],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=self.stop_errors,
            env=self.environment, start_new_session=True)
        self.stop_deadline = time.monotonic() + 15

    def request_stop(self):
        self.stop_requested = True
        if self.password and self.stop_child is None and not self.stop_sent:
            self._start_stop()

    def notify_guest_finished(self):
        if self.guest_finished_at is None:
            self.guest_finished_at = time.monotonic()

    def _missing_final_result(self, now):
        return not self.final_seen and self.guest_finished_at is not None and now - self.guest_finished_at >= 30

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
        return self.result

    def _publish_export(self):
        report = _report(_json(self.export_directory / 'validated-result.json'), self.run_id, self.vm_id, final=True)
        incoming = self.export_directory / 'artifacts'
        artifacts = access._private_directory(self.exchange / 'artifacts')
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
            if self.stop_child is not None:
                code = self.stop_child.poll()
                if code is None and now > self.stop_deadline:
                    access._stop(self.stop_child)
                    code = self.stop_child.returncode
                if code is not None:
                    self.stop_child.wait()
                    self.stop_child = None
                    self.stop_sent = code == 0
                    if code != 0:
                        return self._finish({'status': 'failed', 'reason': 'guest_stop_transfer_failed',
                                             'error': self._error_text(self.stop_errors)})
                    self.stop_errors.close()
                    self.files.remove(self.stop_errors)
            if self.result is not None:
                return self.result
            if self.child is None:
                if self._missing_final_result(now):
                    return self._finish({'status': 'failed', 'reason': 'guest_exited_without_result'})
                if now >= self.next_poll:
                    self._start_remote('report', _POLL, timeout=30)
                return None
            if self.phase == 'export':
                if self.output.tell() > MAX_EXPORT_BYTES + MAX_EXPORT_FILES * 2048:
                    raise GuestExchangeError('The guest artifact download exceeds its size limit')
                _capacity(self.work, 0)
            if self.phase == 'report' and self.output.tell() > MAX_REPORT_BYTES:
                raise GuestExchangeError('The guest report exceeds its size limit')
            if self.errors.tell() > MAX_REPORT_BYTES:
                raise GuestExchangeError('The guest exchange diagnostic output exceeds its size limit')
            code = self.child.poll()
            if code is None:
                if self._missing_final_result(now):
                    return self._finish({'status': 'failed', 'reason': 'guest_exited_without_result'})
                if now > self.deadline:
                    return self._finish({'status': 'failed', 'reason': 'guest_exchange_timeout', 'phase': self.phase})
                return None
            self.child.wait()
            self.child = None
            if code != 0:
                return self._finish({'status': 'failed', 'reason': 'guest_exchange_cancelled' if self.stop_requested else 'guest_exchange_failed',
                                     'phase': self.phase, 'error': self._error_text(self.errors)})
            phase = self.phase
            data = None
            if phase == 'report':
                self.output.seek(0)
                data = self.output.read(MAX_REPORT_BYTES + 1)
            self._close_phase_files()
            if phase == 'pack':
                if self.stop_requested:
                    return self._finish({'status': 'failed', 'reason': 'guest_exchange_cancelled'})
                self._start_remote('upload', _UPLOAD, input_path=self.input_archive, timeout=900)
            elif phase == 'upload':
                self.input_archive.unlink(missing_ok=True)
                self.next_poll = now
            elif phase == 'report':
                if len(data) > MAX_REPORT_BYTES:
                    raise GuestExchangeError('The guest report exceeds its size limit')
                value = json.loads(data)
                if value:
                    _report(value, self.run_id, self.vm_id)
                    if value.get('finishedAt'):
                        _report(value, self.run_id, self.vm_id, final=True)
                        self.final_seen = True
                        self._start_remote('export', _EXPORT, output_path=self.output_archive, timeout=1800)
                    else:
                        _atomic_json(self.exchange / 'artifacts/result.json', value)
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
