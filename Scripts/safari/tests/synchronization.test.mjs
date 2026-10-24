import assert from "node:assert/strict";
import test from "node:test";
import {auditSynchronizationProof, auditSynchronizationSnapshot, expectedSynchronizationPolicy} from "../synchronization.mjs";

const policy = "safari-event-loop-only";
const snapshot = (count = 0) => ({schemaVersion: 1, policy, installationID: "12345678-1234-4123-8123-123456789abc",
    hookInstalled: true, hookActive: true,
    framework: {bundleIdentifier: "com.apple.dt.XCUIAutomation", version: "25228", imageUUID: "6C9998E3-2351-34D3-BAAB-B523F500A26A"},
    selector: "waitForQuiescenceIncludingAnimationsIdle:usingActivity:isPreEvent:", methodEncoding: "v28@0:8B16B20B24",
    counters: {interceptedCalls: 3 * count, originalForwards: 3 * count, safariPreRewrites: count,
        safariPostRewrites: count, nonSafariForwards: count, nonSafariArgumentChanges: 0}});

test("Safari synchronization selects the required policy without an unknown-platform fallback", () => {
    assert.equal(expectedSynchronizationPolicy("ios"), policy);
    assert.equal(expectedSynchronizationPolicy("macos"), "xctest-default");
    assert.throws(() => expectedSynchronizationPolicy("visionos"));
});

test("iOS synchronization requires an installed active hook with the exact runtime and ABI pins", () => {
    assert.deepEqual(auditSynchronizationSnapshot(snapshot(), {policy}), []);
    for (const mutate of [
        value => { delete value.schemaVersion; },
        value => { value.schemaVersion = 2; },
        value => { value.policy = "xctest-default"; },
        value => { value.installationID = ""; },
        value => { value.hookInstalled = false; },
        value => { value.hookActive = false; },
        value => { delete value.framework; },
        value => { value.framework.bundleIdentifier = "com.apple.dt.XCTest"; },
        value => { value.framework.version = "25229"; },
        value => { value.framework.imageUUID = "00000000-0000-0000-0000-000000000000"; },
        value => { value.selector = "waitForQuiescenceIncludingAnimationsIdle:isPreEvent:"; },
        value => { value.methodEncoding = "v24@0:8B16B20"; },
        value => { value.counters.originalForwards = Number.MAX_SAFE_INTEGER + 1; },
        value => { value.counters.safariPreRewrites = -1; },
        value => { value.counters.interceptedCalls = 1.5; },
        value => { value.counters.nonSafariArgumentChanges = 1; },
        value => { value.counters.extra = 0; },
    ]) {
        const invalid = snapshot();
        mutate(invalid);
        assert.ok(auditSynchronizationSnapshot(invalid, {policy}).length);
    }
    for (const invalid of [undefined, null, [], {}]) {
        assert.ok(auditSynchronizationSnapshot(invalid, {policy}).length);
    }
});

test("iOS synchronization rejects impossible counter relationships and coverage proofs", () => {
    for (const counters of [
        {originalForwards: 4},
        {safariPreRewrites: 4},
        {safariPostRewrites: 4},
        {nonSafariForwards: 4},
        {interceptedCalls: 2, originalForwards: 2},
    ]) {
        const invalid = snapshot(1);
        Object.assign(invalid.counters, counters);
        assert.deepEqual(auditSynchronizationSnapshot(invalid, {policy}),
            ["Safari synchronization has inconsistent hook counters"]);
    }
    for (const calls of [0, 2]) {
        const proof = {before: snapshot(), after: snapshot(1)};
        proof.after.counters.interceptedCalls = proof.after.counters.originalForwards = calls;
        assert.deepEqual(auditSynchronizationProof(proof, {policy}),
            ["Safari synchronization after has inconsistent hook counters"]);
    }
});

test("iOS synchronization accepts consistent in-flight and saturated counters", () => {
    const inFlight = snapshot(1);
    inFlight.counters.interceptedCalls += 1;
    inFlight.counters.safariPreRewrites += 1;
    assert.deepEqual(auditSynchronizationSnapshot(inFlight, {policy}), []);
    const saturated = snapshot();
    for (const name of Object.keys(saturated.counters)) {
        if (name !== "nonSafariArgumentChanges") { saturated.counters[name] = Number.MAX_SAFE_INTEGER; }
    }
    assert.deepEqual(auditSynchronizationSnapshot(saturated, {policy}), []);
});

test("iOS proofs reject counter progress without enough new calls", () => {
    const before = snapshot(1);
    before.counters.interceptedCalls = before.counters.originalForwards = 10;
    for (const changes of [
        {safariPreRewrites: 1, safariPostRewrites: 1, nonSafariForwards: 1},
        {interceptedCalls: 1, originalForwards: 1, safariPreRewrites: 1, safariPostRewrites: 1},
        {interceptedCalls: 2, originalForwards: 2, safariPreRewrites: 1, safariPostRewrites: 1, nonSafariForwards: 1},
        {interceptedCalls: 2, originalForwards: 2, safariPreRewrites: 1, safariPostRewrites: 1, nonSafariForwards: 3},
    ]) {
        const after = structuredClone(before);
        for (const [name, count] of Object.entries(changes)) { after.counters[name] += count; }
        assert.deepEqual(auditSynchronizationSnapshot(after, {policy}), []);
        assert.deepEqual(auditSynchronizationProof({before, after}, {policy}),
            ["Safari synchronization has inconsistent hook counter changes"]);
    }
});

test("iOS proofs allow in-flight calls to cross snapshot boundaries", () => {
    const before = snapshot(1);
    Object.assign(before.counters, {interceptedCalls: 10, originalForwards: 9,
        safariPreRewrites: 2, safariPostRewrites: 2, nonSafariForwards: 4});
    const after = structuredClone(before);
    Object.assign(after.counters, {interceptedCalls: 12, originalForwards: 11,
        safariPreRewrites: 3, safariPostRewrites: 3, nonSafariForwards: 5});
    assert.deepEqual(auditSynchronizationProof({before, after}, {policy}), []);
});

test("saturated counters cannot establish a passing synchronization proof", () => {
    const before = snapshot(1);
    before.counters.interceptedCalls = before.counters.originalForwards = Number.MAX_SAFE_INTEGER - 1;
    const after = structuredClone(before);
    after.counters.interceptedCalls = after.counters.originalForwards = Number.MAX_SAFE_INTEGER;
    after.counters.safariPreRewrites += 1;
    after.counters.safariPostRewrites += 1;
    assert.deepEqual(auditSynchronizationSnapshot(after, {policy}), []);
    assert.deepEqual(auditSynchronizationProof({before, after}, {policy}),
        ["Safari synchronization has saturated hook counters"]);
});

test("iOS proofs reject disabled hooks, changed identities, unforwarded calls, reset counters and missing event phases", () => {
    const valid = {before: snapshot(1), after: snapshot(2)};
    assert.deepEqual(auditSynchronizationProof(valid, {policy}), []);
    for (const mutate of [
        value => { delete value.before; },
        value => { delete value.after; },
        value => { value.after.hookActive = false; },
        value => { value.after.installationID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"; },
        value => { value.after.counters.originalForwards -= 1; },
        value => { value.after.counters.nonSafariForwards = 0; },
        value => { value.after.counters.safariPreRewrites = value.before.counters.safariPreRewrites; },
        value => { value.after.counters.safariPostRewrites = value.before.counters.safariPostRewrites; },
        value => { value.before.counters.nonSafariArgumentChanges = 1; value.after.counters.nonSafariArgumentChanges = 1; },
    ]) {
        const invalid = structuredClone(valid);
        mutate(invalid);
        assert.ok(auditSynchronizationProof(invalid, {policy}).length);
    }
    valid.after.counters.nonSafariForwards = valid.before.counters.nonSafariForwards;
    assert.deepEqual(auditSynchronizationProof(valid, {policy}), []);
});

test("macOS requires explicit default synchronization and never carries private hook evidence", () => {
    const policy = "xctest-default";
    const valid = {schemaVersion: 1, policy, hookInstalled: false};
    assert.deepEqual(auditSynchronizationProof({before: valid, after: valid}, {policy}), []);
    for (const invalid of [undefined, null, {}, {...valid, hookInstalled: true}, {...valid, hookActive: false},
        {...valid, framework: snapshot().framework}, {...valid, policy: "safari-event-loop-only"}]) {
        assert.ok(auditSynchronizationSnapshot(invalid, {policy}).length);
    }
    assert.ok(auditSynchronizationProof({before: valid, after: valid}, {}).length);
});
