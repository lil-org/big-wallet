import assert from "node:assert/strict";
import {spawnSync} from "node:child_process";
import {chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from "node:fs";
import {tmpdir} from "node:os";
import path from "node:path";
import test from "node:test";

function fixture(operation) {
    const root = mkdtempSync(path.join(tmpdir(), "big-wallet-approval-route-"));
    const scripts = path.join(root, "Scripts");
    mkdirSync(path.join(scripts, "vm"), {recursive: true});
    const calls = path.join(root, "calls");
    const argv = path.join(root, "argv");
    writeFileSync(calls, "");
    writeFileSync(argv, "");
    const target = path.join(scripts, "check_approval_lifecycle.sh");
    writeFileSync(target, readFileSync(new URL("../../check_approval_lifecycle.sh", import.meta.url)));
    writeFileSync(path.join(scripts, "inpage_provider_toolchain.sh"), `
inpage_provider_prepare_tool_path() { :; }
require_inpage_provider_toolchain() { printf 'toolchain-check\n' >> "$FIXTURE_CALLS"; return 41; }
inpage_provider_run_node() { "$FIXTURE_NODE" "$@"; }
`);
    writeFileSync(path.join(scripts, "vm/guest_session.sh"), `
test_vm_is_virtual_mac() { [ "$FIXTURE_ROLE" = guest ]; }
test_vm_require_guest_session() { printf 'guest-verification\n' >> "$FIXTURE_CALLS"; [ "$FIXTURE_VERIFIED" = yes ]; }
`);
    const runner = path.join(scripts, "test_vm.sh");
    writeFileSync(runner, `#!/bin/sh
printf 'vm-route\n' >> "$FIXTURE_CALLS"
printf '%s\\0' "$@" > "$FIXTURE_ARGV"
exit 27
`);
    chmodSync(runner, 0o755);
    const run = (arguments_ = [], changes = {}) => spawnSync("/bin/sh", [target, ...arguments_], {
        encoding: "utf8", timeout: 10000,
        env: {PATH: "/usr/bin:/bin", FIXTURE_NODE: process.execPath, FIXTURE_CALLS: calls,
            FIXTURE_ARGV: argv, FIXTURE_ROLE: "host", FIXTURE_VERIFIED: "yes", ...changes},
    });
    try {
        operation({run, calls: () => readFileSync(calls, "utf8"),
            argv: () => readFileSync(argv, "utf8").split("\0").filter(Boolean)});
    } finally { rmSync(root, {recursive: true, force: true}); }
}

test("host approval route needs no local npm validation and preserves defaults", () => fixture(({run, calls, argv}) => {
    const result = run();
    assert.equal(result.status, 27, result.stderr);
    assert.equal(calls(), "vm-route\n");
    assert.deepEqual(argv(), ["run", "all", "--stage", "approval", "--configuration", "Debug"]);
}));

test("host approval route preserves configuration and spaced replay arguments", () => fixture(({run, calls, argv}) => {
    const result = run(["--replay", "/fixture/results with spaces/replay.json", "--no-minimize"], {APPROVAL_CONFIGURATION: "Release"});
    assert.equal(result.status, 27, result.stderr);
    assert.equal(calls(), "vm-route\n");
    assert.deepEqual(argv(), ["run", "all", "--stage", "approval", "--configuration", "Release",
        "--approval-arg=--replay", "--approval-arg=/fixture/results with spaces/replay.json", "--approval-arg=--no-minimize"]);
}));

test("verified guest still requires its provider toolchain before build steps", () => fixture(({run, calls, argv}) => {
    const result = run([], {FIXTURE_ROLE: "guest"});
    assert.equal(result.status, 41, result.stderr);
    assert.equal(calls(), "guest-verification\ntoolchain-check\n");
    assert.deepEqual(argv(), []);
}));

test("unverified guest cannot validate tools or route back to the host", () => fixture(({run, calls, argv}) => {
    const result = run([], {FIXTURE_ROLE: "guest", FIXTURE_VERIFIED: "no"});
    assert.equal(result.status, 2, result.stderr);
    assert.equal(calls(), "guest-verification\n");
    assert.deepEqual(argv(), []);
}));
