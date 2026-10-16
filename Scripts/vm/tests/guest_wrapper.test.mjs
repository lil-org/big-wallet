import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, renameSync, rmSync, symlinkSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import test from 'node:test';

function fixture(operation) {
    const root = realpathSync(mkdtempSync(path.join(tmpdir(), 'big-wallet-guest-wrapper-')));
    const build = path.join(root, 'Volumes/BigWalletBuild');
    const exchange = path.join(build, 'Exchange');
    const state = path.join(root, 'Library/Application Support/BigWalletTestVM');
    const calls = path.join(root, 'calls');
    mkdirSync(exchange, {recursive: true});
    mkdirSync(state, {recursive: true});
    writeFileSync(path.join(exchange, 'job.json'), '{}');
    writeFileSync(path.join(build, '.big-wallet-vm.json'), '{}');
    writeFileSync(path.join(state, 'identity.json'), '{}');
    writeFileSync(calls, '');
    const scripts = {
        '/usr/sbin/sysctl': 'printf "%s\\n" "${FIXTURE_MODEL:-VirtualMac2,1}"',
        '/usr/bin/id': 'case "$1" in -u) printf "501\\n";; -g) printf "20\\n";; -un) printf "wallet-test\\n";; *) exit 1;; esac',
        '/usr/bin/stat': `case "$2" in
%Su) printf 'wallet-test\\n';;
%u) case "$3" in "$FIXTURE_EXCHANGE") printf '%s\\n' "\${FIXTURE_EXCHANGE_UID:-501}";; "$FIXTURE_BUILD") printf '%s\\n' "\${FIXTURE_BUILD_UID:-0}";; *) printf '0\\n';; esac;;
%g) printf '%s\\n' "\${FIXTURE_EXCHANGE_GID:-20}";;
%Lp) case "$3" in "$FIXTURE_EXCHANGE") printf '%s\\n' "\${FIXTURE_EXCHANGE_MODE:-700}";; "$FIXTURE_BUILD") printf '%s\\n' "\${FIXTURE_BUILD_MODE:-755}";; *) printf '640\\n';; esac;;
*) exit 1;;
esac`,
        '/sbin/mount': 'printf "/dev/disk4s1 on %s (%s%s)\\n" "${FIXTURE_MOUNTPOINT:-$FIXTURE_BUILD}" "${FIXTURE_FILESYSTEM:-apfs}" "${FIXTURE_MOUNT_OPTIONS-, local, journaled}"',
        '/usr/sbin/ioreg': 'printf "fixture registry\\n"',
        '/usr/bin/plutil': `case "$2" in
version) printf '1\\n';;
consoleUser) printf 'wallet-test\\n';;
vmId) if [ "$6" = "$FIXTURE_BUILD/.big-wallet-vm.json" ]; then printf '%s\\n' "\${FIXTURE_BUILD_VM_ID:-fixture-vm}"; else printf 'fixture-vm\\n'; fi;;
runId) printf 'fixture-run\\n';;
IOConsoleLocked) /bin/cat >/dev/null; [ "\${FIXTURE_LOCKED:-false}" != unavailable ] || exit 1; printf '%s\\n' "\${FIXTURE_LOCKED:-false}";;
*) exit 1;;
esac`,
        '/usr/local/bin/node': 'printf "node" >> "$FIXTURE_CALLS"; printf " <%s>" "$@" >> "$FIXTURE_CALLS"; printf "\\n" >> "$FIXTURE_CALLS"',
        '/usr/bin/caffeinate': 'printf "caffeinate" >> "$FIXTURE_CALLS"; printf " <%s>" "$@" >> "$FIXTURE_CALLS"; printf "\\n" >> "$FIXTURE_CALLS"',
    };
    let wrapper = readFileSync(new URL('../guest_runner', import.meta.url), 'utf8');
    for (const [original, body] of Object.entries(scripts)) {
        const replacement = path.join(root, 'bin', path.basename(original));
        mkdirSync(path.dirname(replacement), {recursive: true});
        writeFileSync(replacement, `#!/bin/sh\nset -eu\n${body}\n`);
        chmodSync(replacement, 0o755);
        wrapper = wrapper.replaceAll(original, replacement);
    }
    wrapper = wrapper.replaceAll('/Volumes/BigWalletBuild', build).replaceAll('/Library/Application Support/BigWalletTestVM', state);
    const wrapperPath = path.join(root, 'guest_runner');
    writeFileSync(wrapperPath, wrapper);
    const run = (argument = path.join(exchange, 'job.json'), changes = {}) => spawnSync('/bin/sh', [wrapperPath, argument], {
        encoding: 'utf8', env: {PATH: '/usr/bin:/bin', FIXTURE_EXCHANGE: exchange, FIXTURE_BUILD: build, FIXTURE_CALLS: calls,
            BW_TEST_VM_EXCHANGE: exchange, BW_TEST_VM_RUN_ID: 'fixture-run', ...changes},
    });
    try { operation({run, calls: () => readFileSync(calls, 'utf8'), root, exchange}); }
    finally { rmSync(root, {recursive: true, force: true}); }
}

test('normal verified guest jobs hold awake assertions only for the Node utility lifetime', () => fixture(({run, calls}) => {
    const result = run();
    assert.equal(result.status, 0, result.stderr);
    assert.match(calls(), /^caffeinate <-dimsu> <[^>]+\/bin\/node> <\/usr\/local\/libexec\/big-wallet-vm\/guest_bootstrap.mjs> <--exchange>/);
    assert.doesNotMatch(calls(), /^node/m);
}));

test('read-only session verification does not establish a second caffeine assertion', () => fixture(({run, calls}) => {
    const result = run('--verify-session');
    assert.equal(result.status, 0, result.stderr);
    assert.match(calls(), /^node <\/usr\/local\/libexec\/big-wallet-vm\/guest_bootstrap.mjs> <--verify-session>/);
    assert.doesNotMatch(calls(), /caffeinate/);
}));

test('locked and unreadable sessions cannot start a job or session verification', () => {
    for (const locked of ['true', 'unavailable', '0']) {
        for (const argument of [undefined, '--verify-session']) {
            fixture(({run, calls}) => {
                const result = run(argument, {FIXTURE_LOCKED: locked});
                assert.notEqual(result.status, 0);
                assert.match(result.stderr, /unlocked|unlocked-session/);
                assert.equal(calls(), '');
            });
        }
    }
});

test('physical hosts fail before any caffeine or Node invocation', () => fixture(({run, calls}) => {
    const result = run(undefined, {FIXTURE_MODEL: 'Mac16,1'});
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /outside a macOS virtual machine/);
    assert.equal(calls(), '');
}));

test('exchange requires the managed local APFS mount', () => {
    for (const changes of [{FIXTURE_FILESYSTEM: 'nfs'}, {FIXTURE_MOUNT_OPTIONS: ', journaled'},
        {FIXTURE_MOUNTPOINT: '/Volumes/Other'}]) {
        fixture(({run, calls}) => {
            const result = run(undefined, changes);
            assert.notEqual(result.status, 0);
            assert.match(result.stderr, /local APFS build volume is not mounted/);
            assert.equal(calls(), '');
        });
    }
});

test('local exchange and build identity reject unsafe ownership and permissions', () => {
    for (const [changes, message] of [
        [{FIXTURE_EXCHANGE_UID: '0'}, /selected guest account/],
        [{FIXTURE_EXCHANGE_GID: '99'}, /selected guest account/],
        [{FIXTURE_EXCHANGE_MODE: '755'}, /must be private/],
        [{FIXTURE_EXCHANGE_MODE: '1700'}, /must be private/],
        [{FIXTURE_BUILD_UID: '501'}, /owned by root/],
        [{FIXTURE_BUILD_MODE: '777'}, /writable by other users/],
        [{FIXTURE_BUILD_VM_ID: 'other-vm'}, /build volume belongs to another VM/],
    ]) {
        fixture(({run, calls}) => {
            const result = run(undefined, changes);
            assert.notEqual(result.status, 0);
            assert.match(result.stderr, message);
            assert.equal(calls(), '');
        });
    }
});

test('local exchange cannot redirect through a symlink', () => fixture(({run, calls, exchange}) => {
    renameSync(exchange, exchange + '.real');
    symlinkSync(exchange + '.real', exchange);
    const result = run();
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /direct local directories/);
    assert.equal(calls(), '');
}));
