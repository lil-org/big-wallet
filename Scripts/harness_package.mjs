import {execFileSync} from "node:child_process";
import {isAbsolute, relative, resolve, sep} from "node:path";

export function inspectSwiftPackage(root, packagePath) {
    const run = args => JSON.parse(execFileSync("xcrun", ["swift", "package", "--package-path", packagePath, ...args], {
        cwd: root, encoding: "utf8", maxBuffer: 16 * 1_024 * 1_024,
    }));
    return {description: run(["describe", "--type", "json"]), manifest: run(["dump-package"])};
}

export function namedInventory(values, label = "target or product") {
    if (!Array.isArray(values) || values.some(value => typeof value?.name !== "string") || new Set(values.map(value => value.name)).size !== values.length) {
        throw new Error(`Invalid ${label} inventory`);
    }
    return new Map(values.map(value => [value.name, value]));
}

export function containedPath(root, path) {
    if (typeof path !== "string") { return false; }
    const value = relative(root, resolve(root, path));
    return Boolean(value) && value !== ".." && !value.startsWith(`..${sep}`) && !isAbsolute(value);
}

export function dependencyRecords(target) {
    if (!Array.isArray(target.dependencies)) { throw new Error(`Invalid dependencies for ${target.name}`); }
    return target.dependencies.map(value => {
        const keys = Object.keys(value ?? {});
        if (keys.length !== 1 || !["byName", "target", "product"].includes(keys[0]) || !Array.isArray(value[keys[0]]) || typeof value[keys[0]][0] !== "string") {
            throw new Error(`Unsupported dependency for ${target.name}`);
        }
        return {kind: keys[0], name: value[keys[0]][0], package: value[keys[0]][1]};
    });
}
