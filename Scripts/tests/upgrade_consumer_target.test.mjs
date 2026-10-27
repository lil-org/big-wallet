import assert from "node:assert/strict";
import test from "node:test";
import {validateUpgradeConsumerTarget} from "../validate_upgrade_consumer_target.mjs";

function graph() {
    const products = ["WalletDomain", "WalletAuthority", "WalletFlows", "WalletNetworking"];
    const targets = [...products, "WalletStorageSupport", "CWalletCrypto"].map(name => ({
        name, type: "regular", dependencies: [],
    }));
    targets.find(value => value.name === "WalletAuthority").dependencies = ["WalletDomain", "WalletStorageSupport", "CWalletCrypto"]
        .map(name => ({byName: [name, null]}));
    targets.find(value => value.name === "WalletFlows").dependencies = ["WalletDomain", "WalletAuthority"].map(name => ({byName: [name, null]}));
    targets.find(value => value.name === "WalletNetworking").dependencies = ["WalletDomain", "WalletStorageSupport"]
        .map(name => ({byName: [name, null]}));
    const runtime = {
        manifest: {
            dependencies: [],
            products: products.map(name => ({name, type: {library: ["automatic"]}, targets: [name]})),
            targets,
        },
        description: {
            name: "WalletRuntime", path: "/repo/Packages/WalletRuntime", dependencies: [],
            targets: targets.map(({name}) => ({
                name, path: `Sources/${name}`, sources: [name === "CWalletCrypto" ? "crypto.c" : `${name}.swift`],
            })),
        },
    };
    const harness = {
        manifest: {
            dependencies: [{}],
            products: [{name: "WalletUpgradeConsumer", type: {executable: null}, targets: ["WalletUpgradeConsumer"]}],
            targets: [{name: "WalletUpgradeConsumer", type: "executable", dependencies: ["WalletDomain", "WalletAuthority", "WalletFlows"]
                .map(name => ({product: [name, "walletruntime", null, null]})),
            settings: [{kind: {swiftLanguageMode: {version: "6"}}}]}],
        },
        description: {
            name: "WalletUpgradeHarness", path: "/repo/Packages/WalletUpgradeHarness",
            dependencies: [{identity: "walletruntime", path: runtime.description.path}],
            targets: [{name: "WalletUpgradeConsumer", path: "Sources/WalletUpgradeConsumer", sources: ["Consumer.swift", "Storage.swift"]}],
        },
    };
    return {harness, runtime};
}

const runtimeTarget = (value, name = "WalletAuthority") => value.runtime.manifest.targets.find(target => target.name === name);
const runtimeSource = (value, name = "WalletAuthority") => value.runtime.description.targets.find(target => target.name === name);
const consumer = value => value.harness.manifest.targets[0];
const source = value => value.harness.description.targets[0];

test("accepts Domain, Authority and Flows products with a closed dependency graph", () => {
    const value = graph();
    assert.equal(validateUpgradeConsumerTarget(value), true);
    assert.equal(value.runtime.manifest.products.length, 4);
    assert.deepEqual(consumer(value).dependencies.map(value => value.product[0]), ["WalletDomain", "WalletAuthority", "WalletFlows"]);
});

test("accepts ordinary target dependencies and package-relative described paths", () => {
    const value = graph();
    for (const target of value.runtime.manifest.targets) {
        target.dependencies = target.dependencies.map(({byName}) => ({target: [byName[0], null]}));
    }
    runtimeTarget(value).dependencies.reverse();
    consumer(value).dependencies.reverse();
    assert.equal(validateUpgradeConsumerTarget(value), true);
});

for (const [name, mutate, expected] of [
    ["a different harness identity", value => { value.harness.description.name = "WalletRuntimeHarness"; }, /package identities/],
    ["a different runtime identity", value => { value.runtime.description.name = "OtherRuntime"; }, /package identities/],
    ["relative harness roots", value => { value.harness.description.path = "Packages/WalletUpgradeHarness"; }, /package identities/],
    ["relative runtime roots", value => { value.runtime.description.path = "Packages/WalletRuntime"; }, /package identities/],
    ["app dependencies", value => { runtimeTarget(value).dependencies.push({byName: ["Big Wallet", null]}); }, /unexpected runtime dependency/],
    ["test-support dependencies", value => { runtimeTarget(value).dependencies.push({byName: ["WalletRuntimeTestSupport", null]}); }, /unexpected runtime dependency/],
    ["networking transitively", value => { runtimeTarget(value).dependencies.push({byName: ["WalletNetworking", null]}); }, /unexpected runtime dependency/],
    ["networking as a consumer product", value => { consumer(value).dependencies[1].product[0] = "WalletNetworking"; }, /only WalletDomain, WalletAuthority and WalletFlows/],
    ["an extra consumer product dependency", value => { consumer(value).dependencies.push({product: ["WalletNetworking", "walletruntime", null, null]}); }, /only WalletDomain, WalletAuthority and WalletFlows/],
    ["duplicate consumer dependencies", value => { consumer(value).dependencies[1] = consumer(value).dependencies[0]; }, /only WalletDomain, WalletAuthority and WalletFlows/],
    ["a missing consumer dependency", value => { consumer(value).dependencies.pop(); }, /only WalletDomain, WalletAuthority and WalletFlows/],
    ["consumer by-name dependencies", value => { consumer(value).dependencies[0] = {byName: ["WalletDomain", null]}; }, /only WalletDomain, WalletAuthority and WalletFlows/],
    ["a consumer dependency from another package", value => { consumer(value).dependencies[0].product[1] = "external"; }, /only WalletDomain, WalletAuthority and WalletFlows/],
    ["a missing crypto dependency", value => { runtimeTarget(value).dependencies.pop(); }, /unexpected runtime dependency/],
    ["a duplicate runtime dependency", value => { runtimeTarget(value).dependencies[2] = runtimeTarget(value).dependencies[0]; }, /unexpected runtime dependency/],
    ["a Domain-to-Authority dependency cycle", value => { runtimeTarget(value, "WalletDomain").dependencies.push({byName: ["WalletAuthority", null]}); }, /unexpected runtime dependency/],
    ["a crypto dependency cycle", value => { runtimeTarget(value, "CWalletCrypto").dependencies.push({byName: ["WalletAuthority", null]}); }, /unexpected runtime dependency/],
    ["a runtime product dependency", value => { runtimeTarget(value).dependencies[0] = {product: ["WalletDomain", "walletruntime", null, null]}; }, /unexpected runtime dependency/],
    ["a malformed dependency record", value => { runtimeTarget(value).dependencies[0] = {byName: ["WalletDomain", null], target: ["WalletDomain", null]}; }, /Unsupported dependency/],
    ["a missing dependency inventory", value => { delete runtimeTarget(value).dependencies; }, /Invalid dependencies/],
    ["a missing ordinary runtime target", value => { value.runtime.manifest.targets = value.runtime.manifest.targets.filter(target => target.name !== "WalletStorageSupport"); }, /Missing ordinary runtime dependency/],
    ["a binary runtime target", value => { runtimeTarget(value, "CWalletCrypto").type = "binary"; }, /Missing ordinary runtime dependency/],
    ["a test runtime target", value => { runtimeTarget(value, "WalletDomain").type = "test"; }, /Missing ordinary runtime dependency/],
    ["an external described runtime package", value => { value.runtime.description.dependencies.push({identity: "external", path: "/elsewhere"}); }, /only on the local WalletRuntime/],
    ["an external manifest runtime package", value => { value.runtime.manifest.dependencies.push({sourceControl: [{identity: "external"}]}); }, /only on the local WalletRuntime/],
    ["an extra harness package", value => { value.harness.description.dependencies.push({identity: "external", path: "/elsewhere"}); }, /only on the local WalletRuntime/],
    ["an extra manifest harness package", value => { value.harness.manifest.dependencies.push({}); }, /only on the local WalletRuntime/],
    ["a redirected local package", value => { value.harness.description.dependencies[0].path = "/repo/Packages/Other"; }, /only on the local WalletRuntime/],
    ["a mismatched local package identity", value => { value.harness.description.dependencies[0].identity = "other"; }, /only on the local WalletRuntime/],
    ["an extra shipping product", value => { value.runtime.manifest.products.push({name: "Tests", type: {library: ["automatic"]}, targets: ["WalletRuntimeTestSupport"]}); }, /runtime product inventory/],
    ["a missing legitimate runtime product", value => { value.runtime.manifest.products.pop(); }, /runtime product inventory/],
    ["an executable runtime product", value => { value.runtime.manifest.products[0].type = {executable: null}; }, /runtime product inventory/],
    ["a runtime product with a different target", value => { value.runtime.manifest.products[0].targets = ["WalletRuntimeTestSupport"]; }, /runtime product inventory/],
    ["an extra harness product", value => { value.harness.manifest.products.push({name: "Other", type: {executable: null}, targets: ["WalletUpgradeConsumer"]}); }, /exactly one WalletUpgradeConsumer/],
    ["a renamed consumer product", value => { value.harness.manifest.products[0].name = "Other"; }, /exactly one WalletUpgradeConsumer/],
    ["a library consumer product", value => { value.harness.manifest.products[0].type = {library: ["automatic"]}; }, /exactly one WalletUpgradeConsumer/],
    ["a consumer product targeting a helper", value => { value.harness.manifest.products[0].targets = ["Helper"]; }, /exactly one WalletUpgradeConsumer/],
    ["an extra harness target", value => { value.harness.manifest.targets.push({name: "Helper", type: "executable", dependencies: []}); }, /exactly one WalletUpgradeConsumer/],
    ["a test consumer target", value => { consumer(value).type = "test"; }, /exactly one WalletUpgradeConsumer/],
    ["duplicate runtime targets", value => { value.runtime.manifest.targets.push(runtimeTarget(value)); }, /Invalid runtime target inventory/],
    ["duplicate described consumer targets", value => { value.harness.description.targets.push(source(value)); }, /Invalid described consumer target inventory/],
    ["missing consumer sources", value => { source(value).sources = []; }, /Unsafe upgrade consumer/],
    ["missing runtime source descriptions", value => { value.runtime.description.targets = value.runtime.description.targets.filter(target => target.name !== "WalletAuthority"); }, /Unsafe upgrade consumer/],
    ["consumer source directories outside the package", value => { source(value).path = "../../App macOS"; }, /Unsafe upgrade consumer/],
    ["runtime source directories outside the package", value => { runtimeSource(value).path = "/outside/Authority"; }, /Unsafe upgrade consumer/],
    ["archived fixtures selected as the consumer source directory", value => { source(value).path = "Sources/ShippedMain/1.0.98-147"; }, /Unsafe upgrade consumer/],
    ["archived fixtures selected as a runtime source directory", value => { runtimeSource(value).path = "Sources/ShippedMain/1.0.98-147"; }, /Unsafe upgrade consumer/],
    ["source traversal", value => { source(value).sources.push("../../outside.swift"); }, /Unsafe upgrade consumer/],
    ["absolute source escape", value => { runtimeSource(value).sources.push("/outside/Authority.swift"); }, /Unsafe upgrade consumer/],
    ["a source equal to its source directory", value => { source(value).sources.push("."); }, /Unsafe upgrade consumer/],
]) {
    test(`rejects ${name} before building`, () => {
        const value = graph();
        mutate(value);
        assert.throws(() => validateUpgradeConsumerTarget(value), expected);
    });
}

for (const file of [
    "AppDelegate.swift", "SceneDelegate.swift", "SafariWebExtensionHandler.swift", "SafariVMFixtures.swift",
    "ProducerDriver.swift", "IsolatedStorageAdapters.swift", "Archived/ProducerDriver.swift",
    "Fixtures/ShippedMain/1.0.98-147/WalletsManager.swift", "source.tar.gz", "Wallet.entitlements",
    "AlchemyJWTRequestProofKey.pem", "PrivacyInfo.xcprivacy",
]) {
    for (const [location, select] of [["consumer", source], ["runtime dependency", runtimeSource]]) {
        test(`rejects ${file} in ${location} sources`, () => {
            const value = graph();
            select(value).sources.push(file);
            assert.throws(() => validateUpgradeConsumerTarget(value), /Unsafe upgrade consumer/);
        });
    }
}

for (const [name, mutate] of [
    ["consumer resources", value => { consumer(value).resources = [{rule: {copy: {}}, path: "Fixtures"}]; }],
    ["described consumer resources", value => { source(value).resources = [{path: "Fixtures"}]; }],
    ["dependency resources", value => { runtimeTarget(value).resources = [{path: "Fixture.json"}]; }],
    ["described dependency resources", value => { runtimeSource(value).resources = [{path: "Fixture.json"}]; }],
    ["consumer plugin usage", value => { consumer(value).pluginUsages = [{plugin: ["Generate", null]}]; }],
    ["dependency plugin usage", value => { runtimeTarget(value).pluginUsages = [{plugin: ["Generate", null]}]; }],
    ["consumer plugins", value => { consumer(value).plugins = [{name: "Generate"}]; }],
    ["dependency plugins", value => { runtimeTarget(value).plugins = [{name: "Generate"}]; }],
]) {
    test(`rejects ${name}`, () => {
        const value = graph();
        mutate(value);
        assert.throws(() => validateUpgradeConsumerTarget(value), /Unsafe upgrade consumer/);
    });
}

for (const flags of [
    ["-sectcreate", "__entitlements"], ["-enable-testing"], ["-DBW_SAFARI_VM_TESTING"],
    ["-I", "Fixtures/ShippedMain"], ["ProducerDriver.swift"],
]) {
    for (const [location, select] of [["consumer", consumer], ["runtime dependency", runtimeTarget]]) {
        test(`rejects ${flags.join(" ")} in ${location} build settings`, () => {
            const value = graph();
            select(value).settings = [{unsafeFlags: flags}];
            assert.throws(() => validateUpgradeConsumerTarget(value), /Unsafe upgrade consumer/);
        });
    }
}
