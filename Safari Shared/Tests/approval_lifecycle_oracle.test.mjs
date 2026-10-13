import assert from "node:assert/strict";
import {mkdtemp, readFile, rm} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import test from "node:test";
import {EffectLedger, FakeRPC, LifecycleOracle} from "../../Scripts/approval_lifecycle/oracle.mjs";
import {Random, Scheduler} from "../../Scripts/approval_lifecycle/scheduler.mjs";

const handle = {id: 1, token: "00000000-0000-0000-0000-000000000001", profileIdentifier: null};
const request = {handle, configurationKey: "https://one.example", provider: "ethereum", payloadDigest: "payload", account: "account"};
const execution = {handle, executionID: "execution-one", epoch: "approval-1", account: "account", payloadDigest: "payload"};

function approved() {
    const oracle = new LifecycleOracle;
    oracle.register(request);
    oracle.approvalIntent({handle, label: "approval-one", revision: 1});
    oracle.acceptConsent({handle, label: "approval-one", revision: 1});
    return oracle;
}

function providerState(provider, revision, address, context = "context") {
    return {context, revisions: {ethereum: provider === "ethereum" ? revision : 0, solana: provider === "solana" ? revision : 0},
        ethereum: {address: provider === "ethereum" ? address || "" : "", chainId: "0x1"},
        solana: provider === "solana" && address ? {publicKey: address} : null};
}

test("lifecycle oracle rejects signing without explicit matching consent", () => {
    const oracle = new LifecycleOracle;
    oracle.register(request);
    assert.throws(() => oracle.execution(execution), error => error.invariant === "consent");
    assert.throws(() => oracle.acceptConsent({handle, label: "invented"}), error => error.invariant === "consent");
    for (const changed of [{account: "another"}, {payloadDigest: "another"}]) {
        assert.throws(() => approved().execution({...execution, ...changed}), error => error.invariant === "consent");
    }
});

test("an accepted admission retry keeps its full handle even when the original record remains present", () => {
    const oracle = new LifecycleOracle;
    const admitted = {...request, enqueueAttempt: "attempt-one"};
    oracle.register(admitted);
    oracle.register(admitted);
    assert.throws(() => oracle.register({...admitted, handle: {...handle, token: "another-token"}}), error => error.invariant === "replay");
    assert.throws(() => oracle.register({...admitted, handle: {...handle, id: 2, token: "another-token"}}), error => error.invariant === "replay");
    assert.equal(oracle.requests.size, 1);
});

test("admission retry identity is scoped to profile, origin and attempt rather than dapp ID", () => {
    const oracle = new LifecycleOracle;
    oracle.register({...request, enqueueAttempt: "attempt-one"});
    oracle.register({...request, enqueueAttempt: "attempt-two", handle: {...handle, token: "new-attempt"}});
    oracle.register({...request, enqueueAttempt: "attempt-one", handle: {...handle, profileIdentifier: "another-profile"}});
    oracle.register({...request, enqueueAttempt: "attempt-one", configurationKey: "https://other.example", handle: {...handle, token: "other-origin"}});
    oracle.register({...request, enqueueAttempt: "coalesced-attempt"});
    assert.equal(oracle.requests.size, 4);
    assert.equal(oracle.admissions.size, 5);
});

test("coalesced manual switch attempts keep independent immutable fingerprints", () => {
    const oracle = new LifecycleOracle;
    const first = {...request, provider: "unknown", name: "switchAccount", enqueueAttempt: "first"};
    const second = {...first, enqueueAttempt: "second", payloadDigest: "second-payload"};
    const key = oracle.register(first);
    oracle.register(second);
    oracle.register(second);
    oracle.register(first);
    assert.equal(oracle.requests.size, 1);
    assert.equal(oracle.admissions.size, 2);
    assert.equal(oracle.requests.get(key).payloadDigest, first.payloadDigest);
    for (const admission of [first, second]) {
        assert.throws(() => oracle.register({...admission, payloadDigest: "changed"}), error => error.invariant === "isolation");
    }
});

test("manual switch coalescing preserves ordinary request and identity bindings", () => {
    const manual = {...request, provider: "unknown", name: "switchAccount", enqueueAttempt: "first"};
    for (const [original, change] of [
        [{...request, name: "signPersonalMessage", enqueueAttempt: "first"}, {}],
        [{...request, provider: "solana", name: "signMessage", enqueueAttempt: "first"}, {}],
        [manual, {configurationKey: "https://other.example"}],
        [manual, {provider: "ethereum"}],
        [manual, {name: "requestAccounts"}],
        [manual, {enqueueAttempt: undefined}],
    ]) {
        const oracle = new LifecycleOracle;
        oracle.register(original);
        assert.throws(() => oracle.register({...original, enqueueAttempt: "second", payloadDigest: "second-payload", ...change}),
            error => error.invariant === "isolation");
    }
});

test("every signing success needs a successful execution for the same request handle", () => {
    for (const [provider, names] of [["ethereum", ["signPersonalMessage", "signTypedMessage", "signTransaction"]],
        ["solana", ["signMessage", "signTransaction", "signAllTransactions", "signAndSendTransaction"]]]) {
        for (const name of names) {
            const oracle = new LifecycleOracle;
            oracle.register({...request, provider, name});
            const settlement = {operation: "signing-result", document: "tab", currentDocument: "tab", handle, result: "signature"};
            assert.throws(() => oracle.settle(settlement), error => error.invariant === "consent");
            oracle.approvalIntent({handle, label: "fresh-consent"});
            oracle.acceptConsent({handle, label: "fresh-consent"});
            oracle.execution(execution);
            assert.throws(() => oracle.settle(settlement), error => error.invariant === "consent");
            oracle.signed(execution);
            oracle.settle(settlement);
        }
    }
});

test("another origin's signature cannot settle an unapproved request with the same account and payload", () => {
    const oracle = new LifecycleOracle;
    oracle.register({...request, name: "signPersonalMessage"});
    oracle.approvalIntent({handle, label: "approved-origin"});
    oracle.acceptConsent({handle, label: "approved-origin"});
    oracle.execution(execution);
    oracle.signed(execution);
    const other = {...handle, token: "another-origin-request"};
    oracle.register({...request, handle: other, configurationKey: "https://other.example", name: "signPersonalMessage"});
    assert.throws(() => oracle.settle({operation: "other-origin", document: "other-tab", currentDocument: "other-tab", handle: other, result: "same-signature"}),
        error => error.invariant === "consent");
    oracle.settle({operation: "retained-result", document: "tab", currentDocument: "tab", handle, result: "same-signature"});
    const recovery = {...handle, id: 4, token: "address-recovery"};
    oracle.register({...request, handle: recovery, name: "ecRecover"});
    oracle.settle({operation: "address-recovery", document: "tab", currentDocument: "tab", handle: recovery, result: "account"});
});

test("lifecycle oracle rejects submission before checkpoint and duplicate dispatch", () => {
    const oracle = approved();
    oracle.execution(execution);
    assert.throws(() => oracle.dispatch(execution), error => error.invariant === "broadcast");
    oracle.signed(execution);
    oracle.checkpoint(execution);
    oracle.dispatch(execution);
    oracle.accepted({...execution, transactionID: "transaction"});
    assert.throws(() => oracle.dispatch(execution), error => error.invariant === "broadcast");
});

test("lifecycle oracle distinguishes fresh approval after abandonment from consumed consent replay", () => {
    const oracle = approved();
    oracle.execution(execution);
    assert.throws(() => oracle.execution({...execution, executionID: "replayed"}), error => error.invariant === "consent");
    oracle.approvalIntent({handle, label: "approval-two", revision: 2});
    oracle.acceptConsent({handle, label: "approval-two", revision: 2});
    oracle.execution({...execution, executionID: "after-new-consent", epoch: "approval-2"});
    assert.equal(oracle.executions.size, 2);
});

test("lifecycle oracle fences revocation before commitment but permits committed results", () => {
    for (const committed of [false, true]) {
        const oracle = approved();
        oracle.execution(execution);
        oracle.signed(execution);
        if (committed) { oracle.checkpoint(execution); }
        oracle.revoke({profileIdentifier: null, configurationKey: request.configurationKey});
        if (committed) { oracle.dispatch(execution); }
        else { assert.throws(() => oracle.checkpoint(execution), error => error.invariant === "revocation"); }
    }
});

test("lifecycle oracle rejects stale-authority restoration and cross-document success", () => {
    const oracle = new LifecycleOracle;
    const configuration = {profileIdentifier: null, configurationKey: request.configurationKey, generation: "document-one",
        state: {context: "context", revisions: {ethereum: 2, solana: 1}, ethereum: {address: "", chainId: "0x1"}, solana: null}};
    oracle.configuration(configuration);
    assert.throws(() => oracle.configuration({...configuration, state: {...configuration.state, revisions: {ethereum: 1, solana: 1}}}),
        error => error.invariant === "replay");
    assert.throws(() => oracle.settle({operation: "one", document: "old", currentDocument: "new", result: "signature"}),
        error => error.invariant === "isolation");
    oracle.settle({operation: "one", document: "old", currentDocument: "new", error: {code: 4900}});
    assert.throws(() => oracle.settle({operation: "one", document: "new", currentDocument: "new", result: "signature"}),
        error => error.invariant === "replay");
    assert.throws(() => oracle.requireCoverage(["broadcast.accepted"]), error => error.invariant === "coverage");
});

test("effect ledger durably records real RPC bytes and derives their transaction hash", async () => {
    const root = await mkdtemp(join(tmpdir(), "approval-ledger-"));
    const path = join(root, "effects.jsonl");
    const ledger = new EffectLedger(path);
    try {
        const oracle = approved();
        oracle.execution(execution);
        oracle.signed(execution);
        oracle.checkpoint(execution);
        const rpc = new FakeRPC({ledger, oracle});
        const reply = await rpc.respond({...execution, endpoint: "https://rpc.fixture.invalid/1", request: {id: 4, method: "eth_sendRawTransaction", params: ["0x010203"]}});
        assert.match(reply.result, /^0x[0-9a-f]{64}$/);
        assert.equal(reply.id, 4);
        const events = (await readFile(path, "utf8")).trim().split("\n").map(JSON.parse);
        assert.deepEqual(events.map(event => event.type), ["rpc.received", "rpc.accepted"]);
        assert.equal(events[0].bytes, "AQID");
        assert.equal(events[1].transactionID, reply.result);
        await assert.rejects(rpc.respond({request: {method: "unexpected", params: []}}), error => error.invariant === "rpc");
    } finally { ledger.close(); await rm(root, {recursive: true, force: true}); }
});

test("fixture RPC chain identity comes from the endpoint and rejects unrelated destinations", async () => {
    const rpc = new FakeRPC({oracle: new LifecycleOracle, ledger: {append() {}}});
    for (const [endpoint, expected] of [
        ["https://rpc.fixture.invalid/1", "0x1"], ["https://rpc.fixture.invalid/10", "0xa"],
        ["https://chain-1337.lifecycle.invalid", "0x539"], ["https://changed.fixture.invalid/1337", "0x539"],
    ]) {
        assert.equal((await rpc.respond({endpoint, chainId: "0xffff", request: {id: 2, method: "eth_chainId", params: []}})).result, expected);
    }
    for (const endpoint of [undefined, "https://unrecognized.invalid", "https://solana.fixture.invalid/solana-devnet"]) {
        await assert.rejects(rpc.respond({endpoint, request: {id: 2, method: "eth_chainId", params: []}}), error => error.invariant === "rpc");
    }
});

test("scheduler controls ordering, duplicated delivery, retirement and wall-clock movement", async () => {
    const scheduler = new Scheduler({now: 100});
    const seen = [];
    const first = scheduler.schedule(() => seen.push("first"), 0, "a", "message");
    const second = scheduler.schedule(() => seen.push("second"), 0, "b", "message");
    scheduler.hold(first);
    scheduler.duplicate(second);
    await scheduler.drain();
    assert.deepEqual(seen, ["second", "second"]);
    scheduler.release(first);
    await scheduler.drain();
    scheduler.schedule(() => seen.push("retired"), 5, "a");
    scheduler.retire("a");
    await scheduler.advance(-20);
    assert.equal(scheduler.now, 80);
    await scheduler.advance(30);
    assert.deepEqual(seen, ["second", "second", "first"]);
    const left = new Random(42), right = new Random(42);
    assert.deepEqual(Array.from({length: 32}, () => left.token()), Array.from({length: 32}, () => right.token()));
});

test("wall-clock rollback cannot postpone already scheduled browser timers", async () => {
    const scheduler = new Scheduler({now: 10000});
    let fired = false;
    scheduler.schedule(() => { fired = true; }, 1000);
    await scheduler.advance(-9000);
    await scheduler.advance(999);
    assert.equal(fired, false);
    await scheduler.advance(1);
    assert.equal(fired, true);
    assert.equal(scheduler.now, 2000);
});

test("execution effects cannot cross request handles or process incarnations", () => {
    for (const changed of [{handle: {...handle, token: "different"}}, {epoch: "approval-2"}]) {
        const oracle = approved();
        oracle.execution(execution);
        assert.throws(() => oracle.signed({...execution, ...changed}), error => error.invariant === "isolation");
    }
    const oracle = approved();
    oracle.execution(execution);
    oracle.signed(execution);
    oracle.checkpoint(execution);
    oracle.approvalIntent({handle, label: "second-approval"});
    oracle.acceptConsent({handle, label: "second-approval"});
    assert.throws(() => oracle.execution({...execution, executionID: "second"}), error => error.invariant === "broadcast");
});

test("only one execution can commit and dispatch a request after multiple fresh approvals", () => {
    for (const observedDurably of [false, true]) {
        for (const ownerIndex of [0, 1]) {
            const oracle = approved();
            oracle.execution(execution);
            oracle.signed(execution);
            oracle.approvalIntent({handle, label: "approval-two"});
            oracle.acceptConsent({handle, label: "approval-two"});
            const second = {...execution, executionID: "execution-two"};
            oracle.execution(second);
            oracle.signed(second);
            if (observedDurably) {
                oracle.observeDurable({handle, broadcastCheckpointed: true});
                for (const entry of [execution, second]) {
                    assert.throws(() => oracle.dispatch(entry), error => error.invariant === "broadcast");
                }
            }
            const entries = [execution, second];
            const owner = entries[ownerIndex], other = entries[1 - ownerIndex];
            oracle.checkpoint(owner);
            oracle.observeDurable({handle, broadcastCheckpointed: true});
            assert.throws(() => oracle.checkpoint(other), error => error.invariant === "broadcast");
            assert.throws(() => oracle.dispatch(other), error => error.invariant === "broadcast");
            oracle.dispatch(owner);
            oracle.accepted({...owner, transactionID: "transaction"});
            assert.throws(() => oracle.dispatch(owner), error => error.invariant === "broadcast");
            assert.equal([...oracle.executions.values()].reduce((count, entry) => count + entry.dispatches, 0), 1);
        }
    }
});

test("a higher revision cannot restore a revoked grant without another explicit connection approval", () => {
    const oracle = new LifecycleOracle;
    const state = (revision, address) => ({context: "context", revisions: {ethereum: revision, solana: 0},
        ethereum: {address, chainId: "0x1"}, solana: null});
    const envelope = {profileIdentifier: null, configurationKey: request.configurationKey, generation: "document-one"};
    oracle.register({...request, name: "requestAccounts"});
    oracle.approvalIntent({handle, label: "connect-one", selectedAccounts: [{coin: "ethereum", address: "0xAb"}]});
    oracle.acceptConsent({handle, label: "connect-one"});
    oracle.configuration({...envelope, state: state(1, "0xAb")});
    oracle.revoke({profileIdentifier: null, configurationKey: request.configurationKey, provider: "ethereum", attempt: "revoke-one"});
    oracle.configuration({...envelope, state: state(2, "")});
    assert.throws(() => oracle.configuration({...envelope, state: state(3, "0xab")}), error => error.invariant === "replay");
    const reconnect = {...handle, id: 3, token: "00000000-0000-0000-0000-000000000003"};
    oracle.register({...request, handle: reconnect, name: "requestAccounts"});
    oracle.approvalIntent({handle: reconnect, label: "connect-two", selectedAccounts: [{coin: "ethereum", address: "0xab"}]});
    oracle.acceptConsent({handle: reconnect, label: "connect-two"});
    oracle.configuration({...envelope, state: state(3, "0xab")});
    oracle.revoke({profileIdentifier: undefined, configurationKey: request.configurationKey, provider: "ethereum", attempt: "revoke-one"});
    oracle.configuration({...envelope, state: state(3, "0xab")});
});

test("a definite revocation permits a failed signing attempt but forbids a successful signature", () => {
    for (const succeeds of [false, true]) {
        const oracle = approved();
        oracle.revoke({profileIdentifier: null, configurationKey: request.configurationKey, provider: "ethereum"});
        oracle.execution(execution);
        if (succeeds) { assert.throws(() => oracle.signed({...execution, succeeded: true}), error => error.invariant === "revocation"); }
        else { oracle.signed({...execution, succeeded: false}); }
    }
});

test("a revocation observed before the acknowledged signing entry forbids a successful signature without a held gate", () => {
    for (const succeeds of [false, true]) {
        const oracle = approved();
        oracle.revoke({profileIdentifier: null, configurationKey: request.configurationKey, provider: "ethereum", definiteHandles: []});
        oracle.execution(execution);
        if (succeeds) { assert.throws(() => oracle.signed({...execution, succeeded: true}), error => error.invariant === "revocation"); }
        else { oracle.signed({...execution, succeeded: false}); }
    }
});

test("an unchanged old tab snapshot is not a new grant after another tab reconnects with a different account", () => {
    const oracle = new LifecycleOracle;
    const state = (revision, address) => ({context: "context", revisions: {ethereum: revision, solana: 0}, ethereum: {address, chainId: "0x1"}, solana: null});
    const envelope = {profileIdentifier: null, configurationKey: request.configurationKey};
    oracle.register({...request, name: "requestAccounts"});
    oracle.approvalIntent({handle, label: "initial-connect", selectedAccounts: [{coin: "ethereum", address: "0xAb"}]});
    oracle.acceptConsent({handle, label: "initial-connect"});
    oracle.configuration({...envelope, generation: "tab-one", state: state(1, "0xAb")});
    oracle.configuration({...envelope, generation: "tab-two", state: state(1, "0xAb")});
    oracle.revoke({...envelope, provider: "ethereum", attempt: "remove-first-account"});
    oracle.configuration({...envelope, generation: "tab-two", state: state(2, "")});
    const reconnect = {...handle, id: 4, token: "00000000-0000-0000-0000-000000000004"};
    oracle.register({...request, handle: reconnect, name: "requestAccounts"});
    oracle.approvalIntent({handle: reconnect, label: "replacement-connect", selectedAccounts: [{coin: "ethereum", address: "0xCd"}]});
    oracle.acceptConsent({handle: reconnect, label: "replacement-connect"});
    oracle.configuration({...envelope, generation: "tab-two", state: state(3, "0xCd")});
    oracle.configuration({...envelope, generation: "tab-one", state: state(1, "0xAb")});
    assert.throws(() => oracle.configuration({...envelope, generation: "tab-one", state: state(4, "0xAb")}), error => error.invariant === "replay");
});

test("older account snapshots need an earlier proven grant rather than pending or future consent", () => {
    for (const provider of ["ethereum", "solana"]) {
        for (const evidence of ["none", "intent", "consent", "future-committed", "future-observed"]) {
            const oracle = new LifecycleOracle;
            const envelope = {profileIdentifier: null, configurationKey: request.configurationKey};
            const name = provider === "ethereum" ? "requestAccounts" : "connect";
            const first = provider === "ethereum" ? "0xab" : "first-solana";
            const second = provider === "ethereum" ? "0xcd" : "second-solana";
            oracle.register({...request, provider, name});
            oracle.approvalIntent({handle, label: "first", selectedAccounts: [{coin: provider, address: first}]});
            oracle.acceptConsent({handle, label: "first"});
            oracle.configuration({...envelope, generation: "current-page", state: providerState(provider, 4, first)});
            if (evidence !== "none") {
                const other = {...handle, id: 2, token: "second"};
                oracle.register({...request, handle: other, provider, name});
                oracle.approvalIntent({handle: other, label: "second", selectedAccounts: [{coin: provider, address: second}]});
                if (evidence !== "intent") { oracle.acceptConsent({handle: other, label: "second"}); }
                if (evidence === "future-committed") { oracle.recordCommittedGrant({handle: other, state: providerState(provider, 5, second)}); }
                if (evidence === "future-observed") {
                    oracle.configuration({...envelope, generation: "current-page", state: providerState(provider, 5, second)});
                }
            }
            assert.throws(() => oracle.configuration({...envelope, generation: "late-page", state: providerState(provider, 3, second)}),
                error => error.invariant === "replay", `${provider}: ${evidence}`);
        }
    }
});

test("older proven accounts remain historical after another account connects and is revoked", () => {
    for (const provider of ["ethereum", "solana"]) {
        for (const evidence of ["committed", "observed"]) {
            const oracle = new LifecycleOracle;
            const envelope = {profileIdentifier: null, configurationKey: request.configurationKey};
            const name = provider === "ethereum" ? "requestAccounts" : "connect";
            const first = provider === "ethereum" ? "0xab" : "first-solana";
            const second = provider === "ethereum" ? "0xcd" : "second-solana";
            oracle.register({...request, provider, name});
            oracle.approvalIntent({handle, label: "first", selectedAccounts: [{coin: provider, address: first}]});
            oracle.acceptConsent({handle, label: "first"});
            if (evidence === "committed") { oracle.recordCommittedGrant({handle, state: providerState(provider, 1, first)}); }
            else { oracle.configuration({...envelope, generation: "current-page", state: providerState(provider, 1, first)}); }
            const other = {...handle, id: 2, token: "second"};
            oracle.register({...request, handle: other, provider, name});
            oracle.approvalIntent({handle: other, label: "second", selectedAccounts: [{coin: provider, address: second}]});
            oracle.acceptConsent({handle: other, label: "second"});
            oracle.configuration({...envelope, generation: "current-page", state: providerState(provider, 4, second)});
            oracle.revoke({...envelope, provider});
            oracle.configuration({...envelope, generation: "current-page", state: providerState(provider, 5, null)});
            const permission = oracle.permission(null, request.configurationKey, provider);
            const before = structuredClone({...permission, authorityHistory: undefined});
            oracle.configuration({...envelope, generation: "late-page", state: providerState(provider, 3, first)});
            assert.deepEqual({...permission, authorityHistory: undefined}, before);
            assert.equal(permission.revoked, true);
            assert.throws(() => oracle.configuration({...envelope, generation: "late-page", state: providerState(provider, 6, first)}),
                error => error.invariant === "replay");
        }
    }
});

test("historical accounts stay within known grant and revocation intervals", () => {
    for (const provider of ["ethereum", "solana"]) {
        for (const evidence of ["committed", "observed"]) {
            const oracle = new LifecycleOracle;
            const envelope = {profileIdentifier: null, configurationKey: request.configurationKey};
            const first = provider === "ethereum" ? "0xab" : "first-solana";
            const second = provider === "ethereum" ? "0xcd" : "second-solana";
            const grant = (revision, address) => {
                const grantedHandle = {...handle, id: revision, token: `grant-${revision}`};
                oracle.register({...request, handle: grantedHandle, provider, name: provider === "ethereum" ? "requestAccounts" : "connect"});
                oracle.approvalIntent({handle: grantedHandle, label: `grant-${revision}`, selectedAccounts: [{coin: provider, address}]});
                oracle.acceptConsent({handle: grantedHandle, label: `grant-${revision}`});
                const state = providerState(provider, revision, address);
                if (evidence === "committed") { oracle.recordCommittedGrant({handle: grantedHandle, state}); }
                else { oracle.configuration({...envelope, generation: "current-page", state}); }
            };
            const historical = (revision, address) => oracle.configuration({...envelope,
                generation: `late-page-${revision}`, state: providerState(provider, revision, address)});
            grant(1, first);
            oracle.revoke({...envelope, provider});
            oracle.configuration({...envelope, generation: "current-page", state: providerState(provider, 2, null)});
            grant(4, second);
            oracle.configuration({...envelope, generation: "current-page", state: providerState(provider, 4, second)});
            historical(1, first);
            assert.throws(() => historical(3, first), error => error.invariant === "replay", `${provider}: ${evidence}`);
            grant(6, first);
            oracle.configuration({...envelope, generation: "current-page", state: providerState(provider, 6, first)});
            grant(9, second);
            oracle.configuration({...envelope, generation: "current-page", state: providerState(provider, 9, second)});
            assert.throws(() => historical(5, first), error => error.invariant === "replay");
            const intermediate = providerState(provider, 7, first);
            if (provider === "ethereum") { intermediate.ethereum.chainId = "0xa"; }
            oracle.configuration({...envelope, generation: "late-network-page", state: intermediate});
            historical(3, null);
            assert.equal(oracle.permission(null, request.configurationKey, provider).lastObserved.address, second);
        }
    }
});

test("network-only authority revisions retain their complete state across documents", () => {
    for (const currentRevision of [2, 3]) {
        const oracle = new LifecycleOracle;
        const envelope = {profileIdentifier: null, configurationKey: request.configurationKey};
        oracle.register({...request, name: "requestAccounts"});
        oracle.approvalIntent({handle, label: "connect", selectedAccounts: [{coin: "ethereum", address: "0xab"}]});
        oracle.acceptConsent({handle, label: "connect"});
        oracle.recordCommittedGrant({handle, state: providerState("ethereum", 1, "0xab")});
        const state = providerState("ethereum", 2, "0xab");
        state.ethereum.chainId = "0xa";
        oracle.configuration({...envelope, generation: "first-page", state});
        if (currentRevision === 3) {
            oracle.configuration({...envelope, generation: "first-page", state: providerState("ethereum", 3, "0xab")});
        }
        const changed = structuredClone(state);
        changed.ethereum.chainId = "0x539";
        assert.throws(() => oracle.configuration({...envelope, generation: "second-page", state: changed}), error => error.invariant === "replay");
        oracle.configuration({...envelope, generation: "second-page", state: {...state,
            ethereum: {chainId: state.ethereum.chainId, address: state.ethereum.address}}});
    }
});

test("backfilled revocations invalidate inferred account snapshots in either delivery order", () => {
    for (const provider of ["ethereum", "solana"]) {
        for (const order of ["before-replacement", "after-replacement"]) {
            for (const regrant of [false, true]) {
                const oracle = new LifecycleOracle;
                const envelope = {profileIdentifier: null, configurationKey: request.configurationKey};
                const first = provider === "ethereum" ? "0xab" : "first-solana";
                const second = provider === "ethereum" ? "0xcd" : "second-solana";
                const grant = (revision, address) => {
                    const grantedHandle = {...handle, id: revision, token: `grant-${revision}`};
                    oracle.register({...request, handle: grantedHandle, provider, name: provider === "ethereum" ? "requestAccounts" : "connect"});
                    oracle.approvalIntent({handle: grantedHandle, label: `grant-${revision}`, selectedAccounts: [{coin: provider, address}]});
                    oracle.acceptConsent({handle: grantedHandle, label: `grant-${revision}`});
                    oracle.recordCommittedGrant({handle: grantedHandle, state: providerState(provider, revision, address)});
                };
                const observe = (revision, address) => oracle.configuration({...envelope,
                    generation: `page-${revision}`, state: providerState(provider, revision, address)});
                grant(1, first);
                observe(1, first);
                if (regrant) { grant(3, first); }
                if (order === "before-replacement") { observe(3, first); }
                grant(4, second);
                observe(4, second);
                if (order === "after-replacement") { observe(3, first); }
                if (regrant) {
                    observe(2, null);
                    observe(1, first);
                    observe(3, first);
                } else {
                    assert.throws(() => observe(2, null), error => error.invariant === "replay", `${provider}: ${order}`);
                }
                assert.equal(oracle.permission(null, request.configurationKey, provider).lastObserved.address, second);
            }
        }
    }
});

test("one approval cannot become another grant at a later observed or committed revision", () => {
    for (const provider of ["ethereum", "solana"]) {
        for (const evidence of ["committed", "observed"]) {
            const oracle = new LifecycleOracle;
            const address = provider === "ethereum" ? "0xab" : "first-solana";
            const envelope = {profileIdentifier: null, configurationKey: request.configurationKey};
            oracle.register({...request, provider, name: provider === "ethereum" ? "requestAccounts" : "connect"});
            oracle.approvalIntent({handle, label: "connect", selectedAccounts: [{coin: provider, address}]});
            oracle.acceptConsent({handle, label: "connect"});
            const initial = providerState(provider, 1, address);
            if (evidence === "committed") { oracle.recordCommittedGrant({handle, state: initial}); }
            else { oracle.configuration({...envelope, generation: "first-page", state: initial}); }
            const network = providerState(provider, 4, address);
            if (provider === "ethereum") { network.ethereum.chainId = "0xa"; }
            oracle.configuration({...envelope, generation: "first-page", state: network});
            oracle.recordCommittedGrant({handle, state: network});
            assert.throws(() => oracle.configuration({...envelope, generation: "late-page", state: providerState(provider, 2, null)}),
                error => error.invariant === "replay", `${provider}: ${evidence}`);
        }
    }
});

test("earlier native proof refines an observed grant without predating its reviewed authority", () => {
    for (const provider of ["ethereum", "solana"]) {
        for (const evidence of ["earlier", "same-review", "backfilled-revocation", "before-review", "other-context"]) {
            const oracle = new LifecycleOracle;
            const address = provider === "ethereum" ? "0xab" : "first-solana";
            const envelope = {profileIdentifier: null, configurationKey: request.configurationKey};
            const authority = {context: evidence === "other-context" ? "other" : "context",
                revisions: providerState(provider, evidence === "before-review" ? 2 : evidence === "same-review" ? 1 : 0, null).revisions};
            oracle.register({...request, provider, authority, name: provider === "ethereum" ? "requestAccounts" : "connect"});
            oracle.approvalIntent({handle, label: "connect", selectedAccounts: [{coin: provider, address}]});
            oracle.acceptConsent({handle, label: "connect"});
            const earlier = () => oracle.recordCommittedGrant({handle, state: providerState(provider, 1, address)});
            if (["same-review", "before-review", "other-context"].includes(evidence)) { earlier(); }
            oracle.configuration({...envelope, generation: "first-page", state: providerState(provider, 4, address, authority.context)});
            const disconnected = () => oracle.configuration({...envelope, generation: "disconnected-page", state: providerState(provider, 2, null)});
            if (evidence === "backfilled-revocation") {
                disconnected();
                assert.throws(earlier, error => error.invariant === "replay");
            } else {
                earlier();
                const historical = () => oracle.configuration({...envelope, generation: "late-page", state: providerState(provider, 1, address)});
                if (["earlier", "same-review"].includes(evidence)) {
                    historical();
                    assert.throws(disconnected, error => error.invariant === "replay");
                } else {
                    assert.throws(historical, error => error.invariant === "replay");
                    disconnected();
                }
            }
        }
    }
});

test("configuration grants remain bound to the reviewed authority context and revision", () => {
    for (const provider of ["ethereum", "solana"]) {
        for (const invalid of ["other-context", "before-review"]) {
            for (const revision of [2, 3]) {
                const oracle = new LifecycleOracle;
                const address = provider === "ethereum" ? "0xab" : "selected-solana";
                const envelope = {profileIdentifier: null, configurationKey: request.configurationKey, generation: "page"};
                oracle.configuration({...envelope, state: providerState(provider, 0, null)});
                oracle.register({...request, provider, name: provider === "ethereum" ? "requestAccounts" : "connect",
                    authority: {context: "context", revisions: providerState(provider, 2, null).revisions}});
                oracle.approvalIntent({handle, label: "connect", selectedAccounts: [{coin: provider, address}]});
                oracle.acceptConsent({handle, label: "connect"});
                const stale = providerState(provider, invalid === "before-review" ? 1 : 3, address,
                    invalid === "other-context" ? "other" : "context");
                assert.throws(() => oracle.configuration({...envelope, state: stale}), error => error.invariant === "replay",
                    `${provider}: ${invalid}`);
                const permission = oracle.permission(null, request.configurationKey, provider);
                assert.equal(permission.tickets.length, 1);
                assert.equal(permission.grantBoundaries.size, 0);
                oracle.configuration({...envelope, state: providerState(provider, revision, address)});
                assert.deepEqual(permission.grantBoundaries.get("connect"), {context: "context", revision});
            }
        }
    }
});

test("historical account evidence stays scoped to its profile, origin, provider and authority context", () => {
    for (const provider of ["ethereum", "solana"]) {
        for (const scope of ["profile", "origin", "provider", "context"]) {
            const oracle = new LifecycleOracle;
            const envelope = {profileIdentifier: null, configurationKey: request.configurationKey};
            const name = provider === "ethereum" ? "requestAccounts" : "connect";
            const first = provider === "ethereum" ? "0xab" : "first-solana";
            const second = provider === "ethereum" ? "0xcd" : "second-solana";
            const foreign = {...envelope,
                ...(scope === "profile" ? {profileIdentifier: "another-profile"} : {}),
                ...(scope === "origin" ? {configurationKey: "https://other.example"} : {})};
            const foreignProvider = scope === "provider" ? provider === "ethereum" ? "solana" : "ethereum" : provider;
            const foreignHandle = {...handle, id: 2, token: "foreign", profileIdentifier: foreign.profileIdentifier};
            oracle.register({...request, ...foreign, handle: foreignHandle, provider: foreignProvider,
                name: foreignProvider === "ethereum" ? "requestAccounts" : "connect"});
            oracle.approvalIntent({handle: foreignHandle, label: "foreign", selectedAccounts: [{coin: foreignProvider, address: second}]});
            oracle.acceptConsent({handle: foreignHandle, label: "foreign"});
            oracle.recordCommittedGrant({handle: foreignHandle, state: providerState(foreignProvider, 1, second, scope === "context" ? "foreign-context" : "context")});
            oracle.register({...request, provider, name});
            oracle.approvalIntent({handle, label: "first", selectedAccounts: [{coin: provider, address: first}]});
            oracle.acceptConsent({handle, label: "first"});
            oracle.configuration({...envelope, generation: "current-page", state: providerState(provider, 4, first)});
            assert.throws(() => oracle.configuration({...envelope, generation: "late-page", state: providerState(provider, 3, second)}),
                error => error.invariant === "replay", `${provider}: ${scope}`);
        }
    }
});

test("connection consent grants only the exact reviewed account for its provider", () => {
    for (const [provider, name, expected, other] of [
        ["ethereum", "requestAccounts", "0x1111111111111111111111111111111111111111", "0x2222222222222222222222222222222222222222"],
        ["solana", "connect", "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk", "9hSR6S7WPtxmTojgo6GG3k4yDPecgJY292j7xrsUGWBu"],
    ]) {
        const oracle = new LifecycleOracle;
        oracle.register({...request, provider, name});
        oracle.approvalIntent({handle, label: "selected", selectedAccounts: [{coin: provider, address: expected}]});
        oracle.acceptConsent({handle, label: "selected"});
        const configuration = address => ({profileIdentifier: null, configurationKey: request.configurationKey, generation: "page",
            state: {context: "context", revisions: {ethereum: provider === "ethereum" ? 1 : 0, solana: provider === "solana" ? 1 : 0},
                ethereum: {address: provider === "ethereum" ? address : "", chainId: "0x1"}, solana: provider === "solana" ? {publicKey: address} : null}});
        assert.throws(() => oracle.configuration(configuration(other)), error => error.invariant === "replay");
        oracle.configuration(configuration(expected));
    }
});

test("manual account selection binds each provider separately and cannot grant an unselected provider", () => {
    const state = (ethereum, solana) => ({context: "context", revisions: {ethereum: 1, solana: 1}, ethereum: {address: ethereum, chainId: "0x1"}, solana: solana && {publicKey: solana}});
    for (const includeSolana of [false, true]) {
        const oracle = new LifecycleOracle;
        oracle.register({...request, provider: "unknown", name: "switchAccount"});
        oracle.approvalIntent({handle, label: "selection", selectedAccounts: [{coin: "ethereum", address: "0xAb"},
            ...(includeSolana ? [{coin: "solana", address: "selected-solana"}] : [])]});
        oracle.acceptConsent({handle, label: "selection"});
        const envelope = {profileIdentifier: null, configurationKey: request.configurationKey, generation: "page"};
        assert.throws(() => oracle.configuration({...envelope, state: state("0xab", "wrong-solana")}), error => error.invariant === "replay");
        oracle.configuration({...envelope, state: state("0xab", includeSolana ? "selected-solana" : null)});
    }
});

test("a newer empty authority snapshot revokes grants even when revocation telemetry was lost", () => {
    const oracle = new LifecycleOracle;
    const envelope = {profileIdentifier: null, configurationKey: request.configurationKey, generation: "page"};
    const state = (revision, address) => ({context: "context", revisions: {ethereum: revision, solana: 0}, ethereum: {address, chainId: "0x1"}, solana: null});
    oracle.register({...request, name: "requestAccounts"});
    oracle.approvalIntent({handle, label: "connect", selectedAccounts: [{coin: "ethereum", address: "0xAb"}]});
    oracle.acceptConsent({handle, label: "connect"});
    oracle.configuration({...envelope, state: state(2, "0xab")});
    oracle.configuration({...envelope, generation: "old-tab", state: state(1, "")});
    oracle.configuration({...envelope, state: state(3, "0xab")});
    oracle.configuration({...envelope, state: state(4, "")});
    assert.throws(() => oracle.configuration({...envelope, state: state(5, "0xab")}), error => error.invariant === "replay");
});

test("newer empty authority invalidates pending first grants while preserving freshly reviewed consent", () => {
    for (const acceptedBeforeObservation of [false, true]) {
        const oracle = new LifecycleOracle;
        const envelope = {profileIdentifier: null, configurationKey: request.configurationKey, generation: "page"};
        const state = (revision, address) => ({context: "context", revisions: {ethereum: revision, solana: 0}, ethereum: {address, chainId: "0x1"}, solana: null});
        oracle.configuration({...envelope, state: state(0, "")});
        oracle.register({...request, name: "requestAccounts", authority: {context: "context", revisions: {ethereum: 0, solana: 0}}});
        oracle.approvalIntent({handle, label: "old", selectedAccounts: [{coin: "ethereum", address: "0xAb"}]});
        const fresh = {...handle, id: 12, token: "fresh-review"};
        oracle.register({...request, handle: fresh, name: "requestAccounts", authority: {context: "context", revisions: {ethereum: 1, solana: 0}}});
        oracle.approvalIntent({handle: fresh, label: "fresh", selectedAccounts: [{coin: "ethereum", address: "0xCd"}]});
        if (acceptedBeforeObservation) {
            oracle.acceptConsent({handle, label: "old"});
            oracle.acceptConsent({handle: fresh, label: "fresh"});
        }
        oracle.configuration({...envelope, state: state(1, "")});
        if (!acceptedBeforeObservation) {
            oracle.acceptConsent({handle, label: "old"});
            oracle.acceptConsent({handle: fresh, label: "fresh"});
        }
        assert.throws(() => oracle.configuration({...envelope, state: state(2, "0xab")}), error => error.invariant === "replay");
        oracle.configuration({...envelope, generation: "old-page", state: state(0, "")});
        oracle.configuration({...envelope, state: state(2, "0xcd")});
    }
});

test("delayed disconnection snapshots preserve consent reviewed against the newer authority", () => {
    for (const acceptedBeforeObservation of [false, true]) {
        const oracle = new LifecycleOracle;
        const envelope = {profileIdentifier: null, configurationKey: request.configurationKey, generation: "page"};
        const state = (revision, address) => ({context: "context", revisions: {ethereum: revision, solana: 0}, ethereum: {address, chainId: "0x1"}, solana: null});
        oracle.register({...request, name: "requestAccounts"});
        oracle.approvalIntent({handle, label: "first", selectedAccounts: [{coin: "ethereum", address: "0xAb"}]});
        oracle.acceptConsent({handle, label: "first"});
        oracle.configuration({...envelope, state: state(1, "0xab")});
        const reconnect = {...handle, id: 9, token: "reconnect"};
        oracle.register({...request, handle: reconnect, name: "requestAccounts", authority: {context: "context", revisions: {ethereum: 2, solana: 0}}});
        oracle.approvalIntent({handle: reconnect, label: "new", selectedAccounts: [{coin: "ethereum", address: "0xCd"}]});
        if (acceptedBeforeObservation) { oracle.acceptConsent({handle: reconnect, label: "new"}); }
        oracle.configuration({...envelope, state: state(2, "")});
        if (!acceptedBeforeObservation) { oracle.acceptConsent({handle: reconnect, label: "new"}); }
        oracle.configuration({...envelope, state: state(3, "0xcd")});
    }
});

test("approving a revoked connection handle cannot grant accounts but a fresh request can", () => {
    for (const [provider, name] of [["ethereum", "requestAccounts"], ["solana", "connect"], ["unknown", "switchAccount"]]) {
        for (const observeDisconnection of [false, true]) {
            const oracle = new LifecycleOracle;
            const coin = provider === "solana" ? "solana" : "ethereum";
            const address = coin === "ethereum" ? "0xab" : "selected-solana";
            const envelope = {profileIdentifier: null, configurationKey: request.configurationKey, generation: "page"};
            const state = (revision, connected) => ({context: "context", revisions: {ethereum: coin === "ethereum" ? revision : 0, solana: coin === "solana" ? revision : 0},
                ethereum: {address: connected && coin === "ethereum" ? address : "", chainId: "0x1"},
                solana: connected && coin === "solana" ? {publicKey: address} : null});
            oracle.configuration({...envelope, state: state(0, false)});
            oracle.register({...request, provider, name, authority: {context: "context", revisions: state(0, false).revisions}});
            oracle.revoke({...envelope, provider: coin, definiteHandles: [], beforeSigningHandles: []});
            if (observeDisconnection) { oracle.configuration({...envelope, state: state(1, false)}); }
            oracle.approvalIntent({handle, label: "stale-review", selectedAccounts: [{coin, address}]});
            oracle.acceptConsent({handle, label: "stale-review"});
            assert.throws(() => oracle.configuration({...envelope, state: state(2, true)}), error => error.invariant === "replay");

            const fresh = {...handle, id: 13, token: "fresh-after-revocation"};
            oracle.register({...request, handle: fresh, provider, name, authority: {context: "context", revisions: state(1, false).revisions}});
            oracle.approvalIntent({handle: fresh, label: "fresh-review", selectedAccounts: [{coin, address}]});
            oracle.acceptConsent({handle: fresh, label: "fresh-review"});
            oracle.configuration({...envelope, state: state(2, true)});
        }
    }
});

test("removing a reviewed account invalidates unpublished grant intent before or after consent acceptance", () => {
    for (const acceptedBeforeRemoval of [false, true]) {
        const oracle = new LifecycleOracle;
        const envelope = {profileIdentifier: null, configurationKey: request.configurationKey, generation: "page"};
        const state = {context: "context", revisions: {ethereum: 1, solana: 0}, ethereum: {address: "0xab", chainId: "0x1"}, solana: null};
        oracle.register({...request, account: undefined, name: "requestAccounts"});
        oracle.approvalIntent({handle, label: "pending", selectedAccounts: [{coin: "ethereum", address: "0xAb"}]});
        if (acceptedBeforeRemoval) { oracle.acceptConsent({handle, label: "pending"}); }
        oracle.revoke({profileIdentifier: null, provider: "ethereum", account: "0xab"});
        if (!acceptedBeforeRemoval) { oracle.acceptConsent({handle, label: "pending"}); }
        assert.throws(() => oracle.configuration({...envelope, state}), error => error.invariant === "replay");
        const restored = {...handle, id: 10, token: "new-request-after-restore"};
        oracle.register({...request, handle: restored, account: undefined, name: "requestAccounts"});
        oracle.approvalIntent({handle: restored, label: "fresh-after-restore", selectedAccounts: [{coin: "ethereum", address: "0xAb"}]});
        oracle.acceptConsent({handle: restored, label: "fresh-after-restore"});
        oracle.configuration({...envelope, state});
    }
});

test("removing a pending account leaves an unrelated granted account valid", () => {
    const oracle = new LifecycleOracle;
    const envelope = {profileIdentifier: null, configurationKey: request.configurationKey, generation: "page"};
    const state = revision => ({context: "context", revisions: {ethereum: revision, solana: 0}, ethereum: {address: "0xcd", chainId: "0x1"}, solana: null});
    oracle.register({...request, account: undefined, name: "requestAccounts"});
    oracle.approvalIntent({handle, label: "existing", selectedAccounts: [{coin: "ethereum", address: "0xCd"}]});
    oracle.acceptConsent({handle, label: "existing"});
    oracle.configuration({...envelope, state: state(1)});
    const pending = {...handle, id: 11, token: "other-account"};
    oracle.register({...request, handle: pending, account: undefined, name: "requestAccounts"});
    oracle.approvalIntent({handle: pending, label: "pending", selectedAccounts: [{coin: "ethereum", address: "0xAb"}]});
    oracle.acceptConsent({handle: pending, label: "pending"});
    oracle.revoke({profileIdentifier: null, provider: "ethereum", account: "0xab"});
    oracle.configuration({...envelope, state: state(2)});
    assert.throws(() => oracle.configuration({...envelope, state: {...state(3), ethereum: {address: "0xab", chainId: "0x1"}}}), error => error.invariant === "replay");
});

test("a delayed committed grant is historical after account removal and cannot authorize newer restoration", () => {
    for (const provider of ["ethereum", "solana"]) {
        for (const alreadyObserved of [false, true]) {
            const oracle = new LifecycleOracle;
            const address = provider === "ethereum" ? "0xab" : "selected-solana";
            const envelope = {profileIdentifier: null, configurationKey: request.configurationKey, generation: "page"};
            const state = (revision, connected) => ({context: "context", revisions: {ethereum: provider === "ethereum" ? revision : 0, solana: provider === "solana" ? revision : 0},
                ethereum: {address: connected && provider === "ethereum" ? address : "", chainId: "0x1"},
                solana: connected && provider === "solana" ? {publicKey: address} : null});
            const connection = {...request, provider, name: provider === "ethereum" ? "requestAccounts" : "connect",
                authority: {context: "context", revisions: state(0, false).revisions}};
            oracle.configuration({...envelope, state: state(0, false)});
            oracle.register(connection);
            oracle.approvalIntent({handle, label: "committed", selectedAccounts: [{coin: provider, address}]});
            oracle.acceptConsent({handle, label: "committed"});
            if (alreadyObserved) { oracle.configuration({...envelope, state: state(1, true)}); }
            oracle.recordCommittedGrant({handle, state: state(1, true)});
            oracle.revoke({...envelope, provider, account: address});
            oracle.configuration({...envelope, state: state(1, true)});
            oracle.settle({operation: "delayed-connect", document: "page", currentDocument: "page", handle, result: address});
            assert.throws(() => oracle.configuration({...envelope, state: state(2, true)}), error => error.invariant === "replay");
            oracle.configuration({...envelope, state: state(2, false)});
            assert.throws(() => oracle.configuration({...envelope, state: state(3, true)}), error => error.invariant === "replay");

            const fresh = {...handle, id: 14, token: "fresh-after-delayed-grant"};
            oracle.register({...connection, handle: fresh, authority: {context: "context", revisions: state(2, false).revisions}});
            oracle.approvalIntent({handle: fresh, label: "fresh", selectedAccounts: [{coin: provider, address}]});
            oracle.acceptConsent({handle: fresh, label: "fresh"});
            oracle.configuration({...envelope, state: state(3, true)});
        }
    }
});

test("historical grants require exact committed state observed before revocation", () => {
    for (const invalid of ["unapproved", "wrong-account", "late-observation", "changed-state", "changed-context"]) {
        const oracle = new LifecycleOracle;
        const envelope = {profileIdentifier: null, configurationKey: request.configurationKey, generation: "page"};
        const state = {context: "context", revisions: {ethereum: 1, solana: 0}, ethereum: {address: "0xab", chainId: "0x1"}, solana: null};
        oracle.register({...request, name: "requestAccounts"});
        oracle.approvalIntent({handle, label: "connect", selectedAccounts: [{coin: "ethereum", address: invalid === "wrong-account" ? "0xcd" : "0xab"}]});
        if (invalid !== "unapproved") { oracle.acceptConsent({handle, label: "connect"}); }
        if (invalid === "late-observation") { oracle.revoke({...envelope, provider: "ethereum", definiteHandles: []}); }
        oracle.recordCommittedGrant({handle, state});
        if (invalid !== "late-observation") { oracle.revoke({...envelope, provider: "ethereum", definiteHandles: []}); }
        const delivered = structuredClone(state);
        if (invalid === "changed-state") { delivered.ethereum.chainId = "0xa"; }
        if (invalid === "changed-context") { delivered.context = "another-context"; }
        assert.throws(() => oracle.configuration({...envelope, state: delivered}), error => error.invariant === "replay");
    }
});

test("historical grants remain exact after another document observes the same or newer revision", () => {
    for (const observedRevision of [1, 2]) {
        const oracle = new LifecycleOracle;
        const envelope = {profileIdentifier: null, configurationKey: request.configurationKey};
        const state = (revision, connected) => ({context: "context", revisions: {ethereum: revision, solana: 0},
            ethereum: {address: connected ? "0xab" : "", chainId: "0x1"}, solana: null});
        oracle.register({...request, name: "requestAccounts"});
        oracle.approvalIntent({handle, label: "committed", selectedAccounts: [{coin: "ethereum", address: "0xab"}]});
        oracle.acceptConsent({handle, label: "committed"});
        oracle.recordCommittedGrant({handle, state: state(1, true)});
        oracle.configuration({...envelope, generation: "first-page", state: state(1, true)});
        oracle.revoke({...envelope, provider: "ethereum", account: "0xab"});
        if (observedRevision === 2) { oracle.configuration({...envelope, generation: "first-page", state: state(2, false)}); }

        const delayed = {...envelope, generation: "second-page", state: state(1, true)};
        const changed = structuredClone(delayed);
        changed.state.ethereum.chainId = "0xa";
        assert.throws(() => oracle.configuration(changed), error => error.invariant === "replay");
        oracle.configuration(delayed);
        assert.equal(oracle.permission(null, request.configurationKey, "ethereum").revoked, true);
        for (const generation of ["first-page", "second-page"]) {
            oracle.configuration({...envelope, generation, state: state(2, false)});
        }
        assert.throws(() => oracle.configuration({...delayed, state: state(3, true)}), error => error.invariant === "replay");

        const fresh = {...handle, id: 15, token: "fresh-after-cross-document-history"};
        oracle.register({...request, handle: fresh, name: "requestAccounts"});
        oracle.approvalIntent({handle: fresh, label: "fresh", selectedAccounts: [{coin: "ethereum", address: "0xab"}]});
        oracle.acceptConsent({handle: fresh, label: "fresh"});
        oracle.configuration({...delayed, state: state(3, true)});
    }
});
