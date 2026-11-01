import assert from "node:assert/strict";
import {EventEmitter} from "node:events";
import {mkdtemp, rm} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {PassThrough} from "node:stream";
import test from "node:test";
import {asanDiagnostics, startWorker} from "./process.mjs";

const candidate = {name: "empty", mode: "eip712", inputBase64: ""};
const response = request => ({version: 1, id: request.id, mode: request.mode, status: "ok", accepted: false, peakRSSBytes: 1024, durationNanoseconds: 1});

function spawnFake(reply) {
    return () => {
        const child = new EventEmitter();
        child.stdout = new PassThrough(); child.stderr = new PassThrough(); child.stdin = new PassThrough();
        let closed = false;
        const close = (code = 0, signal = null) => {
            if (closed) { return; } closed = true;
            queueMicrotask(() => child.emit("close", code, signal));
        };
        child.kill = () => close(null, "SIGKILL");
        child.stdin.on("data", bytes => reply({child, request: JSON.parse(bytes), close}));
        child.stdin.on("finish", () => close());
        return child;
    };
}

async function fixture(run) {
    const directory = await mkdtemp(join(tmpdir(), "parser-fuzz-process-test-"));
    try { await run(join(directory, "worker.log")); }
    finally { await rm(directory, {recursive: true, force: true}); }
}

test("worker protocol accepts one matching bounded response and drains cleanly", async () => fixture(async logPath => {
    const worker = await startWorker("mock", {logPath, spawnProcess: spawnFake(({child, request}) => child.stdout.write(JSON.stringify(response(request)) + "\n"))});
    assert.equal((await worker.evaluate(candidate)).accepted, false);
    assert.equal((await worker.close()).status, 0);
}));

for (const [name, reply, expected] of [
    ["malformed response", ({child}) => child.stdout.write("not-json\n"), "protocol"],
    ["wrong request identifier", ({child, request}) => child.stdout.write(JSON.stringify({...response(request), id: 999}) + "\n"), "protocol"],
    ["missing resource counters", ({child, request}) => child.stdout.write(JSON.stringify({version: 1, id: request.id, mode: request.mode, status: "ok", accepted: false}) + "\n"), "protocol"],
    ["reported RSS breach", ({child, request}) => child.stdout.write(JSON.stringify({...response(request), peakRSSBytes: 2_000_000_000}) + "\n"), "rss"],
    ["crash", ({close}) => close(null, "SIGABRT"), "crash"],
    ["sanitizer diagnostic", ({child, close}) => { child.stderr.write("ERROR: AddressSanitizer: heap-buffer-overflow\n"); close(1); }, "sanitizer"],
]) {
    test(`worker supervisor rejects ${name}`, async () => fixture(async logPath => {
        const worker = await startWorker("mock", {logPath, spawnProcess: spawnFake(reply)});
        await assert.rejects(worker.evaluate(candidate), error => error.kind === expected);
        await worker.stop();
    }));
}

test("watchdog and cancellation terminate an unresponsive worker", async () => fixture(async logPath => {
    const worker = await startWorker("mock", {logPath, timeoutMilliseconds: 10, spawnProcess: spawnFake(() => {})});
    await assert.rejects(worker.evaluate(candidate), error => error.kind === "timeout");
    await worker.stop();
}));

test("cancellation never becomes a successful partial run", async () => fixture(async logPath => {
    const controller = new AbortController();
    const worker = await startWorker("mock", {logPath, signal: controller.signal, spawnProcess: spawnFake(() => {})});
    const pending = worker.evaluate(candidate); controller.abort();
    await assert.rejects(pending, error => error.kind === "cancelled");
    await worker.stop();
}));

test("sanitizer audit catches initialization failures without flagging plain build flags", () => {
    assert.equal(asanDiagnostics("swiftc -sanitize=address"), false);
    assert.equal(asanDiagnostics("AddressSanitizer runtime is not loaded"), true);
    assert.equal(asanDiagnostics("dyld: Library not loaded: libclang_rt.asan_osx_dynamic.dylib"), true);
});

test("an RSS sample finishing between process exit and stream close cannot fail a clean drain", async () => fixture(async logPath => {
    let sample;
    let sampled;
    const sampleStarted = new Promise(resolve => { sampled = resolve; });
    const spawnProcess = command => {
        if (command === "/bin/ps") {
            sample = new EventEmitter(); sample.stdout = new PassThrough(); sample.kill = () => {};
            sampled(); return sample;
        }
        const child = spawnFake(({child, request}) => child.stdout.write(JSON.stringify(response(request)) + "\n"))();
        child.pid = 123;
        child.stdin.removeAllListeners("finish");
        child.stdin.on("finish", () => {
            child.emit("exit", 0, null);
            sample.emit("close", 1, null);
            queueMicrotask(() => child.emit("close", 0, null));
        });
        return child;
    };
    const worker = await startWorker("mock", {logPath, spawnProcess});
    await worker.evaluate(candidate); await sampleStarted;
    assert.equal((await worker.close()).status, 0);
}));

test("a failed RSS sample still fails monitoring while the worker is alive", async () => fixture(async logPath => {
    const spawnProcess = command => {
        if (command === "/bin/ps") {
            const sample = new EventEmitter(); sample.stdout = new PassThrough(); sample.kill = () => {};
            queueMicrotask(() => sample.emit("close", 1, null));
            return sample;
        }
        const child = spawnFake(() => {})(); child.pid = 123; return child;
    };
    const worker = await startWorker("mock", {logPath, spawnProcess});
    await assert.rejects(worker.evaluate(candidate), error => error.kind === "resourceMonitor");
    await worker.stop();
}));
