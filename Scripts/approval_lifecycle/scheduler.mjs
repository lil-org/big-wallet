import {setImmediate as immediate} from "node:timers/promises";

export class LifecycleFailure extends Error {
    constructor(invariant, message, details = {}) {
        super(`${invariant}: ${message}`);
        this.name = "LifecycleFailure";
        this.invariant = invariant;
        this.details = details;
    }
}

export class Random {
    constructor(seed) { this.state = seed >>> 0 || 0x9e3779b9; }
    next() {
        let value = this.state;
        value ^= value << 13;
        value ^= value >>> 17;
        value ^= value << 5;
        this.state = value >>> 0;
        return this.state / 0x100000000;
    }
    integer(maximum) {
        if (!Number.isSafeInteger(maximum) || maximum <= 0) { throw new Error("Invalid random bound"); }
        return Math.floor(this.next() * maximum);
    }
    pick(values) { return values[this.integer(values.length)]; }
    token(words = 4) {
        return Array.from({length: words}, () => Math.floor(this.next() * 0x100000000).toString(16).padStart(8, "0")).join("");
    }
}

export class Scheduler {
    constructor({now = 1_800_000_000_000, seed = 1, trace = () => {}, replay = null} = {}) {
        this.now = now;
        this.monotonic = 0;
        this.random = new Random(seed);
        this.seed = seed;
        this.randomSources = new Map;
        this.trace = trace;
        this.tasks = new Map;
        this.serial = 0;
        this.executed = 0;
        this.counters = new Map;
        this.phase = "setup";
        this.replay = replay;
        this.replayIndex = 0;
    }
    schedule(callback, delay = 0, owner = "global", kind = "timer", details = {}) {
        if (typeof callback !== "function" || !Number.isFinite(delay)) { throw new Error("Invalid scheduled task"); }
        const prefix = `${owner}|${kind}|${details.transportKey || details.subject || ""}|${Math.max(0, delay)}`;
        const occurrence = (this.counters.get(prefix) || 0) + 1;
        this.counters.set(prefix, occurrence);
        const task = {id: ++this.serial, key: `${prefix}|${occurrence}`, due: this.monotonic + Math.max(0, delay), callback, owner, kind, details, held: false};
        this.tasks.set(task.id, task);
        return task.id;
    }
    cancel(id) { this.tasks.delete(id); }
    retire(owner) {
        for (const [id, task] of this.tasks) { if (task.owner === owner) { this.tasks.delete(id); } }
    }
    pending({owner, kind, ready = false} = {}) {
        return [...this.tasks.values()].filter(task => (!owner || task.owner === owner) &&
            (!kind || task.kind === kind) && (!ready || task.due <= this.monotonic && !task.held))
            .sort((left, right) => left.due - right.due || left.id - right.id);
    }
    hold(id) { const task = this.tasks.get(id); if (task) { task.held = true; } return !!task; }
    release(id) { const task = this.tasks.get(id); if (task) { task.held = false; } return !!task; }
    duplicate(id) {
        const task = this.tasks.get(id);
        if (!task) { return null; }
        return this.schedule(task.callback, task.due - this.monotonic, task.owner, task.kind, {...task.details, duplicateOf: id});
    }
    get expected() { return this.replay?.[this.replayIndex] ?? null; }
    async deliver(id) {
        if (this.replay) {
            const expected = this.expected;
            if (!expected || expected.phase !== this.phase || expected.type !== "schedule") { return false; }
            const matching = [...this.tasks.values()].find(task => task.key === expected.key);
            if (!matching || matching.held || matching.due > this.monotonic) { return false; }
            if (id !== undefined && id !== matching.id) { throw new LifecycleFailure("replay-schedule", "Explicit delivery diverged from the saved schedule", {expected, actual: this.tasks.get(id)?.key}); }
            id = matching.id;
            this.replayIndex += 1;
        } else { id ??= this.pending({ready: true})[0]?.id; }
        const task = this.tasks.get(id);
        if (!task || task.held || task.due > this.monotonic) { return false; }
        this.tasks.delete(id);
        this.trace({type: "schedule", phase: this.phase, key: task.key, task: task.id, owner: task.owner, kind: task.kind, time: this.now, details: task.details});
        this.executed += 1;
        task.callback();
        await this.flush();
        return true;
    }
    async flush() {
        for (let index = 0; index < 4; index += 1) { await Promise.resolve(); }
        await immediate();
    }
    async drain({maximum = 10000} = {}) {
        let count = 0;
        while (await this.deliver()) {
            if (++count >= maximum) { throw new LifecycleFailure("progress", "Immediate browser tasks do not quiesce", {maximum}); }
        }
        await this.flush();
        return count;
    }
    async advance(milliseconds, onClock = async () => {}) {
        if (!Number.isFinite(milliseconds)) { throw new Error("Invalid clock adjustment"); }
        this.setClock(this.now + milliseconds);
        await onClock(this.now);
        await this.drain();
    }
    async until(predicate, {timeout = 10000, maximum = 20000, advance = false, onClock = async () => {}} = {}) {
        const deadline = performance.now() + timeout;
        for (let count = 0; count < maximum; count += 1) {
            if (predicate()) { return; }
            if (performance.now() >= deadline) {
                throw new LifecycleFailure("watchdog", "Browser/native operation did not reach its checkpoint", {pending: this.pending().map(({callback, ...task}) => task)});
            }
            if (await this.deliver()) { continue; }
            await this.flush();
            if (predicate()) { return; }
            if (advance) {
                const next = this.pending().find(task => !task.held);
                if (next) { this.setClock(this.now + Math.max(0, next.due - this.monotonic)); await onClock(this.now); }
            }
        }
        throw new LifecycleFailure("progress", "Browser/native operation exceeded its scheduling budget", {maximum});
    }
    bindings(owner) {
        const scheduler = this;
        const source = name => {
            const key = `${owner}:${name}`;
            if (!this.randomSources.has(key)) {
                let seed = this.seed >>> 0;
                for (const char of key) { seed = Math.imul(seed ^ char.charCodeAt(0), 16777619) >>> 0; }
                this.randomSources.set(key, new Random(seed));
            }
            return this.randomSources.get(key);
        };
        const random = source("crypto");
        const ordinaryRandom = source("math");
        const DateType = class extends Date {
            constructor(...args) { super(...(args.length ? args : [scheduler.now])); }
            static now() { return scheduler.now; }
        };
        return {
            Date: DateType,
            Math: Object.assign(Object.create(Math), {random: () => ordinaryRandom.next()}),
            setTimeout: (callback, delay) => this.schedule(callback, delay, owner),
            clearTimeout: id => this.cancel(id),
            crypto: {
                getRandomValues: values => {
                    for (let index = 0; index < values.length; index += 1) { values[index] = Math.floor(random.next() * 0x100000000); }
                    return values;
                },
                randomUUID: () => {
                    const token = random.token();
                    return `${token.slice(0, 8)}-${token.slice(8, 12)}-4${token.slice(13, 16)}-8${token.slice(17, 20)}-${token.slice(20)}`;
                },
            },
        };
    }
    setClock(value) {
        this.monotonic += Math.max(0, value - this.now);
        this.now = value;
    }
}
