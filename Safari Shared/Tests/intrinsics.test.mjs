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
            export * as intrinsics from "./intrinsics";
            export {default as OperationRuntime} from "./operation_runtime";
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

test("shared intrinsics preserve collection receivers and invalid-receiver errors", () => {
    const result = new vm.Script(`(() => {
        const i = module.exports.intrinsics;
        const key = {};
        const first = new Map;
        const second = new Map;
        const firstWeak = new WeakMap;
        const secondWeak = new WeakMap;
        const returns = [
            i.setMapEntry(first, key, "first"),
            i.setMapEntry(second, key, "second"),
            i.setWeakMapValue(firstWeak, key, "firstWeak"),
            i.setWeakMapValue(secondWeak, key, "secondWeak"),
        ];
        const errors = [];
        for (const operation of [
            () => i.getMapEntry({}, key),
            () => i.setMapEntry({}, key, 1),
            () => i.getWeakMapValue({}, key),
            () => i.setWeakMapValue({}, key, 1),
            () => i.hasOwnProperty(null, "key"),
        ]) {
            try { operation(); } catch (error) { errors.push(error.name); }
        }
        return {
            values: [
                i.getMapEntry(first, key), i.getMapEntry(second, key),
                i.getWeakMapValue(firstWeak, key), i.getWeakMapValue(secondWeak, key),
            ],
            voidSetters: returns.every(value => value === undefined),
            errors,
        };
    })()`).runInContext(harness());
    assert.deepEqual(JSON.parse(JSON.stringify(result)), {
        values: ["first", "second", "firstWeak", "secondWeak"],
        voidSetters: true,
        errors: Array(5).fill("TypeError"),
    });
});

for (const family of ["reflection", "collections"]) {
    test(`provider operations retain captured ${family} functions after page mutation`, async () => {
        const context = harness();
        context.family = family;
        const result = await new vm.Script(`(async () => {
            const {
                intrinsics: i, OperationRuntime, outboundDataSnapshot,
                trustedOutboundArray, trustedOutboundRecord,
            } = module.exports;
            const runtime = new OperationRuntime("generation");
            const weak = new WeakMap;
            const key = {};
            const targets = family === "reflection" ? [
                [Reflect, "apply"], [Object, "create"], [Object, "defineProperty"],
                [Object, "freeze"], [Object, "getOwnPropertyDescriptor"],
                [Object, "getOwnPropertyNames"],
                [Object.prototype, "hasOwnProperty"], [Array, "isArray"],
                [Array.prototype, "push"], [Number, "isSafeInteger"],
                [globalThis, "TypeError"],
            ] : [
                [Map.prototype, "get"], [Map.prototype, "set"],
                [WeakMap.prototype, "get"], [WeakMap.prototype, "set"],
                [globalThis, "Map"],
            ];
            const originals = targets.map(([target, name]) => target[name]);
            try {
                for (let index = 0; index < targets.length; index += 1) {
                    const [target, name] = targets[index];
                    target[name] = () => { throw new Error("Page replaced " + name); };
                }
                const map = new i.MapConstructor;
                i.setMapEntry(map, key, "map");
                i.setWeakMapValue(weak, key, "weak");
                const value = i.createObjectNormally(null);
                i.definePropertyNormally(value, "owned", {value: true, enumerable: true});
                i.freezeObjectNormally(value);
                const record = runtime.register({payload: {value: 7}});
                runtime.enqueue(record);
                runtime.drain(operation => operation.resolve(operation.payload.value));
                const snapshot = outboundDataSnapshot({items: [1, 2]});
                return {
                    settled: await record.promise,
                    map: i.getMapEntry(map, key),
                    weak: i.getWeakMapValue(weak, key),
                    owned: i.hasOwnProperty(value, "owned"),
                    descriptor: i.getOwnPropertyDescriptorNormally(value, "owned").value,
                    array: i.isArrayNormally(snapshot.items),
                    integer: i.isSafeIntegerNormally(7),
                    error: new i.TypeErrorConstructor("captured").name,
                    snapshot: trustedOutboundRecord({
                        items: trustedOutboundArray(snapshot.items),
                    }),
                };
            } finally {
                for (let index = 0; index < targets.length; index += 1) {
                    targets[index][0][targets[index][1]] = originals[index];
                }
            }
        })()`).runInContext(context);
        assert.deepEqual(JSON.parse(JSON.stringify(result)), {
            settled: 7,
            map: "map",
            weak: "weak",
            owned: true,
            descriptor: true,
            array: true,
            integer: true,
            error: "TypeError",
            snapshot: {items: [1, 2]},
        });
    });
}

test("trusted payload containers preserve normalized data under prototype changes", () => {
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

test("trusted payload definitions ignore inherited descriptor getters", () => {
    const result = new vm.Script(`(() => {
        const {trustedOutboundArray, trustedOutboundRecord} = module.exports;
        const fields = ["configurable", "writable", "enumerable", "get", "set"];
        for (const field of fields) {
            Object.defineProperty(Object.prototype, field, {
                __proto__: null,
                configurable: true,
                get() { throw new Error("Inherited descriptor getter: " + field); },
            });
        }
        try {
            const record = trustedOutboundRecord({value: "0x1"});
            const array = trustedOutboundArray(["2"]);
            return {
                record,
                array,
                frozen: Object.isFrozen(record) && Object.isFrozen(array),
                toJSON: Object.getOwnPropertyDescriptor(array, "toJSON"),
            };
        } finally {
            for (const field of fields) { delete Object.prototype[field]; }
        }
    })()`).runInContext(harness());
    assert.deepEqual(JSON.parse(JSON.stringify(result)), {
        record: {value: "0x1"},
        array: ["2"],
        frozen: true,
        toJSON: {writable: false, enumerable: false, configurable: false},
    });
});
