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
            export {outboundDataSnapshot} from "./outbound_snapshot";
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
            const {intrinsics: i, OperationRuntime, outboundDataSnapshot} = module.exports;
            const runtime = new OperationRuntime("generation");
            const weak = new WeakMap;
            const key = {};
            const targets = family === "reflection" ? [
                [Reflect, "apply"], [Object, "create"], [Object, "defineProperty"],
                [Object, "freeze"], [Object, "getOwnPropertyDescriptor"],
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
                    snapshot,
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
