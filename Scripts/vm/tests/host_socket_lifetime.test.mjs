import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {fileURLToPath} from 'node:url';

test('host retains original socket ownership until read source cancellation completes', () => {
    const root = realpathSync(mkdtempSync(path.join(tmpdir(), 'big-wallet-host-socket-fixture-')));
    try {
        const sourceURL = new URL('../VMHost.swift', import.meta.url);
        execFileSync('/usr/bin/xcrun', ['swiftc', '-swift-version', '6', '-parse-as-library', '-typecheck', fileURLToPath(sourceURL)],
            {timeout: 120_000, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']});
        const source = readFileSync(sourceURL, 'utf8');
        const entry = source.indexOf('@main\n@MainActor\nprivate struct VMHostProgram');
        assert.ok(entry > 0, 'Host entry point must be isolated from the fixture');
        const host = source.slice(0, entry)
            .replaceAll('VZVirtioSocketConnection', 'FixtureConnection')
            .replace('@MainActor VZVirtioSocketListenerDelegate, ', '')
            .replace('        listener.delegate = self\n', '');
        assert.ok(!host.includes('VZVirtioSocketConnection'));
        assert.ok(!host.includes('VZVirtioSocketListenerDelegate'));
        const fixture = readFileSync(new URL('./host_socket_lifetime_fixture.swift', import.meta.url), 'utf8');
        const swift = path.join(root, 'HostSocketLifetimeFixture.swift');
        const executable = path.join(root, 'HostSocketLifetimeFixture');
        writeFileSync(swift, host + fixture);
        execFileSync('/usr/bin/xcrun', ['swiftc', '-swift-version', '6', '-parse-as-library', '-O', swift, '-o', executable],
            {timeout: 120_000, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']});
        const output = execFileSync(executable, [root],
            {timeout: 10_000, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']});
        assert.match(output, /Host socket lifetime fixtures passed/);
    } finally { rmSync(root, {recursive: true, force: true}); }
});
