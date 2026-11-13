import {resolve} from "node:path";
import {containedPath, dependencyRecords, namedInventory} from "./harness_package.mjs";

export const runtimeLibraries = Object.freeze(["WalletDomain", "WalletAuthority", "WalletFlows", "WalletNetworking"]);
export const runtimeDependencies = Object.freeze(Object.fromEntries(Object.entries({
    WalletDomain: [], WalletStorageSupport: [], CWalletCrypto: [],
    WalletAuthority: ["CWalletCrypto", "WalletDomain", "WalletStorageSupport"],
    WalletFlows: ["WalletAuthority", "WalletDomain"],
    WalletNetworking: ["WalletDomain", "WalletStorageSupport"],
}).map(([name, dependencies]) => [name, Object.freeze(dependencies)])));
export const runtimeTargets = Object.freeze(Object.keys(runtimeDependencies));

const forbiddenSource = /(?:^|\/)(?:AppDelegate|SceneDelegate|SafariWebExtensionHandler|SafariVMFixtures)\.swift$|\.entitlements$|AlchemyJWTRequestProofKey|PrivacyInfo\.xcprivacy/;
const forbiddenSettings = /entitlements|enable-testing|-package-name|BW_SAFARI_VM_TESTING|WalletRuntimeHarness|WalletUpgradeHarness|ShippedWalletProducer|WalletRuntimeTestSupport/;

export function validateRuntimeProducts(inventory) {
    const products = namedInventory(inventory, "runtime product");
    if (products.size !== runtimeLibraries.length || runtimeLibraries.some(name => {
        const product = products.get(name);
        return !product?.type?.library || JSON.stringify(product.targets) !== JSON.stringify([name]);
    })) { throw new Error("Unexpected runtime product inventory: expected exactly four production libraries"); }
}

export function validateRuntimeTarget(target, name) {
    if (target?.type !== "regular") { throw new Error(`Missing ordinary runtime dependency: ${name}`); }
    const expected = runtimeDependencies[name];
    const actual = dependencyRecords(target);
    if (!expected || actual.some(value => value.kind === "product") ||
        target.dependencies.some(value => Object.values(value)[0].slice(1).some(condition => condition != null)) ||
        JSON.stringify(actual.map(value => value.name).sort()) !== JSON.stringify(expected)) {
        throw new Error(`Forbidden or unexpected runtime dependency: ${name}`);
    }
    return expected;
}

export function validateTargetSources(target, described, root, {
    allowResources = false, extraForbiddenSource, extraForbiddenSettings,
} = {}) {
    const forbiddenPath = path => forbiddenSource.test(path) || extraForbiddenSource?.test(path);
    const settings = JSON.stringify(target.settings ?? []);
    if (!described || !containedPath(root, described.path) || forbiddenPath(described.path) ||
        !Array.isArray(described.sources) || !described.sources.length ||
        new Set(described.sources).size !== described.sources.length ||
        described.sources.some(path => !containedPath(resolve(root, described.path), path) || forbiddenPath(path)) ||
        !allowResources && (target.resources?.length || described.resources?.length) ||
        target.pluginUsages?.length || target.plugins?.length || ["plugin", "binary", "system"].includes(target.type) ||
        target.packageAccess === false || forbiddenSettings.test(settings) || extraForbiddenSettings?.test(settings)) {
        throw new Error(`Unsafe target sources or build settings: ${target.name}`);
    }
}

export function validateRuntimeClosure(runtime, roots = runtimeLibraries, sourceOptions) {
    validateRuntimeProducts(runtime.manifest.products);
    const targets = namedInventory(runtime.manifest.targets, "runtime target");
    const descriptions = namedInventory(runtime.description.targets, "described runtime target");
    const visited = new Set();
    const visit = name => {
        if (visited.has(name)) { return; }
        const target = targets.get(name);
        const dependencies = validateRuntimeTarget(target, name);
        validateTargetSources(target, descriptions.get(name), runtime.description.path, sourceOptions);
        visited.add(name);
        dependencies.forEach(visit);
    };
    roots.forEach(visit);
}
