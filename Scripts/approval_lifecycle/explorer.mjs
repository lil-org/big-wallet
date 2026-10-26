import {isDeepStrictEqual} from "node:util";
import {LifecycleFailure} from "./scheduler.mjs";

export const EXPLORATION_BOUNDS = Object.freeze({
    all: Object.freeze({preemptions: 1, transitions: 64, traces: 256, faults: 1, actors: 2}),
    extended: Object.freeze({preemptions: 2, transitions: 128, traces: 4096, faults: 2, actors: 3}),
});

const identifier = value => typeof value === "string" && value.length > 0 && value.length <= 512 && !/[\u0000-\u001f]/.test(value);

export function validateSchedule(schedule) {
    if (!Array.isArray(schedule) || schedule.length > EXPLORATION_BOUNDS.extended.transitions) {
        throw new Error("Invalid systematic schedule");
    }
    for (const step of schedule) {
        if (!step || !identifier(step.choice) || !Array.isArray(step.enabled) || !step.enabled.length ||
            step.enabled.some(action => !action || !identifier(action.id) || !identifier(action.actor) ||
                typeof action.fault !== "boolean") ||
            new Set(step.enabled.map(action => action.id)).size !== step.enabled.length ||
            !step.enabled.some(action => action.id === step.choice) ||
            !isDeepStrictEqual(step.enabled.map(action => action.id), step.enabled.map(action => action.id).sort())) {
            throw new Error("Invalid systematic schedule step");
        }
    }
    return schedule;
}

function totals(schedule) {
    let previous;
    let preemptions = 0;
    let faults = 0;
    const actors = new Set;
    for (const step of schedule) {
        const action = step.enabled.find(value => value.id === step.choice);
        if (previous !== undefined && previous !== action.actor && step.enabled.some(value => value.actor === previous)) {
            preemptions += 1;
        }
        previous = action.actor;
        actors.add(action.actor);
        if (action.fault) { faults += 1; }
    }
    return {preemptions, faults, actors: actors.size};
}

function withinBounds(schedule, bounds) {
    const used = totals(schedule);
    return schedule.length <= bounds.transitions && used.preemptions <= bounds.preemptions &&
        used.faults <= bounds.faults && used.actors <= bounds.actors;
}

export class ScheduleExplorer {
    constructor({prefix = [], profile = "all", exact = false, onChoice = () => {}} = {}) {
        if (!Object.hasOwn(EXPLORATION_BOUNDS, profile)) { throw new Error("Invalid systematic profile"); }
        this.bounds = EXPLORATION_BOUNDS[profile];
        this.prefix = structuredClone(validateSchedule(prefix));
        if (!withinBounds(this.prefix, this.bounds)) { throw new Error("Saved schedule exceeds its exploration bounds"); }
        this.steps = [];
        this.exact = exact;
        this.onChoice = onChoice;
    }

    async step(actions) {
        if (!Array.isArray(actions) || actions.some(action => typeof action?.run !== "function")) {
            throw new Error("Systematic actions require executable boundaries");
        }
        const enabled = actions.map(({id, actor, fault = false}) => ({id, actor, fault}))
            .sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
        if (!enabled.length) { return false; }
        validateSchedule([{enabled, choice: enabled[0].id}]);
        if (this.steps.length >= this.bounds.transitions) {
            throw new LifecycleFailure("exploration-budget", "Systematic transition budget was exhausted", {bounds: this.bounds, enabled});
        }
        const expected = this.prefix[this.steps.length];
        if (this.exact && !expected) {
            throw new LifecycleFailure("replay-schedule", "Systematic replay reached an unrecorded decision", {enabled, index: this.steps.length});
        }
        if (expected && !isDeepStrictEqual(expected.enabled, enabled)) {
            throw new LifecycleFailure("replay-schedule", "Systematic enabled actions diverged", {expected, enabled, index: this.steps.length});
        }
        const choices = enabled.filter(action => withinBounds([...this.steps, {enabled, choice: action.id}], this.bounds));
        const choice = expected ? choices.find(action => action.id === expected.choice) : choices[0];
        if (!choice) {
            throw new LifecycleFailure("exploration-bound", "No continuation fits the declared schedule bounds", {enabled, expected, bounds: this.bounds});
        }
        const step = {enabled, choice: choice.id};
        this.steps.push(step);
        this.onChoice(structuredClone(step));
        await actions.find(action => action.id === choice.id).run();
        return true;
    }

    finish() {
        if (this.steps.length < this.prefix.length) {
            throw new LifecycleFailure("replay-schedule", "Systematic replay did not consume its saved prefix", {
                expected: this.prefix.length, consumed: this.steps.length,
            });
        }
        return {schedule: structuredClone(this.steps), ...totals(this.steps)};
    }

    alternatives() {
        const prefixes = [];
        for (let index = 0; index < this.steps.length; index += 1) {
            const step = this.steps[index];
            for (const action of step.enabled) {
                if (action.id === step.choice) { continue; }
                const prefix = [...this.steps.slice(0, index), {enabled: step.enabled, choice: action.id}];
                if (withinBounds(prefix, this.bounds)) { prefixes.push(structuredClone(prefix)); }
            }
        }
        return prefixes;
    }
}

export async function exploreSchedules(execute, {profile = "all", traceLimit = EXPLORATION_BOUNDS[profile]?.traces} = {}) {
    const bounds = EXPLORATION_BOUNDS[profile];
    if (!bounds || !Number.isSafeInteger(traceLimit) || traceLimit < 1 || traceLimit > bounds.traces) {
        throw new Error("Invalid systematic trace budget");
    }
    const frontier = [[]];
    const queued = new Set(["[]"]);
    const covered = new Set;
    let completed = 0;
    let pruned = 0;
    while (frontier.length) {
        const prefix = frontier.pop();
        if (covered.has(JSON.stringify(prefix))) { continue; }
        if (completed >= traceLimit) {
            const error = new LifecycleFailure("exploration-budget", "Systematic trace budget left an unexplored frontier", {
                profile, traceLimit, completed, frontier: frontier.length + 1,
            });
            error.exploration = {profile, completed, pruned, frontier: frontier.length + 1, nextPrefix: prefix,
                bounds: {...bounds, traces: traceLimit}};
            throw error;
        }
        const explorer = new ScheduleExplorer({prefix, profile});
        try { await execute(explorer, completed); }
        catch (error) {
            if (error?.invariant !== "exploration-bound") {
                error.systematicSchedule = structuredClone(explorer.steps);
                error.exploration = {profile, completed, pruned, frontier: frontier.length + 1,
                    bounds: {...bounds, traces: traceLimit}};
                throw error;
            }
            pruned += 1;
        }
        const result = explorer.finish();
        completed += 1;
        for (let index = 0; index <= result.schedule.length; index += 1) {
            covered.add(JSON.stringify(result.schedule.slice(0, index)));
        }
        for (const alternative of explorer.alternatives().reverse()) {
            const key = JSON.stringify(alternative);
            if (!queued.has(key) && !covered.has(key)) { frontier.push(alternative); queued.add(key); }
        }
    }
    return {profile, completed, pruned, finished: completed - pruned, frontier: 0, bounds: {...bounds, traces: traceLimit}};
}

export async function minimizeSchedule(original, invariant, replay, maximumAttempts = 200) {
    validateSchedule(original);
    if (!Number.isSafeInteger(maximumAttempts) || maximumAttempts < 0 || maximumAttempts > 200) { throw new Error("Invalid reduction budget"); }
    let schedule = structuredClone(original);
    let attempts = 0;
    for (let length = 0; length < schedule.length && attempts < maximumAttempts; length += 1) {
        const candidate = schedule.slice(0, length);
        attempts += 1;
        try { await replay(candidate); }
        catch (error) {
            if (error instanceof LifecycleFailure && error.invariant === invariant) {
                const observed = validateSchedule(error.systematicSchedule ?? candidate);
                if (observed.length < schedule.length) { schedule = structuredClone(observed); }
            }
        }
    }
    return {schedule, attempts};
}
