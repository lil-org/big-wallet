import {createHash} from "node:crypto";
import {execFileSync} from "node:child_process";
import {constants} from "node:fs";
import {open, readdir, realpath, writeFile} from "node:fs/promises";
import {homedir} from "node:os";
import {basename, dirname, isAbsolute, join, resolve} from "node:path";
import {isDeepStrictEqual} from "node:util";
import {bindTestPlan, bundleExecutable, derivedDataLocation} from "../security_mutations/products.mjs";
import {EXCHANGE_PATH} from "./guest_bootstrap.mjs";
import {auditASanLog, auditNativeResult, resultBundleInventory} from "./result_audit.mjs";
import {commandForStage} from "./test_manifest.mjs";
import {APP_TEST_CLASS_PLATFORMS, APP_TEST_TARGETS, isCompileOnlyTarget, matchesTestSelector} from "./test_policy.mjs";

const maximumBytes = 16 * 1024 * 1024;
const digest = bytes => createHash("sha256").update(bytes).digest("hex");

export function discoveryProductsDirectory(log, {directory, canonicalDirectory}) {
    if (!isAbsolute(canonicalDirectory ?? "") || resolve(canonicalDirectory) !== canonicalDirectory ||
        !canonicalDirectory.endsWith("/DerivedData")) { throw new Error("Test discovery requires default DerivedData"); }
    const location = derivedDataLocation(log, directory);
    return join(canonicalDirectory, basename(location.root), "Build/Products");
}

function testBundles(bindings) {
    return bindings.flatMap(({target, bundle, host}) => [
        {target, role: "test", bundle}, ...(host ? [{target, role: "host", bundle: host}] : []),
    ]);
}

function linkedProducts(log, build, products, bundles, platform) {
    const root = derivedDataLocation(log, build.directory).products;
    const owners = new Map(bundles.map(owner => [platform === "macos" ? join(owner.bundle, "Contents/MacOS") : owner.bundle, owner]));
    const linked = new Map();
    for (const line of log.split(/\r?\n/)) {
        const command = /^(Ld|Copy) ((?:\\.|[^\s])+)/.exec(line);
        if (!command) { continue; }
        const output = command[2].replace(/\\(.)/g, "$1");
        if (!output.startsWith(root + "/")) { continue; }
        const path = join(products, output.slice(root.length + 1));
        if (!path.startsWith(products + "/")) { continue; }
        const owner = owners.get(dirname(path));
        if (command[1] === "Ld" && owner) {
            if (!path.endsWith(".dylib") || path.endsWith(".debug.dylib")) {
                linked.set(path, {target: owner.target, role: owner.role, path});
            }
            continue;
        }
        const bundle = command[1] === "Ld" ? /^(.+\.framework)\/(?:Versions\/[^/]+\/)?[^/]+$/.exec(path)?.[1] : path;
        if (!bundle?.endsWith(".framework")) { continue; }
        if (command[1] === "Copy" && !bundles.some(owner => bundle.startsWith(owner.bundle + "/"))) { continue; }
        const binary = join(bundle, basename(bundle, ".framework"));
        linked.set(binary, {role: "framework", path: binary});
    }
    for (const [directory, owner] of owners) {
        const mains = [...linked.keys()].filter(path => dirname(path) === directory && !path.endsWith(".dylib"));
        if (mains.length !== 1) { throw new Error(`Build log must identify one ${owner.role} executable for ${owner.target}`); }
    }
    return linked;
}

export function parseTestEnumeration(value, {targets, testPlan, platform, runtime}) {
    if (!value || typeof value !== "object" || !Array.isArray(value.errors) || value.errors.length ||
        !Array.isArray(value.values) || value.values.length !== 1) { throw new Error("XCTest enumeration is missing, ambiguous, or reports errors"); }
    const suite = value.values[0];
    if (!suite || suite.testPlan !== testPlan || !Array.isArray(suite.enabledTests) || !suite.enabledTests.length ||
        suite.enabledTests.length > 20_000 || !Array.isArray(suite.disabledTests) || suite.disabledTests.length) {
        throw new Error("XCTest enumeration must describe one nonempty test plan without disabled tests");
    }
    const identifiers = [];
    const seen = new Set();
    const emptySuites = new Set();
    for (const test of suite.enabledTests) {
        if (!test || typeof test.identifier !== "string" || test.identifier.length > 1024 || Object.keys(test).join(",") !== "identifier") {
            throw new Error("Invalid enumerated XCTest entry");
        }
        const identifier = test.identifier.replace(/\(\)$/, "");
        const parts = identifier.split("/");
        if (parts.length === 2 && identifier === test.identifier && targets.includes(parts[0]) && /^[A-Za-z_]\w*$/.test(parts[1])) {
            if (emptySuites.has(identifier)) { throw new Error(`Duplicate empty XCTest suite: ${identifier}`); }
            emptySuites.add(identifier);
            continue;
        }
        if (parts.length !== 3 || !targets.includes(parts[0]) ||
            !/^[A-Za-z_]\w*$/.test(parts[1]) || !/^test[A-Za-z0-9_]+$/.test(parts[2]) || seen.has(identifier)) {
            throw new Error(`Unexpected or duplicate enumerated XCTest identifier: ${identifier}`);
        }
        seen.add(identifier);
        identifiers.push(identifier);
    }
    if ([...emptySuites].some(suite => identifiers.some(identifier => identifier.startsWith(`${suite}/`)))) {
        throw new Error("XCTest suite is listed as both empty and executable");
    }
    for (const target of targets) {
        if (!identifiers.some(identifier => identifier.startsWith(`${target}/`))) { throw new Error(`XCTest enumeration omits target: ${target}`); }
    }
    if (!runtime) {
        for (const [name, platforms] of Object.entries(APP_TEST_CLASS_PLATFORMS)) {
            if (platforms.includes(platform) && !identifiers.some(identifier => identifier.startsWith(`${APP_TEST_TARGETS[platform]}/${name}/`))) {
                throw new Error(`XCTest enumeration omits critical app suite: ${name}`);
            }
        }
    }
    return identifiers.sort();
}

export function validateDiscoveryPlan(plan, policy) {
    if (!Array.isArray(plan?.TestConfigurations) || plan.TestConfigurations.length !== 1 ||
        plan.TestConfigurations[0].IsEnabled !== true || !Array.isArray(plan.TestConfigurations[0].TestTargets) ||
        typeof plan.TestPlan?.Name !== "string" || !plan.TestPlan.Name || plan.TestPlan.Name.length > 256 ||
        plan.ContainerInfo?.SchemeName !== policy.scheme) { throw new Error("Unexpected XCTest discovery plan"); }
    const targets = plan.TestConfigurations[0].TestTargets;
    if (targets.length !== policy.targets.length || targets.some(target => !policy.targets.includes(target.BlueprintName)) ||
        new Set(targets.map(target => target.BlueprintName)).size !== targets.length) {
        throw new Error("XCTest discovery plan does not contain exactly its required targets");
    }
    for (const target of targets) {
        if (target.IsEnabled === false || target.IsSkipped === true ||
            [target.OnlyTestIdentifiers, target.SkipTestIdentifiers].some(value => value !== undefined && (!Array.isArray(value) || value.length))) {
            throw new Error("XCTest discovery plan contains hidden selection or disabled tests");
        }
        const runtimes = String(target.TestingEnvironmentVariables?.DYLD_INSERT_LIBRARIES ?? "").split(":")
            .map(library => basename(library)).filter(name => /^libclang_rt\.(asan|tsan)_[a-z0-9]+_dynamic\.dylib$/.test(name));
        const suffix = {macos: "osx", ios: "iossim", visionos: "xrossim"}[policy.platform];
        const expected = ["asan", "tsan"].includes(policy.kind) ? [`libclang_rt.${policy.kind}_${suffix}_dynamic.dylib`] : [];
        if (!isDeepStrictEqual(runtimes, expected)) {
            throw new Error("XCTest plan instrumentation does not match its discovery obligation");
        }
    }
    return plan.TestPlan.Name;
}

export function resolveTestSelection(identifiers, policy) {
    for (const selector of policy.mutationWitnesses ?? []) {
        if (!identifiers.includes(selector)) { throw new Error(`Missing runtime mutation witness: ${selector}`); }
    }
    for (const selector of policy.focus ?? []) {
        if (!identifiers.some(identifier => matchesTestSelector(identifier, selector))) {
            throw new Error(`Required ${policy.kind} test policy has no match: ${selector}`);
        }
    }
    const available = identifiers.filter(identifier => !policy.focus?.length || policy.focus.some(selector => matchesTestSelector(identifier, selector)));
    const selected = available.filter(identifier => !policy.selectors.length || policy.selectors.some(selector => matchesTestSelector(identifier, selector)));
    const matchedSelectors = policy.selectors.filter(selector => selected.some(identifier => matchesTestSelector(identifier, selector)));
    return {selected, matchedSelectors};
}

export function executionStage(discoveryStage, identifiers, evidence) {
    const policy = discoveryStage.nativeDiscovery;
    const {selected} = resolveTestSelection(identifiers, policy);
    if (!selected.length) { return null; }
    const {nativeDiscovery, releaseStages, ...stage} = discoveryStage;
    const nativeAudit = {configuration: policy.configuration, platform: policy.platform, kind: policy.kind,
        filtered: selected.length !== identifiers.length, requiredTests: selected, ...(policy.runtime ? {runtime: true} : {})};
    return {...stage, id: policy.executionID, dependencies: [discoveryStage.id], nativeAudit, resultBundle: true,
        discoveryStage: discoveryStage.id,
        args: ["test-without-building", "-xctestrun", evidence.plan.path, "-destination", `$destination:${policy.platform}`,
            "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
            ...(selected.length === identifiers.length ? [] : selected.map(name => `-only-testing:${name}`))]};
}

function enumerationArguments(plan, destination, output) {
    return ["test-without-building", "-xctestrun", plan, "-destination", destination,
        "-enumerate-tests", "-test-enumeration-style", "flat", "-test-enumeration-format", "json",
        "-test-enumeration-output-path", output];
}

export async function verifyArchivedTestRuns(stages, report, artifacts) {
    const records = new Map(report.stages.map(record => [record.id, record]));
    const guestArtifacts = join(EXCHANGE_PATH, "artifacts");
    for (const stage of stages) {
        if (!stage.nativeDiscovery && !stage.discoveryStage) { continue; }
        const record = records.get(stage.id);
        const platform = (stage.nativeDiscovery ?? stage.nativeAudit).platform;
        const udid = report.preflight?.simulators?.[platform]?.udid;
        const destination = platform === "macos" ? "platform=macOS,arch=arm64"
            : `platform=${platform === "ios" ? "iOS" : "visionOS"} Simulator,id=${udid}`;
        if ((platform !== "macos" && !/^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(udid ?? "")) ||
            report.preflight?.destinations?.[platform] !== destination) { throw new Error(`Missing or inconsistent XCTest destination: ${stage.id}`); }
        let command;
        if (stage.nativeDiscovery) {
            const output = join(guestArtifacts, `${stage.id}.discovery.json`);
            command = ["xcodebuild", ...enumerationArguments(record.discovery.plan.path, destination, output)];
            if (!isDeepStrictEqual(record.discovery.command, command)) { throw new Error(`Unexpected XCTest enumeration command: ${stage.id}`); }
        } else {
            const execution = commandForStage(stage, {artifacts: guestArtifacts, destinations: {[platform]: destination}});
            command = [execution.command, ...execution.args];
        }
        if (!isDeepStrictEqual(record.command, command)) { throw new Error(`Unexpected recorded XCTest command: ${stage.id}`); }
        if (record.exitCode !== 0 || !stage.nativeDiscovery && record.signal !== null) {
            throw new Error(`Archived XCTest execution did not exit cleanly: ${stage.id}`);
        }
        if (stage.nativeDiscovery) { continue; }
        const bundle = `${stage.id}.xcresult`;
        if (record.resultBundle !== bundle || await resultBundleInventory(join(artifacts, bundle)) !== record.resultBundleInventorySHA256) {
            throw new Error(`Unexpected archived XCTest bundle inventory: ${stage.id}`);
        }
        const summary = JSON.parse(await readDiscoveryFile(join(artifacts, `${stage.id}.summary.json`)));
        const tree = JSON.parse(await readDiscoveryFile(join(artifacts, `${stage.id}.tests.json`)));
        const audit = auditNativeResult(summary, tree, stage.nativeAudit);
        if (!audit.ok || Object.entries(audit).some(([key, value]) => !isDeepStrictEqual(value, record.audit?.[key]))) {
            throw new Error(`Archived XCTest results do not match the execution policy and audit: ${stage.id}`);
        }
        if (stage.nativeAudit.kind === "asan") {
            const log = `${stage.id}.log`;
            if (record.log !== log || record.outputDrainTimedOut || record.audit.asanLog?.ok !== true) {
                throw new Error(`Missing or incomplete AddressSanitizer log audit: ${stage.id}`);
            }
            const scanned = await auditASanLog(join(artifacts, log));
            if (!scanned.ok || !isDeepStrictEqual(scanned, record.audit.asanLog)) {
                throw new Error(`Archived AddressSanitizer log does not match its passing audit: ${stage.id}`);
            }
        }
    }
}

export function stagesAfterDiscovery(stage, identifiers, evidence, existingIDs) {
    const execution = executionStage(stage, identifiers, evidence);
    if (!execution) { return []; }
    const release = stage.releaseStages ?? [];
    const focus = release.find(value => value.nativeDiscovery)?.nativeDiscovery.focus ?? [];
    const tests = execution.nativeAudit.requiredTests ?? [];
    return [execution, ...(tests.some(identifier => focus.some(selector => matchesTestSelector(identifier, selector)))
        ? release.filter(value => !existingIDs.has(value.id)) : [])];
}

export async function readRecordedDiscovery(stage, record, artifacts) {
    const evidence = record.discovery;
    const prefix = `${stage.id}.discovery`;
    if (!evidence || evidence.artifact !== `${prefix}.json` || evidence.log !== `${stage.id}.log` ||
        !stage.dependencies?.some(id => id.startsWith("build-") && evidence.build?.artifact === `${id}.log`) ||
        evidence.plan?.artifact !== `${prefix}.xctestrun` || evidence.plan.decodedArtifact !== `${prefix}.plan.json` ||
        typeof evidence.plan.path !== "string" || !isAbsolute(evidence.plan.path) || resolve(evidence.plan.path) !== evidence.plan.path ||
        !evidence.plan.path.includes("/DerivedData/") || !evidence.plan.path.endsWith(".xctestrun") ||
        !Array.isArray(evidence.products) || !evidence.products.length) { throw new Error("Missing or malformed XCTest discovery evidence"); }
    const raw = await readDiscoveryFile(join(artifacts, evidence.artifact));
    const buildLog = await readDiscoveryFile(join(artifacts, evidence.build.artifact));
    const planBytes = await readDiscoveryFile(join(artifacts, evidence.plan.artifact));
    if (digest(raw) !== evidence.sha256 || digest(buildLog) !== evidence.build.sha256 ||
        digest(planBytes) !== evidence.plan.sha256) { throw new Error("XCTest discovery artifact identity changed"); }
    if (discoveryProductsDirectory(buildLog.toString("utf8"), evidence.build) !== dirname(evidence.plan.path)) {
        throw new Error("Archived XCTest plan does not match its build log directory");
    }
    const decoded = JSON.parse(execFileSync("/usr/bin/plutil", ["-convert", "json", "-o", "-", join(artifacts, evidence.plan.artifact)],
        {encoding: "utf8", maxBuffer: maximumBytes, timeout: 30_000}));
    const recordedPlan = JSON.parse(await readDiscoveryFile(join(artifacts, evidence.plan.decodedArtifact)));
    if (!isDeepStrictEqual(decoded, recordedPlan)) { throw new Error("Decoded XCTest plan does not match the built plan"); }
    const testPlan = validateDiscoveryPlan(decoded, stage.nativeDiscovery);
    const identifiers = parseTestEnumeration(JSON.parse(raw), {...stage.nativeDiscovery, testPlan});
    if (!isDeepStrictEqual(identifiers, evidence.identifiers) || testPlan !== evidence.testPlan ||
        !isDeepStrictEqual(stage.nativeDiscovery.targets, evidence.targets)) { throw new Error("Recorded discovery inventory does not match Xcode output"); }
    const products = dirname(evidence.plan.path);
    const policy = stage.nativeDiscovery;
    const bindings = bindTestPlan(decoded, {family: policy.runtime ? "runtime" : policy.platform === "macos" ? "macos-app" : "ios-app",
        selectors: policy.targets, products, configuration: policy.configuration, platform: policy.platform});
    if (!bindings) { throw new Error("Archived XCTest plan does not match its configuration and platform"); }
    const expected = linkedProducts(buildLog.toString("utf8"), evidence.build, products, testBundles(bindings), policy.platform);
    for (const binary of evidence.products) {
        const linked = expected.get(binary?.path);
        if (!linked || binary.role !== linked.role || binary.target !== linked.target ||
            !/^[a-f0-9]{64}$/.test(binary.sha256) || !Number.isSafeInteger(binary.bytes) || binary.bytes <= 0 || binary.bytes > 1024 * 1024 * 1024) {
            throw new Error("Invalid XCTest product binding");
        }
        expected.delete(binary.path);
    }
    if (expected.size) { throw new Error(`Missing linked XCTest product: ${expected.keys().next().value}`); }
    await readDiscoveryFile(join(artifacts, evidence.log));
    return {identifiers, evidence};
}

export async function auditDiscoveryStages(manifest, records, {job, artifacts, load = readRecordedDiscovery}) {
    const queue = [...manifest];
    const byID = new Map(records.map(record => [record.id, record]));
    const issues = [];
    const matched = new Set();
    if (byID.size !== records.length) { issues.push("Repeated stage results"); }
    for (let index = 0; index < queue.length; index++) {
        const stage = queue[index];
        const record = byID.get(stage.id);
        if (!record) { issues.push(`Missing required stage: ${stage.id}`); continue; }
        if (!isDeepStrictEqual(stage.nativeDiscovery, record.nativeDiscovery) || !isDeepStrictEqual(stage.nativeAudit, record.nativeAudit) ||
            stage.group !== record.group || stage.discoveryStage !== record.discoveryStage) { issues.push(`Stage policy differs from its resolved plan: ${stage.id}`); }
        if (stage.discoveryStage && record.status === "passed" && record.productsVerified !== true) { issues.push(`Test products were not verified: ${stage.id}`); }
        if (stage.nativeAudit && record.status === "passed" && record.audit?.ok !== true) { issues.push(`Native results were not audited: ${stage.id}`); }
        if (!stage.nativeDiscovery || record.status !== "passed") { continue; }
        try {
            const {identifiers, evidence} = await load(stage, record, artifacts);
            for (const selector of resolveTestSelection(identifiers, stage.nativeDiscovery).matchedSelectors) { matched.add(selector); }
            queue.splice(index + 1, 0, ...stagesAfterDiscovery(stage, identifiers, evidence, new Set(queue.map(value => value.id))));
        } catch (error) { issues.push(`${stage.id}: ${error.message}`); }
    }
    if (!isDeepStrictEqual(queue.map(stage => stage.id), records.map(stage => stage.id))) { issues.push("Result stages do not match resolved discovery obligations"); }
    for (const selector of job.payload.onlyTesting.filter(isCompileOnlyTarget)) {
        const builds = manifest.filter(stage => stage.group === "runtime" && stage.id.startsWith(`runtime.${selector}.`));
        if (builds.length && builds.every(stage => byID.get(stage.id)?.status === "passed")) { matched.add(selector); }
    }
    const verifiesSelection = !job.payload.stages.length || job.payload.stages.some(stage => ["test", "asan", "tsan"].includes(stage));
    const unmatched = verifiesSelection ? job.payload.onlyTesting.filter(selector =>
        !selector.startsWith("Safari UI Tests ") && selector !== "SafariLifecycleTests" && !selector.startsWith("SafariLifecycleTests/") && !matched.has(selector)) : [];
    for (const selector of unmatched) { issues.push(`XCTest selector did not match selected test coverage: ${selector}`); }
    for (const kind of ["asan", "tsan"]) {
        if (job.payload.stages.includes(kind) && !queue.some(stage => stage.nativeAudit?.kind === kind)) {
            issues.push(`Explicit ${kind} selection did not match any focused tests`);
        }
    }
    return {ok: issues.length === 0, issues, matchedSelectors: [...matched].sort(), unmatchedSelectors: unmatched, stages: queue};
}

async function productHash(path) {
    const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
        const before = await file.stat();
        if (!before.isFile() || before.size <= 0 || before.size > 1024 * 1024 * 1024) { throw new Error("Invalid XCTest product size"); }
        const hash = createHash("sha256");
        const buffer = Buffer.alloc(64 * 1024);
        let size = 0;
        while (size < before.size) {
            const {bytesRead} = await file.read(buffer, 0, Math.min(buffer.length, before.size - size), size);
            if (!bytesRead) { throw new Error("Truncated XCTest product"); }
            hash.update(buffer.subarray(0, bytesRead)); size += bytesRead;
        }
        const after = await file.stat();
        if (before.size !== after.size || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs) { throw new Error("XCTest product changed while hashing"); }
        return {bytes: size, sha256: hash.digest("hex")};
    } finally { await file.close(); }
}

export async function verifyDiscoveryProducts(evidence) {
    if (digest(await readDiscoveryFile(evidence.plan.path)) !== evidence.plan.sha256) { throw new Error("Bound XCTest plan changed before execution"); }
    for (const product of evidence.products) {
        const current = await hashBoundProduct(product);
        if (current.bytes !== product.bytes || current.sha256 !== product.sha256) { throw new Error("Bound XCTest product changed after enumeration"); }
    }
}

async function hashBoundProduct({role, path}) {
    const resolved = await realpath(path);
    if (resolved !== path && !(role === "framework" && resolved.startsWith(dirname(path) + "/Versions/"))) {
        throw new Error("Bound XCTest product was redirected outside its bundle");
    }
    return productHash(resolved);
}

export async function readDiscoveryFile(path) {
    const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
        const before = await file.stat();
        if (!before.isFile() || before.size > maximumBytes) { throw new Error("Test discovery requires a bounded regular file"); }
        const bytes = Buffer.alloc(before.size + 1);
        let length = 0;
        while (length < bytes.length) {
            const {bytesRead} = await file.read(bytes, length, bytes.length - length, length);
            if (!bytesRead) { break; }
            length += bytesRead;
        }
        const after = await file.stat();
        if (length !== before.size || before.size !== after.size || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs) {
            throw new Error("Test discovery file changed while reading");
        }
        return bytes.subarray(0, length);
    } finally { await file.close(); }
}

export async function captureTestDiscovery({stage, buildCommand, buildLog, artifacts, workspace, destination, execute, stopRequested}) {
    const policy = stage.nativeDiscovery;
    const targets = policy.targets;
    const family = policy.runtime ? "runtime" : policy.platform === "macos" ? "macos-app" : "ios-app";
    const run = async (command, args, options = {}) => {
        const result = await execute(command, args, {cwd: workspace, timeoutSeconds: 120, stopRequested, ...options});
        if (result.cancelled) { throw Object.assign(new Error("Test discovery cancelled"), {cancelled: true}); }
        if (result.code !== 0 || result.timedOut || result.error) { throw new Error("Test discovery command failed"); }
        return result;
    };
    if (buildCommand?.[0] !== "xcodebuild" || buildCommand[1] !== "build-for-testing") {
        throw new Error("Test discovery requires its successful test build command");
    }
    const prefix = `${stage.id}.discovery`;
    const rawBuildLog = await readDiscoveryFile(join(artifacts, buildLog));
    const directory = join(homedir(), "Library/Developer/Xcode/DerivedData");
    const canonicalDirectory = await realpath(directory);
    const build = {artifact: buildLog, sha256: digest(rawBuildLog), directory, canonicalDirectory};
    const products = discoveryProductsDirectory(rawBuildLog.toString("utf8"), build);
    if (await realpath(products) !== products) { throw new Error("XCTest products may not be redirected outside default DerivedData"); }
    const names = (await readdir(products)).filter(name => name.endsWith(".xctestrun")).sort();
    if (names.length > 64) { throw new Error("Too many built XCTest plans"); }
    const matching = [];
    for (const name of names) {
        const path = join(products, name);
        if (await realpath(path) !== path) { throw new Error("XCTest plan may not be a symlink"); }
        const raw = await readDiscoveryFile(path);
        const converted = await run("/usr/bin/plutil", ["-convert", "json", "-o", "-", path]);
        const decoded = JSON.parse(converted.stdout ?? converted.output);
        if (decoded.ContainerInfo?.SchemeName !== policy.scheme) { continue; }
        const binding = bindTestPlan(decoded, {family, selectors: targets, products, configuration: policy.configuration, platform: policy.platform});
        if (binding) { matching.push({path, raw, decoded, binding}); }
    }
    if (matching.length !== 1) { throw new Error(`Expected exactly one built XCTest plan, found ${matching.length}`); }
    const plan = matching[0];
    const testPlan = validateDiscoveryPlan(plan.decoded, policy);
    await writeFile(join(artifacts, `${prefix}.xctestrun`), plan.raw, {flag: "wx", mode: 0o600});
    await writeFile(join(artifacts, `${prefix}.plan.json`), JSON.stringify(plan.decoded, null, 2) + "\n", {flag: "wx", mode: 0o600});
    const bundles = testBundles(plan.binding);
    const linked = linkedProducts(rawBuildLog.toString("utf8"), build, products, bundles, policy.platform);
    for (const {bundle, role} of bundles) {
        const infoPath = join(bundle, policy.platform === "macos" ? "Contents/Info.plist" : "Info.plist");
        if (!(await realpath(infoPath)).startsWith(`${products}/`)) { throw new Error("XCTest metadata escaped the product root"); }
        const converted = await run("/usr/bin/plutil", ["-convert", "json", "-o", "-", infoPath]);
        const path = bundleExecutable(bundle, JSON.parse(converted.stdout ?? converted.output), policy.platform === "macos" ? "macos-app" : "ios-app");
        if (linked.get(path)?.role !== role || path.endsWith(".dylib")) { throw new Error(`XCTest bundle executable was not linked: ${path}`); }
    }
    const binaries = [];
    for (const binary of linked.values()) { binaries.push({...binary, ...await hashBoundProduct(binary)}); }
    const args = enumerationArguments(plan.path, destination, join(artifacts, `${prefix}.json`));
    await run("xcodebuild", args, {timeoutSeconds: 300, logPath: join(artifacts, `${stage.id}.log`)});
    const raw = await readDiscoveryFile(join(artifacts, `${prefix}.json`));
    const identifiers = parseTestEnumeration(JSON.parse(raw), {...policy, testPlan});
    const evidence = {artifact: `${prefix}.json`, sha256: digest(raw), log: `${stage.id}.log`, command: ["xcodebuild", ...args], build,
        plan: {path: plan.path, artifact: `${prefix}.xctestrun`, decodedArtifact: `${prefix}.plan.json`, sha256: digest(plan.raw)},
        testPlan, targets, products: binaries, identifiers};
    await verifyDiscoveryProducts(evidence);
    return evidence;
}
