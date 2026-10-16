#!/usr/bin/env node

import {spawn} from "node:child_process";
import {createHash} from "node:crypto";
import {constants, createWriteStream} from "node:fs";
import {lstat, mkdir, open, realpath, writeFile} from "node:fs/promises";
import {availableParallelism, cpus, freemem, loadavg, totalmem, userInfo} from "node:os";
import {dirname, isAbsolute, join, resolve, sep} from "node:path";
import {pathToFileURL} from "node:url";
import {createManifest, validateJob, commandForStage} from "./test_manifest.mjs";
import {auditNativeResult, auditResults} from "./result_audit.mjs";

const EXCHANGE_PATH = "/Volumes/BigWalletBuild/Exchange";
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

export async function preflight({workspace, identity, bootstrapEvidence, provision, readSnapshotFile, execute = runProcess, stopRequested = async () => false}) {
    const checks = {};
    const versions = {};
    checks.bootstrap = bootstrapEvidence.available;
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
        provisioning = {vmId: provision.vmId, consoleUser: provision.consoleUser, appliedRequestID: provision.appliedProvisioningRequestID ?? null};
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
        const fingerprint = (await readSnapshotFile(join(workspace, "Scripts/alchemy_jwt_request_proof_key.sha256"), 100)).toString().trim();
        if (sha256(provision.proofKey) !== fingerprint) { throw new Error("Guest proof key does not match the source fingerprint"); }
        proofKey = provision.proofKey;
    } catch (error) { proofKeyIssue = error.message; }
    checks.proofKey = Boolean(proofKey);
    return {report: {checks, versions, destinations, simulators: choices, bootstrap: bootstrapEvidence, pinnedEnvironment, provisioning,
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

export async function prepareNativeSimulators(platform, {destinations, artifacts, stageId, execute, writeJSON, stopRequested = async () => false}) {
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
    await writeJSON(join(artifacts, preparation.artifact), preparation);
    return preparation;
}

export function pendingStageResults(manifest) {
    return manifest.map(stage => ({id: stage.id, group: stage.group, status: "pending",
        ...(stage.nativeAudit ? {nativeAudit: stage.nativeAudit} : {})}));
}

async function preserveGeneratedArtifact(workspace, artifacts, stageId, path, previousHash) {
    const components = typeof path === "string" ? path.split(sep) : [];
    if (!/^[A-Za-z0-9][A-Za-z0-9.-]{0,127}$/.test(stageId) || stageId.includes("..") ||
        !components.length || components.some(component => !component || component === "." || component === "..")) {
        throw new Error("Invalid generated artifact path");
    }
    const source = join(workspace, path);
    if (await realpath(source) !== source || !(await lstat(source)).isFile()) {
        throw new Error("Generated artifact must be a regular file without symlinks");
    }
    const file = await open(source, constants.O_RDONLY | constants.O_NOFOLLOW);
    let contents;
    try {
        if (!(await file.stat()).isFile()) { throw new Error("Generated artifact must be a regular file"); }
        contents = await file.readFile();
    } finally { await file.close(); }
    const hash = sha256(contents);
    if (hash === previousHash) { return null; }
    if (await realpath(artifacts) !== artifacts) { throw new Error("Artifact directory may not traverse symlinks"); }
    let directory = artifacts;
    for (const component of ["generated", stageId, ...components.slice(0, -1)]) {
        directory = join(directory, component);
        try { await mkdir(directory, {mode: 0o700}); }
        catch (error) { if (error.code !== "EEXIST") { throw error; } }
        if (!(await lstat(directory)).isDirectory() || await realpath(directory) !== directory) {
            throw new Error("Generated artifact directory may not traverse symlinks");
        }
    }
    const artifact = join("generated", stageId, path);
    await writeFile(join(artifacts, artifact), contents, {flag: "wx", mode: 0o600});
    return {source: path, artifact, sha256: hash};
}

export async function executeStages(manifest, {workspace, artifacts, preflight: checked, proofKey, execute = runProcess,
    stopRequested = async () => false, publish = async () => {}, runId, exchange, unlockSigning, writeJSON, hashFile, measureResources = resourceSnapshot}) {
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
                    destinations: checked.destinations, artifacts, stageId: stage.id, execute, writeJSON, stopRequested,
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
                await writeJSON(join(artifacts, `${stage.id}.summary.json`), summary);
                await writeJSON(join(artifacts, `${stage.id}.tests.json`), tree);
                result.audit = auditNativeResult(summary, tree, stage.nativeAudit);
                if (!result.audit.ok) { result.status = "failed"; result.reason = result.audit.issues; }
            }
            for (const [path, hash] of Object.entries(before)) {
                const generated = await preserveGeneratedArtifact(workspace, artifacts, stage.id, path, hash);
                if (generated) {
                    result.status = "failed";
                    result.reason = `Generated artifact was not current: ${path}`;
                    (result.generatedArtifacts ??= []).push(generated);
                }
            }
        } catch (error) { result.status = error.cancelled ? "cancelled" : "failed"; result.reason = error.message; }
        result.finishedAt = timestamp();
        result.resources.finished = measureResources();
        await publish(results);
    }
    return results;
}

export async function runJob({job: input, identity, provision, workspace, exchange, artifacts, source, buildVolume,
    bootstrapEvidence, stopRequested, writeJSON, readSnapshotFile, hashFile}) {
    const job = validateJob(input);
    const manifest = job.kind === "run" ? createManifest(job) : [];
    const reportPath = join(artifacts, "result.json");
    const report = {version: 1, runId: job.runId, vmId: job.vmId, kind: job.kind, profile: job.profile, status: "running", startedAt: timestamp(),
        resources: {started: resourceSnapshot()}, identity, source, buildVolume, stages: pendingStageResults(manifest)};
    try {
        await writeJSON(reportPath, report);
        if (await stopRequested()) { throw new Error("Run cancelled"); }
        const checked = await preflight({workspace, identity, provision, bootstrapEvidence, readSnapshotFile, stopRequested});
        report.preflight = checked.report;
        await writeJSON(reportPath, report);
        if (await stopRequested()) { throw new Error("Run cancelled"); }
        if (job.kind === "doctor") {
            report.status = Object.values(checked.report.checks).every(value => value === true) ? "passed" : "failed";
            report.summary = {issues: Object.entries(checked.report.checks).filter(([, value]) => !value).map(([key]) => `Unavailable prerequisite: ${key}`)};
        } else {
            report.stages = await executeStages(manifest, {
                workspace, artifacts, preflight: checked.report, proofKey: checked.proofKey, unlockSigning: checked.unlockSigning, stopRequested, runId: job.runId, exchange,
                writeJSON, hashFile, publish: async stages => { report.stages = structuredClone(stages); await writeJSON(reportPath, report); },
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
    } finally {
        report.finishedAt = timestamp();
        report.resources.finished = resourceSnapshot();
        report.coverage = coverageReport(job, report.stages, report.preflight);
        await writeJSON(reportPath, report);
    }
    return report;
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
    process.stderr.write("Submit guest jobs with Scripts/test_vm.sh; the installed bootstrap owns guest execution.\n");
    process.exitCode = 2;
}
