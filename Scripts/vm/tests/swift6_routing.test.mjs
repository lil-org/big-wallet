import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import test from 'node:test';

test('Swift umbrella routes every host mode and refuses guest execution', () => {
    const root = mkdtempSync(path.join(tmpdir(), 'big-wallet-swift-route-'));
    try {
        const scripts = path.join(root, 'Scripts');
        mkdirSync(path.join(scripts, 'vm'), {recursive: true});
        writeFileSync(path.join(scripts, 'check_swift6.sh'), readFileSync(new URL('../../check_swift6.sh', import.meta.url)));
        writeFileSync(path.join(scripts, 'vm/guest_session.sh'), 'test_vm_is_virtual_mac() { [ "$FIXTURE_ROLE" = guest ]; }\n');
        const recorded = path.join(root, 'arguments');
        writeFileSync(path.join(scripts, 'test_vm.sh'), '#!/bin/sh\nprintf "%s\\0" "$@" > "$FIXTURE_ARGUMENTS"\nexit 27\n', {mode: 0o755});
        const run = (args, role = 'host') => spawnSync('/bin/sh', [path.join(scripts, 'check_swift6.sh'), ...args], {
            encoding: 'utf8', timeout: 10000, env: {PATH: '/usr/bin:/bin', FIXTURE_ROLE: role, FIXTURE_ARGUMENTS: recorded},
        });
        for (const mode of ['all', 'build', 'test', 'performance', 'tsan', 'fuzz', 'approval']) {
            assert.equal(run([mode]).status, 27);
            assert.deepEqual(readFileSync(recorded, 'utf8').split('\0').filter(Boolean),
                ['run', 'all', ...(mode === 'all' ? [] : ['--stage', mode])]);
        }
        rmSync(recorded);
        assert.equal(run(['test'], 'guest').status, 2);
        assert.equal(run(['invalid']).status, 2);
        assert.equal(run(['--help']).status, 0);
        assert.equal(spawnSync('/bin/test', ['-e', recorded]).status, 1);
    } finally { rmSync(root, {recursive: true, force: true}); }
});
