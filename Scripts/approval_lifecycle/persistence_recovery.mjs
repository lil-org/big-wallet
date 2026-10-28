import assert from "node:assert/strict";
import {nativeSiteContext} from "./browser.mjs";
import {handleKey} from "./oracle.mjs";
import {LifecycleFailure} from "./scheduler.mjs";

export const persistenceRecoveryCases = Object.freeze(["partial-write", "ambiguous-checkpoint", "accepted-completion"]);

const failures = Object.freeze({
    "partial-write": {operation: "broadcast.prepare", checkpoint: "persistence.write.after", errno: 28, partialWriteBytes: 17},
    "ambiguous-checkpoint": {operation: "broadcast.prepare", checkpoint: "persistence.rename.after", errno: 5},
    "accepted-completion": {operation: "completion", checkpoint: "persistence.write.before", errno: 5},
});

export function persistenceRecoveryScenarios(provider) {
    return persistenceRecoveryCases.map(failure => ({kind: "persistenceRecovery", provider, failure}));
}

export function persistenceRecoveryCoverage(mode, provider, failure) {
    return `persistence-recovery:${failure}:${mode}:${provider}`;
}

function sameHandle(candidate, handle) {
    return candidate != null && handleKey(candidate) === handleKey(handle);
}

export function countRequestEffects(events, handle) {
    const relevant = events.filter(event => event.handle && sameHandle(event.handle, handle));
    return {
        consents: relevant.filter(event => event.type === "consent").length,
        signing: relevant.filter(event => event.type === "checkpoint" && event.name === "signer.before").length,
        signed: relevant.filter(event => event.type === "checkpoint" && event.name === "signer.after" && event.succeeded === true).length,
        submissions: relevant.filter(event => event.type === "rpc.received").length,
        accepted: relevant.filter(event => event.type === "rpc.accepted").length,
    };
}

export function requirePersistenceFailure(events, expected) {
    const observed = events.filter(event => event.type === "checkpoint" && event.fault === true);
    const event = observed[0];
    const keys = ["epoch", "role", "operation", "errno"];
    let matches = observed.length === 1 && keys.every(key => event[key] === expected[key]) &&
        event.name === expected.checkpoint && event.gateKey === `${expected.label}|${expected.checkpoint}|1`;
    try {
        matches &&= sameHandle(event.handle ?? event.identity, expected.handle) &&
            (!event.handle || sameHandle(event.handle, expected.handle)) &&
            (!event.identity || sameHandle(event.identity, expected.handle));
    } catch { matches = false; }
    if (expected.partialWriteBytes !== undefined) {
        matches &&= event.writtenBytes === expected.partialWriteBytes && event.writtenBytes > 0 &&
            Number.isSafeInteger(event.requestedBytes) && event.writtenBytes < event.requestedBytes;
    }
    if (!matches) {
        throw new LifecycleFailure("coverage", "Persistence recovery did not exercise its exact injected failure", {expected, observed});
    }
    return event;
}

function gateFor(session, child, handle, name, label) {
    return [...session.gates.values()].find(gate => gate.child === child && gate.details.name === name &&
        gate.details.gateKey === `${label}|${name}|1` && sameHandle(gate.details.handle ?? gate.details.identity, handle));
}

async function awaitGate(session, child, handle, name, label) {
    await session.pumpUntil(() => gateFor(session, child, handle, name, label) !== undefined, {advance: true});
    return gateFor(session, child, handle, name, label);
}

function releaseGate(session, gate) {
    gate.child.release(gate.event.gate, null);
    session.gates.delete(`${gate.child.epoch}:${gate.event.gate}`);
}

export async function recoverySnapshot(session, handle) {
    const deadline = performance.now() + session.options.timeout;
    while (performance.now() < deadline) {
        await session.pump();
        const requests = await session.inspect();
        if (session.lastInspectionAvailable && session.snapshots.get(handle.profileIdentifier)?.durableObservationAvailable === true) {
            const request = requests.find(request => sameHandle(request.handle, handle));
            assert.ok(request, "Recovery must preserve the admitted request");
            return request;
        }
        await session.advance(25);
    }
    throw new LifecycleFailure("coverage", "Recovery never produced an authoritative durable observation", {handle});
}

async function observeWithoutApproval(session, handle) {
    let request;
    for (let pass = 0; pass < 3; pass += 1) {
        await session.pump();
        request = await recoverySnapshot(session, handle);
        for (const child of session.children.values()) { await child.fence(); }
        await session.advance(250);
    }
    return request;
}

async function replayStaleApproval(session, handle, saved) {
    if (session.mode === "native") {
        await assert.rejects(session.child("approval").command("decide", {handle, useSaved: saved.label}),
            error => error.native === true && /consent/.test(error.message));
    } else {
        const reply = await session.child("bridge").command("native", {profileIdentifier: handle.profileIdentifier,
            message: {subject: "approveRequest", id: handle.id, requestToken: handle.token,
                reviewToken: saved.reviewToken, payload: saved.payload, workflowVersion: session.child("bridge").ready.workflowVersion,
                __bwContext: {source: "popup", privateBrowsing: false}}});
        assert.equal(reply.status, "ignored", "A previous-process review must not authorize recovery");
    }
}

async function retryWithoutApproval(session, handle) {
    if (session.mode === "native") {
        await session.child("approval").command("decide", {handle, decision: "retry"});
    } else {
        await session.child("bridge").command("native", {profileIdentifier: handle.profileIdentifier,
            message: {subject: "retryApproval", id: handle.id, requestToken: handle.token,
                workflowVersion: session.child("bridge").ready.workflowVersion,
                __bwContext: {source: "popup", privateBrowsing: false}}});
    }
    await observeWithoutApproval(session, handle);
}

async function assertDisconnected(session, provider) {
    const tab = session.tabs[0];
    const bridge = session.child("bridge");
    const reply = await bridge.command("native", {profileIdentifier: tab.profile.id, message: {
        subject: "getLatestConfiguration", id: 1, configurationKey: new URL(tab.url).origin,
        workflowVersion: bridge.ready.workflowVersion, __bwContext: nativeSiteContext(tab),
    }});
    assert.ok(reply.state, "Disconnected authority must remain readable");
    assert.equal(provider === "ethereum" ? reply.state.ethereum?.address : reply.state.solana?.publicKey ?? "", "",
        "Recovery must not restore disconnected permissions");
    await session.refreshTab(0);
    const publicAccount = provider === "ethereum" ? tab.document.pageWindow.ethereum.selectedAddress : tab.document.pageWindow.solana.publicKey;
    assert.ok(!publicAccount, "The surviving page must remain disconnected");
}

async function disconnect(session, provider) {
    const tab = session.tabs[0];
    const operation = session.browser.request(tab.id, provider, provider === "ethereum"
        ? {method: "wallet_revokePermissions", params: [{eth_accounts: {}}]} : {method: "disconnect"});
    await session.complete(operation, {approve: false, expectedSuccess: true});
    await assertDisconnected(session, provider);
}

function unknownResponse(response, provider, transactionID) {
    assert.equal(response?.kind, "error", "Uncertain submission must not become a success");
    assert.equal(response.error.code, -32603);
    assert.equal(response.error.data?.[provider === "ethereum" ? "transactionHash" : "signature"], transactionID,
        "Recovery must retain the exact signed transaction identity");
}

async function repeatDelivery(session, handle, provider, transactionID) {
    const bridge = session.child("bridge");
    const tab = session.tabs[0];
    const identity = {id: handle.id, requestToken: handle.token, configurationKey: new URL(tab.url).origin,
        workflowVersion: bridge.ready.workflowVersion, __bwContext: nativeSiteContext(tab)};
    for (let pass = 0; pass < 2; pass += 1) {
        const reply = await bridge.command("native", {profileIdentifier: handle.profileIdentifier,
            message: {...identity, subject: "pollResponse", maintenance: "interactive"}});
        unknownResponse(reply.response, provider, transactionID);
        for (let duplicate = 0; duplicate < 2; duplicate += 1) {
            const acknowledged = await bridge.command("native", {profileIdentifier: handle.profileIdentifier,
                message: {...identity, subject: "acknowledgeResponse"}});
            assert.equal(acknowledged.acknowledged, true, "Repeated acknowledgement must retain the stored result");
        }
    }
}

async function retryPartialWrite(session, operation, handle, saved, deadline, helpers, before) {
    await replayStaleApproval(session, handle, saved);
    await retryWithoutApproval(session, handle);
    assert.deepEqual(countRequestEffects(session.ledger.events, handle), before, "Recovery and Retry must not sign or submit");
    let retry = operation;
    if (session.mode === "native") {
        await session.complete(operation, {approve: false});
        assert.equal(operation.status, "rejected");
        assert.equal(operation.error?.code, -32603);
        assert.match(operation.error?.message ?? "", /interrupted/i);
        retry = session.request({tab: 0, provider: operation.provider, method: "broadcast"});
    } else {
        session.browser.closePopup(handle.profileIdentifier);
        await session.browser.openPopup(handle.profileIdentifier);
    }
    const review = await helpers.awaitReview(session, operation.provider);
    if (session.mode === "native") {
        assert.notEqual(handleKey(review.handle), handleKey(handle), "Native retry requires a new request");
    } else {
        assert.equal(handleKey(review.handle), handleKey(handle), "Popup retry preserves the queued request");
        const current = await recoverySnapshot(session, handle);
        assert.equal(current.request?.admissionDeadline, deadline, "Retry must not extend the original deadline");
        assert.ok(session.scheduler.now < deadline, "Fresh popup consent must precede the original deadline");
        assert.notEqual(session.browser.popupState(handle.profileIdentifier)?.review?.reviewToken, saved.reviewToken);
    }
    assert.deepEqual(countRequestEffects(session.ledger.events, handle), before, "Building a fresh review must not sign");
    await helpers.approveOnce(session, review);
    await session.complete(retry, {approve: false, expectedSuccess: true});
    const expected = {consents: 1, signing: 1, signed: 1, submissions: 1, accepted: 1};
    if (session.mode === "popup") {
        expected.consents += before.consents;
        expected.signing += before.signing;
        expected.signed += before.signed;
    }
    assert.deepEqual(countRequestEffects(session.ledger.events, review.handle), expected);
    if (session.mode === "native") { assert.deepEqual(countRequestEffects(session.ledger.events, handle), before); }
    await session.quiesce();
    assert.deepEqual(countRequestEffects(session.ledger.events, review.handle), expected, "Cleanup must not repeat the fresh execution");
}

export async function runPersistenceRecovery(session, specification, helpers) {
    const {provider, failure} = specification;
    const definition = failures[failure];
    const label = persistenceRecoveryCoverage(session.mode, provider, failure);
    await session.connect(0, provider);
    const operation = session.request({tab: 0, provider, method: "broadcast"});
    const review = await helpers.awaitReview(session, provider);
    const handle = review.handle;
    const owner = session.child(session.mode === "native" ? "approval" : "bridge");
    const common = {operation: definition.operation, requestToken: handle.token, occurrence: 1};
    const beforeName = `${definition.operation}.before`;
    await owner.command("checkpoints", {rules: [{...common, name: beforeName, label: `${label}:before`, action: "hold"}]});
    await helpers.approveOnce(session, review);
    const beforeGate = await awaitGate(session, owner, handle, beforeName, `${label}:before`);
    const faultStart = session.ledger.events.length;
    const failedName = `${definition.operation}.failed`;
    await owner.command("checkpoints", {rules: [
        {...common, name: definition.checkpoint, label, action: "fail", errno: definition.errno},
        {...common, name: failedName, label: `${label}:failed`, action: "hold"},
    ], ...(definition.partialWriteBytes ? {partialWriteBytes: definition.partialWriteBytes} : {})});
    releaseGate(session, beforeGate);
    const failedGate = await awaitGate(session, owner, handle, failedName, `${label}:failed`);
    assert.equal(failedGate.details.result, "retryablePersistenceFailure");
    requirePersistenceFailure(session.ledger.events.slice(faultStart), {...definition, handle, epoch: owner.epoch, role: owner.role, label});
    const before = countRequestEffects(session.ledger.events, handle);
    const submissions = failure === "accepted-completion" ? 1 : 0;
    assert.deepEqual(before, {consents: 1, signing: 1, signed: 1, submissions, accepted: submissions});
    const signed = session.ledger.events.findLast(event => event.name === "signer.after" && event.succeeded && sameHandle(event.handle, handle));
    assert.equal(typeof signed?.transactionID, "string");
    const stored = await recoverySnapshot(session, handle);
    assert.equal(stored.broadcastCheckpointed, failure !== "partial-write");
    const saved = (session.mode === "native" ? session.savedConsents : session.savedReviews).findLast(value => sameHandle(value.handle, handle));
    assert.ok(saved, "The failed execution must retain an old approval for replay");
    if (failure !== "partial-write") {
        unknownResponse(stored.terminalResponse ?? stored.recoveryResponse, provider, signed.transactionID);
        await disconnect(session, provider);
        assert.deepEqual(countRequestEffects(session.ledger.events, handle), before, "Disconnect must not repeat privileged work");
    }
    await session.restart(owner.role);
    await observeWithoutApproval(session, handle);
    assert.deepEqual(countRequestEffects(session.ledger.events, handle), before, "Restart must not sign or dispatch");
    if (failure === "partial-write") {
        await retryPartialWrite(session, operation, handle, saved, stored.request?.admissionDeadline, helpers, before);
    } else {
        await replayStaleApproval(session, handle, saved);
        await retryWithoutApproval(session, handle);
        if (failure === "ambiguous-checkpoint") { await session.restart(owner.role); }
        else { session.browser.restartWorker(handle.profileIdentifier); }
        const recovered = await observeWithoutApproval(session, handle);
        assert.equal(recovered.terminal, true);
        assert.equal(recovered.transactionID, signed.transactionID);
        unknownResponse(recovered.terminalResponse, provider, signed.transactionID);
        await repeatDelivery(session, handle, provider, signed.transactionID);
        await session.complete(operation, {approve: false});
        assert.equal(operation.status, "rejected");
        assert.equal(operation.error?.data?.[provider === "ethereum" ? "transactionHash" : "signature"], signed.transactionID);
        await assertDisconnected(session, provider);
        assert.deepEqual(countRequestEffects(session.ledger.events, handle), before, "Repeated recovery must preserve exactly-once effects");
        await session.quiesce();
        assert.deepEqual(countRequestEffects(session.ledger.events, handle), before, "Cleanup must not repeat committed work");
    }
    session.coverage.add(label);
}
