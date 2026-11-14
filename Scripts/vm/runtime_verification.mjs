import path from 'node:path';

function fail(message) { throw new Error(message); }
function check(condition, message) { if (!condition) fail(message); }

export class RuntimeRepairRequired extends Error {
    constructor(pin, phase = null) {
        super(`Explicit repair is required for ${pin.platform} ${pin.version} (${pin.buildVersion}).`);
        this.name = 'RuntimeRepairRequired';
        this.details = {platform: pin.platform === 'iOS' ? 'ios' : 'visionos',
            version: pin.version, buildVersion: pin.buildVersion, phase};
    }
}

export function matchesRuntimeImage(image, pin) {
    const platformIdentifier = pin.platform === 'iOS' ? 'com.apple.platform.iphonesimulator' : 'com.apple.platform.xrsimulator';
    return image.platformIdentifier === platformIdentifier && image.version === pin.version && image.build === pin.buildVersion;
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

export function createRuntimeVerifier(wanted, {config, state, buildRoot, developer, fs, crypto, run, performance, console}) {
    check(['iOS', 'visionOS'].includes(wanted.platform) && /^\d+(?:\.\d+){1,2}$/.test(wanted.version) &&
        /^\d+[A-Z]\d+[a-z]?$/.test(wanted.buildVersion), 'Invalid pinned runtime identity.');
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
    const validImage = image => image && uuid(image.identifier) && matches(image) &&
        typeof image.runtimeIdentifier === 'string' && Number.isSafeInteger(image.sizeBytes) && image.sizeBytes > 0;
    const ordinary = image => validImage(image) && image.kind === 'Disk Image' && typeof image.path === 'string' &&
        image.path.startsWith('/Library/Developer/CoreSimulator/Images/') && path.resolve(image.path) === image.path &&
        image.path.endsWith('/' + image.identifier + '.dmg');
    function readJournal() {
        let journal;
        const info = fs.lstatSync(journalPath, {throwIfNoEntry: false});
        if (info) {
            check(info.isFile() && !info.isSymbolicLink() && info.uid === 0 && (info.mode & 0o077) === 0 && info.size <= 128 * 1024,
                'Runtime repair receipt must be private and bounded.');
            journal = JSON.parse(fs.readFileSync(journalPath, 'utf8'));
            check(journal.version === 1 && journal.vmId === config.vmId && same(journal.pin, pin) && journal.sourcePath === sourcePath &&
                ['source', 'probe', 'probe-verified', 'deleting', 'adding', 'complete'].includes(journal.phase),
                'Runtime repair receipt belongs to another source or pin.');
        }
        if (journal) validateJournal(journal);
        return journal;
    }

    function validateJournal(journal) {
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
    }

    function sourceValid(journal) {
        check(fs.lstatSync(sourcePath).uid === 0, 'The preserved runtime repair source changed.');
        const observed = runtimeFileDigest(sourcePath);
        check(same(observed, journal.source), 'The preserved runtime repair source changed.');
        return observed;
    }
    function current(journal, entry, values = images()) {
        const item = values.find(value => value.identifier === entry.identifier);
        check(!item || same(bound(item), bound(entry)), 'A recorded runtime image identity changed.');
        const allowed = new Set([...journal.failed.map(value => value.identifier), journal.probe?.identifier, journal.installed?.identifier].filter(Boolean));
        check(!values.some(value => matches(value) && !allowed.has(value.identifier)), 'An unrecorded runtime alias appeared; preserve the repair for inspection.');
        return item;
    }
    function requireRepairableImages(selected, inventory) {
        const ready = selected.filter(image => image.state === 'Ready');
        check(ready.length === 1, 'The pinned runtime has ambiguous active registrations.');
        const repairable = selected.every(image => image.kind === 'Patchable Cryptex Disk Image' && image.deletable === true &&
            (image.identifier === ready[0].identifier || image.state === 'Unusable' && image.unusableErrorMessage === 'Cryptex Mount Preferred'));
        if (!repairable) {
            let fresh = null;
            try { fresh = images().filter(matches); } catch {}
            console.log('BIG_WALLET_RUNTIME_REPAIR_ADMISSION=' + JSON.stringify(runtimeAdmissionDiagnostic(pin, selected, fresh)));
            fail('Runtime repair is limited to explicitly rejected patchable cryptex registrations.');
        }
        const assetPaths = new Set(selected.map(image => image.path));
        check(assetPaths.size === 1 && [...assetPaths].every(value => typeof value === 'string' &&
            value.startsWith(assetRoot) && /^[0-9a-f]+\.asset\/AssetData$/i.test(value.slice(assetRoot.length))),
            'Rejected runtime aliases do not identify one official asset.');
        check(!inventory.some(image => !matches(image) && assetPaths.has(image.path)), 'Another runtime pin shares the rejected asset.');
    }

    function validateProbeCompletion(journal) {
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
        return {completion, nativeVerification, readyProof};
    }

    function verifyInstalledRepair(journal) {
        const finalImages = images();
        check(finalImages.filter(matches).length === 1, 'Expected only the verified replacement for this runtime pin.');
        const installed = current(journal, journal.installed, finalImages);
        check(installed && installed.state === 'Ready' && installed.signatureState === 'Verified' &&
            same(runtimeFileDigest(installed.path), journal.source) && verify(installed).status === 'verified',
            'The recorded replacement runtime is no longer verified and available.');
        console.log(`Verified repaired ${wanted.platform} ${wanted.version} (${wanted.buildVersion}); receipt ${journalPath}.`);
        return profile(installed, true);
    }

    function verifyCompletedRepair(journal) {
        check(journal.phase === 'complete', 'Runtime repair is incomplete.');
        sourceValid(journal);
        validateProbeCompletion(journal);
        return verifyInstalledRepair(journal);
    }

    function existing({waitForHandoff = false} = {}) {
        const journal = readJournal();
        if (journal) {
            if (journal.phase !== 'complete') throw new RuntimeRepairRequired(pin, journal.phase);
            return verifyCompletedRepair(journal);
        }
        const inventory = images();
        const selected = inventory.filter(matches);
        if (selected.length === 0) return null;
        check(selected.length <= 8, 'The pinned runtime image inventory is ambiguous.');
        const ready = selected.filter(image => image.state === 'Ready');
        check(ready.length === 1, 'The pinned runtime has ambiguous active registrations.');
        if (verify(ready[0]).status === 'verified') return profile(ready[0], waitForHandoff);
        requireRepairableImages(selected, inventory);
        throw new RuntimeRepairRequired(pin);
    }

    function required(options) {
        const runtime = existing(options);
        check(runtime, 'The pinned runtime image inventory is missing or ambiguous.');
        return runtime;
    }

    return {pin, key, journalPath, journalDirectory, sourcePath, sourceDirectory, assetRoot, assetIdentifier, uuid, same,
        images, matches, bound, verify, profile, validImage, ordinary, invoke, readJournal, validateJournal,
        sourceValid, current, requireRepairableImages, validateProbeCompletion, verifyInstalledRepair, verifyCompletedRepair,
        existing, required, runtimeFileDigest, runtimeMetadataField};
}
