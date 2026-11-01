import assert from "node:assert/strict";
import {mkdtemp, mkdir, realpath, rm} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import test from "node:test";
import {BOOTSTRAP_TOOL_NAMES, commandForStage, createManifest, validateJob} from "../test_manifest.mjs";
import {auditResults} from "../result_audit.mjs";
import {executeStages, HARDENING_TERMINATION_GRACE_MILLISECONDS, pendingStageResults} from "../guest.mjs";
import {atomicJSON, hashFile} from "../guest_bootstrap.mjs";

const job = ({profile = "all", ...payload} = {}) => ({
    version: 1, runId: "hardening-fixture", vmId: "fixture-vm", kind: "run", profile,
    payload: {stages: [], onlyTesting: [], ...payload},
    bootstrapTools: Object.fromEntries(BOOTSTRAP_TOOL_NAMES.map(name => [name, "a".repeat(64)])),
    source: {sha256: "b".repeat(64), commit: "c".repeat(40)},
});
const replay = {path: "/Volumes/BigWalletBuild/Exchange/inputs/parser-fuzz-replay.json", sha256: "d".repeat(64)};

test("native fuzz phases are sequential and audited under both acceptance profiles", () => {
    for (const profile of ["all", "extended"]) {
        const manifest = createManifest(job({profile, stages: ["fuzz"]}));
        const stages = manifest.filter(stage => stage.parserFuzzAudit);
        assert.deepEqual(stages.map(stage => stage.parserFuzzAudit.phase), ["build", "canaries", "parsers", "decrypt"]);
        for (const [index, stage] of stages.entries()) {
            assert.equal(stage.parserFuzzAudit.profile, profile);
            assert.equal(stage.parserFuzzAudit.sourceSHA256, job().source.sha256);
            assert.equal(stage.proofKey, undefined);
            assert.ok(stage.requirements.includes("macos"));
            if (index) { assert.ok(stage.dependencies.includes(stages[index - 1].id)); }
            const command = commandForStage(stage, {destinations: {}, artifacts: "/artifacts"});
            assert.ok(command.args.includes(`/artifacts/failures/${stage.id}/parser-fuzz-report.json`));
            assert.ok(command.args.includes(`/artifacts/failures/${stage.id}`));
            assert.ok(!command.args.some(argument => argument.includes("derivedDataPath")));
        }
        assert.ok(manifest.some(stage => stage.id === "fuzz.default"));
        assert.ok(!manifest.some(stage => stage.mutationAudit));
    }
});

test("native replay runs only native build and replay with a staged bounded artifact", () => {
    const manifest = createManifest(job({stages: ["fuzz"], parserFuzzReplay: replay}));
    const stages = manifest.filter(stage => stage.group === "fuzz");
    assert.deepEqual(stages.map(stage => stage.id), ["fuzz.native.build", "fuzz.native.replay"]);
    assert.ok(stages[1].args.includes(replay.path));
    assert.equal(stages[1].parserFuzzAudit.replaySHA256, replay.sha256);
    for (const payload of [
        {parserFuzzReplay: replay}, {stages: ["test"], parserFuzzReplay: replay},
        {stages: ["fuzz"], parserFuzzReplay: "/tmp/untrusted.json"},
        {stages: ["fuzz"], parserFuzzReplay: {...replay, sha256: "invalid"}},
        {stages: ["fuzz"], parserFuzzReplay: null},
        {stages: ["fuzz"], parserFuzzReplay: replay, onlyTesting: ["Tests macOS"]},
        {stages: ["fuzz", "mutation"], parserFuzzReplay: replay},
    ]) { assert.throws(() => validateJob(job(payload)), /Native parser replay/); }
});

test("native parser selection omits the unchanged wire campaigns without changing its workload", () => {
    for (const profile of ["all", "extended"]) {
        const selected = createManifest(job({profile, stages: ["parser-fuzz"]}));
        const combined = createManifest(job({profile, stages: ["fuzz"]}));
        assert.deepEqual(selected.filter(stage => stage.parserFuzzAudit), combined.filter(stage => stage.parserFuzzAudit));
        assert.ok(selected.filter(stage => stage.group === "fuzz").every(stage => stage.parserFuzzAudit));
    }
    assert.throws(() => createManifest(job({stages: ["parser-fuzz"], onlyTesting: ["Tests macOS"]})), /declared case inventory/);
    assert.deepEqual(createManifest(job({stages: ["parser-fuzz"], parserFuzzReplay: replay})).filter(stage => stage.parserFuzzAudit).map(stage => stage.id),
        ["fuzz.native.build", "fuzz.native.replay"]);
});

test("mutation profiles retain declared witnesses and only request selected signing prerequisites", () => {
    for (const profile of ["all", "extended"]) for (const signing of ["local", "apple"]) {
        const manifest = createManifest(job({profile, stages: ["mutation"], signing}));
        const stages = manifest.filter(stage => stage.mutationAudit);
        assert.equal(stages.length, 1);
        const stage = stages[0];
        assert.deepEqual(stage.mutationAudit, {tier: profile === "all" ? "core" : "extended", signing, sourceSHA256: job().source.sha256});
        assert.equal(stage.requirements.includes("ios"), profile === "extended");
        assert.equal(stage.requirements.includes("signing"), signing === "apple");
        assert.equal(stage.requirements.includes("proofKey"), signing === "apple");
        assert.equal(stage.proofKey === true, signing === "apple");
        const command = commandForStage(stage, {destinations: {macos: "platform=macOS,arch=arm64", ios: "platform=iOS Simulator,id=fixture"},
            artifacts: "/artifacts", scratch: "/workspace-scratch/mutation"});
        assert.ok(command.args.includes("platform=macOS,arch=arm64"));
        assert.ok(command.args.includes("/workspace-scratch/mutation"));
        assert.ok(!command.args.some(argument => argument.includes("derivedDataPath")));
        assert.ok(!manifest.some(candidate => candidate.parserFuzzAudit));
    }
    assert.throws(() => createManifest(job({stages: ["mutation"], onlyTesting: ["WalletAuthenticationTests"]})), /declared witness inventory/);
    assert.ok(!createManifest(job({onlyTesting: ["Tests iOS"]})).some(stage => stage.mutationAudit));
});

test("pending and aggregate results require both new evidence audits", () => {
    const manifest = createManifest(job({stages: ["fuzz", "mutation"]})).filter(stage => stage.parserFuzzAudit || stage.mutationAudit);
    const pending = pendingStageResults(manifest);
    for (let index = 0; index < manifest.length; index++) {
        assert.deepEqual(pending[index].parserFuzzAudit, manifest[index].parserFuzzAudit);
        assert.deepEqual(pending[index].mutationAudit, manifest[index].mutationAudit);
        const passed = {...pending[index], status: "passed", audit: {ok: true}};
        assert.equal(auditResults([passed]).status, "passed");
        assert.equal(auditResults([{...passed, audit: undefined}]).status, "failed");
        assert.equal(auditResults([{...passed, audit: {ok: false}}]).status, "failed");
    }
});

test("a zero process exit cannot pass hardening stages without evidence", async () => {
    const root = await realpath(await mkdtemp(join(tmpdir(), "wallet-hardening-audit-")));
    try {
        const artifacts = join(root, "artifacts");
        await mkdir(artifacts);
        const manifest = createManifest(job({stages: ["fuzz", "mutation"]})).filter(stage => stage.parserFuzzAudit || stage.mutationAudit)
            .map(stage => ({...stage, dependencies: [], requirements: [], scratchDirectory: false}));
        const results = await executeStages(manifest, {workspace: root, artifacts, preflight: {checks: {}, destinations: {macos: "platform=macOS"}},
            execute: async (_command, _args, options) => {
                assert.equal(options.env.BW_TEST_VM_SOURCE_SHA256, job().source.sha256);
                assert.equal(options.terminationGraceMilliseconds, HARDENING_TERMINATION_GRACE_MILLISECONDS);
                assert.ok(options.terminationGraceMilliseconds > 5_000);
                return {code: 0, signal: null, output: "", timedOut: false, cancelled: false};
            }, runId: job().runId, exchange: "/Volumes/BigWalletBuild/Exchange", writeJSON: atomicJSON, hashFile});
        assert.ok(results.every(result => result.status === "failed"));
    } finally { await rm(root, {recursive: true, force: true}); }
});

test("passing evidence cannot override incomplete output drainage or process failure", async () => {
    const root = await realpath(await mkdtemp(join(tmpdir(), "wallet-hardening-output-")));
    try {
        const artifacts = join(root, "artifacts");
        await mkdir(artifacts);
        const stages = createManifest(job({stages: ["fuzz", "mutation"]})).filter(stage => stage.parserFuzzAudit || stage.mutationAudit)
            .map(stage => ({...stage, dependencies: [], requirements: [], scratchDirectory: false}));
        for (const failure of [{outputDrainTimedOut: true}, {code: 1}, {timedOut: true}, {cancelled: true}]) {
            const results = await executeStages(stages, {workspace: root, artifacts, preflight: {checks: {}, destinations: {macos: "platform=macOS"}},
                execute: async () => ({code: 0, signal: null, output: "", timedOut: false, cancelled: false, ...failure}),
                auditParserFuzz: async () => ({ok: true, issues: []}), auditMutation: async () => ({ok: true, issues: []}),
                runId: job().runId, exchange: "/Volumes/BigWalletBuild/Exchange", writeJSON: atomicJSON, hashFile});
            assert.ok(results.every(result => result.status === (failure.cancelled ? "cancelled" : "failed")));
        }
    } finally { await rm(root, {recursive: true, force: true}); }
});
