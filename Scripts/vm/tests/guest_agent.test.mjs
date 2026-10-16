import assert from 'node:assert/strict';
import {execFileSync, spawn, spawnSync} from 'node:child_process';
import {mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync, existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {fileURLToPath} from 'node:url';

test('one-shot guest supervisor claims once, records failures, and stops its fixture child', async () => {
    const root = mkdtempSync(path.join(tmpdir(), 'big-wallet-agent-fixture-'));
    let active;
    try {
        const source = readFileSync(new URL('../VMGuestAgent.swift', import.meta.url), 'utf8');
        const entry = source.indexOf('@main\n@MainActor\nprivate struct VMGuestAgentProgram');
        assert.ok(entry > 0);
        const agent = source.slice(0, entry).replace('private let exchangePath = "/Volumes/BigWalletBuild/Exchange"',
            'private let exchangePath = CommandLine.arguments[1]').replace(
                'private let runnerPath = "/usr/local/libexec/big-wallet-vm/guest_runner"',
                'private let runnerPath = CommandLine.arguments[2]');
        const swift = path.join(root, 'GuestAgentFixture.swift');
        const executable = path.join(root, 'GuestAgentFixture');
        const runner = path.join(root, 'fixture-runner');
        writeFileSync(swift, agent + readFileSync(new URL('./guest_agent_fixture.swift', import.meta.url), 'utf8'));
        execFileSync('/usr/bin/xcrun', ['swiftc', '-swift-version', '6', '-parse-as-library', '-O', swift, '-o', executable],
            {timeout: 120_000, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']});
        execFileSync(executable, [path.join(root, 'files'), runner, 'files'], {timeout: 10_000});
        const exchange = path.join(root, 'exchange');
        mkdirSync(exchange);
        const job = runId => writeFileSync(path.join(exchange, 'job.json'), JSON.stringify({runId, vmId: 'fixture-vm'}));
        const receipt = runId => JSON.parse(readFileSync(path.join(exchange, '.agent-runs', `${runId}.json`)));
        writeFileSync(runner, '#!/bin/sh\nset -eu\n[ "$#" -eq 1 ]\nprintf "run\\n" >> "$BW_VM_EXCHANGE/calls"\n', {mode: 0o755});
        job('success');
        execFileSync(executable, [exchange, runner, 'run'], {timeout: 10_000});
        const completed = receipt('success');
        assert.equal(completed.state, 'completed');
        assert.equal(completed.exitCode, 0);
        assert.equal(completed.vmId, 'fixture-vm');
        assert.equal(spawnSync(executable, [exchange, runner, 'run'], {timeout: 10_000}).status, 2);
        assert.deepEqual(receipt('success'), completed);
        assert.equal(readFileSync(path.join(exchange, 'calls'), 'utf8'), 'run\n');
        job('missing-runner');
        assert.equal(spawnSync(executable, [exchange, runner + '-missing', 'run'], {timeout: 10_000}).status, 2);
        assert.equal(receipt('missing-runner').state, 'failed');
        writeFileSync(runner, '#!/bin/sh\nexit 7\n', {mode: 0o755});
        job('failure');
        assert.equal(spawnSync(executable, [exchange, runner, 'run'], {timeout: 10_000}).status, 7);
        assert.equal(receipt('failure').exitCode, 7);
        writeFileSync(runner, '#!/bin/sh\nexec /bin/sleep 30\n', {mode: 0o755});
        job('signal');
        active = spawn(executable, [exchange, runner, 'run'], {stdio: 'ignore'});
        const exited = new Promise(resolve => active.once('exit', (code, signal) => resolve({code, signal})));
        const deadline = Date.now() + 5000;
        while (Date.now() < deadline && (!existsSync(path.join(exchange, '.agent-runs/signal.json')) || receipt('signal').state !== 'running')) {
            await new Promise(resolve => setTimeout(resolve, 10));
        }
        const running = receipt('signal');
        assert.equal(running.state, 'running');
        active.kill('SIGTERM');
        const timeout = setTimeout(() => active.kill('SIGKILL'), 5000);
        const result = await exited;
        clearTimeout(timeout);
        assert.equal(result.signal, null);
        assert.equal(receipt('signal').state, 'completed');
        assert.throws(() => process.kill(running.runnerPID, 0), {code: 'ESRCH'});
        active = null;
        writeFileSync(runner, '#!/bin/sh\ntrap "" TERM\nprintf "%s" "$$" > "$BW_VM_EXCHANGE/ignoring-term"\nexec /bin/sleep 30\n', {mode: 0o755});
        job('failed-publication');
        const started = Date.now();
        assert.equal(spawnSync(executable, [exchange, runner, 'fail-running'], {timeout: 10_000}).status, 2);
        assert.ok(Date.now() - started >= 4500, 'Supervisor must wait for termination escalation');
        assert.equal(receipt('failed-publication').state, 'failed');
        const childPID = Number(readFileSync(path.join(exchange, 'ignoring-term'), 'utf8'));
        assert.throws(() => process.kill(childPID, 0), {code: 'ESRCH'});

        const production = path.join(root, 'VMGuestAgent');
        execFileSync('/usr/bin/xcrun', ['swiftc', '-swift-version', '6', '-parse-as-library', '-O',
            fileURLToPath(new URL('../VMGuestAgent.swift', import.meta.url)), '-o', production],
        {timeout: 120_000, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']});
        active = spawn('/bin/sleep', ['30'], {stdio: 'ignore'});
        const processID = active.pid;
        const identity = () => JSON.parse(execFileSync(production, ['--process-identity', String(processID)], {timeout: 5000}));
        const first = identity();
        assert.equal(first.length, 2);
        assert.ok(first[0] > 0 && first[1] >= 0 && first[1] < 1_000_000);
        assert.deepEqual(identity(), first);
        const stopped = new Promise(resolve => active.once('exit', resolve));
        active.kill('SIGTERM');
        await stopped;
        active = null;
        assert.equal(identity(), null);
        for (const pid of ['0', '-1', 'invalid']) {
            assert.equal(spawnSync(production, ['--process-identity', pid], {timeout: 5000}).status, 2);
        }
    } finally {
        active?.kill('SIGKILL');
        rmSync(root, {recursive: true, force: true});
    }
});
