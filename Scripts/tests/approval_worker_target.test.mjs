import assert from "node:assert/strict";
import test from "node:test";
import {validateApprovalWorkerTarget} from "../validate_approval_worker_target.mjs";

function project() {
    return {rootObject: "project", objects: {
        project: {buildConfigurationList: "configurations"},
        configurations: {buildConfigurations: ["debug", "release"]},
        debug: {buildSettings: {}}, release: {buildSettings: {}},
        target: {isa: "PBXNativeTarget", name: "ApprovalCrashWorker", productType: "com.apple.product-type.tool",
            dependencies: [], buildRules: [], buildPhases: ["sources"], buildConfigurationList: "configurations"},
        sources: {isa: "PBXSourcesBuildPhase", files: ["buildFile"]},
        buildFile: {fileRef: "file"}, file: {path: "ApprovalCrashWorker.swift"},
    }};
}

test("accepts an isolated command-line target", () => {
    assert.equal(validateApprovalWorkerTarget(project()), true);
});

for (const [name, mutate] of [
    ["app dependency", value => { value.target.dependencies.push("wallet"); }],
    ["resource copying", value => { value.sources.isa = "PBXResourcesBuildPhase"; }],
    ["build scripts", value => { value.sources.isa = "PBXShellScriptBuildPhase"; }],
    ["custom build rules", value => { value.target.buildRules.push("rule"); }],
    ["wallet entry point", value => { value.file.path = "AppDelegate.swift"; }],
    ["extension entry point", value => { value.file.path = "SafariWebExtensionHandler.swift"; }],
    ["inherited entitlements", value => { value.debug.buildSettings.CODE_SIGN_ENTITLEMENTS = "Wallet.entitlements"; }],
    ["application product", value => { value.target.productType = "com.apple.product-type.application"; }],
]) {
    test(`rejects ${name} before building`, () => {
        const value = project();
        mutate(value.objects);
        assert.throws(() => validateApprovalWorkerTarget(value));
    });
}
