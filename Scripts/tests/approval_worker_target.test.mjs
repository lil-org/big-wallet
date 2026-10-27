import assert from "node:assert/strict";
import test from "node:test";
import {validateApprovalWorkerTarget} from "../validate_approval_worker_target.mjs";

function graph() {
    const libraries = ["WalletDomain", "WalletAuthority", "WalletFlows", "WalletNetworking"];
    const targets = libraries.concat("WalletStorageSupport", "CWalletCrypto").map(name => ({name, type: "regular", dependencies: []}));
    targets.find(target => target.name === "WalletAuthority").dependencies = ["WalletDomain", "WalletStorageSupport", "CWalletCrypto"].map(name => ({byName: [name, null]}));
    targets.find(target => target.name === "WalletFlows").dependencies = ["WalletDomain", "WalletAuthority"].map(name => ({byName: [name, null]}));
    targets.find(target => target.name === "WalletNetworking").dependencies = ["WalletDomain", "WalletStorageSupport"].map(name => ({byName: [name, null]}));
    const runtime = {
        manifest: {dependencies: [], products: libraries.map(name => ({name, type: {library: ["automatic"]}, targets: [name]})), targets},
        description: {name: "WalletRuntime", path: "/repo/Packages/WalletRuntime", dependencies: [],
            targets: targets.map(({name}) => ({name, path: `Sources/${name}`, sources: [`${name}.swift`]}))},
    };
    const harness = {
        manifest: {dependencies: [{}], products: [{name: "ApprovalCrashWorker", type: {executable: null}, targets: ["ApprovalCrashWorker"]}],
            targets: [{name: "ApprovalCrashWorker", type: "executable", dependencies: libraries.map(name => ({product: [name, "walletruntime", null, null]}))}]},
        description: {name: "WalletRuntimeHarness", path: "/repo/Packages/WalletRuntimeHarness",
            dependencies: [{identity: "walletruntime", path: runtime.description.path}],
            targets: [{name: "ApprovalCrashWorker", path: "Sources/ApprovalCrashWorker", sources: ["ApprovalCrashWorker.swift"]}]},
    };
    return {runtime, harness};
}

const authority = value => value.runtime.manifest.targets.find(target => target.name === "WalletAuthority");
const worker = value => value.harness.manifest.targets[0];
const source = value => value.harness.description.targets[0];

test("accepts the isolated worker and closed runtime dependency graph", () => {
    assert.equal(validateApprovalWorkerTarget(graph()), true);
});

for (const [name, mutate] of [
    ["app dependency", value => { authority(value).dependencies.push({byName: ["Big Wallet", null]}); }],
    ["test-support dependency", value => { authority(value).dependencies.push({byName: ["WalletRuntimeTestSupport", null]}); }],
    ["dependency cycle", value => { value.runtime.manifest.targets[0].dependencies.push({byName: ["WalletAuthority", null]}); }],
    ["resource copying", value => { worker(value).resources = [{rule: {copy: {}}, path: "Secrets"}]; }],
    ["dependency resource", value => { authority(value).resources = [{path: "Fixture.json"}]; }],
    ["build plugin", value => { worker(value).pluginUsages = [{plugin: ["BuildScript", null]}]; }],
    ["wallet entry point", value => { source(value).sources.push("AppDelegate.swift"); }],
    ["extension entry point", value => { source(value).sources.push("SafariWebExtensionHandler.swift"); }],
    ["live fixture entry point", value => { source(value).sources.push("SafariVMFixtures.swift"); }],
    ["wallet entitlements", value => { source(value).sources.push("Wallet.entitlements"); }],
    ["proof material", value => { source(value).sources.push("AlchemyJWTRequestProofKey"); }],
    ["entitlement linker setting", value => { worker(value).settings = [{unsafeFlags: ["-sectcreate", "__entitlements"]}]; }],
    ["permanent testability", value => { authority(value).settings = [{unsafeFlags: ["-enable-testing"]}]; }],
    ["external package", value => { value.runtime.description.dependencies.push({identity: "external", path: "/elsewhere"}); }],
    ["redirected local package", value => { value.harness.description.dependencies[0].path = "/elsewhere"; }],
    ["source outside package", value => { source(value).path = "../../App macOS"; }],
    ["source traversal", value => { source(value).sources.push("../../AppDelegate.swift"); }],
    ["extra harness product", value => { value.harness.manifest.products.push({name: "App", type: {library: ["automatic"]}, targets: ["App"]}); }],
    ["extra shipping product", value => { value.runtime.manifest.products.push({name: "Tests", type: {library: ["automatic"]}, targets: ["WalletRuntimeTestSupport"]}); }],
    ["wrong product owner", value => { value.runtime.manifest.products[0].targets = ["WalletRuntimeTestSupport"]; }],
    ["helper target", value => { value.harness.manifest.targets.push({name: "Helper", type: "executable", dependencies: []}); }],
    ["missing target", value => { value.runtime.manifest.targets.pop(); }],
]) {
    test(`rejects ${name} before building`, () => {
        const value = graph(); mutate(value);
        assert.throws(() => validateApprovalWorkerTarget(value));
    });
}
