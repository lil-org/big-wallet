import assert from "node:assert/strict";
import {once} from "node:events";
import test from "node:test";
import {NativeChild} from "../../Scripts/approval_lifecycle/native_child.mjs";
import {LifecycleSession} from "../../Scripts/approval_lifecycle/session.mjs";

const prelude = `
import readline from 'node:readline';
const epoch = process.argv[process.argv.indexOf('--epoch') + 1];
let sequence = 0;
const send = value => process.stdout.write(JSON.stringify({epoch,...value})+'\\n');
send({kind:'event',sequence:++sequence,event:'ready',details:{pid:process.pid}});
const lines = readline.createInterface({input:process.stdin});
`;
function child(source, options = {}) {
    return new NativeChild({executable: process.execPath, extraArguments: ["--input-type=module", "-e", prelude + source, "--"],
        role: "bridge", root: "/unused", epoch: "test-incarnation", mode: "native", timeout: 3000, ...options});
}

test("native IPC multiplexes replies and leaves controls responsive while work is held", async () => {
    const worker = child(`
        let held;
        lines.on('line', line => {
            const call=JSON.parse(line);
            if(call.operation==='hold') { held=call; send({kind:'event',sequence:++sequence,event:'checkpoint',details:{name:'held',hold:true},gate:'one'}); }
            if(call.operation==='inspect') { send({kind:'reply',id:call.id,ok:true,result:'responsive'}); }
            if(call.kind==='release') { send({kind:'reply',id:held.id,ok:true,result:call.value}); }
        });
    `);
    try {
        await worker.waitEvent(event => event.event === "ready");
        const pending = worker.command("hold");
        await worker.waitEvent(event => event.gate === "one");
        assert.equal(await worker.command("inspect"), "responsive");
        worker.release("one", "released");
        assert.equal(await pending, "released");
        assert.throws(() => worker.release("one"), error => error.invariant === "protocol");
    } finally { await worker.close(); }
});

for (const [name, response] of [
    ["foreign epoch", "send({kind:'reply',epoch:'old',id:call.id,ok:true,result:null});"],
    ["unknown id", "send({kind:'reply',id:call.id+100,ok:true,result:null});"],
    ["malformed JSON", "process.stdout.write('broken\\n');"],
    ["out-of-order event", "send({kind:'event',sequence:1,event:'checkpoint',details:{}});"],
]) {
    test(`native IPC rejects ${name}`, async () => {
        const worker = child(`lines.on('line', line => {const call=JSON.parse(line); ${response}});`);
        try {
            await worker.waitEvent(event => event.event === "ready");
            await assert.rejects(worker.command("check"), error => error.invariant === "protocol");
        } finally { await worker.close(); }
    });
}

test("native IPC fails missing replies and missing checkpoints with bounded watchdogs", async () => {
    for (const checkpoint of [false, true]) {
        const worker = child("lines.on('line',()=>{});");
        try {
            await worker.waitEvent(event => event.event === "ready");
            const pending = checkpoint ? worker.waitEvent(event => event.event === "missing", {timeout: 30})
                : worker.command("missing", {}, {timeout: 30});
            await assert.rejects(pending, error => error.invariant === "watchdog");
        } finally { await worker.close(); }
    }
});

test("native gate expiry fails the run even if production returns a recoverable response", async () => {
    const worker = child(`lines.on('line', line => {
        const call=JSON.parse(line);
        send({kind:'event',sequence:++sequence,event:'watchdog',details:{gate:'expired-gate'}});
        send({kind:'reply',id:call.id,ok:true,result:{unavailable:true}});
    });`);
    try {
        await worker.waitEvent(event => event.event === "ready");
        await assert.rejects(worker.command("work"), error => error.invariant === "watchdog" && error.details.gate === "expired-gate");
        assert.equal(worker.failure.invariant, "watchdog");
    } finally { await worker.close(); }
});

test("native IPC distinguishes intentional SIGKILL and reaps its owned process", async () => {
    const worker = child("lines.on('line',()=>{});");
    await worker.waitEvent(event => event.event === "ready");
    const pending = worker.command("hold").catch(error => error);
    const exited = await worker.kill();
    assert.equal(exited.signal, "SIGKILL");
    assert.equal(worker.failure, null);
    assert.equal((await pending).invariant, "process-restarted");
    assert.equal(worker.exited, true);
});

test("an intentional kill may truncate a subsequent frame without corrupting the acknowledged checkpoint", async () => {
    const worker = child(`lines.on('line', line => {
        const call=JSON.parse(line);
        send({kind:'event',sequence:++sequence,event:'checkpoint',details:{name:'durable'},gate:'durable'});
        process.stdout.write('{"partial":');
    });`);
    await worker.waitEvent(event => event.event === "ready");
    const pending = worker.command("hold").catch(error => error);
    await worker.waitEvent(event => event.event === "checkpoint");
    await worker.kill();
    assert.equal(worker.failure, null);
    assert.equal((await pending).invariant, "process-restarted");
});

test("restart preserves an oracle failure from a complete frame drained during SIGKILL", async () => {
    const session = new LifecycleSession({seed: 1, mode: "popup"});
    let starts = 0;
    session.start = async () => { starts += 1; throw new Error("A failed incarnation must not be replaced"); };
    const worker = child(`lines.on('line', () => {
        send({kind:'event',sequence:++sequence,event:'checkpoint',details:{name:'signer.before',
            handle:{id:1,token:'00000000-0000-0000-0000-000000000001',profileIdentifier:null},executionID:'execution'}});
        process.stderr.write('event written\\n');
    });`, {onEvent: (event, source) => session.nativeEvent(event, source)});
    session.children.set("bridge", worker);
    try {
        await worker.waitEvent(event => event.event === "ready");
        worker.process.stdout.pause();
        const written = once(worker.process.stderr, "data");
        const pending = worker.command("work").catch(error => error);
        await written;
        assert.equal(worker.failure, null);
        const restarting = session.restart("bridge");
        worker.process.stdout.resume();
        await assert.rejects(restarting, error => error.invariant === "consent");
        assert.equal((await pending).invariant, "consent");
        assert.equal(worker.exited, true);
        assert.equal(starts, 0);
        assert.equal(session.children.get("bridge"), worker);
        assert.throws(() => session.check(), error => error.invariant === "consent");
    } finally {
        worker.process.stdout.resume();
        await worker.close();
    }
});

test("out-of-band task cancellation and fences remain responsive at a held gate", async () => {
    const worker = child(`
        let held, active = false, gate = false;
        lines.on('line', line => {
            const call = JSON.parse(line);
            if (call.operation === 'hold') {
                held = call; active = true; gate = true;
                send({kind:'event', sequence:++sequence, event:'task', details:{id:'work#1', label:'work', active:true}});
                send({kind:'event', sequence:++sequence, event:'checkpoint', gate:'held', details:{name:'held', hold:true, taskID:'work#1'}});
            } else if (call.kind === 'control' && call.operation === 'fence') {
                send({kind:'reply', id:call.id, ok:true, result:{sequence,
                    tasks:active ? [{id:'work#1', label:'work'}] : [], gates:gate ? [{gate:'held', name:'held', taskID:'work#1'}] : []}});
            } else if (call.kind === 'control' && call.operation === 'cancel') {
                const cancelled = active && call.payload.taskID === 'work#1';
                if (cancelled) {
                    gate = false;
                    send({kind:'event', sequence:++sequence, event:'gateRetired', details:{gate:'held'}});
                    active = false;
                    send({kind:'event', sequence:++sequence, event:'task', details:{id:'work#1', label:'work', active:false}});
                    send({kind:'reply', id:held.id, ok:true, result:'cancelled'});
                }
                send({kind:'reply', id:call.id, ok:true, result:{cancelled, taskID:call.payload.taskID}});
            }
        });
    `);
    try {
        await worker.waitEvent(event => event.event === "ready");
        const pending = worker.command("hold");
        await worker.waitEvent(event => event.gate === "held");
        const before = await worker.fence();
        assert.deepEqual(before.tasks, [{id: "work#1", label: "work"}]);
        assert.equal(before.gates[0].gate, "held");
        assert.equal(await worker.cancelTask("work#1"), true);
        const after = await worker.fence();
        assert.deepEqual(after.tasks, []);
        assert.deepEqual(after.gates, []);
        assert.equal(worker.gates.has("held"), false);
        assert.ok(worker.events.some(event => event.event === "task" && event.details.active === false && event.sequence <= after.sequence));
        assert.equal(await worker.cancelTask("work#1"), false);
        assert.equal(await pending, "cancelled");
    } finally { await worker.close(); }
});

test("a native fence waits for earlier observations while exposing pending external RPC work", async () => {
    let releaseObservation, releaseRPC, observationFinished = false;
    const observation = new Promise(resolve => { releaseObservation = resolve; });
    const rpc = new Promise(resolve => { releaseRPC = resolve; });
    const worker = child(`
        lines.on('line', line => {
            const call = JSON.parse(line);
            if (call.operation === 'observe') {
                send({kind:'event', sequence:++sequence, event:'observation', details:{}});
                send({kind:'event', sequence:++sequence, event:'rpc', gate:'rpc', details:{}});
                send({kind:'reply', id:call.id, ok:true, result:null});
            } else if (call.kind === 'control' && call.operation === 'fence') {
                send({kind:'reply', id:call.id, ok:true, result:{sequence, tasks:[], gates:[{gate:'rpc'}]}});
            }
        });
    `, {onEvent: async event => {
        if (event.event === "observation") { await observation; observationFinished = true; }
        if (event.event === "rpc") { await rpc; }
    }});
    try {
        await worker.waitEvent(event => event.event === "ready");
        await worker.command("observe");
        let fenced = false;
        const fence = worker.fence().then(result => { fenced = true; return result; });
        await new Promise(resolve => setImmediate(resolve));
        assert.equal(fenced, false);
        releaseObservation();
        const snapshot = await fence;
        assert.equal(observationFinished, true);
        assert.deepEqual(snapshot.pendingEvents.map(event => event.event), ["rpc"]);
        releaseRPC();
    } finally { releaseObservation(); releaseRPC(); await worker.close(); }
});

for (const [operation, result] of [
    ["fence", {sequence: 100000, tasks: [], gates: []}],
    ["fence", {sequence: 1, tasks: {}, gates: []}],
    ["cancel", {taskID: "other-task", cancelled: true}],
    ["cancel", {taskID: "work#1", cancelled: "yes"}],
]) {
    test(`native ${operation} rejects malformed control acknowledgements ${JSON.stringify(result)}`, async () => {
        const worker = child(`lines.on('line', line => {
            const call = JSON.parse(line);
            send({kind:'reply', id:call.id, ok:true, result:${JSON.stringify(result)}});
        });`);
        try {
            await worker.waitEvent(event => event.event === "ready");
            await assert.rejects(operation === "fence" ? worker.fence() : worker.cancelTask("work#1"),
                error => error.invariant === "protocol");
        } finally { await worker.close(); }
    });
}
