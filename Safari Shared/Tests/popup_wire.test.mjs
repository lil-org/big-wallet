import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import {createRequire} from "node:module";
import test from "node:test";

const require = createRequire(import.meta.url);
const wire = require("../Resources/popup_wire.js");
const fixtures = JSON.parse(await readFile(new URL("fixtures/popup_contract.json", import.meta.url), "utf8"));

for (const [name, value] of Object.entries(fixtures)) {
    test(`popup contract decodes the shared ${name} fixture`, () => {
        const decoded = value.requests ? wire.decodeQueue(value)
            : value.state ? wire.decodeApprovalState(value, value.id)
                : wire.decodeCommandResult(value);
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
    source.review.iconURL = {invalid: true};
    source.review.account.icon = 7;
    const before = structuredClone(source);
    const decoded = wire.decodeApprovalState(source, source.id);
    assert.equal(decoded.review.iconURL, undefined);
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
});
