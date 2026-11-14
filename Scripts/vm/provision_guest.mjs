import nativeFS from 'node:fs';
import path from 'node:path';
import nativeCrypto from 'node:crypto';
import {spawnSync as nativeSpawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';

function fail(message) { throw new Error(message); }

function check(condition, message) { if (!condition) fail(message); }

function text(value, name) {
    check(typeof value === 'string' && value.length > 0 && !value.includes('\0'), `${name} must be a nonempty string.`);
    return value;
}

export function validateXcodeArchive(value) {
    if (!value || typeof value !== 'object' || value.path !== 'Xcode.tar' || typeof value.sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(value.sha256)) {
        throw new Error('A staged Xcode.tar archive with its pinned SHA-256 is required.');
    }
    return value;
}

export function matchesRuntime(runtime, wanted) {
    return runtime.version === wanted.version && runtime.buildversion === wanted.buildVersion &&
        runtime.identifier.includes(wanted.platform === 'visionOS' ? '.xrOS-' : '.iOS-') && runtime.isAvailable;
}

export function matchesRuntimeImage(image, pin) {
    const platformIdentifier = pin.platform === 'iOS' ? 'com.apple.platform.iphonesimulator' : 'com.apple.platform.xrsimulator';
    return image.platformIdentifier === platformIdentifier && image.version === pin.version && image.build === pin.buildVersion;
}

export function validateRetirementPins(pins) {
    check(Array.isArray(pins) && pins.length > 0 && pins.length <= 2 &&
        pins.every(pin => pin && ['iOS', 'visionOS'].includes(pin.platform) &&
            typeof pin.version === 'string' && /^\d+(?:\.\d+){1,2}$/.test(pin.version) &&
            typeof pin.buildVersion === 'string' && /^\d+[A-Z]\d+[a-z]?$/.test(pin.buildVersion)) &&
        new Set(pins.map(pin => pin.platform)).size === pins.length, 'Invalid simulator runtime pins for retirement.');
}

export function automaticLoginCommandDiagnostic(result, password) {
    const output = value => result.error || result.signal ? '[output omitted: capture incomplete]' :
        String(value ?? '').split(password).join('[REDACTED]').slice(0, 4096);
    return {status: result.status ?? null, error: result.error?.code ?? null, signal: result.signal ?? null,
        stdout: output(result.stdout), stderr: output(result.stderr)};
}

export function requiredProvisioningInputs(configuration, xcodeInstalled, runtimes) {
    const required = [];
    if (!xcodeInstalled) {
        validateXcodeArchive(configuration.xcodeArchive);
        required.push('Xcode.tar');
    }
    for (const wanted of configuration.runtimes) {
        if (wanted.dmgPath === undefined) continue;
        check(typeof wanted.dmgPath === 'string' && /^[A-Za-z0-9][A-Za-z0-9._-]*\.dmg$/.test(wanted.dmgPath),
            'Runtime images must use a staged DMG basename.');
        if (!runtimes.some(runtime => matchesRuntime(runtime, wanted))) required.push(wanted.dmgPath);
    }
    return [...new Set(required)];
}

export function selectBlankBuildDisk(disks, bootDisk, expectedBytes, authorized) {
    if (authorized !== true) throw new Error('Build-data initialization requires an explicit receipt.');
    if (!Array.isArray(disks) || !/^disk\d+$/.test(bootDisk) || expectedBytes !== 103_079_215_104) {
        throw new Error('Invalid managed build-data disk specification.');
    }
    const candidates = disks.filter(disk => disk && disk.DeviceIdentifier !== bootDisk && /^disk\d+$/.test(disk.DeviceIdentifier) &&
        disk.Size === expectedBytes && (disk.Partitions === undefined || (Array.isArray(disk.Partitions) && disk.Partitions.length === 0)) &&
        (disk.Content === undefined || disk.Content === ''));
    if (candidates.length !== 1) throw new Error('Expected exactly one blank 96 GiB nonboot disk. Existing partitioned disks will not be erased.');
    return candidates[0].DeviceIdentifier;
}

export function validateBlankBuildDisk(details, samples, expectedBytes) {
    if (expectedBytes !== 103_079_215_104 || details.WholeDisk !== true || details.TotalSize !== expectedBytes || details.FilesystemType ||
        samples.length !== 2 || samples.some(sample => sample.length !== 1024 * 1024 || sample.some(byte => byte !== 0))) {
        throw new Error('The managed build-data disk is not blank; refusing to initialize it.');
    }
}

export function runtimeRootSpaceRequirement(stagedBytes) {
    const gib = 1024 ** 3;
    if (stagedBytes === undefined) return 16 * gib;
    if (!Number.isSafeInteger(stagedBytes) || stagedBytes <= 0 || stagedBytes > Number.MAX_SAFE_INTEGER - 8 * gib) {
        throw new Error('The staged simulator runtime size is invalid.');
    }
    return stagedBytes + 8 * gib;
}

export function runtimeAdmissionDiagnostic(pin, before, after) {
    const fields = ['identifier', 'kind', 'state', 'deletable', 'signatureState', 'platformIdentifier',
        'version', 'build', 'path', 'runtimeIdentifier', 'sizeBytes', 'unusableErrorMessage'];
    const publicValues = values => values.map(value => Object.fromEntries(fields.map(key => [key, value[key] ?? null])))
        .sort((left, right) => String(left.identifier).localeCompare(String(right.identifier)));
    const bounded = values => ({count: values.length, truncated: values.length > 8,
        images: values.slice(0, 8).map(value => Object.fromEntries(fields.map(key => {
            const item = value[key];
            return [key, typeof item === 'string' ? item.slice(0, 384) : typeof item === 'boolean' || item === null ||
                Number.isSafeInteger(item) ? item : '<invalid-type>'];
        })))});
    const initial = publicValues(before);
    const latest = after === null ? null : publicValues(after);
    const result = {version: 1, pin, beforeVerification: bounded(initial)};
    if (latest === null) result.afterVerification = {status: 'unavailable'};
    else if (JSON.stringify(initial) !== JSON.stringify(latest)) result.afterVerification = bounded(latest);
    else result.afterVerification = {status: 'unchanged'};
    for (const entry of [result.afterVerification, result.beforeVerification]) {
        while (entry.images?.length && Buffer.byteLength(JSON.stringify(result)) > 16384) {
            entry.images.pop(); entry.truncated = true;
        }
    }
    return result;
}

export function runtimeProfileDiagnostic(pin, image, runtimes, directory, matchedProfiles) {
    const fields = (value, keys) => Object.fromEntries(keys.map(key => {
        const item = value[key] ?? null;
        return [key, typeof item === 'string' ? item.slice(0, 384) : typeof item === 'boolean' || item === null ? item : '<invalid-type>'];
    }));
    const result = {version: 1, pin, matchedProfiles, directory,
        image: fields(image, ['identifier', 'kind', 'state', 'signatureState', 'mountPath', 'runtimeBundlePath',
            'runtimeIdentifier', 'platformIdentifier', 'version', 'build']),
        runtimes: {count: runtimes.length, truncated: runtimes.length > 16,
            values: runtimes.slice(0, 16).map(value => fields(value,
                ['identifier', 'isAvailable', 'availabilityError', 'bundlePath', 'runtimeRoot', 'version', 'buildversion']))}};
    while (result.runtimes.values.length && Buffer.byteLength(JSON.stringify(result)) > 16384) {
        result.runtimes.values.pop(); result.runtimes.truncated = true;
    }
    return result;
}

export function optionalSigningConfiguration(proof, identity, previous) {
    const fields = Object.fromEntries(['proofKey', 'keychainPath', 'keychainPassword']
        .filter(key => typeof previous?.[key] === 'string' && previous[key].length > 0)
        .map(key => [key, previous[key]]));
    const missingSigning = [];
    const appliedCapabilities = [];
    for (const [name, operation] of [['request-proof key', proof], ['development signing', identity]]) {
        try { Object.assign(fields, operation()); appliedCapabilities.push(name); }
        catch (error) { missingSigning.push(`${name}: ${error.message}`); }
    }
    return {fields, missingSigning, appliedCapabilities};
}

export function appliedProvisioningRequest(config, previous, appliedCapabilities) {
    const identifier = config.provisioningRequestID;
    if (identifier === undefined) return previous?.appliedProvisioningRequestID;
    if (typeof identifier !== 'string' || !/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(identifier)) {
        throw new Error('The provisioning request identity is invalid.');
    }
    const signing = config.signing ?? {};
    const requested = [];
    if (Object.hasOwn(signing, 'proofKeyFile')) requested.push('request-proof key');
    if (['p12Path', 'p12PasswordFile', 'keychainPasswordFile', 'profiles'].some(key => Object.hasOwn(signing, key))) {
        requested.push('development signing');
    }
    return requested.every(name => appliedCapabilities.includes(name)) ? identifier : previous?.appliedProvisioningRequestID;
}

export function makeAgentConfiguration({library, agentLabel, environment, developer, logDirectory}) {
    return {Label: agentLabel,
        ProgramArguments: [`${library}/VMGuestAgent`],
        LimitLoadToSessionType: 'Aqua', RunAtLoad: false, KeepAlive: false,
        EnvironmentVariables: {PATH: environment.PATH, DEVELOPER_DIR: developer},
        StandardOutPath: path.join(logDirectory, 'agent.log'), StandardErrorPath: path.join(logDirectory, 'agent.log')};
}

export function createProvisioner(context, system = {}) {
    const {config, staging, uid, gid, mode = ''} = context;
    const {fs = nativeFS, spawnSync = nativeSpawnSync, crypto = nativeCrypto, execute,
        process = globalThis.process, performance = globalThis.performance,
        console = globalThis.console, setImmediate = globalThis.setImmediate} = system;
    const {library = '/usr/local/libexec/big-wallet-vm', state = '/Library/Application Support/BigWalletTestVM',
        exchange = '/Volumes/BigWalletBuild/Exchange', developer = '/Applications/Xcode.app/Contents/Developer'} = context.paths ?? {};
    const agentLabel = 'org.lil.big-wallet.vm-guest';
    const uidText = String(uid);
    const environment = {...(context.environment ?? process.env), PATH: '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin', DEVELOPER_DIR: developer};

    function run(label, file, args, options = {}) {
        check(options.inputFD === undefined || Number.isInteger(options.inputFD) && options.inputFD >= 0 && options.input === undefined,
            'A command input descriptor must be valid and cannot be combined with input bytes.');
        const maximumOutput = options.maxBuffer ?? 64 * 1024 * 1024;
        check(Number.isSafeInteger(maximumOutput) && maximumOutput > 0 && maximumOutput <= 64 * 1024 * 1024,
            'A command output limit must be positive and bounded.');
        if (execute) return execute(label, file, args, options);
        const invocation = options.user ? ['/bin/launchctl', ['asuser', uidText, '/usr/bin/sudo', '-H', '-u', config.consoleUser, file, ...args]] : [file, args];
        const result = spawnSync(invocation[0], invocation[1], {encoding: 'utf8', env: environment,
            stdio: options.inputFD === undefined ? undefined : [options.inputFD, 'pipe', 'pipe'],
            input: options.input, timeout: options.timeout ?? 3_600_000, killSignal: options.killSignal ?? 'SIGTERM', maxBuffer: maximumOutput});
        if (options.logStdout && !options.secret && result.stdout) process.stdout.write(result.stdout);
        if (options.returnStatus) {
            check(!result.error && !result.signal && Number.isInteger(result.status), `${label} did not complete normally.`);
            return {status: result.status, stdout: (result.stdout ?? '').trim(), stderr: (result.stderr ?? '').trim()};
        }
        if (result.error || result.signal || result.status !== 0) {
            if (!options.secret && result.stderr) process.stderr.write(result.stderr);
            fail(`${label} failed (${result.error?.code ?? result.signal ?? `exit ${result.status}`}).`);
        }
        return result.stdout.trim();
    }
    function configureUIAutomation() {
        const tool = '/usr/bin/automationmodetool';
        run('Configure guest UI automation authentication', tool,
            ['enable-automationmode-without-authentication'], {timeout: 30000, killSignal: 'SIGKILL'});
        const status = run('Verify guest UI automation authentication', tool, [],
            {user: true, timeout: 10000, killSignal: 'SIGKILL'});
        check(/(?:^|\n)This device DOES NOT REQUIRE user authentication to enable Automation Mode\.(?:\n|$)/.test(status),
            'Guest UI automation still requires authentication. Complete guest setup with Scripts/test_vm.sh setup --interactive.');
    }
    function staged(relative, name) {
        text(relative, name);
        check(!path.isAbsolute(relative), `${name} must be relative to the provisioning directory.`);
        const candidate = path.resolve(staging, relative);
        check(candidate.startsWith(staging + path.sep), `${name} escapes the provisioning directory.`);
        const resolved = fs.realpathSync(candidate);
        check(resolved.startsWith(staging + path.sep) && fs.statSync(resolved).isFile(), `${name} must name a staged regular file.`);
        return resolved;
    }
    function secret(relative, name, allowEmpty = false) {
        const value = fs.readFileSync(staged(relative, name), 'utf8').replace(/\r?\n$/, '');
        if (allowEmpty && value === '') return value;
        return text(value, name);
    }
    function prepareGuestState() {
        fs.mkdirSync(state, {recursive: true, mode: 0o700});
        const metadata = fs.lstatSync(state);
        check(metadata.isDirectory() && !metadata.isSymbolicLink() && metadata.uid === 0 && (metadata.mode & 0o022) === 0,
            'Guest state must be a protected root-owned directory.');
        const identityPath = path.join(state, 'identity.json');
        if (fs.existsSync(identityPath)) {
            const prior = JSON.parse(fs.readFileSync(identityPath, 'utf8'));
            check(prior.vmId === config.vmId && prior.consoleUser === config.consoleUser,
                'This guest is already registered for another VM or console user; select the existing identity instead of replacing it.');
        }
        fs.chmodSync(state, 0o700);
        fs.chownSync(state, 0, 20);
        run('Remove previous guest state access', '/bin/chmod', ['-N', state]);
        run('Allow the selected guest account to read state', '/bin/chmod', ['+a', `user:${config.consoleUser} allow list,search`, state]);
        return identityPath;
    }
    function writeJSON(filename, value, mode) {
        const temporary = `${filename}.${process.pid}.tmp`;
        fs.writeFileSync(temporary, JSON.stringify(value, null, 2) + '\n', {mode});
        fs.chmodSync(temporary, mode);
        fs.chownSync(temporary, 0, 20);
        fs.renameSync(temporary, filename);
    }
    function replaceGuestAgentInstallation(replacements, service) {
        const token = crypto.randomUUID();
        const prepared = [];
        let stopping = false;
        let wasLoaded = false;
        let restorationFailed = false;
        try {
            for (const replacement of replacements) {
                const original = fs.lstatSync(replacement.path, {throwIfNoEntry: false});
                check(!original || original.isFile() && !original.isSymbolicLink() && original.uid === replacement.uid &&
                    (replacement.uid !== 0 || (original.mode & 0o022) === 0),
                    `Existing guest runner file is not protected: ${replacement.path}`);
                const entry = {...replacement, temporary: `${replacement.path}.${token}.new`,
                    backup: `${replacement.path}.${token}.previous`, original, installed: false};
                prepared.push(entry);
                if (replacement.source) fs.copyFileSync(replacement.source, entry.temporary, fs.constants.COPYFILE_EXCL);
                else fs.writeFileSync(entry.temporary, replacement.data, {flag: 'wx', mode: 0o600});
                fs.chmodSync(entry.temporary, replacement.mode);
                fs.chownSync(entry.temporary, replacement.uid, replacement.gid);
                if (original) {
                    fs.copyFileSync(replacement.path, entry.backup, fs.constants.COPYFILE_EXCL);
                    fs.chmodSync(entry.backup, original.mode & 0o7777);
                    fs.chownSync(entry.backup, original.uid, original.gid);
                }
            }
            wasLoaded = service.isLoaded();
            for (const [signal, code] of [['SIGINT', 130], ['SIGTERM', 143], ['SIGHUP', 129]]) {
                process.on(signal, () => { process.exitCode = code; });
            }
            // Drain queued signals after synchronous replacement or rollback.
            setImmediate(() => {});
            stopping = true;
            service.stop();
            for (const entry of prepared) {
                fs.renameSync(entry.temporary, entry.path);
                entry.installed = true;
            }
            service.start();
        } catch (error) {
            if (stopping) {
                try {
                    service.stop();
                    for (const entry of prepared.toReversed()) {
                        if (!entry.installed) continue;
                        if (entry.original) fs.renameSync(entry.backup, entry.path);
                        else fs.rmSync(entry.path);
                    }
                    if (wasLoaded) service.start();
                } catch (restoreError) {
                    restorationFailed = true;
                    throw new Error(`${error.message} Previous guest agent restoration failed: ${restoreError.message}. Protected .previous files were retained.`);
                }
            }
            throw error;
        } finally {
            for (const entry of prepared) {
                fs.rmSync(entry.temporary, {force: true});
                if (!restorationFailed) fs.rmSync(entry.backup, {force: true});
            }
        }
    }
    function xcodeVersion(application) {
        const filename = path.join(application, 'Contents/version.plist');
        if (!fs.existsSync(filename)) return null;
        return {
            version: run('Read Xcode version', '/usr/bin/plutil', ['-extract', 'CFBundleShortVersionString', 'raw', '-o', '-', filename]),
            buildVersion: run('Read Xcode build', '/usr/bin/plutil', ['-extract', 'ProductBuildVersion', 'raw', '-o', '-', filename]),
        };
    }
    function matchesXcode(value) { return value?.version === config.xcode.version && value?.buildVersion === config.xcode.buildVersion; }

    function extractXcodeArchive(archive, expectedSHA256, incoming) {
        const digest = run('Verify staged Xcode archive', '/usr/bin/shasum', ['-a', '256', archive]).split(/\s+/)[0];
        check(digest === expectedSHA256, 'The staged Xcode archive SHA-256 does not match; the existing installation was preserved.');
        fs.mkdirSync(incoming, {mode: 0o755});
        run('Extract pinned Xcode archive', '/usr/bin/tar', ['-xf', archive, '-C', incoming, '--strip-components', '1', '--no-same-owner']);
    }
    function selectedUserSessionReady() {
        const options = {encoding: 'utf8', timeout: 1000, killSignal: 'SIGKILL'};
        const consoleUser = spawnSync('/usr/bin/stat', ['-f', '%u', '/dev/console'], options);
        if (consoleUser.status !== 0 || consoleUser.stdout.trim() !== String(uid) ||
            spawnSync('/bin/launchctl', ['print', `gui/${uid}`], {...options, stdio: 'ignore'}).status !== 0) return false;
        const registry = spawnSync('/usr/sbin/ioreg', ['-n', 'Root', '-d', '1', '-a'], options);
        if (registry.status !== 0) return false;
        const locked = spawnSync('/usr/bin/plutil', ['-extract', 'IOConsoleLocked', 'raw', '-o', '-', '-'], {...options, input: registry.stdout});
        return locked.status === 0 && locked.stdout.trim() === 'false';
    }
    function automaticLoginEnabled() {
        const result = spawnSync('/usr/sbin/sysadminctl', ['-autologin', 'status'],
            {encoding: 'utf8', timeout: 10000, killSignal: 'SIGKILL', maxBuffer: 16 * 1024});
        const message = `${result.stdout}${result.stderr}`;
        const account = new RegExp(`(^|[^A-Za-z0-9_-])${config.consoleUser}($|[^A-Za-z0-9_-])`);
        return result.status === 0 && account.test(message) && !/\b(off|disabled|failed|error)\b/i.test(message);
    }

    function ensureAutomaticLogin() {
        const enabled = automaticLoginEnabled();
        const requiresRestart = !enabled && !selectedUserSessionReady();
        let result, password;
        if (!enabled) {
            check(config.autologin && Object.hasOwn(config.autologin, 'passwordFile'),
                'Automatic login is disabled. Supply the existing guest account password in autologin.passwordFile; no password will be reset.');
            check(run('Read selected account groups', '/usr/bin/id', ['-Gn', config.consoleUser]).split(/\s+/).includes('admin'),
                'Automatic login setup requires the selected guest account to be an administrator.');
            if (config.interactiveSetup === true && requiresRestart) {
                waitForSelectedSession({timeoutMilliseconds: 300000});
            }
            password = secret(config.autologin.passwordFile, 'autologin.passwordFile');
            const args = ['-autologin', 'set', '-userName', config.consoleUser, '-password', password,
                '-adminUser', config.consoleUser, '-adminPassword', password];
            const invocation = selectedUserSessionReady() ? ['/bin/launchctl', ['asuser', uidText, '/usr/sbin/sysadminctl', ...args]] :
                ['/usr/sbin/sysadminctl', args];
            result = spawnSync(invocation[0], invocation[1], {
                encoding: 'utf8', env: environment, timeout: 60000, killSignal: 'SIGKILL', maxBuffer: 16 * 1024,
            });
        }
        const verified = automaticLoginEnabled();
        if (!verified && result) {
            process.stderr.write(`Automatic login command diagnostics: ${JSON.stringify(automaticLoginCommandDiagnostic(result, password))}\n`);
        }
        if (result && result.status !== 0) {
            fail(`Enable automatic login for the selected guest account failed${result.error ?
                ` (${result.error.code || 'process error'})` : ` (exit ${result.status})`}.`);
        }
        check(verified, 'Automatic login for the selected guest account is unavailable. Check the existing password and guest FileVault/login policy; no password was reset.');
        return requiresRestart;
    }
    function waitForSelectedSession({ready = selectedUserSessionReady, now = () => performance.now(), timeoutMilliseconds = 120000,
        wait = milliseconds => {
            const result = spawnSync('/bin/sleep', [String(milliseconds / 1000)], {timeout: Math.ceil(milliseconds) + 1000, killSignal: 'SIGKILL'});
            check(result.status === 0, 'Waiting for the guest graphical session was interrupted.');
        }} = {}) {
        const deadline = now() + timeoutMilliseconds;
        while (!ready()) {
            const remaining = deadline - now();
            check(remaining > 0, `The selected guest account did not reach an unlocked Aqua session within ${timeoutMilliseconds / 1000} seconds. Check guest automatic login and lock policy.`);
            wait(Math.min(1000, remaining));
        }
    }

    function retireSupersededRuntimes(previous, wanted, buildRoot, verifyOnly = false) {
        validateRetirementPins(previous);
        validateRetirementPins(wanted);
        const uuid = id => typeof id === 'string' && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(id);
        const simctl = (...args) => run('Retire superseded simulator runtime', '/usr/bin/env',
            ['DEVELOPER_DIR=' + developer, '/usr/bin/xcrun', 'simctl', ...args],
            {user: true, timeout: 120000, maxBuffer: 4 * 1024 * 1024});
        for (const pin of previous) {
            const target = wanted.find(value => value.platform === pin.platform);
            check(target, 'A replacement pin is required for runtime retirement.');
            if (target.version === pin.version && target.buildVersion === pin.buildVersion) continue;
            const key = `${pin.platform}-${pin.version}-${pin.buildVersion}`;
            const runtimeID = `com.apple.CoreSimulator.SimRuntime.${pin.platform === 'iOS' ? 'iOS' : 'xrOS'}-${pin.version.replaceAll('.', '-')}`;
            const oldImage = image => matchesRuntimeImage(image, pin);
            const oldProfile = profile => profile.identifier === runtimeID && profile.version === pin.version && profile.buildversion === pin.buildVersion;
            const inventory = () => {
                const images = JSON.parse(simctl('runtime', 'list', '--json'));
                const {runtimes} = JSON.parse(simctl('list', 'runtimes', '--json'));
                const {devices} = JSON.parse(simctl('list', 'devices', '--json'));
                check(images && !Array.isArray(images) && typeof images === 'object' && Object.keys(images).length <= 256 &&
                    Object.entries(images).every(([id, image]) => uuid(id) && image?.identifier === id) && Array.isArray(runtimes) &&
                    devices && typeof devices === 'object' && !Array.isArray(devices) && Object.values(devices).every(Array.isArray),
                    'Invalid simulator inventory during runtime retirement.');
                const all = Object.values(images), selected = all.filter(oldImage);
                check(selected.every(image => image.runtimeIdentifier === runtimeID && image.deletable === true &&
                    typeof image.path === 'string' && path.isAbsolute(image.path) &&
                    !all.some(other => !oldImage(other) && other.path === image.path)),
                    'A superseded image is non-deletable or shares an ambiguous runtime asset.');
                const shared = target.version === pin.version || all.some(image => image.runtimeIdentifier === runtimeID && !oldImage(image)) ||
                    runtimes.some(profile => profile.identifier === runtimeID && !oldProfile(profile));
                const affected = devices[runtimeID] ?? [];
                const deviceIDs = affected.map(device => device.udid?.toLowerCase());
                const otherIDs = new Set(Object.entries(devices).filter(([id]) => id !== runtimeID)
                    .flatMap(([, others]) => others.map(device => device.udid?.toLowerCase())));
                check((!selected.length && shared || affected.every(device => device.state === 'Shutdown')) &&
                    new Set(deviceIDs).size === deviceIDs.length && deviceIDs.every(id => uuid(id) && !otherIDs.has(id)),
                    'Affected simulators must have unambiguous identifiers and be shut down for runtime retirement.');
                return {images: selected, profiles: runtimes.filter(oldProfile), devices: shared ? [] : affected};
            };
            const downloads = path.join(buildRoot, 'RuntimeDownloads', key);
            const sources = path.join(buildRoot, 'RuntimeRepairSources', key);
            const receipt = path.join(state, 'RuntimeRepairs', key + '.json');
            const ownedArtifact = filename => {
                const parent = path.dirname(filename);
                const directory = fs.lstatSync(parent, {throwIfNoEntry: false});
                if (!directory) return null;
                check(directory.isDirectory() && directory.uid === 0 && !(directory.mode & 0o022) &&
                    fs.realpathSync(parent) === parent && directory.dev === fs.statSync(path.dirname(parent)).dev,
                    'Superseded runtime artifacts must remain in a protected runner directory.');
                const metadata = fs.lstatSync(filename, {throwIfNoEntry: false});
                if (!metadata) return null;
                let entries = 0;
                function inspect(file, item, depth) {
                    const exportContent = filename === downloads && depth > 0;
                    check(depth <= 24 && ++entries <= 16384 && (exportContent || item.uid === 0 && !(item.mode & 0o022)) &&
                        item.dev === directory.dev && (item.isFile() || item.isDirectory()),
                        `Unsafe entry in superseded runtime artifact ${file} (uid ${item.uid}, mode ${item.mode.toString(8)}).`);
                    if (item.isDirectory()) for (const child of fs.readdirSync(file)) {
                        const next = path.join(file, child);
                        inspect(next, fs.lstatSync(next), depth + 1);
                    }
                }
                inspect(filename, metadata, 0);
                check(filename === receipt ? metadata.isFile() && !(metadata.mode & 0o077) && metadata.size <= 128 * 1024 :
                    metadata.isDirectory(), 'Unexpected superseded runtime artifact type.');
                return metadata;
            };
            const artifacts = new Map([downloads, sources, receipt].map(filename => [filename, ownedArtifact(filename)]));
            check(!artifacts.get(sources) || artifacts.get(receipt), 'Superseded repair source lacks its ownership receipt.');
            if (artifacts.get(receipt)) {
                const saved = JSON.parse(fs.readFileSync(receipt, 'utf8'));
                check(saved.version === 1 && saved.vmId === config.vmId && saved.phase === 'complete' &&
                    saved.pin?.platform === pin.platform && saved.pin.version === pin.version && saved.pin.buildVersion === pin.buildVersion &&
                    saved.sourcePath === path.join(sources, 'runtime.dmg'), 'Invalid or incomplete superseded runtime repair receipt.');
            }
            let current = inventory();
            if (!verifyOnly) {
                for (const device of current.devices) {
                    check(inventory().devices.some(candidate => candidate.udid === device.udid),
                        'Simulator device ownership changed during retirement.');
                    simctl('delete', device.udid);
                }
                const initial = current.images;
                for (const image of initial) {
                    current = inventory();
                    check(!current.devices.length && current.images.every(value => initial.some(entry =>
                        entry.identifier === value.identifier && entry.path === value.path)), 'Runtime ownership changed during retirement.');
                    if (current.images.some(value => value.identifier === image.identifier)) simctl('runtime', 'delete', image.identifier);
                }
                current = inventory();
            }
            check(!current.images.length && !current.profiles.length && !current.devices.length,
                `Superseded runtime ${key} is still registered in the guest.`);
            for (const [filename, original] of artifacts) {
                if (verifyOnly) {
                    check(!original, 'Superseded runtime artifacts are still present.');
                    continue;
                }
                const observed = ownedArtifact(filename);
                check(original?.dev === observed?.dev && original?.ino === observed?.ino && original?.ctimeMs === observed?.ctimeMs,
                    'Superseded runtime artifact changed before removal.');
                if (observed) {
                    if (filename === receipt) fs.unlinkSync(filename);
                    else {
                        const cwd = process.cwd();
                        try {
                            process.chdir(filename);
                            const bound = fs.statSync('.');
                            check(bound.dev === original.dev && bound.ino === original.ino, 'Superseded runtime artifact was replaced.');
                            run('Remove superseded runtime files', '/usr/bin/find', ['.', '-xdev', '-mindepth', '1', '-delete']);
                        } finally { process.chdir(cwd); }
                        const root = fs.lstatSync(filename);
                        check(root.dev === original.dev && root.ino === original.ino, 'Superseded runtime artifact was replaced.');
                        fs.rmdirSync(filename);
                    }
                    check(!fs.lstatSync(filename, {throwIfNoEntry: false}), 'Superseded runtime artifact removal did not complete.');
                }
                const parent = path.dirname(filename);
                syncDirectory(fs.lstatSync(parent, {throwIfNoEntry: false}) ? parent : path.dirname(parent));
            }
            console.log(`Verified retirement of ${key}.`);
        }
    }
    function prepareRuntimeCache(runtime, wanted) {
        check(runtime && matchesRuntime(runtime, wanted), 'Shared-cache preparation requires the exact available pinned runtime.');
        const command = ['DEVELOPER_DIR=' + developer, '/usr/bin/xcrun'];
        console.log(`Preparing the shared cache for ${wanted.platform} ${wanted.version} (${wanted.buildVersion}).`);
        run(`Prepare ${wanted.platform} shared cache`, '/usr/bin/env',
            [...command, 'simctl', 'runtime', 'dyld_shared_cache', 'update', runtime.identifier],
            {user: true, timeout: 1_800_000, maxBuffer: 64 * 1024, logStdout: true});
        const after = JSON.parse(run(`Recheck ${wanted.platform} after shared-cache preparation`, '/usr/bin/env',
            [...command, 'simctl', 'list', 'runtimes', '--json'], {user: true, timeout: 120000, maxBuffer: 4 * 1024 * 1024})).runtimes;
        check(Array.isArray(after) && after.some(value => value.identifier === runtime.identifier && matchesRuntime(value, wanted)),
            `The pinned ${wanted.platform} runtime changed or became unavailable after shared-cache preparation.`);
    }
    function runtimeFileDigest(filename) {
        check(path.isAbsolute(filename) && fs.realpathSync(filename) === filename, 'Runtime source must not traverse symlinks.');
        const descriptor = fs.openSync(filename, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
        try {
            const before = fs.fstatSync(descriptor);
            check(before.isFile() && (before.mode & 0o022) === 0 && Number.isSafeInteger(before.size) &&
                before.size > 0 && before.size <= 128 * 1024 ** 3, 'Runtime source must be a protected bounded regular file.');
            const hash = crypto.createHash('sha256'), buffer = Buffer.alloc(1024 * 1024);
            let offset = 0, count;
            while ((count = fs.readSync(descriptor, buffer, 0, buffer.length, offset)) > 0) {
                hash.update(buffer.subarray(0, count)); offset += count;
                check(offset <= before.size, 'Runtime source changed while hashing.');
            }
            const after = fs.fstatSync(descriptor);
            check(offset === before.size && before.ino === after.ino && before.size === after.size &&
                before.mtimeMs === after.mtimeMs && before.ctimeMs === after.ctimeMs, 'Runtime source changed while hashing.');
            return {sha256: hash.digest('hex'), size: before.size};
        } finally { fs.closeSync(descriptor); }
    }
    function runtimeMetadataField(filename, key, format = 'raw') {
        check(['raw', 'json'].includes(format), 'Invalid runtime metadata extraction format.');
        const output = run('Read pinned runtime metadata', '/usr/bin/plutil',
            ['-extract', key, format, '-o', '-', filename], {timeout: 30000, maxBuffer: 1024 * 1024});
        return format === 'json' ? JSON.parse(output) : output;
    }

    function verifyOrRepairPinnedRuntime(wanted, buildRoot, mode = 'prepare', retirement) {
        check(['prepare', 'existing', 'verify'].includes(mode), 'Invalid runtime verification mode.');
        check(['iOS', 'visionOS'].includes(wanted.platform) && /^\d+(?:\.\d+){1,2}$/.test(wanted.version) &&
            /^\d+[A-Z]\d+[a-z]?$/.test(wanted.buildVersion), 'Invalid pinned runtime repair identity.');
        const assetIdentifier = `com.apple.MobileAsset.${wanted.platform === 'iOS' ? 'iOS' : 'xrOS'}SimulatorRuntime`;
        const pin = {platform: wanted.platform, version: wanted.version, buildVersion: wanted.buildVersion};
        const key = `${wanted.platform}-${wanted.version}-${wanted.buildVersion}`;
        const journalDirectory = path.join(state, 'RuntimeRepairs');
        const journalPath = path.join(journalDirectory, `${key}.json`);
        const sourceDirectory = path.join(buildRoot, 'RuntimeRepairSources', key);
        const sourcePath = path.join(sourceDirectory, 'runtime.dmg');
        const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value);
        const assetRoot = `/System/Library/AssetsV2/${assetIdentifier.replaceAll('.', '_')}/`;
        const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
        const mkdir = (directory, mode) => {
            fs.mkdirSync(directory, {recursive: true, mode});
            const info = fs.lstatSync(directory);
            check(info.isDirectory() && !info.isSymbolicLink() && info.uid === 0 && (info.mode & 0o022) === 0 &&
                fs.realpathSync(directory) === directory, 'Runtime repair storage must be root-owned and protected.');
        };
        const invoke = (args, accepted = [0], timeout = 600000) => {
            const result = run(`${wanted.platform} runtime ${args.slice(0, 3).join(' ')}`, '/usr/bin/env',
                ['DEVELOPER_DIR=' + developer, '/usr/bin/xcrun', 'simctl', ...args],
                {user: true, timeout, maxBuffer: 2 * 1024 * 1024, returnStatus: true,
                    logStdout: ['verify', 'add', 'delete'].includes(args[1])});
            check(accepted.includes(result.status), `Pinned ${wanted.platform} runtime operation failed (exit ${result.status}).`);
            return result;
        };
        const images = () => {
            const value = JSON.parse(invoke(['runtime', 'list', '--json']).stdout);
            check(value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).length <= 256,
                'Invalid runtime image inventory.');
            return Object.entries(value).map(([id, image]) => {
                check(uuid(id) && image.identifier === id, 'Invalid runtime image identifier.');
                return image;
            });
        };
        const matches = image => matchesRuntimeImage(image, wanted);
        const trackedImages = (values = images()) => values.filter(image => !retirement?.pins.some(pin => matchesRuntimeImage(image, pin)));
        const checkSpace = image => runtimeStorageCheckpoint(buildRoot, wanted.platform, image, retirement?.release);
        const bound = image => Object.fromEntries(['identifier', 'kind', 'path', 'platformIdentifier', 'runtimeIdentifier', 'version', 'build', 'sizeBytes']
            .map(name => [name, image[name]]));
        const verify = image => {
            const result = invoke(['runtime', 'verify', image.identifier], [0, 1]);
            if (result.status === 0 && /^Signature verified, signature is valid\.$/m.test(result.stdout)) return {status: 'verified'};
            check(result.status === 1 && /^Signature verification failed:.*-67054\b/m.test(result.stdout),
                'Runtime signature verification was inconclusive; no repair is authorized.');
            return {status: 'rejected', code: -67054, output: result.stdout.slice(0, 4096)};
        };
        const profile = (image, waitForHandoff = false) => {
            const deadline = waitForHandoff ? performance.now() + 90000 : null;
            const read = () => {
                const timeout = deadline === null ? 600000 : Math.max(1, Math.min(10000, Math.ceil(deadline - performance.now())));
                const values = JSON.parse(invoke(['list', 'runtimes', '--json'], [0], timeout).stdout).runtimes;
                check(Array.isArray(values), 'Invalid usable runtime inventory.');
                return values;
            };
            const exact = values => values.filter(value => value.version === wanted.version && value.buildversion === wanted.buildVersion &&
                value.identifier === image.runtimeIdentifier && value.bundlePath === image.runtimeBundlePath &&
                value.runtimeRoot === path.join(image.runtimeBundlePath, 'Contents/Resources/RuntimeRoot'));
            let runtimes = read(), matching = exact(runtimes), selected = matching.filter(value => value.isAvailable === true);
            try {
                let scope;
                while (waitForHandoff && selected.length === 0 && matching.length === 1 && matching[0].isAvailable === false) {
                    check(image.kind === 'Disk Image' && image.state === 'Ready' && image.signatureState === 'Verified' &&
                        path.isAbsolute(image.mountPath) && image.runtimeBundlePath.startsWith(image.mountPath + '/'),
                        'The owned Ready runtime scope changed during profile handoff.');
                    const file = fs.lstatSync(image.path), directory = fs.statSync(image.runtimeBundlePath);
                    check(file.isFile() && !file.isSymbolicLink() && file.size === image.sizeBytes && directory.isDirectory(),
                        'The owned Ready runtime scope changed during profile handoff.');
                    const observed = [file.dev, file.ino, file.size, file.mtimeMs, directory.dev, directory.ino];
                    check(scope === undefined || same(scope, observed), 'The owned Ready runtime scope changed during profile handoff.');
                    scope = observed;
                    const remaining = deadline - performance.now();
                    check(remaining > 0, 'The exact pinned runtime profile did not become available within 90 seconds.');
                    run('Wait for exact runtime profile handoff', '/bin/sleep', [String(Math.min(2000, remaining) / 1000)],
                        {timeout: Math.max(1, Math.ceil(Math.min(3000, remaining))), maxBuffer: 1024});
                    check(performance.now() < deadline, 'The exact pinned runtime profile did not become available within 90 seconds.');
                    runtimes = read(); matching = exact(runtimes); selected = matching.filter(value => value.isAvailable === true);
                }
                if (scope !== undefined) {
                    const file = fs.lstatSync(image.path), directory = fs.statSync(image.runtimeBundlePath);
                    check(file.isFile() && !file.isSymbolicLink() && directory.isDirectory() &&
                        same(scope, [file.dev, file.ino, file.size, file.mtimeMs, directory.dev, directory.ino]),
                        'The owned Ready runtime scope changed during profile handoff.');
                }
                check(selected.length === 1 && path.isAbsolute(image.mountPath) && path.isAbsolute(image.runtimeBundlePath) &&
                    image.runtimeBundlePath.startsWith(image.mountPath + '/') && fs.statSync(image.runtimeBundlePath).isDirectory(),
                    'The verified pinned runtime profile is not mounted and available.');
            } catch (error) {
                const directory = {exists: false, existsError: null};
                try { directory.exists = fs.statSync(image.runtimeBundlePath).isDirectory(); }
                catch (inspection) { directory.existsError = typeof inspection.code === 'string' && /^[A-Z0-9_]{1,32}$/.test(inspection.code)
                    ? inspection.code : 'inspection-failed'; }
                console.log('BIG_WALLET_RUNTIME_PROFILE_DIAGNOSTIC=' +
                    JSON.stringify(runtimeProfileDiagnostic(pin, image, runtimes, directory, selected.length)));
                throw error;
            }
            const versionPath = path.join(selected[0].runtimeRoot, 'System/Library/CoreServices/SystemVersion.plist');
            check(runtimeMetadataField(versionPath, 'ProductVersion') === wanted.version &&
                runtimeMetadataField(versionPath, 'ProductBuildVersion') === wanted.buildVersion,
                'The mounted simulator system version differs from the runtime pin.');
            const mounts = run('Verify sealed runtime mount', '/sbin/mount', [], {timeout: 30000, maxBuffer: 1024 * 1024})
                .split('\n').map(line => /^(\S+) on (.+) \(([^)]+)\)$/.exec(line)).filter(value => value?.[2] === image.mountPath);
            check(mounts.length === 1 && /^\/dev\/disk\d+(?:s\d+)+$/.test(mounts[0][1]) &&
                ['apfs', 'sealed', 'read-only'].every(value => mounts[0][3].split(', ').includes(value)),
                'The pinned runtime is not on a sealed read-only APFS mount.');
            return selected[0];
        };
        let journal;
        if (fs.existsSync(journalPath)) {
            const info = fs.lstatSync(journalPath);
            check(info.isFile() && !info.isSymbolicLink() && info.uid === 0 && (info.mode & 0o077) === 0 && info.size <= 128 * 1024,
                'Runtime repair receipt must be private and bounded.');
            journal = JSON.parse(fs.readFileSync(journalPath, 'utf8'));
            check(journal.version === 1 && journal.vmId === config.vmId && same(journal.pin, pin) && journal.sourcePath === sourcePath &&
                ['source', 'probe', 'probe-verified', 'deleting', 'adding', 'complete'].includes(journal.phase),
                'Runtime repair receipt belongs to another source or pin.');
        }
        check(mode !== 'verify' || !journal || journal.phase === 'complete', 'Runtime repair is incomplete.');
        let inventory = images();
        const selected = inventory.filter(matches);
        if (mode === 'existing' && !journal && selected.length === 0) return null;
        if (!journal) {
            check(selected.length > 0 && selected.length <= 8, 'The pinned runtime image inventory is missing or ambiguous.');
            const ready = selected.filter(image => image.state === 'Ready');
            check(ready.length === 1, 'The pinned runtime has ambiguous active registrations.');
            const rejection = verify(ready[0]);
            if (rejection.status === 'verified') {
                return profile(ready[0], mode === 'prepare');
            }
            check(mode !== 'verify', 'Pinned runtime signature changed after preparation.');
            const repairable = selected.every(image => image.kind === 'Patchable Cryptex Disk Image' && image.deletable === true &&
                (image.identifier === ready[0].identifier || image.state === 'Unusable' && image.unusableErrorMessage === 'Cryptex Mount Preferred'));
            if (!repairable) {
                let fresh = null;
                try { fresh = images().filter(matches); } catch {}
                console.log('BIG_WALLET_RUNTIME_REPAIR_ADMISSION=' + JSON.stringify(runtimeAdmissionDiagnostic(pin, selected, fresh)));
                fail('Automatic runtime repair is limited to explicitly rejected patchable cryptex registrations.');
            }
            const assetPaths = new Set(selected.map(image => image.path));
            check(assetPaths.size === 1 && [...assetPaths].every(value => typeof value === 'string' &&
                value.startsWith(assetRoot) && /^[0-9a-f]+\.asset\/AssetData$/i.test(value.slice(assetRoot.length))),
                'Rejected runtime aliases do not identify one official asset.');
            check(!inventory.some(image => !matches(image) && assetPaths.has(image.path)), 'Another runtime pin shares the rejected asset.');
            const exported = exportedRuntimeImage(path.join(buildRoot, 'RuntimeDownloads', key));
            check(fs.lstatSync(exported).isDirectory(), 'Runtime repair requires the preserved official exported bundle metadata.');
            const metadataPath = path.join(exported, 'ExportedMetadata.plist');
            const manifestPath = path.join(exported, 'Restore/BuildManifest.plist');
            const restorePath = path.join(exported, 'Restore/Restore.plist');
            const architectures = runtimeMetadataField(metadataPath, 'MobileAssetProperties.Architectures', 'json');
            check(runtimeMetadataField(metadataPath, 'CFBundleIdentifier') === assetIdentifier &&
                runtimeMetadataField(metadataPath, 'MobileAssetProperties.Build') === wanted.buildVersion &&
                runtimeMetadataField(metadataPath, 'MobileAssetProperties.SimulatorVersion') === wanted.version &&
                Array.isArray(architectures) && architectures.includes('arm64') &&
                [manifestPath, restorePath].every(filename => runtimeMetadataField(filename, 'ProductVersion') === wanted.version &&
                    runtimeMetadataField(filename, 'ProductBuildVersion') === wanted.buildVersion),
                'The official runtime export metadata differs from the exact pin.');
            const payloads = fs.readdirSync(path.join(exported, 'Restore')).filter(name => name.endsWith('.dmg'));
            check(payloads.length === 1, 'The official runtime export must contain exactly one Restore disk image.');
            const original = path.join(exported, 'Restore', payloads[0]);
            const digest = runtimeFileDigest(original);
            mkdir(journalDirectory, 0o700);
            mkdir(path.dirname(sourceDirectory), 0o755);
            mkdir(sourceDirectory, 0o755);
            check(!fs.existsSync(sourcePath), 'An unrecorded runtime repair source already exists; preserve it for inspection.');
            journal = {version: 1, vmId: config.vmId, pin, phase: 'source', sourcePath, original, source: digest,
                metadata: {exported: runtimeFileDigest(metadataPath), manifest: runtimeFileDigest(manifestPath), restore: runtimeFileDigest(restorePath)},
                failed: selected.map(image => ({...bound(image), proof: image.identifier === ready[0].identifier ? rejection :
                    {status: 'same-asset-alias', activeIdentifier: ready[0].identifier}})), deleted: []};
            writeDurableJSON(journalPath, journal, 0o600);
        }
        const validImage = image => image && uuid(image.identifier) && matches(image) &&
            typeof image.runtimeIdentifier === 'string' && Number.isSafeInteger(image.sizeBytes) && image.sizeBytes > 0;
        const ordinary = image => validImage(image) && image.kind === 'Disk Image' && typeof image.path === 'string' &&
            image.path.startsWith('/Library/Developer/CoreSimulator/Images/') && path.resolve(image.path) === image.path &&
            image.path.endsWith('/' + image.identifier + '.dmg');
        const originalRelative = path.relative(path.join(buildRoot, 'RuntimeDownloads', key), journal.original ?? '').split(path.sep);
        check(originalRelative.length >= 3 && originalRelative.length <= 6 && !originalRelative.includes('..') &&
            path.resolve(journal.original) === journal.original && /\.export(?:ed)?Bundle$/.test(originalRelative.at(-3)) &&
            originalRelative.at(-2) === 'Restore' && originalRelative.at(-1).endsWith('.dmg') &&
            journal.source && /^[0-9a-f]{64}$/.test(journal.source.sha256) && Number.isSafeInteger(journal.source.size) && journal.source.size > 0 &&
            Array.isArray(journal.failed) && journal.failed.length > 0 && journal.failed.length <= 8 &&
            new Set(journal.failed.map(value => value.identifier)).size === journal.failed.length &&
            journal.failed.every(value => validImage(value) && value.kind === 'Patchable Cryptex Disk Image' &&
                typeof value.path === 'string' && value.path.startsWith(assetRoot) && /^[0-9a-f]+\.asset\/AssetData$/i.test(value.path.slice(assetRoot.length))) &&
            new Set(journal.failed.map(value => value.path)).size === 1 &&
            Array.isArray(journal.deleted) && journal.deleted.every(id => journal.failed.some(value => value.identifier === id)),
            'Runtime repair ownership or preserved-source proof is invalid.');
        const rejected = journal.failed.filter(value => value.proof?.status === 'rejected' && value.proof.code === -67054);
        check(rejected.length === 1 && journal.failed.every(value => value === rejected[0] ||
            value.proof?.status === 'same-asset-alias' && value.proof.activeIdentifier === rejected[0].identifier),
            'Runtime repair has no exact active signature rejection.');
        check(!journal.probe || ordinary(journal.probe), 'Runtime source probe ownership is invalid.');
        check(!journal.installed || ordinary(journal.installed), 'Installed runtime repair ownership is invalid.');
        for (const field of ['beforeProbe', 'beforeAdd']) check(journal[field] === undefined || Array.isArray(journal[field]) &&
            journal[field].every(uuid) && new Set(journal[field]).size === journal[field].length, 'Runtime repair inventory receipt is invalid.');
        const save = phase => { journal.phase = phase; writeDurableJSON(journalPath, journal, 0o600); };
        const sourceValid = () => {
            check(fs.lstatSync(sourcePath).uid === 0, 'The preserved runtime repair source changed.');
            const observed = runtimeFileDigest(sourcePath);
            check(same(observed, journal.source), 'The preserved runtime repair source changed.');
            return observed;
        };
        const current = (entry, values = images()) => {
            const item = values.find(value => value.identifier === entry.identifier);
            check(!item || same(bound(item), bound(entry)), 'A recorded runtime image identity changed.');
            const allowed = new Set([...journal.failed.map(value => value.identifier), journal.probe?.identifier, journal.installed?.identifier].filter(Boolean));
            check(!values.some(value => matches(value) && !allowed.has(value.identifier)), 'An unrecorded runtime alias appeared; preserve the repair for inspection.');
            return item;
        };
        const readySourceProof = image => {
            check(image && ordinary(image) && image.state === 'Ready' && image.signatureState === 'Verified' &&
                image.sizeBytes === journal.source.size && same(runtimeFileDigest(image.path), journal.source) &&
                verify(image).status === 'verified', 'The owned Ready source image did not verify against the preserved payload.');
            profile(image, true); sourceValid();
            return {image: bound(image), state: 'Ready', signatureState: 'Verified', imageDigest: journal.source};
        };
        const recordReadyProbe = image => {
            check(journal.probeAttempted === true && (!journal.probe || same(bound(image), journal.probe)),
                'The Ready source image has no matching recorded probe intent.');
            const proof = journal.probeCompletion;
            check(!proof || (proof.kind === 'completed-native-add' ? proof.exitCode === 0 && same(proof.inputBefore, journal.source) &&
                same(proof.inputAfter, journal.source) : proof.kind === 'observed-native-completion' && same(proof.inputAfter, journal.source)),
                'The Ready source image conflicts with the recorded native completion.');
            const nativeVerification = readySourceProof(image);
            journal.probe = bound(image);
            journal.keepReadyProbe = true;
            journal.probeCompletion = {...(proof ?? {kind: 'observed-native-completion', inputAfter: journal.source}), nativeVerification};
        };
        if (journal.phase === 'source') {
            check(same(runtimeFileDigest(journal.original), journal.source), 'The original official runtime source changed.');
            if (retirement?.release) checkSpace(journal.original);
            const incoming = sourcePath + '.incoming';
            if (fs.existsSync(incoming)) {
                const item = fs.lstatSync(incoming);
                check(item.isFile() && !item.isSymbolicLink() && item.uid === 0, 'Unsafe partial runtime source.');
            }
            if (fs.existsSync(sourcePath)) sourceValid();
            else {
                fs.copyFileSync(journal.original, incoming, fs.constants.COPYFILE_FICLONE);
                fs.chmodSync(incoming, 0o644);
                fs.chownSync(incoming, 0, 20);
                check(same(runtimeFileDigest(incoming), journal.source), 'The independent runtime copy did not match.');
                const descriptor = fs.openSync(incoming, 'r');
                try { fs.fsyncSync(descriptor); } finally { fs.closeSync(descriptor); }
                fs.renameSync(incoming, sourcePath);
                syncDirectory(sourceDirectory);
            }
            journal.beforeProbe = trackedImages().map(value => value.identifier);
            save('probe');
        }
        sourceValid();
        if (journal.phase === 'probe') {
            inventory = images();
            const readyProbes = inventory.filter(image => matches(image) && ordinary(image) && image.state === 'Ready' &&
                (image.identifier === journal.probe?.identifier || !journal.beforeProbe.includes(image.identifier)));
            if (readyProbes.length) {
                check(readyProbes.length === 1, 'Multiple new Ready source images are ambiguous.');
                recordReadyProbe(readyProbes[0]); save('probe');
            }
            const previousIDs = new Set(journal.failed.map(image => image.identifier));
            const replacements = inventory.filter(image => matches(image) && !(journal.keepReadyProbe && image.identifier === journal.probe.identifier));
            if (journal.deleted.length === 0 && !inventory.some(image => previousIDs.has(image.identifier)) && replacements.length > 0) {
                const previousAnchor = journal.failed.find(image => image.proof.status === 'rejected');
                const equivalent = image => same({...bound(image), identifier: previousAnchor.identifier}, bound(previousAnchor));
                const anchors = replacements.filter(image => image.state === 'Ready');
                check(replacements.length <= 8 && anchors.length === 1 && replacements.every(image => equivalent(image) &&
                    image.deletable === true && (image.identifier === anchors[0].identifier ||
                        image.state === 'Unusable' && image.unusableErrorMessage === 'Cryptex Mount Preferred')) &&
                    !inventory.some(image => !matches(image) && image.path === previousAnchor.path) &&
                    !trackedImages(inventory).some(image => !journal.beforeProbe.includes(image.identifier) && !matches(image)),
                    'Regenerated runtime registrations do not match the exact retained asset and pin.');
                sourceValid();
                const rejection = verify(anchors[0]);
                check(rejection.status === 'rejected', 'The regenerated runtime has no fresh explicit signature rejection.');
                const confirmed = images();
                const confirmedPins = confirmed.filter(image => matches(image) && !(journal.keepReadyProbe && image.identifier === journal.probe.identifier));
                check(confirmedPins.length === replacements.length && confirmedPins.every(image => replacements.some(previous =>
                    same(bound(image), bound(previous)) && image.state === previous.state && image.deletable === true &&
                    (image.identifier === anchors[0].identifier || image.unusableErrorMessage === 'Cryptex Mount Preferred'))) &&
                    !confirmed.some(image => previousIDs.has(image.identifier) || !matches(image) && image.path === previousAnchor.path) &&
                    !trackedImages(confirmed).some(image => !inventory.some(previous => previous.identifier === image.identifier)),
                    'Runtime registrations changed during fresh signature verification.');
                sourceValid();
                check(journal.bindingHistory === undefined || Array.isArray(journal.bindingHistory), 'Invalid runtime binding history.');
                journal.bindingHistory = [...(journal.bindingHistory ?? []), {reason: 'native-registration-recreated',
                    failed: journal.failed, beforeProbe: journal.beforeProbe, probeAttempted: journal.probeAttempted ?? false,
                    probe: journal.probe ?? null, completion: journal.probeCompletion ?? null}].slice(-4);
                journal.failed = confirmedPins.map(image => ({...bound(image), proof: image.identifier === anchors[0].identifier ? rejection :
                    {status: 'same-asset-alias', activeIdentifier: anchors[0].identifier}}));
                journal.beforeProbe = trackedImages(confirmed).map(image => image.identifier);
                if (!journal.keepReadyProbe) {
                    journal.probeAttempted = false;
                    delete journal.probe;
                    delete journal.probeCompletion;
                }
                save('probe');
                inventory = confirmed;
            }
            let probes = trackedImages(inventory).filter(image => journal.keepReadyProbe && image.identifier === journal.probe.identifier ||
                !journal.beforeProbe.includes(image.identifier));
            if (!probes.length) {
                check(!journal.keepReadyProbe, 'The recorded Ready source image disappeared.');
                if (journal.probeAttempted) {
                    const registrationsUnchanged = journal.failed.every(entry => {
                        const image = inventory.find(value => value.identifier === entry.identifier);
                        return image && same(bound(image), bound(entry)) && (image.state === 'Ready' ||
                            image.state === 'Unusable' && image.unusableErrorMessage === 'Cryptex Mount Preferred');
                    }) && inventory.filter(matches).every(image => journal.failed.some(entry => entry.identifier === image.identifier));
                    if (!registrationsUnchanged) {
                        console.log('BIG_WALLET_RUNTIME_REPAIR_RETRY_ADMISSION=' +
                            JSON.stringify(runtimeAdmissionDiagnostic(pin, journal.failed, inventory.filter(matches))));
                        fail('The failed runtime registrations changed while the native source probe was absent.');
                    }
                    sourceValid();
                    check(journal.probeHistory === undefined || Array.isArray(journal.probeHistory), 'Invalid native probe history.');
                    journal.probeHistory = [...(journal.probeHistory ?? []), {reason: 'registration-absent',
                        beforeProbe: journal.beforeProbe, completion: journal.probeCompletion ?? null}].slice(-4);
                    journal.beforeProbe = trackedImages(inventory).map(image => image.identifier);
                    delete journal.probeCompletion;
                }
                checkSpace(sourcePath);
                const inputBefore = sourceValid();
                journal.probeAttempted = true; save('probe');
                const added = invoke(['runtime', 'add', sourcePath], [0, 5]);
                const inputAfter = sourceValid();
                journal.probeCompletion = {kind: 'completed-native-add', exitCode: added.status, inputBefore, inputAfter};
                if (added.status === 5) {
                    const records = added.stdout.split(/\r?\n/).filter(line => line.startsWith('D: '));
                    const identifier = records.length === 1 && records[0].split(/\s+/, 2)[1];
                    check(uuid(identifier), 'The native duplicate add did not identify its registration.');
                    journal.probeCompletion.identifier = identifier.toUpperCase();
                }
                save('probe');
                probes = trackedImages().filter(image => !journal.beforeProbe.includes(image.identifier));
            }
            check(probes.length === 1, 'The independent native source probe is missing, unverified, or ambiguous.');
            if (probes[0].state === 'Ready' && ordinary(probes[0])) recordReadyProbe(probes[0]);
            else {
                check(journal.probeAttempted === true && Array.isArray(journal.beforeProbe) && ordinary(probes[0]) &&
                    probes[0].state === 'Unusable' && probes[0].signatureState === 'Verified' && probes[0].deletable === true &&
                    probes[0].sizeBytes === journal.source.size &&
                    probes[0].path === `/Library/Developer/CoreSimulator/Images/Inbox/${probes[0].identifier}.dmg` &&
                    journal.failed.some(value => probes[0].unusableErrorMessage === `Duplicate of ${value.identifier}`),
                    'The independent native source probe is missing, unverified, or ambiguous.');
                const nativeVerification = {image: bound(probes[0]), state: probes[0].state, signatureState: probes[0].signatureState,
                    duplicateOf: probes[0].unusableErrorMessage.slice('Duplicate of '.length)};
                const proof = journal.probeCompletion;
                check(proof?.kind === 'completed-native-add' && proof.exitCode === 5 && proof.identifier === probes[0].identifier.toUpperCase(),
                    'The duplicate registration has no matching native add completion; preserve it for inspection.');
                journal.probe = bound(probes[0]);
                proof.nativeVerification = nativeVerification;
            }
            save('probe-verified');
        }
        const completion = journal.probeCompletion;
        const nativeVerification = completion?.nativeVerification;
        const readyProof = journal.keepReadyProbe === true;
        check(completion && journal.probe && nativeVerification?.state === (readyProof ? 'Ready' : 'Unusable') &&
            nativeVerification.signatureState === 'Verified' && same(nativeVerification.image, journal.probe) &&
            (readyProof ? same(nativeVerification.imageDigest, journal.source) : completion.identifier === journal.probe.identifier.toUpperCase() &&
                journal.failed.some(value => value.identifier === nativeVerification.duplicateOf)) &&
            (completion.kind === 'completed-native-add' ? completion.exitCode === (readyProof ? 0 : 5) &&
            same(completion.inputBefore, journal.source) && same(completion.inputAfter, journal.source) :
            readyProof && completion.kind === 'observed-native-completion' && same(completion.inputAfter, journal.source)),
            'Runtime repair requires recorded native source verification.');
        if (journal.phase === 'probe-verified') {
            if (readyProof) {
                journal.installed = journal.probe;
            } else {
                const probe = current(journal.probe);
                if (probe) {
                    check(probe.state === 'Unusable' && probe.signatureState === 'Verified' && probe.deletable === true &&
                        probe.unusableErrorMessage === `Duplicate of ${nativeVerification.duplicateOf}`,
                        'The recorded duplicate probe changed before removal.');
                    invoke(['runtime', 'delete', probe.identifier]);
                }
                check(!current(journal.probe), 'Native source probe removal did not finish.');
            }
            save('deleting');
        }
        if (journal.phase === 'deleting') {
            check(!readyProof || same(journal.installed, journal.probe), 'The retained Ready replacement identity changed.');
            if (!readyProof) checkSpace(sourcePath);
            const anchor = journal.failed.find(entry => entry.proof.status === 'rejected');
            const validateDeletion = values => {
                check(!values.some(image => !matches(image) && image.path === anchor.path), 'Another runtime pin shares the rejected asset.');
                for (const entry of journal.failed) {
                    const image = current(entry, values);
                    if (!image) continue;
                    const displaced = image.state === 'Unusable' && image.unusableErrorMessage === 'Cryptex Mount Preferred';
                    const expectedState = entry === anchor
                        ? image.state === 'Ready' || readyProof && displaced && image.signatureState === 'Unknown'
                        : displaced;
                    check(!journal.deleted.includes(entry.identifier) && image.deletable === true && expectedState,
                        'A recorded failed runtime registration changed before deletion.');
                }
            };
            for (const entry of [...journal.failed.filter(value => value !== anchor), anchor]) {
                let values = images();
                if (current(entry, values)) {
                    validateDeletion(values);
                    const replacement = readyProof && current(journal.installed, values);
                    if (readyProof) readySourceProof(replacement);
                    else sourceValid();
                    const active = current(anchor, values);
                    check(active && verify(active).status === 'rejected', 'Recorded failed runtime signature changed; no deletion authorized.');
                    const devices = JSON.parse(invoke(['list', 'devices', '--json']).stdout).devices;
                    check(devices && typeof devices === 'object' && Object.values(devices).every(Array.isArray), 'Invalid simulator device inventory.');
                    values = images();
                    validateDeletion(values);
                    check(values.filter(image => image.path === anchor.path).every(image =>
                        (devices[image.runtimeIdentifier] ?? []).every(device => device.state === 'Shutdown')),
                        'Affected simulators must be shut down before exact runtime repair.');
                    if (readyProof) {
                        const retained = current(journal.installed, values);
                        check(retained?.state === 'Ready' && retained.signatureState === 'Verified' &&
                            retained.mountPath === replacement.mountPath && retained.runtimeBundlePath === replacement.runtimeBundlePath,
                            'The retained Ready replacement changed during verification.');
                    }
                    check(current(anchor, values) && current(entry, values), 'The failed runtime registrations changed during verification.');
                    journal.deleting = entry.identifier; save('deleting');
                    invoke(['runtime', 'delete', entry.identifier]);
                }
                check(!current(entry), 'Exact runtime deletion did not finish.');
                if (!journal.deleted.includes(entry.identifier)) journal.deleted.push(entry.identifier);
                save('deleting');
            }
            if (readyProof) {
                readySourceProof(current(journal.installed)); save('complete');
            } else { journal.beforeAdd = trackedImages().map(value => value.identifier); save('adding'); }
        }
        if (journal.phase === 'adding') {
            inventory = trackedImages();
            let added = inventory.filter(image => !journal.beforeAdd.includes(image.identifier));
            if (!added.length) {
                check(inventory.length === journal.beforeAdd.length && !inventory.some(matches),
                    'The runtime inventory changed before import; preserve it for inspection.');
                checkSpace(sourcePath);
                sourceValid(); journal.addAttempted = true; save('adding');
                invoke(['runtime', 'add', sourcePath]);
                added = trackedImages().filter(image => !journal.beforeAdd.includes(image.identifier));
            }
            check(journal.addAttempted === true && added.length === 1 && ordinary(added[0]) && added[0].state === 'Ready' &&
                added[0].signatureState === 'Verified' && same(runtimeFileDigest(added[0].path), journal.source) &&
                verify(added[0]).status === 'verified', 'The replacement runtime did not reach exact verified readiness.');
            profile(added[0], true); journal.installed = bound(added[0]); save('complete');
        }
        const finalImages = images();
        check(finalImages.filter(matches).length === 1, 'Expected only the verified replacement for this runtime pin.');
        const installed = current(journal.installed, finalImages);
        check(installed && installed.state === 'Ready' && installed.signatureState === 'Verified' &&
            same(runtimeFileDigest(installed.path), journal.source) && verify(installed).status === 'verified',
            'The recorded replacement runtime is no longer verified and available.');
        console.log(`Verified repaired ${wanted.platform} ${wanted.version} (${wanted.buildVersion}); receipt ${journalPath}.`);
        return profile(installed, true);
    }

    function prepareLocalProvisioningDirectory(buildRoot, vmId) {
        check(buildRoot === '/Volumes/BigWalletBuild', 'Local provisioning requires the managed build volume.');
        check(typeof vmId === 'string' && /^[A-Za-z0-9_-]+$/.test(vmId), 'Local provisioning requires a valid VM identity.');
        const parent = path.join(buildRoot, 'Provisioning');
        fs.mkdirSync(parent, {recursive: true, mode: 0o700});
        const metadata = fs.lstatSync(parent);
        check(metadata.isDirectory() && !metadata.isSymbolicLink() && metadata.uid === 0 && fs.realpathSync(parent) === parent,
            'The local provisioning parent must be a real root-owned directory.');
        fs.chmodSync(parent, 0o700);
        let removed = 0;
        for (const entry of fs.readdirSync(parent, {withFileTypes: true})) {
            if (removed >= 32) break;
            if (!entry.isDirectory() || !/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(entry.name)) continue;
            const directory = path.join(parent, entry.name);
            const marker = path.join(directory, '.big-wallet-provisioning.json');
            try {
                const directoryMetadata = fs.lstatSync(directory);
                const markerMetadata = fs.lstatSync(marker);
                if (!directoryMetadata.isDirectory() || directoryMetadata.isSymbolicLink() || directoryMetadata.uid !== 0 ||
                    (directoryMetadata.mode & 0o7777) !== 0o700 || !markerMetadata.isFile() || markerMetadata.isSymbolicLink() ||
                    markerMetadata.uid !== 0 || (markerMetadata.mode & 0o7777) !== 0o600 || markerMetadata.size > 4096) continue;
                const identity = JSON.parse(fs.readFileSync(marker, 'utf8'));
                if (identity.version !== 1 || identity.vmId !== vmId) continue;
            } catch { continue; }
            fs.rmSync(directory, {recursive: true});
            removed += 1;
        }
        const directory = path.join(parent, crypto.randomUUID());
        fs.mkdirSync(directory, {mode: 0o700});
        const provision = path.join(directory, 'provision');
        fs.mkdirSync(provision, {mode: 0o700});
        writeJSON(path.join(directory, '.big-wallet-provisioning.json'), {version: 1, vmId}, 0o600);
        return provision;
    }
    function prepareLocalExchange(buildRoot) {
        check(buildRoot === '/Volumes/BigWalletBuild' && exchange === path.join(buildRoot, 'Exchange'),
            'The local exchange requires the managed build volume.');
        const parent = fs.lstatSync(buildRoot);
        check(parent.isDirectory() && !parent.isSymbolicLink() && parent.uid === 0 && (parent.mode & 0o022) === 0 &&
            fs.realpathSync(buildRoot) === buildRoot, 'The local exchange parent must be a protected root-owned directory.');
        const existing = fs.lstatSync(exchange, {throwIfNoEntry: false});
        if (!existing) fs.mkdirSync(exchange, {mode: 0o700});
        const metadata = fs.lstatSync(exchange);
        check(metadata.isDirectory() && !metadata.isSymbolicLink() && [0, uid].includes(metadata.uid) &&
            (metadata.mode & 0o077) === 0 && fs.realpathSync(exchange) === exchange,
            'The local exchange must be a private directory owned by root or the selected guest account.');
        fs.chmodSync(exchange, 0o700);
        setOwnershipIfNeeded(exchange, uid, gid);
    }
    function removeLocalProvisioningInput(filename, directory, vmId) {
        check(/^\/Volumes\/BigWalletBuild\/Provisioning\/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\/provision$/.test(directory) &&
            fs.realpathSync(directory) === directory && path.dirname(filename) === directory,
            'Only managed local provisioning inputs may be removed.');
        for (const parent of [directory, path.dirname(directory), path.dirname(path.dirname(directory))]) {
            const metadata = fs.lstatSync(parent);
            check(metadata.isDirectory() && !metadata.isSymbolicLink() && metadata.uid === 0 && (metadata.mode & 0o077) === 0,
                'Local provisioning inputs must remain in protected root-owned directories.');
        }
        const marker = path.join(path.dirname(directory), '.big-wallet-provisioning.json');
        const markerMetadata = fs.lstatSync(marker);
        check(markerMetadata.isFile() && !markerMetadata.isSymbolicLink() && markerMetadata.uid === 0 &&
            (markerMetadata.mode & 0o7777) === 0o600 && markerMetadata.size <= 4096, 'The local provisioning identity must be protected.');
        const identity = JSON.parse(fs.readFileSync(marker, 'utf8'));
        check(identity.version === 1 && identity.vmId === vmId, 'The local provisioning inputs belong to another VM.');
        const metadata = fs.lstatSync(filename);
        check(metadata.isFile() && !metadata.isSymbolicLink() && metadata.uid === 0, 'Only root-owned local provisioning files may be removed.');
        fs.rmSync(filename);
    }
    function diskMetadata(args) {
        const xml = run('Inspect guest APFS layout', '/usr/sbin/diskutil', args);
        return JSON.parse(run('Decode disk metadata', '/usr/bin/plutil', ['-convert', 'json', '-o', '-', '-'], {input: xml}));
    }

    function syncDirectory(directory) {
        const descriptor = fs.openSync(directory, 'r');
        try { fs.fsyncSync(descriptor); }
        finally { fs.closeSync(descriptor); }
    }
    function writeDurableJSON(filename, value, mode) {
        const temporary = `${filename}.${crypto.randomUUID()}.tmp`;
        try {
            const descriptor = fs.openSync(temporary, 'wx', mode);
            try {
                fs.writeFileSync(descriptor, JSON.stringify(value) + '\n');
                fs.fchmodSync(descriptor, mode);
                fs.fchownSync(descriptor, 0, 20);
                fs.fsyncSync(descriptor);
            } finally { fs.closeSync(descriptor); }
            fs.renameSync(temporary, filename);
            syncDirectory(path.dirname(filename));
        } finally { fs.rmSync(temporary, {force: true}); }
    }
    function readBuildInitializationIntent(filename) {
        const parent = fs.lstatSync(path.dirname(filename));
        check(parent.isDirectory() && !parent.isSymbolicLink() && parent.uid === 0 && (parent.mode & 0o022) === 0 &&
            fs.realpathSync(path.dirname(filename)) === path.dirname(filename), 'Build initialization state must be protected and root-owned.');
        const metadata = fs.lstatSync(filename, {throwIfNoEntry: false});
        if (!metadata) return null;
        check(metadata.isFile() && !metadata.isSymbolicLink() && metadata.uid === 0 &&
            (metadata.mode & 0o7777) === 0o600 && metadata.size <= 4096, 'The build initialization intent must be a private root-owned file.');
        const intent = JSON.parse(fs.readFileSync(filename, 'utf8'));
        const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
        check(intent?.version === 1 && intent.vmId === config.vmId && intent.bytes === config.buildData.bytes &&
            Object.keys(intent).every(key => ['version', 'vmId', 'bytes', 'nonce', 'volumeUUID'].includes(key)) &&
            typeof intent.nonce === 'string' && uuid.test(intent.nonce) &&
            (intent.volumeUUID === undefined || typeof intent.volumeUUID === 'string' && uuid.test(intent.volumeUUID)),
            'The build initialization intent is invalid or belongs to another VM.');
        return intent;
    }
    function verifyBuildIdentity(directory, volumeUUID) {
        const marker = path.join(directory, '.big-wallet-vm.json');
        const metadata = fs.lstatSync(marker, {throwIfNoEntry: false});
        check(metadata, 'Existing BigWalletBuild has no managed-volume identity; it will not be reformatted or adopted automatically.');
        check(metadata.isFile() && !metadata.isSymbolicLink() && metadata.uid === 0 && (metadata.mode & 0o022) === 0 &&
            metadata.size <= 4096, 'The build-volume identity must be a protected root-owned file.');
        const identity = JSON.parse(fs.readFileSync(marker, 'utf8'));
        check(identity.version === 1 && identity.vmId === config.vmId && identity.volumeUUID === volumeUUID,
            'The existing build-data volume belongs to another VM.');
    }
    function prepareBuildData() {
        check(config.buildData?.bytes === 103_079_215_104 && config.buildData?.volumeName === 'BigWalletBuild',
            'Build storage must be the managed 96 GiB BigWalletBuild sidecar.');
        const root = diskMetadata(['info', '-plist', '/']);
        check(Array.isArray(root.APFSPhysicalStores) && root.APFSPhysicalStores.length === 1, 'The guest boot disk could not be identified safely.');
        const bootStore = root.APFSPhysicalStores[0].APFSPhysicalStore;
        check(/^disk\d+s\d+$/.test(bootStore), 'The guest boot physical store is invalid.');
        const bootDisk = diskMetadata(['info', '-plist', bootStore]).ParentWholeDisk;
        check(/^disk\d+$/.test(bootDisk), 'The guest boot disk is invalid.');
        function allVolumes() {
            return diskMetadata(['apfs', 'list', '-plist']).Containers.flatMap(container =>
                container.Volumes.map(volume => ({container, volume})));
        }
        const intentPath = path.join(state, 'build-data-initialization.json');
        let intent = readBuildInitializationIntent(intentPath);
        let temporaryName = intent ? `BigWalletInit-${intent.nonce}` : null;
        const selectVolume = () => {
            const volumes = allVolumes();
            const final = volumes.filter(({volume}) => volume.Name === 'BigWalletBuild');
            check(final.length <= 1, 'More than one BigWalletBuild volume exists; disconnect unrelated volumes before setup.');
            if (!intent) return final[0];
            const owned = volumes.filter(({volume}) => volume.Name === temporaryName ||
                intent.volumeUUID !== undefined && volume.APFSVolumeUUID === intent.volumeUUID);
            check(owned.length <= 1 && (!intent.volumeUUID || owned.length === 1 && owned[0].volume.APFSVolumeUUID === intent.volumeUUID),
                'The pending build volume is missing, changed, or ambiguous; all disks were preserved.');
            check(final.every(entry => owned.includes(entry)), 'An unrelated BigWalletBuild volume conflicts with pending initialization.');
            return owned[0];
        };
        let selected = selectVolume();
        if (!selected) {
            const disks = diskMetadata(['list', '-plist', 'physical']).AllDisksAndPartitions;
            const disk = selectBlankBuildDisk(disks, bootDisk, config.buildData.bytes, config.initializeBuildData);
            const details = diskMetadata(['info', '-plist', disk]);
            check(details.WholeDisk === true && details.TotalSize === config.buildData.bytes && !details.FilesystemType,
                'The managed build-data disk is not an unformatted whole disk.');
            const descriptor = fs.openSync(`/dev/r${disk}`, 'r');
            const samples = [];
            try {
                for (const offset of [0, config.buildData.bytes - 1024 * 1024]) {
                    const bytes = Buffer.alloc(1024 * 1024);
                    const count = fs.readSync(descriptor, bytes, 0, bytes.length, offset);
                    samples.push(bytes.subarray(0, count));
                }
            } finally { fs.closeSync(descriptor); }
            validateBlankBuildDisk(details, samples, config.buildData.bytes);
            intent ??= {version: 1, vmId: config.vmId, bytes: config.buildData.bytes, nonce: crypto.randomUUID()};
            temporaryName = `BigWalletInit-${intent.nonce}`;
            writeDurableJSON(intentPath, intent, 0o600);
            console.log('Initializing only the newly staged blank build-data sidecar; the boot disk and Recovery are preserved.');
            run('Initialize managed build-data sidecar', '/usr/sbin/diskutil', ['eraseDisk', 'APFS', temporaryName, 'GPT', disk]);
            selected = selectVolume();
        }
        check(selected, 'The managed APFS build volume was not found.');
        const {container, volume} = selected;
        check(container.PhysicalStores.length === 1 && /^disk\d+s\d+$/.test(container.PhysicalStores[0].DeviceIdentifier),
            'The build volume must have one physical store.');
        const whole = diskMetadata(['info', '-plist', container.PhysicalStores[0].DeviceIdentifier]).ParentWholeDisk;
        check(/^disk\d+$/.test(whole) && whole !== bootDisk && diskMetadata(['info', '-plist', whole]).TotalSize === config.buildData.bytes,
            'The build volume is not on the managed nonboot 96 GiB sidecar.');
        check(/^disk\d+s\d+$/.test(volume.DeviceIdentifier), 'The build APFS volume identifier is invalid.');
        check(typeof volume.APFSVolumeUUID === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(volume.APFSVolumeUUID),
            'The build APFS volume identity is invalid.');
        if (intent && !intent.volumeUUID) {
            intent.volumeUUID = volume.APFSVolumeUUID;
            writeDurableJSON(intentPath, intent, 0o600);
        }
        run('Mount guest build storage', '/usr/sbin/diskutil', ['mount', volume.DeviceIdentifier]);
        let details = diskMetadata(['info', '-plist', volume.DeviceIdentifier]);
        let directory = details.MountPoint;
        check(directory === '/Volumes/BigWalletBuild' || intent && directory === `/Volumes/${temporaryName}`,
            'The managed build volume has an unexpected mountpoint; all disks were preserved.');
        check(fs.realpathSync(directory) === directory, 'The build mountpoint must be a real directory.');
        run('Enable ownership on managed build storage', '/usr/sbin/diskutil', ['enableOwnership', volume.DeviceIdentifier]);
        if (intent) {
            const marker = path.join(directory, '.big-wallet-vm.json');
            if (fs.lstatSync(marker, {throwIfNoEntry: false})) verifyBuildIdentity(directory, volume.APFSVolumeUUID);
            protectBuildVolumeRoot(directory, temporaryName);
            writeDurableJSON(marker, {version: 1, vmId: config.vmId, volumeUUID: volume.APFSVolumeUUID}, 0o644);
            if (volume.Name !== 'BigWalletBuild' || directory !== '/Volumes/BigWalletBuild') {
                run('Name the verified build volume', '/usr/sbin/diskutil', ['renameVolume', volume.DeviceIdentifier, 'BigWalletBuild']);
                run('Remount verified build storage', '/usr/sbin/diskutil', ['unmount', volume.DeviceIdentifier]);
                run('Mount verified build storage', '/usr/sbin/diskutil', ['mount', volume.DeviceIdentifier]);
                details = diskMetadata(['info', '-plist', volume.DeviceIdentifier]);
                directory = details.MountPoint;
            }
            const final = selectVolume();
            check(final?.volume.Name === 'BigWalletBuild' && final.volume.APFSVolumeUUID === intent.volumeUUID &&
                directory === '/Volumes/BigWalletBuild' && fs.realpathSync(directory) === directory,
                'The initialized build volume did not reach its final identity and mountpoint.');
        }
        verifyBuildIdentity(directory, volume.APFSVolumeUUID);
        protectBuildVolumeRoot(directory);
        if (intent) {
            fs.unlinkSync(intentPath);
            syncDirectory(state);
        }
        return directory;
    }
    function protectBuildVolumeRoot(directory, temporaryName) {
        check(directory === '/Volumes/BigWalletBuild' || typeof temporaryName === 'string' &&
            /^BigWalletInit-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(temporaryName) &&
            directory === `/Volumes/${temporaryName}`, 'Only the managed build-volume root may be protected.');
        const metadata = fs.lstatSync(directory);
        check(metadata.isDirectory() && !metadata.isSymbolicLink() && metadata.uid === 0 && fs.realpathSync(directory) === directory,
            'The managed build-volume root must be a real root-owned directory.');
        if ((metadata.mode & 0o7777) !== 0o755) fs.chmodSync(directory, 0o755);
    }
    function setOwnershipIfNeeded(filename, owner, group) {
        const metadata = fs.statSync(filename);
        if (metadata.uid !== owner || metadata.gid !== group) fs.chownSync(filename, owner, group);
    }
    function relocationFileID(filename) {
        const metadata = fs.lstatSync(filename, {bigint: true, throwIfNoEntry: false});
        return metadata ? `${metadata.dev}:${metadata.ino}` : null;
    }
    function relocationIntentPath(source, destination) {
        const identifier = crypto.createHash('sha256').update(`${source}\0${destination}`).digest('hex');
        return path.join(state, `relocation-${identifier}.json`);
    }
    function requireIdleRelocationTree(directory) {
        const result = spawnSync('/usr/sbin/lsof', ['-nP', '-t', '+w', '+D', directory, '-x', 'f'], {
            encoding: 'utf8', env: environment, timeout: 60000, killSignal: 'SIGKILL', maxBuffer: 1024 * 1024,
        });
        check(!result.error && [0, 1].includes(result.status) && !result.stderr.trim(),
            'Could not verify that retired guest development data is idle; all directories were preserved.');
        check(!result.stdout.trim(), 'Guest processes still have retired development data open; all directories were preserved.');
    }
    function relocateDirectory(source, destination, owner, group, verifiedDestination = false) {
        check(path.isAbsolute(source) && path.resolve(source) === source && path.isAbsolute(destination) && path.resolve(destination) === destination,
            'Relocation requires canonical absolute paths.');
        fs.mkdirSync(path.dirname(destination), {recursive: true});
        fs.mkdirSync(path.dirname(source), {recursive: true});
        if (owner !== 0) setOwnershipIfNeeded(path.dirname(source), owner, group);
        for (const parent of [state, path.dirname(source), path.dirname(destination)]) {
            check(fs.realpathSync(parent) === parent, 'Relocation parents must not traverse symlinks.');
        }
        if (verifiedDestination) {
            const target = fs.lstatSync(destination, {throwIfNoEntry: false});
            check(target?.isDirectory() && !target.isSymbolicLink() && fs.realpathSync(destination) === destination,
                'The verified application destination must remain a real directory.');
        }
        const intentPath = relocationIntentPath(source, destination);
        const recordMetadata = fs.lstatSync(intentPath, {throwIfNoEntry: false});
        let intent;
        if (recordMetadata) {
            check(recordMetadata.isFile() && !recordMetadata.isSymbolicLink() && recordMetadata.uid === 0 &&
                (recordMetadata.mode & 0o7777) === 0o600 && recordMetadata.size <= 8192, 'Relocation intent must be a private root-owned file.');
            intent = JSON.parse(fs.readFileSync(intentPath, 'utf8'));
            check(intent.version === 1 && intent.vmId === config.vmId && intent.source === source && intent.destination === destination &&
                intent.owner === owner && intent.group === group && typeof intent.ready === 'boolean' &&
                /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(intent.nonce) &&
                (intent.sourceID === null || typeof intent.sourceID === 'string' && /^\d+:\d+$/.test(intent.sourceID)) &&
                (intent.sourceID === null ? intent.retiredParentID === null :
                    typeof intent.retiredParentID === 'string' && /^\d+:\d+$/.test(intent.retiredParentID)) &&
                (intent.sourceID === null ? [intent.sourceUID, intent.sourceGID, intent.sourceMode].every(value => value === null) :
                    [intent.sourceUID, intent.sourceGID, intent.sourceMode].every(value => Number.isSafeInteger(value) && value >= 0) && intent.sourceMode <= 0o7777) &&
                typeof intent.treeID === 'string' && /^\d+:\d+$/.test(intent.treeID), 'Relocation intent does not match these directories.');
        }
        const linked = () => fs.lstatSync(source, {throwIfNoEntry: false})?.isSymbolicLink() &&
            path.resolve(path.dirname(source), fs.readlinkSync(source)) === destination;
        if (!intent && verifiedDestination && !linked()) {
            const original = fs.lstatSync(source, {throwIfNoEntry: false});
            const preserved = path.join('/Volumes/BigWalletBuild/Preserved', `${path.basename(source)}-${path.basename(intentPath, '.json')}`);
            if (original?.isDirectory() || fs.lstatSync(relocationIntentPath(source, preserved), {throwIfNoEntry: false})) {
                relocateDirectory(source, preserved, owner, group);
            } else if (original?.isSymbolicLink()) {
                const target = path.resolve(path.dirname(source), fs.readlinkSync(source));
                fs.mkdirSync(path.dirname(preserved), {recursive: true});
                const parent = fs.lstatSync(path.dirname(preserved));
                check(parent.isDirectory() && !parent.isSymbolicLink() && parent.uid === 0 && (parent.mode & 0o022) === 0 &&
                    fs.realpathSync(path.dirname(preserved)) === path.dirname(preserved), 'The preserved application parent must be protected and real.');
                const previous = fs.lstatSync(preserved, {throwIfNoEntry: false});
                check(!previous || target === preserved && previous.isDirectory() || previous.isSymbolicLink() && fs.readlinkSync(preserved) === target,
                    'The preserved application path already contains unrelated data.');
                check(target !== preserved || previous?.isDirectory(), 'The preserved application directory is missing.');
                if (!previous) fs.symlinkSync(target, preserved);
                syncDirectory(path.dirname(preserved));
            }
        }
        if (!intent && linked()) {
            const target = fs.lstatSync(destination, {throwIfNoEntry: false});
            check(!target || target.isDirectory() && !target.isSymbolicLink() && fs.realpathSync(destination) === destination,
                'The existing relocation target must be a real directory.');
            fs.mkdirSync(destination, {recursive: true, mode: 0o755});
            setOwnershipIfNeeded(destination, owner, group);
            return;
        }
        if (!intent) {
            const original = fs.lstatSync(source, {throwIfNoEntry: false});
            const target = fs.lstatSync(destination, {throwIfNoEntry: false});
            check(!original || original.isDirectory() || verifiedDestination && original.isSymbolicLink(), 'Relocation source is not a directory.');
            check(!target || verifiedDestination && target.isDirectory() && !target.isSymbolicLink(),
                'An unrecorded relocation destination already exists; both directories were preserved.');
            const nonce = crypto.randomUUID();
            const incoming = `${destination}.${nonce}.incoming`;
            const retiredParent = `${source}.${nonce}.previous`;
            if (!target) {
                fs.mkdirSync(incoming, {mode: 0o700});
                syncDirectory(incoming);
                syncDirectory(path.dirname(incoming));
            }
            if (original) {
                fs.mkdirSync(retiredParent, {mode: 0o700});
                fs.chownSync(retiredParent, 0, 0);
                run('Protect retired guest development data', '/bin/chmod', ['-N', retiredParent]);
                syncDirectory(retiredParent);
                syncDirectory(path.dirname(retiredParent));
            }
            intent = {version: 1, vmId: config.vmId, source, destination, owner, group, nonce,
                sourceID: original ? relocationFileID(source) : null,
                sourceUID: original?.uid ?? null, sourceGID: original?.gid ?? null, sourceMode: original ? original.mode & 0o7777 : null,
                retiredParentID: original ? relocationFileID(retiredParent) : null,
                treeID: relocationFileID(target ? destination : incoming), ready: Boolean(target || !original)};
            try { writeDurableJSON(intentPath, intent, 0o600); }
            catch (error) {
                if (!fs.lstatSync(intentPath, {throwIfNoEntry: false})) {
                    for (const [directory, identifier] of [[retiredParent, intent.retiredParentID], [incoming, target ? null : intent.treeID]]) {
                        if (identifier && relocationFileID(directory) === identifier && !fs.readdirSync(directory).length) {
                            fs.rmdirSync(directory);
                            syncDirectory(path.dirname(directory));
                        }
                    }
                }
                throw error;
            }
        }
        const incoming = `${destination}.${intent.nonce}.incoming`;
        const retiredParent = `${source}.${intent.nonce}.previous`;
        const retired = path.join(retiredParent, path.basename(source));
        const matchesTree = filename => fs.lstatSync(filename, {throwIfNoEntry: false})?.isDirectory() && relocationFileID(filename) === intent.treeID;
        const matchesSource = filename => {
            const metadata = fs.lstatSync(filename, {throwIfNoEntry: false});
            return metadata && (metadata.isDirectory() || verifiedDestination && metadata.isSymbolicLink()) &&
                relocationFileID(filename) === intent.sourceID && metadata.uid === intent.sourceUID && metadata.gid === intent.sourceGID &&
                (metadata.mode & 0o7777) === intent.sourceMode;
        };
        const retiredParentMetadata = fs.lstatSync(retiredParent, {throwIfNoEntry: false});
        if (retiredParentMetadata) {
            check(retiredParentMetadata.isDirectory() && !retiredParentMetadata.isSymbolicLink() && retiredParentMetadata.uid === 0 &&
                (retiredParentMetadata.mode & 0o7777) === 0o700 && fs.realpathSync(retiredParent) === retiredParent &&
                relocationFileID(retiredParent) === intent.retiredParentID, 'The protected relocation directory changed; all directories were preserved.');
        } else {
            check(intent.sourceID === null || intent.ready && linked() && matchesTree(destination),
                'The protected relocation directory is missing; all directories were preserved.');
        }
        check(!fs.lstatSync(destination, {throwIfNoEntry: false}) || intent.ready && matchesTree(destination),
            'Relocation destination changed; all directories were preserved.');
        if (!linked()) {
            const original = fs.lstatSync(source, {throwIfNoEntry: false});
            if (original) {
                check((!intent.ready || verifiedDestination) && matchesSource(source) &&
                    !fs.lstatSync(retired, {throwIfNoEntry: false}), 'Relocation source changed or was recreated; all directories were preserved.');
                if (original.isDirectory()) requireIdleRelocationTree(source);
                fs.renameSync(source, retired);
                syncDirectory(retiredParent);
                syncDirectory(path.dirname(source));
            } else {
                check(intent.sourceID === null || matchesSource(retired), 'The original relocation directory is missing or changed.');
            }
        }
        if (!intent.ready) {
            check(matchesSource(retired) && matchesTree(incoming), 'The pending relocation directories changed.');
            requireIdleRelocationTree(retired);
            for (const entry of fs.readdirSync(incoming)) fs.rmSync(path.join(incoming, entry), {recursive: true});
            run('Copy existing guest development data to the sidecar', '/bin/cp', ['-pRP', `${retired}/.`, incoming]);
            run('Flush completed guest development copy', '/bin/sync', []);
            intent.ready = true;
            writeDurableJSON(intentPath, intent, 0o600);
        }
        if (!fs.lstatSync(destination, {throwIfNoEntry: false})) {
            check(matchesTree(incoming), 'The completed relocation copy is missing or changed.');
            fs.renameSync(incoming, destination);
            syncDirectory(path.dirname(destination));
        }
        setOwnershipIfNeeded(destination, owner, group);
        syncDirectory(destination);
        if (!linked()) {
            check(!fs.lstatSync(source, {throwIfNoEntry: false}), 'Relocation source was recreated; all directories were preserved.');
            fs.symlinkSync(destination, source);
            syncDirectory(path.dirname(source));
        }
        check(linked() && matchesTree(destination), 'The relocated directory did not reach its final identity.');
        if (fs.lstatSync(retired, {throwIfNoEntry: false})) {
            check(intent.sourceID !== null && matchesSource(retired), 'The retired directory changed; it was preserved.');
            if (fs.lstatSync(retired).isDirectory()) requireIdleRelocationTree(retired);
            fs.rmSync(retired, {recursive: true});
            syncDirectory(retiredParent);
        }
        if (fs.lstatSync(retiredParent, {throwIfNoEntry: false})) {
            fs.rmdirSync(retiredParent);
            syncDirectory(path.dirname(retiredParent));
        }
        fs.unlinkSync(intentPath);
        syncDirectory(state);
    }
    function ensureUserDeveloperDirectories(userHome, owner, group) {
        let directory = userHome;
        for (const component of ['Library', 'Developer', 'Xcode']) {
            directory = path.join(directory, component);
            let metadata;
            try { metadata = fs.lstatSync(directory); }
            catch (error) { if (error.code !== 'ENOENT') throw error; }
            if (!metadata) {
                fs.mkdirSync(directory, {mode: 0o755});
                metadata = fs.lstatSync(directory);
            }
            if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
                throw new Error(`The selected user's developer directory is not a regular directory: ${directory}`);
            }
            fs.chownSync(directory, owner, group);
        }
    }

    function runtimeArtifactBytes(filename) {
        check(path.isAbsolute(filename) && path.resolve(filename) === filename && fs.realpathSync(filename) === filename,
            'Runtime artifacts must use canonical paths without symlinks.');
        const root = fs.lstatSync(filename);
        const bundle = root.isDirectory() && /\.export(?:ed)?Bundle$/.test(filename);
        check(bundle || root.isFile() && filename.endsWith('.dmg'), 'A runtime artifact must be a complete exported bundle or a standalone DMG.');
        let bytes = 0, entries = 0, images = 0, metadataBytes = 0;
        function visit(current, depth) {
            check(depth <= 16 && ++entries <= 8192, 'The runtime artifact exceeds its bounded inspection limit.');
            const value = fs.lstatSync(current);
            check(!value.isSymbolicLink() && (value.isFile() || value.isDirectory()) && value.dev === root.dev,
                'Runtime artifacts must contain only regular files and directories on the same filesystem.');
            if (value.isDirectory()) {
                check(current === filename || !/\.export(?:ed)?Bundle$/.test(current), 'Nested runtime export bundles are ambiguous.');
                for (const entry of fs.readdirSync(current)) visit(path.join(current, entry), depth + 1);
            } else {
                check(Number.isSafeInteger(value.size) && value.size >= 0, 'The runtime artifact contains an invalid file size.');
                bytes += value.size;
                check(Number.isSafeInteger(bytes) && bytes <= 128 * 1024 ** 3, 'The runtime artifact exceeds its bounded byte limit.');
                if (current.endsWith('.dmg')) {
                    check(value.size > 0, 'The runtime artifact contains an empty disk image.');
                    images += 1;
                } else {
                    metadataBytes += value.size;
                }
            }
        }
        visit(filename, 0);
        check(images > 0 && (!bundle || metadataBytes > 0), 'The exported runtime bundle is incomplete; retain its disk image and metadata together.');
        return bytes;
    }
    function runtimeStorageCheckpoint(buildRoot, platform, stagedRuntime, releaseSpace) {
        const root = fs.statfsSync('/System/Volumes/Data');
        const build = fs.statfsSync(buildRoot);
        const available = root.bavail * root.bsize;
        const buildAvailable = build.bavail * build.bsize;
        const required = runtimeRootSpaceRequirement(stagedRuntime ? runtimeArtifactBytes(stagedRuntime) : undefined);
        check(Number.isSafeInteger(available) && Number.isSafeInteger(buildAvailable), 'Guest filesystem capacity could not be measured.');
        const gib = bytes => (bytes / 1024 ** 3).toFixed(1);
        console.log(`Guest storage before ${platform} ${stagedRuntime ? 'import' : 'download'}: system Data ${gib(available)} GiB free of ${gib(root.blocks * root.bsize)} GiB; build data ${gib(buildAvailable)} GiB free of ${gib(build.blocks * build.bsize)} GiB. Required system headroom: ${gib(required)} GiB.`);
        if ((available < required || !stagedRuntime && buildAvailable < 16 * 1024 ** 3) && releaseSpace?.()) {
            return runtimeStorageCheckpoint(buildRoot, platform, stagedRuntime, releaseSpace);
        }
        check(available >= required, `Insufficient guest system-volume space for ${platform}: ${gib(available)} GiB free, ${gib(required)} GiB required. Preserve Apple's system runtime directories; free guest system space or supply a staged runtime image before retrying.`);
        if (!stagedRuntime) check(buildAvailable >= 16 * 1024 ** 3, 'The build-data volume needs at least 16 GiB free to stage a simulator runtime download.');
    }
    function reclaimRuntimePreparationSpace(directory, releaseSpace) {
        if (!releaseSpace) return;
        const {bavail, bsize} = fs.statfsSync(directory);
        const available = bavail * bsize;
        check(Number.isSafeInteger(available) && available >= 0, 'Guest filesystem capacity could not be measured.');
        if (available < 8 * 1024 ** 3 && releaseSpace()) {
            console.log(`Reclaimed a superseded runtime after measuring ${(available / 1024 ** 3).toFixed(1)} GiB free on ${directory}.`);
            reclaimRuntimePreparationSpace(directory, releaseSpace);
        }
    }
    function exportedRuntimeImage(directory) {
        check(path.isAbsolute(directory) && path.resolve(directory) === directory && fs.realpathSync(directory) === directory,
            'Runtime exports must use a canonical directory without symlinks.');
        const artifacts = [];
        let entries = 0;
        function visit(current, depth) {
            check(depth <= 4 && ++entries <= 8192, 'Runtime export discovery exceeds its bounded inspection limit.');
            const value = fs.lstatSync(current);
            check(!value.isSymbolicLink() && (value.isFile() || value.isDirectory()), 'Runtime exports may not contain symlinks or special files.');
            if (/\.export(?:ed)?Bundle$/.test(current) || current.endsWith('.dmg')) {
                check(artifacts.length === 0, 'Xcode did not export exactly one complete simulator runtime artifact; inspect the guest RuntimeDownloads directory before retrying.');
                runtimeArtifactBytes(current);
                artifacts.push(current);
                return;
            }
            if (value.isDirectory()) for (const entry of fs.readdirSync(current)) visit(path.join(current, entry), depth + 1);
        }
        visit(directory, 0);
        check(artifacts.length === 1, 'Xcode did not export exactly one complete simulator runtime artifact; inspect the guest RuntimeDownloads directory before retrying.');
        return artifacts[0];
    }

    function importSigningIdentity(filename, keychainPath, password) {
        const descriptor = fs.openSync(filename, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
        try {
            const metadata = fs.fstatSync(descriptor);
            check(metadata.isFile() && metadata.uid === 0 && (metadata.mode & 0o077) === 0,
                'The staged development identity must remain a private root-owned file.');
            run('Import the explicit guest development identity', '/usr/bin/security',
                ['import', '/dev/stdin', '-f', 'pkcs12', '-k', keychainPath, '-P', password, '-T', '/usr/bin/codesign', '-T', '/usr/bin/security'],
                {user: true, secret: true, inputFD: descriptor});
        } finally { fs.closeSync(descriptor); }
    }

    function provisionGuest() {
        check(config.version === 1, 'Unsupported configuration version.');
        appliedProvisioningRequest(config, undefined, []);
        check(config.autologin === undefined || (config.autologin && typeof config.autologin === 'object' && !Array.isArray(config.autologin)),
            'Automatic login configuration must be an object.');
        check(config.xcode && typeof config.xcode === 'object', 'Pinned Xcode metadata is required.');
        text(config.xcode.version, 'xcode.version');
        text(config.xcode.buildVersion, 'xcode.buildVersion');
        check(Array.isArray(config.runtimes), 'Pinned iOS and visionOS runtimes are required.');
        check(config.runtimes.length === 2 && new Set(config.runtimes.map(runtime => runtime.platform)).size === 2 &&
            config.runtimes.every(runtime => ['iOS', 'visionOS'].includes(runtime.platform)), 'Supply one iOS and one visionOS runtime.');
        for (const runtime of config.runtimes) {
            text(runtime.version, 'runtime.version');
            text(runtime.buildVersion, 'runtime.buildVersion');
        }
        const userHome = run('Read selected account', '/usr/bin/dscl', ['.', '-read', `/Users/${config.consoleUser}`, 'NFSHomeDirectory']).replace(/^NFSHomeDirectory:\s*/, '');
        check(path.isAbsolute(userHome) && fs.statSync(userHome).isDirectory(), 'Selected account has no usable home directory.');
        check(run('Read selected groups', '/usr/bin/id', ['-Gn', config.consoleUser]).split(/\s+/).includes('staff'), 'Selected console account must belong to staff.');
        fs.mkdirSync(library, {recursive: true, mode: 0o755});
        const identityPath = prepareGuestState();
        const buildRoot = prepareBuildData();
        const targetXcode = `${buildRoot}/Applications/Xcode.app`;
        const requiresRestart = ensureAutomaticLogin();
        if (mode === '--prepare-storage') return prepareStorage(buildRoot, targetXcode, requiresRestart);
        check(!requiresRestart, 'Automatic login was enabled; restart this guest before full provisioning.');
        waitForSelectedSession();
        prepareLocalExchange(buildRoot);
        const workspacePath = `${buildRoot}/Workspaces/${config.consoleUser}/big-wallet`;
        fs.mkdirSync(path.dirname(workspacePath), {recursive: true, mode: 0o755});
        fs.chownSync(path.dirname(workspacePath), uid, gid);
        ensureUserDeveloperDirectories(userHome, uid, gid);
        relocateDirectory(path.join(userHome, 'Library/Developer/Xcode/DerivedData'), `${buildRoot}/Users/${config.consoleUser}/DerivedData`, uid, gid);
        relocateDirectory(path.join(userHome, 'Library/Developer/CoreSimulator'), `${buildRoot}/Users/${config.consoleUser}/CoreSimulator`, uid, gid);

        fs.mkdirSync(path.dirname(targetXcode), {recursive: true, mode: 0o755});
        if (!matchesXcode(xcodeVersion(targetXcode))) {
            console.log('Verifying and extracting the pinned Xcode archive inside the guest.');
            const incoming = path.join(path.dirname(targetXcode), 'BigWallet-Xcode.incoming.app');
            if (fs.existsSync(incoming)) {
                check(!fs.lstatSync(incoming).isSymbolicLink() && fs.statSync(incoming).uid === 0,
                    'The reserved incoming Xcode path must be a root-owned directory, not a symlink.');
                fs.rmSync(incoming, {recursive: true});
            }
            validateXcodeArchive(config.xcodeArchive);
            const archive = staged(config.xcodeArchive.path, 'xcodeArchive.path');
            extractXcodeArchive(archive, config.xcodeArchive.sha256, incoming);
            check(matchesXcode(xcodeVersion(incoming)), 'Extracted Xcode metadata did not match.');
            removeLocalProvisioningInput(archive, staging, config.vmId);
            if (fs.existsSync(targetXcode)) {
                const backup = path.join(path.dirname(targetXcode), `Xcode.before-big-wallet-${Date.now()}.app`);
                fs.renameSync(targetXcode, backup);
                console.log(`Preserved previous guest Xcode at ${backup}.`);
            }
            fs.renameSync(incoming, targetXcode);
        }
        relocateDirectory('/Applications/Xcode.app', targetXcode, 0, 0, true);
        run('Select guest Xcode', '/usr/bin/xcode-select', ['--switch', developer]);
        run('Accept guest Xcode license', '/usr/bin/xcodebuild', ['-license', 'accept']);
        run('Initialize guest Xcode', '/usr/bin/xcodebuild', ['-runFirstLaunch']);
        configureUIAutomation();

        const previous = loadPreviousProvisioning(userHome);
        const provisioningPath = path.join(state, 'provisioning.json');
        prepareRuntimes(buildRoot, previous);

        const launchDirectory = path.join(userHome, 'Library/LaunchAgents');
        fs.mkdirSync(launchDirectory, {recursive: true, mode: 0o755});
        fs.chownSync(launchDirectory, uid, gid);
        const logDirectory = path.join(userHome, 'Library/Logs/BigWalletTestVM');
        fs.mkdirSync(logDirectory, {recursive: true, mode: 0o700});
        fs.chownSync(logDirectory, uid, gid);
        const agentPlist = path.join(launchDirectory, `${agentLabel}.plist`);
        const agentConfiguration = makeAgentConfiguration({library, agentLabel, environment, developer, logDirectory});
        const optional = prepareSigning(userHome, previous);
        const provisioning = {version: 1, vmId: config.vmId, consoleUser: config.consoleUser,
            appliedProvisioningRequestID: appliedProvisioningRequest(config, previous, optional.appliedCapabilities),
            ...optional.fields, missingSigning: optional.missingSigning, workspacePath, node: config.node, jq: config.jq,
            xcode: config.xcode, runtimes: config.runtimes.map(({platform, version, buildVersion}) => ({platform, version, buildVersion}))};
        const replacements = ['VMGuestAgent', 'guest_runner', 'guest_bootstrap.mjs'].map(filename => ({
            path: `${library}/${filename}`, source: staged(filename, filename), uid: 0, gid: 0,
            mode: filename === 'VMGuestAgent' || filename === 'guest_runner' ? 0o755 : 0o644,
        }));
        for (const [filename, value] of [[identityPath, {version: 1, vmId: config.vmId, consoleUser: config.consoleUser}],
            [provisioningPath, provisioning]]) {
            replacements.push({path: filename, data: JSON.stringify(value, null, 2) + '\n', mode: 0o640, uid: 0, gid: 20});
        }
        replacements.push({path: agentPlist, data: run('Prepare guest agent configuration', '/usr/bin/plutil',
            ['-convert', 'xml1', '-o', '-', '-'], {input: JSON.stringify(agentConfiguration)}) + '\n', mode: 0o644, uid, gid});
        installGuestAgent(replacements, agentPlist);
        console.log(`Guest ${config.vmId} base is ready for ${config.consoleUser}. No account, password, or existing VM installation was reset.`);
        if (optional.missingSigning.length) {
            console.log(`Signed native coverage is unavailable: ${optional.missingSigning.join('; ')}`);
        } else {
            console.log('Signing prerequisites are installed; the test runner must still verify every requested coverage stage.');
        }
    }

    function prepareStorage(buildRoot, targetXcode, requiresRestart) {
        const xcodeInstalled = matchesXcode(xcodeVersion(targetXcode));
        let runtimes = [];
        if (xcodeInstalled && selectedUserSessionReady()) {
            try {
                runtimes = JSON.parse(run('Inspect installed guest runtimes', '/usr/bin/env',
                    [`DEVELOPER_DIR=${targetXcode}/Contents/Developer`, '/usr/bin/xcrun', 'simctl', 'list', 'runtimes', '--json'],
                    {user: true, timeout: 120000, killSignal: 'SIGKILL'})).runtimes;
                check(Array.isArray(runtimes), 'The installed runtime inventory is invalid.');
            } catch { console.log('Existing simulator runtime readiness could not be verified; explicit images will be staged.'); runtimes = []; }
        }
        const requiredInputs = requiredProvisioningInputs(config, xcodeInstalled, runtimes);
        const stagingDirectory = prepareLocalProvisioningDirectory(buildRoot, config.vmId);
        console.log('BIG_WALLET_PROVISIONING_STAGE=' + JSON.stringify({stagingDirectory, requiredInputs,
            ...(requiresRestart ? {requiresRestart: true} : {})}));
        return;
    }

    function loadPreviousProvisioning(userHome) {
        const keychainPath = path.join(userHome, 'Library/Keychains/big-wallet-vm.keychain-db');
        const provisioningPath = path.join(state, 'provisioning.json');
        let previous;
        const metadata = fs.lstatSync(provisioningPath, {throwIfNoEntry: false});
        if (metadata) {
            check(metadata.isFile() && metadata.uid === 0 && (metadata.mode & 0o022) === 0 && metadata.size <= 1024 * 1024,
                'Existing guest provisioning configuration is not a protected root-owned file.');
            try { previous = JSON.parse(fs.readFileSync(provisioningPath, 'utf8')); }
            catch { fail('Existing guest provisioning configuration could not be read.'); }
            check(previous?.version === 1 && previous.vmId === config.vmId && previous.consoleUser === config.consoleUser &&
                (previous.keychainPath === undefined || previous.keychainPath === keychainPath),
                'Existing guest provisioning configuration belongs to a different VM or account.');
            check(Array.isArray(previous.runtimes) && previous.runtimes.length === config.runtimes.length &&
                config.runtimes.every(pin => previous.runtimes.some(old => old?.platform === pin.platform)),
                'Existing guest provisioning is missing its simulator runtime pins.');
            validateRetirementPins(previous.runtimes);
        }
        return previous;
    }

    function prepareRuntimes(buildRoot, previous) {
        let priorRuntimes = previous?.runtimes;
        const same = (a, b) => a.version === b.version && a.buildVersion === b.buildVersion;
        if (config.supersededRuntimes !== undefined) {
            check(previous, 'Source baseline runtime retirement requires a protected same-guest provisioning record.');
            validateRetirementPins(config.supersededRuntimes);
            check(config.supersededRuntimes.every(old => config.runtimes.some(pin => pin.platform === old.platform && !same(pin, old))),
                'The source baseline must identify only superseded runtime pins.');
            priorRuntimes = config.runtimes.map(pin => {
                const recorded = previous.runtimes.find(value => value.platform === pin.platform);
                const baseline = config.supersededRuntimes.find(old => old.platform === pin.platform) ?? pin;
                check(same(recorded, baseline) || same(recorded, pin), 'Guest runtime pins differ from the source baseline and its requested replacement.');
                return baseline;
            });
        }
        validateRetirementPins(config.runtimes);
        const superseded = (priorRuntimes ?? []).filter(old => config.runtimes.some(pin => pin.platform === old.platform && !same(pin, old)));
        const pending = new Map(superseded.map(pin => [pin.platform, pin]));
        function retire(platform) {
            const old = pending.get(platform);
            if (!old) return false;
            const target = config.runtimes.find(pin => pin.platform === platform);
            retireSupersededRuntimes([old], [target], buildRoot);
            pending.delete(platform);
            return true;
        }
        console.log('Verifying pinned guest simulator runtimes.');
        function installedRuntimes() {
            return JSON.parse(run('List guest runtimes', '/usr/bin/xcrun', ['simctl', 'list', 'runtimes', '--json'], {user: true})).runtimes;
        }
        for (const wanted of config.runtimes) {
            if (pending.get(wanted.platform)?.version === wanted.version) retire(wanted.platform);
            const releaseSpace = pending.size ? () => retire(wanted.platform) || retire(pending.keys().next().value) : undefined;
            const retirement = superseded.length ? {pins: superseded, release: releaseSpace} : undefined;
            const matches = runtime => matchesRuntime(runtime, wanted);
            let runtime = verifyOrRepairPinnedRuntime(wanted, buildRoot, 'existing', retirement);
            if (!runtime) {
                if (wanted.dmgPath) {
                    const image = staged(wanted.dmgPath, 'runtime.dmgPath');
                    runtimeStorageCheckpoint(buildRoot, wanted.platform, image, releaseSpace);
                    run(`Import ${wanted.platform} runtime`, '/usr/bin/xcodebuild', ['-importPlatform', image]);
                } else {
                    runtimeStorageCheckpoint(buildRoot, wanted.platform, undefined, releaseSpace);
                    const downloads = path.join(buildRoot, 'RuntimeDownloads', `${wanted.platform}-${wanted.version}-${wanted.buildVersion}`);
                    fs.mkdirSync(downloads, {recursive: true, mode: 0o755});
                    run(`Download ${wanted.platform} ${wanted.version}`, '/usr/bin/xcodebuild',
                        ['-downloadPlatform', wanted.platform, '-exportPath', downloads, '-buildVersion', wanted.buildVersion, '-architectureVariant', 'arm64']);
                    if (!installedRuntimes().some(matches)) {
                        const image = exportedRuntimeImage(downloads);
                        runtimeStorageCheckpoint(buildRoot, wanted.platform, image, releaseSpace);
                        run(`Import ${wanted.platform} runtime`, '/usr/bin/xcodebuild', ['-importPlatform', image]);
                    }
                }
                runtime = verifyOrRepairPinnedRuntime(wanted, buildRoot, 'prepare', retirement);
            }
            reclaimRuntimePreparationSpace('/System/Volumes/Data', releaseSpace);
            prepareRuntimeCache(runtime, wanted);
            if (wanted.dmgPath && fs.existsSync(path.resolve(staging, wanted.dmgPath))) {
                removeLocalProvisioningInput(staged(wanted.dmgPath, 'runtime.dmgPath'), staging, config.vmId);
            }
            const deviceTypes = JSON.parse(run('List simulator device types', '/usr/bin/xcrun', ['simctl', 'list', 'devicetypes', '--json'], {user: true})).devicetypes;
            const name = wanted.platform === 'iOS' ? 'iPhone 18 Pro' : 'Apple Vision Pro';
            const type = deviceTypes.find(type => type.name === name);
            check(type, `The pinned Xcode does not provide the ${name} simulator device type.`);
            const availableDevices = () => JSON.parse(run('List guest simulator devices', '/usr/bin/xcrun', ['simctl', 'list', 'devices', '--json'], {user: true})).devices[runtime.identifier] ?? [];
            if (!availableDevices().some(device => device.isAvailable && device.name === name)) {
                reclaimRuntimePreparationSpace(buildRoot, releaseSpace);
                run(`Create ${name} for the pinned runtime`, '/usr/bin/xcrun', ['simctl', 'create', name, type.identifier, runtime.identifier], {user: true});
            }
            check(availableDevices().some(device => device.isAvailable && device.name === name), `No available ${name} simulator was created.`);
            retire(wanted.platform);
        }
        for (const wanted of config.runtimes) verifyOrRepairPinnedRuntime(wanted, buildRoot, 'verify');
        if (priorRuntimes) retireSupersededRuntimes(priorRuntimes, config.runtimes, buildRoot, true);
    }

    function prepareSigning(userHome, previous) {
        const keychainPath = path.join(userHome, 'Library/Keychains/big-wallet-vm.keychain-db');
        const signing = config.signing;
        check(signing === undefined || (signing && typeof signing === 'object' && !Array.isArray(signing)), 'Signing configuration must be an object.');
        const optional = optionalSigningConfiguration(() => {
            const proofKey = Object.hasOwn(signing ?? {}, 'proofKeyFile') ? secret(signing.proofKeyFile, 'signing.proofKeyFile') : previous?.proofKey;
            check(typeof proofKey === 'string', 'No request-proof key has been supplied.');
            check(/^[A-Za-z0-9_-]{43}$/.test(proofKey) && Buffer.from(proofKey, 'base64url').length === 32 &&
                Buffer.from(proofKey, 'base64url').toString('base64url') === proofKey, 'The request-proof key must be canonical base64url for 32 bytes.');
            const expectedProofDigest = fs.readFileSync(staged('alchemy_jwt_request_proof_key.sha256', 'request-proof fingerprint'), 'utf8').trim();
            check(/^[a-f0-9]{64}$/.test(expectedProofDigest) && crypto.createHash('sha256').update(proofKey).digest('hex') === expectedProofDigest,
                'The request-proof key does not match the repository fingerprint.');
            return {proofKey};
        }, () => {
            let p12, p12Password;
            if (Object.hasOwn(signing ?? {}, 'p12Path') || Object.hasOwn(signing ?? {}, 'p12PasswordFile')) {
                check(signing.p12Path && signing.p12PasswordFile, 'Updating the development identity requires both p12Path and p12PasswordFile.');
                p12 = staged(signing.p12Path, 'signing.p12Path');
                p12Password = secret(signing.p12PasswordFile, 'signing.p12PasswordFile', true);
            }
            const keychainPassword = Object.hasOwn(signing ?? {}, 'keychainPasswordFile') ? secret(signing.keychainPasswordFile, 'signing.keychainPasswordFile') : previous?.keychainPassword;
            check(typeof keychainPassword === 'string' && keychainPassword.length > 0, 'No dedicated guest signing keychain password or development identity has been supplied.');
            check(fs.existsSync(keychainPath) || p12, 'The dedicated guest signing keychain is missing; provide a development identity to create it.');
            const keychainIsNew = !fs.existsSync(keychainPath);
            if (keychainIsNew) {
                run('Create dedicated guest signing keychain', '/usr/bin/security', ['create-keychain', '-p', keychainPassword, keychainPath], {user: true, secret: true});
            }
            run('Unlock dedicated guest signing keychain', '/usr/bin/security', ['unlock-keychain', '-p', keychainPassword, keychainPath], {user: true, secret: true});
            run('Configure dedicated guest signing keychain', '/usr/bin/security', ['set-keychain-settings', '-lut', '21600', keychainPath], {user: true, secret: true});
            if (p12) {
                const p12Hash = crypto.createHash('sha256').update(fs.readFileSync(p12)).digest('hex');
                const importMarker = path.join(state, 'signing-import.sha256');
                if (keychainIsNew || !fs.existsSync(importMarker) || fs.readFileSync(importMarker, 'utf8').trim() !== p12Hash) {
                    importSigningIdentity(p12, keychainPath, p12Password);
                    fs.writeFileSync(importMarker, p12Hash + '\n', {mode: 0o600});
                }
            }
            run('Authorize guest codesign for the dedicated keychain', '/usr/bin/security',
                ['set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', keychainPassword, keychainPath], {user: true, secret: true});
            const keychains = run('Read guest keychain search list', '/usr/bin/security', ['list-keychains', '-d', 'user'], {user: true, secret: true})
                .split('\n').map(value => value.trim().replace(/^"|"$/g, '')).filter(Boolean);
            run('Add dedicated guest signing keychain to search list', '/usr/bin/security',
                ['list-keychains', '-d', 'user', '-s', ...new Set([...keychains, keychainPath])], {user: true, secret: true});
            const identities = run('Verify guest code-signing identity', '/usr/bin/security', ['find-identity', '-v', '-p', 'codesigning', keychainPath], {user: true, secret: true});
            check(/\b[1-9]\d* valid identities found\b/.test(identities), 'No valid code-signing identity is present in the dedicated guest keychain.');
            const profileDirectory = path.join(userHome, 'Library/Developer/Xcode/UserData/Provisioning Profiles');
            fs.mkdirSync(profileDirectory, {recursive: true, mode: 0o700});
            fs.chownSync(path.dirname(profileDirectory), uid, gid);
            fs.chownSync(profileDirectory, uid, gid);
            check(signing?.profiles === undefined || Array.isArray(signing.profiles), 'signing.profiles must be an array of staged file paths.');
            for (const relative of signing?.profiles ?? []) {
                const source = staged(relative, 'signing.profiles');
                check(/\.(mobileprovision|provisionprofile)$/.test(source), 'Signing profiles must have a provisioning-profile extension.');
                const destination = path.join(profileDirectory, path.basename(source));
                fs.copyFileSync(source, destination);
                fs.chownSync(destination, uid, gid);
                fs.chmodSync(destination, 0o600);
            }
            check(fs.readdirSync(profileDirectory).some(filename => /\.(mobileprovision|provisionprofile)$/.test(filename)),
                'The guest provisioning profiles are missing; provide explicit signing inputs to restore them.');
            return {keychainPath, keychainPassword};
        }, previous);
        return optional;
    }

    function installGuestAgent(replacements, agentPlist) {
        const service = `gui/${uid}/${agentLabel}`;
        const serviceOptions = {timeout: 2000, killSignal: 'SIGKILL'};
        const isLoaded = () => {
            const result = spawnSync('/bin/launchctl', ['print', service], {stdio: 'ignore', timeout: 1000, killSignal: 'SIGKILL'});
            check(!result.error, 'The guest test agent service could not be inspected.');
            return result.status === 0;
        };
        replaceGuestAgentInstallation(replacements, {
            isLoaded,
            stop() { if (isLoaded()) run('Stop the guest test agent for replacement', '/bin/launchctl', ['bootout', service], serviceOptions); },
            start() {
                run('Load the guest test agent', '/bin/launchctl', ['bootstrap', `gui/${uid}`, agentPlist], serviceOptions);
            },
        });
        for (const filename of ['guest.mjs', 'test_manifest.mjs', 'result_audit.mjs']) {
            const obsolete = path.join(library, filename);
            const metadata = fs.lstatSync(obsolete, {throwIfNoEntry: false});
            if (!metadata) continue;
            check(metadata.isFile() && !metadata.isSymbolicLink() && metadata.uid === 0 && (metadata.mode & 0o022) === 0,
                'An obsolete installed harness file is not protected; it was preserved.');
            fs.rmSync(obsolete);
        }
    }

    return {
        prepareStorage, run, configureUIAutomation,
        prepareGuestState, writeJSON, replaceGuestAgentInstallation, extractXcodeArchive,
        selectedUserSessionReady, automaticLoginEnabled, ensureAutomaticLogin, waitForSelectedSession,
        retireSupersededRuntimes, runtimeFileDigest, runtimeMetadataField, verifyOrRepairPinnedRuntime,
        prepareLocalProvisioningDirectory, prepareLocalExchange, removeLocalProvisioningInput, syncDirectory,
        writeDurableJSON, prepareBuildData, protectBuildVolumeRoot, setOwnershipIfNeeded,
        relocationIntentPath, requireIdleRelocationTree, relocateDirectory, ensureUserDeveloperDirectories,
        runtimeArtifactBytes, runtimeStorageCheckpoint, exportedRuntimeImage, importSigningIdentity,
        provisionGuest, loadPreviousProvisioning, prepareRuntimes, prepareSigning, installGuestAgent
    };
}

export function main(argv = process.argv.slice(2)) {
    check(process.getuid() === 0, 'Provisioning requires root inside the guest.');
    const model = nativeSpawnSync('/usr/sbin/sysctl', ['-n', 'hw.model'], {encoding: 'utf8'});
    check(model.status === 0 && model.stdout.trim().startsWith('VirtualMac'), 'Refusing to provision outside a macOS virtual machine.');
    check(argv.length === 5, 'Expected configuration, staging directory, UID, GID, and provisioning mode.');
    const [configPath, staging, uidText, gidText, mode] = argv;
    const config = JSON.parse(nativeFS.readFileSync(configPath, 'utf8'));
    createProvisioner({config, staging, uid: Number(uidText), gid: Number(gidText), mode}).provisionGuest();
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
    try { main(); }
    catch (error) {
        console.error(`Big Wallet VM setup: ${error.message}`);
        process.exitCode = 1;
    }
}
