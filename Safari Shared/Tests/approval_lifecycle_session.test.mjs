import assert from "node:assert/strict";
import {createRequire} from "node:module";
import test from "node:test";
import {BrowserLifecycle} from "../../Scripts/approval_lifecycle/browser.mjs";
import {LifecycleSession} from "../../Scripts/approval_lifecycle/session.mjs";
import {LifecycleFailure} from "../../Scripts/approval_lifecycle/scheduler.mjs";
import {handleKey} from "../../Scripts/approval_lifecycle/oracle.mjs";

const require = createRequire(new URL("../Inpage Provider/package.json", import.meta.url));
const {keccak_256} = require("@noble/hashes/sha3");
const {ed25519} = require("@noble/curves/ed25519");
const {secp256k1} = require("@noble/curves/secp256k1");
const {Keypair, SystemProgram, Transaction} = require("@solana/web3.js");
const base58Module = require("bs58");
const base58 = base58Module.default || base58Module;

test("launch acknowledgement does not require a fresh receipt when an existing route is reused", async () => {
    const session = new LifecycleSession({seed: 1, mode: "native"});
    const commands = [], releases = [];
    const identity = {instanceIdentifier: "fixture-runtime"};
    session.children.set("approval", {ready: {identity}, command: async (...arguments_) => { commands.push(arguments_); },
        waitEvent: async () => { throw new Error("A reused route need not publish another receipt"); }});
    const bridge = {epoch: "bridge-1", role: "bridge", release: (...arguments_) => releases.push(arguments_)};
    await session.nativeEvent({event: "launch", gate: "launch-one", details: {url: "bigwallet://agent/approval?workflowVersion=4&id=1"}}, bridge);
    assert.deepEqual(commands, [["route", {url: "bigwallet://agent/approval?workflowVersion=4&id=1"}]]);
    assert.deepEqual(releases, [["launch-one", {success: true, identity}]]);
});

test("an intentional peer restart returns launch failure without killing the healthy bridge", async () => {
    for (const duringCommand of [false, true]) {
        const session = new LifecycleSession({seed: 1, mode: "native"});
        const releases = [];
        session.children.set("approval", {expectedExit: !duringCommand,
            command: async () => { throw new LifecycleFailure("process-restarted", "Intentional peer restart"); }});
        const bridge = {epoch: "bridge-1", role: "bridge", release: (...arguments_) => releases.push(arguments_)};
        await session.nativeEvent({event: "launch", gate: "launch-one", details: {url: "bigwallet://agent/approval"}}, bridge);
        assert.deepEqual(releases, [["launch-one", {success: false}]]);
    }
    const session = new LifecycleSession({seed: 1, mode: "native"});
    session.children.set("approval", {command: async () => { throw new LifecycleFailure("protocol", "Malformed worker reply"); }});
    await assert.rejects(session.nativeEvent({event: "launch", details: {url: "bigwallet://agent/approval"}}, {role: "bridge", epoch: "bridge-1"}),
        error => error.invariant === "protocol");
});

test("fault coverage records actual message loss rather than an unused fault rule", () => {
    const session = new LifecycleSession({seed: 1, mode: "native"});
    const browser = new BrowserLifecycle({scheduler: session.scheduler, trace: event => session.record(event), native: async () => ({})});
    browser.addFault({channel: "native", phase: "request", action: "drop", sourceAction: 3});
    assert.equal(session.coverage.has("action:drop"), false);
    void browser.nativeMessage({id: null}, "worker", {subject: "getLatestConfiguration", id: 1}, () => true);
    assert.equal(session.coverage.has("action:drop"), true);
    assert.equal(session.coverage.has("fault:native:request:drop"), true);
    assert.equal(typeof session.faultTargets[3], "string");
    browser.close();
});

test("revocation includes automatic signer checkpoints only while their release is pending", async () => {
    const key = Buffer.alloc(32, 2), message = Buffer.from([1, 2, 3]);
    const address = Keypair.fromSeed(key).publicKey.toBase58();
    const result = base58.encode(ed25519.sign(message, key));
    const handle = {id: 1, token: "signing", profileIdentifier: "00000000-0000-0000-0000-000000000001"};
    const configurationKey = "https://one.example";
    for (const checkpoint of ["signer.before", "signer.after"]) {
        for (const released of [false, true]) {
            for (const removal of [false, true]) {
                const session = new LifecycleSession({seed: 1, mode: "native"});
                session.ledger = {append() {}};
                const child = {role: "approval", epoch: "approval-1", release() {}};
                session.oracle.register({handle, configurationKey, provider: "solana", name: "signMessage", account: address});
                session.oracle.approvalIntent({handle, label: "approved"});
                session.oracle.acceptConsent({handle, label: "approved"});
                session.nativeRequests.set(handleKey(handle), {provider: "solana", name: "signMessage",
                    expectedBody: {publicKey: address, object: {params: {message: "0x010203"}}}});
                const details = {handle, executionID: "execution", approvedAccount: address};
                const signed = {event: "checkpoint", gate: "after", details: {...details, name: "signer.after",
                    succeeded: true, response: {kind: "result", result}}};
                await session.nativeEvent({event: "checkpoint", gate: "before", details: {...details, name: "signer.before"}}, child);
                if (checkpoint === "signer.after") {
                    await session.scheduler.deliver();
                    await session.nativeEvent(signed, child);
                }
                assert.equal(session.gates.size, 0);
                if (released) { await session.scheduler.deliver(); }
                await session.nativeEvent({event: "checkpoint", details: {name: "revocation.after", ...(removal ?
                    {removals: [{kind: "accounts", accounts: [{coin: "solana", address}]}]} :
                    {profileIdentifier: handle.profileIdentifier, configurationKey, provider: "solana"})}}, child);
                const request = session.oracle.requests.get(handleKey(handle));
                assert.equal(request.definitelyRevoked, !released);
                if (checkpoint === "signer.before") {
                    if (!released) { await session.scheduler.deliver(); }
                    if (released) { await session.nativeEvent(signed, child); }
                    else { await assert.rejects(session.nativeEvent(signed, child), error => error.invariant === "revocation"); }
                } else {
                    const commit = () => session.oracle.checkpoint({...details, epoch: child.epoch});
                    if (released) { commit(); }
                    else { assert.throws(commit, error => error.invariant === "revocation"); }
                }
            }
        }
    }
});

test("readiness recovery advances to transport timers more than one second away", async () => {
    const session = new LifecycleSession({seed: 1, mode: "native", timeout: 1000});
    let delivered = false;
    session.scheduler.schedule(() => { delivered = true; }, 5000, "document");
    await session.pumpUntil(() => delivered, {advance: true});
    assert.equal(session.scheduler.monotonic, 5000);
});

test("saved scheduling decisions form an ordered prefix that permits healthy continuation", () => {
    const decisions = [
        {phase: 0, type: "delivery", ordinal: 0, choice: "saved-delivery"},
        {phase: 1, type: "release-gate", ordinal: 0, choice: null},
    ];
    const session = new LifecycleSession({seed: 1, mode: "native", decisions});
    session.scheduler.phase = 0;
    assert.equal(session.decision("delivery", "proposed-delivery"), "saved-delivery");
    session.scheduler.phase = 1;
    assert.equal(session.decision("release-gate", "proposed-gate"), null);
    assert.equal(session.decision("release-gate", "new-gate"), "new-gate");
    session.scheduler.phase = 2;
    assert.equal(session.decision("delivery", "new-delivery"), "new-delivery");
    assert.deepEqual(session.decisions, [...decisions,
        {phase: 1, type: "release-gate", ordinal: 1, choice: "new-gate"},
        {phase: 2, type: "delivery", ordinal: 0, choice: "new-delivery"},
    ]);
});

test("recorded scheduling decisions cannot be skipped or reordered before the prefix ends", () => {
    for (const change of [{phase: 1}, {type: "release-gate"}, {ordinal: 1}]) {
        const session = new LifecycleSession({seed: 1, mode: "native", decisions: [
            {phase: 0, type: "delivery", ordinal: 0, choice: "first", ...change},
            {phase: 0, type: "delivery", ordinal: 0, choice: "later"},
        ]});
        session.scheduler.phase = 0;
        assert.throws(() => session.decision("delivery", "proposed"), error => error.invariant === "replay-schedule");
        assert.equal(session.decisions.length, 0);
    }
});

function recoverySession(requests, available = true) {
    const session = new LifecycleSession({seed: 1, mode: "native"});
    session.browser = {faults: [], operations: new Map(), snapshot: () => [], wake() {}};
    session.pump = async () => {};
    session.inspect = async () => { session.lastInspectionAvailable = available; return requests; };
    session.decide = async () => false;
    session.advance = async () => {};
    return session;
}

test("an abandoned browser operation cannot hide a native execution that remains active", async () => {
    for (const request of [{phase: "approving"}, {phase: "queued", presentation: "waiting"}]) {
        const session = recoverySession([request]);
        session.browser.operations.set("abandoned", {status: "abandoned"});
        await assert.rejects(session.quiesce(), error => error.invariant === "progress");
    }
    await recoverySession([{phase: "queued", presentation: "review"}]).quiesce();
    await assert.rejects(recoverySession([{phase: "responded"}], false).quiesce(), error => error.invariant === "progress");
});

test("gate preparation can drain reviews while ordinary recovery leaves them available", async () => {
    for (const mode of ["native", "popup"]) {
        for (const rejectReviews of [false, true]) {
            const request = {phase: "queued", presentation: "review", handle: {id: 1, token: "pending", profileIdentifier: null}};
            const session = recoverySession([request]);
            session.mode = mode;
            Object.assign(session.browser, {
                closePopup() {}, async openPopup() {},
                popupRequest: () => ({id: 1, requestToken: "pending"}),
                popupReviewing: () => true,
                popupState: () => ({review: {reviewToken: "review"}}),
            });
            const decisions = [];
            session.decide = async (_, decision, current) => {
                decisions.push(decision);
                current.phase = "responded";
            };
            await session.quiesce({rejectReviews});
            assert.deepEqual(decisions, rejectReviews ? ["reject"] : []);
            assert.equal(request.phase, rejectReviews ? "responded" : "queued");
        }
    }
});

async function terminalPopupRecoverySession({queuedSuccessor = false} = {}) {
    const session = new LifecycleSession({seed: 1, mode: "popup", timeout: 1000});
    const profileIdentifier = "00000000-0000-0000-0000-000000000001";
    const terminal = {phase: "queued", provider: "solana", name: "signMessage", configurationKey: "https://one.example",
        handle: {id: 4, token: "00000000-0000-0000-0000-000000000004", profileIdentifier}};
    const next = {phase: "queued", provider: "ethereum", name: "requestAccounts", configurationKey: terminal.configurationKey,
        handle: {id: terminal.handle.id, token: "00000000-0000-0000-0000-000000000001", profileIdentifier}};
    const other = {...next, handle: {...next.handle, profileIdentifier: "00000000-0000-0000-0000-000000000002"}};
    let pending = terminal, reviewedPopup;
    session.browser = new BrowserLifecycle({scheduler: session.scheduler, mode: "popup", native: async (message, profile) => {
        const current = profile === profileIdentifier ? pending : queuedSuccessor ? other : null;
        if (message.subject === "getLatestConfiguration") { return {id: message.id, state: disconnected}; }
        if (message.subject === "getRecoveryRequests") { return {id: message.id, requests: []}; }
        if (message.subject === "getPendingRequests") {
            return {requests: current ? [{id: current.handle.id, requestToken: current.handle.token,
                provider: current.provider, configurationKey: current.configurationKey, host: "one.example",
                receivedAt: session.scheduler.now, sequence: 1}] : [], completedResponses: []};
        }
        if (message.subject === "getApprovalState") {
            return {status: "ok", approval: {id: current.handle.id, host: "one.example", state: "review", actions: ["approve", "reject"], review: {
                kind: current === terminal ? "signMessage" : "accountSelection", title: "Review",
                reviewToken: "00000000-0000-0000-0000-000000000101",
                ...(current === terminal ? {meta: "0x010203", account: {name: "Account", croppedAddress: "1234"}} :
                    {allowsEmptySelection: false, canSelectNetwork: false, accounts: []}),
            }}};
        }
        throw new Error(`Unexpected popup command ${message.subject}`);
    }});
    session.inspect = async () => {
        if (!reviewedPopup) {
            await session.pumpUntil(() => session.browser.popupRequest(profileIdentifier)?.requestToken === terminal.handle.token &&
                session.browser.popupState(profileIdentifier)?.state === "review");
            reviewedPopup = session.browser.profile(profileIdentifier).popup;
            terminal.phase = "responded";
            if (queuedSuccessor) { pending = next; }
        }
        session.lastInspectionAvailable = true;
        return queuedSuccessor ? [terminal, next, other] : [terminal];
    };
    const tab = session.browser.openTab({profileIdentifier, url: "https://one.example/page"});
    await session.pumpUntil(() => session.browser.configurationReady(tab.id, disconnected));
    return {session, terminal, next, other, profileIdentifier, reviewedPopup: () => reviewedPopup, queueNext: () => { pending = next; }};
}

test("drained popup recovery closes a terminal review before the next approval", async () => {
    const {session, next, profileIdentifier, reviewedPopup, queueNext} = await terminalPopupRecoverySession();
    try {
        await session.quiesce({rejectReviews: true});
        assert.equal(reviewedPopup().alive, false);
        assert.equal(session.browser.profile(profileIdentifier).popup, null);
        assert.equal(session.scheduler.pending({owner: reviewedPopup().owner}).length, 0);
        queueNext();
        const reopened = await session.browser.openPopup(profileIdentifier);
        await session.pumpUntil(() => session.browser.popupRequest(profileIdentifier)?.requestToken === next.handle.token &&
            session.browser.popupState(profileIdentifier)?.state === "review");
        assert.notEqual(reopened, reviewedPopup());
        assert.equal(session.browser.popupRequest(profileIdentifier).id, next.handle.id);
    } finally { session.browser.close(); }
});

test("popup recovery reopens an explicitly terminal head and preserves a queued successor with the same id", async () => {
    const {session, terminal, next, other, profileIdentifier, reviewedPopup} = await terminalPopupRecoverySession({queuedSuccessor: true});
    try {
        assert.equal(terminal.handle.id, next.handle.id);
        assert.notEqual(terminal.handle.token, next.handle.token);
        await session.quiesce();
        assert.equal(terminal.phase, "responded");
        assert.equal(reviewedPopup().alive, false);
        assert.equal(session.browser.popupRequest(profileIdentifier).requestToken, next.handle.token);
        assert.equal(session.browser.profile(profileIdentifier).popup.alive, true);
        assert.equal(session.browser.profile(profileIdentifier).popupSerial, 2);
        assert.equal(session.browser.profile(other.handle.profileIdentifier).popupSerial, 1);
        assert.equal(session.browser.profile(other.handle.profileIdentifier).popup.alive, true);
        assert.equal(other.phase, "queued");
        assert.equal(next.phase, "queued");
        assert.equal(session.background.size, 0);
        assert.equal(session.scheduler.pending({kind: "message"}).length, 0);
    } finally { session.browser.close(); }
});

test("popup recovery requires exact terminal evidence and drained work before replacing a head", async () => {
    for (const guard of ["queued", "approving", "missing", "otherToken", "otherProfile", "unavailable", "background", "messages"]) {
        const profileIdentifier = "00000000-0000-0000-0000-000000000001";
        const handle = {id: 4, token: "displayed", profileIdentifier};
        const evidence = {phase: ["queued", "approving"].includes(guard) ? guard : "responded", handle: {...handle}};
        if (guard === "otherToken") { evidence.handle.token = "different"; }
        if (guard === "otherProfile") { evidence.handle.profileIdentifier = "00000000-0000-0000-0000-000000000002"; }
        const successor = {phase: "queued", handle: {...handle, token: "next"}};
        const session = recoverySession(guard === "missing" ? [successor] : [evidence, successor], guard !== "unavailable");
        session.mode = "popup";
        const open = new Set(), closes = [];
        Object.assign(session.browser, {
            closePopup(profile) { closes.push(profile); open.delete(profile); },
            async openPopup(profile) { open.add(profile); },
            popupRequest: profile => profile === profileIdentifier ? {id: handle.id, requestToken: handle.token} : null,
            popupReviewing: () => true,
            popupState: () => ({review: {reviewToken: "review"}}),
        });
        if (guard === "background") { session.track(new Promise(() => {})); }
        if (guard === "messages") { session.scheduler.schedule(() => {}, 0, "fixture", "message"); }
        await assert.rejects(session.quiesce(), error => error.invariant === "progress");
        assert.equal(open.has(profileIdentifier), true, guard);
        assert.equal(closes.filter(profile => profile === profileIdentifier).length, 1, guard);
        assert.equal(successor.phase, "queued", guard);
    }
});

test("popup recovery retains live reviews and cannot discard unresolved work", async () => {
    for (const [phase, rejectReviews, available, succeeds] of [
        ["queued", false, true, true], ["queued", true, true, false],
        ["approving", true, true, false], ["responded", true, false, false],
    ]) {
        const profileIdentifier = "00000000-0000-0000-0000-000000000001";
        const request = {phase, handle: {id: 4, token: "pending", profileIdentifier}};
        const session = recoverySession([request], available);
        session.mode = "popup";
        const open = new Set(), closes = [];
        Object.assign(session.browser, {
            closePopup(profile) { closes.push(profile); open.delete(profile); },
            async openPopup(profile) { open.add(profile); },
            popupRequest: () => ({id: request.handle.id, requestToken: request.handle.token}),
            popupReviewing: () => true,
            popupState: () => ({review: {reviewToken: "review"}}),
        });
        if (succeeds) { await session.quiesce({rejectReviews}); }
        else { await assert.rejects(session.quiesce({rejectReviews}), error => error.invariant === "progress"); }
        assert.equal(open.has(profileIdentifier), true);
        assert.equal(closes.filter(profile => profile === profileIdentifier).length, 1);
        assert.equal(request.phase, phase);
    }
});

test("quiescence waits for tracked native work even when browser and stored requests are terminal", async () => {
    const session = recoverySession([{phase: "responded"}]);
    let finish;
    session.track(new Promise(resolve => { finish = resolve; }));
    let turns = 0;
    session.advance = async () => { turns += 1; finish(); await Promise.resolve(); };
    await session.quiesce();
    assert.ok(turns > 0);
    assert.equal(session.background.size, 0);
});

test("recovery focuses queued native requests whose approval coordinator was lost before deciding", async () => {
    for (const [provider, name] of [["unknown", "switchAccount"], ["ethereum", "signPersonalMessage"], ["solana", "signMessage"]]) {
        for (const rejectReviews of [false, true]) {
            const request = {phase: "queued", provider, name, configurationKey: "https://one.example",
                handle: {id: 7, token: "12345678-1234-1234-1234-123456789abc", profileIdentifier: "00000000-0000-0000-0000-000000000001"}};
            const session = recoverySession([request]);
            session.browser.operations.set("retired-provider", {status: "rejected", error: {code: 4900}});
            const commands = [], decisions = [];
            session.children.set("bridge", {ready: {workflowVersion: 4}, command: async (operation, payload) => {
                if (operation === "checkpoints") { return {}; }
                commands.push({operation, payload});
                request.presentation = "review";
                return {id: request.handle.id, opened: true};
            }});
            session.decide = async (_, decision, current) => {
                assert.equal(current.presentation, "review", "A missing coordinator must be focused before a decision");
                decisions.push(decision);
                current.phase = "responded";
            };
            await session.quiesce({rejectReviews});
            assert.deepEqual(commands, [{operation: "native", payload: {
                message: {subject: "showApproval", id: 7, requestToken: request.handle.token, configurationKey: request.configurationKey,
                    workflowVersion: 4, __bwPrivateBrowsing: false},
                profileIdentifier: request.handle.profileIdentifier, privateBrowsing: false,
            }}]);
            assert.deepEqual(decisions, rejectReviews ? ["reject"] : []);
            assert.equal(request.phase, rejectReviews ? "responded" : "queued");
            assert.equal(session.background.size, 0);
        }
    }
});

test("recovery refocuses paused native requests without a presentation before deciding", async () => {
    for (const [provider, name] of [["unknown", "switchAccount"], ["ethereum", "signPersonalMessage"], ["solana", "signMessage"]]) {
        for (const rejectReviews of [false, true]) {
            const request = {phase: "queued", provider, name, presentation: "none", coordinatorPhase: "paused", revision: 0,
                configurationKey: "https://one.example",
                handle: {id: 7, token: "12345678-1234-1234-1234-123456789abc", profileIdentifier: "00000000-0000-0000-0000-000000000002"}};
            const session = recoverySession([request]);
            const commands = [], decisions = [];
            session.children.set("bridge", {ready: {workflowVersion: 4}, command: async (operation, payload) => {
                if (operation === "checkpoints") { return {}; }
                commands.push({operation, payload});
                Object.assign(request, {presentation: "review", coordinatorPhase: "reviewing", revision: 1});
                return {id: request.handle.id, opened: true};
            }});
            session.decide = async (_, decision, current) => {
                assert.equal(current.presentation, "review", "A paused coordinator must recover before a decision");
                assert.equal(current.revision, 1, "The decision must use the resumed presentation revision");
                decisions.push(decision);
                current.phase = "responded";
            };
            await session.quiesce({rejectReviews});
            assert.deepEqual(commands, [{operation: "native", payload: {
                message: {subject: "showApproval", id: request.handle.id, requestToken: request.handle.token,
                    configurationKey: request.configurationKey, workflowVersion: 4, __bwPrivateBrowsing: false},
                profileIdentifier: request.handle.profileIdentifier, privateBrowsing: false,
            }}]);
            assert.deepEqual(decisions, rejectReviews ? ["reject"] : []);
            assert.equal(request.phase, rejectReviews ? "responded" : "queued");
            assert.equal(session.background.size, 0);
        }
    }
});

test("recovery does not refocus an existing native presentation", async () => {
    for (const [provider, name] of [["unknown", "switchAccount"], ["ethereum", "signPersonalMessage"], ["solana", "signMessage"]]) {
        for (const presentation of ["none", "waiting", "retryRequired", "review"]) {
            const request = {phase: "queued", provider, name, presentation, coordinatorPhase: presentation === "retryRequired" ? "paused" : undefined};
            const session = recoverySession([request]);
            session.sendNative = () => { throw new Error("Existing coordinator must retain its presentation"); };
            session.decide = async () => { request.phase = "responded"; };
            await session.quiesce();
            assert.equal(request.presentation, presentation);
        }
    }
});

test("recovery cannot refocus a native coordinator without proof that it is paused", async () => {
    for (const coordinatorPhase of [undefined, "registered", "validating", "acquiringReceipt", "awaitingAuthentication", "waiting", "rejecting"]) {
        for (const rejectReviews of [false, true]) {
            const request = {phase: "queued", presentation: "none", coordinatorPhase, revision: 0};
            const session = recoverySession([request]);
            session.sendNative = () => { throw new Error("An active or unobserved coordinator must not be refocused"); };
            await assert.rejects(session.quiesce({rejectReviews}), error => error.invariant === "progress");
            assert.equal(request.presentation, "none");
            assert.equal(request.coordinatorPhase, coordinatorPhase);
        }
    }
});

test("recovery cannot relaunch or hide an active native execution without a presentation", async () => {
    for (const [provider, name] of [["ethereum", "signPersonalMessage"], ["solana", "signMessage"]]) {
        for (const rejectReviews of [false, true]) {
            for (const presentation of [undefined, "none"]) {
                const request = {phase: "approving", provider, name, presentation, coordinatorPhase: "paused"};
                const session = recoverySession([request]);
                session.browser.operations.set("retired-provider", {status: "rejected", error: {code: 4900}});
                session.sendNative = () => { throw new Error("Active execution must not be relaunched"); };
                await assert.rejects(session.quiesce({rejectReviews}), error => error.invariant === "progress");
                assert.equal(request.phase, "approving");
            }
        }
    }
});

test("recovery waits for native admissions after navigation even when their browser replies are dropped", async () => {
    const session = new LifecycleSession({seed: 1, mode: "native", timeout: 1000});
    const state = {context: "a".repeat(64), revisions: {ethereum: 0, solana: 0}, ethereum: {address: "", chainId: "0x1"}, solana: null};
    let finish, completed = false, recoveryTurns = 0;
    session.children.set("bridge", {ready: {workflowVersion: 4}, command: async (operation, payload) => {
        if (operation !== "native") { return {}; }
        const message = payload.message;
        if (message.subject === "getLatestConfiguration") { return {id: message.id, state}; }
        if (message.subject === "getRecoveryRequests") { return {id: message.id, requests: []}; }
        return new Promise(resolve => { finish = () => { completed = true; resolve({id: message.id}); }; });
    }});
    session.browser = new BrowserLifecycle({scheduler: session.scheduler,
        native: (message, profileIdentifier) => session.sendNative(message, profileIdentifier)});
    session.inspect = async () => { session.lastInspectionAvailable = true; return []; };
    const advance = session.advance.bind(session);
    session.advance = async milliseconds => { recoveryTurns += 1; finish(); await advance(milliseconds); };
    try {
        const tab = session.browser.openTab({url: "https://one.example/page"});
        session.tabs = [tab];
        await session.pumpUntil(() => session.browser.configurationReady(tab.id, state));
        session.browser.addFault({channel: "native", phase: "reply", subject: "requestAccounts", action: "drop"});
        const operation = session.browser.request(tab.id, "ethereum", {method: "eth_requestAccounts"});
        await session.pumpUntil(() => !!finish);
        session.browser.navigate(tab.id, "https://other.example/page");
        await session.quiesce();
        assert.equal(operation.status, "abandoned");
        assert.equal(completed, true);
        assert.ok(recoveryTurns > 0);
        assert.equal(session.background.size, 0);
        assert.equal(session.scheduler.pending({kind: "message"}).length, 0);
    } finally { session.browser.close(); }
});

test("configuration refresh cannot hide newly started native work during recovery", async () => {
    const session = recoverySession([]);
    session.tabs = [{alive: true}];
    session.refreshTab = async () => { session.track(new Promise(() => {})); };
    await assert.rejects(session.quiesce(), error => error.invariant === "progress");
});

test("recovery drains slow native reads without continually requesting another worker pass", async () => {
    const session = new LifecycleSession({seed: 1, mode: "native", timeout: 1000});
    const state = {context: "a".repeat(64), revisions: {ethereum: 0, solana: 0}, ethereum: {address: "", chainId: "0x1"}, solana: null};
    const replies = [];
    let deferRecovery = false, reads = 0;
    session.children.set("bridge", {ready: {workflowVersion: 4}, command: async (operation, payload) => {
        if (operation !== "native") { return {}; }
        const message = payload.message;
        if (message.subject === "getLatestConfiguration") { return {id: message.id, state}; }
        assert.equal(message.subject, "getRecoveryRequests");
        if (!deferRecovery) { return {id: message.id, requests: []}; }
        reads += 1;
        return new Promise(resolve => { replies.push(() => resolve({id: message.id, requests: []})); });
    }});
    session.browser = new BrowserLifecycle({scheduler: session.scheduler,
        native: (message, profileIdentifier) => session.sendNative(message, profileIdentifier)});
    session.inspect = async () => {
        for (const reply of replies.splice(0)) { reply(); }
        session.lastInspectionAvailable = true;
        return [];
    };
    try {
        const tab = session.browser.openTab({url: "https://one.example/page"});
        session.tabs = [tab];
        await session.pumpUntil(() => session.browser.configurationReady(tab.id, state));
        await session.pump();
        deferRecovery = true;
        session.browser.wake();
        await session.pumpUntil(() => replies.length > 0);
        session.browser.wake();
        await session.quiesce();
        assert.equal(reads, 2);
        assert.equal(session.background.size, 0);
    } finally { session.browser.close(); }
});

test("tracked native failures retain fatal diagnostics while restarted commands retire", async () => {
    for (const invariant of ["protocol", "process-restarted"]) {
        const session = new LifecycleSession({seed: 1, mode: "native"});
        const error = new LifecycleFailure(invariant, "Native command failed");
        session.children.set("bridge", {command: async () => { throw error; }});
        await assert.rejects(session.sendNative({subject: "getRecoveryRequests"}, null), value => value === error);
        await Promise.resolve();
        assert.equal(session.background.size, 0);
        if (invariant === "protocol") { assert.throws(() => session.check(), value => value === error); }
        else { session.check(); }
    }
});

test("committed grant observations precede browser delivery and preserve their request handle", async () => {
    const session = new LifecycleSession({seed: 1, mode: "native"});
    const profileIdentifier = "00000000-0000-0000-0000-000000000001";
    const message = {subject: "pollResponse", id: 1, requestToken: "request"};
    const state = {context: "context", revisions: {ethereum: 1, solana: 0}, ethereum: {address: "0xab", chainId: "0x1"}, solana: null};
    const observed = [];
    session.oracle.recordCommittedGrant = value => observed.push(structuredClone(value));
    let reply = {state, response: {kind: "result", approvalCommitted: true}};
    session.children.set("bridge", {command: async () => reply});
    assert.equal(await session.sendNative(message, profileIdentifier), reply);
    assert.deepEqual(observed, [{handle: {id: 1, token: "request", profileIdentifier}, state}]);
    for (const response of [{kind: "error", approvalCommitted: true}, {kind: "result", approvalCommitted: false}]) {
        reply = {state, response};
        await session.sendNative(message, profileIdentifier);
    }
    reply = {state, response: {kind: "result", approvalCommitted: true}};
    await session.sendNative({...message, subject: "getLatestConfiguration"}, profileIdentifier);
    assert.equal(observed.length, 1);
    const failure = new LifecycleFailure("consent", "Invalid committed grant");
    session.oracle.recordCommittedGrant = () => { throw failure; };
    await assert.rejects(session.sendNative(message, profileIdentifier), error => error === failure);
    assert.throws(() => session.check(), error => error === failure);
});

test("retired popup promises do not keep recovery alive but cannot hide native work", async () => {
    for (const phase of ["responded", "approving"]) {
        const session = recoverySession([{phase}]);
        const popup = {alive: true};
        const profile = {popup};
        session.browser.profile = () => profile;
        session.trackPopup(new Promise(() => {}), null);
        popup.alive = false;
        profile.popup = {alive: true};
        if (phase === "responded") { await session.quiesce(); }
        else { await assert.rejects(session.quiesce(), error => error.invariant === "progress"); }
        assert.equal(session.background.size, 0);
    }
});

test("persistence fault coverage requires an observed injected failure", async () => {
    const session = new LifecycleSession({seed: 1, mode: "native"});
    session.ledger = {append() {}};
    const child = {role: "bridge", epoch: "bridge-1"};
    await session.nativeEvent({event: "checkpoint", details: {name: "persistence.rename.after"}}, child);
    assert.equal(session.coverage.has("action:failPersistence"), false);
    await session.nativeEvent({event: "checkpoint", details: {name: "persistence.rename.after", fault: true}}, child);
    assert.equal(session.coverage.has("action:failPersistence"), true);
    assert.equal(session.coverage.has("fault:persistence:persistence.rename.after"), true);
});

test("wallet actions recover only from the expected native store-unavailable error", async () => {
    for (const kind of ["removeAccount", "restoreAccount"]) {
        for (const failure of ["unavailable", "other-native", "other-error"]) {
            const session = new LifecycleSession({seed: 1, mode: "native"});
            const error = Object.assign(new Error(failure), {native: failure !== "other-error",
                details: failure === "other-native" ? "other failure" : "unavailable"});
            session.accounts = ["ethereum", "solana"].map(coin => ({walletID: "fixture-multicoin", coin, address: coin}));
            session.tabs = [{profile: {id: null}}];
            session.snapshots.set(null, {accounts: session.accounts});
            session.children.set("bridge", {command: async () => { throw error; }});
            let inspected = false;
            session.inspect = async () => { inspected = true; return []; };
            session.pump = async () => {};
            session.oracle.revoke = () => { assert.fail("Failed wallet mutations must not revoke oracle permission"); };
            const action = session.action({kind, tab: 0, selector: 0});
            if (failure === "unavailable") {
                await action;
                assert.equal(inspected, true);
                assert.equal(session.trace.find(event => event.type === "action-result").exercised, false);
                assert.equal(session.coverage.has(`action:${kind}`), false);
            } else { await assert.rejects(action, value => value === error); }
        }
    }
});

test("admission correlation separates transport kinds and provider generations when wire IDs repeat", async () => {
    const session = new LifecycleSession({seed: 1, mode: "popup"});
    const handle = {id: 2, token: "00000000-0000-0000-0000-000000000002", profileIdentifier: null};
    const message = {id: 2, provider: "solana", name: "signTransaction", configurationKey: "https://one.example", body: {publicKey: "account"}};
    const operation = {document: "document", provider: "solana", payload: {method: "signTransaction"}, wireID: 2, wireKind: "request", providerGeneration: "current"};
    const disconnect = {...operation, wireKind: "disconnect"};
    const retired = {...operation, providerGeneration: "retired"};
    session.admissions.set("attempt", {message});
    session.tabs = [{document: {owner: "document", contentContext: {bigWalletRequests: new Map([["current", {enqueueAttempt: "attempt", generation: "current", message}]])}}}];
    session.browser = {operations: new Map([["retired", retired], ["signing", operation], ["disconnect", disconnect]])};
    await session.nativeEvent({event: "admission", details: {handle, enqueueAttempt: "attempt", configurationKey: message.configurationKey,
        provider: "solana", name: "signTransaction", payloadDigest: "payload"}}, {role: "bridge", epoch: "bridge-1"});
    assert.deepEqual(operation.handle, handle);
    assert.equal(disconnect.handle, undefined);
    assert.equal(retired.handle, undefined);
});

test("admission identity must match the captured browser attempt", async () => {
    const profileIdentifier = "00000000-0000-0000-0000-000000000001";
    const handle = {id: 2, token: "request", profileIdentifier};
    const message = {id: 2, provider: "solana", name: "signMessage", configurationKey: "https://one.example"};
    const details = {handle, enqueueAttempt: "attempt", configurationKey: message.configurationKey,
        provider: message.provider, name: message.name, payloadDigest: "payload"};
    for (const change of [
        {handle: {...handle, profileIdentifier: "00000000-0000-0000-0000-000000000002"}},
        {handle: {...handle, id: 3}},
        {configurationKey: "https://two.example"},
        {provider: "ethereum"},
        {name: "signTransaction"},
    ]) {
        const session = new LifecycleSession({seed: 1, mode: "native"});
        session.admissions.set("attempt", {message, profileIdentifier});
        await assert.rejects(session.nativeEvent({event: "admission", details: {...details, ...change}}, {role: "bridge", epoch: "bridge-1"}),
            error => error.invariant === "isolation");
        assert.equal(session.oracle.requests.size, 0);
    }
});

test("manual switch admission may coalesce a new browser ID into its existing handle", async () => {
    const session = new LifecycleSession({seed: 1, mode: "native"});
    const handle = {id: 1, token: "coalesced", profileIdentifier: null};
    const message = {provider: "unknown", name: "switchAccount", configurationKey: "https://one.example"};
    for (const id of [1, 2]) {
        session.admissions.set(`attempt-${id}`, {message: {...message, id}, profileIdentifier: null});
        await session.nativeEvent({event: "admission", details: {...message, handle, enqueueAttempt: `attempt-${id}`, payloadDigest: `payload-${id}`}},
            {role: "bridge", epoch: "bridge-1"});
    }
    assert.equal(session.oracle.requests.size, 1);
    assert.equal(session.oracle.admissions.size, 2);
});

test("browser settlement cannot borrow admission from another profile, origin, or provider", () => {
    const profileIdentifier = "00000000-0000-0000-0000-000000000001";
    const handle = {id: 1, token: "request", profileIdentifier};
    for (const change of [{profileIdentifier: null}, {url: "https://two.example/page"}, {provider: "solana"}]) {
        const session = new LifecycleSession({seed: 1, mode: "native"});
        session.oracle.register({handle, configurationKey: "https://one.example", provider: "ethereum", name: "requestAccounts"});
        assert.throws(() => session.observeSettlement({label: "misrouted", profileIdentifier, url: "https://one.example/page", provider: "ethereum",
            payload: {method: "eth_accounts"}, status: "fulfilled", handle, document: "page", currentDocument: "page", result: [], ...change}),
        error => error.invariant === "isolation");
    }
});

test("a successful signing call cannot bypass consent checks when admission correlation is missing", () => {
    for (const [provider, method] of [["ethereum", "personal_sign"], ["ethereum", "eth_sendTransaction"], ["solana", "signMessage"], ["solana", "signTransaction"], ["solana", "signAndSendTransaction"]]) {
        for (const handle of [undefined, {id: 1, token: "unobserved", profileIdentifier: null}]) {
            const session = new LifecycleSession({seed: 1, mode: "native"});
            assert.throws(() => session.observeSettlement({label: "unsigned", provider, payload: {method}, status: "fulfilled", handle}),
                error => error.invariant === "isolation");
        }
    }
    const session = new LifecycleSession({seed: 1, mode: "native"});
    for (const method of ["personal_ecRecover", "eth_accounts", "eth_chainId"]) {
        session.observeSettlement({label: method, provider: "ethereum", payload: {method}, status: "fulfilled", document: "page", currentDocument: "page", result: "value"});
    }
});

const disconnected = {context: "a".repeat(64), revisions: {ethereum: 0, solana: 0}, ethereum: {address: "", chainId: "0x1"}, solana: null};

test("generated connection calls cannot return an account while native and browser state remain disconnected", async () => {
    for (const provider of ["ethereum", "solana"]) {
        const session = new LifecycleSession({seed: 1, mode: "native", timeout: 1000});
        const account = provider === "ethereum" ? "0x" + "1".repeat(40) : Keypair.fromSeed(Buffer.alloc(32, 2)).publicKey.toBase58();
        session.accounts = [{coin: provider, address: account}];
        session.children.set("bridge", {ready: {workflowVersion: 4}, command: async (command, payload) => {
            if (command === "inspect") { return {requests: [], accounts: session.accounts, durableObservationAvailable: true}; }
            if (command !== "native") { return {}; }
            const message = payload.message;
            if (message.subject === "getLatestConfiguration") { return {id: message.id, state: disconnected}; }
            if (message.subject === "getRecoveryRequests") { return {id: message.id, requests: []}; }
            return {id: message.id, state: disconnected, response: {id: message.id, name: message.name, provider,
                kind: "result", result: provider === "ethereum" ? [account] : {publicKey: account}, approvalCommitted: true}};
        }});
        session.children.set("approval", {command: async () => ({requests: []})});
        session.browser = new BrowserLifecycle({scheduler: session.scheduler,
            native: (message, profileIdentifier) => session.sendNative(message, profileIdentifier),
            onNative: event => session.observeNativeMessage(event), onSettlement: operation => session.observeSettlement(operation)});
        const tab = session.browser.openTab();
        session.tabs = [tab];
        try {
            const operation = session.request({tab: 0, provider, method: "connect"});
            await assert.rejects(session.complete(operation, {approve: false, expectedSuccess: true}), error => error.invariant === "consent");
            assert.equal(session.oracle.requests.size, 0);
            assert.equal(session.oracle.approvals.size, 0);
            assert.equal(session.browser.configurationReady(tab.id, disconnected), true);
        } finally { session.browser.close(); }
    }
});

test("existing authorized connections succeed without a new admission before and after provider readiness", async () => {
    for (const provider of ["ethereum", "solana"]) {
        for (const afterReadiness of [false, true]) {
            const session = new LifecycleSession({seed: 1, mode: "native", timeout: 1000});
            const address = provider === "ethereum" ? "0x" + "ab".repeat(20) : Keypair.fromSeed(Buffer.alloc(32, 2)).publicKey.toBase58();
            const state = structuredClone(disconnected);
            state.revisions[provider] = 1;
            if (provider === "ethereum") { state.ethereum.address = address; }
            else { state.solana = {publicKey: address}; }
            const handle = {id: 99, token: "prior-connection", profileIdentifier: null};
            session.oracle.register({handle, configurationKey: "https://one.example", provider, name: provider === "ethereum" ? "requestAccounts" : "connect"});
            session.oracle.approvalIntent({handle, label: "prior-approval", selectedAccounts: [{coin: provider, address}]});
            session.oracle.acceptConsent({handle, label: "prior-approval"});
            session.browser = new BrowserLifecycle({scheduler: session.scheduler, onSettlement: operation => session.observeSettlement(operation), native: async message => {
                if (message.subject === "getLatestConfiguration") { return {id: message.id, state}; }
                if (message.subject === "getRecoveryRequests") { return {id: message.id, requests: []}; }
                return {id: message.id, state, response: {id: message.id, name: message.name, provider, kind: "result",
                    result: provider === "ethereum" ? ["0x" + "AB".repeat(20)] : {publicKey: address}, approvalCommitted: false}};
            }});
            const tab = session.browser.openTab({url: "https://one.example/page"});
            try {
                if (afterReadiness) { await session.scheduler.until(() => session.browser.configurationReady(tab.id, state)); }
                const operation = session.browser.request(tab.id, provider, {method: provider === "ethereum" ? "eth_requestAccounts" : "connect"});
                await session.scheduler.until(() => operation.status !== "pending");
                session.check();
                assert.equal(operation.status, "fulfilled");
                assert.equal(operation.handle, undefined);
                assert.equal(session.oracle.approvals.size, 1);
            } finally { session.browser.close(); }
        }
    }
});

test("connection results match the accepted account selection instead of an unrelated account", () => {
    for (const provider of ["ethereum", "solana"]) {
        const selected = provider === "ethereum" ? "0x" + "1".repeat(40) : Keypair.fromSeed(Buffer.alloc(32, 2)).publicKey.toBase58();
        const other = provider === "ethereum" ? "0x" + "2".repeat(40) : Keypair.fromSeed(Buffer.alloc(32, 3)).publicKey.toBase58();
        for (const consent of ["pending", "accepted", "revoked"]) {
            for (const returned of [selected, other]) {
                const session = new LifecycleSession({seed: 1, mode: "native"});
                const handle = {id: 1, token: "connection", profileIdentifier: null};
                session.oracle.register({handle, configurationKey: "https://one.example", provider, name: provider === "ethereum" ? "requestAccounts" : "connect"});
                if (consent === "revoked") { session.oracle.revoke({profileIdentifier: null, configurationKey: "https://one.example", provider, definite: false}); }
                session.oracle.approvalIntent({handle, label: "selected", selectedAccounts: [{coin: provider, address: selected}]});
                if (consent !== "pending") { session.oracle.acceptConsent({handle, label: "selected"}); }
                const settle = () => session.observeSettlement({label: "connect", provider, handle, url: "https://one.example/page",
                    document: "page", currentDocument: "page", status: "fulfilled",
                    publicState: provider === "ethereum" ? {address: consent === "pending" ? "" : other} : {publicKey: consent === "pending" ? "" : other},
                    payload: {method: provider === "ethereum" ? "eth_requestAccounts" : "connect"},
                    result: provider === "ethereum" ? [returned] : {publicKey: returned}});
                if (consent === "accepted" && returned === selected) { settle(); }
                else { assert.throws(settle, error => error.invariant === "consent"); }
            }
        }
    }
});

test("an older tab snapshot cannot make a never-approved account appear authorized", async () => {
    for (const provider of ["ethereum", "solana"]) {
        const accounts = provider === "ethereum" ? ["0x" + "1".repeat(40), "0x" + "2".repeat(40)] :
            [2, 3].map(value => Keypair.fromSeed(Buffer.alloc(32, value)).publicKey.toBase58());
        for (const address of accounts) {
            const session = new LifecycleSession({seed: 1, mode: "native", timeout: 1000});
            const state = (revision, account) => ({...disconnected,
                revisions: {ethereum: provider === "ethereum" ? revision : 0, solana: provider === "solana" ? revision : 0},
                ethereum: {address: provider === "ethereum" ? account : "", chainId: "0x1"},
                solana: provider === "solana" ? {publicKey: account} : null});
            const handle = {id: 1, token: "approved-account", profileIdentifier: null};
            session.oracle.register({handle, configurationKey: "https://one.example", provider,
                name: provider === "ethereum" ? "requestAccounts" : "connect"});
            session.oracle.approvalIntent({handle, label: "approved", selectedAccounts: [{coin: provider, address: accounts[0]}]});
            session.oracle.acceptConsent({handle, label: "approved"});
            session.oracle.recordCommittedGrant({handle, state: state(1, accounts[0])});
            let current = state(4, accounts[0]);
            session.browser = new BrowserLifecycle({scheduler: session.scheduler,
                onSettlement: operation => session.observeSettlement(operation), native: async message => {
                    if (message.subject === "getLatestConfiguration") { return {id: message.id, state: current}; }
                    if (message.subject === "getRecoveryRequests") { return {id: message.id, requests: []}; }
                    return {id: message.id, state: current, response: {id: message.id, name: message.name, provider,
                        kind: "result", result: provider === "ethereum" ? [address] : {publicKey: address}, approvalCommitted: true}};
                }});
            try {
                const first = session.browser.openTab({url: "https://one.example/first"});
                await session.pumpUntil(() => session.browser.configurationReady(first.id, current));
                current = state(3, address);
                const second = session.browser.openTab({url: "https://one.example/second"});
                await session.scheduler.until(() => session.browser.configurationReady(second.id, current));
                const operation = session.browser.request(second.id, provider, {method: provider === "ethereum" ? "eth_requestAccounts" : "connect"});
                if (address !== accounts[0]) {
                    await assert.rejects(session.pumpUntil(() => operation.status !== "pending"), error => error.invariant === "replay");
                } else {
                    await session.pumpUntil(() => operation.status !== "pending");
                    assert.equal(operation.status, "fulfilled");
                    session.check();
                }
            } finally { session.browser.close(); }
        }
    }
});

async function popupSession() {
    const session = new LifecycleSession({seed: 1, mode: "popup", timeout: 1000});
    const handle = {id: 1, token: "00000000-0000-0000-0000-000000000001", profileIdentifier: null};
    const request = {handle, configurationKey: "https://one.example", provider: "ethereum", name: "requestAccounts"};
    const queued = {id: handle.id, requestToken: handle.token, provider: request.provider, configurationKey: request.configurationKey,
        host: "one.example", receivedAt: session.scheduler.now, sequence: 0};
    const state = {id: handle.id, host: queued.host, state: "review", actions: ["approve", "reject"], review: {
        kind: "accountSelection", title: "Connect", reviewToken: "00000000-0000-0000-0000-000000000101",
        allowsEmptySelection: false, canSelectNetwork: true, networks: [{chainId: "0x1", name: "Ethereum", isSelected: true}],
        accounts: [{walletId: "chosen-wallet", coin: "ethereum", address: "0x" + "1".repeat(40), derivationPath: "path",
            name: "Selected", croppedAddress: "1111", isSelected: true}],
    }};
    session.oracle.register(request);
    session.browser = new BrowserLifecycle({scheduler: session.scheduler, mode: "popup", onNative: event => session.observeNativeMessage(event), native: async message => {
        if (message.subject === "getLatestConfiguration") { return {id: message.id, state: disconnected}; }
        if (message.subject === "getRecoveryRequests") { return {id: message.id, requests: []}; }
        if (message.subject === "getPendingRequests") { return {requests: [queued], completedResponses: []}; }
        if (message.subject === "getApprovalState") { return {status: "ok", approval: state}; }
        if (message.subject === "approveRequest") { return new Promise(() => {}); }
        throw new Error(`Unexpected popup command ${message.subject}`);
    }});
    session.browser.openTab({url: "https://one.example/page"});
    const popup = await session.browser.openPopup();
    await session.pumpUntil(() => session.browser.popupState()?.actions.includes("approve"));
    return {session, request, popup};
}

test("popup consent comes from the driver's click and the displayed account selection", async () => {
    const {session, request, popup} = await popupSession();
    try {
        assert.equal(session.oracle.approvals.size, 0);
        assert.equal(await session.decide({}, "approve", request), true);
        session.browser.check();
        const approval = [...session.oracle.approvals.values()][0];
        assert.deepEqual(approval.grantAccounts, {ethereum: "0x" + "1".repeat(40)});
        assert.equal(popup.harness.nativeMessages.filter(message => message.subject === "approveRequest").length, 1);
        assert.equal(session.popupApprovals.size, 0);
    } finally { session.browser.close(); }
});

test("an unsolicited popup approval cannot create user consent", async () => {
    const {session, request, popup} = await popupSession();
    try {
        await assert.rejects(popup.harness.browser.runtime.sendNativeMessage("org.lil.wallet", {subject: "approveRequest",
            id: request.handle.id, requestToken: request.handle.token, reviewToken: session.browser.popupState().review.reviewToken,
            payload: {selectedAccounts: session.browser.popupPresentation().accounts, chainId: "0x1"}}), error => error.invariant === "consent");
        assert.equal(session.oracle.approvals.size, 0);
        assert.throws(() => session.browser.check(), error => error.invariant === "consent");
    } finally { session.browser.close(); }
});

test("a popup approval transmission cannot change or reuse the user's clicked intent", async () => {
    for (const change of ["account", "handle", "review", "duplicate"]) {
        const {session, request, popup} = await popupSession();
        try {
            const send = popup.harness.browser.runtime.sendNativeMessage;
            popup.harness.browser.runtime.sendNativeMessage = (application, message) => {
                if (message.subject !== "approveRequest") { return send(application, message); }
                if (change === "duplicate") {
                    void send(application, message);
                    return send(application, message);
                }
                const altered = structuredClone(message);
                if (change === "account") { altered.payload.selectedAccounts[0].address = "0x" + "2".repeat(40); }
                if (change === "handle") { altered.requestToken = "00000000-0000-0000-0000-000000000002"; }
                if (change === "review") { altered.reviewToken = "00000000-0000-0000-0000-000000000102"; }
                return send(application, altered);
            };
            await session.decide({}, "approve", request);
            assert.throws(() => session.browser.check(), error => error.invariant === "consent");
        } finally { session.browser.close(); }
    }
});

test("recovery delivers delayed configuration updates and checks the actual page provider", async () => {
    const session = new LifecycleSession({seed: 1, mode: "native", timeout: 1000});
    const address = "0x" + "1".repeat(40);
    let state = {...disconnected, revisions: {ethereum: 1, solana: 0}, ethereum: {address, chainId: "0x1"}};
    const handle = {id: 1, token: "connect", profileIdentifier: null};
    session.oracle.register({handle, configurationKey: "https://one.example", provider: "ethereum", name: "requestAccounts"});
    session.oracle.approvalIntent({handle, label: "connect", selectedAccounts: [{coin: "ethereum", address}]});
    session.oracle.acceptConsent({handle, label: "connect"});
    const native = async message => {
        if (message.subject === "getLatestConfiguration") { return {id: message.id, state}; }
        if (message.subject === "getRecoveryRequests") { return {id: message.id, requests: []}; }
        throw new Error(`Unexpected recovery command ${message.subject}`);
    };
    session.children.set("bridge", {ready: {workflowVersion: 4}, command: async (operation, payload) => operation === "native" ? native(payload.message) : {}});
    session.browser = new BrowserLifecycle({scheduler: session.scheduler, native});
    session.inspect = async () => { session.lastInspectionAvailable = true; return []; };
    try {
        const tab = session.browser.openTab({url: "https://one.example/page"});
        session.tabs = [tab];
        await session.pumpUntil(() => session.browser.configurationReady(tab.id, state));
        session.browser.addFault({channel: "page", phase: "reply", subject: "response", action: "delay", delay: 20001});
        state = {...disconnected, revisions: {ethereum: 2, solana: 0}};
        session.browser.focus(tab.id);
        await session.pumpUntil(() => tab.document.contentContext.bigWalletConfigurationState.state.revisions.ethereum === 2);
        assert.equal(tab.document.pageWindow.ethereum.selectedAddress, address);
        await session.quiesce();
        assert.equal(tab.document.pageWindow.ethereum.selectedAddress, null);
        assert.equal(session.scheduler.pending({kind: "message"}).length, 0);
        assert.ok(session.scheduler.monotonic >= 20001);
        session.check();
    } finally { session.browser.close(); }
});

async function configurationSession(current, authoritative) {
    const session = new LifecycleSession({seed: 1, mode: "native", timeout: 1000});
    for (const provider of ["ethereum", "solana"]) {
        const address = provider === "ethereum" ? current.ethereum.address : current.solana?.publicKey;
        if (!address) { continue; }
        const handle = {id: provider === "ethereum" ? 1 : 2, token: provider, profileIdentifier: null};
        session.oracle.register({handle, configurationKey: "https://one.example", provider,
            name: provider === "ethereum" ? "requestAccounts" : "connect"});
        session.oracle.approvalIntent({handle, label: provider, selectedAccounts: [{coin: provider, address}]});
        session.oracle.acceptConsent({handle, label: provider});
    }
    const native = async message => {
        if (message.subject === "getLatestConfiguration") { return {id: message.id, state: current}; }
        if (message.subject === "getRecoveryRequests") { return {id: message.id, requests: []}; }
        throw new Error(`Unexpected configuration command ${message.subject}`);
    };
    session.children.set("bridge", {ready: {workflowVersion: 4}, command: async (operation, payload) =>
        operation === "native" ? {id: payload.message.id, state: authoritative} : {}});
    session.browser = new BrowserLifecycle({scheduler: session.scheduler, native});
    const tab = session.browser.openTab({url: "https://one.example/page"});
    session.tabs = [tab];
    await session.pumpUntil(() => session.browser.configurationReady(tab.id, current));
    return session;
}

test("configuration refresh cannot transfer approval to another authority context", async () => {
    for (const provider of ["ethereum", "solana"]) {
        for (const context of [disconnected.context, "b".repeat(64)]) {
            const session = new LifecycleSession({seed: 1, mode: "native", timeout: 1000});
            const address = provider === "ethereum" ? "0x" + "1".repeat(40) : Keypair.fromSeed(Buffer.alloc(32, 2)).publicKey.toBase58();
            let state = structuredClone(disconnected);
            session.browser = new BrowserLifecycle({scheduler: session.scheduler, native: async message => {
                if (message.subject === "getLatestConfiguration") { return {id: message.id, state}; }
                if (message.subject === "getRecoveryRequests") { return {id: message.id, requests: []}; }
                throw new Error(`Unexpected configuration command ${message.subject}`);
            }});
            try {
                const tab = session.browser.openTab({url: "https://one.example/page"});
                await session.pumpUntil(() => session.browser.configurationReady(tab.id, state));
                const handle = {id: 1, token: "reviewed-context", profileIdentifier: null};
                session.oracle.register({handle, configurationKey: "https://one.example", provider,
                    name: provider === "ethereum" ? "requestAccounts" : "connect", authority: state});
                session.oracle.approvalIntent({handle, label: "approved", selectedAccounts: [{coin: provider, address}]});
                session.oracle.acceptConsent({handle, label: "approved"});
                state = structuredClone(state);
                state.context = context;
                state.revisions[provider] = 1;
                if (provider === "ethereum") { state.ethereum.address = address; }
                else { state.solana = {publicKey: address}; }
                session.browser.focus(tab.id);
                await session.scheduler.until(() => session.browser.configurationReady(tab.id, state));
                if (context === disconnected.context) { session.check(); }
                else { assert.throws(() => session.check(), error => error.invariant === "replay"); }
            } finally { session.browser.close(); }
        }
    }
});

test("a new document cannot use an account from inside a known revocation gap", async () => {
    for (const provider of ["ethereum", "solana"]) {
        const addresses = provider === "ethereum" ? ["0x" + "1".repeat(40), "0x" + "2".repeat(40)] :
            [2, 3].map(value => Keypair.fromSeed(Buffer.alloc(32, value)).publicKey.toBase58());
        const state = (revision, address) => ({...disconnected,
            revisions: {ethereum: provider === "ethereum" ? revision : 0, solana: provider === "solana" ? revision : 0},
            ethereum: {address: provider === "ethereum" ? address || "" : "", chainId: "0x1"},
            solana: provider === "solana" && address ? {publicKey: address} : null});
        for (const historicalRevision of [1, 3]) {
            const current = state(1, addresses[0]);
            const session = await configurationSession(current, current);
            session.browser.onSettlement = operation => session.observeSettlement(operation);
            const native = session.browser.native;
            session.browser.native = async message => message.subject ? native(message) : {
                id: message.id, state: current, response: {id: message.id, name: message.name, provider, kind: "result",
                    result: provider === "ethereum" ? [current.ethereum.address] : {publicKey: current.solana.publicKey}, approvalCommitted: true},
            };
            const first = session.tabs[0];
            try {
                session.oracle.revoke({profileIdentifier: null, configurationKey: "https://one.example", provider, account: addresses[0]});
                Object.assign(current, state(2, null));
                session.browser.focus(first.id);
                await session.pumpUntil(() => session.browser.configurationReady(first.id, current));
                const handle = {id: 3, token: "replacement-account", profileIdentifier: null};
                session.oracle.register({handle, configurationKey: "https://one.example", provider,
                    name: provider === "ethereum" ? "requestAccounts" : "connect"});
                session.oracle.approvalIntent({handle, label: "replacement", selectedAccounts: [{coin: provider, address: addresses[1]}]});
                session.oracle.acceptConsent({handle, label: "replacement"});
                Object.assign(current, state(4, addresses[1]));
                session.browser.focus(first.id);
                await session.pumpUntil(() => session.browser.configurationReady(first.id, current));
                Object.assign(current, state(historicalRevision, addresses[0]));
                const second = session.browser.openTab({url: "https://one.example/second"});
                await session.scheduler.until(() => session.browser.configurationReady(second.id, current));
                const operation = session.browser.request(second.id, provider, {method: provider === "ethereum" ? "eth_requestAccounts" : "connect"});
                if (historicalRevision === 3) {
                    await assert.rejects(session.pumpUntil(() => operation.status !== "pending"), error => error.invariant === "replay");
                } else {
                    await session.pumpUntil(() => operation.status !== "pending");
                    assert.equal(operation.status, "fulfilled");
                    session.check();
                }
            } finally { session.browser.close(); }
        }
    }
});

test("equal network revisions cannot give two documents different chains", async () => {
    const current = {...disconnected, revisions: {ethereum: 1, solana: 0},
        ethereum: {address: "0x" + "1".repeat(40), chainId: "0x1"}};
    const session = await configurationSession(current, current);
    session.browser.onSettlement = operation => session.observeSettlement(operation);
    try {
        current.revisions.ethereum = 2;
        current.ethereum.chainId = "0xa";
        session.browser.focus(session.tabs[0].id);
        await session.pumpUntil(() => session.browser.configurationReady(session.tabs[0].id, current));
        current.ethereum.chainId = "0x539";
        const second = session.browser.openTab({url: "https://one.example/second"});
        await session.scheduler.until(() => session.browser.configurationReady(second.id, current));
        const operation = session.browser.request(second.id, "ethereum", {method: "eth_chainId"});
        await assert.rejects(session.pumpUntil(() => operation.status !== "pending"), error => error.invariant === "replay");
    } finally { session.browser.close(); }
});

test("refresh retries typed temporary unavailability while pumping cleanup and advancing the clock", async () => {
    for (const unavailableReads of [1, 2]) {
        const session = await configurationSession(disconnected, disconnected);
        const bridge = session.child("bridge");
        const command = bridge.command;
        const reads = [], timeouts = [];
        const startedAt = session.scheduler.monotonic;
        let cleanupCompleted = false;
        bridge.command = async (operation, payload, options) => {
            if (operation !== "native") { return command(operation, payload); }
            reads.push(session.scheduler.monotonic - startedAt);
            timeouts.push(options.timeout);
            if (reads.length === 1) { session.scheduler.schedule(() => { cleanupCompleted = true; }, 0, "cleanup", "native-gate"); }
            else { assert.equal(cleanupCompleted, true); }
            return reads.length <= unavailableReads ? {id: payload.message.id, unavailable: true} : {id: payload.message.id, state: disconnected};
        };
        try {
            await session.refreshTab(0);
            assert.deepEqual(reads, unavailableReads === 1 ? [0, 1000] : [0, 1000, 6000]);
            assert.ok(timeouts.every(value => value > 0 && value <= session.options.timeout));
            assert.ok(timeouts.every((value, index) => index === 0 || value <= timeouts[index - 1]));
            session.check();
        } finally { session.browser.close(); }
    }
});

test("refresh cannot replace persistent native unavailability with cached provider state", async () => {
    const session = await configurationSession(disconnected, disconnected);
    const bridge = session.child("bridge");
    const command = bridge.command;
    let reads = 0;
    bridge.command = async (operation, payload) => {
        if (operation !== "native") { return command(operation, payload); }
        reads += 1;
        return {id: payload.message.id, unavailable: true};
    };
    try {
        await assert.rejects(session.refreshTab(0), error => error.invariant === "progress" && error.details.reply.unavailable === true);
        assert.equal(reads, 3);
        assert.equal(session.scheduler.monotonic, 6000);
    } finally { session.browser.close(); }
});

test("configuration retries share one wall-clock watchdog", async t => {
    const session = await configurationSession(disconnected, disconnected);
    let now = 0, reads = 0;
    const clock = t.mock.method(performance, "now", () => now);
    session.child("bridge").command = async (_operation, payload, options) => {
        reads += 1;
        assert.equal(options.timeout, session.options.timeout);
        return {id: payload.message.id, unavailable: true};
    };
    session.advance = async () => { now = session.options.timeout; };
    try {
        await assert.rejects(session.refreshTab(0), error => error.invariant === "watchdog");
        assert.equal(reads, 1);
    } finally { clock.mock.restore(); session.browser.close(); }
});

test("configuration refresh does not retry malformed replies or unrelated native failures", async () => {
    for (const reply of [null, {}, {id: 1}, {id: 1, unavailable: false}, {id: 2, unavailable: true},
        {id: 1, unavailable: true, state: null}, {id: 1, unavailable: true, state: disconnected},
        {id: 2, state: disconnected}, {id: 1, unavailable: true, unexpected: true}]) {
        const session = await configurationSession(disconnected, disconnected);
        let reads = 0;
        session.child("bridge").command = async () => { reads += 1; return reply; };
        try {
            await assert.rejects(session.refreshTab(0), error => error.invariant === "progress");
            assert.equal(reads, 1);
            assert.equal(session.scheduler.monotonic, 0);
        } finally { session.browser.close(); }
    }
    const session = await configurationSession(disconnected, disconnected);
    const failure = Object.assign(new Error("Unexpected native failure"), {native: true});
    session.child("bridge").command = async () => { throw failure; };
    try { await assert.rejects(session.refreshTab(0), error => error === failure); }
    finally { session.browser.close(); }
});

test("refresh rejects stale provider values at the authoritative native revision", async () => {
    const firstKey = Keypair.fromSeed(Buffer.alloc(32, 2)).publicKey.toBase58();
    const secondKey = Keypair.fromSeed(Buffer.alloc(32, 3)).publicKey.toBase58();
    for (const change of ["chain", "ethereumAccount", "ethereumDisconnect", "solanaAccount", "solanaDisconnect", "solanaConnect"]) {
        const current = {...disconnected, revisions: {ethereum: 1, solana: 1},
            ethereum: {address: "0x" + "1".repeat(40), chainId: "0x1"}, solana: {publicKey: firstKey}};
        if (change === "solanaConnect") { current.solana = null; }
        const authoritative = structuredClone(current);
        if (change === "chain") { authoritative.ethereum.chainId = "0x539"; }
        if (change === "ethereumAccount") { authoritative.ethereum.address = "0x" + "2".repeat(40); }
        if (change === "ethereumDisconnect") { authoritative.ethereum.address = ""; }
        if (change === "solanaAccount") { authoritative.solana.publicKey = secondKey; }
        if (change === "solanaDisconnect") { authoritative.solana = null; }
        if (change === "solanaConnect") { authoritative.solana = {publicKey: firstKey}; }
        const session = await configurationSession(current, authoritative);
        try {
            session.options.timeout = 40;
            await assert.rejects(session.refreshTab(0), error => error.invariant === "watchdog", change);
        } finally { session.browser.close(); }
    }
});

test("refresh permits provider values from a newer native revision", async () => {
    const current = {...disconnected, revisions: {ethereum: 2, solana: 2},
        ethereum: {address: "0x" + "1".repeat(40), chainId: "0x539"},
        solana: {publicKey: Keypair.fromSeed(Buffer.alloc(32, 2)).publicKey.toBase58()}};
    const authoritative = {...disconnected, revisions: {ethereum: 1, solana: 1}};
    const session = await configurationSession(current, authoritative);
    try {
        await session.refreshTab(0);
        session.check();
    } finally { session.browser.close(); }
});

test("native account choices are explicit descriptors and match the recorded user intent", async () => {
    const session = new LifecycleSession({seed: 1, mode: "native"});
    const handle = {id: 1, token: "request", profileIdentifier: null};
    const request = {handle, configurationKey: "https://one.example", provider: "unknown", name: "switchAccount", presentation: "review", revision: 2};
    session.oracle.register(request);
    session.snapshots.set(null, {accounts: [{walletID: "ethereum-wallet", coin: "ethereum", address: "0xAB", path: "eth-path"},
        {walletID: "solana-wallet", coin: "solana", address: "selected-solana", path: "sol-path"}]});
    let issued;
    session.children.set("approval", {command: async (name, payload) => { issued = {name, payload}; }});
    await session.decide({}, "approve", request);
    assert.deepEqual(issued.payload.selectedAccounts, [{walletId: "ethereum-wallet", coin: "ethereum", address: "0xAB", derivationPath: "eth-path"},
        {walletId: "solana-wallet", coin: "solana", address: "selected-solana", derivationPath: "sol-path"}]);
    assert.equal(issued.payload.accounts, undefined);
    assert.deepEqual([...session.oracle.approvals.values()][0].grantAccounts, {ethereum: "0xab", solana: "selected-solana"});
});

test("Solana broadcast endpoint expectations preserve the explicitly approved cluster", async () => {
    const handle = {id: 1, token: "request", profileIdentifier: null};
    for (const mode of ["popup", "native"]) {
        const session = new LifecycleSession({seed: 1, mode});
        const request = {handle, configurationKey: "https://one.example", provider: "solana", name: "signAndSendTransaction",
            presentation: "review", revision: 1};
        const admitted = {provider: "solana", name: request.name};
        session.nativeRequests.set(handleKey(handle), admitted);
        session.oracle.register(request);
        if (mode === "popup") {
            const review = {kind: "signMessage", reviewToken: "review"};
            const payload = {cluster: "testnet"};
            session.popupApprovals.set("popup", {handle, review, payload});
            session.observeNativeMessage({profileIdentifier: null, owner: "popup", message: {subject: "approveRequest", id: handle.id,
                requestToken: handle.token, reviewToken: review.reviewToken, payload}});
        } else {
            session.children.set("approval", {command: async () => {}});
            await session.decide({}, "approve", request);
        }
        assert.equal(admitted.reviewedCluster, mode === "popup" ? "testnet" : "devnet");
    }
});

const ethereumTransaction = {
    from: "0x9d8a62f656a8d1615c1294fd71e9cfb3e4855a4f", to: "0x3535353535353535353535353535353535353535",
    chainId: "0x1", nonce: "0x9", gasLimit: "0x5208", gasPrice: "0x4a817c800", value: "0xde0b6b3a7640000", input: "0x",
};
const ethereumSigned = Buffer.from("f86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83", "hex");
const ethereumHash = "0x" + Buffer.from(keccak_256(ethereumSigned)).toString("hex");

async function admittedBrowserRequest(provider, payload, state, mutate, {navigateBeforeAdmission = false} = {}) {
    const session = new LifecycleSession({seed: 1, mode: "native", timeout: 1000});
    let admissionFailure;
    session.browser = new BrowserLifecycle({scheduler: session.scheduler, onNative: event => session.observeNativeMessage(event), native: async message => {
        if (message.subject === "getLatestConfiguration") { return {id: message.id, state}; }
        if (message.subject === "getRecoveryRequests") { return {id: message.id, requests: []}; }
        assert.equal(message.subject, undefined);
        const handle = {id: message.id, token: "request", profileIdentifier: null};
        if (navigateBeforeAdmission) { session.browser.navigate(tab.id, "https://other.example/page"); }
        try {
            await session.nativeEvent({event: "admission", details: {handle, enqueueAttempt: message.enqueueAttempt,
                configurationKey: message.configurationKey, provider: message.provider, name: message.name, payloadDigest: "native-digest"}},
            {epoch: "bridge-1", role: "bridge"});
        } catch (error) { admissionFailure = error; throw error; }
        return new Promise(() => {});
    }});
    const tab = session.browser.openTab({url: "https://one.example/page"});
    session.tabs = [tab];
    await session.scheduler.until(() => session.browser.configurationReady(tab.id, state));
    const runtime = tab.profile.worker.context.browser.runtime;
    const send = runtime.sendNativeMessage;
    runtime.sendNativeMessage = (application, value) => {
        const message = structuredClone(value);
        if (!message.subject) { mutate?.(message); }
        return send(application, message);
    };
    const operation = session.browser.request(tab.id, provider, payload);
    await session.scheduler.until(() => operation.handle || admissionFailure);
    if (admissionFailure) { session.browser.close(); throw admissionFailure; }
    session.browser.check();
    return {session, operation};
}

test("native admission cannot change a public signing method or provider after document retirement", async () => {
    const address = "0x" + "1".repeat(40);
    const state = {...disconnected, revisions: {ethereum: 1, solana: 0}, ethereum: {address, chainId: "0x1"}};
    for (const navigateBeforeAdmission of [false, true]) {
        for (const change of ["typedData", "provider", "manualSwitch"]) {
            await assert.rejects(admittedBrowserRequest("ethereum", {method: "personal_sign", params: ["0x010203", address]}, state,
                message => {
                    if (change === "typedData") { message.name = "signTypedMessage"; message.body.object = {raw: "{}"}; }
                    if (change === "provider") { message.provider = "solana"; message.name = "signMessage"; }
                    if (change === "manualSwitch") { message.provider = "unknown"; message.name = "switchAccount"; }
                }, {navigateBeforeAdmission}), error => error.invariant === "isolation");
        }
    }
});

test("native signing admission requires a matching request transport", async () => {
    const handle = {id: 1, token: "request", profileIdentifier: null};
    const message = {id: 1, provider: "ethereum", name: "signPersonalMessage", configurationKey: "https://one.example"};
    for (const wireKind of [undefined, "rpc", "disconnect"]) {
        const session = new LifecycleSession({seed: 1, mode: "native"});
        const operation = wireKind ? {provider: "ethereum", payload: {method: "personal_sign"}, wireKind} : undefined;
        session.admissions.set("attempt", {message, profileIdentifier: null, operation});
        await assert.rejects(session.nativeEvent({event: "admission", details: {...message, handle, enqueueAttempt: "attempt"}},
            {epoch: "bridge-1", role: "bridge"}), error => error.invariant === "isolation");
    }
});

test("Ethereum broadcast assertions retain the public transaction across worker payload substitution", async () => {
    for (const changed of [false, true]) {
        const transaction = {...ethereumTransaction, value: changed ? "0x1" : ethereumTransaction.value};
        const state = {...disconnected, revisions: {ethereum: 1, solana: 0}, ethereum: {address: transaction.from, chainId: "0x1"}};
        const {session, operation} = await admittedBrowserRequest("ethereum", {method: "eth_sendTransaction", params: [transaction]}, state,
            message => { message.body.object.value = ethereumTransaction.value; });
        try {
            const request = session.nativeRequests.get(handleKey(operation.handle));
            assert.deepEqual(request.expectedBody.object, transaction);
            assert.equal(request.body.object.value, ethereumTransaction.value);
            const verify = () => session.verifySigning({handle: operation.handle, signedTransaction: ethereumSigned.toString("hex"), encoding: "hex", transactionID: ethereumHash});
            if (changed) { assert.throws(verify, error => error.invariant === "payload"); }
            else { verify(); }
        } finally { session.browser.close(); }
    }
});

test("popup review preserves approved fees and nonce across repeated native admissions", async () => {
    const session = new LifecycleSession({seed: 1, mode: "popup"});
    const handle = {id: 1, token: "request", profileIdentifier: null};
    const expectedBody = {address: ethereumTransaction.from, chainId: "0x1", object: {...ethereumTransaction, nonce: "0x0", gasPrice: "0x1"}};
    const message = {id: handle.id, provider: "ethereum", name: "signTransaction", configurationKey: "https://one.example",
        body: {...expectedBody, object: {...expectedBody.object, value: "0x2"}}};
    session.admissions.set("attempt", {message, profileIdentifier: null, operation: {requestBody: expectedBody,
        provider: "ethereum", payload: {method: "eth_sendTransaction"}, wireKind: "request"}});
    const event = {event: "admission", details: {handle, enqueueAttempt: "attempt", configurationKey: message.configurationKey,
        provider: message.provider, name: message.name, payloadDigest: "payload"}};
    const child = {epoch: "bridge-1", role: "bridge"};
    await session.nativeEvent(event, child);
    const review = {kind: "sendTransaction", reviewToken: "review", editor: {nonce: "9", usesEIP1559: false, gasPriceGwei: "20"}};
    session.popupApprovals.set("popup", {handle, review, payload: {}});
    session.observeNativeMessage({profileIdentifier: null, owner: "popup", message: {subject: "approveRequest", id: handle.id,
        requestToken: handle.token, reviewToken: review.reviewToken, payload: {}}});
    const signed = {handle, signedTransaction: ethereumSigned.toString("hex"), encoding: "hex", transactionID: ethereumHash};
    session.verifySigning(signed);
    const reviewedBody = structuredClone(session.nativeRequests.get(handleKey(handle)).reviewedBody);
    await session.nativeEvent(event, child);
    session.verifySigning(signed);
    assert.deepEqual(session.nativeRequests.get(handleKey(handle)).reviewedBody, reviewedBody);
    assert.strictEqual(session.nativeRequests.get(handleKey(handle)).expectedBody, expectedBody);
    assert.equal(expectedBody.object.nonce, "0x0");
    assert.equal(expectedBody.object.gasPrice, "0x1");
});

test("Ethereum signer checkpoints check the original message and account after document retirement", async () => {
    const keys = [Buffer.alloc(32, 2), Buffer.alloc(32, 3)];
    const addresses = keys.map(key => "0x" + Buffer.from(keccak_256(secp256k1.getPublicKey(key, false).subarray(1))).subarray(12).toString("hex"));
    for (const change of ["none", "message", "account", "missing"]) {
        const state = {...disconnected, revisions: {ethereum: 1, solana: 0}, ethereum: {address: addresses[0], chainId: "0x1"}};
        const {session, operation} = await admittedBrowserRequest("ethereum", {method: "personal_sign", params: ["0x010203", addresses[0]]}, state,
            message => {
                if (change === "message") { message.body.object.data = "0x090909"; }
                if (change === "account") { message.body.address = addresses[1]; }
            });
        try {
            const request = session.nativeRequests.get(handleKey(operation.handle));
            const bytes = Buffer.from(request.body.object.data.slice(2), "hex");
            const signed = secp256k1.sign(keccak_256(Buffer.concat([Buffer.from(`\x19Ethereum Signed Message:\n${bytes.length}`), bytes])), keys[change === "account" ? 1 : 0]);
            const signature = "0x" + Buffer.concat([signed.toCompactRawBytes(), Buffer.from([signed.recovery + 27])]).toString("hex");
            session.browser.navigate(operation.tab, "https://other.example/page");
            assert.equal(operation.status, "abandoned");
            if (change === "missing") { delete request.expectedBody; }
            const verify = () => session.verifySigning({handle: operation.handle, response: {kind: "result", result: signature}});
            if (change === "none") { verify(); }
            else { assert.throws(verify, error => error.invariant === "payload"); }
        } finally { session.browser.close(); }
    }
});

test("Solana signer checkpoints check the original bytes and account after document retirement", async () => {
    const signers = [Keypair.fromSeed(Buffer.alloc(32, 2)), Keypair.fromSeed(Buffer.alloc(32, 3))];
    const address = signers[0].publicKey.toBase58();
    const transactionMessage = lamports => new Transaction({feePayer: signers[0].publicKey, recentBlockhash: "11111111111111111111111111111111"})
        .add(SystemProgram.transfer({fromPubkey: signers[0].publicKey, toPubkey: signers[0].publicKey, lamports})).serializeMessage();
    for (const method of ["signMessage", "signTransaction"]) {
        for (const change of ["none", "message", "account", "missing"]) {
            const original = method === "signMessage" ? "0x010203" : base58.encode(transactionMessage(1));
            const altered = method === "signMessage" ? "0x090909" : base58.encode(transactionMessage(2));
            const state = {...disconnected, revisions: {ethereum: 0, solana: 1}, solana: {publicKey: address}};
            const {session, operation} = await admittedBrowserRequest("solana", {method, params: {message: original}}, state,
                message => {
                    if (change === "message") { message.body.object.params.message = altered; }
                    if (change === "account") { message.body.publicKey = signers[1].publicKey.toBase58(); }
                });
            try {
                const request = session.nativeRequests.get(handleKey(operation.handle));
                const encoded = request.body.object.params.message;
                const bytes = method === "signMessage" ? Buffer.from(encoded.slice(2), "hex") : base58.decode(encoded);
                const signature = base58.encode(ed25519.sign(bytes, signers[change === "account" ? 1 : 0].secretKey.subarray(0, 32)));
                session.browser.navigate(operation.tab, "https://other.example/page");
                assert.equal(operation.status, "abandoned");
                if (change === "missing") { delete request.expectedBody; }
                const verify = () => session.verifySigning({handle: operation.handle, response: {kind: "result", result: signature}});
                if (change === "none") { verify(); }
                else { assert.throws(verify, error => error.invariant === "payload"); }
            } finally { session.browser.close(); }
        }
    }
});

test("Solana broadcasts retain normalized public transaction bytes across worker substitution", async () => {
    const signer = Keypair.fromSeed(Buffer.alloc(32, 2));
    const address = signer.publicKey.toBase58();
    const transaction = lamports => new Transaction({feePayer: signer.publicKey, recentBlockhash: "11111111111111111111111111111111"})
        .add(SystemProgram.transfer({fromPubkey: signer.publicKey, toPubkey: signer.publicKey, lamports}));
    const signed = transaction(2);
    signed.sign(signer);
    const bytes = signed.serialize();
    for (const changed of [false, true]) {
        const original = transaction(changed ? 1 : 2).serialize({requireAllSignatures: false, verifySignatures: false});
        const state = {...disconnected, revisions: {ethereum: 0, solana: 1}, solana: {publicKey: address}};
        const {session, operation} = await admittedBrowserRequest("solana", {method: "signAndSendTransaction", params: {transaction: original}}, state,
            message => { message.body.object.params.transaction = base58.encode(bytes); });
        try {
            assert.equal(session.nativeRequests.get(handleKey(operation.handle)).expectedBody.object.params.transaction, base58.encode(original));
            const verify = () => session.verifySigning({handle: operation.handle, signedTransaction: bytes.toString("base64"), transactionID: base58.encode(signed.signature)});
            if (changed) { assert.throws(verify, error => error.invariant === "payload"); }
            else { verify(); }
        } finally { session.browser.close(); }
    }
});

test("Solana public signing results must retain the approved account", () => {
    const first = Keypair.fromSeed(Buffer.alloc(32, 2)), second = Keypair.fromSeed(Buffer.alloc(32, 3));
    const message = Buffer.from([1, 2, 3]);
    for (const method of ["signMessage", "signTransaction"]) {
        for (const returned of [first, second]) {
            const session = new LifecycleSession({seed: 1, mode: "native"});
            const handle = {id: 1, token: "request", profileIdentifier: null};
            const publicKey = first.publicKey.toBase58();
            const params = {message: method === "signMessage" ? "0x010203" : base58.encode(message)};
            const body = {publicKey, object: {params}};
            session.nativeRequests.set(handleKey(handle), {provider: "solana", name: method, body, expectedBody: body});
            session.oracle.register({handle, configurationKey: "https://one.example", provider: "solana", name: method, account: publicKey});
            session.oracle.approvalIntent({handle, label: "approved"});
            session.oracle.acceptConsent({handle, label: "approved"});
            const execution = {handle, executionID: "execution", epoch: "approval-1"};
            session.oracle.execution(execution);
            session.oracle.signed(execution);
            session.verifySigning({...execution, response: {kind: "result", result: base58.encode(ed25519.sign(message, first.secretKey.subarray(0, 32)))}});
            const settle = () => session.observeSettlement({label: "result", handle, provider: "solana", profileIdentifier: null,
                url: "https://one.example/page", document: "page", currentDocument: "page", payload: {method, params}, status: "fulfilled",
                result: {publicKey: returned.publicKey.toBase58(), signature: base58.encode(ed25519.sign(message, returned.secretKey.subarray(0, 32)))}});
            if (returned === first) { settle(); }
            else { assert.throws(settle, error => error.invariant === "payload"); }
        }
    }
});
