import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import test from "node:test";
import {auditNativeResult, auditResults, performanceTestName, testCases} from "../result_audit.mjs";
import {createManifest, PERFORMANCE_TESTS, PLATFORMS, RUNNER_TOOL_NAMES} from "../test_manifest.mjs";

const captured = JSON.parse(await readFile(new URL("./fixtures/xcresult_xcode27_performance_debug.json", import.meta.url), "utf8"));
const debugPolicy = {configuration: "Debug", kind: "full", platform: "ios"};

function passedGates() {
    const tree = structuredClone(captured.tree);
    const suite = tree.testNodes[0].children[0].children[0];
    suite.children = suite.children.filter(node => performanceTestName(node.nodeIdentifier)).map(({children, ...node}) => ({...node, result: "Passed"}));
    return {tree, summary: {totalTestCount: 5, passedTests: 5, failedTests: 0, skippedTests: 0}};
}

test("captured XCTest27 cases retain skip-message children without counting them as tests", () => {
    const cases = testCases(captured.tree);
    assert.equal(cases.length, 7);
    assert.equal(cases.filter(value => value.result === "passed").length, 2);
    const skipped = cases.filter(value => value.result === "skipped");
    assert.equal(skipped.length, 5);
    for (const value of skipped) {
        assert.match(value.details, /WALLETCORE_PROXY_PERF_ALLOW_DEBUG=1/);
        assert.match(value.identifier, /^WalletCoreProxyPerformanceGateTests\/test[^/]+\(\)$/);
    }
    const audit = auditNativeResult(captured.summary, captured.tree, debugPolicy);
    assert.equal(audit.ok, true);
    assert.deepEqual(audit.issues, []);
    assert.deepEqual(new Set(audit.expectedSkips), new Set(PERFORMANCE_TESTS));
    assert.deepEqual(audit.performancePassed, []);
});

test("current-schema passed cases expose all five Release gates for full and focused runs", () => {
    const {summary, tree} = passedGates();
    for (const kind of ["full", "performance"]) {
        const audit = auditNativeResult(summary, tree, {configuration: "Release", kind, platform: "ios"});
        assert.equal(audit.ok, true);
        assert.deepEqual(new Set(audit.performancePassed), new Set(PERFORMANCE_TESTS));
        assert.deepEqual(audit.expectedSkips, []);
    }
});

test("Debug skip proof requires passing Release gates on the corresponding platform", () => {
    const debug = {id: "test.ios.debug", status: "passed", nativeAudit: debugPolicy,
        audit: auditNativeResult(captured.summary, captured.tree, debugPolicy)};
    const {summary, tree} = passedGates();
    const releasePolicy = {configuration: "Release", kind: "full", platform: "ios"};
    const release = {id: "test.ios.release", status: "passed", nativeAudit: releasePolicy,
        audit: auditNativeResult(summary, tree, releasePolicy)};
    assert.equal(auditResults([debug]).status, "failed");
    assert.equal(auditResults([debug, {...release, nativeAudit: {...releasePolicy, platform: "macos"}}]).status, "failed");
    assert.equal(auditResults([debug, release]).status, "passed");
    assert.equal(auditResults([{...debug, nativeAudit: {...debugPolicy, platform: "visionos"}}, release]).status, "failed");
    const withBlockedMac = auditResults([debug, release, {id: "performance.release", status: "blocked", nativeAudit: {configuration: "Release", platform: "macos"}}]);
    assert.equal(withBlockedMac.status, "failed");
    assert.equal(withBlockedMac.counts.blocked, 1);
    assert.deepEqual(withBlockedMac.issues, []);
});

test("filtered Debug manifests pass captured skip audits only when their scheduled Release proof passes", () => {
    const release = passedGates();
    for (const target of [undefined, ...PLATFORMS.map(platform => platform.target)]) {
        for (const method of [undefined, ...PERFORMANCE_TESTS]) {
            const selector = `${target ? `${target}/` : ""}WalletCoreProxyPerformanceGateTests${method ? `/${method}()` : ""}`;
            const manifest = createManifest({version: 1, runId: "filtered-gates", vmId: "fixture-vm", kind: "run", profile: "all",
                stages: ["test"], configuration: "Debug", onlyTesting: [selector],
                runnerTools: Object.fromEntries(RUNNER_TOOL_NAMES.map(name => [name, "a".repeat(64)])),
                source: {sha256: "b".repeat(64), commit: "c".repeat(40)},
            });
            const debug = structuredClone(captured);
            if (method) {
                const suite = debug.tree.testNodes[0].children[0].children[0];
                suite.children = suite.children.filter(node => performanceTestName(node.nodeIdentifier) === method);
                debug.summary = {totalTestCount: 1, passedTests: 0, failedTests: 0, skippedTests: 1};
            }
            const results = manifest.map(stage => {
                if (!stage.nativeAudit) { return {id: stage.id, status: "passed"}; }
                const fixture = stage.nativeAudit.configuration === "Debug" ? debug : release;
                return {id: stage.id, status: "passed", nativeAudit: stage.nativeAudit,
                    audit: auditNativeResult(fixture.summary, fixture.tree, stage.nativeAudit)};
            });
            assert.ok(results.every(stage => !stage.audit || stage.audit.ok), selector);
            assert.equal(auditResults(results).status, "passed", selector);
            assert.equal(auditResults(results.filter(stage => stage.nativeAudit?.configuration !== "Release")).status, "failed", selector);
            const failedRelease = results.map(stage => stage.nativeAudit?.configuration === "Release" ? {...stage, status: "failed"} : stage);
            assert.equal(auditResults(failedRelease).status, "failed", selector);
        }
    }
});

test("missing cases or unexpected skipped cases remain audit failures", () => {
    const tree = structuredClone(captured.tree);
    tree.testNodes[0].children[0].children[0].children.shift();
    const missing = auditNativeResult(captured.summary, tree, debugPolicy);
    assert.equal(missing.ok, false);
    assert.ok(missing.issues.includes("Skipped-test inventory does not match XCTest summary"));
    assert.ok(missing.issues.includes("Test-case inventory does not match XCTest summary"));
    assert.equal(auditNativeResult({totalTestCount: 1, passedTests: 1, failedTests: 0, skippedTests: 0}, {testNodes: []}, debugPolicy).ok, false);
    assert.equal(auditNativeResult(captured.summary, captured.tree, {...debugPolicy, configuration: "Release"}).ok, false);
});
