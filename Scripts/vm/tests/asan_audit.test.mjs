import assert from "node:assert/strict";
import {mkdtemp, readFile, realpath, rm, symlink, truncate, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import test from "node:test";
import {asanDiagnostics, auditNativeResult, auditResults} from "../result_audit.mjs";
import {auditASanLog, executeStages} from "../guest.mjs";
import {atomicJSON, hashFile} from "../guest_bootstrap.mjs";

const fixture = async operation => {
    const directory = await realpath(await mkdtemp(join(tmpdir(), "wallet-asan-audit-")));
    try { return await operation(directory); }
    finally { await rm(directory, {recursive: true, force: true}); }
};
const success = output => ({code: 0, signal: null, output: output ?? "", timedOut: false, cancelled: false});
const summary = (passed, skipped = 0, failed = 0) => ({totalTestCount: passed + skipped + failed, passedTests: passed, skippedTests: skipped, failedTests: failed});
const runtimeTarget = "WalletAuthorityTests";
const appTarget = "Tests macOS";
const identifiers = ["SecretLifetimeTests/testBorrow", "SecretLifetimeTests/testInvalidate"];
const policy = target => ({kind: "asan", platform: "macos", configuration: "Debug",
    ...(target === runtimeTarget ? {runtime: true} : {}), requiredTests: identifiers.map(name => `${target}/${name}`)});
const tree = (target, names = identifiers, result = "Passed") => ({testNodes: [{nodeType: "Unit test bundle", name: target,
    children: names.map(name => ({nodeType: "Test Case", nodeIdentifier: `${name}()`, result}))}]});

test("ASan audits require every selected app and runtime test to pass exactly once", () => {
    for (const target of [runtimeTarget, appTarget]) {
        const auditPolicy = policy(target);
        assert.equal(auditNativeResult(summary(2), tree(target), auditPolicy).ok, true);
        assert.equal(auditNativeResult(summary(2), tree(target, auditPolicy.requiredTests), auditPolicy).ok, true);
        for (const names of [[], identifiers.slice(0, 1), [...identifiers, identifiers[0]],
            [...identifiers, "UnselectedTests/testUnexpected"], ["SecretLifetimeTests/testUnknown", identifiers[1]]]) {
            assert.equal(auditNativeResult(summary(names.length), tree(target, names), auditPolicy).ok, false, names.join(","));
        }
        assert.equal(auditNativeResult(summary(0, 2), tree(target, identifiers, "Skipped"), auditPolicy).ok, false);
        assert.equal(auditNativeResult(summary(2), tree(target, identifiers, "Unknown"), auditPolicy).ok, false);
        assert.equal(auditNativeResult(summary(2), tree(target === runtimeTarget ? appTarget : runtimeTarget), auditPolicy).ok, false);
        assert.equal(auditNativeResult(summary(2), tree("OtherTarget", auditPolicy.requiredTests), auditPolicy).ok, false);
        for (const requiredTests of [undefined, [], [auditPolicy.requiredTests[0], auditPolicy.requiredTests[0]],
            [`${target}/SecretLifetimeTests`], ["OtherTarget/SecretLifetimeTests/testBorrow"], [null]]) {
            assert.equal(auditNativeResult(summary(2), tree(target), {...auditPolicy, requiredTests}).ok, false);
        }
    }
});

test("ASan does not accept the ordinary Debug performance skip exemption", () => {
    const name = "WalletCoreProxyPerformanceGateTests/testScryptDefaultDerivationPerformanceGate";
    const audit = auditNativeResult(summary(0, 1), tree(runtimeTarget, [name], "Skipped"),
        {...policy(runtimeTarget), requiredTests: [`${runtimeTarget}/${name}`]});
    assert.equal(audit.ok, false);
    assert.deepEqual(audit.expectedSkips, []);
});

test("ASan warning audits retain unrelated QoS warnings and reject sanitizer or malformed warnings", () => {
    const auditPolicy = policy(appTarget);
    const nativeTree = tree(appTarget);
    const qos = {issueType: "Runtime Warning",
        message: "[Internal] Thread running at User-interactive quality-of-service class waiting on a lower QoS thread running at Default quality-of-service class. Investigate ways to avoid priority inversions",
        sourceURL: "file:///fixture/AddressSanitizer.swift"};
    for (const runtimeWarnings of [undefined, [], [qos]]) {
        assert.equal(auditNativeResult({...summary(2), runtimeWarnings}, nativeTree, auditPolicy).ok, true);
    }
    for (const runtimeWarnings of [null, {}, "warning", [null], ["warning"], [[]], [{}], [{message: 1}], [{message: ""}],
        [{message: "unrelated", issueType: 1}]]) {
        const audit = auditNativeResult({...summary(2), runtimeWarnings}, nativeTree, auditPolicy);
        assert.equal(audit.ok, false);
        assert.ok(audit.issues.some(issue => issue.includes("invalid runtime-warning")));
    }
    for (const warning of [{issueType: "Address Sanitizer", message: "Use of deallocated memory"},
        {issueType: "Runtime Warning", message: "ERROR: AddressSanitizer: heap-use-after-free"},
        {issueType: "Runtime Warning", message: "AddressSanitizer: stack-overflow"},
        {warningText: "AddressSanitizer:DEADLYSIGNAL"},
        {message: "Sanitizer load violates platform policy"}]) {
        const audit = auditNativeResult({...summary(2), runtimeWarnings: [qos, warning]}, nativeTree, auditPolicy);
        assert.equal(audit.ok, false);
        assert.ok(audit.issues.includes("AddressSanitizer diagnostic in XCTest runtime warnings"));
    }
});

test("ASan diagnostic detection ignores compiler flags and runtime library paths", () => {
    const clean = [
        "xcodebuild test -enableAddressSanitizer YES",
        "swiftc -sanitize=address /fixture/AddressSanitizer.swift",
        "clang -fsanitize=address -L/fixture/libclang_rt.asan_osx_dynamic.dylib",
        "DYLD_INSERT_LIBRARIES=/fixture/libclang_rt.asan_osx_dynamic.dylib",
        "AddressSanitizer: libc interceptors initialized",
        "AddressSanitizer Init done",
    ].join("\n");
    assert.deepEqual(asanDiagnostics(clean), []);
    for (const diagnostic of [
        "==4321==ERROR: AddressSanitizer: heap-use-after-free on address 0x123",
        "SUMMARY: AddressSanitizer: stack-buffer-overflow fixture.c:4",
        "AddressSanitizer:DEADLYSIGNAL",
        "AddressSanitizer CHECK failed: asan_malloc_mac.cpp:123",
        "AddressSanitizer: heap-buffer-overflow",
        "==4321==ASan runtime does not come first in initial library list",
        "==4321==ASan cannot proceed correctly. ABORTING.",
        "Your application is linked against incompatible ASan runtimes.",
        "AddressSanitizer: failed to allocate 0x123 bytes",
        "AddressSanitizer is loaded too late (e.g. via dlopen).",
        "Sanitizer load violates platform policy",
        "dyld[4321]: Library not loaded: @rpath/libclang_rt.asan_osx_dynamic.dylib",
        "dyld: inserted library '/fixture/libclang_rt.asan_osx_dynamic.dylib' could not be loaded",
    ]) {
        assert.ok(asanDiagnostics(diagnostic).length, diagnostic);
    }
});

test("ASan scans diagnostics beyond captured output and across full-log chunk boundaries", async () => fixture(async directory => {
    const log = join(directory, "stage.log");
    const bytes = Buffer.alloc(17 * 1024 * 1024, 46);
    const diagnostic = "\n==4321==ERROR: AddressSanitizer: heap-use-after-free\n";
    bytes.write(diagnostic, 16 * 1024 * 1024 + 64 * 1024 - 20);
    await writeFile(log, bytes);
    const result = await auditASanLog(log);
    assert.equal(result.ok, false);
    assert.deepEqual(result.diagnostics, ["AddressSanitizer memory error"]);
    assert.equal(result.bytesScanned, bytes.length);
    assert.equal(result.issues.length, 1);
    await writeFile(log, "xcodebuild test -enableAddressSanitizer YES\nTest Suite passed\n");
    const clean = await auditASanLog(log);
    assert.equal(clean.ok, true);
    assert.deepEqual(clean.diagnostics, []);
}));

test("ASan log evidence rejects missing, empty, redirected, oversized, changing, or cancelled inputs", async () => fixture(async directory => {
    const log = join(directory, "stage.log");
    await assert.rejects(auditASanLog(log));
    await writeFile(log, "");
    await assert.rejects(auditASanLog(log), /nonempty bounded regular file/);
    await writeFile(log, "Test Suite passed\n");
    const link = join(directory, "link.log");
    await symlink(log, link);
    await assert.rejects(auditASanLog(link));
    await assert.rejects(auditASanLog(directory), /nonempty bounded regular file/);
    await assert.rejects(auditASanLog(log, {stopRequested: async () => true}), error => error.cancelled === true);
    let changed = false;
    await assert.rejects(auditASanLog(log, {stopRequested: async () => {
        if (!changed) { changed = true; await writeFile(log, "Changed after the initial stat\n"); }
        return false;
    }}), /changed during auditing/);
    await truncate(log, 256 * 1024 * 1024 + 1);
    await assert.rejects(auditASanLog(log), /nonempty bounded regular file/);
}));

const runStage = async ({target = runtimeTarget, log = "Test Suite passed\n", outcome = {}, probe = {}, runtimeWarnings} = {}, inspect = () => {}) => fixture(async directory => {
    const stage = {id: target === runtimeTarget ? "asan.focused.runtime" : "asan.focused", group: "asan", command: "xcodebuild",
        args: ["test", "-enableAddressSanitizer", "YES"], cwd: ".", dependencies: [], requirements: [], timeoutSeconds: 1,
        nativeAudit: policy(target), resultBundle: true};
    const calls = [];
    const results = await executeStages([stage], {workspace: directory, artifacts: directory,
        preflight: {checks: {}, destinations: {macos: "platform=macOS,arch=arm64"}}, writeJSON: atomicJSON, hashFile,
        execute: async (command, args, options) => {
            calls.push([command, ...args]);
            if (command === "xcodebuild") {
                if (log !== null) { await writeFile(options.logPath, log); }
                return {...success(), ...outcome};
            }
            assert.equal(command, "xcrun");
            assert.equal(args[0], "xcresulttool");
            return {...success(JSON.stringify(args.includes("summary") ? {...summary(2), runtimeWarnings} : tree(target))), ...probe};
        }});
    await inspect(results[0], directory, calls);
    return results;
});

test("ASan execution requires both native and full-log audits for app and runtime tests", async () => {
    for (const target of [runtimeTarget, appTarget]) {
        const passed = await runStage({target}, async (stage, directory) => {
            assert.equal(stage.status, "passed");
            assert.equal(stage.audit.ok, true);
            assert.equal(stage.audit.asanLog.ok, true);
            assert.equal(stage.audit.asanLog.bytesScanned, 18);
            assert.equal(JSON.parse(await readFile(join(directory, `${stage.id}.summary.json`), "utf8")).passedTests, 2);
        });
        assert.equal(auditResults(passed).status, "passed");
        for (const audit of [undefined, {ok: true}, {...passed[0].audit, ok: false},
            {...passed[0].audit, asanLog: undefined}, {...passed[0].audit, asanLog: {ok: false}}]) {
            assert.equal(auditResults([{...passed[0], audit}]).status, "failed");
        }
        for (const options of [{log: null}, {log: ""}, {log: "ERROR: AddressSanitizer: heap-use-after-free\n"},
            {outcome: {outputDrainTimedOut: true}}, {runtimeWarnings: [{issueType: "Address Sanitizer", message: "Use of deallocated memory"}]}]) {
            const failed = await runStage({target, ...options});
            assert.equal(failed[0].status, "failed");
            assert.equal(failed[0].audit.ok, false);
            assert.equal(auditResults(failed).status, "failed");
        }
    }
});

test("ASan execution preserves failed, crashed, timed-out, cancelled, and unauditable outcomes", async () => {
    for (const [outcome, status, calls] of [[{code: 65}, "failed", 3], [{code: null, signal: "SIGABRT"}, "failed", 3],
        [{timedOut: true}, "failed", 1], [{cancelled: true}, "cancelled", 1]]) {
        const results = await runStage({outcome}, async (stage, directory, executed) => {
            assert.equal(stage.status, status);
            assert.equal(executed.length, calls);
            assert.equal(await readFile(join(directory, stage.log), "utf8"), "Test Suite passed\n");
            assert.equal(stage.exitCode, outcome.code === undefined ? 0 : outcome.code);
            assert.equal(stage.signal, outcome.signal ?? null);
        });
        assert.notEqual(auditResults(results).status, "passed");
    }
    for (const [probe, status] of [[{code: 1}, "failed"], [{timedOut: true}, "failed"], [{error: "missing result bundle"}, "failed"],
        [{output: "not JSON"}, "failed"], [{cancelled: true}, "cancelled"]]) {
        await runStage({probe, log: "AddressSanitizer:DEADLYSIGNAL\n"}, stage => {
            assert.equal(stage.status, status);
            assert.equal(stage.audit.ok, false);
            assert.equal(stage.audit.asanLog.ok, false);
            assert.ok(stage.audit.asanLog.diagnostics.includes("AddressSanitizer fatal diagnostic"));
        });
    }
});
