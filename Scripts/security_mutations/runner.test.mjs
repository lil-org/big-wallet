import assert from "node:assert/strict";
import {chmod, mkdir, mkdtemp, readFile, realpath, rm, writeFile} from "node:fs/promises";
import {join} from "node:path";
import {tmpdir} from "node:os";
import test from "node:test";
import {executeMatrix, verifyWorkspace} from "./run.mjs";
import {sha256} from "./contract.mjs";

function fixture() {
    const calls = [];
    let changed = false;
    const hooks = {
        baseline: async phase => { calls.push(`baseline:${phase}`); assert.equal(changed, false); return [{status: "passed"}]; },
        apply: async mutant => { calls.push(`apply:${mutant.id}`); assert.equal(changed, false); changed = true; return {path: mutant.id}; },
        execute: async mutant => { calls.push(`execute:${mutant.id}`); assert.equal(changed, true); return {status: "killed"}; },
        restore: async mutant => { calls.push(`restore:${mutant.id}`); changed = false; return {path: "restored"}; },
    };
    return {calls, hooks, mutants: [{id: "first"}, {id: "second"}], changed: () => changed};
}

test("matrix reuses one work area serially and proves both pristine baselines", async () => {
    const value = fixture();
    const result = await executeMatrix(value.mutants, value.hooks);
    assert.equal(result.status, "passed");
    assert.deepEqual(value.calls, ["baseline:before", "apply:first", "execute:first", "restore:first", "apply:second", "execute:second", "restore:second", "baseline:after"]);
});

test("failed baseline blocks all mutations", async () => {
    const value = fixture();
    value.hooks.baseline = async () => [{status: "baseline-failed"}];
    const result = await executeMatrix(value.mutants, value.hooks);
    assert.equal(result.status, "failed");
    assert.equal(result.mutants.length, 0);
    assert.deepEqual(value.calls, []);
});

test("compile failure timeout survivor and thrown execution never count as kills or skip restoration", async () => {
    for (const status of ["compile-failure", "timed-out", "survived", "crashed", "invalid-evidence", "throw"]) {
        const value = fixture();
        value.hooks.execute = async () => { if (status === "throw") { throw new Error("executor failed"); } return {status}; };
        const result = await executeMatrix(value.mutants, value.hooks);
        assert.equal(result.status, "failed", status);
        assert.equal(result.mutants.length, 2);
        assert.ok(result.mutants.every(mutant => mutant.status !== "killed"));
        assert.ok(value.calls.includes("baseline:after"));
        assert.equal(value.changed(), false);
    }
});

test("failed restoration stops before another mutant or baseline can run", async () => {
    const value = fixture();
    value.hooks.restore = async () => { throw new Error("cannot restore"); };
    const result = await executeMatrix(value.mutants, value.hooks);
    assert.equal(result.status, "failed");
    assert.equal(result.mutants.length, 1);
    assert.equal(result.mutants[0].status, "restoration-failure");
    assert.equal(value.calls.includes("apply:second"), false);
    assert.equal(value.calls.includes("baseline:after"), false);
});

test("cancellation restores an active mutant and leaves incomplete matrix visibly failed", async () => {
    const value = fixture();
    let stopped = false;
    value.hooks.execute = async () => { stopped = true; return {status: "cancelled"}; };
    const result = await executeMatrix(value.mutants, {...value.hooks, stopped: () => stopped});
    assert.equal(result.status, "cancelled");
    assert.equal(result.mutants.length, 1);
    assert.equal(value.changed(), false);
    assert.equal(result.baselineAfter.length, 0);
});

test("source audit rejects unrelated modifications and unexpected production files", async t => {
    const root = await realpath(await mkdtemp(join(tmpdir(), "mutation-orchestration-")));
    t.after(() => rm(root, {recursive: true, force: true}));
    for (const path of ["Packages/WalletRuntime/Sources", "Packages/WalletRuntime/Tests", "Shared", "App iOS", "App macOS", "Safari Shared", "Tests", "Scripts"]) {
        await mkdir(join(root, path), {recursive: true});
    }
    const path = "Shared/Guard.swift";
    await writeFile(join(root, path), "original", {mode: 0o644});
    await chmod(join(root, path), 0o644);
    const manifest = {version: 1, files: [{path, mode: 0o644, type: "file", sha256: sha256("original")}]};
    await verifyWorkspace(root, manifest);
    await writeFile(join(root, path), "mutated");
    await assert.rejects(verifyWorkspace(root, manifest), /unexpected source/);
    await verifyWorkspace(root, manifest, new Map([[path, sha256("mutated")]]));
    await writeFile(join(root, path), "original");
    await writeFile(join(root, "Shared/Injected.swift"), "injected");
    await assert.rejects(verifyWorkspace(root, manifest), /Unexpected source appeared/);
    assert.equal(await readFile(join(root, path), "utf8"), "original");
    await rm(join(root, "Shared/Injected.swift"));
    await writeFile(join(root, "Packages/WalletRuntime/Tests/Injected.swift"), "injected test");
    await assert.rejects(verifyWorkspace(root, manifest), /Unexpected source appeared/);
    await assert.rejects(verifyWorkspace(root, manifest, new Map(), {deadline: performance.now() - 1}), /finalization deadline/);
});
