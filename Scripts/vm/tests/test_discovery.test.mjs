import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {readFileSync} from "node:fs";
import {mkdir, mkdtemp, realpath, rm, symlink, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import test from "node:test";
import {discoveryProductsDirectory, executionStage, parseTestEnumeration, readRecordedDiscovery, resolveTestSelection, validateDiscoveryPlan, verifyArchivedTestRuns, verifyDiscoveryProducts} from "../test_discovery.mjs";
import {auditNativeResult} from "../result_audit.mjs";
import {APP_TEST_CLASS_PLATFORMS, APP_TEST_TARGETS, RUNTIME_TEST_TARGETS} from "../test_policy.mjs";
import {ASAN_RUNTIME_TESTS} from "../test_manifest.mjs";

const fixture = JSON.parse(readFileSync(new URL("./fixtures/xcode27_2_runtime_enumeration.json", import.meta.url), "utf8"));
const policy = {runtime: true, targets: RUNTIME_TEST_TARGETS, testPlan: "WalletRuntime-Package", scheme: "WalletRuntime-Package",
    configuration: "Debug", platform: "macos", kind: "full", selectors: [], executionID: "test-runtime.macos.debug"};
const makeValue = identifiers => ({errors: [], values: [{testPlan: "Fixture", disabledTests: [],
    enabledTests: identifiers.map(identifier => ({identifier}))}]});
const hash = bytes => createHash("sha256").update(bytes).digest("hex");
const directory = "/Users/fixture/Library/Developer/Xcode/DerivedData";
const buildLogFor = root => `Build description path: ${root}/Build/Intermediates.noindex/XCBuildData/fixture.xcbuilddata\n`;

async function temporary(run) {
    const root = await realpath(await mkdtemp(join(tmpdir(), "wallet-discovery-")));
    try { await run(root); } finally { await rm(root, {recursive: true, force: true}); }
}

async function writeResultBundle(bundle) {
    await mkdir(join(bundle, "Data"), {recursive: true});
    await writeFile(join(bundle, "Data/data.fixture"), "data");
    await writeFile(join(bundle, "Info.plist"), "info");
    await writeFile(join(bundle, "database.sqlite3"), "db");
    return hash(["Data/data.fixture", "4", "Info.plist", "4", "database.sqlite3", "2", ""].join("\0"));
}

test("fresh build logs bind default DerivedData and reject unchanged builds without a product root", () => {
    const log = buildLogFor(`${directory}/Wallet`);
    const location = {directory, canonicalDirectory: directory};
    assert.equal(discoveryProductsDirectory(log, location), `${directory}/Wallet/Build/Products`);
    assert.equal(discoveryProductsDirectory(log, {...location, canonicalDirectory: "/Volumes/BigWalletBuild/Users/fixture/DerivedData"}),
        "/Volumes/BigWalletBuild/Users/fixture/DerivedData/Wallet/Build/Products");
    for (const invalid of ["Build succeeded", log + buildLogFor(`${directory}/Other`), buildLogFor("/tmp/Wallet"),
        buildLogFor(`${directory}/Wallet/../Wallet`)]) {
        assert.throws(() => discoveryProductsDirectory(invalid, location));
    }
    for (const changed of [{directory: "/tmp/DerivedData"}, {canonicalDirectory: "relative/DerivedData"}]) {
        assert.throws(() => discoveryProductsDirectory(log, {...location, ...changed}), /default DerivedData/);
    }
});

test("Xcode 27.2 flat output yields unique target-qualified identifiers", () => {
    const identifiers = parseTestEnumeration(fixture, policy);
    assert.equal(identifiers.length, 1796);
    assert.ok(identifiers.every(identifier => identifier.split("/").length === 3 && !identifier.endsWith("()")));
    assert.deepEqual([...new Set(identifiers.map(identifier => identifier.split("/")[0]))].sort(), [...RUNTIME_TEST_TARGETS].sort());
});

test("the ASan policy selects 173 runtime methods in the captured Xcode 27.2 enumeration", () => {
    const identifiers = parseTestEnumeration(fixture, policy);
    const {selected} = resolveTestSelection(identifiers, {...policy, kind: "asan", focus: ASAN_RUNTIME_TESTS});
    assert.equal(selected.length, 173);
    assert.equal(selected.filter(id => id.startsWith("WalletAuthorityTests/SecretBytesTests/")).length, 7);
});

test("discovery rejects errors, empty output, omissions, disabled tests and ambiguous identities", () => {
    for (const change of [
        value => { value.errors = ["Test host failed"]; },
        value => { delete value.errors; },
        value => { value.values = []; },
        value => { value.values.push(value.values[0]); },
        value => { value.values[0].enabledTests = []; },
        value => { value.values[0].testPlan = "Other"; },
        value => { value.values[0].disabledTests.push({identifier: "WalletAuthorityTests/Tests/testDisabled()"}); },
        value => { value.values[0].enabledTests = value.values[0].enabledTests.filter(test => !test.identifier.startsWith("WalletFlowsTests/")); },
        value => { value.values[0].enabledTests.push(value.values[0].enabledTests[0]); },
        value => { value.values[0].enabledTests[0].identifier = "WrongTarget/Tests/testOne()"; },
        value => { value.values[0].enabledTests[0].identifier = "Tests/testOne()"; },
        value => { value.values[0].enabledTests[0].identifier = "WalletAuthorityTests/Tests/notATest()"; },
    ]) {
        const value = structuredClone(fixture); change(value);
        assert.throws(() => parseTestEnumeration(value, policy));
    }
});

test("critical app suites remain independent discovery obligations", () => {
    for (const [platform, target] of Object.entries(APP_TEST_TARGETS)) {
        const names = Object.entries(APP_TEST_CLASS_PLATFORMS).filter(([, variants]) => variants.includes(platform))
            .map(([name]) => `${target}/${name}/testFixture()`);
        const selectedPolicy = {...policy, runtime: false, platform, targets: [target], testPlan: "Fixture"};
        assert.equal(parseTestEnumeration(makeValue(names), selectedPolicy).length, names.length);
        assert.throws(() => parseTestEnumeration(makeValue(names.slice(1)), selectedPolicy), /critical app suite/);
    }
});

test("mobile Xcode empty-class markers never count as executable or satisfy a selector", () => {
    const value = JSON.parse(readFileSync(new URL("./fixtures/xcode27_2_ios_app_enumeration.json", import.meta.url), "utf8"));
    const mobile = {...policy, runtime: false, platform: "ios", targets: ["Tests iOS"], testPlan: "Tests iOS"};
    const identifiers = parseTestEnumeration(value, mobile);
    assert.equal(identifiers.length, 330);
    assert.deepEqual(resolveTestSelection(identifiers, {...mobile, selectors: ["CustomNetworkPackagingTests"]}).matchedSelectors, []);
    const marker = value.values[0].enabledTests.find(test => test.identifier === "Tests iOS/CustomNetworkPackagingTests");
    value.values[0].enabledTests.push(marker);
    assert.throws(() => parseTestEnumeration(value, mobile), /Duplicate empty/);
    value.values[0].enabledTests.pop();
    value.values[0].enabledTests.push({identifier: `${marker.identifier}/testContradiction()`});
    assert.throws(() => parseTestEnumeration(value, mobile), /both empty and executable/);
    value.values[0].enabledTests = [marker];
    assert.throws(() => parseTestEnumeration(value, mobile), /omits target/);
});

test("selection unions overlap and reports every independently matched selector", () => {
    const identifiers = ["WalletAuthorityTests/Tests/testOne", "WalletAuthorityTests/Tests/testTwo", "WalletAuthorityTests/Other/testThree"];
    const result = resolveTestSelection(identifiers, {...policy, selectors: ["Tests", "Tests/testOne()", "Tests/testMissing"]});
    assert.deepEqual(result.selected, identifiers.slice(0, 2));
    assert.deepEqual(result.matchedSelectors, ["Tests", "Tests/testOne()"]);
    assert.deepEqual(resolveTestSelection(identifiers, {...policy, selectors: ["Tests macOS/Tests"]}).selected, []);
    assert.throws(() => resolveTestSelection(identifiers, {...policy, focus: ["MissingTests"]}), /no match/);
    assert.deepEqual(resolveTestSelection(identifiers, {...policy, focus: ["Tests"], selectors: ["Other"]}).selected, []);
});

test("resolved execution uses the enumerated plan and exact method expectations", () => {
    const identifiers = ["WalletAuthorityTests/Tests/testOne", "WalletAuthorityTests/Tests/testTwo"];
    const stage = {id: "discover.test-runtime.macos.debug", group: "test", command: "xcodebuild", args: [],
        dependencies: ["build-runtime-tests.macos.debug"], nativeDiscovery: {...policy, selectors: ["Tests/testOne"]}};
    const evidence = {plan: {path: "/fixture/Products/Runtime.xctestrun"}};
    const resolved = executionStage(stage, identifiers, evidence);
    assert.equal(resolved.id, "test-runtime.macos.debug");
    assert.deepEqual(resolved.dependencies, [stage.id]);
    assert.deepEqual(resolved.nativeAudit.requiredTests, [identifiers[0]]);
    assert.equal(resolved.nativeDiscovery, undefined);
    assert.ok(resolved.args.includes(evidence.plan.path));
    const full = executionStage({...stage, nativeDiscovery: {...policy, selectors: []}}, identifiers, evidence);
    assert.deepEqual(full.nativeAudit.requiredTests, identifiers);
    assert.ok(!full.args.some(argument => argument.startsWith("-only-testing:")));
    assert.equal(executionStage({...stage, nativeDiscovery: {...policy, selectors: ["Missing"]}}, identifiers, evidence), null);
});

test("bound plans reject disabled configurations targets and hidden method filters", () => {
    const plan = {TestPlan: {Name: "WalletRuntime-Package"}, ContainerInfo: {SchemeName: policy.scheme},
        TestConfigurations: [{IsEnabled: true, TestTargets: RUNTIME_TEST_TARGETS.map(BlueprintName => ({BlueprintName}))}]};
    assert.equal(validateDiscoveryPlan(plan, policy), "WalletRuntime-Package");
    for (const change of [
        value => { value.TestConfigurations[0].IsEnabled = false; },
        value => { value.TestConfigurations[0].TestTargets.pop(); },
        value => { value.TestConfigurations[0].TestTargets[0].IsEnabled = false; },
        value => { value.TestConfigurations[0].TestTargets[0].OnlyTestIdentifiers = ["Tests/testOne"]; },
        value => { value.TestConfigurations[0].TestTargets[0].SkipTestIdentifiers = ["Tests/testOne"]; },
    ]) {
        const value = structuredClone(plan); change(value);
        assert.throws(() => validateDiscoveryPlan(value, policy));
    }
});

test("captured ASan plan cannot satisfy an ordinary or opposite sanitizer obligation", () => {
    const plan = JSON.parse(readFileSync(new URL("./fixtures/xcode27_2_asan_plan.json", import.meta.url), "utf8"));
    assert.equal(validateDiscoveryPlan(plan, {...policy, kind: "asan"}), "WalletRuntime-Package");
    for (const kind of ["full", "performance", "tsan"]) {
        assert.throws(() => validateDiscoveryPlan(plan, {...policy, kind}), /instrumentation/);
    }
    for (const target of plan.TestConfigurations[0].TestTargets) {
        target.TestingEnvironmentVariables.DYLD_INSERT_LIBRARIES = "";
    }
    assert.throws(() => validateDiscoveryPlan(plan, {...policy, kind: "asan"}), /instrumentation/);
});

test("captured TSan plan binds the actual thread sanitizer runtime", () => {
    const plan = JSON.parse(readFileSync(new URL("./fixtures/xcode27_2_tsan_plan.json", import.meta.url), "utf8"));
    assert.equal(validateDiscoveryPlan(plan, {...policy, kind: "tsan"}), "WalletRuntime-Package");
    for (const kind of ["full", "performance", "asan"]) {
        assert.throws(() => validateDiscoveryPlan(plan, {...policy, kind}), /instrumentation/);
    }
});

test("simulator sanitizer libraries must match the platform and requested instrumentation", () => {
    for (const platform of ["ios", "visionos"]) {
        for (const kind of ["asan", "tsan"]) {
            const plan = JSON.parse(readFileSync(new URL(`./fixtures/xcode27_2_${kind}_plan.json`, import.meta.url), "utf8"));
            const obligation = {...policy, platform, kind};
            assert.throws(() => validateDiscoveryPlan(plan, obligation), /instrumentation/);
            const suffix = platform === "ios" ? "iossim" : "xrossim";
            for (const target of plan.TestConfigurations[0].TestTargets) {
                target.TestingEnvironmentVariables.DYLD_INSERT_LIBRARIES = `/fixture/libclang_rt.${kind}_${suffix}_dynamic.dylib`;
            }
            assert.equal(validateDiscoveryPlan(plan, obligation), plan.TestPlan.Name);
            assert.throws(() => validateDiscoveryPlan(plan, {...obligation, kind: "full"}), /instrumentation/);
            assert.throws(() => validateDiscoveryPlan(plan, {...obligation, platform: platform === "ios" ? "visionos" : "ios"}), /instrumentation/);
        }
    }
});

test("host acceptance compares both commands and re-audits the exported XCTest results", async () => temporary(async artifacts => {
    const target = "Tests iOS";
    const selected = `${target}/Suite/testSelected`;
    const discovery = {id: "discover.test.ios.debug", command: "xcodebuild", nativeDiscovery: {
        ...policy, platform: "ios", runtime: false, targets: [target], selectors: [selected], executionID: "test.ios.debug",
    }};
    const plan = "/fixture/DerivedData/Wallet/Build/Products/ios.xctestrun";
    const execution = executionStage(discovery, [selected, `${target}/Suite/testOther`], {plan: {path: plan}});
    const udid = "12345678-1234-1234-1234-123456789abc";
    const destination = `platform=iOS Simulator,id=${udid}`;
    const guestArtifacts = "/Volumes/BigWalletBuild/Exchange/artifacts";
    const enumeration = ["xcodebuild", "test-without-building", "-xctestrun", plan, "-destination", destination,
        "-enumerate-tests", "-test-enumeration-style", "flat", "-test-enumeration-format", "json",
        "-test-enumeration-output-path", `${guestArtifacts}/${discovery.id}.discovery.json`];
    const bundle = `${execution.id}.xcresult`;
    const command = ["xcodebuild", "test-without-building", "-xctestrun", plan, "-destination", destination,
        "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", `-only-testing:${selected}`,
        "-resultBundlePath", `${guestArtifacts}/${bundle}`];
    const summary = {totalTestCount: 1, passedTests: 1, failedTests: 0, skippedTests: 0};
    const tree = {testNodes: [{nodeType: "Unit test bundle", name: target, children: [
        {nodeType: "Test Case", nodeIdentifier: "Suite/testSelected()", result: "Passed"},
    ]}]};
    const report = {preflight: {simulators: {ios: {udid}}, destinations: {ios: destination}}, stages: [
        {id: discovery.id, command: enumeration, exitCode: 0, discovery: {plan: {path: plan}, command: enumeration}},
        {id: execution.id, command, exitCode: 0, signal: null, resultBundle: bundle, audit: auditNativeResult(summary, tree, execution.nativeAudit)},
    ]};
    const stages = [discovery, execution];
    const summaryPath = join(artifacts, `${execution.id}.summary.json`);
    const treePath = join(artifacts, `${execution.id}.tests.json`);
    report.stages[1].resultBundleInventorySHA256 = await writeResultBundle(join(artifacts, bundle));
    await writeFile(summaryPath, JSON.stringify(summary));
    await writeFile(treePath, JSON.stringify(tree));
    await verifyArchivedTestRuns(stages, report, artifacts);
    for (const change of [
        r => { r.stages[0].command = ["xcodebuild"]; },
        r => { r.stages[0].discovery.command = ["xcodebuild"]; },
        r => { r.stages[0].exitCode = 65; },
        r => { delete r.stages[0].exitCode; },
        r => { r.stages[1].command[3] = "/other.xctestrun"; },
        r => { r.stages[1].command[5] = "platform=macOS,arch=arm64"; },
        r => { r.stages[1].command.splice(-3, 1); },
        r => { r.stages[1].command.pop(); },
        r => { r.stages[1].exitCode = 65; },
        r => { r.stages[1].signal = "SIGTERM"; },
        r => { r.stages[1].resultBundle = "another.xcresult"; },
        r => { delete r.stages[1].resultBundleInventorySHA256; },
        r => { r.stages[1].audit.counts.total = 2; },
        r => { r.preflight.simulators.ios.udid = "invalid"; },
    ]) {
        const changed = structuredClone(report);
        change(changed);
        await assert.rejects(verifyArchivedTestRuns(stages, changed, artifacts));
    }
    const dataPath = join(artifacts, bundle, "Data/data.fixture");
    await writeFile(dataPath, "larger data");
    await assert.rejects(verifyArchivedTestRuns(stages, report, artifacts), /bundle inventory/);
    await rm(dataPath);
    await assert.rejects(verifyArchivedTestRuns(stages, report, artifacts), /Incomplete XCTest result bundle/);
    await writeFile(dataPath, "data");
    tree.testNodes[0].children[0].nodeIdentifier = "Suite/testOther()";
    await writeFile(treePath, JSON.stringify(tree));
    await assert.rejects(verifyArchivedTestRuns(stages, report, artifacts), /Archived XCTest results/);
    await rm(summaryPath);
    await assert.rejects(verifyArchivedTestRuns(stages, report, artifacts), /ENOENT/);
    await writeFile(summaryPath, JSON.stringify(summary));
    await rm(treePath);
    await assert.rejects(verifyArchivedTestRuns(stages, report, artifacts), /ENOENT/);
}));

test("host acceptance requires matching clean ASan log evidence", async () => temporary(async artifacts => {
    const discovery = {id: "discover.asan.focused", command: "xcodebuild", nativeDiscovery: {
        ...policy, kind: "asan", runtime: false, targets: ["Tests macOS"], executionID: "asan.focused",
    }};
    const id = "Tests macOS/Suite/testOne";
    const plan = "/fixture/DerivedData/Wallet/Build/Products/asan.xctestrun";
    const execution = executionStage(discovery, [id], {plan: {path: plan}});
    const destination = "platform=macOS,arch=arm64";
    const bundle = `${execution.id}.xcresult`;
    const summary = {totalTestCount: 1, passedTests: 1, failedTests: 0, skippedTests: 0};
    const tree = {testNodes: [{nodeType: "Unit test bundle", name: "Tests macOS", children: [
        {nodeType: "Test Case", nodeIdentifier: "Suite/testOne()", result: "Passed"},
    ]}]};
    await writeFile(join(artifacts, `${execution.id}.summary.json`), JSON.stringify(summary));
    await writeFile(join(artifacts, `${execution.id}.tests.json`), JSON.stringify(tree));
    const clean = "Test Suite passed\n";
    const record = {id: execution.id, exitCode: 0, signal: null, command: ["xcodebuild", "test-without-building", "-xctestrun", plan, "-destination", destination,
        "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-resultBundlePath", `/Volumes/BigWalletBuild/Exchange/artifacts/${bundle}`],
        log: `${execution.id}.log`, resultBundle: bundle, resultBundleInventorySHA256: await writeResultBundle(join(artifacts, bundle)),
        audit: auditNativeResult(summary, tree, execution.nativeAudit)};
    const check = () => verifyArchivedTestRuns([execution], {preflight: {destinations: {macos: destination}}, stages: [record]}, artifacts);
    const path = join(artifacts, record.log);
    await writeFile(path, clean);
    await assert.rejects(check(), /incomplete AddressSanitizer/);
    record.audit.asanLog = {ok: false, issues: [], diagnostics: [], bytesScanned: clean.length};
    await assert.rejects(check(), /incomplete AddressSanitizer/);
    record.audit.asanLog.ok = true;
    await check();
    await writeFile(path, "ERROR: AddressSanitizer: heap-use-after-free\n");
    await assert.rejects(check(), /Archived AddressSanitizer log/);
    await rm(path);
    await assert.rejects(check(), /ENOENT/);
}));

test("host verification independently binds discovery to its configuration and product bundles", async () => temporary(async artifacts => {
    const stage = {id: "discover.test-runtime.macos.debug", dependencies: ["build-runtime-tests.macos.debug"], nativeDiscovery: policy};
    const prefix = `${stage.id}.discovery`;
    const products = "/Users/fixture/Library/Developer/Xcode/DerivedData/Wallet/Build/Products";
    const plan = {TestPlan: {Name: policy.testPlan}, ContainerInfo: {SchemeName: policy.scheme},
        TestConfigurations: [{IsEnabled: true, TestTargets: RUNTIME_TEST_TARGETS.map(BlueprintName => ({BlueprintName,
            TestBundlePath: `__TESTROOT__/Debug/${BlueprintName}.xctest`}))}]};
    Object.assign(plan.TestConfigurations[0].TestTargets[0], {IsAppHostedTestBundle: true, TestHostPath: "__TESTROOT__/Debug/Big Wallet.app"});
    const rawPlan = JSON.stringify(plan);
    const raw = JSON.stringify(fixture);
    const framework = "WalletAuthority.framework";
    const builtFramework = `${products}/Debug/PackageFrameworks/${framework}`;
    const embeddedFramework = `${products}/Debug/WalletAuthorityTests.xctest/Contents/Frameworks/${framework}`;
    const host = `${products}/Debug/Big Wallet.app/Contents/MacOS/Big Wallet`;
    const binaries = RUNTIME_TEST_TARGETS.map(target => ({target, role: "test", path: `${products}/Debug/${target}.xctest/Contents/MacOS/${target}`}));
    for (const path of [host, host + ".debug.dylib"]) { binaries.push({target: RUNTIME_TEST_TARGETS[0], role: "host", path}); }
    const rawBuildLog = buildLogFor(`${directory}/Wallet`) + binaries.map(({path}) => `Ld ${path.replaceAll(" ", "\\ ")} normal\n`).join("") +
        `Ld ${builtFramework}/Versions/A/WalletAuthority normal\nCopy ${embeddedFramework} ${builtFramework} (in target 'WalletAuthorityTests')\n`;
    const evidence = {artifact: `${prefix}.json`, sha256: hash(raw), log: `${stage.id}.log`,
        build: {artifact: "build-runtime-tests.macos.debug.log", sha256: hash(rawBuildLog), directory, canonicalDirectory: directory},
        plan: {path: `${products}/Runtime.xctestrun`, artifact: `${prefix}.xctestrun`, decodedArtifact: `${prefix}.plan.json`, sha256: hash(rawPlan)},
        targets: RUNTIME_TEST_TARGETS, testPlan: policy.testPlan, identifiers: parseTestEnumeration(fixture, policy),
        products: binaries.map(binary => ({...binary, bytes: 8, sha256: "a".repeat(64)}))};
    for (const bundle of [builtFramework, embeddedFramework]) {
        evidence.products.push({role: "framework", bytes: 8, sha256: "b".repeat(64), path: join(bundle, "WalletAuthority")});
    }
    await Promise.all([[evidence.artifact, raw], [evidence.log, "enumerated"], [evidence.plan.artifact, rawPlan],
        [evidence.plan.decodedArtifact, rawPlan], [evidence.build.artifact, rawBuildLog]].map(([path, value]) => writeFile(join(artifacts, path), value)));
    assert.equal((await readRecordedDiscovery(stage, {discovery: evidence}, artifacts)).identifiers.length, 1796);
    for (const changed of [{configuration: "Release"}, {platform: "ios"}]) {
        await assert.rejects(readRecordedDiscovery({...stage, nativeDiscovery: {...policy, ...changed}}, {discovery: evidence}, artifacts), /configuration and platform/);
    }
    const moved = structuredClone(evidence);
    moved.products[0].path += "-unrelated";
    await assert.rejects(readRecordedDiscovery(stage, {discovery: moved}, artifacts), /product binding/);
    for (const omitted of [binaries[0].path, host, host + ".debug.dylib", join(embeddedFramework, "WalletAuthority")]) {
        const incomplete = {...evidence, products: evidence.products.filter(binary => binary.path !== omitted)};
        await assert.rejects(readRecordedDiscovery(stage, {discovery: incomplete}, artifacts), /Missing linked XCTest product/);
    }
    const redirected = structuredClone(evidence);
    redirected.build.canonicalDirectory = "/Volumes/Other/DerivedData";
    await assert.rejects(readRecordedDiscovery(stage, {discovery: redirected}, artifacts), /build log directory/);
    await writeFile(join(artifacts, evidence.build.artifact), rawBuildLog + " ");
    await assert.rejects(readRecordedDiscovery(stage, {discovery: evidence}, artifacts), /identity changed/);
    await writeFile(join(artifacts, evidence.build.artifact), rawBuildLog);
    await writeFile(join(artifacts, evidence.artifact), raw + " ");
    await assert.rejects(readRecordedDiscovery(stage, {discovery: evidence}, artifacts), /identity changed/);
}));

test("replacement of an enumerated executable or plan prevents execution", async () => temporary(async root => {
    const plan = join(root, "plan.xctestrun");
    const binary = join(root, "test-binary");
    await writeFile(plan, "plan");
    await writeFile(binary, "binary");
    const evidence = {plan: {path: plan, sha256: hash("plan")}, products: [{path: binary, bytes: 6, sha256: hash("binary")}]};
    await verifyDiscoveryProducts(evidence);
    await writeFile(binary, "edited");
    await assert.rejects(verifyDiscoveryProducts(evidence), /product changed/);
    await writeFile(binary, "binary");
    await writeFile(plan, "edited plan");
    await assert.rejects(verifyDiscoveryProducts(evidence), /plan changed/);
}));

test("replacing a versioned wallet framework invalidates the bound products", async () => temporary(async root => {
    const bundle = join(root, "WalletAuthority.framework");
    const version = join(bundle, "Versions/A");
    await mkdir(version, {recursive: true});
    await writeFile(join(version, "WalletAuthority"), "original");
    const binary = join(bundle, "WalletAuthority");
    await symlink("Versions/A/WalletAuthority", binary);
    const plan = join(root, "plan.xctestrun");
    await writeFile(plan, "plan");
    const evidence = {plan: {path: plan, sha256: hash("plan")}, products: [
        {role: "framework", path: binary, bytes: 8, sha256: hash("original")},
    ]};
    await verifyDiscoveryProducts(evidence);
    await writeFile(join(version, "WalletAuthority"), "replaced");
    await assert.rejects(verifyDiscoveryProducts(evidence), /product changed/);
}));

test("mutation witnesses must match the discovered target, suite, and method", () => {
    const identifiers = ["WalletAuthorityTests/GrantTests/testExpiry"];
    for (const incorrect of ["WalletFlowsTests/GrantTests/testExpiry", "WalletAuthorityTests/OtherTests/testExpiry"]) {
        assert.throws(() => resolveTestSelection(identifiers, {...policy, mutationWitnesses: [incorrect]}), /Missing runtime mutation witness/);
    }
});
