import {spawnSync} from "node:child_process";
import {createHash} from "node:crypto";
import {constants} from "node:fs";
import {copyFile, lstat, mkdir, open, realpath, writeFile} from "node:fs/promises";
import {isAbsolute, join, resolve} from "node:path";
import {isDeepStrictEqual} from "node:util";
import {fileURLToPath, pathToFileURL} from "node:url";
import {captureSourceIdentity} from "../approval_lifecycle/source_identity.mjs";
import {auditConsumerReport, auditUpgradeResult} from "./audit.mjs";
import {ARCHIVE_DIRECTORY, BASELINE, FIXTURE_ID, PHASES} from "./contract.mjs";

const repository = fileURLToPath(new URL("../../", import.meta.url));
const sha256 = value => createHash("sha256").update(value).digest("hex");

export function parseOptions(args) {
    const options = {};
    for (let index = 0; index < args.length; index += 2) {
        const name = {"--configuration": "configuration", "--failure-dir": "failureDirectory", "--scratch-dir": "scratchDirectory"}[args[index]];
        const value = args[index + 1];
        if (!name || !value || value.startsWith("--") || Object.hasOwn(options, name)) { throw new Error("Invalid upgrade verification arguments"); }
        options[name] = value;
    }
    if (!["Debug", "Release"].includes(options.configuration) ||
        [options.failureDirectory, options.scratchDirectory].some(value => typeof value !== "string" || !isAbsolute(value) || resolve(value) !== value) ||
        options.failureDirectory === options.scratchDirectory) {
        throw new Error("Upgrade verification requires a configuration and separate absolute guest output directories");
    }
    return options;
}

export function assertIsolatedProducerSymbols(output) {
    if (typeof output !== "string") { throw new Error("Missing historical producer symbol audit"); }
    const forbidden = output.split(/\r?\n/).map(value => value.trim()).filter(value => /^_*SecItem/.test(value));
    if (forbidden.length) { throw new Error(`Historical producer can access operating-system Keychain storage: ${forbidden.join(", ")}`); }
    return [];
}

async function fileIdentity(path, maximum = 1024 * 1024 * 1024) {
    const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
        const before = await file.stat({bigint: true});
        if (!before.isFile() || before.size > BigInt(maximum)) { throw new Error(`Invalid verification file: ${path}`); }
        const data = await file.readFile();
        const [after, named] = await Promise.all([file.stat({bigint: true}), lstat(path, {bigint: true})]);
        if (BigInt(data.length) !== before.size || !named.isFile() ||
            ["dev", "ino", "size", "mtimeNs", "ctimeNs"].some(key => before[key] !== after[key] || before[key] !== named[key])) {
            throw new Error(`Verification file changed while reading: ${path}`);
        }
        return {sha256: sha256(data), bytes: data.length, data};
    } finally { await file.close(); }
}

async function privateDirectory(path, create = false) {
    if (create) { await mkdir(path, {recursive: true, mode: 0o700}); }
    const info = await lstat(path);
    if (!info.isDirectory() || info.isSymbolicLink() || await realpath(path) !== path) {
        throw new Error(`Verification requires an ordinary guest directory: ${path}`);
    }
}

const writeJSON = (path, value) => writeFile(path, JSON.stringify(value, null, 2) + "\n", {mode: 0o600});

export async function runUpgrade(options) {
    const verified = spawnSync("/bin/sh", ["-c", '. "$1"; test_vm_require_guest_session', "wallet-upgrade", join(repository, "Scripts/vm/guest_session.sh")],
        {cwd: repository, stdio: "inherit", timeout: 30000});
    if (verified.error || verified.status !== 0) { throw new Error("Upgrade verification requires the provisioned VM session"); }
    await privateDirectory(options.scratchDirectory);
    await privateDirectory(options.failureDirectory, true);
    const runId = process.env.BW_TEST_VM_RUN_ID;
    if (typeof runId !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(runId) || runId.includes("..")) {
        throw new Error("Upgrade verification requires the active VM run identity");
    }
    const report = {version: 1, runId, fixtureID: FIXTURE_ID, baseline: BASELINE, configuration: options.configuration,
        status: "running", provenance: {commands: []}, phases: []};
    const destination = join(options.failureDirectory, "upgrade-report.json");
    let commandIndex = 0;
    let archiveManifest;
    const run = async (command, args, label, timeout = 1800000) => {
        process.stdout.write(`${label}\n`);
        const result = spawnSync(command, args, {cwd: repository, encoding: "utf8", maxBuffer: 64 * 1024 * 1024, timeout});
        const log = `${String(++commandIndex).padStart(2, "0")}-${label.toLowerCase().replace(/[^a-z0-9]+/g, "-")}.log`;
        await writeFile(join(options.failureDirectory, log), (result.stdout ?? "") + (result.stderr ?? ""), {mode: 0o600});
        report.provenance.commands.push({argv: [command, ...args], processID: result.pid, exitCode: result.status, log});
        if (result.error || result.signal || result.status !== 0) {
            process.stderr.write(((result.stdout ?? "") + (result.stderr ?? "")).slice(-30000));
            throw new Error(`${label} failed: ${result.error?.message ?? result.signal ?? result.status}`);
        }
        return result;
    };
    try {
        const archiveDirectory = join(repository, ARCHIVE_DIRECTORY);
        const sourceDirectory = join(options.scratchDirectory, "predecessor-source");
        await run("python3", ["Scripts/wallet_upgrade/archive.py", "--verify", "--extract", sourceDirectory], "Verify historical source archive");
        const manifestFile = await fileIdentity(join(archiveDirectory, "manifest.json"), 1024 * 1024);
        const manifest = JSON.parse(manifestFile.data);
        archiveManifest = manifest;
        await writeFile(join(options.failureDirectory, "archive-manifest.json"), manifestFile.data, {mode: 0o600});
        const archive = await fileIdentity(join(archiveDirectory, "source.tar.gz"), 8 * 1024 * 1024);
        Object.assign(report.provenance, {archiveSHA256: archive.sha256, manifestSHA256: manifestFile.sha256,
            archivedFileCount: manifest.files.length, archivedSwiftCount: manifest.swiftSources.length,
            archivedCUnitCount: manifest.cSources.length, commitTreeProofVerified: true});
        const sdk = (await run("xcrun", ["--sdk", "macosx", "--show-sdk-path"], "Locate macOS SDK", 30000)).stdout.trim();
        if (!isAbsolute(sdk)) { throw new Error("Invalid macOS SDK path"); }
        report.provenance.swiftVersion = (await run("xcrun", ["swiftc", "--version"], "Record Swift compiler", 30000)).stdout.trim();
        report.provenance.clangVersion = (await run("xcrun", ["clang", "--version"], "Record C compiler", 30000)).stdout.trim();
        const objects = join(options.scratchDirectory, "predecessor-objects");
        await mkdir(objects, {mode: 0o700});
        const objectFiles = [];
        for (const [index, source] of manifest.cSources.entries()) {
            const output = join(objects, `${index}.o`);
            await run("xcrun", ["--sdk", "macosx", "clang", "-target", "arm64-apple-macosx14.0", "-isysroot", sdk,
                "-std=gnu11", "-O3", ...manifest.definitions.map(value => `-D${value}`), "-Wno-unused-function",
                "-Wno-shorten-64-to-32", "-c", join(sourceDirectory, source), "-o", output], `Compile historical C unit ${index + 1}`);
            objectFiles.push(output);
        }
        const driver = join(repository, "Scripts/wallet_upgrade/ProducerDriver.swift");
        const adapters = join(repository, "Scripts/wallet_upgrade/IsolatedStorageAdapters.swift");
        report.provenance.driverSHA256 = (await fileIdentity(driver)).sha256;
        report.provenance.adaptersSHA256 = (await fileIdentity(adapters)).sha256;
        const producer = join(options.scratchDirectory, "ShippedWalletProducer");
        await run("xcrun", ["--sdk", "macosx", "swiftc", "-swift-version", "5", "-parse-as-library", "-O", "-whole-module-optimization",
            "-target", "arm64-apple-macosx14.0", "-sdk", sdk, "-module-name", "ShippedWalletProducer",
            ...manifest.swiftSources.map(path => join(sourceDirectory, path)), driver, adapters, ...objectFiles,
            "-framework", "Foundation", "-framework", "AppKit", "-framework", "CryptoKit", "-framework", "Security", "-o", producer],
        "Compile unmodified historical Swift sources");
        const symbols = await run("xcrun", ["nm", "-j", "-u", producer], "Audit historical storage isolation", 30000);
        report.provenance.undefinedSecurityStorageSymbols = assertIsolatedProducerSymbols(symbols.stdout);
        report.provenance.undefinedSymbolsAuditExitCode = symbols.status;
        report.provenance.undefinedSymbolsSHA256 = sha256(symbols.stdout);
        const {data: producerData, ...producerIdentity} = await fileIdentity(producer);
        report.provenance.producerBinary = producerIdentity;
        const fixtureDirectory = join(options.failureDirectory, "predecessor");
        const produced = await run(producer, ["produce", "--output", fixtureDirectory], "Generate shipped wallet state", 300000);
        report.provenance.producerProcessID = produced.pid;
        report.provenance.producerExitCode = produced.status;
        const keychain = await fileIdentity(join(fixtureDirectory, "keychain.plist"), 16 * 1024 * 1024);
        const preferences = await fileIdentity(join(fixtureDirectory, "preferences.plist"), 16 * 1024 * 1024);
        const expectations = await fileIdentity(join(fixtureDirectory, "expectations.json"), 16 * 1024 * 1024);
        const fixture = JSON.parse(expectations.data);
        if (fixture.version !== 1 || fixture.fixtureID !== FIXTURE_ID ||
            !isDeepStrictEqual(fixture.baseline, BASELINE) || !Array.isArray(fixture.wallets) || !Array.isArray(fixture.networks)) {
            throw new Error("Historical producer returned an invalid fixture");
        }
        report.fixture = {keychainSHA256: keychain.sha256, preferencesSHA256: preferences.sha256, expectationsSHA256: expectations.sha256,
            walletCount: fixture.wallets.length, accountCount: fixture.wallets.reduce((count, wallet) => count + wallet.accounts.length, 0),
            networkCount: fixture.networks.length};
        await run(process.execPath, ["Scripts/validate_upgrade_consumer_target.mjs"], "Validate isolated consumer graph", 120000);
        const buildArgs = ["build", "--package-path", "Packages/WalletUpgradeHarness", "--configuration", options.configuration.toLowerCase(),
            "--product", "WalletUpgradeConsumer", "--jobs", "2", "-Xswiftc", "-enable-testing"];
        await run("swift", buildArgs, `Build current ${options.configuration} consumer`);
        const binaryDirectory = (await run("swift", ["build", "--package-path", "Packages/WalletUpgradeHarness",
            "--configuration", options.configuration.toLowerCase(), "--show-bin-path", "-Xswiftc", "-enable-testing"], "Locate current consumer", 120000)).stdout.trim();
        if (!isAbsolute(binaryDirectory)) { throw new Error("Invalid current consumer binary path"); }
        const consumer = join(binaryDirectory, "WalletUpgradeConsumer");
        report.sourceIdentity = await captureSourceIdentity(consumer);
        const states = {};
        for (const name of new Set(PHASES.map(phase => phase.state))) {
            const state = join(options.failureDirectory, name);
            await mkdir(state, {mode: 0o700});
            states[name] = state;
        }
        for (const name of ["keychain.plist", "preferences.plist"]) {
            await copyFile(join(fixtureDirectory, name), join(states.loaded, name), constants.COPYFILE_EXCL);
        }
        const fixtureHashes = {keychainSHA256: keychain.sha256, preferencesSHA256: preferences.sha256};
        for (const phase of PHASES) {
            const phaseReport = join(options.failureDirectory, `${phase.mode}.json`);
            const completed = await run(consumer, [phase.mode, "--fixture", fixtureDirectory, "--state", states[phase.state], "--report", phaseReport],
                `Verify ${phase.mode}`, 600000);
            const result = JSON.parse((await fileIdentity(phaseReport, 16 * 1024 * 1024)).data);
            if (result.processID !== completed.pid) { throw new Error(`${phase.mode}: consumer process identity mismatch`); }
            const audit = auditConsumerReport(result, phase, fixtureHashes);
            report.phases.push(result);
            await writeJSON(destination, report);
            if (!audit.ok) { throw new Error(audit.issues.join("; ")); }
        }
        report.fixtureAfter = {keychainSHA256: (await fileIdentity(join(fixtureDirectory, "keychain.plist"))).sha256,
            preferencesSHA256: (await fileIdentity(join(fixtureDirectory, "preferences.plist"))).sha256};
        if ((await fileIdentity(join(fixtureDirectory, "expectations.json"))).sha256 !== expectations.sha256) {
            throw new Error("Historical expectation bytes changed during verification");
        }
        report.status = "passed";
        report.audit = auditUpgradeResult(report, {configuration: options.configuration, baseline: BASELINE},
            {runId, sourceSHA256: report.sourceIdentity.source.sha256});
        if (!report.audit.ok) { throw new Error(report.audit.issues.join("; ")); }
    } catch (error) {
        report.status = "failed";
        report.error = error.message;
        throw error;
    } finally {
        await writeJSON(join(options.failureDirectory, "provenance.json"), {version: 1, baseline: BASELINE, archiveManifest: archiveManifest ?? null,
            sourceIdentity: report.sourceIdentity ?? null, fixture: report.fixture ?? null, ...report.provenance});
        await writeJSON(destination, report);
    }
    process.stdout.write(`Upgrade and recovery verification passed (${options.configuration})\n`);
    return report;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
    try { await runUpgrade(parseOptions(process.argv.slice(2))); }
    catch (error) { process.stderr.write(`${error.message}\n`); process.exitCode = 1; }
}
