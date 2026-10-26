import assert from "node:assert/strict";
import test from "node:test";
import {EXPLORATION_BOUNDS, ScheduleExplorer, exploreSchedules, minimizeSchedule, validateSchedule} from "../../Scripts/approval_lifecycle/explorer.mjs";
import {LifecycleFailure} from "../../Scripts/approval_lifecycle/scheduler.mjs";
import {systematicScenarios, systematicWorkload, validateSystematicScenario} from "../../Scripts/approval_lifecycle/systematic.mjs";
import {parseOptions} from "../../Scripts/approval_lifecycle/scenarios.mjs";

const action = (id, actor = id, run = async () => {}, fault = false) => ({id, actor, run, fault});
const savedStep = (choice, enabled) => ({choice, enabled: enabled.map(({id, actor, fault = false}) => ({id, actor, fault}))
    .sort((left, right) => left.id < right.id ? -1 : left.id > right.id ? 1 : 0)});

async function twoActors(explorer) {
    const next = {a: 0, b: 0};
    const order = [];
    while (next.a < 2 || next.b < 2) {
        await explorer.step(Object.keys(next).filter(actor => next[actor] < 2).map(actor =>
            action(`${actor}:${next[actor]}`, actor, async () => { order.push(actor); next[actor] += 1; })));
    }
    return order.join("");
}

for (const [profile, expected] of [
    ["all", ["aabb", "abba", "baab", "bbaa"]],
    ["extended", ["aabb", "abab", "abba", "baab", "baba", "bbaa"]],
]) {
    test(`${profile} exhausts every legal two-actor ordering exactly once`, async () => {
        const observed = [];
        const report = await exploreSchedules(async explorer => { observed.push(await twoActors(explorer)); }, {profile});
        assert.deepEqual(observed.sort(), expected);
        assert.equal(new Set(observed).size, expected.length);
        assert.equal(report.completed, expected.length);
        assert.equal(report.finished, expected.length);
        assert.equal(report.pruned, 0);
        assert.equal(report.frontier, 0);
    });
}

test("exploration discovers a race behind a nondefault ordering and records its exact decision", async () => {
    await assert.rejects(exploreSchedules(async explorer => {
        const order = await twoActors(explorer);
        if (order === "baab") { throw new LifecycleFailure("ownership", "Reproduced race"); }
    }), error => {
        assert.equal(error.invariant, "ownership");
        assert.equal(error.systematicSchedule.map(step => step.choice[0]).join(""), "baab");
        return true;
    });
});

test("a trace limit that leaves a frontier fails instead of claiming bounded completion", async () => {
    await assert.rejects(exploreSchedules(twoActors, {traceLimit: 1}), error => {
        assert.equal(error.invariant, "exploration-budget");
        assert.equal(error.details.completed, 1);
        assert.ok(error.details.frontier > 0);
        assert.equal(error.exploration.frontier, error.details.frontier);
        assert.equal(error.exploration.completed, 1);
        assert.ok(error.exploration.nextPrefix.length > 0);
        return true;
    });
});

test("fault and actor bounds prune only their illegal continuations", async () => {
    for (const actorBound of [false, true]) {
        const run = async explorer => {
            const count = actorBound ? 3 : 2;
            for (let index = 0; index < count; index += 1) {
                await explorer.step([action(`step:${index}`, actorBound ? `actor:${index}` : "actor", async () => {}, !actorBound)]);
            }
        };
        const limited = await exploreSchedules(run, {profile: "all"});
        assert.equal(limited.pruned, 1);
        assert.equal(limited.finished, 0);
        assert.equal(limited.frontier, 0);
        const extended = await exploreSchedules(run, {profile: "extended"});
        assert.equal(extended.pruned, 0);
        assert.equal(extended.finished, 1);
    }
});

test("transition exhaustion is an incomplete exploration failure", async () => {
    await assert.rejects(exploreSchedules(async explorer => {
        for (let index = 0; index <= EXPLORATION_BOUNDS.all.transitions; index += 1) {
            await explorer.step([action(`step:${index}`, "actor")]);
        }
    }), error => error.invariant === "exploration-budget" && error.systematicSchedule.length === EXPLORATION_BOUNDS.all.transitions);
});

test("exact replay reproduces decisions without relying on input action order", async () => {
    const initial = new ScheduleExplorer;
    const order = await twoActors(initial);
    const schedule = initial.finish().schedule;
    const replay = new ScheduleExplorer({prefix: schedule, exact: true});
    assert.equal(await twoActors(replay), order);
    assert.deepEqual(replay.finish(), initial.finish());
    const reverse = new ScheduleExplorer({prefix: [savedStep("b", [action("a"), action("b")])], exact: true});
    let selected;
    await reverse.step([action("b", "b", async () => { selected = "b"; }), action("a")]);
    assert.equal(selected, "b");
    reverse.finish();
});

test("exact replay rejects changed enablement, actors, fault flags, added and omitted decisions", async () => {
    const enabled = [action("a", "owner"), action("b", "other", async () => {}, true)];
    const prefix = [savedStep("a", enabled)];
    for (const changed of [
        [enabled[0]],
        [...enabled, action("c")],
        [action("a", "different"), enabled[1]],
        [enabled[0], action("b", "other")],
    ]) {
        const replay = new ScheduleExplorer({prefix, exact: true});
        await assert.rejects(replay.step(changed), error => error.invariant === "replay-schedule");
        assert.equal(replay.steps.length, 0);
    }
    const exhausted = new ScheduleExplorer({prefix, exact: true});
    await exhausted.step(enabled);
    await assert.rejects(exhausted.step([action("next", "owner")]), error => error.invariant === "replay-schedule");
    const omitted = new ScheduleExplorer({prefix, exact: true});
    assert.throws(() => omitted.finish(), error => error.invariant === "replay-schedule");
    const empty = new ScheduleExplorer({exact: true});
    await assert.rejects(empty.step([action("unexpected")]), error => error.invariant === "replay-schedule");
    assert.equal(await empty.step([]), false);
});

test("exploration prefixes may continue while recorded replay remains exact", async () => {
    const prefix = [savedStep("a", [action("a", "owner")])];
    const explorer = new ScheduleExplorer({prefix});
    await explorer.step([action("a", "owner")]);
    await explorer.step([action("b", "owner")]);
    assert.equal(explorer.finish().schedule.length, 2);
    assert.equal(prefix.length, 1);
});

test("saved schedules reject malformed or over-bound action metadata", () => {
    const step = savedStep("a", [action("a")]);
    for (const schedule of [null, {}, [{...step, choice: "missing"}], [{...step, enabled: []}],
        [{...step, enabled: [...step.enabled, ...step.enabled]}],
        [{...step, enabled: [{id: "a", actor: "actor", fault: 1}]}],
        [{...step, enabled: [{id: "a", actor: "bad\nactor", fault: false}]}],
        [{...step, enabled: [{id: "b", actor: "b", fault: false}, ...step.enabled]}]]) {
        assert.throws(() => validateSchedule(schedule));
    }
    const faults = [0, 1].map(index => savedStep(`fault:${index}`, [action(`fault:${index}`, "fault", async () => {}, true)]));
    assert.throws(() => new ScheduleExplorer({prefix: faults}), /bounds/);
    assert.doesNotThrow(() => new ScheduleExplorer({prefix: faults, profile: "extended"}));
    assert.throws(() => new ScheduleExplorer({profile: "unknown"}));
});

test("reduction retains only a smaller observed trace with the same invariant", async () => {
    const original = [0, 1, 2, 3].map(index => savedStep(`step:${index}`, [action(`step:${index}`, "owner")]));
    const candidates = [];
    const result = await minimizeSchedule(original, "ownership", async prefix => {
        candidates.push(prefix.length);
        const error = new LifecycleFailure(prefix.length === 0 ? "replay-schedule" : "ownership", "Injected");
        error.systematicSchedule = original.slice(0, 2);
        throw error;
    });
    assert.deepEqual(result.schedule, original.slice(0, 2));
    assert.deepEqual(candidates, [0, 1]);
    assert.equal(result.attempts, 2);
    assert.equal(original.length, 4);
    const bounded = await minimizeSchedule(original, "ownership", async () => {}, 1);
    assert.equal(bounded.attempts, 1);
    assert.deepEqual(bounded.schedule, original);
    const noGrowth = await minimizeSchedule(original, "ownership", async () => {
        const error = new LifecycleFailure("ownership", "Still fails");
        error.systematicSchedule = original;
        throw error;
    });
    assert.deepEqual(noGrowth.schedule, original);
});

test("default and extended profiles cover both surfaces, both providers and each named race", () => {
    const required = ["authentication-cancellation", "signing-cancellation", "signing-revocation", "publication-cancellation",
        "checkpoint-cancellation", "dispatch-cancellation", "completion-cancellation", "delivery-cancellation"];
    for (const profile of ["all", "extended"]) {
        for (const mode of ["native", "popup"]) {
            const scenarios = systematicScenarios(mode, 42, profile);
            assert.equal(scenarios.length, required.length * 2);
            for (const provider of ["ethereum", "solana"]) {
                assert.deepEqual(scenarios.filter(scenario => scenario.systematic.provider === provider)
                    .map(scenario => scenario.systematic.template), required);
            }
            for (const scenario of scenarios) { assert.equal(validateSystematicScenario(scenario), scenario); }
        }
    }
});

test("systematic profiles require actual overlapping request and fault workloads", () => {
    assert.deepEqual(systematicWorkload("all"), {requests: 2, faults: 1});
    assert.deepEqual(systematicWorkload("extended"), {requests: 3, faults: 2});
    assert.throws(() => systematicWorkload("unknown"));
});

test("declared multi-request race frontiers fit the complete run budgets", async () => {
    for (const profile of ["all", "extended"]) {
        const workload = systematicWorkload(profile);
        const report = await exploreSchedules(async explorer => {
            await explorer.step([action("request0:observe-overlap", "request0")]);
            let primary = 0;
            const finished = new Set();
            while (primary < 2 || finished.size < workload.requests - 1) {
                const enabled = [];
                if (primary < 2) { enabled.push(action(`request0:advance:${primary}`, "request0", async () => { primary++; })); }
                for (let index = 1; index < workload.requests; index++) {
                    if (!finished.has(index)) { enabled.push(action(`request${index}:release-and-fault`, `request${index}`, async () => { finished.add(index); }, true)); }
                }
                await explorer.step(enabled);
            }
            assert.equal(explorer.finish().actors, workload.requests);
            assert.equal(explorer.finish().faults, workload.faults);
        }, {profile});
        assert.equal(report.frontier, 0);
        assert.equal(report.pruned, 0);
        assert.ok(report.completed * systematicScenarios("native", 1, profile).length * 2 <= EXPLORATION_BOUNDS[profile].traces);
    }
});

test("systematic command options enforce profile budgets and independent diagnostic modes", () => {
    const parse = (...args) => parseOptions(["--worker", "/fixture/worker", ...args]);
    assert.equal(parse().systematic, "all");
    assert.equal(parse("--systematic", "extended", "--trace-limit", "4096").traceLimit, 4096);
    const only = parse("--systematic-only");
    assert.equal(only.mandatory, false);
    assert.equal(only.sequences, 0);
    assert.equal(only.systematic, "all");
    assert.equal(parse("--random-only").systematic, "off");
    for (const args of [["--trace-limit", "257"], ["--systematic", "off", "--trace-limit", "1"],
        ["--systematic-only", "--random-only"], ["--systematic-only", "--systematic", "off"], ["--systematic", "unknown"]]) {
        assert.throws(() => parse(...args));
    }
});
