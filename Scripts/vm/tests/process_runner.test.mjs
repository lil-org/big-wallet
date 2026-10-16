import assert from "node:assert/strict";
import fs, {existsSync, readFileSync} from "node:fs";
import {mkdtemp, readFile, rm} from "node:fs/promises";
import {syncBuiltinESMExports} from "node:module";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {performance} from "node:perf_hooks";
import {Writable} from "node:stream";
import test from "node:test";
import {setTimeout as delay} from "node:timers/promises";
import {runProcess} from "../guest.mjs";

function alive(pid) {
    try { process.kill(pid, 0); return true; }
    catch (error) { if (error.code === "ESRCH") { return false; } throw error; }
}

async function waitForExit(pid) {
    const deadline = performance.now() + 2000;
    while (alive(pid) && performance.now() < deadline) { await delay(20); }
    assert.equal(alive(pid), false, `Fixture process ${pid} did not exit`);
}

async function withProcesses({detached = false, exitCode = 0, waitForStop = false, writeWhenReady = false}, run) {
    const root = await mkdtemp(join(tmpdir(), "big-wallet-process-unit-"));
    const pidPath = join(root, "pids.json");
    const readyPath = join(root, "ready");
    const signalsPath = join(root, "signals");
    const descendant = `
        const fs = require('node:fs');
        ${waitForStop ? `process.on('SIGTERM', () => fs.appendFileSync(${JSON.stringify(signalsPath)}, 'TERM\\n'));` : ""}
        fs.writeFileSync(${JSON.stringify(readyPath)}, 'ready');
        setTimeout(() => process.exit(0), 10000);
    `;
    const parent = `
        const fs = require('node:fs');
        const {spawn} = require('node:child_process');
        fs.writeFileSync(${JSON.stringify(pidPath)}, JSON.stringify({parent: process.pid}));
        const child = spawn(process.execPath, ['-e', ${JSON.stringify(descendant)}], {
            detached: ${detached}, stdio: ${waitForStop ? "['ignore', 'ignore', 'ignore']" : "['ignore', process.stdout, process.stderr]"}
        });
        fs.writeFileSync(${JSON.stringify(pidPath)}, JSON.stringify({parent: process.pid, descendant: child.pid}));
        child.unref();
        ${writeWhenReady ? `const ready = setInterval(() => {
            if (fs.existsSync(${JSON.stringify(readyPath)})) { clearInterval(ready); process.stdout.write('ready\\n'); }
        }, 10);` : ""}
        ${waitForStop ? "setTimeout(() => process.exit(0), 10000);" : `process.stdout.write('Finished\\n', () => process.exit(${exitCode}));`}
    `;
    try { await run({parent, root, pidPath, readyPath, signalsPath}); }
    finally {
        if (existsSync(pidPath)) {
            const pids = JSON.parse(readFileSync(pidPath, "utf8"));
            for (const pid of Object.values(pids)) {
                try { process.kill(pid, "SIGKILL"); }
                catch (error) { if (error.code !== "ESRCH") { throw error; } }
            }
            for (const pid of Object.values(pids)) { await waitForExit(pid); }
        }
        await rm(root, {recursive: true, force: true});
    }
}

for (const detached of [false, true]) {
    test(`own exit bounds inherited output drain with detached descendant=${detached}`, {timeout: 20000}, async () => {
        const exitCode = detached ? 7 : 0;
        await withProcesses({detached, exitCode}, async ({parent, root, pidPath}) => {
            const started = performance.now();
            const result = await runProcess(process.execPath, ["-e", parent], {
                timeoutSeconds: 2, logPath: join(root, "command.log"),
            });
            assert.ok(performance.now() - started < 5000);
            assert.equal(result.code, exitCode);
            assert.equal(result.signal, null);
            assert.equal(result.stdout, "Finished\n");
            assert.equal(result.timedOut, false);
            assert.equal(result.cancelled, false);
            assert.equal(result.outputDrainTimedOut, true);
            assert.equal(await readFile(join(root, "command.log"), "utf8"), "Finished\n");
            assert.equal(alive(JSON.parse(await readFile(pidPath, "utf8")).descendant), true);
        });
    });
}

for (const cancellation of [false, true]) {
    test(`${cancellation ? "cancellation" : "timeout"} preserves group escalation after the parent exits`, {timeout: 20000}, async () => {
        await withProcesses({waitForStop: true}, async ({parent, pidPath, readyPath, signalsPath}) => {
            const result = await runProcess(process.execPath, ["-e", parent], {
                timeoutSeconds: cancellation ? 20 : 2,
                stopRequested: async () => cancellation && existsSync(readyPath),
            });
            assert.equal(result.code, null);
            assert.equal(result.signal, "SIGTERM");
            assert.equal(result.timedOut, !cancellation);
            assert.equal(result.cancelled, cancellation);
            assert.equal(result.outputDrainTimedOut, false);
            assert.match(await readFile(signalsPath, "utf8"), /TERM/);
            await waitForExit(JSON.parse(await readFile(pidPath, "utf8")).descendant);
        });
    });
}

test("log write failures preserve bounded process-group cleanup without reporting cancellation", {timeout: 15000}, async context => {
    const replacement = context.mock.method(fs, "createWriteStream", () => new Writable({
        write(_chunk, _encoding, callback) { callback(Object.assign(new Error("ENOSPC: no space left on device"), {code: "ENOSPC"})); },
    }));
    syncBuiltinESMExports();
    try {
        await withProcesses({waitForStop: true, writeWhenReady: true}, async ({parent, root, pidPath, signalsPath}) => {
            const started = performance.now();
            const result = await runProcess(process.execPath, ["-e", parent], {timeoutSeconds: 10,
                logPath: join(root, "command.log"), stopRequested: async () => false});
            assert.ok(performance.now() - started < 8000);
            assert.equal(result.timedOut, false);
            assert.equal(result.cancelled, false);
            assert.equal(result.signal, "SIGTERM");
            assert.match(result.error, /Stage log failed: ENOSPC/);
            assert.match(await readFile(signalsPath, "utf8"), /TERM/);
            await waitForExit(JSON.parse(await readFile(pidPath, "utf8")).descendant);
        });
    } finally { replacement.mock.restore(); syncBuiltinESMExports(); }
});

test("spawn errors resolve without waiting for an exit event", {timeout: 5000}, async () => {
    const result = await runProcess("/nonexistent/big-wallet-process-fixture", [], {timeoutSeconds: 1});
    assert.match(result.error, /ENOENT/);
    assert.equal(result.timedOut, false);
    assert.equal(result.cancelled, false);
    assert.equal(result.outputDrainTimedOut, false);
});

test("prelaunch cancellation does not create a process", async () => {
    const result = await runProcess("/nonexistent/big-wallet-process-fixture", [], {stopRequested: async () => true});
    assert.equal(result.cancelled, true);
    assert.equal(result.timedOut, false);
    assert.equal(result.error, undefined);
});
