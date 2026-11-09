import {basename, dirname, isAbsolute, join, resolve, sep} from "node:path";

const inside = (parent, path) => path.startsWith(`${parent}${sep}`);

export function derivedDataLocation(log, derivedDataDirectory, pinned = null) {
    if (!isAbsolute(derivedDataDirectory ?? "") || resolve(derivedDataDirectory) !== derivedDataDirectory ||
        !derivedDataDirectory.endsWith("/Library/Developer/Xcode/DerivedData")) { throw new Error("Mutation builds require the default DerivedData directory"); }
    const roots = new Set();
    for (const line of log.split(/\r?\n/)) {
        const match = /^Build description path: (.+)\/Build\/Intermediates(?:\.noindex)?\/XCBuildData\/[^/]+\.xcbuilddata$/.exec(line);
        if (line.startsWith("Build description path:") && !match) { throw new Error("Unsupported build description path"); }
        if (match) { roots.add(match[1]); }
    }
    if (pinned && (dirname(pinned.root ?? "") !== derivedDataDirectory || resolve(pinned.root) !== pinned.root ||
        pinned.products !== join(pinned.root, "Build/Products"))) { throw new Error("Invalid pinned default DerivedData location"); }
    if (roots.size > 1 || roots.size === 0 && !pinned) { throw new Error("Build log must identify exactly one DerivedData root before it can be pinned"); }
    const root = roots.size ? [...roots][0] : pinned.root;
    if (dirname(root) !== derivedDataDirectory || resolve(root) !== root) { throw new Error("Build description escaped default DerivedData"); }
    if (pinned && root !== pinned.root) { throw new Error("Incremental build changed its pristine baseline DerivedData root"); }
    return {root, products: join(root, "Build/Products"), locationSource: roots.size ? "emitted" : "pinned"};
}

function targets(plan) {
    if (!plan || typeof plan !== "object" || Array.isArray(plan)) { throw new Error("Invalid XCTest run plan"); }
    if (Array.isArray(plan.TestConfigurations)) {
        return plan.TestConfigurations.filter(configuration => configuration.IsEnabled !== false).flatMap(configuration => {
            if (!Array.isArray(configuration.TestTargets)) { throw new Error("Malformed XCTest run configuration"); }
            return configuration.TestTargets;
        });
    }
    return Object.entries(plan).filter(([name, value]) => !name.startsWith("__") && value && typeof value.TestBundlePath === "string")
        .map(([name, value]) => ({BlueprintName: name, ...value}));
}

function expand(value, products, host = null) {
    if (typeof value !== "string" || !value || value.includes("\0")) { throw new Error("Invalid XCTest product path"); }
    const expanded = value.replaceAll("__TESTROOT__", products).replaceAll("__TESTHOST__", host ?? "__TESTHOST__");
    if (/__[A-Z_]+__/.test(expanded) || !isAbsolute(expanded)) { throw new Error("Unsupported XCTest product path token"); }
    return resolve(expanded);
}

export function bindTestPlan(plan, {family, selectors, products, configuration = "Debug", platform = family === "ios-app" ? "ios" : "macos"}) {
    if (!isAbsolute(products) || resolve(products) !== products) { throw new Error("Invalid build products directory"); }
    const expected = [...new Set(selectors.map(selector => selector.split("/")[0]))];
    const available = targets(plan);
    const chosen = [];
    for (const name of expected) {
        const matches = available.filter(target => target.BlueprintName === name || target.ProductModuleName === name ||
            basename(target.TestBundlePath ?? "") === `${name}.xctest`);
        if (!matches.length) { return null; }
        if (matches.length !== 1) { throw new Error(`XCTest plan repeats selected target: ${name}`); }
        const target = matches[0];
        let host = null;
        if ((family !== "runtime" || target.IsAppHostedTestBundle === true) &&
            typeof target.TestHostPath === "string" && target.TestHostPath.includes(".app")) {
            const path = expand(target.TestHostPath, products);
            const match = /^(.+?\.app)(?:\/.*)?$/.exec(path);
            if (match) { host = match[1]; }
        }
        if (family !== "runtime" && !host) { throw new Error(`App witness has no bound test host: ${name}`); }
        const bundle = expand(target.TestBundlePath, products, host);
        const configurationDirectory = join(products, configuration + ({macos: "", ios: "-iphonesimulator", visionos: "-xrsimulator"}[platform] ?? "-unsupported"));
        if (!inside(configurationDirectory, bundle) || host && !inside(configurationDirectory, host)) { return null; }
        if (!bundle.endsWith(".xctest") || !inside(products, bundle) || host && !inside(products, host)) { throw new Error("XCTest product escaped its build root"); }
        chosen.push({target: name, bundle, host});
    }
    return chosen;
}

export function bundleExecutable(bundle, info, family) {
    const name = info?.CFBundleExecutable;
    if (typeof name !== "string" || !name || name === "." || name === ".." || /[\/\\\u0000-\u001f]/.test(name)) {
        throw new Error("Invalid XCTest product executable name");
    }
    return family === "ios-app" ? join(bundle, name) : join(bundle, "Contents/MacOS", name);
}
