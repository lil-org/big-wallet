#!/usr/bin/env node

import {spawn} from "node:child_process";
import {observeProcess} from "../process_lifecycle.mjs";
import {createHash, randomUUID} from "node:crypto";
import {constants} from "node:fs";
import {readFile, writeFile, mkdir, realpath, lstat, access, copyFile, rename, rm, readdir, open} from "node:fs/promises";
import {join, dirname, basename, resolve} from "node:path";
import {userInfo} from "node:os";
import {pathToFileURL} from "node:url";
import {isDeepStrictEqual} from "node:util";
import {SafariFixtureServer, atomicJSON} from "./fixture_server.mjs";
import {runSafariPreparation} from "./prepare.mjs";

export function parseArguments(args) {
    const options = {onlyTesting: [], iterations: 1};
    const names = {"--phase": "phase", "--platform": "platform", "--configuration": "configuration", "--signing": "signing",
        "--destination": "destination", "--scratch-dir": "scratch", "-resultBundlePath": "resultBundle", "--iterations": "iterations",
        "--preparation-result": "preparationResult", "--prepared-safari": "preparedSafari"};
    for (let index = 0; index < args.length; index += 1) {
        const key = args[index];
        if (key === "--interactive-safari") {
            if (options.interactiveActivation) { throw new Error("Duplicate interactive Safari option"); }
            options.interactiveActivation = true;
            continue;
        }
        const value = args[++index];
        if (key === "--only-testing" && typeof value === "string") { options.onlyTesting.push(value); continue; }
        if (!(key in names) || typeof value !== "string" || value.includes("\0") || options[names[key]] !== undefined && key !== "--iterations") { throw new Error(`Invalid Safari argument: ${key}`); }
        options[names[key]] = key === "--iterations" ? Number(value) : value;
    }
    if (options.preparedSafari !== undefined) {
        try { options.preparedSafari = JSON.parse(options.preparedSafari); } catch { throw new Error("Invalid prepared Safari reference"); }
        validatePreparedSafariReference(options.preparedSafari);
    }
    if (!["build", "test", "prepare"].includes(options.phase) || !["macos", "ios"].includes(options.platform) ||
        !["Debug", "Release"].includes(options.configuration) || !["local", "apple"].includes(options.signing) ||
        ![1, 10].includes(options.iterations) || typeof options.destination !== "string" ||
        !options.scratch?.startsWith("/Volumes/BigWalletBuild/") || options.phase === "test" && !options.resultBundle?.startsWith("/Volumes/BigWalletBuild/") ||
        options.interactiveActivation && (options.platform !== "macos" || options.phase !== "test" || options.preparedSafari) ||
        options.phase === "prepare" && (options.platform !== "macos" || options.signing !== "local" || options.configuration !== "Debug" ||
            !options.preparationResult?.startsWith("/Volumes/BigWalletBuild/") || options.resultBundle || options.preparedSafari || options.onlyTesting.length || options.iterations !== 1) ||
        options.phase !== "prepare" && options.preparationResult !== undefined ||
        options.preparedSafari && (options.phase !== "test" || options.platform !== "macos" || options.signing !== "local")) {
        throw new Error("Invalid Safari execution options");
    }
    return options;
}

export function validatePreparedSafariReference(value) {
    if (!value || typeof value !== "object" || Array.isArray(value) || Object.keys(value).sort().join(",") !== "preparationRunID,receiptSHA256" ||
        typeof value.preparationRunID !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(value.preparationRunID) ||
        value.preparationRunID.includes("..") || !/^[a-f0-9]{64}$/.test(value.receiptSHA256)) {
        throw new Error("Invalid prepared Safari reference");
    }
}

const maximumCapturedBytes = 8 * 1024 * 1024;

export function commandTimeoutSeconds(command, args) {
    if (basename(command) !== "xcodebuild") { return 60; }
    if (args.includes("-showBuildSettings")) { return 120; }
    if (args.includes("test") || args.includes("test-without-building")) { return 7200; }
    return 3600;
}

export function safariTestTimeouts(iterations) {
    if (![1, 10].includes(iterations)) { throw new Error("Invalid Safari test iteration count"); }
    const allowance = String(600 * iterations);
    return {
        args: ["-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", allowance,
            "-maximum-test-execution-time-allowance", allowance],
        timeoutSeconds: iterations === 10 ? 21600 : 7200,
    };
}

export async function execute(command, args, {capture = false, captureStderr = false, env = process.env,
    timeoutSeconds = commandTimeoutSeconds(command, args), maximumBytes = maximumCapturedBytes,
    terminationGraceMilliseconds = 2000, outputDrainMilliseconds = 1000,
    spawnProcess = spawn, signalGroup = (pid, signal) => process.kill(-pid, signal),
    outputStreams = {stdout: process.stdout, stderr: process.stderr}} = {}) {
    if (!Number.isFinite(timeoutSeconds) || timeoutSeconds <= 0 || timeoutSeconds > 21600 ||
        !Number.isSafeInteger(maximumBytes) || maximumBytes < 1 || maximumBytes > maximumCapturedBytes ||
        !Number.isFinite(terminationGraceMilliseconds) || terminationGraceMilliseconds < 0 || terminationGraceMilliseconds > 2000 ||
        !Number.isFinite(outputDrainMilliseconds) || outputDrainMilliseconds < 0 || outputDrainMilliseconds > 1000) {
        throw new Error("Invalid Safari command execution limits");
    }
    const chunks = [];
    const pendingDrains = new Set();
    let tail = Buffer.alloc(0);
    let length = 0;
    let failure;
    let deadline;
    const child = spawnProcess(command, args, {env, detached: true, stdio: ["ignore", "pipe", "pipe"]});
    const lifecycle = observeProcess(child, {
        policy: "safari-command",
        terminationGraceMilliseconds,
        signalGroup,
        onStop: error => { failure ??= error; },
        onFailure: (_kind, error) => { failure ??= error; },
        onExit: () => { clearTimeout(deadline); },
    });
    const stop = error => lifecycle.stop(error);
    const terminate = () => stop(Object.assign(new Error(`${basename(command)} was cancelled`), {cancelled: true}));
    const outputFailed = error => stop(new Error(`${basename(command)} log output failed: ${error.message}`));
    const destinations = new Set([["stdout", capture], ["stderr", captureStderr]].filter(([, retained]) => !retained).map(([name]) => outputStreams[name]));
    for (const destination of destinations) { destination.on("error", outputFailed); }
    const collect = value => {
        const bytes = Buffer.isBuffer(value) ? value : Buffer.from(value);
        const retained = Math.min(bytes.length, maximumBytes - length);
        if (retained > 0) { chunks.push(Buffer.from(bytes.subarray(0, retained))); length += retained; }
        if (retained < bytes.length) {
            stop(Object.assign(new Error(`${basename(command)} output exceeded ${maximumBytes} bytes`), {truncated: true}));
        }
    };
    for (const [name, retained] of [["stdout", capture], ["stderr", captureStderr]]) {
        const stream = child[name];
        stream?.on("data", value => {
            const bytes = Buffer.isBuffer(value) ? value : Buffer.from(value);
            tail = Buffer.from(bytes.length >= 64 * 1024 ? bytes.subarray(-64 * 1024) : Buffer.concat([tail, bytes]).subarray(-64 * 1024));
            if (retained) { collect(bytes); return; }
            const destination = outputStreams[name];
            let flowing;
            try { flowing = destination.write(bytes); }
            catch (error) { outputFailed(error); return; }
            if (flowing === false) {
                stream.pause();
                const pending = {destination, resume: undefined};
                const resume = () => { pendingDrains.delete(pending); stream.resume(); };
                pending.resume = resume;
                pendingDrains.add(pending);
                destination.once("drain", resume);
            }
        });
    }
    process.once("SIGTERM", terminate);
    process.once("SIGINT", terminate);
    deadline = setTimeout(() => stop(Object.assign(new Error(`${basename(command)} timed out after ${timeoutSeconds}s`), {timedOut: true})), timeoutSeconds * 1000);
    try {
        const outcome = await lifecycle.exit;
        await lifecycle.waitForEscalation();
        await lifecycle.drainOutput(outputDrainMilliseconds);
        const output = Buffer.concat(chunks, length).toString("utf8");
        if (!failure && outcome.code !== 0) { failure = new Error(`${basename(command)} failed with ${outcome.signal ? `signal ${outcome.signal}` : `exit code ${outcome.code}`}`); }
        if (failure) {
            const details = redactSafariDiagnostics(tail.toString("utf8"), [env.ALCHEMY_JWT_REQUEST_PROOF_KEY])
                .split(/\r?\n/).filter(line => /error:|failed|timed out|automation|encountered an error|denied|not authorized/i.test(line))
                .slice(-12).map(line => line.slice(0, 1500)).join("\n");
            if (details) { failure.message += `\n${details}`; }
            throw Object.assign(failure, {output, exitCode: outcome.code, signal: outcome.signal, ...(details ? {details} : {})});
        }
        return output;
    } finally {
        clearTimeout(deadline);
        process.removeListener("SIGTERM", terminate);
        process.removeListener("SIGINT", terminate);
        for (const destination of destinations) { destination.removeListener("error", outputFailed); }
        for (const {destination, resume} of pendingDrains) { destination.removeListener("drain", resume); }
        child.stdout?.destroy();
        child.stderr?.destroy();
        lifecycle.dispose();
    }
}

async function privateDirectory(path) {
    await mkdir(path, {recursive: true, mode: 0o700});
    const info = await lstat(path);
    if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid() || info.mode & 0o077 || await realpath(path) !== path) { throw new Error("Unsafe Safari fixture directory"); }
}

function signingSettings(options) {
    if (options.signing !== "local") { return []; }
    return ["CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "PROVISIONING_PROFILE=", "PROVISIONING_PROFILE_SPECIFIER=",
        "CODE_SIGN_ENTITLEMENTS=", "ENABLE_APP_SANDBOX=NO", "ENABLE_HARDENED_RUNTIME=NO", "REGISTER_APP_GROUPS=NO", "CODE_SIGNING_ALLOWED=YES", "BW_VM_VERIFICATION_BUILD=YES"];
}

export function safariXcodeCommands(options, descriptorPath, runID) {
    const scheme = `Safari UI Tests ${options.platform === "macos" ? "macOS" : "iOS"}`;
    const destination = options.platform === "ios" && options.phase === "build"
        ? "generic/platform=iOS Simulator" : options.destination;
    const base = ["-project", "Wallet.xcodeproj", "-scheme", scheme, "-configuration", options.configuration, "-destination", destination,
        ...signingSettings(options), "BW_SAFARI_VM_TESTING=YES", `BW_SAFARI_VM_CONFIGURATION=${descriptorPath}`,
        `BW_TEST_VM_RUN_ID=${runID}`, "BW_TEST_VM_EXCHANGE=/Volumes/BigWalletBuild/Exchange",
        `SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) BW_SAFARI_VM_TESTING${options.configuration === "Debug" ? " DEBUG" : ""}`];
    const settings = [...base];
    settings[settings.indexOf("-scheme") + 1] = options.platform === "macos" ? "Wallet" : "Wallet iOS";
    const timeouts = options.phase === "test" ? safariTestTimeouts(options.iterations) : null;
    return {
        base,
        settings: ["-showBuildSettings", "-json", ...settings],
        build: ["-jobs", "2", "build-for-testing", ...base, "ENABLE_TESTABILITY=YES"],
        test: timeouts && {
            args: ["-jobs", "2", "test-without-building", ...base,
                "-parallel-testing-enabled", "NO", "-enableCodeCoverage", "NO", "-collect-test-diagnostics", "never",
                ...timeouts.args, "-resultBundlePath", options.resultBundle,
                ...options.onlyTesting.map(value => `-only-testing:${value}`)],
            timeoutSeconds: timeouts.timeoutSeconds,
        },
    };
}

function validateFixtureRoot(root) {
    if (!/^\/Volumes\/BigWalletBuild\/Exchange\/[A-Za-z0-9._-]+\/safari\/macos\/(Debug|Release)$/.test(root) || root.includes("..")) { throw new Error("Invalid fixture entitlement root"); }
}

export function appleFixtureEntitlements(original, root) {
    validateFixtureRoot(root);
    if (!original || typeof original !== "object" || Array.isArray(original) || original["com.apple.security.app-sandbox"] !== true) {
        throw new Error("Apple Safari fixture signing requires original sandbox entitlements");
    }
    const key = "com.apple.security.temporary-exception.files.absolute-path.read-write";
    const existing = original[key] ?? [];
    if (!Array.isArray(existing) || existing.some(path => typeof path !== "string")) { throw new Error("Invalid original filesystem entitlements"); }
    return {...structuredClone(original), [key]: [...new Set([...existing, `${root}/`])]};
}

export function extensionEntitlements(root) {
    validateFixtureRoot(root);
    return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.network.client</key><true/>
<key>com.apple.security.temporary-exception.apple-events</key><array><string>org.lil.wallet.ambient</string></array>
<key>com.apple.security.temporary-exception.files.absolute-path.read-write</key><array><string>${root}/</string></array>
</dict></plist>\n`;
}

async function signLocalMacFixtureProducts(paths, root, command = execute, entitlementsDirectory = root) {
    const entitlements = join(entitlementsDirectory, "SafariVM.entitlements");
    await writeFile(entitlements, extensionEntitlements(root), {mode: 0o600});
    await command("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements", entitlements, paths.extension]);
    await command("/usr/bin/codesign", ["--force", "--sign", "-", paths.app]);
    await command("/usr/bin/codesign", ["--verify", "--deep", "--strict", paths.app]);
}

async function products(settingsArgs, options) {
    const settings = JSON.parse(await execute("xcodebuild", settingsArgs, {capture: true}));
    const target = options.platform === "macos" ? "Big Wallet" : "Big Wallet iOS";
    const app = settings.find(value => value.target === target)?.buildSettings;
    if (!app?.TARGET_BUILD_DIR || app.FULL_PRODUCT_NAME !== "Big Wallet.app") { throw new Error("Safari app build settings unavailable"); }
    const path = join(app.TARGET_BUILD_DIR, app.FULL_PRODUCT_NAME);
    if (!path.includes("/Library/Developer/Xcode/DerivedData/")) { throw new Error("Safari test app must use default DerivedData"); }
    const extension = join(path, options.platform === "macos" ? "Contents/PlugIns/Safari macOS.appex" : "PlugIns/Safari iOS.appex");
    return {app: path, extension, ...(options.platform === "macos" ? {helper: join(extension, "Contents/Helpers/Big Wallet.app")} : {})};
}

async function verifyFixtureProducts(paths, platform, descriptor) {
    for (const bundle of [paths.app, paths.extension, ...(paths.helper ? [paths.helper] : [])]) {
        const resources = platform === "macos" ? join(bundle, "Contents/Resources") : bundle;
        const marker = JSON.parse(await readFile(join(resources, "SafariVMRun.json"), "utf8"));
        if (!isDeepStrictEqual(marker, descriptor)) { throw new Error("Safari product is missing its current VM fixture marker"); }
    }
}

export async function readExtensionMetadata(bundle, platform, command = execute) {
    const infoPath = join(bundle, platform === "macos" ? "Contents/Info.plist" : "Info.plist");
    const info = JSON.parse(await command("/usr/bin/plutil", ["-convert", "json", "-o", "-", infoPath],
        {capture: true, maximumBytes: 65536, timeoutSeconds: 15}));
    const bounded = value => typeof value === "string" && value.trim().length > 0 && value.length <= 256 && !/[\u0000-\u001f\u007f]/.test(value);
    if (info?.CFBundleIdentifier !== "org.lil.wallet.Safari" || !bounded(info.CFBundleShortVersionString) || !bounded(info.CFBundleVersion)) {
        throw new Error("Safari extension bundle identity or version metadata is invalid");
    }
    return {bundleIdentifier: info.CFBundleIdentifier, version: info.CFBundleShortVersionString, build: info.CFBundleVersion,
        ...(bounded(info.CFBundleName) ? {name: info.CFBundleName} : {}),
        ...(bounded(info.CFBundleDisplayName) ? {displayName: info.CFBundleDisplayName} : {}),
        ...(bounded(info.NSExtension?.NSExtensionPointIdentifier) ? {extensionPointIdentifier: info.NSExtension.NSExtensionPointIdentifier} : {})};
}

export async function readMacOSRuntime(command = execute) {
    const version = (await command("/usr/bin/sw_vers", ["-productVersion"], {capture: true, maximumBytes: 1024, timeoutSeconds: 15})).trim();
    const build = (await command("/usr/bin/sw_vers", ["-buildVersion"], {capture: true, maximumBytes: 1024, timeoutSeconds: 15})).trim();
    if (version.length > 128 || !/^\d+(?:\.\d+){0,3}$/.test(version) || !/^[A-Za-z0-9]{1,128}$/.test(build)) {
        throw new Error("Guest macOS runtime metadata is invalid");
    }
    return {macOS: {version, build}};
}

export async function signAppleFixtureProducts(paths, root, scratch, command = execute) {
    validateFixtureRoot(root);
    const signingDirectory = join(scratch, "apple-fixture-signing");
    await privateDirectory(signingDirectory);
    await command("/usr/bin/codesign", ["--verify", "--deep", "--strict", paths.app]);
    const products = [];
    for (const role of ["helper", "extension", "app"]) {
        const bundle = paths[role];
        if (typeof bundle !== "string") { throw new Error(`Missing signed Safari ${role}`); }
        const prefix = join(signingDirectory, `${role}-certificate-`);
        const originalPath = join(signingDirectory, `${role}-original.plist`);
        await command("/usr/bin/codesign", ["--display", "--entitlements", originalPath, "--xml", "--extract-certificates", prefix, bundle]);
        const certificate = await readFile(`${prefix}0`);
        if (!certificate.length || certificate.length > 1024 * 1024) { throw new Error("Invalid original Apple signing certificate"); }
        const identity = createHash("sha1").update(certificate).digest("hex").toUpperCase();
        const original = JSON.parse(await command("/usr/bin/plutil", ["-convert", "json", "-o", "-", originalPath], {capture: true}));
        const entitlements = appleFixtureEntitlements(original, root);
        const entitlementsPath = join(signingDirectory, `${role}-fixture.plist`);
        await writeFile(entitlementsPath, JSON.stringify(entitlements), {mode: 0o600, flag: "wx"});
        await command("/usr/bin/plutil", ["-convert", "xml1", entitlementsPath]);
        products.push({role, bundle, identity, entitlementsPath, entitlements});
    }
    for (const product of products) {
        await command("/usr/bin/codesign", ["--force", "--sign", product.identity,
            "--preserve-metadata=identifier,requirements,flags,runtime,launch-constraints,library-constraints",
            "--entitlements", product.entitlementsPath, "--timestamp=none", product.bundle]);
        const verifiedPath = join(signingDirectory, `${product.role}-verified.plist`);
        const verifiedPrefix = join(signingDirectory, `${product.role}-verified-certificate-`);
        await command("/usr/bin/codesign", ["--display", "--entitlements", verifiedPath, "--xml", "--extract-certificates", verifiedPrefix, product.bundle]);
        const verifiedIdentity = createHash("sha1").update(await readFile(`${verifiedPrefix}0`)).digest("hex").toUpperCase();
        const verifiedEntitlements = JSON.parse(await command("/usr/bin/plutil", ["-convert", "json", "-o", "-", verifiedPath], {capture: true}));
        if (verifiedIdentity !== product.identity || !isDeepStrictEqual(verifiedEntitlements, product.entitlements)) {
            throw new Error("Apple fixture signing did not preserve its original identity and entitlements");
        }
    }
    await command("/usr/bin/codesign", ["--verify", "--deep", "--strict", paths.app]);
    return {mode: "apple", policy: "production-entitlements-with-fixture-file-access", fixtureAccessRoot: `${root}/`,
        originalIdentitiesPreserved: true, originalEntitlementsPreserved: true,
        products: products.map(({role, identity}) => ({role, identity}))};
}

async function executablePaths(bundles, platform, command = execute) {
    const paths = new Set();
    for (const bundle of bundles) {
        const contents = platform === "macos" ? join(bundle, "Contents") : bundle;
        const name = (await command("/usr/bin/plutil", ["-extract", "CFBundleExecutable", "raw", "-o", "-", join(contents, "Info.plist")], {capture: true})).trim();
        if (!name || name.includes("/") || name === "." || name === "..") { throw new Error("Invalid Safari product executable name"); }
        const path = join(contents, ...(platform === "macos" ? ["MacOS"] : []), name);
        paths.add(path);
        paths.add(await realpath(path));
    }
    return [...paths];
}

export async function removeHostedUnitTestBundle(products, platform) {
    if (platform !== "ios") { return; }
    const bundle = join(products.app, "PlugIns", "Tests iOS.xctest");
    await rm(bundle, {recursive: true, force: true});
    await rm(`${bundle}.dSYM`, {recursive: true, force: true});
}

export async function verifySynchronizationHookExclusion(products, platform, command = execute) {
    if (!["ios", "macos"].includes(platform)) { throw new Error("Invalid Safari product platform"); }
    const bundles = [products.app, products.extension, ...(products.helper ? [products.helper] : [])];
    const required = new Set(await Promise.all((await executablePaths(bundles, platform, command)).map(path => realpath(path))));
    const roots = [...new Set(await Promise.all(bundles.map(path => realpath(path))))];
    const magic = new Set([0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe, 0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca]);
    const marker = Buffer.from("BWSafariSynchronization");
    const visited = new Set(), executables = [];
    let entries = 0, codeBytes = 0;
    const visit = async (path, root, depth = 0) => {
        if (visited.has(path)) { return; }
        visited.add(path);
        if (++entries > 20000 || depth > 32) { throw new Error("Safari product code inspection exceeded its traversal limit"); }
        const info = await lstat(path);
        if (info.isSymbolicLink()) {
            const target = await realpath(path);
            if (target !== root && !target.startsWith(root + "/")) { throw new Error("Safari product symlink escapes its bundle: " + path); }
            return;
        }
        if (info.isDirectory()) {
            for (const name of (await readdir(path)).sort()) { await visit(join(path, name), root, depth + 1); }
            return;
        }
        if (!info.isFile()) { throw new Error("Safari product contains an unsupported file: " + path); }
        const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
        try {
            const opened = await file.stat();
            if (!opened.isFile() || opened.dev !== info.dev || opened.ino !== info.ino || opened.size !== info.size) {
                throw new Error("Safari product changed during code inspection: " + path);
            }
            const header = Buffer.alloc(4);
            const {bytesRead} = await file.read(header, 0, header.length, 0);
            if (bytesRead !== 4 || !magic.has(header.readUInt32BE(0))) {
                if (required.has(path)) { throw new Error("Safari product executable is not Mach-O: " + path); }
                return;
            }
            codeBytes += opened.size;
            if (opened.size > 512 * 1024 * 1024 || codeBytes > 2 * 1024 * 1024 * 1024) {
                throw new Error("Safari product code inspection exceeded its byte limit");
            }
            const chunk = Buffer.alloc(64 * 1024);
            let offset = 0, tail = Buffer.alloc(0);
            while (offset < opened.size) {
                const {bytesRead} = await file.read(chunk, 0, Math.min(chunk.length, opened.size - offset), offset);
                if (!bytesRead) { throw new Error("Safari product changed during code inspection: " + path); }
                const content = Buffer.concat([tail, chunk.subarray(0, bytesRead)]);
                if (content.includes(marker)) {
                    throw new Error("Safari synchronization hook must not be linked into wallet or extension products: " + path);
                }
                tail = Buffer.from(content.subarray(Math.max(0, content.length - marker.length + 1)));
                offset += bytesRead;
            }
            executables.push(path);
        } finally {
            await file.close();
        }
    };
    for (const root of roots) {
        if (!(await lstat(root)).isDirectory()) { throw new Error("Safari product bundle is not a directory: " + root); }
        await visit(root, root);
    }
    if ([...required].some(path => !executables.includes(path))) { throw new Error("Safari product executable was not inspected"); }
    return {status: "passed", executables};
}

export function safariDiagnosticPredicate(platform, allowedExecutables = []) {
    const runner = `Safari UI Tests ${platform === "macos" ? "macOS" : "iOS"}-Runner`;
    const bundle = `org.lil.wallet.safari-ui-tests.${platform}`;
    const paths = [...new Set(allowedExecutables)].filter(path => typeof path === "string" && path.startsWith("/")).slice(0, 12);
    const bundlePaths = [...new Set(paths.map(path => /^(.*(?:\.app|\.appex))\//.exec(path)?.[1]).filter(Boolean))];
    const extensionPaths = [...new Set(paths.map(path => /^(.+?\.appex)\//.exec(path)?.[1]).filter(Boolean))];
    const extensionReferences = ["org.lil.wallet.Safari", ...extensionPaths].map(value => `eventMessage CONTAINS ${JSON.stringify(value)}`).join(" OR ");
    const products = [`process == ${JSON.stringify(runner)}`, ...paths.map(path => `processImagePath == ${JSON.stringify(path)}`)].join(" OR ");
    const references = [...new Set([bundle, runner, "org.lil.wallet.Safari", ...paths, ...bundlePaths, ...extensionPaths])]
        .map(value => `eventMessage CONTAINS ${JSON.stringify(value)}`).join(" OR ");
    const security = '(eventMessage CONTAINS[c] "sandbox" OR eventMessage CONTAINS[c] "automation" OR eventMessage CONTAINS[c] "authoriz" OR eventMessage CONTAINS[c] "denied" OR subsystem BEGINSWITH "com.apple.TCC" OR subsystem BEGINSWITH "com.apple.dt")';
    const registrars = ["pkd", "lsd", platform === "macos" ? "Safari" : "MobileSafari"].map(value => `process == ${JSON.stringify(value)}`).join(" OR ");
    const browserExtensions = `(process == ${JSON.stringify(platform === "macos" ? "Safari" : "MobileSafari")} AND subsystem == "com.apple.Safari" AND category == "Extensions")`;
    return `((${products}) AND ${security}) OR ((process == "sandboxd" OR process == "tccd" OR process == "testmanagerd" OR process == "testmanagerd_sim" OR process == "CoreSimulatorService") AND (${references})) OR ((${registrars}) AND (${extensionReferences})) OR ${browserExtensions}`;
}

export function redactSafariDiagnostics(output, secrets = []) {
    let result = String(output);
    for (const secret of secrets) {
        if (typeof secret === "string" && secret.length >= 8) { result = result.split(secret).join("[REDACTED]"); }
    }
    return result.replace(/\bBearer\s+[^\s"',;]+/gi, "Bearer [REDACTED]")
        .replace(/(X-Big-Wallet-Test-Token["'\s:=]+)[^\s"',;]+/gi, "$1[REDACTED]");
}

export async function collectSafariDiagnostics({server, platform, artifacts, stageId, startedAt, interrupted = false}, command = execute) {
    const duration = Math.min(21720, Math.max(1, Math.ceil((Date.now() - startedAt) / 1000) + 60));
    const args = ["show", "--style", "compact", "--no-pager", "--info", "--debug", "--last", `${duration}s`,
        "--predicate", safariDiagnosticPredicate(platform, server.allowedExecutables)];
    let output;
    let error;
    try {
        output = await command("/usr/bin/log", args, {capture: true, captureStderr: true, maximumBytes: maximumCapturedBytes,
            timeoutSeconds: interrupted ? 1 : 60, ...(interrupted ? {terminationGraceMilliseconds: 100, outputDrainMilliseconds: 100} : {})});
    } catch (failure) { error = failure; output = failure.output ?? ""; }
    const secrets = [server.token, server.pageToken, process.env.ALCHEMY_JWT_REQUEST_PROOF_KEY];
    const contents = Buffer.from(redactSafariDiagnostics(output, secrets)).subarray(0, maximumCapturedBytes);
    const artifact = `${stageId}.safari-diagnostics.log`;
    await writeFile(join(artifacts, artifact), contents, {mode: 0o600, flag: "wx"});
    return {status: error ? "incomplete" : "collected", artifact, bytes: contents.length,
        ...(error ? {reason: redactSafariDiagnostics(error.message, secrets), truncated: error.truncated === true, timedOut: error.timedOut === true} : {})};
}

export async function collectSafariRegistration({artifacts, stageId, phase, interrupted = false}, command = execute) {
    if (!["registered", "refreshed", "failure"].includes(phase)) { throw new Error("Invalid Safari registration diagnostic phase"); }
    let output;
    let error;
    try {
        output = await command("/usr/bin/pluginkit", ["-m", "-A", "-D", "-vv", "-i", "org.lil.wallet.Safari"],
            {capture: true, captureStderr: true, maximumBytes: 1024 * 1024, timeoutSeconds: interrupted ? 1 : 15,
                ...(interrupted ? {terminationGraceMilliseconds: 100, outputDrainMilliseconds: 100} : {})});
    } catch (failure) { error = failure; output = failure.output ?? ""; }
    const contents = Buffer.from(redactSafariDiagnostics(output, [process.env.ALCHEMY_JWT_REQUEST_PROOF_KEY])).subarray(0, 1024 * 1024);
    const artifact = `${stageId}.safari-registration-${phase}.log`;
    if (phase === "refreshed") {
        const temporary = join(artifacts, `${artifact}.${randomUUID()}.tmp`);
        try {
            await writeFile(temporary, contents, {mode: 0o600, flag: "wx"});
            await rename(temporary, join(artifacts, artifact));
        } finally { await rm(temporary, {force: true}); }
    } else { await writeFile(join(artifacts, artifact), contents, {mode: 0o600, flag: "wx"}); }
    return {status: error ? "incomplete" : "collected", artifact, bytes: contents.length,
        ...(error ? {reason: redactSafariDiagnostics(error.message, [process.env.ALCHEMY_JWT_REQUEST_PROOF_KEY]),
            truncated: error.truncated === true, timedOut: error.timedOut === true} : {})};
}

function validateMacFixtureProducts(products) {
    if (typeof products?.app !== "string" || !products.app.startsWith("/") || !products.app.endsWith("/Big Wallet.app") ||
        products.extension !== join(products.app, "Contents/PlugIns/Safari macOS.appex") ||
        products.helper !== join(products.extension, "Contents/Helpers/Big Wallet.app") ||
        [products.app, products.extension, products.helper].some(path => resolve(path) !== path || path.length > 4096 || /[\u0000-\u001f\u007f]/.test(path))) {
        throw new Error("Missing verified Safari fixture products");
    }
}

export function safariMacInstallation(descriptor, stageId, home = userInfo().homedir) {
    validateFixtureRoot(descriptor?.root ?? "");
    const configuration = descriptor?.configuration?.toLowerCase();
    const stages = ["safari.macos." + configuration, ...(descriptor?.configuration === "Release" ? ["safari.soak-macos.release"] : [])];
    if (descriptor.platform !== "macos" || descriptor.version !== 1 ||
        !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(descriptor.runID ?? "") || descriptor.runID.includes("..") ||
        descriptor.root !== "/Volumes/BigWalletBuild/Exchange/" + descriptor.runID + "/safari/macos/" + descriptor.configuration ||
        !["Debug", "Release"].includes(descriptor.configuration) || !stages.includes(stageId) ||
        typeof home !== "string" || !home.startsWith("/") || resolve(home) !== home || home.length > 2048 || /[\u0000-\u001f\u007f]/.test(home)) {
        throw new Error("Invalid Safari guest installation identity");
    }
    return {home, directory: join(home, "Applications/BigWalletSafariVM", descriptor.runID, stageId),
        stageId, created: false};
}

export function safariPreparedInstallation(descriptor, stageId, home, reference = null) {
    safariMacInstallation(descriptor, `safari.macos.${descriptor?.configuration?.toLowerCase()}`, home);
    if (descriptor.signingMode !== "local" ||
        !["prepare-safari.macos.debug", "safari.macos.debug", "safari.macos.release", "safari.soak-macos.release"].includes(stageId)) {
        throw new Error("Invalid prepared Safari installation identity");
    }
    if (reference) { validatePreparedSafariReference(reference); }
    return {home, directory: join(home, "Applications/BigWalletSafariVM/Prepared"), stageId, created: false,
        prepared: true, preparationRunID: reference?.preparationRunID ?? descriptor.runID, reference};
}

async function privateJSON(path, maximum = 65536) {
    const info = await lstat(path);
    if (!info.isFile() || info.isSymbolicLink() || info.uid !== process.getuid() || info.nlink !== 1 ||
        (info.mode & 0o7777) !== 0o600 || info.size > maximum) {
        throw new Error("Prepared Safari metadata must be a bounded private owned file");
    }
    const bytes = await readFile(path);
    return {value: JSON.parse(bytes.toString("utf8")), bytes};
}

export async function safariProductSignatures(paths, command = execute) {
    await command("/usr/bin/codesign", ["--verify", "--deep", "--strict", paths.app], {capture: true, captureStderr: true, timeoutSeconds: 30});
    const signatures = {};
    for (const [role, identifier] of [["app", "org.lil.wallet"], ["extension", "org.lil.wallet.Safari"], ["helper", "org.lil.wallet.ambient"]]) {
        const output = await command("/usr/bin/codesign", ["--display", "--verbose=4", paths[role]], {
            capture: true, captureStderr: true, maximumBytes: 65536, timeoutSeconds: 15,
        });
        const cdhash = /^CDHash=([a-f0-9]{40})$/m.exec(output)?.[1];
        if (!cdhash || !output.includes(`Identifier=${identifier}\n`) || !/^Signature=adhoc$/m.test(output) ||
            !/^TeamIdentifier=not set$/m.test(output)) { throw new Error(`Invalid prepared Safari ${role} signature identity`); }
        signatures[role] = {identifier, cdhash};
    }
    return signatures;
}

export async function readPreparedSafariReceipt(installation) {
    const {value, bytes} = await privateJSON(join(installation.directory, ".safari-prepared.json"));
    const receiptSHA256 = createHash("sha256").update(bytes).digest("hex");
    if (!installation.reference || receiptSHA256 !== installation.reference.receiptSHA256 ||
        value?.version !== 1 || value.status !== "passed" || value.preparationRunID !== installation.reference.preparationRunID ||
        value.installationDirectory !== installation.directory || value.descriptor?.runID !== value.preparationRunID ||
        value.descriptor.platform !== "macos" || value.descriptor.signingMode !== "local" ||
        value.descriptor.configuration !== "Debug" || value.enabledObservation?.enabled !== true || value.cleanup?.status !== "passed") {
        throw new Error("Prepared Safari seed receipt does not match the selected baseline");
    }
    return {receipt: value, receiptSHA256};
}

export async function assertPreparedProductsStopped(paths, command = execute) {
    const output = await command("/bin/ps", ["-ww", "-axo", "pid=,comm="], {
        capture: true, captureStderr: true, maximumBytes: 1024 * 1024, timeoutSeconds: 15,
    });
    const executables = new Set([
        join(paths.app, "Contents/MacOS/Big Wallet"), join(paths.extension, "Contents/MacOS/Safari macOS"),
        join(paths.helper, "Contents/MacOS/Big Wallet"),
    ]);
    for (const line of output.split("\n").filter(line => line.trim())) {
        const match = /^\s*(\d+)\s+(.+?)\s*$/.exec(line);
        if (!match) { throw new Error("Could not verify prepared Safari process inventory"); }
        const executable = match[2];
        if (executables.has(executable) || executable.startsWith(paths.app + "/") ||
            !executable.startsWith("/") && ["Big Wallet", "Safari macOS"].includes(executable)) {
            throw new Error("A prepared Safari product is still running; stop it before replacing the installation");
        }
    }
}

async function verifyInstallationDirectory(path, privateMode = true) {
    const info = await lstat(path);
    if (!info.isDirectory() || info.isSymbolicLink() || info.uid !== process.getuid() ||
        info.mode & (privateMode ? 0o077 : 0o022) || await realpath(path) !== path) {
        throw new Error("Safari installation directory is not private, real, and owned");
    }
}

function installationMarker(descriptor, installation) {
    const expected = installation.prepared
        ? safariPreparedInstallation(descriptor, installation.stageId, installation.home, installation.reference)
        : safariMacInstallation(descriptor, installation.stageId, installation.home);
    if (installation.directory !== expected.directory) { throw new Error("Safari installation directory changed"); }
    return {version: 1, runID: descriptor.runID, stageId: installation.stageId, configuration: descriptor.configuration,
        fixtureRoot: descriptor.root, ...(installation.prepared ? {mode: "prepared", preparationRunID: installation.preparationRunID} : {})};
}

async function verifySafariMacInstallation(descriptor, installation) {
    const expected = installationMarker(descriptor, installation);
    await verifyInstallationDirectory(installation.home, false);
    await verifyInstallationDirectory(join(installation.home, "Applications"), false);
    for (const directory of new Set([join(installation.home, "Applications/BigWalletSafariVM"),
        dirname(installation.directory), installation.directory])) { await verifyInstallationDirectory(directory); }
    const path = join(installation.directory, ".safari-vm-installation.json");
    const info = await lstat(path);
    if (!info.isFile() || info.isSymbolicLink() || info.uid !== process.getuid() || info.nlink !== 1 ||
        (info.mode & 0o7777) !== 0o600 || info.size > 16384 ||
        !isDeepStrictEqual(JSON.parse(await readFile(path, "utf8")), expected)) {
        throw new Error("Safari installation ownership marker changed");
    }
}

export async function installSafariMacProducts({products, descriptor, installation, replace = false}, command = execute) {
    validateMacFixtureProducts(products);
    if (!products.app.includes("/Library/Developer/Xcode/DerivedData/")) { throw new Error("Safari installation source must be the default DerivedData build"); }
    await verifyFixtureProducts(products, "macos", descriptor);
    const marker = installationMarker(descriptor, installation);
    await verifyInstallationDirectory(installation.home, false);
    const applications = join(installation.home, "Applications");
    try { await mkdir(applications, {mode: 0o700}); } catch (error) { if (error.code !== "EEXIST") { throw error; } }
    await verifyInstallationDirectory(applications, false);
    for (const directory of new Set([join(applications, "BigWalletSafariVM"), dirname(installation.directory)])) {
        try { await mkdir(directory, {mode: 0o700}); } catch (error) { if (error.code !== "EEXIST") { throw error; } }
        await verifyInstallationDirectory(directory);
    }
    let previousDescriptor = descriptor;
    let takeover = false;
    let previousSeed;
    if (installation.prepared && !replace && !installation.reference) {
        try {
            await verifyInstallationDirectory(installation.directory);
            const saved = await privateJSON(join(installation.directory, ".safari-prepared.json"));
            const reference = {preparationRunID: saved.value?.preparationRunID, receiptSHA256: createHash("sha256").update(saved.bytes).digest("hex")};
            validatePreparedSafariReference(reference);
            previousSeed = {...installation, reference, preparationRunID: reference.preparationRunID};
        } catch (error) {
            if (error.code !== "ENOENT") { throw error; }
            if (await lstat(installation.directory).then(() => true, error => error.code === "ENOENT" ? false : Promise.reject(error))) {
                throw new Error("An incomplete prepared Safari installation must be recovered through candidate setup");
            }
        }
    }
    if (installation.prepared && !replace && (installation.reference || previousSeed)) {
        await verifyInstallationDirectory(installation.directory);
        const previousOwner = previousSeed ?? installation;
        const {receipt} = await readPreparedSafariReceipt(previousOwner);
        const {value: previous} = await privateJSON(join(installation.directory, ".safari-vm-installation.json"));
        if (previous.mode !== "prepared" || previous.preparationRunID !== previousOwner.preparationRunID ||
            ![previousOwner.preparationRunID, descriptor.runID].includes(previous.runID) ||
            !["Debug", "Release"].includes(previous.configuration) ||
            previous.fixtureRoot !== `/Volumes/BigWalletBuild/Exchange/${previous.runID}/safari/macos/${previous.configuration}` ||
            previousSeed && (previous.stageId !== "prepare-safari.macos.debug" || previous.configuration !== "Debug" ||
                previous.runID !== previousOwner.preparationRunID)) {
            throw new Error("Prepared Safari installation ownership does not match its seed or current run");
        }
        previousDescriptor = {version: 1, runID: previous.runID, root: previous.fixtureRoot, platform: "macos",
            signingMode: "local", configuration: previous.configuration};
        await verifySafariMacInstallation(previousDescriptor, {...previousOwner, stageId: previous.stageId});
        const previousPaths = macInstalledPaths(products, installation);
        await verifyFixtureProducts(previousPaths, "macos", previousDescriptor);
        const signatures = await safariProductSignatures(previousPaths, command);
        if (previous.runID === previousOwner.preparationRunID && !isDeepStrictEqual(signatures, receipt.signatures)) {
            throw new Error("Prepared Safari seed products changed before installation takeover");
        }
        await assertPreparedProductsStopped(previousPaths, command);
        takeover = true;
        installation.created = true;
    } else if (replace) {
        if (!installation.created) { throw new Error("Safari replacement requires the current owned installation"); }
        await verifySafariMacInstallation(descriptor, installation);
    } else {
        await mkdir(installation.directory, {mode: 0o700});
        installation.created = true;
        await writeFile(join(installation.directory, ".safari-vm-installation.json"), JSON.stringify(marker), {mode: 0o600, flag: "wx"});
    }
    const paths = macInstalledPaths(products, installation);
    const {app} = paths;
    if (replace || takeover) {
        await verifyFixtureProducts(paths, "macos", previousDescriptor);
        await rm(app, {recursive: true});
    }
    await command("/usr/bin/ditto", ["--rsrc", "--extattr", "--acl", products.app, app],
        {capture: true, captureStderr: true, maximumBytes: 1024 * 1024, timeoutSeconds: 120});
    if (takeover) { await atomicJSON(join(installation.directory, ".safari-vm-installation.json"), marker); }
    await verifySafariMacInstallation(descriptor, installation);
    await verifyFixtureProducts(paths, "macos", descriptor);
    await command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app],
        {capture: true, captureStderr: true, maximumBytes: 64 * 1024, timeoutSeconds: 60});
    if (previousSeed) { await rm(join(installation.directory, ".safari-prepared.json")); }
    return paths;
}

function macInstalledPaths(products, installation) {
    const app = join(installation.directory, "Big Wallet.app");
    const extension = join(app, "Contents/PlugIns/Safari macOS.appex");
    return {...products, app, extension, helper: join(extension, "Contents/Helpers/Big Wallet.app"),
        sourceApp: products.app, installationDirectory: installation.directory};
}

export async function removeSafariMacInstallation({descriptor, installation}) {
    if (!installation?.created) { return {status: "not-created"}; }
    try {
        await verifySafariMacInstallation(descriptor, installation);
        await rm(installation.directory, {recursive: true});
        return {status: "passed", directory: installation.directory};
    } catch (error) {
        return {status: "failed", directory: installation.directory, reason: String(error.message).slice(0, 4096)};
    }
}

export async function refreshSafariExtensionRegistration({products, sourceProducts, descriptor, artifacts, stageId}, command = execute) {
    if (descriptor?.platform !== "macos" || descriptor.signingMode !== "local") {
        throw new Error("Safari registration refresh requires the local macOS fixture");
    }
    validateMacFixtureProducts(products);
    validateMacFixtureProducts(sourceProducts);
    if (products.extension === sourceProducts.extension) { throw new Error("Safari registration requires a distinct installed copy"); }
    await verifyFixtureProducts(products, "macos", descriptor);
    await verifyFixtureProducts(sourceProducts, "macos", descriptor);
    let failure;
    let registeredAt;
    let deregistration;
    try {
        deregistration = await removeSafariRegistration(sourceProducts.extension, {}, command);
        await command("/usr/bin/pluginkit", ["-a", products.extension], {capture: true, captureStderr: true, maximumBytes: 64 * 1024, timeoutSeconds: 15});
        registeredAt = new Date().toISOString();
    } catch (error) { failure = error; }
    try { await collectSafariRegistration({artifacts, stageId, phase: "refreshed"}, command); }
    catch (error) { failure ??= error; }
    if (failure) { throw failure; }
    return {registeredAt, extension: products.extension, deregisteredExtension: deregistration.extension,
        ...(deregistration.alreadyAbsent ? {deregistrationAlreadyAbsent: true} : {})};
}

export async function rebuildSafariMacProducts({products, sourceProducts, descriptor, installation, buildArgs, artifacts, stageId,
    deadline = Date.now() + 150000, beforeReplace = async () => {}}, command = execute) {
    if (!Number.isFinite(deadline) || deadline <= Date.now() || deadline > Date.now() + 150000) {
        throw new Error("Invalid Safari rebuild deadline");
    }
    const boundedCommand = (executable, args, options = {}) => {
        const remaining = (deadline - Date.now()) / 1000;
        if (remaining <= 0) { throw new Error("Safari rebuild exceeded its overall deadline"); }
        return command(executable, args, {...options, timeoutSeconds: Math.min(options.timeoutSeconds ?? commandTimeoutSeconds(executable, args), remaining)});
    };
    if (descriptor?.platform !== "macos" || descriptor.signingMode !== "local") {
        throw new Error("Safari rebuild requires the local macOS fixture");
    }
    validateMacFixtureProducts(products);
    validateMacFixtureProducts(sourceProducts);
    if (products.app !== join(installation.directory, "Big Wallet.app") || products.app === sourceProducts.app) {
        throw new Error("Safari rebuild requires its distinct owned installation");
    }
    await verifySafariMacInstallation(descriptor, installation);
    await verifyFixtureProducts(products, "macos", descriptor);
    await verifyFixtureProducts(sourceProducts, "macos", descriptor);
    const args = [...buildArgs];
    const scheme = args.indexOf("-scheme");
    if (scheme < 0 || args[scheme + 1] !== "Safari UI Tests macOS") { throw new Error("Invalid Safari rebuild scheme"); }
    args[scheme + 1] = "Wallet";
    await boundedCommand("xcodebuild", ["-jobs", "2", "build", ...args, "ENABLE_TESTABILITY=YES"], {timeoutSeconds: 120});
    await verifyFixtureProducts(sourceProducts, "macos", descriptor);
    await signLocalMacFixtureProducts(sourceProducts, descriptor.root, boundedCommand, installation.directory);
    await beforeReplace();
    if (Date.now() >= deadline) { throw new Error("Safari rebuild exceeded its overall deadline"); }
    await installSafariMacProducts({products: sourceProducts, descriptor, installation, replace: true}, boundedCommand);
    const registration = await refreshSafariExtensionRegistration({products, sourceProducts, descriptor, artifacts, stageId}, boundedCommand);
    return {...registration, rebuiltAt: new Date().toISOString(), workaround: "macOS-27-183044008"};
}

export async function collectSafariCodeSigning({products, artifacts, stageId, phase, secrets = [], interrupted = false}, command = execute) {
    if (!["before-tests", "failure"].includes(phase)) { throw new Error("Invalid Safari code-signing diagnostic phase"); }
    validateMacFixtureProducts(products);
    const maximumBytes = 64 * 1024;
    const redactions = [...secrets, process.env.ALCHEMY_JWT_REQUEST_PROOF_KEY];
    const bounded = (value, maximum = maximumBytes) => {
        const bytes = Buffer.from(redactSafariDiagnostics(value, redactions));
        let end = Math.min(bytes.length, maximum);
        while (end > 0 && end < bytes.length && (bytes[end] & 0xc0) === 0x80) { end -= 1; }
        return bytes.subarray(0, end).toString("utf8");
    };
    const report = {version: 1, stageId, phase, products: []};
    for (const role of ["app", "extension", "helper"]) {
        const bundle = products[role];
        const product = {role, bundle, probes: []};
        for (const [operation, flags] of [["verify", ["--verify", "--deep", "--strict"]],
            ["display", ["--display", "--verbose=4", "--entitlements", ":-"]]]) {
            const args = [...flags, bundle];
            let output;
            let error;
            try {
                output = await command("/usr/bin/codesign", args, {capture: true, captureStderr: true, maximumBytes,
                    timeoutSeconds: interrupted ? 1 : 15,
                    ...(interrupted ? {terminationGraceMilliseconds: 100, outputDrainMilliseconds: 100} : {})});
            } catch (failure) { error = failure; output = failure.output ?? ""; }
            const text = bounded(output);
            product.probes.push({operation, command: "/usr/bin/codesign", arguments: args, status: error ? "failed" : "passed", output: text,
                bytes: Buffer.byteLength(text), truncated: error?.truncated === true || Buffer.byteLength(String(output)) > maximumBytes,
                ...(error ? {reason: bounded(error.message, 4096), timedOut: error.timedOut === true, cancelled: error.cancelled === true} : {})});
        }
        report.products.push(product);
    }
    report.status = report.products.every(product => product.probes.every(probe => probe.status === "passed")) ? "collected" : "incomplete";
    const contents = Buffer.from(JSON.stringify(report, null, 2) + "\n");
    if (contents.length > 4 * 1024 * 1024) { throw new Error("Safari code-signing diagnostics exceeded their artifact limit"); }
    const artifact = `${stageId}.safari-code-signing-${phase}.json`;
    await writeFile(join(artifacts, artifact), contents, {mode: 0o600, flag: "wx"});
    return {status: report.status, artifact, bytes: contents.length};
}

async function removeSafariRegistration(extension, {interrupted = false}, command) {
    const resolvedExtension = await realpath(extension);
    try {
        const output = await command("/usr/bin/pluginkit", ["-r", resolvedExtension], {capture: true, captureStderr: true, maximumBytes: 64 * 1024,
            timeoutSeconds: interrupted ? 1 : 15,
            ...(interrupted ? {terminationGraceMilliseconds: 100, outputDrainMilliseconds: 100} : {})});
        return {output, exitCode: 0, alreadyAbsent: false, extension: resolvedExtension};
    } catch (error) {
        if (error.exitCode === 1 && error.signal === null && error.timedOut !== true && error.cancelled !== true &&
            error.truncated !== true && error.output === "remove: no plugin at " + resolvedExtension + "\n") {
            return {output: error.output, exitCode: 1, alreadyAbsent: true, extension: resolvedExtension};
        }
        throw Object.assign(error, {registrationPath: resolvedExtension});
    }
}

export async function deregisterSafariExtension({products, secrets = [], interrupted = false}, command = execute) {
    if (!products) { return {status: "unavailable", reason: "Fixture product identities were not verified before cleanup"}; }
    const redactions = [...secrets, process.env.ALCHEMY_JWT_REQUEST_PROOF_KEY];
    try { validateMacFixtureProducts(products); }
    catch (error) { return {status: "unavailable", reason: error.message}; }
    const args = ["-r", products.extension];
    const result = {status: "passed", extension: products.extension, command: "/usr/bin/pluginkit", arguments: args};
    let output;
    try {
        const removed = await removeSafariRegistration(products.extension, {interrupted}, command);
        output = removed.output;
        result.resolvedExtension = removed.extension;
        result.arguments = ["-r", removed.extension];
        result.exitCode = removed.exitCode;
        if (removed.alreadyAbsent) { result.alreadyAbsent = true; }
    } catch (error) {
        output = error.output ?? "";
        if (error.registrationPath) {
            result.resolvedExtension = error.registrationPath;
            result.arguments = ["-r", error.registrationPath];
        }
        Object.assign(result, {status: "failed", reason: redactSafariDiagnostics(error.message, redactions).slice(0, 4096),
            exitCode: error.exitCode ?? null, signal: error.signal ?? null,
            timedOut: error.timedOut === true, truncated: error.truncated === true, cancelled: error.cancelled === true});
    }
    const contents = Buffer.from(redactSafariDiagnostics(output, redactions)).subarray(0, 64 * 1024);
    if (contents.length) { result.output = contents.toString("utf8"); }
    result.bytes = contents.length;
    return result;
}

export async function finalizeSafariRun({server, descriptorPath, artifacts, stageId, platform, startedAt,
    primaryError, diagnosticProducts, sourceProducts, descriptor, installation, interrupted = false}, command = execute) {
    const report = {status: "passed", failures: []};
    const secrets = [server.token, server.pageToken, process.env.ALCHEMY_JWT_REQUEST_PROOF_KEY];
    if (primaryError) { report.primaryFailure = redactSafariDiagnostics(primaryError.message, secrets); }
    const attempt = async (operation, action) => {
        try { return await action(); }
        catch (error) {
            report.failures.push({operation, error: redactSafariDiagnostics(error.message, secrets)});
            return undefined;
        }
    };
    await attempt("descriptor", () => copyFile(descriptorPath, join(artifacts, `${stageId}.safari-run.json`)));
    if (primaryError) {
        await attempt("partial-evidence", async () => {
            try { await copyFile(join(artifacts, `${stageId}.safari.json`), join(artifacts, `${stageId}.safari-partial.json`)); }
            catch (error) { if (error.code !== "ENOENT") { throw error; } }
        });
    }
    const failuresBeforeCleanup = report.failures.length;
    await attempt("cleanup", () => server.close());
    const cleanupFailed = report.failures.length > failuresBeforeCleanup;
    const cleanupFailure = cleanupFailed ? report.failures.at(-1).error : undefined;
    if (cleanupFailed) { await attempt("partial-persistence", () => server.persist()); }
    if (primaryError || report.failures.length) {
        if (platform === "macos") {
            report.codeSigning = diagnosticProducts
                ? await attempt("code-signing-diagnostics", () => collectSafariCodeSigning({products: diagnosticProducts, artifacts, stageId, phase: "failure", secrets, interrupted}, command))
                : {status: "unavailable", reason: "Fixture product identities were not verified before failure"};
            report.registration = await attempt("registration-diagnostics", () => collectSafariRegistration({artifacts, stageId, phase: "failure", interrupted}, command));
        }
        report.diagnostics = await attempt("diagnostics", () => collectSafariDiagnostics({server, platform, artifacts, stageId, startedAt, interrupted}, command));
    }
    if (platform === "macos") {
        const preservePrepared = installation?.prepared === true;
        if (preservePrepared) {
            await attempt("prepared-installation-ownership", () => verifySafariMacInstallation(descriptor, installation));
        }
        const deregistration = preservePrepared
            ? {status: "retained", extension: diagnosticProducts?.extension, reason: "prepared-installation"}
            : await deregisterSafariExtension({products: diagnosticProducts, secrets, interrupted}, command);
        report.extensionDeregistration = deregistration;
        if (!["passed", "retained"].includes(deregistration.status)) {
            report.failures.push({operation: "extension-deregistration", error: deregistration.reason});
        }
        const buildDeregistration = await deregisterSafariExtension({products: sourceProducts, secrets, interrupted}, command);
        report.buildExtensionDeregistration = buildDeregistration;
        if (buildDeregistration.status !== "passed") {
            report.failures.push({operation: "build-extension-deregistration", error: buildDeregistration.reason});
        }
        const previous = server.cleanup ?? {};
        const previousFailure = cleanupFailed || previous.status !== "passed"
            ? previous.reason || cleanupFailure || "Safari process cleanup did not report success" : undefined;
        if (previousFailure && !cleanupFailed) { report.failures.push({operation: "cleanup", error: previousFailure}); }
        const installationRemoval = preservePrepared
            ? {status: "retained", directory: installation.directory, reason: "prepared-installation"}
            : installation?.created && previousFailure
            ? {status: "retained", directory: installation.directory, reason: previousFailure}
            : await removeSafariMacInstallation({descriptor, installation});
        report.installationRemoval = installationRemoval;
        if (installationRemoval.status === "failed") {
            report.failures.push({operation: "installation-removal", error: installationRemoval.reason});
        }
        server.cleanup = {...previous, status: !previousFailure && !report.failures.length && ["passed", "retained"].includes(deregistration.status) &&
            buildDeregistration.status === "passed" && ["passed", "not-created", ...(preservePrepared ? ["retained"] : [])].includes(installationRemoval.status) ? "passed" : "failed",
            extensionDeregistration: deregistration, buildExtensionDeregistration: buildDeregistration, installationRemoval};
        const reason = previous.reason || previousFailure || (!["passed", "retained"].includes(deregistration.status) ? deregistration.reason : undefined) ||
            (buildDeregistration.status !== "passed" ? buildDeregistration.reason : undefined) ||
            (installationRemoval.status === "failed" ? installationRemoval.reason : undefined);
        if (reason) { server.cleanup.reason = reason; }
        await attempt("cleanup-persistence", () => server.persist({nativeRecords: server.nativeReader?.failure ? server.nativeReader.records : undefined}));
    }
    if (report.failures.length) { report.status = "failed"; }
    await attempt("finalization-report", () => atomicJSON(join(artifacts, `${stageId}.safari-finalization.json`), report));
    if (primaryError) { throw primaryError; }
    if (report.failures.length) { throw new Error(`Safari finalization failed: ${report.failures.map(failure => `${failure.operation}: ${failure.error}`).join("; ")}`); }
}

async function installedIOSProducts(udid, descriptor, command = execute) {
    const app = (await command("xcrun", ["simctl", "get_app_container", udid, "org.lil.wallet", "app"], {capture: true})).trim();
    if (!app.startsWith("/") || !app.toLowerCase().includes(`/devices/${udid.toLowerCase()}/data/containers/bundle/application/`) || !app.endsWith("/Big Wallet.app")) {
        throw new Error("The installed wallet is outside the selected simulator container");
    }
    const paths = {app, extension: join(app, "PlugIns/Safari iOS.appex")};
    await verifyFixtureProducts(paths, "ios", descriptor);
    return {installedApp: app, allowedExecutables: await executablePaths([paths.app, paths.extension], "ios", command),
        extensionInfo: await readExtensionMetadata(paths.extension, "ios", command)};
}

export async function main(args = process.argv.slice(2)) {
    const options = parseArguments(args);
    const runID = process.env.BW_TEST_VM_RUN_ID;
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(runID || "") || runID.includes("..") || process.env.BW_TEST_VM_EXCHANGE !== "/Volumes/BigWalletBuild/Exchange") {
        throw new Error("Safari tests require an active VM job");
    }
    await execute("/bin/sh", ["-c", ". Scripts/vm/guest_session.sh; test_vm_require_guest_session"]);
    const root = `/Volumes/BigWalletBuild/Exchange/${runID}/safari/${options.platform}/${options.configuration}`;
    const descriptor = {version: 1, runID, root, platform: options.platform, signingMode: options.signing, configuration: options.configuration};
    const descriptorPath = join(root, "SafariVMRun.json");
    await privateDirectory(root);
    if (options.phase === "build") {
        await atomicJSON(descriptorPath, descriptor);
        await atomicJSON(join(root, ".run.json"), descriptor);
    } else {
        if (JSON.stringify(JSON.parse(await readFile(descriptorPath, "utf8"))) !== JSON.stringify(descriptor)) { throw new Error("Safari build/run descriptor mismatch"); }
    }
    const commands = safariXcodeCommands(options, descriptorPath, runID);
    const buildArgs = commands.base;
    if (options.phase === "build") {
        const paths = await products(commands.settings, options);
        await removeHostedUnitTestBundle(paths, options.platform);
        await execute("xcodebuild", commands.build);
        await access(paths.extension);
        await verifyFixtureProducts(paths, options.platform, descriptor);
        paths.synchronizationHookExclusion = await verifySynchronizationHookExclusion(paths, options.platform);
        if (options.platform === "macos" && options.signing === "local") {
            await signLocalMacFixtureProducts(paths, root);
        }
        paths.signingCoverage = options.platform === "macos" && options.signing === "apple"
            ? await signAppleFixtureProducts(paths, root, options.scratch)
            : {mode: options.signing, policy: options.signing === "local" ? "credential-free-fixtures" : "production-simulator-entitlements"};
        await atomicJSON(join(root, "products.json"), paths);
        return;
    }
    const artifacts = dirname(options.preparationResult ?? options.resultBundle);
    const stageId = options.phase === "prepare" ? basename(options.preparationResult, ".safari-preparation.json")
        : basename(options.resultBundle, ".xcresult");
    if (options.phase === "prepare" && stageId !== "prepare-safari.macos.debug") { throw new Error("Invalid Safari preparation artifact identity"); }
    const preparationNonce = options.phase === "prepare" ? randomUUID() : undefined;
    const server = new SafariFixtureServer({descriptor, iterations: options.iterations, artifacts, stageId,
        interactiveActivation: options.interactiveActivation === true,
        ...(preparationNonce ? {preparationNonce} : {}),
        ...(options.preparedSafari ? {preparedActivation: true, preparation: options.preparedSafari} : {})});
    const startedAt = Date.now();
    let primaryError;
    let diagnosticProducts;
    let sourceProducts;
    let installation;
    let preparationObservation;
    let interrupted = false;
    const stop = () => { interrupted = true; };
    const requireRunning = () => {
        if (interrupted) { throw new Error("Safari test run cancelled"); }
    };
    const runCommand = (command, args, options) => {
        requireRunning();
        return execute(command, args, options);
    };
    const cleanupCommand = (command, args, options) => execute(command, args, interrupted
        ? {...options, timeoutSeconds: 1, terminationGraceMilliseconds: 100, outputDrainMilliseconds: 100}
        : options);
    process.once("SIGTERM", stop);
    process.once("SIGINT", stop);
    try {
        await server.start();
        server.runtime = await readMacOSRuntime(runCommand);
        const buildProducts = JSON.parse(await readFile(join(root, "products.json"), "utf8"));
        await verifyFixtureProducts(buildProducts, options.platform, descriptor);
        sourceProducts = buildProducts;
        let paths = {...sourceProducts};
        if (options.platform === "macos") {
            installation = options.phase === "prepare" || options.preparedSafari
                ? safariPreparedInstallation(descriptor, stageId, await realpath(userInfo().homedir), options.preparedSafari)
                : safariMacInstallation(descriptor, stageId, await realpath(userInfo().homedir));
            paths = await installSafariMacProducts({products: sourceProducts, descriptor, installation}, runCommand);
            server.walletApplicationPath = paths.app;
            server.helperApplicationPath = paths.helper;
        }
        if (options.platform === "macos") { diagnosticProducts = {app: paths.app, extension: paths.extension, helper: paths.helper}; }
        server.signingCoverage = paths.signingCoverage;
        if (options.platform === "macos") {
            const info = JSON.parse(await runCommand("/usr/bin/plutil", ["-convert", "json", "-o", "-", "/Applications/Safari.app/Contents/Info.plist"], {capture: true}));
            server.browser = {bundleIdentifier: "com.apple.Safari", version: info.CFBundleShortVersionString, build: info.CFBundleVersion};
            paths.extensionInfo = await readExtensionMetadata(paths.extension, "macos", runCommand);
            server.extension = paths.extensionInfo;
            paths.allowedExecutables = await executablePaths([paths.app, paths.extension, paths.helper], "macos", runCommand);
            await runCommand("/usr/bin/pluginkit", ["-a", paths.extension]);
            paths.registration = await collectSafariRegistration({artifacts, stageId, phase: "registered"}, runCommand);
        } else {
            const udid = /,id=([0-9A-Fa-f-]+)$/.exec(options.destination)?.[1];
            if (!udid) { throw new Error("Missing selected iOS Simulator"); }
            await runCommand("xcrun", ["simctl", "uninstall", udid, "org.lil.wallet"]);
            await runCommand("xcrun", ["simctl", "install", udid, paths.app]);
            Object.assign(paths, await installedIOSProducts(udid, descriptor, runCommand));
            server.extension = paths.extensionInfo;
            server.resolveAllowedExecutables = async () => {
                const current = await installedIOSProducts(udid, descriptor, cleanupCommand);
                paths.installedApp = current.installedApp;
                paths.extensionInfo = current.extensionInfo;
                server.extension = current.extensionInfo;
                paths.allowedExecutables = [...new Set([...paths.allowedExecutables, ...current.allowedExecutables])];
                await atomicJSON(join(artifacts, `${stageId}.safari-products.json`), paths);
                return current.allowedExecutables;
            };
            const safari = (await runCommand("xcrun", ["simctl", "get_app_container", udid, "com.apple.mobilesafari", "app"], {capture: true})).trim();
            const info = JSON.parse(await runCommand("/usr/bin/plutil", ["-convert", "json", "-o", "-", join(safari, "Info.plist")], {capture: true}));
            server.browser = {bundleIdentifier: "com.apple.mobilesafari", version: info.CFBundleShortVersionString, build: info.CFBundleVersion};
        }
        server.allowedExecutables = new Set(paths.allowedExecutables);
        if (options.platform === "macos" && options.signing === "local") {
            server.refreshExtensionRegistration = async (maximumDeadline = Date.now() + 150000) => {
                requireRunning();
                const deadline = Math.min(maximumDeadline, Date.now() + 150000);
                await server.stopOwnedProcesses(deadline);
                return rebuildSafariMacProducts({products: diagnosticProducts, sourceProducts,
                    descriptor, installation, buildArgs, artifacts, stageId, deadline,
                    beforeReplace: () => server.stopOwnedProcesses(deadline)}, runCommand);
            };
        }
        paths.runtime = server.runtime;
        await atomicJSON(join(artifacts, `${stageId}.safari-products.json`), paths);
        if (diagnosticProducts) {
            await collectSafariCodeSigning({products: diagnosticProducts, artifacts, stageId, phase: "before-tests", secrets: [server.token, server.pageToken]}, runCommand);
        }
        if (options.phase === "prepare") {
            preparationObservation = await runSafariPreparation({server, descriptor, nonce: preparationNonce, paths,
                command: runCommand, refresh: server.refreshExtensionRegistration, requireRunning,
                signatures: value => safariProductSignatures(value, runCommand),
                progress: value => atomicJSON(join(artifacts, `${stageId}.safari-preparation-progress.json`),
                    {version: 1, preparationRunID: runID, ...value})});
        } else {
            await runCommand("xcodebuild", commands.test.args,
                {env: {...process.env, TEST_RUNNER_BW_SAFARI_VM_CONFIGURATION: descriptorPath}, timeoutSeconds: commands.test.timeoutSeconds});
        }
        requireRunning();
    } catch (error) {
        primaryError = error;
    } finally {
        try {
            try {
                await finalizeSafariRun({server, descriptorPath, artifacts, stageId, platform: options.platform, startedAt,
                    primaryError, diagnosticProducts, sourceProducts: options.platform === "macos" ? sourceProducts : undefined, descriptor, installation, interrupted}, cleanupCommand);
            } catch (error) {
                if (options.phase === "prepare") {
                    await atomicJSON(options.preparationResult, {version: 1, status: "failed", preparationRunID: runID,
                        reason: redactSafariDiagnostics(String(error.message), [server.token, server.pageToken]),
                        cleanup: server.cleanup});
                }
                throw error;
            }
        } finally {
            process.removeListener("SIGTERM", stop);
            process.removeListener("SIGINT", stop);
        }
    }
    requireRunning();
    if (options.phase === "prepare") {
        if (!preparationObservation || server.cleanup.status !== "passed") { throw new Error("Safari preparation did not finish verified native cleanup"); }
        await verifySafariMacInstallation(descriptor, installation);
        const signatures = await safariProductSignatures(diagnosticProducts, runCommand);
        if (!isDeepStrictEqual(signatures, preparationObservation.signatures)) { throw new Error("Prepared Safari signatures changed during cleanup"); }
        const receipt = {version: 1, status: "passed", preparationRunID: runID, descriptor,
            installationDirectory: installation.directory, sourceApp: sourceProducts.app, signatures,
            enabledObservation: preparationObservation.enabledObservation, cleanup: {status: "passed"}, preparedAt: new Date().toISOString()};
        const bytes = JSON.stringify(receipt);
        await writeFile(join(installation.directory, ".safari-prepared.json"), bytes, {mode: 0o600, flag: "wx"});
        const receiptSHA256 = createHash("sha256").update(bytes).digest("hex");
        await atomicJSON(options.preparationResult, {version: 1, status: "passed", preparationRunID: runID,
            platform: "macos", configuration: "Debug", signingMode: "local", installationDirectory: installation.directory, receiptSHA256, receipt});
    }
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
    main().catch(error => { process.stderr.write(`${error.stack || error}\n`); process.exitCode = 1; });
}
