import assert from "node:assert/strict";
import test from "node:test";
import {mandatoryName, mandatoryScenarios, validateMandatoryScenario} from "../../Scripts/approval_lifecycle/mandatory.mjs";
import {countRequestEffects, persistenceRecoveryCases, persistenceRecoveryCoverage,
    persistenceRecoveryScenarios, recoverySnapshot, requirePersistenceFailure} from "../../Scripts/approval_lifecycle/persistence_recovery.mjs";

const handle = {id: 19, token: "request-token", profileIdentifier: "profile-one"};
const expected = {handle, epoch: "approval-2", role: "approval", operation: "broadcast.prepare",
    checkpoint: "persistence.write.after", label: "short-write", errno: 5, partialWriteBytes: 17};
const fault = {type: "checkpoint", fault: true, handle, epoch: expected.epoch, role: expected.role,
    operation: expected.operation, name: expected.checkpoint, gateKey: `${expected.label}|${expected.checkpoint}|1`,
    errno: 5, writtenBytes: 17, requestedBytes: 512};
const rejectsFault = events => assert.throws(() => requirePersistenceFailure(events, expected), error => error.invariant === "coverage");

test("persistence recovery requires an observed failure at the exact request and process checkpoint", () => {
    for (const event of [fault, {...fault, handle: undefined, identity: handle}, {...fault, identity: {...handle}}]) {
        assert.doesNotThrow(() => requirePersistenceFailure([
            {type: "checkpoint", name: expected.checkpoint, handle, fault: false},
            {type: "checkpoint", name: "signer.before", handle},
            event,
            {type: "observation", handle},
        ], expected));
    }
});

test("an armed rule or a nonfault checkpoint does not prove a persistence failure occurred", () => {
    for (const events of [[], [{type: "command", command: "checkpoints", rules: [expected]}],
        [{...fault, fault: false}], [{...fault, fault: undefined}], [{...fault, fault: "true"}],
        [{...fault, type: "observation"}]]) {
        rejectsFault(events);
    }
});

test("persistence failure evidence cannot be borrowed from another request, process, operation or gate", () => {
    for (const change of [
        {handle: {...handle, id: handle.id + 1}},
        {handle: {...handle, token: "another-token"}},
        {handle: {...handle, profileIdentifier: "another-profile"}},
        {handle: {...handle, profileIdentifier: null}},
        {handle: undefined},
        {epoch: "approval-1"}, {epoch: undefined},
        {role: "bridge"}, {role: undefined},
        {operation: "completion"}, {operation: undefined},
        {name: "persistence.write.before"},
        {gateKey: `other-label|${expected.checkpoint}|1`},
        {gateKey: `${expected.label}|persistence.rename.after|1`},
        {gateKey: `${expected.label}|${expected.checkpoint}|2`},
        {gateKey: undefined},
    ]) {
        rejectsFault([{...fault, ...change}]);
    }
});

test("conflicting handle and operation identity cannot validate a persistence failure", () => {
    const other = {...handle, token: "another-token"};
    for (const event of [{...fault, identity: other}, {...fault, handle: other, identity: handle}]) {
        rejectsFault([event]);
    }
});

test("duplicate or additional persistence faults invalidate single-failure coverage", () => {
    for (const second of [fault, {...fault, handle: {...handle, token: "another-token"}},
        {...fault, name: "persistence.rename.after"}, {...fault, epoch: "approval-3"}]) {
        rejectsFault([fault, second]);
    }
});

test("persistence failure coverage requires the injected numeric errno", () => {
    for (const errno of [28, 0, -5, "5", true, null, undefined, NaN, Infinity]) {
        rejectsFault([{...fault, errno}]);
    }
});

test("a short-write failure must prove that exactly 17 bytes of a larger write reached storage", () => {
    assert.doesNotThrow(() => requirePersistenceFailure([{...fault, requestedBytes: 18}], expected));
    for (const change of [
        {writtenBytes: 0}, {writtenBytes: 16}, {writtenBytes: 18}, {writtenBytes: 17.5},
        {writtenBytes: "17"}, {writtenBytes: undefined},
        {requestedBytes: 0}, {requestedBytes: 16}, {requestedBytes: 17},
        {requestedBytes: 18.5}, {requestedBytes: "512"}, {requestedBytes: undefined},
        {requestedBytes: NaN}, {requestedBytes: Infinity},
    ]) {
        rejectsFault([{...fault, ...change}]);
    }
});

test("rename and final-sync failures do not require unrelated short-write evidence", () => {
    for (const checkpoint of ["persistence.rename.after", "persistence.finalSync.after"]) {
        const target = {...expected, checkpoint};
        delete target.partialWriteBytes;
        const event = {...fault, name: checkpoint, gateKey: `${expected.label}|${checkpoint}|1`};
        delete event.writtenBytes;
        delete event.requestedBytes;
        assert.doesNotThrow(() => requirePersistenceFailure([event], target));
    }
});

function effectsFor(requestHandle) {
    return [
        {type: "consent", handle: requestHandle},
        {type: "checkpoint", name: "signer.before", handle: requestHandle},
        {type: "checkpoint", name: "signer.after", succeeded: true, handle: requestHandle},
        {type: "rpc.received", handle: requestHandle},
        {type: "rpc.accepted", handle: requestHandle},
    ];
}

test("request effects use the full handle and retain all process incarnations for that request", () => {
    const unrelated = [
        {...handle, id: handle.id + 1},
        {...handle, token: "another-token"},
        {...handle, profileIdentifier: "another-profile"},
        {...handle, profileIdentifier: null},
    ].flatMap(effectsFor);
    const beforeRestart = effectsFor(handle).map(event => ({...event, epoch: "approval-1", role: "approval"}));
    const afterRestart = effectsFor({...handle}).map(event => ({...event, epoch: "approval-2", role: "approval"}));
    assert.deepEqual(countRequestEffects([...unrelated, ...beforeRestart, ...afterRestart], handle),
        {consents: 2, signing: 2, signed: 2, submissions: 2, accepted: 2});
    assert.deepEqual(countRequestEffects(unrelated, handle),
        {consents: 0, signing: 0, signed: 0, submissions: 0, accepted: 0});
});

test("request effects distinguish attempted signing, successful signing and remote acceptance", () => {
    assert.deepEqual(countRequestEffects([
        {type: "consent", handle},
        {type: "checkpoint", name: "signer.before", handle},
        {type: "checkpoint", name: "signer.before", handle},
        {type: "checkpoint", name: "signer.after", succeeded: false, handle},
        {type: "checkpoint", name: "signer.after", handle},
        {type: "checkpoint", name: "signer.after", succeeded: "true", handle},
        {type: "checkpoint", name: "signer.after", succeeded: true, handle},
        {type: "checkpoint", name: "broadcast.dispatch", handle},
        {type: "rpc.received", handle},
        {type: "checkpoint", name: "completion.after", handle},
        ...effectsFor(undefined),
    ], handle), {consents: 1, signing: 2, signed: 1, submissions: 1, accepted: 0});
});

test("recovery waits for a fresh durable snapshot without approving or accepting cached observations", async () => {
    const stale = {handle, transactionID: "stale-transaction"};
    const fresh = {handle: {...handle}, transactionID: "recovered-transaction"};
    const calls = [];
    let inspections = 0;
    const session = {
        options: {timeout: 1000},
        snapshots: new Map,
        lastInspectionAvailable: false,
        pump: async () => { calls.push("pump"); },
        advance: async delay => { calls.push(["advance", delay]); },
        decide: async () => { calls.push("approve"); },
        async inspect() {
            calls.push("inspect");
            inspections += 1;
            this.lastInspectionAvailable = inspections !== 2;
            this.snapshots.set(handle.profileIdentifier, {durableObservationAvailable: inspections !== 1});
            return inspections < 3 ? [stale] : [fresh];
        },
    };
    assert.equal(await recoverySnapshot(session, handle), fresh);
    assert.deepEqual(calls, ["pump", "inspect", ["advance", 25], "pump", "inspect", ["advance", 25], "pump", "inspect"]);
    assert.equal(inspections, 3);
});

test("persistently unavailable durable observations fail within the recovery watchdog", {timeout: 1000}, async () => {
    for (const targetSnapshot of [undefined, {durableObservationAvailable: false}]) {
        let pumps = 0;
        let inspections = 0;
        let advances = 0;
        let approvals = 0;
        const session = {
            options: {timeout: 15},
            snapshots: new Map([[handle.profileIdentifier, targetSnapshot],
                ["another-profile", {durableObservationAvailable: true}]]),
            lastInspectionAvailable: true,
            pump: async () => { pumps += 1; await new Promise(resolve => setImmediate(resolve)); },
            inspect: async () => { inspections += 1; return [{handle}]; },
            advance: async delay => { assert.equal(delay, 25); advances += 1; },
            decide: async () => { approvals += 1; },
        };
        await assert.rejects(recoverySnapshot(session, handle), error => {
            assert.equal(error.invariant, "coverage");
            assert.match(error.message, /authoritative durable observation/);
            assert.deepEqual(error.details.handle, handle);
            return true;
        });
        assert.ok(pumps > 0);
        assert.equal(inspections, pumps);
        assert.equal(advances, inspections);
        assert.equal(approvals, 0);
    }
});

test("an available durable snapshot must still contain the admitted request", async () => {
    const calls = [];
    const session = {
        options: {timeout: 1000},
        snapshots: new Map([[handle.profileIdentifier, {durableObservationAvailable: true}]]),
        lastInspectionAvailable: true,
        pump: async () => { calls.push("pump"); },
        inspect: async () => { calls.push("inspect"); return [{handle: {...handle, token: "another-token"}}]; },
        advance: async () => { calls.push("advance"); },
        decide: async () => { calls.push("approve"); },
    };
    await assert.rejects(recoverySnapshot(session, handle), /Recovery must preserve the admitted request/);
    assert.deepEqual(calls, ["pump", "inspect"]);
});

test("mandatory persistence recovery covers each failure for both providers and approval surfaces", () => {
    assert.deepEqual(persistenceRecoveryCases, ["partial-write", "ambiguous-checkpoint", "accepted-completion"]);
    const expectedNames = new Set;
    const observedNames = new Set;
    const markers = new Set;
    for (const mode of ["native", "popup"]) {
        const scenarios = mandatoryScenarios(mode, 29);
        const persistence = scenarios.filter(scenario => scenario.mandatory.kind === "persistenceRecovery");
        assert.equal(persistence.length, 6);
        assert.equal(new Set(scenarios.map(mandatoryName)).size, scenarios.length);
        for (const provider of ["ethereum", "solana"]) {
            const specifications = persistenceRecoveryScenarios(provider);
            assert.deepEqual(specifications, persistenceRecoveryCases.map(failure => ({kind: "persistenceRecovery", provider, failure})));
            for (const specification of specifications) {
                expectedNames.add(JSON.stringify([mode, specification.provider, specification.failure]));
            }
        }
        for (const scenario of persistence) {
            const {provider, failure} = scenario.mandatory;
            observedNames.add(JSON.stringify([mode, provider, failure]));
            const replay = JSON.parse(JSON.stringify(scenario));
            assert.deepEqual(validateMandatoryScenario(replay), scenario);
            const marker = persistenceRecoveryCoverage(mode, provider, failure);
            assert.equal(typeof marker, "string");
            assert.ok(marker.length > 0);
            assert.equal(persistenceRecoveryCoverage(replay.mode, replay.mandatory.provider, replay.mandatory.failure), marker);
            markers.add(marker);
        }
    }
    assert.equal(expectedNames.size, 12);
    assert.deepEqual(observedNames, expectedNames);
    assert.equal(markers.size, 12);
});

test("mandatory persistence recovery rejects missing, unknown and malformed replay specifications", () => {
    const scenario = mandatoryScenarios("native", 29).find(value => value.mandatory.kind === "persistenceRecovery");
    assert.ok(scenario);
    for (const mandatory of [
        {...scenario.mandatory, provider: "bitcoin"},
        {...scenario.mandatory, provider: null},
        {...scenario.mandatory, failure: "crash"},
        {...scenario.mandatory, failure: null},
        {...scenario.mandatory, failure: {}},
        {...scenario.mandatory, operation: "completion"},
        {...scenario.mandatory, partialWriteBytes: 18},
        {kind: "persistenceRecovery", failure: "partial-write"},
        {kind: "persistenceRecovery", provider: "ethereum"},
    ]) {
        assert.throws(() => validateMandatoryScenario(JSON.parse(JSON.stringify({...scenario, mandatory}))));
    }
    for (const change of [{mode: "unknown"}, {seed: -1}, {version: 2}, {actions: [{kind: "request"}]}]) {
        assert.throws(() => validateMandatoryScenario({...scenario, ...change}));
    }
});
