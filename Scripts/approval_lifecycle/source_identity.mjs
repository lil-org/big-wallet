import {createHash} from "node:crypto";
import {constants} from "node:fs";
import {lstat, open, realpath} from "node:fs/promises";
import {basename, isAbsolute, join} from "node:path";
import {fileURLToPath} from "node:url";
import {isDeepStrictEqual} from "node:util";
import {EXCHANGE_PATH, validateJobEnvelope, validateSnapshotManifest} from "../vm/guest_bootstrap.mjs";

const repository = fileURLToPath(new URL("../../", import.meta.url));
const sha256 = value => createHash("sha256").update(value).digest("hex");
const objectWithKeys = (value, keys) => value !== null && typeof value === "object" && !Array.isArray(value) &&
    Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
const digest = value => typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
const positiveInteger = value => Number.isSafeInteger(value) && value > 0;

export function validateSourceIdentity(value) {
    if (!objectWithKeys(value, ["version", "source", "worker"]) || value.version !== 1 ||
        !objectWithKeys(value.source, ["kind", "sha256", "commit", "fileCount"]) || value.source.kind !== "vm-snapshot" ||
        !digest(value.source.sha256) || typeof value.source.commit !== "string" ||
        !/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(value.source.commit) || !positiveInteger(value.source.fileCount) ||
        !objectWithKeys(value.worker, ["sha256", "bytes"]) || !digest(value.worker.sha256) || !positiveInteger(value.worker.bytes)) {
        throw new Error("Invalid approval source identity");
    }
    return value;
}

async function stableFile(path, maximum, retainContents = false) {
    const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
        const before = await file.stat({bigint: true});
        if (!before.isFile() || before.size > BigInt(maximum)) { throw new Error(`Invalid identity file: ${basename(path)}`); }
        const hash = createHash("sha256");
        const chunks = [];
        let bytes = 0;
        for await (const chunk of file.createReadStream({autoClose: false})) {
            bytes += chunk.length;
            if (bytes > maximum || BigInt(bytes) > before.size) { throw new Error(`Identity file changed: ${basename(path)}`); }
            hash.update(chunk);
            if (retainContents) { chunks.push(chunk); }
        }
        const [after, named] = await Promise.all([file.stat({bigint: true}), lstat(path, {bigint: true})]);
        const fields = ["dev", "ino", "size", "mtimeNs", "ctimeNs"];
        if (BigInt(bytes) !== before.size || !named.isFile() ||
            fields.some(field => before[field] !== after[field] || before[field] !== named[field])) {
            throw new Error(`Identity file changed: ${basename(path)}`);
        }
        return {sha256: hash.digest("hex"), bytes, ...(retainContents ? {contents: Buffer.concat(chunks)} : {})};
    } finally { await file.close(); }
}

export async function captureSourceIdentity(worker, {environment = process.env, workspace = repository, exchange = EXCHANGE_PATH} = {}) {
    const runId = environment.BW_TEST_VM_RUN_ID;
    if (typeof runId !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(runId) || runId.includes("..") ||
        typeof exchange !== "string" || !isAbsolute(exchange) || environment.BW_TEST_VM_EXCHANGE !== exchange) {
        throw new Error("Approval source identity requires the current VM job");
    }
    const exchangeMetadata = await lstat(exchange);
    if (!exchangeMetadata.isDirectory() || exchangeMetadata.isSymbolicLink() || await realpath(exchange) !== exchange) {
        throw new Error("Approval source exchange must be a real directory");
    }
    const [jobFile, manifestFile, markerFile] = await Promise.all([
        stableFile(join(exchange, "job.json"), 65536, true),
        stableFile(join(exchange, "snapshot-manifest.json"), 16 * 1024 * 1024, true),
        stableFile(join(workspace, ".big-wallet-vm-workspace.json"), 65536, true),
    ]);
    const job = validateJobEnvelope(JSON.parse(jobFile.contents));
    const marker = JSON.parse(markerFile.contents);
    if (job.kind !== "run" || job.runId !== runId || marker.version !== 1 || marker.runId !== job.runId ||
        marker.vmId !== job.vmId || !isDeepStrictEqual(marker.source, job.source)) {
        throw new Error("Approval source identity does not match the active workspace");
    }
    if (manifestFile.sha256 !== job.source.sha256) { throw new Error("Approval source manifest does not match the VM job"); }
    const manifest = validateSnapshotManifest(JSON.parse(manifestFile.contents));
    if (job.source.fileCount !== manifest.files.length) { throw new Error("Approval source inventory does not match the VM job"); }
    const binary = await stableFile(await realpath(worker), 1024 * 1024 * 1024);
    return validateSourceIdentity({version: 1,
        source: {kind: "vm-snapshot", sha256: sha256(manifestFile.contents), commit: job.source.commit, fileCount: manifest.files.length},
        worker: binary});
}
