import assert from "node:assert/strict";
import test from "node:test";
import {actionKinds, generateScenario, mandatoryCheckpoints, minimizeScenario, parseOptions, validateScenario} from "../../Scripts/approval_lifecycle/scenarios.mjs";
import {LifecycleFailure} from "../../Scripts/approval_lifecycle/scheduler.mjs";
import {mandatoryName, mandatoryScenarios, validateMandatoryScenario} from "../../Scripts/approval_lifecycle/mandatory.mjs";

test("Lifecycle scenarios are reproducible and cover action kinds before random continuation", () => {
    for (const seed of [0, 1, 17, 0xffffffff]) {
        for (const mode of ["native", "popup"]) {
            const first = generateScenario({seed, steps: 64, mode});
            assert.deepEqual(first, generateScenario({seed, steps: 64, mode}));
            assert.equal(first.actions.length, 64);
            assert.deepEqual(new Set(first.actions.slice(0, actionKinds.length).map(action => action.kind)), new Set(actionKinds));
            assert.equal(validateScenario(JSON.parse(JSON.stringify(first))).seed, seed);
            assert.deepEqual(new Set(first.actions.map(action => action.tab)), new Set([0, 1, 2, 3]));
            for (const action of first.actions) {
                if (mode === "popup" && ["restartNative", "failPersistence"].includes(action.kind)) { assert.equal(action.role, "bridge"); }
                if (action.kind === "clockBackward") { assert.ok(action.milliseconds < 0); }
                if (action.kind === "expire") { assert.ok(action.milliseconds > 0); }
                if (action.kind === "drop") { assert.notEqual(action.channel, "page"); }
            }
        }
    }
    assert.notDeepEqual(generateScenario({seed: 42}), generateScenario({seed: 43}));
    assert.equal(new Set(mandatoryCheckpoints).size, mandatoryCheckpoints.length);
    for (const checkpoint of ["receipt.after", "broadcast.prepared", "persistence.rename.after", "acknowledgement.after", "revocation.after"]) {
        assert.ok(mandatoryCheckpoints.includes(checkpoint));
    }
});

test("Explicit replay can retain diagnostic permanent DOM losses while generated drops use interruptible transports", () => {
    const explicit = {version: 1, seed: 1, mode: "native", actions: [{kind: "drop", tab: 0, selector: 0, channel: "page", phase: "request"}]};
    assert.equal(validateScenario(explicit), explicit);
    const channels = new Set;
    for (let seed = 0; seed < 64; seed += 1) {
        for (const value of generateScenario({seed, steps: 200}).actions) {
            if (value.kind === "drop") { assert.notEqual(value.channel, "page"); channels.add(value.channel); }
        }
    }
    assert.deepEqual(channels, new Set(["native", "runtime", "tab"]));
});

test("Lifecycle CLI defaults, soak and explicit overrides retain requested budgets", () => {
    const defaults = parseOptions(["--worker", "/fixture/worker"]);
    assert.deepEqual([defaults.seed, defaults.sequences, defaults.steps, defaults.mode], [1, 32, 64, "alternate"]);
    assert.equal(defaults.mandatory, true);
    assert.equal(defaults.minimize, true);
    const soak = parseOptions(["--worker", "/fixture/worker", "--soak"]);
    assert.deepEqual([soak.sequences, soak.steps], [1000, 200]);
    const explicit = parseOptions(["--soak", "--worker", "/fixture/worker", "--seed", "0xffffffff", "--sequences", "3", "--steps", "7", "--mode", "popup", "--no-minimize", "--random-only", "--replay", "/fixture/scenario.json"]);
    assert.deepEqual([explicit.seed, explicit.sequences, explicit.steps, explicit.mode], [0xffffffff, 3, 7, "popup"]);
    assert.equal(explicit.minimize, false);
    assert.equal(explicit.mandatory, false);
    assert.equal(explicit.replay, "/fixture/scenario.json");
    assert.equal(parseOptions(["--help"]).help, true);
});

test("Lifecycle CLI rejects malformed options and out-of-range run budgets", () => {
    for (const arguments_ of [[], ["--worker"], ["--worker", "/fixture/worker", "--unknown"], ["--worker", "/fixture/worker", "--mode", "invalid"]]) {
        assert.throws(() => parseOptions(arguments_));
    }
    for (const [flag, values] of [
        ["--seed", ["-1", "4294967296", "1.1", "NaN", "1e3"]],
        ["--sequences", ["0", "1001", "-1", "Infinity"]],
        ["--steps", ["0", "10001", "0.5"]],
        ["--timeout-ms", ["0", "120001", "10ms"]],
    ]) {
        for (const value of values) { assert.throws(() => parseOptions(["--worker", "/fixture/worker", flag, value])); }
    }
});

const scenario = actions => ({version: 1, seed: 1, mode: "native", actions});
const action = (kind, fields = {}) => ({kind, tab: 0, selector: 0, ...fields});

test("Lifecycle replay validates envelope and bounded action identities", () => {
    assert.equal(validateScenario(scenario([])).actions.length, 0);
    for (const value of [null, {}, {...scenario([]), version: 2}, {...scenario([]), mode: "alternate"}, {...scenario([]), seed: -1}, {...scenario([]), seed: 0x100000000}, {...scenario([]), actions: Array(10001).fill(action("wake"))}]) {
        assert.throws(() => validateScenario(value));
    }
    for (const invalid of [null, {}, action("unrecognized"), action("wake", {tab: -1}), action("wake", {tab: 4}), action("wake", {selector: NaN}), action("wake", {selector: -1}), action("wake", {selector: 0.5})]) {
        assert.throws(() => validateScenario(scenario([invalid])));
    }
});

test("Lifecycle replay rejects actions that cannot execute their selected behavior", () => {
    for (const invalid of [
        action("request", {provider: "unknown", method: "message"}), action("request", {provider: "ethereum", method: "unknown"}),
        action("expire", {milliseconds: -1}), action("clockBackward", {milliseconds: 1}), action("expire", {milliseconds: Infinity}),
        action("delay", {channel: "unknown", phase: "reply", delay: 1}), action("drop", {channel: "native", phase: "unknown"}),
        action("delay", {channel: "native", phase: "reply", delay: -1}), action("restartNative", {role: "unrelated-process"}),
        action("failPersistence", {role: "bridge", checkpoint: "unknown", partialWriteBytes: 1}),
    ]) { assert.throws(() => validateScenario(scenario([invalid]))); }
    assert.throws(() => validateScenario({...scenario([action("restartNative", {role: "approval"})]), mode: "popup"}));
});

test("Lifecycle replay requires one increasing safe phase identity per action", () => {
    const original = scenario([action("wake"), action("deliver")]);
    assert.deepEqual(validateScenario({...original, actionPhases: [3, 8]}).actionPhases, [3, 8]);
    for (const actionPhases of [null, {}, [], [0], [0, 1, 2], [-1, 0], [1, 1], [2, 1], [0, 1.5],
        [0, Infinity], [0, Number.MAX_SAFE_INTEGER + 1], Array(2)]) {
        assert.throws(() => validateScenario({...original, actionPhases}));
    }
});

test("Lifecycle reduction preserves the violated invariant and required preceding actions", async () => {
    const original = scenario([action("wake"), action("request", {provider: "ethereum", method: "connect"}), action("focus"), action("approve"), action("deliver"), action("duplicate", {channel: "native", phase: "reply", delay: 500, selector: 18}), action("wake")]);
    const unchanged = structuredClone(original);
    let calls = 0;
    const replay = async candidate => {
        calls += 1;
        const kinds = candidate.actions.map(value => value.kind);
        const request = kinds.indexOf("request"), approve = kinds.indexOf("approve"), duplicate = kinds.indexOf("duplicate");
        if (request >= 0 && approve > request && duplicate > approve) { throw new LifecycleFailure("broadcast", "Duplicate dispatch"); }
        if (duplicate >= 0) { throw new LifecycleFailure("progress", "Missing prerequisite"); }
    };
    const reduced = await minimizeScenario(original, "broadcast", replay);
    assert.deepEqual(original, unchanged);
    assert.deepEqual(reduced.scenario.actions.map(value => value.kind), ["request", "approve", "duplicate"]);
    assert.deepEqual(reduced.scenario.actionPhases, [1, 3, 5]);
    assert.equal(reduced.scenario.actions[2].selector, 0);
    assert.equal(reduced.scenario.actions[2].delay, 0);
    assert.equal(reduced.attempts, calls);
    assert.ok(calls <= 200);
    await assert.rejects(replay(reduced.scenario), error => error.invariant === "broadcast");
});

test("Lifecycle reduction projects deleted action metadata and retains setup and recovery choices", async () => {
    const original = {...scenario([action("drop", {channel: "native", phase: "reply"}), action("deliver"), action("releaseNative")]),
        actionPhases: [2, 4, 7], faultTargets: {0: "4|captured-target"}, decisions: [
            {phase: "setup", type: "native-gate", ordinal: 0, choice: "setup-gate"},
            {phase: 4, type: "delivery", ordinal: 0, choice: "captured-delivery"},
            {phase: 7, type: "release-gate", ordinal: 0, choice: null},
            {phase: "recovery", type: "native-gate", ordinal: 0, choice: "recovery-gate"},
        ]};
    const unchanged = structuredClone(original);
    const reduced = await minimizeScenario(original, "broadcast", async candidate => {
        validateScenario(candidate);
        if (!candidate.actions.some(value => value.kind === "releaseNative")) { return; }
        throw new LifecycleFailure("broadcast", "Independent failure");
    });
    assert.deepEqual(original, unchanged);
    assert.deepEqual(reduced.scenario.actions, [action("releaseNative")]);
    assert.deepEqual(reduced.scenario.actionPhases, [7]);
    assert.deepEqual(reduced.scenario.faultTargets, {});
    assert.deepEqual(reduced.scenario.decisions, original.decisions.filter(value => value.phase !== 4));
});

test("Lifecycle reduction cannot replace a failure with a different invariant or an exception", async () => {
    const original = scenario([action("wake"), action("focus"), action("deliver")]);
    for (const error of [new LifecycleFailure("protocol", "Different failure"), new Error("Unexpected runtime exception")]) {
        const reduced = await minimizeScenario(original, "broadcast", async () => { throw error; }, 20);
        assert.deepEqual(reduced.scenario, original);
    }
});

test("Lifecycle reduction obeys the global attempt limit including schedule simplification", async () => {
    const original = scenario(Array.from({length: 400}, (_, selector) => action("delay", {selector: selector + 1, channel: "native", phase: "reply", delay: 500})));
    let calls = 0;
    const reduced = await minimizeScenario(original, "broadcast", async () => { calls += 1; }, 200);
    assert.equal(reduced.attempts, 200);
    assert.equal(calls, 200);
    const zero = await minimizeScenario(original, "broadcast", async () => { throw new Error("Must not execute"); }, 0);
    assert.equal(zero.attempts, 0);
    assert.deepEqual(zero.scenario, original);
    for (const limit of [-1, 201, 1.5, Infinity]) { await assert.rejects(minimizeScenario(original, "broadcast", async () => {}, limit)); }
});

test("Mandatory crash corpus covers both providers and every broadcast persistence boundary on both surfaces", () => {
    for (const mode of ["native", "popup"]) {
        const cases = mandatoryScenarios(mode, 17);
        assert.deepEqual(cases, mandatoryScenarios(mode, 17));
        assert.equal(new Set(cases.map(mandatoryName)).size, cases.length);
        for (const candidate of cases) {
            assert.equal(validateMandatoryScenario(JSON.parse(JSON.stringify(candidate))).mode, mode);
        }
        for (const provider of ["ethereum", "solana"]) {
            for (const stage of ["write", "fileSync", "rename", "directorySync", "finalSync"]) {
                for (const side of ["before", "after"]) {
                    const matches = cases.filter(({mandatory}) => mandatory.kind === "crash" && mandatory.provider === provider &&
                        mandatory.checkpoint === `persistence.${stage}.${side}` && mandatory.operation === "broadcast.prepare");
                    assert.equal(matches.length, 1);
                    if (stage === "write" && side === "after") { assert.equal(matches[0].mandatory.partialWriteBytes, 17); }
                }
            }
            for (const checkpoint of ["admission.after", "claim.after", "authorize.after", "signer.before", "signer.after", "broadcast.prepared", "rpc.received", "rpc.accepted", "completion.after", "delivery.after", "acknowledgement.after"]) {
                assert.ok(cases.some(({mandatory}) => mandatory.provider === provider && mandatory.checkpoint === checkpoint), `${mode}/${provider}/${checkpoint}`);
            }
            assert.equal(cases.some(({mandatory}) => mandatory.provider === provider && mandatory.checkpoint === "receipt.after"), mode === "native");
        }
    }
});

test("Mandatory corpus contains success, process competition, capability replay, authentication and revocation recovery", () => {
    for (const mode of ["native", "popup"]) {
        const cases = mandatoryScenarios(mode);
        for (const kind of ["success", "competition", "consentReplay", "revocationCrash", "authenticationCancellation", "revocationBeforeSigning"]) {
            assert.ok(cases.some(({mandatory}) => mandatory.kind === kind));
        }
        assert.equal(cases.some(({mandatory}) => mandatory.kind === "retryRequiredFocus"), mode === "native");
        assert.equal(cases.some(({mandatory}) => mandatory.kind === "chainSwitchAuthentication"), mode === "native");
        assert.equal(cases.some(({mandatory}) => mandatory.kind === "manualSwitchCoalescing"), mode === "native");
        assert.equal(cases.some(({mandatory}) => mandatory.kind === "editedReview"), mode === "popup");
        assert.equal(cases.some(({mandatory}) => mandatory.kind === "abandonedPopupReview"), mode === "popup");
        assert.equal(cases.some(({mandatory}) => mandatory.kind === "walletReconciliationAfterClockJump"), mode === "popup");
        assert.equal(cases.some(({mandatory}) => mandatory.kind === "contenderDuringBroadcast"), mode === "popup");
        for (const provider of ["ethereum", "solana"]) {
            for (const operation of ["claim", "completion", "acknowledgement"]) {
                for (const side of ["before", "after"]) {
                    assert.ok(cases.some(({mandatory}) => mandatory.provider === provider && mandatory.operation === operation && mandatory.checkpoint === `persistence.rename.${side}`));
                }
            }
        }
    }
});

test("Mandatory replay rejects unknown scenarios and altered crash target identities", () => {
    const candidate = mandatoryScenarios("native").find(({mandatory}) => mandatory.kind === "crash" && mandatory.operation === "broadcast.prepare");
    for (const invalid of [null, {...candidate, version: 2}, {...candidate, seed: -1}, {...candidate, seed: 0x100000000},
        {...candidate, actions: [action("wake")]}, {...candidate, mandatory: {...candidate.mandatory, provider: "unknown"}},
        {...candidate, mandatory: {...candidate.mandatory, operation: "unrelated-write"}},
        {...candidate, mandatory: {...candidate.mandatory, checkpoint: "persistence.unrelated.after"}}]) {
        assert.throws(() => validateMandatoryScenario(invalid));
    }
    const receipt = mandatoryScenarios("native").find(({mandatory}) => mandatory.checkpoint === "receipt.after");
    assert.throws(() => validateMandatoryScenario({...receipt, mode: "popup"}));
    const retryRequiredFocus = mandatoryScenarios("native").find(({mandatory}) => mandatory.kind === "retryRequiredFocus");
    assert.throws(() => validateMandatoryScenario({...retryRequiredFocus, mode: "popup"}));
    const chainSwitchAuthentication = mandatoryScenarios("native").find(({mandatory}) => mandatory.kind === "chainSwitchAuthentication");
    assert.throws(() => validateMandatoryScenario({...chainSwitchAuthentication, mode: "popup"}));
    const manualSwitchCoalescing = mandatoryScenarios("native").find(({mandatory}) => mandatory.kind === "manualSwitchCoalescing");
    assert.throws(() => validateMandatoryScenario({...manualSwitchCoalescing, mode: "popup"}));
    const abandonedPopupReview = mandatoryScenarios("popup").find(({mandatory}) => mandatory.kind === "abandonedPopupReview");
    assert.throws(() => validateMandatoryScenario({...abandonedPopupReview, mode: "native"}));
    const walletReconciliation = mandatoryScenarios("popup").find(({mandatory}) => mandatory.kind === "walletReconciliationAfterClockJump");
    assert.throws(() => validateMandatoryScenario({...walletReconciliation, mode: "native"}));
    const contenderDuringBroadcast = mandatoryScenarios("popup").find(({mandatory}) => mandatory.kind === "contenderDuringBroadcast");
    assert.throws(() => validateMandatoryScenario({...contenderDuringBroadcast, mode: "native"}));
});
