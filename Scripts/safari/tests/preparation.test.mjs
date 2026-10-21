import test from "node:test";
import assert from "node:assert/strict";
import {createHash, randomUUID} from "node:crypto";
import {mkdtemp, mkdir, writeFile, readFile, rm, realpath, cp, access} from "node:fs/promises";
import {join} from "node:path";
import {tmpdir} from "node:os";
import {findPreparationObservation, preparationRequestAllowed, runSafariPreparation, waitForPreparationProbe} from "../prepare.mjs";
import {parseArguments, safariPreparedInstallation, installSafariMacProducts, readPreparedSafariReceipt,
    safariProductSignatures, assertPreparedProductsStopped} from "../run.mjs";

const nonce = "cb0611ad-9f0e-4b07-b783-071d6abea441";
const incarnation = "5e961dd9-62e9-424f-ac88-c6816490e23c";
const executablePath = "/Users/fixture/Applications/Big Wallet.app/Contents/MacOS/Big Wallet";
const observationOptions = {offset: 0, runID: "prepare-test", nonce, executablePath, notBefore: 1000};
const started = {kind: "processStarted", runID: "prepare-test", processID: 42, incarnation, role: "app",
    bundleID: "org.lil.wallet", executablePath, time: 1};
const state = {kind: "safariExtensionState", runID: "prepare-test", processID: 42, incarnation, time: 2,
    preparationNonce: nonce, enabled: true, errorDomain: null, errorCode: null};

test("preparation admits only the newest fresh state from the launched containing app", () => {
    assert.equal(findPreparationObservation([started, state], observationOptions).enabled, true);
    for (const later of [{...state, enabled: false, time: 3},
        {...state, enabled: null, errorDomain: "SafariErrorDomain", errorCode: 1, time: 3}]) {
        assert.equal(findPreparationObservation([started, state, later], observationOptions), null);
    }
    for (const events of [[state], [{...started, role: "extension"}, state],
        [started, {...state, preparationNonce: randomUUID()}], [started, {...state, incarnation: randomUUID()}],
        [started, {...state, runID: "old-run"}], [started, {...state, time: 0}]]) {
        assert.equal(findPreparationObservation(events, observationOptions), null);
    }
    assert.equal(findPreparationObservation([started, state], {...observationOptions, offset: 1}), null);
    assert.equal(findPreparationObservation([started, state], {...observationOptions, notBefore: 3000}), null);
});

test("preparation controller authentication binds token, host, origin and same-origin requests", () => {
    const origin = "http://127.0.0.1:49152";
    const request = {method: "POST", headers: {host: "127.0.0.1:49152", origin, "x-wallet-preparation": "secret", "sec-fetch-site": "same-origin"}};
    assert.equal(preparationRequestAllowed(request, origin, "secret"), true);
    for (const headers of [{...request.headers, host: "evil.invalid"}, {...request.headers, origin: "http://evil.invalid"},
        {...request.headers, "x-wallet-preparation": "wrong"}, {...request.headers, "sec-fetch-site": "cross-site"},
        {...request.headers, origin: undefined}]) {
        assert.equal(preparationRequestAllowed({...request, headers}, origin, "secret"), false);
    }
    assert.equal(preparationRequestAllowed({...request, method: "OPTIONS"}, origin, "secret"), false);
});

test("probe startup accepts a fresh disabled state or typed public error only from its live launch", async () => {
    for (const response of [{...state, enabled: false},
        {...state, enabled: null, errorDomain: "SafariErrorDomain", errorCode: 1}]) {
        const server = {nativeEvents: async () => [started, response], processInspector: async () => executablePath,
            allowedExecutables: new Set([executablePath])};
        const result = await waitForPreparationProbe({server, observation: observationOptions, check() {}, deadline: 16000,
            now: () => 1000, wait: async () => assert.fail("A fresh response must not wait"), canonicalPath: async value => value});
        assert.deepEqual(result, {processID: 42, incarnation});
    }
});

test("probe startup rejects a crashed process and bounds an alive nonresponsive process", async () => {
    const server = {nativeEvents: async () => [started], processInspector: async () => null,
        allowedExecutables: new Set([executablePath])};
    await assert.rejects(waitForPreparationProbe({server, observation: observationOptions, check() {}, deadline: 16000,
        now: () => 1000, wait: async () => assert.fail("A terminated probe must fail immediately"),
        canonicalPath: async value => value}), /app terminated/);
    let time = 1000;
    let polls = 0;
    server.processInspector = async () => { polls += 1; return executablePath; };
    await assert.rejects(waitForPreparationProbe({server, observation: observationOptions, check() {}, deadline: 16000,
        now: () => time, wait: async milliseconds => { time += milliseconds; }, canonicalPath: async value => value}), /within 15 seconds/);
    assert.equal(time, 16000);
    assert.equal(polls, 60);
});

async function fixture(context) {
    const root = await realpath(await mkdtemp(join(tmpdir(), "safari-preparation-")));
    context.after(() => rm(root, {recursive: true, force: true}));
    const home = join(root, "home");
    await mkdir(home, {mode: 0o700});
    const descriptor = {version: 1, runID: "prepare-test", root: "/Volumes/BigWalletBuild/Exchange/prepare-test/safari/macos/Debug",
        platform: "macos", signingMode: "local", configuration: "Debug"};
    const app = join(home, "Library/Developer/Xcode/DerivedData/Wallet/Build/Products/Debug/Big Wallet.app");
    const extension = join(app, "Contents/PlugIns/Safari macOS.appex");
    const products = {app, extension, helper: join(extension, "Contents/Helpers/Big Wallet.app")};
    const fill = async value => {
        for (const path of Object.values(products)) {
            await mkdir(join(path, "Contents/Resources"), {recursive: true});
            await writeFile(join(path, "Contents/Resources/SafariVMRun.json"), JSON.stringify(value));
        }
    };
    await fill(descriptor);
    const commands = [];
    const command = async (file, args) => {
        commands.push([file, ...args]);
        if (file === "/usr/bin/ditto") { await cp(args[3], args[4], {recursive: true}); return ""; }
        if (file === "/bin/ps") { return " 1 /sbin/launchd\n"; }
        assert.equal(file, "/usr/bin/codesign");
        if (args[0] === "--verify") { return ""; }
        const path = args.at(-1);
        const role = path.includes("Contents/Helpers") ? "helper" : path.endsWith(".appex") ? "extension" : "app";
        const identifier = {app: "org.lil.wallet", extension: "org.lil.wallet.Safari", helper: "org.lil.wallet.ambient"}[role];
        const bundled = await readFile(join(path, "Contents/Resources/SafariVMRun.json"));
        return `Identifier=${identifier}\nCDHash=${createHash("sha1").update(bundled).update(role).digest("hex")}\nSignature=adhoc\nTeamIdentifier=not set\n`;
    };
    return {root, home, descriptor, products, fill, command, commands};
}

async function seedFixture(context) {
    const value = await fixture(context);
    const installation = safariPreparedInstallation(value.descriptor, "prepare-safari.macos.debug", value.home);
    const installed = await installSafariMacProducts({products: value.products, descriptor: value.descriptor, installation}, value.command);
    const signatures = await safariProductSignatures(installed, value.command);
    const receipt = {version: 1, status: "passed", preparationRunID: value.descriptor.runID, descriptor: value.descriptor,
        installationDirectory: installation.directory, sourceApp: value.products.app, signatures,
        enabledObservation: {enabled: true}, cleanup: {status: "passed"}};
    const bytes = JSON.stringify(receipt);
    const reference = {preparationRunID: value.descriptor.runID, receiptSHA256: createHash("sha256").update(bytes).digest("hex")};
    await writeFile(join(installation.directory, ".safari-prepared.json"), bytes, {mode: 0o600});
    return {...value, installation, installed, receipt, reference};
}

test("prepared runtime replaces the exact stable URL with current descriptor and signatures", async context => {
    const f = await seedFixture(context);
    const descriptor = {...f.descriptor, runID: "current-test", root: "/Volumes/BigWalletBuild/Exchange/current-test/safari/macos/Debug"};
    await f.fill(descriptor);
    const installation = safariPreparedInstallation(descriptor, "safari.macos.debug", f.home, f.reference);
    assert.deepEqual((await readPreparedSafariReceipt(installation)).receipt, f.receipt);
    const current = await installSafariMacProducts({products: f.products, descriptor, installation}, f.command);
    assert.equal(current.app, f.installed.app);
    assert.deepEqual(JSON.parse(await readFile(join(current.app, "Contents/Resources/SafariVMRun.json"))), descriptor);
    assert.notDeepEqual(await safariProductSignatures(current, f.command), f.receipt.signatures);
    assert.equal(JSON.parse(await readFile(join(installation.directory, ".safari-vm-installation.json"))).runID, "current-test");
    assert.deepEqual((await readPreparedSafariReceipt(installation)).receipt, f.receipt);
});

test("prepared takeover rejects altered receipts, altered seeded products and running seed code", async context => {
    const f = await seedFixture(context);
    const descriptor = {...f.descriptor, runID: "current-test", root: "/Volumes/BigWalletBuild/Exchange/current-test/safari/macos/Debug"};
    await f.fill(descriptor);
    const bad = safariPreparedInstallation(descriptor, "safari.macos.debug", f.home, {...f.reference, receiptSHA256: "0".repeat(64)});
    await assert.rejects(installSafariMacProducts({products: f.products, descriptor, installation: bad}, f.command), /receipt/);
    const installation = safariPreparedInstallation(descriptor, "safari.macos.debug", f.home, f.reference);
    await assert.rejects(installSafariMacProducts({products: f.products, descriptor, installation},
        (file, args) => file === "/bin/ps" ? Promise.resolve(`42 ${f.installed.app}/Contents/MacOS/Big Wallet\n`) : f.command(file, args)), /still running/);
    const marker = join(f.installed.app, "Contents/Resources/SafariVMRun.json");
    await writeFile(marker, JSON.stringify({...f.descriptor, untrusted: true}));
    await assert.rejects(installSafariMacProducts({products: f.products, descriptor, installation}, f.command), /fixture marker/);
});

test("preparation can replace a verified older seed without retaining its passed receipt", async context => {
    const f = await seedFixture(context);
    const descriptor = {...f.descriptor, runID: "prepare-next", root: "/Volumes/BigWalletBuild/Exchange/prepare-next/safari/macos/Debug"};
    await f.fill(descriptor);
    const installation = safariPreparedInstallation(descriptor, "prepare-safari.macos.debug", f.home);
    await installSafariMacProducts({products: f.products, descriptor, installation}, f.command);
    await assert.rejects(access(join(installation.directory, ".safari-prepared.json")), {code: "ENOENT"});
    assert.equal(JSON.parse(await readFile(join(installation.directory, ".safari-vm-installation.json"))).preparationRunID, "prepare-next");
});

test("preparation refuses to remove a pre-existing marker on failed admission", async context => {
    const f = await fixture(context);
    const marker = join(f.root, "activation-preparation.json");
    await writeFile(marker, "existing owner");
    await assert.rejects(runSafariPreparation({server: {preparationNonce: nonce, nativeEvents: async () => []},
        descriptor: {...f.descriptor, root: f.root}, nonce, paths: f.products,
        command: async () => assert.fail("No process may launch"), requireRunning() {}}), {code: "EEXIST"});
    assert.equal(await readFile(marker, "utf8"), "existing owner");
});

test("a crashed launched probe never announces preparation readiness", async context => {
    const f = await fixture(context);
    const appExecutable = join(f.products.app, "Contents/MacOS/Big Wallet");
    const events = [];
    const progress = [];
    const server = {preparationNonce: nonce, nativeEvents: async () => events, processInspector: async () => null,
        allowedExecutables: new Set([appExecutable])};
    await assert.rejects(runSafariPreparation({server, descriptor: {...f.descriptor, root: f.root}, nonce, paths: f.products,
        command: async (file, args) => {
            assert.equal(file, "/usr/bin/open");
            if (args[0] === "-n") { events.push({...started, executablePath: appExecutable, time: Date.now() / 1000}); }
        },
        requireRunning() {}, progress: async value => progress.push(value)}), /app terminated/);
    assert.deepEqual(progress, []);
    await assert.rejects(access(join(f.root, "activation-preparation.json")), {code: "ENOENT"});
});

test("preparation finishes only after authenticated rebuild and a live signed app observation", async context => {
    const f = await fixture(context);
    const descriptor = {...f.descriptor, root: f.root};
    const appExecutable = join(f.products.app, "Contents/MacOS/Big Wallet");
    await mkdir(join(f.products.app, "Contents/MacOS"), {recursive: true});
    await writeFile(appExecutable, "fixture executable");
    const events = [];
    const progress = [];
    let launchCount = 0;
    let rebuilds = 0;
    let safariQuit = false;
    let action;
    const server = {preparationNonce: nonce, nativeEvents: async () => events,
        clearGuestCredential: async () => {}, processInspector: async () => appExecutable,
        allowedExecutables: new Set([appExecutable])};
    const command = async (file, args) => {
        if (file === "/usr/bin/open" && args[0] === "-a") {
            const url = new URL(args[2]);
            const token = url.hash.slice(1);
            action = new Promise((resolve, reject) => setTimeout(() => {
                fetch(`${url.origin}/refresh`, {method: "POST",
                    headers: {Origin: url.origin, "X-Wallet-Preparation": token}})
                    .then(async response => { assert.equal(response.status, 200); await response.json(); resolve(); }).catch(reject);
            }, 20));
        } else if (file === "/usr/bin/open") {
            launchCount += 1;
            const time = Date.now() / 1000;
            const processID = 40 + launchCount;
            events.push({...started, processID, executablePath: appExecutable, time});
            events.push({...state, processID, enabled: rebuilds > 0, time: time + 0.001});
        } else {
            assert.equal(file, "/usr/bin/osascript");
            assert.deepEqual(args, ["-e", 'tell application id "com.apple.Safari" to quit']);
            safariQuit = true;
        }
        return "";
    };
    const result = await runSafariPreparation({server, descriptor, nonce, paths: f.products, command,
        refresh: async () => { rebuilds += 1; }, signatures: async () => ({verified: "fixture-signature"}),
        requireRunning() {}, progress: async value => progress.push(value)});
    await action;
    assert.equal(rebuilds, 1);
    assert.equal(result.enabledObservation.enabled, true);
    assert.equal(result.enabledObservation.processID, 42);
    assert.equal(safariQuit, true);
    assert.deepEqual(progress.map(value => value.phase), ["ready-for-user", "refreshed", "enabled"]);
    await assert.rejects(access(join(f.root, "activation-preparation.json")), {code: "ENOENT"});
});

test("prepared process inventory is fail-closed for ambiguous names and malformed output", async () => {
    const paths = {app: "/test/App.app", extension: "/test/App.app/Extension.appex", helper: "/test/App.app/Helper.app"};
    await assertPreparedProductsStopped(paths, async () => "1 /sbin/launchd\n");
    for (const output of ["10 Big Wallet\n", "11 /test/App.app/Contents/MacOS/Big Wallet\n", "unparseable"]) {
        await assert.rejects(assertPreparedProductsStopped(paths, async () => output));
    }
});

test("preparation arguments require an isolated local Debug prepare stage", () => {
    const base = ["--phase", "prepare", "--platform", "macos", "--configuration", "Debug", "--signing", "local",
        "--destination", "platform=macOS,arch=arm64", "--scratch-dir", "/Volumes/BigWalletBuild/scratch",
        "--preparation-result", "/Volumes/BigWalletBuild/artifacts/prepare-safari.macos.debug.safari-preparation.json"];
    assert.equal(parseArguments(base).phase, "prepare");
    for (const args of [base.map(value => value === "Debug" ? "Release" : value),
        [...base, "--interactive-safari"], [...base, "--only-testing", "SafariLifecycleTests"],
        [...base, "--prepared-safari", JSON.stringify({preparationRunID: "seed", receiptSHA256: "a".repeat(64)})]]) {
        assert.throws(() => parseArguments(args));
    }
});
