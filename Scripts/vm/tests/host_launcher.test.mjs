import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import test from 'node:test';

test('VM lifecycle host typechecks without starting a virtual machine', () => {
    execFileSync('/usr/bin/xcrun', ['swiftc', '-swift-version', '6', '-parse-as-library', '-typecheck',
        fileURLToPath(new URL('../VMHost.swift', import.meta.url))],
    {timeout: 120_000, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']});
});
