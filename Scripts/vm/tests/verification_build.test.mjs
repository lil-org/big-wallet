import assert from "node:assert/strict";
import {spawnSync} from "node:child_process";
import {existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from "node:fs";
import {tmpdir} from "node:os";
import path from "node:path";
import test from "node:test";

function fixture(operation) {
    const root = mkdtempSync(path.join(tmpdir(), "big-wallet-verification-build-"));
    const scripts = path.join(root, "Scripts");
    const buildDirectory = path.join(root, "Products with spaces");
    const resourceFolder = "Big Wallet.app/Contents/Resources";
    const resource = path.join(buildDirectory, resourceFolder, "AlchemyJWTRequestProofKey");
    const calls = path.join(root, "calls");
    mkdirSync(path.join(scripts, "vm"), {recursive: true});
    mkdirSync(path.dirname(resource), {recursive: true});
    writeFileSync(calls, "");
    for (const name of ["bundle_alchemy_jwt_request_proof_key.sh", "validate_alchemy_jwt_request_proof_key.sh"]) {
        writeFileSync(path.join(scripts, name), readFileSync(new URL(`../../${name}`, import.meta.url)));
    }
    writeFileSync(path.join(scripts, "alchemy_jwt_request_proof_key_common.sh"), `
load_alchemy_jwt_request_proof_key() {
    printf 'credential-read\\n' >> "$FIXTURE_CALLS"
    fail "fixture production credential is unavailable"
}
`);
    writeFileSync(path.join(scripts, "vm/guest_session.sh"), `
test_vm_require_guest_session() {
    printf 'verify-session\\n' >> "$FIXTURE_CALLS"
    [ "$FIXTURE_ROLE" = guest ] && [ "$FIXTURE_VERIFIED" = yes ]
}
`);
    const environment = {
        PATH: "/usr/bin:/bin", FIXTURE_CALLS: calls, FIXTURE_ROLE: "guest", FIXTURE_VERIFIED: "yes",
        BW_VM_VERIFICATION_BUILD: "YES", ACTION: "build", DEPLOYMENT_LOCATION: "NO", DEPLOYMENT_POSTPROCESSING: "NO",
        CODE_SIGN_IDENTITY: "-", CODE_SIGN_STYLE: "Manual", DEVELOPMENT_TEAM: "", PROVISIONING_PROFILE: "",
        PROVISIONING_PROFILE_SPECIFIER: "", CODE_SIGN_ENTITLEMENTS: "", ENABLE_APP_SANDBOX: "NO",
        ENABLE_HARDENED_RUNTIME: "NO", REGISTER_APP_GROUPS: "NO", PLATFORM_NAME: "macosx", CODE_SIGNING_ALLOWED: "YES",
        TARGET_BUILD_DIR: buildDirectory, UNLOCALIZED_RESOURCES_FOLDER_PATH: resourceFolder,
        SCRIPT_OUTPUT_FILE_COUNT: "1", SCRIPT_OUTPUT_FILE_0: resource,
    };
    const run = (changes = {}, script = "bundle_alchemy_jwt_request_proof_key.sh") => {
        writeFileSync(calls, "");
        const env = {...environment, ...changes};
        for (const [key, value] of Object.entries(env)) { if (value === undefined) { delete env[key]; } }
        return spawnSync("/bin/sh", [path.join(scripts, script)], {encoding: "utf8", timeout: 10000, env});
    };
    try {
        operation({run, resource, calls: () => readFileSync(calls, "utf8")});
    } finally { rmSync(root, {recursive: true, force: true}); }
}

test("verified local builds omit and remove proof resources without reading credentials", () => fixture(({run, resource, calls}) => {
    for (const [platform, signing] of [
        ["macosx", "YES"], ["iphonesimulator", "YES"], ["xrsimulator", "YES"], ["iphoneos", "NO"], ["xros", "NO"],
    ]) {
        writeFileSync(resource, "stale proof resource");
        const credential = "fixture-environment-credential-must-not-be-used";
        const result = run({PLATFORM_NAME: platform, CODE_SIGNING_ALLOWED: signing, ALCHEMY_JWT_REQUEST_PROOF_KEY: credential});
        assert.equal(result.status, 0, `${platform}: ${result.stderr}`);
        assert.equal(existsSync(resource), false);
        assert.equal(calls(), "verify-session\n");
        assert.equal((result.stdout + result.stderr).includes(credential), false);
    }
}));

test("default and explicit production modes still require the production proof loader", () => fixture(({run, resource, calls}) => {
    for (const mode of [undefined, "NO"]) {
        writeFileSync(resource, "stale proof resource");
        const result = run({BW_VM_VERIFICATION_BUILD: mode, FIXTURE_ROLE: "host"});
        assert.equal(result.status, 1);
        assert.match(result.stderr, /fixture production credential is unavailable/);
        assert.equal(calls(), "credential-read\n");
        assert.equal(existsSync(resource), false);
    }
}));

test("proof omission rejects host and unverified guest sessions", () => fixture(({run, resource, calls}) => {
    for (const changes of [{FIXTURE_ROLE: "host"}, {FIXTURE_VERIFIED: "no"}]) {
        writeFileSync(resource, "stale proof resource");
        const result = run(changes);
        assert.equal(result.status, 1);
        assert.match(result.stderr, /verified test VM session/);
        assert.equal(calls(), "verify-session\n");
        assert.equal(existsSync(resource), false);
    }
}));

test("proof omission rejects deployment and inconsistent local build settings", () => fixture(({run, resource, calls}) => {
    const invalid = [
        {ACTION: "archive"}, {ACTION: "install"}, {ACTION: ""}, {ACTION: undefined},
        {DEPLOYMENT_LOCATION: "YES"}, {DEPLOYMENT_POSTPROCESSING: "YES"},
        {ARCHIVE_PATH: "/fixture/app.xcarchive"}, {ARCHIVE_PRODUCTS_PATH: "/fixture/archive/Products"},
        {CODE_SIGN_IDENTITY: "Apple Development"}, {CODE_SIGN_IDENTITY: undefined}, {CODE_SIGN_STYLE: "Automatic"},
        {DEVELOPMENT_TEAM: "TEAM"}, {PROVISIONING_PROFILE: "profile"}, {PROVISIONING_PROFILE_SPECIFIER: "profile"},
        {CODE_SIGN_ENTITLEMENTS: "Wallet.entitlements"}, {ENABLE_APP_SANDBOX: "YES"}, {ENABLE_HARDENED_RUNTIME: "YES"},
        {REGISTER_APP_GROUPS: "YES"}, {REGISTER_APP_GROUPS: undefined},
        {CODE_SIGNING_ALLOWED: "NO"}, {PLATFORM_NAME: "iphoneos"}, {PLATFORM_NAME: "xros"},
        {PLATFORM_NAME: "unknown"}, {PLATFORM_NAME: undefined},
    ];
    for (const changes of invalid) {
        writeFileSync(resource, "stale proof resource");
        const result = run(changes);
        assert.equal(result.status, 1, JSON.stringify(changes));
        assert.match(result.stderr, /VM verification builds/);
        assert.equal(calls(), "");
        assert.equal(existsSync(resource), false);
    }
}));

test("proof omission rejects invalid modes and cannot bypass resource path validation", () => fixture(({run, calls}) => {
    for (const mode of ["", "yes", "1", "local"]) {
        const result = run({BW_VM_VERIFICATION_BUILD: mode});
        assert.equal(result.status, 1);
        assert.match(result.stderr, /BW_VM_VERIFICATION_BUILD must be YES or NO/);
        assert.equal(calls(), "");
    }
    const result = run({SCRIPT_OUTPUT_FILE_0: "/fixture/unrelated-resource"});
    assert.equal(result.status, 1);
    assert.match(result.stderr, /output path does not match/);
    assert.equal(calls(), "");
}));

test("standalone production proof validation does not inherit the local omission mode", () => fixture(({run, calls}) => {
    const result = run({}, "validate_alchemy_jwt_request_proof_key.sh");
    assert.equal(result.status, 1);
    assert.match(result.stderr, /fixture production credential is unavailable/);
    assert.equal(calls(), "credential-read\n");
}));
