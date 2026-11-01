import {constants} from "node:fs";
import {execFile} from "node:child_process";
import {lstat, open, realpath} from "node:fs/promises";
import {dirname, isAbsolute, join, resolve} from "node:path";
import {isDeepStrictEqual} from "node:util";
import {applyMutation, groupedWitnesses, isDigest, LIMITS, loadManifest, safeRelativePath, selectedMutants, sha256, VERSION} from "./contract.mjs";
import {javascriptCommand, nativeCommand} from "./commands.mjs";
import {bindTestPlan, bundleExecutable, derivedDataLocation} from "./products.mjs";

const validCount = value => Number.isSafeInteger(value) && value >= 0;
const successful = outcome => outcome && outcome.code === 0 && outcome.signal === null &&
    outcome.timedOut === false && outcome.cancelled === false && !outcome.error && !outcome.outputDrainTimedOut;

function outcomeFailure(outcome) {
    if (!outcome || typeof outcome.timedOut !== "boolean" || typeof outcome.cancelled !== "boolean" ||
        !(outcome.code === null || Number.isInteger(outcome.code)) || !(outcome.signal === null || typeof outcome.signal === "string")) {
        return "invalid-evidence";
    }
    if (outcome.cancelled) { return "cancelled"; }
    if (outcome.timedOut) { return "timed-out"; }
    if (outcome.signal) { return "crashed"; }
    if (outcome.error || outcome.outputDrainTimedOut) { return "infrastructure-failure"; }
    return null;
}

export function nativeCases(tree) {
    const cases = [];
    const visit = (node, target) => {
        if (!node || typeof node !== "object") { return; }
        if (Array.isArray(node)) { for (const child of node) { visit(child, target); } return; }
        if (node.nodeType === "Unit test bundle" && typeof node.name === "string") { target = node.name; }
        if (node.nodeType === "Test Case") {
            if (typeof node.nodeIdentifier !== "string" || typeof node.result !== "string") { throw new Error("Malformed XCTest case"); }
            let name = node.nodeIdentifier.replace(/\(\)$/, "");
            if (target && !name.startsWith(`${target}/`)) { name = `${target}/${name}`; }
            cases.push({name, result: node.result.toLowerCase()});
            return;
        }
        if (Array.isArray(node.children)) { visit(node.children, target); }
    };
    if (!Array.isArray(tree?.testNodes)) { throw new Error("Missing XCTest test inventory"); }
    visit(tree.testNodes);
    return cases;
}

export function parseNodeResults(text) {
    const records = text.trim().split("\n").filter(Boolean).map(line => JSON.parse(line));
    const complete = records.filter(record => record.kind === "complete");
    const cases = records.filter(record => record.kind === "case");
    if (complete.length !== 1 || records.at(-1) !== complete[0] || complete[0].count !== cases.length || records.length !== cases.length + 1 ||
        cases.some(record => typeof record.name !== "string" || !["passed", "failed", "skipped"].includes(record.result))) {
        throw new Error("Incomplete Node test reporter evidence");
    }
    return cases;
}

function assertionMessages(error) {
    if (!error || typeof error !== "object") { return []; }
    const messages = error.code === "ERR_ASSERTION" && typeof error.message === "string" ? [error.message] : [];
    return messages.concat(assertionMessages(error.cause));
}

export function classifyExecution(execution, {witness = null} = {}) {
    const issues = [];
    const result = status => ({status, issues});
    if (!execution || !Array.isArray(execution.selectors) || !execution.selectors.length ||
        new Set(execution.selectors).size !== execution.selectors.length) { return result("invalid-evidence"); }
    if (execution.family !== "javascript") {
        const problem = outcomeFailure(execution.build?.outcome);
        if (problem) { return result(problem); }
        if (!successful(execution.build.outcome)) { return result("compile-failure"); }
        const binaries = execution.binaries;
        if (!Array.isArray(binaries) || !binaries.length || binaries.some(binary =>
            !isDigest(binary.sha256) || !Number.isSafeInteger(binary.bytes) || binary.bytes <= 0 || typeof binary.target !== "string") ||
            execution.selectors.some(selector => !binaries.some(binary => binary.target === selector.split("/")[0]))) {
            issues.push("Missing built witness executable identities");
            return result("invalid-evidence");
        }
    }
    const problem = outcomeFailure(execution.test?.outcome);
    if (problem) { return result(problem); }
    const diagnostics = /Test (?:host|runner|process) (?:crashed|exited|failed|terminated)|Restarting after unexpected exit|Testing failed.*(?:crash|launch)|TEST EXECUTE INTERRUPTED|(?:signal|Signal):? (?:SIG[A-Z]+|11|6)|AddressSanitizer:DEADLYSIGNAL|test timed out/i;
    if (diagnostics.test(execution.diagnosticText ?? "") || diagnostics.test(JSON.stringify(execution.summary?.runtimeWarnings ?? []))) {
        issues.push("Test infrastructure or crash diagnostics accompany the result");
        return result("infrastructure-failure");
    }
    let cases;
    let messages = [];
    try {
        if (execution.family === "javascript") {
            const reported = parseNodeResults(execution.nodeResults);
            cases = reported.filter(record => execution.selectors.includes(record.name) || record.result !== "skipped");
            messages = cases.filter(record => record.result === "failed").flatMap(record => assertionMessages(record.error));
        } else {
            cases = nativeCases(execution.tree);
            cases = cases.map(test => {
                if (execution.selectors.includes(test.name)) { return test; }
                const matches = execution.selectors.filter(selector => selector.endsWith(`/${test.name}`));
                return matches.length === 1 ? {...test, name: matches[0]} : test;
            });
            const summary = execution.summary;
            if (![summary?.totalTestCount, summary?.passedTests, summary?.failedTests, summary?.skippedTests].every(validCount) ||
                summary.totalTestCount !== cases.length || summary.passedTests + summary.failedTests + summary.skippedTests !== cases.length ||
                summary.passedTests !== cases.filter(test => test.result === "passed").length ||
                summary.failedTests !== cases.filter(test => test.result === "failed").length || summary.skippedTests !== 0) {
                throw new Error("XCTest summary does not match the complete case inventory");
            }
            const failures = summary.testFailures ?? [];
            if (!Array.isArray(failures) || failures.some(failure => typeof failure?.failureText !== "string")) { throw new Error("Invalid XCTest failure provenance"); }
            if ((summary.failedTests === 0) !== (failures.length === 0)) { throw new Error("XCTest failure details disagree with the result counts"); }
            messages = failures.map(failure => failure.failureText);
        }
        if (cases.length !== execution.selectors.length || cases.some(test => !execution.selectors.includes(test.name) ||
            !["passed", "failed"].includes(test.result)) || execution.selectors.some(selector => cases.filter(test => test.name === selector).length !== 1)) {
            throw new Error("Every selected witness must execute exactly once without skips or unexpected cases");
        }
    } catch (error) { issues.push(error.message); return result("invalid-evidence"); }
    const failures = cases.filter(test => test.result === "failed");
    if (!failures.length) {
        if (!successful(execution.test.outcome)) { return result("infrastructure-failure"); }
        return result(witness ? "survived" : "passed");
    }
    if (!witness) { return result("baseline-failed"); }
    const expectedExit = execution.family === "javascript" ? 1 : 65;
    if (execution.test.outcome.code !== expectedExit || execution.selectors.length !== 1 ||
        failures.length !== 1 || failures[0].name !== witness.selector || !messages.length ||
        messages.some(message => !message.includes(witness.marker) || diagnostics.test(message))) {
        issues.push("Failure has no matching invariant assertion from the designated witness");
        return result("unexpected-failure");
    }
    return result("killed");
}

export async function readEvidenceFile(path, maximum = LIMITS.maximumArtifactBytes) {
    const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
        const before = await file.stat({bigint: true});
        if (!before.isFile() || before.size > BigInt(maximum)) { throw new Error("Mutation evidence must be a bounded regular file"); }
        const bytes = Buffer.alloc(Number(before.size));
        let offset = 0;
        while (offset < bytes.length) {
            const read = await file.read(bytes, offset, Math.min(65536, bytes.length - offset), offset);
            if (read.bytesRead === 0) { throw new Error("Mutation evidence shortened while reading"); }
            offset += read.bytesRead;
        }
        if ((await file.read(Buffer.alloc(1), 0, 1, bytes.length)).bytesRead !== 0) { throw new Error("Mutation evidence grew while reading"); }
        const after = await file.stat({bigint: true});
        const named = await lstat(path, {bigint: true});
        if (!named.isFile() || ["dev", "ino", "size", "mtimeNs", "ctimeNs"].some(key => before[key] !== after[key] || before[key] !== named[key])) {
            throw new Error("Mutation evidence changed while reading");
        }
        return bytes;
    } finally { await file.close(); }
}

export async function decodeRetainedPlist(bytes) {
    if (!Buffer.isBuffer(bytes) || bytes.length > LIMITS.maximumArtifactBytes) { throw new Error("Retained plist exceeds its byte bound"); }
    return await new Promise((resolvePlist, reject) => {
        const child = execFile("/usr/bin/plutil", ["-convert", "json", "-o", "-", "--", "-"],
            {encoding: "utf8", timeout: 10000, killSignal: "SIGKILL", maxBuffer: LIMITS.maximumArtifactBytes}, (error, stdout) => {
                if (error) { reject(new Error("Could not independently decode retained XCTest plist")); return; }
                try { resolvePlist(JSON.parse(stdout)); }
                catch { reject(new Error("Retained XCTest plist did not decode to valid JSON")); }
            });
        child.stdin.on("error", error => { if (error.code !== "EPIPE") { reject(error); child.kill("SIGKILL"); } });
        child.stdin.end(bytes);
    });
}

async function stableArtifact(root, artifact, json = false) {
    if (!safeRelativePath(artifact?.path) || !isDigest(artifact.sha256) || !validCount(artifact.bytes) || artifact.bytes > LIMITS.maximumArtifactBytes) {
        throw new Error("Invalid mutation artifact reference");
    }
    const path = join(root, artifact.path);
    if (await realpath(path) !== path) { throw new Error(`Mutation evidence traverses a symlink: ${artifact.path}`); }
    const bytes = await readEvidenceFile(path);
    if (bytes.length !== artifact.bytes || sha256(bytes) !== artifact.sha256) { throw new Error(`Mutation artifact changed: ${artifact.path}`); }
    return json === true ? JSON.parse(bytes) : json === "buffer" ? bytes : bytes.toString("utf8");
}

function inventory(manifest) {
    if (!manifest || manifest.version !== VERSION || !Array.isArray(manifest.files)) { throw new Error("Missing source inventory"); }
    return manifest.files.map(file => ({path: file.path, type: file.type, mode: file.mode, sha256: file.sha256,
        ...(file.type === "symlink" ? {target: file.target} : {})})).sort((a, b) => a.path.localeCompare(b.path));
}

export async function auditMutationEvidence(reportPath, policy) {
    const issues = [];
    const mutationCounts = {};
    let selected = [];
    const counted = new Set();
    const countMutation = (id, status) => {
        if (counted.has(id)) { return; }
        counted.add(id);
        mutationCounts[status] = (mutationCounts[status] ?? 0) + 1;
    };
    try {
        const loaded = await loadManifest();
        selected = selectedMutants(loaded.manifest, policy.tier);
        if (resolve(reportPath) !== reportPath || await realpath(reportPath) !== reportPath) { throw new Error("Mutation report must be an absolute regular artifact"); }
        const report = JSON.parse(await readEvidenceFile(reportPath));
        const root = dirname(reportPath);
        if (report.version !== VERSION || report.tier !== policy.tier || report.runId !== policy.runId || report.signing !== policy.signing ||
            report.configuration !== "Debug" || report.source?.sha256 !== policy.sourceSHA256 ||
            report.manifestSHA256 !== loaded.sha256 || !isDeepStrictEqual(report.selectedIDs, selected.map(mutant => mutant.id))) {
            throw new Error("Mutation report identity, tier, signing, source, or selected matrix does not match the stage");
        }
        const maximumSeconds = policy.tier === "core" ? LIMITS.coreSeconds : LIMITS.extendedSeconds;
        if (report.maximumSeconds !== maximumSeconds || !Number.isFinite(report.elapsedSeconds) || report.elapsedSeconds < 0 ||
            report.elapsedSeconds >= maximumSeconds || !Number.isFinite(Date.parse(report.startedAt)) || !Number.isFinite(Date.parse(report.finishedAt))) {
            throw new Error("Mutation report has invalid or exceeded runtime bounds");
        }
        if ([report.workspace, report.artifactDirectory, report.runnerRoot, report.nodeExecutable, report.derivedDataDirectory].some(path => !isAbsolute(path ?? "") || resolve(path) !== path) ||
            !/^platform=macOS(?:,arch=arm64)?$/.test(report.destinations?.macos ?? "") ||
            policy.tier === "extended" && !/^platform=iOS Simulator,id=[a-f0-9-]{36}$/i.test(report.destinations?.ios ?? "")) {
            throw new Error("Mutation execution locations or destinations are invalid");
        }
        const sourceManifest = await stableArtifact(root, report.sourceManifest, true);
        if (!isDeepStrictEqual(await stableArtifact(root, report.manifest, true), loaded.manifest)) { throw new Error("Retained mutation manifest differs from the selected contract"); }
        if (report.sourceManifest.sha256 !== policy.sourceSHA256) { throw new Error("Mutation source manifest does not match the staged snapshot"); }
        const expectedInventory = inventory(sourceManifest);
        const originals = new Map();
        for (const source of report.originals ?? []) {
            try {
                const expected = sourceManifest.files.find(file => file.path === source.source && file.type === "file");
                if (!expected || source.artifact?.sha256 !== expected.sha256 || originals.has(source.source)) { throw new Error("Invalid original source evidence"); }
                originals.set(source.source, await stableArtifact(root, source.artifact));
            } catch (error) { issues.push(`Original source ${source?.source ?? "unknown"}: ${error.message}`); }
        }
        const productLocations = new Map();
        const passingBefore = new Set();
        const readExecution = async (execution, witnesses, phase = "mutant") => {
            if (!execution) { throw new Error("Missing mutation execution evidence"); }
            let parsed = {...execution};
            if (execution.family === "javascript") {
                const command = javascriptCommand(witnesses, report);
                if (!isDeepStrictEqual(execution.test?.argv, [command.command, ...command.args]) || execution.test.cwd !== report.workspace) {
                    throw new Error("JavaScript mutation command does not match its curated witnesses");
                }
                parsed.diagnosticText = await stableArtifact(root, execution.test.log);
                parsed.nodeResults = await stableArtifact(root, execution.test.results);
            } else {
                const options = {...report.destinations, signing: report.signing, runId: report.runId};
                const build = nativeCommand(execution.family, "build-for-testing", witnesses.map(witness => witness.selector), options);
                if (!isDeepStrictEqual(execution.build?.argv, [build.command, ...build.args]) || execution.build.cwd !== join(report.workspace, build.cwd)) {
                    throw new Error("Mutation build command differs from its declared scope, signing or default DerivedData policy");
                }
                const buildLog = await stableArtifact(root, execution.build.log);
                if (!successful(execution.build.outcome)) { return parsed; }
                const pinnedLocation = phase === "before" ? null : productLocations.get(execution.family);
                if (phase !== "before" && !pinnedLocation) { throw new Error("No independently proven pristine product-location pin"); }
                const location = derivedDataLocation(buildLog, report.derivedDataDirectory, pinnedLocation);
                if (phase === "before") { productLocations.set(execution.family, location); }
                const plan = execution.build.testPlan;
                if (!plan || plan.root !== location.root || plan.products !== location.products || plan.locationSource !== location.locationSource || dirname(plan.originalPath ?? "") !== location.products ||
                    !plan.originalPath.endsWith(".xctestrun") || plan.afterSHA256 !== plan.source?.sha256) {
                    throw new Error("Mutation test plan is not bound to this build's default DerivedData products");
                }
                const rawPlan = await stableArtifact(root, plan.source, "buffer");
                const decodedPlan = await stableArtifact(root, plan.decoded, true);
                if (!isDeepStrictEqual(await decodeRetainedPlist(rawPlan), decodedPlan)) {
                    throw new Error("Retained raw XCTest run plan differs from its decoded evidence");
                }
                const binding = bindTestPlan(decodedPlan, {
                    family: execution.family, selectors: execution.selectors, products: location.products,
                });
                if (!binding) { throw new Error("Retained XCTest plan does not include the selected platform and targets"); }
                parsed.binaries = await stableArtifact(root, execution.build.binaries, true);
                const products = binding.flatMap(target => [{target: target.target, role: "test", bundle: target.bundle},
                    ...(target.host ? [{target: target.target, role: "host", bundle: target.host}] : [])]);
                if (!Array.isArray(execution.build.productInfo) || execution.build.productInfo.length !== products.length) { throw new Error("Missing bound XCTest product metadata"); }
                const expectedExecutables = [];
                for (const product of products) {
                    const infos = execution.build.productInfo.filter(info => info.target === product.target && info.role === product.role && info.bundle === product.bundle);
                    if (infos.length !== 1 || infos[0].afterSHA256 !== infos[0].source?.sha256) { throw new Error("XCTest product metadata changed or was omitted"); }
                    const rawInfo = await stableArtifact(root, infos[0].source, "buffer");
                    const info = await stableArtifact(root, infos[0].decoded, true);
                    if (!isDeepStrictEqual(await decodeRetainedPlist(rawInfo), info)) {
                        throw new Error("Retained raw product Info.plist differs from its decoded evidence");
                    }
                    expectedExecutables.push({...product, path: bundleExecutable(product.bundle, info, execution.family)});
                }
                if (!Array.isArray(parsed.binaries) || expectedExecutables.some(expected => parsed.binaries.filter(binary =>
                    binary.target === expected.target && binary.role === expected.role && binary.bundle === expected.bundle && binary.path === expected.path).length !== 1) ||
                    parsed.binaries.some(binary => !expectedExecutables.some(expected => binary.target === expected.target && binary.bundle === expected.bundle &&
                        (binary.role === expected.role && binary.path === expected.path || binary.role === `${expected.role}-debug` &&
                            dirname(binary.path ?? "") === dirname(expected.path) && binary.path.endsWith(".debug.dylib"))))) {
                    throw new Error("Executable hashes do not match the test bundles and app hosts in the built plan");
                }
                if (!isDeepStrictEqual(await stableArtifact(root, execution.test?.binariesAfter, true), parsed.binaries)) {
                    throw new Error("Bound XCTest executables changed during execution");
                }
                if (!safeRelativePath(execution.test?.resultBundle)) { throw new Error("Missing retained XCTest result bundle"); }
                const command = nativeCommand(execution.family, "test-without-building", witnesses.map(witness => witness.selector), {...options, testRunPath: plan.originalPath},
                    join(report.artifactDirectory, execution.test.resultBundle));
                if (!isDeepStrictEqual(execution.test.argv, [command.command, ...command.args]) || execution.test.cwd !== join(report.workspace, command.cwd)) {
                    throw new Error("Mutation test command differs from its declared witnesses or build configuration");
                }
                parsed.diagnosticText = await stableArtifact(root, execution.test.log);
                if (outcomeFailure(execution.test.outcome)) { return parsed; }
                parsed.summary = await stableArtifact(root, execution.test.summary, true);
                parsed.tree = await stableArtifact(root, execution.test.tree, true);
                const bundle = join(root, execution.test.resultBundle);
                if (!(await lstat(bundle)).isDirectory() || await realpath(bundle) !== bundle) { throw new Error("Invalid XCTest result bundle"); }
            }
            return parsed;
        };
        const groups = groupedWitnesses(selected);
        for (const name of ["baselineBefore", "baselineAfter"]) {
            if (!Array.isArray(report[name]) || report[name].length !== groups.length) { issues.push(`Incomplete ${name} inventory`); }
            for (const group of groups) {
                try {
                    const records = Array.isArray(report[name]) ? report[name].filter(record => record.family === group.family) : [];
                    if (records.length !== 1 || !isDeepStrictEqual(records[0].selectors, group.witnesses.map(witness => witness.selector))) { throw new Error(`Invalid ${name} selectors`); }
                    const audit = classifyExecution(await readExecution(records[0], group.witnesses, name === "baselineBefore" ? "before" : "after"));
                    if (audit.status !== "passed") { issues.push(`${name}/${group.family}: ${audit.status}`); }
                    else if (name === "baselineBefore") { passingBefore.add(group.family); }
                } catch (error) { issues.push(`${name}/${group.family}: ${error.message}`); }
            }
        }
        if (!Array.isArray(report.mutants) || report.mutants.length !== selected.length) { issues.push("Mutation report omitted selected mutants"); }
        for (const mutant of selected) {
            let audit, record;
            try {
                const records = Array.isArray(report.mutants) ? report.mutants.filter(record => record.id === mutant.id) : [];
                if (records.length !== 1) { throw new Error(`Missing or duplicate mutant: ${mutant.id}`); }
                record = records[0];
                if (!passingBefore.has(mutant.family)) { throw new Error("No passing pristine baseline for this witness family"); }
                const original = originals.get(mutant.source);
                const witness = originals.get(mutant.witness.file);
                if (original === undefined || witness === undefined || !witness.includes(mutant.witness.marker)) { throw new Error(`Missing original source or witness marker: ${mutant.id}`); }
                const expected = applyMutation(original, mutant).patch;
                const patch = await stableArtifact(root, record.patch, true);
                if (!isDeepStrictEqual(patch, expected)) { throw new Error(`Mutation differs from the curated source change: ${mutant.id}`); }
                const restored = await stableArtifact(root, record.restoration, true);
                if (!isDeepStrictEqual(inventory(restored), expectedInventory)) { throw new Error(`Mutant source was not restored: ${mutant.id}`); }
                if (record.execution?.family !== mutant.family || !isDeepStrictEqual(record.execution.selectors, [mutant.witness.selector])) {
                    throw new Error(`Mutant ran the wrong witness: ${mutant.id}`);
                }
                audit = classifyExecution(await readExecution(record.execution, [mutant.witness]), {witness: mutant.witness});
            }
            catch (error) { audit = {status: "invalid-evidence", issues: [error.message]}; }
            countMutation(mutant.id, audit.status);
            if (record && record.status !== audit.status) { issues.push(`${mutant.id}: recorded classification disagrees with evidence`); }
            if (audit.status !== "killed") { issues.push(`${mutant.id}: ${audit.status}`); }
            for (const issue of audit.issues) { issues.push(`${mutant.id}: ${issue}`); }
        }
        if (!isDeepStrictEqual(inventory(await stableArtifact(root, report.finalRestoration, true)), expectedInventory)) { issues.push("Final source restoration differs from baseline"); }
        if (report.status !== "passed") { issues.push(`Mutation runner finished with status ${report.status}`); }
        if (mutationCounts.killed !== selected.length) { issues.push("Every selected mutant must have a semantic assertion kill"); }
    } catch (error) { issues.push(error.message); }
    finally { for (const mutant of selected) { countMutation(mutant.id, "invalid-evidence"); } }
    return {ok: issues.length === 0, issues, mutationCounts};
}
