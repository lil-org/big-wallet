import assert from "node:assert/strict";
import {spawn} from "node:child_process";
import {once} from "node:events";
import {chmod, link, lstat, mkdir, mkdtemp, readFile, realpath, rename, rm, symlink, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {isAbsolute, join} from "node:path";
import {setTimeout as delay} from "node:timers/promises";
import test from "node:test";
import vm from "node:vm";
import {acquireRunLock} from "../guest.mjs";

const macOS = {skip: process.platform !== "darwin", timeout: 20000};
const guestURL = new URL("../guest.mjs", import.meta.url).href;

async function fixture(operation) {
    const root = await realpath(await mkdtemp(join(tmpdir(), "big-wallet-guest-lock-")));
    try { await operation(root, join(root, "run.lock")); }
    finally { await rm(root, {recursive: true, force: true}); }
}

test("kernel ownership survives the lockf helper and excludes a concurrent run until release", macOS, async () => fixture(async (root, filename) => {
    const release = await acquireRunLock(filename, "first-run");
    const identity = await lstat(filename);
    try {
        assert.equal(identity.mode & 0o777, 0o600);
        await assert.rejects(acquireRunLock(filename, "contender"), /already active/);
        assert.equal(JSON.parse(await readFile(filename, "utf8")).runId, "first-run");
    } finally { await release(); }
    await release();
    const next = await acquireRunLock(filename, "next-run");
    try {
        assert.equal((await lstat(filename)).ino, identity.ino);
        assert.equal(JSON.parse(await readFile(filename, "utf8")).runId, "next-run");
    } finally { await next(); }
}));

test("owner publication failure releases the descriptor and leaves the same lock immediately reusable", macOS, async () => fixture(async (root, filename) => {
    await assert.rejects(acquireRunLock(filename, "failed-publication", {publishOwner: async file => {
        await file.writeFile("partial owner diagnostics");
        throw Object.assign(new Error("fixture owner publication failed"), {code: "ENOSPC"});
    }}), /owner publication failed/);
    const identity = await lstat(filename);
    const release = await acquireRunLock(filename, "retry");
    try {
        assert.equal((await lstat(filename)).ino, identity.ino);
        assert.equal(JSON.parse(await readFile(filename, "utf8")).runId, "retry");
    } finally { await release(); }
}));

test("prior-boot and reused-PID diagnostics have no ownership authority", macOS, async () => fixture(async (root, filename) => {
    for (const runId of ["interrupted-prior-boot", "same-boot-reused-pid"]) {
        await writeFile(filename, JSON.stringify({version: 1, runId, pid: process.pid}), {mode: 0o600});
        const release = await acquireRunLock(filename, "current-run");
        try { assert.equal(JSON.parse(await readFile(filename, "utf8")).runId, "current-run"); }
        finally { await release(); }
    }
}));

test("release closes only its descriptor when the path has been replaced", macOS, async () => fixture(async (root, filename) => {
    const release = await acquireRunLock(filename, "first-run");
    const original = join(root, "original-lock");
    await rename(filename, original);
    await writeFile(filename, "replacement", {mode: 0o600});
    const current = await acquireRunLock(filename, "replacement-owner");
    try {
        await release();
        assert.equal(JSON.parse(await readFile(filename, "utf8")).runId, "replacement-owner");
        await assert.rejects(acquireRunLock(filename, "contender"), /already active/);
    } finally { await current(); await release(); }
}));

test("unsafe lock files and redirected parents are refused without mutation", async () => {
    for (const kind of ["directory", "symlink", "hardlink", "public-file", "parent-symlink"]) {
        await fixture(async (root, filename) => {
            const unrelated = join(root, "unrelated");
            await writeFile(unrelated, "preserve", {mode: 0o600});
            if (kind === "directory") { await mkdir(filename); await writeFile(join(filename, "unrelated"), "preserve"); }
            if (kind === "symlink") await symlink(unrelated, filename);
            if (kind === "hardlink") await link(unrelated, filename);
            if (kind === "public-file") { await writeFile(filename, "preserve"); await chmod(filename, 0o644); }
            if (kind === "parent-symlink") {
                const external = join(root, "other-directory");
                await mkdir(external);
                await symlink(external, join(root, "redirect"));
                filename = join(root, "redirect", "run.lock");
            }
            await assert.rejects(acquireRunLock(filename, "unsafe"), /private owned regular file|directory is not protected/, kind);
            assert.equal(await readFile(unrelated, "utf8"), "preserve");
            if (kind === "directory") assert.equal(await readFile(join(filename, "unrelated"), "utf8"), "preserve");
        });
    }
});

async function waitForFile(filename, timeout = 3000) {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
        try { return await readFile(filename, "utf8"); }
        catch (error) { if (error.code !== "ENOENT") throw error; }
        await delay(10);
    }
    throw new Error(`Fixture file did not appear: ${filename}`);
}

test("owner process exit releases the lock while its stage subprocess is still alive", macOS, async () => fixture(async (root, filename) => {
    const ready = join(root, "stage-ready");
    const stop = join(root, "stage-stop");
    const finished = join(root, "stage-finished");
    const stage = `
        const fs = require('node:fs');
        fs.writeFileSync(${JSON.stringify(ready)}, 'ready');
        const finish = () => { fs.writeFileSync(${JSON.stringify(finished)}, 'finished'); process.exit(0); };
        setInterval(() => { if (fs.existsSync(${JSON.stringify(stop)})) finish(); }, 10);
        setTimeout(finish, 10000);
    `;
    const program = `
        import {spawn} from 'node:child_process';
        import {acquireRunLock} from ${JSON.stringify(guestURL)};
        globalThis.release = await acquireRunLock(${JSON.stringify(filename)}, 'fixture-owner');
        const child = spawn(process.execPath, ['-e', ${JSON.stringify(stage)}], {stdio: 'ignore'});
        child.unref();
        process.stdout.write('locked\\n');
        process.stdin.once('data', () => process.exit(0));
        process.stdin.once('end', () => process.exit(0));
    `;
    const child = spawn(process.execPath, ["--input-type=module", "-e", program], {stdio: ["pipe", "pipe", "pipe"]});
    const exited = once(child, "exit");
    let stderr = "";
    child.stderr.on("data", chunk => { stderr += chunk; });
    try {
        const [data] = await Promise.race([once(child.stdout, "data"), exited.then(() => { throw new Error(stderr || "Fixture owner exited before acquisition"); })]);
        assert.equal(data.toString(), "locked\n", stderr);
        await waitForFile(ready);
        await assert.rejects(acquireRunLock(filename, "concurrent"), /already active/);
        child.stdin.end("exit\n");
        assert.deepEqual(await exited, [0, null], stderr);
        assert.equal(await lstat(finished).then(() => true, () => false), false);
        const release = await acquireRunLock(filename, "after-process-exit");
        await release();
    } finally {
        child.stdin.end();
        await writeFile(stop, "stop");
        await exited;
        await waitForFile(finished, 11000);
    }
}));

test("failure publishing the final report still releases the guest lock", macOS, async () => fixture(async root => {
    const exchange = join(root, "exchange");
    await mkdir(exchange);
    await writeFile(join(exchange, "job.json"), JSON.stringify({runId: "report-failure", vmId: "fixture", kind: "doctor", profile: "all"}));
    const definition = (await readFile(new URL("../guest.mjs", import.meta.url), "utf8"))
        .match(/^export async function main\([^]*?^}/m)[0].replace(/^export /, "");
    let publications = 0;
    const run = vm.runInNewContext(`(${definition})`, {
        process, isAbsolute, EXCHANGE_PATH: exchange, realpath, verifyExchangeDirectory: async () => exchange,
        regularFile: filename => readFile(filename),
        validateJob: value => value, verifyGuest: async () => ({vmId: "fixture"}), join, mkdir,
        userInfo: () => ({homedir: root}), createManifest: () => [], pendingStageResults: () => [], acquireRunLock,
        timestamp: () => "fixture", resourceSnapshot: () => ({}), coverageReport: () => ({}),
        readGuestProvision: async () => { throw new Error("fixture prerequisite failure"); },
        atomicJSON: async () => { if (++publications === 2) throw new Error("fixture final report failed"); },
    });
    await assert.rejects(run(["--exchange", exchange]), /final report failed/);
    const release = await acquireRunLock(join(root, "Library/Application Support/BigWalletTestVM/run.lock"), "report-retry");
    await release();
}));
