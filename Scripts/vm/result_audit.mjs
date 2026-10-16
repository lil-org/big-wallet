import {PERFORMANCE_TESTS} from "./test_manifest.mjs";

const finiteCount = value => Number.isSafeInteger(value) && value >= 0;
const count = (summary, name) => finiteCount(summary[name]) ? summary[name] : undefined;

export function testCases(tree) {
    const cases = [];
    const visit = value => {
        if (!value || typeof value !== "object") { return; }
        if (Array.isArray(value)) { for (const item of value) { visit(item); } return; }
        if (value.nodeType === "Test Case") {
            if (typeof value.nodeIdentifier === "string" && typeof value.result === "string") {
                const messages = (value.children ?? []).filter(child => child.nodeType === "Skip Message" && typeof child.name === "string");
                cases.push({identifier: value.nodeIdentifier, result: value.result.toLowerCase(),
                    details: messages.length ? messages.map(child => child.name).join("\n") : undefined});
            }
            return;
        }
        if (Array.isArray(value.children)) { visit(value.children); }
    };
    if (Array.isArray(tree?.testNodes)) { visit(tree.testNodes); }
    return cases;
}

export function performanceTestName(identifier) {
    return PERFORMANCE_TESTS.find(name => identifier.includes("WalletCoreProxyPerformanceGateTests") &&
        new RegExp(`(?:^|/)${name}(?:\\(\\))?(?:$|/)`).test(identifier));
}

export function auditNativeResult(summary, tree, policy) {
    if (!summary || typeof summary !== "object") { throw new Error("Missing XCTest summary"); }
    const counts = {
        total: count(summary, "totalTestCount"),
        passed: count(summary, "passedTests"),
        failed: count(summary, "failedTests"),
        skipped: count(summary, "skippedTests"),
    };
    const issues = [];
    if (Object.values(counts).some(value => value === undefined) || counts.total === 0) { issues.push("XCTest did not report a nonempty, complete test count"); }
    if (Object.values(counts).every(value => value !== undefined) && counts.passed + counts.failed + counts.skipped !== counts.total) {
        issues.push("XCTest outcome counts do not match its total");
    }
    if (counts.failed > 0) { issues.push(`${counts.failed} XCTest failures`); }
    const cases = testCases(tree);
    if (counts.total !== cases.length) { issues.push("Test-case inventory does not match XCTest summary"); }
    const skipped = cases.filter(test => test.result === "skipped");
    if (counts.skipped !== skipped.length) { issues.push("Skipped-test inventory does not match XCTest summary"); }
    const expectedSkips = [];
    for (const test of skipped) {
        const performanceName = performanceTestName(test.identifier);
        if (policy.configuration === "Debug" && policy.kind === "full" && performanceName) { expectedSkips.push(performanceName); }
        else { issues.push(`Unexpected skipped test: ${test.identifier}`); }
    }
    const performancePassed = [...new Set(cases.filter(test => test.result === "passed").map(test => performanceTestName(test.identifier)).filter(Boolean))];
    if (policy.kind === "performance") {
        for (const name of PERFORMANCE_TESTS) { if (!performancePassed.includes(name)) { issues.push(`Release performance gate did not pass: ${name}`); } }
    }
    return {ok: issues.length === 0, counts, issues, skipped: skipped.map(test => test.identifier), expectedSkips, performancePassed};
}

export function auditResults(stages) {
    const issues = [];
    const released = new Map();
    for (const stage of stages) {
        const platform = stage.nativeAudit?.platform;
        if (stage.status !== "passed" || stage.nativeAudit?.configuration !== "Release" ||
            stage.audit?.ok !== true || typeof platform !== "string") { continue; }
        const gates = released.get(platform) ?? new Set();
        for (const name of stage.audit.performancePassed) { gates.add(name); }
        released.set(platform, gates);
    }
    for (const stage of stages) {
        if (stage.status === "passed") {
            for (const skipped of stage.audit?.expectedSkips ?? []) {
                if (!released.get(stage.nativeAudit?.platform)?.has(skipped)) {
                    issues.push(`${stage.id} skipped ${skipped} without a passing Release gate for its platform`);
                }
            }
        }
    }
    const counts = {passed: 0, failed: 0, blocked: 0, cancelled: 0};
    for (const stage of stages) {
        if (stage.status in counts) { counts[stage.status] += 1; }
        else { issues.push(`${stage.id} has no terminal outcome`); }
    }
    const status = counts.cancelled ? "cancelled" : counts.failed || counts.blocked || issues.length || !stages.length ? "failed" : "passed";
    return {status, counts, issues, tests: stages.filter(stage => stage.audit).map(stage => ({stage: stage.id, ...stage.audit.counts, skippedTests: stage.audit.skipped}))};
}
