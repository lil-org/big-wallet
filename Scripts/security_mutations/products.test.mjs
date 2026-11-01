import assert from "node:assert/strict";
import test from "node:test";
import {bindTestPlan, bundleExecutable, derivedDataLocation} from "./products.mjs";

const directory = "/Users/wallet-test/Library/Developer/Xcode/DerivedData";
const root = `${directory}/WalletRuntime-fixture`;
const products = `${root}/Build/Products`;
const description = `Build description path: ${root}/Build/Intermediates.noindex/XCBuildData/123.xcbuilddata`;
const selector = "WalletAuthorityTests/GuardTests/testOne";
const plan = () => ({__xctestrun_metadata__: {FormatVersion: 2}, TestConfigurations: [{Name: "Default", TestTargets: [
    {BlueprintName: "WalletAuthorityTests-product", ProductModuleName: "WalletAuthorityTests", TestBundlePath: "__TESTROOT__/Debug/WalletAuthorityTests.xctest",
        TestHostPath: "__PLATFORMS__/MacOSX.platform/Developer/Library/Xcode/Agents/xctest", IsAppHostedTestBundle: false},
]}]});

test("build products are located only from one current build description under default DerivedData", () => {
    assert.deepEqual(derivedDataLocation(description, directory), {root, products, locationSource: "emitted"});
    assert.throws(() => derivedDataLocation("", directory), /exactly one/);
    assert.throws(() => derivedDataLocation(description + "\n" + description.replace("WalletRuntime-fixture", "Other"), directory), /exactly one/);
    assert.throws(() => derivedDataLocation(description.replace(directory, "/tmp/DerivedData"), directory), /escaped/);
});

test("incremental and no-op logs reuse only the proven pristine family location", () => {
    const pinned = derivedDataLocation(description, directory);
    assert.deepEqual(derivedDataLocation("** TEST BUILD SUCCEEDED **\n", directory, pinned), {root, products, locationSource: "pinned"});
    assert.deepEqual(derivedDataLocation(description, directory, pinned), {root, products, locationSource: "emitted"});
    assert.throws(() => derivedDataLocation(description.replace("WalletRuntime-fixture", "Other"), directory, pinned), /changed/);
    assert.throws(() => derivedDataLocation(description + "\n" + description.replace("WalletRuntime-fixture", "Other"), directory, pinned), /exactly one/);
    assert.throws(() => derivedDataLocation("Build description path: /unexpected/layout", directory, pinned), /Unsupported/);
    assert.throws(() => derivedDataLocation("", directory, {root: "/tmp/custom", products: "/tmp/custom/Build/Products"}), /Invalid pinned/);
});

test("SwiftPM target aliases bind through the exact selected module and bundle", () => {
    assert.deepEqual(bindTestPlan(plan(), {family: "runtime", selectors: [selector], products}),
        [{target: "WalletAuthorityTests", bundle: `${products}/Debug/WalletAuthorityTests.xctest`, host: null}]);
    assert.equal(bindTestPlan(plan(), {family: "runtime", selectors: ["OtherTests/Class/testOther"], products}), null);
    const repeated = plan(); repeated.TestConfigurations[0].TestTargets.push(repeated.TestConfigurations[0].TestTargets[0]);
    assert.throws(() => bindTestPlan(repeated, {family: "runtime", selectors: [selector], products}), /repeats/);
    const toolHost = plan();
    toolHost.TestConfigurations[0].TestTargets[0].TestHostPath = "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest";
    assert.equal(bindTestPlan(toolHost, {family: "runtime", selectors: [selector], products})[0].host, null);
});

test("app plans bind test bundles to the same selected platform and app host", () => {
    const mobile = {TestConfigurations: [{TestTargets: [{BlueprintName: "Tests iOS", ProductModuleName: "Tests_iOS",
        TestBundlePath: "__TESTHOST__/PlugIns/Tests iOS.xctest", TestHostPath: "__TESTROOT__/Debug-iphonesimulator/Big Wallet.app"}]}]};
    assert.deepEqual(bindTestPlan(mobile, {family: "ios-app", selectors: ["Tests iOS/Class/testOne"], products}), [
        {target: "Tests iOS", bundle: `${products}/Debug-iphonesimulator/Big Wallet.app/PlugIns/Tests iOS.xctest`, host: `${products}/Debug-iphonesimulator/Big Wallet.app`},
    ]);
    assert.equal(bindTestPlan(mobile, {family: "macos-app", selectors: ["Tests iOS/Class/testOne"], products}), null);
    const mac = {"Tests macOS": {TestBundlePath: "__TESTROOT__/Debug/Tests macOS.xctest",
        TestHostPath: "__TESTROOT__/Debug/Big Wallet.app/Contents/MacOS/Big Wallet"}};
    assert.equal(bindTestPlan(mac, {family: "macos-app", selectors: ["Tests macOS/Class/testOne"], products})[0].host, `${products}/Debug/Big Wallet.app`);
});

test("run plans reject escaping paths unresolved tokens and missing app hosts", () => {
    const changed = plan(); changed.TestConfigurations[0].TestTargets[0].TestBundlePath = "__TESTROOT__/../../outside.xctest";
    assert.equal(bindTestPlan(changed, {family: "runtime", selectors: [selector], products}), null);
    changed.TestConfigurations[0].TestTargets[0].TestBundlePath = "__UNKNOWN__/Debug/WalletAuthorityTests.xctest";
    assert.throws(() => bindTestPlan(changed, {family: "runtime", selectors: [selector], products}), /token/);
    assert.throws(() => bindTestPlan(plan(), {family: "macos-app", selectors: [selector], products}), /no bound test host/);
});

test("executable identity follows each bound bundle's own Info.plist", () => {
    assert.equal(bundleExecutable("/bundle/Test.xctest", {CFBundleExecutable: "Test"}, "runtime"), "/bundle/Test.xctest/Contents/MacOS/Test");
    assert.equal(bundleExecutable("/bundle/Wallet.app", {CFBundleExecutable: "Big Wallet"}, "ios-app"), "/bundle/Wallet.app/Big Wallet");
    for (const name of ["", "..", "../other", "/other", "bad\0name"]) {
        assert.throws(() => bundleExecutable("/bundle/Test.xctest", {CFBundleExecutable: name}, "runtime"));
    }
});
