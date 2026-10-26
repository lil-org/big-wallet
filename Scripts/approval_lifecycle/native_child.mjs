import {spawn} from "node:child_process";
import {LifecycleFailure} from "./scheduler.mjs";

export class NativeChild {
    constructor({executable, role, root, epoch, mode, timeout = 10000, trace = () => {}, onEvent = () => {}, extraArguments = []}) {
        this.role = role;
        this.epoch = epoch;
        this.timeout = timeout;
        this.trace = trace;
        this.onEvent = onEvent;
        this.pending = new Map;
        this.waiters = new Set;
        this.events = [];
        this.gates = new Set;
        this.serial = 0;
        this.sequence = 0;
        this.eventWork = new Map;
        this.stderr = "";
        this.output = "";
        this.failure = null;
        this.expectedExit = false;
        this.expectedSignal = null;
        this.exited = false;
        this.process = spawn(executable, [...extraArguments, "--role", role, "--root", root, "--epoch", epoch, "--mode", mode], {stdio: ["pipe", "pipe", "pipe"]});
        this.pid = this.process.pid;
        this.process.stdout.setEncoding("utf8");
        this.process.stdout.on("data", chunk => this.receive(chunk));
        this.process.stderr.on("data", chunk => { this.stderr = (this.stderr + String(chunk)).slice(-65536); });
        this.process.on("error", error => this.fail("process", error.message));
        this.process.stdin.on("error", error => { if (!this.expectedExit) { this.fail("process", error.message); } });
        this.exit = new Promise(resolve => this.process.on("close", (code, signal) => {
            this.exited = true;
            if (!this.expectedExit || this.output.length && !(this.expectedSignal === "SIGKILL" && signal === "SIGKILL")) {
                this.fail("process", "Native worker exited unexpectedly", {code, signal, partialOutput: this.output});
            }
            if (this.expectedSignal === "SIGKILL" && signal === "SIGKILL") { this.output = ""; }
            const error = this.failure || new LifecycleFailure("process-restarted", "Native process incarnation ended", {role, epoch, code, signal});
            for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
            this.pending.clear();
            for (const waiter of this.waiters) { clearTimeout(waiter.timer); waiter.reject(error); }
            this.waiters.clear();
            resolve({code, signal});
        }));
    }
    fail(invariant, message, details = {}) {
        this.failure ??= new LifecycleFailure(invariant, message, {role: this.role, epoch: this.epoch, stderr: this.stderr, ...details});
        for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(this.failure); }
        this.pending.clear();
        for (const waiter of this.waiters) { clearTimeout(waiter.timer); waiter.reject(this.failure); }
        this.waiters.clear();
        if (!this.exited) { this.process.kill("SIGKILL"); }
        return this.failure;
    }
    receive(chunk) {
        this.output += chunk;
        if (this.output.length > 16 * 1024 * 1024) { this.fail("protocol", "Native output exceeded 16 MiB"); return; }
        let boundary;
        while ((boundary = this.output.indexOf("\n")) >= 0) {
            const line = this.output.slice(0, boundary);
            this.output = this.output.slice(boundary + 1);
            if (this.failure) { continue; }
            try { this.message(JSON.parse(line)); }
            catch (error) { this.fail("protocol", error.message, {line: line.slice(0, 1000)}); }
        }
    }
    message(message) {
        if (!message || message.epoch !== this.epoch) { throw new Error("Native response has the wrong process epoch"); }
        this.trace({type: "native-in", role: this.role, ...message});
        if (message.kind === "reply") {
            const pending = this.pending.get(message.id);
            if (!pending || typeof message.ok !== "boolean") { throw new Error("Unknown, duplicate, or malformed native reply"); }
            this.pending.delete(message.id);
            clearTimeout(pending.timer);
            if (message.ok) { pending.resolve(message.result); }
            else {
                const error = new Error(typeof message.error === "string" ? message.error : JSON.stringify(message.error));
                error.native = true;
                error.details = message.error;
                pending.reject(error);
            }
            return;
        }
        if (message.kind !== "event" || typeof message.event !== "string" || !Number.isSafeInteger(message.sequence) || message.sequence <= this.sequence) {
            throw new Error("Malformed or out-of-order native event");
        }
        this.sequence = message.sequence;
        if (message.event === "watchdog") {
            this.events.push(message);
            this.fail("watchdog", "Native checkpoint acknowledgement timed out", message.details);
            return;
        }
        if (message.event === "gateRetired") {
            if (typeof message.details?.gate !== "string") { throw new Error("Malformed gate retirement"); }
            this.gates.delete(message.details.gate);
        }
        if (message.gate !== undefined) {
            if (typeof message.gate !== "string" || this.gates.has(message.gate)) { throw new Error("Invalid or duplicate native gate"); }
            this.gates.add(message.gate);
        }
        this.events.push(message);
        for (const waiter of [...this.waiters]) {
            if (waiter.predicate(message)) { this.waiters.delete(waiter); clearTimeout(waiter.timer); waiter.resolve(message); }
        }
        const work = Promise.resolve(this.onEvent(message, this)).catch(error => {
            if (this.expectedExit && error?.invariant === "process-restarted") { return; }
            this.fail(error.invariant || "oracle", error.message, error.details);
        }).finally(() => this.eventWork.delete(message.sequence));
        this.eventWork.set(message.sequence, {event: message.event, work});
    }
    write(message) {
        if (this.failure) { throw this.failure; }
        if (this.exited || this.expectedExit) { throw new LifecycleFailure("process-restarted", "Native process is no longer available", {epoch: this.epoch}); }
        this.trace({type: "native-out", role: this.role, ...message});
        this.process.stdin.write(JSON.stringify(message) + "\n");
    }
    command(operation, payload = {}, options = {}) {
        return this.request("command", operation, payload, options);
    }
    control(operation, payload = {}, options = {}) {
        return this.request("control", operation, payload, options);
    }
    request(kind, operation, payload, {timeout = this.timeout, label} = {}) {
        if (this.failure) { return Promise.reject(this.failure); }
        const id = ++this.serial;
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => this.fail("watchdog", "Native control/message timed out", {id, operation}), timeout);
            this.pending.set(id, {resolve, reject, timer, operation});
            try { this.write({kind, id, epoch: this.epoch, operation, payload, ...(label === undefined ? {} : {label})}); }
            catch (error) { this.pending.delete(id); clearTimeout(timer); reject(error); }
        });
    }
    async fence() {
        const snapshot = await this.control("fence");
        if (!snapshot || !Number.isSafeInteger(snapshot.sequence) || snapshot.sequence < 0 || snapshot.sequence > this.sequence ||
            !Array.isArray(snapshot.tasks) || !Array.isArray(snapshot.gates)) {
            throw this.fail("protocol", "Malformed native control fence", {snapshot});
        }
        const observed = [...this.eventWork].filter(([sequence, value]) => sequence <= snapshot.sequence &&
            value.event !== "rpc" && value.event !== "launch");
        await Promise.all(observed.map(([, value]) => value.work));
        if (this.failure) { throw this.failure; }
        return {...snapshot, pendingEvents: [...this.eventWork].filter(([sequence]) => sequence <= snapshot.sequence)
            .map(([sequence, value]) => ({sequence, event: value.event}))};
    }
    async cancelTask(taskID) {
        if (typeof taskID !== "string" || !taskID.length) { throw new Error("A tracked native task is required"); }
        const result = await this.control("cancel", {taskID});
        if (result?.taskID !== taskID || typeof result.cancelled !== "boolean") {
            throw this.fail("protocol", "Malformed task cancellation acknowledgement", {result});
        }
        return result.cancelled;
    }
    release(gate, value = null) {
        if (!this.gates.delete(gate)) { throw new LifecycleFailure("protocol", "Releasing an unknown native gate", {gate, epoch: this.epoch}); }
        this.write({kind: "release", epoch: this.epoch, gate, value});
    }
    waitEvent(predicate, {after = 0, timeout = this.timeout} = {}) {
        if (this.failure) { return Promise.reject(this.failure); }
        const found = this.events.find(event => event.sequence > after && predicate(event));
        if (found) { return Promise.resolve(found); }
        return new Promise((resolve, reject) => {
            const waiter = {predicate: event => event.sequence > after && predicate(event), resolve, reject};
            waiter.timer = setTimeout(() => {
                this.waiters.delete(waiter);
                reject(this.fail("watchdog", "Native checkpoint was not reached", {after}));
            }, timeout);
            this.waiters.add(waiter);
        });
    }
    async kill() {
        if (this.exited) { throw this.failure || new LifecycleFailure("process", "Cannot crash an exited worker"); }
        this.expectedExit = true;
        this.expectedSignal = "SIGKILL";
        this.trace({type: "kill", role: this.role, epoch: this.epoch, pid: this.pid, signal: "SIGKILL"});
        if (!this.process.kill("SIGKILL")) { throw this.fail("process", "SIGKILL could not be delivered to owned child"); }
        const result = await this.waitExit();
        if (this.failure) { throw this.failure; }
        if (result.signal !== "SIGKILL") { throw new LifecycleFailure("process", "Crash worker did not exit by SIGKILL", result); }
        return result;
    }
    async waitExit() {
        let timer;
        try {
            return await Promise.race([this.exit, new Promise((_, reject) => {
                timer = setTimeout(() => reject(this.fail("watchdog", "Native process could not be reaped")), this.timeout);
            })]);
        } finally { clearTimeout(timer); }
    }
    async close() {
        if (this.exited) { return; }
        if (this.failure) { this.expectedExit = true; this.process.kill("SIGKILL"); await this.waitExit(); return; }
        this.expectedExit = true;
        this.process.stdin.end();
        const result = await this.waitExit();
        if (result.code !== 0) { throw new LifecycleFailure("process", "Native worker did not shut down cleanly", result); }
    }
}
