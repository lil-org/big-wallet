#!/usr/bin/env node

import {execFileSync} from "node:child_process";
import {randomUUID} from "node:crypto";
import {appendFile, copyFile, lstat, mkdir, readFile, readdir, rename, rm, writeFile} from "node:fs/promises";
import {basename, dirname, isAbsolute, join, relative, resolve} from "node:path";
import {pathToFileURL} from "node:url";
import {gzipSync} from "node:zlib";
import {inspectParserFuzzTarget} from "../validate_parser_fuzz_target.mjs";
import {CANARIES, FIXTURES_PATH, HARNESS, LIMITS, PROFILES, ROOT, caseDigest, digest, parseOptions, sha256, validateCase} from "./contract.mjs";
import {planSummary, plannedCases} from "./cases.mjs";
import {compareResult, oracleFingerprint, solanaOracle} from "./oracles.mjs";
import {WorkerFailure, asanDiagnostics, runCommand, startWorker} from "./process.mjs";
import {captureParserSource, validateParserSourceInventory} from "./source.mjs";
import {readStableFile} from "./evidence.mjs";
import {captureCompilerResponses} from "./compiler.mjs";

const CACHE = join(HARNESS, ".build", "parser-fuzz-asan");
const RECEIPT = join(CACHE, "build-receipt.json");
const BUDGET = join(CACHE, "execution-budget.json");
const milliseconds = nanoseconds => Number(nanoseconds / 1_000_000n);

async function atomicJSON(path, value) {
    const temporary = `${path}.${randomUUID()}.tmp`;
    await writeFile(temporary, JSON.stringify(value, null, 2) + "\n", {flag: "wx", mode: 0o600});
    await rename(temporary, path);
}

async function regularFile(path, maximum = LIMITS.logBytes) {
    return await readStableFile(path, maximum);
}

async function sourceInventory() {
    const paths = [];
    async function visit(path) {
        const status = await lstat(path);
        if (status.isSymbolicLink()) { throw new Error(`Source inventory contains a symlink: ${path}`); }
        if (status.isDirectory()) {
            for (const name of (await readdir(path)).sort()) { if (!name.startsWith(".")) { await visit(join(path, name)); } }
        } else if (status.isFile()) { paths.push({path: relative(ROOT, path), sha256: sha256(await regularFile(path, 64 * 1_024 * 1_024))}); }
    }
    for (const path of [join(ROOT, "Packages/WalletRuntime/Package.swift"), join(ROOT, "Packages/WalletRuntime/Sources"),
        join(HARNESS, "Package.swift"), join(HARNESS, "Sources"), join(ROOT, "Scripts/native_parser_fuzz"),
        join(ROOT, "Scripts/validate_parser_fuzz_target.mjs")]) { await visit(path); }
    return paths.sort((a, b) => a.path.localeCompare(b.path));
}

async function recordEvidence(report, directory, name) {
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name)) { throw new Error("Unsafe evidence name"); }
    const bytes = await regularFile(join(directory, name), name.endsWith(".jsonl.gz") ? LIMITS.compressedLedgerBytes : 64 * 1_024 * 1_024);
    const evidence = {path: name, sha256: sha256(bytes), bytes: bytes.length};
    report.evidence = report.evidence.filter(value => value.path !== name);
    report.evidence.push(evidence);
    return evidence;
}

function identity() {
    const runId = process.env.BW_TEST_VM_RUN_ID, sourceSHA256 = process.env.BW_TEST_VM_SOURCE_SHA256;
    if (typeof runId !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(runId) || runId.includes("..") || !digest(sourceSHA256)) {
        throw new Error("Parser fuzz requires the VM run and source snapshot identities");
    }
    return {runId, sourceSHA256};
}

async function build(options, report, signal) {
    const directory = dirname(options.report);
    const initialSources = await sourceInventory();
    const capturedSource = await captureParserSource(initialSources, identity());
    await writeFile(join(directory, "snapshot-manifest.json"), capturedSource.manifestBytes, {flag: "wx"});
    await writeFile(join(directory, "workspace-marker.json"), capturedSource.markerBytes, {flag: "wx"});
    await atomicJSON(join(directory, "source-identity.json"), capturedSource.identity);
    const graph = inspectParserFuzzTarget(ROOT);
    await atomicJSON(join(directory, "target-graph.json"), graph);
    await rm(CACHE, {recursive: true, force: true});
    await mkdir(CACHE, {recursive: true});
    const commands = [];
    async function execute(args, name, timeoutMilliseconds = 120_000, command = "xcrun") {
        const result = await runCommand(command, args, {cwd: ROOT, logPath: join(directory, name), signal, timeoutMilliseconds});
        commands.push({command, args, log: name, status: result.status, signal: result.signal});
        if (result.status !== 0 || result.signal) { throw new WorkerFailure("build", `Build command failed: ${name}`); }
        return result.output;
    }
    const compiler = await execute(["swiftc", "--version"], "compiler-version.txt");
    const arguments_ = ["swift", "build", "--package-path", HARNESS, "--scratch-path", CACHE,
        "--configuration", "release", "--product", "WalletParserFuzzWorker", "--jobs", "2", "--sanitize", "address", "-Xswiftc", "-enable-testing", "-v"];
    const buildLog = await execute(arguments_, "build.log", 1_800_000);
    const compilerResponses = await captureCompilerResponses(buildLog, CACHE);
    const responseFiles = [];
    for (const [path, bytes] of compilerResponses) {
        const artifact = `compiler-response-${String(responseFiles.length).padStart(3, "0")}.rsp`;
        await writeFile(join(directory, artifact), bytes, {flag: "wx"});
        responseFiles.push({path, artifact, sha256: sha256(bytes), bytes: bytes.length});
        await recordEvidence(report, directory, artifact);
    }
    const output = await execute(["swift", "build", "--package-path", HARNESS, "--scratch-path", CACHE,
        "--configuration", "release", "--show-bin-path"], "binary-location.txt");
    const binaryDirectory = output.trim().split(/\r?\n/).at(-1);
    if (!isAbsolute(binaryDirectory) || !binaryDirectory.startsWith(`${CACHE}/`)) { throw new Error("Worker build product escaped its isolated package cache"); }
    const executable = join(binaryDirectory, "WalletParserFuzzWorker");
    const linkage = await execute(["otool", "-L", executable], "linkage.txt");
    if (!/libclang_rt\.asan_osx_dynamic\.dylib/.test(linkage)) { throw new Error("Worker does not link the AddressSanitizer runtime"); }
    const resource = JSON.parse(await execute(["--fixture-identity"], "resource-identity.json", 30_000, executable));
    if (resource.version !== 1 || !resource.path?.startsWith(`${binaryDirectory}/`) || !resource.path.endsWith("/fixtures.json")) {
        throw new Error("Worker fixture resource escaped its built bundle");
    }
    const builtFixtures = await regularFile(resource.path, 65_536);
    if (resource.bytes !== builtFixtures.length || resource.sha256 !== sha256(builtFixtures) ||
        resource.sha256 !== sha256(await regularFile(FIXTURES_PATH, 65_536))) { throw new Error("Built fixture bundle differs from the submitted source"); }
    await writeFile(join(directory, "built-fixtures.json"), builtFixtures, {flag: "wx"});
    const sources = await sourceInventory();
    validateParserSourceInventory(capturedSource.manifestBytes, sources, report.sourceSHA256);
    await atomicJSON(join(directory, "source-inventory.json"), sources);
    await atomicJSON(join(directory, "commands.json"), commands);
    await copyFile(executable, join(directory, "worker.bin"));
    await copyFile(FIXTURES_PATH, join(directory, "fixtures.json"));
    for (const name of ["target-graph.json", "compiler-version.txt", "build.log", "binary-location.txt", "linkage.txt", "source-inventory.json", "commands.json", "worker.bin", "fixtures.json",
        "snapshot-manifest.json", "workspace-marker.json", "source-identity.json", "resource-identity.json", "built-fixtures.json"]) {
        await recordEvidence(report, directory, name);
    }
    report.build = {configuration: "release", sanitizers: ["address"], testable: ["WalletDomain", "WalletAuthority"],
        compiler: compiler.trim(), arguments: arguments_, binarySHA256: sha256(await regularFile(executable, 64 * 1_024 * 1_024)),
        sourceInventorySHA256: sha256(JSON.stringify(sources)), graphValidated: true, responseFiles,
        resource: {path: relative(CACHE, resource.path), sha256: resource.sha256, bytes: resource.bytes}};
    const receipt = {version: 1, ...identity(), profile: options.profile, executable, resourcePath: resource.path, evidenceDirectory: directory,
        evidence: report.evidence, build: report.build};
    await atomicJSON(RECEIPT, receipt);
    await atomicJSON(BUDGET, {version: 1, ...identity(), profile: options.profile, spentNanoseconds: "0", active: null});
}

async function loadBuild(options, report) {
    const receipt = JSON.parse(await regularFile(RECEIPT));
    const current = identity();
    if (receipt.version !== 1 || receipt.runId !== current.runId || receipt.sourceSHA256 !== current.sourceSHA256 || receipt.profile !== options.profile ||
        !receipt.executable?.startsWith(`${CACHE}/`) || sha256(await regularFile(receipt.executable, 64 * 1_024 * 1_024)) !== receipt.build?.binarySHA256 ||
        typeof receipt.build.resource?.path !== "string" || receipt.build.resource.path.split("/").includes("..") ||
        receipt.resourcePath !== join(CACHE, receipt.build.resource.path) ||
        sha256(await regularFile(receipt.resourcePath, 65_536)) !== receipt.build.resource.sha256 ||
        sha256(JSON.stringify(await sourceInventory())) !== receipt.build.sourceInventorySHA256) {
        throw new Error("Build receipt does not match this run, source, or executable");
    }
    for (const entry of receipt.evidence) {
        if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(entry.path)) { throw new Error("Invalid build evidence path"); }
        const source = join(receipt.evidenceDirectory, entry.path);
        const bytes = await regularFile(source, 64 * 1_024 * 1_024);
        if (sha256(bytes) !== entry.sha256 || bytes.length !== entry.bytes) { throw new Error("Build evidence changed"); }
        await copyFile(source, join(dirname(options.report), entry.path));
        await recordEvidence(report, dirname(options.report), entry.path);
    }
    report.build = receipt.build;
    await captureParserSource(await sourceInventory(), current);
    return receipt.executable;
}

async function startBudget(options, report, cancellation) {
    const budget = JSON.parse(await regularFile(BUDGET));
    const current = identity();
    if (budget.version !== 1 || budget.runId !== current.runId || budget.sourceSHA256 !== current.sourceSHA256 || budget.profile !== options.profile ||
        budget.active !== null || !/^\d+$/.test(budget.spentNanoseconds)) { throw new Error("Missing, mismatched, or unfinished aggregate execution budget"); }
    const allowance = BigInt(PROFILES[options.profile].executionSeconds) * 1_000_000_000n;
    const spent = BigInt(budget.spentNanoseconds);
    if (spent >= allowance) { throw new WorkerFailure("budget", "Aggregate native fuzz budget exhausted"); }
    const started = process.hrtime.bigint(), token = randomUUID();
    budget.active = {phase: options.phase, token, startedNanoseconds: String(started)};
    await atomicJSON(BUDGET, budget);
    report.aggregateBudget = {limitSeconds: PROFILES[options.profile].executionSeconds, beforeNanoseconds: String(spent),
        phaseNanoseconds: "0", afterNanoseconds: String(spent), excludesCompilation: true};
    const timer = setTimeout(() => cancellation.abort(new WorkerFailure("budget", "Aggregate native fuzz execution deadline reached")), milliseconds(allowance - spent));
    return async () => {
        clearTimeout(timer);
        const elapsed = process.hrtime.bigint() - started;
        const latest = JSON.parse(await regularFile(BUDGET));
        if (latest.active?.token !== token) { throw new Error("Aggregate budget ownership changed"); }
        report.aggregateBudget.phaseNanoseconds = String(elapsed);
        report.aggregateBudget.afterNanoseconds = String(spent + elapsed);
        await atomicJSON(BUDGET, {...budget, spentNanoseconds: String(spent + elapsed), active: null});
        if (spent + elapsed > allowance) { throw new WorkerFailure("budget", "Aggregate native fuzz execution budget exceeded"); }
    };
}

export function* shrinkCandidates(candidate) {
    if (!candidate.inputBase64 || candidate.relation || candidate.expected) { return; }
    const original = Buffer.from(candidate.inputBase64, "base64");
    for (let chunks = 2; chunks <= 16; chunks *= 2) {
        const length = Math.max(1, Math.ceil(original.length / chunks));
        for (let offset = 0; offset < original.length; offset += length) {
            const smaller = Buffer.concat([original.subarray(0, offset), original.subarray(offset + length)]);
            if (smaller.length < original.length) { yield {...candidate, inputBase64: smaller.toString("base64")}; }
        }
    }
}

async function evaluate(candidate, worker) {
    const result = await worker.evaluate(candidate);
    const oracle = candidate.mode === "solana" ? solanaOracle(candidate) : undefined;
    return {result, oracle, failure: compareResult(candidate, result, oracle)};
}

export function hostReplayCommand(runId, phase, artifactName) {
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(runId) || runId.includes("..") ||
        !["parsers", "decrypt", "replay"].includes(phase) || !/^failure-[a-f0-9]{16}\.json$/.test(artifactName)) {
        throw new Error("Invalid host replay artifact identity");
    }
    return 'Scripts/test_vm.sh run all --stage parser-fuzz --parser-fuzz-replay "${BW_TEST_VM_STATE_DIR:-$HOME/Library/Application Support/Big Wallet Test VM}/results/' +
        `${runId}/artifacts/failures/fuzz.native.${phase}/${artifactName}"`;
}

async function preserveFailure(options, report, executable, entry, failure, signal) {
    const path = join(options.failureDirectory, `failure-${sha256(entry.id).slice(0, 16)}.json`);
    const artifact = {version: 1, ...identity(), profile: options.profile, phase: options.phase, caseID: entry.id,
        originalCase: entry.candidate, case: entry.candidate, failure, reproduced: false, shrinkAttempts: 0,
        replay: hostReplayCommand(report.runId, options.phase, basename(path)),
        replayStateDirectory: "Uses the default VM state directory or BW_TEST_VM_STATE_DIR; set that variable when the run used --state-dir."};
    await atomicJSON(path, artifact);
    const started = performance.now();
    const timeoutMilliseconds = entry.candidate.mode === "decrypt" ? LIMITS.decryptMilliseconds : LIMITS.parserMilliseconds;
    let attempt = 0;
    async function reproduce(candidate) {
        const remaining = LIMITS.shrinkMilliseconds - (performance.now() - started);
        if (remaining <= 0 || signal.aborted) { return false; }
        const name = `reproduce-${attempt++}.log`;
        let worker, observed;
        try {
            worker = await startWorker(executable, {logPath: join(dirname(options.report), name), signal,
                timeoutMilliseconds});
            observed = (await evaluate(candidate, worker)).failure;
            await worker.close();
        } catch (error) { observed ??= {kind: error.kind ?? "infrastructure", code: error.code ?? "error", message: error.message}; }
        finally { if (worker) { await worker.stop(); } await recordEvidence(report, dirname(options.report), name); }
        return observed?.kind === failure.kind && observed?.code === failure.code;
    }
    if (!signal.aborted && failure.kind !== "cancelled") {
        artifact.reproduced = await reproduce(entry.candidate);
        if (artifact.reproduced && ["invariant", "oracle", "crash", "sanitizer", "timeout", "rss"].includes(failure.kind)) {
            for (const smaller of shrinkCandidates(entry.candidate)) {
                if (attempt >= LIMITS.shrinkAttempts || LIMITS.shrinkMilliseconds - (performance.now() - started) < timeoutMilliseconds || signal.aborted) { break; }
                artifact.shrinkAttempts += 1;
                if (await reproduce(smaller)) { artifact.case = smaller; break; }
            }
        }
    }
    await atomicJSON(path, artifact);
    report.failures.push({caseID: entry.id, kind: failure.kind, code: failure.code, artifact: path, reproduced: artifact.reproduced});
}

async function runCases(options, report, executable, replay, signal) {
    const directory = dirname(options.report), ledger = join(directory, "cases.jsonl.gz");
    await writeFile(ledger, "", {flag: "wx"});
    report.plan = planSummary(options.profile, options.phase, replay);
    report.caseCounts = {planned: report.plan.count, executed: 0, accepted: 0, rejected: 0};
    report.checks = {knownAnswers: 0, relations: 0, solanaComparisons: 0, solanaStrictnessDifferences: 0, keystoreRoundTrips: 0};
    report.resources = {peakRSSBytes: 0, rssSamples: 0, monitoring: "getrusage plus periodic ps; watchdog enforcement, not OS memory isolation"};
    const logName = "worker.log";
    const worker = await startWorker(executable, {logPath: join(directory, logName), signal,
        timeoutMilliseconds: options.phase === "decrypt" || replay?.mode === "decrypt" ? LIMITS.decryptMilliseconds : LIMITS.parserMilliseconds});
    let buffer = "", buffered = 0, currentEntry, compressedBytes = 0, expandedBytes = 0;
    const flush = async () => {
        if (!buffer) { return; }
        expandedBytes += Buffer.byteLength(buffer);
        const compressed = gzipSync(buffer);
        compressedBytes += compressed.length;
        if (expandedBytes > LIMITS.expandedLedgerBytes || compressedBytes > LIMITS.compressedLedgerBytes) { throw new WorkerFailure("evidenceLimit", "Case ledger exceeded its bounded artifact allowance"); }
        await appendFile(ledger, compressed); buffer = ""; buffered = 0;
    };
    try {
        for (const entry of plannedCases(options.profile, options.phase, replay)) {
            currentEntry = entry;
            if (signal.aborted) { throw signal.reason ?? new WorkerFailure("cancelled", "Run cancelled"); }
            const evaluated = await evaluate(entry.candidate, worker);
            const {result, oracle, failure} = evaluated;
            report.caseCounts.executed += 1;
            if (result.status === "ok") { report.caseCounts[result.accepted ? "accepted" : "rejected"] += 1; }
            const checks = {knownAnswer: Boolean(entry.candidate.expected?.digest) || entry.candidate.mode === "decrypt" && result.accepted === true,
                relation: Boolean(entry.candidate.relation), solanaCompared: Boolean(oracle?.accepted && result.accepted),
                strictnessDifference: Boolean(oracle?.accepted && !result.accepted), keystoreRoundTrip: entry.candidate.mode === "keystore" && (result.accepted === true || result.strictAccepted === true)};
            for (const [key, field] of [["knownAnswer", "knownAnswers"], ["relation", "relations"], ["solanaCompared", "solanaComparisons"],
                ["strictnessDifference", "solanaStrictnessDifferences"], ["keystoreRoundTrip", "keystoreRoundTrips"]]) { report.checks[field] += Number(checks[key]); }
            buffer += JSON.stringify({id: entry.id, sha256: caseDigest(entry.candidate), mode: entry.candidate.mode, source: entry.source,
                status: failure ? "failed" : "passed", accepted: result.accepted, durationNanoseconds: result.durationNanoseconds,
                peakRSSBytes: result.peakRSSBytes, checks, result, oracle: oracleFingerprint(oracle)}) + "\n";
            buffered += 1;
            if (buffered >= 64 || failure) { await flush(); }
            if (failure) {
                await worker.stop();
                await preserveFailure(options, report, executable, entry, failure, signal);
                throw new WorkerFailure(failure.kind, failure.message, failure.code);
            }
        }
        await flush();
        await worker.close();
    } catch (error) {
        await flush();
        await worker.stop();
        if (currentEntry && report.failures.length === 0) {
            await preserveFailure(options, report, executable, currentEntry,
                {kind: error.kind ?? "infrastructure", code: error.code ?? "error", message: error.message}, signal);
        }
        throw error;
    } finally {
        const stopped = await worker.stop();
        report.resources.peakRSSBytes = Math.max(stopped.peakRSSBytes, worker.stats.peakRSSBytes);
        report.resources.rssSamples = stopped.rssSamples;
        await recordEvidence(report, directory, logName);
        await recordEvidence(report, directory, "cases.jsonl.gz");
    }
}

async function runCanaries(options, report, executable, signal) {
    const directory = dirname(options.report);
    report.canaries = [];
    report.caseCounts = {planned: CANARIES.length, executed: 0, accepted: 0, rejected: 0};
    const candidate = {name: "canary", mode: "eip712", inputBase64: Buffer.from("{}").toString("base64")};
    for (const name of CANARIES) {
        const log = `canary-${name}.log`;
        const worker = await startWorker(executable, {logPath: join(directory, log), args: name === "protocol" ? [] : ["--canary", name], signal,
            timeoutMilliseconds: name === "hang" ? 750 : 5_000, rssBytes: name === "rss" ? 128 * 1_024 * 1_024 : LIMITS.rssBytes});
        let result, failure, stopped;
        try { result = await worker.evaluate(candidate); if (name === "protocol") { stopped = await worker.close(); } }
        catch (error) { failure = error; }
        stopped ??= await worker.stop();
        const passed = name === "protocol" ? !failure && result?.status === "ok" && result.accepted === false && stopped.status === 0 && stopped.signal === null
            : name === "asan" ? asanDiagnostics(stopped.stderr) && stopped.status !== 0
            : name === "crash" ? stopped.signal === "SIGABRT"
            : name === "hang" ? failure?.kind === "timeout"
            : name === "rss" ? failure?.kind === "rss" && stopped.peakRSSBytes > 128 * 1_024 * 1_024
            : name === "malformed" ? failure?.kind === "protocol"
            : result?.status === "failure" && result.invariant === "deliberateCanary";
        report.caseCounts.executed += 1;
        report.canaries.push({name, passed, failureKind: failure?.kind ?? null, signal: stopped.signal, status: stopped.status,
            invariant: result?.invariant ?? null, resultStatus: result?.status ?? null, accepted: result?.accepted ?? null,
            peakRSSBytes: stopped.peakRSSBytes, log});
        await recordEvidence(report, directory, log);
        if (!passed) { throw new WorkerFailure("canary", `Harness canary ${name} failed (${failure?.kind ?? result?.status ?? stopped.signal ?? stopped.status})`); }
    }
}

export async function main(arguments_ = process.argv.slice(2)) {
    const options = parseOptions(arguments_);
    if (options.help) {
        console.log("Usage: node Scripts/native_parser_fuzz/run.mjs --phase build|canaries|parsers|decrypt|replay --profile all|extended --report FILE --failure-dir DIR [--replay FILE]");
        return;
    }
    execFileSync("/bin/sh", ["-c", '. "$1"; test_vm_require_guest_session', "native-parser-fuzz", join(ROOT, "Scripts/vm/guest_session.sh")], {cwd: ROOT, stdio: "inherit"});
    const currentIdentity = identity(), directory = dirname(options.report);
    await mkdir(directory, {recursive: true, mode: 0o700});
    await mkdir(options.failureDirectory, {recursive: true, mode: 0o700});
    const report = {version: 1, ...currentIdentity, phase: options.phase, profile: options.profile,
        status: "running", startedAt: new Date().toISOString(), coverageGuided: false, engine: "seeded-structure-aware",
        limits: LIMITS, evidence: [], failures: []};
    await writeFile(options.report, JSON.stringify(report) + "\n", {flag: "wx", mode: 0o600});
    const cancellation = new AbortController();
    const cancel = () => cancellation.abort(new WorkerFailure("cancelled", "Parser fuzz interrupted"));
    process.once("SIGTERM", cancel); process.once("SIGINT", cancel);
    let finishBudget;
    try {
        if (options.phase === "build") { await build(options, report, cancellation.signal); }
        else {
            const executable = await loadBuild(options, report);
            finishBudget = await startBudget(options, report, cancellation);
            if (options.phase === "canaries") { await runCanaries(options, report, executable, cancellation.signal); }
            else {
                let replay;
                if (options.phase === "replay") {
                    const bytes = await regularFile(options.replay, LIMITS.artifactBytes);
                    const artifact = JSON.parse(bytes);
                    if (artifact.version !== 1) { throw new Error("Unsupported replay artifact"); }
                    replay = validateCase(artifact.case);
                    report.replaySHA256 = sha256(bytes);
                    await writeFile(join(directory, "replay-input.json"), bytes, {flag: "wx"});
                    await recordEvidence(report, directory, "replay-input.json");
                }
                await runCases(options, report, executable, replay, cancellation.signal);
            }
        }
        if (finishBudget) { const finish = finishBudget; finishBudget = undefined; await finish(); }
        report.status = "passed";
    } catch (error) {
        report.status = "failed";
        report.error = {kind: error.kind ?? "infrastructure", code: error.code ?? "error", message: error.message};
        process.exitCode = 1;
    } finally {
        if (finishBudget) {
            try { await finishBudget(); }
            catch (error) { report.status = "failed"; report.error ??= {kind: "budget", message: error.message}; process.exitCode = 1; }
        }
        report.finishedAt = new Date().toISOString();
        await atomicJSON(options.report, report);
        process.removeListener("SIGTERM", cancel); process.removeListener("SIGINT", cancel);
    }
    console.log(`Native parser fuzz ${options.phase}: ${report.status}${report.caseCounts ? ` (${report.caseCounts.executed}/${report.caseCounts.planned} cases)` : ""}; report ${options.report}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) { await main(); }
