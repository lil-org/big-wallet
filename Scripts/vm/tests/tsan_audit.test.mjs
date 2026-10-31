import assert from "node:assert/strict";
import test from "node:test";
import {auditNativeResult, auditResults} from "../result_audit.mjs";

const identifiers = ["AccountPreviewStateTests/testFirst", "AccountPreviewStateTests/testSecond"];
const policy = {kind: "tsan", platform: "macos", configuration: "Debug", filtered: true,
    requiredTests: identifiers.map(name => `Tests macOS/${name}`)};
const summary = passed => ({totalTestCount: passed, passedTests: passed, failedTests: 0, skippedTests: 0});
const tree = (names = identifiers, target = "Tests macOS") => ({testNodes: [{nodeType: "Unit test bundle", name: target,
    children: names.map(name => ({nodeType: "Test Case", nodeIdentifier: `${name}()`, result: "Passed"}))}]});

test("app TSan accepts every selected method exactly once with qualified or bundle-relative identifiers", () => {
    for (const names of [identifiers, policy.requiredTests]) {
        const audit = auditNativeResult(summary(names.length), tree(names), policy);
        assert.equal(audit.ok, true);
        assert.deepEqual(audit.issues, []);
    }
});

test("app TSan rejects missing, duplicate, and unexpected methods even when every reported test passes", () => {
    for (const names of [identifiers.slice(0, 1), [...identifiers, identifiers[0]],
        [...identifiers, "UnselectedTests/testUnexpected"]]) {
        const audit = auditNativeResult(summary(names.length), tree(names), policy);
        assert.equal(audit.ok, false, names.join(","));
        assert.ok(audit.issues.some(issue => /must execute exactly once|Unexpected threadsanitizer test/.test(issue)));
    }
});

test("app TSan requires a nonempty unique method inventory and matching bundle identity", () => {
    for (const requiredTests of [undefined, [], [policy.requiredTests[0], policy.requiredTests[0]],
        ["Tests macOS/AccountPreviewStateTests"], ["OtherTarget/AccountPreviewStateTests/testFirst"], [null]]) {
        const audit = auditNativeResult(summary(2), tree(), {...policy, requiredTests});
        assert.equal(audit.ok, false);
        assert.ok(audit.issues.includes("ThreadSanitizer audit requires a nonempty, unique expected-test inventory"));
    }
    for (const names of [identifiers, policy.requiredTests]) {
        const audit = auditNativeResult(summary(2), tree(names, "OtherTarget"), policy);
        assert.equal(audit.ok, false);
    }
    const mismatched = auditNativeResult(summary(2), tree(policy.requiredTests, "OtherTarget"), policy);
    assert.ok(mismatched.issues.some(issue => issue.startsWith("ThreadSanitizer test bundle does not match its identifier")));
});

test("aggregate TSan results require a passing XCTest inventory audit", () => {
    const stage = {id: "tsan.focused", status: "passed", nativeAudit: policy,
        audit: auditNativeResult(summary(2), tree(), policy)};
    assert.equal(auditResults([stage]).status, "passed");
    for (const audit of [undefined, {...stage.audit, ok: false}]) {
        const result = auditResults([{...stage, audit}]);
        assert.equal(result.status, "failed");
        assert.ok(result.issues.includes("tsan.focused has no passing ThreadSanitizer XCTest audit"));
    }
});
