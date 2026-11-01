import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import test from "node:test";
import {validateParserFuzzSource, validateParserFuzzTarget} from "../validate_parser_fuzz_target.mjs";
import {graphFixture} from "../native_parser_fuzz/test_support.mjs";

test("parser harness consumes the existing privileged module without exporting new APIs", () => {
    assert.equal(validateParserFuzzTarget(graphFixture()), true);
    validateParserFuzzSource(readFileSync(new URL("../../Packages/WalletParserFuzzHarness/Sources/WalletParserFuzzWorker/Worker.swift", import.meta.url), "utf8"));
});

for (const [name, change] of [
    ["external dependency", value => value.harness.description.dependencies.push({identity: "external", path: "/elsewhere"})],
    ["networking edge", value => value.runtime.manifest.targets.find(target => target.name === "WalletAuthority").dependencies.push({byName: ["WalletNetworking", null]})],
    ["application target", value => value.harness.manifest.targets.push({name: "App", type: "executable"})],
    ["production source copied into worker", value => value.harness.description.targets[0].sources.push("WalletCoreProxy.swift")],
    ["source path escape", value => value.harness.description.targets[0].sources = ["../../../../AppDelegate.swift"]],
    ["fixture build flag in production", value => value.runtime.manifest.targets[0].settings = [{name: "enable-testing"}]],
    ["runtime resource", value => value.runtime.manifest.targets[0].resources = [{path: "credentials"}]],
    ["arbitrary harness resource", value => value.harness.manifest.targets[0].resources[0].path = "credentials.json"],
    ["canary networking edge", value => value.harness.manifest.targets[1].dependencies.push({byName: ["WalletNetworking", null]})],
    ["build plugin", value => value.harness.manifest.targets[0].pluginUsages = [{name: "Plugin"}]],
]) {
    test(`parser harness rejects ${name}`, () => { const fixture = graphFixture(); change(fixture); assert.throws(() => validateParserFuzzTarget(fixture)); });
}

test("worker source cannot acquire live storage or networking", () => {
    const imports = "@testable import WalletDomain\n@testable import WalletAuthority\n";
    for (const operation of ["let keychain = Keychain()", "let request = URLRequest()", "AuthorityRuntime.live()", "import WalletNetworking", "SecItemCopyMatching(query, nil)", '@_silgen_name("hidden")']) {
        assert.throws(() => validateParserFuzzSource(imports + operation));
    }
    assert.throws(() => validateParserFuzzSource("import WalletAuthority"));
});
