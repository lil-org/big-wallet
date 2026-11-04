import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import test from 'node:test';

test('VM lifecycle host typechecks without starting a virtual machine', () => {
    execFileSync('/usr/bin/xcrun', ['swiftc', '-swift-version', '6', '-parse-as-library', '-typecheck',
        fileURLToPath(new URL('../VMHost.swift', import.meta.url))],
    {timeout: 120_000, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']});
});

test('VM watchdog detects exited owners and preserves committed macOS installations', () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), 'big-wallet-host-fixture-')));
    try {
        const source = readFileSync(new URL('../VMHost.swift', import.meta.url), 'utf8');
        const entry = source.indexOf('@main\n@MainActor\nprivate struct VMHostProgram');
        assert.ok(entry > 0);
        const swift = join(root, 'HostFixture.swift');
        const executable = join(root, 'HostFixture');
        writeFileSync(swift, source.slice(0, entry) + readFileSync(new URL('./host_launcher_fixture.swift', import.meta.url), 'utf8'));
        execFileSync('/usr/bin/xcrun', ['swiftc', '-swift-version', '6', '-parse-as-library', '-O', swift, '-o', executable],
            {timeout: 120_000, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']});
        const stopFile = join(root, 'vm-stop');
        const args = ['--vm', join(root, 'fixture.vbvm'), '--status', join(root, 'status.json'), '--stop-file', stopFile];
        const check = () => JSON.parse(execFileSync(executable, ['check', ...args, '--owner-pid', String(process.pid)],
            {timeout: 10_000, encoding: 'utf8'}));
        assert.deepEqual(check(), {ownerExists: true, parentMatches: true, stopRequested: false});
        writeFileSync(stopFile, '');
        assert.equal(check().stopRequested, true);
        rmSync(stopFile);
        const supervisor = `
import os, subprocess, sys
owner_code = '''import os, subprocess, sys
subprocess.Popen(sys.argv[1:] + ['--owner-pid', str(os.getpid())])
os._exit(0)
'''
owner = subprocess.Popen([sys.executable, '-c', owner_code, *sys.argv[1:]], stdout=subprocess.PIPE, text=True)
try:
    sys.stdout.write(owner.stdout.readline())
finally:
    owner.wait(timeout=5)
`;
        const orphan = JSON.parse(execFileSync('python3', ['-c', supervisor, executable, 'orphan', ...args],
            {timeout: 10_000, encoding: 'utf8'}));
        assert.deepEqual(orphan, {ownerExists: true, parentMatches: false, stopRequested: true});
        const control = join(root, 'upgrade-control.json');
        const protect = () => JSON.parse(execFileSync(executable, ['protection', ...args,
            '--owner-pid', String(process.pid), '--upgrade-control', control],
        {timeout: 10_000, encoding: 'utf8'}));
        const record = (protectedInstallation, showWindow = false) => JSON.stringify({version: 1,
            vmPath: join(root, 'fixture.vbvm'), protectInstallation: protectedInstallation, showWindow});
        writeFileSync(control, record(true), {mode: 0o600});
        assert.deepEqual(protect(), {protected: true, deferred: true, shutdownStarted: false, forceStopRequested: false, windowRequested: false});
        writeFileSync(control, record(true, true));
        assert.deepEqual(protect(), {protected: true, deferred: true, shutdownStarted: false, forceStopRequested: false, windowRequested: true});
        writeFileSync(control, record(false));
        assert.deepEqual(protect(), {protected: false, deferred: false, shutdownStarted: false, forceStopRequested: false, windowRequested: false});
        writeFileSync(control, '{');
        assert.deepEqual(protect(), {protected: true, deferred: true, shutdownStarted: false, forceStopRequested: false, windowRequested: false});
        rmSync(control);
        assert.deepEqual(protect(), {protected: true, deferred: true, shutdownStarted: false, forceStopRequested: false, windowRequested: false});
    } finally {
        rmSync(root, {recursive: true, force: true});
    }
});
