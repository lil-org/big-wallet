import {execFileSync} from "node:child_process";
import {fileURLToPath, pathToFileURL} from "node:url";
import {dirname, isAbsolute, relative, resolve, sep} from "node:path";

const libraries = ["WalletDomain", "WalletAuthority", "WalletNetworking"];
const allowedTargets = new Set([...libraries, "WalletStorageSupport", "CWalletCrypto"]);
const forbiddenSource = /(?:^|\/)(?:AppDelegate|SceneDelegate|SafariWebExtensionHandler|SafariVMFixtures)\.swift$|\.entitlements$|AlchemyJWTRequestProofKey|PrivacyInfo\.xcprivacy/;

function named(values, label) {
    if (!Array.isArray(values) || values.some(value => typeof value?.name !== "string") || new Set(values.map(value => value.name)).size !== values.length) {
        throw new Error(`Invalid ${label} inventory`);
    }
    return new Map(values.map(value => [value.name, value]));
}

function contained(root, path) {
    if (typeof path !== "string") { return false; }
    const value = relative(root, resolve(root, path));
    return value.length > 0 && value !== ".." && !value.startsWith(`..${sep}`) && !isAbsolute(value);
}

function dependencies(target) {
    if (!Array.isArray(target.dependencies)) { throw new Error(`Invalid dependencies for ${target.name}`); }
    return target.dependencies.map(dependency => {
        const keys = Object.keys(dependency ?? {});
        if (keys.length !== 1 || !["byName", "target", "product"].includes(keys[0]) || !Array.isArray(dependency[keys[0]]) || typeof dependency[keys[0]][0] !== "string") {
            throw new Error(`Unsupported dependency for ${target.name}`);
        }
        return {kind: keys[0], name: dependency[keys[0]][0], package: dependency[keys[0]][1]};
    });
}

function sources(target, described, root) {
    if (!described || !contained(root, described.path) || !Array.isArray(described.sources) || !described.sources.length ||
        described.sources.some(path => !contained(resolve(root, described.path), path) || forbiddenSource.test(path))) {
        throw new Error(`Unsafe source inventory for ${target.name}`);
    }
    if (target.resources?.length || described.resources?.length || target.pluginUsages?.length || target.plugins?.length || ["plugin", "binary", "system"].includes(target.type)) {
        throw new Error(`Approval worker dependency ${target.name} may not execute plugins or include resources`);
    }
    if (/entitlements|enable-testing|BW_SAFARI_VM_TESTING/.test(JSON.stringify(target.settings ?? []))) {
        throw new Error(`Approval worker dependency ${target.name} has unsafe production build settings`);
    }
}

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
    const products = named(runtime.manifest.products, "runtime product");
    if (products.size !== libraries.length || libraries.some(name => !products.get(name)?.type?.library || JSON.stringify(products.get(name).targets) !== JSON.stringify([name]))) {
        throw new Error("WalletRuntime must expose only its three production libraries");
    }
    const targets = named(runtime.manifest.targets, "runtime target");
    const descriptions = named(runtime.description.targets, "described runtime target");
    const active = new Set();
    const visited = new Set();
    const visit = name => {
        if (active.has(name)) { throw new Error("Runtime dependency graph contains a cycle"); }
        if (visited.has(name)) { return; }
        if (!allowedTargets.has(name)) { throw new Error(`Production library reaches a test or application target: ${name}`); }
        const target = targets.get(name);
        if (!target || target.type !== "regular") { throw new Error(`Invalid production target: ${name}`); }
        sources(target, descriptions.get(name), root);
        active.add(name);
        for (const dependency of dependencies(target)) {
            if (dependency.kind === "product") { throw new Error(`Runtime target has an external product dependency: ${name}`); }
            visit(dependency.name);
        }
        active.delete(name); visited.add(name);
    };
    libraries.forEach(visit);
    const workerProducts = named(harness.manifest.products, "harness product");
    const product = workerProducts.get("ApprovalCrashWorker");
    if (workerProducts.size !== 1 || !product || !Object.hasOwn(product.type ?? {}, "executable") || JSON.stringify(product.targets) !== JSON.stringify(["ApprovalCrashWorker"])) {
        throw new Error("Harness must expose exactly one ApprovalCrashWorker executable");
    }
    const workers = named(harness.manifest.targets, "harness target");
    const worker = workers.get("ApprovalCrashWorker");
    if (workers.size !== 1 || worker?.type !== "executable") { throw new Error("Harness may not include app, extension, or helper targets"); }
    sources(worker, named(harness.description.targets, "described harness target").get(worker.name), harness.description.path);
    const inputs = dependencies(worker);
    if (inputs.length !== libraries.length || new Set(inputs.map(value => value.name)).size !== libraries.length || inputs.some(value =>
        value.kind !== "product" || value.package?.toLowerCase() !== "walletruntime" || !libraries.includes(value.name))) {
        throw new Error("Approval worker must consume only the three runtime library products");
    }
    return true;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
    if (process.argv.length !== 2) { throw new Error("Approval worker validation takes no command-line arguments"); }
    const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
    execFileSync("/bin/sh", ["-c", '. "$1"; test_vm_require_guest_session', "approval-worker-validation", resolve(root, "Scripts/vm/guest_session.sh")], {cwd: root, stdio: "inherit"});
    const inspect = path => {
        const run = args => JSON.parse(execFileSync("swift", ["package", "--package-path", path, ...args], {cwd: root, encoding: "utf8", maxBuffer: 16 * 1024 * 1024}));
        return {description: run(["describe", "--type", "json"]), manifest: run(["dump-package"])};
    };
    validateApprovalWorkerTarget({harness: inspect(resolve(root, "Packages/WalletRuntimeHarness")), runtime: inspect(resolve(root, "Packages/WalletRuntime"))});
}
