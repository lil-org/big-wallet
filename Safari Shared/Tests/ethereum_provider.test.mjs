// ∅ 2026 lil org

import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { createRequire } from "node:module";
import test from "node:test";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const providerRequire = createRequire(
    new URL("../Inpage Provider/package.json", import.meta.url)
);
const { buildSync } = providerRequire("esbuild");
const providerDirectory = new URL("../Inpage Provider/", import.meta.url);

function bundle(entryPoint, format = "cjs") {
    return buildSync({
        bundle: true,
        entryPoints: [fileURLToPath(new URL(entryPoint, providerDirectory))],
        format,
        logLevel: "silent",
        platform: "browser",
        target: "safari15",
        write: false,
    }).outputFiles[0].text;
}

const operationRuntimeSource = bundle("operation_runtime.js");
const rpcSource = bundle("rpc.js");
const rpcResponseSource = bundle("rpc_response.js");
const ethereumSource = bundle("ethereum.js");
const solanaSource = bundle("solana.js");
const stableFacadesSource = bundle("stable_facades.js");
const inpageSource = bundle("index.js", "iife");

class HarnessEvent {
    constructor(type, options = {}) {
        this._type = type;
        Object.assign(this, options);
    }

    get type() { return this._type; }
}

class HarnessCustomEvent extends HarnessEvent {
    constructor(type, options = {}) {
        super(type, options);
        this.detail = options.detail;
    }
}

function moduleHarness(source, extraGlobals = {}) {
    const timers = [];
    const context = vm.createContext({
        clearTimeout() {},
        console: {error() {}, log() {}},
        CustomEvent: HarnessCustomEvent,
        Event: HarnessEvent,
        module: {exports: {}},
        setTimeout(callback) {
            timers.push(callback);
            return timers.length;
        },
        ...extraGlobals,
    });
    new vm.Script(source).runInContext(context);
    return {
        context,
        exports: context.module.exports,
        runTimers() {
            while (timers.length > 0) { timers.shift()(); }
        },
    };
}

function normalized(value) {
    return JSON.parse(JSON.stringify(value));
}

function ethereumHarness(initialState = null) {
    const module = moduleHarness(ethereumSource);
    const requests = [];
    const rpc = [];
    const disconnects = [];
    let current = true;
    let rpcObserver = null;
    const transport = {
        isCurrent() { return current; },
        postDisconnect(message) {
            disconnects.push(message);
            return current;
        },
        postRequest(message) {
            requests.push(message);
            return current;
        },
        postRPC(message, generation) {
            rpc.push({generation, message});
            rpcObserver?.(message, generation);
            return current;
        },
    };
    const Ethereum = module.exports.default;
    const provider = new Ethereum("ethereum-generation", transport, initialState);
    return {
        ...module,
        disconnects,
        Ethereum,
        provider,
        requests,
        rpc,
        setCurrent(value) { current = value; },
        setRPCObserver(value) { rpcObserver = value; },
    };
}

function solanaHarness(initialState = null) {
    const module = moduleHarness(solanaSource);
    const requests = [];
    const disconnects = [];
    const epochs = [];
    let current = true;
    let disconnectPost = true;
    let epochError = null;
    let epochPost = true;
    let requestPost = true;
    const transport = {
        isCurrent() { return current; },
        postDisconnect(message) {
            disconnects.push(message);
            return current && disconnectPost;
        },
        postRequest(message) {
            requests.push(message);
            return current && requestPost;
        },
        synchronizeSolanaEpoch(epoch) {
            epochs.push(epoch);
            if (epochError) { throw epochError; }
            return current && epochPost;
        },
    };
    const Solana = module.exports.default;
    const provider = new Solana("solana-generation", transport, initialState);
    return {
        ...module,
        disconnects,
        epochs,
        provider,
        requests,
        setCurrent(value) { current = value; },
        setDisconnectPost(value) { disconnectPost = value; },
        setEpochError(value) { epochError = value; },
        setEpochPost(value) { epochPost = value; },
        setRequestPost(value) { requestPost = value; },
        Solana,
    };
}

function applyEthereumConfiguration(harness, address = "", chainId = "0x1") {
    return harness.Ethereum.applyEnvelope(harness.provider, {
        kind: "configuration",
        configuration: {address, chainId},
    });
}

const firstSolanaKey = "11111111111111111111111111111111";
const secondSolanaKey = "So11111111111111111111111111111111111111112";
const validSignature = "1".repeat(64);

function applySolanaConfiguration(
    harness,
    {
        accountRevision = 0,
        isConnected = false,
        publicKey = null,
        solanaAuthorizationEpoch = 0,
        ...envelope
    } = {}
) {
    return harness.Solana.applyEnvelope(harness.provider, {
        kind: "configuration",
        configuration: {
            accountRevision,
            isConnected,
            publicKey,
            solanaAuthorizationEpoch,
        },
        ...envelope,
    });
}

function publicKey(value = firstSolanaKey) {
    return {toString() { return value; }};
}

function legacyTransaction(byte, signature = null) {
    const entry = {publicKey: publicKey(), signature};
    return {
        entry,
        transaction: {
            signatures: [entry],
            serializeMessage() { return new Uint8Array([byte]); },
        },
    };
}

function versionedTransaction(byte) {
    const signatures = [new Uint8Array(64)];
    return {
        signatures,
        transaction: {
            message: {
                header: {numRequiredSignatures: 1},
                staticAccountKeys: [publicKey()],
                serialize() { return new Uint8Array([byte]); },
            },
            signatures,
        },
    };
}

test("OperationRuntime owns exact records and never reuses wire IDs", async () => {
    const {exports} = moduleHarness(operationRuntimeSource);
    const Runtime = exports.default;
    const runtime = new Runtime("runtime-generation");
    const callerPayload = {method: "first"};
    const first = runtime.register({originalId: 7, payload: callerPayload});
    const second = runtime.register({originalId: 7, payload: {method: "second"}});

    assert.equal(first.wireId, 1);
    assert.equal(second.wireId, 2);
    assert.equal(first.payload, callerPayload);
    assert.deepEqual(callerPayload, {method: "first"});
    assert.equal(runtime.owns({...first}), false);
    assert.equal(runtime.operation(1), first);

    let replacement;
    const thenable = {};
    Object.defineProperty(thenable, "then", {
        get() {
            assert.equal(runtime.owns(first), false);
            if (!replacement) {
                replacement = runtime.register({
                    originalId: 7,
                    payload: {method: "replacement"},
                });
            }
            return undefined;
        },
    });
    assert.equal(first.resolve(thenable), true);
    assert.equal((await first.promise), thenable);
    assert.equal(replacement.wireId, 3);
    assert.equal(runtime.owns(replacement), true);
    second.resolve("second");
    replacement.resolve("replacement");
    assert.equal(await second.promise, "second");
    assert.equal(await replacement.promise, "replacement");
});

test("OperationRuntime supports provider-distinct monotonic wire IDs", async () => {
    const {exports} = moduleHarness(operationRuntimeSource);
    const Runtime = exports.default;
    const runtime = new Runtime("runtime-generation", {
        firstWireId: 2,
        wireIdStep: 2,
    });
    const first = runtime.register({payload: {}});
    const second = runtime.register({payload: {}});
    assert.deepEqual([first.wireId, second.wireId], [2, 4]);
    first.resolve(true);
    second.resolve(true);
    await Promise.all([first.promise, second.promise]);
});

test("OperationRuntime bounds loading admissions and resets after draining", async () => {
    const {exports} = moduleHarness(operationRuntimeSource);
    const Runtime = exports.default;
    assert.equal(Runtime.maximumLoadingOperations, 64);
    assert.throws(
        () => new Runtime("runtime-generation", {maximumLoadingOperations: 0}),
        /options/
    );
    const runtime = new Runtime("runtime-generation", {
        maximumLoadingOperations: 2,
    });
    const first = runtime.register({payload: {name: "first"}});
    const second = runtime.register({payload: {name: "second"}});
    const overflow = runtime.register({payload: {name: "overflow"}});
    const overflowFailure = overflow.promise.catch(error => error.message);

    assert.equal(runtime.enqueue(first), true);
    assert.equal(runtime.enqueue(second), true);
    assert.equal(runtime.enqueue(overflow), false);
    overflow.reject(new Error("loading limit"));

    const order = [];
    runtime.drain(record => {
        order.push(record.payload.name);
        record.resolve(true);
    });
    assert.deepEqual(order, ["first", "second"]);
    assert.equal(await overflowFailure, "loading limit");
    assert.deepEqual(await Promise.all([first.promise, second.promise]), [true, true]);
    assert.equal(runtime.phase, "ready");

    const ready = runtime.register({payload: {name: "ready"}});
    assert.equal(runtime.enqueue(ready), false);
    ready.resolve(true);
    assert.equal(await ready.promise, true);
});

test("OperationRuntime counts reentrant loading admissions in one FIFO", async () => {
    const {exports} = moduleHarness(operationRuntimeSource);
    const Runtime = exports.default;
    const runtime = new Runtime("runtime-generation", {
        maximumLoadingOperations: 2,
    });
    const first = runtime.register({payload: {name: "first"}});
    assert.equal(runtime.enqueue(first), true);
    const order = [];
    let reentrant;
    let overflow;
    let overflowFailure;

    runtime.drain(record => {
        order.push(record.payload.name);
        if (record === first) {
            reentrant = runtime.register({payload: {name: "reentrant"}});
            assert.equal(runtime.enqueue(reentrant), true);
            overflow = runtime.register({payload: {name: "overflow"}});
            overflowFailure = overflow.promise.catch(error => error.message);
            assert.equal(runtime.enqueue(overflow), false);
            overflow.reject(new Error("loading limit"));
        }
        record.resolve(true);
    });

    assert.deepEqual(order, ["first", "reentrant"]);
    assert.equal(await first.promise, true);
    assert.equal(await reentrant.promise, true);
    assert.equal(await overflowFailure, "loading limit");
});

test("OperationRuntime drains work admitted after a reentrant reset", async () => {
    const {exports} = moduleHarness(operationRuntimeSource);
    const Runtime = exports.default;
    const runtime = new Runtime("runtime-generation");
    const first = runtime.register({payload: {name: "first"}});
    const queued = runtime.register({payload: {name: "queued"}});
    const firstFailure = first.promise.catch(error => error.message);
    const queuedFailure = queued.promise.catch(error => error.message);
    assert.equal(runtime.enqueue(first), true);
    assert.equal(runtime.enqueue(queued), true);
    let reentrant;
    const order = [];

    runtime.drain(record => {
        order.push(record.payload.name);
        if (record === first) {
            runtime.rejectAll(new Error("reset"));
            reentrant = runtime.register({payload: {name: "reentrant"}});
            assert.equal(runtime.enqueue(reentrant), true);
        } else {
            record.resolve(true);
        }
    });

    assert.deepEqual(order, ["first", "reentrant"]);
    assert.equal(await firstFailure, "reset");
    assert.equal(await queuedFailure, "reset");
    assert.equal(await reentrant.promise, true);
    assert.equal(runtime.phase, "ready");
});

test("OperationRuntime handles getter reentry and drains a reentrant FIFO", async () => {
    const {exports} = moduleHarness(operationRuntimeSource);
    const Runtime = exports.default;
    const runtime = new Runtime("runtime-generation");
    let nested;
    const outer = runtime.register({
        get originalId() {
            nested = runtime.register({originalId: 1, payload: {name: "nested"}});
            return 1;
        },
        payload: {name: "outer"},
    });
    assert.deepEqual([nested.wireId, outer.wireId], [1, 2]);
    runtime.enqueue(nested);
    runtime.enqueue(outer);
    const failed = outer.promise.catch(error => error.message);
    let reentrant;
    const order = [];
    runtime.drain(record => {
        order.push(record.payload.name);
        if (record === nested) {
            reentrant = runtime.register({
                originalId: 1,
                payload: {name: "reentrant"},
            });
            assert.equal(runtime.enqueue(reentrant), true);
            record.resolve(true);
        } else if (record === outer) {
            throw new Error("dispatch failed");
        } else {
            record.resolve(true);
        }
    });

    assert.deepEqual(order, ["nested", "outer", "reentrant"]);
    assert.equal(runtime.phase, "ready");
    assert.equal(await failed, "dispatch failed");
    assert.equal(await nested.promise, true);
    assert.equal(await reentrant.promise, true);
});

test("OperationRuntime rejects all, retires, and keeps IDs monotonic", async () => {
    const {exports} = moduleHarness(operationRuntimeSource);
    const Runtime = exports.default;
    const runtime = new Runtime("runtime-generation");
    const first = runtime.register({payload: {}});
    const firstRejected = first.promise.catch(error => error.message);
    assert.equal(runtime.rejectAll(new Error("reset")), 1);
    assert.equal(await firstRejected, "reset");
    const second = runtime.register({payload: {}});
    assert.equal(second.wireId, 2);
    const secondRejected = second.promise.catch(error => error.message);
    assert.equal(runtime.retire(new Error("retired")), 1);
    assert.equal(await secondRejected, "retired");
    assert.equal(runtime.phase, "retired");
    assert.throws(() => runtime.register({payload: {}}), /retired/);
});

test("RPC replies canonicalize own terminals and fail malformed correlations", () => {
    const {exports} = moduleHarness(rpcResponseSource);
    const normalize = exports.normalizedRPCResponse;
    assert.deepEqual(normalized(normalize({id: 4, result: {value: 1}}, 4)), {
        id: 4,
        result: {value: 1},
    });
    for (const response of [
        {id: 4},
        {error: "failed", id: 4, result: true},
    ]) {
        assert.equal(normalize(response, 4).error.code, -32603);
    }
    const inherited = Object.create({
        get result() { throw new Error("inherited result read"); },
    });
    inherited.id = 4;
    assert.equal(normalize(inherited, 4).error.code, -32603);
    assert.deepEqual(normalized(normalize({id: 5, result: true}, 4)), {
        error: {
            code: -32603,
            message: "Failed to process RPC response",
        },
        id: 4,
    });
});

test("RPCServer reports a false generation-bound transport result", () => {
    const {exports} = moduleHarness(rpcSource);
    const RPCServer = exports.default;
    const server = new RPCServer("0x1", "generation", () => false);
    const payload = {id: 1, method: "eth_blockNumber", params: []};
    assert.equal(server.call(payload, () => true), false);
    assert.deepEqual(payload, {
        id: 1,
        method: "eth_blockNumber",
        params: [],
    });
});

test("Ethereum waits for configuration and supports local and RPC methods", async () => {
    const harness = ethereumHarness();
    const chain = harness.provider.request({id: 1, method: "eth_chainId"});
    const accounts = harness.provider.request({id: 2, method: "eth_accounts"});
    const block = harness.provider.request({
        id: 3,
        method: "eth_blockNumber",
        params: [],
    });

    assert.equal(harness.Ethereum.isReady(harness.provider), false);
    assert.equal(harness.rpc.length, 0);
    applyEthereumConfiguration(harness, "", "0x2");
    assert.equal(await chain, "0x2");
    assert.deepEqual(normalized(await accounts), []);
    assert.equal(harness.rpc.length, 1);
    assert.equal(harness.rpc[0].generation, "ethereum-generation");
    assert.deepEqual(JSON.parse(harness.rpc[0].message.body), {
        id: harness.rpc[0].message.id,
        jsonrpc: "2.0",
        method: "eth_blockNumber",
        params: [],
    });
    harness.Ethereum.applyEnvelope(harness.provider, {
        id: harness.rpc[0].message.id,
        kind: "result",
        result: "0x10",
    });
    assert.equal(await block, "0x10");
});

test("Ethereum bounds loading work without retiring the ready provider", async () => {
    const harness = ethereumHarness();
    const requests = Array.from({length: 65}, () => {
        return harness.provider.request({method: "eth_chainId"});
    });
    const overflow = assert.rejects(requests[64], error => error.code === 4900);

    applyEthereumConfiguration(harness, "", "0x2");
    assert.deepEqual(
        await Promise.all(requests.slice(0, 64)),
        Array(64).fill("0x2")
    );
    await overflow;
    assert.equal(await harness.provider.request({method: "eth_chainId"}), "0x2");
});

test("Ethereum ignores terminal envelopes until an operation is dispatched", async () => {
    const harness = ethereumHarness();
    const request = harness.provider.request({
        method: "eth_sendTransaction",
        params: [{value: "0x1"}],
    });
    assert.equal(harness.Ethereum.applyEnvelope(harness.provider, {
        id: 1,
        kind: "result",
        name: "signTransaction",
        result: "forged",
    }), false);
    assert.equal(harness.requests.length, 0);
    applyEthereumConfiguration(harness);
    assert.equal(harness.requests.length, 1);
    harness.Ethereum.applyEnvelope(harness.provider, {
        id: harness.requests[0].id,
        kind: "result",
        name: "signTransaction",
        result: "0xhash",
    });
    assert.equal(await request, "0xhash");
});

test("Ethereum rejects wallet-named terminals for RPC operations", async () => {
    const harness = ethereumHarness();
    applyEthereumConfiguration(harness);
    const address = "0x0000000000000000000000000000000000000001";
    const request = harness.provider.request({
        method: "eth_blockNumber",
        params: [],
    });
    harness.Ethereum.applyEnvelope(harness.provider, {
        id: harness.rpc[0].message.id,
        kind: "result",
        name: "requestAccounts",
        result: [address],
    });
    await assert.rejects(request, error => error.code === -32603);
    assert.equal(harness.provider.selectedAddress, null);
});

test("Ethereum keeps the standard legacy adapters and public properties", async () => {
    const harness = ethereumHarness();
    const sent = harness.provider.send({id: 10, method: "eth_chainId"});
    const asyncResponse = new Promise((resolve, reject) => {
        harness.provider.sendAsync(
            {id: "async", method: "eth_accounts"},
            (error, result) => error ? reject(error) : resolve(result)
        );
    });
    applyEthereumConfiguration(harness, "", "0xa");
    assert.equal(await sent, "0xa");
    assert.deepEqual(normalized(await asyncResponse), {
        id: "async",
        jsonrpc: "2.0",
        result: [],
    });
    assert.equal(harness.provider.isMetaMask, true);
    assert.equal(harness.provider.isBigWallet, true);
    assert.equal(harness.provider.networkVersion, "10");
    assert.equal(harness.provider.selectedAddress, null);
    assert.equal(harness.provider.isConnected(), true);
    assert.equal(await harness.provider.isUnlocked(), true);

    const enabled = harness.provider.enable();
    assert.equal(harness.requests.at(-1).name, "requestAccounts");
    harness.Ethereum.applyEnvelope(harness.provider, {
        id: harness.requests.at(-1).id,
        kind: "result",
        name: "requestAccounts",
        result: ["0x0000000000000000000000000000000000000001"],
    });
    assert.deepEqual(normalized(await enabled), [
        "0x0000000000000000000000000000000000000001",
    ]);
});

test("Ethereum exposes exact network versions for large chain IDs", async () => {
    const harness = ethereumHarness();
    applyEthereumConfiguration(harness, "", "0x1");
    const networkChanges = [];
    harness.provider.on("networkChanged", networkVersion => {
        networkChanges.push(networkVersion);
    });

    applyEthereumConfiguration(harness, "", "0x20000000000001");
    assert.equal(harness.provider.networkVersion, "9007199254740993");
    assert.equal(
        await harness.provider.request({method: "net_version"}),
        "9007199254740993"
    );

    applyEthereumConfiguration(harness, "", "0x7fffffffffffffff");
    assert.equal(harness.provider.networkVersion, "9223372036854775807");
    assert.equal(
        await harness.provider.request({method: "net_version"}),
        "9223372036854775807"
    );
    assert.deepEqual(networkChanges, [
        "9007199254740993",
        "9223372036854775807",
    ]);
});

test("Ethereum preserves native JSON semantics without mutating callers", async () => {
    const harness = ethereumHarness();
    applyEthereumConfiguration(harness);
    const boxed = new Number(3);
    boxed.valueOf = () => 4;
    const params = [{
        boxed,
        custom: {toJSON() { return {value: 5}; }},
        date: new Date("2026-08-23T00:00:00.000Z"),
        sparse: [, undefined, 3],
    }];
    const request = harness.provider.request({
        id: "native-json",
        method: "eth_custom",
        params,
    });
    const body = JSON.parse(harness.rpc[0].message.body);
    assert.deepEqual(body.params, [{
        boxed: 4,
        custom: {value: 5},
        date: "2026-08-23T00:00:00.000Z",
        sparse: [null, null, 3],
    }]);
    assert.equal(Object.hasOwn(params, "jsonrpc"), false);
    harness.Ethereum.applyEnvelope(harness.provider, {
        id: harness.rpc[0].message.id,
        kind: "result",
        result: true,
    });
    assert.equal(await request, true);

    const cycle = {};
    cycle.self = cycle;
    await assert.rejects(
        harness.provider.request({method: "eth_custom", params: [cycle]}),
        error => error.code === -32602
    );
    await assert.rejects(
        harness.provider.request({method: "eth_custom", params: [1n]}),
        error => error.code === -32602
    );
    assert.equal(harness.rpc.length, 1);
});

test("queued Ethereum snapshots ignore later inherited toJSON changes", async () => {
    const harness = ethereumHarness();
    const rpcRequest = harness.provider.request({
        method: "eth_custom",
        params: [{value: 1}],
    });
    const walletRequest = harness.provider.request({
        method: "eth_sendTransaction",
        params: [{value: "0x1"}],
    });
    const objectPrototype = vm.runInContext("Object.prototype", harness.context);
    const arrayPrototype = vm.runInContext("Array.prototype", harness.context);
    const objectToJSON = Object.getOwnPropertyDescriptor(
        objectPrototype,
        "toJSON"
    );
    const arrayToJSON = Object.getOwnPropertyDescriptor(
        arrayPrototype,
        "toJSON"
    );
    Object.defineProperty(objectPrototype, "toJSON", {
        configurable: true,
        value() { return 7; },
        writable: true,
    });
    Object.defineProperty(arrayPrototype, "toJSON", {
        configurable: true,
        value() { return 7; },
        writable: true,
    });
    try {
        applyEthereumConfiguration(harness);
        assert.deepEqual(JSON.parse(harness.rpc[0].message.body).params, [
            {value: 1},
        ]);
        assert.deepEqual(normalized(harness.requests[0].data), {value: "0x1"});
        harness.Ethereum.applyEnvelope(harness.provider, {
            id: harness.rpc[0].message.id,
            kind: "result",
            result: true,
        });
        harness.Ethereum.applyEnvelope(harness.provider, {
            id: harness.requests[0].id,
            kind: "result",
            name: "signTransaction",
            result: "0xhash",
        });
        assert.equal(await rpcRequest, true);
        assert.equal(await walletRequest, "0xhash");
    } finally {
        if (objectToJSON) {
            Object.defineProperty(objectPrototype, "toJSON", objectToJSON);
        } else {
            delete objectPrototype.toJSON;
        }
        if (arrayToJSON) {
            Object.defineProperty(arrayPrototype, "toJSON", arrayToJSON);
        } else {
            delete arrayPrototype.toJSON;
        }
    }
});

test("Ethereum returns faithful native JSON object shapes", async () => {
    const harness = ethereumHarness();
    applyEthereumConfiguration(harness);
    const request = harness.provider.request({
        method: "eth_getBlockByNumber",
        params: ["latest", false],
    });
    harness.Ethereum.applyEnvelope(harness.provider, {
        id: harness.rpc[0].message.id,
        kind: "result",
        result: {number: "0x1"},
    });
    const result = await request;
    assert.deepEqual(Object.getOwnPropertyNames(result), ["number"]);
    assert.equal(Object.hasOwn(result, "toJSON"), false);
});

test("Ethereum emits authoritative deltas from copied state", () => {
    const firstAddress = "0x0000000000000000000000000000000000000001";
    const secondAddress = "0x0000000000000000000000000000000000000002";
    const harness = ethereumHarness({
        accountRevision: 1,
        accountRevocationTombstone: false,
        address: firstAddress,
        chainId: "0x1",
        didEmitConnect: true,
    });
    const events = [];
    harness.provider.on("accountsChanged", accounts => {
        events.push(["accountsChanged", normalized(accounts)]);
    });
    harness.provider.on("chainChanged", chainId => {
        events.push(["chainChanged", chainId]);
    });
    applyEthereumConfiguration(harness, secondAddress, "0x2");
    assert.deepEqual(events, [
        ["accountsChanged", [secondAddress]],
        ["chainChanged", "0x2"],
    ]);
});

test("Ethereum compares reentrant first-drain state to the copied baseline", async () => {
    const firstAddress = "0x0000000000000000000000000000000000000001";
    const secondAddress = "0x0000000000000000000000000000000000000002";
    for (const testCase of [{
        nestedAddress: secondAddress,
        nestedChainId: "0x2",
        expected: [
            ["accountsChanged", [secondAddress]],
            ["chainChanged", "0x2"],
        ],
    }, {
        nestedAddress: firstAddress,
        nestedChainId: "0x1",
        expected: [],
    }, {
        nestedAddress: firstAddress,
        nestedChainId: "0x1",
        suppressUpdate: true,
        expected: [
            ["accountsChanged", [secondAddress]],
            ["chainChanged", "0x2"],
        ],
    }]) {
        const harness = ethereumHarness({
            accountRevision: 1,
            accountRevocationTombstone: false,
            address: firstAddress,
            chainId: "0x1",
            didEmitConnect: true,
        });
        const events = [];
        harness.provider.on("accountsChanged", accounts => {
            events.push(["accountsChanged", normalized(accounts)]);
        });
        harness.provider.on("chainChanged", chainId => {
            events.push(["chainChanged", chainId]);
        });
        const request = harness.provider.request({
            method: "eth_blockNumber",
            params: [],
        });
        let reentered = false;
        harness.setRPCObserver(() => {
            if (reentered) { return; }
            reentered = true;
            harness.Ethereum.applyEnvelope(harness.provider, {
                configuration: {
                    address: testCase.nestedAddress,
                    chainId: testCase.nestedChainId,
                },
                kind: "configuration",
                suppressUpdate: testCase.suppressUpdate,
            });
        });
        applyEthereumConfiguration(harness, secondAddress, "0x2");
        assert.deepEqual(events, testCase.expected);
        harness.Ethereum.applyEnvelope(harness.provider, {
            id: harness.rpc[0].message.id,
            kind: "result",
            result: true,
        });
        assert.equal(await request, true);
    }
});

test("Ethereum retains its copied baseline through malformed first-drain state", async () => {
    const firstAddress = "0x0000000000000000000000000000000000000001";
    const secondAddress = "0x0000000000000000000000000000000000000002";
    const harness = ethereumHarness({
        accountRevision: 1,
        accountRevocationTombstone: false,
        address: firstAddress,
        chainId: "0x1",
        didEmitConnect: true,
    });
    const events = [];
    harness.provider.on("accountsChanged", accounts => {
        events.push(["accountsChanged", normalized(accounts)]);
    });
    harness.provider.on("chainChanged", chainId => {
        events.push(["chainChanged", chainId]);
    });
    const request = harness.provider.request({
        method: "eth_blockNumber",
        params: [],
    });
    const rejected = assert.rejects(request, error => error.code === -32603);
    harness.setRPCObserver(() => {
        harness.Ethereum.applyEnvelope(harness.provider, {
            configuration: null,
            kind: "configuration",
        });
    });
    applyEthereumConfiguration(harness, secondAddress, "0x2");
    await rejected;
    assert.deepEqual(events, []);
    applyEthereumConfiguration(harness, secondAddress, "0x2");
    assert.deepEqual(events, [
        ["accountsChanged", [secondAddress]],
        ["chainChanged", "0x2"],
    ]);
});

test("Ethereum emits guarded state changes and keeps the newest epoch", () => {
    const harness = ethereumHarness();
    const firstAddress = "0x0000000000000000000000000000000000000001";
    const secondAddress = "0x0000000000000000000000000000000000000002";
    const thirdAddress = "0x0000000000000000000000000000000000000003";
    applyEthereumConfiguration(harness, firstAddress, "0x1");
    let laterListener = 0;
    harness.provider.on("accountsChanged", () => {
        throw new Error("listener failed");
    });
    harness.provider.on("accountsChanged", () => {
        laterListener += 1;
    });
    harness.Ethereum.applyEnvelope(harness.provider, {
        kind: "configuration",
        switchAccount: true,
        configuration: {address: secondAddress, chainId: "0x2"},
    });
    assert.equal(laterListener, 1);
    assert.equal(harness.provider.selectedAddress, secondAddress);

    const reentrant = {
        toJSON() {
            harness.Ethereum.applyEnvelope(harness.provider, {
                kind: "configuration",
                switchAccount: true,
                configuration: {address: thirdAddress, chainId: "0x3"},
            });
            return {address: firstAddress, chainId: "0x4"};
        },
    };
    assert.equal(harness.Ethereum.applyEnvelope(harness.provider, {
        kind: "configuration",
        switchAccount: true,
        configuration: reentrant,
    }), false);
    assert.equal(harness.provider.selectedAddress, thirdAddress);
    assert.equal(harness.provider.chainId, "0x3");
});

test("Ethereum posts wallet requests, settles errors, and retires with 4900", async () => {
    const harness = ethereumHarness();
    applyEthereumConfiguration(harness);
    const transaction = {from: "0x0", value: "0x1"};
    const request = harness.provider.request({
        id: 8,
        method: "eth_sendTransaction",
        params: [transaction],
    });
    assert.equal(harness.requests[0].name, "signTransaction");
    assert.deepEqual(normalized(harness.requests[0].data), transaction);
    harness.Ethereum.applyEnvelope(harness.provider, {
        id: harness.requests[0].id,
        kind: "error",
        name: "signTransaction",
        error: {code: 4001, message: "Canceled"},
    });
    await assert.rejects(request, error => error.code === 4001);

    const pending = harness.provider.request({
        method: "personal_sign",
        params: ["0x01"],
    });
    assert.equal(harness.Ethereum.retire(harness.provider), true);
    await assert.rejects(pending, error => error.code === 4900);
    assert.equal(harness.provider.isConnected(), false);
    assert.equal(harness.Ethereum.snapshot(harness.provider).phase, "retired");
    assert.equal(harness.Ethereum.applyEnvelope(harness.provider, {
        id: harness.requests.at(-1).id,
        kind: "result",
        name: harness.requests.at(-1).name,
        result: "late",
    }), false);
});

test("Ethereum authorization failures revoke only their captured account", async () => {
    const harness = ethereumHarness();
    const address = "0x0000000000000000000000000000000000000001";
    applyEthereumConfiguration(harness, address);
    const request = harness.provider.request({
        method: "eth_blockNumber",
        params: [],
    });
    harness.Ethereum.applyEnvelope(harness.provider, {
        authorizationFailure: true,
        error: {code: 4100, message: "Unauthorized"},
        id: harness.rpc[0].message.id,
        kind: "error",
    });
    await assert.rejects(request, error => error.code === 4100);
    assert.equal(harness.provider.selectedAddress, null);

    const currentAddress = "0x0000000000000000000000000000000000000002";
    applyEthereumConfiguration(harness, currentAddress);
    const stale = harness.provider.request({
        method: "eth_blockNumber",
        params: [],
    });
    harness.Ethereum.applyEnvelope(harness.provider, {
        kind: "configuration",
        switchAccount: true,
        configuration: {address: currentAddress, chainId: "0x2"},
    });
    harness.Ethereum.applyEnvelope(harness.provider, {
        authorizationFailure: true,
        error: {code: 4100, message: "Stale unauthorized"},
        id: harness.rpc.at(-1).message.id,
        kind: "error",
    });
    await assert.rejects(stale, error => error.code === 4100);
    assert.equal(harness.provider.selectedAddress, currentAddress);
});

test("Ethereum chain responses update only an already-authorized account", async () => {
    const firstAddress = "0x0000000000000000000000000000000000000001";
    const secondAddress = "0x0000000000000000000000000000000000000002";
    for (const method of [
        "wallet_switchEthereumChain",
        "wallet_addEthereumChain",
    ]) {
        const harness = ethereumHarness();
        applyEthereumConfiguration(harness, firstAddress, "0x1");
        const events = [];
        harness.provider.on("accountsChanged", accounts => {
            events.push(["accountsChanged", normalized(accounts)]);
        });
        harness.provider.on("chainChanged", chainId => {
            events.push(["chainChanged", chainId]);
        });
        const request = harness.provider.request({
            method,
            params: [{chainId: "0x2"}],
        });
        const message = harness.requests[0];
        harness.Ethereum.applyEnvelope(harness.provider, {
            id: message.id,
            kind: "result",
            name: message.name,
            result: [secondAddress],
        });
        assert.deepEqual(normalized(await request), [secondAddress]);
        assert.equal(harness.provider.selectedAddress, secondAddress);
        assert.equal(harness.provider.chainId, "0x2");
        assert.deepEqual(events, [
            ["accountsChanged", [secondAddress]],
            ["chainChanged", "0x2"],
        ]);

        events.length = 0;
        const accountlessResult = harness.provider.request({
            method,
            params: [{chainId: "0x3"}],
        });
        const accountlessMessage = harness.requests.at(-1);
        harness.Ethereum.applyEnvelope(harness.provider, {
            id: accountlessMessage.id,
            kind: "result",
            name: accountlessMessage.name,
            result: [],
        });
        assert.deepEqual(normalized(await accountlessResult), []);
        assert.equal(harness.provider.selectedAddress, null);
        assert.equal(harness.provider.chainId, "0x3");
        assert.deepEqual(events, [
            ["accountsChanged", []],
            ["chainChanged", "0x3"],
        ]);
    }

    const accountless = ethereumHarness();
    applyEthereumConfiguration(accountless, "", "0x1");
    const accountEvents = [];
    accountless.provider.on("accountsChanged", accounts => {
        accountEvents.push(normalized(accounts));
    });
    const request = accountless.provider.request({
        method: "wallet_switchEthereumChain",
        params: [{chainId: "0x2"}],
    });
    accountless.Ethereum.applyEnvelope(accountless.provider, {
        id: accountless.requests[0].id,
        kind: "result",
        name: accountless.requests[0].name,
        result: [secondAddress],
    });
    assert.deepEqual(normalized(await request), [secondAddress]);
    assert.equal(accountless.provider.selectedAddress, null);
    assert.equal(accountless.provider.chainId, "0x2");
    assert.deepEqual(accountEvents, []);
});

test("Ethereum rejects noncanonical chain IDs before wallet transport", async () => {
    const invalidChainIds = [
        "0xA",
        "0x01",
        "0x0",
        "0x8000000000000000",
    ];
    for (const method of [
        "wallet_addEthereumChain",
        "wallet_switchEthereumChain",
    ]) {
        const harness = ethereumHarness();
        applyEthereumConfiguration(harness);
        for (const chainId of invalidChainIds) {
            const requestCount = harness.requests.length;
            await assert.rejects(
                harness.provider.request({
                    method,
                    params: [{chainId}],
                }),
                error => error.code === -32602,
                `${method} ${chainId}`
            );
            assert.equal(harness.requests.length, requestCount);
        }
    }
});

test("Ethereum rejects malformed account-bearing results without state changes", async () => {
    const address = "0x0000000000000000000000000000000000000001";
    const accountsHarness = ethereumHarness();
    applyEthereumConfiguration(accountsHarness);
    const accounts = accountsHarness.provider.request({
        method: "eth_requestAccounts",
        params: [],
    });
    accountsHarness.Ethereum.applyEnvelope(accountsHarness.provider, {
        id: accountsHarness.requests[0].id,
        kind: "result",
        name: "requestAccounts",
        result: "invalid",
    });
    await assert.rejects(accounts, error => error.code === -32603);
    assert.equal(accountsHarness.provider.selectedAddress, null);

    const chainHarness = ethereumHarness();
    applyEthereumConfiguration(chainHarness, address, "0x1");
    const chain = chainHarness.provider.request({
        method: "wallet_switchEthereumChain",
        params: [{chainId: "0x2"}],
    });
    chainHarness.Ethereum.applyEnvelope(chainHarness.provider, {
        id: chainHarness.requests[0].id,
        kind: "result",
        name: "switchEthereumChain",
        result: "invalid",
    });
    await assert.rejects(chain, error => error.code === -32603);
    assert.equal(chainHarness.provider.chainId, "0x1");
    assert.equal(chainHarness.provider.selectedAddress, address);
});

test("Ethereum request normalization cannot bypass a configuration failure", async () => {
    const harness = ethereumHarness();
    applyEthereumConfiguration(harness);
    const trigger = {
        toJSON() {
            harness.Ethereum.applyEnvelope(harness.provider, {
                kind: "configuration",
                configuration: null,
            });
            return {};
        },
    };
    const request = harness.provider.request({
        method: "eth_custom",
        params: [trigger],
    });
    await assert.rejects(request, error => error.code === -32603);
    assert.equal(harness.rpc.length, 0);
    assert.equal(harness.Ethereum.isReady(harness.provider), false);
});

test("Ethereum retires queued work when normalization sees stale transport", async () => {
    const harness = ethereumHarness();
    const queued = harness.provider.request({method: "eth_chainId"});
    const queuedRejected = assert.rejects(
        queued,
        error => error.code === 4900
    );
    const current = harness.provider.request({
        method: "eth_custom",
        params: [{
            toJSON() {
                harness.setCurrent(false);
                return {value: 1};
            },
        }],
    });
    await Promise.all([
        queuedRejected,
        assert.rejects(current, error => error.code === 4900),
    ]);
    assert.equal(harness.Ethereum.snapshot(harness.provider).phase, "retired");
});

test("empty requestAccounts success preserves a revocation tombstone", async () => {
    const harness = ethereumHarness();
    const address = "0x0000000000000000000000000000000000000001";
    applyEthereumConfiguration(harness, address);
    const revocation = harness.provider.request({
        method: "wallet_revokePermissions",
        params: [{eth_accounts: {}}],
    });
    harness.Ethereum.applyEnvelope(harness.provider, {
        id: harness.disconnects[0].id,
        kind: "result",
        name: "revokePermissions",
        result: null,
    });
    await revocation;
    assert.equal(
        harness.Ethereum.snapshot(harness.provider)
            .accountRevocationTombstone,
        true
    );

    const accounts = harness.provider.request({
        method: "eth_requestAccounts",
        params: [],
    });
    harness.Ethereum.applyEnvelope(harness.provider, {
        id: harness.requests.at(-1).id,
        kind: "result",
        name: "requestAccounts",
        result: [],
    });
    assert.deepEqual(normalized(await accounts), []);
    assert.equal(
        harness.Ethereum.snapshot(harness.provider)
            .accountRevocationTombstone,
        true
    );
    applyEthereumConfiguration(harness, address);
    assert.equal(harness.provider.selectedAddress, null);
});

test("successful requestAccounts explicitly reauthorizes a revoked account", async () => {
    const harness = ethereumHarness();
    const address = "0x0000000000000000000000000000000000000001";
    applyEthereumConfiguration(harness, address);
    const revocation = harness.provider.request({
        method: "wallet_revokePermissions",
        params: [{eth_accounts: {}}],
    });
    harness.Ethereum.applyEnvelope(harness.provider, {
        id: harness.disconnects[0].id,
        kind: "result",
        name: "revokePermissions",
        result: null,
    });
    await revocation;

    const reconnect = harness.provider.request({method: "eth_requestAccounts"});
    harness.Ethereum.applyEnvelope(harness.provider, {
        id: harness.requests.at(-1).id,
        kind: "result",
        name: "requestAccounts",
        result: [address],
    });
    assert.deepEqual(normalized(await reconnect), [address]);
    assert.equal(harness.provider.selectedAddress, address);
    assert.equal(
        harness.Ethereum.snapshot(harness.provider).accountRevocationTombstone,
        false
    );
});

test("Ethereum rejects signing results after account authorization drifts", async () => {
    const harness = ethereumHarness();
    const firstAddress = "0x0000000000000000000000000000000000000001";
    const secondAddress = "0x0000000000000000000000000000000000000002";
    applyEthereumConfiguration(harness, firstAddress);
    const signing = harness.provider.request({
        method: "personal_sign",
        params: ["0x01"],
    });
    const request = harness.requests.at(-1);
    harness.Ethereum.applyEnvelope(harness.provider, {
        configuration: {address: secondAddress, chainId: "0x1"},
        kind: "configuration",
        switchAccount: true,
    });
    harness.Ethereum.applyEnvelope(harness.provider, {
        id: request.id,
        kind: "result",
        name: request.name,
        result: "0xsignature",
    });
    await assert.rejects(signing, error => error.code === 4100);
    assert.equal(harness.provider.selectedAddress, secondAddress);

    const current = harness.provider.request({
        method: "personal_sign",
        params: ["0x02"],
    });
    const currentRequest = harness.requests.at(-1);
    applyEthereumConfiguration(harness, secondAddress, "0x2");
    harness.Ethereum.applyEnvelope(harness.provider, {
        id: currentRequest.id,
        kind: "result",
        name: currentRequest.name,
        result: "0xcurrent",
    });
    assert.equal(await current, "0xcurrent");
});

test("Ethereum settles a committed signature after later authorization drift", async () => {
    const harness = ethereumHarness();
    const firstAddress = "0x0000000000000000000000000000000000000001";
    const secondAddress = "0x0000000000000000000000000000000000000002";
    applyEthereumConfiguration(harness, firstAddress);
    const signing = harness.provider.request({
        method: "personal_sign",
        params: ["0x01"],
    });
    const request = harness.requests.at(-1);
    harness.Ethereum.applyEnvelope(harness.provider, {
        configuration: {address: secondAddress, chainId: "0x1"},
        kind: "configuration",
        switchAccount: true,
    });
    harness.Ethereum.applyEnvelope(harness.provider, {
        approvalCommitted: true,
        id: request.id,
        kind: "result",
        name: request.name,
        result: "0xsignature",
        suppressUpdate: true,
    });

    assert.equal(await signing, "0xsignature");
    assert.equal(harness.provider.selectedAddress, secondAddress);
});

test("Ethereum settles committed account approval without replacing newer state", async () => {
    const harness = ethereumHarness();
    const approvedAddress = "0x0000000000000000000000000000000000000001";
    const newerAddress = "0x0000000000000000000000000000000000000002";
    applyEthereumConfiguration(harness, "");
    const accounts = harness.provider.request({method: "eth_requestAccounts"});
    const request = harness.requests.at(-1);
    harness.Ethereum.applyEnvelope(harness.provider, {
        configuration: {address: newerAddress, chainId: "0x1"},
        kind: "configuration",
        switchAccount: true,
    });
    harness.Ethereum.applyEnvelope(harness.provider, {
        approvalCommitted: true,
        id: request.id,
        kind: "result",
        name: "requestAccounts",
        result: [approvedAddress],
        suppressUpdate: true,
    });

    assert.deepEqual(normalized(await accounts), [approvedAddress]);
    assert.equal(harness.provider.selectedAddress, newerAddress);
});

test("suppressed initial configuration neither drains nor emits connect", async () => {
    const harness = ethereumHarness();
    let connects = 0;
    harness.provider.on("connect", () => { connects += 1; });
    const chain = harness.provider.request({method: "eth_chainId"});
    let settled = false;
    chain.finally(() => { settled = true; });
    assert.equal(harness.Ethereum.applyEnvelope(harness.provider, {
        kind: "configuration",
        suppressUpdate: true,
        configuration: {
            address: "0x0000000000000000000000000000000000000001",
            chainId: "0x2",
        },
    }), false);
    await Promise.resolve();
    assert.equal(settled, false);
    assert.equal(connects, 0);
    assert.equal(harness.Ethereum.isReady(harness.provider), false);
    applyEthereumConfiguration(harness, "", "0x3");
    assert.equal(await chain, "0x3");
    assert.equal(connects, 1);
    harness.runTimers();
    assert.equal(connects, 1);
});

test("Ethereum replays one authoritative connect to late direct listeners", () => {
    const harness = ethereumHarness();
    applyEthereumConfiguration(harness, "", "0x2");
    const connects = [];
    const removed = value => connects.push(["removed", normalized(value)]);
    harness.provider.on("connect", removed);
    harness.provider.removeListener("connect", removed);
    harness.provider.prependOnceListener("connect", value => {
        connects.push(["late", normalized(value)]);
    });
    harness.runTimers();
    assert.deepEqual(connects, [["late", {chainId: "0x2"}]]);

    harness.provider.on("connect", value => {
        connects.push(["later", normalized(value)]);
    });
    harness.runTimers();
    assert.deepEqual(connects, [["late", {chainId: "0x2"}]]);
});

test("public connect emits do not consume the direct authoritative replay", () => {
    const harness = ethereumHarness();
    applyEthereumConfiguration(harness, "", "0x3");
    const connects = [];
    harness.provider.on("connect", value => {
        connects.push(normalized(value));
    });

    harness.provider.emit("connect", {chainId: "0x999"});
    harness.runTimers();

    assert.deepEqual(connects, [
        {chainId: "0x999"},
        {chainId: "0x3"},
    ]);
    harness.provider.on("connect", value => {
        connects.push(["later", normalized(value)]);
    });
    harness.runTimers();
    assert.deepEqual(connects, [
        {chainId: "0x999"},
        {chainId: "0x3"},
    ]);
});

test("Ethereum removeAllListeners preserves argument count and tracking", () => {
    const harness = ethereumHarness();
    applyEthereumConfiguration(harness, "", "0x4");
    let accountsChanged = 0;
    let removedConnects = 0;
    harness.provider.on("accountsChanged", () => { accountsChanged += 1; });
    harness.provider.on("connect", () => { removedConnects += 1; });

    harness.provider.removeAllListeners();
    harness.provider.emit("accountsChanged", []);
    harness.runTimers();

    assert.equal(harness.provider.listenerCount("accountsChanged"), 0);
    assert.equal(harness.provider.listenerCount("connect"), 0);
    assert.equal(accountsChanged, 0);
    assert.equal(removedConnects, 0);

    const retainedConnects = [];
    harness.provider.on("connect", value => {
        retainedConnects.push(normalized(value));
    });
    harness.provider.removeAllListeners(undefined);
    harness.runTimers();
    assert.equal(harness.provider.listenerCount("connect"), 1);
    assert.deepEqual(retainedConnects, [{chainId: "0x4"}]);
});

test("Ethereum connect tracking survives throwing removal hooks", () => {
    const harness = ethereumHarness();
    applyEthereumConfiguration(harness, "", "0x5");
    const removed = () => {};
    harness.provider.on("connect", removed);
    harness.provider.once("removeListener", () => {
        throw new Error("removal hook failed");
    });

    assert.throws(
        () => harness.provider.removeListener("connect", removed),
        /removal hook failed/u
    );
    harness.runTimers();

    const connects = [];
    harness.provider.on("connect", value => connects.push(normalized(value)));
    harness.runTimers();
    assert.deepEqual(connects, [{chainId: "0x5"}]);
});

test("Ethereum connect replay keeps EventEmitter snapshot ordering", () => {
    const harness = ethereumHarness();
    applyEthereumConfiguration(harness, "", "0x6");
    const connects = [];
    const second = () => connects.push("second");
    harness.provider.on("connect", () => {
        connects.push("first");
        harness.provider.removeListener("connect", second);
    });
    harness.provider.on("connect", second);

    harness.runTimers();

    assert.deepEqual(connects, ["first", "second"]);
    assert.equal(harness.provider.listenerCount("connect"), 1);
});

test("Ethereum connect snapshots survive reentrant configuration", () => {
    for (const lateSubscription of [false, true]) {
        const harness = ethereumHarness();
        if (lateSubscription) {
            applyEthereumConfiguration(harness, "", "0x6");
        }
        const connects = [];
        harness.provider.on("connect", () => {
            connects.push("first");
            applyEthereumConfiguration(harness, "", "0x6");
        });
        harness.provider.on("connect", () => connects.push("second"));

        if (!lateSubscription) {
            applyEthereumConfiguration(harness, "", "0x6");
        }
        harness.runTimers();

        assert.deepEqual(connects, ["first", "second"]);
    }
});

test("Ethereum tracks the exact once listener removed before connect replay", () => {
    const harness = ethereumHarness();
    applyEthereumConfiguration(harness, "", "0x6");
    let connects = 0;
    const listener = () => { connects += 1; };
    harness.provider.once("connect", listener);
    harness.provider.prependOnceListener("connect", listener);
    harness.provider.removeListener("connect", listener);

    harness.runTimers();

    assert.equal(connects, 1);
    assert.equal(harness.provider.listenerCount("connect"), 0);
});

test("Ethereum connect replay waits for copied state and fences retirement", () => {
    const copied = ethereumHarness({
        accountRevision: 0,
        accountRevocationTombstone: false,
        address: "",
        chainId: "0x1",
        didEmitConnect: true,
    });
    const connects = [];
    copied.provider.on("connect", value => connects.push(normalized(value)));
    applyEthereumConfiguration(copied, "", "0x4");
    assert.deepEqual(connects, []);
    copied.runTimers();
    assert.deepEqual(connects, [{chainId: "0x4"}]);

    const retired = ethereumHarness();
    applyEthereumConfiguration(retired, "", "0x5");
    let retiredConnects = 0;
    retired.provider.on("connect", () => { retiredConnects += 1; });
    retired.Ethereum.retire(retired.provider);
    retired.runTimers();
    assert.equal(retiredConnects, 0);
});

test("Ethereum connect replay waits for configuration recovery", () => {
    const harness = ethereumHarness();
    applyEthereumConfiguration(harness, "", "0x6");
    assert.equal(harness.Ethereum.applyEnvelope(harness.provider, {
        configuration: null,
        kind: "configuration",
    }), false);
    const connects = [];
    harness.provider.on("connect", value => {
        connects.push(normalized(value));
    });

    harness.runTimers();
    assert.deepEqual(connects, []);

    applyEthereumConfiguration(harness, "", "0x7");
    harness.runTimers();
    assert.deepEqual(connects, [{chainId: "0x7"}]);
});

test("suppressed initial Solana configuration preserves the loading queue", async () => {
    const harness = solanaHarness();
    const events = [];
    for (const eventName of ["accountChanged", "connect", "disconnect"]) {
        harness.provider.on(eventName, () => { events.push(eventName); });
    }
    harness.provider.standardOn("change", () => { events.push("change"); });
    const connection = harness.provider.connect();
    let settled = false;
    connection.finally(() => { settled = true; });

    assert.equal(applySolanaConfiguration(harness, {
        suppressUpdate: true,
    }), false);
    await Promise.resolve();
    assert.equal(harness.Solana.isReady(harness.provider), false);
    assert.equal(harness.requests.length, 0);
    assert.equal(settled, false);
    assert.deepEqual(events, []);

    assert.equal(applySolanaConfiguration(harness), true);
    assert.equal(harness.Solana.isReady(harness.provider), true);
    assert.equal(harness.requests.length, 1);
    assert.deepEqual(events, []);
    harness.Solana.applyEnvelope(harness.provider, {
        id: harness.requests[0].id,
        kind: "result",
        name: "connect",
        result: {publicKey: firstSolanaKey},
    });
    assert.equal((await connection).publicKey.toString(), firstSolanaKey);
});

test("Solana bounds loading work without retiring the ready provider", async () => {
    const harness = solanaHarness();
    const connections = Array.from({length: 65}, () => harness.provider.connect());
    const overflow = assert.rejects(connections[64], error => error.code === 4900);

    applySolanaConfiguration(harness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    const connected = await Promise.all(connections.slice(0, 64));
    assert.deepEqual(
        connected.map(value => value.publicKey.toString()),
        Array(64).fill(firstSolanaKey)
    );
    await overflow;
    assert.equal(harness.requests.length, 0);
    assert.equal(
        (await harness.provider.connect()).publicKey.toString(),
        firstSolanaKey
    );
});

test("Solana ignores terminal envelopes until an operation is dispatched", async () => {
    const harness = solanaHarness();
    const connection = harness.provider.connect();
    assert.equal(harness.Solana.applyEnvelope(harness.provider, {
        id: 2,
        kind: "result",
        name: "connect",
        result: {publicKey: firstSolanaKey},
    }), false);
    assert.equal(harness.requests.length, 0);
    applySolanaConfiguration(harness);
    assert.equal(harness.requests.length, 1);
    harness.Solana.applyEnvelope(harness.provider, {
        id: harness.requests[0].id,
        kind: "result",
        name: "connect",
        result: {publicKey: firstSolanaKey},
    });
    assert.equal((await connection).publicKey.toString(), firstSolanaKey);
});

test("Solana late connect cannot overwrite newer authorization", async () => {
    const harness = solanaHarness();
    applySolanaConfiguration(harness);
    const connection = harness.provider.connect();
    applySolanaConfiguration(harness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: secondSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    harness.Solana.applyEnvelope(harness.provider, {
        id: harness.requests[0].id,
        kind: "result",
        name: "connect",
        result: {publicKey: firstSolanaKey},
    });
    await assert.rejects(connection, error => error.code === 4900);
    assert.equal(harness.provider.publicKey.toString(), secondSolanaKey);
});

test("Solana current connect baseline remains authoritative when suppressed", async () => {
    const harness = solanaHarness();
    applySolanaConfiguration(harness);
    const connection = harness.provider.connect();
    harness.Solana.applyEnvelope(harness.provider, {
        id: harness.requests[0].id,
        kind: "result",
        name: "connect",
        result: {publicKey: firstSolanaKey},
        suppressUpdate: true,
    });

    assert.equal((await connection).publicKey.toString(), firstSolanaKey);
    assert.equal(harness.provider.publicKey.toString(), firstSolanaKey);
    assert.equal(harness.provider.isConnected, true);
});

test("Solana silent connect never posts without a trusted account", async () => {
    const harness = solanaHarness();
    const connection = harness.provider.standardConnect({silent: true});
    assert.equal(harness.requests.length, 0);
    applySolanaConfiguration(harness);
    assert.deepEqual(normalized(await connection), {accounts: []});
    assert.equal(harness.requests.length, 0);
});

test("Solana local reconnect emits connect after settlement", async () => {
    const harness = solanaHarness({
        accountRevision: 1,
        isConnected: false,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    applySolanaConfiguration(harness, {
        accountRevision: 1,
        isConnected: false,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    let connects = 0;
    harness.provider.on("connect", () => { connects += 1; });
    assert.equal((await harness.provider.connect()).publicKey.toString(), firstSolanaKey);
    assert.equal(connects, 1);
    assert.equal(harness.requests.length, 0);
    await harness.provider.connect();
    assert.equal(connects, 1);

    const loading = solanaHarness({
        accountRevision: 1,
        isConnected: false,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    let loadingConnects = 0;
    loading.provider.on("connect", () => { loadingConnects += 1; });
    const queued = loading.provider.connect();
    applySolanaConfiguration(loading, {
        accountRevision: 1,
        isConnected: false,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    assert.equal((await queued).publicKey.toString(), firstSolanaKey);
    assert.equal(loadingConnects, 1);

    const ordered = solanaHarness({
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    const events = [];
    ordered.provider.on("connect", () => { events.push("connect"); });
    ordered.provider.on("disconnect", () => { events.push("disconnect"); });
    const reconnect = ordered.provider.connect();
    applySolanaConfiguration(ordered, {
        accountRevision: 1,
        isConnected: false,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    assert.equal((await reconnect).publicKey.toString(), firstSolanaKey);
    assert.deepEqual(events, ["disconnect", "connect"]);
    assert.equal(ordered.provider.isConnected, true);
});

test("Solana drains loading connects FIFO and fences stale completion", async () => {
    const harness = solanaHarness();
    const first = harness.provider.connect();
    const second = harness.provider.connect();
    const secondRejected = assert.rejects(
        second,
        error => error.code === 4900
    );
    assert.equal(harness.requests.length, 0);
    applySolanaConfiguration(harness);
    assert.deepEqual(harness.requests.map(message => message.id), [2, 4]);
    harness.Solana.applyEnvelope(harness.provider, {
        id: 2,
        kind: "result",
        name: "connect",
        result: {publicKey: firstSolanaKey},
    });
    harness.Solana.applyEnvelope(harness.provider, {
        id: 4,
        kind: "result",
        name: "connect",
        result: {publicKey: firstSolanaKey},
    });
    assert.equal((await first).publicKey.toString(), firstSolanaKey);
    await secondRejected;
    assert.equal(harness.provider.publicKey.toString(), firstSolanaKey);
});

test("Solana shares disconnect work and manual switch clears its tombstone", async () => {
    const harness = solanaHarness({
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 0,
    });
    applySolanaConfiguration(harness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
    });
    const first = harness.provider.disconnect();
    const second = harness.provider.disconnect();
    assert.equal(first, second);
    assert.equal(harness.disconnects.length, 1);
    assert.deepEqual(harness.epochs, [1]);
    assert.equal(harness.provider.publicKey, null);
    harness.Solana.applyEnvelope(harness.provider, {
        id: harness.disconnects[0].id,
        kind: "result",
        name: "disconnect",
        result: true,
    });
    assert.equal(await first, true);
    const state = harness.Solana.snapshot(harness.provider);
    applySolanaConfiguration(harness, {
        accountRevision: state.accountRevision,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: state.solanaAuthorizationEpoch,
    });
    assert.equal(harness.provider.publicKey, null);
    applySolanaConfiguration(harness, {
        accountRevision: state.accountRevision,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: state.solanaAuthorizationEpoch,
        switchAccount: true,
    });
    assert.equal(harness.provider.publicKey.toString(), firstSolanaKey);
});

test("ordinary Solana configuration preserves a copied revocation tombstone", () => {
    const harness = solanaHarness({
        accountRevision: 3,
        accountRevocationTombstone: true,
        isConnected: false,
        publicKey: null,
        solanaAuthorizationEpoch: 4,
    });
    const before = harness.Solana.snapshot(harness.provider);

    assert.equal(applySolanaConfiguration(harness, {
        accountRevision: 8,
        isConnected: true,
        publicKey: secondSolanaKey,
        solanaAuthorizationEpoch: 9,
    }), true);
    assert.equal(harness.Solana.isReady(harness.provider), true);
    assert.deepEqual(harness.Solana.snapshot(harness.provider), before);

    assert.equal(applySolanaConfiguration(harness, {
        accountRevision: 8,
        isConnected: true,
        publicKey: secondSolanaKey,
        solanaAuthorizationEpoch: 9,
        switchAccount: true,
    }), true);
    assert.deepEqual(normalized(harness.Solana.snapshot(harness.provider)), {
        accountRevision: 8,
        accountRevocationTombstone: false,
        isConnected: true,
        publicKey: secondSolanaKey,
        solanaAuthorizationEpoch: 9,
    });
});

test("successful Solana connect explicitly reauthorizes a revoked account", async () => {
    const harness = solanaHarness({
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    applySolanaConfiguration(harness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    const disconnect = harness.provider.disconnect();
    harness.Solana.applyEnvelope(harness.provider, {
        id: harness.disconnects[0].id,
        kind: "result",
        name: "disconnect",
        result: true,
    });
    await disconnect;

    const reconnect = harness.provider.connect();
    harness.Solana.applyEnvelope(harness.provider, {
        id: harness.requests.at(-1).id,
        kind: "result",
        name: "connect",
        result: {publicKey: firstSolanaKey},
    });
    assert.equal((await reconnect).publicKey.toString(), firstSolanaKey);
    assert.equal(harness.provider.accountRevocationTombstone, false);
});

test("Solana accepts raw ArrayBuffer messages", async () => {
    const harness = solanaHarness({
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    applySolanaConfiguration(harness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    const bytes = new Uint8Array([1, 2, 3]);
    const signing = harness.provider.signMessage(bytes.buffer);
    assert.equal(harness.requests.at(-1).body.object.params.message, "0x010203");
    harness.Solana.applyEnvelope(harness.provider, {
        id: harness.requests.at(-1).id,
        kind: "result",
        name: "signMessage",
        result: validSignature,
    });
    assert.equal((await signing).signature.length, 64);
});

test("Solana settles a committed signature after later authorization drift", async () => {
    const harness = solanaHarness({
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    applySolanaConfiguration(harness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    const signing = harness.provider.signMessage(new Uint8Array([1]));
    const request = harness.requests.at(-1);
    applySolanaConfiguration(harness, {
        accountRevision: 2,
        isConnected: true,
        publicKey: secondSolanaKey,
        solanaAuthorizationEpoch: 2,
    });
    harness.Solana.applyEnvelope(harness.provider, {
        approvalCommitted: true,
        id: request.id,
        kind: "result",
        name: "signMessage",
        result: validSignature,
        suppressUpdate: true,
    });

    const result = await signing;
    assert.equal(result.signature.length, 64);
    assert.equal(result.publicKey.toString(), firstSolanaKey);
    assert.equal(harness.provider.publicKey.toString(), secondSolanaKey);
});

test("Solana applies a committed transaction signature after authorization drift", async () => {
    const harness = solanaHarness({
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    applySolanaConfiguration(harness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    const transaction = legacyTransaction(1);
    const signing = harness.provider.signTransaction(transaction.transaction);
    const request = harness.requests.at(-1);
    applySolanaConfiguration(harness, {
        accountRevision: 2,
        isConnected: true,
        publicKey: secondSolanaKey,
        solanaAuthorizationEpoch: 2,
    });
    harness.Solana.applyEnvelope(harness.provider, {
        approvalCommitted: true,
        id: request.id,
        kind: "result",
        name: "signTransaction",
        result: validSignature,
        suppressUpdate: true,
    });

    assert.equal(await signing, transaction.transaction);
    assert.equal(transaction.entry.signature.length, 64);
    assert.equal(harness.provider.publicKey.toString(), secondSolanaKey);
});

test("Wallet Standard settles committed single-item signing after authorization drift", async () => {
    for (const variant of ["message", "transaction", "send"]) {
        const harness = solanaHarness({
            accountRevision: 1,
            isConnected: true,
            publicKey: firstSolanaKey,
            solanaAuthorizationEpoch: 1,
        });
        applySolanaConfiguration(harness, {
            accountRevision: 1,
            isConnected: true,
            publicKey: firstSolanaKey,
            solanaAuthorizationEpoch: 1,
        });
        const account = harness.provider.standardAccounts()[0];
        let signing;
        if (variant === "message") {
            signing = harness.provider.standardSignMessage({
                account,
                message: new Uint8Array([1]),
            });
        } else if (variant === "transaction") {
            harness.provider.preparedStandardTransaction = () => ({
                messageBytes: new Uint8Array([1]),
                signatureOffset: 1,
                transactionBytes: new Uint8Array(66),
            });
            signing = harness.provider.standardSignTransaction({
                account,
                chain: "solana:mainnet",
                transaction: new Uint8Array([1]),
            });
        } else {
            signing = harness.provider.standardSignAndSendTransaction({
                account,
                chain: "solana:mainnet",
                transaction: new Uint8Array([1]),
            });
        }
        const request = harness.requests.at(-1);
        applySolanaConfiguration(harness, {
            accountRevision: 2,
            isConnected: true,
            publicKey: secondSolanaKey,
            solanaAuthorizationEpoch: 2,
        });
        harness.Solana.applyEnvelope(harness.provider, {
            approvalCommitted: true,
            id: request.id,
            kind: "result",
            name: request.name,
            result: validSignature,
            suppressUpdate: true,
        });

        const [result] = await signing;
        if (variant === "message") {
            assert.equal(result.signature.length, 64);
        } else if (variant === "transaction") {
            assert.equal(result.signedTransaction.length, 66);
        } else {
            assert.equal(result.signature.length, 64);
        }
        assert.equal(harness.provider.publicKey.toString(), secondSolanaKey);
    }
});

test("Solana settles committed connect without replacing newer state", async () => {
    const harness = solanaHarness();
    applySolanaConfiguration(harness, {
        accountRevision: 0,
        isConnected: false,
        publicKey: null,
        solanaAuthorizationEpoch: 0,
    });
    const connecting = harness.provider.connect();
    const request = harness.requests.at(-1);
    applySolanaConfiguration(harness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: secondSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    harness.Solana.applyEnvelope(harness.provider, {
        approvalCommitted: true,
        id: request.id,
        kind: "result",
        name: "connect",
        result: {publicKey: firstSolanaKey},
        suppressUpdate: true,
    });

    assert.equal((await connecting).publicKey.toString(), firstSolanaKey);
    assert.equal(harness.provider.publicKey.toString(), secondSolanaKey);
});

test("Wallet Standard committed connect returns current authorization", async () => {
    for (const currentPublicKey of [secondSolanaKey, null]) {
        const harness = solanaHarness();
        applySolanaConfiguration(harness);
        const connecting = harness.provider.standardConnect();
        const request = harness.requests.at(-1);
        if (currentPublicKey) {
            applySolanaConfiguration(harness, {
                accountRevision: 1,
                isConnected: true,
                publicKey: currentPublicKey,
                solanaAuthorizationEpoch: 1,
            });
        } else {
            await harness.provider.externalDisconnect();
        }
        harness.Solana.applyEnvelope(harness.provider, {
            approvalCommitted: true,
            configurationApplied: false,
            id: request.id,
            kind: "result",
            name: "connect",
            result: {publicKey: firstSolanaKey},
            suppressUpdate: true,
        });

        const result = await connecting;
        assert.deepEqual(
            normalized(result.accounts.map(account => account.address)),
            currentPublicKey ? [currentPublicKey] : []
        );
    }
});

test("Solana signs explicit legacy and versioned transactions", async () => {
    for (const transaction of [legacyTransaction(1), versionedTransaction(1)]) {
        const harness = solanaHarness({
            accountRevision: 1,
            isConnected: true,
            publicKey: firstSolanaKey,
            solanaAuthorizationEpoch: 1,
        });
        applySolanaConfiguration(harness, {
            accountRevision: 1,
            isConnected: true,
            publicKey: firstSolanaKey,
            solanaAuthorizationEpoch: 1,
        });
        const signed = harness.provider.signTransaction(transaction.transaction);
        harness.Solana.applyEnvelope(harness.provider, {
            id: harness.requests[0].id,
            kind: "result",
            name: "signTransaction",
            result: validSignature,
        });
        assert.equal(await signed, transaction.transaction);
        if (transaction.entry) {
            assert.equal(transaction.entry.signature.length, 64);
        } else {
            assert.equal(transaction.signatures[0].length, 64);
        }
    }
});

test("Solana rejects replacement of a versioned transaction message", async () => {
    const harness = solanaHarness({
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    applySolanaConfiguration(harness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    const transaction = versionedTransaction(1);
    const replacement = versionedTransaction(2);
    const request = harness.provider.signTransaction(transaction.transaction);
    transaction.transaction.message = replacement.transaction.message;
    harness.Solana.applyEnvelope(harness.provider, {
        id: harness.requests[0].id,
        kind: "result",
        name: "signTransaction",
        result: validSignature,
    });
    await assert.rejects(request, error => error.code === 4200);
    assert.deepEqual([...transaction.signatures[0]], new Array(64).fill(0));

    const reentrant = versionedTransaction(1);
    const reentrantReplacement = versionedTransaction(2);
    let serializations = 0;
    reentrant.transaction.message.serialize = () => {
        serializations += 1;
        if (serializations === 5) {
            reentrant.transaction.message =
                reentrantReplacement.transaction.message;
        }
        return new Uint8Array([1]);
    };
    const reentrantRequest = harness.provider.signTransaction(
        reentrant.transaction
    );
    harness.Solana.applyEnvelope(harness.provider, {
        id: harness.requests[1].id,
        kind: "result",
        name: "signTransaction",
        result: validSignature,
    });
    await assert.rejects(reentrantRequest, error => error.code === 4200);
    assert.deepEqual([...reentrant.signatures[0]], new Array(64).fill(0));
});

test("Solana rejects transaction serializer replacement", async () => {
    for (const transaction of [legacyTransaction(1), versionedTransaction(1)]) {
        const harness = solanaHarness({
            accountRevision: 1,
            isConnected: true,
            publicKey: firstSolanaKey,
            solanaAuthorizationEpoch: 1,
        });
        applySolanaConfiguration(harness, {
            accountRevision: 1,
            isConnected: true,
            publicKey: firstSolanaKey,
            solanaAuthorizationEpoch: 1,
        });
        const request = harness.provider.signTransaction(
            transaction.transaction
        );
        if (transaction.entry) {
            transaction.transaction.serializeMessage = () =>
                new Uint8Array([2]);
        } else {
            transaction.transaction.message.serialize = () =>
                new Uint8Array([2]);
        }
        harness.Solana.applyEnvelope(harness.provider, {
            id: harness.requests[0].id,
            kind: "result",
            name: "signTransaction",
            result: validSignature,
        });
        await assert.rejects(request, error => error.code === 4200);
    }
});

test("Solana final message validation rechecks authorization", async () => {
    const harness = solanaHarness({
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    applySolanaConfiguration(harness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    const transaction = legacyTransaction(1);
    let serializations = 0;
    transaction.transaction.serializeMessage = () => {
        serializations += 1;
        if (serializations === 5) {
            applySolanaConfiguration(harness, {
                accountRevision: 2,
                isConnected: true,
                publicKey: secondSolanaKey,
                solanaAuthorizationEpoch: 2,
            });
        }
        return new Uint8Array([1]);
    };
    const request = harness.provider.signTransaction(transaction.transaction);
    harness.Solana.applyEnvelope(harness.provider, {
        id: harness.requests[0].id,
        kind: "result",
        name: "signTransaction",
        result: validSignature,
    });
    await assert.rejects(request, error => error.code === 4900);
    assert.equal(transaction.entry.signature, null);
});

test("Solana rejects invalid signatures, mutation, custom shapes, and oversized batches", async () => {
    const harness = solanaHarness({
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    applySolanaConfiguration(harness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    const mutable = legacyTransaction(1);
    let byte = 1;
    mutable.transaction.serializeMessage = () => new Uint8Array([byte]);
    const changed = harness.provider.signTransaction(mutable.transaction);
    byte = 2;
    harness.Solana.applyEnvelope(harness.provider, {
        id: harness.requests[0].id,
        kind: "result",
        name: "signTransaction",
        result: validSignature,
    });
    await assert.rejects(changed, error => error.code === 4200);
    assert.equal(mutable.entry.signature, null);

    const invalid = legacyTransaction(3);
    const invalidSignature = harness.provider.signTransaction(invalid.transaction);
    harness.Solana.applyEnvelope(harness.provider, {
        id: harness.requests[1].id,
        kind: "result",
        name: "signTransaction",
        result: "1".repeat(63),
    });
    await assert.rejects(invalidSignature, error => error.code === 4200);

    await assert.rejects(
        harness.provider.signTransaction({signatures: []}),
        error => error.code === 4200
    );
    await assert.rejects(
        harness.provider.request({
            method: "signAllTransactions",
            params: {messages: new Array(65).fill("2")},
        }),
        error => error.code === 4200
    );
});

test("Solana restores exact transaction state after a mid-apply failure", async () => {
    const harness = solanaHarness({
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    applySolanaConfiguration(harness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    const firstBytes = Buffer.alloc(64, 7);
    const secondBytes = new Uint8Array(64).fill(8);
    const firstTarget = {publicKey: publicKey(), signature: firstBytes};
    const secondEntry = {publicKey: publicKey(), signature: secondBytes};
    let failApply = true;
    let firstTransaction;
    let secondTransaction;
    const firstEntry = new Proxy(firstTarget, {
        defineProperty(target, name, descriptor) {
            if (name === "signature" && failApply &&
                descriptor.value !== firstBytes) {
                failApply = false;
                firstBytes[0] = 1;
                secondBytes[0] = 2;
                firstTransaction.signatures = [];
                secondTransaction.signatures[0] = {};
                throw new Error("apply failed");
            }
            return Reflect.defineProperty(target, name, descriptor);
        },
    });
    const firstSignatures = [firstEntry];
    const secondSignatures = [secondEntry];
    firstTransaction = {
        signatures: firstSignatures,
        serializeMessage() { return new Uint8Array([1]); },
    };
    secondTransaction = {
        signatures: secondSignatures,
        serializeMessage() { return new Uint8Array([2]); },
    };
    const request = harness.provider.signAllTransactions([
        firstTransaction,
        secondTransaction,
    ]);
    harness.Solana.applyEnvelope(harness.provider, {
        id: harness.requests[0].id,
        kind: "batchResult",
        name: "signAllTransactions",
        results: [validSignature, validSignature],
    });
    await assert.rejects(request, /apply failed/);
    assert.equal(firstTransaction.signatures, firstSignatures);
    assert.equal(secondTransaction.signatures, secondSignatures);
    assert.equal(firstSignatures[0], firstEntry);
    assert.equal(secondSignatures[0], secondEntry);
    assert.equal(Buffer.isBuffer(firstTarget.signature), true);
    assert.equal(firstTarget.signature, firstBytes);
    assert.equal(secondEntry.signature, secondBytes);
    assert.equal(firstBytes[0], 7);
    assert.equal(secondBytes[0], 8);
});

test("Solana restores typed-array and ArrayBuffer bytes after apply failure", async () => {
    for (const representation of ["typedArray", "arrayBuffer"]) {
        const harness = solanaHarness({
            accountRevision: 1,
            isConnected: true,
            publicKey: firstSolanaKey,
            solanaAuthorizationEpoch: 1,
        });
        applySolanaConfiguration(harness, {
            accountRevision: 1,
            isConnected: true,
            publicKey: firstSolanaKey,
            solanaAuthorizationEpoch: 1,
        });
        const initial = new Uint8Array(64).fill(7);
        const signature = representation === "arrayBuffer"
            ? initial.buffer
            : initial;
        const target = {publicKey: publicKey(), signature};
        let failApply = true;
        const entry = new Proxy(target, {
            defineProperty(object, name, descriptor) {
                if (name === "signature" && failApply &&
                    descriptor.value !== signature) {
                    failApply = false;
                    initial[0] = 1;
                    throw new Error("apply failed");
                }
                return Reflect.defineProperty(object, name, descriptor);
            },
        });
        const transaction = {
            signatures: [entry],
            serializeMessage() { return new Uint8Array([1]); },
        };
        const signing = harness.provider.signTransaction(transaction);
        harness.Solana.applyEnvelope(harness.provider, {
            id: harness.requests[0].id,
            kind: "result",
            name: "signTransaction",
            result: validSignature,
        });

        await assert.rejects(signing, /apply failed/u);
        assert.equal(target.signature, signature);
        assert.deepEqual([...initial], new Array(64).fill(7));
    }
});

test("Solana captures every rollback baseline before response serializers run", async () => {
    const harness = solanaHarness({
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    applySolanaConfiguration(harness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    const secondBytes = new Uint8Array(64).fill(8);
    const first = legacyTransaction(1);
    const second = legacyTransaction(2, secondBytes);
    let firstSerializations = 0;
    let secondSerializations = 0;
    first.transaction.serializeMessage = () => {
        firstSerializations += 1;
        if (firstSerializations > 1) { secondBytes[0] = 2; }
        return new Uint8Array([1]);
    };
    second.transaction.serializeMessage = () => {
        secondSerializations += 1;
        return new Uint8Array([secondSerializations > 1 ? 3 : 2]);
    };
    const request = harness.provider.signAllTransactions([
        first.transaction,
        second.transaction,
    ]);
    harness.Solana.applyEnvelope(harness.provider, {
        id: harness.requests[0].id,
        kind: "batchResult",
        name: "signAllTransactions",
        results: [validSignature, validSignature],
    });
    await assert.rejects(request, error => error.code === 4200);
    assert.equal(first.entry.signature, null);
    assert.equal(second.entry.signature, secondBytes);
    assert.equal(secondBytes[0], 8);
});

test("Solana rejects a later batch setter that mutates an earlier message", async () => {
    const harness = solanaHarness({
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    applySolanaConfiguration(harness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    let firstByte = 1;
    const first = legacyTransaction(1);
    first.transaction.serializeMessage = () => new Uint8Array([firstByte]);
    const secondTarget = {publicKey: publicKey(), signature: null};
    const secondEntry = new Proxy(secondTarget, {
        defineProperty(target, name, descriptor) {
            if (name === "signature" && descriptor.value !== null) {
                firstByte = 9;
            }
            return Reflect.defineProperty(target, name, descriptor);
        },
    });
    const second = {
        signatures: [secondEntry],
        serializeMessage() { return new Uint8Array([2]); },
    };
    const request = harness.provider.signAllTransactions([
        first.transaction,
        second,
    ]);
    harness.Solana.applyEnvelope(harness.provider, {
        id: harness.requests[0].id,
        kind: "batchResult",
        name: "signAllTransactions",
        results: [validSignature, validSignature],
    });
    await assert.rejects(request, error => error.code === 4200);
    assert.equal(first.entry.signature, null);
    assert.equal(secondTarget.signature, null);
});

test("Solana rejects aliased signer targets in a batch", async () => {
    const harness = solanaHarness({
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    applySolanaConfiguration(harness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    const entry = {publicKey: publicKey(), signature: null};
    const first = {
        signatures: [entry],
        serializeMessage() { return new Uint8Array([1]); },
    };
    const second = {
        signatures: [entry],
        serializeMessage() { return new Uint8Array([2]); },
    };
    const request = harness.provider.signAllTransactions([first, second]);
    harness.Solana.applyEnvelope(harness.provider, {
        id: harness.requests[0].id,
        kind: "batchResult",
        name: "signAllTransactions",
        results: [validSignature, `${"1".repeat(63)}2`],
    });
    await assert.rejects(request, error => error.code === 4200);
    assert.equal(entry.signature, null);
});

test("Solana rollback preserves a caller-replaced signature array", async () => {
    const harness = solanaHarness({
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    applySolanaConfiguration(harness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    const original = legacyTransaction(1);
    const request = harness.provider.signTransaction(original.transaction);
    const replacementBytes = new Uint8Array(64).fill(9);
    const replacementEntry = {
        publicKey: publicKey(),
        signature: replacementBytes,
    };
    const replacementSignatures = [replacementEntry];
    original.transaction.signatures = replacementSignatures;
    harness.Solana.applyEnvelope(harness.provider, {
        id: harness.requests[0].id,
        kind: "result",
        name: "signTransaction",
        result: validSignature,
    });
    await assert.rejects(request, error => error.code === 4200);
    assert.equal(original.transaction.signatures, replacementSignatures);
    assert.equal(original.transaction.signatures[0], replacementEntry);
    assert.equal(replacementEntry.signature, replacementBytes);
    assert.equal(replacementBytes[0], 9);
});

test("Solana preflights a whole batch before applying signatures", async () => {
    const harness = solanaHarness({
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    applySolanaConfiguration(harness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    const first = legacyTransaction(1);
    const second = legacyTransaction(2);
    const request = harness.provider.signAllTransactions([
        first.transaction,
        second.transaction,
    ]);
    harness.Solana.applyEnvelope(harness.provider, {
        id: harness.requests[0].id,
        kind: "batchResult",
        name: "signAllTransactions",
        results: [validSignature, "1".repeat(63)],
    });
    await assert.rejects(request, error => error.code === 4200);
    assert.equal(first.entry.signature, null);
    assert.equal(second.entry.signature, null);
});

test("Wallet Standard signing preflights and caps every input", async () => {
    const harness = solanaHarness({
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    applySolanaConfiguration(harness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    const account = harness.provider.standardAccounts()[0];
    let messageCalls = 0;
    harness.provider.signMessage = async () => {
        messageCalls += 1;
        return {signature: validSignature};
    };
    await assert.rejects(harness.provider.standardSignMessage(
        {account, message: new Uint8Array([1])},
        {account: {}, message: new Uint8Array([2])}
    ));
    assert.equal(messageCalls, 0);
    await assert.rejects(harness.provider.standardSignMessage(
        ...new Array(65).fill(null).map(() => ({
            account,
            message: new Uint8Array([1]),
        }))
    ), error => error.code === 4200);
    assert.equal(messageCalls, 0);

    let transactionCalls = 0;
    harness.provider.preparedStandardTransaction = () => ({
        messageBytes: new Uint8Array([1]),
        signatureOffset: 1,
        transactionBytes: new Uint8Array(66),
    });
    harness.provider.request = async () => {
        transactionCalls += 1;
        return {signature: validSignature};
    };
    await assert.rejects(harness.provider.standardSignTransaction(
        {
            account,
            chain: "solana:mainnet",
            transaction: new Uint8Array([1]),
        },
        {
            account: {},
            chain: "solana:mainnet",
            transaction: new Uint8Array([2]),
        }
    ));
    assert.equal(transactionCalls, 0);
});

test("Wallet Standard signing rejects authorization drift between awaits", async () => {
    for (const variant of ["message", "transaction", "send"]) {
        const harness = solanaHarness({
            accountRevision: 1,
            isConnected: true,
            publicKey: firstSolanaKey,
            solanaAuthorizationEpoch: 1,
        });
        applySolanaConfiguration(harness, {
            accountRevision: 1,
            isConnected: true,
            publicKey: firstSolanaKey,
            solanaAuthorizationEpoch: 1,
        });
        const account = harness.provider.standardAccounts()[0];
        let calls = 0;
        const switchAccount = signature => {
            calls += 1;
            applySolanaConfiguration(harness, {
                accountRevision: 2,
                isConnected: true,
                publicKey: secondSolanaKey,
                solanaAuthorizationEpoch: 2,
            });
            return {signature};
        };
        let request;
        if (variant === "message") {
            harness.provider.signMessage = async () =>
                switchAccount(new Uint8Array(64));
            const input = {
                account,
                message: new Uint8Array([1]),
            };
            request = harness.provider.standardSignMessage(input, input);
        } else if (variant === "transaction") {
            harness.provider.preparedStandardTransaction = () => ({
                messageBytes: new Uint8Array([1]),
                signatureOffset: 1,
                transactionBytes: new Uint8Array(66),
            });
            harness.provider.request = async () => switchAccount(validSignature);
            const input = {
                account,
                chain: "solana:mainnet",
                transaction: new Uint8Array([1]),
            };
            request = harness.provider.standardSignTransaction(input, input);
        } else {
            harness.provider.signAndSendTransaction = async () =>
                switchAccount(validSignature);
            const input = {
                account,
                chain: "solana:mainnet",
                transaction: new Uint8Array([1]),
            };
            request = harness.provider.standardSignAndSendTransaction(
                input,
                input
            );
        }
        await assert.rejects(request, error => error.code === 4900);
        assert.equal(calls, 1);
    }
});

test("Solana retires all work when a generation transport returns false", async () => {
    const requestHarness = solanaHarness({
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    applySolanaConfiguration(requestHarness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    const first = requestHarness.provider.signMessage(new Uint8Array([1]));
    const firstRejected = assert.rejects(first, error => error.code === 4900);
    requestHarness.setRequestPost(false);
    const second = requestHarness.provider.signMessage(new Uint8Array([2]));
    await Promise.all([
        firstRejected,
        assert.rejects(second, error => error.code === 4900),
    ]);
    assert.equal(requestHarness.provider.retired, true);

    const disconnectHarness = solanaHarness({
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    applySolanaConfiguration(disconnectHarness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    const pending = disconnectHarness.provider.signMessage(
        new Uint8Array([1])
    );
    const pendingRejected = assert.rejects(
        pending,
        error => error.code === 4900
    );
    disconnectHarness.setDisconnectPost(false);
    const disconnect = disconnectHarness.provider.disconnect();
    await Promise.all([
        pendingRejected,
        assert.rejects(disconnect, error => error.code === 4900),
    ]);
    assert.equal(disconnectHarness.provider.retired, true);

    const epochHarness = solanaHarness({
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    applySolanaConfiguration(epochHarness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    epochHarness.setEpochPost(false);
    await assert.rejects(
        epochHarness.provider.disconnect(),
        error => error.code === 4900
    );
    assert.equal(epochHarness.provider.retired, true);

    const externalHarness = solanaHarness({
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    applySolanaConfiguration(externalHarness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    const externalPending = externalHarness.provider.signMessage(
        new Uint8Array([1])
    );
    const externalRejected = assert.rejects(
        externalPending,
        error => error.code === 4900
    );
    externalHarness.setEpochPost(false);
    await externalHarness.provider.externalDisconnect();
    await externalRejected;
    assert.equal(externalHarness.provider.retired, true);

    const failureHarness = solanaHarness({
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    applySolanaConfiguration(failureHarness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    const failed = failureHarness.provider.signMessage(new Uint8Array([1]));
    const unrelated = failureHarness.provider.signMessage(new Uint8Array([2]));
    const failedRejected = assert.rejects(failed, error => error.code === 4900);
    const unrelatedRejected = assert.rejects(
        unrelated,
        error => error.code === 4900
    );
    failureHarness.setEpochPost(false);
    failureHarness.Solana.applyEnvelope(failureHarness.provider, {
        authorizationFailure: true,
        error: {code: 4100, message: "Unauthorized"},
        id: failureHarness.requests[0].id,
        kind: "error",
        name: "signMessage",
    });
    await Promise.all([failedRejected, unrelatedRejected]);
    assert.equal(failureHarness.provider.retired, true);

    const throwingHarness = solanaHarness({
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    applySolanaConfiguration(throwingHarness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    const throwingPending = throwingHarness.provider.signMessage(
        new Uint8Array([1])
    );
    const throwingRejected = assert.rejects(
        throwingPending,
        error => error.code === 4900
    );
    throwingHarness.setEpochError(new Error("synchronization failed"));
    await throwingHarness.provider.externalDisconnect();
    await throwingRejected;
    assert.equal(throwingHarness.provider.retired, true);

    const exhaustedHarness = solanaHarness({
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: Number.MAX_SAFE_INTEGER,
    });
    applySolanaConfiguration(exhaustedHarness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: Number.MAX_SAFE_INTEGER,
    });
    const exhaustedPending = exhaustedHarness.provider.signMessage(
        new Uint8Array([1])
    );
    const exhaustedRejected = assert.rejects(
        exhaustedPending,
        error => error.code === 4900
    );
    await Promise.all([
        exhaustedRejected,
        assert.rejects(
            exhaustedHarness.provider.disconnect(),
            error => error.code === 4900
        ),
    ]);
    assert.equal(exhaustedHarness.provider.retired, true);
});

test("Solana fences stale authorization and retires pending work", async () => {
    const harness = solanaHarness({
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    applySolanaConfiguration(harness, {
        accountRevision: 1,
        isConnected: true,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    const pending = harness.provider.signMessage(new Uint8Array([1]));
    applySolanaConfiguration(harness, {
        accountRevision: 2,
        isConnected: true,
        publicKey: secondSolanaKey,
        solanaAuthorizationEpoch: 2,
    });
    harness.Solana.applyEnvelope(harness.provider, {
        authorizationFailure: true,
        error: {code: 4100, message: "Unauthorized"},
        id: harness.requests[0].id,
        kind: "error",
        name: "signMessage",
    });
    await assert.rejects(pending, error => error.code === 4100);
    assert.equal(harness.provider.publicKey.toString(), secondSolanaKey);

    const retiring = harness.provider.signMessage(new Uint8Array([2]));
    assert.equal(harness.Solana.retire(harness.provider) > 0, true);
    await assert.rejects(retiring, error => error.code === 4900);
    assert.equal(harness.Solana.isReady(harness.provider), false);
    assert.equal(harness.provider.isConnected, false);
});

function facadeHarness({navigator = {wallets: []}, registerOnDispatch = true} = {}) {
    const listeners = new Map;
    const registeredWallets = [];
    const window = {
        navigator,
        addEventListener(name, listener) {
            if (!listeners.has(name)) { listeners.set(name, new Set); }
            listeners.get(name).add(listener);
        },
        removeEventListener(name, listener) {
            listeners.get(name)?.delete(listener);
        },
        dispatchEvent(event) {
            if (registerOnDispatch &&
                event.type === "wallet-standard:register-wallet") {
                event.detail({
                    register(wallet) {
                        registeredWallets.push(wallet);
                        return () => {};
                    },
                });
            }
            for (const listener of listeners.get(event.type) || []) {
                listener(event);
            }
            return true;
        },
    };
    const module = moduleHarness(stableFacadesSource, {window});
    return {...module, listeners, registeredWallets, window};
}

function ethereumFacadeTarget(name) {
    const provider = new EventEmitter;
    provider.address = "";
    provider.chainId = "0x1";
    provider.request = payload => Promise.resolve(`${name}:${payload.method}`);
    provider.send = provider.request;
    provider.sendAsync = (payload, callback) => callback(null, name);
    provider.enable = () => Promise.resolve([]);
    provider.isConnected = () => true;
    provider.isUnlocked = () => Promise.resolve(true);
    let retired = 0;
    return {
        provider,
        requestConnectReplay() { return false; },
        retire() { retired += 1; },
        retired() { return retired; },
        snapshot() {
            return {
                accountRevision: 0,
                accountRevocationTombstone: false,
                address: provider.address,
                chainId: provider.chainId,
            };
        },
    };
}

function solanaFacadeTarget(name, address = firstSolanaKey) {
    const changeListeners = new Set;
    const account = {
        address,
        chains: ["solana:mainnet"],
        features: ["solana:signMessage"],
        label: "Big Wallet",
        publicKey: new Uint8Array(32),
    };
    const provider = Object.assign(new EventEmitter, {
        standardAccounts() { return [account]; },
        standardConnect: () => Promise.resolve(name),
        standardDisconnect: () => Promise.resolve(name),
        standardOn(event, listener) {
            if (event === "change") { changeListeners.add(listener); }
            return () => changeListeners.delete(listener);
        },
        standardSignAndSendTransaction: () => Promise.resolve(name),
        standardSignMessage: () => Promise.resolve(name),
        standardSignTransaction: () => Promise.resolve(name),
    });
    let retired = 0;
    return {
        changeListeners,
        provider,
        retire() { retired += 1; },
        retired() { return retired; },
        snapshot() {
            return {
                accountRevision: 0,
                accountRevocationTombstone: false,
                isConnected: true,
                publicKey: address,
                solanaAuthorizationEpoch: 0,
            };
        },
    };
}

test("stable facades retarget atomically while preserving identities and listeners", async () => {
    const harness = facadeHarness();
    const record = harness.exports.createStableFacadeRecord({
        icon: "data:image/svg+xml,<svg/>",
        uuid: "00000000-0000-4000-8000-000000000001",
    });
    const firstEthereum = ethereumFacadeTarget("first");
    const firstSolana = solanaFacadeTarget("first");
    const firstStage = record.prepareTargets({
        ethereumProvider: firstEthereum,
        solanaProvider: firstSolana,
    });
    assert.deepEqual(normalized(firstStage.commit()), {
        ethereum: null,
        solana: null,
    });
    const eipProvider = record.eip6963.provider;
    const wallet = record.wallet;
    const account = wallet.accounts[0];
    const events = [];
    const solanaEvents = [];
    eipProvider.on("accountsChanged", value => events.push(value));
    record.solana.on("accountChanged", value => solanaEvents.push(value));
    firstEthereum.provider.emit("accountsChanged", ["first"]);
    assert.deepEqual(events, [["first"]]);
    assert.equal(await eipProvider.request({method: "eth_chainId"}),
        "first:eth_chainId");

    const secondEthereum = ethereumFacadeTarget("second");
    const secondSolana = solanaFacadeTarget("second");
    const previous = record.prepareTargets({
        ethereumProvider: secondEthereum,
        solanaProvider: secondSolana,
    }).commit();
    assert.equal(record.eip6963.provider, eipProvider);
    assert.equal(
        record.eip6963.uuid,
        "00000000-0000-4000-8000-000000000001"
    );
    assert.equal(record.wallet, wallet);
    assert.equal(wallet.accounts[0], account);
    assert.equal(await eipProvider.request({method: "eth_chainId"}),
        "second:eth_chainId");
    assert.equal(
        await wallet.features["solana:signMessage"].signMessage({}),
        "second"
    );
    firstEthereum.provider.emit("accountsChanged", ["stale"]);
    secondEthereum.provider.emit("accountsChanged", ["second"]);
    firstSolana.provider.emit("accountChanged", "stale");
    secondSolana.provider.emit("accountChanged", "second");
    assert.deepEqual(events, [["first"], ["second"]]);
    assert.deepEqual(solanaEvents, ["second"]);
    previous.ethereum.retire();
    previous.solana.retire();
    assert.equal(firstEthereum.retired(), 1);
    assert.equal(firstSolana.retired(), 1);
});

test("stable Solana forwarding ignores an overridden public emitter", () => {
    const harness = facadeHarness();
    const record = harness.exports.createStableFacadeRecord({
        uuid: "00000000-0000-4000-8000-000000000008",
    });
    const solana = solanaFacadeTarget("current");
    record.prepareTargets({
        ethereumProvider: ethereumFacadeTarget("current"),
        solanaProvider: solana,
    }).commit();
    const events = [];
    record.solana.on("accountChanged", value => events.push(value));
    record.solana.emit = () => {
        throw new Error("overridden emit called");
    };

    solana.provider.emit("accountChanged", "current");

    assert.deepEqual(events, ["current"]);
});

test("stable facade connect snapshots survive reentrant retargeting", async () => {
    const harness = facadeHarness();
    const record = harness.exports.createStableFacadeRecord({
        uuid: "00000000-0000-4000-8000-000000000007",
    });
    const firstEthereum = ethereumFacadeTarget("first");
    const secondEthereum = ethereumFacadeTarget("second");
    const firstSolana = solanaFacadeTarget("first");
    const secondSolana = solanaFacadeTarget("second");
    firstEthereum.requestConnectReplay = listener => listener({
        chainId: "0x1",
    });
    const connects = [];
    record.eip6963.provider.on("connect", () => {
        connects.push("first");
        record.prepareTargets({
            ethereumProvider: secondEthereum,
            solanaProvider: secondSolana,
        }).commit();
    });
    record.eip6963.provider.on("connect", () => connects.push("second"));

    record.prepareTargets({
        ethereumProvider: firstEthereum,
        solanaProvider: firstSolana,
    }).commit();

    assert.deepEqual(connects, ["first", "second"]);
    assert.equal(
        await record.eip6963.provider.request({method: "test"}),
        "second:test"
    );
});

test("stable facade rollback keeps old targets and registration is issued once", async () => {
    const harness = facadeHarness();
    const record = harness.exports.createStableFacadeRecord({
        uuid: "00000000-0000-4000-8000-000000000002",
    });
    const ethereum = ethereumFacadeTarget("current");
    const solana = solanaFacadeTarget("current");
    record.prepareTargets({
        ethereumProvider: ethereum,
        solanaProvider: solana,
    }).commit();
    const stagedEthereum = ethereumFacadeTarget("staged");
    const stagedSolana = solanaFacadeTarget("staged");
    const stage = record.prepareTargets({
        ethereumProvider: stagedEthereum,
        solanaProvider: stagedSolana,
    });
    assert.equal(stage.rollback(), true);
    assert.equal(await record.eip6963.provider.request({method: "test"}),
        "current:test");
    assert.throws(() => record.prepareTargets({
        ethereumProvider: stagedEthereum,
        solanaProvider: {provider: {}},
    }));
    const hooklessEthereum = ethereumFacadeTarget("hookless");
    delete hooklessEthereum.requestConnectReplay;
    assert.throws(() => record.prepareTargets({
        ethereumProvider: hooklessEthereum,
        solanaProvider: stagedSolana,
    }), /Ethereum target is invalid/u);
    assert.equal(await record.eip6963.provider.request({method: "test"}),
        "current:test");

    assert.equal(record.ensureWalletRegistration(), record.wallet);
    assert.equal(record.ensureWalletRegistration(), record.wallet);
    assert.equal(harness.registeredWallets.length, 1);
    assert.equal(harness.window.navigator.wallets.length, 1);
    assert.equal(harness.exports.reusableStableFacadeRecord(record), record);
    assert.equal(harness.exports.reusableStableFacadeRecord({}), null);
});

test("stable facade supports absent and frozen app-first wallet hosts", () => {
    const queueHarness = facadeHarness({navigator: {}});
    const queued = queueHarness.exports.createStableFacadeRecord({
        uuid: "00000000-0000-4000-8000-000000000003",
    });
    queued.ensureWalletRegistration();
    assert.equal(Array.isArray(queueHarness.window.navigator.wallets), true);
    assert.equal(queueHarness.window.navigator.wallets.length, 1);

    let receiver = null;
    let registeredWallet = null;
    const registration = Object.freeze({
        register(wallet) {
            registeredWallet = wallet;
            return () => {};
        },
    });
    const host = Object.freeze({
        push(callback) {
            receiver = this;
            callback(registration);
        },
    });
    const navigator = {};
    Object.defineProperty(navigator, "wallets", {
        configurable: false,
        value: host,
        writable: false,
    });
    const hostHarness = facadeHarness({
        navigator,
        registerOnDispatch: false,
    });
    const hosted = hostHarness.exports.createStableFacadeRecord({
        uuid: "00000000-0000-4000-8000-000000000004",
    });
    assert.equal(hosted.ensureWalletRegistration(), hosted.wallet);
    assert.equal(receiver, host);
    assert.equal(registeredWallet, hosted.wallet);
    assert.equal(hostHarness.window.navigator.wallets, host);
    assert.equal(hosted.dispose, undefined);
});

function inpageHarness({beforeEvaluate} = {}) {
    const listeners = new Map;
    const listenerErrors = [];
    const postedMessages = [];
    const registeredWallets = [];
    const announcements = [];
    const timers = [];
    let uuidSerial = 1;
    const window = {
        crypto: {
            getRandomValues(values) {
                values.fill(uuidSerial);
                uuidSerial += 1;
                return values;
            },
            randomUUID() {
                const suffix = `${uuidSerial}`.padStart(12, "0");
                uuidSerial += 1;
                return `00000000-0000-4000-8000-${suffix}`;
            },
        },
        navigator: {wallets: []},
        addEventListener(name, listener) {
            if (!listeners.has(name)) { listeners.set(name, []); }
            listeners.get(name).push(listener);
        },
        removeEventListener(name, listener) {
            listeners.set(
                name,
                (listeners.get(name) || []).filter(value => value !== listener)
            );
        },
        dispatchEvent(event) {
            for (const listener of listeners.get(event.type) || []) {
                try {
                    listener.call(window, event);
                } catch (error) {
                    listenerErrors.push(error);
                }
            }
            return true;
        },
        postMessage(message) {
            postedMessages.push(normalized(message));
        },
    };
    window.addEventListener("wallet-standard:register-wallet", event => {
        event.detail({
            register(wallet) {
                registeredWallets.push(wallet);
                return () => {};
            },
        });
    });
    window.addEventListener("eip6963:announceProvider", event => {
        announcements.push(event.detail);
    });
    const context = vm.createContext({
        clearTimeout() {},
        console: {error() {}, log() {}},
        CustomEvent: HarnessCustomEvent,
        Event: HarnessEvent,
        setTimeout(callback) {
            timers.push(callback);
            return timers.length;
        },
        window,
    });
    beforeEvaluate?.(window, context);
    const evaluate = () => {
        new vm.Script(inpageSource, {filename: "inpage.js"}).runInContext(context);
    };
    evaluate();
    return {
        announcements,
        context,
        dispatch({generation, ...data}) {
            const message = {
                direction: "big-wallet-content-v1",
                providerGeneration: generation ??
                    window.bigWalletInpageProviderGenerationToken,
                ...data,
            };
            for (const listener of listeners.get("message") || []) {
                listener.call(window, {data: message, source: window});
            }
        },
        evaluate,
        listenerCount(name) { return (listeners.get(name) || []).length; },
        listenerErrors,
        postedMessages,
        registeredWallets,
        runTimers() {
            while (timers.length > 0) { timers.shift()(); }
        },
        window,
    };
}

function pageMessages(harness, kind, provider) {
    return harness.postedMessages.filter(envelope => {
        return envelope.kind === kind &&
            (typeof provider === "undefined" ||
                envelope.message?.provider === provider);
    });
}

function dispatchConfigurations(
    harness,
    {
        address = "",
        chainId = "0x1",
        publicKey = null,
        accountRevision = 0,
        solanaAuthorizationEpoch = 0,
        switchAccount = false,
    } = {},
    generation
) {
    const latestConfigurations = [{
        chainId,
        provider: "ethereum",
        results: address ? [address] : [],
    }];
    if (publicKey) {
        latestConfigurations.push({
            accountRevision,
            isConnected: true,
            provider: "solana",
            publicKey,
            solanaAuthorizationEpoch,
        });
    }
    harness.dispatch({
        generation,
        kind: "response",
        response: {
            latestConfigurations,
            ...(switchAccount
                ? {name: "switchAccount", provider: "unknown"}
                : {}),
        },
    });
}

function dispatchProviderResponse(
    harness,
    {
        generation,
        id,
        provider,
        name,
        ...response
    }
) {
    harness.dispatch({
        generation,
        id,
        kind: "response",
        response: {name, provider, ...response},
    });
}

test("inpage first install routes configuration, wallet, RPC, and error replies", async () => {
    const harness = inpageHarness();
    const {window} = harness;
    assert.equal(window.ethereum, window.bigwallet.eth);
    assert.equal(window.ethereum, window.web3.currentProvider);
    assert.equal(window.ethereum, window.metamask);
    assert.equal(window.solana, window.bigwallet.solana);
    assert.equal(window.solana, window.phantom.solana);
    assert.equal(harness.listenerCount("message"), 1);
    assert.equal(harness.listenerCount("eip6963:requestProvider"), 1);
    assert.equal(harness.announcements.length, 1);
    assert.equal(harness.registeredWallets.length, 1);

    const transaction = window.ethereum.request({
        method: "eth_sendTransaction",
        params: [{from: "0x0", value: "0x1"}],
    });
    const connection = window.solana.connect();
    assert.equal(pageMessages(harness, "request").length, 0);
    dispatchConfigurations(harness);
    const ethereumRequest = pageMessages(harness, "request", "ethereum")[0];
    const solanaRequest = pageMessages(harness, "request", "solana")[0];
    assert.equal(ethereumRequest.message.name, "signTransaction");
    assert.deepEqual(ethereumRequest.message.body.object, {
        from: "0x0",
        value: "0x1",
    });
    assert.equal(solanaRequest.message.name, "connect");
    dispatchProviderResponse(harness, {
        id: ethereumRequest.message.id,
        name: "signTransaction",
        provider: "ethereum",
        result: "0xhash",
    });
    dispatchProviderResponse(harness, {
        id: solanaRequest.message.id,
        name: "connect",
        provider: "solana",
        publicKey: firstSolanaKey,
    });
    assert.equal(await transaction, "0xhash");
    assert.equal((await connection).publicKey.toString(), firstSolanaKey);

    const block = window.ethereum.request({
        method: "eth_blockNumber",
        params: [],
    });
    const rpc = pageMessages(harness, "rpc").at(-1);
    harness.dispatch({
        id: rpc.message.id,
        kind: "rpc",
        response: {id: rpc.message.id, result: "0x10"},
    });
    assert.equal(await block, "0x10");

    const denied = window.ethereum.request({
        method: "personal_sign",
        params: ["0x01"],
    });
    const deniedRequest = pageMessages(harness, "request", "ethereum").at(-1);
    dispatchProviderResponse(harness, {
        error: "Canceled",
        errorCode: 4001,
        id: deniedRequest.message.id,
        name: deniedRequest.message.name,
        provider: "ethereum",
    });
    await assert.rejects(denied, error => error.code === 4001);
    assert.deepEqual(harness.listenerErrors, []);
});

test("configuration-changing terminal responses update state and settle", async () => {
    const harness = inpageHarness();
    const address = "0x0000000000000000000000000000000000000001";
    dispatchConfigurations(harness);
    const request = harness.window.ethereum.request({
        method: "eth_requestAccounts",
    });
    const message = pageMessages(harness, "request", "ethereum").at(-1);
    dispatchProviderResponse(harness, {
        id: message.message.id,
        name: message.message.name,
        provider: "ethereum",
        chainId: "0x2",
        results: [address],
        latestConfigurations: [{
            provider: "ethereum",
            chainId: "0x2",
            results: [address],
        }],
    });
    assert.deepEqual(normalized(await request), [address]);
    assert.equal(harness.window.ethereum.selectedAddress, address);
    assert.equal(harness.window.ethereum.chainId, "0x2");
    assert.equal(
        harness.window.bigWalletInpageStableFacadeRecord.snapshots()
            .ethereum.accountRevision,
        1
    );
});

test("combined requestAccounts response reauthorizes a revoked account", async () => {
    const harness = inpageHarness();
    const address = "0x0000000000000000000000000000000000000001";
    dispatchConfigurations(harness, {address});
    const revocation = harness.window.ethereum.request({
        method: "wallet_revokePermissions",
        params: [{eth_accounts: {}}],
    });
    const disconnect = pageMessages(harness, "disconnect", "ethereum").at(-1);
    dispatchProviderResponse(harness, {
        id: disconnect.message.id,
        name: "revokePermissions",
        provider: "ethereum",
        result: null,
    });
    await revocation;

    const reconnect = harness.window.ethereum.request({
        method: "eth_requestAccounts",
    });
    const request = pageMessages(harness, "request", "ethereum").at(-1);
    dispatchProviderResponse(harness, {
        id: request.message.id,
        name: "requestAccounts",
        provider: "ethereum",
        results: [address],
        latestConfigurations: [{
            chainId: "0x1",
            provider: "ethereum",
            results: [address],
        }],
    });
    assert.deepEqual(normalized(await reconnect), [address]);
    assert.equal(harness.window.ethereum.selectedAddress, address);
});

test("committed requestAccounts preserves a tombstone on configuration drift", async () => {
    const harness = inpageHarness();
    const approvedAddress =
        "0x0000000000000000000000000000000000000001";
    const authoritativeAddress =
        "0x0000000000000000000000000000000000000002";
    dispatchConfigurations(harness, {address: approvedAddress});
    const revocation = harness.window.ethereum.request({
        method: "wallet_revokePermissions",
        params: [{eth_accounts: {}}],
    });
    const disconnect = pageMessages(harness, "disconnect", "ethereum").at(-1);
    dispatchProviderResponse(harness, {
        id: disconnect.message.id,
        name: "revokePermissions",
        provider: "ethereum",
        result: null,
    });
    await revocation;

    const before = harness.window.bigWalletInpageStableFacadeRecord
        .snapshots().ethereum;
    let accountChanges = 0;
    harness.window.ethereum.on("accountsChanged", () => {
        accountChanges += 1;
    });
    const reconnect = harness.window.ethereum.request({
        method: "eth_requestAccounts",
    });
    const request = pageMessages(harness, "request", "ethereum").at(-1);
    dispatchProviderResponse(harness, {
        __bwApprovalCommitted: true,
        id: request.message.id,
        latestConfigurations: [{
            chainId: "0x1",
            provider: "ethereum",
            results: [authoritativeAddress],
        }],
        name: "requestAccounts",
        provider: "ethereum",
        results: [approvedAddress],
    });

    assert.deepEqual(normalized(await reconnect), [approvedAddress]);
    assert.deepEqual(
        harness.window.bigWalletInpageStableFacadeRecord.snapshots().ethereum,
        before
    );
    assert.equal(harness.window.ethereum.selectedAddress, null);
    assert.equal(accountChanges, 0);
});

test("combined Solana connect settles initial and revoked connections once", async () => {
    const harness = inpageHarness();
    dispatchConfigurations(harness);
    let connects = 0;
    harness.window.solana.on("connect", () => { connects += 1; });
    const initial = harness.window.solana.connect();
    const initialRequest = pageMessages(harness, "request", "solana").at(-1);
    dispatchProviderResponse(harness, {
        id: initialRequest.message.id,
        name: "connect",
        provider: "solana",
        publicKey: firstSolanaKey,
        latestConfigurations: [{
            provider: "solana",
            publicKey: firstSolanaKey,
        }],
    });
    assert.equal((await initial).publicKey.toString(), firstSolanaKey);
    assert.equal(connects, 1);

    const disconnecting = harness.window.solana.disconnect();
    const disconnect = pageMessages(harness, "disconnect", "solana").at(-1);
    dispatchProviderResponse(harness, {
        id: disconnect.message.id,
        name: "revokePermissions",
        provider: "solana",
        result: true,
    });
    await disconnecting;
    const reconnect = harness.window.solana.connect();
    const reconnectRequest = pageMessages(harness, "request", "solana").at(-1);
    dispatchProviderResponse(harness, {
        id: reconnectRequest.message.id,
        name: "connect",
        provider: "solana",
        publicKey: firstSolanaKey,
        latestConfigurations: [{
            provider: "solana",
            publicKey: firstSolanaKey,
        }],
    });
    assert.equal((await reconnect).publicKey.toString(), firstSolanaKey);
    assert.equal(connects, 2);
    assert.equal(harness.window.solana.accountRevocationTombstone, false);
});

test("committed Solana connect preserves a tombstone on configuration drift", async () => {
    const harness = inpageHarness();
    dispatchConfigurations(harness, {publicKey: firstSolanaKey});
    const disconnecting = harness.window.solana.disconnect();
    const disconnect = pageMessages(harness, "disconnect", "solana").at(-1);
    dispatchProviderResponse(harness, {
        id: disconnect.message.id,
        name: "revokePermissions",
        provider: "solana",
        result: true,
    });
    await disconnecting;

    const before = harness.window.bigWalletInpageStableFacadeRecord
        .snapshots().solana;
    let accountChanges = 0;
    let connects = 0;
    harness.window.solana.on("accountChanged", () => {
        accountChanges += 1;
    });
    harness.window.solana.on("connect", () => {
        connects += 1;
    });
    const connecting = harness.window.solana.connect();
    const request = pageMessages(harness, "request", "solana").at(-1);
    dispatchProviderResponse(harness, {
        __bwApprovalCommitted: true,
        id: request.message.id,
        latestConfigurations: [{
            provider: "solana",
            publicKey: secondSolanaKey,
        }],
        name: "connect",
        provider: "solana",
        publicKey: firstSolanaKey,
    });

    assert.equal((await connecting).publicKey.toString(), firstSolanaKey);
    assert.deepEqual(
        harness.window.bigWalletInpageStableFacadeRecord.snapshots().solana,
        before
    );
    assert.equal(harness.window.solana.publicKey, null);
    assert.equal(harness.window.solana.accountRevocationTombstone, true);
    assert.equal(accountChanges, 0);
    assert.equal(connects, 0);
});

test("late combined Solana connect never undoes a newer disconnect", async () => {
    for (const approvalCommitted of [false, true]) {
        const harness = inpageHarness();
        dispatchConfigurations(harness);
        const connecting = harness.window.solana.connect();
        const connect = pageMessages(harness, "request", "solana").at(-1);
        const rejected = approvalCommitted
            ? null
            : assert.rejects(connecting, error => error.code === 4900);
        const disconnecting = harness.window.solana.disconnect();
        const disconnect = pageMessages(harness, "disconnect", "solana").at(-1);
        const disconnected = harness.window.bigWalletInpageStableFacadeRecord
            .snapshots().solana;

        dispatchProviderResponse(harness, {
            ...(approvalCommitted ? {__bwApprovalCommitted: true} : {}),
            id: connect.message.id,
            latestConfigurations: [{
                provider: "solana",
                publicKey: firstSolanaKey,
            }],
            name: "connect",
            provider: "solana",
            publicKey: firstSolanaKey,
        });

        if (approvalCommitted) {
            assert.equal(
                (await connecting).publicKey.toString(),
                firstSolanaKey
            );
        } else {
            await rejected;
        }
        assert.deepEqual(
            harness.window.bigWalletInpageStableFacadeRecord
                .snapshots().solana,
            disconnected
        );
        assert.equal(harness.window.solana.publicKey, null);
        assert.equal(harness.window.solana.accountRevocationTombstone, true);

        dispatchProviderResponse(harness, {
            id: disconnect.message.id,
            name: "revokePermissions",
            provider: "solana",
            result: true,
        });
        await disconnecting;
    }
});

test("committed combined Solana connect preserves a reentrant disconnect", async () => {
    const harness = inpageHarness();
    dispatchConfigurations(harness);
    let disconnecting = null;
    const changes = [];
    harness.window.solana.on("accountChanged", publicKey => {
        changes.push(publicKey?.toString() || null);
        if (publicKey && disconnecting === null) {
            disconnecting = harness.window.solana.disconnect();
        }
    });
    const connecting = harness.window.solana.connect();
    const request = pageMessages(harness, "request", "solana").at(-1);
    dispatchProviderResponse(harness, {
        __bwApprovalCommitted: true,
        id: request.message.id,
        latestConfigurations: [{
            provider: "solana",
            publicKey: firstSolanaKey,
        }],
        name: "connect",
        provider: "solana",
        publicKey: firstSolanaKey,
    });

    assert.equal((await connecting).publicKey.toString(), firstSolanaKey);
    assert.deepEqual(changes, [firstSolanaKey, null]);
    assert.equal(harness.window.solana.publicKey, null);
    assert.equal(harness.window.solana.accountRevocationTombstone, true);
    const disconnect = pageMessages(harness, "disconnect", "solana").at(-1);
    dispatchProviderResponse(harness, {
        id: disconnect.message.id,
        name: "revokePermissions",
        provider: "solana",
        result: true,
    });
    await disconnecting;
    assert.equal(harness.window.solana.publicKey, null);
});

test("uncommitted combined Solana connect rejects after a reentrant disconnect", async () => {
    const harness = inpageHarness();
    dispatchConfigurations(harness);
    let disconnecting = null;
    harness.window.solana.on("accountChanged", publicKey => {
        if (publicKey && disconnecting === null) {
            disconnecting = harness.window.solana.disconnect();
        }
    });
    const connecting = harness.window.solana.connect();
    const rejected = assert.rejects(connecting, error => error.code === 4900);
    const request = pageMessages(harness, "request", "solana").at(-1);
    dispatchProviderResponse(harness, {
        id: request.message.id,
        latestConfigurations: [{
            provider: "solana",
            publicKey: firstSolanaKey,
        }],
        name: "connect",
        provider: "solana",
        publicKey: firstSolanaKey,
    });

    await rejected;
    assert.equal(harness.window.solana.publicKey, null);
    assert.equal(harness.window.solana.accountRevocationTombstone, true);
    const disconnect = pageMessages(harness, "disconnect", "solana").at(-1);
    dispatchProviderResponse(harness, {
        id: disconnect.message.id,
        name: "revokePermissions",
        provider: "solana",
        result: true,
    });
    await disconnecting;
    assert.equal(harness.window.solana.publicKey, null);
});

test("combined manual switch applies its authoritative configuration once", () => {
    const harness = inpageHarness();
    const firstAddress = "0x0000000000000000000000000000000000000001";
    const secondAddress = "0x0000000000000000000000000000000000000002";
    dispatchConfigurations(harness, {
        accountRevision: 1,
        address: firstAddress,
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    });
    const before = harness.window.bigWalletInpageStableFacadeRecord.snapshots();
    let ethereumChanges = 0;
    let solanaChanges = 0;
    harness.window.ethereum.on("accountsChanged", () => {
        ethereumChanges += 1;
    });
    harness.window.solana.on("accountChanged", () => {
        solanaChanges += 1;
    });
    const ethereumConfiguration = {
        chainId: "0x2",
        provider: "ethereum",
        results: [secondAddress],
    };
    const solanaConfiguration = {
        accountRevision: before.solana.accountRevision + 1,
        isConnected: true,
        provider: "solana",
        publicKey: secondSolanaKey,
        solanaAuthorizationEpoch: before.solana.solanaAuthorizationEpoch + 1,
    };

    harness.dispatch({
        id: 101,
        kind: "response",
        response: {
            bodies: [ethereumConfiguration, solanaConfiguration],
            id: 101,
            latestConfigurations: [ethereumConfiguration, solanaConfiguration],
            name: "switchAccount",
            provider: "multiple",
            providersToDisconnect: [],
        },
    });

    const after = harness.window.bigWalletInpageStableFacadeRecord.snapshots();
    assert.equal(after.ethereum.accountRevision, before.ethereum.accountRevision + 1);
    assert.equal(after.solana.accountRevision, before.solana.accountRevision + 1);
    assert.equal(harness.window.ethereum.selectedAddress, secondAddress);
    assert.equal(harness.window.solana.publicKey.toString(), secondSolanaKey);
    assert.equal(ethereumChanges, 1);
    assert.equal(solanaChanges, 1);
});

test("manual switch does not undo a reentrant Solana disconnect", async () => {
    const harness = inpageHarness();
    dispatchConfigurations(harness);
    let disconnecting = null;
    harness.window.solana.on("accountChanged", publicKey => {
        if (publicKey && disconnecting === null) {
            disconnecting = harness.window.solana.disconnect();
        }
    });
    const ethereumConfiguration = {
        chainId: "0x1",
        provider: "ethereum",
        results: [],
    };
    const solanaConfiguration = {
        accountRevision: 1,
        isConnected: true,
        provider: "solana",
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
    };
    harness.dispatch({
        id: 103,
        kind: "response",
        response: {
            bodies: [ethereumConfiguration, solanaConfiguration],
            id: 103,
            latestConfigurations: [ethereumConfiguration, solanaConfiguration],
            name: "switchAccount",
            provider: "multiple",
            providersToDisconnect: [],
        },
    });

    assert.ok(disconnecting);
    assert.equal(harness.window.solana.publicKey, null);
    assert.equal(harness.window.solana.accountRevocationTombstone, true);
    const disconnect = pageMessages(harness, "disconnect", "solana").at(-1);
    dispatchProviderResponse(harness, {
        id: disconnect.message.id,
        name: "revokePermissions",
        provider: "solana",
        result: true,
    });
    await disconnecting;
    assert.equal(harness.window.solana.publicKey, null);
});

test("committed chain result preserves a newer authoritative chain", async () => {
    const harness = inpageHarness();
    dispatchConfigurations(harness, {chainId: "0x1"});
    const switching = harness.window.ethereum.request({
        method: "wallet_switchEthereumChain",
        params: [{chainId: "0x2"}],
    });
    const request = pageMessages(harness, "request", "ethereum").at(-1);
    dispatchProviderResponse(harness, {
        __bwApprovalCommitted: true,
        chainId: "0x2",
        id: request.message.id,
        latestConfigurations: [{
            chainId: "0x3",
            provider: "ethereum",
            results: [],
        }],
        name: "switchEthereumChain",
        provider: "ethereum",
        result: null,
    });

    assert.equal(await switching, null);
    assert.equal(harness.window.ethereum.chainId, "0x3");
});

test("terminal configuration failure retires loading providers", async () => {
    const harness = inpageHarness();
    const ethereum = harness.window.ethereum.request({method: "eth_chainId"});
    const solana = harness.window.solana.connect();
    let ethereumSettled = false;
    void ethereum.catch(() => { ethereumSettled = true; });

    harness.dispatch({
        generation: "stale-generation",
        kind: "configurationError",
    });
    await Promise.resolve();
    assert.equal(ethereumSettled, false);

    harness.dispatch({kind: "configurationError"});
    await assert.rejects(ethereum, error => {
        return error.code === 4900 &&
            error.message === "Failed to communicate with Big Wallet";
    });
    await assert.rejects(solana, error => error.code === 4900);
    await assert.rejects(
        harness.window.ethereum.request({method: "eth_chainId"}),
        error => error.code === 4900
    );
});

test("inpage delivers one authoritative connect to early and late listeners", () => {
    const earlyHarness = inpageHarness();
    const earlyDirect = [];
    const earlyFacade = [];
    earlyHarness.window.ethereum.on("connect", value => {
        earlyDirect.push(normalized(value));
    });
    earlyHarness.window.bigWalletInpageStableFacadeRecord.eip6963.provider.on(
        "connect",
        value => earlyFacade.push(normalized(value))
    );
    dispatchConfigurations(earlyHarness, {chainId: "0x2"});
    earlyHarness.runTimers();
    assert.deepEqual(earlyDirect, [{chainId: "0x2"}]);
    assert.deepEqual(earlyFacade, [{chainId: "0x2"}]);

    const lateHarness = inpageHarness();
    dispatchConfigurations(lateHarness, {chainId: "0x3"});
    const lateDirect = [];
    const lateFacade = [];
    assert.equal(
        lateHarness.window.ethereum,
        lateHarness.window.bigWalletInpageStableFacadeRecord.eip6963.provider
    );
    lateHarness.window.ethereum.on("connect", value => {
        lateDirect.push(normalized(value));
    });
    lateHarness.runTimers();
    assert.deepEqual(lateDirect, [{chainId: "0x3"}]);
    assert.deepEqual(lateFacade, []);

    lateHarness.window.ethereum.on("connect", value => {
        lateDirect.push(["later", normalized(value)]);
    });
    lateHarness.window.bigWalletInpageStableFacadeRecord.eip6963.provider.on(
        "connect",
        value => {
        lateFacade.push(["later", normalized(value)]);
        }
    );
    lateHarness.runTimers();
    assert.deepEqual(lateDirect, [{chainId: "0x3"}]);
    assert.deepEqual(lateFacade, []);
});

test("public connect emits do not consume the stable facade replay", () => {
    const harness = inpageHarness();
    dispatchConfigurations(harness, {chainId: "0x5"});
    const facade = harness.window.bigWalletInpageStableFacadeRecord
        .eip6963.provider;
    const connects = [];
    harness.window.ethereum.removeAllListeners("connect");
    facade.once("connect", value => connects.push(normalized(value)));
    assert.equal(facade.emit("connect", {chainId: "0x998"}), false);
    let spoofed = false;
    harness.window.ethereum.prependListener("connect", value => {
        if (!spoofed && value.chainId === "0x5") {
            spoofed = true;
            harness.window.ethereum.emit("connect", {chainId: "0x999"});
        }
    });

    harness.runTimers();

    assert.deepEqual(connects, [{chainId: "0x5"}]);
    facade.prependListener("connect", value => {
        connects.push(["later", normalized(value)]);
    });
    harness.runTimers();
    assert.deepEqual(connects, [{chainId: "0x5"}]);
});

test("inpage rejects missing and ambiguous terminals and bounds bridge arrays", async () => {
    const harness = inpageHarness();
    const queued = harness.window.ethereum.request({method: "eth_chainId"});
    harness.dispatch({
        kind: "response",
        response: {
            latestConfigurations: new Array(65).fill({
                chainId: "0x2",
                provider: "ethereum",
                results: [],
            }),
        },
    });
    assert.equal(pageMessages(harness, "rpc").length, 0);
    dispatchConfigurations(harness, {chainId: "0x2"});
    assert.equal(await queued, "0x2");

    for (const terminal of [
        {},
        {result: "value", results: ["other"]},
    ]) {
        const request = harness.window.ethereum.request({
            method: "eth_sendTransaction",
            params: [{value: "0x1"}],
        });
        const message = pageMessages(harness, "request", "ethereum").at(-1);
        dispatchProviderResponse(harness, {
            id: message.message.id,
            name: message.message.name,
            provider: "ethereum",
            ...terminal,
        });
        await assert.rejects(request, error => error.code === -32603);
    }

    const malformedConfiguration = harness.window.ethereum.request({
        method: "eth_sendTransaction",
        params: [{value: "0x1"}],
    });
    const malformedMessage = pageMessages(
        harness,
        "request",
        "ethereum"
    ).at(-1);
    harness.dispatch({
        id: malformedMessage.message.id,
        kind: "response",
        response: {
            latestConfigurations: null,
            name: malformedMessage.message.name,
            provider: "ethereum",
            result: "0xhash",
        },
    });
    await assert.rejects(
        malformedConfiguration,
        error => error.code === -32603
    );

    const pending = harness.window.ethereum.request({
        method: "eth_sendTransaction",
        params: [{value: "0x2"}],
    });
    const pendingMessage = pageMessages(harness, "request", "ethereum").at(-1);
    harness.dispatch({
        id: pendingMessage.message.id,
        kind: "response",
        response: {
            bodies: new Array(65).fill({
                name: pendingMessage.message.name,
                provider: "ethereum",
                result: "stale",
            }),
            name: pendingMessage.message.name,
            provider: "multiple",
            providersToDisconnect: [],
        },
    });
    let settled = false;
    pending.finally(() => { settled = true; });
    await Promise.resolve();
    assert.equal(settled, false);
    dispatchProviderResponse(harness, {
        id: pendingMessage.message.id,
        name: pendingMessage.message.name,
        provider: "ethereum",
        result: "current",
    });
    assert.equal(await pending, "current");
});

test("inpage configuration getter reentry preserves the newer configuration", () => {
    for (const surface of ["array", "results"]) {
        const harness = inpageHarness();
        const newerAddress =
            "0x0000000000000000000000000000000000000003";
        const staleAddress =
            "0x0000000000000000000000000000000000000002";
        const nested = () => dispatchConfigurations(harness, {
            address: newerAddress,
            chainId: "0x3",
        });
        let configurations;
        if (surface === "array") {
            configurations = [];
            Object.defineProperty(configurations, 0, {
                configurable: true,
                enumerable: true,
                get() {
                    nested();
                    return {
                        chainId: "0x2",
                        provider: "ethereum",
                        results: [staleAddress],
                    };
                },
            });
            configurations.length = 1;
        } else {
            const results = [];
            Object.defineProperty(results, 0, {
                configurable: true,
                enumerable: true,
                get() {
                    nested();
                    return staleAddress;
                },
            });
            results.length = 1;
            configurations = [{
                chainId: "0x2",
                provider: "ethereum",
                results,
            }];
        }
        harness.dispatch({
            kind: "response",
            response: {latestConfigurations: configurations},
        });
        assert.equal(harness.window.ethereum.selectedAddress, newerAddress);
        assert.equal(harness.window.ethereum.chainId, "0x3");
    }
});

test("invalid nested ingress cannot suppress a valid outer configuration", () => {
    const harness = inpageHarness();
    let didReenter = false;
    const response = new Proxy({
        latestConfigurations: [{
            chainId: "0x2",
            provider: "ethereum",
            results: [],
        }],
    }, {
        getOwnPropertyDescriptor(target, name) {
            if (name === "latestConfigurations" && !didReenter) {
                didReenter = true;
                harness.dispatch({
                    generation: "stale-generation",
                    kind: "response",
                    response: {latestConfigurations: []},
                });
                harness.dispatch({kind: "invalid", response: {}});
                harness.dispatch({
                    kind: "response",
                    response: {
                        latestConfigurations: [{
                            chainId: 2,
                            provider: "ethereum",
                            results: [],
                        }],
                    },
                });
                const throwingResponse = new Proxy({
                    latestConfigurations: [],
                }, {
                    getOwnPropertyDescriptor(nestedTarget, nestedName) {
                        if (nestedName === "latestConfigurations") {
                            throw new Error("invalid nested response");
                        }
                        return Reflect.getOwnPropertyDescriptor(
                            nestedTarget,
                            nestedName
                        );
                    },
                });
                harness.dispatch({
                    kind: "response",
                    response: throwingResponse,
                });
            }
            return Reflect.getOwnPropertyDescriptor(target, name);
        },
    });
    harness.dispatch({kind: "response", response});
    assert.equal(harness.window.ethereum.chainId, "0x2");
});

test("reentrant terminal ingress settles without overwriting newer chain state", async () => {
    const harness = inpageHarness();
    dispatchConfigurations(harness, {chainId: "0x1"});
    const request = harness.window.ethereum.request({
        method: "wallet_switchEthereumChain",
        params: [{chainId: "0x2"}],
    });
    const message = pageMessages(harness, "request", "ethereum").at(-1);
    let didReenter = false;
    const response = new Proxy({
        name: message.message.name,
        provider: "ethereum",
        result: null,
    }, {
        getOwnPropertyDescriptor(target, name) {
            if (name === "result" && !didReenter) {
                didReenter = true;
                dispatchConfigurations(harness, {chainId: "0x3"});
            }
            return Reflect.getOwnPropertyDescriptor(target, name);
        },
    });
    harness.dispatch({
        id: message.message.id,
        kind: "response",
        response,
    });
    assert.equal(await request, null);
    assert.equal(harness.window.ethereum.chainId, "0x3");
});

test("terminal ingress settles when shallow validation observes newer state", async () => {
    const harness = inpageHarness();
    dispatchConfigurations(harness, {chainId: "0x1"});
    const request = harness.window.ethereum.request({
        method: "wallet_switchEthereumChain",
        params: [{chainId: "0x2"}],
    });
    const message = pageMessages(harness, "request", "ethereum").at(-1);
    const terminal = {
        name: message.message.name,
        provider: "ethereum",
        result: null,
    };
    let reentered = false;
    const envelope = new Proxy({
        direction: "big-wallet-content-v1",
        id: message.message.id,
        kind: "response",
        providerGeneration:
            harness.window.bigWalletInpageProviderGenerationToken,
        response: terminal,
    }, {
        getOwnPropertyDescriptor(target, name) {
            if (name === "response" && !reentered) {
                reentered = true;
                dispatchConfigurations(harness, {chainId: "0x3"});
            }
            return Reflect.getOwnPropertyDescriptor(target, name);
        },
    });
    harness.window.bigWalletInpageContentBridgeHandler({
        data: envelope,
        source: harness.window,
    });
    assert.equal(await request, null);
    assert.equal(harness.window.ethereum.chainId, "0x3");
});

test("inpage rejects direct and RPC response ID mismatches", async () => {
    const harness = inpageHarness();
    dispatchConfigurations(harness);
    const direct = harness.window.ethereum.request({
        method: "eth_sendTransaction",
        params: [{value: "0x1"}],
    });
    const directMessage = pageMessages(harness, "request", "ethereum").at(-1);
    harness.dispatch({
        id: directMessage.message.id,
        kind: "response",
        response: {
            id: directMessage.message.id + 1,
            name: directMessage.message.name,
            provider: "ethereum",
            result: "wrong",
        },
    });
    await assert.rejects(direct, error => error.code === -32603);

    const rpc = harness.window.ethereum.request({
        method: "eth_blockNumber",
        params: [],
    });
    const rpcMessage = pageMessages(harness, "rpc").at(-1);
    harness.dispatch({
        id: rpcMessage.message.id,
        kind: "rpc",
        response: {
            id: rpcMessage.message.id + 1,
            result: "wrong",
        },
    });
    await assert.rejects(rpc, error => error.code === -32603);
});

test("inpage derives terminal ownership from provider-distinct wire IDs", async () => {
    const harness = inpageHarness();
    dispatchConfigurations(harness, {publicKey: firstSolanaKey});
    const ethereum = harness.window.ethereum.request({
        method: "eth_sendTransaction",
        params: [{value: "0x1"}],
    });
    const solana = harness.window.solana.signMessage(new Uint8Array([1]));
    const ethereumMessage = pageMessages(
        harness,
        "request",
        "ethereum"
    ).at(-1);
    const solanaMessage = pageMessages(harness, "request", "solana").at(-1);
    assert.equal(ethereumMessage.message.id % 2, 1);
    assert.equal(solanaMessage.message.id % 2, 0);
    dispatchProviderResponse(harness, {
        id: ethereumMessage.message.id,
        name: ethereumMessage.message.name,
        provider: "solana",
        result: validSignature,
    });
    await assert.rejects(ethereum, error => error.code === -32603);
    let solanaSettled = false;
    solana.finally(() => { solanaSettled = true; });
    await Promise.resolve();
    assert.equal(solanaSettled, false);
    dispatchProviderResponse(harness, {
        id: solanaMessage.message.id,
        name: solanaMessage.message.name,
        provider: "solana",
        result: validSignature,
    });
    assert.equal((await solana).signature.length, 64);

    const wrongKind = harness.window.solana.signMessage(new Uint8Array([2]));
    const wrongKindMessage = pageMessages(
        harness,
        "request",
        "solana"
    ).at(-1);
    harness.dispatch({
        id: wrongKindMessage.message.id,
        kind: "rpc",
        response: {id: wrongKindMessage.message.id, result: "wrong"},
    });
    await assert.rejects(wrongKind, error => error.code === -32603);
});

test("Solana 4100 ingress revokes authorization and advances its epoch", async () => {
    const harness = inpageHarness();
    dispatchConfigurations(harness, {publicKey: firstSolanaKey});
    const beforeRevision = harness.window.solana.accountRevision;
    const beforeEpoch = harness.window.solana.solanaAuthorizationEpoch;
    const request = harness.window.solana.signMessage(new Uint8Array([1]));
    const message = pageMessages(harness, "request", "solana").at(-1);
    dispatchProviderResponse(harness, {
        error: "Unauthorized",
        errorCode: 4100,
        errorPublicKey: firstSolanaKey,
        id: message.message.id,
        name: message.message.name,
        provider: "solana",
    });
    await assert.rejects(request, error => error.code === 4100);
    assert.equal(harness.window.solana.publicKey, null);
    assert.equal(harness.window.solana.accountRevocationTombstone, true);
    assert.equal(
        harness.window.solana.accountRevision > beforeRevision,
        true
    );
    assert.equal(
        harness.window.solana.solanaAuthorizationEpoch > beforeEpoch,
        true
    );
    assert.equal(
        pageMessages(harness, "solanaAuthorizationEpoch").length > 0,
        true
    );
});

test("Solana 4100 without an account marker leaves authorization intact", async () => {
    const harness = inpageHarness();
    dispatchConfigurations(harness, {publicKey: firstSolanaKey});
    const request = harness.window.solana.signMessage(new Uint8Array([1]));
    const message = pageMessages(harness, "request", "solana").at(-1);
    dispatchProviderResponse(harness, {
        error: "Authorization changed while the request was pending",
        errorCode: 4100,
        id: message.message.id,
        name: message.message.name,
        provider: "solana",
    });

    await assert.rejects(request, error => error.code === 4100);
    assert.equal(harness.window.solana.publicKey.toString(), firstSolanaKey);
    assert.equal(harness.window.solana.accountRevocationTombstone, false);
});

test("Solana omission disconnects externally for ordinary and switch snapshots", () => {
    for (const switchAccount of [false, true]) {
        const harness = inpageHarness();
        dispatchConfigurations(harness, {publicKey: firstSolanaKey});
        const beforeEpoch = harness.window.solana.solanaAuthorizationEpoch;
        harness.dispatch({
            kind: "response",
            response: {
                latestConfigurations: [{
                    chainId: "0x1",
                    provider: "ethereum",
                    results: [],
                }],
                ...(switchAccount
                    ? {name: "switchAccount", provider: "unknown"}
                    : {}),
            },
        });
        assert.equal(harness.window.solana.publicKey, null);
        assert.equal(harness.window.solana.accountRevocationTombstone, true);
        assert.equal(
            harness.window.solana.solanaAuthorizationEpoch,
            beforeEpoch + 1
        );
        assert.equal(
            pageMessages(harness, "solanaAuthorizationEpoch").length > 0,
            true
        );
    }
});

test("Solana omission makes a copied loading provider ready", async () => {
    const harness = inpageHarness();
    dispatchConfigurations(harness, {publicKey: firstSolanaKey});
    harness.evaluate();
    const requestCount = pageMessages(harness, "request", "solana").length;
    const signing = harness.window.solana.signMessage(new Uint8Array([1]));
    const rejected = assert.rejects(signing, error => error.code === 4100);
    assert.equal(
        pageMessages(harness, "request", "solana").length,
        requestCount
    );
    harness.dispatch({
        kind: "response",
        response: {
            latestConfigurations: [{
                chainId: "0x1",
                provider: "ethereum",
                results: [],
            }],
        },
    });
    await rejected;
    assert.equal(harness.window.solana.didGetLatestConfiguration, true);
    assert.equal(harness.window.solana.publicKey, null);
});

test("same-key Solana switch reauthorization fences a late 4100", async () => {
    const harness = inpageHarness();
    dispatchConfigurations(harness, {publicKey: firstSolanaKey});
    const beforeRevision = harness.window.solana.accountRevision;
    const pending = harness.window.solana.signMessage(new Uint8Array([1]));
    const pendingMessage = pageMessages(harness, "request", "solana").at(-1);
    harness.dispatch({
        kind: "response",
        response: {
            latestConfigurations: [{
                chainId: "0x1",
                provider: "ethereum",
                results: [],
            }, {
                provider: "solana",
                publicKey: firstSolanaKey,
            }],
            name: "switchAccount",
            provider: "unknown",
        },
    });
    assert.equal(
        harness.window.solana.accountRevision > beforeRevision,
        true
    );
    dispatchProviderResponse(harness, {
        error: "Late unauthorized",
        errorCode: 4100,
        id: pendingMessage.message.id,
        name: pendingMessage.message.name,
        provider: "solana",
    });
    await assert.rejects(pending, error => error.code === 4100);
    assert.equal(harness.window.solana.publicKey.toString(), firstSolanaKey);
    assert.equal(harness.window.solana.accountRevocationTombstone, false);
});

test("sparse and duplicate configuration arrays are ignored atomically", async () => {
    const harness = inpageHarness();
    dispatchConfigurations(harness, {publicKey: firstSolanaKey});
    const revision = harness.window.solana.accountRevision;
    const epoch = harness.window.solana.solanaAuthorizationEpoch;
    const sparse = [{
        chainId: "0x2",
        provider: "ethereum",
        results: [],
    }];
    sparse.length = 2;
    harness.dispatch({
        kind: "response",
        response: {latestConfigurations: sparse},
    });
    harness.dispatch({
        kind: "response",
        response: {
            latestConfigurations: [{
                provider: "solana",
                publicKey: secondSolanaKey,
            }, {
                provider: "solana",
                publicKey: null,
            }],
        },
    });
    const invalidChainIds = ["0X1", "0xA", "0x01"];
    const invalidConfigurations = [[{
        chainId: 2,
        provider: "ethereum",
        results: [],
    }, {
        provider: "solana",
        publicKey: secondSolanaKey,
    }], [{
        chainId: "0x2",
        provider: "ethereum",
        results: "not-an-array",
    }, {
        provider: "solana",
        publicKey: secondSolanaKey,
    }], [{
        chainId: "0x2",
        provider: "ethereum",
        results: [],
    }, {
        provider: "solana",
        publicKey: "invalid-public-key",
    }], ...invalidChainIds.map(chainId => [{
        chainId,
        provider: "ethereum",
        results: [],
    }, {
        provider: "solana",
        publicKey: secondSolanaKey,
    }])];
    for (const latestConfigurations of invalidConfigurations) {
        harness.dispatch({
            kind: "response",
            response: {latestConfigurations},
        });
    }
    assert.equal(harness.window.solana.publicKey.toString(), firstSolanaKey);
    assert.equal(harness.window.solana.accountRevision, revision);
    assert.equal(harness.window.solana.solanaAuthorizationEpoch, epoch);
    assert.equal(harness.window.ethereum.chainId, "0x1");
    assert.equal(
        await harness.window.ethereum.request({method: "eth_chainId"}),
        "0x1"
    );
});

test("Solana ingress preserves canonical error data and error signatures", async () => {
    const harness = inpageHarness();
    dispatchConfigurations(harness, {publicKey: firstSolanaKey});
    const cases = [{
        errorDataJSON: JSON.stringify({reason: "denied"}),
        validate(error) {
            return error.code === 4001 && error.data?.reason === "denied";
        },
    }, {
        errorSignature: validSignature,
        validate(error) {
            return error.code === 4001 &&
                error.data?.signature === validSignature;
        },
    }];
    for (const testCase of cases) {
        const request = harness.window.solana.signMessage(new Uint8Array([1]));
        const message = pageMessages(harness, "request", "solana").at(-1);
        dispatchProviderResponse(harness, {
            error: "Denied",
            errorCode: 4001,
            id: message.message.id,
            name: message.message.name,
            provider: "solana",
            ...testCase,
            validate: undefined,
        });
        await assert.rejects(request, testCase.validate);
    }
});

test("reinjection ignores a forged exact public facade alias", async () => {
    const harness = inpageHarness();
    const stableRecord = harness.window.bigWalletInpageStableFacadeRecord;
    const eipProvider = stableRecord.eip6963.provider;
    const wallet = stableRecord.wallet;
    const forgedHarness = facadeHarness();
    const forged = forgedHarness.exports.createStableFacadeRecord({
        uuid: "00000000-0000-4000-8000-000000000099",
    });
    harness.window.bigWalletInpageStableFacadeRecord = forged;
    const oldEthereum = harness.window.ethereum;
    const queued = oldEthereum.request({method: "eth_chainId"});
    harness.evaluate();
    await assert.rejects(queued, error => error.code === 4900);
    assert.equal(
        harness.window.bigWalletInpageStableFacadeRecord,
        stableRecord
    );
    assert.equal(stableRecord.eip6963.provider, eipProvider);
    assert.equal(stableRecord.wallet, wallet);
    assert.equal(harness.window.ethereum, oldEthereum);
    const anchor = Object.getOwnPropertyDescriptor(
        harness.window,
        "bigWalletInpageStableFacadeAnchorV1"
    );
    assert.equal(anchor.configurable, false);
    assert.equal(anchor.enumerable, false);
    assert.equal(anchor.writable, false);
});

test("exact reinjection preserves facades and rejects all old generation work", async () => {
    const harness = inpageHarness();
    const stableRecord = harness.window.bigWalletInpageStableFacadeRecord;
    const eipProvider = stableRecord.eip6963.provider;
    const wallet = stableRecord.wallet;
    const uuid = stableRecord.eip6963.uuid;
    const firstEthereum = harness.window.ethereum;
    const firstSolana = harness.window.solana;
    const firstGeneration =
        harness.window.bigWalletInpageProviderGenerationToken;
    const queuedEthereum = firstEthereum.request({method: "eth_chainId"});
    const queuedSolana = firstSolana.connect();
    const disconnect = firstSolana.disconnect();
    disconnect.catch(() => {});

    harness.evaluate();
    await assert.rejects(queuedEthereum, error => error.code === 4900);
    await assert.rejects(queuedSolana, error => error.code === 4900);
    await assert.rejects(disconnect, error => error.code === 4900);
    assert.equal(harness.window.ethereum, firstEthereum);
    assert.equal(harness.window.solana, firstSolana);
    assert.equal(harness.window.metamask, firstEthereum);
    assert.equal(harness.window.web3.currentProvider, firstEthereum);
    assert.equal(harness.window.bigwallet.eth, firstEthereum);
    assert.equal(harness.window.phantom.solana, firstSolana);
    assert.equal(harness.window.bigwallet.solana, firstSolana);
    assert.equal(harness.window.bigWalletInpageStableFacadeRecord, stableRecord);
    assert.equal(stableRecord.eip6963.provider, eipProvider);
    assert.equal(stableRecord.eip6963.uuid, uuid);
    assert.equal(stableRecord.wallet, wallet);
    assert.equal(harness.registeredWallets.length, 1);
    assert.equal(harness.listenerCount("message"), 1);
    assert.equal(harness.listenerCount("eip6963:requestProvider"), 1);

    const secondEthereum = harness.window.ethereum;
    const secondSolana = harness.window.solana;
    const secondGeneration =
        harness.window.bigWalletInpageProviderGenerationToken;
    dispatchConfigurations(harness, {
        publicKey: firstSolanaKey,
        solanaAuthorizationEpoch: 1,
        switchAccount: true,
    });
    const oldRPC = secondEthereum.request({
        method: "eth_blockNumber",
        params: [],
    });
    const oldSign = secondSolana.signMessage(new Uint8Array([1]));
    const oldRPCMessage = pageMessages(harness, "rpc").at(-1);
    const oldSignMessage = pageMessages(harness, "request", "solana").at(-1);
    harness.evaluate();
    await assert.rejects(oldRPC, error => error.code === 4900);
    await assert.rejects(oldSign, error => error.code === 4900);
    dispatchConfigurations(harness);
    assert.equal(await secondEthereum.request({method: "eth_chainId"}), "0x1");
    assert.equal(harness.window.bigWalletInpageStableFacadeRecord, stableRecord);
    assert.equal(harness.registeredWallets.length, 1);
    assert.equal(harness.listenerCount("message"), 1);

    dispatchConfigurations(harness, {publicKey: firstSolanaKey});
    const current = harness.window.ethereum.request({
        method: "eth_blockNumber",
        params: [],
    });
    const currentMessage = pageMessages(harness, "rpc").at(-1);
    let currentSettled = false;
    current.finally(() => { currentSettled = true; });
    harness.dispatch({
        generation: secondGeneration,
        id: oldRPCMessage.message.id,
        kind: "rpc",
        response: {id: oldRPCMessage.message.id, result: "stale"},
    });
    dispatchProviderResponse(harness, {
        generation: secondGeneration,
        id: oldSignMessage.message.id,
        name: oldSignMessage.message.name,
        provider: "solana",
        result: validSignature,
    });
    await Promise.resolve();
    assert.equal(currentSettled, false);
    harness.dispatch({
        id: currentMessage.message.id,
        kind: "rpc",
        response: {id: currentMessage.message.id, result: "current"},
    });
    assert.equal(await current, "current");
    assert.notEqual(firstGeneration, secondGeneration);
});
