import {execFileSync} from "node:child_process";
import {fileURLToPath, pathToFileURL} from "node:url";
import {dependencyRecords, inspectSwiftPackage, namedInventory} from "./harness_package.mjs";
import {runtimeLibraries as libraries, validateRuntimeClosure, validateTargetSources} from "./runtime_policy.mjs";
import {dirname, isAbsolute, resolve} from "node:path";

export function validateApprovalWorkerTarget({harness, runtime}) {
    if (!harness || !runtime || harness.description?.name !== "WalletRuntimeHarness" || runtime.description?.name !== "WalletRuntime" ||
        !isAbsolute(harness.description?.path ?? "") || !isAbsolute(runtime.description?.path ?? "")) {
        throw new Error("Approval worker requires the expected local Swift package identities");
    }
    const root = runtime.description.path;
    const packageDependencies = harness.description.dependencies;
    if (!Array.isArray(runtime.description.dependencies) || runtime.description.dependencies.length || !Array.isArray(packageDependencies) || packageDependencies.length !== 1 ||
        resolve(packageDependencies[0].path ?? "") !== root || packageDependencies[0].identity?.toLowerCase() !== "walletruntime" ||
        runtime.manifest?.dependencies?.length || harness.manifest?.dependencies?.length !== 1) {
        throw new Error("Approval worker may depend only on the local WalletRuntime package");
    }
    validateRuntimeClosure(runtime);
    const workerProducts = namedInventory(harness.manifest.products, "harness product");
    const product = workerProducts.get("ApprovalCrashWorker");
    if (workerProducts.size !== 1 || !product || !Object.hasOwn(product.type ?? {}, "executable") || JSON.stringify(product.targets) !== JSON.stringify(["ApprovalCrashWorker"])) {
        throw new Error("Harness must expose exactly one ApprovalCrashWorker executable");
    }
    const workers = namedInventory(harness.manifest.targets, "harness target");
    const worker = workers.get("ApprovalCrashWorker");
    if (workers.size !== 1 || worker?.type !== "executable") { throw new Error("Harness may not include app, extension, or helper targets"); }
    validateTargetSources(worker, namedInventory(harness.description.targets, "described harness target").get(worker.name), harness.description.path);
    const inputs = dependencyRecords(worker);
    if (inputs.length !== libraries.length || new Set(inputs.map(value => value.name)).size !== libraries.length || inputs.some(value =>
        value.kind !== "product" || value.package?.toLowerCase() !== "walletruntime" || !libraries.includes(value.name))) {
        throw new Error("Approval worker must consume only the four runtime library products");
    }
    return true;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
    if (process.argv.length !== 2) { throw new Error("Approval worker validation takes no command-line arguments"); }
    const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
    execFileSync("/bin/sh", ["-c", '. "$1"; test_vm_require_guest_session', "approval-worker-validation", resolve(root, "Scripts/vm/guest_session.sh")], {cwd: root, stdio: "inherit"});

    validateApprovalWorkerTarget({harness: inspectSwiftPackage(root, resolve(root, "Packages/WalletRuntimeHarness")), runtime: inspectSwiftPackage(root, resolve(root, "Packages/WalletRuntime"))});
}
