import {createHash} from "node:crypto";
import {readFile} from "node:fs/promises";
import {isAbsolute} from "node:path";

export const VERSION = 1;
export const LIMITS = Object.freeze({coreSeconds: 3600, extendedSeconds: 7200, buildSeconds: 900,
    testSeconds: 180, querySeconds: 60, maximumArtifactBytes: 64 * 1024 * 1024});
export const FAMILIES = Object.freeze(["runtime", "macos-app", "ios-app", "javascript"]);
export const sha256 = value => createHash("sha256").update(value).digest("hex");
export const isDigest = value => typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
export const safeRelativePath = value => typeof value === "string" && value.length > 0 && value.length <= 4096 &&
    !isAbsolute(value) && !/[\\\u0000-\u001f]/.test(value) && value.split("/").every(part => part && part !== "." && part !== "..");

export function validateManifest(value) {
    if (!value || value.version !== VERSION || !Array.isArray(value.mutants) || value.mutants.length !== 19) {
        throw new Error("Mutation manifest must contain the nineteen curated mutants");
    }
    const ids = new Set();
    for (const mutant of value.mutants) {
        if (!mutant || !/^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)+$/.test(mutant.id) || ids.has(mutant.id) ||
            !["core", "extended"].includes(mutant.tier) || !FAMILIES.includes(mutant.family) ||
            !safeRelativePath(mutant.source) || !/^(?:Packages\/WalletRuntime\/Sources\/|Shared\/Services\/|App iOS\/Screens\/|Safari Shared\/Resources\/)/.test(mutant.source) ||
            !/\.(?:swift|js)$/.test(mutant.source) || /(?:generated|inpage\.js)/.test(mutant.source) ||
            !Array.isArray(mutant.edits) || mutant.edits.length < 1 || mutant.edits.length > 4 ||
            mutant.edits.some(edit => typeof edit?.find !== "string" || !edit.find || edit.find.length > 16384 ||
                typeof edit.replace !== "string" || edit.replace.length > 16384 || edit.find === edit.replace) ||
            !safeRelativePath(mutant.witness?.file) || !/^(?:Tests\/|Packages\/WalletRuntime\/Tests\/|Safari Shared\/Tests\/)/.test(mutant.witness.file) ||
            mutant.witness.marker !== `SECURITY-MUTATION[${mutant.id}]` || typeof mutant.witness.selector !== "string" || !mutant.witness.selector) {
            throw new Error(`Invalid curated mutation: ${mutant?.id}`);
        }
        if (mutant.family !== "javascript" && !/^(?:Wallet(?:Authority|Networking|Flows)Tests|Tests macOS|Tests iOS)\/[A-Za-z_][A-Za-z0-9_]*\/test[A-Za-z0-9_]+$/.test(mutant.witness.selector)) {
            throw new Error(`Invalid mutation XCTest selector: ${mutant.id}`);
        }
        if (mutant.family === "javascript" && !mutant.witness.file.endsWith(".test.mjs")) { throw new Error("Invalid JavaScript witness"); }
        ids.add(mutant.id);
    }
    if (value.mutants.filter(mutant => mutant.tier === "core").length !== 6) { throw new Error("Mutation manifest requires six core mutants"); }
    return value;
}

export async function loadManifest(path = new URL("./manifest.json", import.meta.url)) {
    const bytes = await readFile(path);
    return {manifest: validateManifest(JSON.parse(bytes)), sha256: sha256(bytes), bytes};
}

export function selectedMutants(manifest, tier) {
    if (!["core", "extended"].includes(tier)) { throw new Error("Invalid mutation tier"); }
    return manifest.mutants.filter(mutant => tier === "extended" || mutant.tier === "core");
}

export function applyMutation(source, mutant) {
    if (typeof source !== "string") { throw new Error("Mutation source must be text"); }
    let result = source;
    const edits = [];
    for (const edit of mutant.edits) {
        const offset = result.indexOf(edit.find);
        if (offset < 0 || result.indexOf(edit.find, offset + 1) >= 0) { throw new Error(`Mutation anchor is missing or ambiguous: ${mutant.id}`); }
        edits.push({offset, before: edit.find, after: edit.replace});
        result = result.slice(0, offset) + edit.replace + result.slice(offset + edit.find.length);
    }
    return {source: result, patch: {version: VERSION, id: mutant.id, file: mutant.source,
        beforeSHA256: sha256(source), afterSHA256: sha256(result), edits}};
}

export function groupedWitnesses(mutants) {
    return FAMILIES.map(family => ({family,
        witnesses: [...new Map(mutants.filter(mutant => mutant.family === family)
            .map(mutant => [mutant.witness.selector, mutant.witness])).values()]}))
        .filter(group => group.witnesses.length);
}
