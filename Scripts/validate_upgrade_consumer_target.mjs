import {execFileSync} from "node:child_process";
import {dirname, isAbsolute, relative, resolve, sep} from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";

const products = ["WalletDomain", "WalletAuthority", "WalletFlows", "WalletNetworking"];
const inputs = ["WalletDomain", "WalletAuthority", "WalletFlows"];
const graph = {WalletDomain: [], WalletStorageSupport: [], CWalletCrypto: [],
    WalletAuthority: ["WalletDomain", "WalletStorageSupport", "CWalletCrypto"],
    WalletFlows: ["WalletDomain", "WalletAuthority"]};
const forbidden = /(?:^|\/)(?:AppDelegate|SceneDelegate|SafariWebExtensionHandler|SafariVMFixtures|ProducerDriver|IsolatedStorageAdapters)\.swift$|\.entitlements$|AlchemyJWTRequestProofKey|PrivacyInfo\.xcprivacy|ShippedMain|source\.tar/;

function named(values, label) {
    if (!Array.isArray(values) || values.some(value => typeof value?.name !== "string") || new Set(values.map(value => value.name)).size !== values.length) {
        throw new Error(`Invalid ${label} inventory`);
    }
    return new Map(values.map(value => [value.name, value]));
}

function contained(root, path) {
    if (typeof path !== "string") { return false; }
    const value = relative(root, resolve(root, path));
    return Boolean(value) && value !== ".." && !value.startsWith(`..${sep}`) && !isAbsolute(value);
}

function dependencies(target) {
    if (!Array.isArray(target.dependencies)) { throw new Error(`Invalid dependencies for ${target.name}`); }
    return target.dependencies.map(value => {
        const keys = Object.keys(value ?? {});
        if (keys.length !== 1 || !["byName", "target", "product"].includes(keys[0]) ||
            !Array.isArray(value[keys[0]]) || typeof value[keys[0]][0] !== "string") {
            throw new Error(`Unsupported dependency for ${target.name}`);
        }
        return {kind: keys[0], name: value[keys[0]][0], package: value[keys[0]][1]};
    });
}

function validateSources(target, description, root) {
    if (!description || !contained(root, description.path) || forbidden.test(description.path) || !Array.isArray(description.sources) || !description.sources.length ||
        description.sources.some(path => !contained(resolve(root, description.path), path) || forbidden.test(path)) ||
        target.resources?.length || description.resources?.length || target.pluginUsages?.length || target.plugins?.length ||
        /entitlements|enable-testing|BW_SAFARI_VM_TESTING|ShippedMain|ProducerDriver/.test(JSON.stringify(target.settings ?? []))) {
        throw new Error(`Unsafe upgrade consumer source or build settings: ${target.name}`);
    }
}

export function validateUpgradeConsumerTarget({harness, runtime}) {
    if (harness?.description?.name !== "WalletUpgradeHarness" || runtime?.description?.name !== "WalletRuntime" ||
        !isAbsolute(harness.description.path ?? "") || !isAbsolute(runtime.description.path ?? "")) {
        throw new Error("Upgrade consumer requires the expected local package identities");
    }
    const root = runtime.description.path;
    const packages = harness.description.dependencies;
    if (!Array.isArray(runtime.description.dependencies) || runtime.description.dependencies.length || runtime.manifest?.dependencies?.length ||
        !Array.isArray(packages) || packages.length !== 1 || resolve(packages[0].path ?? "") !== root ||
        packages[0].identity?.toLowerCase() !== "walletruntime" || harness.manifest?.dependencies?.length !== 1) {
        throw new Error("Upgrade consumer may depend only on the local WalletRuntime package");
    }
    const runtimeProducts = named(runtime.manifest.products, "runtime product");
    if (runtimeProducts.size !== products.length || products.some(name => !runtimeProducts.get(name)?.type?.library ||
        JSON.stringify(runtimeProducts.get(name).targets) !== JSON.stringify([name]))) {
        throw new Error("Unexpected runtime product inventory");
    }
    const targets = named(runtime.manifest.targets, "runtime target");
    const descriptions = named(runtime.description.targets, "described runtime target");
    for (const [name, expected] of Object.entries(graph)) {
        const target = targets.get(name);
        if (target?.type !== "regular") { throw new Error(`Missing ordinary runtime dependency: ${name}`); }
        validateSources(target, descriptions.get(name), root);
        const actual = dependencies(target);
        if (actual.some(value => value.kind === "product") || actual.length !== expected.length ||
            new Set(actual.map(value => value.name)).size !== expected.length || expected.some(value => !actual.some(item => item.name === value))) {
            throw new Error(`Upgrade consumer reaches an unexpected runtime dependency: ${name}`);
        }
    }
    const consumerProducts = named(harness.manifest.products, "consumer product");
    const product = consumerProducts.get("WalletUpgradeConsumer");
    const consumers = named(harness.manifest.targets, "consumer target");
    const consumer = consumers.get("WalletUpgradeConsumer");
    if (consumerProducts.size !== 1 || !product || !Object.hasOwn(product.type ?? {}, "executable") ||
        JSON.stringify(product.targets) !== JSON.stringify(["WalletUpgradeConsumer"]) || consumers.size !== 1 || consumer?.type !== "executable") {
        throw new Error("Upgrade harness must contain exactly one WalletUpgradeConsumer executable");
    }
    validateSources(consumer, named(harness.description.targets, "described consumer target").get(consumer.name), harness.description.path);
    const actual = dependencies(consumer);
    if (actual.length !== inputs.length || new Set(actual.map(value => value.name)).size !== inputs.length || actual.some(value =>
        value.kind !== "product" || value.package?.toLowerCase() !== "walletruntime" || !inputs.includes(value.name))) {
        throw new Error("Upgrade consumer must use only WalletDomain, WalletAuthority and WalletFlows");
    }
    return true;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
    if (process.argv.length !== 2) { throw new Error("Upgrade consumer validation takes no arguments"); }
    const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
    execFileSync("/bin/sh", ["-c", '. "$1"; test_vm_require_guest_session', "upgrade-consumer-validation", resolve(root, "Scripts/vm/guest_session.sh")], {cwd: root, stdio: "inherit"});
    const inspect = path => {
        const run = args => JSON.parse(execFileSync("swift", ["package", "--package-path", path, ...args], {cwd: root, encoding: "utf8", maxBuffer: 16 * 1024 * 1024}));
        return {description: run(["describe", "--type", "json"]), manifest: run(["dump-package"])};
    };
    validateUpgradeConsumerTarget({harness: inspect(resolve(root, "Packages/WalletUpgradeHarness")), runtime: inspect(resolve(root, "Packages/WalletRuntime"))});
}
