import {execFileSync, spawnSync} from "node:child_process";
import {existsSync, readFileSync, readdirSync, realpathSync} from "node:fs";
import {dirname, isAbsolute, join, relative, resolve, sep} from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";

const libraries = ["WalletDomain", "WalletAuthority", "WalletFlows", "WalletNetworking"];
const productionTargets = [...libraries, "WalletStorageSupport", "CWalletCrypto"];
const expectedDependencies = {
    WalletDomain: [], WalletStorageSupport: [], CWalletCrypto: [],
    WalletAuthority: ["CWalletCrypto", "WalletDomain", "WalletStorageSupport"],
    WalletFlows: ["WalletAuthority", "WalletDomain"],
    WalletNetworking: ["WalletDomain", "WalletStorageSupport"],
};
const applicationRoots = ["App iOS", "App macOS", "App visionOS", "Big Wallet Ambient", "Safari Shared", "Safari macOS", "Safari iOS", "Safari visionOS", "Shared"];
const privateTypes = /\b(?:SecretBytes|Keychain|WalletCrypto|WalletPrivateKey|WalletStoredKey|WalletHDWallet|WalletRepository|WalletContainer|WalletSigningSource|WalletSigningPreparation|WalletSigningSession|ApprovedWalletSigningOperation|ApprovedExecutionPermit|BroadcastDispatchPermit|SafariApprovalVault|SafariApprovalVaultHost|SafariApprovalKeychainStore|EthereumSigner|SolanaSigner)\b/;
const networkTypes = /\b(?:URLSession|URLRequest|HTTPURLResponse|AlchemyJWTProvider|EthereumRPC|SafariRPCClient|SafariRPCService|SolanaRPCClient|PriceService|TransactionInspector)\b/;

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

function conditionPossibilities(expression) {
    if (!/\bBW_SAFARI_VM_TESTING\b/.test(expression)) { return 3; }
    const tokens = expression.match(/&&|\|\||!|[()]|[A-Za-z_][A-Za-z_0-9]*|[^\s]/g) ?? [];
    let index = 0;
    const combine = (left, right, operation) => {
        let possibilities = 0;
        for (const a of [false, true]) for (const b of [false, true]) {
            if (left & (a ? 2 : 1) && right & (b ? 2 : 1)) { possibilities |= operation(a, b) ? 2 : 1; }
        }
        return possibilities;
    };
    const primary = () => {
        const token = tokens[index++];
        if (token === "!") { const value = primary(); return (value & 1 ? 2 : 0) | (value & 2 ? 1 : 0); }
        if (token === "(") { const value = or(); if (tokens[index++] !== ")") { throw new Error("Malformed conditional"); } return value; }
        if (!token) { throw new Error("Missing conditional expression"); }
        if (tokens[index] === "(") {
            let depth = 0;
            do { const next = tokens[index++]; if (next === "(") { depth += 1; } if (next === ")") { depth -= 1; } }
            while (index < tokens.length && depth);
            if (depth) { throw new Error("Unclosed conditional call"); }
            return 3;
        }
        return token === "BW_SAFARI_VM_TESTING" || token === "false" ? 1 : token === "true" ? 2 : 3;
    };
    const and = () => { let value = primary(); while (tokens[index] === "&&") { index += 1; value = combine(value, primary(), (a, b) => a && b); } return value; };
    const or = () => { let value = and(); while (tokens[index] === "||") { index += 1; value = combine(value, and(), (a, b) => a || b); } return value; };
    const result = or();
    if (index !== tokens.length) { throw new Error("Unsupported conditional expression"); }
    return result;
}

export function productionSource(source, {application = false} = {}) {
    if (!application) { return source; }
    const directives = maskNonCode(source);
    const originalLines = source.split("\n"), lines = directives.split("\n");
    const stack = [];
    let active = true;
    const result = lines.map((line, index) => {
        const directive = /^\s*#(if|elseif|else|endif)\b(.*)$/.exec(line);
        if (directive) {
            const [, kind, expression] = directive;
            if (kind === "if") {
                const possibilities = conditionPossibilities(expression);
                stack.push({parent: active, remaining: !!(possibilities & 1)});
                active = active && !!(possibilities & 2);
            } else {
                const frame = stack.at(-1);
                if (!frame) { throw new Error("Unbalanced source conditional"); }
                if (kind === "endif") { stack.pop(); active = frame.parent; }
                else if (kind === "else") { active = frame.parent && frame.remaining; frame.remaining = false; }
                else {
                    const possibilities = conditionPossibilities(expression);
                    active = frame.parent && frame.remaining && !!(possibilities & 2);
                    frame.remaining &&= !!(possibilities & 1);
                }
            }
            return "";
        }
        if (index === lines.length - 1 && stack.length) { throw new Error("Unbalanced source conditional"); }
        return active ? originalLines[index] : "";
    });
    if (stack.length) { throw new Error("Unbalanced source conditional"); }
    return result.join("\n");
}

function balanced(source, start, open, close) {
    const code = maskNonCode(source);
    let depth = 0;
    for (let index = start; index < code.length; index += 1) {
        if (code[index] === open) { depth += 1; }
        if (code[index] === close && --depth === 0) { return {body: source.slice(start + 1, index), end: index + 1}; }
    }
    throw new Error(`Unclosed ${open} in package manifest`);
}

function manifestCalls(source, names) {
    const pattern = new RegExp(`\\.(${names.join("|")})\\s*\\(`, "g");
    const code = maskNonCode(source);
    const calls = [];
    for (const match of code.matchAll(pattern)) {
        const start = match.index + match[0].lastIndexOf("(");
        calls.push({kind: match[1], ...balanced(source, start, "(", ")")});
    }
    return calls;
}

export function validateRuntimeManifest(source) {
    const text = maskNonCode(source, {strings: false});
    if (/"-package-name"|\bpackageAccess\s*:\s*false/.test(text)) { throw new Error("Runtime compiler package identity may not be overridden"); }
    if (/BW_SAFARI_VM_TESTING|enable-testing/.test(text)) { throw new Error("Production package contains fixture/test compiler settings"); }
    const productCalls = manifestCalls(text, ["library", "executable"]);
    const products = productCalls.map(call => /\bname\s*:\s*"([^"]+)"/.exec(call.body)?.[1]);
    if (products.length !== libraries.length || products.some(name => !libraries.includes(name)) || new Set(products).size !== libraries.length) {
        throw new Error("Runtime must expose exactly WalletDomain, WalletAuthority, WalletFlows and WalletNetworking");
    }
    for (const product of productCalls) {
        const name = /\bname\s*:\s*"([^"]+)"/.exec(product.body)?.[1];
        if (product.kind !== "library" || !new RegExp(`\\btargets\\s*:\\s*\\[\\s*"${name}"\\s*\\]`).test(product.body)) {
            throw new Error(`Runtime product has unexpected targets: ${name}`);
        }
    }
    if (/\.package\s*\(/.test(maskNonCode(text))) { throw new Error("Runtime production package may not depend on another package"); }
    const calls = manifestCalls(text, ["target", "testTarget", "executableTarget", "binaryTarget", "systemLibrary", "plugin"]);
    const found = new Map;
    for (const call of calls) {
        const name = /\bname\s*:\s*"([^"]+)"/.exec(call.body)?.[1];
        if (!name || found.has(name)) { throw new Error("Duplicate or unnamed runtime target"); }
        found.set(name, call);
    }
    for (const name of productionTargets) {
        const call = found.get(name);
        if (call?.kind !== "target") { throw new Error(`Missing ordinary production target: ${name}`); }
        const match = /\bdependencies\s*:\s*\[/.exec(call.body);
        if (/\bdependencies\s*:/.test(call.body) && !match) { throw new Error(`Dynamic dependencies are not allowed in ${name}`); }
        const dependencies = match ? balanced(call.body, match.index + match[0].lastIndexOf("["), "[", "]").body : "";
        const values = dependencies.split(",").map(value => value.trim()).filter(Boolean);
        if (values.some(value => !/^"[A-Za-z0-9_]+"$/.test(value))) { throw new Error(`Unsupported dependency expression in ${name}`); }
        const names = values.map(value => JSON.parse(value)).sort();
        if (JSON.stringify(names) !== JSON.stringify(expectedDependencies[name])) { throw new Error(`Forbidden runtime dependencies in ${name}: ${names.join(", ")}`); }
        const path = /\bpath\s*:\s*"([^"]+)"/.exec(call.body)?.[1];
        if (/\bpath\s*:/.test(call.body) && !path || path && path !== `Sources/${name}`) { throw new Error(`Production target ${name} has unexpected source membership`); }
        if (/\b(?:resources|plugins)\s*:/.test(maskNonCode(call.body)) || /BW_SAFARI_VM_TESTING|enable-testing|WalletRuntimeHarness|WalletUpgradeHarness|ShippedWalletProducer/.test(call.body)) {
            throw new Error(`Production target ${name} has fixture or test build settings`);
        }
    }
    for (const [name, target] of found) {
        if (!productionTargets.includes(name) && target.kind !== "testTarget" && name !== "WalletRuntimeTestSupport") {
            throw new Error(`Unexpected runtime target: ${name}`);
        }
    }
    return true;
}

export function validateRuntimeSource(path, source, {module, application = false, ownedSymbols = new Set} = {}) {
    const effective = productionSource(source, {application});
    const code = maskNonCode(effective);
    const literalCode = maskNonCode(effective, {strings: false});
    const fail = message => { throw new Error(`${path}: ${message}`); };
    if (/@testable\b/.test(code)) { fail("Production code may not use @testable"); }
    const imports = [...code.matchAll(/\bimport\s+(?:(?:class|struct|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z_][A-Za-z0-9_]*)/g)].map(match => match[1]);
    if (imports.some(name => /(?:TestSupport|Harness|Tests)$|WalletUpgradeConsumer|ShippedWalletProducer/.test(name))) { fail("Production code imports test or harness support"); }
    const foreignSymbols = [...literalCode.matchAll(/@_silgen_name\s*\(\s*"([^"\n]+)"\s*\)/g)].map(match => match[1]);
    if (module !== "WalletAuthority" && (imports.includes("CWalletCrypto") || foreignSymbols.some(symbol => module !== "WalletStorageSupport" || symbol !== "flock"))) { fail("Direct private crypto linkage belongs inside Authority"); }
    if (application && (imports.includes("WalletStorageSupport") || privateTypes.test(literalCode))) { fail("Application code reaches private authority or storage implementation"); }
    if (module === "WalletDomain") {
        if (imports.some(name => !["Foundation", "CoreFoundation", "CryptoKit", "Synchronization"].includes(name)) ||
            /\b(?:URLSession|URLRequest|FileManager|FileHandle|UserDefaults|Bundle|NotificationCenter|DistributedNotificationCenter|SecItem\w*|NSApplication|UIApplication|NSView|UIView)\b|\b(?:Data|String)\s*\(\s*contentsOf|\.write\s*\(\s*to\s*:/.test(literalCode) || privateTypes.test(literalCode)) {
            fail("Domain must contain values and pure operations, without services, I/O or UI");
        }
    }
    if (module === "WalletAuthority" && (imports.includes("WalletNetworking") || imports.includes("WalletFlows") || networkTypes.test(literalCode))) { fail("Authority depends on concrete networking"); }
    if (module === "WalletFlows" && (imports.some(name => ["Security", "LocalAuthentication", "WalletStorageSupport", "WalletNetworking"].includes(name)) ||
        privateTypes.test(literalCode) || /\b(?:ReviewConsent|ApprovedCompletion|PreparedBroadcast|ApprovedExecutionPermit|BroadcastDispatchPermit|SecItem\w*)\b/.test(code))) {
        fail("Flows reaches privileged authority implementation");
    }
    if (module === "WalletAuthority" && /(?:EthereumSigner|SolanaSigner|WalletCoreProxy[^/]*)\.swift$/.test(path) &&
        /\b(?:TransactionPreparing|SignedTransactionBroadcasting|BroadcastRequest|BroadcastResult|FileManager|FileHandle)\b|\b(?:Data|String)\s*\(\s*contentsOf/.test(literalCode)) {
        fail("Signing implementations may not receive networking services or perform I/O");
    }
    if (module === "WalletNetworking") {
        if (imports.includes("WalletAuthority") || imports.includes("WalletFlows") || imports.includes("LocalAuthentication") || privateTypes.test(literalCode)) { fail("Networking reaches wallet or signing authority"); }
        const text = maskNonCode(effective, {strings: false});
        if (/org\.lil\.keychain|SafariApprovalVault|org\.lil\.wallet\.wallet\.|org\.lil\.wallet\.password/.test(text)) { fail("Networking contains wallet Keychain/vault identifiers"); }
        if (/\bkSecAttrAccessGroup\b/.test(code) && !/\b(?:let|var)\s+accessGroup\s*=\s*"[^"\n]+\.rpc-auth"/.test(text)) {
            fail("Networking Security storage must use its separate RPC-auth access group");
        }
    }
    if (module && /\bBW_SAFARI_VM_TESTING\b/.test(code)) { fail("Runtime production source contains application fixture branches"); }
    if (application) {
        for (const declaration of code.matchAll(/^(?:(?:public|internal|private|fileprivate|final|nonisolated)\s+)*(?:class|struct|enum|actor|protocol)\s+(\w+)/gm)) {
            if (ownedSymbols.has(declaration[1])) { fail(`Runtime-owned type is compiled again by the application: ${declaration[1]}`); }
        }
    }
    return true;
}

export function parseProject(source) {
    const text = maskNonCode(source, {strings: false});
    const tokens = text.match(/"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+/g) ?? [];
    let index = 0;
    const take = expected => { const value = tokens[index++]; if (expected && value !== expected) { throw new Error(`Expected ${expected} in project, received ${value}`); } return value; };
    const scalar = () => { const value = take(); if (value === undefined) { throw new Error("Truncated project"); } return value.startsWith('"') ? JSON.parse(value.replace(/\\U([a-fA-F0-9]{4})/g, "\\u$1")) : value; };
    const parse = () => {
        if (tokens[index] === "{") {
            take("{"); const result = {};
            while (tokens[index] !== "}") { const key = scalar(); take("="); if (Object.hasOwn(result, key)) { throw new Error("Duplicate project key"); } result[key] = parse(); take(";"); }
            take("}"); return result;
        }
        if (tokens[index] === "(") {
            take("("); const result = [];
            while (tokens[index] !== ")") { result.push(parse()); if (tokens[index] !== ")") { take(","); } }
            take(")"); return result;
        }
        return scalar();
    };
    const project = parse();
    if (index !== tokens.length) { throw new Error("Unexpected trailing project tokens"); }
    return project;
}

export function validateProjectMembership(project, {root, sourceExists = existsSync, validateSource = () => {}} = {}) {
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
    for (const target of Object.values(objects).filter(value => value.isa === "PBXNativeTarget")) {
        if (/test/i.test(target.productType ?? "") || /Tests/.test(target.name ?? "")) { continue; }
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
            if (/CWalletCrypto|WalletStorageSupport|WalletRuntimeHarness|WalletUpgradeHarness|WalletUpgradeConsumer|ShippedWalletProducer|wallet_upgrade|ShippedMain|WalletRuntimeTestSupport/.test(JSON.stringify(objects[configurationID]?.buildSettings ?? {}))) {
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
                validateSource(path);
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
    validateRuntimeManifest(readFileSync(join(packageRoot, "Package.swift"), "utf8"));
    for (const [source, fixture] of [
        ["Shared/Ethereum/NetworkCatalog.json", "NetworkCatalog.json"],
        ["Safari Shared/Tests/fixtures/wire_protocol_contract.json", "wire_protocol_contract.json"],
        ["Safari Shared/Tests/fixtures/native_response_contract.json", "native_response_contract.json"],
    ]) {
        if (!readFileSync(join(root, source)).equals(readFileSync(join(packageRoot, "Tests/Support/Fixtures", fixture)))) {
            throw new Error(`Runtime test resource differs from its source: ${fixture}`);
        }
    }
    const ownedSymbols = new Set;
    let count = 0;
    for (const module of productionTargets.filter(name => name !== "CWalletCrypto")) {
        for (const path of filesBelow(join(packageRoot, "Sources", module))) {
            const source = readFileSync(path, "utf8");
            validateRuntimeSource(relative(root, path), source, {module});
            for (const declaration of maskNonCode(source).matchAll(/^(?:(?:public|internal|private|fileprivate|final|nonisolated)\s+)*(?:class|struct|enum|actor|protocol)\s+(\w+)/gm)) { ownedSymbols.add(declaration[1]); }
            count += 1;
        }
    }
    for (const directory of applicationRoots) {
        for (const path of filesBelow(join(root, directory))) {
            if (relative(root, path).split(sep).includes("Tests")) { continue; }
            validateRuntimeSource(relative(root, path), readFileSync(path, "utf8"), {application: true, ownedSymbols});
            count += 1;
        }
    }
    validateProjectMembership(parseProject(readFileSync(join(root, "Wallet.xcodeproj/project.pbxproj"), "utf8")), {root,
        validateSource: path => {
            const source = readFileSync(path, "utf8");
            if (path.endsWith(".swift")) { validateRuntimeSource(relative(root, path), source, {application: true, ownedSymbols}); }
            else if (/#\s*(?:import|include)[^\n]*(?:CWalletCrypto|big_wallet|secp256k1)/.test(source)) {
                throw new Error(`${path}: Application source imports private crypto headers`);
            }
        },
    });
    return count;
}

export function parseOptions(arguments_) {
    const options = {root: resolve(dirname(fileURLToPath(import.meta.url)), ".."), configuration: "debug", checkAPI: false};
    for (let index = 0; index < arguments_.length; index += 1) {
        const flag = arguments_[index];
        if (flag === "--check-api") { options.checkAPI = true; continue; }
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

export function checkOrdinaryImportAPI(options) {
    execFileSync("/bin/sh", ["-c", '. "$1"; test_vm_require_guest_session', "runtime-boundary-validation", join(options.root, "Scripts/vm/guest_session.sh")], {cwd: options.root, stdio: "inherit"});
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
            !fixture.succeeds && (typeof fixture.diagnostic !== "string" || !fixture.diagnostic.length)) { throw new Error("Invalid boundary fixture"); }
        const path = join(fixtureRoot, fixture.path);
        const source = readFileSync(path, "utf8");
        if (/@testable|@_spi/.test(maskNonCode(source))) { throw new Error(`API fixture must use ordinary imports: ${fixture.path}`); }
        for (const [scope, flags] of boundaryConsumerContexts(packageIdentity)) {
            const result = spawnSync("swiftc", ["-typecheck", "-target", `${process.arch === "arm64" ? "arm64" : "x86_64"}-apple-macosx15.0`, "-swift-version", "6", "-enable-upcoming-feature", "NonisolatedNonsendingByDefault",
                "-enable-upcoming-feature", "InferIsolatedConformances", ...flags, "-I", modules, path], {cwd: options.root, encoding: "utf8", maxBuffer: 4 * 1024 * 1024});
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

export function boundaryConsumerContexts(packageIdentity) {
    if (!/^[A-Za-z_][A-Za-z_0-9]*$/.test(packageIdentity)) { throw new Error("Invalid compiler package identity"); }
    return [
        ["external", ["-module-name", "WalletExternalBoundaryConsumer"]],
        ["package", ["-module-name", "WalletPackageBoundaryConsumer", "-package-name", packageIdentity]],
    ];
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
    const options = parseOptions(process.argv.slice(2));
    const count = checkRuntimeBoundaries(options.root);
    process.stdout.write(`Runtime source boundaries checked: ${count} Swift files.\n`);
    if (options.checkAPI) { checkOrdinaryImportAPI(options); }
}
