import assert from "node:assert/strict";
import {createHash} from "node:crypto";
import {readFileSync} from "node:fs";
import {mkdir, mkdtemp, readFile, realpath, rm, symlink, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {dirname, join} from "node:path";
import test from "node:test";
import {buildWorkspaceIdentity, captureDerivedDataRoots, captureProductInventory, discoveryProductsDirectory, recordedProductInventory} from "../test_products.mjs";

const appInfo = readFileSync(new URL("./fixtures/xcode27_2_app_derived_data_info.plist", import.meta.url));
const runtimeInfo = readFileSync(new URL("./fixtures/xcode27_2_runtime_derived_data_info.plist", import.meta.url));
const directory = "/Users/fixture/Library/Developer/Xcode/DerivedData";
const rootRecord = (name, bytes, canonicalDirectory = directory) => ({name, path: join(canonicalDirectory, name), infoPlist: {
    path: join(canonicalDirectory, name, "info.plist"), bytes: bytes.length,
    sha256: createHash("sha256").update(bytes).digest("hex"), base64: bytes.toString("base64"),
}});

test("captured Date-bearing metadata binds app and package builds without guessing root names", () => {
    const roots = {directory, canonicalDirectory: directory, roots: [rootRecord("opaque-one", appInfo), rootRecord("opaque-two", runtimeInfo)]};
    const build = {directory, canonicalDirectory: directory, cwd: "/fixture/big-wallet", command: ["xcodebuild", "build-for-testing", "-project", "Wallet.xcodeproj"]};
    assert.equal(discoveryProductsDirectory(roots, build), `${directory}/opaque-one/Build/Products`);
    const runtime = {...build, cwd: "/fixture/big-wallet/Packages/WalletRuntime", command: ["xcodebuild", "build-for-testing", "-scheme", "WalletRuntime-Package"]};
    assert.equal(discoveryProductsDirectory(roots, runtime), `${directory}/opaque-two/Build/Products`);
    assert.throws(() => discoveryProductsDirectory(roots, {...runtime, cwd: "/fixture/other/WalletRuntime"}), /found 0/);
    const duplicate = {...roots, roots: [...roots.roots, rootRecord("unrelated-name", runtimeInfo)]};
    assert.throws(() => discoveryProductsDirectory(duplicate, runtime), /found 2/);
    const changedDate = {...roots, roots: [rootRecord("opaque-one", Buffer.from(appInfo.toString().replace("16:04:36", "16:04:37")))]};
    assert.equal(discoveryProductsDirectory(changedDate, build), `${directory}/opaque-one/Build/Products`);
    for (const mutate of [
        value => { value.roots[0].infoPlist.sha256 = "a".repeat(64); },
        value => { value.roots[0].infoPlist.base64 += " "; },
        value => { value.roots[0].infoPlist.bytes += 1; },
        value => { value.roots[0].path = "/outside"; },
        value => { value.roots[0].infoPlist.path = "/outside/info.plist"; },
        value => { value.roots.push(value.roots[0]); },
    ]) {
        const changed = structuredClone(roots);
        mutate(changed);
        assert.throws(() => discoveryProductsDirectory(changed, build), /identity|evidence/i);
    }
});

test("build workspace identity uses the actual container argument or package cwd", () => {
    const cwd = "/fixture/big-wallet";
    const base = ["xcodebuild", "build-for-testing"];
    assert.equal(buildWorkspaceIdentity(base, cwd), cwd);
    assert.equal(buildWorkspaceIdentity([...base, "-project", "Wallet.xcodeproj"], cwd), `${cwd}/Wallet.xcodeproj`);
    assert.equal(buildWorkspaceIdentity([...base, "-workspace", `${cwd}/Wallet.xcworkspace`], cwd), `${cwd}/Wallet.xcworkspace`);
    for (const args of [["-project"], ["-project", "../Other.xcodeproj"], ["-project", "Wallet.xcodeproj", "-workspace", "Wallet.xcworkspace"],
        ["-project", "Wallet.xcodeproj", "-project", "Other.xcodeproj"], ["-derivedDataPath", "/tmp/products"]]) {
        assert.throws(() => buildWorkspaceIdentity([...base, ...args], cwd));
    }
});

async function fixture(platform, run) {
    const root = await realpath(await mkdtemp(join(tmpdir(), "wallet-test-products-")));
    const directory = join(root, "Library/Developer/Xcode/DerivedData");
    const products = join(directory, "Wallet/Build/Products");
    const configuration = join(products, platform === "macos" ? "Debug" : "Debug-iphonesimulator");
    const testBundle = join(configuration, "AuthorityTests.xctest");
    const host = join(configuration, "Big Wallet.app");
    const framework = join(configuration, "PackageFrameworks/WalletAuthority.framework");
    const embedded = join(testBundle, platform === "macos" ? "Contents/Frameworks/WalletAuthority.framework" : "Frameworks/WalletAuthority.framework");
    const write = async (path, value) => {
        await mkdir(dirname(path), {recursive: true});
        await writeFile(path, value);
    };
    for (const [bundle, name] of [[testBundle, "AuthorityTests"], [host, "Big Wallet"]]) {
        await write(join(bundle, platform === "macos" ? "Contents/Info.plist" : "Info.plist"), JSON.stringify({CFBundleExecutable: name}));
        const executable = join(bundle, platform === "macos" ? "Contents/MacOS" : "", name);
        await write(executable, "binary");
        await write(executable + ".debug.dylib", "debug binary");
    }
    for (const bundle of [framework, embedded]) {
        if (platform === "macos") {
            await write(join(bundle, "Versions/A/Resources/Info.plist"), JSON.stringify({CFBundleExecutable: "WalletAuthority"}));
            await write(join(bundle, "Versions/A/WalletAuthority"), "framework binary");
            await symlink("Versions/A/Resources", join(bundle, "Resources"));
            await symlink("Versions/A/WalletAuthority", join(bundle, "WalletAuthority"));
        } else {
            await write(join(bundle, "Info.plist"), JSON.stringify({CFBundleExecutable: "WalletAuthority"}));
            await write(join(bundle, "WalletAuthority"), "framework binary");
        }
    }
    const location = {directory, canonicalDirectory: directory};
    const bindings = [{target: "AuthorityTests", bundle: testBundle, host}];
    const policy = {configuration: "Debug", platform};
    const capture = () => captureProductInventory(products, bindings, policy, async path => JSON.parse(await readFile(path)));
    const replay = metadata => recordedProductInventory(products, bindings, policy, metadata);
    try { await run({root, products, configuration, testBundle, host, framework, embedded, location, bindings, policy, capture, replay, write}); }
    finally { await rm(root, {recursive: true, force: true}); }
}

test("DerivedData diagnostics retain raw property lists containing dates", async () => fixture("macos", async value => {
    const info = '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>' +
        '<key>WorkspacePath</key><string>/fixture/Wallet.xcodeproj/project.xcworkspace</string>' +
        '<key>LastAccessedDate</key><date>2026-11-14T00:00:00Z</date></dict></plist>';
    const infoPath = join(value.location.directory, "Wallet/info.plist");
    await value.write(infoPath, info);
    await mkdir(join(value.location.directory, "ModuleCache.noindex"));
    const seen = [];
    const captured = await captureDerivedDataRoots(value.location, async path => {
        seen.push(path);
        return readFile(path);
    });
    assert.deepEqual(captured, {...value.location, roots: [{name: "Wallet", path: join(value.location.directory, "Wallet"), infoPlist: {
        path: infoPath, bytes: Buffer.byteLength(info), sha256: createHash("sha256").update(info).digest("hex"),
        base64: Buffer.from(info).toString("base64"),
    }}]});
    assert.equal(Buffer.from(captured.roots[0].infoPlist.base64, "base64").toString(), info);
    assert.deepEqual(seen, [join(value.location.directory, "Wallet/info.plist")]);
    await value.write(join(value.location.directory, "Wallet/info.plist"), "x".repeat(64 * 1024 + 1));
    await assert.rejects(captureDerivedDataRoots(value.location, async () => assert.fail("Oversized metadata must not be read")), /oversized/);
}));

test("DerivedData diagnostics reject redirected roots and metadata files", async () => fixture("macos", async value => {
    const alias = join(value.location.directory, "Redirected");
    await symlink(join(value.location.directory, "Wallet"), alias);
    await assert.rejects(captureDerivedDataRoots(value.location, async () => ({})), /root may not be a symlink/);
    await rm(alias);
    const outside = join(value.root, "outside.plist");
    await value.write(outside, JSON.stringify({WorkspacePath: "/outside"}));
    await symlink(outside, join(value.location.directory, "Wallet/info.plist"));
    await assert.rejects(captureDerivedDataRoots(value.location, async () => ({})), /Unsafe/);
}));

for (const platform of ["macos", "ios"]) {
    test(`${platform} metadata captures and rederives every executable, debug library and built/embedded framework`, async () => fixture(platform, async value => {
        const {products, metadata} = await value.capture();
        assert.equal(products.length, 6);
        assert.equal(products.filter(product => product.role === "framework").length, 2);
        assert.equal(products.filter(product => product.path.endsWith(".debug.dylib")).length, 2);
        assert.deepEqual(await value.replay(metadata), products);
        assert.ok(metadata.directories.some(directory => directory.entries === null));
        for (const collection of ["directories", "bundles"]) {
            const missing = structuredClone(metadata);
            missing[collection].pop();
            await assert.rejects(value.replay(missing), /Missing XCTest/);
            const duplicate = structuredClone(metadata);
            duplicate[collection].push(duplicate[collection][0]);
            await assert.rejects(value.replay(duplicate), /Invalid XCTest/);
        }
        const malicious = structuredClone(metadata);
        malicious.bundles[0].info.CFBundleExecutable = "../../unrelated";
        await assert.rejects(value.replay(malicious), /executable/i);
        const unrelated = structuredClone(metadata);
        unrelated.directories.push({path: join(value.configuration, "Other"), entries: []});
        await assert.rejects(value.replay(unrelated), /Unrelated/);
        const missingFramework = structuredClone(metadata);
        missingFramework.directories.find(directory => directory.path.endsWith("/PackageFrameworks")).entries = [];
        await assert.rejects(value.replay(missingFramework), /Unrelated XCTest product metadata/);
    }));
}

test("artifact discovery rejects missing executables and escaping bundle metadata", async () => fixture("macos", async value => {
    const binary = join(value.testBundle, "Contents/MacOS/AuthorityTests");
    await rm(binary);
    await assert.rejects(value.capture(), /Missing XCTest executable/);
    await value.write(binary, "binary");
    const info = join(value.host, "Contents/Info.plist");
    await rm(info);
    const outside = join(value.root, "outside.plist");
    await value.write(outside, JSON.stringify({CFBundleExecutable: "Big Wallet"}));
    await symlink(outside, info);
    await assert.rejects(value.capture(), /metadata escaped/);
}));

test("artifact discovery rejects redirected executable directories and framework bundles", async () => fixture("ios", async value => {
    const frameworks = dirname(value.embedded);
    await rm(frameworks, {recursive: true});
    await symlink(dirname(value.framework), frameworks);
    await assert.rejects(value.capture(), /may not traverse symlinks/);
    await rm(frameworks);
    await mkdir(frameworks);
    await symlink(value.framework, value.embedded);
    await assert.rejects(value.capture(), /may not traverse symlinks/);
}));

test("recorded directory names cannot escape their bundle or hide missing metadata", async () => fixture("macos", async value => {
    const {metadata} = await value.capture();
    for (const invalid of ["../elsewhere.framework", "invalid/name.framework", "", "bad\u0000.framework"]) {
        const changed = structuredClone(metadata);
        changed.directories[0].entries.push(invalid);
        await assert.rejects(value.replay(changed), /malformed XCTest directory/);
    }
    const missingRequired = structuredClone(metadata);
    missingRequired.directories[0].entries = null;
    await assert.rejects(value.replay(missingRequired), /malformed XCTest directory/);
}));
