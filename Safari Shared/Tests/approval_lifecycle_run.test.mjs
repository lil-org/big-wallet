import assert from "node:assert/strict";
import {once} from "node:events";
import {mkdir, mkdtemp, readFile, rm} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import test from "node:test";
import {executeScenario} from "../../Scripts/approval_lifecycle/run.mjs";
import {LifecycleSession} from "../../Scripts/approval_lifecycle/session.mjs";
import {LifecycleFailure} from "../../Scripts/approval_lifecycle/scheduler.mjs";
import {NativeChild} from "../../Scripts/approval_lifecycle/native_child.mjs";
import {EffectLedger} from "../../Scripts/approval_lifecycle/oracle.mjs";
import {BrowserLifecycle} from "../../Scripts/approval_lifecycle/browser.mjs";
import {deferred} from "./test_helpers.mjs";

const action = kind => ({kind, tab: 0, selector: 0});
const scenario = actions => ({version: 1, seed: 1, mode: "popup", actions});

function isolateSession(t) {
    t.mock.method(LifecycleSession.prototype, "initialize", async function () { this.ledger = {events: []}; });
    for (const method of ["connect", "pump", "inspect", "quiesce", "close"]) {
        t.mock.method(LifecycleSession.prototype, method, async () => {});
    }
    for (const method of ["request", "check"]) { t.mock.method(LifecycleSession.prototype, method, () => {}); }
}

test("failure replay retains only attempted actions and can continue past a fixed failure", async t => {
    isolateSession(t);
    let fail = true;
    const visited = [];
    t.mock.method(LifecycleSession.prototype, "action", async function (value) {
        this.scheduler.phase = ++this.actionIndex;
        visited.push(value.kind);
        if (value.kind === "deliver") { this.decision("delivery", null); }
        if (value.kind === "releaseNative") {
            if (fail) { throw new LifecycleFailure("broadcast", "Injected failure before the next decision"); }
            this.decision("release-gate", null);
        }
        if (value.kind === "wake") { throw new Error("Unattempted actions must not be part of the failure replay"); }
    });
    const original = scenario([action("deliver"), action("releaseNative"), action("wake")]);
    let replay;
    await assert.rejects(executeScenario(original, {}, {capture: false}), error => {
        replay = error.replayScenario;
        return error.invariant === "broadcast";
    });
    assert.deepEqual(replay.actions, original.actions.slice(0, 2));
    assert.equal(replay.decisions.length, 1);
    assert.equal(original.actions.length, 3);
    fail = false;
    visited.length = 0;
    const result = await executeScenario(replay, {}, {capture: false});
    assert.deepEqual(visited, ["deliver", "releaseNative"]);
    assert.equal(result.scenario.decisions.length, 2);
});

test("a bootstrap failure does not record unattempted generated actions", async t => {
    isolateSession(t);
    t.mock.method(LifecycleSession.prototype, "connect", async () => { throw new LifecycleFailure("coverage", "Bootstrap failed"); });
    await assert.rejects(executeScenario(scenario([action("wake")]), {}, {capture: false}), error =>
        error.invariant === "coverage" && error.replayScenario.actions.length === 0);
});

test("replay cannot pass while a saved scheduling decision remains unconsumed", async t => {
    isolateSession(t);
    const replay = {...scenario([]), decisions: [{phase: 0, type: "delivery", ordinal: 0, choice: null}]};
    await assert.rejects(executeScenario(replay, {}, {capture: false}), error => error.invariant === "replay-schedule");
});

function nativeReplyFaultSession(t) {
    isolateSession(t);
    const settings = {phaseDrift: false, ignoreSavedTarget: false, captureArtifacts: false};
    const roots = [];
    const flights = new WeakMap;
    t.mock.method(LifecycleSession.prototype, "initialize", async function () {
        settings.session = this;
        this.ledger = {events: []};
        if (settings.captureArtifacts) {
            this.root = await mkdtemp(join(tmpdir(), "approval-replay-fault-"));
            roots.push(this.root);
            this.storeRoot = join(this.root, "store");
            await mkdir(this.storeRoot);
            this.ledger = new EffectLedger(join(this.root, "effects.jsonl"));
        }
        const flight = deferred();
        flights.set(this, flight);
        this.browser = new BrowserLifecycle({scheduler: this.scheduler, native: () => flight.promise,
            trace: event => this.record(event)});
    });
    t.mock.method(LifecycleSession.prototype, "action", async function (value) {
        this.scheduler.phase = ++this.actionIndex;
        if (value.kind === "drop") {
            this.browser.addFault({...value, action: value.kind, sourceAction: this.actionIndex,
                target: settings.ignoreSavedTarget ? undefined : this.options.faultTargets?.[this.actionIndex]});
            void this.browser.nativeMessage({id: null}, "worker", {subject: "getLatestConfiguration", id: 1}, () => true);
            await this.scheduler.drain();
        }
        if (value.kind === "wake" || !settings.phaseDrift) { flights.get(this).resolve({id: 1}); }
        await this.scheduler.drain();
    });
    t.mock.method(LifecycleSession.prototype, "quiesce", async function () { this.browser.faults = []; });
    t.mock.method(LifecycleSession.prototype, "close", async function () { this.browser.close(); this.ledger.close?.(); });
    t.after(async () => { for (const root of roots) { await rm(root, {recursive: true, force: true}); } });
    return settings;
}

const replyFaultScenario = channel => scenario([{...action("drop"), channel, phase: "reply"}, action("wake")]);

test("saved native reply fault targets are accepted when replay applies the same transport", async t => {
    nativeReplyFaultSession(t);
    const original = await executeScenario(replyFaultScenario("native"), {}, {capture: false});
    assert.equal(typeof original.scenario.faultTargets[0], "string");
    const replay = await executeScenario(original.scenario, {}, {capture: false});
    assert.deepEqual(replay.scenario.faultTargets, original.scenario.faultTargets);
    assert.ok(replay.coverage.includes("fault:native:reply:drop"));
});

test("reply phase drift rejects replay and preserves unmet fault targets in both saved artifacts", async t => {
    const settings = nativeReplyFaultSession(t);
    const original = await executeScenario(replyFaultScenario("native"), {}, {capture: false});
    settings.phaseDrift = true;
    settings.captureArtifacts = true;
    let failure;
    await assert.rejects(executeScenario(original.scenario, {}), error => {
        failure = error;
        return error.invariant === "replay-schedule";
    });
    assert.deepEqual(settings.session.faultTargets, {});
    assert.deepEqual(failure.replayScenario.faultTargets, original.scenario.faultTargets);
    const savedScenario = JSON.parse(await readFile(join(failure.artifactPath, "scenario.json"), "utf8"));
    const savedReplay = JSON.parse(await readFile(join(failure.artifactPath, "replay.json"), "utf8"));
    assert.deepEqual(savedScenario.faultTargets, original.scenario.faultTargets);
    assert.deepEqual(savedReplay.scenario.faultTargets, original.scenario.faultTargets);
});

test("applying a fault to another transport cannot satisfy a saved target", async t => {
    const settings = nativeReplyFaultSession(t);
    const original = await executeScenario(replyFaultScenario("native"), {}, {capture: false});
    settings.phaseDrift = true;
    settings.ignoreSavedTarget = true;
    await assert.rejects(executeScenario(original.scenario, {}, {capture: false}), error => {
        assert.notEqual(settings.session.faultTargets[0], original.scenario.faultTargets[0]);
        assert.equal(typeof settings.session.faultTargets[0], "string");
        assert.deepEqual(error.replayScenario.faultTargets, original.scenario.faultTargets);
        return error.invariant === "replay-schedule";
    });
});

test("fresh scenarios may finish with unused fault rules", async t => {
    nativeReplyFaultSession(t);
    const result = await executeScenario(replyFaultScenario("page"), {}, {capture: false});
    assert.deepEqual(result.scenario.faultTargets, {});
    assert.equal(result.coverage.includes("fault:page:reply:drop"), false);
});

test("failure replay omits saved fault targets belonging to unattempted actions", async t => {
    isolateSession(t);
    t.mock.method(LifecycleSession.prototype, "action", async function () {
        this.actionIndex += 1;
        throw new LifecycleFailure("broadcast", "Failure before later fault actions");
    });
    const drop = {...action("drop"), channel: "native", phase: "reply"};
    const replay = {...scenario([drop, {...drop}]), faultTargets: {0: "attempted", 1: "unattempted"}};
    await assert.rejects(executeScenario(replay, {}, {capture: false}), error => {
        assert.equal(error.replayScenario.actions.length, 1);
        assert.deepEqual(error.replayScenario.faultTargets, {0: "attempted"});
        return error.invariant === "broadcast";
    });
});

for (const invalid of [false, true]) {
    test(`scenario finalization ${invalid ? "retains a late oracle failure" : "accepts a valid trailing observation"}`, async t => {
        let root, worker;
        t.mock.method(LifecycleSession.prototype, "initialize", async function () {
            root = this.root = await mkdtemp(join(tmpdir(), "approval-finalization-"));
            this.storeRoot = join(root, "store");
            await mkdir(this.storeRoot);
            this.ledger = new EffectLedger(join(root, "effects.jsonl"));
            const source = `
                import readline from 'node:readline';
                const epoch = process.argv[process.argv.indexOf('--epoch') + 1];
                const send = value => process.stdout.write(JSON.stringify({epoch,...value})+'\\n');
                send({kind:'event',sequence:1,event:'ready',gate:'tail',details:{}});
                readline.createInterface({input:process.stdin}).on('line', () => {
                    send(${JSON.stringify(invalid ? {kind: "event", sequence: 2, event: "checkpoint", details: {
                        name: "signer.before", handle: {id: 1, token: "unapproved", profileIdentifier: null}, executionID: "execution",
                    }} : {kind: "event", sequence: 2, event: "observation", details: {}})});
                    process.stderr.write('written\\n');
                });
            `;
            worker = new NativeChild({executable: process.execPath, extraArguments: ["--input-type=module", "-e", source, "--"],
                role: "bridge", root, epoch: "bridge-1", mode: "popup", timeout: 3000,
                onEvent: (event, child) => this.nativeEvent(event, child)});
            this.children.set("bridge", worker);
            await worker.waitEvent(event => event.event === "ready");
            worker.process.stdout.pause();
            const written = once(worker.process.stderr, "data");
            worker.release("tail");
            await written;
            const kill = worker.process.kill.bind(worker.process);
            t.mock.method(worker.process, "kill", signal => {
                const result = kill(signal);
                worker.process.stdout.resume();
                return result;
            });
        });
        for (const method of ["connect", "pump", "inspect", "quiesce"]) {
            t.mock.method(LifecycleSession.prototype, method, async () => {});
        }
        t.mock.method(LifecycleSession.prototype, "request", () => {});
        t.after(async () => {
            worker?.process.stdout.resume();
            await worker?.close();
            if (root) { await rm(root, {recursive: true, force: true}); }
        });
        if (invalid) {
            let failure;
            await assert.rejects(executeScenario(scenario([]), {}), error => { failure = error; return error.invariant === "consent"; });
            const saved = JSON.parse(await readFile(join(failure.artifactPath, "failure.json"), "utf8"));
            assert.equal(saved.invariant, "consent");
            assert.equal(JSON.parse(await readFile(join(failure.artifactPath, "replay.json"), "utf8")).invariant, "consent");
        } else { assert.equal((await executeScenario(scenario([]), {})).effects, 1); }
        assert.equal(worker.exited, true);
    });
}
