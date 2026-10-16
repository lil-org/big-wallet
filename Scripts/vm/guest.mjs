#!/usr/bin/env node

import {spawn} from "node:child_process";
import {createHash, randomUUID} from "node:crypto";
import {constants, createReadStream, createWriteStream} from "node:fs";
import {chmod, copyFile, lstat, mkdir, open, readFile, readlink, realpath, rename, rm, stat, symlink} from "node:fs/promises";
import {availableParallelism, cpus, freemem, loadavg, totalmem, userInfo} from "node:os";
import {basename, dirname, isAbsolute, join, relative, resolve, sep} from "node:path";
import {pathToFileURL} from "node:url";
import {createManifest, validateJob, commandForStage, RUNNER_TOOL_NAMES} from "./test_manifest.mjs";
import {auditNativeResult, auditResults} from "./result_audit.mjs";

export const IDENTITY_PATH = "/Library/Application Support/BigWalletTestVM/identity.json";
export const PROVISIONING_PATH = "/Library/Application Support/BigWalletTestVM/provisioning.json";
export const EXCHANGE_PATH = "/Volumes/BigWalletBuild/Exchange";
export const INSTALLED_RUNNER_DIRECTORY = "/usr/local/libexec/big-wallet-vm";
export const BUILD_VOLUME = "/Volumes/BigWalletBuild";
const MAX_JSON_BYTES = 16 * 1024 * 1024;
const timestamp = () => new Date().toISOString();
const sha256 = value => createHash("sha256").update(value).digest("hex");
const inside = (parent, child) => child === parent || child.startsWith(`${parent}${sep}`);

export function resourceSnapshot({now = timestamp, cpuCount = () => cpus().length, availableCPUs = availableParallelism,
    totalMemory = totalmem, freeMemory = freemem, loadAverage = loadavg} = {}) {
    const recordedAt = now();
    try {
        const logicalCPUCount = cpuCount();
        const availableCPUCount = availableCPUs();
        const totalMemoryBytes = totalMemory();
        const freeMemoryBytes = freeMemory();
        const load = loadAverage();
        if (![logicalCPUCount, availableCPUCount, totalMemoryBytes].every(value => Number.isSafeInteger(value) && value > 0) ||
            !Number.isSafeInteger(freeMemoryBytes) || freeMemoryBytes < 0 || freeMemoryBytes > totalMemoryBytes ||
            !Array.isArray(load) || load.length !== 3 || load.some(value => !Number.isFinite(value) || value < 0)) {
            throw new Error("Invalid resource measurements");
        }
        return {recordedAt, available: true, logicalCPUCount, availableCPUCount, totalMemoryBytes, freeMemoryBytes,
            loadAverage: {oneMinute: load[0], fiveMinutes: load[1], fifteenMinutes: load[2]}, oneMinuteLoadPerCPU: load[0] / logicalCPUCount};
    } catch { return {recordedAt, available: false}; }
}

export async function atomicJSON(path, value) {
    await mkdir(dirname(path), {recursive: true});
    const temporary = `${path}.${randomUUID()}.tmp`;
    const file = await open(temporary, "wx", 0o600);
    try { await file.writeFile(`${JSON.stringify(value, null, 2)}\n`); await file.sync(); }
    finally { await file.close(); }
    await rename(temporary, path);
}

async function regularFile(path, maximum = MAX_JSON_BYTES) {
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

export function cleanEnvironment(environment = process.env) {
    const allowed = ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "DEVELOPER_DIR"];
    return Object.fromEntries([
        ...allowed.flatMap(key => typeof environment[key] === "string" ? [[key, environment[key]]] : []),
        ["CI", "1"], ["WRANGLER_SEND_METRICS", "false"], ["NO_COLOR", "1"],
    ]);
}

export async function runProcess(command, args, {cwd, env = cleanEnvironment(), logPath, timeoutSeconds = 60, stopRequested = async () => false} = {}) {
    if (await stopRequested()) { return {code: null, signal: null, output: "", timedOut: false, cancelled: true}; }
    let output = "";
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    let cancelled = false;
    let launchError;
    let interval;
    let deadline;
    let escalationDone = Promise.resolve();
    let exited = false;
    let stopping = false;
    let polling = false;
    const log = logPath ? createWriteStream(logPath, {flags: "wx", mode: 0o600}) : null;
    const child = spawn(command, args, {cwd, env, shell: false, detached: true, stdio: ["ignore", "pipe", "pipe"]});
    const closed = new Promise(resolveClose => child.once("close", resolveClose));
    const ended = new Promise(resolveExit => {
        const finish = (code, signal) => {
            if (exited) { return; }
            exited = true;
            clearTimeout(deadline);
            clearInterval(interval);
            resolveExit({code, signal});
        };
        child.once("exit", finish);
        child.on("error", error => { launchError = error.message; finish(null, null); });
    });
    const kill = signal => {
        if (!child.pid) { return; }
        try { process.kill(-child.pid, signal); } catch (error) { if (error.code !== "ESRCH") { launchError ??= error.message; } }
    };
    const stop = reason => {
        if (exited || stopping) { return; }
        stopping = true;
        timedOut = reason === "timeout";
        cancelled = reason === "cancel";
        kill("SIGTERM");
        if (child.pid) { escalationDone = new Promise(resolveEscalation => setTimeout(() => { kill("SIGKILL"); resolveEscalation(); }, 5000)); }
    };
    const capture = data => {
        log?.write(data);
        if (output.length < MAX_JSON_BYTES) { output += data.toString("utf8").slice(0, MAX_JSON_BYTES - output.length); }
    };
    child.stdout.on("data", data => { stdout += data.toString("utf8").slice(0, MAX_JSON_BYTES - stdout.length); capture(data); });
    child.stderr.on("data", data => { stderr += data.toString("utf8").slice(0, MAX_JSON_BYTES - stderr.length); capture(data); });
    log?.on("error", error => { launchError = `Stage log failed: ${error.message}`; stop("failure"); });
    deadline = setTimeout(() => stop("timeout"), timeoutSeconds * 1000);
    interval = setInterval(async () => {
        if (polling) { return; }
        polling = true;
        try { if (await stopRequested()) { stop("cancel"); } }
        catch { stop("cancel"); }
        finally { polling = false; }
    }, 500);
    const outcome = await ended;
    let drainTimer;
    let outputDrainTimedOut = false;
    await Promise.race([closed, new Promise(resolveDrain => {
        drainTimer = setTimeout(() => {
            outputDrainTimedOut = true;
            child.stdout.destroy();
            child.stderr.destroy();
            resolveDrain();
        }, 1000);
    })]);
    clearTimeout(drainTimer);
    await escalationDone;
    if (log) { await new Promise(resolveLog => log.end(resolveLog)); }
    return {...outcome, output, stdout, stderr, timedOut, cancelled, outputDrainTimedOut, ...(launchError ? {error: launchError} : {})};
}

export async function verifyGuest(vmId, {execute = runProcess, identityPath = IDENTITY_PATH} = {}) {
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

async function hashFile(path) {
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

export function chooseDestinations(simulators) {
    const destinations = {macos: "platform=macOS,arch=arm64"};
    const choices = {};
    for (const [platform, pattern, preferred] of [
        ["ios", /\.iOS-/, "iPhone 18 Pro"], ["visionos", /\.(?:xrOS|visionOS)-/, "Apple Vision Pro"],
    ]) {
        const candidates = Object.entries(simulators?.devices ?? {}).filter(([runtime]) => pattern.test(runtime))
            .flatMap(([runtime, devices]) => devices.filter(device => device.isAvailable && typeof device.udid === "string" &&
                (platform !== "ios" || device.name?.startsWith("iPhone"))).map(device => ({...device, runtime})))
            .sort((left, right) => Number(right.name === preferred) - Number(left.name === preferred) || right.runtime.localeCompare(left.runtime, undefined, {numeric: true}) || left.name.localeCompare(right.name));
        if (candidates[0]) {
            const device = candidates[0];
            choices[platform] = {name: device.name, udid: device.udid, runtime: device.runtime};
            destinations[platform] = `platform=${platform === "ios" ? "iOS" : "visionOS"} Simulator,id=${device.udid}`;
        }
    }
    return {destinations, choices};
}

export function pinnedEnvironmentEvidence(xcodeOutput, runtimeData, provisioning) {
    const expectedXcode = provisioning.xcode;
    const liveXcode = {version: xcodeOutput.match(/^Xcode ([^\r\n]+)/m)?.[1], buildVersion: xcodeOutput.match(/^Build version ([^\r\n]+)/m)?.[1]};
    const xcodeMatches = typeof expectedXcode?.version === "string" && typeof expectedXcode?.buildVersion === "string" &&
        liveXcode.version === expectedXcode.version && liveXcode.buildVersion === expectedXcode.buildVersion;
    const pins = provisioning.runtimes;
    const runtimes = {};
    for (const [id, platform, marker] of [["ios", "iOS", ".iOS-"], ["visionos", "visionOS", ".xrOS-"]]) {
        const wanted = Array.isArray(pins) ? pins.filter(runtime => runtime.platform === platform) : [];
        const expected = wanted.length === 1 ? wanted[0] : null;
        const installed = expected && typeof expected.version === "string" && typeof expected.buildVersion === "string" &&
            runtimeData?.runtimes?.find(runtime => runtime.isAvailable && runtime.identifier?.includes(marker) &&
                runtime.version === expected.version && runtime.buildversion === expected.buildVersion);
        runtimes[id] = {available: Boolean(installed), ...(expected ? {expected: {version: expected.version, buildVersion: expected.buildVersion}} : {}),
            ...(installed ? {identifier: installed.identifier} : {})};
    }
    return {xcode: {available: xcodeMatches, expected: {version: expectedXcode?.version, buildVersion: expectedXcode?.buildVersion}, actual: liveXcode}, runtimes};
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

export async function verifyBuildVolume({execute = runProcess, vmId, stopRequested = async () => false,
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

export async function runnerToolsEvidence(expected, {directory = INSTALLED_RUNNER_DIRECTORY, inspect = lstat, hash = hashFile} = {}) {
    const hashes = {};
    const missing = [];
    const mismatched = [];
    for (const name of RUNNER_TOOL_NAMES) {
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

export async function preflight({workspace, identity, expectedRunnerTools, execute = runProcess, provisioningPath = PROVISIONING_PATH,
    provision: suppliedProvision, stopRequested = async () => false}) {
    const checks = {};
    const versions = {};
    const runnerTools = await runnerToolsEvidence(expectedRunnerTools);
    checks.runnerTools = runnerTools.available;
    const query = async (name, command, args) => {
        const result = await execute(command, args, {timeoutSeconds: 120, stopRequested});
        versions[name] = result.output.trim().slice(0, 2000);
        return result;
    };
    const node = await query("node", "node", ["--version"]);
    const npm = await query("npm", "npm", ["--version"]);
    checks.node = node.code === 0 && node.output.trim() === "v24.22.0" && npm.code === 0 && npm.output.trim() === "11.16.0";
    const python = await query("python", "python3", ["--version"]);
    checks.python = python.code === 0 && /^Python 3\./.test(python.output.trim());
    const jq = await query("jq", "/usr/local/bin/jq", ["--version"]);
    checks.jq = jq.code === 0 && jq.output.trim() === "jq-1.8.1";
    const xcode = await query("xcode", "xcodebuild", ["-version"]);
    const swift = await query("swift", "xcrun", ["swift", "--version"]);
    const major = Number(xcode.output.match(/Xcode (\d+)/)?.[1]);
    const swiftVersion = swift.output.match(/Swift version (\d+)\.(\d+)/);
    checks.xcode = xcode.code === 0 && major >= 27 && swift.code === 0 && swiftVersion &&
        (Number(swiftVersion[1]) > 6 || Number(swiftVersion[1]) === 6 && Number(swiftVersion[2]) >= 4) ? true : false;
    const simulatorResult = await execute("xcrun", ["simctl", "list", "devices", "available", "-j"], {timeoutSeconds: 120, stopRequested});
    const runtimeResult = await execute("xcrun", ["simctl", "list", "runtimes", "-j"], {timeoutSeconds: 120, stopRequested});
    let simulatorData;
    let runtimeData;
    try { simulatorData = JSON.parse(simulatorResult.stdout ?? simulatorResult.output); } catch {}
    try { runtimeData = JSON.parse(runtimeResult.stdout ?? runtimeResult.output); } catch {}
    let {destinations, choices} = chooseDestinations(simulatorData);
    checks.macos = checks.xcode && identity.aqua;
    checks.ios = simulatorResult.code === 0 && Boolean(destinations.ios);
    checks.visionos = simulatorResult.code === 0 && Boolean(destinations.visionos);
    checks.signing = false;
    let proofKey;
    let proofKeyIssue;
    let signingIssue;
    let unlockSigning;
    let pinnedEnvironment;
    let missingSigning;
    let provisioning;
    try {
        const provision = suppliedProvision ?? await readGuestProvision(identity, provisioningPath);
        provisioning = provisioningEvidence(provision);
        if (Array.isArray(provision.missingSigning)) {
            missingSigning = provision.missingSigning.filter(value => typeof value === "string").map(value => value.slice(0, 1024)).slice(0, 20);
        }
        pinnedEnvironment = pinnedEnvironmentEvidence(xcode.output, runtimeData, provision);
        checks.xcode = checks.xcode && pinnedEnvironment.xcode.available;
        const runtimeIDs = new Set(Object.values(pinnedEnvironment.runtimes).filter(runtime => runtime.available).map(runtime => runtime.identifier));
        ({destinations, choices} = chooseDestinations({devices: Object.fromEntries(Object.entries(simulatorData?.devices ?? {}).filter(([runtime]) => runtimeIDs.has(runtime)))}));
        checks.macos = checks.xcode && identity.aqua;
        checks.ios = simulatorResult.code === 0 && runtimeResult.code === 0 && Boolean(destinations.ios);
        checks.visionos = simulatorResult.code === 0 && runtimeResult.code === 0 && Boolean(destinations.visionos);
        if (typeof provision.keychainPath === "string" && inside(join(userInfo().homedir, "Library/Keychains"), provision.keychainPath) &&
            typeof provision.keychainPassword === "string" && provision.keychainPassword.length > 0 && provision.keychainPassword.length <= 8192) {
            unlockSigning = async () => {
                const unlocked = await execute("/usr/bin/security", ["unlock-keychain", "-p", provision.keychainPassword, provision.keychainPath], {timeoutSeconds: 30, stopRequested});
                return unlocked.code === 0 && !unlocked.cancelled && !unlocked.timedOut;
            };
            if (await unlockSigning()) {
                const signing = await execute("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning", provision.keychainPath], {timeoutSeconds: 30, stopRequested});
                checks.signing = signing.code === 0 && /\b[1-9][0-9]* valid identities found\b/.test(signing.output);
            }
        }
        if (!checks.signing) { signingIssue = "The dedicated guest signing keychain could not be unlocked or contains no valid signing identity"; }
        if (typeof provision.proofKey !== "string" || !/^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$/.test(provision.proofKey)) { throw new Error("Guest proof key is missing or malformed"); }
        const fingerprint = (await regularFile(join(workspace, "Scripts/alchemy_jwt_request_proof_key.sha256"), 100)).toString().trim();
        if (sha256(provision.proofKey) !== fingerprint) { throw new Error("Guest proof key does not match the source fingerprint"); }
        proofKey = provision.proofKey;
    } catch (error) { proofKeyIssue = error.message; }
    checks.proofKey = Boolean(proofKey);
    return {report: {checks, versions, destinations, simulators: choices, runnerTools, pinnedEnvironment, provisioning,
        ...(proofKeyIssue ? {proofKeyIssue} : {}), ...(signingIssue ? {signingIssue} : {}), ...(missingSigning ? {missingSigning} : {})}, proofKey, unlockSigning};
}

export function coverageReport(job, stages, preflight) {
    const selected = job.stages.length > 0 || job.onlyTesting.length > 0 || Boolean(job.configuration) || Boolean(job.approvalArgs?.length);
    const missingPrerequisites = Object.entries(preflight?.checks ?? {}).filter(([, available]) => available !== true).map(([name]) => name);
    if (job.kind === "doctor") {
        return {scope: "prerequisites", status: preflight && !missingPrerequisites.length ? "complete" : "partial", missingPrerequisites};
    }
    const manifest = createManifest(job);
    for (const requirement of new Set(manifest.flatMap(stage => stage.requirements))) {
        if (preflight?.checks?.[requirement] !== true && !missingPrerequisites.includes(requirement)) { missingPrerequisites.push(requirement); }
    }
    const outcomes = new Map(stages.map(stage => [stage.id, stage.status]));
    const incompleteStages = manifest.filter(stage => outcomes.get(stage.id) !== "passed").map(stage => ({id: stage.id, status: outcomes.get(stage.id) ?? "not-run"}));
    const fullSuiteVerified = !selected && stages.length === manifest.length && !incompleteStages.length && !missingPrerequisites.length && auditResults(stages).status === "passed";
    return {scope: selected ? "selected" : "full", status: fullSuiteVerified ? "complete" : "partial",
        selectedStageGroups: job.stages.length ? [...job.stages] : ["all"], onlyTesting: [...job.onlyTesting],
        missingPrerequisites, incompleteStages, fullSuiteVerified};
}

export async function prepareStageScratch(workspace, runId, stageId) {
    if (!isAbsolute(workspace) || inside(EXCHANGE_PATH, workspace) || await realpath(workspace) !== workspace ||
        typeof runId !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(runId) || runId.includes("..") ||
        typeof stageId !== "string" || !/^[A-Za-z0-9][A-Za-z0-9.-]{0,127}$/.test(stageId) || stageId.includes("..")) {
        throw new Error("Invalid guest-local scratch identity");
    }
    let directory = dirname(workspace);
    if (await realpath(directory) !== directory) { throw new Error("Scratch parent may not traverse symlinks"); }
    for (const component of [".big-wallet-vm-scratch", runId, stageId]) {
        directory = join(directory, component);
        try { await mkdir(directory, {mode: 0o700}); }
        catch (error) { if (error.code !== "EEXIST") { throw error; } }
        const metadata = await lstat(directory);
        if (!metadata.isDirectory() || metadata.isSymbolicLink() || metadata.uid !== process.getuid() ||
            (metadata.mode & 0o077) !== 0 || await realpath(directory) !== directory) {
            throw new Error("Guest scratch must remain private and may not traverse symlinks");
        }
    }
    return directory;
}

export async function prepareNativeSimulators(platform, {destinations, artifacts, stageId, execute, stopRequested = async () => false}) {
    const preparation = {platform, status: "running", artifact: `${stageId}.simulators.json`, startedAt: timestamp(), steps: []};
    const invoke = async (args, timeoutSeconds) => {
        if (await stopRequested()) { preparation.status = "cancelled"; throw new Error("Stop requested during simulator preparation"); }
        const step = {command: ["xcrun", "simctl", ...args], log: `${stageId}.simulator-${preparation.steps.length + 1}-${args[0]}.log`, timeoutSeconds};
        preparation.steps.push(step);
        const outcome = await execute("xcrun", ["simctl", ...args], {timeoutSeconds, stopRequested, logPath: join(artifacts, step.log)});
        Object.assign(step, {exitCode: outcome.code, signal: outcome.signal, timedOut: outcome.timedOut, cancelled: outcome.cancelled,
            status: outcome.cancelled ? "cancelled" : outcome.timedOut || outcome.error || outcome.code !== 0 ? "failed" : "passed"});
        if (step.status !== "passed") {
            preparation.status = step.status;
            throw new Error(outcome.cancelled ? "Stop requested during simulator preparation" : outcome.timedOut ?
                `Simulator ${args[0]} timed out after ${timeoutSeconds}s` : outcome.error ?? `Simulator ${args[0]} failed with exit code ${outcome.code}`);
        }
        return outcome.stdout ?? outcome.output;
    };
    try {
        if (!["macos", "ios", "visionos"].includes(platform)) { throw new Error("Unknown native test platform"); }
        const selected = {};
        for (const [name, label] of [["ios", "iOS"], ["visionos", "visionOS"]]) {
            if (destinations[name] === undefined) { continue; }
            const match = new RegExp(`^platform=${label} Simulator,id=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$`, "i").exec(destinations[name]);
            if (!match) { throw new Error(`Invalid selected ${name} simulator destination`); }
            selected[name] = match[1].toUpperCase();
        }
        const target = platform === "macos" ? undefined : selected[platform];
        if (platform !== "macos" && !target) { throw new Error(`Missing selected ${platform} simulator`); }
        preparation.target = target ?? null;
        if (Object.keys(selected).length) {
            const inventory = JSON.parse(await invoke(["list", "devices", "--json"], 60));
            if (!inventory.devices || typeof inventory.devices !== "object" || Array.isArray(inventory.devices) ||
                Object.values(inventory.devices).some(devices => !Array.isArray(devices))) { throw new Error("Invalid simulator device inventory"); }
            const devices = new Map(Object.values(inventory.devices).flat().filter(device => typeof device?.udid === "string")
                .map(device => [device.udid.toUpperCase(), device]));
            for (const udid of new Set(Object.values(selected))) {
                const device = devices.get(udid);
                if (!device || !["Booted", "Booting", "Shutdown"].includes(device.state)) { throw new Error(`Selected simulator ${udid} has no stable boot state`); }
                if (udid !== target && device.state !== "Shutdown") { await invoke(["shutdown", udid], 120); }
            }
            if (target) {
                const device = devices.get(target);
                if (device.isAvailable === false) { throw new Error(`Selected simulator ${target} is unavailable`); }
                if (device.state === "Shutdown") { await invoke(["boot", target], 120); }
                await invoke(["bootstatus", target, "-b"], 300);
            }
        }
        preparation.status = "passed";
    } catch (error) {
        if (preparation.status !== "cancelled") { preparation.status = "failed"; }
        preparation.reason = error.message;
    }
    preparation.finishedAt = timestamp();
    await atomicJSON(join(artifacts, preparation.artifact), preparation);
    return preparation;
}

export function pendingStageResults(manifest) {
    return manifest.map(stage => ({id: stage.id, group: stage.group, status: "pending",
        ...(stage.nativeAudit ? {nativeAudit: stage.nativeAudit} : {})}));
}

export async function executeStages(manifest, {workspace, artifacts, preflight: checked, proofKey, execute = runProcess,
    stopRequested = async () => false, publish = async () => {}, runId, exchange, unlockSigning, measureResources = resourceSnapshot}) {
    const results = pendingStageResults(manifest);
    const byID = new Map(results.map(result => [result.id, result]));
    await publish(results);
    for (const stage of manifest) {
        const result = byID.get(stage.id);
        result.resources = {started: measureResources()};
        if (await stopRequested()) {
            result.status = "cancelled";
            result.reason = "Stop requested";
            result.resources.finished = measureResources();
            await publish(results);
            continue;
        }
        const dependencies = stage.dependencies.filter(id => byID.get(id)?.status !== "passed");
        const requirements = stage.requirements.filter(key => checked.checks[key] !== true);
        if (dependencies.length || requirements.length) {
            result.status = "blocked";
            result.reason = {dependencies, requirements};
            result.resources.finished = measureResources();
            await publish(results);
            continue;
        }
        result.startedAt = timestamp();
        result.status = "running";
        await publish(results);
        try {
            if (stage.requirements.includes("signing") && (!unlockSigning || !await unlockSigning())) { throw new Error("Guest signing keychain could not be unlocked"); }
            if (stage.nativeAudit) {
                result.simulatorPreparation = await prepareNativeSimulators(stage.nativeAudit.platform, {
                    destinations: checked.destinations, artifacts, stageId: stage.id, execute, stopRequested,
                });
                if (result.simulatorPreparation.status !== "passed") {
                    throw Object.assign(new Error(result.simulatorPreparation.reason), {cancelled: result.simulatorPreparation.status === "cancelled"});
                }
            }
            const scratch = stage.scratchDirectory ? await prepareStageScratch(workspace, runId, stage.id) : undefined;
            if (scratch) { result.scratchDirectory = scratch; }
            const {command, args} = commandForStage(stage, {destinations: checked.destinations, artifacts, scratch});
            result.command = [command, ...args];
            result.log = `${stage.id}.log`;
            const before = Object.fromEntries(await Promise.all((stage.unchanged ?? []).map(async path => [path, await hashFile(join(workspace, path))])));
            const outcome = await execute(command, args, {
                cwd: join(workspace, stage.cwd), env: {...cleanEnvironment(), ...(stage.env ?? {}),
                    ...(runId && exchange ? {BW_TEST_VM_RUN_ID: runId, BW_TEST_VM_EXCHANGE: exchange} : {}),
                    ...(stage.proofKey ? {ALCHEMY_JWT_REQUEST_PROOF_KEY: proofKey} : {})},
                logPath: join(artifacts, result.log), timeoutSeconds: stage.timeoutSeconds, stopRequested,
            });
            result.exitCode = outcome.code;
            result.signal = outcome.signal;
            if (outcome.outputDrainTimedOut) { result.outputDrainTimedOut = true; }
            result.status = outcome.cancelled ? "cancelled" : outcome.timedOut || outcome.error || outcome.code !== 0 ? "failed" : "passed";
            if (outcome.timedOut) { result.reason = `Timed out after ${stage.timeoutSeconds}s`; }
            if (outcome.error) { result.reason = outcome.error; }
            if (stage.nativeAudit && !outcome.cancelled && !outcome.timedOut) {
                const bundle = join(artifacts, `${stage.id}.xcresult`);
                result.resultBundle = `${stage.id}.xcresult`;
                const summaryResult = await execute("xcrun", ["xcresulttool", "get", "test-results", "summary", "--path", bundle], {timeoutSeconds: 120});
                const treeResult = await execute("xcrun", ["xcresulttool", "get", "test-results", "tests", "--path", bundle], {timeoutSeconds: 120});
                if (summaryResult.code !== 0 || treeResult.code !== 0) { throw new Error("Could not audit XCTest result bundle"); }
                const summary = JSON.parse(summaryResult.stdout ?? summaryResult.output);
                const tree = JSON.parse(treeResult.stdout ?? treeResult.output);
                await atomicJSON(join(artifacts, `${stage.id}.summary.json`), summary);
                await atomicJSON(join(artifacts, `${stage.id}.tests.json`), tree);
                result.audit = auditNativeResult(summary, tree, stage.nativeAudit);
                if (!result.audit.ok) { result.status = "failed"; result.reason = result.audit.issues; }
            }
            for (const [path, hash] of Object.entries(before)) {
                if (await hashFile(join(workspace, path)) !== hash) { result.status = "failed"; result.reason = `Generated artifact was not current: ${path}`; }
            }
        } catch (error) { result.status = error.cancelled ? "cancelled" : "failed"; result.reason = error.message; }
        result.finishedAt = timestamp();
        result.resources.finished = measureResources();
        await publish(results);
    }
    return results;
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
                env: cleanEnvironment(), stdio: ["ignore", "ignore", "ignore", file.fd], timeout: 10000,
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
    const job = validateJob(JSON.parse(await regularFile(join(exchange, "job.json"), 65536)));
    if (job.kind !== "run" || job.runId !== environment.BW_TEST_VM_RUN_ID) { throw new Error("Guest run identity is stale"); }
    await verify(job.vmId);
    return {runId: job.runId, status: "passed"};
}

export async function main(args = process.argv.slice(2)) {
    if (args[0] === "--verify-session") { return verifySession(args); }
    if (args.length !== 2 || args[0] !== "--exchange" || !isAbsolute(args[1])) { throw new Error("Usage: guest.mjs --exchange /absolute/exchange"); }
    if (args[1] !== EXCHANGE_PATH) { throw new Error("Guest execution requires the fixed local exchange"); }
    const exchange = await verifyExchangeDirectory();
    const job = validateJob(JSON.parse(await regularFile(join(exchange, "job.json"), 65536)));
    if (job.kind === "prepare") { throw new Error("Prepare jobs belong to the guest provisioning helper"); }
    const identity = await verifyGuest(job.vmId);
    const artifacts = join(exchange, "artifacts");
    await mkdir(artifacts, {recursive: true, mode: 0o700});
    if (await realpath(artifacts) !== artifacts) { throw new Error("Artifact directory may not traverse symlinks"); }
    const reportPath = join(artifacts, "result.json");
    try {
        const previous = JSON.parse(await regularFile(reportPath));
        if (previous.runId === job.runId && ["passed", "failed", "cancelled"].includes(previous.status)) { return previous; }
    } catch (error) { if (error.code !== "ENOENT") { throw error; } }
    const manifest = job.kind === "run" ? createManifest(job) : [];
    const report = {version: 1, runId: job.runId, vmId: job.vmId, kind: job.kind, profile: job.profile, status: "running", startedAt: timestamp(),
        resources: {started: resourceSnapshot()}, identity, source: job.source, stages: pendingStageResults(manifest)};
    const stopRequested = async () => {
        try {
            const stop = JSON.parse(await regularFile(join(exchange, "stop.json"), 4096));
            return stop.runId === job.runId;
        } catch (error) { return error.code !== "ENOENT"; }
    };
    const release = await acquireRunLock(join(userInfo().homedir, "Library/Application Support/BigWalletTestVM/run.lock"), job.runId);
    try {
        await atomicJSON(reportPath, report);
        const provision = await readGuestProvision(identity);
        const workspace = provision.workspacePath;
        report.buildVolume = await verifyBuildVolume({vmId: job.vmId, stopRequested});
        if (job.source) { report.source = await materializeSource(exchange, job, workspace, {stopRequested}); }
        if (await stopRequested()) { throw new Error("Run cancelled"); }
        const checked = await preflight({workspace, identity, provision, expectedRunnerTools: job.runnerTools, stopRequested});
        report.preflight = checked.report;
        await atomicJSON(reportPath, report);
        if (await stopRequested()) { throw new Error("Run cancelled"); }
        if (job.kind === "doctor") {
            report.status = Object.values(checked.report.checks).every(value => value === true) ? "passed" : "failed";
            report.summary = {issues: Object.entries(checked.report.checks).filter(([, value]) => !value).map(([key]) => `Unavailable prerequisite: ${key}`)};
        } else {
            report.stages = await executeStages(manifest, {
                workspace, artifacts, preflight: checked.report, proofKey: checked.proofKey, unlockSigning: checked.unlockSigning, stopRequested, runId: job.runId, exchange,
                publish: async stages => { report.stages = structuredClone(stages); await atomicJSON(reportPath, report); },
            });
            report.summary = auditResults(report.stages);
            report.status = report.summary.status;
        }
    } catch (error) {
        report.status = await stopRequested() ? "cancelled" : "failed";
        report.error = error.message;
        for (const stage of report.stages) {
            if (!["pending", "running"].includes(stage.status)) { continue; }
            stage.status = report.status === "cancelled" ? "cancelled" : "blocked";
            stage.reason = error.message;
            stage.finishedAt = timestamp();
        }
        if (manifest.length) { report.summary = auditResults(report.stages); }
    }
    finally {
        try {
            report.finishedAt = timestamp();
            report.resources.finished = resourceSnapshot();
            report.coverage = coverageReport(job, report.stages, report.preflight);
            await atomicJSON(reportPath, report);
        } finally { await release(); }
    }
    return report;
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
    main().then(report => { process.stdout.write(`${JSON.stringify({runId: report.runId, status: report.status})}\n`); process.exitCode = report.status === "passed" ? 0 : 1; })
        .catch(error => { process.stderr.write(`Guest runner refused: ${error.message}\n`); process.exitCode = 1; });
}
