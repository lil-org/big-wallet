import assert from "node:assert/strict";
import {chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from "node:fs";
import {mkdtemp, mkdir, realpath, rm} from "node:fs/promises";
import {spawnSync} from "node:child_process";
import {tmpdir} from "node:os";
import {join} from "node:path";
import test from "node:test";
import {auditConsumerReport, auditUpgradeResult} from "../../wallet_upgrade/audit.mjs";
import {ARCHIVE_SHA256, BASELINE, FAILURE_CASES, FIXTURE_ID, PHASES} from "../../wallet_upgrade/contract.mjs";
import {assertIsolatedProducerSymbols, parseOptions} from "../../wallet_upgrade/run.mjs";
import {auditResults} from "../result_audit.mjs";
import {createManifest, BOOTSTRAP_TOOL_NAMES} from "../test_manifest.mjs";
import {executeStages, pendingStageResults} from "../guest.mjs";
import {atomicJSON, hashFile} from "../guest_bootstrap.mjs";

const hash = value => value.repeat(64);
const pair = (a, b) => ({keychainSHA256: hash(a), preferencesSHA256: hash(b)});
const empty = {keychainSHA256: null, preferencesSHA256: null};
const policy = {configuration: "Debug", baseline: BASELINE, sourceSHA256: hash("9")};
const context = {runId: "upgrade-fixture", sourceSHA256: hash("9")};

function reportFixture() {
    const original = pair("a", "b"), mutated = pair("c", "d"), restored = pair("e", "f");
    const snapshots = [[original, original], [original, mutated], [mutated, mutated], [empty, restored], [restored, restored], [empty, empty]];
    return {version: 1, status: "passed", runId: context.runId, configuration: "Debug", fixtureID: FIXTURE_ID, baseline: BASELINE,
        sourceIdentity: {version: 1, source: {kind: "vm-snapshot", sha256: context.sourceSHA256, commit: "c".repeat(40), fileCount: 100}, worker: {sha256: hash("1"), bytes: 1000}},
        provenance: {archiveSHA256: ARCHIVE_SHA256, manifestSHA256: hash("2"), driverSHA256: hash("3"), adaptersSHA256: hash("4"),
            producerBinary: {sha256: hash("5"), bytes: 1000}, archivedFileCount: 95, archivedSwiftCount: 30, archivedCUnitCount: 5,
            commitTreeProofVerified: true, producerExitCode: 0, producerProcessID: 100, undefinedSecurityStorageSymbols: [],
            undefinedSymbolsAuditExitCode: 0, undefinedSymbolsSHA256: hash("6"), swiftVersion: "Swift fixture", clangVersion: "Clang fixture",
            commands: Array.from({length: 8}, (_, index) => ({argv: ["fixture-command", String(index)], exitCode: 0, processID: index + 10}))},
        fixture: {...original, expectationsSHA256: hash("7"), walletCount: 3, accountCount: 4, networkCount: 1}, fixtureAfter: original,
        phases: PHASES.map((phase, index) => ({version: 1, status: "passed", mode: phase.mode, fixtureID: FIXTURE_ID, baseline: BASELINE,
            processID: 101 + index, checks: [...phase.checks], counts: {...phase.counts}, networkAttempts: 0,
            keychainWrites: phase.mode === "restore" ? 5 : phase.mode === "mutate-existing" ? 1 : 0,
            preferenceWrites: phase.mode === "mutate-existing" ? 1 : 0,
            storage: {before: snapshots[index][0], after: snapshots[index][1]},
            ...(phase.mode === "failures" ? {failureCases: FAILURE_CASES.map(name => ({name, rejected: true, before: original, after: original,
                keychainWrites: 0, preferenceWrites: 0}))} : {})})),
    };
}

test("complete historical-state, reopen, restore, and failure evidence passes", () => {
    const audit = auditUpgradeResult(reportFixture(), policy, context);
    assert.equal(audit.ok, true, audit.issues.join("\n"));
    assert.equal(audit.phaseCount, 6);
    assert.deepEqual(audit.counts, {total: 10, passed: 10, failed: 0, skipped: 0});
});

for (const [name, mutate] of [
    ["incomplete phases", value => value.phases.pop()],
    ["reordered phases", value => value.phases.reverse()],
    ["duplicate process", value => { value.phases[1].processID = value.phases[0].processID; }],
    ["producer process reused", value => { value.phases[0].processID = value.provenance.producerProcessID; }],
    ["missing check", value => value.phases[0].checks.pop()],
    ["duplicate check", value => { value.phases[0].checks[1] = value.phases[0].checks[0]; }],
    ["missing signature", value => { value.phases[0].counts.approvedSignatures = 3; }],
    ["network request", value => { value.phases[4].networkAttempts = 1; }],
    ["verification write", value => { value.phases[0].keychainWrites = 1; }],
    ["unbound source", value => { value.sourceIdentity.source.sha256 = hash("8"); }],
    ["different release", value => { value.baseline = {...BASELINE, buildVersion: "148"}; }],
    ["different archive", value => { value.provenance.archiveSHA256 = hash("8"); }],
    ["missing Git proof", value => { delete value.provenance.commitTreeProofVerified; }],
    ["live Keychain symbol", value => { value.provenance.undefinedSecurityStorageSymbols = ["_SecItemAdd"]; }],
    ["malformed symbol audit", value => { value.provenance.undefinedSecurityStorageSymbols = ""; }],
    ["failed symbol audit", value => { value.provenance.undefinedSymbolsAuditExitCode = 1; }],
    ["missing compiler provenance", value => { value.provenance.commands = []; }],
    ["changed original fixture", value => { value.fixtureAfter = pair("1", "2"); }],
    ["rewritten initial state", value => { value.phases[0].storage = {before: pair("1", "2"), after: pair("1", "2")}; }],
    ["unpersisted mutation", value => { value.phases[1].keychainWrites = 0; }],
    ["different reopen state", value => { value.phases[2].storage = {before: pair("1", "2"), after: pair("1", "2")}; }],
    ["nonempty restore destination", value => { value.phases[3].storage.before = pair("1", "2"); }],
    ["missing negative case", value => value.phases[5].failureCases.pop()],
    ["negative case changed data", value => { value.phases[5].failureCases[0].after = pair("1", "2"); }],
    ["negative case succeeded", value => { value.phases[5].failureCases[0].rejected = false; }],
]) {
    test(`upgrade auditor rejects ${name}`, () => {
        const report = structuredClone(reportFixture()); mutate(report);
        assert.equal(auditUpgradeResult(report, policy, context).ok, false);
    });
}

test("missing, partial, and wrong-configuration reports cannot pass", () => {
    for (const value of [null, {}, {version: 1}, {...reportFixture(), status: "running"}]) {
        assert.equal(auditUpgradeResult(value, policy, context).ok, false);
    }
    assert.equal(auditUpgradeResult(reportFixture(), {...policy, configuration: "Release"}, context).ok, false);
    assert.equal(auditUpgradeResult(reportFixture(), policy, {...context, runId: "another-run"}).ok, false);
    assert.equal(auditConsumerReport(null, PHASES[0], pair("a", "b")).ok, false);
    assert.match(auditUpgradeResult({version: 1, status: "failed", error: "Historical compiler failed"}, policy, context).issues[0], /Historical compiler failed/);
    assert.equal(auditResults([{id: "upgrade.debug", status: "passed", upgradeAudit: policy}]).status, "failed");
});

test("producer symbol audit rejects all Security storage entry points", () => {
    assert.deepEqual(assertIsolatedProducerSymbols("_SecRandomCopyBytes\n_swift_release\n"), []);
    for (const symbol of ["_SecItemCopyMatching", "_SecItemAdd", "_SecItemUpdate", "_SecItemDelete", "SecItemCopyMatching", "__SecItemUnknown"]) {
        assert.throws(() => assertIsolatedProducerSymbols(`_swift_release\n ${symbol}\n`), /Keychain/);
    }
    assert.throws(() => assertIsolatedProducerSymbols(null));
});

test("upgrade arguments accept only bounded configuration and VM-owned paths", () => {
    const args = ["--configuration", "Release", "--failure-dir", "/fixture/results with spaces", "--scratch-dir", "/fixture/scratch"];
    assert.equal(parseOptions(args).configuration, "Release");
    for (const invalid of [[], [...args, "--configuration", "Debug"], [...args, "--worker", "/bin/sh"],
        ["--configuration", "Debug", "--failure-dir", "relative", "--scratch-dir", "/scratch"],
        ["--configuration", "Debug", "--failure-dir", "/same", "--scratch-dir", "/same"]]) { assert.throws(() => parseOptions(invalid)); }
});

const job = payload => ({version: 1, runId: context.runId, vmId: "fixture-vm", kind: "run", profile: "all",
    source: {sha256: context.sourceSHA256, commit: "c".repeat(40)},
    bootstrapTools: Object.fromEntries(BOOTSTRAP_TOOL_NAMES.map(name => [name, hash("1")])),
    payload: {stages: [], onlyTesting: [], ...payload}});

test("full and selected manifests require both upgrade audits without Safari or signing prerequisites", () => {
    for (const payload of [{}, {stages: ["upgrade"]}]) {
        const manifest = createManifest(job(payload));
        const phases = manifest.filter(stage => stage.group === "upgrade");
        assert.deepEqual(phases.map(stage => stage.id), ["upgrade.debug", "upgrade.release"]);
        for (const phase of phases) {
            assert.deepEqual(phase.upgradeAudit.baseline, BASELINE);
            assert.equal(phase.upgradeAudit.sourceSHA256, context.sourceSHA256);
            assert.ok(phase.failureDirectory && phase.scratchDirectory);
            assert.ok(!phase.requirements.includes("signing") && !phase.requirements.includes("proofKey") && !phase.requirements.includes("safariAutomation"));
        }
        assert.ok(pendingStageResults(manifest).filter(stage => stage.upgradeAudit).length === 2);
    }
    assert.deepEqual(createManifest(job({stages: ["upgrade"], configuration: "Release"})).filter(stage => stage.group === "upgrade").map(stage => stage.id), ["upgrade.release"]);
});

test("guest stage rejects a zero-exit consumer with missing evidence and audits complete evidence", async () => {
    const root = await realpath(await mkdtemp(join(tmpdir(), "wallet-upgrade-stage-")));
    try {
        for (const complete of [false, true]) {
            const artifacts = join(root, String(complete));
            await mkdir(artifacts);
            const stage = {id: "upgrade.debug", group: "upgrade", command: "fixture", args: [], cwd: ".", dependencies: [], requirements: [],
                upgradeAudit: policy, timeoutSeconds: 60};
            if (complete) { await atomicJSON(join(artifacts, "failures/upgrade.debug/upgrade-report.json"), reportFixture()); }
            const result = await executeStages([stage], {workspace: root, artifacts, preflight: {checks: {}, destinations: {}},
                runId: context.runId, writeJSON: atomicJSON, hashFile,
                execute: async () => ({code: 0, signal: null, timedOut: false, cancelled: false, output: ""})});
            assert.equal(result[0].status, complete ? "passed" : "failed");
            assert.equal(result[0].audit?.ok, complete ? true : undefined);
        }
    } finally { await rm(root, {recursive: true, force: true}); }
});

function routingFixture(operation) {
    const root = mkdtempSync(join(tmpdir(), "wallet-upgrade-routing-"));
    try {
        const scripts = join(root, "Scripts");
        mkdirSync(join(scripts, "vm"), {recursive: true});
        const wrapper = join(scripts, "check_wallet_upgrade.sh");
        writeFileSync(wrapper, readFileSync(new URL("../../check_wallet_upgrade.sh", import.meta.url)));
        writeFileSync(join(scripts, "vm/guest_session.sh"), 'test_vm_is_virtual_mac() { [ "$FIXTURE_ROLE" = guest ]; }\ntest_vm_require_guest_session() { return 1; }\n');
        const runner = join(scripts, "test_vm.sh");
        writeFileSync(runner, '#!/bin/sh\nprintf "%s\\0" "$@"\nexit 27\n');
        chmodSync(runner, 0o755);
        operation((args = [], changes = {}) => spawnSync("/bin/sh", [wrapper, ...args], {encoding: "utf8", timeout: 10000,
            env: {PATH: "/usr/bin:/bin", FIXTURE_ROLE: "host", ...changes}}));
    } finally { rmSync(root, {recursive: true, force: true}); }
}

test("host wrapper routes to the VM and unverified guests cannot execute native work", () => routingFixture(run => {
    const result = run([], {UPGRADE_CONFIGURATION: "Release"});
    assert.equal(result.status, 27);
    assert.deepEqual(result.stdout.split("\0").filter(Boolean), ["run", "all", "--stage", "upgrade", "--configuration", "Release"]);
    assert.equal(run([], {FIXTURE_ROLE: "guest"}).status, 2);
    assert.equal(run(["--scratch-dir", "/tmp/override"]).status, 2);
}));
