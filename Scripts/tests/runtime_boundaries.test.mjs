import assert from "node:assert/strict";
import test from "node:test";
import {parseOptions, parseProject, productionSource, validateProjectMembership, validateRuntimeManifest, validateRuntimeSource} from "../check_runtime_boundaries.mjs";

const manifest = `
import PackageDescription
let package = Package(name: "WalletRuntime", products: [
    .library(name: "WalletDomain", targets: ["WalletDomain"]),
    .library(name: "WalletAuthority", targets: ["WalletAuthority"]),
    .library(name: "WalletNetworking", targets: ["WalletNetworking"]),
], targets: [
    .target(name: "WalletDomain"), .target(name: "WalletStorageSupport"), .target(name: "CWalletCrypto"),
    .target(name: "WalletAuthority", dependencies: ["WalletDomain", "WalletStorageSupport", "CWalletCrypto"]),
    .target(name: "WalletNetworking", dependencies: ["WalletDomain", "WalletStorageSupport"]),
    .target(name: "WalletRuntimeTestSupport", path: "Tests/Support"),
    .testTarget(name: "WalletAuthorityTests", dependencies: ["WalletAuthority", "WalletRuntimeTestSupport"]),
])`;

test("runtime manifest permits exactly three public products and private support dependencies", () => {
    assert.equal(validateRuntimeManifest(manifest), true);
    for (const changed of [
        manifest.replace('.target(name: "WalletDomain")', '.target(name: "WalletDomain", dependencies: ["WalletAuthority"])'),
        manifest.replace('["WalletDomain", "WalletStorageSupport"]', '["WalletDomain", "WalletRuntimeTestSupport"]'),
        manifest.replace('["WalletDomain", "WalletStorageSupport", "CWalletCrypto"]', '["WalletDomain", "WalletStorageSupport", "CWalletCrypto", "WalletNetworking"]'),
        manifest.replace('.target(name: "WalletDomain")', '.target(name: "WalletDomain", dependencies: hiddenDependencies)'),
        manifest.replace('.target(name: "WalletDomain")', '.target(name: "WalletDomain", path: hiddenPath)'),
        manifest.replace('.target(name: "WalletDomain")', '.target(name: "WalletDomain", path: "../../Shared")'),
        manifest.replace('products: [', 'products: [.library(name: "WalletStorageSupport", targets: ["WalletStorageSupport"]),'),
        manifest + '\nlet injection = SwiftSetting.define("BW_SAFARI_VM_TESTING")',
        manifest + '\nlet dependency = Package.Dependency.package(path: "../WalletRuntimeHarness")',
    ]) { assert.throws(() => validateRuntimeManifest(changed)); }
});

test("only guaranteed inactive application fixture branches are excluded", () => {
    for (const condition of ["BW_SAFARI_VM_TESTING", "DEBUG && BW_SAFARI_VM_TESTING", "BW_SAFARI_VM_TESTING && os(macOS)"]) {
        const source = `#if ${condition}\n@testable import WalletAuthority\nlet raw = WalletPrivateKey.self\n#else\nimport WalletAuthority\n#endif`;
        assert.doesNotThrow(() => validateRuntimeSource("App macOS/Adapter.swift", source, {application: true}));
        assert.equal(productionSource(source, {application: true}).includes("@testable"), false);
    }
    for (const condition of ["DEBUG || BW_SAFARI_VM_TESTING", "!BW_SAFARI_VM_TESTING", "os(macOS)", "false"]) {
        assert.throws(() => validateRuntimeSource("App/Adapter.swift", `#if ${condition}\n@testable import WalletAuthority\n#endif`, {application: true}));
    }
    const fallback = "#if BW_SAFARI_VM_TESTING\nimport Foundation\n#elseif DEBUG\n@testable import WalletAuthority\n#else\nimport Foundation\n#endif";
    assert.throws(() => validateRuntimeSource("App/Adapter.swift", fallback, {application: true}));
    assert.throws(() => productionSource("#if BW_SAFARI_VM_TESTING", {application: true}));
    assert.throws(() => productionSource("#endif", {application: true}));
    assert.throws(() => validateRuntimeSource("Authority/Fixture.swift", "#if BW_SAFARI_VM_TESTING\n@testable import WalletDomain\n#endif", {module: "WalletAuthority"}));
});

test("source boundaries reject implementation dependencies while allowing RPC-auth Security", () => {
    for (const source of ["import AppKit", "import WalletNetworking", "let value = URLSession.shared", "let value = FileManager.default", "let value = Data(contentsOf: url)"]) {
        assert.throws(() => validateRuntimeSource("Domain/Value.swift", source, {module: "WalletDomain"}));
    }
    for (const source of ["import WalletNetworking", "let rpc: EthereumRPC", "let request: URLRequest"]) {
        assert.throws(() => validateRuntimeSource("Authority/Work.swift", source, {module: "WalletAuthority"}));
    }
    for (const source of ["let service: any SignedTransactionBroadcasting", "let service: any TransactionPreparing", "let value = Data(contentsOf: url)"]) {
        assert.throws(() => validateRuntimeSource("Authority/EthereumSigner.swift", source, {module: "WalletAuthority"}));
    }
    assert.doesNotThrow(() => validateRuntimeSource("Authority/Execution.swift", "let service: any SignedTransactionBroadcasting", {module: "WalletAuthority"}));
    for (const source of ["import WalletAuthority", "import LocalAuthentication", "let key: WalletPrivateKey", 'let group = "8DXC3N7E7P.org.lil.keychain"', 'let key = "org.lil.wallet.password"']) {
        assert.throws(() => validateRuntimeSource("Networking/Client.swift", source, {module: "WalletNetworking"}));
    }
    assert.doesNotThrow(() => validateRuntimeSource("Networking/TokenStore.swift", `import Security\nlet accessGroup = "8DXC3N7E7P.org.lil.wallet.rpc-auth"\nlet field = kSecAttrAccessGroup`, {module: "WalletNetworking"}));
    assert.throws(() => validateRuntimeSource("Networking/TokenStore.swift", "import Security\nlet field = kSecAttrAccessGroup", {module: "WalletNetworking"}));
    assert.doesNotThrow(() => validateRuntimeSource("Domain/Value.swift", "import Foundation\n// URLSession is not used here\nstruct Value {}", {module: "WalletDomain"}));
    assert.throws(() => validateRuntimeSource("App/Adapter.swift", "import CWalletCrypto", {application: true}));
    assert.throws(() => validateRuntimeSource("App/Adapter.swift", '@_silgen_name("hidden") func bypass()', {application: true}));
    assert.throws(() => validateRuntimeSource("App/Adapter.swift", "import WalletRuntimeTestSupport", {application: true}));
    assert.throws(() => validateRuntimeSource("App/Adapter.swift", "struct RequestHandle {}", {application: true, ownedSymbols: new Set(["RequestHandle"])}));
    assert.doesNotThrow(() => validateRuntimeSource("App/Adapter.swift", "extension RequestHandle {}", {application: true, ownedSymbols: new Set(["RequestHandle"])}));
});

function project(sourcePath = "App/main.swift") {
    return parseProject(`// !$*UTF8*$!\n{
        rootObject = project; objects = {
            project = {isa = PBXProject; mainGroup = root;};
            root = {isa = PBXGroup; children = (source,); sourceTree = "<group>";};
            source = {isa = PBXFileReference; path = "${sourcePath}"; sourceTree = "<group>";};
            build = {isa = PBXBuildFile; fileRef = source;};
            phase = {isa = PBXSourcesBuildPhase; files = (build,);};
            app = {isa = PBXNativeTarget; name = Wallet; productType = "com.apple.product-type.application"; buildPhases = (phase,);};
        };
    }`);
}

test("Xcode membership forbids duplicated runtime source and production test dependencies", () => {
    const options = {root: "/fixture", sourceExists: () => true};
    assert.equal(validateProjectMembership(project(), options), true);
    for (const path of ["Packages/WalletRuntime/Sources/WalletDomain/Value.swift", "Packages/WalletRuntimeHarness/Sources/worker.swift", "Tests/Fixture.swift", "../outside.swift"]) {
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

test("API fixture invocation selects the requested prebuilt configuration without hidden builds", () => {
    assert.equal(parseOptions(["--configuration", "Release"]).configuration, "release");
    assert.equal(parseOptions(["--check-api", "--configuration", "Debug"]).checkAPI, true);
    assert.throws(() => parseOptions(["--configuration", "Profile"]));
    assert.throws(() => parseOptions(["--build"]));
});

test("the private storage target may bind flock without opening app crypto linkage", () => {
    assert.doesNotThrow(() => validateRuntimeSource("Storage/Lock.swift", '@_silgen_name("flock") private func lock(_ fd: Int32, _ operation: Int32) -> Int32', {module: "WalletStorageSupport"}));
    assert.throws(() => validateRuntimeSource("Storage/Lock.swift", '@_silgen_name("bw_secp256k1_sign_recoverable") private func sign()', {module: "WalletStorageSupport"}));
});
