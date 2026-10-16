import assert from "node:assert/strict";
import {rename} from "node:fs/promises";
import {join} from "node:path";
import vm from "node:vm";
import {nativeSiteContext} from "./browser.mjs";
import {LifecycleFailure} from "./scheduler.mjs";
import {handleKey} from "./oracle.mjs";
import {profiles} from "./scenarios.mjs";

const persistenceStages = ["write", "fileSync", "rename", "directorySync", "finalSync"];
const semanticStages = ["admission.after", "claim.after", "authorize.after", "signer.before", "signer.after",
    "broadcast.prepared", "broadcast.dispatch", "rpc.received", "rpc.accepted", "completion.after", "delivery.after", "acknowledgement.after"];

export function mandatoryScenarios(mode, seed = 1) {
    const cases = [
        {kind: "success"}, {kind: "competition"}, {kind: "consentReplay"}, {kind: "revocationCrash"},
        {kind: "authenticationCancellation"}, {kind: "revocationBeforeSigning"},
        ...(mode === "native" ? [{kind: "retryRequiredFocus"}, {kind: "chainSwitchAuthentication"}, {kind: "manualSwitchCoalescing"}] : []),
        ...(mode === "popup" ? [{kind: "editedReview"}, {kind: "abandonedPopupReview"}] : []),
    ];
    for (const provider of ["ethereum", "solana"]) {
        for (const checkpoint of [...semanticStages, ...(mode === "native" ? ["receipt.after"] : [])]) {
            cases.push({kind: "crash", provider, checkpoint});
        }
        for (const stage of persistenceStages) {
            for (const side of ["before", "after"]) {
                cases.push({kind: "crash", provider, checkpoint: `persistence.${stage}.${side}`,
                    operation: "broadcast.prepare", ...(stage === "write" && side === "after" ? {partialWriteBytes: 17} : {})});
            }
        }
        for (const operation of ["claim", "completion", "acknowledgement"]) {
            for (const side of ["before", "after"]) {
                cases.push({kind: "crash", provider, checkpoint: `persistence.rename.${side}`, operation});
            }
        }
    }
    return cases.map(mandatory => ({version: 1, seed, mode, actions: [], mandatory}));
}

export function mandatoryName(scenario) {
    const value = scenario.mandatory;
    return [scenario.mode, value.kind, value.provider, value.operation, value.checkpoint].filter(Boolean).join("/");
}

export function validateMandatoryScenario(scenario) {
    if (scenario?.version !== 1 || !Number.isInteger(scenario.seed) || scenario.seed < 0 || scenario.seed > 0xffffffff ||
        !["native", "popup"].includes(scenario.mode) || !Array.isArray(scenario.actions) || scenario.actions.length) {
        throw new Error("Invalid mandatory approval scenario");
    }
    const known = mandatoryScenarios(scenario.mode, scenario.seed).some(candidate =>
        JSON.stringify(candidate.mandatory) === JSON.stringify(scenario.mandatory));
    if (!known) { throw new Error("Unknown mandatory approval scenario"); }
    return scenario;
}

function countEffects(session) {
    return {
        signing: session.ledger.events.filter(event => event.type === "checkpoint" && event.name === "signer.before").length,
        submissions: session.ledger.events.filter(event => event.type === "rpc.received").length,
        accepted: session.ledger.events.filter(event => event.type === "rpc.accepted").length,
    };
}

async function awaitReview(session, provider, {tab = 0, name} = {}) {
    const deadline = performance.now() + session.options.timeout;
    while (performance.now() < deadline) {
        await session.pump();
        const requests = await session.inspect();
        const request = requests.find(value => value.provider === provider &&
            value.handle.profileIdentifier === session.tabs[tab].profile.id &&
            (!name || value.name === name) && !["responded", "completed"].includes(value.phase));
        if (request) {
            if (session.mode === "native" && request.presentation === "review") { return request; }
            if (session.mode === "popup") {
                await session.browser.openPopup(request.handle.profileIdentifier);
                await session.pump();
                const state = session.browser.popupState(request.handle.profileIdentifier);
                const popup = session.browser.profile(request.handle.profileIdentifier).popup;
                const current = popup && vm.runInContext("popupQueue?.currentRequest?.request ?? null", popup.harness.context);
                if (current?.id === request.handle.id && current.requestToken === request.handle.token &&
                    state?.actions.includes("approve") &&
                    (state.review?.requiresClusterSelection || !popup.harness.get("button-approve").disabled)) { return request; }
            }
        }
        await session.advance(250);
    }
    throw new LifecycleFailure("coverage", "Required approval did not become reviewable", {provider, name});
}

async function releaseExternal(session) {
    for (const [key, gate] of session.gates) {
        if (gate.external) { gate.release(); session.gates.delete(key); }
    }
    await session.pump();
}

async function approveOnce(session, request) {
    const deadline = performance.now() + session.options.timeout;
    while (performance.now() < deadline) {
        if (await session.decide({}, "approve", request)) { return; }
        await session.pump();
        await session.advance(250);
    }
    throw new LifecycleFailure("coverage", "Required approval control never became actionable", {handle: request.handle});
}

async function success(session) {
    for (const provider of ["ethereum", "solana"]) {
        await session.connect(0, provider);
        for (const method of ["message", "transaction", "broadcast"]) {
            await session.complete(session.request({tab: 0, provider, method}), {expectedSuccess: true});
        }
    }
    for (const tab of [1, 2, 3]) { await session.connect(tab, "ethereum"); }
    const operations = [1, 2, 3].map(index => session.browser.request(session.tabs[index].id, "ethereum", {
        method: "personal_sign", params: [`0x0102030${index}`, session.account("ethereum").address],
    }));
    for (const operation of operations) { await session.complete(operation, {expectedSuccess: true}); }
    await session.complete(session.request({tab: 0, provider: "ethereum", method: "addChain"}), {expectedSuccess: true});
    session.browser.focus(session.tabs[0].id);
    if (session.mode === "popup") {
        session.browser.closePopup(profiles[0]);
        await session.browser.openPopup(profiles[0]);
        await session.pumpUntil(() => vm.runInContext("popupQueue?.canSwitchAccount === true",
            session.browser.profile(profiles[0]).popup.harness.context), {advance: true});
        session.trackPopup(session.browser.clickPopup(profiles[0], "idle-switch-account"), profiles[0]);
    } else { session.browser.toolbar(session.tabs[0].id); }
    const manual = await awaitReview(session, "unknown", {name: "switchAccount"});
    await approveOnce(session, manual);
    await session.pumpUntil(() => session.ledger.events.some(event =>
        event.type === "checkpoint" && event.name === "completion.after" && event.handle && handleKey(event.handle) === handleKey(manual.handle)), {advance: true});
    session.oracle.requireCoverage(["consent", "signer.before", "signer.after", "broadcast.prepared", "broadcast.dispatch", "broadcast.accepted", "browser.fulfilled"]);
    await session.quiesce();
}

async function crash(session, specification) {
    const {provider, checkpoint, operation: storeOperation} = specification;
    await session.connect(0, provider);
    const bridgeCheckpoint = checkpoint === "admission.after" || checkpoint === "delivery.after" ||
        checkpoint === "acknowledgement.after" || storeOperation === "acknowledgement";
    const role = bridgeCheckpoint || session.mode === "popup" ? "bridge" : "approval";
    const child = session.child(role);
    const early = checkpoint === "admission.after" || checkpoint === "receipt.after";
    const arm = async () => {
        if (checkpoint.startsWith("rpc.")) { session.externalRule = {name: checkpoint}; }
        else {
            await child.command("checkpoints", {rules: [{name: checkpoint, operation: storeOperation, occurrence: 1, action: "hold"}],
                partialWriteBytes: specification.partialWriteBytes});
        }
    };
    if (early) { await arm(); }
    const operation = session.request({tab: 0, provider, method: "broadcast"});
    let request;
    if (!early) {
        request = await awaitReview(session, provider);
        await arm();
        await approveOnce(session, request);
    }
    await session.pumpUntil(() => [...session.gates.values()].some(gate => gate.details.name === checkpoint), {advance: true});
    const gate = [...session.gates.values()].find(value => value.details.name === checkpoint);
    const handle = request?.handle || gate.details.handle || gate.details.identity;
    if (!gate.external) {
        assert.equal(gate.child, child, "Checkpoint must belong to the targeted process incarnation");
        if (storeOperation) { assert.equal(gate.details.operation, storeOperation); }
        assert.equal(handleKey(gate.details.handle || gate.details.identity), handleKey(handle));
        if (specification.partialWriteBytes) {
            assert.equal(gate.details.writtenBytes, specification.partialWriteBytes);
            assert.ok(gate.details.writtenBytes < gate.details.requestedBytes, "Crash must interrupt a partial temporary write");
        }
    }
    const before = countEffects(session);
    const signedIdentity = session.ledger.events.findLast(event => event.name === "signer.after" &&
        event.succeeded && event.handle && handleKey(event.handle) === handleKey(handle))?.transactionID;
    await session.restart(role);
    await releaseExternal(session);
    for (const value of session.children.values()) { await value.command("checkpoints", {rules: []}); }
    await session.quiesce();
    const after = countEffects(session);
    assert.equal(after.signing, before.signing, "Recovery must not invoke signing again");
    assert.equal(after.submissions, before.submissions, "Recovery must not submit again");
    const recovered = (await session.inspect()).find(value => value.handle && handle && handleKey(value.handle) === handleKey(handle));
    assert.equal(session.snapshots.get(handle.profileIdentifier)?.durableObservationAvailable, true,
        "Recovery assertions require a readable authoritative profile");
    assert.ok(recovered, "The admitted request must remain observable after restart");
    const knownCommitted = ["broadcast.prepared", "broadcast.dispatch", "rpc.received", "rpc.accepted",
        "completion.after", "delivery.after", "acknowledgement.after"].includes(checkpoint) ||
        ["completion", "acknowledgement"].includes(storeOperation) ||
        storeOperation === "broadcast.prepare" && ["persistence.rename.after", "persistence.directorySync.before",
            "persistence.directorySync.after", "persistence.finalSync.before", "persistence.finalSync.after"].includes(checkpoint);
    if (knownCommitted) {
        assert.equal(recovered.broadcastCheckpointed, true, "A published broadcast checkpoint must survive process death");
        assert.equal(typeof signedIdentity, "string", "The parent must record the signed transaction identity before crashing");
        assert.equal(recovered.transactionID, signedIdentity, "Recovery must retain the exact signed transaction identity");
        const knownTerminal = ["completion.after", "delivery.after", "acknowledgement.after"].includes(checkpoint) ||
            storeOperation === "acknowledgement" || storeOperation === "completion" && checkpoint === "persistence.rename.after";
        assert.equal(recovered.terminalResponse?.kind, knownTerminal ? "result" : "error",
            "Recovery must distinguish a published result from an uncertain submission");
    }
    if (recovered?.broadcastCheckpointed) {
        assert.ok(recovered.transactionID, "Committed broadcast must retain its transaction identity");
        const response = recovered.terminalResponse || recovered.recoveryResponse;
        assert.ok(response, "Committed broadcast must have a recoverable response");
        const resultIdentity = response.kind === "result" ? response.result :
            response.error?.data?.transactionHash || response.error?.data?.signature;
        assert.equal(resultIdentity, recovered.transactionID, "Recovery response must identify the original transaction");
    }
    if (checkpoint === "rpc.accepted") {
        assert.equal(before.accepted, 1, "Remote acceptance must happen before the deliberate crash");
        assert.equal(after.accepted, 1);
    }
    if (knownCommitted) {
        const browserIdentity = operation.status === "fulfilled" ?
            (typeof operation.result === "string" ? operation.result : operation.result?.signature) :
            operation.error?.data?.transactionHash || operation.error?.data?.signature;
        assert.equal(browserIdentity, signedIdentity, "The surviving page must receive the original transaction identity");
    }
    assert.notEqual(operation.status, "pending", "Surviving browser request must settle after recovery");
    session.coverage.add(`crash:${checkpoint}:${storeOperation || "semantic"}`);
}

async function competition(session) {
    await session.connect(0, "ethereum");
    const operation = session.request({tab: 0, provider: "ethereum", method: "message"});
    const request = await awaitReview(session, "ethereum");
    const owner = session.child(session.mode === "native" ? "approval" : "bridge");
    await owner.command("checkpoints", {rules: [{name: "claim.after", occurrence: 1, action: "hold"}]});
    await approveOnce(session, request);
    await session.pumpUntil(() => [...session.gates.values()].some(gate => gate.details.name === "claim.after"), {advance: true});
    let contender = session.children.get(session.mode === "native" ? "bridge" : "approval");
    if (!contender) { contender = await session.start("approval"); }
    const result = await contender.command("claim", {handle: request.handle, label: "contender"});
    assert.equal(result, "executing", "A second process must observe the live operation owner");
    await session.restart(owner.role);
    const afterDeath = await contender.command("claim", {handle: request.handle, label: "after-death"});
    if (session.mode === "popup") {
        assert.equal(afterDeath, "claimed", "The OS must release the operation lock when the owner dies");
        await contender.command("releaseClaim", {label: "after-death"});
    } else { assert.equal(afterDeath, "responded", "An orphaned native execution must recover as interrupted"); }
    await session.quiesce();
    assert.notEqual(operation.status, "pending");
    assert.equal(countEffects(session).signing, 0);
    session.coverage.add("process-lock-recovery");
}

async function consentReplay(session) {
    await session.connect(0, "ethereum");
    const operation = session.request({tab: 0, provider: "ethereum", method: "broadcast"});
    await session.complete(operation, {expectedSuccess: true});
    const before = countEffects(session);
    if (session.mode === "native") {
        const saved = session.savedConsents.at(-1);
        assert.ok(saved, "Native execution must expose a process-local consent label");
        await session.child("approval").command("decide", {handle: saved.handle, useSaved: saved.label});
        await session.restart("approval");
        await assert.rejects(session.child("approval").command("decide", {handle: saved.handle, useSaved: saved.label}),
            error => error.native === true && /consent/.test(error.message));
    } else {
        const saved = session.savedReviews.at(-1);
        assert.ok(saved, "Popup execution must expose a review token");
        await session.restart("bridge");
        const reply = await session.child("bridge").command("native", {profileIdentifier: saved.handle.profileIdentifier,
            message: {subject: "approveRequest", id: saved.handle.id, requestToken: saved.handle.token,
                reviewToken: saved.reviewToken, payload: saved.payload || {}, workflowVersion: 4,
                __bwContext: {source: "popup", privateBrowsing: false}}});
        assert.equal(reply.status, "ignored", "A previous-process review must not become active again");
    }
    await session.pump();
    await session.inspect();
    assert.deepEqual(countEffects(session), before, "Consumed or old-process consent must not execute a committed request");
    session.coverage.add("old-process-consent");
    await session.quiesce();
    assert.deepEqual(countEffects(session), before, "Stale replay must not start deferred work during recovery");
}

async function revocationCrash(session) {
    await session.connect(0, "ethereum");
    const account = session.account("ethereum");
    const child = session.child("bridge");
    await child.command("checkpoints", {rules: [{name: "revocation.after", operation: "walletMutation", occurrence: 1, action: "hold"}]});
    session.track(child.command("wallet", {action: "removeWallet", walletID: account.walletID}));
    await session.pumpUntil(() => [...session.gates.values()].some(gate => gate.details.name === "revocation.after"));
    await session.restart("bridge");
    const reply = await session.child("bridge").command("native", {profileIdentifier: profiles[0],
        message: {subject: "getLatestConfiguration", id: 100, workflowVersion: 4,
            configurationKey: new URL(session.tabs[0].url).origin, __bwContext: nativeSiteContext(session.tabs[0])}});
    assert.equal(reply.state?.ethereum?.address, "",
        "Published revocation must survive a crash before wallet mutation completes");
    await session.quiesce();
    session.coverage.add("wallet-revocation-crash");
}

async function authenticationCancellation(session) {
    await session.connect(0, "ethereum");
    const owner = session.child(session.mode === "native" ? "approval" : "bridge");
    if (session.mode === "native") {
        await owner.command("checkpoints", {rules: [{name: "authentication.before", occurrence: 1, action: "hold"}]});
    }
    const operation = session.request({tab: 0, provider: "ethereum", method: "message"});
    if (session.mode === "popup") {
        const request = await awaitReview(session, "ethereum");
        await owner.command("checkpoints", {rules: [{name: "authentication.before", occurrence: 1, action: "hold"}]});
        await approveOnce(session, request);
    }
    await session.pumpUntil(() => [...session.gates.values()].some(gate => gate.details.name === "authentication.before"), {advance: true});
    await session.action({kind: "cancelAuthentication", tab: 0, selector: 0});
    await session.quiesce();
    assert.equal(countEffects(session).signing, 0, "Cancelled authentication must not enter signing");
    assert.equal(operation.status, "rejected");
    session.coverage.add("authentication-cancelled");
}

async function chainSwitchAuthentication(session) {
    await session.connect(0, "ethereum");
    const tab = session.tabs[0];
    const owner = session.child("approval");
    const initialChain = tab.document.pageWindow.ethereum.chainId;
    const targetChain = initialChain === "0x1" ? "0xa" : "0x1";
    const switchChain = () => session.browser.request(tab.id, "ethereum", {
        method: "wallet_switchEthereumChain", params: [{chainId: targetChain}],
    });
    const authenticated = (operation, after) => owner.events.some(event => event.sequence > after &&
        event.event === "checkpoint" && event.details.name === "authentication.before" &&
        handleKey(event.details.handle) === handleKey(operation.handle));
    const durableChain = async () => {
        await session.inspect();
        const configuration = session.snapshots.get(tab.profile.id).configurations.find(value =>
            value.configurationKey === new URL(tab.url).origin);
        return configuration?.state.ethereum.chainId;
    };

    await owner.command("authenticate", {success: false});
    const beforeCancellation = owner.sequence;
    const canceled = switchChain();
    await session.complete(canceled, {approve: false});
    assert.equal(canceled.status, "rejected", "Known-chain switching must not bypass canceled helper authentication");
    assert.ok(authenticated(canceled, beforeCancellation), "The chain switch must reach helper authentication");
    assert.equal(tab.document.pageWindow.ethereum.chainId, initialChain, "Canceled authentication must preserve the page's chain");
    assert.equal(await durableChain(), initialChain, "Canceled authentication must preserve the stored chain");

    await owner.command("authenticate", {success: true});
    const beforeAuthentication = owner.sequence;
    const approved = switchChain();
    await session.complete(approved, {approve: false, expectedSuccess: true});
    assert.notEqual(handleKey(approved.handle), handleKey(canceled.handle), "Retrying must create a fresh native request");
    assert.ok(authenticated(approved, beforeAuthentication), "The fresh chain switch must authenticate again");
    assert.equal(tab.document.pageWindow.ethereum.chainId, targetChain);
    assert.equal(await durableChain(), targetChain);
    await session.quiesce();
    session.coverage.add("native-chain-switch-authentication");
}

async function revocationBeforeSigning(session) {
    await session.connect(0, "ethereum");
    const operation = session.request({tab: 0, provider: "ethereum", method: "broadcast"});
    const request = await awaitReview(session, "ethereum");
    const owner = session.child(session.mode === "native" ? "approval" : "bridge");
    await owner.command("checkpoints", {rules: [{name: "signer.before", occurrence: 1, action: "hold"}]});
    await approveOnce(session, request);
    await session.pumpUntil(() => [...session.gates.values()].some(gate => gate.details.name === "signer.before"), {advance: true});
    const disconnect = session.browser.request(session.tabs[0].id, "ethereum", {method: "wallet_revokePermissions", params: [{eth_accounts: {}}]});
    await session.complete(disconnect, {approve: false, expectedSuccess: true});
    for (const [key, gate] of session.gates) {
        if (gate.details.name === "signer.before") { gate.child.release(gate.event.gate, null); session.gates.delete(key); }
    }
    await session.quiesce();
    assert.equal(countEffects(session).submissions, 0, "Revocation before signing must prevent dispatch");
    assert.equal(operation.status, "rejected");
    assert.equal(session.ledger.events.filter(event => event.name === "signer.after" && event.succeeded).length, 0);
    session.coverage.add("revocation-before-signing");
}

async function retryRequiredFocus(session) {
    await session.connect(0, "ethereum");
    const operation = session.request({tab: 0, provider: "ethereum", method: "message"});
    const request = await awaitReview(session, "ethereum");
    const owner = session.child("approval");
    const matches = handle => handleKey(handle) === handleKey(request.handle);
    await owner.command("checkpoints", {rules: [{name: "claim.before", occurrence: 1, action: "hold"}]});
    await approveOnce(session, request);
    await session.pumpUntil(() => [...session.gates.values()].some(gate =>
        gate.details.name === "claim.before" && matches(gate.details.handle)), {advance: true});
    const wallets = join(session.storeRoot, "wallets.plist");
    const unavailableWallets = join(session.storeRoot, "wallets.unavailable.plist");
    await rename(wallets, unavailableWallets);
    try {
        for (const [key, gate] of session.gates) {
            if (gate.details.name === "claim.before" && matches(gate.details.handle)) {
                gate.child.release(gate.event.gate, null);
                session.gates.delete(key);
            }
        }
        await session.pumpUntil(() => owner.events.some(event => event.event === "presentation" &&
            matches(event.details.handle) && event.details.presentation === "retryRequired"));
    } finally { await rename(unavailableWallets, wallets); }
    const paused = (await session.inspect()).find(value => matches(value.handle));
    assert.equal(paused?.presentation, "retryRequired");
    const before = countEffects(session);
    const bridge = session.child("bridge");
    const focused = await bridge.command("native", {profileIdentifier: request.handle.profileIdentifier, message: {
        subject: "showApproval", id: request.handle.id, requestToken: request.handle.token,
        configurationKey: request.configurationKey, workflowVersion: bridge.ready.workflowVersion,
        __bwContext: {source: "worker", privateBrowsing: false},
    }});
    assert.equal(focused.opened, true, "Focusing a paused request must redeliver its native route");
    await session.pump();
    const afterFocus = (await session.inspect()).find(value => matches(value.handle));
    assert.equal(afterFocus?.presentation, "retryRequired", "Route redelivery must preserve the explicit Retry requirement");
    assert.equal(afterFocus.revision, paused.revision, "Focus must not rebuild a paused review");
    assert.deepEqual(countEffects(session), before, "Route redelivery must not resume signing");
    assert.equal(await session.decide({}, "retry", afterFocus), true);
    const retried = await awaitReview(session, "ethereum");
    await approveOnce(session, retried);
    await session.complete(operation, {approve: false, expectedSuccess: true});
    await session.quiesce();
    assert.equal(countEffects(session).signing, before.signing + 1, "Explicit Retry and fresh approval must sign once");
    session.coverage.add("native-explicit-review-retry");
}

async function editedReview(session) {
    await session.connect(0, "ethereum");
    const operation = session.request({tab: 0, provider: "ethereum", method: "broadcast"});
    const request = await awaitReview(session, "ethereum");
    const original = structuredClone(session.browser.popupState(profiles[0]));
    assert.equal(typeof original?.review?.reviewToken, "string");
    await session.action({kind: "editFees", tab: 0, selector: 0});
    await session.pumpUntil(() => {
        const state = session.browser.popupState(profiles[0]);
        return state?.review?.reviewToken && state.review.reviewToken !== original.review.reviewToken && state.actions.includes("approve");
    }, {advance: true});
    await session.child("bridge").command("native", {profileIdentifier: profiles[0], message: {
        subject: "approveRequest", id: request.handle.id, requestToken: request.handle.token,
        reviewToken: original.review.reviewToken, payload: {}, workflowVersion: 4,
        __bwContext: {source: "popup", privateBrowsing: false},
    }});
    await session.pump();
    assert.equal(countEffects(session).signing, 0, "Old review tokens must not approve edited fees");
    await session.complete(operation, {expectedSuccess: true});
    assert.equal(countEffects(session).submissions, 1);
    session.coverage.add("edited-review-token");
}

async function abandonedPopupReview(session) {
    await session.connect(0, "ethereum");
    const operation = session.request({tab: 0, provider: "ethereum", method: "message"});
    const request = await awaitReview(session, "ethereum");
    const key = handleKey(request.handle);
    const tab = session.tabs[0];
    session.browser.navigate(tab.id, new URL(tab.url).origin + "/replacement");
    assert.equal(operation.status, "abandoned");
    assert.equal(session.browser.popupRequest(tab.profile.id)?.requestToken, request.handle.token,
        "The abandoned request must still occupy the popup review before gate preparation");
    await session.action({kind: "holdNative", tab: 2, selector: 0, provider: "solana", checkpoint: "signer.before"});
    const gate = [...session.gates.values()].find(value => value.details.name === "signer.before");
    assert.ok(gate, "The fresh request must reach its native checkpoint");
    const held = session.nativeRequests.get(handleKey(gate.details.handle));
    assert.equal(held?.provider, "solana");
    assert.equal(held.configurationKey, new URL(session.tabs[2].url).origin);
    await session.quiesce();
    const abandoned = (await session.inspect()).find(value => handleKey(value.handle) === key);
    assert.equal(abandoned?.terminalResponse?.kind, "error");
    assert.equal(abandoned.terminalResponse.error.code, 4001, "Gate preparation must reject the blocking review");
    assert.equal(session.ledger.events.some(event => event.name === "signer.before" && event.handle &&
        handleKey(event.handle) === key), false, "The abandoned request must never enter signing");
    session.coverage.add("abandoned-popup-review");
}

async function manualSwitchCoalescing(session) {
    const tab = session.tabs[0];
    const child = session.child("bridge");
    const admissions = () => child.events.filter(event => event.event === "admission" && event.details.name === "switchAccount");
    session.browser.toolbar(tab.id);
    await session.pumpUntil(() => admissions().length === 1, {advance: true});
    await session.pump();
    await session.inspect();
    session.browser.toolbar(tab.id);
    await session.pumpUntil(() => admissions().length === 2, {advance: true});
    await session.pump();
    const [first, second] = admissions().map(event => event.details);
    assert.notEqual(first.enqueueAttempt, second.enqueueAttempt, "Each toolbar click must make a fresh admission attempt");
    assert.notEqual(first.payloadDigest, second.payloadDigest, "Fresh toolbar requests must retain their distinct fingerprints");
    assert.equal(handleKey(first.handle), handleKey(second.handle), "Consecutive toolbar clicks must reuse the pending request");
    const request = await awaitReview(session, "unknown", {name: "switchAccount"});
    assert.equal(handleKey(request.handle), handleKey(first.handle));
    await session.quiesce();
    session.coverage.add("manual-switch-coalescing");
}

export async function runMandatory(session, scenario) {
    validateMandatoryScenario(scenario);
    const specification = scenario.mandatory;
    session.currentAction = specification;
    session.record({type: "mandatory", specification});
    switch (specification.kind) {
    case "success": await success(session); break;
    case "crash": await crash(session, specification); break;
    case "competition": await competition(session); break;
    case "consentReplay": await consentReplay(session); break;
    case "revocationCrash": await revocationCrash(session); break;
    case "authenticationCancellation": await authenticationCancellation(session); break;
    case "chainSwitchAuthentication": await chainSwitchAuthentication(session); break;
    case "revocationBeforeSigning": await revocationBeforeSigning(session); break;
    case "retryRequiredFocus": await retryRequiredFocus(session); break;
    case "editedReview": await editedReview(session); break;
    case "abandonedPopupReview": await abandonedPopupReview(session); break;
    case "manualSwitchCoalescing": await manualSwitchCoalescing(session); break;
    default: throw new Error("Unknown mandatory scenario");
    }
    session.check();
}
