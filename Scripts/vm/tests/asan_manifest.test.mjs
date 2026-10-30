import assert from "node:assert/strict";
import test from "node:test";
import {ASAN_APP_TESTS, ASAN_RUNTIME_TESTS, BOOTSTRAP_TOOL_NAMES, commandForStage, createManifest, PERFORMANCE_TESTS} from "../test_manifest.mjs";
import {loadRuntimeInventory} from "../runtime_inventory.mjs";

const job = ({profile = "all", ...payload} = {}) => ({
    version: 1, runId: "asan-manifest", vmId: "fixture-vm", kind: "run", profile,
    payload: {stages: [], onlyTesting: [], ...payload},
    bootstrapTools: Object.fromEntries(BOOTSTRAP_TOOL_NAMES.map(name => [name, "a".repeat(64)])),
    source: {sha256: "b".repeat(64), commit: "c".repeat(40)},
});
const asan = options => createManifest(job(options)).filter(stage => stage.group === "asan");
const tests = stages => stages.flatMap(stage => stage.nativeAudit.requiredTests);

test("both acceptance profiles include the same focused runtime and app ASan inventories", () => {
    const baseline = asan();
    assert.deepEqual(baseline.map(stage => stage.id), ["asan.focused.runtime", "asan.focused"]);
    assert.deepEqual(asan({profile: "extended"}), baseline);
    assert.deepEqual(asan({stages: ["asan"]}).map(stage => stage.nativeAudit), baseline.map(stage => stage.nativeAudit));
    const inventory = loadRuntimeInventory();
    for (const [stage, focus, entries] of [[baseline[0], ASAN_RUNTIME_TESTS, inventory.tests], [baseline[1], ASAN_APP_TESTS, inventory.appTests]]) {
        const expected = entries.filter(entry => entry.variants.includes("macos.debug") &&
            focus.some(selector => entry.id === selector || entry.id.startsWith(`${selector}/`))).map(entry => entry.id);
        assert.deepEqual(stage.nativeAudit.requiredTests, expected);
        assert.equal(new Set(expected).size, expected.length);
        for (const selector of focus) { assert.ok(expected.some(id => id === selector || id.startsWith(`${selector}/`)), selector); }
        assert.ok(stage.dependencies.includes("runtime.inventory"));
        assert.deepEqual(stage.args.filter(argument => argument.startsWith("-only-testing:")), expected.map(id => `-only-testing:${id}`));
    }
    assert.equal(baseline[0].nativeAudit.requiredTests.length, 172);
    assert.equal(baseline[1].nativeAudit.requiredTests.length, 38);
    assert.ok(tests(baseline).includes("WalletAuthorityTests/WalletCoreProxyPerformanceGateTests/testScryptDefaultParametersAndSequentialDerivationVectors"));
    assert.ok(tests(baseline).every(id => !PERFORMANCE_TESTS.some(name => id.endsWith(`/${name}`))));
});

test("ASan always builds macOS Debug with address instrumentation and without TSan", () => {
    for (const configuration of [undefined, "Debug", "Release"]) {
        for (const signing of ["local", "apple"]) {
            for (const stage of asan({stages: ["asan"], configuration, signing, runtimePlatforms: ["ios", "visionos"]})) {
                const value = option => stage.args[stage.args.indexOf(option) + 1];
                assert.equal(stage.command, "xcodebuild");
                assert.ok(stage.args.includes("test"));
                assert.ok(!stage.args.includes("test-without-building"));
                assert.equal(value("-configuration"), "Debug");
                assert.equal(value("-destination"), "$destination:macos");
                assert.equal(value("-enableAddressSanitizer"), "YES");
                assert.equal(value("-enableThreadSanitizer"), "NO");
                assert.equal(value("-parallel-testing-enabled"), "NO");
                assert.equal(stage.nativeAudit.kind, "asan");
                assert.equal(stage.resultBundle, true);
                assert.equal(stage.timeoutSeconds, 14400);
                assert.ok(!stage.env || Object.keys(stage.env).length === 0);
                if (signing === "local") {
                    assert.ok(stage.args.includes("CODE_SIGN_IDENTITY=-"));
                    assert.ok(!stage.requirements.includes("signing"));
                    assert.ok(!stage.requirements.includes("proofKey"));
                    assert.equal(stage.proofKey, undefined);
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
        assert.equal(tests(selected).length, 7);
        assert.ok(tests(selected).every(id => id.startsWith("WalletAuthorityTests/SecretBytesTests/")));
        assert.equal(selected[0].nativeAudit.filtered, true);
    }
    const method = "SecretBytesTests/testInvalidationRetiresEveryAliasAndWipesExactlyOnce";
    assert.deepEqual(tests(asan({stages: ["asan"], onlyTesting: [`${method}()`, `WalletAuthorityTests/${method}`]})),
        [`WalletAuthorityTests/${method}`]);
    const apps = asan({stages: ["asan"], onlyTesting: ["Tests macOS"]});
    assert.deepEqual(apps.map(stage => stage.id), ["asan.focused"]);
    assert.equal(tests(apps).length, 38);
    const appMethod = "Tests macOS/SecretHandlingTests/testInvalidationRejectsLateSecretResultsAndCallbacks";
    assert.deepEqual(tests(asan({stages: ["asan"], onlyTesting: [appMethod]})), [appMethod]);
    const mixed = asan({stages: ["asan"], onlyTesting: [`WalletAuthorityTests/${method}`, appMethod]});
    assert.equal(mixed.length, 2);
    assert.deepEqual(tests(mixed), [`WalletAuthorityTests/${method}`, appMethod]);
    assert.equal(tests(asan({stages: ["asan"], onlyTesting: ["WalletAuthorityTests"]})).length, 172);
});

test("explicit empty ASan selections fail while unrelated focused runs stay unchanged", () => {
    for (const selector of ["MissingTests", "Tests iOS", "WalletNetworkingTests", "SecretBytesTests/testMissing",
        "WalletAuthorityTests/WalletCoreProxyPerformanceGateTests/testSecp256k1SigningPerformanceGate"]) {
        assert.throws(() => asan({stages: ["asan"], onlyTesting: [selector]}), /ASan selection did not match/);
    }
    assert.deepEqual(asan({onlyTesting: ["Tests iOS"]}), []);
    assert.deepEqual(asan({stages: ["test"], onlyTesting: ["SecretBytesTests"]}), []);
    assert.deepEqual(asan({stages: ["tsan"]}), []);
});
