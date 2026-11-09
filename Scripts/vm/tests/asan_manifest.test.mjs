import assert from "node:assert/strict";
import test from "node:test";
import {ASAN_APP_TESTS, ASAN_RUNTIME_TESTS, BOOTSTRAP_TOOL_NAMES, commandForStage, createManifest as staticManifest, PERFORMANCE_TESTS} from "../test_manifest.mjs";
import {auditFixtureSelection, fixtureIdentifiers, resolvedFixtureManifest as createManifest} from "./discovery_support.mjs";

const job = ({profile = "all", ...payload} = {}) => ({
    version: 1, runId: "asan-manifest", vmId: "fixture-vm", kind: "run", profile,
    payload: {stages: [], onlyTesting: [], ...payload},
    bootstrapTools: Object.fromEntries(BOOTSTRAP_TOOL_NAMES.map(name => [name, "a".repeat(64)])),
    source: {sha256: "b".repeat(64), commit: "c".repeat(40)},
});
const asan = options => createManifest(job(options)).filter(stage => stage.nativeAudit?.kind === "asan");
const tests = stages => stages.flatMap(stage => stage.nativeAudit.requiredTests);

test("both acceptance profiles include the same focused runtime and app ASan inventories", () => {
    const baseline = asan();
    assert.deepEqual(baseline.map(stage => stage.id), ["asan.focused.runtime", "asan.focused"]);
    assert.deepEqual(asan({profile: "extended"}), baseline);
    assert.deepEqual(asan({stages: ["asan"]}).map(stage => stage.nativeAudit), baseline.map(stage => stage.nativeAudit));
    for (const [stage, focus] of [[baseline[0], ASAN_RUNTIME_TESTS], [baseline[1], ASAN_APP_TESTS]]) {
        const expected = fixtureIdentifiers({...stage.nativeAudit, platform: "macos"}).filter(id =>
            focus.some(selector => id === selector || id.startsWith(`${selector}/`)));
        assert.deepEqual(stage.nativeAudit.requiredTests, expected);
        assert.equal(new Set(expected).size, expected.length);
        for (const selector of focus) { assert.ok(expected.some(id => id === selector || id.startsWith(`${selector}/`)), selector); }
        assert.ok(stage.dependencies.includes(`discover.${stage.id}`));
        assert.deepEqual(stage.args.filter(argument => argument.startsWith("-only-testing:")), expected.map(id => `-only-testing:${id}`));
    }
    assert.ok(baseline[1].nativeAudit.requiredTests.length >= ASAN_APP_TESTS.length);
    assert.ok(tests(baseline).includes("WalletAuthorityTests/WalletCoreProxyPerformanceGateTests/testScryptDefaultParametersAndSequentialDerivationVectors"));
    assert.ok(tests(baseline).every(id => !PERFORMANCE_TESTS.some(name => id.endsWith(`/${name}`))));
});

test("ASan builds macOS Debug then discovers and executes the exact bound plan", () => {
    for (const configuration of [undefined, "Debug", "Release"]) {
        for (const signing of ["local", "apple"]) {
            const selected = job({stages: ["asan"], configuration, signing, runtimePlatforms: ["ios", "visionos"]});
            const plan = staticManifest(selected);
            const resolved = createManifest(selected);
            for (const discovery of plan.filter(stage => stage.nativeDiscovery)) {
                const build = plan.find(stage => stage.id === discovery.dependencies[0]);
                const stage = resolved.find(stage => stage.id === discovery.nativeDiscovery.executionID);
                const value = option => build.args[build.args.indexOf(option) + 1];
                assert.ok(build.args.includes("build-for-testing"));
                assert.equal(value("-configuration"), "Debug");
                assert.equal(value("-destination"), "$destination:macos");
                assert.equal(value("-enableAddressSanitizer"), "YES");
                assert.equal(value("-enableThreadSanitizer"), "NO");
                assert.ok(!build.args.some(arg => arg.startsWith("-only-testing:")));
                assert.equal(discovery.nativeDiscovery.kind, "asan");
                assert.ok(stage.args.includes("test-without-building"));
                assert.ok(stage.args.includes("-xctestrun"));
                assert.equal(stage.args[stage.args.indexOf("-parallel-testing-enabled") + 1], "NO");
                assert.equal(stage.resultBundle, true);
                assert.equal(stage.timeoutSeconds, 14400);
                if (signing === "local") {
                    assert.ok(build.args.includes("CODE_SIGN_IDENTITY=-"));
                    assert.ok(!build.requirements.includes("signing"));
                    assert.ok(!build.requirements.includes("proofKey"));
                    assert.equal(build.proofKey, undefined);
                }
                const command = commandForStage(stage, {destinations: {macos: "platform=macOS,arch=arm64"}, artifacts: "/artifacts"});
                assert.ok(command.args.includes(`/artifacts/${stage.id}.xcresult`));
                assert.ok(!command.args.some(arg => arg.includes("derivedDataPath")));
            }
        }
    }
});

test("ASan selectors narrow its inventory and omit unrelated invocations", () => {
    for (const selector of ["SecretBytesTests", "WalletAuthorityTests/SecretBytesTests"]) {
        const selected = asan({stages: ["asan"], onlyTesting: [selector]});
        assert.deepEqual(selected.map(stage => stage.id), ["asan.focused.runtime"]);
        assert.ok(tests(selected).length > 1);
        assert.ok(tests(selected).every(id => id.startsWith("WalletAuthorityTests/SecretBytesTests/")));
        assert.equal(selected[0].nativeAudit.filtered, true);
    }
    const method = "SecretBytesTests/testInvalidationRetiresEveryAliasAndWipesExactlyOnce";
    assert.deepEqual(tests(asan({stages: ["asan"], onlyTesting: [`${method}()`, `WalletAuthorityTests/${method}`]})),
        [`WalletAuthorityTests/${method}`]);
    const apps = asan({stages: ["asan"], onlyTesting: ["Tests macOS"]});
    assert.deepEqual(apps.map(stage => stage.id), ["asan.focused"]);
    assert.ok(tests(apps).length >= ASAN_APP_TESTS.length);
    const appMethod = "Tests macOS/SecretHandlingTests/testInvalidationRejectsLateSecretResultsAndCallbacks";
    assert.deepEqual(tests(asan({stages: ["asan"], onlyTesting: [appMethod]})), [appMethod]);
    const mixed = asan({stages: ["asan"], onlyTesting: [`WalletAuthorityTests/${method}`, appMethod]});
    assert.equal(mixed.length, 2);
    assert.deepEqual(tests(mixed), [`WalletAuthorityTests/${method}`, appMethod]);
    const runtime = asan({stages: ["asan"]}).find(stage => stage.nativeAudit.runtime);
    assert.deepEqual(tests(asan({stages: ["asan"], onlyTesting: ["WalletAuthorityTests"]})), runtime.nativeAudit.requiredTests);
});

test("ASan rejects disjoint scopes before building and checks methods in focused suites through discovery", async () => {
    for (const selector of ["MissingTests", "Tests iOS", "WalletNetworkingTests",
        "WalletAuthorityTests/WalletCoreProxyPerformanceGateTests/testSecp256k1SigningPerformanceGate"]) {
        assert.throws(() => staticManifest(job({stages: ["asan"], onlyTesting: [selector]})), /asan selection did not match/);
    }
    const missing = job({stages: ["asan"], onlyTesting: ["SecretBytesTests/testMissing"]});
    assert.deepEqual(staticManifest(missing).filter(stage => stage.group === "asan").map(stage => stage.id),
        ["clean-asan.focused.runtime", "build-asan.focused.runtime", "discover.asan.focused.runtime"]);
    assert.equal((await auditFixtureSelection(missing)).ok, false);
    assert.deepEqual(asan({onlyTesting: ["Tests iOS"]}), []);
    assert.deepEqual(asan({stages: ["test"], onlyTesting: ["SecretBytesTests"]}), []);
    assert.deepEqual(asan({stages: ["tsan"]}), []);
});
