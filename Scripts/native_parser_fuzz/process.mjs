import {spawn} from "node:child_process";
import {appendFile, writeFile} from "node:fs/promises";
import {LIMITS, finiteCount, nativeRequest} from "./contract.mjs";

export class WorkerFailure extends Error {
    constructor(kind, message, code = kind) { super(message); this.name = "WorkerFailure"; this.kind = kind; this.code = code; }
}

export function asanDiagnostics(text) {
    return /\b(?:ERROR|SUMMARY):\s*Address\s*Sanitizer\b|\bAddress\s*Sanitizer:\s*(?:DEADLYSIGNAL|CHECK failed|ERROR|WARNING|heap-|stack-|global-|double-free|alloc-dealloc|attempting free|allocation-size-too-big|negative-size-param)|\b(?:ASan|Address\s*Sanitizer)(?: runtime)?[^\r\n]{0,160}(?:does not come first|cannot proceed|is not loaded|failed to|unable to|loaded too late)|\b(?:dyld|Library not loaded)[^\r\n]{0,4096}libclang_rt\.asan/i.test(text);
}

export async function runCommand(command, args, {cwd, env, logPath, timeoutMilliseconds = 120_000, signal} = {}) {
    await writeFile(logPath, "", {flag: "wx"});
    return await new Promise((resolve, reject) => {
        const child = spawn(command, args, {cwd, env: {...process.env, ...env}, stdio: ["ignore", "pipe", "pipe"], detached: true});
        let text = "", failure, bytes = 0, writes = Promise.resolve(), settled = false;
        const kill = () => { if (child.pid) { try { process.kill(-child.pid, "SIGKILL"); } catch {} } };
        const fail = error => { failure ??= error; kill(); };
        const receive = data => {
            bytes += data.length;
            if (bytes > LIMITS.logBytes) { fail(new WorkerFailure("logLimit", "Command log exceeded its bound")); return; }
            text += data.toString();
            writes = writes.then(() => appendFile(logPath, data)).catch(error => fail(error));
        };
        child.stdout.on("data", receive); child.stderr.on("data", receive);
        child.on("error", error => fail(error));
        const timer = setTimeout(() => fail(new WorkerFailure("timeout", "Command exceeded its deadline")), timeoutMilliseconds);
        const abort = () => fail(new WorkerFailure("cancelled", "Run was cancelled"));
        signal?.addEventListener("abort", abort, {once: true});
        if (signal?.aborted) { abort(); }
        child.on("close", async (status, exitSignal) => {
            if (settled) { return; } settled = true;
            clearTimeout(timer); signal?.removeEventListener("abort", abort);
            await writes;
            if (failure) { reject(failure); return; }
            resolve({status, signal: exitSignal, output: text});
        });
    });
}

export async function startWorker(executable, {logPath, args = [], timeoutMilliseconds = LIMITS.parserMilliseconds,
    rssBytes = LIMITS.rssBytes, signal, spawnProcess = spawn} = {}) {
    await writeFile(logPath, "", {flag: "wx"});
    const child = spawnProcess(executable, args, {stdio: ["pipe", "pipe", "pipe"],
        env: {...process.env, ASAN_OPTIONS: "detect_leaks=0:halt_on_error=1:abort_on_error=1", OS_ACTIVITY_MODE: "disable"}});
    child.stdout.setEncoding("utf8");
    let output = "", stderr = "", logBytes = 0, pending, failure, closing = false, exited = false, processExited = false, nextID = 0;
    let peakRSSBytes = 0, rssSamples = 0, sampling = false, writes = Promise.resolve();
    let resolveCompletion;
    const completion = new Promise(resolve => { resolveCompletion = resolve; });
    const terminate = () => { if (!exited && !processExited) { child.kill("SIGKILL"); } };
    const fail = error => {
        failure ??= error;
        if (pending) { clearTimeout(pending.timer); pending.reject(failure); pending = undefined; }
        terminate();
    };
    const abort = () => fail(new WorkerFailure("cancelled", "Worker cancelled"));
    signal?.addEventListener("abort", abort, {once: true});
    if (signal?.aborted) { abort(); }
    child.stderr.on("data", data => {
        logBytes += data.length;
        if (logBytes > LIMITS.logBytes) { fail(new WorkerFailure("logLimit", "Worker log exceeded its bound")); return; }
        stderr += data.toString();
        writes = writes.then(() => appendFile(logPath, data)).catch(error => fail(new WorkerFailure("evidence", error.message)));
    });
    child.stdout.on("data", data => {
        output += data;
        if (Buffer.byteLength(output) > LIMITS.responseBytes) { fail(new WorkerFailure("protocol", "Worker response exceeded its bound")); return; }
        let boundary;
        while ((boundary = output.indexOf("\n")) !== -1) {
            const line = output.slice(0, boundary); output = output.slice(boundary + 1);
            try {
                const value = JSON.parse(line);
                if (!pending || value.version !== 1 || value.id !== pending.id || value.mode !== pending.mode ||
                    !["ok", "failure"].includes(value.status) || !finiteCount(value.peakRSSBytes) || !finiteCount(value.durationNanoseconds) ||
                    value.status === "ok" && typeof value.accepted !== "boolean" ||
                    value.status === "failure" && typeof value.invariant !== "string") {
                    throw new Error("Malformed, duplicate, or out-of-order worker response");
                }
                peakRSSBytes = Math.max(peakRSSBytes, value.peakRSSBytes);
                if (peakRSSBytes > rssBytes) { fail(new WorkerFailure("rss", "Worker exceeded monitored RSS limit")); return; }
                const current = pending; pending = undefined; clearTimeout(current.timer); current.resolve(value);
            } catch (error) { fail(new WorkerFailure("protocol", error.message)); return; }
        }
    });
    child.on("error", error => fail(new WorkerFailure("spawn", error.message)));
    child.stdin.on("error", error => {
        if (error.code !== "EPIPE") { fail(new WorkerFailure("input", error.message)); }
    });
    const rssTimer = setInterval(() => {
        if (sampling || exited || processExited || !child.pid) { return; }
        sampling = true;
        const sample = spawnProcess("/bin/ps", ["-o", "rss=", "-p", String(child.pid)], {stdio: ["ignore", "pipe", "ignore"]});
        let value = "";
        sample.stdout.on("data", data => { value += data.toString(); });
        const sampleTimer = setTimeout(() => { sample.kill("SIGKILL"); }, 1_000);
        sample.on("error", error => { if (!exited && !processExited) { fail(new WorkerFailure("resourceMonitor", error.message)); } });
        sample.on("close", status => {
            sampling = false; clearTimeout(sampleTimer);
            if (exited || processExited) { return; }
            if (status !== 0 || !/^\s*\d+\s*$/.test(value)) { fail(new WorkerFailure("resourceMonitor", "Could not sample worker RSS")); return; }
            const measured = Number(value.trim()) * 1024;
            if (!finiteCount(measured)) { fail(new WorkerFailure("resourceMonitor", "Invalid worker RSS sample")); return; }
            rssSamples += 1; peakRSSBytes = Math.max(peakRSSBytes, measured);
            if (peakRSSBytes > rssBytes) { fail(new WorkerFailure("rss", "Worker exceeded monitored RSS limit")); }
        });
    }, 100);
    child.on("exit", () => { processExited = true; clearInterval(rssTimer); });
    child.on("close", async (status, exitSignal) => {
        exited = true; clearInterval(rssTimer); signal?.removeEventListener("abort", abort);
        if (asanDiagnostics(stderr) && !failure) { failure = new WorkerFailure("sanitizer", "AddressSanitizer diagnostic"); }
        if (!failure && (!closing || status !== 0 || output.length || pending)) { failure = new WorkerFailure("crash", `Worker exited unexpectedly (${exitSignal ?? status})`); }
        if (pending) { clearTimeout(pending.timer); pending.reject(failure); pending = undefined; }
        await writes;
        resolveCompletion({status, signal: exitSignal, stderr, failure, peakRSSBytes, rssSamples});
    });
    return {
        async evaluate(candidate) {
            if (failure) { throw failure; }
            if (exited || pending) { throw new WorkerFailure("protocol", "Worker is closed or already processing a case"); }
            const id = nextID++;
            return await new Promise((resolve, reject) => {
                const timer = setTimeout(() => fail(new WorkerFailure("timeout", "Native case exceeded its watchdog")), timeoutMilliseconds);
                pending = {id, mode: candidate.mode, resolve, reject, timer};
                child.stdin.write(JSON.stringify(nativeRequest(candidate, id)) + "\n");
            });
        },
        async close() {
            closing = true; child.stdin.end();
            const timer = setTimeout(() => fail(new WorkerFailure("timeout", "Worker output did not drain")), 5_000);
            const result = await completion; clearTimeout(timer);
            if (result.failure) { throw result.failure; }
            return result;
        },
        async stop() { closing = true; terminate(); return await completion; },
        get stats() { return {peakRSSBytes, rssSamples}; },
        get stderr() { return stderr; },
    };
}
