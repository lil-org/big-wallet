export function graphFixture() {
    const runtimePath = "/workspace/Packages/WalletRuntime", harnessPath = "/workspace/Packages/WalletParserFuzzHarness";
    const graph = {WalletDomain: [], WalletStorageSupport: [], CWalletCrypto: [], WalletAuthority: ["WalletDomain", "WalletStorageSupport", "CWalletCrypto"]};
    const runtimeTargets = Object.entries(graph).map(([name, dependencies]) => ({name, type: "regular", dependencies: dependencies.map(value => ({byName: [value, null]}))}));
    return {
        runtime: {
            description: {name: "WalletRuntime", path: runtimePath, dependencies: [], targets: runtimeTargets.map(value => ({name: value.name, path: `Sources/${value.name}`, sources: [value.name === "CWalletCrypto" ? "shim.c" : "Source.swift"]}))},
            manifest: {dependencies: [], targets: runtimeTargets, products: ["WalletDomain", "WalletAuthority", "WalletFlows", "WalletNetworking"].map(name => ({name, type: {library: ["automatic"]}, targets: [name]}))},
        },
        harness: {
            description: {name: "WalletParserFuzzHarness", path: harnessPath, dependencies: [{identity: "walletruntime", path: runtimePath}], targets: [
                {name: "WalletParserFuzzWorker", path: "Sources/WalletParserFuzzWorker", sources: ["Worker.swift"]},
                {name: "ParserFuzzCanaries", path: "Sources/ParserFuzzCanaries", sources: ["Canaries.c"]},
            ]},
            manifest: {dependencies: [{}], products: [{name: "WalletParserFuzzWorker", type: {executable: null}, targets: ["WalletParserFuzzWorker"]}], targets: [
                {name: "WalletParserFuzzWorker", type: "executable", resources: [{path: "Resources/fixtures.json", rule: {copy: {}}}], dependencies: [
                    {product: ["WalletDomain", "walletruntime", null, null]}, {product: ["WalletAuthority", "walletruntime", null, null]}, {byName: ["ParserFuzzCanaries", null]},
                ]},
                {name: "ParserFuzzCanaries", type: "regular", dependencies: []},
            ]},
        },
    };
}
