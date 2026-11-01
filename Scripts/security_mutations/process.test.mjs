import assert from "node:assert/strict";
import {spawnSync} from "node:child_process";
import {mkdtemp, readFile, realpath, rm, writeFile} from "node:fs/promises";
import {join} from "node:path";
import {tmpdir} from "node:os";
import {fileURLToPath} from "node:url";
import {setTimeout as delay} from "node:timers/promises";
import test from "node:test";
import {classifyExecution, parseNodeResults} from "./audit.mjs";
import {commandEnvironment, runCommand} from "./process.mjs";

async function directory(t) {
    const path = await realpath(await mkdtemp(join(tmpdir(), "mutation-runner-canary-")));
    t.after(() => rm(path, {recursive: true, force: true}));
    return path;
}

test("real Node reporter canary records an assertion kill without running repository tests", async t => {
    const root = await directory(t);
    const file = join(root, "canary.test.mjs");
    const marker = "SECURITY-MUTATION[canary.assertion]";
    await writeFile(file, `import test from 'node:test'; import assert from 'node:assert/strict';\n` +
        `test('selected invariant',()=>assert.equal(1,2,'${marker}'));\ntest('unselected',()=>{});\n`);
    const outcome = spawnSync(process.execPath, ["--test", "--test-name-pattern=^selected invariant$",
        `--test-reporter=${fileURLToPath(new URL("./node_reporter.mjs", import.meta.url))}`, file], {encoding: "utf8", timeout: 5000, env: commandEnvironment()});
    assert.equal(outcome.status, 1, outcome.stderr);
    const cases = parseNodeResults(outcome.stdout);
    assert.equal(cases.filter(value => value.name === "selected invariant").length, 1);
    const execution = {family: "javascript", selectors: ["selected invariant"], nodeResults: outcome.stdout,
        test: {outcome: {code: 1, signal: null, timedOut: false, cancelled: false, outputDrainTimedOut: false}}};
    assert.equal(classifyExecution(execution, {witness: {selector: "selected invariant", marker}}).status, "killed");
});

test("process cancellation kills its detached Node-only canary before returning", async t => {
    const root = await directory(t);
    const logPath = join(root, "cancel.log");
    const started = performance.now();
    const outcome = await runCommand(process.execPath, ["-e", "process.stdout.write(String(process.pid)); setInterval(()=>{},1000)"],
        {cwd: root, logPath, timeoutSeconds: 10, stopRequested: async () => performance.now() - started > 100});
    assert.equal(outcome.cancelled, true);
    const pid = Number(await readFile(logPath, "utf8"));
    assert.ok(Number.isInteger(pid) && pid > 0);
    assert.throws(() => process.kill(pid, 0), error => error.code === "ESRCH");
    assert.ok(performance.now() - started < 9000);
});

test("output drain failure terminates descendants after their parent exits", {timeout: 15000}, async t => {
    const root = await directory(t);
    const pidPath = join(root, "pids.json");
    const signalsPath = join(root, "signals");
    const descendant = `
        process.on('SIGTERM', () => require('node:fs').appendFileSync(${JSON.stringify(signalsPath)}, 'TERM'));
        process.stdout.write('ready');
        setInterval(() => {}, 1000);
    `;
    const parent = `
        const child = require('node:child_process').spawn(process.execPath, ['-e', ${JSON.stringify(descendant)}],
            {stdio: ['ignore', 'pipe', 'inherit']});
        require('node:fs').writeFileSync(${JSON.stringify(pidPath)}, JSON.stringify({parent: process.pid, child: child.pid}));
        child.stdout.once('data', () => process.exit(0));
    `;
    let pids;
    try {
        const outcome = await runCommand(process.execPath, ["-e", parent],
            {cwd: root, logPath: join(root, "drain.log"), timeoutSeconds: 10});
        pids = JSON.parse(await readFile(pidPath, "utf8"));
        assert.equal(outcome.code, 0);
        assert.equal(outcome.outputDrainTimedOut, true);
        assert.equal(outcome.timedOut, false);
        assert.equal(outcome.cancelled, false);
        assert.equal(await readFile(signalsPath, "utf8"), "TERM");
        const exited = () => {
            try { process.kill(pids.child, 0); return false; }
            catch (error) { if (error.code === "ESRCH") { return true; } throw error; }
        };
        for (let count = 0; count < 100 && !exited(); count++) { await delay(10); }
        assert.ok(exited(), "The command descendant survived process-group escalation");
    } finally {
        pids ??= JSON.parse(await readFile(pidPath, "utf8").catch(() => "null"));
        if (pids) {
            try { process.kill(-pids.parent, "SIGKILL"); }
            catch (error) { if (error.code !== "ESRCH") { throw error; } }
        }
    }
});

test("timeout and a nonzero Node exit remain distinct orchestration outcomes", async t => {
    const root = await directory(t);
    const timeout = await runCommand(process.execPath, ["-e", "setInterval(()=>{},1000)"],
        {cwd: root, logPath: join(root, "timeout.log"), timeoutSeconds: 0.1});
    assert.equal(timeout.timedOut, true);
    assert.equal(timeout.cancelled, false);
    const failure = await runCommand(process.execPath, ["-e", "process.exit(65)"],
        {cwd: root, logPath: join(root, "exit.log"), timeoutSeconds: 5});
    assert.equal(failure.code, 65);
    assert.equal(failure.timedOut, false);
});

test("mutation command environments exclude credentials and caller compiler overrides", () => {
    const environment = commandEnvironment({PATH: "/bin", HOME: "/home/test", ALCHEMY_JWT_REQUEST_PROOF_KEY: "secret",
        OTHER_SWIFT_FLAGS: "-D BYPASS", SWIFT_ACTIVE_COMPILATION_CONDITIONS: "BYPASS", BW_TEST_VM_RUN_ID: "run"});
    assert.equal(environment.ALCHEMY_JWT_REQUEST_PROOF_KEY, undefined);
    assert.equal(environment.OTHER_SWIFT_FLAGS, undefined);
    assert.equal(environment.SWIFT_ACTIVE_COMPILATION_CONDITIONS, undefined);
    assert.equal(environment.BW_TEST_VM_RUN_ID, "run");
});

test("evidence descriptor reads reject FIFO inputs without blocking the audit", async t => {
    const root = await directory(t);
    const fifo = join(root, "report.json");
    const created = spawnSync("mkfifo", [fifo], {encoding: "utf8", timeout: 1000});
    assert.equal(created.status, 0, created.stderr);
    const module = new URL("./audit.mjs", import.meta.url).href;
    const script = `import {readEvidenceFile} from ${JSON.stringify(module)};` +
        `try { await readEvidenceFile(process.argv[1]); process.exitCode=2; }` +
        `catch(error) { if (!error.message.includes('bounded regular file')) throw error; process.stdout.write('rejected'); }`;
    const result = spawnSync(process.execPath, ["--input-type=module", "-e", script, fifo],
        {encoding: "utf8", timeout: 1500, env: commandEnvironment()});
    assert.equal(result.status, 0, result.error?.message ?? result.stderr);
    assert.equal(result.stdout, "rejected");
});
