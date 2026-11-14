import assert from 'node:assert/strict';
import {createHash, randomUUID} from 'node:crypto';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdtempSync, mkdirSync, readFileSync, readlinkSync, rmSync, symlinkSync, writeFileSync} from 'node:fs';
import * as filesystem from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import test from 'node:test';
import * as provisioning from '../provision_guest.mjs';

const source = readFileSync(new URL('../provision_guest.sh', import.meta.url), 'utf8');
function provisionerFixture({config = {consoleUser: 'tester'}, staging = '/guest/provision', uid = 501, gid = 20, mode = '',
    library = '/guest/library', state = '/guest/state', exchange = '/Volumes/BigWalletBuild/Exchange',
    developer = '/Applications/Xcode.app/Contents/Developer', environment = {}, fs = {}, run,
    spawnSync = () => assert.fail('Unexpected subprocess'), crypto = {createHash, randomUUID},
    process: processEffects = {pid: process.pid, stdout: {write() {}}, stderr: {write() {}}, on() {}},
    performance = {now: () => 0}, console = {log() {}, error() {}}, setImmediate = () => {}} = {}) {
    return provisioning.createProvisioner({config, staging, uid, gid, mode, environment,
        paths: {library, state, exchange, developer}},
        {fs, execute: run, spawnSync, crypto, process: processEffects, performance, console, setImmediate});
}

const select = provisioning.selectBlankBuildDisk;
const validate = provisioning.validateBlankBuildDisk;
const optionalSigning = provisioning.optionalSigningConfiguration;
const appliedRequest = provisioning.appliedProvisioningRequest;
const rootSpaceRequirement = provisioning.runtimeRootSpaceRequirement;
const validateArchive = provisioning.validateXcodeArchive;
const capacity = 103_079_215_104;
const boot = {DeviceIdentifier: 'disk0', Size: 68_719_476_736, Content: 'GUID_partition_scheme',
    Partitions: [{Content: 'Apple_APFS_ISC'}, {Content: 'Apple_APFS'}, {Content: 'Apple_APFS_Recovery'}]};
const blank = {DeviceIdentifier: 'disk1', Size: capacity};
const details = {WholeDisk: true, TotalSize: capacity};
const samples = () => [Buffer.alloc(1024 * 1024), Buffer.alloc(1024 * 1024)];
const check = (condition, message) => { if (!condition) throw new Error(message); };
const validateRetirementPins = provisioning.validateRetirementPins;
const matchesRuntimeImage = provisioning.matchesRuntimeImage;

test('local preparation requests only missing pinned archive and runtime images', () => {
    const matchesRuntime = provisioning.matchesRuntime;
    const required = provisioning.requiredProvisioningInputs;
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
        writeFileSync(filename, content, options) { nodes.set(filename, {kind: 'file', uid: 0, mode: options.mode, content}); },
        chownSync() {},
        renameSync(from, to) { nodes.set(to, nodes.get(from)); nodes.delete(from); },
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
    const create = provisionerFixture({fs, crypto: {randomUUID: () => id(999)}}).prepareLocalProvisioningDirectory;
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
    const remove = provisionerFixture({fs: fixture.fs}).removeLocalProvisioningInput;
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
    const prepare = provisionerFixture({fs, exchange, uid: 501, gid: 20}).prepareLocalExchange;
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
        const ready = provisionerFixture({uid: 501, spawnSync(command, args, options) {
            assert.equal(options.timeout, 1000);
            assert.equal(options.killSignal, 'SIGKILL');
            if (command.endsWith('/stat')) return {status: 0, stdout: failure === 'console' ? '502\n' : '501\n'};
            if (command.endsWith('/launchctl')) return {status: failure === 'domain' ? 1 : 0};
            if (command.endsWith('/ioreg')) return {status: 0, stdout: 'fixture registry'};
            return {status: 0, stdout: failure === 'locked' ? 'true\n' : 'false\n'};
        }}).selectedUserSessionReady;
        assert.equal(ready(), failure === null);
    }
});

test('Aqua wait permits normal login progress but bounds timeout and propagates interruption', () => {
    const wait = provisionerFixture().waitForSelectedSession;
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
    const wait = provisionerFixture({spawnSync(command, args, options) {
        calls.push({command, args, options});
        return spawnSync(command, args, options);
    }}).waitForSelectedSession;
    assert.throws(() => wait({ready: () => false, now: () => times.shift()}), /unlocked Aqua session/);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].command, '/bin/sleep');
    assert.ok(Number(calls[0].args[0]) > 0 && Number(calls[0].args[0]) < 1);
    assert.equal(calls[0].options.timeout, 1170);
    assert.equal(calls[0].options.killSignal, 'SIGKILL');
});

function automaticLoginFixture({enabled = false, ready = false, interactive = false, completesLogin = true,
    supplied = true, setStatus = 0, confirms = true, commandOutput, commandError} = {}) {
    const events = [];
    const invocations = [];
    const password = 'fixture-secret-password';
    let clock = 0;
    let diagnostics = '';
    const config = {consoleUser: 'tester', interactiveSetup: interactive,
        ...(supplied ? {autologin: {passwordFile: 'password'}} : {})};
    const provisioner = provisionerFixture({config,
        fs: {realpathSync: value => value, statSync: () => ({isFile: () => true}),
            readFileSync(filename) { assert.equal(filename, '/guest/provision/password'); events.push('password'); return password; }},
        performance: {now: () => clock}, process: {stderr: {write: value => { diagnostics += value; }}},
        run(_label, command) { assert.equal(command, '/usr/bin/id'); return 'staff admin'; },
        spawnSync(command, args, options) {
            if (command === '/usr/bin/stat') return {status: 0, stdout: ready ? '501' : '502'};
            if (command === '/usr/sbin/ioreg') return {status: 0, stdout: 'fixture registry'};
            if (command === '/usr/bin/plutil') return {status: 0, stdout: 'false'};
            if (command === '/bin/launchctl' && args[0] === 'print') return {status: 0};
            if (command === '/bin/sleep') {
                if (clock === 0) events.push('login');
                clock += Number(args[0]) * 1000;
                if (completesLogin) ready = true;
                return {status: 0};
            }
            if (command === '/usr/sbin/sysadminctl' && args[1] === 'status') {
                return {status: 0, stdout: '', stderr: enabled ? 'Automatic login user: tester' : 'Automatic login disabled'};
            }
            assert.equal(command, ready ? '/bin/launchctl' : '/usr/sbin/sysadminctl');
            assert.equal(options.timeout, 60000);
            assert.equal(options.maxBuffer, 16 * 1024);
            assert.ok(args.includes(password));
            assert.ok(!args.includes('/usr/bin/sudo'));
            if (ready) assert.deepEqual(args.slice(0, 3), ['asuser', '501', '/usr/sbin/sysadminctl']);
            events.push('configure');
            invocations.push({command, args, options});
            enabled = confirms;
            return {status: setStatus, stdout: commandOutput ?? '', stderr: commandError ?? ''};
        },
    });
    return {run: provisioner.ensureAutomaticLogin, events, invocations, diagnostics: () => diagnostics};
}

test('autologin preparation uses only the supplied existing password and requests one restart only when needed', () => {
    for (const [enabled, ready] of [[true, false], [false, false], [false, true]]) {
        const fixture = automaticLoginFixture({enabled, ready});
        assert.equal(fixture.run(), !enabled && !ready);
        assert.deepEqual(fixture.events, enabled ? [] : ['password', 'configure']);
    }
    assert.throws(automaticLoginFixture({supplied: false}).run, /existing guest account password/);
});

test('autologin status matches the exact selected account name', () => {
    for (const [message, expected] of [['Automatic login user: bob', true], ["Automatic login user: 'bob'", true],
        ['Automatic login user: bobby', false], ['Automatic login user: bob-test', false], ['Automatic login disabled for bob', false]]) {
        const enabled = provisionerFixture({config: {consoleUser: 'bob'},
            spawnSync() { return {status: 0, stdout: '', stderr: message}; }}).automaticLoginEnabled;
        assert.equal(enabled(), expected);
    }
});

test('interactive autologin preparation waits for existing guest login and still requires a cold restart', () => {
    const fixture = automaticLoginFixture({interactive: true});
    assert.equal(fixture.run(), true);
    assert.deepEqual(fixture.events, ['login', 'password', 'configure']);
});

test('interactive guest login timeout stops before reading credentials or setting automatic login', () => {
    const fixture = automaticLoginFixture({interactive: true, completesLogin: false});
    assert.throws(fixture.run, /unlocked Aqua session/);
    assert.deepEqual(fixture.events, ['login']);
    assert.deepEqual(fixture.invocations, []);
});

test('interactive setup does not wait when the selected guest session is already unlocked', () => {
    const fixture = automaticLoginFixture({interactive: true, ready: true});
    assert.equal(fixture.run(), false);
    assert.deepEqual(fixture.events, ['password', 'configure']);
});

test('failed autologin verification reports bounded redacted command output', () => {
    for (const status of [0, 1]) {
        const fixture = automaticLoginFixture({setStatus: status, confirms: false,
            commandOutput: 'fixture-secret-password', commandError: 'Rejected fixture-secret-password twice fixture-secret-password'});
        assert.throws(fixture.run, status === 0 ? /Automatic login.*unavailable/ : /Enable automatic login.*failed/);
        assert.ok(!fixture.diagnostics().includes('fixture-secret-password'));
        const report = JSON.parse(fixture.diagnostics().slice('Automatic login command diagnostics: '.length));
        assert.deepEqual(report, {status, error: null, signal: null, stdout: '[REDACTED]', stderr: 'Rejected [REDACTED] twice [REDACTED]'});
    }
});

test('autologin diagnostics redact before truncation and suppress incomplete captures', () => {
    const diagnostic = provisioning.automaticLoginCommandDiagnostic;
    const password = 'boundary-secret-password';
    const report = diagnostic({status: 0, stdout: 'x'.repeat(4090) + password, stderr: password.repeat(400)}, password);
    assert.equal(report.stdout, 'x'.repeat(4090) + '[REDAC');
    assert.equal(report.stderr, '[REDACTED]'.repeat(400));
    for (const failure of [{error: {code: 'ENOBUFS'}}, {error: {code: 'ETIMEDOUT'}}, {signal: 'SIGTERM'}]) {
        const report = diagnostic({status: null, stdout: password.slice(0, 12), stderr: password.slice(12), ...failure}, password);
        assert.equal(report.stdout, '[output omitted: capture incomplete]');
        assert.equal(report.stderr, '[output omitted: capture incomplete]');
    }
});

test('nonzero autologin set still fails even when subsequent verification matches', () => {
    const fixture = automaticLoginFixture({setStatus: 1, confirms: true, commandOutput: 'fixture-secret-password'});
    assert.throws(fixture.run, /Enable automatic login.*failed/);
    assert.equal(fixture.diagnostics(), '');
});

test('storage staging reports only required inputs and a restart without publishing a receipt', () => {
    const fixture = localStageFilesystem();
    const logs = [];
    const config = {version: 1, vmId: 'fixture-vm', consoleUser: 'tester', xcode: {version: '27.0', buildVersion: 'fixture'},
        xcodeArchive: {path: 'Xcode.tar', sha256: 'a'.repeat(64)},
        runtimes: [{platform: 'iOS', version: '27.0', buildVersion: 'ios', dmgPath: 'ios.dmg'},
            {platform: 'visionOS', version: '27.0', buildVersion: 'vision', dmgPath: 'vision.dmg'}]};
    const prepare = provisionerFixture({config, fs: {...fixture.fs, existsSync: () => false},
        crypto: {randomUUID: () => '00000000-0000-4000-8000-000000000999'}, console: {log: value => logs.push(value)}}).prepareStorage;
    prepare('/Volumes/BigWalletBuild', '/Volumes/BigWalletBuild/Applications/Xcode.app', true);
    assert.equal(logs.length, 1);
    assert.deepEqual(JSON.parse(logs[0].slice('BIG_WALLET_PROVISIONING_STAGE='.length)), {
        stagingDirectory: '/Volumes/BigWalletBuild/Provisioning/00000000-0000-4000-8000-000000000999/provision',
        requiredInputs: ['Xcode.tar', 'ios.dmg', 'vision.dmg'], requiresRestart: true,
    });
    assert.equal([...fixture.nodes.keys()].some(path => path.endsWith('/provisioning.json')), false);
});

function guestStateFixture({failACL} = {}) {
    const state = '/guest/state';
    const config = {vmId: 'fixture-vm', consoleUser: 'tester'};
    const prior = {...config};
    const metadata = {uid: 0, gid: 20, mode: 0o750, isDirectory: () => true, isSymbolicLink: () => false};
    const changes = [];
    let acl = [{principal: 'staff', group: true, rights: ['list', 'search', 'add_file']}];
    const prepare = provisionerFixture({state, config,
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
    }).prepareGuestState;
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
        const install = provisionerFixture({fs: api, crypto: {randomUUID: () => 'fixture'},
            process: {on(signal) { deferredSignals.push(signal); }}, setImmediate() {},
            check(condition, message) { if (!condition) throw new Error(message); }}).replaceGuestAgentInstallation;
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
    for (const signal of ['SIGTERM', 'SIGHUP']) {
        for (const failStart of [false, true]) {
            const root = mkdtempSync(path.join(tmpdir(), 'big-wallet-agent-signal-'));
            const agent = path.join(root, 'agent');
            const state = path.join(root, 'service-state');
            const program = `
                const {createProvisioner} = await import(${JSON.stringify(new URL('../provision_guest.mjs', import.meta.url).href)});
                const fs = await import('node:fs');
                const {replaceGuestAgentInstallation} = createProvisioner({config: {}, uid: process.getuid(), gid: process.getgid()});
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
                const result = spawnSync(process.execPath, ['--input-type=module', '-e', program], {encoding: 'utf8', timeout: 5000, killSignal: 'SIGKILL'});
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
    const protect = provisionerFixture({
        fs: {
            lstatSync: () => metadata, realpathSync: filename => filename,
            chmodSync: (filename, mode) => { changes.push([filename, mode]); metadata.mode = 0o40000 | mode; },
            chownSync: () => { throw new Error('Ownership must not be rewritten'); },
        },
    }).protectBuildVolumeRoot;
    protect('/Volumes/BigWalletBuild');
    protect('/Volumes/BigWalletBuild');
    assert.deepEqual(changes, [['/Volumes/BigWalletBuild', 0o755]]);
    assert.equal(metadata.gid, 80);
});

test('an already protected managed volume root receives no chmod', () => {
    const protect = provisionerFixture({
        fs: {
            lstatSync: () => ({uid: 0, mode: 0o40755, isDirectory: () => true, isSymbolicLink: () => false}),
            realpathSync: filename => filename,
            chmodSync: () => { throw new Error('Correct mode must be left alone'); },
        },
    }).protectBuildVolumeRoot;
    assert.doesNotThrow(() => protect('/Volumes/BigWalletBuild'));
});

test('build-volume protection rejects unrelated paths, ownership, symlinks, and nondirectories without mutation', () => {
    for (const change of [{uid: 501}, {uid: 99}, {isDirectory: () => false}, {isSymbolicLink: () => true}, {canonical: '/elsewhere'}]) {
        const protect = provisionerFixture({
                fs: {
                lstatSync: () => ({uid: 0, mode: 0o40775, isDirectory: () => true, isSymbolicLink: () => false, ...change}),
                realpathSync: filename => change.canonical ?? filename,
                chmodSync: () => { throw new Error('Invalid root must not be changed'); },
            },
        }).protectBuildVolumeRoot;
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
    const location = filename => {
        for (const volume of fixture.volumes) {
            if (volume.MountPoint && filename.startsWith(volume.MountPoint + '/')) {
                return {entries: volume.files, key: filename.slice(volume.MountPoint.length + 1)};
            }
        }
        return {entries: nodes, key: filename};
    };
    const storeNode = (filename, node) => { const {entries, key} = location(filename); entries.set(key, node); };
    const remove = filename => { const {entries, key} = location(filename); entries.delete(key); };
    const descriptors = new Map();
    let nextDescriptor = 10;
    let pendingDurableWrite;
    const fs = {
        lstatSync(filename, options) {
            const node = locate(filename);
            if (node) return metadata(node);
            if (options?.throwIfNoEntry === false) return undefined;
            throw Object.assign(new Error('missing fixture path'), {code: 'ENOENT'});
        },
        realpathSync: filename => locate(filename)?.target ?? filename,
        readFileSync: filename => locate(filename).content,
        openSync(filename, flags, mode) {
            let kind;
            if (/^\/dev\/rdisk\d+$/.test(filename)) {
                assert.equal(flags, 'r'); kind = 'raw';
            } else if (flags === 'wx') {
                assert.equal(locate(filename), undefined);
                storeNode(filename, {kind: 'file', uid: 0, gid: 0, mode, content: ''}); kind = 'file';
            } else {
                assert.equal(flags, 'r'); assert.equal(locate(filename)?.kind, 'directory'); kind = 'directory';
            }
            const descriptor = nextDescriptor++;
            descriptors.set(descriptor, {filename, kind});
            return descriptor;
        },
        readSync(descriptor, bytes) {
            assert.equal(descriptors.get(descriptor)?.kind, 'raw'); bytes.fill(0); return bytes.length;
        },
        writeFileSync(descriptor, bytes) {
            const opened = descriptors.get(descriptor);
            assert.equal(opened?.kind, 'file'); locate(opened.filename).content = String(bytes);
        },
        fchmodSync(descriptor, mode) { locate(descriptors.get(descriptor).filename).mode = mode; },
        fchownSync(descriptor, owner, group) {
            Object.assign(locate(descriptors.get(descriptor).filename), {uid: owner, gid: group});
        },
        fsyncSync(descriptor) {
            const opened = descriptors.get(descriptor);
            assert.ok(opened);
            if (opened.kind !== 'directory') return;
            fixture.events.push(['sync', opened.filename]);
            if (!pendingDurableWrite || path.dirname(pendingDurableWrite.filename) !== opened.filename) return;
            const committed = pendingDurableWrite; pendingDurableWrite = undefined;
            if (committed.filename === intentPath) fixture.events.push(['intent', {...committed.value}]);
            else { fixture.events.push(['marker', committed.value.volumeUUID]); checkpoint('after-marker'); }
        },
        closeSync(descriptor) { assert.ok(descriptors.delete(descriptor)); },
        renameSync(from, to) {
            const node = locate(from);
            assert.equal(node?.kind, 'file');
            const value = JSON.parse(node.content);
            if (to === intentPath) checkpoint(value.volumeUUID ? 'before-uuid' : 'before-intent');
            else {
                checkpoint('before-marker');
                const volume = fixture.volumes.find(item => to === `${item.MountPoint}/.big-wallet-vm.json`);
                assert.ok(volume); assert.equal(volume.root.mode, 0o755);
                assert.equal(JSON.parse(nodes.get(intentPath).content).volumeUUID, volume.APFSVolumeUUID);
            }
            storeNode(to, node); remove(from); pendingDurableWrite = {filename: to, value};
        },
        rmSync(filename, options) { assert.equal(options.force, true); assert.ok(filename.endsWith('.tmp')); remove(filename); },
        chmodSync(filename, mode) { locate(filename).mode = mode; fixture.events.push(['protect', filename]); },
        unlinkSync(filename) {
            assert.equal(filename, intentPath); checkpoint('before-retire'); nodes.delete(filename);
            fixture.events.push(['retire']); checkpoint('after-retire');
        },
    };
    function metadataForDisk(args) {
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
        }
    const options = {fs, config, state, crypto: {randomUUID: () => nonce},
        run(_label, command, args, options) {
            if (command === '/usr/bin/plutil') return options.input;
            assert.equal(command, '/usr/sbin/diskutil');
            if (['info', 'list', 'apfs'].includes(args[0])) return JSON.stringify(metadataForDisk(args));
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
        }
    };
    fixture.fs = fs;
    fixture.execute = options.run;
    fixture.prepare = provisionerFixture(options).prepareBuildData;
    return fixture;
}

test('storage-only provisioning protects guest state before disk setup and returns before full setup', () => {
    for (const failACL of [undefined, '-N', '+a']) {
        const disk = buildInitializationFixture();
        const stage = localStageFilesystem();
        const library = '/guest/library', userHome = '/Users/tester';
        disk.nodes.set(library, {kind: 'directory', uid: 0, gid: 0, mode: 0o755});
        disk.nodes.set(userHome, {kind: 'directory', uid: 501, gid: 20, mode: 0o700});
        const config = {...disk.config, version: 1, consoleUser: 'tester',
            xcode: {version: '27.0', buildVersion: 'fixture'}, xcodeArchive: {path: 'Xcode.tar', sha256: 'a'.repeat(64)},
            runtimes: [{platform: 'iOS', version: '27.0', buildVersion: '24A434', dmgPath: 'ios.dmg'},
                {platform: 'visionOS', version: '27.0', buildVersion: '24M362', dmgPath: 'vision.dmg'}]};
        const sequence = [], logs = [];
        const isStage = filename => typeof filename === 'string' && (filename === stage.parent || filename.startsWith(stage.parent + '/'));
        const fs = {...disk.fs,
            statSync: (...args) => disk.fs.lstatSync(...args),
            existsSync: filename => disk.nodes.has(filename) || stage.nodes.has(filename),
            mkdirSync(filename) { assert.ok([library, disk.state].includes(filename), `Unexpected directory: ${filename}`); },
            chownSync(filename, uid, gid) {
                const node = disk.nodes.get(filename); assert.ok(node); Object.assign(node, {uid, gid});
            },
            readdirSync(filename) { assert.fail(`Unexpected directory inspection: ${filename}`); },
        };
        for (const [name, operation] of Object.entries(stage.fs)) {
            const fallback = fs[name];
            fs[name] = (filename, ...args) => {
                if (isStage(filename)) return operation(filename, ...args);
                assert.equal(typeof fallback, 'function', `Unexpected filesystem operation: ${name}`);
                return fallback(filename, ...args);
            };
        }
        const provisioner = provisionerFixture({config, fs, library, state: disk.state, mode: '--prepare-storage',
            crypto: {randomUUID: () => disk.nonce}, console: {log: value => logs.push(value)},
            run(label, command, args, options) {
                if (command === '/usr/bin/dscl') return `NFSHomeDirectory: ${userHome}`;
                if (command === '/usr/bin/id') return 'staff';
                if (command === '/bin/chmod') {
                    assert.equal(args.at(-1), disk.state); assert.ok(['-N', '+a'].includes(args[0]));
                    sequence.push(`acl:${args[0]}`);
                    if (args[0] === failACL) throw new Error('fixture ACL failure');
                    return '';
                }
                if (command === '/usr/sbin/diskutil') sequence.push('disk');
                return disk.execute(label, command, args, options);
            },
            spawnSync(command, args) {
                assert.equal(command, '/usr/sbin/sysadminctl', 'Full setup must not begin');
                assert.deepEqual(args, ['-autologin', 'status']);
                return {status: 0, stdout: 'Automatic login is enabled for tester', stderr: ''};
            },
        });
        if (failACL) {
            assert.throws(() => provisioner.provisionGuest(), /fixture ACL failure/);
            assert.equal(sequence.includes('disk'), false); assert.equal(disk.formatted, false);
            assert.equal(stage.nodes.size, 1);
            assert.equal(logs.some(value => value.startsWith('BIG_WALLET_PROVISIONING_STAGE=')), false);
        } else {
            provisioner.provisionGuest();
            assert.deepEqual(sequence.slice(0, 3), ['acl:-N', 'acl:+a', 'disk']);
            assert.equal(disk.events.filter(event => event[0] === 'format').length, 1);
            const markers = logs.filter(value => value.startsWith('BIG_WALLET_PROVISIONING_STAGE='));
            assert.equal(markers.length, 1);
            const stagingDirectory = `${stage.parent}/${disk.nonce}/provision`;
            assert.deepEqual(JSON.parse(markers[0].slice('BIG_WALLET_PROVISIONING_STAGE='.length)), {
                stagingDirectory, requiredInputs: ['Xcode.tar', 'ios.dmg', 'vision.dmg'],
            });
            assert.ok(stage.nodes.has(stagingDirectory));
        }
        for (const filename of ['identity.json', 'provisioning.json']) assert.equal(disk.nodes.has(path.join(disk.state, filename)), false);
    }
});

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
    const write = provisionerFixture({fs, crypto: {randomUUID: () => 'fixture'}}).writeDurableJSON;
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
        const inputs = {environment: {}, uid: 502, config: {consoleUser: 'wallet-test'},
            process: {stderr: {write: value => { stderr += value; }}},
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
        const importIdentity = provisionerFixture(inputs).importSigningIdentity;
        operation({filename, payload, inputs,
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
            const original = fixture.inputs.fs.fstatSync;
            fixture.inputs.fs.fstatSync = descriptor => { const metadata = original(descriptor); change(metadata); return metadata; };
            fixture.importer(() => assert.fail('An invalid identity must not reach the importer'));
            assert.throws(fixture.invoke, /private root-owned file/);
        });
    }
    signingImportFixture(fixture => {
        const link = `${fixture.filename}.link`;
        symlinkSync(fixture.filename, link);
        try {
            fixture.importer(() => assert.fail('A linked identity must not reach the importer'));
            const importIdentity = provisionerFixture(fixture.inputs).importSigningIdentity;
            assert.throws(() => importIdentity(link, '/fixture/keychain', 'fixture-password'), {code: 'ELOOP'});
        } finally { rmSync(link); }
    });
});

test('command descriptors reject ambiguous input and leave ordinary command input unchanged', () => {
    const calls = [];
    const run = provisionerFixture({environment: {},
        spawnSync(...arguments_) { calls.push(arguments_); return {status: 0, stdout: 'passed'}; }}).run;
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
});

test('missing signing does not discard an independently validated proof key', () => {
    const result = optionalSigning(() => ({proofKey: 'validated-fixture'}), () => { throw new Error('No development identity'); });
    assert.equal(result.fields.proofKey, 'validated-fixture');
    assert.equal(result.fields.keychainPath, undefined);
    assert.equal(result.missingSigning.length, 1);
    assert.match(result.missingSigning[0], /development signing: No development identity/);
});

test('signing preparation publishes its import marker only after success and reuses it on retry', () => {
    const staging = '/guest/provision';
    const userHome = '/Users/tester';
    const keychainPath = `${userHome}/Library/Keychains/big-wallet-vm.keychain-db`;
    const marker = '/guest/state/signing-import.sha256';
    const files = new Map([
        [staging + '/identity.p12', Buffer.from('fixture identity bytes')],
        [staging + '/identity-password', 'identity-password'], [staging + '/keychain-password', 'keychain-password'],
        [keychainPath, 'existing keychain'],
    ]);
    let importFails = true;
    let imports = 0;
    const config = {consoleUser: 'tester', signing: {p12Path: 'identity.p12', p12PasswordFile: 'identity-password', keychainPasswordFile: 'keychain-password'}};
    const prepare = provisionerFixture({config, staging,
        fs: {constants: filesystem.constants, realpathSync: value => value,
            existsSync: filename => files.has(filename), statSync: filename => ({isFile: () => files.has(filename)}),
            readFileSync: filename => files.get(filename), writeFileSync: (filename, bytes) => files.set(filename, bytes),
            openSync(filename) { assert.equal(filename, staging + '/identity.p12'); return 7; },
            fstatSync: () => ({isFile: () => true, uid: 0, mode: 0o600}), closeSync: descriptor => assert.equal(descriptor, 7),
            mkdirSync() {}, chownSync() {}, readdirSync: () => ['fixture.mobileprovision'],
        },
        run(_label, command, args, options) {
            assert.equal(command, '/usr/bin/security');
            assert.equal(options.user, true);
            if (args[0] === 'import') {
                imports += 1;
                assert.equal(options.inputFD, 7);
                if (importFails) throw new Error('fixture identity import failed');
            }
            if (args[0] === 'find-identity') return '1 valid identities found';
            if (args[0] === 'list-keychains' && !args.includes('-s')) return '"' + keychainPath + '"';
            return '';
        },
    }).prepareSigning;
    const failed = prepare(userHome);
    assert.equal(failed.fields.keychainPath, undefined);
    assert.ok(failed.missingSigning.some(message => /identity import failed/.test(message)));
    assert.equal(files.has(marker), false);
    importFails = false;
    const succeeded = prepare(userHome);
    assert.equal(succeeded.fields.keychainPath, keychainPath);
    assert.equal(succeeded.fields.keychainPassword, 'keychain-password');
    assert.equal(files.get(marker), createHash('sha256').update(files.get(staging + '/identity.p12')).digest('hex') + '\n');
    prepare(userHome, succeeded.fields);
    assert.equal(imports, 2);
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


test('UI automation provisioning uses the supported guest administrator tool and verifies the selected user', () => {
    const calls = [];
    const configure = provisionerFixture({run(label, file, args, options = {}) {
        calls.push({file, args: [...args], user: options.user ?? false, timeout: options.timeout, killSignal: options.killSignal});
        return args.length ? 'succeeded.' : 'Automation Mode is disabled.\nThis device DOES NOT REQUIRE user authentication to enable Automation Mode.';
    }}).configureUIAutomation;
    configure();
    assert.deepEqual(calls, [
        {file: '/usr/bin/automationmodetool', args: ['enable-automationmode-without-authentication'], user: false, timeout: 30000, killSignal: 'SIGKILL'},
        {file: '/usr/bin/automationmodetool', args: [], user: true, timeout: 10000, killSignal: 'SIGKILL'},
    ]);
});

test('UI automation provisioning rejects required authentication even when automation is already enabled', () => {
    for (const status of [
        'Automation Mode is ENABLED.\nThis device requires user authentication to enable Automation Mode.',
        'Automation Mode is ENABLED.', '', 'unexpected output',
    ]) {
        const configure = provisionerFixture({run: (_label, _file, args) => args.length ? 'succeeded.' : status}).configureUIAutomation;
        assert.throws(configure, /still requires authentication.*setup --interactive/);
    }
});

test('UI automation provisioning preserves administrator or selected-user verification failures', () => {
    for (const failureCall of [1, 2]) {
        let calls = 0;
        const configure = provisionerFixture({run() {
            if (++calls === failureCall) throw new Error('fixture authorization unavailable');
            return 'succeeded.';
        }}).configureUIAutomation;
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
    const ensure = provisionerFixture({fs: fakeFS}).ensureUserDeveloperDirectories;
    ensure('/Users/tester', 501, 20);
    assert.deepEqual([...directories.keys()], ['/Users/tester/Library', '/Users/tester/Library/Developer', '/Users/tester/Library/Developer/Xcode']);
    assert.ok([...directories.values()].every(value => value.owner === 501 && value.group === 20));
    const rejectsSymlink = provisionerFixture({fs: {...fakeFS,
        lstatSync: () => ({isDirectory: () => false, isSymbolicLink: () => true})}}).ensureUserDeveloperDirectories;
    assert.throws(() => rejectsSymlink('/Users/tester', 501, 20), /regular directory/);
});

test('runtime storage guards measure download headroom and a reserve beyond the staged image', () => {
    assert.equal(rootSpaceRequirement(), 16 * 1024 ** 3);
    assert.equal(rootSpaceRequirement(10 * 1024 ** 3), 18 * 1024 ** 3);
    for (const size of [0, -1, 1.5, Number.MAX_SAFE_INTEGER, Infinity]) assert.throws(() => rootSpaceRequirement(size), /size is invalid/);
});

function runtimeExportFixture() {
    const directory = filesystem.realpathSync(mkdtempSync(path.join(tmpdir(), 'wallet-runtime-export-')));
    const bytes = provisionerFixture({fs: filesystem}).runtimeArtifactBytes;
    const select = provisionerFixture({fs: filesystem}).exportedRuntimeImage;
    const bundle = (name = 'iOS.exportedBundle') => {
        const artifact = path.join(directory, name);
        mkdirSync(path.join(artifact, 'Restore'), {recursive: true});
        writeFileSync(path.join(artifact, 'Restore/runtime.dmg'), Buffer.alloc(128, 1));
        writeFileSync(path.join(artifact, 'Info.plist'), 'fixture secure export metadata');
        return artifact;
    };
    return {directory, bytes, select: () => select(directory), bundle, close: () => rmSync(directory, {recursive: true, force: true})};
}

test('runtime export discovery preserves the complete Apple bundle and counts its metadata', () => {
    for (const suffix of ['exportedBundle', 'exportBundle']) {
        const fixture = runtimeExportFixture();
        try {
            const artifact = fixture.bundle(`iOS.${suffix}`);
            const metadata = readFileSync(path.join(artifact, 'Info.plist'));
            assert.equal(fixture.select(), artifact);
            assert.equal(fixture.bytes(artifact), 128 + metadata.length);
            assert.deepEqual(readFileSync(path.join(artifact, 'Info.plist')), metadata);
        } finally { fixture.close(); }
    }
});

test('runtime export discovery still selects a standalone external DMG', () => {
    const fixture = runtimeExportFixture();
    try {
        const artifact = path.join(fixture.directory, 'iOS.dmg');
        writeFileSync(artifact, Buffer.alloc(64, 1));
        assert.equal(fixture.select(), artifact);
        assert.equal(fixture.bytes(artifact), 64);
    } finally { fixture.close(); }
});

test('runtime export discovery rejects multiple independent artifacts', () => {
    const fixture = runtimeExportFixture();
    try {
        fixture.bundle();
        writeFileSync(path.join(fixture.directory, 'another.dmg'), 'image');
        assert.throws(fixture.select, /exactly one/);
    } finally { fixture.close(); }
});

test('runtime artifact inspection rejects missing metadata, nested bundles, and symlinks', () => {
    for (const kind of ['metadata', 'nested', 'symlink', 'image-directory']) {
        const fixture = runtimeExportFixture();
        try {
            const artifact = fixture.bundle();
            if (kind === 'metadata') filesystem.unlinkSync(path.join(artifact, 'Info.plist'));
            if (kind === 'nested') mkdirSync(path.join(artifact, 'nested.exportedBundle'));
            if (kind === 'symlink') symlinkSync(path.join(artifact, 'Info.plist'), path.join(artifact, 'metadata-link'));
            if (kind === 'image-directory') {
                filesystem.unlinkSync(path.join(artifact, 'Restore/runtime.dmg'));
                mkdirSync(path.join(artifact, 'Restore/runtime.dmg'));
            }
            assert.throws(fixture.select, /incomplete|Nested|regular files/);
        } finally { fixture.close(); }
    }
    const fixture = runtimeExportFixture();
    try {
        const artifact = fixture.bundle();
        symlinkSync(artifact, path.join(fixture.directory, 'alias'));
        assert.throws(fixture.select, /symlinks/);
    } finally { fixture.close(); }
});

test('runtime artifact inspection is bounded and storage checks use all bundle file bytes', () => {
    const fixture = runtimeExportFixture();
    try {
        const artifact = fixture.bundle();
        const checkpoint = provisionerFixture({console: {log() {}}, fs: {...filesystem, statfsSync: () => ({
                bavail: 8 * 1024 ** 3 + 128, bsize: 1, blocks: 64 * 1024 ** 3})}}).runtimeStorageCheckpoint;
        assert.throws(() => checkpoint('/guest/build', 'iOS', artifact), /Insufficient guest system-volume/);
        const limited = provisionerFixture({fs: {...filesystem,
            lstatSync(filename) {
                const metadata = filesystem.lstatSync(filename);
                return filename.endsWith('.dmg') ? {...metadata, size: 129 * 1024 ** 3,
                    isFile: () => true, isDirectory: () => false, isSymbolicLink: () => false} : metadata;
            }}}).runtimeArtifactBytes;
        assert.throws(() => limited(artifact), /bounded byte/);
        let nested = artifact;
        for (let depth = 0; depth < 17; depth += 1) nested = path.join(nested, 'nested');
        mkdirSync(nested, {recursive: true});
        assert.throws(fixture.select, /bounded inspection/);
    } finally { fixture.close(); }
});

function runtimeProvisioningFixture({platform = 'iOS', reused = false, dmgPath, importedBuild, cacheError, cachedBuild,
    cacheUnavailable = false, previous, freeBefore = 64 * 1024 ** 3, buildFreeBefore = freeBefore, freeAfter = 64 * 1024 ** 3,
    deviceExists = true, additionalPins = [], supersededRuntimes, onRetirement} = {}) {
    const wanted = {platform, version: '27.0', buildVersion: platform === 'iOS' ? '24A434' : '24M362', ...(dmgPath ? {dmgPath} : {})};
    const requested = [wanted, ...additionalPins];
    const buildRoot = '/Volumes/BigWalletBuild';
    const staging = `${buildRoot}/Provisioning/00000000-0000-4000-8000-000000000001/provision`;
    const state = '/guest/state', developer = '/Applications/Xcode.app/Contents/Developer';
    const config = {vmId: 'fixture', consoleUser: 'tester', runtimes: requested, supersededRuntimes};
    const commands = [], cacheCommands = [], nativeCommands = [], events = [], removed = [], retired = [];
    const nodes = new Map(), images = new Map(), profileOverrides = new Map(), artifactPins = new Map();
    const devices = {};
    let nextIdentity = 1;
    const uuid = () => `00000000-0000-4000-8000-${String(nextIdentity++).padStart(12, '0')}`;
    const samePin = (a, b) => a.platform === b.platform && a.version === b.version && a.buildVersion === b.buildVersion;
    const runtimeID = pin => `com.apple.CoreSimulator.SimRuntime.${pin.platform === 'iOS' ? 'iOS' : 'xrOS'}-${pin.version.replaceAll('.', '-')}`;
    const deviceName = pin => pin.platform === 'iOS' ? 'iPhone 18 Pro' : 'Apple Vision Pro';
    function directory(filename, mode = 0o755) {
        const parent = path.dirname(filename);
        if (parent !== filename && !nodes.has(parent)) directory(parent);
        if (!nodes.has(filename)) nodes.set(filename, {kind: 'directory', mode, uid: 0, gid: 20, ino: nextIdentity++});
    }
    function file(filename, content = '', size = Buffer.byteLength(content), mode = 0o600) {
        directory(path.dirname(filename));
        nodes.set(filename, {kind: 'file', content, size, mode, uid: 0, gid: 20, ino: nextIdentity++});
    }
    function metadata(filename, options) {
        const value = nodes.get(filename);
        if (!value) {
            if (options?.throwIfNoEntry === false) return undefined;
            throw Object.assign(new Error(`Missing fixture path: ${filename}`), {code: 'ENOENT'});
        }
        return {...value, dev: 1, size: value.size ?? 0, mtimeMs: 1, ctimeMs: 1,
            isDirectory: () => value.kind === 'directory', isFile: () => value.kind === 'file', isSymbolicLink: () => false};
    }
    directory(buildRoot); directory(state); directory(staging, 0o700);
    nodes.get(path.dirname(staging)).mode = 0o700;
    nodes.get(path.dirname(path.dirname(staging))).mode = 0o700;
    file(path.join(path.dirname(staging), '.big-wallet-provisioning.json'), JSON.stringify({version: 1, vmId: config.vmId}));
    if (previous !== undefined) file(path.join(state, 'provisioning.json'), JSON.stringify(previous));
    for (const pin of requested) {
        if (pin.dmgPath) {
            const filename = path.join(staging, pin.dmgPath);
            file(filename, '', 2 * 1024 ** 3); artifactPins.set(filename, pin);
        }
    }
    function addRuntime(pin, target = false) {
        const identifier = uuid();
        const mountPath = `/Library/Developer/CoreSimulator/Volumes/${identifier}`;
        const runtimeBundlePath = `${mountPath}/Library/Developer/CoreSimulator/Profiles/Runtimes/Fixture.simruntime`;
        const image = {identifier, runtimeIdentifier: runtimeID(pin),
            platformIdentifier: `com.apple.platform.${pin.platform === 'iOS' ? 'iphone' : 'xr'}simulator`,
            version: pin.version, build: pin.buildVersion, kind: 'Disk Image', state: 'Ready', signatureState: 'Verified', deletable: true,
            path: `/Library/Developer/CoreSimulator/Images/${identifier}.dmg`, mountPath, runtimeBundlePath, sizeBytes: 1024};
        const record = {pin: {...pin}, image};
        images.set(identifier, record); directory(runtimeBundlePath); file(image.path, '', image.sizeBytes);
        devices[image.runtimeIdentifier] ??= [];
        if (target && deviceExists && !devices[image.runtimeIdentifier].length) {
            devices[image.runtimeIdentifier].push({udid: uuid(), name: deviceName(pin), isAvailable: true, state: 'Shutdown'});
        }
        return record;
    }
    const oldPins = (supersededRuntimes ?? previous?.runtimes ?? []).filter(old =>
        requested.some(pin => pin.platform === old.platform && !samePin(pin, old)));
    oldPins.forEach(pin => addRuntime(pin));
    if (reused) requested.forEach(pin => addRuntime(pin, true));
    const profiles = () => [...images.values()].map(({pin, image}) => ({identifier: image.runtimeIdentifier,
        version: pin.version, buildversion: pin.buildVersion, isAvailable: true, bundlePath: image.runtimeBundlePath,
        runtimeRoot: path.join(image.runtimeBundlePath, 'Contents/Resources/RuntimeRoot'), ...profileOverrides.get(image.identifier)}));
    const fs = {
        existsSync: filename => nodes.has(filename), realpathSync: filename => filename,
        lstatSync: metadata, statSync: metadata, mkdirSync: (filename, options = {}) => directory(filename, options.mode),
        readFileSync(filename) { metadata(filename); return nodes.get(filename).content; },
        readdirSync(filename) {
            assert.ok(metadata(filename).isDirectory());
            return [...nodes.keys()].filter(candidate => candidate !== filename && path.dirname(candidate) === filename).map(candidate => path.basename(candidate));
        },
        rmSync(filename) { metadata(filename); removed.push(filename); nodes.delete(filename); },
        openSync(filename) { assert.ok(metadata(filename).isDirectory()); return 7; }, fsyncSync() {}, closeSync() {},
        statfsSync(filename) {
            assert.ok([buildRoot, '/System/Volumes/Data'].includes(filename));
            const initial = filename === buildRoot ? buildFreeBefore : freeBefore;
            const reclaimed = Array.isArray(freeAfter) ? freeAfter[retired.length - 1] : freeAfter;
            return {bavail: retired.length ? reclaimed : initial, bsize: 1, blocks: 96 * 1024 ** 3};
        },
    };
    function execute(label, command, originalArgs, options = {}) {
        let args = [...originalArgs];
        nativeCommands.push({label, command, args: [...args], options: {...options}});
        if (command === '/usr/bin/xcodebuild') {
            commands.push([command, ...args]); events.push(args[0]);
            if (args[0] === '-downloadPlatform') {
                const pin = requested.find(value => value.platform === args[1] && value.buildVersion === args[args.indexOf('-buildVersion') + 1]);
                assert.ok(pin);
                const output = path.join(args[args.indexOf('-exportPath') + 1], 'downloaded.dmg');
                file(output, '', 2 * 1024 ** 3); artifactPins.set(output, pin);
            } else {
                assert.equal(args[0], '-importPlatform');
                const pin = artifactPins.get(args[1]); assert.ok(pin);
                addRuntime({...pin, buildVersion: importedBuild ?? pin.buildVersion}, true);
            }
            return '';
        }
        if (command === '/usr/bin/plutil') {
            assert.equal(args[0], '-extract');
            const record = [...images.values()].find(({image}) => args.at(-1).startsWith(image.runtimeBundlePath + '/'));
            assert.ok(record);
            if (args[1] === 'ProductVersion') return record.pin.version;
            assert.equal(args[1], 'ProductBuildVersion'); return record.pin.buildVersion;
        }
        if (command === '/sbin/mount') return [...images.values()].map(({image}, index) =>
            `/dev/disk${index + 10}s1 on ${image.mountPath} (apfs, sealed, read-only)`).join('\n');
        if (command === '/usr/bin/env') {
            assert.equal(args[0], `DEVELOPER_DIR=${developer}`);
            if (args.slice(2, 5).join(' ') === 'simctl runtime dyld_shared_cache') cacheCommands.push({command, args: [...args], options: {...options}});
            command = args[1]; args = args.slice(2);
        }
        assert.equal(command, '/usr/bin/xcrun'); assert.equal(args[0], 'simctl');
        const action = args.slice(1);
        let output;
        if (action.join(' ') === 'runtime list --json') output = JSON.stringify(Object.fromEntries([...images].map(([identifier, {image}]) => [identifier, image])));
        else if (action[0] === 'runtime' && action[1] === 'verify') {
            assert.ok(images.has(action[2])); events.push('verify'); output = 'Signature verified, signature is valid.';
        } else if (action[0] === 'runtime' && action[1] === 'delete') {
            const record = images.get(action[2]); assert.ok(record);
            assert.ok(oldPins.some(pin => samePin(pin, record.pin)), 'Only an old exact pin may be deleted');
            images.delete(action[2]); retired.push(record.pin.platform); events.push('retire');
            onRetirement?.([record.pin], requested.filter(pin => pin.platform === record.pin.platform), false);
            output = '';
        } else if (action[0] === 'runtime' && action[1] === 'dyld_shared_cache') {
            assert.equal(action[2], 'update');
            const record = [...images.values()].find(({pin, image}) => image.runtimeIdentifier === action[3] && requested.some(value => samePin(value, pin)));
            assert.ok(record); events.push('cache');
            if (cacheError) throw new Error(cacheError);
            if (cachedBuild || cacheUnavailable) profileOverrides.set(record.image.identifier,
                {buildversion: cachedBuild ?? record.pin.buildVersion, isAvailable: !cacheUnavailable});
            output = 'dyld shared cache is usable at path: fixture';
        } else if (action.join(' ') === 'list runtimes --json') {
            if (label === 'List guest runtimes' || label.startsWith('Recheck ')) events.push('runtimes');
            output = JSON.stringify({runtimes: profiles()});
        } else if (action.join(' ') === 'list devices --json') {
            if (label === 'List guest simulator devices') events.push('devices');
            output = JSON.stringify({devices});
        } else if (action.join(' ') === 'list devicetypes --json') {
            events.push('devicetypes');
            output = JSON.stringify({devicetypes: requested.map(pin => ({name: deviceName(pin), identifier: `${pin.platform}-fixture-device`}))});
        } else if (action[0] === 'create') {
            const pin = requested.find(value => runtimeID(value) === action[3]); assert.ok(pin);
            assert.equal(action[1], deviceName(pin)); assert.equal(action[2], `${pin.platform}-fixture-device`);
            devices[action[3]] = [{udid: uuid(), name: action[1], isAvailable: true, state: 'Shutdown'}];
            events.push('create'); output = '';
        } else assert.fail(`Unexpected fixture command: ${label}: ${command} ${args.join(' ')}`);
        return options.returnStatus ? {status: 0, stdout: output, stderr: ''} : output;
    }
    const provisioner = provisionerFixture({config, staging, state, developer, fs, run: execute,
        console: {log(value) { if (value.startsWith('Verified retirement of ')) events.push('retirement-check'); }}});
    return {wanted, staging, buildRoot, commands, cacheCommands, nativeCommands, events, removed, retired, images,
        run() { provisioner.prepareRuntimes(buildRoot, provisioner.loadPreviousProvisioning('/Users/tester')); }};
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

test('guest setup retires prior same-account pins after device readiness and checks absence after verification', () => {
    const previous = {version: 1, vmId: 'fixture', consoleUser: 'tester',
        runtimes: [{platform: 'iOS', version: '26.4', buildVersion: '23E222'}]};
    const fixture = runtimeProvisioningFixture({previous});
    fixture.run();
    assert.ok(fixture.events.indexOf('devices') > fixture.events.indexOf('cache'));
    assert.ok(fixture.events.indexOf('retire') > fixture.events.lastIndexOf('devices'));
    assert.deepEqual(fixture.events.slice(-2), ['verify', 'retirement-check']);
    assert.equal(fixture.commands.filter(command => command[1] === '-importPlatform').length, 1);
    const failed = runtimeProvisioningFixture({previous, cacheError: 'fixture cache failed'});
    assert.throws(failed.run, /fixture cache failed/);
    assert.ok(!failed.events.includes('retire'));
    for (const changed of [{vmId: 'other-vm'}, {consoleUser: 'other-user'}]) {
        const other = runtimeProvisioningFixture({previous: {...previous, ...changed}});
        assert.throws(other.run, /different VM or account/);
        assert.deepEqual(other.events, []);
        assert.deepEqual(other.commands, []);
    }
});

test('guest setup retires early only below the measured download reserve and rechecks free space', () => {
    const reserve = 16 * 1024 ** 3;
    const previous = {version: 1, vmId: 'fixture', consoleUser: 'tester',
        runtimes: [{platform: 'iOS', version: '26.4', buildVersion: '23E222'}]};
    const sufficient = runtimeProvisioningFixture({previous, freeBefore: reserve});
    sufficient.run();
    assert.ok(sufficient.events.indexOf('retire') > sufficient.events.lastIndexOf('devices'));
    const reclaimable = runtimeProvisioningFixture({previous, freeBefore: reserve - 1, freeAfter: reserve});
    reclaimable.run();
    assert.ok(reclaimable.events.includes('retire'));
    assert.ok(reclaimable.events.indexOf('retire') < reclaimable.events.indexOf('-downloadPlatform'));
    assert.equal(reclaimable.events.filter(event => event === 'retire').length, 1);
    const exhausted = runtimeProvisioningFixture({previous, freeBefore: reserve - 1, freeAfter: reserve - 1});
    assert.throws(exhausted.run, /Insufficient guest system-volume space/);
    assert.equal(exhausted.events.filter(event => event === 'retire').length, 1);
    assert.deepEqual(exhausted.commands, []);
});

test('two-platform upgrades reclaim the second old runtime only if the first leaves too little space', () => {
    const previous = {version: 1, vmId: 'fixture', consoleUser: 'tester', runtimes: [
        {platform: 'iOS', version: '26.4', buildVersion: '23E222'},
        {platform: 'visionOS', version: '26.4', buildVersion: '23N111'},
    ]};
    const additionalPins = [{platform: 'visionOS', version: '27.0', buildVersion: '24M362'}];
    for (const reused of [false, true]) {
        const reserve = (reused ? 8 : 16) * 1024 ** 3;
        for (const firstIsEnough of [true, false]) {
            const fixture = runtimeProvisioningFixture({previous, additionalPins, reused, freeBefore: reserve - 2,
                freeAfter: [firstIsEnough ? reserve : reserve - 1, reserve]});
            fixture.run();
            assert.deepEqual(fixture.retired, ['iOS', 'visionOS']);
            const firstOperation = fixture.events.indexOf(reused ? 'cache' : '-downloadPlatform');
            assert.equal(fixture.events.slice(0, firstOperation).filter(value => value === 'retire').length, firstIsEnough ? 1 : 2);
            if (firstIsEnough) assert.ok(fixture.events.lastIndexOf('retire') > fixture.events.lastIndexOf('devices'));
        }
    }
});

test('resuming with an installed replacement reclaims space on the volume needed for cache or device preparation', () => {
    const reserve = 8 * 1024 ** 3;
    const previous = {version: 1, vmId: 'fixture', consoleUser: 'tester',
        runtimes: [{platform: 'iOS', version: '26.4', buildVersion: '23E222'}]};
    for (const [freeBefore, buildFreeBefore, expected] of [
        [reserve - 1, reserve, ['retire', 'cache', 'create']],
        [reserve, reserve - 1, ['cache', 'retire', 'create']],
        [reserve, reserve, ['cache', 'create', 'retire']],
    ]) {
        const fixture = runtimeProvisioningFixture({previous, reused: true, deviceExists: false, freeBefore, buildFreeBefore});
        fixture.run();
        assert.deepEqual(fixture.events.filter(event => ['cache', 'create', 'retire'].includes(event)), expected);
        assert.deepEqual(fixture.commands, []);
    }
    const failed = runtimeProvisioningFixture({previous, reused: true, cacheError: 'fixture cache error'});
    assert.throws(failed.run, /fixture cache error/);
    assert.ok(!failed.events.includes('retire'));
});

test('guest setup retires a replaced build with the same runtime identifier before import', () => {
    const previous = {version: 1, vmId: 'fixture', consoleUser: 'tester',
        runtimes: [{platform: 'iOS', version: '27.0', buildVersion: '24A111'}]};
    const fixture = runtimeProvisioningFixture({previous});
    fixture.run();
    assert.ok(fixture.events.includes('retire'));
    assert.ok(fixture.events.indexOf('retire') < fixture.events.indexOf('-importPlatform'));
});

test('runtime provisioning rejects a different installed build after downloading', () => {
    const fixture = runtimeProvisioningFixture({importedBuild: '24A999'});
    assert.throws(fixture.run, /pinned runtime image inventory is missing or ambiguous/);
    assert.equal(fixture.commands.length, 2);
});

test('runtime provisioning reuses an already installed exact build without downloading or importing', () => {
    for (const dmgPath of [undefined, 'runtime.dmg']) {
        const fixture = runtimeProvisioningFixture({reused: true, dmgPath});
        fixture.run();
        assert.deepEqual(fixture.commands, []);
        assert.deepEqual(fixture.removed, dmgPath ? [path.join(fixture.staging, 'runtime.dmg')] : []);
    }
});

test('runtime provisioning imports an explicit DMG without downloading', () => {
    const fixture = runtimeProvisioningFixture({dmgPath: 'runtime.dmg'});
    fixture.run();
    assert.deepEqual(fixture.commands, [['/usr/bin/xcodebuild', '-importPlatform', path.join(fixture.staging, 'runtime.dmg')]]);
    assert.deepEqual(fixture.removed, [path.join(fixture.staging, 'runtime.dmg')]);
});

test('runtime provisioning awaits the exact pinned cache and rechecks it before device readiness', () => {
    for (const platform of ['iOS', 'visionOS']) {
        const fixture = runtimeProvisioningFixture({platform, reused: true});
        fixture.run();
        assert.deepEqual(fixture.commands, []);
        assert.equal(fixture.cacheCommands.length, 1);
        const cached = fixture.cacheCommands[0];
        assert.deepEqual(cached.args, ['DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer', '/usr/bin/xcrun',
            'simctl', 'runtime', 'dyld_shared_cache', 'update',
            `com.apple.CoreSimulator.SimRuntime.${platform === 'iOS' ? 'iOS' : 'xrOS'}-27-0`]);
        assert.equal(cached.options.user, true);
        assert.equal(cached.options.timeout, 1_800_000);
        assert.equal(cached.options.maxBuffer, 64 * 1024);
        assert.equal(cached.options.logStdout, true);
        assert.equal(cached.args.includes('--force'), false);
        assert.equal(cached.args.includes('--all'), false);
        const position = fixture.events.indexOf('cache');
        assert.equal(fixture.events[position + 1], 'runtimes');
        assert.ok(fixture.events.indexOf('devicetypes') > position + 1);
    }
});

test('cache preparation failures and post-cache runtime drift block setup before device readiness', () => {
    for (const options of [{cacheError: 'fixture cache failed'}, {cachedBuild: '24A999'}, {cacheUnavailable: true}]) {
        const fixture = runtimeProvisioningFixture({reused: true, ...options});
        assert.throws(fixture.run, /fixture cache failed|changed or became unavailable/);
        assert.equal(fixture.events.includes('devicetypes'), false);
        assert.equal(fixture.events.includes('devices'), false);
    }
});

test('cache command output is bounded and retained on failure without enabling secret logging', () => {
    const written = [];
    const calls = [];
    let result = {status: 1, stdout: 'bounded cache failure details', stderr: ''};
    const command = provisionerFixture({
        uidText: '501', config: {consoleUser: 'wallet-test'},
        environment: {DEVELOPER_DIR: '/Applications/Xcode.app/Contents/Developer'},
        process: {stdout: {write: value => written.push(value)}, stderr: {write() {}}},
        spawnSync(file, args, options) {
            calls.push({file, args: Array.from(args), options});
            return result;
        }}).run;
    const options = {user: true, maxBuffer: 64 * 1024, timeout: 1_800_000, logStdout: true};
    assert.throws(() => command('Cache preparation', '/usr/bin/env', ['DEVELOPER_DIR=pinned', '/usr/bin/xcrun'], options), /failed/);
    assert.equal(calls[0].options.maxBuffer, 64 * 1024);
    assert.equal(calls[0].file, '/bin/launchctl');
    assert.deepEqual(written, ['bounded cache failure details']);
    assert.throws(() => command('Secret command', '/usr/bin/fixture', [], {...options, secret: true}), /failed/);
    assert.equal(written.length, 1);
    assert.throws(() => command('Invalid buffer', '/usr/bin/fixture', [], {...options, maxBuffer: Infinity}), /output limit/);
    for (const interruption of [{error: {code: 'ETIMEDOUT'}}, {error: {code: 'ENOBUFS'}}, {signal: 'SIGTERM'}]) {
        result = {status: 0, stdout: '', stderr: '', ...interruption};
        assert.throws(() => command('Cache preparation', '/usr/bin/env', [], options), /failed/);
    }
});

function runtimeRetirementFixture(t, {iosVersion = '27.2'} = {}) {
    const root = filesystem.realpathSync(mkdtempSync(path.join(tmpdir(), 'wallet-runtime-retirement-')));
    t.after(() => rmSync(root, {recursive: true, force: true}));
    const buildRoot = path.join(root, 'build'), state = path.join(root, 'state');
    const vmId = 'fixture-vm';
    const images = new Map(), devices = {}, mutations = [];
    const add = (platform, version, buildVersion) => {
        const pin = {platform, version, buildVersion};
        const key = [platform, version, buildVersion].join('-');
        const marker = platform === 'iOS' ? 'iOS' : 'xrOS';
        const runtimeIdentifier = 'com.apple.CoreSimulator.SimRuntime.' + marker + '-' + version.replaceAll('.', '-');
        const image = {identifier: randomUUID(), runtimeIdentifier, version, build: buildVersion, state: 'Ready',
            platformIdentifier: 'com.apple.platform.' + (platform === 'iOS' ? 'iphone' : 'xr') + 'simulator',
            signatureState: 'Verified', deletable: true, kind: 'Disk Image'};
        image.path = '/Library/Developer/CoreSimulator/Images/' + image.identifier + '.dmg';
        images.set(image.identifier, image);
        const device = {udid: randomUUID(), name: platform === 'iOS' ? 'iPhone 18 Pro' : 'Apple Vision Pro',
            isAvailable: true, state: 'Shutdown'};
        (devices[runtimeIdentifier] ??= []).push(device);
        const download = path.join(buildRoot, 'RuntimeDownloads', key);
        const repairSource = path.join(buildRoot, 'RuntimeRepairSources', key);
        const receipt = path.join(state, 'RuntimeRepairs', key + '.json');
        for (const directory of [download, repairSource, path.dirname(receipt)]) mkdirSync(directory, {recursive: true, mode: 0o700});
        writeFileSync(path.join(download, 'runtime.dmg'), 'exported fixture');
        const sourcePath = path.join(repairSource, 'runtime.dmg');
        writeFileSync(sourcePath, 'preserved fixture');
        writeFileSync(receipt, JSON.stringify({version: 1, vmId, pin, phase: 'complete', sourcePath}), {mode: 0o600});
        return {pin, image, device, artifacts: [download, repairSource, receipt]};
    };
    const previous = [add('iOS', '27.0', '24A434'), add('visionOS', '27.0', '24M362')];
    const wanted = [add('iOS', iosVersion, '24B8117'), add('visionOS', '27.2', '24N120')];
    const unrelated = add('iOS', '26.4', '23E222');
    const developer = '/Applications/Xcode.app/Contents/Developer';
    const behavior = {};
    const synced = [];
    const run = (_label, file, args, options) => {
        if (file === '/usr/bin/find') {
            assert.deepEqual(Array.from(args), ['.', '-xdev', '-mindepth', '1', '-delete']);
            behavior.beforeWalk?.(process.cwd());
            return execFileSync(file, Array.from(args), {encoding: 'utf8'});
        }
        assert.equal(file, '/usr/bin/env');
        assert.deepEqual(Array.from(args).slice(0, 3), ['DEVELOPER_DIR=' + developer, '/usr/bin/xcrun', 'simctl']);
        assert.equal(options.user, true);
        const command = Array.from(args).slice(3);
        if (command.join(' ') === 'runtime list --json') return JSON.stringify(Object.fromEntries(images));
        if (command.join(' ') === 'list devices --json') return JSON.stringify({devices});
        if (command.join(' ') === 'list runtimes --json') return JSON.stringify({runtimes: [...images.values()].map(image => ({
            identifier: image.runtimeIdentifier, version: image.version, buildversion: image.build, isAvailable: true}))});
        if (command[0] === 'delete') {
            assert.equal(command.length, 2);
            const attached = Object.values(devices).find(values => values.some(device => device.udid === command[1]));
            assert.ok(attached, 'device deletion requires a single live UUID');
            attached.splice(attached.findIndex(device => device.udid === command[1]), 1);
        } else {
            assert.deepEqual(command.slice(0, 2), ['runtime', 'delete']);
            assert.equal(command.length, 3);
            assert.ok(images.delete(command[2]), 'image deletion requires a single live UUID');
        }
        mutations.push(command);
        behavior.afterMutation?.(command);
        if (behavior.interrupt === command.at(-1)) {
            delete behavior.interrupt;
            throw new Error('fixture interruption after native deletion');
        }
        return '';
    };
    const openDirectories = new Map();
    const fs = {...filesystem,
        openSync(filename, ...args) { const descriptor = filesystem.openSync(filename, ...args); openDirectories.set(descriptor, filename); return descriptor; },
        fsyncSync(descriptor) { filesystem.fsyncSync(descriptor); const directory = openDirectories.get(descriptor); synced.push(directory); behavior.onSync?.(directory); },
        closeSync(descriptor) { openDirectories.delete(descriptor); filesystem.closeSync(descriptor); },
        lstatSync(filename, options) {
        const info = filesystem.lstatSync(filename, options);
        if (info) info.uid = filename === behavior.assetOwnedPath ? 200 : 0;
        if (info && filename === behavior.mount) info.dev++;
        return info;
    }};
    const retire = provisionerFixture({run, fs, developer, state, config: {vmId}, process}).retireSupersededRuntimes;
    const setup = (from = previous, to = wanted, verifyOnly = false) =>
        retire(from.map(record => record.pin), to.map(record => record.pin), buildRoot, verifyOnly);
    const assertPresent = (record, present) => {
        assert.equal(images.has(record.image.identifier), present);
        assert.equal(Object.values(devices).flat().some(device => device.udid === record.device.udid), present);
        for (const artifact of record.artifacts) assert.equal(filesystem.existsSync(artifact), present, artifact);
    };
    return {previous, wanted, unrelated, behavior, images, devices, mutations, synced, setup, assertPresent};
}

test('superseded runtimes retire their images, devices, downloads and repair artifacts by exact pin', t => {
    const fixture = runtimeRetirementFixture(t);
    fixture.setup();
    for (const record of fixture.previous) fixture.assertPresent(record, false);
    for (const record of [...fixture.wanted, fixture.unrelated]) fixture.assertPresent(record, true);
});

test('a cold retry retires a returned baseline runtime after the guest records the replacement', t => {
    const inventory = runtimeRetirementFixture(t);
    const baseline = inventory.unrelated, replacement = inventory.previous[0];
    const previous = {version: 1, vmId: 'fixture', consoleUser: 'tester', runtimes: [replacement.pin]};
    const options = {reused: true, supersededRuntimes: [baseline.pin]};
    for (const record of [undefined, {...previous, runtimes: [inventory.wanted[0].pin]}]) {
        const denied = runtimeProvisioningFixture({...options, previous: record});
        assert.throws(denied.run, /same-guest provisioning record|pins differ from the source baseline/);
        assert.deepEqual(denied.events, []);
    }
    const fixture = runtimeProvisioningFixture({...options, previous, onRetirement(from, to, verifyOnly) {
        inventory.setup(from.map(pin => ({pin})), to.map(pin => ({pin})), verifyOnly);
    }});
    fixture.run();
    assert.deepEqual(fixture.commands, []);
    assert.ok(fixture.events.lastIndexOf('verify') > fixture.events.lastIndexOf('retire'));
    assert.equal(fixture.events.at(-1), 'retirement-check');
    inventory.assertPresent(baseline, false);
    for (const kept of [...inventory.previous, ...inventory.wanted]) inventory.assertPresent(kept, true);
});

test('superseded runtime retirement resumes after an exact device or image deletion', t => {
    for (const kind of ['image', 'device']) {
        const fixture = runtimeRetirementFixture(t);
        const record = fixture.previous[0];
        fixture.behavior.interrupt = kind === 'image' ? record.image.identifier : record.device.udid;
        assert.throws(() => fixture.setup(), /fixture interruption after native deletion/);
        fixture.setup();
        for (const retired of fixture.previous) fixture.assertPresent(retired, false);
        for (const kept of [...fixture.wanted, fixture.unrelated]) fixture.assertPresent(kept, true);
    }
});

test('unchanged runtime pins preserve every registration, device and artifact', t => {
    const fixture = runtimeRetirementFixture(t);
    fixture.setup(fixture.previous, [...fixture.previous].reverse());
    assert.deepEqual(fixture.mutations, []);
    for (const record of [...fixture.previous, ...fixture.wanted, fixture.unrelated]) fixture.assertPresent(record, true);
    fixture.setup(fixture.previous, [fixture.wanted[0], fixture.previous[1]]);
    fixture.assertPresent(fixture.previous[0], false);
    for (const record of [fixture.previous[1], ...fixture.wanted, fixture.unrelated]) fixture.assertPresent(record, true);
});

test('superseded builds sharing a runtime identifier keep the attached devices', t => {
    const fixture = runtimeRetirementFixture(t, {iosVersion: '27.0'});
    const old = fixture.previous[0], current = fixture.wanted[0];
    const devices = structuredClone(fixture.devices[old.image.runtimeIdentifier]);
    fixture.setup();
    assert.equal(fixture.images.has(old.image.identifier), false);
    assert.deepEqual(fixture.devices[current.image.runtimeIdentifier], devices);
    fixture.assertPresent(current, true);
    fixture.setup(fixture.previous, fixture.wanted, true);
});

test('foreign images sharing an old asset or a booted old device block retirement before deletion', t => {
    for (const conflict of ['shared path', 'booted device']) {
        const fixture = runtimeRetirementFixture(t);
        const old = fixture.previous[0];
        if (conflict === 'shared path') fixture.unrelated.image.path = old.image.path;
        else old.device.state = 'Booted';
        assert.throws(() => fixture.setup());
        assert.deepEqual(fixture.mutations, []);
        for (const record of [...fixture.previous, ...fixture.wanted, fixture.unrelated]) fixture.assertPresent(record, true);
    }
});

test('retirement rechecks the next simulator after the first device deletion', t => {
    for (const change of ['boot', 'move', 'shared runtime']) {
        const fixture = runtimeRetirementFixture(t);
        const old = fixture.previous[0], foreign = fixture.unrelated;
        const devices = fixture.devices[old.image.runtimeIdentifier];
        const next = {...old.device, udid: randomUUID()};
        devices.push(next);
        fixture.behavior.afterMutation = () => {
            if (change === 'boot') next.state = 'Booted';
            if (change === 'move') fixture.devices[foreign.image.runtimeIdentifier].push(devices.pop());
            if (change === 'shared runtime') foreign.image.runtimeIdentifier = old.image.runtimeIdentifier;
        };
        assert.throws(() => fixture.setup());
        assert.deepEqual(fixture.mutations, [['delete', old.device.udid]]);
        assert.ok(Object.values(fixture.devices).flat().includes(next));
    }
});

test('retirement preserves an artifact replaced or mounted after registration removal', t => {
    for (const change of ['replacement', 'nested mount']) {
        const fixture = runtimeRetirementFixture(t);
        const old = fixture.previous[0], [download, , receipt] = old.artifacts;
        const nested = path.join(download, 'Restore');
        mkdirSync(nested);
        fixture.behavior.afterMutation = command => {
            if (command.at(-1) !== old.image.identifier) return;
            if (change === 'replacement') {
                filesystem.renameSync(download, download + '.saved');
                mkdirSync(download);
            } else fixture.behavior.mount = nested;
        };
        assert.throws(() => fixture.setup());
        assert.ok(filesystem.existsSync(change === 'replacement' ? download : nested));
        assert.ok(filesystem.existsSync(receipt));
        fixture.assertPresent(fixture.unrelated, true);
    }
});

test('a download path replaced during the removal walk cannot redirect it to foreign data', t => {
    const fixture = runtimeRetirementFixture(t);
    const [download, , receipt] = fixture.previous[0].artifacts;
    const foreign = fixture.unrelated.artifacts[0];
    fixture.behavior.beforeWalk = directory => {
        assert.equal(directory, download);
        filesystem.renameSync(download, download + '.saved');
        symlinkSync(foreign, download);
    };
    assert.throws(() => fixture.setup(), /artifact was replaced/);
    assert.ok(filesystem.lstatSync(download).isSymbolicLink());
    assert.equal(readFileSync(path.join(foreign, 'runtime.dmg'), 'utf8'), 'exported fixture');
    assert.ok(filesystem.existsSync(receipt));
});

test('the repair receipt survives a failed sidecar flush and retry flushes the already absent source', t => {
    const fixture = runtimeRetirementFixture(t);
    const old = fixture.previous[0], [download, source, receipt] = old.artifacts;
    const retire = () => fixture.setup([old], [fixture.wanted[0]]);
    fixture.behavior.onSync = directory => {
        if (directory === path.dirname(source)) {
            assert.ok(filesystem.existsSync(receipt));
            throw new Error('fixture sidecar flush failure');
        }
    };
    assert.throws(retire, /fixture sidecar flush failure/);
    assert.ok(!filesystem.existsSync(source) && filesystem.existsSync(receipt));
    assert.deepEqual(fixture.synced.splice(0), [path.dirname(download), path.dirname(source)]);
    fixture.behavior.onSync = directory =>
        assert.equal(filesystem.existsSync(receipt), directory !== path.dirname(receipt));
    retire();
    assert.deepEqual(fixture.synced, old.artifacts.map(file => path.dirname(file)));
    fixture.assertPresent(old, false);
});

test('superseded runtime cleanup preserves foreign repair evidence and symlink targets', t => {
    for (const conflict of ['foreign receipt', 'symlink']) {
        const fixture = runtimeRetirementFixture(t);
        const [download, , receipt] = fixture.previous[0].artifacts;
        if (conflict === 'foreign receipt') {
            const record = JSON.parse(readFileSync(receipt, 'utf8'));
            writeFileSync(receipt, JSON.stringify({...record, vmId: 'another-guest'}));
        } else {
            symlinkSync(fixture.unrelated.artifacts[0], path.join(download, 'foreign-download'));
        }
        assert.throws(() => fixture.setup());
        fixture.assertPresent(fixture.unrelated, true);
        assert.equal(filesystem.existsSync(conflict === 'foreign receipt' ? receipt : download), true);
    }
});

test('Apple export descendants can retain installer permissions only inside the protected download directory', t => {
    const fixture = runtimeRetirementFixture(t);
    const old = fixture.previous[0];
    const [download, repair] = old.artifacts;
    for (const protectedPath of [download, path.join(repair, 'runtime.dmg')]) {
        fixture.behavior.assetOwnedPath = protectedPath;
        assert.throws(() => fixture.setup());
        assert.deepEqual(fixture.mutations, []);
        fixture.assertPresent(old, true);
    }
    const bundle = path.join(download, 'runtime.exportedBundle');
    const restore = path.join(bundle, 'Restore');
    mkdirSync(restore, {recursive: true});
    filesystem.renameSync(path.join(download, 'runtime.dmg'), path.join(restore, 'runtime.dmg'));
    writeFileSync(path.join(bundle, 'ExportedMetadata.plist'), 'fixture metadata');
    filesystem.chmodSync(restore, 0o775);
    fixture.behavior.assetOwnedPath = bundle;
    fixture.setup();
    fixture.assertPresent(old, false);
    fixture.assertPresent(fixture.unrelated, true);
});

test('superseded runtime verification detects a reappearing old registration without deleting it', t => {
    const fixture = runtimeRetirementFixture(t);
    fixture.setup();
    const old = fixture.previous[0].image;
    fixture.images.set(old.identifier, old);
    const before = fixture.mutations.length;
    assert.throws(() => fixture.setup(fixture.previous, fixture.wanted, true));
    assert.equal(fixture.mutations.length, before);
    assert.ok(fixture.images.has(old.identifier));
});

function runtimeRepairFixture({platform = 'iOS', healthy = false, sibling = false, exportParents = []} = {}) {
    const root = filesystem.realpathSync(mkdtempSync(path.join(tmpdir(), 'wallet-runtime-repair-')));
    const buildRoot = path.join(root, 'build'), state = path.join(root, 'state');
    const pin = {platform, version: '27.0', buildVersion: platform === 'iOS' ? '24A434' : '24M362'};
    const key = `${pin.platform}-${pin.version}-${pin.buildVersion}`;
    const asset = `com.apple.MobileAsset.${platform === 'iOS' ? 'iOS' : 'xrOS'}SimulatorRuntime`;
    const runtimeIdentifier = `com.apple.CoreSimulator.SimRuntime.${platform === 'iOS' ? 'iOS' : 'xrOS'}-27-0`;
    const exported = path.join(buildRoot, 'RuntimeDownloads', key, ...exportParents, 'runtime.exportedBundle');
    mkdirSync(path.join(exported, 'Restore'), {recursive: true});
    mkdirSync(state);
    const original = path.join(exported, 'Restore', 'runtime.dmg');
    writeFileSync(original, 'official runtime fixture bytes');
    writeFileSync(path.join(exported, 'ExportedMetadata.plist'), JSON.stringify({CFBundleIdentifier: asset,
        MobileAssetProperties: {Build: pin.buildVersion, SimulatorVersion: pin.version, Architectures: ['arm64']}}));
    for (const name of ['BuildManifest.plist', 'Restore.plist']) writeFileSync(path.join(exported, 'Restore', name),
        JSON.stringify({ProductVersion: pin.version, ProductBuildVersion: pin.buildVersion}));
    const digest = provisionerFixture({fs: filesystem, crypto: {createHash}}).runtimeFileDigest;
    const source = digest(original);
    const nativeImage = path.join(root, 'native-image.dmg');
    const corruptNativeImage = path.join(root, 'corrupt-native-image.dmg');
    writeFileSync(nativeImage, readFileSync(original));
    writeFileSync(corruptNativeImage, Buffer.alloc(source.size, 0x78));
    const journalDirectory = path.join(state, 'RuntimeRepairs');
    const journalPath = path.join(journalDirectory, `${key}.json`);
    const oldID = '11111111-1111-4111-8111-111111111111', probeID = '22222222-2222-4222-8222-222222222222';
    const newID = '33333333-3333-4333-8333-333333333333', siblingID = '44444444-4444-4444-8444-444444444444';
    const base = {version: pin.version, build: pin.buildVersion, platformIdentifier: `com.apple.platform.${platform === 'iOS' ? 'iphone' : 'xr'}simulator`,
        runtimeIdentifier, sizeBytes: source.size, deletable: true, state: 'Ready', signatureState: 'Unknown'};
    const mount = `/Library/Developer/CoreSimulator/Volumes/${platform === 'iOS' ? 'iOS' : 'xrOS'}_${pin.buildVersion}`;
    const bundlePath = `${mount}/Library/Developer/CoreSimulator/Profiles/Runtimes/${platform === 'iOS' ? 'iOS' : 'xrOS'} 27.0.simruntime`;
    const normal = id => ({...base, identifier: id, kind: 'Disk Image', signatureState: 'Verified',
        path: `/Library/Developer/CoreSimulator/Images/${id}.dmg`, mountPath: mount, runtimeBundlePath: bundlePath});
    const broken = {...base, identifier: oldID, kind: 'Patchable Cryptex Disk Image',
        path: `/System/Library/AssetsV2/${asset.replaceAll('.', '_')}/${'a'.repeat(40)}.asset/AssetData`};
    const inventory = new Map([[oldID, healthy ? normal(oldID) : broken]]);
    if (sibling) inventory.set(siblingID, {...broken, identifier: siblingID, state: 'Unusable', unusableErrorMessage: 'Cryptex Mount Preferred'});
    const calls = [], writes = [], checkpoints = [], logs = [], sleeps = [], queryTimeouts = [], behavior = {};
    let clock = 0, runtimeQueries = 0;
    const descriptors = new Map();
    let pendingJournal;
    const physicalPath = filename => {
        if (filename.startsWith('/Library/Developer/CoreSimulator/Images/Inbox/')) {
            throw Object.assign(new Error('Discarded native Inbox file'), {code: 'ENOENT'});
        }
        if (filename.startsWith('/Library/Developer/CoreSimulator/Images/')) {
            return behavior.normalHashMismatch ? corruptNativeImage : nativeImage;
        }
        return filename;
    };
    const fs = {...filesystem,
        lstatSync(filename, options) {
            const item = filesystem.lstatSync(physicalPath(filename), options);
            if (!item) return item;
            return new Proxy(item, {get(target, key) {
                if (key === 'uid') return behavior.sourceWrongOwner && filename.endsWith('/runtime.dmg') &&
                    filename.includes('/RuntimeRepairSources/') ? 501 : 0;
                const value = Reflect.get(target, key);
                return typeof value === 'function' ? value.bind(target) : value;
            }});
        },
        statSync(filename, options) {
            return filename === bundlePath ? {isDirectory: () => true, dev: 3, ino: 200}
                : filesystem.statSync(physicalPath(filename), options);
        },
        realpathSync(filename) {
            const physical = physicalPath(filename);
            const canonical = filesystem.realpathSync(physical);
            return physical !== filename && canonical === physical ? filename : canonical;
        },
        openSync(filename, flags, mode) {
            const descriptor = filesystem.openSync(physicalPath(filename), flags, mode);
            descriptors.set(descriptor, filename);
            return descriptor;
        },
        closeSync(descriptor) { descriptors.delete(descriptor); return filesystem.closeSync(descriptor); },
        renameSync(from, to) {
            filesystem.renameSync(from, to);
            if (to === journalPath) pendingJournal = JSON.parse(readFileSync(to, 'utf8'));
        },
        fsyncSync(descriptor) {
            filesystem.fsyncSync(descriptor);
            if (descriptors.get(descriptor) !== journalDirectory || !pendingJournal) return;
            const value = pendingJournal;
            pendingJournal = undefined;
            writes.push(value);
            if (value.phase === behavior.interruptPhase) {
                delete behavior.interruptPhase;
                throw new Error('fixture repair interrupted');
            }
            if (value.phase === 'adding' && value.addAttempted && behavior.interruptAddIntent) {
                behavior.interruptAddIntent = false;
                throw new Error('fixture stopped before add');
            }
        },
        statfsSync(directory) {
            assert.ok(directory === '/System/Volumes/Data' || directory === buildRoot);
            const available = directory === '/System/Volumes/Data' && behavior.noSpace ? 0 : 64 * 1024 ** 3;
            if (directory === '/System/Volumes/Data') checkpoints.push({directory, available});
            return {bavail: available, bsize: 1, blocks: 128 * 1024 ** 3};
        },
        chownSync() {}, fchownSync() {},
    };
    const runtime = () => {
        const selectedPath = behavior.preferredCryptex ? '/private/var/run/fixture-cryptex/iOS.simruntime' : bundlePath;
        return {identifier: runtimeIdentifier, version: pin.version, buildversion: behavior.profileWrongPin ? '24A999' : pin.buildVersion,
            isAvailable: !behavior.profileUnavailable && (!behavior.availableAfterQueries || runtimeQueries >= behavior.availableAfterQueries),
            availabilityError: behavior.profileUnavailable ? 'fixture profile handoff unavailable' : undefined,
            bundlePath: selectedPath, runtimeRoot: behavior.profileWrongRoot ? '/private/wrong-runtime-root' : `${selectedPath}/Contents/Resources/RuntimeRoot`};
    };
    const run = (label, file, args, options) => {
        if (file === '/bin/sleep') { sleeps.push(options.timeout); clock += Number(args[0]) * 1000; return ''; }
        if (file === '/usr/bin/plutil') {
            const filename = args.at(-1);
            assert.equal(args[0], '-extract', 'Complete manifests may contain plist Data that JSON conversion cannot represent');
            const metadata = filename.startsWith(bundlePath) ? {ProductVersion: pin.version, ProductBuildVersion: pin.buildVersion}
                : JSON.parse(readFileSync(filename, 'utf8'));
            const value = args[1].split('.').reduce((current, key) => current[key], metadata);
            assert.notEqual(value, undefined);
            return args[2] === 'json' ? JSON.stringify(value) : String(value);
        }
        if (file === '/sbin/mount') return `/dev/disk7s1 on ${mount} (apfs, local, sealed, read-only)`;
        assert.equal(file, '/usr/bin/env');
        assert.deepEqual(Array.from(args).slice(0, 3), ['DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer', '/usr/bin/xcrun', 'simctl']);
        assert.equal(options.user, true);
        assert.equal(options.returnStatus, true);
        const command = Array.from(args).slice(3);
        calls.push(command);
        const response = (stdout, status = 0) => ({status, stdout, stderr: ''});
        if (command[0] === 'list') {
            if (command[1] === 'runtimes') { runtimeQueries += 1; queryTimeouts.push(options.timeout); }
            return response(JSON.stringify(command[1] === 'devices' ?
                {devices: {[runtimeIdentifier]: [{state: behavior.booted ? 'Booted' : 'Shutdown'}]}} : {runtimes: [runtime()]}));
        }
        if (command[1] === 'list') return response(JSON.stringify(Object.fromEntries(inventory)));
        if (command[1] === 'verify') {
            const image = inventory.get(command[2]);
            if (behavior.verifyTimeout) throw new Error('fixture native verify timeout');
            if (behavior.verifyUnknown) return response('verification unavailable', 1);
            if (image.kind === 'Patchable Cryptex Disk Image') {
                if (behavior.anchorNowVerified) return response('Signature verified, signature is valid.');
                if (behavior.anchorVerificationUnknown) return response('Native verification unavailable', 1);
                if (behavior.recreatedVerify === 'verified' && image.identifier !== oldID) return response('Signature verified, signature is valid.');
                if (behavior.recreatedVerify === 'unknown' && image.identifier !== oldID) return response('Native verification unavailable', 1);
                if (behavior.afterFailedVerify) behavior.afterFailedVerify(inventory);
                return response('Signature verification failed: (-67054 a sealed resource is missing or invalid', 1);
            }
            if (behavior.interruptReadyProof && command[2] === probeID) {
                behavior.interruptReadyProof = false; throw new Error('fixture Ready source verification interrupted');
            }
            return response('Signature verified, signature is valid.');
        }
        if (command[1] === 'add') {
            assert.equal(command.length, 3);
            const hasBroken = [...inventory.values()].some(value => value.kind === 'Patchable Cryptex Disk Image');
            if (hasBroken) {
                const duplicate = [...inventory.values()].find(value => value.kind === 'Patchable Cryptex Disk Image' && value.state === 'Ready').identifier;
                const addedProbeID = behavior.nextProbeID ?? probeID;
                inventory.set(addedProbeID, {...normal(addedProbeID),
                    path: behavior.readyAdd ? normal(addedProbeID).path : `/Library/Developer/CoreSimulator/Images/Inbox/${addedProbeID}.dmg`,
                    state: behavior.readyAdd ? 'Ready' : 'Unusable',
                    sizeBytes: behavior.probeSizeMismatch ? source.size + 1 : source.size,
                    signatureState: behavior.probeUnverified ? 'Unknown' : 'Verified', unusableErrorMessage: `Duplicate of ${duplicate}`});
                if (behavior.afterProbe) behavior.afterProbe(inventory);
                if (behavior.mutateAfterProbe) behavior.mutateAfterProbe(inventory);
                if (behavior.changeSourceAfterProbe) writeFileSync(command[2], 'changed source bytes');
                if (behavior.interruptProbe) { behavior.interruptProbe = false; throw new Error('fixture probe interrupted after native completion'); }
                return response(behavior.readyAdd ? addedProbeID : `D: ${behavior.reportedProbeID ?? addedProbeID} ${platform} (Unusable - Duplicate of ${duplicate})`, behavior.readyAdd ? 0 : 5);
            }
            if (behavior.failedAdd) return response('fixture add failed before registration', 1);
            inventory.set(newID, normal(newID));
            if (behavior.interruptAdd) { behavior.interruptAdd = false; throw new Error('fixture add interrupted after registration'); }
            return response(newID);
        }
        assert.equal(command[1], 'delete');
        assert.equal(command.length, 3);
        const removed = command[2];
        inventory.delete(removed);
        if (behavior.retireSiblings && [oldID, siblingID].includes(removed)) {
            inventory.delete(siblingID); inventory.delete(oldID);
        }
        if (behavior.interruptDelete === removed) { behavior.interruptDelete = undefined; throw new Error('fixture delete interrupted after removal'); }
        return response('Deleted');
    };
    const prepare = provisionerFixture({fs, state, config: {vmId: 'fixture-vm'},
        performance: {now: () => clock}, run, console: {log: value => logs.push(value)}}).verifyOrRepairPinnedRuntime;
    return {pin, buildRoot, exported, inventory, calls, writes, checkpoints, logs, sleeps, queryTimeouts,
        elapsed: () => clock, behavior, oldID, probeID, newID, siblingID, journalPath,
        prepare: (mode, retirement) => prepare(pin, buildRoot, mode, retirement), journal: () => JSON.parse(readFileSync(journalPath, 'utf8')),
        close: () => rmSync(root, {recursive: true, force: true})};
}

test('exact runtime repair requires independent verified source then deletes only recorded UUIDs', () => {
    for (const platform of ['iOS', 'visionOS']) {
        const fixture = runtimeRepairFixture({platform});
        try {
            const runtime = fixture.prepare();
            assert.equal(runtime.buildversion, fixture.pin.buildVersion);
            assert.deepEqual(fixture.calls.filter(args => args[1] === 'delete').map(args => args[2]), [fixture.probeID, fixture.oldID]);
            assert.equal(fixture.calls.filter(args => args[1] === 'add').length, 2);
            assert.ok(fixture.calls.every(args => !args.some(value => ['--all', '--unusable', '--keep-asset', '--move', '--async', '--force'].includes(value))));
            assert.equal(fixture.calls.some(args => args[1] === 'verify' && args[2] === fixture.probeID), false);
            assert.ok(fixture.writes.some(value => value.phase === 'probe-verified' && value.probeCompletion?.exitCode === 5 &&
                value.probe.identifier === fixture.probeID));
            assert.equal(fixture.journal().probeCompletion.nativeVerification.signatureState, 'Verified');
            assert.equal(fixture.journal().phase, 'complete');
            assert.equal(fixture.journal().installed.identifier, fixture.newID);
            assert.ok(filesystem.existsSync(fixture.journal().sourcePath));
            assert.ok(fixture.checkpoints.length >= 3);
        } finally { fixture.close(); }
    }
});

test('a deleted runtime registration reappearing beside the verified replacement blocks completion', () => {
    const fixture = runtimeRepairFixture();
    try {
        const original = fixture.inventory.get(fixture.oldID);
        fixture.prepare();
        fixture.inventory.set(fixture.oldID, {...original, path: '/another/asset'});
        const calls = fixture.calls.length;
        assert.throws(() => fixture.prepare('verify'), /only the verified replacement/);
        assert.equal(fixture.calls.slice(calls).some(args => ['add', 'delete'].includes(args[1])), false);
    } finally { fixture.close(); }
});

test('a fresh signed runtime waits for its exact profile without creating a repair receipt', () => {
    const fixture = runtimeRepairFixture({healthy: true});
    try {
        fixture.behavior.availableAfterQueries = 2;
        assert.equal(fixture.prepare().isAvailable, true);
        assert.equal(fixture.sleeps.length, 1);
        assert.equal(filesystem.existsSync(fixture.journalPath), false);
        assert.equal(fixture.calls.some(args => ['add', 'delete'].includes(args[1])), false);
    } finally { fixture.close(); }
});

test('a verified Ready import can demote the rejected cryptex before its exact deletion', () => {
    const fixture = runtimeRepairFixture();
    try {
        fixture.behavior.readyAdd = true;
        fixture.behavior.afterProbe = inventory => Object.assign(inventory.get(fixture.oldID),
            {state: 'Unusable', unusableErrorMessage: 'Cryptex Mount Preferred'});
        fixture.prepare();
        const record = fixture.journal();
        assert.equal(record.probeCompletion.exitCode, 0);
        assert.equal(record.probeCompletion.nativeVerification.state, 'Ready');
        assert.equal(record.probeCompletion.nativeVerification.imageDigest.sha256, record.source.sha256);
        assert.equal(record.keepReadyProbe, true);
        assert.equal(record.installed.identifier, fixture.probeID);
        assert.equal(fixture.calls.filter(args => args[1] === 'add').length, 1);
        assert.deepEqual(fixture.calls.filter(args => args[1] === 'delete').map(args => args[2]), [fixture.oldID]);
        assert.ok(fixture.calls.some(args => args[1] === 'verify' && args[2] === fixture.probeID));
        const add = fixture.calls.findIndex(args => args[1] === 'add');
        const deletion = fixture.calls.findIndex(args => args[1] === 'delete');
        assert.ok(fixture.calls.slice(add + 1, deletion).some(args => args[1] === 'verify' && args[2] === fixture.oldID));
        assert.equal(record.phase, 'complete');
    } finally { fixture.close(); }
});

test('cold Ready-probe resume reattests regenerated bad UUIDs without discarding independent source proof', () => {
    const fixture = runtimeRepairFixture();
    try {
        fixture.behavior.readyAdd = true;
        fixture.behavior.interruptReadyProof = true;
        assert.throws(fixture.prepare, /Ready source verification interrupted/);
        assert.equal(fixture.journal().phase, 'probe');
        assert.equal(fixture.journal().probeCompletion.exitCode, 0);
        const recreatedID = '55555555-5555-4555-8555-555555555555';
        const original = fixture.inventory.get(fixture.oldID);
        fixture.inventory.delete(fixture.oldID);
        fixture.inventory.set(recreatedID, {...original, identifier: recreatedID});
        fixture.prepare('existing');
        const record = fixture.journal();
        assert.equal(record.installed.identifier, fixture.probeID);
        assert.equal(record.failed[0].identifier, recreatedID);
        assert.equal(record.failed[0].proof.code, -67054);
        assert.equal(record.probeCompletion.exitCode, 0);
        assert.equal(record.bindingHistory[0].completion.nativeVerification.state, 'Ready');
        assert.equal(fixture.calls.filter(args => args[1] === 'add').length, 1);
        assert.deepEqual(fixture.calls.filter(args => args[1] === 'delete').map(args => args[2]), [recreatedID]);
        assert.equal(record.phase, 'complete');
    } finally { fixture.close(); }
});

test('Ready native completion observed after a lost response records no invented exit code', () => {
    const fixture = runtimeRepairFixture();
    try {
        fixture.behavior.readyAdd = true;
        fixture.behavior.interruptProbe = true;
        assert.throws(fixture.prepare, /probe interrupted/);
        assert.equal(fixture.journal().probeCompletion, undefined);
        fixture.prepare('existing');
        const proof = fixture.journal().probeCompletion;
        assert.equal(proof.kind, 'observed-native-completion');
        assert.equal(proof.exitCode, undefined);
        assert.equal(proof.nativeVerification.state, 'Ready');
        assert.equal(fixture.journal().installed.identifier, fixture.probeID);
        assert.equal(fixture.calls.filter(args => args[1] === 'add').length, 1);
    } finally { fixture.close(); }
});

test('Ready source imports require exact file content and reject unavailable profiles or multiple owned candidates', () => {
    for (const failure of ['hash', 'profile', 'multiple']) {
        const fixture = runtimeRepairFixture();
        try {
            fixture.behavior.readyAdd = true;
            if (failure === 'hash') fixture.behavior.normalHashMismatch = true;
            if (failure === 'profile') fixture.behavior.profileUnavailable = true;
            if (failure === 'multiple') fixture.behavior.afterProbe = inventory => inventory.set(fixture.siblingID,
                {...inventory.get(fixture.probeID), identifier: fixture.siblingID,
                    path: `/Library/Developer/CoreSimulator/Images/${fixture.siblingID}.dmg`});
            assert.throws(fixture.prepare, /Ready source|profile is not mounted|did not become available|probe is missing, unverified, or ambiguous/);
            assert.equal(fixture.calls.some(args => args[1] === 'delete'), false);
        } finally { fixture.close(); }
    }
});

test('profile mismatch diagnostic separates native image mount from selected usable runtime without relaxing the guard', () => {
    const fixture = runtimeRepairFixture();
    try {
        fixture.behavior.readyAdd = true;
        fixture.behavior.preferredCryptex = true;
        assert.throws(fixture.prepare, /profile is not mounted and available/);
        const line = fixture.logs.find(value => value.startsWith('BIG_WALLET_RUNTIME_PROFILE_DIAGNOSTIC='));
        const report = JSON.parse(line.slice(line.indexOf('=') + 1));
        assert.equal(report.matchedProfiles, 0);
        assert.equal(report.directory.exists, true);
        assert.equal(report.directory.existsError, null);
        assert.match(report.image.mountPath, /^\/Library\/Developer\/CoreSimulator\/Volumes\//);
        assert.equal(report.runtimes.values[0].bundlePath, '/private/var/run/fixture-cryptex/iOS.simruntime');
        assert.equal(report.runtimes.values[0].buildversion, fixture.pin.buildVersion);
        assert.equal(fixture.calls.some(args => args[1] === 'delete'), false);
    } finally { fixture.close(); }
    const summarize = provisioning.runtimeProfileDiagnostic;
    const value = {identifier: 'fixture', bundlePath: 'x'.repeat(4000), runtimeRoot: 'y'.repeat(4000), privateField: 'secret-fixture'};
    const report = summarize({platform: 'iOS'}, {...value, mountPath: 'z'.repeat(4000)}, Array(100).fill(value),
        {exists: false, existsError: 'EACCES'}, 0);
    assert.ok(Buffer.byteLength(JSON.stringify(report)) <= 16384);
    assert.equal(report.runtimes.truncated, true);
    assert.equal(report.directory.existsError, 'EACCES');
    assert.doesNotMatch(JSON.stringify(report), /secret-fixture|privateField/);
});

test('exact owned Ready profile handoff waits only until true availability within a bounded deadline', () => {
    const fixture = runtimeRepairFixture();
    try {
        fixture.behavior.readyAdd = true;
        fixture.behavior.availableAfterQueries = 3;
        fixture.prepare();
        assert.equal(fixture.journal().phase, 'complete');
        assert.equal(fixture.sleeps.length, 2);
        assert.equal(fixture.elapsed(), 4000);
        assert.ok(fixture.queryTimeouts.every(timeout => timeout > 0 && timeout <= 10000));
        assert.ok(fixture.sleeps.every(timeout => timeout > 0 && timeout <= 3000));
    } finally { fixture.close(); }
});

test('permanently unavailable exact Ready profile times out with bounded diagnostics before deletion', () => {
    const fixture = runtimeRepairFixture();
    try {
        fixture.behavior.readyAdd = true;
        fixture.behavior.profileUnavailable = true;
        assert.throws(fixture.prepare, /within 90 seconds/);
        assert.equal(fixture.elapsed(), 90000);
        assert.equal(fixture.calls.some(args => args[1] === 'delete'), false);
        assert.ok(fixture.queryTimeouts.every(timeout => timeout > 0 && timeout <= 10000));
        const line = fixture.logs.find(value => value.startsWith('BIG_WALLET_RUNTIME_PROFILE_DIAGNOSTIC='));
        const diagnostic = JSON.parse(line.slice(line.indexOf('=') + 1));
        assert.equal(diagnostic.runtimes.values[0].isAvailable, false);
        assert.equal(diagnostic.runtimes.values[0].availabilityError, 'fixture profile handoff unavailable');
    } finally { fixture.close(); }
});

test('profile handoff never waits for a different pin bundle path or runtime root', () => {
    for (const wrong of ['profileWrongPin', 'preferredCryptex', 'profileWrongRoot']) {
        const fixture = runtimeRepairFixture();
        try {
            fixture.behavior.readyAdd = true;
            fixture.behavior.profileUnavailable = true;
            fixture.behavior[wrong] = true;
            assert.throws(fixture.prepare, /profile is not mounted and available/);
            assert.equal(fixture.sleeps.length, 0);
            assert.equal(fixture.calls.some(args => args[1] === 'delete'), false);
        } finally { fixture.close(); }
    }
});

test('timeout unknown verification and unverified or changed probes never authorize deletion', () => {
    for (const flag of ['verifyTimeout', 'verifyUnknown', 'probeUnverified', 'probeSizeMismatch', 'changeSourceAfterProbe', 'noSpace']) {
        const fixture = runtimeRepairFixture();
        try {
            fixture.behavior[flag] = true;
            assert.throws(fixture.prepare);
            assert.equal(fixture.calls.some(args => args[1] === 'delete'), false);
        } finally { fixture.close(); }
    }
});

test('an unattributed Inbox duplicate after a lost completion cannot authorize either deletion', () => {
    const fixture = runtimeRepairFixture();
    try {
        fixture.behavior.interruptProbe = true;
        assert.throws(fixture.prepare, /probe interrupted/);
        assert.equal(fixture.journal().phase, 'probe');
        assert.equal(fixture.journal().probeAttempted, true);
        assert.equal(fixture.journal().probeCompletion, undefined);
        assert.throws(() => fixture.prepare('existing'), /no matching native add completion/);
        assert.equal(fixture.calls.some(args => args[1] === 'delete'), false);
        assert.equal(fixture.calls.filter(args => args[1] === 'add').length, 1);
        assert.equal(fixture.journal().phase, 'probe');
        assert.equal(fixture.journal().probeCompletion, undefined);
    } finally { fixture.close(); }
});

test('the duplicate add and inventory must identify the same UUID before deletion', () => {
    const fixture = runtimeRepairFixture();
    try {
        fixture.behavior.reportedProbeID = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
        assert.throws(fixture.prepare, /no matching native add completion/);
        assert.throws(() => fixture.prepare('existing'), /no matching native add completion/);
        assert.equal(fixture.calls.some(args => args[1] === 'delete'), false);
    } finally { fixture.close(); }
});

test('native duplicate self-cleanup permits a fresh verification add only with unchanged failed registrations', () => {
    const fixture = runtimeRepairFixture();
    try {
        fixture.behavior.interruptProbe = true;
        assert.throws(fixture.prepare, /probe interrupted/);
        fixture.inventory.delete(fixture.probeID);
        fixture.behavior.nextProbeID = fixture.siblingID;
        fixture.prepare('existing');
        assert.equal(fixture.journal().probe.identifier, fixture.siblingID);
        assert.equal(fixture.journal().probeCompletion.kind, 'completed-native-add');
        assert.equal(fixture.journal().probeCompletion.exitCode, 5);
        assert.equal(fixture.journal().probeHistory[0].reason, 'registration-absent');
        assert.equal(fixture.journal().probeHistory[0].completion, null);
        assert.equal(fixture.calls.filter(args => args[1] === 'add').length, 3);
        assert.equal(fixture.journal().phase, 'complete');
    } finally { fixture.close(); }
});

test('pre-deletion native UUID regeneration requires a fresh exact rejection and a new source probe', () => {
    const fixture = runtimeRepairFixture();
    try {
        fixture.behavior.interruptProbe = true;
        assert.throws(fixture.prepare, /probe interrupted/);
        const recreatedID = '55555555-5555-4555-8555-555555555555';
        const original = fixture.inventory.get(fixture.oldID);
        fixture.inventory.delete(fixture.oldID);
        fixture.inventory.delete(fixture.probeID);
        fixture.inventory.set(recreatedID, {...original, identifier: recreatedID});
        fixture.prepare('existing');
        const record = fixture.journal();
        assert.equal(record.bindingHistory[0].failed[0].identifier, fixture.oldID);
        assert.equal(record.failed[0].identifier, recreatedID);
        assert.equal(record.failed[0].proof.code, -67054);
        assert.equal(record.probeCompletion.kind, 'completed-native-add');
        assert.equal(record.probeCompletion.nativeVerification.duplicateOf, recreatedID);
        assert.equal(fixture.calls.filter(args => args[1] === 'add').length, 3);
        assert.equal(fixture.calls.some(args => args[1] === 'delete' && args[2] === fixture.oldID), false);
        const attest = fixture.calls.findIndex(args => args[1] === 'verify' && args[2] === recreatedID);
        const remove = fixture.calls.findIndex(args => args[1] === 'delete' && args[2] === recreatedID);
        assert.ok(attest >= 0 && remove > attest);
        assert.equal(record.phase, 'complete');
    } finally { fixture.close(); }
});

test('native UUID regeneration refuses changed assets sizes mixed IDs pending aliases and inconclusive signatures', () => {
    for (const changed of ['asset', 'size', 'mixed', 'pending', 'verified', 'unknown', 'foreign-asset-reference']) {
        const fixture = runtimeRepairFixture();
        try {
            fixture.behavior.interruptProbe = true;
            assert.throws(fixture.prepare, /probe interrupted/);
            const recreatedID = '55555555-5555-4555-8555-555555555555';
            const original = fixture.inventory.get(fixture.oldID);
            fixture.inventory.delete(fixture.probeID);
            if (changed !== 'mixed') fixture.inventory.delete(fixture.oldID);
            const recreated = {...original, identifier: recreatedID};
            if (changed === 'asset') recreated.path = recreated.path.replace('a'.repeat(40), 'b'.repeat(40));
            if (changed === 'size') recreated.sizeBytes += 1;
            if (changed === 'pending') recreated.state = 'Copying';
            if (changed === 'verified' || changed === 'unknown') fixture.behavior.recreatedVerify = changed;
            fixture.inventory.set(recreatedID, recreated);
            if (changed === 'foreign-asset-reference') {
                const foreignID = '66666666-6666-4666-8666-666666666666';
                fixture.inventory.set(foreignID, {...original, identifier: foreignID, build: '24M362',
                    platformIdentifier: 'com.apple.platform.xrsimulator'});
                const record = fixture.journal(); record.beforeProbe.push(foreignID);
                writeFileSync(fixture.journalPath, JSON.stringify(record));
            }
            const additions = fixture.calls.filter(args => args[1] === 'add').length;
            assert.throws(() => fixture.prepare('existing'), /registrations|signature|probe is missing, unverified, or ambiguous/);
            assert.equal(fixture.calls.filter(args => args[1] === 'add').length, additions);
            assert.equal(fixture.calls.some(args => args[1] === 'delete'), false);
            assert.equal(fixture.journal().failed[0].identifier, fixture.oldID);
        } finally { fixture.close(); }
    }
});

test('absent-probe retry refuses missing changed or pending failed registrations and changed source', () => {
    for (const changed of ['missing', 'identity', 'pending', 'new-alias', 'source']) {
        const fixture = runtimeRepairFixture();
        try {
            fixture.behavior.interruptProbe = true;
            assert.throws(fixture.prepare, /probe interrupted/);
            fixture.inventory.delete(fixture.probeID);
            if (changed === 'missing') fixture.inventory.delete(fixture.oldID);
            if (changed === 'identity') fixture.inventory.get(fixture.oldID).path += '-changed';
            if (changed === 'pending') fixture.inventory.get(fixture.oldID).state = 'Deleting';
            if (changed === 'new-alias') fixture.inventory.set(fixture.siblingID,
                {...fixture.inventory.get(fixture.oldID), identifier: fixture.siblingID});
            if (changed === 'source') writeFileSync(fixture.journal().sourcePath, 'changed preserved input');
            const additions = fixture.calls.filter(args => args[1] === 'add').length;
            assert.throws(() => fixture.prepare('existing'), /registrations changed|source changed|probe is missing, unverified, or ambiguous/);
            assert.equal(fixture.calls.filter(args => args[1] === 'add').length, additions);
            assert.equal(fixture.calls.some(args => args[1] === 'delete'), false);
        } finally { fixture.close(); }
    }
});

test('absent-probe admission diagnostics include the exact recorded and current bound size without relaxing rejection', () => {
    const fixture = runtimeRepairFixture();
    try {
        fixture.behavior.interruptProbe = true;
        assert.throws(fixture.prepare, /probe interrupted/);
        fixture.inventory.delete(fixture.probeID);
        const recordedSize = fixture.inventory.get(fixture.oldID).sizeBytes;
        fixture.inventory.get(fixture.oldID).sizeBytes += 1;
        const additions = fixture.calls.filter(args => args[1] === 'add').length;
        assert.throws(() => fixture.prepare('existing'), /registrations changed/);
        const line = fixture.logs.find(value => value.startsWith('BIG_WALLET_RUNTIME_REPAIR_RETRY_ADMISSION='));
        const report = JSON.parse(line.slice(line.indexOf('=') + 1));
        assert.equal(report.beforeVerification.images[0].identifier, fixture.oldID);
        assert.equal(report.beforeVerification.images[0].sizeBytes, recordedSize);
        assert.equal(report.afterVerification.images[0].sizeBytes, recordedSize + 1);
        assert.equal(fixture.calls.filter(args => args[1] === 'add').length, additions);
        assert.equal(fixture.calls.some(args => args[1] === 'delete'), false);
    } finally { fixture.close(); }
    const summarize = provisioning.runtimeAdmissionDiagnostic;
    const report = summarize({platform: 'iOS'}, [{identifier: 'fixture', sizeBytes: Infinity}], null);
    assert.equal(report.beforeVerification.images[0].sizeBytes, '<invalid-type>');
});

test('probe cleanup errors are not suppressed and cannot authorize failed-runtime deletion', () => {
    const fixture = runtimeRepairFixture();
    try {
        fixture.behavior.interruptDelete = fixture.probeID;
        assert.throws(fixture.prepare, /delete interrupted/);
        assert.equal(fixture.calls.some(args => args[1] === 'delete' && args[2] === fixture.oldID), false);
        assert.equal(fixture.journal().phase, 'probe-verified');
    } finally { fixture.close(); }
});

test('duplicate probe cleanup refuses a registration whose state changed after verification', () => {
    const fixture = runtimeRepairFixture();
    try {
        let probe;
        fixture.behavior.afterProbe = inventory => { probe = {...inventory.get(fixture.probeID)}; };
        fixture.behavior.interruptDelete = fixture.probeID;
        assert.throws(fixture.prepare, /delete interrupted/);
        fixture.inventory.set(fixture.probeID, {...probe, state: 'Ready'});
        assert.throws(fixture.prepare, /duplicate probe changed/);
        assert.deepEqual(fixture.calls.filter(args => args[1] === 'delete').map(args => args[2]), [fixture.probeID]);
        assert.equal(fixture.journal().phase, 'probe-verified');
    } finally { fixture.close(); }
});

test('runtime repair admission failure records bounded public before and after image evidence without changing its gate', () => {
    const fixture = runtimeRepairFixture({sibling: true});
    try {
        fixture.inventory.get(fixture.siblingID).state = 'Copying';
        fixture.behavior.afterFailedVerify = inventory => { inventory.get(fixture.siblingID).state = 'Deleting'; };
        assert.throws(fixture.prepare, /limited to explicitly rejected/);
        const line = fixture.logs.find(value => value.startsWith('BIG_WALLET_RUNTIME_REPAIR_ADMISSION='));
        const report = JSON.parse(line.split('=').slice(1).join('='));
        assert.equal(report.beforeVerification.images.find(value => value.identifier === fixture.siblingID).state, 'Copying');
        assert.equal(report.afterVerification.images.find(value => value.identifier === fixture.siblingID).state, 'Deleting');
        assert.equal(fixture.calls.some(args => ['add', 'delete'].includes(args[1])), false);
        assert.equal(filesystem.existsSync(fixture.journalPath), false);
    } finally { fixture.close(); }
    const summarize = provisioning.runtimeAdmissionDiagnostic;
    const image = {identifier: 'id', path: 'x'.repeat(4000), kind: 'y'.repeat(4000), state: 'Copying',
        unusableErrorMessage: 'z'.repeat(4000), privateField: 'private-fixture-secret'};
    const report = summarize({platform: 'iOS', version: '27.0', buildVersion: '24A434'},
        Array.from({length: 100}, (_, index) => ({...image, identifier: String(index)})),
        Array.from({length: 100}, (_, index) => ({...image, identifier: String(index), state: 'Deleting'})));
    assert.ok(Buffer.byteLength(JSON.stringify(report)) <= 16384);
    assert.equal(report.beforeVerification.count, 100);
    assert.equal(report.beforeVerification.truncated, true);
    assert.doesNotMatch(JSON.stringify(report), /private-fixture-secret|privateField/);
});

test('wrong official export or BuildManifest pin blocks repair before native staging or deletion', () => {
    for (const filename of ['ExportedMetadata.plist', 'Restore/BuildManifest.plist']) {
        const fixture = runtimeRepairFixture();
        try {
            const destination = path.join(fixture.exported, filename);
            const metadata = JSON.parse(readFileSync(destination, 'utf8'));
            if (filename === 'ExportedMetadata.plist') metadata.MobileAssetProperties.Build = '24A999';
            else metadata.ProductBuildVersion = '24A999';
            writeFileSync(destination, JSON.stringify(metadata));
            assert.throws(fixture.prepare, /metadata differs/);
            assert.equal(fixture.calls.some(args => ['add', 'delete'].includes(args[1])), false);
        } finally { fixture.close(); }
    }
});

test('runtime repair accepts an official bundle at the maximum discovery depth', () => {
    const fixture = runtimeRepairFixture({exportParents: ['Xcode', 'iOS', 'arm64']});
    try {
        fixture.prepare();
        assert.equal(fixture.journal().original, path.join(fixture.exported, 'Restore', 'runtime.dmg'));
        fixture.prepare('verify');
        assert.equal(fixture.calls.filter(args => args[1] === 'add').length, 2);
    } finally { fixture.close(); }
});

test('native plist extraction preserves required fields when the manifest contains binary Data', {skip: process.platform !== 'darwin'}, () => {
    const root = filesystem.realpathSync(mkdtempSync(path.join(tmpdir(), 'wallet-runtime-plist-')));
    try {
        const filename = path.join(root, 'BuildManifest.plist');
        writeFileSync(filename, '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>' +
            '<key>ProductVersion</key><string>27.0</string><key>ProductBuildVersion</key><string>24A434</string>' +
            '<key>ManifestData</key><data>AQIDBA==</data><key>MobileAssetProperties</key><dict>' +
            '<key>Architectures</key><array><string>arm64</string></array></dict></dict></plist>');
        const conversion = spawnSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', filename], {encoding: 'utf8'});
        assert.notEqual(conversion.status, 0);
        assert.match(conversion.stdout + conversion.stderr, /Invalid object.*JSON/i);
        const commands = [];
        const extract = provisionerFixture({run(_label, file, args, options) {
            commands.push(Array.from(args));
            return execFileSync(file, Array.from(args), {encoding: 'utf8', timeout: options.timeout, maxBuffer: options.maxBuffer}).trim();
        }}).runtimeMetadataField;
        assert.equal(extract(filename, 'ProductVersion'), '27.0');
        assert.equal(extract(filename, 'ProductBuildVersion'), '24A434');
        assert.deepEqual(Array.from(extract(filename, 'MobileAssetProperties.Architectures', 'json')), ['arm64']);
        assert.ok(commands.every(args => args[0] === '-extract' && args.includes('-o') && args.includes('-')));
    } finally { rmSync(root, {recursive: true, force: true}); }
});

test('resumed repairs tolerate new native UUIDs for both superseded pins and still track unrelated images', () => {
    for (const phase of ['probe', 'deleting', 'adding']) {
        const fixture = runtimeRepairFixture();
        try {
            const previous = {platform: 'iOS', version: '26.4', buildVersion: '23E222'};
            const retired = {identifier: randomUUID(), platformIdentifier: 'com.apple.platform.iphonesimulator',
                version: previous.version, build: previous.buildVersion, kind: 'Disk Image'};
            const otherPin = {platform: 'visionOS', version: previous.version, buildVersion: '23N222'};
            const otherImage = {...retired, identifier: randomUUID(), platformIdentifier: 'com.apple.platform.xrsimulator', build: otherPin.buildVersion};
            const unrelated = {...otherImage, identifier: randomUUID(), build: previous.buildVersion};
            fixture.inventory.set(retired.identifier, retired);
            fixture.inventory.set(otherImage.identifier, otherImage);
            fixture.inventory.set(unrelated.identifier, unrelated);
            const retirement = {pins: [previous, otherPin], release() {
                assert.ok(fixture.inventory.delete(retired.identifier));
                fixture.behavior.noSpace = false;
                throw new Error('fixture interrupted after retirement');
            }};
            fixture.behavior.interruptPhase = phase;
            assert.throws(() => fixture.prepare('prepare', retirement), /fixture repair interrupted/);
            const snapshot = phase === 'adding' ? fixture.journal().beforeAdd : fixture.journal().beforeProbe;
            assert.ok(!snapshot.includes(retired.identifier));
            assert.ok(!snapshot.includes(otherImage.identifier));
            assert.ok(snapshot.includes(unrelated.identifier));
            for (const image of [retired, otherImage]) {
                fixture.inventory.delete(image.identifier);
                image.identifier = randomUUID();
                fixture.inventory.set(image.identifier, image);
            }
            if (phase === 'deleting') {
                otherImage.path = fixture.inventory.get(fixture.oldID).path;
                assert.throws(() => fixture.prepare('existing', retirement), /Another runtime pin shares the rejected asset/);
                assert.ok(fixture.inventory.has(fixture.oldID));
                delete otherImage.path;
            }
            fixture.behavior.noSpace = true;
            assert.throws(() => fixture.prepare('existing', retirement), /fixture interrupted after retirement/);
            assert.equal(fixture.journal().phase, phase);
            if (phase === 'adding') {
                fixture.inventory.delete(unrelated.identifier);
                assert.throws(() => fixture.prepare('existing', retirement), /inventory changed before import/);
                fixture.inventory.set(unrelated.identifier, unrelated);
            }
            fixture.prepare('existing', retirement);
            assert.equal(fixture.journal().phase, 'complete');
            assert.ok(fixture.inventory.has(otherImage.identifier));
            assert.ok(fixture.inventory.has(unrelated.identifier));
        } finally { fixture.close(); }
    }
});

test('delete to import interruption resumes the exact empty inventory without redownload', () => {
    const fixture = runtimeRepairFixture();
    try {
        fixture.behavior.interruptDelete = fixture.oldID;
        assert.throws(fixture.prepare, /delete interrupted/);
        assert.equal(fixture.inventory.size, 0);
        const before = fixture.calls.filter(args => args[1] === 'add').length;
        fixture.prepare('existing');
        assert.equal(fixture.calls.filter(args => args[1] === 'add').length, before + 1);
        assert.equal(fixture.journal().phase, 'complete');
    } finally { fixture.close(); }
});

test('completed import is observed after interruption instead of being repeated', () => {
    const fixture = runtimeRepairFixture();
    try {
        fixture.behavior.interruptAdd = true;
        assert.throws(fixture.prepare, /add interrupted/);
        const count = fixture.calls.filter(args => args[1] === 'add').length;
        fixture.prepare('existing');
        assert.equal(fixture.calls.filter(args => args[1] === 'add').length, count);
        assert.equal(fixture.journal().phase, 'complete');
    } finally { fixture.close(); }
});

test('an interrupted or failed final add can retry from the same empty inventory', () => {
    for (const failure of ['interruptAddIntent', 'failedAdd']) {
        const fixture = runtimeRepairFixture();
        try {
            fixture.behavior[failure] = true;
            assert.throws(fixture.prepare, /stopped before add|operation failed/);
            assert.equal(fixture.journal().addAttempted, true);
            assert.equal(fixture.inventory.size, 0);
            fixture.behavior[failure] = false;
            fixture.prepare('existing');
            assert.equal(fixture.journal().phase, 'complete');
            assert.deepEqual(fixture.calls.filter(args => args[1] === 'delete').map(args => args[2]), [fixture.probeID, fixture.oldID]);
        } finally { fixture.close(); }
    }
});

test('an interrupted final add preserves a partial registration and does not import over it', () => {
    const fixture = runtimeRepairFixture();
    try {
        fixture.behavior.interruptAdd = true;
        assert.throws(fixture.prepare, /add interrupted/);
        fixture.inventory.get(fixture.newID).state = 'Copying';
        const start = fixture.calls.length;
        assert.throws(() => fixture.prepare('existing'), /did not reach exact verified readiness/);
        assert.equal(fixture.calls.slice(start).some(args => ['add', 'delete'].includes(args[1])), false);
        assert.equal(fixture.journal().phase, 'adding');
    } finally { fixture.close(); }
});

test('same-asset historical aliases are bound to the active rejection and may retire together', () => {
    const fixture = runtimeRepairFixture({sibling: true});
    try {
        fixture.behavior.retireSiblings = true;
        fixture.prepare();
        assert.equal(fixture.calls.some(args => args[1] === 'verify' && args[2] === fixture.siblingID), false);
        assert.deepEqual(fixture.calls.filter(args => args[1] === 'delete').map(args => args[2]), [fixture.probeID, fixture.siblingID]);
        assert.deepEqual(fixture.journal().deleted, [fixture.siblingID, fixture.oldID]);
    } finally { fixture.close(); }
});

test('resuming deletion requires a live verified Ready replacement and rejection before removing any alias', () => {
    for (const changed of ['missing-probe', 'probe-hash', 'probe-profile', 'verified-anchor', 'inconclusive-anchor',
        'other-demotion', 'other-signature-state', 'missing-anchor', 'undeletable', 'foreign']) {
        const fixture = runtimeRepairFixture({sibling: true});
        try {
            const anchor = fixture.inventory.get(fixture.oldID);
            fixture.inventory.delete(fixture.oldID);
            fixture.inventory.set(fixture.oldID, anchor);
            fixture.behavior.readyAdd = true;
            fixture.behavior.booted = true;
            assert.throws(fixture.prepare, /must be shut down/);
            assert.equal(fixture.journal().phase, 'deleting');
            fixture.behavior.booted = false;
            Object.assign(anchor, {state: 'Unusable', unusableErrorMessage: 'Cryptex Mount Preferred'});
            if (changed === 'missing-probe') fixture.inventory.delete(fixture.probeID);
            if (changed === 'probe-hash') fixture.behavior.normalHashMismatch = true;
            if (changed === 'probe-profile') fixture.behavior.profileWrongPin = true;
            if (changed === 'verified-anchor') fixture.behavior.anchorNowVerified = true;
            if (changed === 'inconclusive-anchor') fixture.behavior.anchorVerificationUnknown = true;
            if (changed === 'other-demotion') anchor.unusableErrorMessage = 'Unknown image format';
            if (changed === 'other-signature-state') anchor.signatureState = 'Verified';
            if (changed === 'missing-anchor') fixture.inventory.delete(fixture.oldID);
            if (changed === 'undeletable') fixture.inventory.get(fixture.oldID).deletable = false;
            if (changed === 'foreign') fixture.behavior.afterFailedVerify = inventory => inventory.set(fixture.newID,
                {...inventory.get(fixture.oldID), identifier: fixture.newID, build: '24A999'});
            assert.throws(fixture.prepare, /Ready source|not mounted|signature changed|inconclusive|registration changed|shares the rejected asset/);
            assert.equal(fixture.calls.some(args => args[1] === 'delete'), false);
            assert.equal(fixture.journal().phase, 'deleting');
        } finally { fixture.close(); }
    }
});

test('a duplicate source probe cannot authorize deletion of a demoted cryptex', () => {
    const fixture = runtimeRepairFixture();
    try {
        fixture.behavior.afterProbe = inventory => Object.assign(inventory.get(fixture.oldID),
            {state: 'Unusable', unusableErrorMessage: 'Cryptex Mount Preferred'});
        assert.throws(fixture.prepare, /registration changed/);
        assert.ok(fixture.inventory.has(fixture.oldID));
        assert.ok(!fixture.calls.some(args => args[1] === 'delete' && args[2] === fixture.oldID));
    } finally { fixture.close(); }
});

test('resuming deletion after native co-retirement reconciles absent registrations without a live anchor', () => {
    const fixture = runtimeRepairFixture({sibling: true});
    try {
        fixture.behavior.readyAdd = true;
        fixture.behavior.retireSiblings = true;
        fixture.behavior.interruptDelete = fixture.siblingID;
        assert.throws(fixture.prepare, /delete interrupted/);
        assert.equal(fixture.journal().phase, 'deleting');
        assert.deepEqual(fixture.journal().deleted, []);
        fixture.prepare('existing');
        assert.deepEqual(fixture.calls.filter(args => args[1] === 'delete').map(args => args[2]), [fixture.siblingID]);
        assert.deepEqual(fixture.journal().deleted, [fixture.siblingID, fixture.oldID]);
        assert.equal(fixture.journal().phase, 'complete');
    } finally { fixture.close(); }
});

test('unexpected aliases and changed frozen image identities block broken-runtime deletion', () => {
    for (const changed of ['new', 'path']) {
        const fixture = runtimeRepairFixture();
        try {
            fixture.behavior.mutateAfterProbe = inventory => {
                if (changed === 'new') inventory.set(fixture.siblingID, {...inventory.get(fixture.oldID), identifier: fixture.siblingID});
                else inventory.get(fixture.oldID).path += '-changed';
            };
            assert.throws(fixture.prepare, /unrecorded runtime alias|identity changed|probe is missing, unverified, or ambiguous/);
            assert.equal(fixture.calls.some(args => args[1] === 'delete' && args[2] === fixture.oldID), false);
        } finally { fixture.close(); }
    }
});

test('resume rejects foreign failed image entries and changed preserved-source ownership', () => {
    for (const changed of ['pin', 'owner']) {
        const fixture = runtimeRepairFixture();
        try {
            fixture.behavior.interruptDelete = fixture.probeID;
            assert.throws(fixture.prepare, /delete interrupted/);
            if (changed === 'pin') {
                const record = fixture.journal(); record.failed[0].build = 'UNRELATED';
                writeFileSync(fixture.journalPath, JSON.stringify(record));
            } else fixture.behavior.sourceWrongOwner = true;
            const count = fixture.calls.filter(args => args[1] === 'delete').length;
            assert.throws(() => fixture.prepare('existing'), /ownership|source changed/);
            assert.equal(fixture.calls.filter(args => args[1] === 'delete').length, count);
        } finally { fixture.close(); }
    }
});

test('Xcode provisioning requires a pinned archive rather than traversing a shared app bundle', () => {
    assert.equal(validateArchive({path: 'Xcode.tar', sha256: 'a'.repeat(64)}).path, 'Xcode.tar');
    for (const value of [undefined, {}, {path: '../Xcode.tar', sha256: 'a'.repeat(64)}, {path: 'Xcode.tar', sha256: 'not-a-digest'}]) {
        assert.throws(() => validateArchive(value), /pinned SHA-256/);
    }
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
        const extract = provisionerFixture({
            fs: {mkdirSync},
            run: (_label, command, args) => { commands.push([command, ...args]); return execFileSync(command, args, {encoding: 'utf8'}).trim(); },
            }).extractXcodeArchive;
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
        const inputs = {fs, state: root, crypto: {createHash, randomUUID},
                run: () => { throw new Error('the existing correct symlink must not be moved'); }};
        const relocate = provisionerFixture(inputs).relocateDirectory;
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
        const descriptorPaths = new Map();
        let pendingDurableWrite;
        let intentPath;
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
            statSync: (filename, ...args) => filesystem.statSync(map(filename), ...args),
            openSync(filename, ...args) {
                if (args[0] === 'wx' && existingTarget && filename.startsWith(intentPath + '.')) fail('primary-intent');
                const descriptor = filesystem.openSync(map(filename), ...args);
                descriptorPaths.set(descriptor, filename);
                return descriptor;
            },
            fsyncSync(descriptor) {
                filesystem.fsyncSync(descriptor);
                if (!filesystem.fstatSync(descriptor).isDirectory()) return;
                const directory = descriptorPaths.get(descriptor);
                assert.ok(directory);
                events.push(['sync', directory]);
                if (!pendingDurableWrite || path.dirname(pendingDurableWrite.filename) !== directory) return;
                const committed = pendingDurableWrite; pendingDurableWrite = undefined;
                events.push(['intent', committed.filename, committed.value.ready]);
                if (committed.filename === intentPath && committed.value.ready) fail('ready');
            },
            closeSync(descriptor) {
                try { filesystem.closeSync(descriptor); } finally { descriptorPaths.delete(descriptor); }
            },
            fchownSync() {},
            chownSync(filename, owner, group) { assert.ok(filename.endsWith('.previous')); assert.equal(owner, 0); assert.equal(group, 0); },
            renameSync(from, to) {
                filesystem.renameSync(map(from), map(to));
                events.push(['rename', from, to]);
                if (to.startsWith(state + '/relocation-') && to.endsWith('.json')) {
                    pendingDurableWrite = {filename: to, value: JSON.parse(filesystem.readFileSync(map(to), 'utf8'))};
                }
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
        const provisioner = provisionerFixture({fs: api, state, config: {vmId: 'fixture-vm'},
            uid: process.getuid(), gid: process.getgid(),
            run(_label, command, args) {
                events.push([command, ...args]);
                if (command === '/bin/sync') return '';
                if (command === '/bin/chmod') { assert.equal(args[0], '-N'); assert.ok(args[1].endsWith('.previous')); return ''; }
                assert.equal(command, '/bin/cp');
                if (failAt === 'copy') {
                    writeFileSync(path.join(map(args[2]), 'device.plist'), 'partial'); fail('copy');
                }
                execFileSync('/bin/cp', [args[0], map(args[1]), map(args[2])], {timeout: 5000});
                return '';
            },
            spawnSync(command, args, options) {
                assert.equal(command, '/usr/sbin/lsof');
                const directory = args[4];
                assert.deepEqual(args, ['-nP', '-t', '+w', '+D', directory, '-x', 'f']);
                assert.equal(options.timeout, 60000); assert.equal(options.killSignal, 'SIGKILL');
                events.push(['idle', directory]);
                if (path.dirname(directory).endsWith('.previous')) {
                    const parent = api.lstatSync(path.dirname(directory));
                    assert.equal(parent.uid, 0); assert.equal(parent.mode & 0o7777, 0o700);
                }
                inspectIdle(directory);
                return {status: 1, stdout: '', stderr: ''};
            },
        });
        intentPath = provisioner.relocationIntentPath(original, destination);
        const relocate = provisioner.relocateDirectory;
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
        const inspect = provisionerFixture({environment: {}, spawnSync(command, args, options) {
            assert.equal(command, '/usr/sbin/lsof');
            assert.deepEqual(Array.from(args), ['-nP', '-t', '+w', '+D', '/fixture/private/tree', '-x', 'f']);
            assert.equal(options.timeout, 60000);
            assert.equal(options.killSignal, 'SIGKILL');
            return result;
        }}).requireIdleRelocationTree;
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
    const ownership = provisionerFixture({fs: {
        statSync: () => ({uid: 501, gid: 20}), chownSync: (...args) => changes.push(args),
    }}).setOwnershipIfNeeded;
    ownership('/fixture', 501, 20);
    assert.deepEqual(changes, []);
    ownership('/fixture', 502, 20);
    ownership('/fixture', 501, 21);
    assert.deepEqual(changes, [['/fixture', 502, 20], ['/fixture', 501, 21]]);
});

test('installed Aqua supervisor remains idle until an explicit job launch', () => {
    const configuration = provisioning.makeAgentConfiguration({
        library: '/fixture/tools', agentLabel: 'fixture-agent', environment: {PATH: '/fixture/bin'},
        developer: '/fixture/Xcode', logDirectory: '/fixture/logs',
    });
    assert.equal(configuration.LimitLoadToSessionType, 'Aqua');
    assert.equal(configuration.RunAtLoad, false);
    assert.equal(configuration.KeepAlive, false);
    assert.deepEqual(configuration.ProgramArguments, ['/fixture/tools/VMGuestAgent']);
    const commands = [];
    const removed = [];
    let fails = true;
    const install = provisionerFixture({library: '/fixture/tools',
        fs: {lstatSync: () => ({uid: 0, mode: 0o644, isFile: () => true, isSymbolicLink: () => false}),
            rmSync: filename => removed.push(filename)},
        spawnSync: () => ({status: 1}),
        run: (_label, command, args) => { if (fails) throw new Error('fixture installation failed'); commands.push([command, ...args]); },
    }).installGuestAgent;
    assert.throws(() => install([], '/fixture/agent.plist'), /installation failed/);
    assert.deepEqual(removed, []);
    fails = false;
    install([], '/fixture/agent.plist');
    assert.deepEqual(commands, [['/bin/launchctl', 'bootstrap', 'gui/501', '/fixture/agent.plist']]);
    assert.deepEqual(removed, ['guest.mjs', 'test_manifest.mjs', 'result_audit.mjs'].map(name => path.join('/fixture/tools', name)));
});

test('importing the provisioning module has no process or filesystem effects', () => {
    const program = `
        const fs = await import('node:fs');
        const child = await import('node:child_process');
        const {syncBuiltinESMExports} = await import('node:module');
        const fail = () => { throw new Error('unexpected import side effect'); };
        const read = fs.default.readFileSync;
        const moduleURL = ${JSON.stringify(new URL('../provision_guest.mjs', import.meta.url).href)};
        fs.default.readFileSync = (filename, ...args) => {
            if (String(filename) === moduleURL || String(filename) === new URL(moduleURL).pathname) return read(filename, ...args);
            return fail();
        };
        for (const name of ['writeFileSync', 'mkdirSync', 'rmSync']) fs.default[name] = fail;
        child.default.spawnSync = fail;
        syncBuiltinESMExports();
        const previous = process.exitCode;
        await import(${JSON.stringify(new URL('../provision_guest.mjs', import.meta.url).href)});
        if (process.exitCode !== previous) throw new Error('import changed exitCode');
    `;
    const result = spawnSync(process.execPath, ['--input-type=module', '-e', program], {encoding: 'utf8'});
    assert.equal(result.status, 0, result.stderr);
});
