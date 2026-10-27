import assert from "node:assert/strict";
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from "node:fs";
import {tmpdir} from "node:os";
import {join} from "node:path";
import test from "node:test";
import {declaredTests, generateRuntimeInventory, RUNTIME_TEST_TARGETS, swiftCode, validateRuntimeInventory} from "../runtime_inventory.mjs";
import {auditApprovalResult, auditNativeResult, auditResults} from "../result_audit.mjs";
import {BOOTSTRAP_TOOL_NAMES, createManifest, PLATFORMS, runtimeTestsForPlatform, testingForPlatform, validateJob} from "../test_manifest.mjs";

const job = payload => ({version: 1, runId: "runtime-tests", vmId: "fixture-vm", kind: "run", profile: "all",
    payload: {stages: [], onlyTesting: [], ...payload}, bootstrapTools: Object.fromEntries(BOOTSTRAP_TOOL_NAMES.map(name => [name, "a".repeat(64)])),
    source: {sha256: "b".repeat(64), commit: "c".repeat(40)}});

test("Swift test inventory respects platform/configuration conditions and ignores source-looking strings", () => {
    const source = `@testable import WalletDomain
class ExampleTests: XCTestCase {
    let text = #"func testFake() {}"#
    /* outer /* func testComment() {} */ */
    func testAlways() { let text = "}" }
    #if os(macOS) && DEBUG
    func testMacDebug() {}
    #elseif canImport(UIKit)
    func testUIKit() {}
    #else
    func testMacRelease() {}
    #endif
    #if SWIFT_PACKAGE
    func testPackage() {}
    #else
    func testAppOnly() {}
    #endif
}
extension ExampleTests { func testExtension() {} }
`;
    assert.deepEqual(declaredTests(source, "macos", "Debug"), ["ExampleTests/testAlways", "ExampleTests/testMacDebug", "ExampleTests/testPackage", "ExampleTests/testExtension"]);
    assert.deepEqual(declaredTests(source, "macos", "Release"), ["ExampleTests/testAlways", "ExampleTests/testMacRelease", "ExampleTests/testPackage", "ExampleTests/testExtension"]);
    for (const platform of ["ios", "visionos"]) {
        assert.deepEqual(declaredTests(source, platform, "Debug"), ["ExampleTests/testAlways", "ExampleTests/testUIKit", "ExampleTests/testPackage", "ExampleTests/testExtension"]);
    }
    assert.equal(swiftCode(source).split("\n").length, source.split("\n").length);
    assert.throws(() => declaredTests("#if DEBUG\nclass Tests: XCTestCase { func testValue() {} }", "macos", "Debug"), /Unclosed/);
});

test("generated inventory requires every test target and rejects duplicate declarations", () => {
    const root = mkdtempSync(join(tmpdir(), "wallet-runtime-inventory-"));
    try {
        for (const target of RUNTIME_TEST_TARGETS) {
            const directory = join(root, "Packages/WalletRuntime/Tests", target);
            mkdirSync(directory, {recursive: true});
            writeFileSync(join(directory, "Tests.swift"), `@testable import ${target.slice(0, -5)}\nclass ${target}: XCTestCase { func testOne() {} }`);
        }
        const inventory = generateRuntimeInventory(root);
        assert.equal(validateRuntimeInventory(inventory).tests.length, RUNTIME_TEST_TARGETS.length);
        assert.ok(inventory.tests.every(test => test.variants.length === 6));
        writeFileSync(join(root, "Packages/WalletRuntime/Tests/WalletDomainTests/Duplicate.swift"), "class WalletDomainTests: XCTestCase { func testOne() {} }");
        assert.throws(() => generateRuntimeInventory(root), /Duplicate/);
        assert.throws(() => validateRuntimeInventory({...inventory, tests: inventory.tests.slice(1)}), /omits/);
    } finally { rmSync(root, {recursive: true, force: true}); }
});

test("runtime extensions resolve XCTest classes across files for each active variant", () => {
    const root = mkdtempSync(join(tmpdir(), "wallet-runtime-extension-inventory-"));
    try {
        for (const target of RUNTIME_TEST_TARGETS) {
            const directory = join(root, "Packages/WalletRuntime/Tests", target);
            mkdirSync(join(directory, "Extensions"), {recursive: true});
            writeFileSync(join(directory, "ZTests.swift"), `@testable import ${target.slice(0, -5)}
class ${target}: XCTestCase { func testOriginal() {} }
#if os(macOS) && DEBUG
class MacOnlyTests: XCTestCase { func testMacOriginal() {} }
#endif
class Helper { func testNotXCTest() {} }
// class CommentTests: XCTestCase {}
let sourceText = "class StringTests: XCTestCase {}"
`);
            writeFileSync(join(directory, "Extensions", "AExtensions.swift"), `
@MainActor
extension ${target} {
    func testAcrossFiles() {}
    #if DEBUG
    func testDebugExtension() {}
    #else
    func testReleaseExtension() {}
    #endif
    func helper() { func testNestedFunction() {} }
}
#if os(macOS) && DEBUG
extension MacOnlyTests { func testMacExtension() {} }
#endif
extension Helper { func testHelperExtension() {} }
extension MissingTests { func testUnrelatedExtension() {} }
extension ${target}.Helper { func testNestedTypeExtension() {} }
extension CommentTests { func testCommentExtension() {} }
extension StringTests { func testStringExtension() {} }
`);
        }
        const inventory = generateRuntimeInventory(root);
        for (const target of RUNTIME_TEST_TARGETS) {
            const entry = name => inventory.tests.find(test => test.id === `${target}/${name}`);
            assert.equal(entry(`${target}/testAcrossFiles`).variants.length, 6);
            assert.deepEqual(entry(`${target}/testDebugExtension`).variants, ["macos.debug", "ios.debug", "visionos.debug"]);
            assert.deepEqual(entry(`${target}/testReleaseExtension`).variants, ["macos.release", "ios.release", "visionos.release"]);
            assert.deepEqual(entry("MacOnlyTests/testMacExtension").variants, ["macos.debug"]);
            assert.equal(inventory.tests.filter(test => test.id.startsWith(`${target}/`)).length, 6);
        }
        const directory = join(root, "Packages/WalletRuntime/Tests/WalletDomainTests");
        const duplicate = join(directory, "DuplicateExtension.swift");
        writeFileSync(duplicate, "extension WalletDomainTests { func testAcrossFiles() {} }");
        assert.throws(() => generateRuntimeInventory(root), /Duplicate runtime test: WalletDomainTests\/WalletDomainTests\/testAcrossFiles/);
        rmSync(duplicate);
        writeFileSync(join(directory, "UnclosedExtension.swift"), "extension WalletDomainTests { func testUnclosed() {}\n");
        assert.throws(() => generateRuntimeInventory(root), /Unclosed XCTest class: WalletDomainTests/);
    } finally { rmSync(root, {recursive: true, force: true}); }
});

test("runtime extension discovery does not join conditional directives across files", () => {
    const root = mkdtempSync(join(tmpdir(), "wallet-runtime-extension-condition-"));
    try {
        for (const target of RUNTIME_TEST_TARGETS) {
            const directory = join(root, "Packages/WalletRuntime/Tests", target);
            mkdirSync(directory, {recursive: true});
            writeFileSync(join(directory, "Tests.swift"), `@testable import ${target.slice(0, -5)}\nclass ${target}: XCTestCase { func testOriginal() {} }`);
        }
        const directory = join(root, "Packages/WalletRuntime/Tests/WalletDomainTests");
        writeFileSync(join(directory, "AExtension.swift"), "#if DEBUG\nextension WalletDomainTests { func testExtension() {} }");
        writeFileSync(join(directory, "ZDirective.swift"), "#endif\n");
        assert.throws(() => generateRuntimeInventory(root), /Unclosed Swift conditional directive/);
    } finally { rmSync(root, {recursive: true, force: true}); }
});

test("package selectors produce simulator and Release stages with explicit testability and exact inventory", () => {
    const manifest = createManifest(job({stages: ["test"], onlyTesting: ["WalletNetworkingTests/SafariRPCServiceTests"], configuration: "Release"}));
    for (const platform of ["macos", "ios", "visionos"]) {
        const build = manifest.find(stage => stage.id === `build-runtime-tests.${platform}.release`);
        const run = manifest.find(stage => stage.id === `test-runtime.${platform}.release`);
        assert.equal(build.cwd, "Packages/WalletRuntime");
        assert.ok(build.args.includes("ENABLE_TESTABILITY=YES"));
        assert.ok(build.args.includes("WalletRuntime-Package"));
        assert.deepEqual(build.args.filter(arg => arg.startsWith("-only-testing:")), run.args.filter(arg => arg.startsWith("-only-testing:")));
        assert.deepEqual(run.nativeAudit.requiredTests, runtimeTestsForPlatform(["WalletNetworkingTests/SafariRPCServiceTests"], platform, "Release"));
        assert.ok(run.nativeAudit.requiredTests.length > 0);
        assert.ok(!run.requirements.includes("signing") && !run.requirements.includes("proofKey"));
    }
    assert.ok(!manifest.some(stage => /^test\.(?:macos|ios|visionos)/.test(stage.id)));
    const compilation = createManifest(job({stages: ["runtime"], onlyTesting: ["WalletNetworkingTests"], configuration: "Debug"}));
    assert.deepEqual(compilation.map(stage => stage.id), ["runtime.WalletNetworkingTests.debug"]);
    assert.ok(compilation[0].args.includes("-enable-testing"));
    const mac = createManifest(job({stages: ["test"], onlyTesting: ["WalletNetworkingTests"], configuration: "Debug", runtimePlatforms: ["macos"]}));
    assert.ok(mac.some(stage => stage.id === "test-runtime.macos.debug"));
    assert.ok(!mac.some(stage => /^test-runtime\.(?:ios|visionos)/.test(stage.id)));
    for (const runtimePlatforms of [["macos", "macos"], ["watchos"], "macos"]) {
        assert.throws(() => validateJob(job({runtimePlatforms})));
    }
});

test("runtime audit rejects omitted, duplicate, extra, skipped, and zero tests", () => {
    const requiredTests = ["WalletDomainTests/DomainTests/testOne", "WalletDomainTests/DomainTests/testTwo"];
    const policy = {runtime: true, kind: "full", configuration: "Release", platform: "macos", requiredTests};
    const tree = names => ({testNodes: [{nodeType: "Unit test bundle", name: "WalletDomainTests", children: names.map(name => ({nodeType: "Test Case", nodeIdentifier: name, result: "Passed"}))}]});
    const summary = total => ({totalTestCount: total, passedTests: total, failedTests: 0, skippedTests: 0});
    const names = requiredTests.map(name => name.split("/").slice(1).join("/") + "()");
    assert.equal(auditNativeResult(summary(2), tree(names), policy).ok, true);
    for (const actual of [[], names.slice(0, 1), [names[0], names[0]], [...names, "DomainTests/testOther()"]]) {
        assert.equal(auditNativeResult(summary(actual.length), tree(actual), policy).ok, false);
    }
    const skipped = tree(names); skipped.testNodes[0].children[0].result = "Skipped";
    assert.equal(auditNativeResult({...summary(2), passedTests: 1, skippedTests: 1}, skipped, policy).ok, false);
    assert.equal(auditResults([{id: "runtime", status: "passed", nativeAudit: policy}]).status, "failed");
    const sameName = {testNodes: [{nodeType: "Unit test bundle", name: "WalletDomainTests", children: [
        {nodeType: "Test Case", nodeIdentifier: "WalletDomainTests/testOne()", result: "Passed"},
    ]}]};
    const sameNamePolicy = {...policy, requiredTests: ["WalletDomainTests/WalletDomainTests/testOne"]};
    assert.equal(auditNativeResult(summary(1), sameName, sameNamePolicy).ok, true);
    const wrongTarget = structuredClone(sameName); wrongTarget.testNodes[0].name = "WalletNetworkingTests";
    assert.equal(auditNativeResult(summary(1), wrongTarget, sameNamePolicy).ok, false);
});

test("split coordinator and password selectors retain their platform-specific app tests", () => {
    for (const platform of PLATFORMS) {
        assert.deepEqual(testingForPlatform(["PasswordStorageTests"], platform, "Debug"), [`${platform.target}/PasswordStorageTests`]);
        assert.deepEqual(testingForPlatform(["NativeApprovalCoordinatorTests"], platform, "Debug"),
            platform.id === "macos" ? ["Tests macOS/NativeApprovalCoordinatorTests"] : []);
    }
    const selection = "NativeApprovalCoordinatorTests/testFreshReviewKeepsOldSelectionAndPasswordCallbacksInactive";
    assert.deepEqual(runtimeTestsForPlatform([selection], "macos", "Debug"), []);
    assert.deepEqual(testingForPlatform([selection], PLATFORMS[0], "Debug"), [`Tests macOS/${selection}`]);
    const pure = runtimeTestsForPlatform(["PasswordStorageTests"], "macos", "Debug")[0];
    assert.ok(pure);
    assert.deepEqual(testingForPlatform([pure.split("/").slice(1).join("/")], PLATFORMS[0], "Debug"), []);
});

test("systematic approval profile limits are explicit and incomplete evidence cannot pass", () => {
    assert.doesNotThrow(() => validateJob(job({approvalArgs: ["--systematic", "extended", "--systematic-only", "--trace-limit", "4096"]})));
    for (const args of [["--systematic", "all", "--trace-limit", "257"], ["--systematic", "off", "--trace-limit", "1"], ["--random-only", "--systematic-only"]]) {
        assert.throws(() => validateJob(job({approvalArgs: args})));
    }
    const baseline = createManifest(job({stages: ["approval"], configuration: "Debug"})).find(stage => stage.id === "approval.debug");
    assert.deepEqual(baseline.approvalAudit, {profile: "all", traceLimit: 256, modes: ["native", "popup"]});
    const extended = createManifest({...job({stages: ["approval"], configuration: "Release"}), profile: "extended"});
    assert.equal(extended.find(stage => stage.id === "approval.systematic-release").approvalAudit.traceLimit, 4096);
    const templates = ["authentication-cancellation", "signing-cancellation", "signing-revocation", "publication-cancellation",
        "checkpoint-cancellation", "dispatch-cancellation", "completion-cancellation", "delivery-cancellation"];
    const scenarios = ["native", "popup"].flatMap(mode => ["ethereum", "solana"].flatMap(provider => templates.map(template => ({
        scenario: `${mode}/systematic/${provider}/${template}`, profile: "all", completed: 1, pruned: 0, finished: 1, frontier: 0,
        requests: 2, faultsApplied: 1,
        bounds: {preemptions: 1, transitions: 64, traces: 256, faults: 1, actors: 2},
    }))));
    const sourceIdentity = {version: 1, source: {kind: "vm-snapshot", sha256: "a".repeat(64), commit: "b".repeat(40), fileCount: 7},
        worker: {sha256: "c".repeat(64), bytes: 123}};
    const evidence = {version: 1, sourceIdentity, status: "complete", profile: "all", traces: scenarios.length, frontier: 0, scenarios};
    assert.equal(auditApprovalResult(evidence, baseline.approvalAudit).ok, true);
    for (const changed of [{status: "incomplete"}, {frontier: 1}, {traces: 0}, {sourceIdentity: undefined},
        {sourceIdentity: {...sourceIdentity, worker: {...sourceIdentity.worker, sha256: "unverified"}}},
        {scenarios: scenarios.slice(1)}, {scenarios: [...scenarios, scenarios[0]]},
        {scenarios: scenarios.map(value => ({...value, requests: 1}))}, {scenarios: scenarios.map(value => ({...value, faultsApplied: 0}))}]) {
        assert.equal(auditApprovalResult({...evidence, ...changed}, baseline.approvalAudit).ok, false);
    }
});
