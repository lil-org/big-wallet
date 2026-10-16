import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import test from 'node:test';

test('guest agent bounds job files, writes receipts, replays terminal status, and safely closes sockets', () => {
    const root = mkdtempSync(path.join(tmpdir(), 'big-wallet-agent-fixture-'));
    try {
        const source = readFileSync(new URL('../VMGuestAgent.swift', import.meta.url), 'utf8');
        const entry = source.indexOf('@main\n@MainActor\nprivate struct VMGuestAgentProgram');
        assert.ok(entry > 0, 'Guest agent entry point must be isolated from the fixture');
        const agent = source.slice(0, entry).replace('private let exchangePath = "/Volumes/BigWalletBuild/Exchange"',
            'private let exchangePath = CommandLine.arguments[1]').replace(
                'private let runnerPath = "/usr/local/libexec/big-wallet-vm/guest_runner"',
                'private let runnerPath = CommandLine.arguments[2]');
        assert.ok(!agent.includes('"/Volumes/BigWalletBuild/Exchange"'));
        assert.ok(!agent.includes('"/usr/local/libexec/big-wallet-vm/guest_runner"'));
        const fixture = readFileSync(new URL('./guest_agent_fixture.swift', import.meta.url), 'utf8');
        const swift = path.join(root, 'GuestAgentFixture.swift');
        const executable = path.join(root, 'GuestAgentFixture');
        const runner = path.join(root, 'fixture-runner');
        writeFileSync(runner, '#!/bin/sh\nset -eu\n[ "$#" -eq 1 ]\nprintf "%s\\n" "$1" >> "$BW_VM_EXCHANGE/fixture-job-path"\nprintf "fixture runner output\\n"\n', {mode: 0o755});
        writeFileSync(swift, agent + fixture);
        execFileSync('/usr/bin/xcrun', ['swiftc', '-swift-version', '6', '-parse-as-library', '-O', swift, '-o', executable],
            {timeout: 120_000, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']});
        const output = execFileSync(executable, [path.join(root, 'exchange'), runner],
            {timeout: 10_000, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']});
        assert.match(output, /Guest agent terminal replay fixtures passed/);
        assert.match(output, /Guest agent socket lifetime fixtures passed/);
        assert.match(output, /Guest agent bounded job file fixtures passed/);
        assert.match(output, /Guest agent atomic receipt fixtures passed/);
    } finally { rmSync(root, {recursive: true, force: true}); }
});
