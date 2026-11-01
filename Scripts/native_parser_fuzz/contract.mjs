import {createHash} from "node:crypto";
import {readFileSync} from "node:fs";
import {dirname, resolve} from "node:path";
import {fileURLToPath} from "node:url";

export const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
export const HARNESS = resolve(ROOT, "Packages/WalletParserFuzzHarness");
export const FIXTURES_PATH = resolve(HARNESS, "Sources/WalletParserFuzzWorker/Resources/fixtures.json");
export const PHASES = ["build", "canaries", "parsers", "decrypt", "replay"];
export const PARSERS = ["keystore", "eip712", "solana"];
export const INPUT_LIMITS = {keystore: 1_048_577, eip712: 262_145, solana: 1_233};
export const DECRYPT_MUTATIONS = ["original", "wrongPassword", "emptyPassword", "mac", "ciphertext", "shortIV", "emptyMAC", "uppercaseCrypto"];
export const CANARIES = ["protocol", "asan", "crash", "hang", "rss", "malformed", "invariant"];
export const PROFILES = {
    all: {seeds: [0xc0ffee], iterations: 2_000, decryptRounds: 1, executionSeconds: 600},
    extended: {seeds: [0xc0ffee, 42, 20261013, 3735928559], iterations: 20_000, decryptRounds: 4, executionSeconds: 3_600},
};
export const LIMITS = {
    parserMilliseconds: 5_000, decryptMilliseconds: 30_000, rssBytes: 1_073_741_824,
    responseBytes: 2 * 1_024 * 1_024, logBytes: 16 * 1_024 * 1_024,
    artifactBytes: 4 * 1_024 * 1_024, reportBytes: 4 * 1_024 * 1_024,
    shrinkAttempts: 200, shrinkMilliseconds: 30_000,
    compressedLedgerBytes: 128 * 1_024 * 1_024, expandedLedgerBytes: 512 * 1_024 * 1_024,
};

export const sha256 = value => createHash("sha256").update(value).digest("hex");
export const digest = value => typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
export const finiteCount = value => Number.isSafeInteger(value) && value >= 0;
export const fixtureData = () => JSON.parse(readFileSync(FIXTURES_PATH, "utf8"));
export const caseDigest = candidate => sha256(JSON.stringify(candidate));
export const typedDataEntryPoint = candidate => candidate.entryPoint === "checked" ? "EIP712.checkedDigest" : "PreparedEthereumTypedData";

export function validateCase(candidate) {
    if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) { throw new Error("Case must be an object"); }
    const keys = ["name", "mode", "inputBase64", "secondaryBase64", "relation", "expected", "oracle", "fixtureID", "mutation", "mutationIndex", "entryPoint"];
    if (Object.keys(candidate).some(key => !keys.includes(key)) || typeof candidate.name !== "string" ||
        !candidate.name.length || candidate.name.length > 256 || ![...PARSERS, "decrypt"].includes(candidate.mode)) {
        throw new Error("Invalid parser case identity");
    }
    if (candidate.mode === "decrypt") {
        if (!fixtureData().keystores.some(fixture => fixture.id === candidate.fixtureID) ||
            !DECRYPT_MUTATIONS.includes(candidate.mutation) || !finiteCount(candidate.mutationIndex) || candidate.mutationIndex >= 32 ||
            ["inputBase64", "secondaryBase64", "relation", "oracle", "entryPoint"].some(key => Object.hasOwn(candidate, key))) {
            throw new Error("Decryption accepts only allowlisted fixtures and bounded mutations");
        }
    } else {
        for (const key of ["inputBase64", ...(candidate.secondaryBase64 === undefined ? [] : ["secondaryBase64"])]) {
            const encoded = candidate[key];
            if (typeof encoded !== "string" || encoded.length > Math.ceil(INPUT_LIMITS[candidate.mode] / 3) * 4 ||
                Buffer.from(encoded, "base64").toString("base64") !== encoded || Buffer.from(encoded, "base64").length > INPUT_LIMITS[candidate.mode]) {
                throw new Error("Invalid or oversized parser input");
            }
        }
        if (["fixtureID", "mutation", "mutationIndex"].some(key => Object.hasOwn(candidate, key))) { throw new Error("Parser case contains decryption options"); }
        if (candidate.relation !== undefined && (candidate.mode !== "eip712" || !["equalDigest", "differentDigest"].includes(candidate.relation) || candidate.secondaryBase64 === undefined) ||
            candidate.secondaryBase64 !== undefined && candidate.relation === undefined) { throw new Error("Invalid typed-data relation"); }
        if (candidate.oracle !== undefined && (candidate.mode !== "solana" || !["canonical", "malformed"].includes(candidate.oracle))) {
            throw new Error("Invalid oracle selection");
        }
        if (candidate.entryPoint !== undefined && (candidate.mode !== "eip712" || candidate.entryPoint !== "checked")) { throw new Error("Invalid parser entry point"); }
    }
    if (candidate.expected !== undefined) {
        const expected = candidate.expected;
        if (!expected || typeof expected !== "object" || Array.isArray(expected) ||
            Object.keys(expected).some(key => !["accepted", "strictAccepted", "digest", "rejection"].includes(key)) ||
            ["accepted", "strictAccepted"].some(key => expected[key] !== undefined && typeof expected[key] !== "boolean") ||
            expected.digest !== undefined && !digest(expected.digest) ||
            expected.rejection !== undefined && typeof expected.rejection !== "string") { throw new Error("Invalid expected result"); }
    }
    return candidate;
}

export function nativeRequest(candidate, id) {
    validateCase(candidate);
    const {name, expected, oracle, ...request} = candidate;
    return {id, ...request};
}

export function parseOptions(arguments_) {
    const options = {profile: "all"};
    const names = {"--phase": "phase", "--profile": "profile", "--report": "report", "--failure-dir": "failureDirectory", "--replay": "replay"};
    for (let index = 0; index < arguments_.length; index += 1) {
        const flag = arguments_[index];
        if (flag === "--help") { options.help = true; continue; }
        const name = names[flag], value = arguments_[++index];
        if (!name || !value || value.startsWith("--") || Object.hasOwn(options, name) && name !== "profile") { throw new Error(`Invalid argument ${flag}`); }
        options[name] = value;
    }
    if (options.help) { return options; }
    if (!PHASES.includes(options.phase) || !Object.hasOwn(PROFILES, options.profile) || !options.report || !options.failureDirectory ||
        (options.phase === "replay") !== Boolean(options.replay)) { throw new Error("Require phase, profile, report, failure-dir, and replay only for replay phase"); }
    for (const key of ["report", "failureDirectory", "replay"]) { if (options[key]) { options[key] = resolve(options[key]); } }
    return options;
}
