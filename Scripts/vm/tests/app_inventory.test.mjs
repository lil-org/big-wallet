import assert from "node:assert/strict";
import test from "node:test";
import {appTestPolicy, BOOTSTRAP_TOOL_NAMES, createManifest, PLATFORMS, testingForPlatform} from "../test_manifest.mjs";
import {auditNativeResult, auditResults} from "../result_audit.mjs";

const job = payload => ({version: 1, runId: "app-inventory", vmId: "fixture-vm", kind: "run", profile: "all",
    payload: {stages: ["test"], configuration: "Debug", onlyTesting: [], ...payload},
    bootstrapTools: Object.fromEntries(BOOTSTRAP_TOOL_NAMES.map(name => [name, "a".repeat(64)])),
    source: {sha256: "b".repeat(64), commit: "c".repeat(40)}});
const tree = (identifiers, target = "Tests macOS") => ({testNodes: [{nodeType: "Unit test bundle", name: target,
    children: identifiers.map(nodeIdentifier => ({nodeType: "Test Case", nodeIdentifier, result: "Passed"}))}]});
const summary = count => ({totalTestCount: count, passedTests: count, failedTests: 0, skippedTests: 0});
const mac = PLATFORMS.find(platform => platform.id === "macos");

test("focused known app classes require their complete current method inventory", () => {
    const selected = ["Tests macOS/WalletAccessControllerTests", "Tests macOS/OnboardingCancellationTests"];
    const stages = createManifest(job({onlyTesting: selected}));
    const stage = stages.find(stage => stage.id === "test.macos.debug");
    const expected = stage.nativeAudit.requiredAppTests;
    assert.ok(expected.length > 30);
    assert.equal(stage.nativeAudit.exactAppInventory, true);
    assert.ok(stage.dependencies.includes("runtime.inventory"));
    assert.ok(expected.every(name => selected.some(prefix => name.startsWith(prefix + "/"))));
    assert.equal(auditNativeResult(summary(expected.length), tree(expected), stage.nativeAudit).ok, true);
    const one = expected.filter(name => name.endsWith("/testOldAuthenticationCannotReplaceNewAuthenticationOrUnlockAfterLock"));
    assert.equal(one.length, 1);
    assert.equal(auditNativeResult(summary(1), tree(one), stage.nativeAudit).ok, false);
    assert.equal(auditNativeResult(summary(expected.length + 1), tree([...expected, expected[0]]), stage.nativeAudit).ok, false);
    assert.equal(auditNativeResult(summary(expected.length + 1), tree([...expected, "UnexpectedTests/testUnexpected"]), stage.nativeAudit).ok, false);
    assert.equal(auditNativeResult(summary(expected.length), tree(expected, "Tests iOS"), stage.nativeAudit).ok, false);
});

test("full app runs require registered critical tests while permitting other app classes", () => {
    const policy = {configuration: "Debug", platform: "macos", kind: "full", ...appTestPolicy([], mac, "Debug")};
    assert.equal(policy.exactAppInventory, false);
    const names = [...policy.requiredAppTests, "OtherTests/testAdditional"];
    assert.equal(auditNativeResult(summary(names.length), tree(names), policy).ok, true);
    assert.equal(auditNativeResult(summary(names.length - 1), tree(names.slice(1)), policy).ok, false);
    assert.equal(auditNativeResult(summary(names.length + 1), tree([...names, names.at(-1)]), policy).ok, false);
    const extra = [...names, "WalletAccessControllerTests/testNotInTheInventory"];
    assert.equal(auditNativeResult(summary(extra.length), tree(extra), policy).ok, false);
});

test("known app classes route only to supported platforms", () => {
    for (const platform of PLATFORMS) {
        assert.equal(testingForPlatform(["OnboardingCancellationTests"], platform, "Debug").length, platform.id === "macos" ? 1 : 0);
        assert.equal(testingForPlatform(["MobileWalletAccessTests"], platform, "Debug").length, platform.id === "macos" ? 0 : 1);
        assert.equal(testingForPlatform(["WalletAccessControllerTests"], platform, "Debug").length, 1);
    }
    const stages = createManifest(job({onlyTesting: ["OnboardingCancellationTests"]}));
    assert.deepEqual(stages.filter(stage => stage.nativeAudit).map(stage => stage.id), ["test.macos.debug"]);
});

test("mixed and unregistered selections cannot silently omit requested suites or add unrelated tests", () => {
    for (const selectors of [
        ["Tests macOS/WalletAccessControllerTests", "Tests macOS/UnregisteredTests"],
        ["Tests macOS/UnregisteredTests/testSpecific"],
    ]) {
        const policy = {configuration: "Debug", platform: "macos", kind: "full", ...appTestPolicy(selectors, mac, "Debug")};
        const known = policy.requiredAppTests ?? [];
        const complete = [...known, "Tests macOS/UnregisteredTests/testSpecific"];
        assert.equal(auditNativeResult(summary(complete.length), tree(complete), policy).ok, true);
        assert.equal(auditNativeResult(summary(known.length), tree(known), policy).ok, false);
        const extra = [...complete, "Tests macOS/UnrequestedTests/testExtra"];
        assert.equal(auditNativeResult(summary(extra.length), tree(extra), policy).ok, false);
        assert.equal(auditNativeResult(summary(complete.length + 1), tree([...complete, complete.at(-1)]), policy).ok, false);
        assert.equal(auditNativeResult(summary(complete.length), tree(complete, "Tests iOS"), policy).ok, false);
    }
});

test("known nonexistent app methods cannot disappear beside valid class selectors", () => {
    for (const onlyTesting of [
        ["WalletAccessControllerTests/testMissing"],
        ["Tests macOS/WalletAccessControllerTests", "Tests macOS/OnboardingCancellationTests/testMissing"],
        ["Tests iOS/OnboardingCancellationTests"],
    ]) { assert.throws(() => createManifest(job({onlyTesting})), /App test selection did not match/); }
    assert.doesNotThrow(() => createManifest(job({onlyTesting: ["WalletSigningSessionTests"]})));
});

test("app audit rejects empty, malformed, duplicate, and wrong-platform policies", () => {
    const name = "Tests macOS/WalletAccessControllerTests/testFixture";
    const policy = {configuration: "Debug", platform: "macos", kind: "full", exactAppInventory: true};
    for (const requiredAppTests of [[], [name, name], ["Tests iOS/WalletAccessControllerTests/testFixture"], ["Tests macOS/WalletAccessControllerTests"], [null]]) {
        assert.equal(auditNativeResult(summary(1), tree([name]), {...policy, requiredAppTests}).ok, false);
    }
});

test("aggregate results require the registered app inventory audit", () => {
    const stage = createManifest(job({onlyTesting: ["Tests macOS/WalletAccessControllerTests"]}))
        .find(stage => stage.id === "test.macos.debug");
    const expected = stage.nativeAudit.requiredAppTests;
    const audit = auditNativeResult(summary(expected.length), tree(expected), stage.nativeAudit);
    assert.equal(auditResults([{id: stage.id, status: "passed", nativeAudit: stage.nativeAudit, audit}]).status, "passed");
    for (const missing of [undefined, {ok: false}]) {
        const result = auditResults([{id: stage.id, status: "passed", nativeAudit: stage.nativeAudit, audit: missing}]);
        assert.equal(result.status, "failed");
        assert.ok(result.issues.includes("test.macos.debug has no passing app XCTest inventory audit"));
    }
});
