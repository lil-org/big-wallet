import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {fileURLToPath} from "node:url";
import {join} from "node:path";
import test from "node:test";
import {parseProject} from "../../check_runtime_boundaries.mjs";
import {validateAppTestMembership, validatePackageTestMembership} from "../test_membership.mjs";
import {RUNTIME_TEST_TARGETS} from "../test_policy.mjs";

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
    const root = fileURLToPath(new URL("../../../", import.meta.url));
    const source = readFileSync(new URL("../../../Wallet.xcodeproj/project.pbxproj", import.meta.url), "utf8");
    const project = parseProject(source);
    assert.doesNotThrow(() => validateAppTestMembership(project, root));
    const target = Object.values(project.objects).find(value => value.isa === "PBXNativeTarget" && value.name === "Tests macOS");
    const phase = target.buildPhases.map(id => project.objects[id]).find(value => value.isa === "PBXSourcesBuildPhase");
    phase.files = [];
    assert.throws(() => validateAppTestMembership(project, root), /must compile the critical suite/);
});
