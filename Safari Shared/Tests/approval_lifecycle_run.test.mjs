import assert from "node:assert/strict";
import {once} from "node:events";
import {mkdir, mkdtemp, readFile, rm, writeFile} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import test from "node:test";
import {executeScenario as executeCapturedScenario, main, reduceFailure} from "../../Scripts/approval_lifecycle/run.mjs";
import {LifecycleSession} from "../../Scripts/approval_lifecycle/session.mjs";
import {LifecycleFailure} from "../../Scripts/approval_lifecycle/scheduler.mjs";
import {NativeChild} from "../../Scripts/approval_lifecycle/native_child.mjs";
import {EffectLedger} from "../../Scripts/approval_lifecycle/oracle.mjs";
import {BrowserLifecycle} from "../../Scripts/approval_lifecycle/browser.mjs";
import {deferred} from "./test_helpers.mjs";

const action = kind => ({kind, tab: 0, selector: 0});
const scenario = actions => ({version: 1, seed: 1, mode: "popup", actions});
const sourceIdentity = {version: 1, source: {kind: "vm-snapshot", sha256: "a".repeat(64), commit: "c".repeat(40), fileCount: 7},
    worker: {sha256: "b".repeat(64), bytes: 123}};
const currentIdentity = {...sourceIdentity, source: {...sourceIdentity.source, sha256: "d".repeat(64)},
    worker: {...sourceIdentity.worker, sha256: "e".repeat(64)}};
const executeScenario = (value, options = {}, execution) => executeCapturedScenario(value, {sourceIdentity, ...options}, execution);

function isolateSession(t) {
    t.mock.method(LifecycleSession.prototype, "initialize", async function () { this.ledger = {events: []}; });
    for (const method of ["connect", "pump", "inspect", "quiesce", "close"]) {
        t.mock.method(LifecycleSession.prototype, method, async () => {});
    }
    for (const method of ["request", "check"]) { t.mock.method(LifecycleSession.prototype, method, () => {}); }
}

test("failure replay retains only attempted actions and rejects extending a fixed witness", async t => {
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
    await assert.rejects(executeScenario(replay, {sourceIdentity: currentIdentity}, {capture: false}), error => {
        assert.equal(error.invariant, "replay-schedule");
        assert.deepEqual(error.replayScenario.decisions, replay.decisions);
        assert.deepEqual(error.replayScenario.sourceIdentity, sourceIdentity);
        assert.deepEqual(error.replayScenario.reproduction.sourceIdentity, currentIdentity);
        return true;
    });
    assert.deepEqual(visited, ["deliver", "releaseNative"]);
});

test("a fixed failure can pass on newer source while consuming exactly the saved choices", async t => {
    isolateSession(t);
    let fail = true;
    t.mock.method(LifecycleSession.prototype, "action", async function () {
        this.scheduler.phase = ++this.actionIndex;
        this.decision("release-gate", null);
        if (fail) { throw new LifecycleFailure("broadcast", "Failure after the recorded choice"); }
    });
    let replay;
    await assert.rejects(executeScenario(scenario([action("releaseNative")]), {}, {capture: false}), error => {
        replay = error.replayScenario;
        return error.invariant === "broadcast";
    });
    fail = false;
    const result = await executeScenario(replay, {sourceIdentity: currentIdentity}, {capture: false});
    assert.deepEqual(result.scenario.decisions, replay.decisions);
    assert.deepEqual(result.scenario.faultTargets, replay.faultTargets);
    assert.deepEqual(result.scenario.sourceIdentity, sourceIdentity);
    assert.deepEqual(result.scenario.reproduction.sourceIdentity, currentIdentity);
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
    await assert.rejects(executeScenario(original.scenario, {sourceIdentity: currentIdentity}), error => {
        failure = error;
        return error.invariant === "replay-schedule";
    });
    assert.deepEqual(settings.session.faultTargets, {});
    assert.deepEqual(failure.replayScenario.faultTargets, original.scenario.faultTargets);
    const savedScenario = JSON.parse(await readFile(join(failure.artifactPath, "scenario.json"), "utf8"));
    const savedReplay = JSON.parse(await readFile(join(failure.artifactPath, "replay.json"), "utf8"));
    const savedFailure = JSON.parse(await readFile(join(failure.artifactPath, "failure.json"), "utf8"));
    assert.deepEqual(savedScenario.faultTargets, original.scenario.faultTargets);
    assert.deepEqual(savedReplay.scenario.faultTargets, original.scenario.faultTargets);
    for (const saved of [savedScenario, savedReplay, savedFailure, savedReplay.scenario, savedReplay.originalScenario]) {
        assert.deepEqual(saved.sourceIdentity, sourceIdentity);
        assert.deepEqual(saved.reproduction.sourceIdentity, currentIdentity);
    }
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

test("failure replay retains unconsumed saved fault targets and rejects the early invariant", async t => {
    isolateSession(t);
    t.mock.method(LifecycleSession.prototype, "action", async function () {
        this.actionIndex += 1;
        throw new LifecycleFailure("broadcast", "Failure before later fault actions");
    });
    const drop = {...action("drop"), channel: "native", phase: "reply"};
    const replay = {...scenario([drop, {...drop}]), faultTargets: {0: "attempted", 1: "unattempted"}};
    await assert.rejects(executeScenario(replay, {}, {capture: false}), error => {
        assert.equal(error.replayScenario.actions.length, 2);
        assert.deepEqual(error.replayScenario.faultTargets, replay.faultTargets);
        assert.equal(error.details.observedFailure.invariant, "broadcast");
        return error.invariant === "replay-schedule";
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

test("expected schedule-bound pruning removes scratch state without failure artifacts", async t => {
    isolateSession(t);
    const root = await mkdtemp(join(tmpdir(), "approval-pruning-"));
    t.after(() => rm(root, {recursive: true, force: true}));
    t.mock.method(LifecycleSession.prototype, "initialize", async function () { this.root = root; this.ledger = {events: []}; });
    t.mock.method(LifecycleSession.prototype, "connect", async () => { throw new LifecycleFailure("exploration-bound", "Outside bounds"); });
    const artifacts = t.mock.method(LifecycleSession.prototype, "artifacts", async () => { throw new Error("Pruning is not a failure artifact"); });
    const close = t.mock.method(LifecycleSession.prototype, "close", async () => {});
    const {ScheduleExplorer} = await import("../../Scripts/approval_lifecycle/explorer.mjs");
    const {systematicScenarios} = await import("../../Scripts/approval_lifecycle/systematic.mjs");
    await assert.rejects(executeScenario(systematicScenarios("popup")[0], {}, {explorer: new ScheduleExplorer}),
        error => error.invariant === "exploration-bound" && error.artifactPath === undefined);
    assert.equal(artifacts.mock.callCount(), 0);
    assert.deepEqual(close.mock.calls[0].arguments, [{preserve: false}]);
});

test("exact systematic replay preserves its unmet schedule when enabled actions diverge", async t => {
    isolateSession(t);
    t.mock.method(LifecycleSession.prototype, "connect", async function () {
        await this.systematicExplorer.step([{id: "unexpected", actor: "owner", run: async () => {}}]);
    });
    const {systematicScenarios} = await import("../../Scripts/approval_lifecycle/systematic.mjs");
    const original = {...systematicScenarios("popup")[0], schedule: [
        {enabled: [{id: "expected", actor: "owner", fault: false}], choice: "expected"},
    ]};
    await assert.rejects(executeScenario(original, {}, {capture: false}), error => {
        assert.equal(error.invariant, "replay-schedule");
        assert.deepEqual(error.replayScenario.schedule, original.schedule);
        assert.deepEqual(error.systematicSchedule, []);
        return true;
    });
});


test("an incomplete systematic run persists a failing frontier report", async t => {
    isolateSession(t);
    const root = await mkdtemp(join(tmpdir(), "approval-incomplete-"));
    t.after(() => rm(root, {recursive: true, force: true}));
    t.mock.method(LifecycleSession.prototype, "connect", async () => {
        throw new LifecycleFailure("exploration-budget", "Unfinished decision frontier");
    });
    await assert.rejects(main(["--worker", process.execPath, "--systematic-only", "--mode", "native", "--failure-dir", root]),
        error => error.invariant === "exploration-budget");
    const report = JSON.parse(await readFile(join(root, "systematic-coverage.json"), "utf8"));
    assert.equal(report.status, "incomplete");
    assert.equal(report.invariant, "exploration-budget");
    assert.equal(report.frontier, 1);
    assert.equal(report.traces, 0);
    assert.match(report.scenario, /systematic/);
    assert.deepEqual(report.scenarios, []);
    assert.equal(report.sourceIdentity.source.kind, "vm-snapshot");
    assert.match(report.sourceIdentity.source.sha256, /^[a-f0-9]{64}$/);
    assert.match(report.sourceIdentity.worker.sha256, /^[a-f0-9]{64}$/);
});

test("a successful replay saves current source identity separately from the original witness", async t => {
    isolateSession(t);
    const root = await mkdtemp(join(tmpdir(), "approval-successful-reproduction-"));
    t.after(() => rm(root, {recursive: true, force: true}));
    const path = join(root, "replay.json");
    const original = {version: 1, invariant: "broadcast", scenario: {...scenario([]), sourceIdentity, decisions: [], faultTargets: {}}};
    await writeFile(path, JSON.stringify(original));
    await main(["--worker", process.execPath, "--replay", path, "--failure-dir", root]);
    assert.deepEqual(JSON.parse(await readFile(path, "utf8")), original);
    const report = JSON.parse(await readFile(join(root, "reproduction.json"), "utf8"));
    assert.equal(report.status, "passed");
    assert.deepEqual(report.sourceIdentity, sourceIdentity);
    assert.deepEqual(report.scenario.sourceIdentity, sourceIdentity);
    assert.deepEqual(report.scenario.reproduction, report.reproduction);
    assert.match(report.reproduction.sourceIdentity.source.sha256, /^[a-f0-9]{64}$/);
    assert.match(report.reproduction.sourceIdentity.worker.sha256, /^[a-f0-9]{64}$/);
    assert.notDeepEqual(report.reproduction.sourceIdentity, sourceIdentity);
});

test("a matching failure before the saved decision tail is not an exact reproduction", async t => {
    isolateSession(t);
    t.mock.method(LifecycleSession.prototype, "action", async function () {
        this.scheduler.phase = ++this.actionIndex;
        throw new LifecycleFailure("broadcast", "Failure before the recorded scheduling choice");
    });
    const original = {...scenario([action("deliver"), action("releaseNative")]),
        decisions: [{phase: 1, type: "release-gate", ordinal: 0, choice: null}]};
    await assert.rejects(executeScenario(original, {}, {capture: false}), error => {
        assert.equal(error.invariant, "replay-schedule");
        assert.equal(error.details.observedFailure.invariant, "broadcast");
        assert.deepEqual(error.replayScenario.decisions, original.decisions);
        assert.deepEqual(error.replayScenario.actions, original.actions);
        return true;
    });
});

test("a matching failure before the saved systematic tail is not an exact reproduction", async t => {
    isolateSession(t);
    t.mock.method(LifecycleSession.prototype, "connect", async function () {
        await this.systematicExplorer.step([{id: "first", actor: "owner", run: async () => {
            throw new LifecycleFailure("broadcast", "Failure before the recorded continuation");
        }}]);
    });
    const {systematicScenarios} = await import("../../Scripts/approval_lifecycle/systematic.mjs");
    const original = {...systematicScenarios("popup")[0], schedule: [
        {enabled: [{id: "first", actor: "owner", fault: false}], choice: "first"},
        {enabled: [{id: "second", actor: "owner", fault: false}], choice: "second"},
    ]};
    await assert.rejects(executeScenario(original, {}, {capture: false}), error => {
        assert.equal(error.invariant, "replay-schedule");
        assert.equal(error.details.observedFailure.invariant, "broadcast");
        assert.deepEqual(error.replayScenario.schedule, original.schedule);
        assert.deepEqual(error.systematicSchedule, original.schedule.slice(0, 1));
        return true;
    });
});

test("a matching failure with additional unrecorded decisions is not an exact reproduction", async t => {
    isolateSession(t);
    let continued = false;
    t.mock.method(LifecycleSession.prototype, "action", async function () {
        this.scheduler.phase = ++this.actionIndex;
        this.decision("unexpected", null);
        continued = true;
        throw new LifecycleFailure("broadcast", "Failure after a new scheduling choice");
    });
    const original = {...scenario([action("releaseNative")]), decisions: []};
    await assert.rejects(executeScenario(original, {}, {capture: false}), error =>
        error.invariant === "replay-schedule" && /unrecorded scheduling decision/.test(error.message) &&
        error.replayScenario.decisions.length === 0);
    assert.equal(continued, false);
});

test("an otherwise successful replay rejects an additional scheduling choice", async t => {
    isolateSession(t);
    t.mock.method(LifecycleSession.prototype, "action", async function () {
        this.scheduler.phase = ++this.actionIndex;
        this.decision("unexpected", null);
    });
    const original = {...scenario([action("deliver")]), decisions: [], faultTargets: {}};
    await assert.rejects(executeScenario(original, {}, {capture: false}), error => {
        assert.equal(error.invariant, "replay-schedule");
        assert.deepEqual(error.replayScenario.decisions, []);
        return true;
    });
});

test("an otherwise successful replay rejects an additional applied transport fault", async t => {
    isolateSession(t);
    t.mock.method(LifecycleSession.prototype, "action", async function () {
        this.scheduler.phase = ++this.actionIndex;
        this.faultTargets[this.actionIndex] = "newly-faulted-transport";
    });
    const original = {...scenario([{...action("drop"), channel: "native", phase: "reply"}]), decisions: [], faultTargets: {}};
    await assert.rejects(executeScenario(original, {}, {capture: false}), error => {
        assert.equal(error.invariant, "replay-schedule");
        assert.deepEqual(error.replayScenario.faultTargets, {});
        return true;
    });
});

test("a matching failure with an additional applied transport fault is not an exact reproduction", async t => {
    isolateSession(t);
    t.mock.method(LifecycleSession.prototype, "action", async function () {
        this.scheduler.phase = ++this.actionIndex;
        this.faultTargets[this.actionIndex] = "newly-faulted-transport";
        throw new LifecycleFailure("broadcast", "Failure after a new transport fault");
    });
    const original = {...scenario([{...action("drop"), channel: "native", phase: "reply"}]), decisions: [], faultTargets: {}};
    await assert.rejects(executeScenario(original, {}, {capture: false}), error => {
        assert.equal(error.invariant, "replay-schedule");
        assert.equal(error.details.observedFailure.invariant, "broadcast");
        assert.deepEqual(error.replayScenario.faultTargets, {});
        return true;
    });
});

test("random minimization retains scheduling and fault identity and verifies the reduced witness twice", async t => {
    isolateSession(t);
    const root = await mkdtemp(join(tmpdir(), "approval-reduction-identity-"));
    t.after(() => rm(root, {recursive: true, force: true}));
    const visits = [];
    t.mock.method(LifecycleSession.prototype, "initialize", async function () {
        this.ledger = {events: []};
        visits.push({decisions: structuredClone(this.options.decisions), faultTargets: structuredClone(this.options.faultTargets), actions: []});
        this.visit = visits.at(-1);
    });
    t.mock.method(LifecycleSession.prototype, "action", async function (value) {
        this.scheduler.phase = ++this.actionIndex;
        this.visit.actions.push(value.kind);
        if (value.kind === "drop") {
            this.faultTargets[this.actionIndex] = "captured-target";
            this.decision("transport", null);
        }
        if (value.kind === "releaseNative" && Object.keys(this.faultTargets).length) { throw new LifecycleFailure("broadcast", "Stable failure"); }
    });
    const original = {...scenario([{...action("drop"), channel: "native", phase: "reply"}, action("wake"), action("releaseNative")]),
        sourceIdentity, decisions: [{phase: 0, type: "transport", ordinal: 0, choice: null}], faultTargets: {0: "captured-target"}};
    const failure = new LifecycleFailure("broadcast", "Stable failure");
    failure.replayScenario = original;
    failure.artifactPath = root;
    await reduceFailure(failure, {sourceIdentity: currentIdentity, minimize: true});
    const saved = JSON.parse(await readFile(join(root, "replay.json"), "utf8"));
    assert.deepEqual(saved.scenario.actions.map(value => value.kind), ["drop", "releaseNative"]);
    assert.deepEqual(saved.scenario.decisions, original.decisions);
    assert.deepEqual(saved.scenario.faultTargets, original.faultTargets);
    assert.deepEqual(saved.originalScenario, original);
    assert.deepEqual(saved.sourceIdentity, sourceIdentity);
    assert.deepEqual(saved.scenario.sourceIdentity, sourceIdentity);
    assert.deepEqual(saved.reproduction.sourceIdentity, currentIdentity);
    assert.equal(saved.reproduction.stableReproductions, 2);
    assert.deepEqual(visits.slice(-2).map(value => value.actions), [["drop", "releaseNative"], ["drop", "releaseNative"]]);
    assert.ok(visits.slice(-2).every(value => JSON.stringify(value.decisions) === JSON.stringify(original.decisions) &&
        JSON.stringify(value.faultTargets) === JSON.stringify(original.faultTargets)));
});

test("random minimization removes prefix and middle actions while retaining nested transport and delivery identities", async t => {
    isolateSession(t);
    const root = await mkdtemp(join(tmpdir(), "approval-reduction-phases-"));
    t.after(() => rm(root, {recursive: true, force: true}));
    const visits = [];
    t.mock.method(LifecycleSession.prototype, "initialize", async function () {
        this.ledger = {events: []};
        this.tabs = [{id: 1, profile: {id: null}}];
        this.browser = new BrowserLifecycle({scheduler: this.scheduler, native: async () => ({id: 1}),
            trace: event => this.record(event)});
        this.browser.focus = () => {};
        this.browser.wake = () => {
            void this.browser.nativeMessage({id: null}, "worker", {subject: "getLatestConfiguration", id: 1}, () => true);
        };
        visits.push({actionPhases: this.options.actionPhases, decisions: this.options.decisions, faultTargets: this.options.faultTargets});
    });
    t.mock.method(LifecycleSession.prototype, "check", function () {
        if (this.coverage.has("fault:native:reply:drop") && this.decisions.some(value => value.type === "delivery" && value.choice !== null)) {
            throw new LifecycleFailure("broadcast", "Failure after selected delivery and reply loss");
        }
    });
    t.mock.method(LifecycleSession.prototype, "close", async function () { this.browser.close(); });
    let failure;
    await assert.rejects(executeScenario(scenario([action("focus"), {...action("drop"), channel: "native", phase: "reply"},
        action("focus"), action("wake"), action("focus"), action("deliver")]), {}, {capture: false}), error => {
        failure = error;
        return error.invariant === "broadcast";
    });
    const original = structuredClone(failure.replayScenario);
    assert.match(original.faultTargets[1], /^5\|worker\|native\|reply\|getLatestConfiguration\|3\|worker\|native\|request\|/);
    assert.match(original.decisions[0].choice, /^worker\|message\|3\|worker\|native\|request\|/);
    failure.artifactPath = root;
    await reduceFailure(failure, {sourceIdentity: currentIdentity, minimize: true, timeout: 50});
    const saved = JSON.parse(await readFile(join(root, "replay.json"), "utf8"));
    assert.deepEqual(saved.scenario.actions.map(value => value.kind), ["drop", "wake", "deliver"]);
    assert.deepEqual(saved.scenario.actionPhases, [1, 3, 5]);
    assert.deepEqual(saved.scenario.decisions, original.decisions);
    assert.deepEqual(saved.scenario.faultTargets, {0: original.faultTargets[1]});
    assert.deepEqual(saved.originalScenario, original);
    assert.deepEqual(failure.replayScenario, original);
    assert.equal(saved.reproduction.stableReproductions, 2);
    assert.deepEqual(visits.slice(-2), Array(2).fill({actionPhases: [1, 3, 5], decisions: original.decisions,
        faultTargets: {0: original.faultTargets[1]}}));
});

test("failure capture truncates stable action phases with the attempted actions", async t => {
    isolateSession(t);
    t.mock.method(LifecycleSession.prototype, "initialize", async function () {
        this.ledger = {events: []};
        this.tabs = [];
    });
    t.mock.method(LifecycleSession.prototype, "check", () => { throw new LifecycleFailure("broadcast", "Failure after release choice"); });
    const original = {...scenario([action("releaseNative"), action("releaseNative")]), actionPhases: [4, 9]};
    await assert.rejects(executeScenario(original, {}, {capture: false}), error => {
        assert.deepEqual(error.replayScenario.actionPhases, [4]);
        assert.equal(error.replayScenario.actions.length, 1);
        assert.deepEqual(error.replayScenario.decisions, [{phase: 4, type: "release-gate", ordinal: 0, choice: null}]);
        return error.invariant === "broadcast";
    });
});

test("random minimization keeps the original witness when its second verification does not reproduce", async t => {
    isolateSession(t);
    const root = await mkdtemp(join(tmpdir(), "approval-reduction-unstable-"));
    t.after(() => rm(root, {recursive: true, force: true}));
    let reducedAttempts = 0;
    t.mock.method(LifecycleSession.prototype, "action", async function (value) {
        this.scheduler.phase = ++this.actionIndex;
        if (value.kind !== "releaseNative") { return; }
        if (this.actionIndex === 0 && ++reducedAttempts >= 3) { return; }
        throw new LifecycleFailure("broadcast", "Unstable reduced failure");
    });
    const original = {...scenario([action("wake"), action("releaseNative")]), sourceIdentity, decisions: [], faultTargets: {}};
    const failure = new LifecycleFailure("broadcast", "Original failure");
    failure.replayScenario = original;
    failure.artifactPath = root;
    await reduceFailure(failure, {sourceIdentity: currentIdentity, minimize: true});
    const saved = JSON.parse(await readFile(join(root, "replay.json"), "utf8"));
    assert.equal(reducedAttempts, 3);
    assert.deepEqual(saved.scenario, original);
    assert.equal(saved.reproduction.stableReproductions, 0);
    assert.deepEqual(saved.reproduction.sourceIdentity, currentIdentity);
});
