import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import test from "node:test";
import {BOOTSTRAP_TOOL_NAMES, createManifest as staticManifest} from "../test_manifest.mjs";
import {executionStage, parseTestEnumeration} from "../test_discovery.mjs";
import {auditNativeResult, auditResults} from "../result_audit.mjs";

import {auditFixtureSelection, resolvedFixtureManifest as createManifest} from "./discovery_support.mjs";

const job = payload => ({version: 1, runId: "app-inventory", vmId: "fixture-vm", kind: "run", profile: "all",
    payload: {stages: ["test"], configuration: "Debug", onlyTesting: [], ...payload},
    bootstrapTools: Object.fromEntries(BOOTSTRAP_TOOL_NAMES.map(name => [name, "a".repeat(64)])),
    source: {sha256: "b".repeat(64), commit: "c".repeat(40)}});
const tree = (identifiers, target = "Tests macOS") => ({testNodes: [{nodeType: "Unit test bundle", name: target,
    children: identifiers.map(nodeIdentifier => ({nodeType: "Test Case", nodeIdentifier, result: "Passed"}))}]});
const summary = count => ({totalTestCount: count, passedTests: count, failedTests: 0, skippedTests: 0});

test("focused known app classes require their complete current method inventory", () => {
    const selected = ["Tests macOS/WalletAccessControllerTests", "Tests macOS/OnboardingCancellationTests"];
    const stages = createManifest(job({onlyTesting: selected}));
    const stage = stages.find(stage => stage.id === "test.macos.debug");
    const expected = stage.nativeAudit.requiredTests;
    assert.ok(expected.length > 2);
    assert.ok(stage.dependencies.includes("discover.test.macos.debug"));
    assert.ok(expected.every(name => selected.some(prefix => name.startsWith(prefix + "/"))));
    assert.equal(auditNativeResult(summary(expected.length), tree(expected), stage.nativeAudit).ok, true);
    const one = expected.filter(name => name.endsWith("/testOldAuthenticationCannotReplaceNewAuthenticationOrUnlockAfterLock"));
    assert.equal(one.length, 1);
    assert.equal(auditNativeResult(summary(1), tree(one), stage.nativeAudit).ok, false);
    assert.equal(auditNativeResult(summary(expected.length + 1), tree([...expected, expected[0]]), stage.nativeAudit).ok, false);
    assert.equal(auditNativeResult(summary(expected.length + 1), tree([...expected, "UnexpectedTests/testUnexpected"]), stage.nativeAudit).ok, false);
    assert.equal(auditNativeResult(summary(expected.length), tree(expected, "Tests iOS"), stage.nativeAudit).ok, false);
});

test("full app runs require exactly all tests discovered including unregistered classes", () => {
    const stage = createManifest(job({onlyTesting: ["Tests macOS"]})).find(stage => stage.id === "test.macos.debug");
    const policy = stage.nativeAudit;
    const names = policy.requiredTests;
    assert.ok(names.some(name => name.includes("/UnregisteredTests/")));
    assert.equal(auditNativeResult(summary(names.length), tree(names), policy).ok, true);
    assert.equal(auditNativeResult(summary(names.length - 1), tree(names.slice(1)), policy).ok, false);
    assert.equal(auditNativeResult(summary(names.length + 1), tree([...names, names.at(-1)]), policy).ok, false);
    assert.equal(auditNativeResult(summary(names.length + 1), tree([...names, "UnexpectedTests/testUnexpected"]), policy).ok, false);
});

test("unqualified app selectors match actual methods even outside a critical suite's required platforms", () => {
    const method = "SecretHandlingTests/testUIKitAdapterWritesLocalOnlySystemExpirationWithoutAdoptingReplacement";
    const stages = staticManifest(job({onlyTesting: [method]}));
    const app = stages.filter(stage => stage.nativeDiscovery && !stage.nativeDiscovery.runtime);
    assert.deepEqual(app.map(stage => stage.nativeDiscovery.platform), ["macos", "ios", "visionos"]);
    for (const [platform, file] of [["macos", "xcode27_2_app_enumeration.json"], ["ios", "xcode27_2_ios_app_enumeration.json"]]) {
        const stage = app.find(stage => stage.nativeDiscovery.platform === platform);
        const output = JSON.parse(readFileSync(new URL(`./fixtures/${file}`, import.meta.url)));
        const ids = parseTestEnumeration(output, {...stage.nativeDiscovery, testPlan: output.values[0].testPlan});
        const execution = executionStage(stage, ids, {plan: {path: "/fixture/expected.xctestrun"}});
        if (platform === "macos") { assert.equal(execution, null); }
        else { assert.deepEqual(execution.nativeAudit.requiredTests, [`Tests iOS/${method}`]); }
    }
});

test("mixed and unregistered selections use discovery and reject omitted or unrelated executions", () => {
    for (const onlyTesting of [
        ["Tests macOS/WalletAccessControllerTests", "Tests macOS/UnregisteredTests"],
        ["Tests macOS/UnregisteredTests/testSpecific"],
    ]) {
        const policy = createManifest(job({onlyTesting})).find(stage => stage.id === "test.macos.debug").nativeAudit;
        const complete = policy.requiredTests;
        assert.equal(auditNativeResult(summary(complete.length), tree(complete), policy).ok, true);
        assert.equal(auditNativeResult(summary(complete.length - 1), tree(complete.slice(1)), policy).ok, false);
        const extra = [...complete, "Tests macOS/UnrequestedTests/testExtra"];
        assert.equal(auditNativeResult(summary(extra.length), tree(extra), policy).ok, false);
        assert.equal(auditNativeResult(summary(complete.length + 1), tree([...complete, complete.at(-1)]), policy).ok, false);
        assert.equal(auditNativeResult(summary(complete.length), tree(complete, "Tests iOS"), policy).ok, false);
    }
});

test("nonexistent app methods cannot disappear beside valid selectors after discovery", async () => {
    for (const onlyTesting of [
        ["WalletAccessControllerTests/testMissing"],
        ["Tests macOS/WalletAccessControllerTests", "Tests macOS/OnboardingCancellationTests/testMissing"],
        ["Tests iOS/OnboardingCancellationTests"],
    ]) {
        const selected = job({onlyTesting});
        assert.doesNotThrow(() => staticManifest(selected));
        assert.equal((await auditFixtureSelection(selected)).ok, false);
    }
});

test("app audit rejects empty, malformed, duplicate, and wrong-platform policies", () => {
    const name = "Tests macOS/WalletAccessControllerTests/testFixture";
    const policy = {configuration: "Debug", platform: "macos", kind: "full"};
    for (const requiredTests of [undefined, [], [name, name], ["Tests iOS/WalletAccessControllerTests/testFixture"], ["Tests macOS/WalletAccessControllerTests"], [null]]) {
        assert.equal(auditNativeResult(summary(1), tree([name]), {...policy, requiredTests}).ok, false);
    }
});

test("aggregate results require the registered app inventory audit", () => {
    const stage = createManifest(job({onlyTesting: ["Tests macOS/WalletAccessControllerTests"]}))
        .find(stage => stage.id === "test.macos.debug");
    const expected = stage.nativeAudit.requiredTests;
    const audit = auditNativeResult(summary(expected.length), tree(expected), stage.nativeAudit);
    assert.equal(auditResults([{id: stage.id, status: "passed", nativeAudit: stage.nativeAudit, audit}]).status, "passed");
    for (const missing of [undefined, {ok: false}]) {
        const result = auditResults([{id: stage.id, status: "passed", nativeAudit: stage.nativeAudit, audit: missing}]);
        assert.equal(result.status, "failed");
        assert.ok(result.issues.includes("test.macos.debug has no passing app XCTest inventory audit"));
    }
});
