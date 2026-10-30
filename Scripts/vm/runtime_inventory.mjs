import {existsSync, readFileSync, readdirSync, writeFileSync} from "node:fs";
import {dirname, join, resolve} from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";

export const RUNTIME_TEST_TARGETS = ["WalletDomainTests", "WalletAuthorityTests", "WalletFlowsTests", "WalletNetworkingTests"];
const PLATFORMS = ["macos", "ios", "visionos"];
const CONFIGURATIONS = ["Debug", "Release"];
const APP_TEST_TARGETS = {macos: "Tests macOS", ios: "Tests iOS", visionos: "Tests visionOS"};
export const APP_TEST_CLASS_PLATFORMS = {
    NativeApprovalCoordinatorTests: ["macos"],
    TransactionApprovalCoordinatorTests: PLATFORMS,
    PasswordStorageTests: PLATFORMS,
    SecretHandlingTests: ["macos"],
    MacSecretLifetimeTests: ["macos"],
    NativeSecretAlertPresentationTests: ["macos"],
};
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

function blank(text) { return text.replace(/[^\n]/g, " "); }

export function swiftCode(source) {
    let result = "";
    for (let index = 0; index < source.length;) {
        if (source.startsWith("//", index)) {
            const end = source.indexOf("\n", index);
            const stop = end < 0 ? source.length : end;
            result += blank(source.slice(index, stop)); index = stop; continue;
        }
        if (source.startsWith("/*", index)) {
            let stop = index + 2;
            let depth = 1;
            while (stop < source.length && depth) {
                if (source.startsWith("/*", stop)) { depth++; stop += 2; }
                else if (source.startsWith("*/", stop)) { depth--; stop += 2; }
                else { stop++; }
            }
            if (depth) { throw new Error("Unclosed Swift comment"); }
            result += blank(source.slice(index, stop)); index = stop; continue;
        }
        const prefix = /^(#+)?("""|")/.exec(source.slice(index));
        if (prefix) {
            const hashes = prefix[1] ?? "";
            const delimiter = prefix[2] + hashes;
            let stop = index + prefix[0].length;
            while (stop < source.length && !source.startsWith(delimiter, stop)) {
                if (source.startsWith(`\\${hashes}`, stop)) { stop += hashes.length + 2; }
                else { stop++; }
            }
            if (stop >= source.length) { throw new Error("Unclosed Swift string"); }
            stop += delimiter.length;
            result += blank(source.slice(index, stop)); index = stop; continue;
        }
        result += source[index++];
    }
    return result;
}

function condition(expression, platform, configuration, swiftPackage) {
    const os = {macos: "macOS", ios: "iOS", visionos: "visionOS"}[platform];
    const modules = new Set(["Foundation", "CryptoKit", "CommonCrypto", "Security", "Synchronization", "XCTest",
        "SwiftUI", "Combine", "OSLog", "LocalAuthentication", "Darwin", "Dispatch",
        "WalletDomain", "WalletAuthority", "WalletFlows", "WalletNetworking", "WalletStorageSupport", "WalletRuntimeTestSupport"]);
    if (platform === "macos") { modules.add("AppKit"); }
    else { modules.add("UIKit"); }
    if (!swiftPackage) { modules.add("Big_Wallet"); }
    const normalized = expression
        .replace(/os\(\s*(\w+)\s*\)/g, (_, value) => String(value === os))
        .replace(/canImport\(\s*(\w+)\s*\)/g, (_, value) => String(modules.has(value)))
        .replace(/targetEnvironment\(\s*(\w+)\s*\)/g, (_, value) => String(value === "simulator" && platform !== "macos"))
        .replace(/\bSWIFT_PACKAGE\b/g, String(swiftPackage))
        .replace(/\bDEBUG\b/g, String(configuration === "Debug"))
        .replace(/\b[A-Za-z_]\w*\b/g, value => ["true", "false"].includes(value) ? value : "false");
    const tokens = normalized.match(/true|false|&&|\|\||[!()]/g) ?? [];
    if (tokens.join("") !== normalized.replace(/\s/g, "")) { throw new Error(`Unsupported Swift condition: ${expression}`); }
    let index = 0;
    const primary = () => {
        const token = tokens[index++];
        if (token === "!") { return !primary(); }
        if (token === "(") {
            const value = disjunction();
            if (tokens[index++] !== ")") { throw new Error(`Invalid Swift condition: ${expression}`); }
            return value;
        }
        if (!["true", "false"].includes(token)) { throw new Error(`Invalid Swift condition: ${expression}`); }
        return token === "true";
    };
    const conjunction = () => {
        let value = primary();
        while (tokens[index] === "&&") { index++; const next = primary(); value = value && next; }
        return value;
    };
    const disjunction = () => {
        let value = conjunction();
        while (tokens[index] === "||") { index++; const next = conjunction(); value = value || next; }
        return value;
    };
    const value = disjunction();
    if (index !== tokens.length) { throw new Error(`Invalid Swift condition: ${expression}`); }
    return value;
}

function activeCode(source, platform, configuration, swiftPackage = true) {
    const stack = [];
    let active = true;
    const code = swiftCode(source).split("\n").map(line => {
        const directive = /^\s*#(if|elseif|else|endif)\b(.*)$/.exec(line);
        if (!directive) { return active ? line : blank(line); }
        const [, kind, expression] = directive;
        if (kind === "if") {
            const branch = condition(expression.trim(), platform, configuration, swiftPackage);
            stack.push({parent: active, matched: branch}); active = active && branch;
        } else {
            const current = stack.at(-1);
            if (!current) { throw new Error("Unmatched Swift conditional directive"); }
            if (kind === "endif") { active = stack.pop().parent; }
            else {
                const branch = kind === "else" || condition(expression.trim(), platform, configuration, swiftPackage);
                active = current.parent && !current.matched && branch;
                current.matched ||= branch;
            }
        }
        return blank(line);
    }).join("\n");
    if (stack.length) { throw new Error("Unclosed Swift conditional directive"); }
    return code;
}

function testClassDeclarations(code) {
    return [...code.matchAll(/\bclass\s+(\w+)\s*:\s*[^{}]*\bXCTestCase\b[^{}]*\{/g)]
        .map(match => ({name: match[1], start: match.index + match[0].length}));
}

function testsInCode(code, knownTestCases = []) {
    const types = testClassDeclarations(code);
    const names = new Set([...knownTestCases, ...types.map(type => type.name)]);
    for (const match of code.matchAll(/\bextension\s+(\w+)(?=\s*(?:\{|:|where\b))[^{}]*\{/g)) {
        if (names.has(match[1])) { types.push({name: match[1], start: match.index + match[0].length}); }
    }
    const tests = [];
    for (const type of types) {
        let depth = 1;
        for (let index = type.start; index < code.length && depth; index++) {
            if (code[index] === "{") { depth++; }
            else if (code[index] === "}") { depth--; }
            else if (depth === 1) {
                const method = /^func\s+(test\w+)\s*\(\s*\)/.exec(code.slice(index));
                if (method) { tests.push(`${type.name}/${method[1]}`); index += method[0].length - 1; }
            }
        }
        if (depth) { throw new Error(`Unclosed XCTest class: ${type.name}`); }
    }
    return tests;
}

export function declaredTests(source, platform, configuration, {swiftPackage = true} = {}) {
    return testsInCode(activeCode(source, platform, configuration, swiftPackage));
}

export function generateRuntimeInventory(root = ROOT) {
    const tests = new Map();
    const sourcesIn = directory => readdirSync(directory, {withFileTypes: true}).flatMap(entry => {
        const path = join(directory, entry.name);
        if (entry.isDirectory()) { return sourcesIn(path); }
        if (entry.name.endsWith(".swift") && !entry.isFile()) { throw new Error(`Swift test source must be a regular file: ${path}`); }
        return entry.isFile() && entry.name.endsWith(".swift") ? [readFileSync(path, "utf8")] : [];
    });
    for (const target of RUNTIME_TEST_TARGETS) {
        const directory = join(root, "Packages/WalletRuntime/Tests", target);
        const sources = sourcesIn(directory);
        const module = target.slice(0, -5);
        for (const platform of PLATFORMS) {
            for (const configuration of CONFIGURATIONS) {
                const code = sources.map(source => activeCode(source, platform, configuration));
                if (!code.some(source => new RegExp(`@testable\\s+import\\s+${module}\\b`).test(source))) {
                    throw new Error(`Runtime test target must compile a testable import: ${module}/${platform}/${configuration}`);
                }
                const knownTestCases = new Set(code.flatMap(source => testClassDeclarations(source).map(type => type.name)));
                const seen = new Set();
                for (const source of code) {
                    for (const name of testsInCode(source, knownTestCases)) {
                        const id = `${target}/${name}`;
                        if (seen.has(id)) { throw new Error(`Duplicate runtime test: ${id}`); }
                        seen.add(id);
                        const entry = tests.get(id) ?? {id, variants: []};
                        entry.variants.push(`${platform}.${configuration.toLowerCase()}`);
                        tests.set(id, entry);
                    }
                }
                if (!seen.size) { throw new Error(`Runtime test target has no tests: ${target}/${platform}/${configuration}`); }
            }
        }
    }
    const appTests = new Map();
    for (const [name, platforms] of Object.entries(APP_TEST_CLASS_PLATFORMS)) {
        const file = join(root, "Tests", `${name}.swift`);
        if (!existsSync(file)) { continue; }
        const source = readFileSync(file, "utf8");
        for (const platform of platforms) {
            for (const configuration of CONFIGURATIONS) {
                const target = APP_TEST_TARGETS[platform];
                for (const test of declaredTests(source, platform, configuration, {swiftPackage: false}).filter(test => test.startsWith(`${name}/`))) {
                    const id = `${target}/${test}`;
                    const entry = appTests.get(id) ?? {id, variants: []};
                    entry.variants.push(`${platform}.${configuration.toLowerCase()}`); appTests.set(id, entry);
                }
            }
        }
    }
    const sorted = values => [...values].sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
    return {version: 1, tests: sorted(tests.values()), appTests: sorted(appTests.values())};
}

export function validateRuntimeInventory(value) {
    if (!value || value.version !== 1 || !Array.isArray(value.tests) || !value.tests.length || value.tests.length > 20_000 ||
        !Array.isArray(value.appTests) || value.appTests.length > 10_000) { throw new Error("Invalid runtime test inventory"); }
    const seen = new Set();
    for (const entry of value.tests) {
        if (!entry || !new RegExp(`^(?:${RUNTIME_TEST_TARGETS.join("|")})/[A-Za-z_]\\w*/test[A-Za-z0-9_]+$`).test(entry.id) || seen.has(entry.id) ||
            !Array.isArray(entry.variants) || !entry.variants.length || new Set(entry.variants).size !== entry.variants.length ||
            entry.variants.some(variant => !/^(?:macos|ios|visionos)\.(?:debug|release)$/.test(variant))) { throw new Error("Invalid runtime test entry"); }
        seen.add(entry.id);
    }
    for (const target of RUNTIME_TEST_TARGETS) {
        for (const platform of PLATFORMS) {
            for (const configuration of CONFIGURATIONS) {
                if (!value.tests.some(entry => entry.id.startsWith(`${target}/`) && entry.variants.includes(`${platform}.${configuration.toLowerCase()}`))) {
                    throw new Error(`Runtime test inventory omits ${target}/${platform}/${configuration}`);
                }
            }
        }
    }
    for (const entry of value.appTests) {
        const match = /^(Tests (?:macOS|iOS|visionOS))\/([A-Za-z_]\w*)\/test[A-Za-z0-9_]+$/.exec(entry?.id ?? "");
        const platform = match && Object.keys(APP_TEST_TARGETS).find(platform => APP_TEST_TARGETS[platform] === match[1]);
        if (!match || !Object.hasOwn(APP_TEST_CLASS_PLATFORMS, match[2]) || !APP_TEST_CLASS_PLATFORMS[match[2]].includes(platform) || seen.has(entry.id) ||
            !Array.isArray(entry.variants) || !entry.variants.length || new Set(entry.variants).size !== entry.variants.length ||
            entry.variants.some(variant => !CONFIGURATIONS.some(configuration => variant === `${platform}.${configuration.toLowerCase()}`))) { throw new Error("Invalid app test entry"); }
        seen.add(entry.id);
    }
    return value;
}

export function loadRuntimeInventory(path = join(ROOT, "Scripts/vm/runtime-test-inventory.json")) {
    return validateRuntimeInventory(JSON.parse(readFileSync(path, "utf8")));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
    const mode = process.argv[2] ?? "--check";
    if (!["--check", "--write", "--print"].includes(mode) || process.argv.length > 3) { throw new Error("Expected --check, --write, or --print"); }
    const inventory = generateRuntimeInventory();
    const text = JSON.stringify(inventory, null, 2) + "\n";
    if (mode === "--print") { process.stdout.write(text); }
    else if (mode === "--write") { writeFileSync(join(ROOT, "Scripts/vm/runtime-test-inventory.json"), text); }
    else if (JSON.stringify(loadRuntimeInventory()) !== JSON.stringify(inventory)) { throw new Error("Runtime XCTest inventory is stale; run node Scripts/vm/runtime_inventory.mjs --write"); }
}
