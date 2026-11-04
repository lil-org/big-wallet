import assert from "node:assert/strict";
import test from "node:test";
import {collectSimulatorRuntimeDiagnostics} from "../guest.mjs";

const success = value => ({code: 0, output: JSON.stringify(value), timedOut: false, cancelled: false});
const runtimes = {runtimes: [{identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
    version: "27.0", buildversion: "24A434", isAvailable: true}]};

test("runtime diagnostics retain the existing inventory and only issue bounded metadata queries", async () => {
    const calls = [];
    const stopRequested = async () => false;
    const images = {"fixture-image": {build: "24A434", state: "Ready", path: "/Library/Developer/CoreSimulator/Images/fixture.dmg"}};
    const matches = {"iOS 27.2": {System: "24A434"}};
    const result = await collectSimulatorRuntimeDiagnostics(success(runtimes), {stopRequested,
        execute: async (command, args, options) => {
            calls.push([command, ...args]);
            assert.equal(options.timeoutSeconds, 20);
            assert.equal(options.stopRequested, stopRequested);
            return success(args.includes("match") ? matches : images);
        }});
    assert.deepEqual(calls, [["xcrun", "simctl", "runtime", "list", "-j"],
        ["xcrun", "simctl", "runtime", "match", "list", "-j"]]);
    assert.deepEqual(result, {runtimes, images, matches, issues: []});
});

test("runtime diagnostics reject oversized malformed primitive and deeply nested payloads", async () => {
    let nested = {};
    for (let index = 0; index < 20; index++) { nested = {nested}; }
    for (const bad of [{...success({}), output: "{"}, success(null), success(true), success("metadata"),
        success({large: "x".repeat(1024 * 1024)}), success(nested), success(Array.from({length: 33000}, () => 0))]) {
        const result = await collectSimulatorRuntimeDiagnostics(bad, {execute: async () => bad});
        assert.equal(result.runtimes, null);
        assert.equal(result.images, null);
        assert.equal(result.matches, null);
        assert.equal(result.issues.length, 3);
        assert.ok(result.issues.every(issue => issue.length < 80));
    }
});

test("failed cancelled timed out or throwing metadata queries are recorded without escaping", async () => {
    for (const execute of [async () => ({...success({}), code: 1}), async () => ({...success({}), cancelled: true}),
        async () => ({...success({}), timedOut: true}), async () => { throw new Error("unavailable"); }]) {
        const result = await collectSimulatorRuntimeDiagnostics(success(runtimes), {execute});
        assert.deepEqual(result.runtimes, runtimes);
        assert.equal(result.images, null);
        assert.equal(result.matches, null);
        assert.equal(result.issues.length, 2);
    }
});

test("diagnostic JSON uses stdout and measures UTF-8 bytes before retention", async () => {
    const result = await collectSimulatorRuntimeDiagnostics({...success(runtimes), stdout: JSON.stringify(runtimes),
        output: "stderr is not JSON"}, {execute: async () => ({...success({}), stdout: JSON.stringify({large: "é".repeat(600000)})})});
    assert.deepEqual(result.runtimes, runtimes);
    assert.deepEqual(result.issues, ["images: output_exceeds_limit", "matches: output_exceeds_limit"]);
});
