import {execFileSync} from "node:child_process";
import {readFileSync, readdirSync} from "node:fs";
import {dirname, join, resolve} from "node:path";
import {fileURLToPath, pathToFileURL} from "node:url";
import {parseProject, projectFilePaths} from "../check_runtime_boundaries.mjs";
import {APP_TEST_CLASS_PLATFORMS, APP_TEST_TARGETS, RUNTIME_TEST_TARGETS} from "./test_policy.mjs";

export function validatePackageTestMembership(description, {root, listSources, readSource}) {
    for (const name of RUNTIME_TEST_TARGETS) {
        const matches = description.targets?.filter(target => target.name === name && target.type === "test") ?? [];
        if (matches.length !== 1) { throw new Error(`Missing or duplicate package test target: ${name}`); }
        const target = matches[0];
        const directory = join(root, "Packages/WalletRuntime/Tests", name);
        if (typeof target.path !== "string" || resolve(root, "Packages/WalletRuntime", target.path) !== directory ||
            !Array.isArray(target.sources) || target.sources.some(path => typeof path !== "string" || !path.endsWith(".swift"))) {
            throw new Error(`Unexpected package test source layout: ${name}`);
        }
        const actual = target.sources.map(path => resolve(directory, path)).sort();
        const expected = listSources(directory).sort();
        if (!actual.length || JSON.stringify(actual) !== JSON.stringify(expected)) {
            throw new Error(`Package test target omits or redirects sources: ${name}`);
        }
        const contract = join(directory, "TestabilityContract.swift");
        if (!actual.includes(contract) || readSource(contract).trim() !== `@testable import ${name.slice(0, -5)}`) {
            throw new Error(`Package test target lacks its unconditional testability import: ${name}`);
        }
    }
}

export function validateAppTestMembership(project, root) {
    const objects = project.objects;
    const paths = projectFilePaths(project, root);
    for (const [platform, name] of Object.entries(APP_TEST_TARGETS)) {
        const matches = Object.values(objects).filter(value => value.isa === "PBXNativeTarget" && value.name === name);
        if (matches.length !== 1) { throw new Error(`Missing or duplicate app test target: ${name}`); }
        const sources = matches[0].buildPhases.flatMap(id => {
            const phase = objects[id];
            return phase?.isa === "PBXSourcesBuildPhase" ? phase.files.map(id => paths.get(objects[id]?.fileRef)) : [];
        });
        for (const [suite, platforms] of Object.entries(APP_TEST_CLASS_PLATFORMS)) {
            if (platforms.includes(platform) && sources.filter(path => path === join(root, "Tests", `${suite}.swift`)).length !== 1) {
                throw new Error(`${name} must compile the critical suite ${suite}`);
            }
        }
    }
}

function sources(directory) {
    return readdirSync(directory, {withFileTypes: true}).flatMap(entry => {
        const path = join(directory, entry.name);
        if (entry.isDirectory()) { return sources(path); }
        if (!entry.isFile()) { throw new Error(`Test sources must be regular files: ${path}`); }
        return entry.name.endsWith(".swift") ? [path] : [];
    });
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
    const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
    const description = JSON.parse(execFileSync("swift", ["package", "--package-path", "Packages/WalletRuntime", "describe", "--type", "json"],
        {cwd: root, encoding: "utf8", maxBuffer: 16 * 1024 * 1024}));
    validatePackageTestMembership(description, {root, listSources: sources, readSource: path => readFileSync(path, "utf8")});
    validateAppTestMembership(parseProject(readFileSync(join(root, "Wallet.xcodeproj/project.pbxproj"), "utf8")), root);
    process.stdout.write("Package and critical app test sources are included in their required targets.\n");
}
