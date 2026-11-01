import {createRequire} from "node:module";
import {isDeepStrictEqual} from "node:util";
import {resolve} from "node:path";
import {ROOT, sha256, typedDataEntryPoint} from "./contract.mjs";

let solana;
export function solanaOracle(candidate) {
    if (!solana) {
        const require = createRequire(resolve(ROOT, "Safari Shared/Inpage Provider/package.json"));
        if (require("@solana/web3.js/package.json").version !== "1.98.4") { throw new Error("Solana oracle version must match the existing pin 1.98.4"); }
        solana = require("@solana/web3.js");
    }
    try {
        const input = Buffer.from(candidate.inputBase64, "base64");
        const message = solana.VersionedMessage.deserialize(input);
        return {accepted: true, canonical: Buffer.from(message.serialize()).equals(input), summary: {
            version: message.version === "legacy" ? "legacy" : "v0",
            requiredSignatures: message.header.numRequiredSignatures,
            readOnlySigned: message.header.numReadonlySignedAccounts,
            readOnlyUnsigned: message.header.numReadonlyUnsignedAccounts,
            accountKeys: message.staticAccountKeys.map(key => key.toBuffer().toString("hex")),
            blockhash: new solana.PublicKey(message.recentBlockhash).toBuffer().toString("hex"),
            instructions: message.compiledInstructions.map(instruction => ({programIdIndex: instruction.programIdIndex,
                accountIndices: instruction.accountKeyIndexes, dataHex: Buffer.from(instruction.data).toString("hex")})),
            lookups: message.addressTableLookups.map(lookup => ({accountKey: lookup.accountKey.toBuffer().toString("hex"),
                writableIndexes: lookup.writableIndexes, readOnlyIndexes: lookup.readonlyIndexes})),
        }};
    } catch (error) { return {accepted: false, reason: String(error.message).slice(0, 256)}; }
}

export function compareResult(candidate, result, oracle) {
    if (result.status !== "ok") { return {kind: "invariant", code: result.invariant ?? "missingInvariant", message: "Native worker invariant failed"}; }
    if (candidate.mode === "keystore" && typeof result.strictAccepted !== "boolean") {
        return {kind: "invariant", code: "keystoreStrictResult", message: "Worker omitted the independent strict stored-reader result"};
    }
    if (candidate.mode === "eip712" && result.entryPoint !== typedDataEntryPoint(candidate)) {
        return {kind: "invariant", code: "typedDataEntryPoint", message: "Worker did not identify the selected typed-data entry point"};
    }
    for (const [key, expected] of Object.entries(candidate.expected ?? {})) {
        if (result[key] !== expected) { return {kind: "expectation", code: key, message: `${key} differed from independently labeled expectation`}; }
    }
    if (oracle) {
        if (candidate.oracle === "canonical" && (!oracle.accepted || !oracle.canonical || !result.accepted)) {
            return {kind: "oracle", code: "canonicalAcceptance", message: "Canonical generated Solana message was not accepted and reproduced by both parsers"};
        }
        if (result.accepted && !oracle.accepted) { return {kind: "oracle", code: "nativeOnlyAcceptance", message: "Native parser accepted a message the SDK could not decode"}; }
        if (result.accepted && oracle.accepted && !isDeepStrictEqual(result.summary, oracle.summary)) {
            return {kind: "oracle", code: "normalizedMessage", message: "Native and SDK parsed messages differ"};
        }
    }
    return null;
}

export function oracleFingerprint(oracle) {
    if (!oracle) { return null; }
    return {accepted: oracle.accepted, ...(oracle.accepted ? {canonical: oracle.canonical, summarySHA256: sha256(JSON.stringify(oracle.summary))} : {})};
}
