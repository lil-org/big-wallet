#!/bin/sh
set -eu

fail() { printf '%s\n' "Big Wallet VM setup: $*" >&2; exit 1; }

case "$(/usr/sbin/sysctl -n hw.model)" in
    VirtualMac*) ;;
    *) fail 'Refusing to provision outside a macOS virtual machine.' ;;
esac
[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'Run this one-time setup as root inside the guest.'
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || fail 'Usage: sudo sh provision_guest.sh /local/provision/config.json [--prepare-storage]'
mode=${2:-}
case "$mode" in ''|--prepare-storage) ;; *) fail 'Unknown provisioning mode.' ;; esac
[ -f "$1" ] && [ ! -L "$1" ] || fail 'A regular provisioning config.json is required.'
provision_directory=$(CDPATH= cd -- "$(dirname -- "$1")" && pwd -P)
provision_config="$provision_directory/$(basename -- "$1")"
case "$provision_directory" in
    /private/tmp/big-wallet-provision.*/provision) [ "$mode" = --prepare-storage ] || fail 'Full provisioning requires the managed local staging directory.' ;;
    /Volumes/BigWalletBuild/Provisioning/*/provision) ;;
    *) fail 'Provisioning inputs must be staged locally inside the guest.' ;;
esac
for protected_path in "$provision_directory" "$(dirname -- "$provision_directory")"; do
    [ ! -L "$protected_path" ] && [ -d "$protected_path" ] || fail 'Local provisioning directories must be real directories.'
    [ "$(/usr/bin/stat -f '%u' "$protected_path")" -eq 0 ] || fail 'Local provisioning directories must be owned by root.'
    protected_mode=$(/usr/bin/stat -f '%Lp' "$protected_path")
    [ "$((0$protected_mode & 077))" -eq 0 ] || fail 'Local provisioning directories must be private.'
done
umask 022
[ "$(/usr/bin/plutil -extract version raw -o - "$provision_config")" = 1 ] || fail 'Unsupported provisioning config version.'
console_user=$(/usr/bin/plutil -extract consoleUser raw -o - "$provision_config")
case "$console_user" in ''|*[!a-zA-Z0-9_-]*) fail 'consoleUser must name an existing local account.' ;; esac
console_uid=$(/usr/bin/id -u "$console_user") || fail 'Create or select an existing guest account before setup.'
[ "$console_uid" -ge 500 ] || fail 'consoleUser must be a regular local account.'
console_gid=$(/usr/bin/id -g "$console_user")
vm_id=$(/usr/bin/plutil -extract vmId raw -o - "$provision_config")
case "$vm_id" in ''|*[!a-zA-Z0-9_-]*) fail 'vmId must contain only letters, digits, underscores, and hyphens.' ;; esac
node_version=24.22.0
npm_version=11.16.0
jq_version=1.8.1
jq_sha256=a9fe3ea2f86dfc72f6728417521ec9067b343277152b114f4e98d8cb0e263603
[ "$(/usr/bin/plutil -extract jq.version raw -o - "$provision_config")" = "$jq_version" ] || fail 'The pinned jq version is required.'
[ "$(/usr/bin/plutil -extract jq.sha256 raw -o - "$provision_config")" = "$jq_sha256" ] || fail 'The pinned official jq SHA-256 is required.'
case "$(/usr/bin/uname -m)" in arm64) node_arch=arm64 ;; *) fail 'An Apple silicon macOS guest is required.' ;; esac
unset NODE_OPTIONS NODE_PATH

temporary_directory=$(/usr/bin/mktemp -d /private/tmp/big-wallet-vm-setup.XXXXXX)
cleanup() { /bin/rm -rf "$temporary_directory"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
if [ ! -x /usr/local/bin/node ] || [ "$(/usr/local/bin/node --version)" != "v$node_version" ] ||
    [ ! -x /usr/local/bin/npm ] || ! /usr/local/bin/npm --version --cache "$temporary_directory/npm-cache" >/dev/null 2>&1; then
    printf '%s\n' "Installing Node $node_version from nodejs.org with SHA-256 verification."
    node_archive="node-v$node_version-darwin-$node_arch.tar.gz"
    node_url="https://nodejs.org/dist/v$node_version"
    /usr/bin/curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        "$node_url/SHASUMS256.txt" -o "$temporary_directory/SHASUMS256.txt"
    /usr/bin/curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        "$node_url/$node_archive" -o "$temporary_directory/$node_archive"
    /usr/bin/awk -v archive="$node_archive" '$2 == archive { print; found++ } END { if (found != 1) exit 1 }' \
        "$temporary_directory/SHASUMS256.txt" > "$temporary_directory/node.sha256" || fail 'Official Node checksum was not found.'
    (cd "$temporary_directory" && /usr/bin/shasum -a 256 -c node.sha256) || fail 'Node archive checksum did not match.'
    /bin/mkdir -p /usr/local
    /usr/bin/tar -xzf "$temporary_directory/$node_archive" -C /usr/local --strip-components=1
fi
if [ ! -x /usr/local/bin/npm ] || [ "$(/usr/local/bin/npm --version --cache "$temporary_directory/npm-cache")" != "$npm_version" ]; then
    printf '%s\n' "Installing npm $npm_version."
    /usr/local/bin/npm install --global --cache "$temporary_directory/npm-cache" --registry=https://registry.npmjs.org "npm@$npm_version" --no-audit --no-fund
fi
[ "$(/usr/local/bin/node --version)" = "v$node_version" ] || fail 'Node version verification failed.'
[ "$(/usr/local/bin/npm --version --cache "$temporary_directory/npm-cache")" = "$npm_version" ] || fail 'npm version verification failed.'
if [ ! -x /usr/local/bin/jq ] || [ "$(/usr/bin/shasum -a 256 /usr/local/bin/jq | /usr/bin/awk '{print $1}')" != "$jq_sha256" ]; then
    printf '%s\n' "Installing jq $jq_version with the pinned official SHA-256."
    /usr/bin/curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        "https://github.com/jqlang/jq/releases/download/jq-$jq_version/jq-macos-arm64" -o "$temporary_directory/jq"
    [ "$(/usr/bin/shasum -a 256 "$temporary_directory/jq" | /usr/bin/awk '{print $1}')" = "$jq_sha256" ] || fail 'jq binary checksum did not match.'
    /usr/bin/install -m 0755 "$temporary_directory/jq" /usr/local/bin/jq
fi
[ "$(/usr/local/bin/jq --version)" = "jq-$jq_version" ] || fail 'jq version verification failed.'

/usr/local/bin/node --input-type=module - "$provision_config" "$provision_directory" "$console_uid" "$console_gid" "$mode" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';

const [configPath, staging, uidText, gidText, mode] = process.argv.slice(2);
const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
const uid = Number(uidText), gid = Number(gidText);
const library = '/usr/local/libexec/big-wallet-vm';
const state = '/Library/Application Support/BigWalletTestVM';
const exchange = '/Volumes/BigWalletBuild/Exchange';
const agentLabel = 'org.lil.big-wallet.vm-guest';
const developer = '/Applications/Xcode.app/Contents/Developer';
const environment = {...process.env, PATH: '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin', DEVELOPER_DIR: developer};

function fail(message) { throw new Error(message); }
function check(condition, message) { if (!condition) fail(message); }
function text(value, name) {
    check(typeof value === 'string' && value.length > 0 && !value.includes('\0'), `${name} must be a nonempty string.`);
    return value;
}
function run(label, file, args, options = {}) {
    check(options.inputFD === undefined || Number.isInteger(options.inputFD) && options.inputFD >= 0 && options.input === undefined,
        'A command input descriptor must be valid and cannot be combined with input bytes.');
    const invocation = options.user ? ['/bin/launchctl', ['asuser', uidText, '/usr/bin/sudo', '-H', '-u', config.consoleUser, file, ...args]] : [file, args];
    const result = spawnSync(invocation[0], invocation[1], {encoding: 'utf8', env: environment,
        stdio: options.inputFD === undefined ? undefined : [options.inputFD, 'pipe', 'pipe'],
        input: options.input, timeout: options.timeout ?? 3_600_000, killSignal: options.killSignal ?? 'SIGTERM', maxBuffer: 64 * 1024 * 1024});
    if (result.status !== 0) {
        if (!options.secret && result.stderr) process.stderr.write(result.stderr);
        fail(`${label} failed${result.error ? ` (${result.error.code || 'process error'})` : ` (exit ${result.status})`}.`);
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
function validateXcodeArchive(value) {
    if (!value || typeof value !== 'object' || value.path !== 'Xcode.tar' || typeof value.sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(value.sha256)) {
        throw new Error('A staged Xcode.tar archive with its pinned SHA-256 is required.');
    }
    return value;
}
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
    const result = spawnSync('/usr/sbin/sysadminctl', ['-autologin', 'status'], {encoding: 'utf8', timeout: 10000, killSignal: 'SIGKILL'});
    const message = `${result.stdout}${result.stderr}`;
    const account = new RegExp(`(^|[^A-Za-z0-9_-])${config.consoleUser}($|[^A-Za-z0-9_-])`);
    return result.status === 0 && account.test(message) && !/\b(off|disabled|failed|error)\b/i.test(message);
}
function ensureAutomaticLogin() {
    const enabled = automaticLoginEnabled();
    const requiresRestart = !enabled && !selectedUserSessionReady();
    if (!enabled) {
        check(config.autologin && Object.hasOwn(config.autologin, 'passwordFile'),
            'Automatic login is disabled. Supply the existing guest account password in autologin.passwordFile; no password will be reset.');
        check(run('Read selected account groups', '/usr/bin/id', ['-Gn', config.consoleUser]).split(/\s+/).includes('admin'),
            'Automatic login setup requires the selected guest account to be an administrator.');
        const password = secret(config.autologin.passwordFile, 'autologin.passwordFile');
        run('Enable automatic login for the selected guest account', '/usr/sbin/sysadminctl',
            ['-autologin', 'set', '-userName', config.consoleUser, '-password', password,
                '-adminUser', config.consoleUser, '-adminPassword', password], {secret: true, timeout: 60000, killSignal: 'SIGKILL'});
    }
    check(automaticLoginEnabled(), 'Automatic login for the selected guest account is unavailable. Check the existing password and guest FileVault/login policy; no password was reset.');
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
        check(remaining > 0, 'The selected guest account did not reach an unlocked Aqua session within 120 seconds. Check guest automatic login and lock policy.');
        wait(Math.min(1000, remaining));
    }
}
function matchesRuntime(runtime, wanted) {
    return runtime.version === wanted.version && runtime.buildversion === wanted.buildVersion &&
        runtime.identifier.includes(wanted.platform === 'visionOS' ? '.xrOS-' : '.iOS-') && runtime.isAvailable;
}
function requiredProvisioningInputs(configuration, xcodeInstalled, runtimes) {
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
function selectBlankBuildDisk(disks, bootDisk, expectedBytes, authorized) {
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
function validateBlankBuildDisk(details, samples, expectedBytes) {
    if (expectedBytes !== 103_079_215_104 || details.WholeDisk !== true || details.TotalSize !== expectedBytes || details.FilesystemType ||
        samples.length !== 2 || samples.some(sample => sample.length !== 1024 * 1024 || sample.some(byte => byte !== 0))) {
        throw new Error('The managed build-data disk is not blank; refusing to initialize it.');
    }
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
function runtimeRootSpaceRequirement(stagedBytes) {
    const gib = 1024 ** 3;
    if (stagedBytes === undefined) return 16 * gib;
    if (!Number.isSafeInteger(stagedBytes) || stagedBytes <= 0 || stagedBytes > Number.MAX_SAFE_INTEGER - 8 * gib) {
        throw new Error('The staged simulator runtime size is invalid.');
    }
    return stagedBytes + 8 * gib;
}
function runtimeStorageCheckpoint(buildRoot, platform, stagedRuntime) {
    const root = fs.statfsSync('/System/Volumes/Data');
    const build = fs.statfsSync(buildRoot);
    const available = root.bavail * root.bsize;
    const buildAvailable = build.bavail * build.bsize;
    const required = runtimeRootSpaceRequirement(stagedRuntime ? fs.statSync(stagedRuntime).size : undefined);
    check(Number.isSafeInteger(available) && Number.isSafeInteger(buildAvailable), 'Guest filesystem capacity could not be measured.');
    const gib = bytes => (bytes / 1024 ** 3).toFixed(1);
    console.log(`Guest storage before ${platform} ${stagedRuntime ? 'import' : 'download'}: system Data ${gib(available)} GiB free of ${gib(root.blocks * root.bsize)} GiB; build data ${gib(buildAvailable)} GiB free of ${gib(build.blocks * build.bsize)} GiB. Required system headroom: ${gib(required)} GiB.`);
    check(available >= required, `Insufficient guest system-volume space for ${platform}: ${gib(available)} GiB free, ${gib(required)} GiB required. Preserve Apple's system runtime directories; free guest system space or supply a staged runtime image before retrying.`);
    if (!stagedRuntime) check(buildAvailable >= 16 * 1024 ** 3, 'The build-data volume needs at least 16 GiB free to stage a simulator runtime download.');
}
function exportedRuntimeImage(directory) {
    const images = [];
    function visit(current, depth) {
        for (const entry of fs.readdirSync(current, {withFileTypes: true})) {
            const filename = path.join(current, entry.name);
            if (entry.isSymbolicLink()) continue;
            if (entry.isFile() && entry.name.endsWith('.dmg')) images.push(filename);
            if (entry.isDirectory() && depth < 3) visit(filename, depth + 1);
        }
    }
    visit(directory, 0);
    check(images.length === 1, 'Xcode did not export exactly one simulator runtime DMG; inspect the guest RuntimeDownloads directory before retrying.');
    return images[0];
}
function optionalSigningConfiguration(proof, identity, previous) {
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
function appliedProvisioningRequest(config, previous, appliedCapabilities) {
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
    if (mode === '--prepare-storage') {
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

    console.log('Verifying pinned guest simulator runtimes.');
    function installedRuntimes() {
        return JSON.parse(run('List guest runtimes', '/usr/bin/xcrun', ['simctl', 'list', 'runtimes', '--json'], {user: true})).runtimes;
    }
    for (const wanted of config.runtimes) {
        const matches = runtime => matchesRuntime(runtime, wanted);
        if (!installedRuntimes().some(matches)) {
            if (wanted.dmgPath) {
                const image = staged(wanted.dmgPath, 'runtime.dmgPath');
                runtimeStorageCheckpoint(buildRoot, wanted.platform, image);
                run(`Import ${wanted.platform} runtime`, '/usr/bin/xcodebuild', ['-importPlatform', image]);
            } else {
                runtimeStorageCheckpoint(buildRoot, wanted.platform);
                const downloads = path.join(buildRoot, 'RuntimeDownloads', `${wanted.platform}-${wanted.version}-${wanted.buildVersion}`);
                fs.mkdirSync(downloads, {recursive: true, mode: 0o755});
                run(`Download ${wanted.platform} ${wanted.version}`, '/usr/bin/xcodebuild',
                    ['-downloadPlatform', wanted.platform, '-exportPath', downloads, '-buildVersion', wanted.buildVersion, '-architectureVariant', 'arm64']);
                if (!installedRuntimes().some(matches)) {
                    const image = exportedRuntimeImage(downloads);
                    runtimeStorageCheckpoint(buildRoot, wanted.platform, image);
                    run(`Import ${wanted.platform} runtime`, '/usr/bin/xcodebuild', ['-importPlatform', image]);
                }
            }
        }
        const runtime = installedRuntimes().find(matches);
        check(runtime, `${wanted.platform} ${wanted.version} (${wanted.buildVersion}) is unavailable in this guest; install that exact runtime before testing.`);
        if (wanted.dmgPath && fs.existsSync(path.resolve(staging, wanted.dmgPath))) {
            removeLocalProvisioningInput(staged(wanted.dmgPath, 'runtime.dmgPath'), staging, config.vmId);
        }
        const deviceTypes = JSON.parse(run('List simulator device types', '/usr/bin/xcrun', ['simctl', 'list', 'devicetypes', '--json'], {user: true})).devicetypes;
        const name = wanted.platform === 'iOS' ? 'iPhone 18 Pro' : 'Apple Vision Pro';
        const type = deviceTypes.find(type => type.name === name);
        check(type, `The pinned Xcode does not provide the ${name} simulator device type.`);
        const availableDevices = () => JSON.parse(run('List guest simulator devices', '/usr/bin/xcrun', ['simctl', 'list', 'devices', '--json'], {user: true})).devices[runtime.identifier] ?? [];
        if (!availableDevices().some(device => device.isAvailable && device.name === name)) {
            run(`Create ${name} for the pinned runtime`, '/usr/bin/xcrun', ['simctl', 'create', name, type.identifier, runtime.identifier], {user: true});
        }
        check(availableDevices().some(device => device.isAvailable && device.name === name), `No available ${name} simulator was created.`);
    }

    const launchDirectory = path.join(userHome, 'Library/LaunchAgents');
    fs.mkdirSync(launchDirectory, {recursive: true, mode: 0o755});
    fs.chownSync(launchDirectory, uid, gid);
    const logDirectory = path.join(userHome, 'Library/Logs/BigWalletTestVM');
    fs.mkdirSync(logDirectory, {recursive: true, mode: 0o700});
    fs.chownSync(logDirectory, uid, gid);
    const agentPlist = path.join(launchDirectory, `${agentLabel}.plist`);
    const agentConfiguration = {Label: agentLabel,
        ProgramArguments: [`${library}/VMGuestAgent`],
        LimitLoadToSessionType: 'Aqua', RunAtLoad: false, KeepAlive: false,
        EnvironmentVariables: {PATH: environment.PATH, DEVELOPER_DIR: developer},
        StandardOutPath: path.join(logDirectory, 'agent.log'), StandardErrorPath: path.join(logDirectory, 'agent.log')};
    const signing = config.signing;
    const keychainPath = path.join(userHome, 'Library/Keychains/big-wallet-vm.keychain-db');
    const provisioningPath = path.join(state, 'provisioning.json');
    let previous;
    if (fs.existsSync(provisioningPath)) {
        const metadata = fs.lstatSync(provisioningPath);
        check(metadata.isFile() && !metadata.isSymbolicLink() && metadata.uid === 0 && (metadata.mode & 0o022) === 0,
            'Existing guest signing configuration is not a protected root-owned file.');
        previous = JSON.parse(fs.readFileSync(provisioningPath, 'utf8'));
        check(previous.version === 1 && previous.vmId === config.vmId && previous.consoleUser === config.consoleUser &&
            (previous.keychainPath === undefined || previous.keychainPath === keychainPath),
            'Existing guest signing configuration belongs to a different VM or account.');
    }
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
    console.log(`Guest ${config.vmId} base is ready for ${config.consoleUser}. No account, password, or existing VM installation was reset.`);
    if (optional.missingSigning.length) {
        console.log(`Signed native coverage is unavailable: ${optional.missingSigning.join('; ')}`);
    } else {
        console.log('Signing prerequisites are installed; the test runner must still verify every requested coverage stage.');
    }
}

try { provisionGuest(); }
catch (error) {
    console.error(`Big Wallet VM setup: ${error.message}`);
    process.exitCode = 1;
}
NODE
