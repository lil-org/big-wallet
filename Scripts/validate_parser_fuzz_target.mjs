import {execFileSync} from "node:child_process";
import {lstatSync, readFileSync, realpathSync} from "node:fs";
import {dirname, isAbsolute, relative, resolve, sep} from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";

const graph = {WalletDomain: [], WalletStorageSupport: [], CWalletCrypto: [], WalletAuthority: ["WalletDomain", "WalletStorageSupport", "CWalletCrypto"]};
const harnessSources = {WalletParserFuzzWorker: ["Worker.swift"], ParserFuzzCanaries: ["Canaries.c"]};
const forbidden = /(?:^|\/)(?:AppDelegate|SceneDelegate|SafariWebExtensionHandler|SafariVMFixtures)\.swift$|\.entitlements$|AlchemyJWTRequestProofKey|PrivacyInfo\.xcprivacy|ShippedMain/;

function named(values) {
    if (!Array.isArray(values) || values.some(value => typeof value?.name !== "string") || new Set(values.map(value => value.name)).size !== values.length) {
        throw new Error("Invalid target or product inventory");
    }
    return new Map(values.map(value => [value.name, value]));
}

function contained(root, path) {
    if (typeof path !== "string") { return false; }
    const value = relative(root, resolve(root, path));
    return Boolean(value) && value !== ".." && !value.startsWith(`..${sep}`) && !isAbsolute(value);
}

function dependencies(target) {
    return (target.dependencies ?? []).map(value => {
        const keys = Object.keys(value ?? {});
        if (keys.length !== 1 || !["product", "byName", "target"].includes(keys[0]) || !Array.isArray(value[keys[0]]) || typeof value[keys[0]][0] !== "string") {
            throw new Error(`Invalid dependency in ${target.name}`);
        }
        return {kind: keys[0], name: value[keys[0]][0], package: value[keys[0]][1]};
    });
}

function checkSourceInventory(target, description, root, expected) {
    if (!description || !contained(root, description.path) || !Array.isArray(description.sources) || !description.sources.length ||
        description.sources.some(path => !contained(resolve(root, description.path), path) || forbidden.test(path)) ||
        target.pluginUsages?.length || target.plugins?.length || /entitlements|BW_SAFARI_VM_TESTING|enable-testing/.test(JSON.stringify(target.settings ?? []))) {
        throw new Error(`Unsafe fuzz dependency sources or settings: ${target.name}`);
    }
    if (expected && JSON.stringify([...description.sources].sort()) !== JSON.stringify([...expected].sort())) {
        throw new Error(`Unexpected harness sources in ${target.name}`);
    }
}

export function validateParserFuzzSource(source) {
    if (/\b(?:SecItem\w*|Keychain|WalletRepository|AuthorityRuntime|WalletCredentials|URLSession|URLRequest|NSApplication|UIApplication|LAContext|Process)\b|@_silgen_name/.test(source) ||
        /\bimport\s+(?:WalletFlows|WalletNetworking|Security|LocalAuthentication|AppKit|UIKit)\b/.test(source)) {
        throw new Error("Parser fuzz worker reaches storage, authentication, networking, or app services");
    }
    const testable = [...source.matchAll(/@testable\s+import\s+(\w+)/g)].map(match => match[1]).sort();
    if (JSON.stringify(testable) !== JSON.stringify(["WalletAuthority", "WalletDomain"])) { throw new Error("Fuzz worker must use the existing testable modules"); }
}

export function validateParserFuzzTarget({harness, runtime}) {
    if (harness?.description?.name !== "WalletParserFuzzHarness" || runtime?.description?.name !== "WalletRuntime" ||
        !isAbsolute(harness.description.path ?? "") || !isAbsolute(runtime.description.path ?? "")) {
        throw new Error("Fuzz worker requires the expected local package identities");
    }
    const packages = harness.description.dependencies;
    if (runtime.description.dependencies?.length || runtime.manifest.dependencies?.length || !Array.isArray(packages) || packages.length !== 1 ||
        resolve(packages[0].path ?? "") !== runtime.description.path || packages[0].identity?.toLowerCase() !== "walletruntime" || harness.manifest.dependencies?.length !== 1) {
        throw new Error("Parser harness may depend only on local WalletRuntime");
    }
    const products = named(runtime.manifest.products);
    const expectedProducts = ["WalletDomain", "WalletAuthority", "WalletFlows", "WalletNetworking"];
    if (products.size !== expectedProducts.length || expectedProducts.some(name => !products.get(name)?.type?.library ||
        JSON.stringify(products.get(name).targets) !== JSON.stringify([name]))) { throw new Error("Runtime public products changed"); }
    const targets = named(runtime.manifest.targets), descriptions = named(runtime.description.targets);
    for (const [name, expected] of Object.entries(graph)) {
        const target = targets.get(name);
        if (target?.type !== "regular" || target.resources?.length) { throw new Error(`Invalid production dependency ${name}`); }
        checkSourceInventory(target, descriptions.get(name), runtime.description.path);
        const actual = dependencies(target);
        if (actual.some(value => value.kind === "product") || actual.length !== expected.length || new Set(actual.map(value => value.name)).size !== expected.length ||
            expected.some(value => !actual.some(item => item.name === value))) { throw new Error(`Forbidden parser dependency edge in ${name}`); }
    }
    const ownProducts = named(harness.manifest.products), product = ownProducts.get("WalletParserFuzzWorker");
    if (ownProducts.size !== 1 || !Object.hasOwn(product?.type ?? {}, "executable") || JSON.stringify(product.targets) !== '["WalletParserFuzzWorker"]') {
        throw new Error("Harness must expose only its parser worker");
    }
    const ownTargets = named(harness.manifest.targets), ownDescriptions = named(harness.description.targets);
    if (ownTargets.size !== 2 || ownTargets.get("WalletParserFuzzWorker")?.type !== "executable" || ownTargets.get("ParserFuzzCanaries")?.type !== "regular") {
        throw new Error("Harness target inventory is not closed");
    }
    for (const [name, sourceList] of Object.entries(harnessSources)) {
        const target = ownTargets.get(name);
        checkSourceInventory(target, ownDescriptions.get(name), harness.description.path, sourceList);
        const resources = target.resources ?? [];
        if (name === "WalletParserFuzzWorker") {
            if (resources.length !== 1 || resources[0].path !== "Resources/fixtures.json" || !Object.hasOwn(resources[0].rule ?? {}, "copy")) {
                throw new Error("Fuzz worker may bundle only the synthetic fixture inventory");
            }
        } else if (resources.length || dependencies(target).length) { throw new Error("Canary target must have no resources or dependencies"); }
    }
    const inputs = dependencies(ownTargets.get("WalletParserFuzzWorker"));
    if (inputs.length !== 3 || new Set(inputs.map(value => value.name)).size !== 3 ||
        inputs.some(value => value.name === "ParserFuzzCanaries" ? !["byName", "target"].includes(value.kind)
            : value.kind !== "product" || value.package?.toLowerCase() !== "walletruntime" || !["WalletDomain", "WalletAuthority"].includes(value.name))) {
        throw new Error("Fuzz worker must consume only Domain, Authority, and its local canaries");
    }
    return true;
}

export function inspectParserFuzzTarget(root) {
    const inspect = path => {
        const run = args => JSON.parse(execFileSync("xcrun", ["swift", "package", "--package-path", path, ...args], {cwd: root, encoding: "utf8", maxBuffer: 16 * 1_024 * 1_024}));
        return {description: run(["describe", "--type", "json"]), manifest: run(["dump-package"])};
    };
    const harness = inspect(resolve(root, "Packages/WalletParserFuzzHarness"));
    const runtime = inspect(resolve(root, "Packages/WalletRuntime"));
    validateParserFuzzTarget({harness, runtime});
    for (const [name, expected] of Object.entries(harnessSources)) {
        const description = harness.description.targets.find(value => value.name === name);
        for (const relativePath of expected) {
            const path = resolve(harness.description.path, description.path, relativePath);
            if (!lstatSync(path).isFile() || lstatSync(path).isSymbolicLink() || !contained(harness.description.path, realpathSync(path))) {
                throw new Error("Harness source escapes its package");
            }
            if (name === "WalletParserFuzzWorker") { validateParserFuzzSource(readFileSync(path, "utf8")); }
        }
    }
    return {harness, runtime};
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
    if (process.argv.length !== 2) { throw new Error("Parser fuzz target validation takes no arguments"); }
    const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
    execFileSync("/bin/sh", ["-c", '. "$1"; test_vm_require_guest_session', "parser-fuzz-validation", resolve(root, "Scripts/vm/guest_session.sh")], {cwd: root, stdio: "inherit"});
    inspectParserFuzzTarget(root);
}
