import assert from "node:assert/strict";
import test from "node:test";
import {sha256} from "./contract.mjs";
import {isParserSource, validateParserSourceInventory} from "./source.mjs";

test("parser provenance requires every exact source entry from the submitted snapshot", () => {
    const inventory = [
        {path: "Packages/WalletRuntime/Sources/WalletDomain/EIP712.swift", sha256: "a".repeat(64)},
        {path: "Scripts/harness_package.mjs", sha256: "e".repeat(64)},
        {path: "Scripts/native_parser_fuzz/run.mjs", sha256: "b".repeat(64)},
        {path: "Scripts/runtime_policy.mjs", sha256: "f".repeat(64)},
    ];
    const manifest = Buffer.from(JSON.stringify({version: 1, files: inventory.map(value => ({...value, type: "file", mode: 0o644}))}));
    assert.equal(validateParserSourceInventory(manifest, inventory, sha256(manifest)).files.length, 4);
    assert.throws(() => validateParserSourceInventory(manifest, inventory, "c".repeat(64)));
    assert.throws(() => validateParserSourceInventory(manifest, inventory.slice(1), sha256(manifest)));
    assert.throws(() => validateParserSourceInventory(manifest, [...inventory, {path: "extra.swift", sha256: "d".repeat(64)}], sha256(manifest)));
    for (const path of ["Scripts/harness_package.mjs", "Scripts/runtime_policy.mjs"]) {
        assert.throws(() => validateParserSourceInventory(manifest, inventory.filter(value => value.path !== path), sha256(manifest)));
        assert.throws(() => validateParserSourceInventory(manifest, inventory.map(value => value.path === path ? {...value, sha256: "c".repeat(64)} : value), sha256(manifest)));
    }
});

test("source inventory excludes generated caches and rejects parser source symlinks", () => {
    assert.equal(isParserSource("Packages/WalletParserFuzzHarness/.build/generated.swift"), false);
    assert.equal(isParserSource("App macOS/Agent.swift"), false);
    assert.equal(isParserSource("Scripts/harness_package.mjs"), true);
    assert.equal(isParserSource("Scripts/runtime_policy.mjs"), true);
    const file = {path: "Scripts/native_parser_fuzz/run.mjs", type: "symlink", mode: 0o644, sha256: "a".repeat(64)};
    const manifest = Buffer.from(JSON.stringify({version: 1, files: [file]}));
    assert.throws(() => validateParserSourceInventory(manifest, [{path: file.path, sha256: file.sha256}], sha256(manifest)));
});
