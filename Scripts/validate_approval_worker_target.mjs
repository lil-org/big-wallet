import {execFileSync} from "node:child_process";
import {fileURLToPath, pathToFileURL} from "node:url";
import {resolve} from "node:path";

export function validateApprovalWorkerTarget(project) {
    const objects = project.objects;
    const target = Object.values(objects).find(value =>
        value.isa === "PBXNativeTarget" && value.name === "ApprovalCrashWorker");
    if (!target || target.productType !== "com.apple.product-type.tool") {
        throw new Error("ApprovalCrashWorker must be a command-line target");
    }
    if (target.dependencies.length || target.buildRules.length) {
        throw new Error("ApprovalCrashWorker must not build other targets or run custom build rules");
    }
    for (const id of target.buildPhases) {
        if (!["PBXSourcesBuildPhase", "PBXFrameworksBuildPhase"].includes(objects[id]?.isa)) {
            throw new Error("ApprovalCrashWorker must not run scripts or copy application resources");
        }
        for (const entry of objects[id].files) {
            const path = objects[objects[entry]?.fileRef]?.path;
            if (path === "AppDelegate.swift" || path === "SafariWebExtensionHandler.swift") {
                throw new Error("ApprovalCrashWorker must not include a live application or extension entry point");
            }
        }
    }
    const configurations = [target, objects[project.rootObject]].flatMap(value =>
        objects[value.buildConfigurationList].buildConfigurations.map(id => objects[id].buildSettings));
    if (configurations.some(settings => settings.CODE_SIGN_ENTITLEMENTS)) {
        throw new Error("ApprovalCrashWorker must not inherit wallet entitlements");
    }
    return true;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
    const projectPath = fileURLToPath(new URL("../Wallet.xcodeproj/project.pbxproj", import.meta.url));
    const project = JSON.parse(execFileSync("plutil", ["-convert", "json", "-o", "-", projectPath], {encoding: "utf8"}));
    validateApprovalWorkerTarget(project);
}
