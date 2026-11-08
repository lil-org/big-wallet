import assert from "node:assert/strict";
import {mkdtemp, readFile, realpath, rm, symlink, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import test from "node:test";
import {gzipSync} from "node:zlib";
import {auditParserFuzzEvidence} from "./audit.mjs";
import {FIXTURES_PATH, LIMITS, caseDigest, sha256, typedDataEntryPoint} from "./contract.mjs";
import {corpus, planSummary} from "./cases.mjs";
import {graphFixture} from "./test_support.mjs";
import {oracleFingerprint, solanaOracle} from "./oracles.mjs";

async function fixture(run, phase = "build") {
    const directory = await realpath(await mkdtemp(join(tmpdir(), "parser-fuzz-audit-test-")));
    const path = join(directory, "report.json");
    const policy = {phase, profile: "all", sourceSHA256: "a".repeat(64), runId: "test-run"};
    const arguments_ = ["swift", "build", "--configuration", "release", "--scratch-path", "/cache", "--sanitize", "address", "-Xswiftc", "-enable-testing"];
    const fixtureBytes = await readFile(FIXTURES_PATH);
    const sources = [...Array.from({length: 9}, (_, index) => ({path: `Packages/WalletRuntime/Sources/WalletDomain/${index}.swift`, sha256: "b".repeat(64)})),
        {path: "Scripts/harness_package.mjs", sha256: "d".repeat(64)},
        {path: "Packages/WalletParserFuzzHarness/Sources/WalletParserFuzzWorker/Resources/fixtures.json", sha256: sha256(fixtureBytes)}].sort((a, b) => a.path.localeCompare(b.path));
    const manifest = JSON.stringify({version: 1, files: sources.map(value => ({...value, type: "file", mode: 0o644}))});
    policy.sourceSHA256 = sha256(manifest);
    const source = {sha256: policy.sourceSHA256, commit: "c".repeat(40), fileCount: sources.length};
    const binary = Buffer.from("synthetic-unit-test-binary");
    const files = {
        "target-graph.json": JSON.stringify(graphFixture()),
        "compiler-version.txt": "Apple Swift version 6.2\n",
        "build.log": ["WalletDomain", "WalletAuthority", "WalletParserFuzzWorker"].map(name => `swiftc -module-name ${name} -sanitize=address -enable-testing`).join("\n") +
            "\nclang -c /workspace/Sources/ParserFuzzCanaries/Canaries.c -fsanitize=address\n",
        "binary-location.txt": "/cache/release\n", "linkage.txt": "libclang_rt.asan_osx_dynamic.dylib\n",
        "source-inventory.json": JSON.stringify(sources), "worker.bin": binary,
        "fixtures.json": fixtureBytes,
        "built-fixtures.json": fixtureBytes,
        "resource-identity.json": JSON.stringify({version: 1, path: "/cache/release/Bundle.bundle/fixtures.json", sha256: sha256(fixtureBytes), bytes: fixtureBytes.length}),
        "snapshot-manifest.json": manifest,
        "workspace-marker.json": JSON.stringify({version: 1, runId: policy.runId, vmId: "fixture-vm", source}),
        "source-identity.json": JSON.stringify({version: 1, kind: "vm-snapshot", runId: policy.runId, vmId: "fixture-vm", source}),
        "commands.json": JSON.stringify([
            {command: "xcrun", args: ["swiftc", "--version"], log: "compiler-version.txt", status: 0, signal: null},
            {command: "xcrun", args: arguments_, log: "build.log", status: 0, signal: null},
            {command: "xcrun", args: ["swift", "build", "--show-bin-path"], log: "binary-location.txt", status: 0, signal: null},
            {command: "xcrun", args: ["otool", "-L", "/cache/worker"], log: "linkage.txt", status: 0, signal: null},
            {command: "/cache/release/WalletParserFuzzWorker", args: ["--fixture-identity"], log: "resource-identity.json", status: 0, signal: null},
        ]),
    };
    const report = {version: 1, ...policy, status: "passed", startedAt: "2026-11-01T00:00:00Z", finishedAt: "2026-11-01T00:00:01Z",
        coverageGuided: false, engine: "seeded-structure-aware", limits: LIMITS, failures: [], evidence: [],
        build: {configuration: "release", sanitizers: ["address"], testable: ["WalletDomain", "WalletAuthority"], graphValidated: true,
            compiler: "Apple Swift version 6.2", arguments: arguments_, binarySHA256: sha256(binary), sourceInventorySHA256: sha256(JSON.stringify(sources)), responseFiles: [],
            resource: {path: "release/Bundle.bundle/fixtures.json", sha256: sha256(fixtureBytes), bytes: fixtureBytes.length}}};
    if (phase === "replay") {
        const candidate = {name: "empty-object", mode: "eip712", inputBase64: Buffer.from("{}").toString("base64"), expected: {accepted: false}};
        files["replay-input.json"] = JSON.stringify({version: 1, case: candidate});
        policy.replaySHA256 = sha256(files["replay-input.json"]); report.replaySHA256 = policy.replaySHA256;
        report.aggregateBudget = {limitSeconds: 600, beforeNanoseconds: "0", phaseNanoseconds: "1", afterNanoseconds: "1", excludesCompilation: true};
        report.plan = planSummary("all", "replay", candidate);
        report.caseCounts = {planned: 1, executed: 1, accepted: 0, rejected: 1};
        report.checks = {knownAnswers: 0, relations: 0, solanaComparisons: 0, solanaStrictnessDifferences: 0, keystoreRoundTrips: 0};
        report.resources = {peakRSSBytes: 1_024, rssSamples: 0};
        files["worker.log"] = "";
        files["cases.jsonl.gz"] = JSON.stringify({id: "replay/0", sha256: caseDigest(candidate), mode: "eip712", source: "replay", status: "passed", accepted: false,
            durationNanoseconds: 1, peakRSSBytes: 1_024, checks: {knownAnswer: false, relation: false, solanaCompared: false, strictnessDifference: false, keystoreRoundTrip: false},
            result: {version: 1, id: 0, mode: "eip712", status: "ok", accepted: false, durationNanoseconds: 1, peakRSSBytes: 1_024,
                entryPoint: "PreparedEthereumTypedData"}, oracle: null}) + "\n";
    }
    async function save() {
        report.evidence = [];
        for (const [name, value] of Object.entries(files)) {
            const data = name.endsWith(".jsonl.gz") ? gzipSync(value) : Buffer.from(value); await writeFile(join(directory, name), data);
            report.evidence.push({path: name, sha256: sha256(data), bytes: data.length});
        }
        await writeFile(path, JSON.stringify(report));
    }
    try { await save(); await run({directory, path, policy, report, files, save}); }
    finally { await rm(directory, {recursive: true, force: true}); }
}

test("complete build evidence is accepted without claiming fuzz execution", async () => fixture(async ({path, policy}) => {
    const result = await auditParserFuzzEvidence(path, policy);
    assert.deepEqual(result.issues, []); assert.equal(result.ok, true); assert.equal(result.caseCounts, undefined); assert.equal(result.counts, undefined);
}));

test("auditor recognizes Xcode shell-escaped sanitizer compile flags", async () => fixture(async value => {
    value.files["build.log"] = value.files["build.log"].replaceAll("=address", "\\=address");
    await value.save();
    const result = await auditParserFuzzEvidence(value.path, value.policy);
    assert.deepEqual(result.issues, []); assert.equal(result.ok, true);
}));

test("auditor reads retained Clang response arguments and rejects sanitizer-free replacements", async () => fixture(async value => {
    value.files["build.log"] = value.files["build.log"].replace(" -fsanitize=address", " @/cache/common.args.resp");
    value.files["compiler-response-000.rsp"] = '-target arm64-apple-macos15.0 "-fsanitize=address" -O0';
    const descriptor = () => ({path: "common.args.resp", artifact: "compiler-response-000.rsp",
        sha256: sha256(value.files["compiler-response-000.rsp"]), bytes: Buffer.byteLength(value.files["compiler-response-000.rsp"])});
    value.report.build.responseFiles = [descriptor()];
    await value.save();
    let result = await auditParserFuzzEvidence(value.path, value.policy);
    assert.deepEqual(result.issues, []); assert.equal(result.ok, true);
    value.files["compiler-response-000.rsp"] = '-target arm64-apple-macos15.0 -O0';
    value.report.build.responseFiles = [descriptor()];
    await value.save();
    result = await auditParserFuzzEvidence(value.path, value.policy);
    assert.equal(result.ok, false); assert.ok(result.issues.some(issue => issue.includes("not instrumented")));
}));

test("replay audits the exact staged artifact and one exact execution", async () => fixture(async ({path, policy}) => {
    const result = await auditParserFuzzEvidence(path, policy);
    assert.deepEqual(result.issues, []); assert.equal(result.ok, true); assert.equal(result.caseCounts.executed, 1);
    assert.equal((await auditParserFuzzEvidence(path, {...policy, replaySHA256: "f".repeat(64)})).ok, false);
}, "replay"));

for (const [name, change] of [
    ["failed status", value => { value.report.status = "failed"; }],
    ["wrong source", value => { value.report.sourceSHA256 = "c".repeat(64); }],
    ["wrong run", value => { value.report.runId = "another-run"; }],
    ["unproven coverage claim", value => { value.report.coverageGuided = true; }],
    ["missing parser instrumentation", value => { value.files["build.log"] = "clang Canaries.c -fsanitize=address"; }],
    ["missing ASan runtime", value => { value.files["linkage.txt"] = "Foundation"; }],
    ["built resource differs from submitted source", value => { value.files["built-fixtures.json"] = "{}"; }],
    ["missing built resource identity", value => { delete value.files["resource-identity.json"]; }],
    ["weakened memory ceiling", value => { value.report.limits = {...LIMITS, rssBytes: 0}; }],
    ["hidden failure", value => { value.report.failures = [{}]; }],
    ["missing build log", value => { delete value.files["build.log"]; }],
    ["source inventory differs from staged manifest", value => { const entries = JSON.parse(value.files["source-inventory.json"]); entries[0].sha256 = "d".repeat(64);
        value.files["source-inventory.json"] = JSON.stringify(entries); value.report.build.sourceInventorySHA256 = sha256(JSON.stringify(entries)); }],
    ["workspace marker differs from job identity", value => { const marker = JSON.parse(value.files["workspace-marker.json"]); marker.runId = "other"; value.files["workspace-marker.json"] = JSON.stringify(marker); }],
]) {
    test(`auditor rejects ${name}`, async () => fixture(async value => {
        change(value); await value.save(); assert.equal((await auditParserFuzzEvidence(value.path, value.policy)).ok, false);
    }));
}

for (const [name, change] of [
    ["empty ledger", value => { value.files["cases.jsonl.gz"] = ""; }],
    ["duplicate case", value => { value.files["cases.jsonl.gz"] += value.files["cases.jsonl.gz"]; }],
    ["skipped case", value => { value.files["cases.jsonl.gz"] = value.files["cases.jsonl.gz"].replace('"passed"', '"skipped"'); }],
    ["mutated case identity", value => { value.files["cases.jsonl.gz"] = value.files["cases.jsonl.gz"].replace("replay/0", "replay/1"); }],
    ["zero executed count", value => { value.report.caseCounts.executed = 0; }],
    ["sanitizer error despite exit success", value => { value.files["worker.log"] = "SUMMARY: AddressSanitizer: heap-use-after-free"; }],
    ["aggregate budget overflow", value => { value.report.aggregateBudget.afterNanoseconds = "600000000001"; }],
    ["missing aggregate budget", value => { delete value.report.aggregateBudget; }],
    ["contradictory parser acceptance", value => { value.files["cases.jsonl.gz"] = value.files["cases.jsonl.gz"].replace('"accepted":false', '"accepted":true'); }],
    ["missing native result", value => { const row = JSON.parse(value.files["cases.jsonl.gz"]); delete row.result; value.files["cases.jsonl.gz"] = JSON.stringify(row) + "\n"; }],
]) {
    test(`replay auditor rejects ${name}`, async () => fixture(async value => {
        change(value); await value.save(); assert.equal((await auditParserFuzzEvidence(value.path, value.policy)).ok, false);
    }, "replay"));
}

test("auditor rejects missing, changed, and symlinked evidence", async () => fixture(async ({path, policy, directory}) => {
    await writeFile(join(directory, "worker.bin"), "changed");
    assert.equal((await auditParserFuzzEvidence(path, policy)).ok, false);
    await rm(join(directory, "worker.bin"));
    await symlink(join(directory, "build.log"), join(directory, "worker.bin"));
    assert.equal((await auditParserFuzzEvidence(path, policy)).ok, false);
    assert.equal((await auditParserFuzzEvidence(join(directory, "absent.json"), policy)).ok, false);
}));

function replaceReplay(value, candidate, result, oracle) {
    value.files["replay-input.json"] = JSON.stringify({version: 1, case: candidate});
    value.policy.replaySHA256 = sha256(value.files["replay-input.json"]);
    value.report.replaySHA256 = value.policy.replaySHA256;
    value.report.plan = planSummary("all", "replay", candidate);
    const checks = {knownAnswer: Boolean(candidate.expected?.digest), relation: Boolean(candidate.relation),
        solanaCompared: Boolean(oracle?.accepted && result.accepted), strictnessDifference: Boolean(oracle?.accepted && !result.accepted),
        keystoreRoundTrip: candidate.mode === "keystore" && (result.accepted || result.strictAccepted)};
    value.report.caseCounts = {planned: 1, executed: 1, accepted: Number(result.accepted), rejected: Number(!result.accepted)};
    value.report.checks = {knownAnswers: Number(checks.knownAnswer), relations: Number(checks.relation), solanaComparisons: Number(checks.solanaCompared),
        solanaStrictnessDifferences: Number(checks.strictnessDifference), keystoreRoundTrips: Number(checks.keystoreRoundTrip)};
    const native = {version: 1, id: 0, mode: candidate.mode, status: "ok", durationNanoseconds: 1, peakRSSBytes: 1_024,
        ...(candidate.mode === "eip712" ? {entryPoint: typedDataEntryPoint(candidate)} : {}), ...result};
    value.files["cases.jsonl.gz"] = JSON.stringify({id: "replay/0", sha256: caseDigest(candidate), mode: candidate.mode, source: "replay", status: "passed",
        accepted: native.accepted, durationNanoseconds: 1, peakRSSBytes: 1_024, checks, result: native, oracle: oracleFingerprint(oracle)}) + "\n";
}

test("auditor requires a strict-reader result even for unlabeled rejected keystore input", async () => fixture(async value => {
    const candidate = {name: "unlabeled-empty", mode: "keystore", inputBase64: ""};
    replaceReplay(value, candidate, {accepted: false, strictAccepted: false});
    await value.save();
    assert.equal((await auditParserFuzzEvidence(value.path, value.policy)).ok, true);
    const row = JSON.parse(value.files["cases.jsonl.gz"]); delete row.result.strictAccepted;
    value.files["cases.jsonl.gz"] = JSON.stringify(row) + "\n";
    await value.save();
    const result = await auditParserFuzzEvidence(value.path, value.policy);
    assert.equal(result.ok, false); assert.ok(result.issues.some(issue => issue.includes("keystoreStrictResult")));
}, "replay"));

test("auditor verifies user-rejected stored-accepted keys and their round-trip accounting", async () => fixture(async value => {
    const candidate = corpus("keystore").find(candidate => candidate.name === "pbkdf2-2000000-32-1");
    replaceReplay(value, candidate, {accepted: false, strictAccepted: true, rejection: "limitExceeded"});
    await value.save();
    assert.equal(value.report.checks.keystoreRoundTrips, 1);
    assert.equal((await auditParserFuzzEvidence(value.path, value.policy)).ok, true);
    replaceReplay(value, candidate, {accepted: false, strictAccepted: false, rejection: "limitExceeded"});
    await value.save();
    const result = await auditParserFuzzEvidence(value.path, value.policy);
    assert.equal(result.ok, false); assert.ok(result.issues.some(issue => issue.includes("strictAccepted")));
}, "replay"));

test("auditor catches a bypassed digest comparator even after all artifact hashes are recomputed", async () => fixture(async value => {
    const candidate = corpus("eip712")[0];
    replaceReplay(value, candidate, {accepted: true, digest: candidate.expected.digest});
    await value.save();
    assert.equal((await auditParserFuzzEvidence(value.path, value.policy)).ok, true);
    const row = JSON.parse(value.files["cases.jsonl.gz"]); row.result.digest = "0".repeat(64);
    value.files["cases.jsonl.gz"] = JSON.stringify(row) + "\n";
    await value.save();
    const result = await auditParserFuzzEvidence(value.path, value.policy);
    assert.equal(result.ok, false); assert.ok(result.issues.some(issue => issue.includes("independent comparison")));
}, "replay"));

test("auditor recomputes the Solana oracle rather than trusting passed labels and fingerprints", async () => fixture(async value => {
    const candidate = corpus("solana")[0], oracle = solanaOracle(candidate);
    assert.equal(oracle.accepted, true);
    replaceReplay(value, candidate, {accepted: true, summary: oracle.summary}, oracle);
    await value.save();
    assert.equal((await auditParserFuzzEvidence(value.path, value.policy)).ok, true);
    const row = JSON.parse(value.files["cases.jsonl.gz"]); row.result.summary.requiredSignatures += 1;
    value.files["cases.jsonl.gz"] = JSON.stringify(row) + "\n";
    await value.save();
    const result = await auditParserFuzzEvidence(value.path, value.policy);
    assert.equal(result.ok, false); assert.ok(result.issues.some(issue => issue.includes("normalizedMessage")));
}, "replay"));

test("failed audit retains a bounded original runner diagnostic", async () => fixture(async value => {
    value.report.status = "failed";
    value.report.error = {kind: "timeout", code: "timeout", message: "original pipe watchdog " + "x".repeat(5000)};
    await value.save();
    const result = await auditParserFuzzEvidence(value.path, value.policy);
    assert.equal(result.ok, false);
    assert.ok(result.issues[0].startsWith("Runner failure: timeout: timeout: original pipe watchdog"));
    assert.ok(result.issues[0].length < 1100);
}));
