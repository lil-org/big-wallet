const objectWithKeys = (value, keys) => value !== null && typeof value === "object" && !Array.isArray(value) &&
    Object.keys(value).sort().join(",") === [...keys].sort().join(",");
const counterNames = ["interceptedCalls", "originalForwards", "safariPreRewrites", "safariPostRewrites",
    "nonSafariForwards", "nonSafariArgumentChanges"];
const framework = {bundleIdentifier: "com.apple.dt.XCUIAutomation", version: "25228",
    imageUUID: "6C9998E3-2351-34D3-BAAB-B523F500A26A"};
const selector = "waitForQuiescenceIncludingAnimationsIdle:usingActivity:isPreEvent:";
const methodEncoding = "v28@0:8B16B20B24";

export function expectedSynchronizationPolicy(platform) {
    if (platform === "ios") { return "safari-event-loop-only"; }
    if (platform === "macos") { return "xctest-default"; }
    throw new Error("Unsupported Safari synchronization platform");
}

export function auditSynchronizationSnapshot(snapshot, {policy, label = "Safari synchronization"} = {}) {
    const issues = [];
    if (policy === "xctest-default") {
        if (!objectWithKeys(snapshot, ["schemaVersion", "policy", "hookInstalled"]) ||
            snapshot.schemaVersion !== 1 || snapshot.policy !== policy || snapshot.hookInstalled !== false) {
            issues.push(`${label} must attest to default XCTest synchronization without a hook`);
        }
        return issues;
    }
    if (policy !== "safari-event-loop-only") { return [`${label} has an invalid synchronization policy`]; }
    if (!objectWithKeys(snapshot, ["schemaVersion", "policy", "installationID", "hookInstalled", "hookActive",
        "framework", "selector", "methodEncoding", "counters"]) || snapshot.schemaVersion !== 1 || snapshot.policy !== policy ||
        typeof snapshot.installationID !== "string" || !/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(snapshot.installationID) ||
        snapshot.hookInstalled !== true || snapshot.hookActive !== true) {
        issues.push(`${label} has no active, identified Safari event-loop-only hook`);
    }
    if (!objectWithKeys(snapshot?.framework, Object.keys(framework)) ||
        Object.entries(framework).some(([key, value]) => snapshot.framework[key] !== value) ||
        snapshot?.selector !== selector || snapshot?.methodEncoding !== methodEncoding) {
        issues.push(`${label} does not match the pinned XCTest framework and hook ABI`);
    }
    if (!objectWithKeys(snapshot?.counters, counterNames) ||
        counterNames.some(name => !Number.isSafeInteger(snapshot.counters[name]) || snapshot.counters[name] < 0)) {
        issues.push(`${label} has invalid hook counters`);
    } else {
        const counters = snapshot.counters;
        if (counters.originalForwards > counters.interceptedCalls ||
            counters.safariPreRewrites > counters.interceptedCalls ||
            counters.safariPostRewrites > counters.interceptedCalls ||
            counters.nonSafariForwards > counters.originalForwards ||
            (counters.interceptedCalls < Number.MAX_SAFE_INTEGER &&
                counters.safariPreRewrites + counters.safariPostRewrites + counters.nonSafariForwards > counters.interceptedCalls)) {
            issues.push(`${label} has inconsistent hook counters`);
        }
        if (counters.nonSafariArgumentChanges !== 0) {
            issues.push(`${label} changed non-Safari quiescence arguments`);
        }
    }
    return issues;
}

export function auditSynchronizationProof(proof, {policy, label = "Safari synchronization"} = {}) {
    if (!objectWithKeys(proof, ["before", "after"])) { return [`${label} is missing its before and after snapshots`]; }
    const issues = [
        ...auditSynchronizationSnapshot(proof.before, {policy, label: `${label} before`}),
        ...auditSynchronizationSnapshot(proof.after, {policy, label: `${label} after`}),
    ];
    if (issues.length || policy !== "safari-event-loop-only") { return issues; }
    if (proof.before.installationID !== proof.after.installationID) { issues.push(`${label} changed hook installation identity`); }
    if (proof.after.counters.interceptedCalls === Number.MAX_SAFE_INTEGER) {
        issues.push(`${label} has saturated hook counters`);
        return issues;
    }
    const delta = Object.fromEntries(counterNames.map(name => [name, proof.after.counters[name] - proof.before.counters[name]]));
    if (Object.values(delta).some(value => value < 0)) { issues.push(`${label} hook counters decreased`); }
    if (delta.originalForwards !== delta.interceptedCalls) { issues.push(`${label} did not forward every intercepted call to XCTest`); }
    const rewrites = delta.safariPreRewrites + delta.safariPostRewrites;
    const pendingCalls = proof.before.counters.interceptedCalls - proof.before.counters.originalForwards;
    if (rewrites > delta.interceptedCalls || delta.nonSafariForwards > delta.originalForwards ||
        rewrites + delta.nonSafariForwards > delta.interceptedCalls + pendingCalls) {
        issues.push(`${label} has inconsistent hook counter changes`);
    }
    if (delta.safariPreRewrites <= 0 || delta.safariPostRewrites <= 0) {
        issues.push(`${label} did not rewrite both Safari pre-event and post-event animation waits`);
    }
    return issues;
}
