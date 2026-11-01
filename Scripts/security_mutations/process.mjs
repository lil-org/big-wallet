import {spawn} from "node:child_process";
import {createWriteStream} from "node:fs";
import {writeFile} from "node:fs/promises";
import {observeProcess} from "../process_lifecycle.mjs";
import {LIMITS} from "./contract.mjs";

export function commandEnvironment(environment = process.env) {
    const names = ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "DEVELOPER_DIR",
        "BW_TEST_VM_RUN_ID", "BW_TEST_VM_EXCHANGE", "BW_TEST_VM_SOURCE_SHA256"];
    return {...Object.fromEntries(names.flatMap(name => typeof environment[name] === "string" ? [[name, environment[name]]] : [])),
        CI: "1", NO_COLOR: "1"};
}

export async function runCommand(command, args, {cwd, env = commandEnvironment(), logPath, timeoutSeconds,
    stopRequested = async () => false} = {}) {
    if (await stopRequested()) {
        await writeFile(logPath, "", {flag: "wx", mode: 0o600});
        return {code: null, signal: null, timedOut: false, cancelled: true, outputDrainTimedOut: false, stdout: "", stderr: ""};
    }
    let stdout = "", stderr = "", error = null, bytes = 0;
    let timedOut = false, cancelled = false, polling = false;
    const log = createWriteStream(logPath, {flags: "wx", mode: 0o600});
    const child = spawn(command, args, {cwd, env, shell: false, detached: true, stdio: ["ignore", "pipe", "pipe"]});
    let timer, interval;
    const lifecycle = observeProcess(child, {policy: "vm-command", terminationGraceMilliseconds: 5000, allowStopAfterExit: true,
        signalGroup: (pid, signal) => process.kill(-pid, signal),
        onStop: reason => { timedOut = reason === "timeout"; cancelled = reason === "cancel"; },
        onFailure: (_, failure) => { error ??= failure.message; },
        onExit: () => { clearTimeout(timer); clearInterval(interval); }});
    const capture = (chunk, stream) => {
        bytes += chunk.length;
        if (bytes > LIMITS.maximumArtifactBytes) {
            error ??= "Mutation command exceeded its retained-output budget";
            lifecycle.stop("failure");
            return;
        }
        log.write(chunk);
        if (stream === "stdout") { stdout += chunk.toString("utf8"); }
        else { stderr += chunk.toString("utf8"); }
    };
    child.stdout.on("data", chunk => capture(chunk, "stdout"));
    child.stderr.on("data", chunk => capture(chunk, "stderr"));
    log.on("error", failure => { error = failure.message; lifecycle.stop("failure"); });
    timer = setTimeout(() => lifecycle.stop("timeout"), timeoutSeconds * 1000);
    interval = setInterval(async () => {
        if (polling) { return; }
        polling = true;
        try { if (await stopRequested()) { lifecycle.stop("cancel"); } }
        catch { lifecycle.stop("cancel"); }
        finally { polling = false; }
    }, 250);
    try {
        const outcome = await lifecycle.exit;
        const outputDrainTimedOut = await lifecycle.drainOutput(2000);
        if (outputDrainTimedOut) { lifecycle.stop("failure"); }
        await lifecycle.waitForEscalation();
        await new Promise(done => log.end(done));
        return {...outcome, timedOut, cancelled, outputDrainTimedOut, error, stdout, stderr};
    } finally {
        clearTimeout(timer); clearInterval(interval); lifecycle.dispose();
    }
}
