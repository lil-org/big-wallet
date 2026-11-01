import {join} from "node:path";

const EXCHANGE = "/Volumes/BigWalletBuild/Exchange";
const LOCAL_SETTINGS = ["CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "PROVISIONING_PROFILE=",
    "PROVISIONING_PROFILE_SPECIFIER=", "CODE_SIGN_ENTITLEMENTS=", "ENABLE_APP_SANDBOX=NO", "ENABLE_HARDENED_RUNTIME=NO",
    "REGISTER_APP_GROUPS=NO", "BW_VM_VERIFICATION_BUILD=YES", "CODE_SIGNING_ALLOWED=YES"];

export function nativeCommand(family, action, selectors, options, resultBundle) {
    if (action === "test-without-building") {
        if (typeof options.testRunPath !== "string" || !options.testRunPath.endsWith(".xctestrun")) { throw new Error("Mutation tests require their exact built XCTest run plan"); }
        return {command: "xcodebuild", cwd: family === "runtime" ? "Packages/WalletRuntime" : ".", args: [action,
            "-xctestrun", options.testRunPath, "-destination", options[family === "ios-app" ? "ios" : "macos"],
            "-enableCodeCoverage", "NO", "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
            "-resultBundlePath", resultBundle, ...selectors.map(selector => `-only-testing:${selector}`)]};
    }
    if (action !== "build-for-testing") { throw new Error("Unsupported native mutation build action"); }
    const app = family !== "runtime";
    const platform = family === "ios-app" ? "ios" : "macos";
    const args = [action, "-jobs", "2", "-configuration", "Debug", "-destination", options[platform],
        "-enableCodeCoverage", "NO",
        ...(app ? ["-project", "Wallet.xcodeproj", "-scheme", platform === "ios" ? "Tests iOS" : "Tests macOS"] : ["-scheme", "WalletRuntime-Package"]),
        "ENABLE_TESTABILITY=YES"];
    if (!app) { args.push("CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "CODE_SIGNING_ALLOWED=YES"); }
    else if (options.signing === "local") {
        args.push(...LOCAL_SETTINGS, `BW_TEST_VM_RUN_ID=${options.runId}`, `BW_TEST_VM_EXCHANGE=${EXCHANGE}`);
    }
    args.push(...selectors.map(selector => `-only-testing:${selector}`));
    return {command: "xcodebuild", args, cwd: app ? "." : "Packages/WalletRuntime"};
}

export function javascriptCommand(witnesses, {nodeExecutable, runnerRoot}) {
    const escape = value => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const pattern = `^(?:${witnesses.map(witness => escape(witness.selector)).join("|")})$`;
    return {command: nodeExecutable, args: ["--test", `--test-name-pattern=${pattern}`,
        `--test-reporter=${join(runnerRoot, "Scripts/security_mutations/node_reporter.mjs")}`,
        ...new Set(witnesses.map(witness => witness.file))]};
}

