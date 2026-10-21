import assert from 'node:assert/strict';
import {createHash, randomUUID} from 'node:crypto';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdtempSync, mkdirSync, readFileSync, readlinkSync, rmSync, symlinkSync, writeFileSync} from 'node:fs';
import * as filesystem from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../provision_guest.sh', import.meta.url), 'utf8');
function pureFunction(name, globals = Object.create(null)) {
    const match = source.match(new RegExp(`^function ${name}\\([^]*?^}`, 'm'));
    assert.ok(match, `Missing ${name}`);
    return vm.runInNewContext(`(${match[0]})`, globals);
}
const select = pureFunction('selectBlankBuildDisk');
const validate = pureFunction('validateBlankBuildDisk');
const optionalSigning = pureFunction('optionalSigningConfiguration');
const appliedRequest = pureFunction('appliedProvisioningRequest');
const rootSpaceRequirement = pureFunction('runtimeRootSpaceRequirement');
const validateArchive = pureFunction('validateXcodeArchive');
const capacity = 103_079_215_104;
const boot = {DeviceIdentifier: 'disk0', Size: 68_719_476_736, Content: 'GUID_partition_scheme',
    Partitions: [{Content: 'Apple_APFS_ISC'}, {Content: 'Apple_APFS'}, {Content: 'Apple_APFS_Recovery'}]};
const blank = {DeviceIdentifier: 'disk1', Size: capacity};
const details = {WholeDisk: true, TotalSize: capacity};
const samples = () => [Buffer.alloc(1024 * 1024), Buffer.alloc(1024 * 1024)];
const check = (condition, message) => { if (!condition) throw new Error(message); };

test('local preparation requests only missing pinned archive and runtime images', () => {
    const matchesRuntime = pureFunction('matchesRuntime');
    const required = pureFunction('requiredProvisioningInputs', {check, matchesRuntime, validateXcodeArchive: validateArchive});
    const runtimes = [{platform: 'iOS', version: '27.0', buildVersion: 'ios-build', dmgPath: 'runtime-0.dmg'},
        {platform: 'visionOS', version: '27.0', buildVersion: 'vision-build', dmgPath: 'runtime-1.dmg'}];
    const installed = [{identifier: 'com.apple.CoreSimulator.SimRuntime.iOS-27-0', version: '27.0', buildversion: 'ios-build', isAvailable: true},
        {identifier: 'com.apple.CoreSimulator.SimRuntime.xrOS-27-0', version: '27.0', buildversion: 'vision-build', isAvailable: true}];
    const configuration = {runtimes, xcodeArchive: {path: 'Xcode.tar', sha256: 'a'.repeat(64)}};
    assert.deepEqual(Array.from(required(configuration, false, [])), ['Xcode.tar', 'runtime-0.dmg', 'runtime-1.dmg']);
    assert.deepEqual(Array.from(required({runtimes}, true, installed)), []);
    assert.deepEqual(Array.from(required(configuration, true, installed.slice(0, 1))), ['runtime-1.dmg']);
    assert.throws(() => required({runtimes}, false, installed), /pinned SHA-256/);
    assert.throws(() => required({runtimes: [{...runtimes[0], dmgPath: '../outside.dmg'}]}, true, []), /basename/);
});

function localStageFilesystem() {
    const parent = '/Volumes/BigWalletBuild/Provisioning';
    const nodes = new Map([[parent, {kind: 'directory', uid: 0, mode: 0o700}]]);
    const removed = [];
    const fs = {
        mkdirSync(filename, options) { if (!nodes.has(filename)) nodes.set(filename, {kind: 'directory', uid: 0, mode: options.mode}); },
        lstatSync(filename) {
            const node = nodes.get(filename);
            if (!node) throw Object.assign(new Error('missing'), {code: 'ENOENT'});
            return {...node, size: node.content?.length ?? 0, isDirectory: () => node.kind === 'directory',
                isFile: () => node.kind === 'file', isSymbolicLink: () => node.kind === 'symlink'};
        },
        realpathSync: filename => filename,
        chmodSync(filename, mode) { nodes.get(filename).mode = mode; },
        readdirSync(directory) { return [...nodes].filter(([filename]) => path.dirname(filename) === directory)
            .map(([filename, node]) => ({name: path.basename(filename), isDirectory: () => node.kind === 'directory'})); },
        readFileSync: filename => nodes.get(filename).content,
        rmSync(filename) { removed.push(filename); for (const key of nodes.keys()) if (key === filename || key.startsWith(filename + '/')) nodes.delete(key); },
    };
    const id = number => `00000000-0000-4000-8000-${String(number).padStart(12, '0')}`;
    const marker = (directory, vmId = 'fixture-vm') => nodes.set(path.join(directory, '.big-wallet-provisioning.json'),
        {kind: 'file', uid: 0, mode: 0o600, content: JSON.stringify({version: 1, vmId})});
    const add = (number, vmId = 'fixture-vm') => {
        const directory = path.join(parent, id(number));
        nodes.set(directory, {kind: 'directory', uid: 0, mode: 0o700});
        marker(directory, vmId);
        return directory;
    };
    const create = pureFunction('prepareLocalProvisioningDirectory', {fs, path, check, crypto: {randomUUID: () => id(999)},
        writeJSON(filename, value, mode) { nodes.set(filename, {kind: 'file', uid: 0, mode, content: JSON.stringify(value)}); }});
    return {parent, nodes, removed, fs, add, marker, create: () => create('/Volumes/BigWalletBuild', 'fixture-vm')};
}

test('local stage creation removes only marked private directories owned by the same VM', () => {
    const fixture = localStageFilesystem();
    const owned = fixture.add(1);
    const other = fixture.add(2, 'other-vm');
    const unmarked = fixture.add(3);
    fixture.nodes.delete(path.join(unmarked, '.big-wallet-provisioning.json'));
    const exposed = fixture.add(4);
    fixture.nodes.get(exposed).mode = 0o755;
    const linked = fixture.add(5);
    fixture.nodes.get(linked).kind = 'symlink';
    const unsafeMarker = fixture.add(6);
    fixture.nodes.get(path.join(unsafeMarker, '.big-wallet-provisioning.json')).mode = 0o644;
    const directory = fixture.create();
    assert.deepEqual(fixture.removed, [owned]);
    for (const preserved of [other, unmarked, exposed, linked, unsafeMarker]) assert.ok(fixture.nodes.has(preserved));
    assert.equal(fixture.nodes.get(directory).mode, 0o700);
    const marker = fixture.nodes.get(path.join(path.dirname(directory), '.big-wallet-provisioning.json'));
    assert.equal(marker.mode, 0o600);
    assert.deepEqual(JSON.parse(marker.content), {version: 1, vmId: 'fixture-vm'});
});

test('abandoned local stage cleanup is bounded', () => {
    const fixture = localStageFilesystem();
    for (let index = 1; index <= 34; index += 1) fixture.add(index);
    fixture.create();
    assert.equal(fixture.removed.length, 32);
});

test('large input cleanup requires a protected local same-VM marker and never removes unmanaged inputs', () => {
    const fixture = localStageFilesystem();
    const directory = fixture.create();
    const archive = path.join(directory, 'Xcode.tar');
    fixture.nodes.set(archive, {kind: 'file', uid: 0, mode: 0o600, content: 'archive'});
    const remove = pureFunction('removeLocalProvisioningInput', {fs: fixture.fs, path, check});
    assert.throws(() => remove('/tmp/unmanaged/provision/Xcode.tar', '/tmp/unmanaged/provision', 'fixture-vm'), /managed local/);
    assert.throws(() => remove(archive, directory, 'other-vm'), /another VM/);
    fixture.nodes.get(archive).uid = 501;
    assert.throws(() => remove(archive, directory, 'fixture-vm'), /root-owned local/);
    assert.deepEqual(fixture.removed, []);
    fixture.nodes.get(archive).uid = 0;
    remove(archive, directory, 'fixture-vm');
    assert.deepEqual(fixture.removed, [archive]);
});

function localExchangeFixture({parent = {}, existing} = {}) {
    const build = '/Volumes/BigWalletBuild';
    const exchange = build + '/Exchange';
    const nodes = new Map([[build, {kind: 'directory', uid: 0, gid: 0, mode: 0o755, ...parent}]]);
    if (existing) nodes.set(exchange, {kind: 'directory', uid: 501, gid: 20, mode: 0o700, ...existing});
    const changes = [];
    const metadata = filename => {
        const node = nodes.get(filename);
        if (!node) return undefined;
        return {...node, isDirectory: () => node.kind === 'directory', isSymbolicLink: () => node.kind === 'symlink'};
    };
    const fs = {
        lstatSync: metadata, statSync: metadata,
        realpathSync: filename => nodes.get(filename)?.target ?? filename,
        mkdirSync(filename, options) { changes.push(['mkdir', filename]); nodes.set(filename, {kind: 'directory', uid: 0, gid: 0, mode: options.mode}); },
        chmodSync(filename, mode) { changes.push(['chmod', filename, mode]); nodes.get(filename).mode = mode; },
        chownSync(filename, uid, gid) { changes.push(['chown', filename, uid, gid]); Object.assign(nodes.get(filename), {uid, gid}); },
    };
    const prepare = pureFunction('prepareLocalExchange', {fs, path, check, exchange, uid: 501, gid: 20,
        setOwnershipIfNeeded: pureFunction('setOwnershipIfNeeded', {fs})});
    return {build, exchange, nodes, changes, run: () => prepare(build)};
}

test('local exchange is private and assigned to the selected guest on creation and retry', () => {
    for (const existing of [undefined, {uid: 0, gid: 0}, {}]) {
        const fixture = localExchangeFixture({existing});
        fixture.run();
        const directory = fixture.nodes.get(fixture.exchange);
        assert.equal(directory.uid, 501);
        assert.equal(directory.gid, 20);
        assert.equal(directory.mode, 0o700);
        assert.equal(fixture.changes.filter(([operation]) => operation === 'mkdir').length, existing ? 0 : 1);
        fixture.run();
        assert.equal(fixture.changes.filter(([operation]) => operation === 'mkdir').length, existing ? 0 : 1);
    }
});

test('local exchange preparation rejects redirected or unprotected storage before changing it', () => {
    for (const parent of [{uid: 501}, {mode: 0o777}, {kind: 'symlink'}, {kind: 'file'}, {target: '/outside'}]) {
        const fixture = localExchangeFixture({parent});
        assert.throws(fixture.run, /protected root-owned/);
        assert.deepEqual(fixture.changes, []);
    }
    for (const existing of [{uid: 502}, {mode: 0o755}, {kind: 'symlink'}, {kind: 'file'}, {target: '/outside'}]) {
        const fixture = localExchangeFixture({existing});
        assert.throws(fixture.run, /private directory/);
        assert.deepEqual(fixture.changes, []);
    }
});

test('Aqua readiness requires the selected console user, GUI domain and an unlocked session', () => {
    for (const failure of [null, 'console', 'domain', 'locked']) {
        const ready = pureFunction('selectedUserSessionReady', {uid: 501, spawnSync(command, args, options) {
            assert.equal(options.timeout, 1000);
            assert.equal(options.killSignal, 'SIGKILL');
            if (command.endsWith('/stat')) return {status: 0, stdout: failure === 'console' ? '502\n' : '501\n'};
            if (command.endsWith('/launchctl')) return {status: failure === 'domain' ? 1 : 0};
            if (command.endsWith('/ioreg')) return {status: 0, stdout: 'fixture registry'};
            return {status: 0, stdout: failure === 'locked' ? 'true\n' : 'false\n'};
        }});
        assert.equal(ready(), failure === null);
    }
});

test('Aqua wait permits normal login progress but bounds timeout and propagates interruption', () => {
    const wait = pureFunction('waitForSelectedSession', {check});
    let time = 0;
    const delays = [];
    wait({ready: () => time >= 2000, now: () => time, wait(milliseconds) { delays.push(milliseconds); time += milliseconds; }});
    assert.deepEqual(delays, [1000, 1000]);
    time = 0;
    assert.throws(() => wait({ready: () => false, now: () => time, timeoutMilliseconds: 2500,
        wait(milliseconds) { time += milliseconds; }}), /unlocked Aqua session/);
    assert.equal(time, 2500);
    assert.throws(() => wait({ready: () => false, now: () => 0, wait() { throw new Error('fixture cancellation'); }}), /fixture cancellation/);
});

test('Aqua wait handles a fractional final delay through the subprocess timeout API', () => {
    const times = [0, 119830.591959, 120000];
    const calls = [];
    const wait = pureFunction('waitForSelectedSession', {check, spawnSync(command, args, options) {
        calls.push({command, args, options});
        return spawnSync(command, args, options);
    }});
    assert.throws(() => wait({ready: () => false, now: () => times.shift()}), /unlocked Aqua session/);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].command, '/bin/sleep');
    assert.ok(Number(calls[0].args[0]) > 0 && Number(calls[0].args[0]) < 1);
    assert.equal(calls[0].options.timeout, 1170);
    assert.equal(calls[0].options.killSignal, 'SIGKILL');
});

test('autologin preparation uses only the supplied existing password and requests one restart only when needed', () => {
    for (const [enabled, ready] of [[true, false], [false, false], [false, true]]) {
        const calls = [];
        let configured = enabled;
        const ensure = pureFunction('ensureAutomaticLogin', {check, config: {consoleUser: 'tester', autologin: {passwordFile: 'password'}},
            automaticLoginEnabled: () => configured, selectedUserSessionReady: () => ready,
            secret() { calls.push('password'); return 'existing-password'; },
            run(_label, command, args, options) {
                if (command.endsWith('/id')) return 'staff admin';
                assert.equal(options.secret, true);
                assert.equal(options.timeout, 60000);
                assert.ok(args.includes('existing-password'));
                calls.push('enable');
                configured = true;
                return '';
            }});
        assert.equal(ensure(), !enabled && !ready);
        assert.deepEqual(calls, enabled ? [] : ['password', 'enable']);
    }
    const ensure = pureFunction('ensureAutomaticLogin', {check, config: {consoleUser: 'tester'},
        automaticLoginEnabled: () => false, selectedUserSessionReady: () => false});
    assert.throws(ensure, /existing guest account password/);
});

test('autologin status matches the exact selected account name', () => {
    for (const [message, expected] of [['Automatic login user: bob', true], ["Automatic login user: 'bob'", true],
        ['Automatic login user: bobby', false], ['Automatic login user: bob-test', false], ['Automatic login disabled for bob', false]]) {
        const enabled = pureFunction('automaticLoginEnabled', {config: {consoleUser: 'bob'},
            spawnSync() { return {status: 0, stdout: '', stderr: message}; }});
        assert.equal(enabled(), expected);
    }
});

test('storage preparation emits one marker before full setup or receipt publication', () => {
    const logs = [];
    let prepareState = () => '/guest/state/identity.json';
    let preparedStorage = 0;
    const main = pureFunction('provisionGuest', {check, path, mode: '--prepare-storage', uid: 501, gid: 20,
        config: {version: 1, vmId: 'fixture-vm', consoleUser: 'tester', xcode: {version: '27.0', buildVersion: 'fixture'},
            runtimes: [{platform: 'iOS', version: '27.0', buildVersion: 'ios'}, {platform: 'visionOS', version: '27.0', buildVersion: 'vision'}]},
        library: '/guest/library', state: '/guest/state', appliedProvisioningRequest() {}, text: value => value,
        fs: {statSync: () => ({isDirectory: () => true}), mkdirSync() {}, chmodSync() {}, chownSync() {}, existsSync: () => false},
        prepareGuestState: () => prepareState(),
        run: (_label, command) => command.endsWith('/dscl') ? 'NFSHomeDirectory: /Users/tester' : 'staff',
        prepareBuildData: () => { preparedStorage++; return '/Volumes/BigWalletBuild'; }, ensureAutomaticLogin: () => true,
        xcodeVersion: () => null, matchesXcode: () => false, selectedUserSessionReady: () => false,
        requiredProvisioningInputs: () => ['Xcode.tar'], prepareLocalProvisioningDirectory: () => '/Volumes/BigWalletBuild/Provisioning/00000000-0000-4000-8000-000000000001/provision',
        console: {log: value => logs.push(value)},
        waitForSelectedSession() { throw new Error('Full setup must not begin'); },
        writeJSON() { throw new Error('The setup receipt must not be published'); },
    });
    main();
    assert.equal(logs.length, 1);
    assert.ok(logs[0].startsWith('BIG_WALLET_PROVISIONING_STAGE='));
    assert.deepEqual(JSON.parse(logs[0].split('=')[1]), {
        stagingDirectory: '/Volumes/BigWalletBuild/Provisioning/00000000-0000-4000-8000-000000000001/provision',
        requiredInputs: ['Xcode.tar'], requiresRestart: true,
    });
    for (const failACL of ['-N', '+a']) {
        const fixture = guestStateFixture({failACL});
        prepareState = fixture.prepare;
        assert.throws(main, /fixture ACL failure/);
        assert.equal(preparedStorage, 1);
        assert.equal(logs.length, 1);
        assert.equal(fixture.changes.at(-1), failACL);
    }
});

function guestStateFixture({failACL} = {}) {
    const state = '/guest/state';
    const config = {vmId: 'fixture-vm', consoleUser: 'tester'};
    const prior = {...config};
    const metadata = {uid: 0, gid: 20, mode: 0o750, isDirectory: () => true, isSymbolicLink: () => false};
    const changes = [];
    let acl = [{principal: 'staff', group: true, rights: ['list', 'search', 'add_file']}];
    const prepare = pureFunction('prepareGuestState', {check, path, state, config,
        fs: {
            mkdirSync() {}, lstatSync: () => metadata, existsSync: () => true,
            readFileSync: () => JSON.stringify(prior),
            chmodSync(_filename, mode) { metadata.mode = mode; changes.push('mode'); },
            chownSync(_filename, uid, gid) { metadata.uid = uid; metadata.gid = gid; changes.push('owner'); },
        },
        run(_label, command, args) {
            assert.equal(command, '/bin/chmod');
            assert.equal(args.at(-1), state);
            changes.push(args[0]);
            if (args[0] === failACL) throw new Error('fixture ACL failure');
            if (args[0] === '-N') acl = [];
            else {
                assert.equal(args[0], '+a');
                const entry = /^user:([\w-]+) allow ([a-z_,]+)$/.exec(args[1]);
                assert.ok(entry);
                acl.push({principal: entry[1], group: false, rights: entry[2].split(',')});
            }
        },
    });
    const accounts = {root: {uid: 0, groups: [0], name: 'root'},
        selected: {uid: 501, groups: [20], name: 'tester'}, other: {uid: 502, groups: [20], name: 'unrelated'}};
    const posix = (node, account, permission) => account.uid === 0 || Boolean((node.mode >>
        (node.uid === account.uid ? 6 : account.groups.includes(node.gid) ? 3 : 0)) & permission);
    const directoryAccess = (account, right) => posix(metadata, account, {list: 4, search: 1, add_file: 2}[right]) ||
        acl.some(entry => (entry.group ? account.groups.includes(20) && entry.principal === 'staff' : entry.principal === account.name) && entry.rights.includes(right));
    const fileAccess = (account, mode, permission) => directoryAccess(account, 'search') && posix({uid: 0, gid: 20, mode}, account, permission);
    return {prepare, metadata, prior, changes, accounts, directoryAccess, fileAccess};
}

test('guest state permits only root and the selected staff account to read signing configuration', () => {
    const fixture = guestStateFixture();
    const {root, selected, other} = fixture.accounts;
    assert.equal(fixture.fileAccess(other, 0o640, 4), true);
    fixture.prepare();
    assert.deepEqual(fixture.changes, ['mode', 'owner', '-N', '+a']);
    for (const account of [root, selected]) {
        assert.equal(fixture.directoryAccess(account, 'list'), true);
        assert.equal(fixture.fileAccess(account, 0o640, 4), true);
    }
    assert.equal(fixture.fileAccess(root, 0o640, 2), true);
    for (const account of [selected, other]) {
        assert.equal(fixture.directoryAccess(account, 'add_file'), false);
        assert.equal(fixture.fileAccess(account, 0o640, 2), false);
    }
    assert.equal(fixture.directoryAccess(other, 'list'), false);
    assert.equal(fixture.fileAccess(other, 0o640, 4), false);
});

test('guest state rejects unsafe directories and account changes before granting access', () => {
    for (const change of [{uid: 501}, {mode: 0o770}, {isDirectory: () => false}, {isSymbolicLink: () => true},
        {consoleUser: 'different'}, {vmId: 'different'}]) {
        const fixture = guestStateFixture();
        Object.assign(Object.hasOwn(change, 'consoleUser') || Object.hasOwn(change, 'vmId') ? fixture.prior : fixture.metadata, change);
        assert.throws(fixture.prepare, /protected root-owned directory|another VM or console user/);
        assert.deepEqual(fixture.changes, []);
    }
});

function agentInstallationFixture(operation, {fresh = false} = {}) {
    const root = mkdtempSync(path.join(tmpdir(), 'big-wallet-agent-install-'));
    const owner = process.getuid();
    const group = process.getgid();
    const entries = ['VMGuestAgent', 'provisioning.json', 'agent.plist'].map((name, index) => ({
        path: path.join(root, name), data: `new-${name}`, mode: index === 0 ? 0o755 : 0o640, uid: owner, gid: group,
    }));
    const events = [];
    const deferredSignals = [];
    let loaded = !fresh;
    const api = {...filesystem, chownSync() {}};
    const service = {
        isLoaded: () => loaded,
        stop() { events.push('stop'); loaded = false; },
        start() { events.push('start'); loaded = true; },
    };
    try {
        if (!fresh) for (const entry of entries) writeFileSync(entry.path, `old-${path.basename(entry.path)}`, {mode: 0o600});
        const install = pureFunction('replaceGuestAgentInstallation', {fs: api, crypto: {randomUUID: () => 'fixture'},
            process: {on(signal) { deferredSignals.push(signal); }}, setImmediate() {},
            check(condition, message) { if (!condition) throw new Error(message); }});
        const contents = () => entries.map(entry => filesystem.existsSync(entry.path) ? readFileSync(entry.path, 'utf8') : null);
        const leftovers = () => filesystem.readdirSync(root).filter(name => /\.(new|previous)$/.test(name));
        operation({root, entries, api, service, events, deferredSignals, install: () => install(entries, service), contents, leftovers,
            loaded: () => loaded});
    } finally { rmSync(root, {recursive: true, force: true}); }
}

test('agent replacement stages every file before quiescing and installs the complete set', () => {
    agentInstallationFixture(({entries, service, events, install, contents, leftovers, loaded}) => {
        const stop = service.stop;
        service.stop = () => {
            assert.deepEqual(contents(), entries.map(entry => `old-${path.basename(entry.path)}`));
            for (const entry of entries) {
                assert.equal(readFileSync(`${entry.path}.fixture.new`, 'utf8'), entry.data);
                assert.equal(readFileSync(`${entry.path}.fixture.previous`, 'utf8'), `old-${path.basename(entry.path)}`);
            }
            stop();
        };
        install();
        assert.deepEqual(events, ['stop', 'start']);
        assert.deepEqual(contents(), entries.map(entry => entry.data));
        assert.equal(loaded(), true);
        for (const entry of entries) assert.equal(filesystem.statSync(entry.path).mode & 0o777, entry.mode);
        assert.deepEqual(leftovers(), []);
    });
    assert.doesNotMatch(source, /launchctl bootout "gui\/\$console_uid\/org\.lil\.big-wallet\.vm-guest"/);
    assert.ok(source.lastIndexOf('replaceGuestAgentInstallation(replacements,') > source.indexOf('const provisioning ='));
});

test('preparation failures leave the existing agent and files untouched', () => {
    for (const failure of ['missing-source', 'symlink', 'wrong-owner', 'writable-root-file']) {
        agentInstallationFixture(({root, entries, api, events, deferredSignals, install, contents, leftovers, loaded}) => {
            if (failure === 'missing-source') entries[1].source = path.join(root, 'missing');
            if (failure === 'wrong-owner') entries[1].uid += 1;
            if (failure === 'writable-root-file') {
                entries[1].uid = 0;
                api.lstatSync = (filename, options) => {
                    const metadata = filesystem.lstatSync(filename, options);
                    if (filename === entries[1].path) { metadata.uid = 0; metadata.mode |= 0o022; }
                    return metadata;
                };
            }
            if (failure === 'symlink') {
                const original = entries[1].path;
                api.renameSync(original, path.join(root, 'preserved'));
                symlinkSync(path.join(root, 'preserved'), original);
            }
            assert.throws(install);
            assert.deepEqual(events, []);
            assert.deepEqual(deferredSignals, []);
            assert.deepEqual(contents(), entries.map(entry => `old-${path.basename(entry.path)}`));
            assert.equal(loaded(), true);
            assert.deepEqual(leftovers(), []);
        });
    }
});

test('replacement or launch failure restores the exact prior files, modes, receipt and service', () => {
    for (const failure of ['replacement', 'launch']) {
        agentInstallationFixture(({entries, api, service, events, install, contents, leftovers, loaded}) => {
            let failOnce = true;
            if (failure === 'replacement') {
                api.renameSync = (from, to) => {
                    if (failOnce && from === `${entries[1].path}.fixture.new`) {
                        failOnce = false;
                        throw new Error('fixture replacement failure');
                    }
                    filesystem.renameSync(from, to);
                };
            } else {
                const start = service.start;
                service.start = () => {
                    start();
                    if (failOnce) { failOnce = false; throw new Error('fixture launch failure'); }
                };
            }
            assert.throws(install, /fixture (replacement|launch) failure/);
            assert.deepEqual(contents(), entries.map(entry => `old-${path.basename(entry.path)}`));
            for (const entry of entries) assert.equal(filesystem.statSync(entry.path).mode & 0o777, 0o600);
            assert.deepEqual(events, failure === 'replacement' ? ['stop', 'stop', 'start'] : ['stop', 'start', 'stop', 'start']);
            assert.equal(loaded(), true);
            assert.deepEqual(leftovers(), []);
        });
    }
});

test('private guest state protects staged signing configuration and rollback copies', () => {
    for (const failStart of [false, true]) {
        agentInstallationFixture(({entries, service, install, contents, leftovers}) => {
            const fixture = guestStateFixture();
            fixture.prepare();
            const provisioning = entries[1];
            filesystem.chmodSync(provisioning.path, 0o640);
            const assertAccess = filename => {
                const mode = filesystem.statSync(filename).mode;
                assert.equal(fixture.fileAccess(fixture.accounts.selected, mode, 4), true);
                assert.equal(fixture.fileAccess(fixture.accounts.other, mode, 4), false);
                assert.equal(fixture.fileAccess(fixture.accounts.selected, mode, 2), false);
            };
            const stop = service.stop;
            let stopped = false;
            service.stop = () => {
                if (!stopped) {
                    for (const suffix of ['', '.fixture.new', '.fixture.previous']) assertAccess(provisioning.path + suffix);
                    stopped = true;
                }
                stop();
            };
            const start = service.start;
            let failed = false;
            service.start = () => {
                start();
                if (failStart && !failed) { failed = true; throw new Error('fixture launch failure'); }
            };
            if (failStart) assert.throws(install, /fixture launch failure/);
            else install();
            assertAccess(provisioning.path);
            assert.equal(contents()[1], `${failStart ? 'old' : 'new'}-provisioning.json`);
            assert.deepEqual(leftovers(), []);
        });
    }
});

test('failed first installation removes new files without inventing a previous service', () => {
    agentInstallationFixture(({service, events, install, contents, leftovers, loaded}) => {
        service.start = () => { events.push('start'); throw new Error('fixture startup failure'); };
        assert.throws(install, /fixture startup failure/);
        assert.deepEqual(contents(), [null, null, null]);
        assert.deepEqual(events, ['stop', 'start', 'stop']);
        assert.equal(loaded(), false);
        assert.deepEqual(leftovers(), []);
    }, {fresh: true});
});

test('failed restoration retains protected previous files for recovery', () => {
    agentInstallationFixture(({entries, api, service, install, leftovers, loaded}) => {
        service.start = () => { throw new Error('fixture startup failure'); };
        api.renameSync = (from, to) => {
            if (from.endsWith('.previous')) throw new Error('fixture restore failure');
            filesystem.renameSync(from, to);
        };
        assert.throws(install, /restoration failed: fixture restore failure.*\.previous files were retained/);
        assert.equal(loaded(), false);
        assert.equal(leftovers().length, entries.length);
        for (const entry of entries) {
            assert.equal(readFileSync(`${entry.path}.fixture.previous`, 'utf8'), `old-${path.basename(entry.path)}`);
            assert.equal(filesystem.statSync(`${entry.path}.fixture.previous`).mode & 0o777, 0o600);
        }
    });
});

test('termination during agent replacement waits for commit or rollback before exiting', () => {
    const install = source.match(/^function replaceGuestAgentInstallation\([^]*?^}/m)[0];
    for (const signal of ['SIGTERM', 'SIGHUP']) {
        for (const failStart of [false, true]) {
            const root = mkdtempSync(path.join(tmpdir(), 'big-wallet-agent-signal-'));
            const agent = path.join(root, 'agent');
            const state = path.join(root, 'service-state');
            const program = `
                const fs = require('node:fs');
                const crypto = require('node:crypto');
                const check = (condition, message) => { if (!condition) throw new Error(message); };
                ${install}
                const agent = ${JSON.stringify(agent)};
                const state = ${JSON.stringify(state)};
                fs.writeFileSync(agent, 'old', {mode: 0o600});
                fs.writeFileSync(state, 'loaded');
                let stops = 0;
                let starts = 0;
                try {
                    replaceGuestAgentInstallation([{path: agent, data: 'new', mode: 0o600,
                        uid: process.getuid(), gid: process.getgid()}], {
                        isLoaded: () => true,
                        stop() {
                            fs.writeFileSync(state, 'stopped');
                            if (++stops === 1) process.kill(process.pid, ${JSON.stringify(signal)});
                        },
                        start() {
                            if (++starts === 1 && ${failStart}) throw new Error('fixture startup failure');
                            fs.writeFileSync(state, 'loaded');
                        },
                    });
                } catch (error) {
                    if (!${failStart} || error.message !== 'fixture startup failure') throw error;
                }
            `;
            try {
                const result = spawnSync(process.execPath, ['-e', program], {encoding: 'utf8', timeout: 5000, killSignal: 'SIGKILL'});
                assert.equal(result.error, undefined, `${signal} ${failStart}: ${result.stderr}`);
                assert.equal(result.signal, null, `${signal} ${failStart}: ${result.stderr}`);
                assert.equal(result.status, signal === 'SIGTERM' ? 143 : 129);
                assert.equal(readFileSync(state, 'utf8'), 'loaded');
                assert.equal(readFileSync(agent, 'utf8'), failStart ? 'old' : 'new');
                assert.deepEqual(filesystem.readdirSync(root).sort(), ['agent', 'service-state']);
            } finally { rmSync(root, {recursive: true, force: true}); }
        }
    }
});

function nodeBootstrapFixture({npmPresent = false, npmVersion = '11.15.0', validChecksum = true, npmEnvNode = false}, operation) {
    const root = mkdtempSync(path.join(tmpdir(), 'big-wallet-node-bootstrap-'));
    const prefix = path.join(root, 'installed');
    const downloads = path.join(root, 'downloads');
    const payload = path.join(root, 'node-v24.22.0-darwin-arm64');
    const archive = path.join(root, 'fixture.tar.gz');
    const checksums = path.join(root, 'SHASUMS256.txt');
    const calls = path.join(root, 'calls');
    const version = path.join(root, 'npm-version');
    const userHome = path.join(root, 'guest-home');
    const inheritedCache = path.join(root, 'inherited-npm-cache');
    const quote = value => `'${value.replaceAll("'", "'\\''")}'`;
    const script = (filename, text) => { writeFileSync(filename, `#!/bin/sh\nset -eu\n${text}\n`); filesystem.chmodSync(filename, 0o755); };
    try {
        mkdirSync(path.join(prefix, 'bin'), {recursive: true});
        mkdirSync(path.join(payload, 'bin'), {recursive: true});
        mkdirSync(downloads);
        mkdirSync(userHome);
        mkdirSync(inheritedCache);
        writeFileSync(calls, '');
        writeFileSync(version, npmVersion + '\n');
        script(path.join(payload, 'bin/node'), 'if [ "$1" = --version ]; then printf "v24.22.0\\n"; else exec /bin/sh "$@"; fi');
        script(path.join(payload, 'bin/npm'), `
command=$1
shift
cache=\${npm_config_cache:-"$HOME/.npm"}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --cache) shift; cache=$1 ;;
        --cache=*) cache=\${1#--cache=} ;;
    esac
    shift
done
/bin/mkdir -p "$cache"
printf '%s\\n' "$command" >> "$cache/fixture-writes"
case "$command" in
    --version) /bin/cat "$FIXTURE_NPM_VERSION" ;;
    install) printf 'npm-install\\n' >> "$FIXTURE_CALLS"; printf '11.16.0\\n' > "$FIXTURE_NPM_VERSION" ;;
    *) exit 1 ;;
esac`);
        if (npmEnvNode) {
            const npm = path.join(payload, 'bin/npm');
            writeFileSync(npm, readFileSync(npm, 'utf8').replace('#!/bin/sh', '#!/usr/bin/env node'));
        }
        filesystem.copyFileSync(path.join(payload, 'bin/node'), path.join(prefix, 'bin/node'));
        if (npmPresent) { filesystem.copyFileSync(path.join(payload, 'bin/npm'), path.join(prefix, 'bin/npm')); }
        execFileSync('/usr/bin/tar', ['-czf', archive, '-C', root, path.basename(payload)]);
        const digest = validChecksum ? createHash('sha256').update(readFileSync(archive)).digest('hex') : '0'.repeat(64);
        writeFileSync(checksums, `${digest}  node-v24.22.0-darwin-arm64.tar.gz\n`);
        const curl = path.join(root, 'fixture-curl');
        script(curl, `
input=''
destination=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        https://*/SHASUMS256.txt) input="$FIXTURE_CHECKSUMS" ;;
        https://*/node-*.tar.gz) input="$FIXTURE_ARCHIVE" ;;
        -o) shift; destination="$1" ;;
    esac
    shift
done
[ -n "$input" ] && [ -n "$destination" ]
printf 'download\\n' >> "$FIXTURE_CALLS"
/bin/cp "$input" "$destination"`);
        const start = source.indexOf('export PATH=/usr/local/bin:');
        const end = source.indexOf('\nif [ ! -x /usr/local/bin/jq ]', start);
        assert.ok(start >= 0 && end > start);
        const bootstrap = source.slice(start, end).replaceAll('/usr/local', quote(prefix)).replaceAll('/usr/bin/curl', quote(curl));
        const program = `set -eu\nfail() { printf '%s\\n' "$*" >&2; exit 1; }\n${bootstrap}`;
        const run = () => execFileSync('/bin/sh', ['-c', program], {encoding: 'utf8', timeout: 10000,
            env: {PATH: '/usr/bin:/bin', node_version: '24.22.0', npm_version: '11.16.0', node_arch: 'arm64',
                HOME: userHome, npm_config_cache: inheritedCache,
                temporary_directory: downloads, FIXTURE_ARCHIVE: archive, FIXTURE_CHECKSUMS: checksums,
                FIXTURE_CALLS: calls, FIXTURE_NPM_VERSION: version}});
        operation({run, calls: () => readFileSync(calls, 'utf8'), npm: path.join(prefix, 'bin/npm'),
            userState: () => ({home: filesystem.readdirSync(userHome), cache: filesystem.readdirSync(inheritedCache)}),
            privateCacheWrites: () => readFileSync(path.join(downloads, 'npm-cache/fixture-writes'), 'utf8'),
            version: () => readFileSync(version, 'utf8').trim()});
    } finally { rmSync(root, {recursive: true, force: true}); }
}

test('root npm install and version probes override inherited user cache settings with private staging', () => {
    nodeBootstrapFixture({npmPresent: true}, ({run, userState, privateCacheWrites}) => {
        run();
        assert.deepEqual(userState(), {home: [], cache: []});
        assert.deepEqual(privateCacheWrites().trim().split('\n'), ['--version', '--version', 'install', '--version']);
    });
});

test('missing npm is restored from the verified Node archive before upgrading npm', () => {
    nodeBootstrapFixture({}, ({run, calls, npm, version}) => {
        run();
        assert.equal(filesystem.existsSync(npm), true);
        assert.equal(version(), '11.16.0');
        assert.equal(calls(), 'download\ndownload\nnpm-install\n');
    });
});

test('an executable but unusable npm is restored from the verified Node archive', () => {
    nodeBootstrapFixture({npmPresent: true}, ({run, calls, npm, version}) => {
        writeFileSync(npm, '#!/bin/sh\nexit 23\n');
        run();
        assert.equal(version(), '11.16.0');
        assert.equal(calls(), 'download\ndownload\nnpm-install\n');
    });
});

test('npm health checks resolve its env node shebang before deciding to reinstall', () => {
    nodeBootstrapFixture({npmPresent: true, npmVersion: '11.16.0', npmEnvNode: true}, ({run, calls}) => {
        run();
        assert.equal(calls(), '');
    });
});

test('complete pinned tools avoid reinstallation and older npm upgrades without replacing Node', () => {
    for (const npmVersion of ['11.16.0', '11.15.0']) {
        nodeBootstrapFixture({npmPresent: true, npmVersion}, ({run, calls, version}) => {
            run();
            assert.equal(version(), '11.16.0');
            assert.equal(calls(), npmVersion === '11.16.0' ? '' : 'npm-install\n');
        });
    }
});

test('missing npm repair refuses an archive with an invalid checksum', () => {
    nodeBootstrapFixture({validChecksum: false}, ({run, calls, npm}) => {
        assert.throws(run, error => error.status === 1 && /checksum did not match/.test(error.stderr));
        assert.equal(filesystem.existsSync(npm), false);
        assert.equal(calls(), 'download\ndownload\n');
    });
});

test('the receipt permits only the unique unformatted sidecar, preserving boot and Recovery', () => {
    assert.equal(select([boot, blank], 'disk0', capacity, true), 'disk1');
    assert.deepEqual(boot.Partitions.map(partition => partition.Content), ['Apple_APFS_ISC', 'Apple_APFS', 'Apple_APFS_Recovery']);
});

test('a boot disk matching the sidecar size is never selected', () => {
    assert.throws(() => select([{...blank, DeviceIdentifier: 'disk0'}], 'disk0', capacity, true), /exactly one/);
    assert.equal(select([{...blank, DeviceIdentifier: 'disk0'}, blank], 'disk0', capacity, true), 'disk1');
});

test('formatting refuses absent receipts, ambiguous devices, and the wrong capacity', () => {
    for (const receipt of [undefined, false, 'true', 1]) {
        assert.throws(() => select([boot, blank], 'disk0', capacity, receipt), /receipt/);
    }
    assert.throws(() => select([boot, blank, {...blank, DeviceIdentifier: 'disk2'}], 'disk0', capacity, true), /exactly one/);
    assert.throws(() => select([boot, {...blank, Size: capacity - 512}], 'disk0', capacity, true), /exactly one/);
    assert.throws(() => select([boot, blank], 'disk0', 96_000_000_000, true), /specification/);
});

test('recognized filesystems and any partition table are not candidates', () => {
    for (const existing of [
        {...blank, Content: 'GUID_partition_scheme', Partitions: []},
        {...blank, Content: 'Apple_APFS'},
        {...blank, Content: 'Apple_HFS'},
        {...blank, Partitions: [{DeviceIdentifier: 'disk1s1'}]},
        {...blank, Partitions: false},
        {...blank, Partitions: {}},
        {...blank, DeviceIdentifier: '/dev/disk1'},
    ]) {
        assert.throws(() => select([boot, existing], 'disk0', capacity, true), /exactly one/);
    }
});

test('both complete edge samples must be zero before formatting', () => {
    assert.doesNotThrow(() => validate(details, samples(), capacity));
    for (const index of [0, 1]) {
        const value = samples();
        value[index][value[index].length - 1] = 1;
        assert.throws(() => validate(details, value, capacity), /not blank/);
    }
    assert.throws(() => validate(details, [Buffer.alloc(512), Buffer.alloc(1024 * 1024)], capacity), /not blank/);
    assert.throws(() => validate(details, [], capacity), /not blank/);
});

test('physical-device details must still match after disk enumeration', () => {
    for (const changed of [{...details, WholeDisk: false}, {...details, TotalSize: capacity + 512}, {...details, FilesystemType: 'apfs'}]) {
        assert.throws(() => validate(changed, samples(), capacity), /not blank/);
    }
});

test('managed build-volume protection removes group write only on the verified root', () => {
    const changes = [];
    const metadata = {uid: 0, gid: 80, mode: 0o40775, isDirectory: () => true, isSymbolicLink: () => false};
    const protect = pureFunction('protectBuildVolumeRoot', {
        check: (condition, message) => { if (!condition) throw new Error(message); },
        fs: {
            lstatSync: () => metadata, realpathSync: filename => filename,
            chmodSync: (filename, mode) => { changes.push([filename, mode]); metadata.mode = 0o40000 | mode; },
            chownSync: () => { throw new Error('Ownership must not be rewritten'); },
        },
    });
    protect('/Volumes/BigWalletBuild');
    protect('/Volumes/BigWalletBuild');
    assert.deepEqual(changes, [['/Volumes/BigWalletBuild', 0o755]]);
    assert.equal(metadata.gid, 80);
});

test('an already protected managed volume root receives no chmod', () => {
    const protect = pureFunction('protectBuildVolumeRoot', {
        check: (condition, message) => { if (!condition) throw new Error(message); },
        fs: {
            lstatSync: () => ({uid: 0, mode: 0o40755, isDirectory: () => true, isSymbolicLink: () => false}),
            realpathSync: filename => filename,
            chmodSync: () => { throw new Error('Correct mode must be left alone'); },
        },
    });
    assert.doesNotThrow(() => protect('/Volumes/BigWalletBuild'));
});

test('build-volume protection rejects unrelated paths, ownership, symlinks, and nondirectories without mutation', () => {
    for (const change of [{uid: 501}, {uid: 99}, {isDirectory: () => false}, {isSymbolicLink: () => true}, {canonical: '/elsewhere'}]) {
        const protect = pureFunction('protectBuildVolumeRoot', {
            check: (condition, message) => { if (!condition) throw new Error(message); },
            fs: {
                lstatSync: () => ({uid: 0, mode: 0o40775, isDirectory: () => true, isSymbolicLink: () => false, ...change}),
                realpathSync: filename => change.canonical ?? filename,
                chmodSync: () => { throw new Error('Invalid root must not be changed'); },
            },
        });
        assert.throws(() => protect('/Volumes/BigWalletBuild'), /real root-owned directory/);
        assert.throws(() => protect('/Volumes/OtherVolume'), /Only the managed/);
    }
});

function buildInitializationFixture() {
    const state = '/guest-state';
    const intentPath = `${state}/build-data-initialization.json`;
    const nonce = '11111111-2222-4333-8444-555555555555';
    const volumeUUID = 'AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE';
    const config = {vmId: 'fixture-vm', initializeBuildData: true, buildData: {bytes: capacity, volumeName: 'BigWalletBuild'}};
    const nodes = new Map([[state, {kind: 'directory', uid: 0, mode: 0o750}]]);
    const fixture = {state, intentPath, nonce, volumeUUID, config, nodes, volumes: [], events: [], formatted: false};
    const checkpoint = phase => {
        if (fixture.failure === phase && !fixture.failed) {
            fixture.failed = true;
            throw new Error(`fixture interruption: ${phase}`);
        }
    };
    const locate = filename => {
        if (nodes.has(filename)) return nodes.get(filename);
        for (const volume of fixture.volumes) {
            if (filename === volume.MountPoint) return volume.root;
            if (volume.MountPoint && filename.startsWith(volume.MountPoint + '/')) return volume.files.get(filename.slice(volume.MountPoint.length + 1));
        }
    };
    const metadata = node => ({...node, size: node.content?.length ?? 0,
        isDirectory: () => node.kind === 'directory', isFile: () => node.kind === 'file', isSymbolicLink: () => node.kind === 'symlink'});
    fixture.addVolume = (name, changes = {}) => {
        const volume = {Name: name, APFSVolumeUUID: volumeUUID, DeviceIdentifier: 'disk2s1', store: 'disk1s2', whole: 'disk1', bytes: capacity,
            MountPoint: `/Volumes/${name}`, root: {kind: 'directory', uid: 0, mode: 0o775}, files: new Map(), ...changes};
        fixture.volumes.push(volume);
        fixture.formatted = true;
        return volume;
    };
    fixture.intent = changes => {
        const value = {version: 1, vmId: config.vmId, bytes: capacity, nonce, ...changes};
        nodes.set(intentPath, {kind: 'file', uid: 0, mode: 0o600, content: JSON.stringify(value)});
        return value;
    };
    fixture.marker = (volume, changes = {}) => volume.files.set('.big-wallet-vm.json', {kind: 'file', uid: 0, mode: 0o644,
        content: JSON.stringify({version: 1, vmId: config.vmId, volumeUUID: volume.APFSVolumeUUID, ...changes})});
    const fs = {
        lstatSync(filename, options) {
            const node = locate(filename);
            if (node) return metadata(node);
            if (options?.throwIfNoEntry === false) return undefined;
            throw Object.assign(new Error('missing fixture path'), {code: 'ENOENT'});
        },
        realpathSync: filename => locate(filename)?.target ?? filename,
        readFileSync: filename => locate(filename).content,
        openSync: filename => { assert.match(filename, /^\/dev\/rdisk\d+$/); return 7; },
        readSync: (_fd, bytes) => { bytes.fill(0); return bytes.length; }, closeSync() {},
        chmodSync(filename, mode) { locate(filename).mode = mode; fixture.events.push(['protect', filename]); },
        unlinkSync(filename) {
            assert.equal(filename, intentPath);
            checkpoint('before-retire');
            nodes.delete(filename);
            fixture.events.push(['retire']);
            checkpoint('after-retire');
        },
    };
    const globals = {Buffer, path, fs, config, state, check, crypto: {randomUUID: () => nonce}, console: {log() {}},
        selectBlankBuildDisk: select, validateBlankBuildDisk: validate,
        syncDirectory: directory => fixture.events.push(['sync', directory]),
        writeDurableJSON(filename, value, mode) {
            if (filename === intentPath) {
                checkpoint(value.volumeUUID ? 'before-uuid' : 'before-intent');
                nodes.set(filename, {kind: 'file', uid: 0, mode, content: JSON.stringify(value)});
                fixture.events.push(['intent', {...value}]);
            } else {
                checkpoint('before-marker');
                const volume = fixture.volumes.find(item => filename === `${item.MountPoint}/.big-wallet-vm.json`);
                assert.ok(volume);
                assert.equal(volume.root.mode, 0o755);
                assert.equal(JSON.parse(nodes.get(intentPath).content).volumeUUID, volume.APFSVolumeUUID);
                volume.files.set('.big-wallet-vm.json', {kind: 'file', uid: 0, mode, content: JSON.stringify(value)});
                fixture.events.push(['marker', volume.APFSVolumeUUID]);
                checkpoint('after-marker');
            }
        },
        diskMetadata(args) {
            if (args[0] === 'apfs') return {Containers: fixture.volumes.map(volume => ({PhysicalStores: [{DeviceIdentifier: volume.store}],
                Volumes: [{Name: volume.Name, DeviceIdentifier: volume.DeviceIdentifier, APFSVolumeUUID: volume.APFSVolumeUUID}]}))};
            if (args[0] === 'list') return {AllDisksAndPartitions: [{...blank, ...(fixture.formatted ? {Content: 'GUID_partition_scheme', Partitions: [{}]} : {})}]};
            const device = args.at(-1);
            if (device === '/') return {APFSPhysicalStores: [{APFSPhysicalStore: 'disk0s2'}]};
            if (device === 'disk0s2') return {ParentWholeDisk: 'disk0'};
            const stored = fixture.volumes.find(volume => volume.store === device);
            if (stored) return {ParentWholeDisk: stored.whole};
            const whole = fixture.volumes.find(volume => volume.whole === device);
            if (whole) return {TotalSize: whole.bytes};
            const volume = fixture.volumes.find(volume => volume.DeviceIdentifier === device);
            if (volume) return {MountPoint: volume.MountPoint};
            if (device === 'disk1') return details;
            throw new Error(`Unexpected fixture device: ${device}`);
        },
        run(_label, command, args) {
            assert.equal(command, '/usr/sbin/diskutil');
            if (args[0] === 'eraseDisk') {
                checkpoint('before-format');
                assert.equal(args[2], `BigWalletInit-${JSON.parse(nodes.get(intentPath).content).nonce}`);
                assert.equal(fixture.formatted, false);
                fixture.events.push(['format', args[2]]);
                fixture.addVolume(args[2]);
                checkpoint('after-format');
                return;
            }
            const volume = fixture.volumes.find(item => item.DeviceIdentifier === args[1]);
            assert.ok(volume);
            if (args[0] === 'mount') {
                checkpoint(volume.Name === 'BigWalletBuild' && !volume.MountPoint ? 'before-remount' : 'before-mount');
                volume.MountPoint ??= `/Volumes/${volume.Name}`;
            } else if (args[0] === 'enableOwnership') checkpoint('before-ownership');
            else if (args[0] === 'renameVolume') {
                checkpoint('before-rename');
                assert.equal(JSON.parse(volume.files.get('.big-wallet-vm.json').content).volumeUUID, volume.APFSVolumeUUID);
                assert.equal(JSON.parse(nodes.get(intentPath).content).volumeUUID, volume.APFSVolumeUUID);
                volume.Name = args[2];
                checkpoint('after-rename');
            } else if (args[0] === 'unmount') {
                checkpoint('before-unmount');
                volume.MountPoint = null;
            } else throw new Error(`Unexpected fixture operation: ${args[0]}`);
            fixture.events.push([args[0], args[1]]);
        },
    };
    for (const name of ['readBuildInitializationIntent', 'verifyBuildIdentity', 'protectBuildVolumeRoot']) globals[name] = pureFunction(name, globals);
    fixture.prepare = pureFunction('prepareBuildData', globals);
    return fixture;
}

test('initialization retries every committed boundary without reformatting or changing its nonce', () => {
    const phases = ['before-intent', 'before-format', 'after-format', 'before-uuid', 'before-mount', 'before-ownership',
        'before-marker', 'after-marker', 'before-rename', 'after-rename', 'before-unmount', 'before-remount', 'before-retire', 'after-retire'];
    for (const phase of phases) {
        const fixture = buildInitializationFixture();
        fixture.failure = phase;
        assert.throws(fixture.prepare, /fixture interruption/, phase);
        assert.equal(fixture.prepare(), '/Volumes/BigWalletBuild', phase);
        assert.deepEqual(fixture.events.filter(event => event[0] === 'format'), [['format', `BigWalletInit-${fixture.nonce}`]], phase);
        assert.equal(fixture.volumes[0].Name, 'BigWalletBuild');
        assert.equal(fixture.volumes[0].root.mode, 0o755);
        assert.equal(JSON.parse(fixture.volumes[0].files.get('.big-wallet-vm.json').content).volumeUUID, fixture.volumeUUID);
        assert.equal(fixture.nodes.has(fixture.intentPath), false);
    }
});

test('pending volume recovery follows its UUID across device renumbering', () => {
    const fixture = buildInitializationFixture();
    fixture.failure = 'before-ownership';
    assert.throws(fixture.prepare, /fixture interruption/);
    Object.assign(fixture.volumes[0], {whole: 'disk4', store: 'disk4s2', DeviceIdentifier: 'disk5s1'});
    assert.equal(fixture.prepare(), '/Volumes/BigWalletBuild');
    assert.equal(fixture.events.filter(event => event[0] === 'format').length, 1);
    assert.ok(fixture.events.some(event => event[0] === 'renameVolume' && event[1] === 'disk5s1'));
});

test('completed pending initialization retires its intent without unmounting an in-use final path', () => {
    const fixture = buildInitializationFixture();
    fixture.intent({volumeUUID: fixture.volumeUUID});
    fixture.marker(fixture.addVolume('BigWalletBuild'));
    assert.equal(fixture.prepare(), '/Volumes/BigWalletBuild');
    assert.equal(fixture.events.some(event => ['format', 'renameVolume', 'unmount'].includes(event[0])), false);
    assert.equal(fixture.nodes.has(fixture.intentPath), false);
});

test('invalid or foreign initialization intents are preserved before any disk mutation', () => {
    for (const change of [{version: 2}, {vmId: 'other-vm'}, {bytes: capacity - 1}, {nonce: '../outside'}, {volumeUUID: 'invalid'}, {unexpected: true}]) {
        const fixture = buildInitializationFixture();
        fixture.intent(change);
        assert.throws(fixture.prepare, /invalid or belongs to another VM/);
        assert.deepEqual(fixture.events, []);
        assert.equal(fixture.nodes.has(fixture.intentPath), true);
    }
    for (const change of [{kind: 'symlink'}, {uid: 501}, {mode: 0o644}]) {
        const fixture = buildInitializationFixture();
        fixture.intent();
        Object.assign(fixture.nodes.get(fixture.intentPath), change);
        assert.throws(fixture.prepare, /private root-owned file/);
        assert.deepEqual(fixture.events, []);
    }
});

test('recovery rejects conflicting final names and duplicate nonce or UUID volumes', () => {
    for (const conflict of ['final-name', 'nonce', 'uuid']) {
        const fixture = buildInitializationFixture();
        fixture.intent({volumeUUID: fixture.volumeUUID});
        fixture.addVolume(`BigWalletInit-${fixture.nonce}`);
        fixture.addVolume(conflict === 'final-name' ? 'BigWalletBuild' : conflict === 'nonce' ? `BigWalletInit-${fixture.nonce}` : 'Other',
            {APFSVolumeUUID: conflict === 'uuid' ? fixture.volumeUUID : 'FFFFFFFF-EEEE-4DDD-8CCC-BBBBBBBBBBBB',
                DeviceIdentifier: 'disk7s1', store: 'disk6s2', whole: 'disk6'});
        assert.throws(fixture.prepare, /ambiguous|unrelated BigWalletBuild/);
        assert.deepEqual(fixture.events, []);
    }
});

test('unidentified partial formatting and unrelated existing volumes are never adopted or erased', () => {
    for (const existing of ['partial', 'final-unmarked', 'nonce-without-intent', 'boot', 'wrong-size']) {
        const fixture = buildInitializationFixture();
        if (existing === 'partial') { fixture.intent(); fixture.formatted = true; }
        else {
            const volume = fixture.addVolume(existing === 'nonce-without-intent' ? `BigWalletInit-${fixture.nonce}` : 'BigWalletBuild');
            if (existing === 'boot') volume.whole = 'disk0';
            if (existing === 'wrong-size') volume.bytes -= 1;
        }
        assert.throws(fixture.prepare, /exactly one|no managed-volume identity|managed nonboot/);
        assert.equal(fixture.events.some(event => ['format', 'marker', 'renameVolume', 'retire', 'protect'].includes(event[0])), false);
    }
});

test('durable initialization records sync file metadata before rename and the containing directory after it', () => {
    const events = [];
    const fs = {openSync: (filename, flags) => { events.push(['open', filename, flags]); return flags === 'r' ? 2 : 1; },
        writeFileSync: () => events.push(['write']), fchmodSync: () => events.push(['mode']), fchownSync: () => events.push(['owner']),
        fsyncSync: descriptor => events.push(['sync', descriptor]), closeSync: descriptor => events.push(['close', descriptor]),
        renameSync: () => events.push(['rename']), rmSync: () => events.push(['cleanup'])};
    const syncDirectory = pureFunction('syncDirectory', {fs});
    const write = pureFunction('writeDurableJSON', {fs, path, crypto: {randomUUID: () => 'fixture'}, syncDirectory});
    write('/state/intent.json', {version: 1}, 0o600);
    assert.ok(events.findIndex(event => event[0] === 'sync' && event[1] === 1) < events.findIndex(event => event[0] === 'rename'));
    assert.ok(events.findIndex(event => event[0] === 'rename') < events.findIndex(event => event[0] === 'sync' && event[1] === 2));
});

test('build-root permissions are changed only after the existing sidecar identity is accepted', () => {
    const fixture = buildInitializationFixture();
    const volume = fixture.addVolume('BigWalletBuild');
    fixture.marker(volume);
    assert.equal(fixture.prepare(), '/Volumes/BigWalletBuild');
    assert.ok(fixture.events.some(event => event[0] === 'protect'));
    for (const change of [{vmId: 'other-vm'}, {volumeUUID: 'other-volume'}]) {
        fixture.events.length = 0;
        fixture.marker(volume, change);
        assert.throws(fixture.prepare, /belongs to another VM/);
        assert.equal(fixture.events.some(event => event[0] === 'protect'), false);
    }
});

function signingImportFixture(operation) {
    const root = mkdtempSync(path.join(tmpdir(), 'big-wallet-signing-input-'));
    const filename = path.join(root, 'identity.p12');
    const payload = Buffer.from([0x30, 0x82, 0x00, 0xff, 0x80, 0x0a, 0x00, 0x42]);
    const descriptors = [];
    let imported;
    let stderr = '';
    try {
        filesystem.chmodSync(root, 0o700);
        writeFileSync(filename, payload, {mode: 0o600});
        const metadata = filesystem.statSync(filename);
        const globals = {check, environment: {}, uidText: '502', config: {consoleUser: 'wallet-test'},
            fail: message => { throw new Error(message); }, process: {stderr: {write: value => { stderr += value; }}},
            fs: {...filesystem,
                openSync(...args) { const descriptor = filesystem.openSync(...args); descriptors.push(descriptor); return descriptor; },
                fstatSync(descriptor) { const value = filesystem.fstatSync(descriptor); value.uid = 0; return value; },
            },
            spawnSync(command, args, options) {
                assert.equal(command, '/bin/launchctl');
                assert.deepEqual(Array.from(args).slice(0, 7), ['asuser', '502', '/usr/bin/sudo', '-H', '-u', 'wallet-test', '/usr/bin/security']);
                assert.deepEqual(Array.from(args).slice(7, 11), ['import', '/dev/stdin', '-f', 'pkcs12']);
                assert.equal(options.input, undefined);
                assert.deepEqual(Array.from(options.stdio), [descriptors.at(-1), 'pipe', 'pipe']);
                assert.equal(filesystem.fstatSync(options.stdio[0]).size, payload.length);
                return imported(options);
            }};
        globals.run = pureFunction('run', globals);
        const importIdentity = pureFunction('importSigningIdentity', globals);
        operation({filename, payload, globals,
            invoke: () => importIdentity(filename, '/fixture/dedicated.keychain-db', 'fixture-p12-password'),
            importer: operation => { imported = operation; },
            stderr: () => stderr,
            descriptors,
        });
        assert.equal(readFileSync(filename).equals(payload), true);
        const after = filesystem.statSync(filename);
        assert.deepEqual([after.uid, after.gid, after.mode], [metadata.uid, metadata.gid, metadata.mode]);
        assert.equal(filesystem.statSync(root).mode & 0o777, 0o700);
        assert.deepEqual(filesystem.readdirSync(root), ['identity.p12']);
        for (const descriptor of descriptors) assert.throws(() => filesystem.fstatSync(descriptor), {code: 'EBADF'});
    } finally { rmSync(root, {recursive: true, force: true}); }
}

test('signing import hands a regular binary descriptor to the selected user without copying or exposing staging', () => {
    signingImportFixture(fixture => {
        fixture.importer(options => {
            const result = spawnSync(process.execPath, ['-e', `
                const fs = require('node:fs');
                const fd = fs.openSync('/dev/stdin', 'r');
                const metadata = fs.fstatSync(fd);
                if (!metadata.isFile()) process.exit(1);
                const contents = Buffer.alloc(metadata.size);
                if (fs.readSync(fd, contents, 0, contents.length, null) !== contents.length) process.exit(2);
                fs.closeSync(fd);
                process.stdout.write(require('node:crypto').createHash('sha256').update(contents).digest('hex'));
            `], {...options, env: process.env, timeout: 5000, killSignal: 'SIGKILL'});
            assert.equal(result.status, 0, result.stderr);
            assert.equal(result.stdout, createHash('sha256').update(fixture.payload).digest('hex'));
            return result;
        });
        fixture.invoke();
        assert.equal(fixture.stderr(), '');
    });
});

test('signing import closes its descriptor on failure, launch exceptions and cancellation without logging secrets', () => {
    for (const outcome of ['failed', 'launch-error', 'cancelled']) {
        signingImportFixture(fixture => {
            fixture.importer(() => {
                if (outcome === 'launch-error') throw new Error('fixture launch failure');
                return {status: outcome === 'failed' ? 1 : null, signal: outcome === 'cancelled' ? 'SIGTERM' : null,
                    stdout: '', stderr: 'fixture-p12-password private identity bytes'};
            });
            assert.throws(fixture.invoke, /failed|fixture launch failure/);
            assert.equal(fixture.stderr(), '');
        });
    }
});

test('signing import rejects exposed, non-root, nonregular and symlink inputs before launching', () => {
    for (const change of [metadata => { metadata.uid = 502; }, metadata => { metadata.mode |= 0o040; },
        metadata => { metadata.isFile = () => false; }]) {
        signingImportFixture(fixture => {
            const original = fixture.globals.fs.fstatSync;
            fixture.globals.fs.fstatSync = descriptor => { const metadata = original(descriptor); change(metadata); return metadata; };
            fixture.importer(() => assert.fail('An invalid identity must not reach the importer'));
            assert.throws(fixture.invoke, /private root-owned file/);
        });
    }
    signingImportFixture(fixture => {
        const link = `${fixture.filename}.link`;
        symlinkSync(fixture.filename, link);
        try {
            fixture.importer(() => assert.fail('A linked identity must not reach the importer'));
            const importIdentity = pureFunction('importSigningIdentity', fixture.globals);
            assert.throws(() => importIdentity(link, '/fixture/keychain', 'fixture-password'), {code: 'ELOOP'});
        } finally { rmSync(link); }
    });
});

test('command descriptors reject ambiguous input and leave ordinary command input unchanged', () => {
    const calls = [];
    const run = pureFunction('run', {check, environment: {},
        spawnSync(...arguments_) { calls.push(arguments_); return {status: 0, stdout: 'passed'}; }});
    for (const inputFD of [-1, null, '0', 1.5]) assert.throws(() => run('fixture', '/fixture', [], {inputFD}), /descriptor/);
    assert.throws(() => run('fixture', '/fixture', [], {inputFD: 0, input: Buffer.from('fixture')}), /cannot be combined/);
    assert.equal(calls.length, 0);
    run('fixture', '/fixture', []);
    const input = Buffer.from('ordinary stdin');
    run('fixture', '/fixture', [], {input});
    assert.equal(calls[0][2].stdio, undefined);
    assert.equal(calls[0][2].input, undefined);
    assert.equal(calls[1][2].stdio, undefined);
    assert.equal(calls[1][2].input, input);
});

test('failed identity import does not acknowledge signing and a retry can complete the same request', () => {
    signingImportFixture(fixture => {
        const request = {provisioningRequestID: '12345678-1234-1234-1234-123456789abc', signing: {p12Path: 'identity.p12'}};
        const previous = {appliedProvisioningRequestID: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'};
        fixture.importer(() => ({status: 1, stdout: '', stderr: 'private import error'}));
        const apply = () => optionalSigning(() => ({proofKey: 'fixture-proof'}), () => {
            fixture.invoke();
            return {keychainPath: '/fixture/dedicated.keychain-db', keychainPassword: 'fixture-password'};
        });
        const failed = apply();
        assert.equal(appliedRequest(request, previous, failed.appliedCapabilities), previous.appliedProvisioningRequestID);
        assert.equal(failed.fields.keychainPath, undefined);
        fixture.importer(() => ({status: 0, stdout: 'imported', stderr: ''}));
        const retried = apply();
        assert.equal(appliedRequest(request, previous, retried.appliedCapabilities), request.provisioningRequestID);
        assert.deepEqual(Array.from(retried.missingSigning), []);
    });
    assert.match(source, /importSigningIdentity\(p12, keychainPath, p12Password\);\n\s*fs\.writeFileSync\(importMarker/);
});

test('missing signing does not discard an independently validated proof key', () => {
    const result = optionalSigning(() => ({proofKey: 'validated-fixture'}), () => { throw new Error('No development identity'); });
    assert.equal(result.fields.proofKey, 'validated-fixture');
    assert.equal(result.fields.keychainPath, undefined);
    assert.equal(result.missingSigning.length, 1);
    assert.match(result.missingSigning[0], /development signing: No development identity/);
});

test('base-only provisioning reports both missing capabilities without fabricated credentials', () => {
    const result = optionalSigning(() => { throw new Error('Not supplied'); }, () => { throw new Error('Not supplied'); });
    assert.deepEqual(Object.keys(result.fields), []);
    assert.equal(result.missingSigning.length, 2);
});

test('failed optional credential updates preserve prior values without acknowledging the new request', () => {
    const prior = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
    const next = '12345678-1234-1234-1234-123456789abc';
    const previous = {proofKey: 'validated-proof', keychainPath: '/guest/dedicated.keychain-db',
        keychainPassword: 'validated-password', appliedProvisioningRequestID: prior, unrelated: 'do not copy'};
    const config = {provisioningRequestID: next, signing: {proofKeyFile: 'proof', keychainPasswordFile: 'password'}};
    for (const failed of ['proof', 'signing', 'both']) {
        const result = optionalSigning(
            () => { if (failed !== 'signing') throw new Error('Proof update failed'); return {proofKey: 'new-proof'}; },
            () => { if (failed !== 'proof') throw new Error('Signing update failed'); return {keychainPath: previous.keychainPath, keychainPassword: 'new-password'}; },
            previous);
        assert.equal(result.fields.proofKey, failed === 'signing' ? 'new-proof' : previous.proofKey);
        assert.equal(result.fields.keychainPassword, failed === 'proof' ? 'new-password' : previous.keychainPassword);
        assert.equal(result.fields.keychainPath, previous.keychainPath);
        assert.equal(result.fields.unrelated, undefined);
        assert.equal(result.fields.appliedProvisioningRequestID, undefined);
        assert.equal(result.missingSigning.length, failed === 'both' ? 2 : 1);
        assert.equal(appliedRequest(config, previous, result.appliedCapabilities), prior);
    }
    assert.equal(previous.proofKey, 'validated-proof');
    assert.equal(previous.keychainPassword, 'validated-password');
});

test('a retry can reuse credentials retained after a transient signing failure', () => {
    const prior = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
    const next = '12345678-1234-1234-1234-123456789abc';
    const previous = {proofKey: 'validated-proof', keychainPath: '/guest/dedicated.keychain-db',
        keychainPassword: 'validated-password', appliedProvisioningRequestID: prior};
    const config = {provisioningRequestID: next, signing: {profiles: ['updated.provisionprofile']}};
    const failed = optionalSigning(() => ({proofKey: previous.proofKey}), () => { throw new Error('Profile copy unavailable'); }, previous);
    const retained = {...failed.fields, appliedProvisioningRequestID: appliedRequest(config, previous, failed.appliedCapabilities)};
    const retried = optionalSigning(() => ({proofKey: retained.proofKey}), () => {
        assert.equal(retained.keychainPassword, 'validated-password');
        return {keychainPath: retained.keychainPath, keychainPassword: retained.keychainPassword};
    }, retained);
    assert.equal(appliedRequest(config, retained, retried.appliedCapabilities), next);
    assert.equal(retried.missingSigning.length, 0);
    assert.deepEqual(Array.from(retried.appliedCapabilities), ['request-proof key', 'development signing']);
    assert.match(source, /return \{keychainPath, keychainPassword\};\n\s*}, previous\);/);
});

test('a provisioning receipt requires successful explicit signing and proof inputs', () => {
    const current = '12345678-1234-1234-1234-123456789abc';
    const prior = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
    const previous = {appliedProvisioningRequestID: prior};
    const request = signing => ({provisioningRequestID: current, signing});
    assert.equal(appliedRequest(request({proofKeyFile: 'proof'}), previous, ['request-proof key']), current);
    assert.equal(appliedRequest(request({proofKeyFile: 'proof'}), previous, []), prior);
    for (const field of ['p12Path', 'p12PasswordFile', 'keychainPasswordFile', 'profiles']) {
        const config = request({[field]: field === 'profiles' ? ['profile.mobileprovision'] : 'input'});
        assert.equal(appliedRequest(config, previous, ['development signing']), current);
        assert.equal(appliedRequest(config, previous, ['request-proof key']), prior);
    }
    const failed = optionalSigning(() => ({proofKey: 'fixture'}), () => { throw new Error('Explicit update failed'); });
    assert.equal(appliedRequest(request({proofKeyFile: 'proof', p12Path: 'identity'}), previous, failed.appliedCapabilities), prior);
    assert.equal(appliedRequest(request({proofKeyFile: 'proof', p12Path: 'identity'}), undefined, failed.appliedCapabilities), undefined);
});

test('unrequested missing signing does not prevent a completed account or proof receipt', () => {
    const identifier = '12345678-1234-1234-1234-123456789abc';
    const unavailable = optionalSigning(() => { throw new Error('Not supplied'); }, () => { throw new Error('Not supplied'); });
    assert.equal(appliedRequest({provisioningRequestID: identifier}, undefined, unavailable.appliedCapabilities), identifier);
    const proofOnly = optionalSigning(() => ({proofKey: 'fixture'}), () => { throw new Error('Not supplied'); });
    assert.equal(appliedRequest({provisioningRequestID: identifier, signing: {proofKeyFile: 'proof'}}, undefined,
        proofOnly.appliedCapabilities), identifier);
    assert.equal(appliedRequest({}, {appliedProvisioningRequestID: identifier}, []), identifier);
    for (const provisioningRequestID of [null, '', {}, '../other', 'not-a-receipt']) {
        assert.throws(() => appliedRequest({provisioningRequestID}, undefined, []), /identity is invalid/);
    }
});

test('provisioning leaves protected system simulator directories to Xcode', () => {
    assert.doesNotMatch(source, /relocateDirectory\(['"]\/Library\/Developer\/CoreSimulator/);
    assert.doesNotMatch(source, /csrutil\s+disable/);
    assert.match(source, /\['-runFirstLaunch'\]/);
    assert.match(source, /'-downloadPlatform', wanted\.platform, '-exportPath', downloads/);
});

test('UI automation provisioning uses the supported guest administrator tool and verifies the selected user', () => {
    const calls = [];
    const configure = pureFunction('configureUIAutomation', {check, run(label, file, args, options = {}) {
        calls.push({file, args: [...args], user: options.user ?? false, timeout: options.timeout, killSignal: options.killSignal});
        return args.length ? 'succeeded.' : 'Automation Mode is disabled.\nThis device DOES NOT REQUIRE user authentication to enable Automation Mode.';
    }});
    configure();
    assert.deepEqual(calls, [
        {file: '/usr/bin/automationmodetool', args: ['enable-automationmode-without-authentication'], user: false, timeout: 30000, killSignal: 'SIGKILL'},
        {file: '/usr/bin/automationmodetool', args: [], user: true, timeout: 10000, killSignal: 'SIGKILL'},
    ]);
    assert.ok(source.indexOf('    configureUIAutomation();') > source.indexOf("['-runFirstLaunch']"));
    assert.doesNotMatch(source, /TCC\.db|authorizationdb\s+write|tccutil\s+reset/);
});

test('UI automation provisioning rejects required authentication even when automation is already enabled', () => {
    for (const status of [
        'Automation Mode is ENABLED.\nThis device requires user authentication to enable Automation Mode.',
        'Automation Mode is ENABLED.', '', 'unexpected output',
    ]) {
        const configure = pureFunction('configureUIAutomation', {check, run: (_label, _file, args) => args.length ? 'succeeded.' : status});
        assert.throws(configure, /still requires authentication.*setup --interactive/);
    }
});

test('UI automation provisioning preserves administrator or selected-user verification failures', () => {
    for (const failureCall of [1, 2]) {
        let calls = 0;
        const configure = pureFunction('configureUIAutomation', {check, run() {
            if (++calls === failureCall) throw new Error('fixture authorization unavailable');
            return 'succeeded.';
        }});
        assert.throws(configure, /fixture authorization unavailable/);
        assert.equal(calls, failureCall);
    }
});

test('created user developer parents have the selected user ownership without recursive permission changes', () => {
    const directories = new Map([['/Users/tester/Library', {owner: 0}]]);
    const fakeFS = {
        lstatSync(filename) {
            if (!directories.has(filename)) throw Object.assign(new Error('missing'), {code: 'ENOENT'});
            return {isDirectory: () => true, isSymbolicLink: () => false};
        },
        mkdirSync(filename) { directories.set(filename, {owner: 0}); },
        chownSync(filename, owner, group) { directories.set(filename, {owner, group}); },
    };
    const ensure = pureFunction('ensureUserDeveloperDirectories', {fs: fakeFS, path});
    ensure('/Users/tester', 501, 20);
    assert.deepEqual([...directories.keys()], ['/Users/tester/Library', '/Users/tester/Library/Developer', '/Users/tester/Library/Developer/Xcode']);
    assert.ok([...directories.values()].every(value => value.owner === 501 && value.group === 20));
    const rejectsSymlink = pureFunction('ensureUserDeveloperDirectories', {path, fs: {...fakeFS,
        lstatSync: () => ({isDirectory: () => false, isSymbolicLink: () => true})}});
    assert.throws(() => rejectsSymlink('/Users/tester', 501, 20), /regular directory/);
});

test('runtime storage guards measure download headroom and a reserve beyond the staged image', () => {
    assert.equal(rootSpaceRequirement(), 16 * 1024 ** 3);
    assert.equal(rootSpaceRequirement(10 * 1024 ** 3), 18 * 1024 ** 3);
    for (const size of [0, -1, 1.5, Number.MAX_SAFE_INTEGER, Infinity]) assert.throws(() => rootSpaceRequirement(size), /size is invalid/);
});

function runtimeProvisioningFixture({platform = 'iOS', reused = false, dmgPath, importedBuild} = {}) {
    const wanted = {platform, version: '27.0', buildVersion: platform === 'iOS' ? '24A434' : '24M362', ...(dmgPath ? {dmgPath} : {})};
    const runtime = {identifier: `com.apple.CoreSimulator.SimRuntime.${platform === 'iOS' ? 'iOS' : 'xrOS'}-27-0`,
        version: wanted.version, buildversion: wanted.buildVersion, isAvailable: true};
    const name = platform === 'iOS' ? 'iPhone 18 Pro' : 'Apple Vision Pro';
    const buildRoot = '/guest/build';
    const staging = '/guest/provision';
    const commands = [];
    const removed = [];
    let runtimes = reused ? [runtime] : [];
    const start = source.indexOf("    console.log('Verifying pinned guest simulator runtimes.');");
    const end = source.indexOf('    const launchDirectory =', start);
    assert.ok(start >= 0 && end > start);
    const globals = {config: {vmId: 'fixture', runtimes: [wanted]}, path, buildRoot, staging, check,
        matchesRuntime: pureFunction('matchesRuntime'), console: {log() {}},
        fs: {mkdirSync() {}, existsSync: () => true},
        staged: relative => path.join(staging, relative), runtimeStorageCheckpoint() {},
        exportedRuntimeImage: directory => path.join(directory, 'downloaded.dmg'),
        removeLocalProvisioningInput: filename => removed.push(filename),
        run(_label, command, args) {
            if (command === '/usr/bin/xcodebuild') {
                commands.push([command, ...args]);
                if (args[0] === '-importPlatform') runtimes = [{...runtime, buildversion: importedBuild ?? wanted.buildVersion}];
                else assert.equal(args[0], '-downloadPlatform');
                return '';
            }
            assert.equal(command, '/usr/bin/xcrun');
            assert.deepEqual(Array.from(args).slice(0, 2), ['simctl', 'list']);
            if (args[2] === 'runtimes') return JSON.stringify({runtimes});
            if (args[2] === 'devicetypes') return JSON.stringify({devicetypes: [{name, identifier: 'fixture-device'}]});
            assert.equal(args[2], 'devices');
            return JSON.stringify({devices: {[runtime.identifier]: [{name, isAvailable: true}]}});
        },
    };
    return {wanted, commands, removed, run: () => vm.runInNewContext(source.slice(start, end), globals)};
}

test('runtime downloads select the pinned build ID when release and build differ', () => {
    for (const platform of ['iOS', 'visionOS']) {
        const fixture = runtimeProvisioningFixture({platform});
        fixture.run();
        const download = fixture.commands.find(command => command[1] === '-downloadPlatform');
        assert.equal(download[download.indexOf('-buildVersion') + 1], fixture.wanted.buildVersion);
        assert.notEqual(fixture.wanted.buildVersion, fixture.wanted.version);
        assert.equal(fixture.commands.filter(command => command[1] === '-importPlatform').length, 1);
    }
});

test('runtime provisioning rejects a different installed build after downloading', () => {
    const fixture = runtimeProvisioningFixture({importedBuild: '24A999'});
    assert.throws(fixture.run, /iOS 27\.0 \(24A434\) is unavailable/);
    assert.equal(fixture.commands.length, 2);
});

test('runtime provisioning reuses an already installed exact build without downloading or importing', () => {
    for (const dmgPath of [undefined, 'runtime.dmg']) {
        const fixture = runtimeProvisioningFixture({reused: true, dmgPath});
        fixture.run();
        assert.deepEqual(fixture.commands, []);
        assert.deepEqual(fixture.removed, dmgPath ? ['/guest/provision/runtime.dmg'] : []);
    }
});

test('runtime provisioning imports an explicit DMG without downloading', () => {
    const fixture = runtimeProvisioningFixture({dmgPath: 'runtime.dmg'});
    fixture.run();
    assert.deepEqual(fixture.commands, [['/usr/bin/xcodebuild', '-importPlatform', '/guest/provision/runtime.dmg']]);
    assert.deepEqual(fixture.removed, ['/guest/provision/runtime.dmg']);
});

test('Xcode provisioning requires a pinned archive rather than traversing a shared app bundle', () => {
    assert.equal(validateArchive({path: 'Xcode.tar', sha256: 'a'.repeat(64)}).path, 'Xcode.tar');
    for (const value of [undefined, {}, {path: '../Xcode.tar', sha256: 'a'.repeat(64)}, {path: 'Xcode.tar', sha256: 'not-a-digest'}]) {
        assert.throws(() => validateArchive(value), /pinned SHA-256/);
    }
    assert.doesNotMatch(source, /run\('Copy Xcode', '\/usr\/bin\/ditto'/);
    assert.doesNotMatch(source, /sourceXcode|xcodeCandidates/);
});

test('archive transfer preserves ordinary framework symlinks and rejects hash mismatches before extraction', () => {
    const root = mkdtempSync(path.join(tmpdir(), 'big-wallet-xcode-archive-fixture-'));
    try {
        const app = path.join(root, 'source', 'Xcode.app');
        const framework = path.join(app, 'Contents', 'Frameworks', 'Fixture.framework');
        mkdirSync(path.join(framework, 'Versions', 'A', 'Headers'), {recursive: true});
        writeFileSync(path.join(framework, 'Versions', 'A', 'Headers', 'fixture.h'), 'fixture');
        symlinkSync('A', path.join(framework, 'Versions', 'Current'));
        symlinkSync('Versions/Current/Headers', path.join(framework, 'Headers'));
        const archive = path.join(root, 'Xcode.tar');
        execFileSync('/usr/bin/tar', ['-cf', archive, '-C', path.dirname(app), 'Xcode.app']);
        const hash = createHash('sha256').update(readFileSync(archive)).digest('hex');
        const incoming = path.join(root, 'incoming.app');
        const commands = [];
        const extract = pureFunction('extractXcodeArchive', {
            fs: {mkdirSync},
            run: (_label, command, args) => { commands.push([command, ...args]); return execFileSync(command, args, {encoding: 'utf8'}).trim(); },
            check: (condition, message) => { if (!condition) throw new Error(message); },
        });
        assert.throws(() => extract(archive, '0'.repeat(64), incoming), /does not match/);
        assert.equal(commands.length, 1);
        extract(archive, hash, incoming);
        const extracted = path.join(incoming, 'Contents', 'Frameworks', 'Fixture.framework');
        assert.equal(readlinkSync(path.join(extracted, 'Versions', 'Current')), 'A');
        assert.equal(readFileSync(path.join(extracted, 'Headers', 'fixture.h'), 'utf8'), 'fixture');
        assert.equal(commands.filter(command => command[0] === '/usr/bin/tar').length, 1);
    } finally { rmSync(root, {recursive: true, force: true}); }
});

test('idempotent directory relocation does not chown an already correctly owned protected target', () => {
    const root = filesystem.realpathSync(mkdtempSync(path.join(tmpdir(), 'big-wallet-owned-relocation-')));
    try {
        const destination = path.join(root, 'installed.app');
        const sourceLink = path.join(root, 'Xcode.app');
        mkdirSync(destination);
        symlinkSync(destination, sourceLink);
        const metadata = filesystem.statSync(destination);
        const fs = {...filesystem, chownSync: () => { throw new Error('already-owned protected target must not receive chown'); }};
        const ownership = pureFunction('setOwnershipIfNeeded', {fs});
        const globals = {fs, path, state: root, crypto: {createHash, randomUUID}, setOwnershipIfNeeded: ownership,
            check: (condition, message) => { if (!condition) throw new Error(message); },
            run: () => { throw new Error('the existing correct symlink must not be moved'); }};
        globals.relocationIntentPath = pureFunction('relocationIntentPath', globals);
        const relocate = pureFunction('relocateDirectory', globals);
        relocate(sourceLink, destination, metadata.uid, metadata.gid);
        assert.equal(readlinkSync(sourceLink), destination);
    } finally { rmSync(root, {recursive: true, force: true}); }
});

function relocationFixture(operation, {existingTarget = false, absentSource = false, sourceLink = false} = {}) {
    const root = filesystem.realpathSync(mkdtempSync(path.join(tmpdir(), 'big-wallet-relocation-')));
    const state = path.join(root, 'state');
    const original = path.join(root, 'user', 'CoreSimulator');
    const destination = path.join(root, 'sidecar', 'Users', 'tester', 'CoreSimulator');
    const preservedRoot = '/Volumes/BigWalletBuild/Preserved';
    const localPreserved = path.join(root, 'sidecar', 'Preserved');
    const map = filename => filename === preservedRoot || filename.startsWith(preservedRoot + '/')
        ? localPreserved + filename.slice(preservedRoot.length) : filename;
    const logical = filename => filename === localPreserved || filename.startsWith(localPreserved + '/')
        ? preservedRoot + filename.slice(localPreserved.length) : filename;
    const events = [];
    let failAt;
    let inspectIdle = () => {};
    const fail = name => { if (failAt === name) { failAt = null; throw new Error(`fixture ${name}`); } };
    try {
        mkdirSync(state, {mode: 0o700});
        mkdirSync(path.dirname(original), {recursive: true});
        mkdirSync(path.dirname(destination), {recursive: true});
        if (!absentSource) {
            mkdirSync(original);
            writeFileSync(path.join(original, 'device.plist'), 'complete original device data');
            writeFileSync(path.join(original, 'complete-only'), 'complete original extra file');
            if (sourceLink) {
                const other = path.join(root, 'other-app');
                filesystem.renameSync(original, other);
                symlinkSync(other, original);
            }
        }
        if (existingTarget) {
            mkdirSync(destination);
            writeFileSync(path.join(destination, 'device.plist'), 'verified replacement');
        }
        const api = {...filesystem,
            mkdirSync(filename, options) { const result = filesystem.mkdirSync(map(filename), options); if (filename.endsWith('.incoming')) fail('incoming'); return result; },
            lstatSync(filename, options) {
                const metadata = filesystem.lstatSync(map(filename), options);
                if (metadata && (filename.startsWith(state + '/') || filename === preservedRoot || filename.endsWith('.previous'))) {
                    metadata.uid = options?.bigint ? 0n : 0;
                }
                return metadata;
            },
            realpathSync: filename => filename.startsWith(preservedRoot) ? logical(filesystem.realpathSync(map(filename))) : filesystem.realpathSync(filename),
            readFileSync: (filename, ...args) => filesystem.readFileSync(map(filename), ...args),
            readdirSync: (filename, ...args) => filesystem.readdirSync(map(filename), ...args),
            openSync: (filename, ...args) => filesystem.openSync(map(filename), ...args),
            fchownSync() {},
            chownSync(filename, owner, group) { assert.ok(filename.endsWith('.previous')); assert.equal(owner, 0); assert.equal(group, 0); },
            renameSync(from, to) {
                filesystem.renameSync(map(from), map(to));
                events.push(['rename', from, to]);
                if (to === destination) fail('promotion');
                if (from === original && path.dirname(to).endsWith('.previous')) fail('retirement');
            },
            symlinkSync(target, filename) {
                filesystem.symlinkSync(map(target), map(filename));
                events.push(['link', target, filename]);
                if (filename === original) fail('link');
            },
            readlinkSync: filename => logical(filesystem.readlinkSync(map(filename))),
            rmSync(filename, options) {
                if (path.dirname(filename).endsWith('.previous') && failAt === 'retired-cleanup') {
                    filesystem.rmSync(path.join(map(filename), 'device.plist'));
                    fail('retired-cleanup');
                }
                return filesystem.rmSync(map(filename), options);
            },
            rmdirSync: filename => filesystem.rmdirSync(map(filename)),
            unlinkSync(filename) { filesystem.unlinkSync(map(filename)); fail('intent-cleanup'); },
        };
        const globals = {fs: api, path, state, config: {vmId: 'fixture-vm'}, crypto: {createHash, randomUUID},
            check, setOwnershipIfNeeded(filename) { assert.ok(map(filename).startsWith(root)); },
            run(_label, command, args) {
                events.push([command, ...args]);
                if (command === '/bin/sync') return;
                if (command === '/bin/chmod') { assert.equal(args[0], '-N'); assert.ok(args[1].endsWith('.previous')); return; }
                assert.equal(command, '/bin/cp');
                if (failAt === 'copy') {
                    writeFileSync(path.join(map(args[2]), 'device.plist'), 'partial');
                    fail('copy');
                }
                execFileSync('/bin/cp', [args[0], map(args[1]), map(args[2])], {timeout: 5000});
            }};
        globals.requireIdleRelocationTree = directory => {
            events.push(['idle', directory]);
            if (path.dirname(directory).endsWith('.previous')) {
                const parent = api.lstatSync(path.dirname(directory));
                assert.equal(parent.uid, 0);
                assert.equal(parent.mode & 0o7777, 0o700);
            }
            inspectIdle(directory);
        };
        const sync = pureFunction('syncDirectory', globals);
        globals.syncDirectory = directory => { sync(directory); events.push(['sync', directory]); };
        const durable = pureFunction('writeDurableJSON', globals);
        globals.relocationFileID = pureFunction('relocationFileID', globals);
        globals.relocationIntentPath = pureFunction('relocationIntentPath', globals);
        const intentPath = globals.relocationIntentPath(original, destination);
        globals.writeDurableJSON = (filename, value, mode) => {
            if (filename === intentPath && existingTarget) fail('primary-intent');
            durable(filename, value, mode);
            events.push(['intent', filename, value.ready]);
            if (filename === intentPath && value.ready) fail('ready');
        };
        const relocate = pureFunction('relocateDirectory', globals);
        operation({root, state, original, destination, preserved: localPreserved, events, api,
            interrupt: name => { failAt = name; },
            inspectIdle: callback => { inspectIdle = callback; },
            run: () => relocate(original, destination, process.getuid(), process.getgid(), existingTarget),
            active: () => readFileSync(path.join(original, 'device.plist'), 'utf8'),
            intents: () => filesystem.readdirSync(state),
            retired: () => filesystem.readdirSync(path.dirname(original)).filter(name => name.endsWith('.previous')),
            retiredTrees: () => filesystem.readdirSync(path.dirname(original)).filter(name => name.endsWith('.previous'))
                .map(name => path.join(path.dirname(original), name, path.basename(original)))});
    } finally { rmSync(root, {recursive: true, force: true}); }
}

test('interrupted CoreSimulator relocation retries every copy and activation boundary without adopting a partial tree', () => {
    for (const boundary of ['incoming', 'copy', 'ready', 'promotion', 'retirement', 'link', 'retired-cleanup', 'intent-cleanup']) {
        relocationFixture(fixture => {
            fixture.interrupt(boundary);
            assert.throws(fixture.run, new RegExp(`fixture ${boundary}`));
            fixture.run();
            assert.equal(fixture.active(), 'complete original device data');
            assert.equal(readFileSync(path.join(fixture.original, 'complete-only'), 'utf8'), 'complete original extra file');
            assert.equal(filesystem.realpathSync(fixture.original), fixture.destination);
            assert.deepEqual(fixture.intents(), []);
            assert.deepEqual(fixture.retired(), []);
            const commands = fixture.events.filter(event => event[0] === '/bin/cp').length;
            fixture.run();
            assert.equal(fixture.events.filter(event => event[0] === '/bin/cp').length, commands);
        });
    }
});

test('ready and promoted relocation retries preserve data recreated at the original guest path', () => {
    for (const boundary of ['ready', 'promotion']) {
        relocationFixture(fixture => {
            fixture.interrupt(boundary);
            assert.throws(fixture.run, new RegExp(`fixture ${boundary}`));
            assert.equal(filesystem.existsSync(fixture.original), false);
            mkdirSync(fixture.original);
            writeFileSync(path.join(fixture.original, 'device.plist'), 'updated after interruption');
            writeFileSync(path.join(fixture.original, 'new-device'), 'new device data');
            assert.throws(fixture.run, /source changed or was recreated/);
            assert.equal(fixture.active(), 'updated after interruption');
            assert.equal(readFileSync(path.join(fixture.original, 'new-device'), 'utf8'), 'new device data');
            const [retired] = fixture.retiredTrees();
            assert.equal(readFileSync(path.join(retired, 'device.plist'), 'utf8'), 'complete original device data');
            assert.equal(readFileSync(path.join(retired, 'complete-only'), 'utf8'), 'complete original extra file');
            assert.equal(fixture.intents().length, 1);
        });
    }
});

test('existing references block relocation before retiring or copying and retries retain their final writes', () => {
    for (const beforeRetirement of [true, false]) {
        relocationFixture(fixture => {
            const descriptor = filesystem.openSync(path.join(fixture.original, 'device.plist'), 'r+');
            try {
                fixture.inspectIdle(directory => {
                    if ((directory === fixture.original) !== beforeRetirement) return;
                    filesystem.ftruncateSync(descriptor, 0);
                    filesystem.writeSync(descriptor, 'final write through an existing reference');
                    throw new Error('fixture open reference');
                });
                assert.throws(fixture.run, /fixture open reference/);
                assert.ok(!fixture.events.some(event => event[0] === '/bin/cp'));
                assert.equal(filesystem.existsSync(fixture.original), beforeRetirement);
            } finally { filesystem.closeSync(descriptor); }
            fixture.inspectIdle(() => {});
            fixture.run();
            assert.equal(fixture.active(), 'final write through an existing reference');
            assert.deepEqual(fixture.retired(), []);
        });
    }
});

test('retired trees stay private until copying and are checked again before deletion', () => {
    relocationFixture(fixture => {
        let retiredChecks = 0;
        fixture.inspectIdle(directory => {
            if (directory !== fixture.original && ++retiredChecks === 2) throw new Error('fixture cleanup reference');
        });
        assert.throws(fixture.run, /fixture cleanup reference/);
        assert.equal(filesystem.realpathSync(fixture.original), fixture.destination);
        const [retired] = fixture.retiredTrees();
        assert.equal(readFileSync(path.join(retired, 'device.plist'), 'utf8'), 'complete original device data');
        const protect = fixture.events.findIndex(event => event[0] === '/bin/chmod');
        const copy = fixture.events.findIndex(event => event[0] === '/bin/cp');
        assert.ok(protect >= 0 && copy > protect);
        fixture.inspectIdle(() => {});
        fixture.run();
        assert.deepEqual(fixture.retired(), []);
    });
});

test('relocation refuses changed retired ownership, permissions, or wrapper identity', () => {
    for (const change of ['owner', 'mode', 'wrapper']) {
        relocationFixture(fixture => {
            fixture.interrupt('ready');
            assert.throws(fixture.run, /fixture ready/);
            const [retired] = fixture.retiredTrees();
            if (change === 'owner') {
                const inspect = fixture.api.lstatSync;
                fixture.api.lstatSync = (filename, options) => {
                    const metadata = inspect(filename, options);
                    if (filename === retired) metadata.uid = options?.bigint ? 999n : 999;
                    return metadata;
                };
            } else if (change === 'mode') {
                filesystem.chmodSync(retired, 0o700);
            } else {
                filesystem.renameSync(path.dirname(retired), `${path.dirname(retired)}.saved`);
                mkdirSync(path.dirname(retired), {mode: 0o700});
            }
            assert.throws(fixture.run, /missing or changed|protected relocation directory changed/);
            assert.equal(filesystem.existsSync(fixture.original), false);
            assert.equal(fixture.intents().length, 1);
            assert.equal(readFileSync(path.join(change === 'wrapper' ? `${path.dirname(retired)}.saved/${path.basename(retired)}` : retired,
                'device.plist'), 'utf8'), 'complete original device data');
        });
    }
});

test('open-reference checks cover mounted descendants and fail closed on incomplete inspection', () => {
    for (const result of [{status: 1, stdout: '', stderr: ''}, {status: 0, stdout: '123\n', stderr: ''},
        {status: 1, stdout: '', stderr: 'cannot stat descendant'}, {status: 2, stdout: '', stderr: ''},
        {status: null, stdout: '', stderr: '', error: {code: 'ETIMEDOUT'}}]) {
        const inspect = pureFunction('requireIdleRelocationTree', {check, environment: {}, spawnSync(command, args, options) {
            assert.equal(command, '/usr/sbin/lsof');
            assert.deepEqual(Array.from(args), ['-nP', '-t', '+w', '+D', '/fixture/private/tree', '-x', 'f']);
            assert.equal(options.timeout, 60000);
            assert.equal(options.killSignal, 'SIGKILL');
            return result;
        }});
        if (result.status === 1 && !result.stderr) assert.doesNotThrow(() => inspect('/fixture/private/tree'));
        else assert.throws(() => inspect('/fixture/private/tree'), /preserved/);
    }
});

test('verified application replacement preserves differing original data on the sidecar and frees its boot copy', () => {
    relocationFixture(fixture => {
        fixture.interrupt('primary-intent');
        assert.throws(fixture.run, /fixture primary-intent/);
        fixture.run();
        assert.equal(fixture.active(), 'verified replacement');
        const saved = filesystem.readdirSync(fixture.preserved);
        assert.equal(saved.length, 1);
        assert.equal(readFileSync(path.join(fixture.preserved, saved[0], 'device.plist'), 'utf8'), 'complete original device data');
        assert.deepEqual(fixture.retired(), []);
        assert.deepEqual(fixture.intents(), []);
    }, {existingTarget: true});
});

test('new empty relocation directories are synced before the dependent intent and remain retryable', () => {
    relocationFixture(fixture => {
        fixture.run();
        assert.equal(filesystem.realpathSync(fixture.original), fixture.destination);
        const intent = fixture.events.findIndex(event => event[0] === 'intent');
        const incomingSync = fixture.events.findIndex(event => event[0] === 'sync' && event[1].endsWith('.incoming'));
        const parentSync = fixture.events.findIndex(event => event[0] === 'sync' && event[1] === path.dirname(fixture.destination));
        assert.ok(incomingSync >= 0 && parentSync > incomingSync && intent > parentSync);
        assert.deepEqual(fixture.retired(), []);
    }, {absentSource: true});
});

test('relocation refuses unrecorded partial destinations and symlinked idempotent targets', () => {
    relocationFixture(fixture => {
        mkdirSync(fixture.destination);
        writeFileSync(path.join(fixture.destination, 'partial'), 'keep');
        assert.throws(fixture.run, /unrecorded relocation destination/);
        assert.equal(fixture.active(), 'complete original device data');
        assert.equal(readFileSync(path.join(fixture.destination, 'partial'), 'utf8'), 'keep');
    });
    relocationFixture(fixture => {
        const unrelated = path.join(fixture.root, 'unrelated');
        mkdirSync(unrelated);
        symlinkSync(unrelated, fixture.destination);
        symlinkSync(fixture.destination, fixture.original);
        assert.throws(fixture.run, /target must be a real directory/);
        assert.equal(filesystem.realpathSync(fixture.destination), unrelated);
    }, {absentSource: true});
});

test('installer restores public-directory permissions after checking private input paths', () => {
    const guard = source.indexOf('Local provisioning directories must be private.');
    const mask = source.indexOf('\numask 022\n');
    assert.ok(mask > guard);
    assert.ok(mask < source.indexOf('temporary_directory='));
    const root = filesystem.realpathSync(mkdtempSync(path.join(tmpdir(), 'big-wallet-provision-umask-')));
    try {
        const program = `umask 077\n${source.slice(mask, mask + '\numask 022\n'.length)}\nexec "$FIXTURE_NODE" -e '${
            'const fs=require("node:fs"),p=process.argv[1];fs.mkdirSync(p+"/Applications",{mode:0o755});fs.mkdirSync(p+"/private",{mode:0o700});fs.writeFileSync(p+"/private/secret","fixture",{mode:0o600})'}' "$FIXTURE_ROOT"`;
        execFileSync('/bin/sh', ['-c', program], {env: {PATH: '/usr/bin:/bin', FIXTURE_NODE: process.execPath, FIXTURE_ROOT: root}});
        assert.equal(filesystem.statSync(path.join(root, 'Applications')).mode & 0o777, 0o755);
        assert.equal(filesystem.statSync(path.join(root, 'private')).mode & 0o777, 0o700);
        assert.equal(filesystem.statSync(path.join(root, 'private/secret')).mode & 0o777, 0o600);
    } finally { rmSync(root, {recursive: true, force: true}); }
});

test('ownership is changed only when the owner or group differs', () => {
    const changes = [];
    const ownership = pureFunction('setOwnershipIfNeeded', {fs: {
        statSync: () => ({uid: 501, gid: 20}), chownSync: (...args) => changes.push(args),
    }});
    ownership('/fixture', 501, 20);
    assert.deepEqual(changes, []);
    ownership('/fixture', 502, 20);
    ownership('/fixture', 501, 21);
    assert.deepEqual(changes, [['/fixture', 502, 20], ['/fixture', 501, 21]]);
});

test('installed Aqua supervisor remains idle until an explicit job launch', () => {
    const configStart = source.indexOf('    const agentConfiguration = ');
    const configEnd = source.indexOf('    const signing = ', configStart);
    const configuration = vm.runInNewContext(`${source.slice(configStart, configEnd)} agentConfiguration`, {
        library: '/fixture/tools', agentLabel: 'fixture-agent', environment: {PATH: '/fixture/bin'},
        developer: '/fixture/Xcode', logDirectory: '/fixture/logs', path,
    });
    assert.equal(configuration.LimitLoadToSessionType, 'Aqua');
    assert.equal(configuration.RunAtLoad, false);
    assert.equal(configuration.KeepAlive, false);
    assert.deepEqual(Array.from(configuration.ProgramArguments), ['/fixture/tools/VMGuestAgent']);
    const serviceStart = source.indexOf('    const service = `gui/${uid}/${agentLabel}`;');
    const serviceEnd = source.indexOf('    console.log(', serviceStart);
    const commands = [];
    const removed = [];
    const install = replaceGuestAgentInstallation => vm.runInNewContext(source.slice(serviceStart, serviceEnd), {
        uid: 501, agentLabel: 'fixture-agent', agentPlist: '/fixture/agent.plist', replacements: [], check,
        library: '/fixture/tools', path,
        fs: {lstatSync: () => ({uid: 0, mode: 0o644, isFile: () => true, isSymbolicLink: () => false}),
            rmSync: filename => { assert.equal(commands.length, 1); removed.push(filename); }},
        spawnSync: () => ({status: 1}), run: (_label, command, args) => commands.push([command, ...args]),
        replaceGuestAgentInstallation,
    });
    assert.throws(() => install(() => { throw new Error('fixture installation failed'); }), /installation failed/);
    assert.deepEqual(removed, []);
    install((_replacements, service) => service.start());
    assert.deepEqual(commands, [['/bin/launchctl', 'bootstrap', 'gui/501', '/fixture/agent.plist']]);
    assert.deepEqual(removed, ['guest.mjs', 'test_manifest.mjs', 'result_audit.mjs'].map(name => path.join('/fixture/tools', name)));
});
