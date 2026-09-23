import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import {createRequire} from "node:module";
import test from "node:test";

const require = createRequire(import.meta.url);
const wire = require("../Resources/popup_wire.js");
const wireFixtures = JSON.parse(await readFile(new URL("fixtures/popup_contract.json", import.meta.url), "utf8"));

const fixtures = Object.fromEntries(Object.entries(wireFixtures).map(([name, value]) => [name, value.approval ?? value]));

for (const [name, value] of Object.entries(wireFixtures)) {
    test(`popup contract decodes the shared ${name} fixture`, () => {
        const decoded = value.requests ? wire.decodeQueue(value)
            : wire.decodeCommandResult(value, value.approval?.id);
        assert.deepEqual(decoded, value);
    });
}

test("popup decoder projects display fields without admitting new capabilities", () => {
    const source = structuredClone(fixtures.selectAccount);
    source.extra = "ignored";
    source.review.extra = "ignored";
    source.review.accounts[0].extra = "ignored";
    assert.deepEqual(wire.decodeApprovalState(source, source.id), fixtures.selectAccount);
    source.actions.push("arbitraryAction");
    assert.equal(wire.decodeApprovalState(source, source.id), null);
});

test("popup decoding removes malformed decorative images without changing the source", () => {
    const source = structuredClone(fixtures.signMessage);
    source.review.account.icon = 7;
    const before = structuredClone(source);
    const decoded = wire.decodeApprovalState(source, source.id);
    assert.equal(decoded.review.account.icon, undefined);
    assert.deepEqual(source, before);
    source.review.meta = null;
    assert.equal(wire.decodeApprovalState(source, source.id), null);
});

test("popup decoding requires matching identity and complete transaction fields", () => {
    assert.equal(wire.decodeApprovalState(fixtures.legacyTransaction, 92), null);
    const source = structuredClone(fixtures.type2Transaction);
    delete source.review.editor.maxFeePerGasGwei;
    assert.equal(wire.decodeApprovalState(source, source.id), null);
    assert.equal(wire.decodeApprovalState({...fixtures.working, review: fixtures.signMessage.review}, 91), null);
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

test("popup optional fields omit undefined and reject null except for decorative images", () => {
    const queue = structuredClone(fixtures.queue);
    delete queue.layoutDirection;
    delete queue.strings;
    delete queue.requests[0].enqueueAttempt;
    const queueWithUndefined = structuredClone(queue);
    queueWithUndefined.layoutDirection = undefined;
    queueWithUndefined.strings = undefined;
    queueWithUndefined.requests[0].enqueueAttempt = undefined;
    assert.deepEqual(wire.decodeQueue(queueWithUndefined), queue);
    for (const field of ["layoutDirection", "strings"]) {
        assert.equal(wire.decodeQueue({...queueWithUndefined, [field]: null}), null);
    }
    queueWithUndefined.requests[0].enqueueAttempt = null;
    assert.equal(wire.decodeQueue(queueWithUndefined), null);

    const working = {id: fixtures.working.id, state: "working", actions: []};
    const workingWithUndefined = {
        ...working, host: undefined, error: undefined, editsError: undefined, review: undefined,
    };
    assert.deepEqual(wire.decodeApprovalState(workingWithUndefined, working.id), working);
    for (const field of ["host", "error", "editsError", "review"]) {
        assert.equal(wire.decodeApprovalState({...workingWithUndefined, [field]: null}, working.id), null);
    }

    const message = structuredClone(fixtures.signMessage);
    delete message.review.account.icon;
    const messageWithUndefined = structuredClone(message);
    Object.assign(messageWithUndefined.review, {
        primaryTitle: undefined, alert: undefined, clusters: undefined,
        requiresClusterSelection: undefined,
    });
    messageWithUndefined.review.account.icon = undefined;
    assert.deepEqual(wire.decodeApprovalState(messageWithUndefined, message.id), message);
    for (const field of ["primaryTitle", "alert", "clusters", "requiresClusterSelection"]) {
        const source = structuredClone(messageWithUndefined);
        source.review[field] = null;
        assert.equal(wire.decodeApprovalState(source, source.id), null);
    }
    messageWithUndefined.review.account.icon = null;
    assert.deepEqual(wire.decodeApprovalState(messageWithUndefined, message.id), message);
});
