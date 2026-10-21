import test from "node:test";
import assert from "node:assert/strict";
import {execFile} from "node:child_process";
import {mkdtemp, mkdir, writeFile, readFile, lstat, rm} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {fileURLToPath} from "node:url";
import {promisify} from "node:util";

const execute = promisify(execFile);
const bundler = fileURLToPath(new URL("../bundle_configuration.sh", import.meta.url));
const repository = fileURLToPath(new URL("../../../", import.meta.url));

async function fixture(context) {
    const root = await mkdtemp(join(tmpdir(), "safari-build-guard-"));
    context.after(() => rm(root, {recursive: true, force: true}));
    const resources = "Big Wallet.app/Contents/Resources";
    await mkdir(join(root, resources), {recursive: true});
    const marker = join(root, resources, "SafariVMRun.json");
    await writeFile(marker, "stale-fixture");
    const run = overrides => execute("/bin/sh", [bundler], {env: {
        PATH: "/usr/bin:/bin:/usr/sbin:/sbin", TARGET_BUILD_DIR: root,
        UNLOCALIZED_RESOURCES_FOLDER_PATH: resources, SRCROOT: root,
        ...overrides,
    }});
    return {root, marker, run};
}

test("ordinary builds remove a stale Safari fixture descriptor", async context => {
    const {marker, run} = await fixture(context);
    await run({});
    await assert.rejects(lstat(marker), {code: "ENOENT"});
});

test("ordinary builds restore the pristine popup after a fixture build", async context => {
    const {root, run} = await fixture(context);
    const source = join(repository, "Safari Shared/Resources/popup.js");
    const output = join(root, "Big Wallet.app/Contents/Resources/popup.js");
    await writeFile(output, "stale-popup");
    await execute("/usr/bin/python3", [join(repository, "Scripts/safari/instrument_popup.py"), source, output, "fixture"]);
    assert.match(await readFile(output, "utf8"), /safariVMPopupDiagnostic/);
    await run({SRCROOT: repository});
    assert.equal(await readFile(output, "utf8"), await readFile(source, "utf8"));
});

test("ordinary builds restore pristine content after a fixture build", async context => {
    const {root, run} = await fixture(context);
    const source = join(repository, "Safari Shared/Resources/content.js");
    const output = join(root, "Big Wallet.app/Contents/Resources/content.js");
    await writeFile(output, "stale-content");
    await execute("/usr/bin/python3", [join(repository, "Scripts/safari/instrument_content.py"), source, output, "fixture"]);
    assert.match(await readFile(output, "utf8"), /safariVMContentDiagnostic/);
    await run({SRCROOT: repository});
    assert.equal(await readFile(output, "utf8"), await readFile(source, "utf8"));
});

test("ordinary builds restore the pristine worker after a fixture build", async context => {
    const {root, run} = await fixture(context);
    const source = join(repository, "Safari Shared/Resources/service_worker.js");
    const output = join(root, "Big Wallet.app/Contents/Resources/service_worker.js");
    await writeFile(output, "stale-worker");
    await execute("/usr/bin/python3", [join(repository, "Scripts/safari/instrument_worker.py"), source, output, "fixture"]);
    assert.match(await readFile(output, "utf8"), /safariVMWorkerDiagnostic/);
    await run({SRCROOT: repository});
    assert.equal(await readFile(output, "utf8"), await readFile(source, "utf8"));
});

test("Safari fixture compiler and resource modes must agree", async context => {
    const {marker, run} = await fixture(context);
    for (const mode of [
        {BW_SAFARI_VM_TESTING: "YES"},
        {SWIFT_ACTIVE_COMPILATION_CONDITIONS: "DEBUG BW_SAFARI_VM_TESTING"},
    ]) {
        await assert.rejects(run(mode), error => /compilation and resource modes must agree/.test(error.stderr));
        assert.equal(await readFile(marker, "utf8"), "stale-fixture");
    }
});

test("fixture builds reject distribution actions before accessing guest resources", async context => {
    const {run} = await fixture(context);
    for (const action of [
        {ACTION: "install"},
        {ACTION: "archive"},
        {DEPLOYMENT_LOCATION: "YES"},
        {ARCHIVE_PATH: "/fixture/Wallet.xcarchive"},
    ]) {
        await assert.rejects(run({BW_SAFARI_VM_TESTING: "YES", SWIFT_ACTIVE_COMPILATION_CONDITIONS: "BW_SAFARI_VM_TESTING", ...action}),
            error => /cannot be archived or installed for distribution/.test(error.stderr));
    }
});
