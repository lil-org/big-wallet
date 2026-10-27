import {createHash} from "node:crypto";
import {isAbsolute, resolve} from "node:path";
import {PERFORMANCE_TESTS, RUNTIME_TEST_TARGETS, validSafariPreparationReference} from "./test_manifest.mjs";
import {auditSynchronizationProof, expectedSynchronizationPolicy} from "../safari/synchronization.mjs";
import {validateSourceIdentity} from "../approval_lifecycle/source_identity.mjs";

const finiteCount = value => Number.isSafeInteger(value) && value >= 0;
const count = (summary, name) => finiteCount(summary[name]) ? summary[name] : undefined;
const bundleMetadata = value => typeof value === "string" && value.trim().length > 0 && value.length <= 256 && !/[\u0000-\u001f\u007f]/.test(value);

export function testCases(tree) {
    const cases = [];
    const visit = (value, target) => {
        if (!value || typeof value !== "object") { return; }
        if (Array.isArray(value)) { for (const item of value) { visit(item, target); } return; }
        if (value.nodeType === "Unit test bundle" && typeof value.name === "string") { target = value.name; }
        if (value.nodeType === "Test Case") {
            if (typeof value.nodeIdentifier === "string" && typeof value.result === "string") {
                const messages = (value.children ?? []).filter(child => child.nodeType === "Skip Message" && typeof child.name === "string");
                cases.push({identifier: value.nodeIdentifier, result: value.result.toLowerCase(), ...(target ? {target} : {}),
                    details: messages.length ? messages.map(child => child.name).join("\n") : undefined});
            }
            return;
        }
        if (Array.isArray(value.children)) { visit(value.children, target); }
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
    if (counts.failed > 0) {
        issues.push(`${counts.failed} XCTest failures`);
        if (policy.kind === "safari" && Array.isArray(summary.testFailures)) {
            for (const failure of summary.testFailures.slice(0, 10)) {
                const detail = typeof failure?.failureText === "string" ? failure.failureText.slice(0, 2048).trim() : "";
                if (detail) { issues.push(`Safari XCTest failure: ${detail}`); }
            }
        }
    }
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
    if (policy.runtime === true) {
        const expected = policy.requiredTests;
        if (!Array.isArray(expected) || !expected.length || expected.some(name => typeof name !== "string" ||
            !RUNTIME_TEST_TARGETS.some(target => name.startsWith(`${target}/`))) || new Set(expected).size !== expected.length) {
            issues.push("Runtime audit requires a nonempty, unique expected-test inventory");
        } else {
            const inventory = new Map();
            for (const test of cases) {
                let identifier = test.identifier.replace(/\(\)$/, "");
                if (!(identifier.split("/").length === 3 && RUNTIME_TEST_TARGETS.some(target => identifier.startsWith(`${target}/`)))) {
                    if (RUNTIME_TEST_TARGETS.includes(test.target)) { identifier = `${test.target}/${identifier}`; }
                    else if (!test.target) {
                        const matches = expected.filter(name => name.endsWith(`/${identifier}`));
                        if (matches.length === 1) { identifier = matches[0]; }
                    }
                }
                inventory.set(identifier, (inventory.get(identifier) ?? 0) + 1);
                if (!expected.includes(identifier)) { issues.push(`Unexpected runtime test: ${test.identifier}`); }
                if (test.result !== "passed" && !(test.result === "skipped" && policy.configuration === "Debug" &&
                    policy.kind === "full" && performanceTestName(identifier))) {
                    issues.push(`Runtime test did not pass: ${test.identifier} (${test.result})`);
                }
            }
            for (const identifier of expected) {
                if (inventory.get(identifier) !== 1) { issues.push(`Runtime test must execute exactly once: ${identifier}`); }
            }
        }
    }
    if (policy.kind === "safari") {
        if (summary.runtimeWarnings !== undefined && !Array.isArray(summary.runtimeWarnings)) {
            issues.push("Safari XCTest summary has an invalid runtime-warning inventory");
        } else if (summary.runtimeWarnings?.length) {
            issues.push(`${summary.runtimeWarnings.length} Safari XCTest runtime warnings`);
        }
        const expected = policy.requiredTests;
        if (!Array.isArray(expected) || !expected.length || expected.some(name => typeof name !== "string") || new Set(expected).size !== expected.length) {
            issues.push("Safari audit requires a nonempty, unique expected-test inventory");
        } else {
            const target = policy.platform === "macos" ? "Safari UI Tests macOS" : "Safari UI Tests iOS";
            const inventory = new Map();
            for (const test of cases) {
                const identifier = test.identifier.replace(new RegExp(`^${target}/`), "").replace(/\(\)$/, "");
                inventory.set(identifier, (inventory.get(identifier) ?? 0) + 1);
                if (!expected.includes(identifier)) { issues.push(`Unexpected Safari test: ${test.identifier}`); }
                if (test.result !== "passed") { issues.push(`Safari test did not pass: ${test.identifier} (${test.result})`); }
            }
            for (const identifier of expected) {
                if (inventory.get(identifier) !== 1) { issues.push(`Safari test must execute exactly once: ${identifier}`); }
            }
        }
    }
    return {ok: issues.length === 0, counts, issues, skipped: skipped.map(test => test.identifier), expectedSkips, performancePassed};
}

export function auditApprovalResult(report, policy) {
    const issues = [];
    const bounds = policy?.profile === "extended"
        ? {preemptions: 2, transitions: 128, traces: 4096, faults: 2, actors: 3}
        : {preemptions: 1, transitions: 64, traces: 256, faults: 1, actors: 2};
    if (!["all", "extended"].includes(policy?.profile) || !Number.isSafeInteger(policy.traceLimit) ||
        policy.traceLimit < 1 || policy.traceLimit > bounds.traces || !Array.isArray(policy.modes) || !policy.modes.length ||
        new Set(policy.modes).size !== policy.modes.length || policy.modes.some(mode => !["native", "popup"].includes(mode))) {
        return {ok: false, issues: ["Invalid approval exploration policy"]};
    }
    if (!report || report.version !== 1 || report.status !== "complete" || report.profile !== policy.profile || report.frontier !== 0 ||
        !Number.isSafeInteger(report.traces) || report.traces < 1 || report.traces > policy.traceLimit ||
        !Array.isArray(report.scenarios) || !report.scenarios.length) {
        return {ok: false, issues: ["Approval exploration did not exhaust a nonempty bounded frontier"]};
    }
    try { validateSourceIdentity(report.sourceIdentity); }
    catch { issues.push("Approval exploration omitted a valid source and worker identity"); }
    const scenarios = new Set();
    const families = new Map();
    let traces = 0;
    for (const scenario of report.scenarios) {
        const identity = /^(native|popup)\/systematic\/(ethereum|solana)\/([a-z0-9-]+)$/.exec(scenario?.scenario ?? "");
        if (!identity || !policy.modes.includes(identity[1]) || scenarios.has(scenario.scenario)) {
            issues.push("Approval exploration has an invalid or duplicated scenario"); continue;
        }
        scenarios.add(scenario.scenario);
        const family = `${identity[1]}/${identity[2]}`;
        const templates = families.get(family) ?? new Set();
        templates.add(identity[3]); families.set(family, templates);
        if (scenario.profile !== policy.profile || scenario.frontier !== 0 || !finiteCount(scenario.completed) || scenario.completed < 1 ||
            !finiteCount(scenario.pruned) || !finiteCount(scenario.finished) || scenario.finished < 1 ||
            scenario.finished + scenario.pruned !== scenario.completed || !scenario.bounds ||
            scenario.requests !== (policy.profile === "extended" ? 3 : 2) || scenario.faultsApplied !== bounds.faults ||
            !Number.isSafeInteger(scenario.bounds.traces) || scenario.bounds.traces < 1 || scenario.bounds.traces > policy.traceLimit ||
            scenario.completed > scenario.bounds.traces || ["preemptions", "transitions", "faults", "actors"].some(key => scenario.bounds[key] !== bounds[key])) {
            issues.push(`Approval exploration has incomplete bounds or outcomes: ${scenario.scenario}`);
        }
        traces += scenario.completed;
    }
    const expectedTemplates = ["authentication-cancellation", "signing-cancellation", "signing-revocation", "publication-cancellation",
        "checkpoint-cancellation", "dispatch-cancellation", "completion-cancellation", "delivery-cancellation"].sort();
    for (const mode of policy.modes) {
        for (const provider of ["ethereum", "solana"]) {
            if (JSON.stringify([...(families.get(`${mode}/${provider}`) ?? [])].sort()) !== JSON.stringify(expectedTemplates)) {
                issues.push(`Approval exploration omitted a mode/provider family: ${mode}/${provider}`);
            }
        }
    }
    if (traces !== report.traces) { issues.push("Approval trace totals do not match the scenario inventory"); }
    return {ok: issues.length === 0, issues, sourceIdentity: report.sourceIdentity,
        profile: policy.profile, traces: report.traces, scenarios: scenarios.size, frontier: report.frontier};
}

export function auditSafariResult(evidence, policy, {runId, stageId} = {}) {
    const issues = [];
    const expected = policy.requiredScenarios;
    if (!Array.isArray(expected) || !expected.length || expected.some(id => typeof id !== "string") || new Set(expected).size !== expected.length ||
        !Number.isSafeInteger(policy.iterations) || policy.iterations < 1 || policy.iterations > 10 ||
        !["automatic", "interactive", "prepared"].includes(policy.activationMode) ||
        policy.activationMode !== "automatic" && policy.platform !== "macos" ||
        policy.activationMode === "prepared" && (policy.signing !== "local" || !validSafariPreparationReference(policy.preparation))) {
        return {ok: false, issues: ["Safari audit requires a bounded, nonempty scenario inventory"], scenarioCount: 0};
    }
    if (!evidence || typeof evidence !== "object" || Array.isArray(evidence)) {
        return {ok: false, issues: ["Missing Safari browser evidence"], scenarioCount: 0};
    }
    if (!["ios", "macos"].includes(policy.platform) ||
        policy.synchronizationPolicy !== expectedSynchronizationPolicy(policy.platform)) {
        issues.push("Safari audit has an invalid synchronization policy");
    }
    for (const [key, value] of Object.entries({version: 1, runId, stageId, platform: policy.platform,
        configuration: policy.configuration, signing: policy.signing, iterations: policy.iterations, activationMode: policy.activationMode,
        synchronizationPolicy: policy.synchronizationPolicy})) {
        if (value === undefined || evidence[key] !== value) { issues.push(`Safari evidence has an invalid ${key}`); }
    }
    if (policy.activationMode === "prepared") {
        if (!validSafariPreparationReference(evidence.preparation) ||
            evidence.preparation.preparationRunID !== policy.preparation.preparationRunID ||
            evidence.preparation.receiptSHA256 !== policy.preparation.receiptSHA256) {
            issues.push("Safari evidence does not match the verified baseline preparation");
        }
    } else if (evidence.preparation !== undefined && evidence.preparation !== null) {
        issues.push("Safari evidence contains an unrequested baseline preparation");
    }
    const browserIdentifier = policy.platform === "macos" ? "com.apple.Safari" : "com.apple.mobilesafari";
    if (evidence.browser?.bundleIdentifier !== browserIdentifier || typeof evidence.browser?.version !== "string" || !evidence.browser.version.length) {
        issues.push("Safari evidence did not identify the tested browser and version");
    }
    if (evidence.extensionIdentifier !== "org.lil.wallet.Safari") {
        issues.push("Safari evidence did not identify the expected wallet extension");
    }
    if (evidence.extension?.bundleIdentifier !== "org.lil.wallet.Safari" ||
        !bundleMetadata(evidence.extension?.version) || !bundleMetadata(evidence.extension?.build)) {
        issues.push("Safari evidence did not identify the tested extension bundle, version, and build");
    }
    const macOS = evidence.runtime?.macOS;
    if (typeof macOS?.version !== "string" || macOS.version.length > 128 || !/^\d+(?:\.\d+){0,3}$/.test(macOS.version) ||
        typeof macOS?.build !== "string" || !/^[A-Za-z0-9]{1,128}$/.test(macOS.build)) {
        issues.push("Safari evidence did not identify the guest macOS version and build");
    }
    if (evidence.handshake?.provider !== true || evidence.handshake?.native !== true) {
        issues.push("Safari provider and native messaging handshake did not pass");
    }
    if (evidence.cleanup?.status !== "passed") {
        issues.push("Safari evidence has no successful final cleanup");
    }
    const activations = evidence.activationRequests;
    if (!Array.isArray(activations) || activations.length > 512 ||
        policy.activationMode !== "interactive" && activations.length) {
        issues.push("Safari evidence has an invalid activation checkpoint inventory");
    } else {
        let previousObservation = 0;
        for (const activation of activations) {
            const requestedAt = Date.parse(activation?.requestedAt);
            const observedAt = Date.parse(activation?.observedAt);
            if (!activation || typeof activation.enabled !== "boolean" || !expected.includes(activation.scenario?.id) ||
                !Number.isSafeInteger(activation.scenario?.iteration) || activation.scenario.iteration < 1 ||
                activation.scenario.iteration > policy.iterations || typeof activation.requestedAt !== "string" ||
                typeof activation.observedAt !== "string" || !Number.isFinite(requestedAt) ||
                !Number.isFinite(observedAt) || requestedAt < previousObservation || observedAt < requestedAt) {
                issues.push("Safari evidence has an incomplete or invalid activation checkpoint");
            }
            previousObservation = observedAt;
        }
    }
    const scenarios = evidence.scenarios;
    const inventory = new Map();
    let nonSafariForwards = 0;
    if (!Array.isArray(scenarios)) { issues.push("Missing Safari scenario evidence"); }
    else {
        for (const scenario of scenarios) {
            if (!scenario || typeof scenario !== "object" || !expected.includes(scenario.id) ||
                !Number.isSafeInteger(scenario.iteration) || scenario.iteration < 1 || scenario.iteration > policy.iterations) {
                issues.push("Safari evidence contains an unexpected scenario or iteration");
                continue;
            }
            const key = `${scenario.id}:${scenario.iteration}`;
            inventory.set(key, (inventory.get(key) ?? 0) + 1);
            if (scenario.status !== "passed") { issues.push(`Safari scenario did not pass: ${key}`); }
            const synchronizationIssues = auditSynchronizationProof(scenario.synchronization,
                {policy: policy.synchronizationPolicy, label: `Safari scenario ${key} synchronization`});
            issues.push(...synchronizationIssues);
            if (!synchronizationIssues.length && policy.synchronizationPolicy === "safari-event-loop-only") {
                nonSafariForwards += scenario.synchronization.after.counters.nonSafariForwards -
                    scenario.synchronization.before.counters.nonSafariForwards;
            }
        }
    }
    for (const id of expected) {
        for (let iteration = 1; iteration <= policy.iterations; iteration += 1) {
            const key = `${id}:${iteration}`;
            if (inventory.get(key) !== 1) { issues.push(`Safari scenario must pass exactly once: ${key}`); }
        }
    }
    if (policy.synchronizationPolicy === "safari-event-loop-only" && nonSafariForwards <= 0) {
        issues.push("Safari synchronization did not prove any unchanged non-Safari forwarding during the stage");
    }
    return {ok: issues.length === 0, issues, scenarioCount: inventory.size,
        iterations: policy.iterations, browser: evidence.browser, extensionIdentifier: evidence.extensionIdentifier,
        extension: evidence.extension, runtime: evidence.runtime, activationMode: evidence.activationMode,
        synchronizationPolicy: evidence.synchronizationPolicy,
        ...(policy.activationMode === "prepared" ? {preparation: evidence.preparation} : {}),
        cleanup: evidence.cleanup?.status ?? "missing"};
}

export function auditSafariPreparation(evidence, {runId} = {}) {
    const issues = [];
    const objectWithKeys = (value, keys) => value !== null && typeof value === "object" && !Array.isArray(value) &&
        Object.keys(value).sort().join(",") === [...keys].sort().join(",");
    const path = value => typeof value === "string" && value.length <= 4096 && isAbsolute(value) &&
        resolve(value) === value && !/[\u0000-\u001f\u007f]/.test(value);
    const time = value => typeof value === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value) &&
        Number.isFinite(Date.parse(value)) && new Date(value).toISOString() === value;
    const fields = ["version", "status", "preparationRunID", "platform", "configuration", "signingMode",
        "installationDirectory", "receiptSHA256", "receipt"];
    if (!objectWithKeys(evidence, fields) || evidence.version !== 1 || evidence.status !== "passed" ||
        evidence.preparationRunID !== runId || evidence.platform !== "macos" ||
        evidence.configuration !== "Debug" || evidence.signingMode !== "local" ||
        !validSafariPreparationReference({preparationRunID: runId, receiptSHA256: evidence?.receiptSHA256})) {
        return {ok: false, issues: ["Safari preparation result has an invalid status or identity"]};
    }
    const receipt = evidence.receipt;
    if (!objectWithKeys(receipt, ["version", "status", "preparationRunID", "descriptor", "installationDirectory",
        "sourceApp", "signatures", "enabledObservation", "cleanup", "preparedAt"]) ||
        receipt.version !== 1 || receipt.status !== "passed" || receipt.preparationRunID !== runId) {
        return {ok: false, issues: ["Safari preparation receipt has an invalid status or identity"]};
    }
    if (createHash("sha256").update(JSON.stringify(receipt)).digest("hex") !== evidence.receiptSHA256) {
        issues.push("Safari preparation receipt digest does not match its contents");
    }
    const descriptor = receipt.descriptor;
    if (!objectWithKeys(descriptor, ["version", "runID", "root", "platform", "signingMode", "configuration"]) ||
        descriptor.version !== 1 || descriptor.runID !== runId || descriptor.platform !== "macos" ||
        descriptor.signingMode !== "local" || descriptor.configuration !== "Debug" ||
        descriptor.root !== `/Volumes/BigWalletBuild/Exchange/${runId}/safari/macos/Debug`) {
        issues.push("Safari preparation receipt does not match the current fixture descriptor");
    }
    const installation = receipt.installationDirectory;
    if (!path(installation) || !installation.endsWith("/Applications/BigWalletSafariVM/Prepared") ||
        installation !== evidence.installationDirectory ||
        !path(receipt.sourceApp) || !receipt.sourceApp.includes("/Library/Developer/Xcode/DerivedData/") ||
        !receipt.sourceApp.endsWith("/Big Wallet.app")) {
        issues.push("Safari preparation receipt has invalid installation paths");
    }
    if (!objectWithKeys(receipt.signatures, ["app", "extension", "helper"])) {
        issues.push("Safari preparation receipt is missing signed product identities");
    } else {
        for (const [role, identifier] of [["app", "org.lil.wallet"], ["extension", "org.lil.wallet.Safari"], ["helper", "org.lil.wallet.ambient"]]) {
            const signature = receipt.signatures[role];
            if (!objectWithKeys(signature, ["identifier", "cdhash"]) || signature.identifier !== identifier ||
                typeof signature.cdhash !== "string" || !/^[a-f0-9]{40}$/.test(signature.cdhash)) {
                issues.push(`Safari preparation receipt has an invalid ${role} signature identity`);
            }
        }
    }
    const observation = receipt.enabledObservation;
    if (!objectWithKeys(observation, ["enabled", "processID", "executablePath", "preparationNonce", "observedAt"]) ||
        observation.enabled !== true || !Number.isSafeInteger(observation.processID) || observation.processID <= 1 ||
        observation.processID > 2147483647 || observation.executablePath !== `${installation}/Big Wallet.app/Contents/MacOS/Big Wallet` ||
        typeof observation.preparationNonce !== "string" ||
        !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(observation.preparationNonce) ||
        !time(observation.observedAt) || !time(receipt.preparedAt) || Date.parse(observation.observedAt) > Date.parse(receipt.preparedAt)) {
        issues.push("Safari preparation receipt has no valid native enabled-state observation");
    }
    if (!objectWithKeys(receipt.cleanup, ["status"]) || receipt.cleanup.status !== "passed") {
        issues.push("Safari preparation receipt has no successful process cleanup");
    }
    return {ok: issues.length === 0, issues,
        preparation: {preparationRunID: runId, receiptSHA256: evidence.receiptSHA256}};
}

export function auditResults(stages) {
    const issues = [];
    const released = new Map();
    for (const stage of stages) {
        const platform = stage.nativeAudit?.platform;
        if (stage.status !== "passed" || stage.nativeAudit?.configuration !== "Release" ||
            stage.audit?.ok !== true || typeof platform !== "string") { continue; }
        const gates = released.get(platform) ?? new Set();
        for (const name of stage.audit.performancePassed ?? []) { gates.add(name); }
        released.set(platform, gates);
    }
    for (const stage of stages) {
        if (stage.status === "passed") {
            if (stage.nativeAudit?.runtime === true && stage.audit?.ok !== true) {
                issues.push(`${stage.id} has no passing runtime XCTest audit`);
            }
            if (stage.approvalAudit && stage.audit?.ok !== true) {
                issues.push(`${stage.id} has no passing approval exploration audit`);
            }
            if (stage.upgradeAudit && stage.audit?.ok !== true) {
                issues.push(`${stage.id} has no passing shipped-main upgrade and recovery audit`);
            }
            if (stage.preparationResult && stage.audit?.ok !== true) {
                issues.push(`${stage.id} has no passing Safari preparation audit`);
            }
            if (stage.nativeAudit?.kind === "safari" && (stage.audit?.ok !== true || stage.audit.safari?.ok !== true || stage.audit.safariLog?.ok !== true)) {
                issues.push(`${stage.id} has no passing Safari browser audit`);
            }
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
    return {status, counts, issues, tests: stages.filter(stage => stage.audit?.counts).map(stage => ({stage: stage.id, ...stage.audit.counts, skippedTests: stage.audit.skipped}))};
}
