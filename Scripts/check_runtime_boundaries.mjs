import {execFileSync, spawnSync} from "node:child_process";
import {existsSync, readFileSync, readdirSync, realpathSync} from "node:fs";
import {dirname, isAbsolute, join, relative, resolve, sep} from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";
import {inspectSwiftPackage, namedInventory} from "./harness_package.mjs";
import {runtimeLibraries as libraries, runtimeTargets as productionTargets, validateRuntimeProducts, validateRuntimeTarget, validateTargetSources} from "./runtime_policy.mjs";
const applicationRoots = ["App iOS", "App macOS", "App visionOS", "Big Wallet Ambient", "Safari Shared", "Safari macOS", "Safari iOS", "Safari visionOS", "Shared"];
const applicationOnlySources = new Set([
    "Shared/Services/ApplicationServices.swift", "Shared/Services/SafariVMApplicationServices.swift",
    "Shared/Wallets/AccountNames.swift", "Shared/Ethereum/Networks.swift", "Shared/Services/ReviewRequester.swift",
]);
export const vmFixtureSources = new Set([
    "Shared/Services/SafariVMFixtures.swift", "Shared/Services/SafariVMApplicationServices.swift",
    "Safari Shared/SafariVMExtensionServices.swift",
]);
const fixtureFileNames = [...vmFixtureSources].map(path => path.slice(path.lastIndexOf("/") + 1));

function maskNonCode(source, {strings = true} = {}) {
    let result = "", index = 0;
    const blank = value => value.replace(/[^\n]/g, " ");
    while (index < source.length) {
        if (source.startsWith("//", index)) {
            const end = source.indexOf("\n", index);
            const stop = end < 0 ? source.length : end;
            result += blank(source.slice(index, stop)); index = stop;
        } else if (source.startsWith("/*", index)) {
            const start = index; let depth = 1; index += 2;
            while (index < source.length && depth) {
                if (source.startsWith("/*", index)) { depth += 1; index += 2; }
                else if (source.startsWith("*/", index)) { depth -= 1; index += 2; }
                else { index += 1; }
            }
            if (depth) { throw new Error("Unterminated source comment"); }
            result += blank(source.slice(start, index));
        } else {
            const match = /^(#*)("""|")/.exec(source.slice(index));
            if (!match) { result += source[index++]; continue; }
            const start = index, delimiter = match[2] + match[1];
            index += match[0].length;
            while (index < source.length && !source.startsWith(delimiter, index)) {
                if (source[index] === "\\" && !match[1]) { index += 2; }
                else { index += 1; }
            }
            if (index >= source.length) { throw new Error("Unterminated source string"); }
            index += delimiter.length;
            const value = source.slice(start, index);
            result += strings ? blank(value) : value;
        }
    }
    return result;
}

export function validateRuntimeManifestSource(source) {
    const text = maskNonCode(source, {strings: false});
    if (/BW_SAFARI_VM_TESTING|enable-testing|-package-name|\bpackageAccess\s*:\s*false\b/.test(text)) {
        throw new Error("Runtime manifest contains a forbidden test or package-identity setting");
    }
}

export function validateRuntimePackage({manifest, description}, root) {
    const packageRoot = resolve(root, "Packages/WalletRuntime");
    if (description?.name !== "WalletRuntime" || description.path !== packageRoot ||
        !Array.isArray(description.dependencies) || description.dependencies.length ||
        !Array.isArray(manifest?.dependencies) || manifest.dependencies.length) {
        throw new Error("Runtime must be the expected local package without external dependencies");
    }
    for (const inventory of [manifest.products, description.products]) {
        validateRuntimeProducts(inventory);
    }
    const targets = namedInventory(manifest.targets, "runtime target");
    if (targets.get("WalletRuntimeTestSupport")?.type !== "regular") {
        throw new Error("WalletRuntimeTestSupport must be a regular target");
    }
    const descriptions = namedInventory(description.targets, "described runtime target");
    if (targets.size !== descriptions.size || [...targets.keys()].some(name => !descriptions.has(name))) {
        throw new Error("Runtime target descriptions do not match the evaluated manifest");
    }
    for (const [name, target] of targets) {
        if (!productionTargets.includes(name) && target.type !== "test" && name !== "WalletRuntimeTestSupport") {
            throw new Error(`Unexpected runtime target: ${name}`);
        }
        if (target.packageAccess === false || /-package-name/.test(JSON.stringify(target.settings ?? []))) {
            throw new Error("Runtime compiler package identity may not be overridden");
        }
    }
    for (const name of productionTargets) {
        const target = targets.get(name);
        const described = descriptions.get(name);
        validateRuntimeTarget(target, name);
        const directory = join(packageRoot, "Sources", name);
        if (typeof described?.path !== "string" || resolve(packageRoot, described.path) !== directory ||
            target.path != null && (typeof target.path !== "string" || resolve(packageRoot, target.path) !== directory)) {
            throw new Error(`Production target ${name} has unexpected source membership`);
        }
        validateTargetSources(target, described, packageRoot);
    }
    return true;
}

export function validateRuntimeSource(path, source, {module, application = false} = {}) {
    const code = maskNonCode(source);
    const fail = message => { throw new Error(`${path}: ${message}`); };
    const fixture = application && vmFixtureSources.has(path.split(sep).join("/"));
    if (!fixture && /@testable\b/.test(code)) { fail("Production code may not use @testable"); }
    const imports = [...code.matchAll(/\bimport\s+(?:(?:class|struct|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z_][A-Za-z0-9_]*)/g)].map(match => match[1]);
    if (imports.some(name => /(?:TestSupport|Harness|Tests)$|WalletUpgradeConsumer|ShippedWalletProducer/.test(name))) { fail("Production code imports test or harness support"); }
    const foreignSymbols = [...code.matchAll(/@_silgen_name\b/g)].map(match =>
        /^@_silgen_name\s*\(\s*"([^"\n]+)"\s*\)/.exec(source.slice(match.index))?.[1]);
    const permitsFileLockBinding = module === "WalletStorageSupport" || fixture;
    if (module !== "WalletAuthority" && (imports.includes("CWalletCrypto") || foreignSymbols.some(symbol => !permitsFileLockBinding || symbol !== "flock"))) { fail("Direct private crypto linkage belongs inside Authority"); }
    if (application && imports.includes("WalletStorageSupport")) { fail("Application code imports private storage implementation"); }
    if (module === "WalletDomain" && imports.some(name => !["Foundation", "CoreFoundation", "CryptoKit", "Synchronization"].includes(name))) {
        fail("Domain imports a service or UI module");
    }
    if (module === "WalletAuthority" && imports.some(name => ["WalletNetworking", "WalletFlows"].includes(name))) { fail("Authority imports networking or flows"); }
    if (module === "WalletFlows" && imports.some(name => ["Security", "LocalAuthentication", "WalletStorageSupport", "WalletNetworking"].includes(name))) {
        fail("Flows imports privileged implementation or networking");
    }
    if (module === "WalletNetworking" && imports.some(name => ["WalletAuthority", "WalletFlows", "LocalAuthentication"].includes(name))) {
        fail("Networking imports wallet or signing authority");
    }
    return true;
}

function decodePlist(source) {
    return JSON.parse(execFileSync("/usr/bin/plutil", ["-convert", "json", "-o", "-", "--", "-"], {
        input: source, encoding: "utf8", maxBuffer: 16 * 1024 * 1024,
    }));
}

function rejectDuplicateProjectKeys(source) {
    const dictionaries = [new Set()];
    let expectingKey = true;
    const tokens = /\/\/[^\r\n\u2028\u2029]*|\/\*[\s\S]*?\*\/|"(?:\\[\s\S]|[^"\\])*"|'(?:\\[\s\S]|[^'\\])*'|[\w$/:.\-]+|[{};]/g;
    for (const [token] of source.matchAll(tokens)) {
        if (token.startsWith("//") || token.startsWith("/*")) { continue; }
        if (token === "{") { dictionaries.push(new Set()); expectingKey = true; continue; }
        if (token === "}") { dictionaries.pop(); expectingKey = false; continue; }
        if (token === ";") { expectingKey = true; continue; }
        if (!expectingKey || !dictionaries.length) { continue; }
        const keys = dictionaries.at(-1);
        let key = token;
        if (token[0] === '"' || token[0] === "'") {
            key = token.includes("\\") ? decodePlist("(" + token + ")")[0] : token.slice(1, -1);
        }
        if (keys.has(key)) { throw new Error("Duplicate Xcode project key: " + key); }
        keys.add(key);
        expectingKey = false;
    }
}

export function readProject(path) {
    const source = readFileSync(path, "utf8");
    rejectDuplicateProjectKeys(source);
    return decodePlist(source);
}

export function projectFilePaths(project, root) {
    const objects = project.objects;
    if (!objects || !project.rootObject || objects[project.rootObject]?.isa !== "PBXProject") { throw new Error("Invalid Xcode project inventory"); }
    const paths = new Map;
    const walk = (id, parent) => {
        const value = objects[id];
        if (!value) { throw new Error(`Missing project object ${id}`); }
        const base = value.sourceTree === "SOURCE_ROOT" ? root : parent;
        const path = value.path ? resolve(base, value.path) : base;
        paths.set(id, path);
        for (const child of value.children ?? []) { walk(child, path); }
    };
    walk(objects[project.rootObject].mainGroup, root);
    return paths;
}

export function validateProjectMembership(project, {root, sourceExists = existsSync, validateSource = () => {}} = {}) {
    const objects = project.objects;
    const paths = projectFilePaths(project, root);
    const projectConfigurations = objects[objects[project.rootObject].buildConfigurationList]?.buildConfigurations ?? [];
    const projectSettings = new Map(projectConfigurations.map(id => [objects[id].name, objects[id].buildSettings ?? {}]));
    const words = value => (Array.isArray(value) ? value : [value ?? ""]).flatMap(value => value.split(/\s+/)).filter(Boolean);
    for (const target of Object.values(objects).filter(value => value.isa === "PBXNativeTarget")) {
        if (/test/i.test(target.productType ?? "") || /Tests/.test(target.name ?? "")) { continue; }
        const nativeExtension = target.productType === "com.apple.product-type.app-extension";
        if (/Harness|CrashWorker|UpgradeConsumer|ShippedWalletProducer|TestSupport/.test(target.name ?? "")) { throw new Error(`Xcode production graph contains fixture target ${target.name}`); }
        for (const dependencyID of target.packageProductDependencies ?? []) {
            const name = objects[dependencyID]?.productName;
            if (!name || /Harness|UpgradeConsumer|ShippedWalletProducer|Tests|TestSupport|WalletStorageSupport|CWalletCrypto/.test(name)) { throw new Error(`${target.name} links a private/test product: ${name}`); }
        }
        for (const dependencyID of target.dependencies ?? []) {
            const reference = objects[dependencyID];
            const dependency = objects[reference?.target];
            const dependencyName = dependency?.name ?? objects[reference?.targetProxy]?.remoteInfo ?? "";
            if (/Harness|CrashWorker|UpgradeConsumer|ShippedWalletProducer|Tests|TestSupport/.test(dependencyName)) { throw new Error(`${target.name} depends on a fixture/test target`); }
        }
        for (const configurationID of objects[target.buildConfigurationList]?.buildConfigurations ?? []) {
            const configuration = objects[configurationID];
            const settings = configuration.buildSettings ?? {};
            const inherited = projectSettings.get(configuration.name) ?? {};
            const effective = name => settings[name] === undefined ? words(inherited[name])
                : words(settings[name]).flatMap(value => value === "$(inherited)" ? words(inherited[name]) : [value]);
            if (fixtureFileNames.some(name => !effective("BW_VM_FIXTURE_EXCLUDED_SOURCES").includes(name)) ||
                !effective("EXCLUDED_SOURCE_FILE_NAMES").includes("$(BW_VM_FIXTURE_EXCLUDED_SOURCES)")) {
                throw new Error(`${target.name} must exclude VM fixture sources in ordinary builds`);
            }
            if (nativeExtension && effective("APPLICATION_EXTENSION_API_ONLY").join(" ") !== "YES") {
                throw new Error(`${target.name} must enforce application-extension API availability`);
            }
            if (/CWalletCrypto|WalletStorageSupport|WalletRuntimeHarness|WalletUpgradeHarness|WalletUpgradeConsumer|ShippedWalletProducer|wallet_upgrade|ShippedMain|WalletRuntimeTestSupport/.test(JSON.stringify(settings))) {
                throw new Error(`${target.name} manually links private runtime/test implementation`);
            }
        }
        for (const phaseID of target.buildPhases ?? []) {
            const phase = objects[phaseID];
            if (phase?.isa === "PBXFrameworksBuildPhase") {
                for (const buildID of phase.files ?? []) {
                    const product = objects[objects[buildID]?.productRef]?.productName;
                    if (product && /Harness|UpgradeConsumer|ShippedWalletProducer|Tests|TestSupport|WalletStorageSupport|CWalletCrypto/.test(product)) {
                        throw new Error(`${target.name} links a private/test framework: ${product}`);
                    }
                }
            }
            if (phase?.isa === "PBXResourcesBuildPhase") {
                for (const buildID of phase.files ?? []) {
                    const path = paths.get(objects[buildID]?.fileRef);
                    if (path && /(?:^|\/)(?:ShippedMain|wallet_upgrade|WalletUpgradeHarness)(?:\/|$)/.test(path.split(sep).join("/"))) {
                        throw new Error(`${target.name} packages an upgrade test artifact`);
                    }
                }
            }
            if (phase?.isa !== "PBXSourcesBuildPhase") { continue; }
            for (const buildID of phase.files ?? []) {
                const path = paths.get(objects[buildID]?.fileRef);
                if (!path || !sourceExists(path)) { throw new Error(`${target.name} compiles a missing source: ${path ?? buildID}`); }
                const local = relative(root, path).split(sep).join("/");
                if (local === ".." || local.startsWith("../") || /^Packages\/WalletRuntime\/Sources\/|^Packages\/Wallet(?:Runtime|Upgrade)Harness\/|^Scripts\/wallet_upgrade\/|(?:^|\/)Tests\//.test(local) || /big_wallet_.*\.(c|h)$|secp256k1\//.test(local)) {
                    throw new Error(`${target.name} directly compiles private runtime/test source: ${local}`);
                }
                if (nativeExtension && applicationOnlySources.has(local)) {
                    throw new Error(`${target.name} compiles application or native-helper composition: ${local}`);
                }
                validateSource(path, {nativeExtension});
            }
        }
    }
    return true;
}

function filesBelow(root, extension = ".swift") {
    if (!existsSync(root)) { return []; }
    return readdirSync(root, {withFileTypes: true}).flatMap(entry => {
        const path = join(root, entry.name);
        if (["node_modules", ".build", ".git"].includes(entry.name)) { return []; }
        if (entry.isSymbolicLink()) { throw new Error(`Unexpected source symlink: ${path}`); }
        return entry.isDirectory() ? filesBelow(path, extension) : path.endsWith(extension) ? [path] : [];
    });
}

export function checkRuntimeBoundaries(root) {
    const packageRoot = join(root, "Packages/WalletRuntime");
    validateRuntimeManifestSource(readFileSync(join(packageRoot, "Package.swift"), "utf8"));
    validateRuntimePackage(inspectSwiftPackage(root, packageRoot), root);
    for (const [source, fixture] of [
        ["Shared/Ethereum/NetworkCatalog.json", "NetworkCatalog.json"],
        ["Safari Shared/Tests/fixtures/wire_protocol_contract.json", "wire_protocol_contract.json"],
        ["Safari Shared/Tests/fixtures/native_response_contract.json", "native_response_contract.json"],
    ]) {
        if (!readFileSync(join(root, source)).equals(readFileSync(join(packageRoot, "Tests/Support/Fixtures", fixture)))) {
            throw new Error(`Runtime test resource differs from its source: ${fixture}`);
        }
    }
    let count = 0;
    for (const module of productionTargets.filter(name => name !== "CWalletCrypto")) {
        for (const path of filesBelow(join(packageRoot, "Sources", module))) {
            const source = readFileSync(path, "utf8");
            validateRuntimeSource(relative(root, path), source, {module});
            count += 1;
        }
    }
    for (const directory of applicationRoots) {
        for (const path of filesBelow(join(root, directory))) {
            if (relative(root, path).split(sep).includes("Tests")) { continue; }
            validateRuntimeSource(relative(root, path), readFileSync(path, "utf8"), {application: true});
            count += 1;
        }
    }
    validateProjectMembership(readProject(join(root, "Wallet.xcodeproj/project.pbxproj")), {root,
        validateSource: (path, {nativeExtension}) => {
            const source = readFileSync(path, "utf8");
            if (path.endsWith(".swift")) { validateRuntimeSource(relative(root, path), source, {application: true}); }
            else if (/#\s*(?:import|include)[^\n]*(?:CWalletCrypto|big_wallet|secp256k1)/.test(source)) {
                throw new Error(`${path}: Application source imports private crypto headers`);
            }
        },
    });
    return count;
}

export function parseOptions(arguments_) {
    const options = {root: resolve(dirname(fileURLToPath(import.meta.url)), ".."), configuration: "debug", checkAPI: false, apiOnly: false};
    for (let index = 0; index < arguments_.length; index += 1) {
        const flag = arguments_[index];
        if (flag === "--check-api" || flag === "--api-only") {
            options.checkAPI = true;
            if (flag === "--api-only") { options.apiOnly = true; }
            continue;
        }
        const name = {"--root": "root", "--package-path": "packagePath", "--configuration": "configuration", "--modules-path": "modulesPath"}[flag];
        const value = arguments_[++index];
        if (!name || !value || value.startsWith("--")) { throw new Error(`Invalid boundary-check argument ${flag}`); }
        options[name] = value;
    }
    options.configuration = options.configuration.toLowerCase();
    if (!["debug", "release"].includes(options.configuration)) { throw new Error("Boundary checks require Debug or Release configuration"); }
    options.root = resolve(options.root);
    options.packagePath = resolve(options.root, options.packagePath ?? "Packages/WalletRuntime");
    return options;
}

function checkOrdinaryImportAPI(options) {
    const binPath = options.modulesPath ? dirname(resolve(options.modulesPath)) : execFileSync("swift", ["build", "--package-path", options.packagePath,
        "--configuration", options.configuration, "--show-bin-path"], {cwd: options.root, encoding: "utf8"}).trim();
    const modules = options.modulesPath ? resolve(options.modulesPath)
        : [join(binPath, "Modules"), binPath].find(path => libraries.every(library => existsSync(join(path, `${library}.swiftmodule`))));
    if (!modules) { throw new Error(`No complete runtime module output exists in ${binPath}`); }
    for (const library of libraries) {
        if (!existsSync(join(modules, `${library}.swiftmodule`))) { throw new Error(`Build ${library} for ${options.configuration} before checking its public boundary`); }
    }
    const fixtureRoot = realpathSync(join(options.packagePath, "BoundaryChecks"));
    const graph = JSON.parse(execFileSync("swift", ["package", "--package-path", options.packagePath,
        "show-dependencies", "--format", "json"], {cwd: options.root, encoding: "utf8"}));
    const packageIdentity = boundaryPackageIdentity(graph);
    const catalog = JSON.parse(readFileSync(join(fixtureRoot, "fixtures.json"), "utf8"));
    if (!Array.isArray(catalog) || !catalog.length || !catalog.some(value => value.succeeds === true) || !catalog.some(value => value.succeeds === false)) { throw new Error("Invalid API boundary fixture inventory"); }
    for (const fixture of catalog) {
        if (typeof fixture.path !== "string" || !/^(?:Positive|Negative)\/[A-Za-z0-9_]+\.swift$/.test(fixture.path) || typeof fixture.succeeds !== "boolean" ||
            fixture.applicationExtension !== undefined && typeof fixture.applicationExtension !== "boolean" ||
            !fixture.succeeds && (typeof fixture.diagnostic !== "string" || !fixture.diagnostic.length)) { throw new Error("Invalid boundary fixture"); }
        const path = join(fixtureRoot, fixture.path);
        const source = readFileSync(path, "utf8");
        if (/@testable|@_spi/.test(maskNonCode(source))) { throw new Error(`API fixture must use ordinary imports: ${fixture.path}`); }
        for (const [scope, flags] of boundaryConsumerContexts(packageIdentity)) {
            const result = spawnSync("swiftc", ["-typecheck", "-target", `${process.arch === "arm64" ? "arm64" : "x86_64"}-apple-macosx15.0`, "-swift-version", "6", "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
                "-enable-upcoming-feature", "InferIsolatedConformances", ...flags,
                ...boundaryApplicationExtensionFlags(fixture), "-I", modules, path], {cwd: options.root, encoding: "utf8", maxBuffer: 4 * 1024 * 1024});
            if (result.error || result.signal || result.status === null) { throw result.error ?? new Error(`Boundary compiler failed: ${fixture.path}`); }
            const diagnostic = (result.stdout ?? "") + (result.stderr ?? "");
            if (fixture.succeeds ? result.status !== 0 : result.status === 0 || !new RegExp(fixture.diagnostic, "i").test(diagnostic)) {
                throw new Error(`Unexpected ${scope} API boundary result for ${fixture.path}: exit ${result.status}\n${diagnostic}`);
            }
            process.stdout.write(`Runtime ${scope} API boundary ${fixture.succeeds ? "accepted" : "rejected"}: ${fixture.path}\n`);
        }
    }
    return catalog.length;
}

export function boundaryPackageIdentity(graph) {
    if (graph?.name !== "WalletRuntime" || !/^[A-Za-z_][A-Za-z_0-9]*$/.test(graph.identity ?? "") ||
        !Array.isArray(graph.dependencies) || graph.dependencies.length) {
        throw new Error("Resolved runtime package identity is missing or inconsistent");
    }
    return graph.identity;
}

export function boundaryApplicationExtensionFlags(fixture) {
    if (fixture.applicationExtension !== undefined && typeof fixture.applicationExtension !== "boolean") {
        throw new Error("Invalid application-extension fixture context");
    }
    return fixture.applicationExtension === true ? ["-application-extension"] : [];
}

export function boundaryConsumerContexts(packageIdentity) {
    if (!/^[A-Za-z_][A-Za-z_0-9]*$/.test(packageIdentity)) { throw new Error("Invalid compiler package identity"); }
    return [
        ["external", ["-module-name", "WalletExternalBoundaryConsumer"]],
        ["package", ["-module-name", "WalletPackageBoundaryConsumer", "-package-name", packageIdentity]],
    ];
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
    const options = parseOptions(process.argv.slice(2));
    execFileSync("/bin/sh", ["-c", '. "$1"; test_vm_require_guest_session', "runtime-boundary-validation", join(options.root, "Scripts/vm/guest_session.sh")], {cwd: options.root, stdio: "inherit"});
    if (!options.apiOnly) {
        const count = checkRuntimeBoundaries(options.root);
        process.stdout.write(`Runtime source boundaries checked: ${count} Swift files.\n`);
    }
    if (options.checkAPI) { checkOrdinaryImportAPI(options); }
}
