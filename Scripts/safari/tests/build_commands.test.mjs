import test from "node:test";
import assert from "node:assert/strict";
import {safariXcodeCommands} from "../run.mjs";

const runID = "run-build-destination-fixture";
const iosDestination = "platform=iOS Simulator,id=457B858E-62B8-4870-A30E-520F60D4D276";
const macDestination = "platform=macOS,arch=arm64";
const option = (args, name) => {
    assert.equal(args.filter(value => value === name).length, 1, `${name} must occur exactly once`);
    return args[args.indexOf(name) + 1];
};
const configurationOptions = (platform, configuration, signing, phase) => Object.freeze({
    platform, configuration, signing, phase, iterations: 1,
    destination: platform === "ios" ? iosDestination : macDestination,
    resultBundle: `/Volumes/BigWalletBuild/Exchange/artifacts/safari.${platform}.${configuration.toLowerCase()}.xcresult`,
    onlyTesting: [`Safari UI Tests ${platform === "ios" ? "iOS" : "macOS"}/SafariLifecycleTests/testInstallAndNativeRoundtrip`],
});
const descriptor = (platform, configuration) => `/Volumes/BigWalletBuild/Exchange/${runID}/safari/${platform}/${configuration}/SafariVMRun.json`;

for (const configuration of ["Debug", "Release"]) {
    for (const signing of ["local", "apple"]) {
        test(`iOS ${configuration} ${signing} builds resolve settings and compile without a live simulator destination`, () => {
            const options = configurationOptions("ios", configuration, signing, "build");
            const marker = descriptor("ios", configuration);
            const commands = safariXcodeCommands(options, marker, runID);
            assert.deepEqual(commands.settings.slice(0, 2), ["-showBuildSettings", "-json"]);
            assert.deepEqual(commands.build.slice(0, 3), ["-jobs", "2", "build-for-testing"]);
            for (const args of [commands.settings, commands.build]) {
                assert.equal(option(args, "-destination"), "generic/platform=iOS Simulator");
                assert.equal(option(args, "-configuration"), configuration);
                assert.equal(args.some(value => value.includes("457B858E-62B8-4870-A30E-520F60D4D276")), false);
                assert.ok(args.includes(`BW_SAFARI_VM_CONFIGURATION=${marker}`));
                assert.ok(args.includes(`BW_TEST_VM_RUN_ID=${runID}`));
                assert.equal(args.includes("CODE_SIGN_IDENTITY=-"), signing === "local");
            }
            assert.equal(option(commands.settings, "-scheme"), "Wallet iOS");
            assert.equal(option(commands.build, "-scheme"), "Safari UI Tests iOS");
            assert.ok(commands.build.includes("ENABLE_TESTABILITY=YES"));
            assert.equal(commands.test, null);
            assert.equal(options.destination, iosDestination);
        });

        test(`iOS ${configuration} ${signing} execution retains the exact pinned simulator and existing test limits`, () => {
            const options = configurationOptions("ios", configuration, signing, "test");
            const commands = safariXcodeCommands(options, descriptor("ios", configuration), runID);
            assert.deepEqual(commands.test.args.slice(0, 3), ["-jobs", "2", "test-without-building"]);
            assert.equal(option(commands.test.args, "-destination"), iosDestination);
            assert.equal(option(commands.test.args, "-scheme"), "Safari UI Tests iOS");
            assert.equal(option(commands.test.args, "-resultBundlePath"), options.resultBundle);
            assert.equal(option(commands.test.args, "-test-timeouts-enabled"), "YES");
            assert.equal(option(commands.test.args, "-default-test-execution-time-allowance"), "600");
            assert.equal(option(commands.test.args, "-maximum-test-execution-time-allowance"), "600");
            assert.equal(option(commands.test.args, "-parallel-testing-enabled"), "NO");
            assert.equal(option(commands.test.args, "-collect-test-diagnostics"), "never");
            assert.ok(commands.test.args.includes(`-only-testing:${options.onlyTesting[0]}`));
            assert.equal(commands.test.timeoutSeconds, 7200);
        });

        test(`macOS ${configuration} ${signing} build and runtime settings keep their original destination`, () => {
            const marker = descriptor("macos", configuration);
            const build = safariXcodeCommands(configurationOptions("macos", configuration, signing, "build"), marker, runID);
            const runtime = safariXcodeCommands(configurationOptions("macos", configuration, signing, "test"), marker, runID);
            assert.deepEqual(build.base, runtime.base);
            assert.deepEqual(build.settings, runtime.settings);
            for (const args of [build.settings, build.build, runtime.test.args]) {
                assert.equal(option(args, "-destination"), macDestination);
                assert.equal(option(args, "-configuration"), configuration);
                assert.equal(args.includes("CODE_SIGN_IDENTITY=-"), signing === "local");
            }
            assert.equal(option(build.settings, "-scheme"), "Wallet");
            assert.equal(option(build.build, "-scheme"), "Safari UI Tests macOS");
            assert.equal(option(runtime.test.args, "-scheme"), "Safari UI Tests macOS");
            if (configuration === "Debug" && signing === "local") {
                const prepare = safariXcodeCommands(configurationOptions("macos", configuration, signing, "prepare"), marker, runID);
                assert.deepEqual(build.base, prepare.base);
                assert.equal(prepare.test, null);
            }
        });
    }
}
