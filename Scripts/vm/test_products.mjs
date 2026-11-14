import {execFileSync} from "node:child_process";
import {createHash} from "node:crypto";
import {lstat, readdir, realpath} from "node:fs/promises";
import {basename, dirname, isAbsolute, join, resolve} from "node:path";
import {bundleExecutable} from "../security_mutations/products.mjs";

const maximumEntries = 4096;
const maximumBundles = 256;
const safeName = value => typeof value === "string" && value.length > 0 && value.length <= 1024 &&
    value !== "." && value !== ".." && !/[\/\\\u0000-\u001f]/.test(value);
const absolutePath = value => typeof value === "string" && value.length <= 4096 && isAbsolute(value) &&
    resolve(value) === value && !/[\u0000-\u001f]/.test(value);
const inside = (root, path) => path.startsWith(`${root}/`);

export function buildWorkspaceIdentity(buildCommand, cwd) {
    if (!Array.isArray(buildCommand) || buildCommand[0] !== "xcodebuild" || buildCommand[1] !== "build-for-testing" ||
        buildCommand.length > 512 || buildCommand.some(value => typeof value !== "string" || value.includes("\0")) ||
        buildCommand.some(value => value.includes("derivedDataPath")) || !absolutePath(cwd)) {
        throw new Error("Test discovery requires its successful default-DerivedData test build command");
    }
    const containers = buildCommand.flatMap((value, index) => ["-project", "-workspace"].includes(value) ? [{flag: value, path: buildCommand[index + 1]}] : []);
    if (containers.length > 1) { throw new Error("Ambiguous XCTest build container"); }
    if (!containers.length) { return cwd; }
    const {flag, path} = containers[0];
    if (typeof path !== "string" || !path.endsWith(flag === "-project" ? ".xcodeproj" : ".xcworkspace")) {
        throw new Error("Invalid XCTest build container");
    }
    const resolved = resolve(cwd, path);
    if (!absolutePath(resolved) || !inside(cwd, resolved)) { throw new Error("XCTest build container escaped its source directory"); }
    return resolved;
}

function validateDerivedDataLocation({directory, canonicalDirectory}) {
    if (!absolutePath(directory) || !directory.endsWith("/Library/Developer/Xcode/DerivedData") ||
        !absolutePath(canonicalDirectory) || !canonicalDirectory.endsWith("/DerivedData")) {
        throw new Error("Test discovery requires default DerivedData");
    }
}

export async function captureDerivedDataRoots(location, readMetadata) {
    validateDerivedDataLocation(location);
    const directory = location.canonicalDirectory;
    if (await realpath(directory) !== directory) { throw new Error("DerivedData directory may not traverse symlinks"); }
    const names = (await readdir(directory)).sort();
    if (names.length > 256) { throw new Error("Too many default DerivedData entries"); }
    const roots = [];
    for (const name of names) {
        if (!safeName(name)) { throw new Error("Invalid DerivedData directory name"); }
        const path = join(directory, name);
        const root = await lstat(path);
        if (root.isSymbolicLink()) { throw new Error("DerivedData root may not be a symlink"); }
        if (!root.isDirectory()) { continue; }
        const infoPath = join(path, "info.plist");
        let before;
        try { before = await lstat(infoPath); }
        catch (error) { if (error.code === "ENOENT") { continue; } throw error; }
        if (!before.isFile() || before.isSymbolicLink() || before.size > 64 * 1024 || await realpath(infoPath) !== infoPath) {
            throw new Error("Unsafe or oversized DerivedData root metadata");
        }
        const bytes = await readMetadata(infoPath);
        if (!(bytes instanceof Uint8Array) || bytes.length !== before.size || bytes.length > 64 * 1024) {
            throw new Error("Invalid DerivedData root metadata bytes");
        }
        const after = await lstat(infoPath);
        if (before.ino !== after.ino || before.dev !== after.dev || before.size !== after.size ||
            before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs) {
            throw new Error("DerivedData root metadata changed while reading");
        }
        roots.push({name, path, infoPlist: {path: infoPath, bytes: bytes.length,
            sha256: createHash("sha256").update(bytes).digest("hex"), base64: Buffer.from(bytes).toString("base64")}});
    }
    return {directory: location.directory, canonicalDirectory: directory, roots};
}

export function discoveryProductsDirectory(metadata, build) {
    validateDerivedDataLocation(build);
    const workspace = buildWorkspaceIdentity(build.command, build.cwd);
    if (!metadata || metadata.directory !== build.directory || metadata.canonicalDirectory !== build.canonicalDirectory ||
        !Array.isArray(metadata.roots) || metadata.roots.length > 256) { throw new Error("Invalid DerivedData root inventory"); }
    const seen = new Set();
    const matching = [];
    for (const root of metadata.roots) {
        if (!safeName(root?.name) || root.path !== join(build.canonicalDirectory, root.name) || seen.has(root.name) ||
            root.infoPlist?.path !== join(root.path, "info.plist")) { throw new Error("Invalid DerivedData root identity"); }
        seen.add(root.name);
        const info = root.infoPlist;
        if (!Number.isSafeInteger(info.bytes) || info.bytes <= 0 || info.bytes > 64 * 1024 ||
            typeof info.base64 !== "string" || info.base64.length > 88 * 1024 || !/^[a-f0-9]{64}$/.test(info.sha256 ?? "")) {
            throw new Error("Invalid DerivedData root plist evidence");
        }
        const bytes = Buffer.from(info.base64, "base64");
        if (bytes.length !== info.bytes || bytes.toString("base64") !== info.base64 ||
            createHash("sha256").update(bytes).digest("hex") !== info.sha256) { throw new Error("DerivedData root plist identity changed"); }
        const identity = execFileSync("/usr/bin/plutil", ["-extract", "WorkspacePath", "raw", "-expect", "string", "-n", "-o", "-", "-"],
            {input: bytes, encoding: "utf8", maxBuffer: 4096, timeout: 30_000});
        if (!absolutePath(identity)) { throw new Error("Invalid DerivedData workspace identity"); }
        if (identity === workspace) { matching.push(root.path); }
    }
    if (matching.length !== 1) { throw new Error(`Expected exactly one DerivedData root for the build workspace, found ${matching.length}`); }
    return join(matching[0], "Build/Products");
}

function configurationDirectory(products, policy) {
    const suffix = {macos: "", ios: "-iphonesimulator", visionos: "-xrsimulator"}[policy.platform];
    if (suffix === undefined || !["Debug", "Release"].includes(policy.configuration)) { throw new Error("Invalid XCTest product configuration"); }
    return join(products, policy.configuration + suffix);
}

async function productInventory(products, bindings, policy, readDirectory, readBundle) {
    if (!absolutePath(products)) { throw new Error("Invalid XCTest products directory"); }
    const configuration = configurationDirectory(products, policy);
    const binaries = new Map();
    const frameworks = new Set();
    const add = binary => {
        if (!absolutePath(binary.path) || !inside(configuration, binary.path)) { throw new Error("XCTest executable escaped its configuration and platform"); }
        const previous = binaries.get(binary.path);
        if (previous && previous.role !== binary.role) { throw new Error("Conflicting XCTest executable roles"); }
        if (!previous) { binaries.set(binary.path, binary); }
    };
    const directory = async (path, optional = false) => {
        const entries = await readDirectory(path, optional);
        if (entries === null && optional) { return []; }
        if (!Array.isArray(entries) || entries.length > maximumEntries || entries.some(name => !safeName(name)) ||
            new Set(entries).size !== entries.length) { throw new Error(`Missing or malformed XCTest directory inventory: ${path}`); }
        return entries;
    };
    const addFrameworks = async (path, optional) => {
        for (const name of await directory(path, optional)) {
            if (name.endsWith(".framework")) { frameworks.add(join(path, name)); }
        }
    };
    await addFrameworks(configuration, false);
    await addFrameworks(join(configuration, "PackageFrameworks"), true);
    const owners = bindings.flatMap(({target, bundle, host}) => [
        {target, role: "test", bundle}, ...(host ? [{target, role: "host", bundle: host}] : []),
    ]);
    for (const owner of owners) {
        if (!absolutePath(owner.bundle) || !inside(configuration, owner.bundle)) { throw new Error("XCTest bundle escaped its configuration and platform"); }
        const info = await readBundle(owner.bundle, false);
        const path = bundleExecutable(owner.bundle, info, policy.platform === "macos" ? "macos-app" : "ios-app");
        const entries = await directory(dirname(path));
        if (!entries.includes(basename(path))) { throw new Error(`Missing XCTest executable: ${path}`); }
        add({target: owner.target, role: owner.role, path});
        for (const name of entries.filter(name => name.endsWith(".debug.dylib"))) {
            add({target: owner.target, role: owner.role, path: join(dirname(path), name)});
        }
        await addFrameworks(join(owner.bundle, policy.platform === "macos" ? "Contents/Frameworks" : "Frameworks"), true);
    }
    if (frameworks.size > maximumBundles) { throw new Error("Too many XCTest frameworks"); }
    for (const bundle of [...frameworks].sort()) {
        const info = await readBundle(bundle, true);
        const name = info?.CFBundleExecutable;
        if (!safeName(name)) { throw new Error("Invalid XCTest framework executable"); }
        const entries = await directory(bundle);
        if (!entries.includes(name)) { throw new Error(`Missing XCTest framework executable: ${bundle}`); }
        add({role: "framework", path: join(bundle, name)});
    }
    return [...binaries.values()].sort((left, right) => left.path.localeCompare(right.path));
}

export async function recordedProductInventory(products, bindings, policy, metadata) {
    if (!metadata || !Array.isArray(metadata.directories) || metadata.directories.length > maximumEntries ||
        !Array.isArray(metadata.bundles) || metadata.bundles.length > maximumBundles) {
        throw new Error("Missing or malformed XCTest product metadata");
    }
    const directories = new Map();
    const bundles = new Map();
    for (const value of metadata.directories) {
        if (!value || !absolutePath(value.path) || directories.has(value.path)) { throw new Error("Invalid XCTest directory metadata"); }
        directories.set(value.path, value.entries);
    }
    for (const value of metadata.bundles) {
        if (!value || !absolutePath(value.path) || !value.info || typeof value.info !== "object" || Array.isArray(value.info) || bundles.has(value.path)) {
            throw new Error("Invalid XCTest bundle metadata");
        }
        bundles.set(value.path, value.info);
    }
    const usedDirectories = new Set();
    const usedBundles = new Set();
    const result = await productInventory(products, bindings, policy, async path => {
        if (!directories.has(path)) { throw new Error(`Missing XCTest directory metadata: ${path}`); }
        usedDirectories.add(path);
        return directories.get(path);
    }, async path => {
        if (!bundles.has(path)) { throw new Error(`Missing XCTest bundle metadata: ${path}`); }
        usedBundles.add(path);
        return bundles.get(path);
    });
    if (usedDirectories.size !== directories.size || usedBundles.size !== bundles.size) { throw new Error("Unrelated XCTest product metadata"); }
    return result;
}

export async function captureProductInventory(products, bindings, policy, readInfo) {
    const metadata = {directories: [], bundles: []};
    const directories = new Map();
    const bundles = new Map();
    const result = await productInventory(products, bindings, policy, async (path, optional) => {
        if (directories.has(path)) { return directories.get(path); }
        let entries;
        try {
            const before = await lstat(path);
            if (!before.isDirectory() || before.isSymbolicLink() || await realpath(path) !== path) {
                throw new Error("XCTest product directory may not traverse symlinks");
            }
            entries = (await readdir(path)).sort();
            const after = await lstat(path);
            if (before.ino !== after.ino || before.dev !== after.dev || before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs) {
                throw new Error("XCTest product directory changed while reading");
            }
        } catch (error) {
            if (!optional || error.code !== "ENOENT") { throw error; }
            entries = null;
        }
        directories.set(path, entries);
        metadata.directories.push({path, entries});
        return entries;
    }, async (bundle, framework) => {
        if (bundles.has(bundle)) { return bundles.get(bundle); }
        const attributes = await lstat(bundle);
        if (!attributes.isDirectory() || attributes.isSymbolicLink() || await realpath(bundle) !== bundle) {
            throw new Error("XCTest bundle may not traverse symlinks");
        }
        const candidates = framework ? [join(bundle, "Resources/Info.plist"), join(bundle, "Info.plist")]
            : [join(bundle, policy.platform === "macos" ? "Contents/Info.plist" : "Info.plist")];
        let info;
        for (const candidate of candidates) {
            let path;
            try { path = await realpath(candidate); }
            catch (error) { if (error.code === "ENOENT") { continue; } throw error; }
            if (!inside(bundle, path)) { throw new Error("XCTest metadata escaped its bundle"); }
            info = await readInfo(path);
            break;
        }
        if (!info || typeof info !== "object" || Array.isArray(info)) { throw new Error(`Missing XCTest bundle Info.plist: ${bundle}`); }
        bundles.set(bundle, info);
        metadata.bundles.push({path: bundle, info});
        return info;
    });
    if (metadata.directories.length > maximumEntries || metadata.bundles.length > maximumBundles) { throw new Error("Too much XCTest product metadata"); }
    return {products: result, metadata};
}
