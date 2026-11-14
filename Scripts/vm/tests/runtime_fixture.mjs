import assert from 'node:assert/strict';
import {createHash, randomUUID} from 'node:crypto';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import * as filesystem from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {createRuntimeVerifier, RuntimeRepairRequired, runtimeAdmissionDiagnostic, runtimeProfileDiagnostic} from '../runtime_verification.mjs';
import {repairPinnedRuntime} from '../runtime_repair.mjs';
import {provisionerFixture} from './provisioning_fixture.mjs';

export function runtimeRepairFixture({platform = 'iOS', healthy = false, sibling = false, exportParents = []} = {}) {
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
    const digest = createRuntimeVerifier(pin, provisionerFixture({fs: filesystem, crypto: {createHash}}).runtimeDependencies(buildRoot)).runtimeFileDigest;
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
    const provisioner = (repairPlatforms = []) => provisionerFixture({fs, state, config: {vmId: 'fixture-vm'}, repairPlatforms,
        performance: {now: () => clock}, run, console: {log: value => logs.push(value)}});
    const dependencies = provisioner().runtimeDependencies(buildRoot);
    const verifier = createRuntimeVerifier(pin, dependencies);
    return {pin, buildRoot, exported, inventory, calls, writes, checkpoints, logs, sleeps, queryTimeouts,
        elapsed: () => clock, behavior, oldID, probeID, newID, siblingID, journalPath,
        prepare: (mode, retirement) => mode === 'verify' ? verifier.required() : repairPinnedRuntime(pin, dependencies, retirement),
        inspect: (repairPlatforms = [], retirement) => provisioner(repairPlatforms).inspectRuntime(pin, buildRoot, retirement), verifier, journal: () => JSON.parse(readFileSync(journalPath, 'utf8')),
        close: () => rmSync(root, {recursive: true, force: true})};
}

