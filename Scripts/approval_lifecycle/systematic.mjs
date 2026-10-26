import {LifecycleFailure} from "./scheduler.mjs";
import {EXPLORATION_BOUNDS, validateSchedule} from "./explorer.mjs";
import {approveOnce, awaitReview} from "./mandatory.mjs";
import {handleKey} from "./oracle.mjs";

const templates = Object.freeze([
    {name: "authentication-cancellation", gates: ["authentication.before"], interference: "cancel", method: "message"},
    {name: "signing-cancellation", gates: ["signer.before", "signer.after"], interference: "cancel", method: "broadcast"},
    {name: "signing-revocation", gates: ["signer.before", "signer.after"], interference: "revoke", method: "broadcast"},
    {name: "publication-cancellation", gates: ["persistence.write.before", "persistence.rename.after"], operation: "broadcast.prepare", interference: "cancel", method: "broadcast"},
    {name: "checkpoint-cancellation", gates: ["broadcast.prepared"], interference: "cancel", method: "broadcast"},
    {name: "dispatch-cancellation", gates: ["broadcast.dispatch"], interference: "cancel", method: "broadcast"},
    {name: "completion-cancellation", gates: ["persistence.write.before", "persistence.rename.after"], operation: "completion", interference: "cancel", method: "message"},
    {name: "delivery-cancellation", gates: ["delivery.after"], interference: "cancel", method: "message"},
]);

export function systematicScenarios(mode, seed = 1, profile = "all") {
    if (!["native", "popup"].includes(mode) || !Object.hasOwn(EXPLORATION_BOUNDS, profile)) {
        throw new Error("Invalid systematic scenario configuration");
    }
    return ["ethereum", "solana"].flatMap(provider => templates.map(template => ({
        version: 1, seed, mode, actions: [], systematic: {template: template.name, provider, profile},
    })));
}

export function systematicName(scenario) {
    return `${scenario.mode}/systematic/${scenario.systematic.provider}/${scenario.systematic.template}`;
}

export function validateSystematicScenario(scenario) {
    if (!scenario || scenario.version !== 1 || !Number.isInteger(scenario.seed) || scenario.seed < 0 || scenario.seed > 0xffffffff ||
        !["native", "popup"].includes(scenario.mode) || !Array.isArray(scenario.actions) || scenario.actions.length ||
        !scenario.systematic || !["ethereum", "solana"].includes(scenario.systematic.provider) ||
        !Object.hasOwn(EXPLORATION_BOUNDS, scenario.systematic.profile) ||
        !templates.some(template => template.name === scenario.systematic.template)) {
        throw new Error("Invalid systematic approval scenario");
    }
    if (scenario.schedule !== undefined) { validateSchedule(scenario.schedule); }
    return scenario;
}

export function systematicWorkload(profile) {
    if (!Object.hasOwn(EXPLORATION_BOUNDS, profile)) { throw new Error("Invalid systematic profile"); }
    return {requests: profile === "extended" ? 3 : 2, faults: profile === "extended" ? 2 : 1};
}

export async function runSystematic(session, scenario, explorer) {
    validateSystematicScenario(scenario);
    const template = templates.find(value => value.name === scenario.systematic.template);
    const {provider, profile} = scenario.systematic;
    const workload = systematicWorkload(profile);
    const rules = new Map();
    const addRules = (child, actor, names, operation) => {
        const entries = names.map((name, index) => ({name, label: `systematic:${template.name}:${actor}:${index}`,
            occurrence: 1, action: "hold", ...(operation ? {operation} : {})}));
        const tracked = {child, entries, operation: null};
        const values = rules.get(child) ?? [];
        values.push(tracked); rules.set(child, values);
        return tracked;
    };
    const arm = async () => {
        for (const [child, entries] of rules) {
            await child.command("checkpoints", {rules: entries.flatMap(value => value.entries.map(rule => ({...rule,
                ...(value.operation?.handle ? {requestToken: value.operation.handle.token} : {})})))});
        }
    };
    const parked = (control, index = 0) => {
        const rule = control.entries[index];
        if (!rule) { return undefined; }
        const key = `${rule.label}|${rule.name}|1`;
        return [...session.gates.values()].find(gate => gate.child === control.child &&
            gate.details.gateKey === key && control.child.gates.has(gate.event.gate));
    };
    const release = control => {
        const gate = parked(control);
        if (!gate) { throw new LifecycleFailure("coverage", "A competing request lost its acknowledged gate"); }
        control.child.release(gate.event.gate);
        session.gates.delete(`${control.child.epoch}:${gate.event.gate}`);
    };
    await session.connect(0, provider);
    await session.connect(3, provider);
    let thirdTab;
    if (workload.requests === 3) {
        thirdTab = session.tabs.length;
        session.tabs.push(session.browser.openTab({profileIdentifier: session.tabs[3].profile.id,
            url: new URL(session.tabs[2].url).origin + "/systematic-third"}));
        await session.connect(thirdTab, provider);
    }
    const signingOwner = session.child(session.mode === "popup" ? "bridge" : "approval");
    const owner = session.child(template.name === "delivery-cancellation" ? "bridge" : signingOwner.role);

    const companion = addRules(signingOwner, "request1", ["signer.before"]);
    companion.operation = session.request({tab: 3, provider, method: "message"});
    const companionReview = await awaitReview(session, provider, {tab: 3});
    await arm();
    await approveOnce(session, companionReview);
    await session.pumpUntil(() => parked(companion) !== undefined, {advance: true});

    let third;
    if (thirdTab !== undefined) {
        third = addRules(session.child("bridge"), "request2", ["admission.after"], "enqueue");
        await arm();
        third.operation = session.request({tab: thirdTab, provider, method: "message"});
        await session.pumpUntil(() => parked(third) !== undefined, {advance: true});
    }

    const primary = addRules(owner, "request0", template.gates, template.operation);
    const early = template.name === "authentication-cancellation" && session.mode === "native";
    if (early) { await arm(); }
    primary.operation = session.request({tab: 0, provider, method: template.method});
    if (!early) {
        const request = await awaitReview(session, provider, {tab: 0});
        await arm();
        await approveOnce(session, request);
    }
    await session.pumpUntil(() => parked(primary) !== undefined, {advance: true});
    const controls = [primary, companion, ...(third ? [third] : [])];
    const tasks = [];
    for (const control of controls) {
        const gate = parked(control);
        const handle = gate?.details.handle ?? gate?.details.identity;
        const taskID = gate?.details.taskID;
        if (!control.operation.handle || control.operation.status !== "pending" || !handle ||
            handleKey(handle) !== handleKey(control.operation.handle) || typeof taskID !== "string") {
            throw new LifecycleFailure("coverage", "Systematic overlap requires distinct pending production requests", {handle, operation: control.operation, taskID});
        }
        const fence = await control.child.fence();
        if (!fence.tasks.some(task => task.id === taskID) || !fence.gates.some(value => value.gateKey === gate.details.gateKey)) {
            throw new LifecycleFailure("coverage", "Systematic request is not parked at a live production boundary", {taskID, fence});
        }
        tasks.push({control, taskID, finished: () => control.child.events.some(event => event.event === "task" &&
            event.details.id === taskID && event.details.active === false)});
    }
    if (new Set(controls.map(control => handleKey(control.operation.handle))).size !== workload.requests) {
        throw new LifecycleFailure("coverage", "Systematic request actors share an admission handle");
    }
    session.systematicWorkload = {requests: workload.requests, faultsApplied: 0};
    session.scheduler.phase = "systematic";
    explorer.onChoice = step => session.record({type: "systematic-choice", step});
    await explorer.step([{id: "request0:observe-overlap", actor: "request0", run: async () => {
        session.record({type: "systematic-workload", requests: controls.map((control, index) => ({actor: `request${index}`,
            handle: control.operation.handle, role: control.child.role, taskID: tasks[index].taskID})), faultBudget: workload.faults});
    }}]);
    let ownerStep = 0;
    let interfered = false;
    let restarted = !third;
    const terminalBoundary = template.name.startsWith("signing-") ? "signer.terminal"
        : template.name === "authentication-cancellation" && session.mode === "popup" ? "authentication.terminal" : null;
    const boundaryFinished = () => terminalBoundary ? owner.events.some(event => event.event === "observation" &&
        event.details.boundary === terminalBoundary && event.details.handle &&
        handleKey(event.details.handle) === handleKey(primary.operation.handle)) : tasks[0].finished();
    const primaryFinished = () => tasks[0].finished() && boundaryFinished() && !primary.entries.some((_, index) => parked(primary, index));
    while (ownerStep < template.gates.length || !interfered || !restarted) {
        if (ownerStep < template.gates.length && !primaryFinished() && !parked(primary, ownerStep)) {
            await session.pumpUntil(() => primaryFinished() || parked(primary, ownerStep) !== undefined, {advance: true});
        }
        if (primaryFinished() && !parked(primary, ownerStep)) { ownerStep = template.gates.length; }
        const actions = [];
        if (ownerStep < template.gates.length) {
            const index = ownerStep;
            actions.push({id: `request0:advance:${index}:${template.gates[index]}`, actor: "request0", run: async () => {
                const gate = parked(primary, index);
                if (!gate) { throw new LifecycleFailure("coverage", "Primary request lost its acknowledged boundary"); }
                owner.release(gate.event.gate); session.gates.delete(`${owner.epoch}:${gate.event.gate}`);
                ownerStep += 1;
                await session.pumpUntil(() => primaryFinished() || ownerStep < template.gates.length && parked(primary, ownerStep) !== undefined, {advance: true});
                session.record({type: "systematic-boundary", index, taskFinished: primaryFinished(), fence: await owner.fence()});
            }});
        }
        if (!interfered) {
            actions.push({id: `request1:release-and-${template.interference}`, actor: "request1", fault: true, run: async () => {
                if (template.interference === "cancel") {
                    const cancelled = await owner.cancelTask(tasks[0].taskID);
                    if (!cancelled && !primaryFinished()) {
                        throw new LifecycleFailure("coverage", "Cancellation target disappeared without a terminal event", {taskID: tasks[0].taskID});
                    }
                    session.systematicWorkload.faultsApplied += Number(cancelled);
                    session.record({type: "systematic-cancellation", taskID: tasks[0].taskID, cancelled, fence: await owner.fence()});
                    if (cancelled && terminalBoundary) {
                        await session.pumpUntil(primaryFinished, {advance: true});
                    }
                } else {
                    const tab = session.tabs[0];
                    const disconnect = session.browser.request(tab.id, provider, provider === "ethereum"
                        ? {method: "wallet_revokePermissions", params: [{eth_accounts: {}}]} : {method: "disconnect"});
                    await session.complete(disconnect, {approve: false, expectedSuccess: true});
                    session.systematicWorkload.faultsApplied += 1;
                }
                release(companion);
                interfered = true;
            }});
        }
        if (!restarted) {
            actions.push({id: "request2:release-and-restart-worker", actor: "request2", fault: true, run: async () => {
                session.browser.restartWorker(session.tabs[0].profile.id);
                session.systematicWorkload.faultsApplied += 1;
                release(third);
                restarted = true;
            }});
        }
        if (!actions.length) { break; }
        await explorer.step(actions);
        session.check();
    }
    const explored = explorer.finish();
    if (explored.actors !== workload.requests || explored.faults !== workload.faults) {
        throw new LifecycleFailure("coverage", "Systematic scheduling did not exercise every admitted request actor and fault action", {explored, workload});
    }
    await session.pumpUntil(() => tasks.every(task => task.finished()), {advance: true});
    const handles = new Set(controls.map(control => handleKey(control.operation.handle)));
    const relevant = () => session.ledger.events.filter(event => event.handle && handles.has(handleKey(event.handle)));
    const beforeRecovery = relevant();
    await session.quiesce();
    session.check();
    for (const {control, taskID} of tasks) {
        const fence = await control.child.fence();
        const keys = control.entries.map(rule => `${rule.label}|${rule.name}|1`);
        if (fence.tasks.some(task => task.id === taskID) || fence.gates.some(gate => keys.includes(gate.gateKey))) {
            throw new LifecycleFailure("ownership", "Systematic recovery leaked an operation or gate", {taskID, fence});
        }
        if (control.operation.status === "pending") { throw new LifecycleFailure("progress", "Systematic recovery left an overlapping browser operation pending", {operation: control.operation}); }
    }
    for (const effect of ["signer.before", "rpc.received"]) {
        const count = events => events.filter(event => effect === "rpc.received" ? event.type === effect : event.name === effect).length;
        if (count(relevant()) !== count(beforeRecovery)) {
            throw new LifecycleFailure("consent", "Fault-free recovery repeated privileged work", {effect, before: count(beforeRecovery), after: count(relevant())});
        }
    }
    session.coverage.add(`systematic:overlap:${workload.requests}`);
    session.coverage.add(`systematic:${template.name}:${provider}:${session.mode}`);
}
