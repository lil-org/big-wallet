import assert from "node:assert/strict";
import test from "node:test";
import {DECRYPT_MUTATIONS, INPUT_LIMITS, PARSERS, PROFILES, fixtureData, nativeRequest, parseOptions, validateCase} from "./contract.mjs";
import {corpus, EIP712_BUDGET_FAMILIES, EIP712_PRIMITIVE_FAMILIES, EIP712_STRUCTURE_FORMS, generatedCases, planSummary, plannedCases, random, shortvec, solanaMessageAtWireBoundary, typedDataBudgetCases} from "./cases.mjs";
import {compareResult, solanaOracle} from "./oracles.mjs";
import {hostReplayCommand, shrinkCandidates} from "./run.mjs";

test("seeded structure-aware cases reproduce exactly and stay within native entry-point bounds", () => {
    for (const mode of PARSERS) {
        const first = [...generatedCases(mode, 0xc0ffee, 128)];
        assert.deepEqual(first, [...generatedCases(mode, 0xc0ffee, 128)]);
        assert.notDeepEqual(first, [...generatedCases(mode, 0x5eed, 128)]);
        for (const candidate of [...corpus(mode), ...first]) {
            validateCase(candidate);
            assert.ok(Buffer.from(candidate.inputBase64, "base64").length <= INPUT_LIMITS[mode]);
        }
    }
});

test("all parser plan requires 6000 generated cases plus every committed corpus entry", () => {
    const plan = planSummary("all", "parsers");
    assert.equal(plan.count, 6000 + PARSERS.reduce((sum, mode) => sum + corpus(mode).length, 0));
    assert.deepEqual(plan, planSummary("all", "parsers"));
    for (const mode of PARSERS) { assert.equal(plan.groups[`${mode}/generated/12648430`], 2000); }
    for (const family of EIP712_PRIMITIVE_FAMILIES) { assert.ok(plan.primitiveFamilies[`12648430/${family}`] > 0); }
    for (const form of EIP712_STRUCTURE_FORMS) { assert.ok(plan.structureForms[`12648430/${form}`] > 0); }
    for (const family of EIP712_BUDGET_FAMILIES) for (const edge of ["within", "exceeded"]) { assert.equal(plan.budgetBoundaries[`${family}/${edge}`], 1); }
    assert.equal(plan.entryPoints["EIP712.checkedDigest"], 24);
    assert.deepEqual(plan.solanaWireSizes, {"1232": 1, "1233": 1});
});

test("keystore corpus independently labels stored-reader acceptance beyond user admission limits", () => {
    const entries = corpus("keystore");
    const boundaries = entries.filter(candidate => candidate.name.startsWith("input-limit-") || /^pbkdf2-\d+-\d+-[01]$/.test(candidate.name));
    assert.equal(boundaries.length, 8);
    for (const candidate of boundaries) {
        validateCase(candidate);
        const document = JSON.parse(Buffer.from(candidate.inputBase64, "base64"));
        assert.deepEqual(document.activeAccounts, []);
        assert.equal(candidate.expected.strictAccepted, true);
    }
    const differences = boundaries.filter(candidate => candidate.expected.accepted === false);
    assert.deepEqual(differences.map(candidate => candidate.name), ["input-limit-exceeded", "pbkdf2-2000000-32-1", "pbkdf2-1000000-33-1", "pbkdf2-62500-1024-1"]);
    for (const candidate of differences) { assert.equal(candidate.expected.rejection, "limitExceeded"); }
    for (const name of ["empty", "invalid-utf8", "non-object"]) {
        assert.deepEqual(entries.find(candidate => candidate.name === name).expected, {accepted: false, strictAccepted: false});
    }
});

test("Solana wire limit isolates a valid canonical message from its one-byte-larger counterpart", () => {
    const candidate = corpus("solana").find(value => value.name === "wire-size.within");
    const oracle = solanaOracle(candidate);
    assert.equal(oracle.accepted, true); assert.equal(oracle.canonical, true);
    assert.equal(oracle.summary.instructions.length, 1);
    const within = solanaMessageAtWireBoundary(1_232), exceeded = solanaMessageAtWireBoundary(1_233);
    assert.equal(within.length, 1_232); assert.equal(exceeded.length, 1_233);
    assert.equal(oracle.summary.instructions[0].dataHex.length / 2, 1126);
    assert.ok(within.subarray(0, 104).equals(exceeded.subarray(0, 104)));
    assert.ok(within.subarray(106).equals(exceeded.subarray(106, exceeded.length - 1)));
    assert.deepEqual([...within.subarray(104, 106)], [...shortvec(1126)]);
    assert.deepEqual([...exceeded.subarray(104, 106)], [...shortvec(1127)]);
    assert.equal(corpus("solana").find(value => value.name === "wire-size.exceeded").expected.accepted, false);
});

test("every approved seed reaches every primitive family in positive equality and change cases", () => {
    for (const seed of PROFILES.extended.seeds) {
        const families = new Map(), forms = new Set();
        for (const candidate of generatedCases("eip712", seed, 128)) {
            if (candidate.expected?.accepted !== true) { continue; }
            const document = JSON.parse(Buffer.from(candidate.inputBase64, "base64"));
            const secondary = JSON.parse(Buffer.from(candidate.secondaryBase64, "base64"));
            if (candidate.relation === "differentDigest") {
                assert.notDeepEqual(secondary.message.value, document.message.value);
                assert.equal(secondary.message.marker, document.message.marker);
            }
            const family = document.types.Root.find(field => field.name === "value").type;
            const detail = document.types.Root.find(field => field.name === "detail")?.type;
            forms.add(detail === "Child" ? "struct" : detail === "Child[]" ? "structArray" : "flat");
            const relations = families.get(family) ?? new Set();
            relations.add(candidate.relation); families.set(family, relations);
        }
        assert.deepEqual([...families.keys()].sort(), [...EIP712_PRIMITIVE_FAMILIES].sort());
        assert.deepEqual([...forms].sort(), ["flat", "struct", "structArray"]);
        for (const relations of families.values()) { assert.deepEqual([...relations].sort(), ["differentDigest", "equalDigest"]); }
    }
});

test("every production typed-data resource budget has labeled admitted and rejected fixtures", () => {
    assert.deepEqual(EIP712_BUDGET_FAMILIES, ["inputBytes", "jsonDepth", "jsonTokens", "types", "fieldsPerType", "totalFields", "dependencyDepth", "valueDepth", "arrayTypeDepth", "arrayElements", "work", "processingBytes"]);
    assert.deepEqual(EIP712_PRIMITIVE_FAMILIES, ["uint8", "int16", "bool", "string", "bytes4", "address", "uint256", "uint8[]"]);
    const cases = typedDataBudgetCases();
    assert.equal(cases.length, 24);
    for (const family of EIP712_BUDGET_FAMILIES) {
        const within = cases.filter(candidate => candidate.name === `budget.${family}.within`);
        const exceeded = cases.filter(candidate => candidate.name === `budget.${family}.exceeded`);
        assert.equal(within.length, 1); assert.equal(exceeded.length, 1);
        assert.equal(within[0].expected.accepted, true); assert.equal(exceeded[0].expected.accepted, false);
        assert.equal(typeof exceeded[0].expected.rejection, "string");
        for (const candidate of [...within, ...exceeded]) {
            validateCase(candidate); assert.equal(candidate.entryPoint, "checked");
            assert.ok(Buffer.from(candidate.inputBase64, "base64").length <= INPUT_LIMITS.eip712);
        }
    }
});

test("decryption is a closed fixture matrix with no attacker-controlled KDF inputs", () => {
    assert.equal(fixtureData().keystores.length, 3);
    for (const [profile, count] of [["all", 24], ["extended", 96]]) {
        const entries = [...plannedCases(profile, "decrypt")];
        assert.equal(entries.length, count);
        for (const {candidate} of entries) {
            validateCase(candidate);
            assert.ok(DECRYPT_MUTATIONS.includes(candidate.mutation));
            assert.equal(candidate.inputBase64, undefined);
            assert.equal(nativeRequest(candidate, 0).expected, undefined);
        }
    }
    const valid = [...plannedCases("all", "decrypt")][0].candidate;
    assert.throws(() => validateCase({...valid, inputBase64: ""}));
    assert.throws(() => validateCase({...valid, mutation: "kdf"}));
    assert.throws(() => validateCase({...valid, fixtureID: "untrusted"}));
    assert.throws(() => validateCase({...valid, mutationIndex: 32}));
});

test("replay rejects invalid base64, extra fields, and payloads beyond each cap", () => {
    for (const mode of PARSERS) {
        const candidate = {name: "replay", mode, inputBase64: ""};
        validateCase(candidate);
        assert.throws(() => validateCase({...candidate, inputBase64: "===="}));
        assert.throws(() => validateCase({...candidate, inputBase64: Buffer.alloc(INPUT_LIMITS[mode] + 1).toString("base64")}));
        assert.throws(() => validateCase({...candidate, command: "execute"}));
    }
});

test("oracle comparison separates policy rejection from semantic disagreement", () => {
    const candidate = {name: "solana", mode: "solana", inputBase64: "", oracle: "malformed"};
    assert.equal(compareResult(candidate, {status: "ok", accepted: false}, {accepted: true, canonical: false}), null);
    assert.equal(compareResult({...candidate, oracle: "canonical"}, {status: "ok", accepted: false}, {accepted: true, canonical: true}).code, "canonicalAcceptance");
    assert.equal(compareResult(candidate, {status: "ok", accepted: true, summary: {n: 1}}, {accepted: true, summary: {n: 2}}).code, "normalizedMessage");
    assert.equal(compareResult({...candidate, expected: {accepted: false}}, {status: "ok", accepted: true}).kind, "expectation");
});

test("shrinking preserves labeled cases and only emits smaller unlabeled byte inputs", () => {
    const candidate = {name: "raw", mode: "eip712", inputBase64: Buffer.from("123456789").toString("base64")};
    assert.ok([...shrinkCandidates(candidate)].every(value => Buffer.from(value.inputBase64, "base64").length < 9));
    assert.equal([...shrinkCandidates({...candidate, expected: {accepted: true}})].length, 0);
    assert.equal([...shrinkCandidates({...candidate, relation: "equalDigest", secondaryBase64: candidate.inputBase64})].length, 0);
});

test("saved replay commands address exported host artifacts without interpolating shell input", () => {
    const artifact = "failure-0123456789abcdef.json";
    const command = hostReplayCommand("run-fixture", "parsers", artifact);
    assert.equal(command,
        'Scripts/test_vm.sh run all --stage parser-fuzz --parser-fuzz-replay "${BW_TEST_VM_STATE_DIR:-$HOME/Library/Application Support/Big Wallet Test VM}/results/run-fixture/artifacts/failures/fuzz.native.parsers/failure-0123456789abcdef.json"');
    assert.ok(!command.includes("/Volumes/BigWalletBuild/Exchange"));
    for (const [run, phase, name] of [
        ["../other", "parsers", artifact], ["$(command)", "parsers", artifact], ["run-fixture", "unknown", artifact],
        ["run-fixture", "parsers", "../failure.json"], ["run-fixture", "parsers", "$(command).json"],
    ]) { assert.throws(() => hostReplayCommand(run, phase, name)); }
});

test("CLI replay is explicit and ordinary profiles cannot silently narrow execution", () => {
    assert.equal(parseOptions(["--phase", "replay", "--report", "/report", "--failure-dir", "/failure", "--replay", "/input"]).phase, "replay");
    assert.throws(() => parseOptions(["--phase", "parsers", "--report", "/report", "--failure-dir", "/failure", "--replay", "/input"]));
    assert.throws(() => parseOptions(["--phase", "parsers", "--report", "/report", "--failure-dir", "/failure", "--iterations", "1"]));
    assert.deepEqual([...shortvec(127)], [127]);
    assert.deepEqual([...shortvec(128)], [128, 1]);
    assert.throws(() => shortvec(65_536));
    assert.equal(random(1).next(), random(1).next());
});
