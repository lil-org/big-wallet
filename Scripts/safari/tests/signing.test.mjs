import test from "node:test";
import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {EventEmitter} from "node:events";
import {mkdtemp, readFile, realpath, rm, writeFile, mkdir, readdir, cp, stat, symlink} from "node:fs/promises";
import {tmpdir} from "node:os";
import {basename, dirname, join} from "node:path";
import {PassThrough, Writable} from "node:stream";
import {appleFixtureEntitlements, signAppleFixtureProducts, commandTimeoutSeconds, safariTestTimeouts, execute,
    collectSafariDiagnostics, collectSafariRegistration, collectSafariCodeSigning, finalizeSafariRun, safariDiagnosticPredicate,
    readExtensionMetadata, readMacOSRuntime, refreshSafariExtensionRegistration,
    safariMacInstallation, installSafariMacProducts, removeSafariMacInstallation, rebuildSafariMacProducts,
    deregisterSafariExtension, removeHostedUnitTestBundle, verifySynchronizationHookExclusion} from "../run.mjs";

const root = "/Volumes/BigWalletBuild/Exchange/signing-test/safari/macos/Release";
const fileAccess = "com.apple.security.temporary-exception.files.absolute-path.read-write";
const machO = (content = "ordinary product binary") => {
    const header = Buffer.alloc(32);
    header.writeUInt32LE(0xfeedfacf, 0);
    header.writeUInt32LE(0x0100000c, 4);
    header.writeUInt32LE(2, 12);
    return Buffer.concat([header, Buffer.from(content)]);
};

test("Safari removes only the hosted iOS unit-test bundle before checking production binaries", async context => {
    const directory = await realpath(await mkdtemp(join(tmpdir(), "safari-hosted-tests-")));
    context.after(() => rm(directory, {recursive: true, force: true}));
    const app = join(directory, "Wallet.app"), extension = join(app, "PlugIns/Safari.appex");
    const products = {app, extension};
    const hosted = join(app, "PlugIns/Tests iOS.xctest");
    const hostedBinary = join(hosted, "Tests iOS");
    const binaries = [join(app, "fixture"), join(extension, "fixture"), join(app, "PlugIns/Other.xctest/fixture")];
    for (const path of [...binaries, hostedBinary]) {
        await mkdir(dirname(path), {recursive: true});
        await writeFile(path, machO(path === hostedBinary ? "BWSafariSynchronizationState" : undefined));
    }
    const inspect = async () => "fixture";
    await assert.rejects(verifySynchronizationHookExclusion(products, "ios", inspect), /must not be linked/);
    await removeHostedUnitTestBundle(products, "macos");
    assert.ok((await stat(hostedBinary)).isFile());
    await removeHostedUnitTestBundle(products, "ios");
    await assert.rejects(stat(hosted), {code: "ENOENT"});
    await removeHostedUnitTestBundle(products, "ios");
    assert.deepEqual(new Set((await verifySynchronizationHookExclusion(products, "ios", inspect)).executables), new Set(binaries));
    for (const binary of binaries.slice(0, 2)) {
        await writeFile(binary, machO("BWSafariSynchronizationState"));
        await removeHostedUnitTestBundle(products, "ios");
        await assert.rejects(verifySynchronizationHookExclusion(products, "ios", inspect), error =>
            /must not be linked/.test(error.message) && error.message.includes(binary));
        await writeFile(binary, machO());
    }
    const outside = join(directory, "outside.xctest");
    await mkdir(outside);
    await symlink(outside, hosted);
    await removeHostedUnitTestBundle(products, "ios");
    assert.ok((await stat(outside)).isDirectory());
    assert.ok(!(await readdir(join(app, "PlugIns"))).includes("Tests iOS.xctest"));
});

test("wallet, extension, and helper binaries exclude the UI test synchronization hook", async context => {
    const directory = await realpath(await mkdtemp(join(tmpdir(), "safari-hook-exclusion-")));
    context.after(() => rm(directory, {recursive: true, force: true}));
    for (const platform of ["ios", "macos"]) {
        const products = {app: join(directory, platform, "Wallet.app"), extension: join(directory, platform, "Safari.appex"),
            ...(platform === "macos" ? {helper: join(directory, platform, "Helper.app")} : {})};
        const binaries = [];
        for (const bundle of Object.values(products)) {
            const executable = join(bundle, ...(platform === "macos" ? ["Contents", "MacOS"] : []), "fixture");
            await mkdir(dirname(executable), {recursive: true});
            await writeFile(executable, machO());
            binaries.push(executable);
        }
        const inspect = async (command, args) => {
            assert.equal(command, "/usr/bin/plutil");
            assert.deepEqual(args.slice(0, 5), ["-extract", "CFBundleExecutable", "raw", "-o", "-"]);
            return "fixture";
        };
        assert.deepEqual(await verifySynchronizationHookExclusion(products, platform, inspect),
            {status: "passed", executables: binaries});
        for (const binary of binaries) {
            await writeFile(binary, machO("binary\0BWSafariSynchronizationState\0tail"));
            await assert.rejects(verifySynchronizationHookExclusion(products, platform, inspect), /must not be linked/);
            await writeFile(binary, machO());
        }
        await writeFile(binaries[0], "not a Mach-O executable");
        await assert.rejects(verifySynchronizationHookExclusion(products, platform, inspect), /is not Mach-O/);
        await rm(binaries[0]);
        await assert.rejects(verifySynchronizationHookExclusion(products, platform, inspect), {code: "ENOENT"});
    }
});

test("a clean launcher cannot hide hook code in Debug libraries or nested framework executables", async context => {
    const directory = await realpath(await mkdtemp(join(tmpdir(), "safari-hook-loadable-code-")));
    context.after(() => rm(directory, {recursive: true, force: true}));
    const app = join(directory, "Wallet.app"), extension = join(app, "Contents/PlugIns/Safari.appex");
    const products = {app, extension};
    const binaries = [join(app, "Contents/MacOS/fixture"), join(extension, "Contents/MacOS/fixture")];
    const debug = join(app, "Contents/MacOS/Wallet.debug.dylib");
    const extensionDebug = join(extension, "Contents/MacOS/Safari.debug.dylib");
    const framework = join(app, "Contents/Frameworks/Nested.framework");
    const nested = join(framework, "Versions/A/Nested");
    for (const path of [...binaries, debug, extensionDebug, nested]) {
        await mkdir(dirname(path), {recursive: true});
        await writeFile(path, machO());
    }
    await symlink("A", join(framework, "Versions/Current"));
    await symlink("Versions/Current/Nested", join(framework, "Nested"));
    const resource = join(app, "Contents/Resources/synchronization.txt");
    await mkdir(dirname(resource), {recursive: true});
    await writeFile(resource, "BWSafariSynchronization appears in this ordinary text resource");
    const inspect = async () => "fixture";
    const clean = await verifySynchronizationHookExclusion(products, "macos", inspect);
    assert.deepEqual(new Set(clean.executables), new Set([...binaries, debug, extensionDebug, nested]));
    for (const path of [debug, extensionDebug, nested]) {
        const prefix = Buffer.alloc(64 * 1024 - 32 - 5);
        await writeFile(path, machO(Buffer.concat([prefix, Buffer.from("BWSafariSynchronizationState")])));
        await assert.rejects(verifySynchronizationHookExclusion(products, "macos", inspect), error =>
            /must not be linked/.test(error.message) && error.message.includes(path));
        await writeFile(path, machO());
    }
    const outside = join(directory, "outside.dylib");
    await writeFile(outside, machO());
    await symlink(outside, join(app, "Contents/Frameworks/Outside.dylib"));
    await assert.rejects(verifySynchronizationHookExclusion(products, "macos", inspect), /symlink escapes/);
});
const originalEntitlements = role => ({
    "com.apple.security.app-sandbox": true,
    "com.apple.security.application-groups": ["TEAM.group.org.lil.wallet"],
    "keychain-access-groups": [`TEAM.org.lil.wallet.${role}`, "TEAM.org.lil.wallet.rpc-auth"],
    "com.apple.security.network.client": true,
    "com.apple.security.get-task-allow": true,
    "com.apple.developer.icloud-container-identifiers": ["iCloud.org.lil.wallet"],
});
const certificate = role => Buffer.from(`fixture-${role}-original-signing-certificate`);
const identity = role => createHash("sha1").update(certificate(role)).digest("hex").toUpperCase();
const diagnosticProducts = {app: "/fixture/Big Wallet.app", extension: "/fixture/Big Wallet.app/Contents/PlugIns/Safari macOS.appex",
    helper: "/fixture/Big Wallet.app/Contents/PlugIns/Safari macOS.appex/Contents/Helpers/Big Wallet.app"};
const sourceDiagnosticProducts = Object.fromEntries(Object.entries(diagnosticProducts).map(([role, path]) => [role, "/build" + path]));

async function signingFixture(context, options = {}) {
    const scratch = await realpath(await mkdtemp(join(tmpdir(), "safari-signing-fixture-")));
    context.after(() => rm(scratch, {recursive: true, force: true}));
    const paths = {app: "/fixture/Big Wallet.app", extension: "/fixture/Big Wallet.app/Contents/PlugIns/Safari macOS.appex",
        helper: "/fixture/Big Wallet.app/Contents/PlugIns/Safari macOS.appex/Contents/Helpers/Big Wallet.app"};
    const calls = [];
    const signed = new Map();
    const command = async (executable, args) => {
        calls.push([executable, ...args]);
        if (executable === "/usr/bin/codesign") {
            const role = Object.keys(paths).find(key => paths[key] === args.at(-1));
            assert.ok(role, "Only the three declared fixture products may be signed or inspected");
            if (args.includes("--verify")) {
                if (options.failVerification === (signed.size ? "final" : "initial")) { throw new Error("Injected signature verification failure"); }
                return "";
            }
            if (args.includes("--display")) {
                const prefix = args[args.indexOf("--extract-certificates") + 1];
                const verified = prefix.includes("-verified-");
                const bytes = options.certificate?.(role, verified) ?? certificate(role);
                await writeFile(`${prefix}0`, bytes);
                return "";
            }
            assert.ok(args.includes("--force"));
            assert.equal(args[args.indexOf("--sign") + 1], identity(role));
            if (options.failSigning === role) { throw new Error("Injected signing failure"); }
            signed.set(role, JSON.parse(await readFile(args[args.indexOf("--entitlements") + 1], "utf8")));
            return "";
        }
        assert.equal(executable, "/usr/bin/plutil", "The fixture must never execute any native tool");
        if (args.includes("xml1")) { return ""; }
        assert.deepEqual(args.slice(0, 4), ["-convert", "json", "-o", "-"]);
        const path = args.at(-1);
        const role = basename(path).split("-")[0];
        const verified = path.includes("-verified.");
        const value = verified ? signed.get(role) : options.original?.(role) ?? originalEntitlements(role);
        return JSON.stringify(verified && options.verified ? options.verified(role, value) : value);
    };
    return {scratch, paths, calls, signed, run: () => signAppleFixtureProducts(paths, root, scratch, command)};
}

test("Apple fixture access preserves every original entitlement without mutating the source", () => {
    const original = originalEntitlements("extension");
    const snapshot = structuredClone(original);
    const result = appleFixtureEntitlements(original, root);
    assert.deepEqual(result, {...snapshot, [fileAccess]: [`${root}/`]});
    result["keychain-access-groups"].push("changed-copy");
    assert.deepEqual(original, snapshot);
    const existing = {...original, [fileAccess]: ["/existing/exception/", `${root}/`]};
    assert.deepEqual(appleFixtureEntitlements(existing, root), existing);
});

test("Apple fixture entitlement merging rejects unrestricted or malformed inputs", () => {
    for (const value of [undefined, null, [], {}, {"com.apple.security.app-sandbox": false},
        {...originalEntitlements("app"), [fileAccess]: "/"}, {...originalEntitlements("app"), [fileAccess]: [1]}]) {
        assert.throws(() => appleFixtureEntitlements(value, root));
    }
    for (const path of ["/", root + "/../Debug", root.replace("macos", "ios"), root + '"<string>/</string>', root.replace("Release", "Distribution")]) {
        assert.throws(() => appleFixtureEntitlements(originalEntitlements("app"), path));
    }
});

test("Apple products retain their own signing identities and are signed inside out", async context => {
    const fixture = await signingFixture(context);
    const result = await fixture.run();
    const operations = fixture.calls.filter(call => call.includes("--force"));
    assert.deepEqual(operations.map(call => call.at(-1)), [fixture.paths.helper, fixture.paths.extension, fixture.paths.app]);
    assert.equal(fixture.calls.filter(call => call.includes("--verify")).length, 2);
    for (const operation of operations) {
        assert.ok(!operation.includes("--deep"));
        assert.ok(operation.includes("--preserve-metadata=identifier,requirements,flags,runtime,launch-constraints,library-constraints"));
        assert.ok(operation.includes("--timestamp=none"));
    }
    for (const role of ["helper", "extension", "app"]) {
        assert.deepEqual(fixture.signed.get(role), {...originalEntitlements(role), [fileAccess]: [`${root}/`]});
    }
    assert.deepEqual(result, {mode: "apple", policy: "production-entitlements-with-fixture-file-access", fixtureAccessRoot: `${root}/`,
        originalIdentitiesPreserved: true, originalEntitlementsPreserved: true,
        products: ["helper", "extension", "app"].map(role => ({role, identity: identity(role)}))});
});

test("Invalid original signatures, certificates, or sandbox entitlements prevent re-signing", async context => {
    for (const options of [
        {failVerification: "initial"},
        {certificate: () => Buffer.alloc(0)},
        {certificate: () => Buffer.alloc(1024 * 1024 + 1)},
        {original: role => ({...originalEntitlements(role), "com.apple.security.app-sandbox": false})},
    ]) {
        const fixture = await signingFixture(context, options);
        await assert.rejects(fixture.run());
        assert.equal(fixture.calls.filter(call => call.includes("--force")).length, 0);
    }
});

test("A changed identity or entitlement after signing prevents signing the enclosing products", async context => {
    for (const options of [
        {certificate: (role, verified) => verified ? Buffer.from("different-identity") : certificate(role)},
        {verified: (_role, value) => ({...value, "keychain-access-groups": []})},
        {verified: (_role, value) => ({...value, [fileAccess]: ["/"]})},
    ]) {
        const fixture = await signingFixture(context, options);
        await assert.rejects(fixture.run(), /did not preserve/);
        assert.deepEqual(fixture.calls.filter(call => call.includes("--force")).map(call => call.at(-1)), [fixture.paths.helper]);
    }
});

test("Signing failures and final bundle verification failures remain failures", async context => {
    for (const options of [{failSigning: "extension"}, {failVerification: "final"}]) {
        const fixture = await signingFixture(context, options);
        await assert.rejects(fixture.run(), /Injected/);
        if (options.failSigning) {
            assert.equal(fixture.calls.filter(call => call.includes("--force") && call.at(-1) === fixture.paths.app).length, 0);
        }
    }
});

test("A signing directory cannot overwrite artifacts from an earlier attempt", async context => {
    const fixture = await signingFixture(context);
    await fixture.run();
    const signed = fixture.calls.filter(call => call.includes("--force")).length;
    await assert.rejects(fixture.run(), {code: "EEXIST"});
    assert.equal(fixture.calls.filter(call => call.includes("--force")).length, signed);
});

test("Extension metadata comes from the actual platform bundle with bounded read-only inspection", async () => {
    for (const platform of ["macos", "ios"]) {
        const metadata = await readExtensionMetadata("/fixture/Safari.appex", platform, async (executable, args, options) => {
            assert.equal(executable, "/usr/bin/plutil");
            assert.deepEqual(args, ["-convert", "json", "-o", "-", `/fixture/Safari.appex/${platform === "macos" ? "Contents/" : ""}Info.plist`]);
            assert.deepEqual(options, {capture: true, maximumBytes: 65536, timeoutSeconds: 15});
            return JSON.stringify({CFBundleIdentifier: "org.lil.wallet.Safari", CFBundleShortVersionString: "1.2.3", CFBundleVersion: "45",
                CFBundleName: "Safari", CFBundleDisplayName: "Big Wallet", NSExtension: {NSExtensionPointIdentifier: "com.apple.Safari.web-extension"}});
        });
        assert.deepEqual(metadata, {bundleIdentifier: "org.lil.wallet.Safari", version: "1.2.3", build: "45", name: "Safari", displayName: "Big Wallet",
            extensionPointIdentifier: "com.apple.Safari.web-extension"});
    }
    for (const info of [null, {}, {CFBundleIdentifier: "other.extension", CFBundleShortVersionString: "1", CFBundleVersion: "1"},
        {CFBundleIdentifier: "org.lil.wallet.Safari", CFBundleShortVersionString: " ", CFBundleVersion: "1"},
        {CFBundleIdentifier: "org.lil.wallet.Safari", CFBundleShortVersionString: "1", CFBundleVersion: 1},
        {CFBundleIdentifier: "org.lil.wallet.Safari", CFBundleShortVersionString: "1", CFBundleVersion: "a".repeat(257)},
        {CFBundleIdentifier: "org.lil.wallet.Safari", CFBundleShortVersionString: "1", CFBundleVersion: "1\u0001"}]) {
        await assert.rejects(readExtensionMetadata("/fixture/Safari.appex", "macos", async () => JSON.stringify(info)), /metadata is invalid/);
    }
    await assert.rejects(readExtensionMetadata("/fixture/Safari.appex", "macos", async () => "invalid plist"), SyntaxError);
});

test("Guest macOS evidence requires actual bounded version and build probes", async () => {
    const probes = [];
    const runtime = await readMacOSRuntime(async (executable, args, options) => {
        assert.equal(executable, "/usr/bin/sw_vers");
        assert.deepEqual(options, {capture: true, maximumBytes: 1024, timeoutSeconds: 15});
        probes.push(args);
        return args[0] === "-productVersion" ? "27.0.1\n" : "26A123\n";
    });
    assert.deepEqual(probes, [["-productVersion"], ["-buildVersion"]]);
    assert.deepEqual(runtime, {macOS: {version: "27.0.1", build: "26A123"}});
    for (const [version, build] of [["", "26A123"], ["macOS 27.0", "26A123"], ["1".repeat(129), "26A123"],
        ["27.0", ""], ["27.0", "26A123\nother"], ["27.0", "A".repeat(129)]]) {
        await assert.rejects(readMacOSRuntime(async (_executable, args) => args[0] === "-productVersion" ? version : build), /runtime metadata is invalid/);
    }
});

test("Safari registration diagnostics are read-only, bounded, and retain failures independently", async context => {
    const scratch = await realpath(await mkdtemp(join(tmpdir(), "safari-registration-fixture-")));
    context.after(() => rm(scratch, {recursive: true, force: true}));
    for (const phase of ["registered", "failure"]) {
        const interrupted = phase === "failure";
        const report = await collectSafariRegistration({artifacts: scratch, stageId: "safari.test", phase, interrupted}, async (executable, args, options) => {
            assert.equal(executable, "/usr/bin/pluginkit");
            assert.deepEqual(args, ["-m", "-A", "-D", "-vv", "-i", "org.lil.wallet.Safari"]);
            assert.equal(options.maximumBytes, 1024 * 1024);
            assert.equal(options.captureStderr, true);
            assert.equal(options.timeoutSeconds, interrupted ? 1 : 15);
            if (interrupted) {
                assert.equal(options.terminationGraceMilliseconds, 100);
                assert.equal(options.outputDrainMilliseconds, 100);
                throw Object.assign(new Error("registration probe timed out"), {output: "partial inventory", timedOut: true});
            }
            return "Bearer fixture-secret\n" + "x".repeat(1024 * 1024);
        });
        assert.equal(report.artifact, `safari.test.safari-registration-${phase}.log`);
        const text = await readFile(join(scratch, report.artifact), "utf8");
        if (interrupted) {
            assert.equal(report.status, "incomplete");
            assert.equal(report.timedOut, true);
            assert.equal(text, "partial inventory");
        } else {
            assert.equal(report.status, "collected");
            assert.equal(report.bytes, 1024 * 1024);
            assert.doesNotMatch(text, /fixture-secret/);
        }
    }
    await assert.rejects(collectSafariRegistration({artifacts: scratch, stageId: "safari.test", phase: "enable"}, async () => assert.fail("No mutations may run")), /Invalid/);
});

async function registrationFixture(context) {
    const scratch = await realpath(await mkdtemp(join(tmpdir(), "safari-refresh-fixture-")));
    context.after(() => rm(scratch, {recursive: true, force: true}));
    const app = join(scratch, "Big Wallet.app");
    const extension = join(app, "Contents/PlugIns/Safari macOS.appex");
    const helper = join(extension, "Contents/Helpers/Big Wallet.app");
    const products = {app, extension, helper};
    const sourceApp = join(scratch, "Library/Developer/Xcode/DerivedData/Wallet/Build/Products/Release/Big Wallet.app");
    const sourceExtension = join(sourceApp, "Contents/PlugIns/Safari macOS.appex");
    const sourceProducts = {app: sourceApp, extension: sourceExtension, helper: join(sourceExtension, "Contents/Helpers/Big Wallet.app")};
    const descriptor = {version: 1, runID: "signing-test", platform: "macos", signingMode: "local", configuration: "Release", root};
    const markers = {};
    for (const [role, bundle] of [...Object.entries(products), ...Object.entries(sourceProducts).map(([role, bundle]) => ["source-" + role, bundle])]) {
        const resources = join(bundle, "Contents/Resources");
        await mkdir(resources, {recursive: true});
        markers[role] = join(resources, "SafariVMRun.json");
        await writeFile(markers[role], JSON.stringify(descriptor));
    }
    const artifacts = join(scratch, "artifacts");
    await mkdir(artifacts);
    return {products, sourceProducts, descriptor, artifacts, markers, stageId: "safari.test"};
}

test("Registration refresh rechecks run markers and updates only its bounded latest inventory", async context => {
    const fixture = await registrationFixture(context);
    await collectSafariRegistration({...fixture, phase: "registered"}, async () => "original registration");
    const calls = [];
    let revision = 0;
    for (let index = 0; index < 2; index += 1) {
        const result = await refreshSafariExtensionRegistration(fixture, async (command, args, options) => {
            assert.equal(command, "/usr/bin/pluginkit");
            calls.push(args);
            if (args[0] === "-r") {
                assert.deepEqual(args, ["-r", fixture.sourceProducts.extension]);
                return "";
            }
            if (args[0] === "-a") {
                assert.deepEqual(args, ["-a", fixture.products.extension]);
                assert.deepEqual(options, {capture: true, captureStderr: true, maximumBytes: 64 * 1024, timeoutSeconds: 15});
                revision += 1;
                return "";
            }
            assert.deepEqual(args, ["-m", "-A", "-D", "-vv", "-i", "org.lil.wallet.Safari"]);
            assert.equal(options.maximumBytes, 1024 * 1024);
            return "revision=" + revision + "\n" + "x".repeat(1024 * 1024);
        });
        assert.deepEqual(Object.keys(result).sort(), ["deregisteredExtension", "extension", "registeredAt"]);
        assert.equal(result.deregisteredExtension, fixture.sourceProducts.extension);
        assert.equal(result.extension, fixture.products.extension);
        assert.equal(new Date(result.registeredAt).toISOString(), result.registeredAt);
    }
    assert.equal(calls.length, 6);
    assert.deepEqual((await readdir(fixture.artifacts)).sort(), ["safari.test.safari-registration-refreshed.log", "safari.test.safari-registration-registered.log"]);
    assert.equal(await readFile(join(fixture.artifacts, "safari.test.safari-registration-registered.log"), "utf8"), "original registration");
    const refreshed = await readFile(join(fixture.artifacts, "safari.test.safari-registration-refreshed.log"), "utf8");
    assert.match(refreshed, /^revision=2\n/);
    assert.equal(Buffer.byteLength(refreshed), 1024 * 1024);
});

test("Registration refresh refuses stale markers, other signing modes, and foreign product paths before commands", async context => {
    const fixture = await registrationFixture(context);
    const forbidden = async () => assert.fail("Only current verified local macOS products may be registered");
    for (const marker of Object.values(fixture.markers)) {
        await writeFile(marker, JSON.stringify({...fixture.descriptor, runID: "previous-run"}));
        await assert.rejects(refreshSafariExtensionRegistration(fixture, forbidden), /current VM fixture marker/);
        await writeFile(marker, JSON.stringify(fixture.descriptor));
    }
    for (const descriptor of [{...fixture.descriptor, platform: "ios"}, {...fixture.descriptor, signingMode: "apple"}]) {
        await assert.rejects(refreshSafariExtensionRegistration({...fixture, descriptor}, forbidden), /requires the local macOS fixture/);
    }
    await assert.rejects(refreshSafariExtensionRegistration({...fixture, products: {...fixture.products, extension: "/other/Safari.appex"}}, forbidden), /verified Safari fixture products/);
});

test("Registration refresh preserves its registration failure while still capturing inventory", async context => {
    const fixture = await registrationFixture(context);
    const failure = new Error("Injected registration failure");
    const calls = [];
    await assert.rejects(refreshSafariExtensionRegistration(fixture, async (_command, args) => {
        calls.push(args[0]);
        if (args[0] === "-a") { throw failure; }
        return "inventory after failed registration";
    }), error => error === failure);
    assert.deepEqual(calls, ["-r", "-a", "-m"]);
    assert.equal(await readFile(join(fixture.artifacts, "safari.test.safari-registration-refreshed.log"), "utf8"), "inventory after failed registration");
});

test("registration refresh accepts only the exact already-absent source result before adding the installed extension", async context => {
    const fixture = await registrationFixture(context);
    for (const exitCode of [1, 2]) {
        const calls = [];
        const failure = Object.assign(new Error("pluginkit failed"), {
            exitCode, signal: null, output: "remove: no plugin at " + fixture.sourceProducts.extension + "\n",
        });
        const refresh = refreshSafariExtensionRegistration(fixture, async (command, args) => {
            assert.equal(command, "/usr/bin/pluginkit");
            calls.push(args[0]);
            if (args[0] === "-r") { throw failure; }
            return "";
        });
        if (exitCode === 1) {
            assert.equal((await refresh).deregistrationAlreadyAbsent, true);
            assert.deepEqual(calls, ["-r", "-a", "-m"]);
        } else {
            await assert.rejects(refresh, error => error === failure);
            assert.deepEqual(calls, ["-r", "-m"]);
        }
    }
});

test("DerivedData aliases are resolved before exact removal and absent-response comparison", async context => {
    const fixture = await registrationFixture(context);
    const sourceRoot = join(dirname(fixture.artifacts), "Library/Developer/Xcode/DerivedData");
    const aliasRoot = join(dirname(fixture.artifacts), "alias-home/Library/Developer/Xcode/DerivedData");
    await mkdir(dirname(aliasRoot), {recursive: true});
    await symlink(sourceRoot, aliasRoot);
    const sourceProducts = Object.fromEntries(Object.entries(fixture.sourceProducts).map(([role, path]) => [role, path.replace(sourceRoot, aliasRoot)]));
    assert.notEqual(sourceProducts.extension, fixture.sourceProducts.extension);
    const absent = output => Object.assign(new Error("pluginkit failed with exit code 1"), {exitCode: 1, signal: null, output});
    const command = async (executable, args) => {
        assert.equal(executable, "/usr/bin/pluginkit");
        if (args[0] === "-r") {
            assert.deepEqual(args, ["-r", fixture.sourceProducts.extension]);
            throw absent("remove: no plugin at " + fixture.sourceProducts.extension + "\n");
        }
        assert.ok(["-a", "-m"].includes(args[0]));
        return "";
    };
    const removal = await deregisterSafariExtension({products: sourceProducts}, command);
    assert.equal(removal.status, "passed");
    assert.equal(removal.alreadyAbsent, true);
    assert.equal(removal.extension, sourceProducts.extension);
    assert.equal(removal.resolvedExtension, fixture.sourceProducts.extension);
    assert.deepEqual(removal.arguments, ["-r", fixture.sourceProducts.extension]);
    const refreshed = await refreshSafariExtensionRegistration({...fixture, sourceProducts}, command);
    assert.equal(refreshed.deregistrationAlreadyAbsent, true);
    assert.equal(refreshed.deregisteredExtension, fixture.sourceProducts.extension);
    const mismatched = await deregisterSafariExtension({products: sourceProducts}, async () => {
        throw absent("remove: no plugin at " + sourceProducts.extension + "\n");
    });
    assert.equal(mismatched.status, "failed");
    assert.equal(mismatched.alreadyAbsent, undefined);
});

async function installationFixture(context) {
    const fixture = await registrationFixture(context);
    const home = join(dirname(fixture.artifacts), "guest-home");
    await mkdir(home, {mode: 0o700});
    const sourceBytes = Buffer.from("unchanged complete signed fixture payload");
    await writeFile(join(fixture.sourceProducts.app, "signed-payload.bin"), sourceBytes);
    const calls = [];
    const command = async (executable, args, options) => {
        calls.push([executable, ...args]);
        if (executable === "/usr/bin/ditto") {
            assert.deepEqual(args.slice(0, 3), ["--rsrc", "--extattr", "--acl"]);
            assert.equal(args[3], fixture.sourceProducts.app);
            assert.equal(options.timeoutSeconds, 120);
            await cp(args[3], args[4], {recursive: true, dereference: false, preserveTimestamps: true, errorOnExist: true, force: false});
            return "";
        }
        assert.equal(executable, "/usr/bin/codesign");
        assert.deepEqual(args.slice(0, 4), ["--verify", "--deep", "--strict", args[3]]);
        assert.ok(args[3].startsWith(join(home, "Applications/BigWalletSafariVM") + "/"));
        assert.equal(options.timeoutSeconds, 60);
        return "";
    };
    return {...fixture, home, sourceBytes, calls, command};
}

test("macOS runtime copies complete signed products into an exact private guest stage without changing build sources", async context => {
    const fixture = await installationFixture(context);
    const original = structuredClone(fixture.sourceProducts);
    for (const stageId of ["safari.macos.release", "safari.soak-macos.release"]) {
        const installation = safariMacInstallation(fixture.descriptor, stageId, fixture.home);
        const installed = await installSafariMacProducts({products: fixture.sourceProducts, descriptor: fixture.descriptor, installation}, fixture.command);
        assert.equal(installed.app, join(fixture.home, "Applications/BigWalletSafariVM/signing-test", stageId, "Big Wallet.app"));
        assert.equal(installed.extension, join(installed.app, "Contents/PlugIns/Safari macOS.appex"));
        assert.equal(installed.helper, join(installed.extension, "Contents/Helpers/Big Wallet.app"));
        assert.equal(installed.sourceApp, original.app);
        assert.deepEqual(await readFile(join(installed.app, "signed-payload.bin")), fixture.sourceBytes);
        assert.deepEqual(await readFile(join(original.app, "signed-payload.bin")), fixture.sourceBytes);
        assert.equal((await stat(installation.directory)).mode & 0o777, 0o700);
        assert.deepEqual(fixture.sourceProducts, original);
        const removal = await removeSafariMacInstallation({descriptor: fixture.descriptor, installation});
        assert.equal(removal.status, "passed");
        await assert.rejects(stat(installation.directory), {code: "ENOENT"});
    }
    assert.equal(fixture.calls.filter(call => call[0] === "/usr/bin/ditto").length, 2);
    assert.ok(fixture.calls.filter(call => call[0] === "/usr/bin/ditto").every(call => call.at(-2) === original.app));
});

test("failed copies or signature validation never fall back to DerivedData and retain verified installation cleanup", async context => {
    for (const failedCommand of ["/usr/bin/ditto", "/usr/bin/codesign"]) {
        const fixture = await installationFixture(context);
        const installation = safariMacInstallation(fixture.descriptor, "safari.macos.release", fixture.home);
        await assert.rejects(installSafariMacProducts({products: fixture.sourceProducts, descriptor: fixture.descriptor, installation}, async (executable, args, options) => {
            await fixture.command(executable, args, options);
            if (executable === failedCommand) { throw new Error("Injected install failure"); }
            return "";
        }), /Injected install failure/);
        assert.equal(installation.created, true);
        assert.equal((await removeSafariMacInstallation({descriptor: fixture.descriptor, installation})).status, "passed");
        await assert.rejects(stat(installation.directory), {code: "ENOENT"});
        assert.deepEqual(await readFile(join(fixture.sourceProducts.app, "signed-payload.bin")), fixture.sourceBytes);
    }
});

test("installation cleanup refuses changed ownership markers and never removes an uncreated stage", async context => {
    const fixture = await installationFixture(context);
    const installation = safariMacInstallation(fixture.descriptor, "safari.macos.release", fixture.home);
    await installSafariMacProducts({products: fixture.sourceProducts, descriptor: fixture.descriptor, installation}, fixture.command);
    const marker = join(installation.directory, ".safari-vm-installation.json");
    const original = await readFile(marker);
    await writeFile(marker, JSON.stringify({version: 1, runID: "another-run"}));
    assert.equal((await removeSafariMacInstallation({descriptor: fixture.descriptor, installation})).status, "failed");
    assert.ok((await stat(installation.directory)).isDirectory());
    await writeFile(marker, original);
    const duplicate = safariMacInstallation(fixture.descriptor, "safari.macos.release", fixture.home);
    await assert.rejects(installSafariMacProducts({products: fixture.sourceProducts, descriptor: fixture.descriptor, installation: duplicate}, fixture.command), {code: "EEXIST"});
    assert.equal((await removeSafariMacInstallation({descriptor: fixture.descriptor, installation: duplicate})).status, "not-created");
    assert.ok((await stat(installation.directory)).isDirectory());
    assert.equal((await removeSafariMacInstallation({descriptor: fixture.descriptor, installation})).status, "passed");
});

test("unsigned Safari recovery rebuilds the containing app before replacing and registering its owned copy", async context => {
    const fixture = await installationFixture(context);
    const stageId = "safari.macos.release";
    const installation = safariMacInstallation(fixture.descriptor, stageId, fixture.home);
    const products = await installSafariMacProducts({products: fixture.sourceProducts, descriptor: fixture.descriptor, installation}, fixture.command);
    const calls = [];
    const buildArgs = ["-project", "Wallet.xcodeproj", "-scheme", "Safari UI Tests macOS", "-configuration", "Release", "BW_SAFARI_VM_TESTING=YES"];
    const result = await rebuildSafariMacProducts({...fixture, products, installation, stageId, buildArgs,
        beforeReplace: async () => {
            assert.ok(calls.some(call => call[0] === "xcodebuild"));
            assert.ok(!calls.some(call => call[0] === "/usr/bin/ditto"));
            calls.push(["verified-process-cleanup"]);
        }}, async (executable, args, options) => {
        calls.push([executable, ...args]);
        if (executable === "xcodebuild") {
            assert.deepEqual(args, ["-jobs", "2", "build", "-project", "Wallet.xcodeproj", "-scheme", "Wallet", "-configuration", "Release", "BW_SAFARI_VM_TESTING=YES", "ENABLE_TESTABILITY=YES"]);
            assert.equal(options.timeoutSeconds, 120);
            await writeFile(join(fixture.sourceProducts.app, "signed-payload.bin"), "rebuilt after unsigned permission");
            return "";
        }
        if (executable === "/usr/bin/codesign" && args[0] === "--force") {
            if (args.includes("--entitlements")) {
                assert.match(await readFile(args[args.indexOf("--entitlements") + 1], "utf8"), /signing-test\/safari\/macos\/Release\//);
            }
            return "";
        }
        if (executable === "/usr/bin/codesign" && args.at(-1) === fixture.sourceProducts.app) { return ""; }
        if (executable === "/usr/bin/pluginkit") { return args[0] === "-m" ? "fresh rebuilt registration" : ""; }
        return fixture.command(executable, args, options);
    });
    assert.equal(calls[0][0], "xcodebuild");
    assert.ok(calls.findIndex(call => call[0] === "/usr/bin/ditto") > calls.findIndex(call => call[1] === "--force"));
    assert.ok(calls.findIndex(call => call[0] === "/usr/bin/ditto") > calls.findIndex(call => call[0] === "verified-process-cleanup"));
    assert.ok(calls.findIndex(call => call[0] === "/usr/bin/pluginkit") > calls.findIndex(call => call[0] === "/usr/bin/ditto"));
    assert.equal(await readFile(join(products.app, "signed-payload.bin"), "utf8"), "rebuilt after unsigned permission");
    assert.equal(result.workaround, "macOS-27-183044008");
    assert.equal(result.extension, products.extension);
    assert.equal(result.deregisteredExtension, fixture.sourceProducts.extension);
    assert.equal(new Date(result.rebuiltAt).toISOString(), result.rebuiltAt);
    assert.equal((await removeSafariMacInstallation({descriptor: fixture.descriptor, installation})).status, "passed");
});

test("unsigned Safari rebuild refuses changed ownership and preserves the installed copy on build failure", async context => {
    const fixture = await installationFixture(context);
    const stageId = "safari.macos.release";
    const installation = safariMacInstallation(fixture.descriptor, stageId, fixture.home);
    const products = await installSafariMacProducts({products: fixture.sourceProducts, descriptor: fixture.descriptor, installation}, fixture.command);
    const input = {...fixture, products, installation, stageId, buildArgs: ["-scheme", "Safari UI Tests macOS"]};
    const marker = join(installation.directory, ".safari-vm-installation.json");
    const original = await readFile(marker);
    await writeFile(marker, JSON.stringify({version: 1, runID: "another-run"}));
    await assert.rejects(rebuildSafariMacProducts(input, async () => assert.fail("Changed ownership must prevent commands")), /ownership marker changed/);
    await writeFile(marker, original);
    const calls = [];
    await assert.rejects(rebuildSafariMacProducts(input, async (command, args) => {
        calls.push([command, ...args]);
        throw new Error("Injected rebuild failure");
    }), /Injected rebuild failure/);
    assert.equal(calls.length, 1);
    assert.equal(calls[0][0], "xcodebuild");
    assert.deepEqual(await readFile(join(products.app, "signed-payload.bin")), fixture.sourceBytes);
    await assert.rejects(rebuildSafariMacProducts({...input, deadline: Date.now() - 1}, async () => assert.fail("Expired rebuilds must not execute commands")), /rebuild deadline/);
    await assert.rejects(rebuildSafariMacProducts({...input, beforeReplace: async () => { throw new Error("Owned extension restarted"); }}, async () => ""), /Owned extension restarted/);
    assert.deepEqual(await readFile(join(products.app, "signed-payload.bin")), fixture.sourceBytes);
    assert.equal((await removeSafariMacInstallation({descriptor: fixture.descriptor, installation})).status, "passed");
});

test("Safari code-signing diagnostics inspect only verified product paths and preserve signature output", async context => {
    const artifacts = await realpath(await mkdtemp(join(tmpdir(), "safari-code-signing-fixture-")));
    context.after(() => rm(artifacts, {recursive: true, force: true}));
    const calls = [];
    const command = async (executable, args, options) => {
        calls.push(args);
        assert.equal(executable, "/usr/bin/codesign");
        assert.deepEqual(options, {capture: true, captureStderr: true, maximumBytes: 64 * 1024, timeoutSeconds: 15});
        assert.ok(Object.values(diagnosticProducts).includes(args.at(-1)));
        if (args[0] === "--verify") {
            assert.deepEqual(args.slice(0, -1), ["--verify", "--deep", "--strict"]);
            return "valid on disk\n";
        }
        assert.deepEqual(args.slice(0, -1), ["--display", "--verbose=4", "--entitlements", ":-"]);
        return "Signature=adhoc\n<plist><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>\n";
    };
    const report = await collectSafariCodeSigning({products: diagnosticProducts, artifacts, stageId: "safari.test", phase: "before-tests"}, command);
    assert.equal(report.status, "collected");
    assert.equal(report.artifact, "safari.test.safari-code-signing-before-tests.json");
    assert.equal(calls.length, 6);
    const contents = await readFile(join(artifacts, report.artifact));
    assert.equal(contents.length, report.bytes);
    const saved = JSON.parse(contents);
    assert.equal(saved.phase, "before-tests");
    assert.deepEqual(saved.products.map(product => product.role), ["app", "extension", "helper"]);
    for (const product of saved.products) {
        assert.equal(product.bundle, diagnosticProducts[product.role]);
        assert.deepEqual(product.probes.map(probe => probe.operation), ["verify", "display"]);
        assert.ok(product.probes.every(probe => probe.status === "passed" && probe.truncated === false));
        assert.match(product.probes[1].output, /Signature=adhoc/);
    }
    await assert.rejects(collectSafariCodeSigning({products: diagnosticProducts, artifacts, stageId: "safari.test", phase: "before-tests"}, command), {code: "EEXIST"});
    assert.deepEqual(await readFile(join(artifacts, report.artifact)), contents);
    for (const products of [undefined, {}, {...diagnosticProducts, helper: "/unrelated/Big Wallet.app"},
        {...diagnosticProducts, extension: "/unrelated/Safari.appex"}]) {
        await assert.rejects(collectSafariCodeSigning({products, artifacts, stageId: "invalid", phase: "failure"}, async () => assert.fail("Invalid product must not be inspected")), /verified Safari fixture products/);
    }
});

test("Safari code-signing failures are bounded, redacted, and do not suppress other product probes", async context => {
    const artifacts = await realpath(await mkdtemp(join(tmpdir(), "safari-code-signing-failure-")));
    context.after(() => rm(artifacts, {recursive: true, force: true}));
    let calls = 0;
    const report = await collectSafariCodeSigning({products: diagnosticProducts, artifacts, stageId: "safari.test", phase: "failure",
        secrets: ["controller-secret-fixture"], interrupted: true}, async (executable, _args, options) => {
        assert.equal(executable, "/usr/bin/codesign");
        assert.deepEqual(options, {capture: true, captureStderr: true, maximumBytes: 64 * 1024, timeoutSeconds: 1,
            terminationGraceMilliseconds: 100, outputDrainMilliseconds: 100});
        calls += 1;
        if (calls === 1) {
            throw Object.assign(new Error("invalid signature controller-secret-fixture " + "x".repeat(8192)),
                {output: "partial metadata controller-secret-fixture", timedOut: true, truncated: true});
        }
        return "Bearer header-secret-fixture controller-secret-fixture\n" + "✓".repeat(64 * 1024);
    });
    assert.equal(calls, 6);
    assert.equal(report.status, "incomplete");
    const contents = await readFile(join(artifacts, report.artifact), "utf8");
    assert.doesNotMatch(contents, /controller-secret-fixture|header-secret-fixture/);
    assert.ok(Buffer.byteLength(contents) < 4 * 1024 * 1024);
    const saved = JSON.parse(contents);
    const first = saved.products[0].probes[0];
    assert.equal(first.status, "failed");
    assert.equal(first.timedOut, true);
    assert.match(first.output, /partial metadata/);
    assert.ok(Buffer.byteLength(first.reason) <= 4096);
    assert.ok(saved.products.flatMap(product => product.probes).every(probe => probe.truncated && Buffer.byteLength(probe.output) <= 64 * 1024));
});

function processFixture(action) {
    const child = new EventEmitter();
    child.pid = 123456;
    child.stdout = new PassThrough();
    child.stderr = new PassThrough();
    const signals = [];
    return {child, signals, options: {
        spawnProcess: (_command, _args, options) => {
            assert.equal(options.detached, true);
            queueMicrotask(() => action?.(child));
            return child;
        },
        signalGroup: (pid, signal) => { assert.equal(pid, child.pid); signals.push(signal); },
        outputStreams: {stdout: new PassThrough(), stderr: new PassThrough()},
        terminationGraceMilliseconds: 1, outputDrainMilliseconds: 1,
    }};
}

test("Subprocess deadlines distinguish builds, settings probes, and tests", () => {
    assert.equal(commandTimeoutSeconds("/usr/bin/plutil", []), 60);
    assert.equal(commandTimeoutSeconds("xcodebuild", ["-showBuildSettings", "-json"]), 120);
    assert.equal(commandTimeoutSeconds("xcodebuild", ["build-for-testing"]), 3600);
    assert.equal(commandTimeoutSeconds("/usr/bin/xcodebuild", ["test-without-building"]), 7200);
});

test("Safari test default and maximum allowances scale together within unchanged stage deadlines", () => {
    for (const [iterations, allowance, timeoutSeconds] of [[1, "600", 7200], [10, "6000", 21600]]) {
        assert.deepEqual(safariTestTimeouts(iterations), {
            args: ["-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", allowance,
                "-maximum-test-execution-time-allowance", allowance],
            timeoutSeconds,
        });
    }
    for (const iterations of [0, 2, 100, Infinity]) {
        assert.throws(() => safariTestTimeouts(iterations), /Invalid Safari test iteration count/);
    }
});

test("Command capture closes inherited pipes and removes cancellation handlers", async () => {
    const before = [process.listenerCount("SIGTERM"), process.listenerCount("SIGINT")];
    const fixture = processFixture(child => {
        child.stdout.write("out");
        child.stderr.write("err");
        child.emit("exit", 0, null);
    });
    const output = await execute("fixture-command", [], {...fixture.options, capture: true, captureStderr: true});
    assert.equal(output, "outerr");
    assert.equal(fixture.child.stdout.destroyed, true);
    assert.equal(fixture.child.stderr.destroyed, true);
    assert.deepEqual(fixture.signals, []);
    assert.deepEqual([process.listenerCount("SIGTERM"), process.listenerCount("SIGINT")], before);
});

test("Command capture preserves split UTF-8 bytes and independently forwards uncaptured stderr", async () => {
    const stderr = new PassThrough();
    const forwarded = [];
    stderr.on("data", value => forwarded.push(Buffer.from(value)));
    const fixture = processFixture(child => {
        const bytes = Buffer.from("€");
        child.stdout.write(bytes.subarray(0, 1));
        child.stderr.write("diagnostic");
        child.stdout.write(bytes.subarray(1));
        child.emit("exit", 0, null);
        child.emit("close", 0, null);
    });
    const output = await execute("fixture-command", [], {...fixture.options, capture: true,
        outputStreams: {...fixture.options.outputStreams, stderr}});
    assert.equal(output, "€");
    assert.equal(Buffer.concat(forwarded).toString("utf8"), "diagnostic");
    assert.deepEqual(fixture.signals, []);
});

test("Uncaptured command output pauses until the destination drains and removes its listeners", async () => {
    let started, completeWrite;
    const ready = new Promise(resolve => { started = resolve; });
    const forwarded = [];
    const stdout = new Writable({highWaterMark: 1, write(chunk, _encoding, callback) {
        forwarded.push(Buffer.from(chunk));
        completeWrite = callback;
        started();
    }});
    const fixture = processFixture(child => child.stdout.write("forwarded"));
    const operation = execute("fixture-command", [], {...fixture.options,
        outputStreams: {...fixture.options.outputStreams, stdout}});
    await ready;
    assert.equal(fixture.child.stdout.isPaused(), true);
    completeWrite();
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(fixture.child.stdout.isPaused(), false);
    fixture.child.emit("exit", 0, null);
    fixture.child.emit("close", 0, null);
    assert.equal(await operation, "");
    assert.equal(Buffer.concat(forwarded).toString("utf8"), "forwarded");
    assert.equal(stdout.listenerCount("drain"), 0);
    assert.equal(stdout.listenerCount("error"), 0);
});

test("Destination write failures terminate the group and retain the first diagnostic", async () => {
    const stdout = new Writable({write(_chunk, _encoding, callback) { callback(new Error("fixture output failure")); }});
    const fixture = processFixture(child => child.stdout.write("forwarded"));
    await assert.rejects(execute("fixture-command", [], {...fixture.options,
        outputStreams: {...fixture.options.outputStreams, stdout}}), error => {
        assert.match(error.message, /log output failed: fixture output failure/);
        assert.equal(error.signal, "SIGKILL");
        return true;
    });
    assert.deepEqual(fixture.signals, ["SIGTERM", "SIGKILL"]);
    assert.equal(stdout.listenerCount("error"), 0);
});

test("Oversized command output is capped and terminates the entire owned process group", async () => {
    const fixture = processFixture(child => child.stdout.write(Buffer.alloc(256, "x")));
    await assert.rejects(execute("fixture-command", [], {...fixture.options, capture: true, maximumBytes: 32}), error => {
        assert.equal(error.truncated, true);
        assert.equal(Buffer.byteLength(error.output), 32);
        return true;
    });
    assert.deepEqual(fixture.signals, ["SIGTERM", "SIGKILL"]);
});

test("A hung command cannot survive its deadline by ignoring termination or retaining pipes", async () => {
    const fixture = processFixture();
    await assert.rejects(execute("fixture-command", [], {...fixture.options, timeoutSeconds: 0.005}), error => error.timedOut === true);
    assert.deepEqual(fixture.signals, ["SIGTERM", "SIGKILL"]);
    assert.equal(fixture.child.stdout.destroyed, true);
});

test("Subprocess failure preserves actual automation errors while redacting credential text", async () => {
    const secret = "fixture-proof-secret";
    const fixture = processFixture(child => {
        child.stderr.write(`error: Failed to enable UI automation mode; ${secret}\n`);
        child.emit("exit", 65, null);
        child.emit("close", 65, null);
    });
    await assert.rejects(execute("xcodebuild", ["test-without-building"], {...fixture.options, env: {ALCHEMY_JWT_REQUEST_PROOF_KEY: secret}}), error => {
        assert.equal(error.exitCode, 65);
        assert.equal(error.signal, null);
        assert.match(error.message, /exit code 65/);
        assert.match(error.message, /Failed to enable UI automation mode/);
        assert.doesNotMatch(error.message, new RegExp(secret));
        return true;
    });
});

test("an observed exit-one absence response is successful exact-path cleanup through command execution", async context => {
    const {products: diagnosticProducts} = await registrationFixture(context);
    const output = "remove: no plugin at " + diagnosticProducts.extension + "\n";
    const fixture = processFixture(child => {
        child.stderr.write(output);
        child.emit("exit", 1, null);
        child.emit("close", 1, null);
    });
    const result = await deregisterSafariExtension({products: diagnosticProducts}, async (command, args, options) => {
        assert.equal(command, "/usr/bin/pluginkit");
        assert.deepEqual(args, ["-r", diagnosticProducts.extension]);
        return execute(command, args, {...options, ...fixture.options});
    });
    assert.equal(result.status, "passed");
    assert.equal(result.alreadyAbsent, true);
    assert.equal(result.exitCode, 1);
    assert.equal(result.output, output);
    assert.deepEqual(fixture.signals, []);
});

test("deregistration never accepts near-matching absence text or an abnormal command outcome", async context => {
    const {products: diagnosticProducts} = await registrationFixture(context);
    const exact = "remove: no plugin at " + diagnosticProducts.extension + "\n";
    const failures = [
        {exitCode: 0}, {exitCode: 2}, {exitCode: "1"}, {exitCode: undefined},
        {signal: "SIGTERM"}, {signal: undefined}, {timedOut: true}, {cancelled: true}, {truncated: true},
        {output: exact.trimEnd()}, {output: exact + "\n"}, {output: "warning\n" + exact},
        {output: "remove: no plugin at /other/Safari.appex\n"}, {output: ""},
    ];
    for (const change of failures) {
        const result = await deregisterSafariExtension({products: diagnosticProducts}, async () => {
            throw Object.assign(new Error("pluginkit failed"), {exitCode: 1, signal: null, output: exact, ...change});
        });
        assert.equal(result.status, "failed");
        assert.equal(result.alreadyAbsent, undefined);
    }
});

test("Failure diagnostics select fixture products, redact tokens, and cap the artifact", async context => {
    const scratch = await realpath(await mkdtemp(join(tmpdir(), "safari-diagnostics-fixture-")));
    context.after(() => rm(scratch, {recursive: true, force: true}));
    const path = "/fixture/Big Wallet.app/Contents/MacOS/Big Wallet";
    const extension = "/fixture/Big Wallet.app/Contents/PlugIns/Safari macOS.appex";
    const server = {token: "fixture-controller-token", pageToken: "fixture-page-token", allowedExecutables: new Set([path, `${extension}/Contents/MacOS/Safari macOS`])};
    const predicate = safariDiagnosticPredicate("macos", server.allowedExecutables);
    assert.match(predicate, /processImagePath == "\/fixture\/Big Wallet.app\/Contents\/MacOS\/Big Wallet"/);
    assert.match(predicate, /org.lil.wallet.safari-ui-tests.macos/);
    assert.ok(predicate.includes('eventMessage CONTAINS "/fixture/Big Wallet.app"'));
    const registrationIndex = predicate.indexOf('OR ((process == "pkd"');
    assert.ok(predicate.slice(0, registrationIndex).includes(`eventMessage CONTAINS ${JSON.stringify(extension)}`));
    assert.ok(predicate.includes(`((process == "pkd" OR process == "lsd" OR process == "Safari") AND (eventMessage CONTAINS "org.lil.wallet.Safari" OR eventMessage CONTAINS ${JSON.stringify(extension)}))`));
    assert.ok(safariDiagnosticPredicate("macos").includes('((process == "pkd" OR process == "lsd" OR process == "Safari") AND (eventMessage CONTAINS "org.lil.wallet.Safari"))'));
    assert.ok(predicate.endsWith('(process == "Safari" AND subsystem == "com.apple.Safari" AND category == "Extensions")'));
    let called = false;
    const report = await collectSafariDiagnostics({server, platform: "macos", artifacts: scratch, stageId: "safari.test", startedAt: Date.now()}, async (command, args, options) => {
        called = true;
        assert.equal(command, "/usr/bin/log");
        assert.equal(args[args.indexOf("--predicate") + 1], predicate);
        assert.equal(options.timeoutSeconds, 60);
        assert.equal(options.maximumBytes, 8 * 1024 * 1024);
        return `Bearer secret-in-header ${server.token} ${server.pageToken}\n` + "x".repeat(8 * 1024 * 1024);
    });
    assert.equal(called, true);
    assert.equal(report.bytes, 8 * 1024 * 1024);
    const data = await readFile(join(scratch, report.artifact), "utf8");
    assert.doesNotMatch(data, /secret-in-header|fixture-controller-token|fixture-page-token/);
});

test("Cleanup and diagnostics failures preserve the original test failure and partial artifacts", async context => {
    const scratch = await realpath(await mkdtemp(join(tmpdir(), "safari-finalization-fixture-")));
    context.after(() => rm(scratch, {recursive: true, force: true}));
    const artifacts = join(scratch, "artifacts");
    await mkdir(artifacts);
    const descriptorPath = join(scratch, "descriptor.json");
    await writeFile(descriptorPath, '{"runID":"fixture"}');
    await writeFile(join(artifacts, "safari.test.safari.json"), '{"scenarios":[]}');
    const primaryError = new Error("XCTest failed to enable automation");
    const server = {token: "fixture-controller-token", pageToken: "fixture-page-token", allowedExecutables: new Set(),
        close: async () => { throw new Error("cleanup failed"); }, persist: async () => { throw new Error("persistence failed"); }};
    await assert.rejects(finalizeSafariRun({server, descriptorPath, artifacts, stageId: "safari.test", platform: "macos", startedAt: Date.now(), primaryError,
        diagnosticProducts, sourceProducts: sourceDiagnosticProducts},
        async () => { throw Object.assign(new Error("diagnostic collection failed"), {output: "partial diagnostic"}); }), error => error === primaryError);
    assert.equal(await readFile(join(artifacts, "safari.test.safari-run.json"), "utf8"), '{"runID":"fixture"}');
    assert.equal(await readFile(join(artifacts, "safari.test.safari-partial.json"), "utf8"), '{"scenarios":[]}');
    const report = JSON.parse(await readFile(join(artifacts, "safari.test.safari-finalization.json"), "utf8"));
    assert.equal(report.primaryFailure, primaryError.message);
    assert.deepEqual(report.failures.map(failure => failure.operation), ["cleanup", "partial-persistence", "extension-deregistration", "build-extension-deregistration", "cleanup-persistence"]);
    assert.equal(report.extensionDeregistration.status, "failed");
    assert.equal(report.installationRemoval.status, "not-created");
    assert.equal(server.cleanup.status, "failed");
    assert.equal(server.cleanup.reason, "cleanup failed");
    assert.deepEqual(server.cleanup.extensionDeregistration, report.extensionDeregistration);
    assert.equal(report.codeSigning.status, "incomplete");
    const signatures = JSON.parse(await readFile(join(artifacts, report.codeSigning.artifact), "utf8"));
    assert.ok(signatures.products.flatMap(product => product.probes).every(probe => probe.status === "failed" && probe.output === "partial diagnostic"));
    assert.equal(report.registration.status, "incomplete");
    assert.equal(await readFile(join(artifacts, report.registration.artifact), "utf8"), "partial diagnostic");
    assert.equal(report.diagnostics.status, "incomplete");
    assert.equal(await readFile(join(artifacts, report.diagnostics.artifact), "utf8"), "partial diagnostic");
});

async function finalizationFixture(context) {
    const productFixture = await registrationFixture(context);
    const artifacts = await realpath(await mkdtemp(join(tmpdir(), "safari-cleanup-fixture-")));
    context.after(() => rm(artifacts, {recursive: true, force: true}));
    const descriptorPath = join(artifacts, "descriptor.json");
    await writeFile(descriptorPath, '{"runID":"fixture"}');
    const operations = [];
    const server = {token: "fixture-controller-token", pageToken: "fixture-page-token", allowedExecutables: new Set(), cleanup: {status: "pending"},
        async close() { operations.push("stop-owned-processes"); this.cleanup = {status: "passed"}; },
        async persist() {
            operations.push("persist-cleanup");
            await writeFile(join(artifacts, "safari.test.safari.json"), JSON.stringify({cleanup: this.cleanup}));
        }};
    return {artifacts, operations, server,
        options: {server, descriptorPath, artifacts, stageId: "safari.test", platform: "macos", startedAt: Date.now(),
            diagnosticProducts: productFixture.products, sourceProducts: productFixture.sourceProducts},
        report: async () => JSON.parse(await readFile(join(artifacts, "safari.test.safari-finalization.json"), "utf8")),
        sidecar: async () => JSON.parse(await readFile(join(artifacts, "safari.test.safari.json"), "utf8"))};
}

test("Successful macOS finalization deregisters only its verified extension after process cleanup and persists that result", async context => {
    const fixture = await finalizationFixture(context);
    const {diagnosticProducts, sourceProducts: sourceDiagnosticProducts} = fixture.options;
    await finalizeSafariRun(fixture.options, async (executable, args, options) => {
        fixture.operations.push(args[1] === diagnosticProducts.extension ? "deregister" : "deregister-build");
        assert.equal(executable, "/usr/bin/pluginkit");
        assert.ok([diagnosticProducts.extension, sourceDiagnosticProducts.extension].includes(args[1]));
        assert.equal(args[0], "-r");
        assert.deepEqual(options, {capture: true, captureStderr: true, maximumBytes: 64 * 1024, timeoutSeconds: 15});
        return "";
    });
    assert.deepEqual(fixture.operations, ["stop-owned-processes", "deregister", "deregister-build", "persist-cleanup"]);
    const report = await fixture.report();
    assert.equal(report.status, "passed");
    assert.equal(report.extensionDeregistration.status, "passed");
    assert.equal(report.extensionDeregistration.extension, diagnosticProducts.extension);
    const sidecar = await fixture.sidecar();
    assert.equal(sidecar.cleanup.status, "passed");
    assert.deepEqual(sidecar.cleanup.extensionDeregistration, report.extensionDeregistration);
});

test("already-absent exact installed and build registrations persist as successful final cleanup", async context => {
    const fixture = await finalizationFixture(context);
    const {diagnosticProducts, sourceProducts: sourceDiagnosticProducts} = fixture.options;
    await finalizeSafariRun(fixture.options, async (command, args) => {
        assert.equal(command, "/usr/bin/pluginkit");
        assert.equal(args[0], "-r");
        assert.ok([diagnosticProducts.extension, sourceDiagnosticProducts.extension].includes(args[1]));
        throw Object.assign(new Error("pluginkit failed with exit code 1"), {
            exitCode: 1, signal: null, output: "remove: no plugin at " + args[1] + "\n",
        });
    });
    const report = await fixture.report();
    const sidecar = await fixture.sidecar();
    assert.equal(report.status, "passed");
    assert.equal(report.extensionDeregistration.alreadyAbsent, true);
    assert.equal(report.buildExtensionDeregistration.alreadyAbsent, true);
    assert.equal(sidecar.cleanup.status, "passed");
    assert.deepEqual(sidecar.cleanup.extensionDeregistration, report.extensionDeregistration);
});

test("Failure diagnostics finish before extension deregistration and preserve the primary XCTest error", async context => {
    const fixture = await finalizationFixture(context);
    const {diagnosticProducts, sourceProducts: sourceDiagnosticProducts} = fixture.options;
    const primaryError = new Error("Original XCTest failure");
    await assert.rejects(finalizeSafariRun({...fixture.options, primaryError}, async (executable, args) => {
        if (executable === "/usr/bin/codesign") { fixture.operations.push("signature-diagnostic"); return "signature"; }
        if (executable === "/usr/bin/log") { fixture.operations.push("system-diagnostic"); return "system"; }
        assert.equal(executable, "/usr/bin/pluginkit");
        if (args[0] === "-m") { fixture.operations.push("registration-diagnostic"); return "registration"; }
        assert.ok([diagnosticProducts.extension, sourceDiagnosticProducts.extension].includes(args[1]));
        assert.equal(args[0], "-r");
        fixture.operations.push(args[1] === diagnosticProducts.extension ? "deregister" : "deregister-build");
        return "";
    }), error => error === primaryError);
    assert.deepEqual(fixture.operations, ["stop-owned-processes", ...Array(6).fill("signature-diagnostic"),
        "registration-diagnostic", "system-diagnostic", "deregister", "deregister-build", "persist-cleanup"]);
    const report = await fixture.report();
    assert.equal(report.primaryFailure, primaryError.message);
    assert.equal(report.extensionDeregistration.status, "passed");
    assert.equal((await fixture.sidecar()).cleanup.status, "passed");
});

test("Unavailable or mismatched fixture products never cause a deregistration command or a passing cleanup", async context => {
    for (const products of [undefined, {...diagnosticProducts, extension: "/other/Big Wallet.app/Contents/PlugIns/Safari macOS.appex"},
        {app: "/fixture/../other/Big Wallet.app", extension: "/other/Big Wallet.app/Contents/PlugIns/Safari macOS.appex",
            helper: "/other/Big Wallet.app/Contents/PlugIns/Safari macOS.appex/Contents/Helpers/Big Wallet.app"}]) {
        const fixture = await finalizationFixture(context);
        const {sourceProducts: sourceDiagnosticProducts} = fixture.options;
        await assert.rejects(finalizeSafariRun({...fixture.options, diagnosticProducts: products}, async (command, args) => {
            assert.equal(command, "/usr/bin/pluginkit");
            assert.deepEqual(args, ["-r", sourceDiagnosticProducts.extension]);
            fixture.operations.push("deregister-build");
            return "";
        }), /extension-deregistration/);
        assert.deepEqual(fixture.operations, ["stop-owned-processes", "deregister-build", "persist-cleanup"]);
        const report = await fixture.report();
        assert.equal(report.status, "failed");
        assert.equal(report.extensionDeregistration.status, "unavailable");
        assert.equal((await fixture.sidecar()).cleanup.status, "failed");
    }
});

test("Deregistration failures fail the stage with bounded redacted evidence and preserve earlier cleanup failures", async context => {
    for (const priorFailure of [undefined, "Owned helper did not stop"]) {
        const fixture = await finalizationFixture(context);
        const {diagnosticProducts, sourceProducts: sourceDiagnosticProducts} = fixture.options;
        if (priorFailure) {
            fixture.server.close = async function () {
                fixture.operations.push("stop-owned-processes");
                this.cleanup = {status: "failed", reason: priorFailure, retained: "prior evidence"};
                throw new Error(priorFailure);
            };
        }
        await assert.rejects(finalizeSafariRun({...fixture.options, interrupted: true}, async (executable, args, options) => {
            if (executable === "/usr/bin/pluginkit" && args[0] === "-r") {
                assert.ok([diagnosticProducts.extension, sourceDiagnosticProducts.extension].includes(args[1]));
                assert.equal(options.timeoutSeconds, 1);
                throw Object.assign(new Error("Cannot deregister fixture-controller-token"),
                    {output: "fixture-controller-token\n" + "x".repeat(128 * 1024), timedOut: true, truncated: true});
            }
            assert.ok(priorFailure, "Successful test cleanup should not collect failure diagnostics");
            return "";
        }), /extension-deregistration/);
        const report = await fixture.report();
        assert.equal(report.status, "failed");
        assert.equal(report.extensionDeregistration.status, "failed");
        assert.equal(report.extensionDeregistration.timedOut, true);
        assert.ok(report.extensionDeregistration.bytes <= 64 * 1024);
        assert.doesNotMatch(JSON.stringify(report), /fixture-controller-token/);
        const sidecar = await fixture.sidecar();
        assert.equal(sidecar.cleanup.status, "failed");
        assert.deepEqual(sidecar.cleanup.extensionDeregistration, report.extensionDeregistration);
        if (priorFailure) {
            assert.equal(sidecar.cleanup.reason, priorFailure);
            assert.equal(sidecar.cleanup.retained, "prior evidence");
        }
    }
});

test("iOS finalization does not deregister macOS extension products", async context => {
    const fixture = await finalizationFixture(context);
    await finalizeSafariRun({...fixture.options, platform: "ios"}, async () => assert.fail("No macOS cleanup command may run for iOS"));
    assert.deepEqual(fixture.operations, ["stop-owned-processes"]);
    assert.equal((await fixture.report()).extensionDeregistration, undefined);
});

test("finalization deregisters installed and build extensions before removing the verified installation", async context => {
    const fixture = await installationFixture(context);
    const installation = safariMacInstallation(fixture.descriptor, "safari.macos.release", fixture.home);
    const installed = await installSafariMacProducts({products: fixture.sourceProducts, descriptor: fixture.descriptor, installation}, fixture.command);
    const finalized = await finalizationFixture(context);
    const deregistered = [];
    await finalizeSafariRun({...finalized.options, descriptor: fixture.descriptor, installation,
        diagnosticProducts: installed, sourceProducts: fixture.sourceProducts}, async (executable, args) => {
        assert.equal(executable, "/usr/bin/pluginkit");
        assert.equal(args[0], "-r");
        assert.ok((await stat(installation.directory)).isDirectory());
        deregistered.push(args[1]);
        return "";
    });
    assert.deepEqual(deregistered, [installed.extension, fixture.sourceProducts.extension]);
    await assert.rejects(stat(installation.directory), {code: "ENOENT"});
    const report = await finalized.report();
    const sidecar = await finalized.sidecar();
    assert.equal(report.installationRemoval.status, "passed");
    assert.equal(report.buildExtensionDeregistration.status, "passed");
    assert.equal(sidecar.cleanup.status, "passed");
    assert.deepEqual(sidecar.cleanup.installationRemoval, report.installationRemoval);
});

test("finalization retains the installed bundles when process cleanup fails or is unconfirmed", async context => {
    const failure = "Owned Safari fixture processes kept restarting during cleanup";
    for (const outcome of [
        {cleanup: {status: "failed", reason: failure}, error: new Error(failure)},
        {cleanup: {status: "passed"}, error: new Error("")},
        {},
        {cleanup: {status: "pending"}},
        {cleanup: {status: "failed", reason: ""}},
        {cleanup: {status: "failed", reason: failure}, error: new Error(failure), primaryError: new Error("Original XCTest failure")},
    ]) {
        const fixture = await installationFixture(context);
        const installation = safariMacInstallation(fixture.descriptor, "safari.macos.release", fixture.home);
        const installed = await installSafariMacProducts({products: fixture.sourceProducts, descriptor: fixture.descriptor, installation}, fixture.command);
        const marker = join(installation.directory, ".safari-vm-installation.json");
        const markerBytes = await readFile(marker);
        const executables = [];
        for (const role of ["app", "extension", "helper"]) {
            const executable = join(installed[role], "Contents/MacOS", role === "extension" ? "Safari macOS" : "Big Wallet");
            await mkdir(dirname(executable), {recursive: true});
            await writeFile(executable, `fixture ${role}`);
            executables.push([executable, await readFile(executable)]);
        }
        const finalized = await finalizationFixture(context);
        finalized.server.close = async function () {
            this.cleanup = outcome.cleanup;
            if (outcome.error) { throw outcome.error; }
        };
        const deregistered = [];
        await assert.rejects(finalizeSafariRun({...finalized.options, descriptor: fixture.descriptor, installation,
            diagnosticProducts: installed, sourceProducts: fixture.sourceProducts, primaryError: outcome.primaryError}, async (executable, args) => {
            if (executable === "/usr/bin/pluginkit" && args[0] === "-r") { deregistered.push(args[1]); }
            else { assert.ok(["/usr/bin/pluginkit", "/usr/bin/codesign", "/usr/bin/log"].includes(executable)); }
            return "";
        }), error => outcome.primaryError ? error === outcome.primaryError : /Safari finalization failed/.test(error.message));
        assert.deepEqual(deregistered, [installed.extension, fixture.sourceProducts.extension]);
        assert.deepEqual(await readFile(marker), markerBytes);
        for (const [executable, bytes] of executables) {
            assert.equal(await realpath(executable), executable);
            assert.deepEqual(await readFile(executable), bytes);
        }
        const report = await finalized.report();
        const sidecar = await finalized.sidecar();
        assert.equal(report.status, "failed");
        assert.equal(report.primaryFailure, outcome.primaryError?.message);
        assert.ok(report.failures.some(failure => failure.operation === "cleanup"));
        assert.equal(report.installationRemoval.status, "retained");
        assert.equal(report.installationRemoval.directory, installation.directory);
        assert.ok(report.installationRemoval.reason.length > 0);
        assert.equal(sidecar.cleanup.status, "failed");
        assert.ok(sidecar.cleanup.reason.length > 0);
        assert.deepEqual(sidecar.cleanup.installationRemoval, report.installationRemoval);
    }
});

test("a primary XCTest failure still removes the installation after successful process cleanup", async context => {
    const fixture = await installationFixture(context);
    const installation = safariMacInstallation(fixture.descriptor, "safari.macos.release", fixture.home);
    const installed = await installSafariMacProducts({products: fixture.sourceProducts, descriptor: fixture.descriptor, installation}, fixture.command);
    const finalized = await finalizationFixture(context);
    const primaryError = new Error("Original XCTest failure");
    await assert.rejects(finalizeSafariRun({...finalized.options, descriptor: fixture.descriptor, installation,
        diagnosticProducts: installed, sourceProducts: fixture.sourceProducts, primaryError}, async () => ""), error => error === primaryError);
    await assert.rejects(stat(installation.directory), {code: "ENOENT"});
    const report = await finalized.report();
    assert.equal(report.status, "passed");
    assert.equal(report.primaryFailure, primaryError.message);
    assert.equal(report.installationRemoval.status, "passed");
    assert.equal((await finalized.sidecar()).cleanup.status, "passed");
});

test("an installation ownership mismatch fails final cleanup without removing the directory", async context => {
    const fixture = await installationFixture(context);
    const installation = safariMacInstallation(fixture.descriptor, "safari.macos.release", fixture.home);
    const installed = await installSafariMacProducts({products: fixture.sourceProducts, descriptor: fixture.descriptor, installation}, fixture.command);
    await writeFile(join(installation.directory, ".safari-vm-installation.json"), "{}");
    const finalized = await finalizationFixture(context);
    await assert.rejects(finalizeSafariRun({...finalized.options, descriptor: fixture.descriptor, installation,
        diagnosticProducts: installed, sourceProducts: fixture.sourceProducts}, async () => ""), /installation-removal/);
    assert.ok((await stat(installation.directory)).isDirectory());
    assert.equal((await finalized.report()).installationRemoval.status, "failed");
    assert.equal((await finalized.sidecar()).cleanup.status, "failed");
});
