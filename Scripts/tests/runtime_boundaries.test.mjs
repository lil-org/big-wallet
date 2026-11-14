import assert from "node:assert/strict";
import test from "node:test";
import {boundaryConsumerContexts, boundaryPackageIdentity, parseOptions, boundaryApplicationExtensionFlags, vmFixtureSources, validateProjectMembership, validateRuntimeManifestSource, validateRuntimePackage, validateRuntimeSource} from "../check_runtime_boundaries.mjs";

const root = "/fixture";
function runtimePackage() {
    const dependencies = {
        WalletDomain: [], WalletStorageSupport: [], CWalletCrypto: [],
        WalletAuthority: ["WalletDomain", "WalletStorageSupport", "CWalletCrypto"],
        WalletFlows: ["WalletDomain", "WalletAuthority"],
        WalletNetworking: ["WalletDomain", "WalletStorageSupport"],
    };
    const targets = Object.entries(dependencies).map(([name, dependencies]) => ({
        name, type: "regular", packageAccess: true, dependencies: dependencies.map(name => ({byName: [name, null]})), settings: [],
    }));
    targets.push({name: "WalletRuntimeTestSupport", type: "regular", dependencies: []},
        {name: "WalletAuthorityTests", type: "test", dependencies: [{byName: ["WalletAuthority", null]}]});
    const products = ["WalletDomain", "WalletAuthority", "WalletFlows", "WalletNetworking"]
        .map(name => ({name, type: {library: ["automatic"]}, targets: [name]}));
    return {
        manifest: {
            dependencies: [], targets, products,
        },
        description: {
            name: "WalletRuntime", path: `${root}/Packages/WalletRuntime`, dependencies: [], products: structuredClone(products),
            targets: targets.map(({name}) => ({name, path: `Sources/${name}`, sources: [name === "CWalletCrypto" ? "crypto.c" : "Value.swift"]})),
        },
    };
}
const target = value => value.manifest.targets.find(value => value.name === "WalletAuthority");
const described = value => value.description.targets.find(value => value.name === "WalletAuthority");

test("manifest flags cannot hide in an environment-dependent branch", () => {
    for (const flag of ["-enable-testing", "-package-name", "-DBW_SAFARI_VM_TESTING"]) {
        const source = `if ProcessInfo.processInfo.environment["BW_TEST_VM_RUN_ID"] == nil { settings.append(.unsafeFlags(["${flag}"])) }`;
        assert.throws(() => validateRuntimeManifestSource(source), /forbidden/);
        assert.doesNotThrow(() => validateRuntimeManifestSource(`// ${source}\n/* ${source} */`));
    }
    assert.throws(() => validateRuntimeManifestSource(".target(name: name, packageAccess: false)"), /forbidden/);
});

test("implicit products and executable test support are rejected", () => {
    const implicit = runtimePackage();
    implicit.description.products.push({name: "WalletRuntimeTestSupport", type: {executable: null}, targets: ["WalletRuntimeTestSupport"]});
    assert.throws(() => validateRuntimePackage(implicit, root), /four production libraries/);
    const executable = runtimePackage();
    executable.manifest.targets.find(target => target.name === "WalletRuntimeTestSupport").type = "executable";
    assert.throws(() => validateRuntimePackage(executable, root), /regular target/);
});

test("evaluated runtime graph permits exactly four public products and private support dependencies", () => {
    assert.equal(validateRuntimePackage(runtimePackage(), root), true);
    for (const change of [
        value => { value.description.path = "/elsewhere"; },
        value => { value.manifest.dependencies.push({fileSystem: [{path: "../Harness"}]}); },
        value => { value.description.dependencies.push({identity: "external"}); },
        value => { value.manifest.products.push({name: "WalletStorageSupport", type: {library: ["automatic"]}, targets: ["WalletStorageSupport"]}); },
        value => { value.manifest.products[0].targets.push("WalletAuthority"); },
        value => { value.manifest.products[0].type = {executable: null}; },
        value => { value.manifest.targets.push({...target(value)}); },
        value => { value.manifest.targets.pop(); },
        value => { target(value).type = "binary"; },
        value => { target(value).dependencies.pop(); },
        value => { target(value).dependencies.push({byName: ["WalletNetworking", null]}); },
        value => { target(value).dependencies[0] = {product: ["WalletDomain", "external", null, null]}; },
        value => { target(value).dependencies[0] = {target: ["WalletDomain", {platformNames: ["macos"]}]}; },
        value => { value.manifest.targets.push({name: "NewProduction", type: "regular", dependencies: []});
                   value.description.targets.push({name: "NewProduction", path: "Sources/NewProduction", sources: ["Value.swift"]}); },
    ]) {
        const value = runtimePackage();
        change(value);
        assert.throws(() => validateRuntimePackage(value, root));
    }
    const equivalent = runtimePackage();
    target(equivalent).path = "Sources/./WalletAuthority";
    target(equivalent).dependencies = target(equivalent).dependencies.map(value => ({target: value.byName}));
    assert.equal(validateRuntimePackage(equivalent, root), true);
});

test("evaluated production sources and conditional settings preserve runtime boundaries", () => {
    for (const change of [
        value => { target(value).path = "../../Shared"; },
        value => { described(value).path = "Sources/WalletDomain"; },
        value => { described(value).sources = []; },
        value => { described(value).sources.push("../Other/Injected.swift"); },
        value => { described(value).sources.push(described(value).sources[0]); },
        value => { target(value).resources = [{rule: {copy: {}}, path: "fixture"}]; },
        value => { described(value).resources = [{path: "fixture"}]; },
        value => { target(value).pluginUsages = [{plugin: ["FixturePlugin", null]}]; },
        value => { target(value).packageAccess = false; },
        ...["BW_SAFARI_VM_TESTING", "-enable-testing", "-package-name", "WalletRuntimeHarness", "WalletUpgradeHarness", "ShippedWalletProducer"]
            .map(flag => value => { target(value).settings = [{tool: "swift", condition: {config: "release"}, kind: {unsafeFlags: {_0: [flag]}}}]; }),
    ]) {
        const value = runtimePackage();
        change(value);
        assert.throws(() => validateRuntimePackage(value, root));
    }
});

test("imports are checked in every conditional branch, with explicit fixture exceptions", () => {
    for (const condition of ["BW_SAFARI_VM_TESTING", "DEBUG && BW_SAFARI_VM_TESTING", "false"]) {
        assert.throws(() => validateRuntimeSource("App/Adapter.swift",
            `#if ${condition}\n@testable import WalletAuthority\n#endif`, {application: true}));
    }
    for (const path of vmFixtureSources) {
        assert.doesNotThrow(() => validateRuntimeSource(path, "@testable import WalletAuthority", {application: true}));
        assert.doesNotThrow(() => validateRuntimeSource(path, '@_silgen_name("flock") private func lock()', {application: true}));
        assert.throws(() => validateRuntimeSource(path, '@_silgen_name("bw_secp256k1_sign_recoverable") private func sign()', {application: true}));
        assert.throws(() => validateRuntimeSource("Other/" + path.split("/").at(-1),
            "@testable import WalletAuthority", {application: true}));
    }
});

test("module import rules retain privileged and networking boundaries", () => {
    for (const module of ["AppKit", "WalletNetworking"]) {
        assert.throws(() => validateRuntimeSource("Domain/Value.swift", `import ${module}`, {module: "WalletDomain"}));
    }
    for (const module of ["WalletNetworking", "WalletFlows"]) {
        assert.throws(() => validateRuntimeSource("Authority/Work.swift", `import ${module}`, {module: "WalletAuthority"}));
    }
    for (const module of ["WalletAuthority", "WalletFlows", "LocalAuthentication"]) {
        assert.throws(() => validateRuntimeSource("Networking/Client.swift", `import ${module}`, {module: "WalletNetworking"}));
    }
    for (const module of ["CWalletCrypto", "WalletStorageSupport", "WalletRuntimeTestSupport"]) {
        assert.throws(() => validateRuntimeSource("App/Adapter.swift", `import ${module}`, {application: true}));
    }
    assert.doesNotThrow(() => validateRuntimeSource("Networking/TokenStore.swift", "import Security", {module: "WalletNetworking"}));
});

test("harmless text and unrelated declarations are not mistaken for authority access", () => {
    const source = `import Foundation
// import CWalletCrypto
/* @testable import WalletAuthority */
let message = "Unable to read Keychain or WalletPrivateKey"
let example = #"@_silgen_name("hidden") func bypass()"#
let multiline = """
import CWalletCrypto
@testable import WalletAuthority
"""
struct RequestHandle {}
struct URLSession {}`;
    for (const options of [{application: true}, {module: "WalletDomain"}, {module: "WalletNetworking"}]) {
        assert.doesNotThrow(() => validateRuntimeSource("Example.swift", source, options));
    }
    assert.throws(() => validateRuntimeSource("App/Adapter.swift", '@_silgen_name("hidden") func bypass()', {application: true}));
});

function project(sourcePath = "App/main.swift") {
    return {rootObject: "project", objects: {
        project: {isa: "PBXProject", mainGroup: "root", buildConfigurationList: "projectConfigurations"},
        projectConfigurations: {buildConfigurations: ["projectDebug"]},
        projectDebug: {name: "Debug", buildSettings: {
            BW_VM_FIXTURE_EXCLUDED_SOURCES: [...vmFixtureSources].map(path => path.split("/").at(-1)).join(" "),
            EXCLUDED_SOURCE_FILE_NAMES: "$(inherited) $(BW_VM_FIXTURE_EXCLUDED_SOURCES)",
        }},
        configurations: {buildConfigurations: ["debug"]},
        debug: {name: "Debug", buildSettings: {APPLICATION_EXTENSION_API_ONLY: "YES"}},
        root: {isa: "PBXGroup", children: ["source"], sourceTree: "<group>"},
        source: {isa: "PBXFileReference", path: sourcePath, sourceTree: "<group>"},
        build: {isa: "PBXBuildFile", fileRef: "source"},
        phase: {isa: "PBXSourcesBuildPhase", files: ["build"]},
        app: {isa: "PBXNativeTarget", name: "Wallet", productType: "com.apple.product-type.application", buildPhases: ["phase"], buildConfigurationList: "configurations"},
    }};
}

test("Xcode membership forbids duplicated runtime source and production test dependencies", () => {
    const options = {root: "/fixture", sourceExists: () => true};
    assert.equal(validateProjectMembership(project(), options), true);
    for (const path of ["Packages/WalletRuntime/Sources/WalletDomain/Value.swift", "Packages/WalletRuntimeHarness/Sources/worker.swift",
        "Packages/WalletUpgradeHarness/Sources/WalletUpgradeConsumer/Consumer.swift", "Scripts/wallet_upgrade/ProducerDriver.swift", "Tests/Fixture.swift", "../outside.swift"]) {
        assert.throws(() => validateProjectMembership(project(path), options));
    }
    assert.throws(() => validateProjectMembership(project(), {...options, sourceExists: () => false}));
    const leaked = project();
    leaked.objects.app.packageProductDependencies = ["privateProduct"];
    leaked.objects.privateProduct = {productName: "WalletRuntimeTestSupport"};
    assert.throws(() => validateProjectMembership(leaked, options));
    const fixture = project();
    fixture.objects.app.dependencies = ["dependency"];
    fixture.objects.dependency = {target: "harness"};
    fixture.objects.harness = {isa: "PBXNativeTarget", name: "ApprovalCrashWorker"};
    assert.throws(() => validateProjectMembership(fixture, options));
});

test("Safari extension targets exclude application composition and singleton helpers", () => {
    const options = {root: "/fixture", sourceExists: () => true};
    for (const path of ["Shared/Services/ApplicationServices.swift", "Shared/Services/SafariVMApplicationServices.swift",
        "Shared/Wallets/AccountNames.swift", "Shared/Ethereum/Networks.swift", "Shared/Services/ReviewRequester.swift"]) {
        const app = project(path);
        assert.equal(validateProjectMembership(app, options), true);
        app.objects.app.name = "Safari macOS";
        app.objects.app.productType = "com.apple.product-type.app-extension";
        assert.throws(() => validateProjectMembership(app, options), /application or native-helper composition/);
    }
    const extension = project("Safari Shared/SafariExtensionServices.swift");
    extension.objects.app.productType = "com.apple.product-type.app-extension";
    let sourceContext;
    assert.equal(validateProjectMembership(extension, {...options, validateSource: (_, context) => { sourceContext = context; }}), true);
    assert.deepEqual(sourceContext, {nativeExtension: true});
});

test("ordinary target settings preserve fixture exclusions and extension API checking", () => {
    const options = {root: "/fixture", sourceExists: () => true};
    for (const field of ["BW_VM_FIXTURE_EXCLUDED_SOURCES", "EXCLUDED_SOURCE_FILE_NAMES"]) {
        const value = project();
        value.objects.debug.buildSettings[field] = "";
        assert.throws(() => validateProjectMembership(value, options), /exclude VM fixture sources/);
    }
    const inherited = project();
    inherited.objects.debug.buildSettings.EXCLUDED_SOURCE_FILE_NAMES = "$(inherited) Other.swift";
    assert.equal(validateProjectMembership(inherited, options), true);
    const extension = project();
    extension.objects.app.productType = "com.apple.product-type.app-extension";
    extension.objects.debug.buildSettings.APPLICATION_EXTENSION_API_ONLY = "NO";
    assert.throws(() => validateProjectMembership(extension, options), /application-extension API/);
});

test("application-extension fixtures opt into compiler enforcement", () => {
    assert.deepEqual(boundaryApplicationExtensionFlags({}), []);
    assert.deepEqual(boundaryApplicationExtensionFlags({applicationExtension: false}), []);
    assert.deepEqual(boundaryApplicationExtensionFlags({applicationExtension: true}), ["-application-extension"]);
    for (const value of [null, "YES", 1, [], {}]) {
        assert.throws(() => boundaryApplicationExtensionFlags({applicationExtension: value}));
    }
});

test("production targets cannot package or link upgrade verification artifacts", () => {
    const options = {root: "/fixture", sourceExists: () => true};
    for (const name of ["WalletUpgradeConsumer", "ShippedWalletProducer"]) {
        const linked = project();
        linked.objects.app.packageProductDependencies = ["upgradeProduct"];
        linked.objects.upgradeProduct = {productName: name};
        assert.throws(() => validateProjectMembership(linked, options));
        assert.throws(() => validateRuntimeSource("App/Adapter.swift", `import ${name}`, {application: true}));
    }
    for (const path of ["Tests/Fixtures/ShippedMain/1.0.98-147/source.tar.gz", "Scripts/wallet_upgrade/ProducerDriver.swift"]) {
        const packaged = project(path);
        packaged.objects.phase.isa = "PBXResourcesBuildPhase";
        assert.throws(() => validateProjectMembership(packaged, options));
    }
});

test("API fixture invocation selects the requested prebuilt configuration without hidden builds", () => {
    assert.equal(parseOptions(["--configuration", "Release"]).configuration, "release");
    assert.equal(parseOptions(["--check-api", "--configuration", "Debug"]).checkAPI, true);
    assert.equal(parseOptions(["--api-only", "--configuration", "Debug"]).apiOnly, true);
    assert.throws(() => parseOptions(["--configuration", "Profile"]));
    assert.throws(() => parseOptions(["--build"]));
});

test("the private storage target may bind flock without opening app crypto linkage", () => {
    assert.doesNotThrow(() => validateRuntimeSource("Storage/Lock.swift", '@_silgen_name("flock") private func lock(_ fd: Int32, _ operation: Int32) -> Int32', {module: "WalletStorageSupport"}));
    assert.throws(() => validateRuntimeSource("Storage/Lock.swift", '@_silgen_name("bw_secp256k1_sign_recoverable") private func sign()', {module: "WalletStorageSupport"}));
});

test("Flows cannot import privileged implementation or networking", () => {
    for (const source of ["import Security", "import LocalAuthentication", "import WalletStorageSupport", "import WalletNetworking"]) {
        assert.throws(() => validateRuntimeSource("Flows/Adapter.swift", source, {module: "WalletFlows"}));
    }
    assert.doesNotThrow(() => validateRuntimeSource("Flows/Adapter.swift", "import WalletAuthority\nlet runtime: AuthorityRuntime", {module: "WalletFlows"}));
    assert.throws(() => validateRuntimeSource("Authority/Core.swift", "import WalletFlows", {module: "WalletAuthority"}));
});

test("boundary checks use the resolved SwiftPM identity in a distinct consumer module", () => {
    const identity = boundaryPackageIdentity({name: "WalletRuntime", identity: "actual_identity", dependencies: []});
    assert.equal(identity, "actual_identity");
    assert.deepEqual(boundaryConsumerContexts(identity), [
        ["external", ["-module-name", "WalletExternalBoundaryConsumer"]],
        ["package", ["-module-name", "WalletPackageBoundaryConsumer", "-package-name", "actual_identity"]],
    ]);
    assert.throws(() => boundaryPackageIdentity({name: "WalletRuntime", dependencies: []}));
    assert.throws(() => boundaryPackageIdentity({name: "Different", identity: "actual_identity", dependencies: []}));
    assert.throws(() => boundaryPackageIdentity({name: "WalletRuntime", identity: "actual_identity", dependencies: [{}]}));
    assert.throws(() => boundaryConsumerContexts(""));
});
