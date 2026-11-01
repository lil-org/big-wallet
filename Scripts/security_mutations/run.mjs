import {constants} from "node:fs";
import {chmod, lstat, mkdir, open, readFile, readlink, readdir, realpath, rename, writeFile} from "node:fs/promises";
import {createHash, randomUUID} from "node:crypto";
import {dirname, isAbsolute, join, resolve} from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";
import {isDeepStrictEqual} from "node:util";
import {materializeSource, validateJobEnvelope, validateSnapshotManifest} from "../vm/guest_bootstrap.mjs";
import {applyMutation, groupedWitnesses, LIMITS, loadManifest, selectedMutants, sha256, VERSION} from "./contract.mjs";
import {auditMutationEvidence, classifyExecution, readEvidenceFile} from "./audit.mjs";
import {commandEnvironment, runCommand} from "./process.mjs";
import {javascriptCommand, nativeCommand} from "./commands.mjs";
import {bindTestPlan, bundleExecutable, derivedDataLocation} from "./products.mjs";

const repository = fileURLToPath(new URL("../../", import.meta.url));
const EXCHANGE = "/Volumes/BigWalletBuild/Exchange";
const complete = outcome => outcome.code === 0 && !outcome.signal && !outcome.timedOut && !outcome.cancelled && !outcome.error && !outcome.outputDrainTimedOut;
const recordedOutcome = ({code, signal, timedOut, cancelled, outputDrainTimedOut, error}) =>
    ({code, signal, timedOut, cancelled, outputDrainTimedOut: outputDrainTimedOut === true, error: error ?? null});

export function parseOptions(args) {
    const names = {"--tier": "tier", "--failure-dir": "failureDirectory", "--scratch-dir": "scratchDirectory",
        "--destination-macos": "macos", "--destination-ios": "ios", "--signing": "signing", "--workspace": "workspace"};
    const options = {workspace: process.cwd()};
    const seen = new Set();
    for (let index = 0; index < args.length; index += 2) {
        const key = names[args[index]], value = args[index + 1];
        if (!key || !value || value.startsWith("--") || seen.has(key)) { throw new Error("Invalid security mutation arguments"); }
        seen.add(key);
        options[key] = value;
    }
    if (!["core", "extended"].includes(options.tier) || !["local", "apple"].includes(options.signing) ||
        !/^platform=macOS(?:,arch=arm64)?$/.test(options.macos ?? "") ||
        options.tier === "extended" && !/^platform=iOS Simulator,id=[a-f0-9-]{36}$/i.test(options.ios ?? "") ||
        [options.workspace, options.failureDirectory, options.scratchDirectory].some(path => !isAbsolute(path ?? "") || resolve(path) !== path) ||
        new Set([options.workspace, options.failureDirectory, options.scratchDirectory]).size !== 3) {
        throw new Error("Mutation verification requires a tier, signing mode, destinations, and distinct absolute guest directories");
    }
    return options;
}

export async function executeMatrix(mutants, {baseline, apply, execute, restore, stopped = () => false, publish = async () => {}}) {
    const report = {baselineBefore: [], mutants: [], baselineAfter: []};
    report.baselineBefore = await baseline("before");
    await publish(report);
    if (!report.baselineBefore.length || report.baselineBefore.some(result => result.status !== "passed")) { return {...report, status: "failed", error: "Pristine baseline did not pass"}; }
    for (const mutant of mutants) {
        if (stopped()) { return {...report, status: "cancelled", error: "Mutation campaign stopped before completing its selected matrix"}; }
        const record = {id: mutant.id, status: "running"};
        report.mutants.push(record);
        try {
            record.patch = await apply(mutant);
            record.execution = await execute(mutant);
            record.status = record.execution.status;
        } catch (error) {
            record.status = record.patch ? "infrastructure-failure" : "invalid-patch";
            record.error = error.message;
        } finally {
            try { record.restoration = await restore(mutant); }
            catch (error) { record.status = "restoration-failure"; record.error = error.message; }
            await publish(report);
        }
        if (record.status === "restoration-failure") { return {...report, status: "failed", error: "Source restoration failed; later mutants were not run"}; }
    }
    if (stopped()) { return {...report, status: "cancelled", error: "Mutation campaign stopped before the restored baseline"}; }
    report.baselineAfter = await baseline("after");
    const passed = report.mutants.every(result => result.status === "killed") && report.baselineAfter.length > 0 && report.baselineAfter.every(result => result.status === "passed");
    return {...report, status: passed ? "passed" : "failed"};
}

async function regularDirectory(path, create = false) {
    if (create) { await mkdir(path, {recursive: true, mode: 0o700}); }
    if (!(await lstat(path)).isDirectory() || await realpath(path) !== path) { throw new Error(`Mutation directory is not an ordinary local path: ${path}`); }
}

async function fileHash(path, maximum = 1024 * 1024 * 1024) {
    const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
        const before = await file.stat({bigint: true});
        if (!before.isFile() || before.size > BigInt(maximum)) { throw new Error(`Invalid mutation file: ${path}`); }
        const hash = createHash("sha256");
        let bytes = 0;
        const chunk = Buffer.alloc(65536);
        const expected = Number(before.size);
        while (bytes < expected) {
            const read = await file.read(chunk, 0, Math.min(chunk.length, expected - bytes), bytes);
            if (read.bytesRead === 0) { throw new Error(`Mutation file shortened while reading: ${path}`); }
            hash.update(chunk.subarray(0, read.bytesRead));
            bytes += read.bytesRead;
        }
        if ((await file.read(chunk, 0, 1, bytes)).bytesRead !== 0) { throw new Error(`Mutation file grew while reading: ${path}`); }
        const after = await file.stat({bigint: true}), named = await lstat(path, {bigint: true});
        if (!named.isFile() || BigInt(bytes) !== before.size || ["dev", "ino", "size", "mtimeNs", "ctimeNs"].some(key => before[key] !== after[key] || before[key] !== named[key])) {
            throw new Error(`Mutation file changed while reading: ${path}`);
        }
        return {sha256: hash.digest("hex"), bytes};
    } finally { await file.close(); }
}

export async function verifyWorkspace(workspace, manifest, replacements = new Map(), {deadline = Infinity} = {}) {
    const files = [];
    for (const file of manifest.files) {
        if (performance.now() >= deadline) { throw new Error("Source integrity audit exceeded its finalization deadline"); }
        const path = join(workspace, file.path);
        const info = await lstat(path);
        const mode = info.mode & 0o777;
        if (mode !== file.mode) { throw new Error(`Mutation workspace mode changed: ${file.path}`); }
        let digest;
        if (file.type === "symlink") {
            if (!info.isSymbolicLink() || await readlink(path) !== file.target) { throw new Error(`Mutation symlink changed: ${file.path}`); }
            digest = sha256(file.target);
        } else {
            if (!info.isFile() || await realpath(path) !== path) { throw new Error(`Mutation source is not a direct regular file: ${file.path}`); }
            digest = (await fileHash(path)).sha256;
        }
        if (digest !== (replacements.get(file.path) ?? file.sha256)) { throw new Error(`Mutation changed an unexpected source: ${file.path}`); }
        files.push({...file, sha256: digest});
    }
    const known = new Set(manifest.files.map(file => file.path));
    const scan = async relative => {
        if (performance.now() >= deadline) { throw new Error("Source inventory scan exceeded its finalization deadline"); }
        for (const item of await readdir(join(workspace, relative), {withFileTypes: true})) {
            if (["node_modules", ".build", ".swiftpm"].includes(item.name)) { continue; }
            const path = `${relative}/${item.name}`;
            if (item.isDirectory()) { await scan(path); }
            else if (/\.(?:swift|js|mjs|c|h)$/.test(item.name) && !known.has(path)) { throw new Error(`Unexpected source appeared in mutation copy: ${path}`); }
        }
    };
    for (const root of ["Packages/WalletRuntime/Sources", "Packages/WalletRuntime/Tests", "Shared", "App iOS", "App macOS", "Safari Shared", "Tests", "Scripts"]) { await scan(root); }
    return {version: VERSION, files};
}

async function replaceSource(path, bytes, mode) {
    if (await realpath(path) !== path || !(await lstat(path)).isFile()) { throw new Error("Mutation replacement requires a regular source file"); }
    const temporary = `${path}.mutation-${randomUUID()}`;
    await writeFile(temporary, bytes, {flag: "wx", mode});
    await chmod(temporary, mode);
    await rename(temporary, path);
}

export async function runMutations(options) {
    const runId = process.env.BW_TEST_VM_RUN_ID;
    if (process.env.BW_TEST_VM_EXCHANGE !== EXCHANGE || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(runId ?? "") || runId.includes("..")) {
        throw new Error("Security mutation execution requires the active test VM job");
    }
    await regularDirectory(options.workspace);
    await regularDirectory(options.failureDirectory, true);
    await regularDirectory(options.scratchDirectory);
    const started = Date.now(), startedMonotonic = performance.now(), maximumSeconds = options.tier === "core" ? LIMITS.coreSeconds : LIMITS.extendedSeconds;
    let cancelled = false;
    let cleanupDeadline = Infinity;
    const onSignal = () => { cancelled = true; cleanupDeadline = Math.min(cleanupDeadline, performance.now() + 45000); };
    process.on("SIGINT", onSignal); process.on("SIGTERM", onSignal);
    const stopped = () => {
        const stop = cancelled || performance.now() - startedMonotonic >= maximumSeconds * 1000;
        if (stop) { cleanupDeadline = Math.min(cleanupDeadline, performance.now() + 45000); }
        return stop;
    };
    const artifact = async path => ({path, ...await fileHash(join(options.failureDirectory, path), LIMITS.maximumArtifactBytes)});
    const writeArtifact = async (path, value, raw = false) => {
        await mkdir(dirname(join(options.failureDirectory, path)), {recursive: true, mode: 0o700});
        await writeFile(join(options.failureDirectory, path), raw ? value : JSON.stringify(value, null, 2) + "\n", {flag: "wx", mode: 0o600});
        return artifact(path);
    };
    const destination = join(options.failureDirectory, "mutation-report.json");
    let sequence = 0;
    const report = {version: VERSION, runId, tier: options.tier, signing: options.signing, configuration: "Debug",
        startedAt: new Date(started).toISOString(), status: "running", maximumSeconds, commands: [],
        runnerRoot: repository.replace(/\/$/, ""), artifactDirectory: options.failureDirectory,
        destinations: {macos: options.macos, ...(options.ios ? {ios: options.ios} : {})}, nodeExecutable: process.execPath,
        derivedDataDirectory: join(process.env.HOME, "Library/Developer/Xcode/DerivedData")};
    const publish = async partial => {
        Object.assign(report, partial);
        const temporary = `${destination}.${randomUUID()}.tmp`;
        await writeFile(temporary, JSON.stringify(report, null, 2) + "\n", {flag: "wx", mode: 0o600});
        await rename(temporary, destination);
    };
    const invoke = async (command, args, label, {cwd = options.workspace, timeoutSeconds = LIMITS.querySeconds, build = false, logPath} = {}) => {
        const path = logPath ?? `commands/${String(++sequence).padStart(3, "0")}-${label}.log`;
        await mkdir(dirname(join(options.failureDirectory, path)), {recursive: true, mode: 0o700});
        process.stdout.write(`Security mutations: ${label}\n`);
        const env = commandEnvironment();
        if (build && options.signing === "apple" && process.env.ALCHEMY_JWT_REQUEST_PROOF_KEY) { env.ALCHEMY_JWT_REQUEST_PROOF_KEY = process.env.ALCHEMY_JWT_REQUEST_PROOF_KEY; }
        const outcome = await runCommand(command, args, {cwd, env, logPath: join(options.failureDirectory, path),
            timeoutSeconds: Math.max(1, Math.min(timeoutSeconds, maximumSeconds - (performance.now() - startedMonotonic) / 1000)), stopRequested: stopped});
        const evidence = {argv: [command, ...args], cwd, outcome: recordedOutcome(outcome), log: await artifact(path)};
        report.commands.push(evidence);
        return {evidence, outcome};
    };
    let workspace, sourceManifest;
    const originals = new Map();
    try {
        const verification = await invoke("/bin/sh", ["-c", '. "$1"; test_vm_require_guest_session', "security-mutations",
            join(repository, "Scripts/vm/guest_session.sh")], "verify-guest-session");
        if (!complete(verification.outcome)) { throw new Error("Security mutations require the verified guest session"); }
        const job = validateJobEnvelope(JSON.parse(await readFile(join(EXCHANGE, "job.json"))));
        const marker = JSON.parse(await readFile(join(options.workspace, ".big-wallet-vm-workspace.json")));
        const sourceBytes = await readFile(join(EXCHANGE, "snapshot-manifest.json"));
        sourceManifest = validateSnapshotManifest(JSON.parse(sourceBytes));
        if (job.kind !== "run" || job.runId !== runId || marker.runId !== runId || marker.vmId !== job.vmId ||
            !isDeepStrictEqual(marker.source, job.source) || sha256(sourceBytes) !== job.source.sha256 ||
            process.env.BW_TEST_VM_SOURCE_SHA256 !== job.source.sha256) { throw new Error("Security mutation source is not the submitted VM snapshot"); }
        report.source = job.source;
        report.sourceManifest = await writeArtifact("source-manifest.json", sourceBytes, true);
        const loaded = await loadManifest();
        const mutants = selectedMutants(loaded.manifest, options.tier);
        report.manifestSHA256 = loaded.sha256;
        report.selectedIDs = mutants.map(mutant => mutant.id);
        report.manifest = await writeArtifact("mutation-manifest.json", loaded.bytes, true);
        workspace = join(options.scratchDirectory, "workspace");
        await materializeSource(EXCHANGE, job, workspace, {stopRequested: stopped});
        report.workspace = workspace;
        await verifyWorkspace(workspace, sourceManifest);
        report.originals = [];
        for (const path of new Set(mutants.flatMap(mutant => [mutant.source, mutant.witness.file]))) {
            const bytes = await readFile(join(workspace, path));
            const file = sourceManifest.files.find(file => file.path === path && file.type === "file");
            if (!file || sha256(bytes) !== file.sha256) { throw new Error(`Curated mutation input is not in the snapshot: ${path}`); }
            originals.set(path, {bytes, mode: file.mode});
            report.originals.push({source: path, artifact: await writeArtifact(`originals/${path}`, bytes, true)});
        }
        for (const mutant of mutants) {
            applyMutation(originals.get(mutant.source).bytes.toString("utf8"), mutant);
            if (!originals.get(mutant.witness.file).bytes.toString("utf8").includes(mutant.witness.marker)) { throw new Error(`Missing invariant witness marker: ${mutant.id}`); }
        }
        report.toolchain = {};
        for (const [name, command, args] of [["xcode", "xcodebuild", ["-version"]], ["swift", "xcrun", ["swiftc", "--version"]], ["node", process.execPath, ["--version"]]]) {
            const result = await invoke(command, args, `toolchain-${name}`);
            if (!complete(result.outcome)) { throw new Error(`Could not identify ${name}`); }
            report.toolchain[name] = result.outcome.stdout.trim();
        }
        const {prepareNativeSimulators} = await import("../vm/guest.mjs");
        let preparedPlatform;
        const productLocations = new Map();
        const preparePlatform = async family => {
            const platform = family === "ios-app" ? "ios" : "macos";
            if (family === "javascript" || preparedPlatform === platform) { return; }
            const id = `mutation-${++sequence}-${platform}`;
            const prepared = await prepareNativeSimulators(platform, {destinations: {macos: options.macos, ...(options.ios ? {ios: options.ios} : {})},
                artifacts: options.failureDirectory, stageId: id, stopRequested: stopped,
                writeJSON: async (path, value) => { await writeFile(path, JSON.stringify(value, null, 2) + "\n", {flag: "wx", mode: 0o600}); },
                execute: async (command, args, settings) => (await invoke(command, args, `${id}-simulator`,
                    {timeoutSeconds: settings.timeoutSeconds, logPath: settings.logPath.replace(options.failureDirectory + "/", "")})).outcome});
            if (prepared.status !== "passed") { throw new Error(prepared.reason ?? "Mutation simulator preparation failed"); }
            preparedPlatform = platform;
        };
        const runWitnesses = async (family, witnesses, label, mutant = null) => {
            await preparePlatform(family);
            const selectors = witnesses.map(witness => witness.selector);
            const execution = {family, selectors};
            const folder = label;
            await mkdir(join(options.failureDirectory, folder), {recursive: true, mode: 0o700});
            if (family === "javascript") {
                const command = javascriptCommand(witnesses, report);
                const test = await invoke(command.command, command.args, `${label}-test`, {cwd: workspace, timeoutSeconds: LIMITS.testSeconds, logPath: `${folder}/test.log`});
                execution.test = {...test.evidence, results: await writeArtifact(`${folder}/node-results.ndjson`, test.outcome.stdout, true)};
                const classified = classifyExecution({...execution, nodeResults: test.outcome.stdout,
                    diagnosticText: test.outcome.stdout + test.outcome.stderr}, {witness: mutant?.witness});
                return {...execution, ...classified};
            }
            const selectedOptions = {...options, runId};
            const buildCommand = nativeCommand(family, "build-for-testing", selectors, selectedOptions);
            const build = await invoke(buildCommand.command, buildCommand.args, `${label}-build`, {cwd: join(workspace, buildCommand.cwd),
                timeoutSeconds: LIMITS.buildSeconds, build: true, logPath: `${folder}/build.log`});
            execution.build = build.evidence;
            if (!complete(build.outcome)) { return {...execution, ...classifyExecution(execution, {witness: mutant?.witness})}; }
            const pristineBaseline = label === `baseline-before/${family}`;
            const pinnedLocation = pristineBaseline ? null : productLocations.get(family);
            if (!pristineBaseline && !pinnedLocation) { throw new Error("Incremental mutation build has no pristine product-location pin"); }
            const location = derivedDataLocation((await readEvidenceFile(join(options.failureDirectory, execution.build.log.path))).toString("utf8"),
                report.derivedDataDirectory, pinnedLocation);
            if (pristineBaseline) { productLocations.set(family, location); }
            const productsRoot = await realpath(location.products);
            const confine = async path => {
                const canonical = await realpath(path);
                if (!canonical.startsWith(productsRoot + "/")) { throw new Error("Mutation test product escaped its build products directory"); }
            };
            const planNames = (await readdir(location.products)).filter(name => name.endsWith(".xctestrun")).sort();
            if (planNames.length > 32) { throw new Error("Too many XCTest plans in the mutation build root"); }
            const matching = [];
            for (const name of planNames) {
                const path = join(location.products, name);
                await confine(path);
                const raw = await readEvidenceFile(path);
                const parsed = await invoke("/usr/bin/plutil", ["-convert", "json", "-o", "-", path], `${label}-test-plan-${matching.length + 1}`);
                if (!complete(parsed.outcome)) { throw new Error("Unable to inspect the built XCTest run plan"); }
                const decoded = JSON.parse(parsed.outcome.stdout);
                const binding = bindTestPlan(decoded, {family, selectors, products: location.products});
                if (binding) { matching.push({path, raw, decoded, binding}); }
            }
            if (matching.length !== 1) { throw new Error("Build products must contain exactly one matching XCTest run plan"); }
            const plan = matching[0];
            execution.build.testPlan = {originalPath: plan.path, ...location,
                source: await writeArtifact(`${folder}/built.xctestrun`, plan.raw, true),
                decoded: await writeArtifact(`${folder}/test-plan.json`, plan.decoded)};
            const binaries = [];
            execution.build.productInfo = [];
            for (const target of plan.binding) {
                for (const [role, bundle] of [["test", target.bundle], ...(target.host ? [["host", target.host]] : [])]) {
                    await confine(bundle);
                    const infoPath = join(bundle, family === "ios-app" ? "Info.plist" : "Contents/Info.plist");
                    await confine(infoPath);
                    const infoBytes = await readEvidenceFile(infoPath);
                    const infoResult = await invoke("/usr/bin/plutil", ["-convert", "json", "-o", "-", infoPath], `${label}-product-info-${execution.build.productInfo.length + 1}`);
                    if (!complete(infoResult.outcome)) { throw new Error("Unable to inspect a bound XCTest product Info.plist"); }
                    const info = JSON.parse(infoResult.outcome.stdout);
                    const path = bundleExecutable(bundle, info, family);
                    await confine(path);
                    const productIndex = execution.build.productInfo.length;
                    execution.build.productInfo.push({target: target.target, role, bundle,
                        source: await writeArtifact(`${folder}/products/${productIndex}.Info.plist`, infoBytes, true),
                        decoded: await writeArtifact(`${folder}/products/${productIndex}.Info.json`, info)});
                    const identity = {target: target.target, role, bundle};
                    binaries.push({...identity, path, ...await fileHash(path)});
                    for (const item of await readdir(dirname(path))) {
                        if (item.endsWith(".debug.dylib")) {
                            const sidecar = join(dirname(path), item);
                            await confine(sidecar);
                            binaries.push({...identity, role: `${role}-debug`, path: sidecar, ...await fileHash(sidecar)});
                        }
                    }
                }
            }
            execution.build.binaries = await writeArtifact(`${folder}/binaries.json`, binaries);
            const bundle = `${folder}/tests.xcresult`;
            if ((await fileHash(plan.path)).sha256 !== execution.build.testPlan.source.sha256) { throw new Error("Built XCTest run plan changed before execution"); }
            const testCommand = nativeCommand(family, "test-without-building", selectors, {...selectedOptions, testRunPath: plan.path}, join(options.failureDirectory, bundle));
            const test = await invoke(testCommand.command, testCommand.args, `${label}-test`, {cwd: join(workspace, testCommand.cwd),
                timeoutSeconds: LIMITS.testSeconds, logPath: `${folder}/test.log`});
            execution.test = {...test.evidence, resultBundle: bundle};
            execution.build.testPlan.afterSHA256 = (await fileHash(plan.path)).sha256;
            for (const product of execution.build.productInfo) {
                const path = join(product.bundle, family === "ios-app" ? "Info.plist" : "Contents/Info.plist");
                await confine(path);
                product.afterSHA256 = (await fileHash(path)).sha256;
                if (product.afterSHA256 !== product.source.sha256) { throw new Error("XCTest product metadata changed during execution"); }
            }
            const binariesAfter = [];
            for (const binary of binaries) { await confine(binary.path); binariesAfter.push({...binary, ...await fileHash(binary.path)}); }
            execution.test.binariesAfter = await writeArtifact(`${folder}/binaries-after.json`, binariesAfter);
            if (execution.build.testPlan.afterSHA256 !== execution.build.testPlan.source.sha256 || !isDeepStrictEqual(binariesAfter, binaries)) {
                throw new Error("Bound XCTest plan or executable bytes changed during the witness run");
            }
            if (test.outcome.timedOut || test.outcome.cancelled || test.outcome.signal || test.outcome.error) {
                return {...execution, ...classifyExecution({...execution, binaries}, {witness: mutant?.witness})};
            }
            const parsed = {};
            for (const kind of ["summary", "tests"]) {
                const result = await invoke("xcrun", ["xcresulttool", "get", "test-results", kind, "--path", join(options.failureDirectory, bundle)], `${label}-${kind}`);
                if (!complete(result.outcome)) { throw new Error(`Unable to read mutation XCTest ${kind}`); }
                parsed[kind] = JSON.parse(result.outcome.stdout);
                execution.test[kind === "tests" ? "tree" : "summary"] = await writeArtifact(`${folder}/${kind}.json`, parsed[kind]);
            }
            return {...execution, ...classifyExecution({...execution, binaries, summary: parsed.summary, tree: parsed.tests,
                diagnosticText: test.outcome.stdout + test.outcome.stderr}, {witness: mutant?.witness})};
        };
        const result = await executeMatrix(mutants, {
            stopped, publish,
            baseline: async phase => {
                const records = [];
                await verifyWorkspace(workspace, sourceManifest);
                for (const group of groupedWitnesses(mutants)) {
                    records.push(await runWitnesses(group.family, group.witnesses, `baseline-${phase}/${group.family}`));
                    if (records.at(-1).status !== "passed" || stopped()) { break; }
                }
                return records;
            },
            apply: async mutant => {
                await verifyWorkspace(workspace, sourceManifest);
                const original = originals.get(mutant.source);
                const changed = applyMutation(original.bytes.toString("utf8"), mutant);
                const patch = await writeArtifact(`mutants/${mutant.id}/patch.json`, changed.patch);
                await replaceSource(join(workspace, mutant.source), changed.source, original.mode);
                await verifyWorkspace(workspace, sourceManifest, new Map([[mutant.source, changed.patch.afterSHA256]]));
                return patch;
            },
            execute: mutant => runWitnesses(mutant.family, [mutant.witness], `mutants/${mutant.id}`, mutant),
            restore: async mutant => {
                const original = originals.get(mutant.source);
                await replaceSource(join(workspace, mutant.source), original.bytes, original.mode);
                return writeArtifact(`mutants/${mutant.id}/restoration.json`, await verifyWorkspace(workspace, sourceManifest, new Map(), {deadline: cleanupDeadline}));
            },
        });
        await publish(result);
    } catch (error) {
        report.status = cancelled ? "cancelled" : "failed";
        report.error = error.message;
    } finally {
        if (workspace && sourceManifest) {
            try {
                for (const [path, original] of originals) { await replaceSource(join(workspace, path), original.bytes, original.mode); }
                report.finalRestoration = await writeArtifact("final-restoration.json", await verifyWorkspace(workspace, sourceManifest, new Map(), {deadline: cleanupDeadline}));
            } catch (error) { report.status = "failed"; report.restorationError = error.message; }
        }
        report.finishedAt = new Date().toISOString();
        report.elapsedSeconds = (performance.now() - startedMonotonic) / 1000;
        if (report.elapsedSeconds >= maximumSeconds) { report.status = "failed"; report.error = "Mutation campaign watchdog expired"; }
        await publish({});
        process.removeListener("SIGINT", onSignal); process.removeListener("SIGTERM", onSignal);
    }
    const audit = await auditMutationEvidence(destination, {tier: options.tier, signing: options.signing, runId, sourceSHA256: process.env.BW_TEST_VM_SOURCE_SHA256});
    report.audit = audit;
    if (!audit.ok) { report.status = "failed"; }
    await publish({});
    process.stdout.write(`Security mutation result: ${report.status}; ${JSON.stringify(audit.mutationCounts)}\n`);
    return report;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
    try { const result = await runMutations(parseOptions(process.argv.slice(2))); if (result.status !== "passed") { process.exitCode = 1; } }
    catch (error) { process.stderr.write(`${error.message}\n`); process.exitCode = 1; }
}
