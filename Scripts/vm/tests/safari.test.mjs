import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {mkdtemp, mkdir, realpath, rm, symlink, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import test from "node:test";
import {SAFARI_SCENARIOS, SAFARI_TEST_CLASS} from "../../safari/scenarios.mjs";
import {coverageReport, executeStages, readSafariEvidence, SAFARI_TERMINATION_GRACE_MILLISECONDS} from "../guest.mjs";
import {atomicJSON, hashFile, EXCHANGE_PATH} from "../guest_bootstrap.mjs";
import {auditNativeResult, auditResults, auditSafariPreparation, auditSafariResult} from "../result_audit.mjs";
import {BOOTSTRAP_TOOL_NAMES, commandForStage, createManifest, SAFARI_PLATFORMS, validateJob} from "../test_manifest.mjs";

const job = ({payload, ...overrides} = {}) => ({version: 1, runId: "safari-fixture", vmId: "fixture-vm", kind: "run", profile: "all",
    payload: {stages: ["safari"], onlyTesting: [], ...payload},
    bootstrapTools: Object.fromEntries(BOOTSTRAP_TOOL_NAMES.map(name => [name, "a".repeat(64)])),
    source: {sha256: "b".repeat(64), commit: "c".repeat(40)}, ...overrides});
const runtimeStages = manifest => manifest.filter(stage => stage.nativeAudit?.kind === "safari");
const fixtureStage = (configuration = "Debug") => runtimeStages(createManifest(job({payload: {configuration}})))
    .find(stage => stage.nativeAudit.platform === "macos");
const nativeResult = policy => ({summary: {totalTestCount: policy.requiredTests.length, passedTests: policy.requiredTests.length, failedTests: 0, skippedTests: 0},
    tree: {testNodes: policy.requiredTests.map(identifier => ({nodeType: "Test Case", nodeIdentifier: `${identifier}()`, result: "Passed"}))}});
const evidence = stage => ({version: 1, runId: job().runId, stageId: stage.id, platform: stage.nativeAudit.platform,
    configuration: stage.nativeAudit.configuration, signing: stage.nativeAudit.signing, iterations: stage.nativeAudit.iterations,
    activationMode: stage.nativeAudit.activationMode, activationRequests: [],
    browser: {bundleIdentifier: stage.nativeAudit.platform === "macos" ? "com.apple.Safari" : "com.apple.mobilesafari", version: "27.0"},
    extensionIdentifier: "org.lil.wallet.Safari", extension: {bundleIdentifier: "org.lil.wallet.Safari", version: "0.1", build: "23"},
    runtime: {macOS: {version: "27.0", build: "26A123"}}, handshake: {provider: true, native: true}, cleanup: {status: "passed"},
    scenarios: stage.nativeAudit.requiredScenarios.flatMap(id => Array.from({length: stage.nativeAudit.iterations}, (_, index) => ({id, iteration: index + 1, status: "passed"})))});
const auditEvidence = (value, stage) => auditSafariResult(value, stage.nativeAudit, {runId: job().runId, stageId: stage.id});
const success = output => ({code: 0, signal: null, stdout: output ?? "", output: output ?? "", timedOut: false, cancelled: false});
const fixture = async action => {
    const directory = await realpath(await mkdtemp(join(tmpdir(), "big-wallet-safari-runner-")));
    try { return await action(directory); } finally { await rm(directory, {recursive: true, force: true}); }
};

const preparationReference = {preparationRunID: "setup-safari-preparation-fixture", receiptSHA256: "d".repeat(64)};
const preparationJob = () => job({payload: {prepareSafari: true, configuration: "Debug", signing: "local",
    onlyTesting: ["Safari UI Tests macOS"]}});
const preparationEvidence = runId => {
    const installationDirectory = "/Users/tester/Applications/BigWalletSafariVM/Prepared";
    const receipt = {version: 1, status: "passed", preparationRunID: runId,
        descriptor: {version: 1, runID: runId, root: `/Volumes/BigWalletBuild/Exchange/${runId}/safari/macos/Debug`,
            platform: "macos", signingMode: "local", configuration: "Debug"},
        installationDirectory, sourceApp: "/Users/tester/Library/Developer/Xcode/DerivedData/Wallet/Build/Products/Debug/Big Wallet.app",
        signatures: {app: {identifier: "org.lil.wallet", cdhash: "a".repeat(40)},
            extension: {identifier: "org.lil.wallet.Safari", cdhash: "b".repeat(40)},
            helper: {identifier: "org.lil.wallet.ambient", cdhash: "c".repeat(40)}},
        enabledObservation: {enabled: true, processID: 42, executablePath: `${installationDirectory}/Big Wallet.app/Contents/MacOS/Big Wallet`,
            preparationNonce: "12345678-1234-4123-8123-123456789abc", observedAt: "2026-10-20T10:00:00.000Z"},
        cleanup: {status: "passed"}, preparedAt: "2026-10-20T10:00:01.000Z"};
    return {version: 1, status: "passed", preparationRunID: runId, platform: "macos", configuration: "Debug", signingMode: "local",
        installationDirectory, receiptSHA256: createHash("sha256").update(JSON.stringify(receipt)).digest("hex"), receipt};
};

test("Safari preparation plans only the fixed local build and a native-consent probe without XCTest", () => {
    const selected = preparationJob();
    const manifest = createManifest(selected);
    assert.deepEqual(manifest.map(stage => stage.id), ["provider.install", "protocol.check", "build-safari.macos.debug", "prepare-safari.macos.debug"]);
    assert.ok(manifest.every(stage => !stage.nativeAudit && !stage.resultBundle));
    const stage = manifest.at(-1);
    assert.equal(stage.preparationResult, true);
    assert.ok(stage.args.includes("prepare"));
    assert.ok(!stage.requirements.includes("safariAutomation"));
    const command = commandForStage(stage, {destinations: {macos: "platform=macOS,arch=arm64"}, artifacts: "/artifacts", scratch: "/scratch"});
    assert.ok(command.args.includes("--preparation-result"));
    assert.ok(command.args.includes("/artifacts/prepare-safari.macos.debug.safari-preparation.json"));
    assert.ok(!command.args.includes("-resultBundlePath"));
    assert.equal(coverageReport(selected, [], {checks: {}}).fullSuiteVerified, false);
    for (const payload of [{prepareSafari: "true"}, {configuration: "Release"}, {signing: "apple"},
        {onlyTesting: ["Safari UI Tests iOS"]}, {interactiveSafari: true}, {preparedSafari: preparationReference}, {stages: []}]) {
        assert.throws(() => createManifest({...selected, payload: {...selected.payload, ...payload}}));
    }
});

test("prepared Safari references are bound only to local macOS runtime stages", () => {
    const selected = job({payload: {preparedSafari: preparationReference}});
    const manifest = createManifest(selected);
    for (const stage of manifest) {
        const prepared = stage.nativeAudit?.kind === "safari" && stage.nativeAudit.platform === "macos";
        assert.equal(stage.args.includes("--prepared-safari"), prepared);
        if (prepared) {
            assert.equal(stage.nativeAudit.activationMode, "prepared");
            assert.deepEqual(stage.nativeAudit.preparation, preparationReference);
            const valid = {...evidence(stage), preparation: preparationReference};
            assert.equal(auditEvidence(valid, stage).ok, true);
            assert.equal(auditEvidence({...valid, preparation: {...preparationReference, receiptSHA256: "e".repeat(64)}}, stage).ok, false);
            assert.equal(auditEvidence({...valid, activationRequests: [{enabled: true}]}, stage).ok, false);
            assert.equal(auditEvidence(evidence(stage), stage).ok, false);
        }
    }
    for (const payload of [{preparedSafari: null}, {preparedSafari: {...preparationReference, extra: true}},
        {preparedSafari: {...preparationReference, preparationRunID: "../other"}}, {signing: "apple"},
        {interactiveSafari: true}, {onlyTesting: ["Safari UI Tests iOS"]}, {stages: ["build"]}]) {
        assert.throws(() => createManifest({...selected, payload: {...selected.payload, ...payload}}));
    }
});

test("preparation receipts require the exact descriptor, native enabled observation, identities and cleanup", () => {
    const valid = preparationEvidence(job().runId);
    assert.equal(auditSafariPreparation(valid, {runId: job().runId}).ok, true);
    for (const mutate of [
        value => { value.status = "failed"; },
        value => { value.receiptSHA256 = "0".repeat(64); },
        value => { value.receipt.descriptor.runID = "old-run"; },
        value => { value.receipt.signatures.extension.identifier = "another.extension"; },
        value => { value.receipt.enabledObservation.enabled = false; },
        value => { value.receipt.enabledObservation.processID = 0; },
        value => { value.receipt.enabledObservation.executablePath = "/other/Big Wallet"; },
        value => { value.receipt.enabledObservation.preparationNonce = "not-a-nonce"; },
        value => { value.receipt.enabledObservation.observedAt = "2026-10-20T10:01:00.000Z"; },
        value => { value.receipt.cleanup.status = "failed"; },
        value => { value.receipt.installationDirectory = "/Users/tester/../Prepared"; },
    ]) {
        const invalid = structuredClone(valid);
        mutate(invalid);
        if (invalid.receiptSHA256 !== "0".repeat(64)) {
            invalid.receiptSHA256 = createHash("sha256").update(JSON.stringify(invalid.receipt)).digest("hex");
        }
        assert.equal(auditSafariPreparation(invalid, {runId: job().runId}).ok, false);
    }
});

test("preparation execution retains cancellation grace and cannot pass without its receipt audit", async () => fixture(async directory => {
    const stage = {...createManifest(preparationJob()).at(-1), dependencies: [], requirements: [], scratchDirectory: false};
    const artifact = join(directory, `${stage.id}.safari-preparation.json`);
    const calls = [];
    const options = {workspace: directory, artifacts: directory, writeJSON: atomicJSON, hashFile, runId: job().runId,
        preflight: {checks: {}, destinations: {macos: "platform=macOS,arch=arm64"}},
        execute: async (command, args, settings) => {
            calls.push([command, args]);
            assert.equal(command, "node");
            assert.equal(settings.terminationGraceMilliseconds, SAFARI_TERMINATION_GRACE_MILLISECONDS);
            await writeFile(artifact, JSON.stringify(preparationEvidence(job().runId)));
            return success();
        }};
    const results = await executeStages([stage], options);
    assert.equal(results[0].status, "passed");
    assert.equal(results[0].preparationResult, `${stage.id}.safari-preparation.json`);
    assert.equal(results[0].preparationSHA256, await hashFile(artifact));
    assert.equal(auditResults(results).status, "passed");
    assert.equal(auditResults([{...results[0], audit: undefined}]).status, "failed");
    assert.equal(calls.length, 1);
    const failed = await executeStages([stage], {...options, execute: async () => {
        await writeFile(artifact, JSON.stringify({status: "passed"}));
        return success();
    }});
    assert.equal(failed[0].status, "failed");
}));

test("interactive Safari mode reaches only selected macOS runtime stages", () => {
    const selected = job({payload: {interactiveSafari: true}});
    const manifest = createManifest(selected);
    for (const stage of manifest) {
        const interactive = stage.nativeAudit?.kind === "safari" && stage.nativeAudit.platform === "macos";
        assert.equal(stage.args.includes("--interactive-safari"), interactive);
        if (stage.nativeAudit?.kind === "safari") {
            assert.equal(stage.nativeAudit.activationMode, interactive ? "interactive" : "automatic");
        }
    }
    assert.equal(coverageReport(selected, [], {checks: {}}).safari.unattended, "not-established");
    for (const payload of [{interactiveSafari: "true"}, {interactiveSafari: true, stages: ["build"]},
        {interactiveSafari: true, onlyTesting: ["Safari UI Tests iOS"]},
        {interactiveSafari: true, onlyTesting: ["Tests macOS"]}]) {
        assert.throws(() => createManifest(job({payload})), /[Ii]nteractive/);
    }
    assert.throws(() => validateJob(job({kind: "doctor", payload: {interactiveSafari: true}})), /[Ii]nteractive/);
});

test("Safari audit binds assisted activation and requires matching completed checkpoints", () => {
    const stage = runtimeStages(createManifest(job({payload: {interactiveSafari: true}}))).find(value => value.nativeAudit.platform === "macos");
    const valid = evidence(stage);
    valid.activationRequests = [{scenario: {id: stage.nativeAudit.requiredScenarios[0], iteration: 1}, enabled: true,
        requestedAt: "2026-10-20T10:00:00.000Z", observedAt: "2026-10-20T10:00:01.000Z"}];
    assert.equal(auditEvidence(valid, stage).ok, true);
    for (const change of [
        value => { value.activationMode = "automatic"; },
        value => { delete value.activationRequests; },
        value => { delete value.activationRequests[0].observedAt; },
        value => { value.activationRequests[0].scenario.id = "unselected"; },
        value => { value.activationRequests[0].observedAt = "2026-10-20T09:00:00.000Z"; },
        value => { value.activationRequests[0].enabled = "yes"; },
    ]) {
        const invalid = structuredClone(valid);
        change(invalid);
        assert.equal(auditEvidence(invalid, stage).ok, false);
    }
    const automatic = fixtureStage();
    const unrequested = {...evidence(automatic), activationRequests: valid.activationRequests};
    assert.equal(auditEvidence(unrequested, automatic).ok, false);
});

test("Safari selection includes both platforms and configurations with credential-free build dependencies", () => {
    const manifest = createManifest(job());
    assert.deepEqual(runtimeStages(manifest).map(stage => stage.id), ["safari.macos.debug", "safari.macos.release", "safari.ios.debug", "safari.ios.release"]);
    assert.ok(!manifest.some(stage => stage.id.includes("visionos") || stage.group === "performance"));
    for (const stage of manifest) {
        for (const dependency of stage.dependencies) { assert.ok(manifest.findIndex(candidate => candidate.id === dependency) < manifest.indexOf(stage)); }
        assert.ok(!stage.requirements.includes("signing") && !stage.requirements.includes("proofKey"));
    }
    for (const stage of runtimeStages(manifest)) {
        assert.equal(stage.nativeAudit.iterations, 1);
        const scenarios = SAFARI_SCENARIOS.filter(scenario => scenario.platforms.includes(stage.nativeAudit.platform));
        assert.deepEqual(stage.nativeAudit.requiredScenarios, scenarios.map(scenario => scenario.id));
        assert.deepEqual(stage.nativeAudit.requiredTests, scenarios.map(scenario => `${SAFARI_TEST_CLASS}/${scenario.method}`));
        assert.equal(stage.scratchDirectory, true);
        assert.equal(stage.resultBundle, true);
        assert.equal(stage.requirements.includes("safariAutomation"), stage.nativeAudit.platform === "macos");
    }
    assert.ok(manifest.filter(stage => stage.group === "build").every(stage => !stage.requirements.includes("safariAutomation")));
    assert.deepEqual(runtimeStages(createManifest(job({payload: {stages: []}}))).map(stage => stage.id), runtimeStages(manifest).map(stage => stage.id));
});

test("missing guest automation blocks only macOS Safari runtime with an actionable setup prerequisite", async () => fixture(async directory => {
    const stage = {...fixtureStage(), dependencies: []};
    const checks = Object.fromEntries(stage.requirements.map(requirement => [requirement, true]));
    checks.safariAutomation = false;
    const prerequisite = "Run Scripts/test_vm.sh setup to refresh guest UI automation.";
    const later = {id: "unrelated", group: "repository", command: "fixture-command", args: [], cwd: ".", dependencies: [], requirements: [], timeoutSeconds: 1};
    const calls = [];
    const results = await executeStages([stage, later], {workspace: directory, artifacts: directory, writeJSON: atomicJSON, hashFile,
        preflight: {checks, destinations: {}, safariAutomationIssue: prerequisite},
        execute: async (command, args) => { calls.push([command, ...args]); return success(); }});
    assert.deepEqual(results.map(result => result.status), ["blocked", "passed"]);
    assert.deepEqual(results[0].reason.requirements, ["safariAutomation"]);
    assert.equal(results[0].reason.prerequisite, prerequisite);
    assert.deepEqual(calls, [["fixture-command"]]);
    const ios = createManifest(job({payload: {onlyTesting: ["Safari UI Tests iOS"]}}));
    assert.ok(ios.every(stage => !stage.requirements.includes("safariAutomation")));
    const native = createManifest(job({payload: {stages: ["test"], onlyTesting: ["Tests macOS"]}}));
    assert.ok(native.every(stage => !stage.requirements.includes("safariAutomation")));
}));

test("extended Safari coverage schedules ten Release iterations without retries or Debug soaks", () => {
    const manifest = createManifest(job({profile: "extended"}));
    const soaks = runtimeStages(manifest).filter(stage => stage.id.includes("soak-"));
    assert.deepEqual(soaks.map(stage => stage.id), ["safari.soak-macos.release", "safari.soak-ios.release"]);
    for (const stage of soaks) {
        assert.equal(stage.nativeAudit.configuration, "Release");
        assert.equal(stage.nativeAudit.iterations, 10);
        assert.equal(stage.args[stage.args.indexOf("--iterations") + 1], "10");
        assert.deepEqual(stage.dependencies, [`safari.${stage.nativeAudit.platform}.release`]);
        assert.doesNotMatch(JSON.stringify(stage), /retry-tests-on-failure|test-repetition-relaunch-enabled/);
    }
    assert.ok(!runtimeStages(createManifest(job({profile: "extended", payload: {configuration: "Debug"}}))).some(stage => stage.nativeAudit.iterations !== 1));
});

test("Safari stage deadlines leave bounded time after the subprocess limit for finalization", () => {
    const manifest = createManifest(job({profile: "extended"}));
    for (const stage of manifest.filter(stage => stage.args[0] === "Scripts/safari/run.mjs")) {
        const subprocessLimit = stage.group === "build" ? 3600 : stage.nativeAudit.iterations === 10 ? 21600 : 7200;
        assert.equal(stage.timeoutSeconds - subprocessLimit, 600);
    }
});

test("only Safari runtime wrappers receive the bounded finalization signal grace", async context => {
    const root = await realpath(await mkdtemp(join(tmpdir(), "safari-grace-policy-")));
    context.after(() => rm(root, {recursive: true, force: true}));
    const stages = [
        {id: "safari.fixture", nativeAudit: {kind: "safari", platform: "macos"}},
        {id: "build-safari.fixture"},
        {id: "repository.fixture"},
    ].map(stage => ({group: "test", command: "fixture", args: [], cwd: ".", dependencies: [], requirements: [], timeoutSeconds: 1, ...stage}));
    const graces = [];
    await executeStages(stages, {workspace: root, artifacts: root, preflight: {checks: {}, destinations: {}},
        writeJSON: atomicJSON, hashFile, execute: async (_command, _args, options) => {
            graces.push(options.terminationGraceMilliseconds);
            return {code: 0, signal: null, output: "", cancelled: true, timedOut: false};
        }});
    assert.equal(SAFARI_TERMINATION_GRACE_MILLISECONDS, 300_000);
    assert.deepEqual(graces, [SAFARI_TERMINATION_GRACE_MILLISECONDS, undefined, undefined]);
});

test("Safari filters preserve the exact requested platform and method inventory", () => {
    for (const platform of SAFARI_PLATFORMS) {
        const scenario = SAFARI_SCENARIOS.find(scenario => scenario.platforms.includes(platform.id));
        const method = `${platform.target}/${SAFARI_TEST_CLASS}/${scenario.method}`;
        const selected = job({payload: {onlyTesting: [`${method}()`], configuration: "Release"}});
        assert.doesNotThrow(() => validateJob(selected));
        const manifest = createManifest(selected);
        const [stage] = runtimeStages(manifest);
        assert.equal(runtimeStages(manifest).length, 1);
        assert.equal(stage.nativeAudit.platform, platform.id);
        assert.deepEqual(stage.nativeAudit.requiredTests, [`${SAFARI_TEST_CLASS}/${scenario.method}`]);
        assert.deepEqual(stage.nativeAudit.requiredScenarios, [scenario.id]);
        assert.equal(stage.args[stage.args.indexOf("--only-testing") + 1], method);
        assert.ok(!manifest.some(candidate => candidate.id.startsWith("test.")));
        const targetManifest = createManifest(job({payload: {onlyTesting: [platform.target], configuration: "Debug"}}));
        assert.ok(runtimeStages(targetManifest).every(stage => stage.nativeAudit.platform === platform.id && !stage.nativeAudit.filtered));
    }
    assert.throws(() => createManifest(job({payload: {onlyTesting: ["Safari UI Tests iOS/MissingTests/testMissing"]}})), /did not match/);
    assert.throws(() => createManifest(job({payload: {stages: [], onlyTesting: ["Safari UI Tests iOS", "Safari UI Tests macOS/MissingTests/testMissing"]}})), /did not match/);
    assert.throws(() => validateJob(job({payload: {onlyTesting: ["Safari UI Tests visionOS"]}})), /XCTest selection/);
    assert.throws(() => validateJob(job({payload: {onlyTesting: ["Safari UI Tests iOS/Class/test;exit"]}})), /XCTest selection/);
    for (const stages of [["test"], ["repository"], ["test", "repository"]]) {
        assert.throws(() => createManifest(job({payload: {stages, onlyTesting: ["Safari UI Tests iOS"]}})), /require --stage safari or --stage build/);
    }
    assert.throws(() => createManifest(job({payload: {stages: ["safari", "repository"], onlyTesting: ["Tests macOS/PasswordStorageTests"]}})), /did not match/);
    const buildOnly = createManifest(job({payload: {stages: ["build"], onlyTesting: ["Safari UI Tests iOS"]}}));
    assert.ok(buildOnly.some(stage => stage.id === "build-safari.ios.debug"));
    assert.equal(runtimeStages(buildOnly).length, 0);
    for (const selector of [SAFARI_TEST_CLASS, "Safari UI Tests iOS", `${SAFARI_TEST_CLASS}/${SAFARI_SCENARIOS[0].method}`]) {
        const manifest = createManifest(job({payload: {stages: [], onlyTesting: [selector]}}));
        assert.ok(!manifest.some(stage => /^test\.(macos|ios|visionos)\./.test(stage.id)), selector);
        assert.ok(runtimeStages(manifest).length > 0, selector);
    }
});

test("Safari Apple mode retains the same scenarios and requires only the credentials each build uses", () => {
    const local = createManifest(job());
    const apple = createManifest(job({payload: {signing: "apple"}}));
    assert.deepEqual(local.map(stage => stage.id), apple.map(stage => stage.id));
    for (const stage of apple.filter(stage => stage.id.startsWith("build-safari."))) {
        assert.equal(stage.proofKey, true);
        assert.ok(stage.requirements.includes("proofKey"));
        assert.equal(stage.requirements.includes("signing"), stage.id.includes(".macos."));
        assert.equal(stage.command, "node");
        assert.ok(!stage.args.some(argument => argument.startsWith("CODE_SIGN_")));
    }
    for (const stage of runtimeStages(apple)) {
        assert.equal(stage.nativeAudit.signing, "apple");
        assert.deepEqual(stage.nativeAudit.requiredTests, local.find(candidate => candidate.id === stage.id).nativeAudit.requiredTests);
    }
});

test("Safari wrapper receives owned scratch, destination, and result paths", () => {
    const stage = fixtureStage();
    const options = {destinations: {macos: "platform=macOS,arch=arm64"}, artifacts: "/results", scratch: "/workspace/scratch"};
    const command = commandForStage(stage, options);
    assert.equal(command.args[command.args.indexOf("--destination") + 1], options.destinations.macos);
    assert.equal(command.args[command.args.indexOf("--scratch-dir") + 1], options.scratch);
    assert.equal(command.args[command.args.indexOf("-resultBundlePath") + 1], `/results/${stage.id}.xcresult`);
    assert.throws(() => commandForStage(stage, {...options, scratch: "/results/scratch"}), /Guest-local scratch/);
});

test("Safari XCTest audits reject omitted, repeated, skipped, unexpected, and indeterminate cases", () => {
    const stage = fixtureStage();
    const native = nativeResult(stage.nativeAudit);
    assert.equal(auditNativeResult(native.summary, native.tree, stage.nativeAudit).ok, true);
    const prefixed = structuredClone(native.tree);
    prefixed.testNodes[0].nodeIdentifier = `Safari UI Tests macOS/${prefixed.testNodes[0].nodeIdentifier}`;
    assert.equal(auditNativeResult(native.summary, prefixed, stage.nativeAudit).ok, true);
    const mutations = [
        tree => { tree.testNodes.pop(); },
        tree => { tree.testNodes.push(structuredClone(tree.testNodes[0])); },
        tree => { tree.testNodes[0].result = "Skipped"; },
        tree => { tree.testNodes[0].result = "Expected Failure"; },
        tree => { tree.testNodes[0].nodeIdentifier = "OtherTests/testOther()"; },
        tree => { tree.testNodes[0].nodeIdentifier = `Safari UI Tests iOS/${tree.testNodes[0].nodeIdentifier}`; },
    ];
    for (const mutate of mutations) {
        const tree = structuredClone(native.tree);
        mutate(tree);
        assert.equal(auditNativeResult(native.summary, tree, stage.nativeAudit).ok, false);
    }
    assert.equal(auditNativeResult(native.summary, native.tree, {...stage.nativeAudit, requiredTests: []}).ok, false);
});

test("Safari audits surface bounded XCTest startup and UI failure details without changing ordinary audits", () => {
    const stage = fixtureStage();
    const detail = "Safari UI Tests macOS-Runner encountered an error: Failed to enable UI automation mode";
    const summary = {totalTestCount: 1, passedTests: 0, failedTests: 1, skippedTests: 0,
        testFailures: [{failureText: detail}]};
    const tree = {testNodes: [{nodeType: "Test Case", nodeIdentifier: "Safari UI Tests macOS-Runner encountered an error", result: "Failed"}]};
    const safari = auditNativeResult(summary, tree, stage.nativeAudit);
    assert.equal(safari.ok, false);
    assert.ok(safari.issues.includes("1 XCTest failures"));
    assert.ok(safari.issues.includes(`Safari XCTest failure: ${detail}`));
    assert.ok(safari.issues.some(issue => issue.startsWith("Safari test must execute exactly once:")));
    const ordinary = auditNativeResult(summary, tree, {configuration: "Debug", kind: "full", platform: "macos"});
    assert.deepEqual(ordinary.issues, ["1 XCTest failures"]);
    const bounded = auditNativeResult({...summary,
        testFailures: Array.from({length: 12}, (_, index) => ({failureText: `${index}:` + "x".repeat(3000)}))}, tree, stage.nativeAudit);
    const details = bounded.issues.filter(issue => issue.startsWith("Safari XCTest failure:"));
    assert.equal(details.length, 10);
    assert.ok(details.every(issue => issue.length <= "Safari XCTest failure: ".length + 2048));
});

test("Safari evidence requires a fresh native handshake and each scenario iteration exactly once", () => {
    const stage = runtimeStages(createManifest(job({profile: "extended"}))).find(stage => stage.id === "safari.soak-macos.release");
    const valid = evidence(stage);
    assert.equal(auditEvidence(valid, stage).ok, true);
    assert.equal(auditEvidence(valid, stage).scenarioCount, stage.nativeAudit.requiredScenarios.length * 10);
    const mutations = [
        value => { value.runId = "previous-run"; },
        value => { value.stageId = "another-stage"; },
        value => { value.signing = "apple"; },
        value => { value.platform = "ios"; },
        value => { value.configuration = "Debug"; },
        value => { value.iterations = 1; },
        value => { value.browser.bundleIdentifier = "com.apple.SafariTechnologyPreview"; },
        value => { value.browser.version = ""; },
        value => { value.extensionIdentifier = ""; },
        value => { value.extensionIdentifier = "unrelated.safari.extension"; },
        value => { delete value.extension; },
        value => { value.extension = null; },
        value => { value.extension.bundleIdentifier = "unrelated.safari.extension"; },
        value => { value.extension.version = ""; },
        value => { value.extension.version = " "; },
        value => { value.extension.version = "1\n2"; },
        value => { value.extension.build = 23; },
        value => { value.extension.build = "x".repeat(257); },
        value => { delete value.runtime; },
        value => { value.runtime = null; },
        value => { value.runtime.macOS = null; },
        value => { value.runtime.macOS.version = ""; },
        value => { value.runtime.macOS.version = "27.0\n"; },
        value => { value.runtime.macOS.build = ""; },
        value => { value.runtime.macOS.build = "26A123\n"; },
        value => { value.runtime.macOS.build = "x".repeat(129); },
        value => { value.handshake.native = false; },
        value => { value.handshake.provider = false; },
        value => { delete value.cleanup; },
        value => { value.cleanup = null; },
        value => { value.cleanup.status = "pending"; },
        value => { value.cleanup.status = "failed"; },
        value => { value.scenarios.pop(); },
        value => { value.scenarios.push(structuredClone(value.scenarios[0])); },
        value => { value.scenarios[0].id = "unrequested"; },
        value => { value.scenarios[0].iteration = 0; },
        value => { value.scenarios[0].iteration = 11; },
        value => { value.scenarios[0].status = "skipped"; },
        value => { value.scenarios[0].status = "failed"; },
    ];
    for (const mutate of mutations) {
        const changed = structuredClone(valid);
        mutate(changed);
        assert.equal(auditEvidence(changed, stage).ok, false);
    }
    assert.equal(auditEvidence(undefined, stage).ok, false);
    assert.ok(auditEvidence({...valid, cleanup: {status: "pending"}}, stage).issues.includes("Safari evidence has no successful final cleanup"));
});

test("Safari sidecars reject missing, malformed, oversized, nonregular, and redirected files", async () => fixture(async directory => {
    const path = join(directory, "evidence.json");
    await assert.rejects(readSafariEvidence(path));
    await writeFile(path, JSON.stringify({fixture: true}));
    assert.deepEqual(await readSafariEvidence(path), {fixture: true});
    const link = join(directory, "link.json");
    await symlink(path, link);
    await assert.rejects(readSafariEvidence(link));
    await assert.rejects(readSafariEvidence(directory));
    await writeFile(path, "{");
    await assert.rejects(readSafariEvidence(path));
    await writeFile(path, Buffer.alloc(4 * 1024 * 1024 + 1));
    await assert.rejects(readSafariEvidence(path), /bounded regular file/);
}));

test("Safari execution cannot pass from XCTest alone and retains separate browser evidence", async () => fixture(async directory => {
    const workspace = join(directory, "workspace");
    const artifacts = join(directory, "artifacts");
    await mkdir(workspace);
    await mkdir(artifacts);
    const stage = {...fixtureStage(), dependencies: [], requirements: []};
    const native = nativeResult(stage.nativeAudit);
    const options = {workspace, artifacts, runId: job().runId, exchange: EXCHANGE_PATH,
        preflight: {checks: {}, destinations: {macos: "platform=macOS,arch=arm64"}}, writeJSON: atomicJSON, hashFile,
        execute: async (command, args) => {
            if (command === "node") { return success(); }
            assert.equal(command, "xcrun");
            assert.equal(args[0], "xcresulttool");
            return success(JSON.stringify(args.includes("summary") ? native.summary : native.tree));
        }};
    const missing = await executeStages([stage], options);
    assert.equal(missing[0].status, "failed");
    const startupFailure = structuredClone(native);
    startupFailure.summary.passedTests -= 1;
    startupFailure.summary.failedTests = 1;
    startupFailure.summary.testFailures = [{failureText: "Missing Safari extension permission control"}];
    startupFailure.tree.testNodes[0].result = "Failed";
    const failed = await executeStages([stage], {...options, execute: async (command, args) =>
        command === "node" ? {...success(), code: 1} : success(JSON.stringify(args.includes("summary") ? startupFailure.summary : startupFailure.tree))});
    assert.equal(failed[0].status, "failed");
    assert.ok(failed[0].reason.includes("Safari XCTest failure: Missing Safari extension permission control"));
    assert.ok(failed[0].reason.some(issue => issue.startsWith("Safari browser evidence is unavailable:")));
    await writeFile(join(artifacts, `${stage.id}.safari.json`), JSON.stringify(evidence(stage)));
    const passed = await executeStages([stage], options);
    assert.equal(passed[0].status, "passed");
    assert.equal(passed[0].audit.safari.ok, true);
    assert.equal(passed[0].safariEvidence, `${stage.id}.safari.json`);
    assert.equal(auditResults(passed).status, "passed");
    assert.equal(auditResults([{...passed[0], audit: undefined}]).status, "failed");
}));

test("XCTest audit queries honor cancellation and cannot pass after a timed-out or failed probe", async () => fixture(async directory => {
    const stage = {id: "safari.audit-probe", group: "safari", command: "node", args: [], cwd: ".", dependencies: [], requirements: [],
        timeoutSeconds: 1, resultBundle: true, nativeAudit: fixtureStage().nativeAudit};
    for (const [failure, status] of [[{timedOut: true}, "failed"], [{error: "probe failed"}, "failed"], [{cancelled: true}, "cancelled"], [{stopAfterProbe: true}, "cancelled"]]) {
        const calls = [];
        let stop = false;
        const stopRequested = async () => stop;
        const results = await executeStages([stage], {workspace: directory, artifacts: directory, writeJSON: atomicJSON, hashFile, stopRequested,
            preflight: {checks: {}, destinations: {macos: "platform=macOS,arch=arm64"}},
            execute: async (command, args, options) => {
                calls.push([command, ...args]);
                assert.equal(options.stopRequested, stopRequested);
                if (command === "node") { return success(); }
                assert.equal(args[3], "summary");
                if (failure.stopAfterProbe) { stop = true; }
                return {...success("{}"), ...failure};
            }});
        assert.equal(results[0].status, status);
        assert.equal(calls.length, 2);
        assert.equal(results[0].audit, undefined);
    }
}));

test("Safari coverage separates actual browser results from signing, hardware, and lock coverage", () => {
    const selectedJob = job({payload: {configuration: "Debug"}});
    const manifest = createManifest(selectedJob);
    const checks = Object.fromEntries(manifest.flatMap(stage => stage.requirements).map(name => [name, true]));
    const unaudited = manifest.map(stage => ({id: stage.id, status: "passed"}));
    assert.equal(coverageReport(selectedJob, unaudited, {checks}).safari.status, "incomplete");
    const stages = manifest.map(stage => ({id: stage.id, status: "passed",
        ...(stage.nativeAudit?.kind === "safari" ? {audit: {ok: true, safari: {ok: true}}} : {})}));
    const coverage = coverageReport(selectedJob, stages, {checks});
    assert.equal(coverage.safari.status, "passed");
    assert.equal(coverage.safari.signingMode, "local");
    assert.equal(coverage.safari.hardwareBiometrics, "not-verified");
    assert.equal(coverage.safari.macOSScreenLock, "not-tested");
    assert.equal(coverage.credentialCoverage.osEntitlementIntegration, "not-verified");
    assert.equal(coverage.fullSuiteVerified, false);
});
