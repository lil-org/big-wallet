import assert from "node:assert/strict";
import test from "node:test";
import {classifyExecution, parseNodeResults} from "./audit.mjs";

const witness = {selector: "WalletAuthorityTests/GuardTests/testBinding", marker: "SECURITY-MUTATION[fixture.binding]"};
const success = () => ({code: 0, signal: null, timedOut: false, cancelled: false, error: null, outputDrainTimedOut: false});

function execution(failed = true) {
    return {family: "runtime", selectors: [witness.selector], build: {outcome: success()},
        binaries: [{target: "WalletAuthorityTests", sha256: "a".repeat(64), bytes: 10}],
        test: {outcome: {...success(), code: failed ? 65 : 0}},
        summary: {totalTestCount: 1, passedTests: failed ? 0 : 1, failedTests: failed ? 1 : 0, skippedTests: 0,
            testFailures: failed ? [{failureText: `failed - ${witness.marker}`}] : []},
        tree: {testNodes: [{nodeType: "Unit test bundle", name: "WalletAuthorityTests", children: [
            {nodeType: "Test Case", nodeIdentifier: "GuardTests/testBinding()", result: failed ? "Failed" : "Passed"},
        ]}]}};
}

test("a complete assertion failure is a kill and a passing mutant survives", () => {
    assert.equal(classifyExecution(execution(), {witness}).status, "killed");
    assert.equal(classifyExecution(execution(false), {witness}).status, "survived");
    assert.equal(classifyExecution(execution(false)).status, "passed");
    assert.equal(classifyExecution(execution()).status, "baseline-failed");
});

test("compile errors timeouts crashes cancellation and output truncation never kill a mutant", () => {
    for (const [field, value, expected] of [["timedOut", true, "timed-out"], ["cancelled", true, "cancelled"],
        ["signal", "SIGSEGV", "crashed"], ["error", "launch failed", "infrastructure-failure"], ["outputDrainTimedOut", true, "infrastructure-failure"]]) {
        const record = execution(); record.test.outcome[field] = value;
        assert.equal(classifyExecution(record, {witness}).status, expected);
    }
    const record = execution(); record.build.outcome.code = 65;
    assert.equal(classifyExecution(record, {witness}).status, "compile-failure");
    delete record.build.outcome;
    assert.equal(classifyExecution(record, {witness}).status, "invalid-evidence");
});

test("marker plus unrelated assertion or test-host crash is not a semantic kill", () => {
    for (const failureText of ["XCTAssertNotNil failed: fixture setup", "Test host crashed after assertion", `${witness.marker}: Test runner exited unexpectedly`]) {
        const record = execution(); record.summary.testFailures.push({failureText});
        assert.equal(classifyExecution(record, {witness}).status, "unexpected-failure");
    }
    for (const diagnosticText of ["Test host crashed", "Restarting after unexpected exit", "TEST EXECUTE INTERRUPTED"]) {
        assert.equal(classifyExecution({...execution(), diagnosticText}, {witness}).status, "infrastructure-failure");
    }
    const record = execution(); record.summary.runtimeWarnings = [{message: "Test runner failed to launch"}];
    assert.equal(classifyExecution(record, {witness}).status, "infrastructure-failure");
});

test("missing skipped duplicate wrong-name or ambiguous XCTest inventories fail closed", () => {
    for (const change of [
        record => { record.tree.testNodes[0].children = []; },
        record => { record.tree.testNodes[0].children[0].result = "Skipped"; },
        record => { record.tree.testNodes[0].children.push(record.tree.testNodes[0].children[0]); },
        record => { record.tree.testNodes[0].children[0].nodeIdentifier = "OtherTests/testOther()"; },
        record => { delete record.summary.failedTests; },
        record => { record.binaries = []; },
    ]) {
        const record = execution(); change(record);
        assert.equal(classifyExecution(record, {witness}).status, "invalid-evidence");
    }
});

test("an ordinary nonzero exit or an unmarked test failure is not a kill", () => {
    const unmarked = execution(); unmarked.summary.testFailures = [{failureText: "XCTAssertTrue failed"}];
    assert.equal(classifyExecution(unmarked, {witness}).status, "unexpected-failure");
    const arbitrary = execution(); arbitrary.test.outcome.code = 42;
    assert.equal(classifyExecution(arbitrary, {witness}).status, "unexpected-failure");
    const passed = execution(false); passed.test.outcome.code = 65;
    assert.equal(classifyExecution(passed, {witness}).status, "infrastructure-failure");
});

test("Node reporter requires complete assertion provenance for the exact filtered witness", () => {
    const jsWitness = {selector: "sender identity", marker: "SECURITY-MUTATION[sender.identity]"};
    const rows = [{kind: "case", name: jsWitness.selector, result: "failed", error: {code: "ERR_TEST_FAILURE", cause: {code: "ERR_ASSERTION", message: jsWitness.marker}}}, {kind: "complete", count: 1}];
    const record = {family: "javascript", selectors: [jsWitness.selector], test: {outcome: {...success(), code: 1}}, nodeResults: rows.map(row => JSON.stringify(row)).join("\n")};
    assert.equal(classifyExecution(record, {witness: jsWitness}).status, "killed");
    assert.throws(() => parseNodeResults(JSON.stringify(rows[0])), /Incomplete/);
    rows[0].error.cause.code = "ERR_OTHER";
    record.nodeResults = rows.map(row => JSON.stringify(row)).join("\n");
    assert.equal(classifyExecution(record, {witness: jsWitness}).status, "unexpected-failure");
    record.nodeResults = "broken JSON";
    assert.equal(classifyExecution(record, {witness: jsWitness}).status, "invalid-evidence");
});
