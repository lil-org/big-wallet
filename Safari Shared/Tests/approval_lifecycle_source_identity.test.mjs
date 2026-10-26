import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {mkdir, mkdtemp, readFile, realpath, rename, rm, symlink, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import test from "node:test";
import {captureSourceIdentity, validateSourceIdentity} from "../../Scripts/approval_lifecycle/source_identity.mjs";

const hash = value => createHash("sha256").update(value).digest("hex");

async function fixture(t) {
    const root = await realpath(await mkdtemp(join(tmpdir(), "approval-source-identity-")));
    t.after(() => rm(root, {recursive: true, force: true}));
    const exchange = join(root, "exchange");
    const workspace = join(root, "workspace");
    await Promise.all([mkdir(exchange), mkdir(workspace)]);
    const worker = join(workspace, "ApprovalCrashWorker");
    await writeFile(worker, "first worker bytes\n");
    const environment = {BW_TEST_VM_RUN_ID: "run-fixture", BW_TEST_VM_EXCHANGE: exchange};
    const manifest = {version: 1, files: [{path: "source.swift", type: "file", mode: 0o644, sha256: hash("source\n")}]};
    const job = {version: 1, kind: "run", runId: environment.BW_TEST_VM_RUN_ID, vmId: "vm-fixture", profile: "all", payload: {},
        bootstrapTools: Object.fromEntries(["VMGuestAgent", "guest_runner", "guest_bootstrap.mjs"].map(name => [name, "a".repeat(64)]))};
    const publish = async () => {
        const contents = JSON.stringify(manifest, null, 2) + "\n";
        job.source = {sha256: hash(contents), commit: "b".repeat(40), fileCount: manifest.files.length, bytes: 7};
        await Promise.all([
            writeFile(join(exchange, "job.json"), JSON.stringify(job)),
            writeFile(join(exchange, "snapshot-manifest.json"), contents),
            writeFile(join(workspace, ".big-wallet-vm-workspace.json"), JSON.stringify({version: 1, runId: job.runId, vmId: job.vmId, source: job.source})),
        ]);
    };
    await publish();
    const options = {environment, workspace, exchange};
    return {root, exchange, workspace, worker, environment, manifest, job, publish, options,
        capture: () => captureSourceIdentity(worker, options)};
}

test("source identity is deterministic and separates the source snapshot from actual worker bytes", async t => {
    const value = await fixture(t);
    const first = await value.capture();
    assert.deepEqual(await value.capture(), first);
    assert.deepEqual(first.source, {kind: "vm-snapshot", ...Object.fromEntries(["sha256", "commit", "fileCount"].map(key => [key, value.job.source[key]]))});
    assert.deepEqual(first.worker, {sha256: hash("first worker bytes\n"), bytes: Buffer.byteLength("first worker bytes\n")});
    assert.equal(validateSourceIdentity(first), first);
    assert.equal(JSON.stringify(first).includes(value.root), false);
    await writeFile(value.worker, "second worker bytes\n");
    const rebuilt = await value.capture();
    assert.deepEqual(rebuilt.source, first.source);
    assert.notEqual(rebuilt.worker.sha256, first.worker.sha256);
    value.manifest.files[0].sha256 = hash("changed source\n");
    await value.publish();
    const changed = await value.capture();
    assert.notEqual(changed.source.sha256, first.source.sha256);
    assert.deepEqual(changed.worker, rebuilt.worker);
});

test("worker identity follows build-directory symlinks and hashes the resolved executable", async t => {
    const value = await fixture(t);
    const alias = join(value.workspace, "debug");
    const binaryDirectory = join(value.workspace, "arm64-apple-macosx-debug");
    await mkdir(binaryDirectory);
    await rename(value.worker, join(binaryDirectory, "ApprovalCrashWorker"));
    await symlink(binaryDirectory, alias);
    const identity = await captureSourceIdentity(join(alias, "ApprovalCrashWorker"), value.options);
    assert.equal(identity.worker.sha256, hash("first worker bytes\n"));
});

for (const change of ["environment", "job", "workspace-run", "workspace-vm", "workspace-source", "manifest", "inventory"]) {
    test(`source identity rejects stale or mismatched ${change}`, async t => {
        const value = await fixture(t);
        if (change === "environment") { value.environment.BW_TEST_VM_RUN_ID = "run-other"; }
        if (change === "job") {
            value.job.kind = "doctor";
            await writeFile(join(value.exchange, "job.json"), JSON.stringify(value.job));
        }
        if (change.startsWith("workspace-")) {
            const path = join(value.workspace, ".big-wallet-vm-workspace.json");
            const marker = JSON.parse(await readFile(path, "utf8"));
            if (change === "workspace-run") { marker.runId = "run-other"; }
            if (change === "workspace-vm") { marker.vmId = "vm-other"; }
            if (change === "workspace-source") { marker.source.sha256 = "c".repeat(64); }
            await writeFile(path, JSON.stringify(marker));
        }
        if (change === "manifest") { await writeFile(join(value.exchange, "snapshot-manifest.json"), "{}"); }
        if (change === "inventory") {
            value.job.source.fileCount += 1;
            await writeFile(join(value.exchange, "job.json"), JSON.stringify(value.job));
            await writeFile(join(value.workspace, ".big-wallet-vm-workspace.json"), JSON.stringify({version: 1,
                runId: value.job.runId, vmId: value.job.vmId, source: value.job.source}));
        }
        await assert.rejects(value.capture(), /Approval source/);
    });
}

test("production capture requires the fixed guest exchange and a current run identity", async t => {
    const value = await fixture(t);
    await assert.rejects(captureSourceIdentity(value.worker, {environment: value.environment, workspace: value.workspace}), /current VM job/);
    for (const runId of [undefined, "", "../escape", "run..stale"]) {
        await assert.rejects(captureSourceIdentity(value.worker, {...value.options,
            environment: {...value.environment, BW_TEST_VM_RUN_ID: runId}}), /current VM job/);
    }
});

for (const name of ["job.json", "snapshot-manifest.json", ".big-wallet-vm-workspace.json"]) {
    test(`source identity rejects a symlinked ${name}`, async t => {
        const value = await fixture(t);
        const directory = name.startsWith(".") ? value.workspace : value.exchange;
        const path = join(directory, name);
        const target = join(directory, `${name}.target`);
        await rename(path, target);
        await symlink(target, path);
        await assert.rejects(value.capture());
    });
}

test("source identity rejects malformed hashes, inventories, versions, and unexpected fields", async t => {
    const identity = await (await fixture(t)).capture();
    const changes = [
        value => { value.version = 2; },
        value => { value.source.kind = "git"; },
        value => { value.source.sha256 = "A".repeat(64); },
        value => { value.source.commit = "b".repeat(41); },
        value => { value.source.fileCount = 0; },
        value => { value.source.fileCount = 1.5; },
        value => { value.worker.sha256 = "invalid"; },
        value => { value.worker.bytes = 0; },
        value => { value.worker.bytes = Number.MAX_SAFE_INTEGER + 1; },
        value => { value.path = "/unrecorded/path"; },
    ];
    for (const change of changes) {
        const invalid = structuredClone(identity);
        change(invalid);
        assert.throws(() => validateSourceIdentity(invalid), /Invalid approval source identity/);
    }
});
