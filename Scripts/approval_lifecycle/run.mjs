import {access, mkdir, readFile, writeFile} from "node:fs/promises";
import {constants} from "node:fs";
import {join, resolve} from "node:path";
import {pathToFileURL} from "node:url";
import {LifecycleSession} from "./session.mjs";
import {LifecycleFailure} from "./scheduler.mjs";
import {generateScenario, minimizeScenario, parseOptions, validateScenario} from "./scenarios.mjs";
import {mandatoryName, mandatoryScenarios, runMandatory, validateMandatoryScenario} from "./mandatory.mjs";

const help = `Usage: Scripts/check_approval_lifecycle.sh [options]
  --seed N             Reproducible unsigned 32-bit seed (default 1)
  --sequences N        Random sequences (default 32; maximum 1000)
  --steps N            Actions per sequence (default 64; maximum 10000)
  --mode MODE          alternate, native, or popup (default alternate)
  --soak               Defaults to 1000 sequences of 200 actions
  --replay PATH        Replay a saved scenario.json or replay.json
  --failure-dir PATH   Retain failure diagnostics beneath this directory
  --scratch-dir PATH   Create disposable runs beneath this directory
  --timeout-ms N       Wall-clock watchdog (default 15000)
  --no-minimize        Retain failures without trace reduction
  --random-only        Omit mandatory cases for local diagnosis
  --worker PATH        Built ApprovalCrashWorker (supplied by shell entry point)
  --help               Show this help
`;

const shellQuote = value => "'" + value.replaceAll("'", "'\\''") + "'";

function checkedScenario(value) {
    return value?.mandatory ? validateMandatoryScenario(value) : validateScenario(value);
}

function recordedScenario(scenario, session) {
    const faultTargets = Object.fromEntries(Object.entries({...session.faultTargets, ...scenario.faultTargets})
        .filter(([index]) => Number(index) >= 0 && Number(index) < scenario.actions.length));
    return structuredClone({...scenario, decisions: session.decisions || [], faultTargets});
}

async function bootstrap(session) {
    for (const tab of [0, 1, 2, 3]) {
        for (const provider of ["ethereum", "solana"]) { await session.connect(tab, provider); }
    }
    for (let tab = 0; tab < 4; tab += 1) {
        session.request({tab, provider: tab % 2 ? "solana" : "ethereum", method: "message"});
    }
    await session.pump();
    await session.inspect();
}

export async function executeScenario(scenario, options, {capture = true} = {}) {
    checkedScenario(scenario);
    const session = new LifecycleSession({...options, mode: scenario.mode, seed: scenario.seed,
        decisions: scenario.decisions, faultTargets: scenario.faultTargets});
    let preserve = false;
    try {
        await session.initialize();
        if (scenario.mandatory) { await runMandatory(session, scenario); }
        else {
            await bootstrap(session);
            for (let index = 0; index < scenario.actions.length; index += 1) {
                await session.action(scenario.actions[index]);
            }
            await session.quiesce();
            session.check();
        }
        if (scenario.decisions && session.decisions.length < scenario.decisions.length) {
            throw new LifecycleFailure("replay-schedule", "Replay did not consume every saved scheduling decision");
        }
        for (const [action, target] of Object.entries(scenario.faultTargets || {})) {
            if (session.faultTargets[action] !== target) {
                throw new LifecycleFailure("replay-schedule", "Replay did not apply a saved transport fault", {
                    action: Number(action), expected: target, actual: session.faultTargets[action],
                });
            }
        }
        await session.freeze();
        session.check();
        return {scenario: recordedScenario(scenario, session), coverage: [...session.coverage],
            oracleCoverage: [...session.oracle.coverage], effects: session.ledger.events.length};
    } catch (caught) {
        const error = caught instanceof LifecycleFailure ? caught : new LifecycleFailure(
            scenario.mandatory ? "mandatory" : "unexpected", caught.message, {stack: caught.stack, case: scenario.mandatory});
        error.replayScenario = recordedScenario({...scenario, actions: scenario.actions.slice(0, session.actionIndex + 1)}, session);
        if (capture && session.root) {
            preserve = true;
            const name = `${scenario.mode}-${scenario.mandatory ? mandatoryName(scenario).replaceAll("/", "-") : `seed-${scenario.seed}`}-${Date.now()}`;
            const destination = options.failureDirectory ? join(resolve(options.failureDirectory), name) : join(session.root, "failure");
            const replay = error.replayScenario;
            error.artifactPath = await session.artifacts(error, replay, destination);
            await writeFile(join(error.artifactPath, "replay.json"), JSON.stringify({version: 1, invariant: error.invariant,
                scenario: replay, originalScenario: replay, reproduced: null}, null, 2) + "\n");
        }
        throw error;
    } finally { await session.close({preserve}); }
}

async function reduceFailure(error, options) {
    if (!error.artifactPath || !error.replayScenario || error.replayScenario.mandatory || !options.minimize) { return; }
    const original = error.replayScenario;
    const replay = candidate => executeScenario(candidate, options, {capture: false});
    let reproduced = false;
    try { await replay(original); }
    catch (again) { reproduced = again.invariant === error.invariant; }
    let minimized = original;
    let attempts = 0;
    if (reproduced) {
        const candidate = {...original};
        delete candidate.decisions;
        delete candidate.faultTargets;
        const result = await minimizeScenario(candidate, error.invariant, replay, 200);
        attempts = result.attempts;
        try { await replay(result.scenario); }
        catch (again) { if (again.invariant === error.invariant) { minimized = again.replayScenario; } }
    }
    await writeFile(join(error.artifactPath, "replay.json"), JSON.stringify({version: 1, invariant: error.invariant,
        scenario: minimized, originalScenario: original, reproduced, reductionAttempts: attempts}, null, 2) + "\n");
}

export async function main(arguments_ = process.argv.slice(2)) {
    const options = parseOptions(arguments_);
    if (options.help) { process.stdout.write(help); return; }
    options.worker = resolve(options.worker);
    await access(options.worker, constants.X_OK);
    if (options.failureDirectory) { await mkdir(options.failureDirectory, {recursive: true}); }
    const coverage = new Set;
    let completed = 0;
    let scenarios;
    if (options.replay) {
        const saved = JSON.parse(await readFile(options.replay, "utf8"));
        scenarios = [checkedScenario(saved.scenario || saved)];
    } else {
        const modes = options.mode === "alternate" ? ["native", "popup"] : [options.mode];
        scenarios = options.mandatory ? modes.flatMap(mode => mandatoryScenarios(mode, options.seed)) : [];
        for (let index = 0; index < options.sequences; index += 1) {
            scenarios.push(generateScenario({seed: (options.seed + index) >>> 0, steps: options.steps, mode: modes[index % modes.length]}));
        }
    }
    for (const scenario of scenarios) {
        const label = scenario.mandatory ? mandatoryName(scenario) : `${scenario.mode}/seed-${scenario.seed}/${scenario.actions.length}-actions`;
        process.stdout.write(`Approval lifecycle: ${label}\n`);
        try {
            const result = await executeScenario(scenario, options);
            for (const name of result.coverage.concat(result.oracleCoverage)) { coverage.add(name); }
            completed += 1;
        } catch (error) {
            if (error.artifactPath) {
                process.stderr.write(`Failure artifacts: ${error.artifactPath}\n`);
                await reduceFailure(error, options);
                process.stderr.write(`Replay: Scripts/check_approval_lifecycle.sh --replay ${shellQuote(join(error.artifactPath, "replay.json"))}\n`);
            }
            throw error;
        }
    }
    if (!options.replay) {
        const required = options.mandatory ? ["consent", "signer.before", "signer.after", "broadcast.prepared",
            "broadcast.dispatch", "broadcast.accepted", "process-lock-recovery", "old-process-consent",
            "wallet-revocation-crash", "authentication-cancelled", "revocation-before-signing"] : [];
        if (options.mandatory && options.mode !== "native") { required.push("edited-review-token"); }
        if (options.mandatory && options.mode !== "popup") { required.push("native-explicit-review-retry", "native-chain-switch-authentication"); }
        if (options.sequences >= 32 && options.steps >= 64) {
            required.push("gate:authentication.before",
                "gate:signer.before", "gate:signer.after", "gate:broadcast.prepared");
        }
        const missing = required.filter(name => !coverage.has(name));
        if (options.sequences >= 32 && options.steps >= 64) {
            if (![...coverage].some(name => name.startsWith("fault:persistence:"))) {
                missing.push("applied persistence failure");
            }
            for (const kind of ["drop", "delay", "duplicate"]) {
                if (![...coverage].some(name => name.startsWith("fault:") && name.endsWith(`:${kind}`))) {
                    missing.push(`applied ${kind} fault`);
                }
            }
        }
        if (missing.length) { throw new LifecycleFailure("coverage", "Run omitted required exercised transitions", {missing}); }
    }
    process.stdout.write(`Approval lifecycle passed: ${completed} scenarios, ${coverage.size} observed coverage points.\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
    main().catch(error => { process.stderr.write(`${error.stack || error}\n`); process.exitCode = 1; });
}
