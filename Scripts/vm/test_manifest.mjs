import {isAbsolute, join, resolve, sep} from "node:path";
import {SAFARI_SCENARIOS, SAFARI_TEST_CLASS} from "../safari/scenarios.mjs";
import {expectedSynchronizationPolicy} from "../safari/synchronization.mjs";
import {RUNTIME_TEST_TARGETS, loadRuntimeInventory} from "./runtime_inventory.mjs";
import {BASELINE as UPGRADE_BASELINE} from "../wallet_upgrade/contract.mjs";

export {RUNTIME_TEST_TARGETS};
export const RUNTIME_MODULES = ["WalletDomain", "WalletNetworking", "WalletAuthority"];
const runtimeInventory = loadRuntimeInventory(new URL("./runtime-test-inventory.json", import.meta.url));

export const SELECTORS = ["build", "test", "performance", "tsan", "fuzz", "approval", "upgrade", "safari", "repository", "worker", "runtime"];
export const BOOTSTRAP_TOOL_NAMES = ["VMGuestAgent", "guest_runner", "guest_bootstrap.mjs"];
const LOCAL_SIGNING_SETTINGS = [
    "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "PROVISIONING_PROFILE=",
    "PROVISIONING_PROFILE_SPECIFIER=", "CODE_SIGN_ENTITLEMENTS=", "ENABLE_APP_SANDBOX=NO",
    "ENABLE_HARDENED_RUNTIME=NO", "REGISTER_APP_GROUPS=NO", "BW_VM_VERIFICATION_BUILD=YES",
];
export const PLATFORMS = [
    {id: "macos", target: "Tests macOS", scheme: "Wallet", generic: "generic/platform=macOS", requirement: "macos"},
    {id: "ios", target: "Tests iOS", scheme: "Wallet iOS", generic: "generic/platform=iOS", requirement: "ios"},
    {id: "visionos", target: "Tests visionOS", scheme: "Wallet visionOS", generic: "generic/platform=visionOS", requirement: "visionos"},
];
export const SAFARI_PLATFORMS = PLATFORMS.filter(platform => platform.id !== "visionos")
    .map(platform => ({...platform, target: `Safari UI ${platform.target}`}));
const TEST_TARGETS = [...PLATFORMS, ...SAFARI_PLATFORMS].map(platform => platform.target).concat(RUNTIME_TEST_TARGETS);
const isSafariSelector = selector => selector.startsWith("Safari UI Tests ") || selector === SAFARI_TEST_CLASS || selector.startsWith(`${SAFARI_TEST_CLASS}/`);
const SAFARI_STAGE_OVERHEAD_SECONDS = 600;
export const PERFORMANCE_ENV = {
    TEST_RUNNER_WALLETCORE_PROXY_PERF_SCRYPT_DERIVE_MS: "1000",
    TEST_RUNNER_WALLETCORE_PROXY_PERF_SCRYPT_WALLETCORE_JSON_IMPORT_MS: "1000",
    TEST_RUNNER_WALLETCORE_PROXY_PERF_SECP256K1_PUBLIC_KEY_MS: "25",
    TEST_RUNNER_WALLETCORE_PROXY_PERF_SECP256K1_SIGN_MS: "15",
    TEST_RUNNER_WALLETCORE_PROXY_PERF_ED25519_SIGN_MS: "15",
};
export const PERFORMANCE_TESTS = [
    "testScryptDefaultDerivationPerformanceGate", "testScryptWalletCoreJSONImportPerformanceGate",
    "testSecp256k1PublicKeyPerformanceGate", "testSecp256k1SigningPerformanceGate", "testEd25519SigningPerformanceGate",
];
export const TSAN_TESTS = [
    "AsyncTestSupportTests", "AlchemyJWTProviderTests", "SolanaOptionsTests", "ApprovalResolutionTests",
    "WalletSigningSessionTests", "WalletSigningScopeTests", "NativeApprovalServiceTests", "TransactionInspectorTests",
    "WalletsManagerPreviewTests", "AccountPreviewStateTests", "WalletCoreProxyParallelDerivationTests",
    "SafariRPCRequestTests", "SafariRPCServiceTests", "SafariRPCStreamingTests",
];
export const EXTENDED_TSAN_TESTS = [
    "ExtensionBridgeStoredRequestTests", "PopupRequestSessionsTests", "DurableProfilePersistenceTests",
    "WalletAuthorityRevocationLedgerTests", "NativeApprovalCoordinatorTests", "WalletsManagerPrivateKeyImportTests",
    "AccountsListViewControllerTests", "NativeAccountSelectionViewControllerTests",
    "TransactionApprovalCoordinatorTests",
];
export const SHELL_TESTS = [
    "test_alchemy_jwt_request_proof_key_packaging.sh", "test_alchemy_key_artifact_cleanup.sh",
    "test_asc_alchemy_release_guard.sh", "test_asc_build_marker.sh", "test_embed_ambient_helper.sh",
    "test_terminate_ambient_agents.sh",
];

export function validateJob(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) { throw new Error("Job must be an object"); }
    const allowed = new Set(["version", "runId", "vmId", "kind", "profile", "source", "bootstrapTools", "payload"]);
    if (Object.keys(value).some(key => !allowed.has(key)) || value.version !== 1) { throw new Error("Unsupported job schema"); }
    if (typeof value.runId !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(value.runId) || value.runId.includes("..")) {
        throw new Error("Invalid run identifier");
    }
    if (typeof value.vmId !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$/.test(value.vmId)) { throw new Error("Invalid VM identifier"); }
    if (!["run", "doctor"].includes(value.kind) || !["all", "extended"].includes(value.profile)) { throw new Error("Invalid job kind or profile"); }
    const options = value.payload;
    const optionNames = new Set(["stages", "onlyTesting", "configuration", "approvalArgs", "signing", "interactiveSafari", "prepareSafari", "preparedSafari", "runtimePlatforms"]);
    if (!options || typeof options !== "object" || Array.isArray(options) || Object.keys(options).some(key => !optionNames.has(key))) {
        throw new Error("Unsupported job payload");
    }
    if (!Array.isArray(options.stages) || options.stages.some(stage => !SELECTORS.includes(stage)) || new Set(options.stages).size !== options.stages.length) {
        throw new Error("Invalid stage selection");
    }
    if (!Array.isArray(options.onlyTesting) || options.onlyTesting.length > 200 || options.onlyTesting.some(test =>
        typeof test !== "string" || !TEST_TARGETS.includes(test) &&
        !/^(?:(?:(?:Safari UI )?Tests macOS|(?:Safari UI )?Tests iOS|Tests visionOS|Wallet(?:Domain|Authority|Networking)Tests)\/)?[A-Za-z_][A-Za-z0-9_]*(?:\/[A-Za-z_][A-Za-z0-9_]*(?:\(\))?)?$/.test(test))) {
        throw new Error("Invalid XCTest selection");
    }
    for (const selector of options.onlyTesting) {
        if (isSafariSelector(selector) &&
            !SAFARI_PLATFORMS.some(platform => safariTestsForPlatform([selector], platform).length)) {
            throw new Error(`Safari selection did not match any known tests: ${selector}`);
        }
    }
    if (value.kind === "run" && options.onlyTesting.some(isSafariSelector) && options.stages.length &&
        !options.stages.some(stage => stage === "safari" || stage === "build")) {
        throw new Error("Safari XCTest selectors require --stage safari or --stage build");
    }
    if (options.configuration !== undefined && !["Debug", "Release"].includes(options.configuration)) { throw new Error("Invalid configuration"); }
    if (options.runtimePlatforms !== undefined && (!Array.isArray(options.runtimePlatforms) ||
        new Set(options.runtimePlatforms).size !== options.runtimePlatforms.length ||
        options.runtimePlatforms.some(platform => !["macos", "ios", "visionos"].includes(platform)))) {
        throw new Error("Invalid runtime platform selection");
    }
    if (options.signing !== undefined && !["local", "apple"].includes(options.signing)) { throw new Error("Invalid signing mode"); }
    if (options.interactiveSafari !== undefined && typeof options.interactiveSafari !== "boolean") { throw new Error("Invalid interactive Safari mode"); }
    if (options.interactiveSafari && (value.kind !== "run" || options.stages.length && !options.stages.includes("safari") ||
        !safariTestsForPlatform(options.onlyTesting, SAFARI_PLATFORMS.find(platform => platform.id === "macos")).length)) {
        throw new Error("Interactive Safari mode requires selected macOS Safari runtime tests");
    }
    if (options.prepareSafari !== undefined && typeof options.prepareSafari !== "boolean") { throw new Error("Invalid Safari preparation mode"); }
    if (options.prepareSafari && (value.kind !== "run" || value.profile !== "all" ||
        options.stages.length !== 1 || options.stages[0] !== "safari" ||
        options.onlyTesting.length !== 1 || options.onlyTesting[0] !== "Safari UI Tests macOS" ||
        options.configuration !== "Debug" || options.signing !== "local" ||
        options.interactiveSafari || options.preparedSafari !== undefined || options.approvalArgs?.length)) {
        throw new Error("Safari preparation requires only local Debug macOS Safari setup");
    }
    if (options.preparedSafari !== undefined && (!validSafariPreparationReference(options.preparedSafari) ||
        value.kind !== "run" || options.prepareSafari || options.interactiveSafari || (options.signing ?? "local") !== "local" ||
        options.stages.length && !options.stages.includes("safari") ||
        !safariTestsForPlatform(options.onlyTesting, SAFARI_PLATFORMS.find(platform => platform.id === "macos")).length)) {
        throw new Error("Prepared Safari mode requires selected local macOS Safari runtime tests and a valid preparation reference");
    }
    if (!value.bootstrapTools || typeof value.bootstrapTools !== "object" || Array.isArray(value.bootstrapTools) ||
        Object.keys(value.bootstrapTools).length !== BOOTSTRAP_TOOL_NAMES.length || BOOTSTRAP_TOOL_NAMES.some(name => !/^[a-f0-9]{64}$/.test(value.bootstrapTools[name]))) {
        throw new Error("Invalid bootstrap tool identity");
    }
    if (!value.source || typeof value.source !== "object" || Array.isArray(value.source) || Object.keys(value.source).some(key => !["sha256", "commit", "fileCount", "bytes"].includes(key)) ||
        !/^[a-f0-9]{64}$/.test(value.source.sha256) || typeof value.source.commit !== "string" || !/^[a-f0-9]{40,64}$/.test(value.source.commit)) {
        throw new Error("Invalid source identity");
    }
    for (const key of ["fileCount", "bytes"]) {
        if (value.source[key] !== undefined && (!Number.isSafeInteger(value.source[key]) || value.source[key] < 0)) { throw new Error("Invalid source inventory"); }
    }
    validateApprovalArguments(options.approvalArgs ?? []);
    return structuredClone(value);
}

export function validSafariPreparationReference(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value) &&
        Object.keys(value).sort().join(",") === "preparationRunID,receiptSHA256" &&
        typeof value.preparationRunID === "string" && /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(value.preparationRunID) &&
        !value.preparationRunID.includes("..") && typeof value.receiptSHA256 === "string" && /^[a-f0-9]{64}$/.test(value.receiptSHA256);
}

function validateApprovalArguments(args) {
    if (!Array.isArray(args) || args.length > 30 || args.some(arg => typeof arg !== "string" || arg.length > 2048 || arg.includes("\0"))) {
        throw new Error("Invalid approval arguments");
    }
    const switches = new Set(["--soak", "--no-minimize", "--random-only", "--systematic-only"]);
    const numbers = new Set(["--seed", "--sequences", "--steps", "--timeout-ms", "--trace-limit"]);
    for (let index = 0; index < args.length; index += 1) {
        const flag = args[index];
        if (switches.has(flag)) { continue; }
        const value = args[++index];
        if (numbers.has(flag) && typeof value === "string" && /^(?:0x[0-9a-f]+|[0-9]+)$/i.test(value)) { continue; }
        if (flag === "--mode" && ["alternate", "native", "popup"].includes(value)) { continue; }
        if (flag === "--systematic" && ["all", "extended", "off"].includes(value)) { continue; }
        if (flag === "--replay" && typeof value === "string" && value.length && !value.startsWith("--")) { continue; }
        throw new Error(`Unsupported approval argument: ${flag}`);
    }
    if (args.includes("--random-only") && args.includes("--systematic-only")) { throw new Error("Conflicting approval exploration modes"); }
    const profile = args.includes("--random-only") ? "off" : argumentValue(args, "--systematic") ?? "all";
    const limit = argumentValue(args, "--trace-limit");
    if (args.includes("--systematic-only") && profile === "off" || limit !== undefined &&
        (profile === "off" || !Number.isSafeInteger(Number(limit)) || Number(limit) < 1 || Number(limit) > (profile === "extended" ? 4096 : 256))) {
        throw new Error("Trace limit exceeds the selected approval exploration profile");
    }
}

function argumentValue(args, flag) {
    const index = args.lastIndexOf(flag);
    return index < 0 ? undefined : args[index + 1];
}

export function approvalArguments(args) {
    if (args.includes("--replay") || args.includes("--random-only")) { return [...args]; }
    const profile = argumentValue(args, "--systematic") ?? "all";
    return [...args, ...(args.includes("--systematic") ? [] : ["--systematic", profile]),
        ...(profile === "off" || args.includes("--trace-limit") ? [] : ["--trace-limit", profile === "extended" ? "4096" : "256"])];
}

function approvalAudit(args) {
    if (args.includes("--replay") || args.includes("--random-only")) { return undefined; }
    const profile = argumentValue(args, "--systematic") ?? "all";
    if (profile === "off") { return undefined; }
    const mode = argumentValue(args, "--mode") ?? "alternate";
    return {profile, traceLimit: Number(argumentValue(args, "--trace-limit") ?? (profile === "extended" ? 4096 : 256)),
        modes: mode === "alternate" ? ["native", "popup"] : [mode]};
}

export function testingForPlatform(selectors, platform, configuration) {
    return selectors.flatMap(selector => {
        if (RUNTIME_MODULES.includes(selector)) { return []; }
        if (TEST_TARGETS.some(target => selector === target || selector.startsWith(`${target}/`))) {
            return selector === platform.target || selector.startsWith(`${platform.target}/`) ? [selector] : [];
        }
        const normalized = selector.replace(/\(\)$/, "");
        if (["NativeApprovalCoordinatorTests", "TransactionApprovalCoordinatorTests", "PasswordStorageTests"].some(name => normalized === name || normalized.startsWith(`${name}/`))) {
            return runtimeInventory.appTests.some(test => test.id.startsWith(`${platform.target}/`) &&
                (!configuration || test.variants.includes(`${platform.id}.${configuration.toLowerCase()}`)) &&
                (test.id === `${platform.target}/${normalized}` || test.id.startsWith(`${platform.target}/${normalized}/`)))
                ? [`${platform.target}/${selector}`] : [];
        }
        if (runtimeInventory.tests.some(test => test.id.split("/").slice(1).join("/") === normalized ||
            test.id.split("/")[1] === normalized)) { return []; }
        if ((selector === SAFARI_TEST_CLASS || selector.startsWith(`${SAFARI_TEST_CLASS}/`)) &&
            !SAFARI_PLATFORMS.some(candidate => candidate.target === platform.target)) { return []; }
        return [`${platform.target}/${selector}`];
    });
}

export function runtimeTestsForPlatform(selectors, platform, configuration) {
    const variant = `${platform}.${configuration.toLowerCase()}`;
    return runtimeInventory.tests.filter(test => test.variants.includes(variant) && (!selectors.length || selectors.some(raw => {
        const selector = raw.replace(/\(\)$/, "");
        if (RUNTIME_MODULES.includes(selector)) { return false; }
        const name = test.id.split("/").slice(1).join("/");
        return test.id === selector || test.id.startsWith(`${selector}/`) || name === selector || name.startsWith(`${selector}/`);
    }))).map(test => test.id);
}

export function safariTestsForPlatform(selectors, platform) {
    const selected = testingForPlatform(selectors, platform).map(selector => selector.replace(/\(\)$/, ""));
    const scenarios = SAFARI_SCENARIOS.filter(scenario => scenario.platforms.includes(platform.id));
    return scenarios.filter(scenario => {
        const identifier = `${platform.target}/${SAFARI_TEST_CLASS}/${scenario.method}`;
        return !selectors.length || selected.some(selector => identifier === selector || identifier.startsWith(`${selector}/`));
    });
}

export function createManifest(job) {
    validateJob(job);
    const options = job.payload;
    const stages = [];
    const debugPerformancePlatforms = new Set();
    const add = (id, group, command, args, extra = {}) => stages.push({
        id, group, command, args, cwd: ".", dependencies: [], requirements: ["node"], timeoutSeconds: 900, ...extra,
    });
    const provider = "Safari Shared/Inpage Provider";
    const worker = "Workers/alchemy-jwt";
    add("provider.install", "repository", "npm", ["ci", "--include=dev", "--include=optional", "--no-audit"], {cwd: provider});
    add("protocol.check", "repository", "node", ["Scripts/generate_wire_protocol.mjs", "--check"]);
    add("pins.check", "repository", "python3", ["Scripts/vm/environment_pins.py", "--check"], {requirements: ["python"]});
    add("runtime.inventory", "repository", "node", ["Scripts/vm/runtime_inventory.mjs", "--check"]);
    add("runtime.boundaries", "repository", "node", ["Scripts/check_runtime_boundaries.mjs"]);
    add("runtime.boundary-tests", "repository", "node", ["--test", "Scripts/tests/runtime_boundaries.test.mjs"]);
    add("provider.bundle", "repository", "npm", ["run", "build"], {cwd: provider, dependencies: ["provider.install", "protocol.check"], unchanged: ["Safari Shared/Resources/inpage.js"]});
    add("provider.test", "test", "node", ["--test", "--test-concurrency=1", "--test-reporter=tap", "../Tests/*.test.mjs"], {
        cwd: provider, dependencies: ["provider.install", "protocol.check"],
    });
    for (const file of SHELL_TESTS) {
        add(`scripts.${file.slice(5, -3)}`, "repository", file.includes("asc_alchemy") ? "/bin/bash" : "/bin/sh", [`Scripts/tests/${file}`], {dependencies: ["provider.install"], requirements: ["node", "jq"]});
    }
    add("metadata.localizations", "repository", "/bin/bash", ["Scripts/asc/validate_localizations.sh"], {requirements: ["jq"]});
    add("scripts.approval-worker-target", "repository", "node", ["--test", "Scripts/tests/approval_worker_target.test.mjs"]);
    add("scripts.upgrade-consumer-target", "repository", "node", ["--test", "Scripts/tests/upgrade_consumer_target.test.mjs"]);
    add("upgrade.archive", "repository", "python3", ["Scripts/wallet_upgrade/archive.py", "--verify"], {requirements: ["python"]});
    add("runner.node-tests", "repository", "node", ["--test", "Scripts/vm/tests/*.test.mjs"], {requirements: ["node", "xcode"]});
    add("runner.python-tests", "repository", "python3", ["-m", "unittest", "discover", "-s", "Scripts/vm/tests", "-p", "test_*.py"], {requirements: ["python", "node"]});
    add("safari.runner-tests", "repository", "node", ["--test", "Scripts/safari/tests/*.test.mjs"], {dependencies: ["provider.install"]});
    add("worker.install", "worker", "npm", ["ci", "--no-audit"], {cwd: worker});
    for (const [id, script, suffix] of [
        ["check", "check", []], ["test", "test", []], ["validate-self", "validate:self", []],
        ["validate-dry-run", "validate:live", ["--", "--dry-run"]], ["deploy-dry-run", "deploy:dry-run", []], ["startup", "startup", []],
    ]) { add(`worker.${id}`, "worker", "npm", ["run", script, ...suffix], {cwd: worker, dependencies: ["worker.install"]}); }

    const configurations = options.configuration ? [options.configuration] : ["Debug", "Release"];
    for (const selector of options.onlyTesting.filter(selector => RUNTIME_TEST_TARGETS.some(target => selector === target || selector.startsWith(`${target}/`)))) {
        if (!(options.runtimePlatforms?.length ? options.runtimePlatforms : PLATFORMS.map(platform => platform.id)).some(platform =>
            configurations.some(configuration => runtimeTestsForPlatform([selector], platform, configuration).length))) {
            throw new Error(`Runtime selection did not match any tests on the selected platforms: ${selector}`);
        }
    }
    const apiValidation = !options.stages.length || ["build", "performance", "tsan"].some(group => options.stages.includes(group)) ||
        options.stages.includes("test") &&
        (!options.onlyTesting.length || PLATFORMS.some(platform => runtimeTestsForPlatform(options.onlyTesting, platform.id, configurations[0]).length));
    if (options.onlyTesting.includes("ApprovalCrashWorker")) {
        add("runtime.harness-graph", "runtime", "node", ["Scripts/validate_approval_worker_target.mjs"], {requirements: ["node", "xcode"], timeoutSeconds: 300});
    }
    for (const configuration of configurations) {
        if (options.onlyTesting.includes("ApprovalCrashWorker")) {
            add(`runtime.ApprovalCrashWorker.${configuration.toLowerCase()}`, "runtime", "swift", [
                "build", "--package-path", "Packages/WalletRuntimeHarness", "--configuration", configuration.toLowerCase(),
                "--product", "ApprovalCrashWorker", "--jobs", "2", "-Xswiftc", "-enable-testing",
            ], {dependencies: ["runtime.harness-graph"], requirements: ["xcode"], timeoutSeconds: 1800});
        }
        for (const target of [...RUNTIME_MODULES, ...RUNTIME_TEST_TARGETS]) {
            if (RUNTIME_TEST_TARGETS.includes(target) && !options.onlyTesting.includes(target)) { continue; }
            if (options.onlyTesting.length && !options.onlyTesting.includes(target) && !(apiValidation && RUNTIME_MODULES.includes(target))) { continue; }
            add(`runtime.${target}.${configuration.toLowerCase()}`, "runtime", "swift", [
                "build", "--package-path", "Packages/WalletRuntime", "--configuration", configuration.toLowerCase(),
                "--target", target, "--jobs", "2",
                ...(RUNTIME_TEST_TARGETS.includes(target) ? ["-Xswiftc", "-enable-testing"] : []),
            ], {requirements: ["xcode"], timeoutSeconds: 1800});
        }
        if (apiValidation) {
            add(`runtime.api.${configuration.toLowerCase()}`, "build", "node", ["Scripts/check_runtime_boundaries.mjs", "--check-api",
                "--package-path", "Packages/WalletRuntime", "--configuration", configuration], {
                dependencies: ["runtime.boundaries", ...RUNTIME_MODULES.map(target => `runtime.${target}.${configuration.toLowerCase()}`)],
                requirements: ["node", "xcode"], timeoutSeconds: 1800,
            });
        }
        for (const platform of PLATFORMS) {
            const slug = `${platform.id}.${configuration.toLowerCase()}`;
            const requiredRuntimeTests = !options.runtimePlatforms?.length || options.runtimePlatforms.includes(platform.id)
                ? runtimeTestsForPlatform(options.onlyTesting, platform.id, configuration) : [];
            if (requiredRuntimeTests.length) {
                const runtimeBase = ["-jobs", "2", "-enableCodeCoverage", "NO", "-scheme", "WalletRuntime-Package",
                    "-configuration", configuration, "-destination", `$destination:${platform.id}`,
                    "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "CODE_SIGNING_ALLOWED=YES"];
                add(`build-runtime-tests.${slug}`, "build", "xcodebuild", ["build-for-testing", ...runtimeBase, "ENABLE_TESTABILITY=YES",
                    ...(options.onlyTesting.length ? requiredRuntimeTests.map(test => `-only-testing:${test}`) : [])], {
                    cwd: "Packages/WalletRuntime", dependencies: ["runtime.inventory", ...(apiValidation ? [`runtime.api.${configuration.toLowerCase()}`] : [])], requirements: ["xcode", platform.requirement], timeoutSeconds: 3600,
                    runtimeTestability: RUNTIME_MODULES,
                });
                add(`test-runtime.${slug}`, "test", "xcodebuild", ["test-without-building", ...runtimeBase,
                    "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
                    ...(options.onlyTesting.length ? requiredRuntimeTests.map(test => `-only-testing:${test}`) : [])], {
                    cwd: "Packages/WalletRuntime", dependencies: [`build-runtime-tests.${slug}`], requirements: ["xcode", platform.requirement], timeoutSeconds: 7200,
                    nativeAudit: {configuration, platform: platform.id, kind: "full", runtime: true, requiredTests: requiredRuntimeTests,
                        filtered: requiredRuntimeTests.length !== runtimeTestsForPlatform([], platform.id, configuration).length},
                    env: configuration === "Release" ? PERFORMANCE_ENV : {}, resultBundle: true,
                });
                if (configuration === "Debug" && requiredRuntimeTests.some(test => test.includes("/WalletCoreProxyPerformanceGateTests/") &&
                    PERFORMANCE_TESTS.some(name => test.endsWith(`/${name}`)))) {
                    debugPerformancePlatforms.add(platform.id);
                }
            }
            const signing = platform.id === "macos" ? ["signing"] : [];
            add(`build.${slug}`, "build", "xcodebuild", ["-jobs", "2", "build", "-project", "Wallet.xcodeproj", "-scheme", platform.scheme,
                "-configuration", configuration, "-destination", platform.generic, ...(platform.id === "macos" ? [] : ["CODE_SIGNING_ALLOWED=NO"])], {
                dependencies: ["provider.install", "protocol.check"], requirements: ["node", "xcode", "proofKey", ...signing], proofKey: true, timeoutSeconds: 3600,
            });
            const base = ["-jobs", "2", "-enableCodeCoverage", "NO", "-project", "Wallet.xcodeproj", "-scheme", platform.target,
                "-configuration", configuration, "-destination", `$destination:${platform.id}`];
            add(`build-tests.${slug}`, "build", "xcodebuild", ["build-for-testing", ...base, "ENABLE_TESTABILITY=YES"], {
                dependencies: ["provider.install", "protocol.check"], requirements: ["node", "xcode", "proofKey", platform.requirement, ...signing], proofKey: true, timeoutSeconds: 3600,
            });
            const selectedTests = testingForPlatform(options.onlyTesting, platform, configuration);
            if (options.onlyTesting.length && !selectedTests.length) { continue; }
            add(`test.${slug}`, "test", "xcodebuild", ["test-without-building", ...base, "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never",
                ...selectedTests.map(test => `-only-testing:${test}`)], {
                dependencies: [`build-tests.${slug}`], requirements: ["xcode", platform.requirement], timeoutSeconds: 7200,
                nativeAudit: {configuration, platform: platform.id, kind: "full", filtered: selectedTests.length > 0 && !selectedTests.includes(platform.target)},
                env: configuration === "Release" ? PERFORMANCE_ENV : {}, resultBundle: true,
            });
        }
    }
    const nativeBase = ["-jobs", "2", "-enableCodeCoverage", "NO", "test", "-project", "Wallet.xcodeproj", "-scheme", "Tests macOS",
        "-destination", "$destination:macos", "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never"];
    const nativeRequirements = ["node", "xcode", "proofKey", "macos", "signing"];
    const nativeDependencies = ["provider.install", "protocol.check"];
    const runtimeChecks = ["runtime.inventory", ...(apiValidation ? [`runtime.api.${configurations.includes("Release") ? "release" : "debug"}`] : [])];
    const runtimePerformanceTests = PERFORMANCE_TESTS.map(name => `WalletAuthorityTests/WalletCoreProxyPerformanceGateTests/${name}`);
    const runtimeNativeBase = ["-jobs", "2", "-enableCodeCoverage", "NO", "test", "-scheme", "WalletRuntime-Package",
        "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "ENABLE_TESTABILITY=YES",
        "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "CODE_SIGNING_ALLOWED=YES"];
    add("performance.release", "performance", "xcodebuild", [...runtimeNativeBase, "-configuration", "Release", "-destination", "$destination:macos",
        ...runtimePerformanceTests.map(test => `-only-testing:${test}`)], {
        cwd: "Packages/WalletRuntime", dependencies: runtimeChecks, requirements: ["xcode", "macos"], timeoutSeconds: 7200,
        env: PERFORMANCE_ENV, nativeAudit: {configuration: "Release", platform: "macos", kind: "performance", runtime: true, requiredTests: runtimePerformanceTests}, resultBundle: true,
    });
    if (options.configuration === "Debug" && (!options.stages.length || options.stages.includes("test"))) {
        for (const platform of PLATFORMS.filter(platform => platform.id !== "macos" && debugPerformancePlatforms.has(platform.id))) {
            add(`performance.${platform.id}.release`, "performance", "xcodebuild", [...runtimeNativeBase, "-configuration", "Release",
                "-destination", `$destination:${platform.id}`, ...runtimePerformanceTests.map(test => `-only-testing:${test}`)], {
                cwd: "Packages/WalletRuntime", dependencies: runtimeChecks, requirements: ["xcode", platform.requirement], timeoutSeconds: 7200,
                env: PERFORMANCE_ENV, nativeAudit: {configuration: "Release", platform: platform.id, kind: "performance", runtime: true, requiredTests: runtimePerformanceTests}, resultBundle: true,
            });
        }
    }
    for (const [id, classes] of [["tsan.focused", TSAN_TESTS], ...(job.profile === "extended" ? [["tsan.extended", EXTENDED_TSAN_TESTS]] : [])]) {
        const packageTests = runtimeTestsForPlatform(classes, "macos", "Debug");
        if (packageTests.length) {
            add(`${id}.runtime`, "tsan", "xcodebuild", [...runtimeNativeBase, "-configuration", "Debug", "-destination", "$destination:macos",
                "-enableThreadSanitizer", "YES", ...packageTests.map(test => `-only-testing:${test}`)], {
                cwd: "Packages/WalletRuntime", dependencies: runtimeChecks, requirements: ["xcode", "macos"], timeoutSeconds: 14400,
                nativeAudit: {configuration: "Debug", platform: "macos", kind: "tsan", runtime: true, requiredTests: packageTests}, resultBundle: true,
            });
        }
        const appTests = testingForPlatform(classes, PLATFORMS[0], "Debug");
        if (appTests.length) {
            add(id, "tsan", "xcodebuild", [...nativeBase, "-configuration", "Debug", "-enableThreadSanitizer", "YES", ...appTests.map(test => `-only-testing:${test}`)], {
                dependencies: nativeDependencies, requirements: nativeRequirements, proofKey: true, timeoutSeconds: 14400,
                nativeAudit: {configuration: "Debug", platform: "macos", kind: "tsan"}, resultBundle: true,
            });
        }
    }
    add("fuzz.default", "fuzz", "node", ["Scripts/fuzz_wire_protocol.mjs"], {dependencies: ["protocol.check"], requirements: ["node", "xcode"], timeoutSeconds: 3600, failureDirectory: true});
    add("fuzz.regressions", "fuzz", "node", ["Scripts/fuzz_wire_protocol.mjs", "--replay", "Safari Shared/Tests/fixtures/protocol_fuzz_regressions.json"], {
        dependencies: ["protocol.check"], requirements: ["node", "xcode"], timeoutSeconds: 1800, failureDirectory: true,
    });
    if (job.profile === "extended") {
        for (const seed of [42, 20261013, 3735928559]) {
            add(`fuzz.seed-${seed}`, "fuzz", "node", ["Scripts/fuzz_wire_protocol.mjs", "--seed", String(seed), "--iterations", "20000"], {
                dependencies: ["protocol.check"], requirements: ["node", "xcode"], timeoutSeconds: 7200, failureDirectory: true,
            });
        }
    }
    for (const configuration of configurations) {
        const slug = configuration.toLowerCase();
        const arguments_ = approvalArguments(options.approvalArgs ?? []);
        add(`approval.${slug}`, "approval", "/bin/sh", ["Scripts/check_approval_lifecycle.sh", ...arguments_], {
            dependencies: ["provider.install", "protocol.check"], requirements: ["node", "xcode"],
            timeoutSeconds: arguments_.includes("--soak") || argumentValue(arguments_, "--systematic") === "extended" ? 21600 : 7200,
            approvalAudit: approvalAudit(arguments_),
            env: {APPROVAL_CONFIGURATION: configuration}, failureDirectory: true, scratchDirectory: true,
        });
        if (job.profile === "extended" && (options.approvalArgs ?? []).every(argument => argument === "--no-minimize")) {
            const systematic = ["--systematic", "extended", "--systematic-only", "--trace-limit", "4096", ...(options.approvalArgs ?? [])];
            add(`approval.systematic-${slug}`, "approval", "/bin/sh", ["Scripts/check_approval_lifecycle.sh", ...systematic], {
                dependencies: [`approval.${slug}`], requirements: ["node", "xcode"], timeoutSeconds: 21600,
                approvalAudit: approvalAudit(systematic),
                env: {APPROVAL_CONFIGURATION: configuration}, failureDirectory: true, scratchDirectory: true,
            });
            add(`approval.soak-${slug}`, "approval", "/bin/sh", ["Scripts/check_approval_lifecycle.sh", "--soak", "--seed", "42", "--systematic", "off", ...(options.approvalArgs ?? [])], {
                dependencies: [`approval.${slug}`], requirements: ["node", "xcode"], timeoutSeconds: 21600,
                env: {APPROVAL_CONFIGURATION: configuration}, failureDirectory: true, scratchDirectory: true,
            });
        }
    }
    for (const configuration of configurations) {
        add(`upgrade.${configuration.toLowerCase()}`, "upgrade", "/bin/sh", ["Scripts/check_wallet_upgrade.sh"], {
            dependencies: ["runtime.boundaries", "pins.check", "upgrade.archive", "scripts.upgrade-consumer-target"],
            requirements: ["node", "python", "xcode", "macos"], timeoutSeconds: 3600,
            env: {UPGRADE_CONFIGURATION: configuration}, failureDirectory: true, scratchDirectory: true,
            upgradeAudit: {configuration, baseline: UPGRADE_BASELINE, sourceSHA256: job.source.sha256},
        });
    }
    for (const platform of SAFARI_PLATFORMS) {
        const scenarios = safariTestsForPlatform(options.onlyTesting, platform);
        if (!scenarios.length) { continue; }
        const requiredTests = scenarios.map(scenario => `${SAFARI_TEST_CLASS}/${scenario.method}`);
        const selectedTests = requiredTests.flatMap(test => ["--only-testing", `${platform.target}/${test}`]);
        for (const configuration of configurations) {
            const slug = `${platform.id}.${configuration.toLowerCase()}`;
            const signing = options.signing ?? "local";
            const interactive = platform.id === "macos" && options.interactiveSafari === true;
            const prepared = platform.id === "macos" ? options.preparedSafari : undefined;
            const base = ["Scripts/safari/run.mjs", "--platform", platform.id, "--configuration", configuration,
                "--signing", signing, "--destination", `$destination:${platform.id}`];
            add(`build-safari.${slug}`, "build", "node", [...base, "--phase", "build"], {
                dependencies: ["provider.install", "protocol.check", "pins.check"], scratchDirectory: true, timeoutSeconds: 3600 + SAFARI_STAGE_OVERHEAD_SECONDS,
                requirements: ["node", "xcode", platform.requirement, ...(signing === "apple" ? ["proofKey", ...(platform.id === "macos" ? ["signing"] : [])] : [])],
                ...(signing === "apple" ? {proofKey: true} : {}),
            });
            if (options.prepareSafari) {
                add(`prepare-safari.${slug}`, "safari", "node", [...base, "--phase", "prepare"], {
                    dependencies: [`build-safari.${slug}`], scratchDirectory: true, preparationResult: true,
                    requirements: ["node", "xcode", "macos"], timeoutSeconds: 1800 + SAFARI_STAGE_OVERHEAD_SECONDS,
                });
                continue;
            }
            const runtime = (id, iterations, dependencies) => add(id, "safari", "node",
                [...base, "--phase", "test", "--iterations", String(iterations), ...(interactive ? ["--interactive-safari"] : []),
                    ...(prepared ? ["--prepared-safari", JSON.stringify(prepared)] : []), ...selectedTests], {
                    dependencies, scratchDirectory: true, resultBundle: true, timeoutSeconds: (iterations === 1 ? 7200 : 21600) + SAFARI_STAGE_OVERHEAD_SECONDS,
                    requirements: ["node", "xcode", platform.requirement, ...(platform.id === "macos" ? ["safariAutomation"] : [])],
                    nativeAudit: {kind: "safari", platform: platform.id, configuration, signing, iterations,
                        synchronizationPolicy: expectedSynchronizationPolicy(platform.id),
                        activationMode: prepared ? "prepared" : interactive ? "interactive" : "automatic",
                        ...(prepared ? {preparation: structuredClone(prepared)} : {}),
                        requiredTests, requiredScenarios: scenarios.map(scenario => scenario.id),
                        filtered: scenarios.length !== safariTestsForPlatform([], platform).length},
                });
            runtime(`safari.${slug}`, 1, [`build-safari.${slug}`]);
            if (job.profile === "extended" && configuration === "Release") {
                runtime(`safari.soak-${platform.id}.release`, 10, [`safari.${slug}`]);
            }
        }
    }
    if (options.stages.includes("safari") && !stages.some(stage => stage.group === "safari")) {
        throw new Error("Safari selection did not match any known tests");
    }
    const selected = new Set(stages.filter(stage => !options.stages.length || options.stages.includes(stage.group)).map(stage => stage.id));
    for (const stage of stages) {
        if (selected.has(stage.id) && stage.nativeAudit?.runtime === true && stage.nativeAudit.configuration === "Debug" && stage.nativeAudit.kind === "full" &&
            (!stage.nativeAudit.filtered || debugPerformancePlatforms.has(stage.nativeAudit.platform))) {
            const requiredGates = PERFORMANCE_TESTS.filter(name => stage.nativeAudit.requiredTests.some(test =>
                test.includes("/WalletCoreProxyPerformanceGateTests/") && test.endsWith(`/${name}`)));
            const releaseAlreadySelected = stages.some(candidate => selected.has(candidate.id) && candidate.nativeAudit?.runtime === true &&
                candidate.nativeAudit.configuration === "Release" && candidate.nativeAudit.platform === stage.nativeAudit.platform &&
                requiredGates.every(name => candidate.nativeAudit.requiredTests.some(test => test.includes("/WalletCoreProxyPerformanceGateTests/") && test.endsWith(`/${name}`))));
            if (releaseAlreadySelected) { continue; }
            const gate = stage.nativeAudit.platform === "macos" ? "performance.release" : `performance.${stage.nativeAudit.platform}.release`;
            if (stages.some(candidate => candidate.id === gate)) { selected.add(gate); }
        }
    }
    const byID = new Map(stages.map(stage => [stage.id, stage]));
    const include = id => { for (const dependency of byID.get(id).dependencies) { if (!selected.has(dependency)) { selected.add(dependency); include(dependency); } } };
    for (const id of selected) { include(id); }
    return stages.filter(stage => selected.has(stage.id)).map(stage => {
        if ((options.signing ?? "local") === "local" && stage.command === "xcodebuild") {
            const {proofKey, ...local} = stage;
            const deviceBuild = stage.args.includes("generic/platform=iOS") || stage.args.includes("generic/platform=visionOS");
            stage = {...local,
                args: [...stage.args.filter(argument => !argument.startsWith("CODE_SIGNING_ALLOWED=")),
                    ...LOCAL_SIGNING_SETTINGS, `CODE_SIGNING_ALLOWED=${deviceBuild ? "NO" : "YES"}`],
                requirements: stage.requirements.filter(requirement => requirement !== "signing" && requirement !== "proofKey"),
            };
        }
        return {...stage, requirements: [...new Set(["bootstrap", ...stage.requirements])]};
    });
}

export function commandForStage(stage, {destinations, artifacts, scratch}) {
    const args = stage.args.map(arg => arg.startsWith("$destination:") ? destinations[arg.slice(13)] : arg);
    if (args.some(arg => typeof arg !== "string" || !arg)) { throw new Error(`Missing destination for ${stage.id}`); }
    if (stage.resultBundle) { args.push("-resultBundlePath", join(artifacts, `${stage.id}.xcresult`)); }
    if (stage.preparationResult) { args.push("--preparation-result", join(artifacts, `${stage.id}.safari-preparation.json`)); }
    if (stage.failureDirectory) { args.push("--failure-dir", join(artifacts, "failures", stage.id)); }
    if (stage.scratchDirectory) {
        if (typeof scratch !== "string" || !isAbsolute(scratch) || resolve(scratch) !== scratch ||
            scratch === artifacts || scratch.startsWith(`${artifacts}${sep}`)) {
            throw new Error(`Guest-local scratch is required for ${stage.id}`);
        }
        args.push("--scratch-dir", scratch);
    }
    if (args.some(arg => arg.includes("derivedDataPath"))) { throw new Error("Custom DerivedData is prohibited"); }
    return {command: stage.command, args};
}
