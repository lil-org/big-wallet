import assert from "node:assert/strict";
import {spawn} from "node:child_process";
import test from "node:test";
import {fileURLToPath} from "node:url";

const sourcePath = fileURLToPath(new URL("../run.mjs", import.meta.url));

async function mainFixture({sourcePath, phase, priorFailure}) {
    const [{readFile}, vm, {EventEmitter}, {PassThrough}] = await Promise.all([
        import("node:fs/promises"), import("node:vm"), import("node:events"), import("node:stream"),
    ]);
    const source = await readFile(sourcePath, "utf8");
    const runID = "cancellation-fixture";
    const platform = phase === "diagnostics" ? "macos" : "ios";
    const root = `/Volumes/BigWalletBuild/Exchange/${runID}/safari/${platform}/Debug`;
    const descriptor = {version: 1, runID, root, platform, signingMode: "local", configuration: "Debug"};
    const app = platform === "macos" ? "/fixture/home/Library/Developer/Xcode/DerivedData/Wallet/Build/Products/Debug/Big Wallet.app"
        : "/fixture/Devices/AAAA/Data/Containers/Bundle/Application/BBBB/Big Wallet.app";
    const extension = `${app}/${platform === "macos" ? "Contents/PlugIns/Safari macOS.appex" : "PlugIns/Safari iOS.appex"}`;
    const products = {app, extension, ...(platform === "macos" ? {helper: `${extension}/Contents/Helpers/Big Wallet.app`} : {})};
    const originalError = new Error("Original XCTest fixture failure");
    const events = [], timers = [], unexpectedCommands = [], commands = [];
    const files = new Map();
    const listeners = () => [process.listenerCount("SIGTERM"), process.listenerCount("SIGINT")];
    const initialListeners = listeners();
    let finalReport, currentCommand, stopped = false, cleaning = false, pretestReady = false, diagnosticPaused = false, identityResolved = false;
    const pause = async point => {
        events.push(`${point}-started`);
        if (phase === point) {
            const resumed = new Promise(resolve => process.once("message", resolve));
            process.send({phase: point, listeners: listeners()});
            await resumed;
            stopped = true;
        }
        events.push(`${point}-finished`);
    };
    const context = vm.createContext({process, Buffer, structuredClone, clearTimeout,
        setTimeout(callback, milliseconds) {
            if (currentCommand === "/usr/bin/log") { timers.push(milliseconds); }
            return setTimeout(callback, milliseconds);
        },
    });
    const module = new vm.SourceTextModule(source, {context, identifier: "file:///fixture/run.mjs"});
    const cache = new Map();
    process.env.BW_TEST_VM_RUN_ID = runID;
    process.env.BW_TEST_VM_EXCHANGE = "/Volumes/BigWalletBuild/Exchange";
    await module.link(async name => {
        if (cache.has(name)) { return cache.get(name); }
        let exports;
        if (name === "./fixture_server.mjs") {
            exports = {
                SafariFixtureServer: class {
                    constructor() { this.allowedExecutables = new Set(); }
                    async start() { if (phase === "startup") { await pause("startup"); } }
                    async close() {
                        cleaning = true;
                        await pause("cleanup");
                        if (this.resolveAllowedExecutables) { await this.resolveAllowedExecutables(); identityResolved = true; }
                        this.cleanup = {status: "passed"};
                    }
                    async persist() {}
                },
                atomicJSON: async (path, value) => {
                    if (path.endsWith(".safari-products.json")) {
                        pretestReady = true;
                        if (!cleaning && phase === "pretest-write") { await pause("pretest-write"); }
                    }
                    if (path.endsWith(".safari-finalization.json")) {
                        await pause("report");
                        finalReport = JSON.parse(JSON.stringify(value));
                    }
                },
            };
        } else if (name === "./prepare.mjs") {
            exports = {runSafariPreparation: async () => { throw new Error("Unexpected preparation in a normal cancellation fixture"); }};
        } else {
            exports = {...await import(name)};
            if (name === "node:fs/promises") {
                Object.assign(exports, {
                    mkdir: async () => {},
                    lstat: async path => ({isDirectory: () => !files.has(path), isFile: () => files.has(path),
                        isSymbolicLink: () => false, uid: process.getuid(), mode: files.has(path) ? 0o600 : 0o700, nlink: 1, size: 100}),
                    realpath: async path => path,
                    readFile: async path => {
                        if (files.has(path)) { return files.get(path); }
                        if (path.endsWith("SafariVMRun.json")) { return JSON.stringify(descriptor); }
                        if (path.endsWith("products.json")) { return JSON.stringify(products); }
                        throw new Error(`Unexpected fixture read: ${path}`);
                    },
                    copyFile: async () => {},
                    writeFile: async (path, value) => { files.set(path, value); },
                    rm: async () => {},
                });
            }
            if (name === "node:os") { exports.userInfo = () => ({homedir: "/fixture/home"}); }
            if (name === "node:child_process") {
                exports.spawn = (command, args) => {
                    const child = new EventEmitter();
                    child.stdout = new PassThrough();
                    child.stderr = new PassThrough();
                    currentCommand = command;
                    commands.push({command, args, stopped, cleaning});
                    queueMicrotask(async () => {
                        if (phase === "diagnostics" && pretestReady && command === "/usr/bin/codesign" && !diagnosticPaused) {
                            diagnosticPaused = true;
                            await pause("diagnostics");
                        }
                        let output = "";
                        if (command === "xcodebuild" && priorFailure) {
                            child.emit("error", originalError);
                            child.emit("close", null, null);
                            return;
                        }
                        if (command === "/usr/bin/sw_vers") { output = args[0] === "-productVersion" ? "27.0" : "26A123"; }
                        else if (command === "xcrun" && args[1] === "get_app_container") { output = app; }
                        else if (command === "/usr/bin/plutil") {
                            output = args[0] === "-extract" ? "Big Wallet" : JSON.stringify({
                                CFBundleIdentifier: "org.lil.wallet.Safari", CFBundleShortVersionString: "1", CFBundleVersion: "1",
                            });
                        } else if (!["/bin/sh", "xcrun", "xcodebuild", "/usr/bin/log", "/usr/bin/ditto", "/usr/bin/codesign", "/usr/bin/pluginkit"].includes(command)) {
                            unexpectedCommands.push(command);
                        }
                        child.stdout.end(output);
                        child.stderr.end();
                        child.emit("exit", 0, null);
                        child.emit("close", 0, null);
                    });
                    return child;
                };
            }
        }
        const names = Object.keys(exports);
        const linked = new vm.SyntheticModule(names, function () {
            for (const name of names) { this.setExport(name, exports[name]); }
        }, {context});
        cache.set(name, linked);
        return linked;
    });
    await module.evaluate();
    let failure;
    try {
        await module.namespace.main(["--phase", "test", "--platform", platform, "--configuration", "Debug", "--signing", "local",
            "--destination", platform === "macos" ? "platform=macOS,arch=arm64" : "platform=iOS Simulator,id=AAAA",
            "--scratch-dir", "/Volumes/BigWalletBuild/scratch",
            "-resultBundlePath", `/Volumes/BigWalletBuild/artifacts/safari.${platform}.debug.xcresult`]);
    } catch (error) {
        failure = {message: error.message, preservedOriginal: error === originalError};
        process.exitCode = 1;
    }
    process.stdout.write(JSON.stringify({events, timers, unexpectedCommands, commands, identityResolved, finalReport, failure,
        initialListeners, finalListeners: listeners()}) + "\n");
    process.disconnect();
}

async function cancelledFixture(context, {signal, phase, priorFailure = false}) {
    const child = spawn(process.execPath, ["--no-warnings", "--experimental-vm-modules", "--input-type=module", "-e",
        `(${mainFixture.toString()})(${JSON.stringify({sourcePath, phase, priorFailure})})`],
    {stdio: ["ignore", "pipe", "pipe", "ipc"]});
    let output = "", stderr = "", ready, resumeTimer;
    context.after(() => {
        clearTimeout(resumeTimer);
        if (child.exitCode === null && child.signalCode === null) { child.kill("SIGKILL"); }
    });
    child.stdout.on("data", value => { output += value; });
    child.stderr.on("data", value => { stderr += value; });
    child.once("message", message => {
        ready = message;
        child.kill(signal);
        resumeTimer = setTimeout(() => {
            if (child.connected) { child.send("resume"); }
        }, 100);
    });
    const outcome = await new Promise((resolve, reject) => {
        child.once("error", reject);
        child.once("close", (code, signal) => resolve({code, signal}));
    });
    assert.deepEqual(outcome, {code: 1, signal: null}, stderr || output);
    assert.equal(ready?.phase, phase, stderr || output);
    assert.ok(ready.listeners.every(count => count >= 1));
    const result = JSON.parse(output);
    assert.deepEqual(result.events.slice(-4), ["cleanup-started", "cleanup-finished", "report-started", "report-finished"]);
    assert.deepEqual(result.unexpectedCommands, []);
    assert.deepEqual(result.finalListeners, result.initialListeners);
    assert.equal(result.finalReport.status, "passed", JSON.stringify(result.finalReport));
    return result;
}

for (const signal of ["SIGTERM", "SIGINT"]) {
    for (const phase of ["cleanup", "report"]) {
        for (const priorFailure of [false, true]) {
            test(`first ${signal} during ${phase} finishes finalization after ${priorFailure ? "failed" : "successful"} XCTest`, {timeout: 10000}, async context => {
                const result = await cancelledFixture(context, {signal, phase, priorFailure});
                if (priorFailure) {
                    assert.equal(result.failure.preservedOriginal, true);
                    assert.equal(result.finalReport.primaryFailure, result.failure.message);
                    if (phase === "cleanup") {
                        assert.ok(result.timers.includes(1000));
                        assert.ok(result.timers.every(milliseconds => milliseconds <= 1000));
                    }
                } else {
                    assert.match(result.failure.message, /cancelled/i);
                    assert.equal(result.failure.preservedOriginal, false);
                }
            });
        }
    }
    for (const phase of ["startup", "pretest-write", "diagnostics"]) {
        test(`first ${signal} during ${phase} prevents further setup and XCTest while allowing cleanup`, {timeout: 10000}, async context => {
            const result = await cancelledFixture(context, {signal, phase});
            assert.match(result.failure.message, /cancelled/i);
            assert.equal(result.finalReport.primaryFailure, result.failure.message);
            assert.deepEqual(result.commands.filter(command => command.stopped && !command.cleaning), []);
            assert.ok(!result.commands.some(command => command.command === "xcodebuild"));
            if (phase === "pretest-write") {
                assert.equal(result.identityResolved, true);
                assert.ok(result.commands.some(command => command.stopped && command.cleaning && command.command === "xcrun"));
            }
        });
    }
}
