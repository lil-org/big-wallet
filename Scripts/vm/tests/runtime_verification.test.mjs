import assert from 'node:assert/strict';
import {chmodSync, existsSync, readFileSync, writeFileSync} from 'node:fs';
import test from 'node:test';
import {RuntimeRepairRequired} from '../runtime_verification.mjs';
import {runtimeRepairFixture} from './runtime_fixture.mjs';

const mutations = fixture => fixture.calls.filter(args => ['add', 'delete'].includes(args[1]));

test('ordinary setup reports rejected pins without creating repair state or mutating registrations', () => {
    for (const platform of ['iOS', 'visionOS']) {
        const fixture = runtimeRepairFixture({platform});
        try {
            assert.throws(fixture.inspect, error => error instanceof RuntimeRepairRequired &&
                error.details.platform === (platform === 'iOS' ? 'ios' : 'visionos') && error.details.phase === null);
            assert.deepEqual(mutations(fixture), []);
            assert.deepEqual(fixture.writes, []);
            assert.equal(existsSync(fixture.journalPath), false);
        } finally { fixture.close(); }
    }
});

test('explicit repair selection is scoped to this invocation and the selected platform', () => {
    for (const platform of ['iOS', 'visionOS']) {
        const fixture = runtimeRepairFixture({platform});
        try {
            const selected = platform === 'iOS' ? 'ios' : 'visionos';
            assert.throws(() => fixture.inspect([selected === 'ios' ? 'visionos' : 'ios']), RuntimeRepairRequired);
            assert.deepEqual(mutations(fixture), []);
            assert.equal(fixture.inspect([selected]).isAvailable, true);
            const calls = mutations(fixture).length;
            const writes = fixture.writes.length;
            assert.equal(fixture.inspect().isAvailable, true);
            assert.equal(mutations(fixture).length, calls);
            assert.equal(fixture.writes.length, writes);
        } finally { fixture.close(); }
    }
});

test('explicit selection verifies a healthy runtime without starting repair', () => {
    const fixture = runtimeRepairFixture({healthy: true});
    try {
        assert.equal(fixture.inspect(['ios']).isAvailable, true);
        assert.deepEqual(mutations(fixture), []);
        assert.deepEqual(fixture.writes, []);
        assert.equal(existsSync(fixture.journalPath), false);
    } finally { fixture.close(); }
});

test('every interrupted repair phase blocks ordinary setup before a missing-runtime reinstall', () => {
    for (const phase of ['source', 'probe', 'probe-verified', 'deleting', 'adding']) {
        const fixture = runtimeRepairFixture();
        try {
            fixture.behavior.interruptPhase = phase;
            assert.throws(fixture.prepare, /repair interrupted/);
            if (phase === 'adding') fixture.inventory.clear();
            const receipt = readFileSync(fixture.journalPath);
            const calls = fixture.calls.length;
            const writes = fixture.writes.length;
            assert.throws(fixture.inspect, error => error instanceof RuntimeRepairRequired && error.details.phase === phase);
            assert.equal(fixture.calls.length, calls);
            assert.equal(fixture.writes.length, writes);
            assert.deepEqual(readFileSync(fixture.journalPath), receipt);
            assert.equal(fixture.inspect(['ios']).isAvailable, true);
        } finally { fixture.close(); }
    }
});

test('completed repair verification retains source, native proof, exact binding and alias checks', () => {
    for (const change of ['source-bytes', 'source-owner', 'image-bytes', 'proof', 'alias', 'binding', 'vm', 'permissions']) {
        const fixture = runtimeRepairFixture();
        try {
            fixture.prepare();
            const journal = fixture.journal();
            if (change === 'source-bytes') writeFileSync(journal.sourcePath, 'changed source');
            if (change === 'source-owner') fixture.behavior.sourceWrongOwner = true;
            if (change === 'image-bytes') fixture.behavior.normalHashMismatch = true;
            if (change === 'proof') {
                journal.probeCompletion.exitCode = 0;
                writeFileSync(fixture.journalPath, JSON.stringify(journal));
            }
            if (change === 'alias') fixture.inventory.set(fixture.siblingID,
                {...fixture.inventory.get(fixture.newID), identifier: fixture.siblingID});
            if (change === 'binding') fixture.inventory.get(fixture.newID).path += '-changed';
            if (change === 'vm') {
                journal.vmId = 'another-vm';
                writeFileSync(fixture.journalPath, JSON.stringify(journal));
            }
            if (change === 'permissions') chmodSync(fixture.journalPath, 0o644);
            const calls = mutations(fixture).length;
            const writes = fixture.writes.length;
            assert.throws(fixture.inspect, error => !(error instanceof RuntimeRepairRequired));
            assert.equal(mutations(fixture).length, calls);
            assert.equal(fixture.writes.length, writes);
        } finally { fixture.close(); }
    }
});

test('inconclusive native verification does not suggest or invoke repair', () => {
    const fixture = runtimeRepairFixture();
    try {
        fixture.behavior.verifyUnknown = true;
        assert.throws(() => fixture.inspect(['ios']), error => !(error instanceof RuntimeRepairRequired) && /inconclusive/.test(error.message));
        assert.deepEqual(mutations(fixture), []);
        assert.equal(existsSync(fixture.journalPath), false);
    } finally { fixture.close(); }
});
