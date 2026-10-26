import {Random, LifecycleFailure} from "./scheduler.mjs";

export const profiles = ["00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000002"];
export const origins = ["https://one.lifecycle.invalid", "https://two.lifecycle.invalid"];
export const actionKinds = Object.freeze([
    "request", "holdNative", "approve", "reject", "retry", "editFees", "cancelAuthentication", "closePopup", "openPopup", "navigate", "replaceDocument",
    "disconnect", "removeAccount", "restoreAccount", "changeNetwork", "expire", "clockBackward", "delay", "drop", "duplicate", "deliver",
    "restartWorker", "restartNative", "compete", "failPersistence", "staleReview", "staleConsent", "wake", "focus", "releaseNative",
]);
export const mandatoryCheckpoints = Object.freeze([
    "admission.after", "receipt.after", "claim.after", "authorize.after", "signer.before", "signer.after", "broadcast.prepared",
    "persistence.write.before", "persistence.write.after", "persistence.fileSync.before", "persistence.fileSync.after",
    "persistence.rename.before", "persistence.rename.after", "persistence.directorySync.before", "persistence.directorySync.after",
    "persistence.finalSync.before", "persistence.finalSync.after", "completion.after", "delivery.after", "acknowledgement.after", "revocation.after",
    "persistence.read.before", "persistence.read.after", "persistence.stat.before", "persistence.stat.after",
]);

export function generateScenario({seed = 1, steps = 64, mode = "native"} = {}) {
    const random = new Random(seed);
    const actions = [];
    const requests = ["connect", "message", "transaction", "broadcast", "addChain", "switchAccount"];
    for (let index = 0; index < steps; index += 1) {
        const kind = index < actionKinds.length ? actionKinds[(index + seed) % actionKinds.length] : random.pick(actionKinds);
        const tab = random.integer(4);
        const action = {kind, tab, selector: random.integer(1000000)};
        if (kind === "request") { action.provider = random.pick(["ethereum", "solana"]); action.method = random.pick(requests); }
        if (kind === "holdNative") {
            action.provider = random.pick(["ethereum", "solana"]);
            action.checkpoint = random.pick(["authentication.before", "signer.before", "signer.after", "broadcast.prepared"]);
        }
        if (["delay", "drop", "duplicate"].includes(kind)) {
            action.channel = random.pick(kind === "drop" ? ["native", "runtime", "tab"] : ["native", "runtime", "page", "tab"]);
            action.phase = random.pick(["request", "reply"]);
            action.delay = random.pick([1, 500, 5001, 20001]);
        }
        if (kind === "restartNative") { action.role = mode === "popup" ? "bridge" : random.pick(["bridge", "approval"]); }
        if (kind === "failPersistence") {
            action.checkpoint = random.pick(["persistence.read.before", "persistence.stat.before", "persistence.write.before", "persistence.fileSync.before", "persistence.rename.after", "persistence.directorySync.after"]);
            action.role = mode === "popup" ? "bridge" : random.pick(["bridge", "approval"]);
            action.partialWriteBytes = random.pick([0, 1, 17]);
        }
        if (kind === "expire") { action.milliseconds = random.pick([900001, 180001, 3600001]); }
        if (kind === "clockBackward") { action.milliseconds = -random.pick([1, 30001, 900001]); }
        actions.push(action);
    }
    return {version: 1, seed, mode, actions};
}

export function validateScenario(scenario) {
    if (scenario?.version !== 1 || !Number.isSafeInteger(scenario.seed) || scenario.seed < 0 || scenario.seed > 0xffffffff || !["native", "popup"].includes(scenario.mode) ||
        !Array.isArray(scenario.actions) || scenario.actions.length > 10000) {
        throw new Error("Invalid approval lifecycle replay scenario");
    }
    if (scenario.actionPhases !== undefined && (!Array.isArray(scenario.actionPhases) || scenario.actionPhases.length !== scenario.actions.length ||
        Array.from(scenario.actionPhases).some((phase, index) => !Number.isSafeInteger(phase) || phase < 0 || index > 0 && phase <= scenario.actionPhases[index - 1]))) {
        throw new Error("Invalid approval lifecycle action phases");
    }
    for (const action of scenario.actions) {
        if (!action || !actionKinds.includes(action.kind) || !Number.isInteger(action.tab) || action.tab < 0 || action.tab > 3 ||
            !Number.isSafeInteger(action.selector) || action.selector < 0) {
            throw new Error("Invalid approval lifecycle replay action");
        }
        if (action.kind === "request" && (!["ethereum", "solana"].includes(action.provider) ||
            !["connect", "message", "transaction", "broadcast", "addChain", "switchAccount"].includes(action.method))) { throw new Error("Invalid request action"); }
        if (action.kind === "holdNative" && (!["ethereum", "solana"].includes(action.provider) ||
            !["authentication.before", "signer.before", "signer.after", "broadcast.prepared"].includes(action.checkpoint))) { throw new Error("Invalid native gate action"); }
        if (["expire", "clockBackward"].includes(action.kind) && (!Number.isFinite(action.milliseconds) ||
            (action.kind === "expire" ? action.milliseconds <= 0 : action.milliseconds >= 0))) { throw new Error("Invalid clock action"); }
        if (["delay", "drop", "duplicate"].includes(action.kind) &&
            (!["native", "runtime", "page", "tab"].includes(action.channel) || !["request", "reply"].includes(action.phase) ||
                action.kind === "delay" && (!Number.isFinite(action.delay) || action.delay < 0))) { throw new Error("Invalid transport fault"); }
        if (["restartNative", "failPersistence"].includes(action.kind) &&
            (!["bridge", "approval"].includes(action.role) || scenario.mode === "popup" && action.role !== "bridge")) { throw new Error("Invalid native role"); }
        if (action.kind === "failPersistence" && (!mandatoryCheckpoints.includes(action.checkpoint) ||
            !action.checkpoint.startsWith("persistence.") || !Number.isSafeInteger(action.partialWriteBytes) || action.partialWriteBytes < 0)) { throw new Error("Invalid persistence fault"); }
    }
    return scenario;
}

function removeActions(scenario, offset, width) {
    const phases = scenario.actionPhases ?? scenario.actions.map((_, index) => index);
    const removedPhases = new Set(phases.slice(offset, offset + width));
    const indices = scenario.actions.map((_, index) => index).filter(index => index < offset || index >= offset + width);
    const candidate = {...scenario, actions: indices.map(index => scenario.actions[index]), actionPhases: indices.map(index => phases[index])};
    if (scenario.decisions !== undefined) {
        candidate.decisions = scenario.decisions.filter(decision => !removedPhases.has(decision.phase));
    }
    if (scenario.faultTargets !== undefined) {
        candidate.faultTargets = Object.fromEntries(indices.flatMap((index, reducedIndex) =>
            Object.hasOwn(scenario.faultTargets, index) ? [[reducedIndex, scenario.faultTargets[index]]] : []));
    }
    return candidate;
}

export async function minimizeScenario(original, invariant, replay, maximumAttempts = 200) {
    if (!Number.isSafeInteger(maximumAttempts) || maximumAttempts < 0 || maximumAttempts > 200) { throw new Error("Invalid minimization budget"); }
    let attempts = 0;
    let current = structuredClone(original);
    const failsSame = async candidate => {
        if (attempts >= maximumAttempts) { return false; }
        attempts += 1;
        try { await replay(candidate); return false; }
        catch (error) { return error instanceof LifecycleFailure && error.invariant === invariant; }
    };
    let width = Math.max(1, Math.floor(current.actions.length / 2));
    while (width >= 1 && attempts < maximumAttempts) {
        let changed = false;
        for (let offset = 0; offset < current.actions.length && attempts < maximumAttempts; offset += width) {
            const candidate = removeActions(current, offset, width);
            if (await failsSame(candidate)) { current = candidate; changed = true; break; }
        }
        if (!changed) { width = Math.floor(width / 2); }
    }
    for (let index = 0; index < current.actions.length && attempts < maximumAttempts; index += 1) {
        const action = current.actions[index];
        for (const field of ["selector", "delay"]) {
            if (typeof action[field] !== "number" || action[field] === 0) { continue; }
            const candidate = structuredClone(current);
            candidate.actions[index][field] = 0;
            if (await failsSame(candidate)) { current = candidate; }
        }
    }
    return {scenario: current, attempts};
}

export function parseOptions(arguments_) {
    const options = {seed: 1, sequences: 32, steps: 64, mode: "alternate", timeout: 15000, minimize: true, mandatory: true, systematic: "all"};
    let soak = false;
    const specified = new Set;
    for (let index = 0; index < arguments_.length; index += 1) {
        const flag = arguments_[index];
        if (flag === "--soak") { soak = true; continue; }
        if (flag === "--help") { options.help = true; continue; }
        if (flag === "--no-minimize") { options.minimize = false; continue; }
        if (flag === "--random-only") { options.mandatory = false; continue; }
        if (flag === "--systematic-only") { options.systematicOnly = true; continue; }
        const names = {"--worker": "worker", "--seed": "seed", "--sequences": "sequences", "--steps": "steps", "--mode": "mode",
            "--timeout-ms": "timeout", "--replay": "replay", "--failure-dir": "failureDirectory", "--scratch-dir": "scratchDirectory",
            "--systematic": "systematic", "--trace-limit": "traceLimit"};
        const name = names[flag];
        const value = arguments_[++index];
        if (!name || value === undefined || value.startsWith("--")) { throw new Error(`Invalid argument ${flag}`); }
        specified.add(name);
        if (["seed", "sequences", "steps", "timeout", "traceLimit"].includes(name)) {
            const number = Number(value);
            const maximum = name === "seed" ? 0xffffffff : name === "sequences" ? 1000 : name === "steps" ? 10000 : name === "traceLimit" ? 4096 : 120000;
            if (!/^(?:0x[0-9a-f]+|[0-9]+)$/i.test(value) || !Number.isSafeInteger(number) || number < (name === "seed" ? 0 : 1) || number > maximum) {
                throw new Error(`Invalid value for ${flag}`);
            }
            options[name] = number;
        } else { options[name] = value; }
    }
    if (soak) { if (!specified.has("sequences")) { options.sequences = 1000; } if (!specified.has("steps")) { options.steps = 200; } }
    if (!["all", "extended", "off"].includes(options.systematic)) { throw new Error("Invalid systematic profile"); }
    if (!options.mandatory) {
        if (options.systematicOnly) { throw new Error("--random-only and --systematic-only cannot be combined"); }
        options.systematic = "off";
    }
    if (options.systematicOnly) {
        if (options.systematic === "off") { throw new Error("Systematic-only runs require an exploration profile"); }
        options.mandatory = false;
        options.sequences = 0;
    }
    if (options.traceLimit !== undefined && (options.systematic === "off" || options.systematic === "all" && options.traceLimit > 256)) {
        throw new Error("Trace limit exceeds the selected systematic profile");
    }
    if (!["alternate", "native", "popup"].includes(options.mode)) { throw new Error("Invalid approval surface"); }
    if (!options.help && !options.worker) { throw new Error("--worker is required"); }
    return options;
}
