import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {chmod, mkdtemp, mkdir, readFile, readdir, realpath, rm, symlink, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import test from "node:test";
import {auditNativeResult, auditResults, performanceTestName} from "../result_audit.mjs";
import {chooseDestinations, cleanEnvironment, coverageReport, executeStages, pendingStageResults, pinnedEnvironmentEvidence, prepareStageScratch, resourceSnapshot} from "../guest.mjs";
import {atomicJSON, hashFile, BUILD_VOLUME, EXCHANGE_PATH, materializeSource, provisioningEvidence, readGuestProvision, bootstrapToolsEvidence, validateGuestEvidence, validateSnapshotManifest, verifyBuildVolume, verifyExchangeDirectory} from "../guest_bootstrap.mjs";
import {approvalArguments, commandForStage, createManifest, PERFORMANCE_ENV, PERFORMANCE_TESTS, PLATFORMS, SHELL_TESTS, TSAN_TESTS, EXTENDED_TSAN_TESTS, BOOTSTRAP_TOOL_NAMES, validateJob} from "../test_manifest.mjs";

const digest = data => createHash("sha256").update(data).digest("hex");
const job = ({payload, ...overrides} = {}) => ({version: 1, runId: "2026-10-13-test", vmId: "fixture-vm", kind: "run", profile: "all", payload: {stages: [], onlyTesting: [], ...payload},
    bootstrapTools: Object.fromEntries(BOOTSTRAP_TOOL_NAMES.map(name => [name, "c".repeat(64)])),
    source: {sha256: "a".repeat(64), commit: "b".repeat(40)}, ...overrides});
const fixture = async fn => {
    const root = await realpath(await mkdtemp(join(tmpdir(), "big-wallet-guest-unit-")));
    try { return await fn(root); } finally { await rm(root, {recursive: true, force: true}); }
};

test("provisioning attestation projects only the applied request and guest account", () => {
    const identity = {vmId: "fixture-vm", consoleUser: "wallet-test"};
    const requestID = "12345678-1234-1234-1234-123456789abc";
    const provision = {...identity, appliedProvisioningRequestID: requestID, proofKey: "private-proof", keychainPassword: "private-password"};
    assert.deepEqual(provisioningEvidence(provision), {...identity, appliedRequestID: requestID});
    assert.deepEqual(provisioningEvidence(identity), {...identity, appliedRequestID: null});
    for (const appliedProvisioningRequestID of [null, 1, {}, "", "../other", "not-a-receipt"]) {
        assert.throws(() => provisioningEvidence({...identity, appliedProvisioningRequestID}), /receipt is invalid/);
    }
});

test("provisioning reader rejects shared, writable, or redirected state before reading secrets", async () => {
    const identity = {vmId: "fixture-vm", consoleUser: "tester"};
    const provision = {version: 1, ...identity, workspacePath: `${BUILD_VOLUME}/Workspaces/tester/big-wallet`};
    const parent = {uid: 0, mode: 0o700, isDirectory: () => true, isSymbolicLink: () => false};
    const file = {uid: 0, mode: 0o640};
    let reads = 0;
    const options = (directory = parent, metadata = file) => ({
        inspect: async path => path === "/guest/state" ? directory : metadata,
        read: async () => { reads++; return JSON.stringify(provision); },
    });
    assert.deepEqual(await readGuestProvision(identity, "/guest/state/provisioning.json", options()), provision);
    assert.equal(reads, 1);
    for (const change of [{uid: 501}, {mode: 0o750}, {mode: 0o770}, {isDirectory: () => false}, {isSymbolicLink: () => true}]) {
        await assert.rejects(readGuestProvision(identity, "/guest/state/provisioning.json", options({...parent, ...change})), /directory is not private/);
    }
    for (const change of [{uid: 501}, {mode: 0o660}, {mode: 0o644}]) {
        await assert.rejects(readGuestProvision(identity, "/guest/state/provisioning.json", options(parent, {...file, ...change})), /permissions are not private/);
    }
    assert.equal(reads, 1);
});
const nativeTree = cases => ({testNodes: [{name: "Tests macOS", nodeType: "Test Plan", children: cases.map(([name, result]) => ({name, nodeIdentifier: name, nodeType: "Test Case", result}))}]});
const summary = (passed, skipped = 0, failed = 0) => ({totalTestCount: passed + skipped + failed, passedTests: passed, skippedTests: skipped, failedTests: failed});
const success = output => ({code: 0, signal: null, output: output ?? "", timedOut: false, cancelled: false});
const passedManifest = manifest => manifest.map(stage => ({id: stage.id, status: "passed",
    ...(stage.nativeAudit ? {nativeAudit: stage.nativeAudit} : {}),
    ...(stage.approvalAudit ? {approvalAudit: stage.approvalAudit} : {}),
    ...(stage.nativeAudit?.runtime || stage.approvalAudit ? {audit: {ok: true}} : {}),
    ...(stage.nativeAudit?.kind === "safari" ? {audit: {ok: true, safari: {ok: true}, safariLog: {ok: true}}} : {})}));

test("job validation admits the host snapshot contract and rejects execution injection", () => {
    assert.deepEqual(validateJob(job({source: {...job().source, fileCount: 4, bytes: 100}})).source.fileCount, 4);
    assert.throws(() => validateJob(job({kind: "doctor", source: undefined})));
    for (const invalid of [
        {version: 2}, {kind: "deploy"}, {profile: "fast"}, {runId: "../escape"}, {vmId: ""}, {bootstrapTools: {}},
        {payload: {stages: ["deploy"]}}, {payload: {stages: ["test", "test"]}}, {payload: {configuration: "AdHoc"}}, {unknown: true},
        {payload: {onlyTesting: ["Class/test;rm"]}}, {payload: {onlyTesting: ["-skip-testing:Class"]}}, {source: {sha256: "a", commit: "b"}},
        {payload: {approvalArgs: ["--worker", "/bin/sh"]}}, {payload: {approvalArgs: ["--failure-dir", "/tmp/elsewhere"]}}, {payload: {approvalArgs: ["--seed", "no"]}},
        {payload: {unknown: true}}, {payload: {signing: "automatic"}}, {payload: {signing: null}},
    ]) { assert.throws(() => validateJob(job(invalid)), JSON.stringify(invalid)); }
    for (const payload of [undefined, null, [], 1, "options", {}]) {
        assert.throws(() => validateJob({...job(), payload}));
    }
    assert.doesNotThrow(() => validateJob(job({payload: {approvalArgs: ["--soak", "--seed", "42", "--mode", "popup"]}})));
    assert.doesNotThrow(() => validateJob(job({payload: {onlyTesting: ["Tests macOS/PasswordStorageTests/testSetup()", "SecretHandlingTests"]}})));
    for (const signing of ["local", "apple"]) { assert.equal(validateJob(job({payload: {signing}})).payload.signing, signing); }
});

test("hardware guard cannot be enabled with environment variables or a physical hypervisor", () => {
    const evidence = {identity: {version: 1, vmId: "fixture-vm", consoleUser: "tester"}, identityOwner: 0, identityMode: 0o640,
        platform: "darwin", uid: 501, consoleUid: 501, model: "VirtualMac2,1", hypervisor: "1", aqua: true, username: "tester"};
    assert.equal(validateGuestEvidence(evidence, "fixture-vm").vmId, "fixture-vm");
    for (const change of [{model: "Mac16,1"}, {identityOwner: 501}, {identityMode: 0o666}, {consoleUid: 0}, {uid: 0},
        {aqua: false}, {platform: "linux"}, {username: "other"}, {identity: {version: 1, vmId: "another", consoleUser: "tester"}}]) {
        assert.throws(() => validateGuestEvidence({...evidence, ...change}, "fixture-vm"));
    }
});

test("environment drops host credentials and proof material until a native stage explicitly requests it", () => {
    const env = cleanEnvironment({PATH: "/fixture/bin", HOME: "/Users/fixture", USER: "fixture", ALCHEMY_JWT_REQUEST_PROOF_KEY: "secret",
        CLOUDFLARE_API_TOKEN: "secret", APP_STORE_CONNECT_API_KEY: "secret", BW_TEST_VM_EXCHANGE: "/bypass", NODE_OPTIONS: "--require exploit"});
    assert.equal(env.PATH, "/fixture/bin");
    assert.equal(env.ALCHEMY_JWT_REQUEST_PROOF_KEY, undefined);
    assert.equal(env.CLOUDFLARE_API_TOKEN, undefined);
    assert.equal(env.NODE_OPTIONS, undefined);
    assert.equal(env.BW_TEST_VM_EXCHANGE, undefined);
    assert.equal(env.WRANGLER_SEND_METRICS, "false");
});

test("resource snapshots retain contention measurements without external processes", () => {
    const snapshot = resourceSnapshot({now: () => "fixture-time", cpuCount: () => 4, availableCPUs: () => 4,
        totalMemory: () => 8 * 1024 ** 3, freeMemory: () => 2 * 1024 ** 3, loadAverage: () => [3, 2, 1]});
    assert.deepEqual(snapshot, {recordedAt: "fixture-time", available: true, logicalCPUCount: 4, availableCPUCount: 4,
        totalMemoryBytes: 8 * 1024 ** 3, freeMemoryBytes: 2 * 1024 ** 3,
        loadAverage: {oneMinute: 3, fiveMinutes: 2, fifteenMinutes: 1}, oneMinuteLoadPerCPU: 0.75});
    assert.deepEqual(resourceSnapshot({now: () => "fixture-time", cpuCount: () => { throw new Error("unavailable"); }}), {recordedAt: "fixture-time", available: false});
});

test("all matrix includes every native configuration/platform and all repository suites", () => {
    const stages = createManifest(job());
    const ids = new Set(stages.map(stage => stage.id));
    for (const platform of PLATFORMS) {
        for (const configuration of ["debug", "release"]) {
            for (const prefix of ["build", "build-tests", "test"]) { assert.ok(ids.has(`${prefix}.${platform.id}.${configuration}`)); }
        }
    }
    for (const file of SHELL_TESTS) {
        const stage = stages.find(stage => stage.args.includes(`Scripts/tests/${file}`));
        assert.ok(stage);
        assert.ok(stage.requirements.includes("jq"));
    }
    for (const id of ["provider.test", "provider.bundle", "protocol.check", "pins.check", "scripts.approval-worker-target", "metadata.localizations", "runner.node-tests", "runner.python-tests", "safari.runner-tests",
        "worker.check", "worker.test", "worker.validate-self", "worker.validate-dry-run", "worker.deploy-dry-run", "worker.startup", "performance.release",
        "tsan.focused", "fuzz.default", "fuzz.regressions", "approval.debug", "approval.release"]) { assert.ok(ids.has(id), id); }
    assert.equal(stages.length, ids.size);
    for (const [index, stage] of stages.entries()) {
        for (const dependency of stage.dependencies) { assert.ok(stages.slice(0, index).some(prior => prior.id === dependency), `${stage.id}: ${dependency}`); }
    }
});

test("selected runs report partial coverage without unrelated credential prerequisites", () => {
    const stages = [{id: "worker.test", status: "passed"}];
    const preflight = {checks: {node: true, bootstrap: true, xcode: true, proofKey: false, signing: false}};
    const selected = coverageReport(job({payload: {stages: ["worker"]}}), stages, preflight);
    assert.equal(selected.scope, "selected");
    assert.equal(selected.status, "partial");
    assert.equal(selected.fullSuiteVerified, false);
    assert.deepEqual(selected.missingPrerequisites, []);
    assert.equal(selected.signingMode, "local");
    assert.equal(selected.credentialCoverage.appleDevelopmentSigning, "not-requested");
    const incomplete = coverageReport(job(), [...stages, {id: "test.macos.debug", status: "blocked"}], preflight);
    assert.equal(incomplete.scope, "full");
    assert.equal(incomplete.status, "partial");
    assert.ok(incomplete.incompleteStages.some(stage => stage.id === "test.macos.debug" && stage.status === "blocked"));
    assert.ok(incomplete.incompleteStages.some(stage => stage.status === "not-run"));
    const manifest = createManifest(job());
    const checks = Object.fromEntries(manifest.flatMap(stage => stage.requirements).map(name => [name, true]));
    assert.equal(coverageReport(job(), stages, {checks}).fullSuiteVerified, false);
    const complete = coverageReport(job(), passedManifest(manifest), {checks});
    assert.equal(complete.fullSuiteVerified, true);
    assert.equal(complete.executionMode, "unattended");
});

test("a fully passing unfiltered assisted run does not establish the unattended matrix", () => {
    const selectedJob = job({payload: {interactiveSafari: true}});
    const manifest = createManifest(selectedJob);
    const stages = passedManifest(manifest);
    const checks = Object.fromEntries(manifest.flatMap(stage => stage.requirements).map(name => [name, true]));
    const coverage = coverageReport(selectedJob, stages, {checks});
    assert.equal(auditResults(stages).status, "passed");
    assert.equal(coverage.scope, "full");
    assert.equal(coverage.executionMode, "assisted");
    assert.equal(coverage.status, "partial");
    assert.equal(coverage.fullSuiteVerified, false);
    assert.equal(coverage.safari.status, "passed");
    assert.equal(coverage.safari.unattended, "not-established");
    assert.ok(coverage.safari.stages.every(stage => stage.status === "passed" && stage.audited));
    assert.deepEqual(coverage.incompleteStages, []);
    assert.deepEqual(coverage.missingPrerequisites, []);
});

test("local and Apple modes retain the complete same test workload with explicit signing settings", () => {
    for (const profile of ["all", "extended"]) {
        for (const configuration of [undefined, "Debug"]) {
            const local = createManifest(job({profile, payload: {configuration}}));
            const explicitLocal = createManifest(job({profile, payload: {configuration, signing: "local"}}));
            const apple = createManifest(job({profile, payload: {configuration, signing: "apple"}}));
            assert.deepEqual(local, explicitLocal);
            assert.deepEqual(local.map(stage => stage.id), apple.map(stage => stage.id));
            for (const stage of local) {
                const signed = apple.find(candidate => candidate.id === stage.id);
                if (stage.args[0] === "Scripts/safari/run.mjs") {
                    assert.equal(stage.args[stage.args.indexOf("--signing") + 1], "local");
                    assert.equal(signed.args[signed.args.indexOf("--signing") + 1], "apple");
                    assert.deepEqual(stage.nativeAudit?.requiredTests, signed.nativeAudit?.requiredTests);
                    assert.deepEqual(stage.nativeAudit?.requiredScenarios, signed.nativeAudit?.requiredScenarios);
                    assert.equal(stage.nativeAudit?.iterations, signed.nativeAudit?.iterations);
                    assert.equal(stage.timeoutSeconds, signed.timeoutSeconds);
                    assert.ok(!stage.requirements.includes("signing") && !stage.requirements.includes("proofKey"));
                    continue;
                }
                assert.deepEqual(stage.nativeAudit, signed.nativeAudit);
                assert.equal(stage.timeoutSeconds, signed.timeoutSeconds);
                assert.deepEqual(stage.env, signed.env);
                if (stage.command !== "xcodebuild") { assert.deepEqual(stage, signed); continue; }
                assert.equal(stage.proofKey, undefined);
                assert.ok(!stage.requirements.includes("proofKey"));
                assert.ok(!stage.requirements.includes("signing"));
                if (stage.cwd === "Packages/WalletRuntime") {
                    assert.ok(signed.args.includes("CODE_SIGN_IDENTITY=-"));
                    assert.ok(signed.args.includes("CODE_SIGN_STYLE=Manual"));
                    assert.equal(signed.proofKey, undefined);
                    assert.ok(!signed.requirements.includes("proofKey") && !signed.requirements.includes("signing"));
                    assert.deepEqual(stage.args.filter(arg => arg.startsWith("-only-testing:")), signed.args.filter(arg => arg.startsWith("-only-testing:")));
                    continue;
                }
                for (const setting of ["CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "PROVISIONING_PROFILE=",
                    "PROVISIONING_PROFILE_SPECIFIER=", "CODE_SIGN_ENTITLEMENTS=", "ENABLE_APP_SANDBOX=NO",
                    "ENABLE_HARDENED_RUNTIME=NO", "REGISTER_APP_GROUPS=NO", "BW_VM_VERIFICATION_BUILD=YES"]) {
                    assert.ok(stage.args.includes(setting), `${stage.id}: ${setting}`);
                    assert.ok(!signed.args.includes(setting), `${signed.id}: production override ${setting}`);
                }
                const device = stage.args.includes("generic/platform=iOS") || stage.args.includes("generic/platform=visionOS");
                assert.deepEqual(stage.args.filter(arg => arg.startsWith("CODE_SIGNING_ALLOWED=")), [`CODE_SIGNING_ALLOWED=${device ? "NO" : "YES"}`]);
                assert.deepEqual(stage.args.filter(arg => arg.startsWith("-only-testing:")), signed.args.filter(arg => arg.startsWith("-only-testing:")));
                if (stage.args.includes("test-without-building")) { continue; }
                assert.equal(signed.proofKey, true, signed.id);
                assert.ok(signed.requirements.includes("proofKey"), signed.id);
                if (stage.args.includes("generic/platform=macOS") || stage.args.includes("$destination:macos")) {
                    assert.ok(signed.requirements.includes("signing"), signed.id);
                }
            }
        }
    }
});

test("complete local coverage never implies Apple, production credential, or entitlement integration coverage", () => {
    const localJob = job();
    const manifest = createManifest(localJob);
    const checks = {...Object.fromEntries(manifest.flatMap(stage => stage.requirements).map(name => [name, true])), signing: false, proofKey: false};
    const stages = passedManifest(manifest);
    const local = coverageReport(localJob, stages, {checks});
    assert.equal(local.status, "complete");
    assert.equal(local.fullSuiteVerified, true);
    assert.deepEqual(local.missingPrerequisites, []);
    assert.deepEqual(local.credentialCoverage, {appleDevelopmentSigning: "not-requested", productionProofResource: "not-requested",
        productionDistributionSigning: "not-verified", osEntitlementIntegration: "not-verified"});
    const appleJob = job({payload: {signing: "apple"}});
    const unavailable = coverageReport(appleJob, stages, {checks});
    assert.equal(unavailable.fullSuiteVerified, false);
    assert.deepEqual(new Set(unavailable.missingPrerequisites), new Set(["proofKey", "signing"]));
    assert.equal(unavailable.credentialCoverage.appleDevelopmentSigning, "incomplete");
    assert.equal(unavailable.credentialCoverage.productionProofResource, "incomplete");
    const apple = coverageReport(appleJob, stages, {checks: {...checks, signing: true, proofKey: true}});
    assert.equal(apple.fullSuiteVerified, true);
    assert.equal(apple.credentialCoverage.appleDevelopmentSigning, "passed");
    assert.equal(apple.credentialCoverage.productionProofResource, "passed");
    assert.equal(apple.credentialCoverage.productionDistributionSigning, "not-verified");
    assert.equal(apple.credentialCoverage.osEntitlementIntegration, "not-verified");
    assert.equal(coverageReport(appleJob, stages.filter(stage => stage.id !== "build.macos.release"),
        {checks: {...checks, signing: true, proofKey: true}}).credentialCoverage.appleDevelopmentSigning, "incomplete");
});

test("native stages retain audited result bundles without long-running system diagnostics", () => {
    for (const profile of ["all", "extended"]) {
        for (const signing of ["local", "apple"]) {
            for (const configuration of [undefined, "Debug", "Release"]) {
                const manifest = createManifest(job({profile, payload: {signing, configuration}}));
                for (const stage of manifest) {
                    if (!stage.nativeAudit) {
                        assert.ok(!stage.args.includes("-collect-test-diagnostics"), stage.id);
                        continue;
                    }
                    if (stage.nativeAudit.kind === "safari") {
                        assert.equal(stage.command, "node");
                        assert.equal(stage.args[0], "Scripts/safari/run.mjs");
                        assert.equal(stage.nativeAudit.configuration, stage.args[stage.args.indexOf("--configuration") + 1]);
                        assert.equal(stage.resultBundle, true);
                        assert.equal(stage.scratchDirectory, true);
                        const command = commandForStage(stage, {destinations: {macos: "macos", ios: "ios"}, artifacts: "/artifacts", scratch: "/scratch/stage"});
                        assert.equal(command.args[command.args.indexOf("-resultBundlePath") + 1], `/artifacts/${stage.id}.xcresult`);
                        continue;
                    }
                    assert.equal(stage.args.filter(arg => arg === "-collect-test-diagnostics").length, 1, stage.id);
                    assert.equal(stage.args[stage.args.indexOf("-collect-test-diagnostics") + 1], "never", stage.id);
                    assert.equal(stage.resultBundle, true, stage.id);
                    assert.equal(stage.nativeAudit.configuration, stage.args[stage.args.indexOf("-configuration") + 1], stage.id);
                    assert.equal(stage.nativeAudit.kind, stage.group === "test" ? "full" : stage.group, stage.id);
                    assert.equal(stage.timeoutSeconds, stage.group === "tsan" ? 14400 : 7200, stage.id);
                    const command = commandForStage(stage, {destinations: {macos: "macos", ios: "ios", visionos: "visionos"}, artifacts: "/artifacts"});
                    assert.equal(command.args[command.args.indexOf("-resultBundlePath") + 1], `/artifacts/${stage.id}.xcresult`, stage.id);
                }
            }
        }
    }
});

test("all matrix never invokes live deployment, account mutation, or custom DerivedData", () => {
    for (const stage of createManifest(job({profile: "extended"}))) {
        assert.ok(stage.requirements.includes("bootstrap"));
        const text = JSON.stringify([stage.command, stage.args]);
        assert.doesNotMatch(text, /derivedDataPath|allowProvisioningUpdates|Scripts\/asc\/(?:publish|bump|submit)|"rollout"|"upload:validated"|"verify:release"|"validate:keypair"/);
        if (stage.args.includes("validate:live")) { assert.ok(stage.args.includes("--dry-run")); }
        if (text.includes("deploy")) { assert.ok(stage.args.includes("deploy:dry-run")); }
        if (stage.proofKey) { assert.equal(stage.command, "xcodebuild"); }
    }
});

test("runner fixtures declare their helper compiler and manifest interpreter", () => {
    const stages = createManifest(job({payload: {stages: ["repository"]}}));
    assert.deepEqual(stages.find(stage => stage.id === "runner.node-tests").requirements, ["bootstrap", "node", "xcode"]);
    assert.deepEqual(stages.find(stage => stage.id === "runner.python-tests").requirements, ["bootstrap", "python", "node"]);
    assert.deepEqual(stages.find(stage => stage.id === "safari.runner-tests").args, ["--test", "Scripts/safari/tests/*.test.mjs"]);
    assert.deepEqual(stages.find(stage => stage.id === "safari.runner-tests").dependencies, ["provider.install"]);
});

test("installed runner evidence fails stale, missing, or user-writable guest tools", async () => {
    const expected = job().bootstrapTools;
    const inspect = async () => ({uid: 0, mode: 0o755, isFile: () => true, isSymbolicLink: () => false});
    assert.equal((await bootstrapToolsEvidence(expected, {inspect, hash: async () => "c".repeat(64)})).available, true);
    const stale = await bootstrapToolsEvidence(expected, {inspect, hash: async path => path.endsWith("guest_bootstrap.mjs") ? "d".repeat(64) : "c".repeat(64)});
    assert.equal(stale.available, false);
    assert.deepEqual(stale.mismatched, ["guest_bootstrap.mjs"]);
    const writable = await bootstrapToolsEvidence(expected, {inspect: async () => ({...await inspect(), mode: 0o777}), hash: async () => "c".repeat(64)});
    assert.equal(writable.available, false);
    assert.equal(writable.missing.length, BOOTSTRAP_TOOL_NAMES.length);
});

test("extended matrix retains baseline checks and adds bounded seeds, soak, and broader TSan", () => {
    const basic = createManifest(job());
    const extended = createManifest(job({profile: "extended"}));
    for (const stage of basic) { assert.ok(extended.some(candidate => candidate.id === stage.id)); }
    for (const seed of [42, 20261013, 3735928559]) {
        const fuzz = extended.find(stage => stage.id === `fuzz.seed-${seed}`);
        assert.ok(fuzz.args.includes("20000"));
    }
    const tsan = extended.filter(stage => stage.id.startsWith("tsan.extended"));
    for (const name of EXTENDED_TSAN_TESTS) { assert.ok(tsan.some(stage => stage.args.some(arg => arg === `-only-testing:Tests macOS/${name}` || arg.includes(`/${name}/`)))); }
    for (const config of ["debug", "release"]) {
        assert.equal(basic.find(stage => stage.id === `approval.${config}`).timeoutSeconds, 7200);
        assert.equal(extended.find(stage => stage.id === `approval.${config}`).timeoutSeconds, 7200);
        const soak = extended.find(stage => stage.id === `approval.soak-${config}`);
        assert.ok(soak.args.includes("--soak"));
        assert.equal(soak.timeoutSeconds, 21600);
    }
    for (const name of TSAN_TESTS) { assert.ok(extended.filter(stage => stage.id.startsWith("tsan.focused")).some(stage => stage.args.some(arg => arg === `-only-testing:Tests macOS/${name}` || arg.includes(`/${name}/`)))); }
    assert.deepEqual(extended.find(stage => stage.id === "performance.release").env, PERFORMANCE_ENV);
});

test("explicit approval soaks use the six-hour budget without adding duplicate workloads", () => {
    const approvalArgs = ["--soak", "--seed", "42", "--no-minimize"];
    for (const profile of ["all", "extended"]) {
        for (const configuration of ["Debug", "Release"]) {
            const stages = createManifest(job({profile, payload: {configuration, stages: ["approval"], approvalArgs}}))
                .filter(stage => stage.group === "approval");
            assert.equal(stages.length, 1);
            assert.equal(stages[0].id, `approval.${configuration.toLowerCase()}`);
            assert.deepEqual(stages[0].args, ["Scripts/check_approval_lifecycle.sh", ...approvalArguments(approvalArgs)]);
            assert.equal(stages[0].timeoutSeconds, 21600);
        }
    }
});

test("diagnostics-only approval arguments retain the extended workload and reach both configurations", () => {
    const baseline = createManifest(job({profile: "extended", payload: {stages: ["approval"]}}));
    for (const approvalArgs of [["--no-minimize"], ["--no-minimize", "--no-minimize"]]) {
        const stages = createManifest(job({profile: "extended", payload: {stages: ["approval"], approvalArgs}}));
        assert.deepEqual(stages.map(stage => stage.id), baseline.map(stage => stage.id));
        for (const configuration of ["debug", "release"]) {
            assert.deepEqual(stages.find(stage => stage.id === `approval.${configuration}`).args,
                ["Scripts/check_approval_lifecycle.sh", ...approvalArguments(approvalArgs)]);
            const soak = stages.find(stage => stage.id === `approval.soak-${configuration}`);
            assert.deepEqual(soak.args, ["Scripts/check_approval_lifecycle.sh", "--soak", "--seed", "42", "--systematic", "off", ...approvalArgs]);
            assert.deepEqual(soak.dependencies, [`approval.${configuration}`]);
        }
    }
});

test("custom approval workloads and replays still replace the default extended soaks", () => {
    for (const override of [["--soak"], ["--seed", "7"], ["--sequences", "1"], ["--steps", "20"],
        ["--timeout-ms", "5000"], ["--mode", "native"], ["--random-only"], ["--replay", "/fixture/replay.json"]]) {
        for (const approvalArgs of [override, [...override, "--no-minimize"]]) {
            const stages = createManifest(job({profile: "extended", payload: {stages: ["approval"], approvalArgs}}));
            assert.ok(!stages.some(stage => stage.id.startsWith("approval.soak-")));
            for (const configuration of ["debug", "release"]) {
                assert.deepEqual(stages.find(stage => stage.id === `approval.${configuration}`).args,
                    ["Scripts/check_approval_lifecycle.sh", ...approvalArguments(approvalArgs)]);
            }
        }
    }
    const ordinary = createManifest(job({payload: {stages: ["approval"], approvalArgs: ["--no-minimize"]}}));
    assert.ok(!ordinary.some(stage => stage.id.startsWith("approval.soak-")));
});

test("narrow test selection expands required builds but does not schedule unrelated suites", () => {
    const stages = createManifest(job({payload: {stages: ["test"], configuration: "Debug", onlyTesting: ["Tests macOS/WindowAuthenticationSessionTests"]}}));
    const ids = stages.map(stage => stage.id);
    assert.ok(ids.includes("test.macos.debug"));
    assert.ok(ids.includes("build-tests.macos.debug"));
    assert.ok(ids.includes("provider.install"));
    assert.ok(ids.includes("provider.test"));
    assert.ok(!ids.includes("test.ios.debug"));
    assert.ok(!ids.includes("build-tests.ios.debug"));
    assert.ok(!ids.includes("worker.test"));
    const stage = stages.find(stage => stage.id === "test.macos.debug");
    assert.ok(stage.args.includes("-only-testing:Tests macOS/WindowAuthenticationSessionTests"));
});

test("unqualified setup selectors run available classes across all three platforms", () => {
    const stages = createManifest(job({payload: {stages: ["test"], configuration: "Debug", onlyTesting: ["WindowAuthenticationSessionTests", "PasswordStorageTests", "SecretHandlingTests"]}}));
    for (const platform of PLATFORMS) {
        const stage = stages.find(stage => stage.id === `test.${platform.id}.debug`);
        assert.ok(stage.args.includes(`-only-testing:${platform.target}/PasswordStorageTests`));
    }
});

test("full Debug test selections retain a Release performance run for skipped-gate accounting", () => {
    const stages = createManifest(job({payload: {stages: ["test"], configuration: "Debug"}}));
    assert.ok(stages.some(stage => stage.id === "performance.release"));
});

test("destination selection uses installed runtimes and exact simulator UUIDs", () => {
    const devices = {devices: {
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [{name: "iPhone 18 Pro", udid: "preferred", isAvailable: true}, {name: "iPhone 18", udid: "other", isAvailable: true}],
        "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [{name: "iPhone 17", udid: "older", isAvailable: true}],
        "com.apple.CoreSimulator.SimRuntime.xrOS-27-0": [{name: "Apple Vision Pro", udid: "vision", isAvailable: true}],
        "com.apple.CoreSimulator.SimRuntime.iOS-28-0": [{name: "iPhone 19", udid: "missing", isAvailable: false}],
    }};
    const selected = chooseDestinations(devices);
    assert.equal(selected.destinations.ios, "platform=iOS Simulator,id=preferred");
    assert.equal(selected.destinations.visionos, "platform=visionOS Simulator,id=vision");
    assert.equal(chooseDestinations({}).destinations.ios, undefined);
});

test("pinned Xcode and simulator builds reject drift even when newer tools are available", () => {
    const provisioning = {xcode: {version: "27.0", buildVersion: "27A266a"}, runtimes: [
        {platform: "iOS", version: "27.0", buildVersion: "24A434"}, {platform: "visionOS", version: "27.0", buildVersion: "24M362"},
    ]};
    const runtimes = {runtimes: [
        {identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0", version: "27.0", buildversion: "24A434", isAvailable: true},
        {identifier: "com.apple.CoreSimulator.SimRuntime.xrOS-27-0", version: "27.0", buildversion: "24M362", isAvailable: true},
    ]};
    const correct = pinnedEnvironmentEvidence("Xcode 27.0\nBuild version 27A266a", runtimes, provisioning);
    assert.equal(correct.xcode.available, true);
    assert.equal(correct.runtimes.ios.available, true);
    assert.equal(correct.runtimes.visionos.available, true);
    const drift = pinnedEnvironmentEvidence("Xcode 27.1\nBuild version 27B100", {runtimes: runtimes.runtimes.map(runtime => ({...runtime, buildversion: "different"}))}, provisioning);
    assert.equal(drift.xcode.available, false);
    assert.equal(drift.runtimes.ios.available, false);
    assert.equal(drift.runtimes.visionos.available, false);
    assert.equal(pinnedEnvironmentEvidence("Xcode 27.0\nBuild version 27A266a", runtimes, {}).xcode.available, false);
});

test("stage commands retain default DerivedData and isolate result/replay artifact paths", () => {
    const stages = createManifest(job());
    const destinations = {macos: "platform=macOS,arch=arm64", ios: "platform=iOS Simulator,id=fixture", visionos: "platform=visionOS Simulator,id=fixture"};
    const testStage = commandForStage(stages.find(stage => stage.id === "test.macos.debug"), {destinations, artifacts: "/artifacts"});
    assert.ok(testStage.args.includes("/artifacts/test.macos.debug.xcresult"));
    assert.ok(testStage.args.includes(destinations.macos));
    const approvalStage = stages.find(stage => stage.id === "approval.debug");
    const approval = commandForStage(approvalStage, {destinations, artifacts: "/artifacts", scratch: "/local-scratch/approval.debug"});
    assert.equal(approval.args[approval.args.indexOf("--scratch-dir") + 1], "/local-scratch/approval.debug");
    assert.equal(approval.args[approval.args.indexOf("--failure-dir") + 1], "/artifacts/failures/approval.debug");
    assert.throws(() => commandForStage(approvalStage, {destinations, artifacts: "/artifacts"}), /Guest-local scratch/);
    assert.throws(() => commandForStage(approvalStage, {destinations, artifacts: "/artifacts", scratch: "/artifacts/scratch"}), /Guest-local scratch/);
    assert.ok(approval.args.includes("/artifacts/failures/approval.debug"));
    assert.ok(!approval.args.includes("/artifacts/scratch/approval.debug"));
    assert.throws(() => commandForStage({id: "bad", command: "xcodebuild", args: ["-derivedDataPath", "/tmp/test"]}, {destinations, artifacts: "/artifacts"}));
});

test("source manifest rejects traversal, ancestor conflicts, and chained symlink escapes", () => {
    const entry = (path, type = "file", target) => ({path, type, sha256: digest(target ?? "contents"), mode: 0o644, ...(target ? {target} : {})});
    assert.doesNotThrow(() => validateSnapshotManifest({version: 1, files: [entry("src/main.swift"), entry("linked", "symlink", "src/main.swift")]}));
    for (const files of [
        [entry("../escape")], [entry("/escape")], [entry("a"), entry("a")], [entry("a"), entry("a/b")],
        [entry("link", "symlink", "/outside")], [entry("link", "symlink", "../outside")],
        [entry("link", "symlink", "link")], [entry("a", "symlink", "b"), entry("b", "symlink", "a")],
        [entry(".big-wallet-vm-workspace.json")], [{...entry("file"), mode: 0o4755}],
    ]) { assert.throws(() => validateSnapshotManifest({version: 1, files})); }
});

test("local exchange requires private guest ownership under the protected build root", async () => {
    const parent = {uid: 0, mode: 0o755, isDirectory: () => true, isSymbolicLink: () => false};
    const exchange = {uid: 501, gid: 20, mode: 0o700, isDirectory: () => true, isSymbolicLink: () => false};
    const options = (root = parent, directory = exchange) => ({
        inspect: async filename => filename === BUILD_VOLUME ? root : directory,
        canonicalPath: async filename => filename, currentUID: () => 501, currentGID: () => 20,
    });
    assert.equal(await verifyExchangeDirectory(options()), EXCHANGE_PATH);
    for (const change of [{uid: 501}, {mode: 0o777}, {isDirectory: () => false}, {isSymbolicLink: () => true}]) {
        await assert.rejects(verifyExchangeDirectory(options({...parent, ...change})), /protected root-owned/);
    }
    for (const change of [{uid: 0}, {gid: 99}, {mode: 0o755}, {mode: 0o1700}, {isDirectory: () => false}, {isSymbolicLink: () => true}]) {
        await assert.rejects(verifyExchangeDirectory(options(parent, {...exchange, ...change})), /private directory/);
    }
    for (const redirected of [BUILD_VOLUME, EXCHANGE_PATH]) {
        await assert.rejects(verifyExchangeDirectory({...options(), canonicalPath: async filename => filename === redirected ? "/outside" : filename}), /directory/);
    }
});

test("cold-boot build volume waits briefly and rejects an unrelated mounted volume", async () => {
    const identity = {version: 1, vmId: "fixture-vm", volumeUUID: "12345678-1234-1234-1234-123456789abc"};
    let time = 0;
    let calls = 0;
    const options = {vmId: "fixture-vm", now: () => time, wait: async milliseconds => { time += milliseconds; }, timeoutMilliseconds: 2000,
        canonicalPath: async () => BUILD_VOLUME, readIdentity: async () => identity,
        execute: async () => success(++calls === 1 ? "" : `/dev/disk4s1 on ${BUILD_VOLUME} (apfs, local, journaled)`)};
    assert.deepEqual(await verifyBuildVolume(options), identity);
    assert.equal(calls, 2);
    assert.equal(time, 1000);
    await assert.rejects(verifyBuildVolume({...options, readIdentity: async () => ({...identity, vmId: "another-vm"})}), /another VM/);
    await assert.rejects(verifyBuildVolume({...options, canonicalPath: async () => "/redirect"}), /direct mount/);
    for (const output of [`/dev/disk4s1 on ${BUILD_VOLUME} (apfs, journaled)`, `/dev/disk4s1 on ${BUILD_VOLUME} (nfs, local)`,
        `/dev/disk4s1 on ${BUILD_VOLUME}/Other (apfs, local, journaled)`]) {
        await assert.rejects(verifyBuildVolume({...options, execute: async () => success(output), timeoutMilliseconds: 0}), /did not become available/);
    }
    time = 0;
    await assert.rejects(verifyBuildVolume({...options, execute: async () => success("")}), /did not become available/);
    assert.equal(time, 2000);
    await assert.rejects(verifyBuildVolume({...options, stopRequested: async () => true, execute: async () => { throw new Error("must not execute"); }}), /cancelled/);
});

async function sourceFixture(root, contents = "version one") {
    const exchange = join(root, "exchange");
    await mkdir(join(exchange, "source/Scripts"), {recursive: true});
    await writeFile(join(exchange, "source/Scripts/fixture"), contents);
    const manifest = {version: 1, files: [{path: "Scripts/fixture", type: "file", mode: 0o644, sha256: digest(contents)}]};
    const raw = JSON.stringify(manifest);
    await writeFile(join(exchange, "snapshot-manifest.json"), raw);
    return {exchange, job: job({source: {sha256: digest(raw), commit: "b".repeat(40), fileCount: 1, bytes: Buffer.byteLength(contents)}}), workspace: join(root, "Developer/big-wallet")};
}

test("source materialization verifies the exact snapshot and safely replaces an owned stable workspace", async () => fixture(async root => {
    const first = await sourceFixture(root);
    await materializeSource(first.exchange, first.job, first.workspace);
    assert.equal(await readFile(join(first.workspace, "Scripts/fixture"), "utf8"), "version one");
    await writeFile(join(first.workspace, "old-generated-file"), "old");
    const second = await sourceFixture(root, "version two");
    await materializeSource(second.exchange, {...second.job, runId: "second"}, second.workspace);
    assert.equal(await readFile(join(second.workspace, "Scripts/fixture"), "utf8"), "version two");
    assert.ok(!(await readdir(second.workspace)).includes("old-generated-file"));
}));

test("tampered source never replaces the previous source snapshot", async () => fixture(async root => {
    const setup = await sourceFixture(root);
    await materializeSource(setup.exchange, setup.job, setup.workspace);
    await writeFile(join(setup.exchange, "source/Scripts/fixture"), "tampered");
    await assert.rejects(materializeSource(setup.exchange, {...setup.job, runId: "tampered"}, setup.workspace), /hash mismatch/);
    assert.equal(await readFile(join(setup.workspace, "Scripts/fixture"), "utf8"), "version one");
}));

test("unowned workspace and symlinked source roots are rejected", async () => fixture(async root => {
    const setup = await sourceFixture(root);
    await mkdir(setup.workspace, {recursive: true});
    await writeFile(join(setup.workspace, "user-work"), "keep");
    await assert.rejects(materializeSource(setup.exchange, setup.job, setup.workspace), /unmarked/);
    assert.equal(await readFile(join(setup.workspace, "user-work"), "utf8"), "keep");
    await rm(setup.workspace, {recursive: true});
    await rm(join(setup.exchange, "source"), {recursive: true});
    await mkdir(join(root, "outside"));
    await symlink(join(root, "outside"), join(setup.exchange, "source"));
    await assert.rejects(materializeSource(setup.exchange, setup.job, setup.workspace), /Source directory/);
}));

test("XCTest audit fails empty runs, unavailable counts, ordinary skips, and missing skip inventory", () => {
    const policy = {configuration: "Debug", kind: "full"};
    assert.equal(auditNativeResult(summary(1), nativeTree([["Class/testWorks()", "Passed"]]), policy).ok, true);
    assert.equal(auditNativeResult(summary(0), nativeTree([]), policy).ok, false);
    assert.equal(auditNativeResult({}, nativeTree([]), policy).ok, false);
    assert.equal(auditNativeResult({...summary(1), totalTestCount: 2}, nativeTree([["Class/testWorks()", "Passed"]]), policy).ok, false);
    assert.equal(auditNativeResult(summary(1, 1), nativeTree([["Class/testWorks()", "Passed"], ["WindowAuthenticationSessionTests/testFocus()", "Skipped"]]), policy).ok, false);
    assert.equal(auditNativeResult(summary(1, 1), nativeTree([["Class/testWorks()", "Passed"]]), policy).ok, false);
    assert.equal(auditNativeResult(summary(1, 0, 1), nativeTree([]), policy).ok, false);
});

test("unfinished stages never produce a passing aggregate and skipped counts remain numeric", () => {
    assert.equal(auditResults([{id: "pending", status: "running"}]).status, "failed");
    const audit = auditNativeResult(summary(1), nativeTree([["Class/testWorks()", "Passed"]]), {configuration: "Debug", kind: "full"});
    const result = auditResults([{id: "complete", status: "passed", nativeAudit: {configuration: "Debug"}, audit}]);
    assert.equal(result.status, "passed");
    assert.equal(result.tests[0].skipped, 0);
    assert.deepEqual(result.tests[0].skippedTests, []);
});

test("Debug performance skips are provisional until every corresponding Release gate passes", () => {
    const cases = PERFORMANCE_TESTS.map(name => [`WalletCoreProxyPerformanceGateTests/${name}()`, "Skipped"]);
    const debug = auditNativeResult(summary(0, 5), nativeTree(cases), {configuration: "Debug", kind: "full"});
    assert.equal(debug.ok, true);
    const debugStage = {id: "test.debug", status: "passed", nativeAudit: {configuration: "Debug", platform: "macos"}, audit: debug};
    assert.equal(auditResults([debugStage]).status, "failed");
    const release = auditNativeResult(summary(5), nativeTree(cases.map(([name]) => [name, "Passed"])), {configuration: "Release", kind: "performance"});
    assert.equal(release.ok, true);
    assert.equal(auditResults([debugStage, {id: "performance", status: "passed", nativeAudit: {configuration: "Release", platform: "macos"}, audit: release}]).status, "passed");
    assert.equal(auditNativeResult(summary(4), nativeTree(cases.slice(0, 4).map(([name]) => [name, "Passed"])), {configuration: "Release", kind: "performance"}).ok, false);
    assert.equal(auditNativeResult(summary(0, 5), nativeTree(cases), {configuration: "Release", kind: "full"}).ok, false);
    assert.equal(performanceTestName("UnrelatedClass/testEd25519SigningPerformanceGate()"), undefined);
});

test("stage executor aggregates independent failures and blocks only unmet dependencies or prerequisites", async () => fixture(async root => {
    const manifest = [
        {id: "failed", group: "test", command: "fake", args: [], cwd: ".", dependencies: [], requirements: [], timeoutSeconds: 1},
        {id: "dependent", group: "test", command: "fake", args: [], cwd: ".", dependencies: ["failed"], requirements: [], timeoutSeconds: 1},
        {id: "independent", group: "worker", command: "fake", args: [], cwd: ".", dependencies: [], requirements: [], timeoutSeconds: 1},
        {id: "unavailable", group: "test", command: "fake", args: [], cwd: ".", dependencies: [], requirements: ["ios"], timeoutSeconds: 1},
    ];
    const executed = [];
    const snapshots = [];
    let measurement = 0;
    const results = await executeStages(manifest, {writeJSON: atomicJSON, hashFile, workspace: root, artifacts: root, preflight: {checks: {}, destinations: {}},
        execute: async (_command, _args, options) => { executed.push(options.logPath); return executed.length === 1 ? {...success(), code: 1} : success(); },
        publish: async stages => snapshots.push(structuredClone(stages)),
        measureResources: () => ({sequence: measurement++}),
    });
    assert.deepEqual(results.map(result => result.status), ["failed", "blocked", "passed", "blocked"]);
    assert.equal(executed.length, 2);
    assert.equal(auditResults(results).status, "failed");
    assert.deepEqual(snapshots[0], pendingStageResults(manifest));
    assert.ok(snapshots.every(stages => stages.length === manifest.length));
    assert.ok(snapshots.some(stages => stages.some(stage => stage.status === "running")));
    assert.equal(measurement, 8);
    assert.deepEqual(results.map(result => result.resources), [
        {started: {sequence: 0}, finished: {sequence: 1}}, {started: {sequence: 2}, finished: {sequence: 3}},
        {started: {sequence: 4}, finished: {sequence: 5}}, {started: {sequence: 6}, finished: {sequence: 7}},
    ]);
}));

for (const changed of [false, true]) {
    test(`generated artifacts ${changed ? "are exported without passing a stale check" : "stay unexported when current"}`, async () => fixture(async root => {
        const workspace = join(root, "workspace"), artifacts = join(root, "artifacts");
        const source = "Safari Shared/Resources/inpage.js";
        await mkdir(join(workspace, "Safari Shared/Resources"), {recursive: true});
        await mkdir(artifacts);
        await writeFile(join(workspace, source), "current bundle");
        const stage = {id: "provider.bundle", group: "repository", command: "fake", args: [], cwd: ".", dependencies: [],
            requirements: [], timeoutSeconds: 1, unchanged: [source]};
        const results = await executeStages([stage], {writeJSON: atomicJSON, hashFile, workspace, artifacts, preflight: {checks: {}, destinations: {}},
            execute: async () => { if (changed) { await writeFile(join(workspace, source), "generated bundle"); } return success(); }});
        assert.equal(results[0].status, changed ? "failed" : "passed");
        if (changed) {
            const artifact = `generated/provider.bundle/${source}`;
            assert.match(results[0].reason, /Generated artifact was not current/);
            assert.deepEqual(results[0].generatedArtifacts, [{source, artifact, sha256: digest("generated bundle")}]);
            assert.equal(await readFile(join(artifacts, artifact), "utf8"), "generated bundle");
            assert.equal(auditResults(results).status, "failed");
        } else {
            assert.equal(results[0].generatedArtifacts, undefined);
            assert.deepEqual(await readdir(artifacts), []);
        }
    }));
}

test("generated artifact copy failures fail the stage and preserve existing output", async () => fixture(async root => {
    const workspace = join(root, "workspace"), artifacts = join(root, "artifacts");
    await mkdir(workspace);
    await mkdir(join(artifacts, "generated/provider.bundle"), {recursive: true});
    await writeFile(join(workspace, "inpage.js"), "old bundle");
    const destination = join(artifacts, "generated/provider.bundle/inpage.js");
    await writeFile(destination, "preserved output");
    const stage = {id: "provider.bundle", group: "repository", command: "fake", args: [], cwd: ".", dependencies: [],
        requirements: [], timeoutSeconds: 1, unchanged: ["inpage.js"]};
    const results = await executeStages([stage], {writeJSON: atomicJSON, hashFile, workspace, artifacts, preflight: {checks: {}, destinations: {}},
        execute: async () => { await writeFile(join(workspace, "inpage.js"), "new bundle"); return success(); }});
    assert.equal(results[0].status, "failed");
    assert.match(results[0].reason, /EEXIST/);
    assert.equal(results[0].generatedArtifacts, undefined);
    assert.equal(await readFile(destination, "utf8"), "preserved output");
}));

for (const interference of ["source-symlink", "source-directory", "destination-symlink", "traversal"]) {
    test(`generated artifact exports reject ${interference}`, async () => fixture(async root => {
        const workspace = join(root, "workspace"), artifacts = join(root, "artifacts"), outside = join(root, "outside");
        await mkdir(workspace);
        await mkdir(artifacts);
        await mkdir(outside);
        const source = interference === "traversal" ? "../inpage.js" : "inpage.js";
        const filename = join(workspace, source);
        await writeFile(filename, "old bundle");
        const stage = {id: "provider.bundle", group: "repository", command: "fake", args: [], cwd: ".", dependencies: [],
            requirements: [], timeoutSeconds: 1, unchanged: [source]};
        const results = await executeStages([stage], {writeJSON: atomicJSON, hashFile, workspace, artifacts, preflight: {checks: {}, destinations: {}},
            execute: async () => {
                await rm(filename);
                if (interference === "source-symlink") {
                    await writeFile(join(workspace, "other.js"), "new bundle");
                    await symlink(join(workspace, "other.js"), filename);
                } else if (interference === "source-directory") { await mkdir(filename); }
                else { await writeFile(filename, "new bundle"); }
                if (interference === "destination-symlink") { await symlink(outside, join(artifacts, "generated")); }
                return success();
            }});
        assert.equal(results[0].status, "failed");
        assert.match(results[0].reason, /generated artifact path|regular file|symlinks/);
        assert.equal(results[0].generatedArtifacts, undefined);
        assert.deepEqual(await readdir(outside), []);
    }));
}

test("a transport failure retains the complete planned inventory before any command starts", async () => fixture(async root => {
    const manifest = createManifest(job({profile: "extended"}));
    let retained;
    await assert.rejects(executeStages(manifest, {writeJSON: atomicJSON, hashFile, workspace: root, artifacts: root, preflight: {checks: {}, destinations: {}},
        execute: async () => { throw new Error("must not execute"); },
        publish: async stages => { retained = structuredClone(stages); throw new Error("transport interrupted"); },
    }), /transport interrupted/);
    assert.equal(retained.length, manifest.length);
    assert.ok(retained.every(stage => stage.status === "pending"));
    assert.deepEqual(retained.map(stage => stage.id), manifest.map(stage => stage.id));
    assert.equal(auditResults(retained).status, "failed");
}));

test("native result bundles are audited and totals retained even when a native command exits zero", async () => fixture(async root => {
    const stage = {id: "test.fixture", group: "test", command: "xcodebuild", args: ["test"], cwd: ".", dependencies: [], requirements: [], timeoutSeconds: 1,
        resultBundle: true, nativeAudit: {configuration: "Debug", kind: "full", platform: "macos"}};
    const results = await executeStages([stage], {writeJSON: atomicJSON, hashFile, workspace: root, artifacts: root, preflight: {checks: {}, destinations: {}}, execute: async (command, args) => {
        if (command === "xcodebuild") { return success(); }
        return success(JSON.stringify(args.includes("summary") ? summary(0, 1) : nativeTree([["Class/testSkipped", "Skipped"]])));
    }});
    assert.equal(results[0].status, "failed");
    assert.equal(results[0].audit.counts.skipped, 1);
    assert.ok((await readdir(root)).includes("test.fixture.summary.json"));
}));

test("stop cancels future stages and secrets are supplied only to the native process environment", async () => fixture(async root => {
    const stages = [
        {id: "native", group: "build", command: "xcodebuild", args: [], cwd: ".", dependencies: [], requirements: [], timeoutSeconds: 1, proofKey: true},
        {id: "worker", group: "worker", command: "npm", args: ["test"], cwd: ".", dependencies: [], requirements: [], timeoutSeconds: 1},
    ];
    const calls = [];
    const results = await executeStages(stages, {writeJSON: atomicJSON, hashFile, workspace: root, artifacts: root, preflight: {checks: {}, destinations: {}}, proofKey: "private-fixture",
        runId: "run", exchange: EXCHANGE_PATH, execute: async (command, args, options) => { calls.push({command, args, env: options.env}); return success(); }});
    assert.equal(calls[0].env.ALCHEMY_JWT_REQUEST_PROOF_KEY, "private-fixture");
    assert.equal(calls[1].env.ALCHEMY_JWT_REQUEST_PROOF_KEY, undefined);
    assert.equal(calls[1].env.BW_TEST_VM_RUN_ID, "run");
    assert.doesNotMatch(JSON.stringify(results), /private-fixture/);
    const stopped = await executeStages(stages, {writeJSON: atomicJSON, hashFile, workspace: root, artifacts: root, preflight: {checks: {}, destinations: {}}, stopRequested: async () => true,
        execute: async () => { throw new Error("must not execute"); }});
    assert.deepEqual(stopped.map(stage => stage.status), ["cancelled", "cancelled"]);
    assert.equal(auditResults(stopped).status, "cancelled");
}));

test("timeouts remain failures and do not suppress unrelated stages", async () => fixture(async root => {
    const stage = id => ({id, group: "test", command: "fake", args: [], cwd: ".", dependencies: [], requirements: [], timeoutSeconds: 7});
    const results = await executeStages([stage("timed-out"), stage("later")], {writeJSON: atomicJSON, hashFile, workspace: root, artifacts: root, preflight: {checks: {}, destinations: {}},
        execute: async (_command, _args, options) => options.logPath.includes("timed-out") ? {...success(), timedOut: true, code: null} : success()});
    assert.deepEqual(results.map(result => result.status), ["failed", "passed"]);
    assert.match(results[0].reason, /7s/);
}));

for (const code of ["EEXIST", "EACCES"]) {
    test(`stage log ${code} is a failure without a stop request`, {timeout: 15000, skip: code === "EACCES" && process.getuid?.() === 0}, async () => fixture(async root => {
        const artifacts = join(root, "artifacts");
        await mkdir(artifacts);
        if (code === "EEXIST") { await writeFile(join(artifacts, "fixture.log"), "preserve"); }
        else { await chmod(artifacts, 0o500); }
        try {
            const stage = {id: "fixture", group: "repository", command: process.execPath, args: ["-e", "setTimeout(() => {}, 10000)"],
                cwd: ".", dependencies: [], requirements: [], timeoutSeconds: 10};
            const results = await executeStages([stage], {writeJSON: atomicJSON, hashFile, workspace: root, artifacts, preflight: {checks: {}, destinations: {}},
                stopRequested: async () => false});
            assert.equal(results[0].status, "failed");
            assert.match(results[0].reason, new RegExp(`Stage log failed: ${code}`));
            const summary = auditResults(results);
            assert.equal(summary.status, "failed");
            assert.equal(summary.counts.failed, 1);
            assert.equal(summary.counts.cancelled, 0);
            if (code === "EEXIST") { assert.equal(await readFile(join(artifacts, "fixture.log"), "utf8"), "preserve"); }
        } finally { await chmod(artifacts, 0o700); }
    }));
}

test("approval scratch stays beside the local workspace and rejects symlink redirection", async () => fixture(async root => {
    const workspace = join(root, "workspace");
    await mkdir(workspace);
    const scratch = await prepareStageScratch(workspace, "run-1", "approval.debug");
    assert.equal(scratch, join(root, ".big-wallet-vm-scratch/run-1/approval.debug"));
    await writeFile(join(scratch, "retained-fixture"), "retained");
    assert.equal(await prepareStageScratch(workspace, "run-1", "approval.debug"), scratch);
    assert.equal(await readFile(join(scratch, "retained-fixture"), "utf8"), "retained");
    await assert.rejects(prepareStageScratch(workspace, "../outside", "approval.debug"), /identity/);
    const outside = join(root, "outside");
    await mkdir(outside);
    await symlink(outside, join(root, ".big-wallet-vm-scratch/run-2"));
    await assert.rejects(prepareStageScratch(workspace, "run-2", "approval.debug"), /symlinks/);
    assert.deepEqual(await readdir(outside), []);
}));

test("approval stages pass local scratch separately from shared failure artifacts", async () => fixture(async root => {
    const workspace = join(root, "workspace"), artifacts = join(root, "exchange-artifacts");
    await mkdir(workspace);
    await mkdir(artifacts);
    const stage = {id: "approval.fixture", group: "approval", command: "fake", args: [], cwd: ".", dependencies: [],
        requirements: [], timeoutSeconds: 1, scratchDirectory: true, failureDirectory: true};
    let actual;
    const results = await executeStages([stage], {writeJSON: atomicJSON, hashFile, workspace, artifacts, runId: "run-fixture", preflight: {checks: {}, destinations: {}},
        execute: async (_command, args) => { actual = args; return success(); }});
    assert.equal(results[0].status, "passed");
    assert.equal(actual[actual.indexOf("--scratch-dir") + 1], join(root, ".big-wallet-vm-scratch/run-fixture/approval.fixture"));
    assert.equal(actual[actual.indexOf("--failure-dir") + 1], join(artifacts, "failures/approval.fixture"));
}));
