#!/usr/bin/env node

import {execFile, spawn} from "node:child_process";
import {createHash, randomUUID} from "node:crypto";
import {constants, createReadStream} from "node:fs";
import {chmod, copyFile, lstat, mkdir, open, readFile, readlink, realpath, rename, rm, stat, symlink} from "node:fs/promises";
import {userInfo} from "node:os";
import {basename, dirname, isAbsolute, join, relative, resolve, sep} from "node:path";
import {pathToFileURL} from "node:url";

export const IDENTITY_PATH = "/Library/Application Support/BigWalletTestVM/identity.json";
export const PROVISIONING_PATH = "/Library/Application Support/BigWalletTestVM/provisioning.json";
export const EXCHANGE_PATH = "/Volumes/BigWalletBuild/Exchange";
export const INSTALLED_RUNNER_DIRECTORY = "/usr/local/libexec/big-wallet-vm";
export const BUILD_VOLUME = "/Volumes/BigWalletBuild";
export const BOOTSTRAP_TOOL_NAMES = ["VMGuestAgent", "guest_runner", "guest_bootstrap.mjs"];
const MAX_JSON_BYTES = 16 * 1024 * 1024;
const sha256 = value => createHash("sha256").update(value).digest("hex");
const inside = (parent, child) => child === parent || child.startsWith(`${parent}${sep}`);

function probeProcess(command, args, {timeoutSeconds = 60} = {}) {
    return new Promise(resolveProbe => {
        execFile(command, args, {encoding: "utf8", timeout: timeoutSeconds * 1000, killSignal: "SIGKILL", maxBuffer: MAX_JSON_BYTES,
            env: {PATH: "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"}}, (error, stdout, stderr) => {
            resolveProbe({code: error ? error.code : 0, output: stdout + stderr});
        });
    });
}

export function validateJobEnvelope(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) { throw new Error("Job must be an object"); }
    const allowed = new Set(["version", "runId", "vmId", "kind", "profile", "stages", "onlyTesting", "source", "configuration", "approvalArgs", "bootstrapTools"]);
    if (Object.keys(value).some(key => !allowed.has(key)) || value.version !== 1) { throw new Error("Unsupported job schema"); }
    if (typeof value.runId !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(value.runId) || value.runId.includes("..") ||
        typeof value.vmId !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$/.test(value.vmId) || !["run", "doctor"].includes(value.kind)) {
        throw new Error("Invalid guest job identity or kind");
    }
    if (!value.source || typeof value.source !== "object" || Array.isArray(value.source) ||
        Object.keys(value.source).some(key => !["sha256", "commit", "fileCount", "bytes"].includes(key)) ||
        !/^[a-f0-9]{64}$/.test(value.source.sha256) || typeof value.source.commit !== "string" || !/^[a-f0-9]{40,64}$/.test(value.source.commit)) {
        throw new Error("Invalid source identity");
    }
    for (const key of ["fileCount", "bytes"]) {
        if (value.source[key] !== undefined && (!Number.isSafeInteger(value.source[key]) || value.source[key] < 0)) { throw new Error("Invalid source inventory"); }
    }
    if (!value.bootstrapTools || typeof value.bootstrapTools !== "object" || Array.isArray(value.bootstrapTools) ||
        Object.keys(value.bootstrapTools).length !== BOOTSTRAP_TOOL_NAMES.length || BOOTSTRAP_TOOL_NAMES.some(name => !/^[a-f0-9]{64}$/.test(value.bootstrapTools[name]))) {
        throw new Error("Invalid bootstrap tool identity");
    }
    return value;
}

export async function atomicJSON(path, value) {
    await mkdir(dirname(path), {recursive: true});
    const temporary = `${path}.${randomUUID()}.tmp`;
    const file = await open(temporary, "wx", 0o600);
    try { await file.writeFile(`${JSON.stringify(value, null, 2)}\n`); await file.sync(); }
    finally { await file.close(); }
    await rename(temporary, path);
}

export async function regularFile(path, maximum = MAX_JSON_BYTES) {
    const info = await lstat(path);
    if (!info.isFile() || info.isSymbolicLink() || info.size > maximum) { throw new Error(`Invalid file: ${basename(path)}`); }
    return readFile(path);
}

export function validateGuestEvidence(evidence, vmId) {
    const {identity, identityOwner, identityMode, platform, uid, consoleUid, model, hypervisor, aqua, username} = evidence;
    if (platform !== "darwin" || identityOwner !== 0 || (identityMode & 0o022) !== 0 ||
        !identity || identity.version !== 1 || identity.vmId !== vmId || identity.consoleUser !== username ||
        !Number.isInteger(uid) || uid === 0 || uid !== consoleUid || !aqua ||
        !/^VirtualMac[0-9,]*$/.test(model)) {
        throw new Error("Guest identity, virtual hardware, or active Aqua session could not be verified; execution refused");
    }
    return {vmId, consoleUser: username, uid, model, hypervisor: hypervisor === "1", aqua: true};
}

export async function verifyGuest(vmId, {execute = probeProcess, identityPath = IDENTITY_PATH} = {}) {
    const parent = await lstat(dirname(identityPath));
    if (!parent.isDirectory() || parent.isSymbolicLink() || parent.uid !== 0 || (parent.mode & 0o022) !== 0) {
        throw new Error("Guest sentinel directory is not protected");
    }
    const metadata = await lstat(identityPath);
    if (!metadata.isFile() || metadata.isSymbolicLink()) { throw new Error("Guest sentinel is not a regular file"); }
    const identity = JSON.parse(await regularFile(identityPath, 4096));
    const uid = process.getuid?.();
    const values = await Promise.all([
        execute("/usr/sbin/sysctl", ["-n", "hw.model"]),
        execute("/usr/sbin/sysctl", ["-n", "kern.hv_vmm_present"]),
        execute("/usr/bin/stat", ["-f", "%u", "/dev/console"]),
        execute("/bin/launchctl", ["print", `gui/${uid}`]),
        execute("/usr/bin/id", ["-un"]),
    ]);
    return validateGuestEvidence({
        identity, identityOwner: metadata.uid, identityMode: metadata.mode,
        platform: process.platform, uid, consoleUid: Number(values[2].output.trim()),
        model: values[0].output.trim(), hypervisor: values[1].output.trim(), aqua: values[3].code === 0,
        username: values[4].output.trim(),
    }, vmId);
}

function sourcePath(value) {
    return typeof value === "string" && value.length > 0 && value.length <= 4096 && !isAbsolute(value) &&
        !value.includes("\0") && !value.includes("\\") && value.split("/").every(part => part && part !== "." && part !== "..");
}

export function validateSnapshotManifest(manifest) {
    if (!manifest || manifest.version !== 1 || !Array.isArray(manifest.files) || manifest.files.length > 100000) { throw new Error("Invalid snapshot manifest"); }
    const paths = new Set();
    const symlinks = new Map();
    for (const file of manifest.files) {
        if (!file || !sourcePath(file.path) || paths.has(file.path) || file.path === ".big-wallet-vm-workspace.json" ||
            !/^[a-f0-9]{64}$/.test(file.sha256) || !["file", "symlink"].includes(file.type) ||
            !Number.isInteger(file.mode) || file.mode < 0 || file.mode > 0o777) { throw new Error("Invalid snapshot entry"); }
        if (file.type === "symlink") {
            if (typeof file.target !== "string" || !file.target || isAbsolute(file.target) || file.target.includes("\0") ||
                !inside("/snapshot", resolve("/snapshot", dirname(file.path), file.target)) || sha256(file.target) !== file.sha256) {
                throw new Error(`Unsafe snapshot symlink: ${file.path}`);
            }
            symlinks.set(file.path, file.target);
        }
        paths.add(file.path);
    }
    for (const file of manifest.files) {
        let parent = dirname(file.path);
        while (parent !== ".") {
            if (paths.has(parent)) { throw new Error(`Snapshot entry has a nondirectory parent: ${file.path}`); }
            parent = dirname(parent);
        }
    }
    const walk = (path, visited = new Set()) => {
        let current = path;
        const components = current.split("/");
        for (let index = 1; index <= components.length; index += 1) {
            const ancestor = components.slice(0, index).join("/");
            if (!symlinks.has(ancestor)) { continue; }
            if (visited.has(ancestor)) { throw new Error("Snapshot symlink cycle"); }
            visited.add(ancestor);
            const target = resolve("/snapshot", dirname(ancestor), symlinks.get(ancestor), ...components.slice(index));
            if (!inside("/snapshot", target)) { throw new Error("Snapshot symlink escapes source"); }
            current = relative("/snapshot", target);
            return walk(current, visited);
        }
        return current;
    };
    for (const path of symlinks.keys()) { walk(path); }
    return manifest;
}

export async function hashFile(path) {
    const hash = createHash("sha256");
    for await (const chunk of createReadStream(path)) { hash.update(chunk); }
    return hash.digest("hex");
}

export async function materializeSource(exchange, job, workspace, {stopRequested = async () => false} = {}) {
    const manifestData = await regularFile(join(exchange, "snapshot-manifest.json"));
    if (sha256(manifestData) !== job.source.sha256) { throw new Error("Source manifest hash does not match submitted job"); }
    const manifest = validateSnapshotManifest(JSON.parse(manifestData));
    if (job.source.fileCount !== undefined && job.source.fileCount !== manifest.files.length) { throw new Error("Source file inventory does not match job"); }
    const source = join(exchange, "source");
    const sourceMetadata = await lstat(source);
    if (!sourceMetadata.isDirectory() || sourceMetadata.isSymbolicLink() || await realpath(source) !== source) { throw new Error("Source directory may not traverse symlinks"); }
    const parent = dirname(workspace);
    await mkdir(parent, {recursive: true});
    if (await realpath(parent) !== parent) { throw new Error("Workspace parent may not traverse symlinks"); }
    try {
        const existing = await lstat(workspace);
        if (!existing.isDirectory() || existing.isSymbolicLink()) { throw new Error("Guest workspace is not a directory"); }
        const marker = JSON.parse(await regularFile(join(workspace, ".big-wallet-vm-workspace.json"), 4096));
        if (marker.version !== 1 || marker.vmId !== job.vmId) { throw new Error("Refusing to replace an unowned guest checkout"); }
    } catch (error) {
        if (error.code !== "ENOENT") { throw error; }
        if (await stat(workspace).then(() => true, () => false)) { throw new Error("Refusing to replace an unmarked guest checkout"); }
    }
    const staging = join(parent, `.big-wallet-vm-source-${job.runId}`);
    await mkdir(staging, {mode: 0o700});
    try {
        let bytes = 0;
        for (const file of manifest.files) {
            if (await stopRequested()) { throw new Error("Source transfer cancelled"); }
            const input = join(source, file.path);
            const output = join(staging, file.path);
            const metadata = await lstat(input);
            await mkdir(dirname(output), {recursive: true});
            if (file.type === "symlink") {
                if (!metadata.isSymbolicLink() || await readlink(input) !== file.target) { throw new Error(`Snapshot symlink mismatch: ${file.path}`); }
                await symlink(file.target, output);
            } else {
                if (!metadata.isFile() || metadata.isSymbolicLink() || !inside(source, await realpath(input)) || metadata.size > 1024 * 1024 * 1024) {
                    throw new Error(`Unsafe snapshot file: ${file.path}`);
                }
                await copyFile(input, output);
                bytes += metadata.size;
                if (bytes > 1024 * 1024 * 1024) { throw new Error("Source snapshot exceeds 1 GiB"); }
                if (await hashFile(output) !== file.sha256) { throw new Error(`Source hash mismatch: ${file.path}`); }
                await chmod(output, file.mode);
            }
        }
        if (job.source.bytes !== undefined && job.source.bytes !== bytes) { throw new Error("Source byte inventory does not match job"); }
        await atomicJSON(join(staging, ".big-wallet-vm-workspace.json"), {version: 1, vmId: job.vmId, source: job.source, runId: job.runId});
        const previous = join(parent, `.big-wallet-vm-previous-${job.runId}`);
        let movedPrevious = false;
        try { await rename(workspace, previous); movedPrevious = true; } catch (error) { if (error.code !== "ENOENT") { throw error; } }
        try { await rename(staging, workspace); }
        catch (error) { if (movedPrevious) { await rename(previous, workspace); } throw error; }
        if (movedPrevious) { await rm(previous, {recursive: true}); }
        return {files: manifest.files.length, ...job.source};
    } catch (error) { await rm(staging, {recursive: true, force: true}); throw error; }
}

export async function readGuestProvision(identity, path = PROVISIONING_PATH, {inspect = lstat, read = regularFile} = {}) {
    const directory = await inspect(dirname(path));
    if (!directory.isDirectory() || directory.isSymbolicLink() || directory.uid !== 0 || (directory.mode & 0o077) !== 0) {
        throw new Error("Guest provisioning directory is not private");
    }
    const metadata = await inspect(path);
    if (metadata.uid !== 0 || (metadata.mode & 0o007) !== 0 || (metadata.mode & 0o022) !== 0) { throw new Error("Guest provisioning permissions are not private"); }
    let provision;
    try { provision = JSON.parse(await read(path, 16384)); }
    catch { throw new Error("Guest provisioning JSON is unavailable or invalid"); }
    if (provision.version !== 1 || provision.vmId !== identity.vmId || provision.consoleUser !== identity.consoleUser) { throw new Error("Guest provisioning identity does not match this VM"); }
    provisioningEvidence(provision);
    const expectedWorkspace = join(BUILD_VOLUME, "Workspaces", identity.consoleUser, "big-wallet");
    if (provision.workspacePath !== expectedWorkspace) { throw new Error("Guest workspace is not on the configured build volume"); }
    return provision;
}

export function provisioningEvidence(provision) {
    const appliedRequestID = provision.appliedProvisioningRequestID;
    if (appliedRequestID !== undefined && (typeof appliedRequestID !== "string" ||
        !/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(appliedRequestID))) {
        throw new Error("Guest provisioning receipt is invalid");
    }
    return {vmId: provision.vmId, consoleUser: provision.consoleUser, appliedRequestID: appliedRequestID ?? null};
}

async function readBuildVolumeIdentity() {
    const path = join(BUILD_VOLUME, ".big-wallet-vm.json");
    const metadata = await lstat(path);
    if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.uid !== 0 || (metadata.mode & 0o022) !== 0) {
        throw new Error("The guest build-volume identity is not protected");
    }
    return JSON.parse(await regularFile(path, 4096));
}

export async function verifyExchangeDirectory({inspect = lstat, canonicalPath = realpath,
    currentUID = () => process.getuid(), currentGID = () => process.getgid()} = {}) {
    const parent = await inspect(BUILD_VOLUME);
    if (!parent.isDirectory() || parent.isSymbolicLink() || parent.uid !== 0 || (parent.mode & 0o022) !== 0 ||
        await canonicalPath(BUILD_VOLUME) !== BUILD_VOLUME) {
        throw new Error("The local exchange parent must be a protected root-owned directory");
    }
    const directory = await inspect(EXCHANGE_PATH);
    if (!directory.isDirectory() || directory.isSymbolicLink() || directory.uid !== currentUID() || directory.gid !== currentGID() ||
        (directory.mode & 0o7777) !== 0o700 || await canonicalPath(EXCHANGE_PATH) !== EXCHANGE_PATH) {
        throw new Error("The local exchange must be a private directory owned by the selected guest account");
    }
    return EXCHANGE_PATH;
}

export async function verifyBuildVolume({execute = probeProcess, vmId, stopRequested = async () => false,
    readIdentity = readBuildVolumeIdentity, canonicalPath = realpath, now = Date.now,
    wait = milliseconds => new Promise(resolveWait => setTimeout(resolveWait, milliseconds)), timeoutMilliseconds = 30000} = {}) {
    const deadline = now() + timeoutMilliseconds;
    while (true) {
        if (await stopRequested()) { throw new Error("Run cancelled while waiting for the build volume"); }
        const result = await execute("/sbin/mount", [], {timeoutSeconds: 5, stopRequested});
        if (result.code === 0 && result.output.split("\n").some(line => {
            const mount = /^\/dev\/disk\d+s\d+ on (\S+) \(([^)]+)\)$/.exec(line);
            return mount?.[1] === BUILD_VOLUME && mount[2].split(", ")[0] === "apfs" && mount[2].split(", ").includes("local");
        })) {
            if (await canonicalPath(BUILD_VOLUME) !== BUILD_VOLUME) { throw new Error("The guest build volume is not a direct mount"); }
            try {
                const identity = await readIdentity();
                if (identity.version !== 1 || identity.vmId !== vmId || typeof identity.volumeUUID !== "string" ||
                    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(identity.volumeUUID)) {
                    throw new Error("The guest build volume belongs to another VM or has an invalid identity");
                }
                return identity;
            } catch (error) { if (error.code !== "ENOENT") { throw error; } }
        }
        if (now() >= deadline) { throw new Error("The managed guest APFS build volume did not become available"); }
        await wait(Math.min(1000, Math.max(0, deadline - now())));
    }
}

export async function bootstrapToolsEvidence(expected, {directory = INSTALLED_RUNNER_DIRECTORY, inspect = lstat, hash = hashFile} = {}) {
    const hashes = {};
    const missing = [];
    const mismatched = [];
    for (const name of BOOTSTRAP_TOOL_NAMES) {
        try {
            const path = join(directory, name);
            const metadata = await inspect(path);
            if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.uid !== 0 || (metadata.mode & 0o022) !== 0) { throw new Error("Unprotected installed tool"); }
            hashes[name] = await hash(path);
            if (hashes[name] !== expected?.[name]) { mismatched.push(name); }
        } catch { missing.push(name); }
    }
    return {available: missing.length === 0 && mismatched.length === 0, hashes, missing, mismatched};
}

async function publishLockOwner(file, runId) {
    await file.truncate(0);
    await file.writeFile(`${JSON.stringify({version: 1, runId, pid: process.pid})}\n`);
    await file.sync();
}

export async function acquireRunLock(filename, runId, {publishOwner = publishLockOwner} = {}) {
    if (!isAbsolute(filename) || resolve(filename) !== filename) { throw new Error("Guest lock path must be absolute and canonical"); }
    const parentPath = dirname(filename);
    await mkdir(parentPath, {recursive: true, mode: 0o700});
    const parent = await lstat(parentPath);
    if (!parent.isDirectory() || parent.isSymbolicLink() || parent.uid !== process.getuid() ||
        (parent.mode & 0o022) !== 0 || await realpath(parentPath) !== parentPath) { throw new Error("Guest lock directory is not protected"); }
    const validate = metadata => {
        if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.uid !== BigInt(process.getuid()) ||
            (metadata.mode & 0o077n) !== 0n || metadata.nlink !== 1n) { throw new Error("Guest lock must be a private owned regular file"); }
    };
    try { validate(await lstat(filename, {bigint: true})); }
    catch (error) { if (error.code !== "ENOENT") { throw error; } }
    const file = await open(filename, constants.O_RDWR | constants.O_CREAT | constants.O_NOFOLLOW | constants.O_NONBLOCK, 0o600);
    try {
        const identity = await file.stat({bigint: true});
        validate(identity);
        await new Promise((resolveLock, rejectLock) => {
            const child = spawn("/usr/bin/lockf", ["-s", "-t", "0", "3"], {
                env: {PATH: "/usr/bin:/bin"}, stdio: ["ignore", "ignore", "ignore", file.fd], timeout: 10000,
            });
            child.once("error", rejectLock);
            child.once("close", code => code === 0 ? resolveLock() : rejectLock(new Error(code === 75 ?
                "Another guest run is already active" : "The guest execution lock could not be acquired")));
        });
        const current = await lstat(filename, {bigint: true});
        validate(current);
        if (current.dev !== identity.dev || current.ino !== identity.ino) { throw new Error("Guest lock changed during acquisition"); }
        await publishOwner(file, runId);
    } catch (error) {
        await file.close();
        throw error;
    }
    let released = false;
    return async () => {
        if (!released) { released = true; await file.close(); }
    };
}

export async function verifySession(args, {environment = process.env, verify = verifyGuest} = {}) {
    const exchange = args.length === 1 ? EXCHANGE_PATH : args.length === 3 && args[1] === "--exchange" ? args[2] : null;
    if (args[0] !== "--verify-session" || exchange !== EXCHANGE_PATH || environment.BW_TEST_VM_EXCHANGE !== EXCHANGE_PATH ||
        typeof environment.BW_TEST_VM_RUN_ID !== "string") { throw new Error("A current guest run is required"); }
    await verifyExchangeDirectory();
    const job = validateJobEnvelope(JSON.parse(await regularFile(join(exchange, "job.json"), 65536)));
    if (job.kind !== "run" || job.runId !== environment.BW_TEST_VM_RUN_ID) { throw new Error("Guest run identity is stale"); }
    await verify(job.vmId);
    return {runId: job.runId, status: "passed"};
}

export async function main(args = process.argv.slice(2)) {
    if (args[0] === "--verify-session") { return verifySession(args); }
    if (args.length !== 2 || args[0] !== "--exchange" || args[1] !== EXCHANGE_PATH) { throw new Error("Guest execution requires the fixed local exchange"); }
    const exchange = await verifyExchangeDirectory();
    const job = validateJobEnvelope(JSON.parse(await regularFile(join(exchange, "job.json"), 65536)));
    const identity = await verifyGuest(job.vmId);
    const bootstrapEvidence = await bootstrapToolsEvidence(job.bootstrapTools);
    const artifacts = join(exchange, "artifacts");
    await mkdir(artifacts, {recursive: true, mode: 0o700});
    if (await realpath(artifacts) !== artifacts) { throw new Error("Artifact directory may not traverse symlinks"); }
    try {
        const previous = JSON.parse(await regularFile(join(artifacts, "result.json")));
        if (bootstrapEvidence.available && previous.runId === job.runId && ["passed", "failed", "cancelled"].includes(previous.status)) { return previous; }
    } catch (error) { if (error.code !== "ENOENT") { throw error; } }
    const stopRequested = async () => {
        try { return JSON.parse(await regularFile(join(exchange, "stop.json"), 4096)).runId === job.runId; }
        catch (error) { return error.code !== "ENOENT"; }
    };
    const startedAt = new Date().toISOString();
    const release = await acquireRunLock(join(userInfo().homedir, "Library/Application Support/BigWalletTestVM/run.lock"), job.runId);
    try {
        if (!bootstrapEvidence.available) { throw new Error("Installed guest bootstrap does not match this job; run setup before testing"); }
        const provision = await readGuestProvision(identity);
        const workspace = provision.workspacePath;
        const buildVolume = await verifyBuildVolume({vmId: job.vmId, stopRequested});
        const source = await materializeSource(exchange, job, workspace, {stopRequested});
        if (await stopRequested()) { throw new Error("Run cancelled"); }
        const entry = join(workspace, "Scripts/vm/guest.mjs");
        await regularFile(entry);
        if (await realpath(entry) !== entry) { throw new Error("Guest harness entry may not traverse symlinks"); }
        const {runJob} = await import(pathToFileURL(entry).href);
        if (typeof runJob !== "function") { throw new Error("The snapshotted guest harness has no runJob entry"); }
        return await runJob({job, identity, provision, workspace, exchange, artifacts, source, buildVolume, bootstrapEvidence,
            stopRequested, writeJSON: atomicJSON, readSnapshotFile: regularFile, hashFile});
    } catch (error) {
        let report = {version: 1, runId: job.runId, vmId: job.vmId, kind: job.kind, profile: job.profile,
            identity, source: job.source, startedAt, stages: []};
        try {
            const previous = JSON.parse(await regularFile(join(artifacts, "result.json")));
            if (previous.runId === job.runId && previous.vmId === job.vmId && previous.kind === job.kind &&
                previous.source?.sha256 === job.source.sha256 && Array.isArray(previous.stages) &&
                previous.stages.every(stage => stage && typeof stage.id === "string" && typeof stage.status === "string")) {
                report = previous;
            }
        } catch {}
        report.preflight = {...report.preflight, bootstrap: bootstrapEvidence,
            checks: {...report.preflight?.checks, bootstrap: bootstrapEvidence.available}};
        const status = await stopRequested() ? "cancelled" : "failed";
        const finishedAt = new Date().toISOString();
        Object.assign(report, {status, error: error.message, finishedAt});
        for (const stage of report.stages) {
            if (["passed", "failed", "blocked", "cancelled"].includes(stage.status)) { continue; }
            Object.assign(stage, {status: status === "cancelled" ? "cancelled" : "blocked", reason: error.message, finishedAt});
        }
        const counts = Object.fromEntries(["passed", "failed", "blocked", "cancelled"].map(outcome =>
            [outcome, report.stages.filter(stage => stage.status === outcome).length]));
        report.summary = {...report.summary, status, counts,
            issues: [...(Array.isArray(report.summary?.issues) ? report.summary.issues : []), error.message]};
        report.coverage = {...report.coverage, status: "partial", fullSuiteVerified: false,
            incompleteStages: report.stages.filter(stage => stage.status !== "passed").map(stage => ({id: stage.id, status: stage.status}))};
        await atomicJSON(join(artifacts, "result.json"), report);
        return report;
    } finally { await release(); }
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
    main().then(report => { process.stdout.write(`${JSON.stringify({runId: report.runId, status: report.status})}\n`); process.exitCode = report.status === "passed" ? 0 : 1; })
        .catch(error => { process.stderr.write(`Guest bootstrap refused: ${error.message}\n`); process.exitCode = 1; });
}
