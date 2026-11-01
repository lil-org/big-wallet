import {dirname, join, resolve} from "node:path";
import {createInterface} from "node:readline";
import {pathToFileURL} from "node:url";
import {isDeepStrictEqual} from "node:util";
import {createGunzip} from "node:zlib";
import {Readable} from "node:stream";
import {validateParserFuzzTarget} from "../validate_parser_fuzz_target.mjs";
import {CANARIES, LIMITS, PHASES, PROFILES, caseDigest, digest, finiteCount, sha256, validateCase} from "./contract.mjs";
import {planSummary, plannedCases} from "./cases.mjs";
import {asanDiagnostics} from "./process.mjs";
import {compareResult, oracleFingerprint, solanaOracle} from "./oracles.mjs";
import {validateParserSourceInventory} from "./source.mjs";
import {readStableFile} from "./evidence.mjs";
import {addressInstrumentationEnabled, canaryCompileArguments, COMPILER_RESPONSE_LIMITS, expandCompilerArguments} from "./compiler.mjs";

async function boundedRegularFile(path, limit) {
    return await readStableFile(path, limit);
}

function checkBuild(report, evidence, issues) {
    const build = report.build;
    if (!build || build.configuration !== "release" || !isDeepStrictEqual(build.sanitizers, ["address"]) ||
        !isDeepStrictEqual(build.testable, ["WalletDomain", "WalletAuthority"]) || !build.graphValidated ||
        !digest(build.binarySHA256) || !digest(build.sourceInventorySHA256) || typeof build.compiler !== "string" || !build.compiler.includes("Swift version")) {
        issues.push("Missing optimized ASan/testable build provenance"); return;
    }
    const required = ["target-graph.json", "compiler-version.txt", "build.log", "binary-location.txt", "linkage.txt", "source-inventory.json", "commands.json", "worker.bin", "fixtures.json",
        "snapshot-manifest.json", "workspace-marker.json", "source-identity.json", "resource-identity.json", "built-fixtures.json"];
    if (required.some(name => !evidence.has(name))) { issues.push("Missing build evidence"); return; }
    if (sha256(evidence.get("worker.bin")) !== build.binarySHA256 || evidence.get("compiler-version.txt").toString().trim() !== build.compiler ||
        !/libclang_rt\.asan_osx_dynamic\.dylib/.test(evidence.get("linkage.txt").toString())) { issues.push("Executable/compiler/sanitizer evidence does not match"); }
    try {
        validateParserFuzzTarget(JSON.parse(evidence.get("target-graph.json")));
        const sources = JSON.parse(evidence.get("source-inventory.json"));
        if (!Array.isArray(sources) || sources.length < 10 || new Set(sources.map(value => value.path)).size !== sources.length ||
            sources.some(value => typeof value.path !== "string" || value.path.startsWith("/") || value.path.split("/").includes("..") || !digest(value.sha256)) ||
            sha256(JSON.stringify(sources)) !== build.sourceInventorySHA256) { issues.push("Invalid source inventory"); }
        const manifest = validateParserSourceInventory(evidence.get("snapshot-manifest.json"), sources, report.sourceSHA256);
        const identity = JSON.parse(evidence.get("source-identity.json"));
        const marker = JSON.parse(evidence.get("workspace-marker.json"));
        if (identity.version !== 1 || identity.kind !== "vm-snapshot" || identity.runId !== report.runId || typeof identity.vmId !== "string" ||
            identity.source?.sha256 !== report.sourceSHA256 || identity.source.fileCount !== manifest.files.length ||
            !/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(identity.source.commit ?? "") || marker.version !== 1 || marker.runId !== identity.runId ||
            marker.vmId !== identity.vmId || !isDeepStrictEqual(marker.source, identity.source)) { issues.push("Source identity is not bound to the submitted guest workspace"); }
        const commands = JSON.parse(evidence.get("commands.json"));
        const compilation = commands.find(value => value.log === "build.log");
        if (!Array.isArray(commands) || commands.length < 5 || commands.some(value => value.status !== 0 || value.signal !== null ||
            (value.log === "resource-identity.json" ? !value.command.endsWith("/WalletParserFuzzWorker") || !isDeepStrictEqual(value.args, ["--fixture-identity"]) : value.command !== "xcrun")) ||
            !compilation || !isDeepStrictEqual(compilation.args, build.arguments)) { issues.push("Build command inventory is incomplete or failed"); }
        const resource = JSON.parse(evidence.get("resource-identity.json"));
        const fixtureSource = sources.find(value => value.path === "Packages/WalletParserFuzzHarness/Sources/WalletParserFuzzWorker/Resources/fixtures.json");
        const binaryDirectory = evidence.get("binary-location.txt").toString().trim().split(/\r?\n/).at(-1);
        const resourceCommand = commands.find(value => value.log === "resource-identity.json");
        if (resource.version !== 1 || !build.resource || typeof build.resource.path !== "string" || build.resource.path.startsWith("/") ||
            build.resource.path.split("/").some(part => !part || part === "." || part === "..") || !resource.path?.endsWith(`/${build.resource.path}`) ||
            !resource.path.startsWith(`${binaryDirectory}/`) || resourceCommand?.command !== `${binaryDirectory}/WalletParserFuzzWorker` ||
            build.resource.sha256 !== resource.sha256 || build.resource.bytes !== resource.bytes || resource.bytes !== evidence.get("built-fixtures.json").length ||
            sha256(evidence.get("built-fixtures.json")) !== resource.sha256 || fixtureSource?.sha256 !== resource.sha256 ||
            !evidence.get("built-fixtures.json").equals(evidence.get("fixtures.json"))) {
            issues.push("Built fixture bundle is not bound to the worker and submitted fixture source");
        }
        const args = build.arguments;
        if (!Array.isArray(args) || args[args.indexOf("--sanitize") + 1] !== "address" ||
            args[args.indexOf("--configuration") + 1] !== "release" || !args.includes("-enable-testing") ||
            !args.includes("--scratch-path") || args.includes("-derivedDataPath")) { issues.push("Build flags do not establish isolated optimized ASan compilation"); }
        const lines = evidence.get("build.log").toString().split(/\r?\n/).map(line => line.replace(/\\=/g, "="));
        for (const module of ["WalletDomain", "WalletAuthority", "WalletParserFuzzWorker"]) {
            if (!lines.some(line => line.includes(`-module-name ${module}`) && line.includes("-sanitize=address") && line.includes("-enable-testing"))) {
                issues.push(`No instrumented compile command for ${module}`);
            }
        }
        const responses = new Map();
        if (!Array.isArray(build.responseFiles) || build.responseFiles.length > COMPILER_RESPONSE_LIMITS.files) { throw new Error("Missing compiler response-file inventory"); }
        for (const response of build.responseFiles) {
            const bytes = evidence.get(response.artifact);
            if (typeof response.path !== "string" || response.path.startsWith("/") || response.path.split("/").some(part => !part || part === "." || part === "..") ||
                responses.has(response.path) || !bytes || bytes.length !== response.bytes || sha256(bytes) !== response.sha256) {
                throw new Error("Compiler response evidence is missing, changed, or duplicated");
            }
            responses.set(response.path, bytes);
        }
        const cache = args[args.indexOf("--scratch-path") + 1];
        const expanded = expandCompilerArguments(canaryCompileArguments(evidence.get("build.log").toString()), cache, responses);
        if (!addressInstrumentationEnabled(expanded)) { issues.push("Canary C implementation was not instrumented"); }
    } catch (error) { issues.push(`Invalid build evidence: ${error.message}`); }
}

function checkBudget(report, issues) {
    if (report.phase === "build") { return; }
    try {
        const value = report.aggregateBudget;
        if (!value || value.limitSeconds !== PROFILES[report.profile].executionSeconds || value.excludesCompilation !== true ||
            [value.beforeNanoseconds, value.phaseNanoseconds, value.afterNanoseconds].some(part => typeof part !== "string" || !/^\d+$/.test(part))) { throw new Error(); }
        const before = BigInt(value.beforeNanoseconds), elapsed = BigInt(value.phaseNanoseconds), after = BigInt(value.afterNanoseconds);
        if (elapsed <= 0n || before + elapsed !== after || after > BigInt(value.limitSeconds) * 1_000_000_000n) { throw new Error(); }
    } catch { issues.push("Aggregate execution budget is missing, inconsistent, or exceeded"); }
}

function checkCanaries(report, evidence, issues) {
    if (!Array.isArray(report.canaries) || report.canaries.length !== CANARIES.length ||
        !isDeepStrictEqual(report.canaries.map(value => value.name), CANARIES) ||
        report.caseCounts?.planned !== CANARIES.length || report.caseCounts.executed !== CANARIES.length) {
        issues.push("Canary inventory is incomplete"); return;
    }
    for (const canary of report.canaries) {
        const bytes = evidence.get(`canary-${canary.name}.log`);
        if (!bytes || canary.log !== `canary-${canary.name}.log` || canary.passed !== true) { issues.push(`Missing ${canary.name} detection evidence`); continue; }
        const observed = canary.name === "protocol" ? canary.resultStatus === "ok" && canary.accepted === false && canary.status === 0 && canary.signal === null && canary.failureKind === null
            : canary.name === "asan" ? asanDiagnostics(bytes.toString()) && canary.status !== 0
            : canary.name === "crash" ? canary.signal === "SIGABRT"
            : canary.name === "hang" ? canary.failureKind === "timeout"
            : canary.name === "rss" ? canary.failureKind === "rss" && canary.peakRSSBytes > 128 * 1_024 * 1_024
            : canary.name === "malformed" ? canary.failureKind === "protocol"
            : canary.invariant === "deliberateCanary";
        if (!observed) { issues.push(`Canary ${canary.name} did not establish its intended failure`); }
    }
}

async function checkCases(report, directory, evidence, replay, issues) {
    const expectedPlan = planSummary(report.profile, report.phase, replay);
    if (!isDeepStrictEqual(report.plan, expectedPlan)) { issues.push("Planned corpus, seeds, or counts differ from the contract"); }
    if (!evidence.has("cases.jsonl.gz") || !evidence.has("worker.log")) { issues.push("Missing case execution or worker log"); return; }
    if (asanDiagnostics(evidence.get("worker.log").toString())) { issues.push("AddressSanitizer diagnostic in parser worker log"); }
    const expected = plannedCases(report.profile, report.phase, replay);
    const counters = {planned: expectedPlan.count, executed: 0, accepted: 0, rejected: 0};
    const checks = {knownAnswers: 0, relations: 0, solanaComparisons: 0, solanaStrictnessDifferences: 0, keystoreRoundTrips: 0};
    let maximumRSS = 0;
    const compressed = Readable.from([evidence.get("cases.jsonl.gz")]);
    const expanded = createGunzip();
    let expandedBytes = 0;
    expanded.on("data", bytes => {
        expandedBytes += bytes.length;
        if (expandedBytes > LIMITS.expandedLedgerBytes) { expanded.destroy(new Error("Expanded case ledger exceeded its budget")); }
    });
    compressed.on("error", error => expanded.destroy(error));
    compressed.pipe(expanded);
    const reader = createInterface({input: expanded, crlfDelay: Infinity});
    try {
        for await (const line of reader) {
            if (!line || line.length > 32_768) { throw new Error("Invalid case ledger line"); }
            const actual = JSON.parse(line), entry = expected.next();
            if (entry.done || actual.id !== entry.value.id || actual.sha256 !== caseDigest(entry.value.candidate) ||
                actual.mode !== entry.value.candidate.mode || actual.source !== entry.value.source || actual.status !== "passed" ||
                typeof actual.accepted !== "boolean" || !finiteCount(actual.durationNanoseconds) || !finiteCount(actual.peakRSSBytes) ||
                actual.peakRSSBytes === 0 || actual.peakRSSBytes > LIMITS.rssBytes || !actual.checks ||
                ["knownAnswer", "relation", "solanaCompared", "strictnessDifference", "keystoreRoundTrip"].some(key => typeof actual.checks[key] !== "boolean")) {
                throw new Error(`Case identity, execution, or resource evidence is invalid at ${counters.executed}`);
            }
            const candidate = entry.value.candidate;
            const result = actual.result;
            if (!result || result.version !== 1 || result.id !== counters.executed || result.mode !== candidate.mode || result.status !== "ok" ||
                result.accepted !== actual.accepted || result.peakRSSBytes !== actual.peakRSSBytes || result.durationNanoseconds !== actual.durationNanoseconds) {
                throw new Error("Missing or mismatched native result evidence");
            }
            const oracle = candidate.mode === "solana" ? solanaOracle(candidate) : undefined;
            if (!isDeepStrictEqual(actual.oracle, oracleFingerprint(oracle))) { throw new Error("Recorded oracle result differs from independent recomputation"); }
            const mismatch = compareResult(candidate, result, oracle);
            if (mismatch) { throw new Error(`Retained native result fails independent comparison: ${mismatch.code}`); }
            if (candidate.expected?.accepted !== undefined && actual.accepted !== candidate.expected.accepted ||
                actual.checks.relation !== Boolean(candidate.relation) ||
                actual.checks.knownAnswer !== (Boolean(candidate.expected?.digest) || candidate.mode === "decrypt" && actual.accepted) ||
                actual.checks.keystoreRoundTrip !== (candidate.mode === "keystore" && (actual.accepted || result.strictAccepted)) ||
                actual.checks.solanaCompared !== Boolean(oracle?.accepted && result.accepted) ||
                actual.checks.strictnessDifference !== Boolean(oracle?.accepted && !result.accepted)) {
                throw new Error("Case outcome or property evidence contradicts its declared contract");
            }
            const timeout = actual.mode === "decrypt" ? LIMITS.decryptMilliseconds : LIMITS.parserMilliseconds;
            if (actual.durationNanoseconds > timeout * 1_000_000) { throw new Error("Native case exceeded its execution watchdog"); }
            counters.executed += 1; counters[actual.accepted ? "accepted" : "rejected"] += 1;
            maximumRSS = Math.max(maximumRSS, actual.peakRSSBytes);
            for (const [key, field] of [["knownAnswer", "knownAnswers"], ["relation", "relations"], ["solanaCompared", "solanaComparisons"],
                ["strictnessDifference", "solanaStrictnessDifferences"], ["keystoreRoundTrip", "keystoreRoundTrips"]]) { checks[field] += Number(actual.checks[key]); }
        }
        if (!expected.next().done || counters.executed !== expectedPlan.count) { throw new Error("Case execution inventory is incomplete"); }
    } catch (error) { issues.push(error.message); }
    finally { reader.close(); compressed.destroy(); expanded.destroy(); }
    if (!isDeepStrictEqual(report.caseCounts, counters) || !isDeepStrictEqual(report.checks, checks)) { issues.push("Reported counts do not match execution evidence"); }
    if (!report.resources || !finiteCount(report.resources.peakRSSBytes) || report.resources.peakRSSBytes < maximumRSS ||
        report.resources.peakRSSBytes > LIMITS.rssBytes || !finiteCount(report.resources.rssSamples)) { issues.push("Missing or inconsistent RSS monitoring evidence"); }
    if (report.phase === "parsers" && ["knownAnswers", "relations", "solanaComparisons", "keystoreRoundTrips"].some(key => checks[key] === 0)) {
        issues.push("Parser run did not exercise every promised oracle/property family");
    }
}

export async function auditParserFuzzEvidence(reportPath, policy) {
    const issues = [];
    let report;
    try {
        if (!policy || !PHASES.includes(policy.phase) || !Object.hasOwn(PROFILES, policy.profile) || !digest(policy.sourceSHA256) ||
            typeof policy.runId !== "string" || !policy.runId.length) { throw new Error("Invalid parser fuzz audit policy"); }
        report = JSON.parse(await boundedRegularFile(reportPath, LIMITS.reportBytes));
        if (report.status !== "passed" && report.error && typeof report.error === "object") {
            const detail = [report.error.kind, report.error.code, report.error.message].filter(value => typeof value === "string").join(": ").slice(0, 1_024);
            if (detail) { issues.push(`Runner failure: ${detail}`); }
        }
        if (report.version !== 1 || report.phase !== policy.phase || report.profile !== policy.profile || report.runId !== policy.runId ||
            report.sourceSHA256 !== policy.sourceSHA256 || report.status !== "passed" || report.coverageGuided !== false ||
            report.engine !== "seeded-structure-aware" || !isDeepStrictEqual(report.limits, LIMITS) || report.error ||
            !Array.isArray(report.failures) || report.failures.length || !Number.isFinite(Date.parse(report.startedAt)) ||
            !Number.isFinite(Date.parse(report.finishedAt)) || Date.parse(report.finishedAt) < Date.parse(report.startedAt)) {
            issues.push("Report identity, status, engine, limits, or completion is invalid");
        }
        const directory = dirname(reportPath), evidence = new Map();
        if (!Array.isArray(report.evidence) || report.evidence.length > 128) { throw new Error("Missing or oversized evidence inventory"); }
        for (const entry of report.evidence) {
            if (!entry || typeof entry.path !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(entry.path) ||
                evidence.has(entry.path) || !digest(entry.sha256) || !finiteCount(entry.bytes)) { throw new Error("Invalid or duplicate evidence entry"); }
            const limit = entry.path.endsWith(".jsonl.gz") ? LIMITS.compressedLedgerBytes : 64 * 1_024 * 1_024;
            const bytes = await boundedRegularFile(join(directory, entry.path), limit);
            if (bytes.length !== entry.bytes || sha256(bytes) !== entry.sha256) { throw new Error(`Evidence changed: ${entry.path}`); }
            evidence.set(entry.path, bytes);
        }
        checkBuild(report, evidence, issues);
        checkBudget(report, issues);
        let replay;
        if (report.phase === "replay") {
            const bytes = evidence.get("replay-input.json");
            if (!bytes || !digest(policy.replaySHA256) || report.replaySHA256 !== policy.replaySHA256 || sha256(bytes) !== policy.replaySHA256) {
                throw new Error("Replay artifact does not match the staged input identity");
            }
            const artifact = JSON.parse(bytes);
            if (artifact.version !== 1) { throw new Error("Unsupported replay input"); }
            replay = validateCase(artifact.case);
        }
        if (report.phase === "canaries") { checkCanaries(report, evidence, issues); }
        else if (report.phase !== "build") { await checkCases(report, directory, evidence, replay, issues); }
    } catch (error) { issues.push(`Parser fuzz evidence: ${error.message}`); }
    return {ok: issues.length === 0, issues, ...(report?.caseCounts ? {caseCounts: report.caseCounts} : {})};
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
    const [path, ...args] = process.argv.slice(2), policy = {};
    const names = {"--phase": "phase", "--profile": "profile", "--source-sha256": "sourceSHA256", "--run-id": "runId", "--replay-sha256": "replaySHA256"};
    for (let index = 0; index < args.length; index += 2) {
        if (!names[args[index]] || !args[index + 1]) { throw new Error("Invalid audit arguments"); }
        policy[names[args[index]]] = args[index + 1];
    }
    const result = await auditParserFuzzEvidence(resolve(path), policy);
    console.log(JSON.stringify(result, null, 2));
    if (!result.ok) { process.exitCode = 1; }
}
