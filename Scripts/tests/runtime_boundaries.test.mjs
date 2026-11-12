import assert from "node:assert/strict";
import test from "node:test";
import {boundaryConsumerContexts, boundaryPackageIdentity, parseOptions, productionSource, validateProjectMembership, validateRuntimeManifestSource, validateRuntimePackage, validateRuntimeSource} from "../check_runtime_boundaries.mjs";

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
    return {rootObject: "project", objects: {
        project: {isa: "PBXProject", mainGroup: "root"},
        root: {isa: "PBXGroup", children: ["source"], sourceTree: "<group>"},
        source: {isa: "PBXFileReference", path: sourcePath, sourceTree: "<group>"},
        build: {isa: "PBXBuildFile", fileRef: "source"},
        phase: {isa: "PBXSourcesBuildPhase", files: ["build"]},
        app: {isa: "PBXNativeTarget", name: "Wallet", productType: "com.apple.product-type.application", buildPhases: ["phase"]},
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

test("Safari extension sources cannot regain the broad runtime through another helper", () => {
    const options = {application: true, nativeExtension: true};
    for (const source of ["let services = ApplicationServices.shared",
        "let runtime: AuthorityRuntime", "let network = Networks.ethereum", "ReviewRequester.request()",
        "let factory = SafariVMApplicationServices.make", "let mutations = SafariVMMutations.shared"]) {
        assert.throws(() => validateRuntimeSource("Shared/Adapter.swift", source, options), /application or native-helper composition/);
    }
    for (const source of ["let runtime: NativeTransportRuntime", "let runtime: PopupAuthorityRuntime",
        "let configuration: AuthorityRuntimeConfiguration", "let resources: RuntimeResources",
        "// ApplicationServices is app-owned\nlet runtime: NativeTransportRuntime"]) {
        assert.doesNotThrow(() => validateRuntimeSource("Safari Shared/Services.swift", source, options));
    }
    assert.doesNotThrow(() => validateRuntimeSource("Shared/Services/ApplicationServices.swift",
        "let runtime: AuthorityRuntime", {application: true}));
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

test("Flows cannot reach secrets, authority internals or networking", () => {
    for (const source of ["import Security", "import LocalAuthentication", "import WalletStorageSupport", "import WalletNetworking",
        "let secret: SecretBytes", "let consent: ReviewConsent", "let signer: WalletSigningSession", "let permit: BroadcastDispatchPermit"]) {
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
