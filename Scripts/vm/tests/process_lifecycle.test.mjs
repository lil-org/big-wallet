import assert from "node:assert/strict";
import {EventEmitter} from "node:events";
import {readFile} from "node:fs/promises";
import {PassThrough} from "node:stream";
import test from "node:test";
import vm from "node:vm";

const source = await readFile(new URL("../../process_lifecycle.mjs", import.meta.url), "utf8");

function fixture(policy, signalFailure) {
    let now = 0;
    let serial = 0;
    const timers = new Map();
    const observe = vm.runInNewContext(source.replace("export function", "function") + "\nobserveProcess", {
        setTimeout(callback, milliseconds) {
            const id = ++serial;
            timers.set(id, {callback, deadline: now + milliseconds});
            return id;
        },
        clearTimeout(id) { timers.delete(id); },
    });
    const child = new EventEmitter();
    child.pid = 123;
    child.stdout = new PassThrough();
    child.stderr = new PassThrough();
    const signals = [], stops = [], failures = [], exits = [];
    const lifecycle = observe(child, {
        policy, terminationGraceMilliseconds: 10,
        signalGroup(pid, signal) {
            assert.equal(pid, child.pid);
            signals.push(signal);
            if (signalFailure) { throw signalFailure; }
        },
        onStop: reason => stops.push(reason),
        onFailure: (kind, error) => failures.push({kind, error}),
        onExit: () => exits.push(true),
    });
    const tick = milliseconds => {
        const target = now + milliseconds;
        for (;;) {
            const due = [...timers].filter(([, timer]) => timer.deadline <= target)
                .sort((left, right) => left[1].deadline - right[1].deadline)[0];
            if (!due) { break; }
            now = due[1].deadline;
            timers.delete(due[0]);
            due[1].callback();
        }
        now = target;
    };
    return {child, lifecycle, signals, stops, failures, exits, tick, timers};
}

for (const policy of ["vm-command", "vm-finalizer", "safari-command"]) {
    for (const code of [0, 7]) {
        test(`${policy} preserves exit ${code} and removes closed-child observers`, async () => {
            const f = fixture(policy);
            f.child.emit("exit", code, null);
            f.child.emit("close", code, null);
            assert.deepEqual({...await f.lifecycle.exit}, {code, signal: null});
            assert.equal(await f.lifecycle.drainOutput(1), false);
            f.lifecycle.dispose();
            assert.equal(f.child.listenerCount("exit"), 0);
            assert.equal(f.child.listenerCount("error"), 0);
            assert.equal(f.child.listenerCount("close"), 0);
            assert.equal(f.timers.size, 0);
            assert.deepEqual(f.signals, []);
        });
    }
    test(`${policy} settles spawn failures without an exit event`, async () => {
        const f = fixture(policy);
        delete f.child.pid;
        const error = new Error("spawn failed");
        f.child.emit("error", error);
        f.child.emit("close");
        assert.deepEqual({...await f.lifecycle.exit}, {code: null, signal: null});
        assert.deepEqual(f.failures, [{kind: "spawn", error}]);
        assert.equal(await f.lifecycle.drainOutput(1), false);
        f.lifecycle.dispose();
    });
    test(`${policy} preserves its escalation policy after the leader exits`, async () => {
        const f = fixture(policy);
        assert.equal(f.lifecycle.stop("cancel"), true);
        assert.equal(f.lifecycle.stop("timeout"), false);
        f.child.emit("exit", 0, null);
        assert.deepEqual({...await f.lifecycle.exit}, {code: 0, signal: null});
        f.tick(10);
        await f.lifecycle.waitForEscalation();
        assert.deepEqual(f.signals, policy === "vm-finalizer" ? ["SIGTERM"] : ["SIGTERM", "SIGKILL"]);
        assert.deepEqual(f.stops, ["cancel"]);
        assert.equal(f.exits.length, 1);
        f.child.emit("close");
        f.lifecycle.dispose();
    });
    test(`${policy} retains the correct completion source at the hard kill deadline`, async () => {
        const f = fixture(policy);
        let completed = false;
        f.lifecycle.exit.then(() => { completed = true; });
        f.lifecycle.stop("timeout");
        f.tick(10);
        await f.lifecycle.waitForEscalation();
        await Promise.resolve();
        assert.equal(completed, policy === "safari-command");
        assert.deepEqual(f.signals, ["SIGTERM", "SIGKILL"]);
        f.child.emit("exit", null, "SIGKILL");
        f.child.emit("close");
        assert.deepEqual({...await f.lifecycle.exit}, {code: null, signal: "SIGKILL"});
        assert.equal(f.exits.length, 1);
        f.lifecycle.dispose();
    });
}

test("VM policies ignore new stop requests after exit", async () => {
    for (const policy of ["vm-command", "vm-finalizer"]) {
        const f = fixture(policy);
        f.child.emit("exit", 0, null);
        await f.lifecycle.exit;
        assert.equal(f.lifecycle.stop("output failed"), false);
        f.tick(20);
        assert.deepEqual(f.signals, []);
        f.child.emit("close");
        f.lifecycle.dispose();
    }
});

test("Safari preserves late escalation scheduled during pipe drain after disposal", async () => {
    const f = fixture("safari-command");
    f.child.emit("exit", 0, null);
    await f.lifecycle.exit;
    await f.lifecycle.waitForEscalation();
    const draining = f.lifecycle.drainOutput(1);
    assert.equal(f.lifecycle.stop("output failed"), true);
    f.tick(1);
    assert.equal(await draining, true);
    f.lifecycle.dispose();
    assert.deepEqual(f.signals, ["SIGTERM"]);
    f.tick(9);
    assert.deepEqual(f.signals, ["SIGTERM", "SIGKILL"]);
    assert.equal(f.exits.length, 1);
    f.child.emit("close");
    assert.equal(f.child.listenerCount("error"), 0);
});

test("pipe draining is bounded and close can precede exit", async () => {
    const f = fixture("vm-command");
    const draining = f.lifecycle.drainOutput(5);
    f.tick(5);
    assert.equal(await draining, true);
    assert.equal(f.child.stdout.destroyed, true);
    assert.equal(f.child.stderr.destroyed, true);
    f.lifecycle.dispose();
    const error = new Error("late child error");
    f.child.emit("error", error);
    f.child.emit("close");
    await f.lifecycle.exit;
    assert.deepEqual(f.failures, [{kind: "spawn", error}]);
    assert.equal(f.child.listenerCount("error"), 0);
    const other = fixture("vm-command");
    other.child.emit("close");
    assert.equal(await other.lifecycle.drainOutput(5), false);
    other.child.emit("exit", 0, null);
    await other.lifecycle.exit;
    other.lifecycle.dispose();
    assert.equal(other.timers.size, 0);
});

test("missing process groups are harmless while other signal failures reach the adapter", async () => {
    for (const code of ["ESRCH", "EPERM"]) {
        const error = Object.assign(new Error(code), {code});
        const f = fixture("safari-command", error);
        f.lifecycle.stop("timeout");
        f.tick(10);
        await f.lifecycle.exit;
        assert.deepEqual(f.failures, code === "ESRCH" ? [] : [{kind: "signal", error}, {kind: "signal", error}]);
        f.child.emit("close");
        f.lifecycle.dispose();
    }
});
