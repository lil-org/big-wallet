import assert from "node:assert/strict";
import test from "node:test";
import {BrowserLifecycle} from "../../Scripts/approval_lifecycle/browser.mjs";
import {LifecycleFailure, Scheduler} from "../../Scripts/approval_lifecycle/scheduler.mjs";
import {deferred} from "./test_helpers.mjs";
import {createRequire} from "node:module";

const require = createRequire(new URL("../Inpage Provider/package.json", import.meta.url));
const base58Module = require("bs58");
const base58 = base58Module.default || base58Module;

const state = {context: "a".repeat(64), revisions: {ethereum: 0, solana: 0}, ethereum: {address: "", chainId: "0x1"}, solana: null};
function bootstrap(message) {
    if (message.subject === "getLatestConfiguration") { return {id: message.id, state}; }
    if (message.subject === "getRecoveryRequests") { return {id: message.id, requests: []}; }
    throw new Error(`Unexpected bootstrap command ${message.subject}`);
}

test("composed harness boots actual provider, content and worker scripts across queued cloned boundaries", async () => {
    const scheduler = new Scheduler;
    const native = [];
    const browser = new BrowserLifecycle({scheduler, native: async message => { native.push(message); return bootstrap(message); }});
    try {
        const tab = browser.openTab();
        const operation = browser.request(tab.id, "ethereum", {method: "eth_chainId"});
        await scheduler.until(() => operation.status !== "pending");
        browser.check();
        assert.equal(operation.result, "0x1");
        assert.equal(native.filter(message => message.subject === "getLatestConfiguration").length, 1);
        assert.equal(tab.document.pageWindow.ethereum.isBigWallet, true);
        assert.equal(tab.document.pageWindow.solana.isBigWallet, true);
        assert.equal(tab.document.pageWindow.navigator.wallets.length, 1);
        assert.notEqual(tab.document.pageWindow, tab.document.contentWindow);
    } finally { browser.close(); }
});

for (const phase of ["request", "reply"]) {
    for (const action of ["delay", "duplicate"]) {
        test(`page ${phase} ${action} faults affect the selected provider transport direction`, async () => {
            const scheduler = new Scheduler;
            const trace = [], delivered = [], settlements = [];
            const address = "0x" + "1".repeat(40);
            const connected = {...state, revisions: {ethereum: 1, solana: 0}, ethereum: {address, chainId: "0x1"}};
            const signature = "0x" + "11".repeat(65);
            let nativeRequests = 0;
            const browser = new BrowserLifecycle({scheduler, trace: event => trace.push(event),
                onSettlement: operation => settlements.push(operation), native: async message => {
                    if (message.subject === "getLatestConfiguration") { return {id: message.id, state: connected}; }
                    if (message.subject) { return bootstrap(message); }
                    nativeRequests += 1;
                    return {id: message.id, state: connected, response: {
                        id: message.id, name: message.name, provider: "ethereum", kind: "result", result: signature, approvalCommitted: true,
                    }};
                }});
            try {
                const tab = browser.openTab();
                await scheduler.until(() => browser.configurationReady(tab.id, connected));
                await scheduler.drain();
                tab.document.pageWindow.addEventListener("message", event => delivered.push(event.data));
                browser.addFault({channel: "page", phase, action, delay: 500});
                const operation = browser.request(tab.id, "ethereum", {method: "personal_sign", params: ["0x010203", address]});
                await scheduler.drain();
                assert.equal(browser.faults.length, 0);
                if (action === "delay") {
                    assert.equal(operation.status, "pending");
                    assert.equal(nativeRequests, phase === "request" ? 0 : 1);
                    await scheduler.advance(499);
                    assert.equal(operation.status, "pending");
                    await scheduler.advance(1);
                }
                browser.check();
                assert.equal(operation.status, "fulfilled");
                assert.equal(operation.result, signature);
                assert.equal(nativeRequests, 1);
                assert.equal(settlements.length, 1);
                for (const direction of ["request", "reply"]) {
                    const wireDirection = direction === "request" ? tab.document.contentContext.bigWalletPageDirection :
                        tab.document.contentContext.bigWalletContentDirection;
                    assert.equal(delivered.filter(message => message.direction === wireDirection &&
                        (direction === "request" ? message.message?.id : message.response?.id) === operation.wireID).length,
                        action === "duplicate" && direction === phase ? 2 : 1);
                }
                const fault = trace.find(event => event.type === "browser-wire" && event.fault);
                assert.equal(fault.channel, "page");
                assert.equal(fault.phase, phase);
            } finally { browser.close(); }
        });
    }
}

test("composed harness preserves distinct profiles, documents and restarted browser workers", async () => {
    const scheduler = new Scheduler;
    const profiles = [];
    const browser = new BrowserLifecycle({scheduler, native: async (message, profile) => { profiles.push(profile); return bootstrap(message); }});
    try {
        const first = browser.openTab({profileIdentifier: "00000000-0000-0000-0000-000000000001"});
        const second = browser.openTab({profileIdentifier: "00000000-0000-0000-0000-000000000002"});
        const reads = [first, second].map(tab => browser.request(tab.id, "ethereum", {method: "eth_accounts"}));
        await scheduler.until(() => reads.every(operation => operation.status !== "pending"));
        assert.deepEqual(new Set(profiles), new Set([first.profile.id, second.profile.id]));
        const previous = first.document.owner;
        browser.navigate(first.id, "https://other.example/dapp");
        browser.restartWorker(first.profile.id);
        browser.focus(first.id);
        const next = browser.request(first.id, "ethereum", {method: "eth_accounts"});
        await scheduler.until(() => next.status !== "pending", {advance: true});
        assert.notEqual(first.document.owner, previous);
        assert.equal(next.status, "fulfilled");
        browser.check();
    } finally { browser.close(); }
});

test("composed popup executes its real queue boot and closes its own timers", async () => {
    const scheduler = new Scheduler;
    const commands = [];
    const browser = new BrowserLifecycle({scheduler, mode: "popup", native: async message => {
        commands.push(message.subject);
        if (message.subject === "getPendingRequests") { return {requests: [], completedResponses: []}; }
        return bootstrap(message);
    }});
    try {
        browser.openTab();
        const popup = await browser.openPopup();
        await scheduler.until(() => commands.includes("getPendingRequests") && popup.harness.get("screen-idle").classList.contains("hidden") === false);
        assert.equal(popup.harness.get("idle-host").textContent, "wallet.example");
        browser.closePopup();
        assert.equal(scheduler.pending({owner: popup.owner}).length, 0);
        assert.equal(browser.profile().popup, null);
        browser.check();
    } finally { browser.close(); }
});

test("native reply scheduling identities remain bound to calls when completions arrive in reverse order", async () => {
    const runs = [];
    for (const order of [[1, 2], [2, 1]]) {
        const scheduler = new Scheduler;
        const flights = new Map([[1, deferred()], [2, deferred()]]);
        const trace = [];
        const browser = new BrowserLifecycle({scheduler, trace: event => trace.push(event), native: message => flights.get(message.id).promise});
        const promises = [1, 2].map(id => browser.nativeMessage({id: null}, "worker", {subject: "pollResponse", id,
            configurationKey: `https://${id}.example`}, () => true));
        await scheduler.drain();
        for (const id of order) { flights.get(id).resolve({id}); await scheduler.flush(); }
        await scheduler.drain();
        assert.deepEqual(await Promise.all(promises), [{id: 1}, {id: 2}]);
        runs.push(Object.fromEntries(trace.filter(event => event.channel === "native" && event.phase === "reply")
            .map(event => [event.message.id, event.transportKey])));
    }
    assert.deepEqual(runs[0], runs[1]);
    assert.notEqual(runs[0][1], runs[0][2]);
});

for (const kind of ["result", "error"]) {
    test(`page ${kind} replay keeps fault and delivery targets when requests finish in reverse order`, async () => {
        let saved;
        for (const order of [[0, 1], [1, 0]]) {
            const scheduler = new Scheduler;
            const trace = [], requests = [];
            const flights = [deferred(), deferred()];
            const address = "0x" + "1".repeat(40);
            const connected = {...state, revisions: {ethereum: 1, solana: 0}, ethereum: {address, chainId: "0x1"}};
            const browser = new BrowserLifecycle({scheduler, trace: event => trace.push(event), native: message => {
                if (message.subject === "getLatestConfiguration") { return {id: message.id, state: connected}; }
                if (message.subject) { return bootstrap(message); }
                requests.push(message);
                return flights[requests.length - 1].promise;
            }});
            const queue = browser.queue.bind(browser);
            browser.queue = (owner, channel, phase, message, ...rest) => {
                const key = queue(owner, channel, phase, message, ...rest);
                if (channel === "page" && phase === "reply" && message.response?.kind === kind) {
                    for (const task of scheduler.pending()) {
                        if (task.details.transportKey === key) { scheduler.hold(task.id); }
                    }
                }
                return key;
            };
            try {
                const tab = browser.openTab();
                await scheduler.until(() => browser.configurationReady(tab.id, connected));
                const operations = ["0x0102", "0x0304"].map(data => browser.request(tab.id, "ethereum", {
                    method: "personal_sign", params: [data, address],
                }));
                await scheduler.until(() => requests.length === 2);
                browser.addFault({channel: "page", phase: "reply", action: "delay", delay: 500, target: saved?.fault});
                for (const index of order) {
                    const request = requests[index];
                    flights[index].resolve({id: request.id, state: connected, response: {
                        id: request.id, provider: request.provider, name: request.name, kind,
                        ...(kind === "result" ? {result: "0x" + "11".repeat(65), approvalCommitted: true} :
                            {error: {code: 4001, message: "Rejected"}, approvalCommitted: false, authorizationFailure: false}),
                    }});
                    await scheduler.until(() => trace.some(event => event.channel === "page" && event.phase === "reply" &&
                        event.message.response?.id === request.id));
                }
                const fault = trace.find(event => event.fault);
                assert.equal(fault.message.response.id, operations[0].wireID);
                const delivery = scheduler.pending().find(task => saved ? task.key === saved.delivery :
                    task.details.transportKey === fault.transportKey);
                assert.ok(delivery);
                saved = {fault: fault.transportKey, delivery: delivery.key};
                scheduler.setClock(scheduler.now + 500);
                scheduler.release(delivery.id);
                await scheduler.deliver(delivery.id);
                assert.equal(operations[0].status, kind === "result" ? "fulfilled" : "rejected");
                assert.equal(operations[1].status, "pending");
                for (const task of scheduler.pending()) { scheduler.release(task.id); }
                await scheduler.drain();
                browser.check();
            } finally { browser.close(); }
        }
    });
}

test("configuration update and polling identities remain independent of generated IDs", () => {
    const runs = [1, 2].map(id => {
        const browser = new BrowserLifecycle({scheduler: new Scheduler});
        return [
            browser.queue("document", "page", "reply", {kind: "response", id,
                providerGeneration: "generation", response: {kind: "configuration", state}}, () => {}),
            browser.queue("worker", "native", "request", {subject: "getLatestConfiguration", id}, () => {}),
        ];
    });
    assert.deepEqual(runs[0], runs[1]);
});

test("duplicate native delivery does not create another user approval, but a second logical decision does", async () => {
    const scheduler = new Scheduler;
    const observed = [], delivered = [];
    const browser = new BrowserLifecycle({scheduler, onNative: event => observed.push(event), native: async message => {
        delivered.push(message);
        return {status: "ignored"};
    }});
    const message = {subject: "approveRequest", id: 1, requestToken: "request", reviewToken: "review", payload: {}};
    browser.addFault({channel: "native", phase: "request", action: "duplicate"});
    const first = browser.nativeMessage({id: null}, "popup", message, () => true);
    await scheduler.drain();
    await first;
    assert.equal(delivered.length, 2);
    assert.equal(observed.length, 1);
    const second = browser.nativeMessage({id: null}, "popup", message, () => true);
    await scheduler.drain();
    await second;
    assert.equal(delivered.length, 3);
    assert.equal(observed.length, 2);
    browser.check();
});

test("an approval observer failure remains fatal even when transport rejection is handled by the popup", async () => {
    const scheduler = new Scheduler;
    const failure = new LifecycleFailure("consent", "Invalid explicit approval");
    let sent = false;
    const browser = new BrowserLifecycle({scheduler, onNative: () => { throw failure; }, native: async () => { sent = true; }});
    await assert.rejects(browser.nativeMessage({id: null}, "popup", {subject: "approveRequest"}, () => true), error => error === failure);
    assert.throws(() => browser.check(), error => error === failure);
    assert.equal(sent, false);
    assert.equal(scheduler.pending().length, 0);
});

test("configuration readiness waits for the current native snapshot to reach the actual page provider", async () => {
    const scheduler = new Scheduler;
    let current = state;
    const browser = new BrowserLifecycle({scheduler, native: async message => message.subject === "getLatestConfiguration" ? {id: message.id, state: current} : bootstrap(message)});
    try {
        const tab = browser.openTab();
        await scheduler.until(() => browser.configurationReady(tab.id, current));
        current = {...state, revisions: {ethereum: 1, solana: 0}, ethereum: {address: "0x1111111111111111111111111111111111111111", chainId: "0x1"}};
        browser.focus(tab.id);
        assert.equal(browser.configurationReady(tab.id, current), false);
        await scheduler.until(() => tab.document.contentContext.bigWalletConfigurationState?.state.revisions.ethereum === 1);
        assert.equal(browser.configurationReady(tab.id, current), false);
        await scheduler.until(() => browser.configurationReady(tab.id, current));
        assert.equal(tab.document.pageWindow.ethereum.selectedAddress, current.ethereum.address);
    } finally { browser.close(); }
});

test("provider replacement loads fresh configuration before, during and after the initial read", async () => {
    for (const timing of ["beforeRead", "duringRead", "afterConfiguration"]) {
        const scheduler = new Scheduler;
        const initial = deferred();
        const refreshed = {...state, revisions: {ethereum: 1, solana: 0}, ethereum: {address: "", chainId: "0x539"}};
        let reads = 0;
        const browser = new BrowserLifecycle({scheduler, native: async message => {
            if (message.subject !== "getLatestConfiguration") { return bootstrap(message); }
            reads += 1;
            return {id: message.id, state: reads === 1 ? await initial.promise : refreshed};
        }});
        try {
            const tab = browser.openTab();
            if (timing === "duringRead") { await scheduler.until(() => reads === 1); }
            if (timing === "afterConfiguration") {
                initial.resolve(state);
                await scheduler.until(() => browser.configurationReady(tab.id, state));
            }
            const generation = tab.document.contentContext.bigWalletProviderGeneration;
            browser.replaceProvider(tab.id);
            const operation = browser.request(tab.id, "ethereum", {method: "eth_chainId"});
            initial.resolve(state);
            await scheduler.until(() => operation.status !== "pending" && browser.configurationReady(tab.id, refreshed));
            browser.check();
            assert.equal(operation.status, "fulfilled", timing);
            assert.equal(operation.result, "0x539", timing);
            assert.equal(reads, 2, timing);
            assert.notEqual(tab.document.contentContext.bigWalletProviderGeneration, generation, timing);
        } finally { browser.close(); }
    }
});

test("queued signing and disconnect calls keep distinct transport identities while configuration loads", async () => {
    const scheduler = new Scheduler;
    const trace = [];
    const connected = {...state, revisions: {ethereum: 0, solana: 1}, solana: {publicKey: "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk"}};
    const browser = new BrowserLifecycle({scheduler, trace: value => trace.push(value), native: async message => {
        if (message.subject === "getLatestConfiguration") { return {id: message.id, state: connected}; }
        if (message.subject === "getRecoveryRequests") { return {id: message.id, requests: []}; }
        return new Promise(() => {});
    }});
    try {
        const tab = browser.openTab();
        const signing = browser.request(tab.id, "solana", {method: "signMessage", params: {message: "0x010203", display: "hex"}});
        const disconnect = browser.request(tab.id, "solana", {method: "disconnect"});
        await scheduler.until(() => signing.wireID !== undefined && disconnect.wireID !== undefined);
        const messages = trace.filter(value => value.type === "browser-wire" && value.channel === "page" &&
            value.message?.direction === "big-wallet-provider-v1").map(value => value.message);
        assert.equal(signing.wireID, messages.find(value => value.kind === "request").message.id);
        assert.equal(disconnect.wireID, messages.find(value => value.kind === "disconnect").message.id);
        assert.equal(signing.wireKind, "request");
        assert.equal(disconnect.wireKind, "disconnect");
        assert.equal(signing.providerGeneration, messages.find(value => value.kind === "request").providerGeneration);
    } finally { browser.close(); }
});

test("overlapping calls of the same method retain FIFO payload identities after readiness", async () => {
    const scheduler = new Scheduler;
    const trace = [];
    const address = "0x1111111111111111111111111111111111111111";
    const connected = {...state, revisions: {ethereum: 1, solana: 0}, ethereum: {address, chainId: "0x1"}};
    const browser = new BrowserLifecycle({scheduler, trace: value => trace.push(value), native: async message => {
        if (message.subject === "getLatestConfiguration") { return {id: message.id, state: connected}; }
        if (message.subject === "getRecoveryRequests") { return {id: message.id, requests: []}; }
        return new Promise(() => {});
    }});
    try {
        const tab = browser.openTab();
        const local = browser.request(tab.id, "ethereum", {method: "eth_accounts"});
        const first = browser.request(tab.id, "ethereum", {method: "personal_sign", params: ["0x0102", address]});
        const second = browser.request(tab.id, "ethereum", {method: "personal_sign", params: ["0x0304", address]});
        await scheduler.until(() => first.wireID !== undefined && second.wireID !== undefined);
        const messages = trace.filter(value => value.type === "browser-wire" && value.channel === "page" &&
            value.message?.message?.name === "signPersonalMessage").map(value => value.message.message);
        assert.equal(local.wireID, undefined);
        assert.equal(messages.find(value => value.id === first.wireID).body.object.data, "0x0102");
        assert.equal(messages.find(value => value.id === second.wireID).body.object.data, "0x0304");
    } finally { browser.close(); }
});

test("locally rejected signing calls cannot consume a later request's transport identity", async () => {
    for (const afterReadiness of [false, true]) {
        const scheduler = new Scheduler;
        const address = "0x1111111111111111111111111111111111111111";
        const connected = {...state, revisions: {ethereum: 1, solana: 0}, ethereum: {address, chainId: "0x1"}};
        const signature = "0x" + "11".repeat(65);
        const nativeRequests = [];
        const settlements = [];
        const browser = new BrowserLifecycle({scheduler, onSettlement: operation => settlements.push(operation), native: async message => {
            if (message.subject === "getLatestConfiguration") { return {id: message.id, state: connected}; }
            if (message.subject === "getRecoveryRequests") { return {id: message.id, requests: []}; }
            assert.equal(message.name, "signPersonalMessage");
            nativeRequests.push(message);
            return {id: message.id, state: connected, response: {
                id: message.id, name: message.name, provider: "ethereum", kind: "result", result: signature, approvalCommitted: true,
            }};
        }});
        try {
            const tab = browser.openTab();
            if (afterReadiness) { await scheduler.until(() => browser.configurationReady(tab.id, connected)); }
            const invalid = browser.request(tab.id, "ethereum", {method: "personal_sign", params: []});
            const valid = browser.request(tab.id, "ethereum", {method: "personal_sign", params: ["0x0102", address]});
            await scheduler.until(() => invalid.status !== "pending" && valid.status !== "pending");
            browser.check();
            assert.equal(invalid.status, "rejected");
            assert.equal(invalid.error.code, -32602);
            assert.equal(invalid.wireID, undefined);
            assert.equal(valid.status, "fulfilled");
            assert.equal(valid.result, signature);
            assert.equal(nativeRequests.length, 1);
            assert.equal(valid.wireID, nativeRequests[0].id);
            assert.equal(valid.wireKind, "request");
            assert.deepEqual(settlements.map(operation => operation.label), [invalid.label, valid.label]);
        } finally { browser.close(); }
    }
});

test("signing expectations preserve the public Ethereum payload and account before provider emission", async () => {
    const address = "0x1111111111111111111111111111111111111111";
    const connected = {...state, revisions: {ethereum: 1, solana: 0}, ethereum: {address, chainId: "0x539"}};
    const typedData = {types: {EIP712Domain: []}, primaryType: "EIP712Domain", domain: {}, message: {value: 1}};
    const cases = [
        [{method: "personal_sign", params: ["0x010203", address]}, {data: "0x010203"}],
        ...["eth_signTypedData", "eth_signTypedData_v3", "eth_signTypedData_v4"].map(method => [
            {method, params: [address, JSON.stringify(typedData)]}, {raw: JSON.stringify(typedData)},
        ]),
        [{method: "eth_sendTransaction", params: [{from: address, to: address, value: "0x1"}]}, {from: address, to: address, value: "0x1"}],
    ];
    for (const afterReadiness of [false, true]) {
        const scheduler = new Scheduler;
        const browser = new BrowserLifecycle({scheduler, native: async message => {
            if (message.subject === "getLatestConfiguration") { return {id: message.id, state: connected}; }
            if (message.subject === "getRecoveryRequests") { return {id: message.id, requests: []}; }
            return new Promise(() => {});
        }});
        try {
            const tab = browser.openTab();
            if (afterReadiness) { await scheduler.until(() => browser.configurationReady(tab.id, connected)); }
            const queue = browser.queue.bind(browser);
            browser.queue = (owner, channel, phase, message, ...rest) => {
                if (channel === "page" && message.direction === "big-wallet-provider-v1" && message.kind === "request") {
                    message.message.body = {address: "0x" + "2".repeat(40), chainId: "0x1", object: {data: "0x090909", raw: "changed", value: "0x9"}};
                }
                return queue(owner, channel, phase, message, ...rest);
            };
            for (const [payload, expectedObject] of cases) {
                const operation = browser.request(tab.id, "ethereum", payload);
                await scheduler.until(() => operation.requestBody);
                browser.check();
                assert.deepEqual(operation.requestBody, {address, chainId: connected.ethereum.chainId, object: expectedObject});
            }
        } finally { browser.close(); }
    }
});

test("Solana signing expectations normalize original public bytes without trusting the emitted body", async () => {
    const publicKey = "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk";
    const connected = {...state, revisions: {ethereum: 0, solana: 1}, solana: {publicKey}};
    const bytes = Uint8Array.from([1, 2, 3]);
    const message = base58.encode(bytes);
    const cases = [
        [{method: "signMessage", params: {message: "010203", display: "hex"}}, {message: "0x010203", display: "hex", messageEncoding: "hex"}],
        [{method: "signMessage", params: {message: "hello", display: "UTF8"}}, {message: "hello", display: "UTF8", messageEncoding: "utf8"}],
        ...[bytes, bytes.buffer].map(message => [{method: "signMessage", params: {message}}, {message: "0x010203", messageEncoding: "hex"}]),
        ...[message, bytes, bytes.buffer].map(value => [{method: "signTransaction", params: {message: value}}, {message}]),
        [{method: "signAllTransactions", params: {message: [message, bytes]}}, {messages: [message, message]}],
        [{method: "signAllTransactions", params: {messages: [bytes.buffer, message]}}, {messages: [message, message]}],
        ...[message, bytes, bytes.buffer].map(transaction => [{method: "signAndSendTransaction", params: {transaction, options: {skipPreflight: false}}},
            {transaction: message, options: {skipPreflight: false}}]),
        [{method: "signAndSendTransaction", params: {message: bytes}}, {message}],
    ];
    for (const afterReadiness of [false, true]) {
        const scheduler = new Scheduler;
        const browser = new BrowserLifecycle({scheduler, native: async message => {
            if (message.subject === "getLatestConfiguration") { return {id: message.id, state: connected}; }
            if (message.subject === "getRecoveryRequests") { return {id: message.id, requests: []}; }
            return new Promise(() => {});
        }});
        try {
            const tab = browser.openTab();
            if (afterReadiness) { await scheduler.until(() => browser.configurationReady(tab.id, connected)); }
            const queue = browser.queue.bind(browser);
            browser.queue = (owner, channel, phase, envelope, ...rest) => {
                if (channel === "page" && envelope.direction === "big-wallet-provider-v1" && envelope.kind === "request") {
                    envelope.message.body.publicKey = "11111111111111111111111111111111";
                    envelope.message.body.object.params = {message: "0x090909", transaction: "changed"};
                }
                return queue(owner, channel, phase, envelope, ...rest);
            };
            for (const [payload, expectedParams] of cases) {
                const operation = browser.request(tab.id, "solana", payload);
                await scheduler.until(() => operation.requestBody);
                browser.check();
                assert.deepEqual(operation.requestBody, {publicKey, object: {id: operation.wireID, method: payload.method, params: expectedParams}});
            }
        } finally { browser.close(); }
    }
});
