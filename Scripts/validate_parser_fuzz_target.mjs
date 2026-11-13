import {execFileSync} from "node:child_process";
import {lstatSync, readFileSync, realpathSync} from "node:fs";
import {dirname, isAbsolute, resolve} from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";
import {containedPath, dependencyRecords, inspectSwiftPackage, namedInventory} from "./harness_package.mjs";
import {validateRuntimeClosure, validateTargetSources} from "./runtime_policy.mjs";

const harnessSources = {WalletParserFuzzWorker: null, ParserFuzzCanaries: ["Canaries.c"]};
const sourcePolicy = {extraForbiddenSource: /ShippedMain/};

function checkSourceInventory(target, description, root, expected) {
    validateTargetSources(target, description, root, {...sourcePolicy, allowResources: true});
    if (expected && JSON.stringify([...description.sources].sort()) !== JSON.stringify([...expected].sort())) {
        throw new Error(`Unexpected harness sources in ${target.name}`);
    }
}

export function validateParserFuzzSources(sources) {
    const testable = new Set();
    for (const source of sources) {
        if (/\b(?:SecItem\w*|Keychain|WalletRepository|AuthorityRuntime|WalletCredentials|URLSession|URLRequest|NSApplication|UIApplication|LAContext|Process)\b|@_silgen_name/.test(source) ||
            /\bimport\s+(?:WalletFlows|WalletNetworking|Security|LocalAuthentication|AppKit|UIKit)\b/.test(source)) {
            throw new Error("Parser fuzz worker reaches storage, authentication, networking, or app services");
        }
        for (const match of source.matchAll(/@testable\s+import\s+(\w+)/g)) { testable.add(match[1]); }
    }
    if (JSON.stringify([...testable].sort()) !== JSON.stringify(["WalletAuthority", "WalletDomain"])) { throw new Error("Fuzz worker must use the existing testable modules"); }
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
    validateRuntimeClosure(runtime, ["WalletDomain", "WalletAuthority"], sourcePolicy);
    const ownProducts = namedInventory(harness.manifest.products), product = ownProducts.get("WalletParserFuzzWorker");
    if (ownProducts.size !== 1 || !Object.hasOwn(product?.type ?? {}, "executable") || JSON.stringify(product.targets) !== '["WalletParserFuzzWorker"]') {
        throw new Error("Harness must expose only its parser worker");
    }
    const ownTargets = namedInventory(harness.manifest.targets), ownDescriptions = namedInventory(harness.description.targets);
    if (ownTargets.size !== 2 || ownTargets.get("WalletParserFuzzWorker")?.type !== "executable" || ownTargets.get("ParserFuzzCanaries")?.type !== "regular") {
        throw new Error("Harness target inventory is not closed");
    }
    for (const [name, sourceList] of Object.entries(harnessSources)) {
        const target = ownTargets.get(name);
        checkSourceInventory(target, ownDescriptions.get(name), harness.description.path, sourceList);
        const resources = target.resources ?? [];
        if (name === "WalletParserFuzzWorker") {
            if (ownDescriptions.get(name).sources.some(path => !path.endsWith(".swift"))) {
                throw new Error("Parser worker must contain only Swift sources");
            }
            if (resources.length !== 1 || resources[0].path !== "Resources/fixtures.json" || !Object.hasOwn(resources[0].rule ?? {}, "copy")) {
                throw new Error("Fuzz worker may bundle only the synthetic fixture inventory");
            }
        } else if (resources.length || dependencyRecords(target).length) { throw new Error("Canary target must have no resources or dependencies"); }
    }
    const inputs = dependencyRecords(ownTargets.get("WalletParserFuzzWorker"));
    if (inputs.length !== 3 || new Set(inputs.map(value => value.name)).size !== 3 ||
        inputs.some(value => value.name === "ParserFuzzCanaries" ? !["byName", "target"].includes(value.kind)
            : value.kind !== "product" || value.package?.toLowerCase() !== "walletruntime" || !["WalletDomain", "WalletAuthority"].includes(value.name))) {
        throw new Error("Fuzz worker must consume only Domain, Authority, and its local canaries");
    }
    return true;
}

export function validateParserFuzzFiles(harness) {
    const sources = [];
    for (const name of Object.keys(harnessSources)) {
        const description = harness.description.targets.find(value => value.name === name);
        for (const relativePath of description.sources) {
            const path = resolve(harness.description.path, description.path, relativePath);
            const status = lstatSync(path);
            if (!status.isFile() || status.isSymbolicLink() || !containedPath(harness.description.path, realpathSync(path))) {
                throw new Error("Harness source escapes its package");
            }
            if (name === "WalletParserFuzzWorker") { sources.push(readFileSync(path, "utf8")); }
        }
    }
    validateParserFuzzSources(sources);
}

export function inspectParserFuzzTarget(root) {
    const harness = inspectSwiftPackage(root, resolve(root, "Packages/WalletParserFuzzHarness"));
    const runtime = inspectSwiftPackage(root, resolve(root, "Packages/WalletRuntime"));
    validateParserFuzzTarget({harness, runtime});
    validateParserFuzzFiles(harness);
    return {harness, runtime};
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
    if (process.argv.length !== 2) { throw new Error("Parser fuzz target validation takes no arguments"); }
    const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
    execFileSync("/bin/sh", ["-c", '. "$1"; test_vm_require_guest_session', "parser-fuzz-validation", resolve(root, "Scripts/vm/guest_session.sh")], {cwd: root, stdio: "inherit"});
    inspectParserFuzzTarget(root);
}
