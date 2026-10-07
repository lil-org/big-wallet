import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import test from "node:test";
import {generateCases} from "../../Scripts/wire_protocol_fuzz_cases.mjs";

const definition = JSON.parse(await readFile(new URL("../Protocol/wire-protocol.json", import.meta.url), "utf8"));
const fixtures = JSON.parse(await readFile(new URL("fixtures/wire_protocol_contract.json", import.meta.url), "utf8"));
const generate = options => generateCases({definition, fixtures, ...options});

test("fuzz cases reproduce a uint32 seed without changing inputs", () => {
    const before = JSON.stringify({definition, fixtures});
    const first = generate({seed: 0, iterations: 90});
    assert.deepEqual(first, generate({seed: 0, iterations: 90}));
    assert.equal(JSON.stringify({definition, fixtures}), before);
    assert.equal(first.filter(value => value.name.startsWith("random:")).length, 90);
    assert.notDeepEqual(first, generate({seed: 0xffffffff, iterations: 90}));
    assert.deepEqual(first.filter(value => !value.name.startsWith("random:")),
        generate({seed: 42, iterations: 0}));
});

test("fuzz seeds retain every independent fixture and every named contract", () => {
    const cases = generate({iterations: 0});
    assert.equal(cases.filter(value => value.name.startsWith("fixture:")).length, fixtures.length);
    for (const fixture of fixtures) {
        assert.deepEqual(cases.find(value => value.name === `fixture:${fixture.name}`), {
            name: `fixture:${fixture.name}`, type: fixture.type, value: fixture.value, expectedValid: fixture.valid,
        });
    }
    assert.deepEqual(new Set(cases.filter(value => value.expectedValid).map(value => value.type)), new Set(Object.keys(definition.types)));
    assert.equal(new Set(cases.map(value => value.name)).size, cases.length);
    assert.ok(cases.length > fixtures.length + 300);
    assert.ok(generate({iterations: 1000}).length < 10000);
});

test("numeric boundaries include adjacent safe and signed64 representations", () => {
    const cases = generate({iterations: 0});
    const numbers = type => cases.filter(value => value.name.startsWith(`boundary:number:${type}:`));
    assert.ok(numbers("RequestID").some(value => value.value === 2 ** 53 && value.expectedValid === false));
    assert.ok(numbers("RequestID").some(value => value.value === -(2 ** 53) && value.expectedValid === false));
    assert.ok(numbers("RequestID").some(value => value.value === Number.MAX_SAFE_INTEGER && value.expectedValid === true));
    const errors = numbers("ErrorCode");
    for (const boundary of [-(2 ** 63), 2 ** 63]) {
        assert.ok(errors.some(value => value.value === boundary && value.expectedValid === true));
    }
    assert.ok(errors.some(value => value.value < -(2 ** 63) && value.expectedValid === false));
    assert.ok(errors.some(value => value.value > 2 ** 63 && value.expectedValid === false));
    assert.ok(errors.some(value => value.value === 0.5 && value.expectedValid === false));
    assert.ok(numbers("PositiveInteger").some(value => value.value === Number.MIN_VALUE && value.expectedValid === false));
    assert.ok(numbers("RequestID").some(value => value.value === Number.MAX_VALUE && value.expectedValid === false));
});

test("structural mutations preserve own prototype-named fields", () => {
    const cases = generate({iterations: 0});
    for (const key of ["__proto__", "constructor"]) {
        const candidate = cases.find(value => value.name === `boundary:field:Revisions:${key}:unknown`);
        assert.ok(Object.hasOwn(candidate.value, key));
        assert.deepEqual(candidate.value[key], {polluted: true});
        assert.equal(Object.getPrototypeOf(candidate.value), Object.prototype);
        assert.equal(Object.prototype.polluted, undefined);
    }
    const revisions = fixtures.find(value => value.valid && value.type === "Revisions").value;
    assert.deepEqual(cases.find(value => value.name === "boundary:field:Revisions:ethereum:missing").value, {solana: revisions.solana});
    assert.equal(cases.find(value => value.name === "boundary:field:Revisions:ethereum:null").value.ethereum, null);
    const ready = cases.filter(value => value.name.startsWith("boundary:response-ready:"));
    assert.deepEqual(ready.map(value => [value.value.ids.length, value.expectedValid]),
        [[0, false], [1, true], [15, true], [16, true], [17, false]]);
    assert.ok(cases.some(value => value.name.startsWith("boundary:array:PopupApprovalState.variant2.actions:") && value.value.actions.length === 1));
});

test("depth boundaries account for response envelopes and reserved delivery nesting", () => {
    const depth = value => !value || typeof value !== "object" ? 0
        : 1 + Math.max(0, ...Object.values(value).map(depth));
    const cases = generate({iterations: 0}).filter(value => value.name.startsWith("boundary:depth:"));
    assert.equal(cases.length, 27);
    for (const candidate of cases) {
        const actualDepth = depth(candidate.value);
        const limit = definition.constants.MAX_JSON_DEPTH - definition.depthReservations[candidate.type];
        assert.equal(actualDepth, Number(candidate.name.split(":").at(-1)));
        assert.equal(candidate.expectedValid, actualDepth <= limit);
    }
});

test("Unicode candidates use UTF16 lengths without isolated surrogate code units", () => {
    const cases = generate({seed: 8, iterations: 250});
    const strings = [];
    const inspect = value => {
        if (typeof value === "string") { strings.push(value); }
        if (value && typeof value === "object") {
            for (const [key, child] of Object.entries(value)) { strings.push(key); inspect(child); }
        }
    };
    for (const candidate of cases) { inspect(candidate.value); }
    assert.ok(strings.includes("🧪"));
    assert.ok(strings.includes("e\u0301"));
    assert.ok(cases.some(value => value.name.includes('"🧪":2')));
    assert.ok(cases.some(value => value.name.includes('"é":2')));
    for (const value of strings) {
        for (const scalar of value) {
            assert.ok(scalar.length === 2 || scalar.charCodeAt(0) < 0xd800 || scalar.charCodeAt(0) > 0xdfff);
        }
    }
    assert.equal(JSON.stringify(JSON.parse(JSON.stringify(cases))), JSON.stringify(cases));
});

test("mandatory Unicode dictionary collisions reject ambiguity while retaining noncanonical keys", () => {
    const cases = generate({iterations: 0}).filter(value => value.name.startsWith("boundary:unicode-keys:"));
    assert.equal(cases.length, 12);
    for (const candidate of cases) {
        const dictionary = candidate.type === "RPCResponse"
            ? candidate.value.result.nested[0] : candidate.value.error.data.nested[0];
        const keys = Object.keys(dictionary);
        assert.equal(keys.length, 2);
        assert.notEqual(keys[0], keys[1]);
        if (candidate.name.endsWith(":collision")) {
            assert.equal(candidate.expectedValid, false);
            assert.equal(keys[0].normalize("NFC"), keys[1].normalize("NFC"));
            assert.equal(dictionary[keys[0]], "first");
            assert.equal(dictionary[keys[1]], "second");
        } else {
            assert.equal(candidate.expectedValid, true);
            assert.notEqual(keys[0].normalize("NFC"), keys[1].normalize("NFC"));
            assert.ok(keys.some(key => key !== key.normalize("NFC")));
        }
        assert.deepEqual(JSON.parse(JSON.stringify(dictionary)), dictionary);
    }
});

test("mandatory protocol-field mutations include canonically equivalent Kelvin spellings", () => {
    const cases = generate({iterations: 0});
    for (const [type, key, equivalent] of [
        ["SolanaConfiguration", "publicKey", "publicKey"],
        ["RuntimeResponseRequest", "configurationKey", "configurationKey"],
    ]) {
        for (const mode of ["renamed", "collision"]) {
            const candidate = cases.find(value => value.name === `boundary:unicode-field:${type}:${key}:${mode}`);
            assert.equal(candidate.expectedValid, false);
            assert.ok(Object.hasOwn(candidate.value, equivalent));
            assert.equal(Object.hasOwn(candidate.value, key), mode === "collision");
            assert.equal(key, equivalent.normalize("NFC"));
        }
    }
});

test("random schema samples and fixture mutations both contribute independent cases", () => {
    const cases = generate({seed: 123, iterations: 120}).filter(value => value.name.startsWith("random:"));
    assert.equal(cases.filter(value => value.name.includes(":schema:")).length, 40);
    assert.equal(cases.filter(value => value.name.includes(":mutation:")).length, 80);
    assert.ok(new Set(cases.map(value => value.type)).size > 20);
    assert.ok(cases.every(value => !Object.hasOwn(value, "expectedValid")));
    const knownValues = new Set(fixtures.filter(value => value.valid).map(value => JSON.stringify(value.value)));
    assert.ok(cases.filter(value => !knownValues.has(JSON.stringify(value.value))).length > 60);
});

test("fuzz options reject invalid counts and seeds", () => {
    for (const seed of [-1, 2 ** 32, 0.5, NaN, Infinity, "1"]) {
        assert.throws(() => generate({seed, iterations: 0}), TypeError);
    }
    for (const iterations of [-1, 0.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1]) {
        assert.throws(() => generate({iterations}), TypeError);
    }
    assert.throws(() => generateCases({definition, fixtures: [], iterations: 1}), /valid fixtures/);
});
