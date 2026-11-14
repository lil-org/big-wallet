import path from 'node:path';
import {createRuntimeVerifier, matchesRuntimeImage, runtimeAdmissionDiagnostic} from './runtime_verification.mjs';

function fail(message) { throw new Error(message); }
function check(condition, message) { if (!condition) fail(message); }

export function repairPinnedRuntime(wanted, dependencies, retirement) {
    const {fs, config, buildRoot, console, writeDurableJSON, syncDirectory,
        runtimeStorageCheckpoint, exportedRuntimeImage} = dependencies;
    const verifier = createRuntimeVerifier(wanted, dependencies);
    const {pin, key, journalPath, journalDirectory, sourcePath, sourceDirectory, assetIdentifier, uuid, same,
        images, matches, bound, verify, profile, ordinary, invoke, runtimeFileDigest, runtimeMetadataField} = verifier;
    const mkdir = (directory, mode) => {
        fs.mkdirSync(directory, {recursive: true, mode});
        const info = fs.lstatSync(directory);
        check(info.isDirectory() && !info.isSymbolicLink() && info.uid === 0 && (info.mode & 0o022) === 0 &&
            fs.realpathSync(directory) === directory, 'Runtime repair storage must be root-owned and protected.');
    };
    const trackedImages = (values = images()) => values.filter(image => !retirement?.pins.some(pin => matchesRuntimeImage(image, pin)));
    const checkSpace = image => runtimeStorageCheckpoint(buildRoot, wanted.platform, image, retirement?.release);
    let journal = verifier.readJournal();
    if (journal?.phase === 'complete') return verifier.verifyCompletedRepair(journal);
    let inventory = images();
    const selected = inventory.filter(matches);
    if (!journal) {
        check(selected.length > 0 && selected.length <= 8, 'The pinned runtime image inventory is missing or ambiguous.');
        const ready = selected.filter(image => image.state === 'Ready');
        check(ready.length === 1, 'The pinned runtime has ambiguous active registrations.');
        const rejection = verify(ready[0]);
        if (rejection.status === 'verified') return profile(ready[0], true);
        verifier.requireRepairableImages(selected, inventory);
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
        verifier.validateJournal(journal);
    }
    const save = phase => { journal.phase = phase; writeDurableJSON(journalPath, journal, 0o600); };
    const sourceValid = () => verifier.sourceValid(journal);
    const current = (entry, values) => verifier.current(journal, entry, values);
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
    const {completion, nativeVerification, readyProof} = verifier.validateProbeCompletion(journal);
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
    return verifier.verifyInstalledRepair(journal);
}
