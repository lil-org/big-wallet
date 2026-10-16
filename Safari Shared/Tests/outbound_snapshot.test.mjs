import assert from "node:assert/strict";
import {createRequire} from "node:module";
import test from "node:test";
import {fileURLToPath} from "node:url";
import vm from "node:vm";

const providerDirectory = new URL("../Inpage Provider/", import.meta.url);
const providerRequire = createRequire(new URL("package.json", providerDirectory));
const {buildSync} = providerRequire("esbuild");
const source = buildSync({
    bundle: true,
    stdin: {
        contents: `
            export {
                outboundDataSnapshot,
                trustedOutboundArray,
                trustedOutboundRecord,
            } from "./outbound_snapshot";
        `,
        resolveDir: fileURLToPath(providerDirectory),
    },
    format: "cjs",
    logLevel: "silent",
    platform: "browser",
    target: "safari15",
    write: false,
}).outputFiles[0].text;

function harness() {
    const context = vm.createContext({module: {exports: {}}});
    new vm.Script(source).runInContext(context);
    return context;
}

test("trusted payload containers preserve normalized data after inherited toJSON changes", () => {
    const result = new vm.Script(`(() => {
        const {outboundDataSnapshot, trustedOutboundArray, trustedOutboundRecord} =
            module.exports;
        let calls = 0;
        const normalized = outboundDataSnapshot({
            nested: {toJSON() { calls += 1; return {value: 7}; }},
            toJSON: "literal",
            ["__proto__"]: {value: 8},
        });
        Object.prototype.toJSON = () => { throw new Error("Object toJSON called"); };
        Array.prototype.toJSON = () => { throw new Error("Array toJSON called"); };
        const array = trustedOutboundArray([normalized]);
        const record = trustedOutboundRecord(normalized);
        const payload = trustedOutboundRecord({array, record});
        const serialized = JSON.stringify(payload);
        delete Object.prototype.toJSON;
        delete Array.prototype.toJSON;
        return {
            serialized,
            calls,
            frozen: [payload, array, record].every(Object.isFrozen),
            sharedNestedData: record.nested === normalized.nested,
            nullPrototype: Object.getPrototypeOf(record) === null,
            arrayIdentity: Array.isArray(array),
        };
    })()`).runInContext(harness());
    assert.deepEqual(JSON.parse(JSON.stringify(result)), {
        serialized: JSON.stringify({
            array: [{nested: {value: 7}, toJSON: "literal", ["__proto__"]: {value: 8}}],
            record: {nested: {value: 7}, toJSON: "literal", ["__proto__"]: {value: 8}},
        }),
        calls: 1,
        frozen: true,
        sharedNestedData: true,
        nullPrototype: true,
        arrayIdentity: true,
    });
});
