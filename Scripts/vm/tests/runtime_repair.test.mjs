import assert from 'node:assert/strict';
import {createHash, randomUUID} from 'node:crypto';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import * as filesystem from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {createRuntimeVerifier, RuntimeRepairRequired, runtimeAdmissionDiagnostic, runtimeProfileDiagnostic} from '../runtime_verification.mjs';
import {repairPinnedRuntime} from '../runtime_repair.mjs';
import {provisionerFixture} from './provisioning_fixture.mjs';

import {runtimeRepairFixture} from './runtime_fixture.mjs';

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
    const summarize = runtimeProfileDiagnostic;
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
    const summarize = runtimeAdmissionDiagnostic;
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
    const summarize = runtimeAdmissionDiagnostic;
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
        const extract = createRuntimeVerifier({platform: 'iOS', version: '27.0', buildVersion: '24A434'}, provisionerFixture({run(_label, file, args, options) {
            commands.push(Array.from(args));
            return execFileSync(file, Array.from(args), {encoding: 'utf8', timeout: options.timeout, maxBuffer: options.maxBuffer}).trim();
        }}).runtimeDependencies('/guest/build')).runtimeMetadataField;
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

