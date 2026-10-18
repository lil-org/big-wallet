import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {mkdtemp, realpath, rm} from "node:fs/promises";
import {tmpdir, userInfo} from "node:os";
import {join} from "node:path";
import test from "node:test";
import {coverageReport, executeStages, preflight, requiredPrerequisites} from "../guest.mjs";
import {atomicJSON, EXCHANGE_PATH, hashFile} from "../guest_bootstrap.mjs";
import {BOOTSTRAP_TOOL_NAMES, createManifest} from "../test_manifest.mjs";

const job = signing => ({version: 1, runId: "signing-mode-fixture", vmId: "fixture-vm", kind: "doctor", profile: "all",
    payload: {stages: [], onlyTesting: [], ...(signing ? {signing} : {})},
    bootstrapTools: Object.fromEntries(BOOTSTRAP_TOOL_NAMES.map(name => [name, "c".repeat(64)])),
    source: {sha256: "a".repeat(64), commit: "b".repeat(40)}});
const success = output => ({code: 0, signal: null, output: output ?? "", timedOut: false, cancelled: false});
const proof = "A".repeat(43);
const runtimeID = platform => `com.apple.CoreSimulator.SimRuntime.${platform}-27-0`;
const provision = () => ({vmId: "fixture-vm", consoleUser: "wallet-test", xcode: {version: "27.0", buildVersion: "27A266a"},
    runtimes: [{platform: "iOS", version: "27.0", buildVersion: "24A434"}, {platform: "visionOS", version: "27.0", buildVersion: "24M362"}]});

function probe({signing, credentials = provision(), security = () => success("1 valid identities found"), proofDigest} = {}) {
    const calls = [];
    let proofReads = 0;
    return {calls, proofReads: () => proofReads, run: () => preflight({signing, workspace: "/fixture/workspace",
        identity: {aqua: true}, bootstrapEvidence: {available: true}, provision: credentials,
        readSnapshotFile: async () => { proofReads += 1; return proofDigest ?? createHash("sha256").update(proof).digest("hex"); },
        execute: async (command, args) => {
            calls.push([command, ...args]);
            if (command === "/usr/bin/security") { return security(args); }
            if (command === "node") { return success("v24.22.0"); }
            if (command === "npm") { return success("11.16.0"); }
            if (command === "python3") { return success("Python 3.14.0"); }
            if (command === "/usr/local/bin/jq") { return success("jq-1.8.1"); }
            if (command === "xcodebuild") { assert.deepEqual(args, ["-version"]); return success("Xcode 27.0\nBuild version 27A266a"); }
            if (command === "xcrun" && args[0] === "swift") { return success("Apple Swift version 6.4"); }
            if (command === "xcrun" && args.includes("devices")) {
                return success(JSON.stringify({devices: {
                    [runtimeID("iOS")]: [{name: "iPhone 18 Pro", udid: "fixture-ios", isAvailable: true}],
                    [runtimeID("xrOS")]: [{name: "Apple Vision Pro", udid: "fixture-visionos", isAvailable: true}],
                }}));
            }
            if (command === "xcrun" && args.includes("runtimes")) {
                return success(JSON.stringify({runtimes: [
                    {identifier: runtimeID("iOS"), version: "27.0", buildversion: "24A434", isAvailable: true},
                    {identifier: runtimeID("xrOS"), version: "27.0", buildversion: "24M362", isAvailable: true},
                ]}));
            }
            throw new Error(`Unexpected fixture command: ${command}`);
        }})};
}

test("default local preflight never reads credential fields, opens Keychain, or reads the production proof fingerprint", async () => {
    const credentials = provision();
    for (const name of ["keychainPath", "keychainPassword", "proofKey", "missingSigning"]) {
        Object.defineProperty(credentials, name, {get: () => { throw new Error(`Credential accessed: ${name}`); }});
    }
    const fixture = probe({credentials});
    const checked = await fixture.run();
    assert.ok(requiredPrerequisites(job()).every(name => checked.report.checks[name] === true));
    assert.equal(checked.report.signingMode, "local");
    assert.deepEqual(checked.report.capabilities, {appleSigning: "not-requested", requestProofKey: "not-requested"});
    assert.equal(checked.report.checks.signing, undefined);
    assert.equal(checked.report.checks.proofKey, undefined);
    assert.equal(checked.unlockSigning, undefined);
    assert.equal(checked.proofKey, undefined);
    assert.equal(fixture.proofReads(), 0);
    assert.ok(fixture.calls.every(call => call[0] !== "/usr/bin/security"));
    const coverage = coverageReport(job(), [], checked.report);
    assert.equal(coverage.status, "complete");
    assert.deepEqual(coverage.missingPrerequisites, []);
    assert.equal(coverage.credentialCoverage.appleDevelopmentSigning, "not-requested");
});

test("Apple mode requires its own identity and proof key instead of silently using local verification", async () => {
    const fixture = probe({signing: "apple"});
    const checked = await fixture.run();
    assert.equal(checked.report.checks.signing, false);
    assert.equal(checked.report.checks.proofKey, false);
    assert.deepEqual(checked.report.capabilities, {appleSigning: "unavailable", requestProofKey: "unavailable"});
    const coverage = coverageReport(job("apple"), [], checked.report);
    assert.equal(coverage.status, "partial");
    assert.deepEqual(coverage.missingPrerequisites, ["signing", "proofKey"]);
    assert.equal(coverage.credentialCoverage.appleDevelopmentSigning, "not-run");
});

test("Apple proof-key validation is independent of signing availability", async () => {
    for (const failure of ["identity-missing", "unlock-failed", "unlock-threw"]) {
        const fixture = probe({signing: "apple", credentials: {...provision(), proofKey: proof,
            keychainPath: join(userInfo().homedir, "Library/Keychains/fixture.keychain-db"), keychainPassword: "fixture-password"},
            security: args => {
                if (failure === "unlock-threw") { throw new Error("Fixture unlock error"); }
                if (failure === "unlock-failed") { return {...success(), code: 1}; }
                return success(args[0] === "find-identity" ? "0 valid identities found" : "");
            }});
        const checked = await fixture.run();
        assert.equal(checked.report.checks.signing, false, failure);
        assert.equal(checked.report.checks.proofKey, true, failure);
        assert.equal(checked.proofKey, proof);
        assert.deepEqual(coverageReport(job("apple"), [], checked.report).missingPrerequisites, ["signing"]);
        assert.doesNotMatch(JSON.stringify(checked.report), new RegExp(`${proof}|fixture-password`));
    }
});

test("Apple readiness checks do not claim builds, distribution signing, or OS integration passed", async () => {
    const fixture = probe({signing: "apple", credentials: {...provision(), proofKey: proof,
        keychainPath: join(userInfo().homedir, "Library/Keychains/fixture.keychain-db"), keychainPassword: "fixture-password"}});
    const checked = await fixture.run();
    assert.equal(checked.report.checks.signing, true);
    assert.equal(checked.report.checks.proofKey, true);
    assert.deepEqual(fixture.calls.filter(call => call[0] === "/usr/bin/security").map(call => call[1]), ["unlock-keychain", "find-identity"]);
    const coverage = coverageReport(job("apple"), [], checked.report);
    assert.equal(coverage.status, "complete");
    assert.deepEqual(coverage.credentialCoverage, {appleDevelopmentSigning: "not-run", productionProofResource: "not-run",
        productionDistributionSigning: "not-verified", osEntitlementIntegration: "not-verified"});
    const mismatched = await probe({signing: "apple", credentials: {...provision(), proofKey: proof}, proofDigest: "b".repeat(64)}).run();
    assert.equal(mismatched.report.checks.proofKey, false);
    assert.match(mismatched.report.proofKeyIssue, /fingerprint/);
});

test("Apple stages fail closed if the signing keychain cannot be unlocked after preflight", async () => {
    const directory = await realpath(await mkdtemp(join(tmpdir(), "big-wallet-signing-stage-")));
    try {
        const appleJob = {...job("apple"), kind: "run"};
        const manifest = createManifest(appleJob);
        const stage = {...manifest.find(stage => stage.id === "build.macos.debug"), dependencies: []};
        const checked = {checks: Object.fromEntries(stage.requirements.map(name => [name, true])), destinations: {}};
        let launches = 0;
        let unlocks = 0;
        const results = await executeStages([stage], {workspace: directory, artifacts: directory, preflight: checked,
            proofKey: proof, unlockSigning: async () => { unlocks += 1; return false; }, writeJSON: atomicJSON, hashFile,
            execute: async () => { launches += 1; return success(); }});
        assert.equal(unlocks, 1);
        assert.equal(launches, 0);
        assert.equal(results[0].status, "failed");
        assert.match(results[0].reason, /signing keychain/);
    } finally { await rm(directory, {recursive: true, force: true}); }
});

test("local native execution forwards its guest identity as build settings without credential or mode leakage to other stages", async () => {
    const directory = await realpath(await mkdtemp(join(tmpdir(), "big-wallet-local-stage-")));
    try {
        const localJob = {...job(), kind: "run"};
        const manifest = createManifest(localJob);
        const native = {...manifest.find(stage => stage.id === "build.macos.debug"), dependencies: []};
        const repository = {...manifest.find(stage => stage.id === "scripts.approval-worker-target"), dependencies: []};
        const checked = {checks: Object.fromEntries([...native.requirements, ...repository.requirements].map(name => [name, true])), destinations: {}};
        const calls = [];
        const options = {workspace: directory, artifacts: directory, preflight: checked, writeJSON: atomicJSON, hashFile,
            proofKey: "unrelated-secret", unlockSigning: async () => { throw new Error("Local mode must not unlock signing"); },
            execute: async (command, args, options) => { calls.push({command, args, env: options.env}); return success(); }};
        const results = await executeStages([native, repository], {...options, runId: localJob.runId, exchange: EXCHANGE_PATH});
        assert.deepEqual(results.map(result => result.status), ["passed", "passed"]);
        assert.ok(calls[0].args.includes(`BW_TEST_VM_RUN_ID=${localJob.runId}`));
        assert.ok(calls[0].args.includes(`BW_TEST_VM_EXCHANGE=${EXCHANGE_PATH}`));
        assert.ok(calls[0].args.includes("BW_VM_VERIFICATION_BUILD=YES"));
        assert.ok(calls[1].args.every(arg => !arg.startsWith("BW_")));
        assert.ok(calls.every(call => call.env.ALCHEMY_JWT_REQUEST_PROOF_KEY === undefined && call.env.BW_VM_VERIFICATION_BUILD === undefined));
        assert.doesNotMatch(JSON.stringify(results), /unrelated-secret/);
        const count = calls.length;
        for (const context of [{}, {runId: "../invalid", exchange: EXCHANGE_PATH}, {runId: localJob.runId, exchange: "/outside"}]) {
            const failed = await executeStages([native], {...options, ...context});
            assert.equal(failed[0].status, "failed");
            assert.match(failed[0].reason, /active guest job identity/);
            assert.equal(calls.length, count);
        }
    } finally { await rm(directory, {recursive: true, force: true}); }
});
