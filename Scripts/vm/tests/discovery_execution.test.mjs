import assert from "node:assert/strict";
import {mkdtemp, realpath, rm} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import test from "node:test";
import {atomicJSON, hashFile} from "../guest_bootstrap.mjs";
import {executeStages} from "../guest.mjs";
import {auditResults} from "../result_audit.mjs";
import {fixtureEvidence} from "./discovery_support.mjs";

const selected = "WalletAuthorityTests/RuntimeFixtureTests/testOrdinary";
const nativePolicy = {runtime: true, platform: "macos", configuration: "Debug", kind: "full", selectors: [selected], targets: ["WalletAuthorityTests"]};
const build = id => ({id: `build-${id}`, group: "build", command: "build-fixture", args: [], cwd: ".", dependencies: [], requirements: [], timeoutSeconds: 1});
const discovery = id => ({id: `discover.${id}`, group: "test", command: "xcodebuild", args: [], cwd: ".", dependencies: [`build-${id}`], requirements: [], timeoutSeconds: 1,
    nativeDiscovery: {...nativePolicy, executionID: id}});
const success = value => ({code: 0, signal: null, output: value ? JSON.stringify(value) : "", cancelled: false, timedOut: false});

async function temporary(run) {
    const root = await realpath(await mkdtemp(join(tmpdir(), "wallet-discovery-execution-")));
    try { await run(root); } finally { await rm(root, {recursive: true, force: true}); }
}

test("each variant executes its bound discovery before the next build can replace products", async () => temporary(async root => {
    const events = [];
    const manifest = [build("first"), discovery("first"), build("second"), discovery("second")];
    const results = await executeStages(manifest, {workspace: root, artifacts: root, writeJSON: atomicJSON, hashFile,
        preflight: {checks: {}, destinations: {macos: "platform=macOS,arch=arm64"}},
        discover: async ({stage, buildCommand, buildLog}) => {
            assert.deepEqual(buildCommand, ["build-fixture"]);
            assert.equal(buildLog, `${stage.dependencies[0]}.log`);
            events.push(stage.id);
            return fixtureEvidence(stage);
        },
        verifyProducts: async evidence => { events.push(`verify:${evidence.plan.path.split("/").at(-1)}`); },
        inspectResultBundle: async () => "a".repeat(64),
        execute: async (command, args, options) => {
            if (command === "xcrun") {
                return success(args.includes("summary") ? {totalTestCount: 1, passedTests: 1, failedTests: 0, skippedTests: 0} : {
                    testNodes: [{nodeType: "Unit test bundle", name: "WalletAuthorityTests", children: [
                        {nodeType: "Test Case", nodeIdentifier: selected, result: "Passed"},
                    ]}],
                });
            }
            events.push(options.logPath.split("/").at(-1));
            return success();
        }});
    assert.deepEqual(results.map(stage => stage.id), ["build-first", "discover.first", "first", "build-second", "discover.second", "second"]);
    assert.ok(results.every(stage => stage.status === "passed"));
    assert.deepEqual(events.filter(event => !event.startsWith("verify:")), ["build-first.log", "discover.first", "first.log", "build-second.log", "discover.second", "second.log"]);
    assert.equal(events.filter(event => event.startsWith("verify:")).length, 4);
    assert.equal(auditResults(results).status, "passed");
}));

test("cancellation retains discovered execution and all later discovery obligations", async () => temporary(async root => {
    let stopped = false;
    const manifest = [build("first"), discovery("first"), build("second"), discovery("second")];
    const results = await executeStages(manifest, {workspace: root, artifacts: root, writeJSON: atomicJSON, hashFile,
        preflight: {checks: {}, destinations: {macos: "platform=macOS,arch=arm64"}}, stopRequested: async () => stopped,
        discover: async ({stage}) => { stopped = true; return fixtureEvidence(stage); },
        execute: async () => success()});
    assert.deepEqual(results.map(stage => [stage.id, stage.status]), [
        ["build-first", "passed"], ["discover.first", "passed"], ["first", "cancelled"], ["build-second", "cancelled"], ["discover.second", "cancelled"],
    ]);
    assert.equal(auditResults(results, {ok: false, issues: ["Unresolved selector"]}).status, "cancelled");
}));
