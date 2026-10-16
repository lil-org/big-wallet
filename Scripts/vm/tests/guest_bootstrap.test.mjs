import assert from "node:assert/strict";
import {spawnSync} from "node:child_process";
import {createHash} from "node:crypto";
import {mkdir, mkdtemp, readFile, realpath, rm, symlink, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {dirname, join} from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";
import test from "node:test";
import vm from "node:vm";
import {atomicJSON, BOOTSTRAP_TOOL_NAMES, hashFile, materializeSource, regularFile, validateJobEnvelope} from "../guest_bootstrap.mjs";
import {BOOTSTRAP_TOOL_NAMES as MANIFEST_BOOTSTRAP_TOOLS, validateJob} from "../test_manifest.mjs";

const digest = data => createHash("sha256").update(data).digest("hex");
const bootstrapSource = await readFile(new URL("../guest_bootstrap.mjs", import.meta.url), "utf8");
const mainDefinition = bootstrapSource.match(/^export async function main\([^]*?^}/m)[0]
    .replace(/^export /, "").replace("import(pathToFileURL(entry).href)", "loadHarness(pathToFileURL(entry).href)");
const verifyDefinition = bootstrapSource.match(/^export async function verifySession\([^]*?^}/m)[0].replace(/^export /, "");
const job = overrides => ({version: 1, runId: "bootstrap-fixture", vmId: "fixture-vm", kind: "run", profile: "all", stages: [], onlyTesting: [],
    bootstrapTools: Object.fromEntries(BOOTSTRAP_TOOL_NAMES.map(name => [name, "a".repeat(64)])),
    source: {sha256: "b".repeat(64), commit: "c".repeat(40)}, ...overrides});

async function fixture(operation) {
    const root = await realpath(await mkdtemp(join(tmpdir(), "big-wallet-bootstrap-unit-")));
    const exchange = join(root, "exchange");
    const workspace = join(root, "workspace");
    await mkdir(exchange);
    const events = [];
    const globals = {
        process, EXCHANGE_PATH: exchange, realpath, regularFile, validateJobEnvelope, join, mkdir, pathToFileURL,
        verifyExchangeDirectory: async () => { events.push("exchange"); return exchange; },
        verifyGuest: async () => { events.push("identity"); return {vmId: "fixture-vm", consoleUser: "tester"}; },
        bootstrapToolsEvidence: async () => { events.push("bootstrap"); return {available: true}; },
        userInfo: () => ({homedir: root}),
        acquireRunLock: async () => { events.push("lock"); return async () => { events.push("release"); }; },
        readGuestProvision: async () => { events.push("provision"); return {workspacePath: workspace}; },
        verifyBuildVolume: async () => { events.push("volume"); return {vmId: "fixture-vm"}; },
        materializeSource: async (...args) => { events.push("materialize"); return materializeSource(...args); },
        atomicJSON, hashFile,
        loadHarness: async url => { events.push("import"); return import(url); },
    };
    const stage = async files => {
        const entries = [];
        let bytes = 0;
        for (const [name, value] of Object.entries(files)) {
            const filename = join(exchange, "source", name);
            await mkdir(dirname(filename), {recursive: true});
            if (typeof value === "string") {
                await writeFile(filename, value);
                bytes += Buffer.byteLength(value);
                entries.push({path: name, type: "file", mode: 0o644, sha256: digest(value)});
            } else {
                await symlink(value.target, filename);
                entries.push({path: name, type: "symlink", target: value.target, mode: 0o777, sha256: digest(value.target)});
            }
        }
        await atomicJSON(join(exchange, "snapshot-manifest.json"), {version: 1, files: entries});
        const selected = job({source: {sha256: await hashFile(join(exchange, "snapshot-manifest.json")), commit: "c".repeat(40), fileCount: entries.length, bytes}});
        await atomicJSON(join(exchange, "job.json"), selected);
        return selected;
    };
    const run = overrides => vm.runInNewContext(`(${mainDefinition})`, {...globals, ...overrides})(["--exchange", exchange]);
    try { await operation({root, exchange, workspace, events, globals, stage, run}); }
    finally { await rm(root, {recursive: true, force: true}); }
}

const harness = `import {selected} from "./test_manifest.mjs";
import {result} from "./result_audit.mjs";
export async function runJob(context) {
    return {runId: context.job.runId, status: "passed", selected, result, source: context.source.sha256, entry: "snapshot"};
}`;
const sources = {
    "Scripts/vm/guest.mjs": harness,
    "Scripts/vm/test_manifest.mjs": 'export const selected = "current manifest";',
    "Scripts/vm/result_audit.mjs": 'export const result = "current audit";',
};

test("bootstrap and manifest agree on the installed boundary without installing harness modules", () => {
    assert.deepEqual(BOOTSTRAP_TOOL_NAMES, ["VMGuestAgent", "guest_runner", "guest_bootstrap.mjs"]);
    assert.deepEqual(MANIFEST_BOOTSTRAP_TOOLS, BOOTSTRAP_TOOL_NAMES);
    assert.deepEqual(validateJobEnvelope(job()), validateJob(job()));
    for (const invalid of [{source: undefined}, {bootstrapTools: {}}, {kind: "prepare"}, {runId: "../escape"}, {vmId: ""}, {entry: "/tmp/other.mjs"}]) {
        assert.throws(() => validateJobEnvelope(job(invalid)));
    }
    assert.doesNotMatch(bootstrapSource, /^import .* from ["'](?!node:)/m);
});

test("the installed bootstrap executes the current verified snapshot after every guard and holds its lock", async () => fixture(async ({events, stage, run}) => {
    const selected = await stage(sources);
    const report = await run();
    assert.equal(report.entry, "snapshot");
    assert.equal(report.selected, "current manifest");
    assert.equal(report.result, "current audit");
    assert.equal(report.source, selected.source.sha256);
    assert.deepEqual(events, ["exchange", "identity", "bootstrap", "lock", "provision", "volume", "materialize", "import", "release"]);
}));

for (const filename of ["guest.mjs", "test_manifest.mjs", "result_audit.mjs"]) {
    test(`a changed ${filename} executes from the snapshot without an installed harness`, async () => fixture(async ({stage, run}) => {
        const files = {...sources};
        const path = `Scripts/vm/${filename}`;
        files[path] = filename === "guest.mjs" ? files[path].replace('entry: "snapshot"', 'entry: "updated snapshot"') :
            filename === "test_manifest.mjs" ? 'export const selected = "updated manifest";' : 'export const result = "updated audit";';
        await stage(files);
        const report = await run();
        assert.equal(filename === "guest.mjs" ? report.entry : filename === "test_manifest.mjs" ? report.selected : report.result,
            filename === "guest.mjs" ? "updated snapshot" : filename === "test_manifest.mjs" ? "updated manifest" : "updated audit");
    }));
}

for (const guard of ["verifyGuest", "bootstrapToolsEvidence", "readGuestProvision", "verifyBuildVolume"]) {
    test(`${guard} fails before importing the snapshot harness`, async () => fixture(async ({exchange, events, stage, run}) => {
        await stage(sources);
        const evidence = {available: false, hashes: {}, missing: ["VMGuestAgent"], mismatched: ["guest_runner"]};
        const failure = guard === "bootstrapToolsEvidence" ? async () => evidence : async () => { throw new Error("fixture guard failed"); };
        if (guard === "verifyGuest") {
            await assert.rejects(run({[guard]: failure}), /guard failed/);
        } else {
            const report = await run({[guard]: failure});
            assert.equal(report.status, "failed");
            assert.match(report.error, guard === "bootstrapToolsEvidence" ? /bootstrap does not match.*run setup/ : /fixture guard failed/);
            if (guard === "bootstrapToolsEvidence") {
                const stored = JSON.parse(await readFile(join(exchange, "artifacts/result.json"), "utf8"));
                assert.deepEqual(stored, JSON.parse(JSON.stringify(report)));
                assert.deepEqual(stored.preflight.bootstrap, evidence);
                assert.equal(stored.preflight.checks.bootstrap, false);
                assert.ok(stored.finishedAt);
                assert.equal(stored.coverage.fullSuiteVerified, false);
                assert.ok(!events.includes("provision"));
            }
        }
        assert.ok(!events.includes("import"));
        assert.ok(!events.includes("materialize"));
        assert.equal(events.includes("release"), events.includes("lock"));
    }));
}

for (const previousStatus of ["running", "passed"]) {
    test(`bootstrap mismatches replace stale evidence in a ${previousStatus} report`, async () => fixture(async ({exchange, events, stage, run}) => {
        const selected = await stage(sources);
        await atomicJSON(join(exchange, "artifacts/result.json"), {
            version: 1, runId: selected.runId, vmId: selected.vmId, kind: selected.kind, source: selected.source,
            status: previousStatus, stages: [], preflight: {checks: {bootstrap: true, node: true}, bootstrap: {available: true}},
            ...(previousStatus === "passed" ? {finishedAt: "previous completion"} : {}),
        });
        const evidence = {available: false, hashes: {}, missing: [], mismatched: ["guest_runner"]};
        const report = await run({bootstrapToolsEvidence: async () => evidence});
        assert.equal(report.status, "failed");
        assert.match(report.error, /bootstrap does not match/);
        assert.deepEqual(report.preflight.bootstrap, evidence);
        assert.equal(report.preflight.checks.bootstrap, false);
        assert.equal(report.preflight.checks.node, true);
        assert.equal(report.coverage.fullSuiteVerified, false);
        assert.ok(!events.includes("materialize"));
        assert.ok(!events.includes("import"));
        assert.equal(events.at(-1), "release");
        assert.deepEqual(JSON.parse(await readFile(join(exchange, "artifacts/result.json"), "utf8")), JSON.parse(JSON.stringify(report)));
    }));
}

test("changed source bytes fail verification before the harness is imported", async () => fixture(async ({exchange, events, stage, run}) => {
    await stage(sources);
    await writeFile(join(exchange, "source/Scripts/vm/guest.mjs"), 'throw new Error("tampered code executed");');
    const report = await run();
    assert.equal(report.status, "failed");
    assert.match(report.error, /Source hash mismatch/);
    assert.equal(report.stages.length, 0);
    assert.equal(report.coverage.fullSuiteVerified, false);
    assert.ok(!events.includes("import"));
    assert.equal(events.at(-1), "release");
}));

test("a symlinked entry is refused even when its target remains inside the verified source", async () => fixture(async ({events, stage, run}) => {
    await stage({...sources, "Scripts/vm/guest.mjs": {target: "harness.mjs"}, "Scripts/vm/harness.mjs": harness});
    const report = await run();
    assert.equal(report.status, "failed");
    assert.match(report.error, /Invalid file|may not traverse symlinks/);
    assert.ok(!events.includes("import"));
    assert.equal(events.at(-1), "release");
}));

test("harness import failures release the lock without publishing a passing result", async () => fixture(async ({events, exchange, stage, run}) => {
    await stage({...sources, "Scripts/vm/guest.mjs": 'throw new Error("fixture import failure");'});
    const report = await run();
    assert.equal(report.status, "failed");
    assert.match(report.error, /fixture import failure/);
    assert.equal(events.at(-1), "release");
    assert.deepEqual(JSON.parse(await readFile(join(exchange, "artifacts/result.json"), "utf8")), JSON.parse(JSON.stringify(report)));
    assert.equal(report.coverage.status, "partial");
    assert.equal(report.coverage.fullSuiteVerified, false);
}));

test("cancellation during materialization publishes a cancelled report without importing the harness", async () => fixture(async ({events, exchange, stage, run}) => {
    const selected = await stage(sources);
    await atomicJSON(join(exchange, "stop.json"), {runId: selected.runId});
    const report = await run();
    assert.equal(report.status, "cancelled");
    assert.match(report.error, /cancelled/);
    assert.equal(report.coverage.fullSuiteVerified, false);
    assert.ok(!events.includes("import"));
    assert.equal(events.at(-1), "release");
}));

for (const cancelled of [false, true]) {
    test(`a harness publication failure preserves completed stages and ${cancelled ? "cancels" : "blocks"} unfinished stages`, async () => fixture(async ({events, exchange, stage, run}) => {
        const failingHarness = `export async function runJob(context) {
            await context.writeJSON(context.artifacts + "/result.json", {
                version: 1, runId: context.job.runId, vmId: context.job.vmId, kind: context.job.kind,
                source: context.source, status: "running", stages: [
                    {id: "repository.passed", status: "passed", finishedAt: "already finished", log: "passed.log"},
                    {id: "repository.failed", status: "failed", reason: "prior failure"},
                    {id: "native.running", status: "running"}, {id: "native.pending", status: "pending"}],
                summary: {issues: ["prior issue"]}, coverage: {status: "partial", fullSuiteVerified: false}
            });
            ${cancelled ? 'await context.writeJSON(context.exchange + "/stop.json", {runId: context.job.runId});' : ''}
            throw new Error("fixture final publication failed");
        }`;
        await stage({...sources, "Scripts/vm/guest.mjs": failingHarness});
        const report = await run();
        assert.equal(report.status, cancelled ? "cancelled" : "failed");
        assert.equal(report.error, "fixture final publication failed");
        assert.deepEqual(JSON.parse(JSON.stringify(report.stages[0])), {id: "repository.passed", status: "passed", finishedAt: "already finished", log: "passed.log"});
        assert.deepEqual(JSON.parse(JSON.stringify(report.stages[1])), {id: "repository.failed", status: "failed", reason: "prior failure"});
        assert.ok(report.stages.slice(2).every(stage => stage.status === (cancelled ? "cancelled" : "blocked")));
        assert.deepEqual(Array.from(report.summary.issues), ["prior issue", "fixture final publication failed"]);
        assert.equal(report.summary.counts.passed, 1);
        assert.equal(report.summary.counts.failed, 1);
        assert.equal(report.summary.counts[cancelled ? "cancelled" : "blocked"], 2);
        assert.equal(report.coverage.status, "partial");
        assert.equal(report.coverage.fullSuiteVerified, false);
        assert.equal(report.coverage.incompleteStages.length, 3);
        assert.equal(events.at(-1), "release");
        assert.deepEqual(JSON.parse(await readFile(join(exchange, "artifacts/result.json"), "utf8")), JSON.parse(JSON.stringify(report)));
    }));
}

test("session verification uses the existing run identity without importing the harness or acquiring its lock", async () => fixture(async ({exchange, stage}) => {
    await stage(sources);
    let verifications = 0;
    const verifySession = vm.runInNewContext(`(${verifyDefinition})`, {
        EXCHANGE_PATH: exchange, verifyExchangeDirectory: async () => exchange, validateJobEnvelope,
        regularFile, join,
    });
    const environment = {BW_TEST_VM_EXCHANGE: exchange, BW_TEST_VM_RUN_ID: job().runId};
    const verify = async vmId => { assert.equal(vmId, job().vmId); verifications++; };
    assert.equal((await verifySession(["--verify-session"], {environment, verify})).status, "passed");
    await assert.rejects(verifySession(["--verify-session"], {environment: {...environment, BW_TEST_VM_RUN_ID: "other"}, verify}), /identity is stale/);
    assert.equal(verifications, 1);
}));

test("direct harness invocations never dispatch a job, including the previous CLI forms", () => {
    for (const args of [[], ["--exchange", "/Volumes/BigWalletBuild/Exchange"], ["--verify-session"]]) {
        const result = spawnSync(process.execPath, [fileURLToPath(new URL("../guest.mjs", import.meta.url)), ...args], {encoding: "utf8", timeout: 10000});
        assert.equal(result.status, 2, result.stderr);
        assert.equal(result.stdout, "");
        assert.match(result.stderr, /Scripts\/test_vm.sh/);
    }
});
