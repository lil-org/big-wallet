import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import {basename, dirname, join} from "node:path";
import test from "node:test";
import vm from "node:vm";
import {LIMITS, sha256} from "./contract.mjs";
import {WorkerFailure} from "./process.mjs";
import {hostReplayCommand, shrinkCandidates} from "./run.mjs";

const source = await readFile(new URL("./run.mjs", import.meta.url), "utf8");
const start = source.indexOf("async function preserveFailure("), end = source.indexOf("\nasync function runCases(", start);
assert.ok(start >= 0 && end > start);

async function preserve(candidate, durations) {
    let elapsed = 0, artifact;
    const watchdogs = [];
    const preserveFailure = vm.runInNewContext(source.slice(start, end) + "\npreserveFailure", {
        basename, dirname, join, LIMITS, sha256, hostReplayCommand, shrinkCandidates,
        identity: () => ({runId: "synthetic", sourceSHA256: "a".repeat(64)}),
        performance: {now: () => elapsed += 0.1},
        atomicJSON: async (path, value) => { artifact = structuredClone(value); },
        recordEvidence: async () => {},
        startWorker: async (executable, {timeoutMilliseconds}) => {
            const duration = durations[watchdogs.length];
            assert.equal(typeof duration, "number");
            watchdogs.push(timeoutMilliseconds);
            return {
                async evaluate() {
                    elapsed += Math.min(duration, timeoutMilliseconds);
                    if (duration > timeoutMilliseconds) { throw new WorkerFailure("timeout", "Native case exceeded its watchdog"); }
                    return {failure: null};
                },
                async close() {},
                async stop() {},
            };
        },
        evaluate: (value, worker) => worker.evaluate(value),
    });
    await preserveFailure({failureDirectory: "/synthetic", report: "/synthetic/report.json", profile: "all", phase: "parsers"},
        {runId: "synthetic", failures: []}, "mock", {id: "case/0", candidate},
        {kind: "timeout", code: "timeout", message: "Native case exceeded its watchdog"}, new AbortController().signal);
    return {artifact, watchdogs};
}

test("timeout minimization cannot promote expiration of the remaining shrink budget", async () => {
    const candidate = {name: "slow-input", mode: "eip712", inputBase64: Buffer.from("abcdefghijklmnopqrstuvwxyz012345").toString("base64")};
    const {artifact, watchdogs} = await preserve(candidate, [6_000, ...Array(6).fill(3_900), 2_000]);
    assert.equal(artifact.reproduced, true);
    assert.deepEqual(artifact.case, candidate);
    assert.equal(artifact.shrinkAttempts, 6);
    assert.deepEqual(watchdogs, Array(7).fill(LIMITS.parserMilliseconds));
});

test("initial decryption reproduction retains its full watchdog despite setup time", async () => {
    const candidate = {name: "decrypt-timeout", mode: "decrypt", fixtureID: "ethereum-pbkdf2", mutation: "original", mutationIndex: 0};
    const {artifact, watchdogs} = await preserve(candidate, [LIMITS.decryptMilliseconds + 1]);
    assert.equal(artifact.reproduced, true);
    assert.deepEqual(artifact.case, candidate);
    assert.equal(artifact.shrinkAttempts, 0);
    assert.deepEqual(watchdogs, [LIMITS.decryptMilliseconds]);
});
