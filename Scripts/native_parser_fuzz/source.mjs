import {realpath} from "node:fs/promises";
import {isAbsolute, join} from "node:path";
import {isDeepStrictEqual} from "node:util";
import {ROOT, digest, sha256} from "./contract.mjs";
import {readStableFile} from "./evidence.mjs";

export const EXCHANGE = "/Volumes/BigWalletBuild/Exchange";

export function isParserSource(path) {
    if (typeof path !== "string" || path.split("/").some(part => part.startsWith("."))) { return false; }
    return ["Packages/WalletRuntime/Package.swift", "Packages/WalletParserFuzzHarness/Package.swift", "Scripts/validate_parser_fuzz_target.mjs", "Scripts/harness_package.mjs", "Scripts/runtime_policy.mjs"].includes(path) ||
        ["Packages/WalletRuntime/Sources/", "Packages/WalletParserFuzzHarness/Sources/", "Scripts/native_parser_fuzz/"].some(prefix => path.startsWith(prefix));
}

export function validateParserSourceInventory(manifestBytes, sourceInventory, expectedSHA256) {
    if (!digest(expectedSHA256) || sha256(manifestBytes) !== expectedSHA256) { throw new Error("Snapshot manifest hash does not match the submitted VM source"); }
    const manifest = JSON.parse(manifestBytes);
    if (manifest?.version !== 1 || !Array.isArray(manifest.files) || !manifest.files.length || manifest.files.length > 100_000) { throw new Error("Invalid snapshot manifest"); }
    const files = new Map();
    for (const file of manifest.files) {
        if (!file || typeof file.path !== "string" || !file.path || file.path.length > 4096 || isAbsolute(file.path) ||
            file.path.includes("\\") || file.path.includes("\0") || file.path.split("/").some(part => !part || part === "." || part === "..") ||
            files.has(file.path) || !["file", "symlink"].includes(file.type) || !digest(file.sha256) ||
            !Number.isInteger(file.mode) || file.mode < 0 || file.mode > 0o777) { throw new Error("Invalid or duplicate snapshot source entry"); }
        files.set(file.path, file);
    }
    const expected = manifest.files.filter(file => isParserSource(file.path)).map(file => {
        if (file.type !== "file") { throw new Error("Parser source may not be a symlink"); }
        return {path: file.path, sha256: file.sha256};
    }).sort((a, b) => a.path.localeCompare(b.path));
    if (!expected.length || !isDeepStrictEqual(sourceInventory, expected)) { throw new Error("Parser source inventory differs from the exact staged source entries"); }
    return manifest;
}

export async function captureParserSource(sourceInventory, expectedIdentity, {workspace = ROOT, environment = process.env} = {}) {
    if (environment.BW_TEST_VM_EXCHANGE !== EXCHANGE || await realpath(EXCHANGE) !== EXCHANGE) { throw new Error("Parser source capture requires the provisioned VM exchange"); }
    const [jobBytes, markerBytes, manifestBytes] = await Promise.all([
        readStableFile(join(EXCHANGE, "job.json"), 65_536),
        readStableFile(join(workspace, ".big-wallet-vm-workspace.json"), 65_536),
        readStableFile(join(EXCHANGE, "snapshot-manifest.json"), 16 * 1_024 * 1_024),
    ]);
    const job = JSON.parse(jobBytes), marker = JSON.parse(markerBytes);
    if (job.kind !== "run" || job.runId !== expectedIdentity.runId || typeof job.vmId !== "string" ||
        job.source?.sha256 !== expectedIdentity.sourceSHA256 || marker.version !== 1 || marker.runId !== job.runId ||
        marker.vmId !== job.vmId || !isDeepStrictEqual(marker.source, job.source)) { throw new Error("Parser source does not match the active guest workspace and job"); }
    const manifest = validateParserSourceInventory(manifestBytes, sourceInventory, expectedIdentity.sourceSHA256);
    if (job.source.fileCount !== manifest.files.length) { throw new Error("Submitted source file count does not match the manifest"); }
    return {manifestBytes, markerBytes, identity: {version: 1, kind: "vm-snapshot", runId: job.runId, vmId: job.vmId, source: job.source}};
}
