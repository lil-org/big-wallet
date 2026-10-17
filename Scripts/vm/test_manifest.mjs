import {isAbsolute, join, resolve, sep} from "node:path";

export const SELECTORS = ["build", "test", "performance", "tsan", "fuzz", "approval", "repository", "worker"];
export const BOOTSTRAP_TOOL_NAMES = ["VMGuestAgent", "guest_runner", "guest_bootstrap.mjs"];
export const PLATFORMS = [
    {id: "macos", target: "Tests macOS", scheme: "Wallet", generic: "generic/platform=macOS", requirement: "macos"},
    {id: "ios", target: "Tests iOS", scheme: "Wallet iOS", generic: "generic/platform=iOS", requirement: "ios"},
    {id: "visionos", target: "Tests visionOS", scheme: "Wallet visionOS", generic: "generic/platform=visionOS", requirement: "visionos"},
];
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
    const optionNames = new Set(["stages", "onlyTesting", "configuration", "approvalArgs"]);
    if (!options || typeof options !== "object" || Array.isArray(options) || Object.keys(options).some(key => !optionNames.has(key))) {
        throw new Error("Unsupported job payload");
    }
    if (!Array.isArray(options.stages) || options.stages.some(stage => !SELECTORS.includes(stage)) || new Set(options.stages).size !== options.stages.length) {
        throw new Error("Invalid stage selection");
    }
    if (!Array.isArray(options.onlyTesting) || options.onlyTesting.length > 200 || options.onlyTesting.some(test =>
        typeof test !== "string" || !PLATFORMS.some(platform => platform.target === test) &&
        !/^(?:(?:Tests macOS|Tests iOS|Tests visionOS)\/)?[A-Za-z_][A-Za-z0-9_]*(?:\/[A-Za-z_][A-Za-z0-9_]*(?:\(\))?)?$/.test(test))) {
        throw new Error("Invalid XCTest selection");
    }
    if (options.configuration !== undefined && !["Debug", "Release"].includes(options.configuration)) { throw new Error("Invalid configuration"); }
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

function validateApprovalArguments(args) {
    if (!Array.isArray(args) || args.length > 30 || args.some(arg => typeof arg !== "string" || arg.length > 2048 || arg.includes("\0"))) {
        throw new Error("Invalid approval arguments");
    }
    const switches = new Set(["--soak", "--no-minimize", "--random-only"]);
    const numbers = new Set(["--seed", "--sequences", "--steps", "--timeout-ms"]);
    for (let index = 0; index < args.length; index += 1) {
        const flag = args[index];
        if (switches.has(flag)) { continue; }
        const value = args[++index];
        if (numbers.has(flag) && typeof value === "string" && /^(?:0x[0-9a-f]+|[0-9]+)$/i.test(value)) { continue; }
        if (flag === "--mode" && ["alternate", "native", "popup"].includes(value)) { continue; }
        if (flag === "--replay" && typeof value === "string" && value.length && !value.startsWith("--")) { continue; }
        throw new Error(`Unsupported approval argument: ${flag}`);
    }
}

export function testingForPlatform(selectors, platform) {
    return selectors.flatMap(selector => {
        if (selector.startsWith("Tests ")) { return selector === platform.target || selector.startsWith(`${platform.target}/`) ? [selector] : []; }
        return [`${platform.target}/${selector}`];
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
    add("provider.bundle", "repository", "npm", ["run", "build"], {cwd: provider, dependencies: ["provider.install", "protocol.check"], unchanged: ["Safari Shared/Resources/inpage.js"]});
    add("provider.test", "test", "node", ["--test", "--test-concurrency=1", "--test-reporter=tap", "../Tests/*.test.mjs"], {
        cwd: provider, dependencies: ["provider.install", "protocol.check"],
    });
    for (const file of SHELL_TESTS) {
        add(`scripts.${file.slice(5, -3)}`, "repository", file.includes("asc_alchemy") ? "/bin/bash" : "/bin/sh", [`Scripts/tests/${file}`], {dependencies: ["provider.install"], requirements: ["node", "jq"]});
    }
    add("metadata.localizations", "repository", "/bin/bash", ["Scripts/asc/validate_localizations.sh"], {requirements: ["jq"]});
    add("scripts.approval-worker-target", "repository", "node", ["--test", "Scripts/tests/approval_worker_target.test.mjs"]);
    add("runner.node-tests", "repository", "node", ["--test", "Scripts/vm/tests/*.test.mjs"], {requirements: ["node", "xcode"]});
    add("runner.python-tests", "repository", "python3", ["-m", "unittest", "discover", "-s", "Scripts/vm/tests", "-p", "test_*.py"], {requirements: ["python", "node"]});
    add("worker.install", "worker", "npm", ["ci", "--no-audit"], {cwd: worker});
    for (const [id, script, suffix] of [
        ["check", "check", []], ["test", "test", []], ["validate-self", "validate:self", []],
        ["validate-dry-run", "validate:live", ["--", "--dry-run"]], ["deploy-dry-run", "deploy:dry-run", []], ["startup", "startup", []],
    ]) { add(`worker.${id}`, "worker", "npm", ["run", script, ...suffix], {cwd: worker, dependencies: ["worker.install"]}); }

    const configurations = options.configuration ? [options.configuration] : ["Debug", "Release"];
    for (const configuration of configurations) {
        for (const platform of PLATFORMS) {
            const slug = `${platform.id}.${configuration.toLowerCase()}`;
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
            const selectedTests = testingForPlatform(options.onlyTesting, platform);
            if (options.onlyTesting.length && !selectedTests.length) { continue; }
            if (options.configuration === "Debug") {
                const performanceClass = `${platform.target}/WalletCoreProxyPerformanceGateTests`;
                const performanceSelectors = [platform.target, performanceClass, ...PERFORMANCE_TESTS.map(name => `${performanceClass}/${name}`)];
                if (!selectedTests.length || selectedTests.some(test => performanceSelectors.includes(test.replace(/\(\)$/, "")))) {
                    debugPerformancePlatforms.add(platform.id);
                }
            }
            add(`test.${slug}`, "test", "xcodebuild", ["test-without-building", ...base, "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "on-failure",
                ...selectedTests.map(test => `-only-testing:${test}`)], {
                dependencies: [`build-tests.${slug}`], requirements: ["xcode", platform.requirement], timeoutSeconds: 7200,
                nativeAudit: {configuration, platform: platform.id, kind: "full", filtered: selectedTests.length > 0 && !selectedTests.includes(platform.target)},
                env: configuration === "Release" ? PERFORMANCE_ENV : {}, resultBundle: true,
            });
        }
    }
    const nativeBase = ["-jobs", "2", "-enableCodeCoverage", "NO", "test", "-project", "Wallet.xcodeproj", "-scheme", "Tests macOS",
        "-destination", "$destination:macos", "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "on-failure"];
    const nativeRequirements = ["node", "xcode", "proofKey", "macos", "signing"];
    const nativeDependencies = ["provider.install", "protocol.check"];
    add("performance.release", "performance", "xcodebuild", [...nativeBase, "-configuration", "Release", "ENABLE_TESTABILITY=YES",
        "-only-testing:Tests macOS/WalletCoreProxyPerformanceGateTests"], {
        dependencies: nativeDependencies, requirements: nativeRequirements, proofKey: true, timeoutSeconds: 7200,
        env: PERFORMANCE_ENV, nativeAudit: {configuration: "Release", platform: "macos", kind: "performance"}, resultBundle: true,
    });
    if (options.configuration === "Debug" && (!options.stages.length || options.stages.includes("test"))) {
        for (const platform of PLATFORMS.filter(platform => platform.id !== "macos" && debugPerformancePlatforms.has(platform.id))) {
            add(`performance.${platform.id}.release`, "performance", "xcodebuild", ["-jobs", "2", "-enableCodeCoverage", "NO", "test",
                "-project", "Wallet.xcodeproj", "-scheme", platform.target, "-configuration", "Release", "ENABLE_TESTABILITY=YES",
                "-destination", `$destination:${platform.id}`, "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "on-failure",
                ...PERFORMANCE_TESTS.map(name => `-only-testing:${platform.target}/WalletCoreProxyPerformanceGateTests/${name}`)], {
                dependencies: nativeDependencies, requirements: ["node", "xcode", "proofKey", platform.requirement], proofKey: true, timeoutSeconds: 7200,
                env: PERFORMANCE_ENV, nativeAudit: {configuration: "Release", platform: platform.id, kind: "performance"}, resultBundle: true,
            });
        }
    }
    for (const [id, classes] of [["tsan.focused", TSAN_TESTS], ...(job.profile === "extended" ? [["tsan.extended", EXTENDED_TSAN_TESTS]] : [])]) {
        add(id, "tsan", "xcodebuild", [...nativeBase, "-configuration", "Debug", "-enableThreadSanitizer", "YES", ...classes.map(test => `-only-testing:Tests macOS/${test}`)], {
            dependencies: nativeDependencies, requirements: nativeRequirements, proofKey: true, timeoutSeconds: 14400,
            nativeAudit: {configuration: "Debug", platform: "macos", kind: "tsan"}, resultBundle: true,
        });
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
        add(`approval.${slug}`, "approval", "/bin/sh", ["Scripts/check_approval_lifecycle.sh", ...(options.approvalArgs ?? [])], {
            dependencies: ["provider.install", "protocol.check"], requirements: ["node", "xcode"],
            timeoutSeconds: options.approvalArgs?.includes("--soak") ? 21600 : 7200,
            env: {APPROVAL_CONFIGURATION: configuration}, failureDirectory: true, scratchDirectory: true,
        });
        if (job.profile === "extended" && (options.approvalArgs ?? []).every(argument => argument === "--no-minimize")) {
            add(`approval.soak-${slug}`, "approval", "/bin/sh", ["Scripts/check_approval_lifecycle.sh", "--soak", "--seed", "42", ...(options.approvalArgs ?? [])], {
                dependencies: [`approval.${slug}`], requirements: ["node", "xcode"], timeoutSeconds: 21600,
                env: {APPROVAL_CONFIGURATION: configuration}, failureDirectory: true, scratchDirectory: true,
            });
        }
    }
    const selected = new Set(stages.filter(stage => !options.stages.length || options.stages.includes(stage.group)).map(stage => stage.id));
    for (const stage of stages) {
        if (selected.has(stage.id) && stage.nativeAudit?.configuration === "Debug" && stage.nativeAudit.kind === "full" &&
            (!stage.nativeAudit.filtered || debugPerformancePlatforms.has(stage.nativeAudit.platform))) {
            const gate = stage.nativeAudit.platform === "macos" ? "performance.release" : `performance.${stage.nativeAudit.platform}.release`;
            if (stages.some(candidate => candidate.id === gate)) { selected.add(gate); }
        }
    }
    const byID = new Map(stages.map(stage => [stage.id, stage]));
    const include = id => { for (const dependency of byID.get(id).dependencies) { if (!selected.has(dependency)) { selected.add(dependency); include(dependency); } } };
    for (const id of selected) { include(id); }
    return stages.filter(stage => selected.has(stage.id)).map(stage => ({...stage, requirements: [...new Set(["bootstrap", ...stage.requirements])]}));
}

export function commandForStage(stage, {destinations, artifacts, scratch}) {
    const args = stage.args.map(arg => arg.startsWith("$destination:") ? destinations[arg.slice(13)] : arg);
    if (args.some(arg => typeof arg !== "string" || !arg)) { throw new Error(`Missing destination for ${stage.id}`); }
    if (stage.resultBundle) { args.push("-resultBundlePath", join(artifacts, `${stage.id}.xcresult`)); }
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
