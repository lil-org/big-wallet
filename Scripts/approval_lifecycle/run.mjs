import {access, mkdir, readFile, writeFile} from "node:fs/promises";
import {constants} from "node:fs";
import {dirname, join, resolve} from "node:path";
import {pathToFileURL} from "node:url";
import {isDeepStrictEqual} from "node:util";
import {LifecycleSession} from "./session.mjs";
import {LifecycleFailure} from "./scheduler.mjs";
import {generateScenario, minimizeScenario, parseOptions, validateScenario} from "./scenarios.mjs";
import {mandatoryName, mandatoryScenarios, runMandatory, validateMandatoryScenario} from "./mandatory.mjs";
import {EXPLORATION_BOUNDS, ScheduleExplorer, exploreSchedules, minimizeSchedule} from "./explorer.mjs";
import {runSystematic, systematicName, systematicScenarios, validateSystematicScenario} from "./systematic.mjs";
import {captureSourceIdentity, validateSourceIdentity} from "./source_identity.mjs";

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
  --systematic PROFILE all, extended, or off (default all)
  --systematic-only    Run only bounded deterministic race exploration
  --trace-limit N      Maximum systematic traces across this run (all: 256; extended: 4096)
  --worker PATH        Built ApprovalCrashWorker (supplied by shell entry point)
  --help               Show this help
`;

const shellQuote = value => "'" + value.replaceAll("'", "'\\''") + "'";

function checkedScenario(value) {
    if (value?.sourceIdentity !== undefined) { validateSourceIdentity(value.sourceIdentity); }
    if (value?.systematic) { return validateSystematicScenario(value); }
    return value?.mandatory ? validateMandatoryScenario(value) : validateScenario(value);
}

function recordedScenario(scenario, session, preserveSchedule = false) {
    const targets = preserveSchedule && scenario.faultTargets !== undefined ? scenario.faultTargets :
        {...session.faultTargets, ...scenario.faultTargets};
    const faultTargets = Object.fromEntries(Object.entries(targets)
        .filter(([index]) => Number(index) >= 0 && Number(index) < scenario.actions.length));
    return structuredClone({...scenario, sourceIdentity: session.originalSourceIdentity,
        reproduction: {sourceIdentity: session.sourceIdentity},
        ...(scenario.actionPhases === undefined ? {} : {actionPhases: scenario.actionPhases.slice(0, scenario.actions.length)}),
        decisions: preserveSchedule ? scenario.decisions ?? session.decisions : session.decisions, faultTargets,
        ...(session.systematicExplorer ? {schedule: preserveSchedule ? scenario.schedule ?? session.systematicExplorer.prefix : session.systematicExplorer.steps} : {})});
}

function requireConsumedReplay(scenario, session) {
    if (scenario.decisions && session.decisions.length < scenario.decisions.length) {
        throw new LifecycleFailure("replay-schedule", "Replay did not consume every saved scheduling decision", {
            expected: scenario.decisions.length, consumed: session.decisions.length,
        });
    }
    if (scenario.decisions && session.decisions.length !== scenario.decisions.length) {
        throw new LifecycleFailure("replay-schedule", "Replay reached an unrecorded scheduling decision", {
            expected: scenario.decisions.length, consumed: session.decisions.length,
        });
    }
    for (const [action, target] of Object.entries(scenario.faultTargets || {})) {
        if (session.faultTargets[action] !== target) {
            throw new LifecycleFailure("replay-schedule", "Replay did not apply a saved transport fault", {
                action: Number(action), expected: target, actual: session.faultTargets[action],
            });
        }
    }
    if (scenario.faultTargets && !isDeepStrictEqual(session.faultTargets, scenario.faultTargets)) {
        throw new LifecycleFailure("replay-schedule", "Replay applied an unrecorded transport fault", {
            expected: scenario.faultTargets, actual: session.faultTargets,
        });
    }
    if (session.systematicExplorer?.exact) { session.systematicExplorer.finish(); }
}

function replayArtifact(invariant, scenario, originalScenario, sourceIdentity, reproduction = {}) {
    return {version: 1, invariant, sourceIdentity: originalScenario.sourceIdentity,
        reproduction: {sourceIdentity, ...reproduction}, scenario, originalScenario, ...reproduction};
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

export async function executeScenario(scenario, options, {capture = true, explorer = null, exact = true} = {}) {
    checkedScenario(scenario);
    const sourceIdentity = validateSourceIdentity(options.sourceIdentity ?? await captureSourceIdentity(options.worker));
    const session = new LifecycleSession({...options, sourceIdentity,
        originalSourceIdentity: scenario.sourceIdentity ?? sourceIdentity, mode: scenario.mode, seed: scenario.seed,
        decisions: scenario.decisions, faultTargets: scenario.faultTargets, actionPhases: scenario.actionPhases});
    if (scenario.systematic) {
        session.systematicExplorer = explorer ?? new ScheduleExplorer({prefix: scenario.schedule ?? [], profile: scenario.systematic.profile, exact: exact && scenario.schedule !== undefined});
    }
    let preserve = false;
    try {
        await session.initialize();
        if (scenario.systematic) { await runSystematic(session, scenario, session.systematicExplorer); }
        else if (scenario.mandatory) { await runMandatory(session, scenario); }
        else {
            await bootstrap(session);
            for (let index = 0; index < scenario.actions.length; index += 1) {
                await session.action(scenario.actions[index]);
            }
            await session.quiesce();
            session.check();
        }
        requireConsumedReplay(scenario, session);
        await session.freeze();
        session.check();
        return {scenario: recordedScenario(scenario, session), coverage: [...session.coverage],
            ...(session.systematicExplorer ? {systematic: {...session.systematicExplorer.finish(), ...session.systematicWorkload}} : {}),
            oracleCoverage: [...session.oracle.coverage], effects: session.ledger.events.length};
    } catch (caught) {
        let error = caught instanceof LifecycleFailure ? caught : new LifecycleFailure(
            scenario.mandatory ? "mandatory" : "unexpected", caught.message, {stack: caught.stack, case: scenario.mandatory});
        if (error.invariant !== "replay-schedule") {
            try { requireConsumedReplay(scenario, session); }
            catch (mismatch) {
                mismatch.details = {...mismatch.details, observedFailure: {invariant: error.invariant, message: error.message}};
                error = mismatch;
            }
        }
        const preserveSchedule = error.invariant === "replay-schedule";
        error.replayScenario = recordedScenario(preserveSchedule ? scenario :
            {...scenario, actions: scenario.actions.slice(0, session.actionIndex + 1)}, session, preserveSchedule);
        if (session.systematicExplorer) { error.systematicSchedule = structuredClone(session.systematicExplorer.steps); }
        if (capture && session.root && !(explorer && error.invariant === "exploration-bound")) {
            preserve = true;
            const label = scenario.systematic ? systematicName(scenario) : scenario.mandatory ? mandatoryName(scenario) : `seed-${scenario.seed}`;
            const name = `${scenario.mode}-${label.replaceAll("/", "-")}-${Date.now()}`;
            const destination = options.failureDirectory ? join(resolve(options.failureDirectory), name) : join(session.root, "failure");
            const replay = error.replayScenario;
            error.artifactPath = await session.artifacts(error, replay, destination);
            await writeFile(join(error.artifactPath, "replay.json"), JSON.stringify(
                replayArtifact(error.invariant, replay, replay, sourceIdentity, {reproduced: null}), null, 2) + "\n");
        }
        throw error;
    } finally { await session.close({preserve}); }
}

export async function reduceFailure(error, options) {
    if (!error.artifactPath || !error.replayScenario || error.replayScenario.mandatory || !options.minimize ||
        ["replay-schedule", "exploration-budget", "exploration-bound"].includes(error.invariant)) { return; }
    const sourceIdentity = validateSourceIdentity(options.sourceIdentity ?? await captureSourceIdentity(options.worker));
    const replayOptions = {...options, sourceIdentity};
    const original = error.replayScenario;
    const replay = candidate => executeScenario(candidate, replayOptions, {capture: false});
    let reproduced = false;
    try { await replay(original); }
    catch (again) { reproduced = again.invariant === error.invariant; }
    let minimized = original;
    let attempts = 0;
    let stableReproductions = 0;
    const verifyTwice = async value => {
        let candidate;
        for (let repetition = 0; repetition < 2; repetition += 1) {
            try { await replay(value); return null; }
            catch (again) {
                if (again.invariant !== error.invariant ||
                    candidate && !isDeepStrictEqual(candidate, again.replayScenario)) { return null; }
                candidate = again.replayScenario;
            }
        }
        stableReproductions = 2;
        return candidate;
    };
    if (reproduced) {
        if (original.systematic) {
            const result = await minimizeSchedule(original.schedule, error.invariant,
                schedule => executeScenario({...original, schedule}, replayOptions, {capture: false, exact: false}), 200);
            attempts = result.attempts;
            const candidate = await verifyTwice({...original, schedule: result.schedule});
            if (candidate) { minimized = candidate; }
        } else {
            const result = await minimizeScenario(original, error.invariant, replay, 200);
            attempts = result.attempts;
            const candidate = await verifyTwice(result.scenario);
            if (candidate) { minimized = candidate; }
        }
    }
    await writeFile(join(error.artifactPath, "replay.json"), JSON.stringify(
        replayArtifact(error.invariant, minimized, original, sourceIdentity,
            {reproduced, reductionAttempts: attempts, stableReproductions}), null, 2) + "\n");
}

export async function main(arguments_ = process.argv.slice(2)) {
    const options = parseOptions(arguments_);
    if (options.help) { process.stdout.write(help); return; }
    options.worker = resolve(options.worker);
    await access(options.worker, constants.X_OK);
    options.sourceIdentity = await captureSourceIdentity(options.worker);
    if (options.failureDirectory) { await mkdir(options.failureDirectory, {recursive: true}); }
    const coverage = new Set;
    let completed = 0;
    let systematicTraces = 0;
    const explorationReports = [];
    let scenarios;
    if (options.replay) {
        const saved = JSON.parse(await readFile(options.replay, "utf8"));
        const scenario = checkedScenario(saved.scenario || saved);
        validateSourceIdentity(scenario.sourceIdentity);
        if (scenario.systematic && !Array.isArray(scenario.schedule)) { throw new Error("Systematic replay requires a recorded schedule"); }
        scenarios = [scenario];
    } else {
        const modes = options.mode === "alternate" ? ["native", "popup"] : [options.mode];
        scenarios = options.mandatory ? modes.flatMap(mode => mandatoryScenarios(mode, options.seed)) : [];
        if (options.systematic !== "off") {
            scenarios.push(...modes.flatMap(mode => systematicScenarios(mode, options.seed, options.systematic)));
        }
        for (let index = 0; index < options.sequences; index += 1) {
            scenarios.push(generateScenario({seed: (options.seed + index) >>> 0, steps: options.steps, mode: modes[index % modes.length]}));
        }
    }
    for (const scenario of scenarios) {
        const label = scenario.systematic ? systematicName(scenario) : scenario.mandatory ? mandatoryName(scenario) : `${scenario.mode}/seed-${scenario.seed}/${scenario.actions.length}-actions`;
        process.stdout.write(`Approval lifecycle: ${label}\n`);
        try {
            let observedRequests = 0;
            let faultsApplied = 0;
            const execute = async explorer => {
                const result = await executeScenario(scenario, options, {explorer});
                for (const name of result.coverage.concat(result.oracleCoverage)) { coverage.add(name); }
                observedRequests = Math.max(observedRequests, result.systematic?.requests ?? 0);
                faultsApplied = Math.max(faultsApplied, result.systematic?.faultsApplied ?? 0);
                completed += 1;
                if (options.replay) {
                    const directory = options.failureDirectory ? resolve(options.failureDirectory) : dirname(resolve(options.replay));
                    let destination = join(directory, "reproduction.json");
                    if (destination === resolve(options.replay)) { destination = join(directory, "reproduction-result.json"); }
                    await writeFile(destination, JSON.stringify({version: 1, status: "passed", sourceIdentity: scenario.sourceIdentity,
                        reproduction: {sourceIdentity: options.sourceIdentity}, scenario: result.scenario,
                        coverage: result.coverage, oracleCoverage: result.oracleCoverage, effects: result.effects,
                        ...(result.systematic ? {systematic: result.systematic} : {})}, null, 2) + "\n");
                    process.stdout.write(`Replay result: ${destination}\n`);
                }
            };
            if (scenario.systematic && !options.replay) {
                const maximum = options.traceLimit ?? EXPLORATION_BOUNDS[options.systematic].traces;
                if (systematicTraces >= maximum) {
                    throw new LifecycleFailure("exploration-budget", "Systematic run omitted required scenarios", {maximum, systematicTraces, next: label});
                }
                const report = await exploreSchedules(execute, {profile: options.systematic, traceLimit: maximum - systematicTraces});
                systematicTraces += report.completed;
                explorationReports.push({scenario: label, ...report, requests: observedRequests, faultsApplied});
            } else { await execute(null); }
        } catch (error) {
            if (scenario.systematic && options.failureDirectory && !options.replay) {
                const progress = error.exploration;
                await writeFile(join(resolve(options.failureDirectory), "systematic-coverage.json"), JSON.stringify({
                    version: 1, sourceIdentity: options.sourceIdentity, status: "incomplete", profile: options.systematic,
                    traces: systematicTraces + (progress?.completed ?? 0),
                    frontier: progress?.frontier ?? 1, scenario: label, invariant: error.invariant,
                    details: error.details, progress, scenarios: explorationReports,
                }, null, 2) + "\n");
            }
            if (error.artifactPath) {
                process.stderr.write(`Failure artifacts: ${error.artifactPath}\n`);
                await reduceFailure(error, options);
                process.stderr.write(`Replay: Scripts/check_approval_lifecycle.sh --replay ${shellQuote(join(error.artifactPath, "replay.json"))}\n`);
            }
            throw error;
        }
    }
    if (explorationReports.length) {
        const report = {version: 1, sourceIdentity: options.sourceIdentity, status: "complete", profile: options.systematic, traces: systematicTraces,
            frontier: 0, scenarios: explorationReports};
        if (options.failureDirectory) {
            await writeFile(join(resolve(options.failureDirectory), "systematic-coverage.json"), JSON.stringify(report, null, 2) + "\n");
        }
        process.stdout.write(`Systematic approval exploration completed: ${systematicTraces} traces, no unexplored frontier within ${options.systematic} bounds.\n`);
    }
    if (!options.replay) {
        const required = options.mandatory ? ["consent", "signer.before", "signer.after", "broadcast.prepared",
            "broadcast.dispatch", "broadcast.accepted", "process-lock-recovery", "old-process-consent",
            "wallet-revocation-crash", "authentication-cancelled", "revocation-before-signing"] : [];
        if (options.mandatory && options.mode !== "native") { required.push("edited-review-token", "wallet-reconciliation-after-clock-jump"); }
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
