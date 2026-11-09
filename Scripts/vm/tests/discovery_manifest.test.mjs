import assert from "node:assert/strict";
import {spawnSync} from "node:child_process";
import {appendFile, mkdtemp, rm, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {fileURLToPath} from "node:url";
import test from "node:test";
import {auditApprovalResult, auditNativeResult, auditResults} from "../result_audit.mjs";
import {BOOTSTRAP_TOOL_NAMES, createManifest, PLATFORMS, stagePlan, validateJob} from "../test_manifest.mjs";
import {executionStage} from "../test_discovery.mjs";
import {auditFixtureSelection, fixtureEvidence, resolvedFixtureManifest} from "./discovery_support.mjs";

const job = payload => ({version: 1, runId: "runtime-tests", vmId: "fixture-vm", kind: "run", profile: "all",
    payload: {stages: [], onlyTesting: [], ...payload}, bootstrapTools: Object.fromEntries(BOOTSTRAP_TOOL_NAMES.map(name => [name, "a".repeat(64)])),
    source: {sha256: "b".repeat(64), commit: "c".repeat(40)}});

test("host planning requires unfiltered build and discovery before any exact XCTest stage", () => {
    const selected = job({stages: ["test"], onlyTesting: ["WalletNetworkingTests/SafariRPCServiceTests"], configuration: "Release"});
    const manifest = createManifest(selected);
    for (const platform of PLATFORMS) {
        const build = manifest.find(stage => stage.id === `build-runtime-tests.${platform.id}.release`);
        const discovery = manifest.find(stage => stage.id === `discover.test-runtime.${platform.id}.release`);
        assert.ok(build.args.includes("ENABLE_TESTABILITY=YES"));
        assert.ok(!build.args.some(arg => arg.startsWith("-only-testing:")));
        assert.ok(discovery.nativeDiscovery);
        assert.ok(!manifest.some(stage => stage.id === `test-runtime.${platform.id}.release`));
        const execution = resolvedFixtureManifest(selected).find(stage => stage.id === `test-runtime.${platform.id}.release`);
        assert.ok(execution.nativeAudit.requiredTests.length);
        assert.ok(execution.nativeAudit.requiredTests.every(name => name.startsWith("WalletNetworkingTests/SafariRPCServiceTests/")));
    }
    const compilation = createManifest(job({stages: ["runtime"], onlyTesting: ["WalletNetworkingTests"], configuration: "Debug"}));
    assert.deepEqual(compilation.map(stage => stage.id), ["runtime.WalletNetworkingTests.debug"]);
    assert.ok(!compilation.some(stage => stage.nativeDiscovery || stage.nativeAudit));
});

test("every native discovery requires a fresh build through the correct container clean", () => {
    const manifest = createManifest(job());
    for (const discovery of manifest.filter(stage => stage.nativeDiscovery)) {
        const build = manifest.find(stage => stage.id === discovery.dependencies[0]);
        const clean = manifest.find(stage => stage.id === build.dependencies[0]);
        assert.equal(clean.command, "xcodebuild");
        assert.equal(clean.args[0], "clean");
        assert.equal(clean.cwd, build.cwd);
        assert.equal(clean.args[clean.args.indexOf("-configuration") + 1], discovery.nativeDiscovery.configuration);
        assert.equal(clean.args[clean.args.indexOf("-destination") + 1], `$destination:${discovery.nativeDiscovery.platform}`);
        assert.ok(manifest.indexOf(clean) < manifest.indexOf(build));
        const platform = PLATFORMS.find(value => value.id === discovery.nativeDiscovery.platform);
        assert.equal(clean.args[clean.args.indexOf("-scheme") + 1], discovery.nativeDiscovery.runtime ? "WalletRuntime-Package" : platform.scheme);
        assert.ok(!clean.args.includes("-derivedDataPath"));
    }
});

test("orchestration fixtures can select mutation witnesses added after the captured enumeration", () => {
    const witness = "WalletAuthorityTests/NewMutationTests/testNewWitness";
    const stage = createManifest(job({stages: ["test"], onlyTesting: [witness], configuration: "Debug", runtimePlatforms: ["macos"]}))
        .find(value => value.id === "discover.test-runtime.macos.debug");
    const before = fixtureEvidence(stage);
    stage.nativeDiscovery.mutationWitnesses.push(witness);
    assert.throws(() => executionStage(stage, before.identifiers, before), /Missing runtime mutation witness/);
    const current = fixtureEvidence(stage);
    assert.deepEqual(executionStage(stage, current.identifiers, current).nativeAudit.requiredTests, [witness]);
});

test("each selector must match discovery within the requested scope even beside valid selectors", async () => {
    for (const selector of ["WalletNetworkingTests/MissingTests", "WalletNetworkingTests/SafariRPCServiceTests/testMissing()", "Tests iOS/OnboardingCancellationTests"]) {
        const selected = job({stages: ["test"], configuration: "Debug", onlyTesting: ["WalletNetworkingTests/SafariRPCServiceTests", selector]});
        assert.doesNotThrow(() => createManifest(selected));
        const audit = await auditFixtureSelection(selected);
        assert.equal(audit.ok, false);
        assert.ok(audit.unmatchedSelectors.includes(selector));
    }
});

test("stages which cannot resolve a method reject the selector before running", () => {
    const selector = "WalletAuthorityTests/NoSuchClass/testMissing";
    for (const stages of [["build"], ["performance"], ["build", "performance"], ["runtime"]]) {
        assert.throws(() => createManifest(job({stages, onlyTesting: [selector]})), /selector did not match a selected stage/);
    }
    for (const target of ["WalletNetworking", "WalletNetworkingTests", "ApprovalCrashWorker"]) {
        const stages = createManifest(job({stages: ["runtime"], onlyTesting: [target], configuration: "Debug"}));
        assert.ok(stages.some(stage => stage.id === `runtime.${target}.debug`));
        assert.ok(stages.every(stage => !stage.nativeDiscovery));
    }
    assert.ok(createManifest(job({stages: ["build"], onlyTesting: ["Tests macOS"]})).some(stage => stage.id === "build-tests.macos.debug"));
    assert.doesNotThrow(() => createManifest(job({stages: ["test", "performance"], onlyTesting: [selector]})));
});

test("mixed runtime and XCTest selectors bind to the requested builds and tests", async () => {
    const builds = ["WalletAuthority", "ApprovalCrashWorker"];
    const app = "Tests macOS/WalletAccessControllerTests";
    const selected = job({stages: ["runtime", "test"], onlyTesting: [...builds, app]});
    const manifest = createManifest(selected);
    const discoveries = manifest.filter(stage => stage.nativeDiscovery);
    assert.deepEqual(discoveries.map(stage => stage.id), ["discover.test.macos.debug", "discover.test.macos.release"]);
    assert.ok(discoveries.every(stage => stage.nativeDiscovery.selectors.length === 1 && stage.nativeDiscovery.selectors[0] === app));
    const audit = await auditFixtureSelection(selected);
    assert.equal(audit.ok, true);
    assert.deepEqual(audit.matchedSelectors, [...builds, app].sort());

    const partial = await auditFixtureSelection(selected, {changeRecords: records => {
        records.find(record => record.id === "runtime.WalletAuthority.release").status = "failed";
    }});
    assert.deepEqual(partial.unmatchedSelectors, ["WalletAuthority"]);
    const typo = await auditFixtureSelection(job({stages: ["runtime", "test"], onlyTesting: [...builds, app, "MissingSuite"]}));
    assert.deepEqual(typo.unmatchedSelectors, ["MissingSuite"]);
    assert.throws(() => createManifest(job({stages: ["test"], onlyTesting: builds})), /requires --stage runtime/);
});

test("compile-only selections never expand to an unfiltered native test run", async () => {
    const selected = job({stages: ["runtime", "test"], configuration: "Debug", onlyTesting: ["ApprovalCrashWorker"]});
    assert.ok(createManifest(selected).every(stage => !stage.nativeDiscovery));
    assert.equal((await auditFixtureSelection(selected)).ok, true);
    const both = job({stages: ["runtime", "test"], configuration: "Debug", runtimePlatforms: ["macos"],
        onlyTesting: ["WalletFlows", "WalletNetworkingTests"]});
    const manifest = resolvedFixtureManifest(both);
    assert.ok(manifest.some(stage => stage.id === "runtime.WalletNetworkingTests.debug"));
    assert.deepEqual(manifest.filter(stage => stage.nativeAudit).map(stage => stage.id), ["test-runtime.macos.debug"]);
    assert.ok(manifest.find(stage => stage.nativeAudit).nativeAudit.requiredTests.every(id => id.startsWith("WalletNetworkingTests/")));
    assert.equal((await auditFixtureSelection(both)).ok, true);
});

async function verifyReport(directory, submitted, report) {
    await writeFile(join(directory, "result.json"), JSON.stringify(report));
    return spawnSync(process.execPath, [
        fileURLToPath(new URL("../verify_discovery.mjs", import.meta.url)),
        fileURLToPath(new URL("../test_manifest.mjs", import.meta.url)), directory,
    ], {input: JSON.stringify(submitted), encoding: "utf8"});
}

test("the host accepts a 16 MiB resolved plan and rejects one extra byte", async t => {
    const submitted = job({stages: ["runtime"], onlyTesting: ["WalletDomain"], configuration: "Debug"});
    const plan = stagePlan(createManifest(submitted));
    const directory = await mkdtemp(join(tmpdir(), "wallet-resolved-plan-"));
    t.after(() => rm(directory, {recursive: true, force: true}));
    const report = {...submitted, finishedAt: "2026-11-09T00:00:00Z", status: "passed",
        stages: plan.map(stage => ({...stage, status: "passed"}))};
    const path = join(directory, "resolved-plan.json");
    await writeFile(path, JSON.stringify(plan).padEnd(16 * 1024 ** 2));
    const accepted = await verifyReport(directory, submitted, report);
    assert.equal(accepted.status, 0, accepted.stderr);
    await appendFile(path, " ");
    const rejected = await verifyReport(directory, submitted, report);
    assert.notEqual(rejected.status, 0);
    assert.match(rejected.stderr, /bounded regular file/);
});

test("the host rejects a passing report with blocked discoveries, even if its resolved plan omits all executions", async t => {
    const submitted = job({stages: ["test"], configuration: "Debug"});
    const plan = stagePlan(createManifest(submitted));
    const directory = await mkdtemp(join(tmpdir(), "wallet-host-discovery-"));
    t.after(() => rm(directory, {recursive: true, force: true}));
    const report = {...submitted, finishedAt: "2026-11-09T00:00:00Z", status: "passed",
        stages: plan.map(stage => ({...stage, status: stage.nativeDiscovery ? "blocked" : "passed"}))};
    assert.ok(report.stages.some(stage => stage.status === "blocked"));
    await writeFile(join(directory, "resolved-plan.json"), JSON.stringify(plan));
    const blocked = await verifyReport(directory, submitted, report);
    assert.notEqual(blocked.status, 0);
    assert.match(blocked.stderr, /requires every stage to have passed/);
    const other = await verifyReport(directory, submitted, {...report, runId: "another-run"});
    assert.notEqual(other.status, 0);
    assert.match(other.stderr, /does not belong to the requested job/);
});

test("unresolved discovery cannot disappear from a successful result", async () => {
    const selected = job({stages: ["test"], configuration: "Debug", runtimePlatforms: ["macos"], onlyTesting: ["WalletNetworkingTests"]});
    assert.equal((await auditFixtureSelection(selected)).ok, true);
    const missing = await auditFixtureSelection(selected, {changeRecords: records => {
        records.splice(records.findIndex(stage => stage.nativeDiscovery), 1);
    }});
    assert.equal(missing.ok, false);
    const noAudit = await auditFixtureSelection(selected, {changeRecords: records => {
        records.find(stage => stage.discoveryStage).productsVerified = false;
    }});
    assert.equal(noAudit.ok, false);
});

test("ordinary test matches cannot conceal an explicitly requested empty sanitizer selection", () => {
    for (const sanitizer of ["asan", "tsan"]) {
        const selected = job({stages: ["test", sanitizer], configuration: "Debug", onlyTesting: ["Tests macOS/WalletAccessControllerTests"]});
        assert.throws(() => createManifest(selected), new RegExp(`Explicit ${sanitizer} selection did not match any focused tests`));
    }
});

test("sanitizer planning builds only the tiers and families whose focus intersects the selection", async () => {
    const selected = {...job({stages: ["tsan", "asan"], onlyTesting: ["WalletSigningSessionTests", "Tests macOS/PopupRequestSessionsTests"]}),
        profile: "extended"};
    const phases = createManifest(selected).filter(stage => ["asan", "tsan"].includes(stage.group)).map(stage => stage.id);
    assert.deepEqual(phases, ["tsan.focused.runtime", "tsan.extended", "asan.focused.runtime"]
        .flatMap(id => [`clean-${id}`, `build-${id}`, `discover.${id}`]));
    assert.equal((await auditFixtureSelection(selected)).ok, true);
    selected.payload.onlyTesting.push("UnrelatedMissingTests");
    assert.deepEqual((await auditFixtureSelection(selected)).unmatchedSelectors, ["UnrelatedMissingTests"]);
});

test("runtime audit rejects omitted, duplicate, extra, skipped, and zero tests", () => {
    const requiredTests = ["WalletDomainTests/DomainTests/testOne", "WalletDomainTests/DomainTests/testTwo"];
    const policy = {runtime: true, kind: "full", configuration: "Release", platform: "macos", requiredTests};
    const tree = names => ({testNodes: [{nodeType: "Unit test bundle", name: "WalletDomainTests", children: names.map(name => ({nodeType: "Test Case", nodeIdentifier: name, result: "Passed"}))}]});
    const summary = total => ({totalTestCount: total, passedTests: total, failedTests: 0, skippedTests: 0});
    const names = requiredTests.map(name => name.split("/").slice(1).join("/") + "()");
    assert.equal(auditNativeResult(summary(2), tree(names), policy).ok, true);
    for (const actual of [[], names.slice(0, 1), [names[0], names[0]], [...names, "DomainTests/testOther()"]]) {
        assert.equal(auditNativeResult(summary(actual.length), tree(actual), policy).ok, false);
    }
    const skipped = tree(names); skipped.testNodes[0].children[0].result = "Skipped";
    assert.equal(auditNativeResult({...summary(2), passedTests: 1, skippedTests: 1}, skipped, policy).ok, false);
    assert.equal(auditResults([{id: "runtime", status: "passed", nativeAudit: policy}]).status, "failed");
    const sameName = {testNodes: [{nodeType: "Unit test bundle", name: "WalletDomainTests", children: [
        {nodeType: "Test Case", nodeIdentifier: "WalletDomainTests/testOne()", result: "Passed"},
    ]}]};
    const sameNamePolicy = {...policy, requiredTests: ["WalletDomainTests/WalletDomainTests/testOne"]};
    assert.equal(auditNativeResult(summary(1), sameName, sameNamePolicy).ok, true);
    const wrongTarget = structuredClone(sameName); wrongTarget.testNodes[0].name = "WalletNetworkingTests";
    assert.equal(auditNativeResult(summary(1), wrongTarget, sameNamePolicy).ok, false);
});

test("systematic approval profile limits are explicit and incomplete evidence cannot pass", () => {
    assert.doesNotThrow(() => validateJob(job({approvalArgs: ["--systematic", "extended", "--systematic-only", "--trace-limit", "4096"]})));
    for (const args of [["--systematic", "all", "--trace-limit", "257"], ["--systematic", "off", "--trace-limit", "1"], ["--random-only", "--systematic-only"]]) {
        assert.throws(() => validateJob(job({approvalArgs: args})));
    }
    const baseline = createManifest(job({stages: ["approval"], configuration: "Debug"})).find(stage => stage.id === "approval.debug");
    assert.deepEqual(baseline.approvalAudit, {profile: "all", traceLimit: 256, modes: ["native", "popup"]});
    const extended = createManifest({...job({stages: ["approval"], configuration: "Release"}), profile: "extended"});
    assert.equal(extended.find(stage => stage.id === "approval.systematic-release").approvalAudit.traceLimit, 4096);
    const templates = ["authentication-cancellation", "signing-cancellation", "signing-revocation", "publication-cancellation",
        "checkpoint-cancellation", "dispatch-cancellation", "completion-cancellation", "delivery-cancellation"];
    const scenarios = ["native", "popup"].flatMap(mode => ["ethereum", "solana"].flatMap(provider => templates.map(template => ({
        scenario: `${mode}/systematic/${provider}/${template}`, profile: "all", completed: 1, pruned: 0, finished: 1, frontier: 0,
        requests: 2, faultsApplied: 1,
        bounds: {preemptions: 1, transitions: 64, traces: 256, faults: 1, actors: 2},
    }))));
    const sourceIdentity = {version: 1, source: {kind: "vm-snapshot", sha256: "a".repeat(64), commit: "b".repeat(40), fileCount: 7},
        worker: {sha256: "c".repeat(64), bytes: 123}};
    const evidence = {version: 1, sourceIdentity, status: "complete", profile: "all", traces: scenarios.length, frontier: 0, scenarios};
    assert.equal(auditApprovalResult(evidence, baseline.approvalAudit).ok, true);
    for (const changed of [{status: "incomplete"}, {frontier: 1}, {traces: 0}, {sourceIdentity: undefined},
        {sourceIdentity: {...sourceIdentity, worker: {...sourceIdentity.worker, sha256: "unverified"}}},
        {scenarios: scenarios.slice(1)}, {scenarios: [...scenarios, scenarios[0]]},
        {scenarios: scenarios.map(value => ({...value, requests: 1}))}, {scenarios: scenarios.map(value => ({...value, faultsApplied: 0}))}]) {
        assert.equal(auditApprovalResult({...evidence, ...changed}, baseline.approvalAudit).ok, false);
    }
});
