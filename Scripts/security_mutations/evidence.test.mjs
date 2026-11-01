import assert from "node:assert/strict";
import {mkdir, mkdtemp, readFile, realpath, rm, writeFile} from "node:fs/promises";
import {dirname, join} from "node:path";
import {tmpdir} from "node:os";
import test from "node:test";
import {auditMutationEvidence} from "./audit.mjs";
import {applyMutation, groupedWitnesses, LIMITS, loadManifest, selectedMutants, sha256} from "./contract.mjs";
import {nativeCommand} from "./commands.mjs";
import {bundleExecutable} from "./products.mjs";

async function fixture(t) {
    const root = await realpath(await mkdtemp(join(tmpdir(), "mutation-evidence-")));
    t.after(() => rm(root, {recursive: true, force: true}));
    const artifact = async (path, value, raw = false) => {
        const bytes = Buffer.from(raw ? value : JSON.stringify(value));
        await mkdir(dirname(join(root, path)), {recursive: true});
        await writeFile(join(root, path), bytes);
        return {path, sha256: sha256(bytes), bytes: bytes.length};
    };
    const loaded = await loadManifest(), mutants = selectedMutants(loaded.manifest, "core");
    const sourceTexts = new Map();
    for (const mutant of mutants) {
        sourceTexts.set(mutant.source, mutant.edits.map(edit => edit.find).join("\n"));
        sourceTexts.set(mutant.witness.file, (sourceTexts.get(mutant.witness.file) ?? "") + mutant.witness.marker + "\n");
    }
    const sourceManifest = {version: 1, files: [...sourceTexts].map(([path, text]) => ({path, mode: 0o644, type: "file", sha256: sha256(text)}))};
    const sourceArtifact = await artifact("source-manifest.json", sourceManifest);
    const report = {version: 1, tier: "core", signing: "local", configuration: "Debug", runId: "fixture-run",
        source: {sha256: sourceArtifact.sha256, commit: "a".repeat(40), fileCount: sourceManifest.files.length},
        sourceManifest: sourceArtifact, manifestSHA256: loaded.sha256,
        manifest: await artifact("mutation-manifest.json", loaded.bytes, true), selectedIDs: mutants.map(mutant => mutant.id),
        maximumSeconds: LIMITS.coreSeconds, elapsedSeconds: 1, startedAt: new Date().toISOString(), finishedAt: new Date().toISOString(),
        status: "passed", workspace: "/guest/mutation/workspace", artifactDirectory: "/guest/artifacts",
        runnerRoot: "/guest/source", nodeExecutable: "/usr/local/bin/node", destinations: {macos: "platform=macOS,arch=arm64"}, originals: []};
    report.derivedDataDirectory = "/Users/wallet-test/Library/Developer/Xcode/DerivedData";
    for (const [source, text] of sourceTexts) { report.originals.push({source, artifact: await artifact(`originals/${source}`, text, true)}); }
    const success = {code: 0, signal: null, timedOut: false, cancelled: false, outputDrainTimedOut: false, error: null};
    const execution = async (family, witnesses, label, killed = false) => {
        const selectors = witnesses.map(witness => witness.selector), options = {...report.destinations, signing: report.signing, runId: report.runId};
        const build = nativeCommand(family, "build-for-testing", selectors, options);
        const bundle = `${label}/tests.xcresult`;
        await mkdir(join(root, bundle), {recursive: true});
        const targets = [...new Set(selectors.map(selector => selector.split("/")[0]))];
        const buildRoot = `${report.derivedDataDirectory}/Wallet-${family}`, products = `${buildRoot}/Build/Products`;
        const originalPath = `${products}/selected.xctestrun`;
        const host = family === "runtime" ? null : `${products}/Debug/Big Wallet.app`;
        const runPlan = {TestConfigurations: [{TestTargets: targets.map(target => ({BlueprintName: target,
            TestBundlePath: `__TESTROOT__/Debug/${target}.xctest`, ...(host ? {TestHostPath: host + "/Contents/MacOS/Big Wallet"} : {})}))}]};
        const planSource = await artifact(`${label}/built.xctestrun`, runPlan);
        const testPlan = {originalPath, root: buildRoot, products, locationSource: "emitted", source: planSource,
            decoded: await artifact(`${label}/test-plan.json`, runPlan), afterSHA256: planSource.sha256};
        const test = nativeCommand(family, "test-without-building", selectors, {...options, testRunPath: originalPath}, join(report.artifactDirectory, bundle));
        const productInfo = [], binaries = [];
        for (const target of targets) {
            for (const [role, directory] of [["test", `${products}/Debug/${target}.xctest`], ...(host ? [["host", host]] : [])]) {
                const info = {CFBundleExecutable: role === "test" ? target : "Big Wallet"};
                const source = await artifact(`${label}/${productInfo.length}.Info.plist`, info);
                productInfo.push({target, role, bundle: directory, source,
                    decoded: await artifact(`${label}/${productInfo.length}.Info.json`, info), afterSHA256: source.sha256});
                binaries.push({target, role, bundle: directory, path: bundleExecutable(directory, info, family), sha256: "b".repeat(64), bytes: 128});
            }
        }
        const tree = {testNodes: targets.map(target => ({nodeType: "Unit test bundle", name: target,
            children: selectors.filter(selector => selector.startsWith(target + "/")).map(selector => ({nodeType: "Test Case",
                nodeIdentifier: selector.split("/").slice(1).join("/") + "()", result: killed ? "Failed" : "Passed"}))}))};
        return {family, selectors, status: killed ? "killed" : "passed",
            build: {argv: [build.command, ...build.args], cwd: join(report.workspace, build.cwd), outcome: {...success},
                log: await artifact(`${label}/build.log`, `Build description path: ${buildRoot}/Build/Intermediates.noindex/XCBuildData/current.xcbuilddata`, true),
                testPlan, productInfo, binaries: await artifact(`${label}/binaries.json`, binaries)},
            test: {argv: [test.command, ...test.args], cwd: join(report.workspace, test.cwd), outcome: {...success, code: killed ? 65 : 0},
                log: await artifact(`${label}/test.log`, "test completed", true), resultBundle: bundle,
                binariesAfter: await artifact(`${label}/binaries-after.json`, binaries),
                summary: await artifact(`${label}/summary.json`, {totalTestCount: selectors.length, passedTests: killed ? 0 : selectors.length,
                    failedTests: killed ? 1 : 0, skippedTests: 0, testFailures: killed ? [{failureText: `failed - ${witnesses[0].marker}`}] : []}),
                tree: await artifact(`${label}/tree.json`, tree)}};
    };
    report.baselineBefore = [];
    report.baselineAfter = [];
    for (const group of groupedWitnesses(mutants)) {
        report.baselineBefore.push(await execution(group.family, group.witnesses, `before/${group.family}`));
        report.baselineAfter.push(await execution(group.family, group.witnesses, `after/${group.family}`));
    }
    report.mutants = [];
    for (const mutant of mutants) {
        report.mutants.push({id: mutant.id, status: "killed",
            patch: await artifact(`${mutant.id}/patch.json`, applyMutation(sourceTexts.get(mutant.source), mutant).patch),
            restoration: await artifact(`${mutant.id}/restoration.json`, sourceManifest),
            execution: await execution(mutant.family, [mutant.witness], mutant.id, true)});
    }
    report.finalRestoration = await artifact("final-restoration.json", sourceManifest);
    const path = join(root, "mutation-report.json");
    const save = () => writeFile(path, JSON.stringify(report));
    await save();
    return {root, report, path, save, policy: {tier: "core", runId: report.runId, sourceSHA256: sourceArtifact.sha256, signing: "local"}};
}

test("complete retained evidence independently proves all six semantic kills", async t => {
    const value = await fixture(t);
    const result = await auditMutationEvidence(value.path, value.policy);
    assert.deepEqual(result, {ok: true, issues: [], mutationCounts: {killed: 6}});
    assert.equal(Object.hasOwn(result, "counts"), false);
});

test("evidence audit rejects missing or modified artifact bytes and source identity drift", async t => {
    const value = await fixture(t);
    assert.equal((await auditMutationEvidence(value.path, {...value.policy, sourceSHA256: "f".repeat(64)})).ok, false);
    await writeFile(join(value.root, value.report.mutants[0].execution.test.log.path), "tampered");
    const changed = await auditMutationEvidence(value.path, value.policy);
    assert.equal(changed.ok, false);
    assert.equal(changed.mutationCounts["invalid-evidence"], 1);
    await rm(join(value.root, value.report.mutants[1].patch.path));
    assert.equal((await auditMutationEvidence(value.path, value.policy)).ok, false);
});

test("evidence audit rejects changed signing witnesses commands and matrix omissions", async t => {
    const value = await fixture(t);
    const first = value.report.mutants[0];
    first.execution.test.argv.push("-skip-testing:WalletAuthorityTests");
    await value.save();
    let result = await auditMutationEvidence(value.path, value.policy);
    assert.equal(result.ok, false);
    assert.equal(result.mutationCounts["invalid-evidence"], 1);
    first.execution.test.argv.pop();
    first.execution.build.argv.push("-derivedDataPath", "/tmp/unsafe");
    await value.save();
    assert.equal((await auditMutationEvidence(value.path, value.policy)).ok, false);
    first.execution.build.argv.splice(-2);
    value.report.mutants.pop();
    await value.save();
    result = await auditMutationEvidence(value.path, value.policy);
    assert.ok(result.issues.some(issue => issue.includes("omitted selected mutants")));
    assert.equal((await auditMutationEvidence(value.path, {...value.policy, signing: "apple"})).ok, false);
});

test("evidence audit recounts compilation failure instead of trusting a recorded kill", async t => {
    const value = await fixture(t);
    value.report.mutants[0].execution.build.outcome.code = 65;
    await value.save();
    const result = await auditMutationEvidence(value.path, value.policy);
    assert.equal(result.ok, false);
    assert.equal(result.mutationCounts["compile-failure"], 1);
    assert.equal(result.mutationCounts.killed, 5);
    assert.ok(result.issues.some(issue => issue.includes("classification disagrees")));
});

test("a missing restored baseline or XCTest bundle cannot be called success", async t => {
    const value = await fixture(t);
    await rm(join(value.root, value.report.baselineAfter[0].test.resultBundle), {recursive: true});
    assert.equal((await auditMutationEvidence(value.path, value.policy)).ok, false);
    value.report.baselineAfter = [];
    await value.save();
    const result = await auditMutationEvidence(value.path, value.policy);
    assert.ok(result.issues.some(issue => issue.includes("Incomplete baselineAfter")));
    assert.equal(result.mutationCounts.killed, 6);
});

test("incremental mutation and restored baseline logs use only pristine family pins", async t => {
    const value = await fixture(t);
    for (const execution of [...value.report.mutants.map(mutant => mutant.execution), ...value.report.baselineAfter]) {
        const bytes = Buffer.from("** TEST BUILD SUCCEEDED **\n");
        await writeFile(join(value.root, execution.build.log.path), bytes);
        execution.build.log.sha256 = sha256(bytes);
        execution.build.log.bytes = bytes.length;
        execution.build.testPlan.locationSource = "pinned";
    }
    await value.save();
    assert.equal((await auditMutationEvidence(value.path, value.policy)).ok, true);
    const execution = value.report.mutants[0].execution;
    const bytes = Buffer.from(`Build description path: ${value.report.derivedDataDirectory}/Other/Build/Intermediates.noindex/XCBuildData/changed.xcbuilddata\n`);
    await writeFile(join(value.root, execution.build.log.path), bytes);
    execution.build.log.sha256 = sha256(bytes);
    execution.build.log.bytes = bytes.length;
    execution.build.testPlan.locationSource = "emitted";
    await value.save();
    const changed = await auditMutationEvidence(value.path, value.policy);
    assert.equal(changed.ok, false);
    assert.equal(changed.mutationCounts["invalid-evidence"], 1);
    assert.equal(changed.mutationCounts.killed, 5);
});

test("partial campaigns count every selected mutant despite an incomplete restored baseline", async t => {
    const value = await fixture(t);
    value.report.baselineAfter = [];
    value.report.status = "failed";
    delete value.report.mutants[0].execution;
    value.report.mutants.splice(1, 1);
    await value.save();
    const result = await auditMutationEvidence(value.path, value.policy);
    assert.equal(result.ok, false);
    assert.equal(result.mutationCounts["invalid-evidence"], 2);
    assert.equal(result.mutationCounts.killed, 4);
    assert.equal(Object.values(result.mutationCounts).reduce((sum, count) => sum + count, 0), 6);
    assert.ok(result.issues.some(issue => issue.includes("Incomplete baselineAfter")));
    assert.ok(result.issues.some(issue => issue.includes("omitted selected mutants")));
});

test("missing pristine family evidence cannot turn later assertions into proven kills", async t => {
    const value = await fixture(t);
    value.report.baselineBefore = value.report.baselineBefore.filter(execution => execution.family !== "runtime");
    await value.save();
    const result = await auditMutationEvidence(value.path, value.policy);
    assert.equal(result.ok, false);
    assert.equal(result.mutationCounts["invalid-evidence"], 5);
    assert.equal(result.mutationCounts.killed, 1);
});

test("recomputed raw plist hashes cannot conceal different run-plan or product metadata", async t => {
    for (const kind of ["plan", "info"]) {
        const value = await fixture(t);
        const execution = value.report.mutants[0].execution;
        const descriptor = kind === "plan" ? execution.build.testPlan : execution.build.productInfo[0];
        const path = join(value.root, descriptor.source.path);
        const changed = JSON.parse(await readFile(path, "utf8"));
        if (kind === "plan") { changed.TestConfigurations[0].TestTargets[0].TestBundlePath = "__TESTROOT__/Debug/Other.xctest"; }
        else { changed.CFBundleExecutable = "OtherExecutable"; }
        const bytes = Buffer.from(JSON.stringify(changed));
        await writeFile(path, bytes);
        descriptor.source.sha256 = sha256(bytes);
        descriptor.source.bytes = bytes.length;
        descriptor.afterSHA256 = descriptor.source.sha256;
        await value.save();
        const result = await auditMutationEvidence(value.path, value.policy);
        assert.equal(result.ok, false, kind);
        assert.equal(result.mutationCounts["invalid-evidence"], 1, kind);
        assert.equal(result.mutationCounts.killed, 5, kind);
    }
});
