import assert from "node:assert/strict";
import {mkdtemp, readFile, realpath, rm} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import test from "node:test";
import {atomicJSON, hashFile} from "../guest_bootstrap.mjs";
import {coverageReport, executeStages, prepareNativeSimulators} from "../guest.mjs";
import {createManifest, PERFORMANCE_ENV, PERFORMANCE_TESTS, PLATFORMS, BOOTSTRAP_TOOL_NAMES, validateJob} from "../test_manifest.mjs";

const ios = "11111111-1111-1111-1111-111111111111";
const visionos = "22222222-2222-2222-2222-222222222222";
const unrelated = "33333333-3333-3333-3333-333333333333";
const destinations = {macos: "platform=macOS,arch=arm64", ios: `platform=iOS Simulator,id=${ios}`, visionos: `platform=visionOS Simulator,id=${visionos}`};
const success = output => ({code: 0, signal: null, stdout: output ?? "", output: output ?? "", timedOut: false, cancelled: false});
const inventory = (iosState = "Booted", visionState = "Shutdown") => JSON.stringify({devices: {
    "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [{udid: ios, state: iosState, isAvailable: true}, {udid: unrelated, state: "Booted", isAvailable: true}],
    "com.apple.CoreSimulator.SimRuntime.xrOS-27-0": [{udid: visionos, state: visionState, isAvailable: true}],
}});
const fixture = async fn => {
    const root = await realpath(await mkdtemp(join(tmpdir(), "big-wallet-simulator-unit-")));
    try { return await fn(root); } finally { await rm(root, {recursive: true, force: true}); }
};
const job = ({payload, ...overrides} = {}) => ({version: 1, runId: "simulator-fixture", vmId: "fixture-vm", kind: "run", profile: "all", payload: {stages: [], onlyTesting: [], ...payload},
    bootstrapTools: Object.fromEntries(BOOTSTRAP_TOOL_NAMES.map(name => [name, "a".repeat(64)])),
    source: {sha256: "b".repeat(64), commit: "c".repeat(40)}, ...overrides});
const nativeStage = {id: "test.visionos.debug", group: "test", command: "xcodebuild", args: ["test-without-building"],
    cwd: ".", dependencies: [], requirements: [], timeoutSeconds: 60, resultBundle: true,
    nativeAudit: {configuration: "Debug", platform: "visionos", kind: "full"}};

test("simulator preparation shuts down only another selected device before booting and waiting for the target", async () => fixture(async root => {
    const calls = [];
    const stopRequested = async () => false;
    const preparation = await prepareNativeSimulators("visionos", {writeJSON: atomicJSON, destinations, artifacts: root, stageId: nativeStage.id, stopRequested,
        execute: async (command, args, options) => {
            calls.push(args);
            assert.equal(command, "xcrun");
            assert.equal(options.stopRequested, stopRequested);
            assert.ok(options.timeoutSeconds > 0 && options.timeoutSeconds <= 300);
            assert.equal(options.logPath, join(root, `${nativeStage.id}.simulator-${calls.length}-${args[1]}.log`));
            return success(args[1] === "list" ? inventory() : "ready");
        }});
    assert.deepEqual(calls, [["simctl", "list", "devices", "--json"], ["simctl", "shutdown", ios],
        ["simctl", "boot", visionos], ["simctl", "bootstatus", visionos, "-b"]]);
    assert.equal(preparation.status, "passed");
    assert.deepEqual(JSON.parse(await readFile(join(root, preparation.artifact), "utf8")), preparation);
    assert.ok(preparation.steps.every(step => step.status === "passed"));
    assert.ok(!JSON.stringify(calls).includes(unrelated));
}));

test("an already booted target still waits for readiness without issuing boot again", async () => fixture(async root => {
    const calls = [];
    const preparation = await prepareNativeSimulators("visionos", {writeJSON: atomicJSON, destinations, artifacts: root, stageId: nativeStage.id,
        execute: async (_command, args) => { calls.push(args); return success(args[1] === "list" ? inventory("Shutdown", "Booted") : ""); }});
    assert.equal(preparation.status, "passed");
    assert.deepEqual(calls, [["simctl", "list", "devices", "--json"], ["simctl", "bootstatus", visionos, "-b"]]);
}));

test("macOS tests shut down both selected booted simulators and preserve unrelated devices", async () => fixture(async root => {
    const calls = [];
    const preparation = await prepareNativeSimulators("macos", {writeJSON: atomicJSON, destinations, artifacts: root, stageId: "test.macos.debug",
        execute: async (_command, args) => { calls.push(args); return success(args[1] === "list" ? inventory("Booted", "Booted") : ""); }});
    assert.equal(preparation.status, "passed");
    assert.equal(preparation.target, null);
    assert.deepEqual(calls, [["simctl", "list", "devices", "--json"], ["simctl", "shutdown", ios], ["simctl", "shutdown", visionos]]);
}));

test("macOS tests with no selected simulators need no simulator commands", async () => fixture(async root => {
    const preparation = await prepareNativeSimulators("macos", {writeJSON: atomicJSON, destinations: {macos: destinations.macos}, artifacts: root, stageId: "test.macos.debug",
        execute: async () => { throw new Error("Unexpected simulator command"); }});
    assert.equal(preparation.status, "passed");
    assert.deepEqual(preparation.steps, []);
}));

for (const [label, outcome, expected] of [
    ["failure", {...success(), code: 1}, "failed"],
    ["timeout", {...success(), code: null, timedOut: true}, "failed"],
    ["cancellation", {...success(), code: null, cancelled: true}, "cancelled"],
]) {
    test(`bootstatus ${label} is retained and prevents XCTest without retrying or blocking independent work`, async () => fixture(async root => {
        const calls = [];
        const later = {id: "later", group: "repository", command: "fixture-command", args: [], cwd: ".", dependencies: [], requirements: [], timeoutSeconds: 1};
        const results = await executeStages([nativeStage, later], {writeJSON: atomicJSON, hashFile, workspace: root, artifacts: root, preflight: {checks: {}, destinations},
            execute: async (command, args) => {
                calls.push([command, ...args]);
                assert.notEqual(command, "xcodebuild");
                if (args[1] === "list") { return success(inventory("Shutdown", "Booted")); }
                return args[1] === "bootstatus" ? outcome : success();
            }});
        assert.deepEqual(results.map(result => result.status), [expected, "passed"]);
        assert.equal(results[0].simulatorPreparation.status, expected);
        assert.equal(results[0].simulatorPreparation.steps.at(-1).status, expected);
        assert.equal(calls.filter(call => call.includes("bootstatus")).length, 1);
        assert.equal(calls.at(-1)[0], "fixture-command");
        const saved = JSON.parse(await readFile(join(root, results[0].simulatorPreparation.artifact), "utf8"));
        assert.equal(saved.status, expected);
        assert.match(saved.reason, label === "timeout" ? /300s/ : label === "cancellation" ? /Stop requested/ : /exit code 1/);
    }));
}

test("a stop between preparation commands prevents the next mutation", async () => fixture(async root => {
    const calls = [];
    const preparation = await prepareNativeSimulators("visionos", {writeJSON: atomicJSON, destinations, artifacts: root, stageId: nativeStage.id,
        stopRequested: async () => calls.length === 1,
        execute: async (_command, args) => { calls.push(args); return success(inventory()); }});
    assert.equal(preparation.status, "cancelled");
    assert.deepEqual(calls, [["simctl", "list", "devices", "--json"]]);
}));

test("malformed simulator destinations are rejected before invoking simctl", async () => fixture(async root => {
    const preparation = await prepareNativeSimulators("visionos", {writeJSON: atomicJSON, destinations: {...destinations, ios: "platform=iOS Simulator,id=all"},
        artifacts: root, stageId: nativeStage.id, execute: async () => { throw new Error("Unexpected simulator command"); }});
    assert.equal(preparation.status, "failed");
    assert.match(preparation.reason, /Invalid selected ios/);
    assert.deepEqual(preparation.steps, []);
}));

test("build stages stay untouched and successful simulator preparation runs immediately before XCTest", async () => fixture(async root => {
    const build = {...nativeStage, id: "build-tests.visionos.debug", group: "build", args: ["build-for-testing"], nativeAudit: undefined, resultBundle: false};
    const calls = [];
    const results = await executeStages([build, nativeStage], {writeJSON: atomicJSON, hashFile, workspace: root, artifacts: root, preflight: {checks: {}, destinations},
        execute: async (command, args) => {
            calls.push([command, ...args]);
            if (args[0] === "simctl") { return success(args[1] === "list" ? inventory("Shutdown", "Booted") : ""); }
            if (args[0] === "xcresulttool") {
                return success(JSON.stringify(args.includes("summary") ? {totalTestCount: 1, passedTests: 1, failedTests: 0, skippedTests: 0} :
                    {testNodes: [{nodeType: "Test Case", nodeIdentifier: "FixtureTests/testWorks()", result: "Passed"}]}));
            }
            return success();
        }});
    assert.deepEqual(results.map(result => result.status), ["passed", "passed"]);
    assert.equal(results[0].simulatorPreparation, undefined);
    assert.deepEqual(calls.slice(0, 3), [["xcodebuild", "build-for-testing"], ["xcrun", "simctl", "list", "devices", "--json"], ["xcrun", "simctl", "bootstatus", visionos, "-b"]]);
    assert.equal(calls[3][0], "xcodebuild");
    assert.equal(calls[3][1], "test-without-building");
}));

test("Debug-only unfiltered native tests receive Release performance proof on each simulator platform", () => {
    for (const stages of [[], ["test"]]) {
        const manifest = createManifest(job({payload: {configuration: "Debug", stages}}));
        for (const platform of ["ios", "visionos"]) {
            const gate = manifest.find(stage => stage.id === `performance.${platform}.release`);
            assert.ok(gate);
            assert.deepEqual(gate.nativeAudit, {configuration: "Release", platform, kind: "performance"});
            assert.equal(gate.args[gate.args.indexOf("-configuration") + 1], "Release");
            assert.ok(gate.args.includes("ENABLE_TESTABILITY=YES"));
            assert.ok(gate.args.includes("CODE_SIGNING_ALLOWED=YES"));
            assert.deepEqual(gate.env, PERFORMANCE_ENV);
            assert.equal(gate.proofKey, undefined);
            const selectors = gate.args.filter(arg => arg.startsWith("-only-testing:"));
            assert.equal(selectors.length, PERFORMANCE_TESTS.length);
            for (const name of PERFORMANCE_TESTS) { assert.ok(selectors.some(arg => arg.endsWith(`/${name}`))); }
        }
    }
});

test("normal full matrices and filtered or non-test Debug selections add no simulator performance stages", () => {
    for (const options of [{}, {profile: "extended"}, {payload: {configuration: "Debug", stages: ["build"]}},
        {payload: {configuration: "Debug", stages: ["performance"]}}, {payload: {configuration: "Debug", stages: ["test"], onlyTesting: ["Tests visionOS/FixtureTests"]}}]) {
        const manifest = createManifest(job(options));
        assert.ok(!manifest.some(stage => /^performance\.(ios|visionos)\.release$/.test(stage.id)));
    }
    const full = createManifest(job());
    for (const platform of ["macos", "ios", "visionos"]) {
        for (const configuration of ["debug", "release"]) { assert.equal(full.filter(stage => stage.id === `test.${platform}.${configuration}`).length, 1); }
    }
    for (const stage of full) {
        if (stage.nativeAudit) { assert.equal(stage.args[stage.args.indexOf("-collect-test-diagnostics") + 1], "never"); }
        if (stage.group === "build") { assert.ok(!stage.args.includes("-collect-test-diagnostics")); }
    }
});

test("whole-target selectors select only that platform and retain full target audit with selected overall scope", () => {
    const selectedJob = job({payload: {stages: ["test"], onlyTesting: ["Tests visionOS"]}});
    const manifest = createManifest(selectedJob);
    assert.deepEqual(manifest.filter(stage => stage.nativeAudit).map(stage => stage.id), ["test.visionos.debug", "test.visionos.release"]);
    for (const stage of manifest.filter(stage => stage.nativeAudit)) {
        assert.equal(stage.nativeAudit.filtered, false);
        assert.ok(stage.args.includes("-only-testing:Tests visionOS"));
    }
    assert.ok(manifest.some(stage => stage.id === "build-tests.visionos.debug"));
    assert.ok(manifest.some(stage => stage.id === "build-tests.visionos.release"));
    assert.ok(!manifest.some(stage => /^build-tests\.(ios|macos)\./.test(stage.id)));
    assert.equal(coverageReport(selectedJob, [], {checks: {}}).scope, "selected");
});

test("Debug whole-target selection adds Release proof only for its full selected platform", () => {
    const manifest = createManifest(job({payload: {configuration: "Debug", stages: ["test"], onlyTesting: ["Tests visionOS"]}}));
    assert.deepEqual(manifest.filter(stage => stage.nativeAudit).map(stage => stage.id), ["test.visionos.debug", "performance.visionos.release"]);
    assert.equal(manifest.find(stage => stage.id === "test.visionos.debug").nativeAudit.filtered, false);
    assert.equal(manifest.find(stage => stage.id === "performance.visionos.release").nativeAudit.platform, "visionos");
});

test("qualified Debug targets, performance classes, and gate methods retain Release proof only on their platform", () => {
    for (const platform of PLATFORMS) {
        const testClass = `${platform.target}/WalletCoreProxyPerformanceGateTests`;
        const selectors = [platform.target, testClass, ...PERFORMANCE_TESTS.flatMap(name => [`${testClass}/${name}`, `${testClass}/${name}()`])];
        for (const selector of selectors) {
            const manifest = createManifest(job({payload: {configuration: "Debug", stages: ["test"], onlyTesting: [selector]}}));
            const native = manifest.filter(stage => stage.nativeAudit);
            const gate = platform.id === "macos" ? "performance.release" : `performance.${platform.id}.release`;
            assert.deepEqual(native.map(stage => stage.id), [`test.${platform.id}.debug`, gate], selector);
            assert.ok(native[0].args.includes(`-only-testing:${selector}`));
            assert.equal(native[0].nativeAudit.filtered, selector !== platform.target);
            assert.equal(native[1].nativeAudit.configuration, "Release");
            assert.equal(native[1].nativeAudit.platform, platform.id);
        }
    }
});

test("unqualified Debug performance filters retain Release proof on all three platforms", () => {
    for (const selector of ["WalletCoreProxyPerformanceGateTests", ...PERFORMANCE_TESTS.map(name => `WalletCoreProxyPerformanceGateTests/${name}()`)]) {
        const manifest = createManifest(job({payload: {configuration: "Debug", stages: ["test"], onlyTesting: [selector]}}));
        const gates = manifest.filter(stage => stage.nativeAudit?.kind === "performance");
        assert.deepEqual(gates.map(stage => stage.nativeAudit.platform), ["macos", "ios", "visionos"], selector);
        assert.ok(gates.every(stage => stage.nativeAudit.configuration === "Release"));
    }
});

test("unrelated Debug methods and mixed platform filters do not add unnecessary Release proof", () => {
    for (const selector of ["FixtureTests", "WalletCoreProxyPerformanceGateTests/testScryptDefaultParametersAndSequentialDerivationVectors",
        "WalletCoreProxyPerformanceGateTests/testUnknownPerformanceGate", "OtherTests/testEd25519SigningPerformanceGate"]) {
        const manifest = createManifest(job({payload: {configuration: "Debug", stages: ["test"], onlyTesting: [selector]}}));
        assert.ok(!manifest.some(stage => stage.nativeAudit?.configuration === "Release"), selector);
    }
    const manifest = createManifest(job({payload: {configuration: "Debug", stages: ["test"], onlyTesting: [
        "Tests iOS/FixtureTests", "Tests macOS/WalletCoreProxyPerformanceGateTests",
        "Tests visionOS/WalletCoreProxyPerformanceGateTests/testUnknownPerformanceGate",
    ]}}));
    assert.deepEqual(manifest.filter(stage => stage.nativeAudit?.configuration === "Release").map(stage => stage.id), ["performance.release"]);
});

test("Debug and Release filtered matrices use their selected Release tests without extra performance stages", () => {
    for (const platform of PLATFORMS) {
        for (const suffix of ["", ...PERFORMANCE_TESTS.map(name => `/${name}`)]) {
            const manifest = createManifest(job({payload: {stages: ["test"], onlyTesting: [`${platform.target}/WalletCoreProxyPerformanceGateTests${suffix}`]}}));
            assert.deepEqual(manifest.filter(stage => stage.nativeAudit).map(stage => stage.id), [
                `test.${platform.id}.debug`, `test.${platform.id}.release`,
            ]);
        }
    }
});

test("only exact known whole-target names bypass the class-selector grammar", () => {
    for (const selector of ["Tests macOS", "Tests iOS", "Tests visionOS"]) { assert.doesNotThrow(() => validateJob(job({payload: {onlyTesting: [selector]}}))); }
    for (const selector of ["Tests watchOS", "Tests visionOS ", " Tests visionOS", "Tests visionOS;rm", "Tests visionOS/Foo bar", "Tests visionOS/../escape"]) {
        assert.throws(() => validateJob(job({payload: {onlyTesting: [selector]}})), /Invalid XCTest selection/);
    }
});
