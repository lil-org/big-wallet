import {execFileSync} from "node:child_process";
import {dirname, isAbsolute, resolve} from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";
import {dependencyRecords, inspectSwiftPackage, namedInventory} from "./harness_package.mjs";
import {validateRuntimeClosure, validateTargetSources} from "./runtime_policy.mjs";

const inputs = ["WalletDomain", "WalletAuthority", "WalletFlows"];
const sourcePolicy = {
    extraForbiddenSource: /(?:^|\/)(?:ProducerDriver|IsolatedStorageAdapters)\.swift$|ShippedMain|source\.tar/,
    extraForbiddenSettings: /ShippedMain|ProducerDriver/,
};

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
    validateRuntimeClosure(runtime, inputs, sourcePolicy);
    const consumerProducts = namedInventory(harness.manifest.products, "consumer product");
    const product = consumerProducts.get("WalletUpgradeConsumer");
    const consumers = namedInventory(harness.manifest.targets, "consumer target");
    const consumer = consumers.get("WalletUpgradeConsumer");
    if (consumerProducts.size !== 1 || !product || !Object.hasOwn(product.type ?? {}, "executable") ||
        JSON.stringify(product.targets) !== JSON.stringify(["WalletUpgradeConsumer"]) || consumers.size !== 1 || consumer?.type !== "executable") {
        throw new Error("Upgrade harness must contain exactly one WalletUpgradeConsumer executable");
    }
    validateTargetSources(consumer, namedInventory(harness.description.targets, "described consumer target").get(consumer.name), harness.description.path, sourcePolicy);
    const actual = dependencyRecords(consumer);
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

    validateUpgradeConsumerTarget({harness: inspectSwiftPackage(root, resolve(root, "Packages/WalletUpgradeHarness")), runtime: inspectSwiftPackage(root, resolve(root, "Packages/WalletRuntime"))});
}
