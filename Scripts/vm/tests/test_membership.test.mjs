import assert from "node:assert/strict";
import {mkdtemp, rm, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {fileURLToPath} from "node:url";
import {join} from "node:path";
import test from "node:test";
import {readProject} from "../../check_runtime_boundaries.mjs";
import {validateAppTestMembership, validatePackageTestMembership} from "../test_membership.mjs";
import {APP_TEST_CLASS_PLATFORMS, APP_TEST_TARGETS, RUNTIME_TEST_TARGETS} from "../test_policy.mjs";

const root = "/fixture";
const targets = () => RUNTIME_TEST_TARGETS.map(name => ({name, type: "test", path: `Tests/${name}`,
    sources: ["Tests.swift", "TestabilityContract.swift"]}));
const options = {
    root,
    listSources: directory => ["Tests.swift", "TestabilityContract.swift"].map(name => join(directory, name)),
    readSource: path => `@testable import ${path.split("/").at(-2).slice(0, -5)}\n`,
};

test("evaluated package targets must include all regular test sources and testability contracts", () => {
    assert.doesNotThrow(() => validatePackageTestMembership({targets: targets()}, options));
    for (const change of [
        value => value.pop(),
        value => value.push(value[0]),
        value => { value[0].sources.pop(); },
        value => { value[0].sources.push("../Other/Injected.swift"); },
        value => { value[0].path = "Tests/Redirected"; },
        value => { value[0].type = "library"; },
    ]) {
        const value = targets();
        change(value);
        assert.throws(() => validatePackageTestMembership({targets: value}, options));
    }
    assert.throws(() => validatePackageTestMembership({targets: targets()}, {...options,
        readSource: () => "#if DEBUG\n@testable import WalletDomain\n#endif"}), /unconditional/);
});

test("critical app test source membership is checked independently of test enumeration", () => {
    const suites = Object.keys(APP_TEST_CLASS_PLATFORMS);
    const objects = {
        project: {isa: "PBXProject", mainGroup: "tests"},
        tests: {isa: "PBXGroup", path: "Tests", children: suites},
    };
    for (const suite of suites) {
        objects[suite] = {isa: "PBXFileReference", path: `${suite}.swift`};
        objects[`build-${suite}`] = {isa: "PBXBuildFile", fileRef: suite};
    }
    for (const [platform, name] of Object.entries(APP_TEST_TARGETS)) {
        const phase = `sources-${platform}`;
        objects[platform] = {isa: "PBXNativeTarget", name, buildPhases: [phase]};
        objects[phase] = {isa: "PBXSourcesBuildPhase", files: suites
            .filter(suite => APP_TEST_CLASS_PLATFORMS[suite].includes(platform)).map(suite => `build-${suite}`)};
    }
    const project = {rootObject: "project", objects};
    assert.doesNotThrow(() => validateAppTestMembership(project, root));
    objects["sources-macos"].files = objects["sources-macos"].files.filter(id => id !== "build-WindowAuthenticationSessionTests");
    assert.throws(() => validateAppTestMembership(project, root), /Tests macOS must compile the critical suite WindowAuthenticationSessionTests/);
});

const macOS = {skip: process.platform !== "darwin"};

test("the Xcode project includes every required app test suite", macOS, () => {
    const root = fileURLToPath(new URL("../../../", import.meta.url));
    validateAppTestMembership(readProject(join(root, "Wallet.xcodeproj/project.pbxproj")), root);
});

test("project decoding rejects duplicate keys in the same dictionary", macOS, async t => {
    const directory = await mkdtemp(join(tmpdir(), "pbx-keys-"));
    t.after(() => rm(directory, {recursive: true, force: true}));
    const path = join(directory, "project.pbxproj");
    await writeFile(path, '{ objects = { ID /* A */ = { isa = A; }; "ID" /* B */ = { isa = B; }; }; }');
    assert.throws(() => readProject(path), /Duplicate Xcode project key: ID/);
    await writeFile(path, "rootObject = old; rootObject = current;");
    assert.throws(() => readProject(path), /Duplicate Xcode project key: rootObject/);
    await writeFile(path, String.raw`{ groups = ({ name = a; "na\U006de" = b; }); }`);
    assert.throws(() => readProject(path), /Duplicate Xcode project key: name/);
    await writeFile(path, '{ groups = ({ name = "text; /* { x = y; } */"; }, /* } */ { "name" = b; }); }');
    assert.deepEqual(readProject(path).groups.map(group => group.name), ["text; /* { x = y; } */", "b"]);
});
