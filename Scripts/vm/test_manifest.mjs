import {readFileSync} from "node:fs";
import {isAbsolute, join, resolve, sep} from "node:path";
import {SAFARI_SCENARIOS, SAFARI_TEST_CLASS} from "../safari/scenarios.mjs";
import {expectedSynchronizationPolicy} from "../safari/synchronization.mjs";
import {RUNTIME_MODULES, RUNTIME_TEST_TARGETS, TSAN_FOCUS, candidateTargets, focusMayMatch, isCompileOnlyTarget, matchesTestSelector} from "./test_policy.mjs";
import {BASELINE as UPGRADE_BASELINE} from "../wallet_upgrade/contract.mjs";
const mutationManifest = JSON.parse(readFileSync(new URL("../security_mutations/manifest.json", import.meta.url), "utf8"));

export {RUNTIME_MODULES, RUNTIME_TEST_TARGETS};

export const SELECTORS = ["build", "test", "performance", "tsan", "asan", "fuzz", "parser-fuzz", "mutation", "approval", "upgrade", "safari", "repository", "worker", "runtime"];
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
export const ASAN_RUNTIME_TESTS = [
    "SecretBytesTests", "ScryptROMixShimTests", "WalletCoreProxyCoinAndCryptoTests",
    "WalletCoreProxyPrivateKeyTests", "WalletCoreProxyHDWalletTests", "WalletCoreProxyStoredKeyTests",
    "WalletCoreProxyParallelDerivationTests", "WalletSigningSessionTests", "WalletSigningScopeTests",
    "UnlockedAccountSignerTests", "WalletsManagerPrivateKeyImportTests",
    "WalletCoreProxyPerformanceGateTests/testScryptDefaultParametersAndSequentialDerivationVectors",
].map(name => `WalletAuthorityTests/${name}`);
export const ASAN_APP_TESTS = [
    "SecretHandlingTests", "MacSecretLifetimeTests", "NativeSecretAlertPresentationTests",
].map(name => `Tests macOS/${name}`);
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
    const optionNames = new Set(["stages", "onlyTesting", "configuration", "approvalArgs", "parserFuzzReplay", "signing", "interactiveSafari", "prepareSafari", "preparedSafari", "runtimePlatforms", "expectedMacOS"]);
    if (!options || typeof options !== "object" || Array.isArray(options) || Object.keys(options).some(key => !optionNames.has(key))) {
        throw new Error("Unsupported job payload");
    }
    if (options.expectedMacOS !== undefined && (!options.expectedMacOS || typeof options.expectedMacOS !== "object" ||
        Object.keys(options.expectedMacOS).sort().join(",") !== "buildVersion,version" ||
        typeof options.expectedMacOS.version !== "string" || !/^[0-9]+(?:\.[0-9]+){1,2}$/.test(options.expectedMacOS.version) ||
        typeof options.expectedMacOS.buildVersion !== "string" || !/^[0-9]+[A-Z][0-9]+[a-z]?$/.test(options.expectedMacOS.buildVersion))) {
        throw new Error("Invalid expected macOS identity");
    }
    if (!Array.isArray(options.stages) || options.stages.some(stage => !SELECTORS.includes(stage)) || new Set(options.stages).size !== options.stages.length) {
        throw new Error("Invalid stage selection");
    }
    if (!Array.isArray(options.onlyTesting) || options.onlyTesting.length > 200 || options.onlyTesting.some(test =>
        typeof test !== "string" || !TEST_TARGETS.includes(test) &&
        !/^(?:(?:(?:Safari UI )?Tests macOS|(?:Safari UI )?Tests iOS|Tests visionOS|Wallet(?:Domain|Authority|Flows|Networking)Tests)\/)?[A-Za-z_][A-Za-z0-9_]*(?:\/[A-Za-z_][A-Za-z0-9_]*(?:\(\))?)?$/.test(test))) {
        throw new Error("Invalid XCTest selection");
    }
    for (const selector of options.onlyTesting) {
        if (value.kind === "run" && isCompileOnlyTarget(selector) && options.stages.length && !options.stages.includes("runtime")) {
            throw new Error(`Compile-only selector ${selector} requires --stage runtime`);
        }
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
    if (options.parserFuzzReplay !== undefined && (value.kind !== "run" ||
        options.parserFuzzReplay === null || typeof options.parserFuzzReplay !== "object" ||
        Object.keys(options.parserFuzzReplay).sort().join(",") !== "path,sha256" ||
        options.parserFuzzReplay.path !== "/Volumes/BigWalletBuild/Exchange/inputs/parser-fuzz-replay.json" ||
        typeof options.parserFuzzReplay.sha256 !== "string" || !/^[a-f0-9]{64}$/.test(options.parserFuzzReplay.sha256) ||
        options.stages.length !== 1 || !["fuzz", "parser-fuzz"].includes(options.stages[0]) || options.onlyTesting.length)) {
        throw new Error("Native parser replay requires only --stage fuzz or --stage parser-fuzz and a staged replay artifact");
    }
    if (options.stages.includes("mutation") && options.onlyTesting.length) {
        throw new Error("Mutation verification uses its declared witness inventory and does not accept --only-testing");
    }
    if (options.stages.includes("parser-fuzz") && options.onlyTesting.length) {
        throw new Error("Native parser fuzzing uses its declared case inventory and does not accept --only-testing");
    }
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
    if (value.kind === "run" && options.stages.length && !options.stages.some(stage => ["test", "tsan", "asan"].includes(stage))) {
        for (const selector of options.onlyTesting) {
            if (isSafariSelector(selector)) { continue; }
            if (options.stages.includes("build") && TEST_TARGETS.includes(selector)) { continue; }
            if (options.stages.includes("runtime") && (isCompileOnlyTarget(selector) || RUNTIME_TEST_TARGETS.includes(selector))) { continue; }
            throw new Error(`XCTest selector did not match a selected stage that accepts it: ${selector}. Use --stage test for individual classes or methods.`);
        }
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

export function safariTestsForPlatform(selectors, platform) {
    const scenarios = SAFARI_SCENARIOS.filter(scenario => scenario.platforms.includes(platform.id));
    return scenarios.filter(scenario => {
        const identifier = `${platform.target}/${SAFARI_TEST_CLASS}/${scenario.method}`;
        return !selectors.length || selectors.some(selector => matchesTestSelector(identifier, selector));
    });
}

export function createManifest(job) {
    validateJob(job);
    const options = job.payload;
    const stages = [];
    const makeStage = (id, group, command, args, extra = {}) => ({
        id, group, command, args, cwd: ".", dependencies: [], requirements: ["node"], timeoutSeconds: 900, ...extra,
    });
    const add = (...args) => stages.push(makeStage(...args));
    const provider = "Safari Shared/Inpage Provider";
    const worker = "Workers/alchemy-jwt";
    add("provider.install", "repository", "npm", ["ci", "--include=dev", "--include=optional", "--no-audit"], {cwd: provider});
    add("protocol.check", "repository", "node", ["Scripts/generate_wire_protocol.mjs", "--check"]);
    add("pins.check", "repository", "python3", ["Scripts/vm/environment_pins.py", "--check"], {requirements: ["python"]});
    add("runtime.test-membership", "repository", "node", ["Scripts/vm/test_membership.mjs"], {requirements: ["node", "xcode"]});
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
    add("scripts.parser-fuzz-target", "repository", "node", ["--test", "Scripts/tests/parser_fuzz_target.test.mjs"], {requirements: ["node", "xcode"]});
    add("scripts.native-parser-fuzz", "repository", "node", ["--test", "Scripts/native_parser_fuzz/*.test.mjs"], {dependencies: ["provider.install"]});
    add("scripts.security-mutations", "repository", "node", ["--test", "Scripts/security_mutations/*.test.mjs"]);
    add("upgrade.archive", "repository", "python3", ["Scripts/wallet_upgrade/archive.py", "--verify"], {requirements: ["python"]});
    add("runner.node-tests", "repository", "node", ["--test", "Scripts/vm/tests/*.test.mjs"], {requirements: ["node", "xcode", "python"]});
    add("runner.python-tests", "repository", "python3", ["-m", "unittest", "discover", "-s", "Scripts/vm/tests", "-p", "test_*.py"], {requirements: ["python", "node"]});
    add("safari.runner-tests", "repository", "node", ["--test", "Scripts/safari/tests/*.test.mjs"], {dependencies: ["provider.install"]});
    add("worker.install", "worker", "npm", ["ci", "--no-audit"], {cwd: worker});
    for (const [id, script, suffix] of [
        ["check", "check", []], ["test", "test", []], ["validate-self", "validate:self", []],
        ["validate-dry-run", "validate:live", ["--", "--dry-run"]], ["deploy-dry-run", "deploy:dry-run", []], ["startup", "startup", []],
    ]) { add(`worker.${id}`, "worker", "npm", ["run", script, ...suffix], {cwd: worker, dependencies: ["worker.install"]}); }

    const configurations = options.configuration ? [options.configuration] : ["Debug", "Release"];
    const runtimeSelected = platform => (!options.runtimePlatforms?.length || options.runtimePlatforms.includes(platform)) &&
        candidateTargets(options.onlyTesting, platform, true).length > 0;
    const apiValidation = !options.stages.length || ["build", "performance", "tsan"].some(group => options.stages.includes(group)) ||
        options.stages.includes("test") && PLATFORMS.some(platform => runtimeSelected(platform.id));
    const nativeStages = (id, group, args, policy, extra = {}) => {
        const buildID = policy.kind === "full"
            ? `${policy.runtime ? "build-runtime-tests" : "build-tests"}.${policy.platform}.${policy.configuration.toLowerCase()}`
            : `build-${id}`;
        const buildArgs = ["build-for-testing", ...args, "ENABLE_TESTABILITY=YES"];
        const groupForBuild = policy.kind === "full" ? "build" : group;
        const cleanID = `clean-${id}`;
        const platform = PLATFORMS.find(platform => platform.id === policy.platform);
        const clean = makeStage(cleanID, groupForBuild, "xcodebuild", policy.runtime
            ? ["clean", "-scheme", "WalletRuntime-Package", "-configuration", policy.configuration,
                "-destination", `$destination:${policy.platform}`]
            : ["clean", "-project", "Wallet.xcodeproj", "-scheme", platform.scheme,
                "-configuration", policy.configuration, "-destination", `$destination:${policy.platform}`], {
            cwd: extra.cwd ?? ".", dependencies: extra.dependencies ?? [],
            requirements: ["xcode", platform.requirement], timeoutSeconds: 300,
        });
        const dependencies = [cleanID];
        const build = makeStage(buildID, groupForBuild, "xcodebuild", buildArgs, {
            ...extra, dependencies, timeoutSeconds: 3600,
            ...(policy.runtime ? {runtimeTestability: RUNTIME_MODULES} : {}),
        });
        const {proofKey, runtimeTestability, ...execution} = extra;
        const discovery = makeStage(`discover.${id}`, group, "xcodebuild", ["test-without-building", ...args], {
            ...execution, dependencies: [buildID], requirements: ["xcode", policy.platform],
            nativeDiscovery: {...policy, executionID: id, scheme: args[args.indexOf("-scheme") + 1],
                targets: policy.runtime ? RUNTIME_TEST_TARGETS : [PLATFORMS.find(platform => platform.id === policy.platform).target],
                selectors: policy.kind === "performance" ? [] : options.onlyTesting.filter(selector => !isSafariSelector(selector) && !isCompileOnlyTarget(selector))},
        });
        return [clean, build, discovery];
    };
    const addNative = (...args) => stages.push(...nativeStages(...args));
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
            if (runtimeSelected(platform.id)) {
                addNative(`test-runtime.${slug}`, "test", ["-jobs", "2", "-enableCodeCoverage", "NO", "-scheme", "WalletRuntime-Package",
                    "-configuration", configuration, "-destination", `$destination:${platform.id}`,
                    "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "CODE_SIGNING_ALLOWED=YES"],
                    {configuration, platform: platform.id, kind: "full", runtime: true,
                        ...(configuration === "Debug" && platform.id === "macos" ? {
                            mutationWitnesses: mutationManifest.mutants.filter(mutant => mutant.family === "runtime").map(mutant => mutant.witness.selector),
                        } : {})}, {
                        cwd: "Packages/WalletRuntime", dependencies: ["runtime.test-membership", ...(apiValidation ? [`runtime.api.${configuration.toLowerCase()}`] : [])],
                        requirements: ["xcode", platform.requirement], timeoutSeconds: 7200,
                        env: configuration === "Release" ? PERFORMANCE_ENV : {},
                    });
            }
            const signing = platform.id === "macos" ? ["signing"] : [];
            add(`build.${slug}`, "build", "xcodebuild", ["-jobs", "2", "build", "-project", "Wallet.xcodeproj", "-scheme", platform.scheme,
                "-configuration", configuration, "-destination", platform.generic, ...(platform.id === "macos" ? [] : ["CODE_SIGNING_ALLOWED=NO"])], {
                dependencies: ["provider.install", "protocol.check"], requirements: ["node", "xcode", "proofKey", ...signing], proofKey: true, timeoutSeconds: 3600,
            });
            if (candidateTargets(options.onlyTesting, platform.id, false).length) {
                addNative(`test.${slug}`, "test", ["-jobs", "2", "-enableCodeCoverage", "NO", "-project", "Wallet.xcodeproj", "-scheme", platform.target,
                    "-configuration", configuration, "-destination", `$destination:${platform.id}`],
                    {configuration, platform: platform.id, kind: "full"}, {
                        dependencies: ["provider.install", "protocol.check", "runtime.test-membership"],
                        requirements: ["node", "xcode", "proofKey", platform.requirement, ...signing], proofKey: true, timeoutSeconds: 7200,
                        env: configuration === "Release" ? PERFORMANCE_ENV : {},
                    });
            }
        }
    }
    const nativeBase = ["-jobs", "2", "-enableCodeCoverage", "NO", "-project", "Wallet.xcodeproj", "-scheme", "Tests macOS"];
    const nativeRequirements = ["node", "xcode", "proofKey", "macos", "signing"];
    const nativeDependencies = ["provider.install", "protocol.check", "runtime.test-membership"];
    const runtimeChecks = ["runtime.test-membership", ...(apiValidation ? [`runtime.api.${configurations.includes("Release") ? "release" : "debug"}`] : [])];
    const runtimePerformanceTests = PERFORMANCE_TESTS.map(name => `WalletAuthorityTests/WalletCoreProxyPerformanceGateTests/${name}`);
    const runtimeNativeBase = ["-jobs", "2", "-enableCodeCoverage", "NO", "-scheme", "WalletRuntime-Package",
        "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "CODE_SIGNING_ALLOWED=YES"];
    const releaseProof = new Map();
    for (const platform of PLATFORMS.filter(platform => platform.id === "macos" || options.configuration === "Debug" && (!options.stages.length || options.stages.includes("test")) && runtimeSelected(platform.id))) {
        const id = platform.id === "macos" ? "performance.release" : `performance.${platform.id}.release`;
        const proof = nativeStages(id, "performance", [...runtimeNativeBase, "-configuration", "Release", "-destination", `$destination:${platform.id}`],
            {configuration: "Release", platform: platform.id, kind: "performance", runtime: true, focus: runtimePerformanceTests}, {
                cwd: "Packages/WalletRuntime", dependencies: runtimeChecks, requirements: ["xcode", platform.requirement], timeoutSeconds: 7200, env: PERFORMANCE_ENV,
            });
        releaseProof.set(platform.id, proof);
        if (platform.id === "macos") { stages.push(...proof); }
    }
    for (const [name, focus] of Object.entries(TSAN_FOCUS)) {
        if (name === "extended" && job.profile !== "extended") { continue; }
        for (const runtime of [true, false]) {
            const tests = runtime ? focus.runtime : focus.app;
            if (!focusMayMatch(options.onlyTesting, tests)) { continue; }
            addNative(`tsan.${name}${runtime ? ".runtime" : ""}`, "tsan",
                [...(runtime ? runtimeNativeBase : nativeBase), "-configuration", "Debug", "-destination", "$destination:macos",
                    "-enableThreadSanitizer", "YES", "-enableAddressSanitizer", "NO"],
                {configuration: "Debug", platform: "macos", kind: "tsan", runtime, focus: tests}, {
                    cwd: runtime ? "Packages/WalletRuntime" : ".", dependencies: runtime ? runtimeChecks : nativeDependencies,
                    requirements: runtime ? ["xcode", "macos"] : nativeRequirements, ...(!runtime ? {proofKey: true} : {}), timeoutSeconds: 14400,
                });
        }
    }
    for (const runtime of [true, false]) {
        const tests = runtime ? ASAN_RUNTIME_TESTS : ASAN_APP_TESTS;
        if (!focusMayMatch(options.onlyTesting, tests)) { continue; }
        addNative(`asan.focused${runtime ? ".runtime" : ""}`, "asan",
            [...(runtime ? runtimeNativeBase : nativeBase), "-configuration", "Debug", "-destination", "$destination:macos",
                "-enableAddressSanitizer", "YES", "-enableThreadSanitizer", "NO"],
            {configuration: "Debug", platform: "macos", kind: "asan", runtime, focus: tests}, {
                cwd: runtime ? "Packages/WalletRuntime" : ".", dependencies: runtime ? runtimeChecks : nativeDependencies,
                requirements: runtime ? ["xcode", "macos"] : nativeRequirements, ...(!runtime ? {proofKey: true} : {}), timeoutSeconds: 14400,
            });
    }
    for (const kind of ["asan", "tsan"]) {
        if (options.stages.includes(kind) && !stages.some(stage => stage.nativeDiscovery?.kind === kind)) {
            throw new Error(`Explicit ${kind} selection did not match any focused tests`);
        }
    }
    if (!options.parserFuzzReplay) {
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
    }
    const nativeFuzzPhases = options.parserFuzzReplay ? ["build", "replay"] : ["build", "canaries", "parsers", "decrypt"];
    for (const [index, phase] of nativeFuzzPhases.entries()) {
        add(`fuzz.native.${phase}`, "fuzz", "node", ["Scripts/native_parser_fuzz/run.mjs", "--phase", phase, "--profile", job.profile,
            ...(phase === "replay" ? ["--replay", options.parserFuzzReplay.path] : [])], {
            dependencies: index === 0 ? ["runtime.boundaries", "scripts.parser-fuzz-target", "scripts.native-parser-fuzz"]
                : [`fuzz.native.${nativeFuzzPhases[index - 1]}`, "provider.install"],
            requirements: ["node", "xcode", "macos"], failureDirectory: true,
            timeoutSeconds: phase === "build" ? 1800 : job.profile === "extended" ? 3720 : 720,
            parserFuzzAudit: {phase, profile: job.profile, sourceSHA256: job.source.sha256,
                ...(phase === "replay" ? {replaySHA256: options.parserFuzzReplay.sha256} : {})},
        });
    }
    if (!options.onlyTesting.length) {
        const tier = job.profile === "extended" ? "extended" : "core";
        const apple = options.signing === "apple";
        add("mutation.security", "mutation", "node", ["Scripts/security_mutations/run.mjs", "--tier", tier,
            "--destination-macos", "$destination:macos", ...(tier === "extended" ? ["--destination-ios", "$destination:ios"] : []),
            "--signing", options.signing ?? "local"], {
            dependencies: ["runtime.test-membership", "runtime.boundaries", "provider.install", "protocol.check", "scripts.security-mutations"],
            requirements: ["node", "xcode", "macos", ...(tier === "extended" ? ["ios"] : []), ...(apple ? ["signing", "proofKey"] : [])],
            ...(apple ? {proofKey: true} : {}), failureDirectory: true, scratchDirectory: true,
            timeoutSeconds: (tier === "extended" ? 7200 : 3600) + 120,
            mutationAudit: {tier, signing: options.signing ?? "local", sourceSHA256: job.source.sha256},
        });
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
    const selected = new Set(stages.filter(stage => !options.stages.length || options.stages.includes(stage.group) ||
        options.stages.includes("parser-fuzz") && stage.parserFuzzAudit).map(stage => stage.id));
    const byID = new Map(stages.map(stage => [stage.id, stage]));
    const include = id => { for (const dependency of byID.get(id).dependencies) { if (!selected.has(dependency)) { selected.add(dependency); include(dependency); } } };
    for (const id of selected) { include(id); }
    const configure = stage => {
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
    };
    return stages.filter(stage => selected.has(stage.id)).map(stage => {
        const policy = stage.nativeDiscovery;
        if (options.configuration === "Debug" && policy?.runtime && policy.kind === "full") {
            const proof = releaseProof.get(policy.platform);
            if (!proof.every(stage => selected.has(stage.id))) {
                stage = {...stage, releaseStages: proof.map(configure)};
            }
        }
        return configure(stage);
    });
}

export function commandForStage(stage, {destinations, artifacts, scratch}) {
    const args = stage.args.map(arg => arg.startsWith("$destination:") ? destinations[arg.slice(13)] : arg);
    if (args.some(arg => typeof arg !== "string" || !arg)) { throw new Error(`Missing destination for ${stage.id}`); }
    if (stage.resultBundle) { args.push("-resultBundlePath", join(artifacts, `${stage.id}.xcresult`)); }
    if (stage.preparationResult) { args.push("--preparation-result", join(artifacts, `${stage.id}.safari-preparation.json`)); }
    if (stage.failureDirectory) { args.push("--failure-dir", join(artifacts, "failures", stage.id)); }
    if (stage.parserFuzzAudit) { args.push("--report", join(artifacts, "failures", stage.id, "parser-fuzz-report.json")); }
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

export function stagePlan(stages) {
    return stages.map(stage => ({id: stage.id, group: stage.group, status: "pending",
        ...Object.fromEntries(["nativeAudit", "nativeDiscovery", "discoveryStage", "approvalAudit", "upgradeAudit", "parserFuzzAudit", "mutationAudit"]
            .filter(key => stage[key] !== undefined).map(key => [key, stage[key]])),
        ...(stage.preparationResult ? {preparationResult: true} : {})}));
}
