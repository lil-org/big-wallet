import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import {createRequire} from "node:module";
import test from "node:test";

const require = createRequire(import.meta.url);
const rawWire = require("../Resources/popup_wire.js");
const normalized = value => JSON.parse(JSON.stringify(value));
const wire = {
    decodeQueue: (...args) => normalized(rawWire.decodeQueue(...args)),
    decodeApprovalState: (...args) => normalized(rawWire.decodeApprovalState(...args)),
    decodeCommandResult: (...args) => normalized(rawWire.decodeCommandResult(...args)),
};
const wireFixtures = JSON.parse(await readFile(new URL("fixtures/popup_contract.json", import.meta.url), "utf8"));

const fixtures = Object.fromEntries(Object.entries(wireFixtures).map(([name, value]) => [name, value.approval ?? value]));

for (const [name, value] of Object.entries(wireFixtures)) {
    test(`popup contract decodes the shared ${name} fixture`, () => {
        const decoded = value.requests ? wire.decodeQueue(value)
            : wire.decodeCommandResult(value, value.approval?.id);
        assert.deepEqual(decoded, value);
    });
}

test("popup decoder rejects unknown fields at every owned object boundary", () => {
    for (const edit of [
        source => { source.extra = "unexpected"; },
        source => { source.review.extra = "unexpected"; },
        source => { source.review.accounts[0].extra = "unexpected"; },
        source => { source.actions.push("arbitraryAction"); },
    ]) {
        const source = structuredClone(fixtures.selectAccount);
        edit(source);
        assert.equal(wire.decodeApprovalState(source, source.id), null);
    }
});

test("popup decoding rejects malformed decorative images without changing the source", () => {
    const source = structuredClone(fixtures.signMessage);
    source.review.account.icon = 7;
    const before = structuredClone(source);
    assert.equal(wire.decodeApprovalState(source, source.id), null);
    assert.deepEqual(source, before);
    source.review.account.icon = null;
    assert.equal(wire.decodeApprovalState(source, source.id), null);
});

test("popup decoding requires matching identity and complete transaction fields", () => {
    assert.equal(wire.decodeApprovalState(fixtures.legacyTransaction, 92), null);
    const source = structuredClone(fixtures.type2Transaction);
    delete source.review.editor.maxFeePerGasGwei;
    assert.equal(wire.decodeApprovalState(source, source.id), null);
    assert.equal(wire.decodeApprovalState({...fixtures.working, review: fixtures.signMessage.review}, 91), null);
});

test("popup transaction backoff accepts only a boolean when present", () => {
    for (const canBackOffRefresh of [undefined, null, "true", 1, [], {}, false, true]) {
        const source = structuredClone(fixtures.legacyTransaction);
        source.review.canBackOffRefresh = canBackOffRefresh;
        const before = structuredClone(source);
        assert.deepEqual(wire.decodeApprovalState(source, source.id),
            typeof canBackOffRefresh === "boolean" ? source : null);
        assert.deepEqual(source, before);
    }
    const source = structuredClone(fixtures.legacyTransaction);
    delete source.review.canBackOffRefresh;
    assert.deepEqual(wire.decodeApprovalState(source, source.id), source);
});

test("popup queue allows absent metadata but rejects malformed present metadata", () => {
    const queue = structuredClone(fixtures.queue);
    delete queue.layoutDirection;
    delete queue.strings;
    assert.deepEqual(wire.decodeQueue(queue), queue);
    for (const [field, values] of [
        ["strings", [undefined, null, "translations", [], {refresh: "Refresh", cancel: 1}]],
        ["layoutDirection", [undefined, null, "auto", true, [], {}]],
    ]) {
        for (const value of values) {
            const source = {...structuredClone(queue), [field]: value};
            const before = structuredClone(source);
            assert.equal(wire.decodeQueue(source), null);
            assert.deepEqual(source, before);
        }
    }
    for (const layoutDirection of ["ltr", "rtl"]) {
        const source = {...queue, layoutDirection, strings: {refresh: "Refresh"}};
        assert.deepEqual(wire.decodeQueue(source), source);
    }
});

test("popup edit feedback is command scoped and only accompanies successful command responses", () => {
    const approval = fixtures.legacyTransaction;
    const response = {status: "ok", approval, editsError: true};
    assert.deepEqual(wire.decodeCommandResult(response, approval.id), response);
    for (const editsError of [false, null, "true", undefined]) {
        assert.equal(wire.decodeCommandResult({...response, editsError}, approval.id), null);
    }
    for (const status of ["ignored", "unavailable"]) {
        assert.equal(wire.decodeCommandResult({...response, status}, approval.id), null);
    }
    assert.deepEqual(wire.decodeCommandResult({status: "ok", approval}, approval.id), {status: "ok", approval});
});

test("popup queue and command replies retain their exact identity contracts", () => {
    const queue = structuredClone(fixtures.queue);
    queue.completedResponses[0].extra = true;
    assert.equal(wire.decodeQueue(queue), null);
    assert.equal(wire.decodeCommandResult({status: "ok", actions: ["approve"]}), null);
    assert.equal(wire.decodeCommandResult({status: "arbitrary"}), null);
    assert.equal(wire.decodeCommandResult(undefined), null);
    assert.equal(wire.decodeCommandResult({status: "ok"}, 91), null);
    assert.equal(wire.decodeCommandResult({status: "ok", approval: null}, 91), null);
    assert.equal(wire.decodeCommandResult(fixtures.working, 91), null);
    assert.equal(wire.decodeCommandResult(wireFixtures.working, 92), null);
    assert.equal(wire.decodeCommandResult({...wireFixtures.working, extra: true}, 91), null);
    for (const status of ["ignored", "unavailable"]) {
        const empty = {status, approval: null};
        assert.deepEqual(wire.decodeCommandResult(empty, 91), empty);
    }
    const current = {status: "ignored", approval: fixtures.working};
    assert.deepEqual(wire.decodeCommandResult(current, 91), current);
    assert.equal(wire.decodeCommandResult({status: "unavailable", approval: fixtures.working}, 91), null);
    assert.equal(wire.decodeCommandResult({status: "unavailable", approval: fixtures.legacyTransaction}, 91), null);
});

test("popup selection identities fold Ethereum address case and retain distinct derivation paths", () => {
    const source = structuredClone(fixtures.selectAccount);
    source.review.accounts[0].address = `0x${"ab".repeat(20)}`;
    source.review.accounts.push({
        ...source.review.accounts[0],
        address: `0x${"AB".repeat(20)}`,
        isSelected: false,
    });
    assert.equal(wire.decodeApprovalState(source, source.id), null);

    source.review.accounts[1].derivationPath = "m/44'/60'/0'/0/1";
    assert.deepEqual(wire.decodeApprovalState(source, source.id), source);
});

test("popup editors validate and preserve fee fields outside the active fee model", () => {
    for (const [fixture, field] of [
        [fixtures.type2Transaction, "gasPriceGwei"],
        [fixtures.legacyTransaction, "maxFeePerGasGwei"],
    ]) {
        const source = structuredClone(fixture);
        source.review.editor[field] = "12";
        assert.deepEqual(wire.decodeApprovalState(source, source.id), source);

        source.review.editor[field] = 12;
        assert.equal(wire.decodeApprovalState(source, source.id), null);
    }
});

test("popup optional fields distinguish absent properties from invalid values", () => {
    const queue = structuredClone(fixtures.queue);
    delete queue.layoutDirection;
    delete queue.strings;
    delete queue.requests[0].enqueueAttempt;
    assert.deepEqual(wire.decodeQueue(queue), queue);
    for (const value of [undefined, null]) {
        const source = structuredClone(queue);
        source.requests[0].enqueueAttempt = value;
        assert.equal(wire.decodeQueue(source), null);
    }
    const working = {id: fixtures.working.id, state: "working", actions: []};
    assert.deepEqual(wire.decodeApprovalState(working, working.id), working);
    for (const field of ["host", "error", "review"]) {
        for (const value of [undefined, null]) {
            assert.equal(wire.decodeApprovalState({...working, [field]: value}, working.id), null);
        }
    }
    const message = structuredClone(fixtures.signMessage);
    delete message.review.account.icon;
    assert.deepEqual(wire.decodeApprovalState(message, message.id), message);
    for (const value of [undefined, null]) {
        const source = structuredClone(message);
        source.review.account.icon = value;
        assert.equal(wire.decodeApprovalState(source, source.id), null);
    }
});
