import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import test from "node:test";
import {applyMutation, groupedWitnesses, loadManifest, selectedMutants, validateManifest} from "./contract.mjs";
import {javascriptCommand, nativeCommand} from "./commands.mjs";
import {parseOptions} from "./run.mjs";

const repository = new URL("../../", import.meta.url);
const {manifest} = await loadManifest();

test("the six core and nineteen extended mutations each have unique current anchors and named witnesses", async () => {
    assert.equal(selectedMutants(manifest, "core").length, 6);
    assert.equal(selectedMutants(manifest, "extended").length, 19);
    for (const mutant of manifest.mutants) {
        const source = await readFile(new URL(mutant.source, repository), "utf8");
        const changed = applyMutation(source, mutant);
        assert.notEqual(changed.patch.beforeSHA256, changed.patch.afterSHA256, mutant.id);
        const witness = await readFile(new URL(mutant.witness.file, repository), "utf8");
        assert.ok(witness.includes(mutant.witness.marker), mutant.id);
        if (mutant.family !== "javascript") {
            assert.ok(witness.includes(`func ${mutant.witness.selector.split("/")[2]}(`), mutant.id);
        } else { assert.ok(witness.includes(`test("${mutant.witness.selector}"`), mutant.id); }
    }
    assert.deepEqual(groupedWitnesses(selectedMutants(manifest, "core")).map(group => group.family), ["runtime", "macos-app"]);
});

test("source mutation refuses absent or duplicate anchors and changes only the selected span", () => {
    const mutant = {id: "fixture.guard", source: "file.swift", edits: [{find: "check()", replace: "true"}]};
    assert.equal(applyMutation("before check() after", mutant).source, "before true after");
    assert.throws(() => applyMutation("missing", mutant), /missing or ambiguous/);
    assert.throws(() => applyMutation("check() check()", mutant), /missing or ambiguous/);
    assert.equal(applyMutation("before check() after", mutant).patch.edits[0].offset, 7);
});

test("stale authentication mutation rebinds the incoming handle without changing its witness", async () => {
    const mutant = manifest.mutants.find(value => value.id === "access.stale-authentication");
    assert.equal(mutant.witness.selector, "Tests macOS/WalletAccessControllerTests/testOldAuthenticationCannotReplaceNewAuthenticationOrUnlockAfterLock");
    const source = await readFile(new URL(mutant.source, repository), "utf8");
    const changed = applyMutation(source, mutant);
    assert.ok(changed.source.includes("attempt originalAttempt: AuthenticationAttempt"));
    assert.ok(changed.source.includes("let attempt = authentication ?? originalAttempt"));
    assert.ok(changed.source.includes("guard attempt.isCurrent, authentication === attempt,"));
    assert.equal(changed.patch.edits.length, 1);
});

test("curated manifest cannot target tests generated source or unsafe paths", () => {
    for (const path of ["../source.swift", "/source.swift", "Tests/Guard.swift", "Packages/WalletRuntime/Package.swift",
        "Safari Shared/Resources/protocol.generated.js", "Safari Shared/Resources/inpage.js"]) {
        const changed = structuredClone(manifest);
        changed.mutants[0].source = path;
        assert.throws(() => validateManifest(changed), /Invalid curated mutation/);
    }
    const changed = structuredClone(manifest);
    changed.mutants[1].id = changed.mutants[0].id;
    assert.throws(() => validateManifest(changed));
});

test("native command plans use exact witnesses default DerivedData and explicit local signing", () => {
    const options = {macos: "platform=macOS,arch=arm64", ios: "platform=iOS Simulator,id=00000000-0000-0000-0000-000000000001", signing: "local", runId: "fixture"};
    for (const family of ["runtime", "macos-app", "ios-app"]) {
        const command = nativeCommand(family, "build-for-testing", ["Tests macOS/Class/testOne"], options);
        assert.equal(command.command, "xcodebuild");
        assert.equal(command.args.filter(argument => argument.startsWith("-only-testing:")).length, 1);
        assert.equal(command.args.includes("-derivedDataPath"), false);
        assert.ok(command.args.includes("CODE_SIGN_IDENTITY=-"));
        if (family !== "runtime") {
            assert.ok(command.args.includes("BW_VM_VERIFICATION_BUILD=YES"));
            assert.ok(command.args.includes("CODE_SIGN_ENTITLEMENTS="));
            assert.ok(command.args.includes("BW_TEST_VM_RUN_ID=fixture"));
        }
    }
    const apple = nativeCommand("macos-app", "build-for-testing", [], {...options, signing: "apple"});
    assert.equal(apple.args.includes("BW_VM_VERIFICATION_BUILD=YES"), false);
    assert.throws(() => nativeCommand("runtime", "-showBuildSettings", [], options), /Unsupported/);
    assert.throws(() => nativeCommand("runtime", "test-without-building", [], options), /exact built/);
    const run = nativeCommand("runtime", "test-without-building", ["WalletAuthorityTests/Class/testOne"],
        {...options, testRunPath: "/products/plan.xctestrun"}, "/artifacts/tests.xcresult");
    assert.equal(run.args[run.args.indexOf("-xctestrun") + 1], "/products/plan.xctestrun");
    assert.equal(run.args.includes("-scheme"), false);
    const js = javascriptCommand([{selector: "a (literal) + value", file: "fixture.test.mjs"}], {nodeExecutable: "/node", runnerRoot: "/repo"});
    assert.equal(js.args[1], "--test-name-pattern=^(?:a \\(literal\\) \\+ value)$");
});

test("execution CLI requires the guest-owned destination and output contract", () => {
    const args = ["--tier", "core", "--signing", "local", "--destination-macos", "platform=macOS,arch=arm64",
        "--failure-dir", "/artifacts", "--scratch-dir", "/scratch", "--workspace", "/source"];
    assert.equal(parseOptions(args).tier, "core");
    assert.throws(() => parseOptions([...args, "--tier", "extended"]));
    assert.throws(() => parseOptions(args.map(value => value === "core" ? "extended" : value)), /destinations/);
    assert.throws(() => parseOptions(args.map(value => value === "/artifacts" ? "/scratch" : value)), /distinct/);
});

