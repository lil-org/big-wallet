import assert from "node:assert/strict";
import {mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync} from "node:fs";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {fileURLToPath} from "node:url";
import test from "node:test";
import {inspectParserFuzzTarget, validateParserFuzzFiles, validateParserFuzzSources, validateParserFuzzTarget} from "../validate_parser_fuzz_target.mjs";
import {graphFixture} from "../native_parser_fuzz/test_support.mjs";

test("parser harness consumes the existing privileged module without exporting new APIs", () => {
    inspectParserFuzzTarget(fileURLToPath(new URL("../../", import.meta.url)));
});

for (const [name, change] of [
    ["external dependency", value => value.harness.description.dependencies.push({identity: "external", path: "/elsewhere"})],
    ["networking edge", value => value.runtime.manifest.targets.find(target => target.name === "WalletAuthority").dependencies.push({byName: ["WalletNetworking", null]})],
    ["application target", value => value.harness.manifest.targets.push({name: "App", type: "executable"})],
    ["missing dependency inventory", value => { delete value.runtime.manifest.targets[0].dependencies; }],
    ["non-Swift worker source", value => value.harness.description.targets[0].sources.push("Helper.c")],
    ["changed canary source", value => value.harness.description.targets[1].sources = ["Other.c"]],
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
        assert.throws(() => validateParserFuzzSources([imports, operation]));
    }
    assert.throws(() => validateParserFuzzSources(["import WalletAuthority"]));
    assert.throws(() => validateParserFuzzSources(["@testable import WalletAuthority"]));
    assert.throws(() => validateParserFuzzSources([imports, "@testable import AdditionalModule"]));
});

test("worker sources may split required imports and repeat permitted imports", () => {
    const fixture = graphFixture();
    fixture.harness.description.targets[0].sources.push("Helpers.swift", "Support.swift");
    assert.equal(validateParserFuzzTarget(fixture), true);
    validateParserFuzzSources([
        "@testable import WalletDomain\n@testable import WalletDomain",
        "@testable import WalletAuthority\n@testable import WalletDomain",
        "struct Helper {}",
    ]);
});

test("source inspection accepts renamed and split sources and rejects unsafe files", context => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "parser-split-sources-")));
    context.after(() => rmSync(root, {recursive: true, force: true}));
    const fixture = graphFixture();
    fixture.harness.description.path = root;
    const worker = fixture.harness.description.targets[0];
    const canary = fixture.harness.description.targets[1];
    worker.sources = ["ParserMain.swift", "Helpers.swift", "Support.swift"];
    mkdirSync(join(root, worker.path), {recursive: true});
    mkdirSync(join(root, canary.path), {recursive: true});
    writeFileSync(join(root, worker.path, "ParserMain.swift"), "@testable import WalletDomain");
    writeFileSync(join(root, worker.path, "Support.swift"), "struct Helper {}");
    writeFileSync(join(root, canary.path, "Canaries.c"), "void canary(void) {}");
    const helper = join(root, worker.path, "Helpers.swift");
    writeFileSync(helper, "@testable import WalletAuthority");
    assert.equal(validateParserFuzzTarget(fixture), true);
    validateParserFuzzFiles(fixture.harness);

    writeFileSync(helper, "@testable import WalletAuthority\nlet session = URLSession.shared");
    assert.throws(() => validateParserFuzzFiles(fixture.harness), /networking/);
    rmSync(helper);
    symlinkSync(join(root, worker.path, "Support.swift"), helper);
    assert.throws(() => validateParserFuzzFiles(fixture.harness), /escapes its package/);
    rmSync(helper);
    mkdirSync(helper);
    assert.throws(() => validateParserFuzzFiles(fixture.harness), /escapes its package/);
});
